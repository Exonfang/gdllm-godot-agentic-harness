@tool
class_name GDLLMSettings
## Central home for the plugin's editor settings: key names, defaults, and helpers. Settings live in EditorSettings (per-developer, never committed)

const API_BASE := "gdllm/connection/api_base" ## Retired: the pre-multi-source single endpoint. Read once at register() to seed the local source, then erased. Sources now live under GDLLMSources.SETTINGS_KEY.
const CHAT_MODEL := "gdllm/models/chat"
const TASKS_MODEL := "gdllm/models/tasks" ## Small model for background chores: session-title summarization and read_file's long-file maps.

# Each model's system prompt sits beside it on the Models page; the alphabetical sort keeps prompt next to model.
const CHAT_SYSTEM_PROMPT := "gdllm/models/chat_system_prompt"
const TASKS_SYSTEM_PROMPT := "gdllm/models/tasks_system_prompt"

## Clock format for timestamps the plugin renders (e.g. a session's "Created …" header). Godot has no built-in 12h/24h preference, so we carry our own.
const TIME_FORMAT := "gdllm/interface/time_format"

## Whether the live reasoning block starts expanded and streams its trace as it's built. Off keeps it collapsed to a click-to-open "Thinking…" caption so a churning trace stays out of the way; the trace is never hidden, only deferred (see GDLLMChatSession._begin_thinking_block).
const AUTO_EXPAND_THINKING := "gdllm/interface/auto_expand_thinking"

## Whether tool-call disclosures start expanded when they appear, versus collapsed to a click-to-open caption. Off by default so the log stays terse; the calls are never hidden, only deferred.
const AUTO_EXPAND_TOOL_CALLS := "gdllm/interface/auto_expand_tool_calls"

## The tool-result counterpart to AUTO_EXPAND_TOOL_CALLS, split out because results are usually far longer than the calls that produced them.
const AUTO_EXPAND_TOOL_RESULTS := "gdllm/interface/auto_expand_tool_results"

## Whether model replies render as Markdown through the optional MarkdownLabel addon when it is installed. Off renders replies verbatim in a plain RichTextLabel — the same fallback a project without the addon gets automatically — for users who keep MarkdownLabel installed for their game but don't want this plugin using it (see GDLLMMarkdown).
const MARKDOWN_RESPONSES := "gdllm/interface/render_markdown_responses"

## Height (px) of the chat message box, set by dragging the grabber above it; shared by every session.
const INPUT_HEIGHT := "gdllm/interface/input_height"

## Most subagents the chat runs at once within a turn; extras beyond this queue and start as running ones finish (see GDLLMChatSession._maybe_start_subagents). 0 (or less) removes the cap.
const MAX_PARALLEL_SUBAGENTS := "gdllm/agents/max_parallel_subagents"

## Whether a newly created session starts with "Make changes" on. Off by default so write permission stays a per-conversation opt-in; existing sessions keep their own stored state either way.
const NEW_SESSION_EDITS := "gdllm/agents/new_sessions_start_with_edits"

## Whether the plugin keeps the GDLLMGameAgent autoload registered in the project — the in-game half of the game-driving tools (read_game_ui, send_game_input, call_game_method). The autoload is inert without a debugger attached; turning this off removes it from Project Settings → Globals on the spot (see the plugin's _sync_game_agent).
const GAME_AGENT := "gdllm/agents/register_game_input_agent"

## Master switch for the automatic context-compaction system; off disables the send-time trigger and every automatic pass added under it, leaving the context meter's readout, the send-time over-window warning, and the chat's manual Compact button.
const AUTO_COMPACTION := "gdllm/compaction/enable_automatic_context_compaction"

## Tokens of headroom the compaction trigger keeps between the predicted next prompt and the model's context window; the sole tuning knob — no per-model probing or special-casing.
const COMPACTION_BUFFER := "gdllm/compaction/buffer_tokens"

## Token count the predicted context must reach before tool results are pruned at all — the pruning pass reports itself skipped under it, so a small conversation is never touched.
const COMPACTION_PRUNE_THRESHOLD := "gdllm/compaction/tool_result_pruning_threshold"

## Fewest tokens a tool-result prune must recover before it commits — a prune rewrites the provider cache from the oldest pruned result forward, so a trivial recovery would cost more than it saves.
const COMPACTION_PRUNE_MIN_RECOVERY := "gdllm/compaction/minimum_token_recovery_from_tool_result_prune"

## Gates compaction pass 2 on its own: off leaves tool-result pruning as the only automatic pass, and a shortfall pruning can't cover is disclosed on the event instead of summarized. Also the default the manual Compact dialog's summarize checkbox opens with.
const COMPACTION_SUMMARIZATION := "gdllm/compaction/enable_summarization_pass"

## Gates the compaction trigger and tool-result pruning inside subagent tool loops, whose transcripts grow the same way the main chat's does; the master switch above still gates everything (see GDLLMSubagent._maybe_compact).
const COMPACTION_IN_SUBAGENTS := "gdllm/compaction/enable_compaction_within_subagents"

## Percentage of the model-visible conversation the summarization pass keeps verbatim as its newest tail; the rest is replaced by the summary (see GDLLMChatSession._summary_split_index).
const COMPACTION_TAIL_PERCENT := "gdllm/compaction/verbatim_recent_tail_percent"

## Idle seconds past which the provider prompt cache is presumed cold for models without their own cache-TTL figure in the Effort Configuration dialog (see GDLLMChatSession._cache_cold_gap_seconds).
const CACHE_TTL_FALLBACK := "gdllm/compaction/cache_ttl_fallback_seconds"

## Whether the compaction debugging tools are active; gates every debug override below it so a leftover value can't silently distort real behavior.
const COMPACTION_DEBUG := "gdllm/compaction/enable_debugging_tools"

## Debug-only: a token threshold the compaction trigger uses in place of the model's context window (0 = off), so compaction can be exercised against an arbitrarily small window.
const COMPACTION_DEBUG_THRESHOLD := "gdllm/compaction/debug_enforce_arbitrary_compaction_threshold"

const DEFAULT_MODEL := "nemotron-3-nano:30b"
const DEFAULT_TIME_FORMAT := "12-hour"
const DEFAULT_AUTO_EXPAND_THINKING := true
const DEFAULT_AUTO_EXPAND_TOOL_CALLS := false
const DEFAULT_AUTO_EXPAND_TOOL_RESULTS := false
const DEFAULT_MARKDOWN_RESPONSES := true
const DEFAULT_MAX_PARALLEL_SUBAGENTS := 4
const DEFAULT_NEW_SESSION_EDITS := false
const DEFAULT_GAME_AGENT := true
const DEFAULT_AUTO_COMPACTION := true
## 16k absorbs the incremental predictor's worst log-measured miss (~8.6k over 3421 wild requests) plus a typical reply's tokens.
const DEFAULT_COMPACTION_BUFFER := 16000
const DEFAULT_COMPACTION_PRUNE_THRESHOLD := 100000
const DEFAULT_COMPACTION_PRUNE_MIN_RECOVERY := 20000
const DEFAULT_COMPACTION_SUMMARIZATION := true
const DEFAULT_COMPACTION_IN_SUBAGENTS := true
## 30% verbatim tail matches the field norm (Gemini CLI keeps ~30%); the clamp bounds keep both a head and a tail meaningful.
const DEFAULT_COMPACTION_TAIL_PERCENT := 30
const MIN_COMPACTION_TAIL_PERCENT := 5
const MAX_COMPACTION_TAIL_PERCENT := 90
## Anthropic's 5-minute TTL — the shortest documented among the adapters' providers, so the conservative presumption when a model's real TTL isn't configured.
const DEFAULT_CACHE_TTL_FALLBACK := 300
const DEFAULT_COMPACTION_DEBUG := false
const DEFAULT_COMPACTION_DEBUG_THRESHOLD := 0
const DEFAULT_INPUT_HEIGHT := 80
const MIN_INPUT_HEIGHT := 40 ## Shortest the message box can be dragged or set down to.
const MAX_INPUT_HEIGHT := 600 ## Hard ceiling: an oversized value would grow the dock's minimum height past its slot, the vertical cousin of the min-width layout hang the picker clipping guards against.

const DEFAULT_CHAT_SYSTEM_PROMPT := "You are an AI assistant embedded directly in the Godot {godot_version} editor, helping the user with their questions. Use GDScript for any code. {markdown_rendering} Ground your answers rather than answering from assumption. When an answer depends on the engine's API — a class, method, signal, or property — use the describe_class tool (reach it through tool_search, like every other tool) to confirm what actually exists in this engine build before writing code against it. When an answer depends on the user's own project — their code, scenes, or how some part of it actually works — call tool_search to reach the project tools and explore first. A self-contained subtask — investigating how some part of the project works, summarizing material, drafting a piece of code — can be handed whole to a fresh-context helper via the run_subagent tool (find it with tool_search), which returns just its result and keeps this conversation's context lean. Stop exploring the moment you know enough to answer; questions you can already answer well need no exploration."
const DEFAULT_TASKS_SYSTEM_PROMPT := "You generate a short title for a chat conversation, summarizing the user's request in very few words. Reply with only the title text: no quotes, no trailing punctuation, no preamble."

## Where the merged list is cached between sessions, under the same per-project folder the session store uses. Lets a restart fill every picker instantly instead of showing only the last-used model while a fresh sweep runs.
const MODELS_CACHE_DIR := "user://gdllm"
const MODELS_CACHE_PATH := "user://gdllm/models_cache.json"

## The merged model list (qualified "source::model" ids) every model dropdown is built from. Seeded from disk cache at register() so a restart shows the full picker with no HTTP, then refreshed on demand — when a picker opens or from the Connections dialog (see GDLLMChatDock.refresh_all_models).
static var _available_models: PackedStringArray = PackedStringArray()


## Register the settings so they show up in Editor → Editor Settings and persist across sessions. Idempotent — safe to call on every plugin load; existing values are kept.
static func register() -> void:
	var es := EditorInterface.get_editor_settings()
	# carry values off the pre-"Models"-page keys so a prior install's choices aren't lost
	_migrate(es, "gdllm/chat/model", CHAT_MODEL)
	# Carry a prior install's sources onto the renamed key ("sources" -> "sources_fallback") before seeding decides the key is empty, so configured sources and keys aren't lost.
	_migrate(es, "gdllm/connection/sources", GDLLMSources.SETTINGS_KEY)
	# Seed the multi-source list, carrying the pre-multi-source single endpoint onto the local source, then retire the flat API_BASE key (sources live under GDLLMSources.SETTINGS_KEY now).
	var local_base := String(es.get_setting(API_BASE)) if es.has_setting(API_BASE) else GDLLMSources.DEFAULT_OLLAMA_LOCAL_BASE
	GDLLMSources.ensure_seeded(local_base)
	es.erase(API_BASE)
	# An install seeded before the Anthropic kind existed gets its template row appended once, so the Connections dialog shows it without a hand-added source (deleting it sticks; see GDLLMSources.TEMPLATES_SEEDED_KEY).
	GDLLMSources.ensure_anthropic_template()
	# Render the raw sources JSON as a multi-line text box, labeled "Sources Fallback" (the Connections dialog is the primary editor; this is the readable fallback). ensure_seeded already set the value, so _define only adds the multiline property info.
	_define(es, GDLLMSources.SETTINGS_KEY, JSON.stringify(GDLLMSources.default_sources(local_base)), PROPERTY_HINT_MULTILINE_TEXT)
	# Same fallback pattern for the per-model effort-level and cache-TTL map (the Effort Configuration dialog is the primary editor; see GDLLMEfforts).
	_define(es, GDLLMEfforts.SETTINGS_KEY, "{}", PROPERTY_HINT_MULTILINE_TEXT)
	# And for the ordered favorite-models list (the Favorite Models dialog is the primary editor; see GDLLMFavorites).
	_define(es, GDLLMFavorites.SETTINGS_KEY, "[]", PROPERTY_HINT_MULTILINE_TEXT)
	# Model settings now hold a qualified "source::model" id; default to the local source's default model.
	var default_model := GDLLMSources.make_qualified("ollama-local", DEFAULT_MODEL)
	_define(es, CHAT_MODEL, default_model)
	_define(es, TASKS_MODEL, default_model)
	_define(es, CHAT_SYSTEM_PROMPT, DEFAULT_CHAT_SYSTEM_PROMPT, PROPERTY_HINT_MULTILINE_TEXT)
	# A stored prompt byte-identical to the pre-placeholder default is that default, not a user edit — adopt the placeholder form so the Markdown line gates on existing installs too.
	if String(es.get_setting(CHAT_SYSTEM_PROMPT)) == GDLLMMarkdown.apply_prompt_placeholder(DEFAULT_CHAT_SYSTEM_PROMPT, true):
		es.set_setting(CHAT_SYSTEM_PROMPT, DEFAULT_CHAT_SYSTEM_PROMPT)
	_define(es, TASKS_SYSTEM_PROMPT, DEFAULT_TASKS_SYSTEM_PROMPT, PROPERTY_HINT_MULTILINE_TEXT)
	_define(es, TIME_FORMAT, DEFAULT_TIME_FORMAT, PROPERTY_HINT_ENUM, "12-hour,24-hour")
	_define_bool(es, AUTO_EXPAND_THINKING, DEFAULT_AUTO_EXPAND_THINKING)
	_define_bool(es, AUTO_EXPAND_TOOL_CALLS, DEFAULT_AUTO_EXPAND_TOOL_CALLS)
	_define_bool(es, AUTO_EXPAND_TOOL_RESULTS, DEFAULT_AUTO_EXPAND_TOOL_RESULTS)
	_define_bool(es, MARKDOWN_RESPONSES, DEFAULT_MARKDOWN_RESPONSES)
	_define_int(es, INPUT_HEIGHT, DEFAULT_INPUT_HEIGHT, "%d,%d,1" % [MIN_INPUT_HEIGHT, MAX_INPUT_HEIGHT])
	# or_greater lets the spinbox go past 64 by typing, while 0 stands for "no cap".
	_define_int(es, MAX_PARALLEL_SUBAGENTS, DEFAULT_MAX_PARALLEL_SUBAGENTS, "0,64,1,or_greater")
	_define_bool(es, NEW_SESSION_EDITS, DEFAULT_NEW_SESSION_EDITS)
	_define_bool(es, GAME_AGENT, DEFAULT_GAME_AGENT)
	_define_bool(es, AUTO_COMPACTION, DEFAULT_AUTO_COMPACTION)
	# or_greater lets the buffer pass 64k by typing; 0 means trigger only once the window itself is predicted full.
	_define_int(es, COMPACTION_BUFFER, DEFAULT_COMPACTION_BUFFER, "0,65536,1000,or_greater")
	# 0 lets pruning run at any size; or_greater covers windows past a million tokens.
	_define_int(es, COMPACTION_PRUNE_THRESHOLD, DEFAULT_COMPACTION_PRUNE_THRESHOLD, "0,1000000,10000,or_greater")
	# 0 commits any positive recovery, however small.
	_define_int(es, COMPACTION_PRUNE_MIN_RECOVERY, DEFAULT_COMPACTION_PRUNE_MIN_RECOVERY, "0,65536,1000,or_greater")
	_define_bool(es, COMPACTION_SUMMARIZATION, DEFAULT_COMPACTION_SUMMARIZATION)
	_define_bool(es, COMPACTION_IN_SUBAGENTS, DEFAULT_COMPACTION_IN_SUBAGENTS)
	_define_int(es, COMPACTION_TAIL_PERCENT, DEFAULT_COMPACTION_TAIL_PERCENT, "%d,%d,1" % [MIN_COMPACTION_TAIL_PERCENT, MAX_COMPACTION_TAIL_PERCENT])
	# Applies only to models without their own cache-TTL figure in the Effort Configuration dialog; or_greater admits providers with hour-long caches.
	_define_int(es, CACHE_TTL_FALLBACK, DEFAULT_CACHE_TTL_FALLBACK, "0,3600,10,or_greater")
	_define_bool(es, COMPACTION_DEBUG, DEFAULT_COMPACTION_DEBUG)
	# A plain editable number line rather than a range spinbox: any window-sized figure is legitimate, and 0 keeps the override off.
	_define_int_plain(es, COMPACTION_DEBUG_THRESHOLD, DEFAULT_COMPACTION_DEBUG_THRESHOLD)
	# The chat log's palette, defined straight off GDLLMColors' map so a new color role is one entry there and nothing here.
	for color_key: String in GDLLMColors.DEFAULTS:
		var color_default: Color = GDLLMColors.DEFAULTS[color_key]
		_define_color(es, color_key, color_default)
	# Seed the pickers from last session's cached list so boot never waits on model HTTP; a fresh sweep runs only on demand.
	load_cached_models()


## Carry a value from a pre-rename key onto its new key and erase the stale one, so old entries don't linger in the settings dialog. No-op once nothing predates the rename.
static func _migrate(es: EditorSettings, old_key: String, new_key: String) -> void:
	if not es.has_setting(old_key):
		return
	if not es.has_setting(new_key):
		es.set_setting(new_key, es.get_setting(old_key))
	es.erase(old_key)


static func _define(es: EditorSettings, key: String, default: String, hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not es.has_setting(key):
		es.set_setting(key, default)
	es.set_initial_value(key, default, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": hint,
		"hint_string": hint_string,
	})


## The integer counterpart to _define, rendered as a range spinbox from `range_hint` ("min,max,step[,or_greater]").
static func _define_int(es: EditorSettings, key: String, default: int, range_hint: String) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default)
	es.set_initial_value(key, default, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": range_hint,
	})


## The hint-free integer counterpart to _define_int, rendered as a plain editable number line instead of a range spinbox.
static func _define_int_plain(es: EditorSettings, key: String, default: int) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default)
	es.set_initial_value(key, default, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	})


## The boolean counterpart to _define, rendered as a checkbox in the settings dialog.
static func _define_bool(es: EditorSettings, key: String, default: bool) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default)
	es.set_initial_value(key, default, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	})


## The Color counterpart to _define, rendered as the inspector's color swatch and picker. Alpha stays editable: most of the log's colors are translucent washes over whatever sits beneath them.
static func _define_color(es: EditorSettings, key: String, default: Color) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default)
	es.set_initial_value(key, default, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_COLOR,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	})


## Record the merged model list (qualified "source::model" ids across every configured source) as the single source of truth for every model dropdown, rebuild the settings-page enums from it, and cache it to disk so the next restart shows the full picker without a fetch. The dock reads get_available_models() to build each session picker.
static func set_available_models(models: PackedStringArray) -> void:
	_available_models = models
	_refresh_model_enum(models)
	_write_models_cache(models)


## The current merged model list; every model select field is built from this. Seeded from disk at register() and refreshed on demand, so it's rarely empty — only a first-ever run with an unreachable server leaves it bare until a source responds.
static func get_available_models() -> PackedStringArray:
	return _available_models


## Load the cached merged list into _available_models and rebuild the settings enums from it, so the pickers are populated the instant register() runs — before any source is contacted. No-op (empty list) on first run, when the cache file doesn't exist yet.
static func load_cached_models() -> void:
	_available_models = _read_models_cache()
	_refresh_model_enum(_available_models)


## Read the cached list from disk, returning an empty array if the file is absent or unparseable (first run, or a corrupted cache — either way a sweep will repopulate it).
static func _read_models_cache() -> PackedStringArray:
	if not FileAccess.file_exists(MODELS_CACHE_PATH):
		return PackedStringArray()
	var file := FileAccess.open(MODELS_CACHE_PATH, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var data: Variant = JSON.parse_string(file.get_as_text())
	return PackedStringArray(data) if data is Array else PackedStringArray()


## Persist the merged list so the next editor start can seed the pickers from it. Failures are non-fatal — the cache is only an optimization, and a sweep rebuilds it.
static func _write_models_cache(models: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(MODELS_CACHE_DIR)
	var file := FileAccess.open(MODELS_CACHE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("GDLLMSettings: could not write model cache %s" % MODELS_CACHE_PATH)
		return
	file.store_string(JSON.stringify(Array(models)))


## Turn the model settings into native dropdowns in the settings dialog, populated from the models actually installed on the server. The current value is folded in so a model the server didn't report stays selectable.
static func _refresh_model_enum(models: PackedStringArray) -> void:
	var es := EditorInterface.get_editor_settings()
	for key in [CHAT_MODEL, TASKS_MODEL]:
		# Favorites float to the top here too, so the settings dropdowns mirror the session pickers' order.
		var names := GDLLMFavorites.apply_order(models)
		var current := String(es.get_setting(key))
		if current != "" and not names.has(current):
			names.append(current)
		es.add_property_info({
			"name": key,
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": ",".join(names),
		})


## The resolved source (endpoint, key, wire format) plus bare model for the chat model, ready for LLMClient.configure_from. The tasks counterpart follows. Each reads the stored qualified id and hands it to GDLLMSources.
static func get_chat_source_and_model() -> Dictionary:
	return GDLLMSources.resolve_qualified(get_chat_model())


static func get_tasks_source_and_model() -> Dictionary:
	return GDLLMSources.resolve_qualified(get_tasks_model())


## Whether timestamps should render on a 24-hour clock (else 12-hour with AM/PM).
static func is_24_hour_clock() -> bool:
	return String(EditorInterface.get_editor_settings().get_setting(TIME_FORMAT)) == "24-hour"


## Whether the live reasoning block auto-expands and streams its trace, versus starting collapsed to a click-to-open caption (see GDLLMChatSession._begin_thinking_block).
static func is_auto_expand_thinking() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(AUTO_EXPAND_THINKING))


## Whether tool-call disclosures start expanded when they appear (see GDLLMChatSession._add_tool_call_block).
static func is_auto_expand_tool_calls() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(AUTO_EXPAND_TOOL_CALLS))


## Whether tool-result disclosures start expanded when they appear (see GDLLMChatSession._add_tool_result_block).
static func is_auto_expand_tool_results() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(AUTO_EXPAND_TOOL_RESULTS))


## Whether model replies may render as Markdown; the MarkdownLabel addon must also be installed (GDLLMMarkdown.enabled combines the two).
static func is_markdown_responses_enabled() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(MARKDOWN_RESPONSES))


## Persist the auto-expand-thinking preference. The single write path both the session header's switch and the settings-dialog checkbox resolve to — writing it emits EditorSettings.settings_changed, which is how the two displays stay in sync.
static func set_auto_expand_thinking(value: bool) -> void:
	EditorInterface.get_editor_settings().set_setting(AUTO_EXPAND_THINKING, value)


## Persist the auto-expand-tool-calls preference; the tool-call counterpart to set_auto_expand_thinking, shared by the header switch and the settings dialog.
static func set_auto_expand_tool_calls(value: bool) -> void:
	EditorInterface.get_editor_settings().set_setting(AUTO_EXPAND_TOOL_CALLS, value)


## Persist the auto-expand-tool-results preference; the tool-result counterpart to set_auto_expand_tool_calls.
static func set_auto_expand_tool_results(value: bool) -> void:
	EditorInterface.get_editor_settings().set_setting(AUTO_EXPAND_TOOL_RESULTS, value)


## Height of the chat message box; clamped so a hand-edited value can't push the dock's minimum size past its slot.
static func get_input_height() -> int:
	return clampi(int(EditorInterface.get_editor_settings().get_setting(INPUT_HEIGHT)), MIN_INPUT_HEIGHT, MAX_INPUT_HEIGHT)


static func set_input_height(value: int) -> void:
	EditorInterface.get_editor_settings().set_setting(INPUT_HEIGHT, clampi(value, MIN_INPUT_HEIGHT, MAX_INPUT_HEIGHT))


## Most subagents a turn may run concurrently before the rest queue; 0 or less means no cap (see GDLLMChatSession._maybe_start_subagents).
static func get_max_parallel_subagents() -> int:
	return int(EditorInterface.get_editor_settings().get_setting(MAX_PARALLEL_SUBAGENTS))


## Whether a newly created session starts with "Make changes" on (see GDLLMSessionStore._new_record).
static func is_new_session_edits_on() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(NEW_SESSION_EDITS))


## Whether the plugin keeps the GDLLMGameAgent autoload registered (see the plugin's _sync_game_agent). Read defensively because _enable_plugin consults it before register() has defined the key.
static func is_game_agent_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(GAME_AGENT):
		return DEFAULT_GAME_AGENT
	return bool(es.get_setting(GAME_AGENT))


## Whether the automatic context-compaction system is on at all (see GDLLMChatSession._maybe_trigger_compaction).
static func is_auto_compaction_enabled() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(AUTO_COMPACTION))


## Headroom (tokens) the compaction trigger keeps between the predicted next prompt and the model's window, clamped so a hand-edited negative can't turn the buffer into extra room. Enforced to 0 while the debug threshold override is active, so the trigger fires exactly at the user-defined threshold rather than a buffer-width early.
static func get_compaction_buffer_tokens() -> int:
	if get_compaction_debug_override() > 0:
		return 0
	return maxi(0, int(EditorInterface.get_editor_settings().get_setting(COMPACTION_BUFFER)))


## Token count the predicted context must reach before the tool-result pruning pass may run at all, clamped so a hand-edited negative can't arm pruning on a near-empty session (see GDLLMChatSession._prune_tool_results). Deliberately NOT suspended by the debug threshold override — the pass's skip note names this setting, so a debugging user lowers it knowingly instead of it silently vanishing.
static func get_prune_threshold_tokens() -> int:
	return maxi(0, int(EditorInterface.get_editor_settings().get_setting(COMPACTION_PRUNE_THRESHOLD)))


## Fewest tokens a tool-result prune must recover before it commits — a pass that can't reach this reports the shortfall and prunes nothing (see GDLLMChatSession._prune_tool_results).
static func get_prune_min_recovery_tokens() -> int:
	return maxi(0, int(EditorInterface.get_editor_settings().get_setting(COMPACTION_PRUNE_MIN_RECOVERY)))


## Whether compaction's anchored-summarization pass may run at all (see GDLLMChatSession._run_summary_pass); off leaves tool-result pruning as the only automatic pass.
static func is_summarization_enabled() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(COMPACTION_SUMMARIZATION))


## Whether the compaction trigger and tool-result pruning also run inside subagent tool loops (see GDLLMSubagent._maybe_compact); the master compaction switch still gates everything.
static func is_subagent_compaction_enabled() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(COMPACTION_IN_SUBAGENTS))


## Percentage of the model-visible conversation the summarization pass keeps verbatim, clamped so a hand-edited value can't leave the pass without a head to summarize or a tail to keep (see GDLLMChatSession._summary_split_index).
static func get_compaction_tail_percent() -> int:
	return clampi(int(EditorInterface.get_editor_settings().get_setting(COMPACTION_TAIL_PERCENT)), MIN_COMPACTION_TAIL_PERCENT, MAX_COMPACTION_TAIL_PERCENT)


## Idle seconds past which the provider prompt cache is presumed cold when the model carries no cache-TTL figure of its own. Hand-edited negatives clamp to 0, which presumes the cache always cold — a boundary on every send, legitimate for a provider with no prompt cache at all.
static func get_cache_ttl_fallback_seconds() -> int:
	return maxi(0, int(EditorInterface.get_editor_settings().get_setting(CACHE_TTL_FALLBACK)))


## The debug threshold standing in for the model's context window in the compaction trigger, or 0 whenever the override is inactive — the debugging-tools gate and the above-zero requirement both live here so callers can't apply half the rule (see GDLLMChatSession._maybe_trigger_compaction).
static func get_compaction_debug_override() -> int:
	var es := EditorInterface.get_editor_settings()
	if not bool(es.get_setting(COMPACTION_DEBUG)):
		return 0
	return maxi(0, int(es.get_setting(COMPACTION_DEBUG_THRESHOLD)))


static func get_chat_model() -> String:
	return String(EditorInterface.get_editor_settings().get_setting(CHAT_MODEL))


## Small model used for background chores (session-title summarization, read_file's long-file maps, and any future task work).
static func get_tasks_model() -> String:
	return String(EditorInterface.get_editor_settings().get_setting(TASKS_MODEL))


## System prompt for the dock chat conversation.
static func get_chat_system_prompt() -> String:
	return _apply_placeholders(String(EditorInterface.get_editor_settings().get_setting(CHAT_SYSTEM_PROMPT)))


## System prompt handed to the Tasks Model for background chores (currently session-title summarization).
static func get_tasks_system_prompt() -> String:
	return _apply_placeholders(String(EditorInterface.get_editor_settings().get_setting(TASKS_SYSTEM_PROMPT)))


## Substitute the placeholders any prompt may contain, each movable anywhere in the prompt — or dropped entirely. `{godot_version}` becomes the running editor's version (e.g. "4.7.0"). `{markdown_rendering}` becomes the ask for Markdown formatting while replies actually render as Markdown, and an instruction to write plainly while they fall back to plain text (MarkdownLabel absent, or Render Markdown Responses off) — silence isn't enough, models default to Markdown unprompted.
static func _apply_placeholders(prompt: String) -> String:
	var v := Engine.get_version_info()
	var godot_version := "%d.%d.%d" % [v.major, v.minor, v.patch]
	prompt = prompt.replace("{godot_version}", godot_version)
	return GDLLMMarkdown.apply_prompt_placeholder(prompt, GDLLMMarkdown.enabled())


## Persist the chat model. Writing it emits EditorSettings.settings_changed, which is how the dock picker and the settings page keep each other in sync.
static func set_chat_model(model: String) -> void:
	EditorInterface.get_editor_settings().set_setting(CHAT_MODEL, model)


static func set_tasks_model(model: String) -> void:
	EditorInterface.get_editor_settings().set_setting(TASKS_MODEL, model)
