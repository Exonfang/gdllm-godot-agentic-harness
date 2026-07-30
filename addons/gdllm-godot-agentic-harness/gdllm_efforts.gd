@tool
class_name GDLLMEfforts
## Pure logic over the per-model reasoning-effort configuration: the OpenRouter-style level
## vocabulary and the user-maintained map of which levels each model actually supports. No API
## reports a model's levels (Ollama's /api/show carries no level vocabulary), so the user checks
## them off per model in the dock's Effort Configuration dialog. Keyed by qualified
## "source::model" id, so the same model on two sources is configured separately. A model with no
## entry (or an empty one) offers only "Default" and sends no effort at all, letting the model's
## own defaults prevail. Every adapter translates a selected level to its provider's own knob —
## Ollama's `think`, OpenAI's `reasoning_effort`, Anthropic's `output_config.effort` (with "none"
## as disabled thinking) — so this config alone decides what a model offers; a level the provider
## doesn't accept fails loudly at request time (see LLMAdapter.build_chat_body).
## The same dialog row also carries the model's optional prompt-cache TTL (cache_cold_gap_seconds), the idle gap after which the session presumes the provider prompt cache cold; unset falls back to the Cache TTL Fallback editor setting (see GDLLMChatSession._cache_cold_gap_seconds). On an Anthropic source the figure is enforced, not just presumed — it rides every request as the cache_control lifetime, quantized to the API's two tiers (see AnthropicAdapter.cache_control_for).
## And the model's optional declared context window (context_window_tokens): a set value overrides any window the provider's API reports (see GDLLMContexts.window_for), and for a source that reports none — an OpenAI-compatible server whose /v1/models entries carry no vendor window field (see OpenAIAdapter.context_probe) — it is the only way the meter, the automatic compaction trigger, and the over-window guards get a ceiling to judge against.

const SETTINGS_KEY := "gdllm/models/effort_levels_fallback" ## EditorSettings key holding the map as a JSON object string. A model's entry is a plain level array (["high", ...]) until a cache TTL or declared window is set, then {"levels": [...], "cache_cold_gap_seconds": N, "context_window_tokens": N} with only the set keys — the array shape stays readable and older stored configs parse unchanged. Named "…_fallback" like the sources key — the Effort Configuration dialog is the primary editor; this is the readable fallback.

## Every effort level, strongest first — OpenRouter's shared vocabulary, which each provider's own knob maps onto. "none" asks for no reasoning at all; the dropdown's "Default" is the absence of a level ("").
const LEVELS: Array[String] = ["max", "xhigh", "high", "medium", "low", "minimal", "none"]


## The stored config as {qualified_id: Array of level strings}, or {} when nothing is stored yet or the stored value is unparseable.
static func get_config() -> Dictionary:
	# A headless --script run has no editor settings to read; unconfigured is the honest answer there, and it keeps every accessor — now on GDLLMContexts.window_for's path — safe for the test suites.
	if not Engine.is_editor_hint():
		return {}
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTINGS_KEY):
		return {}
	var parsed: Variant = JSON.parse_string(String(es.get_setting(SETTINGS_KEY)))
	return parsed if parsed is Dictionary else {}


## Persist the config as a JSON string. Writing it emits EditorSettings.settings_changed, which is how every open session's effort picker picks the change up (see GDLLMChatDock._on_editor_settings_changed).
static func save_config(config: Dictionary) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTINGS_KEY, JSON.stringify(config))


## The levels `qualified` is configured to support, in LEVELS order regardless of stored order, unknown names dropped. Empty when the model was never configured — the caller then offers only "Default".
static func levels_for(qualified: String) -> PackedStringArray:
	var stored: Variant = get_config().get(qualified)
	var raw: Variant = stored.get("levels") if stored is Dictionary else stored
	if not (raw is Array):
		return PackedStringArray()
	var out := PackedStringArray()
	for level in LEVELS:
		if raw.has(level):
			out.append(level)
	return out


## The model's own prompt-cache TTL in seconds, or 0 when unconfigured — the caller then applies the Cache TTL Fallback editor setting (see GDLLMChatSession._cache_cold_gap_seconds).
static func cache_cold_gap_for(qualified: String) -> int:
	var stored: Variant = get_config().get(qualified)
	if stored is Dictionary:
		return maxi(0, int(stored.get("cache_cold_gap_seconds", 0)))
	return 0


## The model's user-declared maximum context window in tokens, or 0 when unconfigured. A declared value is the user's word over engine truth (see GDLLMContexts.window_for).
static func context_window_for(qualified: String) -> int:
	return window_from_entry(get_config().get(qualified))


## The declared window inside one stored entry, pure so the shape rule is testable headless: only the dict shape can carry one — the plain level-array shape predates the field — and a non-positive figure is unconfigured, never a window.
static func window_from_entry(stored: Variant) -> int:
	if stored is Dictionary:
		return maxi(0, int(stored.get("context_window_tokens", 0)))
	return 0


## The stored entry for a row's levels, cache TTL, and declared window: the plain level array unless a TTL or window is set, so configs without either keep the original readable shape, and only the set keys are stored.
static func make_entry(levels: Array, cache_cold_gap: int, context_window: int = 0) -> Variant:
	if cache_cold_gap <= 0 and context_window <= 0:
		return levels
	var entry := {"levels": levels}
	if cache_cold_gap > 0:
		entry["cache_cold_gap_seconds"] = cache_cold_gap
	if context_window > 0:
		entry["context_window_tokens"] = context_window
	return entry
