# Compile binding and window-rule commands into compositor actions and
# install runtime settings at startup and reload.

type
  RuntimeActionKind = enum
    actionNative, actionExec, actionLaunch, actionCycleZones, actionSwapZones,
    actionFocusOutput, actionSwapOutputs
  WindowAction = enum
    windowNone, windowFixed, windowTitlebar, windowBorder, windowFloating, windowFullscreen,
    windowAlwaysOnTop,
    windowMinimize, windowMaximize, windowKill, windowZone, windowWorkspace, windowOutput
  RuntimeAction = object
    case kind: RuntimeActionKind
    of actionNative:
      # Only native callbacks with a window operation are allowed in for_window.
      windowAction: WindowAction
      action: proc(arg: ptr Arg) {.cdecl.}
      arg: Arg
      workspaceStep: int
    of actionExec:
      shell: string
    of actionLaunch:
      profile: WaylandClientProfile
    of actionCycleZones:
      zoneCycle: seq[cint]
    of actionSwapZones:
      targetZone: int
      focusSourceZone: bool
    of actionFocusOutput:
      outputName: string
    of actionSwapOutputs:
      outputFirst, outputSecond: string
  CompiledWindowRule = object
    rule: WindowRule
    commands: seq[RuntimeAction]
  CompiledConfig = tuple[keys: seq[Key], commands: seq[seq[RuntimeAction]],
    rules: seq[CompiledWindowRule], startup: seq[RuntimeAction]]

var
  activeConfig = defaultRuntimeConfig()
  configPath: string
  activeConfigText: string
  runtimeLoaded = false
  runtimeKeys: seq[Key]
  runtimeCommands: seq[seq[RuntimeAction]]
  runtimeWindowRules: seq[CompiledWindowRule]
  runtimeStartup: seq[RuntimeAction]

proc reloadconfig(arg: ptr Arg) {.cdecl.}
proc syncSwayIpcPolicy()
proc moveToZone*(arg: ptr Arg) {.cdecl.}
proc setFixedSize*(arg: ptr Arg) {.cdecl.}
proc setClientFixedSize(c: ptr Client; value: cint)
proc setClientTitlebar(c: ptr Client; value: cint; newWindow = false)
proc setClientBorder(c: ptr Client; value: cint; newWindow = false)
proc assignClientZone*(c: ptr Client; index: int)
proc setFloatingWindow(arg: ptr Arg) {.cdecl.}
proc setFullscreenWindow(arg: ptr Arg) {.cdecl.}
proc initializeZoneClient*(c: ptr Client)
proc setWindowMinimized(c: ptr Client; minimized: bool)
proc setWindowMaximized(c: ptr Client; maximized: bool)
proc minimizeWindow(arg: ptr Arg) {.cdecl.}
proc maximizeWindow(arg: ptr Arg) {.cdecl.}
proc minimizenotify(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc refreshTitlebarConfig()
proc cycleZones*(indices: openArray[cint])
proc swapZones(target: int; focusSource: bool)
proc focusLast(arg: ptr Arg) {.cdecl.}
proc refreshZoneConfig*(previous: RuntimeConfig)
proc cancelPointerInteraction()

proc configuredLayout(name: string): ptr Layout =
  case name
  of "monocle": addr layouts[layoutMonocleIndex]
  of "zones": addr layouts[layoutZonesIndex]
  else: nil

proc shellCommand(command: string) =
  let pid = fork()
  if pid == 0:
    discard dup2(STDERR_FILENO, STDOUT_FILENO)
    discard setsid()
    discard execl("/bin/sh", "/bin/sh", "-c", command.cstring, nil)
    die("nimzo: exec /bin/sh failed:")
  elif pid < 0:
    discard fprintf(stderr, "nimzo: fork failed\n")

proc commandParts(text: string; separators: set[char] = {','}): seq[string] =
  # exec owns the rest of the line, including shell commas and semicolons.
  var start = 0
  var quote = '\0'
  var escaped = false
  for i, ch in text:
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'\'', '"'}:
      quote = ch
    elif ch in separators:
      let part = text[start ..< i].strip
      if part == "exec" or part.startsWith("exec "):
        result.add text[start .. ^1].strip
        return
      if part.len == 0: raise newException(ValueError, "empty command")
      result.add part
      start = i + 1
  if quote != '\0': raise newException(ValueError, "unterminated command quote")
  let last = text[start .. ^1].strip
  if last.len == 0: raise newException(ValueError, "empty command")
  result.add last

proc tagArgument(text: string): Arg =
  if text == "all": return Arg(ui: high(uint32))
  let tagNumber = parseInt(text)
  if tagNumber notin 1 .. TAGCOUNT:
    raise newException(ValueError, "workspace must be 1.." & $TAGCOUNT)
  Arg(ui: 1'u32 shl (tagNumber - 1))

proc relativeWorkspace(text: string): int =
  case text
  of "next", "next_on_output": 1
  of "prev", "prev_on_output": -1
  else: 0

proc relativeTagArgument(step: int; m: ptr Monitor = selmon): Arg =
  if m == nil: raise newException(ValueError, "no active output")
  # With several visible tags, use the lowest tag as the navigation anchor.
  var current = 0
  for index in 0 ..< TAGCOUNT:
    if (m.tagset[m.seltags] and (1'u32 shl index)) != 0:
      current = index
      break
  Arg(ui: 1'u32 shl ((current + step + TAGCOUNT) mod TAGCOUNT))

proc directionArgument(text: string): Arg =
  case text
  of "left": Arg(i: cint(WLR_DIRECTION_LEFT))
  of "right": Arg(i: cint(WLR_DIRECTION_RIGHT))
  of "up": Arg(i: cint(WLR_DIRECTION_UP))
  of "down": Arg(i: cint(WLR_DIRECTION_DOWN))
  else: raise newException(ValueError, "expected output direction left, right, up, or down")

proc commandWords(text: string): seq[string] =
  var word = ""
  var quote = '\0'
  var escaped = false
  for ch in text:
    if escaped:
      word.add ch
      escaped = false
    elif ch == '\\': escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
      else: word.add ch
    elif ch in {'\'', '"'}: quote = ch
    elif ch in {' ', '\t', '\r', '\n'}:
      if word.len != 0:
        result.add word
        word = ""
    else: word.add ch
  if quote != '\0' or escaped: raise newException(ValueError, "unterminated command argument")
  if word.len != 0: result.add word

proc compileCommand(text: string; config: RuntimeConfig): RuntimeAction =
  let words = commandWords(text)
  if words.len == 0: raise newException(ValueError, "empty command")
  if words[0] == "exec":
    let shell = text[4 .. ^1].strip
    if shell.len == 0: raise newException(ValueError, "exec requires a shell command")
    return RuntimeAction(kind: actionExec, shell: shell)
  case words[0]
  of "launch":
    if words.len != 2: raise newException(ValueError, "launch requires one wayland_client name")
    for profile in config.waylandClients:
      if profile.name == words[1]: return RuntimeAction(kind: actionLaunch, profile: profile)
    raise newException(ValueError, "unknown wayland_client '" & words[1] & "'")
  of "minimize":
    if words.len == 1:
      result.action = minimizeWindow
      result.windowAction = windowMinimize
      return
  of "maximize":
    if words.len == 2 and words[1] in ["on", "off", "toggle"]:
      result.action = maximizeWindow
      result.windowAction = windowMaximize
      result.arg.i = if words[1] == "toggle": -1 elif words[1] == "on": 1 else: 0
      return
  of "exit", "reload", "kill":
    if words.len == 1:
      case words[0]
      of "exit": result.action = quit
      of "reload": result.action = reloadconfig
      of "kill":
        result.action = requestCloseFocusedWindow
        result.windowAction = windowKill
      else: discard
      return
  of "focus":
    if words.len == 2 and words[1] == "last":
      result.action = focusLast
      return
    if words.len == 2 and words[1] in ["next", "prev"]:
      result.action = focusstack
      result.arg.i = if words[1] == "next": 1 else: -1
      return
    if words.len in [2, 3] and words[1] == "output":
      if words.len == 3 and words[2] in ["left", "right", "up", "down"]:
        result.action = focusmon
        result.arg = directionArgument(words[2])
      else:
        let name = if words.len == 3 and words[2] != "next": words[2] else: ""
        return RuntimeAction(kind: actionFocusOutput, outputName: name)
      return
  of "swap":
    if words.len in 2..4 and words[1] == "outputs":
      return RuntimeAction(kind: actionSwapOutputs,
        outputFirst: if words.len == 4: words[2] else: "",
        outputSecond: if words.len >= 3: words[^1] else: "")
    if words.len in [4, 6] and words[1] == "zone" and words[2] == "with" and
        (words.len == 4 or (words[4] == "focus" and words[5] == "source")):
      let target = zoneIndex(config.zones, words[3])
      if target < 0: raise newException(ValueError, "unknown zone '" & words[3] & "'")
      return RuntimeAction(kind: actionSwapZones, targetZone: target,
        focusSourceZone: words.len == 6)
  of "workspace":
    result.action = view
    if words == @["workspace", "back_and_forth"]: return
    if words.len == 2:
      result.workspaceStep = relativeWorkspace(words[1])
      if result.workspaceStep == 0: result.arg = tagArgument(words[1])
      return
    if words.len == 3 and words[1] == "number":
      result.arg = tagArgument(words[2])
      return
  of "move":
    if words.len == 5 and words[1..3] == @["container", "to", "zone"]:
      let index = zoneIndex(config.zones, words[4])
      if index < 0: raise newException(ValueError, "unknown zone '" & words[4] & "'")
      result.action = moveToZone
      result.windowAction = windowZone
      result.arg.i = cint(index)
      return
    if words.len == 5 and words[1..3] == @["container", "to", "output"]:
      result.action = tagmon
      result.windowAction = windowOutput
      result.arg = directionArgument(words[4])
      return
    if words.len in [5, 6] and words[1..3] == @["container", "to", "workspace"]:
      if words.len == 6 and words[4] != "number":
        raise newException(ValueError, "expected workspace number")
      result.action = tag
      result.windowAction = windowWorkspace
      result.workspaceStep = relativeWorkspace(words[^1])
      if words.len == 6 or result.workspaceStep == 0:
        result.workspaceStep = 0
        result.arg = tagArgument(words[^1])
      return
  of "layout":
    if words.len == 2:
      result.action = setlayout
      let name = words[1]
      if name != "toggle":
        let layout = configuredLayout(name)
        if layout == nil: raise newException(ValueError, "unknown layout '" & name & "'")
        result.arg.v = layout
      return
  of "floating", "fullscreen":
    if words.len == 2 and words[1] in ["on", "off", "toggle"]:
      result.action = if words[0] == "floating": setFloatingWindow else: setFullscreenWindow
      result.windowAction = if words[0] == "floating": windowFloating else: windowFullscreen
      result.arg.i = if words[1] == "toggle": -1 elif words[1] == "on": 1 else: 0
      return
  of "toggleview", "toggletag":
    if words.len == 2:
      result.action = if words[0] == "toggleview": toggleview else: toggletag
      result.arg = tagArgument(words[1])
      return
  of "titlebar", "border", "alwaysOnTop":
    if words.len == 2 and words[1] in ["on", "off", "toggle"]:
      case words[0]
      of "border":
        result.action = setBorderWindow
        result.windowAction = windowBorder
      of "alwaysOnTop":
        result.action = setAlwaysOnTopWindow
        result.windowAction = windowAlwaysOnTop
      else:
        result.action = setTitlebarWindow
        result.windowAction = windowTitlebar
      result.arg.i = if words[1] == "toggle": -1 elif words[1] == "on": 1 else: 0
      return
  of "fixedSize":
    if words.len == 2 and words[1] in ["on", "off", "toggle"]:
      result.action = setFixedSize
      result.windowAction = windowFixed
      result.arg.i = if words[1] == "toggle": -1 elif words[1] == "on": 1 else: 0
      return
  of "cycle":
    if words.len == 5 and words[1..3] == @["focus", "in", "zone"]:
      let names = words[4].split('|')
      var indices = newSeq[cint](names.len)
      for i, name in names:
        let index = zoneIndex(config.zones, name)
        if index < 0: raise newException(ValueError, "unknown zone '" & name & "'")
        indices[i] = cint(index)
      return RuntimeAction(kind: actionCycleZones, zoneCycle: indices)
  of "vt":
    if words.len == 2:
      let number = parseInt(words[1])
      if number notin 1..12:
        raise newException(ValueError, "vt must be 1..12")
      result.action = chvt
      result.arg.ui = uint32(number)
      return
  else: discard
  raise newException(ValueError, "unsupported command '" & text & "'")

type OutputWorkspaceState = object
  tagset: array[2, uint32]
  seltags, sellt: cuint
  lt: array[2, ptr Layout]

proc outputBefore(a, b: ptr Monitor): bool =
  if a.m.y != b.m.y: return a.m.y < b.m.y
  if a.m.x != b.m.x: return a.m.x < b.m.x
  strcmp(a.wlr_output.name, b.wlr_output.name) < 0

proc nextEnabledOutput(current: ptr Monitor): ptr Monitor =
  # Geometry order is stable across backend enumeration and skips disabled heads.
  var first, following: ptr Monitor
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.enabled:
      if first == nil or outputBefore(m, first): first = m
      if current != nil and outputBefore(current, m) and
          (following == nil or outputBefore(m, following)): following = m
    m = wl_list_next_link(m)
  if following != nil: following else: first

proc namedEnabledOutput(name: string): ptr Monitor =
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.enabled and strcmp(m.wlr_output.name, name.cstring) == 0:
      return m
    m = wl_list_next_link(m)
  raise newException(ValueError, "unknown or disabled output '" & name & "'")

proc outputWorkspace(m: ptr Monitor): OutputWorkspaceState =
  OutputWorkspaceState(tagset: m.tagset, seltags: m.seltags, sellt: m.sellt,
    lt: m.lt)

proc installOutputWorkspace(m: ptr Monitor; state: OutputWorkspaceState) =
  m.tagset = state.tagset
  m.seltags = state.seltags
  m.sellt = state.sellt
  m.lt = state.lt

proc relocateOutputClient(c: ptr Client; destination: ptr Monitor) =
  if c.mon == destination: return
  forgetOutputPlacement(c)
  let dx = destination.w.x - c.mon.w.x
  let dy = destination.w.y - c.mon.w.y
  var geometry = c.geom
  geometry.x += dx
  geometry.y += dy
  c.prev.x += dx
  c.prev.y += dy
  c.maximizeRestore.x += dx
  c.maximizeRestore.y += dy
  c.mon = destination
  # Keep all tag bits, zone names, floating/fixed flags, and fullscreen restore
  # geometry. Publish only after every client and view has reached its target.
  resize(c, if c.isfullscreen != 0: destination.m else: geometry, 0)

proc focusOutput(destination: ptr Monitor) =
  if destination == nil: return
  selmon = destination
  wlr_cursor_warp_closest(cursor, nil, cdouble(destination.w.x) + cdouble(destination.w.width) / 2,
    cdouble(destination.w.y) + cdouble(destination.w.height) / 2)
  focusclient(focustop(destination), nil, 1)
  publishCompositorState()

proc checkOutputAction() =
  if locked != 0: raise newException(ValueError, "session is locked")
  if seat.drag != nil: raise newException(ValueError, "a data drag is active")

proc swapOutputContents(firstName, secondName: string) =
  let first = if firstName.len != 0: namedEnabledOutput(firstName)
    elif secondName.len != 0: selmon else: nextEnabledOutput(nil)
  if first == nil or not first.wlr_output.enabled: return
  let pair = secondName.len != 0
  let second = if pair: namedEnabledOutput(secondName) else: nextEnabledOutput(first)
  if first == second: return
  cancelPointerInteraction()
  # Reassign clients once from their original owners, before modifying views.
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    if c.mon != nil and c.mon.wlr_output.enabled and client_is_unmanaged(c) == 0:
      if pair:
        if c.mon == first: relocateOutputClient(c, second)
        elif c.mon == second: relocateOutputClient(c, first)
      else:
        relocateOutputClient(c, nextEnabledOutput(c.mon))
    c = wl_list_next_link(c)
  if pair:
    let saved = outputWorkspace(first)
    installOutputWorkspace(first, outputWorkspace(second))
    installOutputWorkspace(second, saved)
    arrange(first)
    arrange(second)
  else:
    var saved = outputWorkspace(first)
    var destination = nextEnabledOutput(first)
    while true:
      let displaced = outputWorkspace(destination)
      installOutputWorkspace(destination, saved)
      saved = displaced
      arrange(destination)
      if destination == first: break
      destination = nextEnabledOutput(destination)
  # Focus stays on the physical output, now showing its incoming workspace.
  focusclient(focustop(selmon), nil, 1)
  publishCompositorState()

proc runRuntimeAction(command: RuntimeAction) =
  case command.kind
  of actionExec:
    shellCommand(command.shell)
  of actionLaunch:
    launchWaylandClient(command.profile)
  of actionCycleZones:
    cycleZones(command.zoneCycle)
  of actionSwapZones:
    swapZones(command.targetZone, command.focusSourceZone)
  of actionFocusOutput:
    checkOutputAction()
    let destination = if command.outputName.len == 0: nextEnabledOutput(selmon)
      else: namedEnabledOutput(command.outputName)
    focusOutput(destination)
  of actionSwapOutputs:
    checkOutputAction()
    swapOutputContents(command.outputFirst, command.outputSecond)
  of actionNative:
    var argument = if command.workspaceStep != 0:
      relativeTagArgument(command.workspaceStep) else: command.arg
    command.action(addr argument)

proc runConfiguredBinding(arg: ptr Arg) {.cdecl.} =
  # Retain this command list across reload, which replaces its backing storage.
  let commands = runtimeCommands[int(arg.i)]
  for command in commands:
    try:
      runRuntimeAction(command)
    except ValueError as error:
      discard fprintf(stderr, "nimzo: command: %s\n", error.msg.cstring)

proc outputInDirection(m: ptr Monitor; direction: wlr_direction): ptr Monitor =
  if m == nil: return nil
  if wlr_output_layout_get(output_layout, m.wlr_output) == nil: return m
  var output = wlr_output_layout_adjacent_output(output_layout, direction, m.wlr_output,
    cdouble(m.m.x), cdouble(m.m.y))
  if output == nil:
    let opposite = cast[wlr_direction](cast[uint32](direction) xor
      cast[uint32](WLR_DIRECTION_LEFT or WLR_DIRECTION_RIGHT or WLR_DIRECTION_UP or WLR_DIRECTION_DOWN))
    output = wlr_output_layout_farthest_output(output_layout, opposite, m.wlr_output,
      cdouble(m.m.x), cdouble(m.m.y))
  if output != nil: cast[ptr Monitor](output.data) else: m

proc runWindowAction(operation: WindowAction; arg: Arg; c: ptr Client;
    workspaceStep = 0) =
  # Target the matched client directly, never the currently focused window.
  if locked != 0 or c == nil or client_is_unmanaged(c) != 0: return
  let value = arg.i
  case operation
  of windowFixed: setClientFixedSize(c, value)
  of windowTitlebar: setClientTitlebar(c, value, newWindow = true)
  of windowBorder: setClientBorder(c, value, newWindow = true)
  of windowAlwaysOnTop:
    let enabled = if value < 0: not c.alwaysOnTop else: value != 0
    if enabled == c.alwaysOnTop: return
    c.alwaysOnTop = enabled
    if c.mon != nil:
      if not enabled and c.isfloating == 0 and c.zoneName[0] == '\0':
        c.zoneInitialized = false
        if c.mon != addr parkingMonitor: initializeZoneClient(c)
      arrange(c.mon)
      publishCompositorState()
  of windowFloating:
    if c.isfullscreen == 0:
      setfloating(c, if value < 0: cint(c.isfloating == 0) else: value)
  of windowFullscreen:
    setfullscreen(c, if value < 0: cint(c.isfullscreen == 0) else: value)
  of windowMinimize: setWindowMinimized(c, true)
  of windowMaximize:
    setWindowMaximized(c, if value < 0: not c.ismaximized else: value != 0)
  of windowKill: client_send_close(c)
  of windowZone: assignClientZone(c, int(value))
  of windowWorkspace:
    var tags = arg.ui and TAGMASK
    if workspaceStep != 0 and c.mon != nil:
      tags = relativeTagArgument(workspaceStep, c.mon).ui
    if tags != 0 and c.tags != tags:
      forgetOutputPlacement(c)
      c.tags = tags
      if c.mon != nil: arrange(c.mon)
  of windowOutput:
    let destination = outputInDirection(c.mon, cast[wlr_direction](value))
    if destination != nil: setmon(c, destination, 0)
  of windowNone: discard

proc setFloatingWindow(arg: ptr Arg) {.cdecl.} =
  runWindowAction(windowFloating, arg[], focustop(selmon))

proc setAlwaysOnTopWindow(arg: ptr Arg) {.cdecl.} =
  runWindowAction(windowAlwaysOnTop, arg[], focused_client)

proc setFullscreenWindow(arg: ptr Arg) {.cdecl.} =
  runWindowAction(windowFullscreen, arg[], focustop(selmon))

proc runWindowRules(c: ptr Client) =
  let properties = clientWindowProperties(c)
  # Keep backing storage alive even if configuration changes in the future.
  let rules = runtimeWindowRules
  for compiled in rules:
    if not compiled.rule.matches(properties): continue
    for command in compiled.commands:
      if command.kind == actionExec:
        shellCommand(command.shell)
      else:
        runWindowAction(command.windowAction, command.arg, c, command.workspaceStep)

proc compileConfigCommands(config: RuntimeConfig): CompiledConfig =
  for startup in config.startup:
    try:
      if startup.command.startsWith("exec "):
        result.startup.add RuntimeAction(kind: actionExec, shell: startup.command[5..^1])
      else:
        result.startup.add compileCommand(startup.command, config)
    except ValueError as error:
      raise newException(ConfigError, startup.location & ": " & error.msg)
  for binding in config.bindings:
    var commands: seq[RuntimeAction]
    try:
      for part in commandParts(binding.command): commands.add compileCommand(part, config)
    except ValueError as error:
      raise newException(ConfigError, binding.location & ": " & error.msg)
    result.keys.add Key(`mod`: binding.modifiers, keysym: binding.keysym,
      `func`: runConfiguredBinding, arg: Arg(i: cint(result.commands.len)))
    result.commands.add commands
  for rule in config.rules:
    var compiled = CompiledWindowRule(rule: rule)
    try:
      for part in commandParts(rule.command):
        let command = compileCommand(part, config)
        if command.kind != actionExec and
            (command.kind != actionNative or command.windowAction == windowNone):
          raise newException(ValueError, "command is not supported in for_window: '" & part & "'")
        compiled.commands.add command
    except ValueError as error:
      raise newException(ConfigError, rule.location & ": " & error.msg)
    result.rules.add compiled

proc installConfig(config: RuntimeConfig; compiled: CompiledConfig) =
  activeConfig = config
  syncSwayIpcPolicy()
  runtimeKeys = compiled.keys
  runtimeCommands = compiled.commands
  runtimeWindowRules = compiled.rules
  runtimeStartup = compiled.startup
  runtimeLoaded = true
  rootcolor = config.background
  focuscolor = config.focused
  bordercolor = config.unfocused
  urgentcolor = config.urgent
  fullscreen_bg = config.fullscreen
  for button in buttons.mitems: button.`mod` = config.floatingModifiers
  for rule in monrules.mitems: rule.lt = configuredLayout(config.layout)

proc refreshConfigColors() =
  refreshTitlebarConfig()
  wlr_scene_rect_set_color(root_bg, rootcolor)
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    wlr_scene_rect_set_color(m.fullscreen_bg, fullscreen_bg)
    m = wl_list_next_link(m)
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    client_set_border_color(c, if c == focused_client: focuscolor
      elif c.isurgent != 0: urgentcolor else: bordercolor)
    c = wl_list_next_link(c)

proc reloadconfig(arg: ptr Arg) {.cdecl.} =
  if configPath.len == 0:
    discard fprintf(stderr, "nimzo: no configuration file to reload\n")
    return
  try:
    let text = readFile(configPath)
    let candidate = parseConfig(text, configPath)
    let compiled = compileConfigCommands(candidate)
    let previous = activeConfig
    cancelPointerInteraction()
    installConfig(candidate, compiled)
    activeConfigText = text
    refreshConfigColors()
    applyConfiguredOutputs(activeConfig)
    refreshZoneConfig(previous)
  except CatchableError as error:
    discard fprintf(stderr, "nimzo: reload: %s\n", error.msg.cstring)

proc loadInitialConfig(path: string; validate: bool) =
  configPath = path
  if configPath.len == 0:
    let userPath = getConfigDir() / "nimzo" / "config"
    if fileExists(userPath): configPath = userPath
    elif fileExists("/etc/nimzo/config"): configPath = "/etc/nimzo/config"
  if configPath.len == 0:
    if validate: raise newException(ConfigError, "no configuration file found")
    return
  let text = readFile(configPath)
  let candidate = parseConfig(text, configPath)
  let compiled = compileConfigCommands(candidate)
  installConfig(candidate, compiled)
  activeConfigText = text

proc startConfiguredPrograms() =
  for command in runtimeStartup:
    try:
      runRuntimeAction(command)
    except ValueError as error:
      discard fprintf(stderr, "nimzo: startup: %s\n", error.msg.cstring)
