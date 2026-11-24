# Find covered windows from the committed scene order, then offer a picker.

proc wlr_seat_pointer_has_grab(seat: ptr wlr_seat): bool {.importc, cdecl.}

const StackLayers = [LyrAbove, LyrFloat, LyrTile]

type StackEntry = object
  client: ptr Client
  iconPath: string

var
  stackPicker: ptr wlr_scene_tree
  stackPickerRows: ptr wlr_scene_tree
  stackPickerHighlight: ptr wlr_scene_rect
  stackPickerOwner: ptr Client
  stackPickerEntries: seq[StackEntry]
  stackPickerBox: wlr_box
  stackPickerFirst, stackPickerSelected: int
  stackPickerGeneration: uint64
  stackPickerScale: cfloat
  stackPickerButtonDown: bool
  windowStacksEnabled: bool

proc stackIntersection(a, b: wlr_box): wlr_box =
  result.x = max(a.x, b.x)
  result.y = max(a.y, b.y)
  result.width = cint(max(0'i64, min(a.x.int64 + a.width, b.x.int64 + b.width) - result.x))
  result.height = cint(max(0'i64, min(a.y.int64 + a.height, b.y.int64 + b.height) - result.y))

proc stackVisibleBox(c: ptr Client): wlr_box =
  stackIntersection(c.current, c.mon.m)

proc stackCovers(frontInZone, back: wlr_box): bool =
  if back.width <= 0 or back.height <= 0: return false
  let overlap = stackIntersection(frontInZone, back)
  let area = int64(back.width) * back.height
  int64(overlap.width) * overlap.height >= (area + 3) div 4

proc stackMatches(front, back: ptr Client; zone: ZoneDef): bool =
  if strcmp(clientZoneName(back), zone.name.cstring) == 0: return true
  let a = front.current
  let b = back.current
  let sameSide = a.x == b.x or a.x.int64 + a.width == b.x.int64 + b.width
  sameSide and (a.y == b.y or a.y.int64 + a.height == b.y.int64 + b.height)

proc stackClient(node: ptr wlr_scene_node): ptr Client =
  if not node.enabled or node.data == nil: return nil
  let c = cast[ptr Client](node.data)
  if c.mon != nil and c.mon != (addr parkingMonitor) and c.mon.wlr_output.enabled and
      VISIBLEON(c, c.mon) and c.isfullscreen == 0:
    return c

iterator stackWindows(owner: ptr Client): ptr Client =
  yield owner
  var node = wl_list_prev_link(addr owner.scene.node)
  let children = addr owner.scene.node.parent.children
  while wl_list_more_link(node, children):
    if node.enabled and node.data != nil:
      let c = cast[ptr Client](node.data)
      if c.hiddenBy == owner: yield c
    node = wl_list_prev_link(node)

proc setStackCaption(node: ptr wlr_scene_buffer; pixels: pointer; width: cint) =
  wlr_scene_buffer_set_buffer(node, cast[ptr wlr_buffer](pixels))
  dropTitlebarBuffer(pixels)
  wlr_scene_buffer_set_dest_size(node, width, TitlebarHeight)

proc updateStackBadge(c: ptr Client) =
  let previousInset = titlebarStackInset(c)
  defer:
    if titlebarStackInset(c) != previousInset: updateTitlebar(c)
  let total = c.hiddenCount + 1
  if c.hiddenCount != 0 and c.titlebar != nil and c.titlebar.node.enabled:
    let box = stackVisibleBox(c)
    var badgeWidth = 56.cint
    var count = total
    while count >= 10:
      count = count div 10
      badgeWidth += 8
    let width = min(box.width, badgeWidth)
    if width >= 48 and box.height >= TitlebarHeight:
      let scale = c.mon.wlr_output.scale
      if c.stackBadge == nil or c.stackBadgeCount != total or
          c.stackBadgeScale != scale or c.stackBadgeWidth != width or
          c.stackBadgeGeneration != titlebarGeneration:
        let label = $total
        let pixels = renderStackCaption(width, scale, activeConfig.font.cstring,
          label.cstring, activeConfig.focusedDecoration, badge = true)
        if pixels == nil: return
        if c.stackBadge == nil:
          c.stackBadge = wlr_scene_buffer_create(c.scene, nil)
          if c.stackBadge == nil:
            dropTitlebarBuffer(pixels)
            return
          c.stackBadge.node.data = c
        setStackCaption(c.stackBadge, pixels, width)
        c.stackBadgeCount = total
        c.stackBadgeScale = scale
        c.stackBadgeWidth = width
        c.stackBadgeGeneration = titlebarGeneration
      wlr_scene_node_set_position(addr c.stackBadge.node,
        box.x + box.width - c.current.x - width, box.y - c.current.y)
      if c.xdgPopups != nil:
        wlr_scene_node_raise_to_top(addr c.xdgPopups.node)
        wlr_scene_node_place_below(addr c.stackBadge.node, addr c.xdgPopups.node)
      else:
        wlr_scene_node_raise_to_top(addr c.stackBadge.node)
      wlr_scene_node_set_enabled(addr c.stackBadge.node, true)
      return
  if c.stackBadge != nil: wlr_scene_node_set_enabled(addr c.stackBadge.node, false)

proc stackBadgeAt(c: ptr Client): bool =
  c != nil and c.stackBadge != nil and c.stackBadge.node.enabled and
    wlr_scene_node_at(addr c.scene.node, cursor.x, cursor.y, nil, nil) == addr c.stackBadge.node

proc closeStackPicker() =
  if stackPicker == nil: return
  wlr_scene_node_destroy(addr stackPicker.node)
  stackPicker = nil
  stackPickerRows = nil
  stackPickerHighlight = nil
  stackPickerOwner = nil
  stackPickerEntries.setLen(0)

proc stackPickerBounds(owner: ptr Client): wlr_box =
  if owner.stackBadge == nil or not owner.stackBadge.node.enabled: return
  let area = owner.mon.w
  result.width = min(320, area.width)
  result.height = cint(min(owner.hiddenCount + 1, int(area.height div TitlebarHeight))) * TitlebarHeight
  if result.width < 48 or result.height <= 0: return
  let x = owner.current.x + owner.stackBadge.node.x + owner.stackBadgeWidth - result.width
  let y = owner.current.y + owner.stackBadge.node.y
  result.x = clamp(x, area.x, area.x + area.width - result.width)
  result.y = clamp(if y + TitlebarHeight + result.height <= area.y + area.height:
    y + TitlebarHeight else: y - result.height, area.y, area.y + area.height - result.height)

proc refreshWindowStacks() =
  let enabled = activeConfig.windowStackPicker
  if not enabled and not windowStacksEnabled: return
  windowStacksEnabled = enabled
  var c = wl_list_first_link(addr clients, cast[ptr Client](nil))
  while wl_list_more_link(c, addr clients):
    c.hiddenBy = nil
    c.hiddenCount = 0
    c = wl_list_next_link(c)
  if enabled and activeConfig.zones.len != 0:
    for layer in StackLayers:
      let children = addr layers[layer].children
      var frontNode = wl_list_last_link(children, cast[ptr wlr_scene_node](nil))
      while wl_list_more_link(frontNode, children):
        let front = stackClient(frontNode)
        if front != nil and front.hiddenBy == nil:
          let zone = zoneClientIndex(front)
          if zone >= 0:
            let target = activeConfig.zones[zone].zoneBox(zoneBoxFromWlr(front.mon.w))
            let frontInZone = stackIntersection(front.current, wlrBoxFromZone(target))
            if frontInZone.width > 0 and frontInZone.height > 0:
              var backNode = wl_list_prev_link(frontNode)
              while wl_list_more_link(backNode, children):
                let back = stackClient(backNode)
                if back != nil and back.hiddenBy == nil and back.mon == front.mon and
                    stackMatches(front, back, activeConfig.zones[zone]) and
                    stackCovers(frontInZone, back.current):
                  back.hiddenBy = front
                  inc front.hiddenCount
                backNode = wl_list_prev_link(backNode)
        frontNode = wl_list_prev_link(frontNode)
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    updateStackBadge(c)
    c = wl_list_next_link(c)
  if stackPicker != nil:
    let owner = stackPickerOwner
    if owner.hiddenCount + 1 != stackPickerEntries.len or stackPickerBounds(owner) != stackPickerBox or
        owner.mon.wlr_output.scale != stackPickerScale or titlebarGeneration != stackPickerGeneration:
      closeStackPicker()
      return
    var i = 0
    for c in stackWindows(owner):
      if c != stackPickerEntries[i].client:
        closeStackPicker()
        return
      inc i

proc localIconName(name: string): bool =
  name.len != 0 and name notin [".", ".."] and '/' notin name and '\\' notin name

proc stackAppIcon(appId: string; dataDirs: openArray[string]): string =
  if not localIconName(appId): return
  var name = appId
  let desktop = if appId.endsWith(".desktop"): appId else: appId & ".desktop"
  for dir in dataDirs:
    let file = dir / "applications" / desktop
    if not fileExists(file): continue
    try:
      var desktopEntry = false
      for line in lines(file):
        if line.startsWith('['): desktopEntry = line == "[Desktop Entry]"
        elif desktopEntry and line.startsWith("Icon="):
          name = line[5 .. ^1].strip
          break
    except IOError: discard
    break
  if name.isAbsolute:
    if name.endsWith(".png") and fileExists(name): return name
    return
  if not localIconName(name): return
  if not name.endsWith(".png"): name.add(".png")
  for size in ["16x16", "22x22", "24x24", "32x32", "48x48", "64x64",
      "72x72", "96x96", "128x128", "192x192", "256x256", "512x512"]:
    for dir in dataDirs:
      let path = dir / "icons" / "hicolor" / size / "apps" / name
      if fileExists(path): return path
  for dir in dataDirs:
    let path = dir / "pixmaps" / name
    if fileExists(path): return path

proc pickerRowCount(): int = int(stackPickerBox.height div TitlebarHeight)

proc updateStackPickerHighlight() =
  let row = stackPickerSelected - stackPickerFirst
  wlr_scene_node_set_enabled(addr stackPickerHighlight.node, row >= 0 and row < pickerRowCount())
  wlr_scene_node_set_position(addr stackPickerHighlight.node, 2, cint(row) * TitlebarHeight + 2)

proc drawStackPickerRows() =
  if stackPickerRows != nil: wlr_scene_node_destroy(addr stackPickerRows.node)
  stackPickerRows = wlr_scene_tree_create(stackPicker)
  let scale = stackPickerOwner.mon.wlr_output.scale
  let colors = activeConfig.unfocusedDecoration
  for i in 0 ..< pickerRowCount():
    let entry = addr stackPickerEntries[stackPickerFirst + i]
    let c = entry.client
    let title = if client_has_title(c): $client_actual_title(c) else: $client_get_appid(c)
    let label = if title.len != 0 and validateUtf8(title) == -1: title else: "Untitled window"
    let pixels = renderStackCaption(stackPickerBox.width, scale, activeConfig.font.cstring,
      label.cstring, colors, iconPath = entry.iconPath.cstring)
    if pixels == nil:
      closeStackPicker()
      return
    let row = wlr_scene_buffer_create(stackPickerRows, nil)
    if row == nil:
      dropTitlebarBuffer(pixels)
      closeStackPicker()
      return
    setStackCaption(row, pixels, stackPickerBox.width)
    wlr_scene_node_set_position(addr row.node, 0, cint(i) * TitlebarHeight)
  wlr_scene_node_raise_to_top(addr stackPickerHighlight.node)
  updateStackPickerHighlight()

proc openStackPicker(owner: ptr Client): bool =
  let box = stackPickerBounds(owner)
  if owner.hiddenCount == 0 or box.width < 48 or box.height <= 0: return false
  stackPicker = wlr_scene_tree_create(layers[LyrOverlay])
  stackPickerOwner = owner
  stackPickerBox = box
  stackPickerScale = owner.mon.wlr_output.scale
  stackPickerGeneration = titlebarGeneration
  stackPickerFirst = 0
  stackPickerSelected = 0
  wlr_scene_node_set_position(addr stackPicker.node, box.x, box.y)
  var dataDirs = @[getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")]
  for dir in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
    if dir.isAbsolute: dataDirs.add(dir)
  for c in stackWindows(owner):
    stackPickerEntries.add StackEntry(client: c, iconPath: stackAppIcon($client_get_appid(c), dataDirs))
  if stackPickerEntries.len < pickerRowCount():
    closeStackPicker()
    return false
  stackPickerHighlight = wlr_scene_rect_create(stackPicker, 3, TitlebarHeight - 4,
    activeConfig.unfocusedDecoration.text)
  drawStackPickerRows()
  if stackPicker == nil: return false
  wlr_seat_pointer_notify_clear_focus(seat)
  wlr_cursor_set_xcursor(cursor, cursor_mgr, "default")
  true

proc stackPickerRowAtCursor(): int =
  let box = stackPickerBox
  if cursor.x >= cdouble(box.x) and cursor.x < cdouble(box.x + box.width) and
      cursor.y >= cdouble(box.y) and cursor.y < cdouble(box.y + box.height):
    return stackPickerFirst + int(cursor.y - cdouble(box.y)) div int(TitlebarHeight)
  -1

proc selectStackPickerRow(index: int) =
  let c = if index >= 0: stackPickerEntries[index].client else: nil
  closeStackPicker()
  if c != nil and c.scene.node.enabled and VISIBLEON(c, c.mon):
    focusclient(c, nil, 1)
  motionnotify(0, nil, 0, 0, 0, 0)

proc moveStackPickerSelection(step: int) =
  let previous = stackPickerFirst
  let count = pickerRowCount()
  stackPickerSelected = clamp(stackPickerSelected + step, 0, stackPickerEntries.high)
  stackPickerFirst = clamp(stackPickerFirst, max(0, stackPickerSelected - count + 1), stackPickerSelected)
  if stackPickerFirst != previous: drawStackPickerRows()
  else: updateStackPickerHighlight()

proc stackPickerKey(sym: xkb_keysym_t): bool =
  case sym
  of XKB_KEY_Escape: selectStackPickerRow(-1)
  of XKB_KEY_Return: selectStackPickerRow(stackPickerSelected)
  of XKB_KEY_Up: moveStackPickerSelection(-1)
  of XKB_KEY_Down: moveStackPickerSelection(1)
  else: return false
  true
