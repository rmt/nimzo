# Test that the Wayland event loop processes IPC requests and publishes
# compositor updates without waiting for a polling timer.

const VERSION = "ipc-dispatch-test"
include ../nimzo_core
include headless_support

proc dispatchEvents(loop: ptr wl_event_loop; timeout: cint): cint
  {.cdecl, importc: "wl_event_loop_dispatch".}

proc drainEvents() =
  # Bound work rather than elapsed time: accept, read, execute, publish, write.
  for _ in 0..<8:
    doAssert dispatchEvents(event_loop, 0) == 0

proc connectIpc(): ipcPosix.SocketHandle =
  result = ipcPosix.socket(ipcPosix.AF_UNIX, ipcPosix.SOCK_STREAM or ipcPosix.SOCK_CLOEXEC, 0)
  doAssert cint(result) >= 0
  let path = getEnv("SWAYSOCK")
  var address: ipcPosix.Sockaddr_un
  address.sun_family = ipcPosix.TSa_Family(ipcPosix.AF_UNIX)
  for index, ch in path: address.sun_path[index] = ch
  doAssert ipcPosix.connect(result, cast[ptr ipcPosix.SockAddr](addr address),
    ipcPosix.SockLen(sizeof(ipcPosix.TSa_Family) + path.len + 1)) == 0
  let flags = ipcPosix.fcntl(result, ipcPosix.F_GETFL)
  doAssert ipcPosix.fcntl(result, ipcPosix.F_SETFL, flags or ipcPosix.O_NONBLOCK) == 0

proc sendRequest(fd: ipcPosix.SocketHandle; kind: uint32; payload = "") =
  var data = IpcMagic & newString(8) & payload
  var size = uint32(payload.len)
  var messageType = kind
  copyMem(addr data[6], addr size, 4)
  copyMem(addr data[10], addr messageType, 4)
  doAssert ipcPosix.send(fd, addr data[0], data.len, ipcPosix.MSG_NOSIGNAL) == data.len

proc replies(fd: ipcPosix.SocketHandle): seq[tuple[kind: uint32, payload: JsonNode]] =
  var data: string
  var buffer: array[8192, char]
  while true:
    let count = ipcPosix.recv(fd, addr buffer[0], buffer.len, 0)
    if count < 0:
      if ipcPosix.errno == ipcPosix.EINTR: continue
      doAssert ipcPosix.errno in [ipcPosix.EAGAIN, ipcPosix.EWOULDBLOCK]
      break
    doAssert count > 0
    let offset = data.len
    data.setLen(offset + count)
    copyMem(addr data[offset], addr buffer[0], count)
  var offset = 0
  while offset < data.len:
    doAssert data.len - offset >= IpcHeaderSize
    doAssert data[offset..<offset + IpcMagic.len] == IpcMagic
    var size, kind: uint32
    copyMem(addr size, addr data[offset + 6], 4)
    copyMem(addr kind, addr data[offset + 10], 4)
    let start = offset + IpcHeaderSize
    doAssert data.len - start >= int(size)
    result.add (kind, parseJson(data[start..<start + int(size)]))
    offset = start + int(size)

let directory = headlessRuntime("nimzo-ipc-dispatch-", 1)
let configFile = directory / "config"
writeFile(configFile, "output HEADLESS-1 default\noutput HEADLESS-1 mode 400x300\n")
loadInitialConfig(configFile, false)
setup()
startSwayIpc()
doAssert wlr_backend_start(backend)
selmon = namedEnabledOutput("HEADLESS-1")
doAssert selmon != nil
drainEvents()
let subscriber = connectIpc()
sendRequest(subscriber, IpcSubscribe, "[\"workspace\"]")
drainEvents()
let subscribed = replies(subscriber)
doAssert subscribed.len == 1 and subscribed[0].kind == IpcSubscribe
doAssert subscribed[0].payload["success"].getBool

# Native changes notify an otherwise idle subscriber without a query to wake IPC.
var tagThree = Arg(ui: 4)
view(addr tagThree)
drainEvents()
let events = replies(subscriber)
doAssert events.len == 1 and events[0].kind == IpcWorkspaceEvent

let client = connectIpc()
sendRequest(client, IpcRunCommand, "workspace 2")
sendRequest(client, IpcGetWorkspaces)
drainEvents()
let result = replies(client)
doAssert result.len == 2
doAssert result[0].kind == IpcRunCommand and result[0].payload[0]["success"].getBool
doAssert result[1].kind == IpcGetWorkspaces
doAssert result[1].payload[0]["name"].getStr == "HEADLESS-1:2"
doAssert result[1].payload[0]["focused"].getBool

sendRequest(client, IpcGetConfig)
drainEvents()
let defaultDenied = replies(client)
doAssert defaultDenied.len == 1 and not defaultDenied[0].payload["success"].getBool

let baseConfig = readFile(configFile)
writeFile(configFile, baseConfig & "sway_ipc_restricted off\n")
reloadconfig(nil)

# Buffered requests beyond the per-dispatch budget must not wait for more input.
for _ in 0..<100: sendRequest(client, IpcGetVersion)
drainEvents()
let versions = replies(client)
doAssert versions.len == 100
for version in versions:
  doAssert version.kind == IpcGetVersion
  doAssert version.payload["human_readable"].getStr == "nimzo 0.9.2"
discard ipcPosix.close(client)
discard ipcPosix.close(subscriber)
drainEvents()
# Closed descriptors can be reused without retaining stale readiness watches.
let replacement = connectIpc()
sendRequest(replacement, IpcGetWorkspaces)
drainEvents()
let current = replies(replacement)
doAssert current.len == 1 and current[0].payload[0]["name"].getStr == "HEADLESS-1:2"

# A reload changes the policy on the same socket, including between commands.
writeFile(configFile, baseConfig)
sendRequest(replacement, IpcRunCommand, "reload; exit")
sendRequest(replacement, IpcGetConfig)
drainEvents()
let restricted = replies(replacement)
doAssert restricted.len == 2
doAssert restricted[0].payload.len == 2
doAssert restricted[0].payload[0]["success"].getBool
doAssert not restricted[0].payload[1]["success"].getBool
doAssert restricted[1].kind == IpcGetConfig and not restricted[1].payload["success"].getBool

sendRequest(replacement, IpcSubscribe, """["workspace","window"]""")
sendRequest(replacement, IpcSubscribe, """["workspace","input"]""")
sendRequest(replacement, IpcRunCommand, """workspace --no-auto-back-and-forth "HEADLESS-1:4"; kill""")
sendRequest(replacement, IpcGetWorkspaces)
drainEvents()
var workspaceEvent, requestedWorkspace: bool
var subscriptions = 0
for reply in replies(replacement):
  case reply.kind
  of IpcSubscribe:
    doAssert reply.payload["success"].getBool == (subscriptions == 0)
    inc subscriptions
  of IpcRunCommand:
    doAssert reply.payload.len == 2 and reply.payload[0]["success"].getBool
    doAssert not reply.payload[1]["success"].getBool
  of IpcWorkspaceEvent: workspaceEvent = true
  of IpcGetWorkspaces:
    requestedWorkspace = reply.payload[0]["name"].getStr == "HEADLESS-1:4"
  else: doAssert false
doAssert subscriptions == 2 and workspaceEvent and requestedWorkspace
discard ipcPosix.close(replacement)
cleanup()
removeFile(configFile)
removeDir(directory)
echo "PASS: IPC subscriptions, native updates, pipelined commands, buffered requests and fd reuse progress without poll waits"
