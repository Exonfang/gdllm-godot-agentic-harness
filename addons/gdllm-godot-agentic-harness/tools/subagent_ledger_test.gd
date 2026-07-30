extends SceneTree
## Headless regression tests for the subagent's tool-layer mutation ledger (the engine-truth record appended to a delegated run's answer).
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/subagent_ledger_test.gd
## Exits nonzero on any failure. Only static pure helpers are exercised, so no UI, model, or EditorSettings is touched.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Subagent = preload("res://addons/gdllm-godot-agentic-harness/gdllm_subagent.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_ledger_entry()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_ledger_entry() -> void:
	_check(Subagent.ledger_entry("edit_file", {"path": "res://x.gd", "old_string": "a", "new_string": "b"}, "Edited res://x.gd.") == "edit_file res://x.gd", "a successful mutating call records tool plus path")
	_check(Subagent.ledger_entry("edit_file", {"path": "res://x.gd"}, "Error: old_string was not found") == "", "an errored call records nothing")
	_check(Subagent.ledger_entry("read_file", {"path": "res://x.gd"}, "file contents") == "", "a read-only tool records nothing")
	_check(Subagent.ledger_entry("write_file", {"file": "res://y.gd"}, "Wrote res://y.gd.") == "write_file res://y.gd", "a path synonym key still names the target")
	_check(Subagent.ledger_entry("edit_file", {"path": "res://x.gd"}, "Edited, but the file is now BROKEN on disk: parse error") == "edit_file res://x.gd (left BROKEN)", "a kept-but-broken edit is suffixed")
	_check(Subagent.ledger_entry("write_file", {}, "Wrote something.") == "write_file", "no path argument falls back to the bare tool name")
