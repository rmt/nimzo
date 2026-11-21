# See LICENSE.dwm for copyright and license details.

# Provide shared helpers for fatal errors, allocation, nonblocking file
# descriptors, and keyboard symbol lookup.

template MAX(a, b: untyped): untyped = max(a, b)
template MIN(a, b: untyped): untyped = min(a, b)
template LENGTH(a: untyped): untyped = a.len

import std/macros

macro die(fmt: typed; args: varargs[untyped]): untyped =
  let call = newCall(bindSym"fprintf", bindSym"stderr", fmt)
  for arg in args: call.add arg
  result = quote do:
    block:
      discard `call`
      let length = strlen(`fmt`)
      if length > 0 and `fmt`[length - 1] == ':':
        discard fputc(cint(' '), stderr)
        perror(nil)
      else:
        discard fputc(cint('\n'), stderr)
      exit(1)
proc ecalloc(nmemb, size: csize_t): pointer =
  result = calloc(nmemb, size)
  if result == nil: die("calloc:")

proc fd_set_nonblock(fd: cint): cint =
  let flags = fcntl(fd, F_GETFL)
  if flags < 0:
    perror("fcntl(F_GETFL):")
    return -1
  if fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    perror("fcntl(F_SETFL):")
    return -1
  0

proc keymap_get_one_sym_by_level(keymap: ptr xkb_keymap; key: xkb_keycode_t;
    layout: xkb_layout_index_t; level: xkb_level_index_t): xkb_keysym_t =
  var syms: ptr xkb_keysym_t
  let count = xkb_keymap_key_get_syms_by_level(keymap, key, layout, level, addr syms)
  if count > 0: syms[] else: xkb_keysym_t(XKB_KEY_NoSymbol)
