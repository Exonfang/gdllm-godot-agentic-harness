extends SceneTree
## Headless regression tests for user attachments carried as synthetic tool call/result pairs (GDLLMChatSession._append_attachment_pair): that all three wire formats accept the shape, and that the pair is ordinary prune fodder.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/attachment_wire_test.gd
## Exits nonzero on any failure. Only adapter translation and the static prune selector are exercised, so no UI, model, or EditorSettings is touched.
##
## What these guard: an attachment is stored as an assistant turn carrying a real read_file call plus its result, so the existing prune pass reclaims it with no attachment-specific logic and the pruned stamp's "re-run tool" names something the model can actually do. That only works if every provider accepts a tool-call turn the model never actually produced — in particular one with no stored `assistant_blocks`, which Anthropic would otherwise expect to echo verbatim inside a trailing tool loop. A tool_use with no matching tool_result (or the reverse) is a hard API error on Anthropic and OpenAI, so the pairing is what these tests pin. The result body and the ledger mark must match what the live tool does, or the model is told a call ran whose output looks nothing like that call's.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Adapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const Subagent = preload("res://addons/gdllm-godot-agentic-harness/gdllm_subagent.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_anthropic_pairs_tool_use_with_result()
	_test_anthropic_survives_without_stored_blocks()
	_test_openai_binds_result_to_call_id()
	_test_ollama_keeps_the_pair_intact()
	_test_attachment_is_ordinary_prune_fodder()
	_test_stamp_names_the_remedy()
	_test_result_matches_what_the_real_call_returns()
	_test_attachment_grounds_a_later_edit()
	_test_unsaved_buffer_is_disclosed()
	_test_read_file_is_a_registry_tool()
	_test_attachment_never_activates_the_tool()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## The canonical history a send with one attached script produces: the user's message, then the synthetic pair.
func _history() -> Array:
	return [
		{"role": "user", "content": "why is this broken?"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": Tools.READ_FILE, "arguments": {"path": "res://player.gd", "full": true}}}], "attachment": true},
		{"role": "tool", "content": "res://player.gd:\n\nextends Node", "tool_name": Tools.READ_FILE, "attachment": true},
	]


func _test_anthropic_pairs_tool_use_with_result() -> void:
	var out: Array = Adapters.AnthropicAdapter.new()._translate_messages(_history(), true)
	# user → assistant(tool_use) → user(tool_result): the shape the API requires, with the result in the turn right after its call.
	_check(out.size() == 3, "an attachment translates to three Anthropic messages")
	_check(String(out[0]["role"]) == "user" and String(out[2]["role"]) == "user", "the tool_result rides its own user turn")
	var uses: Array = []
	var results: Array = []
	for block in out[1]["content"]:
		if String(block.get("type", "")) == "tool_use":
			uses.append(String(block.get("id", "")))
	for block in out[2]["content"]:
		if String(block.get("type", "")) == "tool_result":
			results.append(String(block.get("tool_use_id", "")))
	_check(uses.size() == 1 and results.size() == 1, "exactly one tool_use and one tool_result")
	# The regression that would break every Anthropic request: an id that doesn't resolve is a hard 400.
	_check(uses[0] != "" and uses[0] == results[0], "the tool_result echoes the tool_use id it answers")


func _test_anthropic_survives_without_stored_blocks() -> void:
	# The synthetic turn sits after the last user message, so the adapter treats it as inside the trailing loop and would echo raw assistant_blocks — which a turn no model produced does not have. It must fall back to rebuilding from the call instead of emitting empty content.
	var out: Array = Adapters.AnthropicAdapter.new()._translate_messages(_history(), true)
	_check(not Array(out[1]["content"]).is_empty(), "a synthetic call turn with no stored blocks still yields content")
	# Tool-less requests (the loop-brake reflection, a subagent's forced answer) reject tool blocks outright, so the pair must flatten to readable text rather than error.
	var flat: Array = Adapters.AnthropicAdapter.new()._translate_messages(_history(), false)
	for msg in flat:
		_check(msg["content"] is String, "a tool-less request flattens the pair to plain text")


func _test_openai_binds_result_to_call_id() -> void:
	var out: Array = Adapters.OpenAIAdapter.new()._translate_messages(_history())
	_check(out.size() == 3, "an attachment translates to three OpenAI messages")
	var call_id := String(out[1]["tool_calls"][0]["id"])
	_check(call_id != "" and String(out[2]["tool_call_id"]) == call_id, "the tool message is bound to its call id")
	var encoded: Variant = out[1]["tool_calls"][0]["function"]["arguments"]
	_check(encoded is String and JSON.parse_string(encoded) is Dictionary, "arguments are string-encoded JSON as the API requires")
	_check(String(encoded).contains("res://player.gd"), "the attached path survives into the call the model sees, so a pruned attachment names what to re-read")


func _test_ollama_keeps_the_pair_intact() -> void:
	var body: Dictionary = Adapters.OllamaAdapter.new().build_chat_body("m", _history(), [])
	var msgs: Array = body["messages"]
	_check(msgs.size() == 3, "Ollama carries the pair as-is")
	_check(String(msgs[2]["role"]) == "tool", "the result stays a tool message")


func _test_attachment_is_ordinary_prune_fodder() -> void:
	# The point of the whole shape: the prune selector sees a tool result like any other, with no attachment-specific branch anywhere in it.
	var loop: Array = []
	loop.append({"role": "user", "content": "go"})
	for i in 5:
		loop.append({"role": "assistant", "content": "", "tool_calls": [{"function": {"name": Tools.READ_FILE, "arguments": {}}}], "attachment": true})
		loop.append({"role": "tool", "content": "x".repeat(4000), "tool_name": Tools.READ_FILE, "attachment": true})
	var picked: Dictionary = Subagent.prune_candidates(loop)
	_check(not Array(picked["indices"]).is_empty(), "attachments are eligible for pruning")
	_check(int(picked["saved"]) > 0, "pruning an attachment reclaims tokens")
	# The keep-recent window applies to them exactly as to real results — no special casing in either direction.
	_check(Array(picked["indices"]).size() == 5 - GDLLMTunables.geti(GDLLMTunables.PRUNE_KEEP_RECENT_PAIRS), "the newest attachment pairs are kept like any tool result")


func _test_stamp_names_the_remedy() -> void:
	# A stamp that only announces the loss leaves the model stuck; the call it replaces is still in history with its arguments, so re-running is an action it can take.
	_check("re-run" in Tools.PRUNED_RESULT_STAMP, "the prune stamp names the remedy, not just the loss")


func _test_result_matches_what_the_real_call_returns() -> void:
	var ledger = Tools.SessionLedger.new()
	# A whole-script attachment reproduces read_file's "<path>:\n\n<text>" shape.
	var whole: String = Tools.format_attachment_read("res://player.gd", "extends Node\nvar hp := 3", 0, 0, false, ledger)
	_check(whole.begins_with("res://player.gd:\n\n"), "a whole-file attachment is formatted as read_file formats a full read")
	_check(whole.ends_with("var hp := 3"), "the attached text arrives verbatim")
	# A selection reproduces the numbered range shape, sliced from the whole buffer so its line numbers are the file's real ones.
	var ranged: String = Tools.format_attachment_read("res://player.gd", "a\nb\nc\nd", 2, 3, false, ledger)
	_check("(lines 2-3 of 4)" in ranged, "a selection is formatted as read_file formats a ranged read")
	_check("   2: b" in ranged and "   3: c" in ranged, "the range carries the file's real line numbers")
	_check(not ("   1: a" in ranged) and not ("   4: d" in ranged), "only the selected lines reach the model")


func _test_attachment_grounds_a_later_edit() -> void:
	# The contradiction this closes: history showing a read_file result for a path while the ledger still calls it never-shown, so edit_file refuses a file the model can plainly see.
	var ledger = Tools.SessionLedger.new()
	_check(not ledger.seen_files.has("res://player.gd"), "nothing is marked seen before the attachment")
	Tools.format_attachment_read("res://player.gd", "extends Node", 0, 0, false, ledger)
	_check(bool(ledger.seen_files.get("res://player.gd", false)), "an attachment marks its file verbatim-seen, as the equivalent real read does")


func _test_unsaved_buffer_is_disclosed() -> void:
	# The attachment is the live editor buffer; a re-run of the call it claims reads disk. When those differ the model must be told, or it takes a silently different result as a reproduction.
	var ledger = Tools.SessionLedger.new()
	var dirty: String = Tools.format_attachment_read("res://player.gd", "extends Node", 0, 0, true, ledger)
	_check("unsaved" in dirty, "an unsaved buffer's divergence from disk is disclosed on the result")
	var clean: String = Tools.format_attachment_read("res://player.gd", "extends Node", 0, 0, false, ledger)
	_check(not ("unsaved" in clean), "a saved buffer carries no spurious warning")


func _test_read_file_is_a_registry_tool() -> void:
	# The whole point of dropping the invented names: the model can actually run what the history shows it running.
	_check(Tools.REGISTRY.has(Tools.READ_FILE), "attachments are carried as a real registered tool")
	_check(not Tools.PRUNE_GUARDED_TOOLS.has(Tools.READ_FILE), "and one the prune pass is allowed to touch")


func _test_attachment_never_activates_the_tool() -> void:
	# The live session never attaches read_file's schema for an attachment (the model reaches it through tool_search), so the reload walkers must not either — or the same session carries different tool footprints before and after a reload, and the context inspector claims a footprint live requests never had.
	var active: Dictionary = Tools.active_tools_from_history(_history())
	_check(not active.has(Tools.READ_FILE), "an attachment's synthetic call activates nothing on reload")
	var usage: Dictionary = Tools.tool_usage_from_history(_history())
	_check(not Dictionary(usage["last_used"]).has(Tools.READ_FILE), "and stamps no recency clock")
	# The exemption reads the attachment flag, never the tool name, so a real model call still activates.
	var real: Array = _history()
	real.append({"role": "assistant", "content": "", "tool_calls": [{"function": {"name": Tools.READ_FILE, "arguments": {"path": "res://player.gd"}}}]})
	_check(Tools.active_tools_from_history(real).has(Tools.READ_FILE), "a real read_file call still activates the tool")
