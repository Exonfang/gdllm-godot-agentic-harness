@tool
class_name GDLLMContexts
## Persistent per-model context-window cache: qualified "source::model" id -> the maximum context (input tokens) the source's own API reported for it.
## Filled on demand — a session probes its model's source the first time the window is unknown (see GDLLMChatSession._refresh_context_window) — and cached to disk so a restart knows every window without HTTP.
## Only engine truth enters the cache: Ollama's /api/show, Anthropic's /v1/models, and an OpenAI-compatible /v1/models entry that carries a vendor window field (vLLM's max_model_len, OpenRouter's context_length, Groq's context_window) report a window; an OpenAI-compatible server carrying none stays unknown here (see OpenAIAdapter.context_probe).
## A window the user declared in the Effort Configuration dialog overrides the cache at lookup instead of entering it (see window_for) — the cache stays pure engine truth, and clearing the declaration falls straight back to it.

const CACHE_PATH := "user://gdllm/context_cache.json" ## Beside the models cache, under the same per-project folder (GDLLMSettings.MODELS_CACHE_DIR).

static var _windows: Dictionary = {} ## qualified id -> window in tokens; the in-memory copy of the disk cache.
static var _loaded := false ## The disk cache has been read this editor run; guards against re-reading it on every lookup.


## The maximum context window for `qualified`: the user-declared figure when one is set — the user's word outranks engine truth, and is the only source for providers whose API reports none — else the cached probe report, or 0 when neither exists.
static func window_for(qualified: String) -> int:
	var declared := GDLLMEfforts.context_window_for(qualified)
	if declared > 0:
		return declared
	_ensure_loaded()
	return int(_windows.get(qualified, 0))


## Record a probe's reported window and persist it. Zero or negative reports are dropped — an unknown stays unknown rather than caching an invented figure.
static func store(qualified: String, tokens: int) -> void:
	if qualified == "" or tokens <= 0:
		return
	_ensure_loaded()
	if int(_windows.get(qualified, 0)) == tokens:
		return
	_windows[qualified] = tokens
	_write()


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if file == null:
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not (data is Dictionary):
		return
	for key in data:
		var tokens := int(data[key])
		if tokens > 0:
			_windows[String(key)] = tokens


## Persist the cache. Failures are non-fatal — the cache is an optimization, and the next probe repopulates it.
static func _write() -> void:
	DirAccess.make_dir_recursive_absolute(GDLLMSettings.MODELS_CACHE_DIR)
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("GDLLMContexts: could not write context cache %s" % CACHE_PATH)
		return
	file.store_string(JSON.stringify(_windows))
