@tool
class_name LLMClient extends Node
## Thin wrapper around an HTTPRequest that talks to the configured LLM endpoint. It owns the HTTPRequest as a child, so freeing this node frees the transport too — just add an instance to the tree (e.g. `add_child(client)`) and free it normally.

signal response_received(text: String, stats: Dictionary) ## `stats` holds the turn's usage/timing counters: tokens_in/out plus durations exactly as the provider reported them (absent when it reported nothing), and est_tokens_in/out — this client's chars-per-token estimates of the wire payload sent and the reply that came back, always present (completion requests included). A `truncated: true` flag marks a reply that was cut short, either by the transport (the stream ended without the provider's completion marker — socket drop or keep-alive return) or by the provider itself (an abnormal stop reason on its terminal frame, carried beside the flag as `stop_reason`: "length" for the output-token cap, else the provider's reason verbatim), so the caller can present the partial reply as incomplete rather than finished. For a chat request this fires once, at the end, with the full accumulated reply — unless the turn ended in tool calls, in which case `tool_calls_received` fires instead.
signal tool_calls_received(tool_calls: Array, content: String, stats: Dictionary) ## The model ended its turn asking to call one or more tools (Ollama's `message.tool_calls`). Fires in place of `response_received`; `content` is any text the model produced alongside the calls. The caller runs the tools, appends the results, and sends again.
signal thinking_delta(text: String) ## A chunk of the model's reasoning as it streams in (Ollama's `message.thinking`); never emitted for non-thinking models.
signal generating_started() ## The model has finished reasoning and produced its first content byte; fires once per chat request, before `response_received`.
signal request_failed(reason: String)
signal models_received(models: PackedStringArray)
signal context_window_received(model: String, tokens: int) ## A context-window probe resolved for `model` (the bare name it asked about, echoed so a caller can drop a reply that outlived a model switch): the source's reported maximum context in tokens, or 0 when the probe failed or timed out — an unknown, never an invented figure. Fired at most once per fetch_context_window call.

# The connect and model-fetch timeouts are user-configurable — see GDLLMTunables' gdllm/network section. The fetch timeout is enforced with a SceneTreeTimer, not HTTPRequest.timeout — that internal timer fails to start for a node built in _init, leaving an unreachable host's fetch to hang forever and any sweep awaiting it stuck.
const BODY_EXCERPT_CHARS := 180 ## How much of an unparseable response body an error message may quote — enough to recognize what answered, short enough that a whole HTML page never lands in the log.

@export var api_base: String = "http://localhost:11434" ## The API endpoint, local or remote.
@export var model: String = "nemotron-3-nano:30b"
@export var api_key: String = "" ## Bearer token for sources that need one (Ollama Cloud, Poolside); empty for local/no-auth endpoints.
@export var adapter_kind: String = "ollama" ## Which wire format this client speaks (see GDLLMSources.KIND_*); selects the LLMAdapter used to build and parse requests.
var effort: String = "" ## Reasoning-effort level for chat requests (a GDLLMEfforts.LEVELS name; "" sends nothing and lets the model's defaults prevail). Adopted from configure_from and translated to each provider's own knob by the adapter (see LLMAdapter.build_chat_body).
var cache_ttl: int = 0 ## The session's effective prompt-cache TTL in seconds, adopted from configure_from beside effort; only the Anthropic adapter acts on it (past the default tier it requests the 1-hour cache lifetime — see AnthropicAdapter.cache_control_for), the rest ignore it.
var source_id: String = "" ## Id of the configured source, carried from configure_from so a stale-source refusal can name it.
var source_stale: bool = false ## The configured source id no longer resolves (deleted or renamed; see GDLLMSources.resolve_qualified); every send refuses loudly instead of running on rerouted connection details.
var _source_project_id: String = "" ## Cloud Code Assist `cloudaicompanionProject` resolved by GDLLMGeminiOAuth.load_code_assist_project at sign-in. Forwarded to GeminiOAuthAdapter.set_project_id on every adapter build so the AGY envelope carries it. Empty for every other kind.
var http_request: HTTPRequest
var last_assistant_blocks: Array = [] ## The provider's raw assistant content blocks for the request that just finished in tool calls, when its adapter needs them echoed back to continue the loop (Anthropic, the OpenAI Responses API; see LLMAdapter's assistant_blocks event). Empty for providers whose canonical echo suffices. Read it right after tool_calls_received and store it beside the turn.
var last_models_error: String = "" ## Why the latest fetch_models resolved empty ("" = no failure, the source is genuinely bare); the model sweep reads it so an empty source is reported with its cause instead of a bare "returned nothing".
var _tags_http_request: HTTPRequest ## Separate transport so a model-list fetch can't collide with an in-flight chat request.
var _tags_pending: bool = false ## True between issuing a model-list request and its first terminal event (response, request error, or timeout); guards models_received against a double-emit when a late response and the timeout race.
var _context_http_request: HTTPRequest ## Third transport for the context-window probe, so it can't collide with a chat request or a model-list fetch.
var _context_pending: bool = false ## True between issuing a probe and its first terminal event; guards context_window_received against a late response racing the timeout.
var _context_model: String = "" ## The bare model the pending probe asked about, echoed on the emit.
var _context_probe_serial: int = 0 ## Bumped per probe; a superseded probe's timeout timer keeps ticking after its request is cancelled, and the serial keeps it from resolving the newer probe as empty.
var _busy: bool = false
var _auth_epoch: int = 0 ## Bumped by cancel(), so a subscription token refresh that outlives its request's cancellation stands down instead of resurrecting it — the shared _busy flag alone can't tell "cancelled" from "a newer send re-latched busy" (see _adopt_fresh_subscription_token).
var _completion_est_in: int = 0 ## chars-per-token estimate of the completion request payload (taken in _post), the non-streamed counterpart of _stream_est_in.

## Streaming chat state. HTTPRequest buffers the whole body, so chat runs on an owned transport polled from _process instead — that's the only way to read a reply (thinking + content) chunk by chunk. The transport is LLMStreamTransport rather than a raw HTTPClient because HTTPClient reads only the Content-Length and chunked body framings, filing an unframed (connection-delimited) streaming body — the shape koboldcpp's built-in server sends — as empty.
var _stream_client: LLMStreamTransport
var _streaming: bool = false
var _stream_pending_bytes: PackedByteArray = PackedByteArray() ## Body bytes whose trailing UTF-8 sequence may still be incomplete; only the longest cleanly-decodable prefix moves to _stream_buffer, so a codepoint split across two drains never decodes as replacement chars.
var _stream_buffer: String = "" ## Unparsed tail of the NDJSON body, or the raw body when the response wasn't 200.
var _stream_content: String = "" ## Assistant content accumulated across chunks; emitted whole via response_received at the end.
var _stream_tool_calls: Array = [] ## Tool calls collected from the stream (Ollama emits them whole, not token-by-token); when non-empty at the end, tool_calls_received fires instead of response_received.
var _stream_generating: bool = false ## generating_started has fired for this request (first content byte seen).
var _stream_stats: Dictionary = {}
var _stream_est_in: int = 0 ## chars-per-token estimate of the request payload actually sent, taken before streaming starts; the provider-independent counterpart of a reported prompt count.
var _stream_est_out_chars: int = 0 ## Characters streamed back this request (thinking + content + tool-call JSON); converted at the configured chars-per-token ratio at finish for the reply-side estimate.
var _stream_done: bool = false ## A chunk reported done:true; finish after the current poll drains.
var _stream_stop: String = "" ## The done event's canonicalized abnormal stop reason ("" = normal finish; "length" = the output-token cap; else the provider's reason verbatim — see LLMAdapter._canonical_stop).
var _stream_bad_code: int = 0 ## Non-200 status; _stream_buffer then holds the error body.
var _stream_received_body: bool = false ## Any body bytes arrived; tells a socket that closed silent (never answered) from one whose reply this source's wire format didn't recognize.
var _stream_error: String = "" ## An error field in the stream itself (e.g. bad model); reported verbatim.
var _stream_connect_elapsed: float = 0.0
var _stream_sent_seen: int = 0 ## The transport's sent_bytes() at the last _process; an upload that advanced resets the connect clock, so only a stalled one can time out.
var _stream_saw_event: bool = false ## Some line of the body parsed into at least one adapter event — proof the reply speaks this source's wire format.
var _stream_idle_elapsed: float = 0.0 ## Seconds since body bytes last arrived; only consulted for replies that can't end themselves (an error status, or a body no line of which parses), where an unframed keep-alive stream may never close.
var _stream_adapter: LLMAdapter ## Per-request adapter; built in send_chat_request, holds any streaming parse state, dropped on teardown.


func _init() -> void:
	# HTTPRequest is our child, so it enters/leaves the tree with us and is freed automatically — no manual cleanup, no orphaned node in the editor tree.
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_request_completed)
	_tags_http_request = HTTPRequest.new()
	add_child(_tags_http_request)
	_tags_http_request.request_completed.connect(self._on_tags_completed)
	_context_http_request = HTTPRequest.new()
	add_child(_context_http_request)
	_context_http_request.request_completed.connect(self._on_context_completed)
	# Defining _process auto-enables per-frame processing; keep it off until a stream is actually running.
	set_process(false)


## Point this client at a resolved source in one call: endpoint, key, wire format, and bare model (see GDLLMSources.resolve_qualified), plus any reasoning-effort selection the caller stamped on the resolved Dictionary (see GDLLMChatSession._resolved_with_effort). The single path every consumer uses to configure a client. A stale resolution (its source was deleted or renamed) is adopted too, but latches source_stale so every send refuses instead of running on whatever connection fields it carries.
func configure_from(resolved: Dictionary) -> void:
	api_base = String(resolved.get("base_url", ""))
	api_key = String(resolved.get("api_key", ""))
	adapter_kind = String(resolved.get("kind", GDLLMSources.KIND_OLLAMA))
	model = String(resolved.get("model", ""))
	effort = String(resolved.get("effort", ""))
	cache_ttl = maxi(0, int(resolved.get("cache_ttl", 0)))
	source_id = String(resolved.get("source_id", ""))
	source_stale = bool(resolved.get("stale", false))
	# Stash the AGY project id from the source row (set by GDLLMGeminiOAuth.load_code_assist_project at sign-in / after a 401). It's a no-op for every other kind — _apply_source_overrides below ignores an empty project on adapters that don't expose set_project_id.
	_source_project_id = String(resolved.get("project_id", ""))


## Refuse to send when the configured source is stale, resolving the request as a failure that names what's missing. The emit is deferred so an await-based caller (GDLLMSubagent._send) reaches its await before the failure lands.
func _refuse_stale_source() -> bool:
	if not source_stale:
		return false
	var reason: String
	if source_id != "":
		reason = "Nothing was sent: model source \"%s\" no longer exists. Re-create it in the Connections dialog, or pick a model from a configured source." % source_id
	elif model == "":
		reason = "Nothing was sent: no model is selected. Pick one from the model picker."
	else:
		reason = "Nothing was sent: \"%s\" names no model source. Pick a model from a configured source." % model
	call_deferred("_emit_request_failed", reason)
	return true


func _emit_request_failed(reason: String) -> void:
	request_failed.emit(reason)


## A fresh adapter for this client's current wire format. Every call site that builds a request also needs the per-source overrides applied (AGY project id); centralizing it here keeps the overrides in sync with the adapter build so a model-list fetch, a context probe, a one-shot completion and a streamed chat all see the same project id.
func _make_adapter() -> LLMAdapter:
	var adapter := LLMAdapter.for_kind(adapter_kind)
	_apply_source_overrides(adapter)
	return adapter


## Per-adapter overrides that need to be applied before the request builder runs — currently just the AGY project id. Cheap to call, safe to call before any adapter that doesn't expose the override (the `has_method` guard makes it a no-op there).
func _apply_source_overrides(adapter: LLMAdapter) -> void:
	if _source_project_id != "" and adapter.has_method("set_project_id"):
		adapter.set_project_id(_source_project_id)


## For a subscription source (ChatGPT or Google AI Studio Antigravity), adopt a current access token as this request's api_key — refreshed silently through the stored refresh token when stale, since access tokens expire within hours and a long-idle session's next send must not ride a dead one. True to proceed; false when the request must not go out (never signed in, the refresh failed, or a cancel landed during it), the failure emitted with sign-in as the named fix (goal 3). Any other kind passes straight through.
func _adopt_fresh_subscription_token() -> bool:
	if adapter_kind != GDLLMSources.KIND_OPENAI_CHATGPT and adapter_kind != GDLLMSources.KIND_GEMINI_OAUTH:
		return true
	# Busy is latched across the await so a second send can't slip in mid-refresh; a cancel() during it bumps the epoch, which reads here as "stand down" — the flag alone can't be the sentinel, since a send issued after the cancel re-latches it and must not be hijacked by this stale continuation.
	_busy = true
	var epoch := _auth_epoch
	var token: String = ""
	if adapter_kind == GDLLMSources.KIND_GEMINI_OAUTH:
		token = await GDLLMGeminiOAuth.ensure_fresh(source_id, self)
	else:
		token = await GDLLMOAuth.ensure_fresh(source_id, self)
	if epoch != _auth_epoch or not _busy:
		return false # cancelled while refreshing; silence is the cancel contract
	_busy = false
	if token == "":
		var hint: String
		if adapter_kind == GDLLMSources.KIND_GEMINI_OAUTH:
			hint = "Not signed in to Google AI Studio Subscription for source \"%s\" (or the sign-in expired and couldn't refresh). Use Sign in with Google in the Connections dialog — the ⚙ beside the model picker." % source_id
		else:
			hint = "Not signed in to ChatGPT for source \"%s\" (or the sign-in expired and couldn't refresh). Use Sign in with ChatGPT in the Connections dialog — the ⚙ beside the model picker." % source_id
		call_deferred("_emit_request_failed", hint)
		return false
	api_key = token
	return true


## The header lines every request to this source carries: JSON content type, plus whatever auth scheme the adapter's provider wants for the configured key.
func _request_headers(adapter: LLMAdapter) -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json"])
	headers.append_array(adapter.auth_headers(api_key))
	return headers


## True while a request is in flight. Callers should check this before starting a new request so overlapping requests are ignored.
func is_busy() -> bool:
	return _busy


## Abort any in-flight request without emitting a result (no response_received/request_failed). Returns true if something was actually cancelled. Used by the chat's Stop button to interrupt a stuck tool loop or a long generation — the caller owns its own UI teardown, since it asked for the stop.
func cancel() -> bool:
	if _streaming:
		_teardown_stream() # closes the socket, stops polling, clears _busy — but stays silent
		return true
	if _busy:
		# Non-streaming path (completions), or a subscription token refresh still ahead of its request: drop the pending HTTPRequest and clear busy ourselves, since a cancelled request never fires request_completed; the epoch bump tells an in-flight refresh its request is dead (see _adopt_fresh_subscription_token).
		_auth_epoch += 1
		http_request.cancel_request()
		_busy = false
		return true
	return false


## Fetch installed model names for this source (path/parse set by the adapter); results arrive via `models_received`. Always emits within GDLLMTunables.MODEL_FETCH_TIMEOUT — an empty list on any failure or timeout, with the cause left on `last_models_error` — so a caller awaiting the signal per source never stalls a sweep.
func fetch_models() -> void:
	last_models_error = ""
	var static_names := _make_adapter().static_models()
	if not static_names.is_empty():
		# This source's backend publishes no listing endpoint, so its maintained set stands in without touching the network — emitted deferred so an awaiting sweep's await always lands first.
		_tags_pending = true
		var names := PackedStringArray(static_names)
		names.sort()
		call_deferred("_emit_models", names)
		return
	_tags_pending = true
	# The deadline is armed before anything can suspend, and through the main loop rather than get_tree() because this node may not be in the tree yet — it must cover the tree_entered wait below as well as an unreachable host that never sends a RST, or a fetch stuck on either would break the always-emits promise.
	(Engine.get_main_loop() as SceneTree).create_timer(GDLLMTunables.getf(GDLLMTunables.MODEL_FETCH_TIMEOUT)).timeout.connect(_on_tags_timeout)
	# request() needs the transport inside the scene tree; when called during setup (right after add_child) it isn't yet, so wait for it.
	if not _tags_http_request.is_inside_tree():
		await _tags_http_request.tree_entered
		if not _tags_pending:
			return # the deadline already resolved this fetch as empty while we waited
	var adapter := _make_adapter()
	# Adapters whose listing endpoint is a POST with a body (GeminiOAuthAdapter's :v1internal:fetchAvailableModels) ship models_request() returning {path, method, body}; others fall back to models_path() + GET. The project id, when the source row has one, is applied to the adapter here so the AGY envelope carries it.
	_apply_source_overrides(adapter)
	var req := adapter.models_request()
	var err := _tags_http_request.request(adapter.normalize_base(api_base) + String(req.get("path", "")), _request_headers(adapter), int(req.get("method", HTTPClient.METHOD_GET)), JSON.stringify(req.get("body", {})))
	if err != OK:
		last_models_error = "the request could not be sent (%s)" % error_string(err)
		push_warning("LLMClient: model list request error: %s" % error_string(err))
		_emit_models(PackedStringArray())


## Give up on a model-list fetch that outran GDLLMTunables.MODEL_FETCH_TIMEOUT: cancel the socket and resolve the fetch as empty. No-op once a response (or error) already resolved it.
func _on_tags_timeout() -> void:
	if not _tags_pending:
		return
	last_models_error = "no response within %ss" % GDLLMTunables.getf(GDLLMTunables.MODEL_FETCH_TIMEOUT)
	push_warning("LLMClient: model list fetch timed out after %ss" % GDLLMTunables.getf(GDLLMTunables.MODEL_FETCH_TIMEOUT))
	_tags_http_request.cancel_request()
	_emit_models(PackedStringArray())


func _on_tags_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		last_models_error = _request_result_failure(result)
		push_warning("LLMClient: model list fetch failed: %s" % last_models_error)
		_emit_models(PackedStringArray())
		return
	if response_code != 200:
		# The body rides along because it's what tells e.g. a bad API key (a 401 that says so) apart from a dead route.
		last_models_error = "HTTP %d: %s" % [response_code, body.get_string_from_utf8().strip_edges().left(300)]
		# A 404 on the models path almost always means the Base URL's shape doesn't match the kind, so the error names the fix instead of leaving only the provider's complaint.
		if response_code == 404:
			last_models_error += " — " + _kind_404_hint()
		push_warning("LLMClient: model list fetch failed (%s)" % last_models_error)
		_emit_models(PackedStringArray())
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		last_models_error = "the response wasn't valid JSON"
		push_warning("LLMClient: model list fetch failed: %s" % last_models_error)
		_emit_models(PackedStringArray())
		return
	var names := _make_adapter().parse_models(json.get_data())
	names.sort()
	_emit_models(names)


## The likely fix for a 404 on this kind's model-list path — in practice a URL or Kind that doesn't match the server (see each adapter's normalize_base and the Connections dialog's per-kind hints) — appended to last_models_error so the failure guides to the solution instead of only quoting the provider.
func _kind_404_hint() -> String:
	if adapter_kind == GDLLMSources.KIND_OPENAI:
		return "check the source's URL and Kind: a bare http://host:port, a base ending in /v1, or a full endpoint like …/v1/chat/completions all work for an OpenAI-compatible server — an Ollama server needs the Ollama kind instead"
	if adapter_kind == GDLLMSources.KIND_OPENAI_RESPONSES:
		return "check the source's URL and Kind: OpenAI's own API lives at https://api.openai.com/v1 (pasting the full …/v1/responses endpoint works too) — a third-party server usually wants the OpenAI-Compatible (Chat Completions) kind instead"
	if adapter_kind == GDLLMSources.KIND_OPENAI_CHATGPT:
		return "check the source's URL: the ChatGPT subscription backend lives at %s, which the Connections dialog prefills — a 404 usually means the URL was edited" % GDLLMSources.DEFAULT_CHATGPT_BASE
	if adapter_kind == GDLLMSources.KIND_ANTHROPIC:
		return "check the source's URL: Anthropic wants https://api.anthropic.com (pasting the full …/v1/messages endpoint works too)"
	if adapter_kind == GDLLMSources.KIND_GEMINI:
		return "check the source's URL and key: Google AI Studio's Gemini API lives at %s — a 401 means the key isn't an AI Studio API key or the project lacks the Generative Language API enabled" % GDLLMSources.DEFAULT_GEMINI_BASE
	if adapter_kind == GDLLMSources.KIND_GEMINI_OAUTH:
		return "check the source's URL: Cloud Code Assist / Antigravity lives at %s — a 404 usually means the URL was edited, the sign-in is on a non-whitelisted tenant, or the stored project id is stale" % GDLLMSources.DEFAULT_GEMINI_OAUTH_BASE
	return "check the source's URL and Kind: an Ollama server takes a bare http://host:port or a full endpoint like …/api/chat — an OpenAI-compatible server (LM Studio, llama.cpp, koboldcpp, vLLM, most others...) needs the OpenAI-Compatible (Chat Completions) kind instead"


## Emit the model list exactly once per fetch, so a late response and the timeout can't both fire models_received (which would double-count the source in a sweep).
func _emit_models(names: PackedStringArray) -> void:
	if not _tags_pending:
		return
	_tags_pending = false
	models_received.emit(names)


## Ask this source for the configured model's maximum context window (Ollama's /api/show, Anthropic's /v1/models/{id}, an OpenAI-compatible /v1/models list read for a vendor window field — see LLMAdapter.context_probe) and resolve via context_window_received within GDLLMTunables.MODEL_FETCH_TIMEOUT: the reported window, or 0 on any failure (an OpenAI-compatible server carrying no such field resolves to 0, an honest unknown). Returns false without emitting when this source's API offers no probe at all or the transport isn't in the tree yet, so the caller shows an honest unknown instead of waiting; a newer probe supersedes a pending one, which then never emits — its reply would describe a model the caller already left.
## Whether this source's API offers a context-window probe at all (see LLMAdapter.context_probe): false marks the window as unknowable from the wire — a settled fact the caller can act on now — as opposed to fetch_context_window's false, which can also mean the probe merely couldn't run yet.
func has_context_probe() -> bool:
	return not _make_adapter().context_probe(model).is_empty()


func fetch_context_window() -> bool:
	var adapter := _make_adapter()
	var probe := adapter.context_probe(model)
	# The tree guard needs no await (unlike fetch_models): a session's client is tree-parented before any model applies, and a missed probe retries on the next model switch.
	if probe.is_empty() or not _context_http_request.is_inside_tree():
		return false
	if _context_pending:
		_context_http_request.cancel_request()
	_context_probe_serial += 1
	_context_pending = true
	_context_model = model
	# Armed through the main loop for the same reason as the model-list deadline: HTTPRequest's own timeout can't be trusted here, and an unreachable host that never RSTs would otherwise hang the probe forever.
	(Engine.get_main_loop() as SceneTree).create_timer(GDLLMTunables.getf(GDLLMTunables.MODEL_FETCH_TIMEOUT)).timeout.connect(_on_context_timeout.bind(_context_probe_serial))
	var body: Dictionary = probe.get("body", {})
	var err := _context_http_request.request(adapter.normalize_base(api_base) + String(probe.get("path", "")), _request_headers(adapter), int(probe.get("method", HTTPClient.METHOD_GET)), JSON.stringify(body) if not body.is_empty() else "")
	if err != OK:
		push_warning("LLMClient: context-window probe error: %s" % error_string(err))
		_emit_context_window(0)
	return true


## Give up on a probe that outran GDLLMTunables.MODEL_FETCH_TIMEOUT, resolving it as unknown. No-op once a response resolved it or a newer probe superseded it (the serial check — cancelling the old request doesn't stop this timer).
func _on_context_timeout(serial: int) -> void:
	if serial != _context_probe_serial or not _context_pending:
		return
	push_warning("LLMClient: context-window probe timed out after %ss" % GDLLMTunables.getf(GDLLMTunables.MODEL_FETCH_TIMEOUT))
	_context_http_request.cancel_request()
	_emit_context_window(0)


func _on_context_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		# Non-fatal: the meter shows an unknown and the next model apply retries; the warning still names the cause for the console.
		push_warning("LLMClient: context-window probe failed (%s)" % (_request_result_failure(result) if result != HTTPRequest.RESULT_SUCCESS else "HTTP %d: %s" % [response_code, body.get_string_from_utf8().strip_edges().left(300)]))
		_emit_context_window(0)
		return
	# _context_model, not `model`: the probe may have been issued for a model the session has since switched away from, and the reply describes the one it asked about.
	_emit_context_window(_make_adapter().parse_context_window(JSON.parse_string(body.get_string_from_utf8()), _context_model))


## Resolve the pending probe exactly once, tagged with the model it asked about.
func _emit_context_window(tokens: int) -> void:
	if not _context_pending:
		return
	_context_pending = false
	context_window_received.emit(_context_model, tokens)


## One-shot (non-streamed) prompt→reply request, used for background chores like session-title generation.
func send_completion_request(prompt_json: String, system_prompt: String) -> void:
	if _refuse_stale_source():
		return
	var req := _make_adapter().completion_request(model, system_prompt, prompt_json)
	_post(String(req["path"]), JSON.stringify(req["body"]))


## Send a multi-turn chat conversation, streamed. `messages` is an ordered Array of {"role": "user"|"assistant"|"tool", "content": String}; a leading system message is prepended when `system_prompt` is non-empty. `tools` is an optional array of function schemas the model may call — when the model chooses to, the turn ends via `tool_calls_received` instead of `response_received`. Reasoning arrives incrementally via `thinking_delta` as the model produces it, and the finished reply (plus usage stats) arrives once via `response_received`. Errors surface through `request_failed`.
func send_chat_request(messages: Array, system_prompt: String = "", tools: Array = []) -> void:
	if _refuse_stale_source():
		return
	if _busy:
		# A visible failure, not a silent drop: without request_failed the caller waits forever on a request that never left.
		push_warning("LLMClient busy; ignoring request")
		request_failed.emit("Client busy: a request is already in flight, so this one was not sent.")
		return
	if not await _adopt_fresh_subscription_token():
		return
	var full_messages: Array = []
	if system_prompt != "":
		full_messages.append({"role": "system", "content": system_prompt})
	full_messages.append_array(messages)
	# The adapter builds the provider-specific body (Ollama passthrough, or an OpenAI translation) and holds any streaming parse state for this request.
	_stream_adapter = _make_adapter()
	var payload := JSON.stringify(_stream_adapter.build_chat_body(model, full_messages, tools, effort, cache_ttl))

	var endpoint := _parse_endpoint()
	_stream_client = LLMStreamTransport.new()
	# Re-prepend the base_url's path (e.g. "/v1") that the endpoint split carved off, so the adapter's bare path lands on the full endpoint. Even an immediately-doomed begin (bad hostname) fails through the transport's state on a later poll, keeping one error path.
	_stream_client.begin(endpoint["host"], endpoint["port"], TLSOptions.client() if endpoint["use_ssl"] else null, String(endpoint["base_path"]) + _stream_adapter.chat_path(), _request_headers(_stream_adapter), payload)

	_busy = true
	_streaming = true
	_stream_pending_bytes = PackedByteArray()
	_stream_buffer = ""
	_stream_content = ""
	_stream_tool_calls = []
	last_assistant_blocks = []
	_stream_generating = false
	_stream_stats = {}
	_stream_est_in = estimate_tokens(payload.length())
	_stream_est_out_chars = 0
	_stream_done = false
	_stream_stop = ""
	_stream_bad_code = 0
	_stream_received_body = false
	_stream_error = ""
	_stream_connect_elapsed = 0.0
	_stream_sent_seen = 0
	_stream_saw_event = false
	_stream_idle_elapsed = 0.0
	set_process(true)


## Drive the streaming chat transport: connect, POST, then read the reply's body chunk by chunk as its own framing delivers it. Runs only between the request and its completion (set_process is toggled around the stream).
func _process(delta: float) -> void:
	if not _streaming:
		return
	_stream_client.poll()
	match _stream_client.state:
		LLMStreamTransport.State.RESOLVING, LLMStreamTransport.State.CONNECTING, LLMStreamTransport.State.TLS_HANDSHAKE, LLMStreamTransport.State.SENDING:
			# The whole pre-response phase is time-boxed — but an upload that is still moving resets the clock, so a slow link only fails once it stalls outright. Once the request is away the model may think for as long as it likes.
			if _stream_client.state == LLMStreamTransport.State.SENDING and _stream_client.sent_bytes() != _stream_sent_seen:
				_stream_sent_seen = _stream_client.sent_bytes()
				_stream_connect_elapsed = 0.0
			_stream_connect_elapsed += delta
			if _stream_connect_elapsed > GDLLMTunables.getf(GDLLMTunables.STREAM_CONNECT_TIMEOUT):
				_fail_stream(_endpoint_failure("it didn't answer within %ss" % GDLLMTunables.getf(GDLLMTunables.STREAM_CONNECT_TIMEOUT)))
		LLMStreamTransport.State.WAITING:
			pass # request away; waiting on the response headers (prompt processing lives here — no timeout)
		LLMStreamTransport.State.BODY:
			_read_stream_body()
			if _stream_done:
				_finish_stream()
			elif _stream_bad_code != 0 or (_stream_received_body and not _stream_saw_event):
				# A reply that can't end itself: an error status, or body bytes no line of which parses as this wire format. Either may ride an unframed keep-alive stream whose close never comes (Connection: close ignored — koboldcpp holds its socket open), and neither can produce the done event that ends a healthy turn — so idle time since the last byte caps the wait. Generation silence never lands here: a healthy stream's bytes arrive as parsed events.
				_stream_idle_elapsed += delta
				if _stream_idle_elapsed > GDLLMTunables.getf(GDLLMTunables.STREAM_CONNECT_TIMEOUT):
					_finish_stream()
		LLMStreamTransport.State.DONE:
			# The body ended by its own framing's rule — a terminal chunk, the promised length, or (for an unframed stream) the socket closing. Drain the tail, then wrap up with what we have; _finish_stream tells a finished reply from a cut-off one by the adapter's done event, not by how the bytes stopped.
			_read_stream_body()
			_finish_stream()
		LLMStreamTransport.State.FAILED:
			_fail_stream(_transport_failure())
		_:
			# IDLE is unreachable while _streaming; any state this match doesn't know is a bug that would otherwise spin silently forever.
			_fail_stream("The connection to %s failed (unexpected transport state %d)." % [api_base, _stream_client.state])


## Drain whatever body bytes the transport has decoded this frame and parse any complete NDJSON lines out of the buffer. Bytes stage through _stream_pending_bytes so a UTF-8 sequence split across two drains decodes whole instead of as replacement chars at both ends.
func _read_stream_body() -> void:
	if _stream_client.response_code != 0 and _stream_client.response_code != 200:
		_stream_bad_code = _stream_client.response_code
	var chunk := _stream_client.read_chunk()
	if chunk.size() > 0:
		_stream_received_body = true
		_stream_idle_elapsed = 0.0
		_stream_pending_bytes.append_array(chunk)
		var complete := _utf8_complete_prefix(_stream_pending_bytes)
		if complete > 0:
			_stream_buffer += _stream_pending_bytes.slice(0, complete).get_string_from_utf8()
			_stream_pending_bytes = _stream_pending_bytes.slice(complete)
	# On a non-200 the body is an error message, not NDJSON; keep it whole for the failure report.
	if _stream_bad_code == 0:
		_parse_stream_lines()


## The longest prefix of `bytes` that ends on a complete UTF-8 sequence — everything, unless the tail is a partial multi-byte codepoint still awaiting its continuation bytes. A malformed tail (no lead byte within reach) counts as complete; the decoder's replacement char is then the honest reading.
static func _utf8_complete_prefix(bytes: PackedByteArray) -> int:
	var size := bytes.size()
	var i := size - 1
	while i >= 0 and i >= size - 3:
		var b := bytes[i]
		if b < 0x80:
			return size # tail ends on ASCII; nothing pending
		if b >= 0xC0:
			# A lead byte: its high bits say how many bytes the sequence needs.
			var need := 2
			if b >= 0xF0:
				need = 4
			elif b >= 0xE0:
				need = 3
			return size if size - i >= need else i
		i -= 1 # a continuation byte; keep walking back toward its lead
	return size


## Pull each newline-terminated JSON object out of the buffer, leaving any partial trailing line for the next frame.
func _parse_stream_lines() -> void:
	while true:
		var nl := _stream_buffer.find("\n")
		if nl == -1:
			return
		var line := _stream_buffer.substr(0, nl).strip_edges()
		_stream_buffer = _stream_buffer.substr(nl + 1)
		if line != "":
			_handle_stream_line(line)


## Hand one streamed line to the adapter and fold each canonical event it yields into our state — the wire-format details (Ollama NDJSON vs OpenAI SSE) live in the adapter; this stays format-agnostic.
func _handle_stream_line(line: String) -> void:
	for event in _stream_adapter.parse_line(line):
		_apply_stream_event(event)


## Fold one canonical stream event into state: emit thinking, accumulate content (firing generating_started on the first byte), collect tool calls, and capture the terminal stats or error.
func _apply_stream_event(event: Dictionary) -> void:
	_stream_saw_event = true
	match String(event.get("type", "")):
		"progress":
			pass # a recognized frame with nothing streamable yet (a Responses lifecycle event); emitted only so the wire-format guard above knows the reply parses before the first visible delta arrives
		"thinking":
			var thinking := String(event.get("text", ""))
			if thinking != "":
				_stream_est_out_chars += thinking.length()
				thinking_delta.emit(thinking)
		"content":
			var content := String(event.get("text", ""))
			if content != "":
				if not _stream_generating:
					_stream_generating = true
					generating_started.emit()
				_stream_est_out_chars += content.length()
				_stream_content += content
		"tool_calls":
			if event.get("calls") is Array:
				# A tool-call turn's output is mostly the call JSON, so its serialized length is the reply-side estimate.
				_stream_est_out_chars += JSON.stringify(event["calls"]).length()
				_stream_tool_calls.append_array(event["calls"])
		"assistant_blocks":
			if event.get("blocks") is Array:
				last_assistant_blocks = event["blocks"]
		"done":
			_stream_stats = event.get("stats", {})
			_stream_stop = String(event.get("stop", ""))
			_stream_done = true
		"error":
			_stream_error = String(event.get("message", ""))
			_stream_done = true


## End a stream cleanly and report the outcome: the reasoning error, the HTTP error body, or the finished reply.
func _finish_stream() -> void:
	if not _streaming:
		return
	# Flush the decode pipeline before judging the outcome. Held-back bytes decode now — an incomplete trailing sequence's replacement char is the honest reading, since its continuation bytes will never come — and a final line the socket closed without terminating still yields its events, often the terminal marker itself, whose loss would stamp a finished reply truncated.
	if _stream_pending_bytes.size() > 0:
		_stream_buffer += _stream_pending_bytes.get_string_from_utf8()
		_stream_pending_bytes = PackedByteArray()
	if _stream_bad_code == 0 and _stream_buffer.strip_edges() != "":
		_handle_stream_line(_stream_buffer.strip_edges())
		_stream_buffer = ""
	_teardown_stream()
	if _stream_error != "":
		request_failed.emit(_stream_error + _failure_hints(_stream_error))
	elif _stream_bad_code != 0:
		var body := _stream_buffer.strip_edges()
		request_failed.emit("HTTP %d: %s%s" % [_stream_bad_code, body, _failure_hints(body)])
	elif not _stream_done and _stream_content == "" and _stream_tool_calls.is_empty():
		# The stream ended before anything usable arrived — a failure, not an empty reply — and the three ways that happens point at different levers, so name the one that applies.
		if _stream_est_out_chars > 0:
			request_failed.emit("Connection to %s closed mid-reply, before any usable content arrived." % api_base)
		elif _stream_received_body:
			request_failed.emit("%s answered, but nothing in the reply matched this source's wire format — check that the source's API type fits the endpoint in the Connections dialog." % api_base)
		else:
			request_failed.emit("Connection to %s closed before any reply arrived." % api_base)
	elif not _stream_tool_calls.is_empty():
		tool_calls_received.emit(_stream_tool_calls, _stream_content, _stream_final_stats())
	else:
		response_received.emit(_stream_content, _stream_final_stats())


## The finished request's stats: whatever the provider reported (possibly nothing), plus this client's own payload-size estimates under separate est_ keys — reported figures are never overwritten or synthesized.
func _stream_final_stats() -> Dictionary:
	var stats := _stream_stats.duplicate()
	stats["est_tokens_in"] = _stream_est_in
	stats["est_tokens_out"] = estimate_tokens(_stream_est_out_chars)
	# Every adapter emits its done event only on a genuine terminal marker (done:true, finish_reason/[DONE], message_stop), so its absence means the stream was cut off and the reply is partial.
	if not _stream_done:
		stats["truncated"] = true
	elif _stream_stop != "":
		# The provider finished cleanly but reported it cut the reply short (canonically "length": the output-token cap) — as truncated as a dropped socket, stamped with its cause so the caller can name it.
		stats["truncated"] = true
		stats["stop_reason"] = _stream_stop
	return stats


## The plugin-wide chars-per-token estimate (see the context inspector's reconstruction line), on the user-configurable ratio in GDLLMTunables; 0 stays 0 so absent traffic never shows a phantom count. Public so the chat's context meter and compaction trigger estimate with the same rule the stats do — every token estimate must route through here or the sizer and the meter disagree.
static func estimate_tokens(chars: int) -> int:
	return int(ceil(chars / GDLLMTunables.getf(GDLLMTunables.CHARS_PER_TOKEN)))


## The inverse estimate — how many characters a token budget is worth on the same user-configured ratio — for the compaction sizers that turn token targets into character splits.
static func estimate_chars(tokens: int) -> int:
	return int(tokens * GDLLMTunables.getf(GDLLMTunables.CHARS_PER_TOKEN))


## Abort a stream (transport/connect failure) and report `reason`.
func _fail_stream(reason: String) -> void:
	if not _streaming:
		return
	_teardown_stream()
	request_failed.emit(reason)


## When a failed request carried a reasoning-effort level and the provider's message points at that knob, name the level sent and where it's configured — the promised loud failure for an unaccepted level should land at the Effort Configuration dialog, not stop at a bare HTTP 400.
func _effort_hint(provider_message: String) -> String:
	if effort == "":
		return ""
	var lowered := provider_message.to_lower()
	if lowered.contains("effort") or lowered.contains("reasoning") or lowered.contains("think"):
		return " (This request sent reasoning effort \"%s\"; if this model doesn't accept that level, adjust its levels in the Effort Configuration dialog — the ⚡ beside the model picker.)" % effort
	return ""


## Every hint this client appends to a failed request's report, joined. The Responses hint stands alone when it fires on a Responses source: on the summaries-verification 400 the effort hint would name the wrong lever — the level is fine, the summary ask riding beside it is what the API rejected — and two contradictory instructions guide to no solution at all.
func _failure_hints(provider_message: String) -> String:
	var responses := _responses_api_hint(provider_message)
	if responses != "" and adapter_kind != GDLLMSources.KIND_OPENAI:
		return responses
	return _effort_hint(provider_message) + responses


## The Responses-API guidance for a failed request, when the provider's message points at a lever this plugin has: a chat-completions 400 naming v1/responses (OpenAI's newest models reject reasoning effort with tools on the older API — the fix is this source's Kind, one dropdown away, same URL and key; OpenAI spells the endpoint both with and without the leading slash, so the match takes the bare form) or a Responses 400 demanding organization verification for reasoning summaries (the fix is verifying, or the summaries switch in Editor Settings).
func _responses_api_hint(provider_message: String) -> String:
	if adapter_kind == GDLLMSources.KIND_OPENAI:
		if provider_message.to_lower().contains("v1/responses"):
			return " (This model wants OpenAI's newer Responses API: switch this source's Kind to \"OpenAI Responses API\" in the Connections dialog — the ⚙ beside the model picker. The URL and key stay the same.)"
	elif adapter_kind == GDLLMSources.KIND_OPENAI_RESPONSES or adapter_kind == GDLLMSources.KIND_OPENAI_CHATGPT:
		# The subscription kind inherits the same summary ask, so its rejections deserve the same guidance.
		var lowered := provider_message.to_lower()
		if lowered.contains("verified") and lowered.contains("summar"):
			return " (Reasoning summaries are requested alongside each effort level by default. Either verify your organization with OpenAI, or turn off \"Openai Reasoning Summaries\" under gdllm/network in Editor Settings — the model still reasons at the selected effort, without the visible trace.)"
	return ""


## The message shape for a failure that means the endpoint itself never answered: name it, name the cause, and point at where it's configured.
func _endpoint_failure(cause: String) -> String:
	return "Can't reach %s: %s. Check the source's endpoint in the Connections dialog." % [api_base, cause]


## A dead stream's failure message from the transport's failure kind, naming the actual cause (bad hostname, refused connect, TLS failure) instead of a bare enum integer.
func _transport_failure() -> String:
	match _stream_client.fail_kind:
		LLMStreamTransport.Fail.RESOLVE:
			return _endpoint_failure("the hostname didn't resolve")
		LLMStreamTransport.Fail.CONNECT:
			return _endpoint_failure("nothing accepted the connection")
		LLMStreamTransport.Fail.TLS:
			return _endpoint_failure("the TLS handshake failed")
		LLMStreamTransport.Fail.CLOSED_BEFORE_REPLY:
			return "%s closed the connection before replying." % api_base
		LLMStreamTransport.Fail.BROKE_MID_REQUEST:
			return "The connection to %s broke mid-request." % api_base
		LLMStreamTransport.Fail.BAD_RESPONSE:
			return "%s answered with something that isn't HTTP — check that the source's endpoint in the Connections dialog really is the model API. It begins: %s" % [api_base, _body_excerpt(_stream_client.fail_detail)]
		_:
			return "The connection to %s failed (transport failure %d)." % [api_base, _stream_client.fail_kind]


## _transport_failure's counterpart for the non-streamed HTTPRequest path, mapping its Result enum the same way.
func _request_result_failure(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_RESOLVE:
			return _endpoint_failure("the hostname didn't resolve")
		HTTPRequest.RESULT_CANT_CONNECT:
			return _endpoint_failure("nothing accepted the connection")
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return _endpoint_failure("the TLS handshake failed")
		HTTPRequest.RESULT_TIMEOUT:
			return "The request to %s timed out." % api_base
		HTTPRequest.RESULT_NO_RESPONSE:
			return "%s accepted the connection but sent no response." % api_base
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "The connection to %s broke mid-request." % api_base
		_:
			return "The request to %s failed in transport (HTTPRequest result %d)." % [api_base, result]


## The failure for a 200 whose body isn't JSON at all — the non-streamed path's counterpart to _finish_stream's wire-format attribution, and a background chore's only symptom, so it names the endpoint and the shape that actually answered rather than the parser's verdict. Three shapes cover what turns up here: an SSE frame means the endpoint streamed a request this path sent unstreamed, HTML means something other than the API answered (a proxy, a captive portal, a login page), and an empty body means it answered with nothing. The excerpt is capped because this text lands in the user's log verbatim.
static func _completion_parse_failure(endpoint: String, text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return "%s returned an empty body where the reply should have been. Check that the model is still loaded at that endpoint." % endpoint
	var head := "%s answered with something that isn't JSON" % endpoint
	if trimmed.begins_with("data:") or trimmed.begins_with("event:"):
		return "%s — it sent a streamed (SSE) response to a request that asked for a single reply, so the source's API type likely doesn't fit the endpoint in the Connections dialog." % head
	if trimmed.begins_with("<"):
		return "%s but markup, so something other than the model API answered — a proxy, a login page, or a wrong path in the source's endpoint. Check it in the Connections dialog. It begins: %s" % [head, _body_excerpt(trimmed)]
	return "%s. Check the source's endpoint and API type in the Connections dialog. It begins: %s" % [head, _body_excerpt(trimmed)]


## A single-line, length-capped quote of a response body for an error message — enough to recognize what answered, never enough to dump a page into the log.
static func _body_excerpt(text: String) -> String:
	var flat := text.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	while flat.contains("  "):
		flat = flat.replace("  ", " ")
	if flat.length() <= BODY_EXCERPT_CHARS:
		return "\"%s\"" % flat
	return "\"%s…\"" % flat.left(BODY_EXCERPT_CHARS)


## Common shutdown for both finish paths: stop polling, drop the socket, clear the busy flag.
func _teardown_stream() -> void:
	_streaming = false
	set_process(false)
	_busy = false
	_stream_adapter = null
	if _stream_client != null:
		_stream_client.close()
		_stream_client = null


## Split `api_base` into the pieces the streaming transport needs. Accepts "http(s)://host[:port][/path]"; the port defaults to the scheme's standard when omitted. `base_path` is the leading path segment of the base_url (e.g. "/v1" for an OpenAI-compatible endpoint, "" when none) — the transport connects by host+port alone, so the streaming path must re-prepend it or the request drops the segment and 404s.
func _parse_endpoint() -> Dictionary:
	var base := _make_adapter().normalize_base(api_base)
	var use_ssl := base.begins_with("https://")
	if base.begins_with("http://"):
		base = base.substr(7)
	elif base.begins_with("https://"):
		base = base.substr(8)
	var base_path := ""
	var slash := base.find("/")
	if slash != -1:
		# Keep the path prefix (minus any trailing slash, so joining an adapter path can't double the separator) for the request line.
		base_path = base.substr(slash).trim_suffix("/")
		base = base.substr(0, slash)
	var host := base
	var port := 443 if use_ssl else 80
	var colon := base.rfind(":")
	if colon != -1:
		host = base.substr(0, colon)
		port = int(base.substr(colon + 1))
	return {"host": host, "port": port, "use_ssl": use_ssl, "base_path": base_path}


func _post(path: String, payload: String) -> void:
	if _busy:
		# Same visible failure as send_chat_request's busy drop, so a completion caller never waits on a request that never left.
		push_warning("LLMClient busy; ignoring request")
		request_failed.emit("Client busy: a request is already in flight, so this one was not sent.")
		return
	if not await _adopt_fresh_subscription_token():
		return
	_busy = true
	_completion_est_in = estimate_tokens(payload.length())
	var adapter := _make_adapter()
	var err := http_request.request(adapter.normalize_base(api_base) + path, _request_headers(adapter), HTTPClient.METHOD_POST, payload)
	if err != OK:
		_busy = false
		request_failed.emit(_endpoint_failure("sending the request failed (%s)" % error_string(err)))


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit(_request_result_failure(result))
		return
	if response_code != 200:
		request_failed.emit("HTTP %s: %s" % [response_code, body.get_string_from_utf8()])
		return
	var text := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		# A backend that only streams (the ChatGPT subscription's) answers a one-shot completion with a buffered SSE transcript; its adapter can lift the reply out of that before the shape is declared a failure.
		var recovered := _make_adapter().parse_completion_stream(text)
		if not recovered.is_empty():
			var recovered_stats: Dictionary = recovered.get("stats", {})
			recovered_stats["est_tokens_in"] = _completion_est_in
			recovered_stats["est_tokens_out"] = estimate_tokens(String(recovered.get("text", "")).length())
			response_received.emit(String(recovered.get("text", "")), recovered_stats)
			return
		request_failed.emit(_completion_parse_failure(api_base, text))
		return
	# Same reported-first shape as _stream_final_stats — the body's usage plus the client's own payload estimates — so a background chore's panel can render the footer a chat turn gets.
	var adapter := _make_adapter()
	var reply := adapter.parse_completion(json.get_data())
	var stats := adapter.parse_completion_stats(json.get_data())
	stats["est_tokens_in"] = _completion_est_in
	stats["est_tokens_out"] = estimate_tokens(reply.length())
	response_received.emit(reply, stats)
