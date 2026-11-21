# See LICENSE for copyright and license details.

# Provide common operations for XDG and Xwayland clients: surface lookup,
# window properties, frame geometry, and protocol notifications.

proc client_wants_titlebar(c: ptr Client): bool {.inline.} =
  c.showTitlebar and c.hasTitle

proc client_title_height(c: ptr Client): cint {.inline.} =
  if client_wants_titlebar(c) and c.isfullscreen == 0: TitlebarHeight else: 0

proc client_top_inset(c: ptr Client): cint {.inline.} =
  let title = client_title_height(c)
  if title != 0: title else: cint(c.bw)

proc client_frame_height(c: ptr Client): cint {.inline.} =
  client_top_inset(c) + cint(c.bw)

proc client_places_manually(c: ptr Client): bool {.inline.} =
  c.isfloating != 0 or c.alwaysOnTop

proc updateTitlebar(c: ptr Client; force = false)

proc client_is_x11(c: ptr Client): cint =
  when defined(XWAYLAND):
    return cint(c.`type` == X11)
  return 0

proc client_get_size_hints(c: ptr Client; maximum, minimum: ptr wlr_box) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      let hints = c.surface.xwayland.size_hints
      if hints != nil:
        maximum.width = hints.max_width
        maximum.height = hints.max_height
        minimum.width = hints.min_width
        minimum.height = hints.min_height
      return
  let state = addr c.surface.xdg.toplevel.current
  maximum.width = cint(state.max_width)
  maximum.height = cint(state.max_height)
  minimum.width = cint(state.min_width)
  minimum.height = cint(state.min_height)

proc client_surface(c: ptr Client): ptr wlr_surface =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return c.surface.xwayland.surface
  c.surface.xdg.surface

proc toplevel_from_wlr_surface(s: ptr wlr_surface; pc: ptr ptr Client;
    pl: ptr ptr LayerSurface): cint =
  if s == nil: return -1
  let root = wlr_surface_get_root_surface(s)
  var c: ptr Client
  var l: ptr LayerSurface
  var kind: cint = -1
  block resolve:
    when defined(XWAYLAND):
      let xs = wlr_xwayland_surface_try_from_wlr_surface(root)
      if xs != nil:
        c = cast[ptr Client](xs.data)
        kind = cint(c.`type`)
        break resolve
    let layer = wlr_layer_surface_v1_try_from_wlr_surface(root)
    if layer != nil:
      l = cast[ptr LayerSurface](layer.data)
      kind = LayerShell
      break resolve
    var xdg = wlr_xdg_surface_try_from_wlr_surface(root)
    while xdg != nil:
      case xdg.role
      of WLR_XDG_SURFACE_ROLE_POPUP:
        if xdg.popup == nil or xdg.popup.parent == nil: return -1
        let parent = xdg.popup.parent
        xdg = wlr_xdg_surface_try_from_wlr_surface(parent)
        if xdg == nil: return toplevel_from_wlr_surface(parent, pc, pl)
      of WLR_XDG_SURFACE_ROLE_TOPLEVEL:
        if xdg.toplevel == nil: return -1
        c = cast[ptr Client](xdg.data)
        kind = cint(c.`type`)
        break resolve
      else: return -1
  if pl != nil: pl[] = l
  if pc != nil: pc[] = c
  kind

proc client_activate_surface(s: ptr wlr_surface; activated: cint) =
  when defined(XWAYLAND):
    let xs = wlr_xwayland_surface_try_from_wlr_surface(s)
    if xs != nil:
      wlr_xwayland_surface_activate(xs, activated != 0)
      return
  let top = wlr_xdg_toplevel_try_from_wlr_surface(s)
  if top != nil: discard wlr_xdg_toplevel_set_activated(top, activated != 0)

proc client_set_bounds(c: ptr Client; width, height: int32): uint32 =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return 0
  if wl_resource_get_version(c.surface.xdg.toplevel.resource) >= XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION and
      width >= 0 and height >= 0 and (c.bounds.width != width or c.bounds.height != height):
    c.bounds.width = width
    c.bounds.height = height
    return wlr_xdg_toplevel_set_bounds(c.surface.xdg.toplevel, width, height)
  0

proc client_get_appid(c: ptr Client): cstring =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      return if c.surface.xwayland.`class` != nil: c.surface.xwayland.`class` else: cstring"broken"
  if c.surface.xdg.toplevel.app_id != nil: c.surface.xdg.toplevel.app_id else: cstring"broken"

proc client_get_clip(c: ptr Client; clip: ptr wlr_box) =
  clip[] = wlr_box(x: 0, y: 0, width: max(1, c.geom.width - 2 * cint(c.bw)),
    height: max(1, c.geom.height - client_frame_height(c)))
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return
  clip.x = c.surface.xdg.geometry.x
  clip.y = c.surface.xdg.geometry.y

proc client_get_geometry(c: ptr Client; geom: ptr wlr_box) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      geom[] = wlr_box(x: cint(c.surface.xwayland.x), y: cint(c.surface.xwayland.y),
        width: cint(c.surface.xwayland.width), height: cint(c.surface.xwayland.height))
      return
  geom[] = c.surface.xdg.geometry
  geom.x = 0
  geom.y = 0

proc client_get_parent(c: ptr Client): ptr Client =
  var p: ptr Client
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      if c.surface.xwayland.parent != nil:
        discard toplevel_from_wlr_surface(c.surface.xwayland.parent.surface, addr p, nil)
      return p
  if c.surface.xdg.toplevel.parent != nil:
    discard toplevel_from_wlr_surface(c.surface.xdg.toplevel.parent.base.surface, addr p, nil)
  p

proc client_has_children(c: ptr Client): cint =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return cint(wl_list_empty(addr c.surface.xwayland.children) == 0)
  cint(wl_list_length(addr c.surface.xdg.link) > 1)

proc client_actual_title(c: ptr Client): cstring =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      return c.surface.xwayland.title
  c.surface.xdg.toplevel.title

proc client_has_title(c: ptr Client): bool {.inline.} =
  let title = client_actual_title(c)
  title != nil and title[0] != '\0'

proc client_get_title(c: ptr Client): cstring =
  let title = client_actual_title(c)
  if title != nil: title else: cstring"broken"

proc clientWindowProperties(c: ptr Client): WindowProperties =
  result.appId = $client_get_appid(c)
  result.title = $client_get_title(c)
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      result.isXwayland = true
      if c.surface.xwayland.`class` != nil:
        result.className = $c.surface.xwayland.`class`
      if c.surface.xwayland.instance != nil:
        result.instance = $c.surface.xwayland.instance

proc client_is_float_type(c: ptr Client): cint =
  var minimum, maximum: wlr_box
  client_get_size_hints(c, addr maximum, addr minimum)
  let fixed = minimum.width > 0 and minimum.height > 0 and
    (minimum.width == maximum.width or minimum.height == maximum.height)
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      let s = c.surface.xwayland
      if s.modal or wlr_xwayland_surface_has_window_type(s, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DIALOG) or
          wlr_xwayland_surface_has_window_type(s, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH) or
          wlr_xwayland_surface_has_window_type(s, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLBAR) or
          wlr_xwayland_surface_has_window_type(s, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_UTILITY): return 1
      return cint(fixed)
  cint(c.surface.xdg.toplevel.parent != nil or fixed)

proc client_is_unmanaged(c: ptr Client): cint =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return cint(c.surface.xwayland.override_redirect)
  0

proc focusedWindowForCommand(): ptr Client {.inline.} =
  if locked != 0 or grabc != nil or selmon == nil or focused_client == nil:
    return nil
  let c = focused_client
  if seat.keyboard_state.focused_surface != client_surface(c):
    return nil
  if c.mon != selmon or client_is_unmanaged(c) != 0 or
      client_surface(c) == nil or not client_surface(c).mapped or
      not VISIBLEON(c, selmon):
    return nil
  c

proc client_notify_enter(s: ptr wlr_surface; kb: ptr wlr_keyboard) =
  if kb == nil:
    wlr_seat_keyboard_notify_enter(seat, s, nil, 0, nil)
    return
  var filtered: array[WLR_KEYBOARD_KEYS_CAP, uint32]
  var count: csize_t = 0
  for i in 0 ..< int(kb.num_keycodes):
    let key = kb.keycodes[i]
    if key >= uint32(consumed.len) or consumed[key] == 0:
      filtered[count] = key
      inc count
  wlr_seat_keyboard_notify_enter(seat, s, cast[ptr UncheckedArray[uint32]](addr filtered[0]), count, addr kb.modifiers)

proc client_send_close(c: ptr Client) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      wlr_xwayland_surface_close(c.surface.xwayland)
      return
  wlr_xdg_toplevel_send_close(c.surface.xdg.toplevel)

proc client_set_border_color(c: ptr Client; color: array[4, cfloat]) =
  for i in 0 ..< 4: wlr_scene_rect_set_color(c.border[i], color)
  updateTitlebar(c)

proc client_set_fullscreen(c: ptr Client; fullscreen: cint) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      wlr_xwayland_surface_set_fullscreen(c.surface.xwayland, fullscreen != 0)
      return
  discard wlr_xdg_toplevel_set_fullscreen(c.surface.xdg.toplevel, fullscreen != 0)

proc client_set_maximized(c: ptr Client; maximized: bool) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      wlr_xwayland_surface_set_maximized(c.surface.xwayland, maximized, maximized)
      return
  discard wlr_xdg_toplevel_set_maximized(c.surface.xdg.toplevel, maximized)

when defined(XWAYLAND):
  proc xwaylandSetMinimized(surface: ptr wlr_xwayland_surface; minimized: bool)
    {.cdecl, importc: "wlr_xwayland_surface_set_minimized".}
  type XwaylandMinimizeEvent {.bycopy.} = object
    surface: ptr wlr_xwayland_surface
    minimize: bool

proc client_set_scale(s: ptr wlr_surface; scale: cfloat) =
  wlr_fractional_scale_v1_notify_scale(s, scale)
  wlr_surface_set_preferred_buffer_scale(s, int32(ceilf(scale)))

proc client_set_size(c: ptr Client; width, height: uint32): uint32 =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      wlr_xwayland_surface_configure(c.surface.xwayland, int16(c.geom.x + cint(c.bw)),
        int16(c.geom.y + client_top_inset(c)), uint16(width), uint16(height))
      return uint32(cint(width) != client_surface(c).current.width or cint(height) != client_surface(c).current.height)
  if int32(width) == c.surface.xdg.toplevel.scheduled.width and int32(height) == c.surface.xdg.toplevel.scheduled.height: return 0
  wlr_xdg_toplevel_set_size(c.surface.xdg.toplevel, int32(width), int32(height))

proc client_send_frame_done_iterator(s: ptr wlr_surface; sx, sy: cint; data: pointer) {.cdecl.} =
  wlr_surface_send_frame_done(s, cast[ptr timespec](data))

proc client_send_frame_done(c: ptr Client) =
  var now: timespec
  discard clock_gettime(CLOCK_MONOTONIC, addr now)
  wlr_surface_for_each_surface(client_surface(c), client_send_frame_done_iterator, addr now)

proc client_set_tiled(c: ptr Client; edges: uint32) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      wlr_xwayland_surface_set_maximized(c.surface.xwayland, edges != uint32(WLR_EDGE_NONE), edges != uint32(WLR_EDGE_NONE))
      return
  if wl_resource_get_version(c.surface.xdg.toplevel.resource) >= XDG_TOPLEVEL_STATE_TILED_RIGHT_SINCE_VERSION:
    discard wlr_xdg_toplevel_set_tiled(c.surface.xdg.toplevel, edges)
  else:
    discard wlr_xdg_toplevel_set_maximized(c.surface.xdg.toplevel, edges != uint32(WLR_EDGE_NONE))

proc client_set_suspended(c: ptr Client; suspended: cint) =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return
  discard wlr_xdg_toplevel_set_suspended(c.surface.xdg.toplevel, suspended != 0)

proc client_wants_focus(c: ptr Client): cint =
  when defined(XWAYLAND):
    return cint(client_is_unmanaged(c) != 0 and
      wlr_xwayland_surface_override_redirect_wants_focus(c.surface.xwayland) and
      wlr_xwayland_surface_icccm_input_model(c.surface.xwayland) != WLR_ICCCM_INPUT_MODEL_NONE)
  0

proc client_wants_fullscreen(c: ptr Client): cint =
  when defined(XWAYLAND):
    if client_is_x11(c) != 0: return cint(c.surface.xwayland.fullscreen)
  cint(c.surface.xdg.toplevel.requested.fullscreen)
