# Assign windows to named zones and apply the zone layout. Handle fixed-size
# placement, zone-based focus cycling, and configuration changes.

# This file is included after runtime_apply.nim and before compositor.nim.

proc zoneBoxFromWlr(box: wlr_box): ZoneBox {.inline.} =
  ZoneBox(x: box.x, y: box.y, width: box.width, height: box.height)

proc wlrBoxFromZone(box: ZoneBox): wlr_box {.inline.} =
  wlr_box(x: box.x, y: box.y, width: box.width, height: box.height)

proc zoneBoxValid(box: ZoneBox): bool {.inline.} =
  box.width > 0 and box.height > 0

proc clearClientZoneName(c: ptr Client) {.inline.} =
  var i = 0
  while i < c.zoneName.len:
    c.zoneName[i] = '\0'
    inc i

proc setClientZoneName(c: ptr Client; name: string) {.inline.} =
  clearClientZoneName(c)
  let count = min(name.len, c.zoneName.len - 1)
  var i = 0
  while i < count:
    c.zoneName[i] = name[i]
    inc i

proc setClientZoneName(c: ptr Client; zone: ZoneDef) {.inline.} =
  setClientZoneName(c, zone.name)

proc clientZoneName(c: ptr Client): cstring {.inline.} =
  cast[cstring](addr c.zoneName[0])

proc clientZoneIndexIn(c: ptr Client; zones: openArray[ZoneDef]): int {.inline.} =
  if c == nil: return -1
  let name = clientZoneName(c)
  if name[0] == '\0': return -1
  for i, zone in zones:
    if zone.name.len != 0 and strcmp(name, zone.name.cstring) == 0:
      return i
  -1

proc zoneClientIndex*(c: ptr Client): int =
  clientZoneIndexIn(c, activeConfig.zones)

proc clientHasNativeFixedSize(c: ptr Client): bool {.inline.} =
  var maximum, minimum: wlr_box
  client_get_size_hints(c, addr maximum, addr minimum)
  minimum.width > 0 and minimum.height > 0 and maximum.width == minimum.width and
    maximum.height == minimum.height

proc managedZoneClient(c: ptr Client; m: ptr Monitor): bool {.inline.} =
  c != nil and m != nil and c.mon == m and client_is_unmanaged(c) == 0 and
    client_surface(c) != nil and client_surface(c).mapped and
    VISIBLEON(c, m) and c.isfullscreen == 0 and not client_places_manually(c) and not c.ismaximized

proc zonePlacementFor(c: ptr Client; index: int; m: ptr Monitor): ZoneBox {.inline.} =
  if c == nil or m == nil or index < 0 or index >= activeConfig.zones.len:
    return
  zonePlacement(activeConfig.zones[index], zoneBoxFromWlr(m.w),
    zoneBoxFromWlr(c.geom), c.isfixed != 0)

proc centerInArea(c: ptr Client; area: ZoneBox): ZoneBox {.inline.} =
  if c == nil or not zoneBoxValid(area): return
  let width = max(c.geom.width, 1).int64
  let height = max(c.geom.height, 1).int64
  var x = area.x.int64 + (area.width.int64 - width) div 2
  var y = area.y.int64 + (area.height.int64 - height) div 2
  if width <= area.width.int64:
    x = max(area.x.int64, min(x, area.x.int64 + area.width.int64 - width))
  else:
    x = area.x.int64
  if height <= area.height.int64:
    y = max(area.y.int64, min(y, area.y.int64 + area.height.int64 - height))
  else:
    y = area.y.int64
  if x < low(int32).int64 or y < low(int32).int64 or
      width > high(int32).int64 or height > high(int32).int64:
    return
  ZoneBox(x: x.int32, y: y.int32, width: width.int32, height: height.int32)

proc resizeZoneClient(c: ptr Client; placement: ZoneBox) {.inline.} =
  if c == nil or not zoneBoxValid(placement) or c.mon == nil or
      client_surface(c) == nil or not client_surface(c).mapped or
      c.isfullscreen != 0:
    return
  resize(c, wlrBoxFromZone(placement), 0)

proc recordClientZone(c: ptr Client; index: int) =
  forgetOutputPlacement(c)
  setClientZoneName(c, activeConfig.zones[index])
  c.zoneInitialized = true

proc assignClientZone*(c: ptr Client; index: int) =
  if c == nil or c.mon == nil or c.alwaysOnTop or index < 0 or index >= activeConfig.zones.len:
    return
  recordClientZone(c, index)
  # An explicit zone command or a normal drop restores automatic placement.
  c.isfloating = 0
  if c.isfullscreen == 0:
    let placement = zonePlacementFor(c, index, c.mon)
    resizeZoneClient(c, placement)
  arrange(c.mon)

proc initializeZoneClient*(c: ptr Client) =
  if c == nil or c.zoneInitialized or c.mon == nil or
      client_is_unmanaged(c) != 0:
    return
  c.zoneInitialized = true

  # Native fixed-size hints are a placement property even when applyrules made
  # the dialog floating.  Keep the native dimensions and center it once.
  let nativeFixedSize = clientHasNativeFixedSize(c)
  if nativeFixedSize: c.isfixed = 1

  if c.isfloating != 0 or c.alwaysOnTop:
    if nativeFixedSize and c.isfloating != 0:
      resizeZoneClient(c, centerInArea(c, zoneBoxFromWlr(c.mon.w)))
    return
  if activeConfig.zones.len == 0: return

  let area = zoneBoxFromWlr(c.mon.w)
  let window = zoneBoxFromWlr(c.geom)
  var index = -1
  if c.isfixed != 0:
    let parent = client_get_parent(c)
    if parent != nil and parent.mon == c.mon:
      index = zoneClientIndex(parent)
    if index < 0 and zoneBoxValid(window):
      index = bestZone(activeConfig.zones, area, window)
    if index < 0: index = 0
  else:
    var foundVacant = false
    var bestSize = Inf
    for candidate, definition in activeConfig.zones:
      var occupied = false
      var other: ptr Client
      other = wl_list_first_link(addr clients, other)
      while wl_list_more_link(other, addr clients):
        if other != c and managedZoneClient(other, c.mon) and zoneClientIndex(other) == candidate:
          occupied = true
          break
        other = wl_list_next_link(other)
      if occupied and foundVacant: continue
      let target = zoneBox(definition, area)
      if not zoneBoxValid(target): continue
      let difference = abs(float64(target.width) - float64(window.width)) /
          max(float64(target.width), max(float64(window.width), 1.0)) +
        abs(float64(target.height) - float64(window.height)) /
          max(float64(target.height), max(float64(window.height), 1.0))
      if (not occupied and not foundVacant) or difference < bestSize:
        index = candidate
        bestSize = difference
      if not occupied: foundVacant = true

  if index < 0: return
  setClientZoneName(c, activeConfig.zones[index])
  if c.isfixed != 0:
    var placement = zonePlacementFor(c, index, c.mon)
    # Without usable initial geometry, centre the unparented dialog on the output.
    if not zoneBoxValid(window): placement = centerInArea(c, area)
    resizeZoneClient(c, placement)
  else:
    resizeZoneClient(c, zonePlacementFor(c, index, c.mon))

proc zonelayout*(m: ptr Monitor) {.cdecl.} =
  if m == nil or m.wlr_output == nil or not m.wlr_output.enabled or
      activeConfig.zones.len == 0:
    return
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    if managedZoneClient(c, m):
      let index = zoneClientIndex(c)
      if index >= 0:
        resizeZoneClient(c, zonePlacementFor(c, index, m))
    c = wl_list_next_link(c)

proc moveToZone*(arg: ptr Arg) {.cdecl.} =
  let c = focusedWindowForCommand()
  if c == nil or c.isfullscreen != 0 or arg == nil or arg.i < 0 or int(arg.i) >= activeConfig.zones.len:
    return
  assignClientZone(c, int(arg.i))

proc setClientFixedSize(c: ptr Client; value: cint) =
  if c == nil: return
  c.isfixed = if value < 0: cint(c.isfixed == 0) else: cint(value != 0)
  if c.mon != nil and c.isfullscreen == 0:
    arrange(c.mon)

proc setFixedSize*(arg: ptr Arg) {.cdecl.} =
  setClientFixedSize(focusedWindowForCommand(), if arg == nil: -1.cint else: arg.i)

proc cycleZoneRequested(indices: openArray[cint]; index: int): bool {.inline.} =
  if index < 0: return false
  for requested in indices:
    if requested >= 0 and int(requested) == index: return true
  false

proc visibleZoneMember(c: ptr Client; m: ptr Monitor): bool {.inline.} =
  VISIBLEON(c, m) and c.isfullscreen == 0 and not c.alwaysOnTop

proc swapZones(target: int; focusSource: bool) =
  let current = focusedWindowForCommand()
  if current == nil or seat.drag != nil: return
  let m = current.mon
  if m == addr(parkingMonitor) or not m.wlr_output.enabled or
      m.lt[m.sellt] != addr(layouts[layoutZonesIndex]) or
      not visibleZoneMember(current, m) or current.ismaximized:
    return
  let source = zoneClientIndex(current)
  if source < 0 or source == target: return
  let area = zoneBoxFromWlr(m.w)
  let fromBox = zoneBox(activeConfig.zones[source], area)
  let toBox = zoneBox(activeConfig.zones[target], area)
  if not zoneBoxValid(fromBox) or not zoneBoxValid(toBox): return

  let dx = int64(toBox.x) - fromBox.x
  let dy = int64(toBox.y) - fromBox.y
  var incoming: ptr Client
  var c = wl_list_first_flink(addr fstack, current)
  while wl_list_more_flink(c, addr fstack):
    if visibleZoneMember(c, m) and not c.ismaximized:
      let index = zoneClientIndex(c)
      if index == source or index == target:
        let outgoing = index == source
        if not outgoing and incoming == nil: incoming = c
        recordClientZone(c, if outgoing: target else: source)
        if c.isfloating != 0:
          var frame = c.geom
          frame.x = cint(clamp(int64(frame.x) + (if outgoing: dx else: -dx),
            int64(low(cint)), int64(high(cint))))
          frame.y = cint(clamp(int64(frame.y) + (if outgoing: dy else: -dy),
            int64(low(cint)), int64(high(cint))))
          resize(c, frame, 0)
    c = wl_list_next_flink(c)
  arrange(m)
  focusclient(if focusSource and incoming != nil: incoming else: current, nil, 1)
  publishCompositorState()

proc cycleZoneEligible(c: ptr Client; indices: openArray[cint]): bool {.inline.} =
  visibleZoneMember(c, selmon) and cycleZoneRequested(indices, zoneClientIndex(c))

proc topZoneMember(indices: openArray[cint]): ptr Client =
  # Client trees are direct children of these layers; other nodes have no data.
  for layer in [LyrFS, LyrFloat, LyrTile]:
    let children = addr layers[layer].children
    var node: ptr wlr_scene_node
    node = wl_list_last_link(children, node)
    while wl_list_more_link(node, children):
      if node.enabled and node.data != nil:
        let c = cast[ptr Client](node.data)
        if cycleZoneEligible(c, indices): return c
      node = wl_list_prev_link(node)

proc cycleZones*(indices: openArray[cint]) =
  let current = focusedWindowForCommand()
  if current == nil or indices.len == 0: return
  if not cycleZoneEligible(current, indices):
    let top = topZoneMember(indices)
    if top != nil: focusclient(top, nil, 1)
    return

  # Once inside the group, use stable client-list order to cycle and wrap.
  var found = false
  var next: ptr Client
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    if c == current: found = true
    elif found and cycleZoneEligible(c, indices):
      next = c
      break
    c = wl_list_next_link(c)

  if next == nil:
    c = wl_list_first_link(addr clients, c)
    while wl_list_more_link(c, addr clients):
      if c != current and cycleZoneEligible(c, indices):
        next = c
        break
      c = wl_list_next_link(c)

  focusclient(if next != nil: next else: current, nil, 1)

proc refreshZoneConfig*(previous: RuntimeConfig) =
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    let currentIndex = zoneClientIndex(c)
    if clientZoneName(c)[0] != '\0' and currentIndex < 0:
      if activeConfig.zones.len == 0:
        clearClientZoneName(c)
      else:
        setClientZoneName(c, activeConfig.zones[0])
    if not client_places_manually(c) and activeConfig.zones.len != 0 and clientZoneName(c)[0] == '\0':
      c.zoneInitialized = false
      initializeZoneClient(c)
    c = wl_list_next_link(c)

  let layoutChanged = previous.layout != activeConfig.layout
  let targetLayout = configuredLayout(activeConfig.layout)
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if layoutChanged and m.lt[m.sellt] != targetLayout:
      m.sellt = m.sellt xor 1
    arrange(m)
    m = wl_list_next_link(m)
