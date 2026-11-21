# Set up a private headless compositor environment for tests and find
# test windows by application ID.

import std/tempfiles

proc headlessRuntime(prefix: string; outputs: int): string =
  result = createTempDir(prefix, "")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("XDG_RUNTIME_DIR", result)
  putEnv("WLR_BACKENDS", "headless")
  putEnv("WLR_RENDERER", "pixman")
  putEnv("WLR_HEADLESS_OUTPUTS", $outputs)

proc app(name: string): ptr Client =
  var c: ptr Client
  c = wl_list_first_link(addr clients, c)
  while wl_list_more_link(c, addr clients):
    if $client_get_appid(c) == name: return c
    c = wl_list_next_link(c)
  return nil
