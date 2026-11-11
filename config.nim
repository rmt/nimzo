# SPDX-License-Identifier: 0BSD

import std/[os, strutils, tables, math, re]
import commands, output_layout, zones

{.passC: staticExec("pkg-config --cflags xkbcommon").strip.}
{.passL: staticExec("pkg-config --libs xkbcommon").strip.}

proc xkb_keysym_from_name(name: cstring; flags: cint): uint32 {.importc, header: "xkbcommon/xkbcommon.h".}

type
  ConfigError* = object of CatchableError

  Color* = object
    r*, g*, b*, a*: uint8

  ClientColors* = object
    border*, background*, text*, indicator*, childBorder*, titlebarBorder*: Color

  BindingKind* = enum
    bindingKey, bindingPointer

  Binding* = object
    kind*: BindingKind
    trigger*, modifiers*: uint32
    commands*: seq[Command]

  WindowRule = object
    appId, title: Regex
    hasAppId, hasTitle, fixedSize: bool

  Config* = object
    font*: string
    focused*, unfocused*: ClientColors
    floatingModifiers*: uint32
    bindings*: seq[Binding]
    startup*: seq[Command]
    outputs*: seq[OutputRule]
    layout*: LayoutMethod
    zones*: seq[Zone]
    rules: seq[WindowRule]
  Options* = object
    path*: string
    explicitPath*, validate*, help*: bool

const DefaultConfigText* = """
set $mod Mod4
set $term foot
font pango:Sans 10
floating_modifier $mod
bindsym $mod+space exec $term
bindsym Alt+x exec $term
bindsym $mod+q kill
bindsym $mod+n focus next
bindsym Alt+Tab focus next
bindsym $mod+Escape exit
bindsym Ctrl+Alt+BackSpace exit
bindsym $mod+Shift+r reload
"""

proc parseColor*(text: string): Color =
  if text.len notin {7, 9} or text[0] != '#' or
      not text[1..^1].allCharsInSet(HexDigits):
    raise newException(ValueError, "expected #RRGGBB or #RRGGBBAA, got '" & text & "'")
  result = Color(r: parseHexInt(text[1..2]).uint8,
    g: parseHexInt(text[3..4]).uint8, b: parseHexInt(text[5..6]).uint8, a: 255)
  if text.len == 9:
    result.a = parseHexInt(text[7..8]).uint8

proc pixel*(color: Color): uint32 =
  ## wl_shm ARGB8888 and Cairo both use native-endian, premultiplied pixels.
  (color.a.uint32 shl 24) or
    ((color.r.uint32 * color.a.uint32 div 255) shl 16) or
    ((color.g.uint32 * color.a.uint32 div 255) shl 8) or
    (color.b.uint32 * color.a.uint32 div 255)

proc rgba32*(color: Color): array[4, uint32] =
  for i, component in [color.r, color.g, color.b]:
    result[i] = (component.uint64 * color.a.uint64 * high(uint32).uint64 div 65025).uint32
  result[3] = color.a.uint32 * 0x01010101'u32

proc modifier(name: string): uint32 =
  case name.toLowerAscii
  of "shift": 1
  of "ctrl", "control": 4
  of "alt", "mod1": 8
  of "mod3": 32
  of "super", "logo", "mod4": 64
  of "mod5": 128
  else: raise newException(ValueError, "unknown modifier '" & name & "'")

proc parseModifiers*(text: string): uint32 =
  if text.toLowerAscii == "none": return 0
  for name in text.split('+'):
    let flag = modifier(name)
    if (result and flag) != 0:
      raise newException(ValueError, "duplicate modifier '" & name & "'")
    result = result or flag

proc parseBinding*(chord: string; commandText: string): Binding =
  let parts = chord.split('+')
  if parts.len > 1:
    result.modifiers = parseModifiers(parts[0..^2].join("+"))
  let key = parts[^1]
  if key.toLowerAscii.startsWith("button"):
    result.kind = bindingPointer
    case key.toLowerAscii
    of "button1": result.trigger = 0x110
    of "button2": result.trigger = 0x112
    of "button3": result.trigger = 0x111
    of "button8": result.trigger = 0x113
    of "button9": result.trigger = 0x114
    else: raise newException(ValueError, "unsupported pointer button '" & key & "'")
  else:
    result.kind = bindingKey
    result.trigger = xkb_keysym_from_name(key.cstring, 1) # XKB_KEYSYM_CASE_INSENSITIVE
    if result.trigger == 0:
      raise newException(ValueError, "unknown keysym '" & key & "'")
  result.commands = parseCommands(commandText)

proc addBinding(bindings: var seq[Binding]; binding: Binding) =
  for existing in bindings.mitems:
    if existing.kind == binding.kind and existing.modifiers == binding.modifiers and
        existing.trigger == binding.trigger:
      existing = binding
      return
  bindings.add(binding)

proc effectiveBindings*(config: Config): seq[Binding] =
  result = @[
    Binding(kind: bindingPointer, trigger: 0x110, modifiers: config.floatingModifiers,
      commands: @[Command(kind: cmdMove)]),
    Binding(kind: bindingPointer, trigger: 0x111, modifiers: config.floatingModifiers,
      commands: @[Command(kind: cmdResize)])]
  for binding in config.bindings:
    result.addBinding(binding)

proc stripComment(line: string): string =
  if line.strip.startsWith("#"): return ""
  var quote = '\0'
  var escaped = false
  for i, ch in line:
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'\'', '"'}:
      quote = ch
    elif ch == '#' and (i == 0 or line[i - 1] in Whitespace):
      var stop = i + 1
      while stop < line.len and line[stop] notin Whitespace: inc stop
      let token = line[i..<stop]
      if token.len notin {7, 9} or not token[1..^1].allCharsInSet(HexDigits):
        return line[0..<i].strip
  line.strip

proc variableChar(ch: char): bool = ch in Letters + Digits + {'_'}

proc expandVariables(text: string; variables: Table[string, string]): string =
  var i = 0
  while i < text.len:
    if text[i] == '\\' and i + 1 < text.len:
      result.add(text[i..i + 1])
      i += 2
    elif text[i] == '$':
      let start = i
      inc i
      while i < text.len and variableChar(text[i]): inc i
      let name = text[start..<i]
      result.add(variables.getOrDefault(name, name))
    else:
      result.add(text[i])
      inc i

proc unquote(text: string): string =
  result = text.strip
  if result.len > 0 and result[0] in {'\'', '"'}:
    var position = 0
    let value = takeWord(result, position)
    if result[position..^1].strip.len == 0: result = value

proc parseColors(text: string): ClientColors =
  let arguments = words(text)
  if arguments.len notin 3..6:
    raise newException(ValueError,
      "expected border background text [indicator [child_border [titlebar_border]]]")
  result.border = parseColor(arguments[0])
  result.background = parseColor(arguments[1])
  result.text = parseColor(arguments[2])
  result.indicator = if arguments.len >= 4: parseColor(arguments[3]) else: result.border
  result.childBorder = if arguments.len >= 5: parseColor(arguments[4]) else: result.border
  result.titlebarBorder = if arguments.len == 6: parseColor(arguments[5]) else: result.border

proc outputIndex(rules: var seq[OutputRule]; name, location: string): int =
  if name.len == 0 or not name.allCharsInSet(Letters + Digits + {'-'}):
    raise newException(ValueError, "output requires an exact connector name (wildcards are not supported)")
  for i, rule in rules:
    if rule.name == name: return i
  rules.add(OutputRule(name: name, location: location))
  rules.high

proc rejectDuplicateDefault(rules: seq[OutputRule]; index: int; candidate: OutputRule) =
  if not candidate.isDefault: return
  for i, rule in rules:
    if i != index and rule.isDefault:
      raise newException(ValueError, "only one output rule may be default")

proc applyOutputProperty(rules: var seq[OutputRule]; index: int;
    name: string; arguments: seq[string]; location: string) =
  let previous = rules[index]
  var candidate = previous
  outputProperty(candidate, name, arguments)
  if name in ["position", "pos"]: candidate.location = location
  rules[index] = candidate
  try:
    rejectDuplicateDefault(rules, index, candidate)
    if name in ["position", "pos"]:
      validateOutputRules(rules)
  except CatchableError:
    rules[index] = previous
    raise

proc applyInlineOutput(rules: var seq[OutputRule]; index: int;
    tokens: seq[string]; location: string) =
  let previous = rules[index]
  var candidate = previous
  let property = tokens[1]
  var validatesPositions = false
  if property == "default":
    outputProperty(candidate, "default", @[])
    if tokens.len > 2:
      let following = tokens[2]
      if following == "default":
        raise newException(ValueError, "duplicate default output property")
      let arguments = if tokens.len > 3: tokens[3..^1] else: @[]
      outputProperty(candidate, following, arguments)
      validatesPositions = following in ["position", "pos"]
  else:
    let arguments = if tokens.len > 2: tokens[2..^1] else: @[]
    outputProperty(candidate, property, arguments)
    validatesPositions = property in ["position", "pos"]
  if validatesPositions: candidate.location = location
  rules[index] = candidate
  try:
    rejectDuplicateDefault(rules, index, candidate)
    if validatesPositions: validateOutputRules(rules)
  except CatchableError:
    rules[index] = previous
    raise

proc blockDepth(line: string): int =
  var quote = '\0'
  var escaped = false
  for ch in line:
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'\'', '"'}:
      quote = ch
    elif ch == '{':
      inc result
    elif ch == '}':
      dec result

proc parsePercent(text, name: string; positive = false): float64 =
  if text.len < 2 or text[^1] != '%':
    raise newException(ValueError, name & " requires a percentage")
  let valueText = text[0..^2]
  try:
    result = parseFloat(valueText)
  except ValueError:
    raise newException(ValueError, name & " requires a finite percentage")
  if result.classify in {fcNan, fcInf, fcNegInf} or result < 0 or
      (positive and result <= 0):
    raise newException(ValueError, name & " requires a finite nonnegative percentage")

proc addZone(zones: var seq[Zone]; zone: Zone) =
  for existing in zones.mitems:
    if existing.name == zone.name:
      existing = zone
      return
  zones.add(zone)

proc parseZone(arguments: string): Zone =
  let tokens = words(arguments)
  if tokens.len != 5 or tokens[0].len == 0:
    raise newException(ValueError, "zone requires NAME X% Y% WIDTH% HEIGHT%")
  result = Zone(name: tokens[0],
    x: parsePercent(tokens[1], "zone x"),
    y: parsePercent(tokens[2], "zone y"),
    width: parsePercent(tokens[3], "zone width", positive = true),
    height: parsePercent(tokens[4], "zone height", positive = true))
  if result.x + result.width > 100.0 or result.y + result.height > 100.0:
    raise newException(ValueError, "zone must fit within the output area")

proc parseWindowRule(arguments: string): WindowRule =
  if arguments.len == 0 or arguments[0] != '[':
    raise newException(ValueError, "for_window requires a bracketed criterion")
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
    elif ch in {'\'', '"'}:
      quote = ch
    elif ch == ']':
      close = i
      break
  if close < 0 or quote != '\0':
    raise newException(ValueError, "for_window has an unterminated criterion")
  let selector = arguments[1..<close]
  let tokens = words(selector)
  if tokens.len == 0:
    raise newException(ValueError, "for_window requires app_id or title")
  for token in tokens:
    let equals = token.find('=')
    if equals <= 0 or equals + 1 >= token.len:
      raise newException(ValueError, "for_window criteria require key=REGEX")
    let key = token[0..<equals]
    let pattern = token[equals + 1..^1]
    if key == "app_id":
      if result.hasAppId: raise newException(ValueError, "duplicate app_id criterion")
      try: result.appId = re(pattern)
      except CatchableError: raise newException(ValueError, "invalid app_id regex")
      result.hasAppId = true
    elif key == "title":
      if result.hasTitle: raise newException(ValueError, "duplicate title criterion")
      try: result.title = re(pattern)
      except CatchableError: raise newException(ValueError, "invalid title regex")
      result.hasTitle = true
    else:
      raise newException(ValueError, "unsupported for_window criterion '" & key & "'")
  var position = close + 1
  let directive = takeWord(arguments, position)
  if directive != "fixedSize":
    raise newException(ValueError, "for_window supports fixedSize on|off")
  let value = takeWord(arguments, position)
  if value notin ["on", "off"] or (position < arguments.len and arguments[position..^1].strip.len != 0):
    raise newException(ValueError, "for_window supports fixedSize on|off")
  result.fixedSize = value == "on"

proc initialFixedSize*(config: Config; appId, title: string): bool =
  for rule in config.rules:
    if (not rule.hasAppId or find(appId, rule.appId) >= 0) and
        (not rule.hasTitle or find(title, rule.title) >= 0):
      result = rule.fixedSize

proc warnConfiguration(source: string; line: int; message: string) =
  stderr.writeLine("warning: ", source, ":", line, ": ", message)

proc parseConfig*(text: string; source = "<config>"): Config =
  let red = parseColor("#8B0000")
  let palette = ClientColors(border: red, background: red, text: parseColor("#FFFFFF"),
    indicator: red, childBorder: red, titlebarBorder: red)
  result = Config(font: "Sans 10", focused: palette, unfocused: palette, floatingModifiers: 64,
    layout: layoutZones)
  var variables = initTable[string, string]()
  var lineNumber = 0
  var blockOutput = -1
  var blockLine = 0
  var skippedDepth = 0
  var skippedLine = 0
  for rawLine in text.splitLines:
    inc lineNumber
    let line = stripComment(rawLine)
    if line.len == 0: continue
    if skippedDepth > 0:
      skippedDepth = max(0, skippedDepth + blockDepth(line))
      continue
    let outputCount = result.outputs.len
    try:
      var position = 0
      let directive = takeWord(line, position)
      let arguments = line[position..^1].strip
      if blockOutput >= 0:
        if directive == "}" and arguments.len == 0:
          blockOutput = -1
        else:
          applyOutputProperty(result.outputs, blockOutput, directive,
            words(expandVariables(arguments, variables)), source & ":" & $lineNumber)
        continue
      if directive == "set":
        position = 0
        let name = takeWord(arguments, position)
        if name.len < 2 or name[0] != '$' or not name[1..^1].allCharsInSet(Letters + Digits + {'_'}):
          raise newException(ValueError, "set requires a $variable name")
        let value = arguments[position..^1].strip
        if value.len == 0:
          raise newException(ValueError, "set requires a value")
        variables[name] = unquote(expandVariables(value, variables))
        continue
      let expanded = expandVariables(arguments, variables)
      case directive
      of "output":
        let tokens = words(expanded)
        if tokens.len < 2:
          raise newException(ValueError, "expected output NAME { or output NAME PROPERTY ARGUMENTS")
        let index = outputIndex(result.outputs, tokens[0], source & ":" & $lineNumber)
        if tokens[1] == "{" and tokens.len == 2:
          blockOutput = index
          blockLine = lineNumber
        else:
          applyInlineOutput(result.outputs, index, tokens, source & ":" & $lineNumber)
      of "font":
        var font = words(expanded).join(" ")
        if font.startsWith("pango:"): font = font[6..^1]
        if font.strip.len == 0:
          raise newException(ValueError, "font requires a Pango font description")
        result.font = font
      of "floating_modifier": result.floatingModifiers = parseModifiers(expanded)
      of "bindsym":
        position = 0
        let chord = takeWord(expanded, position)
        result.bindings.addBinding(parseBinding(chord, expanded[position..^1].strip))
      of "client.focused": result.focused = parseColors(expanded)
      of "client.unfocused": result.unfocused = parseColors(expanded)
      of "exec":
        let parsed = parseCommands("exec " & expanded)
        if parsed.len != 1:
          raise newException(ValueError, "quote shell commands containing commas or semicolons")
        result.startup.add(parsed[0])
      of "layout":
        if words(expanded) != @["zones"]:
          raise newException(ValueError, "layout supports only zones")
        result.layout = layoutZones
      of "zone":
        result.zones.addZone(parseZone(expanded))
      of "for_window":
        result.rules.add(parseWindowRule(expanded))
      else:
        raise newException(ValueError, "unsupported directive '" & directive & "'")
    except ValueError as error:
      result.outputs.setLen(outputCount)
      warnConfiguration(source, lineNumber, error.msg)
      skippedDepth = max(0, blockDepth(line))
      if skippedDepth > 0: skippedLine = lineNumber
  if blockOutput >= 0:
    warnConfiguration(source, blockLine, "unterminated output block")
  if skippedDepth > 0:
    warnConfiguration(source, skippedLine, "unterminated skipped configuration block")

proc defaultConfig*(): Config = parseConfig(DefaultConfigText, "<defaults>")

proc defaultConfigPath*(): string = getConfigDir() / "river" / "nimzo.config"

proc loadConfig*(path: string; allowMissing = false): Config =
  if allowMissing and not fileExists(path): return defaultConfig()
  try:
    result = parseConfig(readFile(path), path)
  except IOError, OSError:
    raise newException(ConfigError, path & ": " & getCurrentExceptionMsg())

proc parseOptions*(arguments: seq[string]): Options =
  result.path = defaultConfigPath()
  var i = 0
  while i < arguments.len:
    case arguments[i]
    of "-c", "--config":
      inc i
      if i == arguments.len or arguments[i].len == 0:
        raise newException(ConfigError, "--config requires a file path")
      result.path = absolutePath(expandTilde(arguments[i]))
      result.explicitPath = true
    of "--validate": result.validate = true
    of "-h", "--help": result.help = true
    else: raise newException(ConfigError, "unknown option '" & arguments[i] & "'")
    inc i
