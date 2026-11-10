# SPDX-FileCopyrightText: © 2026 Isaac Freund
# SPDX-License-Identifier: 0BSD

import std/[algorithm, exitprocs, json, os, posix, strutils, tempfiles]
import config, commands, output_manager, layer_shell, work_area, sway_ipc

{.passC: "-Iprotocol " & staticExec("pkg-config --cflags wayland-client pangocairo").strip.}
{.passL: staticExec("pkg-config --libs wayland-client pangocairo").strip.}
{.compile: "protocol/river-window-management-v1-protocol.c".}
{.compile: "protocol/river-xkb-bindings-v1-protocol.c".}

type
  CairoSurface {.importc: "cairo_surface_t", header: "cairo.h", incompleteStruct.} = object
  CairoContext {.importc: "cairo_t", header: "cairo.h", incompleteStruct.} = object
  PangoLayout {.importc: "PangoLayout", header: "pango/pangocairo.h", incompleteStruct.} = object
  PangoFontDescription {.importc: "PangoFontDescription", header: "pango/pangocairo.h", incompleteStruct.} = object

  WlDisplay {.importc: "struct wl_display", header: "wayland-client.h", incompleteStruct.} = object
  WlRegistry {.importc: "struct wl_registry", header: "wayland-client.h", incompleteStruct.} = object
  WlInterface {.importc: "struct wl_interface", header: "wayland-client.h", incompleteStruct.} = object
  WlCompositor {.importc: "struct wl_compositor", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlShm {.importc: "struct wl_shm", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlShmPool {.importc: "struct wl_shm_pool", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlSurface {.importc: "struct wl_surface", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlBuffer {.importc: "struct wl_buffer", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlOutput {.importc: "struct wl_output", header: "wayland-client-protocol.h", incompleteStruct.} = object

  RiverWindowManager {.importc: "struct river_window_manager_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverWindow {.importc: "struct river_window_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverNode {.importc: "struct river_node_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverDecoration {.importc: "struct river_decoration_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverOutput {.importc: "struct river_output_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverSeat {.importc: "struct river_seat_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverXkbBindings {.importc: "struct river_xkb_bindings_v1", header: "river-xkb-bindings-v1-client-protocol.h", incompleteStruct.} = object
  RiverXkbBinding {.importc: "struct river_xkb_binding_v1", header: "river-xkb-bindings-v1-client-protocol.h", incompleteStruct.} = object
  RiverPointerBinding {.importc: "struct river_pointer_binding_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object

  Listener = object
    callbacks: array[18, pointer]

  Operation = enum
    opNone, opMove, opResize

  OutputInfo = ref object
    obj: ptr WlOutput
    globalName: uint32
    name: string

  Output = ref object
    obj: ptr RiverOutput
    ipcId: int64
    info: OutputInfo
    layer: LayerOutput
    bounds, usable: Box
    removed, areaChanged: bool
    active: Workspace

  Workspace = ref object
    ipcId: int64
    name: string
    output: Output

  Buffer = ref object
    obj: ptr WlBuffer

  Window = ref object
    obj: ptr RiverWindow
    ipcId: int64
    appId: string
    node: ptr RiverNode
    decoration: ptr RiverDecoration
    titlebarSurface: ptr WlSurface
    titlebarBuffer: Buffer
    titlebarWidth: int32
    title: string
    titlebarDirty: bool
    isNew, closed: bool
    decorationHint: uint32
    decorationModeNeedsUpdate: bool
    titlebarAttached, bordersSet, styleValid: bool
    style: ClientColors
    output: Output
    workspace: Workspace
    positionDirty: bool
    hidden: bool
    needsConstrain: bool
    x, y, width, height: int32
    pointerMoveRequested: Seat
    pointerResizeRequested: Seat
    pointerResizeRequestedEdges: uint32

  XkbBinding = ref object
    obj: ptr RiverXkbBinding
    seat: Seat
    commands: seq[Command]

  PointerBinding = ref object
    obj: ptr RiverPointerBinding
    seat: Seat
    commands: seq[Command]

  Seat = ref object
    obj: ptr RiverSeat
    bindingsDirty, removed: bool
    focused, hovered, interacted: Window
    xkbBindings: seq[XkbBinding]
    pointerBindings: seq[PointerBinding]
    pendingCommands: seq[Command]
    layer: LayerSeat
    ipcLayerFocus: bool
    output: Output
    pointerKnown: bool
    pointerX, pointerY: int32
    op: Operation
    opWindow: Window
    opStartX, opStartY, opDx, opDy: int32
    opStartWidth, opStartHeight: int32
    opRelease: bool
    opEdges: uint32

proc cairo_image_surface_create_for_data(data: ptr uint8; format, width, height, stride: cint): ptr CairoSurface {.importc, header: "cairo.h".}
proc cairo_surface_status(surface: ptr CairoSurface): cint {.importc, header: "cairo.h".}
proc cairo_surface_destroy(surface: ptr CairoSurface) {.importc, header: "cairo.h".}
proc cairo_surface_flush(surface: ptr CairoSurface) {.importc, header: "cairo.h".}
proc cairo_create(surface: ptr CairoSurface): ptr CairoContext {.importc, header: "cairo.h".}
proc cairo_status(context: ptr CairoContext): cint {.importc, header: "cairo.h".}
proc cairo_destroy(context: ptr CairoContext) {.importc, header: "cairo.h".}
proc cairo_set_source_rgba(context: ptr CairoContext; r, g, b, a: cdouble) {.importc, header: "cairo.h".}
proc cairo_move_to(context: ptr CairoContext; x, y: cdouble) {.importc, header: "cairo.h".}
proc cairo_rectangle(context: ptr CairoContext; x, y, width, height: cdouble) {.importc, header: "cairo.h".}
proc cairo_clip(context: ptr CairoContext) {.importc, header: "cairo.h".}
proc pango_cairo_create_layout(context: ptr CairoContext): ptr PangoLayout {.importc, header: "pango/pangocairo.h".}
proc pango_cairo_show_layout(context: ptr CairoContext; layout: ptr PangoLayout) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_text(layout: ptr PangoLayout; text: cstring; length: cint) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_font_description(layout: ptr PangoLayout; description: ptr PangoFontDescription) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_width(layout: ptr PangoLayout; width: cint) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_ellipsize(layout: ptr PangoLayout; mode: cint) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_single_paragraph_mode(layout: ptr PangoLayout; setting: cint) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_get_pixel_size(layout: ptr PangoLayout; width, height: ptr cint) {.importc, header: "pango/pangocairo.h".}
proc pango_font_description_from_string(description: cstring): ptr PangoFontDescription {.importc, header: "pango/pangocairo.h".}
proc pango_font_description_free(description: ptr PangoFontDescription) {.importc, header: "pango/pangocairo.h".}
proc g_object_unref(obj: pointer) {.importc, header: "glib-object.h".}

proc wl_display_connect(name: cstring): ptr WlDisplay {.importc, header: "wayland-client.h".}
proc wl_display_get_registry(display: ptr WlDisplay): ptr WlRegistry {.importc, header: "wayland-client.h".}
proc wl_display_roundtrip(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_dispatch(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_get_fd(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_prepare_read(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_cancel_read(display: ptr WlDisplay) {.importc, header: "wayland-client.h".}
proc wl_display_read_events(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_dispatch_pending(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_flush(display: ptr WlDisplay): cint {.importc, header: "wayland-client.h".}
proc wl_display_disconnect(display: ptr WlDisplay) {.importc, header: "wayland-client.h".}
proc wl_registry_add_listener(registry: ptr WlRegistry; listener, data: pointer): cint {.importc, header: "wayland-client.h".}
proc wl_output_add_listener(obj: ptr WlOutput; listener, data: pointer): cint {.importc, header: "wayland-client-protocol.h".}
proc wl_output_release(obj: ptr WlOutput) {.importc, header: "wayland-client-protocol.h".}
proc wl_registry_bind(registry: ptr WlRegistry; name: uint32; iface: pointer; version: uint32): pointer {.importc, header: "wayland-client.h".}
proc wl_compositor_create_surface(obj: ptr WlCompositor): ptr WlSurface {.importc, header: "wayland-client-protocol.h".}
proc wl_shm_create_pool(obj: ptr WlShm; fd, size: int32): ptr WlShmPool {.importc, header: "wayland-client-protocol.h".}
proc wl_shm_pool_create_buffer(obj: ptr WlShmPool; offset, width, height, stride: int32; format: uint32): ptr WlBuffer {.importc, header: "wayland-client-protocol.h".}
proc wl_shm_pool_destroy(obj: ptr WlShmPool) {.importc, header: "wayland-client-protocol.h".}
proc wl_buffer_add_listener(obj: ptr WlBuffer; listener, data: pointer): cint {.importc, header: "wayland-client-protocol.h".}
proc wl_buffer_destroy(obj: ptr WlBuffer) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_destroy(obj: ptr WlSurface) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_attach(obj: ptr WlSurface; buffer: ptr WlBuffer; x, y: int32) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_damage(obj: ptr WlSurface; x, y, width, height: int32) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_commit(obj: ptr WlSurface) {.importc, header: "wayland-client-protocol.h".}

proc river_window_manager_v1_add_listener(obj: ptr RiverWindowManager; listener, data: pointer): cint {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_manager_v1_manage_finish(obj: ptr RiverWindowManager) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_manager_v1_manage_dirty(obj: ptr RiverWindowManager) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_manager_v1_render_finish(obj: ptr RiverWindowManager) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_manager_v1_exit_session(obj: ptr RiverWindowManager) {.importc, header: "river-window-management-v1-client-protocol.h".}

proc river_window_v1_add_listener(obj: ptr RiverWindow; listener, data: pointer): cint {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_destroy(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_get_node(obj: ptr RiverWindow): ptr RiverNode {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_get_decoration_above(obj: ptr RiverWindow; surface: ptr WlSurface): ptr RiverDecoration {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_use_csd(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_use_ssd(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_set_borders(obj: ptr RiverWindow; edges: uint32; width: int32; r, g, b, a: uint32) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_decoration_v1_destroy(obj: ptr RiverDecoration) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_decoration_v1_set_offset(obj: ptr RiverDecoration; x, y: int32) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_decoration_v1_sync_next_commit(obj: ptr RiverDecoration) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_propose_dimensions(obj: ptr RiverWindow; width, height: int32) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_close(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_hide(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_show(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_inform_resize_start(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_v1_inform_resize_end(obj: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_node_v1_set_position(obj: ptr RiverNode; x, y: int32) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_node_v1_place_top(obj: ptr RiverNode) {.importc, header: "river-window-management-v1-client-protocol.h".}

proc river_output_v1_add_listener(obj: ptr RiverOutput; listener, data: pointer): cint {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_output_v1_destroy(obj: ptr RiverOutput) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_add_listener(obj: ptr RiverSeat; listener, data: pointer): cint {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_destroy(obj: ptr RiverSeat) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_focus_window(obj: ptr RiverSeat; window: ptr RiverWindow) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_clear_focus(obj: ptr RiverSeat) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_op_start_pointer(obj: ptr RiverSeat) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_op_end(obj: ptr RiverSeat) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_seat_v1_get_pointer_binding(obj: ptr RiverSeat; button, modifiers: uint32): ptr RiverPointerBinding {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_pointer_binding_v1_add_listener(obj: ptr RiverPointerBinding; listener, data: pointer): cint {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_pointer_binding_v1_enable(obj: ptr RiverPointerBinding) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_pointer_binding_v1_destroy(obj: ptr RiverPointerBinding) {.importc, header: "river-window-management-v1-client-protocol.h".}

proc river_xkb_bindings_v1_get_xkb_binding(obj: ptr RiverXkbBindings; seat: ptr RiverSeat; keysym, modifiers: uint32): ptr RiverXkbBinding {.importc, header: "river-xkb-bindings-v1-client-protocol.h".}
proc river_xkb_binding_v1_add_listener(obj: ptr RiverXkbBinding; listener, data: pointer): cint {.importc, header: "river-xkb-bindings-v1-client-protocol.h".}
proc river_xkb_binding_v1_enable(obj: ptr RiverXkbBinding) {.importc, header: "river-xkb-bindings-v1-client-protocol.h".}
proc river_xkb_binding_v1_destroy(obj: ptr RiverXkbBinding) {.importc, header: "river-xkb-bindings-v1-client-protocol.h".}

var river_window_manager_v1_interface {.importc, header: "river-window-management-v1-client-protocol.h".}: WlInterface
var river_xkb_bindings_v1_interface {.importc, header: "river-xkb-bindings-v1-client-protocol.h".}: WlInterface
var wl_compositor_interface {.importc, header: "wayland-client-protocol.h".}: WlInterface
var wl_output_interface {.importc, header: "wayland-client-protocol.h".}: WlInterface
var wl_shm_interface {.importc, header: "wayland-client-protocol.h".}: WlInterface

const
  BorderWidth = 2'i32
  TitlebarHeight = 24'i32
  TitlePadding = 8'i32
  PangoScale = 1024'i32

var activeConfig: Config
var configPath: string
var outputController: OutputController
var riverLayers: LayerShell
var defaultOutput: Output
var defaultLayerOutput: LayerOutput
var startupPending = true
var compositor: ptr WlCompositor
var sharedMemory: ptr WlShm
var windowManager: ptr RiverWindowManager
var xkbBindings: ptr RiverXkbBindings
var outputs: seq[Output]
var windows: seq[Window]
var workspaces: seq[Workspace]
var fallbackWorkspace: Workspace
var seats: seq[Seat]
var buffers: seq[Buffer]
var wmListener, windowListener, outputListener, seatListener: Listener
var xkbBindingListener, pointerBindingListener, registryListener, bufferListener: Listener
var ipcServer: SwayIpc
var ipcTreeDirty = true
var ipcNextId = 1'i64
var outputInfos: seq[OutputInfo]
var wlOutputListener: Listener
var stopRequested {.volatile.}: bool
var stopPipe = [-1.cint, -1.cint]
var waitingIpcCommands: seq[IpcCommand]
var pendingIpcReplies: seq[tuple[request: IpcCommand, results: JsonNode]]
var exitingIpcCommands: seq[IpcCommand]
var ipcExitReady = false

proc nextIpcId(): int64 =
  inc ipcNextId
  ipcNextId

proc stopForSignal(number: cint) {.noconv.} =
  stopRequested = true
  if stopPipe[1] >= 0:
    var wake = 1'u8
    discard posix.write(stopPipe[1], addr wake, 1)

proc wlOutputGeometry(data: pointer; obj: ptr WlOutput;
    x, y, width, height, subpixel: int32; make, model: cstring; transform: int32) {.cdecl.} = discard
proc wlOutputMode(data: pointer; obj: ptr WlOutput;
    flags: uint32; width, height, refresh: int32) {.cdecl.} = discard
proc wlOutputDone(data: pointer; obj: ptr WlOutput) {.cdecl.} = discard
proc wlOutputScale(data: pointer; obj: ptr WlOutput; scale: int32) {.cdecl.} = discard
proc wlOutputDescription(data: pointer; obj: ptr WlOutput; description: cstring) {.cdecl.} = discard
proc wlOutputName(data: pointer; obj: ptr WlOutput; name: cstring) {.cdecl.} =
  cast[OutputInfo](data).name = $name
  ipcTreeDirty = true
  if not windowManager.isNil: river_window_manager_v1_manage_dirty(windowManager)

proc wmNoop(data: pointer; obj: ptr RiverWindowManager) {.cdecl.} = discard
proc windowNoop(data: pointer; obj: ptr RiverWindow) {.cdecl.} = discard
proc windowDimensionsHint(data: pointer; obj: ptr RiverWindow; minWidth, minHeight, maxWidth, maxHeight: int32) {.cdecl.} = discard
proc windowStringHint(data: pointer; obj: ptr RiverWindow; value: cstring) {.cdecl.} = discard
proc windowParentHint(data: pointer; obj, parent: ptr RiverWindow) {.cdecl.} = discard
proc windowUintHint(data: pointer; obj: ptr RiverWindow; value: uint32) {.cdecl.} = discard
proc windowMenuHint(data: pointer; obj: ptr RiverWindow; x, y: int32) {.cdecl.} = discard
proc windowFullscreenHint(data: pointer; obj: ptr RiverWindow; output: ptr RiverOutput) {.cdecl.} = discard
proc windowIntHint(data: pointer; obj: ptr RiverWindow; value: int32) {.cdecl.} = discard
proc outputWlOutput(data: pointer; obj: ptr RiverOutput; name: uint32) {.cdecl.} =
  for info in outputInfos:
    if info.globalName == name:
      cast[Output](data).info = info
      ipcTreeDirty = true
      break
proc outputPosition(data: pointer; obj: ptr RiverOutput; x, y: int32) {.cdecl.} =
  let output = cast[Output](data)
  if output.bounds.x != x or output.bounds.y != y: ipcTreeDirty = true
  output.bounds.x = x
  output.bounds.y = y

proc outputDimensions(data: pointer; obj: ptr RiverOutput; width, height: int32) {.cdecl.} =
  let output = cast[Output](data)
  if output.bounds.width != width or output.bounds.height != height: ipcTreeDirty = true
  output.bounds.width = width
  output.bounds.height = height
proc seatWlSeat(data: pointer; obj: ptr RiverSeat; name: uint32) {.cdecl.} = discard
proc seatShellInteraction(data: pointer; obj: ptr RiverSeat; surface: pointer) {.cdecl.} = discard
proc seatPosition(data: pointer; obj: ptr RiverSeat; x, y: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.pointerKnown = true
  seat.pointerX = x
  seat.pointerY = y
proc xkbNoop(data: pointer; obj: ptr RiverXkbBinding) {.cdecl.} = discard
proc pointerNoop(data: pointer; obj: ptr RiverPointerBinding) {.cdecl.} = discard
proc registryGlobalRemove(data: pointer; registry: ptr WlRegistry; name: uint32) {.cdecl.} =
  for index, info in outputInfos:
    if info.globalName == name:
      wl_output_release(info.obj)
      outputInfos.delete(index)
      break

proc makeListener(callbacks: varargs[pointer]): Listener =
  for i, callback in callbacks:
    result.callbacks[i] = callback

proc findWindow(obj: ptr RiverWindow): Window =
  for window in windows:
    if window.obj == obj:
      return window

proc findSeat(obj: ptr RiverSeat): Seat =
  for seat in seats:
    if seat.obj == obj:
      return seat

proc bufferReleased(data: pointer; obj: ptr WlBuffer) {.cdecl.} =
  let buffer = cast[Buffer](data)
  wl_buffer_destroy(obj)
  var i = 0
  while i < buffers.len:
    if buffers[i] == buffer:
      buffers.delete(i)
      break
    inc i

proc drawTitle(mapping: pointer; width: int32; title: string; style: ClientColors): bool =
  let textWidth = width - 2 * TitlePadding
  if title.len == 0 or textWidth <= 0:
    return true

  let surface = cairo_image_surface_create_for_data(cast[ptr uint8](mapping),
    0, width, TitlebarHeight, width * 4) # CAIRO_FORMAT_ARGB32
  defer: cairo_surface_destroy(surface)
  if cairo_surface_status(surface) != 0:
    return false
  let context = cairo_create(surface)
  defer: cairo_destroy(context)
  if cairo_status(context) != 0:
    return false
  let layout = pango_cairo_create_layout(context)
  if layout.isNil:
    return false
  defer: g_object_unref(layout)
  let font = pango_font_description_from_string(activeConfig.font.cstring)
  if font.isNil:
    return false
  defer: pango_font_description_free(font)

  pango_layout_set_font_description(layout, font)
  pango_layout_set_text(layout, title.cstring, -1)
  pango_layout_set_width(layout, min(textWidth, high(cint) div PangoScale) * PangoScale)
  pango_layout_set_ellipsize(layout, 3) # PANGO_ELLIPSIZE_END
  pango_layout_set_single_paragraph_mode(layout, 1)
  var textHeight: cint
  pango_layout_get_pixel_size(layout, nil, addr textHeight)
  cairo_rectangle(context, TitlePadding.cdouble, 0, textWidth.cdouble, TitlebarHeight.cdouble)
  cairo_clip(context)
  cairo_set_source_rgba(context, style.text.r.cdouble / 255, style.text.g.cdouble / 255,
    style.text.b.cdouble / 255, style.text.a.cdouble / 255)
  cairo_move_to(context, TitlePadding.cdouble, (TitlebarHeight - textHeight).cdouble / 2)
  pango_cairo_show_layout(context, layout)
  cairo_surface_flush(surface)
  result = cairo_status(context) == 0 and cairo_surface_status(surface) == 0

proc createTitlebarBuffer(width: int32; title: string; style: ClientColors): Buffer =
  if width <= 0:
    return nil
  let byteCount = width.int64 * TitlebarHeight.int64 * 4
  if byteCount > high(int32).int64:
    return nil

  var file: File
  try:
    let temporary = createTempFile("nimzo-", "")
    file = temporary.cfile
    removeFile(temporary.path)
  except OSError as error:
    if not file.isNil:
      file.close()
    stderr.writeLine("failed to create titlebar storage: ", error.msg)
    return nil
  defer: file.close()

  let fd = file.getFileHandle()
  # mmap can succeed on an empty file, but writing to it would raise SIGBUS.
  if ftruncate(fd, byteCount.Off) < 0:
    stderr.writeLine("failed to size titlebar storage: ", osErrorMsg(osLastError()))
    return nil
  let mapping = mmap(nil, byteCount.int, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  if mapping == MAP_FAILED:
    stderr.writeLine("failed to map titlebar storage: ", osErrorMsg(osLastError()))
    return nil
  let pixels = cast[ptr UncheckedArray[uint32]](mapping)
  let background = style.background.pixel
  for i in 0 ..< int(byteCount div 4):
    pixels[i] = background
  if not drawTitle(mapping, width, title, style):
    discard munmap(mapping, byteCount.int)
    stderr.writeLine("failed to render window title")
    return nil

  let pool = wl_shm_create_pool(sharedMemory, fd, byteCount.int32)
  discard munmap(mapping, byteCount.int)
  if pool.isNil:
    return nil

  let wlBuffer = wl_shm_pool_create_buffer(pool, 0, width, TitlebarHeight,
    width * 4, 0'u32) # WL_SHM_FORMAT_ARGB8888
  wl_shm_pool_destroy(pool)
  if wlBuffer.isNil:
    return nil

  let buffer = Buffer(obj: wlBuffer)
  if wl_buffer_add_listener(wlBuffer, cast[pointer](addr bufferListener),
      cast[pointer](buffer)) < 0:
    wl_buffer_destroy(wlBuffer)
    return nil
  buffers.add(buffer)
  buffer

proc ensureLayerObjects() =
  if riverLayers.isNil: return
  for output in outputs:
    if not output.removed and output.layer.isNil:
      output.layer = createLayerOutput(riverLayers, cast[pointer](output.obj))
  for seat in seats:
    if not seat.removed and seat.layer.isNil:
      seat.layer = createLayerSeat(riverLayers, cast[pointer](seat.obj))

proc manageOutputs() =
  ensureLayerObjects()
  if defaultOutput.isNil or defaultOutput.removed or not defaultOutput.bounds.valid:
    defaultOutput = nil
    for output in outputs:
      if output.bounds.valid:
        defaultOutput = output
        break
  let selected = if defaultOutput.isNil: nil else: defaultOutput.layer
  if selected != defaultLayerOutput:
    defaultLayerOutput = selected
    if not selected.isNil: selected.setDefault()
  for output in outputs:
    let hint = if output.layer.isNil: Box() else: output.layer.area
    let area = usableArea(output.bounds, hint)
    output.areaChanged = output.usable != area
    if output.areaChanged: ipcTreeDirty = true
    output.usable = area

proc workspaceNumber(name: string): int =
  let prefix = name.split(':', 1)[0]
  try:
    result = parseInt(prefix)
  except ValueError:
    result = -1

proc findWorkspace(name: string): Workspace =
  let number = workspaceNumber(name)
  for workspace in workspaces:
    if workspace.name == name or
        (number >= 0 and workspaceNumber(workspace.name) == number):
      return workspace

proc newWorkspace(name: string; output: Output): Workspace =
  result = Workspace(name: name, output: output, ipcId: nextIpcId())
  workspaces.add(result)
  ipcTreeDirty = true

proc vacantWorkspace(output: Output): Workspace =
  var number = 1
  while not findWorkspace($number).isNil: inc number
  newWorkspace($number, output)

proc visible(window: Window): bool =
  not window.isNil and not window.closed and not window.workspace.isNil and
    ((window.workspace.output.isNil and window.workspace == fallbackWorkspace) or
      (not window.workspace.output.isNil and
      window.workspace.output.active == window.workspace))

proc relocate(window: Window; workspace: Workspace) =
  ipcTreeDirty = true
  let old = window.output
  let destination = workspace.output
  if old != destination and not old.isNil and not destination.isNil:
    window.x += destination.usable.x - old.usable.x
    window.y += destination.usable.y - old.usable.y
    window.positionDirty = true
  window.workspace = workspace
  window.output = destination
  window.needsConstrain = true

proc manageWorkspaces() =
  var fallback: Output
  for output in outputs:
    if output.bounds.valid:
      if fallback.isNil: fallback = output
      if output.active.isNil:
        output.active = vacantWorkspace(output)
  if workspaces.len == 0:
    discard newWorkspace("1", fallback)
  if fallbackWorkspace.isNil: fallbackWorkspace = workspaces[0]
  for workspace in workspaces:
    if workspace.output.isNil or workspace.output.removed:
      workspace.output = fallback
      if not fallback.isNil and fallback.active.isNil:
        fallback.active = workspace
      for window in windows:
        if window.workspace == workspace: window.relocate(workspace)
  for seat in seats:
    if seat.output.isNil or seat.output.removed:
      seat.output = fallback

proc activeWorkspace(seat: Seat): Workspace =
  if not seat.output.isNil: return seat.output.active
  fallbackWorkspace

proc workspaceOrder(a, b: Workspace): int =
  let an = workspaceNumber(a.name)
  let bn = workspaceNumber(b.name)
  if an >= 0 and bn >= 0: cmp(an, bn)
  elif an >= 0: -1
  elif bn >= 0: 1
  else: cmp(a.name, b.name)

proc workspaceTarget(seat: Seat; target: string): Workspace =
  if target notin ["prev", "next"]:
    result = findWorkspace(target)
    if result.isNil: result = newWorkspace(target, seat.output)
    return
  var ordered = workspaces
  ordered.sort(workspaceOrder)
  let index = ordered.find(seat.activeWorkspace)
  let step = if target == "next": 1 else: ordered.len - 1
  ordered[(max(index, 0) + step) mod ordered.len]

proc directionalOutput(seat: Seat; direction: string): Output =
  let source = seat.output
  if source.isNil: return
  let sx = source.bounds.x.int64 * 2 + source.bounds.width
  let sy = source.bounds.y.int64 * 2 + source.bounds.height
  var bestPrimary = high(int64)
  var bestSecondary = high(int64)
  for output in outputs:
    if output == source or not output.bounds.valid: continue
    let dx = output.bounds.x.int64 * 2 + output.bounds.width - sx
    let dy = output.bounds.y.int64 * 2 + output.bounds.height - sy
    let primary = case direction
      of "left": -dx
      of "right": dx
      of "up": -dy
      else: dy
    let secondary = if direction in ["left", "right"]: abs(dy) else: abs(dx)
    if primary > 0 and (primary < bestPrimary or
        (primary == bestPrimary and secondary < bestSecondary)):
      result = output
      bestPrimary = primary
      bestSecondary = secondary

proc previousOutput(seat: Seat): Output =
  if outputs.len == 0: return
  let start = max(outputs.find(seat.output), 0)
  for distance in 1..outputs.len:
    let output = outputs[(start + outputs.len - distance) mod outputs.len]
    if not output.removed and output.bounds.valid:
      return output

proc pruneWorkspaces() =
  var index = 0
  while index < workspaces.len:
    let workspace = workspaces[index]
    var occupied = false
    for window in windows:
      if window.workspace == workspace: occupied = true
    let active = if workspace.output.isNil: workspace == fallbackWorkspace
                 else: workspace.output.active == workspace
    if not occupied and not active:
      workspaces.delete(index)
      ipcTreeDirty = true
    else:
      inc index

proc chooseOutput(): Output =
  for seat in seats:
    if seat.pointerKnown:
      for output in outputs:
        if output.bounds.contains(seat.pointerX, seat.pointerY): return output
  for seat in seats:
    if not seat.output.isNil and not seat.output.removed: return seat.output
  if not defaultOutput.isNil and not defaultOutput.removed: return defaultOutput
  for output in outputs:
    if output.bounds.valid: return output

proc windowOutput(window: Window): Output =
  var bestOverlap = 0'i64
  let content = Box(x: window.x, y: window.y,
    width: max(window.width, 1), height: max(window.height, 1))
  if not window.output.isNil and not window.output.removed:
    result = window.output
    bestOverlap = content.overlap(result.bounds)
  for output in outputs:
    if output.bounds.valid:
      let overlap = content.overlap(output.bounds)
      if overlap > bestOverlap:
        result = output
        bestOverlap = overlap
  if result.isNil: result = chooseOutput()

proc windowHasOperation(window: Window): bool =
  for seat in seats:
    if seat.opWindow == window: return true

proc windowSetPosition(window: Window; x, y: int32) =
  if window.x != x or window.y != y: ipcTreeDirty = true
  river_node_v1_set_position(window.node, x, y)
  window.x = x
  window.y = y

proc constrainWindows() =
  for window in windows:
    let output = if window.workspace.isNil: window.output else: window.workspace.output
    window.output = output
    if output.isNil or windowHasOperation(window): continue
    if output.areaChanged: window.needsConstrain = true
    if window.needsConstrain:
      let titleHeight = if window.decorationHint == 0: 0'i32 else: TitlebarHeight
      let position = fitPosition(output.usable, window.x, window.y,
        window.width, window.height, BorderWidth, titleHeight)
      if position != (window.x, window.y):
        windowSetPosition(window, position.x, position.y)
      window.needsConstrain = window.width <= 0 or window.height <= 0

proc seatFocus(seat: Seat; target: Window) =
  if seat.layer.exclusiveFocus: return
  var window = target
  if not window.visible: window = nil
  if window.isNil:
    for index in countdown(windows.high, 0):
      let candidate = windows[index]
      if candidate.visible and candidate.workspace == seat.activeWorkspace:
        window = candidate
        break
  if not window.isNil: seat.output = window.output
  if seat.focused == window and not seat.layer.hasLayerFocus and not seat.layer.needsRestore:
    return
  ipcTreeDirty = true
  if not window.isNil:
    river_seat_v1_focus_window(seat.obj, window.obj)
    river_node_v1_place_top(window.node)
    let index = windows.find(window)
    if index >= 0:
      windows.delete(index)
      windows.add(window)
  else:
    river_seat_v1_clear_focus(seat.obj)
  seat.focused = window
  seat.layer.claimWindowFocus()

proc selectWorkspace(seat: Seat; workspace: Workspace) =
  ipcTreeDirty = true
  fallbackWorkspace = workspace
  if not workspace.output.isNil:
    workspace.output.active = workspace
  seat.output = workspace.output
  seat.pointerKnown = false
  seatFocus(seat, nil)

proc repairFocus() =
  for seat in seats:
    if not seat.focused.visible or
        seat.focused.workspace != seat.activeWorkspace:
      seatFocus(seat, nil)

proc ipcNode(id: int64; kind, name: string; bounds: Box): JsonNode =
  %*{"id": id, "type": kind, "name": name, "focused": false,
    "visible": false, "urgent": false, "nodes": [], "floating_nodes": [],
    "focus": [], "rect": {"x": bounds.x, "y": bounds.y,
      "width": bounds.width, "height": bounds.height}}

proc publishIpcTree() =
  if ipcServer.isNil or not ipcTreeDirty: return
  ipcTreeDirty = false
  var primary: Seat
  for seat in seats:
    if not seat.removed:
      primary = seat
      break
  let focusedOutput = if primary.isNil: nil else: primary.output
  let focusedWindow = if primary.isNil or primary.layer.hasLayerFocus: nil else: primary.focused
  let root = ipcNode(1, "root", "root", Box())
  var ordered = workspaces
  ordered.sort(workspaceOrder)
  var firstOutput = true
  var left, top, right, bottom: int64
  for output in outputs:
    if output.removed or not output.bounds.valid or output.info.isNil or
        output.info.name.len == 0: continue
    let node = ipcNode(output.ipcId, "output", output.info.name, output.bounds)
    node["visible"] = %true
    for workspace in ordered:
      if workspace.output != output: continue
      let ws = ipcNode(workspace.ipcId, "workspace", workspace.name, output.usable)
      let number = workspaceNumber(workspace.name)
      ws["num"] = %(if number in 0..high(int32).int: number else: -1)
      ws["output"] = %output.info.name
      ws["visible"] = %(output.active == workspace)
      ws["focused"] = %(output == focusedOutput and output.active == workspace)
      for window in windows:
        if window.closed or window.isNew or window.workspace != workspace: continue
        let child = ipcNode(window.ipcId, "floating_con", window.title,
          Box(x: window.x, y: window.y, width: window.width, height: window.height))
        child["app_id"] = %window.appId
        child["focused"] = %(window == focusedWindow)
        child["visible"] = %window.visible
        ws["floating_nodes"].add(child)
      for index in countdown(windows.high, 0):
        let window = windows[index]
        if not window.closed and not window.isNew and window.workspace == workspace:
          ws["focus"].add(%window.ipcId)
      node["nodes"].add(ws)
    if not output.active.isNil: node["focus"].add(%output.active.ipcId)
    for workspace in ordered:
      if workspace.output == output and workspace != output.active:
        node["focus"].add(%workspace.ipcId)
    root["nodes"].add(node)
    if firstOutput:
      left = output.bounds.x
      top = output.bounds.y
      right = output.bounds.x.int64 + output.bounds.width
      bottom = output.bounds.y.int64 + output.bounds.height
      firstOutput = false
    else:
      left = min(left, output.bounds.x.int64)
      top = min(top, output.bounds.y.int64)
      right = max(right, output.bounds.x.int64 + output.bounds.width)
      bottom = max(bottom, output.bounds.y.int64 + output.bounds.height)
  if not focusedOutput.isNil:
    for node in root["nodes"]:
      if node["id"].getBiggestInt == focusedOutput.ipcId:
        root["focus"].add(%focusedOutput.ipcId)
  for node in root["nodes"]:
    if focusedOutput.isNil or node["id"].getBiggestInt != focusedOutput.ipcId:
      root["focus"].add(node["id"])
  root["rect"] = %*{"x": left, "y": top, "width": right - left, "height": bottom - top}
  ipcServer.setTree(root)

proc seatPointerMove(seat: Seat; window: Window) =
  if seat.layer.exclusiveFocus: return
  seatFocus(seat, window)
  river_seat_v1_op_start_pointer(seat.obj)
  seat.op = opMove
  seat.opWindow = window
  seat.opStartX = window.x
  seat.opStartY = window.y
  seat.opDx = 0
  seat.opDy = 0

proc seatPointerResize(seat: Seat; window: Window; edges: uint32) =
  if seat.layer.exclusiveFocus: return
  seatFocus(seat, window)
  river_window_v1_inform_resize_start(window.obj)
  river_seat_v1_op_start_pointer(seat.obj)
  seat.op = opResize
  seat.opWindow = window
  seat.opEdges = edges
  seat.opStartX = window.x
  seat.opStartY = window.y
  seat.opStartWidth = window.width
  seat.opStartHeight = window.height
  seat.opDx = 0
  seat.opDy = 0

proc xkbPressed(data: pointer; obj: ptr RiverXkbBinding) {.cdecl.} =
  let binding = cast[XkbBinding](data)
  binding.seat.pendingCommands = binding.commands

proc pointerPressed(data: pointer; obj: ptr RiverPointerBinding) {.cdecl.} =
  let binding = cast[PointerBinding](data)
  binding.seat.pendingCommands = binding.commands

proc createXkbBinding(seat: Seat; definition: Binding) =
  let binding = XkbBinding(obj: river_xkb_bindings_v1_get_xkb_binding(
    xkbBindings, seat.obj, definition.trigger, definition.modifiers),
    seat: seat, commands: definition.commands)
  discard river_xkb_binding_v1_add_listener(binding.obj,
    cast[pointer](addr xkbBindingListener), cast[pointer](binding))
  seat.xkbBindings.add(binding)
  river_xkb_binding_v1_enable(binding.obj)

proc createPointerBinding(seat: Seat; definition: Binding) =
  let binding = PointerBinding(obj: river_seat_v1_get_pointer_binding(
    seat.obj, definition.trigger, definition.modifiers), seat: seat, commands: definition.commands)
  discard river_pointer_binding_v1_add_listener(binding.obj,
    cast[pointer](addr pointerBindingListener), cast[pointer](binding))
  seat.pointerBindings.add(binding)
  river_pointer_binding_v1_enable(binding.obj)

proc reloadConfiguration(): CommandResult =
  try:
    let replacement = loadConfig(configPath)
    activeConfig = replacement
    if not outputController.isNil:
      outputController.setRules(activeConfig.outputs)
    elif activeConfig.outputs.len > 0:
      stderr.writeLine("output configuration requires zwlr_output_manager_v1 version 4")
    for seat in seats:
      seat.bindingsDirty = true
    for window in windows:
      window.titlebarDirty = true
    stderr.writeLine("reloaded ", configPath)
    result = commandSuccess()
  except ConfigError as error:
    stderr.writeLine("configuration reload failed; keeping current configuration: ", error.msg)
    result = commandFailure(error.msg)

proc updateSeatBindings(seat: Seat) =
  if not seat.bindingsDirty: return
  for binding in seat.xkbBindings:
    river_xkb_binding_v1_destroy(binding.obj)
  for binding in seat.pointerBindings:
    river_pointer_binding_v1_destroy(binding.obj)
  seat.xkbBindings = @[]
  seat.pointerBindings = @[]
  for definition in activeConfig.effectiveBindings:
    case definition.kind
    of bindingKey: createXkbBinding(seat, definition)
    of bindingPointer: createPointerBinding(seat, definition)
  seat.bindingsDirty = false

proc seatContext(seat: Seat): CommandContext =
  result.exit = proc(): CommandResult =
    river_window_manager_v1_exit_session(windowManager)
    commandSuccess()
  result.reload = proc(): CommandResult = reloadConfiguration()
  if seat.isNil: return
  result.close = proc(): CommandResult =
    if not seat.focused.visible or seat.layer.hasLayerFocus:
      return commandFailure("no focused window")
    river_window_v1_close(seat.focused.obj)
    commandSuccess()
  result.focusNext = proc(): CommandResult =
    if seat.layer.exclusiveFocus:
      return commandFailure("keyboard focus is held by an exclusive layer surface")
    for window in windows:
      if window.visible and window.workspace == seat.activeWorkspace:
        seatFocus(seat, window)
        return commandSuccess()
    commandFailure("no window on the focused workspace")
  result.move = proc(): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if seat.layer.exclusiveFocus:
      return commandFailure("keyboard focus is held by an exclusive layer surface")
    if not seat.hovered.visible: return commandFailure("no hovered window")
    seatPointerMove(seat, seat.hovered)
    commandSuccess()
  result.resize = proc(): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if seat.layer.exclusiveFocus:
      return commandFailure("keyboard focus is held by an exclusive layer surface")
    if not seat.hovered.visible: return commandFailure("no hovered window")
    seatPointerResize(seat, seat.hovered, 2'u32 or 8'u32)
    commandSuccess()
  result.workspace = proc(target: string): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if seat.layer.exclusiveFocus:
      return commandFailure("keyboard focus is held by an exclusive layer surface")
    seat.selectWorkspace(seat.workspaceTarget(target))
    commandSuccess()
  result.moveWorkspaceContainer = proc(target: string): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if not seat.focused.visible or seat.layer.hasLayerFocus:
      return commandFailure("no focused window")
    seat.focused.relocate(seat.workspaceTarget(target))
    repairFocus()
    commandSuccess()
  result.focusOutput = proc(target: string): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if seat.layer.exclusiveFocus:
      return commandFailure("keyboard focus is held by an exclusive layer surface")
    let output = if target == "prev": seat.previousOutput()
                 else: seat.directionalOutput(target)
    if output.isNil: return commandFailure("no output in direction '" & target & "'")
    seat.selectWorkspace(output.active)
    commandSuccess()
  result.moveOutputContainer = proc(target: string): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if not seat.focused.visible or seat.layer.hasLayerFocus:
      return commandFailure("no focused window")
    let output = seat.directionalOutput(target)
    if output.isNil: return commandFailure("no output in direction '" & target & "'")
    seat.focused.relocate(output.active)
    repairFocus()
    commandSuccess()
  result.moveWorkspaceOutput = proc(target: string): CommandResult =
    if seat.op != opNone: return commandFailure("a pointer operation is active")
    if seat.layer.exclusiveFocus:
      return commandFailure("keyboard focus is held by an exclusive layer surface")
    let output = seat.directionalOutput(target)
    if output.isNil: return commandFailure("no output in direction '" & target & "'")
    let workspace = seat.activeWorkspace
    let source = workspace.output
    workspace.output = output
    if not source.isNil:
      source.active = nil
      for candidate in workspaces:
        if candidate.output == source:
          source.active = candidate
          break
      if source.active.isNil: source.active = vacantWorkspace(source)
    for window in windows:
      if window.workspace == workspace: window.relocate(workspace)
    seat.selectWorkspace(workspace)
    repairFocus()
    commandSuccess()

proc processIpcCommands() =
  if waitingIpcCommands.len == 0: return
  let requests = move(waitingIpcCommands)
  for request in requests:
    var primary: Seat
    for seat in seats:
      if not seat.removed:
        primary = seat
        break
    var context = seatContext(primary)
    var exits = false
    context.exit = proc(): CommandResult =
      exits = true
      commandSuccess()
    let results = newJArray()
    for parsed in parseIpcCommands(request.payload):
      let outcome = if parsed.parseError.len > 0:
          commandFailure(parsed.parseError, parseError = true)
        else:
          execute(parsed.command, context)
      let item = %*{"success": outcome.success}
      if not outcome.success:
        item["error"] = %outcome.error
        if outcome.parseError: item["parse_error"] = %true
      results.add(item)
    pendingIpcReplies.add((request, results))
    if exits: exitingIpcCommands.add(request)

proc seatManage(seat: Seat) =
  let layerFocused = seat.layer.hasLayerFocus
  if layerFocused != seat.ipcLayerFocus:
    seat.ipcLayerFocus = layerFocused
    ipcTreeDirty = true
  if not seat.focused.visible:
    seat.focused = nil
  if not seat.layer.hasLayerFocus:
    let target = if seat.layer.needsRestore and seat.interacted.isNil: seat.focused else: seat.interacted
    seatFocus(seat, target)
  elif not seat.layer.exclusiveFocus and not seat.interacted.isNil:
    seatFocus(seat, seat.interacted)
  seat.interacted = nil
  let pending = seat.pendingCommands
  seat.pendingCommands = @[]
  if pending.len > 0:
    let context = seatContext(seat)
    for command in pending:
      let outcome = execute(command, context)
      if not outcome.success: stderr.writeLine("command failed: ", outcome.error)

  case seat.op
  of opNone:
    discard
  of opMove:
    if seat.opRelease:
      let destination = windowOutput(seat.opWindow)
      if not destination.isNil:
        if seat.opWindow.workspace != destination.active: ipcTreeDirty = true
        seat.opWindow.workspace = destination.active
        seat.opWindow.output = destination
        seat.output = destination
        seat.opWindow.needsConstrain = true
      river_seat_v1_op_end(seat.obj)
      seat.op = opNone
      seat.opWindow = nil
  of opResize:
    if seat.opRelease:
      river_window_v1_inform_resize_end(seat.opWindow.obj)
      river_seat_v1_op_end(seat.obj)
      seat.op = opNone
      seat.opWindow = nil
    else:
      var width = seat.opStartWidth
      var height = seat.opStartHeight
      if (seat.opEdges and 4'u32) != 0: width -= seat.opDx
      if (seat.opEdges and 8'u32) != 0: width += seat.opDx
      if (seat.opEdges and 1'u32) != 0: height -= seat.opDy
      if (seat.opEdges and 2'u32) != 0: height += seat.opDy
      river_window_v1_propose_dimensions(seat.opWindow.obj,
        max(width, 1'i32), max(height, 1'i32))
  seat.opRelease = false

proc seatRender(seat: Seat) =
  case seat.op
  of opNone:
    discard
  of opMove:
    windowSetPosition(seat.opWindow,
      seat.opStartX + seat.opDx, seat.opStartY + seat.opDy)
  of opResize:
    var x = seat.opStartX
    var y = seat.opStartY
    if (seat.opEdges and 4'u32) != 0:
      x += seat.opStartWidth - seat.opWindow.width
    if (seat.opEdges and 1'u32) != 0:
      y += seat.opStartHeight - seat.opWindow.height
    windowSetPosition(seat.opWindow, x, y)

proc outputRemoved(data: pointer; obj: ptr RiverOutput) {.cdecl.} =
  cast[Output](data).removed = true
  ipcTreeDirty = true

proc windowClosed(data: pointer; obj: ptr RiverWindow) {.cdecl.} =
  cast[Window](data).closed = true
  ipcTreeDirty = true

proc windowDimensions(data: pointer; obj: ptr RiverWindow; width, height: int32) {.cdecl.} =
  let window = cast[Window](data)
  if window.width != width or window.height != height: ipcTreeDirty = true
  window.width = width
  window.height = height

proc windowTitle(data: pointer; obj: ptr RiverWindow; value: cstring) {.cdecl.} =
  let window = cast[Window](data)
  let title = if value == nil: "" else: $value
  if window.title != title:
    window.title = title
    window.titlebarDirty = true
    ipcTreeDirty = true

proc windowAppId(data: pointer; obj: ptr RiverWindow; value: cstring) {.cdecl.} =
  let window = cast[Window](data)
  let appId = if value == nil: "" else: $value
  if window.appId != appId:
    window.appId = appId
    ipcTreeDirty = true

proc windowDecorationHint(data: pointer; obj: ptr RiverWindow; hint: uint32) {.cdecl.} =
  let window = cast[Window](data)
  if window.decorationHint != hint:
    window.needsConstrain = true
  window.decorationHint = hint
  window.decorationModeNeedsUpdate = true

proc windowPointerMoveRequested(data: pointer; obj: ptr RiverWindow; riverSeat: ptr RiverSeat) {.cdecl.} =
  cast[Window](data).pointerMoveRequested = findSeat(riverSeat)

proc windowPointerResizeRequested(data: pointer; obj: ptr RiverWindow; riverSeat: ptr RiverSeat; edges: uint32) {.cdecl.} =
  let window = cast[Window](data)
  window.pointerResizeRequested = findSeat(riverSeat)
  window.pointerResizeRequestedEdges = edges

proc seatRemoved(data: pointer; obj: ptr RiverSeat) {.cdecl.} =
  cast[Seat](data).removed = true
  ipcTreeDirty = true

proc seatPointerEnter(data: pointer; obj: ptr RiverSeat; riverWindow: ptr RiverWindow) {.cdecl.} =
  cast[Seat](data).hovered = findWindow(riverWindow)

proc seatPointerLeave(data: pointer; obj: ptr RiverSeat) {.cdecl.} =
  cast[Seat](data).hovered = nil

proc seatWindowInteraction(data: pointer; obj: ptr RiverSeat; riverWindow: ptr RiverWindow) {.cdecl.} =
  cast[Seat](data).interacted = findWindow(riverWindow)

proc seatOpDelta(data: pointer; obj: ptr RiverSeat; dx, dy: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.opDx = dx
  seat.opDy = dy

proc seatOpRelease(data: pointer; obj: ptr RiverSeat) {.cdecl.} =
  cast[Seat](data).opRelease = true

proc wmUnavailable(data: pointer; obj: ptr RiverWindowManager) {.cdecl.} =
  stderr.writeLine("error: another window manager is already running")
  quit(1)

proc wmFinished(data: pointer; obj: ptr RiverWindowManager) {.cdecl.} = quit(0)

proc wmNewWindow(data: pointer; obj: ptr RiverWindowManager; riverWindow: ptr RiverWindow) {.cdecl.} =
  let window = Window(obj: riverWindow, node: river_window_v1_get_node(riverWindow),
    isNew: true, ipcId: nextIpcId())
  window.titlebarSurface = wl_compositor_create_surface(compositor)
  window.decoration = river_window_v1_get_decoration_above(window.obj,
    window.titlebarSurface)
  discard river_window_v1_add_listener(window.obj,
    cast[pointer](addr windowListener), cast[pointer](window))
  windows.add(window)
  ipcTreeDirty = true

proc wmNewOutput(data: pointer; obj: ptr RiverWindowManager; riverOutput: ptr RiverOutput) {.cdecl.} =
  let output = Output(obj: riverOutput, ipcId: nextIpcId())
  discard river_output_v1_add_listener(output.obj,
    cast[pointer](addr outputListener), cast[pointer](output))
  outputs.add(output)
  ipcTreeDirty = true
  if not riverLayers.isNil:
    output.layer = createLayerOutput(riverLayers, cast[pointer](output.obj))

proc wmNewSeat(data: pointer; obj: ptr RiverWindowManager; riverSeat: ptr RiverSeat) {.cdecl.} =
  let seat = Seat(obj: riverSeat, bindingsDirty: true)
  ipcTreeDirty = true
  discard river_seat_v1_add_listener(seat.obj,
    cast[pointer](addr seatListener), cast[pointer](seat))
  seats.add(seat)
  if not riverLayers.isNil:
    seat.layer = createLayerSeat(riverLayers, cast[pointer](seat.obj))

proc destroyRemoved() =
  var i = 0
  while i < outputs.len:
    if outputs[i].removed:
      outputs[i].layer.destroy()
      river_output_v1_destroy(outputs[i].obj)
      outputs.delete(i)
    else:
      inc i

  i = 0
  while i < windows.len:
    let window = windows[i]
    if not window.closed:
      inc i
      continue
    for seat in seats:
      if seat.focused == window:
        seat.focused = nil
      if seat.hovered == window: seat.hovered = nil
      if seat.interacted == window: seat.interacted = nil
      if seat.opWindow == window:
        river_seat_v1_op_end(seat.obj)
        seat.op = opNone
        seat.opWindow = nil
    if not window.decoration.isNil:
      river_decoration_v1_destroy(window.decoration)
    if not window.titlebarSurface.isNil:
      wl_surface_destroy(window.titlebarSurface)
    river_window_v1_destroy(window.obj)
    windows.delete(i)

  i = 0
  while i < seats.len:
    let seat = seats[i]
    if not seat.removed:
      inc i
      continue
    for binding in seat.xkbBindings:
      river_xkb_binding_v1_destroy(binding.obj)
    for binding in seat.pointerBindings:
      river_pointer_binding_v1_destroy(binding.obj)
    seat.layer.destroy()
    river_seat_v1_destroy(seat.obj)
    seats.delete(i)

proc windowManage(window: Window) =
  if window.isNew:
    window.isNew = false
    let top = if window.decorationHint == 0: BorderWidth
              else: TitlebarHeight + BorderWidth
    window.output = chooseOutput()
    window.workspace = if window.output.isNil: fallbackWorkspace else: window.output.active
    window.needsConstrain = true
    let area = if window.output.isNil: Box() else: window.output.usable
    let position = fitPosition(area, area.x, area.y, 0, 0, BorderWidth,
      if window.decorationHint == 0: 0'i32 else: TitlebarHeight)
    if area.valid:
      windowSetPosition(window, position.x, position.y)
    else:
      windowSetPosition(window, BorderWidth, top)
    river_window_v1_propose_dimensions(window.obj, 0, 0)
    window.decorationModeNeedsUpdate = true
  if window.decorationModeNeedsUpdate:
    if window.decorationHint == 0:
      river_window_v1_use_csd(window.obj)
    else:
      river_window_v1_use_ssd(window.obj)
    window.decorationModeNeedsUpdate = false
  if not window.pointerMoveRequested.isNil:
    seatPointerMove(window.pointerMoveRequested, window)
    window.pointerMoveRequested = nil
  if not window.pointerResizeRequested.isNil:
    seatPointerResize(window.pointerResizeRequested, window,
      window.pointerResizeRequestedEdges)
    window.pointerResizeRequested = nil

proc windowRender(window: Window) =
  if window.positionDirty:
    river_node_v1_set_position(window.node, window.x, window.y)
    window.positionDirty = false
  let hidden = not window.visible
  if hidden != window.hidden:
    if hidden: river_window_v1_hide(window.obj)
    else: river_window_v1_show(window.obj)
    window.hidden = hidden
  var style = activeConfig.unfocused
  for seat in seats:
    if seat.focused == window and not seat.layer.hasLayerFocus:
      style = activeConfig.focused
      break
  if not window.styleValid or window.style != style:
    window.style = style
    window.styleValid = true
    window.bordersSet = false
    window.titlebarDirty = true
  if not window.bordersSet:
    let color = style.border.rgba32
    river_window_v1_set_borders(window.obj, 15'u32, BorderWidth,
      color[0], color[1], color[2], color[3])
    window.bordersSet = true
  if window.decorationHint == 0:
    if window.titlebarAttached:
      river_decoration_v1_sync_next_commit(window.decoration)
      wl_surface_attach(window.titlebarSurface, nil, 0, 0)
      wl_surface_commit(window.titlebarSurface)
      window.titlebarAttached = false
      window.titlebarBuffer = nil
      window.titlebarWidth = 0
    return
  if window.width <= 0 or window.decoration.isNil or window.titlebarSurface.isNil:
    return
  if not window.titlebarBuffer.isNil and window.titlebarWidth == window.width and
      not window.titlebarDirty:
    return

  let buffer = createTitlebarBuffer(window.width, window.title, style)
  if buffer.isNil:
    return
  window.titlebarBuffer = buffer
  window.titlebarWidth = window.width
  window.titlebarDirty = false
  river_decoration_v1_set_offset(window.decoration, 0, -TitlebarHeight)
  river_decoration_v1_sync_next_commit(window.decoration)
  wl_surface_attach(window.titlebarSurface, buffer.obj, 0, 0)
  wl_surface_damage(window.titlebarSurface, 0, 0, window.width, TitlebarHeight)
  wl_surface_commit(window.titlebarSurface)
  window.titlebarAttached = true

proc requireInterfaces() =
  if windowManager.isNil or xkbBindings.isNil or compositor.isNil or sharedMemory.isNil:
    stderr.writeLine("required river or Wayland interfaces are not supported by the server")
    quit(1)

proc manageStart(data: pointer; obj: ptr RiverWindowManager) {.cdecl.} =
  requireInterfaces()
  destroyRemoved()
  manageOutputs()
  manageWorkspaces()
  for seat in seats:
    updateSeatBindings(seat)
  for window in windows:
    windowManage(window)
  for seat in seats:
    seatManage(seat)
  processIpcCommands()
  if ipcExitReady:
    river_window_manager_v1_exit_session(windowManager)
  repairFocus()
  pruneWorkspaces()
  constrainWindows()
  if startupPending:
    startupPending = false
    for command in activeConfig.startup:
      let outcome = execute(command, CommandContext())
      if not outcome.success: stderr.writeLine("startup command failed: ", outcome.error)
  # Reload may have been requested by any seat during this manage sequence.
  for seat in seats:
    updateSeatBindings(seat)
  river_window_manager_v1_manage_finish(windowManager)

proc renderStart(data: pointer; obj: ptr RiverWindowManager) {.cdecl.} =
  constrainWindows()
  for window in windows:
    windowRender(window)
  for seat in seats:
    seatRender(seat)
  for output in outputs:
    output.areaChanged = false
  river_window_manager_v1_render_finish(windowManager)
  publishIpcTree()
  for reply in pendingIpcReplies:
    ipcServer.replyCommand(reply.request, reply.results)
  pendingIpcReplies.setLen(0)

proc registryGlobal(data: pointer; registry: ptr WlRegistry; name: uint32; interfaceName: cstring; version: uint32) {.cdecl.} =
  case $interfaceName
  of "river_window_manager_v1":
    if version >= 4:
      windowManager = cast[ptr RiverWindowManager](wl_registry_bind(registry,
        name, cast[pointer](addr river_window_manager_v1_interface), 4))
      # Events may arrive in the initial roundtrip; don't discard early seats/windows.
      discard river_window_manager_v1_add_listener(windowManager,
        cast[pointer](addr wmListener), nil)
  of "river_xkb_bindings_v1":
    xkbBindings = cast[ptr RiverXkbBindings](wl_registry_bind(registry,
      name, cast[pointer](addr river_xkb_bindings_v1_interface), 1))
  of "river_layer_shell_v1":
    riverLayers = bindLayerShell(cast[pointer](registry), name)
    ensureLayerObjects()
  of "zwlr_output_manager_v1":
    outputController = bindOutputManager(cast[pointer](registry), name, version, activeConfig.outputs)
  of "wl_compositor":
    compositor = cast[ptr WlCompositor](wl_registry_bind(registry, name,
      cast[pointer](addr wl_compositor_interface), min(version, 4'u32)))
  of "wl_shm":
    sharedMemory = cast[ptr WlShm](wl_registry_bind(registry, name,
      cast[pointer](addr wl_shm_interface), 1))
  of "wl_output":
    if not ipcServer.isNil and version >= 4:
      let info = OutputInfo(globalName: name,
        obj: cast[ptr WlOutput](wl_registry_bind(registry, name,
          cast[pointer](addr wl_output_interface), 4)))
      outputInfos.add(info)
      discard wl_output_add_listener(info.obj,
        cast[pointer](addr wlOutputListener), cast[pointer](info))
  else:
    discard

proc initializeListeners() =
  wmListener = makeListener(cast[pointer](wmUnavailable), cast[pointer](wmFinished),
    cast[pointer](manageStart), cast[pointer](renderStart), cast[pointer](wmNoop),
    cast[pointer](wmNoop), cast[pointer](wmNewWindow), cast[pointer](wmNewOutput),
    cast[pointer](wmNewSeat))
  windowListener = makeListener(cast[pointer](windowClosed),
    cast[pointer](windowDimensionsHint), cast[pointer](windowDimensions),
    cast[pointer](windowAppId), cast[pointer](windowTitle),
    cast[pointer](windowParentHint), cast[pointer](windowDecorationHint),
    cast[pointer](windowPointerMoveRequested), cast[pointer](windowPointerResizeRequested),
    cast[pointer](windowMenuHint), cast[pointer](windowNoop), cast[pointer](windowNoop),
    cast[pointer](windowFullscreenHint), cast[pointer](windowNoop),
    cast[pointer](windowNoop), cast[pointer](windowIntHint),
    cast[pointer](windowUintHint), cast[pointer](windowStringHint))
  outputListener = makeListener(cast[pointer](outputRemoved), cast[pointer](outputWlOutput),
    cast[pointer](outputPosition), cast[pointer](outputDimensions))
  seatListener = makeListener(cast[pointer](seatRemoved), cast[pointer](seatWlSeat),
    cast[pointer](seatPointerEnter), cast[pointer](seatPointerLeave),
    cast[pointer](seatWindowInteraction), cast[pointer](seatShellInteraction),
    cast[pointer](seatOpDelta), cast[pointer](seatOpRelease), cast[pointer](seatPosition))
  xkbBindingListener = makeListener(cast[pointer](xkbPressed), cast[pointer](xkbNoop),
    cast[pointer](xkbNoop))
  pointerBindingListener = makeListener(cast[pointer](pointerPressed), cast[pointer](pointerNoop))
  registryListener = makeListener(cast[pointer](registryGlobal), cast[pointer](registryGlobalRemove))
  bufferListener = makeListener(cast[pointer](bufferReleased))
  wlOutputListener = makeListener(cast[pointer](wlOutputGeometry),
    cast[pointer](wlOutputMode), cast[pointer](wlOutputDone),
    cast[pointer](wlOutputScale), cast[pointer](wlOutputName),
    cast[pointer](wlOutputDescription))

proc dispatchDesktop(display: ptr WlDisplay; fds: var seq[TPollfd]): bool =
  if ipcServer.isNil:
    return wl_display_dispatch(display) >= 0
  if stopRequested: return true
  while wl_display_prepare_read(display) != 0:
    if wl_display_dispatch_pending(display) < 0: return false
    if stopRequested: return true
  var events = POLLIN
  if wl_display_flush(display) < 0:
    if errno == EAGAIN:
      events = events or POLLOUT
    else:
      wl_display_cancel_read(display)
      return false
  fds.setLen(0)
  fds.add(TPollfd(fd: wl_display_get_fd(display), events: events))
  fds.add(TPollfd(fd: stopPipe[0], events: POLLIN))
  ipcServer.appendPollFds(fds)
  if poll(addr fds[0], fds.len.Tnfds, -1) < 0:
    wl_display_cancel_read(display)
    return errno == EINTR
  if stopRequested:
    wl_display_cancel_read(display)
    return true
  if (fds[0].revents and POLLIN) != 0:
    if wl_display_read_events(display) < 0: return false
  else:
    wl_display_cancel_read(display)
  if (fds[0].revents and (POLLERR or POLLHUP or POLLNVAL)) != 0: return false
  if (fds[0].revents and POLLOUT) != 0 and wl_display_flush(display) < 0 and errno != EAGAIN:
    return false
  if wl_display_dispatch_pending(display) < 0: return false
  ipcServer.dispatch(fds)
  let requests = ipcServer.takeCommands()
  if requests.len > 0:
    waitingIpcCommands.add(requests)
    river_window_manager_v1_manage_dirty(windowManager)
  if not ipcExitReady:
    for request in exitingIpcCommands:
      if ipcServer.commandReplySent(request):
        ipcExitReady = true
        exitingIpcCommands.setLen(0)
        river_window_manager_v1_manage_dirty(windowManager)
        break
  true

proc main() =
  try:
    let options = parseOptions(commandLineParams())
    if options.help:
      echo "Usage: nimzo [-c PATH | --config PATH] [--validate]"
      echo "Default configuration: ", defaultConfigPath()
      quit(0)
    configPath = options.path
    activeConfig = loadConfig(configPath, allowMissing = not options.explicitPath)
    if options.validate:
      echo "configuration loaded"
      quit(0)
  except ConfigError as error:
    stderr.writeLine(error.msg)
    quit(1)

  discard signal(SIGCHLD, SIG_IGN)
  ipcServer = startIpc(getEnv("SWAYSOCK"))
  if not ipcServer.isNil:
    addExitProc(proc() =
      ipcServer.close()
      for index in 0..1:
        let fd = stopPipe[index]
        stopPipe[index] = -1
        if fd >= 0: discard posix.close(fd))
    if pipe(stopPipe) < 0:
      stderr.writeLine("failed to create IPC signal wakeup pipe")
      quit(1)
    for fd in stopPipe:
      if fcntl(fd, F_SETFL, O_NONBLOCK) < 0 or fcntl(fd, F_SETFD, FD_CLOEXEC) < 0:
        stderr.writeLine("failed to configure IPC signal wakeup pipe")
        quit(1)
    discard signal(SIGTERM, stopForSignal)
    discard signal(SIGINT, stopForSignal)
  initializeListeners()
  let display = wl_display_connect(nil)
  if display.isNil:
    stderr.writeLine("failed to connect to Wayland server")
    quit(1)

  delEnv("WAYLAND_DEBUG")
  let registry = wl_display_get_registry(display)
  discard wl_registry_add_listener(registry, cast[pointer](addr registryListener), nil)
  if wl_display_roundtrip(display) < 0:
    stderr.writeLine("roundtrip failed")
    quit(1)
  requireInterfaces()

  if outputController.isNil and activeConfig.outputs.len > 0:
    stderr.writeLine("output configuration requires zwlr_output_manager_v1 version 4")
  if riverLayers.isNil:
    stderr.writeLine("warning: river_layer_shell_v1 unavailable; panels/wallpapers may not work")
  var pollFds: seq[TPollfd]
  while not stopRequested:
    if not dispatchDesktop(display, pollFds):
      stderr.writeLine("dispatch failed")
      quit(1)
  wl_display_disconnect(display)

when isMainModule:
  main()
