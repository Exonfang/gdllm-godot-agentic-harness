@tool
class_name GDLLMGameProtocol extends RefCounted
## The pure halves shared by the editor's game-driving tools (GDLLMGame) and the in-game agent autoload (gdllm_game_agent.gd): input-step normalization, the event schedule both processes derive identically from the same steps, the live-UI snapshot walker, and the wire sanitizer that keeps every reply a plain Variant. Everything here is static and side-effect free so the headless suite can drive it without a running game; the only editor/game split left is delivery — the agent fires the schedule with real Input events, the editor only sizes its timeout from it.

## Bumped when the message protocol changes shape; the editor refuses a mismatched agent by version rather than misreading it.
const VERSION := 2

## Bounds on one input sequence: steps per call, wall-clock seconds per call, and per-step hold/wait clamps — one call is a bounded gesture, never an unattended play session.
const MAX_STEPS := 20
const MAX_TOTAL_SECONDS := 10.0
const DEFAULT_HOLD := 0.1
const MAX_HOLD := 5.0
const MIN_HOLD := 0.02
const MIN_WAIT := 0.05
## Seconds per typed character (about two frames at 60 fps), and the most characters one text step may type.
const TYPE_CHAR_SECONDS := 0.03
const MAX_TEXT_CHARS := 200
## Settle gaps: between steps, between a pointer move and its press, and after the last event before the agent replies — so a game reacting on the next frame is not read mid-reaction.
const STEP_GAP := 0.05
const POINT_TO_PRESS := 0.02
const SETTLE_TAIL := 0.1

## Rows one UI snapshot returns before the remainder collapses to a dropped count; the scope path is the lever for more.
const MAX_UI_ROWS := 80
## Bounds on one node inspection. The budget that matters is CHARS, not property count: a node's state is a handful of fat dictionaries among many small scalars, and counting properties would either starve the fat ones or wave through a hundred defaults. One value may print to INSPECT_VALUE_CHARS and the whole report's values to INSPECT_TOTAL_CHARS, after which the remainder is counted and the filter named.
const MAX_INSPECT_PROPS := 120
const INSPECT_VALUE_CHARS := 1200
const INSPECT_TOTAL_CHARS := 10000
## Container depth an inspected value keeps, deeper than a call result's: the state this tool exists to show is nested by nature (a slot dictionary holding item data holding enchantments), and the shallower default rendered exactly that as "[array of N]".
const INSPECT_DEPTH := 6
## Container elements an inspected value keeps, far above a call result's: a 40-slot inventory silently lost its last eight entries to the call-result cap, and an entry dropped whole is worse than one clipped mid-text — the character budget above is what actually bounds an inspection, and it can only do that job if a smaller cap is not cutting in ahead of it.
const INSPECT_MAX_ELEMENTS := 200
## Depth and size caps on a relayed call result, so one return value can't flood the wire or the context.
const RESULT_DEPTH := 4
const RESULT_MAX_ELEMENTS := 32
const RESULT_MAX_CHARS := 2000

## The tolerant key sets one step dictionary is read through; exactly one primary group may be present per step.
const STEP_ACTION_KEYS := ["action", "input_action"]
const STEP_KEY_KEYS := ["key", "keycode", "scancode"]
const STEP_TEXT_KEYS := ["text", "type", "typing", "write"]
const STEP_CLICK_KEYS := ["click", "click_path", "control", "node", "path"]
const STEP_MOUSE_KEYS := ["mouse", "position", "at", "pos", "point"]
const STEP_WAIT_KEYS := ["wait", "wait_seconds", "delay", "pause", "sleep"]
const STEP_HOLD_KEYS := ["hold", "hold_seconds", "seconds", "duration", "for"]
const STEP_BUTTON_KEYS := ["button", "mouse_button"]

const STEPS_USAGE := "Pass \"steps\": an array where each step holds ONE of — {\"action\": \"jump\"} (an InputMap action), {\"key\": \"Space\"} (a key by name), {\"text\": \"hello\"} (typed into the focused control), {\"click\": \"/root/Menu/StartButton\"} (a control path from read_game_ui), {\"mouse\": [x, y]} (a click at window coordinates, optional \"button\": \"left\"/\"right\"/\"middle\"), or {\"wait\": 0.5} (idle seconds) — plus optional \"hold\" seconds on action/key/click/mouse. A single step may be passed directly without the array."

const MOUSE_BUTTON_NAMES := {
	"left": MOUSE_BUTTON_LEFT,
	"right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE,
}


## Normalize a raw steps array into typed step dictionaries, refusing malformed input with the exact expected shape: {"ok", "steps", "seconds", "why"}. A bare string step is taken as an action press — the shorthand a schema-blind model reaches for. The seconds figure comes from the same schedule the agent will fire, so the editor's timeout and the game's playback can never disagree.
static func normalize_steps(raw: Array) -> Dictionary:
	if raw.is_empty():
		return _steps_error("the steps array is empty. " + STEPS_USAGE)
	if raw.size() > MAX_STEPS:
		return _steps_error("%d steps were passed and one call is capped at %d — split the sequence into multiple send_game_input calls." % [raw.size(), MAX_STEPS])
	var steps: Array = []
	for i in raw.size():
		var one := _normalize_step(raw[i], i + 1)
		if one.has("why"):
			return _steps_error(String(one["why"]))
		steps.append(one)
	var seconds := float(build_schedule(steps)["seconds"])
	if seconds > MAX_TOTAL_SECONDS:
		return _steps_error("the sequence would play for about %.1f s, over the %.0f s cap on one call — split it into multiple send_game_input calls (waits and holds count toward the cap)." % [seconds, MAX_TOTAL_SECONDS])
	return {"ok": true, "steps": steps, "seconds": seconds, "why": ""}


static func _steps_error(why: String) -> Dictionary:
	return {"ok": false, "steps": [], "seconds": 0.0, "why": why}


static func _normalize_step(raw: Variant, ordinal: int) -> Dictionary:
	if raw is String:
		return {"kind": "action", "action": String(raw), "hold": DEFAULT_HOLD}
	if not raw is Dictionary:
		return {"why": "step %d is not an object (or action-name string). %s" % [ordinal, STEPS_USAGE]}
	var step: Dictionary = raw
	var groups: Array = []
	for entry in [["action", STEP_ACTION_KEYS], ["key", STEP_KEY_KEYS], ["text", STEP_TEXT_KEYS], ["click", STEP_CLICK_KEYS], ["mouse", STEP_MOUSE_KEYS]]:
		if _first_present(step, entry[1]) != null:
			groups.append(String(entry[0]))
	var wait_value: Variant = _first_present(step, STEP_WAIT_KEYS)
	if groups.size() > 1:
		return {"why": "step %d mixes %s — one input per step; put them in separate steps." % [ordinal, " and ".join(PackedStringArray(groups))]}
	if groups.is_empty():
		if wait_value == null:
			return {"why": "step %d names no input. %s" % [ordinal, STEPS_USAGE]}
		var seconds: float = _float_or(wait_value, -1.0)
		if seconds <= 0.0:
			return {"why": "step %d's wait must be a positive number of seconds." % ordinal}
		return {"kind": "wait", "seconds": clampf(seconds, MIN_WAIT, MAX_TOTAL_SECONDS)}
	var hold_given: Variant = _first_present(step, STEP_HOLD_KEYS)
	var hold := clampf(_float_or(hold_given, DEFAULT_HOLD), MIN_HOLD, MAX_HOLD)
	var normalized: Dictionary
	match String(groups[0]):
		"action":
			normalized = {"kind": "action", "action": String(_first_present(step, STEP_ACTION_KEYS)), "hold": hold}
		"key":
			var key := String(_first_present(step, STEP_KEY_KEYS))
			if OS.find_keycode_from_string(key) == KEY_NONE:
				return {"why": "step %d's key \"%s\" is not a recognized key name — use names like \"Space\", \"Enter\", \"Escape\", \"A\", \"F5\" (OS.find_keycode_from_string's vocabulary)." % [ordinal, key]}
			normalized = {"kind": "key", "key": key, "hold": hold}
		"text":
			var text := String(_first_present(step, STEP_TEXT_KEYS))
			if text.length() > MAX_TEXT_CHARS:
				return {"why": "step %d types %d characters and one text step is capped at %d — split the text across multiple text steps or send_game_input calls." % [ordinal, text.length(), MAX_TEXT_CHARS]}
			if text.is_empty():
				return {"why": "step %d's text is empty." % ordinal}
			normalized = {"kind": "text", "text": text}
		"click":
			var click_button := _button_index(step)
			if click_button < 0:
				return {"why": "step %d's mouse button must be \"left\", \"right\", or \"middle\"." % ordinal}
			normalized = {"kind": "click", "path": String(_first_present(step, STEP_CLICK_KEYS)), "button": click_button}
			# A pointer step carries a hold only when one was asked for: a plain click lands as one atomic press-release (see build_schedule), while an explicit hold spans real time.
			if hold_given != null:
				normalized["hold"] = hold
		"mouse":
			var pos: Variant = _first_present(step, STEP_MOUSE_KEYS)
			if not (pos is Array and (pos as Array).size() == 2 and _is_number((pos as Array)[0]) and _is_number((pos as Array)[1])):
				return {"why": "step %d's mouse position must be a two-number array of window coordinates, e.g. {\"mouse\": [512, 300]}." % ordinal}
			var mouse_button := _button_index(step)
			if mouse_button < 0:
				return {"why": "step %d's mouse button must be \"left\", \"right\", or \"middle\"." % ordinal}
			normalized = {"kind": "mouse", "position": Vector2(float(pos[0]), float(pos[1])), "button": mouse_button}
			if hold_given != null:
				normalized["hold"] = hold
		_:
			return {"why": "step %d could not be read. %s" % [ordinal, STEPS_USAGE]}
	# A wait riding an input step is a trailing settle after that input — the natural shape wild transcripts reached for ({"click": ..., "wait": 1.0}) — not a mixed step.
	if wait_value != null:
		var settle: float = _float_or(wait_value, -1.0)
		if settle <= 0.0:
			return {"why": "step %d's wait must be a positive number of seconds." % ordinal}
		normalized["then_wait"] = clampf(settle, MIN_WAIT, MAX_TOTAL_SECONDS)
	return normalized


## The step's mouse button as a MouseButton index; left when unnamed, -1 when the name is not one this tool speaks.
static func _button_index(step: Dictionary) -> int:
	var value: Variant = _first_present(step, STEP_BUTTON_KEYS)
	if value == null:
		return MOUSE_BUTTON_LEFT
	return int(MOUSE_BUTTON_NAMES.get(String(value).to_lower(), -1))


static func _first_present(step: Dictionary, keys: Array) -> Variant:
	for key in keys:
		if step.has(key):
			return step[key]
	return null


static func _float_or(value: Variant, fallback: float) -> float:
	if _is_number(value):
		return float(value)
	if value is String and String(value).is_valid_float():
		return String(value).to_float()
	return fallback


static func _is_number(value: Variant) -> bool:
	return value is int or value is float


## The timed event list a normalized sequence plays as — [{"at": seconds, "op": "press"/"release"/"point"/"char", "step": index, ...}] plus the total "seconds" including the settle tail. Built identically on both sides of the wire: the agent fires it, the editor sizes its reply timeout from it.
static func build_schedule(steps: Array) -> Dictionary:
	var entries: Array = []
	var t := 0.0
	for i in steps.size():
		var step: Dictionary = steps[i]
		match String(step["kind"]):
			"action", "key":
				entries.append({"at": t, "op": "press", "step": i})
				entries.append({"at": t + float(step["hold"]), "op": "release", "step": i})
				t += float(step["hold"]) + STEP_GAP
			"click", "mouse":
				if step.has("hold"):
					# An explicit hold spans real frames; a real cursor moved over the game during it can still contest the press — inherent to sharing one pointer, and why plain clicks don't do this.
					entries.append({"at": t, "op": "point", "step": i})
					entries.append({"at": t + POINT_TO_PRESS, "op": "press", "step": i})
					entries.append({"at": t + POINT_TO_PRESS + float(step["hold"]), "op": "release", "step": i})
					t += POINT_TO_PRESS + float(step["hold"]) + STEP_GAP
				else:
					# A plain click fires point, press, and release adjacently in ONE input flush: nothing — not even the user's parked real cursor reasserting its position — can interleave and cancel the press mid-click (the measured windowed failure warp-free clicking must survive).
					entries.append({"at": t, "op": "point", "step": i})
					entries.append({"at": t, "op": "press", "step": i})
					entries.append({"at": t, "op": "release", "step": i})
					t += STEP_GAP
			"text":
				var text := String(step["text"])
				for c in text.length():
					entries.append({"at": t + c * TYPE_CHAR_SECONDS, "op": "char", "step": i, "char": text[c]})
				t += text.length() * TYPE_CHAR_SECONDS + STEP_GAP
			"wait":
				t += float(step["seconds"])
		t += float(step.get("then_wait", 0.0))
	return {"entries": entries, "seconds": t + SETTLE_TAIL}


## Map a point in a canvas item's local space (a Control's rect, a Node2D's origin) to root-window coordinates by walking SubViewportContainer chains upward — the same transform the player's real cursor crosses in reverse, stretch_shrink included. {"ok", "pos", "window"}: ok false (with the deepest coordinates reached) when some viewport on the way up is not container-embedded — a ViewportTexture on a mesh, an off-screen viewport — where no window coordinate exists. Wild transcripts showed a game whose whole UI lives inside a SubViewportContainer (a common pixel-art shape): direct viewport pushes never fired its buttons, so every click must ride this mapping into the real input pipeline whenever one exists.
static func window_point(item: CanvasItem, local: Vector2) -> Dictionary:
	var pos := item.get_global_transform_with_canvas() * local
	var viewport := item.get_viewport()
	while viewport is SubViewport:
		var container := viewport.get_parent() as SubViewportContainer
		if container == null:
			return {"ok": false, "pos": pos, "window": null}
		var vp_size := Vector2((viewport as SubViewport).size)
		var scale := Vector2.ONE
		if vp_size.x > 0.0 and vp_size.y > 0.0:
			scale = container.size / vp_size
		pos = container.get_global_transform_with_canvas() * (pos * scale)
		viewport = container.get_viewport()
	return {"ok": viewport is Window, "pos": pos, "window": viewport as Window}


## Bounded snapshot of the live tree under `root`: one row per Control (every node with `all_nodes`), source order, capped at MAX_UI_ROWS with the overflow counted — {"rows", "dropped", "others", "matched", "searched"}. `others` counts the non-Control nodes the Controls-only default walked past, which is what lets the composer name the `all` lever in a game whose screen is sprites rather than UI. A `filter` changes what the cap is SPENT on: without one the rows are simply the first MAX_UI_ROWS in walk order, so a node deep in a big tree is unreachable without already knowing its path — the chicken-and-egg a wild session paid ~15 tool calls to escape — while with one only matches are emitted, so the budget goes to what was asked for. Engine-internal children (scrollbars, popup internals) are skipped: they are implementation detail, and their paths are not stable targets.
static func ui_snapshot(root: Node, all_nodes: bool, filter: String = "") -> Dictionary:
	var needle := filter.strip_edges().to_lower()
	var rows: Array = []
	var dropped := 0
	var others := 0
	var searched := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_front()
		# Plugin-owned overlay nodes (the agent's fake input cursor) are not part of the game; listing them would hand the model its own reflection as a target.
		if node.has_meta("gdllm_ignore"):
			continue
		var children := node.get_children()
		for c in range(children.size() - 1, -1, -1):
			stack.push_front(children[c])
		searched += 1
		# A filter searches the WHOLE tree, Control or not: most of what anyone looks for by name is a gameplay node, and answering "no rows" because the match is a CharacterBody2D would be a dead end at the exact moment the caller named what they wanted.
		var wanted := _node_matches(node, needle) if needle != "" else (node is Control or all_nodes)
		if not wanted:
			if needle == "" and not node is Control:
				others += 1
			continue
		if rows.size() < MAX_UI_ROWS:
			rows.append(_snapshot_row(node))
		else:
			dropped += 1
	return {"rows": rows, "dropped": dropped, "others": others, "matched": rows.size() + dropped, "searched": searched, "filter": filter}


## Whether one node answers to a filter: its name, its class, or the label it displays. The label is in there because the thing a UI question names is usually what the button SAYS, not what its node is called.
static func _node_matches(node: Node, needle: String) -> bool:
	if String(node.name).to_lower().contains(needle) or node.get_class().to_lower().contains(needle):
		return true
	var text: Variant = node.get("text")
	return text is String and String(text).to_lower().contains(needle)


static func _snapshot_row(node: Node) -> Dictionary:
	var row := {"path": String(node.get_path()), "class": node.get_class()}
	var text: Variant = node.get("text")
	if text is String and String(text) != "":
		row["text"] = String(text)
	if node is Control:
		var ctrl := node as Control
		# Rects are reported in WINDOW coordinates via the container-chain mapping, so they compose with mouse steps and with each other; an unmappable viewport's control keeps its local rect behind an honest flag instead.
		var origin := window_point(ctrl, Vector2.ZERO)
		var corner := window_point(ctrl, ctrl.size)
		var top_left: Vector2 = origin["pos"]
		var size: Vector2 = (corner["pos"] as Vector2) - top_left
		row["rect"] = [roundi(top_left.x), roundi(top_left.y), roundi(size.x), roundi(size.y)]
		if not bool(origin["ok"]):
			row["viewport_local"] = true
		row["visible"] = ctrl.is_visible_in_tree()
		if ctrl.has_focus():
			row["focused"] = true
		# get() is null for controls without the property, and bool() has no null constructor.
		var disabled: Variant = node.get("disabled")
		if disabled is bool and disabled:
			row["disabled"] = true
	elif node is Node2D:
		_place_2d(row, node as Node2D)
	elif node is Node3D:
		_place_3d(row, node as Node3D)
	elif node is CanvasItem:
		row["visible"] = (node as CanvasItem).is_visible_in_tree()
	return row


## Where a 2D node IS: its world position (what its own code reads and writes) and, when the chain reaches a window, the screen point a mouse step can click — the same window coordinates a Control's rect reports, so the two compose. Rotation and scale ride along only when they are not the identity, since a row per node is context the default has to earn.
static func _place_2d(row: Dictionary, node: Node2D) -> void:
	row["visible"] = node.is_visible_in_tree()
	var world := node.global_position
	row["pos"] = [snappedf(world.x, 0.01), snappedf(world.y, 0.01)]
	var mapped := window_point(node, Vector2.ZERO)
	if bool(mapped["ok"]):
		var screen: Vector2 = mapped["pos"]
		row["screen"] = [roundi(screen.x), roundi(screen.y)]
	else:
		row["viewport_local"] = true
	var rotation := node.global_rotation_degrees
	if not is_zero_approx(rotation):
		row["rot"] = snappedf(rotation, 0.1)
	var scale := node.global_scale
	if not scale.is_equal_approx(Vector2.ONE):
		row["scale"] = [snappedf(scale.x, 0.01), snappedf(scale.y, 0.01)]


## Where a 3D node IS: its world position, plus the screen point the scene's ACTIVE camera projects it to — the only way a 3D node's place on screen can be known, and marked when it falls behind the camera, where an unprojected point is a mirror image rather than a location. A camera in a sub-viewport reports viewport coordinates behind the same flag a windowless Control's rect carries.
static func _place_3d(row: Dictionary, node: Node3D) -> void:
	row["visible"] = node.is_visible_in_tree()
	var world := node.global_position
	row["pos"] = [snappedf(world.x, 0.01), snappedf(world.y, 0.01), snappedf(world.z, 0.01)]
	var rotation := node.global_rotation_degrees
	if not rotation.is_zero_approx():
		row["rot"] = [snappedf(rotation.x, 0.1), snappedf(rotation.y, 0.1), snappedf(rotation.z, 0.1)]
	var viewport := node.get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	if camera.is_position_behind(world):
		row["behind_camera"] = true
		return
	var screen := camera.unproject_position(world)
	row["screen"] = [roundi(screen.x), roundi(screen.y)]
	if not viewport is Window:
		row["viewport_local"] = true


## Compose one snapshot payload into the tool result: header with the scene, tally, and pause state, one line per row with its hidden/disabled/focused markers, the dropped count with its scoping lever, and where keyboard focus sits.
static func format_ui_snapshot(payload: Dictionary) -> String:
	var rows: Array = payload.get("rows", [])
	var all := bool(payload.get("all", false))
	var what := "node" if all else "control"
	var others := int(payload.get("others", 0))
	var dropped := int(payload.get("dropped", 0))
	var scene_note := " in scene %s%s" % [String(payload.get("scene", "?")), " — the game is PAUSED" if bool(payload.get("paused", false)) else ""]
	var focus := String(payload.get("focus", ""))
	var focus_line := "Keyboard focus: %s" % (focus if focus != "" else "none")
	var filter := String(payload.get("filter", ""))
	if filter != "":
		return _format_filtered(payload, rows, filter, dropped, scene_note, focus_line)
	# A game whose screen is sprites rather than UI has nothing to show here, and the count of what was walked past is the difference between "nothing is on screen" and "the screen is not made of Controls".
	var others_note := ""
	if not all and others > 0:
		others_note = " %d non-Control node%s under it %s not listed — pass \"all\": true to map them with their positions, or \"filter\" to find one by name or class." % [others, "" if others == 1 else "s", "is" if others == 1 else "are"]
	if rows.is_empty():
		return "The running game has no %ss under %s — the scene may still be loading, or the UI lives elsewhere in the tree.%s" % [what, String(payload.get("scope", "/root")), others_note]
	var lines: Array = []
	var head := "Live game %ss (%d shown" % [what, rows.size()]
	if dropped > 0:
		# The lever named here is what a walk of a big tree reads when it runs out of room, so it names the one that FINDS a node rather than only the one that walks less of the tree.
		head += ", %d more dropped — pass \"filter\" to find nodes by name, class or label, or \"path\" to scope deeper" % dropped
	head += ")%s:" % scene_note
	lines.append(head)
	for row: Dictionary in rows:
		lines.append(_row_line(row))
	lines.append(focus_line)
	if others_note != "":
		lines.append(others_note.strip_edges())
	return "\n".join(PackedStringArray(lines))


## The filtered snapshot's report: what matched, out of how much tree, and — when nothing did — what was actually searched, so an empty result reads as a miss rather than as an empty game.
static func _format_filtered(payload: Dictionary, rows: Array, filter: String, dropped: int, scene_note: String, focus_line: String) -> String:
	var searched := int(payload.get("searched", 0))
	var scope := String(payload.get("scope", "/root"))
	if rows.is_empty():
		return "No node under %s has \"%s\" in its name, class or label (%d node%s searched)%s. The match is a plain case-insensitive substring, so a shorter one casts wider — read_game_ui with no filter lists what is actually there." % [scope, filter, searched, "" if searched == 1 else "s", scene_note]
	var lines: Array = ["Live game nodes matching \"%s\" (%d shown of %d matched, %d node%s searched)%s:" % [filter, rows.size(), int(payload.get("matched", rows.size())), searched, "" if searched == 1 else "s", scene_note]]
	for row: Dictionary in rows:
		lines.append(_row_line(row))
	if dropped > 0:
		lines.append("(+%d more match%s — narrow the filter, or scope the walk with \"path\".)" % [dropped, "" if dropped == 1 else "es"])
	lines.append(focus_line)
	return "\n".join(PackedStringArray(lines))


static func _row_line(row: Dictionary) -> String:
	var line := "- %s [%s]" % [String(row["path"]), String(row["class"])]
	if row.has("text"):
		line += " \"%s\"" % String(row["text"])
	if row.has("rect"):
		var r: Array = row["rect"]
		line += " at (%d, %d) %dx%d" % [int(r[0]), int(r[1]), int(r[2]), int(r[3])]
	line += _place_text(row)
	if bool(row.get("viewport_local", false)):
		line += " (viewport-local coords — its viewport has no window position)"
	if row.has("visible") and not bool(row["visible"]):
		line += " (hidden)"
	if bool(row.get("disabled", false)):
		line += " (disabled)"
	if bool(row.get("focused", false)):
		line += " (focused)"
	return line


## The place clause of a gameplay node's row: where it is in the game's own world coordinates (what its script reads and writes) and where that lands on screen (what a mouse step can click) — two different numbers that a single "position" would conflate.
static func _place_text(row: Dictionary) -> String:
	if not row.has("pos"):
		return ""
	var parts: Array = []
	for value in (row["pos"] as Array):
		parts.append(str(value))
	var text := " at (%s) in world" % ", ".join(PackedStringArray(parts))
	if row.has("screen"):
		var screen: Array = row["screen"]
		text += ", screen (%d, %d)" % [int(screen[0]), int(screen[1])]
	if bool(row.get("behind_camera", false)):
		text += ", BEHIND the camera (not on screen)"
	if row.has("rot"):
		var rot: Variant = row["rot"]
		if rot is Array:
			var angles: Array = []
			for value in (rot as Array):
				angles.append(str(value))
			text += ", rotated (%s)°" % ", ".join(PackedStringArray(angles))
		else:
			text += ", rotated %s°" % str(rot)
	if row.has("scale"):
		var scale: Array = row["scale"]
		text += ", scaled (%s, %s)" % [str(scale[0]), str(scale[1])]
	return text


## Everything one live node IS, in one call: the variables its own script declares — the game's state, which is what a question about a live node almost always means, and the one thing no other tool can reach — with the engine properties left behind `all`, since those are defaults ClassDB already documents and a hundred of them buried the fifteen that mattered in the wild session this shape was rebuilt from. The script's variables are collected FIRST and against their own claim on the budget: an earlier version spent it in get_property_list order, which is engine-dominated, so on a real node (150 properties) it dropped exactly the state that was asked for. `filter` narrows by property name and reaches the engine properties too, because refusing a name the caller asked for by name would be a dead end.
static func inspect_node(node: Node, filter: String, all: bool = false) -> Dictionary:
	var needle := filter.strip_edges().to_lower()
	var include_engine := all or needle != ""
	var props := node.get_property_list()
	# A filter CONCENTRATES the report's allowance on what was asked for: narrowing to one property is the request for that property in full, and narrowing to a handful still deserves more than the per-value slice a whole-node dump has to ration. The wild case is a 40-slot inventory that every route truncated — including a filter for it, which also matched "hovered_inventory_slot" and so would defeat any "exactly one match" rule.
	var matches := _count_props(props, true, needle) + _count_props(props, false, needle)
	var cap := INSPECT_VALUE_CHARS
	if needle != "" and matches > 0:
		cap = maxi(INSPECT_VALUE_CHARS, INSPECT_TOTAL_CHARS / matches)
	# The lever is only named where it would actually buy room: a value already alone under its filter has nowhere further to go, and saying otherwise would send the caller in a circle.
	var state := {"count": 0, "spent": 0, "dropped": 0, "cap": cap, "lever": needle == "" or matches > 1}
	var script_props := _collect_props(node, props, true, needle, state)
	var engine_props: Array = []
	if include_engine:
		engine_props = _collect_props(node, props, false, needle, state)
	var script: Variant = node.get_script()
	return {
		"ok": true,
		"path": String(node.get_path()) if node.is_inside_tree() else String(node.name),
		"class": node.get_class(),
		"script": String((script as Script).resource_path) if script is Script else "",
		"children": node.get_child_count(),
		"place": _snapshot_row(node),
		"script_props": script_props,
		"engine_props": engine_props,
		"engine_total": _count_props(props, false, needle),
		"engine_listed": include_engine,
		"dropped": int(state["dropped"]),
		"filter": filter,
	}


## One pass over a node's property list, taking either its script's variables or the engine's, rendered and bounded. The budgets live in `state` so both passes share one allowance and the script's variables, going first, are never the ones it runs out on.
static func _collect_props(node: Node, props: Array, want_script: bool, needle: String, state: Dictionary) -> Array:
	var out: Array = []
	for entry: Dictionary in props:
		if not _prop_eligible(entry, want_script, needle):
			continue
		if int(state["count"]) >= MAX_INSPECT_PROPS or int(state["spent"]) >= INSPECT_TOTAL_CHARS:
			state["dropped"] = int(state["dropped"]) + 1
			continue
		var name := String(entry["name"])
		var text := value_text(node.get(name), int(state["cap"]), name if bool(state["lever"]) else "")
		state["count"] = int(state["count"]) + 1
		state["spent"] = int(state["spent"]) + text.length()
		out.append([name, text])
	return out


## How many properties of one kind a node has that an inspection could show — what lets the report count the engine properties it deliberately left out.
static func _count_props(props: Array, want_script: bool, needle: String) -> int:
	var total := 0
	for entry: Dictionary in props:
		if _prop_eligible(entry, want_script, needle):
			total += 1
	return total


## Whether one property-list entry belongs in an inspection of this kind: category and group rows are inspector headings rather than properties, an engine property has to be one the inspector would show, and a filter narrows by name.
static func _prop_eligible(entry: Dictionary, want_script: bool, needle: String) -> bool:
	var usage := int(entry.get("usage", 0))
	if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
		return false
	if bool(usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != want_script:
		return false
	if not want_script and not (usage & PROPERTY_USAGE_EDITOR):
		return false
	var name := String(entry.get("name", ""))
	if name == "":
		return false
	return needle == "" or name.to_lower().contains(needle)


## One property value as display text: sanitized to a wire-safe Variant first (so an Object never crosses as a reference), then clipped to `cap`. The allowance is deliberately generous — a state dictionary IS the answer this tool exists to give, and clipping one at a call result's length is what sent a wild session into forty per-slot calls to read what it had already been handed. A clip names the lever that undoes it (`lever_name`, the property's own name), because a truncation that says only how much it dropped is what sends a caller looking for the rest somewhere else entirely — measured: a session that hit this went hunting through the project's files for what one filtered call would have handed over.
static func value_text(value: Variant, cap: int = INSPECT_VALUE_CHARS, lever_name: String = "") -> String:
	var safe: Variant = sanitize_result(value, INSPECT_DEPTH, INSPECT_MAX_ELEMENTS)
	var text := "\"%s\"" % safe if safe is String else str(safe)
	if text.length() <= cap:
		return text
	var more := text.length() - cap
	if lever_name == "":
		return "%s… (+%d more chars)" % [text.left(cap), more]
	return "%s… (+%d more chars — pass \"filter\": \"%s\" to get this one property whole)" % [text.left(cap), more, lever_name]


## Compose one inspection into the tool result: what the node is and where it sits, its script's variables, then the engine properties, with the filter and the dropped remainder named rather than silently applied.
static func format_node_inspect(payload: Dictionary) -> String:
	var lines: Array = []
	var script := String(payload.get("script", ""))
	var head := "%s [%s]%s" % [String(payload.get("path", "?")), String(payload.get("class", "?")), " running %s" % script if script != "" else " (no script)"]
	var place: Dictionary = payload.get("place", {})
	head += _place_text(place)
	if place.has("rect"):
		var rect: Array = place["rect"]
		head += " at (%d, %d) %dx%d" % [int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3])]
	if place.has("visible") and not bool(place["visible"]):
		head += " (hidden)"
	var children := int(payload.get("children", 0))
	head += ", %d child node%s." % [children, "" if children == 1 else "s"]
	lines.append(head)
	var script_props: Array = payload.get("script_props", [])
	var engine_props: Array = payload.get("engine_props", [])
	var engine_total := int(payload.get("engine_total", 0))
	var filter := String(payload.get("filter", ""))
	if not script_props.is_empty():
		lines.append("Script variables (the game's own state):")
		for pair: Array in script_props:
			lines.append("  - %s = %s" % [String(pair[0]), String(pair[1])])
	if not engine_props.is_empty():
		lines.append("Engine properties:")
		for pair: Array in engine_props:
			lines.append("  - %s = %s" % [String(pair[0]), String(pair[1])])
	if script_props.is_empty() and engine_props.is_empty():
		if filter != "":
			return "%s\nNo property of this node has \"%s\" in its name — call it again without a filter to see everything its script declares." % [head, filter]
		if engine_total > 0:
			lines.append("This node's script declares no variables of its own, so there is no game state to report here — its %d engine propert%s are behind \"all\": true." % [engine_total, "y is" if engine_total == 1 else "ies are"])
		else:
			lines.append("This node exposes no readable properties at all, which is what a bare Node with no script looks like.")
	# Engine properties are ClassDB's documented defaults, so they are counted rather than listed until asked for — the same treatment read_game_break gives globals, and what keeps a hundred of them from burying the fifteen that carry the state.
	elif not bool(payload.get("engine_listed", false)) and engine_total > 0:
		lines.append("(+%d engine propert%s — position, collision layers, modulate and the rest — not listed; pass \"all\": true for them, or \"filter\" to reach one by name.)" % [engine_total, "y" if engine_total == 1 else "ies"])
	if int(payload.get("dropped", 0)) > 0:
		lines.append("(+%d more propert%s past this report's size budget — pass \"filter\" with part of a name to reach them.)" % [int(payload["dropped"]), "y" if int(payload["dropped"]) == 1 else "ies"])
	return "\n".join(PackedStringArray(lines))


## The refusal when a call names something the node has, but not as a method. Two near-misses are worth separating from "no such thing", both transcript-measured: a SIGNAL is the dominant one — a model reaching for a Button's "pressed", twice in one afternoon's sessions — where the generic advice to use get/set is useless, and the levers that actually fire it are emit_signal or a real click; a PROPERTY is the case that advice was written for, and naming it outright beats gesturing at it. Anything else points at inspect_game_node, which now lists what the node really holds.
static func call_target_error(path: String, node_class: String, method: String, is_signal: bool, is_property: bool, clickable: bool) -> String:
	var head := "%s (%s) has no method \"%s\"" % [path, node_class, method]
	if is_signal:
		var levers := "emit it here with method \"emit_signal\" and args [\"%s\"], which runs every handler connected to it" % method
		if clickable:
			levers += ", or press the control for real with send_game_input ({\"click\": \"%s\"}), which also gives it the hover and focus a player's click would" % path
		return "%s — \"%s\" is a SIGNAL on that node, not a method: %s." % [head, method, levers]
	if is_property:
		return "%s — \"%s\" is a PROPERTY on that node: read it with method \"get\" and args [\"%s\"], or change it with method \"set\" and args [\"%s\", <value>]." % [head, method, method, method]
	return "%s — inspect_game_node lists what this node actually holds (its script's variables and their live values), and properties are reached through get/set, e.g. method \"get\" with args [\"position\"]." % head


## Make any value safe to cross the debugger wire and land in a text result: primitives and math types pass, strings clip, arrays and dictionaries recurse behind depth and element caps, and Objects become their string description — an Object reference is meaningless in another process.
static func sanitize_result(value: Variant, depth: int = RESULT_DEPTH, max_elements: int = RESULT_MAX_ELEMENTS) -> Variant:
	if value is Object:
		# A live Node's path is the actionable handle in another process — wild transcripts showed a bare object description sending models down callv dead ends; the path feeds straight back into call_game_method.
		if value is Node and (value as Node).is_inside_tree():
			return "<%s at %s>" % [(value as Object).get_class(), (value as Node).get_path()]
		return str(value)
	if value is String:
		if String(value).length() > RESULT_MAX_CHARS:
			return "%s… (+%d more chars)" % [String(value).left(RESULT_MAX_CHARS), String(value).length() - RESULT_MAX_CHARS]
		return value
	if value is Array:
		if depth <= 0:
			return "[array of %d]" % (value as Array).size()
		var out: Array = []
		for i in mini((value as Array).size(), max_elements):
			out.append(sanitize_result(value[i], depth - 1, max_elements))
		if (value as Array).size() > max_elements:
			out.append("(+%d more elements)" % ((value as Array).size() - max_elements))
		return out
	if value is Dictionary:
		if depth <= 0:
			return "{dictionary of %d}" % (value as Dictionary).size()
		var dict := {}
		var count := 0
		for key in value:
			if count >= max_elements:
				dict["…"] = "(+%d more entries)" % ((value as Dictionary).size() - max_elements)
				break
			dict[str(key)] = sanitize_result(value[key], depth - 1, max_elements)
			count += 1
		return dict
	return value
