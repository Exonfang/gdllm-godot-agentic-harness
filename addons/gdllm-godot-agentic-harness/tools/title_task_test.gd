extends SceneTree
## Headless regression tests for the Tasks-Model title panel's display-only record: settling a title run appends a role:"task" history entry that notifies persistence, is stripped from every model resend, and leaves token accounting and tool reactivation untouched. Pins the contract that background-task transparency never leaks into any model's context.
## Also pins the title's path from the wire: Ollama's one-shot completion rides /api/chat so a thinking model's reasoning arrives split from the reply (and is kept on the record), and the sanitizer drops a trace that still leaks inline.
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

	_check_ollama_completion()
	_check_sanitizer()
	_check_thinking_record()


func _check_ollama_completion() -> void:
	var adapter := LLMAdapter.for_kind(GDLLMSources.KIND_OLLAMA)
	var req: Dictionary = adapter.completion_request("ornith-1.5:35b", "Title it.", "increment patch version")
	var body: Dictionary = req["body"]
	_check(String(req["path"]) == "/api/chat", "Ollama completions ride /api/chat, where a thinking model's reasoning arrives split out")
	_check(body["messages"] == [{"role": "system", "content": "Title it."}, {"role": "user", "content": "increment patch version"}], "the system prompt and the opening message become chat messages")
	_check(body["stream"] == false and not body.has("think"), "one JSON reply, with the model's own thinking default left alone")
	var bare: Dictionary = adapter.completion_request("m", "", "hi")["body"]
	_check(bare["messages"].size() == 1, "an empty system prompt sends no system message")
	var reply := {"message": {"role": "assistant", "content": "Increment Patch Version", "thinking": "The user wants a short title."}, "prompt_eval_count": 56, "eval_count": 44}
	_check(adapter.parse_completion(reply) == "Increment Patch Version", "the reply is the message content alone")
	_check(adapter.parse_completion_thinking(reply) == "The user wants a short title.", "the reasoning lifts out of message.thinking")
	_check(int(adapter.parse_completion_stats(reply).get("tokens_out", 0)) == 44, "usage counters still read off the top level")
	_check(adapter.parse_completion_thinking({"message": {"content": "x"}}) == "" and adapter.parse_completion({}) == "", "a plain model's reply carries no reasoning, and a malformed body parses empty")
	_check(LLMAdapter.for_kind(GDLLMSources.KIND_OPENAI).parse_completion_thinking({"choices": []}) == "", "adapters that don't lift reasoning return none")


func _check_sanitizer() -> void:
	# Verbatim shape of an Unsloth Qwen GGUF reply on /api/generate: the template opened <think> in the prompt, so only the closing tag comes back.
	var leaked := "The user wants a short title summarizing \"increment patch version\".\n\nLet me create a concise title.\n</think>\n\nIncrement Patch Version"
	_check(GDLLMChatDock.sanitize_title(leaked) == "Increment Patch Version", "a trace ending in a lone </think> is dropped")
	_check(GDLLMChatDock.sanitize_title("<think>\nhmm\n</think>\n\n\"Add a Sprite.\"") == "Add a Sprite", "a whole <think> block is dropped before the usual cleanup")
	_check(GDLLMChatDock.sanitize_title("<THINK>a</Think>Fix Tiles") == "Fix Tiles", "tags match case-insensitively")
	_check(GDLLMChatDock.sanitize_title("<think>\nThe user wants") == "", "a trace cut off before any answer reduces to empty, failing loudly instead of titling with reasoning")
	_check(GDLLMChatDock.sanitize_title("Add a sprite\nextra") == "Add a sprite", "a plain reply still keeps its first line")


func _check_thinking_record() -> void:
	var entry := GDLLMChatSession.title_task_entry("m", "sys", "p", "T", false, 1.0, "T", {}, "reasoning")
	_check(String(entry.get("thinking", "")) == "reasoning", "the reasoning rides the stored record")
	_check(not GDLLMChatSession.title_task_entry("m", "sys", "p", "T", false, 1.0, "T", {}, "  \n").has("thinking"), "a blank trace stores nothing")
	var session := GDLLMChatSession.new()
	session._needs_replay = true
	session.settle_title_task("m", "sys", "p", "T", false, 1.0, "T", {}, "reasoning")
	_check(String(session.get_history()[0].get("thinking", "")) == "reasoning", "a settled live run keeps its reasoning")
	_check(session._history_for_request().is_empty(), "the reasoning never reaches a resend")
	_check(session.clear_thinking() and not session.get_history()[0].has("thinking"), "Clear Thinking strips it like any other trace")
	session.free()
