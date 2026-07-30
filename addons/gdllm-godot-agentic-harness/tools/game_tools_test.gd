extends SceneTree
## Headless regression tests for the game-driving tools' pure halves: step normalization with its tolerant keys, caps, and refusals (GDLLMGameProtocol), the event schedule both processes derive from the same steps, the wire sanitizer, the live-UI snapshot walker driven against a real (headless) Control tree, the tool-result composers, the Make-changes gate's runs-code wording, the transport refusal ladder, and the headless refusals — everything short of a live game, which only an editor-attached run can supply.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/game_tools_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const Protocol = preload("res://addons/gdllm-godot-agentic-harness/gdllm_game_protocol.gd")
const Game = preload("res://addons/gdllm-godot-agentic-harness/gdllm_game.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_normalize_steps()
	_test_schedule()
	_test_sanitize()
	_test_composers()
	_test_gate_and_flags()
	_test_headless_refusals()
	_test_suspend_composers()
	_test_breaked_late()
	# The snapshot walker needs nodes inside a live tree (paths, visibility), so it runs on the first frame, where the root window is fully up.
	process_frame.connect(_on_first_frame, CONNECT_ONE_SHOT)


func _on_first_frame() -> void:
	_test_ui_snapshot()
	_test_world_rows()
	_test_inspect_node()
	_test_inspect_budget()
	_test_ui_filter()
	_test_call_target_error()
	_test_value_budget()
	_test_call_cross_reference()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_normalize_steps() -> void:
	var action: Dictionary = Protocol.normalize_steps([{"action": "jump", "hold": 0.5}])
	_check(bool(action["ok"]), "an action step normalizes")
	_check(String((action["steps"] as Array)[0]["kind"]) == "action" and float((action["steps"] as Array)[0]["hold"]) == 0.5, "the action step keeps its name and hold")
	var bare: Dictionary = Protocol.normalize_steps(["jump"])
	_check(bool(bare["ok"]) and String((bare["steps"] as Array)[0]["action"]) == "jump", "a bare string step is taken as an action press")
	var alias: Dictionary = Protocol.normalize_steps([{"input_action": "fire", "duration": 2}])
	_check(bool(alias["ok"]) and float((alias["steps"] as Array)[0]["hold"]) == 2.0, "tolerant keys resolve (input_action, duration)")
	var key: Dictionary = Protocol.normalize_steps([{"key": "Space"}])
	_check(bool(key["ok"]) and float((key["steps"] as Array)[0]["hold"]) == Protocol.DEFAULT_HOLD, "a key step normalizes with the default hold")
	var bad_key: Dictionary = Protocol.normalize_steps([{"key": "NotARealKeyName"}])
	_check(not bool(bad_key["ok"]) and String(bad_key["why"]).contains("NotARealKeyName"), "an unknown key name is refused naming the key")
	var text: Dictionary = Protocol.normalize_steps([{"text": "hi"}])
	_check(bool(text["ok"]) and String((text["steps"] as Array)[0]["kind"]) == "text", "a text step normalizes")
	var long_text: Dictionary = Protocol.normalize_steps([{"text": "x".repeat(Protocol.MAX_TEXT_CHARS + 1)}])
	_check(not bool(long_text["ok"]) and String(long_text["why"]).contains(str(Protocol.MAX_TEXT_CHARS)), "an over-long text step is refused with the cap")
	var click: Dictionary = Protocol.normalize_steps([{"click": "/root/Menu/Start", "button": "right"}])
	_check(bool(click["ok"]) and int((click["steps"] as Array)[0]["button"]) == MOUSE_BUTTON_RIGHT, "a click step resolves its button name")
	_check(not (click["steps"] as Array)[0].has("hold"), "a plain click carries no hold — it lands atomically")
	var held: Dictionary = Protocol.normalize_steps([{"click": "/root/X", "hold": 0.5}])
	_check(float((held["steps"] as Array)[0]["hold"]) == 0.5, "an explicit hold on a click is kept")
	var bad_button: Dictionary = Protocol.normalize_steps([{"click": "/root/X", "button": "side"}])
	_check(not bool(bad_button["ok"]) and String(bad_button["why"]).contains("left"), "an unknown button name is refused naming the choices")
	var mouse: Dictionary = Protocol.normalize_steps([{"mouse": [512, 300]}])
	_check(bool(mouse["ok"]) and (mouse["steps"] as Array)[0]["position"] == Vector2(512, 300), "a mouse step parses its coordinates")
	var bad_mouse: Dictionary = Protocol.normalize_steps([{"mouse": "center"}])
	_check(not bool(bad_mouse["ok"]) and String(bad_mouse["why"]).contains("two-number"), "a positionless mouse step is refused with the shape")
	var wait: Dictionary = Protocol.normalize_steps([{"wait": 0.5}])
	_check(bool(wait["ok"]) and float((wait["steps"] as Array)[0]["seconds"]) == 0.5, "a wait step normalizes")
	var bad_wait: Dictionary = Protocol.normalize_steps([{"wait": -1}])
	_check(not bool(bad_wait["ok"]), "a negative wait is refused")
	var mixed: Dictionary = Protocol.normalize_steps([{"action": "a", "key": "B"}])
	_check(not bool(mixed["ok"]) and String(mixed["why"]).contains("mixes"), "a step naming two inputs is refused as mixed")
	var settled: Dictionary = Protocol.normalize_steps([{"click": "/root/X", "wait": 1.0}])
	_check(bool(settled["ok"]) and float((settled["steps"] as Array)[0]["then_wait"]) == 1.0, "a wait riding an input step becomes a trailing settle, not a mixed-step refusal")
	_check(float(settled["seconds"]) > 1.0, "the trailing settle counts toward the sequence's length")
	var bad_settle: Dictionary = Protocol.normalize_steps([{"key": "Space", "wait": -3}])
	_check(not bool(bad_settle["ok"]), "a negative trailing settle is still refused")
	var empty_step: Dictionary = Protocol.normalize_steps([{}])
	_check(not bool(empty_step["ok"]) and String(empty_step["why"]).contains("names no input"), "an empty step is refused")
	var not_a_step: Dictionary = Protocol.normalize_steps([42])
	_check(not bool(not_a_step["ok"]), "a non-object step is refused")
	var too_many: Array = []
	for i in Protocol.MAX_STEPS + 1:
		too_many.append({"key": "Space"})
	var capped: Dictionary = Protocol.normalize_steps(too_many)
	_check(not bool(capped["ok"]) and String(capped["why"]).contains(str(Protocol.MAX_STEPS)), "too many steps are refused with the cap and the split remedy")
	var too_long: Dictionary = Protocol.normalize_steps([{"wait": 6}, {"wait": 6}])
	_check(not bool(too_long["ok"]) and String(too_long["why"]).contains("split it"), "a sequence past the time cap is refused with the split remedy")
	_check(not bool(Protocol.normalize_steps([])["ok"]), "an empty steps array is refused")
	var second_error: Dictionary = Protocol.normalize_steps([{"key": "Space"}, {"wait": -2}])
	_check(String(second_error["why"]).contains("step 2"), "a step error names the failing step's ordinal")


func _test_schedule() -> void:
	var action: Dictionary = Protocol.normalize_steps([{"action": "jump", "hold": 0.5}])
	var schedule: Dictionary = Protocol.build_schedule(action["steps"])
	var entries: Array = schedule["entries"]
	_check(entries.size() == 2, "an action step schedules a press and a release")
	_check(String(entries[0]["op"]) == "press" and float(entries[0]["at"]) == 0.0, "the press fires at once")
	_check(String(entries[1]["op"]) == "release" and is_equal_approx(float(entries[1]["at"]), 0.5), "the release fires after the hold")
	_check(is_equal_approx(float(schedule["seconds"]), 0.5 + Protocol.STEP_GAP + Protocol.SETTLE_TAIL), "the total carries the gap and the settle tail")
	var click: Dictionary = Protocol.normalize_steps([{"click": "/root/A"}])
	var click_entries: Array = Protocol.build_schedule(click["steps"])["entries"]
	_check(click_entries.size() == 3 and String(click_entries[0]["op"]) == "point", "a click schedules point, press, release")
	_check(float(click_entries[0]["at"]) == float(click_entries[2]["at"]), "a plain click's three events share one instant — one input flush, so nothing can interleave and cancel the press")
	var held_click: Dictionary = Protocol.normalize_steps([{"click": "/root/A", "hold": 0.5}])
	var held_entries: Array = Protocol.build_schedule(held_click["steps"])["entries"]
	_check(float(held_entries[1]["at"]) > float(held_entries[0]["at"]) and is_equal_approx(float(held_entries[2]["at"]) - float(held_entries[1]["at"]), 0.5), "an explicit hold spaces the press and release across real time")
	var typed: Dictionary = Protocol.normalize_steps([{"text": "ab"}])
	var typed_entries: Array = Protocol.build_schedule(typed["steps"])["entries"]
	_check(typed_entries.size() == 2 and String(typed_entries[0]["char"]) == "a" and String(typed_entries[1]["char"]) == "b", "a text step schedules one char op per character")
	_check(float(typed_entries[1]["at"]) > float(typed_entries[0]["at"]), "characters are paced, not batched")
	var waited: Dictionary = Protocol.normalize_steps([{"wait": 1.0}, {"action": "go"}])
	var wait_entries: Array = Protocol.build_schedule(waited["steps"])["entries"]
	_check(wait_entries.size() == 2 and float(wait_entries[0]["at"]) >= 1.0, "a wait step delays the next input without scheduling events of its own")
	_check(int(wait_entries[0]["step"]) == 1, "schedule entries carry their step index")


func _test_sanitize() -> void:
	_check(int(Protocol.sanitize_result(5)) == 5 and Protocol.sanitize_result(null) == null, "primitives pass through")
	var clipped: String = Protocol.sanitize_result("y".repeat(Protocol.RESULT_MAX_CHARS + 7))
	_check(clipped.contains("+7 more chars"), "a runaway string is clipped with the elided count")
	var object: String = Protocol.sanitize_result(RefCounted.new())
	_check(object.contains("RefCounted"), "an Object becomes its string description, never a reference")
	var nested: Variant = [[[[[["deep"]]]]]]
	var sane: Variant = Protocol.sanitize_result(nested)
	_check(str(sane).contains("[array of"), "nesting past the depth cap collapses to a count")
	var big := {}
	for i in Protocol.RESULT_MAX_ELEMENTS + 3:
		big["k%d" % i] = i
	var capped: Dictionary = Protocol.sanitize_result(big)
	_check(capped.has("…") and String(capped["…"]).contains("+3 more entries"), "an oversized dictionary is capped with the count")
	_check(Protocol.sanitize_result(Vector2(1, 2)) == Vector2(1, 2), "math types pass through untouched")


func _test_composers() -> void:
	var played: String = Tools.format_input_played({"ok": true, "executed": 3, "notes": ["step 2 clicked X inside SubViewport"], "focus": "/root/Menu/Name"}, 1.5, "the run this session started")
	_check(played.contains("Played 3 input step(s)") and played.contains("~1.5 s"), "a played sequence reports its step count and length")
	_check(played.contains("the run this session started"), "whose session was driven is disclosed")
	_check(played.contains("Note: step 2 clicked"), "agent notes ride the result")
	_check(played.contains("Keyboard focus after the sequence: /root/Menu/Name."), "the ending focus is reported")
	var stopped: String = Tools.format_input_played({"ok": false, "executed": 1, "why": "step 2: /root/X is hidden right now", "focus": ""}, 3.0, "the user's running session")
	_check(stopped.begins_with("Error:") and stopped.contains("after 1 completed step(s)") and stopped.contains("hidden"), "a stopped sequence names the failing step's reason and what did play")
	_check(stopped.contains("Keyboard focus after the sequence: nothing."), "an empty focus is stated, not omitted")
	var called: String = Tools.format_game_call({"ok": true, "value": 42, "type": "int"}, "/root/Main/Player", "get_score", [], "the user's running session")
	_check(called.contains("/root/Main/Player.get_score()") and called.contains("returned 42 (int)"), "a call reports its target and typed result")
	_check(called.contains("the user's running session"), "a call disclosed whose session it reached")
	var with_args: String = Tools.format_game_call({"ok": true, "value": "hi", "type": "String"}, "/root/A", "greet", ["bob", 2], "the run this session started")
	_check(with_args.contains("greet(\"bob\", 2)") and with_args.contains("returned \"hi\""), "arguments and string results render readably")
	var refused: String = Tools.format_game_call({"ok": false, "why": "no node exists at /root/Nope"}, "/root/Nope", "get", [], "x")
	_check(refused.begins_with("Error:") and refused.contains("/root/Nope"), "an agent-side call refusal is relayed as the error")
	_check(Tools._multi_session_note(1) == "", "a single session needs no multi-instance note")
	_check(Tools._multi_session_note(3).contains("3 debug sessions"), "a multi-instance run is disclosed")
	var snapshot: String = Protocol.format_ui_snapshot({"rows": [], "dropped": 0, "all": false, "scope": "/root/Menu", "scene": "res://menu.tscn", "paused": false, "focus": ""})
	_check(snapshot.contains("no controls under /root/Menu"), "an empty snapshot says so instead of rendering a blank list")


func _test_gate_and_flags() -> void:
	_check(Tools.is_mutating("send_game_input") and Tools.is_mutating("call_game_method"), "the driving tools ride the mutating gate")
	_check(not Tools.is_mutating("read_game_ui"), "the snapshot is a read tool, ungated")
	_check(Tools.RUN_TOOLS.has("send_game_input") and Tools.RUN_TOOLS.has("call_game_method"), "both driving tools carry the runs-code refusal wording")
	var gated: Dictionary = await Tools.execute("send_game_input", {"steps": [{"action": "jump"}]})
	_check(String(gated["content"]).contains("runs the project's own code") and String(gated["content"]).contains("Make changes"), "the gate refusal words what the tool does, not a file-edit lie")
	var call_gated: Dictionary = await Tools.execute("call_game_method", {"path": "/root", "method": "get"})
	_check(String(call_gated["content"]).contains("runs the project's own code"), "call_game_method's gate refusal matches")


func _test_headless_refusals() -> void:
	var ui: Dictionary = await Tools.execute("read_game_ui", {})
	_check(String(ui["content"]).begins_with("Error:") and String(ui["content"]).contains("headless"), "read_game_ui refuses by name in a headless run")
	_check(String(ui["content"]).contains("no game to read"), "the snapshot refusal says what is missing")
	var drive: Dictionary = await Tools.execute("send_game_input", {"steps": [{"action": "jump"}]}, true)
	_check(String(drive["content"]).contains("no game to drive"), "send_game_input refuses by name in a headless run")
	var shorthand: Dictionary = await Tools.execute("send_game_input", {"action": "jump", "hold": 0.2}, true)
	_check(String(shorthand["content"]).contains("no game to drive"), "a single bare step reaches the transport, proving the shorthand parses")
	var bad_steps: Dictionary = await Tools.execute("send_game_input", {"steps": [{"key": "zzz_unknown"}]}, true)
	_check(String(bad_steps["content"]).contains("step 1"), "a malformed sequence is refused before any transport is tried")
	var stepless: Dictionary = await Tools.execute("send_game_input", {}, true)
	_check(String(stepless["content"]).contains("steps"), "a stepless call carries the usage shape")
	var incomplete: Dictionary = await Tools.execute("call_game_method", {"path": "/root"}, true)
	_check(String(incomplete["content"]).contains("method"), "a methodless call carries the usage shape")
	var reach: Dictionary = await Tools.execute("call_game_method", {"path": "/root", "method": "get", "args": ["name"]}, true)
	_check(String(reach["content"]).contains("no game to reach"), "call_game_method refuses by name in a headless run")
	var unexpected: Dictionary = await Tools.execute("read_game_ui", {"bogus": 1})
	_check(String(unexpected["content"]).contains("path"), "an unknown argument answers with the usage line")
	var transport: Dictionary = await Game.command({"op": "ping"}, 100)
	_check(not bool(transport["ok"]) and String(transport["why_kind"]) == "headless", "the transport itself reports the headless rung for the tools to word")


func _test_ui_snapshot() -> void:
	var holder := Control.new()
	holder.name = "TestUiHolder"
	root.add_child(holder)
	var button := Button.new()
	button.name = "Start"
	button.text = "Start Game"
	button.position = Vector2(100, 50)
	button.size = Vector2(200, 40)
	holder.add_child(button)
	var hidden := Button.new()
	hidden.name = "Hidden"
	hidden.visible = false
	holder.add_child(hidden)
	var disabled := Button.new()
	disabled.name = "Locked"
	disabled.disabled = true
	holder.add_child(disabled)
	var sprite := Node2D.new()
	sprite.name = "NotAControl"
	holder.add_child(sprite)
	var snapshot: Dictionary = Protocol.ui_snapshot(holder, false)
	var rows: Array = snapshot["rows"]
	_check(rows.size() == 4 and int(snapshot["dropped"]) == 0, "controls are walked, non-controls skipped")
	var start_row := _row_named(rows, "Start")
	_check(String(start_row["text"]) == "Start Game", "a button's label rides its row")
	_check(String(start_row["path"]).begins_with("/root/"), "rows carry absolute live paths")
	var start_rect: Array = start_row["rect"]
	_check(int(start_rect[0]) == 100 and int(start_rect[1]) == 50 and int(start_rect[2]) == 200, "the rect is the control's window position and size")
	_check(bool(start_row["visible"]), "a visible control is marked visible")
	_check(not bool(_row_named(rows, "Hidden")["visible"]), "a hidden control is marked, not omitted")
	_check(bool(_row_named(rows, "Locked").get("disabled", false)), "a disabled control is flagged")
	button.grab_focus()
	var focused: Dictionary = Protocol.ui_snapshot(holder, false)
	_check(bool(_row_named(focused["rows"], "Start").get("focused", false)), "the focused control is flagged")
	var everything: Dictionary = Protocol.ui_snapshot(holder, true)
	_check((everything["rows"] as Array).size() == 5, "all_nodes includes non-controls")
	var found_2d := _row_named(everything["rows"], "NotAControl")
	_check(String(found_2d["class"]) == "Node2D" and not found_2d.has("rect"), "a non-control row names its class without inventing a rect")
	var svc := SubViewportContainer.new()
	svc.name = "SVC"
	svc.position = Vector2(10, 60)
	svc.size = Vector2(200, 100)
	svc.stretch = true
	svc.stretch_shrink = 2
	holder.add_child(svc)
	var sub_vp := SubViewport.new()
	sub_vp.size = Vector2i(100, 50)
	svc.add_child(sub_vp)
	var sub_button := Button.new()
	sub_button.name = "SubButton"
	sub_button.position = Vector2(5, 5)
	sub_button.size = Vector2(60, 20)
	sub_vp.add_child(sub_button)
	var mapped: Dictionary = Protocol.window_point(sub_button, sub_button.size / 2.0)
	var expected: Vector2 = svc.get_global_transform_with_canvas() * ((sub_button.position + sub_button.size / 2.0) * 2.0)
	_check(bool(mapped["ok"]) and (mapped["pos"] as Vector2).is_equal_approx(expected), "window_point maps through a stretch-shrink container to real window coordinates")
	var sub_row := _row_named(Protocol.ui_snapshot(svc, false)["rows"], "SubButton")
	var sub_rect: Array = sub_row["rect"]
	_check(int(sub_rect[0]) == 20 and int(sub_rect[1]) == 70 and int(sub_rect[2]) == 120, "a subviewport control's rect is reported in window coordinates, scaled through the container")
	_check(not sub_row.has("viewport_local"), "a container-embedded control's rect carries no local-coords flag")
	var orphan_vp := SubViewport.new()
	holder.add_child(orphan_vp)
	var orphan_ctrl := Button.new()
	orphan_ctrl.name = "Orphan"
	orphan_vp.add_child(orphan_ctrl)
	var orphan_row := _row_named(Protocol.ui_snapshot(holder, false)["rows"], "Orphan")
	_check(bool(orphan_row.get("viewport_local", false)), "a control in a container-less viewport keeps local coords behind the honest flag")
	_check(Protocol._row_line(orphan_row).contains("viewport-local coords"), "the composer marks viewport-local rects")
	var as_path: Variant = Protocol.sanitize_result(sub_button)
	_check(String(as_path).begins_with("<Button at /root/") and String(as_path).ends_with("SubButton>"), "a live Node sanitizes to its class and path — an actionable handle, not a dead reference")
	var overlay := Node.new()
	overlay.name = "FakeCursorLayer"
	overlay.set_meta("gdllm_ignore", true)
	var overlay_child := Button.new()
	overlay_child.name = "NotATarget"
	overlay.add_child(overlay_child)
	holder.add_child(overlay)
	_check(_row_named(Protocol.ui_snapshot(holder, true)["rows"], "NotATarget").is_empty(), "gdllm_ignore-tagged subtrees (the agent's own overlay cursor) never appear as targets")
	for i in Protocol.MAX_UI_ROWS + 5:
		var extra := Button.new()
		extra.name = "Extra%d" % i
		holder.add_child(extra)
	var flooded: Dictionary = Protocol.ui_snapshot(holder, false)
	_check((flooded["rows"] as Array).size() == Protocol.MAX_UI_ROWS and int(flooded["dropped"]) > 0, "rows past the cap are dropped with the overflow counted")
	var body: String = Protocol.format_ui_snapshot({"rows": rows, "dropped": 3, "all": false, "scope": "/root", "scene": "res://menu.tscn", "paused": true, "focus": String(button.get_path())})
	_check(body.contains("Live game controls") and body.contains("res://menu.tscn"), "the composer names the scene")
	_check(body.contains("PAUSED"), "a paused game is disclosed in the header")
	_check(body.contains("3 more dropped") and body.contains("\"path\""), "the dropped count names the scoping lever")
	_check(body.contains("\"Start Game\"") and body.contains("(hidden)") and body.contains("(disabled)"), "rows render text and state markers")
	_check(body.contains("Keyboard focus: /root/"), "the focus line carries the live path")
	holder.free()


func _row_named(rows: Array, name: String) -> Dictionary:
	for row: Dictionary in rows:
		if String(row["path"]).ends_with("/" + name):
			return row
	return {}


## The spatial half of the snapshot: a gameplay node's row has to say WHERE it is, in the game's own world coordinates and on screen, or a 2D/3D scene reads as a list of names with nothing to reason about.
func _test_world_rows() -> void:
	var holder := Node2D.new()
	holder.name = "WorldHolder"
	root.add_child(holder)
	var sprite := Node2D.new()
	sprite.name = "Sprite"
	sprite.position = Vector2(120, 80)
	sprite.rotation_degrees = 30.0
	sprite.scale = Vector2(2, 2)
	holder.add_child(sprite)
	var plain := Node2D.new()
	plain.name = "Plain"
	plain.position = Vector2(10, 20)
	holder.add_child(plain)
	var rows: Array = (Protocol.ui_snapshot(holder, true) as Dictionary)["rows"]
	var row := _row_named(rows, "Sprite")
	_check((row["pos"] as Array)[0] == 120.0 and (row["pos"] as Array)[1] == 80.0, "a Node2D row carries its world position")
	_check(row.has("screen"), "a node in the root window maps to a clickable screen point")
	_check(abs(float(row["rot"]) - 30.0) < 0.5, "a rotated node reports its angle")
	_check(float((row["scale"] as Array)[0]) == 2.0, "a scaled node reports its scale")
	_check(bool(row["visible"]), "a visible gameplay node is marked visible")
	var plain_row := _row_named(rows, "Plain")
	_check(not plain_row.has("rot") and not plain_row.has("scale"), "an unrotated, unscaled node spends no context on defaults")
	var line := Protocol.format_ui_snapshot({"rows": [row], "all": true, "scene": "x", "others": 0})
	_check(line.contains("in world") and line.contains("screen"), "the composed row separates world coordinates from screen ones")
	_check(line.contains("rotated"), "a rotation reaches the composed line")
	# The Controls-only default finds nothing in a scene made of sprites, so it has to name the lever that would.
	var controls_only: Dictionary = Protocol.ui_snapshot(holder, false)
	_check((controls_only["rows"] as Array).is_empty() and int(controls_only["others"]) == 3, "a Controls-only walk counts the non-Control nodes it passed over")
	var empty := Protocol.format_ui_snapshot({"rows": [], "all": false, "scene": "x", "scope": "/root", "others": 3})
	_check(empty.contains("3 non-Control") and empty.contains("\"all\": true"), "an empty Controls-only snapshot names the count and the all lever")
	var camera := Camera3D.new()
	camera.name = "TestCamera"
	root.add_child(camera)
	camera.current = true
	var ahead := Node3D.new()
	ahead.name = "Ahead"
	ahead.position = Vector3(0, 0, -5)
	root.add_child(ahead)
	var behind := Node3D.new()
	behind.name = "Behind"
	behind.position = Vector3(0, 0, 5)
	root.add_child(behind)
	var ahead_row: Dictionary = Protocol.ui_snapshot(ahead, true)["rows"][0]
	_check((ahead_row["pos"] as Array).size() == 3 and float((ahead_row["pos"] as Array)[2]) == -5.0, "a Node3D row carries all three world coordinates")
	_check(ahead_row.has("screen"), "a 3D node in front of the active camera reports where it projects on screen")
	var behind_row: Dictionary = Protocol.ui_snapshot(behind, true)["rows"][0]
	_check(bool(behind_row.get("behind_camera", false)) and not behind_row.has("screen"), "a 3D node behind the camera is marked, never given a mirrored screen point")
	_check(Protocol.format_ui_snapshot({"rows": [behind_row], "all": true, "scene": "x", "others": 0}).contains("BEHIND"), "the composed row states a node is off screen behind the camera")
	holder.queue_free()
	camera.queue_free()
	ahead.queue_free()
	behind.queue_free()


## The whole-node read: a script's own variables are the game's state, and they have to come back WITH their values or the tool is just call_game_method with extra steps.
func _test_inspect_node() -> void:
	var node := Node2D.new()
	node.name = "Inspected"
	var script := GDScript.new()
	script.source_code = "extends Node2D\n\nvar health := 42\nvar label := \"ready\"\n"
	script.reload()
	node.set_script(script)
	node.position = Vector2(5, 6)
	root.add_child(node)
	var payload: Dictionary = Protocol.inspect_node(node, "")
	var script_names: Array = []
	for pair: Array in payload["script_props"]:
		script_names.append(String(pair[0]))
	_check(script_names.has("health") and script_names.has("label"), "the script's own variables are reported")
	_check(String(_prop_value(payload["script_props"], "health")) == "42", "a script variable comes back with its live value")
	_check(String(_prop_value(payload["script_props"], "label")) == "\"ready\"", "a string value is quoted so an empty one is visible")
	_check((payload["engine_props"] as Array).is_empty() and int(payload["engine_total"]) > 0, "the engine's own properties are counted, not listed, so they cannot bury the script's state")
	var with_engine: Dictionary = Protocol.inspect_node(node, "", true)
	var engine_names: Array = []
	for pair: Array in with_engine["engine_props"]:
		engine_names.append(String(pair[0]))
	_check(engine_names.has("position"), "engine properties are there once all: true asks for them")
	_check((payload["place"] as Dictionary).has("pos"), "an inspected gameplay node carries where it is")
	var text := Protocol.format_node_inspect(payload)
	_check(text.contains("health = 42") and text.contains("Script variables"), "the composed report leads with the game's own state")
	_check(text.contains("Node2D"), "the composed report names the class")
	var filtered: Dictionary = Protocol.inspect_node(node, "health")
	_check((filtered["script_props"] as Array).size() == 1 and (filtered["engine_props"] as Array).is_empty(), "a filter narrows to matching property names")
	var missed: Dictionary = Protocol.inspect_node(node, "nosuchproperty")
	_check(Protocol.format_node_inspect(missed).contains("without a filter"), "a filter matching nothing names the way back")
	var bare := Node.new()
	bare.name = "Bare"
	root.add_child(bare)
	_check(Protocol.format_node_inspect(Protocol.inspect_node(bare, "")).contains("no script"), "a node with no script says so rather than implying one")
	node.queue_free()
	bare.queue_free()


## The budget, against a node shaped like a real one: a CharacterBody2D carries well over a hundred engine properties, and an earlier version spent the whole allowance on them in property-list order — dropping exactly the script state that was asked for (measured in a wild session, where it cost ~40 fallback calls).
func _test_inspect_budget() -> void:
	var lines := ["extends CharacterBody2D", ""]
	for i in 40:
		lines.append("var state_%02d := %d" % [i, i])
	# The fat nested value this tool exists to hand over whole: a slot dictionary holding item data holding enchantments.
	lines.append("var hotbar := {}")
	lines.append("")
	lines.append("func _init() -> void:")
	for slot in 10:
		lines.append("\thotbar[%d] = {\"cid\": %d, \"qty\": 1, \"data\": {\"enchantments\": {\"15\": [1, 2], \"11\": [3, 4]}}}" % [slot, 40 + slot])
	var script := GDScript.new()
	script.source_code = "\n".join(PackedStringArray(lines)) + "\n"
	script.reload()
	var body := CharacterBody2D.new()
	body.name = "Budgeted"
	body.set_script(script)
	root.add_child(body)
	var payload: Dictionary = Protocol.inspect_node(body, "")
	var names: Array = []
	for pair: Array in payload["script_props"]:
		names.append(String(pair[0]))
	_check(names.has("state_00") and names.has("state_39") and names.has("hotbar"), "every script variable survives a node whose engine properties outnumber the budget")
	_check((payload["engine_props"] as Array).is_empty() and int(payload["engine_total"]) > 30, "the engine's own properties are counted, not listed, and a CharacterBody2D has dozens")
	_check(int(payload["dropped"]) == 0, "nothing is dropped when the script's state fits — the budget is spent on state, not defaults")
	var text := Protocol.format_node_inspect(payload)
	_check(text.contains("engine propert") and text.contains("\"all\": true"), "the omitted engine properties are counted with their lever named")
	# The wild failure: a state dictionary clipped mid-slot sent the model into a call per slot for what it had already been handed.
	var hotbar_text := _prop_value(payload["script_props"], "hotbar")
	_check(hotbar_text.contains("\"cid\": 49"), "the last slot of a nested state dictionary survives the value budget")
	_check(hotbar_text.contains("enchantments") and not hotbar_text.contains("[array of"), "nesting deep enough for item data is kept, not summarized away")
	var everything: Dictionary = Protocol.inspect_node(body, "", true)
	_check(not (everything["engine_props"] as Array).is_empty() and bool(everything["engine_listed"]), "all: true lists the engine properties")
	var engine_names: Array = []
	for pair: Array in everything["engine_props"]:
		engine_names.append(String(pair[0]))
	_check(engine_names.has("collision_layer"), "an engine property appears once asked for")
	# A filter reaches the engine's properties without `all`: refusing a name the caller typed would be a dead end.
	var filtered: Dictionary = Protocol.inspect_node(body, "collision_layer")
	var filtered_names: Array = []
	for pair: Array in filtered["engine_props"]:
		filtered_names.append(String(pair[0]))
	_check(filtered_names.has("collision_layer"), "a filter reaches an engine property even without all")
	_check((filtered["script_props"] as Array).is_empty(), "that filter matched no script variable, and none is invented")
	body.queue_free()


func _prop_value(pairs: Array, name: String) -> String:
	for pair: Array in pairs:
		if String(pair[0]) == name:
			return String(pair[1])
	return ""


## suspend_game's verdicts: the state the game is left in, and the one consequence a caller has to know — a frozen game answers reads but takes no input.
func _test_breaked_late() -> void:
	var late := Tools._game_reach_error("read", "breaked_late", "no answer within 4.0 s")
	_check(late.contains("BREAKPOINT while it was answering"), "a command the game broke during is attributed to the break, not to a frozen game")
	_check(late.contains("half-done"), "and warns that the work it began may be partial")
	_check(late.contains("read_game_break") and late.contains("remove"), "naming both the read and the way to stop it pausing again")
	_check(Tools._game_reach_error("read", "timeout", "x").contains("frozen, heavily loaded"), "a genuine silent timeout still says so")


func _test_suspend_composers() -> void:
	_check(Tools._suspend_action("freeze") == "on" and Tools._suspend_action("Pause") == "on", "freeze and pause spellings resolve to the freeze")
	_check(Tools._suspend_action("resume") == "off" and Tools._suspend_action("off") == "off", "resume spellings resolve to the thaw")
	_check(Tools._suspend_action("step") == "frame" and Tools._suspend_action("next_frame") == "frame", "step spellings resolve to the frame advance")
	_check(Tools._suspend_action("sideways") == "", "an unrecognized action resolves to nothing for the caller to refuse")
	var froze := Tools._suspend_verdict("on", 0, 1, false, "the run this session started")
	_check(froze.contains("Froze") and froze.contains("send_game_input"), "freezing says what it did and what stops working")
	_check(Tools._suspend_verdict("on", 0, 1, true, "the run").contains("ALREADY"), "freezing an already-frozen game says nothing moved")
	_check(Tools._suspend_verdict("off", 0, 1, true, "the run").contains("Resumed"), "resuming says the game is running again")
	_check(Tools._suspend_verdict("off", 0, 1, false, "the run").contains("NOT suspended"), "resuming a game that was never frozen says so instead of claiming a resume")
	var stepped := Tools._suspend_verdict("frame", 3, 3, true, "the run")
	_check(stepped.contains("3 frame") and stepped.contains("SUSPENDED"), "a frame advance reports the count and that the game is still frozen")
	_check(Tools._suspend_verdict("frame", 1, 3, true, "the run").contains("1 of 3"), "an advance cut short counts what actually landed")
	# The frame ordinals exist for the loop brake as much as for the reader: it reads an identical call returning identical content as a repeat that added nothing, and without them every step rendered the same sentence — which stopped two wild frame-stepping runs at the brake's fourth firing.
	var spanned := Tools._suspend_verdict("frame", 3, 3, true, "the run", 1039, 1042)
	_check(spanned.contains("1039") and spanned.contains("1042"), "a frame advance reports the ordinals it moved between")
	_check(Tools._suspend_verdict("frame", 1, 1, true, "the run", 1039, 1040) != Tools._suspend_verdict("frame", 1, 1, true, "the run", 1040, 1041), "consecutive single-frame steps render DIFFERENTLY, so stepping is never read as a no-op loop")
	var stuck_a := Tools._suspend_verdict("frame", 0, 1, true, "the run", 1039, -1)
	_check(stuck_a == Tools._suspend_verdict("frame", 0, 1, true, "the run", 1039, -1), "a game that never advances still renders identically, so the brake keeps catching futile stepping")
	_check(stuck_a.contains("0 of 1") and not stuck_a.contains("→"), "a step that landed nothing claims no span it did not cross")
	_check(not Tools._suspend_verdict("frame", 2, 2, true, "the run").contains("→"), "with no counter available (an unreachable agent) the report simply omits the ordinals")
	# Measured against a --headless game, which ignores suspension: the presses land, the counter races ahead, and "advanced 1 frame" would be a lie the span quietly contradicts.
	var drifting := Tools._suspend_verdict("frame", 1, 1, true, "the run", 429, 435)
	_check(drifting.contains("WARNING") and drifting.contains("6 frames actually passed"), "a game that ran on between presses is called out, not reported as single-frame stepping")
	_check(not Tools._suspend_verdict("frame", 3, 3, true, "the run", 1039, 1042).contains("WARNING"), "a suspension that IS holding earns no warning")


## Locating a node in a tree too big to list: without a filter the row cap is spent on the first nodes in walk order, so a deep one is unreachable unless its path is already known — the chicken-and-egg a wild session paid ~15 tool calls to escape.
func _test_ui_filter() -> void:
	var holder := Control.new()
	holder.name = "FilterHolder"
	root.add_child(holder)
	# Bury the target past the row cap, exactly as a loaded game buries its player.
	for i in Protocol.MAX_UI_ROWS + 20:
		var filler := Control.new()
		filler.name = "Filler%03d" % i
		holder.add_child(filler)
	var deep := holder
	for i in 3:
		var branch := Control.new()
		branch.name = "Branch%d" % i
		deep.add_child(branch)
		deep = branch
	var target := CharacterBody2D.new()
	target.name = "Player"
	deep.add_child(target)
	var labelled := Button.new()
	labelled.name = "Btn7"
	labelled.text = "Load Game"
	deep.add_child(labelled)
	var unfiltered: Dictionary = Protocol.ui_snapshot(holder, false)
	_check(int(unfiltered["dropped"]) > 0 and _row_named(unfiltered["rows"], "Player").is_empty(), "an unfiltered walk of a big tree drops the buried node entirely")
	_check(Protocol.format_ui_snapshot(unfiltered).contains("\"filter\""), "the overflow line names the filter as the way to find a node, not only the way to walk less")
	var found: Dictionary = Protocol.ui_snapshot(holder, false, "player")
	_check((found["rows"] as Array).size() == 1 and not _row_named(found["rows"], "Player").is_empty(), "a filter finds the buried node by name")
	_check(not _row_named(found["rows"], "Player").has("rect") and _row_named(found["rows"], "Player").has("pos"), "the found gameplay node carries its position, not an invented rect")
	_check(int(found["searched"]) > Protocol.MAX_UI_ROWS and int(found["matched"]) == 1, "the report counts what was searched and what matched")
	_check(int(found["others"]) == 0, "a filtered walk reports no skipped-others count, having searched everything")
	var by_class: Dictionary = Protocol.ui_snapshot(holder, false, "characterbody2d")
	_check((by_class["rows"] as Array).size() == 1, "a filter matches a node's class as well as its name")
	var by_label: Dictionary = Protocol.ui_snapshot(holder, false, "load game")
	_check((by_label["rows"] as Array).size() == 1 and String((by_label["rows"] as Array)[0]["path"]).ends_with("Btn7"), "a filter matches the label a control DISPLAYS, not just its node name")
	var text := Protocol.format_ui_snapshot({"rows": by_label["rows"], "filter": "load game", "matched": 1, "searched": int(by_label["searched"]), "scene": "x", "scope": "/root"})
	_check(text.contains("matching \"load game\"") and text.contains("searched"), "the filtered report says what matched and how much tree was searched")
	var missed: Dictionary = Protocol.ui_snapshot(holder, false, "nosuchnode")
	_check((missed["rows"] as Array).is_empty(), "a filter matching nothing returns nothing")
	var missed_text := Protocol.format_ui_snapshot({"rows": [], "filter": "nosuchnode", "matched": 0, "searched": int(missed["searched"]), "scene": "x", "scope": "/root"})
	_check(missed_text.contains("nosuchnode") and missed_text.contains("searched"), "an empty match reads as a miss over a searched tree, never as an empty game")
	var many: Dictionary = Protocol.ui_snapshot(holder, false, "filler")
	_check(int(many["matched"]) > Protocol.MAX_UI_ROWS and int(many["dropped"]) > 0, "a filter matching more than the cap counts the overflow")
	_check(Protocol.format_ui_snapshot(many).contains("narrow the filter"), "an over-full filtered report names narrowing as the lever")
	holder.queue_free()


## What a call names, when the node does not have it as a method: the wrong advice here is measurable — twice in one afternoon a model called a Button's "pressed" and was told about get/set, then spent six calls rediscovering emit_signal on its own.
func _test_call_target_error() -> void:
	var signal_error := Protocol.call_target_error("/root/UI/Go", "Button", "pressed", true, false, true)
	_check(signal_error.contains("is a SIGNAL"), "a signal is named as a signal, not reported as a missing method")
	_check(signal_error.contains("emit_signal") and signal_error.contains("[\"pressed\"]"), "the signal refusal names emit_signal with the exact arguments")
	_check(signal_error.contains("send_game_input") and signal_error.contains("/root/UI/Go"), "a clickable control is also offered the real click, with its own path")
	_check(not signal_error.contains("get/set"), "the advice that does not apply to a signal is gone")
	var unclickable := Protocol.call_target_error("/root/Timer", "Timer", "timeout", true, false, false)
	_check(unclickable.contains("emit_signal") and not unclickable.contains("send_game_input"), "a node no click can reach is offered only the lever that works on it")
	var property_error := Protocol.call_target_error("/root/Main/Player", "CharacterBody2D", "velocity", false, true, false)
	_check(property_error.contains("is a PROPERTY") and property_error.contains("[\"velocity\"]"), "a property is named outright with its get shape")
	_check(property_error.contains("\"set\""), "the property refusal offers the write side too")
	var unknown := Protocol.call_target_error("/root/Main/Player", "CharacterBody2D", "flurb", false, false, false)
	_check(unknown.contains("inspect_game_node"), "an unrecognized name points at the tool that lists what the node holds")
	for text in [signal_error, property_error, unknown]:
		_check(text.contains("has no method"), "every refusal still states the plain fact it is refusing on")


## The wild trap this closes: a 40-slot inventory that every route truncated. Note the second property — a filter for "inventory" also matches "hovered_inventory_slot", which is why the rule concentrates the budget across matches rather than looking for a single one.
func _test_value_budget() -> void:
	var lines := ["extends Node2D", "", "var hovered_inventory_slot := -1", "var inventory := {}", "var small := 1", "", "func _init() -> void:"]
	for slot in 40:
		lines.append("\tinventory[%d] = {\"cid\": %d, \"qty\": 20, \"data\": {}}" % [slot, slot])
	var script := GDScript.new()
	script.source_code = "\n".join(PackedStringArray(lines)) + "\n"
	script.reload()
	var node := Node2D.new()
	node.name = "Hoarder"
	node.set_script(script)
	root.add_child(node)
	var whole_value := Protocol.value_text(node.get("inventory"), Protocol.INSPECT_TOTAL_CHARS)
	_check(whole_value.length() > Protocol.INSPECT_VALUE_CHARS, "the fixture's inventory really is bigger than the per-value slice, or this proves nothing")
	# The whole-node dump still has to ration, but the clip now says how to undo itself.
	var dump: Dictionary = Protocol.inspect_node(node, "")
	var clipped := _prop_value(dump["script_props"], "inventory")
	_check(clipped.contains("more chars"), "a whole-node dump still clips a value too big to ration room for")
	_check(clipped.contains("\"filter\": \"inventory\""), "the clip names the exact filter that would return it whole")
	# The wild filter: matches the fat property AND a second one whose name contains it.
	var narrowed: Dictionary = Protocol.inspect_node(node, "inventory")
	_check((narrowed["script_props"] as Array).size() == 2, "the filter matches both the fat property and its lookalike, as it did in the wild")
	var full := _prop_value(narrowed["script_props"], "inventory")
	_check(not full.contains("more chars"), "concentrating the budget on the filter's matches returns the fat value WHOLE")
	_check(full.contains("\"39\""), "the last slot of the forty is present, which is what the wild session could never reach")
	_check(_prop_value(narrowed["script_props"], "hovered_inventory_slot") == "-1", "the lookalike still reports its own value")
	# A value alone under its filter has nowhere further to go, so it is not sent in a circle.
	var alone: Dictionary = Protocol.inspect_node(node, "small")
	_check(not _prop_value(alone["script_props"], "small").contains("filter"), "a value that fits names no lever it does not need")
	var solo := Protocol.value_text("x".repeat(Protocol.INSPECT_TOTAL_CHARS + 500), Protocol.INSPECT_TOTAL_CHARS)
	_check(solo.contains("more chars") and not solo.contains("filter"), "a value clipped at the whole budget offers no filter that could beat it")
	node.queue_free()


## The one cross-reference a measured discovery failure earned: a wild run solved "change this permanently" with a live set alone, having never searched for the reload tool at all — it had this schema attached, so this is where it could have learned the neighbour exists.
func _test_call_cross_reference() -> void:
	var desc := String((Tools.REGISTRY["call_game_method"] as Dictionary)["description"])
	_check(desc.contains("reload_game_scripts"), "call_game_method names the tool that makes a change outlive the run")
	_check(desc.contains("no project file changes"), "and states plainly that a set touches nothing on disk")
	# Wording rail: a set is not simply "lost on restart" — the game's own save system may write it out, and claiming otherwise would be the same overreach the reload refusal had to walk back.
	_check(desc.contains("unless the game's own saving writes it out"), "the ephemerality claim is qualified rather than overstated")
	_check(String((Tools.REGISTRY["reload_game_scripts"] as Dictionary)["description"]).contains("state"), "the reload tool still carries its own code-versus-state warning")
