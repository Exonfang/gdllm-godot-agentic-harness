@tool
class_name LLMAdapter extends RefCounted
## Translates between the plugin's canonical (Ollama-native) message/tool shape and one provider's wire format.
## LLMClient owns the transport (socket, HTTP state machine); an adapter only says which path to hit, how to build a request body, and how to turn a streamed line back into canonical events.
## A fresh instance is built per request so a stateful format (OpenAI's tool-call argument fragments) can accumulate across lines.
## Subclasses: OllamaAdapter (near-identity — the canonical shape already IS Ollama's), OpenAIAdapter, OpenAIResponsesAdapter (OpenAI's newer /v1/responses format, which its GPT-5.6-class models require for reasoning effort with tools), AnthropicAdapter and GeminiAdapter (translate at both edges).
##
## Canonical stream events an adapter emits from parse_line, folded straight onto LLMClient's state: {type:"thinking", text}, {type:"content", text}, {type:"tool_calls", calls}, {type:"done", stats, stop}, {type:"error", message} — plus {type:"progress"}, a no-op for a recognized frame with nothing streamable yet, so the client's wire-format guard knows the reply parses before the first visible delta (a Responses reasoning turn can stream nothing user-visible for minutes).
## A done event's `stop` is the provider's end-of-turn reason canonicalized by _canonical_stop: "" for a normal finish, "length" for the output-token cap, anything else verbatim — so a reply the provider itself cut short is never presented as finished (see LLMClient._stream_final_stats).
## A canonical tool call is {"function": {name, arguments: Dictionary}} — exactly what GDLLMTools.tool_call_name/args/sanitize_tool_calls consume.
## An adapter whose provider must see its own turn echoed verbatim to continue a tool loop (Anthropic, the OpenAI Responses API, and Chat Completions servers that attach state to a tool call — Gemini's thought signatures) additionally emits {type:"assistant_blocks", blocks} ahead of the tool calls; LLMClient holds the blocks for the caller to store beside the turn (see LLMClient.last_assistant_blocks).


## Build the adapter for a source `kind` (see GDLLMSources.KIND_*). Unknown kinds fall back to Ollama.
static func for_kind(kind: String) -> LLMAdapter:
	if kind == GDLLMSources.KIND_OPENAI:
		return OpenAIAdapter.new()
	if kind == GDLLMSources.KIND_OPENAI_RESPONSES:
		return OpenAIResponsesAdapter.new()
	if kind == GDLLMSources.KIND_OPENAI_CHATGPT:
		return OpenAIChatGPTAdapter.new()
	if kind == GDLLMSources.KIND_ANTHROPIC:
		return AnthropicAdapter.new()
	if kind == GDLLMSources.KIND_GEMINI:
		return GeminiAdapter.new()
	return OllamaAdapter.new()


## The request path for a streamed chat request.
func chat_path() -> String:
	return ""


## The JSON-ready body for a streamed chat turn, built from canonical `messages` (a leading system message included) and function-schema `tools`. `effort` is the user's reasoning-effort level (a GDLLMEfforts.LEVELS name; "" = default, meaning no knob is sent), which each adapter translates to its provider's own control: Ollama's `think`, OpenAI's `reasoning_effort` (`reasoning.effort` on the Responses API), Anthropic's `output_config.effort` (or disabled thinking for "none"). A level the provider or model doesn't accept fails loudly at request time — which is why the user-maintained config gates what's offered (see GDLLMEfforts). `cache_ttl` is the session's effective prompt-cache TTL in seconds (see GDLLMChatSession._cache_cold_gap_seconds); Anthropic is the only provider whose cache takes a requested lifetime, so the other adapters ignore it.
func build_chat_body(_model: String, _messages: Array, _tools: Array, _effort: String = "", _cache_ttl: int = 0) -> Dictionary:
	return {}


## Zero or more canonical events parsed out of one streamed line. Instance state may accumulate across calls (see OpenAIAdapter).
func parse_line(_line: String) -> Array:
	return []


## The request path for the model-list fetch.
func models_path() -> String:
	return ""


## The model names this source serves without asking the network, for a backend that publishes no listing endpoint (the ChatGPT subscription backend); empty means fetch models_path and parse the reply.
func static_models() -> PackedStringArray:
	return PackedStringArray()


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


## The reply lifted out of a one-shot completion whose body arrived as a buffered SSE transcript instead of JSON — {text, stats} when the transcript parsed, {} otherwise. Only a backend that refuses non-streamed requests needs this (the ChatGPT subscription's); everywhere else the JSON path answers first and this is never consulted.
func parse_completion_stream(_text: String) -> Dictionary:
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


## An error frame's user-facing message: `message` prefixed with the provider's error kind/code when it adds information ("overloaded_error: Overloaded" — skipped when the message already names it), falling back to `fallback` (typically the raw frame) when both are empty, so an error is never reported blank.
static func _prefixed_error(kind: String, message: String, fallback: String) -> String:
	var out := message
	if kind != "" and not out.contains(kind):
		out = ("%s: %s" % [kind, out]) if out != "" else kind
	return out if out != "" else fallback


## The leading system messages' text, joined — for the providers that carry the system prompt as a top-level request field (Anthropic's `system`, the Responses API's `instructions`) rather than a message role.
func _system_text(messages: Array) -> String:
	var parts: Array = []
	for msg in messages:
		if msg is Dictionary and String(msg.get("role", "")) == "system":
			var text := _text(msg.get("content"))
			if text.strip_edges() != "":
				parts.append(text)
	return "\n\n".join(parts)


## One assistant tool-call turn as plain text — its preamble plus a "[called name(args)]" line per call — for tool-less requests on providers that reject tool blocks/items they didn't declare (see each echoing adapter's translate).
func _flatten_call_text(msg: Dictionary) -> String:
	var lines: Array = []
	var text := _text(msg.get("content"))
	if text.strip_edges() != "":
		lines.append(text)
	for tc in msg["tool_calls"]:
		var fn: Dictionary = tc["function"] if tc is Dictionary and tc.get("function") is Dictionary else {}
		lines.append("[called %s(%s)]" % [_text(fn.get("name")), JSON.stringify(fn.get("arguments", {}))])
	return "\n".join(lines)


## One tool result as a labeled plain-text user line ("[name result]…"), the flatten counterpart to _flatten_call_text for the same tool-less requests.
static func _flatten_tool_result_text(msg: Dictionary) -> String:
	var text := _text(msg.get("content"))
	return "[%s result]\n%s" % [_text(msg.get("tool_name", "tool")), text if text.strip_edges() != "" else "(no output)"]


## The index of the last user message in canonical history — the trailing tool loop's boundary: turns after it may replay their stored provider echo, earlier ones rebuild from text (see each echoing adapter's translate). -1 (no user message) makes the whole span that loop. Mirrors GDLLMChatSession._echo_boundary.
static func _last_user_index(messages: Array) -> int:
	var last_user := -1
	for i in messages.size():
		if messages[i] is Dictionary and String(messages[i].get("role", "")) == "user":
			last_user = i
	return last_user


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
	var _tool_calls: Array = [] ## Tool calls under construction, in arrival order: {id, name, args, extra}.
	var _slot_for_index: Dictionary = {} ## Stream `index` → the _tool_calls position of the call currently open under it (see _accumulate_tool_calls).
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

	## A pasted full endpoint (the URL an OpenAI-compatible server's UI hands out, e.g. LM Studio's …/v1/chat/completions) reduces to its serving base first. Then a pathless base (e.g. "http://localhost:8000" for a local vLLM) gets the kind's default path appended (see _default_path); a base that still carries a path (Poolside's "/v1", a gateway's custom prefix) is respected as-is.
	func normalize_base(base: String) -> String:
		var out := _root_from_endpoint(super.normalize_base(base), _endpoint_suffixes())
		var scheme_end := out.find("://")
		var host_start := scheme_end + 3 if scheme_end != -1 else 0
		if out.find("/", host_start) == -1 and out != "":
			out += _default_path()
		return out

	## The pasted-endpoint suffixes normalize_base strips back to the serving base, most-specific first; subclasses swap in their own chat path.
	func _endpoint_suffixes() -> Array:
		return ["/chat/completions", "/completions", "/models", "/embeddings"]

	## The serving path a pathless base gains: every OpenAI-compatible server serves under /v1; the ChatGPT subclass swaps in its backend prefix.
	func _default_path() -> String:
		return "/v1"

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

	## Translate canonical (Ollama-shaped) history to OpenAI's: assistant tool-call turns get string-encoded arguments and synthesized call ids, and each following tool result is bound to its call id by order. Inside the trailing tool loop (everything after the last user message), a turn whose provider stored its raw tool calls (see _raw_tool_calls) replays them verbatim instead, because Gemini validates the thought signature riding on each call to continue the loop; earlier turns rebuild, so past signatures aren't re-sent (goal 1).
	func _translate_messages(messages: Array) -> Array:
		var out: Array = []
		var pending_ids: Array = [] # ids of the last assistant turn's calls, awaiting their tool results in order
		var counter := 0
		var last_user := _last_user_index(messages)
		for i in messages.size():
			var msg: Variant = messages[i]
			if not (msg is Dictionary):
				continue
			var role := String(msg.get("role", ""))
			if role == "assistant" and msg.get("tool_calls") is Array and not msg["tool_calls"].is_empty():
				pending_ids = []
				var calls: Array = _echoed_tool_calls(msg, pending_ids, i) if i > last_user else []
				if calls.is_empty():
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

	## The stored raw tool calls of one assistant turn, ready to resend, with their ids appended to `pending_ids`; empty when the turn must rebuild instead. Blocks that aren't one OpenAI tool call per canonical call were recorded under another kind (Anthropic's tool_use blocks, the Responses API's items, after a mid-loop Kind switch) and would 400 here.
	func _echoed_tool_calls(msg: Dictionary, pending_ids: Array, turn_index: int) -> Array:
		var raw: Variant = msg.get("assistant_blocks")
		if not (raw is Array) or raw.size() != msg["tool_calls"].size():
			return []
		for block in raw:
			if not (block is Dictionary) or String(block.get("type", "")) != "function" or not (block.get("function") is Dictionary):
				return []
		var calls: Array = []
		for n in raw.size():
			var call: Dictionary = raw[n].duplicate(true)
			if _text(call.get("id")) == "":
				call["id"] = "call_echo_%d_%d" % [turn_index, n]
			pending_ids.append(_text(call["id"]))
			calls.append(call)
		return calls

	## Fold this chunk's tool-call deltas into _tool_calls: name arrives once, arguments stream as string fragments concatenated by `index`.
	func _accumulate_tool_calls(deltas: Array) -> void:
		for d in deltas:
			if not (d is Dictionary):
				continue
			var idx := int(d.get("index", 0))
			var id_text := _text(d.get("id"))
			# A delta opens a new call when its index is new, or when it names an id other than the call already open there — Gemini streams each parallel call whole under the same index, and folding them together would join their argument strings into unparseable JSON.
			var pos: int = _slot_for_index.get(idx, -1)
			if pos == -1 or (id_text != "" and _text(_tool_calls[pos]["id"]) not in ["", id_text]):
				_tool_calls.append({"id": "", "name": "", "args": "", "extra": {}})
				pos = _tool_calls.size() - 1
				_slot_for_index[idx] = pos
			var slot: Dictionary = _tool_calls[pos]
			# Only the opening delta of a call carries id/name; continuation deltas send null for both, so keep the first non-empty and never overwrite it back to blank.
			if id_text != "":
				slot["id"] = id_text
			if d.get("function") is Dictionary:
				var fn: Dictionary = d["function"]
				var name_text := _text(fn.get("name"))
				if name_text != "":
					slot["name"] = name_text
				if fn.has("arguments"):
					slot["args"] += _text(fn.get("arguments"))
			# Any other field is provider state the call must carry back verbatim — Gemini's thought signature arrives as extra_content.google.thought_signature — so it is kept whole, whatever the provider names it.
			var extra: Dictionary = slot["extra"]
			for key in d:
				if key in ["index", "id", "type", "function"] or d[key] == null:
					continue
				if extra.get(key) is Dictionary and d[key] is Dictionary:
					extra[key].merge(d[key])
				elif not extra.has(key):
					extra[key] = d[key]

	## The terminal events for the stream: the assembled tool calls (if any) then done+stats, emitted at most once.
	func _finish_events() -> Array:
		if _finished:
			return []
		_finished = true
		var events: Array = []
		if not _tool_calls.is_empty():
			# Raw calls ride ahead of the canonical ones so LLMClient holds them before the tool_calls signal fires (see last_assistant_blocks); only when a call carried provider state, so every other server's history stays as before.
			if _tool_calls.any(func(slot: Dictionary) -> bool: return not slot["extra"].is_empty()):
				events.append({"type": "assistant_blocks", "blocks": _raw_tool_calls()})
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

	## The accumulated calls in OpenAI's own wire shape, provider fields included, as _echoed_tool_calls resends them.
	func _raw_tool_calls() -> Array:
		var out: Array = []
		for slot in _tool_calls:
			var call: Dictionary = slot["extra"].duplicate(true)
			call.merge({"id": _text(slot["id"]), "type": "function", "function": {"name": _text(slot["name"]), "arguments": _text(slot["args"])}}, true)
			out.append(call)
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


## OpenAI Responses API: /v1/responses SSE, /v1/models — OpenAI's newer wire format, which its GPT-5.6-class models require to combine reasoning effort with function tools (/v1/chat/completions rejects that pairing on them, naming this endpoint as the fix; every older OpenAI model also serves under /v1/responses, so one source kind covers the whole catalog).
## Extends OpenAIAdapter for what the two formats share — auth, the /v1/models list and its window probe, the /v1 base handling — and overrides the chat/completion paths and both translation edges: canonical history becomes Responses input items on send (the system prompt as top-level instructions, tool results as function_call_output items), and the semantic SSE events reassemble into canonical events on receive.
## Every request sends store:false — the plugin's own history stays the only record, nothing accumulates server-side — with reasoning items riding back encrypted (encrypted_content), so a tool loop continues statelessly: the API requires every output item between the last user message and a function_call_output echoed back untouched (dropping one 400s naming the missing item), so a tool-call turn's raw items are handed back via the assistant_blocks event and replayed verbatim inside the trailing loop — the same echo mechanism AnthropicAdapter uses.
class OpenAIResponsesAdapter extends OpenAIAdapter:
	var _items: Array = [] ## Finalized output items in stream order (reasoning, message, function_call — from response.output_item.done), replayed for the tool-loop echo; the terminal frame's authoritative output list replaces the accumulation when it arrives (see _adopt_response).
	var _summary_item: String = "" ## The reasoning item whose summary parts are currently streaming; a change marks an item boundary needing its own paragraph break (see the summary_part arm).

	func chat_path() -> String:
		return "/responses"

	func build_chat_body(model: String, messages: Array, tools: Array, effort: String = "", _cache_ttl: int = 0) -> Dictionary:
		var body := {
			"model": model,
			"input": _translate_input(messages, not tools.is_empty()),
			"stream": true,
			# store:false keeps this plugin's history the only record; reasoning then rides back encrypted for the stateless echo (see the class doc). The include is the legacy spelling — current servers attach encrypted_content on store:false by themselves, and the explicit ask keeps older gateways working.
			"store": false,
			"include": ["reasoning.encrypted_content"],
		}
		var instructions := _system_text(messages)
		if instructions != "":
			body["instructions"] = instructions
		# The knob is reasoning.effort, and its value set is the level vocabulary itself ("none" included; "minimal" died with the GPT-5.0 generation — the user-maintained level config gates what each model is offered, see GDLLMEfforts). A selected level also asks for the reasoning summary trace so the thinking shows in the log — except where none can exist ("none"/"minimal") or the user turned the ask off (OpenAI gates summaries behind organization verification; see GDLLMSettings.OPENAI_REASONING_SUMMARIES).
		if effort != "":
			var reasoning := {"effort": effort}
			if effort != "none" and effort != "minimal" and GDLLMSettings.is_openai_reasoning_summaries_enabled():
				reasoning["summary"] = "auto"
			body["reasoning"] = reasoning
		if not tools.is_empty():
			body["tools"] = _translate_tools(tools)
		return body

	## The canonical function-schema envelope flattened to the Responses tool shape — the same fields minus the nesting ({type, name, description, parameters}); chat/completions keeps them under a "function" wrapper, this API doesn't.
	func _translate_tools(tools: Array) -> Array:
		var out: Array = []
		for entry in tools:
			var fn: Dictionary = entry["function"] if entry is Dictionary and entry.get("function") is Dictionary else {}
			if fn.is_empty():
				continue
			var schema: Variant = fn.get("parameters")
			out.append({
				"type": "function",
				"name": _text(fn.get("name")),
				"description": _text(fn.get("description")),
				"parameters": schema if schema is Dictionary and not schema.is_empty() else {"type": "object", "properties": {}},
			})
		return out

	## Canonical history translated to Responses input items. An assistant tool-call turn inside the trailing tool loop (everything after the last real user message) echoes its stored raw output items verbatim — reasoning items, encrypted content intact — because the API validates every item between the last user message and a function_call_output (see the class doc); earlier turns rebuild from text + synthesized call ids so past reasoning isn't re-sent (goal 1), which the API accepts for completed turns. Each tool result becomes a function_call_output bound to its call id by order. With `allow_tool_items` false — a tool-less request such as the loop-brake reflection or a subagent's forced final answer — the loop's turns flatten to plain text instead, so a request that declares no tools can't trip over tool items it never announced.
	func _translate_input(messages: Array, allow_tool_items: bool) -> Array:
		var last_user := _last_user_index(messages)
		var out: Array = []
		var pending_ids: Array = [] # call_ids of the last assistant turn's calls, awaiting their tool results in order
		for i in messages.size():
			var msg: Variant = messages[i]
			if not (msg is Dictionary):
				continue
			var role := String(msg.get("role", ""))
			if role == "system":
				continue # lifted to the top-level instructions field by build_chat_body
			if role == "tool":
				var result_text := _text(msg.get("content"))
				if allow_tool_items:
					out.append({"type": "function_call_output", "call_id": _text(pending_ids.pop_front()) if not pending_ids.is_empty() else "", "output": result_text if result_text.strip_edges() != "" else "(no output)"})
				else:
					out.append({"role": "user", "content": _flatten_tool_result_text(msg)})
			elif role == "assistant" and msg.get("tool_calls") is Array and not msg["tool_calls"].is_empty():
				if allow_tool_items:
					pending_ids = []
					out.append_array(_assistant_call_items(msg, i > last_user, pending_ids, i))
				else:
					out.append(_assistant_text_item(_flatten_call_text(msg)))
			elif role == "assistant":
				out.append(_assistant_text_item(_text(msg.get("content"))))
			else:
				var user_text := _text(msg.get("content"))
				# The API rejects empty text content, and history can hold a blank echo.
				out.append({"role": role, "content": user_text if user_text.strip_edges() != "" else "(empty)"})
		return out

	## One assistant text turn as an input item. Echoed assistant text must be an output_text part — the input_text spelling is rejected on the assistant role.
	static func _assistant_text_item(text: String) -> Dictionary:
		return {"role": "assistant", "content": [{"type": "output_text", "text": text if text.strip_edges() != "" else "(empty)"}]}

	## The input items for one assistant tool-call turn. Inside the trailing loop (`use_raw`), the stored raw output items replay verbatim and their real call_ids fill `pending_ids`; otherwise the turn rebuilds from its text and calls with synthesized ids ("call_gdllm_<turn>_<n>"), which the API accepts for completed turns as long as each function_call_output echoes the same id back. Raw items carrying no function_call at all were recorded under another kind (the source's Kind switched mid-loop; Anthropic stores tool_use/thinking blocks in the same field) — replaying those verbatim 400s on alien item types, so they fall through to the rebuild, which always speaks this wire format.
	func _assistant_call_items(msg: Dictionary, use_raw: bool, pending_ids: Array, turn_index: int) -> Array:
		var raw: Variant = msg.get("assistant_blocks")
		if use_raw and raw is Array and not raw.is_empty():
			for item in raw:
				if item is Dictionary and String(item.get("type", "")) == "function_call":
					pending_ids.append(_text(item.get("call_id")))
			if not pending_ids.is_empty():
				return raw
		var items: Array = []
		var text := _text(msg.get("content"))
		if text.strip_edges() != "":
			items.append(_assistant_text_item(text))
		var n := 0
		for tc in msg["tool_calls"]:
			var fn: Dictionary = tc["function"] if tc is Dictionary and tc.get("function") is Dictionary else {}
			var raw_args: Variant = fn.get("arguments", {})
			var call_id := "call_gdllm_%d_%d" % [turn_index, n]
			n += 1
			pending_ids.append(call_id)
			items.append({"type": "function_call", "call_id": call_id, "name": _text(fn.get("name")), "arguments": raw_args if raw_args is String else JSON.stringify(raw_args)})
		return items

	func parse_line(line: String) -> Array:
		var trimmed := line.strip_edges()
		# SSE frames are "event: name" + "data: {json}" pairs; the data's own `type` field repeats the event name, so only data lines matter (this API sends no [DONE] sentinel — a terminal response.* frame ends the stream).
		if not trimmed.begins_with("data:"):
			return []
		var json := JSON.new()
		if json.parse(trimmed.substr(5).strip_edges()) != OK:
			return []
		var data: Variant = json.get_data()
		if not (data is Dictionary):
			return []
		var type := String(data.get("type", ""))
		# A proxy in front of a Responses endpoint (LiteLLM and friends) reports a mid-stream failure as a typeless {"error": {...}} frame — the shape the chat-completions adapter handles; dropping it would hide the provider's real complaint behind a wire-format attribution.
		if type == "" and data.has("error"):
			var err: Variant = data["error"]
			var message := _text(err.get("message", "")) if err is Dictionary else _text(err)
			return [{"type": "error", "message": message if message != "" else trimmed}]
		match type:
			"response.output_text.delta":
				var content := _text(data.get("delta"))
				if content != "":
					return [{"type": "content", "text": content}]
			"response.reasoning_summary_text.delta", "response.reasoning_text.delta":
				# Hosted models expose reasoning as summary deltas (requested in build_chat_body); raw reasoning_text arrives only from open-weight serving stacks.
				var thinking := _text(data.get("delta"))
				if thinking != "":
					return [{"type": "thinking", "text": thinking}]
			"response.reasoning_summary_part.added":
				# Parts are separate paragraphs whose deltas carry no separator of their own; break between them or consecutive summaries render glued into one run-on line. summary_index restarts per reasoning item (a multi-tool turn can carry several), so a new item's first part breaks too.
				var item_id := _text(data.get("item_id"))
				var new_item := item_id != _summary_item and _summary_item != ""
				_summary_item = item_id
				if int(data.get("summary_index", 0)) > 0 or new_item:
					return [{"type": "thinking", "text": "\n\n"}]
			"response.refusal.done":
				# A refusal replaces the message's output_text, so without this arm the turn would end as a clean empty reply; latching _finished keeps the trailing response.completed from dressing it up as a finished turn.
				_finished = true
				var refusal := _text(data.get("refusal"))
				return [{"type": "error", "message": "OpenAI declined this request (refusal)." if refusal == "" else "OpenAI declined this request (refusal): %s" % refusal}]
			"response.output_item.done":
				if data.get("item") is Dictionary:
					_items.append(data["item"])
			"response.completed":
				_adopt_response(data)
				return _finish_events()
			"response.incomplete":
				_adopt_response(data)
				var resp: Dictionary = data["response"] if data.get("response") is Dictionary else {}
				var details: Dictionary = resp["incomplete_details"] if resp.get("incomplete_details") is Dictionary else {}
				var reason := _text(details.get("reason"))
				# "max_output_tokens" canonicalizes to "length" so a capped reply is disclosed, not shown as finished; any other reason ("content_filter") passes verbatim.
				return _finish_events("length" if reason == "max_output_tokens" else (reason if reason != "" else "incomplete"))
			"response.failed":
				var resp: Dictionary = data["response"] if data.get("response") is Dictionary else {}
				var err: Dictionary = resp["error"] if resp.get("error") is Dictionary else {}
				return [{"type": "error", "message": _prefixed_error(_text(err.get("code", "")), _text(err.get("message", "")), trimmed)}]
			"error":
				# The stream-level error frame carries code/message at top level, unlike response.failed's embedded shape.
				return [{"type": "error", "message": _prefixed_error(_text(data.get("code", "")), _text(data.get("message", "")), trimmed)}]
		# Every other recognized lifecycle frame (response.created, output_item.added, content_part.added, …) is proof the reply speaks this wire format — a reasoning turn can stream nothing user-visible for minutes, and the client's format guard must not read that silence as an unrecognized reply, even behind a proxy that drops individual frames (see LLMClient._stream_saw_event).
		return [{"type": "progress"}] if type.begins_with("response.") else []

	## Fold a terminal frame's embedded response snapshot into state: its usage (the only place this API reports the counters — there is no include_usage concept here) and its authoritative output list, which replaces the per-item accumulation when present so the echo is exactly what the server finalized.
	func _adopt_response(data: Dictionary) -> void:
		var resp: Dictionary = data["response"] if data.get("response") is Dictionary else {}
		if resp.get("usage") is Dictionary:
			_usage = resp["usage"]
		if resp.get("output") is Array and not resp["output"].is_empty():
			_items = resp["output"]

	## The terminal events for the stream: the raw output items for the tool-loop echo, the assembled tool calls, then done+stats — emitted at most once (`stop` arrives pre-canonicalized from parse_line; "" is a normal finish). The signature keeps the parent's zero-argument form callable — GDScript requires override compatibility — and an inherited bare call reads as a normal finish.
	func _finish_events(stop: String = "") -> Array:
		if _finished:
			return []
		_finished = true
		var events: Array = []
		var calls: Array = []
		for item in _items:
			if item is Dictionary and String(item.get("type", "")) == "function_call":
				# Arguments arrive as a JSON string; a no-argument call's empty string parses as {} rather than a noisy failure.
				var args_text := _text(item.get("arguments"))
				var parsed: Variant = JSON.parse_string(args_text) if args_text != "" else {}
				calls.append({"function": {"name": _text(item.get("name")), "arguments": parsed if parsed is Dictionary else {}}})
		if not calls.is_empty():
			# The raw items ride ahead of the calls so LLMClient holds them before the tool_calls signal fires (see last_assistant_blocks).
			events.append({"type": "assistant_blocks", "blocks": _items})
			events.append({"type": "tool_calls", "calls": calls})
		events.append({"type": "done", "stats": _responses_stats(_usage), "stop": stop})
		return events

	func completion_request(model: String, system_prompt: String, prompt: String) -> Dictionary:
		# input as an explicit one-item list, never the documented string shorthand: api.openai.com accepts both, but the ChatGPT subscription backend (which inherits this) rejects the shorthand with "Input must be a list". store:false for the same statelessness as the chat path.
		var body := {"model": model, "input": [{"role": "user", "content": prompt}], "store": false}
		if system_prompt != "":
			body["instructions"] = system_prompt
		return {"path": "/responses", "body": body}

	## The reply text out of a parsed (non-streamed) response body: the first output_text part of the first message item — reasoning items precede it on thinking models.
	func parse_completion(data: Variant) -> String:
		if data is Dictionary and data.get("output") is Array:
			for item in data["output"]:
				if item is Dictionary and String(item.get("type", "")) == "message" and item.get("content") is Array:
					for part in item["content"]:
						if part is Dictionary and String(part.get("type", "")) == "output_text":
							return _text(part.get("text"))
		return ""

	func parse_completion_stats(data: Variant) -> Dictionary:
		if data is Dictionary and data.get("usage") is Dictionary:
			return _responses_stats(data["usage"])
		return {}

	## This API's usage counters mapped onto the plugin's stat keys — the field names differ from chat/completions (input_tokens/output_tokens, not prompt_/completion_); no durations are reported, so those stay 0. Static so the non-streamed completion path maps through the same rule.
	static func _responses_stats(usage: Dictionary) -> Dictionary:
		return {
			"tokens_in": int(usage.get("input_tokens", 0)),
			"tokens_out": int(usage.get("output_tokens", 0)),
			"prompt_eval_duration": 0,
			"eval_duration": 0,
			"total_duration": 0,
		}

	## The parent's suffix list plus this API's own chat path, so a pasted …/v1/responses endpoint reduces to its /v1 base the same way.
	func _endpoint_suffixes() -> Array:
		return super._endpoint_suffixes() + ["/responses"]


## OpenAI ChatGPT Subscription: the parent's Responses wire format, served from the ChatGPT backend and authenticated with the user's ChatGPT sign-in (OAuth access tokens; see GDLLMOAuth) instead of an API key — how a Plus/Pro subscription drives the harness without API billing.
## Only auth and discovery differ from the parent: the Bearer token is a ChatGPT access token whose own account-id claim must ride back as a header (read straight from the token, so no side channel is needed), and the backend publishes no model list or window probe — the model set is a maintained constant, and context windows come from the Effort Configuration dialog alone.
class OpenAIChatGPTAdapter extends OpenAIResponsesAdapter:
	const ORIGINATOR := "gdllm" ## The client identifier sent with each request, naming this harness honestly.
	## The models the subscription backend serves, maintained by hand — there is no listing endpoint to sweep. An id the backend no longer takes fails loudly at request time, naming the model. Verified against the Codex model docs 2026-10-07; ids on their announced retirement path (gpt-5.5 retires 2026-10-14) are deliberately not listed.
	const MODELS: Array[String] = ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-astra", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

	## The ChatGPT access token rides as a Bearer like an API key, and the backend additionally wants the token's own chatgpt_account_id claim echoed as a header, plus the originator stamp.
	func auth_headers(api_key: String) -> PackedStringArray:
		var headers := super.auth_headers(api_key)
		headers.append("originator: " + ORIGINATOR)
		var claims := GDLLMOAuth.jwt_claims(api_key.strip_edges())
		var auth_claim: Dictionary = claims["https://api.openai.com/auth"] if claims.get("https://api.openai.com/auth") is Dictionary else {}
		var account := LLMAdapter._text(auth_claim.get("chatgpt_account_id"))
		if account != "":
			headers.append("chatgpt-account-id: " + account)
		return headers

	func static_models() -> PackedStringArray:
		return PackedStringArray(MODELS)

	## No listing endpoint exists to read a window from; the Effort Configuration dialog's declared figure is the only source (see GDLLMEfforts.context_window_for).
	func context_probe(_model: String) -> Dictionary:
		return {}

	## The subscription backend serves only streamed responses, so the one-shot completion (session titles) asks for a stream too; HTTPRequest buffers the whole SSE transcript, which parse_completion_stream then reads at once.
	func completion_request(model: String, system_prompt: String, prompt: String) -> Dictionary:
		var req := super.completion_request(model, system_prompt, prompt)
		req["body"]["stream"] = true
		return req

	## A buffered SSE transcript run through a fresh stream parse: the terminal frame's text and usage, lifted for the completion path. {} when no terminal frame parsed — the body wasn't this API's stream, and the normal failure attribution should speak.
	func parse_completion_stream(text: String) -> Dictionary:
		var parser := OpenAIChatGPTAdapter.new()
		var content := ""
		var stats := {}
		var finished := false
		for line in text.split("\n"):
			for event in parser.parse_line(line):
				match String(event.get("type", "")):
					"content":
						content += String(event.get("text", ""))
					"done":
						stats = event.get("stats", {})
						finished = true
		if not finished:
			return {}
		return {"text": content, "stats": stats}

	## A pasted full …/responses endpoint reduces to the backend base; nothing else is ever pasted for this kind.
	func _endpoint_suffixes() -> Array:
		return ["/responses"]

	## A pathless base gains the ChatGPT backend prefix, not /v1 (see OpenAIAdapter.normalize_base, which both rules ride).
	func _default_path() -> String:
		return "/backend-api/codex"


## Anthropic Messages API: /v1/messages SSE, /v1/models. Auth is x-api-key + anthropic-version, not a Bearer token.
## Translates the canonical shape to Anthropic's content-block format on send (the system prompt as a top-level field, tool results as tool_result blocks inside user messages) and reassembles the streamed events (thinking, text, tool_use input fragments) back into canonical events on receive.
## Adaptive thinking is requested only on model families documented to accept it; a selected effort level rides output_config.effort beside it ("none" becomes thinking:disabled instead — see build_chat_body), and a tool-call turn's raw content blocks are handed back via the assistant_blocks event because the API requires them echoed — thinking signatures intact — to continue a tool loop.
class AnthropicAdapter extends LLMAdapter:
	const API_VERSION := "2023-06-01" ## The anthropic-version header every request carries.
	const CACHE_TTL_DEFAULT := 300 ## Anthropic's default prompt-cache lifetime (the 5-minute tier).
	const CACHE_TTL_LONG := 3600 ## The only other lifetime the API offers: the 1-hour tier, requested as ttl "1h" at 2x write cost instead of 1.25x (worth it from about three reuses).
	# The fallback chat max_tokens (for a model whose cap no sweep has reported yet — /v1/messages requires the field, and the chat path streams, so a large value can't hit a transport timeout) and the one-shot completion cap are user-configurable — see GDLLMTunables' gdllm/network section.

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
					# Each entry reports the model's own output cap; carry it so chat requests send the model's true limit instead of a guessed constant (models capped below GDLLMTunables.ANTHROPIC_MAX_TOKENS_FALLBACK, e.g. Opus 4.1's 32K, 400 on the constant).
					var cap: Variant = entry.get("max_tokens")
					if (cap is float or cap is int) and int(cap) > 0:
						_output_caps[id] = int(cap)
		return names

	## The max_tokens for a chat request on `model`: the cap /v1/models reported for it, or GDLLMTunables.ANTHROPIC_MAX_TOKENS_FALLBACK when no sweep has seen the model.
	func _chat_max_tokens(model: String) -> int:
		return int(_output_caps.get(model, GDLLMTunables.geti(GDLLMTunables.ANTHROPIC_MAX_TOKENS_FALLBACK)))

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
		var body := {"model": model, "max_tokens": GDLLMTunables.geti(GDLLMTunables.ANTHROPIC_COMPLETION_MAX_TOKENS), "messages": [{"role": "user", "content": prompt}]}
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
				return [{"type": "error", "message": _prefixed_error(_text(err.get("type", "")), message, trimmed)}]
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
		var last_user := _last_user_index(messages)
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
					out.append({"role": "user", "content": _flatten_tool_result_text(msg)})
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

	## The content blocks for one assistant tool-call turn. Inside the trailing loop (`use_raw`), the stored raw blocks are echoed verbatim and their real tool_use ids fill `pending_ids`; otherwise the turn rebuilds from its text and calls with synthesized ids ("toolu_gdllm_<turn>_<n>"), which the stateless API accepts as long as each tool_result echoes the same id back. Raw blocks carrying no tool_use at all were recorded under another kind (the source's Kind switched mid-loop; the Responses adapter stores function_call/reasoning items in the same field) — replaying those verbatim 400s on alien block types, so they fall through to the rebuild, which always speaks this wire format.
	func _assistant_call_blocks(msg: Dictionary, use_raw: bool, pending_ids: Array, turn_index: int) -> Array:
		var raw: Variant = msg.get("assistant_blocks")
		if use_raw and raw is Array and not raw.is_empty():
			for block in raw:
				if block is Dictionary and String(block.get("type", "")) == "tool_use":
					pending_ids.append(_text(block.get("id")))
			if not pending_ids.is_empty():
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


## Google Gemini API, native: /v1beta/models/{model}:streamGenerateContent?alt=sse, /v1beta/models. Authenticated with an AI Studio API key; the alternative to pointing the Chat Completions kind at Google's /v1beta/openai endpoint.
## Translates at both edges: canonical history becomes `contents` (role "model" for the assistant, tool results as functionResponse parts merged into one user turn, since the API rejects two turns in a row from the same role), the system prompt rides as systemInstruction, and tools as functionDeclarations carrying their JSON Schema as-is. A tool-call turn's raw model parts — thought signatures included — are handed back via the assistant_blocks event and replayed verbatim inside the trailing loop, because Gemini validates the signatures to continue a tool loop; earlier turns rebuild from text and calls (goal 1).
class GeminiAdapter extends LLMAdapter:
	const PLUGIN_CFG := "res://addons/gdllm-godot-agentic-harness/plugin.cfg" ## Read for the version this harness reports itself as (see client_header).
	static var _client_header: String = "" ## The x-goog-api-client value, built once (see client_header).
	var _model: String = "" ## The model build_chat_body was called for; the API names it in the URL, which chat_path reads after the body is built.
	var _parts: Array = [] ## The model turn's raw parts as streamed, adjacent text pieces joined, for the assistant_blocks echo.
	var _calls: Array = [] ## Canonical tool calls collected from functionCall parts; each arrives whole.
	var _usage: Dictionary = {} ## The latest usageMetadata; every chunk carries running totals.
	var _finished: bool = false ## Guards the terminal events so a trailing frame can't double-emit.

	func chat_path() -> String:
		return "/models/%s:streamGenerateContent?alt=sse" % model_id(_model)

	## The model id as the API's path wants it — the list hands out "models/…" names, which the picker shows without the prefix.
	static func model_id(model: String) -> String:
		return model.trim_prefix("models/")

	## AI Studio keys ride x-goog-api-key, never the URL; the client header names this harness to Google so its traffic is attributed to GDLLM.
	func auth_headers(api_key: String) -> PackedStringArray:
		var headers := PackedStringArray(["x-goog-api-client: " + client_header()])
		if api_key.strip_edges() != "":
			headers.append("x-goog-api-key: " + api_key.strip_edges())
		return headers

	## "gdllm/<plugin version>", or bare "gdllm" when plugin.cfg can't be read.
	static func client_header() -> String:
		if _client_header == "":
			var cfg := ConfigFile.new()
			var version := String(cfg.get_value("plugin", "version", "")) if cfg.load(PLUGIN_CFG) == OK else ""
			_client_header = "gdllm/" + version if version != "" else "gdllm"
		return _client_header

	func build_chat_body(model: String, messages: Array, tools: Array, effort: String = "", _cache_ttl: int = 0) -> Dictionary:
		_model = model
		var body := {"contents": _translate_messages(messages, not tools.is_empty())}
		var system := _system_text(messages)
		if system != "":
			body["systemInstruction"] = {"parts": [{"text": system}]}
		if not tools.is_empty():
			body["tools"] = [{"functionDeclarations": _translate_tools(tools)}]
		# includeThoughts asks for the reasoning summary so the thinking shows in the log (goal 2). "none" is a zero budget — the only off switch, which models that can't stop thinking reject by name; any other level is a thinkingLevel, gated per model by the user's level config (see GDLLMEfforts).
		var thinking := {"includeThoughts": true}
		if effort == "none":
			thinking = {"thinkingBudget": 0}
		elif effort != "":
			thinking["thinkingLevel"] = effort
		body["generationConfig"] = {"thinkingConfig": thinking}
		return body

	## OpenAI-envelope tool schemas as Gemini function declarations. parametersJsonSchema takes the schema as written; the older `parameters` field accepts only an OpenAPI subset and rejects keywords the plugin's schemas use.
	static func _translate_tools(tools: Array) -> Array:
		var out: Array = []
		for tool in tools:
			var fn: Dictionary = tool.get("function", {}) if tool is Dictionary else {}
			var decl := {"name": _text(fn.get("name")), "description": _text(fn.get("description"))}
			if fn.get("parameters") is Dictionary:
				decl["parametersJsonSchema"] = fn["parameters"]
			out.append(decl)
		return out

	## Canonical history as Gemini contents. With `allow_tool_parts` false — a tool-less request such as the loop-brake reflection or a subagent's forced final answer — the API rejects functionCall/functionResponse parts it has no declarations for, so the loop's turns flatten to plain text the model can still read.
	func _translate_messages(messages: Array, allow_tool_parts: bool) -> Array:
		var last_user := _last_user_index(messages)
		var out: Array = []
		var pending: Array = [] # the last model turn's calls as {name, id}, awaiting their results in order
		for i in messages.size():
			var msg: Variant = messages[i]
			if not (msg is Dictionary):
				continue
			var role := String(msg.get("role", ""))
			if role == "system":
				continue # lifted to systemInstruction by build_chat_body
			if role == "tool":
				if allow_tool_parts:
					_push(out, "user", [_function_response(msg, pending.pop_front() if not pending.is_empty() else {})])
				else:
					_push(out, "user", [{"text": _flatten_tool_result_text(msg)}])
			elif role == "assistant" and msg.get("tool_calls") is Array and not msg["tool_calls"].is_empty():
				if allow_tool_parts:
					pending = []
					_push(out, "model", _model_call_parts(msg, i > last_user, pending))
				else:
					_push(out, "model", [{"text": _flatten_call_text(msg)}])
			else:
				var text := _text(msg.get("content"))
				# The API rejects an empty text part, and history can hold a blank assistant echo.
				_push(out, "model" if role == "assistant" else "user", [{"text": text if text.strip_edges() != "" else "(empty)"}])
		return out

	## Append `parts` as a `role` turn, folding them into the previous turn when it has the same role — the API requires turns to alternate, and parallel tool results land as consecutive tool messages.
	static func _push(out: Array, role: String, parts: Array) -> void:
		if not out.is_empty() and String(out[-1]["role"]) == role:
			out[-1]["parts"].append_array(parts)
		else:
			out.append({"role": role, "parts": parts})

	## The parts for one model tool-call turn. Inside the trailing loop (`use_raw`), the stored raw parts replay verbatim, signatures intact; otherwise the turn rebuilds from its text and calls. Stored blocks whose functionCall count doesn't match the turn were recorded under another kind (Anthropic's blocks, OpenAI tool calls, after a mid-loop Kind switch) and fall through to the rebuild. `pending` receives each call's {name, id} so the results that follow bind to them.
	func _model_call_parts(msg: Dictionary, use_raw: bool, pending: Array) -> Array:
		var raw: Variant = msg.get("assistant_blocks")
		if use_raw and raw is Array:
			var calls: Array = raw.filter(func(p: Variant) -> bool: return p is Dictionary and p.get("functionCall") is Dictionary)
			if not calls.is_empty() and calls.size() == msg["tool_calls"].size():
				for part in calls:
					pending.append({"name": _text(part["functionCall"].get("name")), "id": _text(part["functionCall"].get("id"))})
				return raw.duplicate(true)
		var parts: Array = []
		var text := _text(msg.get("content"))
		if text.strip_edges() != "":
			parts.append({"text": text})
		for tc in msg["tool_calls"]:
			var fn: Dictionary = tc["function"] if tc is Dictionary and tc.get("function") is Dictionary else {}
			var args: Variant = fn.get("arguments", {})
			parts.append({"functionCall": {"name": _text(fn.get("name")), "args": args if args is Dictionary else {}}})
			pending.append({"name": _text(fn.get("name")), "id": ""})
		return parts

	## One tool result as a functionResponse part, bound to its call by name (and id, when the model gave one). The result text rides unparsed under "output" — the API wants an object, and re-encoding a tool's JSON text would change what the model sees from what the log shows.
	static func _function_response(msg: Dictionary, call: Dictionary) -> Dictionary:
		var name := _text(call.get("name"))
		if name == "":
			name = _text(msg.get("tool_name"))
		var text := _text(msg.get("content"))
		var response := {"name": name, "response": {"output": text if text.strip_edges() != "" else "(no output)"}}
		if _text(call.get("id")) != "":
			response["id"] = call["id"]
		return {"functionResponse": response}

	func parse_line(line: String) -> Array:
		var trimmed := line.strip_edges()
		# SSE frames are bare "data: {json}" lines; the stream ends when the connection closes, with finishReason on the last candidate.
		if not trimmed.begins_with("data:"):
			return []
		var json := JSON.new()
		if json.parse(trimmed.substr(5).strip_edges()) != OK:
			return []
		var data: Variant = json.get_data()
		# A mid-stream failure arrives as an error object, sometimes wrapped in a one-item list.
		if data is Array and data.size() == 1:
			data = data[0]
		if not (data is Dictionary):
			return []
		if data.get("error") is Dictionary:
			var err: Dictionary = data["error"]
			return [{"type": "error", "message": _prefixed_error(_text(err.get("status")), _text(err.get("message")), trimmed)}]
		if data.get("usageMetadata") is Dictionary:
			_usage = data["usageMetadata"]
		var candidates: Variant = data.get("candidates")
		if not (candidates is Array) or candidates.is_empty():
			# No candidate at all means the prompt itself was blocked; the reason is the only explanation the API gives.
			var feedback: Variant = data.get("promptFeedback")
			if feedback is Dictionary and _text(feedback.get("blockReason")) != "":
				return [{"type": "error", "message": "Gemini blocked the prompt (%s) and returned no reply — rephrase the request, or check the safety ratings in the raw response." % _text(feedback["blockReason"])}]
			return [{"type": "progress"}]
		var candidate: Dictionary = candidates[0] if candidates[0] is Dictionary else {}
		var events: Array = []
		var content: Variant = candidate.get("content")
		if content is Dictionary and content.get("parts") is Array:
			for part in content["parts"]:
				if part is Dictionary:
					events.append_array(_part_events(part))
		var finish := _text(candidate.get("finishReason"))
		if finish != "":
			events.append_array(_finish_events(finish))
		elif events.is_empty():
			events.append({"type": "progress"})
		return events

	## The canonical events for one streamed part, recording it for the echo.
	func _part_events(part: Dictionary) -> Array:
		_record(part)
		if part.get("functionCall") is Dictionary:
			var call: Dictionary = part["functionCall"]
			_calls.append({"function": {"name": _text(call.get("name")), "arguments": call["args"] if call.get("args") is Dictionary else {}}})
			return []
		var text := _text(part.get("text"))
		if text == "":
			return []
		return [{"type": "thinking" if bool(part.get("thought", false)) else "content", "text": text}]

	## Keep one streamed part for the echo, joining a text piece onto the previous part when both are the same kind of text and the earlier one carries no signature — a turn can stream in hundreds of pieces, and the signature that closes a run must stay on the run it closes.
	func _record(part: Dictionary) -> void:
		if not _parts.is_empty() and part.has("text") and not part.has("functionCall"):
			var last: Dictionary = _parts[-1]
			if last.has("text") and not last.has("thoughtSignature") and bool(last.get("thought", false)) == bool(part.get("thought", false)):
				last["text"] = _text(last["text"]) + _text(part["text"])
				if part.has("thoughtSignature"):
					last["thoughtSignature"] = part["thoughtSignature"]
				return
		_parts.append(part.duplicate(true))

	## The terminal events: the raw parts and tool calls (if any), then done+stats, emitted at most once.
	func _finish_events(reason: String) -> Array:
		if _finished:
			return []
		_finished = true
		var events: Array = []
		if not _calls.is_empty():
			# The raw parts ride ahead of the calls so LLMClient holds them before the tool_calls signal fires (see last_assistant_blocks).
			events.append({"type": "assistant_blocks", "blocks": _parts})
			events.append({"type": "tool_calls", "calls": _calls})
		# MAX_TOKENS is the output cap under this API's spelling; anything else past STOP (SAFETY, MALFORMED_FUNCTION_CALL, …) is disclosed verbatim.
		var stop := "length" if reason == "MAX_TOKENS" else _canonical_stop(reason, PackedStringArray(["STOP"]))
		events.append({"type": "done", "stats": _stats_from(_usage), "stop": stop})
		return events

	## Gemini usage on the plugin's stat keys. candidatesTokenCount leaves out the thinking, which is billed as output all the same.
	static func _stats_from(usage: Dictionary) -> Dictionary:
		return {
			"tokens_in": int(usage.get("promptTokenCount", 0)),
			"tokens_out": int(usage.get("candidatesTokenCount", 0)) + int(usage.get("thoughtsTokenCount", 0)),
			"prompt_eval_duration": 0,
			"eval_duration": 0,
			"total_duration": 0,
		}

	func models_path() -> String:
		return "/models?pageSize=1000"

	## Models that can chat (generateContent), shown without the "models/" prefix; embedding and other models are left out.
	func parse_models(data: Variant) -> PackedStringArray:
		var names := PackedStringArray()
		if data is Dictionary and data.get("models") is Array:
			for entry in data["models"]:
				if entry is Dictionary and entry.get("supportedGenerationMethods") is Array and "generateContent" in entry["supportedGenerationMethods"]:
					names.append(model_id(_text(entry.get("name"))))
		return names

	func context_probe(model: String) -> Dictionary:
		return {"path": "/models/" + model_id(model), "method": HTTPClient.METHOD_GET, "body": {}}

	func parse_context_window(data: Variant, _model: String = "") -> int:
		return int(data.get("inputTokenLimit", 0)) if data is Dictionary else 0

	func completion_request(model: String, system_prompt: String, prompt: String) -> Dictionary:
		var body := {"contents": [{"role": "user", "parts": [{"text": prompt}]}]}
		if system_prompt != "":
			body["systemInstruction"] = {"parts": [{"text": system_prompt}]}
		return {"path": "/models/%s:generateContent" % model_id(model), "body": body}

	## The reply text out of a non-streamed response: every non-thought text part of the first candidate, joined.
	func parse_completion(data: Variant) -> String:
		if not (data is Dictionary) or not (data.get("candidates") is Array) or data["candidates"].is_empty():
			return ""
		var content: Variant = data["candidates"][0].get("content") if data["candidates"][0] is Dictionary else null
		if not (content is Dictionary) or not (content.get("parts") is Array):
			return ""
		var text := ""
		for part in content["parts"]:
			if part is Dictionary and not bool(part.get("thought", false)):
				text += _text(part.get("text"))
		return text

	func parse_completion_stats(data: Variant) -> Dictionary:
		return _stats_from(data["usageMetadata"]) if data is Dictionary and data.get("usageMetadata") is Dictionary else {}

	## A pasted endpoint reduces to the /v1beta base, and a bare host gains it. Google's /v1beta/openai compatibility URL is left alone, so the 404 hint can name the right kind for it.
	func normalize_base(base: String) -> String:
		var out := super.normalize_base(base)
		var models_at := out.find("/models")
		if models_at != -1:
			out = out.left(models_at)
		var scheme_end := out.find("://")
		if out != "" and out.find("/", scheme_end + 3 if scheme_end != -1 else 0) == -1:
			out += "/v1beta"
		return out
