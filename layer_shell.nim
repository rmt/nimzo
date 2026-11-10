# SPDX-License-Identifier: 0BSD

## River arranges/renders layer surfaces. The WM opts in, selects a default
## output, observes exclusive zones, and cooperates with layer keyboard focus.
import work_area

const Header = "river-layer-shell-v1-client-protocol.h"
{.compile: "protocol/river-layer-shell-v1-protocol.c".}

type
  NativeShell {.importc: "struct river_layer_shell_v1", header: Header, incompleteStruct.} = object
  NativeOutput {.importc: "struct river_layer_shell_output_v1", header: Header, incompleteStruct.} = object
  NativeSeat {.importc: "struct river_layer_shell_seat_v1", header: Header, incompleteStruct.} = object
  Interface {.importc: "struct wl_interface", header: "wayland-client.h", incompleteStruct.} = object
  LayerShell* = ptr NativeShell
  LayerFocus* = enum
    layerFocusNone, layerFocusNonExclusive, layerFocusExclusive
  LayerOutput* = ref object
    obj: ptr NativeOutput
    area*: Box
  LayerSeat* = ref object
    obj: ptr NativeSeat
    focus*: LayerFocus
    restoreFocus*: bool
    expectedNone: bool
  Listener = object
    callbacks: array[3, pointer]

proc wl_registry_bind(registry: pointer; name: uint32; iface: ptr Interface; version: uint32): pointer {.importc, header: "wayland-client.h".}
proc river_layer_shell_v1_get_output(obj: LayerShell; output: pointer): ptr NativeOutput {.importc, header: Header.}
proc river_layer_shell_v1_get_seat(obj: LayerShell; seat: pointer): ptr NativeSeat {.importc, header: Header.}
proc river_layer_shell_output_v1_add_listener(obj: ptr NativeOutput; listener, data: pointer): cint {.importc, header: Header.}
proc river_layer_shell_output_v1_set_default(obj: ptr NativeOutput) {.importc, header: Header.}
proc river_layer_shell_output_v1_destroy(obj: ptr NativeOutput) {.importc, header: Header.}
proc river_layer_shell_seat_v1_add_listener(obj: ptr NativeSeat; listener, data: pointer): cint {.importc, header: Header.}
proc river_layer_shell_seat_v1_destroy(obj: ptr NativeSeat) {.importc, header: Header.}
var river_layer_shell_v1_interface {.importc, header: Header.}: Interface

proc areaChanged(data: pointer; obj: ptr NativeOutput; x, y, width, height: int32) {.cdecl.} =
  cast[LayerOutput](data).area = Box(x: x, y: y, width: width, height: height)

proc exclusive(data: pointer; obj: ptr NativeSeat) {.cdecl.} =
  let seat = cast[LayerSeat](data)
  seat.focus = layerFocusExclusive
  seat.restoreFocus = false
  seat.expectedNone = false

proc nonExclusive(data: pointer; obj: ptr NativeSeat) {.cdecl.} =
  let seat = cast[LayerSeat](data)
  seat.focus = layerFocusNonExclusive
  seat.restoreFocus = false
  seat.expectedNone = false

proc noFocus(data: pointer; obj: ptr NativeSeat) {.cdecl.} =
  let seat = cast[LayerSeat](data)
  seat.focus = layerFocusNone
  seat.restoreFocus = not seat.expectedNone
  seat.expectedNone = false

var outputListener = Listener(callbacks: [cast[pointer](areaChanged), nil, nil])
var seatListener = Listener(callbacks: [cast[pointer](exclusive), cast[pointer](nonExclusive), cast[pointer](noFocus)])

proc bindLayerShell*(registry: pointer; name: uint32): LayerShell =
  cast[LayerShell](wl_registry_bind(registry, name, addr river_layer_shell_v1_interface, 1))

proc createLayerOutput*(shell: LayerShell; output: pointer): LayerOutput =
  result = LayerOutput(obj: river_layer_shell_v1_get_output(shell, output))
  discard river_layer_shell_output_v1_add_listener(result.obj, addr outputListener, cast[pointer](result))

proc createLayerSeat*(shell: LayerShell; seat: pointer): LayerSeat =
  result = LayerSeat(obj: river_layer_shell_v1_get_seat(shell, seat))
  discard river_layer_shell_seat_v1_add_listener(result.obj, addr seatListener, cast[pointer](result))

proc setDefault*(output: LayerOutput) =
  river_layer_shell_output_v1_set_default(output.obj)

proc destroy*(output: LayerOutput) =
  if not output.isNil: river_layer_shell_output_v1_destroy(output.obj)

proc destroy*(seat: LayerSeat) =
  if not seat.isNil: river_layer_shell_seat_v1_destroy(seat.obj)

proc hasLayerFocus*(seat: LayerSeat): bool =
  not seat.isNil and seat.focus != layerFocusNone

proc exclusiveFocus*(seat: LayerSeat): bool =
  not seat.isNil and seat.focus == layerFocusExclusive

proc needsRestore*(seat: LayerSeat): bool =
  not seat.isNil and seat.restoreFocus

proc claimWindowFocus*(seat: LayerSeat) =
  if seat.isNil: return
  seat.expectedNone = seat.focus == layerFocusNonExclusive
  seat.focus = layerFocusNone
  seat.restoreFocus = false
