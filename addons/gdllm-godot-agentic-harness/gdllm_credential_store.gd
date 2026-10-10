@tool
class_name GDLLMCredentialStore extends RefCounted
## A separate local credential store for provider keys and OAuth tokens.
##
## Godot exposes no supported cross-platform OS keychain API to GDScript, so this
## implementation does not claim encryption it cannot provide. It keeps credentials
## out of EditorSettings and project/session files, writes atomically, and requests
## owner-only Unix permissions where the platform supports them. The backend status
## is public so UI/docs can describe that residual local-machine risk honestly.

const GLOBAL_SUBDIR := "Godot/gdllm"
const FILE_NAME := "credentials.json"
const VERSION := 1
const UNIX_OWNER_READ_WRITE := 384 # 0600

static var _test_path := ""


static func backend_status() -> Dictionary:
	return {
		"backend": "restricted_plaintext_file",
		"encrypted": false,
		"path": _path(),
		"detail": "Godot has no supported cross-platform native keychain API for GDScript; credentials are separated and owner-restricted where supported, but are not encrypted at rest.",
	}


## The editor-wide, per-OS-user location. Unlike user:// this does not vary with
## the open project's name, matching the global scope of the legacy
## EditorSettings values migrated into it.
static func storage_path() -> String:
	return _path()


static func get_secret(bucket: String, id: String) -> String:
	var data := _load()
	var group: Variant = data.get("secrets", {}).get(bucket, {})
	var value := String(group.get(id, "")) if group is Dictionary else ""
	GDLLMSecretRedactor.register_secret(value)
	return value


static func get_record(bucket: String, id: String) -> Dictionary:
	var data := _load()
	var group: Variant = data.get("secrets", {}).get(bucket, {})
	var record: Variant = group.get(id, {}) if group is Dictionary else {}
	if record is Dictionary:
		GDLLMSecretRedactor.register_variant(record)
		return record.duplicate(true)
	return {}


static func get_namespace(bucket: String) -> Dictionary:
	var data := _load()
	var group: Variant = data.get("secrets", {}).get(bucket, {})
	if group is Dictionary:
		_register_records(group)
		return group.duplicate(true)
	return {}


static func set_secret(bucket: String, id: String, secret: String) -> bool:
	var data := _load()
	var secrets: Dictionary = data.get("secrets", {})
	var group: Dictionary = secrets.get(bucket, {})
	if secret == "":
		group.erase(id)
	else:
		group[id] = secret
		GDLLMSecretRedactor.register_secret(secret)
	secrets[bucket] = group
	data["secrets"] = secrets
	return _write_verified(data)


static func set_record(bucket: String, id: String, record: Dictionary) -> bool:
	var data := _load()
	var secrets: Dictionary = data.get("secrets", {})
	var group: Dictionary = secrets.get(bucket, {})
	if record.is_empty():
		group.erase(id)
	else:
		group[id] = record.duplicate(true)
		GDLLMSecretRedactor.register_variant(record)
	secrets[bucket] = group
	data["secrets"] = secrets
	return _write_verified(data)


## Replace one whole namespace in one atomic write. Callers use this before
## removing legacy plaintext, which makes migration fail closed on disk errors.
static func replace_namespace(bucket: String, records: Dictionary) -> bool:
	var data := _load()
	var secrets: Dictionary = data.get("secrets", {})
	secrets[bucket] = records.duplicate(true)
	data["secrets"] = secrets
	_register_records(records)
	return _write_verified(data)


static func _register_records(records: Dictionary) -> void:
	for value in records.values():
		if value is String:
			GDLLMSecretRedactor.register_secret(String(value))
		elif value is Dictionary or value is Array:
			GDLLMSecretRedactor.register_variant(value)


static func remove(bucket: String, id: String) -> bool:
	return set_record(bucket, id, {})


static func _load() -> Dictionary:
	var path := _path()
	_recover_interrupted_write(path)
	if not FileAccess.file_exists(path):
		return {"version": VERSION, "secrets": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("GDLLM credentials: %s could not be read; refusing to overwrite it." % path)
		return {"version": VERSION, "secrets": {}, "_unreadable": true}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or not parsed.get("secrets") is Dictionary:
		push_warning("GDLLM credentials: %s is not valid credential-store JSON; refusing to overwrite it." % path)
		return {"version": VERSION, "secrets": {}, "_unreadable": true}
	return parsed


static func _recover_interrupted_write(path: String) -> void:
	var temp := path + ".tmp"
	var backup := path + ".previous"
	if not FileAccess.file_exists(path) and FileAccess.file_exists(backup):
		# The process stopped after preserving the old store but before installing
		# the verified replacement. Restore the authoritative previous copy.
		DirAccess.rename_absolute(backup, path)
	if FileAccess.file_exists(path):
		# Either recovery or a completed replacement makes both copies stale and
		# potentially secret-bearing, so remove them on the next access.
		if FileAccess.file_exists(temp):
			DirAccess.remove_absolute(temp)
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(backup)


static func _write_verified(data: Dictionary) -> bool:
	if bool(data.get("_unreadable", false)):
		return false
	var path := _path()
	var dir := path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir) not in [OK, ERR_ALREADY_EXISTS]:
		push_warning("GDLLM credentials: could not create %s; credentials were not changed." % dir)
		return false
	var temp := path + ".tmp"
	var backup := path + ".previous"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		push_warning("GDLLM credentials: could not write a temporary store; credentials were not changed.")
		return false
	var payload := data.duplicate(true)
	payload.erase("_unreadable")
	file.store_string(JSON.stringify(payload))
	file.flush()
	file = null
	_restrict_permissions(temp)
	var verify := FileAccess.open(temp, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(verify.get_as_text()) if verify != null else null
	verify = null
	if not (parsed is Dictionary) or parsed.get("secrets") != payload.get("secrets"):
		DirAccess.remove_absolute(temp)
		push_warning("GDLLM credentials: temporary-store verification failed; credentials were not changed.")
		return false
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	var had_previous := FileAccess.file_exists(path)
	if had_previous and DirAccess.rename_absolute(path, backup) != OK:
		DirAccess.remove_absolute(temp)
		push_warning("GDLLM credentials: could not preserve the previous store; credentials were not changed.")
		return false
	if DirAccess.rename_absolute(temp, path) != OK:
		if had_previous:
			DirAccess.rename_absolute(backup, path)
		push_warning("GDLLM credentials: atomic replacement failed; the previous store was restored.")
		return false
	_restrict_permissions(path)
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	return true


static func _restrict_permissions(path: String) -> void:
	# This API is meaningful on Unix. On Windows, Godot has no GDScript ACL API;
	# the file remains within the per-user application-data directory.
	if OS.get_name() in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		FileAccess.set_unix_permissions(path, UNIX_OWNER_READ_WRITE)


static func _path() -> String:
	if _test_path != "":
		return _test_path
	return OS.get_config_dir().path_join(GLOBAL_SUBDIR).path_join(FILE_NAME)


## Test seam: isolates destructive persistence tests from real credentials.
static func _set_test_path(path: String) -> void:
	_test_path = path
