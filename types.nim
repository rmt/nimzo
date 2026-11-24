# Define shared compositor records for clients, outputs, surfaces, session
# locks, and input, layout, and rule callbacks.

type
  LockFrameState = enum
    LockFrameNeeded, LockFrameSubmitted, LockFramePresented

  Monitor* = object
    link*: wl_list
    wlr_output*: ptr wlr_output
    scene_output*: ptr wlr_scene_output
    fullscreen_bg*: ptr wlr_scene_rect
    frame*: wl_listener
    present: wl_listener
    lockFrame: LockFrameState
    lockCommitSeq: uint32
    destroy*: wl_listener
    request_state*: wl_listener
    commit_lock_surface*: wl_listener
    destroy_lock_surface*: wl_listener
    lock_surface*: ptr wlr_session_lock_surface_v1
    m*: wlr_box
    w*: wlr_box
    layers*: array[4, wl_list]
    lt*: array[2, ptr Layout]
    seltags*: cuint
    sellt*: cuint
    tagset*: array[2, uint32]
    gamma_lut_changed*: cint
    ltsymbol*: array[16, char]
    asleep*: cint
    ipcId*: int64
    unavailable: bool

  INNER_C_UNION_dwl_2* {.bycopy, union.} = object
    xdg*: ptr wlr_xdg_surface
    xwayland*: ptr wlr_xwayland_surface

  INNER_C_UNION_dwl_3* {.bycopy, union.} = object
    image_capture_tree*: ptr wlr_scene_tree
    image_capture_scene_surface*: ptr wlr_scene_surface

  Arg* {.bycopy, union.} = object
    i*: cint
    ui*: uint32
    f*: cfloat
    v*: pointer

  Axis* {.bycopy.} = object
    `mod`*: cuint
    dir*: cuint
    `func`*: proc (a1: ptr Arg) {.cdecl.}
    arg*: Arg

  Button* {.bycopy.} = object
    `mod`*: cuint
    button*: cuint
    `func`*: proc (a1: ptr Arg) {.cdecl.}
    arg*: Arg

  OutputPlacement = object
    output: cstring
    tags: uint32
    normalGeometry: wlr_box
    zoneName: array[64, char]
    zoneInitialized: bool

  Client* {.bycopy.} = object
    `type`*: cuint
    mon*: ptr Monitor
    scene*: ptr wlr_scene_tree
    border*: array[4, ptr wlr_scene_rect]
    scene_surface*: ptr wlr_scene_tree
    xdgPopups: ptr wlr_scene_tree
    link*: wl_list
    flink*: wl_list
    geom*: wlr_box
    prev*: wlr_box
    current*: wlr_box
    snapshot*: ptr wlr_scene_node
    resize_serial*: uint32
    late_serial*: uint32
    bounds*: wlr_box
    surface*: INNER_C_UNION_dwl_2
    decoration*: ptr wlr_xdg_toplevel_decoration_v1
    foreign_toplevel_handle*: ptr wlr_ext_foreign_toplevel_handle_v1
    image_capture_scene*: ptr wlr_scene
    image_capture_source*: ptr wlr_ext_image_capture_source_v1
    capture*: INNER_C_UNION_dwl_3
    commit*: wl_listener
    map*: wl_listener
    maximize*: wl_listener
    minimize*: wl_listener
    unmap*: wl_listener
    destroy*: wl_listener
    set_title*: wl_listener
    fullscreen*: wl_listener
    set_decoration_mode*: wl_listener
    destroy_decoration*: wl_listener
    when defined(XWAYLAND):
      activate*: wl_listener
      associate*: wl_listener
      dissociate*: wl_listener
      configure*: wl_listener
      set_geometry*: wl_listener
      set_hints*: wl_listener
    bw*: cuint
    tags*: uint32
    isfloating*: cint
    isurgent*: cint
    isfullscreen*: cint
    isminimized*, ismaximized*: bool
    maximizeRestore*: wlr_box
    zoneName*: array[64, char]
    zoneInitialized*: bool
    alwaysOnTop: bool
    isfixed*: cint
    ipcId*: int64
    hideBorder: bool
    showTitlebar*: bool
    titlebarInitialized*: bool
    hasTitle: bool
    titlebar*: ptr wlr_scene_buffer
    titlebarDirty*: bool
    titlebarWidth*: cint
    titlebarScale*: cfloat
    titlebarStyle*: cint
    titlebarGeneration*: uint64
    titlebarStackWidth: cint
    stackBadge: ptr wlr_scene_buffer
    stackBadgeCount: int
    stackBadgeGeneration: uint64
    stackBadgeScale: cfloat
    stackBadgeWidth: cint
    hiddenBy: ptr Client
    hiddenCount: int
    outputPlacement: OutputPlacement

  Key* {.bycopy.} = object
    `mod`*: uint32
    keysym*: xkb_keysym_t
    `func`*: proc (a1: ptr Arg) {.cdecl.}
    arg*: Arg

  KeyboardGroup* {.bycopy.} = object
    wlr_group*: ptr wlr_keyboard_group
    virtual_keyboard*: ptr wlr_keyboard
    keysyms*: array[2, xkb_keysym_t]
    mods*: uint32
    key_repeat_source*: ptr wl_event_source
    modifiers*: wl_listener
    key*: wl_listener
    destroy*: wl_listener

  LayerSurface* {.bycopy.} = object
    `type`*: cuint
    mon*: ptr Monitor
    scene*: ptr wlr_scene_tree
    popups*: ptr wlr_scene_tree
    scene_layer*: ptr wlr_scene_layer_surface_v1
    link*: wl_list
    mapped*: cint
    layer_surface*: ptr wlr_layer_surface_v1
    destroy*: wl_listener
    unmap*: wl_listener
    surface_commit*: wl_listener

  Layout* {.bycopy.} = object
    symbol*: cstring
    arrange*: proc (a1: ptr Monitor) {.cdecl.}

  MonitorRule* {.bycopy.} = object
    name*: cstring
    scale*: cfloat
    lt*: ptr Layout
    rr*: wl_output_transform
    x*: cint
    y*: cint

  PointerConstraint* {.bycopy.} = object
    constraint*: ptr wlr_pointer_constraint_v1
    destroy*: wl_listener

  Popup* {.bycopy.} = object
    commit*: wl_listener
    destroy*: wl_listener

  Rule* {.bycopy.} = object
    id*: cstring
    title*: cstring
    tags*: uint32
    isfloating*: cint
    monitor*: cint

  SessionLock* {.bycopy.} = object
    scene*: ptr wlr_scene_tree
    lock*: ptr wlr_session_lock_v1
    acknowledged: bool
    new_surface*: wl_listener
    unlock*: wl_listener
    destroy*: wl_listener
