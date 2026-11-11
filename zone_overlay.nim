# SPDX-FileCopyrightText: © 2026 Isaac Freund
# SPDX-License-Identifier: 0BSD

import std/[os, posix, tempfiles]
import work_area

{.passC: "-Iprotocol".}

type
  WlCompositor {.importc: "struct wl_compositor", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlRegion {.importc: "struct wl_region", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlSurface {.importc: "struct wl_surface", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlBuffer {.importc: "struct wl_buffer", header: "wayland-client-protocol.h", incompleteStruct.} = object
  WlShm {.importc: "struct wl_shm", header: "wayland-client-protocol.h", incompleteStruct.} = object

  RiverWindowManager {.importc: "struct river_window_manager_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverShellSurface {.importc: "struct river_shell_surface_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object
  RiverNode {.importc: "struct river_node_v1", header: "river-window-management-v1-client-protocol.h", incompleteStruct.} = object

  WlBufferListener = object
    release: pointer

  OverlayBuffer = ref object
    obj: ptr WlBuffer
    width, height: int32
    released: bool
    owner: ZoneOverlay

  ZoneOverlay* = ref object
    manager: ptr RiverWindowManager
    surface: ptr WlSurface
    shell: ptr RiverShellSurface
    node: ptr RiverNode
    shm: ptr WlShm
    buffers: seq[OverlayBuffer]
    buffer: OverlayBuffer
    bounds: Box
    deferred, visible, destroyed: bool

proc wl_compositor_create_surface(obj: ptr WlCompositor): ptr WlSurface {.importc, header: "wayland-client-protocol.h".}
proc wl_compositor_create_region(obj: ptr WlCompositor): ptr WlRegion {.importc, header: "wayland-client-protocol.h".}
proc wl_region_destroy(obj: ptr WlRegion) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_set_input_region(obj: ptr WlSurface; region: ptr WlRegion) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_attach(obj: ptr WlSurface; buffer: ptr WlBuffer; x, y: int32) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_damage(obj: ptr WlSurface; x, y, width, height: int32) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_commit(obj: ptr WlSurface) {.importc, header: "wayland-client-protocol.h".}
proc wl_surface_destroy(obj: ptr WlSurface) {.importc, header: "wayland-client-protocol.h".}
proc wl_shm_create_pool(obj: ptr WlShm; fd, size: int32): pointer {.importc, header: "wayland-client-protocol.h".}
proc wl_shm_pool_create_buffer(obj: pointer; offset, width, height, stride: int32; format: uint32): ptr WlBuffer {.importc, header: "wayland-client-protocol.h".}
proc wl_shm_pool_destroy(obj: pointer) {.importc, header: "wayland-client-protocol.h".}
proc wl_buffer_add_listener(obj: ptr WlBuffer; listener, data: pointer): cint {.importc, header: "wayland-client-protocol.h".}
proc wl_buffer_destroy(obj: ptr WlBuffer) {.importc, header: "wayland-client-protocol.h".}

proc river_window_manager_v1_get_shell_surface(obj: ptr RiverWindowManager; surface: ptr WlSurface): ptr RiverShellSurface {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_window_manager_v1_manage_dirty(obj: ptr RiverWindowManager) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_shell_surface_v1_destroy(obj: ptr RiverShellSurface) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_shell_surface_v1_get_node(obj: ptr RiverShellSurface): ptr RiverNode {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_shell_surface_v1_sync_next_commit(obj: ptr RiverShellSurface) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_node_v1_destroy(obj: ptr RiverNode) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_node_v1_set_position(obj: ptr RiverNode; x, y: int32) {.importc, header: "river-window-management-v1-client-protocol.h".}
proc river_node_v1_place_top(obj: ptr RiverNode) {.importc, header: "river-window-management-v1-client-protocol.h".}

var liveBuffers: seq[OverlayBuffer]

proc removeLiveBuffer(buffer: OverlayBuffer) =
  var i = 0
  while i < liveBuffers.len:
    if liveBuffers[i] == buffer:
      liveBuffers.delete(i)
      return
    inc i

proc removeOverlayBuffer(overlay: ZoneOverlay; buffer: OverlayBuffer) =
  var i = 0
  while i < overlay.buffers.len:
    if overlay.buffers[i] == buffer:
      overlay.buffers.delete(i)
      return
    inc i

proc destroyReleasedBuffer(overlay: ZoneOverlay; buffer: OverlayBuffer) =
  if buffer.isNil or not buffer.released:
    return
  if overlay.buffer == buffer:
    overlay.buffer = nil
  removeOverlayBuffer(overlay, buffer)
  removeLiveBuffer(buffer)
  if not buffer.obj.isNil:
    wl_buffer_destroy(buffer.obj)
    buffer.obj = nil

proc overlayBufferReleased(data: pointer; obj: ptr WlBuffer) {.cdecl.} =
  let buffer = cast[OverlayBuffer](data)
  if buffer.isNil:
    wl_buffer_destroy(obj)
    return
  buffer.released = true
  let owner = buffer.owner
  if owner.isNil or owner.destroyed:
    removeLiveBuffer(buffer)
    if not buffer.obj.isNil:
      wl_buffer_destroy(buffer.obj)
      buffer.obj = nil
    return
  if owner.deferred and not owner.manager.isNil:
    river_window_manager_v1_manage_dirty(owner.manager)
  # Keep released storage around so a hide/show of the same size does not
  # allocate another shm file. It is reclaimed when the two-buffer cap needs
  # to make room or when the overlay is destroyed.

var overlayBufferListener = WlBufferListener(release: cast[pointer](overlayBufferReleased))

proc createOverlayBuffer(overlay: ZoneOverlay; width, height: int32): OverlayBuffer =
  if width <= 0 or height <= 0:
    return nil
  let byteCount = width.int64 * height.int64 * 4
  if byteCount <= 0 or byteCount > high(int32).int64:
    return nil

  var file: File
  try:
    let temporary = createTempFile("nimzo-zone-", "")
    file = temporary.cfile
    removeFile(temporary.path)
  except OSError as error:
    if not file.isNil:
      file.close()
    stderr.writeLine("failed to create zone overlay storage: ", error.msg)
    return nil
  defer: file.close()

  let fd = file.getFileHandle()
  if ftruncate(fd, byteCount.Off) < 0:
    stderr.writeLine("failed to size zone overlay storage: ", osErrorMsg(osLastError()))
    return nil
  let mapping = mmap(nil, byteCount.int, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  if mapping == MAP_FAILED:
    stderr.writeLine("failed to map zone overlay storage: ", osErrorMsg(osLastError()))
    return nil

  # ARGB8888 is premultiplied. The fill is translucent blue and the border is
  # deliberately more opaque so the zone remains visible over any client.
  const fillPixel = 0x6000004E'u32 # A=0x60, premultiplied B=0x4e
  const borderPixel = 0xD00000B7'u32 # A=0xd0, premultiplied B=0xb7
  let pixels = cast[ptr UncheckedArray[uint32]](mapping)
  for y in 0 ..< height.int:
    for x in 0 ..< width.int:
      let border = x < 2 or y < 2 or x >= width.int - 2 or y >= height.int - 2
      pixels[y * width.int + x] = if border: borderPixel else: fillPixel
  discard munmap(mapping, byteCount.int)

  let pool = wl_shm_create_pool(overlay.shm, fd, byteCount.int32)
  if pool.isNil:
    return nil
  let wlBuffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, 0'u32)
  wl_shm_pool_destroy(pool)
  if wlBuffer.isNil:
    return nil

  let buffer = OverlayBuffer(obj: wlBuffer, width: width, height: height,
    released: false, owner: overlay)
  if wl_buffer_add_listener(wlBuffer, cast[pointer](addr overlayBufferListener),
      cast[pointer](buffer)) < 0:
    wl_buffer_destroy(wlBuffer)
    return nil
  liveBuffers.add(buffer)
  overlay.buffers.add(buffer)
  buffer

proc evictReleasedBuffer(overlay: ZoneOverlay): bool =
  var i = 0
  while i < overlay.buffers.len:
    let buffer = overlay.buffers[i]
    if buffer.released:
      destroyReleasedBuffer(overlay, buffer)
      return true
    inc i
  false

proc acquireBuffer(overlay: ZoneOverlay; width, height: int32): OverlayBuffer =
  for buffer in overlay.buffers:
    if buffer.width == width and buffer.height == height and buffer.released:
      buffer.released = false
      return buffer
  while overlay.buffers.len >= 2:
    if not evictReleasedBuffer(overlay):
      return nil
  createOverlayBuffer(overlay, width, height)

proc newZoneOverlay*(manager, compositor, shm: pointer): ZoneOverlay =
  if manager.isNil or compositor.isNil or shm.isNil:
    return nil
  let wm = cast[ptr RiverWindowManager](manager)
  let comp = cast[ptr WlCompositor](compositor)
  let sharedMemory = cast[ptr WlShm](shm)
  let surface = wl_compositor_create_surface(comp)
  if surface.isNil:
    return nil
  let region = wl_compositor_create_region(comp)
  if region.isNil:
    wl_surface_destroy(surface)
    return nil
  # An empty input region makes this surface entirely click-through.
  wl_surface_set_input_region(surface, region)
  wl_region_destroy(region)

  let shell = river_window_manager_v1_get_shell_surface(wm, surface)
  if shell.isNil:
    wl_surface_destroy(surface)
    return nil
  let node = river_shell_surface_v1_get_node(shell)
  if node.isNil:
    river_shell_surface_v1_destroy(shell)
    wl_surface_destroy(surface)
    return nil
  ZoneOverlay(manager: wm, surface: surface, shell: shell, node: node,
    shm: sharedMemory)

proc hideOverlay(overlay: ZoneOverlay; clearDeferred: bool) =
  if clearDeferred:
    overlay.deferred = false
  if not overlay.visible:
    return
  river_shell_surface_v1_sync_next_commit(overlay.shell)
  wl_surface_attach(overlay.surface, nil, 0, 0)
  wl_surface_commit(overlay.surface)
  overlay.visible = false

proc show*(overlay: ZoneOverlay; bounds: Box) =
  if overlay.isNil or overlay.destroyed or not bounds.valid:
    return
  if overlay.visible and not overlay.deferred and
      overlay.bounds.x == bounds.x and overlay.bounds.y == bounds.y and
      overlay.bounds.width == bounds.width and overlay.bounds.height == bounds.height:
    # The shell is already committed at this size; place_top is a rendering
    # request and does not need a matching surface commit.
    river_node_v1_place_top(overlay.node)
    return

  let sizeChanged = overlay.buffer.isNil or overlay.buffer.width != bounds.width or
    overlay.buffer.height != bounds.height
  var buffer = overlay.buffer
  if not overlay.visible or sizeChanged:
    # A detached buffer may still be in use until its release event.
    buffer = acquireBuffer(overlay, bounds.width, bounds.height)
    if buffer.isNil:
      # Do not leave an old-sized overlay visible while waiting for release.
      # The release callback dirties the manager to retry this show.
      overlay.deferred = true
      hideOverlay(overlay, clearDeferred = false)
      return
    overlay.buffer = buffer

  river_node_v1_set_position(overlay.node, bounds.x, bounds.y)
  river_node_v1_place_top(overlay.node)
  river_shell_surface_v1_sync_next_commit(overlay.shell)
  if not overlay.visible or sizeChanged:
    wl_surface_attach(overlay.surface, buffer.obj, 0, 0)
    wl_surface_damage(overlay.surface, 0, 0, bounds.width, bounds.height)
  wl_surface_commit(overlay.surface)
  overlay.bounds = bounds
  overlay.deferred = false
  overlay.visible = true

proc hide*(overlay: ZoneOverlay) =
  if overlay.isNil or overlay.destroyed:
    return
  hideOverlay(overlay, clearDeferred = true)

proc destroy*(overlay: ZoneOverlay) =
  if overlay.isNil or overlay.destroyed:
    return
  if overlay.visible:
    hide(overlay)
  overlay.destroyed = true
  for buffer in overlay.buffers:
    buffer.owner = nil
    if buffer.released:
      removeLiveBuffer(buffer)
      if not buffer.obj.isNil:
        wl_buffer_destroy(buffer.obj)
        buffer.obj = nil
  overlay.buffers.setLen(0)
  overlay.buffer = nil
  if not overlay.node.isNil:
    river_node_v1_destroy(overlay.node)
    overlay.node = nil
  if not overlay.shell.isNil:
    river_shell_surface_v1_destroy(overlay.shell)
    overlay.shell = nil
  if not overlay.surface.isNil:
    wl_surface_destroy(overlay.surface)
    overlay.surface = nil
