# Define compositor constants and helpers for tag masks, Wayland lists and
# listeners, and C declarations not provided by the generated bindings.

const
  CurNormal* = 0
  CurPressed* = 1
  CurMove* = 2
  CurResize* = 3
  XDGShell* = 0
  LayerShell* = 1
  X11* = 2
  LyrBg* = 0
  LyrBottom* = 1
  LyrTile* = 2
  LyrFloat* = 3
  LyrAbove = 4
  LyrTop* = 5
  LyrFS* = 6
  LyrUnmanaged* = 7
  LyrOverlay* = 8
  LyrIMPopup* = 9
  LyrBlock* = 10
  NUM_LAYERS* = 11
  AxisUp* = 0
  AxisRight* = 1
  AxisDown* = 2
  AxisLeft* = 3

template CLEANMASK*(mask: untyped): untyped =
  (uint32(mask) and not (uint32(WLR_MODIFIER_CAPS) or uint32(WLR_MODIFIER_MOD2)))
template onSelectedTags(c, m: untyped): untyped =
  ((m) != nil and (c).mon == (m) and ((c).tags and (m).tagset[(m).seltags]) != 0)
template VISIBLEON*(c, m: untyped): untyped =
  (onSelectedTags(c, m) and not (c).isminimized)
template TAGMASK*: uint32 = ((1'u32 shl TAGCOUNT) - 1'u32)
template END*[N: static[int], T](a: array[N, T]): ptr T = cast[ptr T](cast[uint](unsafeAddr a[0]) + uint(sizeof(a)))

template wl_container_of*[T](p: pointer; sample: ptr T; member: untyped): ptr T =
  cast[ptr T](cast[uint](p) - uint(offsetOf(T, member)))
template wl_container_of*[T](p: ptr wl_listener; sample: ptr T; member: untyped): ptr T =
  cast[ptr T](cast[uint](p) - uint(offsetOf(T, member)))

template wl_list_first_link*[T](head: ptr wl_list; sample: ptr T): ptr T = wl_container_of(cast[pointer](head.next), sample, link)
template wl_list_last_link*[T](head: ptr wl_list; sample: ptr T): ptr T = wl_container_of(cast[pointer](head.prev), sample, link)
template wl_list_more_link*[T](pos: ptr T; head: ptr wl_list): bool = addr(pos.link) != head
template wl_list_next_link*[T](pos: ptr T): ptr T = wl_container_of(cast[pointer](pos.link.next), pos, link)
template wl_list_prev_link*[T](pos: ptr T): ptr T = wl_container_of(cast[pointer](pos.link.prev), pos, link)
template wl_list_first_flink*[T](head: ptr wl_list; sample: ptr T): ptr T = wl_container_of(cast[pointer](head.next), sample, flink)
template wl_list_last_flink*[T](head: ptr wl_list; sample: ptr T): ptr T = wl_container_of(cast[pointer](head.prev), sample, flink)
template wl_list_more_flink*[T](pos: ptr T; head: ptr wl_list): bool = addr(pos.flink) != head
template wl_list_next_flink*[T](pos: ptr T): ptr T = wl_container_of(cast[pointer](pos.flink.next), pos, flink)
template wl_list_prev_flink*[T](pos: ptr T): ptr T = wl_container_of(cast[pointer](pos.flink.prev), pos, flink)

template wl_array_first*[T](a: ptr wl_array; sample: ptr T): ptr T = cast[ptr T](a.data)
template wl_array_more*[T](p: ptr T; a: ptr wl_array): bool =
  cast[uint](p) < cast[uint](a.data) + cast[uint](a.size)
template wl_array_next*[T](p: ptr T): ptr T = cast[ptr T](cast[uint](p) + uint(sizeof(T)))
template wl_array_next*[T](p: ptr UncheckedArray[T]): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](cast[uint](p) + uint(sizeof(T)))

template LISTEN*(event, listener, handler: untyped): untyped =
  block:
    (listener).notify = handler
    wl_signal_add(event, listener)

# C flag enums use bitwise combinations that are not individual enumerators.
proc `or`[E: enum](a, b: E): E {.inline.} = cast[E](uint32(a) or uint32(b))
proc `and`[E: enum](a, b: E): E {.inline.} = cast[E](uint32(a) and uint32(b))

# wlroots exposes these fields through an anonymous C union.
template toplevel(s: ptr wlr_xdg_surface): untyped = s.anon0.toplevel
template popup(s: ptr wlr_xdg_surface): untyped = s.anon0.popup

# Nim's standard streams use the same libc FILE pointers.
proc fprintf(stream: File; format: cstring): cint {.cdecl, varargs, importc: "fprintf", header: "<stdio.h>".}
proc fflush(stream: File): cint {.cdecl, importc: "fflush", header: "<stdio.h>".}
proc fputc(c: cint; stream: File): cint {.cdecl, importc: "fputc", header: "<stdio.h>".}
proc wl_signal_add(signal: ptr wl_signal; listener: ptr wl_listener) {.inline.} =
  wl_list_insert(signal.listener_list.prev, addr listener.link)
const INT_MAX = high(cint)
proc close(fd: cint): cint {.cdecl, importc: "close", header: "<unistd.h>".}
proc c_getenv(name: cstring): cstring {.cdecl, importc: "getenv", header: "<stdlib.h>".}
