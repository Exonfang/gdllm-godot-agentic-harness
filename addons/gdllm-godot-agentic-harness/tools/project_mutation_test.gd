extends SceneTree
## Headless regression tests for exact autoload ownership and save+verify+rollback semantics. Uses an injected in-memory backend; never touches this checkout's project.godot.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/project_mutation_test.gd

const GDLLMProjectMutation = preload("res://addons/gdllm-godot-agentic-harness/gdllm_project_mutation.gd")
const NAME := "GDLLMGameAgent"
const SCRIPT := "res://addons/gdllm-godot-agentic-harness/gdllm_game_agent.gd"
const KEY := "autoload/" + NAME

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_enable_and_idempotency()
	_test_disable_owned()
	_test_foreign_collision()
	_test_save_failure_rollback()
	_test_verification_failure_rollback()
	_test_invalid_request()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: %s" % label)


func _test_enable_and_idempotency() -> void:
	var backend := FakeBackend.new()
	backend.memory["application/config/name"] = "Unrelated"
	backend.disk = backend.memory.duplicate(true)
	var result := GDLLMProjectMutation.sync_autoload(NAME, SCRIPT, true, backend)
	_check(bool(result["ok"]) and bool(result["changed"]) and String(result["status"]) == "enabled", "an absent autoload enables transactionally")
	_check(backend.disk.get(KEY) == GDLLMProjectMutation.autoload_value(SCRIPT), "the exact canonical singleton value reaches disk")
	_check(backend.disk.get("application/config/name") == "Unrelated", "an unrelated setting is preserved")
	var saves := backend.save_calls
	result = GDLLMProjectMutation.sync_autoload(NAME, SCRIPT, true, backend)
	_check(bool(result["ok"]) and not bool(result["changed"]) and backend.save_calls == saves, "an owned enabled autoload is idempotent")


func _test_disable_owned() -> void:
	for owned in GDLLMProjectMutation.autoload_values(SCRIPT):
		var backend := FakeBackend.with_setting(KEY, owned)
		var result := GDLLMProjectMutation.sync_autoload(NAME, SCRIPT, false, backend)
		_check(bool(result["ok"]) and String(result["status"]) == "disabled", "an exactly owned %s autoload disables" % owned)
		_check(not backend.memory.has(KEY) and not backend.disk.has(KEY), "disable removes the owned value from memory and disk")


func _test_foreign_collision() -> void:
	for foreign in ["res://addons/gdllm-godot-agentic-harness/gdllm_game_agent.gd", "*res://other/game_agent.gd"]:
		var backend := FakeBackend.with_setting(KEY, foreign)
		var before := backend.disk.duplicate(true)
		var result := GDLLMProjectMutation.sync_autoload(NAME, SCRIPT, false, backend)
		_check(not bool(result["ok"]) and String(result["status"]) == "foreign", "a non-exact value is foreign even when its path looks related")
		_check(backend.disk == before and backend.save_calls == 0, "a foreign collision is preserved without a save")


func _test_save_failure_rollback() -> void:
	var backend := FakeBackend.new()
	backend.save_errors.append(ERR_FILE_CANT_WRITE)
	var result := GDLLMProjectMutation.sync_autoload(NAME, SCRIPT, true, backend)
	_check(not bool(result["ok"]) and String(result["status"]) == "save_failed", "a save error is reported")
	_check(bool(result["rollback_ok"]), "an unchanged disk snapshot verifies the rollback")
	_check(not backend.memory.has(KEY) and not backend.disk.has(KEY), "a failed enable leaves no in-memory or on-disk value")


func _test_verification_failure_rollback() -> void:
	var backend := FakeBackend.new()
	backend.corrupt_saves = 1
	var result := GDLLMProjectMutation.sync_autoload(NAME, SCRIPT, true, backend)
	_check(not bool(result["ok"]) and String(result["status"]) == "verification_failed", "a mismatched read-back fails the transaction")
	_check(bool(result["rollback_ok"]) and backend.save_calls == 2, "verification failure performs and verifies one rollback save")
	_check(not backend.memory.has(KEY) and not backend.disk.has(KEY), "verification rollback restores the absent snapshot")


func _test_invalid_request() -> void:
	var backend := FakeBackend.new()
	var result := GDLLMProjectMutation.sync_autoload("", SCRIPT, true, backend)
	_check(String(result["status"]) == "invalid" and backend.save_calls == 0, "an invalid request performs no mutation")


class FakeBackend:
	extends RefCounted

	var memory: Dictionary = {}
	var disk: Dictionary = {}
	var save_errors: Array[int] = []
	var save_calls := 0
	var corrupt_saves := 0


	static func with_setting(key: String, value: Variant) -> FakeBackend:
		var backend := FakeBackend.new()
		backend.memory[key] = value
		backend.disk[key] = value
		return backend


	func has_setting(key: String) -> bool:
		return memory.has(key)


	func get_setting(key: String) -> Variant:
		return memory.get(key)


	func set_setting(key: String, value: Variant) -> void:
		memory[key] = value


	func clear_setting(key: String) -> void:
		memory.erase(key)


	func save() -> int:
		save_calls += 1
		if not save_errors.is_empty():
			return save_errors.pop_front()
		disk = memory.duplicate(true)
		if corrupt_saves > 0:
			corrupt_saves -= 1
			disk[KEY] = "*res://tampered.gd"
		return OK


	func read_saved(key: String) -> Dictionary:
		return {"ok": true, "exists": disk.has(key), "value": disk.get(key)}
