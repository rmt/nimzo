# Define runtime settings and defaults. Parse and validate the user
# configuration and match window properties against configured rules.

import std/[math, re, strutils, tables]
import zones_geometry

proc xkb_keysym_from_name(name: cstring; flags: cint): uint32 {.importc,
  header: "xkbcommon/xkbcommon.h".}

type
  ConfigError* = object of CatchableError
  Color* = array[4, cfloat]

  ClientColors* = object
    border*, background*, text*, indicator*, childBorder*, titlebarBorder*: Color

  OutputRule* = object
    name*: string
    hasMode*: bool
    width*, height*, refresh*: int
    hasPosition*: bool
    x*, y*: int
    relativeTo*: string
    gap*: int
    hasScale*: bool
    scale*: float32
    hasTransform*: bool
    transform*: int
    isDefault*: bool
    hasEnabled*: bool
    enabled*: bool

  ConfigBinding* = object
    modifiers*, keysym*: uint32
    command*, location*: string

  WindowProperties* = object
    appId*, title*, className*, instance*: string
    isXwayland*: bool

  WindowRule* = object
    appId, title, className, instance: Regex
    hasAppId, hasTitle, hasClass, hasInstance: bool
    command*, location*: string

  WaylandCapability* = enum
    capCapture = "capture"
    capClipboard = "clipboard"
    capVirtualInput = "virtual-input"
    capInputMethod = "input-method"
    capSessionLock = "session-lock"
    capToplevel = "toplevel"
    capOutputControl = "output-control"

  WaylandClientProfile* = object
    name*: string
    capabilities*: set[WaylandCapability]
    argv*: seq[string]

  StartupCommand* = object
    command*, location*: string

  RuntimeConfig* = object
    bindings*: seq[ConfigBinding]
    outputs*: seq[OutputRule]
    startup*: seq[StartupCommand]
    waylandClients*: seq[WaylandClientProfile]
    background*, focused*, unfocused*, urgent*, fullscreen*: Color
    focusedDecoration*, unfocusedDecoration*, urgentDecoration*: ClientColors
    font*: string
    titlebars*: bool
    swayIpcRestricted*, waylandProtocolsRestricted*: bool
    floatingModifiers*: uint32
    zones*: seq[ZoneDef]
    defaultZoneIndex*: int
    layout*: string
    snapDistance*: int
    rules*: seq[WindowRule]

const
  modifierShift = 1'u32
  modifierCtrl = 4'u32
  modifierAlt = 8'u32
  modifierMod3 = 32'u32
  modifierSuper = 64'u32
  modifierMod5 = 128'u32

proc defaultClientColors(border: Color): ClientColors =
  ClientColors(border: border, background: border,
    text: [1.cfloat, 1.cfloat, 1.cfloat, 1.cfloat],
    indicator: border, childBorder: border, titlebarBorder: border)

proc defaultZones(): seq[ZoneDef] =
  @[ZoneDef(name: "L", width: 50, height: 100),
    ZoneDef(name: "R", x: 50, width: 50, height: 100)]

proc baseRuntimeConfig(): RuntimeConfig =
  let root = [0x22.cfloat / 255, 0x22.cfloat / 255, 0x22.cfloat / 255, 1.cfloat]
  let border = [0x44.cfloat / 255, 0x44.cfloat / 255, 0x44.cfloat / 255, 1.cfloat]
  let focus = [0.cfloat, 0x55.cfloat / 255, 0x77.cfloat / 255, 1.cfloat]
  let urgent = [1.cfloat, 0.cfloat, 0.cfloat, 1.cfloat]
  let fullscreen = [0.cfloat, 0.cfloat, 0.cfloat, 1.cfloat]
  RuntimeConfig(background: root, focused: focus, unfocused: border, urgent: urgent,
    focusedDecoration: defaultClientColors(focus),
    unfocusedDecoration: defaultClientColors(border),
    urgentDecoration: defaultClientColors(urgent),
    fullscreen: fullscreen, font: "monospace 10", titlebars: false,
    swayIpcRestricted: true, waylandProtocolsRestricted: true,
    floatingModifiers: modifierSuper, defaultZoneIndex: -1, layout: "zones", snapDistance: 32)

proc defaultRuntimeConfig*(): RuntimeConfig =
  result = baseRuntimeConfig()
  result.zones = defaultZones()

proc valueError(message: string): ref ValueError =
  newException(ValueError, message)

proc isVariableStart(ch: char): bool = ch in {'a'..'z', 'A'..'Z', '_'}
proc isVariableChar(ch: char): bool = isVariableStart(ch) or ch in {'0'..'9'}

proc expandVariables(text: string; variables: Table[string, string]): string =
  var i = 0
  while i < text.len:
    if text[i] == '\\' and i + 1 < text.len:
      result.add(text[i])
      result.add(text[i + 1])
      i += 2
    elif text[i] == '$' and i + 1 < text.len and isVariableStart(text[i + 1]):
      var stop = i + 2
      while stop < text.len and isVariableChar(text[stop]):
        inc stop
      let name = text[i..<stop]
      if variables.hasKey(name): result.add(variables[name])
      else: result.add(name)
      i = stop
    else:
      result.add(text[i])
      inc i

proc takeWord(text: string; position: var int): string =
  while position < text.len and text[position] in Whitespace:
    inc position
  if position >= text.len: return ""
  var quote = '\0'
  while position < text.len:
    let ch = text[position]
    inc position
    if ch == '\\' and quote != '\'':
      if position >= text.len: raise valueError("trailing backslash")
      let next = text[position]
      if quote == '"' and next notin {'"', '\\', '$', '`'}:
        result.add('\\')
      result.add(next)
      inc position
    elif quote != '\0':
      if ch == quote: quote = '\0'
      else: result.add(ch)
    elif ch in {'"', '\''}:
      quote = ch
    elif ch in Whitespace:
      break
    else:
      result.add(ch)
  if quote != '\0': raise valueError("unterminated quote")

proc words(text: string): seq[string] =
  var position = 0
  while true:
    while position < text.len and text[position] in Whitespace:
      inc position
    if position >= text.len: break
    result.add(takeWord(text, position))

proc parseWaylandClient(text: string): WaylandClientProfile =
  let args = words(text)
  if args.len < 3 or args[0].len == 0 or not args[2].startsWith('/'):
    raise valueError("wayland_client requires NAME CAPABILITIES /absolute/executable [ARG...]")
  for arg in args:
    if '\0' in arg: raise valueError("wayland_client arguments cannot contain NUL")
  result.name = args[0]
  for capability in args[1].split('+'):
    var found = false
    for value in WaylandCapability:
      if $value == capability:
        result.capabilities.incl(value)
        found = true
        break
    if not found: raise valueError("unknown Wayland capability '" & capability & "'")
  result.argv = args[2..^1]

proc stripComment(line: string): string =
  var quote = '\0'
  var escaped = false
  var i = 0
  while i < line.len:
    let ch = line[i]
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'"', '\''}:
      quote = ch
    elif ch == '#' and (i == 0 or line[i - 1] in Whitespace):
      if i == 0 or line[0..<i].strip.len == 0:
        return ""
      var stop = i + 1
      while stop < line.len and line[stop] notin Whitespace:
        inc stop
      let token = line[i..<stop]
      let isColour = token.len in {7, 9} and token[1..^1].allCharsInSet(HexDigits)
      if not isColour: return line[0..<i].strip
    inc i
  line.strip

proc parseColour(text: string): Color =
  if text.len notin {7, 9} or text[0] != '#' or
      not text[1..^1].allCharsInSet(HexDigits):
    raise valueError("expected #RRGGBB or #RRGGBBAA colour")
  let alpha = if text.len == 9: parseHexInt(text[7..8]).cfloat / 255 else: 1.cfloat
  result = [parseHexInt(text[1..2]).cfloat / 255 * alpha,
    parseHexInt(text[3..4]).cfloat / 255 * alpha,
    parseHexInt(text[5..6]).cfloat / 255 * alpha, alpha]

proc parseModifier(name: string): uint32 =
  case name.toLowerAscii
  of "shift": modifierShift
  of "ctrl", "control": modifierCtrl
  of "alt", "mod1": modifierAlt
  of "mod3": modifierMod3
  of "super", "logo", "mod4": modifierSuper
  of "mod5": modifierMod5
  of "none": 0'u32
  else: raise valueError("unknown modifier '" & name & "'")

proc parseModifiers(text: string): uint32 =
  if text.len == 0: raise valueError("missing modifiers or keysym")
  if text.toLowerAscii == "none": return 0
  for name in text.split('+'):
    if name.len == 0: raise valueError("empty modifier")
    let flag = parseModifier(name)
    if flag == 0: raise valueError("none cannot be combined with modifiers")
    if (result and flag) != 0: raise valueError("duplicate modifier '" & name & "'")
    result = result or flag

proc parseBindingChord(chord: string): (uint32, uint32) =
  let parts = chord.split('+')
  if parts.len == 0 or parts[^1].len == 0:
    raise valueError("bindsym requires a keysym")
  if parts.len > 1:
    result[0] = parseModifiers(parts[0..^2].join("+"))
  let key = parts[^1]
  if key.toLowerAscii.startsWith("button"):
    raise valueError("pointer buttons are not supported by bindsym")
  result[1] = xkb_keysym_from_name(key.cstring, 1)
  if result[1] == 0: raise valueError("unknown keysym '" & key & "'")

proc addBinding(bindings: var seq[ConfigBinding]; binding: ConfigBinding) =
  for existing in bindings.mitems:
    if existing.modifiers == binding.modifiers and existing.keysym == binding.keysym:
      existing = binding
      return
  bindings.add(binding)

proc parseInteger(text, what: string): int =
  try:
    result = parseInt(text)
  except ValueError:
    raise valueError(what & " requires an integer")

proc int32Value(value: int; what: string): int =
  if value < low(int32).int or value > high(int32).int:
    raise valueError(what & " is outside the int32 range")
  value

proc parseMode(text: string): (int, int, int) =
  let at = text.find('@')
  let dimensions = if at < 0: text else: text[0..<at]
  let separator = dimensions.find('x')
  if separator <= 0 or separator + 1 >= dimensions.len or
      dimensions.find('x', separator + 1) >= 0:
    raise valueError("mode requires WIDTHxHEIGHT[@Hz]")
  let width = int32Value(parseInteger(dimensions[0..<separator], "mode width"), "mode width")
  let height = int32Value(parseInteger(dimensions[separator + 1..^1], "mode height"), "mode height")
  if width <= 0 or height <= 0: raise valueError("mode dimensions must be positive")
  var refresh = 0
  if at >= 0:
    var refreshText = text[at + 1 ..< text.len]
    if refreshText.toLowerAscii.endsWith("hz"):
      refreshText = refreshText[0 ..< refreshText.len - 2]
    if refreshText.len == 0: raise valueError("mode refresh is invalid")
    var rate: float
    try: rate = parseFloat(refreshText)
    except ValueError: raise valueError("mode refresh is invalid")
    if rate.classify in {fcNan, fcInf, fcNegInf} or rate < 0 or rate * 1000 > high(int32).float:
      raise valueError("mode refresh is invalid")
    refresh = int32Value(int(round(rate * 1000)), "mode refresh")
  (width, height, refresh)

proc parsePosition(arguments: seq[string]): (int, int) =
  if arguments.len == 0: raise valueError("position requires X Y")
  var joined = arguments.join(" ")
  var commas = 0
  for ch in joined:
    if ch == ',': inc commas
  if commas > 1: raise valueError("position requires X Y")
  joined = joined.replace(",", " ")
  let values = words(joined)
  if values.len != 2: raise valueError("position requires X Y")
  (int32Value(parseInteger(values[0], "position X"), "position X"),
    int32Value(parseInteger(values[1], "position Y"), "position Y"))

proc parsePercent(text, what: string; positive = false): float64 =
  if text.len < 2 or text[^1] != '%':
    raise valueError(what & " requires a percentage")
  let valueText = text[0 ..< text.len - 1]
  var value: float64
  try:
    value = parseFloat(valueText)
  except ValueError:
    raise valueError(what & " requires a finite percentage")
  if value.classify in {fcNan, fcInf, fcNegInf} or value < 0 or
      (positive and value <= 0):
    raise valueError(what & " requires a finite nonnegative percentage")
  value

proc addZone(zones: var seq[ZoneDef]; zone: ZoneDef) =
  for existing in zones.mitems:
    if existing.name == zone.name:
      existing = zone
      return
  zones.add(zone)

proc parseZone(arguments: string): ZoneDef =
  let values = words(arguments)
  if values.len != 5:
    raise valueError("zone requires NAME X% Y% WIDTH% HEIGHT%")
  let name = values[0]
  var invalidName = name.len == 0 or name.len > 63
  for ch in name:
    if ch <= ' ' or ch == '|':
      invalidName = true
  if invalidName:
    raise valueError("zone name must be 1..63 bytes without whitespace or '|'")
  result = ZoneDef(name: name, x: parsePercent(values[1], "zone x"),
    y: parsePercent(values[2], "zone y"),
    width: parsePercent(values[3], "zone width", positive = true),
    height: parsePercent(values[4], "zone height", positive = true))
  if result.x + result.width > 100 or result.y + result.height > 100:
    raise valueError("zone must fit within the output area")
proc parseWindowRule(arguments: string): WindowRule =
  if arguments.len == 0 or arguments[0] != '[':
    raise valueError("for_window requires a bracketed criterion")
  var quote = '\0'
  var escaped = false
  var close = -1
  for i in 1 ..< arguments.len:
    let ch = arguments[i]
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'"', '\''}:
      quote = ch
    elif ch == ']':
      close = i
      break
  if close < 0 or quote != '\0':
    raise valueError("for_window has an unterminated criterion")
  for token in words(arguments[1 ..< close]):
    let equals = token.find('=')
    if equals <= 0 or equals + 1 >= token.len:
      raise valueError("for_window criteria require key=REGEX")
    let key = token[0 ..< equals]
    let pattern = token[equals + 1 ..^ 1]
    if key == "app_id":
      if result.hasAppId: raise valueError("duplicate app_id criterion")
      try: result.appId = re(pattern)
      except CatchableError: raise valueError("invalid app_id regex")
      result.hasAppId = true
    elif key == "title":
      if result.hasTitle: raise valueError("duplicate title criterion")
      try: result.title = re(pattern)
      except CatchableError: raise valueError("invalid title regex")
      result.hasTitle = true
    elif key == "class":
      if result.hasClass: raise valueError("duplicate class criterion")
      try: result.className = re(pattern)
      except CatchableError: raise valueError("invalid class regex")
      result.hasClass = true
    elif key == "instance":
      if result.hasInstance: raise valueError("duplicate instance criterion")
      try: result.instance = re(pattern)
      except CatchableError: raise valueError("invalid instance regex")
      result.hasInstance = true
    else:
      raise valueError("unsupported for_window criterion '" & key & "'")
  if not result.hasAppId and not result.hasTitle and not result.hasClass and not result.hasInstance:
    raise valueError("for_window requires app_id, title, class, or instance")
  result.command = arguments[close + 1 .. ^1].strip
  if result.command.len == 0: raise valueError("for_window requires a command")


proc parseScale(text: string): float32 =
  var value: float
  try: value = parseFloat(text)
  except ValueError: raise valueError("scale requires a finite positive number")
  if value.classify in {fcNan, fcInf, fcNegInf} or value <= 0 or value > high(float32).float:
    raise valueError("scale requires a finite positive number")
  result = value.float32
  if result <= 0: raise valueError("scale is too small for float32")

proc parseTransform(text: string): int =
  case text.toLowerAscii
  of "normal": 0
  of "90": 1
  of "180": 2
  of "270": 3
  of "flipped": 4
  of "flipped-90": 5
  of "flipped-180": 6
  of "flipped-270": 7
  else: raise valueError("unknown transform '" & text & "'")

proc outputIndex(outputs: var seq[OutputRule]; name: string): int =
  if name.len == 0 or name == "{" or name.contains(' ') or
      (name != "*" and name.contains('*')):
    raise valueError("output requires an exact name or '*'")
  for i, output in outputs:
    if output.name == name: return i
  outputs.add(OutputRule(name: name))
  outputs.high

proc applyOutputProperty(output: var OutputRule; property: string; arguments: seq[string]) =
  case property.toLowerAscii
  of "mode", "resolution":
    if arguments.len != 1: raise valueError(property & " requires WIDTHxHEIGHT[@Hz]")
    let mode = parseMode(arguments[0])
    output.hasMode = true
    output.width = mode[0]
    output.height = mode[1]
    output.refresh = mode[2]
  of "position", "pos":
    output.relativeTo = ""
    output.gap = 0
    if arguments.len > 0 and arguments[0] == "below":
      if arguments.len notin [2, 4] or
          (arguments.len == 4 and arguments[2] != "gap"):
        raise valueError("position below requires OUTPUT [gap PIXELS]")
      if output.name == "*" or arguments[1] in ["*", output.name, ""]:
        raise valueError("relative position requires two distinct exact output names")
      output.relativeTo = arguments[1]
      if arguments.len == 4:
        output.gap = int32Value(parseInteger(arguments[3], "position gap"), "position gap")
        if output.gap < 0: raise valueError("position gap must be nonnegative")
    else:
      let position = parsePosition(arguments)
      output.x = position[0]
      output.y = position[1]
    output.hasPosition = true
  of "scale":
    if arguments.len != 1: raise valueError("scale requires one value")
    output.hasScale = true
    output.scale = parseScale(arguments[0])
  of "transform":
    if arguments.len != 1: raise valueError("transform requires one value")
    output.hasTransform = true
    output.transform = parseTransform(arguments[0])
  of "default":
    if arguments.len != 0 or output.name == "*":
      raise valueError("default takes no arguments and requires an exact output name")
    output.isDefault = true
  of "enable":
    if arguments.len != 0: raise valueError("enable takes no arguments")
    output.hasEnabled = true
    output.enabled = true
  of "disable":
    if arguments.len != 0: raise valueError("disable takes no arguments")
    output.hasEnabled = true
    output.enabled = false
  else:
    raise valueError("unknown output property '" & property & "'")

proc parseClientColours(arguments: string): ClientColors =
  let values = words(arguments)
  if values.len != 1 and (values.len < 3 or values.len > 6):
    raise valueError("client colours require 1 or 3..6 colours")
  if values.len == 1:
    let colour = parseColour(values[0])
    return defaultClientColors(colour)
  result.border = parseColour(values[0])
  result.background = parseColour(values[1])
  result.text = parseColour(values[2])
  result.indicator = if values.len >= 4: parseColour(values[3]) else: result.border
  result.childBorder = if values.len >= 5: parseColour(values[4]) else: result.border
  result.titlebarBorder = if values.len == 6: parseColour(values[5]) else: result.border

proc validateOutputRules(outputs: seq[OutputRule]) =
  var defaults = 0
  for output in outputs:
    if output.isDefault: inc defaults
  if defaults > 1: raise valueError("only one output may be default")
  for origin in outputs:
    var reference = origin.relativeTo
    var depth = 0
    while reference.len != 0:
      if reference == origin.name or depth >= outputs.len:
        raise valueError("output position cycle involving '" & origin.name & "'")
      var next = ""
      for output in outputs:
        if output.name == reference:
          next = output.relativeTo
          break
      reference = next
      inc depth

proc unquoteSetValue(value: string): string =
  let values = words(value)
  if values.len == 1: values[0] else: value.strip

proc parseConfig*(text: string; path = "<config>"): RuntimeConfig =
  result = baseRuntimeConfig()
  var variables = initTable[string, string]()
  var blockIndex = -1
  var blockLine = 0
  var lineNumber = 0
  var defaultZoneName: string
  var defaultZoneLine = 0
  for rawLine in text.splitLines:
    inc lineNumber
    let line = stripComment(rawLine)
    if line.len == 0: continue
    try:
      if blockIndex >= 0:
        if line == "}":
          blockIndex = -1
          continue
        if line.contains('}'):
          raise valueError("output block closing brace must be on its own line")
        let expanded = expandVariables(line, variables)
        var position = 0
        let property = takeWord(expanded, position)
        let arguments = words(expanded[position..<expanded.len])
        if property.len == 0: raise valueError("empty output property")
        applyOutputProperty(result.outputs[blockIndex], property, arguments)
        validateOutputRules(result.outputs)
        continue

      if line == "}": raise valueError("unexpected '}'")
      var position = 0
      let directive = takeWord(line, position)
      let rawRemainder = line[position..<line.len].strip
      let remainder = expandVariables(rawRemainder, variables)
      if directive.len == 0: continue
      case directive
      of "set":
        var setPosition = 0
        let name = takeWord(rawRemainder, setPosition)
        if name.len < 2 or name[0] != '$' or not isVariableStart(name[1]) or
            not name[1..^1].allCharsInSet(Letters + Digits + {'_' }):
          raise valueError("set requires a $variable name")
        let value = rawRemainder[setPosition..<rawRemainder.len].strip
        if value.len == 0: raise valueError("set requires a value")
        variables[name] = unquoteSetValue(expandVariables(value, variables))
      of "bindsym":
        var bindPosition = 0
        let chord = takeWord(remainder, bindPosition)
        let command = remainder[bindPosition..<remainder.len].strip
        if chord.len == 0 or command.len == 0:
          raise valueError("bindsym requires a keysym and command")
        let parsed = parseBindingChord(chord)
        result.bindings.addBinding(ConfigBinding(modifiers: parsed[0], keysym: parsed[1],
          command: command, location: path & ":" & $lineNumber))
      of "font":
        var font = words(remainder).join(" ")
        if font.startsWith("pango:"):
          font = if font.len > 6: font[6..^1] else: ""
        if font.strip.len == 0:
          raise valueError("font requires a Pango font description")
        result.font = font
      of "titlebars", "sway_ipc_restricted", "wayland_protocols_restricted":
        let values = words(remainder)
        if values.len != 1 or values[0] notin ["on", "off"]:
          raise valueError(directive & " requires on or off")
        let enabled = values[0] == "on"
        case directive
        of "titlebars": result.titlebars = enabled
        of "sway_ipc_restricted": result.swayIpcRestricted = enabled
        else: result.waylandProtocolsRestricted = enabled

      of "floating_modifier":
        let values = words(remainder)
        if values.len != 1: raise valueError("floating_modifier requires one modifier list")
        result.floatingModifiers = parseModifiers(values[0])
      of "layout":
        let values = words(remainder)
        if values.len != 1 or values[0] notin ["monocle", "zones"]:
          raise valueError("layout requires monocle or zones")
        result.layout = values[0]
      of "snap_distance":
        let values = words(remainder)
        if values.len != 1:
          raise valueError("snap_distance requires an integer")
        let distance = int32Value(parseInteger(values[0], "snap_distance"), "snap_distance")
        if distance < 0: raise valueError("snap_distance must be nonnegative")
        result.snapDistance = distance
      of "zone":
        result.zones.addZone(parseZone(remainder))
      of "default_zone":
        let values = words(remainder)
        if values.len != 1 or values[0].len == 0:
          raise valueError("default_zone requires one zone name")
        defaultZoneName = values[0]
        defaultZoneLine = lineNumber
      of "for_window":
        var rule = parseWindowRule(remainder)
        rule.location = path & ":" & $lineNumber
        result.rules.add(rule)
      of "exec":
        if remainder.len == 0: raise valueError("exec requires a command")
        result.startup.add StartupCommand(command: "exec " & remainder,
          location: path & ":" & $lineNumber)
      of "wayland_client":
        let profile = parseWaylandClient(remainder)
        for previous in result.waylandClients:
          if previous.name == profile.name: raise valueError("duplicate wayland_client '" & profile.name & "'")
        result.waylandClients.add profile
      of "launch":
        result.startup.add StartupCommand(command: "launch " & remainder,
          location: path & ":" & $lineNumber)
      of "client.focused":
        result.focusedDecoration = parseClientColours(remainder)
        result.focused = result.focusedDecoration.border
      of "client.unfocused":
        result.unfocusedDecoration = parseClientColours(remainder)
        result.unfocused = result.unfocusedDecoration.border
      of "client.urgent":
        result.urgentDecoration = parseClientColours(remainder)
        result.urgent = result.urgentDecoration.border
      of "client.background":
        let values = words(remainder)
        if values.len != 1: raise valueError("client.background requires one colour")
        result.background = parseColour(values[0])
      of "fullscreen_background":
        let values = words(remainder)
        if values.len != 1: raise valueError("fullscreen_background requires one colour")
        result.fullscreen = parseColour(values[0])
      of "output":
        let values = words(remainder)
        if values.len < 2: raise valueError("output requires NAME and a property")
        let index = outputIndex(result.outputs, values[0])
        if values[1] == "{":
          if values.len != 2: raise valueError("output block opener has extra arguments")
          blockIndex = index
          blockLine = lineNumber
        else:
          applyOutputProperty(result.outputs[index], values[1],
            if values.len > 2: values[2..^1] else: @[])
          validateOutputRules(result.outputs)
      else:
        raise valueError("unknown directive '" & directive & "'")
    except CatchableError as error:
      raise newException(ConfigError, path & ":" & $lineNumber & ": " & error.msg)
  if blockIndex >= 0:
    raise newException(ConfigError, path & ":" & $blockLine & ": unterminated output block")
  if result.zones.len == 0:
    result.zones = defaultZones()
  if defaultZoneLine != 0:
    result.defaultZoneIndex = zoneIndex(result.zones, defaultZoneName)
    if result.defaultZoneIndex < 0:
      raise newException(ConfigError, path & ":" & $defaultZoneLine &
        ": default_zone names an unknown zone '" & defaultZoneName & "'")

proc matches*(rule: WindowRule; window: WindowProperties): bool =
  (not rule.hasAppId or find(window.appId, rule.appId) >= 0) and
    (not rule.hasTitle or find(window.title, rule.title) >= 0) and
    (not rule.hasClass or (window.isXwayland and find(window.className, rule.className) >= 0)) and
    (not rule.hasInstance or (window.isXwayland and find(window.instance, rule.instance) >= 0))
