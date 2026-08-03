extends SceneTree
## Headless regression tests for cache-boundary schema retirement: recency reconstruction from stored history, the idle-turns policy, and retirement-aware reactivation.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/schema_retirement_test.gd
## Exits nonzero on any failure. Only static pure helpers are exercised, so no UI, model, or EditorSettings is touched.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_usage_from_history()
	_test_retirement_candidates()
	_test_reactivation_honors_retirement()
	_test_retirement_in_history()
	_test_conditional_description()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _call_turn(tool_name: String) -> Dictionary:
	return {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": tool_name, "arguments": {}}}]}


func _search_turn(activated: String) -> Dictionary:
	return {"role": "tool", "tool_name": "tool_search", "content": JSON.stringify({"tools": [{"name": activated}]})}


func _retirement_notice(retired: Array) -> Dictionary:
	return {"role": "notice", "kind": "cache_boundary", "reason": "test", "retired": retired}


func _test_usage_from_history() -> void:
	var history: Array = [
		{"role": "user", "content": "a"},
		_call_turn("read_file"),
		_search_turn("edit_file"),
		{"role": "user", "content": "b"},
		{"role": "user", "content": "c"},
	]
	var usage: Dictionary = Tools.tool_usage_from_history(history)
	_check(int(usage["turns"]) == 3, "turn clock counts user messages")
	_check(int(usage["last_used"].get("read_file", -1)) == 1, "a called tool stamps the turn it ran")
	_check(int(usage["last_used"].get("edit_file", -1)) == 1, "a searched-only tool stamps its attachment turn")
	_check(not usage["last_used"].has("no_such_tool"), "unregistered names never enter the recency map")


func _test_retirement_candidates() -> void:
	var active := {"read_file": true, "edit_file": true, "tool_search": true}
	var last_used := {"read_file": 5, "edit_file": 1}
	var retired: PackedStringArray = Tools.schema_retirement_candidates(active, last_used, 5)
	_check(retired == PackedStringArray(["edit_file"]), "a tool idle exactly SCHEMA_RETIRE_IDLE_TURNS turns is retired")
	_check(Tools.schema_retirement_candidates(active, last_used, 4).is_empty(), "a tool one turn short of the threshold is kept")
	_check(Tools.schema_retirement_candidates({"read_file": true}, {}, GDLLMTunables.geti(GDLLMTunables.SCHEMA_RETIRE_IDLE_TURNS)).has("read_file"), "no recorded use counts as idle forever")
	_check(not Tools.schema_retirement_candidates({"tool_search": true}, {}, 99).has("tool_search"), "tool_search is never a candidate")
	var multi: PackedStringArray = Tools.schema_retirement_candidates({"write_file": true, "edit_file": true}, {}, 9)
	_check(multi == PackedStringArray(["edit_file", "write_file"]), "candidates come back sorted for deterministic notices")


func _test_reactivation_honors_retirement() -> void:
	var history: Array = [
		{"role": "user", "content": "a"},
		_search_turn("edit_file"),
		_call_turn("read_file"),
		_retirement_notice(["edit_file"]),
	]
	var active: Dictionary = Tools.active_tools_from_history(history)
	_check(not active.has("edit_file"), "a persisted retirement detaches the tool on reload")
	_check(active.has("read_file"), "a retirement only removes the named tools")
	history.append(_search_turn("edit_file"))
	active = Tools.active_tools_from_history(history)
	_check(active.has("edit_file"), "a re-search after retirement re-attaches, replayed in history order")
	# The per-turn reconstruction sees the set as of its cutoff, so a request sent before the retirement still rebuilds with the tool attached.
	_check(Tools.active_tools_from_history(history, 3).has("edit_file"), "a cutoff before the retirement keeps the tool attached")


func _test_retirement_in_history() -> void:
	var history: Array = [
		{"role": "user", "content": "a"},
		_call_turn("read_file"),
		_retirement_notice(["edit_file"]),
	]
	_check(not Tools.retirement_in_history([]), "an empty history has no retirement")
	_check(Tools.retirement_in_history(history), "a persisted retirement latches the flag on reload")
	_check(not Tools.retirement_in_history(history, 2), "a cutoff before the retirement leaves the latch off, so a pre-retirement request reconstructs without the note")
	_check(not Tools.retirement_in_history([{"role": "notice", "kind": "error", "text": "x"}]), "other notice kinds don't latch")


func _test_conditional_description() -> void:
	var plain := String(Tools.tool_search_schema(false, false, {}, false)["function"]["description"])
	var disclosed := String(Tools.tool_search_schema(false, false, {}, true)["function"]["description"])
	_check(not plain.contains(Tools.TOOL_SEARCH_RETIREMENT_NOTE), "the detachment note is absent before any retirement")
	_check(disclosed.contains(Tools.TOOL_SEARCH_RETIREMENT_NOTE), "the note appears once the latch is set")
	_check(disclosed.contains("Available tools"), "the catalog still follows the note")
	# The note is the ONLY difference the latch makes, so flipping it never changes any other prefix bytes.
	_check(disclosed.replace("\n\n" + Tools.TOOL_SEARCH_RETIREMENT_NOTE, "") == plain, "the latch adds exactly the note and nothing else")
