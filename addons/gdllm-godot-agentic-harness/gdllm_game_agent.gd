@tool
extends Node
## The in-game half of the game-driving tools: a project autoload (registered by the plugin, removable via the Register Game Input Agent setting) that does nothing at all unless the run has a debugger attached — a normal exported game leaves it inert. Under the editor's debugger it answers the "gdllm" message prefix from GDLLMDebuggerBridge: UI snapshots, method calls on live nodes, and input sequences played through the REAL input pipeline — Input.parse_input_event with events synthesized from the game's own InputMap — so polling code (Input.is_action_pressed) and callback code (_input, _gui_input) both see exactly what a player's hardware would produce. No class_name: the script IS the autoload singleton, and a matching global class name would shadow it.

## The shared pure halves; preloaded by path so the game process needs no global class cache.
const Protocol := preload("res://addons/gdllm-godot-agentic-harness/gdllm_game_protocol.gd")

## The input sequence in flight: {"id", "steps", "entries", "next", "started_ms", "executed", "notes"}; empty when idle. One at a time — overlapping sequences would interleave their events into nonsense.
var _sequence: Dictionary = {}
## Per-step click routing resolved at each click step's "point" op, keyed by step index: {"mode": "input"/"viewport", "pos", "viewport"}.
var _click_routes: Dictionary = {}
## The fake cursor drawn while pointer input plays (see _show_pointer): the user's REAL mouse cursor is never moved or warped — the overlay shows in-game where the synthetic pointer sits instead.
var _pointer_layer: CanvasLayer = null
var _pointer: Node2D = null
## Frames of the GAME that have actually been processed, which is what suspend_game's stepping is counted against. No engine counter can serve: scene suspension stops _process while the main loop, the renderer and SceneTree.get_frame() all keep running at full speed (probe-measured), so only a counter incremented from _process itself freezes when the game does.
var _frames: int = 0


## The overlay cursor's drawing: a small white arrow with a black outline, legible on any background. A Node2D on a high CanvasLayer, so it can never intercept GUI input or appear in UI snapshots (the layer carries the gdllm_ignore meta the snapshot walker skips).
class PointerOverlay extends Node2D:
	func _draw() -> void:
		var arrow := PackedVector2Array([Vector2.ZERO, Vector2(0, 16), Vector2(4.5, 12.5), Vector2(8, 19), Vector2(10.5, 17.5), Vector2(7, 11), Vector2(12, 11)])
		draw_colored_polygon(arrow, Color.WHITE)
		var outline := arrow.duplicate()
		outline.append(Vector2.ZERO)
		draw_polyline(outline, Color.BLACK, 1.5)


func _ready() -> void:
	if not EngineDebugger.is_active():
		set_process(false)
		return
	# Keep driving while the game is paused — pause menus are exactly what UI testing needs to reach.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	EngineDebugger.register_message_capture("gdllm", _on_message)
	EngineDebugger.send_message("gdllm:hello", [Protocol.VERSION])


## One editor command; `message` arrives with the "gdllm:" prefix already stripped. Every command is [request_id, payload] and every reply is [request_id, result] on "gdllm:result", so the editor can match answers to questions.
func _on_message(message: String, data: Array) -> bool:
	if message != "cmd" or data.size() != 2 or not data[1] is Dictionary:
		return true
	var id := int(data[0])
	var payload: Dictionary = data[1]
	match String(payload.get("op", "")):
		"ping":
			# The frame counter rides the cheapest op there is: suspend_game confirms each stepped frame by watching it move, rather than assuming a next_frame press landed.
			_reply(id, {"ok": true, "version": Protocol.VERSION, "scene_frame": _frames})
		"ui":
			_reply(id, _ui_snapshot(payload))
		"call":
			_reply(id, _call_method(payload))
		"inspect":
			_reply(id, _inspect(payload))
		"input":
			_start_sequence(id, payload)
		_:
			_reply(id, {"ok": false, "why": "unknown op \"%s\" — the editor plugin and this game's agent may be from different plugin versions; restart the run." % String(payload.get("op", ""))})
	return true


func _reply(id: int, result: Dictionary) -> void:
	EngineDebugger.send_message("gdllm:result", [id, result])


## The "ui" op: a bounded snapshot of the live tree (Controls by default, every node with "all"), plus the scene, pause state, and keyboard focus the composer's header reports.
func _ui_snapshot(payload: Dictionary) -> Dictionary:
	var scope := String(payload.get("scope", ""))
	var root: Node = get_tree().root
	if scope != "":
		root = get_tree().root.get_node_or_null(scope)
		if root == null:
			return {"ok": false, "why": "no node exists at %s in the running game — call read_game_ui without a path to see the whole tree." % scope}
	var snapshot := Protocol.ui_snapshot(root, bool(payload.get("all", false)), String(payload.get("filter", "")))
	var scene := get_tree().current_scene
	var scene_label := "(no current scene)"
	if scene != null:
		scene_label = scene.scene_file_path if scene.scene_file_path != "" else String(scene.name)
	return {
		"ok": true,
		"rows": snapshot["rows"],
		"dropped": snapshot["dropped"],
		"others": snapshot["others"],
		"matched": snapshot["matched"],
		"searched": snapshot["searched"],
		"filter": snapshot["filter"],
		"all": bool(payload.get("all", false)),
		"scope": scope if scope != "" else "/root",
		"scene": scene_label,
		"paused": get_tree().paused,
		"focus": _focus_path(),
	}


func _focus_path() -> String:
	var focus := get_tree().root.gui_get_focus_owner()
	return String(focus.get_path()) if focus != null else ""


## The "call" op: one method call on one live node, the result sanitized to plain wire-safe data. Wrong arguments surface as engine errors in the debugger's Errors tab, which the editor-side capture relays alongside this reply.
func _call_method(payload: Dictionary) -> Dictionary:
	var path := String(payload.get("path", ""))
	var node := get_tree().root.get_node_or_null(path)
	if node == null:
		return {"ok": false, "why": "no node exists at %s in the running game — read_game_ui lists the live tree with exact paths." % path}
	var method := String(payload.get("method", ""))
	if not node.has_method(method):
		# What the node has that name AS decides the advice: only the live node can say, and only here.
		return {"ok": false, "why": Protocol.call_target_error(path, node.get_class(), method, node.has_signal(method), _has_property(node, method), node is Control)}
	var raw: Variant = node.callv(method, Array(payload.get("args", [])))
	return {"ok": true, "value": Protocol.sanitize_result(raw), "type": type_string(typeof(raw))}


## Whether the node carries a property of this name, whatever its usage flags — a near-miss check, so it looks wider than an inspection's own eligibility rules.
func _has_property(node: Node, name: String) -> bool:
	for entry: Dictionary in node.get_property_list():
		if String(entry.get("name", "")) == name:
			return true
	return false


## The "inspect" op: every readable property of one live node, values included, sanitized by the same rules a call result crosses under.
func _inspect(payload: Dictionary) -> Dictionary:
	var path := String(payload.get("path", ""))
	var node := get_tree().root.get_node_or_null(path)
	if node == null:
		return {"ok": false, "why": "no node exists at %s in the running game — read_game_ui (with \"all\": true) lists the live tree with exact paths." % path}
	return Protocol.inspect_node(node, String(payload.get("filter", "")), bool(payload.get("all", false)))


## The "input" op: adopt the sequence and fire its schedule from _process. The reply is deferred to the end of playback, so the editor's tool result describes what actually played, not what was merely requested.
func _start_sequence(id: int, payload: Dictionary) -> void:
	if not _sequence.is_empty():
		_reply(id, {"ok": false, "why": "an input sequence is already playing in the game — wait for its result before sending another."})
		return
	var normalized: Dictionary = Protocol.normalize_steps(Array(payload.get("steps", [])))
	if not bool(normalized["ok"]):
		_reply(id, {"ok": false, "why": String(normalized["why"])})
		return
	var schedule: Dictionary = Protocol.build_schedule(normalized["steps"])
	_sequence = {
		"id": id,
		"steps": normalized["steps"],
		"entries": schedule["entries"],
		"seconds": float(schedule["seconds"]),
		"next": 0,
		"started_ms": Time.get_ticks_msec(),
		"executed": 0,
		"notes": [],
	}
	_click_routes = {}
	set_process(true)


func _process(_delta: float) -> void:
	# Counted first and unconditionally: this tick IS the evidence that a frame of the game ran, which is what suspend_game's stepping confirms itself against.
	_frames += 1
	if _sequence.is_empty():
		return
	var elapsed := (Time.get_ticks_msec() - int(_sequence["started_ms"])) / 1000.0
	var entries: Array = _sequence["entries"]
	while int(_sequence["next"]) < entries.size():
		var entry: Dictionary = entries[int(_sequence["next"])]
		if float(entry["at"]) > elapsed:
			break
		var why := _fire(entry)
		if why != "":
			_finish_sequence({"ok": false, "executed": int(_sequence["executed"]), "why": why, "notes": _sequence["notes"], "focus": _focus_path()})
			return
		if String(entry["op"]) in ["release", "char"] and _last_op_of_step(entries, int(_sequence["next"])):
			_sequence["executed"] = int(entry["step"]) + 1
		_sequence["next"] = int(_sequence["next"]) + 1
	# Wait steps carry no entries, so completion is the schedule's clock running out, not the last entry firing.
	if elapsed >= float(_sequence["seconds"]):
		_sequence["executed"] = (_sequence["steps"] as Array).size()
		_finish_sequence({"ok": true, "executed": int(_sequence["executed"]), "notes": _sequence["notes"], "focus": _focus_path()})


func _last_op_of_step(entries: Array, index: int) -> bool:
	return index + 1 >= entries.size() or int((entries[index + 1] as Dictionary)["step"]) != int((entries[index] as Dictionary)["step"])


func _finish_sequence(result: Dictionary) -> void:
	var id := int(_sequence["id"])
	_sequence = {}
	_click_routes = {}
	_hide_pointer_soon()
	_reply(id, result)


## Show the fake cursor at a window position; created on first use, riding the gdllm_ignore meta so read_game_ui never lists it as a clickable target.
func _show_pointer(pos: Vector2) -> void:
	if _pointer_layer == null:
		_pointer_layer = CanvasLayer.new()
		_pointer_layer.layer = 1024
		_pointer_layer.set_meta("gdllm_ignore", true)
		add_child(_pointer_layer)
		_pointer = PointerOverlay.new()
		_pointer_layer.add_child(_pointer)
	_pointer_layer.visible = true
	_pointer.position = pos


## Keep the overlay up briefly after the sequence ends so the user can see where the last input landed, then drop it — unless another sequence started meanwhile.
func _hide_pointer_soon() -> void:
	if _pointer_layer == null:
		return
	get_tree().create_timer(0.6).timeout.connect(func() -> void:
		if _sequence.is_empty() and _pointer_layer != null:
			_pointer_layer.visible = false)


## Fire one schedule entry with real input; "" on success, else the reason the sequence must stop — a later step almost always depends on the failed one having happened.
func _fire(entry: Dictionary) -> String:
	var step: Dictionary = (_sequence["steps"] as Array)[int(entry["step"])]
	var ordinal := int(entry["step"]) + 1
	match String(step["kind"]):
		"action":
			return _fire_action(step, entry, ordinal)
		"key":
			_send_key(OS.find_keycode_from_string(String(step["key"])), String(entry["op"]) == "press", 0)
		"text":
			var ch := String(entry["char"])
			_send_key(OS.find_keycode_from_string(ch), true, ch.unicode_at(0))
			_send_key(OS.find_keycode_from_string(ch), false, ch.unicode_at(0))
		"mouse":
			_deliver_pointer({"mode": "input", "pos": step["position"]}, entry, int(step["button"]))
		"click":
			return _fire_click(step, entry, ordinal)
	return ""


## An action step presses whatever the game's own InputMap binds to the action — a real key/button event, so both event-driven and Input-polling code respond — falling back to InputEventAction only when the action has no pressable binding.
func _fire_action(step: Dictionary, entry: Dictionary, ordinal: int) -> String:
	var action := String(step["action"])
	if not InputMap.has_action(action):
		return "step %d: the running game has no input action \"%s\" — its InputMap knows: %s." % [ordinal, action, _known_actions()]
	var pressed := String(entry["op"]) == "press"
	var events := InputMap.action_get_events(action)
	for source in events:
		if source is InputEventKey or source is InputEventMouseButton or source is InputEventJoypadButton:
			var ev: InputEvent = source.duplicate()
			ev.set("pressed", pressed)
			Input.parse_input_event(ev)
			return ""
	var fallback := InputEventAction.new()
	fallback.action = action
	fallback.pressed = pressed
	fallback.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(fallback)
	return ""


func _known_actions() -> String:
	var names: Array = []
	for action in InputMap.get_actions():
		if not String(action).begins_with("ui_"):
			names.append(String(action))
	if names.is_empty():
		return "only the built-in ui_* actions"
	if names.size() > 20:
		names = names.slice(0, 20)
		names.append("…")
	return ", ".join(PackedStringArray(names))


func _send_key(keycode: Key, pressed: bool, unicode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = pressed
	if pressed and unicode != 0:
		ev.unicode = unicode
	Input.parse_input_event(ev)


## A click step resolves its control once, at the pointer move, and refuses honestly when the control can't take a real click; press and release reuse the resolved route.
func _fire_click(step: Dictionary, entry: Dictionary, ordinal: int) -> String:
	if String(entry["op"]) == "point":
		var route := _resolve_click(String(step["path"]), ordinal)
		if route.has("why"):
			return String(route["why"])
		_click_routes[int(entry["step"])] = route
		if route.has("note"):
			(_sequence["notes"] as Array).append(String(route["note"]))
	var stored: Dictionary = _click_routes.get(int(entry["step"]), {})
	if stored.is_empty():
		return "step %d: the click's target was never resolved — this is a plugin bug worth reporting." % ordinal
	_deliver_pointer(stored, entry, int(step["button"]))
	return ""


## Where and how a control gets its click. The mapped route is the real one: the control's centre carried through SubViewportContainer chains to root-window coordinates (Protocol.window_point), delivered via Input.parse_input_event exactly where a player's cursor would land — container forwarding, hover, focus, and Input polling all behave as for a hardware click, embedded windows offset into root coordinates. Only a control whose viewport has no window position at all (a ViewportTexture on a mesh, an off-screen viewport) falls back to a direct viewport push, disclosed — that fallback provably cannot fire buttons in container-held viewports, which is why the mapping comes first.
func _resolve_click(path: String, ordinal: int) -> Dictionary:
	var node := get_tree().root.get_node_or_null(path)
	if node == null:
		return {"why": "step %d: no node exists at %s — read_game_ui lists the live controls with exact paths." % [ordinal, path]}
	if not node is Control:
		return {"why": "step %d: %s is a %s, not a Control — clicking only reaches UI; call_game_method can poke other nodes." % [ordinal, path, node.get_class()]}
	var ctrl := node as Control
	if not ctrl.is_visible_in_tree():
		return {"why": "step %d: %s is hidden right now, so a real click cannot reach it — something must show it first (read_game_ui marks hidden controls)." % [ordinal, path]}
	var disabled: Variant = ctrl.get("disabled")
	if disabled is bool and disabled:
		return {"why": "step %d: %s is disabled and would swallow the click — enable it first (call_game_method can set \"disabled\" false) or test the enabling path." % [ordinal, path]}
	var mapped: Dictionary = Protocol.window_point(ctrl, ctrl.size / 2.0)
	if bool(mapped["ok"]):
		var window := mapped["window"] as Window
		var pos: Vector2 = mapped["pos"]
		if window == get_tree().root:
			return {"mode": "input", "pos": pos}
		if window.is_embedded():
			return {"mode": "input", "pos": pos + Vector2(window.position)}
		# A native extra window handles its own gui, so the events go straight into it.
		return {"mode": "viewport", "viewport": window, "pos": pos, "note": "step %d clicked %s in the separate native window %s — the events were pushed into that window directly." % [ordinal, path, window.name]}
	return {
		"mode": "viewport",
		"viewport": ctrl.get_viewport(),
		"pos": ctrl.get_global_transform_with_canvas() * (ctrl.size / 2.0),
		"note": "step %d clicked %s inside %s, which has no window position (it is not embedded through SubViewportContainers): the events were pushed into that viewport directly — GUI may react, but Input-polling code cannot see them." % [ordinal, path, ctrl.get_viewport().get_class()],
	}


## One pointer event of the entry's op down the resolved route — motion and button events through Input.parse_input_event (the OS-truth path), or pushed straight into a SubViewport that the OS pipeline can't reach.
func _deliver_pointer(route: Dictionary, entry: Dictionary, button: int) -> void:
	var pos: Vector2 = route["pos"]
	var ev: InputEvent
	if String(entry["op"]) == "point":
		# The user's real cursor is deliberately NOT warped: a plain click's three events land in one input flush, so the parked hardware cursor cannot contest them (probe-measured), and the fake overlay cursor shows the user where the input points.
		if String(route["mode"]) == "input":
			_show_pointer(pos)
		var motion := InputEventMouseMotion.new()
		motion.position = pos
		motion.global_position = pos
		ev = motion
	else:
		var press := InputEventMouseButton.new()
		press.position = pos
		press.global_position = pos
		press.button_index = button as MouseButton
		press.pressed = String(entry["op"]) == "press"
		if press.pressed:
			press.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else (MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_MIDDLE)
		ev = press
	if String(route["mode"]) == "input":
		Input.parse_input_event(ev)
	else:
		(route["viewport"] as Viewport).push_input(ev, true)
