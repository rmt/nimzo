# Test titlebar rendering, window geometry, and pointer interactions with
# real XDG clients on a headless compositor.

const VERSION = "titlebar-test"
include ../nimzo_core
include headless_support
include keyboard_support

var timer: ptr wl_event_source
var stage, attempts: int
var primaryPid: pid_t = -1
var secondaryPid: pid_t = -1
var untitledPid: pid_t = -1
var stackPeerPid: pid_t = -1
var oldPixels: uint64
var captureStarted: bool
var stackCaptureStarted: bool
let runtimeDir = headlessRuntime("nimzo-titlebars-", 2)
let testConfig = runtimeDir / "config"
let baseConfig = """
sway_ipc_restricted off
wayland_protocols_restricted off
font pango:monospace 10
titlebars on
client.focused #8b0000 #8b0000 #ffffff #8b0000 #8b0000 #c84040
client.unfocused #500000 #500000 #dddddd #500000 #500000 #702020
layout zones
zone L 0% 0% 50% 100%
zone R 50% 0% 50% 100%
zone Middle 25% 0% 50% 100%
bindsym Super+b border toggle
bindsym Super+t titlebar toggle
bindsym Super+Ctrl+Alt+space layout toggle
bindsym Super+r reload
output HEADLESS-1 default
output HEADLESS-1 mode 800x600
output HEADLESS-1 position 0 0
output HEADLESS-2 mode 800x600
output HEADLESS-2 scale 1.5
output HEADLESS-2 position 0 600
"""
writeFile(testConfig, baseConfig)
const initialTitle = "<b>Literal text</b> — Καλημέρα 日本語 — a long window title that ends in an ellipsis"
const updatedTitle = "Updated title — café"

proc spawnClient(appId, fixed, title, updated: cstring; finalTitle: cstring = nil): pid_t =
  result = fork()
  if result == 0:
    let executable = getEnv("NIMZO_ZONE_CLIENT")
    if finalTitle != nil:
      discard execl(executable.cstring, executable.cstring, appId, fixed, title, updated, finalTitle, nil)
    elif updated != nil:
      discard execl(executable.cstring, executable.cstring, appId, fixed, title, updated, nil)
    else:
      discard execl(executable.cstring, executable.cstring, appId, fixed, title, nil)
    exit(2)
  doAssert result > 0

proc focus(c: ptr Client) =
  selmon = c.mon
  focusclient(c, nil, 1)

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

proc button(pressed: bool) =
  var event = wlr_pointer_button_event(time_msec: 10, button: uint32(BTN_LEFT),
    state: if pressed: WL_POINTER_BUTTON_STATE_PRESSED else: WL_POINTER_BUTTON_STATE_RELEASED)
  buttonpress(nil, addr event)

proc clickAt(x, y: cint) =
  wlr_cursor_warp_closest(cursor, nil, x.cdouble, y.cdouble)
  motionnotify(10, nil, 0, 0, 0, 0)
  button(true)
  button(false)

proc command(text: string) = discard executeSwayCommand(text)

proc bufferRead(buffer: ptr wlr_buffer; flags: uint32; data: ptr pointer;
  format: ptr uint32; stride: ptr csize_t): bool {.importc: "wlr_buffer_begin_data_ptr_access".}
proc bufferReadEnd(buffer: ptr wlr_buffer) {.importc: "wlr_buffer_end_data_ptr_access".}

proc titleData(c: ptr Client): ptr UncheckedArray[uint32] =
  var data: pointer
  var format: uint32
  var stride: csize_t
  doAssert bufferRead(c.titlebar.buffer, 1, addr data, addr format, addr stride)
  doAssert format == 0x34325241'u32 and stride == csize_t(c.titlebar.buffer.width * 4)
  cast[ptr UncheckedArray[uint32]](data)

proc expectedPixel(color: Color): uint32 =
  (uint32(color[3] * 255 + 0.5) shl 24) or
    (uint32(color[0] * 255 + 0.5) shl 16) or
    (uint32(color[1] * 255 + 0.5) shl 8) or uint32(color[2] * 255 + 0.5)

proc titlePixels(c: ptr Client): uint64 =
  let buffer = c.titlebar.buffer
  let pixels = titleData(c)
  defer: bufferReadEnd(buffer)
  result = 1469598103934665603'u64
  for index in 0 ..< int(buffer.width * buffer.height):
    result = (result xor uint64(pixels[index])) * 1099511628211'u64

proc hasTextPixels(c: ptr Client): bool =
  let buffer = c.titlebar.buffer
  let pixels = titleData(c)
  defer: bufferReadEnd(buffer)
  let colors = if c == focused_client: activeConfig.focusedDecoration else: activeConfig.unfocusedDecoration
  let background = expectedPixel(colors.background)
  let border = expectedPixel(colors.titlebarBorder)
  for index in 0 ..< int(buffer.width * buffer.height):
    if pixels[index] != background and pixels[index] != border: return true

proc menuSurface(c: ptr Client): ptr wlr_surface =
  let popups = addr c.surface.xdg.popups
  if wl_list_empty(popups) == 0:
    let popup = wl_list_first_link(popups, cast[ptr wlr_xdg_popup](nil))
    if popup.base.surface.mapped: return popup.base.surface

proc checkMenu(c: ptr Client; menu: ptr wlr_surface; topInset: cint) =
  doAssert menu != nil
  # The menu starts below the menubar and extends beyond the window content.
  for menuY in [3, 150]:
    var surface: ptr wlr_surface
    var sx, sy: cdouble
    xytonode(cdouble(c.geom.x + cint(c.bw) + 15),
      cdouble(c.geom.y + topInset + 8 + cint(menuY)),
      addr surface, nil, nil, addr sx, addr sy)
    doAssert surface == menu and sx == 5 and sy == cdouble(menuY)

proc checkStage(): bool =
  if primaryPid < 0:
    primaryPid = spawnClient("title-a", "normal", initialTitle, updatedTitle)
    secondaryPid = spawnClient("title-b", "fixed-popup", "Fixed-size window", nil)
    return false
  let a = app("title-a")
  let b = app(if stage <= 18: "title-b" else: "stack-peer")
  if a == nil or b == nil: return false
  for c in [a, b]:
    if c.resize_serial != 0 or not wlr_box_equal(addr c.current, addr c.geom): return false
  case stage
  of 0:
    startTestKeyboard("titlebar-test")
    assignClientZone(a, zoneIndex(activeConfig.zones, "L"))
    assignClientZone(b, zoneIndex(activeConfig.zones, "R"))
    focus(a)
  of 1:
    doAssert a.titlebar != nil and b.titlebar != nil
    doAssert a.scene_surface.node.y == TitlebarHeight and b.scene_surface.node.y == TitlebarHeight
    doAssert b.geom.width == 182 and b.geom.height == 165
    doAssert b.surface.xdg.toplevel.current.width == 180
    doAssert b.surface.xdg.toplevel.current.height == 140
    doAssert hasTextPixels(a) and hasTextPixels(b)
    let pixels = titleData(a)
    doAssert pixels[0] == expectedPixel(activeConfig.focusedDecoration.titlebarBorder)
    bufferReadEnd(a.titlebar.buffer)
    let proof = getEnv("NIMZO_TITLEBAR_PROOF")
    if proof.len != 0:
      if not captureStarted:
        captureStarted = true
        let pid = fork()
        if pid == 0:
          discard execl("/usr/bin/grim", "grim", "-o", "HEADLESS-1", proof.cstring, nil)
          exit(2)
      if not fileExists(proof): return false
    oldPixels = titlePixels(a)
    doAssert kill(primaryPid, cint(ipcPosix.SIGUSR1)) == 0
  of 2:
    if $client_get_title(a) != updatedTitle: return false
    doAssert titlePixels(a) != oldPixels and hasTextPixels(a)
    focus(b)
    chord(uint32(KEY_T))
    doAssert not b.showTitlebar and a.showTitlebar
    doAssert b.geom.height == 142 and b.titlebar == nil
    focus(a)
    let outerHeight = a.geom.height
    command("titlebar off")
    doAssert a.geom.height == outerHeight # Tiled frames keep their zone.
  of 3:
    doAssert a.scene_surface.node.y == cint(a.bw)
    doAssert a.surface.xdg.toplevel.current.height == a.geom.height - 2 * cint(a.bw)
    command("titlebar on")
    command("fullscreen toggle")
    doAssert a.titlebar == nil or not a.titlebar.node.enabled
    command("titlebar off")
    doAssert not a.showTitlebar and a.isfullscreen != 0
    command("fullscreen toggle")
    command("titlebar on")
    let second = namedEnabledOutput("HEADLESS-2")
    setmon(a, second, a.tags)
    focus(a)
  of 4:
    doAssert a.titlebar != nil and a.titlebar.node.enabled and a.titlebarScale == 1.5
    doAssert a.titlebar.buffer.width == a.geom.width * 2 and a.titlebar.buffer.height == 48
    var hit: ptr Client
    var surface: ptr wlr_surface
    var sx, sy: cdouble
    xytonode(float64(a.geom.x + cint(a.bw) + 5), float64(a.geom.y + TitlebarHeight + 5),
      addr surface, addr hit, nil, addr sx, addr sy)
    doAssert hit == a and surface == client_surface(a) and sx == 5 and sy == 5
    xytonode(float64(a.geom.x + 10), float64(a.geom.y + 12), addr surface, addr hit, nil, nil, nil)
    doAssert hit == a and surface == nil
    wlr_cursor_warp_closest(cursor, nil, float64(a.geom.x + 10), float64(a.geom.y + 12))
    motionnotify(10, nil, 0, 0, 0, 0)
    button(true)
    doAssert grabc == a and cursor_mode == CurMove
    motionnotify(20, nil, 50, 40, 0, 0)
    button(false)
    doAssert grabc == nil and cursor_mode == CurNormal
    let setting = a.showTitlebar
    locked = 1
    var off = Arg(i: 0)
    setTitlebarWindow(addr off)
    locked = 0
    doAssert a.showTitlebar == setting
    writeFile(testConfig, baseConfig & "font pango:Sans 12\nclient.focused #00ff00 #002000 #ffffff\n")
    focus(a)
    chord(uint32(KEY_R))
    doAssert a.showTitlebar and not b.showTitlebar and activeConfig.font == "Sans 12"
  of 5:
    doAssert hasTextPixels(a) and a.titlebarGeneration == titlebarGeneration
    doAssert not b.showTitlebar and b.titlebar == nil
    untitledPid = spawnClient("untitled", "fixed-untitled", "", "broken", "")
  of 6, 7, 8:
    let dialog = app("untitled")
    if dialog == nil or dialog.resize_serial != 0 or dialog.geom != dialog.current: return false
    if stage == 7 and client_actual_title(dialog) == nil: return false
    if stage == 8 and $client_actual_title(dialog) != "": return false
    doAssert dialog.showTitlebar
    doAssert dialog.surface.xdg.toplevel.current.height == 140
    if stage == 7:
      doAssert $client_actual_title(dialog) == "broken"
      doAssert dialog.titlebar != nil and dialog.titlebar.node.enabled
      doAssert dialog.scene_surface.node.y == TitlebarHeight and dialog.geom.height == 165
    else:
      doAssert dialog.titlebar == nil and dialog.border[0].node.enabled
      doAssert dialog.scene_surface.node.y == cint(dialog.bw) and dialog.geom.height == 142
    if stage < 8:
      doAssert kill(untitledPid, cint(ipcPosix.SIGUSR1)) == 0
      return true
  of 9:
    focus(b)
    chord(uint32(KEY_T))
  of 10:
    chord(uint32(KEY_B))
  of 11:
    doAssert b.titlebar != nil and b.titlebar.node.enabled
    doAssert b.geom.width == 180 and b.geom.height == 164
    for edge in b.border: doAssert not edge.node.enabled
    let pixels = titleData(b)
    doAssert pixels[0] == expectedPixel(activeConfig.focusedDecoration.background)
    bufferReadEnd(b.titlebar.buffer)
    chord(uint32(KEY_T))
  of 12:
    doAssert b.titlebar == nil and b.scene_surface.node.y == 0
    doAssert b.geom.width == 180 and b.geom.height == 140
    command("fullscreen on")
  of 13:
    command("fullscreen off")
  of 14:
    doAssert b.geom.width == 180 and b.geom.height == 140 and b.bw == 0
    command("border on")
  of 15:
    doAssert b.geom.width == 182 and b.geom.height == 142 and b.border[0].node.enabled
    chord(uint32(KEY_SPACE), layoutMods = true)
    doAssert b.mon.lt[b.mon.sellt] == addr layouts[layoutMonocleIndex]
    chord(uint32(KEY_SPACE), layoutMods = true)
    doAssert b.mon.lt[b.mon.sellt] == addr layouts[layoutZonesIndex]
    chord(uint32(KEY_T))
  of 16:
    doAssert kill(secondaryPid, cint(ipcPosix.SIGUSR1)) == 0
  of 17:
    let menu = menuSurface(b)
    if menu == nil: return false
    checkMenu(b, menu, TitlebarHeight)
    chord(uint32(KEY_T))
  of 18:
    checkMenu(b, menuSurface(b), cint(b.bw))
    stackPeerPid = spawnClient("stack-peer", "fixed", "Fixed-size window", nil)
  of 19:
    let dialog = app("untitled")
    for c in [a, dialog]:
      setmon(c, b.mon, b.tags)
    let zone = zoneIndex(activeConfig.zones, "L")
    for c in [dialog, b, a]:
      assignClientZone(c, zone)
      focus(c)
    command("titlebar off")
  of 20:
    let dialog = app("untitled")
    if dialog.resize_serial != 0 or dialog.geom != dialog.current: return false
    if not activeConfig.windowStackPicker:
      doAssert a.stackBadge == nil
      writeFile(testConfig, readFile(testConfig) & "window_stack_picker on\n")
      reloadconfig(nil)
      return false
    if not a.showTitlebar:
      doAssert a.titlebar == nil and a.stackBadge == nil
      command("titlebar on")
      return false
    doAssert a.stackBadge != nil and a.stackBadge.node.enabled and a.stackBadgeCount == 3
    let x = a.current.x + a.current.width - 15
    let y = a.current.y + 8
    clickAt(x, y)
    doAssert stackPicker != nil and stackPickerBox.height == 3 * TitlebarHeight
    key(uint32(KEY_ESC), true)
    key(uint32(KEY_ESC), false)
    doAssert stackPicker == nil and focused_client == a
    clickAt(x, y)
    doAssert stackPicker != nil
  of 21:
    let proof = getEnv("NIMZO_STACK_PROOF")
    if proof.len != 0:
      if not stackCaptureStarted:
        stackCaptureStarted = true
        let pid = fork()
        if pid == 0:
          discard execl("/usr/bin/grim", "grim", "-o", b.mon.wlr_output.name, proof.cstring, nil)
          exit(2)
      if not fileExists(proof): return false
    clickAt(stackPickerBox.x + 50, stackPickerBox.y + TitlebarHeight + 8)
    doAssert stackPicker == nil and focused_client == b
  of 22:
    # Raising the small window exposes the much larger one below it.
    doAssert not a.stackBadge.node.enabled
    doAssert b.stackBadge != nil and b.stackBadge.node.enabled and b.stackBadgeCount == 2
    let dialog = app("untitled")
    assignClientZone(dialog, zoneIndex(activeConfig.zones, "R"))
  of 23:
    doAssert not b.stackBadge.node.enabled and not a.stackBadge.node.enabled
    assignClientZone(b, zoneIndex(activeConfig.zones, "Middle"))
    focus(a)
  of 24:
    # Half overlap alone does not match windows from different zones.
    let edge = a.current.x + a.current.width
    doAssert 2 * (edge - b.current.x) == b.current.width
    doAssert not a.stackBadge.node.enabled
    var frame = b.current
    frame.x = edge - frame.width
    frame.y = a.current.y
    resize(b, frame, 1)
    # The shared top-right corner makes the window eligible.
    doAssert a.stackBadge.node.enabled and a.stackBadgeCount == 2
    clickAt(edge - 15, a.current.y + 8)
    doAssert stackPicker != nil and stackPickerBox.height == 2 * TitlebarHeight
    clickAt(stackPickerBox.x + 50, stackPickerBox.y + 8)
    doAssert stackPicker == nil and focused_client == a
    clickAt(edge - 15, a.current.y + 8)
    doAssert stackPicker != nil
    inc frame.y
    resize(b, frame, 1)
    doAssert stackPicker == nil and not a.stackBadge.node.enabled
    # The top-left corner also works, without a shared right edge.
    frame.x = a.current.x
    frame.y = a.current.y
    resize(b, frame, 1)
    doAssert a.stackBadge.node.enabled
    # Match each lower corner without sharing a top corner.
    frame.y = a.current.y + a.current.height - frame.height
    resize(b, frame, 1)
    doAssert a.stackBadge.node.enabled
    frame.x = edge - frame.width
    resize(b, frame, 1)
    doAssert a.stackBadge.node.enabled
    # Keep a shared bottom-right corner while changing how much is covered.
    let original = a.current
    var front = original
    front.height = (frame.height + 3) div 4 - 1
    front.y = original.y + original.height - front.height
    resize(a, front, 1)
    doAssert not a.stackBadge.node.enabled
    inc front.height
    dec front.y
    resize(a, front, 1)
    doAssert a.stackBadge.node.enabled
    resize(a, original, 1)
    clickAt(edge - 15, a.current.y + 8)
    doAssert stackPicker != nil and stackPickerBox.height == 2 * TitlebarHeight
    clickAt(stackPickerBox.x + 50, stackPickerBox.y + TitlebarHeight + 8)
    doAssert stackPicker == nil and focused_client == b
    assignClientZone(b, zoneIndex(activeConfig.zones, "L"))
    focus(a)
  of 25:
    clickAt(a.current.x + a.current.width - 15, a.current.y + 8)
    doAssert stackPicker != nil
    command("titlebar off")
  of 26:
    doAssert a.titlebar == nil and not a.stackBadge.node.enabled and stackPicker == nil
    command("titlebar on")
  of 27:
    clickAt(a.current.x + a.current.width - 15, a.current.y + 8)
    doAssert stackPicker != nil
    writeFile(testConfig, readFile(testConfig).replace(
      "window_stack_picker on\n", "window_stack_picker off\n"))
    reloadconfig(nil)
  of 28:
    doAssert stackPicker == nil and not a.stackBadge.node.enabled
    finishTestKeyboard()
    wl_display_terminate(dpy)
    echo "PASS: titlebars, popup alignment, and hidden-window badge and picker"
  else: discard
  true

proc tick(data: pointer): cint {.cdecl.} =
  try:
    inc attempts
    if attempts > 160:
      for name in ["title-a", "title-b", "untitled", "stack-peer"]:
        let c = app(name)
        if c == nil: echo name, " unmapped"
        else: echo name, " resize serial ", c.resize_serial, "; requested ", c.geom, "; committed ", c.current
      raise newException(ValueError, "titlebar test timed out at stage " & $stage)
    if checkStage(): inc stage
    if stage <= 28: discard wl_event_source_timer_update(timer, 50)
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)
  0

loadInitialConfig(testConfig, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 50)
run(nil)
discard wl_event_source_remove(timer)
cleanup()
discard kill(primaryPid, SIGTERM)
discard kill(secondaryPid, SIGTERM)
discard kill(untitledPid, SIGTERM)
removeFile(testConfig)
removeDir(runtimeDir)
if stackPeerPid > 0: discard kill(stackPeerPid, SIGTERM)
