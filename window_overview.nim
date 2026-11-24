# Show a temporary view of the selected output's workspace without modifying
# client geometry. Snapshot nodes own their buffer references until dismissal.

const
  OverviewLimit = 30
  OverviewGap = 10.cint
  OverviewBorder = 2.cint
  OverviewDuration = 170.0
  OverviewScrim = [0.018.cfloat, 0.024, 0.035, 0.93]
  OverviewCardColor = [0.045.cfloat, 0.052, 0.070, 1.0]
  OverviewFrameColor = [0.42.cfloat, 0.46, 0.53, 1.0]
  OverviewSelectionColor = [0.58.cfloat, 0.80, 1.0, 1.0]

type OverviewEntry = object
  client: ptr Client
  origin, target: wlr_box
  border: ptr wlr_scene_rect
  outline: array[4, ptr wlr_scene_rect]

var
  overviewRoot, overviewCards, overviewFrames: ptr wlr_scene_tree
  overviewTimer: ptr wl_event_source
  overviewMonitor: ptr Monitor
  overviewArea, overviewOutputBox: wlr_box
  overviewTags: uint32
  overviewScale: cfloat
  overviewEntries: array[OverviewLimit, OverviewEntry]
  overviewCount, overviewSelected: int
  overviewStart: float64
  overviewButtons: set[0..KEY_MAX]

proc overviewCenter(pos, size: cint): cint {.inline.} = pos + size div 2

proc overviewOrigin(frame, area: wlr_box): wlr_box =
  let x = clamp(frame.x - area.x, 0, area.width - 1)
  let y = clamp(frame.y - area.y, 0, area.height - 1)
  wlr_box(x: x, y: y,
    width: max(1, clamp(frame.x - area.x + frame.width, 0, area.width) - x),
    height: max(1, clamp(frame.y - area.y + frame.height, 0, area.height) - y))

proc overviewGapOverlap(a, b: wlr_box): bool {.inline.} =
  a.x < b.x + b.width + OverviewGap and b.x < a.x + a.width + OverviewGap and
    a.y < b.y + b.height + OverviewGap and b.y < a.y + a.height + OverviewGap

proc overviewDistance(a, b: wlr_box): int64 {.inline.} =
  let dx = int64(overviewCenter(a.x, a.width)) - overviewCenter(b.x, b.width)
  let dy = int64(overviewCenter(a.y, a.height)) - overviewCenter(b.y, b.height)
  dx * dx + dy * dy

proc overviewFit(frame: wlr_box; width, height: cint; scale: float64): wlr_box =
  let contentHeight = height - TitlebarHeight - 2 * OverviewBorder
  let ratio = min(scale, min(float64(width - 2 * OverviewBorder) / frame.width.float64,
    contentHeight.float64 / frame.height.float64))
  result.width = max(min(110.cint, width), cint(frame.width.float64 * ratio) + 2 * OverviewBorder)
  result.height = max(1.cint, cint(frame.height.float64 * ratio)) + TitlebarHeight + 2 * OverviewBorder

proc packOverview(entries: var openArray[OverviewEntry]; area: wlr_box; scale: float64): bool =
  # Search the ideal position and the edges of already placed cards. Break ties
  # in focus order so a stack spreads in a repeatable way.
  for i in 0 ..< entries.len:
    let origin = entries[i].origin
    var box = overviewFit(origin, area.width, area.height, scale)
    let right = area.x + area.width - box.width
    let bottom = area.y + area.height - box.height
    var xs, ys: array[OverviewLimit * 2 + 3, cint]
    xs[0] = clamp(overviewCenter(origin.x, origin.width) - box.width div 2, area.x, right)
    ys[0] = clamp(overviewCenter(origin.y, origin.height) - box.height div 2, area.y, bottom)
    xs[1] = area.x
    xs[2] = right
    ys[1] = area.y
    ys[2] = bottom
    for j in 0 ..< i:
      let placed = entries[j].target
      xs[3 + j * 2] = clamp(placed.x - OverviewGap - box.width, area.x, right)
      xs[4 + j * 2] = clamp(placed.x + placed.width + OverviewGap, area.x, right)
      ys[3 + j * 2] = clamp(placed.y - OverviewGap - box.height, area.y, bottom)
      ys[4 + j * 2] = clamp(placed.y + placed.height + OverviewGap, area.y, bottom)
    var best = high(int64)
    for x in 0 ..< 3 + i * 2:
      box.x = xs[x]
      for y in 0 ..< 3 + i * 2:
        box.y = ys[y]
        let score = overviewDistance(box, origin)
        if score >= best: continue
        var conflict = false
        for j in 0 ..< i:
          if overviewGapOverlap(box, entries[j].target):
            conflict = true
            break
        if not conflict:
          best = score
          entries[i].target = box
      if best == 0: break
    if best == high(int64): return false
  true

proc layoutOverview(entries: var openArray[OverviewEntry]; area: wlr_box): bool =
  if entries.len == 0: return true
  if area.width < 2 * OverviewBorder + 1 or area.height <= TitlebarHeight + 2 * OverviewBorder:
    return false
  for scale in [0.76, 0.61, 0.49, 0.39, 0.31]:
    if packOverview(entries, area, scale): return true
  # Dense workspaces use the closest free cell, rather than allowing overlap
  # or shrinking the labels. Pick the grid that leaves the most preview room.
  var columns, rows: int
  var cellWidth, cellHeight: cint
  var best = 0.cint
  for cols in 1 .. entries.len:
    let nrows = (entries.len + cols - 1) div cols
    let width = (area.width + OverviewGap) div cint(cols) - OverviewGap
    let height = (area.height + OverviewGap) div cint(nrows) - OverviewGap
    let score = min(width - 2 * OverviewBorder, (height - TitlebarHeight - 2 * OverviewBorder) * 2)
    if score > best:
      best = score
      (columns, rows, cellWidth, cellHeight) = (cols, nrows, width, height)
  if best == 0: return false
  var used: set[0 .. OverviewLimit * 2 - 1]
  for entry in entries.mitems:
    let size = overviewFit(entry.origin, cellWidth, cellHeight, 0.76)
    var score = high(int64)
    var nearest = 0
    for cell in 0 ..< columns * rows:
      if cell in used: continue
      var box = size
      box.x = area.x + cint(cell mod columns) * (cellWidth + OverviewGap) + (cellWidth - size.width) div 2
      box.y = area.y + cint(cell div columns) * (cellHeight + OverviewGap) + (cellHeight - size.height) div 2
      let distance = overviewDistance(box, entry.origin)
      if distance < score:
        (nearest, score, entry.target) = (cell, distance, box)
    used.incl nearest
  true

proc overviewRect(parent: ptr wlr_scene_tree; box: wlr_box; color: Color): ptr wlr_scene_rect =
  result = wlr_scene_rect_create(parent, box.width, box.height, color)
  if result != nil: wlr_scene_node_set_position(addr result.node, box.x, box.y)

proc overviewCaption(parent: ptr wlr_scene_tree; x, y, width: cint; label: string) =
  let color = activeConfig.unfocusedDecoration
  let pixels = renderTitlebarBuffer(width, overviewScale, activeConfig.font.cstring,
    label.cstring, color.background, color.text, color.titlebarBorder, 0)
  if pixels == nil: return
  let buffer = wlr_scene_buffer_create(parent, cast[ptr wlr_buffer](pixels))
  dropTitlebarBuffer(pixels)
  if buffer == nil: return
  wlr_scene_buffer_set_dest_size(buffer, width, TitlebarHeight)
  wlr_scene_node_set_position(addr buffer.node, x, y)

proc snapshotOverview(node: ptr wlr_scene_node; parent: ptr wlr_scene_tree;
    scale: float64; x, y, dx, dy: cint) =
  if not node.enabled: return
  let left = x + node.x
  let top = y + node.y
  case node.type_field
  of WLR_SCENE_NODE_TREE:
    let children = addr wlr_scene_tree_from_node(node).children
    var child = wl_list_first_link(children, cast[ptr wlr_scene_node](nil))
    while wl_list_more_link(child, children):
      snapshotOverview(child, parent, scale, left, top, dx, dy)
      child = wl_list_next_link(child)
  of WLR_SCENE_NODE_BUFFER:
    let source = wlr_scene_buffer_from_node(node)
    if source.buffer == nil: return
    var (width, height) = (source.dst_width, source.dst_height)
    if width == 0 or height == 0:
      (width, height) = (source.buffer.width, source.buffer.height)
      if (ord(source.transform) and 1) != 0: swap(width, height)
    let scaledLeft = cint(round(left.float64 * scale))
    let scaledTop = cint(round(top.float64 * scale))
    width = cint(round((left + width).float64 * scale)) - scaledLeft
    height = cint(round((top + height).float64 * scale)) - scaledTop
    if width <= 0 or height <= 0: return
    let copy = wlr_scene_buffer_create(parent, nil)
    if copy == nil: return
    wlr_scene_node_set_position(addr copy.node, dx + scaledLeft, dy + scaledTop)
    wlr_scene_buffer_set_dest_size(copy, width, height)
    wlr_scene_buffer_set_opacity(copy, source.opacity)
    wlr_scene_buffer_set_filter_mode(copy, source.filter_mode)
    wlr_scene_buffer_set_transfer_function(copy, source.transfer_function)
    wlr_scene_buffer_set_primaries(copy, source.primaries)
    wlr_scene_buffer_set_color_encoding(copy, source.color_encoding)
    wlr_scene_buffer_set_color_range(copy, source.color_range)
    wlr_scene_buffer_set_source_box(copy, addr source.src_box)
    wlr_scene_buffer_set_transform(copy, source.transform)
    wlr_scene_buffer_set_buffer(copy, source.buffer)
  of WLR_SCENE_NODE_RECT: discard # Decorations are not part of the snapshot.

proc drawOverviewCard(entry: var OverviewEntry): bool =
  let box = entry.target
  let tile = wlr_scene_tree_create(overviewCards)
  if tile == nil: return false
  wlr_scene_node_set_position(addr tile.node, box.x, box.y)
  entry.border = overviewRect(tile, wlr_box(width: box.width, height: box.height), OverviewFrameColor)
  let innerWidth = box.width - 2 * OverviewBorder
  let innerHeight = box.height - 2 * OverviewBorder
  if entry.border == nil or overviewRect(tile, wlr_box(x: OverviewBorder, y: OverviewBorder,
      width: innerWidth, height: innerHeight), OverviewCardColor) == nil: return false
  let c = entry.client
  let title = if client_has_title(c): $client_actual_title(c) else: $client_get_appid(c)
  let label = if title.len != 0 and validateUtf8(title) == -1: title else: "Untitled window"
  overviewCaption(tile, OverviewBorder, OverviewBorder, innerWidth,
    if c.isminimized: "Minimized: " & label else: label)
  # Copy content only. In particular, popups, stack badges, and server-side
  # decorations are not part of the snapshot. Use committed content if a
  # configure transaction is still waiting on the client.
  let source = if c.snapshot != nil: c.snapshot else: addr c.scene_surface.node
  let width = c.current.width - 2 * source.x
  let height = c.current.height - source.y - source.x
  let previewHeight = innerHeight - TitlebarHeight
  if width > 0 and height > 0:
    let scale = min(innerWidth.float64 / width.float64, previewHeight.float64 / height.float64)
    snapshotOverview(source, tile, scale, -source.x, -source.y,
      OverviewBorder + (innerWidth - cint(round(width.float64 * scale))) div 2,
      OverviewBorder + TitlebarHeight + (previewHeight - cint(round(height.float64 * scale))) div 2)
  for side in entry.outline.mitems:
    side = overviewRect(overviewFrames, wlr_box(width: 1, height: 1), OverviewFrameColor)
    if side == nil: return false
  true

proc closeWindowOverview() =
  if overviewRoot == nil: return
  if overviewTimer != nil:
    discard wl_event_source_remove(overviewTimer)
    overviewTimer = nil
  wlr_scene_node_destroy(addr overviewRoot.node)
  overviewRoot = nil
  overviewCards = nil
  overviewFrames = nil
  overviewMonitor = nil
  overviewCount = 0

proc overviewHasClient(c: ptr Client): bool =
  for i in 0 ..< overviewCount:
    if overviewEntries[i].client == c: return true

proc overviewCurrent(): bool =
  let m = overviewMonitor
  m != nil and locked == 0 and selmon == m and m.wlr_output.enabled and
    m.w == overviewArea and m.m == overviewOutputBox and m.wlr_output.scale == overviewScale and
    m.tagset[m.seltags] == overviewTags

proc refreshWindowOverview() =
  if overviewRoot == nil: return
  if overviewCurrent():
    for i in 0 ..< overviewCount:
      if not onSelectedTags(overviewEntries[i].client, overviewMonitor):
        closeWindowOverview()
        break
  else:
    closeWindowOverview()

proc highlightOverview(index: int) =
  if index == overviewSelected: return
  if overviewSelected >= 0:
    let old = addr overviewEntries[overviewSelected]
    wlr_scene_rect_set_color(old.border, OverviewFrameColor)
    if overviewFrames != nil:
      for side in old.outline: wlr_scene_rect_set_color(side, OverviewFrameColor)
  overviewSelected = index
  if index >= 0:
    let entry = addr overviewEntries[index]
    wlr_scene_rect_set_color(entry.border, OverviewSelectionColor)
    if overviewFrames != nil:
      for side in entry.outline: wlr_scene_rect_set_color(side, OverviewSelectionColor)

proc drawOverviewFrame(entry: OverviewEntry; progress: float64) =
  template interpolate(field: untyped): cint =
    cint(round(entry.origin.field.float64 + (entry.target.field - entry.origin.field).float64 * progress))
  let x = interpolate(x)
  let y = interpolate(y)
  let w = interpolate(width)
  let h = interpolate(height)
  let bx = min(OverviewBorder, w)
  let by = min(OverviewBorder, h)
  for i, box in [wlr_box(x: x, y: y, width: w, height: by),
      wlr_box(x: x, y: y + h - by, width: w, height: by),
      wlr_box(x: x, y: y, width: bx, height: h),
      wlr_box(x: x + w - bx, y: y, width: bx, height: h)]:
    let side = entry.outline[i]
    wlr_scene_rect_set_size(side, box.width, box.height)
    wlr_scene_node_set_position(addr side.node, box.x, box.y)

proc overviewNow(): float64 =
  var now: timespec
  discard clock_gettime(CLOCK_MONOTONIC, addr now)
  now.tv_sec.float64 * 1000 + now.tv_nsec.float64 / 1_000_000

proc settleOverview() =
  if overviewTimer != nil:
    discard wl_event_source_remove(overviewTimer)
    overviewTimer = nil
  if overviewFrames != nil:
    wlr_scene_node_destroy(addr overviewFrames.node)
    overviewFrames = nil
  wlr_scene_node_set_enabled(addr overviewCards.node, true)

proc animateOverview(data: pointer): cint {.cdecl.} =
  refreshWindowOverview()
  if overviewRoot == nil:
    motionnotify(0, nil, 0, 0, 0, 0)
    return 0
  let remaining = 1.0 - (overviewNow() - overviewStart) / OverviewDuration
  if remaining <= 0 or wl_event_source_timer_update(overviewTimer, 16) != 0:
    settleOverview()
  else:
    let progress = 1.0 - remaining * remaining * remaining
    for i in 0 ..< overviewCount: drawOverviewFrame(overviewEntries[i], progress)

proc dismissOverview() =
  closeWindowOverview()
  motionnotify(0, nil, 0, 0, 0, 0)

proc toggleWindowOverview(arg: ptr Arg) {.cdecl.} =
  if overviewRoot != nil:
    dismissOverview()
    return
  let m = selmon
  if m == nil or m == (addr parkingMonitor) or not m.wlr_output.enabled or cursor_mode != CurNormal or
      not pointerOperationAllowed() or wlr_seat_pointer_has_grab(seat): return
  let area = m.w
  if area.width <= 2 * OverviewGap or area.height <= TitlebarHeight + 2 * OverviewGap: return
  var total = 0
  var selected = 0
  var c = wl_list_first_flink(addr fstack, cast[ptr Client](nil))
  while wl_list_more_flink(c, addr fstack):
    if onSelectedTags(c, m):
      if total < OverviewLimit:
        overviewEntries[total] = OverviewEntry(client: c, origin: overviewOrigin(c.current, area))
        if c == focused_client: selected = total
      inc total
    c = wl_list_next_flink(c)
  let count = min(total, OverviewLimit)
  if count > 0 and not layoutOverview(overviewEntries.toOpenArray(0, count - 1),
      wlr_box(x: OverviewGap, y: OverviewGap, width: area.width - 2 * OverviewGap,
        height: area.height - 2 * OverviewGap - (if total > count: TitlebarHeight + OverviewGap else: 0))):
    return
  closeStackPicker()
  overviewRoot = wlr_scene_tree_create(layers[LyrIMPopup])
  if overviewRoot == nil: return
  overviewMonitor = m
  overviewArea = area
  overviewOutputBox = m.m
  overviewScale = m.wlr_output.scale
  overviewTags = m.tagset[m.seltags]
  overviewCount = count
  overviewSelected = -1
  wlr_scene_node_set_position(addr overviewRoot.node, area.x, area.y)
  if overviewRect(overviewRoot, wlr_box(width: area.width, height: area.height), OverviewScrim) == nil:
    closeWindowOverview()
    return
  if total == 0 or total > count:
    let width = min(240.cint, area.width - 2 * OverviewGap)
    overviewCaption(overviewRoot, (area.width - width) div 2,
      if total == 0: (area.height - TitlebarHeight) div 2 else: area.height - TitlebarHeight - OverviewGap,
      width,
      if total == 0: "No windows" else: $(total - count) & " more windows")
  if count > 0:
    overviewCards = wlr_scene_tree_create(overviewRoot)
    overviewFrames = wlr_scene_tree_create(overviewRoot)
    if overviewCards == nil or overviewFrames == nil:
      closeWindowOverview()
      return
    wlr_scene_node_set_enabled(addr overviewCards.node, false)
    for i in 0 ..< count:
      if not drawOverviewCard(overviewEntries[i]):
        closeWindowOverview()
        return
      drawOverviewFrame(overviewEntries[i], 0)
    highlightOverview(selected)
    overviewStart = overviewNow()
    overviewTimer = wl_event_loop_add_timer(event_loop, animateOverview, nil)
    if overviewTimer == nil or wl_event_source_timer_update(overviewTimer, 16) != 0:
      settleOverview()
  wlr_seat_pointer_notify_clear_focus(seat)
  cursorconstrain(nil)
  wlr_cursor_set_xcursor(cursor, cursor_mgr, "default")

proc selectOverviewWindow(index: int) =
  let c = if index >= 0 and overviewCurrent(): overviewEntries[index].client else: nil
  closeWindowOverview()
  if c != nil and onSelectedTags(c, selmon) and pointerOperationAllowed():
    if c.isminimized: setWindowMinimized(c, false)
    focusclient(c, nil, 1)
  motionnotify(0, nil, 0, 0, 0, 0)

proc overviewWindowAtCursor(): int =
  let x = cursor.x - overviewArea.x.float64
  let y = cursor.y - overviewArea.y.float64
  for i in 0 ..< overviewCount:
    let box = overviewEntries[i].target
    if x >= box.x.float64 and y >= box.y.float64 and
        x < (box.x + box.width).float64 and y < (box.y + box.height).float64:
      return i
  -1

proc overviewButton(event: ptr wlr_pointer_button_event): bool =
  if event.state == WL_POINTER_BUTTON_STATE_RELEASED and event.button <= KEY_MAX.uint32 and
      int(event.button) in overviewButtons:
    overviewButtons.excl int(event.button)
    return true
  if overviewRoot == nil: return false
  if event.state == WL_POINTER_BUTTON_STATE_PRESSED:
    if event.button <= KEY_MAX.uint32: overviewButtons.incl int(event.button)
    if event.button == BTN_LEFT.uint32 and overviewFrames == nil:
      selectOverviewWindow(overviewWindowAtCursor())
  true

proc overviewMotion(time: uint32; device: ptr wlr_input_device; dx, dy: cdouble) =
  if time != 0:
    wlr_cursor_move(cursor, device, dx, dy)
    wlr_idle_notifier_v1_notify_activity(idle_notifier, seat)
  if overviewFrames == nil:
    let index = overviewWindowAtCursor()
    if index >= 0: highlightOverview(index)
    wlr_cursor_set_xcursor(cursor, cursor_mgr, if index >= 0: cstring"pointer" else: cstring"default")

proc overviewKey(sym: xkb_keysym_t; mods: uint32) =
  if sym == XKB_KEY_Escape:
    dismissOverview()
  elif overviewSelected >= 0:
    case sym
    of XKB_KEY_Return, XKB_KEY_KP_Enter: selectOverviewWindow(overviewSelected)
    of XKB_KEY_Tab:
      let step = if (mods and uint32(WLR_MODIFIER_SHIFT)) != 0: -1 else: 1
      highlightOverview((overviewSelected + step + overviewCount) mod overviewCount)
    of XKB_KEY_Left, XKB_KEY_Right, XKB_KEY_Up, XKB_KEY_Down:
      let origin = overviewEntries[overviewSelected].target
      var nearest = overviewSelected
      var best = high(int64)
      for i in 0 ..< overviewCount:
        let target = overviewEntries[i].target
        let dx = overviewCenter(target.x, target.width) - overviewCenter(origin.x, origin.width)
        let dy = overviewCenter(target.y, target.height) - overviewCenter(origin.y, origin.height)
        let (forward, sideways) = case sym
          of XKB_KEY_Left: (-dx, dy)
          of XKB_KEY_Right: (dx, dy)
          of XKB_KEY_Up: (-dy, dx)
          else: (dy, dx)
        if forward <= 0: continue
        let score = int64(forward) * forward + 4 * int64(sideways) * sideways
        if score < best: (nearest, best) = (i, score)
      highlightOverview(nearest)
    else: discard
