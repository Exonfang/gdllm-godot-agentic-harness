extends SceneTree
## Headless regression tests for legacy session histories: a stored conversation that used tools since REMOVED from the registry (the 2026-07 scene-tool removal) must survive store load/save verbatim, reactivate only tools that still exist, and get recoverable coaching if a model imitates the old calls. Pins the contract that changing the tool set never rewrites or hides what a past session did.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/legacy_history_test.gd
## Exits nonzero on any failure. The real user://gdllm/sessions.json is backed up before the store is touched and restored afterward, so running this against a live project loses nothing.

const STORE_PATH := "user://gdllm/sessions.json"

var _checks := 0
var _failures := 0


func _init() -> void:
	var backup := _read_store()
	_run_tests()
	_restore_store(backup)
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _run_tests() -> void:
	var legacy_history: Array = [
		{"role": "user", "content": "add a sprite", "attachments": [], "text": "add a sprite"},
		{"role": "assistant", "content": "", "model": "m", "tool_calls": [
			{"function": {"name": "add_node", "arguments": {"type": "Sprite2D", "name": "Spr"}}},
		]},
		{"role": "tool", "tool_name": "add_node", "content": "Added Sprite2D as \"Spr\"..."},
		{"role": "assistant", "content": "", "model": "m", "tool_calls": [
			{"function": {"name": "set_node_property", "arguments": {"node_path": "Spr", "properties": {"visible": false}}}},
			{"function": {"name": "read_file", "arguments": {"path": "res://project.godot"}}},
		]},
		{"role": "tool", "tool_name": "set_node_property", "content": "Set 1 property(ies)..."},
		{"role": "tool", "tool_name": "read_file", "content": "config_version=5..."},
		{"role": "assistant", "content": "Done.", "model": "m"},
	]
	var record := {"id": "s_legacy_1", "title": "Legacy", "model": "m", "created": 1, "updated": 2, "is_open": false, "history": legacy_history}
	# The retired autosave_scenes key rides along, as a real pre-removal file would carry it.
	_write_store(JSON.stringify({"active": "s_legacy_1", "make_changes": false, "autosave_scenes": true, "sessions": [record]}))

	var store := GDLLMSessionStore.new()
	store.load()
	_check(store.sessions.size() == 1, "the legacy session loads")
	var loaded: Array = store.sessions[0]["history"]
	_check(JSON.stringify(loaded) == JSON.stringify(legacy_history), "removed-tool history survives load verbatim")

	store.flush()
	var store2 := GDLLMSessionStore.new()
	store2.load()
	_check(JSON.stringify(store2.sessions[0]["history"]) == JSON.stringify(legacy_history), "removed-tool history survives the flush/reload round trip")

	var active: Dictionary = GDLLMTools.active_tools_from_history(loaded)
	_check(active.has("read_file"), "a surviving tool from the old history reactivates")
	_check(not active.has("add_node") and not active.has("set_node_property"), "removed tools are skipped, not crashed on")

	var result: Dictionary = await GDLLMTools.execute("add_node", {"type": "Sprite2D"}, true)
	var content := String(result.get("content", ""))
	_check(content.begins_with("Error: unknown tool") and content.contains("tool_search"), "a re-attempted removed tool errors with the tool_search route")


## The store file's current text, or null when none exists — the distinction _restore_store needs to put things back exactly.
func _read_store() -> Variant:
	if not FileAccess.file_exists(STORE_PATH):
		return null
	return FileAccess.get_file_as_string(STORE_PATH)


func _write_store(text: String) -> void:
	DirAccess.make_dir_recursive_absolute(STORE_PATH.get_base_dir())
	var file := FileAccess.open(STORE_PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _restore_store(backup: Variant) -> void:
	if backup == null:
		DirAccess.remove_absolute(STORE_PATH)
		return
	_write_store(String(backup))
