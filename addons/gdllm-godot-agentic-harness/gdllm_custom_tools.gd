@tool
class_name GDLLMCustomTools
extends RefCounted
## Project-authored tools: each res://gdllm-tools/<name>.gd (top level only) becomes a tool named by its file stem, listed in tool_search's catalog and dispatched like a built-in (see GDLLMTools._all_tools). The script runs inside the editor process, so loading one is gated by trust: a file the user wrote loads on its own, while one the model created or changed waits for the user's approval in the dock's Custom Tools dialog, and the user can disable any tool there.
## Trust is tracked by content hash. A change is the model's when it lands while a tool call is in flight (begin_model_call/end_model_call bracket every call, so run_script and custom tools that write files count too) or while a game is running (a model-launched game may outlive its call); any other change is the user's. A pending tool stays pending through later edits until approved, and an unreadable trust store marks every unknown file pending rather than trusting it.

const ROOT := "res://gdllm-tools"
const STORE_PATH := "user://gdllm/custom_tools.json"

## The file shape a custom tool must have, quoted to the model when it writes into ROOT and in load errors, so a malformed tool says how to fix itself.
const CONTRACT := "A custom tool is one GDScript file at res://gdllm-tools/<name>.gd (top level; the file stem is the tool name: letters, digits, _ or -, up to 64). It must start with @tool, extend RefCounted, declare const DESCRIPTION := \"what it does and returns\" (required), optionally const SUMMARY (one-line catalog text; defaults to DESCRIPTION's first line), const PARAMETERS (a JSON-Schema object Dictionary; defaults to no parameters), const READ_ONLY := true (omit it and the tool is gated behind the user's Make changes toggle), and const DESTRUCTIVE := true (also gated behind Delete files), and define func execute(args: Dictionary) -> String (it may await). It runs inside the editor, so EditorInterface is available."

const _NAME_PATTERN := "^[A-Za-z0-9_-]{1,64}$"

static var root := ROOT ## Overridable so headless tests can point discovery at a fixture directory.
static var store_path := STORE_PATH

static var _store_loaded := false
static var _store_corrupt := false ## The store exists but couldn't be read: fail closed, treating every file not already trusted as pending.
static var _trusted := {} ## res path -> md5 of the content the user wrote or approved.
static var _pending := {} ## res path -> md5 of the model-made content awaiting approval.
static var _disabled := {} ## res path -> true for tools the user switched off.
static var _loaded := {} ## res path -> {md5, script?, entry?, error?}: the last load attempt per file, reused while its content is unchanged.
static var _inflight := 0 ## Tool calls currently running; any change seen while this is nonzero is the model's.
static var _scanned_frame := -1 ## The process frame of the last passive scan: one tool call consults definitions many times, and the disk can't usefully change within a frame.


## The loaded custom tools as REGISTRY-shaped entries keyed by tool name, after a fresh scan. Only trusted, enabled files that load cleanly appear.
static func definitions() -> Dictionary:
	_passive_scan()
	var out := {}
	for path in _loaded:
		var record: Dictionary = _loaded[path]
		if record.has("entry") and _state_for(path) == "ready":
			out[String(record["entry"]["name"])] = record["entry"]
	return out


## Every file under ROOT with its state, for the Custom Tools dialog and the catalog: [{name, path, state, detail}], state one of "ready", "disabled", "pending", "error". Sorted by name.
static func status() -> Array:
	_passive_scan()
	var rows: Array = []
	for path in _list_files():
		var state := _state_for(path)
		var detail := ""
		if state == "error":
			detail = String(_loaded[path]["error"])
		rows.append({"name": String(path).get_file().get_basename(), "path": path, "state": state, "detail": detail})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["name"]) < String(b["name"]))
	return rows


## Catalog lines naming custom tools that exist but can't be called, and why — so the model asks the user instead of concluding the tool is missing. "" when every custom tool loaded (or there are none).
static func catalog_notes() -> String:
	var lines := PackedStringArray()
	for row: Dictionary in status():
		match String(row["state"]):
			"pending":
				lines.append("Custom tool \"%s\" (%s) is awaiting the user's approval: it was created or changed by the model, so it won't load until the user approves it in the Custom Tools dialog (the 🔧 button beside the model picker)." % [row["name"], row["path"]])
			"error":
				lines.append("Custom tool \"%s\" (%s) failed to load: %s" % [row["name"], row["path"], row["detail"]])
	return "\n".join(lines)


## Bracket a tool call: settle changes made before it as the user's (unless another call is already running), then count it in flight.
static func begin_model_call() -> void:
	_scan(_model_active())
	_inflight += 1


## Close a tool call's bracket: attribute every change made during it to the model, and return the res paths that just became pending.
static func end_model_call() -> PackedStringArray:
	var newly := _scan(true)
	_inflight = maxi(_inflight - 1, 0)
	return newly


## The note appended to a tool result that left custom tools pending, so the model knows the tool won't run yet and tells the user (goal 3); the result itself is shown to the user too.
static func pending_note(paths: PackedStringArray) -> String:
	return "\n\nNote: %s %s a custom tool file. Because you created or changed it, it will not load until the user reviews and approves it in the Custom Tools dialog (the 🔧 button beside the model picker) — tell the user it needs approval. %s" % [", ".join(paths), "is" if paths.size() == 1 else "are each", CONTRACT]


## Approve the file's content as reviewed, identified by `reviewed_md5`: it loads from now on, until the model changes it again. Returns false, approving nothing, when the file no longer holds that content.
static func approve(path: String, reviewed_md5: String) -> bool:
	_load_store()
	if not FileAccess.file_exists(path) or FileAccess.get_md5(path) != reviewed_md5:
		return false
	_trusted[path] = reviewed_md5
	_pending.erase(path)
	_save_store()
	invalidate()
	return true


static func set_enabled(path: String, on: bool) -> void:
	_load_store()
	if on:
		_disabled.erase(path)
	else:
		_disabled[path] = true
	_save_store()
	invalidate()


## Run the custom tool `name` with `args` and return its result text. The caller has already applied the Make changes / Delete files gates.
static func execute(name: String, args: Dictionary) -> String:
	var path := "%s/%s.gd" % [root, name]
	var record: Dictionary = _loaded.get(path, {})
	if not record.has("script") or _state_for(path) != "ready":
		return "Error: custom tool \"%s\" is no longer loaded (it was removed, disabled, changed, or awaits approval since it was attached). Call tool_search to see the current catalog." % name
	var instance: Object = (record["script"] as GDScript).new()
	var out: Variant = await Callable(instance, "execute").call(args)
	if out == null:
		return "Error: custom tool \"%s\" returned nothing. A runtime error in %s is the usual cause — read_errors shows it; execute() must return a String." % [name, path]
	if out is String:
		return out
	if out is Dictionary or out is Array:
		return JSON.stringify(out, "\t")
	return str(out)


## A scan outside any call bracket, at most once per process frame.
static func _passive_scan() -> void:
	var frame := Engine.get_process_frames()
	if frame == _scanned_frame:
		return
	_scanned_frame = frame
	_scan(_model_active())


## Drop the once-per-frame memo so the next lookup rescans — for callers (and tests) that just changed files within the same frame.
static func invalidate() -> void:
	_scanned_frame = -1


static func _model_active() -> bool:
	if _inflight > 0:
		return true
	return Engine.is_editor_hint() and EditorInterface.is_playing_scene()


## "ready", "disabled", "pending", or "error" for a file present under ROOT.
static func _state_for(path: String) -> String:
	if _pending.has(path):
		return "pending"
	if _disabled.has(path):
		return "disabled"
	if _loaded.has(path) and _loaded[path].has("error"):
		return "error"
	return "ready"


## Every top-level .gd under ROOT with its content md5.
static func _list_files() -> Dictionary:
	var files := {}
	var dir := DirAccess.open(root)
	if dir == null:
		return files
	for file in dir.get_files():
		if file.get_extension().to_lower() == "gd":
			var path := "%s/%s" % [root, file]
			files[path] = FileAccess.get_md5(path)
	return files


## Reconcile the trust store with the files on disk, attributing any change to the model when `model_active`, and (re)load each trusted file whose content changed. Returns the paths that became pending in this scan.
static func _scan(model_active: bool) -> PackedStringArray:
	_load_store()
	var files := _list_files()
	var newly := PackedStringArray()
	var changed := false
	for path in files:
		var md5 := String(files[path])
		if String(_trusted.get(path, "")) == md5:
			if _pending.erase(path):
				changed = true
			continue
		if _pending.has(path):
			if String(_pending[path]) != md5:
				_pending[path] = md5
				changed = true
			continue
		if model_active or _store_corrupt:
			_pending[path] = md5
			newly.append(path)
		else:
			_trusted[path] = md5
		changed = true
	for table: Dictionary in [_trusted, _pending, _disabled]:
		for path in table.keys():
			if not files.has(path):
				table.erase(path)
				changed = true
	for path in _loaded.keys():
		if not files.has(path):
			_loaded.erase(path)
	for path in files:
		if _pending.has(path) or _disabled.has(path):
			continue
		if not _loaded.has(path) or String(_loaded[path]["md5"]) != String(files[path]):
			_loaded[path] = _load_tool(path, String(files[path]))
	if changed:
		_save_store()
	return newly


## Load and validate one trusted file, returning its _loaded record: {md5, script, entry} on success, {md5, error} with a fix-pointing message otherwise.
static func _load_tool(path: String, md5: String) -> Dictionary:
	var name := path.get_file().get_basename()
	var fail := func(message: String) -> Dictionary: return {"md5": md5, "error": message + " " + CONTRACT}
	var pattern := RegEx.create_from_string(_NAME_PATTERN)
	if pattern.search(name) == null:
		return fail.call("\"%s\" isn't a valid tool name; rename the file." % name)
	if name == GDLLMTools.TOOL_SEARCH or GDLLMTools.REGISTRY.has(name):
		return fail.call("\"%s\" is already a built-in tool's name; rename the file." % name)
	var script := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as GDScript
	if script == null or not script.can_instantiate():
		return fail.call("the script doesn't compile — check_script on %s shows why." % path)
	if not script.is_tool():
		return fail.call("the script is missing @tool on its first line, so the editor can't run it.")
	if not ClassDB.is_parent_class(script.get_instance_base_type(), "RefCounted"):
		return fail.call("the script must extend RefCounted (it extends %s)." % script.get_instance_base_type())
	var has_execute := false
	for method: Dictionary in script.get_script_method_list():
		if String(method["name"]) == "execute":
			has_execute = true
			break
	if not has_execute:
		return fail.call("the script defines no execute(args: Dictionary) function.")
	var consts := script.get_script_constant_map()
	var description: Variant = consts.get("DESCRIPTION", "")
	if not (description is String) or String(description).strip_edges() == "":
		return fail.call("the script declares no DESCRIPTION string.")
	var parameters: Variant = consts.get("PARAMETERS", {"type": "object", "properties": {}})
	if not (parameters is Dictionary):
		return fail.call("PARAMETERS must be a Dictionary holding a JSON-Schema object.")
	var summary := String(consts.get("SUMMARY", String(description).strip_edges().split("\n")[0]))
	var read_only := bool(consts.get("READ_ONLY", false))
	var destructive := bool(consts.get("DESTRUCTIVE", false))
	var entry := {
		"name": name,
		"path": path,
		"custom": true,
		"summary": summary,
		"description": String(description),
		"parameters": parameters,
		"max_consecutive_uses": -1,
		"mutating": destructive or not read_only,
		"destructive": destructive,
	}
	return {"md5": md5, "script": script, "entry": entry}


static func _load_store() -> void:
	if _store_loaded:
		return
	_store_loaded = true
	if not FileAccess.file_exists(store_path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(store_path))
	if not (data is Dictionary):
		_store_corrupt = true
		push_warning("GDLLM custom tools: %s is unreadable, so every custom tool not already trusted waits for approval in the Custom Tools dialog. Approving them rewrites the file." % store_path)
		return
	_trusted = data.get("trusted", {})
	_pending = data.get("pending", {})
	for path in data.get("disabled", []):
		_disabled[String(path)] = true


static func _save_store() -> void:
	DirAccess.make_dir_recursive_absolute(store_path.get_base_dir())
	var file := FileAccess.open(store_path, FileAccess.WRITE)
	if file == null:
		push_warning("GDLLM custom tools: could not write %s (%s); approvals and enable choices won't persist past this editor session." % [store_path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(JSON.stringify({"trusted": _trusted, "pending": _pending, "disabled": _disabled.keys()}, "\t"))
	_store_corrupt = false


## Forget all state and point at fresh locations — for headless tests only.
static func reset_for_tests(test_root: String, test_store: String) -> void:
	root = test_root
	store_path = test_store
	_store_loaded = false
	_store_corrupt = false
	_trusted = {}
	_pending = {}
	_disabled = {}
	_loaded = {}
	_inflight = 0
	_scanned_frame = -1
