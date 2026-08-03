@tool
class_name GDLLMSessionStore extends RefCounted
## Per-project persistence and in-memory roster of chat sessions. Everything lives in a single JSON file under user://gdllm/, which Godot resolves to a per-project, per-machine folder — so no manual project keying is needed.
## Disk writes are debounced: mutations arrive in bursts (several per agentic turn), and rewriting the whole growing file per mutation stalls the editor. save() marks the roster dirty and one timer flushes the burst; structural changes (create/delete) and the dock's exit path flush immediately, so the only loss window is GDLLMTunables.SESSION_SAVE_DEBOUNCE_SECONDS of tail on a hard editor crash.

## Emitted when a session's title changes (e.g. after Tasks-Model summarization). The dock's session dropdown and tab listen to this to refresh their labels.
signal session_title_changed(id: String, title: String)

## Emitted when persistence itself fails or a broken roster is set aside: the dock surfaces the message in the editor, because a push_warning alone leaves a save outage visible only to users with the Output panel open (goal 2).
signal store_failed(message: String)

const DIR := "user://gdllm"
const PATH := "user://gdllm/sessions.json"
const DEFAULT_TITLE := "New chat"
# The save-debounce window is user-configurable — see GDLLMTunables' gdllm/interface section.

var sessions: Array[Dictionary] = [] ## Ordered roster; each entry is a session record (see _new_record).
var active_id: String = "" ## Last-focused session, restored on load.
var _save_pending: bool = false ## a debounced write is scheduled; further save() calls fold into it
var _protect_unread: bool = false ## the roster file exists but couldn't be read, so flush() must not overwrite sessions that were never loaded; cleared by a successful load
var _protect_announced: bool = false ## the disabled-saves outage has been announced once; flush() is called per mutation burst and must not repeat it


## Read the roster from disk. A missing file leaves an empty roster (a fresh start); a corrupt one is moved aside to a timestamped backup before the empty roster loads, so a later flush() can't overwrite the bytes a recovery would need. An existing file that can't even be OPENED may still be a valid roster (permissions, a transient lock), so it is left in place and saving is disabled instead — flushing over sessions that were never loaded would destroy them.
func load() -> void:
	sessions.clear()
	active_id = ""
	_protect_unread = false
	_protect_announced = false
	if not FileAccess.file_exists(PATH):
		return
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		_protect_unread = true
		_fail("GDLLM sessions: %s exists but could not be opened for reading — stored sessions are hidden this launch, and saving is disabled so they are not overwritten. Check the file's permissions, then restart the editor or re-enable the plugin." % PATH)
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not (data is Dictionary):
		file = null # drop the handle so the file is closed before the quarantine rename
		_quarantine_corrupt()
		return
	active_id = String(data.get("active", ""))
	# "Make changes" was once one project-wide flag; a legacy file's value seeds each record missing its own, preserving what the user had.
	var legacy_make_changes := bool(data.get("make_changes", false))
	for entry in data.get("sessions", []):
		if entry is Dictionary:
			sessions.append(_normalize(entry, legacy_make_changes))


## Move an unparseable sessions.json aside under a timestamped name: the roster starts fresh either way, but flush() rewrites PATH wholesale, and overwriting the corrupt file would destroy the only copy a hand recovery could mine.
func _quarantine_corrupt() -> void:
	var backup := "%s.corrupt-%s" % [PATH, Time.get_datetime_string_from_system().replace(":", "-")]
	var err := DirAccess.rename_absolute(PATH, backup)
	if err != OK:
		_fail("GDLLM sessions: %s is corrupt and couldn't be moved aside (%s); the session list started fresh and the next save will overwrite the corrupt file." % [PATH, error_string(err)])
		return
	_fail("GDLLM sessions: %s was corrupt; it was moved to %s and the session list started fresh — the backup holds the old data if you need a hand recovery." % [PATH, backup])


## Record a persistence failure in the Output panel AND hand it to the dock for in-editor display — the two audiences see different surfaces, and the dock one is what keeps a save outage from being silent.
func _fail(message: String) -> void:
	push_warning(message)
	store_failed.emit(message)


## Schedule a coalesced write, called after every mutation; the burst's writes land as one flush() GDLLMTunables.SESSION_SAVE_DEBOUNCE_SECONDS after the first. Headless (no SceneTree to defer on) it writes synchronously, keeping tests deterministic.
func save() -> void:
	if _save_pending:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		flush()
		return
	_save_pending = true
	tree.create_timer(GDLLMTunables.getf(GDLLMTunables.SESSION_SAVE_DEBOUNCE_SECONDS)).timeout.connect(_on_save_timer)


## The debounce timer's landing point: skip the write when a manual flush already covered this burst.
func _on_save_timer() -> void:
	if _save_pending:
		flush()


## Write the roster to disk now, absorbing any scheduled debounce-write. Compact JSON — the file is a per-machine cache rewritten whole on every flush, and the in-editor "Inspect model context" view pretty-prints its own reconstruction, so an indent here would only pay write cost.
func flush() -> void:
	_save_pending = false
	if _protect_unread:
		# The roster on disk was never read, so writing would replace sessions this run knows nothing about; announced once, not per mutation burst.
		if not _protect_announced:
			_protect_announced = true
			_fail("GDLLM sessions: NOT saving — %s couldn't be read when the plugin loaded, and overwriting it would destroy the sessions it may still hold. Work from this run will be lost unless the file is made readable and the plugin reloaded." % PATH)
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		_fail("GDLLM sessions: could not write %s — chat sessions are NOT being saved, and changes since the last successful save will be lost when the editor exits. Check the folder's permissions and free disk space." % PATH)
		return
	file.store_string(JSON.stringify({"active": active_id, "sessions": sessions}))


## Create, register as active, persist, and return a fresh empty session record.
func create() -> Dictionary:
	var record := _new_record()
	sessions.append(record)
	active_id = record["id"]
	flush() # structural and rare — worth the immediate write
	return record


## An untouched "New chat": no message (user, assistant, or task panel) has ever landed in it. Closing its tab deletes the record instead of hiding it — without that, every boot with no open tab minted a fresh one and rosters accumulated empty sessions indefinitely.
static func is_pristine(record: Dictionary) -> bool:
	return not (record.get("history") is Array) or (record["history"] as Array).is_empty()


## The record for `id`, or an empty Dictionary if none. The returned Dictionary is the live record (mutating it mutates the roster).
func get_session(id: String) -> Dictionary:
	for record in sessions:
		if record["id"] == id:
			return record
	return {}


## Remove a session and persist. No-op if `id` isn't present. When the active session is deleted, active moves to the last remaining session (or "").
func delete(id: String) -> void:
	for i in sessions.size():
		if sessions[i]["id"] == id:
			sessions.remove_at(i)
			if active_id == id:
				active_id = sessions[-1]["id"] if not sessions.is_empty() else ""
			flush() # structural and rare — worth the immediate write
			return


## Set a session's title, persist, and notify listeners. No-op if `id` is absent or the title is unchanged.
func set_title(id: String, title: String) -> void:
	var record := get_session(id)
	if record.is_empty() or record["title"] == title:
		return
	record["title"] = title
	save()
	session_title_changed.emit(id, title)


## Replace a session's conversation history (deep-copied so the store owns its data), bump its timestamp, and persist.
func set_history(id: String, history: Array) -> void:
	var record := get_session(id)
	if record.is_empty():
		return
	record["history"] = history.duplicate(true)
	record["updated"] = int(Time.get_unix_time_from_system())
	save()


## Strip every message's stored reasoning trace from a session and persist. No-op when the session has none. Leaves `updated` untouched — clearing traces isn't a new message. Returns true if anything was removed.
func clear_thinking(id: String) -> bool:
	var record := get_session(id)
	if record.is_empty():
		return false
	var changed := false
	for msg in record.get("history", []):
		if not (msg is Dictionary):
			continue
		if msg.has("thinking"):
			msg.erase("thinking")
			msg.erase("thinking_seconds")
			changed = true
		changed = strip_echo_thinking(msg) or changed
	if changed:
		save()
	return changed


## Drop the thinking/redacted_thinking blocks a provider echo stored beside a tool-call turn (see AnthropicAdapter's assistant_blocks), so "Clear Thinking" removes reasoning from disk and from any resend, not just from the display fields. Returns true if anything was removed.
static func strip_echo_thinking(msg: Dictionary) -> bool:
	if not (msg.get("assistant_blocks") is Array):
		return false
	var kept: Array = []
	for block in msg["assistant_blocks"]:
		if not (block is Dictionary and String(block.get("type", "")) in ["thinking", "redacted_thinking"]):
			kept.append(block)
	if kept.size() == msg["assistant_blocks"].size():
		return false
	if kept.is_empty():
		msg.erase("assistant_blocks")
	else:
		msg["assistant_blocks"] = kept
	return true


## Remember a session's chat model and persist.
func set_model(id: String, model: String) -> void:
	var record := get_session(id)
	if record.is_empty() or record["model"] == model:
		return
	record["model"] = model
	save()


## Remember a session's reasoning-effort selection ("" = Default) and persist. No-op when absent or unchanged.
func set_effort(id: String, effort: String) -> void:
	var record := get_session(id)
	if record.is_empty() or String(record.get("effort", "")) == effort:
		return
	record["effort"] = effort
	save()


## Record whether a session is currently shown as a tab, so it can be reopened on the next editor launch.
func set_open(id: String, is_open: bool) -> void:
	var record := get_session(id)
	if record.is_empty() or record["is_open"] == is_open:
		return
	record["is_open"] = is_open
	save()


## Persist one session's "Make changes" state, so one chat can edit while another stays read-only. No-op when absent or unchanged.
func set_make_changes(id: String, on: bool) -> void:
	var record := get_session(id)
	if record.is_empty() or bool(record.get("make_changes", false)) == on:
		return
	record["make_changes"] = on
	save()


## Persist one session's "Delete files" state, the per-session counterpart to set_make_changes. No-op when absent or unchanged.
func set_delete_files(id: String, on: bool) -> void:
	var record := get_session(id)
	if record.is_empty() or bool(record.get("delete_files", false)) == on:
		return
	record["delete_files"] = on
	save()


## Persist one session's "Tools" state, the per-session counterpart to set_make_changes. No-op when absent or unchanged.
func set_tools_enabled(id: String, on: bool) -> void:
	var record := get_session(id)
	if record.is_empty() or bool(record.get("tools_enabled", true)) == on:
		return
	record["tools_enabled"] = on
	save()


## Remember which session is focused so it can be reselected on the next launch.
func set_active(id: String) -> void:
	if active_id == id:
		return
	active_id = id
	save()


func _new_record() -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	return {
		"id": "s_%d_%d" % [Time.get_ticks_usec(), randi()],
		"title": DEFAULT_TITLE,
		"model": GDLLMSettings.get_chat_model(),
		"created": 0, ## Stamped on the first user message (see GDLLMChatSession._on_send_pressed), not when the empty tab is spawned.
		"updated": now,
		"is_open": true,
		"make_changes": GDLLMSettings.is_new_session_edits_on(), ## Per-session write permission; whether a fresh session starts with it on is the user's editor setting.
		"delete_files": GDLLMSettings.is_new_session_delete_on(), ## Per-session delete permission, seeded the same way; existing sessions keep their stored state.
		"tools_enabled": true,
		"history": [],
	}


## Backfill any missing fields on a record read from disk so older or partial files load cleanly. `legacy_make_changes` is the file's retired project-wide flag, seeding records that predate the per-session field.
func _normalize(record: Dictionary, legacy_make_changes: bool) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	record["id"] = String(record.get("id", "s_%d_%d" % [Time.get_ticks_usec(), randi()]))
	record["title"] = String(record.get("title", DEFAULT_TITLE))
	record["model"] = String(record.get("model", GDLLMSettings.get_chat_model()))
	record["created"] = int(record.get("created", now))
	record["updated"] = int(record.get("updated", now))
	record["is_open"] = bool(record.get("is_open", true))
	record["make_changes"] = bool(record.get("make_changes", legacy_make_changes))
	record["tools_enabled"] = bool(record.get("tools_enabled", true))
	record.erase("context_tokens") # retired cache: token columns now derive from history, so shed the stale field from older files
	if not (record.get("history") is Array):
		record["history"] = []
	return record
