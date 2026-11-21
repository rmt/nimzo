# Test how window rules match and run in order when XDG and Xwayland
# clients map, including after a configuration reload.

const VERSION = "window-rules-test"
include ../nimzo_core
include headless_support

let directory = headlessRuntime("nimzo-rules-", 2)
putEnv("XWAYLAND_NO_GLAMOR", "1")
# Do not probe host NVIDIA drivers from a private software-only Xwayland.
if fileExists("/usr/share/glvnd/egl_vendor.d/50_mesa.json"):
  putEnv("__EGL_VENDOR_LIBRARY_FILENAMES", "/usr/share/glvnd/egl_vendor.d/50_mesa.json")
let configFile = directory / "config"
let marker = directory / "mapped"
let baseConfig = """
layout zones
zone L 0% 0% 50% 100%
zone R 50% 0% 50% 100%
output HEADLESS-1 default
output HEADLESS-1 mode 800x600
output HEADLESS-1 position 0 0
output HEADLESS-2 mode 800x600
output HEADLESS-2 position 0 600
for_window [app_id="^ruled$"] fixedSize off
for_window [app_id="^ruled$" title="^Rule \]"] titlebar on, fixedSize on, move container to workspace 2, exec printf 'mapped,a;#\n' >> MARKER
for_window [app_id="^float$"] fixedSize on, move container to zone R, floating on, titlebar on, fullscreen on, fullscreen off, maximize on, maximize off, move container to output down, move container to workspace number 3, move container to output down, move container to workspace prev
for_window [app_id="^mini$"] minimize
for_window [app_id="^full$"] fullscreen on
for_window [app_id="^max$"] move container to workspace 3, maximize on
for_window [class="^Pianoteq 9$" instance="^piano-ui$" title="^Pianoteq v9\.1\.2$"] fixedSize on, titlebar on
for_window [class="^piano-ui$"] fixedSize off
for_window [instance="^Pianoteq 9$"] titlebar off
exec "$NIMZO_ZONE_CLIENT" anchor
""".replace("MARKER", marker)
writeFile(configFile, baseConfig)
var stage, attempts: int
var timer: ptr wl_event_source
var pids: seq[pid_t]

proc spawn(appId: cstring; title: cstring = "normal") =
  let pid = fork()
  if pid == 0:
    let executable = getEnv("NIMZO_ZONE_CLIENT")
    discard execl(executable.cstring, executable.cstring, appId, "normal", title, "Changed title", nil)
    exit(127)
  doAssert pid > 0
  pids.add pid

proc contentSize(c: ptr Client) =
  doAssert c.geom.width - 2 * cint(c.bw) == 180
  doAssert c.geom.height - client_frame_height(c) == 140

proc checkStage(): bool =
  let anchor = app("anchor")
  if anchor == nil or anchor.resize_serial != 0: return false
  case stage
  of 0:
    doAssert anchor.isfixed == 0 and not anchor.showTitlebar
    for text in ["fixedSize maybe", "layout monocle", "reload", "exit", "focus next", "move container to zone missing", "titlebar on, unsupported"]:
      try:
        discard compileConfigCommands(parseConfig("for_window [app_id=\"a\"] " & text, "bad.conf"))
        doAssert false, "accepted invalid rule: " & text
      except ConfigError as error:
        doAssert error.msg.startsWith("bad.conf:1:")
    spawn("ruled", "Rule ] comma, semi; hash#")
  of 1:
    let c = app("ruled")
    if c == nil or c.resize_serial != 0 or not fileExists(marker): return false
    doAssert readFile(marker) == "mapped,a;#\n"
    doAssert c.isfixed == 1 and c.showTitlebar and c.tags == 2
    contentSize(c)
    doAssert anchor.isfixed == 0 and not anchor.showTitlebar
    doAssert focused_client == anchor
    # A title update and a valid reload do not re-run new-window commands.
    discard kill(pids[0], ipcPosix.SIGUSR1)
    var argument: Arg
    reloadconfig(addr argument)
    # Invalid rule commands must leave the entire previous configuration active.
    writeFile(configFile, baseConfig & "\nfor_window [app_id=\"anchor\"] unsupported\n")
    reloadconfig(addr argument)
    doAssert activeConfigText == baseConfig
    writeFile(configFile, baseConfig)
    spawn("float")
  of 2:
    let c = app("float")
    if c == nil or c.resize_serial != 0: return false
    doAssert c.isfixed == 1 and c.isfloating == 1 and c.showTitlebar
    doAssert c.isfullscreen == 0 and not c.ismaximized
    doAssert c.mon == anchor.mon and c.tags == (1'u32 shl 8)
    doAssert zoneClientIndex(c) == -1
    contentSize(c)
    doAssert app("ruled").isfixed == 1 and app("ruled").tags == 2
    doAssert $client_get_title(app("ruled")) == "Changed title"
    doAssert readFile(marker) == "mapped,a;#\n"
    spawn("mini")
  of 3:
    let c = app("mini")
    if c == nil or c.resize_serial != 0: return false
    doAssert c.isminimized and focused_client != c
    spawn("full")
  of 4:
    let c = app("full")
    if c == nil or c.resize_serial != 0: return false
    doAssert c.isfullscreen == 1
    doAssert c.geom.width == c.mon.m.width and c.geom.height == c.mon.m.height
    spawn("max")
  of 5:
    let c = app("max")
    if c == nil or c.resize_serial != 0: return false
    doAssert c.ismaximized and c.tags == 4
    doAssert c.geom.width == c.mon.w.width and c.geom.height == c.mon.w.height
    when defined(XWAYLAND):
      let pid = fork()
      if pid == 0:
        let executable = getEnv("NIMZO_X11_CLIENT")
        discard execl(executable.cstring, executable.cstring, nil)
        exit(127)
      doAssert pid > 0
      pids.add pid
  of 6:
    when defined(XWAYLAND):
      let c = app("Pianoteq 9")
      if c == nil or c.resize_serial != 0: return false
      doAssert c.isfixed == 1 and c.showTitlebar
      doAssert clientWindowProperties(c).instance == "piano-ui"
      contentSize(c)
      # Reproduce plugin-editor stacking with a real fixed-size X11 window.
      setClientFixedSize(anchor, 1)
      assignClientZone(anchor, zoneIndex(activeConfig.zones, "L"))
      assignClientZone(c, zoneIndex(activeConfig.zones, "L"))
      resize(anchor, wlr_box(x: 100, y: 100, width: 260, height: 230), 1)
      resize(c, wlr_box(x: 100, y: 100, width: 180, height: 170), 1)
      focusclient(c, nil, 1)
      wlr_cursor_warp_closest(cursor, nil, 260, 250)
      var argument = Arg(ui: uint32(CurResize))
      moveresize(addr argument)
      doAssert cursor_mode == CurResize and grabc == c
      motionnotify(10, nil, 40, 40, 0, 0)
      finishPointerInteraction()
      doAssert c.isfloating == 1 and c.isfixed == 1
      focusclient(anchor, nil, 1)
  of 7:
    when defined(XWAYLAND):
      let c = app("Pianoteq 9")
      if c == nil or c.resize_serial != 0: return false
      doAssert c.scene.node.parent == layers[LyrTile]
      var hit: ptr Client
      xytonode(120, 240, nil, addr hit, nil, nil, nil)
      doAssert hit == anchor, "resized Xwayland editor obscures focused zone window"
      for floating in [0.cint, 1.cint]:
        focusclient(c, nil, 1)
        setfloating(c, floating)
        focusclient(anchor, nil, 1)
        xytonode(120, 240, nil, addr hit, nil, nil, nil)
        doAssert hit == anchor
    doAssert readFile(marker) == "mapped,a;#\n"
    for pid in pids: discard kill(pid, SIGTERM)
    wl_display_terminate(dpy)
    echo "PASS: new-window regex rules, XDG/Xwayland class and instance, targeted command chains, requested size, shell exec once and reload validation"
  else: discard
  true

proc tick(data: pointer): cint {.cdecl.} =
  try:
    inc attempts
    if attempts > 160: raise newException(ValueError, "window rule test timed out at stage " & $stage)
    if checkStage(): inc stage
    if stage <= 7: discard wl_event_source_timer_update(timer, 50)
  except Exception as error:
    discard fprintf(stderr, "FAIL: %s\n", error.msg.cstring)
    exit(1)
  0

loadInitialConfig(configFile, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 50)
run(nil)
discard wl_event_source_remove(timer)
cleanup()
removeFile(configFile)
removeFile(marker)
removeDir(directory)
