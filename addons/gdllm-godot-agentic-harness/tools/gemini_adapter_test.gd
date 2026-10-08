extends SceneTree
## Headless regression tests for GeminiAdapter: request-body translation (systemInstruction lift, functionDeclarations with the JSON Schema as written, role alternation with parallel results merged into one user turn, functionResponse binding by name and id, the trailing-loop raw-part echo and its rebuild/kind-switch fallbacks, the tool-less flatten, the thinking config per effort), the SSE stream reassembly (thought vs answer text, whole functionCall parts, signature-preserving part joining, usage, finish reasons, blocked prompts, error frames), the model list and window probe, the completion helpers, auth and the client header, and base normalization.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/gemini_adapter_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const LLMAdapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")

## A minimal attached tool, so a test request carries tools — without one the adapter flattens tool turns to text (see _test_toolless_flatten).
const SOME_TOOLS: Array = [{"type": "function", "function": {"name": "read_file", "description": "Read a file.", "parameters": {"type": "object", "properties": {"path": {"type": "string", "minLength": 1}}, "required": ["path"], "additionalProperties": false}}}]

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_chat_body_basics()
	_test_thinking_config()
	_test_tool_translation()
	_test_parallel_results_merge()
	_test_trailing_loop_echo()
	_test_echo_fallbacks()
	_test_toolless_flatten()
	_test_stream_text_and_thinking()
	_test_stream_tool_calls()
	_test_part_joining()
	_test_stream_stops()
	_test_stream_failures()
	_test_models_and_probe()
	_test_completion()
	_test_auth_and_paths()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Feed each line to the adapter and collect every canonical event, the way LLMClient's stream loop does.
func _events(adapter: LLMAdapters.GeminiAdapter, lines: Array) -> Array:
	var events: Array = []
	for line in lines:
		events.append_array(adapter.parse_line(line))
	return events


func _frame(parts: Array, finish: String = "", usage: Dictionary = {}) -> String:
	var candidate := {"content": {"role": "model", "parts": parts}}
	if finish != "":
		candidate["finishReason"] = finish
	var data := {"candidates": [candidate]}
	if not usage.is_empty():
		data["usageMetadata"] = usage
	return "data: " + JSON.stringify(data)


func _types(events: Array) -> Array:
	return events.map(func(e: Dictionary) -> String: return String(e["type"]))


## A one-call tool loop in progress: user asks, the model calls read_file, the result comes back.
func _loop_history(blocks: Variant) -> Array:
	var turn := {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "res://a.gd"}}}]}
	if blocks != null:
		turn["assistant_blocks"] = blocks
	return [
		{"role": "system", "content": "You are helpful."},
		{"role": "user", "content": "read a.gd"},
		turn,
		{"role": "tool", "content": "extends Node", "tool_name": "read_file"},
	]


func _signed_parts() -> Array:
	return [{"text": "Let me look.", "thought": true}, {"functionCall": {"id": "fc-1", "name": "read_file", "args": {"path": "res://a.gd"}}, "thoughtSignature": "c2ln"}]


func _test_chat_body_basics() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var body := adapter.build_chat_body("gemini-3.8-flash", [{"role": "system", "content": "Be brief."}, {"role": "user", "content": "hi"}, {"role": "assistant", "content": ""}, {"role": "user", "content": "again"}], [])
	_check(body["systemInstruction"] == {"parts": [{"text": "Be brief."}]}, "the system prompt rides as systemInstruction")
	var contents: Array = body["contents"]
	_check(contents.size() == 3 and contents[0]["role"] == "user" and contents[1]["role"] == "model", "the system turn is lifted out and the assistant speaks as \"model\"")
	_check(contents[1]["parts"] == [{"text": "(empty)"}], "a blank assistant echo becomes a placeholder, never an empty text part")
	_check(not body.has("tools"), "a tool-less request declares no tools")
	_check(adapter.chat_path() == "/models/gemini-3.8-flash:streamGenerateContent?alt=sse", "the chat path names the model the body was built for")
	adapter.build_chat_body("models/gemini-3.8-flash", [{"role": "user", "content": "hi"}], [])
	_check(adapter.chat_path() == "/models/gemini-3.8-flash:streamGenerateContent?alt=sse", "a models/-prefixed id isn't doubled in the path")


func _test_thinking_config() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var msgs := [{"role": "user", "content": "hi"}]
	_check(adapter.build_chat_body("m", msgs, [])["generationConfig"] == {"thinkingConfig": {"includeThoughts": true}}, "default effort sends no level but still asks for the reasoning summary")
	_check(adapter.build_chat_body("m", msgs, [], "high")["generationConfig"]["thinkingConfig"] == {"includeThoughts": true, "thinkingLevel": "high"}, "a level rides thinkingConfig.thinkingLevel, inside the config")
	_check(adapter.build_chat_body("m", msgs, [], "none")["generationConfig"]["thinkingConfig"] == {"thinkingBudget": 0}, "\"none\" is a zero budget, never combined with a level")


func _test_tool_translation() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var body := adapter.build_chat_body("m", _loop_history(null), SOME_TOOLS)
	var decl: Dictionary = body["tools"][0]["functionDeclarations"][0]
	_check(decl["name"] == "read_file" and decl["description"] == "Read a file.", "a tool becomes a function declaration")
	_check(decl["parametersJsonSchema"] == SOME_TOOLS[0]["function"]["parameters"], "the schema rides parametersJsonSchema exactly as written")
	var contents: Array = body["contents"]
	_check(contents[1] == {"role": "model", "parts": [{"functionCall": {"name": "read_file", "args": {"path": "res://a.gd"}}}]}, "a call with no stored parts rebuilds as a functionCall part")
	_check(contents[2] == {"role": "user", "parts": [{"functionResponse": {"name": "read_file", "response": {"output": "extends Node"}}}]}, "its result binds by name, the text unparsed under output")
	var json_result := _loop_history(null)
	json_result[3]["content"] = "{\"big\": 12345678901234567890}"
	var response: Dictionary = adapter.build_chat_body("m", json_result, SOME_TOOLS)["contents"][2]["parts"][0]["functionResponse"]["response"]
	_check(response["output"] == "{\"big\": 12345678901234567890}", "a JSON-looking result reaches the model byte-for-byte")


func _test_parallel_results_merge() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var history := [
		{"role": "user", "content": "read both"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "a"}}}, {"function": {"name": "list_dir", "arguments": {}}}]},
		{"role": "tool", "content": "A", "tool_name": "read_file"},
		{"role": "tool", "content": "B", "tool_name": "list_dir"},
		{"role": "user", "content": "now what?"},
	]
	var contents: Array = adapter.build_chat_body("m", history, SOME_TOOLS)["contents"]
	_check(contents.size() == 3, "parallel results and the next user line fold into one user turn, so roles alternate (got %d turns)" % contents.size())
	var parts: Array = contents[2]["parts"]
	_check(parts.size() == 3 and parts[0]["functionResponse"]["name"] == "read_file" and parts[1]["functionResponse"]["name"] == "list_dir" and parts[2] == {"text": "now what?"}, "each result keeps its call's name, in order")


func _test_trailing_loop_echo() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var contents: Array = adapter.build_chat_body("m", _loop_history(_signed_parts()), SOME_TOOLS)["contents"]
	_check(contents[1]["parts"] == _signed_parts(), "inside the trailing loop the stored parts replay verbatim, thought and signature included")
	_check(contents[2]["parts"][0]["functionResponse"].get("id") == "fc-1", "the result echoes the call's id when the model gave one")


func _test_echo_fallbacks() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var history := _loop_history(_signed_parts())
	history.append({"role": "assistant", "content": "It extends Node."})
	history.append({"role": "user", "content": "thanks"})
	var contents: Array = adapter.build_chat_body("m", history, SOME_TOOLS)["contents"]
	_check(contents[1]["parts"] == [{"functionCall": {"name": "read_file", "args": {"path": "res://a.gd"}}}], "a turn before the last user message rebuilds, so past signatures and thoughts aren't re-sent")
	var anthropic := [{"type": "thinking", "thinking": "...", "signature": "x"}, {"type": "tool_use", "id": "toolu_1", "name": "read_file", "input": {}}]
	contents = adapter.build_chat_body("m", _loop_history(anthropic), SOME_TOOLS)["contents"]
	_check(contents[1]["parts"][0].has("functionCall") and not contents[1]["parts"][0].has("type"), "blocks recorded under another kind fall through to the rebuild")
	var openai := [{"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]
	contents = adapter.build_chat_body("m", _loop_history(openai), SOME_TOOLS)["contents"]
	_check(contents[1]["parts"][0].has("functionCall") and not contents[1]["parts"][0].has("id"), "OpenAI-shaped tool calls stored under the Chat Completions kind fall through too")


func _test_toolless_flatten() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var contents: Array = adapter.build_chat_body("m", _loop_history(_signed_parts()), [])["contents"]
	var model_text := String(contents[1]["parts"][0].get("text", ""))
	_check(model_text.contains("[called read_file("), "with no tools declared, a call turn flattens to text")
	_check(String(contents[2]["parts"][0].get("text", "")).begins_with("[read_file result]"), "and its result to a labeled user line")
	var any_tool_part := false
	for content in contents:
		for part in content["parts"]:
			if part.has("functionCall") or part.has("functionResponse"):
				any_tool_part = true
	_check(not any_tool_part, "no functionCall/functionResponse part reaches a request that declares no tools")


func _test_stream_text_and_thinking() -> void:
	var events := _events(LLMAdapters.GeminiAdapter.new(), [
		_frame([{"text": "Considering", "thought": true}]),
		_frame([{"text": "Hello"}]),
		_frame([{"text": " there"}], "STOP", {"promptTokenCount": 10, "candidatesTokenCount": 3, "thoughtsTokenCount": 7}),
	])
	_check(_types(events) == ["thinking", "content", "content", "done"], "thought parts stream as thinking and the rest as content (got %s)" % [_types(events)])
	var done: Dictionary = events[-1]
	_check(done["stop"] == "" and int(done["stats"]["tokens_in"]) == 10 and int(done["stats"]["tokens_out"]) == 10, "STOP is a normal end, and output tokens count the thinking too")


func _test_stream_tool_calls() -> void:
	var events := _events(LLMAdapters.GeminiAdapter.new(), [
		_frame([{"text": "Checking.", "thought": true}]),
		_frame([{"functionCall": {"id": "fc-1", "name": "read_file", "args": {"path": "a"}}, "thoughtSignature": "c2ln"}, {"functionCall": {"id": "fc-2", "name": "list_dir", "args": {}}}], "STOP"),
	])
	_check(_types(events) == ["thinking", "assistant_blocks", "tool_calls", "done"], "a call turn emits its raw parts ahead of the calls (got %s)" % [_types(events)])
	var calls: Array = events[2]["calls"]
	_check(calls == [{"function": {"name": "read_file", "arguments": {"path": "a"}}}, {"function": {"name": "list_dir", "arguments": {}}}], "each functionCall part is one canonical call")
	var blocks: Array = events[1]["blocks"]
	_check(blocks.size() == 3 and blocks[1]["thoughtSignature"] == "c2ln" and not blocks[2].has("thoughtSignature"), "the raw parts keep each signature on its own part")
	var plain := _events(LLMAdapters.GeminiAdapter.new(), [_frame([{"text": "hi"}], "STOP")])
	_check(not _types(plain).has("assistant_blocks"), "a turn without calls stores no blocks")


func _test_part_joining() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	_events(adapter, [
		_frame([{"text": "Think ", "thought": true}]),
		_frame([{"text": "more", "thought": true, "thoughtSignature": "s1"}]),
		_frame([{"text": "next", "thought": true}]),
		_frame([{"text": "Answer"}]),
		_frame([{"functionCall": {"name": "read_file", "args": {}}}], "STOP"),
	])
	var parts: Array = adapter._parts
	_check(parts.size() == 4, "adjacent pieces of one kind join, a signature closes its run, and text kinds stay apart (got %d parts)" % parts.size())
	_check(parts[0] == {"text": "Think more", "thought": true, "thoughtSignature": "s1"}, "the run's signature stays on the joined part")
	_check(parts[1]["text"] == "next" and parts[2] == {"text": "Answer"}, "text after a signature starts a new part")


func _test_stream_stops() -> void:
	var capped := _events(LLMAdapters.GeminiAdapter.new(), [_frame([{"text": "partial"}], "MAX_TOKENS")])
	_check(capped[-1]["stop"] == "length", "MAX_TOKENS is the output cap")
	var malformed := _events(LLMAdapters.GeminiAdapter.new(), [_frame([], "MALFORMED_FUNCTION_CALL")])
	_check(malformed[-1]["type"] == "done" and malformed[-1]["stop"] == "MALFORMED_FUNCTION_CALL", "any other finish reason is disclosed verbatim")
	var adapter := LLMAdapters.GeminiAdapter.new()
	var twice := _events(adapter, [_frame([{"text": "x"}], "STOP"), _frame([], "STOP")])
	_check(_types(twice).count("done") == 1, "a trailing frame can't emit a second done")


func _test_stream_failures() -> void:
	var blocked := _events(LLMAdapters.GeminiAdapter.new(), ["data: " + JSON.stringify({"promptFeedback": {"blockReason": "SAFETY"}, "usageMetadata": {"promptTokenCount": 5}})])
	_check(blocked.size() == 1 and blocked[0]["type"] == "error" and String(blocked[0]["message"]).contains("SAFETY"), "a blocked prompt fails naming the reason, without crashing on the missing candidates")
	var usage_only := _events(LLMAdapters.GeminiAdapter.new(), ["data: " + JSON.stringify({"usageMetadata": {"promptTokenCount": 5}})])
	_check(_types(usage_only) == ["progress"], "a usage-only frame is recognized as progress")
	var err := _events(LLMAdapters.GeminiAdapter.new(), ["data: " + JSON.stringify([{"error": {"code": 400, "message": "Request contains an invalid argument.", "status": "INVALID_ARGUMENT"}}])])
	_check(err.size() == 1 and err[0]["type"] == "error" and String(err[0]["message"]).contains("invalid argument") and String(err[0]["message"]).contains("INVALID_ARGUMENT"), "an error frame, list-wrapped or not, surfaces with its status")
	_check(LLMAdapters.GeminiAdapter.new().parse_line(": keepalive").is_empty() and LLMAdapters.GeminiAdapter.new().parse_line("data: not json").is_empty(), "non-data and unparseable lines are skipped")


func _test_models_and_probe() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var names := adapter.parse_models({"models": [
		{"name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent", "countTokens"]},
		{"name": "models/text-embedding-004", "supportedGenerationMethods": ["embedContent"]},
	]})
	_check(names == PackedStringArray(["gemini-3.8-flash"]), "only chat-capable models are listed, without the models/ prefix")
	_check(adapter.models_path() == "/models?pageSize=1000", "the list asks for a full page")
	var probe := adapter.context_probe("models/gemini-3.8-flash")
	_check(probe["path"] == "/models/gemini-3.8-flash" and probe["method"] == HTTPClient.METHOD_GET, "the window probe reads the model's own entry")
	_check(adapter.parse_context_window({"inputTokenLimit": 1048576}) == 1048576 and adapter.parse_context_window({}) == 0, "the window is inputTokenLimit, 0 when absent")


func _test_completion() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var req := adapter.completion_request("gemini-3.8-flash", "Title it.", "{\"chat\": 1}")
	_check(req["path"] == "/models/gemini-3.8-flash:generateContent", "the one-shot request uses the non-streamed method")
	_check(req["body"]["systemInstruction"] == {"parts": [{"text": "Title it."}]} and req["body"]["contents"][0]["parts"][0]["text"] == "{\"chat\": 1}", "and carries the system prompt and the prompt")
	var reply := {"candidates": [{"content": {"parts": [{"text": "musing", "thought": true}, {"text": "A Good "}, {"text": "Title"}]}}], "usageMetadata": {"promptTokenCount": 9, "candidatesTokenCount": 2}}
	_check(adapter.parse_completion(reply) == "A Good Title", "the reply joins answer text, leaving out thoughts")
	_check(adapter.parse_completion({"candidates": []}) == "" and adapter.parse_completion({}) == "", "a reply with no candidate is empty, not a crash")
	_check(int(adapter.parse_completion_stats(reply)["tokens_in"]) == 9, "completion usage maps through the same rule")


func _test_auth_and_paths() -> void:
	var adapter := LLMAdapters.GeminiAdapter.new()
	var headers := adapter.auth_headers(" AIzaTest ")
	_check(headers.has("x-goog-api-key: AIzaTest"), "the key rides x-goog-api-key")
	_check(not "".join(headers).contains("Bearer"), "never as a Bearer token")
	var client := LLMAdapters.GeminiAdapter.client_header()
	_check(client.begins_with("gdllm/") and headers.has("x-goog-api-client: " + client), "requests name this harness to Google as gdllm/<version> (got %s)" % client)
	_check(adapter.normalize_base("https://generativelanguage.googleapis.com/v1beta") == "https://generativelanguage.googleapis.com/v1beta", "the base is respected as-is")
	_check(adapter.normalize_base("https://generativelanguage.googleapis.com") == "https://generativelanguage.googleapis.com/v1beta", "a bare host gains /v1beta")
	_check(adapter.normalize_base("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse") == "https://generativelanguage.googleapis.com/v1beta", "a pasted endpoint reduces to the base")
	_check(LLMAdapters.for_kind(GDLLMSources.KIND_GEMINI) is LLMAdapters.GeminiAdapter, "the gemini kind builds this adapter")
