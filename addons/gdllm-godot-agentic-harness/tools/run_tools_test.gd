extends SceneTree
## Headless regression tests for the run tools' pure halves and headless behavior: the Output/Errors run-capture deltas (GDLLMConsole), the capture and script-run report composers (GDLLMTools), the Make-changes gate with its runs-code wording, the headless refusals of the editor-bound game tools, and run_script end to end against real engine subprocesses — a clean fixture run and a killed-at-timeout one.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/run_tools_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Console = preload("res://addons/gdllm-godot-agentic-harness/gdllm_console.gd")
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

const RUN_FIXTURE := "res://addons/gdllm-godot-agentic-harness/tools/run_fixture.gd"
const SPIN_FIXTURE := "res://addons/gdllm-godot-agentic-harness/tools/run_spin_fixture.gd"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_lines_delta()
	_test_entries_delta()
	_test_tail_lines()
	_test_run_capture_format()
	_test_script_run_format()
	_test_gate_and_catalog()
	_test_run_overlays()
	_test_reload_arming()
	_test_no_run_refusals()
	_test_reload_report()
	_test_headless_refusals()
	_test_run_script_end_to_end()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_lines_delta() -> void:
	var lines := Console.output_lines("a\nb\nc\n\n")
	_check(lines == ["a", "b", "c"], "output_lines trims trailing blanks and keeps order")
	var grown := Console.lines_delta(2, "b", ["a", "b", "c", "d"])
	_check(grown["lines"] == ["c", "d"] and not bool(grown["reset"]), "growth past the baseline yields exactly the new lines")
	var boundary := Console.lines_delta(2, "b", ["a", "b (x3)", "c"])
	_check(boundary["lines"] == ["b (x3)", "c"], "a changed boundary line (collapse-duplicates counter) rejoins the delta")
	var cleared := Console.lines_delta(5, "e", ["fresh"])
	_check(cleared["lines"] == ["fresh"] and bool(cleared["reset"]), "fewer lines than the baseline reads as a cleared panel, everything counted new")
	var same := Console.lines_delta(2, "b", ["a", "b"])
	_check((same["lines"] as Array).is_empty() and not bool(same["reset"]), "an unchanged panel yields an empty delta, not a reset")


func _test_entries_delta() -> void:
	var entries: Array = [{"kind": "error"}, {"kind": "warning"}, {"kind": "error"}]
	var grown := Console.entries_delta(entries, 1)
	_check((grown["entries"] as Array).size() == 2 and not bool(grown["reset"]), "entries past the baseline are the delta")
	var cleared := Console.entries_delta(entries, 5)
	_check((cleared["entries"] as Array).size() == 3 and bool(cleared["reset"]), "a shrunken list reads as cleared, everything counted new")


func _test_tail_lines() -> void:
	var tail := Console.tail_lines(["a", "b", "c", "d"], 2)
	_check(String(tail["text"]) == "c\nd" and int(tail["omitted"]) == 2, "the tail keeps the newest lines and counts the omitted")
	var long_line := "y".repeat(GDLLMTunables.geti(GDLLMTunables.CONSOLE_LINE_MAX_CHARS) + 9)
	var clipped := Console.tail_lines([long_line], 5)
	_check(String(clipped["text"]).contains("(+9 more chars)"), "a runaway line is clipped with the elided count")


func _test_run_capture_format() -> void:
	var missing: String = Tools.format_run_capture({"lines": [], "reset": false, "missing": true}, [], "")
	_check(missing.contains("could not be read") and missing.contains("read_output"), "an unreadable Output panel is stated, never passed off as silence")
	var quiet: String = Tools.format_run_capture({"lines": [], "reset": false, "missing": false}, [{"session": "Session 1", "entries": [], "reset": false}], "")
	_check(quiet.contains("printed nothing new"), "a silent run says so")
	_check(quiet.contains("No new errors or warnings"), "a clean run states the absence of new errors")
	var big: Array = []
	for i in GDLLMTunables.geti(GDLLMTunables.CONSOLE_OUTPUT_LINES) + 5:
		big.append("line %d" % i)
	var capped: String = Tools.format_run_capture({"lines": big, "reset": true, "missing": false}, [], "\n\nNote: hidden things")
	_check(capped.contains("(%d lines, newest %d shown" % [big.size(), GDLLMTunables.geti(GDLLMTunables.CONSOLE_OUTPUT_LINES)]), "a chatty run is capped with the count and the read_output remedy")
	_check(capped.contains("read_output has the full console"), "the cap names where the rest lives")
	_check(capped.contains("cleared as the run started"), "a cleared-on-play panel is disclosed on the capture")
	_check(capped.contains("Note: hidden things"), "the panel's view-controls rider rides the capture")
	_check(capped.contains("could not be read for this run"), "unreadable error trees are stated too")
	var errs: Array = [
		{"session": "Session 1", "entries": [{"kind": "error", "time": "0:01", "title": "boom", "detail": []}], "reset": false},
		{"session": "Session 2", "entries": [{"kind": "warning", "time": "0:02", "title": "creaky", "detail": []}], "reset": true},
	]
	var errored: String = Tools.format_run_capture({"lines": ["x"], "reset": false, "missing": false}, errs, "")
	_check(errored.contains("2 new debugger entries during the run (1 errors, 1 warnings"), "new entries are tallied by kind")
	_check(errored.contains("Session 1:") and errored.contains("Session 2:"), "multiple debugger sessions are named per entry")
	_check(errored.contains("Errors tab was cleared during the run"), "a cleared Errors tab is disclosed rather than silently recounted")


func _test_script_run_format() -> void:
	var killed: String = Tools.format_script_run("res://x.gd", {"ok": false, "why": "hung", "output": "tick\n", "exit_code": -1, "killed": true}, 7)
	_check(killed.begins_with("Error:") and killed.contains("7 s timeout") and killed.contains("quit()"), "a timeout kill names the timeout and the quit() remedy")
	_check(killed.contains("timeout_seconds (up to %d)" % GDLLMTunables.geti(GDLLMTunables.RUN_SCRIPT_MAX_TIMEOUT)), "the kill names the raisable cap")
	_check(killed.contains("tick"), "output up to the kill is still relayed")
	var dead: String = Tools.format_script_run("res://x.gd", {"ok": false, "why": "failed to launch", "output": "", "exit_code": -1, "killed": false}, 30)
	_check(dead.contains("NOT executed"), "a run that never happened is never passed off as one that did")
	var clean: String = Tools.format_script_run("res://x.gd", {"ok": true, "why": "", "output": "Godot Engine v4.7\nhello\n", "exit_code": 0, "killed": false}, 30)
	_check(clean.contains("exit code 0") and clean.contains("hello"), "a clean run relays exit code and output")
	_check(not clean.contains("Godot Engine v"), "the engine banner is stripped as boot noise")
	var failed: String = Tools.format_script_run("res://x.gd", {"ok": true, "why": "", "output": "", "exit_code": 2, "killed": false}, 30)
	_check(failed.contains("nonzero") and failed.contains("printed nothing"), "a nonzero exit names the failure convention and an empty output is stated")
	var wrong_base: String = Tools.format_script_run("res://x.gd", {"ok": true, "why": "", "output": "Script does not inherit from SceneTree or MainLoop\n", "exit_code": 1, "killed": false}, 30)
	_check(wrong_base.contains("extends SceneTree"), "the engine's wrong-base refusal is translated into the fix")
	var big: Array = []
	for i in GDLLMTunables.geti(GDLLMTunables.RUN_SCRIPT_OUTPUT_LINES) + 3:
		big.append("row %d" % i)
	var capped: String = Tools.format_script_run("res://x.gd", {"ok": true, "why": "", "output": "\n".join(big), "exit_code": 0, "killed": false}, 30)
	_check(capped.contains("only a re-run can reprint it"), "a capped subprocess tail admits the drop is unrecoverable")


func _test_gate_and_catalog() -> void:
	for name: String in ["run_game", "stop_game", "run_script"]:
		_check(Tools.is_mutating(name), "%s rides the mutating gate" % name)
		var refused: Dictionary = await Tools.execute(name, {})
		_check(String(refused["content"]).contains("runs the project's own code") and String(refused["content"]).contains("Make changes"), "%s's gate refusal says it runs code, not that it edits files" % name)
	var closed := String(Tools.tool_search_schema(false)["function"]["description"])
	_check(not closed.contains("run_game"), "the catalog hides the run tools while Make changes is off")
	_check(closed.contains("or run its code"), "the catalog's hidden-tools line admits running is gated too")
	var open := String(Tools.tool_search_schema(true)["function"]["description"])
	_check(open.contains("run_game") and open.contains("run_script"), "the catalog lists the run tools once the gate is open")
	_check(Tools.search("run_game", false, false).is_empty(), "search can't activate a gated run tool")
	_check(not Tools.search("run_game", true, false).is_empty(), "search finds run_game with the gate open")


func _test_headless_refusals() -> void:
	var game: Dictionary = await Tools.execute("run_game", {}, true)
	_check(String(game["content"]).begins_with("Error:") and String(game["content"]).contains("headless"), "run_game refuses by name in a headless run")
	_check(String(game["content"]).contains("run_script"), "the refusal points at the run that still works headlessly")
	var stop: Dictionary = await Tools.execute("stop_game", {}, true)
	_check(String(stop["content"]).contains("headless"), "stop_game refuses by name in a headless run")
	var pathless: Dictionary = await Tools.execute("run_script", {}, true)
	_check(String(pathless["content"]).contains("\"path\""), "a pathless run_script call carries the usage shape")
	var not_script: Dictionary = await Tools.execute("run_script", {"path": "project.godot"}, true)
	_check(String(not_script["content"]).contains("not a GDScript file"), "run_script refuses non-.gd targets")


func _test_run_script_end_to_end() -> void:
	var clean: Dictionary = await Tools.execute("run_script", {"path": RUN_FIXTURE, "args": ["hello", "world"]}, true)
	var content := String(clean["content"])
	_check(content.contains("GDLLM_RUN_FIXTURE hello world"), "the fixture really executed and saw its args")
	_check(content.contains("exit code 0"), "the clean fixture's exit code is relayed")
	var spun: Dictionary = await Tools.execute("run_script", {"path": SPIN_FIXTURE, "timeout_seconds": 1}, true)
	_check(String(spun["content"]).begins_with("Error:") and String(spun["content"]).contains("killed"), "a never-quitting script is killed at the timeout and reported as killed")


## run_game's debug overlays: the Debug-menu run flags, normalized from the names a model reaches for, with an unknown one refused rather than silently drawing nothing.
func _test_run_overlays() -> void:
	var none: Dictionary = Tools._run_overlays({})
	_check(bool(none["ok"]) and (none["names"] as Array).is_empty(), "a run without the argument asks for no overlays")
	var pair: Dictionary = Tools._run_overlays({"show": ["collisions", "nav"]})
	_check(bool(pair["ok"]) and (pair["names"] as Array) == ["collisions", "navigation"], "overlay names normalize through their aliases")
	var single: Dictionary = Tools._run_overlays({"show": "collision_shapes"})
	_check(bool(single["ok"]) and (single["names"] as Array) == ["collisions"], "a bare string overlay is taken as a one-item list")
	var repeated: Dictionary = Tools._run_overlays({"debug_draw": ["paths", "path"]})
	_check((repeated["names"] as Array).size() == 1, "an overlay named twice is set once")
	var unknown: Dictionary = Tools._run_overlays({"show": ["wireframe"]})
	_check(not bool(unknown["ok"]) and String(unknown["why"]).contains("wireframe") and String(unknown["why"]).contains("collisions"), "an unknown overlay is refused naming it and the five that exist")
	var note := Tools._run_options_note(["collisions"], true)
	_check(note.contains("collision shapes") and note.contains("unchanged"), "the result names what was drawn and that the user's own menu was left alone")
	_check(note.contains("reload_game_scripts"), "a run still up says its scripts can be hot-reloaded")
	_check(not Tools._run_options_note([], false).contains("reload_game_scripts"), "a run already stopped is not offered a reload it cannot take")
	_check(Tools._run_options_note([], true).contains("Hot reload"), "hot reload is disclosed even when no overlay was asked for")
	for name in Tools.RUN_DEBUG_OPTIONS:
		_check(Tools.RUN_OVERLAY_LABELS.has(name), "every overlay has a label for the result: %s" % name)


## reload_game_scripts' arming: a reload pushed into a run that was not launched for it silently fails to apply, so an unarmed run is refused rather than left reasoning from a change that never landed; and a run this session never started has no launch time to measure "changed since" against.
func _test_reload_arming() -> void:
	var armed: Dictionary = Tools._reload_armed()
	_check(not bool(armed["ok"]), "with no run of this session's own and no Debug-menu flags, a reload is refused")
	_check(String(armed["why"]).contains("Synchronize Script Changes") and String(armed["why"]).contains("run_game"), "the refusal names the user's own checkboxes and the run_game alternative")
	_check(String(armed["why"]).contains("silently"), "the refusal states the real consequence rather than sounding procedural")
	var no_launch: Dictionary = Tools._reload_paths({})
	_check(not bool(no_launch["ok"]) and String(no_launch["why"]).contains("\"paths\""), "with no run start to measure against, the changed-since default names the explicit argument")
	var missing: Dictionary = Tools._reload_paths({"paths": ["res://definitely_not_here.gd"]})
	_check(not bool(missing["ok"]), "a path that resolves to nothing is refused")
	var wrong_kind: Dictionary = Tools._reload_paths({"paths": ["res://project.godot"]})
	_check(not bool(wrong_kind["ok"]) and String(wrong_kind["why"]).contains("run_game"), "a non-script is refused and pointed at a fresh run")
	_check(Tools.RUN_RELOAD_OPTIONS.size() == 2, "both launch flags are required — either alone breaks the reload")


## The reload report: what it can honestly claim. Two wild runs both ended on "the run printed nothing new to the Output console" — which is exactly what a reload that never applied looks like, since the game keeps running and printing as before — so the report names the one check that does prove it and offers the console as evidence of nothing.
func _test_reload_report() -> void:
	var plain := Tools.format_reload_report(["res://player.gd"], "the run this session started", "", [])
	_check(plain.contains("call a changed method") and plain.contains("call_game_method"), "the report names a check that exercises CODE, which is what a reload actually replaces")
	_check(plain.contains("Nothing in the console proves it"), "console silence is disclaimed rather than left to read as success")
	# Measured: after a good reload a changed `var health := 123` still read 77 while a changed method body returned its new value.
	_check(plain.contains("replaces code, not state"), "the report warns that already-initialized variables keep their values, so a working reload is not misread as broken")
	_check(plain.contains("set it with call_game_method"), "and names how to change a live value now")
	_check(not plain.contains("class_name") and not plain.contains("autoload"), "a plain script carries no caveats it does not earn")
	_check(plain.contains("res://player.gd"), "the report lists what was pushed")
	var caveated := Tools.format_reload_report(["res://globals/game.gd"], "the run", "", ["game.gd is an autoload, whose singleton keeps the instance it already built"])
	_check(caveated.contains("CODE only") and caveated.contains("autoload"), "a caveat that applies is stated with the file it applies to")
	var noted := Tools.format_reload_report(["res://a.gd"], "the run", "(trusting the user's checkboxes)", [])
	_check(noted.contains("trusting the user's checkboxes"), "the arming note rides along when there is one")
	# The caveat scan itself, against real files in this project.
	var none := Tools._reload_caveats(["res://addons/gdllm-godot-agentic-harness/tools/run_fixture.gd"])
	_check(none.is_empty(), "a script with no class_name, no @export and no autoload registration earns no caveat")
	var declared := Tools._reload_caveats(["res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd"])
	_check(declared.size() == 1 and String(declared[0]).contains("class_name"), "a script declaring a class_name earns exactly that caveat")
	# This project registers its autoload by uid, and uids do not resolve in a --script run (no registry loaded), so only the negative is assertable here; the positive is verified against a live editor, where the tool actually runs.
	_check(not Tools._is_autoload_script("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd"), "an ordinary script is not mistaken for an autoload")
	_check(not Tools._is_autoload_script("res://nonexistent.gd"), "a path that is not registered anywhere is not mistaken for one")


## The refusal every game tool gives when nothing is playing. Five copies had drifted apart and the weakest — profile_game's, which named a profile flag but never keep_running — cost a wild run three launches that each stopped again, ending its turn on the consecutive-use guard just as it got the arguments right.
func _test_no_run_refusals() -> void:
	var base := Tools._no_run_refusal("nothing to profile")
	_check(base.contains("\"keep_running\": true"), "the shared refusal names the argument that keeps the game up, spelled as it is passed")
	_check(base.contains("stops as soon as its capture ends"), "and says WHY a plain run is not enough, which is the step the wild run missed twice")
	_check(base.contains("ask the user to play"), "the other route stays offered")
	_check(Tools._no_run_refusal("nothing to profile", "Extra clause.").ends_with("Extra clause."), "a tool's own addition rides on the end")
	# Every game tool routes through it, so none can drift into a weaker wording again.
	for what in ["no game to report its video memory", "no game to reload scripts into", "nothing to break into", "no game to read"]:
		_check(Tools._no_run_refusal(what).contains(what), "the shared refusal carries each tool's own noun: %s" % what)
	_check(Tools._game_reach_error("read", "not_running", "").contains("keep_running"), "the transport ladder's not-running rung uses the shared wording too")
	_check(Tools._game_reach_error("drive", "not_running", "").contains("no game to drive"), "and keeps its per-tool verb")
