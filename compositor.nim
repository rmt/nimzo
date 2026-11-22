# Manage the compositor lifecycle and wlroots callbacks for surfaces, inputs,
# outputs, and session locks. Apply focus, workspace, and scene transactions.

var shuttingDown: bool

proc pendingLock(): ptr SessionLock =
  if cur_lock != nil:
    let lock = cast[ptr SessionLock](cur_lock.data)
    if not lock.acknowledged: return lock

proc acknowledgePresentedLock() =
  let lock = pendingLock()
  if lock == nil or shuttingDown: return
  var m = wl_list_first_link(addr mons, cast[ptr Monitor](nil))
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.enabled and m.lockFrame != LockFramePresented: return
    m = wl_list_next_link(m)
  lock.acknowledged = true
  wlr_session_lock_v1_send_locked(lock.lock)

proc presentLockFrame(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  if pendingLock() == nil: return
  var m: ptr Monitor
  m = wl_container_of(listener, m, present)
  let event = cast[ptr wlr_output_event_present](data)
  if m.lockFrame != LockFrameSubmitted or event.commit_seq != m.lockCommitSeq:
    return
  if event.presented:
    m.lockFrame = LockFramePresented
    acknowledgePresentedLock()
  else:
    m.lockFrame = LockFrameNeeded
    wlr_output_schedule_frame(m.wlr_output)

proc lockOwnsSurface(surface: ptr wlr_surface): bool =
  if cur_lock == nil or surface == nil: return false
  let root = wlr_surface_get_root_surface(surface)
  var lockSurface = wl_list_first_link(addr cur_lock.surfaces,
    cast[ptr wlr_session_lock_surface_v1](nil))
  while wl_list_more_link(lockSurface, addr cur_lock.surfaces):
    if lockSurface.surface == root: return true
    lockSurface = wl_list_next_link(lockSurface)

proc setDesktopVisible(visible: bool) =
  wlr_scene_node_set_enabled(addr root_bg.node, visible)
  wlr_scene_node_set_enabled(addr drag_icon.node, visible)
  for i in LyrBg ..< LyrBlock:
    wlr_scene_node_set_enabled(addr layers[i].node, visible)
  wlr_scene_node_set_enabled(addr locked_bg.node, not visible)

proc applybounds*(c: ptr Client; bbox: ptr wlr_box) {.cdecl.} =
  c.geom.width = MAX(1 + 2 * cast[cint](c.bw), c.geom.width)
  c.geom.height = MAX(1 + client_frame_height(c), c.geom.height)
  if c.isfullscreen == 0:
    var
      min: wlr_box = wlr_box(x: 0, y: 0, width: 0, height: 0)
      max: wlr_box = wlr_box(x: 0, y: 0, width: 0, height: 0)
    client_get_size_hints(c, addr(max), addr(min))
    c.geom.width = MAX(min.width + 2 * cast[cint](c.bw), c.geom.width)
    c.geom.height = MAX(min.height + client_frame_height(c), c.geom.height)
    if max.width > 0 and 2 * cast[cint](c.bw) <= INT_MAX - max.width:
      c.geom.width = MIN(max.width + 2 * cast[cint](c.bw), c.geom.width)
    if max.height > 0 and client_frame_height(c) <= INT_MAX - max.height:
      c.geom.height = MIN(max.height + client_frame_height(c), c.geom.height)
  if c.geom.x >= bbox.x + bbox.width:
    c.geom.x = bbox.x + bbox.width - c.geom.width
  if c.geom.y >= bbox.y + bbox.height:
    c.geom.y = bbox.y + bbox.height - c.geom.height
  if c.geom.x + c.geom.width <= bbox.x:
    c.geom.x = bbox.x
  if c.geom.y + c.geom.height <= bbox.y:
    c.geom.y = bbox.y

proc clientSceneLayer(c: ptr Client): ptr wlr_scene_tree =
  let parent = client_get_parent(c)
  let layout = c.mon.lt[c.mon.sellt]
  let layer = if c.isfullscreen != 0 or (parent != nil and parent.isfullscreen != 0):
      LyrFS
    elif c.alwaysOnTop:
      LyrAbove
    elif layout != (addr layouts[layoutZonesIndex]) and
        (c.ismaximized or (c.isfloating != 0 and layout.arrange != nil)):
      LyrFloat
    else:
      # Zones overlap intentionally. Manual geometry must not imply always-on-top.
      LyrTile
  layers[layer]

proc applygeom*(c: ptr Client) {.cdecl.} =
  var clip: wlr_box
  wlr_scene_node_reparent(addr(c.scene.node), clientSceneLayer(c))
  c.current = c.geom
  if c.snapshot != nil:
    wlr_scene_node_destroy(c.snapshot)
    c.snapshot = nil
    wlr_scene_node_set_enabled(addr(c.scene_surface.node), true)
  wlr_scene_node_set_position(addr(c.scene.node), c.geom.x, c.geom.y)
  let top = client_top_inset(c)
  wlr_scene_node_set_position(addr(c.scene_surface.node), cint(c.bw), top)
  wlr_scene_rect_set_size(c.border[0], c.geom.width, cint(c.bw))
  wlr_scene_node_set_enabled(addr(c.border[0].node), c.bw != 0 and client_title_height(c) == 0)
  for i in 1 .. 3:
    wlr_scene_node_set_enabled(addr(c.border[i].node), c.bw != 0)
  wlr_scene_rect_set_size(c.border[1], c.geom.width, cint(c.bw))
  wlr_scene_rect_set_size(c.border[2], cint(c.bw), max(0, c.geom.height - top - cint(c.bw)))
  wlr_scene_rect_set_size(c.border[3], cint(c.bw), max(0, c.geom.height - top - cint(c.bw)))
  wlr_scene_node_set_position(addr(c.border[1].node), 0, c.geom.height - cint(c.bw))
  wlr_scene_node_set_position(addr(c.border[2].node), 0, top)
  wlr_scene_node_set_position(addr(c.border[3].node), c.geom.width - cint(c.bw), top)
  updateTitlebar(c)
  client_get_clip(c, addr(clip))
  wlr_scene_subsurface_tree_set_clip(addr(c.scene_surface.node), addr(clip))

proc applyrules*(c: ptr Client) {.cdecl.} =
  var
    appid: cstring
    title: cstring
  var newtags: uint32 = 0
  var i: cint
  var r: ptr Rule
  var
    mon: ptr Monitor = selmon
    m: ptr Monitor
  appid = client_get_appid(c)
  title = client_get_title(c)
  r = addr(rules[0])
  while r < END(rules):
    if (r.title == nil or strstr(title, r.title) != nil) and
        (r.id == nil or strstr(appid, r.id) != nil):
      c.isfloating = r.isfloating
      newtags = newtags or r.tags
      i = 0
      m = wl_list_first_link((addr(mons)), m)
      while wl_list_more_link(m, (addr(mons))):
        if r.monitor == i:
          mon = m
        inc(i)
        m = wl_list_next_link(m)
    r = cast[ptr Rule](cast[uint](r) + cast[uint](sizeof(Rule)))
  c.isfloating = c.isfloating or client_is_float_type(c)
  setmon(c, mon, newtags)

proc arrange*(m: ptr Monitor) {.cdecl.} =
  var c: ptr Client
  let parked = m == addr parkingMonitor
  if not parked and not m.wlr_output.enabled:
    return
  c = wl_list_first_link((addr(clients)), c)
  while wl_list_more_link(c, (addr(clients))):
    if c.mon == m:
      client_set_suspended(c, cint((parked or not VISIBLEON(c, m)) and
          (c.image_capture_source == nil or
          wl_list_empty(addr(c.image_capture_source.resources)) != 0)))
      if c.ismaximized and c.isfullscreen == 0:
        resize(c, m.w, 0)
    c = wl_list_next_link(c)
  discard strncpy(cast[cstring](addr(m.ltsymbol[0])), m.lt[m.sellt].symbol, csize_t(LENGTH(m.ltsymbol)))
  if m.lt[m.sellt].arrange != nil:
    m.lt[m.sellt].arrange(m)
  transactionschedule()

proc arrangelayer*(m: ptr Monitor; list: ptr wl_list; usable_area: ptr wlr_box;
                  exclusive: cint) {.cdecl.} =
  var l: ptr LayerSurface
  var full_area: wlr_box = m.m
  l = wl_list_first_link((list), l)
  while wl_list_more_link(l, (list)):
    var layer_surface: ptr wlr_layer_surface_v1 = l.layer_surface
    if not layer_surface.initialized:
      l = wl_list_next_link(l)
      continue
    if exclusive != cint(layer_surface.current.exclusive_zone > 0):
      l = wl_list_next_link(l)
      continue
    wlr_scene_layer_surface_v1_configure(l.scene_layer, addr(full_area),
        usable_area)
    wlr_scene_node_set_position(addr(l.popups.node), l.scene.node.x,
                                l.scene.node.y)
    l = wl_list_next_link(l)

proc arrangelayers*(m: ptr Monitor) {.cdecl.} =
  var i: cint
  var usable_area: wlr_box = m.m
  var l: ptr LayerSurface
  var layers_above_shell: array[2, uint32] = [
      uint32(ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY), uint32(ZWLR_LAYER_SHELL_V1_LAYER_TOP)]
  if not m.wlr_output.enabled:
    return
  i = 3
  while i >= 0:
    arrangelayer(m, addr(m.layers[i]), addr(usable_area), 1)
    dec(i)
  if not wlr_box_equal(addr(usable_area), addr(m.w)):
    m.w = usable_area
    arrange(m)
  i = 3
  while i >= 0:
    arrangelayer(m, addr(m.layers[i]), addr(usable_area), 0)
    dec(i)
  i = 0
  while i < cast[cint](LENGTH(layers_above_shell)):
    l = wl_list_last_link((addr(m.layers[layers_above_shell[i]])), l)
    while wl_list_more_link(l, (addr(m.layers[layers_above_shell[i]]))):
      if locked != 0 or
          l.layer_surface.current.keyboard_interactive !=
          ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE or
          l.mapped == 0:
        l = wl_list_prev_link(l)
        continue
      focusclient(nil, l, 0)
      return
      l = wl_list_prev_link(l)
    inc(i)

proc scrollWorkspace(step: int; moveWindow: bool)

proc axisnotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_pointer_axis_event = cast[ptr wlr_pointer_axis_event](data)
  var a: ptr Axis
  var adir: cuint
  var keyboard: ptr wlr_keyboard
  var mods: uint32
  wlr_idle_notifier_v1_notify_activity(idle_notifier, seat)
  if locked == 0:
    if event.orientation == WL_POINTER_AXIS_VERTICAL_SCROLL:
      adir = if event.delta > 0: AxisDown else: AxisUp
    else:
      adir = if event.delta > 0: AxisRight else: AxisLeft
    keyboard = wlr_seat_get_keyboard(seat)
    mods = if keyboard != nil: CLEANMASK(wlr_keyboard_get_modifiers(keyboard)) else: 0
    let pointerMods = CLEANMASK(activeConfig.floatingModifiers)
    const shift = uint32(WLR_MODIFIER_SHIFT)
    let moveWindow = (pointerMods and shift) == 0 and mods == (pointerMods or shift)
    if event.orientation == WL_POINTER_AXIS_VERTICAL_SCROLL and pointerMods != 0 and
        (mods == pointerMods or moveWindow) and grabc == nil and pointerOperationAllowed():
      let delta = if event.delta != 0: event.delta else: cdouble(event.delta_discrete)
      if delta != 0: scrollWorkspace(if delta < 0: -1 else: 1, moveWindow)
      return
    a = addr(axes[0])
    while a < END(axes):
      if mods == CLEANMASK(a.`mod`) and adir == a.dir and a.`func` != nil:
        a.`func`(addr(a.arg))
        return
      a = cast[ptr Axis](cast[uint](a) + cast[uint](sizeof(Axis)))
  wlr_seat_pointer_notify_axis(seat, event.time_msec, event.orientation,
                               event.delta, event.delta_discrete, event.source,
                               event.relative_direction)

proc buttonpress*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_pointer_button_event = cast[ptr wlr_pointer_button_event](data)
  var keyboard: ptr wlr_keyboard
  var mods: uint32
  var c: ptr Client = nil
  var l: ptr LayerSurface = nil
  var b: ptr Button
  wlr_idle_notifier_v1_notify_activity(idle_notifier, seat)
  if locked != 0:
    if lockOwnsSurface(seat.pointer_state.focused_surface):
      discard wlr_seat_pointer_notify_button(seat, event.time_msec, event.button, event.state)
    return
  if cursor_mode == CurMove or cursor_mode == CurResize:
    if event.state == WL_POINTER_BUTTON_STATE_RELEASED and event.button == grabButton:
      finishPointerInteraction()
    return
  case event.state
  of WL_POINTER_BUTTON_STATE_PRESSED:
    cursor_mode = CurPressed
    selmon = xytomon(cursor.x, cursor.y)
    xytonode(cursor.x, cursor.y, nil, addr(c), addr(l), nil, nil)
    if c != nil and (client_is_unmanaged(c) == 0 or client_wants_focus(c) != 0):
      focusclient(c, nil, 1)
    elif l != nil and l.layer_surface.current.keyboard_interactive !=
        ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE:
      focusclient(nil, l, 0)
    keyboard = wlr_seat_get_keyboard(seat)
    mods = if keyboard != nil: CLEANMASK(wlr_keyboard_get_modifiers(keyboard)) else: 0
    if c != nil and event.button == uint32(BTN_LEFT) and mods == 0 and
        client_title_height(c) != 0 and cursor.y >= cdouble(c.geom.y) and
        cursor.y < cdouble(c.geom.y + client_title_height(c)):
      var move = Arg(ui: uint32(CurMove))
      moveresize(addr move)
      if grabc == c:
        grabButton = event.button
        updateZonePreview()
      return
    const shift = uint32(WLR_MODIFIER_SHIFT)
    b = addr(buttons[0])
    while b < END(buttons):
      let bindingMods = CLEANMASK(b.`mod`)
      let extraShift = (bindingMods and shift) == 0 and mods == (bindingMods or shift)
      let freeMove = extraShift and b.button == BTN_LEFT and b.arg.ui == uint32(CurMove)
      let shiftResize = extraShift and b.button == BTN_RIGHT and b.arg.ui == uint32(CurResize)
      if event.button == b.button and b.`func` != nil and
          (mods == bindingMods or freeMove or shiftResize):
        b.`func`(addr(b.arg))
        if cursor_mode == CurMove or cursor_mode == CurResize:
          grabButton = event.button
          grabKeepGeometry = freeMove
          updateZonePreview()
        return
      b = cast[ptr Button](cast[uint](b) + cast[uint](sizeof(Button)))
  of WL_POINTER_BUTTON_STATE_RELEASED:
    cursor_mode = CurNormal
  discard wlr_seat_pointer_notify_button(seat, event.time_msec, event.button, event.state)

proc handleForeignToplevelCaptureRequest*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var request: ptr wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request = cast[ptr wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request](data)
  var view: ptr Client = cast[ptr Client](request.toplevel_handle.data)
  if view.image_capture_source == nil:
    view.image_capture_source = wlr_ext_image_capture_source_v1_create_with_scene_node(
        addr(view.image_capture_scene.tree.node), event_loop, alloc, drw)
    if view.image_capture_source == nil:
      return
  discard wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept(
      request, view.image_capture_source)
  client_set_suspended(view, 0)

proc chvt*(arg: ptr Arg) {.cdecl.} =
  discard wlr_session_change_vt(session, arg.ui)

proc checkidleinhibitor*(exclude: ptr wlr_surface) {.cdecl.} =
  var exclude_surface = exclude
  var
    inhibited: cint = 0
    unused_lx: cint
    unused_ly: cint
  var inhibitor: ptr wlr_idle_inhibitor_v1
  inhibitor = wl_list_first_link((addr(idle_inhibit_mgr.inhibitors)), inhibitor)
  while wl_list_more_link(inhibitor, (addr(idle_inhibit_mgr.inhibitors))):
    var surface: ptr wlr_surface = wlr_surface_get_root_surface(inhibitor.surface)
    var tree: ptr wlr_scene_tree = cast[ptr wlr_scene_tree](surface.data)
    if exclude_surface == inhibitor.surface:
      exclude_surface = nil
      inhibitor = wl_list_next_link(inhibitor)
      continue
    if bypass_surface_visibility != 0 or
        (tree == nil or
        wlr_scene_node_coords(addr(tree.node), addr(unused_lx), addr(unused_ly))):
      inhibited = 1
      break
    inhibitor = wl_list_next_link(inhibitor)
  let inhibited_bool = inhibited != 0
  wlr_idle_notifier_v1_set_inhibited(idle_notifier, inhibited_bool)

proc cleanup*() {.cdecl.} =
  shuttingDown = true
  stopSwayIpc()
  wlrForeignToplevelFinish()
  var name: cstringArray
  cleanuplisteners()
  when defined(XWAYLAND):
    wlr_xwayland_destroy(xwayland)
    xwayland = nil
  wl_display_destroy_clients(dpy)
  if child_pid > 0:
    discard kill(-child_pid, SIGTERM)
    discard waitpid(child_pid, nil, 0)
  destroykeyboardgroup(addr(kb_group.destroy), nil)
  input_method_relay_finish(input_method_relay)
  input_method_relay = nil
  if backend != nil:
    wlr_backend_destroy(backend)
  destroyParkingOutput()
  # Output destruction still uses the cursor. Destroy it before its layout.
  wlr_cursor_destroy(cursor)
  wlr_xcursor_manager_destroy(cursor_mgr)
  if transaction_idle != nil:
    discard wl_event_source_remove(transaction_idle)
  discard wl_event_source_remove(transaction_timer)
  wl_array_release(addr(ghosts))
  name = wl_array_first((addr(offmons)), name)
  while wl_array_more(name, (addr(offmons))):
    free(cast[pointer](name[0]))
    name = wl_array_next(name)
  wl_array_release(addr(offmons))
  wl_display_destroy(dpy)
  wlr_scene_node_destroy(addr(scene.tree.node))
  wlr_allocator_destroy(alloc)
  wlr_renderer_destroy(drw)

proc cleanupmon*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var m: ptr Monitor
  m = wl_container_of(listener, m, destroy)
  inc outputLayoutUpdates
  wl_list_remove(addr m.link)
  if selmon == m: selmon = nil
  if not shuttingDown:
    saveDisconnectedWorkspace(m)
    closemon(m)
  var
    l: ptr LayerSurface
    tmp: ptr LayerSurface
  var pointer: ptr wlr_virtual_pointer_v1
  var i: csize_t
  pointer = wl_list_first_link((addr(virtual_pointer_mgr.virtual_pointers)),
                             pointer)
  while wl_list_more_link(pointer, (addr(virtual_pointer_mgr.virtual_pointers))):
    if pointer.pointer.base.data == m.wlr_output:
      wlr_cursor_map_input_to_output(cursor, addr(pointer.pointer.base), nil)
    pointer = wl_list_next_link(pointer)
  wlr_scene_output_destroy(m.scene_output)
  i = 0
  while i < csize_t(LENGTH(m.layers)):
    l = wl_list_first_link((addr(m.layers[i])), l)
    tmp = wl_list_next_link(l)
    while wl_list_more_link(l, (addr(m.layers[i]))):
      wlr_layer_surface_v1_destroy(l.layer_surface)
      l = tmp
      tmp = wl_list_next_link(l)
    inc(i)
  wl_list_remove(addr(m.destroy.link))
  wl_list_remove(addr(m.frame.link))
  wl_list_remove(addr(m.present.link))
  wl_list_remove(addr(m.request_state.link))
  if m.lock_surface != nil:
    destroylocksurface(addr(m.destroy_lock_surface), nil)
  m.wlr_output.data = nil
  wlr_output_layout_remove(output_layout, m.wlr_output)
  wlr_scene_node_destroy(addr(m.fullscreen_bg.node))
  free(m)
  dec outputLayoutUpdates
  if not shuttingDown: updatemons(nil, nil)

proc cleanuplisteners*() {.cdecl.} =
  wl_list_remove(addr(cursor_axis.link))
  wl_list_remove(addr(cursor_button.link))
  wl_list_remove(addr(cursorFrameListener.link))
  wl_list_remove(addr(cursor_motion.link))
  wl_list_remove(addr(cursor_motion_absolute.link))
  wl_list_remove(addr(gpuResetListener.link))
  wl_list_remove(addr(new_idle_inhibitor.link))
  wl_list_remove(addr(layout_change.link))
  wl_list_remove(addr(new_input_device.link))
  wl_list_remove(addr(backend_destroy.link))
  wl_list_remove(addr(new_virtual_keyboard.link))
  wl_list_remove(addr(new_virtual_pointer.link))
  wl_list_remove(addr(new_pointer_constraint.link))
  wl_list_remove(addr(new_output.link))
  wl_list_remove(addr(new_xdg_toplevel.link))
  wl_list_remove(addr(new_xdg_decoration.link))
  wl_list_remove(addr(new_xdg_popup.link))
  wl_list_remove(addr(new_layer_surface.link))
  wl_list_remove(addr(outputMgrApplyListener.link))
  wl_list_remove(addr(outputMgrTestListener.link))
  wl_list_remove(addr(output_power_mgr_set_mode.link))
  wl_list_remove(addr(request_activate.link))
  wl_list_remove(addr(request_cursor.link))
  wl_list_remove(addr(request_set_psel.link))
  wl_list_remove(addr(request_set_sel.link))
  wl_list_remove(addr(request_set_cursor_shape.link))
  wl_list_remove(addr(requestStartDragListener.link))
  wl_list_remove(addr(startDragListener.link))
  wl_list_remove(addr(new_session_lock.link))
  wl_list_remove(addr(new_foreign_toplevel_capture_request.link))
  when defined(XWAYLAND):
    if xwayland != nil:
      wl_list_remove(addr(new_xwayland_surface.link))
      wl_list_remove(addr(xwaylandReadyListener.link))

proc closemon*(m: ptr Monitor) {.cdecl.} =
  if grabc != nil and grabc.mon == m:
    cancelPointerInteraction()
  evacuateOutputClients(m)

proc commitlayersurfacenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var l: ptr LayerSurface
  l = wl_container_of(listener, l, surface_commit)
  var layer_surface: ptr wlr_layer_surface_v1 = l.layer_surface
  var scene_layer: ptr wlr_scene_tree = layers[layermap[int(layer_surface.current.layer)]]
  var old_state: wlr_layer_surface_v1_state
  if l.layer_surface.initial_commit:
    client_set_scale(layer_surface.surface, l.mon.wlr_output.scale)
    old_state = l.layer_surface.current
    l.layer_surface.current = l.layer_surface.pending
    arrangelayers(l.mon)
    l.layer_surface.current = old_state
    return
  if layer_surface.current.committed == 0 and
      l.mapped == cint(layer_surface.surface.mapped):
    return
  l.mapped = cint(layer_surface.surface.mapped)
  wlr_scene_node_set_enabled(addr(l.scene.node), l.mapped != 0)
  if scene_layer != l.scene.node.parent:
    wlr_scene_node_reparent(addr(l.scene.node), scene_layer)
    wl_list_remove(addr(l.link))
    wl_list_insert(addr(l.mon.layers[int(layer_surface.current.layer)]), addr(l.link))
    wlr_scene_node_reparent(addr(l.popups.node), (if layer_surface.current.layer <
        ZWLR_LAYER_SHELL_V1_LAYER_TOP: layers[LyrTop] else: scene_layer))
  arrangelayers(l.mon)
  if layer_surface.surface == seat.keyboard_state.focused_surface and
      layer_surface.current.keyboard_interactive ==
      ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE:
    focusclient(focustop(selmon), nil, 1)
  discard wl_event_loop_add_idle(event_loop, refocuspointer, nil)

proc commitlocksurface*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var m: ptr Monitor
  m = wl_container_of(listener, m, commit_lock_surface)
  if not m.lock_surface.surface.mapped:
    return
  wl_list_remove(addr(m.commit_lock_surface.link))
  wl_list_init(addr(m.commit_lock_surface.link))
  motionnotify(0, nil, 0, 0, 0, 0)

proc handleXdgSurfaceCommit*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, commit)
  if c.surface.xdg.initial_commit:
    applyrules(c)
    if c.mon != nil:
      client_set_scale(client_surface(c), c.mon.wlr_output.scale)
    setmon(c, nil, 0)
    discard wlr_xdg_toplevel_set_wm_capabilities(c.surface.xdg.toplevel,
        uint32(WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN) or
        uint32(WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE) or
        uint32(WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE))
    if c.decoration != nil:
      requestdecorationmode(addr(c.set_decoration_mode), c.decoration)
    discard wlr_xdg_toplevel_set_size(c.surface.xdg.toplevel, 0, 0)
    if c.isfloating == 0:
      client_set_tiled(c, uint32(WLR_EDGE_TOP or WLR_EDGE_BOTTOM or
          WLR_EDGE_LEFT or WLR_EDGE_RIGHT))
    return
  if c.late_serial != 0 and c.surface.xdg.current.configure_serial >= c.late_serial:
    c.late_serial = 0
    discard wl_event_loop_add_idle(event_loop, refocuspointer, nil)
  transactioncommit(c, cint(c.resize_serial != 0 and
      c.surface.xdg.current.configure_serial >= c.resize_serial))
  resize(c, c.geom, cint(client_places_manually(c) and c.isfullscreen == 0))

proc commitpopup*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var surface: ptr wlr_surface = cast[ptr wlr_surface](data)
  var popup: ptr wlr_xdg_popup = wlr_xdg_popup_try_from_wlr_surface(surface)
  var p: ptr Popup
  p = wl_container_of(listener, p, commit)
  var l: ptr LayerSurface = nil
  var c: ptr Client = nil
  var box: wlr_box
  var `type`: cint = -1
  if not popup.base.initial_commit:
    return
  `type` = toplevel_from_wlr_surface(popup.base.surface, addr(c), addr(l))
  if popup.parent == nil or `type` < 0:
    return
  if popup.parent.data == nil or (l != nil and l.mon == nil) or (c != nil and c.mon == nil):
    wlr_xdg_popup_destroy(popup)
    return
  popup.base.surface.data = wlr_scene_xdg_surface_create(
      cast[ptr wlr_scene_tree](popup.parent.data), popup.base)
  box = if `type` == LayerShell: l.mon.m else: c.mon.w
  dec(box.x, (if `type` == LayerShell: l.scene.node.x else: c.geom.x -
      c.surface.xdg.geometry.x))
  dec(box.y, (if `type` == LayerShell: l.scene.node.y else: c.geom.y -
      c.surface.xdg.geometry.y))
  wlr_xdg_popup_unconstrain_from_box(popup, addr(box))
  destroypopup(addr(p.destroy), nil)

proc createdecoration*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var deco: ptr wlr_xdg_toplevel_decoration_v1 = cast[ptr wlr_xdg_toplevel_decoration_v1](data)
  var c: ptr Client = cast[ptr Client](deco.toplevel.base.data)
  c.decoration = deco
  LISTEN(addr(deco.events.request_mode), addr(c.set_decoration_mode),
         requestdecorationmode)
  LISTEN(addr(deco.events.destroy), addr(c.destroy_decoration), destroydecoration)
  requestdecorationmode(addr(c.set_decoration_mode), deco)

proc createidleinhibitor*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var idle_inhibitor: ptr wlr_idle_inhibitor_v1 = cast[ptr wlr_idle_inhibitor_v1](data)
  var destroy: ptr wl_listener = cast[ptr wl_listener](ecalloc(csize_t(1), csize_t(sizeof(wl_listener))))
  LISTEN(addr(idle_inhibitor.events.destroy), destroy, destroyidleinhibitor)
  checkidleinhibitor(nil)

proc createkeyboard*(keyboard: ptr wlr_keyboard) {.cdecl.} =
  discard wlr_keyboard_set_keymap(keyboard, kb_group.wlr_group.keyboard.keymap)
  discard wlr_keyboard_group_add_keyboard(kb_group.wlr_group, keyboard)
  markSwayDirty()

proc createkeyboardgroup*(): ptr KeyboardGroup {.cdecl.} =
  var group: ptr KeyboardGroup = cast[ptr KeyboardGroup](ecalloc(csize_t(1), csize_t(sizeof(KeyboardGroup))))
  var context: ptr xkb_context
  var keymap: ptr xkb_keymap
  group.wlr_group = wlr_keyboard_group_create()
  group.wlr_group.data = group
  context = xkb_context_new(XKB_CONTEXT_NO_FLAGS)
  keymap = xkb_keymap_new_from_names(context, addr(xkb_rules),
      XKB_KEYMAP_COMPILE_NO_FLAGS)
  if keymap == nil:
    die("failed to compile keymap")
  discard wlr_keyboard_set_keymap(addr(group.wlr_group.keyboard), keymap)
  xkb_keymap_unref(keymap)
  xkb_context_unref(context)
  wlr_keyboard_set_repeat_info(addr(group.wlr_group.keyboard), repeat_rate,
                               repeat_delay)
  LISTEN(addr(group.wlr_group.keyboard.events.key), addr(group.key), keypress)
  LISTEN(addr(group.wlr_group.keyboard.events.modifiers), addr(group.modifiers),
         keypressmod)
  group.key_repeat_source = wl_event_loop_add_timer(event_loop, keyrepeat, group)
  wlr_seat_set_keyboard(seat, addr(group.wlr_group.keyboard))
  return group

proc createlayersurface*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var layer_surface: ptr wlr_layer_surface_v1 = cast[ptr wlr_layer_surface_v1](data)
  var l: ptr LayerSurface
  var surface: ptr wlr_surface = layer_surface.surface
  var scene_layer: ptr wlr_scene_tree = layers[layermap[int(layer_surface.pending.layer)]]
  if layer_surface.output == nil and selmon != nil and selmon != addr parkingMonitor:
    layer_surface.output = selmon.wlr_output
  if layer_surface.output == nil:
    wlr_layer_surface_v1_destroy(layer_surface)
    return
  l = cast[ptr LayerSurface](ecalloc(csize_t(1), csize_t(sizeof(LayerSurface))))
  layer_surface.data = cast[pointer](l)
  l.`type` = LayerShell
  LISTEN(addr(surface.events.commit), addr(l.surface_commit),
         commitlayersurfacenotify)
  LISTEN(addr(surface.events.unmap), addr(l.unmap), unmaplayersurfacenotify)
  LISTEN(addr(layer_surface.events.destroy), addr(l.destroy),
         destroylayersurfacenotify)
  l.layer_surface = layer_surface
  l.mon = cast[ptr Monitor](layer_surface.output.data)
  l.scene_layer = wlr_scene_layer_surface_v1_create(scene_layer, layer_surface)
  l.scene = l.scene_layer.tree
  l.popups = wlr_scene_tree_create(if layer_surface.current.layer <
      ZWLR_LAYER_SHELL_V1_LAYER_TOP: layers[LyrTop] else: scene_layer)
  surface.data = cast[pointer](l.popups)
  l.scene.node.data = cast[pointer](l)
  l.popups.node.data = cast[pointer](l)
  wl_list_insert(addr(l.mon.layers[int(layer_surface.pending.layer)]), addr(l.link))
  wlr_surface_send_enter(surface, layer_surface.output)

proc createlocksurface*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var lock: ptr SessionLock
  lock = wl_container_of(listener, lock, new_surface)
  var lock_surface: ptr wlr_session_lock_surface_v1 = cast[ptr wlr_session_lock_surface_v1](data)
  var m: ptr Monitor = cast[ptr Monitor](lock_surface.output.data)
  var scene_tree: ptr wlr_scene_tree
  scene_tree = wlr_scene_subsurface_tree_create(lock.scene, lock_surface.surface)
  lock_surface.surface.data = cast[pointer](scene_tree)
  m.lock_surface = lock_surface
  wlr_scene_node_set_position(addr(scene_tree.node), m.m.x, m.m.y)
  discard wlr_session_lock_surface_v1_configure_proc(lock_surface,
      uint32(m.m.width), uint32(m.m.height))
  LISTEN(addr(lock_surface.events.destroy), addr(m.destroy_lock_surface),
         destroylocksurface)
  LISTEN(addr(lock_surface.surface.events.commit), addr(m.commit_lock_surface),
         commitlocksurface)
  if m == selmon:
    client_notify_enter(lock_surface.surface, wlr_seat_get_keyboard(seat))

proc createmon*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var wlr_output: ptr wlr_output = cast[ptr wlr_output](data)
  var r: ptr MonitorRule
  var i: csize_t
  var state: wlr_output_state
  var m: ptr Monitor
  if not wlr_output_init_render(wlr_output, alloc, drw):
    return
  inc outputLayoutUpdates
  m = cast[ptr Monitor](ecalloc(csize_t(1), csize_t(sizeof(Monitor))))
  wlr_output.data = cast[pointer](m)
  wlrForeignToplevelOutputAdd(wlr_output)
  m.wlr_output = wlr_output
  i = 0
  while i < csize_t(LENGTH(m.layers)):
    wl_list_init(addr(m.layers[i]))
    inc(i)
  wlr_output_state_init(addr(state))
  m.tagset[1] = 1
  m.tagset[0] = 1
  r = addr(monrules[0])
  while r < END(monrules):
    if r.name == nil or strstr(wlr_output.name, r.name) != nil:
      m.m.x = r.x
      m.m.y = r.y
      m.lt[0] = r.lt
      let alternate = if r.lt == addr layouts[layoutZonesIndex]: layoutMonocleIndex
        else: layoutZonesIndex
      m.lt[1] = addr layouts[alternate]
      discard strncpy(cast[cstring](addr(m.ltsymbol[0])), m.lt[m.sellt].symbol,
          csize_t(LENGTH(m.ltsymbol)))
      wlr_output_state_set_scale(addr(state), r.scale)
      wlr_output_state_set_transform(addr(state), r.rr)
      break
    r = cast[ptr MonitorRule](cast[uint](r) + cast[uint](sizeof(MonitorRule)))
  LISTEN(addr(wlr_output.events.frame), addr(m.frame), rendermon)
  LISTEN(addr(wlr_output.events.present), addr(m.present), presentLockFrame)
  LISTEN(addr(wlr_output.events.destroy), addr(m.destroy), cleanupmon)
  LISTEN(addr(wlr_output.events.request_state), addr(m.request_state),
         requestmonstate)
  if findDisabledOutputEntry(wlr_output) == nil:
    wlr_output_state_set_mode(addr(state), wlr_output_preferred_mode(wlr_output))
    wlr_output_state_set_enabled(addr(state), true)
  configureOutput(wlr_output, addr state, activeConfig)
  if not wlr_output_commit_state(wlr_output, addr(state)):
    discard fprintf(stderr, "nimzo: output %s: configuration commit failed\n", wlr_output.name)
  setOutputDisabledRecord(wlr_output, cint(not wlr_output.enabled))
  wlr_output_state_finish(addr(state))
  wl_list_insert(addr(mons), addr(m.link))
  publishCompositorState()
  m.fullscreen_bg = wlr_scene_rect_create(layers[LyrFS], 0, 0, fullscreen_bg)
  wlr_scene_node_set_enabled(addr(m.fullscreen_bg.node), false)
  m.scene_output = wlr_scene_output_create(scene, wlr_output)
  restoreConnectedWorkspace(m)
  if wlr_output.enabled:
    if m.m.x == -1 and m.m.y == -1:
      discard wlr_output_layout_add_auto(output_layout, wlr_output)
    else:
      discard wlr_output_layout_add(output_layout, wlr_output, m.m.x, m.m.y)
    positionConfiguredOutputs(activeConfig)
  dec outputLayoutUpdates
  updatemons(nil, nil)

proc handleNewXdgToplevel*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var toplevel: ptr wlr_xdg_toplevel = cast[ptr wlr_xdg_toplevel](data)
  var c: ptr Client = nil
  c = cast[ptr Client](ecalloc(csize_t(1), csize_t(sizeof(Client))))
  toplevel.base.data = cast[pointer](c)
  c.surface.xdg = toplevel.base
  c.bw = borderpx
  LISTEN(addr(toplevel.base.surface.events.commit), addr(c.commit), handleXdgSurfaceCommit)
  LISTEN(addr(toplevel.base.surface.events.map), addr(c.map), handleClientMap)
  LISTEN(addr(toplevel.base.surface.events.unmap), addr(c.unmap), unmapnotify)
  LISTEN(addr(toplevel.events.destroy), addr(c.destroy), destroynotify)
  LISTEN(addr(toplevel.events.request_fullscreen), addr(c.fullscreen),
         fullscreennotify)
  LISTEN(addr(toplevel.events.request_maximize), addr(c.maximize), maximizenotify)
  LISTEN(addr(toplevel.events.request_minimize), addr(c.minimize), minimizenotify)
  LISTEN(addr(toplevel.events.set_title), addr(c.set_title), updatetitle)

proc createpointer*(pointer: ptr wlr_pointer) {.cdecl.} =
  var device: ptr libinput_device
  if wlr_input_device_is_libinput(addr(pointer.base)):
    device = wlr_libinput_get_device_handle(addr(pointer.base))
    if device != nil:
      discard libinput_device_config_tap_set_enabled(device,
          (if tap_to_click != 0: LIBINPUT_CONFIG_TAP_ENABLED else: LIBINPUT_CONFIG_TAP_DISABLED))
      discard libinput_device_config_tap_set_drag_enabled(device,
          (if tap_and_drag != 0: LIBINPUT_CONFIG_DRAG_ENABLED else: LIBINPUT_CONFIG_DRAG_DISABLED))
      discard libinput_device_config_tap_set_drag_lock_enabled(device,
          (if drag_lock != 0: LIBINPUT_CONFIG_DRAG_LOCK_ENABLED else: LIBINPUT_CONFIG_DRAG_LOCK_DISABLED))
      discard libinput_device_config_tap_set_button_map(device,
          typeof(LIBINPUT_CONFIG_TAP_MAP_LRM)(button_map))
    if libinput_device_config_scroll_has_natural_scroll(device) != 0:
      discard libinput_device_config_scroll_set_natural_scroll_enabled(device,
          cint(natural_scrolling != 0))
    if libinput_device_config_dwt_is_available(device) != 0:
      discard libinput_device_config_dwt_set_enabled(device, if disable_while_typing != 0: LIBINPUT_CONFIG_DWT_ENABLED else: LIBINPUT_CONFIG_DWT_DISABLED)
    if libinput_device_config_left_handed_is_available(device) != 0:
      discard libinput_device_config_left_handed_set(device, cint(left_handed != 0))
    if libinput_device_config_middle_emulation_is_available(device) != 0:
      discard libinput_device_config_middle_emulation_set_enabled(device,
          typeof(LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED)(if middle_button_emulation != 0:
              LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED else: LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED))
    if libinput_device_config_scroll_get_methods(device) != uint32(LIBINPUT_CONFIG_SCROLL_NO_SCROLL):
      discard libinput_device_config_scroll_set_method(device,
          typeof(LIBINPUT_CONFIG_SCROLL_2FG)(scroll_method))
    if libinput_device_config_click_get_methods(device) != uint32(LIBINPUT_CONFIG_CLICK_METHOD_NONE):
      discard libinput_device_config_click_set_method(device,
          typeof(LIBINPUT_CONFIG_CLICK_METHOD_NONE)(click_method))
    if libinput_device_config_send_events_get_modes(device) != 0:
      discard libinput_device_config_send_events_set_mode(device,
          uint32(send_events_mode))
    if libinput_device_config_accel_is_available(device) != 0:
      discard libinput_device_config_accel_set_profile(device,
          typeof(LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT)(accel_profile))
      discard libinput_device_config_accel_set_speed(device, accel_speed)
  wlr_cursor_attach_input_device(cursor, addr(pointer.base))

proc createpointerconstraint*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var pointer_constraint: ptr PointerConstraint = cast[ptr PointerConstraint](
      ecalloc(csize_t(1), csize_t(sizeof(PointerConstraint))))
  pointer_constraint.constraint = cast[ptr wlr_pointer_constraint_v1](data)
  LISTEN(addr(pointer_constraint.constraint.events.destroy),
         addr(pointer_constraint.destroy), destroypointerconstraint)

proc createpopup*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var popup: ptr wlr_xdg_popup = cast[ptr wlr_xdg_popup](data)
  var p: ptr Popup = cast[ptr Popup](ecalloc(csize_t(1), csize_t(sizeof(Popup))))
  LISTEN(addr(popup.base.surface.events.commit), addr(p.commit), commitpopup)
  LISTEN(addr(popup.events.destroy), addr(p.destroy), destroypopup)

proc cursorconstrain*(constraint: ptr wlr_pointer_constraint_v1) {.cdecl.} =
  var old: ptr wlr_pointer_constraint_v1 = active_constraint
  if old == constraint:
    return
  active_constraint = constraint
  if old != nil:
    wlr_pointer_constraint_v1_send_deactivated(old)
  if constraint != nil:
    wlr_pointer_constraint_v1_send_activated(constraint)

proc cursorframe*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  wlr_seat_pointer_notify_frame(seat)

proc cursorwarptohint*() {.cdecl.} =
  var c: ptr Client = nil
  var sx: cdouble = active_constraint.current.cursor_hint.x
  var sy: cdouble = active_constraint.current.cursor_hint.y
  discard toplevel_from_wlr_surface(active_constraint.surface, addr(c), nil)
  if c != nil and active_constraint.current.cursor_hint.enabled:
    discard wlr_cursor_warp(cursor, nil, sx + cdouble(c.geom.x) + cdouble(c.bw),
        sy + cdouble(c.geom.y) + cdouble(client_top_inset(c)))
    wlr_seat_pointer_warp(active_constraint.seat, sx, sy)

proc destroybackend*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  wl_list_remove(addr(new_output.link))
  wl_list_init(addr(new_output.link))
  wl_list_remove(addr(new_input_device.link))
  wl_list_init(addr(new_input_device.link))
  wl_list_remove(addr(backend_destroy.link))
  wl_list_init(addr(backend_destroy.link))
  backend = nil
  quit(nil)

proc destroydecoration*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, destroy_decoration)
  c.decoration = nil
  wl_list_remove(addr(c.destroy_decoration.link))
  wl_list_remove(addr(c.set_decoration_mode.link))

proc destroydrag*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client = nil
  if sloppyfocus != 0:
    xytonode(cursor.x, cursor.y, nil, addr(c), nil, nil, nil)
  focusclient(if c != nil and client_is_unmanaged(c) == 0: c else: focustop(selmon), nil, 1)
  motionnotify(0, nil, 0, 0, 0, 0)
  wl_list_remove(addr(listener.link))

proc destroyidleinhibitor*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  checkidleinhibitor(cast[ptr wlr_surface](data))
  wl_list_remove(addr(listener.link))
  free(listener)

proc destroylayersurfacenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var l: ptr LayerSurface
  l = wl_container_of(listener, l, destroy)
  wl_list_remove(addr(l.link))
  wl_list_remove(addr(l.destroy.link))
  wl_list_remove(addr(l.unmap.link))
  wl_list_remove(addr(l.surface_commit.link))
  wlr_scene_node_destroy(addr(l.scene.node))
  wlr_scene_node_destroy(addr(l.popups.node))
  l.layer_surface.surface.data = nil
  free(l)

proc detachLockSurface(m: ptr Monitor) =
  m.lock_surface.surface.data = nil
  m.lock_surface = nil
  wl_list_remove(addr m.destroy_lock_surface.link)
  wl_list_remove(addr m.commit_lock_surface.link)

proc destroylock*(lock: ptr SessionLock; unlocked: cint) {.cdecl.} =
  cur_lock = nil
  wlr_seat_pointer_clear_focus(seat)
  wlr_seat_keyboard_clear_focus(seat)
  var m = wl_list_first_link(addr mons, cast[ptr Monitor](nil))
  while wl_list_more_link(m, addr mons):
    if m.lock_surface != nil: detachLockSurface(m)
    m = wl_list_next_link(m)
  wl_list_remove(addr(lock.new_surface.link))
  wl_list_remove(addr(lock.unlock.link))
  wl_list_remove(addr(lock.destroy.link))
  wlr_scene_node_destroy(addr(lock.scene.node))
  free(lock)
  if unlocked == 0: return

  locked = 0
  setDesktopVisible(true)
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    arrangelayers(m)
    m = wl_list_next_link(m)
  focusclient(focustop(selmon), nil, 0)
  motionnotify(0, nil, 0, 0, 0, 0)

proc destroylocksurface*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var m: ptr Monitor
  m = wl_container_of(listener, m, destroy_lock_surface)
  var
    surface: ptr wlr_session_lock_surface_v1
    lock_surface: ptr wlr_session_lock_surface_v1 = m.lock_surface
  detachLockSurface(m)
  if lock_surface.surface != seat.keyboard_state.focused_surface:
    return
  if locked == 0:
    focusclient(focustop(selmon), nil, 1)
    return
  if cur_lock != nil:
    surface = wl_list_first_link((addr(cur_lock.surfaces)), surface)
    while wl_list_more_link(surface, (addr(cur_lock.surfaces))):
      if surface != lock_surface:
        client_notify_enter(surface.surface, wlr_seat_get_keyboard(seat))
        return
      surface = wl_list_next_link(surface)
  wlr_seat_keyboard_clear_focus(seat)

proc detachXdgListeners(c: ptr Client) =
  wl_list_remove(addr(c.commit.link))
  wl_list_remove(addr(c.map.link))
  wl_list_remove(addr(c.unmap.link))
  if c.decoration != nil:
    wl_list_remove(addr(c.set_decoration_mode.link))
    wl_list_remove(addr(c.destroy_decoration.link))

proc destroynotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, destroy)
  wlrForeignToplevelRemoveClient(c)
  wl_list_remove(addr(c.destroy.link))
  wl_list_remove(addr(c.set_title.link))
  wl_list_remove(addr(c.fullscreen.link))
  wl_list_remove(addr(c.minimize.link))
  wl_list_remove(addr(c.maximize.link))
  when defined(XWAYLAND):
    if c.`type` != XDGShell:
      wl_list_remove(addr(c.activate.link))
      wl_list_remove(addr(c.associate.link))
      wl_list_remove(addr(c.configure.link))
      wl_list_remove(addr(c.dissociate.link))
      wl_list_remove(addr(c.set_geometry.link))
      wl_list_remove(addr(c.set_hints.link))
    else:
      detachXdgListeners(c)
  else:
    detachXdgListeners(c)
  free(c)

proc destroypointerconstraint*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var pointer_constraint: ptr PointerConstraint
  pointer_constraint = wl_container_of(listener, pointer_constraint, destroy)
  if active_constraint == pointer_constraint.constraint:
    cursorwarptohint()
    active_constraint = nil
  wl_list_remove(addr(pointer_constraint.destroy.link))
  free(pointer_constraint)

proc destroypopup*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var p: ptr Popup
  p = wl_container_of(listener, p, destroy)
  wl_list_remove(addr(p.commit.link))
  wl_list_remove(addr(p.destroy.link))
  free(p)

proc destroysessionlock*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var lock: ptr SessionLock
  lock = wl_container_of(listener, lock, destroy)
  destroylock(lock, 0)

proc destroykeyboardgroup*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var group: ptr KeyboardGroup
  group = wl_container_of(listener, group, destroy)
  discard wl_event_source_remove(group.key_repeat_source)
  wl_list_remove(addr(group.key.link))
  wl_list_remove(addr(group.modifiers.link))
  wl_list_remove(addr(group.destroy.link))
  wlr_keyboard_group_destroy(group.wlr_group)
  free(group)

proc dirtomon*(dir: wlr_direction): ptr Monitor {.cdecl.} =
  outputInDirection(selmon, dir)

proc focusclient*(c: ptr Client; l: ptr LayerSurface; lift: cint) {.cdecl.} =
  var
    surface: ptr wlr_surface
    old: ptr wlr_surface = seat.keyboard_state.focused_surface
  var
    unused_lx: cint
    unused_ly: cint
    old_client_type: cint
  var old_c: ptr Client = nil
  var old_l: ptr LayerSurface = nil
  if locked != 0:
    return
  if cyclePreview != nil and c != cyclePreview:
    let previous = cyclePreview
    cyclePreview = nil
    setWindowMinimized(previous, true)
  if c != nil and lift != 0:
    wlr_scene_node_raise_to_top(addr(c.scene.node))
  if c != nil and client_surface(c) == old:
    return
  old_client_type = toplevel_from_wlr_surface(old, addr(old_c), addr(old_l))
  if old_client_type == XDGShell:
    var
      popup: ptr wlr_xdg_popup
      tmp: ptr wlr_xdg_popup
    popup = wl_list_first_link((addr(old_c.surface.xdg.popups)), popup)
    tmp = wl_list_next_link(popup)
    while wl_list_more_link(popup, (addr(old_c.surface.xdg.popups))):
      wlr_xdg_popup_destroy(popup)
      popup = tmp
      tmp = wl_list_next_link(popup)
  if c != nil and client_is_unmanaged(c) == 0:
    wl_list_remove(addr(c.flink))
    wl_list_insert(addr(fstack), addr(c.flink))
    selmon = c.mon
    c.isurgent = 0
    if not (old_l != nil and
        old_l.layer_surface.current.keyboard_interactive ==
        ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE) and
        seat.drag == nil:
      client_set_border_color(c, focuscolor)
  if l == nil and old != nil and (c == nil or client_surface(c) != old) and
      old_client_type == LayerShell and
      wlr_scene_node_coords(addr(old_l.scene.node), addr(unused_lx),
                            addr(unused_ly)) and
      old_l.layer_surface.current.layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP and
      old_l.layer_surface.current.keyboard_interactive ==
      ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE:
    return
  if focused_client != nil and focused_client != c and not (c != nil and client_is_unmanaged(c) != 0):
    var s: ptr wlr_surface = client_surface(focused_client)
    if c != nil:
      client_set_border_color(focused_client, bordercolor)
    if s != nil and s.mapped:
      client_activate_surface(s, 0)
    focused_client = nil
    updateTitlebar(old_c)
  publishCompositorState()
  if c == nil and l == nil:
    input_method_relay_set_focus(input_method_relay, nil)
    wlr_seat_keyboard_notify_clear_focus(seat)
    wlrForeignToplevelSyncAll()
    return
  surface = if c != nil: client_surface(c) else: l.layer_surface.surface
  input_method_relay_set_focus(input_method_relay, surface)
  client_notify_enter(surface, wlr_seat_get_keyboard(seat))
  if l != nil:
    return
  client_activate_surface(surface, 1)
  motionnotify(0, nil, 0, 0, 0, 0)
  if client_is_unmanaged(c) == 0:
    focused_client = c
  updateTitlebar(c)
  transactionschedule()
  wlrForeignToplevelSyncAll()

proc focusmon*(arg: ptr Arg) {.cdecl.} =
  var
    i: cint = 0
    nmons: cint = wl_list_length(addr(mons))
  if selmon == nil or selmon == addr parkingMonitor:
    return
  if nmons != 0:
    while true:
      selmon = dirtomon(cast[wlr_direction](arg.i))
      inc(i)
      if not (not selmon.wlr_output.enabled and i < nmons):
        break
  focusOutput(selmon)

proc focusstack*(arg: ptr Arg) {.cdecl.} =
  var
    c: ptr Client
    sel: ptr Client = if focused_client != nil and focused_client.mon == selmon:
      focused_client else: focustop(selmon)
  if locked != 0 or selmon == nil or selmon == addr parkingMonitor:
    return
  let keyboard = wlr_seat_get_keyboard(seat)
  let mods = if keyboard != nil: CLEANMASK(wlr_keyboard_get_modifiers(keyboard)) else: 0'u32
  if sel == nil:
    c = wl_list_first_link(addr clients, c)
    while wl_list_more_link(c, addr clients):
      if not c.alwaysOnTop and onSelectedTags(c, selmon):
        break
      c = wl_list_next_link(c)
    if not wl_list_more_link(c, addr clients): return
  elif arg.i > 0:
    c = wl_list_first_link((addr(sel.link)), c)
    while wl_list_more_link(c, (addr(sel.link))):
      if addr(c.link) == addr(clients):
        c = wl_list_next_link(c)
        continue
      if not c.alwaysOnTop and onSelectedTags(c, selmon):
        break
      c = wl_list_next_link(c)
  else:
    c = wl_list_last_link((addr(sel.link)), c)
    while wl_list_more_link(c, (addr(sel.link))):
      if addr(c.link) == addr(clients):
        c = wl_list_prev_link(c)
        continue
      if not c.alwaysOnTop and onSelectedTags(c, selmon):
        break
      c = wl_list_prev_link(c)
  if c.alwaysOnTop: return
  if cyclePreview != nil and cyclePreview != c:
    let previous = cyclePreview
    cyclePreview = nil
    setWindowMinimized(previous, true)
  if c.isminimized:
    setWindowMinimized(c, false)
    if mods != 0:
      cyclePreview = c
      cycleModifiers = mods
  focusclient(c, nil, 1)

proc focusLast(arg: ptr Arg) {.cdecl.} =
  let current = focusedWindowForCommand()
  if current == nil or selmon == addr(parkingMonitor) or seat.drag != nil: return
  var c = wl_list_first_flink(addr fstack, current)
  while wl_list_more_flink(c, addr fstack):
    if c != current and not c.alwaysOnTop and VISIBLEON(c, selmon):
      focusclient(c, nil, 1)
      return
    c = wl_list_next_flink(c)

proc focustop*(m: ptr Monitor): ptr Client {.cdecl.} =
  if m == addr parkingMonitor: return nil
  var c: ptr Client
  c = wl_list_first_flink(addr fstack, c)
  while wl_list_more_flink(c, addr fstack):
    if VISIBLEON(c, m):
      return c
    c = wl_list_next_flink(c)
  return nil

proc fullscreennotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, fullscreen)
  setfullscreen(c, client_wants_fullscreen(c))

proc gpureset*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var old_drw: ptr wlr_renderer = drw
  var old_alloc: ptr wlr_allocator = alloc
  var m: ptr Monitor
  drw = wlr_renderer_autocreate(backend)
  if drw == nil:
    die("couldn\'t recreate renderer")
  alloc = wlr_allocator_autocreate(backend, drw)
  if alloc == nil:
    die("couldn\'t recreate allocator")
  wl_list_remove(addr(gpuResetListener.link))
  wl_signal_add(addr(drw.events.lost), addr(gpuResetListener))
  wlr_compositor_set_renderer(compositor, drw)
  m = wl_list_first_link((addr(mons)), m)
  while wl_list_more_link(m, (addr(mons))):
    discard wlr_output_init_render(m.wlr_output, alloc, drw)
    m = wl_list_next_link(m)
  wlr_allocator_destroy(old_alloc)
  wlr_renderer_destroy(old_drw)

proc handlesig*(signo: cint) {.cdecl.} =
  if signo == SIGCHLD:
    while waitpid(-1, nil, WNOHANG) > 0:
      ## ignored statement
  elif signo == SIGINT or signo == SIGTERM:
    quit(nil)

proc inputdevice*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var device: ptr wlr_input_device = cast[ptr wlr_input_device](data)
  var caps: uint32
  if uint32(device.type_field) == uint32(WLR_INPUT_DEVICE_KEYBOARD):
    createkeyboard(wlr_keyboard_from_input_device(device))
  elif uint32(device.type_field) == uint32(WLR_INPUT_DEVICE_POINTER):
    createpointer(wlr_pointer_from_input_device(device))
  caps = uint32(WL_SEAT_CAPABILITY_POINTER)
  if wl_list_empty(addr(kb_group.wlr_group.devices)) == 0:
    caps = caps or uint32(WL_SEAT_CAPABILITY_KEYBOARD)
  wlr_seat_set_capabilities(seat, caps)
  markSwayDirty()

proc keybinding*(mods: uint32; sym: xkb_keysym_t): ptr Key {.cdecl.} =
  if runtimeLoaded:
    for key in runtimeKeys.mitems:
      if CLEANMASK(mods) == CLEANMASK(key.`mod`) and sym == key.keysym:
        return addr key
    return nil
  var k: ptr Key
  k = addr(keys[0])
  while k < END(keys):
    if CLEANMASK(mods) == CLEANMASK(k.`mod`) and sym == k.keysym and k.`func` != nil:
      return k
    k = cast[ptr Key](cast[uint](k) + cast[uint](sizeof(Key)))
  return nil

proc keypress*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var group: ptr KeyboardGroup
  group = wl_container_of(listener, group, key)
  var event: ptr wlr_keyboard_key_event = cast[ptr wlr_keyboard_key_event](data)
  var keycode: uint32 = event.keycode + 8
  var kb: ptr wlr_keyboard = addr(group.wlr_group.keyboard)
  var layout: xkb_layout_index_t = xkb_state_key_get_layout(kb.xkb_state, keycode)
  var handled: cint = 0
  var i: cint = 0
  while i < 2:
    group.keysyms[i] = keymap_get_one_sym_by_level(kb.keymap, keycode, layout,
        cast[xkb_level_index_t](i))
    inc(i)
  group.mods = wlr_keyboard_get_modifiers(addr(group.wlr_group.keyboard))
  wlr_idle_notifier_v1_notify_activity(idle_notifier, seat)
  if locked == 0 and event.state == WL_KEYBOARD_KEY_STATE_PRESSED:
    var i: cint = 0
    while i < 2:
      let key: ptr Key = keybinding(group.mods, group.keysyms[i])
      if key != nil:
        if event.keycode < uint32(LENGTH(consumed)):
          consumed[event.keycode] = 1
        key.`func`(addr(key.arg))
        handled = 1
        break
      inc(i)
  if handled != 0 and group.wlr_group.keyboard.repeat_info.delay > 0:
    discard wl_event_source_timer_update(group.key_repeat_source,
                                 group.wlr_group.keyboard.repeat_info.delay)
  else:
    discard wl_event_source_timer_update(group.key_repeat_source, 0)
  if handled != 0:
    return
  if event.keycode < uint32(LENGTH(consumed)) and consumed[event.keycode] != 0:
    if event.state == WL_KEYBOARD_KEY_STATE_RELEASED:
      consumed[event.keycode] = 0
    return
  if input_method_keyboard_grab_forward_key(group, event) != 0:
    return
  wlr_seat_set_keyboard(seat, addr(group.wlr_group.keyboard))
  wlr_seat_keyboard_notify_key(seat, event.time_msec, event.keycode,
      uint32(event.state))

proc keypressmod*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var group: ptr KeyboardGroup
  group = wl_container_of(listener, group, modifiers)
  markSwayDirty()
  if cyclePreview != nil and
      (wlr_keyboard_get_modifiers(addr group.wlr_group.keyboard) and cycleModifiers) != cycleModifiers:
    cyclePreview = nil
    cycleModifiers = 0
  if input_method_keyboard_grab_forward_modifiers(group) != 0:
    return
  wlr_seat_set_keyboard(seat, addr(group.wlr_group.keyboard))
  wlr_seat_keyboard_notify_modifiers(seat,
                                     addr(group.wlr_group.keyboard.modifiers))

proc keyrepeat*(data: pointer): cint {.cdecl.} =
  var group: ptr KeyboardGroup = cast[ptr KeyboardGroup](data)
  if locked != 0 or group.wlr_group.keyboard.repeat_info.rate <= 0:
    return 0
  discard wl_event_source_timer_update(group.key_repeat_source, 1000 div
      group.wlr_group.keyboard.repeat_info.rate)
  var i: cint = 0
  while i < 2:
    let key: ptr Key = keybinding(group.mods, group.keysyms[i])
    if key != nil:
      key.`func`(addr(key.arg))
      break
    inc(i)
  return 0

proc requestCloseFocusedWindow*(arg: ptr Arg) {.cdecl.} =
  var sel: ptr Client = focustop(selmon)
  if sel != nil:
    client_send_close(sel)

proc locksession*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var session_lock: ptr wlr_session_lock_v1 = cast[ptr wlr_session_lock_v1](data)
  var lock: ptr SessionLock
  if cur_lock != nil:
    wlr_session_lock_v1_destroy(session_lock)
    return
  lock = cast[ptr SessionLock](ecalloc(csize_t(1), csize_t(sizeof(SessionLock))))
  session_lock.data = cast[pointer](lock)
  wlr_seat_keyboard_end_grab(seat)
  focusclient(nil, nil, 0)
  input_method_relay_set_focus(input_method_relay, nil)
  wlr_seat_keyboard_notify_clear_focus(seat)
  lock.scene = wlr_scene_tree_create(layers[LyrBlock])
  lock.lock = cast[ptr wlr_session_lock_v1](session_lock)
  cur_lock = session_lock
  locked = 1
  detachInputMethodKeyboard()
  cancelPointerInteraction()
  wlr_seat_pointer_end_grab(seat)
  wlr_seat_pointer_clear_focus(seat)
  setDesktopVisible(false)
  motionnotify(0, nil, 0, 0, 0, 0)
  LISTEN(addr(session_lock.events.new_surface), addr(lock.new_surface),
         createlocksurface)
  LISTEN(addr(session_lock.events.destroy), addr(lock.destroy), destroysessionlock)
  LISTEN(addr(session_lock.events.unlock), addr(lock.unlock), unlocksession)
  var m = wl_list_first_link(addr mons, cast[ptr Monitor](nil))
  while wl_list_more_link(m, addr mons):
    m.lockFrame = LockFrameNeeded
    if m.wlr_output.enabled: wlr_output_schedule_frame(m.wlr_output)
    m = wl_list_next_link(m)
  acknowledgePresentedLock()

proc handleClientMap*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var p: ptr Client = nil
  var
    w: ptr Client
    c: ptr Client
  c = wl_container_of(listener, c, map)
  c.isminimized = false
  var m: ptr Monitor
  var i: cint
  var foreign_toplevel_state: wlr_ext_foreign_toplevel_handle_v1_state =
      wlr_ext_foreign_toplevel_handle_v1_state(app_id: client_get_appid(c),
          title: client_get_title(c))
  c.scene = wlr_scene_tree_create(layers[LyrTile])
  client_surface(c).data = cast[pointer](c.scene)
  wlr_scene_node_set_enabled(addr(c.scene.node), client_is_unmanaged(c) != 0)
  c.scene_surface = if c.`type` == XDGShell: wlr_scene_xdg_surface_create(c.scene,
      c.surface.xdg) else: wlr_scene_subsurface_tree_create(c.scene,
      client_surface(c))
  c.scene.node.data = cast[pointer](c)
  c.scene_surface.node.data = cast[pointer](c)
  client_get_geometry(c, addr(c.geom))
  # Unmanaged popups get a display scene only, not a capture scene or handle.
  if client_is_unmanaged(c) != 0:
    wlr_scene_node_reparent(addr(c.scene.node), layers[LyrUnmanaged])
    wlr_scene_node_set_position(addr(c.scene.node), c.geom.x, c.geom.y)
    if client_wants_focus(c) != 0:
      focusclient(c, nil, 1)
    m = if c.mon != nil: c.mon else: xytomon(cdouble(c.geom.x), cdouble(c.geom.y))
    w = wl_list_first_link((addr(clients)), w)
    while wl_list_more_link(w, (addr(clients))):
      if w != c and w != p and w.isfullscreen != 0 and m == w.mon and ((w.tags and c.tags) != 0):
        setfullscreen(w, 0)
        focusclient(focustop(selmon), nil, 1)
      w = wl_list_next_link(w)
    return
  i = 0
  while i < 4:
    c.border[i] = wlr_scene_rect_create(c.scene, 0, 0, if c.isurgent != 0: urgentcolor else: bordercolor)
    c.border[i].node.data = c
    inc(i)
  if not c.titlebarInitialized:
    c.showTitlebar = activeConfig.titlebars
    c.titlebarInitialized = true
  c.hasTitle = client_has_title(c)
  c.titlebarDirty = true
  c.geom.width += 2 * cint(c.bw)
  c.geom.height += client_frame_height(c)
  c.isfixed = 0
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      var
        x: cint = c.geom.x - cast[cint](c.bw)
        y: cint = c.geom.y - client_top_inset(c)
      c.geom.x = if c.geom.x < sgeom.x: x else: MAX(x, sgeom.x)
      c.geom.y = if c.geom.y < sgeom.y: y else: MAX(y, sgeom.y)
      c.isfullscreen = client_wants_fullscreen(c)
  c.foreign_toplevel_handle = wlr_ext_foreign_toplevel_handle_v1_create(
      foreign_toplevel_list, addr(foreign_toplevel_state))
  c.foreign_toplevel_handle.data = c
  c.image_capture_scene = wlr_scene_create()
  if c.`type` == XDGShell:
    c.capture.image_capture_tree = wlr_scene_xdg_surface_create(
        addr(c.image_capture_scene.tree), c.surface.xdg)
  when defined(XWAYLAND):
    if c.`type` != XDGShell:
      c.capture.image_capture_scene_surface = wlr_scene_surface_create(
          addr(c.image_capture_scene.tree), c.surface.xwayland.surface)
  p = client_get_parent(c)
  if p != nil:
    c.isfloating = 1
    setmon(c, if p.mon != nil: p.mon else: selmon, p.tags)
  else:
    applyrules(c)
  let maximize = if client_is_x11(c) != 0: c.ismaximized
    else: c.surface.xdg.toplevel.requested.maximized
  c.ismaximized = false
  setWindowMaximized(c, maximize)
  # Run rules before inserting into layout/focus lists: automatic arrangement
  # must not replace the requested size before a fixedSize/floating rule runs.
  runWindowRules(c)
  wl_list_insert(addr(clients), addr(c.link))
  wl_list_insert(addr(fstack), addr(c.flink))
  if c.mon != addr parkingMonitor: initializeZoneClient(c)
  if c.mon != nil:
    # Initial zone assignment must not shrink a rule-selected fullscreen window.
    if c.isfullscreen != 0: resize(c, c.mon.m, 0)
    arrange(c.mon)
  focusclient(focustop(selmon), nil, 1)
  publishCompositorState()
  if selmon == addr parkingMonitor: return
  m = if c.mon != nil: c.mon else: xytomon(cdouble(c.geom.x), cdouble(c.geom.y))
  w = wl_list_first_link((addr(clients)), w)
  while wl_list_more_link(w, (addr(clients))):
    if w != c and w != p and w.isfullscreen != 0 and m == w.mon and ((w.tags and c.tags) != 0):
      setfullscreen(w, 0)
      focusclient(focustop(selmon), nil, 1)
    w = wl_list_next_link(w)

proc setWindowMinimized(c: ptr Client; minimized: bool) =
  if locked != 0 or c == nil or c.mon == nil or client_is_unmanaged(c) != 0 or
      not client_surface(c).mapped or c.isminimized == minimized:
    return
  if c == grabc: cancelPointerInteraction()
  c.isminimized = minimized
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      xwaylandSetMinimized(c.surface.xwayland, minimized)
  if minimized:
    wlr_scene_node_set_enabled(addr(c.scene.node), false)
  arrange(c.mon)
  if minimized and focused_client == c:
    focusclient(focustop(selmon), nil, 1)
  wlrForeignToplevelSyncAll()
  publishCompositorState()

proc setWindowMaximized(c: ptr Client; maximized: bool) =
  if locked != 0 or c == nil or client_is_unmanaged(c) != 0: return
  if c.mon == nil or not client_surface(c).mapped:
    c.ismaximized = maximized
    return
  if c.ismaximized == maximized: return
  if c == grabc: cancelPointerInteraction()
  if c.isfullscreen != 0: setfullscreen(c, 0)
  if maximized: c.maximizeRestore = c.geom
  c.ismaximized = maximized
  client_set_maximized(c, maximized)
  resize(c, if maximized: c.mon.w else: c.maximizeRestore, 0)
  if maximized: wlr_scene_node_raise_to_top(addr(c.scene.node))
  arrange(c.mon)
  wlrForeignToplevelSyncAll()
  publishCompositorState()

proc minimizeWindow(arg: ptr Arg) {.cdecl.} =
  setWindowMinimized(focusedWindowForCommand(), true)

proc maximizeWindow(arg: ptr Arg) {.cdecl.} =
  let c = focusedWindowForCommand()
  if c != nil:
    setWindowMaximized(c, if arg.i < 0: not c.ismaximized else: arg.i != 0)

proc minimizenotify(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, minimize)
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      setWindowMinimized(c, cast[ptr XwaylandMinimizeEvent](data).minimize)
      return
  setWindowMinimized(c, true)

proc maximizenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, maximize)
  when defined(XWAYLAND):
    if client_is_x11(c) != 0:
      setWindowMaximized(c, c.surface.xwayland.maximized_horz or c.surface.xwayland.maximized_vert)
      return
  setWindowMaximized(c, c.surface.xdg.toplevel.requested.maximized)

proc monocle*(m: ptr Monitor) {.cdecl.} =
  var c: ptr Client
  var n: cint = 0
  c = wl_list_first_link((addr(clients)), c)
  while wl_list_more_link(c, (addr(clients))):
    if not VISIBLEON(c, m) or client_places_manually(c) or c.isfullscreen != 0 or c.isfixed != 0 or c.ismaximized:
      c = wl_list_next_link(c)
      continue
    resize(c, m.w, 0)
    inc(n)
    c = wl_list_next_link(c)
  if n != 0:
    discard snprintf(cast[cstring](addr(m.ltsymbol[0])), csize_t(LENGTH(m.ltsymbol)),
        "[%d]", n)
  c = focustop(m)
  if c != nil:
    wlr_scene_node_raise_to_top(addr(c.scene.node))

proc motionabsolute*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_pointer_motion_absolute_event = cast[ptr wlr_pointer_motion_absolute_event](data)
  var
    lx: cdouble
    ly: cdouble
    dx: cdouble
    dy: cdouble
  if event.time_msec == 0:
    wlr_cursor_warp_absolute(cursor, addr(event.pointer.base), event.x, event.y)
  wlr_cursor_absolute_to_layout_coords(cursor, addr(event.pointer.base), event.x,
                                       event.y, addr(lx), addr(ly))
  dx = lx - cursor.x
  dy = ly - cursor.y
  motionnotify(event.time_msec, addr(event.pointer.base), dx, dy, dx, dy)

proc findDisabledOutputEntry*(wlr_output: ptr wlr_output): cstringArray {.cdecl.} =
  var name: cstringArray
  name = wl_array_first((addr(offmons)), name)
  while wl_array_more(name, (addr(offmons))):
    if strcmp(name[0], wlr_output.name) == 0:
      return name
    name = wl_array_next(name)
  return nil

proc motionnotify*(time: uint32; device: ptr wlr_input_device; dx: cdouble; dy: cdouble;
                  dx_unaccel: cdouble; dy_unaccel: cdouble) {.cdecl.} =
  var
    nx: cint
    ny: cint
  var
    sx: cdouble = 0
    sy: cdouble = 0
    sx_confined: cdouble
    sy_confined: cdouble
  var
    c: ptr Client = nil
    w: ptr Client = nil
    confined_dx: cdouble = dx
    confined_dy: cdouble = dy
  var
    l: ptr LayerSurface = nil
    focusedl: ptr LayerSurface = nil
  var surface: ptr wlr_surface = nil
  if time != 0:
    wlr_relative_pointer_manager_v1_send_relative_motion(relative_pointer_mgr,
        seat, uint64(time) * 1000'u64, dx, dy, dx_unaccel, dy_unaccel)
    cursorconstrain(wlr_pointer_constraints_v1_constraint_for_surface(
        pointer_constraints, seat.pointer_state.focused_surface, seat))
    if active_constraint != nil and cursor_mode != CurResize and cursor_mode != CurMove:
      discard toplevel_from_wlr_surface(active_constraint.surface, addr(c), nil)
      if c != nil and active_constraint.surface == seat.pointer_state.focused_surface:
        sx = cursor.x - cdouble(c.geom.x) - cdouble(c.bw)
        sy = cursor.y - cdouble(c.geom.y) - cdouble(client_top_inset(c))
        if wlr_region_confine(addr(active_constraint.region), sx, sy, sx + dx, sy + dy,
                             addr(sx_confined), addr(sy_confined)):
          confined_dx = sx_confined - sx
          confined_dy = sy_confined - sy
        if active_constraint.type_field == WLR_POINTER_CONSTRAINT_V1_LOCKED:
          return
    wlr_cursor_move(cursor, device, confined_dx, confined_dy)
    wlr_idle_notifier_v1_notify_activity(idle_notifier, seat)
    if sloppyfocus != 0:
      let previous = selmon
      selmon = xytomon(cursor.x, cursor.y)
      if selmon != previous:
        publishCompositorState()
  wlr_scene_node_set_position(addr(drag_icon.node), cint(round(cursor.x)),
                              cint(round(cursor.y)))
  if cursor_mode == CurMove:
    if selmon == nil:
      return
    nx = cint(round(cursor.x)) - grabcx
    ny = cint(round(cursor.y)) - grabcy
    let destination = xytomon(cursor.x, cursor.y)
    let geometry = snapGeometry(grabc, destination, wlr_box(x: nx, y: ny,
      width: grabc.geom.width, height: grabc.geom.height), false)
    let previous = grabc.geom
    resize(grabc, geometry, 1)
    if grabc.geom != previous: forgetOutputPlacement(grabc)
    updateZonePreview()
    return
  elif cursor_mode == CurResize:
    let destination = xytomon(cursor.x, cursor.y)
    let px = cint(round(cursor.x))
    let py = cint(round(cursor.y))
    let width = max(1, if grabResizeLeft: grabcx - px else: px - grabcx)
    let height = max(1, if grabResizeTop: grabcy - py else: py - grabcy)
    let geometry = snapGeometry(grabc, destination, wlr_box(
      x: if grabResizeLeft: grabcx - width else: grabcx,
      y: if grabResizeTop: grabcy - height else: grabcy,
      width: width, height: height), true, grabResizeLeft, grabResizeTop)
    let previous = grabc.geom
    resize(grabc, geometry, 1)
    if grabc.geom != previous: forgetOutputPlacement(grabc)
    updateZonePreview()
    return
  xytonode(cursor.x, cursor.y, addr(surface), addr(c), addr(l), addr(sx), addr(sy))
  if cursor_mode == CurPressed and seat.drag == nil and
      surface != seat.pointer_state.focused_surface and
      toplevel_from_wlr_surface(seat.pointer_state.focused_surface, addr(w),
                                addr(focusedl)) >= 0:
    c = w
    surface = seat.pointer_state.focused_surface
    sx = cursor.x - cdouble(if focusedl != nil: focusedl.scene.node.x else: w.geom.x)
    sy = cursor.y - cdouble(if focusedl != nil: focusedl.scene.node.y else: w.geom.y)
  if surface == nil and seat.drag == nil:
    wlr_cursor_set_xcursor(cursor, cursor_mgr, "default")
  pointerfocus(c, l, surface, sx, sy, time)
  cursorconstrain(wlr_pointer_constraints_v1_constraint_for_surface(
      pointer_constraints, seat.pointer_state.focused_surface, seat))

proc motionrelative*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_pointer_motion_event = cast[ptr wlr_pointer_motion_event](data)
  motionnotify(event.time_msec, addr(event.pointer.base), event.delta_x,
               event.delta_y, event.unaccel_dx, event.unaccel_dy)

proc setFloatingMode(c: ptr Client; floating: cint; detachZone: bool) =
  let changed = c.isfloating != floating
  if changed: forgetOutputPlacement(c)
  c.isfloating = floating
  if floating != 0:
    if detachZone: clearClientZoneName(c)
  elif changed and c.zoneInitialized and not c.alwaysOnTop and
      clientZoneName(c)[0] == '\0':
    c.zoneInitialized = false
    if c.mon != addr parkingMonitor: initializeZoneClient(c)
  if c.mon == nil or not client_surface(c).mapped or c.mon.lt[c.mon.sellt].arrange == nil:
    return
  arrange(c.mon)
  publishCompositorState()

proc moveresize*(arg: ptr Arg) {.cdecl.} =
  if not pointerOperationAllowed() or arg.ui notin [uint32(CurMove), uint32(CurResize)]:
    return
  if cursor_mode != CurNormal and cursor_mode != CurPressed:
    return
  xytonode(cursor.x, cursor.y, nil, addr(grabc), nil, nil, nil)
  if grabc == nil or client_is_unmanaged(grabc) != 0 or grabc.isfullscreen != 0:
    return
  if grabc.ismaximized:
    let moving = grabc
    setWindowMaximized(moving, false)
    grabc = moving
  cursor_mode = cuint(arg.ui)
  if not grabc.alwaysOnTop: setFloatingMode(grabc, 1, false)
  case cursor_mode
  of CurMove:
    grabcx = cint(round(cursor.x)) - grabc.geom.x
    grabcy = cint(round(cursor.y)) - grabc.geom.y
    wlr_cursor_set_xcursor(cursor, cursor_mgr, "all-scroll")
  of CurResize:
    grabResizeLeft = cursor.x < cdouble(grabc.geom.x) + cdouble(grabc.geom.width) / 2
    grabResizeTop = cursor.y < cdouble(grabc.geom.y) + cdouble(grabc.geom.height) / 2
    grabcx = grabc.geom.x + (if grabResizeLeft: grabc.geom.width else: 0)
    grabcy = grabc.geom.y + (if grabResizeTop: grabc.geom.height else: 0)
    wlr_cursor_warp_closest(cursor, nil,
      cdouble(grabc.geom.x + (if grabResizeLeft: 0 else: grabc.geom.width)),
      cdouble(grabc.geom.y + (if grabResizeTop: 0 else: grabc.geom.height)))
    let shape = if grabResizeTop:
        (if grabResizeLeft: "nw-resize" else: "ne-resize")
      else:
        (if grabResizeLeft: "sw-resize" else: "se-resize")
    wlr_cursor_set_xcursor(cursor, cursor_mgr, shape)
  else:
    discard

proc outputmgrapply*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var config: ptr wlr_output_configuration_v1 = cast[ptr wlr_output_configuration_v1](data)
  outputmgrapplyortest(config, 0)

proc outputmgrapplyortest*(config: ptr wlr_output_configuration_v1; test: cint) {.
    cdecl.} =
  var config_head: ptr wlr_output_configuration_head_v1
  var states_len: csize_t
  var i: csize_t
  var swapchain_manager: wlr_output_swapchain_manager
  var states = wlr_output_configuration_v1_build_state(config, addr(states_len))
  var ok: bool = false
  if states == nil:
    wlr_output_configuration_v1_send_failed(config)
    return
  inc outputLayoutUpdates
  wlr_output_swapchain_manager_init(addr(swapchain_manager), backend)
  ok = wlr_output_swapchain_manager_prepare(addr(swapchain_manager), states, states_len)
  if ok and test == 0:
    i = 0
    while i < states_len:
      let state = addr(cast[ptr UncheckedArray[wlr_backend_output_state]](states)[int(i)])
      let m: ptr Monitor = cast[ptr Monitor](state[].output.data)
      var opts: wlr_scene_output_state_options =
          wlr_scene_output_state_options(swapchain:
            wlr_output_swapchain_manager_get_swapchain(
              addr(swapchain_manager), state[].output))
      ok = wlr_scene_output_build_state(m.scene_output, addr(state[].base), addr(opts))
      if not ok:
        break
      inc(i)
    if ok:
      ok = wlr_backend_commit(backend, states, states_len)
    if ok:
      wlr_output_swapchain_manager_apply(addr(swapchain_manager))
      config_head = wl_list_first_link((addr(config.heads)), config_head)
      while wl_list_more_link(config_head, (addr(config.heads))):
        let wlr_output: ptr wlr_output = config_head.state.output
        let m: ptr Monitor = cast[ptr Monitor](wlr_output.data)
        m.asleep = 0
        setOutputDisabledRecord(wlr_output, cint(not config_head.state.enabled))
        if config_head.state.enabled and
            (m.m.x != config_head.state.x or m.m.y != config_head.state.y or
            wlr_output_layout_get(output_layout, wlr_output) == nil):
          discard wlr_output_layout_add(output_layout, wlr_output, config_head.state.x,
                                config_head.state.y)
        config_head = wl_list_next_link(config_head)
  wlr_output_swapchain_manager_finish(addr(swapchain_manager))
  i = 0
  while i < states_len:
    let state = addr(cast[ptr UncheckedArray[wlr_backend_output_state]](states)[int(i)])
    wlr_output_state_finish(addr(state[].base))
    inc(i)
  free(states)
  if ok:
    wlr_output_configuration_v1_send_succeeded(config)
  else:
    wlr_output_configuration_v1_send_failed(config)
  wlr_output_configuration_v1_destroy(config)
  dec outputLayoutUpdates
  updatemons(nil, nil)
proc outputmgrtest*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var config: ptr wlr_output_configuration_v1 = cast[ptr wlr_output_configuration_v1](data)
  outputmgrapplyortest(config, 1)

proc pointerfocus*(c: ptr Client; l: ptr LayerSurface; surface: ptr wlr_surface;
                  sx: cdouble; sy: cdouble; time: uint32) {.cdecl.} =
  var now: timespec
  var notify_time: uint32 = time
  if surface != seat.pointer_state.focused_surface and sloppyfocus != 0 and time != 0 and
      seat.drag == nil:
    if c != nil and (client_is_unmanaged(c) == 0 or client_wants_focus(c) != 0):
      focusclient(c, nil, 0)
    elif l != nil and l.layer_surface.current.keyboard_interactive !=
        ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE:
      focusclient(nil, l, 0)
  if surface == nil:
    wlr_seat_pointer_notify_clear_focus(seat)
    return
  if time == 0:
    discard clock_gettime(CLOCK_MONOTONIC, addr(now))
    notify_time = uint32(now.tv_sec * 1000 + now.tv_nsec div 1000000)
  wlr_seat_pointer_notify_enter(seat, surface, sx, sy)
  wlr_seat_pointer_notify_motion(seat, notify_time, sx, sy)

proc publishCompositorState*() {.cdecl.} =
  var m: ptr Monitor = nil
  var c: ptr Client
  var
    occ: uint32
    urg: uint32
    sel: uint32
  m = wl_list_first_link((addr(mons)), m)
  while wl_list_more_link(m, (addr(mons))):
    occ = 0
    urg = 0
    c = wl_list_first_link((addr(clients)), c)
    while wl_list_more_link(c, (addr(clients))):
      if c.mon != m:
        c = wl_list_next_link(c)
        continue
      occ = occ or c.tags
      if c.isurgent != 0:
        urg = urg or c.tags
      c = wl_list_next_link(c)
    c = focustop(m)
    if c != nil:
      discard printf("%s title %s\n", m.wlr_output.name, client_get_title(c))
      discard printf("%s appid %s\n", m.wlr_output.name, client_get_appid(c))
      discard printf("%s fullscreen %d\n", m.wlr_output.name, c.isfullscreen)
      discard printf("%s floating %d\n", m.wlr_output.name, c.isfloating)
      sel = c.tags
    else:
      discard printf("%s title \n", m.wlr_output.name)
      discard printf("%s appid \n", m.wlr_output.name)
      discard printf("%s fullscreen \n", m.wlr_output.name)
      discard printf("%s floating \n", m.wlr_output.name)
      sel = 0
    discard printf("%s selmon %u\n", m.wlr_output.name, cuint(m == selmon))
    discard printf("%s tags %u %u %u %u\n", m.wlr_output.name, occ, m.tagset[m.seltags], sel, urg)
    discard printf("%s layout %s\n", m.wlr_output.name, m.ltsymbol)
    m = wl_list_next_link(m)
  discard fflush(stdout)
  markSwayDirty()
  wlrForeignToplevelSyncAll()

proc powermgrsetmode*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_output_power_v1_set_mode_event = cast[ptr wlr_output_power_v1_set_mode_event](data)
  var state: wlr_output_state
  var m: ptr Monitor = cast[ptr Monitor](event.output.data)
  if m == nil:
    return
  let mode_on = event.mode == ZWLR_OUTPUT_POWER_V1_MODE_ON
  wlr_output_state_init(addr state)
  m.gamma_lut_changed = 1
  wlr_output_state_set_enabled(addr(state), mode_on)
  if mode_on and m.wlr_output.current_mode == nil:
    wlr_output_state_set_mode(addr(state),
                              wlr_output_preferred_mode(m.wlr_output))
  inc outputLayoutUpdates
  let committed = wlr_output_commit_state(m.wlr_output, addr state)
  dec outputLayoutUpdates
  if committed:
    m.asleep = cint(not mode_on)
    if mode_on: setOutputDisabledRecord(m.wlr_output, 0)
    updatemons(nil, nil)
  wlr_output_state_finish(addr state)

proc quit*(arg: ptr Arg) {.cdecl.} =
  wl_display_terminate(dpy)

proc refocuspointer*(data: pointer) {.cdecl.} =
  motionnotify(0, nil, 0, 0, 0, 0)

proc rendermon*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var m: ptr Monitor
  m = wl_container_of(listener, m, frame)
  if pendingLock() != nil and m.lockFrame == LockFrameNeeded:
    # Arm before committing: some backends report presentation synchronously.
    var state: wlr_output_state
    wlr_output_state_init(addr state)
    defer: wlr_output_state_finish(addr state)
    if not wlr_scene_output_build_state(m.scene_output, addr state, nil) or
        state.buffer == nil:
      wlr_output_schedule_frame(m.wlr_output)
      return
    m.lockCommitSeq = m.wlr_output.commit_seq + 1'u32
    m.lockFrame = LockFrameSubmitted
    if not wlr_output_commit_state(m.wlr_output, addr state):
      m.lockFrame = LockFrameNeeded
      wlr_output_schedule_frame(m.wlr_output)
      return
  else:
    if not wlr_scene_output_needs_frame(m.scene_output): return
    discard wlr_scene_output_commit(m.scene_output, nil)
  var now: timespec
  discard clock_gettime(CLOCK_MONOTONIC, addr(now))
  wlr_scene_output_send_frame_done(m.scene_output, addr(now))

proc requestdecorationmode*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, set_decoration_mode)
  if c.surface.xdg.initialized:
    discard wlr_xdg_toplevel_decoration_v1_set_mode(c.decoration,
        WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)

proc requeststartdrag*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_seat_request_start_drag_event = cast[ptr wlr_seat_request_start_drag_event](data)
  if locked == 0 and wlr_seat_validate_pointer_grab_serial(seat, event.origin, event.serial):
    wlr_seat_start_pointer_drag(seat, event.drag, event.serial)
  else:
    wlr_data_source_destroy(event.drag.source)

proc requestmonstate*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_output_event_request_state = cast[ptr wlr_output_event_request_state](data)
  inc outputLayoutUpdates
  discard wlr_output_commit_state(event.output, event.state)
  dec outputLayoutUpdates
  updatemons(nil, nil)

proc resize*(c: ptr Client; geo: wlr_box; interact: cint) {.cdecl.} =
  var bbox: ptr wlr_box
  var serial: uint32
  if c.mon == nil or not client_surface(c).mapped:
    return
  bbox = if interact != 0 and c.mon != addr(parkingMonitor): addr(sgeom) else: addr(c.mon.w)
  discard client_set_bounds(c, max(0, geo.width - 2 * cint(c.bw)),
    max(0, geo.height - client_frame_height(c)))
  c.geom = geo
  applybounds(c, bbox)
  if interact != 0 and c == grabc and cursor_mode == CurResize:
    c.geom.x = if grabResizeLeft: grabcx - c.geom.width else: grabcx
    c.geom.y = if grabResizeTop: grabcy - c.geom.height else: grabcy
  serial = client_set_size(c, uint32(c.geom.width - 2 * cint(c.bw)),
      uint32(c.geom.height - client_frame_height(c)))
  if serial != 0:
    c.resize_serial = serial
  if interact != 0 or
      (c.resize_serial == 0 and wlr_box_equal(addr(c.geom), addr(c.current))):
    c.resize_serial = 0
    applygeom(c)
    return
  if c.resize_serial != 0:
    if c.snapshot == nil and c.scene.node.enabled:
      c.snapshot = cloneSceneSubtree(addr(c.scene_surface.node), c.scene, c)
      if c.snapshot != nil:
        wlr_scene_node_set_enabled(addr(c.scene_surface.node), false)
    client_send_frame_done(c)
  transactionschedule()

proc run*(startup_cmd: cstring) {.cdecl.} =
  let socket: cstring = wl_display_add_socket_auto(dpy)
  if socket == nil:
    die("startup: display_add_socket_auto")
  discard setenv("WAYLAND_DISPLAY", socket, 1)
  startSwayIpc()
  if not wlr_backend_start(backend):
    die("startup: backend_start")
  if startup_cmd != nil:
    var piperw: array[2, cint]
    if pipe(piperw) < 0:
      die("startup: pipe:")
    child_pid = fork()
    if child_pid < 0:
      die("startup: fork:")
    if child_pid == 0:
      discard setsid()
      discard dup2(piperw[0], STDIN_FILENO)
      discard close(piperw[0])
      discard close(piperw[1])
      discard execl("/bin/sh", "/bin/sh", "-c", startup_cmd, nil)
      die("startup: execl:")
    discard dup2(piperw[1], STDOUT_FILENO)
    discard close(piperw[1])
    discard close(piperw[0])
  if fd_set_nonblock(STDOUT_FILENO) < 0:
    discard close(STDOUT_FILENO)
  let primary = defaultConfiguredMonitor(activeConfig)
  if primary != nil:
    selmon = primary
    wlr_cursor_warp_closest(cursor, nil,
      cdouble(primary.m.x) + cdouble(primary.m.width) / 2,
      cdouble(primary.m.y) + cdouble(primary.m.height) / 2)
  else:
    let underCursor = xytomon(cursor.x, cursor.y)
    if underCursor != nil: selmon = underCursor
    wlr_cursor_warp_closest(cursor, nil, cursor.x, cursor.y)
  wlr_cursor_set_xcursor(cursor, cursor_mgr, "default")
  positionConfiguredOutputs(activeConfig)
  publishCompositorState()
  startConfiguredPrograms()
  wl_display_run(dpy)

proc setcursor*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_seat_pointer_request_set_cursor_event = cast[ptr wlr_seat_pointer_request_set_cursor_event](data)
  if cursor_mode != CurNormal and cursor_mode != CurPressed:
    return
  if event.seat_client == seat.pointer_state.focused_client:
    wlr_cursor_set_surface(cursor, event.surface, event.hotspot_x, event.hotspot_y)

proc setcursorshape*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_cursor_shape_manager_v1_request_set_shape_event = cast[ptr wlr_cursor_shape_manager_v1_request_set_shape_event](data)
  if cursor_mode != CurNormal and cursor_mode != CurPressed:
    return
  if event.seat_client == seat.pointer_state.focused_client:
    wlr_cursor_set_xcursor(cursor, cursor_mgr,
                           wlr_cursor_shape_v1_name(event.shape))

proc setfloating*(c: ptr Client; floating: cint) {.cdecl.} =
  setFloatingMode(c, floating, true)

proc setfullscreen*(c: ptr Client; fullscreen: cint) {.cdecl.} =
  var wasfullscreen: cint = c.isfullscreen
  c.isfullscreen = fullscreen
  if c.mon == nil or not client_surface(c).mapped:
    return
  c.bw = if fullscreen != 0 or c.hideBorder: 0'u32 else: borderpx
  updateTitlebar(c)
  client_set_fullscreen(c, fullscreen)
  if fullscreen != 0:
    if wasfullscreen == 0:
      c.prev = c.geom
    resize(c, c.mon.m, 0)
  elif wasfullscreen != 0:
    resize(c, c.prev, 0)
  arrange(c.mon)
  publishCompositorState()

proc setlayout*(arg: ptr Arg) {.cdecl.} =
  if selmon == nil or selmon == addr parkingMonitor:
    return
  if arg == nil or arg.v == nil or arg.v != selmon.lt[selmon.sellt]:
    selmon.sellt = selmon.sellt xor 1
  if arg != nil and arg.v != nil:
    selmon.lt[selmon.sellt] = cast[ptr Layout](arg.v)
  discard strncpy(cast[cstring](addr(selmon.ltsymbol[0])),
      selmon.lt[selmon.sellt].symbol, csize_t(LENGTH(selmon.ltsymbol)))
  arrange(selmon)
  publishCompositorState()

proc setmon*(c: ptr Client; m: ptr Monitor; newtags: uint32) {.cdecl.} =
  var oldmon: ptr Monitor = c.mon
  if oldmon == m:
    return
  forgetOutputPlacement(c)
  if oldmon != nil and m != nil:
    c.maximizeRestore.x += m.w.x - oldmon.w.x
    c.maximizeRestore.y += m.w.y - oldmon.w.y
  c.mon = m
  if c.isfullscreen == 0 or wlr_box_empty(addr(c.prev)):
    c.prev = c.geom
  if oldmon != nil:
    arrange(oldmon)
  if m != nil:
    resize(c, c.geom, 0)
    c.tags = if newtags != 0: newtags else: m.tagset[m.seltags]
    setfullscreen(c, c.isfullscreen)
  focusclient(focustop(selmon), nil, 1)

proc setOutputDisabledRecord*(wlr_output: ptr wlr_output; off: cint) {.cdecl.} =
  var name: cstringArray = findDisabledOutputEntry(wlr_output)
  if off != 0 and name == nil:
    let slot = cast[ptr cstring](wl_array_add(addr(offmons), csize_t(sizeof(cstring))))
    if slot != nil:
      slot[] = strdup(wlr_output.name)
      if slot[] == nil:
        offmons.size -= csize_t(sizeof(cstring))
  elif off == 0 and name != nil:
    free(cast[pointer](name[0]))
    let last = cast[ptr cstring](cast[uint](offmons.data) +
        cast[uint](offmons.size) - cast[uint](sizeof(cstring)))
    name[0] = last[]
    offmons.size -= csize_t(sizeof(cstring))
proc setpsel*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_seat_request_set_primary_selection_event = cast[ptr wlr_seat_request_set_primary_selection_event](data)
  wlr_seat_set_primary_selection(seat, event.source, event.serial)

proc setsel*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_seat_request_set_selection_event = cast[ptr wlr_seat_request_set_selection_event](data)
  wlr_seat_set_selection(seat, event.source, event.serial)

proc setup*() {.cdecl.} =
  var
    drm_fd: cint
    i: cint
    sig: array[4, cint] = [cint(SIGCHLD), cint(SIGINT), cint(SIGTERM), cint(SIGPIPE)]
  var sa: sigaction
  sa.sa_flags = SA_RESTART
  sa.compiler_sigaction_handler.sa_handler = handlesig
  discard sigemptyset(addr(sa.sa_mask))
  i = 0
  while i < cast[cint](LENGTH(sig)):
    discard sigaction_proc(sig[i], addr(sa), nil)
    inc(i)
  wlr_log_init(log_level, nil)
  dpy = wl_display_create()
  # Keep registry visibility fixed for the display's lifetime.
  if activeConfig.waylandProtocolsRestricted:
    wl_display_set_global_filter(dpy, filterWaylandGlobal, nil)
  wlrForeignToplevelInit()
  event_loop = wl_display_get_event_loop(dpy)
  backend = wlr_backend_autocreate(event_loop, addr(session))
  if backend == nil:
    die("couldn\'t create backend")
  wl_signal_add(addr(backend.events.destroy), addr(backend_destroy))
  scene = wlr_scene_create()
  root_bg = wlr_scene_rect_create(addr(scene.tree), 0, 0, rootcolor)
  i = 0
  while i < NUM_LAYERS:
    layers[i] = wlr_scene_tree_create(addr(scene.tree))
    inc(i)
  drag_icon = wlr_scene_tree_create(addr(scene.tree))
  wlr_scene_node_place_below(addr(drag_icon.node), addr(layers[LyrBlock].node))
  drw = wlr_renderer_autocreate(backend)
  if drw == nil:
    die("couldn\'t create renderer")
  wl_signal_add(addr(drw.events.lost), addr(gpuResetListener))
  discard wlr_renderer_init_wl_shm(drw, dpy)
  if wlr_renderer_get_texture_formats(drw, uint32(WLR_BUFFER_CAP_DMABUF)) != nil:
    discard wlr_drm_create(dpy, drw)
    wlr_scene_set_linux_dmabuf_v1(scene,
      wlr_linux_dmabuf_v1_create_with_renderer(dpy, 5, drw))
  drm_fd = wlr_renderer_get_drm_fd(drw)
  if drm_fd >= 0 and drw.features.timeline and
      backend.features.timeline:
    discard wlr_linux_drm_syncobj_manager_v1_create(dpy, 1, drm_fd)
  alloc = wlr_allocator_autocreate(backend, drw)
  if alloc == nil:
    die("couldn\'t create allocator")
  compositor = wlr_compositor_create(dpy, 6, drw)
  discard wlr_subcompositor_create(dpy)
  discard wlr_data_device_manager_create(dpy)
  discard wlr_export_dmabuf_manager_v1_create(dpy)
  discard wlr_screencopy_manager_v1_create(dpy)
  discard wlr_ext_image_copy_capture_manager_v1_create(dpy, 1)
  discard wlr_ext_output_image_capture_source_manager_v1_create(dpy, 1)
  discard wlr_data_control_manager_v1_create(dpy)
  discard wlr_ext_data_control_manager_v1_create(dpy, 1)
  discard wlr_primary_selection_v1_device_manager_create(dpy)
  discard wlr_viewporter_create(dpy)
  discard wlr_single_pixel_buffer_manager_v1_create(dpy)
  discard wlr_fractional_scale_manager_v1_create(dpy, 1)
  discard wlr_presentation_create(dpy, backend, 2)
  discard wlr_alpha_modifier_v1_create(dpy)
  activation = wlr_xdg_activation_v1_create(dpy)
  wl_signal_add(addr(activation.events.request_activate), addr(request_activate))
  wlr_scene_set_gamma_control_manager_v1(scene,
      wlr_gamma_control_manager_v1_create(dpy))
  power_mgr = wlr_output_power_manager_v1_create(dpy)
  wl_signal_add(addr(power_mgr.events.set_mode), addr(output_power_mgr_set_mode))
  output_layout = wlr_output_layout_create(dpy)
  wl_signal_add(addr(output_layout.events.change), addr(layout_change))
  discard wlr_xdg_output_manager_v1_create(dpy, output_layout)
  wl_list_init(addr(mons))
  wl_signal_add(addr(backend.events.new_output), addr(new_output))
  wl_list_init(addr(clients))
  wl_list_init(addr(fstack))
  transaction_timer = wl_event_loop_add_timer(event_loop, transactiontimeout, nil)
  wl_array_init(addr(ghosts))
  wl_array_init(addr(offmons))
  xdg_shell = wlr_xdg_shell_create(dpy, 6)
  wl_signal_add(addr(xdg_shell.events.new_toplevel), addr(new_xdg_toplevel))
  wl_signal_add(addr(xdg_shell.events.new_popup), addr(new_xdg_popup))
  layer_shell = wlr_layer_shell_v1_create(dpy, 4)
  wl_signal_add(addr(layer_shell.events.new_surface), addr(new_layer_surface))
  idle_notifier = wlr_idle_notifier_v1_create(dpy)
  idle_inhibit_mgr = wlr_idle_inhibit_v1_create(dpy)
  wl_signal_add(addr(idle_inhibit_mgr.events.new_inhibitor),
                addr(new_idle_inhibitor))
  session_lock_mgr = wlr_session_lock_manager_v1_create(dpy)
  wl_signal_add(addr(session_lock_mgr.events.new_lock), addr(new_session_lock))
  var lockcolor: array[4, cfloat] = [0.1'f32, 0.1'f32, 0.1'f32, 1.0'f32]
  locked_bg = wlr_scene_rect_create(layers[LyrBlock], sgeom.width, sgeom.height,
                                    lockcolor)
  wlr_scene_node_set_enabled(addr(locked_bg.node), false)
  foreign_toplevel_list = wlr_ext_foreign_toplevel_list_v1_create(dpy, 1)
  ext_foreign_toplevel_image_capture_source_manager_v1 = wlr_ext_foreign_toplevel_image_capture_source_manager_v1_create(
      dpy, 1)
  wl_signal_add(addr(ext_foreign_toplevel_image_capture_source_manager_v1.events.new_request),
                addr(new_foreign_toplevel_capture_request))
  wlr_server_decoration_manager_set_default_mode(
      wlr_server_decoration_manager_create(dpy),
      uint32(WLR_SERVER_DECORATION_MANAGER_MODE_SERVER))
  xdg_decoration_mgr = wlr_xdg_decoration_manager_v1_create(dpy)
  wl_signal_add(addr(xdg_decoration_mgr.events.new_toplevel_decoration),
                addr(new_xdg_decoration))
  pointer_constraints = wlr_pointer_constraints_v1_create(dpy)
  wl_signal_add(addr(pointer_constraints.events.new_constraint),
                addr(new_pointer_constraint))
  relative_pointer_mgr = wlr_relative_pointer_manager_v1_create(dpy)
  cursor = wlr_cursor_create()
  wlr_cursor_attach_output_layout(cursor, output_layout)
  cursor_mgr = wlr_xcursor_manager_create(nil, 24)
  discard setenv("XCURSOR_SIZE", "24", 1)
  wl_signal_add(addr(cursor.events.motion), addr(cursor_motion))
  wl_signal_add(addr(cursor.events.motion_absolute), addr(cursor_motion_absolute))
  wl_signal_add(addr(cursor.events.button), addr(cursor_button))
  wl_signal_add(addr(cursor.events.axis), addr(cursor_axis))
  wl_signal_add(addr(cursor.events.frame), addr(cursorFrameListener))
  cursor_shape_mgr = wlr_cursor_shape_manager_v1_create(dpy, 1)
  wl_signal_add(addr(cursor_shape_mgr.events.request_set_shape),
                addr(request_set_cursor_shape))
  wl_signal_add(addr(backend.events.new_input), addr(new_input_device))
  virtual_keyboard_mgr = wlr_virtual_keyboard_manager_v1_create(dpy)
  wl_signal_add(addr(virtual_keyboard_mgr.events.new_virtual_keyboard),
                addr(new_virtual_keyboard))
  virtual_pointer_mgr = wlr_virtual_pointer_manager_v1_create(dpy)
  wl_signal_add(addr(virtual_pointer_mgr.events.new_virtual_pointer),
                addr(new_virtual_pointer))
  seat = wlr_seat_create(dpy, "seat0")
  wl_signal_add(addr(seat.events.request_set_cursor), addr(request_cursor))
  wl_signal_add(addr(seat.events.request_set_selection), addr(request_set_sel))
  wl_signal_add(addr(seat.events.request_set_primary_selection),
                addr(request_set_psel))
  wl_signal_add(addr(seat.events.request_start_drag), addr(requestStartDragListener))
  wl_signal_add(addr(seat.events.start_drag), addr(startDragListener))
  kb_group = createkeyboardgroup()
  wl_list_init(addr(kb_group.destroy.link))
  output_mgr = wlr_output_manager_v1_create(dpy)
  wl_signal_add(addr(output_mgr.events.apply), addr(outputMgrApplyListener))
  wl_signal_add(addr(output_mgr.events.test), addr(outputMgrTestListener))
  input_method_manager = wlr_input_method_manager_v2_create(dpy)
  text_input_manager = wlr_text_input_manager_v3_create(dpy)
  input_method_relay = input_method_relay_create()
  createParkingOutput()
  discard unsetenv("DISPLAY")
  when defined(XWAYLAND):
    xwayland = wlr_xwayland_create(dpy, compositor, true)
    if xwayland != nil:
      wl_signal_add(addr(xwayland.events.ready), addr(xwaylandReadyListener))
      wl_signal_add(addr(xwayland.events.new_surface), addr(new_xwayland_surface))
      discard setenv("DISPLAY", xwayland.display_name, 1)
    else:
      discard fprintf(stderr, "failed to setup XWayland X server, continuing without it\n")

proc cloneSceneSubtree*(node: ptr wlr_scene_node; parent: ptr wlr_scene_tree; data: pointer): ptr wlr_scene_node {.
    cdecl.} =
  var
    child: ptr wlr_scene_node
    copy: ptr wlr_scene_node
  var tree: ptr wlr_scene_tree
  var rect: ptr wlr_scene_rect
  var
    src: ptr wlr_scene_buffer
    buffer: ptr wlr_scene_buffer
  if not node.enabled:
    return nil
  case node.type_field
  of WLR_SCENE_NODE_TREE:
    tree = wlr_scene_tree_create(parent)
    child = wl_list_first_link((addr(wlr_scene_tree_from_node(node).children)),
                             child)
    while wl_list_more_link(child, (addr(wlr_scene_tree_from_node(node).children))):
      discard cloneSceneSubtree(child, tree, data)
      child = wl_list_next_link(child)
    copy = addr(tree.node)
  of WLR_SCENE_NODE_RECT:
    rect = wlr_scene_rect_from_node(node)
    copy = addr(wlr_scene_rect_create(parent, rect.width, rect.height, rect.color).node)
  of WLR_SCENE_NODE_BUFFER:
    src = wlr_scene_buffer_from_node(node)
    buffer = wlr_scene_buffer_create(parent, nil)
    wlr_scene_buffer_set_dest_size(buffer, src.dst_width, src.dst_height)
    wlr_scene_buffer_set_opaque_region(buffer, addr(src.opaque_region))
    wlr_scene_buffer_set_opacity(buffer, src.opacity)
    wlr_scene_buffer_set_filter_mode(buffer, src.filter_mode)
    wlr_scene_buffer_set_transfer_function(buffer, src.transfer_function)
    wlr_scene_buffer_set_primaries(buffer, src.primaries)
    wlr_scene_buffer_set_color_encoding(buffer, src.color_encoding)
    wlr_scene_buffer_set_color_range(buffer, src.color_range)
    wlr_scene_buffer_set_source_box(buffer, addr(src.src_box))
    wlr_scene_buffer_set_transform(buffer, src.transform)
    wlr_scene_buffer_set_buffer(buffer, src.buffer)
    copy = addr(buffer.node)
  else:
    return nil
  copy.data = data
  wlr_scene_node_set_position(copy, node.x, node.y)
  if node.parent == parent:
    wlr_scene_node_place_above(copy, node)
  return copy

proc spawn*(arg: ptr Arg) {.cdecl.} =
  if fork() == 0:
    discard dup2(STDERR_FILENO, STDOUT_FILENO)
    discard setsid()
    discard execvp((cast[cstringArray](arg.v))[0], cast[cstringArray](arg.v))
    die("dwl: execvp %s failed:", (cast[cstringArray](arg.v))[0])

proc startdrag*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var drag: ptr wlr_drag = cast[ptr wlr_drag](data)
  wl_signal_add(addr(drag.events.destroy), addr(drag_destroy))
  if drag.icon != nil:
    drag.icon.data = addr(wlr_scene_drag_icon_create(drag_icon, drag.icon).node)

proc tag*(arg: ptr Arg) {.cdecl.} =
  var sel: ptr Client = focustop(selmon)
  if sel == nil or (arg.ui and TAGMASK) == 0 or sel.tags == (arg.ui and TAGMASK):
    return
  forgetOutputPlacement(sel)
  sel.tags = arg.ui and TAGMASK
  focusclient(focustop(selmon), nil, 1)
  arrange(selmon)
  publishCompositorState()

proc tagmon*(arg: ptr Arg) {.cdecl.} =
  var sel: ptr Client = focustop(selmon)
  if sel != nil:
    setmon(sel, dirtomon(cast[wlr_direction](arg.i)), 0)

proc togglefloating*(arg: ptr Arg) {.cdecl.} =
  var sel: ptr Client = focustop(selmon)
  if sel != nil and sel.isfullscreen == 0:
    setfloating(sel, cint(sel.isfloating == 0))

proc togglefullscreen*(arg: ptr Arg) {.cdecl.} =
  var sel: ptr Client = focustop(selmon)
  if sel != nil:
    setfullscreen(sel, cint(sel.isfullscreen == 0))

proc toggletag*(arg: ptr Arg) {.cdecl.} =
  var newtags: uint32
  var sel: ptr Client = focustop(selmon)
  if sel == nil:
    return
  newtags = sel.tags xor (arg.ui and TAGMASK)
  if newtags == 0 or newtags == sel.tags:
    return
  forgetOutputPlacement(sel)
  sel.tags = newtags
  focusclient(focustop(selmon), nil, 1)
  arrange(selmon)
  publishCompositorState()

proc toggleview*(arg: ptr Arg) {.cdecl.} =
  var newtagset: uint32
  if selmon == nil:
    return
  newtagset = selmon.tagset[selmon.seltags] xor (arg.ui and TAGMASK)
  if newtagset == 0:
    return
  selmon.tagset[selmon.seltags] = newtagset
  focusclient(focustop(selmon), nil, 1)
  arrange(selmon)
  publishCompositorState()

proc transactionapply*() {.cdecl.} =
  var ghost: ptr ptr wlr_scene_node
  var
    c: ptr Client
    p: ptr Client
  var m: ptr Monitor
  discard wl_event_source_timer_update(transaction_timer, 0)
  transaction_waiting = 0
  var layersChanged = false
  ghost = wl_array_first((addr(ghosts)), ghost)
  while wl_array_more(ghost, (addr(ghosts))):
    wlr_scene_node_destroy(ghost[])
    ghost = wl_array_next(ghost)
  ghosts.size = 0
  c = wl_list_first_link((addr(clients)), c)
  while wl_list_more_link(c, (addr(clients))):
    if c.resize_serial != 0:
      c.late_serial = c.resize_serial
    c.resize_serial = 0
    if c.mon == nil:
      c = wl_list_next_link(c)
      continue
    if c.mon == addr parkingMonitor:
      wlr_scene_node_set_enabled(addr c.scene.node, false)
    elif c.mon.wlr_output.enabled:
      let top = focustop(c.mon)
      let fullscreen = if c.isfullscreen != 0: c else: client_get_parent(c)
      wlr_scene_node_set_enabled(addr(c.scene.node), VISIBLEON(c, c.mon) and
        (fullscreen == nil or fullscreen.isfullscreen == 0 or top == fullscreen or
          (top != nil and client_get_parent(top) == fullscreen)))
    if c.scene.node.parent != clientSceneLayer(c): layersChanged = true
    applygeom(c)
    c = wl_list_next_link(c)
  # Reparenting appends nodes in client-list order, not focus order. Keep the
  # focused window above peers when layouts merge scene layers, but do not turn
  # ordinary geometry commits or sloppy focus (lift=0) into implicit raises.
  if layersChanged and focused_client != nil and focused_client.mon != nil:
    wlr_scene_node_raise_to_top(addr focused_client.scene.node)
  m = wl_list_first_link((addr(mons)), m)
  while wl_list_more_link(m, (addr(mons))):
    if m.wlr_output.enabled:
      c = focustop(m)
      var enabled = false
      if c != nil:
        p = client_get_parent(c)
        enabled = c.isfullscreen != 0 or (p != nil and p.isfullscreen != 0)
      wlr_scene_node_set_enabled(addr(m.fullscreen_bg.node), enabled)
    m = wl_list_next_link(m)
  motionnotify(0, nil, 0, 0, 0, 0)
  checkidleinhibitor(nil)
  markSwayDirty()

proc transactioncheck*(data: pointer) {.cdecl.} =
  var c: ptr Client
  transaction_idle = nil
  c = wl_list_first_link((addr(clients)), c)
  while wl_list_more_link(c, (addr(clients))):
    if c.resize_serial != 0 and VISIBLEON(c, c.mon) and c.mon.wlr_output.enabled:
      if transaction_waiting == 0:
        discard wl_event_source_timer_update(transaction_timer, TRANSACTION_TIMEOUT)
        transaction_waiting = 1
      return
    c = wl_list_next_link(c)
  transactionapply()

proc transactioncommit*(c: ptr Client; ready: cint) {.cdecl.} =
  if c.resize_serial != 0 and ready != 0:
    c.resize_serial = 0
    transactionschedule()
  elif c.snapshot != nil:
    client_send_frame_done(c)

proc transactionschedule*() {.cdecl.} =
  if transaction_idle == nil:
    transaction_idle = wl_event_loop_add_idle(event_loop, transactioncheck, nil)

proc transactiontimeout*(data: pointer): cint {.cdecl.} =
  transactionapply()
  return 0

proc unlocksession*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var lock: ptr SessionLock
  lock = wl_container_of(listener, lock, unlock)
  destroylock(lock, 1)

proc unmaplayersurfacenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var l: ptr LayerSurface
  l = wl_container_of(listener, l, unmap)
  var prev: ptr wl_list = l.link.prev
  l.mapped = 0
  wlr_scene_node_set_enabled(addr(l.scene.node), false)
  wl_list_remove(addr(l.link))
  if l.layer_surface.output != nil:
    l.mon = cast[ptr Monitor](l.layer_surface.output.data)
    if l.mon != nil:
      arrangelayers(l.mon)
  wl_list_insert(prev, addr(l.link))
  if l.layer_surface.surface == seat.keyboard_state.focused_surface:
    focusclient(focustop(selmon), nil, 1)
  motionnotify(0, nil, 0, 0, 0, 0)

proc unmapnotify*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, unmap)
  if cyclePreview == c: cyclePreview = nil
  var
    ghost: ptr wlr_scene_node
    slot: ptr ptr wlr_scene_node
  if c == grabc:
    cancelPointerInteraction()
  if c == focused_client:
    focused_client = nil
  if client_is_unmanaged(c) == 0:
    ghost = cloneSceneSubtree(addr(c.scene.node), c.scene.node.parent, nil)
    if ghost != nil:
      slot = cast[ptr ptr wlr_scene_node](wl_array_add(addr(ghosts),
          csize_t(sizeof(ptr wlr_scene_node))))
      if slot != nil:
        slot[] = ghost
      else:
        wlr_scene_node_destroy(ghost)
      transactionschedule()
    wl_list_remove(addr(c.link))
    setmon(c, nil, 0)
    wl_list_remove(addr(c.flink))
  elif client_wants_focus(c) != 0:
    focusclient(focustop(selmon), nil, 1)
  wlrForeignToplevelRemoveClient(c)
  if c.foreign_toplevel_handle != nil:
    wlr_ext_foreign_toplevel_handle_v1_destroy(c.foreign_toplevel_handle)
    c.foreign_toplevel_handle = nil
  if c.image_capture_scene != nil:
    if c.`type` != XDGShell and c.capture.image_capture_scene_surface != nil:
      wlr_scene_node_destroy(addr(c.capture.image_capture_scene_surface.buffer.node))
    wlr_scene_node_destroy(addr(c.image_capture_scene.tree.node))
    c.capture.image_capture_tree = nil # Shares storage with the X11 capture child.
    c.image_capture_scene = nil
    c.image_capture_source = nil
  wlr_scene_node_destroy(addr(c.scene.node))
  c.titlebar = nil
  c.titlebarDirty = true
  c.titlebarWidth = 0
  client_surface(c).data = nil
  c.snapshot = nil
  c.resize_serial = 0
  c.late_serial = 0
  c.current = wlr_box(x: 0, y: 0, width: 0, height: 0)
  c.zoneInitialized = false
  c.zoneName[0] = '\0'
  publishCompositorState()
  motionnotify(0, nil, 0, 0, 0, 0)

proc updatemons*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  if outputLayoutUpdates != 0 or shuttingDown: return
  inc outputLayoutUpdates
  defer: dec outputLayoutUpdates
  selmon = activeMonitor()
  var config: ptr wlr_output_configuration_v1 = wlr_output_configuration_v1_create()
  var c: ptr Client
  var
    l: ptr LayerSurface
    tmp: ptr LayerSurface
  var config_head: ptr wlr_output_configuration_head_v1
  var m: ptr Monitor
  var old: wlr_box
  var i: csize_t
  m = wl_list_first_link((addr(mons)), m)
  while wl_list_more_link(m, (addr(mons))):
    if m.wlr_output.enabled:
      m = wl_list_next_link(m)
      continue
    config_head = wlr_output_configuration_head_v1_create(config, m.wlr_output)
    config_head.state.enabled = false
    if m.asleep != 0 or wlr_output_layout_get(output_layout, m.wlr_output) == nil:
      m = wl_list_next_link(m)
      continue
    wlr_output_layout_remove(output_layout, m.wlr_output)
    i = 0
    while i < csize_t(LENGTH(m.layers)):
      l = wl_list_first_link((addr(m.layers[i])), l)
      tmp = wl_list_next_link(l)
      while wl_list_more_link(l, (addr(m.layers[i]))):
        wlr_layer_surface_v1_destroy(l.layer_surface)
        l = tmp
        tmp = wl_list_next_link(l)
      inc(i)
    m = wl_list_next_link(m)
  var addedOutput = false
  m = wl_list_first_link((addr(mons)), m)
  while wl_list_more_link(m, (addr(mons))):
    if m.wlr_output.enabled and
        wlr_output_layout_get(output_layout, m.wlr_output) == nil:
      discard wlr_output_layout_add_auto(output_layout, m.wlr_output)
      addedOutput = true
    m = wl_list_next_link(m)
  if addedOutput: positionConfiguredOutputs(activeConfig)
  wlr_output_layout_get_box(output_layout, nil, addr(sgeom))
  wlr_scene_node_set_position(addr(root_bg.node), sgeom.x, sgeom.y)
  wlr_scene_rect_set_size(root_bg, sgeom.width, sgeom.height)
  wlr_scene_node_set_position(addr(locked_bg.node), sgeom.x, sgeom.y)
  wlr_scene_rect_set_size(locked_bg, sgeom.width, sgeom.height)
  m = wl_list_first_link((addr(mons)), m)
  while wl_list_more_link(m, (addr(mons))):
    if not m.wlr_output.enabled:
      m = wl_list_next_link(m)
      continue
    config_head = wlr_output_configuration_head_v1_create(config, m.wlr_output)
    old = m.m
    wlr_output_layout_get_box(output_layout, m.wlr_output, addr(m.m))
    m.w = m.m
    wlr_scene_output_set_position(m.scene_output, m.m.x, m.m.y)
    wlr_scene_node_set_position(addr(m.fullscreen_bg.node), m.m.x, m.m.y)
    wlr_scene_rect_set_size(m.fullscreen_bg, m.m.width, m.m.height)
    if m.lock_surface != nil:
      var scene_tree: ptr wlr_scene_tree = cast[ptr wlr_scene_tree](m.lock_surface.surface.data)
      wlr_scene_node_set_position(addr(scene_tree.node), m.m.x, m.m.y)
      discard wlr_session_lock_surface_v1_configure_proc(m.lock_surface,
          uint32(m.m.width), uint32(m.m.height))
    arrangelayers(m)
    if not wlr_box_empty(addr old):
      let dx = m.m.x - old.x
      let dy = m.m.y - old.y
      c = wl_list_first_link(addr clients, c)
      while wl_list_more_link(c, addr clients):
        if c.mon == m:
          if c.isfullscreen != 0:
            c.prev = translated(c.prev, dx, dy)
            resize(c, m.m, 0)
          elif not c.ismaximized and (dx != 0 or dy != 0) and
              (client_places_manually(c) or m.lt[m.sellt].arrange == nil):
            resize(c, translated(c.geom, dx, dy), 0)
          if c.ismaximized:
            c.maximizeRestore = translated(c.maximizeRestore, dx, dy)
        c = wl_list_next_link(c)
    m.gamma_lut_changed = 1
    config_head.state.x = m.m.x
    config_head.state.y = m.m.y
    m = wl_list_next_link(m)
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if not m.wlr_output.enabled and not m.unavailable:
      closemon(m)
    m.unavailable = not m.wlr_output.enabled
    m = wl_list_next_link(m)
  restoreOutputClients(selmon)
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    arrange(m)
    m = wl_list_next_link(m)
  if selmon == addr parkingMonitor: arrange(selmon)
  focusclient(focustop(selmon), nil, 1)
  if selmon.lock_surface != nil:
    client_notify_enter(selmon.lock_surface.surface,
                        wlr_seat_get_keyboard(seat))
    client_activate_surface(selmon.lock_surface.surface, 1)
  wlr_cursor_move(cursor, nil, 0, 0)
  wlr_output_manager_v1_set_configuration(output_mgr, config)
  markSwayDirty()
  wlrForeignToplevelSyncAll()
  if pendingLock() != nil:
    m = wl_list_first_link(addr mons, m)
    while wl_list_more_link(m, addr mons):
      if not m.wlr_output.enabled:
        m.lockFrame = LockFrameNeeded
      elif m.lockFrame == LockFrameNeeded:
        wlr_output_schedule_frame(m.wlr_output)
      m = wl_list_next_link(m)
    acknowledgePresentedLock()

proc updatetitle*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var c: ptr Client
  c = wl_container_of(listener, c, set_title)
  if client_is_unmanaged(c) == 0 and client_surface(c) != nil and client_surface(c).mapped:
    let hadBar = client_wants_titlebar(c)
    c.hasTitle = client_has_title(c)
    applyTitlebarChange(c, hadBar)
  if c == focustop(c.mon):
    publishCompositorState()
  if c.foreign_toplevel_handle != nil:
    var foreign_toplevel_state = wlr_ext_foreign_toplevel_handle_v1_state(
      title: client_get_title(c), app_id: client_get_appid(c))
    wlr_ext_foreign_toplevel_handle_v1_update_state(c.foreign_toplevel_handle,
        addr(foreign_toplevel_state))
  markSwayDirty()
  wlrForeignToplevelSyncAll()
proc urgent*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_xdg_activation_v1_request_activate_event = cast[ptr wlr_xdg_activation_v1_request_activate_event](data)
  var c: ptr Client = nil
  discard toplevel_from_wlr_surface(event.surface, addr(c), nil)
  if c == nil or c == focustop(selmon):
    return
  c.isurgent = 1
  publishCompositorState()
  if client_surface(c).mapped:
    client_set_border_color(c, urgentcolor)

proc selectWorkspace(arg: ptr Arg; moved: ptr Client = nil) =
  if selmon == nil or (arg.ui and TAGMASK) == selmon.tagset[selmon.seltags]:
    return
  selmon.seltags = selmon.seltags xor 1
  if (arg.ui and TAGMASK) != 0:
    selmon.tagset[selmon.seltags] = arg.ui and TAGMASK
  focusclient(if moved != nil: moved else: focustop(selmon), nil, 1)
  arrange(selmon)
  publishCompositorState()

proc view*(arg: ptr Arg) {.cdecl.} =
  selectWorkspace(arg)

proc scrollWorkspace(step: int; moveWindow: bool) =
  let m = xytomon(cursor.x, cursor.y)
  if m == nil or m == addr parkingMonitor: return
  var target = relativeTagArgument(step, m)
  var c: ptr Client
  if moveWindow:
    xytonode(cursor.x, cursor.y, nil, addr c, nil, nil, nil)
    if c == nil or client_is_unmanaged(c) != 0 or not VISIBLEON(c, m): return
    if c.tags != target.ui:
      # Change the tags and view together, before arranging either workspace.
      forgetOutputPlacement(c)
      c.tags = target.ui
  selmon = m
  selectWorkspace(addr target, c)

proc virtualkeyboard*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var kb: ptr wlr_virtual_keyboard_v1 = cast[ptr wlr_virtual_keyboard_v1](data)
  var group: ptr KeyboardGroup = createkeyboardgroup()
  group.virtual_keyboard = addr(kb.keyboard)
  discard wlr_keyboard_set_keymap(addr(kb.keyboard), group.wlr_group.keyboard.keymap)
  LISTEN(addr(kb.keyboard.base.events.destroy), addr(group.destroy),
         destroykeyboardgroup)
  discard wlr_keyboard_group_add_keyboard(group.wlr_group, addr(kb.keyboard))
  wlr_seat_set_capabilities(seat,
      seat.capabilities or uint32(WL_SEAT_CAPABILITY_KEYBOARD))

proc virtualpointer*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var event: ptr wlr_virtual_pointer_v1_new_pointer_event = cast[ptr wlr_virtual_pointer_v1_new_pointer_event](data)
  var device: ptr wlr_input_device = addr(event.new_pointer.pointer.base)
  wlr_cursor_attach_input_device(cursor, device)
  device.data = event.suggested_output
  if device.data != nil:
    wlr_cursor_map_input_to_output(cursor, device, event.suggested_output)
  wlr_seat_set_capabilities(seat, seat.capabilities or
      uint32(WL_SEAT_CAPABILITY_POINTER))

proc xytomon*(x: cdouble; y: cdouble): ptr Monitor {.cdecl.} =
  let o = wlr_output_layout_output_at(output_layout, x, y)
  if o != nil and o.enabled: return cast[ptr Monitor](o.data)
  if selmon == addr parkingMonitor: return selmon

proc xytonode*(x: cdouble; y: cdouble; psurface: ptr ptr wlr_surface; pc: ptr ptr Client;
              pl: ptr ptr LayerSurface; nx: ptr cdouble; ny: ptr cdouble) {.cdecl.} =
  var node: ptr wlr_scene_node
  var scene_surface: ptr wlr_scene_surface
  var surface: ptr wlr_surface = nil
  var c: ptr Client = nil
  var layer: cint
  layer = NUM_LAYERS - 1
  while surface == nil and c == nil and layer >= (if locked != 0: LyrBlock else: 0):
    node = wlr_scene_node_at(addr(layers[layer].node), x, y, nx, ny)
    if layer == LyrIMPopup or node == nil:
      dec(layer)
      continue
    if node.type_field == WLR_SCENE_NODE_RECT:
      c = cast[ptr Client](node.data)
      dec(layer)
      continue
    if node.type_field != WLR_SCENE_NODE_BUFFER:
      dec(layer)
      continue
    scene_surface = wlr_scene_surface_try_from_buffer(
        wlr_scene_buffer_from_node(node))
    if scene_surface != nil:
      surface = scene_surface.surface
    else:
      c = cast[ptr Client](node.data)
    dec(layer)
  if psurface != nil:
    psurface[] = surface
  if pc != nil:
    pc[] = c
  discard toplevel_from_wlr_surface(surface, pc, pl)

when defined(XWAYLAND):
  proc activatex11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, activate)
    var surface: ptr wlr_surface = client_surface(c)
    if client_is_unmanaged(c) != 0:
      return
    if c == focustop(selmon):
      wlr_xwayland_surface_activate(c.surface.xwayland, true)
      return
    c.isurgent = 1
    publishCompositorState()
    if surface != nil and surface.mapped:
      client_set_border_color(c, urgentcolor)

  proc associatex11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, associate)
    LISTEN(addr(client_surface(c).events.commit), addr(c.commit), commitx11)
    LISTEN(addr(client_surface(c).events.map), addr(c.map), handleClientMap)
    LISTEN(addr(client_surface(c).events.unmap), addr(c.unmap), unmapnotify)

  proc commitx11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, commit)
    var surface: ptr wlr_surface = client_surface(c)
    transactioncommit(c, cint(surface.current.width ==
        c.geom.width - 2 * cint(c.bw) and
        surface.current.height == c.geom.height - client_frame_height(c)))

  proc configurex11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, configure)
    var event: ptr wlr_xwayland_surface_configure_event = cast[ptr wlr_xwayland_surface_configure_event](data)
    if client_surface(c) == nil or not client_surface(c).mapped or
        client_is_unmanaged(c) != 0 or c.mon == nil:
      wlr_xwayland_surface_configure(c.surface.xwayland, event.x, event.y,
                                     event.width, event.height)
      return
    if c.isfullscreen != 0:
      resize(c, c.mon.m, 0)
    elif (client_places_manually(c) and c != grabc) or
        c.mon.lt[c.mon.sellt].arrange == nil:
      resize(c, wlr_box(x: cint(event.x) - cint(c.bw), y: cint(event.y) - client_top_inset(c),
                       width: cint(event.width) + cint(c.bw) * 2,
                       height: cint(event.height) + client_frame_height(c)), 0)
    else:
      arrange(c.mon)

  proc createnotifyx11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var xsurface: ptr wlr_xwayland_surface = cast[ptr wlr_xwayland_surface](data)
    var c: ptr Client
    c = cast[ptr Client](ecalloc(1, csize_t(sizeof(Client))))
    xsurface.data = cast[pointer](c)
    c.surface.xwayland = xsurface
    c.`type` = X11
    c.bw = if client_is_unmanaged(c) != 0: 0 else: borderpx
    LISTEN(addr(xsurface.events.associate), addr(c.associate), associatex11)
    LISTEN(addr(xsurface.events.destroy), addr(c.destroy), destroynotify)
    LISTEN(addr(xsurface.events.dissociate), addr(c.dissociate), dissociatex11)
    LISTEN(addr(xsurface.events.request_activate), addr(c.activate), activatex11)
    LISTEN(addr(xsurface.events.request_configure), addr(c.configure), configurex11)
    LISTEN(addr(xsurface.events.request_fullscreen), addr(c.fullscreen),
           fullscreennotify)
    LISTEN(addr(xsurface.events.request_maximize), addr(c.maximize), maximizenotify)
    LISTEN(addr(xsurface.events.request_minimize), addr(c.minimize), minimizenotify)
    LISTEN(addr(xsurface.events.set_geometry), addr(c.set_geometry), setgeometryx11)
    LISTEN(addr(xsurface.events.set_hints), addr(c.set_hints), sethints)
    LISTEN(addr(xsurface.events.set_title), addr(c.set_title), updatetitle)

  proc dissociatex11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, dissociate)
    wl_list_remove(addr(c.commit.link))
    wl_list_remove(addr(c.map.link))
    wl_list_remove(addr(c.unmap.link))

  proc setgeometryx11*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, set_geometry)
    if client_is_unmanaged(c) == 0 or client_surface(c) == nil or
        not client_surface(c).mapped:
      return
    client_get_geometry(c, addr(c.geom))
    wlr_scene_node_set_position(addr(c.scene.node), c.geom.x, c.geom.y)

  proc sethints*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var c: ptr Client
    c = wl_container_of(listener, c, set_hints)
    var surface: ptr wlr_surface = client_surface(c)
    if c == focustop(selmon) or client_is_unmanaged(c) != 0 or
        c.surface.xwayland.hints == nil:
      return
    c.isurgent = cint(xcb_icccm_wm_hints_get_urgency(c.surface.xwayland.hints))
    publishCompositorState()
    if c.isurgent != 0 and surface != nil and surface.mapped:
      client_set_border_color(c, urgentcolor)

  proc xwaylandready*(listener: ptr wl_listener; data: pointer) {.cdecl.} =
    var xcursor: ptr wlr_xcursor
    wlr_xwayland_set_seat(xwayland, seat)
    xcursor = wlr_xcursor_manager_get_xcursor(cursor_mgr, "default", 1)
    if xcursor != nil:
      wlr_xwayland_set_cursor(xwayland,
                              wlr_xcursor_image_get_buffer(xcursor.images[]),
                              int32(xcursor.images[].hotspot_x),
                              int32(xcursor.images[].hotspot_y))
proc main*(argc: cint; argv: ptr cstring): cint {.cdecl.} =
  var startup_cmd: cstring = nil
  var c: cint
  var requestedConfig: string
  var validateConfig = false
  while true:
    c = getopt(argc, argv, "s:c:Chdv")
    if c == -1:
      break
    if c == cint(ord('s')):
      startup_cmd = optarg
    elif c == cint(ord('c')):
      requestedConfig = $optarg
    elif c == cint(ord('C')):
      validateConfig = true
    elif c == cint(ord('d')):
      log_level = WLR_DEBUG
    elif c == cint(ord('v')):
      die("nimzo " & VERSION)
    else:
      die("Usage: %s [-v] [-d] [-c config] [-C] [-s startup command]", argv[0])
  if optind < argc:
    die("Usage: %s [-v] [-d] [-c config] [-C] [-s startup command]", argv[0])
  try:
    loadInitialConfig(requestedConfig, validateConfig)
  except CatchableError as error:
    discard fprintf(stderr, "nimzo: %s\n", error.msg.cstring)
    return cint(QuitFailure)
  if validateConfig:
    discard printf("Configuration valid: %s\n", configPath.cstring)
    return EXIT_SUCCESS
  if c_getenv("XDG_RUNTIME_DIR") == nil:
    die("XDG_RUNTIME_DIR must be set")
  setup()
  run(startup_cmd)
  cleanup()
  return EXIT_SUCCESS
