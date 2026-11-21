## Publish window and output state to clients and handle their window requests
## through the wlr foreign-toplevel management protocol.
##
## The C bridge owns the protocol resources. This file
## deliberately keeps only compositor pointers here; no managed Nim object is
## stored in a Client or Monitor.
{.compile: currentSourcePath.parentDir / "wlr_foreign_toplevel_management.c".}
{.compile: currentSourcePath.parentDir / "wlr-foreign-toplevel-management-unstable-v1-protocol.c".}

type ToplevelRequestProc = proc(view: pointer; request: cint; seat, output: pointer) {.cdecl.}
proc wlrForeignToplevelRequest(view: pointer; request: cint; seat, output: pointer) {.cdecl.}

proc nimzo_wlr_toplevel_init(display: ptr wl_display; request: ToplevelRequestProc) {.importc,
    header: "wlr_foreign_toplevel_management.h".}
proc nimzo_wlr_toplevel_finish() {.importc, header: "wlr_foreign_toplevel_management.h".}
proc nimzo_wlr_toplevel_output_add(output: ptr wlr_output) {.importc,
    header: "wlr_foreign_toplevel_management.h".}
proc nimzo_wlr_toplevel_sync(view: pointer; title, appid: cstring; output: pointer;
    visible, activated, maximized, minimized, fullscreen: cint) {.importc,
    header: "wlr_foreign_toplevel_management.h".}
proc nimzo_wlr_toplevel_remove_view(view: pointer) {.importc,
    header: "wlr_foreign_toplevel_management.h".}

var wlrForeignToplevelStarted = false
{.push header: "wlr_foreign_toplevel_management.h".}
let
  ToplevelActivate {.importc: "NIMZO_WLR_TOPLEVEL_ACTIVATE".}: cint
  ToplevelClose {.importc: "NIMZO_WLR_TOPLEVEL_CLOSE".}: cint
  ToplevelSetMaximized {.importc: "NIMZO_WLR_TOPLEVEL_SET_MAXIMIZED".}: cint
  ToplevelUnsetMaximized {.importc: "NIMZO_WLR_TOPLEVEL_UNSET_MAXIMIZED".}: cint
  ToplevelSetMinimized {.importc: "NIMZO_WLR_TOPLEVEL_SET_MINIMIZED".}: cint
  ToplevelUnsetMinimized {.importc: "NIMZO_WLR_TOPLEVEL_UNSET_MINIMIZED".}: cint
  ToplevelSetFullscreen {.importc: "NIMZO_WLR_TOPLEVEL_SET_FULLSCREEN".}: cint
  ToplevelUnsetFullscreen {.importc: "NIMZO_WLR_TOPLEVEL_UNSET_FULLSCREEN".}: cint
{.pop.}

proc wlrForeignToplevelInit*() {.cdecl.} =
  if dpy != nil:
    nimzo_wlr_toplevel_init(dpy, wlrForeignToplevelRequest)
    wlrForeignToplevelStarted = true

proc wlrForeignToplevelFinish*() {.cdecl.} =
  if wlrForeignToplevelStarted:
    nimzo_wlr_toplevel_finish()
    wlrForeignToplevelStarted = false

proc wlrForeignToplevelOutputAdd*(output: ptr wlr_output) {.cdecl.} =
  if wlrForeignToplevelStarted:
    nimzo_wlr_toplevel_output_add(output)

proc wlrForeignToplevelSyncClient(c: ptr Client) {.cdecl.} =
  if c == nil or c.mon == nil or client_surface(c) == nil or
      not client_surface(c).mapped:
    return
  # Minimized clients remain on their taskbar so activation can restore them.
  let visible = cint(c.mon != addr(parkingMonitor) and c.mon.wlr_output.enabled and
    onSelectedTags(c, c.mon))
  nimzo_wlr_toplevel_sync(cast[pointer](c), client_get_title(c), client_get_appid(c),
      cast[pointer](c.mon.wlr_output), visible,
      cint(focused_client == c), cint(c.ismaximized), cint(c.isminimized), c.isfullscreen)

proc wlrForeignToplevelSyncAll*() {.cdecl.} =
  if not wlrForeignToplevelStarted:
    return
  var c: ptr Client
  c = wl_list_first_link((addr(clients)), c)
  while wl_list_more_link(c, (addr(clients))):
    wlrForeignToplevelSyncClient(c)
    c = wl_list_next_link(c)

proc wlrForeignToplevelRemoveClient*(c: ptr Client) {.cdecl.} =
  if wlrForeignToplevelStarted and c != nil:
    nimzo_wlr_toplevel_remove_view(cast[pointer](c))

proc wlrForeignToplevelRequest(view: pointer; request: cint; seat, output: pointer) {.cdecl.} =
  ## Protocol clients are untrusted. Reject requests while a session lock
  ## owns the seat. Check target pointers against compositor data.
  if locked != 0 or view == nil:
    return
  let c = cast[ptr Client](view)
  if c.mon == nil or client_surface(c) == nil or not client_surface(c).mapped:
    return
  if request == ToplevelActivate:
    if c.mon == addr parkingMonitor: return
    setWindowMinimized(c, false)
    if not VISIBLEON(c, c.mon):
      c.mon.tagset[c.mon.seltags] = c.tags
      arrange(c.mon)
    selmon = c.mon
    focusclient(c, nil, 1)
  elif request == ToplevelClose:
    client_send_close(c)
  elif request == ToplevelSetMaximized or request == ToplevelUnsetMaximized:
    setWindowMaximized(c, request == ToplevelSetMaximized)
  elif request == ToplevelSetFullscreen or request == ToplevelUnsetFullscreen:
    if request == ToplevelSetFullscreen and output != nil:
      let target = cast[ptr wlr_output](output)
      if target.enabled and target.data != nil and cast[ptr Monitor](target.data) != c.mon:
        setmon(c, cast[ptr Monitor](target.data), c.tags)
    if request == ToplevelSetFullscreen and not VISIBLEON(c, c.mon):
      c.mon.tagset[c.mon.seltags] = c.tags
      selmon = c.mon
      arrange(c.mon)
    setfullscreen(c, cint(request == ToplevelSetFullscreen))
  elif request == ToplevelSetMinimized or request == ToplevelUnsetMinimized:
    setWindowMinimized(c, request == ToplevelSetMinimized)
  wlrForeignToplevelSyncAll()
