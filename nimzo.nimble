# SPDX-FileCopyrightText: © 2026 Isaac Freund
# SPDX-License-Identifier: 0BSD

version = "0.1.0"
author = "Isaac Freund"
description = "nimzo (Nim zones), a configurable river window manager"
license = "0BSD"
requires "nim >= 2.0.0"
srcDir = "."
bin = @ ["nimzo"]

before build:
  exec "wayland-scanner client-header protocol/river-window-management-v1.xml protocol/river-window-management-v1-client-protocol.h"
  exec "wayland-scanner private-code protocol/river-window-management-v1.xml protocol/river-window-management-v1-protocol.c"
  exec "wayland-scanner client-header protocol/river-xkb-bindings-v1.xml protocol/river-xkb-bindings-v1-client-protocol.h"
  exec "wayland-scanner private-code protocol/river-xkb-bindings-v1.xml protocol/river-xkb-bindings-v1-protocol.c"
  exec "wayland-scanner client-header protocol/river-layer-shell-v1.xml protocol/river-layer-shell-v1-client-protocol.h"
  exec "wayland-scanner private-code protocol/river-layer-shell-v1.xml protocol/river-layer-shell-v1-protocol.c"
  exec "wayland-scanner client-header protocol/wlr-output-management-unstable-v1.xml protocol/wlr-output-management-unstable-v1-client-protocol.h"
  exec "wayland-scanner private-code protocol/wlr-output-management-unstable-v1.xml protocol/wlr-output-management-unstable-v1-protocol.c"

task test, "Run configuration, geometry, layer-shell, and protocol regression tests":
  exec "nim c -r --out:tests/test_config tests/test_config.nim"
  exec "nim c -r --out:tests/test_zones tests/test_zones.nim"
  exec "nim c -r --out:tests/test_outputs tests/test_outputs.nim"
  exec "nim c -r --out:tests/test_work_area tests/test_work_area.nim"
  exec "nimble build"
  exec "python3 tests/test_protocol.py"
