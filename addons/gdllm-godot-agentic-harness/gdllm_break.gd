@tool
class_name GDLLMBreak extends RefCounted
## Engine-truth access to a game paused in the debugger: what it is paused ON (a breakpoint, a breakpoint statement, a runtime error), where (the GDScript call stack), with what state (the frame's locals, members and globals), and the stepping controls. Nothing here asks the game for any of it: on every break the editor itself sends get_stack_dump, and frame 0 auto-selecting in its stack tree sends get_stack_frame_vars (ScriptEditorDebugger::_thread_debug_enter, then _msg_stack_dump's s->select(0)), so this class only records the deserialized signals those replies raise — probe-measured 48–173 ms behind the break, which is why a read settles before it answers. Execution is controlled by pressing the debugger tab's OWN Continue/Step/Next/Out buttons, never by sending "continue"/"step" over the wire: those messages must carry the breaking thread's id, which EditorDebuggerSession.send_message cannot set (it defaults to the main thread), and the buttons additionally clear the execution markers, restore the game's foreground and unmute the audio the break muted. Each button's disabled state is the engine's own verdict on what is legal here — an error break reports can_debug false and disables every step — so a refusal quotes it instead of guessing. Every method is static — this is a namespace, not an instance.

# The settle wait, report bounds (frames, variables, printed-value length), and step cap this file runs under are user-configurable — see GDLLMTunables' gdllm/tool_runtime and gdllm/tool_output sections.

## The debugger controls, keyed by the action name a tool takes: the editor theme icon that identifies the button (icon names are not localized, unlike the tooltips), how the result words what happened, whether the engine's can_debug verdict has to allow it, and whether the game must already be paused — "break" is the one press that needs the opposite, a game that is running.
const ACTIONS := {
	"break": {"icon": "Pause", "verb": "Broke into", "needs_debuggable": false, "needs_break": false},
	"continue": {"icon": "DebugContinue", "verb": "Resumed", "needs_debuggable": false, "needs_break": true},
	"step": {"icon": "DebugStep", "verb": "Stepped into", "needs_debuggable": true, "needs_break": true},
	"next": {"icon": "DebugNext", "verb": "Stepped over", "needs_debuggable": true, "needs_break": true},
	"out": {"icon": "DebugOut", "verb": "Stepped out", "needs_debuggable": true, "needs_break": true},
}

## Spellings of each action a model reaches for, mapped to the ACTIONS key. "pause" and "freeze" are deliberately absent: they read as suspend_game's between-frames freeze just as naturally as this one's stop-at-a-line, and a wrong guess between the two silently answers a different question.
const ACTION_ALIASES := {
	"break": "break", "break_now": "break", "halt": "break", "interrupt": "break", "breakpoint": "break",
	"continue": "continue", "resume": "continue", "go": "continue", "unpause": "continue", "run": "continue",
	"step": "step", "step_into": "step", "into": "step", "stepin": "step",
	"next": "next", "step_over": "next", "over": "next", "stepover": "next",
	"out": "out", "step_out": "out", "finish": "out", "return": "out",
}

## Godot callbacks that fire far too often for a breakpoint to be left armed in: how often each runs, in the words the warning uses. Measured need — every wild run of the stepping prompt armed a line inside `_physics_process`, then fought the instant re-break it causes on every continue.
const HOT_CALLBACKS := {
	"_process": "every frame",
	"_physics_process": "every physics frame",
	"_integrate_forces": "every physics frame",
	"_draw": "every time the node redraws",
	"_input": "on every input event",
	"_unhandled_input": "on every unhandled input event",
	"_unhandled_key_input": "on every unhandled key event",
	"_shortcut_input": "on every shortcut event",
	"_gui_input": "on every input event over the control",
}

## Variable groups as the game sends them (RemoteDebugger::_send_stack_vars types), in report order.
const VAR_LOCAL := 0
const VAR_MEMBER := 1
const VAR_GLOBAL := 2

## Per-debugger-panel break state keyed by the panel's instance id: {"name", "breaked", "reason", "can_debug", "has_stackdump", "frames", "vars", "expected", "selected", "at", "ended"}.
static var _states: Dictionary = {}
## Breakpoints this editor session armed, as res:// path → 1-based lines, so a report can name what it left behind rather than hoping the user notices.
static var _armed: Dictionary = {}


## Hook every debugger session panel's break signals, idempotently; called from the plugin at load and from every break entry point so a late-created session is picked up. Returns {"found", "hooked"} so a caller can tell "no debugger panel" from "this build's panel raises no break signals" — two different honest refusals.
static func ensure_connected() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"found": 0, "hooked": 0}
	var found := 0
	var hooked := 0
	for debugger in GDLLMConsole.find_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger"):
		found += 1
		if not debugger.has_signal("breaked") or not debugger.has_signal("stack_dump"):
			continue
		hooked += 1
		_connect_one(debugger, "breaked", _on_breaked)
		_connect_one(debugger, "stack_dump", _on_stack_dump)
		_connect_one(debugger, "stack_frame_vars", _on_stack_frame_vars)
		_connect_one(debugger, "stack_frame_var", _on_stack_frame_var)
		_connect_one(debugger, "stopped", _on_stopped)
	return {"found": found, "hooked": hooked}


static func _connect_one(debugger: Node, signal_name: String, handler: Callable) -> void:
	if not debugger.has_signal(signal_name):
		return
	var bound := handler.bind(debugger)
	if not debugger.is_connected(signal_name, bound):
		debugger.connect(signal_name, bound)


## A break beginning or ending. The editor raises this before the stack it then asks for arrives, so the record opens empty and fills in.
static func _on_breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool, debugger: Node) -> void:
	var state := _state(debugger)
	if reallydid:
		state["breaked"] = true
		# Each pause is its own event even when it stops at the same line as the last, and numbering them is what tells one from the next: a breakpoint in a per-frame function makes every continue land here again, rendering an identical report that the loop brake reads as a repeat that added nothing (transcript-measured — four identical continues ended a run).
		state["ordinal"] = GDLLMRepeats.bump_run("break:%d" % int(state.get("id", 0)))
		state["reason"] = reason
		state["can_debug"] = can_debug
		state["has_stackdump"] = has_stackdump
		state["frames"] = []
		state["vars"] = []
		state["expected"] = -1
		state["selected"] = 0
		state["at"] = Time.get_ticks_msec()
		state["ended"] = 0
	else:
		state["breaked"] = false


static func _on_stack_dump(frames: Array, debugger: Node) -> void:
	_state(debugger)["frames"] = frames


## The count the game promises to follow with, which is what tells a read the variables have all arrived rather than guessing a delay.
static func _on_stack_frame_vars(num_vars: int, debugger: Node) -> void:
	var state := _state(debugger)
	state["expected"] = num_vars
	state["vars"] = []


static func _on_stack_frame_var(data: Array, debugger: Node) -> void:
	(_state(debugger)["vars"] as Array).append(data)


## A run ending keeps its last break on record — post-mortem locals are still the truth about why it stopped — but stamps it so a report can label its age instead of passing it off as live. The stamp goes on whether or not the run was paused at the end: a break resumed a moment before the process died is just as historical as one it died at.
static func _on_stopped(debugger: Node) -> void:
	var state := _state(debugger)
	if int(state.get("at", 0)) > 0:
		state["ended"] = Time.get_ticks_msec()
	state["breaked"] = false
	# Numbering is per RUN: the next process starts its own count, and a stale high number would read as breaks this run never had.
	state["ordinal"] = 0
	GDLLMRepeats.reset_run()


static func _state(debugger: Node) -> Dictionary:
	var key := debugger.get_instance_id()
	if not _states.has(key):
		# The panel's own id rides the record so a control press or a frame selection can be scoped to the session that is actually paused, rather than to whichever panel is found first — a multi-instance run has several, and the others hold stale stacks.
		_states[key] = {"name": String(debugger.name), "id": key, "breaked": false, "reason": "", "can_debug": false, "has_stackdump": false, "frames": [], "vars": [], "expected": -1, "selected": 0, "at": 0, "ended": 0, "ordinal": 0}
	return _states[key]


## The recorded states whose panels still exist, stale ids dropped in passing.
static func _live_states() -> Array:
	var out: Array = []
	for key in _states.keys():
		if instance_from_id(int(key)) == null:
			_states.erase(key)
			continue
		out.append(_states[key])
	return out


## The state of the session paused right now, or {} when nothing is paused.
static func current_break() -> Dictionary:
	for state: Dictionary in _live_states():
		if bool(state["breaked"]):
			return state
	return {}


## The paused session, or failing that the newest break on record — what a post-mortem report reads.
static func last_break() -> Dictionary:
	var live := current_break()
	if not live.is_empty():
		return live
	var newest: Dictionary = {}
	for state: Dictionary in _live_states():
		if int(state["at"]) > int(newest.get("at", 0)):
			newest = state
	return newest


## Whether a break's stack and variables have all arrived: the frame list plus every variable the game promised. A break with no script stack at all (an editor-initiated pause) is complete the moment it is reported, since nothing further is coming.
static func stack_landed(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	if not bool(state.get("has_stackdump", false)):
		return true
	if (state.get("frames", []) as Array).is_empty():
		return false
	var expected := int(state.get("expected", -1))
	return expected >= 0 and (state.get("vars", []) as Array).size() >= expected


## The ACTIONS key one spelling means, or "" when it means none of them — the tolerant-key pattern the rest of the tools use for argument names, applied to an argument's value.
static func normalize_action(raw: String) -> String:
	var key := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	return String(ACTION_ALIASES.get(key, ""))


## What the game is paused on, from the reason string it sent: GDScript fills in "Breakpoint" for a gutter breakpoint, "Breakpoint Statement" for the keyword, an error message for a runtime error, and nothing at all when the editor asked for the pause (all four probe-observed).
static func classify(reason: String) -> String:
	var text := reason.strip_edges()
	if text == "":
		return "pause"
	if text.begins_with("Breakpoint Statement"):
		return "statement"
	if text.begins_with("Breakpoint"):
		return "breakpoint"
	return "error"


## One line naming what the game stopped on, in the wording the report leads with.
static func describe_reason(reason: String) -> String:
	match classify(reason):
		"pause":
			return "a pause requested from the editor"
		"statement":
			return "a breakpoint statement in the script"
		"breakpoint":
			return "a breakpoint"
	return "a runtime error: %s" % reason.strip_edges()


## The debugger panel a recorded break belongs to, or null once it is gone — what scopes a press or a frame selection to the session that is actually paused.
static func panel_for(state: Dictionary) -> Node:
	if state.is_empty() or not Engine.is_editor_hint():
		return null
	return instance_from_id(int(state.get("id", 0))) as Node


## The debugger toolbar buttons this class can press, as theme icon name → Button, matched by icon identity because the tooltips are localized. Missing entries mean the panel's layout changed and the caller must refuse by name. A `panel` scopes the search to one session's tab: in a multi-instance run every tab carries its own set, and only the paused session's buttons do anything.
static func buttons(panel: Node = null) -> Dictionary:
	var found: Dictionary = {}
	if not Engine.is_editor_hint():
		return found
	var base := EditorInterface.get_base_control()
	var wanted: Dictionary = {}
	for action in ACTIONS:
		wanted[String((ACTIONS[action] as Dictionary)["icon"])] = base.get_theme_icon(String((ACTIONS[action] as Dictionary)["icon"]), "EditorIcons")
	for debugger in _panels(panel):
		for node in GDLLMConsole.find_by_class(debugger, "Button"):
			var button := node as Button
			for icon_name in wanted:
				if button.icon == wanted[icon_name] and not found.has(icon_name):
					found[icon_name] = button
	return found


## The debugger panels to search: just the one given, or every one when no session is known to be paused.
static func _panels(panel: Node) -> Array:
	if panel != null:
		return [panel]
	if not Engine.is_editor_hint():
		return []
	return GDLLMConsole.find_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger")


## Press one stepping control the way the user's hand would. {"ok", "why"}, where a false ok names the missing piece — a layout this build changed, or a control the engine itself has disabled, which is the honest reason stepping is unavailable at an error break.
static func press(action: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "why": "there is no editor debugger here to press anything in"}
	if not ACTIONS.has(action):
		return {"ok": false, "why": "\"%s\" is not a stepping action" % action}
	var icon_name := String((ACTIONS[action] as Dictionary)["icon"])
	var found := buttons(panel_for(current_break()))
	if not found.has(icon_name):
		return {"ok": false, "why": "the debugger's %s button could not be located in this editor build — its internal layout may have changed; tell the user the debugging tools need updating for this editor version" % action.capitalize()}
	var button: Button = found[icon_name]
	if button.disabled:
		return {"ok": false, "why": "the debugger's %s button is disabled right now, so the engine does not allow that here" % action.capitalize()}
	button.emit_signal("pressed")
	return {"ok": true, "why": ""}


## Select one stack frame through the debugger's OWN stack tree, so the editor's inspector shows the frame the report describes rather than being left on another one. {"ok", "why"}.
static func select_frame(frame: int) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "why": "there is no editor here"}
	# Scoped to the paused session: another tab's stack tree still holds the rows of whatever it last broke on, and a frame index would match there just as well.
	for debugger in _panels(panel_for(current_break())):
		for node in GDLLMConsole.find_by_class(debugger, "Tree"):
			var item := frame_item(node as Tree, frame)
			if item != null:
				# The variables on record belong to the frame being left, so they are dropped rather than read as the new frame's until its reply arrives.
				var state := _state(debugger)
				state["expected"] = -1
				state["vars"] = []
				state["selected"] = frame
				item.select(0)
				return {"ok": true, "why": ""}
	return {"ok": false, "why": "frame %d is not on the debugger's stack list" % frame}


## The frame the debugger's stack tree ACTUALLY has selected, synced into the record and returned. The record's own memory only tracks selections this class made, but the user can click a frame by hand between calls — the editor then fetches THAT frame's variables, which the signal handlers duly record — so trusting the memory would caption another frame's variables with the wrong number. Falls back to the memory once the tree is gone or cleared (a stopped run), where the record is all that remains.
static func synced_selection(state: Dictionary) -> int:
	var panel := panel_for(state)
	if panel != null:
		for node in GDLLMConsole.find_by_class(panel, "Tree"):
			var item := (node as Tree).get_selected()
			if item == null:
				continue
			var meta = item.get_metadata(0)
			if meta is Dictionary and (meta as Dictionary).has("frame"):
				state["selected"] = int((meta as Dictionary)["frame"])
				break
	return int(state.get("selected", 0))


## The stack tree's item for one frame index, found by the frame dictionary the editor stamps on every row — the only fingerprint that separates this Tree from the debugger's other single-column ones.
static func frame_item(tree: Tree, frame: int) -> TreeItem:
	if tree.columns != 1:
		return null
	var root := tree.get_root()
	if root == null:
		return null
	var item := root.get_first_child()
	while item != null:
		var meta = item.get_metadata(0)
		if meta is Dictionary and (meta as Dictionary).has("frame"):
			if int((meta as Dictionary)["frame"]) == frame:
				return item
		item = item.get_next()
	return null


## The read_game_break report for a real break: what it stopped on, whether stepping is even offered, the stack, and the selected frame's state — with a stopped run's break labelled by age rather than passed off as live.
static func format_break(state: Dictionary, now_ms: int, whose: String, all: bool, filter := "") -> String:
	var lines: Array = []
	# Liveness is the record's own paused flag, never the mere existence of a record: a resumed or ended run still HAS a last break, and reporting it as "the game is PAUSED" would be a lie that also implies stepping still works.
	var live := bool(state.get("breaked", false))
	var ended := int(state.get("ended", 0))
	var head := "The game is PAUSED"
	if not live and ended > 0:
		head = "The run has since stopped; this is the last break it recorded (%s)" % _age_phrase(now_ms, ended)
	elif not live:
		head = "The game has since resumed past this break; it is the last one recorded (%s)" % _age_phrase(now_ms, int(state.get("at", now_ms)))
	var ordinal := int(state.get("ordinal", 0))
	lines.append("%s on %s%s (%s)." % [head, describe_reason(String(state.get("reason", ""))), GDLLMRepeats.run_tag("break", ordinal), whose])
	var frames: Array = state.get("frames", [])
	if not bool(state.get("has_stackdump", false)) or frames.is_empty():
		# "Run again" was wrong and contradicted set_breakpoint's own result, which correctly says a new breakpoint is live for the game already running: both wild runs that recovered from this armed a line and simply resumed.
		lines.append("There is no GDScript stack at this break — the game was between script frames, which is what a pause requested from the editor usually catches.%s" % (" Resume it with debug_game (\"continue\"). To stop INSIDE code, set_breakpoint a line in a per-frame function (the body of a _process or _physics_process, not its declaration line) — it arms the game already running, so it hits the next time that line executes, with no restart and no reloading of the save." if live else ""))
		return "\n".join(PackedStringArray(lines))
	var selected := int(state.get("selected", 0))
	if live:
		if bool(state.get("can_debug", false)):
			lines.append("Stepping is available (debug_game: step / next / out / continue).")
		else:
			lines.append("Stepping is NOT available here — the engine reports this break as not steppable, which is what a runtime error break looks like: the only move it offers is debug_game (\"continue\"), which resumes with the failed function abandoned.")
	lines.append("Stack (%d frame%s, innermost first):" % [frames.size(), "" if frames.size() == 1 else "s"])
	# A deep SELECTED frame always prints, even past the cap — its variables are the report's subject, so its file:line must appear somewhere in the result.
	var listed := 0
	var skipped := 0
	for i in frames.size():
		var frame: Dictionary = frames[i]
		var index := int(frame.get("frame", i))
		if listed >= GDLLMTunables.geti(GDLLMTunables.DEBUGGER_STACK_FRAMES_CAP) and index != selected:
			skipped += 1
			continue
		listed += 1
		lines.append("  %d: %s:%s in %s%s" % [index, String(frame.get("file", "?")), str(frame.get("line", "?")), String(frame.get("function", "?")), "   <- reported below" if index == selected else ""])
	if skipped > 0:
		lines.append("  (+%d deeper frame%s not listed — pass \"frame\": <index> to select and report one)" % [skipped, "" if skipped == 1 else "s"])
	lines.append_array(_var_lines(state.get("vars", []), selected, all, filter))
	return "\n".join(PackedStringArray(lines))


## How long ago something happened, in the wording a report uses; under a second reads as a moment rather than as "0 s ago".
static func _age_phrase(now_ms: int, then_ms: int) -> String:
	var seconds := int(float(maxi(now_ms - then_ms, 0)) / 1000.0)
	return "a moment ago" if seconds < 1 else "%d s ago" % seconds


## The selected frame's variables, grouped as the game grouped them. Globals are the project's autoloads and named globals — reachable by name from any other tool — so they are counted rather than listed unless asked for, and an object value prints as its live id, since only a node PATH is callable and that comes from read_game_ui. A `filter` is an explicit ask: it searches every group (globals included) and prints matched values WHOLE, re-concentrating the budget the caps protect — the inspect_game_node contract, and the only reader of paused state, since every other game tool refuses while paused.
static func _var_lines(vars: Array, frame: int, all: bool, filter := "") -> Array:
	var groups := {VAR_LOCAL: [], VAR_MEMBER: [], VAR_GLOBAL: []}
	for data: Array in vars:
		var kind := int(data[1]) if data.size() > 1 else -1
		if groups.has(kind):
			(groups[kind] as Array).append(data)
	if filter != "":
		return _filtered_var_lines(groups, frame, filter)
	var lines: Array = []
	var printed := 0
	var dropped := 0
	var objects := false
	for kind in [VAR_LOCAL, VAR_MEMBER]:
		var group: Array = groups[kind]
		if group.is_empty():
			continue
		lines.append("%s in frame %d:" % ["Locals" if kind == VAR_LOCAL else "Members of self", frame])
		for data: Array in group:
			if printed >= GDLLMTunables.geti(GDLLMTunables.DEBUGGER_VARIABLES_CAP):
				dropped += 1
				continue
			printed += 1
			var value: Variant = data[3] if data.size() > 3 else null
			objects = objects or _is_live_object(value)
			lines.append("  - %s = %s" % [String(data[0]), render_value(value)])
	var globals: Array = groups[VAR_GLOBAL]
	if all and not globals.is_empty():
		lines.append("Globals (autoloads and named globals):")
		for data: Array in globals:
			if printed >= GDLLMTunables.geti(GDLLMTunables.DEBUGGER_VARIABLES_CAP):
				dropped += 1
				continue
			printed += 1
			var value: Variant = data[3] if data.size() > 3 else null
			objects = objects or _is_live_object(value)
			lines.append("  - %s = %s" % [String(data[0]), render_value(value)])
	elif not globals.is_empty():
		lines.append("(%d global%s — the project's autoloads and named globals — not listed; pass all=true for them)" % [globals.size(), "" if globals.size() == 1 else "s"])
	if dropped > 0:
		lines.append("(+%d more variable%s in this frame — pass \"filter\" with part of a name to reach them, values printed whole)" % [dropped, "" if dropped == 1 else "s"])
	if lines.is_empty():
		lines.append("This frame carries no variables.")
	if objects:
		lines.append("An object value prints as its live id; call_game_method and read_game_ui address live nodes by PATH, so read_game_ui is where a usable handle comes from.")
	return lines


## The filtered report: only variables whose name contains `filter`, values whole, globals searched without `all` — an explicit name-ask must find the variable wherever it lives and never come back clipped.
static func _filtered_var_lines(groups: Dictionary, frame: int, filter: String) -> Array:
	var f := filter.to_lower()
	var lines: Array = []
	var matched := 0
	var hidden := 0
	var objects := false
	var labels := {VAR_LOCAL: "Locals", VAR_MEMBER: "Members of self", VAR_GLOBAL: "Globals"}
	for kind in [VAR_LOCAL, VAR_MEMBER, VAR_GLOBAL]:
		var header_pending := true
		for data: Array in groups[kind]:
			if not String(data[0]).to_lower().contains(f):
				hidden += 1
				continue
			if header_pending:
				lines.append("%s matching \"%s\" in frame %d:" % [labels[kind], filter, frame])
				header_pending = false
			matched += 1
			var value: Variant = data[3] if data.size() > 3 else null
			objects = objects or _is_live_object(value)
			lines.append("  - %s = %s" % [String(data[0]), render_value(value, true)])
	if matched == 0:
		return ["No variable in this frame matches \"%s\" (%d searched, globals included) — read without \"filter\" for the capped full list." % [filter, hidden]]
	if hidden > 0:
		lines.append("(%d other variable%s hidden by the filter.)" % [hidden, "" if hidden == 1 else "s"])
	if objects:
		lines.append("An object value prints as its live id; call_game_method and read_game_ui address live nodes by PATH, so read_game_ui is where a usable handle comes from.")
	return lines


static func _is_live_object(value: Variant) -> bool:
	return value is Object and (value as Object).has_method("get_object_id")


## One variable value as display text. A local holding a Node arrives as an id stub rather than the node itself (the debugger encodes objects without their contents), which is stated as an id instead of printed as if it were the object. `whole` skips the clip — the filtered path's contract.
static func render_value(value: Variant, whole := false) -> String:
	if _is_live_object(value):
		return "<live object #%d>" % int((value as Object).call("get_object_id"))
	if value is Object:
		return "<%s>" % (value as Object).get_class()
	var text := var_to_str(value)
	if not whole and text.length() > GDLLMTunables.geti(GDLLMTunables.RENDERED_VALUE_MAX_CHARS):
		return text.substr(0, GDLLMTunables.geti(GDLLMTunables.RENDERED_VALUE_MAX_CHARS)) + "… (%d chars — a \"filter\" naming this variable prints it whole)" % text.length()
	return text


## The honest report when nothing is paused: what IS true, and the levers that produce a break to look at.
static func not_paused_message(playing: bool, recorded: Dictionary, now_ms: int) -> String:
	if not playing and recorded.is_empty():
		return "Nothing is running and no break is on record, so there is nothing paused to inspect. Start a run with run_game (keep_running true leaves it up), and a runtime error will pause it on its own — set_breakpoint stops it on a line you choose."
	if not playing:
		return "%s\n\nThe run has ended, so this break cannot be stepped or resumed — those need a live game. Run again with run_game (keep_running true) to reach the same state live." % format_break(recorded, now_ms, "the run that has since ended", false)
	return "The game is running and NOT paused — nothing is stopped at a breakpoint, so there is no stack to read. read_game_ui, call_game_method and send_game_input work on a running game; to stop it and look at state, debug_game (\"break\") halts it wherever it is right now, while set_breakpoint stops it on a line you choose (a runtime error pauses it by itself) — then read this again."


## The debug_game report: the trace of where each press landed, then the state at the end — a stepping run is one tool round, so the trace is what makes it readable rather than a per-step conversation.
static func format_advance(action: String, trace: Array, state: Dictionary, whose: String, all: bool, now_ms: int, playing: bool) -> String:
	var spec: Dictionary = ACTIONS[action]
	var lines: Array = []
	if action == "break":
		if trace.is_empty():
			# The press is asynchronous — the game stops at its next script statement — so nothing landing means the game had no script left to run, not that the button was ignored.
			lines.append("The Break press was made, but %s did not stop at a script statement%s." % [whose, " before the run ended" if not playing else " — it may be idle in engine code with no GDScript running, which a breakpoint on a line that executes would catch instead"])
		else:
			lines.append("Broke into %s:" % whose)
	elif action == "continue":
		if not trace.is_empty():
			lines.append("Resumed %s — it stopped again at:" % whose)
		elif playing:
			lines.append("Resumed %s, and nothing stopped it again." % whose)
		else:
			lines.append("Resumed %s, and it ran to the end — the run is over." % whose)
	elif trace.is_empty():
		lines.append("The %s press was made, but the game %s instead of stopping again." % [action, "ran on" if playing else "ran to the end"])
	else:
		lines.append("%s%s in %s:" % [String(spec["verb"]), "" if trace.size() == 1 else " %d times" % trace.size(), whose])
	for entry: String in trace:
		lines.append("  → %s" % entry)
	if state.is_empty() or not bool(state.get("breaked", false)):
		lines.append("")
		if playing:
			lines.append("It is running now, not paused — read_output and read_errors show what it printed on the way, and read_game_break reports the next break if something stops it again.")
		else:
			lines.append("Nothing is running now — read_output and read_errors show what it printed and errored on the way down, and run_game starts another run.")
		return "\n".join(PackedStringArray(lines))
	lines.append("")
	lines.append(format_break(state, now_ms, whose, all))
	return "\n".join(PackedStringArray(lines))


## One trace line for a landed break: where it stopped, and what stopped it when that changed.
static func trace_entry(state: Dictionary) -> String:
	var ordinal := int(state.get("ordinal", 0))
	var tag := "" if ordinal <= 0 else " (break #%d)" % ordinal
	var frames: Array = state.get("frames", [])
	if frames.is_empty():
		return "paused with no script stack%s (%s)" % [tag, describe_reason(String(state.get("reason", "")))]
	var frame: Dictionary = frames[0]
	var where := "%s:%s in %s%s" % [String(frame.get("file", "?")).get_file(), str(frame.get("line", "?")), String(frame.get("function", "?")), tag]
	if classify(String(state.get("reason", ""))) == "error":
		return "%s — %s" % [where, String(state.get("reason", "")).strip_edges()]
	return where


## Open a script in the editor so its breakpoint gutter exists to toggle. This is deliberately the long way round: the editor's own set_breakpoint is not exposed to scripts, and the raw "breakpoint" debugger message would arm the GAME only — invisible in the gutter and the Breakpoints list, and dropped by the next run, since a new session is sent the EDITOR's breakpoint map. Toggling the gutter goes through CodeEdit's breakpoint_toggled signal into that map, so the user sees it, the running game gets it, and a later run gets it too. {"ok", "why"}.
static func open_script(path: String, line: int) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "why": "breakpoints are armed through the editor's script gutter, and this session is running headless"}
	var script := load(path)
	if script == null or not (script is Script):
		return {"ok": false, "why": "%s is not a script, so it has no lines to break on" % path}
	# edit_script's line is 1-based with 0 meaning keep position (probe-measured, see GDLLMLinks.open_in_editor) — line - 1 here parked the caret one line above the line being armed.
	EditorInterface.edit_script(script, maxi(line, 0))
	return {"ok": true, "why": ""}


## The CodeEdit of the script the editor is showing, and whether it is the one asked for — a mismatch means the open failed and the caller must refuse rather than arm a breakpoint in whatever file happened to be in front. {"ok", "why", "code"}.
static func code_edit_for(path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "why": "no editor here", "code": null}
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return {"ok": false, "why": "the editor's script editor could not be reached", "code": null}
	var open_script = script_editor.get_current_script()
	if open_script == null or String((open_script as Script).resource_path) != path:
		return {"ok": false, "why": "the editor did not open %s (it is showing %s), so no gutter for it could be reached" % [path, "nothing" if open_script == null else String((open_script as Script).resource_path)], "code": null}
	var current = script_editor.get_current_editor()
	if current == null or not current.has_method("get_base_editor"):
		return {"ok": false, "why": "this editor build's script editor exposes no text control to toggle a breakpoint in — tell the user the debugging tools need updating for this editor version", "code": null}
	var code := current.call("get_base_editor") as CodeEdit
	if code == null:
		return {"ok": false, "why": "the open script is not a text editor whose gutter can carry a breakpoint", "code": null}
	return {"ok": true, "why": "", "code": code}


## Toggle one line's breakpoint in the open gutter and report what that line actually holds: a blank or comment line runs no code, so a breakpoint there never fires, and a buffer that disagrees with the file on disk means the line numbers read off disk are not the lines being armed. {"ok", "why", "note", "text"}.
static func toggle_line(code: CodeEdit, line: int, enabled: bool, disk_line: String) -> Dictionary:
	var index := line - 1
	if index < 0 or index >= code.get_line_count():
		return {"ok": false, "why": "line %d is outside the script, which has %d lines" % [line, code.get_line_count()], "note": "", "text": "", "unhittable": false}
	code.set_line_as_breakpoint(index, enabled)
	if code.is_line_breakpointed(index) != enabled:
		return {"ok": false, "why": "the gutter did not take the change on line %d" % line, "note": "", "text": "", "unhittable": false}
	var text := code.get_line(index).strip_edges()
	var note := ""
	if text != disk_line.strip_edges():
		note = "the open editor's line %d reads \"%s\" while the file on disk reads \"%s\" — the script has unsaved changes, so a line number taken from read_file is not the line just armed; save the script and set it again to be certain" % [line, text, disk_line.strip_edges()]
	elif enabled and never_executes(text) != "":
		note = "line %d is %s, so execution never stops there and this breakpoint can never be hit" % [line, never_executes(text)]
		var runnable := first_executable_line(code, index)
		note += " — arm line %d instead (\"%s\")" % [runnable, code.get_line(runnable - 1).strip_edges()] if runnable > 0 else " — arm a line that actually executes"
		return {"ok": true, "why": "", "note": note, "text": text, "unhittable": true, "hot": ""}
	return {"ok": true, "why": "", "note": note, "text": text, "unhittable": false, "hot": hot_callback_note(enclosing_function(code, index)) if enabled else ""}


## What a line IS when it can never be stopped on, or "" when it holds a statement that runs. A function's signature is the case that matters: transcript-measured, two wild runs each armed `func _physics_process(...)`, waited, polled, found nothing and had to re-arm one line down — and unlike a blank or a comment it looks exactly like the code you meant. Only forms that are non-executable by the language are listed; `var` and `@onready var` are deliberately absent, since their initializers do run and warning about them would be a false claim.
static func never_executes(text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed == "":
		return "blank"
	if trimmed.begins_with("#"):
		return "a comment"
	if trimmed.begins_with("func ") or trimmed.begins_with("static func "):
		return "a function declaration"
	if trimmed.begins_with("class_name") or trimmed.begins_with("extends"):
		return "a class declaration"
	if trimmed.begins_with("signal "):
		return "a signal declaration"
	if trimmed.begins_with("enum "):
		return "an enum declaration"
	return ""


## The name of the function a line sits inside, or "" when it sits at class scope — found by walking UP to the nearest declaration, which is the only way to know what a bare line of a body belongs to.
static func enclosing_function(code: CodeEdit, index: int) -> String:
	for i in range(mini(index, code.get_line_count() - 1), -1, -1):
		var text := code.get_line(i).strip_edges()
		if text.begins_with("func ") or text.begins_with("static func "):
			var after := text.trim_prefix("static ").trim_prefix("func ")
			return after.split("(")[0].strip_edges()
	return ""


## The warning a breakpoint inside a very frequently called function earns, or "" for an ordinary one. A per-frame breakpoint re-breaks the instant execution resumes, so the game can never move or take input while it is armed — which is why watching a value change over time belongs to suspend_game, not to this tool.
static func hot_callback_note(function_name: String) -> String:
	if not HOT_CALLBACKS.has(function_name):
		return ""
	return "NOTE: %s runs %s, so the game will pause again the moment it resumes — it cannot move or take input while this is armed. Clear it before continuing if the game needs to run on, and to watch a value change over time use suspend_game (freeze, then step a frame at a time) rather than breaking repeatedly." % [function_name, String(HOT_CALLBACKS[function_name])]


## The 1-based line at or after `from_index` that a breakpoint can actually stop on, or -1 when the rest of the script holds none — what turns "this can never be hit" into the line the caller meant.
static func first_executable_line(code: CodeEdit, from_index: int) -> int:
	for index in range(from_index + 1, code.get_line_count()):
		if never_executes(code.get_line(index)) == "":
			return index + 1
	return -1


## The set_breakpoint report: what was armed or cleared, what that line holds, and the consequences of leaving it armed.
static func format_armed(path: String, line: int, enabled: bool, note: String, text: String, playing: bool, unhittable: bool = false, hot: String = "") -> String:
	var lines: Array = []
	if enabled:
		lines.append("Breakpoint armed at %s:%d — the line reads: %s" % [path, line, text if text != "" else "(blank)"])
		if hot != "":
			lines.append(hot)
		lines.append("It shows in the script's gutter and the debugger's Breakpoints list, and it is live for %s." % ("the game running now" if playing else "the next run"))
		# Promising a pause the note below then rules out is the same self-contradiction "run again" was: the armed line either can stop the game or it cannot, and only one of those sentences can be true.
		if not unhittable:
			lines.append("When the game reaches that line it PAUSES: read_game_break shows the stack and the frame's variables, debug_game steps or resumes it, and every other game tool refuses while it is paused.")
	else:
		lines.append("Breakpoint cleared at %s:%d — the game will no longer pause there." % [path, line])
	if note != "":
		lines.append("Note: %s." % note)
	return "\n".join(PackedStringArray(lines))


## Remember (or forget) a breakpoint this session armed, so a later report can name what it left behind. Pure bookkeeping over 1-based lines.
static func record_armed(path: String, line: int, enabled: bool) -> void:
	var lines: Array = _armed.get(path, [])
	if enabled:
		if not lines.has(line):
			lines.append(line)
			lines.sort()
	else:
		lines.erase(line)
	if lines.is_empty():
		_armed.erase(path)
	else:
		_armed[path] = lines


## Every breakpoint this session armed and has not removed, as [path, line] pairs in path order.
static func armed_list() -> Array:
	var out: Array = []
	for path in _armed.keys():
		for line in _armed[path]:
			out.append([String(path), int(line)])
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	return out


## The trailing note naming breakpoints this session left armed — a breakpoint outlives the editor session (it persists in .godot/editor/script_editor_cache.cfg), so a forgotten one silently freezes the user's next run.
static func armed_note() -> String:
	var armed := armed_list()
	if armed.is_empty():
		return ""
	var parts: Array = []
	for entry: Array in armed:
		parts.append("%s:%d" % [String(entry[0]).get_file(), int(entry[1])])
	return "\nBreakpoints this session armed and still active: %s — they persist across editor restarts, so clear them with set_breakpoint (\"remove\") once the question is answered." % ", ".join(PackedStringArray(parts))
