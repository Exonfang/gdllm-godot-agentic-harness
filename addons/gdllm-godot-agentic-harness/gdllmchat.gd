@tool
class_name GDLLMChatDock extends VBoxContainer
## Dockable multi-session chat panel. Registered via `add_control_to_dock`, so it can be dragged to any dock slot. Each session is a tab inside a TabContainer; the header carries a session dropdown, a New-session button, and a Manage button. Sessions persist per-project via GDLLMSessionStore, and each session's first message is summarized into a title by the Tasks Model.

const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const MANAGE_COL_DELETE := 11 ## Column in the manage table holding each row's trash button.
const MANAGE_RESIZE_MARGIN := 5.0 ## Half-width in px of the grab zone around a column boundary in the manage table's title strip.
const MANAGE_COL_MIN_WIDTH := 40 ## Narrowest a manage-table column can be drag-resized down to.
const CONNECTION_TOGGLE_WIDTH := 34 ## Fixed width of the Connections dialog's per-source enabled column; the header label and each row's checkbox share it so columns line up (mirrors the delete button's 34px).
## Per-kind guidance for the Connections dialog's URL field — placeholder for a blank field, tooltip for a filled one. The field takes the URL the provider's own UI hands out, full endpoint or bare base alike (each adapter derives its routes from the server root; see LLMAdapter._root_from_endpoint), so the guidance shows the form users actually copy.
const CONNECTION_BASE_URL_HINTS := {
	GDLLMSources.KIND_OLLAMA: {
		"placeholder": "http://localhost:11434",
		"tooltip": "Paste the server's address. A bare host and port like http://localhost:11434, or a full endpoint like .../api/chat; every route is derived from the server root either way.",
	},
	GDLLMSources.KIND_OPENAI: {
		"placeholder": "http://localhost:1234/v1/chat/completions",
		"tooltip": "Paste the URL your server hands out, a full endpoint like http://localhost:1234/v1/chat/completions, a base ending in /v1, or a bare host and port (/v1 is then added automatically) all work.",
	},
	GDLLMSources.KIND_ANTHROPIC: {
		"placeholder": "https://api.anthropic.com",
		"tooltip": "Anthropic's endpoint is the same for everyone: https://api.anthropic.com — pasting the full …/v1/messages endpoint works too.",
	},
}
const EFFORT_LEVEL_COL_WIDTH := 62 ## Fixed width of each level column in the Effort Configuration table; the header label and each row's checkbox share it so columns line up, wide enough for "minimal".
const EFFORT_CACHE_COL_WIDTH := 84 ## Fixed width of the Effort Configuration table's cache-TTL column; the header label and each row's spinbox share it so the column lines up.
const EFFORT_CONTEXT_COL_WIDTH := 140 ## Fixed width of the Effort Configuration table's declared-context-window column; sized for an eight-digit token figure beside the spin arrows, so a millions-scale window never clips.
const COLOR_REPAINT_INTERVAL := 0.4 ## Seconds one palette repaint holds off the next; the settings dialog's color picker writes on every drag tick and each repaint rebuilds every open log (see _schedule_color_repaint).

var _store: GDLLMSessionStore ## Per-project roster + persistence.
var _tasks_client: LLMClient ## Shared client for background chores (title summarization).

var _open_sessions: Dictionary = {} ## session_id -> GDLLMChatSession currently shown as a tab.

var _models_sweeping: bool = false ## True while a source sweep is in flight, so a second Fetch click (or the boot sweep) can't stack a concurrent sweep.
var _suppress_tab_events: bool = false ## True while restoring tabs at startup, so tab_changed side-effects don't fire mid-build.
var _restored: bool = false ## The deferred boot restore has loaded the roster and rebuilt the tabs; until then the store is empty and must not be flushed or added to (an early write would clobber sessions.json).
var _tearing_down: bool = false ## True once the dock is being freed (see _commit_open_sessions); suppresses side effects the teardown unwind must not spawn.

## Single-in-flight FIFO of pending title jobs ({"id","text"}), so two sessions' first messages can't collide on the shared tasks client.
var _title_queue: Array[Dictionary] = []
var _title_busy: bool = false

var _editor_had_selection: bool = false ## Editor selection state at the last caret change; routed to the active session's "Attach selection".
var _selection_flips: Array = [] ## CodeEdits whose deselect_on_focus_loss_enabled this dock turned off, so plugin disable can hand the editor its own behavior back (see restore_editor_selection_behavior).

var _tabs: TabContainer
var _session_select: OptionButton ## Roster of every session (open or closed); selecting one opens/focuses its tab.
var _new_button: Button
var _manage_button: Button

var _connections_dialog: ConfirmationDialog ## Built lazily on first Connections press; edits the GDLLMSources list. Opened from the ⚙ button beside each session's model picker.
var _connections_rows_box: VBoxContainer ## Container the per-source edit rows are rebuilt into.
var _connection_rows: Array = [] ## One entry per row: {id, name_edit, kind_select, base_edit, key_edit, container}. `id` preserves an existing source's id so qualified model ids keep resolving; "" for a freshly added row.

var _effort_dialog: ConfirmationDialog ## Built lazily on first Effort-configuration press; edits the GDLLMEfforts per-model level map. Opened from the ⚡ button beside each session's model picker.
var _effort_rows_box: VBoxContainer ## Container the per-model level rows are rebuilt into.
var _effort_rows: Array = [] ## One entry per row: {qualified, checks: Dictionary (level -> CheckBox), cache_spin: SpinBox, container}.
var _effort_add_select: OptionButton ## Picker of Ollama-sourced models not yet in the table; choosing one appends its row (see _on_effort_add_selected).

var _favorites_dialog: ConfirmationDialog ## Built lazily on first Favorites press; edits the GDLLMFavorites ordered list. Opened from the ★ button beside each session's model picker.
var _favorites_rows_box: VBoxContainer ## Container the favorite rows are rebuilt into.
var _favorites_rows: Array = [] ## One entry per row, in display order: {qualified, container}.
var _favorites_add_select: OptionButton ## Picker of models not yet favorited; choosing one appends its row (see _on_favorites_add_selected).
var _last_favorites := "" ## Snapshot of the stored favorites JSON, so _on_editor_settings_changed rebuilds model pickers only on an actual favorites edit.
var _last_colors := "" ## Snapshot of the configured log palette, read the same way and for the same reason: repaint open logs only on an actual color edit.
var _color_repaint_pending := false ## True while a scheduled palette repaint is waiting out COLOR_REPAINT_INTERVAL, so a drag's every tick can't stack rebuilds.

var _manage_dialog: ConfirmationDialog ## Built lazily on first Manage press.
var _manage_tree: Tree ## Table of every session's stats (columns titled in _ensure_manage_dialog), with a per-row delete button.
var _manage_totals: Label ## Footer under the manage table aggregating tokens in/out across every session.
var _manage_resize_col := -1 ## Manage-table column being drag-resized by its right-edge boundary; -1 when idle.
var _manage_resize_start := 0.0 ## Mouse x where the active column drag began.
var _manage_resize_start_width := 0 ## The dragged column's width when the drag began.

var _confirm_dialog: ConfirmationDialog ## Reused "Are you sure?" interstitial guarding the destructive bulk-delete buttons; built lazily.
var _pending_confirm: Callable = Callable() ## Action to run if the user clicks through the interstitial; cleared once it fires.


func _init() -> void:
	# Set before the plugin adds us to a dock so the tab label reads correctly.
	name = "GDLLM"


func _ready() -> void:
	custom_minimum_size = Vector2(240, 0)
	_build_ui()

	_store = GDLLMSessionStore.new()
	_store.session_title_changed.connect(_on_session_title_changed)
	_store.store_failed.connect(_on_store_failed)

	_ensure_tasks_client()

	# Session restore is deferred past boot: _ready runs inside the plugin's _enter_tree, where parsing the roster and rebuilding tabs would hold up editor startup for as long as the stored histories take to load.
	_restore_sessions()

	# keep script-editor selections alive when focus moves away so "Attach selection" can read them. Reapplied only when a script is opened or switched.
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null and not script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		script_editor.editor_script_changed.connect(_on_editor_script_changed)
	_keep_editor_selections_alive()

	# mirror model/endpoint edits made on the settings page (see _on_editor_settings_changed)
	var editor_settings := EditorInterface.get_editor_settings()
	if not editor_settings.settings_changed.is_connected(_on_editor_settings_changed):
		editor_settings.settings_changed.connect(_on_editor_settings_changed)
	# Seed the favorites snapshot so the first unrelated settings_changed doesn't read as a favorites edit.
	_last_favorites = JSON.stringify(Array(GDLLMFavorites.get_list()))
	# Same for the palette snapshot, so no session is repainted over a settings write that left the colors alone.
	_last_colors = GDLLMColors.snapshot()


func _exit_tree() -> void:
	# Plugin disable or editor shutdown: land anything the store's save debounce is still holding. Never before the restore has run — flushing the still-unloaded (empty) roster would erase sessions.json.
	# Also reached by a mere reparent (dock drag to another slot, make-floating, layout apply), so live sessions must not be disturbed here — the mid-turn unwind waits for PREDELETE, which only a real free reaches.
	if _store != null and _restored:
		_store.flush()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_commit_open_sessions()


## Last chance before the dock is freed (plugin disable or editor shutdown): unwind any mid-turn session exactly like a tab close — the Stop path synchronously commits executed tool calls and the interruption notice — then flush, so the persisted roster can't miss work that already hit disk. The sessions are the dock's descendants, so they are still whole here.
func _commit_open_sessions() -> void:
	if _store == null or not _restored:
		return
	# Suppress the Stop path's title-task side effect: a request born during teardown could never settle.
	_tearing_down = true
	for session in _open_sessions.values():
		if is_instance_valid(session):
			session.abort_in_flight()
	_store.flush()


## Load the roster from disk and reopen its sessions, two frames after _ready — the first frame's work still lands before the editor's first paint, so waiting out both keeps boot free of the JSON parse. Each reopened tab defers its own history rendering until it is actually shown (see GDLLMChatSession._apply_record), so restoring many open sessions stays cheap here too.
func _restore_sessions() -> void:
	for i in 2:
		await get_tree().process_frame
	# The plugin was disabled during the wait; the freed store must not be touched (and nothing needs restoring).
	if not is_instance_valid(_tabs):
		return
	_store.load()
	# Restore previously-open sessions (or start one fresh), then wire the dropdown to match.
	_suppress_tab_events = true
	for record in _store.sessions:
		if bool(record.get("is_open", false)):
			_open_session(record)
	if _tabs.get_tab_count() == 0:
		_open_session(_store.create())
	_select_active_tab()
	_suppress_tab_events = false
	_rebuild_session_dropdown()
	_restored = true


## Ctrl+W (Cmd+W on macOS) closes the current session's tab, but only while focus is inside the dock — elsewhere the editor's own Close shortcuts keep working. Consumed even with no tab open, so the keypress can't fall through and close the user's script instead.
func _shortcut_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.is_echo():
		return
	if key.keycode != KEY_W or not key.is_command_or_control_pressed() or key.shift_pressed or key.alt_pressed:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus == null or not (focus == self or is_ancestor_of(focus)):
		return
	if _tabs.get_tab_count() > 0:
		_on_tab_close_pressed(_tabs.current_tab)
	get_viewport().set_input_as_handled()


func _build_ui() -> void:
	# --- Header: session dropdown + New + Manage ---
	var header := HBoxContainer.new()
	add_child(header)

	_session_select = OptionButton.new()
	_session_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Same guard as the session's model picker: a long session title must never set the dock's minimum width, or the editor's dock layout can hang at boot (see _build_ui in gdllm_chat_session.gd).
	_session_select.fit_to_longest_item = false
	_session_select.clip_text = true
	_session_select.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_session_select.tooltip_text = "Switch sessions. Selecting one opens or focuses its tab."
	_session_select.item_selected.connect(_on_session_dropdown_selected)
	header.add_child(_session_select)

	_new_button = Button.new()
	_new_button.text = "＋"
	_new_button.tooltip_text = "Start a new chat session."
	_new_button.pressed.connect(_on_new_pressed)
	header.add_child(_new_button)

	_manage_button = Button.new()
	_manage_button.text = "Manage"
	_manage_button.tooltip_text = "Manage sessions (delete)."
	_manage_button.pressed.connect(_on_manage_pressed)
	header.add_child(_manage_button)

	# --- Session tabs ---
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.drag_to_rearrange_enabled = true
	add_child(_tabs)

	var bar := _tabs.get_tab_bar()
	bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	bar.tab_close_pressed.connect(_on_tab_close_pressed)
	# tab_changed fires for both user clicks and programmatic selection, so the active session and dropdown stay in sync either way.
	_tabs.tab_changed.connect(_on_tab_changed)


func _ensure_tasks_client() -> void:
	if is_instance_valid(_tasks_client):
		return
	_tasks_client = LLMClient.new()
	add_child(_tasks_client)
	_tasks_client.response_received.connect(_on_tasks_response)
	_tasks_client.request_failed.connect(_on_tasks_request_failed)
	_tasks_client.configure_from(GDLLMSettings.get_tasks_source_and_model())


# --- Session lifecycle ---

## Open `record` as a tab (or focus its existing tab). Returns the session view.
func _open_session(record: Dictionary) -> GDLLMChatSession:
	var id := String(record.get("id", ""))
	if _open_sessions.has(id):
		return _open_sessions[id]

	var session := GDLLMChatSession.new()
	session.setup(record)
	session.first_user_message.connect(_on_first_user_message)
	session.history_changed.connect(_on_session_history_changed)
	session.model_changed.connect(_on_session_model_changed)
	session.make_changes_toggled.connect(_on_session_make_changes_toggled)
	session.delete_files_toggled.connect(_on_session_delete_files_toggled)
	session.tools_enabled_toggled.connect(_on_session_tools_enabled_toggled)
	session.effort_changed.connect(_on_session_effort_changed)
	session.connections_requested.connect(_on_connections_pressed) # the ⚙ beside its picker opens the shared dialog
	session.effort_config_requested.connect(_on_effort_config_pressed) # the ⚡ beside its picker opens the shared Effort Configuration dialog
	session.favorites_config_requested.connect(_on_favorites_config_pressed) # the ★ beside its picker opens the shared Favorite Models dialog
	session.models_refresh_requested.connect(_on_models_refresh_requested) # opening its picker re-sweeps sources so the list is current
	_tabs.add_child(session) # triggers the session's _ready (builds its UI; history rendering waits for the tab's first show)

	var idx := _tabs.get_tab_idx_from_control(session)
	_tabs.set_tab_title(idx, String(record.get("title", GDLLMSessionStore.DEFAULT_TITLE)))
	session.set_available_models(GDLLMSettings.get_available_models())

	_open_sessions[id] = session
	_store.set_open(id, true)
	return session


func _select_session_tab(session: GDLLMChatSession) -> void:
	var idx := _tabs.get_tab_idx_from_control(session)
	if idx != -1:
		_tabs.current_tab = idx


## Select the tab for the store's active session, falling back to the first tab, and keep the stored active id in step with whatever tab actually ends up shown.
func _select_active_tab() -> void:
	var target: GDLLMChatSession = null
	if _open_sessions.has(_store.active_id):
		target = _open_sessions[_store.active_id]
	elif _tabs.get_tab_count() > 0:
		target = _tabs.get_tab_control(0) as GDLLMChatSession
	if target != null:
		_select_session_tab(target)
		_store.set_active(target.session_id)


## The session view backing the currently visible tab, or null when there are no tabs.
func _active_session() -> GDLLMChatSession:
	if _tabs.get_tab_count() == 0:
		return null
	return _tabs.get_current_tab_control() as GDLLMChatSession


func _on_new_pressed() -> void:
	# A click in the two-frame window before the deferred restore would create into (and flush) the unloaded roster, clobbering the file.
	if not _restored:
		return
	var session := _open_session(_store.create())
	_select_session_tab(session)
	_rebuild_session_dropdown()


func _on_tab_close_pressed(tab: int) -> void:
	var session := _tabs.get_tab_control(tab) as GDLLMChatSession
	if session == null:
		return
	# Closing a tab hides the session but keeps its record — it stays in the dropdown and reopens with full history. A pristine one has no history to reopen, so its record is discarded outright instead of stranding another empty "New chat" in the roster.
	session.abort_in_flight() # unwind any in-flight request/tool coroutine before the free, so nothing resumes into a dead node
	if GDLLMSessionStore.is_pristine(_store.get_session(session.session_id)):
		_store.delete(session.session_id)
		_rebuild_session_dropdown()
	else:
		_store.set_open(session.session_id, false)
	_open_sessions.erase(session.session_id)
	session.queue_free()


func _on_tab_changed(tab: int) -> void:
	if _suppress_tab_events:
		return
	var session := _tabs.get_tab_control(tab) as GDLLMChatSession
	if session == null:
		return
	_store.set_active(session.session_id)
	_sync_dropdown_to_active(session.session_id)


func _on_session_dropdown_selected(index: int) -> void:
	var id := String(_session_select.get_item_metadata(index))
	if _open_sessions.has(id):
		_select_session_tab(_open_sessions[id])
		return
	var record := _store.get_session(id)
	if record.is_empty():
		return
	_select_session_tab(_open_session(record))


# --- Session dropdown ---

## Rebuild the dropdown from the full roster, keeping the active session selected.
## Iterates the roster newest-first so recent sessions sit at the top of the list.
func _rebuild_session_dropdown() -> void:
	_session_select.clear()
	var selected := -1
	for i in range(_store.sessions.size() - 1, -1, -1):
		var record := _store.sessions[i]
		var idx := _session_select.item_count
		_session_select.add_item(String(record.get("title", GDLLMSessionStore.DEFAULT_TITLE)))
		_session_select.set_item_metadata(idx, record["id"])
		if record["id"] == _store.active_id:
			selected = idx
	if selected != -1:
		_session_select.select(selected)


## Point the dropdown at `id` without firing item_selected (select() is silent).
func _sync_dropdown_to_active(id: String) -> void:
	for i in _session_select.item_count:
		if String(_session_select.get_item_metadata(i)) == id:
			_session_select.select(i)
			return


## Refresh the label of one session in the dropdown (used when its title is generated).
func _update_dropdown_title(id: String, title: String) -> void:
	for i in _session_select.item_count:
		if String(_session_select.get_item_metadata(i)) == id:
			_session_select.set_item_text(i, title)
			return


func _on_session_title_changed(id: String, title: String) -> void:
	if _open_sessions.has(id):
		var idx := _tabs.get_tab_idx_from_control(_open_sessions[id])
		if idx != -1:
			_tabs.set_tab_title(idx, title)
	_update_dropdown_title(id, title)


# --- Persistence hooks from sessions ---

func _on_session_history_changed(id: String) -> void:
	if _open_sessions.has(id):
		var session: GDLLMChatSession = _open_sessions[id]
		_store.set_history(id, session.get_history())


func _on_session_model_changed(id: String, model: String) -> void:
	_store.set_model(id, model)
	# Track the latest pick as the global default so the settings page and new sessions follow it.
	GDLLMSettings.set_chat_model(model)


## Persist one session's effort selection on its own record; per-session, like the model pick ("" = Default).
func _on_session_effort_changed(id: String, effort: String) -> void:
	_store.set_effort(id, effort)


## Persist one session's "Make changes" flip on its own record; per-session, so one chat can edit while another stays read-only.
func _on_session_make_changes_toggled(id: String, on: bool) -> void:
	_store.set_make_changes(id, on)


## Persist one session's "Delete files" flip on its own record, like _on_session_make_changes_toggled.
func _on_session_delete_files_toggled(id: String, on: bool) -> void:
	_store.set_delete_files(id, on)


## Persist one session's "Tools" flip on its own record, like _on_session_make_changes_toggled.
func _on_session_tools_enabled_toggled(id: String, on: bool) -> void:
	_store.set_tools_enabled(id, on)


# --- Title generation (Tasks Model) ---

func _on_first_user_message(id: String, text: String) -> void:
	if _tearing_down:
		return
	_title_queue.append({"id": id, "text": text})
	_process_title_queue()


## Send the next queued title job when the tasks client is free, opening the session's gray task panel first so the request is never silent (goal 2).
func _process_title_queue() -> void:
	if _title_busy or _title_queue.is_empty() or _tasks_client.is_busy():
		return
	_title_busy = true
	_tasks_client.configure_from(GDLLMSettings.get_tasks_source_and_model())
	var job: Dictionary = _title_queue[0]
	# Capture what actually leaves for the Tasks Model (and when), so the settle can persist the exchange even if the tab closes mid-run.
	job["model_label"] = GDLLMSources.label_for(GDLLMSettings.get_tasks_model())
	job["system"] = GDLLMSettings.get_tasks_system_prompt()
	job["started_ms"] = Time.get_ticks_msec()
	var session: GDLLMChatSession = _open_sessions.get(String(job["id"]))
	if is_instance_valid(session):
		session.begin_title_task(String(job["model_label"]), String(job["system"]), String(job["text"]))
	_tasks_client.send_completion_request(String(job["text"]), String(job["system"]))


func _on_tasks_response(text: String, stats: Dictionary) -> void:
	if _title_queue.is_empty():
		_title_busy = false
		return
	var job: Dictionary = _title_queue.pop_front()
	var title := _sanitize_title(text)
	if title != "":
		_store.set_title(String(job["id"]), title) # emits session_title_changed -> tab + dropdown update
		_settle_title_job(job, title, false, text, stats)
	else:
		_settle_title_job(job, "the reply reduced to an empty title", true, text, stats)
	_title_busy = false
	_process_title_queue()


func _on_tasks_request_failed(reason: String) -> void:
	push_warning("GDLLM: title generation failed: %s" % reason)
	if not _title_queue.is_empty():
		_settle_title_job(_title_queue.pop_front(), reason, true)
	_title_busy = false
	_process_title_queue()


## Land a finished title job's outcome in its session's task panel — an open session owns its in-memory history, so it appends the display-only record itself — or, when the tab closed mid-run, straight onto the stored record, so the run persists on reload either way (goal 2). `raw` is the model's reply verbatim ("" when the request failed outright), kept so the debug inspection can show what sanitization saw; `stats` is the request's usage, feeding the panel's footer.
func _settle_title_job(job: Dictionary, result: String, failed: bool, raw: String = "", stats: Dictionary = {}) -> void:
	var id := String(job["id"])
	var seconds := (Time.get_ticks_msec() - int(job.get("started_ms", Time.get_ticks_msec()))) / 1000.0
	var session: GDLLMChatSession = _open_sessions.get(id)
	if is_instance_valid(session):
		session.settle_title_task(String(job.get("model_label", "")), String(job.get("system", "")), String(job.get("text", "")), result, failed, seconds, raw, stats)
		return
	var record := _store.get_session(id)
	if record.is_empty():
		return
	var history: Array = record.get("history", [])
	history.append(GDLLMChatSession.title_task_entry(String(job.get("model_label", "")), String(job.get("system", "")), String(job.get("text", "")), result, failed, seconds, raw, stats))
	_store.set_history(id, history)


## Reduce a model's reply to a clean one-line title: first line only, quotes and trailing punctuation stripped, clamped in length.
func _sanitize_title(raw: String) -> String:
	var title := raw.strip_edges()
	var newline := title.find("\n")
	if newline != -1:
		title = title.substr(0, newline).strip_edges()
	title = title.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'").strip_edges()
	while not title.is_empty() and title[title.length() - 1] in [".", ",", ";", ":", "!", "?"]:
		title = title.substr(0, title.length() - 1)
	title = title.strip_edges()
	if title.length() > 48:
		title = title.substr(0, 48).strip_edges() + "…"
	return title


# --- Model list ---

## Rebuild every open session's model picker from the merged model list (GDLLMSettings already holds it and rebuilt the settings-page enums). Called after a model sweep and whenever a session picker needs to catch up.
func refresh_model_pickers() -> void:
	for session in _open_sessions.values():
		if is_instance_valid(session):
			session.set_available_models(GDLLMSettings.get_available_models())


## The user pressed a session's Fetch button; sweep every enabled source and refresh the pickers.
func _on_models_refresh_requested() -> void:
	refresh_all_models()


## Post an ephemeral note on whichever session tab the user is looking at right now; dropped when no tab is open.
## Resolved per call, so an async sweep's completion note lands where the user is at that moment, not where the sweep began.
func _announce_ephemeral(text: String) -> void:
	var session := _active_session()
	if session != null:
		session.add_ephemeral_notice(text)


## A session-store failure must land where the user is looking, not just the Output panel: a toast survives the dock being closed, and the in-log notice covers load-time failures that fire before any toast is glanceable.
func _on_store_failed(message: String) -> void:
	_announce_ephemeral(message)
	EditorInterface.get_editor_toaster().push_toast(message, EditorToaster.SEVERITY_WARNING)


## A sweep problem needs the same double landing: the ephemeral note is freed unseen when no tab is open or the tab hides before the user looks, so without the toast a source silently vanishing from the list would be exactly the hidden failure goal 2 forbids.
func _announce_sweep_problem(text: String) -> void:
	_announce_ephemeral(text)
	EditorInterface.get_editor_toaster().push_toast(text, EditorToaster.SEVERITY_WARNING)


# --- Model sweep across sources ---

## Fetch every enabled source's model list and merge into one qualified ("source::model") list, then publish it so the settings-page dropdowns and every open session picker rebuild (and GDLLMSettings caches it for next boot). Runs only on demand; a call while another sweep is in flight is ignored (the _models_sweeping guard). Every source is fetched concurrently, so the sweep costs the slowest source's latency, not their sum; a source that errors, times out, or lacks a needed key contributes nothing — named in an ephemeral note backed by an editor toast, so the failure survives even when no tab is showing (see _announce_sweep_problem).
func refresh_all_models() -> void:
	if _models_sweeping:
		return
	_models_sweeping = true
	# Announce the sweep where the user is looking, ephemerally — every trigger path funnels through here, and a moment-scoped action needs no history entry (see GDLLMChatSession.add_ephemeral_notice).
	_announce_ephemeral("Refreshing model list...")
	# Start every source's fetch before awaiting any, so they run in parallel; each handle carries its source id and the box its result lands in.
	var pending: Array = []
	for source in GDLLMSources.get_sources():
		# Skip sources the user toggled off in the Connections dialog — a down or unwanted endpoint contributes nothing and isn't contacted.
		if source is Dictionary and GDLLMSources.is_enabled(source):
			pending.append(_start_source_fetch(source))
	var merged := PackedStringArray()
	for handle in pending:
		var names := await _finish_source_fetch(handle)
		# An enabled source that came back empty would otherwise drop out of the sweep invisibly; the probe's recorded cause tells a dead server, a bad key, and a genuinely bare source apart.
		if names.is_empty():
			var why := String(handle.get("error", ""))
			if why == "":
				_announce_sweep_problem("Source %s returned no models." % String(handle["source_name"]))
			else:
				_announce_sweep_problem("Source %s returned nothing: %s" % [String(handle["source_name"]), why])
		for model_name in names:
			merged.append(GDLLMSources.make_qualified(String(handle["source_id"]), model_name))
	merged.sort()
	_models_sweeping = false
	# Every source came back empty — almost always a transient outage, not a genuine "no models installed". Keep the last known-good list rather than blanking every picker back to just its current model, and say so — keeping stale data is a decision, not a non-event.
	if merged.is_empty() and not GDLLMSettings.get_available_models().is_empty():
		_announce_sweep_problem("All sources returned nothing; keeping the previous model list.")
		return
	GDLLMSettings.set_available_models(merged)
	refresh_model_pickers()
	_announce_ephemeral("Model list refreshed: %d model%s." % [merged.size(), "" if merged.size() == 1 else "s"])


## Start one source's model fetch through a throwaway client and return a handle to await later. Splitting start from finish is what lets refresh_all_models fire every source at once and then join, instead of fetching them one at a time.
func _start_source_fetch(source: Dictionary) -> Dictionary:
	var probe := LLMClient.new()
	add_child(probe)
	probe.api_base = String(source.get("base_url", ""))
	probe.api_key = String(source.get("api_key", ""))
	probe.adapter_kind = String(source.get("kind", GDLLMSources.KIND_OLLAMA))
	var box: Array = [] # filled with the names array once received; a one-shot connect so a synchronous emit (request error) still lands here
	probe.models_received.connect(func(names: PackedStringArray) -> void: box.append(names), CONNECT_ONE_SHOT)
	probe.fetch_models()
	# The display name rides along so an empty result's note can name the source without re-resolving it.
	return {"source_id": String(source.get("id", "")), "source_name": String(source.get("name", source.get("id", ""))), "probe": probe, "box": box}


## Await one started fetch's result, free its throwaway client, and return the bare model names — empty on any failure or timeout, so the sweep never stalls. fetch_models always resolves within LLMClient.TAGS_TIMEOUT, so awaiting the signal is enough; the box covers an emit that already fired (synchronously, or while an earlier source was being awaited).
func _finish_source_fetch(handle: Dictionary) -> PackedStringArray:
	var box: Array = handle["box"]
	var probe: LLMClient = handle["probe"]
	if box.is_empty():
		await probe.models_received
	# Read the failure cause off the probe before freeing it, so an empty result's note can name why (see LLMClient.last_models_error).
	handle["error"] = String(probe.last_models_error)
	probe.queue_free()
	return box[0]


# --- Connections dialog ---

func _on_connections_pressed() -> void:
	_ensure_connections_dialog()
	_refresh_connections_list()
	_connections_dialog.popup_centered(Vector2i(780, 440))


func _ensure_connections_dialog() -> void:
	if is_instance_valid(_connections_dialog):
		return
	_connections_dialog = ConfirmationDialog.new()
	# Screen-capped like every plugin dialog holding an autowrapped label — an unsettled label's zero-width wrapped height once sized a native window past the GPU's surface limit and crashed the editor (see GDLLMChatSession.cap_dialog_to_screen).
	GDLLMChatSession.cap_dialog_to_screen(_connections_dialog)
	_connections_dialog.title = "Connections"
	_connections_dialog.ok_button_text = "Save & Close"
	# Extra actions that leave the dialog open: append a blank row, or persist edits and re-sweep every source's models.
	_connections_dialog.add_button("Add Source", false, "add_source")
	_connections_dialog.add_button("Refresh Models", false, "refresh_models")
	_connections_dialog.confirmed.connect(_on_connections_confirmed)
	_connections_dialog.custom_action.connect(_on_connections_custom_action)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Each source is a place models come from. Kind sets the wire format: Ollama (local or cloud), OpenAI-compatible (LM Studio, llama.cpp, vLLM, Poolside, most others...), or Anthropic (Claude models). For the URL, paste what your provider hands you — the full endpoint or just the server's address; every route is derived from it. Paste an API key for sources that need one — keys are stored locally in Editor Settings and never committed. Save, then Refresh Models to pull each source's models into the pickers."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(hint)

	# Column headers, laid out with the same stretch ratios as each row's fields so they line up.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var on_head := Label.new() # fixed-width, matching each row's enabled checkbox so the columns align
	on_head.text = "On"
	on_head.custom_minimum_size = Vector2(CONNECTION_TOGGLE_WIDTH, 0)
	head.add_child(on_head)
	for spec in [["Name", 2.0], ["Kind", 1.0], ["URL", 3.0], ["API key", 2.0]]:
		var col := Label.new()
		col.text = String(spec[0])
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_stretch_ratio = float(spec[1])
		head.add_child(col)
	var spacer := Control.new() # aligns with each row's fixed-width delete button
	spacer.custom_minimum_size = Vector2(34, 0)
	head.add_child(spacer)
	content.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(740, 260)
	_connections_rows_box = VBoxContainer.new()
	_connections_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connections_rows_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_connections_rows_box)
	content.add_child(scroll)

	_connections_dialog.add_child(content)
	add_child(_connections_dialog)


## Rebuild the edit rows from the stored sources.
func _refresh_connections_list() -> void:
	for entry in _connection_rows:
		var container: Control = entry["container"]
		if is_instance_valid(container):
			container.queue_free()
	_connection_rows.clear()
	for source in GDLLMSources.get_sources():
		if source is Dictionary:
			_add_connection_row(source)


## Append one editable row for `source` (a blank Dictionary for a fresh entry). The row's original id is kept in the entry so a rename doesn't orphan sessions pointing at that source's qualified model ids.
func _add_connection_row(source: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)

	var enabled_check := CheckBox.new()
	enabled_check.button_pressed = GDLLMSources.is_enabled(source)
	enabled_check.custom_minimum_size = Vector2(CONNECTION_TOGGLE_WIDTH, 0)
	enabled_check.tooltip_text = "When off, this source is skipped when fetching models — use it for a connection that's down or one you don't want queried."
	row.add_child(enabled_check)

	var name_edit := LineEdit.new()
	name_edit.text = String(source.get("name", ""))
	name_edit.placeholder_text = "Name"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.size_flags_stretch_ratio = 2.0
	row.add_child(name_edit)

	var kind_select := OptionButton.new()
	var kinds: Array = [["Ollama", GDLLMSources.KIND_OLLAMA], ["OpenAI", GDLLMSources.KIND_OPENAI], ["Anthropic", GDLLMSources.KIND_ANTHROPIC]]
	for i in kinds.size():
		kind_select.add_item(String(kinds[i][0]))
		kind_select.set_item_metadata(i, kinds[i][1])
	var current_kind := String(source.get("kind", GDLLMSources.KIND_OLLAMA))
	for i in kind_select.item_count:
		if String(kind_select.get_item_metadata(i)) == current_kind:
			kind_select.select(i)
			break
	kind_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind_select.size_flags_stretch_ratio = 1.0
	row.add_child(kind_select)

	var base_edit := LineEdit.new()
	base_edit.text = String(source.get("base_url", ""))
	_apply_base_url_hint(base_edit, current_kind)
	base_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	base_edit.size_flags_stretch_ratio = 3.0
	row.add_child(base_edit)
	kind_select.item_selected.connect(func(index: int) -> void:
		var kind := String(kind_select.get_item_metadata(index))
		_apply_base_url_hint(base_edit, kind)
		# Anthropic's endpoint is the same for everyone, so switching a still-blank row to that kind fills it in — one less thing to look up when adding the source by hand.
		if base_edit.text.strip_edges() == "" and kind == GDLLMSources.KIND_ANTHROPIC:
			base_edit.text = GDLLMSources.DEFAULT_ANTHROPIC_BASE)

	var key_edit := LineEdit.new()
	key_edit.text = String(source.get("api_key", ""))
	key_edit.placeholder_text = "API key (if needed)"
	key_edit.secret = true # mask the key at rest; it's still stored plaintext in Editor Settings
	key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_edit.size_flags_stretch_ratio = 2.0
	row.add_child(key_edit)

	var del := Button.new()
	del.custom_minimum_size = Vector2(34, 0)
	_apply_editor_icon(del, "Remove", "✕")
	del.tooltip_text = "Remove this source"
	row.add_child(del)

	_connections_rows_box.add_child(row)
	var entry := {
		"id": String(source.get("id", "")),
		"enabled_check": enabled_check,
		"name_edit": name_edit,
		"kind_select": kind_select,
		"base_edit": base_edit,
		"key_edit": key_edit,
		"container": row,
	}
	_connection_rows.append(entry)
	del.pressed.connect(func() -> void: _remove_connection_row(entry))


## Stamp `base_edit` with `kind`'s URL guidance (see CONNECTION_BASE_URL_HINTS) — the placeholder shows on a blank field, the tooltip on hover either way. Re-applied whenever the row's kind changes, so the guidance always describes the selected wire format.
func _apply_base_url_hint(base_edit: LineEdit, kind: String) -> void:
	var hint: Dictionary = CONNECTION_BASE_URL_HINTS.get(kind, {})
	base_edit.placeholder_text = String(hint.get("placeholder", "http://host:port"))
	base_edit.tooltip_text = String(hint.get("tooltip", ""))


func _remove_connection_row(entry: Dictionary) -> void:
	_connection_rows.erase(entry)
	var container: Control = entry["container"]
	if is_instance_valid(container):
		container.queue_free()


## Read the edit rows back into a sources Array: skip fully blank rows, keep each existing row's id (fresh rows slugify their name), and dedupe ids so every qualified model id resolves to exactly one source.
func _gather_sources() -> Array:
	var sources: Array = []
	var used_ids: Dictionary = {}
	for entry in _connection_rows:
		var display_name := String(entry["name_edit"].text).strip_edges()
		var base := String(entry["base_edit"].text).strip_edges()
		if display_name == "" and base == "":
			continue
		var kind_select: OptionButton = entry["kind_select"]
		var kind := String(kind_select.get_item_metadata(kind_select.selected))
		var id := String(entry["id"])
		if id == "":
			id = GDLLMSources.slugify(display_name)
			if id == "":
				id = "source"
		var unique := id
		var n := 2
		while used_ids.has(unique):
			unique = "%s-%d" % [id, n]
			n += 1
		used_ids[unique] = true
		sources.append({
			"id": unique,
			"name": display_name if display_name != "" else unique,
			"kind": kind,
			"base_url": base,
			"api_key": String(entry["key_edit"].text),
			"enabled": bool(entry["enabled_check"].button_pressed),
		})
	return sources


## Persist the current rows to Editor Settings, whose settings_changed then reconfigures the tasks client and every open session from the updated sources.
func _save_connections() -> void:
	GDLLMSources.save_sources(_gather_sources())


func _on_connections_confirmed() -> void:
	_save_connections()
	# Sweep so newly added or re-enabled sources populate the pickers; deferred so it runs after the dialog closes.
	refresh_all_models.call_deferred()


func _on_connections_custom_action(action: StringName) -> void:
	if action == "add_source":
		# Fresh rows default to the OpenAI kind
		_add_connection_row({"kind": GDLLMSources.KIND_OPENAI})
	elif action == "refresh_models":
		_save_connections() # persist edits first so the sweep hits the current URLs and keys
		refresh_all_models()


# --- Effort Configuration dialog ---

func _on_effort_config_pressed() -> void:
	_ensure_effort_dialog()
	_refresh_effort_dialog()
	_effort_dialog.popup_centered(Vector2i(1060, 440))


func _ensure_effort_dialog() -> void:
	if is_instance_valid(_effort_dialog):
		return
	_effort_dialog = ConfirmationDialog.new()
	GDLLMChatSession.cap_dialog_to_screen(_effort_dialog)
	_effort_dialog.title = "Effort Configuration"
	_effort_dialog.ok_button_text = "Save & Close"
	_effort_dialog.confirmed.connect(_on_effort_confirmed)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Check the reasoning-effort levels each model actually supports — no API reports them, so they're maintained by hand here. A configured model offers its levels in the session's effort dropdown; an unconfigured one offers only Default and sends no effort, letting the model's own behavior prevail. Each provider's adapter translates a level to its own knob (Ollama think, OpenAI reasoning_effort, Anthropic output_config.effort / disabled thinking), so check only levels the model's provider documents — an unsupported one fails loudly at request time (e.g. Anthropic has no minimal, and Claude Fable rejects none). The cache TTL column sets how many idle seconds until the model's provider prompt cache is presumed cold (free context-trimming moments ride these boundaries); 0 means unset, applying the Cache TTL Fallback editor setting on the Compaction page (default 300 s, Anthropic's 5-minute TTL). On an Anthropic source the value is also enforced on the wire, not just presumed: Anthropic's cache has exactly two lifetimes, so a value at or under 300 uses the default 5-minute cache and any larger value requests the 1-hour tier with every request — costlier to write (2x the input price instead of 1.25x, paying off from roughly three reuses) but held for the full hour, and the session then presumes the enforced lifetime (300 or 3600) rather than the raw figure. Other providers' caches accept no requested lifetime, so there the value stays a presumption only. The context column declares the model's maximum context window in tokens; a set value overrides whatever the provider's API reports, and for a source that reports none — an OpenAI-compatible server without a vendor window field in its model list (vLLM, OpenRouter, and Groq do carry one) — it is the only way the context meter, automatic compaction, and the over-window warnings get a ceiling to judge against. 0 means unset: the source's reported window applies, or an honest unknown where none is reported."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(hint)

	# Add-model row: choosing a model from the picker appends its row to the table below.
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	var add_label := Label.new()
	add_label.text = "Add model:"
	add_row.add_child(add_label)
	_effort_add_select = OptionButton.new()
	_effort_add_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_effort_add_select.fit_to_longest_item = false
	_effort_add_select.clip_text = true
	_effort_add_select.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_effort_add_select.item_selected.connect(_on_effort_add_selected)
	add_row.add_child(_effort_add_select)
	content.add_child(add_row)

	# Column headers, fixed-width like each row's checkboxes so they line up.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var model_head := Label.new()
	model_head.text = "Model"
	model_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(model_head)
	for level in GDLLMEfforts.LEVELS:
		var col := Label.new()
		col.text = level
		col.custom_minimum_size = Vector2(EFFORT_LEVEL_COL_WIDTH, 0)
		head.add_child(col)
	var cache_head := Label.new()
	cache_head.text = "cache TTL"
	cache_head.tooltip_text = "Idle seconds until this model's provider prompt cache is presumed cold; 0 = use the Cache TTL Fallback editor setting. On an Anthropic source this is also requested with every send: over 300 asks for the 1-hour cache tier (2x write cost)."
	cache_head.custom_minimum_size = Vector2(EFFORT_CACHE_COL_WIDTH, 0)
	head.add_child(cache_head)
	var context_head := Label.new()
	context_head.text = "context"
	context_head.tooltip_text = "Declared maximum context window in tokens; overrides the window the provider's API reports. 0 = use the reported window (unknown for OpenAI-compatible sources, which report none)."
	context_head.custom_minimum_size = Vector2(EFFORT_CONTEXT_COL_WIDTH, 0)
	head.add_child(context_head)
	var spacer := Control.new() # aligns with each row's fixed-width remove button
	spacer.custom_minimum_size = Vector2(34, 0)
	head.add_child(spacer)
	content.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(1010, 260)
	_effort_rows_box = VBoxContainer.new()
	_effort_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_effort_rows_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_effort_rows_box)
	content.add_child(scroll)

	_effort_dialog.add_child(content)
	add_child(_effort_dialog)


## Rebuild the table rows from the stored config (sorted for a stable order) and the add-picker from the configurable models not yet listed.
func _refresh_effort_dialog() -> void:
	for entry in _effort_rows:
		var container: Control = entry["container"]
		if is_instance_valid(container):
			container.queue_free()
	_effort_rows.clear()
	var config := GDLLMEfforts.get_config()
	var ids := config.keys()
	ids.sort()
	for qualified in ids:
		var qid := String(qualified)
		_add_effort_row(qid, GDLLMEfforts.levels_for(qid), GDLLMEfforts.cache_cold_gap_for(qid), GDLLMEfforts.context_window_for(qid))
	_refresh_effort_add_select()


## Fill the add-picker with every known model that has no row yet, behind a placeholder item — every adapter translates effort now, so any source's models are configurable. Only a stale id (its source was deleted) is withheld, since nothing can run on it.
func _refresh_effort_add_select() -> void:
	_effort_add_select.clear()
	_effort_add_select.add_item("Add a model…")
	_effort_add_select.set_item_metadata(0, "")
	var listed := {}
	for entry in _effort_rows:
		listed[String(entry["qualified"])] = true
	for qid in GDLLMSettings.get_available_models():
		if listed.has(qid):
			continue
		if bool(GDLLMSources.resolve_qualified(qid).get("stale", false)):
			continue
		_effort_add_select.add_item(GDLLMSources.label_for(qid))
		_effort_add_select.set_item_metadata(_effort_add_select.item_count - 1, qid)
	_effort_add_select.select(0)
	_effort_add_select.disabled = _effort_add_select.item_count <= 1


## A model was chosen in the add-picker: append its (empty) row and return the picker to its placeholder.
func _on_effort_add_selected(index: int) -> void:
	var qualified := String(_effort_add_select.get_item_metadata(index))
	if qualified == "":
		return
	_add_effort_row(qualified, PackedStringArray(), 0, 0)
	_refresh_effort_add_select()


## Append one row for `qualified`: its label, a checkbox per level (checked from `levels`), the cache-TTL and declared-context-window spinboxes, and a remove button.
func _add_effort_row(qualified: String, levels: PackedStringArray, cache_cold_gap: int, context_window: int) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)

	var name_label := Label.new()
	name_label.text = GDLLMSources.label_for(qualified)
	name_label.tooltip_text = qualified
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Clip rather than contribute minimum width, so a long model name can't stretch the dialog.
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_label)

	var checks := {}
	for level in GDLLMEfforts.LEVELS:
		var check := CheckBox.new()
		check.custom_minimum_size = Vector2(EFFORT_LEVEL_COL_WIDTH, 0)
		check.button_pressed = levels.has(level)
		check.tooltip_text = "This model supports \"%s\"." % level
		row.add_child(check)
		checks[level] = check

	var cache_spin := SpinBox.new()
	cache_spin.custom_minimum_size = Vector2(EFFORT_CACHE_COL_WIDTH, 0)
	cache_spin.min_value = 0
	cache_spin.max_value = 3600
	cache_spin.step = 1
	cache_spin.allow_greater = true
	cache_spin.suffix = "s"
	cache_spin.value = cache_cold_gap
	cache_spin.tooltip_text = "Idle seconds until this model's provider prompt cache is presumed cold (the provider's cache TTL). 0 = unset: the Cache TTL Fallback editor setting on the Compaction page applies. On an Anthropic source the value is enforced, not just presumed — at or under 300 uses the default 5-minute cache, anything larger requests the 1-hour tier (2x write cost, paying off from about three reuses), and the session presumes that enforced lifetime."
	row.add_child(cache_spin)

	var context_spin := SpinBox.new()
	context_spin.custom_minimum_size = Vector2(EFFORT_CONTEXT_COL_WIDTH, 0)
	context_spin.min_value = 0
	context_spin.max_value = 10_000_000
	context_spin.step = 1
	context_spin.allow_greater = true
	context_spin.value = context_window
	context_spin.tooltip_text = "This model's maximum context window in tokens, declared by hand. A set value overrides the window the provider's API reports; for a source that reports none — an OpenAI-compatible server without a vendor window field in its model list — it is what arms the context meter, automatic compaction, and the over-window warnings. 0 = unset: the reported window applies, or an honest unknown where none is reported."
	row.add_child(context_spin)

	var del := Button.new()
	del.custom_minimum_size = Vector2(34, 0)
	_apply_editor_icon(del, "Remove", "✕")
	del.tooltip_text = "Remove this model's effort configuration"
	row.add_child(del)

	_effort_rows_box.add_child(row)
	var entry := {"qualified": qualified, "checks": checks, "cache_spin": cache_spin, "context_spin": context_spin, "container": row}
	_effort_rows.append(entry)
	del.pressed.connect(func() -> void: _remove_effort_row(entry))


func _remove_effort_row(entry: Dictionary) -> void:
	_effort_rows.erase(entry)
	var container: Control = entry["container"]
	if is_instance_valid(container):
		container.queue_free()
	_refresh_effort_add_select() # the removed model becomes addable again


## Read the rows back into the per-model map and persist it (see GDLLMEfforts.make_entry for the level-array vs dict entry shapes). A row with nothing checked is kept — it stays editable here while behaving exactly like an unconfigured model (Default only). Saving emits settings_changed, which revalidates every open session's selection, rebuilds its effort picker, and re-derives its context meter and downshift row against any newly declared window (see _on_editor_settings_changed → reapply_source).
func _on_effort_confirmed() -> void:
	var config := {}
	for entry in _effort_rows:
		var levels: Array = []
		var checks: Dictionary = entry["checks"]
		for level in GDLLMEfforts.LEVELS:
			var check: CheckBox = checks[level]
			if is_instance_valid(check) and check.button_pressed:
				levels.append(level)
		var cache_spin: SpinBox = entry["cache_spin"]
		var cache_cold_gap := int(cache_spin.value) if is_instance_valid(cache_spin) else 0
		var context_spin: SpinBox = entry["context_spin"]
		var context_window := int(context_spin.value) if is_instance_valid(context_spin) else 0
		config[String(entry["qualified"])] = GDLLMEfforts.make_entry(levels, cache_cold_gap, context_window)
	GDLLMEfforts.save_config(config)


# --- Favorite Models dialog ---

func _on_favorites_config_pressed() -> void:
	_ensure_favorites_dialog()
	_refresh_favorites_dialog()
	_favorites_dialog.popup_centered(Vector2i(520, 440))


func _ensure_favorites_dialog() -> void:
	if is_instance_valid(_favorites_dialog):
		return
	_favorites_dialog = ConfirmationDialog.new()
	GDLLMChatSession.cap_dialog_to_screen(_favorites_dialog)
	_favorites_dialog.title = "Favorite Models"
	_favorites_dialog.ok_button_text = "Save & Close"
	_favorites_dialog.confirmed.connect(_on_favorites_confirmed)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Favorites sit starred at the top of every model picker, in the order below — reorder with the arrows. Removing one only unpins it; the model stays available in the picker's main list."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(hint)

	# Add-model row: choosing a model from the picker appends it to the list below.
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	var add_label := Label.new()
	add_label.text = "Add model:"
	add_row.add_child(add_label)
	_favorites_add_select = OptionButton.new()
	_favorites_add_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_favorites_add_select.fit_to_longest_item = false
	_favorites_add_select.clip_text = true
	_favorites_add_select.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_favorites_add_select.item_selected.connect(_on_favorites_add_selected)
	add_row.add_child(_favorites_add_select)
	content.add_child(add_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(480, 260)
	_favorites_rows_box = VBoxContainer.new()
	_favorites_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_favorites_rows_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_favorites_rows_box)
	content.add_child(scroll)

	_favorites_dialog.add_child(content)
	add_child(_favorites_dialog)


## Rebuild the list rows from the stored favorites — kept in stored order, since that order is the feature — and the add-picker from the models not yet listed.
func _refresh_favorites_dialog() -> void:
	for entry in _favorites_rows:
		var container: Control = entry["container"]
		if is_instance_valid(container):
			container.queue_free()
	_favorites_rows.clear()
	for qualified in GDLLMFavorites.get_list():
		_add_favorite_row(String(qualified))
	_refresh_favorites_add_select()


## Fill the add-picker with every known model not yet favorited, behind a placeholder item. Only a stale id (its source was deleted) is withheld, since no picker would offer it anyway.
func _refresh_favorites_add_select() -> void:
	_favorites_add_select.clear()
	_favorites_add_select.add_item("Add a model…")
	_favorites_add_select.set_item_metadata(0, "")
	var listed := {}
	for entry in _favorites_rows:
		listed[String(entry["qualified"])] = true
	for qid in GDLLMSettings.get_available_models():
		if listed.has(qid):
			continue
		if bool(GDLLMSources.resolve_qualified(qid).get("stale", false)):
			continue
		_favorites_add_select.add_item(GDLLMSources.label_for(qid))
		_favorites_add_select.set_item_metadata(_favorites_add_select.item_count - 1, qid)
	_favorites_add_select.select(0)
	_favorites_add_select.disabled = _favorites_add_select.item_count <= 1


## A model was chosen in the add-picker: append its row at the end of the order and return the picker to its placeholder.
func _on_favorites_add_selected(index: int) -> void:
	var qualified := String(_favorites_add_select.get_item_metadata(index))
	if qualified == "":
		return
	_add_favorite_row(qualified)
	_refresh_favorites_add_select()


## Append one row for `qualified`: reorder arrows, its label, and a remove button.
func _add_favorite_row(qualified: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	var entry := {"qualified": qualified, "container": row}

	var up := Button.new()
	up.custom_minimum_size = Vector2(34, 0)
	_apply_editor_icon(up, "MoveUp", "↑")
	up.tooltip_text = "Move this favorite up"
	up.pressed.connect(func() -> void: _move_favorite_row(entry, -1))
	row.add_child(up)

	var down := Button.new()
	down.custom_minimum_size = Vector2(34, 0)
	_apply_editor_icon(down, "MoveDown", "↓")
	down.tooltip_text = "Move this favorite down"
	down.pressed.connect(func() -> void: _move_favorite_row(entry, 1))
	row.add_child(down)

	var name_label := Label.new()
	name_label.text = GDLLMSources.label_for(qualified)
	name_label.tooltip_text = qualified
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Clip rather than contribute minimum width, so a long model name can't stretch the dialog.
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_label)

	var del := Button.new()
	del.custom_minimum_size = Vector2(34, 0)
	_apply_editor_icon(del, "Remove", "✕")
	del.tooltip_text = "Remove this model from favorites"
	del.pressed.connect(func() -> void: _remove_favorite_row(entry))
	row.add_child(del)

	_favorites_rows_box.add_child(row)
	_favorites_rows.append(entry)


## Shift a favorite one place up or down, in both the working array (what confirm saves) and the visible rows.
func _move_favorite_row(entry: Dictionary, delta: int) -> void:
	var index := _favorites_rows.find(entry)
	var target := index + delta
	if index == -1 or target < 0 or target >= _favorites_rows.size():
		return
	_favorites_rows.remove_at(index)
	_favorites_rows.insert(target, entry)
	_favorites_rows_box.move_child(entry["container"], target)


func _remove_favorite_row(entry: Dictionary) -> void:
	_favorites_rows.erase(entry)
	var container: Control = entry["container"]
	if is_instance_valid(container):
		container.queue_free()
	_refresh_favorites_add_select() # the removed model becomes addable again


## Read the rows back into the ordered favorites list and persist it. Saving emits settings_changed, which reorders and restars every open session's model picker (see _on_editor_settings_changed).
func _on_favorites_confirmed() -> void:
	var favorites := PackedStringArray()
	for entry in _favorites_rows:
		favorites.append(String(entry["qualified"]))
	GDLLMFavorites.save_list(favorites)


# --- Manage dialog ---

func _on_manage_pressed() -> void:
	_ensure_manage_dialog()
	_refresh_manage_list()
	_manage_dialog.popup_centered(Vector2i(1150, 480))


func _ensure_manage_dialog() -> void:
	if is_instance_valid(_manage_dialog):
		return
	_manage_dialog = ConfirmationDialog.new()
	GDLLMChatSession.cap_dialog_to_screen(_manage_dialog)
	_manage_dialog.title = "Manage Sessions"
	_manage_dialog.ok_button_text = "Delete Selected"
	_manage_dialog.dialog_hide_on_ok = false # stay open so several can be deleted in a row
	_manage_dialog.confirmed.connect(_on_manage_delete_confirmed)
	# Extra actions that emit custom_action and leave the dialog open. Delete All wipes the whole roster (guarded by the confirmation interstitial); the Clear Thinking pair reclaim space without deleting the conversation.
	_manage_dialog.add_button("Delete All", false, "delete_all")
	_manage_dialog.add_button("Clear Thinking (Selected)", false, "clear_thinking_selected")
	_manage_dialog.add_button("Clear All Thinking", false, "clear_thinking_all")
	_manage_dialog.custom_action.connect(_on_manage_custom_action)

	# Own the whole content area with a VBox instead of the dialog's built-in text label: the label reserves only one line's height, so a wrapped message bleeds down over the tree's header.
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Delete a session with its trash button, select several and press Delete Selected, or remove every session with Delete All. Clear Thinking drops the stored reasoning traces from the selected sessions (or all of them) to reclaim space while keeping the conversation. These changes are permanent. Drag a column edge in the header to resize it."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(hint)

	_manage_tree = Tree.new()
	_manage_tree.custom_minimum_size = Vector2(1270, 320) # fixed columns total ~1064px, so this keeps the flexing Session title readable
	_manage_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_manage_tree.select_mode = Tree.SELECT_MULTI # bottom button bulk-deletes every selected row
	_manage_tree.hide_root = true
	_manage_tree.columns = 12
	_manage_tree.column_titles_visible = true
	_manage_tree.set_column_title(0, "Session")
	_manage_tree.set_column_title(1, "Created")
	_manage_tree.set_column_title(2, "Last message")
	_manage_tree.set_column_title(3, "Model") # the model(s) stamped on the most assistant turns; ties share the cell
	_manage_tree.set_column_title(4, "Est In") # cumulative prompt tokens estimated from the payloads actually sent (chars/4), subagent threads included
	_manage_tree.set_column_title(5, "Est Out") # cumulative reply tokens estimated from the streamed replies, same coverage
	_manage_tree.set_column_title(6, "Rep In") # cumulative prompt tokens the endpoints themselves reported, same coverage
	_manage_tree.set_column_title(7, "Rep Out") # cumulative reply tokens the endpoints themselves reported, same coverage
	_manage_tree.set_column_title(8, "Context") # the session's current context size: the largest single-request context (in + out), which every new request re-sends
	_manage_tree.set_column_title(9, "On disk") # on-disk footprint minus reasoning traces
	_manage_tree.set_column_title(10, "Thinking") # bytes of stored reasoning traces (what Clear Thinking reclaims)
	# Only the Session title flexes; the rest start at a fixed width wide enough for their header and content ("Jul 30, 2026"). Every boundary is drag-resizable (see _on_manage_tree_gui_input).
	_manage_tree.set_column_expand(0, true)
	for col in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, MANAGE_COL_DELETE]:
		_manage_tree.set_column_expand(col, false)
	_manage_tree.set_column_custom_minimum_width(1, 140)
	_manage_tree.set_column_custom_minimum_width(2, 140)
	_manage_tree.set_column_custom_minimum_width(3, 110)
	for col in [4, 5, 6, 7, 8, 9, 10]:
		_manage_tree.set_column_custom_minimum_width(col, 90)
	_manage_tree.set_column_custom_minimum_width(MANAGE_COL_DELETE, 44)
	# Without clipping, a column's content width becomes a hard floor and drag-shrinking silently stops working.
	for col in _manage_tree.columns:
		_manage_tree.set_column_clip_content(col, true)
	_manage_tree.button_clicked.connect(_on_manage_row_delete)
	_manage_tree.gui_input.connect(_on_manage_tree_gui_input)
	content.add_child(_manage_tree)

	_manage_totals = Label.new()
	_manage_totals.tooltip_text = "Tokens in/out summed across every session in the table, subagent threads included — estimated (chars/4 of the traffic actually exchanged) and endpoint-reported counts kept apart."
	content.add_child(_manage_totals)

	_manage_dialog.add_child(content)
	add_child(_manage_dialog)


func _refresh_manage_list() -> void:
	_manage_tree.clear()
	var root := _manage_tree.create_item()
	var remove_icon := _editor_icon("Remove")
	var total_est_in := 0
	var total_est_out := 0
	var total_rep_in := 0
	var total_rep_out := 0
	# Newest-first, matching the session dropdown's order.
	for i in range(_store.sessions.size() - 1, -1, -1):
		var record := _store.sessions[i]
		var item := _manage_tree.create_item(root)
		item.set_text(0, String(record.get("title", GDLLMSessionStore.DEFAULT_TITLE)))
		item.set_text(1, _format_date(int(record.get("created", 0))))
		item.set_text(2, _format_date(int(record.get("updated", 0))))
		var model := _dominant_models(record.get("history", []))
		item.set_text(3, String(model["text"]))
		item.set_tooltip_text(3, String(model["tooltip"]))
		# Token columns derive from the record's stored per-request stats — the same sums the session header shows (see GDLLMChatSession.token_usage) — with the plugin's chars/4 estimates and the endpoints' own reported counts in separate columns.
		var usage := GDLLMChatSession.token_usage(record.get("history", []))
		var est_in := int(usage["est_in"]) + int(usage["subagent_est_in"])
		var est_out := int(usage["est_out"]) + int(usage["subagent_est_out"])
		var rep_in := int(usage["rep_in"]) + int(usage["subagent_rep_in"])
		var rep_out := int(usage["rep_out"]) + int(usage["subagent_rep_out"])
		var context := int(usage["context"])
		total_est_in += est_in
		total_est_out += est_out
		total_rep_in += rep_in
		total_rep_out += rep_out
		item.set_text(4, "~%s" % _abbrev_tokens(est_in) if est_in > 0 else "—")
		item.set_tooltip_text(4, "Cumulative prompt tokens estimated (chars/4) from the request payloads actually sent this session, subagent threads included: %s. Sessions saved before the estimates existed show —." % _comma(est_in))
		item.set_text(5, "~%s" % _abbrev_tokens(est_out) if est_out > 0 else "—")
		item.set_tooltip_text(5, "Cumulative reply tokens estimated (chars/4) from the replies streamed back this session, subagent threads included: %s. Sessions saved before the estimates existed show —." % _comma(est_out))
		item.set_text(6, _abbrev_tokens(rep_in) if rep_in > 0 else "—")
		item.set_tooltip_text(6, "Cumulative prompt tokens the endpoints themselves reported across every request this session, subagent threads included: %s. Providers that report no usage show —." % _comma(rep_in))
		item.set_text(7, _abbrev_tokens(rep_out) if rep_out > 0 else "—")
		item.set_tooltip_text(7, "Cumulative reply tokens the endpoints themselves reported across every request this session, subagent threads included: %s. Providers that report no usage show —." % _comma(rep_out))
		item.set_text(8, _abbrev_tokens(context) if context > 0 else "—")
		item.set_tooltip_text(8, "The session's current context size — its newest request's context (prompt + reply tokens), which the next request re-sends — preferring each request's reported counts and falling back to its estimates: %s. A session compacted after its last reply shows — until its next request reports the smaller context." % _comma(context))
		for col in [4, 5, 6, 7, 8]:
			item.set_text_alignment(col, HORIZONTAL_ALIGNMENT_RIGHT)
		var think_bytes := _thinking_size(record)
		var total_bytes := JSON.stringify(record).to_utf8_buffer().size()
		item.set_text(9, _format_bytes(maxi(0, total_bytes - think_bytes)))
		item.set_text_alignment(9, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_text(10, _format_bytes(think_bytes) if think_bytes > 0 else "—")
		item.set_text_alignment(10, HORIZONTAL_ALIGNMENT_RIGHT)
		# Metadata lives on column 0; the whole row shares one session id.
		item.set_metadata(0, record["id"])
		if remove_icon != null:
			item.add_button(MANAGE_COL_DELETE, remove_icon, 0, false, "Delete this session")
	var count := _store.sessions.size()
	if count == 0:
		_manage_totals.text = "No sessions."
	else:
		_manage_totals.text = "%d session%s · est tokens in/out: ~%s / ~%s · reported tokens in/out: %s / %s" % [count, _plural(count), _comma(total_est_in), _comma(total_est_out), _comma(total_rep_in), _comma(total_rep_out)]


## The Model column's cell text and tooltip: the model(s) stamped on the most assistant turns in `history` (ties share the cell), with the tooltip breaking down every model's turn count.
func _dominant_models(history: Array) -> Dictionary:
	var counts := {}
	for msg in history:
		if msg is Dictionary and String(msg.get("role", "")) == "assistant" and String(msg.get("model", "")) != "":
			var qualified := String(msg["model"])
			counts[qualified] = int(counts.get(qualified, 0)) + 1
	if counts.is_empty():
		return {"text": "—", "tooltip": "No assistant turn in this session carries a model stamp."}
	var best := 0
	for qualified in counts:
		best = maxi(best, int(counts[qualified]))
	var leaders: Array[String] = []
	var breakdown: Array[String] = []
	for qualified in counts:
		if int(counts[qualified]) == best:
			leaders.append(String(GDLLMSources.parse_qualified(qualified)["model"]))
		breakdown.append("%s ×%d" % [GDLLMSources.label_for(qualified), int(counts[qualified])])
	return {"text": ", ".join(leaders), "tooltip": "Assistant turns per model: %s." % ", ".join(breakdown)}


## Drag-resize for the manage table's columns, which Tree doesn't offer natively: press on a column's right-edge boundary in the title strip, drag to set its width. Runs off the gui_input signal, which fires before Tree's built-in handling, so accept_event keeps the drag from doubling as a title click or row selection.
func _on_manage_tree_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var col := _manage_boundary_at(event.position)
			if col >= 0:
				# The flexing Session column must freeze at its current width, or expand keeps overriding the drag.
				if _manage_tree.is_column_expanding(col):
					_manage_tree.set_column_expand(col, false)
				_manage_resize_col = col
				_manage_resize_start = event.position.x
				_manage_resize_start_width = _manage_tree.get_column_width(col)
				_manage_tree.accept_event()
		elif _manage_resize_col >= 0:
			_manage_resize_col = -1
			_manage_tree.accept_event()
	elif event is InputEventMouseMotion:
		if _manage_resize_col >= 0:
			var width := _manage_resize_start_width + int(event.position.x - _manage_resize_start)
			_manage_tree.set_column_custom_minimum_width(_manage_resize_col, maxi(MANAGE_COL_MIN_WIDTH, width))
			_manage_tree.accept_event()
		else:
			var over_boundary := _manage_boundary_at(event.position) >= 0
			_manage_tree.mouse_default_cursor_shape = Control.CURSOR_HSPLIT if over_boundary else Control.CURSOR_ARROW


## The manage-table column whose right-edge boundary sits under `pos` in the title strip, or -1 when not over a draggable boundary. The last column's right edge is the tree's own edge, so it is never a boundary.
func _manage_boundary_at(pos: Vector2) -> int:
	if pos.y < 0.0 or pos.y > _manage_title_height():
		return -1
	var edge := -_manage_tree.get_scroll().x
	for col in _manage_tree.columns - 1:
		edge += _manage_tree.get_column_width(col)
		if absf(pos.x - edge) <= MANAGE_RESIZE_MARGIN:
			return col
	return -1


## Height of the manage table's title strip, rebuilt from the same theme pieces Tree draws it with, since Tree exposes no getter for it.
func _manage_title_height() -> float:
	var sb := _manage_tree.get_theme_stylebox("title_button_normal")
	var font := _manage_tree.get_theme_font("title_button_font")
	var font_size := _manage_tree.get_theme_font_size("title_button_font_size")
	return sb.get_minimum_size().y + font.get_height(font_size)


## Confirm, then delete every selected row when the dialog's bottom Delete button is pressed.
func _on_manage_delete_confirmed() -> void:
	var ids := _selected_manage_ids()
	if ids.is_empty():
		return
	var count := ids.size()
	_ask_confirmation(
		"Delete %d selected session%s? This cannot be undone." % [count, _plural(count)],
		_delete_sessions.bind(ids))


## Confirm, then delete a single session when its per-row trash button is clicked.
func _on_manage_row_delete(item: TreeItem, column: int, _id: int, _mouse_button_index: int) -> void:
	if column != MANAGE_COL_DELETE:
		return
	var id := String(item.get_metadata(0))
	if id == "":
		return
	_ask_confirmation(
		"Delete \"%s\"? This cannot be undone." % item.get_text(0),
		_delete_sessions.bind([id]))


## Handle the dialog's custom buttons — each is a permanent action, so all route through the "Are you sure?" interstitial before touching anything.
func _on_manage_custom_action(action: StringName) -> void:
	if action == "delete_all":
		if _store.sessions.is_empty():
			return
		var count := _store.sessions.size()
		_ask_confirmation(
			"Delete ALL %d session%s? This cannot be undone." % [count, _plural(count)],
			_delete_all_sessions)
	elif action == "clear_thinking_selected":
		var ids := _selected_manage_ids()
		if ids.is_empty():
			return
		_ask_confirmation(
			"Clear stored reasoning traces from %d selected session%s? This cannot be undone." % [ids.size(), _plural(ids.size())],
			_clear_thinking_for.bind(ids), "Clear")
	elif action == "clear_thinking_all":
		if _store.sessions.is_empty():
			return
		var count := _store.sessions.size()
		_ask_confirmation(
			"Clear stored reasoning traces from ALL %d session%s? This cannot be undone." % [count, _plural(count)],
			_clear_thinking_all, "Clear")


## Drop stored reasoning traces from one session. An open session's live view is cleared too (its in-memory history and rendered blocks), then the stored record is stripped directly — which, unlike routing through set_history, leaves the "Last message" timestamp untouched. A busy session is skipped WHOLE, disk record included, and reported false: its in-flight loop keeps the echo thinking the API needs to finish (see GDLLMChatSession.clear_thinking), and stripping the record alone would be undone the moment that turn persists.
func _clear_session_thinking(id: String) -> bool:
	if _open_sessions.has(id) and _open_sessions[id].is_busy():
		return false
	if _open_sessions.has(id):
		_open_sessions[id].clear_thinking()
	_store.clear_thinking(id)
	return true


## Session ids of every selected row (deduped across the columns SELECT_MULTI may report per row).
func _selected_manage_ids() -> Array[String]:
	var ids: Array[String] = []
	var item := _manage_tree.get_next_selected(null)
	while item != null:
		var id := String(item.get_metadata(0))
		if id != "" and not ids.has(id):
			ids.append(id)
		item = _manage_tree.get_next_selected(item)
	return ids


## An editor-theme icon by name (e.g. "Remove" for the per-row delete buttons), or null if unavailable.
func _editor_icon(icon_name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	return null


## Set `button`'s icon from the editor theme, falling back to `fallback_text` when the theme lacks the name (same shape as GDLLMChatSession._apply_editor_icon).
func _apply_editor_icon(button: Button, icon_name: String, fallback_text: String) -> void:
	var icon := _editor_icon(icon_name)
	if icon != null:
		button.icon = icon
	else:
		button.text = fallback_text


## A short "Jul 6, 2026" date from a Unix timestamp, or "—" when unset (e.g. a session with no messages yet).
func _format_date(unix: int) -> String:
	if unix <= 0:
		return "—"
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%s %d, %d" % [MONTHS[int(d.month) - 1], int(d.day), int(d.year)]


## Human-readable byte size as "512 B", "3.4 KB", or "1.2 MB".
func _format_bytes(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	var kb := bytes / 1024.0
	return "%.1f KB" % kb if kb < 1024.0 else "%.1f MB" % (kb / 1024.0)


## Total bytes of the reasoning traces stored in a session — the space "Clear Thinking" would reclaim, the thinking blocks inside provider echoes included (see GDLLMSessionStore.strip_echo_thinking).
func _thinking_size(record: Dictionary) -> int:
	var bytes := 0
	for msg in record.get("history", []):
		if not (msg is Dictionary):
			continue
		if msg.has("thinking"):
			bytes += String(msg["thinking"]).to_utf8_buffer().size()
		if msg.get("assistant_blocks") is Array:
			for block in msg["assistant_blocks"]:
				if block is Dictionary and String(block.get("type", "")) in ["thinking", "redacted_thinking"]:
					bytes += JSON.stringify(block).to_utf8_buffer().size()
	return bytes


## Compact token count for the manage table's tight columns (e.g. 102340 -> "102.3k", 2000 -> "2k"); the exact figure stays in the cell's tooltip.
static func _abbrev_tokens(n: int) -> String:
	for scale in [[1_000_000_000_000.0, "t"], [1_000_000_000.0, "b"], [1_000_000.0, "m"], [1_000.0, "k"]]:
		if n >= float(scale[0]):
			return ("%.1f" % (n / float(scale[0]))).trim_suffix(".0") + String(scale[1])
	return str(n)


## Group an integer's digits with commas for readability (e.g. 12345 -> "12,345").
func _comma(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return ("-" + out) if n < 0 else out


## Delete a session everywhere: close its tab if open, drop it from the store, refresh the dropdown.
func _delete_session(id: String) -> void:
	if _open_sessions.has(id):
		var session: GDLLMChatSession = _open_sessions[id]
		_open_sessions.erase(id)
		session.queue_free()
	_store.delete(id)
	_rebuild_session_dropdown()


## Delete a batch of sessions by id, then refresh the manage table. Run only after the user clears the confirmation interstitial.
func _delete_sessions(ids: Array) -> void:
	for id in ids:
		_delete_session(String(id))
	_refresh_manage_list()


## Delete every session. Snapshots the ids first, since _delete_session mutates the roster as it goes. Run only after the user clears the confirmation interstitial.
func _delete_all_sessions() -> void:
	var ids: Array[String] = []
	for record in _store.sessions:
		ids.append(String(record["id"]))
	_delete_sessions(ids)


## Strip reasoning traces from a batch of sessions, then refresh the manage table. Run only after the user clears the confirmation interstitial. Every session busy at this moment is skipped and named afterwards, so a clear that silently left traces behind is never mistaken for one that worked.
func _clear_thinking_for(ids: Array) -> void:
	var skipped: Array[String] = []
	for id in ids:
		if not _clear_session_thinking(String(id)):
			skipped.append(_session_title(String(id)))
	_refresh_manage_list()
	if not skipped.is_empty():
		_announce_skipped_clear(skipped)


## Report the sessions "Clear Thinking" skipped for being busy, naming each and the action that finishes the job. Ephemeral rather than a history entry — the skip is a moment's outcome of a button press, not something that happened to the conversation — and toast-backed like every other ephemeral warning, because the manage dialog is covering the log the note lands in (see _announce_sweep_problem).
func _announce_skipped_clear(titles: Array[String]) -> void:
	var text := "Reasoning traces kept in %d busy session%s (%s): a request or tool run is still in flight. Clear again once it's idle." % [
		titles.size(), _plural(titles.size()), ", ".join(titles)]
	_announce_ephemeral(text)
	EditorInterface.get_editor_toaster().push_toast(text, EditorToaster.SEVERITY_WARNING)


## A session's display title by id, for messages naming sessions the user didn't act on one at a time.
func _session_title(id: String) -> String:
	return String(_store.get_session(id).get("title", GDLLMSessionStore.DEFAULT_TITLE))


## Strip reasoning traces from every session. Run only after the user clears the confirmation interstitial.
func _clear_thinking_all() -> void:
	var ids: Array[String] = []
	for record in _store.sessions:
		ids.append(String(record["id"]))
	_clear_thinking_for(ids)


# --- Confirmation interstitial ---

## Pop the "Are you sure?" dialog with `message` and an OK button reading `ok_text`; `on_confirm` runs only if the user clicks through. Guards every permanent delete/clear action against a fat-fingered click.
func _ask_confirmation(message: String, on_confirm: Callable, ok_text: String = "Delete") -> void:
	_ensure_confirm_dialog()
	_confirm_dialog.dialog_text = message
	_confirm_dialog.ok_button_text = ok_text
	_pending_confirm = on_confirm
	_confirm_dialog.popup_centered()


func _ensure_confirm_dialog() -> void:
	if is_instance_valid(_confirm_dialog):
		return
	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Are you sure?"
	_confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	add_child(_confirm_dialog)


## "" for one, "s" otherwise — pluralizes "session" in the confirmation prompts.
func _plural(count: int) -> String:
	return "" if count == 1 else "s"


## Run and clear the action stashed by _ask_confirmation.
func _on_confirm_dialog_confirmed() -> void:
	var action := _pending_confirm
	_pending_confirm = Callable()
	if action.is_valid():
		action.call()


# --- Settings / endpoint sync ---

## Sync the dock when a source or model is changed from the settings page or the Connections dialog (or any other listener).
func _on_editor_settings_changed() -> void:
	_tasks_client.configure_from(GDLLMSettings.get_tasks_source_and_model())
	# Rebuild pickers only on an actual favorites edit — this signal fires for every settings write (input-height drag ticks included), and each rebuild churns every open picker.
	var favorites := JSON.stringify(Array(GDLLMFavorites.get_list()))
	var favorites_changed := favorites != _last_favorites
	_last_favorites = favorites
	for session in _open_sessions.values():
		if is_instance_valid(session):
			if favorites_changed:
				# Reorder and restar the picker; the session keeps its selection by qualified id.
				session.set_available_models(GDLLMSettings.get_available_models())
			# Re-resolve each session's own model so an endpoint or key edited in the Connections dialog takes effect.
			session.reapply_source()
			# Keep each session's header expand switches in step with the settings dialog (they share one key).
			session.sync_expand_toggles_from_settings()
			# The message-box height is shared the same way; a drag in one session follows onto the rest.
			session.sync_input_height_from_settings()
	# Let a global chat-model change follow through to the active session.
	var chat_model := GDLLMSettings.get_chat_model()
	var active := _active_session()
	if active != null and active.current_model() != chat_model:
		active.apply_model(chat_model)
		_store.set_model(active.session_id, chat_model)
	var colors := GDLLMColors.snapshot()
	if colors != _last_colors:
		_last_colors = colors
		_schedule_color_repaint()


## Repaint every open session's log for the edited palette, at most once per COLOR_REPAINT_INTERVAL — a repaint rebuilds each log from its history, and the settings dialog's color picker writes on every tick of a drag through the color wheel.
func _schedule_color_repaint() -> void:
	if _color_repaint_pending:
		return
	_color_repaint_pending = true
	await get_tree().create_timer(COLOR_REPAINT_INTERVAL).timeout
	_color_repaint_pending = false
	for session in _open_sessions.values():
		if is_instance_valid(session):
			session.repaint_colors()


# --- Editor selection tracking (routed to the active session) ---

## Auto-check "Attach selection" on the active session when a selection appears in the editor and uncheck it when the selection clears; acts only on the transition so a manual toggle — or editing your message — is never overwritten.
func _on_editor_caret_changed() -> void:
	var code_edit := _current_code_edit()
	var has_selection := code_edit != null and code_edit.has_selection()
	if has_selection == _editor_had_selection:
		return
	_editor_had_selection = has_selection
	var active := _active_session()
	if active != null:
		active.set_attach_selection(has_selection)


## Turn off deselect-on-focus-loss for every open script editor so a highlighted selection survives clicking into the chat field, and watch each one's caret so "Attach selection" can track it. Every flip is recorded so plugin disable restores the editor's own behavior (see restore_editor_selection_behavior).
func _keep_editor_selections_alive() -> void:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	for base in script_editor.get_open_script_editors():
		var code_edit := base.get_base_editor() as CodeEdit
		if code_edit == null:
			continue
		# Only a flip this dock actually made is recorded, so a CodeEdit the user configured themselves is never "restored" to a state they didn't choose.
		if code_edit.deselect_on_focus_loss_enabled:
			code_edit.deselect_on_focus_loss_enabled = false
			_selection_flips.append(code_edit)
		if not code_edit.caret_changed.is_connected(_on_editor_caret_changed):
			code_edit.caret_changed.connect(_on_editor_caret_changed)


## Undo _keep_editor_selections_alive for plugin disable: every CodeEdit this dock flipped gets its deselect-on-focus-loss behavior back. The caret connections die with this dock, so only the flag needs restoring.
func restore_editor_selection_behavior() -> void:
	for code_edit in _selection_flips:
		if is_instance_valid(code_edit):
			code_edit.deselect_on_focus_loss_enabled = true
	_selection_flips.clear()


## Reapply _keep_editor_selections_alive() when a script is opened or switched — the only time a new CodeEdit (with the default focus-loss behavior) appears.
func _on_editor_script_changed(_script: Script) -> void:
	_keep_editor_selections_alive()


## The CodeEdit backing the currently open script, or null if none is open.
func _current_code_edit() -> CodeEdit:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return null
	var base := script_editor.get_current_editor()
	if base == null:
		return null
	return base.get_base_editor() as CodeEdit
