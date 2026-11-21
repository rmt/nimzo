# Attach a test keyboard to the compositor and send key events through
# the wlroots input path.

proc testKeyboardInit(keyboard: ptr wlr_keyboard; impl: ptr wlr_keyboard_impl;
  name: cstring) {.cdecl, importc: "wlr_keyboard_init".}
proc testKeyboardNotify(keyboard: ptr wlr_keyboard;
  event: ptr wlr_keyboard_key_event) {.cdecl, importc: "wlr_keyboard_notify_key".}
proc testKeyboardFinish(keyboard: ptr wlr_keyboard) {.cdecl, importc: "wlr_keyboard_finish".}

# The generated impl type is opaque. Match wlr/interfaces/wlr_keyboard.h.
# wlroots retains the implementation address while the keyboard is active.
type TestKeyboardImpl = object
  name: cstring
  ledUpdate: proc(keyboard: ptr wlr_keyboard; leds: uint32) {.cdecl.}

var
  testKeyboard: wlr_keyboard
  testKeyboardImpl: TestKeyboardImpl

proc startTestKeyboard(name: cstring) =
  testKeyboardImpl.name = name
  testKeyboardInit(addr testKeyboard, cast[ptr wlr_keyboard_impl](addr testKeyboardImpl), name)
  createkeyboard(addr testKeyboard)

proc finishTestKeyboard() =
  testKeyboardFinish(addr testKeyboard)

proc key(code: uint32; pressed: bool) =
  var event = wlr_keyboard_key_event(time_msec: 10, keycode: code,
    update_state: true, state: if pressed: WL_KEYBOARD_KEY_STATE_PRESSED else: WL_KEYBOARD_KEY_STATE_RELEASED)
  testKeyboardNotify(addr testKeyboard, addr event)
