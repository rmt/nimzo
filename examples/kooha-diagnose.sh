#!/bin/sh
set -eu

for tool in kooha pw-mon journalctl; do
    command -v "$tool" >/dev/null || { printf 'Missing command: %s\n' "$tool" >&2; exit 1; }
done

umask 077
logs=$(mktemp -d "${TMPDIR:-/tmp}/nimzo-kooha.XXXXXXXX")
since=$(date '+%Y-%m-%d %H:%M:%S')
pw-mon -N -a >"$logs/pipewire-graph.log" 2>&1 &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || :; wait "$monitor" 2>/dev/null || :' EXIT

printf 'Quit any existing Kooha instance first. Reproduce the error, then close Kooha.\nLogs: %s\n' "$logs"
status=0
GST_DEBUG='pipewiresrc:6' PIPEWIRE_DEBUG=3 RUST_LOG=kooha=debug \
    kooha "$@" >"$logs/kooha.log" 2>&1 || status=$?
journalctl --user --since "$since" --no-pager \
    -u pipewire.service -u wireplumber.service -u xdg-desktop-portal.service \
    >"$logs/services.log" 2>&1 || :
printf 'Review the logs for private details before sharing: %s\n' "$logs"
exit "$status"
