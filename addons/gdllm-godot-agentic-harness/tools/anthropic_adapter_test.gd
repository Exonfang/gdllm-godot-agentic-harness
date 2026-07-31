extends SceneTree
## Headless regression tests for AnthropicAdapter: auth headers, request-body translation (system lift, tool unwrapping, tool_result binding, the trailing-loop raw-block echo, per-family thinking config), the SSE stream reassembly (thinking/text/tool_use blocks, usage, refusal, errors), the model-list/completion helpers, the context-window probes, and the done event's canonical stop reason across all three adapters.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/anthropic_adapter_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const LLMAdapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")

## A minimal attached tool, so a test request carries a tools param — without one the adapter flattens tool turns to text (see _test_toolless_flatten).
const SOME_TOOLS: Array = [{"type": "function", "function": {"name": "read_file", "description": "Read a file.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}]

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_auth_headers()
	_test_chat_body_basics()
	_test_cache_ttl()
	_test_tool_translation()
	_test_message_translation()
	_test_trailing_loop_echo()
	_test_toolless_flatten()
	_test_thinking_config()
	_test_stream_reassembly()
	_test_stream_refusal()
	_test_stream_error()
	_test_stop_reasons()
	_test_models_and_completion()
	_test_ollama_strips_foreign_fields()
	_test_output_caps()
	_test_context_probe()
	_test_normalize_base()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Feed each line to a fresh parse pass and collect every canonical event, the way LLMClient's stream loop does.
func _events(adapter: LLMAdapters, lines: Array) -> Array:
	var events: Array = []
	for line in lines:
		events.append_array(adapter.parse_line(String(line)))
	return events


## One SSE data line for `payload`, encoded the way the endpoint frames it.
func _sse(payload: Dictionary) -> String:
	return "data: " + JSON.stringify(payload)


## The first event of `type` among `events`, or {} when none arrived.
func _event_of(events: Array, type: String) -> Dictionary:
	for event in events:
		if event is Dictionary and String(event.get("type", "")) == type:
			return event
	return {}


func _test_auth_headers() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var with_key := adapter.auth_headers("sk-ant-test")
	_check(with_key.has("x-api-key: sk-ant-test"), "api key rides the x-api-key header")
	_check(with_key.has("anthropic-version: 2023-06-01"), "the version header always rides along")
	var without_key := adapter.auth_headers("  ")
	_check(without_key.size() == 1 and without_key.has("anthropic-version: 2023-06-01"), "a blank key still sends the version header so the failure is a clear 401")


func _test_chat_body_basics() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var messages: Array = [
		{"role": "system", "content": "You are helpful."},
		{"role": "user", "content": "Hi"},
	]
	var body: Dictionary = adapter.build_chat_body("claude-opus-4-8", messages, [])
	_check(String(body.get("system", "")) == "You are helpful.", "the leading system message lifts to the top-level system field")
	_check(int(body.get("max_tokens", 0)) > 0, "max_tokens is present (the endpoint requires it)")
	_check(bool(body.get("stream", false)), "chat requests stream")
	_check(body.get("cache_control") is Dictionary, "the auto-cache breakpoint is requested")
	_check(not body.has("tools"), "no tools field when none are attached")
	var wire: Array = body.get("messages", [])
	_check(wire.size() == 1 and String(wire[0].get("role", "")) == "user", "the system message never appears in the wire messages")


func _test_cache_ttl() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var messages: Array = [{"role": "user", "content": "Hi"}]
	var default_body: Dictionary = adapter.build_chat_body("claude-opus-4-8", messages, [])
	_check(default_body.get("cache_control") == {"type": "ephemeral"}, "no configured TTL keeps the default cache_control, ttl key absent")
	var tier_body: Dictionary = adapter.build_chat_body("claude-opus-4-8", messages, [], "", 300)
	_check(tier_body.get("cache_control") == {"type": "ephemeral"}, "a TTL at the default tier sends no ttl key, keeping the body byte-identical to the unconfigured form")
	var long_body: Dictionary = adapter.build_chat_body("claude-opus-4-8", messages, [], "", 900)
	_check(long_body.get("cache_control") == {"type": "ephemeral", "ttl": "1h"}, "a TTL past the default tier requests the 1-hour lifetime")
	_check(LLMAdapters.AnthropicAdapter.effective_cache_ttl(0) == 300, "an unset TTL is the default 5-minute tier")
	_check(LLMAdapters.AnthropicAdapter.effective_cache_ttl(300) == 300, "exactly 300 stays on the default tier")
	_check(LLMAdapters.AnthropicAdapter.effective_cache_ttl(301) == 3600, "anything past 300 quantizes up to the 1-hour tier")
	_check(LLMAdapters.AnthropicAdapter.effective_cache_ttl(3600) == 3600, "3600 is the 1-hour tier itself")
	_check(LLMAdapters.AnthropicAdapter.effective_cache_ttl(7200) == 3600, "a figure past 3600 still buys only the 1-hour tier")


func _test_tool_translation() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var tools: Array = [{
		"type": "function",
		"function": {
			"name": "read_file",
			"description": "Read a file.",
			"parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		},
	}]
	var body: Dictionary = adapter.build_chat_body("claude-opus-4-8", [{"role": "user", "content": "Hi"}], tools)
	var wire_tools: Array = body.get("tools", [])
	_check(wire_tools.size() == 1, "one tool translated")
	var entry: Dictionary = wire_tools[0] if wire_tools.size() == 1 else {}
	_check(String(entry.get("name", "")) == "read_file", "the function envelope unwraps to a flat name")
	_check(entry.get("input_schema") is Dictionary and entry["input_schema"].get("required") == ["path"], "parameters become input_schema")
	_check(not entry.has("parameters") and not entry.has("type"), "no OpenAI envelope fields leak through")


func _test_message_translation() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	# A finished tool turn earlier in history, then a fresh user question: the old turn rebuilds from text + synthesized ids.
	var messages: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "", "tool_calls": [
			{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}},
			{"function": {"name": "read_file", "arguments": {"path": "b.gd"}}},
		]},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
		{"role": "tool", "content": "contents of b", "tool_name": "read_file"},
		{"role": "user", "content": "Thanks — and b.gd?"},
	]
	var body: Dictionary = adapter.build_chat_body("claude-opus-4-8", messages, SOME_TOOLS)
	var wire: Array = body.get("messages", [])
	_check(wire.size() == 4, "two tool results merge into one user turn (user, assistant, results, user)")
	var calls: Array = wire[1].get("content", []) if wire.size() > 1 else []
	_check(calls.size() == 2 and String(calls[0].get("type", "")) == "tool_use", "a blank-preamble call turn holds only tool_use blocks")
	var results: Array = wire[2].get("content", []) if wire.size() > 2 else []
	_check(results.size() == 2 and String(results[0].get("type", "")) == "tool_result", "tool results become tool_result blocks in a single user message")
	_check(String(results[0].get("tool_use_id", "")) == String(calls[0].get("id", "")), "the first result binds to the first call's id")
	_check(String(results[1].get("tool_use_id", "")) == String(calls[1].get("id", "")), "the second result binds to the second call's id")
	_check(String(calls[0].get("id", "")) != String(calls[1].get("id", "")), "synthesized call ids are distinct")


func _test_trailing_loop_echo() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var raw_blocks: Array = [
		{"type": "thinking", "thinking": "I should read the file.", "signature": "sig-abc"},
		{"type": "tool_use", "id": "toolu_real_1", "name": "read_file", "input": {"path": "a.gd"}},
	]
	var messages: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}], "assistant_blocks": raw_blocks},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
	]
	var wire: Array = adapter.build_chat_body("claude-opus-4-8", messages, SOME_TOOLS).get("messages", [])
	var echoed: Array = wire[1].get("content", []) if wire.size() > 1 else []
	_check(echoed == raw_blocks, "an assistant turn inside the active tool loop echoes its raw blocks verbatim, signature intact")
	var results: Array = wire[2].get("content", []) if wire.size() > 2 else []
	_check(results.size() == 1 and String(results[0].get("tool_use_id", "")) == "toolu_real_1", "the result binds to the real tool_use id from the raw blocks")
	# The same turn behind a later user message is out of the loop: past reasoning must not be re-sent.
	messages.append({"role": "user", "content": "Now explain it."})
	wire = adapter.build_chat_body("claude-opus-4-8", messages, SOME_TOOLS).get("messages", [])
	var rebuilt: Array = wire[1].get("content", []) if wire.size() > 1 else []
	var has_thinking := false
	for block in rebuilt:
		if block is Dictionary and String(block.get("type", "")) == "thinking":
			has_thinking = true
	_check(not has_thinking, "a call turn behind a newer user message rebuilds without its thinking blocks")


func _test_toolless_flatten() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	# The loop-brake reflection and a subagent's forced answer send tool-bearing history with NO tools param, which the API rejects if any tool_use/tool_result blocks remain.
	var messages: Array = [
		{"role": "user", "content": "What is in a.gd?"},
		{"role": "assistant", "content": "Checking.", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}]},
		{"role": "tool", "content": "contents of a", "tool_name": "read_file"},
		{"role": "user", "content": "Stop searching and answer."},
	]
	var wire: Array = adapter.build_chat_body("claude-opus-4-8", messages, []).get("messages", [])
	var has_blocks := false
	for msg in wire:
		if msg.get("content") is Array:
			has_blocks = true
	_check(not has_blocks, "a tool-less request carries no content-block arrays at all")
	var call_text := String(wire[1].get("content", "")) if wire.size() > 1 else ""
	_check(call_text.contains("Checking.") and call_text.contains("[called read_file("), "the call turn flattens to its preamble plus a readable call line")
	var result_text := String(wire[2].get("content", "")) if wire.size() > 2 else ""
	_check(result_text.begins_with("[read_file result]"), "the tool result flattens to a labeled user message")


func _test_thinking_config() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var opus: Dictionary = adapter.build_chat_body("claude-opus-4-8", [{"role": "user", "content": "Hi"}], [])
	_check(opus.get("thinking") == {"type": "adaptive", "display": "summarized"}, "opus 4.8 requests adaptive thinking with the summarized trace")
	adapter = LLMAdapters.AnthropicAdapter.new()
	var sonnet46: Dictionary = adapter.build_chat_body("claude-sonnet-4-6", [{"role": "user", "content": "Hi"}], [])
	_check(sonnet46.get("thinking") == {"type": "adaptive"}, "the 4.6 family requests adaptive thinking without a display override")
	adapter = LLMAdapters.AnthropicAdapter.new()
	var haiku: Dictionary = adapter.build_chat_body("claude-haiku-4-5", [{"role": "user", "content": "Hi"}], [])
	_check(not haiku.has("thinking"), "a family without adaptive thinking omits the field rather than risking a 400")


func _test_stream_reassembly() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var events := _events(adapter, [
		"event: message_start",
		_sse({"type": "message_start", "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 50}}}),
		"",
		_sse({"type": "ping"}),
		_sse({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
		_sse({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Let me read it."}}),
		_sse({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig-xyz"}}),
		_sse({"type": "content_block_stop", "index": 0}),
		_sse({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}),
		_sse({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Reading "}}),
		_sse({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "now."}}),
		_sse({"type": "content_block_stop", "index": 1}),
		_sse({"type": "content_block_start", "index": 2, "content_block": {"type": "tool_use", "id": "toolu_9", "name": "read_file", "input": {}}}),
		_sse({"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "{\"path\":"}}),
		_sse({"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": " \"a.gd\"}"}}),
		_sse({"type": "content_block_stop", "index": 2}),
		_sse({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 42}}),
		_sse({"type": "message_stop"}),
	])
	var thinking_text := ""
	var content_text := ""
	for event in events:
		if String(event.get("type", "")) == "thinking":
			thinking_text += String(event.get("text", ""))
		elif String(event.get("type", "")) == "content":
			content_text += String(event.get("text", ""))
	_check(thinking_text == "Let me read it.", "thinking deltas stream as canonical thinking events")
	_check(content_text == "Reading now.", "text deltas stream as canonical content events")
	var calls: Array = _event_of(events, "tool_calls").get("calls", [])
	_check(calls == [{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}}], "the fragmented tool_use input reassembles into one canonical call")
	var blocks: Array = _event_of(events, "assistant_blocks").get("blocks", [])
	_check(blocks.size() == 3, "all three raw blocks are handed back for the echo")
	_check(blocks.size() == 3 and String(blocks[0].get("signature", "")) == "sig-xyz", "the thinking block keeps its accumulated signature")
	_check(blocks.size() == 3 and blocks[2].get("input") == {"path": "a.gd"} and not blocks[2].has("_json"), "the echoed tool_use block carries the parsed input, not the fragment buffer")
	var stats: Dictionary = _event_of(events, "done").get("stats", {})
	_check(int(stats.get("tokens_in", 0)) == 150, "tokens_in sums fresh and cached input")
	_check(int(stats.get("tokens_out", 0)) == 42, "tokens_out comes from the final usage delta")


func _test_stream_refusal() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "message_start", "message": {"usage": {"input_tokens": 10}}}),
		_sse({"type": "message_delta", "delta": {"stop_reason": "refusal"}, "usage": {"output_tokens": 0}}),
		_sse({"type": "message_stop"}),
	])
	var error: Dictionary = _event_of(events, "error")
	_check(not error.is_empty() and String(error.get("message", "")).contains("refusal"), "a refusal stop reason surfaces as a clear error, not an empty reply")


func _test_stream_error() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var events := _events(adapter, [_sse({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})])
	var error: Dictionary = _event_of(events, "error")
	_check(String(error.get("message", "")) == "overloaded_error: Overloaded", "a stream error event reports the error's type and the endpoint's message")


func _test_stop_reasons() -> void:
	# A token-capped reply once rendered as a finished answer on every adapter; the done event's `stop` is what keeps that honest, so pin each provider's cap value canonicalizing to "length" and its normal ends to "".
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var events := _events(adapter, [
		_sse({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
		_sse({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Half an ans"}}),
		_sse({"type": "message_delta", "delta": {"stop_reason": "max_tokens"}, "usage": {"output_tokens": 7}}),
		_sse({"type": "message_stop"}),
	])
	_check(String(_event_of(events, "done").get("stop", "?")) == "length", "anthropic max_tokens canonicalizes to the length stop")
	adapter = LLMAdapters.AnthropicAdapter.new()
	events = _events(adapter, [
		_sse({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 7}}),
		_sse({"type": "message_stop"}),
	])
	_check(String(_event_of(events, "done").get("stop", "?")) == "", "anthropic end_turn is a normal finish")
	adapter = LLMAdapters.AnthropicAdapter.new()
	events = _events(adapter, [
		_sse({"type": "message_delta", "delta": {"stop_reason": "model_context_window_exceeded"}, "usage": {}}),
		_sse({"type": "message_stop"}),
	])
	_check(String(_event_of(events, "done").get("stop", "?")) == "model_context_window_exceeded", "an unexpected anthropic stop reason passes through verbatim")
	var openai := LLMAdapters.OpenAIAdapter.new()
	events = _events(openai, [
		_sse({"choices": [{"delta": {"content": "Half"}, "finish_reason": null}]}),
		_sse({"choices": [{"delta": {}, "finish_reason": "length"}]}),
		"data: [DONE]",
	])
	_check(String(_event_of(events, "done").get("stop", "?")) == "length", "openai finish_reason length rides the done event")
	openai = LLMAdapters.OpenAIAdapter.new()
	events = _events(openai, [_sse({"choices": [{"delta": {"content": "All done."}, "finish_reason": "stop"}]})])
	_check(String(_event_of(events, "done").get("stop", "?")) == "", "openai finish_reason stop is a normal finish")
	var ollama := LLMAdapters.OllamaAdapter.new()
	events = _events(ollama, [JSON.stringify({"message": {"content": "Half"}, "done": true, "done_reason": "length"})])
	_check(String(_event_of(events, "done").get("stop", "?")) == "length", "ollama done_reason length (the num_predict cap) rides the done event")
	ollama = LLMAdapters.OllamaAdapter.new()
	events = _events(ollama, [JSON.stringify({"message": {"content": "All."}, "done": true, "done_reason": "stop"})])
	_check(String(_event_of(events, "done").get("stop", "?")) == "", "ollama done_reason stop is a normal finish")


func _test_models_and_completion() -> void:
	var adapter := LLMAdapters.AnthropicAdapter.new()
	var names := adapter.parse_models({"data": [{"id": "claude-opus-4-8"}, {"id": "claude-haiku-4-5"}], "has_more": false})
	_check(names.size() == 2 and names.has("claude-opus-4-8"), "the model list parses out of the data array")
	var req: Dictionary = adapter.completion_request("claude-haiku-4-5", "Be brief.", "Title this chat")
	_check(String(req.get("path", "")) == "/v1/messages", "completions post to the messages endpoint")
	var body: Dictionary = req.get("body", {})
	_check(String(body.get("system", "")) == "Be brief." and int(body.get("max_tokens", 0)) > 0 and not body.has("stream"), "the completion body is a one-shot request with system + max_tokens")
	var reply := adapter.parse_completion({"content": [
		{"type": "thinking", "thinking": "hmm", "signature": "s"},
		{"type": "text", "text": "A Good Title"},
	]})
	_check(reply == "A Good Title", "parse_completion skips thinking blocks to the first text block")


func _test_output_caps() -> void:
	# Caps ride the static registry, so later fresh instances must see what an earlier sweep's parse captured; floats mirror JSON-parsed numbers.
	LLMAdapters.AnthropicAdapter.new().parse_models({"data": [
		{"id": "claude-opus-4-8", "max_tokens": 128000.0, "max_input_tokens": 1000000.0},
		{"id": "claude-opus-4-1", "max_tokens": 32000.0},
		{"id": "claude-uncapped-entry"},
	]})
	var user_turn: Array = [{"role": "user", "content": "Hi"}]
	var body: Dictionary = LLMAdapters.AnthropicAdapter.new().build_chat_body("claude-opus-4-1", user_turn, [])
	_check(int(body.get("max_tokens", 0)) == 32000, "a chat request sends the output cap /v1/models reported for its model")
	body = LLMAdapters.AnthropicAdapter.new().build_chat_body("claude-opus-4-8", user_turn, [])
	_check(int(body.get("max_tokens", 0)) == 128000, "caps are per model, not one shared value")
	body = LLMAdapters.AnthropicAdapter.new().build_chat_body("claude-never-swept", user_turn, [])
	_check(int(body.get("max_tokens", 0)) == LLMAdapters.AnthropicAdapter.CHAT_MAX_TOKENS, "a model no sweep has seen falls back to the 64K constant")
	body = LLMAdapters.AnthropicAdapter.new().build_chat_body("claude-uncapped-entry", user_turn, [])
	_check(int(body.get("max_tokens", 0)) == LLMAdapters.AnthropicAdapter.CHAT_MAX_TOKENS, "an entry that reported no max_tokens keeps the fallback")


func _test_ollama_strips_foreign_fields() -> void:
	var adapter := LLMAdapters.OllamaAdapter.new()
	var messages: Array = [
		{"role": "user", "content": "Hi"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {}}}], "assistant_blocks": [{"type": "text", "text": "x"}]},
	]
	var body: Dictionary = adapter.build_chat_body("some-model", messages, [])
	var wire: Array = body.get("messages", [])
	_check(wire.size() == 2 and not wire[1].has("assistant_blocks"), "Ollama never receives another provider's echo blocks")
	_check(messages[1].has("assistant_blocks"), "stripping copies the message instead of mutating history")


func _test_context_probe() -> void:
	var anthropic := LLMAdapters.AnthropicAdapter.new()
	var probe: Dictionary = anthropic.context_probe("claude-opus-4-8")
	_check(String(probe.get("path", "")) == "/v1/models/claude-opus-4-8" and int(probe.get("method", -1)) == HTTPClient.METHOD_GET, "anthropic probes the single-model retrieve endpoint")
	_check(anthropic.parse_context_window({"id": "claude-opus-4-8", "max_input_tokens": 1000000.0, "max_tokens": 128000.0}) == 1000000, "anthropic reads max_input_tokens as the window")
	_check(anthropic.parse_context_window({"id": "claude-x"}) == 0, "an entry without the field stays unknown")
	var ollama := LLMAdapters.OllamaAdapter.new()
	probe = ollama.context_probe("glm-5.2")
	var probe_body: Dictionary = probe.get("body", {})
	_check(String(probe.get("path", "")) == "/api/show" and int(probe.get("method", -1)) == HTTPClient.METHOD_POST and String(probe_body.get("model", "")) == "glm-5.2", "ollama probes /api/show for the model")
	_check(ollama.parse_context_window({"model_info": {"glm5.2.context_length": 1000000.0, "glm5.2.embedding_length": 0.0}}) == 1000000, "ollama reads the architecture context_length out of model_info")
	_check(ollama.parse_context_window({"parameters": "num_ctx 8192\nstop \"x\"", "model_info": {"llama.context_length": 131072.0}}) == 8192, "a Modelfile num_ctx wins as the configured serving window")
	_check(ollama.parse_context_window({"parameters": null, "model_info": {"llama.context_length": 131072.0}}) == 131072, "a null parameters field falls through to model_info")
	_check(ollama.parse_context_window({}) == 0, "an empty body stays unknown")
	var openai := LLMAdapters.OpenAIAdapter.new()
	var openai_probe: Dictionary = openai.context_probe("some-model")
	_check(String(openai_probe.get("path", "")) == "/models" and int(openai_probe.get("method", -1)) == HTTPClient.METHOD_GET, "openai-compatible probes the /v1/models list")
	var models_body := {"data": [
		{"id": "other-model", "max_model_len": 8192.0},
		{"id": "vllm-model", "max_model_len": 131072.0},
	]}
	_check(openai.parse_context_window(models_body, "vllm-model") == 131072, "vLLM's max_model_len is read from the target model's list entry")
	_check(openai.parse_context_window({"data": [{"id": "or-model", "context_length": 200000.0}]}, "or-model") == 200000, "OpenRouter's context_length is recognized")
	_check(openai.parse_context_window({"data": [{"id": "groq-model", "context_window": 32768.0}]}, "groq-model") == 32768, "Groq's context_window is recognized")
	_check(openai.parse_context_window(models_body, "absent-model") == 0, "a model not in the list stays unknown")
	_check(openai.parse_context_window({"data": [{"id": "plain-model"}]}, "plain-model") == 0, "an entry with no window field stays unknown")


func _test_normalize_base() -> void:
	var ollama := LLMAdapters.OllamaAdapter.new()
	_check(ollama.normalize_base("http://localhost:11434") == "http://localhost:11434", "an ollama bare host:port passes through")
	_check(ollama.normalize_base(" http://localhost:11434/ ") == "http://localhost:11434", "whitespace and trailing slashes are trimmed")
	_check(ollama.normalize_base("http://localhost:11434/api/chat") == "http://localhost:11434", "a pasted ollama chat endpoint reduces to its root")
	_check(ollama.normalize_base("http://localhost:11434/api/tags") == "http://localhost:11434", "a pasted ollama tags endpoint reduces to its root")
	_check(ollama.normalize_base("http://localhost:11434/api") == "http://localhost:11434", "a pasted bare /api reduces to its root")
	_check(ollama.normalize_base("https://gw.example/ollama") == "https://gw.example/ollama", "an unrecognized path is kept as a proxy prefix")
	var openai := LLMAdapters.OpenAIAdapter.new()
	_check(openai.normalize_base("http://localhost:1234") == "http://localhost:1234/v1", "an openai pathless base gets /v1 appended")
	_check(openai.normalize_base("http://localhost:1234/v1") == "http://localhost:1234/v1", "an openai /v1 base is respected as-is")
	_check(openai.normalize_base("http://localhost:1234/v1/chat/completions") == "http://localhost:1234/v1", "a pasted openai chat endpoint reduces to its /v1 base")
	_check(openai.normalize_base("http://localhost:1234/v1/models") == "http://localhost:1234/v1", "a pasted openai models endpoint reduces to its /v1 base")
	_check(openai.normalize_base("http://localhost:1234/chat/completions") == "http://localhost:1234/v1", "a v1-less pasted chat endpoint reduces to the root and regains /v1")
	_check(openai.normalize_base("https://gw.example/llm/v1") == "https://gw.example/llm/v1", "an openai gateway prefix is respected as-is")
	var anthropic := LLMAdapters.AnthropicAdapter.new()
	_check(anthropic.normalize_base("https://api.anthropic.com") == "https://api.anthropic.com", "an anthropic bare base passes through")
	_check(anthropic.normalize_base("https://api.anthropic.com/v1/messages") == "https://api.anthropic.com", "a pasted anthropic messages endpoint reduces to its root")
	_check(anthropic.normalize_base("https://api.anthropic.com/v1") == "https://api.anthropic.com", "a pasted /v1 base reduces to the root the /v1/… paths rejoin")
	_check(anthropic.normalize_base("https://gw.example/anthropic/v1/messages") == "https://gw.example/anthropic", "a gateway-prefixed endpoint keeps its prefix as the root")
