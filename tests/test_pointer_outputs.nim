# Test that pointer motion over empty outputs updates Sway IPC workspace
# events and reported focus without moving keyboard focus from the window.

const VERSION = "pointer-output-test"
include ../nimzo_core
include headless_support

type Reply = tuple[kind: uint32, payload: JsonNode]
var socketFd = ipcPosix.INVALID_SOCKET
var socketInput: string
var stage, attempts: int
var timer: ptr wl_event_source
var barPid: pid_t = -1
let runtimeDir = headlessRuntime("nimzo-pointer-", 2)
putEnv("GDK_BACKEND", "wayland")
let testConfig = runtimeDir / "config"
writeFile(testConfig, """
output HEADLESS-1 default
output HEADLESS-1 mode 400x300
output HEADLESS-1 position 0 0
output HEADLESS-2 mode 400x300
output HEADLESS-2 position 0 300
for_window [app_id="^pointer-window$"] floating on
exec "$NIMZO_ZONE_CLIENT" pointer-window
""")

proc connectIpc() =
  socketFd = ipcPosix.socket(ipcPosix.AF_UNIX, ipcPosix.SOCK_STREAM or ipcPosix.SOCK_CLOEXEC, 0)
  doAssert cint(socketFd) >= 0
  let path = getEnv("SWAYSOCK")
  var address: ipcPosix.Sockaddr_un
  address.sun_family = ipcPosix.TSa_Family(ipcPosix.AF_UNIX)
  for index, ch in path: address.sun_path[index] = ch
  let length = ipcPosix.SockLen(sizeof(ipcPosix.TSa_Family) + path.len + 1)
  doAssert ipcPosix.connect(socketFd, cast[ptr ipcPosix.SockAddr](addr address), length) == 0
  let flags = ipcPosix.fcntl(socketFd, ipcPosix.F_GETFL)
  doAssert ipcPosix.fcntl(socketFd, ipcPosix.F_SETFL, flags or ipcPosix.O_NONBLOCK) == 0

proc sendRequest(kind: uint32; payload = "") =
  var frame = "i3-ipc" & newString(8) & payload
  var size = uint32(payload.len)
  var messageType = kind
  copyMem(addr frame[6], addr size, 4)
  copyMem(addr frame[10], addr messageType, 4)
  # All requests in this scenario fit in the socket's empty local send buffer.
  doAssert ipcPosix.send(socketFd, addr frame[0], frame.len, ipcPosix.MSG_NOSIGNAL) == frame.len

proc receiveReplies(): seq[Reply] =
  var buffer: array[4096, char]
  while true:
    let count = ipcPosix.recv(socketFd, addr buffer[0], buffer.len, 0)
    if count > 0:
      let start = socketInput.len
      socketInput.setLen(start + count)
      copyMem(addr socketInput[start], addr buffer[0], count)
    else:
      doAssert count < 0
      if ipcPosix.errno == ipcPosix.EINTR: continue
      doAssert ipcPosix.errno == ipcPosix.EAGAIN or ipcPosix.errno == ipcPosix.EWOULDBLOCK
      break
  while socketInput.len >= 14:
    doAssert socketInput[0..<6] == "i3-ipc"
    var size, kind: uint32
    copyMem(addr size, addr socketInput[6], 4)
    copyMem(addr kind, addr socketInput[10], 4)
    let total = 14 + int(size)
    if socketInput.len < total: break
    result.add (kind, parseJson(socketInput[14..<total]))
    socketInput = socketInput[total..^1]

proc assertTreeFocus(tree: JsonNode; outputName: string; windowFocused: bool) =
  var focusedLeaves = 0
  for output in tree["nodes"]:
    if output["focused"].getBool:
      inc focusedLeaves
      doAssert output["name"].getStr == outputName and not windowFocused
    for workspace in output["nodes"]:
      if workspace["focused"].getBool:
        inc focusedLeaves
        doAssert output["name"].getStr == outputName and not windowFocused
      for node in workspace["nodes"]:
        if node["focused"].getBool:
          inc focusedLeaves
          doAssert output["name"].getStr == outputName and windowFocused
      for node in workspace["floating_nodes"]:
        if node["focused"].getBool:
          inc focusedLeaves
          doAssert output["name"].getStr == outputName and windowFocused
    if output["name"].getStr == outputName:
      doAssert tree["focus"][0].getBiggestInt == output["id"].getBiggestInt
  doAssert focusedLeaves == 1

var pendingReplies: seq[Reply]

proc checkReplies(output: string; windowFocused, expectEvent: bool): bool =
  pendingReplies.add receiveReplies()
  var treeReceived, workspaceEvent, workspacesReceived: bool
  for reply in pendingReplies:
    case reply.kind
    of IpcGetTree:
      treeReceived = true
      assertTreeFocus(reply.payload, output, windowFocused)
    of IpcGetWorkspaces:
      workspacesReceived = true
      var selected: seq[string]
      for workspace in reply.payload:
        if workspace["focused"].getBool: selected.add workspace["output"].getStr
      doAssert selected == @[output]
    of IpcWorkspaceEvent: workspaceEvent = true
    of IpcSubscribe: doAssert reply.payload["success"].getBool
    else: discard
  if not treeReceived or not workspacesReceived: return false
  doAssert workspaceEvent == expectEvent
  pendingReplies.setLen(0)
  true

proc queryFocus() =
  sendRequest(IpcGetTree)
  sendRequest(IpcGetWorkspaces)

proc moveTo(x, y: cdouble) =
  motionnotify(10, nil, x - cursor.x, y - cursor.y, 0, 0)

proc captureOutput(output, path: string) =
  let pid = fork()
  if pid == 0:
    os.sleep(1500) # Let Waybar process the real subscription and GTK repaint.
    discard execl("/usr/bin/grim", "grim", "-o", output.cstring, path.cstring, nil)
    exit(2)
  doAssert pid > 0

proc checkStage(): bool =
  let first = namedEnabledOutput("HEADLESS-1")
  let second = namedEnabledOutput("HEADLESS-2")
  let bar = getEnv("NIMZO_POINTER_WAYBAR")
  if bar.len != 0 and barPid < 0:
    barPid = fork()
    if barPid == 0:
      let example = getCurrentDir() / "examples" / "waybar.jsonc"
      let style = getCurrentDir() / "examples" / "waybar.css"
      discard execl(bar.cstring, bar.cstring, "-c", example.cstring, "-s", style.cstring, nil)
      exit(2)
    doAssert barPid > 0
  if bar.len != 0 and (first.w.y == first.m.y or second.w.y == second.m.y): return false
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  if not wl_list_more_link(c, addr clients) or c.resize_serial != 0: return false
  let proof = getEnv("NIMZO_POINTER_PROOF")
  case stage
  of 0:
    resize(c, wlr_box(x: 40, y: 80, width: 180, height: 140), 0)
    moveTo(100, 100)
    doAssert selmon == first and focused_client == c
    connectIpc()
    sendRequest(IpcSubscribe, "[\"workspace\",\"window\"]")
    queryFocus()
  of 1:
    # Initial tree has a genuinely keyboard-focused window on the first output.
    if not checkReplies("HEADLESS-1", true, false): return false
    moveTo(350, 450)
    doAssert selmon == second and focused_client == c
    queryFocus()
  of 2:
    # An empty output must win over the retained keyboard focus on the first.
    if not checkReplies("HEADLESS-2", false, true): return false
    if proof.len != 0:
      captureOutput("HEADLESS-1", proof & "-1.png")
      captureOutput("HEADLESS-2", proof & "-2.png")
  of 3:
    if proof.len != 0 and (not fileExists(proof & "-1.png") or not fileExists(proof & "-2.png")):
      return false
    moveTo(320, 450) # Same output: do not emit redundant workspace events.
    queryFocus()
  of 4:
    if not checkReplies("HEADLESS-2", false, false): return false
    moveTo(350, 250) # Back to background, not to the first output's window.
    doAssert selmon == first and focused_client == c
    queryFocus()
  of 5:
    if not checkReplies("HEADLESS-1", true, true): return false
    discard ipcPosix.close(socketFd)
    socketFd = ipcPosix.INVALID_SOCKET
    wl_display_terminate(dpy)
    echo "PASS: pointer-only output changes focus selected empty workspace tags without stealing native keyboard focus; same-output motion stays quiet"
  else: discard
  true

proc tick(data: pointer): cint {.cdecl.} =
  try:
    inc attempts
    if attempts > 60: raise newException(ValueError, "pointer-output test timed out at stage " & $stage)
    if checkStage(): inc stage
    if stage <= 5: discard wl_event_source_timer_update(timer, 200)
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)
  0

loadInitialConfig(testConfig, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 200)
run(nil)
discard wl_event_source_remove(timer)
if barPid > 0: discard kill(barPid, SIGTERM)
cleanup()
removeFile(testConfig)
removeDir(runtimeDir)
