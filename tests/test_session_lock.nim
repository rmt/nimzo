# Verify the ext-session-lock acknowledgement with a real Wayland client.
const VERSION = "session-lock-test"
include ../nimzo_core
include headless_support
import std/osproc

let runtimeDir = headlessRuntime("nimzo-lock-", 2)
let testConfig = runtimeDir / "config"
let roundTrip = runtimeDir / "lock-request-seen"
let unlocked = runtimeDir / "unlock-request-seen"
let denied = runtimeDir / "unprivileged-client-checked"
let fixture = getEnv("NIMZO_SESSION_LOCK_CLIENT")
writeFile(testConfig, "output HEADLESS-1 mode 400x300\noutput HEADLESS-2 mode 400x300\n" &
  "wayland_client locker session-lock " & $(%fixture) & " " & $(%roundTrip) & " " &
  $(%unlocked) & "\nbindsym Ctrl+Alt+l launch locker\n")
var first, withheld: ptr Monitor
var timer: ptr wl_event_source
var publicProbe: Process
var launched: bool
var restoredFrame: bool
var attempts: int

proc tick(data: pointer): cint {.cdecl.} =
  inc attempts
  doAssert attempts <= 300, "timed out waiting for the session lock client"
  if publicProbe == nil:
    publicProbe = startProcess(fixture, args = [denied], options = {poParentStreams})
  elif not launched and fileExists(denied):
    first = wl_list_first_link(addr mons, first)
    withheld = wl_list_next_link(first)
    doAssert wl_list_more_link(withheld, addr mons)
    wl_list_remove(addr withheld.frame.link)
    runConfiguredBinding(addr runtimeKeys[0].arg)
    launched = true
  elif launched:
    if fileExists(unlocked):
      doAssert restoredFrame and locked == 0 and cur_lock == nil
      wl_display_terminate(dpy)
      echo "PASS: public globals are restricted; private locker waits for both outputs and unlocks"
      return 0
    if not restoredFrame and fileExists(roundTrip) and first.lockFrame == LockFramePresented:
      doAssert pendingLock() != nil
      wl_signal_add(addr withheld.wlr_output.events.frame, addr withheld.frame)
      wlr_output_schedule_frame(withheld.wlr_output)
      restoredFrame = true
  discard wl_event_source_timer_update(timer, 15)
  0

loadInitialConfig(testConfig, false)
setup()
timer = wl_event_loop_add_timer(event_loop, tick, nil)
discard wl_event_source_timer_update(timer, 15)
run(nil)
publicProbe.close()
discard wl_event_source_remove(timer)
cleanup()
removeDir(runtimeDir)
