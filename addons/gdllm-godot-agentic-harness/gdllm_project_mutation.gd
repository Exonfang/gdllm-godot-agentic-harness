@tool
class_name GDLLMProjectMutation
extends RefCounted
## Transactional, ownership-aware project.godot mutations. The production backend writes ProjectSettings; tests inject the same tiny interface without touching a real project.


## Reconcile one autoload and return {ok, status, changed, message, rollback_ok}. Ownership is an exact value GDLLM itself can have written: the current `*uid://...` form, or the legacy exact `*res://...` form. A name collision with anything else is foreign and is never overwritten or removed.
static func sync_autoload(name: String, script_path: String, enabled: bool, backend: Variant = null) -> Dictionary:
	if name.strip_edges() == "" or not script_path.begins_with("res://"):
		return _result(false, "invalid", false, "The autoload name and res:// script path must both be explicit.")
	var store: Variant = backend if backend != null else ProjectSettingsBackend.new()
	var key := "autoload/" + name
	var expected := autoload_value(script_path)
	var owned_values := autoload_values(script_path)
	var existed := bool(store.has_setting(key))
	var previous: Variant = store.get_setting(key) if existed else null
	if existed and not (String(previous) in owned_values):
		return _result(false, "foreign", false, "The %s autoload belongs to another value (%s); GDLLM preserved it." % [name, String(previous)])
	if enabled == existed:
		return _result(true, "unchanged", false, "The %s autoload is already %s." % [name, "enabled" if enabled else "disabled"])

	_set_snapshot(store, key, enabled, expected)
	var save_error := int(store.save())
	if save_error != OK:
		_set_snapshot(store, key, existed, previous)
		var rollback_ok := _saved_matches(store, key, existed, previous)
		if not rollback_ok:
			rollback_ok = int(store.save()) == OK and _saved_matches(store, key, existed, previous)
		var failed := _result(false, "save_failed", false, "project.godot could not be saved (%s); the %s autoload change was rolled back%s." % [error_string(save_error), name, "" if rollback_ok else " in memory, but the on-disk state could not be verified"])
		failed["rollback_ok"] = rollback_ok
		return failed
	if _saved_matches(store, key, enabled, expected):
		return _result(true, "enabled" if enabled else "disabled", true, "The %s autoload was %s and verified on disk." % [name, "enabled" if enabled else "disabled"])

	_set_snapshot(store, key, existed, previous)
	var rollback_error := int(store.save())
	var rollback_ok := rollback_error == OK and _saved_matches(store, key, existed, previous)
	var failed := _result(false, "verification_failed", false, "project.godot did not contain the requested %s autoload value after saving; GDLLM rolled the change back%s." % [name, "" if rollback_ok else ", but could not verify the rollback"])
	failed["rollback_ok"] = rollback_ok
	return failed


static func autoload_value(script_path: String) -> String:
	var uid := ResourceLoader.get_resource_uid(script_path)
	if uid != ResourceUID.INVALID_ID:
		return "*" + ResourceUID.id_to_text(uid)
	return "*" + script_path


## Every exact representation this plugin has legitimately written across supported Godot versions. No path normalization or target resolution widens the ownership check.
static func autoload_values(script_path: String) -> PackedStringArray:
	var values := PackedStringArray([autoload_value(script_path)])
	var legacy := "*" + script_path
	if not values.has(legacy):
		values.append(legacy)
	return values


static func owns_autoload(name: String, script_path: String, backend: Variant = null) -> bool:
	var store: Variant = backend if backend != null else ProjectSettingsBackend.new()
	var key := "autoload/" + name
	return bool(store.has_setting(key)) and String(store.get_setting(key)) in autoload_values(script_path)


static func _set_snapshot(store: Variant, key: String, exists: bool, value: Variant) -> void:
	if exists:
		store.set_setting(key, value)
	else:
		store.clear_setting(key)


static func _saved_matches(store: Variant, key: String, exists: bool, value: Variant) -> bool:
	var saved: Dictionary = store.read_saved(key)
	if not bool(saved.get("ok", false)) or bool(saved.get("exists", false)) != exists:
		return false
	return not exists or saved.get("value") == value


static func _result(ok: bool, status: String, changed: bool, message: String) -> Dictionary:
	return {"ok": ok, "status": status, "changed": changed, "message": message, "rollback_ok": true}


class ProjectSettingsBackend:
	extends RefCounted


	func has_setting(key: String) -> bool:
		return ProjectSettings.has_setting(key)


	func get_setting(key: String) -> Variant:
		return ProjectSettings.get_setting(key)


	func set_setting(key: String, value: Variant) -> void:
		ProjectSettings.set_setting(key, value)


	func clear_setting(key: String) -> void:
		ProjectSettings.clear(key)


	func save() -> int:
		return ProjectSettings.save()


	func read_saved(key: String) -> Dictionary:
		var config := ConfigFile.new()
		var error := config.load("res://project.godot")
		if error != OK:
			return {"ok": false, "exists": false, "value": null}
		var slash := key.find("/")
		if slash < 1 or slash == key.length() - 1:
			return {"ok": false, "exists": false, "value": null}
		var section := key.substr(0, slash)
		var property := key.substr(slash + 1)
		var exists := config.has_section_key(section, property)
		return {"ok": true, "exists": exists, "value": config.get_value(section, property) if exists else null}
