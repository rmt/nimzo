# Changelog

## nimzo 0.9.2

* Stop printing the legacy status stream to standard output by default.
  Startup commands launched with `-s` still receive it on standard input.
* Add `default_zone NAME` to choose the initial zone for new windows.
* Align Wayland popup menus with window content instead of the compositor
  titlebar. Keep menus visible when they extend beyond the window.

## nimzo 0.9.1

* Restrict Sway IPC by default. Add `wayland_protocols_restricted` to control
  access to privileged Wayland protocols. Both settings accept `on` and `off`
  and default to `on`.
* When focus is outside the requested zone or zone group, start at its
  topmost eligible window. Continue in stable order once inside.
* Add a `grim` screenshot profile and a Print binding to the example
  configuration, plus a script that saves timestamped JPEGs.
* Add diagnostic scripts for the wlroots ScreenCast portal.

## nimzo 0.9.0

* Rename `cycle-zone NAME` to `cycle focus in zone NAME`. Update existing
  bindings to use the new name.
* Add `swap zone with NAME` to exchange the visible windows in two zones.
  Use `focus source` to keep focus in the original zone. Use `focus last`
  to return to the previously focused visible window.
* Regenerate native bindings for session-lock presentation, private Wayland
  access, and cursor cleanup. Replace the handwritten presentation event
  record with the complete wlroots record.
* Preview the zone with the greatest window overlap at half opacity during
  Super-Shift-left drag and pointer resize. On release, update zone membership
  without fitting the window. Normal drops still fit or align the window.
* Release the cursor, allocator, and renderer during compositor shutdown.
* Accept a maximum-size IPC request followed by another request on the same socket.
* Prevent relative-pointer timestamps from wrapping during conversion to microseconds.
* Add `sway_ipc_restricted on` to limit the Sway IPC socket to workspace
  selection, workspace and tree queries, and workspace and window events.
* Hide privileged Wayland globals from ordinary connections. Add
  `wayland_client` profiles and `launch` for private connections with explicit
  grants, including Waybar and waylock examples.
* Wait for all enabled outputs to present a lock frame before acknowledging a
  session lock. Send mouse presses and releases to the lock surface, and keep
  locked keyboard input out of input-method grabs.
* Name the foreign-toplevel management bridge after its Wayland protocol.
* Rename input-method relay, titlebar rendering, output rules, compositor IPC,
  and built-in configuration files to describe their roles. Clarify internal
  action and protocol callback names without changing commands or protocols.
* Port the compositor, client helpers, and input-method relay to Nim. Keep dwl's
  function names, listeners, tag model, layouts, and resize transactions.
* Add native ABI bindings, reproducible binding generation, `config.nim`, and
  nimzo build, manual, and session entry points. Retain optional Xwayland.
* Add refactoring notes for Waybar, decoration negotiation, workspace/output
  ownership, per-workspace layouts, and zones.
* Correct the menu command to `bemenu-run` so Alt+p can start the launcher.
* Use Super as the default keyboard and pointer modifier.
* Add sway-like runtime configuration for outputs, key bindings, pointer modifiers,
  and colours, with validation, reload, and startup commands.
* Correct disabled-output array traversal and string cleanup so output
  disable/re-enable and shutdown work with runtime configuration.
* Update example shortcuts and colours. Place default output DP-3 above
  HDMI-A-1 with scale-aware relative positioning and a one-pixel gap.
* Keep independent per-output tags as an explicit feature.
* Add percentage zones, named movement and group cycling, drag/drop
  preview, fixed-size rules and toggles, and configurable output/zone snapping.
* Extend new-window rules with Xwayland class/instance regex criteria, targeted
  window command chains and shell exec. Validate rules before installing/reloading
  configuration, preserve requested fixed/floating dimensions, and document Pianoteq.
* Restore pointer grab mode selection and support keypad bindings with Num Lock.
* Add multi-output Waybar integration, XDG output metadata, foreign-toplevel
  taskbar actions, and a bounded SWAYSOCK endpoint with output-local workspaces.
* Add next/named-output focus and complete output-content rotation or named-pair
  swaps. Preserve hidden tags, view/layout history, zones, and window state.
  Bind Super-o and Super-Shift-o in the example. Keep Waybar labels as simple tags.
* Add Pango text titlebars, six-field decoration colours, per-window
  titlebar on/off/toggle, and unmodified titlebar dragging. Bind Super-Shift-b
  in the example; preserve content dimensions, fullscreen policy, and live
  per-window choices across configuration reload.
* Notify Waybar when the pointer changes outputs, including empty desktops.
  Project selected-workspace focus without retaining a focused tree window
  on another output or changing native keyboard focus.
* Add output-local relative workspace commands to bindings and window moves.
  Bind Super-Left/Right for navigation and Super-Shift-Left/Right for separate
  move-and-follow commands, with wrapping through all nine tags.
* Warp the pointer to the destination's usable centre for directional output
  focus, as for cycling and named-output focus.
* Give output-local tags a dynamic published lifetime: show only tags with
  assigned managed windows, including hidden memberships. Remove empty tags
  from Waybar and IPC immediately, even when selected.
* Add minimize/restore and maximize/restore, including taskbar requests and
  states, XDG/Xwayland requests, retained tags, and independent fullscreen
  restore geometry. Bind Super-Down and Super-Up in the example.
* Keep selected tags visible on every output even when empty. Remove only tags
  that are both empty and unselected.
* Include minimized and fullscreen windows in window cycling. Restore skipped
  minimized previews, keep the selection on modifier release, and retain
  fullscreen state without blocking focus changes. Keep zone cycling immediate.
* Bind Super-w to request a polite close of the focused window, without
  force-killing the application. Keep the existing close shortcuts.
* Update floating windows' zone assignments after mouse moves without changing
  their chosen position, size, or floating state, including cross-output drops.
* Resize the nearest corner with Super-right drag. Keep the opposite corner
  fixed, respect application size limits, and snap the dragged edges.
* Keep manually resized/floating windows in normal focus-based stacking in zones
  mode instead of pinning them above all zone windows. Preserve focused stacking
  when layout changes merge layers, without raising windows on sloppy focus.
* Replace the Makefile and config.mk with Nimble build, test, system installation,
  cleanup, and source archive tasks. Generate protocols and native compiler flags
  through config.nims, with environment settings for native dependencies.
* Remove the 16 ms Sway IPC polling timer. Process socket readiness directly and
  publish native state changes at event-loop idle. Notify subscribers when the
  last focused window loses focus, and preserve queued bytes after partial writes.
* Expand the manual's configuration reference with directive and command syntax,
  output properties, window-rule criteria, defaults, and validated examples.
* Restore displaced windows to their output, workspace, and zone when the
  output returns. Restore floating geometry relative to the output, and keep
  manual moves and resizes. Park windows on a private headless output when no
  physical output is active.
* Ship upstream notices with source archives and staged system installations.
  Separate README credits from license terms and document how to maintain the
  compositor, its tests, and its native bindings.
* Use one list for scanner outputs so cleanup leaves hand-written files alone.
  Share compositor assembly and headless fixtures across integration tests.
* Use generated Wayland types for the Waybar bridge and keep minimized windows
  in taskbar membership. Name the layout slots and guard capture scene teardown
  for unmanaged X11 windows.
* Give compiled commands explicit action kinds. Keep the existing callbacks
  for bindings and apply new-window rules to the matched client.
* Move output recovery, including the private headless output and saved
  placement, into `output_recovery.nim` without changing hotplug behavior.
* Fit or align windows on normal zone drops. Add Super-Shift-left drag to
  assign the zone without changing the drop position or size.
* Prefer the zone under the pointer on normal drops so a wide resized window
  can move to a zone that covers less of its frame.
* Include Shift-dropped windows in cycling for their assigned zone without
  fitting or aligning them.
* Allow Shift during modifier-right resize. Use modifier-wheel to switch
  workspaces on the pointer output, or add Shift to move the hovered window
  and follow it to the destination workspace.
* Keep the normal border on untitled windows and show the titlebar when
  an application supplies a title, if titlebars are enabled for that window.
* Toggle the outer border and titlebar outline independently of the titlebar.
  Use Super-b and Super-t for decorations.
* Start in zones layout by default. Use left and right half-output zones
  when no custom zones are defined.
* Remove the tile layout, its shortcut, and the master count, master factor,
  and zoom commands.
* Remove the output-wide floating layout. Individual windows can still float
  in either zones or monocle.
* Use Super-Ctrl-Alt-Space to switch between Zones and Monocle.
* Detach floating windows from zones. Shift-drag and pointer resize keep
  manual geometry without zone membership. A normal drop reattaches the
  window and fits or aligns it to the target zone.
* Add independent always-on-top mode with Super-Shift-a. This mode keeps
  windows above ordinary windows but below fullscreen and skips them in
  window and zone cycling.

The earlier dwl release history follows.

* [0.9](#0.9)
* [0.8](#0.8)
* [0.7](#0.7)
* [0.6](#0.6)
* [0.5](#0.5)


## 0.9

### Added

* Add axis mouse bindings ([#652][652])
* Add support for the ext-data-control protocol ([#1184][1184])
* Add support for the ext-foreign-toplevel-list protocol ([#1223][1223])
* Add support for the ext-image-copy-capture and ext-image-capture-source protocols (screensharing) ([#1218][1218], [#1223][1223], [#1224][1224])
* Add support for version 4 of the layer shell protocol (on-demand keyboard interactivity) ([#674][674])
* Add support for wlr-text-input and wlr-input-method protocols (IME) ([#1219][1219])
* Snap windows to edges when moving or resizing them ([#608][608])

[1184]: https://codeberg.org/dwl/dwl/pulls/1184
[1218]: https://codeberg.org/dwl/dwl/pulls/1218
[1219]: https://codeberg.org/dwl/dwl/pulls/1219
[1223]: https://codeberg.org/dwl/dwl/pulls/1223
[1224]: https://codeberg.org/dwl/dwl/pulls/1224
[608]: https://codeberg.org/dwl/dwl/pulls/608
[652]: https://codeberg.org/dwl/dwl/pulls/652
[674]: https://codeberg.org/dwl/dwl/pulls/674


### Changed

* Update wlroots to version 0.20 ([#1218][1218])
* Use modifier-independent key symbols in config.h keybindings ([#1075][1075])

[1075]: https://codeberg.org/dwl/dwl/pulls/1075
[1218]: https://codeberg.org/dwl/dwl/pulls/1218


### Fixed

* Apply a minimum window size of 1x1 ([#1231][1231])
* Close Xwayland submenus when changing tag or focus ([#1233][1233])
* Don't make Firefox draw rounded corners when it is opened ([#d1ebf3c][d1ebf3c])
* Don't send key release events to the wrong client ([#1108][1108])
* Fix a crash when closing mpv ([#1220][1220])
* Fix a crash when destroying an idle-inhibitor ([#1214][1214])
* Fix choppy resizing on newer wlroots ([#1280][1280])
* Fix the position of certain sub-menus in Xwayland applications ([#1232][1232])
* Keep the focused border color on the regular client when opening a layer shell surface like wmenu ([#6013835][6013835])
* Let keybindings focus and tag monitors above and below ([#5fd19fe][5fd19fe])
* Preserve asleep disabled outputs in output config ([#1198][1198])
* Respect size hints ([#4de32d2][4de32d2])
* Set seat capabilities for virtual keyboards and pointers when there is no other input device ([#99cdc9a][99cdc9a])
* Show popups in fullscreen Xwayland applications ([#1fe1b4e][1fe1b4e])
* Show the correct cursor after moving and resizing ([#8ad2c92][8ad2c92])

[1108]: https://codeberg.org/dwl/dwl/pulls/1108
[1198]: https://codeberg.org/dwl/dwl/pulls/1198
[1214]: https://codeberg.org/dwl/dwl/pulls/1214
[1220]: https://codeberg.org/dwl/dwl/pulls/1220
[1231]: https://codeberg.org/dwl/dwl/pulls/1231
[1232]: https://codeberg.org/dwl/dwl/pulls/1232
[1233]: https://codeberg.org/dwl/dwl/pulls/1233
[1280]: https://codeberg.org/dwl/dwl/pulls/1280
[1fe1b4e]: https://codeberg.org/dwl/dwl/commit/1fe1b4e
[4de32d2]: https://codeberg.org/dwl/dwl/commit/4de32d2
[5fd19fe]: https://codeberg.org/dwl/dwl/commit/5fd19fe
[6013835]: https://codeberg.org/dwl/dwl/commit/6013835
[8ad2c92]: https://codeberg.org/dwl/dwl/commit/8ad2c92
[99cdc9a]: https://codeberg.org/dwl/dwl/commit/99cdc9a
[d1ebf3c]: https://codeberg.org/dwl/dwl/commit/d1ebf3c


### Contributors


* A Frederick Christensen
* Alex Denes
* Andrea Chiavazza
* Diego Viola
* Guido Cella
* Leonardo Hernández Hernández
* Peter Hofmann
* Siva Mahadevan
* julmajustus
* klim
* save196
* sewn
* thanatos


## 0.8

### Added

* Support for the linux-drm-syncobj-v1 protocol ([wlroots!4715][wlroots!4715], [#685][685])
* Allow the use of non-system wlroots library ([#646][646])

[wlroots!4715]: https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/4715
[685]: https://codeberg.org/dwl/dwl/pulls/685
[646]: https://codeberg.org/dwl/dwl/pulls/646


### Fixed

* Crash when a client is created while all outputs are disabled.


Most changes in this release are not listed. See the commits for details.


## 0.7

This version is just 0.6 with wlroots 0.18 compatibility.

### Added

* Add support for the alpha-modifier-v1 protocol ([wlroots!4616][wlroots!4616]).
* dwl now will survive GPU resets ([#601][601]).

[wlroots!4616]: https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/4616
[601]: https://codeberg.org/dwl/dwl/issues/601


### Contributors

Guido Cella


## 0.6

### Added

* Add `rootcolor` to change the default background color ([#544][544]).
* Implement the wlr-virtual-pointer-unstable-v1 protocol ([#574][574]).
* Implement the pointer-constraints and relative-pointer protocols ([#317][317])
* Implement the wlr-output-power-management protocol ([#599][599])

[544]: https://codeberg.org/dwl/dwl/pulls/544
[574]: https://codeberg.org/dwl/dwl/pulls/574
[317]: https://codeberg.org/dwl/dwl/issues/317
[599]: https://codeberg.org/dwl/dwl/issues/559


### Changed

* Keyboards are now managed through keyboard groups ([#549][549]).
* Only the first matched keybinding is executed.
* Allow toggling the layout before selecting a different one ([#570][570]).
* Fullscreen clients are now rendered above wlr_layer_surfaces in the top layer
  ([#609][609]).
* The default menu was changed from `bemenu-run` to `wmenu-run` ([#553][553]).
* The option `sloppyfocus` now replicates the dwm behavior ([#599][599]).
* Allow configure position of monitors with negative values. (-1, -1) is
  used to auto-configure them ([#635][635]).
* dwl now kills the entire process group of `startup_cmd`
* The O_NONBLOCK flag is set for stdout.

[549]: https://codeberg.org/dwl/dwl/pulls/549
[570]: https://codeberg.org/dwl/dwl/pulls/570
[609]: https://codeberg.org/dwl/dwl/pulls/609
[553]: https://codeberg.org/dwl/dwl/issues/553
[599]: https://codeberg.org/dwl/dwl/pulls/599
[635]: https://codeberg.org/dwl/dwl/pulls/635


### Removed

* The SLOC limit is now removed ([#497][497]).

[497]: https://codeberg.org/dwl/dwl/pulls/497


### Fixed

* Clients not having the correct border color when mapping.
* Compliance with the xdg-decoration-unstable-v1 ([#546][546]).
* dwl no longer sends negative values in xdg_toplevel.configure events.
* Crashes with disabled monitors ([#472][472]).

[546]: https://codeberg.org/dwl/dwl/pulls/546
[472]: https://codeberg.org/dwl/dwl/issues/472


### Contributors

Ben Jargowsky
Benjamin Chausse
David Donahue
Devin J. Pohly
Dima Krasner
Emil Miler
Forrest Bushstone
Guido Cella
Peter Hofmann
Rutherther
Squibid
choc
fictitiousexistence
korei999
sewn
thanatos


## 0.5

### Added

* Allow configure x and y position of outputs ([#301][301])
* Implement repeatable keybindings ([#368][368])
* Print app id in printstatus() output ([#381][381])
* Display client count in monocle symbol ([#387][387])
* Export XCURSOR_SIZE to fix apps using an older version of Qt ([#425][425])
* Support for wp-fractional-scale-v1 (through wlr_scene: [wlroots!3511][wlroots!3511])
* dwl now sends `wl_surface.preferred_buffer_scale` (through wlr_scene: [wlroots!4269][wlroots!4269])
* Add support for xdg-shell v6 ([#465][465])
* Add support for wp-cursor-shape-v1 ([#444][444])
* Add desktop file ([#484][484])
* Add macro to easily configure colors ([#466][466])
* Color of urgent clients are now red ([#494][494])
* New flag `-d` and option `log_level` to change the wlroots debug level
* Add CHANGELOG.md ([#501][501])

[301]: https://github.com/djpohly/dwl/pull/301
[368]: https://github.com/djpohly/dwl/pull/368
[381]: https://github.com/djpohly/dwl/pull/381
[387]: https://github.com/djpohly/dwl/issues/387
[425]: https://github.com/djpohly/dwl/pull/425
[wlroots!4269]: https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/4269
[wlroots!3511]: https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/3511
[465]: https://github.com/djpohly/dwl/pull/465
[444]: https://github.com/djpohly/dwl/pull/444
[484]: https://github.com/djpohly/dwl/pull/484
[466]: https://github.com/djpohly/dwl/issues/466
[494]: https://github.com/djpohly/dwl/pull/494
[501]: https://github.com/djpohly/dwl/pull/501


### Changed

* Replace `tags` with `TAGCOUNT` in config.def.h ([#403][403])
* Pop ups are now destroyed when focusing another client ([#408][408])
* dwl does not longer respect size hints, instead clip windows if they are
  larger than they should be ([#455][455])
* The version of wlr-layer-shell-unstable-v1 was lowered to 3 (from 4)
* Use the same border color as dwm ([#494][494])

[403]: https://github.com/djpohly/dwl/pull/403
[408]: https://github.com/djpohly/dwl/pull/409
[455]: https://github.com/djpohly/dwl/pull/455
[494]: https://github.com/djpohly/dwl/pull/494


### Removed

* Remove unused `rootcolor` option ([#401][401])
* Remove support for wlr-input-inhibitor-unstable-v1 ([#430][430])
* Remove support for KDE idle protocol ([#431][431])

[401]: https://github.com/djpohly/dwl/pull/401
[430]: https://github.com/djpohly/dwl/pull/430
[431]: https://github.com/djpohly/dwl/pull/431


### Fixed

* Fix crash when creating a layer surface with all outputs disabled
  ([#421][421])
* Fix other clients being shown as focused if the focused client have pop ups
  open ([#408][408])
* Resize fullscreen clients when updating monitor mode
* dwl no longer crash at exit like sometimes did
* Fullscreen background appearing above clients ([#487][487])
* Fix a segfault when user provides invalid xkb_rules ([#518][518])

[421]: https://github.com/djpohly/dwl/pull/421
[408]: https://github.com/djpohly/dwl/issues/408
[487]: https://github.com/djpohly/dwl/issues/487
[518]: https://github.com/djpohly/dwl/pull/518


### Contributors

* A Frederick Christensen
* Angelo Antony
* Ben Collerson
* Devin J. Pohly
* Forrest Bushstone
* gan-of-culture
* godalming123
* Job79
* link2xt
* Micah Gorrell
* Nikita Ivanov
* Palanix
* pino-desktop
* Weiseguy
* Yves Zoundi
