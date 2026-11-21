# Memory and security audit findings

1. **High — Input methods can receive physical keystrokes while the session is locked.** The lock handler clears text-input focus, but the keyboard path still forwards events to an input-method grab. The grab lookup does not check lock state or whether a text input is active. Do not forward keys or modifiers to input-method grabs while locked. Test that the lock surface receives the keys and the input method does not. See [compositor.nim:1148](compositor.nim#L1148), [compositor.nim:1197](compositor.nim#L1197), and [input_method_relay.nim:64](input_method_relay.nim#L64).

2. **High if untrusted apps can connect — Privileged Wayland protocols have no per-client access policy.** Any client that can connect to the display can bind globals for screen capture, clipboard control, and virtual input. Per-window capture uses a separate scene and does not check lock state. Restrict privileged globals to explicitly trusted clients. Define what happens to existing capture sessions when the screen locks. See [compositor.nim:256](compositor.nim#L256), [compositor.nim:1947](compositor.nim#L1947), and [compositor.nim:2018](compositor.nim#L2018).

3. **High — The compositor reports the session locked before it presents a lock frame.** `locksession` sends `locked` immediately after changing the scene. Output rendering happens later. If a locker suspends the system when it receives that event, the previous desktop frame can remain visible on resume. Send `locked` only after each active output confirms presentation of a lock frame. See [compositor.nim:1188](compositor.nim#L1188) and [compositor.nim:1695](compositor.nim#L1695).

4. **Medium — Shutdown omits native destructors.** `setup` creates a cursor, renderer, and allocator. `cleanup` does not explicitly destroy them. This is a shutdown ownership issue, not evidence of memory growth during a running session. Destroy each resource after its dependents are gone. See [compositor.nim:295](compositor.nim#L295), [compositor.nim:1928](compositor.nim#L1928), [compositor.nim:1941](compositor.nim#L1941), and [compositor.nim:2005](compositor.nim#L2005).

5. **Medium — Lock surfaces receive button releases without presses.** The locked branch returns on press, but release still reaches the seat. This prevents normal operation of mouse-driven lock controls. While locked, skip compositor bindings and forward presses and releases only to lock surfaces. See [compositor.nim:216](compositor.nim#L216) and [compositor.nim:252](compositor.nim#L252).

6. **Medium — The IPC server can reject valid pipelined requests.** The receive loop checks its one-frame buffer limit before it parses complete frames. A valid maximum-size frame followed by part of another frame can close the connection. Consume complete frames before rejecting input that exceeds the buffer limit. See [sway_ipc.nim:31](sway_ipc.nim#L31) and [sway_ipc.nim:340](sway_ipc.nim#L340).

7. **Low — Relative-pointer timestamps wrap after about 71.6 minutes.** The conversion from milliseconds to microseconds multiplies in 32 bits before it casts the result to 64 bits. Widen the timestamp before multiplying. See [compositor.nim:1434](compositor.nim#L1434).

## Verification

A headless AddressSanitizer build with Xwayland disabled acknowledged the normal IPC `exit` command and exited with status 0 and no sanitizer report. This test does not rule out native allocations that are still reachable at exit. Valgrind could not start because the system loader lacked the required debug symbols. The security findings are from source review and were not exercised against a live session. The timestamp wrap was also checked with a standalone arithmetic calculation.
