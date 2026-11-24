# Assemble the compositor for the executable and headless tests. Include
# after defining VERSION. Native declarations precede their consumers.

import std/[os, strutils, math, json]
from std/unicode import validateUtf8
from std/posix as ipcPosix import nil
import runtime_config, zones_geometry, sway_ipc, titlebar_render, wayland_process
include bindings
include compat
include types
include globals
include util
include config_defaults
include client
include input_method_relay
include output_rules
include wayland_access
include runtime_apply
include zones_runtime
include zones_interaction
include output_recovery
include wlr_foreign_toplevel_management
include titlebar_runtime
include window_stack
include sway_ipc_compositor
include compositor
