#!/bin/sh
set -eu

export GRIM_DEFAULT_DIR="${GRIM_DEFAULT_DIR:-${XDG_PICTURES_DIR:-$HOME/Pictures}}"
mkdir -p -- "$GRIM_DEFAULT_DIR"
exec grim -t jpeg
