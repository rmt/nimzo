# SPDX-License-Identifier: 0BSD

import std/[options, sequtils, unittest]
import ../[config, output_layout]

proc state(name: string; width = 1920'i32; height = 1080'i32;
    x = 0'i32; y = 0'i32; scale = 256'i32; transform = 0'i32): OutputState =
  OutputState(name: name, enabled: true, x: x, y: y, scale: scale,
    transform: transform, mode: OutputMode(width: width, height: height, refresh: 60000))

suite "output configuration parsing":
  test "blocks and inline settings, variables and optional gap":
    let cfg = parseConfig("""
set $primary DP-3
output $primary {
  resolution 2560x1440@59.94Hz
  position 0 0
  scale 1.25
  transform 90
  adaptive_sync off
}
output HDMI-A-1 position below $primary gap 1
output HDMI-A-1 resolution 1920x1080
""")
    check cfg.outputs.len == 2
    check cfg.outputs[0].mode.get == OutputMode(width: 2560, height: 1440, refresh: 59940)
    check cfg.outputs[0].scale.get == 320
    check cfg.outputs[0].transform.get == 1
    check not cfg.outputs[0].adaptiveSync.get
    check cfg.outputs[1].placement == positionBelow
    check cfg.outputs[1].reference == "DP-3"
    check cfg.outputs[1].gap == 1

  test "last property wins when connector directives repeat":
    let cfg = parseConfig("""
output DP-1 position right-of DP-2
output DP-1 position 10 20
output DP-2 position below DP-1
""")
    check cfg.outputs.len == 2
    check cfg.outputs[0].placement == positionAbsolute
    check cfg.outputs[0].reference == ""

  test "invalid properties warn, roll back, and later rules continue":
    let cfg = parseConfig("""
output DP-1 position 0 0
output DP-1 scale nan
output DP-1 resolution 0x100
output DP-1 transform 45
output DP-1 adaptive_sync maybe
output DP-1 position below
output DP-1 position below DP-2 gap -1
output DP-1 position 10 nope
output NEW position 10 nope
output DP-2 position 5 6
""", "outputs.conf")
    check cfg.outputs.len == 2
    check cfg.outputs[0].name == "DP-1"
    check cfg.outputs[0].placement == positionAbsolute
    check cfg.outputs[0].x == 0
    check cfg.outputs[0].y == 0
    check cfg.outputs[0].scale.isNone
    check cfg.outputs[1].name == "DP-2"
    check cfg.outputs[1].placement == positionAbsolute
    check (cfg.outputs[1].x, cfg.outputs[1].y) == (5'i32, 6'i32)

  test "unterminated output blocks retain valid properties":
    let cfg = parseConfig("""
output DP-1 {
  resolution 1920x1080
  position 10 20
""", "outputs.conf")
    check cfg.outputs.len == 1
    check cfg.outputs[0].mode.get == OutputMode(width: 1920, height: 1080, refresh: 0)
    check (cfg.outputs[0].x, cfg.outputs[0].y) == (10'i32, 20'i32)

  test "unsupported blocks skip nested directives":
    let cfg = parseConfig("""
input * {
  output HIDDEN position 1 2
  nested {
    output ALSO-HIDDEN position 3 4
  }
}
output DP-1 position 5 6
""")
    check cfg.outputs.len == 1
    check cfg.outputs[0].name == "DP-1"
    check (cfg.outputs[0].x, cfg.outputs[0].y) == (5'i32, 6'i32)

  test "unterminated unsupported blocks skip their nested contents":
    let cfg = parseConfig("""
input * {
  output HIDDEN position 1 2
  nested {
    output ALSO-HIDDEN position 3 4
""")
    check cfg.outputs.len == 0

  test "self references and cycles reject only the offending property":
    let cfg = parseConfig("""
output A position 0 0
output B position right-of A
output B position right-of B
output C position below D
output D position right-of C
output E position 10 20
""")
    check cfg.outputs.mapIt(it.name) == @["A", "B", "C", "E"]
    check cfg.outputs[0].placement == positionAbsolute
    check cfg.outputs[1].placement == positionRight
    check cfg.outputs[1].reference == "A"
    check cfg.outputs[2].placement == positionBelow
    check cfg.outputs[2].reference == "D"
    check cfg.outputs[3].placement == positionAbsolute
    check (cfg.outputs[3].x, cfg.outputs[3].y) == (10'i32, 20'i32)


  test "workspace patterns match globs and numeric workspace prefixes":
    let rule = OutputRule(workspacePatterns: @["1", "name*", "west"])
    check rule.acceptsWorkspace("1")
    check rule.acceptsWorkspace("1:web")
    check not rule.acceptsWorkspace("10:web")
    check rule.acceptsWorkspace("name-left")
    check not rule.acceptsWorkspace("Name-left")
    check rule.acceptsWorkspace("west")
    check not rule.acceptsWorkspace("west-end")
    check OutputRule().acceptsWorkspace("anything")
    check rule.explicitlyMatchesWorkspace("name-left")
    check not OutputRule().explicitlyMatchesWorkspace("anything")

  test "default and workspace output properties work inline and in blocks":
    let cfg = parseConfig("""
output DP-3 workspaces 1|2|name*
output DP-3 default position 0 0
output HDMI-A-1 {
  workspaces 3|web*
}
""")
    check cfg.outputs.len == 2
    check cfg.outputs[0].workspacePatterns == @["1", "2", "name*"]
    check cfg.outputs[0].isDefault
    check cfg.outputs[0].placement == positionAbsolute
    check not cfg.outputs[1].isDefault
    check cfg.outputs[1].workspacePatterns == @["3", "web*"]
    let blockDefault = parseConfig("output DP-3 {\n  default\n  position 0 0\n}\n")
    check blockDefault.outputs[0].isDefault
    check blockDefault.outputs[0].placement == positionAbsolute

  test "invalid workspace patterns and duplicate defaults roll back":
    let cfg = parseConfig("""
output DP-1 workspaces 1|2
output DP-1 workspaces 1||3
output DP-1 default position 0 nope
output DP-2 default
output DP-3 default
output DP-4 default position 0 0
""")
    check cfg.outputs.mapIt(it.name) == @["DP-1", "DP-2"]
    check cfg.outputs[0].workspacePatterns == @["1", "2"]
    check not cfg.outputs[0].isDefault
    check cfg.outputs[1].isDefault

suite "relative output layout":
  test "all four directions, independent of declaration order":
    let current = @[state("A", x = 100, y = 200), state("B", width = 800, height = 600)]
    for (direction, expected) in [
        ("left-of", (-700'i32, 200'i32)), ("right-of", (2020'i32, 200'i32)),
        ("above", (100'i32, -400'i32)), ("below", (100'i32, 1280'i32))]:
      let rules = parseConfig("output B position " & direction & " A").outputs
      let planned = resolveOutputs(rules, current)
      check (planned[1].x, planned[1].y) == expected
      check planned[0] == current[0]

  test "chains use requested resolution, scale and gaps":
    let rules = parseConfig("""
output C position right-of B gap 10
output B position below A gap 1
output A resolution 2560x1440
output A position 0 0
""").outputs
    let planned = resolveOutputs(rules, @[state("A"), state("B"), state("C")])
    check planned[1].y == 1441
    check planned[2].x == 1930
    check planned[2].y == 1441

  test "logical dimensions respect rotation and fractional scale":
    let rules = parseConfig("""
output B position below A
output A resolution 2560x1440
output A scale 2
output A transform 90
""").outputs
    let planned = resolveOutputs(rules, @[state("A", x = 100, y = 200), state("B")])
    check planned[0].logicalSize == (720'i32, 1280'i32)
    check (planned[1].x, planned[1].y) == (100'i32, 1480'i32)
    let fractional = parseConfig("output B position right-of A\noutput A scale 1.5").outputs
    check resolveOutputs(fractional, @[state("A", width = 2560), state("B")])[1].x == 1706

  test "a reference need not have an explicit output rule":
    let rules = parseConfig("output B position right-of A").outputs
    let current = @[state("A", x = 20, y = 30), state("B"), state("unconfigured", x = 4000)]
    let planned = resolveOutputs(rules, current)
    check planned[1].x == 1940
    check planned[1].y == 30
    check planned[2] == current[2]

  test "missing/disabled references don't mutate the snapshot":
    let current = @[state("B", x = 50, y = 60)]
    let rules = parseConfig("output B position right-of missing").outputs
    expect OutputError: discard resolveOutputs(rules, current)
    check current[0].x == 50
    let disabled = parseConfig("output A disable\noutput B position right-of A").outputs
    expect OutputError: discard resolveOutputs(disabled, @[state("A"), state("B")])

  test "disconnected configured targets are deferred":
    let rules = parseConfig("output missing position right-of also-missing").outputs
    let current = @[state("A")]
    check resolveOutputs(rules, current) == current

  test "invalid dimensions and overflowing positions are rejected":
    let rules = parseConfig("output B position right-of A").outputs
    expect OutputError:
      discard resolveOutputs(rules, @[state("A", x = high(int32)), state("B")])
    expect OutputError:
      discard resolveOutputs(rules, @[state("A", scale = 0), state("B")])
