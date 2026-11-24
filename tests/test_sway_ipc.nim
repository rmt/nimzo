# Test the standalone Sway IPC server over Unix sockets, including message
# framing, subscriptions, command replies, and partial reads and writes.

import std/[json, os, posix, strutils, unittest]
import ../sway_ipc

var pathCounter = 0

proc native32(value: uint32): string =
  result = newString(4)
  var copy = value
  copyMem(addr result[0], addr copy, 4)

proc request(messageType: uint32; payload = ""): string =
  result = IpcMagic & native32(payload.len.uint32) & native32(messageType) & payload

proc testPath(): string =
  inc pathCounter
  "/tmp/nimzo-sway-ipc-" & $getpid() & "-" & $pathCounter

proc socketAddress(path: string; address: var Sockaddr_un; length: var SockLen) =
  zeroMem(addr address, sizeof(address))
  address.sun_family = TSa_Family(AF_UNIX)
  for index, value in path:
    address.sun_path[index] = value
  address.sun_path[path.len] = '\0'
  length = SockLen(sizeof(TSa_Family) + path.len + 1)

proc connectClient(path: string): SocketHandle =
  result = socket(AF_UNIX, SOCK_STREAM, 0)
  var address: Sockaddr_un
  var length: SockLen
  socketAddress(path, address, length)
  doAssert connect(result, cast[ptr SockAddr](addr address), length) == 0

proc sendAll(fd: SocketHandle; data: string) =
  var sent = 0
  while sent < data.len:
    let count = send(fd, cast[pointer](unsafeAddr data[sent]), data.len - sent, 0)
    doAssert count > 0
    sent += count

proc pump(server: SwayIpc; passes = 4) =
  for _ in 0..<passes:
    var fds: seq[TPollfd] = @[]
    server.appendPollFds(fds)
    if fds.len > 0:
      discard poll(addr fds[0], Tnfds(fds.len), 10)
      server.dispatch(fds)

proc readExact(fd: SocketHandle; size: int): string =
  result = newString(size)
  var received = 0
  while received < size:
    let count = recv(fd, addr result[received], size - received, 0)
    doAssert count > 0
    received += count

proc readFrame(fd: SocketHandle): tuple[messageType: uint32, payload: string] =
  let header = readExact(fd, IpcHeaderSize)
  check header[0..<IpcMagic.len] == IpcMagic
  var length: uint32
  var messageType: uint32
  copyMem(addr length, unsafeAddr header[6], 4)
  copyMem(addr messageType, unsafeAddr header[10], 4)
  result.messageType = messageType
  result.payload = readExact(fd, length.int)

suite "sway IPC transport":
  test "fragmented and pipelined requests use native framing":
    let path = testPath()
    let server = startIpc(path)
    check server != nil
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server)
    let first = request(IpcGetVersion)
    sendAll(client, first[0..<5])
    pump(server)
    sendAll(client, first[5..^1])
    sendAll(client, request(IpcGetMarks) & request(IpcGetBindingModes))
    pump(server, 8)
    let version = readFrame(client)
    check version.messageType == IpcGetVersion
    let info = parseJson(version.payload)
    check info["human_readable"].getStr == "nimzo 0.9.3"
    check (info["major"].getInt, info["minor"].getInt, info["patch"].getInt) == (0, 9, 3)
    check readFrame(client).messageType == IpcGetMarks
    check readFrame(client).messageType == IpcGetBindingModes

  test "subscriptions publish sway event containers":
    let path = testPath()
    let server = startIpc(path)
    check server != nil
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server)
    sendAll(client, request(IpcSubscribe, "[\"workspace\",\"window\",\"output\"]"))
    pump(server, 4)
    check readFrame(client).messageType == IpcSubscribe
    server.setSnapshot(
      parseJson("{\"id\":7,\"type\":\"con\",\"name\":\"terminal\",\"focused\":true,\"nodes\":[]}"),
      parseJson("[{\"name\":\"OUTPUT:1\",\"num\":-1,\"focused\":true}]"),
      parseJson("[{\"name\":\"DP-1\",\"active\":true}]"), nil, nil)
    pump(server, 8)
    var sawWorkspace, sawWindow, sawOutput = false
    for _ in 0..<4:
      let event = readFrame(client)
      case event.messageType
      of IpcWorkspaceEvent: sawWorkspace = true
      of IpcWindowEvent:
        sawWindow = true
        let container = parseJson(event.payload)["container"]
        check container["id"].getInt == 7
        check container["type"].getStr == "con"
      of IpcOutputEvent: sawOutput = true
      else: check false
    check sawWorkspace and sawWindow and sawOutput
    # Minimizing the last focused window must clear the bar without waiting
    # for an unrelated title, geometry, or workspace-list change.
    server.setTree(parseJson("{\"id\":7,\"type\":\"con\",\"name\":\"terminal\",\"focused\":false,\"minimized\":true,\"nodes\":[]}"))
    pump(server, 4)
    let unfocused = readFrame(client)
    check unfocused.messageType == IpcWindowEvent
    check parseJson(unfocused.payload)["change"].getStr == "focus"
    check not parseJson(unfocused.payload)["container"]["focused"].getBool
    # Closing the last window must wake sway/window even though the workspace
    # list did not change, or the old title stays on screen.
    server.setTree(parseJson("{\"id\":1,\"type\":\"root\",\"nodes\":[]}"))
    pump(server, 4)
    let closed = readFrame(client)
    check closed.messageType == IpcWindowEvent
    check parseJson(closed.payload)["change"].getStr == "close"
    check parseJson(closed.payload)["container"]["id"].getInt == 7

  test "run command replies are queued and ownership is cleaned":
    let path = testPath()
    let server = startIpc(path)
    check server != nil
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server)
    sendAll(client, request(IpcRunCommand, "focus next"))
    pump(server, 4)
    let commands = server.takeCommands()
    check commands.len == 1
    check commands[0].payload == "focus next"
    server.replyCommand(commands[0], parseJson("[{\"success\":true}]"))
    pump(server, 8)
    let reply = readFrame(client)
    check reply.messageType == IpcRunCommand
    check parseJson(reply.payload)[0]["success"].getBool
    check server.commandReplySent(commands[0])
    server.close()
    check not fileExists(path)

  test "a maximum-sized command can be followed by a pipelined query":
    let path = testPath()
    let server = startIpc(path)
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server, 1)
    let payload = repeat('x', MaxIpcPayload)
    let command = request(IpcRunCommand, payload)
    var offset = 0
    while offset < command.high:
      let next = min(offset + 16 * 1024, command.high)
      sendAll(client, command[offset ..< next])
      pump(server, 1)
      offset = next
    sendAll(client, command[^1..^1] & request(IpcGetVersion))
    pump(server, 1)
    let commands = server.takeCommands()
    require commands.len == 1
    check commands[0].payload == payload
    server.replyCommand(commands[0], parseJson("[{\"success\":true}]"))
    pump(server)
    var ready = TPollfd(fd: cint(client), events: POLLIN)
    require poll(addr ready, Tnfds(1), 100) == 1
    check readFrame(client).messageType == IpcRunCommand
    require poll(addr ready, Tnfds(1), 100) == 1
    check readFrame(client).messageType == IpcGetVersion

  test "malformed and unsupported requests receive bounded errors":
    let path = testPath()
    let server = startIpc(path)
    check server != nil
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server)
    sendAll(client, request(IpcSubscribe, "{") & request(999'u32))
    pump(server, 8)
    let malformed = parseJson(readFrame(client).payload)
    check malformed["success"].getBool == false
    let unsupported = parseJson(readFrame(client).payload)
    check unsupported["success"].getBool == false

  test "oversized payload is rejected and socket is closed":
    let path = testPath()
    let server = startIpc(path)
    check server != nil
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server)
    var invalid = IpcMagic & native32((MaxIpcPayload + 1).uint32) & native32(IpcGetTree)
    sendAll(client, invalid)
    pump(server, 4)
    var byte: char
    check recv(client, addr byte, 1, 0) == 0

  test "queued replies preserve bytes after a partial socket write":
    let path = testPath()
    let server = startIpc(path)
    check server != nil
    let client = connectClient(path)
    defer:
      discard close(client)
      server.close()
    pump(server)
    var descriptors: seq[TPollfd]
    server.appendPollFds(descriptors)
    # A small server-side send buffer forces a partial write without timing
    # assumptions or a large amount of test data.
    var sendBuffer = 4096.cint
    doAssert setsockopt(SocketHandle(descriptors[1].fd), SOL_SOCKET, SO_SNDBUF,
      addr sendBuffer, SockLen(sizeof(sendBuffer))) == 0
    let text = repeat('x', 64 * 1024)
    server.setConfig(text)
    sendAll(client, request(IpcGetConfig))
    pump(server, 2)
    # Append a second reply while the first one is only partly sent.
    sendAll(client, request(IpcGetMarks))
    pump(server, 1)
    let expected = request(IpcGetConfig, $(%*{"config": text})) &
      request(IpcGetMarks, "[]")
    let flags = fcntl(client, F_GETFL)
    doAssert fcntl(client, F_SETFL, flags or O_NONBLOCK) == 0
    var received: string
    var buffer: array[8192, char]
    for _ in 0..<100:
      while true:
        let count = recv(client, addr buffer[0], buffer.len, 0)
        if count < 0:
          if errno == EINTR: continue
          doAssert errno == EAGAIN or errno == EWOULDBLOCK
          break
        doAssert count > 0
        let offset = received.len
        received.setLen(offset + count)
        copyMem(addr received[offset], addr buffer[0], count)
      if received.len >= expected.len: break
      pump(server, 1)
    check received == expected
