extends SceneTree
## Headless regression tests for the subagent loop's compaction pruning policy (GDLLMSubagent.prune_candidates): the keep-recent window and every eligibility exemption.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/subagent_compaction_test.gd
## Exits nonzero on any failure. Only the static settings-free selector is exercised, so no UI, model, or EditorSettings is touched.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Subagent = preload("res://addons/gdllm-godot-agentic-harness/gdllm_subagent.gd")
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_keep_recent_window()
	_test_exemptions()
	_test_empty_and_foreign_entries()
	_test_over_window_advice()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _result(tool_name: String, content: String) -> Dictionary:
	return {"role": "tool", "content": content, "tool_name": tool_name}


func _long() -> String:
	return "x".repeat(400)


func _test_keep_recent_window() -> void:
	var messages: Array = [{"role": "user", "content": "task"}]
	for i in 5:
		messages.append({"role": "assistant", "content": "", "tool_calls": []})
		messages.append(_result("read_file", _long()))
	var picked: Dictionary = Subagent.prune_candidates(messages)
	_check(Array(picked["indices"]) == [2, 4], "the newest PRUNE_KEEP_RECENT_PAIRS results are kept, older ones chosen oldest first")
	_check(int(picked["saved"]) > 0, "clearing long results reports a positive reclaim")
	_check(Array(Subagent.prune_candidates(messages.slice(0, 7))["indices"]).is_empty(), "a loop with only the working set prunes nothing")


func _test_exemptions() -> void:
	var messages: Array = [
		_result("tool_search", _long()),
		_result("read_file", "Error: could not read it"),
		_result("read_file", Tools.PRUNED_RESULT_STAMP),
		_result("read_file", "short"),
		_result("read_file", _long()),
	]
	for i in 3:
		messages.append(_result("read_file", _long()))
	var picked: Dictionary = Subagent.prune_candidates(messages)
	_check(Array(picked["indices"]) == [4], "guarded, errored, already-pruned, and too-short results are all exempt")


func _test_empty_and_foreign_entries() -> void:
	var empty: Dictionary = Subagent.prune_candidates([])
	_check(Array(empty["indices"]).is_empty() and int(empty["saved"]) == 0, "an empty loop yields no candidates and no savings")
	var messages: Array = ["not a message", {"role": "assistant", "content": _long()}]
	for i in 4:
		messages.append(_result("read_file", _long()))
	_check(Array(Subagent.prune_candidates(messages)["indices"]) == [2], "non-dictionary and non-tool entries neither crash nor count toward the keep-recent window")


func _test_over_window_advice() -> void:
	# The estimate-only branch wins even with compaction on: no reported base means the figure is a guess, and the message must say so before naming any lever.
	_check(Subagent._over_window_advice(true, true).contains("chars-per-token estimate"), "no reported base is disclosed as an estimate")
	_check(Subagent._over_window_advice(true, false).contains("chars-per-token estimate"), "estimate-only outranks the compaction-off advice")
	# Compaction off names the two switches to enable — the guard fires here exactly because the pass could not.
	_check(Subagent._over_window_advice(false, false).contains("Compaction Within Subagents"), "compaction off points at the within-subagents switch to enable")
	_check(not Subagent._over_window_advice(false, false).contains("chars-per-token estimate"), "a reported base is not called an estimate")
	# Compaction on but still over: the pruning pass ran and could not clear the overflow.
	_check(Subagent._over_window_advice(false, true).contains("even after compaction"), "a genuine overflow past a run pass says so")
