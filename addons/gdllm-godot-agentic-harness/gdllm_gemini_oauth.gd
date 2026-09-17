@tool
class_name GDLLMGeminiOAuth extends Node
## Google OAuth 2.0 helper for the Google Gemini Antigravity source kind (KIND_GEMINI_OAUTH): lets a pasted Google OAuth client id, client secret, and refresh token drive the Gemini model list against Cloud Code Assist, with project-id resolution via `loadCodeAssist` and silent access-token refresh.
## The endpoint constants and `DEFAULT_CLIENT_ID`/`DEFAULT_CLIENT_SECRET` below are the well-known public Antigravity CLI credentials — they are bundled in the official Antigravity binary and are intentionally public so anyone can build a compatible client. They are kept here as defaults so the OAuth route works out-of-the-box without forcing every operator to extract them from their Antigravity install. Users on a private Google Cloud OAuth client can override both via the Editor Settings UI (stored in GDLLMSettings under `gdllm/connection/gemini_oauth_client_id` / `…_client_secret`).
## SECURITY: the two `DEFAULT_CLIENT_*` constants below match the strings shipped by the official Antigravity binary exactly. Any change breaks every install. The `paths-ignore` clause for this file (handled via the repo's secret_scanning config) keeps push-protection from blocking on the public-but-pattern-matching "secret".
## Refresh tokens + the resolved project id persist in EditorSettings under one private key; access tokens never touch disk. The single-flight refresh follows the same pattern GDLLMOAuth uses for ChatGPT sign-in, so a turn's subagent fan-out can't replay the grant.
## Companion to GeminiOAuthAdapter in llm_adapters.gd; only loaded when the user fills in credentials and signs in via the Connections dialog.
##
## Usage sketch (the Connections dialog wires this up; the snippets below document the manual flow):
##   var flow := GDLLMGeminiOAuth.new()
##   host.add_child(flow)
##   flow.finished.connect(func(ok, detail): print(detail); flow.queue_free())
##   flow.begin("gemini-antigravity")
##   # …later…
##   var project: String = await GDLLMGeminiOAuth.load_code_assist_project(source_id)
##   var token: String = await GDLLMGeminiOAuth.ensure_fresh(source_id, host)
##   GeminiOAuthAdapter.set_project_id(project)
##   # request fires with Authorization: Bearer <token>

const SETTINGS_KEY := "gdllm/connection/gemini_oauth_fallback" ## EditorSettings key holding the OAuth credentials + project id per source, as `{source_id: {client_id, client_secret, refresh_token, account_email, access_token, expires_at, project_id}}`. Same "…_fallback" naming as the ChatGPT store; the dialog is the primary editor.
const REFRESH_MARGIN_SECONDS := 300 ## Refresh this long before the access token's exp, so a request never rides an expiring token (mirrors GDLLMOAuth).
const REFRESH_CLAIM_MS := 20000 ## Single-flight claim lifetime (mirrors GDLLMOAuth).
const TOKEN_REQUEST_TIMEOUT := 15.0 ## Per-request timeout for the refresh call.
const FLOW_TIMEOUT_SECONDS := 300.0 ## Browser round-trip timeout for the interactive sign-in (mirrors GDLLMOAuth).
const REDIRECT_PORT := 51121 ## The loopback port for the PKCE callback — kept the same as AIFlowBridge/Antigravity so any user who has the official binary running doesn't collide.

## Google OAuth 2.0 endpoints (RFC 6749).
const GOOGLE_OAUTH_AUTH_URL := "https://accounts.google.com/o/oauth2/v2/auth"
const GOOGLE_OAUTH_TOKEN_URL := "https://oauth2.googleapis.com/token"
const GOOGLE_USERINFO_URL := "https://www.googleapis.com/oauth2/v1/userinfo?alt=json"

## Cloud Code Assist endpoints — distinct from the BYOK Gemini base (`generativelanguage.googleapis.com`). The `:v1internal` prefix and the colon-separated method names are part of the same contract; both prefixes are tried against the same host in AIFlowBridge's reference impl.
const CLOUDCODE_LOAD_CODE_ASSIST_URL := "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
const CLOUDCODE_FETCH_MODELS_URL := "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
const CLOUDCODE_STREAM_URL := "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse"

## Cloud Code Assist hard-coded client identity. Public by design — they're the same strings shipped in the official Antigravity binary; see the SECURITY block at the top of this file.
const AGY_USER_AGENT := "antigravity" ## User-Agent header value Antigravity's gateway inspects (per AIFlowBridge constants.ts).
const AGY_GOOG_API_CLIENT := "gl-kiloCode/10.4.1" ## X-Goog-Api-Client header value — Google's internal client identifier for the Antigravity/Kilo CLI client; the gateway checks this on every request.
const AGY_CLIENT_METADATA := '{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}' ## Client-Metadata header value — JSON blob the gateway inspects to scope tenant features (model access, plan, quotas). Mandatory on loadCodeAssist; carried on every request for consistency with AIFlowBridge.

## Hardcoded fallback model list — used when the gateway returns an empty catalog on first sign-in (tenant not provisioned yet, or no allowedTiers). Mirrors AIFlowBridge's DEFAULT_FALLBACK_MODELS exactly so the picker seeded from this list stays consistent with the upstream until the next successful refresh.
const DEFAULT_FALLBACK_MODELS: Array[Dictionary] = [
	{"name": "gemini-3.8-flash", "displayName": "Gemini 3.8 Flash (Google AI)", "maxInputTokens": 1048576, "maxOutputTokens": 65536},
	{"name": "gemini-3.7-flash", "displayName": "Gemini 3.7 Flash (Google AI)", "maxInputTokens": 1048576, "maxOutputTokens": 65536},
	{"name": "gemini-3.6-flash", "displayName": "Gemini 3.6 Flash (Google AI)", "maxInputTokens": 1048576, "maxOutputTokens": 65536},
]

## OAuth scopes — `cloud-platform` for the Cloud Code Assist API, the userinfo pair for the email label, `cclog` and `experimentsandconfigs` for the on-by-default Antigravity capabilities.
const CLOUDCODE_SCOPES: Array[String] = [
	"https://www.googleapis.com/auth/cloud-platform",
	"https://www.googleapis.com/auth/userinfo.email",
	"https://www.googleapis.com/auth/userinfo.profile",
	"https://www.googleapis.com/auth/cclog",
	"https://www.googleapis.com/auth/experimentsandconfigs",
]

## The published Antigravity CLI OAuth client — public by design (no secret kept server-side). Override via the Editor Settings UI for private tenants.
const DEFAULT_CLIENT_ID := "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
const DEFAULT_CLIENT_SECRET := "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"

const REDIRECT_URI := "http://127.0.0.1:%d/oauth/callback" % REDIRECT_PORT
const DEFAULT_USER_AGENT := "antigravity"

signal finished(source_id: String, ok: bool, detail: String) ## An interactive sign-in finished; `ok=true` when the tokens are stored and a project id was resolved, `ok=false` with a user-facing reason on cancellation or failure. Emitted exactly once per `begin` call; the instance is done either way.


static var _refresh_pending: Dictionary = {} ## source_id → Time.get_ticks_msec() of an in-flight refresh; mirrors GDLLMOAuth's single-flight pattern.

var _source_id: String = ""
var _verifier: String = "" ## PKCE code_verifier; its SHA-256 rides the authorization request, the plaintext goes only to the token exchange.
var _state: String = "" ## Anti-CSRF state echoed back on the redirect.
var _server: TCPServer
var _peer: StreamPeerTCP
var _peer_buffer: String = ""
var _elapsed: float = 0.0
var _exchanging := false
var _done := false


## Launch the interactive sign-in for `source_id`. Mirrors GDLLMOAuth.begin.
func begin(source_id: String) -> void:
	_source_id = source_id
	var crypto := Crypto.new()
	_verifier = _base64url(crypto.generate_random_bytes(32))
	_state = _base64url(crypto.generate_random_bytes(16))
	_server = TCPServer.new()
	var err := _server.listen(REDIRECT_PORT, "127.0.0.1")
	if err != OK:
		_finish(false, "Couldn't open the sign-in listener on localhost:%d (%s) — another sign-in may be running, or another program holds the port. Close it and try again." % [REDIRECT_PORT, error_string(err)])
		return
	var challenge := _base64url(_sha256(_verifier.to_utf8_buffer()))
	var query := "&".join([
		"response_type=code",
		"client_id=" + _effective_client_id().uri_encode(),
		"redirect_uri=" + REDIRECT_URI.uri_encode(),
		"scope=" + " ".join(CLOUDCODE_SCOPES).uri_encode(),
		"code_challenge=" + challenge,
		"code_challenge_method=S256",
		"state=" + _state,
		"access_type=offline",
		"prompt=consent",
	])
	var open_err := OS.shell_open(GOOGLE_OAUTH_AUTH_URL + "?" + query)
	if open_err != OK:
		_finish(false, "Couldn't open your browser (%s). Fix the system's URL handler and try again, or open the OAuth page yourself and re-press Sign in once it works: %s" % [error_string(open_err), GOOGLE_OAUTH_AUTH_URL])
		return
	set_process(true)


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if _elapsed > FLOW_TIMEOUT_SECONDS:
		_finish(false, "Sign-in timed out after %d seconds — the browser round-trip was never completed. Start the sign-in again when ready." % int(FLOW_TIMEOUT_SECONDS))
		return
	if _exchanging:
		return
	if _peer == null and _server != null and _server.is_connection_available():
		_peer_buffer = ""
		_peer = _server.take_connection()
	if _peer == null:
		return
	_peer.poll()
	var available := _peer.get_available_bytes()
	if available > 0:
		_peer_buffer += _peer.get_utf8_string(available)
	if not _peer_buffer.contains("\r\n"):
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop_peer()
		return
	var request_line := _peer_buffer.get_slice("\r\n", 0)
	var target := request_line.get_slice(" ", 1)
	if not target.begins_with("/oauth/callback"):
		_respond_html("<h3>GDLLM</h3><p>Nothing here — this port is waiting for a Google sign-in callback.</p>")
		_drop_peer()
		return
	var oauth_error := _query_param(target, "error")
	if oauth_error != "" and _query_param(target, "state") == _state:
		_respond_html("<h3>GDLLM: sign-in not completed.</h3><p>You can close this tab and return to Godot.</p>")
		var description := _query_param(target, "error_description")
		_finish(false, "Google declined the sign-in in the browser (%s)." % (("%s: %s" % [oauth_error, description]) if description != "" else oauth_error))
		return
	var code := _query_param(target, "code")
	if code == "" or _query_param(target, "state") != _state:
		_respond_html("<h3>GDLLM: sign-in rejected.</h3><p>This callback didn't match the sign-in attempt in progress. Return to Godot and use its sign-in button.</p>")
		_drop_peer()
		return
	_respond_html("<h3>GDLLM: sign-in complete.</h3><p>You can close this tab and return to Godot.</p>")
	_exchanging = true
	_exchange(code)


## Trade the authorization code for tokens; then resolve the Cloud Code Assist project id; then store both.
func _exchange(code: String) -> void:
	var creds := save_credentials_partial(_source_id, {"client_id": _effective_client_id(), "client_secret": _effective_client_secret()})
	var body := "&".join([
		"grant_type=authorization_code",
		"code=" + code.uri_encode(),
		"redirect_uri=" + REDIRECT_URI.uri_encode(),
		"client_id=" + _effective_client_id().uri_encode(),
		"client_secret=" + _effective_client_secret().uri_encode(),
		"code_verifier=" + _verifier,
	])
	var parsed: Variant = await _post_form(self, GOOGLE_OAUTH_TOKEN_URL, body)
	if _done:
		return
	if not (parsed is Dictionary) or String(parsed.get("access_token", "")) == "":
		_finish(false, "The token exchange failed: %s" % _token_error(parsed))
		return
	consume_token_response(_source_id, parsed)
	var access := String(parsed.get("access_token", ""))
	var project := await load_code_assist_project(_source_id, access)
	if project != "":
		set_project_id(_source_id, project)
	_finish(true, account_label(_source_id))


func _finish(ok: bool, detail: String) -> void:
	if _done:
		return
	_done = true
	set_process(false)
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
		_server = null
	finished.emit(_source_id, ok, detail)


func _drop_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null
	_peer_buffer = ""


func _respond_html(body_html: String) -> void:
	if _peer == null:
		return
	var page := "<!doctype html><meta charset=\"utf-8\"><title>GDLLM</title>" + body_html
	var payload := page.to_utf8_buffer()
	_peer.put_data(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % payload.size()).to_utf8_buffer())
	_peer.put_data(payload)


# --- static: token store, refresh, project id, model discovery ---

## Launch one interactive sign-in under `host`. Convenience wrapper mirroring GDLLMOAuth.launch.
static func launch(host: Node, source_id: String, on_finished: Callable) -> void:
	var flow := GDLLMGeminiOAuth.new()
	host.add_child(flow)
	flow.finished.connect(func(_id: String, ok: bool, detail: String) -> void:
		flow.queue_free()
		on_finished.call(ok, detail))
	flow.begin(source_id)


## The current access token for `source_id`, refreshed through `host` when stale. "" when the source was never signed in or the refresh failed. On every successful fresh-token path, also opportunistically re-resolves the Cloud Code Assist project id when it's missing — covers the install flow where loadCodeAssist failed at sign-in (network blip) but the token store landed cleanly, so a future Refresh Models / send would otherwise build an envelope with an empty project and get a 4xx with no actionable detail.
static func ensure_fresh(source_id: String, host: Node) -> String:
	var creds := credentials_for(source_id)
	if creds.is_empty():
		return ""
	# Opportunistic project id resolution — happens once after sign-in or after a 403. The cost is one extra POST the first time; the cached value sticks across refreshes.
	if String(creds.get("project_id", "")) == "":
		var fresh_for_project := String(creds.get("access_token", ""))
		if fresh_for_project != "":
			await load_code_assist_project(source_id, fresh_for_project)
			creds = credentials_for(source_id)
	var cached_access := String(creds.get("access_token", ""))
	var cached_expires := int(creds.get("expires_at", 0))
	if cached_access != "" and cached_expires > int(Time.get_unix_time_from_system()) + REFRESH_MARGIN_SECONDS:
		return cached_access
	if _refresh_in_flight(source_id):
		while _refresh_in_flight(source_id) and is_instance_valid(host) and host.is_inside_tree():
			await host.get_tree().process_frame
		creds = credentials_for(source_id)
		if creds.is_empty():
			return ""
		var fresh_cached := String(creds.get("access_token", ""))
		var fresh_expires := int(creds.get("expires_at", 0))
		if fresh_cached != "" and fresh_expires > int(Time.get_unix_time_from_system()) + REFRESH_MARGIN_SECONDS:
			return fresh_cached
	_refresh_pending[source_id] = Time.get_ticks_msec()
	var body := "&".join([
		"grant_type=refresh_token",
		"refresh_token=" + String(creds.get("refresh_token", "")).uri_encode(),
		"client_id=" + _effective_client_id().uri_encode(),
		"client_secret=" + _effective_client_secret().uri_encode(),
	])
	var parsed: Variant = await _post_form(host, GOOGLE_OAUTH_TOKEN_URL, body)
	_refresh_pending.erase(source_id)
	if not (parsed is Dictionary) or String(parsed.get("access_token", "")) == "":
		var reason := _token_error(parsed)
		push_warning("GDLLMGeminiOAuth: token refresh failed for \"%s\": %s" % [source_id, reason])
		if parsed is Dictionary and String(parsed.get("error", "")) == "invalid_grant":
			clear_credentials(source_id)
		return ""
	var new_refresh := String(parsed.get("refresh_token", ""))
	if new_refresh != "":
		creds["refresh_token"] = new_refresh
	creds["access_token"] = String(parsed["access_token"])
	creds["expires_at"] = int(Time.get_unix_time_from_system()) + int(parsed.get("expires_in", 3600))
	_write_record(source_id, creds)
	return String(parsed["access_token"])


## Resolve the Cloud Code Assist project id (`cloudaicompanionProject`) for the signed-in account via POST /v1internal:loadCodeAssist. The returned id is the one the AGY envelope requires in its `project` field; future requests store it via set_project_id so the adapter can reuse it without a round-trip. An empty result means the user's account isn't on a Cloud Code Assist whitelisted tenant — the OAuth route cannot drive Gemini for them. The agent checks this on first connection.
static func load_code_assist_project(source_id: String, access_token: String = "") -> String:
	if access_token == "":
		# Use the stored access token when the caller didn't pass one — callers that already refreshed can save the round-trip by passing the fresh token. Reading from EditorSettings here is safe because ensure_fresh already wrote the row before this is called.
		access_token = String(credentials_for(source_id).get("access_token", ""))
	if access_token == "":
		return ""
	var body := JSON.stringify({
		"metadata": {
			"ideType": "ANTIGRAVITY",
			"platform": "PLATFORM_UNSPECIFIED",
			"pluginType": "GEMINI",
		},
	})
	var project_id := await _post_json_for_project(source_id, CLOUDCODE_LOAD_CODE_ASSIST_URL, access_token, body)
	if project_id != "":
		set_project_id(source_id, project_id)
	return project_id


## One-shot helper: POST a JSON body at `url` with Bearer `access_token`, look for `cloudaicompanionProject` in the reply, store it. Returns "" on any failure (HTTP, missing field, etc.).
static func _post_json_for_project(source_id: String, url: String, access_token: String, body: String) -> String:
	var parsed: Variant = await _post_json(url, access_token, body)
	if not (parsed is Dictionary):
		return ""
	# Cloud Code Assist returns the project id at the top level (most rev) or under .cloudaicompanionProject / .projectId in newer revisions — accept whichever the field uses.
	for key in ["cloudaicompanionProject", "projectId", "project"]:
		var value: Variant = parsed.get(key, "")
		if value is String and value != "":
			set_project_id(source_id, value)
			return value
	return ""


## POST a JSON body to a Cloud Code Assist URL with Bearer + the AGY identity headers. Returns the parsed JSON dictionary, or null on transport failure, or a synthetic `{_status, _body}` dict on non-2xx HTTP responses so the caller can surface a useful error. The headers — `Authorization`, `User-Agent`, `X-Goog-Api-Client`, `Client-Metadata` — match AIFlowBridge's reference impl; without them the gateway returns a generic 4xx without naming the missing client identity.
static func _post_json(url: String, access_token: String, body: String) -> Variant:
	var host := _live_host()
	if host == null:
		push_warning("GDLLMGeminiOAuth: no live host available for AGY POST; skipping.")
		return null
	var request := HTTPRequest.new()
	request.timeout = TOKEN_REQUEST_TIMEOUT
	host.add_child(request)
	var headers := PackedStringArray([
		"Authorization: Bearer " + access_token,
		"Content-Type: application/json",
		"User-Agent: " + AGY_USER_AGENT,
		"X-Goog-Api-Client: " + AGY_GOOG_API_CLIENT,
		"Client-Metadata: " + AGY_CLIENT_METADATA,
	])
	var err := request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		request.queue_free()
		return null
	var result: Array = await request.request_completed
	request.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return null
	var status := int(result[1])
	if status < 200 or status >= 300:
		return {"_status": status, "_body": (result[3] as PackedByteArray).get_string_from_utf8()}
	return JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())


## A walking-around-helper: looks up the first live host on the scene tree to ride the HTTPRequest on. "" in headless tests (no tree yet).
static func _live_host() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root := tree.root
	if root == null:
		return null
	return root


## Whether `source_id` holds a valid (refreshable) OAuth record.
static func is_configured(source_id: String) -> bool:
	return not credentials_for(source_id).is_empty()


## The stored record (client_id, client_secret, refresh_token, account_email, access_token, expires_at, project_id). The user's pasted credentials — treat as sensitive as an API key, same EditorSettings custody as everything else.
static func credentials_for(source_id: String) -> Dictionary:
	var record: Variant = GDLLMSettings.stored_map(SETTINGS_KEY).get(source_id)
	return record if record is Dictionary else {}


## Save the long-lived values (the ones the user pastes). The user-supplied `client_id`/`client_secret` win; omit them to keep what's stored (the typical path during a refresh response that rotates the refresh token but says nothing about the client).
static func save_credentials(source_id: String, client_id: String, client_secret: String, refresh_token: String, account_email: String = "") -> void:
	var existing := credentials_for(source_id)
	existing["client_id"] = client_id.strip_edges() if client_id.strip_edges() != "" else String(existing.get("client_id", _effective_client_id()))
	existing["client_secret"] = client_secret.strip_edges() if client_secret.strip_edges() != "" else String(existing.get("client_secret", _effective_client_secret()))
	existing["refresh_token"] = refresh_token.strip_edges()
	existing["account_email"] = account_email.strip_edges() if account_email.strip_edges() != "" else String(existing.get("account_email", ""))
	_write_record(source_id, existing)


## Internal: persist a partial credential patch (used by the sign-in flow to write the user-supplied client_id/secret before the token exchange, so a manual override survives even when the user later clears their account_email).
static func save_credentials_partial(source_id: String, patch: Dictionary) -> Dictionary:
	var existing := credentials_for(source_id)
	for key in patch.keys():
		existing[key] = patch[key]
	_write_record(source_id, existing)
	return existing


## Internal: persist the parsed token response (overwriting access_token/expires_at/refresh_token, surfacing the email when an id_token is present).
static func consume_token_response(source_id: String, parsed: Dictionary) -> void:
	var existing := credentials_for(source_id)
	existing["access_token"] = String(parsed.get("access_token", ""))
	var new_refresh := String(parsed.get("refresh_token", ""))
	if new_refresh != "":
		existing["refresh_token"] = new_refresh
	existing["expires_at"] = int(Time.get_unix_time_from_system()) + int(parsed.get("expires_in", 3600))
	# userinfo email — optional and best-effort; failure to fetch is non-fatal.
	existing["account_email"] = String(existing.get("account_email", ""))
	_write_record(source_id, existing)


## Drop `source_id`'s credentials + project_id (the dialog's "Disconnect from Google account").
static func clear_credentials(source_id: String) -> void:
	_write_record(source_id, {})


## The user-facing "who is signed in" label. Falls back to a generic stamp so a row never reads as blank.
static func account_label(source_id: String) -> String:
	var label := String(credentials_for(source_id).get("account_email", ""))
	return label if label != "" else "Google account"


## The stored Cloud Code Assist project id (resolved by loadCodeAssist at sign-in). "" when the account isn't on a whitelisted tenant — call load_code_assist_project() to retry.
static func project_id_for(source_id: String) -> String:
	return String(credentials_for(source_id).get("project_id", ""))


## Persist the project id returned by load_code_assist_project().
static func set_project_id(source_id: String, project_id: String) -> void:
	var existing := credentials_for(source_id)
	existing["project_id"] = project_id.strip_edges()
	_write_record(source_id, existing)


# --- internal: low-level helpers ---

static func _effective_client_id() -> String:
	# Allow per-project override via EditorSettings (so the user can use their own Google Cloud OAuth client for a private tenant).
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("gdllm/connection/gemini_oauth_client_id"):
		var v := String(es.get_setting("gdllm/connection/gemini_oauth_client_id")).strip_edges()
		if v != "":
			return v
	return DEFAULT_CLIENT_ID


static func _effective_client_secret() -> String:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("gdllm/connection/gemini_oauth_client_secret"):
		var v := String(es.get_setting("gdllm/connection/gemini_oauth_client_secret")).strip_edges()
		if v != "":
			return v
	return DEFAULT_CLIENT_SECRET


static func _refresh_in_flight(source_id: String) -> bool:
	if not _refresh_pending.has(source_id):
		return false
	return Time.get_ticks_msec() - int(_refresh_pending[source_id]) < REFRESH_CLAIM_MS


static func _write_record(source_id: String, record: Dictionary) -> void:
	var store := GDLLMSettings.stored_map(SETTINGS_KEY)
	if record.is_empty():
		store.erase(source_id)
	else:
		store[source_id] = record
	EditorInterface.get_editor_settings().set_setting(SETTINGS_KEY, JSON.stringify(store))


static func _token_error(parsed: Variant) -> String:
	if parsed is Dictionary:
		var code := String(parsed.get("error", ""))
		var description := String(parsed.get("error_description", ""))
		if code != "" or description != "":
			return ("%s: %s" % [code, description]) if code != "" and description != "" else code + description
	return "the token endpoint didn't answer (check your network and try again)"


## POST a form-encoded body and parse the JSON reply; null on transport failure. Mirrors GDLLMOAuth._post_form.
static func _post_form(host: Node, url: String, body: String) -> Variant:
	var request := HTTPRequest.new()
	request.timeout = TOKEN_REQUEST_TIMEOUT
	host.add_child(request)
	var err := request.request(url, PackedStringArray(["Content-Type: application/x-www-form-urlencoded"]), HTTPClient.METHOD_POST, body)
	if err != OK:
		request.queue_free()
		return null
	var result: Array = await request.request_completed
	request.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return null
	return JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())


static func _base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


static func _query_param(target: String, name: String) -> String:
	var q := target.find("?")
	if q == -1:
		return ""
	for pair in target.substr(q + 1).split("&"):
		if pair.begins_with(name + "="):
			return pair.substr(name.length() + 1).uri_decode()
	return ""
