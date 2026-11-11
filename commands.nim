# SPDX-License-Identifier: 0BSD

import std/[os, posix, strutils, sequtils]

type
  CommandKind* = enum
    cmdExec, cmdClose, cmdFocusNext, cmdMove, cmdResize, cmdExit, cmdReload,
    cmdWorkspace, cmdMoveWorkspaceContainer, cmdFocusOutput,
    cmdMoveOutputContainer, cmdMoveWorkspaceOutput, cmdMoveZoneContainer,
    cmdFixedSize, cmdFullscreen, cmdMinimize, cmdRestore, cmdCycleZone

  Command* = object
    kind*: CommandKind
    shell*: string
    target*: string

  CommandResult* = object
    success*: bool
    error*: string
    parseError*: bool

  CommandRequest* = object
    command*: Command
    parseError*: string

  CommandContext* = object
    close*, focusNext*, move*, resize*, exit*, reload*, minimize*, restore*:
      proc (): CommandResult {.closure.}
    fullscreen*: proc (target: string): CommandResult {.closure.}
    workspace*, moveWorkspaceContainer*, focusOutput*, moveOutputContainer*,
      moveWorkspaceOutput*, moveZoneContainer*, fixedSize*, cycleZone*:
      proc (target: string): CommandResult {.closure.}

proc commandSuccess*(): CommandResult =
  CommandResult(success: true)

proc commandFailure*(message: string; parseError = false): CommandResult =
  CommandResult(success: false, error: message, parseError: parseError)

proc takeWord*(text: string; position: var int): string =
  ## Read one configuration word, removing quoting but not expanding anything.
  while position < text.len and text[position] in Whitespace:
    inc position
  var quote = '\0'
  while position < text.len:
    let ch = text[position]
    inc position
    if ch == '\\' and quote != '\'':
      if position == text.len:
        raise newException(ValueError, "trailing backslash")
      if quote == '"' and text[position] notin {'"', '\\', '$', '`'}:
        result.add('\\')
      result.add(text[position])
      inc position
    elif quote != '\0':
      if ch == quote: quote = '\0'
      else: result.add(ch)
    elif ch in {'\'', '"'}:
      quote = ch
    elif ch in Whitespace:
      break
    else:
      result.add(ch)
  if quote != '\0':
    raise newException(ValueError, "unterminated quote")

proc words*(text: string): seq[string] =
  var position = 0
  while position < text.len:
    if text[position..^1].strip.len == 0: break
    result.add(takeWord(text, position))

proc splitCommandParts(text: string; allowNewline: bool;
    parseError: var string): seq[string] =
  var quote = '\0'
  var escaped = false
  var start = 0
  for i, ch in text:
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'\'', '"'}:
      quote = ch
    elif ch in {',', ';'} or (allowNewline and ch == '\n'):
      let part = text[start..<i].strip
      if part.len == 0:
        parseError = "empty command"
        return
      result.add(part)
      start = i + 1
  if quote != '\0' or escaped:
    parseError = "unterminated quote or escape"
    return
  let last = text[start..^1].strip
  if last.len == 0:
    parseError = "empty command"
    return
  result.add(last)

proc commandParts(text: string): seq[string] =
  var parseError: string
  result = splitCommandParts(text, false, parseError)
  if parseError.len != 0:
    raise newException(ValueError, parseError)

proc normalizePositiveInteger(value: string): string =
  if value.len == 0:
    raise newException(ValueError, "workspace number requires a positive integer")
  for ch in value:
    if ch notin {'0'..'9'}:
      raise newException(ValueError, "workspace number requires a positive integer")
  var first = 0
  while first < value.len and value[first] == '0':
    inc first
  if first == value.len:
    raise newException(ValueError, "workspace number must be positive")
  result = value[first..^1]

proc requireNoArguments(text: string; position: int; commandName: string) =
  if position < text.len and text[position..^1].strip.len != 0:
    raise newException(ValueError, "'" & commandName & "' does not accept these arguments")

proc parseWorkspaceTarget(arguments: string): string =
  var firstPosition = 0
  while firstPosition < arguments.len and arguments[firstPosition] in Whitespace:
    inc firstPosition
  var firstQuoted = firstPosition < arguments.len and
    arguments[firstPosition] in {'\'', '"'}
  var position = 0
  var first = takeWord(arguments, position)
  if first.len == 0:
    raise newException(ValueError, "workspace requires a target")
  if first == "--no-auto-back-and-forth" and not firstQuoted:
    firstPosition = position
    while firstPosition < arguments.len and arguments[firstPosition] in Whitespace:
      inc firstPosition
    firstQuoted = firstPosition < arguments.len and
      arguments[firstPosition] in {'\'', '"'}
    first = takeWord(arguments, position)
    if first.len == 0:
      raise newException(ValueError, "workspace requires a target")
  if first == "number" and not firstQuoted:
    let number = takeWord(arguments, position)
    if number.len == 0:
      raise newException(ValueError, "workspace number requires a target")
    let colon = number.find(':')
    let prefix = if colon < 0: number else: number[0..<colon]
    result = normalizePositiveInteger(prefix)
    if colon >= 0:
      result.add(number[colon..^1])
  else:
    result = first
    var onlyDigits = not firstQuoted
    for ch in result:
      if ch notin {'0'..'9'}:
        onlyDigits = false
        break
    if onlyDigits:
      result = normalizePositiveInteger(result)
  requireNoArguments(arguments, position, "workspace")

proc parseDirection(arguments: string; commandName: string; allowPrev = false): string =
  var position = 0
  result = takeWord(arguments, position)
  if result notin ["left", "right", "up", "down"] and not (allowPrev and result == "prev"):
    let choices = if allowPrev: "left, right, up, down, or prev" else: "left, right, up, or down"
    raise newException(ValueError, commandName & " requires " & choices)
  requireNoArguments(arguments, position, commandName)

proc parseZoneTarget(arguments: string; commandName: string): string =
  var position = 0
  result = takeWord(arguments, position)
  if result.len == 0:
    raise newException(ValueError, commandName & " requires a zone name")
  requireNoArguments(arguments, position, commandName)

proc parseCycleTarget(arguments: string): string =
  var position = 0
  result = takeWord(arguments, position)
  if result.len == 0:
    raise newException(ValueError, "cycle-zone requires nonempty zone names")
  requireNoArguments(arguments, position, "cycle-zone")
  let names = result.split('|')
  if names.len == 0 or names.anyIt(it.len == 0):
    raise newException(ValueError, "cycle-zone requires nonempty pipe-separated zone names")

proc parseMoveCommand(arguments: string; command: var Command) =
  if arguments.len == 0:
    command.kind = cmdMove
    return
  var position = 0
  let first = takeWord(arguments, position)
  if first != "container" and first != "workspace":
    raise newException(ValueError, "unsupported move syntax")
  let to = takeWord(arguments, position)
  if to != "to":
    raise newException(ValueError, "move requires 'to'")
  let destination = takeWord(arguments, position)
  if destination notin ["workspace", "output", "zone"]:
    raise newException(ValueError, "move destination must be workspace, output, or zone")
  let rest = if position < arguments.len: arguments[position..^1].strip else: ""
  if first == "container" and destination == "workspace":
    command.kind = cmdMoveWorkspaceContainer
    command.target = parseWorkspaceTarget(rest)
  elif first == "container" and destination == "output":
    command.kind = cmdMoveOutputContainer
    command.target = parseDirection(rest, "move container to output")
  elif first == "workspace" and destination == "output":
    command.kind = cmdMoveWorkspaceOutput
    command.target = parseDirection(rest, "move workspace to output")
  elif first == "container" and destination == "zone":
    command.kind = cmdMoveZoneContainer
    command.target = parseZoneTarget(rest, "move container to zone")
  else:
    raise newException(ValueError, "unsupported move syntax")

proc parseCommandPart(part: string): Command =
  var position = 0
  let name = takeWord(part, position)
  let arguments = if position < part.len: part[position..^1].strip else: ""
  case name
  of "exec":
    result.kind = cmdExec
    result.shell = arguments
    var flagPosition = 0
    if takeWord(result.shell, flagPosition) == "--no-startup-id":
      result.shell = result.shell[flagPosition..^1].strip
    if result.shell.len == 0:
      raise newException(ValueError, "exec requires a shell command")
    # Sway permits a whole shell command to be quoted to protect separators.
    if result.shell[0] in {'\'', '"'}:
      var endPosition = 0
      let unquoted = takeWord(result.shell, endPosition)
      if result.shell[endPosition..^1].strip.len == 0:
        result.shell = unquoted
    if result.shell.len == 0:
      raise newException(ValueError, "exec requires a shell command")
  of "kill", "close":
    result.kind = cmdClose
    requireNoArguments(part, position, name)
  of "focus":
    if arguments == "next":
      result.kind = cmdFocusNext
    else:
      var focusPosition = 0
      if takeWord(arguments, focusPosition) != "output":
        raise newException(ValueError, "focus supports 'next' or 'output DIRECTION'")
      result.kind = cmdFocusOutput
      result.target = parseDirection(
        if focusPosition < arguments.len: arguments[focusPosition..^1].strip else: "",
        "focus output", allowPrev = true)
  of "workspace":
    result.kind = cmdWorkspace
    result.target = parseWorkspaceTarget(arguments)
  of "move":
    parseMoveCommand(arguments, result)
  of "fixedSize":
    var fixedPosition = 0
    result.kind = cmdFixedSize
    result.target = takeWord(arguments, fixedPosition)
    if result.target notin ["on", "off", "toggle"]:
      raise newException(ValueError, "fixedSize requires on, off, or toggle")
    requireNoArguments(arguments, fixedPosition, name)
  of "fullscreen":
    var fullscreenPosition = 0
    result.kind = cmdFullscreen
    if arguments.len == 0:
      result.target = "toggle"
    else:
      result.target = takeWord(arguments, fullscreenPosition)
      if result.target notin ["enable", "disable", "toggle"]:
        raise newException(ValueError, "fullscreen requires enable, disable, or toggle")
      requireNoArguments(arguments, fullscreenPosition, name)
  of "minimize":
    result.kind = cmdMinimize
    requireNoArguments(part, position, name)
  of "restore":
    result.kind = cmdRestore
    requireNoArguments(part, position, name)
  of "cycle-zone":
    result.kind = cmdCycleZone
    result.target = parseCycleTarget(arguments)
  of "resize":
    result.kind = cmdResize
    requireNoArguments(part, position, name)
  of "exit":
    result.kind = cmdExit
    requireNoArguments(part, position, name)
  of "reload":
    result.kind = cmdReload
    requireNoArguments(part, position, name)
  else:
    raise newException(ValueError, "unsupported command '" & name & "'")

proc parseCommands*(text: string): seq[Command] =
  for part in commandParts(text):
    result.add(parseCommandPart(part))

proc parseIpcCommands*(text: string): seq[CommandRequest] =
  var parseError: string
  let parts = splitCommandParts(text, true, parseError)
  for part in parts:
    try:
      result.add(CommandRequest(command: parseCommandPart(part)))
    except ValueError as error:
      result.add(CommandRequest(parseError: error.msg))
      return
  if parseError.len != 0:
    result.add(CommandRequest(parseError: parseError))

proc spawnShell(shell: string): CommandResult =
  # Prepare everything before fork; the child only calls async-signal-safe APIs.
  var arguments = [cstring("/bin/sh"), cstring("-c"), shell.cstring, cstring(nil)]
  var childSignal: Sigaction
  childSignal.sa_handler = SIG_DFL
  discard sigemptyset(childSignal.sa_mask)
  let pid = fork()
  if pid == 0:
    # SIG_IGN survives exec. Image loaders and other descendants must be able
    # to wait for their own children instead of inheriting our auto-reaping.
    discard sigaction(SIGCHLD, childSignal)
    discard execv(arguments[0], cast[cstringArray](addr arguments[0]))
    exitnow(127)
  elif pid < 0:
    return commandFailure("failed to spawn command: " & osErrorMsg(osLastError()))
  commandSuccess()

proc execute*(command: Command; context: CommandContext): CommandResult =
  case command.kind
  of cmdExec:
    return spawnShell(command.shell)
  of cmdWorkspace:
    if context.workspace.isNil:
      return commandFailure("workspace command handler unavailable")
    return context.workspace(command.target)
  of cmdMoveWorkspaceContainer:
    if context.moveWorkspaceContainer.isNil:
      return commandFailure("move workspace container command handler unavailable")
    return context.moveWorkspaceContainer(command.target)
  of cmdFocusOutput:
    if context.focusOutput.isNil:
      return commandFailure("focus output command handler unavailable")
    return context.focusOutput(command.target)
  of cmdMoveOutputContainer:
    if context.moveOutputContainer.isNil:
      return commandFailure("move container to output command handler unavailable")
    return context.moveOutputContainer(command.target)
  of cmdMoveWorkspaceOutput:
    if context.moveWorkspaceOutput.isNil:
      return commandFailure("move workspace to output command handler unavailable")
    return context.moveWorkspaceOutput(command.target)
  of cmdMoveZoneContainer:
    if context.moveZoneContainer.isNil:
      return commandFailure("move container to zone command handler unavailable")
    return context.moveZoneContainer(command.target)
  of cmdFixedSize:
    if context.fixedSize.isNil:
      return commandFailure("fixedSize command handler unavailable")
    return context.fixedSize(command.target)
  of cmdFullscreen:
    if context.fullscreen.isNil:
      return commandFailure("fullscreen command handler unavailable")
    return context.fullscreen(command.target)
  of cmdMinimize:
    if context.minimize.isNil:
      return commandFailure("minimize command handler unavailable")
    return context.minimize()
  of cmdRestore:
    if context.restore.isNil:
      return commandFailure("restore command handler unavailable")
    return context.restore()
  of cmdCycleZone:
    if context.cycleZone.isNil:
      return commandFailure("cycle-zone command handler unavailable")
    return context.cycleZone(command.target)
  of cmdClose:
    if context.close.isNil:
      return commandFailure("close command handler unavailable")
    return context.close()
  of cmdFocusNext:
    if context.focusNext.isNil:
      return commandFailure("focus next command handler unavailable")
    return context.focusNext()
  of cmdMove:
    if context.move.isNil:
      return commandFailure("move command handler unavailable")
    return context.move()
  of cmdResize:
    if context.resize.isNil:
      return commandFailure("resize command handler unavailable")
    return context.resize()
  of cmdExit:
    if context.exit.isNil:
      return commandFailure("exit command handler unavailable")
    return context.exit()
  of cmdReload:
    if context.reload.isNil:
      return commandFailure("reload command handler unavailable")
    return context.reload()

