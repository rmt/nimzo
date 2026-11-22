# Test that workspaces and windows keep their state when outputs swap
# contents, lose power, disconnect, or reconnect.

const VERSION = "output-test"
include ../nimzo_core
include headless_support
include keyboard_support

proc wlr_multi_backend_add(multi, child: ptr wlr_backend): bool
  {.cdecl, importc.}
proc wlr_output_destroy(output: ptr wlr_output)
  {.cdecl, importc.}
proc wlr_output_set_name(output: ptr wlr_output; name: cstring)
  {.cdecl, importc.}

proc reconnectOutput(name: cstring) =
  let child = wlr_headless_backend_create(event_loop)
  doAssert child != nil and wlr_multi_backend_add(backend, child)
  let output = wlr_headless_add_output(child, 800, 600)
  doAssert output != nil
  wlr_output_set_name(output, name)
  doAssert wlr_backend_start(child)

proc powerOutput(m: ptr Monitor; on: bool) =
  var event = wlr_output_power_v1_set_mode_event(output: m.wlr_output,
    mode: if on: ZWLR_OUTPUT_POWER_V1_MODE_ON else: ZWLR_OUTPUT_POWER_V1_MODE_OFF)
  powermgrsetmode(nil, addr event)

var timer: ptr wl_event_source
var stage, attempts: int
let runtimeDir = headlessRuntime("nimzo-outputs-", 4)
let testConfig = runtimeDir / "config"
writeFile(testConfig, """
sway_ipc_restricted off
layout zones
zone A 0% 0% 100% 100%
bindsym Super+o focus output next
bindsym Super+Shift+o swap outputs
bindsym Super+Left workspace prev_on_output
bindsym Super+Right workspace next_on_output
bindsym Super+Shift+Left move container to workspace prev_on_output, workspace prev_on_output
bindsym Super+Shift+Right move container to workspace next_on_output, workspace next_on_output
output HEADLESS-1 default
output HEADLESS-1 mode 800x600
output HEADLESS-1 position 0 0
output HEADLESS-2 mode 640x480
output HEADLESS-2 position 0 600
output HEADLESS-3 mode 1024x768
output HEADLESS-3 position 0 1080
output HEADLESS-4 disable
exec "$NIMZO_ZONE_CLIENT" alpha
exec "$NIMZO_ZONE_CLIENT" beta
exec "$NIMZO_ZONE_CLIENT" gamma
exec "$NIMZO_ZONE_CLIENT" hidden
""")

proc monitor(name: string): ptr Monitor =
  var m: ptr Monitor
  m = wl_list_first_link(addr mons, m)
  while wl_list_more_link(m, addr mons):
    if m.wlr_output.name == name.cstring: return m
    m = wl_list_next_link(m)

proc outputKey(shift = false; code = uint32(KEY_O)) =
  key(uint32(KEY_LEFTMETA), true)
  if shift: key(uint32(KEY_LEFTSHIFT), true)
  key(code, true)
  key(code, false)
  if shift: key(uint32(KEY_LEFTSHIFT), false)
  key(uint32(KEY_LEFTMETA), false)

proc command(text: string) = discard executeSwayCommand(text)
var initial: array[3, OutputWorkspaceState]
var restoreBefore: wlr_box
var hiddenGeometry, betaGeometry, gammaGeometry: wlr_box

proc checkStage(): bool =
  let first = monitor("HEADLESS-1")
  let second = monitor("HEADLESS-2")
  let third = monitor("HEADLESS-3")
  let a = app("alpha")
  let b = app("beta")
  let c = app("gamma")
  let hidden = app("hidden")
  if a == nil or b == nil or c == nil or hidden == nil: return false
  var client: ptr Client
  client = wl_list_first_link(addr clients, client)
  while wl_list_more_link(client, addr clients):
    if client.resize_serial != 0: return false
    client = wl_list_next_link(client)
  case stage
  of 0:
    startTestKeyboard("output-test")
    # Real keyboard events must move/follow exactly once, on this output only.
    selmon = first
    focusclient(a, nil, 1)
    let remoteTags = second.tagset[second.seltags]
    outputKey(code = uint32(KEY_LEFT))
    doAssert first.tagset[first.seltags] == 256 and selmon == first
    outputKey(code = uint32(KEY_RIGHT))
    doAssert first.tagset[first.seltags] == 1
    outputKey(true, uint32(KEY_LEFT))
    doAssert a.tags == 256 and first.tagset[first.seltags] == 256
    doAssert focused_client == a and a.mon == first
    outputKey(true, uint32(KEY_RIGHT))
    doAssert a.tags == 1 and first.tagset[first.seltags] == 1
    doAssert focused_client == a and second.tagset[second.seltags] == remoteTags
    # Move-only is independent; IPC and bindings use the same relative commands.
    command("move container to workspace next_on_output")
    doAssert a.tags == 2 and first.tagset[first.seltags] == 1
    command("workspace --no-auto-back-and-forth next_on_output")
    doAssert first.tagset[first.seltags] == 2 and focused_client == a
    command("move container to workspace prev")
    command("workspace prev")
    doAssert a.tags == 1 and first.tagset[first.seltags] == 1
    doAssert focused_client == a
    setmon(b, second, 2)
    setmon(c, third, 4)
    hidden.tags = 8
    first.tagset = [1'u32, 8'u32]
    second.tagset = [2'u32, 16'u32]
    third.tagset = [4'u32, 32'u32]
    first.seltags = 0
    second.seltags = 0
    third.seltags = 0
    first.lt = [addr layouts[layoutMonocleIndex], addr layouts[layoutZonesIndex]]
    second.lt = [addr layouts[layoutMonocleIndex], addr layouts[layoutZonesIndex]]
    second.sellt = 1
    third.lt = [addr layouts[layoutZonesIndex], addr layouts[layoutMonocleIndex]]
    a.isfixed = 1
    resize(a, wlr_box(x: 40, y: 50, width: 200, height: 160), 0)
    setfloating(b, 1)
    resize(b, wlr_box(x: 50, y: 650, width: 300, height: 200), 0)
    restoreBefore = b.geom
    setfullscreen(b, 1)
    for m in [first, second, third]: arrange(m)
    initial = [outputWorkspace(first), outputWorkspace(second), outputWorkspace(third)]
    # Directional focus must move the pointer too, before focus-follows-mouse runs.
    proc checkPointer(destination: ptr Monitor) =
      doAssert selmon == destination
      doAssert abs(cursor.x - (cdouble(destination.w.x) + cdouble(destination.w.width) / 2)) < 1
      doAssert abs(cursor.y - (cdouble(destination.w.y) + cdouble(destination.w.height) / 2)) < 1
    command("focus output HEADLESS-1")
    command("focus output down")
    checkPointer(second)
    command("focus output up")
    checkPointer(first)
    discard wlr_output_layout_add(output_layout, third.wlr_output, 800, 0)
    command("focus output right")
    checkPointer(third)
    command("focus output left")
    checkPointer(first)
    discard wlr_output_layout_add(output_layout, third.wlr_output, 0, 1080)
    command("focus output HEADLESS-1")
    outputKey()
    doAssert selmon == second
    outputKey()
    doAssert selmon == third
    outputKey()
    doAssert selmon == first # Disabled HEADLESS-4 is skipped, including wrap.
    outputKey(true)
    doAssert a.mon == second and b.mon == third and c.mon == first
    doAssert hidden.mon == second and hidden.tags == 8 and not VISIBLEON(hidden, second)
    doAssert a.tags == 1 and b.tags == 2 and c.tags == 4
    doAssert a.isfixed == 1 and a.geom.width == 200 and a.geom.height == 160
    doAssert a.geom.x == 40 and a.geom.y == 650
    doAssert b.isfullscreen == 1 and b.isfloating == 1
    doAssert b.geom.x == third.m.x and b.geom.y == third.m.y
    doAssert b.geom.width == third.m.width and b.geom.height == third.m.height
    doAssert b.prev.y == restoreBefore.y + third.w.y - second.w.y
    doAssert outputWorkspace(first) == initial[2]
    doAssert outputWorkspace(second) == initial[0]
    doAssert outputWorkspace(third) == initial[1]
    doAssert selmon == first and focused_client == c
  of 1:
    outputKey(true)
    outputKey(true)
    doAssert a.mon == first and b.mon == second and c.mon == third and hidden.mon == first
    doAssert outputWorkspace(first) == initial[0]
    doAssert outputWorkspace(second) == initial[1]
    doAssert outputWorkspace(third) == initial[2]
    doAssert wlr_box_equal(addr b.prev, addr restoreBefore)
    command("swap outputs HEADLESS-1 HEADLESS-3")
    doAssert a.mon == third and hidden.mon == third and b.mon == second and c.mon == first
    doAssert outputWorkspace(first) == initial[2] and outputWorkspace(third) == initial[0]
    command("swap outputs HEADLESS-1 HEADLESS-3")
    command("focus output \"HEADLESS-2\"")
    doAssert selmon == second
    command("swap outputs HEADLESS-1")
    doAssert a.mon == second and hidden.mon == second and b.mon == first and c.mon == third
    doAssert outputWorkspace(first) == initial[1] and outputWorkspace(second) == initial[0]
    command("swap outputs HEADLESS-1")
    doAssert a.mon == first and b.mon == second
    let saved = outputWorkspace(first)
    try:
      command("swap outputs HEADLESS-1 HEADLESS-4")
      doAssert false, "disabled output accepted"
    except ValueError: discard
    doAssert a.mon == first and b.mon == second and outputWorkspace(first) == saved
    locked = 1
    try:
      runRuntimeAction(compileCommand("swap outputs", activeConfig))
      doAssert false, "locked rotation accepted"
    except ValueError: discard
    locked = 0
    doAssert a.mon == first and b.mon == second
    setfullscreen(b, 0)
    doAssert b.geom.width == restoreBefore.width and b.geom.height == restoreBefore.height
  of 2:
    betaGeometry = b.geom
    setfullscreen(b, 1)
    powerOutput(second, false)
    doAssert not second.wlr_output.enabled and b.mon != nil and b.mon != second
    powerOutput(second, true)
    doAssert b.mon == second and b.tags == 2 and b.geom == second.m and b.prev == betaGeometry

    setfloating(hidden, 1)
    hiddenGeometry = wlr_box(x: 55, y: 78, width: 235, height: 172)
    resize(hidden, hiddenGeometry, 0)
    gammaGeometry = c.geom
    setWindowMaximized(c, true)
    setWindowMinimized(c, true)

    selmon = third
    wlr_output_destroy(first.wlr_output)
    doAssert a.mon == third and hidden.mon == third and hidden.tags == 8
    third.tagset[third.seltags] = a.tags
    focusclient(a, nil, 1)
    command("move container to workspace 5")
    doAssert a.tags == 16
    wlr_output_destroy(second.wlr_output)
    doAssert b.mon == third and b.isfullscreen != 0
    wlr_output_destroy(monitor("HEADLESS-4").wlr_output)
    wlr_output_destroy(third.wlr_output)
    doAssert wl_list_empty(addr mons) != 0 and selmon == addr parkingMonitor
    for parked in [a, b, c, hidden]:
      doAssert parked.mon == selmon and not parked.scene.node.enabled
    shellCommand("\"$NIMZO_ZONE_CLIENT\" parked")
  of 3:
    let parked = app("parked")
    if parked == nil: return false
    doAssert parked.mon == selmon and not parked.scene.node.enabled
    reconnectOutput("HEADLESS-3")
    doAssert parked.mon == monitor("HEADLESS-3")
    doAssert a.mon == parked.mon and c.mon == parked.mon and hidden.mon == parked.mon
    reconnectOutput("HEADLESS-2")
    doAssert b.mon == monitor("HEADLESS-2") and b.geom == b.mon.m and b.prev == betaGeometry
    reconnectOutput("HEADLESS-1")
  of 4:
    doAssert first != nil and second != nil and third != nil
    doAssert hidden.mon == first and hidden.tags == 8 and not VISIBLEON(hidden, first)
    doAssert hidden.isfloating == 1 and zoneClientIndex(hidden) == -1
    doAssert hidden.current == hiddenGeometry
    doAssert a.mon == third and a.tags == 16
    doAssert b.mon == second and b.tags == 2 and b.current == second.m
    setfullscreen(b, 0)
    doAssert b.geom == betaGeometry
    doAssert c.mon == third and c.tags == 4 and c.isminimized and c.ismaximized
    doAssert c.maximizeRestore == gammaGeometry
    setWindowMaximized(c, false)
    doAssert c.geom == gammaGeometry
    finishTestKeyboard()
    wl_display_terminate(dpy)
    echo "PASS: Super+o cycle, Super+Shift+o three-output rotation, named pair swap, hidden tags, layout/view history, fixed/floating/fullscreen geometry, disabled outputs and lock guard"
    echo "PASS: output power cycle, output removal and reconnection, headless window parking, and workspace/zone/geometry recovery with manual-move opt-out"
  else: discard
  true

proc tick(data: pointer): cint {.cdecl.} =
  try:
    inc attempts
    if attempts > 120: raise newException(ValueError, "output test timed out at stage " & $stage)
    if checkStage(): inc stage
    if stage <= 4: discard wl_event_source_timer_update(timer, 50)
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)
  0

loadInitialConfig(testConfig, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 50)
run(nil)
discard wl_event_source_remove(timer)
cleanup()
removeFile(testConfig)
removeDir(runtimeDir)
