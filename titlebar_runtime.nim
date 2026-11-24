# Manage titlebar scene buffers and appearance. Update window frame geometry
# when the titlebar or border changes.

var titlebarGeneration = 1'u64

proc refreshTitlebarConfig() =
  inc titlebarGeneration

proc titlebarStackInset(c: ptr Client): cint =
  if c.stackBadge != nil and c.stackBadge.node.enabled and c.stackBadge.node.y == 0:
    return max(0, c.current.width - c.stackBadge.node.x)

proc updateTitlebar(c: ptr Client; force: bool) =
  if c == nil or c.scene == nil or client_is_unmanaged(c) != 0 or
      client_surface(c) == nil or not client_surface(c).mapped: return
  if not client_wants_titlebar(c):
    if c.titlebar != nil:
      wlr_scene_node_destroy(addr c.titlebar.node)
      c.titlebar = nil
    c.titlebarDirty = true
    return
  if c.isfullscreen != 0:
    if c.titlebar != nil: wlr_scene_node_set_enabled(addr c.titlebar.node, false)
    return
  let width = if c.current.width > 0: c.current.width else: c.geom.width
  if width <= 0: return
  let scale = if c.mon != nil: c.mon.wlr_output.scale else: 1.cfloat
  let style = if c == focused_client: 1.cint elif c.isurgent != 0: 2.cint else: 0.cint
  let stackInset = titlebarStackInset(c)
  if force or c.titlebar == nil or c.titlebarDirty or c.titlebarWidth != width or
      c.titlebarScale != scale or c.titlebarStyle != style or
      c.titlebarGeneration != titlebarGeneration or c.titlebarStackWidth != stackInset:
    let colors = if style == 1: activeConfig.focusedDecoration
      elif style == 2: activeConfig.urgentDecoration else: activeConfig.unfocusedDecoration
    let buffer = cast[ptr wlr_buffer](renderTitlebarBuffer(width, scale, activeConfig.font.cstring,
      client_actual_title(c), colors.background, colors.text, colors.titlebarBorder, cint(c.bw),
      rightInset = stackInset))
    if buffer == nil:
      discard fprintf(stderr, "nimzo: could not render titlebar for %s\n", client_get_appid(c))
      return
    if c.titlebar == nil:
      c.titlebar = wlr_scene_buffer_create(c.scene, nil)
      if c.titlebar == nil:
        dropTitlebarBuffer(cast[pointer](buffer))
        die("nimzo: could not create titlebar scene buffer")
      c.titlebar.node.data = cast[pointer](c)
      if c.stackBadge != nil:
        wlr_scene_node_place_below(addr c.titlebar.node, addr c.stackBadge.node)
    wlr_scene_buffer_set_buffer(c.titlebar, buffer)
    dropTitlebarBuffer(cast[pointer](buffer))
    wlr_scene_buffer_set_dest_size(c.titlebar, width, TitlebarHeight)
    c.titlebarWidth = width
    c.titlebarScale = scale
    c.titlebarStyle = style
    c.titlebarGeneration = titlebarGeneration
    c.titlebarStackWidth = stackInset
    c.titlebarDirty = false
  wlr_scene_node_set_position(addr c.titlebar.node, 0, 0)
  wlr_scene_node_set_enabled(addr c.titlebar.node, true)

proc applyFrameChange(c: ptr Client; dw, dh: cint; newWindow: bool) =
  c.titlebarDirty = true
  if dw == 0 and dh == 0: return
  let preserveContent = newWindow or client_places_manually(c) or c.isfixed != 0 or
    c.mon == nil or c.mon.lt[c.mon.sellt].arrange == nil
  if c.ismaximized and preserveContent:
    c.maximizeRestore.width += dw
    c.maximizeRestore.height += dh
  if c.isfullscreen != 0:
    if preserveContent:
      c.prev.width += dw
      c.prev.height += dh
    return
  var geometry = c.geom
  if preserveContent and not c.ismaximized:
    geometry.width += dw
    geometry.height += dh
  if c.mon == nil:
    c.geom = geometry
  else:
    resize(c, geometry, 0)
    arrange(c.mon)

proc applyTitlebarChange(c: ptr Client; hadBar: bool; newWindow = false) =
  let border = if c.hideBorder: 0.cint else: cint(borderpx)
  let delta = (if client_wants_titlebar(c): TitlebarHeight else: border) -
    (if hadBar: TitlebarHeight else: border)
  applyFrameChange(c, 0, delta, newWindow)
  updateTitlebar(c)

proc setClientTitlebar(c: ptr Client; value: cint; newWindow: bool) =
  if c == nil: return
  let enabled = if value < 0: not c.showTitlebar else: value != 0
  if enabled == c.showTitlebar: return
  let hadBar = client_wants_titlebar(c)
  c.showTitlebar = enabled
  c.titlebarInitialized = true
  applyTitlebarChange(c, hadBar, newWindow)
  publishCompositorState()

proc setTitlebarWindow(arg: ptr Arg) {.cdecl.} =
  setClientTitlebar(focusedWindowForCommand(), if arg == nil: -1.cint else: arg.i)

proc setClientBorder(c: ptr Client; value: cint; newWindow: bool) =
  if c == nil: return
  let hide = if value < 0: not c.hideBorder else: value == 0
  if hide == c.hideBorder: return
  c.hideBorder = hide
  let delta = if hide: -cint(borderpx) else: cint(borderpx)
  if c.isfullscreen == 0:
    c.bw = if hide: 0'u32 else: borderpx
  applyFrameChange(c, 2 * delta,
    if client_wants_titlebar(c): delta else: 2 * delta, newWindow)
  updateTitlebar(c)
  publishCompositorState()

proc setBorderWindow(arg: ptr Arg) {.cdecl.} =
  setClientBorder(focusedWindowForCommand(), if arg == nil: -1.cint else: arg.i)
