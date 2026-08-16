@tool
class_name GDLLMOAuth extends Node
## "Sign in with ChatGPT" for the OpenAI ChatGPT Subscription source kind: a standard OAuth 2.0 authorization-code flow with PKCE (RFC 6749/7636), written from the protocol against Godot's own primitives — no third-party code. An instance runs one interactive sign-in: it opens the browser on OpenAI's authorization page, catches the redirect on a loopback listener, exchanges the code for tokens, and stores them; the static half owns the per-source token store and the refresh path requests ride on.
## The endpoint constants and client id are OpenAI's published values for ChatGPT sign-in (public constants of the open Codex CLI; PKCE clients carry no secret).
## Tokens persist in GDLLMCredentialStore, separate from EditorSettings and chat
## records. Existing plaintext EditorSettings records migrate transactionally.

signal finished(ok: bool, detail: String) ## The flow ended: signed in and stored (true), or failed/cancelled with a user-facing reason (false). Emitted exactly once; the instance is done either way and should be freed.

const SETTINGS_KEY := "gdllm/connection/chatgpt_tokens_fallback" ## Legacy plaintext setting, retained only as the migration source.
const TOKENS_NAMESPACE := "chatgpt_oauth_tokens"

const AUTH_URL := "https://auth.openai.com/oauth/authorize"
const TOKEN_URL := "https://auth.openai.com/oauth/token"
const CLIENT_ID := "app_EMoamEEZ73f0CkXaXp7hrann" ## The published ChatGPT sign-in client id (a PKCE public client — there is no secret).
const REDIRECT_PORT := 1455 ## The loopback port the published client id's redirect allowlist expects; not configurable, so a port collision must fail loudly instead of retrying elsewhere.
const REDIRECT_URI := "http://localhost:1455/auth/callback"
const SCOPE := "openid profile email offline_access"
const FLOW_TIMEOUT_SECONDS := 300.0 ## How long the browser round-trip may take before the flow gives up (the user may abandon the page; the listener must not squat the port forever).
const REFRESH_MARGIN_SECONDS := 300 ## Refresh this long before the access token's exp, so a request never rides a token that expires mid-stream.
const REFRESH_CLAIM_MS := 20000 ## How long a single-flight refresh claim stays believable (see _refresh_in_flight); past the token request's own timeout, a claim can only be a leader that died without cleaning up.
const TOKEN_REQUEST_TIMEOUT := 15.0 ## Seconds a token exchange or refresh may run; without one, a blackholed token endpoint would wedge the sign-in (and its port) until the editor restarts.

static var _refresh_pending: Dictionary = {} ## source_id → Time.get_ticks_msec() of a refresh grant in flight; parallel clients (a turn's subagent fan-out above all) single-flight through it, because a rotating refresh token replayed twice can revoke the whole sign-in (see ensure_fresh).

var _source_id: String = ""
var _verifier: String = "" ## The PKCE code_verifier; its SHA-256 rides the authorization request, the plaintext goes only to the token exchange.
var _state: String = "" ## The anti-CSRF state echoed back on the redirect; a mismatch is rejected.
var _server: TCPServer
var _peer: StreamPeerTCP ## The connection currently being read. Browsers open speculative preconnect sockets that never send a request, so a dead or byteless-closed peer frees the slot rather than starving the real callback.
var _peer_buffer: String = ""
var _elapsed: float = 0.0
var _exchanging := false ## The callback landed and the token exchange is in flight; the listener stops reading, but the watchdog keeps running — a stalled token endpoint must still time the flow out instead of wedging it (and squatting the port) forever.
var _done := false ## Guards finished against double emission (timeout racing the callback).


## Begin the interactive sign-in for `source_id`. Adds nothing to the tree itself — the caller owns the instance (add_child it first) and frees it after `finished`.
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
		"client_id=" + CLIENT_ID.uri_encode(),
		"redirect_uri=" + REDIRECT_URI.uri_encode(),
		"scope=" + SCOPE.uri_encode(),
		"code_challenge=" + challenge,
		"code_challenge_method=S256",
		"state=" + _state,
	])
	var url := AUTH_URL + "?" + query
	var open_err := OS.shell_open(url)
	if open_err != OK:
		# A system with no URL handler fails right here, and saying so now beats a five-minute silence ending in a timeout that blames the browser round-trip.
		_finish(false, "Couldn't open your browser (%s). Fix the system's URL handler and try again, or open this URL yourself and re-press Sign in once it works: %s" % [error_string(open_err), AUTH_URL])
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
		return # the listener's job is done; only the watchdog above still runs
	if _peer == null and _server != null and _server.is_connection_available():
		_peer_buffer = ""
		_peer = _server.take_connection()
	if _peer == null:
		return
	_peer.poll()
	var available := _peer.get_available_bytes()
	if available > 0:
		_peer_buffer += _peer.get_utf8_string(available)
	# Only the request line matters; it ends the moment the first CRLF arrives.
	if not _peer_buffer.contains("\r\n"):
		# A socket that closed without ever sending one — a browser preconnect, a port probe — frees the slot for the real callback.
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop_peer()
		return
	var request_line := _peer_buffer.get_slice("\r\n", 0)
	var target := request_line.get_slice(" ", 1)
	if not target.begins_with("/auth/callback"):
		# A stray local request (a security agent's port sweep, an extension prefetch) must not abort a five-minute browser round-trip; answer it and keep listening.
		_respond_html("<h3>GDLLM</h3><p>Nothing here — this port is waiting for a ChatGPT sign-in callback.</p>")
		_drop_peer()
		return
	var oauth_error := _query_param(target, "error")
	if oauth_error != "" and _query_param(target, "state") == _state:
		# The user declined (or the provider failed) on the consent page; the redirect names the cause itself (RFC 6749 §4.1.2.1), which beats any guess of ours. Only THIS attempt's state may end the flow — a stale tab's error redirect falls through to the mismatch arm below and the flow keeps waiting, exactly like a foreign code callback.
		_respond_html("<h3>GDLLM: sign-in not completed.</h3><p>You can close this tab and return to Godot.</p>")
		var description := _query_param(target, "error_description")
		_finish(false, "OpenAI declined the sign-in in the browser (%s)." % (("%s: %s" % [oauth_error, description]) if description != "" else oauth_error))
		return
	var code := _query_param(target, "code")
	if code == "" or _query_param(target, "state") != _state:
		# A callback for some other attempt (a stale tab's redirect, a foreign state) — reject it, but keep waiting for the real one.
		_respond_html("<h3>GDLLM: sign-in rejected.</h3><p>This callback didn't match the sign-in attempt in progress. Return to Godot and use its sign-in button.</p>")
		_drop_peer()
		return
	_respond_html("<h3>GDLLM: sign-in complete.</h3><p>You can close this tab and return to Godot.</p>")
	_exchanging = true
	_exchange(code)


## Release the connection being read, ready for the next one.
func _drop_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null
	_peer_buffer = ""


## Trade the authorization code for tokens and store them. Async off the callback read; failure reasons surface through `finished`.
func _exchange(code: String) -> void:
	var body := "&".join([
		"grant_type=authorization_code",
		"code=" + code.uri_encode(),
		"redirect_uri=" + REDIRECT_URI.uri_encode(),
		"client_id=" + CLIENT_ID.uri_encode(),
		"code_verifier=" + _verifier,
	])
	var parsed: Variant = await _post_form(self, TOKEN_URL, body)
	if _done:
		return # the watchdog already timed the flow out; a late exchange result must not resurrect it
	if not (parsed is Dictionary) or String(parsed.get("access_token", "")) == "":
		_finish(false, "The token exchange failed: %s" % _token_error(parsed))
		return
	if not save_tokens(_source_id, parsed):
		_finish(false, "The sign-in succeeded, but its credentials could not be stored safely. The previous sign-in, if any, was left unchanged.")
		return
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
	finished.emit(ok, GDLLMSecretRedactor.redact(detail))


## Write the tiny confirmation page and finish the HTTP exchange, so the browser tab doesn't spin.
func _respond_html(body_html: String) -> void:
	if _peer == null:
		return
	var page := "<!doctype html><meta charset=\"utf-8\"><title>GDLLM</title>" + body_html
	var payload := page.to_utf8_buffer()
	_peer.put_data(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % payload.size()).to_utf8_buffer())
	_peer.put_data(payload)


# --- static: token store and refresh ---

## Run one interactive sign-in under `host` (any in-tree Node): wires `on_finished(ok, detail)` ahead of begin — which can fail synchronously on a port collision — and frees the instance either way. The one launcher the Connections row and the session's sign-in notice share.
static func launch(host: Node, source_id: String, on_finished: Callable) -> void:
	var flow := GDLLMOAuth.new()
	host.add_child(flow)
	flow.finished.connect(func(ok: bool, detail: String) -> void:
		flow.queue_free()
		on_finished.call(ok, detail))
	flow.begin(source_id)


## The current access token for `source_id`, refreshed through `host` (any in-tree Node; a temporary HTTPRequest rides on it) when stale. "" when the source was never signed in or the refresh failed — the caller reports sign-in as the fix. Await it before building a request.
static func ensure_fresh(source_id: String, host: Node) -> String:
	var record := tokens_for(source_id)
	if record.is_empty():
		return ""
	if not stale_at(record, int(Time.get_unix_time_from_system())):
		return String(record.get("access_token", ""))
	if _refresh_in_flight(source_id):
		# Another client is already refreshing this source — the main chat and a turn's subagents share one sign-in — so ride its result instead of replaying the grant, which a provider rotating refresh tokens treats as replay and may answer by revoking the whole sign-in.
		while _refresh_in_flight(source_id) and is_instance_valid(host) and host.is_inside_tree():
			await host.get_tree().process_frame
		record = tokens_for(source_id)
		if record.is_empty():
			return ""
		if not stale_at(record, int(Time.get_unix_time_from_system())):
			return String(record.get("access_token", ""))
		# Still stale with no live claim: the leader died mid-flight (its host was freed, so its cleanup never ran). Take leadership and refresh ourselves rather than misreporting a valid sign-in as signed out.
	_refresh_pending[source_id] = Time.get_ticks_msec()
	var body := "&".join([
		"grant_type=refresh_token",
		"refresh_token=" + String(record.get("refresh_token", "")).uri_encode(),
		"client_id=" + CLIENT_ID.uri_encode(),
	])
	var parsed: Variant = await _post_form(host, TOKEN_URL, body)
	_refresh_pending.erase(source_id)
	if not (parsed is Dictionary) or String(parsed.get("access_token", "")) == "":
		push_warning(GDLLMSecretRedactor.redact("GDLLMOAuth: token refresh failed for \"%s\": %s" % [source_id, _token_error(parsed)]))
		# invalid_grant means this sign-in is dead (revoked, or a rotated token lost) — forget it, so the sign-in notices come back up with their one-click fix instead of every send failing the same way.
		if parsed is Dictionary and String(parsed.get("error", "")) == "invalid_grant":
			if not clear_tokens(source_id):
				push_warning("GDLLMOAuth: the invalid local sign-in for \"%s\" could not be removed; the credential store still contains it." % source_id)
		return ""
	# A refresh response may rotate the refresh token; keep the old one when it doesn't.
	if String(parsed.get("refresh_token", "")) == "":
		parsed["refresh_token"] = record.get("refresh_token", "")
	if not save_tokens(source_id, parsed):
		return ""
	return String(tokens_for(source_id).get("access_token", ""))


## Whether a live refresh currently claims `source_id`. A claim past REFRESH_CLAIM_MS is dead — its leader's host was freed mid-request, so its erase never ran — and leadership is up for grabs again rather than parked forever.
static func _refresh_in_flight(source_id: String) -> bool:
	if not _refresh_pending.has(source_id):
		return false
	return Time.get_ticks_msec() - int(_refresh_pending[source_id]) < REFRESH_CLAIM_MS


## Whether `source_id` holds a sign-in at all (fresh or refreshable — a stale access token with a refresh token still counts; ensure_fresh renews it silently).
static func is_signed_in(source_id: String) -> bool:
	return not tokens_for(source_id).is_empty()


## A short "who is signed in" label for dialog and log rows: the account e-mail when the id token carried one, else the ChatGPT account id, else a generic stamp.
static func account_label(source_id: String) -> String:
	var label := String(tokens_for(source_id).get("account_label", ""))
	return label if label != "" else "signed in"


## The stored token record for `source_id`, {} when none (headless runs included — see GDLLMSettings.stored_map).
static func tokens_for(source_id: String) -> Dictionary:
	_migrate_legacy_tokens()
	return GDLLMCredentialStore.get_record(TOKENS_NAMESPACE, source_id)


## Store a token response for `source_id`, deriving the fields requests need: the account id claim the backend wants echoed as a header, a display label, and the refresh deadline from the access token's own exp claim (fallback: now + expires_in). Writing emits EditorSettings.settings_changed, which is how open sessions' sign-in notices refresh.
static func save_tokens(source_id: String, token_response: Dictionary) -> bool:
	var access := String(token_response.get("access_token", ""))
	var claims := jwt_claims(access)
	var auth_claim: Dictionary = claims["https://api.openai.com/auth"] if claims.get("https://api.openai.com/auth") is Dictionary else {}
	var id_claims := jwt_claims(String(token_response.get("id_token", "")))
	var expires_at := int(claims.get("exp", 0))
	if expires_at <= 0:
		expires_at = int(Time.get_unix_time_from_system()) + int(token_response.get("expires_in", 3600))
	# A refresh grant may omit the id_token (and the auth claim); the identity didn't change, so the stored fields survive rather than degrading the Sign out label to a generic stamp.
	var previous := tokens_for(source_id)
	var account_id := String(auth_claim.get("chatgpt_account_id", ""))
	var account_label := String(id_claims.get("email", ""))
	var record := {
		"access_token": access,
		"refresh_token": String(token_response.get("refresh_token", "")),
		"account_id": account_id if account_id != "" else String(previous.get("account_id", "")),
		"account_label": account_label if account_label != "" else String(previous.get("account_label", "")),
		"expires_at": expires_at,
	}
	GDLLMSecretRedactor.register_variant(record)
	return _write_record(source_id, record)


## Drop `source_id`'s sign-in (the dialog's Sign out). The settings write refreshes open sessions' notices like save_tokens' does.
static func clear_tokens(source_id: String) -> bool:
	# No documented revocation endpoint is configured for this public PKCE client,
	# so sign-out honestly performs local deletion only. A provider-side session can
	# still be revoked from the provider's account security controls.
	return _write_record(source_id, {})


static func _write_record(source_id: String, record: Dictionary) -> bool:
	return GDLLMCredentialStore.set_record(TOKENS_NAMESPACE, source_id, record)


## Remove local tokens for deleted sources or rows changed away from the ChatGPT
## kind. Called after source metadata is safely stored.
static func remove_orphans(valid_source_ids: Array[String]) -> PackedStringArray:
	_migrate_legacy_tokens()
	var failed := PackedStringArray()
	for id in GDLLMCredentialStore.get_namespace(TOKENS_NAMESPACE).keys():
		if not valid_source_ids.has(String(id)):
			if not clear_tokens(String(id)):
				failed.append(String(id))
	if not failed.is_empty():
		push_warning("GDLLMOAuth: could not remove stored tokens for deleted or changed source(s): %s." % ", ".join(failed))
	return failed


## Move the historical EditorSettings JSON into the credential store. The legacy
## value is erased only after the atomic store write verifies, so migration cannot
## silently destroy a refresh token on write failure.
static func _migrate_legacy_tokens() -> bool:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTINGS_KEY):
		return true
	var parsed: Variant = JSON.parse_string(String(es.get_setting(SETTINGS_KEY)))
	if not (parsed is Dictionary) or parsed.is_empty():
		return true
	var records := GDLLMCredentialStore.get_namespace(TOKENS_NAMESPACE)
	for id in parsed:
		if parsed[id] is Dictionary:
			records[id] = parsed[id]
			GDLLMSecretRedactor.register_variant(parsed[id])
	if not GDLLMCredentialStore.replace_namespace(TOKENS_NAMESPACE, records):
		push_warning("GDLLM OAuth: legacy tokens remain in EditorSettings because credential migration could not be verified.")
		return false
	es.set_setting(SETTINGS_KEY, null)
	return true


## Whether a token record needs refreshing at `now` — pure, so the margin rule is testable headless. A record without an expiry reads as stale: refreshing early costs one round-trip, riding an expired token costs the whole request.
static func stale_at(record: Dictionary, now: int) -> bool:
	return now >= int(record.get("expires_at", 0)) - REFRESH_MARGIN_SECONDS


## The decoded claims of a JWT's payload segment, {} when the token doesn't parse. No signature check — these tokens come straight from the provider over TLS, and the claims are only read for display and headers, never trusted for security decisions.
static func jwt_claims(token: String) -> Dictionary:
	var parts := token.split(".")
	if parts.size() != 3:
		return {}
	var payload := parts[1].replace("-", "+").replace("_", "/")
	while payload.length() % 4 != 0:
		payload += "="
	var parsed: Variant = JSON.parse_string(Marshalls.base64_to_raw(payload).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## Unpadded base64url (RFC 4648 §5), the alphabet PKCE and JWTs use.
static func _base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


## POST a form-encoded body and parse the JSON reply; null on transport failure. The temporary HTTPRequest rides `host` (must be in the tree) and frees itself.
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
	var parsed: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	# A non-200 still parses: OAuth error bodies ({"error": "invalid_grant", ...}) name their cause better than a bare status.
	return parsed


## A user-facing reason out of a failed token response — the OAuth error fields when they parsed, else the transport's silence.
static func _token_error(parsed: Variant) -> String:
	if parsed is Dictionary:
		var code := String(parsed.get("error", ""))
		var description := String(parsed.get("error_description", ""))
		if code != "" or description != "":
			return GDLLMSecretRedactor.redact(("%s: %s" % [code, description]) if code != "" and description != "" else code + description)
	return "the token endpoint didn't answer (check your network and try again)"


## The value of `name` in a URL target's query string, "" when absent.
static func _query_param(target: String, name: String) -> String:
	var q := target.find("?")
	if q == -1:
		return ""
	for pair in target.substr(q + 1).split("&"):
		if pair.begins_with(name + "="):
			return pair.substr(name.length() + 1).uri_decode()
	return ""
