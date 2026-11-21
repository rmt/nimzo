# Save and restore workspaces and window placement when outputs disappear
# and return. Park windows on a private output if no real output is active.

import std/tables

proc wlr_headless_backend_create(loop: ptr wl_event_loop): ptr wlr_backend
  {.cdecl, importc.}
proc wlr_headless_add_output(backend: ptr wlr_backend; width, height: cuint): ptr wlr_output
  {.cdecl, importc.}

var
  parkingBackend: ptr wlr_backend
  savedOutputWorkspaces: Table[string, OutputWorkspaceState]

proc saveDisconnectedWorkspace(m: ptr Monitor) =
  if not wlr_box_empty(addr m.m):
    savedOutputWorkspaces[$m.wlr_output.name] = outputWorkspace(m)

proc restoreConnectedWorkspace(m: ptr Monitor) =
  let name = $m.wlr_output.name
  if savedOutputWorkspaces.hasKey(name):
    installOutputWorkspace(m, savedOutputWorkspaces[name])
    savedOutputWorkspaces.del(name)

proc forgetOutputPlacement(c: ptr Client) {.inline.} =
  if c.outputPlacement.output != nil:
    free(cast[pointer](c.outputPlacement.output))
    c.outputPlacement.output = nil

proc activeMonitor(): ptr Monitor =
  if selmon != nil and selmon != addr(parkingMonitor) and selmon.wlr_output.enabled:
    return selmon
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.enabled: return m
    m = wl_list_next_link(m)
  addr parkingMonitor

proc normalGeometry(c: ptr Client): wlr_box =
  if c.ismaximized: c.maximizeRestore
  elif c.isfullscreen != 0: c.prev
  else: c.geom

proc translated(box: wlr_box; dx, dy: cint): wlr_box {.inline.} =
  result = box
  result.x += dx
  result.y += dy

proc placeOutputClient(c: ptr Client; m: ptr Monitor; normal: wlr_box) =
  c.mon = m
  c.maximizeRestore = normal
  c.prev = if c.ismaximized: m.w else: normal
  if m == addr parkingMonitor:
    wlr_scene_node_set_enabled(addr c.scene.node, false)
  resize(c, if c.isfullscreen != 0: m.m elif c.ismaximized: m.w else: normal, 0)

proc restoreOutputClients(fallback: ptr Monitor) =
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    let saved = addr c.outputPlacement
    var m: ptr Monitor
    if saved.output != nil:
      m = wl_list_first_link(addr mons, m)
      while wl_list_more_link(m, addr mons):
        if m.wlr_output.enabled and strcmp(m.wlr_output.name, saved.output) == 0:
          c.tags = saved.tags
          c.zoneName = saved.zoneName
          c.zoneInitialized = saved.zoneInitialized
          if clientZoneName(c)[0] != '\0' and zoneClientIndex(c) < 0:
            clearClientZoneName(c)
            c.zoneInitialized = false
          placeOutputClient(c, m, translated(saved.normalGeometry, m.m.x, m.m.y))
          forgetOutputPlacement(c)
          initializeZoneClient(c)
          break
        m = wl_list_next_link(m)
    if c.mon == addr(parkingMonitor) and fallback != addr(parkingMonitor):
      placeOutputClient(c, fallback, translated(normalGeometry(c), fallback.m.x, fallback.m.y))
      initializeZoneClient(c)
    c = wl_list_next_link(c)

# Parked clients have no layout; retain their geometry until an output returns.
var parkingLayout = Layout(symbol: "", arrange: nil)

proc createParkingOutput() =
  # Do not start this backend or advertise its output. It owns an addressable
  # output for clients, but has no scanout, frames, cursor or shell surfaces.
  parkingBackend = wlr_headless_backend_create(event_loop)
  if parkingBackend == nil: die("couldn't create parking backend")
  parkingMonitor.wlr_output = wlr_headless_add_output(parkingBackend, 1920, 1080)
  if parkingMonitor.wlr_output == nil: die("couldn't create parking output")
  parkingMonitor.wlr_output.data = addr parkingMonitor
  parkingMonitor.m = wlr_box(width: 1920, height: 1080)
  parkingMonitor.w = parkingMonitor.m
  parkingMonitor.tagset = [1'u32, 1'u32]
  parkingMonitor.lt = [addr parkingLayout, addr parkingLayout]
  selmon = addr parkingMonitor

proc destroyParkingOutput() =
  wlr_backend_destroy(parkingBackend)

proc evacuateOutputClients(m: ptr Monitor) =
  selmon = activeMonitor()
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    if c.mon == m:
      let local = translated(normalGeometry(c), -m.m.x, -m.m.y)
      # Keep the original home if a temporary output also disappears.
      if c.outputPlacement.output == nil:
        c.outputPlacement = OutputPlacement(output: strdup(m.wlr_output.name),
          tags: c.tags, normalGeometry: local, zoneName: c.zoneName,
          zoneInitialized: c.zoneInitialized)
      placeOutputClient(c, selmon, translated(local, selmon.m.x, selmon.m.y))
    c = wl_list_next_link(c)
