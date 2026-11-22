# SPDX-License-Identifier: 0BSD

# Serve the Sway-compatible protocol over nonblocking Unix sockets. Handle
# message framing, request and reply queues, and subscription events.

import std/[json, posix, tables]

const
  IpcMagic* = "i3-ipc"
  IpcHeaderSize* = 14
  IpcRunCommand* = 0'u32
  IpcGetCommand* = IpcRunCommand
  IpcGetWorkspaces* = 1'u32
  IpcSubscribe* = 2'u32
  IpcGetOutputs* = 3'u32
  IpcGetTree* = 4'u32
  IpcGetMarks* = 5'u32
  IpcGetVersion* = 7'u32
  IpcGetBindingModes* = 8'u32
  IpcGetConfig* = 9'u32
  IpcGetBindingState* = 12'u32
  IpcGetInputs* = 100'u32
  IpcGetSeats* = 101'u32
  IpcWorkspaceEvent* = 0x80000000'u32
  IpcOutputEvent* = 0x80000001'u32
  IpcWindowEvent* = 0x80000003'u32
  IpcModeEvent* = 0x80000002'u32
  IpcShutdownEvent* = 0x80000006'u32
  IpcBindingEvent* = 0x80000005'u32
  IpcInputEvent* = 0x80000015'u32
  MaxIpcPayload* = 1024 * 1024
  MaxInputBytes = MaxIpcPayload + IpcHeaderSize
  MaxOutputBytes = 2 * 1024 * 1024
  MaxReadBytes = 64 * 1024
  MaxWriteBytes = 256 * 1024
  MaxFramesPerDispatch = 64
  MaxClients = 128

# Each client is a bounded, nonblocking state machine. Input is parsed only from
# complete frames, and output is drained by dispatch rather than by callbacks.
type
  IpcClient = ref object
    fd: SocketHandle
    input: string
    output: string
    outputPos: int
    queuedBytes, writtenBytes: int
    workspace, window, outputEvents, mode, shutdown, binding, inputEvents: bool
    overflowed, closed: bool
    commandBlocked: bool
    pendingRequest: IpcCommand

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
    restricted: bool
    configText: string
    treeText, workspacesText, outputsText, inputsText, seatsText: string
    windows: Table[int64, JsonNode]
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
  appendNative32(result, payload.len.uint32)
  appendNative32(result, messageType)
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
    boundIno: boundIno,
    treeText: "{\"id\":1,\"type\":\"root\",\"name\":\"root\",\"nodes\":[],\"floating_nodes\":[],\"focus\":[],\"focused\":false,\"visible\":false,\"urgent\":false,\"rect\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}",
    workspacesText: "[]", outputsText: "[]", inputsText: "[]", seatsText: "[]")

proc unlinkOwned(server: SwayIpc) =
  if server.path.len != 0:
    unlinkOwnedPath(server.path, server.boundDev, server.boundIno)

proc closeClient(server: SwayIpc; index: int) =
  let client = server.clients[index]
  client.closed = true
  if client.pendingRequest != nil and not client.pendingRequest.replied:
    client.pendingRequest.replied = true
    client.pendingRequest.replyQueued = false
    client.pendingRequest = nil
    if server.pendingCommands > 0:
      dec server.pendingCommands
  discard close(client.fd)
  server.clients.delete(index)

proc close*(server: SwayIpc) =
  if server == nil or server.closed:
    return
  server.closed = true
  for client in server.clients:
    client.closed = true
    if client.pendingRequest != nil and not client.pendingRequest.replied:
      client.pendingRequest.replied = true
      client.pendingRequest.replyQueued = false
      client.pendingRequest = nil
      if server.pendingCommands > 0:
        dec server.pendingCommands
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

proc setRestricted*(server: SwayIpc; restricted: bool) =
  if server == nil or server.restricted == restricted: return
  server.restricted = restricted
  if restricted:
    for client in server.clients:
      client.outputEvents = false
      client.mode = false
      client.shutdown = false
      client.binding = false
      client.inputEvents = false

proc setConfig*(server: SwayIpc; text: string) =
  if server == nil or server.closed:
    return
  server.configText = text

proc replyCommand*(server: SwayIpc; request: IpcCommand; results: JsonNode) =
  if server == nil or server.closed or request == nil or request.replied:
    return
  request.replied = true
  let client = request.client
  if client == nil:
    return
  if server.pendingCommands > 0:
    dec server.pendingCommands
  client.pendingRequest = nil
  client.commandBlocked = false
  if client.closed:
    return
  var payload = ""
  if results != nil:
    toUgly(payload, results)
  else:
    payload = "[]"
  let response = frame(payload, IpcRunCommand)
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
  result = $node

proc handleMessage(server: SwayIpc; client: IpcClient; messageType: uint32; payload: string): bool =
  if server.restricted and messageType notin [IpcRunCommand, IpcGetWorkspaces, IpcSubscribe, IpcGetTree]:
    return queueFrame(client, frame(errorJson("request is not available in restricted Sway IPC"), messageType))
  case messageType
  of IpcRunCommand:
    if server.pendingCommands >= MaxClients:
      return queueFrame(client, frame("[{\"success\":false,\"error\":\"too many pending IPC commands\"}]", messageType))
    let request = IpcCommand(payload: payload, client: client)
    server.commands.add(request)
    client.pendingRequest = request
    client.commandBlocked = true
    inc server.pendingCommands
    true
  of IpcSubscribe:
    var subscriptions: JsonNode
    try:
      subscriptions = parseJson(payload)
    except CatchableError:
      return queueFrame(client, frame(errorJson("invalid SUBSCRIBE payload"), messageType))
    if subscriptions.kind != JArray:
      return queueFrame(client, frame(errorJson("SUBSCRIBE payload must be an array"), messageType))
    var workspace, window, outputEvents, mode, shutdown, binding, inputEvents: bool
    for item in subscriptions:
      if item.kind != JString:
        return queueFrame(client, frame(errorJson("SUBSCRIBE names must be strings"), messageType))
      if server.restricted and item.getStr notin ["workspace", "window"]:
        return queueFrame(client, frame(errorJson("event is not available in restricted Sway IPC"), messageType))
      case item.getStr
      of "workspace": workspace = true
      of "window": window = true
      of "output": outputEvents = true
      of "mode": mode = true
      of "shutdown": shutdown = true
      of "binding": binding = true
      of "input": inputEvents = true
      else:
        return queueFrame(client, frame(errorJson("unsupported subscription: " & item.getStr), messageType))
    client.workspace = client.workspace or workspace
    client.window = client.window or window
    client.outputEvents = client.outputEvents or outputEvents
    client.mode = client.mode or mode
    client.shutdown = client.shutdown or shutdown
    client.binding = client.binding or binding
    client.inputEvents = client.inputEvents or inputEvents
    queueFrame(client, frame("{\"success\": true}", messageType))
  of IpcGetWorkspaces:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame(server.workspacesText, messageType))
  of IpcGetOutputs:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame(server.outputsText, messageType))
  of IpcGetTree:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame(server.treeText, messageType))
  of IpcGetMarks, IpcGetBindingModes:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame(if messageType == IpcGetBindingModes: "[\"default\"]" else: "[]", messageType))
  of IpcGetVersion:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame("{\"major\":0,\"minor\":9,\"patch\":2,\"human_readable\":\"nimzo 0.9.2\",\"loaded_config_file_name\":null}", messageType))
  of IpcGetConfig:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    var configNode = newJObject()
    configNode["config"] = newJString(server.configText)
    var configPayload = ""
    toUgly(configPayload, configNode)
    queueFrame(client, frame(configPayload, messageType))
  of IpcGetBindingState:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame("{\"name\":\"default\"}", messageType))
  of IpcGetInputs:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame(server.inputsText, messageType))
  of IpcGetSeats:
    if payload.len != 0: return queueFrame(client, frame(errorJson("request payload must be empty"), messageType))
    queueFrame(client, frame(server.seatsText, messageType))
  else:
    queueFrame(client, frame(errorJson("unsupported IPC message type"), messageType))

proc serviceInput(server: SwayIpc; client: IpcClient): bool =
  var buffer: array[4096, char]
  var bytesRead = 0
  while bytesRead < MaxReadBytes:
    # Leave bytes beyond the buffer limit in the socket until parsing frees space.
    let room = MaxInputBytes - client.input.len
    if room == 0: break
    let count = recv(client.fd, addr buffer[0], min(min(buffer.len, room), MaxReadBytes - bytesRead), 0)
    if count > 0:
      let inputEnd = client.input.len
      client.input.setLen(inputEnd + count)
      copyMem(addr client.input[inputEnd], addr buffer[0], count)
      bytesRead += count
      continue
    if count == 0:
      return false
    if errno == EINTR:
      continue
    if errno == EAGAIN or errno == EWOULDBLOCK:
      break
    return false

  var processed = 0
  var offset = 0
  while processed < MaxFramesPerDispatch and not client.commandBlocked:
    if client.input.len - offset < IpcHeaderSize:
      break
    for index in 0..<IpcMagic.len:
      if client.input[offset + index] != IpcMagic[index]:
        return false
    let payloadLengthRaw = readNative32(client.input, offset + 6)
    if payloadLengthRaw > MaxIpcPayload.uint32:
      return false
    let payloadLength = payloadLengthRaw.int
    let total = IpcHeaderSize + payloadLength
    if client.input.len - offset < total:
      break
    let messageType = readNative32(client.input, offset + 10)
    var payload = ""
    if payloadLength > 0:
      payload = client.input[offset + IpcHeaderSize ..< offset + total]
    offset += total
    if not handleMessage(server, client, messageType, payload):
      return false
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
    if count < 0 and errno == EINTR:
      continue
    if count < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
      break
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
      if errno == EINTR:
        continue
      if errno == EAGAIN or errno == EWOULDBLOCK:
        break
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
  if client.input.len < IpcHeaderSize:
    return false
  for index in 0..<IpcMagic.len:
    if client.input[index] != IpcMagic[index]:
      return false
  let length = readNative32(client.input, 6)
  length <= MaxIpcPayload.uint32 and length.int <= client.input.len - IpcHeaderSize

proc appendPollFds*(server: SwayIpc; fds: var seq[TPollfd]) =
  if server == nil or server.closed:
    return
  fds.add(TPollfd(fd: cast[cint](server.listener), events: POLLIN, revents: 0))
  for client in server.clients:
    var events = POLLIN
    if client.commandBlocked:
      events = 0
    elif client.bufferedFrame:
      events = events or POLLOUT
    if client.outputPos < client.output.len:
      events = events or POLLOUT
    fds.add(TPollfd(fd: cast[cint](client.fd), events: events, revents: 0))

proc collectWindows(node: JsonNode; windows: var Table[int64, JsonNode]) =
  if node == nil or node.kind != JObject: return
  if node.hasKey("type") and node["type"].getStr in ["con", "floating_con"]:
    windows[node["id"].getBiggestInt] = node
  for key in ["nodes", "floating_nodes"]:
    if node.hasKey(key):
      for child in node[key]: collectWindows(child, windows)

proc setSnapshot*(server: SwayIpc; tree, workspaces, outputs, inputs, seats: JsonNode) =
  if server == nil or server.closed:
    return
  var treeText = server.treeText
  var workspacesText = server.workspacesText
  var outputsText = server.outputsText
  var inputsText = server.inputsText
  var seatsText = server.seatsText
  if tree != nil:
    treeText = ""
    toUgly(treeText, tree)
  if workspaces != nil:
    workspacesText = ""
    toUgly(workspacesText, workspaces)
  if outputs != nil:
    outputsText = ""
    toUgly(outputsText, outputs)
  if inputs != nil:
    inputsText = ""
    toUgly(inputsText, inputs)
  if seats != nil:
    seatsText = ""
    toUgly(seatsText, seats)
  let treeChanged = treeText != server.treeText
  let workspacesChanged = workspacesText != server.workspacesText
  let outputsChanged = outputsText != server.outputsText
  let inputsChanged = inputsText != server.inputsText
  server.treeText = treeText
  server.workspacesText = workspacesText
  server.outputsText = outputsText
  server.inputsText = inputsText
  server.seatsText = seatsText

  proc publish(messageType: uint32; payload: string; interested: proc(client: IpcClient): bool {.closure.}) =
    let event = frame(payload, messageType)
    for client in server.clients:
      if interested(client) and not queueFrame(client, event):
        client.overflowed = true

  if workspacesChanged:
    publish(IpcWorkspaceEvent, "{\"change\":\"reload\"}", proc(client: IpcClient): bool = client.workspace)
  if treeChanged:
    var windows: Table[int64, JsonNode]
    collectWindows(tree, windows)
    proc windowEvent(change: string; node: JsonNode) =
      let event = %*{"change": change, "container": node}
      var payload = ""
      toUgly(payload, event)
      publish(IpcWindowEvent, payload, proc(client: IpcClient): bool = client.window)
    for id, previous in server.windows:
      if not windows.hasKey(id): windowEvent("close", previous)
    var focused = false
    var lostFocus: JsonNode
    for id, window in windows:
      if window.getOrDefault("focused").getBool:
        focused = true
      elif server.windows.hasKey(id) and server.windows[id].getOrDefault("focused").getBool:
        lostFocus = window
      if not server.windows.hasKey(id):
        windowEvent("new", window)
      else:
        let previous = server.windows[id]
        for (field, change) in [("name", "title"), ("fullscreen_mode", "fullscreen_mode"),
            ("urgent", "urgent"), ("rect", "move"), ("type", "floating")]:
          if window.getOrDefault(field) != previous.getOrDefault(field):
            windowEvent(change, window)
      if window.getOrDefault("focused").getBool and
          (not server.windows.hasKey(id) or not server.windows[id].getOrDefault("focused").getBool):
        windowEvent("focus", window)
    # Losing focus to an empty workspace or a layer surface has no new focused
    # window to announce. Still wake subscribers so they clear the old title.
    if not focused and lostFocus != nil:
      windowEvent("focus", lostFocus)
    server.windows = windows
  if outputsChanged:
    publish(IpcOutputEvent, "{\"change\":\"unspecified\"}", proc(client: IpcClient): bool = client.outputEvents)
  if inputsChanged:
    var eventNode = newJObject()
    eventNode["change"] = newJString("reload")
    var inputNode: JsonNode
    try:
      inputNode = parseJson(inputsText)
    except CatchableError:
      inputNode = newJArray()
    eventNode["input"] = inputNode
    var payload = ""
    toUgly(payload, eventNode)
    publish(IpcInputEvent, payload, proc(client: IpcClient): bool = client.inputEvents)

proc setTree*(server: SwayIpc; tree: JsonNode) =
  server.setSnapshot(tree, nil, nil, nil, nil)

proc dispatch*(server: SwayIpc; fds: openArray[TPollfd]) =
  if server == nil or server.closed:
    return
  for polled in fds:
    if polled.fd == cast[cint](server.listener):
      continue
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
    if polled.fd == cast[cint](server.listener) and
        (polled.revents and (POLLIN or POLLERR or POLLHUP)) != 0:
      acceptClients(server)
      break
