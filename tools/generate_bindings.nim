# Generate Nim bindings for the native ABI with Futhark and the patched
# opir parser. Select API roots and adapt C names and import pragmas.
# See CONTRIBUTING.md. The regular build does not need either tool.

import std/[json, macros, os, sets, strutils]
import futhark

const root = currentSourcePath.parentDir.parentDir

proc nativeName(name: string; kind: SymbolKind; parent: string;
    overload: var bool): string =
  # Nim ignores letter case after the first character. Keep lowercase Latin
  # keysyms available under their C names without colliding with uppercase ones.
  if name.startsWith("XKB_KEY_") and name.len == 9 and name[8] in {'A'..'Z'}:
    return "XKB_KEY_upper_" & name[8]
  result = name
  for prefix in ["struct_", "union_", "enum_"]:
    if result.startsWith(prefix):
      return result[prefix.len .. ^1]

proc libcHeader(name: string; kind: SymbolKind; pragmas: var seq[NimNode]) =
  if kind != Proc: return
  let header = case name
    of "printf", "fprintf", "vfprintf", "snprintf", "fflush", "fputc", "perror", "fileno": "<stdio.h>"
    of "strlen", "strcmp", "strstr", "strncpy", "strdup", "memcpy", "memset": "<string.h>"
    of "calloc", "free", "exit", "getenv", "setenv", "unsetenv", "abs": "<stdlib.h>"
    of "close", "dup2", "pipe", "fork", "setsid", "execvp", "execl": "<unistd.h>"
    of "getopt": "<getopt.h>"
    of "fcntl": "<fcntl.h>"
    of "ceilf", "fabs", "floor": "<math.h>"
    else: ""
  if header.len != 0:
    pragmas.add nnkExprColonExpr.newTree(ident("header"), newLit(header))

proc scopeNativeDeclarations(nodes: JsonNode): JsonNode =
  var symbols = initHashSet[string]()
  for file in ["types.nim", "globals.nim", "compositor.nim", "client.nim",
      "input_method_relay.nim", "util.nim", "config_defaults.nim", "compat.nim", "output_recovery.nim",
      "runtime_apply.nim", "output_rules.nim", "sway_ipc_compositor.nim",
      "titlebar_runtime.nim", "wayland_access.nim", "wlr_foreign_toplevel_management.nim",
      "window_overview.nim", "zones_interaction.nim",
      "zones_runtime.nim"]:
    for symbol in readFile(root / file).split({'\0'..'/', ':'..'@', '['..'^', '`', '{'..'\255'}):
      if symbol.len != 0:
        symbols.incl symbol
        for suffix in ["_proc", "_const", "_typedef", "_struct"]:
          if symbol.endsWith(suffix):
            symbols.incl symbol[0 ..< symbol.len - suffix.len]
  for node in nodes:
    let name = if node.hasKey("name"): node["name"].getStr else: ""
    var used = name in symbols
    if not used:
      case node["kind"].getStr
      of "const":
        used = name.startsWith("XKB_KEY_") or name.startsWith("KEY_") or name.startsWith("BTN_")
      of "enum":
        for field in node["fields"]:
          if field["name"].getStr in symbols: used = true
      of "struct", "union":
        let cut = name.find('_')
        used = cut >= 0 and name[cut + 1 .. ^1] in symbols
      else: discard
    # Keep all declarations for dependency resolution. Only mark the requested
    # roots as imports, so unrelated libc extensions do not enter the binding.
    node["file"] = %(if used: root / "nimzo_ffi.h" else: "/nimzo-native-dependency")
  nodes

macro generate(): untyped =
  var body = newStmtList()
  body.add newCall(ident("outputPath"), newLit(root / "bindings.nim"))
  body.add newCall(ident("renameCallback"), bindSym"nativeName")
  body.add newCall(ident("pragmasCallback"), bindSym"libcHeader")
  let callback = quote do:
    (proc(nodes: JsonNode): JsonNode {.closure.} = scopeNativeDeclarations(nodes))
  body.add newCall(ident("addOpirCallback"), callback)
  for flag in @["-DWLR_USE_UNSTABLE", "-DXWAYLAND", "-I" & root] &
      staticExec("pkg-config --cflags wlroots-0.20 wayland-server xkbcommon libinput xcb xcb-icccm").splitWhitespace:
    body.add newCall(ident("compilerarg"), newLit(flag))
  body.add newLit(root / "nimzo_ffi.h")
  result = newCall(bindSym"importc", body)

generate()

# Futhark writes the declarations before this block runs.
static:
  const header = "# Generated C ABI bindings for wlroots, Wayland, and supporting system\n" &
    "# libraries. Regenerate with tools/generate_bindings.nim; do not edit by hand.\n"
  let path = root / "bindings.nim"
  # Futhark embeds absolute import paths in its source-location comments.
  # Keep the locations, but not the checkout-specific directory.
  let original = readFile(path)
  var declarations = original.replace("## Generated based on " & root & "/",
    "## Generated based on ")
  if not declarations.startsWith(header):
    declarations = header & declarations
  if declarations != original:
    writeFile(path, declarations)
