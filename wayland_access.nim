# Restrict privileged Wayland globals to connections created by Nimzo.

type WaylandGrant = object
  destroy: wl_listener
  capabilities: set[WaylandCapability]

proc releaseWaylandGrant(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  var grant: ptr WaylandGrant
  grant = wl_container_of(listener, grant, destroy)
  wl_list_remove(addr listener.link)
  free(grant)

proc filterWaylandGlobal(client: ptr wl_client; global: ptr wl_global;
    data: pointer): bool {.cdecl.} =
  let name = wl_global_get_interface(global).name
  template named(s: string): bool = strcmp(name, cstring(s)) == 0
  let required =
    if named("zwlr_export_dmabuf_manager_v1") or named("zwlr_screencopy_manager_v1") or
        named("ext_image_copy_capture_manager_v1") or named("ext_output_image_capture_source_manager_v1") or
        named("ext_foreign_toplevel_image_capture_source_manager_v1"): capCapture
    elif named("zwlr_data_control_manager_v1") or named("ext_data_control_manager_v1"): capClipboard
    elif named("zwp_virtual_keyboard_manager_v1") or named("zwlr_virtual_pointer_manager_v1"): capVirtualInput
    elif named("zwp_input_method_manager_v2"): capInputMethod
    elif named("ext_session_lock_manager_v1"): capSessionLock
    elif named("zwlr_foreign_toplevel_manager_v1") or named("ext_foreign_toplevel_list_v1"): capToplevel
    elif named("zwlr_output_manager_v1") or named("zwlr_output_power_manager_v1") or
        named("zwlr_gamma_control_manager_v1"): capOutputControl
    else: return true
  let listener = wl_client_get_destroy_late_listener(client, releaseWaylandGrant)
  if listener == nil: return false
  var grant: ptr WaylandGrant
  grant = wl_container_of(listener, grant, destroy)
  required in grant.capabilities

proc launchWaylandClient(profile: WaylandClientProfile) =
  var fds: array[2, cint]
  if waylandSocketPair(fds) != 0:
    raise newException(ValueError, "launch " & profile.name & ": " & osErrorMsg(osLastError()))
  defer: discard close(fds[1])
  let client = wl_client_create(dpy, fds[0])
  if client == nil:
    let error = osLastError()
    discard close(fds[0])
    raise newException(ValueError, "launch " & profile.name & ": " & osErrorMsg(error))

  let grant = cast[ptr WaylandGrant](ecalloc(1, csize_t(sizeof(WaylandGrant))))
  grant.capabilities = profile.capabilities
  grant.destroy.notify = releaseWaylandGrant
  wl_client_add_destroy_late_listener(client, addr grant.destroy)

  let status = spawnWaylandProcess(profile.argv, fds[1])
  if status != 0:
    wl_client_destroy(client)
    raise newException(ValueError, "launch " & profile.name & ": " & osErrorMsg(OSErrorCode(status)))
