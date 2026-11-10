# SPDX-License-Identifier: 0BSD

import std/[os, strutils, tables]
import commands, output_layout

{.passC: staticExec("pkg-config --cflags xkbcommon").strip.}
{.passL: staticExec("pkg-config --libs xkbcommon").strip.}

proc xkb_keysym_from_name(name: cstring; flags: cint): uint32 {.importc, header: "xkbcommon/xkbcommon.h".}

type
  ConfigError* = object of CatchableError

  Color* = object
    r*, g*, b*, a*: uint8

  ClientColors* = object
    border*, background*, text*, indicator*, childBorder*: Color

  BindingKind* = enum
    bindingKey, bindingPointer

  Binding* = object
    kind*: BindingKind
    trigger*, modifiers*: uint32
    commands*: seq[Command]

  Config* = object
    font*: string
    focused*, unfocused*: ClientColors
    floatingModifiers*: uint32
    bindings*: seq[Binding]
    startup*: seq[Command]
    outputs*: seq[OutputRule]

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
  if arguments.len notin 3..5:
    raise newException(ValueError, "expected border background text [indicator [child_border]]")
  result.border = parseColor(arguments[0])
  result.background = parseColor(arguments[1])
  result.text = parseColor(arguments[2])
  result.indicator = if arguments.len >= 4: parseColor(arguments[3]) else: result.border
  result.childBorder = if arguments.len == 5: parseColor(arguments[4]) else: result.border

proc outputIndex(rules: var seq[OutputRule]; name, location: string): int =
  if name.len == 0 or not name.allCharsInSet(Letters + Digits + {'-'}):
    raise newException(ValueError, "output requires an exact connector name (wildcards are not supported)")
  for i, rule in rules:
    if rule.name == name: return i
  rules.add(OutputRule(name: name, location: location))
  rules.high

proc applyOutputProperty(rules: var seq[OutputRule]; index: int;
    name: string; arguments: seq[string]; location: string) =
  let previous = rules[index]
  var candidate = previous
  outputProperty(candidate, name, arguments)
  if name in ["position", "pos"]: candidate.location = location
  rules[index] = candidate
  if name notin ["position", "pos"]: return
  try:
    validateOutputRules(rules)
  except OutputError:
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

proc warnConfiguration(source: string; line: int; message: string) =
  stderr.writeLine("warning: ", source, ":", line, ": ", message)

proc parseConfig*(text: string; source = "<config>"): Config =
  let red = parseColor("#8B0000")
  let palette = ClientColors(border: red, background: red, text: parseColor("#FFFFFF"),
    indicator: red, childBorder: red)
  result = Config(font: "Sans 10", focused: palette, unfocused: palette, floatingModifiers: 64)
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
          applyOutputProperty(result.outputs, index, tokens[1], tokens[2..^1],
            source & ":" & $lineNumber)
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
