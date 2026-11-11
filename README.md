<!--
SPDX-FileCopyrightText: © 2026 Robert Thomson
SPDX-License-Identifier: 0BSD
-->

# nimzo

**nimzo** (Nim zones) is a configurable [river](https://codeberg.org/river/river/)
window manager written in Nim. It started as a Nim implementation of
[tinyrwm](https://codeberg.org/river/tinyrwm/) and is now a standalone project.

## Dependencies

- Nim 2.0 or newer
- Nimble
- pkg-config
- wayland-scanner
- wayland-client
- xkbcommon
- Cairo
- Pango (including pangocairo)
- PCRE (`libpcre`, used by Nim's regular-expression library)
- A sans-serif font, e.g. DejaVu Sans

Install the development packages for these libraries if your distribution
provides them separately. Waybar and swaybg are optional runtime companions;
install them separately if you use the startup commands below.

## Building

```sh
nimble build
```

## Configuration

Configuration parsing lives in `config.nim`; command definitions, parsing, and
execution live in `commands.nim`. Output geometry is resolved in
`output_layout.nim` and applied asynchronously by `output_manager.nim`.
`layer_shell.nim` provides River's panel/wallpaper integration; `work_area.nim`
contains floating-window placement helpers. `zones.nim` implements zone geometry;
`zone_overlay.nim` draws the drag preview.

The default path is `$XDG_CONFIG_HOME/river/nimzo.config`, falling back to
`~/.config/river/nimzo.config` when `XDG_CONFIG_HOME` is not set.
Use `nimzo -c /path/to/config` to override it.
When no default file exists, the built-in configuration includes Alt+x,
Alt+Tab, Ctrl+Alt+BackSpace, and Super+Shift+r to reload. A configuration file
**replaces** the built-in keyboard bindings; include the bindings you need and a
reload binding in your file. Super+left/right drag remains enabled unless you
change `floating_modifier`.

Copy [`config.example`](config.example) to the default location:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/river"
cp config.example "${XDG_CONFIG_HOME:-$HOME/.config}/river/nimzo.config"
```

Or start with:

```text
set $mod Mod4
set $term foot
font pango:monospace 10
client.focused #8b0000 #8b0000 #ffffff
client.unfocused #500000 #500000 #dddddd
floating_modifier $mod
bindsym Alt+x exec $term
bindsym $mod+Return exec $term
bindsym $mod+q kill
bindsym $mod+n focus next
bindsym Ctrl+Alt+BackSpace exit
bindsym $mod+Shift+r reload
```

Validate without a Wayland server:

```sh
./nimzo --validate -c config.example
```

Supported directives:

- `set $name value`: textual substitution of previously defined variables.
  Undefined variables are preserved, allowing shell variables such as `$HOME`
  in exec commands. Quote values containing spaces. This is not shell evaluation.
- `font [pango:]description`: Pango font description.
- `bindsym Mod4+Return command`: keyboard or pointer binding. Modifier names are
  `Shift`, `Ctrl`/`Control`, `Alt`/`Mod1`, `Super`/`Logo`/`Mod4`, `Mod3`, and `Mod5`.
  Key names are resolved by xkbcommon, including multimedia keys. Pointer buttons
  are `button1`, `button2`, `button3`, `button8`, and `button9`. Last duplicate wins.
- `floating_modifier modifiers`: modifier for left-button move/right-button resize.
- `client.focused` and `client.unfocused`: `border background text [indicator
  [child_border [titlebar_border]]]`, using `#RRGGBB` or `#RRGGBBAA`.
  `titlebar_border` sets the titlebar outline color independently of the window
  border and defaults to `border` when omitted. Indicator and child_border are
  accepted for syntax compatibility but have no separate visual element.
- `exec shell-command`: run once at startup, not again on reload.
- `output NAME PROPERTY ...` or an `output NAME { ... }` block: output settings,
  including relative placement (see below).
- `layout zones`: select the layout engine. Zones is currently the only engine.
- `zone NAME X% Y% WIDTH% HEIGHT%`: define a shared named zone (see below).
- `for_window [app_id="REGEX" title="REGEX"] fixedSize on|off`: set the initial
  fixed-size state for matching windows. Either criterion may be omitted.

Binding commands include `exec shell-command`, `kill` (or `close`), `focus next`,
`fullscreen [enable|disable|toggle]`, `minimize`, `restore`, `move`, `resize`,
`exit`, `reload`, and the zone/workspace/output commands below. `fullscreen`
without a target toggles the focused window. `minimize` hides the focused window;
`restore` shows and focuses the most recently minimized window on the active
workspace.
Move/resize start pointer operations on the hovered window. Commands can be
chained with unquoted `;` or `,`. Quote an exec command that contains shell
separators, for example:
`bindsym Alt+x exec 'printf hello; foot'`. Exec runs asynchronously via `/bin/sh -c`.

Full-line and trailing `#` comments are supported; hex colors and quoted `#`
characters are preserved. Invalid lines print a warning to stderr with the file
and line number, then parsing continues. A skipped line does not change settings
already parsed from that file. Unsupported blocks are skipped as a unit, including
nested blocks. An unterminated output block produces a warning but retains its
valid properties.

Reload replaces the configuration with the valid settings from the new file;
omitted or skipped settings use their defaults unless set by another valid line.
Appearance and bindings update without restarting the session. Zone definitions
update for later placement, movement, and cycling; existing windows are not
automatically rearranged. Match rules do not reapply to existing windows.
An unreadable file still causes startup to fail or leaves the current
configuration unchanged on reload.

This is a **Sway-like subset**, not a drop-in Sway configuration reader. Input
directives/blocks, other client states, includes, and other
unsupported commands produce warnings instead of being silently ignored.

## Zone layouts

Zones are shared across outputs. Their percentages use each output's usable
area, excluding space reserved by panels. For example:

```text
layout zones
zone NW 0% 0% 50% 50%
zone NE 50% 0% 50% 50%
zone C 10% 10% 80% 80%

bindsym Mod4+KP_Home move container to zone NW
bindsym Mod4+KP_Prior move container to zone NE
bindsym Mod4+KP_Begin move container to zone C
bindsym Mod4+Shift+f fixedSize toggle
bindsym Mod4+Tab cycle-zone NW|NE

for_window [app_id="^example-dialog$"] fixedSize on
for_window [app_id="^example-dialog$" title="Main window"] fixedSize off
```

`config.example` defines all eight compass directions plus `C`. North and south
span the full width and half the height. East and west span the full height and
half the width. Corners occupy quarters. Center occupies 80% of each axis.

Zone names are case-sensitive. Percentages must be finite and nonnegative,
width and height must be positive, and each zone must remain within 100% on
both axes. Zones may overlap. A repeated name replaces its earlier definition.
Without any zones, windows retain normal floating placement and do not snap.

### Moving and fixed-size windows

`move container to zone NAME` moves the focused window to that zone on its
current output. Normal windows resize to fill the zone, including space for
Nimzo's borders and titlebar. Clients can impose size limits or resize increments;
Nimzo positions the actual resulting frame within the zone.

`fixedSize on`, `fixedSize off`, and `fixedSize toggle` change the focused
window's state. They do not move or resize it immediately. With fixed size on,
zone placement preserves the current content dimensions. On each axis:

- If the zone touches only one output edge, align the frame to that usable edge.
- If the zone touches neither edge or both edges, center the frame within it.

This edge-aligned behavior also applies when an already fixed-size window is
explicitly moved to a zone. It is separate from the centered placement used
for a fixed-size window's first placement. Thus a fixed-size north window is
centered horizontally and aligned to the top; a northeast window aligns to the
top and right. Oversized windows may extend outside the zone. Keep the frame
within the usable output when it fits; otherwise keep its top-left corner
reachable without shrinking it.

Match rules use PCRE regular-expression searches. Use `^` and `$` for exact
matches. When both app ID and title are present, both must match. Rules run
once at initial placement, in file order; the last matching rule wins. The
default is fixed size off. Later title changes and configuration reloads do not
override manual state changes. Manual resizing remains available in either state.

### Dragging, membership, and initial placement

During a pointer move, a translucent blue overlay shows the best matching zone
on the output with the greatest window overlap. Release the drag to snap to
that zone, using the normal or fixed-size behavior. Resizing alone does not snap.

A window belongs to the zone with the greatest overlap with its content
rectangle. Ties prefer the closest dimensions, then definition order. If no
zone overlaps, use the nearest zone center. This geometric membership also
determines occupancy and which windows can be cycled.

New windows first request their natural dimensions. Normal, nonfixed windows
then choose a free zone with the closest dimensions on their workspace and
output. Compare width and height by their relative differences; definition
order breaks ties. If every zone is occupied, use the closest size match
anyway. Place the new window on top. Existing windows do not rearrange when
another window opens or closes.

An initial window is fixed-size when its matching `fixedSize on` configuration
rule enables it, or when its dimension hints report
`min_width == max_width > 0` and `min_height == max_height > 0`. Its natural
client dimensions are preserved; it is not resized to fill a zone. Center it in
the known live parent's zone when one is available. If the parent has no known
center in its usable output using the known parent workspace/output context,
including when another output is current. Without a live parent, use the zone
captured from the focused window at the start of placement on the current
output. If neither context exists, center it in the usable output. This initial
placement does not use the edge alignment rules above and is not recentered
later.

With zones configured, keep new windows, borders, and titlebars hidden while
obtaining the natural dimensions and requesting the placement resize. Hiding
does not stop client configuration or resizing. Use River's reported actual
dimensions to finish alignment, then resolve focus before revealing the window.
Fixed-size windows do not wait for an unnecessary second resize. Later resizes
of an already placed window do not restart this initial hiding.

River can report the current dimensions when a client exceeds its configure
timeout. The window-management protocol does not distinguish that response from
a client choosing to keep its current size, so an unresponsive client can still
produce a later visible resize.

### Cycling zone windows

`cycle-zone N|E` treats the named zones as one group on the current output's
active workspace. If focus is outside the group, select its top-most window.
The next invocation selects its bottom-most window, then subsequent invocations
continue upward and wrap. If focus starts inside the group, begin with the
bottom-most other window.

Cycling keeps a stable traversal even though each focused window is raised.
Changing the group, its members, workspace, or focus outside the traversal
starts a new traversal. An unknown zone or an empty group returns a command
error. Zone commands also work through `RUN_COMMAND` IPC.

### Fullscreen and minimized windows

`fullscreen` toggles the focused window. Use `fullscreen enable`,
`fullscreen disable`, or `fullscreen toggle` to choose the state explicitly.
Fullscreen windows use the whole output, including panel-reserved space, without
Nimzo's titlebar or borders. Nimzo informs the client of the fullscreen state;
leaving fullscreen restores the saved content geometry. Zone membership uses
that saved geometry rather than the fullscreen rectangle. Client fullscreen,
exit-fullscreen, and minimize requests are supported.

`minimize` hides the focused window and its decorations without moving it to
another workspace. The window keeps its geometry and zone membership and still
occupies that zone for initial placement. `cycle-zone` skips minimized windows.
`restore` restores and focuses the most recently minimized window on the active
workspace. `focus next`, bound to Alt+Tab in the defaults and example, includes
minimized windows and restores the selected one. A fullscreen window remains
fullscreen when minimized and returns to fullscreen when restored. If output
geometry changes, fit the restored floating window to the usable area when needed.

Pointer move, resize, and zone movement are rejected while a window is
fullscreen. Zone cycling still uses its saved zone. Fullscreen changes and
minimize/restore are rejected during an active pointer move or resize.
Workspace and output movement remain available,
and a fullscreen window is retargeted when its output changes. Selecting a
visible non-fullscreen window exits another visible fullscreen window on the same
workspace/output so the selected window can be seen.

## Workspaces and output navigation

Nimzo supports the workspace bindings in `config.example`, including:

```text
bindsym $mod+1 workspace number 1
bindsym $mod+Shift+1 move container to workspace number 1, workspace number 1
bindsym $mod+Left workspace prev
bindsym $mod+Right workspace next
bindsym $mod+Shift+Left move container to workspace prev
bindsym $mod+Shift+Right move container to workspace next
bindsym $mod+KP_Subtract focus output up
bindsym $mod+KP_Add focus output down
bindsym $mod+Shift+KP_Subtract move container to output up, focus output up
bindsym $mod+Shift+KP_Add move container to output down, focus output down
bindsym $mod+Control+KP_Subtract move workspace to output up
bindsym $mod+Control+KP_Add move workspace to output down
```

The example binds `Alt+Tab` to `focus next`, `$mod+f` to `fullscreen toggle`,
`$mod+Shift+f` to `fixedSize toggle`, `$mod+m` to `minimize`, and
`$mod+Shift+m` to `restore`.

- Each window belongs to one workspace. Each output shows one workspace;
  windows on other workspaces are hidden, including their decorations.
  These are Sway-style workspaces, not overlapping tag sets or tiled containers.
- Focus follows the mouse by default. Entering a visible window, or moving within
  an unfocused window under the pointer, focuses it without changing the stacking
  order. This works within one output and across outputs. A stationary pointer
  does not override Alt-Tab or other keyboard focus changes.
- Clicking window content or its titlebar raises it, even if it already has
  keyboard focus. Keyboard window selection and deliberate move/resize actions
  also raise their target. Alt-Tab skips the currently focused window when
  another eligible window exists, including after focus-follows-mouse.
- The pointer also selects the focused output and its visible workspace when it
  crosses empty desktop space. Keyboard commands and new windows use that output.
  If no window is under the pointer on a newly selected output, focus its top-most
  window, or clear window focus if the workspace is empty. Leaving a window for
  empty space on the same output keeps the current window focused.
- Pointer focus does not restore minimized windows or select hidden windows.
  Active move/resize operations and exclusive layer surfaces retain their focus
  protections. Entering a window can reclaim focus from a nonexclusive layer
  surface, such as an on-demand panel.
- `workspace [number] TARGET` selects a workspace, creating it on an eligible
  output if needed (normally the focused output without output rules).
  Named targets include `workspace "web browser"` or `workspace number "2:web"`. Numeric prefixes
  identify numbered workspaces, so `workspace number 2` also selects `2:web`.
  If the workspace belongs to another output, focus moves to that output.
- `workspace prev` and `workspace next` cycle through existing workspaces across
  all outputs, with wraparound. Numbered workspaces come first in numeric order;
  other names follow in lexical order. Empty inactive workspaces are removed.
  New outputs choose an unused workspace accepted by their workspace rules.
- `move container to workspace [number] TARGET` moves the focused window without
  following it. `TARGET` can also be `prev` or `next`. Chain a `workspace` command
  to follow the window, as in the example above.
- `focus output DIRECTION` focuses the visible workspace on that output.
  Directions are `left`, `right`, `up`, and `down`. The nearest output center in
  that direction is selected; perpendicular distance breaks ties. There is no
  directional wraparound. Windows on other outputs remain visible.
- `focus output prev` cycles backward through connected, usable outputs in
  compositor announcement order, with wraparound. It does not mean the last
  focused output. With one output, focus stays there; with no outputs, it does
  nothing. For example: `bindsym $mod+o focus output prev`.
- `move container to output DIRECTION` moves the focused window to the target
  output's visible workspace without following it.
- `move workspace to output DIRECTION` moves the current workspace and follows
  it. The destination's previous workspace becomes hidden. The source shows
  another workspace assigned to it, or a new empty workspace if none exists.
- Output moves preserve relative floating-window positions where possible,
  then fit windows to the destination's usable area. Disconnecting an output
  preserves its workspaces on a remaining output. Reload preserves workspaces.
  Workspace/output movement is ignored during an active pointer move or resize.

When workspace or output navigation selects another output, Nimzo focuses its
top-most window and warps the pointer to the center of that window's visible
content. If the workspace is empty, the pointer moves to the output center.
Switching workspaces on the same output does not warp the pointer.
`move workspace to output` also follows the workspace with the pointer;
`move container to output` alone does not.

`focus next` cycles through windows on the pointer-selected workspace,
including minimized windows; selecting a minimized window restores it before
focusing it.
River reports pointer coordinates only during management updates and does not
start an update for pointer motion alone. With multiple outputs, Nimzo requests
an idle update every 50 ms so empty-desktop crossings also update focus. The same
refresh runs on a single output while an unfocused visible window is under the
pointer, so movement within that window can focus it. Normal management updates
refresh coordinates immediately. An idle single-output seat does not need this
refresh when its hovered window is already focused.
Waybar can display and select these workspaces through the opt-in Sway IPC subset
described below. River Classic's tag protocols remain unsupported.

## Output configuration

Use exact connector names, such as `DP-3` and `HDMI-A-1`. Both inline directives
and blocks are supported:

```text
output DP-3 {
  resolution 2560x1440
  position 0 0
  adaptive_sync off
}
output HDMI-A-1 {
  resolution 1920x1080
  position below DP-3 gap 1
}
```
An output can be marked as the preferred workspace fallback. The inline form
can prefix another property with `default`:

```text
output DP-3 default position 0 0
```

The same properties can be written in a block. `workspaces` is a
case-sensitive, `|`-separated list; `*` is the only wildcard:

```text
output DP-3 {
  default
  workspaces 1|2|3|4|name*
  position 0 0
}
```

An output with no `workspaces` patterns is unrestricted. A numeric pattern also
matches a workspace name with that numeric prefix, so `1` matches both `1` and
`1:web`.

When a new workspace is created, an eligible output whose workspace patterns
explicitly match its name is preferred. If there is no explicit match, the
configured default output is the preferred fallback when it is eligible;
otherwise an unrestricted eligible output is used. Explicit output moves are
hard eligibility checks: a move to an output that does not accept the current
workspace is rejected rather than silently falling back to another output.
Reload keeps existing workspaces on their current output while it remains
eligible. If a reload makes that output ineligible, or the output disconnects,
the workspace is moved to an eligible fallback instead; a disconnected
output's matching patterns do not force the workspace onto an ineligible
output.
If no connected output accepts an existing workspace, it and its windows stay
hidden until an eligible output is available. A request to create or select a
workspace with no eligible output fails. An output with no available eligible
workspace stays empty. New output workspaces use an unused literal pattern
first, then an eligible unused positive number, then a wildcard name with `*`
replaced by a number. Without workspace rules, this keeps the previous lowest
unused positive number behavior.

The configured default output is the preferred workspace fallback and is also
the fallback for an unspecified layer-shell output when no current live seat
output is available. An unspecified layer-shell surface otherwise follows the
current output. Once mapped, a surface is not moved when the current output
changes, and a surface that explicitly selected an output remains there.
Pointer-selected outputs still control where new windows open.

`position` accepts either absolute logical coordinates (`position 0 0`) or
`left-of`, `right-of`, `above`, or `below` followed by a reference output name.
An optional `gap PIXELS` adds a non-negative gap in logical pixels; it defaults
to zero. Left/right placement aligns top edges; above/below aligns left edges.
For example, `output HDMI-A-1 position right-of DP-3` places it immediately to
the right of DP-3.

Relative placements can form chains and don't depend on declaration order.
Geometry uses the requested mode, scale, and transform, not raw pixel sizes.
A reference can be a connected output without its own configuration block.
Position lines that introduce self-references or circular dependencies are
skipped with a warning. Earlier valid output settings remain in effect.

Supported output properties:

- `resolution WIDTHxHEIGHT[@HZ]` (alias `mode`), e.g. `2560x1440@59.94Hz`.
- `position X Y` or `position DIRECTION OUTPUT [gap PIXELS]` (alias `pos`).
- `scale NUMBER`, including fractional scaling (quantized to 1/256).
- `transform normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270`.
- `workspaces PATTERN[|PATTERN...]`: restrict an output to matching workspace
  names. Patterns are case-sensitive; `*` matches any sequence, and a numeric
  pattern also matches names with that numeric prefix.
- `default`: mark this output as the preferred fallback for new workspaces.
- `enable` or `disable`. A matching rule enables its output by default.

Only one output may be marked `default`; a later conflicting default
declaration is rejected with a warning and does not change the earlier rule.

Repeated directives for one connector are merged; the last value of each
property wins. Outputs with no matching rule retain their settings. Rules for
disconnected targets are deferred. If a connected target's reference is missing
or disabled, the output transaction is deferred with a diagnostic and the
existing layout is left intact. It is reconsidered when output state changes.

Nimzo uses `zwlr_output_manager_v1` version 4, supplied by current River, without
an external helper. Layouts are recomputed on startup, reload, hotplug, and
mode/scale/transform changes. All connected heads are included in one atomic
output configuration, and the WM continues handling input while it is applied.
Hardware rejection leaves the previous output layout in place; a reload's
keyboard/font/color settings are independent of that asynchronous result.
Avoid running another persistent output configurator (such as kanshi) alongside
nimzo's output rules.

A requested mode must be supported by the output. Negative positions resulting
from `left-of` or `above` may be rejected by River when Xwayland is enabled;
choose a suitable positive absolute anchor in that case. `--validate` loads the
configuration and reports syntax/dependency warnings without needing connected
monitors. Parse warnings do not cause a nonzero exit status; unreadable files and
invalid command-line options still do. Hardware and reference availability are
checked at runtime.

## Waybar, swaybg, and other layer-shell clients

Nimzo binds `river_layer_shell_v1` to opt into River's layer-shell support.
Without this opt-in, River closes layer surfaces even though it advertises the
underlying `zwlr_layer_shell_v1` protocol. River itself arranges and renders the
background/bottom/top/overlay surfaces; nimzo supplies per-output/per-seat
integration, current-output selection, reserved-area placement, and
keyboard-focus cooperation. No Waybar or swaybg build dependency is required.

Start your chosen companions from `river/nimzo.config`:

```text
exec waybar
exec swaybg -i "$HOME/Pictures/wallpaper.png" -m fill
```

A solid color also works: `exec swaybg -c 203050`. Use swaybg's `-o OUTPUT` flag
for different images on different monitors. These are ordinary startup execs:
they run once, not on every nimzo reload. After adding a new startup exec, start
it manually or restart the session. Nimzo does not supervise/restart companions
or implement Sway's `bar { ... }` / `output ... bg ...` directives.

A minimal Waybar configuration and stylesheet are provided:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
cp examples/waybar.jsonc "${XDG_CONFIG_HOME:-$HOME/.config}/waybar/nimzo.jsonc"
cp examples/waybar.css "${XDG_CONFIG_HOME:-$HOME/.config}/waybar/nimzo.css"
```

To use those files, replace the plain `exec waybar` line with:

```text
exec waybar -c "${XDG_CONFIG_HOME:-$HOME/.config}/waybar/nimzo.jsonc" -s "${XDG_CONFIG_HOME:-$HOME/.config}/waybar/nimzo.css"
```

Waybar owns its JSON/CSS configuration; nimzo's `font`/`client.*` settings only
style window decorations. If you launch Waybar through a shell wrapper, make
sure it forwards arguments (`exec waybar.real "$@"`), otherwise `-c`/`-s` are lost.

Panel exclusive zones are honored when placing new windows and when an output's
usable area changes, including panels appearing after startup. Coordinates are
per-output and global-coordinate-correct. Titlebars and borders are included;
when a frame fits, it is placed within the usable area. Oversized floating
windows are not forcibly resized, and intentional interactive moves/resizes can
cross reserved areas. The configured default output is used for clients that do
not choose one only when no current output is available; an already mapped
layer surface is not moved to follow a later output change.

Keyboard-interactive layer clients (launchers/panel widgets) may take exclusive
or on-demand focus without nimzo immediately stealing it back. Window focus is
restored when the layer client releases it. While a layer surface has focus,
window decorations use unfocused colors and window-close shortcuts do not close
the remembered background window. Global exec/reload/exit bindings still work.

**Waybar module compatibility:** The default example uses `wlr/taskbar` and
`clock`; system modules such as CPU/memory/network can also be used. The taskbar
sets `all-outputs: true` because the current River checkout does not report
per-output membership for its foreign-toplevel handles. Nimzo keeps a native
foreign-toplevel handle alive while a window is minimized, so it remains in
taskbar listings, but the current River checkout does not forward
foreign-toplevel activate/close/minimize requests to nimzo. Taskbar buttons
therefore cannot activate, close, minimize, or restore windows; use Nimzo's
shortcuts or `RUN_COMMAND` IPC instead. Highlights and listings still work.

### Sway workspace IPC

To enable Waybar's `sway/workspaces` display and click/scroll actions, set
`SWAYSOCK` before starting Nimzo. For example, in your River init script:

```sh
export SWAYSOCK="$XDG_RUNTIME_DIR/nimzo-ipc.sock"
exec nimzo
```

Waybar must inherit the same variable; launching it with a Nimzo startup `exec`
does this. Add the following to your Waybar JSON configuration:

```json
{
  "modules-left": ["sway/workspaces"],
  "sway/workspaces": {
    "disable-auto-back-and-forth": true
  }
}
```

Nimzo creates a private Unix socket only when `SWAYSOCK` is nonempty and the path
does not exist. Existing files, sockets, and symlinks are never replaced,
including stale sockets. Normal exit and SIGTERM/SIGINT remove the socket
Nimzo created; a forced SIGKILL can leave a stale socket.

The socket implements Sway's `i3-ipc` framing with native-endian 32-bit length
and request type fields. Supported requests are:

- `RUN_COMMAND` (type 0): execute the command text in the payload using Nimzo's
  binding command parser and the default (first live) seat. This includes
  workspace selection/movement, output focus/movement, close, focus next,
  fullscreen, minimize/restore, pointer move/resize, zone movement/cycling,
  fixed-size state, exec, reload, and exit.
- `GET_TREE` (type 4): live output/workspace/floating-window hierarchy, stable
  node IDs, output names, workspace numbers, visibility, focus, titles, app IDs,
  logical geometry, fullscreen mode, minimized state, and zone membership.
- `SUBSCRIBE` (type 2): `workspace` subscriptions, including repeated
  subscriptions on one connection. Workspace reload notifications tell Waybar
  to fetch a new tree when the published state changes, including window changes.
  `window` subscriptions are acknowledged for Waybar's startup handshake, but
  this subset does not emit native window events; subscribe to `workspace` for
  updates. Waybar's `sway/workspaces` does this automatically.

Command payloads are plain text, not JSON. For example:

```text
move container to workspace number 3; workspace --no-auto-back-and-forth number 3
```

Commands can be separated by unquoted `;`, `,`, or newlines. The reply is a
type-0 frame containing an array of results, such as:

```json
[{"success": true}, {"success": true}]
```

A failed command has `success: false` and an `error` message. Invalid syntax also
has `parse_error: true` and stops the chain; earlier commands remain applied.
Execution failures do not roll back earlier commands, and later commands still
run. Missing targets, active pointer operations, and unreadable reload files are
failures, not successful no-ops. Configuration-file warning recovery does not
suppress IPC errors.

Commands run during River's manage sequence. Replies wait until the resulting
tree is published, and a following `GET_TREE` on the same connection cannot
overtake the command. `exec` success means the child was spawned, not that the
shell command finished successfully. Close success means a close request was
sent; the application can close later. Exit replies are flushed before Nimzo
asks River to stop.

Waybar's workspace click and default scroll commands are supported, including
`workspace --no-auto-back-and-forth [number] TARGET`. Nimzo does not automatically
toggle back to the previous workspace, so this flag retains its normal selection
behavior. Remove any earlier `disable-click` or `disable-scroll` settings to use
those actions.

This is not full Sway IPC. Unsupported commands, window criteria, and optional
Waybar modes that require them (such as `no-switch-output` or persistent-workspace
output reassignment) return errors. `mouse_warping` and other unsupported Sway
features remain errors. Other Sway modules and River Classic's `river/tags` or
`river/layout` protocols are not supplied by this subset.

The socket is writable control access to your session, including `exec`; only
clients allowed by its filesystem permissions should be given access.

## Appearance

Windows get a 2-pixel `#8B0000` border. For clients supporting server-side
decorations, Nimzo adds a 24-pixel titlebar with a 2-pixel outline aligned with
the window's outer edges. The titlebar outline has its own color; its width
always matches the window border. UTF-8 titles update automatically and long
titles are ellipsized within the outline.

Use `font`, `client.focused`, and `client.unfocused` to change the appearance.
The optional sixth palette color controls the titlebar border. For example:

```text
#                border  background text    indicator child_border titlebar_border
client.focused   #8b0000 #8b0000    #ffffff #8b0000  #8b0000      #a82020
client.unfocused #500000 #500000    #dddddd #500000  #500000      #702020
```

These are the brighter red titlebar borders used in `config.example`. Existing
three-, four-, and five-color palettes remain valid and use their window-border
color for the titlebar border. Palette changes apply on configuration reload.

The titlebar does not draw buttons. Use Super+left drag to move windows.
Client-side-only decorations remain controlled by the client.

## Testing

Run the configuration/command unit tests and protocol regression tests
(requires Python 3.9+):

```sh
nimble test
```

These check parsing and warning recovery, title rendering, focus colors,
reload, decoration resizing/removal, keyboard bindings, interactive move/resize,
relative output geometry, hotplug, output transaction failures, layer-shell
focus/reserved-area handling and lifetimes, and child-process wait semantics
without requiring a graphical session. IPC regressions cover framing, live tree
updates, subscriptions, nonblocking clients, socket permissions, and safe cleanup.
Zone regressions cover percentage geometry, decorated and fixed-size placement,
initial free-zone selection, matching rules, stable focus traversal, drag
previews, and snapping with the final movement delta.
Pointer-focus regressions cover pointer entry and movement without raising,
click-to-raise on an already-focused window, independent focus and stacking order,
stationary-pointer keyboard navigation, layer and drag protections, output
crossings, stale cross-output window interactions, placement on the
pointer-selected workspace, and navigation warps to occupied and empty outputs.

## Running

```sh
river -c ./nimzo
```

Alternatively, launch `/absolute/path/to/nimzo` from your executable
`~/.config/river/init` script. `river/init` starts the WM; `river/nimzo.config`
configures nimzo.

## Licensing

Nimzo's code is licensed under 0BSD. The bundled River protocol definitions are
MIT-licensed. The output-management protocol is copyright 2019 Purism SPC and
retains its permissive license notice in
[`protocol/wlr-output-management-unstable-v1.xml`](protocol/wlr-output-management-unstable-v1.xml).
See the SPDX headers and [`LICENSES/`](LICENSES/).
