import std/[os, strutils]

const buildRoot = currentSourcePath().parentDir.parentDir

proc pkgConfig(arguments: string): string =
  let command = quoteShell(getEnv("PKG_CONFIG", "pkg-config")) & " " & arguments
  let response = gorgeEx(command)
  if response.exitCode != 0:
    raise newException(ValueError, command & " failed:\n" & response.output)
  response.output.strip

proc scanner(): string =
  result = getEnv("WAYLAND_SCANNER")
  if result.len == 0: result = pkgConfig("--variable=wayland_scanner wayland-scanner")

proc protocolDirectory(): string =
  result = getEnv("WAYLAND_PROTOCOLS")
  if result.len == 0: result = pkgConfig("--variable=pkgdatadir wayland-protocols")

proc generateProtocol(mode, source, target: string) =
  exec "if [ ! -f " & quoteShell(target) & " ] || [ " & quoteShell(source) &
    " -nt " & quoteShell(target) & " ]; then " & quoteShell(scanner()) & " " &
    mode & " " & quoteShell(source) & " " & quoteShell(target) & "; fi"

const protocolSpecs: array[8, tuple[mode, source, target: string; vendored: bool]] = [
  ("enum-header", "staging/cursor-shape/cursor-shape-v1.xml", "cursor-shape-v1-protocol.h", false),
  ("enum-header", "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml", "ext-image-copy-capture-v1-protocol.h", false),
  ("enum-header", "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", "pointer-constraints-unstable-v1-protocol.h", false),
  ("enum-header", "wlr-layer-shell-unstable-v1.xml", "wlr-layer-shell-unstable-v1-protocol.h", true),
  ("server-header", "wlr-output-power-management-unstable-v1.xml", "wlr-output-power-management-unstable-v1-protocol.h", true),
  ("server-header", "stable/xdg-shell/xdg-shell.xml", "xdg-shell-protocol.h", false),
  ("server-header", "wlr-foreign-toplevel-management-unstable-v1.xml", "wlr-foreign-toplevel-management-unstable-v1-protocol.h", true),
  ("private-code", "wlr-foreign-toplevel-management-unstable-v1.xml", "wlr-foreign-toplevel-management-unstable-v1-protocol.c", true)]

proc generateProtocols() =
  let systemProtocols = protocolDirectory()
  for spec in protocolSpecs:
    let directory = if spec.vendored: buildRoot / "protocols" else: systemProtocols
    generateProtocol(spec.mode, directory / spec.source, buildRoot / spec.target)

proc nativeFlags(): tuple[cflags, libs: string] =
  let xwayland = getEnv("NIMZO_XWAYLAND", "1") != "0"
  let packages = "wayland-server xkbcommon libinput pangocairo" &
    (if xwayland: " xcb xcb-icccm" else: "")
  let wlrIncludes = getEnv("WLR_INCS")
  let wlrLibraries = getEnv("WLR_LIBS")
  result.cflags = "-I" & quoteShell(buildRoot) &
    " -DWLR_USE_UNSTABLE -D_POSIX_C_SOURCE=200809L " &
    (if xwayland: "-DXWAYLAND " else: "") & pkgConfig("--cflags " & packages) & " " &
    (if wlrIncludes.len != 0: wlrIncludes else: pkgConfig("--cflags wlroots-0.20")) &
    " " & getEnv("CPPFLAGS") & " " & getEnv("CFLAGS")
  result.libs = pkgConfig("--libs " & packages) & " " &
    (if wlrLibraries.len != 0: wlrLibraries else: pkgConfig("--libs wlroots-0.20")) &
    " -lm " & getEnv("LDFLAGS") & " " & getEnv("LIBS")

proc buildTestClients(work: string) =
  for definition in [
      (protocolDirectory() / "stable/xdg-shell/xdg-shell.xml", "xdg-shell", "zone_client.c", "zone-client"),
      (buildRoot / "protocols/wlr-foreign-toplevel-management-unstable-v1.xml", "foreign-toplevel", "window_state_client.c", "state-client"),
      (protocolDirectory() / "staging/ext-session-lock/ext-session-lock-v1.xml", "ext-session-lock", "session_lock_client.c", "session-lock-client")]:
    let header = work / (definition[1] & "-client-protocol.h")
    let code = work / (definition[1] & "-protocol.c")
    generateProtocol("client-header", definition[0], header)
    generateProtocol("private-code", definition[0], code)
    exec quoteShell(getEnv("CC", "cc")) & " -I" & quoteShell(work) & " " &
      pkgConfig("--cflags wayland-client") & " " &
      quoteShell(buildRoot / "tests" / definition[2]) & " " & quoteShell(code) & " " &
      pkgConfig("--libs wayland-client") & " -o " & quoteShell(work / definition[3])
  if getEnv("NIMZO_XWAYLAND", "1") != "0":
    exec quoteShell(getEnv("CC", "cc")) & " " & pkgConfig("--cflags xcb") & " " &
      quoteShell(buildRoot / "tests/xwayland_rule_client.c") & " " & pkgConfig("--libs xcb") &
      " -o " & quoteShell(work / "xwayland-rule-client")
