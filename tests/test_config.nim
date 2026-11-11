# SPDX-License-Identifier: 0BSD

import std/[os, sequtils, tempfiles, unittest]
import ../[commands, config, zones]

suite "Sway-like configuration":
  test "defaults preserve the original bindings and add reload":
    let cfg = defaultConfig()
    check cfg.font == "Sans 10"
    check cfg.bindings[0].trigger == 0x20
    check cfg.bindings[0].commands[0].shell == "foot"

  test "variables, comments, font and colors":
    let cfg = parseConfig("""
# Comment with a color #badc0d
set $mod Mod4
set $term "ghostty --title 'My terminal'"
set $red #8b0000
set $background #202020
font pango:monospace 10 # comment
client.focused $red $background #ffffff $red $background
client.unfocused #111111 #222222 #aaaaaa
bindsym $mod+Return exec $term
bindsym Alt+x exec echo "$HOME" # Keep shell variables intact.
""")
    check cfg.font == "monospace 10"
    check cfg.focused.background.pixel == 0xff202020'u32
    check cfg.focused.border.rgba32 == [0x8b8b8b8b'u32, 0, 0, 0xffffffff'u32]
    check cfg.unfocused.text.pixel == 0xffaaaaaa'u32
    check cfg.bindings[0].modifiers == 64
    check cfg.bindings[0].trigger == 0xff0d
    check cfg.bindings[0].commands[0].shell == "ghostty --title 'My terminal'"
    check cfg.bindings[1].commands[0].shell == "echo \"$HOME\""

  test "variables are substituted once in definition order":
    let cfg = parseConfig("""
set $term foot
set $term $term --title demo
set $message '$HOME'
bindsym Alt+x exec $term "$message"
""")
    check cfg.bindings[0].commands[0].shell == "foot --title demo \"$HOME\""

  test "keysym lookup includes multimedia keys and modifier aliases":
    let binding = parseBinding("Control+Mod1+BackSpace", "exit")
    check binding.modifiers == 12
    check binding.trigger == 0xff08
    check parseBinding("XF86AudioLowerVolume", "exec volctl down").trigger == 0x1008ff11'u32
    check parseModifiers("Logo+Shift") == 65
    expect ValueError: discard parseModifiers("Mod4+Super")
    expect ValueError: discard parseBinding("Bogus+x", "exit")
    expect ValueError: discard parseBinding("Mod4+NotARealKeySym", "exit")

  test "pointer modifier and explicit pointer overrides":
    let cfg = parseConfig("""
floating_modifier Alt
bindsym Alt+button1 resize
bindsym Mod4+button3 move
""")
    let bindings = cfg.effectiveBindings
    check bindings.len == 3
    check bindings[0].kind == bindingPointer
    check bindings[0].modifiers == 8
    check bindings[0].trigger == 0x110
    check bindings[0].commands[0].kind == cmdResize
    check bindings[1].trigger == 0x111

  test "file bindings replace defaults and the last duplicate wins":
    let cfg = parseConfig("""
bindsym Alt+x exec foot
bindsym Alt+x exec ghostty
""")
    check cfg.bindings.len == 1
    check cfg.bindings[0].commands[0].shell == "ghostty"
    check parseConfig("").bindings.len == 0

  test "colors validate and premultiply alpha":
    let red = parseColor("#ff000080")
    check red.pixel == 0x80800000'u32
    check red.rgba32 == [0x80808080'u32, 0, 0, 0x80808080'u32]
    for invalid in ["red", "#fff", "#gg0000", "#1234567890"]:
      expect ValueError: discard parseColor(invalid)

  test "titlebar border is independent and omitted color follows the window border":
    for optional in ["", " #112233", " #112233 #445566"]:
      let cfg = parseConfig("client.focused #010203 #040506 #070809" & optional)
      check cfg.focused.titlebarBorder == cfg.focused.border
    let cfg = parseConfig("""
client.focused #010203 #040506 #070809 #112233 #445566 #ff000080
client.unfocused #101112 #131415 #161718 #191a1b #1c1d1e #202122
client.focused #ffffff #ffffff #ffffff #ffffff #ffffff invalid
""")
    check cfg.focused.titlebarBorder.pixel == 0x80800000'u32
    check cfg.focused.border.pixel == 0xff010203'u32
    check cfg.focused.childBorder.pixel == 0xff445566'u32
    check cfg.unfocused.titlebarBorder.pixel == 0xff202122'u32

  test "invalid lines warn, preserve state, and continue":
    let cfg = parseConfig("""
set $term foot
font pango:Before 10
font pango:
set $term
bindsym Alt+x exec $term
bindsym Alt+x exec 'unterminated
bindsym Alt+y exec echo later
client.focused #010203 #040506 #070809
client.focused nope nope nope
client.unfocused #101112 #131415 #161718
client.unfocused #xyz
unsupported feature
""", "recovery.conf")
    check cfg.font == "Before 10"
    check cfg.focused.background.pixel == 0xff040506'u32
    check cfg.unfocused.text.pixel == 0xff161718'u32
    check cfg.bindings.len == 2
    check cfg.bindings[0].commands[0].shell == "foot"
    check cfg.bindings[1].commands[0].shell == "echo later"

  test "startup exec is parsed but not executed while loading":
    let cfg = parseConfig("exec 'printf hello; printf world'\n")
    check cfg.startup.len == 1
    check cfg.startup[0].shell == "printf hello; printf world"

  test "load paths, missing files, and command-line options":
    let directory = createTempDir("nimzo-config-", "")
    defer: removeDir(directory)
    let path = directory / "config"
    expect ConfigError: discard loadConfig(path)
    writeFile(path, "bindsym Alt+x exec ghostty\n")
    check loadConfig(path).bindings[0].commands[0].shell == "ghostty"
    removeFile(path)
    let options = parseOptions(@["--config", path, "--validate"])
    check options.path == path
    check options.explicitPath
    check options.validate
    check parseOptions(@["--help"]).help
    expect ConfigError: discard parseOptions(@["-c"])
    expect ConfigError: discard parseOptions(@["--bogus"])

  test "XDG configuration directory is respected":
    let previous = getEnv("XDG_CONFIG_HOME")
    let existed = existsEnv("XDG_CONFIG_HOME")
    defer:
      if existed: putEnv("XDG_CONFIG_HOME", previous)
      else: delEnv("XDG_CONFIG_HOME")
    putEnv("XDG_CONFIG_HOME", "/tmp/nimzo-xdg")
    check defaultConfigPath() == "/tmp/nimzo-xdg/river/nimzo.config"

  test "unset XDG_CONFIG_HOME falls back to HOME/.config/river/nimzo.config":
    let previousXdg = getEnv("XDG_CONFIG_HOME")
    let hadXdg = existsEnv("XDG_CONFIG_HOME")
    let previousHome = getEnv("HOME")
    let hadHome = existsEnv("HOME")
    defer:
      if hadXdg: putEnv("XDG_CONFIG_HOME", previousXdg)
      else: delEnv("XDG_CONFIG_HOME")
      if hadHome: putEnv("HOME", previousHome)
      else: delEnv("HOME")
    delEnv("XDG_CONFIG_HOME")
    putEnv("HOME", "/tmp/nimzo-home")
    check defaultConfigPath() == "/tmp/nimzo-home/.config/river/nimzo.config"

suite "commands":

  test "workspace and output targets are parsed at command boundaries":
    let parsed = parseCommands(
      "workspace 007; workspace number 09:dev; workspace \"web west\"; " &
      "move container to workspace next; focus output left; " &
      "move container to output down; move workspace to output right; focus output prev")
    check parsed.mapIt(it.kind) == @[
      cmdWorkspace, cmdWorkspace, cmdWorkspace, cmdMoveWorkspaceContainer,
      cmdFocusOutput, cmdMoveOutputContainer, cmdMoveWorkspaceOutput, cmdFocusOutput]
    check parsed[0].target == "7"
    check parsed[1].target == "9:dev"
    check parsed[2].target == "web west"
    check parsed[3].target == "next"
    check parsed[4].target == "left"
    check parsed[5].target == "down"
    check parsed[6].target == "right"
    check parsed[7].target == "prev"
  test "workspace flags and IPC command boundaries are parsed":
    let parsed = parseCommands(
      "workspace --no-auto-back-and-forth number 007; " &
      "workspace --no-auto-back-and-forth \"web west\"")
    check parsed.len == 2
    check parsed[0].target == "7"
    check parsed[1].target == "web west"

    let requests = parseIpcCommands(
      "workspace \"web; west\"\n" &
      "workspace --no-auto-back-and-forth number 09:dev\n" &
      "exec \"echo a, b; echo c\"\nreload")
    check requests.len == 4
    check requests.allIt(it.parseError.len == 0)
    check requests[0].command.target == "web; west"
    check requests[1].command.target == "9:dev"
    check requests[2].command.shell == "echo a, b; echo c"
    check requests[3].command.kind == cmdReload

  test "fullscreen, minimize, and restore command syntax":
    let parsed = parseCommands(
      "fullscreen; fullscreen enable; fullscreen disable; fullscreen toggle; " &
      "minimize; restore")
    check parsed.mapIt(it.kind) == @[
      cmdFullscreen, cmdFullscreen, cmdFullscreen, cmdFullscreen, cmdMinimize, cmdRestore]
    check parsed.mapIt(it.target) == @["toggle", "enable", "disable", "toggle", "", ""]

    let requests = parseIpcCommands("fullscreen\nminimize,restore\nfullscreen disable")
    check requests.len == 4
    check requests.allIt(it.parseError.len == 0)
    check requests[0].command.kind == cmdFullscreen
    check requests[0].command.target == "toggle"
    check requests[1].command.kind == cmdMinimize
    check requests[2].command.kind == cmdRestore
    check requests[3].command.target == "disable"

    for invalid in [
      "fullscreen maybe", "fullscreen enable extra", "fullscreen ''",
      "minimize now", "restore now"
    ]:
      expect ValueError: discard parseCommands(invalid)

  test "IPC parser preserves valid prefix before an unsupported command":
    let requests = parseIpcCommands("reload\nunsupported feature\nexit")
    check requests.len == 2
    check requests[0].command.kind == cmdReload
    check requests[0].parseError == ""
    check requests[1].parseError.len > 0

  test "execute returns failure for a missing handler":
    let context = CommandContext()
    let result = execute(Command(kind: cmdClose), context)
    check not result.success
    check not result.parseError

  test "quoted exec separators are left for the shell":
    let parsed = parseCommands("exec --no-startup-id \"echo a, b; echo c\"; reload")
    check parsed.len == 2
    check parsed[0].shell == "echo a, b; echo c"
    check parseCommands("exec printf '%s' 'hello, world'")[0].shell ==
      "printf '%s' 'hello, world'"
    check parseCommands("exec \"printf 'hello\\n'\"")[0].shell == "printf 'hello\\n'"

  test "bad commands are rejected instead of becoming no-ops":
    for invalid in [
      "", "exec", "exec ''", "exec --no-startup-id", "exit nope", "focus left",
      "workspace number", "workspace number 0", "workspace number nope",
      "workspace 1 extra", "focus output diagonal", "focus output prev extra",
      "move container workspace 1", "move container to workspace number 0",
      "move container to output next", "move workspace to output northeast",
      "move container to output prev", "move workspace to output prev",
      "unsupported feature", "reload\nexit", "reload;", "kill,,exit",
    ]:
      expect ValueError: discard parseCommands(invalid)
  test "zone commands validate targets":
    let parsed = parseCommands(
      "move container to zone left; fixedSize toggle; cycle-zone left|right")
    check parsed.mapIt(it.kind) == @[cmdMoveZoneContainer, cmdFixedSize, cmdCycleZone]
    check parsed[0].target == "left"
    check parsed[1].target == "toggle"
    check parsed[2].target == "left|right"
    for invalid in ["move container to zone", "fixedSize maybe", "cycle-zone |right",
      "cycle-zone left|", "cycle-zone left | right"]:
      expect ValueError: discard parseCommands(invalid)

  test "zones and fixed-size rules recover transactionally":
    let cfg = parseConfig("""
layout zones
zone left 0% 0% 50% 100%
zone left 0% 0% 25% 100%
for_window [app_id="terminal" title="shell"] fixedSize on
for_window [title="shell"] fixedSize off
for_window [app_id="("] fixedSize on
""")
    check cfg.layout == layoutZones
    check cfg.zones.len == 1
    check cfg.zones[0].width == 25
    check initialFixedSize(cfg, "terminal", "shell") == false
    check initialFixedSize(cfg, "terminal", "other") == false
