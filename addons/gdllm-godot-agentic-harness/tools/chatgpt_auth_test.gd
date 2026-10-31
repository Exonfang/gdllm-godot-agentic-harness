extends SceneTree
## Headless regression tests for the ChatGPT-subscription pieces that run without a browser or network: GDLLMOAuth's pure helpers (the PKCE derivation against RFC 7636's own test vector, JWT claim decoding, token staleness, callback query parsing, token-error shaping) and OpenAIChatGPTAdapter's header derivation, static model list, probe-less window, and base normalization.
## The interactive flow itself (browser round-trip, loopback callback, token exchange) is exercised manually — it cannot run headless.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/chatgpt_auth_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const LLMAdapters = preload("res://addons/gdllm-godot-agentic-harness/llm_adapters.gd")
const OAuth = preload("res://addons/gdllm-godot-agentic-harness/gdllm_oauth.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_pkce_vector()
	_test_jwt_claims()
	_test_staleness()
	_test_query_param()
	_test_token_error()
	_test_adapter_headers()
	_test_adapter_discovery()
	_test_boot_model_list()
	_test_streamed_completion()
	_test_normalize_base()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## A syntactically valid unsigned JWT carrying `claims` as its payload, for the decode paths (no signature check exists to satisfy).
func _fake_jwt(claims: Dictionary) -> String:
	var header := OAuth._base64url(JSON.stringify({"alg": "none"}).to_utf8_buffer())
	var payload := OAuth._base64url(JSON.stringify(claims).to_utf8_buffer())
	return "%s.%s.%s" % [header, payload, "sig"]


func _test_pkce_vector() -> void:
	# RFC 7636 appendix B: this verifier must derive exactly this S256 challenge.
	var verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	var challenge := OAuth._base64url(OAuth._sha256(verifier.to_utf8_buffer()))
	_check(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "the S256 challenge matches RFC 7636's own test vector")
	_check(not challenge.contains("=") and not challenge.contains("+") and not challenge.contains("/"), "the challenge is unpadded base64url")


func _test_jwt_claims() -> void:
	var claims := OAuth.jwt_claims(_fake_jwt({"exp": 1234, "email": "dev@example.com", "https://api.openai.com/auth": {"chatgpt_account_id": "acct_1"}}))
	_check(int(claims.get("exp", 0)) == 1234, "the payload's claims decode")
	_check(claims.get("https://api.openai.com/auth", {}).get("chatgpt_account_id") == "acct_1", "nested claims survive the decode")
	_check(OAuth.jwt_claims("not-a-jwt").is_empty(), "a non-JWT decodes to nothing rather than erroring")
	_check(OAuth.jwt_claims("").is_empty(), "an empty token decodes to nothing")


func _test_staleness() -> void:
	var record := {"expires_at": 10000}
	_check(not OAuth.stale_at(record, 10000 - OAuth.REFRESH_MARGIN_SECONDS - 1), "a token comfortably before its refresh margin is fresh")
	_check(OAuth.stale_at(record, 10000 - OAuth.REFRESH_MARGIN_SECONDS), "the margin boundary itself reads stale — refreshing early beats riding an expiring token")
	_check(OAuth.stale_at(record, 10001), "an expired token is stale")
	_check(OAuth.stale_at({}, 0), "a record without an expiry reads stale rather than trusted")


func _test_query_param() -> void:
	_check(OAuth._query_param("/auth/callback?code=abc&state=xyz", "code") == "abc", "the code parses out of the callback target")
	_check(OAuth._query_param("/auth/callback?code=abc&state=xyz", "state") == "xyz", "the state parses beside it")
	_check(OAuth._query_param("/auth/callback", "code") == "", "a queryless target yields nothing")
	_check(OAuth._query_param("/auth/callback?error=access_denied", "code") == "", "a denial callback carries no code")
	_check(OAuth._query_param("/cb?code=a%2Fb", "code") == "a/b", "percent-encoded values decode")


func _test_token_error() -> void:
	_check(OAuth._token_error({"error": "invalid_grant", "error_description": "Token revoked"}) == "invalid_grant: Token revoked", "an OAuth error body names code and description")
	_check(OAuth._token_error({"error": "invalid_grant"}) == "invalid_grant", "a description-less error still names its code")
	_check(OAuth._token_error(null).contains("didn't answer"), "a transport failure names the silence")


func _test_adapter_headers() -> void:
	var adapter := LLMAdapters.OpenAIChatGPTAdapter.new()
	var token := _fake_jwt({"https://api.openai.com/auth": {"chatgpt_account_id": "acct_9"}})
	var headers := adapter.auth_headers(token)
	_check(headers.has("Authorization: Bearer " + token), "the access token rides as the Bearer")
	_check(headers.has("chatgpt-account-id: acct_9"), "the token's own account claim rides back as a header — no side channel needed")
	_check(headers.has("originator: gdllm"), "the originator stamp names this harness")
	var keyless := adapter.auth_headers(_fake_jwt({"exp": 1}))
	var has_account := false
	for header in keyless:
		if String(header).begins_with("chatgpt-account-id:"):
			has_account = true
	_check(not has_account, "a token without the account claim sends no empty account header")


func _test_adapter_discovery() -> void:
	var adapter := LLMAdapters.OpenAIChatGPTAdapter.new()
	_check(not adapter.static_models().is_empty(), "the model set is served statically — the backend publishes no listing endpoint")
	_check(adapter.static_models().has("gpt-6.1-terra"), "GPT-6.1 Terra is offered on the subscription")
	_check(adapter.context_probe("gpt-5.6-codex").is_empty(), "no window probe exists; the declared window in Effort Configuration is the only source")
	_check(adapter.chat_path() == "/responses", "chat rides the inherited Responses path under the backend base")
	_check(LLMAdapters.for_kind("openai-chatgpt") is LLMAdapters.OpenAIChatGPTAdapter, "the kind resolves to this adapter")


func _test_boot_model_list() -> void:
	# A cache written before an update must not hide the subscription models this build ships, nor keep ones it dropped; other sources' cached entries pass through.
	var sources: Array = [
		{"id": "chatgpt", "kind": "openai-chatgpt", "enabled": true},
		{"id": "chatgpt-off", "kind": "openai-chatgpt", "enabled": false},
		{"id": "openai", "kind": "openai"},
	]
	var cached := PackedStringArray(["chatgpt::gpt-old-retired", "chatgpt-off::gpt-old-retired", "openai::gpt-6.1-terra"])
	var merged := GDLLMSettings.with_static_models(cached, sources)
	_check(merged.has("chatgpt::gpt-6.1-terra"), "a shipped subscription model shows at boot without waiting for a sweep")
	_check(not merged.has("chatgpt::gpt-old-retired"), "a cached subscription model this build no longer ships is dropped")
	_check(merged.has("chatgpt-off::gpt-old-retired") and not merged.has("chatgpt-off::gpt-6.1-terra"), "a disabled source's cached entries are left as the last sweep wrote them")
	_check(merged.has("openai::gpt-6.1-terra"), "a listed source's cached entries pass through untouched")
	_check(merged.size() == LLMAdapters.OpenAIChatGPTAdapter.MODELS.size() + 2, "nothing else is added")


func _test_streamed_completion() -> void:
	# The subscription backend serves only streams, so the one-shot completion path (session titles) asks for one and lifts the reply out of the buffered SSE transcript.
	var adapter := LLMAdapters.OpenAIChatGPTAdapter.new()
	var req: Dictionary = adapter.completion_request("gpt-5.6-luna", "Be brief.", "Title this chat")
	_check(req.get("body", {}).get("stream") == true, "the completion request asks for a stream — the backend rejects non-streamed calls")
	var transcript := "\n".join([
		"event: response.created",
		"data: " + JSON.stringify({"type": "response.created", "response": {"id": "resp_1"}}),
		"data: " + JSON.stringify({"type": "response.output_text.delta", "delta": "A Good "}),
		"data: " + JSON.stringify({"type": "response.output_text.delta", "delta": "Title"}),
		"data: " + JSON.stringify({"type": "response.completed", "response": {"status": "completed", "output": [], "usage": {"input_tokens": 12, "output_tokens": 4}}}),
	])
	var recovered: Dictionary = adapter.parse_completion_stream(transcript)
	_check(String(recovered.get("text", "")) == "A Good Title", "the transcript's deltas reassemble into the completion text")
	_check(int(recovered.get("stats", {}).get("tokens_in", 0)) == 12, "the terminal frame's usage rides along")
	_check(adapter.parse_completion_stream("<html>a proxy page</html>").is_empty(), "a body that isn't this API's stream recovers nothing, so the normal failure attribution speaks")


func _test_normalize_base() -> void:
	var adapter := LLMAdapters.OpenAIChatGPTAdapter.new()
	_check(adapter.normalize_base("https://chatgpt.com/backend-api/codex") == "https://chatgpt.com/backend-api/codex", "the prefilled backend base passes through")
	_check(adapter.normalize_base("https://chatgpt.com") == "https://chatgpt.com/backend-api/codex", "a pathless base gains the backend prefix, not /v1")
	_check(adapter.normalize_base("https://chatgpt.com/backend-api/codex/responses") == "https://chatgpt.com/backend-api/codex", "a pasted full endpoint reduces to the backend base")
	_check(adapter.normalize_base(" https://chatgpt.com/backend-api/codex/ ") == "https://chatgpt.com/backend-api/codex", "whitespace and trailing slashes trim")
