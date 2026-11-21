# Declare shared compositor state and register callback pointers for Wayland
# listeners. Forward declarations keep callbacks in config_defaults.nim type-safe.

proc applybounds*(c: ptr Client; bbox: ptr wlr_box) {.cdecl.}
proc applygeom*(c: ptr Client) {.cdecl.}
proc applyrules*(c: ptr Client) {.cdecl.}
proc arrange*(m: ptr Monitor) {.cdecl.}
proc arrangelayer*(m: ptr Monitor; list: ptr wl_list; usable_area: ptr wlr_box; exclusive: cint) {.cdecl.}
proc arrangelayers*(m: ptr Monitor) {.cdecl.}
proc axisnotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc buttonpress*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc handleForeignToplevelCaptureRequest*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc chvt*(arg: ptr Arg) {.cdecl.}
proc checkidleinhibitor*(exclude: ptr wlr_surface) {.cdecl.}
proc cleanup*() {.cdecl.}
proc cleanupmon*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc cleanuplisteners*() {.cdecl.}
proc closemon*(m: ptr Monitor) {.cdecl.}
proc commitlayersurfacenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc commitlocksurface*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc handleXdgSurfaceCommit*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc commitpopup*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createdecoration*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createidleinhibitor*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createkeyboard*(keyboard: ptr wlr_keyboard) {.cdecl.}
proc createkeyboardgroup*(): ptr KeyboardGroup {.cdecl.}
proc createlayersurface*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createlocksurface*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createmon*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc handleNewXdgToplevel*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createpointer*(pointer: ptr wlr_pointer) {.cdecl.}
proc createpointerconstraint*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc createpopup*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc cursorconstrain*(constraint: ptr wlr_pointer_constraint_v1) {.cdecl.}
proc cursorframe*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc cursorwarptohint*() {.cdecl.}
proc destroybackend*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroydecoration*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroydrag*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroyidleinhibitor*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroylayersurfacenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroylock*(lock: ptr SessionLock; unlocked: cint) {.cdecl.}
proc destroylocksurface*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroynotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroypointerconstraint*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroypopup*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroysessionlock*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc destroykeyboardgroup*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc dirtomon*(dir: wlr_direction): ptr Monitor {.cdecl.}
proc focusclient*(c: ptr Client; l: ptr LayerSurface; lift: cint) {.cdecl.}
proc focusmon*(arg: ptr Arg) {.cdecl.}
proc focusstack*(arg: ptr Arg) {.cdecl.}
proc focustop*(m: ptr Monitor): ptr Client {.cdecl.}
proc fullscreennotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc gpureset*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc handlesig*(signo: cint) {.cdecl.}
proc inputdevice*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc keybinding*(mods: uint32; sym: xkb_keysym_t): ptr Key {.cdecl.}
proc keypress*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc keypressmod*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc keyrepeat*(data: pointer): cint {.cdecl.}
proc requestCloseFocusedWindow*(arg: ptr Arg) {.cdecl.}
proc locksession*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc handleClientMap*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc maximizenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc monocle*(m: ptr Monitor) {.cdecl.}
proc motionabsolute*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc findDisabledOutputEntry*(wlr_output: ptr wlr_output): cstringArray {.cdecl.}
proc motionnotify*(time: uint32; device: ptr wlr_input_device; dx, dy, dx_unaccel, dy_unaccel: cdouble) {.cdecl.}
proc motionrelative*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc moveresize*(arg: ptr Arg) {.cdecl.}
proc outputmgrapply*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc outputmgrapplyortest*(config: ptr wlr_output_configuration_v1; test: cint) {.cdecl.}
proc outputmgrtest*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc pointerfocus*(c: ptr Client; l: ptr LayerSurface; surface: ptr wlr_surface; sx, sy: cdouble; time: uint32) {.cdecl.}
proc publishCompositorState*() {.cdecl.}
proc powermgrsetmode*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc quit*(arg: ptr Arg) {.cdecl.}
proc refocuspointer*(data: pointer) {.cdecl.}
proc rendermon*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc requestdecorationmode*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc requeststartdrag*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc requestmonstate*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc resize*(c: ptr Client; geo: wlr_box; interact: cint) {.cdecl.}
proc run*(startup_cmd: cstring) {.cdecl.}
proc setcursor*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc setcursorshape*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc setfloating*(c: ptr Client; floating: cint) {.cdecl.}
proc setfullscreen*(c: ptr Client; fullscreen: cint) {.cdecl.}
proc setBorderWindow(arg: ptr Arg) {.cdecl.}
proc setAlwaysOnTopWindow(arg: ptr Arg) {.cdecl.}
proc setTitlebarWindow(arg: ptr Arg) {.cdecl.}
proc setlayout*(arg: ptr Arg) {.cdecl.}
proc setmon*(c: ptr Client; m: ptr Monitor; newtags: uint32) {.cdecl.}
proc setOutputDisabledRecord*(wlr_output: ptr wlr_output; off: cint) {.cdecl.}
proc setpsel*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc setsel*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc setup*() {.cdecl.}
proc cloneSceneSubtree*(node: ptr wlr_scene_node; parent: ptr wlr_scene_tree; data: pointer): ptr wlr_scene_node {.cdecl.}
proc spawn*(arg: ptr Arg) {.cdecl.}
proc startdrag*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc tag*(arg: ptr Arg) {.cdecl.}
proc tagmon*(arg: ptr Arg) {.cdecl.}
proc togglefloating*(arg: ptr Arg) {.cdecl.}
proc togglefullscreen*(arg: ptr Arg) {.cdecl.}
proc toggletag*(arg: ptr Arg) {.cdecl.}
proc toggleview*(arg: ptr Arg) {.cdecl.}
proc transactionapply*() {.cdecl.}
proc transactioncheck*(data: pointer) {.cdecl.}
proc transactioncommit*(c: ptr Client; ready: cint) {.cdecl.}
proc transactionschedule*() {.cdecl.}
proc transactiontimeout*(data: pointer): cint {.cdecl.}
proc unlocksession*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc unmaplayersurfacenotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc unmapnotify*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc updatemons*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc updatetitle*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc urgent*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc view*(arg: ptr Arg) {.cdecl.}
proc virtualkeyboard*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc virtualpointer*(listener: ptr wl_listener; data: pointer) {.cdecl.}
proc xytomon*(x, y: cdouble): ptr Monitor {.cdecl.}
proc xytonode*(x, y: cdouble; psurface: ptr ptr wlr_surface; pc: ptr ptr Client; pl: ptr ptr LayerSurface; nx, ny: ptr cdouble) {.cdecl.}
proc zonelayout*(m: ptr Monitor) {.cdecl.}
when defined(XWAYLAND):
  proc activatex11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc associatex11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc commitx11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc configurex11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc createnotifyx11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc dissociatex11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc setgeometryx11*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc sethints*(listener: ptr wl_listener; data: pointer) {.cdecl.}
  proc xwaylandready*(listener: ptr wl_listener; data: pointer) {.cdecl.}

proc forgetOutputPlacement(c: ptr Client) {.inline.}

var
  child_pid*: pid_t = -1
  locked*: cint = 0
  focused_client*: ptr Client
  cyclePreview: ptr Client
  cycleModifiers: uint32
  dpy*: ptr wl_display
  event_loop*: ptr wl_event_loop
  backend*: ptr wlr_backend
  scene*: ptr wlr_scene
  layers*: array[NUM_LAYERS, ptr wlr_scene_tree]
  drag_icon*: ptr wlr_scene_tree
  drw*: ptr wlr_renderer
  alloc*: ptr wlr_allocator
  compositor*: ptr wlr_compositor
  session*: ptr wlr_session
  xdg_shell*: ptr wlr_xdg_shell
  activation*: ptr wlr_xdg_activation_v1
  xdg_decoration_mgr*: ptr wlr_xdg_decoration_manager_v1
  clients*: wl_list
  fstack*: wl_list
  outputLayoutUpdates: int
  idle_notifier*: ptr wlr_idle_notifier_v1
  idle_inhibit_mgr*: ptr wlr_idle_inhibit_manager_v1
  layer_shell*: ptr wlr_layer_shell_v1
  output_mgr*: ptr wlr_output_manager_v1
  virtual_keyboard_mgr*: ptr wlr_virtual_keyboard_manager_v1
  virtual_pointer_mgr*: ptr wlr_virtual_pointer_manager_v1
  cursor_shape_mgr*: ptr wlr_cursor_shape_manager_v1
  power_mgr*: ptr wlr_output_power_manager_v1
  foreign_toplevel_list*: ptr wlr_ext_foreign_toplevel_list_v1
  ext_foreign_toplevel_image_capture_source_manager_v1*: ptr wlr_ext_foreign_toplevel_image_capture_source_manager_v1
  pointer_constraints*: ptr wlr_pointer_constraints_v1
  relative_pointer_mgr*: ptr wlr_relative_pointer_manager_v1
  active_constraint*: ptr wlr_pointer_constraint_v1
  cursor*: ptr wlr_cursor
  cursor_mgr*: ptr wlr_xcursor_manager
  root_bg*: ptr wlr_scene_rect
  session_lock_mgr*: ptr wlr_session_lock_manager_v1
  locked_bg*: ptr wlr_scene_rect
  cur_lock*: ptr wlr_session_lock_v1
  seat*: ptr wlr_seat
  kb_group*: ptr KeyboardGroup
  cursor_mode*: cuint = CurNormal
  grabc*: ptr Client
  grabcx*, grabcy*: cint
  output_layout*: ptr wlr_output_layout
  sgeom*: wlr_box
  mons*: wl_list
  selmon*: ptr Monitor
  parkingMonitor: Monitor
  consumed*: array[KEY_MAX + 1, cint]
  transaction_idle*: ptr wl_event_source
  transaction_timer*: ptr wl_event_source
  transaction_waiting*: cint
  ghosts*: wl_array
  offmons*: wl_array

let layermap*: array[4, int] = [LyrBg, LyrBottom, LyrTop, LyrOverlay]
const TRANSACTION_TIMEOUT* = 100

var
  backend_destroy*: wl_listener = wl_listener(notify: destroybackend)
  cursor_axis*: wl_listener = wl_listener(notify: axisnotify)
  cursor_button*: wl_listener = wl_listener(notify: buttonpress)
  cursorFrameListener*: wl_listener = wl_listener(notify: cursorframe)
  cursor_motion*: wl_listener = wl_listener(notify: motionrelative)
  cursor_motion_absolute*: wl_listener = wl_listener(notify: motionabsolute)
  gpuResetListener*: wl_listener = wl_listener(notify: gpureset)
  layout_change*: wl_listener = wl_listener(notify: updatemons)
  new_idle_inhibitor*: wl_listener = wl_listener(notify: createidleinhibitor)
  new_input_device*: wl_listener = wl_listener(notify: inputdevice)
  new_virtual_keyboard*: wl_listener = wl_listener(notify: virtualkeyboard)
  new_virtual_pointer*: wl_listener = wl_listener(notify: virtualpointer)
  new_pointer_constraint*: wl_listener = wl_listener(notify: createpointerconstraint)
  new_output*: wl_listener = wl_listener(notify: createmon)
  new_xdg_toplevel*: wl_listener = wl_listener(notify: handleNewXdgToplevel)
  new_xdg_popup*: wl_listener = wl_listener(notify: createpopup)
  new_xdg_decoration*: wl_listener = wl_listener(notify: createdecoration)
  new_layer_surface*: wl_listener = wl_listener(notify: createlayersurface)
  outputMgrApplyListener*: wl_listener = wl_listener(notify: outputmgrapply)
  outputMgrTestListener*: wl_listener = wl_listener(notify: outputmgrtest)
  output_power_mgr_set_mode*: wl_listener = wl_listener(notify: powermgrsetmode)
  request_activate*: wl_listener = wl_listener(notify: urgent)
  request_cursor*: wl_listener = wl_listener(notify: setcursor)
  request_set_psel*: wl_listener = wl_listener(notify: setpsel)
  request_set_sel*: wl_listener = wl_listener(notify: setsel)
  request_set_cursor_shape*: wl_listener = wl_listener(notify: setcursorshape)
  requestStartDragListener*: wl_listener = wl_listener(notify: requeststartdrag)
  startDragListener*: wl_listener = wl_listener(notify: startdrag)
  drag_destroy*: wl_listener = wl_listener(notify: destroydrag)
  new_session_lock*: wl_listener = wl_listener(notify: locksession)
  new_foreign_toplevel_capture_request*: wl_listener = wl_listener(notify: handleForeignToplevelCaptureRequest)
when defined(XWAYLAND):
  var
    new_xwayland_surface*: wl_listener = wl_listener(notify: createnotifyx11)
    xwaylandReadyListener*: wl_listener = wl_listener(notify: xwaylandready)
    xwayland*: ptr wlr_xwayland
