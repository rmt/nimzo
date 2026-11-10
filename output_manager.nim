# SPDX-License-Identifier: 0BSD

## Asynchronous output configuration. Never block River's WM event loop while
## waiting for a modeset: River needs that same loop to complete the modeset.
import output_layout

const Header = "wlr-output-management-unstable-v1-client-protocol.h"
{.compile: "protocol/wlr-output-management-unstable-v1-protocol.c".}

type
  Manager {.importc: "struct zwlr_output_manager_v1", header: Header, incompleteStruct.} = object
  Head {.importc: "struct zwlr_output_head_v1", header: Header, incompleteStruct.} = object
  Mode {.importc: "struct zwlr_output_mode_v1", header: Header, incompleteStruct.} = object
  Configuration {.importc: "struct zwlr_output_configuration_v1", header: Header, incompleteStruct.} = object
  ConfigurationHead {.importc: "struct zwlr_output_configuration_head_v1", header: Header, incompleteStruct.} = object
  Interface {.importc: "struct wl_interface", header: "wayland-client.h", incompleteStruct.} = object
  Listener = object
    callbacks: array[14, pointer]
  OutputController* = ref object
    obj: ptr Manager
    heads: seq[NativeHead]
    rules: seq[OutputRule]
    snapshot, lastInput: seq[OutputState]
    generation, lastGeneration: int
    serial, submittedSerial: uint32
    ready, updating: bool
    pending: ptr Configuration
    pendingHeads: seq[ptr ConfigurationHead]
  NativeHead = ref object
    obj: ptr Head
    owner: OutputController
    state: OutputState
    modes: seq[NativeMode]
    currentMode: NativeMode
    finished: bool
  NativeMode = ref object
    obj: ptr Mode
    head: NativeHead
    state: OutputMode
    preferred: bool

proc wl_registry_bind(registry: pointer; name: uint32; iface: ptr Interface; version: uint32): pointer {.importc, header: "wayland-client.h".}
proc zwlr_output_manager_v1_add_listener(obj: ptr Manager; listener, data: pointer): cint {.importc, header: Header.}
proc zwlr_output_manager_v1_destroy(obj: ptr Manager) {.importc, header: Header.}
proc zwlr_output_manager_v1_create_configuration(obj: ptr Manager; serial: uint32): ptr Configuration {.importc, header: Header.}
proc zwlr_output_head_v1_add_listener(obj: ptr Head; listener, data: pointer): cint {.importc, header: Header.}
proc zwlr_output_head_v1_release(obj: ptr Head) {.importc, header: Header.}
proc zwlr_output_mode_v1_add_listener(obj: ptr Mode; listener, data: pointer): cint {.importc, header: Header.}
proc zwlr_output_mode_v1_release(obj: ptr Mode) {.importc, header: Header.}
proc zwlr_output_configuration_v1_add_listener(obj: ptr Configuration; listener, data: pointer): cint {.importc, header: Header.}
proc zwlr_output_configuration_v1_enable_head(obj: ptr Configuration; head: ptr Head): ptr ConfigurationHead {.importc, header: Header.}
proc zwlr_output_configuration_v1_disable_head(obj: ptr Configuration; head: ptr Head) {.importc, header: Header.}
proc zwlr_output_configuration_v1_apply(obj: ptr Configuration) {.importc, header: Header.}
proc zwlr_output_configuration_v1_destroy(obj: ptr Configuration) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_destroy(obj: ptr ConfigurationHead) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_set_mode(obj: ptr ConfigurationHead; mode: ptr Mode) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_set_custom_mode(obj: ptr ConfigurationHead; width, height, refresh: int32) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_set_position(obj: ptr ConfigurationHead; x, y: int32) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_set_scale(obj: ptr ConfigurationHead; scale: int32) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_set_transform(obj: ptr ConfigurationHead; transform: int32) {.importc, header: Header.}
proc zwlr_output_configuration_head_v1_set_adaptive_sync(obj: ptr ConfigurationHead; state: uint32) {.importc, header: Header.}
var zwlr_output_manager_v1_interface {.importc, header: Header.}: Interface
var managerListener, headListener, modeListener, configurationListener: Listener

proc attempt(controller: OutputController)

proc listener(callbacks: varargs[pointer]): Listener =
  for i, callback in callbacks: result.callbacks[i] = callback

proc findMode(head: NativeHead; desired: OutputMode): NativeMode =
  for mode in head.modes:
    if mode.state.width == desired.width and mode.state.height == desired.height and
        (desired.refresh == 0 or desired.refresh == mode.state.refresh):
      if result.isNil or mode == head.currentMode or
          (result != head.currentMode and mode.preferred):
        result = mode

proc finish(controller: OutputController) =
  for head in controller.pendingHeads:
    zwlr_output_configuration_head_v1_destroy(head)
  controller.pendingHeads = @[]
  zwlr_output_configuration_v1_destroy(controller.pending)
  controller.pending = nil

proc succeeded(data: pointer; obj: ptr Configuration) {.cdecl.} =
  let controller = cast[OutputController](data)
  controller.finish()
  controller.attempt()

proc failed(data: pointer; obj: ptr Configuration) {.cdecl.} =
  let controller = cast[OutputController](data)
  controller.finish()
  stderr.writeLine("output configuration was rejected; previous output layout retained")
  # Retry only when the input state or rules change, not on every WM frame.
  controller.attempt()

proc cancelled(data: pointer; obj: ptr Configuration) {.cdecl.} =
  let controller = cast[OutputController](data)
  controller.finish()
  controller.lastGeneration = -1
  if controller.serial != controller.submittedSerial:
    controller.attempt() # Otherwise wait for a newer manager.done snapshot.

proc attempt(controller: OutputController) =
  if controller.obj.isNil or not controller.ready or controller.updating or
      not controller.pending.isNil or controller.rules.len == 0:
    return
  if controller.lastGeneration == controller.generation and
      controller.lastInput == controller.snapshot:
    return
  controller.lastGeneration = controller.generation
  controller.lastInput = controller.snapshot
  var planned: seq[OutputState]
  var modes: seq[NativeMode]
  try:
    planned = resolveOutputs(controller.rules, controller.snapshot)
    for i in 0..<planned.len:
      if not planned[i].enabled:
        modes.add(nil)
        continue
      let mode = findMode(controller.heads[i], planned[i].mode)
      modes.add(mode)
      if not mode.isNil:
        planned[i].mode = mode.state
      elif controller.heads[i].modes.len > 0:
        raise newException(OutputError, "no matching mode for output '" & planned[i].name & "'")
    if planned == controller.snapshot: return
  except OutputError as error:
    stderr.writeLine("output configuration not applied: ", error.msg)
    return

  controller.pending = zwlr_output_manager_v1_create_configuration(controller.obj, controller.serial)
  controller.submittedSerial = controller.serial
  discard zwlr_output_configuration_v1_add_listener(controller.pending,
    addr configurationListener, cast[pointer](controller))
  for i, state in planned:
    let head = controller.heads[i]
    if not state.enabled:
      zwlr_output_configuration_v1_disable_head(controller.pending, head.obj)
      continue
    let configuration = zwlr_output_configuration_v1_enable_head(controller.pending, head.obj)
    controller.pendingHeads.add(configuration)
    if not modes[i].isNil:
      zwlr_output_configuration_head_v1_set_mode(configuration, modes[i].obj)
    else:
      zwlr_output_configuration_head_v1_set_custom_mode(configuration,
        state.mode.width, state.mode.height, state.mode.refresh)
    zwlr_output_configuration_head_v1_set_position(configuration, state.x, state.y)
    zwlr_output_configuration_head_v1_set_transform(configuration, state.transform)
    zwlr_output_configuration_head_v1_set_scale(configuration, state.scale)
    zwlr_output_configuration_head_v1_set_adaptive_sync(configuration, state.adaptiveSync.uint32)
  zwlr_output_configuration_v1_apply(controller.pending)

proc topologyChanged(controller: OutputController) =
  controller.updating = true
  # Mode availability/head identity can change without changing current geometry.
  controller.lastGeneration = -1

proc modeSize(data: pointer; obj: ptr Mode; width, height: int32) {.cdecl.} =
  let mode = cast[NativeMode](data)
  mode.head.owner.topologyChanged()
  mode.state.width = width
  mode.state.height = height

proc modeRefresh(data: pointer; obj: ptr Mode; refresh: int32) {.cdecl.} =
  let mode = cast[NativeMode](data)
  mode.head.owner.topologyChanged()
  mode.state.refresh = refresh

proc modePreferred(data: pointer; obj: ptr Mode) {.cdecl.} =
  let mode = cast[NativeMode](data)
  mode.head.owner.topologyChanged()
  mode.preferred = true

proc modeFinished(data: pointer; obj: ptr Mode) {.cdecl.} =
  let mode = cast[NativeMode](data)
  let head = mode.head
  head.owner.topologyChanged()
  if head.currentMode == mode: head.currentMode = nil
  for i, candidate in head.modes:
    if candidate == mode:
      head.modes.delete(i)
      break
  zwlr_output_mode_v1_release(obj)

proc headName(data: pointer; obj: ptr Head; name: cstring) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  head.state.name = $name

proc headString(data: pointer; obj: ptr Head; text: cstring) {.cdecl.} =
  cast[NativeHead](data).owner.updating = true

proc headPhysicalSize(data: pointer; obj: ptr Head; width, height: int32) {.cdecl.} =
  cast[NativeHead](data).owner.updating = true

proc headMode(data: pointer; obj: ptr Head; nativeMode: ptr Mode) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.topologyChanged()
  let mode = NativeMode(obj: nativeMode, head: head)
  head.modes.add(mode)
  discard zwlr_output_mode_v1_add_listener(nativeMode, addr modeListener, cast[pointer](mode))

proc headEnabled(data: pointer; obj: ptr Head; enabled: int32) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  head.state.enabled = enabled != 0

proc headCurrentMode(data: pointer; obj: ptr Head; nativeMode: ptr Mode) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  for mode in head.modes:
    if mode.obj == nativeMode:
      head.currentMode = mode
      break

proc headPosition(data: pointer; obj: ptr Head; x, y: int32) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  head.state.x = x
  head.state.y = y

proc headTransform(data: pointer; obj: ptr Head; transform: int32) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  head.state.transform = transform

proc headScale(data: pointer; obj: ptr Head; scale: int32) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  head.state.scale = scale

proc headAdaptiveSync(data: pointer; obj: ptr Head; state: uint32) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.updating = true
  head.state.adaptiveSync = state != 0

proc headFinished(data: pointer; obj: ptr Head) {.cdecl.} =
  let head = cast[NativeHead](data)
  head.owner.topologyChanged()
  head.finished = true
  zwlr_output_head_v1_release(obj)

proc managerHead(data: pointer; obj: ptr Manager; nativeHead: ptr Head) {.cdecl.} =
  let controller = cast[OutputController](data)
  controller.topologyChanged()
  let head = NativeHead(obj: nativeHead, owner: controller, state: OutputState(scale: 256))
  controller.heads.add(head)
  discard zwlr_output_head_v1_add_listener(nativeHead, addr headListener, cast[pointer](head))

proc managerDone(data: pointer; obj: ptr Manager; serial: uint32) {.cdecl.} =
  let controller = cast[OutputController](data)
  var heads: seq[NativeHead]
  var states: seq[OutputState]
  for head in controller.heads:
    if head.finished: continue
    heads.add(head)
    var state = head.state
    if not head.currentMode.isNil:
      state.mode = head.currentMode.state
    elif head.modes.len > 0:
      state.mode = head.modes[0].state
      for mode in head.modes:
        if mode.preferred: state.mode = mode.state
    states.add(state)
  controller.heads = heads
  controller.snapshot = states
  controller.serial = serial
  controller.ready = true
  controller.updating = false
  controller.attempt()

proc managerFinished(data: pointer; obj: ptr Manager) {.cdecl.} =
  let controller = cast[OutputController](data)
  zwlr_output_manager_v1_destroy(obj)
  controller.obj = nil
  stderr.writeLine("output management is no longer available")

proc setRules*(controller: OutputController; rules: seq[OutputRule]) =
  controller.rules = rules
  inc controller.generation
  controller.attempt()

proc bindOutputManager*(registry: pointer; name, version: uint32;
    rules: seq[OutputRule]): OutputController =
  if version < 4: return nil
  managerListener = listener(cast[pointer](managerHead), cast[pointer](managerDone), cast[pointer](managerFinished))
  headListener = listener(cast[pointer](headName), cast[pointer](headString),
    cast[pointer](headPhysicalSize), cast[pointer](headMode), cast[pointer](headEnabled),
    cast[pointer](headCurrentMode), cast[pointer](headPosition), cast[pointer](headTransform),
    cast[pointer](headScale), cast[pointer](headFinished), cast[pointer](headString),
    cast[pointer](headString), cast[pointer](headString), cast[pointer](headAdaptiveSync))
  modeListener = listener(cast[pointer](modeSize), cast[pointer](modeRefresh),
    cast[pointer](modePreferred), cast[pointer](modeFinished))
  configurationListener = listener(cast[pointer](succeeded), cast[pointer](failed), cast[pointer](cancelled))
  let obj = cast[ptr Manager](wl_registry_bind(registry, name, addr zwlr_output_manager_v1_interface, 4))
  result = OutputController(obj: obj, rules: rules, lastGeneration: -1)
  discard zwlr_output_manager_v1_add_listener(obj, addr managerListener, cast[pointer](result))
