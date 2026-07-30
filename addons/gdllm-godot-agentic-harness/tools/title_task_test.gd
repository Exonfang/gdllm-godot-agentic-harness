extends SceneTree
## Headless regression tests for the Tasks-Model title panel's display-only record: settling a title run appends a role:"task" history entry that notifies persistence, is stripped from every model resend, and leaves token accounting and tool reactivation untouched. Pins the contract that background-task transparency never leaks into any model's context.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/title_task_test.gd
## Exits nonzero on any failure.

var _checks := 0
var _failures := 0


func _init() -> void:
	_run_tests()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _run_tests() -> void:
	var entry := GDLLMChatSession.title_task_entry("Local · gemma3:4b", "You generate a short title.", "add a sprite", "Add a sprite", false, 1.5)
	_check(String(entry.get("role", "")) == "task", "the record's role marks it a background task")
	_check(String(entry.get("result", "")) == "Add a sprite" and not bool(entry.get("failed", true)), "the outcome rides the record")

	var session := GDLLMChatSession.new()
	session.session_id = "s_test"
	# A session restored with its first-show replay still pending — the settle path that must not touch the unrendered log.
	session._needs_replay = true
	session._history.assign([
		{"role": "user", "content": "add a sprite"},
		{"role": "assistant", "content": "Done.", "model": "m", "stats": {"tokens_in": 10, "tokens_out": 5}},
	])
	var landed: Array = []
	session.history_changed.connect(func(id: String) -> void: landed.append(id))
	session.settle_title_task("Local · gemma3:4b", "sys", "add a sprite", "Add a sprite", false, 1.5)
	_check(session.get_history().size() == 3, "the settled run lands in history")
	_check(landed == ["s_test"], "the settle notifies the dock to persist")
	var stored: Dictionary = session.get_history()[2]
	_check(String(stored.get("role", "")) == "task" and String(stored.get("result", "")) == "Add a sprite", "the stored entry carries the outcome")

	var resend: Array = session._history_for_request()
	_check(resend.size() == 2, "the task record is stripped from a resend")
	for msg in resend:
		_check(String(msg.get("role", "")) != "task", "no task role reaches the wire")

	var usage := GDLLMChatSession.token_usage(session.get_history())
	_check(int(usage["rep_in"]) == 10 and int(usage["rep_out"]) == 5, "token accounting ignores the task record")
	_check(int(usage["context"]) == 15 and not bool(usage["est_fallback_used"]), "the task record adds nothing to the context size or the estimate share")
	_check(GDLLMTools.active_tools_from_history(session.get_history()).is_empty(), "tool reactivation ignores the task record")
	session.free()
