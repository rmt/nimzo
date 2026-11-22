# Test runtime configuration parsing and validation, including variable
# expansion, bindings, output rules, decorations, and zones.

import std/[strutils, unittest]
import ../runtime_config

suite "runtime configuration":
  test "variables preserve shell quoting and unknown shell variables":
    let config = parseConfig("""
set $mod Mod4
set $term foot
set $red #ff0000
client.focused $red # inline comment
bindsym $mod+Return exec $term --title "a # title"; echo "$HOME"
exec printf '%s' '# startup'
""", "desktop.conf")
    check config.bindings[0].modifiers == 64
    check config.bindings[0].command == "exec foot --title \"a # title\"; echo \"$HOME\""
    check config.startup[0].command == "exec printf '%s' '# startup'"
    check config.focused == [1.cfloat, 0.cfloat, 0.cfloat, 1.cfloat]

  test "private Wayland profiles preserve fixed arguments and explicit grants":
    let config = parseConfig("""
launch bar
wayland_client bar toplevel+output-control /usr/bin/waybar -c "/home/me/panel config" ""
""")
    check config.startup[0].command == "launch bar"
    check config.waylandClients[0].capabilities == {capToplevel, capOutputControl}
    check config.waylandClients[0].argv == @["/usr/bin/waybar", "-c", "/home/me/panel config", ""]
    for invalid in ["wayland_client bar toplevel waybar", "wayland_client bar all /usr/bin/waybar",
        "wayland_client bar capture+ /usr/bin/waybar",
        "wayland_client bar toplevel /usr/bin/waybar\nwayland_client bar capture /usr/bin/waybar"]:
      expect ConfigError:
        discard parseConfig(invalid)

  test "last duplicate chord replaces its command":
    let config = parseConfig("bindsym Super+Return exec first\nbindsym Mod4+Return exec second")
    check config.bindings.len == 1
    check config.bindings[0].command == "exec second"

  test "output blocks merge with inline connector properties":
    let config = parseConfig("""
output DP-1 {
  resolution 2560x1440@59.95Hz
  position -2560, 0
  scale 1.25
  transform 90
}
output DP-1 disable
output * scale 2
""")
    check config.outputs.len == 2
    let output = config.outputs[0]
    check output.width == 2560
    check output.height == 1440
    check output.refresh == 59950
    check output.x == -2560
    check output.y == 0
    check output.scale == 1.25
    check output.transform == 1
    check output.hasEnabled and not output.enabled
    check config.outputs[1].name == "*"

  test "relative output positions keep anchors and gaps":
    let config = parseConfig("""
output HDMI-A-1 position below DP-3 gap 1
output DP-3 position 0 0
""")
    check config.outputs[0].relativeTo == "DP-3"
    check config.outputs[0].gap == 1
    let replaced = parseConfig("""
output HDMI-A-1 position below DP-3 gap 1
output HDMI-A-1 position 20 30
""")
    check replaced.outputs[0].relativeTo == ""
    check replaced.outputs[0].x == 20
    check replaced.outputs[0].y == 30

  test "relative placement rejects cycles and invalid anchors":
    for text in ["output DP-3 position below DP-3",
        "output * position below DP-3", "output DP-3 position below *",
        "output HDMI-A-1 position below DP-3 gap -1",
        "output HDMI-A-1 position below DP-3 gap",
        "output DP-3 position below HDMI-A-1\noutput HDMI-A-1 position below DP-3"]:
      expect ConfigError:
        discard parseConfig(text)

  test "only one exact output can be primary":
    let config = parseConfig("output DP-3 default")
    check config.outputs[0].isDefault
    for text in ["output * default",
        "output DP-3 default\noutput HDMI-A-1 default"]:
      expect ConfigError:
        discard parseConfig(text)

  test "alpha colours are premultiplied for scene rectangles":
    let config = parseConfig("client.focused #ff000080")
    check abs(config.focused[0] - 128.cfloat / 255) < 0.00001
    check config.focused[0] == config.focused[3]

  test "client decorations parse six colours and expose font and titlebars":
    let config = parseConfig("""
font pango:monospace 11
titlebars on
client.focused #010203 #040506 #070809 #0a0b0c #0d0e0f #101112
""")
    check config.font == "monospace 11"
    check config.titlebars
    check config.focusedDecoration.border == [1.cfloat / 255, 2.cfloat / 255,
      3.cfloat / 255, 1.cfloat]
    check config.focusedDecoration.background == [4.cfloat / 255, 5.cfloat / 255,
      6.cfloat / 255, 1.cfloat]
    check config.focusedDecoration.text == [7.cfloat / 255, 8.cfloat / 255,
      9.cfloat / 255, 1.cfloat]
    check config.focusedDecoration.titlebarBorder == [16.cfloat / 255,
      17.cfloat / 255, 18.cfloat / 255, 1.cfloat]
    check config.focused == config.focusedDecoration.border

  test "client decoration shorthand keeps border defaults":
    let config = parseConfig("client.unfocused #112233 #445566 #778899")
    check config.unfocusedDecoration.indicator == config.unfocusedDecoration.border
    check config.unfocusedDecoration.childBorder == config.unfocusedDecoration.border
    check config.unfocusedDecoration.titlebarBorder == config.unfocusedDecoration.border
    check config.unfocused == config.unfocusedDecoration.border

  test "font, titlebars, and client colour errors are rejected":
    for text in [
        "font pango:",
        "font \"\"",
        "titlebars maybe",
        "titlebars on extra",
        "client.focused #010203 #040506",
        "client.focused #010203 #040506 #070809 #0a0b0c #0d0e0f #101112 #131415"
      ]:
      expect ConfigError:
        discard parseConfig(text)

  test "errors identify the source line":
    try:
      discard parseConfig("# comment\noutput DP-1 scale nan", "broken.conf")
      check false
    except ConfigError as error:
      check error.msg.startsWith("broken.conf:2:")

  test "invalid blocks and unsafe native values are rejected":
    for text in ["output DP-1 {\nscale 1", "output DP-1 {\nunknown 1\n}",
        "output DP-1 scale 0", "output DP-1 scale 1e-100",
        "output DP-1 mode 2147483648x720", "output DP-1 position 2147483648 0",
        "output DP-1 mode 800x600@3000000", "bindsym Hyper+x exit",
        "client.focused #zz0000", "not_a_directive yes"]:
      expect ConfigError:
        discard parseConfig(text)

  test "zones are the default and explicit layout choices still work":
    let config = parseConfig("")
    check config.layout == "zones"
    check config.zones.len == 2
    check config.zones[0].name == "L" and config.zones[0].width == 50
    check config.zones[1].name == "R" and config.zones[1].x == 50
    check parseConfig("layout monocle").layout == "monocle"

  test "zones layout and directives parse with last duplicate zone winning":
    let config = parseConfig("""
layout zones
snap_distance 0
zone left 0% 0% 50% 100%
zone left 0% 0% 25% 100%
zone right 50% 0% 50% 100%
""")
    check config.layout == "zones"
    check config.snapDistance == 0
    check config.zones.len == 2
    check config.zones[0].width == 25

  test "default zone resolves against the final zone definitions":
    check parseConfig("default_zone R").defaultZoneIndex == 1
    check parseConfig("default_zone center\nzone left 0% 0% 50% 100%\n" &
      "zone center 25% 25% 50% 50%").defaultZoneIndex == 1
    for text in ["default_zone", "default_zone \"\"", "default_zone L R",
        "default_zone R\nzone left 0% 0% 50% 100%"]:
      expect ConfigError:
        discard parseConfig(text)

  test "window rules retain ordered commands and combine regex criteria":
    let config = parseConfig("""
set $piano Pianoteq 9
for_window [app_id="^terminal$" title="shell"] fixedSize on
for_window [title="shell"] fixedSize off
for_window [class="^$piano$" instance="^piano-ui$" title="^Pianoteq v9\.1\.2$"] fixedSize on, titlebar off, exec echo 'a,b;#'
""", "rules.conf")
    check config.rules.len == 3
    let terminal = WindowProperties(appId: "terminal", title: "shell")
    check config.rules[0].matches(terminal)
    check config.rules[1].matches(terminal)
    check config.rules[0].command == "fixedSize on"
    check config.rules[1].command == "fixedSize off"
    var piano = WindowProperties(appId: "Pianoteq 9", title: "Pianoteq v9.1.2",
      className: "Pianoteq 9", instance: "piano-ui", isXwayland: true)
    check config.rules[2].matches(piano)
    check config.rules[2].location == "rules.conf:4"
    check config.rules[2].command == "fixedSize on, titlebar off, exec echo 'a,b;#'"
    piano.instance = "other"
    check not config.rules[2].matches(piano)
    piano.instance = "piano-ui"
    piano.isXwayland = false
    check not config.rules[2].matches(piano)

  test "zone and fixed-size directives reject malformed values":
    for text in [
        "layout unknown",
        "layout tile",
        "layout tiling",
        "layout floating",
        "zone left 0 0 50% 50%",
        "zone left -1% 0% 50% 50%",
        "zone left 0% 0% 0% 50%",
        "zone left 0% 0% 101% 1%",
        "zone left|bad 0% 0% 1% 1%",
        "zone " & repeat('x', 64) & " 0% 0% 1% 1%",
        "snap_distance -1",
        "snap_distance 2147483648",
        "for_window app_id=terminal fixedSize on",
        "for_window [app_id=\"(\"] fixedSize on",
        "for_window [app_id=\"terminal\"]",
        "for_window [] fixedSize on",
        "for_window [class=\"(\"] fixedSize on",
        "for_window [instance=\"(\"] fixedSize on",
        "for_window [class=\"a\" class=\"b\"] fixedSize on",
        "for_window [instance=\"a\" instance=\"b\"] fixedSize on",
        "for_window [unknown=\"a\"] fixedSize on",
        "for_window [app_id=\"terminal\" app_id=\"other\"] fixedSize on"
      ]:
      expect ConfigError:
        discard parseConfig(text)
