# Define built-in input settings, colors, layouts, rules, and shortcuts.
# The runtime configuration parser is in runtime_config.nim.

const
  TAGCOUNT = 9
  sloppyfocus = 1
  bypass_surface_visibility = 0
  borderpx = 1'u32
  layoutMonocleIndex = 0
  layoutZonesIndex = 1
var
  rootcolor = [0x22.cfloat / 255, 0x22.cfloat / 255, 0x22.cfloat / 255, 1.cfloat]
  bordercolor = [0x44.cfloat / 255, 0x44.cfloat / 255, 0x44.cfloat / 255, 1.cfloat]
  focuscolor = [0.cfloat, 0x55.cfloat / 255, 0x77.cfloat / 255, 1.cfloat]
  urgentcolor = [1.cfloat, 0.cfloat, 0.cfloat, 1.cfloat]
  fullscreen_bg = [0.cfloat, 0.cfloat, 0.cfloat, 1.cfloat]
const
  repeat_rate = 25
  repeat_delay = 600
  tap_to_click = 1
  tap_and_drag = 1
  drag_lock = 1
  natural_scrolling = 0
  disable_while_typing = 1
  left_handed = 0
  middle_button_emulation = 0
  scroll_method = LIBINPUT_CONFIG_SCROLL_2FG
  click_method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS
  send_events_mode = uint32(LIBINPUT_CONFIG_SEND_EVENTS_ENABLED)
  accel_profile = LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE
  accel_speed = 0.0
  button_map = LIBINPUT_CONFIG_TAP_MAP_LRM
  MODKEY = WLR_MODIFIER_LOGO
var
  log_level = WLR_ERROR
  rules = [
    Rule(id: "Gimp_EXAMPLE", title: nil, tags: 0, isfloating: 1, monitor: -1),
    Rule(id: "firefox_EXAMPLE", title: nil, tags: 1'u32 shl 8, isfloating: 0, monitor: -1)]
  layouts = [Layout(symbol: "[M]", arrange: monocle),
    Layout(symbol: "[Z]", arrange: zonelayout)]
  monrules = [MonitorRule(name: nil, scale: 1,
    lt: addr layouts[layoutZonesIndex], rr: WL_OUTPUT_TRANSFORM_NORMAL, x: -1, y: -1)]
  xkb_rules = xkb_rule_names(options: nil)
  termcmd = [cstring"foot", nil]
  menucmd = [cstring"bemenu-run", nil]

template binding(mods, sym, action, argument: untyped): Key =
  Key(`mod`: uint32(mods), keysym: sym, `func`: action, arg: argument)

# Fixed-size storage keeps configuration pointers stable for the session.
var keys = block:
  let base = [
    binding(MODKEY, XKB_KEY_p, spawn, Arg(v: addr menucmd[0])),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_Return, spawn, Arg(v: addr termcmd[0])),
    binding(MODKEY, XKB_KEY_j, focusstack, Arg(i: 1)),
    binding(MODKEY, XKB_KEY_k, focusstack, Arg(i: -1)),
    binding(MODKEY, XKB_KEY_Tab, view, Arg()),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_c, requestCloseFocusedWindow, Arg()),
    binding(MODKEY, XKB_KEY_w, requestCloseFocusedWindow, Arg()),
    binding(MODKEY, XKB_KEY_b, setBorderWindow, Arg(i: -1)),
    binding(MODKEY, XKB_KEY_t, setTitlebarWindow, Arg(i: -1)),
    binding(MODKEY or WLR_MODIFIER_CTRL or WLR_MODIFIER_ALT, XKB_KEY_space, setlayout, Arg()),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_space, togglefloating, Arg()),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_a, setAlwaysOnTopWindow, Arg(i: -1)),
    binding(MODKEY, XKB_KEY_e, togglefullscreen, Arg()),
    binding(MODKEY, XKB_KEY_0, view, Arg(ui: high(uint32))),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_0, tag, Arg(ui: high(uint32))),
    binding(MODKEY, XKB_KEY_comma, focusmon, Arg(i: cint(WLR_DIRECTION_LEFT))),
    binding(MODKEY, XKB_KEY_period, focusmon, Arg(i: cint(WLR_DIRECTION_RIGHT))),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_comma, tagmon, Arg(i: cint(WLR_DIRECTION_LEFT))),
    binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_period, tagmon, Arg(i: cint(WLR_DIRECTION_RIGHT)))]
  var result: array[base.len + TAGCOUNT * 4 + 2 + 12, Key]
  for i, key in base: result[i] = key
  var index = base.len
  for tagIndex in 0 ..< TAGCOUNT:
    let mask = 1'u32 shl tagIndex
    let sym = uint32(XKB_KEY_1) + uint32(tagIndex)
    result[index] = binding(MODKEY, sym, view, Arg(ui: mask))
    result[index + 1] = binding(MODKEY or WLR_MODIFIER_CTRL, sym, toggleview, Arg(ui: mask))
    result[index + 2] = binding(MODKEY or WLR_MODIFIER_SHIFT, sym, tag, Arg(ui: mask))
    result[index + 3] = binding(MODKEY or WLR_MODIFIER_CTRL or WLR_MODIFIER_SHIFT, sym, toggletag, Arg(ui: mask))
    index += 4
  result[index] = binding(MODKEY or WLR_MODIFIER_SHIFT, XKB_KEY_q, quit, Arg())
  inc index
  result[index] = binding(WLR_MODIFIER_CTRL or WLR_MODIFIER_ALT, XKB_KEY_BackSpace, quit, Arg())
  inc index
  for vt in 1 .. 12:
    result[index] = binding(WLR_MODIFIER_CTRL or WLR_MODIFIER_ALT,
      uint32(XKB_KEY_F1) + uint32(vt - 1), chvt, Arg(ui: uint32(vt)))
    inc index
  result

var
  buttons = [
    Button(`mod`: uint32(MODKEY), button: BTN_LEFT, `func`: moveresize, arg: Arg(ui: CurMove)),
    Button(`mod`: uint32(MODKEY), button: BTN_MIDDLE, `func`: togglefloating, arg: Arg()),
    Button(`mod`: uint32(MODKEY), button: BTN_RIGHT, `func`: moveresize, arg: Arg(ui: CurResize))]
  axes = [Axis(`mod`: 0, dir: 0, `func`: nil, arg: Arg())]
