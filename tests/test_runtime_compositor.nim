# Test runtime settings on a headless compositor: output rules, keyboard
# shortcuts, startup commands, and configuration reload.
#
# Run with the same native compiler and linker flags as nimzo (nimble test).
# No display hardware, clients, or existing user configuration are required.
const VERSION = "test"
include ../nimzo_core
include headless_support
include keyboard_support

var stage = 0
var timer: ptr wl_event_source
let runtimeDir = headlessRuntime("nimzo-test-", 3)
let smokePath = runtimeDir / "config"
let startupMarker = runtimeDir / "startup"
let execMarker = runtimeDir / "binding"
let initialText = """
set $mod Mod4
client.background #123456
client.focused #ff0000
bindsym $mod+z layout monocle
bindsym $mod+x workspace 2, layout zones
bindsym $mod+Ctrl+Alt+space layout toggle
bindsym $mod+a workspace 1
bindsym $mod+r reload
bindsym $mod+Return exec printf binding > MARKER
output * scale 1
output HEADLESS-1 {
 default
 mode 800x600
 position 0 0
 transform normal
}
output HEADLESS-2 {
 mode 640x480
 position below HEADLESS-1 gap 1
}
output HEADLESS-3 disable
exec printf 'once\n' >> STARTUP
""".replace("MARKER", execMarker).replace("STARTUP", startupMarker)
writeFile(smokePath, initialText)

proc monitor(name: string): ptr Monitor =
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if $m.wlr_output.name == name: return m
    m = wl_list_next_link(m)

proc chord(code: uint32; layoutMods = false) =
  key(uint32(KEY_LEFTMETA), true)
  if layoutMods:
    key(uint32(KEY_LEFTCTRL), true)
    key(uint32(KEY_LEFTALT), true)
  key(code, true)
  key(code, false)
  if layoutMods:
    key(uint32(KEY_LEFTALT), false)
    key(uint32(KEY_LEFTCTRL), false)
  key(uint32(KEY_LEFTMETA), false)

proc checkStage(): cint =
  let first = monitor("HEADLESS-1")
  let second = monitor("HEADLESS-2")
  let third = monitor("HEADLESS-3")
  doAssert first != nil and second != nil and third != nil
  case stage
  of 0:
    doAssert selmon == first
    doAssert first.wlr_output.width == 800 and first.wlr_output.height == 600
    doAssert second.wlr_output.width == 640 and second.m.x == 0 and second.m.y == 601
    doAssert not third.wlr_output.enabled
    doAssert readFile(startupMarker) == "once\n"
    startTestKeyboard("config-test")
    selmon = first
    doAssert first.lt[first.sellt] == addr layouts[layoutZonesIndex]
    runtimeLoaded = false
    chord(uint32(KEY_SPACE), layoutMods = true)
    doAssert first.lt[first.sellt] == addr layouts[layoutMonocleIndex]
    chord(uint32(KEY_SPACE), layoutMods = true)
    doAssert first.lt[first.sellt] == addr layouts[layoutZonesIndex]
    runtimeLoaded = true
    chord(uint32(KEY_Z))
    doAssert first.lt[first.sellt] == addr layouts[layoutMonocleIndex]
    chord(uint32(KEY_X))
    doAssert first.tagset[first.seltags] == 2
    doAssert first.lt[first.sellt] == addr layouts[layoutZonesIndex]
    chord(uint32(KEY_A))
    chord(uint32(KEY_ENTER))
  of 1:
    doAssert readFile(execMarker) == "binding"
    writeFile(smokePath, "bindsym Super+r unsupported_command\n")
    chord(uint32(KEY_R))
    doAssert activeConfig.background == parseConfig(initialText).background
    doAssert runtimeKeys.len == 6
    writeFile(smokePath, initialText & """
client.background #654321
client.focused #00ff00
output HEADLESS-1 mode 1024x768
output HEADLESS-1 position 100 200
output HEADLESS-1 scale 2
output HEADLESS-1 transform 90
output HEADLESS-2 disable
output HEADLESS-3 {
 enable
 mode 320x240
 position below HEADLESS-1 gap 1
}
""")
    chord(uint32(KEY_R))
    doAssert first.wlr_output.width == 1024 and first.wlr_output.height == 768
    doAssert first.m.x == 100 and first.m.y == 200
    doAssert not second.wlr_output.enabled
    doAssert third.wlr_output.enabled and third.wlr_output.width == 320
    doAssert first.m.height == 512
    doAssert third.m.x == 100 and third.m.y == 713
    doAssert first.tagset[first.seltags] == 1
    doAssert first.lt[first.sellt] == addr layouts[layoutZonesIndex]
    for index in 0 .. 3:
      doAssert root_bg.color[index] == rootcolor[index]
    doAssert focuscolor == [0.cfloat, 1.cfloat, 0.cfloat, 1.cfloat]
  of 2:
    doAssert readFile(startupMarker) == "once\n"
    writeFile(smokePath, initialText & "\noutput HEADLESS-2 enable\nlayout monocle\n")
    chord(uint32(KEY_R))
    doAssert second.wlr_output.enabled
    doAssert second.m.x == 0 and second.m.y == 601
    doAssert not third.wlr_output.enabled
    doAssert first.lt[first.sellt] == addr layouts[layoutMonocleIndex]
    chord(uint32(KEY_SPACE), layoutMods = true)
    doAssert first.lt[first.sellt] == addr layouts[layoutZonesIndex]
    finishTestKeyboard()
    wl_display_terminate(dpy)
    echo "PASS: native bindings, command chains, exec, reload retention, colours, output modes/positions, disable/re-enable, startup once"
    return 0
  else: discard
  inc stage
  discard wl_event_source_timer_update(timer, 200)
  return 0

proc tick(data: pointer): cint {.cdecl.} =
  # Exceptions must not escape through the C event loop.
  try:
    return checkStage()
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)

loadInitialConfig(smokePath, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 200)
run(nil)
discard wl_event_source_remove(timer)
cleanup()
removeFile(smokePath)
removeFile(startupMarker)
removeFile(execMarker)
removeDir(runtimeDir)
