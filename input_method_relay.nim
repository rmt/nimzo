# See LICENSE for copyright and license details.

# Connect Wayland text input clients to the input method. Track text focus,
# forward keyboard grabs, and position input method popups.

type
  InputMethodRelay = object
    text_inputs: wl_list
    input_method: ptr wlr_input_method_v2
    focused_surface: ptr wlr_surface
    active_text_input: ptr TextInput
    popups: wl_list
    popup_tree: ptr wlr_scene_tree
    new_text_input, new_input_method: wl_listener
    input_method_commit, input_method_grab_keyboard: wl_listener
    input_method_destroy, input_method_new_popup_surface: wl_listener
    keyboard_grab_destroy, focused_surface_destroy: wl_listener
  InputMethodPopup = object
    popup_surface: ptr wlr_input_popup_surface_v2
    tree, scene_surface: ptr wlr_scene_tree
    relay: ptr InputMethodRelay
    link: wl_list
    destroy, commit: wl_listener
  TextInput = object
    relay: ptr InputMethodRelay
    input: ptr wlr_text_input_v3
    link: wl_list
    enable, commit, disable, destroy: wl_listener
var
  input_method_manager: ptr wlr_input_method_manager_v2
  text_input_manager: ptr wlr_text_input_manager_v3
  input_method_relay: ptr InputMethodRelay

template owner(p, T, member: untyped): untyped =
  cast[ptr T](cast[uint](p) - uint(offsetOf(T, member)))

iterator relayItems[T](head: ptr wl_list; _: typedesc[T]): ptr T =
  var node = head.next
  while node != head:
    let item = owner(node, T, link)
    node = node.next
    yield item

proc input_method_relay_set_focus(relay: ptr InputMethodRelay; surface: ptr wlr_surface)
proc update_popup_position(popup: ptr InputMethodPopup)
proc handle_keyboard_grab_destroy(listener: ptr wl_listener; data: pointer) {.cdecl.}

proc output_from_wlr_output(output: ptr wlr_output): ptr Monitor =
  for m in relayItems(addr mons, Monitor):
    if m.wlr_output == output: return m

proc output_nearest_to(lx, ly: cint): ptr Monitor =
  var x, y: cdouble
  wlr_output_layout_closest_point(output_layout, nil, cdouble(lx), cdouble(ly), addr x, addr y)
  output_from_wlr_output(wlr_output_layout_output_at(output_layout, x, y))

proc keyboard_is_emulated_by_input_method(keyboard: ptr wlr_keyboard;
    inputMethod: ptr wlr_input_method_v2): cint =
  if keyboard == nil or inputMethod == nil: return 0
  let virtualKeyboard = wlr_input_device_get_virtual_keyboard(addr keyboard.base)
  cint(virtualKeyboard != nil and wl_resource_get_client(virtualKeyboard.resource) ==
    wl_resource_get_client(inputMethod.resource))

proc get_keyboard_grab(keyboard: ptr KeyboardGroup): ptr wlr_input_method_keyboard_grab_v2 =
  if locked != 0: return nil
  let im = input_method_relay.input_method
  if im == nil or im.keyboard_grab == nil or keyboard != kb_group or
      keyboard_is_emulated_by_input_method(keyboard.virtual_keyboard, im) != 0: return nil
  im.keyboard_grab

proc input_method_keyboard_grab_forward_modifiers(keyboard: ptr KeyboardGroup): cint =
  let grab = get_keyboard_grab(keyboard)
  if grab == nil: return 0
  wlr_input_method_keyboard_grab_v2_set_keyboard(grab, addr keyboard.wlr_group.keyboard)
  wlr_input_method_keyboard_grab_v2_send_modifiers(grab, addr keyboard.wlr_group.keyboard.modifiers)
  1

proc input_method_keyboard_grab_forward_key(keyboard: ptr KeyboardGroup;
    event: ptr wlr_keyboard_key_event): cint =
  let grab = get_keyboard_grab(keyboard)
  if grab == nil: return 0
  wlr_input_method_keyboard_grab_v2_set_keyboard(grab, addr keyboard.wlr_group.keyboard)
  wlr_input_method_keyboard_grab_v2_send_key(grab, event.time_msec, event.keycode, uint32(event.state))
  1

proc detachInputMethodKeyboard() =
  let im = input_method_relay.input_method
  if im != nil and im.keyboard_grab != nil:
    wlr_input_method_keyboard_grab_v2_set_keyboard(im.keyboard_grab, nil)

proc get_active_text_input(relay: ptr InputMethodRelay): ptr TextInput =
  if relay.input_method == nil: return nil
  for item in relayItems(addr relay.text_inputs, TextInput):
    if item.input.focused_surface != nil and item.input.current_enabled: return item

proc update_active_text_input(relay: ptr InputMethodRelay) =
  let active = get_active_text_input(relay)
  if relay.input_method != nil and relay.active_text_input != active:
    if active != nil: wlr_input_method_v2_send_activate(relay.input_method)
    else: wlr_input_method_v2_send_deactivate(relay.input_method)
    wlr_input_method_v2_send_done(relay.input_method)
  relay.active_text_input = active

proc update_text_inputs_focused_surface(relay: ptr InputMethodRelay) =
  for item in relayItems(addr relay.text_inputs, TextInput):
    let input = item.input
    var surface: ptr wlr_surface
    if relay.input_method != nil and relay.focused_surface != nil and
        wl_resource_get_client(input.resource) == wl_resource_get_client(relay.focused_surface.resource):
      surface = relay.focused_surface
    if input.focused_surface == surface: continue
    if input.focused_surface != nil: wlr_text_input_v3_send_leave(input)
    if surface != nil: wlr_text_input_v3_send_enter(input, surface)

proc update_popup_position(popup: ptr InputMethodPopup) =
  let relay = popup.relay
  let text = relay.active_text_input
  if text == nil or relay.focused_surface == nil or not popup.popup_surface.surface.mapped: return
  let xdg = wlr_xdg_surface_try_from_wlr_surface(relay.focused_surface)
  let layer = wlr_layer_surface_v1_try_from_wlr_surface(relay.focused_surface)
  var cursorRect: wlr_box
  if (uint32(text.input.current.features) and uint32(WLR_TEXT_INPUT_V3_FEATURE_CURSOR_RECTANGLE)) != 0 and
      (xdg != nil or layer != nil):
    cursorRect = text.input.current.cursor_rectangle
    let tree = cast[ptr wlr_scene_tree](relay.focused_surface.data)
    var lx, ly: cint
    discard wlr_scene_node_coords(addr tree.node, addr lx, addr ly)
    cursorRect.x += lx
    cursorRect.y += ly
    if xdg != nil:
      cursorRect.x -= xdg.geometry.x
      cursorRect.y -= xdg.geometry.y
  let output = output_nearest_to(cursorRect.x, cursorRect.y)
  if output == nil or not output.wlr_output.enabled: return
  var outputBox, popupBox: wlr_box
  wlr_output_layout_get_box(output_layout, output.wlr_output, addr outputBox)
  var rules: wlr_xdg_positioner_rules
  rules.anchor_rect = cursorRect
  rules.anchor = XDG_POSITIONER_ANCHOR_BOTTOM_LEFT
  rules.gravity = XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT
  rules.size.width = popup.popup_surface.surface.current.width
  rules.size.height = popup.popup_surface.surface.current.height
  rules.constraint_adjustment = XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y or XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X
  wlr_xdg_positioner_rules_get_geometry(addr rules, addr popupBox)
  wlr_xdg_positioner_rules_unconstrain_box(addr rules, addr outputBox, addr popupBox)
  wlr_scene_node_set_position(addr popup.tree.node, popupBox.x, popupBox.y)
  wlr_scene_node_raise_to_top(addr relay.popup_tree.node)
  var relative = wlr_box(x: cursorRect.x - popupBox.x, y: cursorRect.y - popupBox.y,
    width: cursorRect.width, height: cursorRect.height)
  wlr_input_popup_surface_v2_send_text_input_rectangle(popup.popup_surface, addr relative)

proc update_popups_position(relay: ptr InputMethodRelay) =
  for popup in relayItems(addr relay.popups, InputMethodPopup): update_popup_position(popup)

proc handle_input_method_commit(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, input_method_commit)
  let im = relay.input_method
  let text = relay.active_text_input
  if text == nil: return
  if im.current.preedit.text != nil:
    wlr_text_input_v3_send_preedit_string(text.input, im.current.preedit.text,
      im.current.preedit.cursor_begin, im.current.preedit.cursor_end)
  if im.current.commit_text != nil: wlr_text_input_v3_send_commit_string(text.input, im.current.commit_text)
  if im.current.`delete`.before_length != 0 or im.current.`delete`.after_length != 0:
    wlr_text_input_v3_send_delete_surrounding_text(text.input,
      im.current.`delete`.before_length, im.current.`delete`.after_length)
  wlr_text_input_v3_send_done(text.input)

proc handle_keyboard_grab_destroy(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, keyboard_grab_destroy)
  let grab = relay.input_method.keyboard_grab
  wl_list_remove(addr relay.keyboard_grab_destroy.link)
  if grab.keyboard != nil:
    wlr_seat_keyboard_notify_modifiers(grab.input_method.seat, addr grab.keyboard.modifiers)

proc handle_input_method_grab_keyboard(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, input_method_grab_keyboard)
  let grab = cast[ptr wlr_input_method_keyboard_grab_v2](data)
  let keyboard = addr kb_group.wlr_group.keyboard
  if locked == 0 and keyboard_is_emulated_by_input_method(keyboard, relay.input_method) == 0:
    wlr_input_method_keyboard_grab_v2_set_keyboard(grab, keyboard)
  relay.keyboard_grab_destroy.notify = handle_keyboard_grab_destroy
  wl_signal_add(addr grab.events.destroy, addr relay.keyboard_grab_destroy)

proc handle_input_method_destroy(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, input_method_destroy)
  wl_list_remove(addr relay.input_method_commit.link)
  wl_list_remove(addr relay.input_method_grab_keyboard.link)
  wl_list_remove(addr relay.input_method_new_popup_surface.link)
  wl_list_remove(addr relay.input_method_destroy.link)
  relay.input_method = nil
  update_text_inputs_focused_surface(relay)
  update_active_text_input(relay)

proc handle_popup_surface_destroy(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let popup = owner(listener, InputMethodPopup, destroy)
  wlr_scene_node_destroy(addr popup.tree.node)
  wl_list_remove(addr popup.destroy.link)
  wl_list_remove(addr popup.commit.link)
  wl_list_remove(addr popup.link)
  free(popup)

proc handle_popup_surface_commit(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  update_popup_position(owner(listener, InputMethodPopup, commit))

proc handle_input_method_new_popup_surface(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, input_method_new_popup_surface)
  let popup = cast[ptr InputMethodPopup](ecalloc(1, csize_t(sizeof(InputMethodPopup))))
  popup.popup_surface = cast[ptr wlr_input_popup_surface_v2](data)
  popup.relay = relay
  popup.destroy.notify = handle_popup_surface_destroy
  wl_signal_add(addr popup.popup_surface.events.destroy, addr popup.destroy)
  popup.commit.notify = handle_popup_surface_commit
  wl_signal_add(addr popup.popup_surface.surface.events.commit, addr popup.commit)
  popup.tree = wlr_scene_tree_create(layers[LyrIMPopup])
  popup.scene_surface = wlr_scene_subsurface_tree_create(popup.tree, popup.popup_surface.surface)
  popup.scene_surface.node.data = popup
  wl_list_insert(addr relay.popups, addr popup.link)
  update_popup_position(popup)

proc handle_new_input_method(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, new_input_method)
  let im = cast[ptr wlr_input_method_v2](data)
  if seat != im.seat: return
  if relay.input_method != nil:
    wlr_input_method_v2_send_unavailable(im)
    return
  relay.input_method = im
  relay.input_method_commit.notify = handle_input_method_commit
  wl_signal_add(addr im.events.commit, addr relay.input_method_commit)
  relay.input_method_grab_keyboard.notify = handle_input_method_grab_keyboard
  wl_signal_add(addr im.events.grab_keyboard, addr relay.input_method_grab_keyboard)
  relay.input_method_destroy.notify = handle_input_method_destroy
  wl_signal_add(addr im.events.destroy, addr relay.input_method_destroy)
  relay.input_method_new_popup_surface.notify = handle_input_method_new_popup_surface
  wl_signal_add(addr im.events.new_popup_surface, addr relay.input_method_new_popup_surface)
  update_text_inputs_focused_surface(relay)
  update_active_text_input(relay)

proc send_state_to_input_method(relay: ptr InputMethodRelay) =
  let im = relay.input_method
  let input = relay.active_text_input.input
  if (uint32(input.active_features) and uint32(WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT)) != 0:
    wlr_input_method_v2_send_surrounding_text(im, input.current.surrounding.text,
      input.current.surrounding.cursor, input.current.surrounding.anchor)
  wlr_input_method_v2_send_text_change_cause(im, input.current.text_change_cause)
  if (uint32(input.active_features) and uint32(WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE)) != 0:
    wlr_input_method_v2_send_content_type(im, input.current.content_type.hint, input.current.content_type.purpose)
  wlr_input_method_v2_send_done(im)

proc handle_text_input_enable(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let text = owner(listener, TextInput, enable)
  let relay = text.relay
  update_active_text_input(relay)
  if relay.active_text_input == text:
    update_popups_position(relay)
    send_state_to_input_method(relay)
  wlr_text_input_v3_send_done(text.input)

proc handle_text_input_disable(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  update_active_text_input(owner(listener, TextInput, disable).relay)

proc handle_text_input_commit(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let text = owner(listener, TextInput, commit)
  if text.relay.active_text_input == text:
    update_popups_position(text.relay)
    send_state_to_input_method(text.relay)

proc handle_text_input_destroy(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let text = owner(listener, TextInput, destroy)
  wl_list_remove(addr text.enable.link)
  wl_list_remove(addr text.disable.link)
  wl_list_remove(addr text.commit.link)
  wl_list_remove(addr text.destroy.link)
  wl_list_remove(addr text.link)
  update_active_text_input(text.relay)
  free(text)

proc handle_new_text_input(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  let relay = owner(listener, InputMethodRelay, new_text_input)
  let input = cast[ptr wlr_text_input_v3](data)
  if seat != input.seat: return
  let text = cast[ptr TextInput](ecalloc(1, csize_t(sizeof(TextInput))))
  text.input = input
  text.relay = relay
  wl_list_insert(addr relay.text_inputs, addr text.link)
  text.enable.notify = handle_text_input_enable
  wl_signal_add(addr input.events.enable, addr text.enable)
  text.disable.notify = handle_text_input_disable
  wl_signal_add(addr input.events.disable, addr text.disable)
  text.commit.notify = handle_text_input_commit
  wl_signal_add(addr input.events.commit, addr text.commit)
  text.destroy.notify = handle_text_input_destroy
  wl_signal_add(addr input.events.destroy, addr text.destroy)
  update_text_inputs_focused_surface(relay)

proc handle_focused_surface_destroy(listener: ptr wl_listener; data: pointer) {.cdecl.} =
  input_method_relay_set_focus(owner(listener, InputMethodRelay, focused_surface_destroy), nil)

proc input_method_relay_create(): ptr InputMethodRelay =
  let relay = cast[ptr InputMethodRelay](ecalloc(1, csize_t(sizeof(InputMethodRelay))))
  wl_list_init(addr relay.text_inputs)
  wl_list_init(addr relay.popups)
  relay.popup_tree = wlr_scene_tree_create(addr scene.tree)
  relay.new_text_input.notify = handle_new_text_input
  wl_signal_add(addr text_input_manager.events.new_text_input, addr relay.new_text_input)
  relay.new_input_method.notify = handle_new_input_method
  wl_signal_add(addr input_method_manager.events.new_input_method, addr relay.new_input_method)
  relay.focused_surface_destroy.notify = handle_focused_surface_destroy
  relay

proc input_method_relay_finish(relay: ptr InputMethodRelay) =
  wl_list_remove(addr relay.new_text_input.link)
  wl_list_remove(addr relay.new_input_method.link)
  free(relay)

proc input_method_relay_set_focus(relay: ptr InputMethodRelay; surface: ptr wlr_surface) =
  if relay == nil or relay.focused_surface == surface: return
  if relay.focused_surface != nil: wl_list_remove(addr relay.focused_surface_destroy.link)
  relay.focused_surface = surface
  if surface != nil: wl_signal_add(addr surface.events.destroy, addr relay.focused_surface_destroy)
  update_text_inputs_focused_surface(relay)
  update_active_text_input(relay)
