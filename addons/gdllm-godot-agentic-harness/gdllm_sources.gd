@tool
class_name GDLLMSources
## Pure logic over the configured model sources: the list of places models come from (Ollama local/cloud, OpenAI-compatible endpoints like vLLM or Poolside, and Anthropic) and the qualified-id helpers that let one "model" string carry which source it belongs to.
## No UI, no transport — the dock's Connections dialog edits this list, and LLMClient consumes a resolved source (see resolve_qualified).

const SETTINGS_KEY := "gdllm/connection/sources_fallback" ## EditorSettings key holding non-secret source metadata as JSON. API keys live in GDLLMCredentialStore, never in this setting.
const TEMPLATES_SEEDED_KEY := "gdllm/connection/templates_seeded" ## EditorSettings key listing (as a JSON array) the template ids already offered to this install. A template added after an install's first seeding appears exactly once through it — deleting the row sticks, instead of the template resurrecting on every load.
const API_KEYS_NAMESPACE := "source_api_keys"
const QUALIFIER := "::" ## Separates a source id from a model name in a qualified model id; neither part contains it.

const KIND_OLLAMA := "ollama" ## Native Ollama wire format (/api/chat NDJSON), used by local and cloud alike.
const KIND_OPENAI := "openai" ## OpenAI-compatible wire format (/v1/chat/completions SSE), used by vLLM, Poolside, etc.
const KIND_OPENAI_RESPONSES := "openai-responses" ## OpenAI Responses API wire format (/v1/responses SSE) — the newer OpenAI API, which GPT-5.6-class models require for reasoning effort with tools; /v1/chat/completions rejects that combination on them.
const KIND_OPENAI_CHATGPT := "openai-chatgpt" ## The Responses wire format served from OpenAI's ChatGPT backend, authenticated with a ChatGPT sign-in instead of an API key (see GDLLMOAuth) — how a Plus/Pro subscription drives the harness without API billing.
const KIND_ANTHROPIC := "anthropic" ## Anthropic Messages API wire format (/v1/messages SSE), used by the Claude models.
const KIND_GEMINI := "gemini" ## Google's native Gemini API wire format (/v1beta/models/{model}:streamGenerateContent SSE), authenticated with an AI Studio API key. Gemini also works on the Chat Completions kind through Google's /v1beta/openai endpoint.

const DEFAULT_OLLAMA_LOCAL_BASE := "http://localhost:11434" ## Seed endpoint for the first-run local Ollama source.
const DEFAULT_ANTHROPIC_BASE := "https://api.anthropic.com" ## Anthropic's API host; the same for every account, so the Connections dialog prefills it when a row switches to the Anthropic kind.
const DEFAULT_OPENAI_BASE := "https://api.openai.com/v1" ## OpenAI's own API base; the same for every account, so the Connections dialog prefills it when a row switches to the Responses kind (third-party servers speak the chat-completions kind instead).
const DEFAULT_GEMINI_BASE := "https://generativelanguage.googleapis.com/v1beta" ## The Gemini API base; the same for every account, prefilled like its siblings when a row switches to the Gemini kind.
const DEFAULT_CHATGPT_BASE := "https://chatgpt.com/backend-api/codex" ## The ChatGPT subscription backend; the same for every account, prefilled like its siblings when a row switches to the subscription kind.


## The configured sources as an Array of source Dictionaries, or the default seed when nothing is stored yet or the stored value is unparseable.
static func get_sources() -> Array:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTINGS_KEY):
		return default_sources()
	var parsed: Variant = JSON.parse_string(String(es.get_setting(SETTINGS_KEY)))
	if not parsed is Array:
		return default_sources()
	_migrate_plaintext_keys(parsed)
	return _hydrate_keys(parsed)


## Persist keys in the separate credential store first, verify that write, then
## persist only source metadata. A credential-store failure leaves the previous
## settings untouched, rather than silently dropping a key or falling back to
## plaintext EditorSettings.
static func save_sources(sources: Array) -> bool:
	var split := _split_keys(sources)
	var keys: Dictionary = split["keys"]
	var metadata: Array = split["metadata"]
	var valid_chatgpt_ids: Array[String] = []
	for source_value in sources:
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var id := String(source.get("id", ""))
		if id != "" and String(source.get("kind", "")) == KIND_OPENAI_CHATGPT:
			valid_chatgpt_ids.append(id)
	if not GDLLMCredentialStore.replace_namespace(API_KEYS_NAMESPACE, keys):
		push_warning("GDLLM sources: credentials could not be saved; source settings were not changed.")
		return false
	EditorInterface.get_editor_settings().set_setting(SETTINGS_KEY, JSON.stringify(metadata))
	# Deleted sources and rows changed away from the subscription kind must not
	# leave reusable refresh tokens behind.
	var orphan_failures := GDLLMOAuth.remove_orphans(valid_chatgpt_ids)
	if not orphan_failures.is_empty():
		push_warning("GDLLM sources: metadata was saved, but reusable local OAuth tokens remain for: %s. Retry after fixing credential-store access." % ", ".join(orphan_failures))
	return true


## One-time, fail-closed migration from the historical source JSON. Secrets are
## written and read back by GDLLMCredentialStore before the plaintext setting is
## scrubbed. On failure the old setting remains intact so access is not lost.
static func _migrate_plaintext_keys(sources: Array) -> bool:
	var split := _split_keys(sources, GDLLMCredentialStore.get_namespace(API_KEYS_NAMESPACE))
	if not bool(split["found_plaintext"]):
		return true
	var keys: Dictionary = split["keys"]
	var metadata: Array = split["metadata"]
	if not GDLLMCredentialStore.replace_namespace(API_KEYS_NAMESPACE, keys):
		push_warning("GDLLM sources: legacy API keys remain in EditorSettings because credential migration could not be verified.")
		return false
	EditorInterface.get_editor_settings().set_setting(SETTINGS_KEY, JSON.stringify(metadata))
	# Keep the caller's in-memory array metadata-only before it is hydrated from
	# the now-authoritative store.
	sources.assign(metadata)
	return true


## Pure half of source migration, exposed for headless regression tests. Existing
## stored keys are retained unless a legacy plaintext row supplies a replacement.
static func _split_keys(sources: Array, existing_keys: Dictionary = {}) -> Dictionary:
	var keys := existing_keys.duplicate(true)
	var metadata: Array = []
	var found_plaintext := false
	for source_value in sources:
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value.duplicate(true)
		var id := String(source.get("id", ""))
		var had_key_field := source.has("api_key")
		var key := String(source.get("api_key", ""))
		found_plaintext = found_plaintext or had_key_field
		if id != "" and key != "":
			keys[id] = key
			GDLLMSecretRedactor.register_secret(key)
		elif had_key_field and id != "":
			keys.erase(id)
		source.erase("api_key")
		metadata.append(source)
	return {"metadata": metadata, "keys": keys, "found_plaintext": found_plaintext}


static func _hydrate_keys(sources: Array) -> Array:
	var keys := GDLLMCredentialStore.get_namespace(API_KEYS_NAMESPACE)
	var hydrated: Array = []
	for source_value in sources:
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value.duplicate(true)
		var key := String(keys.get(String(source.get("id", "")), source.get("api_key", "")))
		source["api_key"] = key
		GDLLMSecretRedactor.register_secret(key)
		hydrated.append(source)
	return hydrated


## Seed the sources list on first run if it's unset — every template disabled, so no unconfigured endpoint is swept for models (and errors) before the user has set anything up. Idempotent — leaves an existing list untouched.
static func ensure_seeded() -> void:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting(SETTINGS_KEY):
		return
	save_sources(default_sources())


## The first-run source list: ready-to-fill templates for a local Ollama, Ollama Cloud, a local vLLM, Poolside, OpenAI, and Anthropic (blank keys). Every row starts disabled — enable yours in the Connections dialog once its endpoint or key is in.
static func default_sources() -> Array:
	return [
		{"id": "ollama-local", "name": "Ollama (Local)", "kind": KIND_OLLAMA, "base_url": DEFAULT_OLLAMA_LOCAL_BASE, "api_key": "", "enabled": false},
		{"id": "ollama-cloud", "name": "Ollama Cloud", "kind": KIND_OLLAMA, "base_url": "https://ollama.com", "api_key": "", "enabled": false},
		{"id": "vllm-local", "name": "vLLM (Local)", "kind": KIND_OPENAI, "base_url": "http://localhost:8000/v1", "api_key": "", "enabled": false},
		{"id": "poolside", "name": "Poolside", "kind": KIND_OPENAI, "base_url": "https://inference.poolside.ai/v1", "api_key": "", "enabled": false},
		_openai_template(),
		_chatgpt_template(),
		_gemini_template(),
		_anthropic_template(),
	]


## The ready-to-fill ChatGPT subscription source row (see KIND_OPENAI_CHATGPT), shared by the first-run seed and the one-time append for installs that predate it. Disabled until the user signs in and flips it on, like every template — there is no key to paste; the Connections row carries a Sign in with ChatGPT button instead.
static func _chatgpt_template() -> Dictionary:
	return {"id": "openai-chatgpt", "name": "OpenAI (ChatGPT)", "kind": KIND_OPENAI_CHATGPT, "base_url": DEFAULT_CHATGPT_BASE, "api_key": "", "enabled": false}


## The ready-to-fill OpenAI source row on the Responses kind (see KIND_OPENAI_RESPONSES), shared by the first-run seed and the one-time append for installs that predate it. Disabled until the user pastes a key and flips it on, like every template.
static func _openai_template() -> Dictionary:
	return {"id": "openai", "name": "OpenAI", "kind": KIND_OPENAI_RESPONSES, "base_url": DEFAULT_OPENAI_BASE, "api_key": "", "enabled": false}


## The ready-to-fill Anthropic source row, shared by the first-run seed and the one-time append for installs that predate it. Disabled until the user pastes a key and flips it on — a keyless sweep of the live endpoint only produces auth errors.
static func _anthropic_template() -> Dictionary:
	return {"id": "anthropic", "name": "Anthropic", "kind": KIND_ANTHROPIC, "base_url": DEFAULT_ANTHROPIC_BASE, "api_key": "", "enabled": false}


## The ready-to-fill Google Gemini source row on the native kind (see KIND_GEMINI), shared by the first-run seed and the one-time append for installs that predate it. Disabled until the user pastes an AI Studio key and flips it on, like every template.
static func _gemini_template() -> Dictionary:
	return {"id": "gemini", "name": "Google Gemini", "kind": KIND_GEMINI, "base_url": DEFAULT_GEMINI_BASE, "api_key": "", "enabled": false}


## Append each post-release template row for an install whose sources predate it — a first run already carries them all via default_sources. Each is offered exactly once, tracked by its id in TEMPLATES_SEEDED_KEY, so a deleted row never resurrects; a source the user already points at the provider — by the template's id or by its kind — counts as offered too.
static func ensure_templates() -> void:
	var es := EditorInterface.get_editor_settings()
	var seeded: Array = []
	if es.has_setting(TEMPLATES_SEEDED_KEY):
		var parsed: Variant = JSON.parse_string(String(es.get_setting(TEMPLATES_SEEDED_KEY)))
		if parsed is Array:
			seeded = parsed
	var sources := get_sources()
	var seeded_changed := false
	var sources_changed := false
	for template: Dictionary in [_anthropic_template(), _openai_template(), _chatgpt_template(), _gemini_template()]:
		var template_id := String(template["id"])
		if seeded.has(template_id):
			continue
		seeded.append(template_id)
		seeded_changed = true
		if not _template_offered(sources, template):
			sources.append(template)
			sources_changed = true
	if sources_changed:
		save_sources(sources)
	if seeded_changed:
		es.set_setting(TEMPLATES_SEEDED_KEY, JSON.stringify(seeded))


## Whether `sources` already carries the template's provider — by its id, or by any source of its kind the user added by hand.
static func _template_offered(sources: Array, template: Dictionary) -> bool:
	for source in sources:
		if source is Dictionary and (String(source.get("id", "")) == String(template["id"]) or String(source.get("kind", "")) == String(template["kind"])):
			return true
	return false


## Whether a source should be queried for models. Defaults to true when the key is absent, so sources stored before this flag existed stay on; the Connections dialog's per-row toggle turns it off for a connection that's down or one the user doesn't want swept.
static func is_enabled(source: Dictionary) -> bool:
	return bool(source.get("enabled", true))


## The source Dictionary for `source_id`, or {} if no source carries that id.
static func resolve(source_id: String) -> Dictionary:
	for source in get_sources():
		if source is Dictionary and String(source.get("id", "")) == source_id:
			return source
	return {}


## Join a source id and a bare model name into the qualified id stored in settings and session records.
static func make_qualified(source_id: String, model: String) -> String:
	return source_id + QUALIFIER + model


## Split a qualified id into {source_id, model}. An id with no qualifier yields an empty source_id, which resolves to no source — resolve_qualified marks it stale and nothing runs on it.
static func parse_qualified(qualified: String) -> Dictionary:
	var at := qualified.find(QUALIFIER)
	if at == -1:
		return {"source_id": "", "model": qualified}
	return {"source_id": qualified.substr(0, at), "model": qualified.substr(at + QUALIFIER.length())}


## Everything a client needs to run a qualified model in one Dictionary: {source_id, source_name, base_url, api_key, kind, model, stale}. An id whose source doesn't resolve — deleted, renamed, or carrying no source qualifier at all — is never rerouted to another endpoint and key: it resolves with empty connection fields and stale=true, keeping the parsed id so refusals can name it, and LLMClient refuses to send on it. Feed the result straight to LLMClient.configure_from.
static func resolve_qualified(qualified: String) -> Dictionary:
	var parsed := parse_qualified(qualified)
	var source_id := String(parsed["source_id"])
	var source := resolve(source_id)
	var stale := source.is_empty()
	return {
		"source_id": source_id,
		"source_name": String(source.get("name", "")),
		"base_url": String(source.get("base_url", "")),
		"api_key": String(source.get("api_key", "")),
		"kind": String(source.get("kind", KIND_OLLAMA)),
		"model": String(parsed["model"]),
		"stale": stale,
	}


## A friendly picker/log label for a qualified id, provider first, e.g. "Poolside · laguna-m.1". An id whose source is gone is flagged ("poolside (missing) · laguna-m.1") rather than rendered as if the provider were still configured; one carrying no source qualifier at all renders as the bare model, since there is no id to flag.
static func label_for(qualified: String) -> String:
	var parsed := parse_qualified(qualified)
	var source_id := String(parsed["source_id"])
	if source_id == "":
		return String(parsed["model"])
	var source := resolve(source_id)
	if source.is_empty():
		return "%s (missing) · %s" % [source_id, parsed["model"]]
	var source_name := String(source.get("name", ""))
	if source_name == "":
		source_name = source_id
	return "%s · %s" % [source_name, parsed["model"]]


## A slug usable as a source id, derived from a display name: lowercased, non-alphanumerics collapsed to single dashes, edges trimmed. "" when the name has no usable characters (caller should fall back to a generated id).
static func slugify(name: String) -> String:
	var out := ""
	var prev_dash := false
	for ch in name.strip_edges().to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
			prev_dash = false
		elif not prev_dash and out != "":
			out += "-"
			prev_dash = true
	return out.trim_suffix("-")
