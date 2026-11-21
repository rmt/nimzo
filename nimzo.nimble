version = "0.9.0"
author = "nimzo contributors"
description = "A Wayland compositor built with Nim and wlroots 0.20"
license = "GPL-3.0-or-later"
bin = @["nimzo"]
requires "nim >= 2.2.0"

include "tools/build_support.nims"

proc compileProgram(source, target: string) =
  exec quoteShell(getEnv("NIM", "nim")) & " c --out:" & quoteShell(target) & " " & quoteShell(source)

proc temporaryDirectory(): string =
  let response = gorgeEx("mktemp -d")
  if response.exitCode != 0:
    raise newException(IOError, response.output)
  response.output.strip

task test, "Run parser, geometry, IPC, and headless real-client tests":
  let work = temporaryDirectory()
  try:
    for name in ["runtime_config", "zones_geometry", "sway_ipc"]:
      let target = work / name
      compileProgram(buildRoot / "tests" / ("test_" & name & ".nim"), target)
      exec quoteShell(target)
    let compositor = work / "compositor"
    compileProgram(buildRoot / "tests/test_runtime_compositor.nim", compositor)
    exec "timeout 15 " & quoteShell(compositor)
    buildTestClients(work)
    for name in ["ipc_dispatch", "zones_compositor", "output_rotation", "titlebars", "pointer_outputs", "window_states", "window_rules", "session_lock"]:
      let target = work / name
      compileProgram(buildRoot / "tests" / ("test_" & name & ".nim"), target)
      exec "NIMZO_ZONE_CLIENT=" & quoteShell(work / "zone-client") &
        " NIMZO_STATE_CLIENT=" & quoteShell(work / "state-client") &
        " NIMZO_X11_CLIENT=" & quoteShell(work / "xwayland-rule-client") &
        " NIMZO_SESSION_LOCK_CLIENT=" & quoteShell(work / "session-lock-client") &
        " timeout 15 " & quoteShell(target)
  finally:
    rmDir(work)

task testWaybar, "Run a real Waybar against private headless outputs":
  let work = temporaryDirectory()
  try:
    compileProgram(buildRoot / "nimzo.nim", work / "nimzo")
    buildTestClients(work)
    exec "python3 " & quoteShell(buildRoot / "tests/test_waybar.py") & " " &
      quoteShell(getEnv("WAYBAR", "waybar")) & " " & quoteShell(work / "zone-client") &
      " " & quoteShell(work / "state-client") & " " & quoteShell(work / "nimzo")
  finally:
    rmDir(work)

proc installationFiles(): seq[(string, string, string)] =
  let prefix = getEnv("PREFIX", "/usr/local")
  let stage = getEnv("DESTDIR")
  let data = stage & getEnv("DATADIR", prefix / "share")
  let notices = data / "licenses/nimzo"
  result = @[("nimzo", stage & prefix / "bin/nimzo", "755"),
    ("nimzo.1", stage & getEnv("MANDIR", prefix / "share/man") / "man1/nimzo.1", "644"),
    ("nimzo.desktop", data / "wayland-sessions/nimzo.desktop", "644")]
  for name in ["LICENSE", "LICENSE.dwm", "LICENSE.sway"]:
    result.add (name, notices / name, "644")
  for name in ["wlr-foreign-toplevel-management-unstable-v1.xml",
      "wlr-layer-shell-unstable-v1.xml", "wlr-output-power-management-unstable-v1.xml"]:
    result.add ("protocols" / name, notices / name, "644")

task installSystem, "Build and install binary, manual, session, and notices (PREFIX, DESTDIR)":
  compileProgram(buildRoot / "nimzo.nim", buildRoot / "nimzo")
  for entry in installationFiles():
    exec "install -D -m " & entry[2] & " " & quoteShell(buildRoot / entry[0]) & " " & quoteShell(entry[1])

task uninstallSystem, "Remove installed binary, manual, session, and notices":
  for entry in installationFiles():
    if fileExists(entry[1]): rmFile(entry[1])

proc cleanGeneratedFiles() =
  let binary = buildRoot / "nimzo"
  if fileExists(binary): rmFile(binary)
  for spec in protocolSpecs:
    let file = buildRoot / spec.target
    if fileExists(file): rmFile(file)

after clean:
  cleanGeneratedFiles()

task cleanGenerated, "Remove the compositor and generated protocol files":
  cleanGeneratedFiles()

task dist, "Create a source archive without generated build outputs":
  let name = "nimzo-" & version
  var sources = @["LICENSE", "LICENSE.dwm", "LICENSE.sway",
    "CHANGELOG.md", "README.md", "CONTRIBUTING.md",
    "nimzo.nimble", "config.nims", "config.example", "examples", "tests",
    "nimzo_ffi.h", "wlr_foreign_toplevel_management.c",
    "wlr_foreign_toplevel_management.h", "tools", "protocols", "nimzo.1", "nimzo.desktop"]
  for file in listFiles(buildRoot):
    if file.endsWith(".nim"): sources.add file.extractFilename
  var command = "tar -czf " & quoteShell(buildRoot / (name & ".tar.gz")) &
    " --transform=" & quoteShell("s,^," & name & "/,") & " -C " & quoteShell(buildRoot)
  for source in sources: command.add " " & quoteShell(source)
  exec command
