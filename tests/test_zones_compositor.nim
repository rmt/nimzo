# Test zone placement, keyboard commands, and pointer moves and resizes
# with real XDG clients on a headless compositor.

const VERSION = "zones-test"
include ../nimzo_core
include headless_support
include keyboard_support

var stage = 0
var attempts = 0
var timer: ptr wl_event_source
let runtimeDir = headlessRuntime("nimzo-zones-", 2)
var droppedGeometry: wlr_box
let configPathForTest = runtimeDir / "config"
let baseText = """
layout zones
snap_distance 32
zone L 0% 0% 50% 100%
zone R 50% 0% 50% 100%
zone C 12.5% 12.5% 75% 75%
for_window [app_id="^rule-fixed$"] fixedSize on
bindsym Super+KP_Left move container to zone L
bindsym Super+KP_Right move container to zone R
bindsym Super+KP_Begin move container to zone C
bindsym Super+KP_Add cycle focus in zone L|R
bindsym Super+f fixedSize toggle
bindsym Super+a alwaysOnTop toggle
bindsym Super+Tab focus next
bindsym Super+F6 swap zone with R
bindsym Super+F7 swap zone with L focus source
bindsym Super+F8 focus last
bindsym Super+F9 swap zone with R focus source
bindsym Super+r reload
output HEADLESS-1 {
 default
 mode 800x600
 position 0 0
}
output HEADLESS-2 {
 mode 800x600
 position below HEADLESS-1 gap 1
}
exec "$NIMZO_ZONE_CLIENT" alpha
exec "$NIMZO_ZONE_CLIENT" beta
exec "$NIMZO_ZONE_CLIENT" gamma
exec "$NIMZO_ZONE_CLIENT" rule-fixed
exec "$NIMZO_ZONE_CLIENT" hint-fixed fixed
"""
writeFile(configPathForTest, baseText)

proc monitor(name: string): ptr Monitor =
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if $m.wlr_output.name == name: return m
    m = wl_list_next_link(m)

proc ready(count: int): bool =
  if int(wl_list_length(addr clients)) != count: return false
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    if c.resize_serial != 0: return false
    c = wl_list_next_link(c)
  true

proc chord(code: uint32) =
  key(uint32(KEY_LEFTMETA), true)
  key(code, true)
  key(code, false)
  key(uint32(KEY_LEFTMETA), false)

proc button(code: uint32; pressed: bool) =
  var event = wlr_pointer_button_event(time_msec: 10, button: code,
    state: if pressed: WL_POINTER_BUTTON_STATE_PRESSED else: WL_POINTER_BUTTON_STATE_RELEASED)
  buttonpress(nil, addr event)

proc scroll(delta: cdouble; orientation = WL_POINTER_AXIS_VERTICAL_SCROLL) =
  var event = wlr_pointer_axis_event(time_msec: 10, delta: delta, orientation: orientation)
  axisnotify(nil, addr event)

proc focus(c: ptr Client) =
  selmon = c.mon
  focusclient(c, nil, 1)

proc startMove(c: ptr Client; keepGeometry = false; grabX = 30) =
  focus(c)
  wlr_cursor_warp_closest(cursor, nil, float64(c.geom.x + grabX), float64(c.geom.y + 30))
  motionnotify(0, nil, 0, 0, 0, 0)
  key(uint32(KEY_LEFTMETA), true)
  if keepGeometry: key(uint32(KEY_LEFTSHIFT), true)
  button(uint32(BTN_LEFT), true)
  doAssert cursor_mode == CurMove and grabc == c, "failed to start move at stage " & $stage

proc movePointerTo(x, y: float64) =
  motionnotify(10, nil, x - cursor.x, y - cursor.y, 0, 0)

proc stopMove(keepGeometry = false) =
  # The mode comes from the initiating chord, not the release modifiers.
  if keepGeometry: key(uint32(KEY_LEFTSHIFT), false)
  button(uint32(BTN_LEFT), false)
  key(uint32(KEY_LEFTMETA), false)
  doAssert cursor_mode == CurNormal and grabc == nil

proc checkPreview(m: ptr Monitor; name: string; opacity: cfloat) =
  doAssert zonePreview != nil and zonePreview.node.enabled
  let target = zoneBox(activeConfig.zones[zoneIndex(activeConfig.zones, name)],
    zoneBoxFromWlr(m.w))
  doAssert zonePreview.node.x == target.x and zonePreview.node.y == target.y
  doAssert zonePreview.width == target.width and zonePreview.height == target.height
  for i, channel in focuscolor:
    doAssert zonePreview.color[i] == channel * opacity

proc checkStage(): bool =
  let first = monitor("HEADLESS-1")
  let second = monitor("HEADLESS-2")
  let a = app("alpha")
  let b = app("beta")
  let c = app("gamma")
  let fixed = app("rule-fixed")
  let hinted = app("hint-fixed")
  if not ready(if stage >= 4: 4 else: 5): return false
  doAssert first != nil and second != nil and a != nil and b != nil
  case stage
  of 0:
    doAssert first.lt[first.sellt] == addr layouts[layoutZonesIndex]
    doAssert second.lt[second.sellt] == addr layouts[layoutZonesIndex]
    doAssert fixed.isfixed == 1 and hinted.isfixed == 1
    doAssert fixed.geom.width == 182 and fixed.geom.height == 142
    doAssert hinted.geom.width == 182 and hinted.geom.height == 142
    doAssert hinted.isfloating == 1 and zoneClientIndex(hinted) == -1
    startTestKeyboard("zones-test")
    # A panel reservation must affect zone geometry, not physical output bounds.
    first.w = wlr_box(x: 0, y: 40, width: 800, height: 560)
    arrange(first)
    selmon = second
    var two = Arg(ui: 2)
    view(addr two)
    doAssert first.tagset[first.seltags] == 1 and second.tagset[second.seltags] == 2
    focus(a)
    var left = Arg(i: cint(zoneIndex(activeConfig.zones, "L")))
    moveToZone(addr left)
    focus(b)
    moveToZone(addr left)
    focus(c)
    chord(uint32(KEY_KP6)) # KP_Right via the second keysym level.
    var right = Arg(i: cint(zoneIndex(activeConfig.zones, "R")))
    assignClientZone(fixed, zoneIndex(activeConfig.zones, "C"))
    assignClientZone(hinted, zoneIndex(activeConfig.zones, "R"))
    doAssert a.geom.x == 0 and a.geom.y == 40 and a.geom.width == 400 and a.geom.height == 560
    doAssert c.geom.x == 400 and c.geom.width == 400
    key(uint32(KEY_NUMLOCK), true)
    key(uint32(KEY_NUMLOCK), false)
    chord(uint32(KEY_KP4))
    doAssert zoneClientIndex(c) == zoneIndex(activeConfig.zones, "L")
    chord(uint32(KEY_KP6))
    doAssert zoneClientIndex(c) == zoneIndex(activeConfig.zones, "R")
    key(uint32(KEY_NUMLOCK), true)
    key(uint32(KEY_NUMLOCK), false)
    focus(a)
    cycleZones([cint(zoneIndex(activeConfig.zones, "L"))])
    doAssert focused_client == b
    cycleZones([cint(zoneIndex(activeConfig.zones, "L"))])
    doAssert focused_client == a
    var twoTag = Arg(ui: 2)
    tag(addr twoTag)
    doAssert not VISIBLEON(a, first) and VISIBLEON(b, first)
    focus(b)
    cycleZones([cint(zoneIndex(activeConfig.zones, "L"))])
    doAssert focused_client == b
    selmon = first
    view(addr twoTag)
    focus(a)
    var oneTag = Arg(ui: 1)
    tag(addr oneTag)
    view(addr oneTag)
    focus(c)
    var toggle = Arg()
    togglefullscreen(addr toggle)
    togglefullscreen(addr toggle)
    doAssert zoneClientIndex(c) == zoneIndex(activeConfig.zones, "R")
    focus(a)
    chord(uint32(KEY_F))
    doAssert a.isfixed == 1
    resize(a, wlr_box(x: a.geom.x, y: a.geom.y, width: 182, height: 142), 1)
    moveToZone(addr right)
    doAssert a.geom.width == 182 and a.geom.height == 142 and a.geom.x == 618
  of 1:
    focus(a)
    chord(uint32(KEY_F))
    doAssert a.isfixed == 0 and a.geom.width == 400 and a.geom.height == 560
    startMove(b)
    movePointerTo(530, 70)
    checkPreview(first, "R", 0.25.cfloat)
    button(uint32(BTN_RIGHT), false)
    doAssert cursor_mode == CurMove
    stopMove()
    doAssert zoneClientIndex(b) == zoneIndex(activeConfig.zones, "R") and b.isfloating == 0
  of 2:
    startMove(b)
    movePointerTo(30, 631)
    stopMove()
    doAssert b.mon == second and b.tags == 2
    doAssert first.tagset[first.seltags] == 1 and second.tagset[second.seltags] == 2
    doAssert zoneClientIndex(b) == zoneIndex(activeConfig.zones, "L")
    # Resize snapping uses actual pointer input, including the initiating button.
    focus(b)
    wlr_cursor_warp_closest(cursor, nil,
      float64(b.geom.x + b.geom.width * 3 div 4), float64(b.geom.y + b.geom.height * 3 div 4))
    key(uint32(KEY_LEFTMETA), true)
    button(uint32(BTN_RIGHT), true)
    doAssert cursor_mode == CurResize
    movePointerTo(793, 1195)
    checkPreview(second, "C", 0.125.cfloat)
    let resized = b.geom
    button(uint32(BTN_RIGHT), false)
    key(uint32(KEY_LEFTMETA), false)
    doAssert b.geom.width == 800 and b.geom.height == 600 and b.isfloating == 1
    doAssert b.geom == resized and $clientZoneName(b) == "C" and not zonePreview.node.enabled
    focus(a)
    let oldZone = zoneClientIndex(a)
    locked = 1
    var left = Arg(i: cint(zoneIndex(activeConfig.zones, "L")))
    moveToZone(addr left)
    doAssert zoneClientIndex(a) == oldZone
    locked = 0
    let reordered = baseText.replace("zone L 0% 0% 50% 100%\n", "").replace(
      "zone R 50% 0% 50% 100%\n", "zone R 50% 0% 50% 100%\nzone L 0% 0% 50% 100%\n")
    writeFile(configPathForTest, reordered)
    chord(uint32(KEY_R))
    doAssert $clientZoneName(a) == "R" and $clientZoneName(b) == "C"
    doAssert b.geom == resized
  of 3:
    # Removing a zone sends its members to the first configured zone.
    focus(fixed)
    var center = Arg(i: cint(zoneIndex(activeConfig.zones, "C")))
    moveToZone(addr center)
    let noCenter = baseText.replace("zone C 12.5% 12.5% 75% 75%\n", "").replace(
      "bindsym Super+KP_Begin move container to zone C\n", "")
    writeFile(configPathForTest, noCenter)
    chord(uint32(KEY_R))
    doAssert $clientZoneName(fixed) == "L" and fixed.geom.width == 182
    focus(c)
    var close = Arg()
    requestCloseFocusedWindow(addr close)
  of 4:
    if c != nil: return false
  of 5:
    doAssert c == nil
    focus(a)
    cycleZones([cint(zoneIndex(activeConfig.zones, "L")), cint(zoneIndex(activeConfig.zones, "R"))])
    doAssert focused_client != nil and focused_client.mon == first
    doAssert focused_client != b
    # Shift-drag keeps manual geometry across outputs.
    resize(b, wlr_box(x: 50, y: 650, width: 182, height: 142), 1)
  of 6:
    startMove(b, keepGeometry = true)
    movePointerTo(530, 110)
    checkPreview(first, "R", 0.125.cfloat)
    droppedGeometry = b.geom
    stopMove(keepGeometry = true)
    doAssert b.mon == first and b.tags == 1 and b.isfloating == 1
    doAssert $clientZoneName(b) == "R" and not zonePreview.node.enabled
    doAssert b.isfixed == 0
    doAssert wlr_box_equal(addr b.geom, addr droppedGeometry)
    arrange(first)
  of 7:
    doAssert wlr_box_equal(addr b.geom, addr droppedGeometry)
    # A window with manual geometry still participates in its assigned zone's cycle.
    focus(a)
    for i in 0 ..< int(wl_list_length(addr clients)):
      chord(uint32(KEY_KPPLUS))
      if focused_client == b: break
    doAssert focused_client == b
    doAssert b.geom == droppedGeometry and b.isfloating == 1
    startMove(b)
    movePointerTo(90, 721)
    doAssert b.geom.width == 182 and b.geom.height == 142
    stopMove()
    doAssert b.mon == second and b.tags == 2 and b.isfloating == 0
    doAssert $clientZoneName(b) == "L"
    doAssert b.geom == wlr_box(x: 0, y: 601, width: 400, height: 600)
  of 8:
    b.isfixed = 1
    setfloating(b, 1)
    resize(b, wlr_box(x: 50, y: 720, width: 182, height: 142), 1)
  of 9:
    startMove(b)
    movePointerTo(570, 735)
    stopMove()
    doAssert $clientZoneName(b) == "R" and b.isfixed == 1 and b.isfloating == 0
    doAssert b.geom == wlr_box(x: 618, y: 830, width: 182, height: 142)
  of 10:
    # Most of the window overlaps R, even though the pointer ends in L.
    startMove(b, keepGeometry = true)
    movePointerTo(390, 760)
    doAssert cursor.x < 400 and b.geom.x < 400
    checkPreview(second, "R", 0.125.cfloat)
    droppedGeometry = b.geom
    stopMove(keepGeometry = true)
    doAssert b.mon == second and b.tags == 2 and b.isfloating == 1
    doAssert $clientZoneName(b) == "R" and b.isfixed == 1
    doAssert b.geom == droppedGeometry and b.geom.x != 618 and b.geom.y != 830
    arrange(second)
    doAssert b.geom == droppedGeometry
    setfloating(a, 1)
    for left in [false, true]:
      for top in [false, true]:
        resize(a, wlr_box(x: 200, y: 200, width: 200, height: 160), 1)
        focus(a)
        wlr_cursor_warp_closest(cursor, nil,
          (if left: 210.0 else: 390.0), (if top: 210.0 else: 350.0))
        key(uint32(KEY_LEFTMETA), true)
        button(uint32(BTN_RIGHT), true)
        doAssert cursor_mode == CurResize and grabc == a
        doAssert cursor.x == (if left: 200.0 else: 400.0)
        doAssert cursor.y == (if top: 200.0 else: 360.0)
        movePointerTo((if left: 140.0 else: 460.0), (if top: 140.0 else: 420.0))
        doAssert a.geom.x == (if left: 140 else: 200)
        doAssert a.geom.y == (if top: 140 else: 200)
        doAssert a.geom.width == 260 and a.geom.height == 220
        # All four dragged corners snap, not the stationary opposite corner.
        movePointerTo((if left: 7.0 else: 793.0),
          (if top: float64(first.w.y + 7) else: 593.0))
        doAssert a.geom.x == (if left: 0 else: 200)
        doAssert a.geom.y == (if top: first.w.y else: 200)
        doAssert a.geom.width == (if left: 400 else: 600)
        doAssert a.geom.height == (if top: 360 - first.w.y else: 400)
        # Crossing the anchor must not move it or invert the window.
        movePointerTo((if left: 420.0 else: 180.0), (if top: 380.0 else: 180.0))
        doAssert a.geom.width > 0 and a.geom.height > 0
        doAssert (if left: a.geom.x + a.geom.width else: a.geom.x) == (if left: 400 else: 200)
        doAssert (if top: a.geom.y + a.geom.height else: a.geom.y) == (if top: 360 else: 200)
        button(uint32(BTN_RIGHT), false)
        key(uint32(KEY_LEFTMETA), false)
  of 11:
    # A manually resized fixed-size window must not become always-on-top in
    # zones mode. Exercise real modifier/button input with overlapping clients.
    setClientFixedSize(a, 1)
    assignClientZone(a, zoneIndex(activeConfig.zones, "L"))
    assignClientZone(fixed, zoneIndex(activeConfig.zones, "L"))
    resize(a, wlr_box(x: 100, y: 100, width: 240, height: 200), 1)
    resize(fixed, wlr_box(x: 100, y: 100, width: 180, height: 140), 1)
    focus(fixed)
    wlr_cursor_warp_closest(cursor, nil, 260, 220)
    key(uint32(KEY_LEFTMETA), true)
    button(uint32(BTN_RIGHT), true)
    doAssert cursor_mode == CurResize and grabc == fixed
    movePointerTo(320, 280)
    button(uint32(BTN_RIGHT), false)
    key(uint32(KEY_LEFTMETA), false)
    doAssert fixed.isfloating == 1 and fixed.isfixed == 1
    droppedGeometry = fixed.geom
    focus(a)
  of 12:
    doAssert fixed.scene.node.parent == a.scene.node.parent
    doAssert a.scene.node.parent == layers[LyrTile]
    var hit: ptr Client
    xytonode(120, 240, nil, addr hit, nil, nil, nil)
    doAssert hit == a, "resized fixed-size window obscures the focused zone window"
    for floating in [0.cint, 1.cint]:
      focus(fixed)
      setfloating(fixed, floating)
      focus(a)
      xytonode(120, 240, nil, addr hit, nil, nil, nil)
      doAssert hit == a
      doAssert fixed.geom.width == droppedGeometry.width and
        fixed.geom.height == droppedGeometry.height
    # Monocle still keeps floating windows above layout-managed windows.
    var monocle = Arg(v: addr layouts[layoutMonocleIndex])
    setlayout(addr monocle)
  of 13:
    doAssert fixed.scene.node.parent == layers[LyrFloat]
    doAssert a.scene.node.parent == layers[LyrTile]
    var zones = Arg(v: addr layouts[layoutZonesIndex])
    setlayout(addr zones)
    focus(a)
  of 14:
    doAssert fixed.scene.node.parent == layers[LyrTile]
    var hit: ptr Client
    xytonode(120, 240, nil, addr hit, nil, nil, nil)
    doAssert hit == a, "returning to zones obscures the focused window"
    focus(fixed)
    xytonode(120, 240, nil, addr hit, nil, nil, nil)
    doAssert hit == fixed
    focusclient(a, nil, 0) # Sloppy focus must not raise a covered window.
  of 15:
    var hit: ptr Client
    xytonode(120, 240, nil, addr hit, nil, nil, nil)
    doAssert hit == fixed and focused_client == a
    setClientFixedSize(a, 0)
    assignClientZone(a, zoneIndex(activeConfig.zones, "L"))
  of 16:
    doAssert a.isfixed == 0
    focus(a)
    wlr_cursor_warp_closest(cursor, nil, 390, 590)
    key(uint32(KEY_LEFTMETA), true)
    key(uint32(KEY_LEFTSHIFT), true)
    button(uint32(BTN_RIGHT), true)
    doAssert cursor_mode == CurResize and grabc == a
    movePointerTo(720, 590)
    checkPreview(first, "L", 0.125.cfloat)
    button(uint32(BTN_RIGHT), false)
    key(uint32(KEY_LEFTSHIFT), false)
    key(uint32(KEY_LEFTMETA), false)
    doAssert a.geom.width == 720 and a.isfloating == 1 and $clientZoneName(a) == "L"
  of 17:
    # The pointer is over R, although most of the resized window is over L.
    startMove(a, grabX = 600)
    movePointerTo(520, 100)
    doAssert zonePreview.node.enabled and zonePreview.node.x == 400
    stopMove()
    doAssert $clientZoneName(a) == "R" and a.isfloating == 0
  of 18:
    let expected = wlr_box(x: 400, y: first.w.y, width: 400, height: first.w.height)
    doAssert a.geom == expected and a.current == expected,
      "requested " & $a.geom & ", applied " & $a.current & ", expected " & $expected
    doAssert a.surface.xdg.toplevel.current.width == expected.width - 2 * cint(a.bw)
    doAssert a.surface.xdg.toplevel.current.height == expected.height - client_frame_height(a)
  of 19:
    # Start with keyboard focus on the first output and the pointer on the second.
    focus(a)
    wlr_cursor_warp_closest(cursor, nil, cdouble(b.geom.x + 30), cdouble(b.geom.y + 30))
    scroll(1)
    doAssert second.tagset[second.seltags] == 2 and focused_client == a
    key(uint32(KEY_LEFTMETA), true)
    scroll(1, WL_POINTER_AXIS_HORIZONTAL_SCROLL)
    doAssert second.tagset[second.seltags] == 2
    scroll(1)
    doAssert second.tagset[second.seltags] == 4 and first.tagset[first.seltags] == 1
    scroll(-1)
    doAssert second.tagset[second.seltags] == 2
    focus(a)
    key(uint32(KEY_LEFTSHIFT), true)
    scroll(-1)
    doAssert b.mon == second and b.tags == 1 and a.tags == 1
    doAssert second.tagset[second.seltags] == 1 and focused_client == b
    scroll(1)
    doAssert b.mon == second and b.tags == 2
    doAssert second.tagset[second.seltags] == 2 and first.tagset[first.seltags] == 1
    doAssert focused_client == b
    key(uint32(KEY_LEFTSHIFT), false)
    key(uint32(KEY_LEFTMETA), false)
  of 20:
    setmon(b, first, 1)
    resize(b, wlr_box(x: 470, y: 150, width: 182, height: 142), 1)
    focus(a)
    # First verify ordinary floating remains eligible for normal switching.
    for i in 0 ..< int(wl_list_length(addr clients)):
      chord(uint32(KEY_TAB))
      if focused_client == b: break
    doAssert focused_client == b
    chord(uint32(KEY_A))
    doAssert b.alwaysOnTop and b.isfloating == 1
  of 21:
    focus(a)
    var hit: ptr Client
    xytonode(500, 180, nil, addr hit, nil, nil, nil)
    doAssert hit == b, "Always-on-top window was below a raised ordinary window"
    for i in 0 ..< int(wl_list_length(addr clients)):
      chord(uint32(KEY_TAB))
      doAssert focused_client != b
    wlr_cursor_warp_closest(cursor, nil, 500, 180)
    motionnotify(0, nil, 0, 0, 0, 0)
    button(uint32(BTN_LEFT), true)
    button(uint32(BTN_LEFT), false)
    doAssert focused_client == b
    setfloating(b, 0)
    doAssert b.alwaysOnTop and b.isfloating == 0 and $clientZoneName(b) == "R"
    focus(a)
    setfullscreen(a, 1)
  of 22:
    var hit: ptr Client
    xytonode(500, 180, nil, addr hit, nil, nil, nil)
    doAssert hit == a, "Always-on-top window covered fullscreen"
    setfullscreen(a, 0)
    focus(b)
    chord(uint32(KEY_A))
    doAssert not b.alwaysOnTop and b.isfloating == 0 and $clientZoneName(b) == "R"
  of 23:
    let left = zoneIndex(activeConfig.zones, "L")
    let right = zoneIndex(activeConfig.zones, "R")
    assignClientZone(a, left)
    assignClientZone(fixed, left)
    assignClientZone(b, right)
    assignClientZone(hinted, right)
    setfloating(fixed, 1)
    recordClientZone(fixed, left)
    resize(fixed, wlr_box(x: 65, y: 140, width: 182, height: 142), 1)
    focus(b)
    focus(hinted)
    focus(a)
    chord(uint32(KEY_F6))
    doAssert focused_client == a
    doAssert $clientZoneName(a) == "R" and $clientZoneName(fixed) == "R"
    doAssert $clientZoneName(b) == "L" and $clientZoneName(hinted) == "L"
    doAssert fixed.isfloating == 1 and fixed.geom == wlr_box(x: 465, y: 140, width: 182, height: 142)
    doAssert a.geom.x == 400 and a.geom.width == 400
    doAssert hinted.isfixed == 1 and hinted.geom.x == 0 and hinted.geom.width < 400
  of 24:
    chord(uint32(KEY_F7))
    doAssert focused_client == hinted
    doAssert $clientZoneName(a) == "L" and $clientZoneName(fixed) == "L"
    doAssert $clientZoneName(b) == "R" and $clientZoneName(hinted) == "R"
    doAssert fixed.geom == wlr_box(x: 65, y: 140, width: 182, height: 142)
    chord(uint32(KEY_F8))
    doAssert focused_client == a
    chord(uint32(KEY_F8))
    doAssert focused_client == hinted
  of 25:
    focus(b)
    var hidden = Arg(ui: 2)
    tag(addr hidden)
    setWindowMinimized(hinted, true)
    setmon(fixed, second, 2)
    focus(fixed)
    focus(a)
    chord(uint32(KEY_F8))
    doAssert focused_client == a and hinted.isminimized
    chord(uint32(KEY_F9))
    doAssert focused_client == a and $clientZoneName(a) == "R"
    doAssert $clientZoneName(b) == "R" and b.tags == 2
    doAssert $clientZoneName(hinted) == "R" and hinted.isminimized
    doAssert fixed.mon == second and $clientZoneName(fixed) == "L"
    finishTestKeyboard()
    wl_display_terminate(dpy)
    echo "PASS: zone drops, zone swap, focus last, always-on-top, snapping, and workspace scroll"
  else: discard
  true

proc tick(data: pointer): cint {.cdecl.} =
  try:
    inc attempts
    if attempts > 120: raise newException(ValueError, "zone clients did not reach the expected state at stage " & $stage)
    if checkStage(): inc stage
    if stage <= 25: discard wl_event_source_timer_update(timer, 50)
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)
  0

loadInitialConfig(configPathForTest, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 50)
run(nil)
discard wl_event_source_remove(timer)
cleanup()
removeFile(configPathForTest)
removeDir(runtimeDir)
