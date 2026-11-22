# nimzo (Nim Zones Wayland Compositor)

Nimzo is a manually tiling compositor for Wayland, written in Nim and using the
concept of workspace `zones`.  It supports multiple outputs with independent
workspaces, and keyboard actions to place windows into zones and to focus &
cycle windows in zones.  Zones may overlap, and focus+cycling can span multiple
zones.

It supports enough of the sway IPC to support Waybar's sway workspaces and the
taskbar with per-workspace windows.

It has simple theming, with titlebar and border colours.

It uses a sway/i3-like configuration file.

Screenshots are on [the wiki](https://github.com/rmt/nimzo/wiki)

## Origin Story

For many years I used OpenBox on X with a custom script to perform manual
tiling and per-region focus cycling, making it extremely fast to jump around
between workspaces and windows.

Wayland didn't come with a standard means to achieve that, so back in 2023 I
patched LabWC to support it.  The devs didn't particularly like manual tiling
as a feature (it felt too much like tiling to them), and the patch lingered.
LLMs came about, and I started using them to rebase the patch every few weeks.
Much to their credit, the devs made some useful changes to the core window
handling to make this use-case easier.  They later introduced a strict no-AI
policy: It's a free world, and they are free to build walls.

I decided to explore other compositors, and MangoWM looked slick, so I set the
LLMs to work and it made a nice layout that worked for me, and opened a ticket
to float the idea and gather interest for manual tiling, but MangoWM's BDFL
declined.  It seems like manual tiling doesn't have a natural home in tiling
compositor's either.

Along the way, someone suggested that I sound like an i3 user, so I tried Sway
(a Wayland compositor port of i3), and I realised that it is actually
fantastically configurable so I took the OpenBox approach and made zones work
with an external program, but Sway also had a couple of long-standing bugs (not
shared by i3).  Except for those i3 compatibility bugs, Sway is great - Kudos
to them!

While waiting for my bugfixes to get merged, I looked into River, and had my
coding agent write a River WM, which was a more ambitious project, and got me
closer to my ideal flow, except for a couple of
already-reported-with-long-pending-MRs bugs (I'm noticing a pattern) that made
Waybar annoying.  It's easy enough to patch, but on closer inspection, River is
just another hobby project - good for them.

At this point, I realised that I could probably get LLMs to write my own
compositor based on DWL and share it for others to use.  I have a fondness for
the Nim programming language, so I first had the AI port it to Nim, and it just
worked, so I decided to keep DWL's GPL license (as far as licenses can be
applied to mostly AI generated code).  I then iterated feature-by-feature,
testing as I went.

The conclusion: In late 2026, LLMs can code Wayland compositors.

## Build and install

You'll need Nim 2.2 or later (with Nimble), a C compiler, pkg-config,
wayland-scanner, wayland-protocols, and the development packages for Wayland,
wlroots 0.20, libinput, xkbcommon, and Pango/Cairo (`pangocairo`). Xwayland
support is enabled by default and also needs XCB and XCB-ICCCM. To build
without it, run `NIMZO_XWAYLAND=0 nimble build`.

```sh
nimble build
./nimzo -C -c config.example
```

`-C` checks the configuration and exits without starting a Wayland session.

Standard `nimble install` only installs the binary. If you also want the man
page, Wayland session entry, and license notices (installed under
`DATADIR/licenses/nimzo/`), run `nimble installSystem`. You can override
`PREFIX` (defaults to `/usr/local`), `MANDIR`, and `DATADIR`, or set
`DESTDIR` for a staged install without root:

```sh
DESTDIR=/tmp/nimzo-package PREFIX=/usr nimble installSystem
```

`nimble uninstallSystem` removes those files using the same path variables.
If you're packaging nimzo, `nimble dist` builds a source tarball with all
license notices from a clean checkout.

## Configure and run

Copy [config.example](config.example) to `~/.config/nimzo/config` and adjust
the output names and keybindings to suit your setup. You can check changes
with `nimzo -C -c PATH` before reloading or restarting. For the full syntax,
defaults, and available commands, see `man nimzo` or [nimzo.1](nimzo.1).

You can start `nimzo` directly from a VT or nested inside an existing Wayland
or X11 session. Make sure `XDG_RUNTIME_DIR` is set before starting it; a
direct VT session also needs access to input and display devices through
logind or seatd. If you'd rather launch it from a display manager,
`nimble installSystem` installs the Wayland session entry.

## Access restrictions

Both restrictions default to `on`. Set either to `off` in your Nimzo config
only if you trust the clients that can connect to that socket:

| Setting | What `off` allows | To apply |
| --- | --- | --- |
| `sway_ipc_restricted` | All supported IPC requests, including shell commands and profile launches. | Reload from a key binding. |
| `wayland_protocols_restricted` | All Wayland clients can bind privileged protocols, including screen capture, clipboard control, and virtual input. | Restart Nimzo. |

## Screenshots with grim

By default, Nimzo does not give `grim` access to screen capture on the
ordinary Wayland socket. Add a capture profile and a key binding to your
Nimzo configuration, then reload it:

```text
wayland_client screenshot capture /usr/bin/grim
bindsym Print launch screenshot
```

Press Print to save a timestamped PNG. To save a JPEG to a specific path,
replace the profile line with:

```text
wayland_client screenshot capture /usr/bin/grim -t jpeg /tmp/nimzo-screenshot-1.jpg
```

For timestamped JPEGs, use the absolute path to
[`examples/grim-screenshot.sh`](examples/grim-screenshot.sh) in place of
`/usr/bin/grim`. The script saves to `$GRIM_DEFAULT_DIR`, then
`$XDG_PICTURES_DIR`, or `$HOME/Pictures` if neither variable is set.

You can also run `swaymsg 'launch screenshot'` from a terminal if you already
use unrestricted Sway IPC. The Print binding works with restricted IPC.

## Waybar

Waybar is optional, but if you want a panel, there's an example setup using
`sway/workspaces`, `sway/window`, and `wlr/taskbar`. Copy
[waybar.jsonc](examples/waybar.jsonc) to `~/.config/waybar/config.jsonc` and
[waybar.css](examples/waybar.css) to `~/.config/waybar/style.css`. Add these
lines to your Nimzo configuration. Use the absolute paths on your system.

```text
sway_ipc_restricted on
wayland_client waybar toplevel /usr/bin/waybar
launch waybar
wayland_client waylock session-lock /usr/bin/waylock
bindsym Ctrl+Alt+l launch waylock
```

A few notes:

- Leave out Waybar's `output` filter if you want a bar on every monitor.
- The default `sway_ipc_restricted on` allows workspace and window updates
  and workspace selection. It does not expose the configuration or accept
  commands such as `exec`, `reload`, `exit`, or `launch`.
- Top-level `launch` runs only at startup. To restart Waybar without restarting
  Nimzo, configure a key binding to `launch waybar`. With Wayland restrictions
  on, starting `waybar` or `waylock` directly does not grant access to the
  taskbar or lock protocols.
- If you're writing your own Waybar config and want plain tag labels, set
  both `format` and `format-for-negative-index` to `{name}` in
  `sway/workspaces`.

You can run the real-client Waybar integration test with `nimble testWaybar`
(see [CONTRIBUTING.md](CONTRIBUTING.md) for the test dependencies).

Note: Waybar has some bugs and performance issues related to its synchronous
initialization sequence, which is especially evident on spinning disks, so if
you have issues with Waybar not displaying after startup, you can take the
patches from https://github.com/rmt/Waybar.

## Screen Locker

Do not use waylock until https://codeberg.org/ifreund/waylock/issues/134 is
fixed, unless you also set `wayland_protocols_restricted off` in the config
file.

Swaylock works fine.

## Contribute

Github PRs are closed as primarily LLM projects make for lousy community
projects, and I can probably prompt my coding agent better than you can prompt
yours.  You can create an issue with enough information and add a human
explanation about why this matters to you, then I'll look into it.  Ideas and
feature requests are welcome, but I'm a little opinionated myself.

If you want to poke around the codebase, run the tests, or regenerate the
wlroots bindings yourself, [CONTRIBUTING.md](CONTRIBUTING.md) has the source
map, build options, and test setup.

## License

nimzo is licensed under [GPL-3.0-or-later](LICENSE). Alongside it, the repo
includes upstream notices for [dwm](LICENSE.dwm), the
[Sway-derived input-method code](LICENSE.sway), and the bundled Futhark
parser patch ([MIT](tools/LICENSE.futhark)). The three vendored
[protocol XML files](protocols/) carry their own `<copyright>` notices, and
any file-specific licenses are noted in the relevant source files.

## Credits

- [dwl](https://codeberg.org/dwl/dwl) and its contributors, along with its
  [dwm](https://dwm.suckless.org/) and TinyWL (CC0-1.0) roots. The
  [changelog](CHANGELOG.md) keeps the upstream dwl release history.
- Sway, labwc, and mangowm contributors for the input-method code inherited
  through dwl, and Sway and i3 for the config syntax and IPC that nimzo
  targets.
- wlroots and Wayland for the compositor libraries and protocols, and Waybar
  for panel and taskbar integration.
