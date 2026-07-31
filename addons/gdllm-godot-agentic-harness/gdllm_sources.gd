@tool
class_name GDLLMSources
## Pure logic over the configured model sources: the list of places models come from (Ollama local/cloud, OpenAI-compatible endpoints like vLLM or Poolside, and Anthropic) and the qualified-id helpers that let one "model" string carry which source it belongs to.
## No UI, no transport — the dock's Connections dialog edits this list, and LLMClient consumes a resolved source (see resolve_qualified).

const SETTINGS_KEY := "gdllm/connection/sources_fallback" ## EditorSettings key holding the sources as a JSON array string. Named "…/sources_fallback" so the settings dialog labels it "Sources Fallback" — a reminder the dock's Connections dialog is the primary editor.
const TEMPLATES_SEEDED_KEY := "gdllm/connection/templates_seeded" ## EditorSettings key listing (as a JSON array) the template ids already offered to this install. A template added after an install's first seeding appears exactly once through it — deleting the row sticks, instead of the template resurrecting on every load.
const QUALIFIER := "::" ## Separates a source id from a model name in a qualified model id; neither part contains it.

const KIND_OLLAMA := "ollama" ## Native Ollama wire format (/api/chat NDJSON), used by local and cloud alike.
const KIND_OPENAI := "openai" ## OpenAI-compatible wire format (/v1/chat/completions SSE), used by vLLM, Poolside, etc.
const KIND_ANTHROPIC := "anthropic" ## Anthropic Messages API wire format (/v1/messages SSE), used by the Claude models.

const DEFAULT_OLLAMA_LOCAL_BASE := "http://localhost:11434" ## Seed endpoint for the first-run local source; the pre-multi-source default.
const DEFAULT_ANTHROPIC_BASE := "https://api.anthropic.com" ## Anthropic's API host; the same for every account, so the Connections dialog prefills it when a row switches to the Anthropic kind.


## The configured sources as an Array of source Dictionaries, or the default seed when nothing is stored yet or the stored value is unparseable.
static func get_sources() -> Array:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTINGS_KEY):
		return default_sources()
	var parsed: Variant = JSON.parse_string(String(es.get_setting(SETTINGS_KEY)))
	return parsed if parsed is Array else default_sources()


## Persist the sources list as a JSON string. Writing it emits EditorSettings.settings_changed, which is how open clients pick up an endpoint or key edit made in the Connections dialog.
static func save_sources(sources: Array) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTINGS_KEY, JSON.stringify(sources))


## Seed the sources list on first run if it's unset, carrying the pre-multi-source endpoint onto the local source. Idempotent — leaves an existing list untouched.
static func ensure_seeded(local_base: String = DEFAULT_OLLAMA_LOCAL_BASE) -> void:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting(SETTINGS_KEY):
		return
	save_sources(default_sources(local_base))


## The first-run source list: the migrated local Ollama plus ready-to-fill templates for Ollama Cloud, a local vLLM, Poolside, and Anthropic (blank keys). Paste a key into the cloud ones via the Connections dialog to enable them.
static func default_sources(local_base: String = DEFAULT_OLLAMA_LOCAL_BASE) -> Array:
	return [
		{"id": "ollama-local", "name": "Ollama (Local)", "kind": KIND_OLLAMA, "base_url": local_base, "api_key": "", "enabled": true},
		{"id": "ollama-cloud", "name": "Ollama Cloud", "kind": KIND_OLLAMA, "base_url": "https://ollama.com", "api_key": "", "enabled": true},
		{"id": "vllm-local", "name": "vLLM (Local)", "kind": KIND_OPENAI, "base_url": "http://localhost:8000/v1", "api_key": "", "enabled": true},
		{"id": "poolside", "name": "Poolside", "kind": KIND_OPENAI, "base_url": "https://inference.poolside.ai/v1", "api_key": "", "enabled": true},
		_anthropic_template(),
	]


## The ready-to-fill Anthropic source row, shared by the first-run seed and the one-time append for installs that predate it.
static func _anthropic_template() -> Dictionary:
	return {"id": "anthropic", "name": "Anthropic", "kind": KIND_ANTHROPIC, "base_url": DEFAULT_ANTHROPIC_BASE, "api_key": "", "enabled": true}


## Append the Anthropic template for an install whose sources predate it — a first run already carries it via default_sources. Offered exactly once, tracked in TEMPLATES_SEEDED_KEY, so a user who deletes the row never sees it come back; an Anthropic source the user already added by hand counts as offered too.
static func ensure_anthropic_template() -> void:
	var es := EditorInterface.get_editor_settings()
	var seeded: Array = []
	if es.has_setting(TEMPLATES_SEEDED_KEY):
		var parsed: Variant = JSON.parse_string(String(es.get_setting(TEMPLATES_SEEDED_KEY)))
		if parsed is Array:
			seeded = parsed
	if seeded.has("anthropic"):
		return
	seeded.append("anthropic")
	es.set_setting(TEMPLATES_SEEDED_KEY, JSON.stringify(seeded))
	# Nothing to offer when the user already points anywhere at Anthropic — by the template's id or by kind.
	if not resolve("anthropic").is_empty():
		return
	var sources := get_sources()
	for source in sources:
		if source is Dictionary and String(source.get("kind", "")) == KIND_ANTHROPIC:
			return
	sources.append(_anthropic_template())
	save_sources(sources)


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
