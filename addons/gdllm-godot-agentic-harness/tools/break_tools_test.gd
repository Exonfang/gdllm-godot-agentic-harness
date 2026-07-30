extends SceneTree
## Headless regression tests for the debugging tools' pure halves (GDLLMBreak): the break classification the game's own reason string carries, the settle predicate that decides a break's stack has fully arrived, the read composer (stack, the frame's variables, globals counted rather than listed, caps, live-object values, an error break's missing stepping, a break with no script stack, a post-mortem break's age), the stepping trace and its ran-on ending, the armed-breakpoint ledger and its persistence warning, the stack-tree frame fingerprint driven against a real Tree, and the refusals — headless by name for all three tools, plus each gate's own wording.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/break_tools_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const Break = preload("res://addons/gdllm-godot-agentic-harness/gdllm_break.gd")
const Repeats = preload("res://addons/gdllm-godot-agentic-harness/gdllm_repeats.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_classify()
	_test_actions()
	_test_stack_landed()
	_test_format_break()
	_test_error_break()
	_test_no_stack_and_post_mortem()
	_test_var_bounds()
	_test_not_paused()
	_test_advance()
	_test_break_action()
	_test_unhittable_lines()
	_test_rearm_and_hot_callbacks()
	_test_break_identity()
	_test_shared_repeat_tracking()
	_test_armed_ledger()
	_test_frame_item()
	_test_refusals()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## One recorded break in the shape the signal handlers build, so the composers are exercised without a live debugger.
func _state(reason: String, frames: Array, vars: Array, can_debug := true, ended := 0) -> Dictionary:
	return {"name": "Session 1", "breaked": ended == 0, "reason": reason, "can_debug": can_debug, "has_stackdump": not frames.is_empty(), "frames": frames, "vars": vars, "expected": vars.size(), "selected": 0, "at": 1000, "ended": ended}


func _frame(file: String, line: int, function: String, index: int) -> Dictionary:
	return {"frame": index, "file": file, "function": function, "line": line}


## A variable in the game's wire shape: [name, group, variant type, value, type hint].
func _var(name: String, group: int, value: Variant) -> Array:
	return [name, group, typeof(value), value, ""]


func _test_classify() -> void:
	_check(Break.classify("Breakpoint") == "breakpoint", "a gutter breakpoint's reason classifies as one")
	_check(Break.classify("Breakpoint Statement") == "statement", "the breakpoint keyword classifies apart from a gutter breakpoint")
	_check(Break.classify("") == "pause", "an empty reason is the editor's own pause")
	_check(Break.classify("Cannot call method 'get_name' on a null value.") == "error", "an error message classifies as an error break")
	_check(Break.describe_reason("Cannot call method 'get_name' on a null value.").contains("Cannot call method"), "an error break's description carries the engine's own message")
	_check(Break.describe_reason("").contains("editor"), "an editor pause is described as one")


func _test_actions() -> void:
	_check(Break.normalize_action("continue") == "continue", "the plain action names pass through")
	_check(Break.normalize_action("Step Into") == "step", "a spaced, capitalized spelling normalizes")
	_check(Break.normalize_action("over") == "next", "\"over\" means step-over")
	_check(Break.normalize_action("step-out") == "out", "a hyphenated spelling normalizes")
	_check(Break.normalize_action("rewind") == "", "an action the debugger has no button for is refused, not guessed at")
	for action in Break.ACTIONS:
		_check(Break.ACTIONS[action].has("icon") and Break.ACTIONS[action].has("verb"), "every action names the button icon it presses")


func _test_stack_landed() -> void:
	_check(not Break.stack_landed({}), "no break is not a landed break")
	var pending := _state("Breakpoint", [_frame("res://a.gd", 10, "_ready", 0)], [])
	pending["expected"] = 3
	_check(not Break.stack_landed(pending), "a break whose promised variables have not all arrived is still landing")
	pending["vars"] = [_var("x", Break.VAR_LOCAL, 1), _var("y", Break.VAR_LOCAL, 2), _var("z", Break.VAR_LOCAL, 3)]
	_check(Break.stack_landed(pending), "the count the game promised is what says the variables are all in")
	var frameless := _state("", [], [])
	_check(Break.stack_landed(frameless), "a break with no script stack is complete on arrival — nothing more is coming")


func _test_format_break() -> void:
	var frames: Array = [_frame("res://player.gd", 42, "take_damage", 0), _frame("res://enemy.gd", 88, "_attack", 1)]
	var vars: Array = [_var("amount", Break.VAR_LOCAL, 12), _var("health", Break.VAR_MEMBER, 41), _var("GameState", Break.VAR_GLOBAL, "autoload")]
	var report: String = Break.format_break(_state("Breakpoint", frames, vars), 5000, "the run this session started", false)
	_check(report.contains("PAUSED") and report.contains("a breakpoint"), "the report leads with what stopped the game")
	_check(report.contains("the run this session started"), "whose run is paused is disclosed")
	_check(report.contains("0: res://player.gd:42 in take_damage"), "the innermost frame is reported with file, line, and function")
	_check(report.contains("1: res://enemy.gd:88 in _attack"), "the caller frames follow it")
	_check(report.contains("<- reported below"), "the frame whose variables are shown is marked in the stack")
	_check(report.contains("- amount = 12"), "the frame's locals are reported")
	_check(report.contains("Members of self") and report.contains("- health = 41"), "self's members are reported apart from the locals")
	_check(report.contains("1 global") and report.contains("all=true"), "globals are counted with the flag that lists them, not dumped")
	_check(not report.contains("GameState"), "a global is not listed unless asked for")
	_check(report.contains("Stepping is available"), "a steppable break says so")
	var full: String = Break.format_break(_state("Breakpoint", frames, vars), 5000, "the user's running session", true)
	_check(full.contains("Globals") and full.contains("GameState"), "all=true lists the globals under their own heading")


func _test_error_break() -> void:
	var frames: Array = [_frame("res://error.gd", 16, "_boom", 0), _frame("res://error.gd", 9, "_ready", 1)]
	var vars: Array = [_var("victim", Break.VAR_LOCAL, null)]
	var report: String = Break.format_break(_state("Cannot call method 'get_name' on a null value.", frames, vars, false), 5000, "the run this session started", false)
	_check(report.contains("Cannot call method 'get_name' on a null value."), "the error that stopped the game is quoted, not summarized")
	_check(report.contains("Stepping is NOT available"), "a break the engine reports as not steppable says so instead of offering steps")
	_check(report.contains("continue"), "the one move an error break offers is named")
	_check(report.contains("- victim = null"), "the state at the moment of failure is reported — the whole point of reading an error break")


func _test_no_stack_and_post_mortem() -> void:
	var report: String = Break.format_break(_state("", [], []), 5000, "the user's running session", false)
	_check(report.contains("no GDScript stack"), "a break with nothing on the stack states that rather than printing an empty stack")
	_check(report.contains("set_breakpoint"), "the lever that produces a break inside code is named")
	var ended := _state("Breakpoint", [_frame("res://a.gd", 3, "_ready", 0)], [_var("x", Break.VAR_LOCAL, 1)], true, 2000)
	var stale: String = Break.format_break(ended, 9000, "the run this session started", false)
	_check(stale.contains("has since stopped") and stale.contains("7 s ago"), "a break from a run that has ended is labelled with its age, never passed off as live")
	_check(not stale.contains("is PAUSED") and not stale.contains("Stepping is available"), "a break with no live game left claims neither that the game is paused nor that it can be stepped")
	# A record whose run is still alive but has been resumed past is just as historical: reporting it as paused would also imply stepping still works.
	var resumed := _state("Breakpoint", [_frame("res://a.gd", 3, "_ready", 0)], [_var("x", Break.VAR_LOCAL, 1)])
	resumed["breaked"] = false
	var moved_on: String = Break.format_break(resumed, 4000, "the run this session started", false)
	_check(moved_on.contains("has since resumed") and moved_on.contains("3 s ago"), "a break the game has already resumed past is reported as history, with its age")
	_check(Break.format_break(resumed, 1200, "a run", false).contains("a moment ago"), "an age under a second reads as a moment, not as \"0 s ago\"")
	_check(not moved_on.contains("is PAUSED") and not moved_on.contains("Stepping is available"), "a resumed break offers no stepping either")


func _test_var_bounds() -> void:
	var many: Array = []
	for i in Break.MAX_VARS + 5:
		many.append(_var("local_%d" % i, Break.VAR_LOCAL, i))
	var report: String = Break.format_break(_state("Breakpoint", [_frame("res://a.gd", 1, "f", 0)], many), 5000, "a run", false)
	_check(report.contains("+5 more variable"), "variables past the cap are counted and pointed at the inspector")
	_check(not report.contains("local_%d" % (Break.MAX_VARS + 1)), "capped variables are not relayed")
	var deep: Array = []
	for i in Break.MAX_FRAMES + 3:
		deep.append(_frame("res://a.gd", i, "f_%d" % i, i))
	var deep_report: String = Break.format_break(_state("Breakpoint", deep, []), 5000, "a run", false)
	_check(deep_report.contains("+3 deeper frame"), "frames past the cap are counted, not dropped silently")
	_check(Break.render_value("goblin") == "\"goblin\"", "a string value prints as a string, quotes included")
	_check(Break.render_value(null) == "null", "a null local prints as null rather than as nothing")
	var long_value := "x".repeat(Break.MAX_VALUE_CHARS + 40)
	_check(Break.render_value(long_value).contains("chars — a \"filter\""), "a long value clip names its length and the filter lever")
	_check(Break.render_value(long_value, true) == var_to_str(long_value), "whole rendering skips the clip")
	_check(Break.render_value(RefCounted.new()).contains("RefCounted"), "an object with no live id prints as its class")
	var mixed := [_var("gold", Break.VAR_LOCAL, 250), _var("goblin_name", Break.VAR_LOCAL, long_value), _var("hp", Break.VAR_MEMBER, 10)]
	var ftext := "\n".join(PackedStringArray(Break._var_lines(mixed, 0, false, "gob")))
	_check(ftext.contains("goblin_name") and not ftext.contains("hp ="), "a filter picks matching variables only")
	_check(not ftext.contains("chars — a"), "a filtered value prints whole, never clipped")
	_check(ftext.contains("hidden by the filter"), "the filter counts what it hid")
	var fmiss := "\n".join(PackedStringArray(Break._var_lines(mixed, 0, false, "zzz")))
	_check(fmiss.contains("No variable in this frame matches \"zzz\""), "a filter matching nothing says so and points back at the full list")


func _test_not_paused() -> void:
	var nothing: String = Break.not_paused_message(false, {}, 5000)
	_check(nothing.contains("Nothing is running") and nothing.contains("run_game"), "with nothing running the lever is naming how to start a run")
	var running: String = Break.not_paused_message(true, {}, 5000)
	_check(running.contains("NOT paused") and running.contains("set_breakpoint"), "a running game that is not paused says so and names how to stop it")
	_check(running.contains("read_game_ui"), "the tools that DO work on a running game are named")
	var ended := _state("Breakpoint", [_frame("res://a.gd", 3, "_ready", 0)], [], true, 2000)
	var over: String = Break.not_paused_message(false, ended, 9000)
	_check(over.contains("has since stopped") and over.contains("keep_running"), "a break whose run has ended is reported with the way to reach it live again")


func _test_advance() -> void:
	var landed := _state("Breakpoint", [_frame("res://player.gd", 44, "take_damage", 0)], [_var("hp", Break.VAR_LOCAL, 3)])
	var stepped: String = Break.format_advance("next", ["player.gd:43 in take_damage", "player.gd:44 in take_damage"], landed, "the run this session started", false, 5000, true)
	_check(stepped.contains("Stepped over 2 times"), "a repeated step reports what it did and how many presses landed")
	_check(stepped.contains("→ player.gd:43") and stepped.contains("→ player.gd:44"), "each press's landing place is traced, so one call reads as a walk through the code")
	_check(stepped.contains("PAUSED") and stepped.contains("- hp = 3"), "the state where stepping ended is reported in full")
	var single: String = Break.format_advance("out", ["player.gd:80 in _process"], landed, "a run", false, 5000, true)
	_check(single.contains("Stepped out in a run:") and not single.contains("1 time"), "a single press reads as one move, not as a count of one")
	var resumed_into: String = Break.format_advance("continue", ["player.gd:60 in die"], landed, "a run", false, 5000, true)
	_check(resumed_into.contains("Resumed a run — it stopped again at:"), "a resume that hit another break says both halves: it resumed, and something stopped it again")
	var ran_on: String = Break.format_advance("continue", [], {}, "a run", false, 5000, true)
	_check(ran_on.contains("nothing stopped it again"), "a resume that hit nothing reports as a resume, not as a press that failed")
	_check(ran_on.contains("running now") and ran_on.contains("read_output"), "and it names where to look at a game that is simply running")
	var step_ran_on: String = Break.format_advance("step", [], {}, "a run", false, 5000, true)
	_check(step_ran_on.contains("ran on instead of stopping again"), "a step whose break never landed says what the game did instead")
	# A resume whose game ended is not a game "running now" — the two endings are different facts and point at different next moves.
	var ended_run: String = Break.format_advance("continue", [], {}, "a run", false, 5000, false)
	_check(ended_run.contains("ran to the end") and ended_run.contains("Nothing is running now"), "a resume that ran the game to its end says so rather than calling it running")
	_check(ended_run.contains("run_game"), "and it names how to start another run")
	_check(Break.trace_entry(_state("Cannot call method 'x' on a null value.", [_frame("res://a.gd", 7, "f", 0)], [])).contains("Cannot call method"), "a trace entry that landed on an error names the error")
	_check(Break.trace_entry(_state("", [], [])).contains("no script stack"), "a trace entry with no stack says so")


func _test_armed_ledger() -> void:
	Break._armed.clear()
	_check(Break.armed_note() == "", "an empty ledger adds no note")
	Break.record_armed("res://player.gd", 42, true)
	Break.record_armed("res://player.gd", 12, true)
	Break.record_armed("res://enemy.gd", 8, true)
	var armed: Array = Break.armed_list()
	_check(armed.size() == 3, "every armed line is remembered")
	_check(String(armed[0][0]) == "res://enemy.gd", "the list is ordered by path")
	_check(int(armed[1][1]) == 12 and int(armed[2][1]) == 42, "lines within one script are ordered")
	var note: String = Break.armed_note()
	_check(note.contains("player.gd:12") and note.contains("enemy.gd:8"), "the note names what is still armed")
	_check(note.contains("persist across editor restarts"), "the note states that a forgotten breakpoint outlives the session — the trap that freezes the user's next run")
	Break.record_armed("res://player.gd", 42, false)
	Break.record_armed("res://player.gd", 12, false)
	_check(Break.armed_list().size() == 1, "clearing a line forgets it")
	Break.record_armed("res://enemy.gd", 8, false)
	_check(Break.armed_note() == "", "an emptied ledger goes quiet again")
	var armed_report: String = Break.format_armed("res://player.gd", 42, true, "", "health -= amount", true)
	_check(armed_report.contains("res://player.gd:42") and armed_report.contains("health -= amount"), "the arming report quotes the line back so a miscounted number is visible at once")
	_check(armed_report.contains("the game running now"), "a live game is told about, not just the next run")
	_check(armed_report.contains("read_game_break") and armed_report.contains("refuses"), "the report names what happens when the line is reached, including the tools that stop working")
	var cleared: String = Break.format_armed("res://player.gd", 42, false, "", "health -= amount", false)
	_check(cleared.contains("cleared") and not cleared.contains("PAUSES"), "clearing reports as clearing")
	var noted: String = Break.format_armed("res://a.gd", 3, true, "line 3 is blank or a comment", "", false)
	_check(noted.contains("Note: line 3 is blank or a comment"), "a line that can never be hit is disclosed on the spot")


func _test_frame_item() -> void:
	var tree := Tree.new()
	tree.columns = 1
	var root := tree.create_item()
	for i in 3:
		var item := tree.create_item(root)
		item.set_metadata(0, {"frame": i, "file": "res://a.gd", "line": i + 1, "function": "f"})
	_check(Break.frame_item(tree, 2) != null, "a frame is found by the dictionary the editor stamps on its row")
	_check(Break.frame_item(tree, 7) == null, "a frame that isn't on the list is not invented")
	var other := Tree.new()
	other.columns = 2
	var other_root := other.create_item()
	other.create_item(other_root).set_metadata(0, {"frame": 0})
	_check(Break.frame_item(other, 0) == null, "another of the debugger's trees is not mistaken for the stack list")
	tree.free()
	other.free()
	# A press and a frame selection are scoped by the paused panel's own id, so a multi-instance run cannot drive the wrong session's tab or match a frame in its stale stack.
	_check(Break.panel_for({}) == null, "no break means no panel to scope a press to")
	_check(Break.panel_for({"id": 424242}) == null, "a panel that no longer exists resolves to nothing rather than to some other tab")
	# The default read follows the tree's real selection; with no tree left (headless, or a stopped run) the record's own memory is the fallback.
	_check(Break.synced_selection({"selected": 2}) == 2, "with no panel to read, the recorded selection stands")
	_check(Break.synced_selection({}) == 0, "an empty record falls back to frame 0")


func _test_refusals() -> void:
	var hook: Dictionary = Break.ensure_connected()
	_check(int(hook["found"]) == 0, "headless finds no debugger panels to hook")
	_check(Break.buttons().is_empty(), "headless finds no debugger buttons")
	var pressed: Dictionary = Break.press("continue")
	_check(not bool(pressed["ok"]) and String(pressed["why"]).contains("no editor"), "pressing a control headless refuses by name rather than inventing a layout problem")
	var selected: Dictionary = Break.select_frame(1)
	_check(not bool(selected["ok"]), "selecting a frame headless refuses")
	var opened: Dictionary = Break.open_script("res://addons/gdllm-godot-agentic-harness/gdllm_break.gd", 3)
	_check(not bool(opened["ok"]) and String(opened["why"]).contains("headless"), "arming a breakpoint headless refuses by name")
	for tool_name in ["read_game_break", "debug_game", "set_breakpoint"]:
		var args: Dictionary = {"action": "continue"} if tool_name == "debug_game" else {}
		var result: Dictionary = await Tools.execute(tool_name, args, true, true)
		_check(String(result["content"]).begins_with("Error:") and String(result["content"]).contains("headless"), "%s refuses by name in a headless run" % tool_name)
	var bogus: Dictionary = await Tools.execute("read_game_break", {"bogus": 1}, true, true)
	_check(String(bogus["content"]).begins_with("Error:") and String(bogus["content"]).contains("frame"), "an unrecognized argument comes back with the usage shape")
	# An unrecognized argument NAME is answered before the environment is judged (as in the other game tools), but an unrecognized action VALUE is checked after, so the headless refusal wins here and the usage line is what carries the actions.
	_check(Tools.DEBUG_GAME_USAGE.contains("continue") and Tools.DEBUG_GAME_USAGE.contains("out"), "the usage line an unknown action is answered with names the actions that exist")
	var gated_step: Dictionary = await Tools.execute("debug_game", {"action": "continue"}, false, false)
	_check(String(gated_step["content"]).contains("runs the project's own code"), "debug_game's gate refusal says it runs code, since stepping resumes the project's own code")
	var gated_point: Dictionary = await Tools.execute("set_breakpoint", {"path": "res://a.gd", "line": 3}, false, false)
	_check(String(gated_point["content"]).contains("where the project's code halts"), "set_breakpoint's gate refusal describes halting, not running or modifying — neither of which it does")
	var catalog := String(Tools.tool_search_schema(false)["function"]["description"])
	_check(catalog.contains("read_game_break"), "reading a paused game is a read tool, listed even with Make changes off")
	_check(not catalog.contains("debug_game"), "the stepping tool is not offered while Make changes is off")


## The "break" action: the one debugger control whose precondition is a RUNNING game, and whose spellings must not collide with suspend_game's between-frames freeze.
func _test_break_action() -> void:
	_check(Break.normalize_action("break") == "break" and Break.normalize_action("halt") == "break", "break spellings resolve to the break action")
	_check(Break.normalize_action("pause") == "" and Break.normalize_action("freeze") == "", "pause and freeze are NOT debug_game actions — they read as suspend_game's freeze, and a wrong guess answers a different question")
	_check(String(Break.ACTIONS["break"]["icon"]) == "Pause", "the break action is identified by the debugger's own Pause icon")
	_check(not bool(Break.ACTIONS["break"]["needs_break"]), "break is the one action that does not need a game already paused")
	for action in ["continue", "step", "next", "out"]:
		_check(bool(Break.ACTIONS[action]["needs_break"]), "%s needs a paused game" % action)
	var landed := Break.format_advance("break", ["player.gd:12 in _process"], _state("", [{"file": "res://player.gd", "line": 12, "function": "_process"}], []), "the run this session started", false, 1000, true)
	_check(landed.contains("Broke into") and landed.contains("player.gd:12"), "a landed break names where it caught the game")
	_check(landed.contains("PAUSED"), "a landed break reports the state it left the game in")
	var missed := Break.format_advance("break", [], {}, "the run this session started", false, 1000, true)
	_check(missed.contains("did not stop") and missed.contains("breakpoint on a line"), "a break that never landed says so and names the lever that would catch it")
	var ended := Break.format_advance("break", [], {}, "the run this session started", false, 1000, false)
	_check(ended.contains("before the run ended"), "a break press on a run that ended attributes it to the ending")
	_check(Break.not_paused_message(true, {}, 1000).contains("debug_game (\"break\")"), "the not-paused report offers breaking into the running game")


## Breakpoints on lines that can never be hit. Transcript-measured: two wild runs each armed `func _physics_process(...)` — the declaration, not the body — waited, polled read_game_break, found nothing, and re-armed one line down. A blank or a comment was already caught; a function signature looks exactly like the code you meant, so it sailed through with a confident "armed".
func _test_unhittable_lines() -> void:
	_check(Break.never_executes("func _process(delta: float) -> void:") == "a function declaration", "a function signature is named as unhittable")
	_check(Break.never_executes("\tstatic func helper() -> int:") == "a function declaration", "an indented static func too")
	_check(Break.never_executes("extends Node2D") == "a class declaration" and Break.never_executes("class_name Player extends Node") == "a class declaration", "class declarations are unhittable")
	_check(Break.never_executes("signal died(who)") == "a signal declaration" and Break.never_executes("enum State { IDLE, RUN }") == "an enum declaration", "signal and enum declarations are unhittable")
	_check(Break.never_executes("") == "blank" and Break.never_executes("  # a note") == "a comment", "the cases already caught still are")
	# Deliberately NOT flagged: these initializers really do run, and warning about them would be a false claim.
	_check(Break.never_executes("var speed := 90.0") == "", "a var initializer executes and is not flagged")
	_check(Break.never_executes("@onready var hud := $HUD") == "", "an @onready initializer executes and is not flagged")
	_check(Break.never_executes("\tposition.x += 1.0") == "" and Break.never_executes("\telse:") == "", "ordinary statements are hittable")
	var code := CodeEdit.new()
	code.text = "extends Node2D\n\n\nfunc _process(delta: float) -> void:\n\t# advance\n\tposition.x += 1.0\n"
	_check(Break.first_executable_line(code, 3) == 6, "the first runnable line after a func declaration skips its comment and finds the statement")
	var armed: Dictionary = Break.toggle_line(code, 4, true, "func _process(delta: float) -> void:")
	_check(bool(armed["ok"]) and String(armed["note"]).contains("function declaration"), "arming a func line reports why it can never be hit")
	_check(String(armed["note"]).contains("line 6") and String(armed["note"]).contains("position.x"), "and names the exact line to arm instead, quoting it")
	_check(bool(armed.get("unhittable", false)), "the toggle reports the line as unhittable so the report can stop promising a pause")
	var unhittable_report := Break.format_armed("res://p.gd", 4, true, String(armed["note"]), "func _process(delta: float) -> void:", true, true, "")
	_check(not unhittable_report.contains("it PAUSES"), "an unhittable line's report does not promise a pause its own note rules out")
	_check(unhittable_report.contains("arm line 6"), "while still naming the line that would work")
	_check(Break.format_armed("res://p.gd", 6, true, "", "position.x += 1.0", true, false, "").contains("it PAUSES"), "a hittable line still explains what happens when it is reached")
	var fine: Dictionary = Break.toggle_line(code, 6, true, "position.x += 1.0")
	_check(bool(fine["ok"]) and String(fine["note"]) == "", "arming a real statement earns no note")
	code.queue_free()
	# The advice a stackless break gives: set_breakpoint arms the game ALREADY running, so "run again" was both wrong and expensive after a save has been loaded.
	var stackless := Break.format_break(_state("", [], []), 1000, "the run", false)
	_check(stackless.contains("no GDScript stack"), "a stackless break is still stated as one")
	_check(not stackless.contains("run again"), "the stale restart advice is gone")
	_check(stackless.contains("_physics_process") and stackless.contains("not its declaration line"), "and it names a per-frame body as the target, warning off the declaration line")


## The breakpoint workflow that ended three wild runs in a loop-brake redirect: a per-frame line has to be cleared to let the game move and re-armed to catch the next hit, and every re-arm rendered identically — four such repeats end the turn.
func _test_rearm_and_hot_callbacks() -> void:
	# The re-arm numbering that used to live here is now the shared per-turn tag (see GDLLMRepeats), applied to every tool whose identical call does the work again.
	# Every wild run armed inside _physics_process and then fought the instant re-break on each continue.
	_check(Break.hot_callback_note("_physics_process").contains("every physics frame"), "a per-frame callback is named with how often it runs")
	_check(Break.hot_callback_note("_physics_process").contains("suspend_game"), "and points at the tool that actually watches a value over time")
	_check(Break.hot_callback_note("_process").contains("cannot move or take input"), "the consequence is stated, not just the frequency")
	_check(Break.hot_callback_note("_input").contains("every input event"), "input callbacks are covered with their own cadence")
	_check(Break.hot_callback_note("take_damage") == "", "an ordinary function earns no warning")
	var code := CodeEdit.new()
	code.text = "extends Node2D\n\n\nfunc _physics_process(delta: float) -> void:\n\tvar motion := Vector2.ZERO\n\tset_velocity(motion)\n\n\nfunc take_damage(n: int) -> void:\n\thealth -= n\n"
	_check(Break.enclosing_function(code, 5) == "_physics_process", "a line's enclosing function is found by walking up to its declaration")
	_check(Break.enclosing_function(code, 9) == "take_damage", "and the nearest one wins, not the first in the file")
	_check(Break.enclosing_function(code, 0) == "", "a line at class scope belongs to no function")
	var armed: Dictionary = Break.toggle_line(code, 6, true, "set_velocity(motion)")
	_check(String(armed.get("hot", "")).contains("every physics frame"), "arming inside a per-frame body carries the warning out of toggle_line")
	var cold: Dictionary = Break.toggle_line(code, 10, true, "health -= n")
	_check(String(cold.get("hot", "")) == "", "arming inside an ordinary function does not")
	_check(Break.format_armed("res://p.gd", 6, true, "", "set_velocity(motion)", true, false, Break.hot_callback_note("_physics_process")).contains("pause again the moment it resumes"), "the warning reaches the composed report")
	code.queue_free()


## Each pause is its own event, and numbering them is what tells one from the next. A breakpoint in a per-frame function makes every continue land at the same line, so an unnumbered report renders identically — four such continues ended a wild run on the loop brake.
func _test_break_identity() -> void:
	var frame := [{"file": "res://player.gd", "line": 501, "function": "_physics_process"}]
	var eighth := _state("Breakpoint", frame, [])
	eighth["ordinal"] = 8
	var ninth := _state("Breakpoint", frame, [])
	ninth["ordinal"] = 9
	_check(Break.trace_entry(eighth) != Break.trace_entry(ninth), "two breaks at the SAME line render differently, so repeated continues are not read as a no-op loop")
	_check(Break.trace_entry(eighth).contains("break #8"), "the trace names which break it landed on")
	# Reading the SAME break twice is genuinely no new information, and must still render identically so the brake keeps catching it.
	_check(Break.trace_entry(eighth) == Break.trace_entry(eighth), "the same break renders identically, so a pointless re-read is still caught")
	_check(Break.format_break(eighth, 1000, "the run", false).contains("break #8 of this run"), "the read report carries the same identity")
	var stackless := _state("", [], [])
	stackless["ordinal"] = 3
	_check(Break.trace_entry(stackless).contains("break #3"), "a stackless break is numbered too, since it is just as much an event")
	var unnumbered := _state("Breakpoint", frame, [])
	_check(not Break.trace_entry(unnumbered).contains("break #"), "a record with no ordinal claims no number it does not have")


## The shared half of the honesty rule: four tools were caught by the duplicate brake for rendering identically after doing real work, so the counting lives in one place (GDLLMRepeats) and a tool opts in by joining one list.
func _test_shared_repeat_tracking() -> void:
	Repeats.reset_turn()
	var sig := Repeats.signature("suspend_game", {"action": "on"})
	_check(Repeats.turn_tag(Repeats.bump_turn(sig)) == "", "a first call carries no tag it has not earned")
	var second := Repeats.turn_tag(Repeats.bump_turn(sig))
	_check(second.contains("#2") and second.contains("did the work again"), "the second identical call says the work happened again, in the brake's own terms")
	_check(Repeats.turn_tag(Repeats.bump_turn(sig)).contains("#3"), "and keeps counting")
	_check(Repeats.signature("a", {"x": 1}) != Repeats.signature("a", {"x": 2}), "different arguments are different calls, as the brake also keys them")
	Repeats.reset_turn()
	_check(Repeats.turn_tag(Repeats.bump_turn(sig)) == "", "a new turn starts the count over, in step with the brake's own ledger")
	# Run-scoped events are the engine's, not the model's: a break is numbered although no tool call produced it.
	Repeats.reset_run()
	_check(Repeats.run_tag("break", Repeats.bump_run("break:1")).contains("break #1 of this run"), "an engine event is numbered within its run")
	_check(Repeats.bump_run("break:1") == 2 and Repeats.count_run("break:1") == 2, "the run counter keeps its own tally")
	Repeats.reset_run()
	_check(Repeats.count_run("break:1") == 0, "and a new run starts from one again")
	_check(Repeats.run_tag("break", 0) == "", "an uncounted event claims no number")
	# Owner scoping: a subagent run's identical call is ITS first, not the chat's second — counts and resets are per-owner like the brake ledgers they mirror.
	Repeats.reset_turn("chat")
	Repeats.reset_turn("run")
	Repeats.bump_turn(sig, "chat")
	Repeats.bump_turn(sig, "chat")
	_check(Repeats.bump_turn(sig, "run") == 1, "another owner's identical call starts at one, never inheriting the chat's count")
	_check(Repeats.bump_turn(sig, "chat") == 3, "while the chat's own tally keeps counting")
	Repeats.reset_turn("chat")
	_check(Repeats.bump_turn(sig, "run") == 2, "resetting one owner leaves the other's tally standing")
	_check(Repeats.bump_turn(sig, "chat") == 1, "and the reset owner starts over")
	Repeats.reset_turn("chat")
	Repeats.reset_turn("run")
	for name in ["suspend_game", "set_breakpoint", "send_game_input", "reload_game_scripts", "debug_game", "run_script", "set_import_setting"]:
		_check(Tools.REPEAT_REAL_WORK_TOOLS.has(name), "%s is registered as doing real work on an identical call" % name)
	_check(not Tools.REPEAT_REAL_WORK_TOOLS.has("read_game_ui"), "a pure read is NOT registered — an identical one really does add nothing, and the brake should still catch it")
