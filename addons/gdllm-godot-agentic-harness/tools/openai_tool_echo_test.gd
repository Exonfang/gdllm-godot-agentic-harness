extends SceneTree
## Headless regression tests for OpenAIAdapter's provider-state echo on tool calls: fields a server attaches to a streamed tool call beyond id/type/function (Gemini's extra_content.google.thought_signature) are captured into an assistant_blocks event, then replayed verbatim on the call inside the trailing tool loop; turns before the last user message, servers that attach nothing, and blocks recorded under another kind all keep the plain rebuild.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/openai_tool_echo_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const LLMAdapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")

const SIGNATURE := {"google": {"thought_signature": "c2lnLTE="}}

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_stream_captures_extras()
	_test_stream_without_extras()
	_test_parallel_calls()
	_test_trailing_loop_echo()
	_test_older_turn_rebuilds()
	_test_alien_blocks_rebuild()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Feed each line to the adapter and collect every canonical event, the way LLMClient's stream loop does.
func _events(adapter: LLMAdapters.OpenAIAdapter, lines: Array) -> Array:
	var events: Array = []
	for line in lines:
		events.append_array(adapter.parse_line(line))
	return events


func _frame(tool_calls: Array, finish: Variant = null) -> String:
	return "data: " + JSON.stringify({"choices": [{"delta": {"tool_calls": tool_calls}, "finish_reason": finish}]})


func _types(events: Array) -> Array:
	return events.map(func(e: Dictionary) -> String: return String(e["type"]))


func _test_stream_captures_extras() -> void:
	var events := _events(LLMAdapters.OpenAIAdapter.new(), [
		_frame([{"index": 0, "id": "fc-1", "type": "function", "function": {"name": "tool_search", "arguments": "{\"query\":"}, "extra_content": SIGNATURE}]),
		_frame([{"index": 0, "function": {"arguments": "\"scene\"}"}}], "tool_calls"),
	])
	var types := _types(events)
	_check(types == ["assistant_blocks", "tool_calls", "done"], "a call carrying provider state emits its raw blocks ahead of the tool calls (got %s)" % [types])
	var block: Dictionary = events[0]["blocks"][0]
	_check(block.get("extra_content") == SIGNATURE, "the provider field is kept whole")
	_check(block["id"] == "fc-1" and block["function"]["name"] == "tool_search" and block["function"]["arguments"] == "{\"query\":\"scene\"}", "the raw call keeps its real id, name, and the joined argument string")
	var call: Dictionary = events[1]["calls"][0]
	_check(call == {"function": {"name": "tool_search", "arguments": {"query": "scene"}}}, "the canonical call is unchanged")


func _test_stream_without_extras() -> void:
	var events := _events(LLMAdapters.OpenAIAdapter.new(), [
		_frame([{"index": 0, "id": "call_a", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}], "tool_calls"),
	])
	_check(_types(events) == ["tool_calls", "done"], "a server that attaches nothing emits no blocks, so its history is stored as before")


func _test_parallel_calls() -> void:
	# Gemini signs only the first of a parallel batch; the unsigned call still rides along so the batch replays whole.
	var events := _events(LLMAdapters.OpenAIAdapter.new(), [
		_frame([{"index": 0, "id": "fc-1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}, "extra_content": SIGNATURE}]),
		_frame([{"index": 1, "id": "fc-2", "type": "function", "function": {"name": "list_dir", "arguments": "{}"}}], "tool_calls"),
	])
	var blocks: Array = events[0]["blocks"]
	_check(blocks.size() == 2, "every call of a batch is kept when any one carries provider state")
	_check(blocks[0].has("extra_content") and not blocks[1].has("extra_content"), "each call keeps only its own provider fields")
	# Gemini streams each parallel call whole under the same index; only the differing id tells them apart.
	events = _events(LLMAdapters.OpenAIAdapter.new(), [
		_frame([{"index": 0, "id": "call_1", "type": "function", "function": {"name": "tool_search", "arguments": "{\"query\":\"list_directory\"}"}, "extra_content": SIGNATURE}]),
		_frame([{"index": 0, "id": "call_2", "type": "function", "function": {"name": "tool_search", "arguments": "{\"query\":\"read_file\"}"}}], "tool_calls"),
	])
	var calls: Array = events[1]["calls"]
	_check(calls.size() == 2, "two whole calls under one index stay two calls (got %d)" % calls.size())
	_check(calls[0]["function"]["arguments"] == {"query": "list_directory"} and calls[1]["function"]["arguments"] == {"query": "read_file"}, "each keeps its own arguments instead of a joined, unparseable string")
	blocks = events[0]["blocks"]
	_check(blocks[0]["id"] == "call_1" and blocks[0].has("extra_content") and blocks[1]["id"] == "call_2" and not blocks[1].has("extra_content"), "the raw calls split the same way, the signature on its own call")
	# Standard OpenAI streaming: one id on the opening delta, argument pieces under the same index with no id.
	events = _events(LLMAdapters.OpenAIAdapter.new(), [
		_frame([{"index": 0, "id": "call_a", "type": "function", "function": {"name": "read_file", "arguments": "{\"pa"}}]),
		_frame([{"index": 0, "function": {"arguments": "th\":\"a\"}"}}]),
		_frame([{"index": 1, "id": "call_b", "type": "function", "function": {"name": "list_dir", "arguments": ""}}]),
		_frame([{"index": 1, "id": "call_b", "function": {"arguments": "{}"}}], "tool_calls"),
	])
	calls = events[0]["calls"]
	_check(calls.size() == 2 and calls[0]["function"]["arguments"] == {"path": "a"} and calls[1]["function"]["name"] == "list_dir", "argument pieces still join under their index, and a repeated same id doesn't split a call")


func _history(blocks: Variant) -> Array:
	var turn := {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "tool_search", "arguments": {"query": "scene"}}}]}
	if blocks != null:
		turn["assistant_blocks"] = blocks
	return [
		{"role": "system", "content": "sys"},
		{"role": "user", "content": "find the main scene"},
		turn,
		{"role": "tool", "content": "res://main.tscn", "tool_name": "tool_search"},
	]


func _raw_block() -> Dictionary:
	return {"id": "fc-1", "type": "function", "function": {"name": "tool_search", "arguments": "{\"query\":\"scene\"}"}, "extra_content": SIGNATURE}


func _test_trailing_loop_echo() -> void:
	var out: Array = LLMAdapters.OpenAIAdapter.new()._translate_messages(_history([_raw_block()]))
	var call: Dictionary = out[2]["tool_calls"][0]
	_check(call.get("extra_content") == SIGNATURE, "inside the trailing loop the stored call replays with its provider field")
	_check(call["id"] == "fc-1" and out[3]["tool_call_id"] == "fc-1", "the tool result binds to the replayed call's real id")
	var unnamed := _raw_block()
	unnamed["id"] = ""
	out = LLMAdapters.OpenAIAdapter.new()._translate_messages(_history([unnamed]))
	_check(out[2]["tool_calls"][0]["id"] != "" and out[3]["tool_call_id"] == out[2]["tool_calls"][0]["id"], "a replayed call with no id gets one its result binds to")


func _test_older_turn_rebuilds() -> void:
	var history := _history([_raw_block()])
	history.append({"role": "assistant", "content": "It's res://main.tscn."})
	history.append({"role": "user", "content": "thanks"})
	var out: Array = LLMAdapters.OpenAIAdapter.new()._translate_messages(history)
	var call: Dictionary = out[2]["tool_calls"][0]
	_check(not call.has("extra_content") and call["id"] == "call_0", "a turn before the last user message rebuilds, so past provider state isn't re-sent")
	_check(out[3]["tool_call_id"] == "call_0", "its result binds to the synthesized id")


func _test_alien_blocks_rebuild() -> void:
	var anthropic := [{"type": "thinking", "thinking": "...", "signature": "x"}, {"type": "tool_use", "id": "toolu_1", "name": "tool_search", "input": {}}]
	var out: Array = LLMAdapters.OpenAIAdapter.new()._translate_messages(_history(anthropic))
	_check(out[2]["tool_calls"][0]["id"] == "call_0" and not out[2]["tool_calls"][0].has("signature"), "blocks recorded under another kind fall through to the rebuild")
	out = LLMAdapters.OpenAIAdapter.new()._translate_messages(_history([_raw_block(), _raw_block()]))
	_check(out[2]["tool_calls"].size() == 1 and out[2]["tool_calls"][0]["id"] == "call_0", "blocks that don't match the turn's call count fall through to the rebuild")
	out = LLMAdapters.OpenAIAdapter.new()._translate_messages(_history(null))
	_check(out[2]["tool_calls"][0]["id"] == "call_0", "a turn with no stored blocks rebuilds as before")
