#!/bin/sh
set -eu

: "${XDG_RUNTIME_DIR:?Run this script inside a user session}"
umask 077
exec >>"$XDG_RUNTIME_DIR/nimzo-screencast.log" 2>&1
printf '\n[%s] Starting Nimzo screencast backend\n' "$(date -Is)"

: "${WAYLAND_SOCKET:?Launch this script from a Nimzo capture profile}"
: "${WAYLAND_DISPLAY:?Run this script inside a Nimzo session}"

# The portal frontend and chooser use the ordinary display, not our private FD.
export XDG_CURRENT_DESKTOP=nimzo
dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec /usr/lib/xdg-desktop-portal-wlr --replace --loglevel=INFO "$@"
