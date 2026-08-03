@tool
class_name GDLLMTunables
## Every arbitrary numeric tunable the harness runs on, as editor settings — the numbers that were magic constants scattered through the codebase, each now registered under its own key with the shipped value as default, so an untouched install behaves exactly as before. GDLLMSettings.register() defines the whole set from SPECS (the GDLLMColors pattern), GDLLMSettingsHelp carries each key's user-facing explanation, and every read goes through geti/getf, which clamp a hand-edited value into its spec's range and fall back to the default outside the editor — so the headless suites always run on the shipped numbers.
## Deliberately self-contained: this class references no other harness class, so any file (including the ones whose constants moved here) can read it without a load-order cycle.
## NOT here, deliberately: the game-process constants (GDLLMGameProtocol, and GDLLMGameAgent's overlay timing) — that code runs inside the game, where EditorSettings doesn't exist, so configuring those means shipping values over the debugger wire first; the per-tool max_consecutive_uses loop-break points, which are per-tool policy in the REGISTRY rather than one number; heuristic internals no user has a mental model for (GDLLMTools.EDIT_CLOSEST_REGION_FLOOR, GDLLMDocs' search-ranking score weights, GDLLMAnimation.KEY_TIME_EPSILON — the last pinned to float32 storage precision, not preference); and a handful of purely cosmetic clips that shape log text no model reads as data (LLMClient.BODY_EXCERPT_CHARS and its .left(300) error-excerpt cousins, GDLLMTools.SUBAGENT_LABEL_MAX_CHARS, GDLLMChatDock.COLOR_REPAINT_INTERVAL, the inspect dialog's preview clip).

# --- gdllm/network — talking to LLM endpoints ---

## Seconds to wait for the chat socket (name resolution + connect only, never the model's own thinking time) before failing the stream.
const STREAM_CONNECT_TIMEOUT := "gdllm/network/stream_connect_timeout_seconds"
## Seconds a model-list fetch or context-window probe may run before it resolves as empty.
const MODEL_FETCH_TIMEOUT := "gdllm/network/model_fetch_timeout_seconds"
## Fallback max_tokens for an Anthropic chat request whose model's real output cap no /v1/models sweep has reported yet.
const ANTHROPIC_MAX_TOKENS_FALLBACK := "gdllm/network/anthropic_max_tokens_fallback"
## max_tokens for the Anthropic one-shot completion path (title generation) — short-form work that never needs the chat path's headroom.
const ANTHROPIC_COMPLETION_MAX_TOKENS := "gdllm/network/anthropic_completion_max_tokens"

# --- gdllm/context — what a conversation costs ---

## The plugin-wide chars-per-token estimation ratio; every token estimate (context meter, compaction trigger, prune savings, stats footers) routes through it.
const CHARS_PER_TOKEN := "gdllm/context/chars_per_token"
## Percent of the model's context window the predicted next prompt must fill before the context meter turns orange; capped at the danger percent below, so an inverted pair reads as one red line rather than dead warning code.
const CONTEXT_METER_WARNING_PERCENT := "gdllm/context/context_meter_warning_percent"
## Percent that turns the meter red (the error color takes over from the warning color).
const CONTEXT_METER_DANGER_PERCENT := "gdllm/context/context_meter_danger_percent"
## The most tools one tool_search returns; everything returned is also attached to every later turn (until schema retirement reclaims it idle), so this bounds what a single vague query can cost the prompt.
const TOOL_SEARCH_MAX_RESULTS := "gdllm/context/tool_search_max_results"
## User turns an attached tool may sit unused before a cache-bust boundary retires its schema from the request; one tool_search re-attaches it.
const SCHEMA_RETIRE_IDLE_TURNS := "gdllm/context/schema_retire_idle_turns"
## How many selected scene nodes one send will attach; the overflow is stated on every attached body rather than dropped quietly.
const MAX_ATTACHED_SCENE_NODES := "gdllm/context/max_attached_scene_nodes"

# --- gdllm/compaction — the knobs its passes run on (the section's switches and thresholds live in GDLLMSettings) ---

## Smallest head (tokens) worth a summarization request; below it the pass reports itself skipped. Waived for a focused run.
const SUMMARY_MIN_HEAD_TOKENS := "gdllm/compaction/summary_minimum_head_tokens"
## Window room (tokens) the fit guard holds back for the summary the model must still have space to write.
const SUMMARY_OUTPUT_RESERVE_TOKENS := "gdllm/compaction/summary_output_reserve_tokens"
## Consecutive summarization failures on one model before the pass suspends itself — the circuit breaker against burning tokens on a model that keeps failing.
const SUMMARY_FAILURE_BREAKER := "gdllm/compaction/summary_failure_breaker_limit"
## Times the fit guard may resize the split before giving up; the first, proportional resize normally lands.
const SUMMARY_FIT_ATTEMPTS := "gdllm/compaction/summary_fit_attempts"
## Percent of the computed size each fit-guard resize actually aims for, so a retry lands inside the window instead of on its line.
const SUMMARY_FIT_MARGIN_PERCENT := "gdllm/compaction/summary_fit_margin_percent"
## Percent of a manual compaction's token target held back for the summary message itself when the target sizes the split.
const SUMMARY_TARGET_RESERVE_PERCENT := "gdllm/compaction/summary_target_reserve_percent"
## Newest tool call/result pairs the pruning passes always leave intact — the model's working set for the turn in flight.
const PRUNE_KEEP_RECENT_PAIRS := "gdllm/compaction/prune_keep_recent_pairs"

# --- gdllm/agents — loop-brake escalation (the agent switches live in GDLLMSettings) ---

## Withheld-duplicate firings in one run past which the gentle stubs have provably failed and the run is stopped for a progress summary.
const WITHHELD_ESCALATION_THRESHOLD := "gdllm/agents/withheld_duplicate_escalation_threshold"
## Tool calls the "you left files BROKEN" reminder stays silent for after each firing, so it never becomes a per-call nag.
const BROKEN_REMINDER_COOLDOWN := "gdllm/agents/broken_reminder_cooldown_calls"

# --- gdllm/interface — chat presentation (its switches live in GDLLMSettings) ---

## Longest a Tasks-Model-generated session title runs before it is clipped with an ellipsis.
const SESSION_TITLE_MAX_CHARS := "gdllm/interface/session_title_max_chars"
## Seconds a session write sits debounced before it lands on disk; the only loss window is this much tail on a hard editor crash.
const SESSION_SAVE_DEBOUNCE_SECONDS := "gdllm/interface/session_save_debounce_seconds"
## Milliseconds of history rendering per frame while a restored session replays; the rest yields to the editor.
const REPLAY_FRAME_BUDGET_MS := "gdllm/interface/session_replay_frame_budget_ms"

# --- gdllm/tool_output — how much of a tool's answer lands in context ---

## Character count past which read_file stops returning a file whole and has a fresh-context subagent map it instead; 0 (or -1) disables the long-file map, reading text files whole.
const READ_FILE_SUMMARY_THRESHOLD := "gdllm/tool_output/read_file_summary_threshold_chars"
## Payload characters past which a packed-array literal in read_file output is elided to a count marker; 0 (or -1) disables elision.
const PACKED_ARRAY_ELIDE_CHARS := "gdllm/tool_output/packed_array_elide_chars"
## Default lines of context around a search_files match when no enclosing function applies; an explicit context_lines ask is uncapped.
const SEARCH_CONTEXT_LINES := "gdllm/tool_output/search_default_context_lines"
## The most excerpt blocks (or overview lines) one search_files result carries.
const SEARCH_MAX_BLOCKS := "gdllm/tool_output/search_max_excerpt_blocks"
## Longest function shown whole at the default context before its excerpt falls back to a window.
const SEARCH_MAX_FUNCTION_LINES := "gdllm/tool_output/search_max_function_excerpt_lines"
## Matching-file count past which a multi-file search result becomes a per-file overview.
const SEARCH_OVERVIEW_FILES := "gdllm/tool_output/search_overview_file_threshold"
## Function names per overview line.
const SEARCH_OVERVIEW_FUNCS := "gdllm/tool_output/search_overview_function_names"
## The universal suggestion-list cap: near-miss names on a failed class/setting/file lookup, and the per-list entries in the editor-selection report.
const SUGGESTION_LIST_CAP := "gdllm/tool_output/suggestion_list_cap"
## Most referencing files named individually before the rest are summarized — by the automatic cross-file check after an edit, and by a rename/move/delete refusal's still-referencing list — so a hub-class rename doesn't flood the context.
const DEPENDENT_MENTIONS_CAP := "gdllm/tool_output/dependent_mentions_cap"
## list_directory's row cap; an explicit "full" ask waives it.
const LIST_DIRECTORY_MAX_ROWS := "gdllm/tool_output/list_directory_max_rows"
## The most dependency/user lines one list_dependencies result prints before collapsing the rest.
const DEPENDENCY_LINES_CAP := "gdllm/tool_output/dependency_lines_cap"
## The most output lines a run_script result relays — more generous than the console default because a subprocess's dropped output has nowhere else to live.
const RUN_SCRIPT_OUTPUT_LINES := "gdllm/tool_output/run_script_output_lines"
## Default line tail read_output returns; an explicit lines ask is uncapped.
const CONSOLE_OUTPUT_LINES := "gdllm/tool_output/console_default_output_lines"
## Default entry count read_errors returns; an explicit limit ask is uncapped.
const CONSOLE_ERROR_ENTRIES := "gdllm/tool_output/console_default_error_entries"
## Longest single relayed console line; the remainder is elided with a count so one runaway line can't flood the context.
const CONSOLE_LINE_MAX_CHARS := "gdllm/tool_output/console_line_max_chars"
## Most detail rows (engine error, source line, stack frames) relayed per error entry.
const CONSOLE_ERROR_DETAIL_ROWS := "gdllm/tool_output/console_error_detail_rows"
## The most members one describe_class section prints before truncating with a filter hint; base classes like Node have hundreds.
const CLASS_MEMBERS_PER_SECTION := "gdllm/tool_output/class_members_per_section"
## The most tree lines one describe_scene result prints before collapsing the rest.
const SCENE_TREE_MAX_NODES := "gdllm/tool_output/scene_tree_max_nodes"
## The most property lines one node's detail shows.
const SCENE_NODE_MAX_PROPERTIES := "gdllm/tool_output/scene_node_max_properties"
## The most connection lines one node's detail shows.
const SCENE_NODE_MAX_CONNECTIONS := "gdllm/tool_output/scene_node_max_connections"
## Longest a rendered value runs before an ellipsis — a scene property, a debugger variable, an animation key — so a packed array or long text never floods a result.
const RENDERED_VALUE_MAX_CHARS := "gdllm/tool_output/rendered_value_max_chars"
## Longest a browsed value runs before it is clipped — a project setting's value (printed whole on an exact-name lookup), a script constant (whose clip note points at read_file instead).
const BROWSE_VALUE_MAX_CHARS := "gdllm/tool_output/browse_value_max_chars"
## Most changed lines an edit confirmation echoes before the middle is counted instead; the replacement already sits in the conversation as the call's own arguments.
const EDIT_EXCERPT_MAX_CHANGED_LINES := "gdllm/tool_output/edit_excerpt_max_changed_lines"
## Lines of context shown on each side of the changed region in an edit confirmation.
const EDIT_EXCERPT_CONTEXT_LINES := "gdllm/tool_output/edit_excerpt_context_lines"
## The most located errors a validation report shows with an excerpt, so a badly broken file doesn't flood the result.
const EDIT_ERROR_EXCERPTS := "gdllm/tool_output/edit_error_excerpts"
## Cap on the child-output line quoted into a dead validation run's why — one line names the cause without spilling an error cascade.
const CHECK_DEATH_TAIL_CHARS := "gdllm/tool_output/check_death_tail_chars"
## Whole-result prose cap for describe_docs, applied once at the result's exit (never per block, which could stack past any budget); a runaway report is truncated with a pointer instead of flooding the context.
const DOCS_PROSE_MAX_CHARS := "gdllm/tool_output/docs_prose_max_chars"
## search_docs' result cap, kept small so a search maps the docs rather than dumping prose.
const DOCS_SEARCH_MAX_HITS := "gdllm/tool_output/docs_search_max_hits"
## Per-hit snippet window length in search_docs results.
const DOCS_SNIPPET_CHARS := "gdllm/tool_output/docs_snippet_chars"
## Most values one enum prints before the rest are counted and filter is named; @GlobalScope's Key alone has 193.
const DOCS_ENUM_VALUES_CAP := "gdllm/tool_output/docs_enum_values_cap"
## Settings shown for one describe_project prefix filter before a counted remainder.
const PROJECT_FILTER_RESULTS_CAP := "gdllm/tool_output/project_filter_results_cap"
## Most import settings rendered before the rest collapse to a count; a texture importer alone declares ~26.
const IMPORT_PARAMS_LISTED_CAP := "gdllm/tool_output/import_params_listed_cap"
## Longest fallback skill description taken from a skill's first body line when its frontmatter declares none.
const SKILL_FALLBACK_DESCRIPTION_CHARS := "gdllm/tool_output/skill_fallback_description_chars"
## Keys listed per animation track before the rest collapse and the window lever is named.
const ANIMATION_KEYS_LISTED_CAP := "gdllm/tool_output/animation_keys_listed_cap"
## Animations listed per player before the rest collapse to a count.
const ANIMATION_ANIMATIONS_LISTED_CAP := "gdllm/tool_output/animation_animations_listed_cap"
## Tracks rendered per zoomed animation before the rest collapse to a count.
const ANIMATION_TRACKS_LISTED_CAP := "gdllm/tool_output/animation_tracks_listed_cap"
## Cell area past which a tilemap grid render is withheld and the rect window named instead; a grid is roughly one character per cell.
const TILEMAP_GRID_CELL_CAP := "gdllm/tool_output/tilemap_grid_cell_cap"
## Layer names any tilemap listing prints before the rest collapse to a count — the empty-layers line and the which-layer disambiguation listings alike.
const TILEMAP_LAYERS_LISTED_CAP := "gdllm/tool_output/tilemap_layers_listed_cap"
## Sources listed per TileSet before the rest collapse to a count.
const TILEMAP_SOURCES_LISTED_CAP := "gdllm/tool_output/tilemap_sources_listed_cap"
## Per-source entries on one layer's tiles line (and atlas coords per tile list) before the rest collapse to a count.
const TILEMAP_SOURCES_PER_LINE_CAP := "gdllm/tool_output/tilemap_sources_per_line_cap"
## Scene paths listed for one scenes-collection source before the rest collapse to a count.
const TILEMAP_SCENE_TILES_LISTED_CAP := "gdllm/tool_output/tilemap_scene_tiles_listed_cap"
## Stack frames listed in a break report before the deeper remainder is counted.
const DEBUGGER_STACK_FRAMES_CAP := "gdllm/tool_output/debugger_stack_frames_cap"
## Variables printed across a break report's locals, members, and globals.
const DEBUGGER_VARIABLES_CAP := "gdllm/tool_output/debugger_variables_cap"
## The most function/category rows one profile report relays before pointing at the Profiler tab for the rest.
const PERF_PROFILE_FUNCTION_ROWS := "gdllm/tool_output/profile_function_rows"
## The most render-pass rows a visual profile relays — higher than the function cap because the passes are a tree whose leaves carry the cost.
const PERF_PROFILE_VISUAL_ROWS := "gdllm/tool_output/profile_visual_rows"
## The most per-node rows a network profile relays from each of the Network Profiler's two tables.
const PERF_PROFILE_NETWORK_ROWS := "gdllm/tool_output/profile_network_rows"
## read_video_ram's default row count.
const VRAM_DEFAULT_ROWS := "gdllm/tool_output/video_ram_default_rows"
## Hard clamp on a caller-supplied read_video_ram limit.
const VRAM_MAX_ROWS := "gdllm/tool_output/video_ram_max_rows"
## read_undo_history's default window of recent actions per history.
const UNDO_HISTORY_DEFAULT_WINDOW := "gdllm/tool_output/undo_history_default_window"
## Cap on a requested undo-history window, so a history of user actions never dumps whole.
const UNDO_HISTORY_MAX_WINDOW := "gdllm/tool_output/undo_history_max_window"

# --- gdllm/tool_runtime — how long a tool may run, wait, or reach ---

## run_game's default capture window (seconds): boot plus first frames.
const RUN_GAME_DEFAULT_WAIT := "gdllm/tool_runtime/run_game_default_wait_seconds"
## Cap on a requested capture window, so one call can't park the tool loop for minutes.
const RUN_GAME_MAX_WAIT := "gdllm/tool_runtime/run_game_max_wait_seconds"
## run_script's default wall-clock timeout (seconds).
const RUN_SCRIPT_DEFAULT_TIMEOUT := "gdllm/tool_runtime/run_script_default_timeout_seconds"
## Cap on a requested run_script timeout; the model may raise the default up to this, since a legitimate script can compute longer.
const RUN_SCRIPT_MAX_TIMEOUT := "gdllm/tool_runtime/run_script_max_timeout_seconds"
## profile_game's default sampling window (seconds).
const PROFILE_GAME_DEFAULT_SECONDS := "gdllm/tool_runtime/profile_game_default_seconds"
## Cap on a requested profiling window.
const PROFILE_GAME_MAX_SECONDS := "gdllm/tool_runtime/profile_game_max_seconds"
## The most frames one suspend_game call may advance, so stepping stays a bounded look rather than an unattended run.
const SUSPEND_MAX_FRAMES := "gdllm/tool_runtime/suspend_max_frames"
## One suspend_game call's whole wall-clock budget (ms) for frame stepping before it reports partial progress.
const SUSPEND_STEP_BUDGET_MS := "gdllm/tool_runtime/suspend_step_budget_ms"
## Cap on how many changed scripts one reload_game_scripts pushes before the list is refused as too broad to be a targeted fix.
const RELOAD_MAX_FILES := "gdllm/tool_runtime/reload_max_files"
## Wall-clock cap (ms) on one headless validation subprocess; an unbounded wait there freezes the whole editor.
const ENGINE_CHECK_TIMEOUT_MS := "gdllm/tool_runtime/engine_check_timeout_ms"
## How long (ms) a game-agent presence probe may take before an agent-less run is refused.
const GAME_PING_TIMEOUT_MS := "gdllm/tool_runtime/game_ping_timeout_ms"
## How long (ms) a break report waits for the stack and variables to land before answering with what it has; probe-measured 48-173 ms behind the break.
const DEBUGGER_STACK_SETTLE_MS := "gdllm/tool_runtime/debugger_stack_settle_ms"
## The most steps one debug_game call may take, so a stepping run stays one bounded tool round; each step can wait up to BREAK_ADVANCE_TIMEOUT_MS plus DEBUGGER_STACK_SETTLE_MS, and the whole call is additionally bounded by DEBUG_GAME_STEP_BUDGET_MS.
const DEBUG_GAME_MAX_STEPS := "gdllm/tool_runtime/debug_game_max_steps"
## One debug_game call's whole wall-clock stepping budget (ms) — the debug counterpart to SUSPEND_STEP_BUDGET_MS; running out reports the presses that landed rather than pressing on.
const DEBUG_GAME_STEP_BUDGET_MS := "gdllm/tool_runtime/debug_game_step_budget_ms"
## Seconds of monitor history kept per debugger session (the stream arrives about once per second), and so also the widest read_performance window.
const PERF_HISTORY_SECONDS := "gdllm/tool_runtime/performance_history_seconds"
## read_performance's default summary window (seconds).
const PERF_DEFAULT_WINDOW_SECONDS := "gdllm/tool_runtime/performance_default_window_seconds"
## Most clicked-control records kept per session; the spec's floor matches one input sequence's step cap (GDLLMGameProtocol.MAX_STEPS), so a sequence's own clicks can never fall off its own report.
const CLICK_RECORD_CAP := "gdllm/tool_runtime/click_record_cap"
## How long after launch the editor may report no playing scene before run_game calls the launch failed, rather than mistaking slow boot for an instant crash.
const RUN_GAME_LAUNCH_GRACE_MS := "gdllm/tool_runtime/run_game_launch_grace_ms"
## Poll interval (ms) between checks that a suspend_game stepped frame has landed.
const SUSPEND_FRAME_SETTLE_MS := "gdllm/tool_runtime/suspend_frame_settle_ms"
## How long (ms) the console is given to catch up before a capture reads it — after a suspend_game stepped frame, and after a reload_game_scripts push, which runs at the game's own pace the same way.
const SUSPEND_OUTPUT_SETTLE_MS := "gdllm/tool_runtime/suspend_output_settle_ms"
## How much longer (ms) than the input sequence itself the editor waits for send_game_input's reply before reporting it unanswered.
const GAME_REPLY_MARGIN_MS := "gdllm/tool_runtime/game_reply_margin_ms"
## Flat wait (ms) for a game command's reply — snapshots, method calls, and suspend_game's frame-confirmation pings — before an unanswered command is reported instead of parked on.
const GAME_REPLY_TIMEOUT_MS := "gdllm/tool_runtime/game_reply_timeout_ms"
## How long (ms) one debugger step press may take to land the next break before the result reports that the game ran on.
const BREAK_ADVANCE_TIMEOUT_MS := "gdllm/tool_runtime/break_advance_timeout_ms"
## The shorter window (ms) a resume is watched for an immediate second break.
const BREAK_CONTINUE_WATCH_MS := "gdllm/tool_runtime/break_continue_watch_ms"
## How many frames the script editor is given to build the text control whose gutter carries a breakpoint.
const BREAK_EDITOR_FRAMES := "gdllm/tool_runtime/break_editor_frames"
## How long (ms) a Video RAM refresh waits for the game's reply before reporting that it never answered, rather than passing the tab's previous list off as current.
const VRAM_REPLY_TIMEOUT_MS := "gdllm/tool_runtime/video_ram_reply_timeout_ms"
## How long (ms) send_game_input waits for clicked-control records still short of the pointer steps played; the game drains these at about one per second (probe-measured), so the default covers the dominant one-or-two-click case.
const CLICK_RECORD_SETTLE_MS := "gdllm/tool_runtime/click_record_settle_ms"
## Explicit cells per edit_tilemap set/erase call — a bulk shape belongs to fill/replace, and arguments are permanent history.
const TILEMAP_MAX_SET_CELLS := "gdllm/tool_runtime/tilemap_max_set_cells"
## Rect area cap for edit_tilemap's fill/erase/terrain rects.
const TILEMAP_MAX_FILL_AREA := "gdllm/tool_runtime/tilemap_max_fill_area"
## Terrain cells per edit_tilemap call — each is an engine matching step.
const TILEMAP_MAX_TERRAIN_CELLS := "gdllm/tool_runtime/tilemap_max_terrain_cells"

## Every tunable's spec, keyed by its setting path: the shipped default (its former hardcoded value — an int spec registers as an integer spinbox, a float default as a float one), the range the settings dialog offers and geti/getf clamp into, the spinbox step, and or_greater where a larger typed-in value is legitimate. An optional capped_by names a sibling key whose value bounds this one at read time — the default/max pairs and the meter's warning/danger pair, so an inconsistently set pair behaves (and is quoted by fill()) as the max-side value rather than a contradiction. GDLLMSettings.register() defines the whole set from this map, and GDLLMSettingsHelp explains each key — so adding a tunable is one const, one entry here, and one description there.
const SPECS := {
	STREAM_CONNECT_TIMEOUT: {"default": 15.0, "min": 1.0, "max": 120.0, "step": 0.5, "or_greater": true},
	MODEL_FETCH_TIMEOUT: {"default": 12.0, "min": 1.0, "max": 120.0, "step": 0.5, "or_greater": true},
	ANTHROPIC_MAX_TOKENS_FALLBACK: {"default": 64000, "min": 1000, "max": 200000, "step": 1000, "or_greater": true},
	ANTHROPIC_COMPLETION_MAX_TOKENS: {"default": 8192, "min": 256, "max": 64000, "step": 256},
	CHARS_PER_TOKEN: {"default": 4.0, "min": 1.0, "max": 10.0, "step": 0.1},
	CONTEXT_METER_WARNING_PERCENT: {"default": 50, "min": 1, "max": 100, "step": 1, "capped_by": CONTEXT_METER_DANGER_PERCENT},
	CONTEXT_METER_DANGER_PERCENT: {"default": 80, "min": 1, "max": 100, "step": 1},
	TOOL_SEARCH_MAX_RESULTS: {"default": 5, "min": 1, "max": 20, "step": 1},
	SCHEMA_RETIRE_IDLE_TURNS: {"default": 4, "min": 1, "max": 50, "step": 1, "or_greater": true},
	MAX_ATTACHED_SCENE_NODES: {"default": 20, "min": 1, "max": 100, "step": 1, "or_greater": true},
	SUMMARY_MIN_HEAD_TOKENS: {"default": 4000, "min": 0, "max": 65536, "step": 500, "or_greater": true},
	SUMMARY_OUTPUT_RESERVE_TOKENS: {"default": 4000, "min": 0, "max": 65536, "step": 500, "or_greater": true},
	SUMMARY_FAILURE_BREAKER: {"default": 3, "min": 1, "max": 10, "step": 1, "or_greater": true},
	SUMMARY_FIT_ATTEMPTS: {"default": 3, "min": 1, "max": 10, "step": 1},
	SUMMARY_FIT_MARGIN_PERCENT: {"default": 90, "min": 50, "max": 99, "step": 1},
	SUMMARY_TARGET_RESERVE_PERCENT: {"default": 25, "min": 5, "max": 90, "step": 1},
	PRUNE_KEEP_RECENT_PAIRS: {"default": 3, "min": 0, "max": 20, "step": 1, "or_greater": true},
	WITHHELD_ESCALATION_THRESHOLD: {"default": 4, "min": 1, "max": 20, "step": 1, "or_greater": true},
	BROKEN_REMINDER_COOLDOWN: {"default": 2, "min": 0, "max": 20, "step": 1},
	SESSION_TITLE_MAX_CHARS: {"default": 48, "min": 10, "max": 200, "step": 1},
	SESSION_SAVE_DEBOUNCE_SECONDS: {"default": 0.75, "min": 0.0, "max": 10.0, "step": 0.05},
	REPLAY_FRAME_BUDGET_MS: {"default": 8, "min": 1, "max": 100, "step": 1},
	READ_FILE_SUMMARY_THRESHOLD: {"default": 12000, "min": 0, "max": 100000, "step": 1000, "or_greater": true},
	PACKED_ARRAY_ELIDE_CHARS: {"default": 128, "min": 0, "max": 10000, "step": 16, "or_greater": true},
	SEARCH_CONTEXT_LINES: {"default": 3, "min": 0, "max": 20, "step": 1},
	SEARCH_MAX_BLOCKS: {"default": 40, "min": 1, "max": 200, "step": 1, "or_greater": true},
	SEARCH_MAX_FUNCTION_LINES: {"default": 30, "min": 1, "max": 200, "step": 1, "or_greater": true},
	SEARCH_OVERVIEW_FILES: {"default": 10, "min": 1, "max": 100, "step": 1},
	SEARCH_OVERVIEW_FUNCS: {"default": 6, "min": 1, "max": 40, "step": 1},
	SUGGESTION_LIST_CAP: {"default": 12, "min": 1, "max": 50, "step": 1},
	DEPENDENT_MENTIONS_CAP: {"default": 12, "min": 1, "max": 50, "step": 1},
	LIST_DIRECTORY_MAX_ROWS: {"default": 200, "min": 10, "max": 2000, "step": 10, "or_greater": true},
	DEPENDENCY_LINES_CAP: {"default": 40, "min": 1, "max": 200, "step": 1, "or_greater": true},
	RUN_SCRIPT_OUTPUT_LINES: {"default": 80, "min": 10, "max": 1000, "step": 10, "or_greater": true},
	CONSOLE_OUTPUT_LINES: {"default": 40, "min": 1, "max": 500, "step": 1, "or_greater": true},
	CONSOLE_ERROR_ENTRIES: {"default": 10, "min": 1, "max": 100, "step": 1, "or_greater": true},
	CONSOLE_LINE_MAX_CHARS: {"default": 400, "min": 40, "max": 4000, "step": 20, "or_greater": true},
	CONSOLE_ERROR_DETAIL_ROWS: {"default": 12, "min": 1, "max": 50, "step": 1},
	CLASS_MEMBERS_PER_SECTION: {"default": 80, "min": 10, "max": 500, "step": 10, "or_greater": true},
	SCENE_TREE_MAX_NODES: {"default": 150, "min": 10, "max": 1000, "step": 10, "or_greater": true},
	SCENE_NODE_MAX_PROPERTIES: {"default": 40, "min": 5, "max": 200, "step": 5, "or_greater": true},
	SCENE_NODE_MAX_CONNECTIONS: {"default": 30, "min": 5, "max": 200, "step": 5, "or_greater": true},
	RENDERED_VALUE_MAX_CHARS: {"default": 120, "min": 20, "max": 2000, "step": 10, "or_greater": true},
	BROWSE_VALUE_MAX_CHARS: {"default": 160, "min": 20, "max": 2000, "step": 10, "or_greater": true},
	EDIT_EXCERPT_MAX_CHANGED_LINES: {"default": 20, "min": 2, "max": 200, "step": 1},
	EDIT_EXCERPT_CONTEXT_LINES: {"default": 1, "min": 0, "max": 10, "step": 1},
	EDIT_ERROR_EXCERPTS: {"default": 3, "min": 1, "max": 20, "step": 1},
	CHECK_DEATH_TAIL_CHARS: {"default": 200, "min": 40, "max": 1000, "step": 10},
	DOCS_PROSE_MAX_CHARS: {"default": 6000, "min": 500, "max": 50000, "step": 500, "or_greater": true},
	DOCS_SEARCH_MAX_HITS: {"default": 12, "min": 1, "max": 50, "step": 1},
	DOCS_SNIPPET_CHARS: {"default": 160, "min": 40, "max": 1000, "step": 10},
	DOCS_ENUM_VALUES_CAP: {"default": 24, "min": 4, "max": 200, "step": 1},
	PROJECT_FILTER_RESULTS_CAP: {"default": 60, "min": 5, "max": 500, "step": 5, "or_greater": true},
	IMPORT_PARAMS_LISTED_CAP: {"default": 40, "min": 5, "max": 200, "step": 5},
	SKILL_FALLBACK_DESCRIPTION_CHARS: {"default": 120, "min": 20, "max": 500, "step": 10},
	ANIMATION_KEYS_LISTED_CAP: {"default": 24, "min": 4, "max": 200, "step": 1},
	ANIMATION_ANIMATIONS_LISTED_CAP: {"default": 40, "min": 4, "max": 200, "step": 1},
	ANIMATION_TRACKS_LISTED_CAP: {"default": 40, "min": 4, "max": 200, "step": 1},
	TILEMAP_GRID_CELL_CAP: {"default": 4000, "min": 100, "max": 100000, "step": 100, "or_greater": true},
	TILEMAP_LAYERS_LISTED_CAP: {"default": 24, "min": 4, "max": 200, "step": 1},
	TILEMAP_SOURCES_LISTED_CAP: {"default": 40, "min": 4, "max": 200, "step": 1},
	TILEMAP_SOURCES_PER_LINE_CAP: {"default": 12, "min": 2, "max": 50, "step": 1},
	TILEMAP_SCENE_TILES_LISTED_CAP: {"default": 12, "min": 2, "max": 50, "step": 1},
	DEBUGGER_STACK_FRAMES_CAP: {"default": 12, "min": 1, "max": 100, "step": 1},
	DEBUGGER_VARIABLES_CAP: {"default": 30, "min": 5, "max": 200, "step": 5},
	PERF_PROFILE_FUNCTION_ROWS: {"default": 20, "min": 5, "max": 200, "step": 5, "or_greater": true},
	PERF_PROFILE_VISUAL_ROWS: {"default": 40, "min": 5, "max": 200, "step": 5, "or_greater": true},
	PERF_PROFILE_NETWORK_ROWS: {"default": 20, "min": 5, "max": 200, "step": 5, "or_greater": true},
	VRAM_DEFAULT_ROWS: {"default": 20, "min": 5, "max": 100, "step": 5, "capped_by": VRAM_MAX_ROWS},
	VRAM_MAX_ROWS: {"default": 100, "min": 10, "max": 1000, "step": 10, "or_greater": true},
	UNDO_HISTORY_DEFAULT_WINDOW: {"default": 15, "min": 1, "max": 100, "step": 1, "capped_by": UNDO_HISTORY_MAX_WINDOW},
	UNDO_HISTORY_MAX_WINDOW: {"default": 100, "min": 10, "max": 1000, "step": 10, "or_greater": true},
	RUN_GAME_DEFAULT_WAIT: {"default": 6, "min": 1, "max": 60, "step": 1, "capped_by": RUN_GAME_MAX_WAIT},
	RUN_GAME_MAX_WAIT: {"default": 30, "min": 5, "max": 600, "step": 5, "or_greater": true},
	RUN_SCRIPT_DEFAULT_TIMEOUT: {"default": 30, "min": 5, "max": 600, "step": 5, "capped_by": RUN_SCRIPT_MAX_TIMEOUT},
	RUN_SCRIPT_MAX_TIMEOUT: {"default": 120, "min": 10, "max": 3600, "step": 10, "or_greater": true},
	PROFILE_GAME_DEFAULT_SECONDS: {"default": 6, "min": 1, "max": 60, "step": 1, "capped_by": PROFILE_GAME_MAX_SECONDS},
	PROFILE_GAME_MAX_SECONDS: {"default": 30, "min": 5, "max": 600, "step": 5, "or_greater": true},
	SUSPEND_MAX_FRAMES: {"default": 30, "min": 1, "max": 600, "step": 1, "or_greater": true},
	SUSPEND_STEP_BUDGET_MS: {"default": 12000, "min": 1000, "max": 60000, "step": 500, "or_greater": true},
	RELOAD_MAX_FILES: {"default": 40, "min": 1, "max": 500, "step": 1, "or_greater": true},
	ENGINE_CHECK_TIMEOUT_MS: {"default": 15000, "min": 1000, "max": 120000, "step": 500, "or_greater": true},
	GAME_PING_TIMEOUT_MS: {"default": 600, "min": 100, "max": 10000, "step": 50, "or_greater": true},
	DEBUGGER_STACK_SETTLE_MS: {"default": 1200, "min": 100, "max": 10000, "step": 50, "or_greater": true},
	DEBUG_GAME_MAX_STEPS: {"default": 10, "min": 1, "max": 30, "step": 1},
	DEBUG_GAME_STEP_BUDGET_MS: {"default": 20000, "min": 2000, "max": 120000, "step": 500, "or_greater": true},
	PERF_DEFAULT_WINDOW_SECONDS: {"default": 30, "min": 5, "max": 600, "step": 5, "capped_by": PERF_HISTORY_SECONDS},
	PERF_HISTORY_SECONDS: {"default": 180, "min": 30, "max": 3600, "step": 10, "or_greater": true},
	CLICK_RECORD_CAP: {"default": 40, "min": 20, "max": 500, "step": 5},
	RUN_GAME_LAUNCH_GRACE_MS: {"default": 2000, "min": 500, "max": 10000, "step": 100, "or_greater": true},
	SUSPEND_FRAME_SETTLE_MS: {"default": 40, "min": 10, "max": 500, "step": 10},
	SUSPEND_OUTPUT_SETTLE_MS: {"default": 1500, "min": 100, "max": 10000, "step": 100},
	GAME_REPLY_MARGIN_MS: {"default": 4000, "min": 500, "max": 30000, "step": 250, "or_greater": true},
	GAME_REPLY_TIMEOUT_MS: {"default": 4000, "min": 500, "max": 30000, "step": 250, "or_greater": true},
	BREAK_ADVANCE_TIMEOUT_MS: {"default": 4000, "min": 500, "max": 30000, "step": 250, "or_greater": true},
	BREAK_CONTINUE_WATCH_MS: {"default": 1500, "min": 100, "max": 10000, "step": 100},
	BREAK_EDITOR_FRAMES: {"default": 20, "min": 5, "max": 200, "step": 1},
	VRAM_REPLY_TIMEOUT_MS: {"default": 4000, "min": 500, "max": 30000, "step": 250, "or_greater": true},
	CLICK_RECORD_SETTLE_MS: {"default": 1600, "min": 200, "max": 10000, "step": 100},
	TILEMAP_MAX_SET_CELLS: {"default": 200, "min": 10, "max": 2000, "step": 10, "or_greater": true},
	TILEMAP_MAX_FILL_AREA: {"default": 10000, "min": 100, "max": 100000, "step": 100, "or_greater": true},
	TILEMAP_MAX_TERRAIN_CELLS: {"default": 200, "min": 10, "max": 2000, "step": 10, "or_greater": true},
}

## Tail-of-key → full key, built lazily for fill(); the tails are unique by construction (see SPECS).
static var _fill_index: Dictionary = {}


## The tunable's current integer value: the user's setting when one is stored, clamped into the spec's range (below min → min; above max → max unless the spec says or_greater), else the shipped default — which is also the answer for a headless --script run, so the suites always see the shipped numbers (the GDLLMColors precedent).
static func geti(key: String) -> int:
	return int(_value(key))


## The float counterpart to geti, for the ratio/seconds tunables whose defaults are floats.
static func getf(key: String) -> float:
	return float(_value(key))


static func _value(key: String) -> Variant:
	if not SPECS.has(key):
		push_error("GDLLMTunables: no tunable named \"%s\" — pass one of GDLLMTunables' key constants (SPECS lists every registered tunable)." % key)
		return 0
	var spec: Dictionary = SPECS[key]
	if not Engine.is_editor_hint():
		# Headless answers are the shipped defaults, with the pair cap still applied — tunables_test asserts every pair's defaults are already consistent, so the cap is provably a no-op here, and this line keeps that true by construction rather than by luck.
		return _resolve(spec, spec["default"], _value(spec["capped_by"]) if spec.has("capped_by") else null)
	var es := EditorInterface.get_editor_settings()
	var stored: Variant = es.get_setting(key) if es != null and es.has_setting(key) else spec["default"]
	# The sibling resolves through _value so its own range clamp applies first; sibling specs carry no capped_by of their own, so this recurses at most once.
	return _resolve(spec, stored, _value(spec["capped_by"]) if spec.has("capped_by") else null)


## The pure resolution rule behind _value, split out so the suites can drive it with synthetic stored/bound values (nothing here touches the editor): garbage resolves to the shipped default, a numeric value clamps into the spec's range (below min → min; above max → max unless or_greater), and the result caps at `bound` — the already-resolved value of a capped_by sibling, or null when the spec has none — so an inconsistently set pair behaves, and is quoted by fill(), as the bounding side rather than a contradiction.
static func _resolve(spec: Dictionary, stored: Variant, bound: Variant) -> Variant:
	# Garbage in, default out: a hand-edited settings file can hold anything — a string, null, nan, inf — and a non-numeric or non-finite value must fall to the default here rather than leak into comparisons whose NaN answers are all false (inf would likewise ride or_greater unbounded).
	if not (stored is int or stored is float) or not is_finite(float(stored)):
		stored = spec["default"]
	if float(stored) < float(spec["min"]):
		stored = spec["min"]
	elif not bool(spec.get("or_greater", false)) and float(stored) > float(spec["max"]):
		stored = spec["max"]
	if bound != null and float(stored) > float(bound):
		return bound
	return stored


## The "min,max,step[,or_greater]" range-hint string PROPERTY_HINT_RANGE takes, built from `spec` for GDLLMSettings.register().
static func range_hint(spec: Dictionary) -> String:
	var hint := "%s,%s,%s" % [spec["min"], spec["max"], spec["step"]]
	if bool(spec.get("or_greater", false)):
		hint += ",or_greater"
	return hint


## `text` with every "{tunable:<key tail>}" token replaced by that tunable's current value, so tool descriptions and usage lines quote the numbers actually in force rather than defaults frozen into their consts (see GDLLMTools._schema and the *_USAGE call sites). An unknown tail is left in place — a visible bug beats a silent blank. A token only renders on a serve path that calls fill() — most usage reminders reach the model through _unexpected_arg_error, which fills, but some constants are concatenated raw — so before adding a token to a constant, confirm its serve site fills (tunables_test verifies tokens RESOLVE, not that every path fills).
static func fill(text: String) -> String:
	if not text.contains("{tunable:"):
		return text
	if _fill_index.is_empty():
		for key: String in SPECS:
			_fill_index[String(key).get_slice("/", 2)] = key
	var out := text
	var start := out.find("{tunable:")
	while start != -1:
		var end := out.find("}", start)
		if end == -1:
			break
		var tail := out.substr(start + 9, end - start - 9)
		if _fill_index.has(tail):
			out = out.left(start) + str(_value(_fill_index[tail])) + out.substr(end + 1)
		else:
			push_error("GDLLMTunables: fill() found no tunable whose key ends in \"%s\" — the token stays visible in the text; fix the token or add the tunable to SPECS." % tail)
			start = end
		start = out.find("{tunable:", start + 1)
	return out
