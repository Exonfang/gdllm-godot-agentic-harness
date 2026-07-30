extends SceneTree
## Headless regression tests for in-stream failure reporting: the OpenAI-compatible, Ollama, and Anthropic adapters' error frames and LLMClient's end-of-stream failure attribution.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/stream_error_test.gd
## Exits nonzero on any failure. Only adapter parsing and the client's stream-state folding are exercised; no socket is opened.
##
## What these guard: an OpenAI-compatible server reports its own failures (context overflow included) as a data: {"error": ...} frame, usually followed by a trailing [DONE]. Discarding the frame turned the failure into a green "(empty response)" bubble — and while this adapter's API reports no window, that frame is the only reactive overflow signal compaction has there. The end-of-stream split matters the same way: "Connection closed before any reply arrived." collapsed a socket drop, a wrong API type, and a mid-reply cutoff into one message that named no endpoint and pointed at no lever.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Adapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")
const Client = preload("res://addons/gdllm-godot-agentic-harness/llm_client.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_error_frame_dict_surfaces_message()
	_test_error_frame_string_surfaces_verbatim()
	_test_error_frame_without_message_keeps_payload()
	_test_normal_frames_still_parse()
	_test_error_outranks_trailing_done()
	_test_cutoff_mid_reply_is_named()
	_test_wire_mismatch_is_named()
	_test_silent_close_is_named()
	_test_ollama_error_frame_string_surfaces_verbatim()
	_test_ollama_error_frame_dict_surfaces_message()
	_test_ollama_error_frame_without_message_keeps_payload()
	_test_anthropic_error_frame_keeps_type_and_message()
	_test_anthropic_error_frame_string_surfaces_verbatim()
	_test_anthropic_error_frame_without_message_keeps_frame()
	_test_ollama_null_message_fields_survive()
	_test_completion_parse_failure_names_the_shape()
	_test_completion_parse_failure_excerpt_is_capped()
	_test_completion_body_reaches_the_failure()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_error_frame_dict_surfaces_message() -> void:
	var events: Array = Adapters.OpenAIAdapter.new().parse_line('data: {"error": {"message": "This model\'s maximum context length is 8192 tokens.", "type": "invalid_request_error"}}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "error", "a dict error frame yields one error event")
	_check(String(events[0].get("message", "")).contains("maximum context length"), "the provider's message rides the event verbatim")


func _test_error_frame_string_surfaces_verbatim() -> void:
	# Some compatible servers send the error as a bare string rather than the OpenAI object.
	var events: Array = Adapters.OpenAIAdapter.new().parse_line('data: {"error": "model not found"}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "error", "a string error frame yields one error event")
	_check(String(events[0].get("message", "")) == "model not found", "the bare string is the message")


func _test_error_frame_without_message_keeps_payload() -> void:
	var events: Array = Adapters.OpenAIAdapter.new().parse_line('data: {"error": {"code": 503}}')
	_check(events.size() == 1 and String(events[0].get("message", "")).contains("503"), "a message-less error falls back to the raw frame rather than an empty report")


func _test_normal_frames_still_parse() -> void:
	var adapter = Adapters.OpenAIAdapter.new()
	var events: Array = adapter.parse_line('data: {"choices": [{"delta": {"content": "hi"}}]}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "content", "an ordinary delta frame is untouched by the error check")


## The full regression: error frame then trailing [DONE] through the real client pipeline must fail loudly, not finish as an empty success.
func _test_error_outranks_trailing_done() -> void:
	var client: Node = Client.new()
	client.api_base = "http://box:8000/v1"
	var failed: Array = []
	var replied: Array = []
	client.request_failed.connect(func(reason: String) -> void: failed.append(reason))
	client.response_received.connect(func(text: String, _stats: Dictionary) -> void: replied.append(text))
	client._streaming = true
	client._stream_adapter = Adapters.OpenAIAdapter.new()
	client._handle_stream_line('data: {"error": {"message": "context length exceeded"}}')
	client._handle_stream_line("data: [DONE]")
	client._finish_stream()
	_check(failed.size() == 1 and String(failed[0]).contains("context length exceeded"), "the error frame reaches request_failed past the trailing [DONE]")
	_check(replied.is_empty(), "no empty-success response_received fires")
	client.free()


## Build a client in the "stream ended with nothing usable" state and return the failure message it reports.
func _finish_message(received_body: bool, est_out_chars: int) -> String:
	var client: Node = Client.new()
	client.api_base = "http://box:8000/v1"
	var failed: Array = []
	client.request_failed.connect(func(reason: String) -> void: failed.append(reason))
	client._streaming = true
	client._stream_received_body = received_body
	client._stream_est_out_chars = est_out_chars
	client._finish_stream()
	client.free()
	return String(failed[0]) if failed.size() == 1 else ""


func _test_cutoff_mid_reply_is_named() -> void:
	# Thinking streamed (est chars counted) but no content and no terminal marker: a cutoff, not a format problem.
	var message := _finish_message(true, 120)
	_check(message.contains("mid-reply") and message.contains("http://box:8000/v1"), "a cutoff after parsed events names the endpoint and the cutoff, got: %s" % message)


func _test_wire_mismatch_is_named() -> void:
	var message := _finish_message(true, 0)
	_check(message.contains("wire format") and message.contains("Connections dialog"), "body bytes no adapter event came from point at the source's API type, got: %s" % message)
	_check(message.contains("http://box:8000/v1"), "the mismatch report names the endpoint")


func _test_silent_close_is_named() -> void:
	var message := _finish_message(false, 0)
	_check(message.contains("before any reply arrived") and message.contains("http://box:8000/v1"), "a silent close names the endpoint, got: %s" % message)


func _test_ollama_error_frame_string_surfaces_verbatim() -> void:
	var events: Array = Adapters.OllamaAdapter.new().parse_line('{"error": "model requires more system memory"}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "error", "Ollama's own bare-string error frame yields one error event")
	_check(String(events[0].get("message", "")) == "model requires more system memory", "the bare string is the message")


## The regression: a proxy in front of Ollama normalizes errors to the OpenAI object, which the old String() stringify threw on, dropping the frame entirely.
func _test_ollama_error_frame_dict_surfaces_message() -> void:
	var events: Array = Adapters.OllamaAdapter.new().parse_line('{"error": {"message": "context length exceeded", "type": "invalid_request_error"}}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "error", "a nested error frame on the Ollama wire yields one error event rather than throwing")
	_check(String(events[0].get("message", "")) == "context length exceeded", "the proxy's message rides the event, not a stringified dict")


func _test_ollama_error_frame_without_message_keeps_payload() -> void:
	var events: Array = Adapters.OllamaAdapter.new().parse_line('{"error": {"code": 503}}')
	_check(events.size() == 1 and String(events[0].get("message", "")).contains("503"), "a message-less error falls back to the raw frame rather than an empty report")


## Anthropic error frames always carry error.type and usually error.message; the type IS the cause (overloaded_error, rate_limit_error), so it must survive into the report.
func _test_anthropic_error_frame_keeps_type_and_message() -> void:
	var events: Array = Adapters.AnthropicAdapter.new().parse_line('data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "error", "an Anthropic error frame yields one error event")
	_check(String(events[0].get("message", "")).contains("overloaded_error") and String(events[0].get("message", "")).contains("Overloaded"), "both the error type and the message ride the event, got: %s" % String(events[0].get("message", "")))


func _test_anthropic_error_frame_string_surfaces_verbatim() -> void:
	# A proxy in front of the Anthropic wire (LiteLLM and friends) can flatten the error to a bare string.
	var events: Array = Adapters.AnthropicAdapter.new().parse_line('data: {"type": "error", "error": "upstream timeout"}')
	_check(events.size() == 1 and String(events[0].get("message", "")) == "upstream timeout", "a bare-string error is the message, not a generic label")


func _test_anthropic_error_frame_without_message_keeps_frame() -> void:
	var typed: Array = Adapters.AnthropicAdapter.new().parse_line('data: {"type": "error", "error": {"type": "api_error"}}')
	_check(typed.size() == 1 and String(typed[0].get("message", "")) == "api_error", "a message-less error still names its type")
	var bare: Array = Adapters.AnthropicAdapter.new().parse_line('data: {"type": "error"}')
	_check(bare.size() == 1 and String(bare[0].get("message", "")).contains("\"error\""), "a degenerate frame falls back to the raw frame rather than a generic label, got: %s" % String(bare[0].get("message", "")))


## An explicit null in a message field is the same throw one field over — Ollama omits these keys, but a compatible server can send them null.
func _test_ollama_null_message_fields_survive() -> void:
	var events: Array = Adapters.OllamaAdapter.new().parse_line('{"message": {"thinking": null, "content": "hi"}}')
	_check(events.size() == 1 and String(events[0].get("type", "")) == "content", "a null thinking field is coerced away, leaving the content event")
	_check(String(events[0].get("text", "")) == "hi", "the content survives intact")


## A 200 whose body isn't JSON is a background chore's only symptom, so the failure names what actually answered instead of reporting the parser's verdict ("JSON parse error", which named no endpoint and pointed at no lever).
func _test_completion_parse_failure_names_the_shape() -> void:
	var base := "http://box:8000/v1"
	var empty: String = Client._completion_parse_failure(base, "  \n ")
	_check(empty.contains("empty body") and empty.contains(base), "an empty body says so and names the endpoint, got: %s" % empty)
	var sse: String = Client._completion_parse_failure(base, "data: {\"choices\": []}\n\ndata: [DONE]")
	_check(sse.contains("streamed") and sse.contains("Connections dialog"), "an SSE body reads as a streamed answer to an unstreamed request, got: %s" % sse)
	var html: String = Client._completion_parse_failure(base, "<!doctype html>\n<html><body>401 Unauthorized</body></html>")
	_check(html.contains("markup") and html.contains("401 Unauthorized"), "markup says something other than the API answered and quotes it, got: %s" % html)
	var junk: String = Client._completion_parse_failure(base, "upstream connect error")
	_check(junk.contains(base) and junk.contains("upstream connect error"), "any other shape still names the endpoint and quotes the body, got: %s" % junk)


## The excerpt lands in the user's log verbatim, so a page-sized body must not arrive with it.
func _test_completion_parse_failure_excerpt_is_capped() -> void:
	var page := "<html>" + "x".repeat(4000) + "</html>"
	var message: String = Client._completion_parse_failure("http://box:8000/v1", page)
	_check(message.length() < 500, "a page-sized body is capped rather than quoted whole, got %d chars" % message.length())
	_check(message.contains("…"), "the cap is disclosed with an ellipsis rather than a silent truncation")
	var wrapped: String = Client._completion_parse_failure("http://box:8000/v1", "line one\nline two\n\n\tline three")
	_check(not wrapped.contains("\n"), "the excerpt is flattened to one line so the log entry stays a single message")


## The Tasks-Model path is the only caller, and its failure is invisible unless the body reaches the message — so pin the wiring, not just the helper.
func _test_completion_body_reaches_the_failure() -> void:
	var client: Node = Client.new()
	client.api_base = "http://box:8000/v1"
	var failed: Array = []
	client.request_failed.connect(func(reason: String) -> void: failed.append(reason))
	client._on_request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), "<html>nope</html>".to_utf8_buffer())
	client.free()
	_check(failed.size() == 1 and String(failed[0]).contains("nope"), "a non-JSON 200 body reaches the emitted failure, got: %s" % failed)
