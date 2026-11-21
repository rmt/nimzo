# Connect the Sway IPC server to the Wayland event loop. Publish snapshots
# of compositor state and dispatch incoming commands to native actions.

import std/tables

type
  IpcFdCallback = proc(fd: cint; mask: uint32; data: pointer): cint {.cdecl.}
  IpcWatch = object
    source: ptr wl_event_source
    mask: uint32
    active: bool

proc ipcAddFd(loop: ptr wl_event_loop; fd: cint; mask: uint32;
    callback: IpcFdCallback; data: pointer): ptr wl_event_source
  {.cdecl, importc: "wl_event_loop_add_fd".}
proc ipcUpdateFd(source: ptr wl_event_source; mask: uint32): cint
  {.cdecl, importc: "wl_event_source_fd_update".}

const
  IpcReadable = 1'u32
  IpcWritable = 2'u32
  IpcHangup = 4'u32
  IpcError = 8'u32

proc ipcLayoutName(keymap: ptr xkb_keymap; index: uint32): cstring
  {.cdecl, importc: "xkb_keymap_layout_get_name".}
proc ipcLayoutCount(keymap: ptr xkb_keymap): uint32
  {.cdecl, importc: "xkb_keymap_num_layouts".}

# Sway IPC is a projection of native output-local tags, not another WM model.
var
  swayServer: SwayIpc
  swayIdle: ptr wl_event_source
  swayWatches: Table[cint, IpcWatch]
  swayStaleFds: seq[cint]
  swayServicing = false
  swayDirty = true
  swayNextId = 2'i64
  swayPollFds: seq[ipcPosix.TPollfd]
  swaySocketPath: string
  swayExitRequests: seq[IpcCommand]

proc publishSwayIdle(data: pointer) {.cdecl.}
proc serviceSwayFd(fd: cint; mask: uint32; data: pointer): cint {.cdecl.}

proc syncSwayIpcPolicy() =
  swayServer.setRestricted(activeConfig.swayIpcRestricted)

proc markSwayDirty() =
  swayDirty = true
  if swayServer != nil and swayIdle == nil and not swayServicing:
    swayIdle = wl_event_loop_add_idle(event_loop, publishSwayIdle, nil)

proc updateSwayWatches() =
  swayPollFds.setLen(0)
  swayServer.appendPollFds(swayPollFds)
  for watch in swayWatches.mvalues:
    watch.active = false
  for descriptor in swayPollFds:
    let fd = descriptor.fd
    var mask = 0'u32
    if (descriptor.events and ipcPosix.POLLIN) != 0: mask = mask or IpcReadable
    if (descriptor.events and ipcPosix.POLLOUT) != 0: mask = mask or IpcWritable
    if swayWatches.hasKey(fd):
      var watch = addr swayWatches[fd]
      watch.active = true
      if watch.mask != mask:
        if ipcUpdateFd(watch.source, mask) < 0:
          raise newException(IOError, "could not update IPC socket event source")
        watch.mask = mask
    else:
      let source = ipcAddFd(event_loop, fd, mask, serviceSwayFd, nil)
      if source == nil:
        raise newException(IOError, "could not watch IPC socket")
      swayWatches[fd] = IpcWatch(source: source, mask: mask, active: true)
  swayStaleFds.setLen(0)
  for fd, watch in swayWatches:
    if not watch.active:
      discard wl_event_source_remove(watch.source)
      swayStaleFds.add fd
  for fd in swayStaleFds:
    swayWatches.del(fd)

proc ipcId(value: var int64): int64 =
  if value == 0:
    value = swayNextId
    inc swayNextId
  value

proc ipcRect(box: wlr_box): JsonNode =
  %*{"x": box.x, "y": box.y, "width": box.width, "height": box.height}

proc ipcTransform(value: wl_output_transform): string =
  const names = ["normal", "90", "180", "270", "flipped", "flipped-90",
    "flipped-180", "flipped-270"]
  names[int(value)]

proc ipcNode(id: int64; kind, name: string; box: wlr_box): JsonNode =
  %*{"id": id, "type": kind, "name": name, "rect": ipcRect(box),
    "nodes": [], "floating_nodes": [], "focus": [], "focused": false,
    "visible": false, "urgent": false, "layout": "splith", "border": "pixel",
    "current_border_width": 0, "fullscreen_mode": 0, "percent": 1.0}

proc ipcWorkspaceName(m: ptr Monitor; number: int): string =
  $m.wlr_output.name & ":" & $number

proc ipcClientTag(c: ptr Client): int =
  # Sway trees cannot represent one container in several workspaces. Prefer a
  # visible membership, then the first membership; native tag bits stay intact.
  var mask = c.tags and c.mon.tagset[c.mon.seltags]
  if mask == 0: mask = c.tags
  for index in 0 ..< TAGCOUNT:
    if (mask and (1'u32 shl index)) != 0: return index

proc refreshSwaySnapshot() =
  if swayServer == nil or not swayDirty: return
  swayDirty = false
  # The selected output can follow the pointer while keyboard focus remains on
  # a client elsewhere. Waybar's tree must follow the selected output, too.
  let projectedFocus = if focused_client != nil and locked == 0 and
      VISIBLEON(focused_client, selmon): focused_client else: nil
  let tree = ipcNode(1, "root", "root", sgeom)
  let workspaces = newJArray()
  let outputs = newJArray()
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    let outputId = ipcId(m.ipcId)
    let outputNode = ipcNode(outputId, "output", $m.wlr_output.name, m.m)
    outputNode["active"] = %m.wlr_output.enabled
    outputNode["primary"] = %(m == selmon)
    outputNode["scale"] = %m.wlr_output.scale
    outputNode["transform"] = %ipcTransform(m.wlr_output.transform)
    let currentMode = %*{"width": m.wlr_output.width, "height": m.wlr_output.height,
      "refresh": m.wlr_output.refresh}
    outputNode["current_mode"] = currentMode
    let modes = newJArray()
    var mode: ptr wlr_output_mode
    mode = wl_list_first_link(addr m.wlr_output.modes, mode)
    while wl_list_more_link(mode, addr m.wlr_output.modes):
      modes.add %*{"width": mode.width, "height": mode.height,
        "refresh": mode.refresh, "preferred": mode.preferred}
      mode = wl_list_next_link(mode)
    var currentWorkspace = ""
    if m.wlr_output.enabled:
      var occupied = 0'u32
      var member: ptr Client
      member = wl_list_first_link(addr clients, member)
      while wl_list_more_link(member, addr clients):
        if member.mon == m and client_is_unmanaged(member) == 0:
          occupied = occupied or member.tags
        member = wl_list_next_link(member)
      var primaryTag = 0
      for index in 0 ..< TAGCOUNT:
        if (m.tagset[m.seltags] and (1'u32 shl index)) != 0:
          primaryTag = index
          break
      if projectedFocus != nil and VISIBLEON(projectedFocus, m):
        primaryTag = ipcClientTag(projectedFocus)
      currentWorkspace = ipcWorkspaceName(m, primaryTag + 1)
      let published = occupied or m.tagset[m.seltags]
      for index in 0 ..< TAGCOUNT:
        if (published and (1'u32 shl index)) == 0: continue
        let visible = (m.tagset[m.seltags] and (1'u32 shl index)) != 0
        let name = ipcWorkspaceName(m, index + 1)
        let workspaceId = outputId * 16 + int64(index) + 1_000_000'i64
        let ws = ipcNode(workspaceId, "workspace", name, m.w)
        # Non-numeric names make Waybar send the full output-qualified name.
        # Numeric clicks otherwise send only `workspace number N`.
        ws["num"] = %(-1)
        ws["visible"] = %visible
        ws["representation"] = %($cast[cstring](addr m.ltsymbol[0]))
        let selected = visible and m == selmon and index == primaryTag
        ws["focused"] = %(selected and projectedFocus == nil)
        var urgent = false
        var c: ptr Client
        c = wl_list_first_link(addr clients, c)
        while wl_list_more_link(c, addr clients):
          if c.mon == m and client_is_unmanaged(c) == 0:
            if (c.tags and (1'u32 shl index)) != 0 and c.isurgent != 0: urgent = true
            if ipcClientTag(c) == index:
              let node = ipcNode(ipcId(c.ipcId), "con", $client_get_title(c), c.geom)
              node["app_id"] = %($client_get_appid(c))
              node["window"] = newJNull()
              node["window_properties"] = %*{"class": $client_get_appid(c),
                "instance": $client_get_appid(c), "title": $client_get_title(c)}
              node["focused"] = %(c == projectedFocus)
              node["visible"] = %(visible and not c.isminimized)
              node["urgent"] = %(c.isurgent != 0)
              node["fullscreen_mode"] = %(if c.isfullscreen != 0: 1 else: 0)
              node["minimized"] = %c.isminimized
              node["maximized"] = %c.ismaximized
              node["current_border_width"] = %c.bw
              node["shell"] = %(if c.`type` == X11: "xwayland" else: "xdg_shell")
              if c.isfloating != 0:
                node["type"] = %"floating_con"
                ws["floating_nodes"].add node
              else:
                ws["nodes"].add node
              if c == projectedFocus: ws["focus"].add node["id"]
          c = wl_list_next_link(c)
        ws["urgent"] = %urgent
        workspaces.add %*{"id": workspaceId, "num": -1, "name": name,
          "visible": visible, "focused": selected, "urgent": urgent,
          "rect": ipcRect(m.w), "output": $m.wlr_output.name}
        outputNode["nodes"].add ws
        if selected: outputNode["focus"].add %workspaceId
      outputNode["current_workspace"] = if currentWorkspace.len == 0: newJNull() else: %currentWorkspace
      tree["nodes"].add outputNode
      if m == selmon: tree["focus"].add %outputId
    outputs.add %*{"id": outputId, "name": $m.wlr_output.name,
      "active": m.wlr_output.enabled, "power": m.wlr_output.enabled,
      "primary": m == selmon, "rect": ipcRect(m.m), "scale": m.wlr_output.scale,
      "transform": ipcTransform(m.wlr_output.transform),
      "current_workspace": (if currentWorkspace.len == 0: newJNull() else: %currentWorkspace),
      "current_mode": currentMode, "modes": modes, "make": $m.wlr_output.make,
      "model": $m.wlr_output.model, "serial": $m.wlr_output.serial}
    m = wl_list_next_link(m)
  let inputs = newJArray()
  if kb_group != nil and kb_group.wlr_group != nil:
    let keyboard = addr kb_group.wlr_group.keyboard
    let layouts = newJArray()
    if keyboard.keymap != nil:
      for index in 0'u32 ..< ipcLayoutCount(keyboard.keymap):
        layouts.add %($ipcLayoutName(keyboard.keymap, index))
    let active = int(keyboard.modifiers.group)
    inputs.add %*{"identifier": "nimzo-keyboard-group", "name": $keyboard.base.name,
      "type": "keyboard", "xkb_layout_names": layouts, "xkb_active_layout_index": active,
      "xkb_active_layout_name": (if active < layouts.len: layouts[active].getStr else: "")}
  let seats = %*[{"name": $seat.name, "capabilities": seat.capabilities,
    "focus": (if focused_client != nil: ipcId(focused_client.ipcId) else: 0'i64),
    "devices": inputs}]
  swayServer.setConfig(activeConfigText)
  swayServer.setSnapshot(tree, workspaces, outputs, inputs, seats)


proc ipcMonitor(name: string): ptr Monitor =
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.enabled and $m.wlr_output.name == name: return m
    m = wl_list_next_link(m)

proc ipcWorkspace(text: string): tuple[monitor: ptr Monitor, arg: Arg] =
  let colon = text.find(':')
  if colon < 0:
    result = (selmon, tagArgument(text))
  else:
    result.monitor = ipcMonitor(text[0 ..< colon])
    if result.monitor == nil: raise newException(ValueError, "unknown or disabled output")
    result.arg = tagArgument(text[colon + 1 .. ^1])
  if result.monitor == nil: raise newException(ValueError, "no active output")

proc executeSwayCommand(text: string): bool =
  if locked != 0: raise newException(ValueError, "session is locked")
  var words = commandWords(text)
  if words.len == 0: raise newException(ValueError, "empty command")
  if activeConfig.swayIpcRestricted and words[0] != "workspace":
    raise newException(ValueError, "only workspace selection is available in restricted Sway IPC")
  if words[0] == "workspace":
    if words.len > 1 and words[1] == "--no-auto-back-and-forth": words.delete(1)
    if words.len == 2 and words[1] in ["next", "prev", "next_on_output", "prev_on_output"]:
      runRuntimeAction(compileCommand(words.join(" "), activeConfig))
      markSwayDirty()
      return false
    if words == @["workspace", "back_and_forth"]:
      var argument: Arg
      view(addr argument)
      markSwayDirty()
      return false
    if words.len notin [2, 3] or (words.len == 3 and words[1] != "number"):
      raise newException(ValueError, "expected workspace [number] NAME")
    var target = ipcWorkspace(words[^1])
    selmon = target.monitor
    view(addr target.arg)
    focusclient(focustop(selmon), nil, 1)
  elif words.len in [5, 6] and words[0..3] == @["move", "container", "to", "workspace"]:
    if words.len == 6 and words[4] != "number":
      raise newException(ValueError, "expected workspace number")
    if words.len == 5 and relativeWorkspace(words[^1]) != 0:
      runRuntimeAction(compileCommand(text, activeConfig))
      markSwayDirty()
      return false
    var target = ipcWorkspace(words[^1])
    let c = focustop(selmon)
    if c == nil: raise newException(ValueError, "no selected window")
    if c.mon == target.monitor: tag(addr target.arg)
    else: setmon(c, target.monitor, target.arg.ui)
  else:
    var command = compileCommand(text, activeConfig)
    if words == @["exit"]: return true # Reply before stopping the event loop.
    runRuntimeAction(command)
  markSwayDirty()

proc serviceSwayIpc() =
  try:
    swayServicing = true
    refreshSwaySnapshot()
    for request in swayServer.takeCommands():
      let replies = newJArray()
      var exiting = false
      try:
        for part in commandParts(request.payload, {',', ';', '\n'}):
          exiting = executeSwayCommand(part) or exiting
          replies.add %*{"success": true}
      except CatchableError as error:
        replies.add %*{"success": false, "parse_error": true, "error": error.msg}
      refreshSwaySnapshot()
      swayServer.replyCommand(request, replies)
      if exiting: swayExitRequests.add request
    for request in swayExitRequests:
      if swayServer.commandReplySent(request): wl_display_terminate(dpy)
    updateSwayWatches()
  except CatchableError as error:
    discard fprintf(stderr, "nimzo: IPC: %s\n", error.msg.cstring)
  finally:
    swayServicing = false

proc publishSwayIdle(data: pointer) {.cdecl.} =
  swayIdle = nil
  serviceSwayIpc()

proc serviceSwayFd(fd: cint; mask: uint32; data: pointer): cint {.cdecl.} =
  try:
    # Refresh before answering queries, even if a native state change and a
    # socket request become ready in the same event-loop dispatch.
    refreshSwaySnapshot()
    var descriptor = ipcPosix.TPollfd(fd: fd)
    if (mask and IpcReadable) != 0: descriptor.revents = descriptor.revents or ipcPosix.POLLIN
    if (mask and IpcWritable) != 0: descriptor.revents = descriptor.revents or ipcPosix.POLLOUT
    if (mask and IpcHangup) != 0: descriptor.revents = descriptor.revents or ipcPosix.POLLHUP
    if (mask and IpcError) != 0: descriptor.revents = descriptor.revents or ipcPosix.POLLERR
    swayServer.dispatch([descriptor])
    serviceSwayIpc()
  except CatchableError as error:
    discard fprintf(stderr, "nimzo: IPC: %s\n", error.msg.cstring)
  0

proc startSwayIpc() =
  swaySocketPath = getEnv("XDG_RUNTIME_DIR") / ("nimzo-ipc." & $getCurrentProcessId() & ".sock")
  swayServer = startIpc(swaySocketPath)
  if swayServer == nil: die("nimzo: could not start Sway IPC")
  syncSwayIpcPolicy()
  putEnv("SWAYSOCK", swaySocketPath)
  putEnv("I3SOCK", swaySocketPath)
  updateSwayWatches()
  markSwayDirty()

proc stopSwayIpc() =
  if swayIdle != nil:
    discard wl_event_source_remove(swayIdle)
    swayIdle = nil
  for watch in swayWatches.values:
    discard wl_event_source_remove(watch.source)
  swayWatches.clear()
  swayPollFds.setLen(0)
  swayStaleFds.setLen(0)
  if swayServer != nil:
    swayServer.close()
    swayServer = nil
  for variable in ["SWAYSOCK", "I3SOCK"]:
    if getEnv(variable) == swaySocketPath: delEnv(variable)
