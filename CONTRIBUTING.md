# Contributing to nimzo

## Find the code to change

`nimzo.nim` is the CLI entry point. It and the native integration tests
include `nimzo_core.nim` for the ordered compositor assembly.

Tests in this table are in `tests/`.

| Task | Code | Nearest test |
| --- | --- | --- |
| Add a config command | `runtime_config.nim` parses text; `runtime_apply.nim` validates and applies commands; `output_rules.nim` applies output rules | `test_runtime_config.nim`, `test_runtime_compositor.nim`, `test_window_rules.nim` |
| Change layout geometry | `zones_geometry.nim` calculates rectangles; `zones_runtime.nim` and `zones_interaction.nim` place and move clients; `compositor.nim` contains monocle | `test_zones_geometry.nim`, `test_zones_compositor.nim` |
| Debug map or unmap | `compositor.nim` owns listeners; `client.nim` handles XDG/X11 differences | `test_window_rules.nim` |
| Debug output loss or reconnection | `compositor.nim` handles output events; `output_recovery.nim` owns saved placement and the headless fallback | `test_output_rotation.nim` |
| Change the IPC projection | `sway_ipc_compositor.nim` projects state; `sway_ipc.nim` owns transport and framing | `test_sway_ipc.nim`, `test_ipc_dispatch.nim` |
| Change foreign-toplevel management | `wlr_foreign_toplevel_management.c` and `.h` own Wayland resources; `wlr_foreign_toplevel_management.nim` applies compositor policy | `test_window_states.nim`, `nimble testWaybar` |
| Regenerate the ABI | `nimzo_ffi.h`, `tools/generate_bindings.nim`, `bindings.nim` | Compare C and Nim layouts, then run the headless tests in both build modes |

## Build and test

See the [README](README.md) for build dependencies. `nimble test` needs
wayland-client development files, `timeout`, `mktemp`, and PCRE for Nim `re`.
Install Xwayland for the X11 client tests. Also run `NIMZO_XWAYLAND=0 nimble test`
in a separate clean source tree when changing native code. The tests do not
need a desktop or physical monitors. `nimble testWaybar` also needs Python 3
and a real Waybar executable. Use `WAYBAR=/path/to/waybar` to select it.

The build accepts `PKG_CONFIG`, `WLR_INCS`, `WLR_LIBS`, `CPPFLAGS`, `CFLAGS`,
`LDFLAGS`, and `LIBS`. Use `WAYLAND_SCANNER` and `WAYLAND_PROTOCOLS` to select
the scanner and the system protocol directory. `nimble clean` removes the
executable and generated scanner files. With Nimble 0.24.1, use
`nimble cleanGenerated` instead: that release does not resolve the Nim compiler
before running its built-in `clean`.

## Ownership and policy

- Keep native listener owners at stable addresses. Remove their listeners
  before freeing them. Do not put managed Nim fields in `ecalloc` records.
  An X11 association, a mapped scene, and the client record have different
  lifetimes. In particular, dissociation can happen before client destruction.
- Save output identity by connector, not by `Monitor` pointer. On output loss,
  move clients to a live output or the private headless output. Restore saved
  placement when possible, but do not reclaim a window the user moved or resized.
  Manual placement changes call `forgetOutputPlacement`; temporary moves
  during output recovery must preserve the saved placement.
- Keep manual window geometry distinct from automatic layout. A floating window
  can retain a zone name without filling that zone. Use the client inset helpers
  to convert between content and outer frame geometry.
- Focus and taskbar membership are different. A minimized client stays mapped
  and keeps its tags and taskbar handle, but does not get normal focus or layout
  space. Do not clear native keyboard focus just to project an empty tag in IPC.
- Parse and compile a configuration before installing it. Keep the active
  command storage alive during a binding, including when it calls reload.
  Reload does not rerun startup commands or existing window rules.
  `RuntimeAction.kind` selects the payload and execution path. Use the native
  callback branch for existing dwl-style actions. A `for_window` rule can use
  `exec` or a native action with an explicit window operation. Apply that
  operation to the matched client, not to the focused client.
- IPC uses descriptor readiness in the Wayland event loop. State changes
  schedule one idle snapshot; queries can refresh pending state before replying.
  Keep queues bounded and nonblocking. Keep output-local `OUTPUT:TAG` identity
  and project each client once without changing its native tag mask.
- Keep session-lock checks and state setters in Nim. The foreign-toplevel
  management bridge uses a narrow C interface for Wayland resources. Do not
  include wlroots headers in the compositor C translation unit: they conflict
  with generated ABI records.

## Native ABI maintenance

Hand-written Nim and C sources are tracked. `bindings.nim` is tracked generated
Nim; do not edit it by hand. The scanner creates untracked C and headers from
the vendored XML and system protocol definitions during a regular build.

`bindings.nim` is generated for the installed wlroots 0.20 and native system
headers. The regular build does not need Futhark. Regenerate the binding when
adding native APIs, changing the target ABI, or changing the wlroots series.
Keep the generated binding and `nimzo_ffi.h` in the same change.
The checked-in binding retains source-location comments from its last generation,
with the checkout directory stripped automatically by the generator.

The generation tool uses Futhark 0.15. Its opir parser needs the supplied patch
with Clang 23. Clang now exposes some named record fields as `CXType_Record`
instead of `CXType_Elaborated`, and adds canonicalizable predefined types. An
unpatched parser can omit fields without reporting an error. Do not replace
missing fields or anonymous records with empty objects.

To build a private patched parser without changing the installed package:

```sh
futhark="$(nimble path futhark)"
work="$(mktemp -d)"
cp "$futhark/futhark/opir.nim" "$futhark/futhark/libclang.nim" "$work/"
patch -d "$work" -p1 < tools/opir-clang23.patch
nim c -d:release --passL:-lclang -o:"$work/opir" "$work/opir.nim"
PATH="$work:$PATH" nim c -d:opirRebuild --maxLoopIterationsVM:1000000000 \
  --path:"$futhark" -o:"$work/generate" tools/generate_bindings.nim
```

Generate the protocol headers before running this command. The native development
packages must include Xwayland and XCB headers for regeneration, even if the
normal compositor build does not enable Xwayland.

The generator scans a maintained list of top-level Nim modules for API roots.
Update that list when moving native API use into a new module.
The generator retains type dependencies and key and button constants.
Uppercase single-letter XKB symbols use `XKB_KEY_upper_A` through
`XKB_KEY_upper_Z`, because Nim cannot distinguish `XKB_KEY_a` from `XKB_KEY_A`.

After regeneration, compare native record sizes and important offsets with the
C headers before running the compositor. In particular, check scene nodes,
outputs, surfaces, XDG surfaces, seats, keyboards, and input-method records.
Then exercise real clients on a headless backend.
