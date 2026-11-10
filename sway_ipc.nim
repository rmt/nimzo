# SPDX-License-Identifier: 0BSD

import std/[json, posix]

const
  IpcMagic* = "i3-ipc"
  IpcHeaderSize* = 14
  IpcGetCommand* = 0'u32
  IpcSubscribe* = 2'u32
  IpcGetTree* = 4'u32
  IpcWorkspaceEvent* = 0x80000000'u32
  MaxIpcPayload* = 1024 * 1024
  MaxInputBytes = MaxIpcPayload + IpcHeaderSize
  MaxOutputBytes = 2 * 1024 * 1024
  MaxReadBytes = 64 * 1024
  MaxWriteBytes = 256 * 1024
  MaxFramesPerDispatch = 64
  MaxClients = 128

# A client is deliberately kept as a small, bounded state machine.  In
# particular, output is never written synchronously while handling input.
type
  IpcClient = ref object
    fd: SocketHandle
    input: string
    output: string
    outputPos: int
    queuedBytes, writtenBytes: int
    workspace, window: bool
    overflowed, closed: bool
    commandBlocked: bool

  IpcCommand* = ref object
    payload*: string
    client: IpcClient
    replyEnd: int
    replied, replyQueued: bool

  SwayIpc* = ref object
    listener: SocketHandle
    path: string
    boundDev: Dev
    boundIno: Ino
    clients: seq[IpcClient]
    commands: seq[IpcCommand]
    pendingCommands: int
    treeText: string
    closed: bool

proc reportFailure(path, message: string) =
  stderr.writeLine("sway IPC: ", path, ": ", message)

proc appendNative32(output: var string; value: uint32) =
  let start = output.len
  output.setLen(start + 4)
  var valueCopy = value
  copyMem(addr output[start], addr valueCopy, 4)

proc readNative32(input: string; offset: int): uint32 =
  copyMem(addr result, unsafeAddr input[offset], 4)

proc frame(payload: string; messageType: uint32): string =
  result = newStringOfCap(IpcHeaderSize + payload.len)
  result.add(IpcMagic)
  result.appendNative32(payload.len.uint32)
  result.appendNative32(messageType)
  result.add(payload)

proc setNonblocking(fd: SocketHandle): bool =
  let status = fcntl(fd, F_GETFL)
  if status < 0 or fcntl(fd, F_SETFL, status or O_NONBLOCK) < 0:
    return false
  let descriptorFlags = fcntl(fd, F_GETFD)
  if descriptorFlags < 0 or fcntl(fd, F_SETFD, descriptorFlags or FD_CLOEXEC) < 0:
    return false
  true

proc makeAddress(path: string; address: var Sockaddr_un; addressLength: var SockLen): bool =
  if path.len == 0 or path.len >= Sockaddr_un_path_length:
    return false
  zeroMem(addr address, sizeof(address))
  address.sun_family = TSa_Family(AF_UNIX)
  for index, value in path:
    address.sun_path[index] = value
  address.sun_path[path.len] = '\0'
  addressLength = SockLen(sizeof(TSa_Family) + path.len + 1)
  true

proc pathExists(path: string): bool =
  var status: Stat
  lstat(path.cstring, status) == 0

proc unlinkOwnedPath(path: string; boundDev: Dev; boundIno: Ino) =
  var status: Stat
  if lstat(path.cstring, status) == 0 and status.st_dev == boundDev and
      status.st_ino == boundIno:
    discard unlink(path.cstring)

proc startIpc*(path: string): SwayIpc =
  if path.len == 0:
    return nil
  if pathExists(path):
    reportFailure(path, "socket path already exists")
    return nil

  let listener = socket(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, 0)
  if listener == INVALID_SOCKET:
    reportFailure(path, "socket failed (errno " & $errno & ")")
    return nil
  if not setNonblocking(listener):
    reportFailure(path, "could not make socket nonblocking (errno " & $errno & ")")
    discard close(listener)
    return nil

  var address: Sockaddr_un
  var addressLength: SockLen
  if not makeAddress(path, address, addressLength):
    reportFailure(path, "socket path is too long")
    discard close(listener)
    return nil
  let previousUmask = umask(Mode(0o177))
  let bindResult = bindSocket(listener, cast[ptr SockAddr](addr address), addressLength)
  discard umask(previousUmask)
  if bindResult != 0:
    reportFailure(path, "bind failed (errno " & $errno & ")")
    discard close(listener)
    return nil
  var pathStatus: Stat
  if lstat(path.cstring, pathStatus) != 0:
    reportFailure(path, "could not stat bound socket path (errno " & $errno & ")")
    discard close(listener)
    return nil
  let boundDev = pathStatus.st_dev
  let boundIno = pathStatus.st_ino
  if listen(listener, 64) != 0:
    reportFailure(path, "listen failed (errno " & $errno & ")")
    unlinkOwnedPath(path, boundDev, boundIno)
    discard close(listener)
    return nil
  result = SwayIpc(listener: listener, path: path, boundDev: boundDev,
    boundIno: boundIno)
  result.treeText = "{\"id\":1,\"type\":\"root\",\"name\":\"root\",\"nodes\":[],\"floating_nodes\":[],\"focus\":[],\"focused\":false,\"visible\":false,\"urgent\":false,\"rect\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}"
  return

proc unlinkOwned(server: SwayIpc) =
  if server.path.len != 0:
    unlinkOwnedPath(server.path, server.boundDev, server.boundIno)

proc closeClient(server: SwayIpc; index: int) =
  let client = server.clients[index]
  client.closed = true
  discard close(client.fd)
  server.clients.delete(index)

proc close*(server: SwayIpc) =
  if server == nil or server.closed: return
  server.closed = true
  for client in server.clients:
    client.closed = true
    discard close(client.fd)
  server.clients.setLen(0)
  discard close(server.listener)
  unlinkOwned(server)
  server.listener = INVALID_SOCKET

proc queueFrame(client: IpcClient; data: string): bool =
  let pending = client.output.len - client.outputPos
  if pending + data.len > MaxOutputBytes:
    return false
  if pending == 0:
    client.output.setLen(0)
    client.outputPos = 0
  elif client.outputPos > 0:
    client.output = client.output[client.outputPos .. ^1]
    client.outputPos = 0
  client.output.add(data)
  client.queuedBytes += data.len
  true

proc takeCommands*(server: SwayIpc): seq[IpcCommand] =
  if server == nil or server.closed:
    return @[]
  result = server.commands
  server.commands = @[]

proc replyCommand*(server: SwayIpc; request: IpcCommand; results: JsonNode) =
  if server == nil or server.closed or request == nil or request.replied:
    return
  request.replied = true
  let client = request.client
  if client == nil:
    return
  dec server.pendingCommands
  client.commandBlocked = false
  if client.closed:
    return
  var payload = ""
  if results != nil:
    toUgly(payload, results)
  else:
    payload = "[]"
  let response = frame(payload, IpcGetCommand)
  if queueFrame(client, response):
    request.replyEnd = client.queuedBytes
    request.replyQueued = true
  else:
    client.overflowed = true

proc commandReplySent*(server: SwayIpc; request: IpcCommand): bool =
  if request == nil or request.client == nil:
    return false
  let client = request.client
  if client.closed:
    return true
  request.replied and request.replyQueued and client.writtenBytes >= request.replyEnd



proc errorJson(message: string): string =
  var node = newJObject()
  node["success"] = newJBool(false)
  node["error"] = newJString(message)
  $node


proc handleMessage(server: SwayIpc; client: IpcClient; messageType: uint32; payload: string): bool =
  case messageType
  of IpcGetTree:
    if payload.len != 0:
      return queueFrame(client, frame(errorJson("GET_TREE payload must be empty"), messageType))
    queueFrame(client, frame(server.treeText, messageType))
  of IpcSubscribe:
    var subscriptions: JsonNode
    try:
      subscriptions = parseJson(payload)
    except CatchableError:
      return queueFrame(client, frame(errorJson("invalid SUBSCRIBE payload"), messageType))
    if subscriptions.kind != JArray:
      return queueFrame(client, frame(errorJson("SUBSCRIBE payload must be an array"), messageType))
    var workspace, window: bool
    for item in subscriptions:
      if item.kind != JString:
        return queueFrame(client, frame(errorJson("SUBSCRIBE names must be strings"), messageType))
      case item.getStr
      of "workspace": workspace = true
      of "window": window = true
      else:
        return queueFrame(client, frame(errorJson("unsupported subscription: " & item.getStr), messageType))
    client.workspace = client.workspace or workspace
    client.window = client.window or window
    queueFrame(client, frame("{\"success\": true}", messageType))
  of IpcGetCommand:
    if server.pendingCommands >= MaxClients:
      return queueFrame(client, frame(
        "[{\"success\":false,\"error\":\"too many pending IPC commands\"}]", messageType))
    inc server.pendingCommands
    server.commands.add(IpcCommand(payload: payload, client: client))
    client.commandBlocked = true
    true
  else:
    queueFrame(client, frame(errorJson("unsupported IPC message type"), messageType))

proc serviceInput(server: SwayIpc; client: IpcClient): bool =
  var buffer: array[4096, char]
  var bytesRead = 0
  while bytesRead < MaxReadBytes:
    let count = recv(client.fd, addr buffer[0], buffer.len, 0)
    if count > 0:
      let inputEnd = client.input.len
      client.input.setLen(inputEnd + count)
      copyMem(addr client.input[inputEnd], addr buffer[0], count)
      bytesRead += count
      if client.input.len > MaxInputBytes:
        return false
      continue
    if count == 0:
      return false
    if errno == EINTR: continue
    if errno == EAGAIN or errno == EWOULDBLOCK: break
    return false

  var processed = 0
  var offset = 0
  while processed < MaxFramesPerDispatch and not client.commandBlocked:
    if client.input.len - offset < IpcHeaderSize: break
    for index in 0..<IpcMagic.len:
      if client.input[offset + index] != IpcMagic[index]: return false
    let payloadLength = readNative32(client.input, offset + 6).int
    if payloadLength < 0 or payloadLength > MaxIpcPayload: return false
    let total = IpcHeaderSize + payloadLength
    if client.input.len - offset < total: break
    let messageType = readNative32(client.input, offset + 10)
    var payload = ""
    if payloadLength > 0:
      payload = client.input[offset + IpcHeaderSize ..< offset + total]
    offset += total
    if not handleMessage(server, client, messageType, payload): return false
    inc processed
  if offset > 0:
    let remaining = client.input.len - offset
    if remaining > 0:
      moveMem(addr client.input[0], addr client.input[offset], remaining)
    client.input.setLen(remaining)
  true

proc serviceOutput(client: IpcClient): bool =
  var written = 0
  while client.outputPos < client.output.len and written < MaxWriteBytes:
    let remaining = min(client.output.len - client.outputPos, MaxWriteBytes - written)
    let count = send(client.fd, cast[pointer](unsafeAddr client.output[client.outputPos]), remaining, MSG_NOSIGNAL)
    if count > 0:
      client.outputPos += count
      client.writtenBytes += count
      written += count
      continue
    if count < 0 and errno == EINTR: continue
    if count < 0 and (errno == EAGAIN or errno == EWOULDBLOCK): break
    return false
  if client.outputPos == client.output.len:
    client.output.setLen(0)
    client.outputPos = 0
  true

proc acceptClients(server: SwayIpc) =
  var accepted = 0
  while accepted < MaxClients:
    let fd = accept4(server.listener, nil, nil, SOCK_CLOEXEC)
    if fd == INVALID_SOCKET:
      if errno == EINTR: continue
      if errno == EAGAIN or errno == EWOULDBLOCK: break
      break
    inc accepted
    if not setNonblocking(fd):
      discard close(fd)
      continue
    if server.clients.len >= MaxClients:
      discard close(fd)
      continue
    server.clients.add(IpcClient(fd: fd))

proc bufferedFrame(client: IpcClient): bool =
  if client.input.len < IpcHeaderSize: return false
  let length = readNative32(client.input, 6).int
  length > MaxIpcPayload or length <= client.input.len - IpcHeaderSize

proc appendPollFds*(server: SwayIpc; fds: var seq[TPollfd]) =
  if server == nil or server.closed: return
  fds.add(TPollfd(fd: cast[cint](server.listener), events: POLLIN, revents: 0))
  for client in server.clients:
    var events = POLLIN
    if client.commandBlocked:
      # A command must be answered before this client can parse more input.
      # Do not poll a blocked socket for readable data or buffered frames.
      events = 0
    else:
      # A writable wakeup also drains complete frames left by the per-pass
      # budget. Incomplete payloads must wait for POLLIN.
      if client.outputPos < client.output.len or client.bufferedFrame:
        events = events or POLLOUT
    if client.outputPos < client.output.len:
      events = events or POLLOUT
    fds.add(TPollfd(fd: cast[cint](client.fd), events: events, revents: 0))

proc setTree*(server: SwayIpc; tree: JsonNode) =
  if server == nil or server.closed or tree == nil: return
  var serialized = ""
  toUgly(serialized, tree)
  if serialized == server.treeText: return
  server.treeText = serialized
  let event = frame("{\"change\":\"reload\"}", IpcWorkspaceEvent)
  for client in server.clients:
    if client.workspace and not queueFrame(client, event):
      # A client that cannot keep up is dropped on the next dispatch pass.  We
      # cannot close here while callers may be iterating a pollfd snapshot.
      client.overflowed = true

proc dispatch*(server: SwayIpc; fds: openArray[TPollfd]) =
  if server == nil or server.closed: return
  # Service existing clients before accepting new ones.  This prevents a newly
  # accepted descriptor from accidentally matching a stale pollfd entry after
  # a client was closed during this dispatch.
  for polled in fds:
    if polled.fd == cast[cint](server.listener): continue
    var index = 0
    while index < server.clients.len:
      let client = server.clients[index]
      if cast[cint](client.fd) == polled.fd:
        var keep = not client.overflowed and
          (polled.revents and (POLLERR or POLLHUP or POLLNVAL)) == 0
        if keep and not client.commandBlocked and
            ((polled.revents and POLLIN) != 0 or client.input.len >= IpcHeaderSize):
          keep = serviceInput(server, client)
        if keep and (polled.revents and POLLOUT) != 0:
          keep = serviceOutput(client)
        if not keep:
          closeClient(server, index)
        break
      inc index
  for polled in fds:
    if polled.fd == cast[cint](server.listener) and (polled.revents and (POLLIN or POLLERR or POLLHUP)) != 0:
      acceptClients(server)
      break
