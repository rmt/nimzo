# Handle pointer moves and resizes: snap to edges, preview drop zones, and
# choose the destination output and zone when the pointer grab ends.

import std/options

proc dragZone(c: ptr Client; m: ptr Monitor; manual: bool): int =
  if c.alwaysOnTop or m == nil or m.lt[m.sellt] != addr layouts[layoutZonesIndex]: return -1
  let area = zoneBoxFromWlr(m.w)
  let frame = zoneBoxFromWlr(c.geom)
  if manual:
    return bestOverlappingZone(activeConfig.zones, area, frame, zoneClientIndex(c))
  bestZone(activeConfig.zones, area, frame, some((x: cursor.x.float64, y: cursor.y.float64)))

var
  zonePreview: ptr wlr_scene_rect
  grabButton: uint32
  grabKeepGeometry: bool
  grabResizeLeft, grabResizeTop: bool

proc manualZoneGrab(): bool {.inline.} =
  cursor_mode == CurResize or grabKeepGeometry

proc pointerOperationAllowed(): bool =
  if locked != 0 or seat.drag != nil: return false
  var layer: ptr LayerSurface
  discard toplevel_from_wlr_surface(seat.keyboard_state.focused_surface, nil, addr layer)
  layer == nil or layer.layer_surface.current.keyboard_interactive !=
    ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE

proc hideZonePreview() =
  if zonePreview != nil:
    wlr_scene_node_set_enabled(addr zonePreview.node, false)

proc cancelPointerInteraction() =
  hideZonePreview()
  cursor_mode = CurNormal
  grabc = nil
  grabButton = 0
  grabKeepGeometry = false

proc dragOutput(c: ptr Client): ptr Monitor =
  let pointerOutput = xytomon(cursor.x, cursor.y)
  result = pointerOutput
  var bestOverlap = 0'i64
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.enabled:
      let left = max(int64(c.geom.x), int64(m.m.x))
      let top = max(int64(c.geom.y), int64(m.m.y))
      let right = min(int64(c.geom.x) + c.geom.width, int64(m.m.x) + m.m.width)
      let bottom = min(int64(c.geom.y) + c.geom.height, int64(m.m.y) + m.m.height)
      let overlap = max(0'i64, right - left) * max(0'i64, bottom - top)
      if overlap > bestOverlap or (overlap == bestOverlap and m == pointerOutput):
        bestOverlap = overlap
        result = m
    m = wl_list_next_link(m)

proc updateZonePreview() =
  if grabc == nil or (cursor_mode != CurMove and cursor_mode != CurResize) or locked != 0:
    hideZonePreview()
    return
  let m = dragOutput(grabc)
  let manual = manualZoneGrab()
  let index = dragZone(grabc, m, manual)
  if index < 0:
    hideZonePreview()
    return
  let target = zoneBox(activeConfig.zones[index], ZoneBox(x: m.w.x, y: m.w.y,
    width: m.w.width, height: m.w.height))
  if target.width <= 0 or target.height <= 0:
    hideZonePreview()
    return
  var color: array[4, cfloat]
  let opacity = if manual: 0.125.cfloat else: 0.25.cfloat
  for i in 0 .. 3: color[i] = focuscolor[i] * opacity
  if zonePreview == nil:
    zonePreview = wlr_scene_rect_create(layers[LyrOverlay], target.width, target.height, color)
  else:
    wlr_scene_rect_set_color(zonePreview, color)
    wlr_scene_rect_set_size(zonePreview, target.width, target.height)
  wlr_scene_node_set_position(addr zonePreview.node, target.x, target.y)
  wlr_scene_node_raise_to_top(addr zonePreview.node)
  wlr_scene_node_set_enabled(addr zonePreview.node, true)

proc closerSnap(candidate: int64; threshold: int64; delta: var int64) {.inline.} =
  if abs(candidate) <= threshold and abs(candidate) < abs(delta):
    delta = candidate

proc snapGeometry(c: ptr Client; m: ptr Monitor; geometry: wlr_box;
    resizing: bool; resizeLeft = false; resizeTop = false): wlr_box =
  result = geometry
  let threshold = int64(activeConfig.snapDistance)
  if m == nil or threshold <= 0:
    return
  var dx = threshold + 1
  var dy = threshold + 1
  # Output edges and zone edges share the same nearest-edge policy.
  let count = if not c.alwaysOnTop and m.lt[m.sellt] == addr layouts[layoutZonesIndex]:
    activeConfig.zones.len else: 0
  for index in -1 ..< count:
    let box = if index < 0: ZoneBox(x: m.w.x, y: m.w.y, width: m.w.width, height: m.w.height)
      else: zoneBox(activeConfig.zones[index], ZoneBox(x: m.w.x, y: m.w.y,
        width: m.w.width, height: m.w.height))
    if box.width <= 0 or box.height <= 0: continue
    let left = int64(geometry.x)
    let top = int64(geometry.y)
    let right = left + geometry.width
    let bottom = top + geometry.height
    let boxRight = int64(box.x) + box.width
    let boxBottom = int64(box.y) + box.height
    if bottom >= box.y and top <= boxBottom:
      if resizing:
        let edge = if resizeLeft: left else: right
        if (if resizeLeft: right - int64(box.x) else: int64(box.x) - left) > 2 * int64(c.bw):
          closerSnap(int64(box.x) - edge, threshold, dx)
        if (if resizeLeft: right - boxRight else: boxRight - left) > 2 * int64(c.bw):
          closerSnap(boxRight - edge, threshold, dx)
      else:
        closerSnap(int64(box.x) - left, threshold, dx)
        closerSnap(boxRight - right, threshold, dx)
    if right >= box.x and left <= boxRight:
      if resizing:
        let edge = if resizeTop: top else: bottom
        if (if resizeTop: bottom - int64(box.y) else: int64(box.y) - top) > int64(client_frame_height(c)):
          closerSnap(int64(box.y) - edge, threshold, dy)
        if (if resizeTop: bottom - boxBottom else: boxBottom - top) > int64(client_frame_height(c)):
          closerSnap(boxBottom - edge, threshold, dy)
      else:
        closerSnap(int64(box.y) - top, threshold, dy)
        closerSnap(boxBottom - bottom, threshold, dy)
  if abs(dx) <= threshold:
    if resizing:
      result.width = cint(clamp(int64(geometry.width) + (if resizeLeft: -dx else: dx), 1'i64, int64(high(cint))))
      if resizeLeft: result.x = geometry.x + geometry.width - result.width
    else: result.x = cint(clamp(int64(geometry.x) + dx, int64(low(cint)), int64(high(cint))))
  if abs(dy) <= threshold:
    if resizing:
      result.height = cint(clamp(int64(geometry.height) + (if resizeTop: -dy else: dy), 1'i64, int64(high(cint))))
      if resizeTop: result.y = geometry.y + geometry.height - result.height
    else: result.y = cint(clamp(int64(geometry.y) + dy, int64(low(cint)), int64(high(cint))))

proc finishPointerInteraction() =
  let c = grabc
  let manual = manualZoneGrab()
  cancelPointerInteraction()
  if c == nil: return
  let destination = dragOutput(c)
  let index = dragZone(c, destination, manual)
  if index < 0 and not manual and not c.alwaysOnTop:
    clearClientZoneName(c)
  if destination != nil:
    selmon = destination
    setmon(c, destination, 0)
    if index >= 0:
      if manual:
        if index != zoneClientIndex(c): recordClientZone(c, index)
      else:
        assignClientZone(c, index)
    focusclient(c, nil, 1)
  wlr_seat_pointer_clear_focus(seat)
  motionnotify(0, nil, 0, 0, 0, 0)
