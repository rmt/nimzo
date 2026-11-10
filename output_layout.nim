# SPDX-License-Identifier: 0BSD

## Output configuration and relative placement, independent of Wayland objects.
import std/[math, options, strutils, tables]

type
  OutputError* = object of ValueError
  Placement* = enum
    positionUnchanged, positionAbsolute, positionLeft, positionRight,
    positionAbove, positionBelow
  OutputMode* = object
    width*, height*, refresh*: int32
  OutputRule* = object
    name*, location*: string
    placement*: Placement
    reference*: string
    x*, y*, gap*: int32
    mode*: Option[OutputMode]
    scale*, transform*: Option[int32]
    enabled*, adaptiveSync*: Option[bool]
  OutputState* = object
    name*: string
    enabled*, adaptiveSync*: bool
    x*, y*: int32
    mode*: OutputMode
    scale*, transform*: int32 # wl_fixed scale, 256 = 1.0

proc invalid(message: string) {.noreturn.} =
  raise newException(OutputError, message)

proc integer(text: string; positive = false): int32 =
  let value = parseBiggestInt(text)
  if value < low(int32) or value > high(int32) or (positive and value <= 0):
    invalid("integer out of range: " & text)
  value.int32

proc finitePositive(text: string): float =
  result = parseFloat(text)
  if result.classify in {fcNan, fcInf, fcNegInf} or result <= 0:
    invalid("expected a positive finite number, got '" & text & "'")

proc parseOutputMode(text: string): OutputMode =
  let parts = text.toLowerAscii.split('@')
  if parts.len notin 1..2: invalid("expected WIDTHxHEIGHT[@HZ]")
  let size = parts[0].split('x')
  if size.len != 2: invalid("expected WIDTHxHEIGHT[@HZ]")
  result.width = integer(size[0], positive = true)
  result.height = integer(size[1], positive = true)
  if parts.len == 2:
    var hz = parts[1]
    hz.removeSuffix("hz")
    let refresh = finitePositive(hz) * 1000
    if refresh > high(int32).float or refresh < 1:
      invalid("refresh rate is out of range")
    result.refresh = round(refresh).int32

proc outputProperty*(rule: var OutputRule; name: string; arguments: seq[string]) =
  case name
  of "position", "pos":
    if arguments.len == 0: invalid("position requires coordinates or a direction and output name")
    let direction = arguments[0]
    if direction in ["left-of", "right-of", "above", "below"]:
      if arguments.len notin {2, 4} or
          (arguments.len == 4 and arguments[2] != "gap"):
        invalid("expected position DIRECTION OUTPUT [gap PIXELS]")
      rule.placement = case direction
        of "left-of": positionLeft
        of "right-of": positionRight
        of "above": positionAbove
        else: positionBelow
      rule.reference = arguments[1]
      if rule.reference.len == 0 or not rule.reference.allCharsInSet(Letters + Digits + {'-'}):
        invalid("relative position requires an exact reference output name")
      rule.gap = if arguments.len == 4: integer(arguments[3]) else: 0
      if rule.gap < 0: invalid("output gap must not be negative")
    else:
      if arguments.len != 2: invalid("expected position X Y")
      rule.placement = positionAbsolute
      rule.reference = ""
      rule.x = integer(arguments[0])
      rule.y = integer(arguments[1])
  of "resolution", "mode":
    if arguments.len != 1: invalid("expected resolution WIDTHxHEIGHT[@HZ]")
    rule.mode = some(parseOutputMode(arguments[0]))
  of "scale":
    if arguments.len != 1: invalid("scale requires a number")
    let scale = finitePositive(arguments[0]) * 256
    if scale < 1 or scale > high(int32).float:
      invalid("output scale is out of range")
    rule.scale = some(round(scale).int32)
  of "transform":
    if arguments.len != 1: invalid("transform requires a value")
    let transform = ["normal", "90", "180", "270", "flipped", "flipped-90",
                     "flipped-180", "flipped-270"].find(arguments[0])
    if transform < 0: invalid("unknown output transform '" & arguments[0] & "'")
    rule.transform = some(transform.int32)
  of "adaptive_sync":
    if arguments.len != 1 or arguments[0] notin ["on", "off"]:
      invalid("adaptive_sync expects on or off")
    rule.adaptiveSync = some(arguments[0] == "on")
  of "enable", "disable":
    if arguments.len != 0: invalid(name & " does not accept arguments")
    rule.enabled = some(name == "enable")
  else:
    invalid("unsupported output property '" & name & "'")

proc validateOutputRules*(rules: seq[OutputRule]) =
  var indices = initTable[string, int]()
  for i, rule in rules: indices[rule.name] = i
  var visits = newSeq[int](rules.len)
  proc visit(i: int) =
    if visits[i] == 1:
      invalid(rules[i].location & ": circular output dependency involving '" & rules[i].name & "'")
    if visits[i] == 2: return
    visits[i] = 1
    let rule = rules[i]
    if rule.placement in {positionLeft, positionRight, positionAbove, positionBelow}:
      if rule.name == rule.reference:
        invalid(rule.location & ": output '" & rule.name & "' cannot be relative to itself")
      if indices.hasKey(rule.reference): visit(indices[rule.reference])
    visits[i] = 2
  for i in 0..<rules.len: visit(i)

proc logicalSize*(state: OutputState): tuple[width, height: int32] =
  if state.scale <= 0 or state.mode.width <= 0 or state.mode.height <= 0:
    invalid("output '" & state.name & "' has no usable mode/scale yet")
  var width = state.mode.width.int64
  var height = state.mode.height.int64
  if (state.transform mod 2) != 0: swap(width, height)
  width = width * 256 div state.scale
  height = height * 256 div state.scale
  if width <= 0 or height <= 0 or width > high(int32) or height > high(int32):
    invalid("logical dimensions of output '" & state.name & "' are out of range")
  (width.int32, height.int32)

proc coordinate(value: int64): int32 =
  if value < low(int32) or value > high(int32): invalid("relative output position is out of range")
  value.int32

proc resolveOutputs*(rules: seq[OutputRule]; current: seq[OutputState]): seq[OutputState] =
  validateOutputRules(rules)
  # Copy: changing a candidate must never mutate the live snapshot on failure.
  var planned = newSeq[OutputState](current.len)
  var indices = initTable[string, int]()
  var activeRules = initTable[string, OutputRule]()
  for i, state in current:
    planned[i] = state
    indices[state.name] = i
  for rule in rules:
    activeRules[rule.name] = rule
    if not indices.hasKey(rule.name): continue # Disconnected configured output.
    let i = indices[rule.name]
    planned[i].enabled = rule.enabled.get(true)
    if not planned[i].enabled: continue
    if rule.mode.isSome:
      let mode = rule.mode.get
      if mode.width != planned[i].mode.width or mode.height != planned[i].mode.height or mode.refresh != 0:
        planned[i].mode = mode
    if rule.scale.isSome: planned[i].scale = rule.scale.get
    if rule.transform.isSome: planned[i].transform = rule.transform.get
    if rule.adaptiveSync.isSome: planned[i].adaptiveSync = rule.adaptiveSync.get
  var visits = newSeq[int](planned.len)
  proc visit(i: int) =
    if visits[i] == 2: return
    if visits[i] == 1: invalid("circular output dependency")
    visits[i] = 1
    if planned[i].enabled and activeRules.hasKey(planned[i].name):
      let rule = activeRules[planned[i].name]
      case rule.placement
      of positionUnchanged: discard
      of positionAbsolute:
        planned[i].x = rule.x
        planned[i].y = rule.y
      else:
        if not indices.hasKey(rule.reference):
          invalid(rule.location & ": reference output '" & rule.reference & "' is not connected")
        let reference = indices[rule.reference]
        if not planned[reference].enabled:
          invalid(rule.location & ": reference output '" & rule.reference & "' is disabled")
        visit(reference)
        let ownSize = planned[i].logicalSize
        let referenceSize = planned[reference].logicalSize
        let x = planned[reference].x.int64
        let y = planned[reference].y.int64
        case rule.placement
        of positionLeft:
          planned[i].x = coordinate(x - ownSize.width - rule.gap)
          planned[i].y = coordinate(y)
        of positionRight:
          planned[i].x = coordinate(x + referenceSize.width + rule.gap)
          planned[i].y = coordinate(y)
        of positionAbove:
          planned[i].x = coordinate(x)
          planned[i].y = coordinate(y - ownSize.height - rule.gap)
        of positionBelow:
          planned[i].x = coordinate(x)
          planned[i].y = coordinate(y + referenceSize.height + rule.gap)
        else: discard
    visits[i] = 2
  for i in 0..<planned.len: visit(i)
  for state in planned:
    if state.enabled:
      let size = state.logicalSize
      discard coordinate(state.x.int64 + size.width)
      discard coordinate(state.y.int64 + size.height)
  result = planned
