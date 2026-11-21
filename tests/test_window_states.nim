# Test window state changes and geometry restoration through keyboard
# shortcuts and foreign-toplevel requests with real clients.

const VERSION = "window-state-test"
include ../nimzo_core
include headless_support
include keyboard_support

var timer: ptr wl_event_source
var stage, attempts: int
var original: wlr_box
let directory = headlessRuntime("nimzo-states-", 2)
let configFile = directory / "config"
let replyFile = directory / "reply"
writeFile(configFile, """
layout zones
zone A 0% 0% 50% 100%
titlebars on
bindsym Super+Down minimize
bindsym Super+Up maximize toggle
bindsym Super+Tab focus next
bindsym Super+Shift+Tab focus prev
bindsym Super+w kill
output HEADLESS-1 default
output HEADLESS-1 mode 800x600
output HEADLESS-1 position 0 0
output HEADLESS-2 mode 640x480
output HEADLESS-2 position 0 600
exec "$NIMZO_ZONE_CLIENT" alpha
exec "$NIMZO_ZONE_CLIENT" beta
""")

proc chord(code: uint32) =
  key(uint32(KEY_LEFTMETA), true)
  key(code, true)
  key(code, false)
  key(uint32(KEY_LEFTMETA), false)

proc request(action: string) =
  if fileExists(replyFile): removeFile(replyFile)
  launchWaylandClient(WaylandClientProfile(name: "state-client", capabilities: {capToplevel},
    argv: @[getEnv("NIMZO_STATE_CLIENT"), "alpha", action, replyFile]))

proc replied(expected: string): bool =
  if not fileExists(replyFile) or getFileSize(replyFile) == 0: return false
  doAssert readFile(replyFile).strip == expected
  true

proc checkStage(): bool =
  let a = app("alpha")
  let b = app("beta")
  if stage == 15:
    if b != nil: return false
    doAssert a != nil and client_surface(a).mapped
    finishTestKeyboard()
    wl_display_terminate(dpy)
    echo "PASS: window states, reversible window cycling and Super+w polite focused-window close"
    return true
  if a == nil or b == nil or a.resize_serial != 0 or b.resize_serial != 0: return false
  let first = namedEnabledOutput("HEADLESS-1")
  let second = namedEnabledOutput("HEADLESS-2")
  case stage
  of 0:
    startTestKeyboard("window-states")
    focusOutput(first)
    focusclient(a, nil, 1)
    # Simulate a reserved panel area independently of a panel implementation.
    first.w.y = 30
    first.w.height = 570
    a.isfloating = 1
    original = wlr_box(x: 50, y: 80, width: 250, height: 200)
    resize(a, original, 0)
  of 1:
    chord(uint32(KEY_UP))
    doAssert a.ismaximized and a.isfloating == 1
    doAssert wlr_box_equal(addr a.geom, addr first.w)
    doAssert a.showTitlebar and a.bw == borderpx
    request("state")
  of 2:
    if not replied("0 1"): return false
    doAssert a.surface.xdg.toplevel.current.maximized
    setfullscreen(a, 1)
    doAssert a.ismaximized and a.isfullscreen != 0
    setfullscreen(a, 0)
    doAssert wlr_box_equal(addr a.geom, addr first.w)
    chord(uint32(KEY_DOWN))
    doAssert a.isminimized and not a.scene.node.enabled
    doAssert focused_client != a and focustop(first) == b
    refreshSwaySnapshot()
    request("state")
  of 3:
    if not replied("1 1"): return false
    request("activate")
  of 4:
    if not replied("0 1"): return false
    doAssert not a.isminimized and focused_client == a
    doAssert a.scene.node.enabled and wlr_box_equal(addr a.geom, addr first.w)
    chord(uint32(KEY_UP))
    doAssert not a.ismaximized and wlr_box_equal(addr a.geom, addr original)
    request("maximize")
  of 5:
    if not replied("0 1"): return false
    doAssert a.ismaximized and wlr_box_equal(addr a.geom, addr first.w)
    setmon(a, second, 1)
    doAssert wlr_box_equal(addr a.geom, addr second.w)
    request("unmaximize")
  of 6:
    if not replied("0 0"): return false
    doAssert not a.ismaximized and a.isfloating == 1
    doAssert a.geom.width == original.width and a.geom.height == original.height
    doAssert a.geom.y == original.y + second.w.y - first.w.y
    focusOutput(second)
    focusclient(a, nil, 1)
    a.isfloating = 0
    arrange(second)
  of 7:
    original = a.geom
    chord(uint32(KEY_UP))
    doAssert a.ismaximized and a.isfloating == 0
    chord(uint32(KEY_UP))
    doAssert not a.ismaximized and wlr_box_equal(addr a.geom, addr original)
    request("minimize")
  of 8:
    if not replied("1 0"): return false
    doAssert a.isminimized and not a.scene.node.enabled
    request("restore")
  of 9:
    if not replied("0 0"): return false
    doAssert not a.isminimized and a.scene.node.enabled
    locked = 1
    setWindowMinimized(a, true)
    setWindowMaximized(a, true)
    doAssert not a.isminimized and not a.ismaximized
    locked = 0
  of 10:
    setmon(a, first, 1)
    focusOutput(first)
    focusclient(b, nil, 1)
    setfullscreen(b, 1)
    setWindowMinimized(a, true)
    original = b.prev
    key(uint32(KEY_LEFTMETA), true)
    key(uint32(KEY_TAB), true)
    key(uint32(KEY_TAB), false)
    doAssert focused_client == a and not a.isminimized
    doAssert b.isfullscreen != 0
  of 11:
    doAssert a.scene.node.enabled and not b.scene.node.enabled
    doAssert not first.fullscreen_bg.node.enabled
    key(uint32(KEY_TAB), true)
    key(uint32(KEY_TAB), false)
    doAssert focused_client == b and a.isminimized
    doAssert b.isfullscreen != 0 and wlr_box_equal(addr b.prev, addr original)
    key(uint32(KEY_LEFTMETA), false)
  of 12:
    doAssert b.scene.node.enabled and not a.scene.node.enabled
    doAssert first.fullscreen_bg.node.enabled
    chord(uint32(KEY_TAB))
    doAssert focused_client == a and not a.isminimized
  of 13:
    doAssert a.scene.node.enabled and not b.scene.node.enabled
    # The selected minimized window stays restored after modifier release.
    key(uint32(KEY_LEFTMETA), true)
    key(uint32(KEY_LEFTSHIFT), true)
    key(uint32(KEY_TAB), true)
    key(uint32(KEY_TAB), false)
    key(uint32(KEY_LEFTSHIFT), false)
    key(uint32(KEY_LEFTMETA), false)
    doAssert focused_client == b and not a.isminimized and b.isfullscreen != 0
  of 14:
    doAssert b.scene.node.enabled and first.fullscreen_bg.node.enabled
    setfullscreen(b, 0)
    doAssert wlr_box_equal(addr b.geom, addr original)
    chord(uint32(KEY_W))
  else: discard
  true

proc tick(data: pointer): cint {.cdecl.} =
  try:
    inc attempts
    if attempts > 160: raise newException(ValueError, "window state test timed out at stage " & $stage)
    if checkStage(): inc stage
    if stage <= 15: discard wl_event_source_timer_update(timer, 50)
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)
  0

loadInitialConfig(configFile, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 50)
run(nil)
discard wl_event_source_remove(timer)
cleanup()
if fileExists(replyFile): removeFile(replyFile)
removeFile(configFile)
removeDir(directory)
