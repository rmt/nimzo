# Apply runtime output rules through wlroots. Select modes, test and commit
# output state, and resolve absolute and relative output positions.

# The generated bindings do not currently expose this small wlroots helper.
proc wlr_output_state_set_custom_mode_runtime(state: ptr wlr_output_state;
    width, height, refresh: int32) {.cdecl, importc: "wlr_output_state_set_custom_mode".}

# The generated bindings expose commit_state but not its public test sibling.
proc wlr_output_test_state_runtime(output: ptr wlr_output;
    state: ptr wlr_output_state): bool {.cdecl, importc: "wlr_output_test_state".}

proc outputRuleApplies(rule: OutputRule; output: ptr wlr_output; wildcard: bool): bool {.inline.} =
  if output == nil or output.name == nil:
    return false
  if wildcard:
    return rule.name == "*"
  return rule.name != "*" and strcmp(output.name, cstring(rule.name)) == 0

proc applyOutputRule(rule: OutputRule; output: ptr wlr_output;
    state: ptr wlr_output_state) =
  if rule.hasEnabled:
    wlr_output_state_set_enabled(state, rule.enabled)
  if rule.hasScale:
    wlr_output_state_set_scale(state, cfloat(rule.scale))
  if rule.hasTransform:
    wlr_output_state_set_transform(state,
        cast[wl_output_transform](rule.transform))

  if not rule.hasMode:
    return

  var mode: ptr wlr_output_mode = nil
  var preferred: ptr wlr_output_mode = nil
  var current: ptr wlr_output_mode = nil
  var best: ptr wlr_output_mode = nil
  var modes = addr(output.modes)
  if wl_list_empty(modes) != 0:
    # Headless and other mode-less backends accept a custom mode. A backend
    # advertising modes must never be given an unadvertised custom mode.
    wlr_output_state_set_custom_mode_runtime(state, int32(rule.width),
        int32(rule.height), int32(rule.refresh))
    return

  mode = wl_list_first_link(modes, mode)
  while wl_list_more_link(mode, modes):
    if mode.width == int32(rule.width) and mode.height == int32(rule.height):
      if output.current_mode == mode:
        current = mode
      if mode.preferred:
        preferred = mode
      if rule.refresh == 0:
        if best == nil or mode.refresh > best.refresh:
          best = mode
      elif mode.refresh == int32(rule.refresh):
        best = mode
        break
    mode = wl_list_next_link(mode)

  if rule.refresh == 0:
    if preferred != nil:
      best = preferred
    elif current != nil:
      best = current
  if best == nil:
    discard fprintf(stderr,
        "runtime output %s: unsupported advertised mode %dx%d@%d\n",
        output.name, cint(rule.width), cint(rule.height), cint(rule.refresh))
    return
  wlr_output_state_set_mode(state, best)

proc configureOutput*(output: ptr wlr_output; state: ptr wlr_output_state;
    config: RuntimeConfig) =
  if output == nil or state == nil or output.name == nil:
    return
  # Resolve in two passes so wildcard properties are always below the exact
  # output rule, independent of the order in the parsed file.
  for rule in config.outputs:
    if outputRuleApplies(rule, output, true):
      applyOutputRule(rule, output, state)
  for rule in config.outputs:
    if outputRuleApplies(rule, output, false):
      applyOutputRule(rule, output, state)

proc configuredPosition(output: ptr wlr_output; config: RuntimeConfig;
    x, y: ptr cint; depth = 0): bool =
  if output == nil or output.name == nil or depth > config.outputs.len:
    return false
  var selected = -1
  for i, rule in config.outputs:
    if rule.name == "*" and rule.hasPosition:
      selected = i
  for i, rule in config.outputs:
    if rule.name != "*" and strcmp(output.name, cstring(rule.name)) == 0 and rule.hasPosition:
      selected = i
  if selected < 0:
    return false
  let rule = config.outputs[selected]
  if rule.relativeTo.len == 0:
    x[] = cint(rule.x)
    y[] = cint(rule.y)
    return true
  var reference: ptr Monitor
  reference = wl_list_first_link(addr mons, reference)
  while wl_list_more_link(reference, addr mons):
    if reference.wlr_output.enabled and
        strcmp(reference.wlr_output.name, rule.relativeTo.cstring) == 0:
      if wlr_output_layout_get(output_layout, reference.wlr_output) == nil:
        return false
      var box: wlr_box
      wlr_output_layout_get_box(output_layout, reference.wlr_output, addr box)
      var referenceX = box.x
      var referenceY = box.y
      # Resolve the configured anchor first, independent of connector order.
      discard configuredPosition(reference.wlr_output, config,
        addr referenceX, addr referenceY, depth + 1)
      let belowY = int64(referenceY) + int64(box.height) + int64(rule.gap)
      if belowY > int64(high(cint)):
        discard fprintf(stderr, "nimzo: output %s: relative position is out of range\n", output.name)
        return false
      x[] = referenceX
      y[] = cint(belowY)
      return true
    reference = wl_list_next_link(reference)
  # Keep automatic/current placement while the anchor is disconnected.
  return false

proc defaultConfiguredMonitor(config: RuntimeConfig): ptr Monitor =
  for rule in config.outputs:
    if not rule.isDefault: continue
    var m: ptr Monitor
    m = wl_list_first_link(addr mons, m)
    while wl_list_more_link(m, addr mons):
      if m.wlr_output.enabled and strcmp(m.wlr_output.name, rule.name.cstring) == 0:
        return m
      m = wl_list_next_link(m)
  return nil

proc positionConfiguredOutputs*(config: RuntimeConfig) =
  if output_layout == nil:
    return
  var m: ptr Monitor
  m = wl_list_first_link(addr(mons), m)
  while wl_list_more_link(m, addr(mons)):
    if m.wlr_output != nil and m.wlr_output.enabled:
      var x, y: cint
      if configuredPosition(m.wlr_output, config, addr(x), addr(y)):
        discard wlr_output_layout_add(output_layout, m.wlr_output, x, y)
    m = wl_list_next_link(m)

proc applyConfiguredOutputs*(config: RuntimeConfig) =
  inc outputLayoutUpdates
  var m: ptr Monitor
  m = wl_list_first_link(addr(mons), m)
  while wl_list_more_link(m, addr(mons)):
    let output = m.wlr_output
    if output != nil:
      var state: wlr_output_state
      wlr_output_state_init(addr(state))
      # Keep all properties not mentioned by the runtime config at their
      # current values. In particular this preserves a backend's mode choice
      # while allowing a later reload to re-enable a previously disabled head.
      wlr_output_state_set_enabled(addr(state), output.enabled)
      if output.current_mode != nil:
        wlr_output_state_set_mode(addr(state), output.current_mode)
      if output.scale > 0:
        wlr_output_state_set_scale(addr(state), output.scale)
      wlr_output_state_set_transform(addr(state), output.transform)
      configureOutput(output, addr(state), config)

      var ok = false
      if not wlr_output_test_state_runtime(output, addr(state)):
        discard fprintf(stderr, "runtime output %s: backend rejected state\n",
            output.name)
      elif not wlr_output_commit_state(output, addr(state)):
        discard fprintf(stderr, "runtime output %s: failed to commit state\n",
            output.name)
      else:
        ok = true
      wlr_output_state_finish(addr(state))
      if ok:
        # offmons is the compositor's persistent record for a disabled output;
        # retain it across a hotplug/reload cycle and remove it on re-enable.
        setOutputDisabledRecord(output, cint(not output.enabled))
    m = wl_list_next_link(m)

  positionConfiguredOutputs(config)
  dec outputLayoutUpdates
  updatemons(nil, nil)
