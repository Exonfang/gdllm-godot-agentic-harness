@tool
class_name LLMAdapter extends RefCounted
## Translates between the plugin's canonical (Ollama-native) message/tool shape and one provider's wire format.
## LLMClient owns the transport (socket, HTTP state machine); an adapter only says which path to hit, how to build a request body, and how to turn a streamed line back into canonical events.
## A fresh instance is built per request so a stateful format (OpenAI's tool-call argument fragments) can accumulate across lines.
## Subclasses: OllamaAdapter (near-identity — the canonical shape already IS Ollama's), OpenAIAdapter and AnthropicAdapter (translate at both edges).
##
## Canonical stream events an adapter emits from parse_line, folded straight onto LLMClient's state: {type:"thinking", text}, {type:"content", text}, {type:"tool_calls", calls}, {type:"done", stats, stop}, {type:"error", message}.
## A done event's `stop` is the provider's end-of-turn reason canonicalized by _canonical_stop: "" for a normal finish, "length" for the output-token cap, anything else verbatim — so a reply the provider itself cut short is never presented as finished (see LLMClient._stream_final_stats).
## A canonical tool call is {"function": {name, arguments: Dictionary}} — exactly what GDLLMTools.tool_call_name/args/sanitize_tool_calls consume.
## An adapter whose provider must see its own turn echoed verbatim to continue a tool loop (Anthropic) additionally emits {type:"assistant_blocks", blocks} ahead of the tool calls; LLMClient holds the blocks for the caller to store beside the turn (see LLMClient.last_assistant_blocks).


## Build the adapter for a source `kind` (see GDLLMSources.KIND_*). Unknown kinds fall back to Ollama.
static func for_kind(kind: String) -> LLMAdapter:
	if kind == GDLLMSources.KIND_OPENAI:
		return OpenAIAdapter.new()
	if kind == GDLLMSources.KIND_ANTHROPIC:
		return AnthropicAdapter.new()
	return OllamaAdapter.new()


## The request path for a streamed chat request.
func chat_path() -> String:
	return ""


## The JSON-ready body for a streamed chat turn, built from canonical `messages` (a leading system message included) and function-schema `tools`. `effort` is the user's reasoning-effort level (a GDLLMEfforts.LEVELS name; "" = default, meaning no knob is sent), which each adapter translates to its provider's own control: Ollama's `think`, OpenAI's `reasoning_effort`, Anthropic's `output_config.effort` (or disabled thinking for "none"). A level the provider or model doesn't accept fails loudly at request time — which is why the user-maintained config gates what's offered (see GDLLMEfforts). `cache_ttl` is the session's effective prompt-cache TTL in seconds (see GDLLMChatSession._cache_cold_gap_seconds); Anthropic is the only provider whose cache takes a requested lifetime, so the other adapters ignore it.
func build_chat_body(_model: String, _messages: Array, _tools: Array, _effort: String = "", _cache_ttl: int = 0) -> Dictionary:
	return {}


## Zero or more canonical events parsed out of one streamed line. Instance state may accumulate across calls (see OpenAIAdapter).
func parse_line(_line: String) -> Array:
	return []


## The request path for the model-list fetch.
func models_path() -> String:
	return ""


## Model names out of a parsed model-list response body.
func parse_models(_data: Variant) -> PackedStringArray:
	return PackedStringArray()


## The {path, method, body} request that asks this provider for `model`'s maximum context window, or {} when the provider offers nothing to ask — every shipped adapter overrides this with its own probe (see each kind's context_probe).
func context_probe(_model: String) -> Dictionary:
	return {}


## The maximum context window (input tokens) out of a parsed probe response body; 0 when the body carries none, so an unknown is never dressed up as a figure. `model` is the id the probe asked about, for a body (a model LIST) that answers for several at once — a single-model probe ignores it.
func parse_context_window(_data: Variant, _model: String = "") -> int:
	return 0


## The {path, body} for a one-shot (non-streamed) completion request.
func completion_request(_model: String, _system_prompt: String, _prompt: String) -> Dictionary:
	return {"path": "", "body": {}}


## The reply text out of a parsed completion response body.
func parse_completion(_data: Variant) -> String:
	return ""


## The usage counters out of a parsed completion response body, mapped onto the plugin's stat keys; {} when the body carries none.
func parse_completion_stats(_data: Variant) -> Dictionary:
	return {}


## The base URL as actually dialed: trimmed, trailing slashes dropped so joining an adapter path can't double the separator. Each subclass further reduces a pasted full endpoint to its server root (see _root_from_endpoint), so the URL a provider's UI hands out works as-is.
func normalize_base(base: String) -> String:
	var out := base.strip_edges()
	while out.ends_with("/"):
		out = out.trim_suffix("/")
	return out


## The server root behind a stored URL that may be a full endpoint rather than a base: the first matching known endpoint suffix is stripped, so the URL a provider's UI hands out (LM Studio's …/v1/chat/completions, Ollama's …/api/chat) works pasted as-is, while a URL carrying no known suffix — a bare host:port or one with a proxy prefix — passes through untouched for the adapter's own paths to join. `suffixes` must be ordered most-specific first; only the first match is stripped.
static func _root_from_endpoint(base: String, suffixes: Array) -> String:
	for suffix in suffixes:
		if base.ends_with(String(suffix)):
			return base.left(base.length() - String(suffix).length())
	return base


## The auth headers for a source's `api_key` — a Bearer token when set, none when empty. Shared by both wire formats (Ollama Cloud and the OpenAI-compatible providers all take `Authorization: Bearer`).
func auth_headers(api_key: String) -> PackedStringArray:
	if api_key.strip_edges() == "":
		return PackedStringArray()
	return PackedStringArray(["Authorization: Bearer " + api_key.strip_edges()])


## The provider's end-of-turn reason canonicalized for the done event's `stop`: "" for a normal finish (no reason reported, or one of the provider's `normal` values), "length" for the output-token cap under either of its wire names, and anything unexpected verbatim so it is still disclosed by name.
static func _canonical_stop(raw: String, normal: PackedStringArray) -> String:
	if raw == "" or normal.has(raw):
		return ""
	if raw == "length" or raw == "max_tokens":
		return "length"
	return raw


## Coerce a provider-supplied wire value to text. OpenAI-compatible servers (vLLM, Poolside) send null for id/name/content/reasoning in tool-call continuation deltas, and Godot's String() constructor throws on anything that isn't already a String, so route every wire-derived field through here.
static func _text(v: Variant) -> String:
	if v is String:
		return v
	if v == null:
		return ""
	return str(v)


## Native Ollama: /api/chat NDJSON, /api/tags, /api/generate. The canonical shapes are already Ollama's, so building and parsing are near pass-throughs.
class OllamaAdapter extends LLMAdapter:
	func chat_path() -> String:
		return "/api/chat"

	func build_chat_body(model: String, messages: Array, tools: Array, effort: String = "", _cache_ttl: int = 0) -> Dictionary:
		# stream:true makes Ollama emit newline-delimited JSON; with no effort selected, think is left unset so thinking-capable models still return reasoning while plain models don't error.
		var body := {"model": model, "messages": _without_foreign_fields(messages), "stream": true}
		# Ollama's knob is `think`: false disables reasoning outright, and a level name passes through as its string form (Ollama rejects a level the model doesn't take, which is why the user-maintained config gates what's offered — see GDLLMEfforts).
		if effort == "none":
			body["think"] = false
		elif effort != "":
			body["think"] = effort
		if not tools.is_empty():
			body["tools"] = tools
		return body

	## Messages with another provider's echo state dropped — an Anthropic tool loop stores raw `assistant_blocks` beside a turn (see AnthropicAdapter), which Ollama must never receive. Everything else passes through untouched, since the canonical shape is Ollama's own.
	func _without_foreign_fields(messages: Array) -> Array:
		var out: Array = []
		for msg in messages:
			if msg is Dictionary and msg.has("assistant_blocks"):
				var copy: Dictionary = msg.duplicate()
				copy.erase("assistant_blocks")
				out.append(copy)
			else:
				out.append(msg)
		return out

	func parse_line(line: String) -> Array:
		var json := JSON.new()
		if json.parse(line) != OK:
			return []
		var data: Variant = json.get_data()
		if not (data is Dictionary):
			return []
		var events: Array = []
		# Ollama's own error frames are bare strings, but a proxy in front of one (LiteLLM and friends) normalizes them to the OpenAI-shaped {"error": {"message": ...}} — stringifying that dict whole would throw and drop the frame, hiding the provider's real complaint (a context-overflow report above all) behind _finish_stream's generic connection-closed attribution.
		if data.has("error"):
			var err: Variant = data["error"]
			var message := _text(err.get("message", "")) if err is Dictionary else _text(err)
			events.append({"type": "error", "message": message if message != "" else line})
			return events
		if data.has("message") and data["message"] is Dictionary:
			var msg: Dictionary = data["message"]
			var thinking := _text(msg.get("thinking", ""))
			if thinking != "":
				events.append({"type": "thinking", "text": thinking})
			var content := _text(msg.get("content", ""))
			if content != "":
				events.append({"type": "content", "text": content})
			# Ollama emits each tool call whole (arguments already an object), so pass them straight through.
			if msg.get("tool_calls") is Array and not msg["tool_calls"].is_empty():
				events.append({"type": "tool_calls", "calls": msg["tool_calls"]})
		if bool(data.get("done", false)):
			# done_reason "stop" is the only normal finish; "length" (the num_predict cap) and anything else must surface as a cut-short reply.
			events.append({"type": "done", "stats": _stats(data), "stop": _canonical_stop(_text(data.get("done_reason")), PackedStringArray(["stop"]))})
		return events

	func models_path() -> String:
		return "/api/tags"

	## A pasted full endpoint (Ollama's docs hand out …/api/chat and friends) reduces to its server root; anything else — a bare host:port, or a reverse-proxy prefix — passes through and the /api/… paths join after it.
	func normalize_base(base: String) -> String:
		return _root_from_endpoint(super.normalize_base(base), ["/api/chat", "/api/generate", "/api/tags", "/api/show", "/api"])

	func parse_models(data: Variant) -> PackedStringArray:
		var names := PackedStringArray()
		if data is Dictionary and data.get("models") is Array:
			for entry in data["models"]:
				if entry is Dictionary and entry.has("name"):
					names.append(String(entry["name"]))
		return names

	## /api/tags reports no context length, so the window comes from a per-model /api/show (local and ollama.com alike; verified live 2026-07-19).
	func context_probe(model: String) -> Dictionary:
		return {"path": "/api/show", "method": HTTPClient.METHOD_POST, "body": {"model": model}}

	## model_info carries the architecture ceiling as "<family>.context_length"; a Modelfile-baked num_ctx (in the parameters dump) is the window the server will actually allocate, so it wins when present.
	func parse_context_window(data: Variant, _model: String = "") -> int:
		if not (data is Dictionary):
			return 0
		var num_ctx := _modelfile_num_ctx(_text(data.get("parameters")))
		if num_ctx > 0:
			return num_ctx
		if data.get("model_info") is Dictionary:
			for key in data["model_info"]:
				if String(key).ends_with(".context_length"):
					return int(data["model_info"][key])
		return 0

	## The num_ctx value out of a Modelfile parameters dump ("num_ctx 8192\nstop ..."), or 0 when it sets none.
	static func _modelfile_num_ctx(parameters: String) -> int:
		for line in parameters.split("\n"):
			var parts := line.strip_edges().split(" ", false)
			if parts.size() >= 2 and parts[0] == "num_ctx":
				return int(parts[1])
		return 0

	func completion_request(model: String, system_prompt: String, prompt: String) -> Dictionary:
		return {"path": "/api/generate", "body": {"model": model, "system": system_prompt, "prompt": prompt, "stream": false}}

	func parse_completion(data: Variant) -> String:
		if data is Dictionary:
			if data.has("response"):
				return String(data["response"])
			if data.get("message") is Dictionary:
				return String(data["message"].get("content", ""))
		return ""

	func parse_completion_stats(data: Variant) -> Dictionary:
		# /api/generate reports the same top-level counters as a chat stream's final chunk.
		return _stats(data) if data is Dictionary else {}

	## Ollama's usage/timing counters; durations stay in nanoseconds, as Ollama reports them. Missing fields default to 0.
	func _stats(data: Dictionary) -> Dictionary:
		return {
			"tokens_in": int(data.get("prompt_eval_count", 0)),
			"tokens_out": int(data.get("eval_count", 0)),
			"prompt_eval_duration": int(data.get("prompt_eval_duration", 0)),
			"eval_duration": int(data.get("eval_duration", 0)),
			"total_duration": int(data.get("total_duration", 0)),
		}


## OpenAI-compatible: /v1/chat/completions SSE, /v1/models.
## Translates the canonical message/tool shape to OpenAI's on send, and reassembles OpenAI's streamed deltas (content, reasoning, and tool-call argument fragments) back into canonical events on receive.
## Paths here omit the /v1 prefix because an OpenAI-compatible base_url carries it (e.g. .../inference.poolside.ai/v1); re-adding it would double the segment and 404.
class OpenAIAdapter extends LLMAdapter:
	var _tool_calls: Array = [] ## Tool calls under construction, one slot per stream `index`: {id, name, args}.
	var _usage: Dictionary = {} ## The `usage` block from the final chunk (stream_options.include_usage).
	var _finish_reason: String = "" ## The finish_reason value that ended the turn; canonicalized onto the done event's `stop` ("length" = the token cap) so a capped reply is disclosed, not shown as finished.
	var _finished: bool = false ## Guards _finish_events so finish_reason and a trailing [DONE] don't double-emit.

	func chat_path() -> String:
		return "/chat/completions"

	func build_chat_body(model: String, messages: Array, tools: Array, effort: String = "", _cache_ttl: int = 0) -> Dictionary:
		var body := {
			"model": model,
			"messages": _translate_messages(messages),
			"stream": true,
			# ask for a final usage-only chunk so token counts still reach the done event's stats
			"stream_options": {"include_usage": true},
		}
		# OpenAI's knob is reasoning_effort, and its value set is the level vocabulary itself ("none" included on models that take it), so every level passes through as-is.
		if effort != "":
			body["reasoning_effort"] = effort
		if not tools.is_empty():
			body["tools"] = tools # GDLLMTools already wraps each in the {type:"function", function:{...}} envelope OpenAI expects
		return body

	func models_path() -> String:
		return "/models"

	## A pasted full endpoint (the URL an OpenAI-compatible server's UI hands out, e.g. LM Studio's …/v1/chat/completions) reduces to its serving base first. Then a pathless base (e.g. "http://localhost:8000" for a local vLLM) gets "/v1" appended, since every OpenAI-compatible server serves under it; a base that still carries a path (Poolside's "/v1", a gateway's custom prefix) is respected as-is.
	func normalize_base(base: String) -> String:
		var out := _root_from_endpoint(super.normalize_base(base), ["/chat/completions", "/completions", "/models", "/embeddings"])
		var scheme_end := out.find("://")
		var host_start := scheme_end + 3 if scheme_end != -1 else 0
		if out.find("/", host_start) == -1 and out != "":
			out += "/v1"
		return out

	func parse_models(data: Variant) -> PackedStringArray:
		var names := PackedStringArray()
		if data is Dictionary and data.get("data") is Array:
			for entry in data["data"]:
				if entry is Dictionary and entry.has("id"):
					names.append(String(entry["id"]))
		return names

	# The base /v1/models contract carries no window field, but several servers add one to each list entry — vLLM's max_model_len, OpenRouter's context_length, Groq's context_window — so probe the list and read the target model's entry (there is no per-model retrieve endpoint on these servers, unlike Anthropic's /v1/models/{id}).
	# A declared window in the Effort Configuration dialog (GDLLMEfforts.context_window_for) still outranks this and forestalls the probe; a server that reports none of these fields resolves to 0, an honest unknown.
	func context_probe(_model: String) -> Dictionary:
		return {"path": "/models", "method": HTTPClient.METHOD_GET, "body": {}}

	## The window for `model` out of a /v1/models list: the first vendor window field its own entry carries. Given the model because one list body answers for every model at once (see LLMAdapter.parse_context_window).
	func parse_context_window(data: Variant, model: String = "") -> int:
		if data is Dictionary and data.get("data") is Array:
			for entry in data["data"]:
				if entry is Dictionary and String(entry.get("id", "")) == model:
					return _entry_context_window(entry)
		return 0

	## The context window a /v1/models entry declares, checking each known vendor extension in turn; 0 when it carries none.
	static func _entry_context_window(entry: Dictionary) -> int:
		for key in ["max_model_len", "context_length", "context_window"]:
			var window: Variant = entry.get(key)
			if (window is float or window is int) and int(window) > 0:
				return int(window)
		return 0

	func completion_request(model: String, system_prompt: String, prompt: String) -> Dictionary:
		var messages: Array = []
		if system_prompt != "":
			messages.append({"role": "system", "content": system_prompt})
		messages.append({"role": "user", "content": prompt})
		return {"path": "/chat/completions", "body": {"model": model, "messages": messages, "stream": false}}

	func parse_completion(data: Variant) -> String:
		if data is Dictionary and data.get("choices") is Array and not data["choices"].is_empty():
			var choice: Variant = data["choices"][0]
			if choice is Dictionary and choice.get("message") is Dictionary:
				return String(choice["message"].get("content", ""))
		return ""

	func parse_completion_stats(data: Variant) -> Dictionary:
		if data is Dictionary and data.get("usage") is Dictionary:
			return _stats_from(data["usage"])
		return {}

	func parse_line(line: String) -> Array:
		var trimmed := line.strip_edges()
		# SSE frames are "data: {json}" lines separated by blank lines; ignore blanks and comments.
		if not trimmed.begins_with("data:"):
			return []
		var payload := trimmed.substr(5).strip_edges()
		if payload == "[DONE]":
			return _finish_events()
		var json := JSON.new()
		if json.parse(payload) != OK:
			return []
		var data: Variant = json.get_data()
		if not (data is Dictionary):
			return []
		# Providers report mid-stream failures (context overflow included) as an error frame — {"error": {...}}, or a bare string on some compatible servers; discarding it would let a trailing [DONE] dress the failure up as an empty success.
		if data.has("error"):
			var err: Variant = data["error"]
			var message := _text(err.get("message", "")) if err is Dictionary else _text(err)
			return [{"type": "error", "message": message if message != "" else payload}]
		# Usage rides a final chunk whose choices are empty (stream_options.include_usage).
		if data.get("usage") is Dictionary:
			_usage = data["usage"]
		var events: Array = []
		if data.get("choices") is Array and not data["choices"].is_empty():
			var choice: Dictionary = data["choices"][0]
			var delta: Variant = choice.get("delta", {})
			if delta is Dictionary:
				# Reasoning models expose their trace as reasoning_content (vLLM) or reasoning; absent means no thinking.
				var reasoning := _text(delta.get("reasoning_content", delta.get("reasoning", "")))
				if reasoning != "":
					events.append({"type": "thinking", "text": reasoning})
				var content := _text(delta.get("content"))
				if content != "":
					events.append({"type": "content", "text": content})
				if delta.get("tool_calls") is Array:
					_accumulate_tool_calls(delta["tool_calls"])
			# finish_reason ends the turn; some servers still send a trailing [DONE], which _finished absorbs.
			if choice.get("finish_reason") != null:
				_finish_reason = _text(choice.get("finish_reason"))
				events.append_array(_finish_events())
		return events

	## Translate canonical (Ollama-shaped) history to OpenAI's: assistant tool-call turns get string-encoded arguments and synthesized call ids, and each following tool result is bound to its call id by order.
	func _translate_messages(messages: Array) -> Array:
		var out: Array = []
		var pending_ids: Array = [] # ids of the last assistant turn's calls, awaiting their tool results in order
		var counter := 0
		for msg in messages:
			if not (msg is Dictionary):
				continue
			var role := String(msg.get("role", ""))
			if role == "assistant" and msg.get("tool_calls") is Array and not msg["tool_calls"].is_empty():
				var calls: Array = []
				pending_ids = []
				for tc in msg["tool_calls"]:
					var id := "call_%d" % counter
					counter += 1
					pending_ids.append(id)
					var fn: Dictionary = tc.get("function", {}) if tc is Dictionary else {}
					var raw_args: Variant = fn.get("arguments", {})
					var args_str: String = raw_args if raw_args is String else JSON.stringify(raw_args)
					calls.append({"id": id, "type": "function", "function": {"name": String(fn.get("name", "")), "arguments": args_str}})
				var assistant_msg := {"role": "assistant", "tool_calls": calls}
				var preamble := String(msg.get("content", ""))
				if preamble != "":
					assistant_msg["content"] = preamble
				out.append(assistant_msg)
			elif role == "tool":
				var id := String(pending_ids.pop_front()) if not pending_ids.is_empty() else ""
				out.append({"role": "tool", "tool_call_id": id, "content": String(msg.get("content", ""))})
			else:
				out.append({"role": role, "content": String(msg.get("content", ""))})
		return out

	## Fold this chunk's tool-call deltas into _tool_calls: name arrives once, arguments stream as string fragments concatenated by `index`.
	func _accumulate_tool_calls(deltas: Array) -> void:
		for d in deltas:
			if not (d is Dictionary):
				continue
			var idx := int(d.get("index", 0))
			while _tool_calls.size() <= idx:
				_tool_calls.append({"id": "", "name": "", "args": ""})
			var slot: Dictionary = _tool_calls[idx]
			# Only the opening delta of a call carries id/name; continuation deltas send null for both, so keep the first non-empty and never overwrite it back to blank.
			var id_text := _text(d.get("id"))
			if id_text != "":
				slot["id"] = id_text
			if d.get("function") is Dictionary:
				var fn: Dictionary = d["function"]
				var name_text := _text(fn.get("name"))
				if name_text != "":
					slot["name"] = name_text
				if fn.has("arguments"):
					slot["args"] += _text(fn.get("arguments"))

	## The terminal events for the stream: the assembled tool calls (if any) then done+stats, emitted at most once.
	func _finish_events() -> Array:
		if _finished:
			return []
		_finished = true
		var events: Array = []
		if not _tool_calls.is_empty():
			events.append({"type": "tool_calls", "calls": _assembled_tool_calls()})
		# "stop"/"tool_calls" (and legacy "function_call") are the normal ends; "length" (the token cap) and "content_filter" mean the reply was cut short.
		events.append({"type": "done", "stats": _stats_from(_usage), "stop": _canonical_stop(_finish_reason, PackedStringArray(["stop", "tool_calls", "function_call"]))})
		return events

	## The accumulated fragments as canonical {"function": {name, arguments: Dictionary}} calls, parsing each arguments string back into an object.
	func _assembled_tool_calls() -> Array:
		var out: Array = []
		for slot in _tool_calls:
			# A no-argument call streams "" for arguments; parsing that is a noisy failure, so treat empty as {}.
			var args_text := _text(slot["args"])
			var parsed: Variant = JSON.parse_string(args_text) if args_text != "" else {}
			var args: Dictionary = parsed if parsed is Dictionary else {}
			out.append({"function": {"name": _text(slot["name"]), "arguments": args}})
		return out

	## OpenAI usage mapped onto the plugin's stat keys; it reports no durations, so those stay 0. Static so the non-streamed completion path maps its body's usage through the same rule.
	static func _stats_from(usage: Dictionary) -> Dictionary:
		return {
			"tokens_in": int(usage.get("prompt_tokens", 0)),
			"tokens_out": int(usage.get("completion_tokens", 0)),
			"prompt_eval_duration": 0,
			"eval_duration": 0,
			"total_duration": 0,
		}


## Anthropic Messages API: /v1/messages SSE, /v1/models. Auth is x-api-key + anthropic-version, not a Bearer token.
## Translates the canonical shape to Anthropic's content-block format on send (the system prompt as a top-level field, tool results as tool_result blocks inside user messages) and reassembles the streamed events (thinking, text, tool_use input fragments) back into canonical events on receive.
## Adaptive thinking is requested only on model families documented to accept it; a selected effort level rides output_config.effort beside it ("none" becomes thinking:disabled instead — see build_chat_body), and a tool-call turn's raw content blocks are handed back via the assistant_blocks event because the API requires them echoed — thinking signatures intact — to continue a tool loop.
class AnthropicAdapter extends LLMAdapter:
	const API_VERSION := "2023-06-01" ## The anthropic-version header every request carries.
	const CACHE_TTL_DEFAULT := 300 ## Anthropic's default prompt-cache lifetime (the 5-minute tier).
	const CACHE_TTL_LONG := 3600 ## The only other lifetime the API offers: the 1-hour tier, requested as ttl "1h" at 2x write cost instead of 1.25x (worth it from about three reuses).
	const CHAT_MAX_TOKENS := 64000 ## Fallback max_tokens for a model whose cap no sweep has reported yet; /v1/messages requires the field, and the chat path streams, so a large value can't hit a transport timeout.
	const COMPLETION_MAX_TOKENS := 8192 ## Cap for the one-shot completion path (title generation) — short-form work that never needs the chat path's headroom.

	static var _output_caps: Dictionary = {} ## Per-model output cap (max_tokens) as /v1/models reported it, captured by parse_models; static so the caps outlive the per-request adapter instances.

	var _usage: Dictionary = {} ## Usage counters folded together from message_start and message_delta.
	var _blocks: Array = [] ## Finished raw content blocks in stream order, handed back for the tool-loop echo.
	var _block: Dictionary = {} ## The content block currently streaming (between content_block_start and _stop).
	var _stop_reason: String = "" ## The final stop_reason from message_delta; "refusal" turns the finish into an error, and any other abnormal reason ("max_tokens" above all) rides the done event's `stop` so a capped reply is disclosed.
	var _finished := false ## Guards _finish_events so a malformed trailing frame can't double-emit.

	func chat_path() -> String:
		return "/v1/messages"

	## Anthropic authenticates with x-api-key (not Bearer), and every call needs the anthropic-version header — sent even with no key so a missing key fails as a clear 401 rather than a malformed request.
	func auth_headers(api_key: String) -> PackedStringArray:
		var headers := PackedStringArray(["anthropic-version: " + API_VERSION])
		if api_key.strip_edges() != "":
			headers.append("x-api-key: " + api_key.strip_edges())
		return headers

	func build_chat_body(model: String, messages: Array, tools: Array, effort: String = "", cache_ttl: int = 0) -> Dictionary:
		var body := {
			"model": model,
			"max_tokens": _chat_max_tokens(model),
			"stream": true,
			"messages": _translate_messages(messages, not tools.is_empty()),
			# Top-level cache_control auto-places a prompt-cache breakpoint on the last cacheable block, so each turn reuses the previous turn's prefix at a fraction of the input price. The configured TTL is enforced here, not just presumed: past the default tier it requests the 1-hour lifetime (see cache_control_for), so the session's cold-gap arithmetic describes what the provider actually holds.
			"cache_control": cache_control_for(cache_ttl),
		}
		var system := _system_text(messages)
		if system != "":
			body["system"] = system
		# Anthropic splits the vocabulary across two knobs: "none" means no reasoning, spelled as an explicit thinking:disabled that overrides the family default; any other level rides output_config.effort alongside that default. Families that reject a knob (Fable rejects disabled; only low/medium/high/xhigh/max are effort values) fail loudly, which the user's level config exists to prevent.
		if effort == "none":
			body["thinking"] = {"type": "disabled"}
		else:
			if effort != "":
				body["output_config"] = {"effort": effort}
			var thinking := _thinking_config(model)
			if not thinking.is_empty():
				body["thinking"] = thinking
		if not tools.is_empty():
			body["tools"] = _translate_tools(tools)
		return body

	## The cache_control block for a configured TTL: the 1-hour tier is requested explicitly, the default 5-minute tier by omission (sending no ttl key keeps the body byte-identical to what pre-TTL sessions sent).
	static func cache_control_for(cache_ttl: int) -> Dictionary:
		if effective_cache_ttl(cache_ttl) == CACHE_TTL_LONG:
			return {"type": "ephemeral", "ttl": "1h"}
		return {"type": "ephemeral"}

	## The lifetime a configured TTL actually buys on this provider — the API offers exactly two tiers, so any figure past the default quantizes up to the 1-hour tier and anything at or under it (0 and unset included) stays on the default. Pure and static so the session's cold-gap presumption and the request body share one rule (see GDLLMChatSession._cache_cold_gap_seconds), testable headless.
	static func effective_cache_ttl(cache_ttl: int) -> int:
		return CACHE_TTL_LONG if cache_ttl > CACHE_TTL_DEFAULT else CACHE_TTL_DEFAULT

	func models_path() -> String:
		# The default page is 20 entries; raise the limit so one fetch covers the whole catalog.
		return "/v1/models?limit=100"

	## A pasted full endpoint (…/v1/messages, or a base ending in /v1) reduces to the server root the /v1/… paths join to, so the URL Anthropic's docs hand out works as-is; a gateway prefix passes through untouched.
	func normalize_base(base: String) -> String:
		return _root_from_endpoint(super.normalize_base(base), ["/v1/messages", "/v1/models", "/v1"])

	func parse_models(data: Variant) -> PackedStringArray:
		var names := PackedStringArray()
		if data is Dictionary and data.get("data") is Array:
			for entry in data["data"]:
				if entry is Dictionary and entry.has("id"):
					var id := String(entry["id"])
					names.append(id)
					# Each entry reports the model's own output cap; carry it so chat requests send the model's true limit instead of a guessed constant (models capped below CHAT_MAX_TOKENS, e.g. Opus 4.1's 32K, 400 on the constant).
					var cap: Variant = entry.get("max_tokens")
					if (cap is float or cap is int) and int(cap) > 0:
						_output_caps[id] = int(cap)
		return names

	## The max_tokens for a chat request on `model`: the cap /v1/models reported for it, or CHAT_MAX_TOKENS when no sweep has seen the model.
	func _chat_max_tokens(model: String) -> int:
		return int(_output_caps.get(model, CHAT_MAX_TOKENS))

	## The single-model retrieve endpoint; its entry carries the same fields as the list the sweep reads.
	func context_probe(model: String) -> Dictionary:
		return {"path": "/v1/models/" + model.uri_encode(), "method": HTTPClient.METHOD_GET, "body": {}}

	## A model entry reports its context window as max_input_tokens (there is no context_window field).
	func parse_context_window(data: Variant, _model: String = "") -> int:
		if data is Dictionary:
			var window: Variant = data.get("max_input_tokens")
			if window is float or window is int:
				return int(window)
		return 0

	func completion_request(model: String, system_prompt: String, prompt: String) -> Dictionary:
		var body := {"model": model, "max_tokens": COMPLETION_MAX_TOKENS, "messages": [{"role": "user", "content": prompt}]}
		if system_prompt != "":
			body["system"] = system_prompt
		return {"path": "/v1/messages", "body": body}

	func parse_completion(data: Variant) -> String:
		# Skip past any thinking blocks (models with thinking on by default emit them first) to the first text block.
		if data is Dictionary and data.get("content") is Array:
			for block in data["content"]:
				if block is Dictionary and String(block.get("type", "")) == "text":
					return _text(block.get("text"))
		return ""

	func parse_completion_stats(data: Variant) -> Dictionary:
		if data is Dictionary and data.get("usage") is Dictionary:
			return _stats_from(data["usage"])
		return {}

	func parse_line(line: String) -> Array:
		var trimmed := line.strip_edges()
		# SSE frames are "event: name" + "data: {json}" pairs; the data's own `type` field repeats the event name, so only data lines matter (blanks, comments, and pings carry nothing).
		if not trimmed.begins_with("data:"):
			return []
		var json := JSON.new()
		if json.parse(trimmed.substr(5).strip_edges()) != OK:
			return []
		var data: Variant = json.get_data()
		if not (data is Dictionary):
			return []
		match String(data.get("type", "")):
			"message_start":
				if data.get("message") is Dictionary and data["message"].get("usage") is Dictionary:
					_merge_usage(data["message"]["usage"])
			"content_block_start":
				_begin_block(data["content_block"] if data.get("content_block") is Dictionary else {})
			"content_block_delta":
				return _apply_delta(data["delta"] if data.get("delta") is Dictionary else {})
			"content_block_stop":
				_end_block()
			"message_delta":
				if data.get("usage") is Dictionary:
					_merge_usage(data["usage"])
				if data.get("delta") is Dictionary:
					_stop_reason = _text(data["delta"].get("stop_reason"))
			"message_stop":
				return _finish_events()
			"error":
				# Like the sibling adapters, an error frame without a usable message falls back to the raw frame — a proxy's bare-string error or a type-only dict still names its real cause that way — and the error's type ("overloaded_error", "rate_limit_error") is kept, since it IS the cause for frames whose message merely elaborates.
				var err: Dictionary = data["error"] if data.get("error") is Dictionary else {}
				var message := _text(err.get("message", "")) if data.get("error") is Dictionary else _text(data.get("error"))
				var err_type := _text(err.get("type", ""))
				if err_type != "" and not message.contains(err_type):
					message = ("%s: %s" % [err_type, message]) if message != "" else err_type
				return [{"type": "error", "message": message if message != "" else trimmed}]
		return []

	## The thinking parameter for `model`. Adaptive thinking is requested only on families documented to accept it, so an unknown or older model never 400s on an unsupported knob; families whose default omits the trace text opt back in with display:"summarized" so the reasoning block the plugin renders isn't empty (the 4.6 family already defaults to summarized).
	func _thinking_config(model: String) -> Dictionary:
		var name := model.to_lower()
		for family in ["claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5", "claude-fable", "claude-mythos"]:
			if name.begins_with(family):
				return {"type": "adaptive", "display": "summarized"}
		for family in ["claude-opus-4-6", "claude-sonnet-4-6"]:
			if name.begins_with(family):
				return {"type": "adaptive"}
		return {}

	## The leading system messages' text, joined — Anthropic takes the system prompt as a top-level field, not a message role.
	func _system_text(messages: Array) -> String:
		var parts: Array = []
		for msg in messages:
			if msg is Dictionary and String(msg.get("role", "")) == "system":
				var text := _text(msg.get("content"))
				if text.strip_edges() != "":
					parts.append(text)
		return "\n\n".join(parts)

	## The canonical function-schema envelope ({type:"function", function:{name, description, parameters}}) unwrapped to Anthropic's flat tool shape.
	func _translate_tools(tools: Array) -> Array:
		var out: Array = []
		for entry in tools:
			var fn: Dictionary = entry["function"] if entry is Dictionary and entry.get("function") is Dictionary else {}
			if fn.is_empty():
				continue
			var schema: Variant = fn.get("parameters")
			out.append({
				"name": _text(fn.get("name")),
				"description": _text(fn.get("description")),
				"input_schema": schema if schema is Dictionary and not schema.is_empty() else {"type": "object", "properties": {}},
			})
		return out

	## Canonical history translated to Anthropic's content-block messages. Tool results become tool_result blocks inside user messages — consecutive results merge into one user turn, as the API requires — each bound to its call id by order. An assistant tool-call turn inside the trailing tool loop (everything after the last real user message) echoes its stored raw `assistant_blocks`, thinking signatures intact, because the API validates them to continue the loop; earlier turns rebuild from text + synthesized ids so past reasoning isn't re-sent (goal 1). With `allow_tool_blocks` false — a tool-less request such as the loop-brake reflection or a subagent's forced final answer — the API rejects tool_use/tool_result blocks outright, so the loop's turns flatten to plain text the model can still read.
	func _translate_messages(messages: Array, allow_tool_blocks: bool) -> Array:
		var last_user := -1
		for i in messages.size():
			if messages[i] is Dictionary and String(messages[i].get("role", "")) == "user":
				last_user = i
		var out: Array = []
		var pending_ids: Array = [] # ids of the last assistant turn's tool_use blocks, awaiting their tool results in order
		for i in messages.size():
			var msg: Variant = messages[i]
			if not (msg is Dictionary):
				continue
			var role := String(msg.get("role", ""))
			if role == "system":
				continue # lifted to the top-level system field by build_chat_body
			if role == "tool":
				if allow_tool_blocks:
					_append_tool_result(out, pending_ids, _text(msg.get("content")))
				else:
					var result_text := _text(msg.get("content"))
					out.append({"role": "user", "content": "[%s result]\n%s" % [_text(msg.get("tool_name", "tool")), result_text if result_text.strip_edges() != "" else "(no output)"]})
			elif role == "assistant" and msg.get("tool_calls") is Array and not msg["tool_calls"].is_empty():
				if allow_tool_blocks:
					pending_ids = []
					out.append({"role": "assistant", "content": _assistant_call_blocks(msg, i > last_user, pending_ids, i)})
				else:
					out.append({"role": "assistant", "content": _flatten_call_text(msg)})
			else:
				var text := _text(msg.get("content"))
				# The API rejects empty text content, and history can hold a blank assistant echo.
				out.append({"role": role, "content": text if text.strip_edges() != "" else "(empty)"})
		return out

	## One assistant tool-call turn as plain text — its preamble plus a "[called name(args)]" line per call — for tool-less requests that cannot carry tool_use blocks.
	func _flatten_call_text(msg: Dictionary) -> String:
		var lines: Array = []
		var text := _text(msg.get("content"))
		if text.strip_edges() != "":
			lines.append(text)
		for tc in msg["tool_calls"]:
			var fn: Dictionary = tc["function"] if tc is Dictionary and tc.get("function") is Dictionary else {}
			lines.append("[called %s(%s)]" % [_text(fn.get("name")), JSON.stringify(fn.get("arguments", {}))])
		return "\n".join(lines)

	## The content blocks for one assistant tool-call turn. Inside the trailing loop (`use_raw`), the stored raw blocks are echoed verbatim and their real tool_use ids fill `pending_ids`; otherwise the turn rebuilds from its text and calls with synthesized ids ("toolu_gdllm_<turn>_<n>"), which the stateless API accepts as long as each tool_result echoes the same id back.
	func _assistant_call_blocks(msg: Dictionary, use_raw: bool, pending_ids: Array, turn_index: int) -> Array:
		var raw: Variant = msg.get("assistant_blocks")
		if use_raw and raw is Array and not raw.is_empty():
			for block in raw:
				if block is Dictionary and String(block.get("type", "")) == "tool_use":
					pending_ids.append(_text(block.get("id")))
			return raw
		var blocks: Array = []
		var text := _text(msg.get("content"))
		if text.strip_edges() != "":
			blocks.append({"type": "text", "text": text})
		var n := 0
		for tc in msg["tool_calls"]:
			var fn: Dictionary = tc["function"] if tc is Dictionary and tc.get("function") is Dictionary else {}
			var args: Variant = fn.get("arguments")
			var id := "toolu_gdllm_%d_%d" % [turn_index, n]
			n += 1
			pending_ids.append(id)
			blocks.append({"type": "tool_use", "id": id, "name": _text(fn.get("name")), "input": args if args is Dictionary else {}})
		if blocks.is_empty():
			blocks.append({"type": "text", "text": "(empty)"}) # a fully malformed stored turn still needs non-empty content
		return blocks

	## Append one tool result to the wire messages: as another tool_result block on the open user turn when the previous message is one, else opening a new user turn — the API wants every result of an assistant's calls in the single user message that follows it.
	func _append_tool_result(out: Array, pending_ids: Array, content: String) -> void:
		var block := {
			"type": "tool_result",
			"tool_use_id": _text(pending_ids.pop_front()) if not pending_ids.is_empty() else "",
			"content": content if content.strip_edges() != "" else "(no output)",
		}
		if not out.is_empty():
			var last: Dictionary = out[out.size() - 1]
			if String(last.get("role", "")) == "user" and last.get("content") is Array:
				last["content"].append(block)
				return
		out.append({"role": "user", "content": [block]})

	## Fold one usage report into the running counters — input tokens arrive on message_start, cumulative output tokens on message_delta.
	func _merge_usage(usage: Dictionary) -> void:
		for key in usage:
			if usage[key] != null:
				_usage[key] = usage[key]

	## Open a streaming content block, normalized to accumulate: text and thinking grow via deltas, a tool_use's input JSON arrives as string fragments held in "_json" until the block closes.
	func _begin_block(content_block: Dictionary) -> void:
		match String(content_block.get("type", "")):
			"text":
				_block = {"type": "text", "text": _text(content_block.get("text"))}
			"thinking":
				_block = {"type": "thinking", "thinking": _text(content_block.get("thinking")), "signature": ""}
			"tool_use":
				_block = {"type": "tool_use", "id": _text(content_block.get("id")), "name": _text(content_block.get("name")), "input": {}, "_json": ""}
			_:
				# redacted_thinking (and anything future) arrives whole; keep it verbatim for the echo.
				_block = content_block.duplicate(true)

	## Fold one delta into the open block, yielding the canonical event when the delta carries streamable text.
	func _apply_delta(delta: Dictionary) -> Array:
		match String(delta.get("type", "")):
			"text_delta":
				var text := _text(delta.get("text"))
				if _block.get("type") == "text":
					_block["text"] = _text(_block.get("text")) + text
				if text != "":
					return [{"type": "content", "text": text}]
			"thinking_delta":
				var thinking := _text(delta.get("thinking"))
				if _block.get("type") == "thinking":
					_block["thinking"] = _text(_block.get("thinking")) + thinking
				if thinking != "":
					return [{"type": "thinking", "text": thinking}]
			"signature_delta":
				if _block.get("type") == "thinking":
					_block["signature"] = _text(_block.get("signature")) + _text(delta.get("signature"))
			"input_json_delta":
				if _block.get("type") == "tool_use":
					_block["_json"] = _text(_block.get("_json")) + _text(delta.get("partial_json"))
		return []

	## Close the open block into the ordered list, parsing a tool_use's accumulated JSON fragments into its input object.
	func _end_block() -> void:
		if _block.is_empty():
			return
		if _block.get("type") == "tool_use":
			var args_text := _text(_block.get("_json"))
			# A no-argument call streams no fragments; treat empty as {} rather than a noisy parse failure.
			var parsed: Variant = JSON.parse_string(args_text) if args_text != "" else {}
			_block["input"] = parsed if parsed is Dictionary else {}
			_block.erase("_json")
		_blocks.append(_block)
		_block = {}

	## The terminal events for the stream: the raw blocks for the tool-loop echo, the assembled tool calls, then done+stats — or an error when the safety classifiers declined the request. Emitted at most once.
	func _finish_events() -> Array:
		if _finished:
			return []
		_finished = true
		if _stop_reason == "refusal":
			return [{"type": "error", "message": "Anthropic declined this request (stop_reason: refusal)."}]
		var events: Array = []
		var calls: Array = []
		for block in _blocks:
			if block is Dictionary and String(block.get("type", "")) == "tool_use":
				calls.append({"function": {"name": _text(block.get("name")), "arguments": block.get("input", {})}})
		if not calls.is_empty():
			# The raw blocks ride ahead of the calls so LLMClient holds them before the tool_calls signal fires (see last_assistant_blocks).
			events.append({"type": "assistant_blocks", "blocks": _blocks})
			events.append({"type": "tool_calls", "calls": calls})
		# "max_tokens" canonicalizes to "length": the cap bounds thinking and reply together, so a high-effort turn can hit it mid-answer and must not render as finished.
		events.append({"type": "done", "stats": _stats_from(_usage), "stop": _canonical_stop(_stop_reason, PackedStringArray(["end_turn", "tool_use", "stop_sequence"]))})
		return events

	## Anthropic usage mapped onto the plugin's stat keys. tokens_in sums fresh and cached input so the context estimate reflects the whole prompt; no durations are reported, so those stay 0. Static so the non-streamed completion path maps its body's usage through the same rule.
	static func _stats_from(usage: Dictionary) -> Dictionary:
		return {
			"tokens_in": int(usage.get("input_tokens", 0)) + int(usage.get("cache_creation_input_tokens", 0)) + int(usage.get("cache_read_input_tokens", 0)),
			"tokens_out": int(usage.get("output_tokens", 0)),
			"prompt_eval_duration": 0,
			"eval_duration": 0,
			"total_duration": 0,
		}
