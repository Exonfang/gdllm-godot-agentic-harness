extends SceneTree
## Headless regressions for credential separation, transactional local persistence,
## legacy source splitting, and the redaction boundaries used by HTTP/OAuth/console.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/credential_security_test.gd

const Redactor = preload("res://addons/gdllm-godot-agentic-harness/gdllm_secret_redactor.gd")
const Store = preload("res://addons/gdllm-godot-agentic-harness/gdllm_credential_store.gd")
const Sources = preload("res://addons/gdllm-godot-agentic-harness/gdllm_sources.gd")
const Console = preload("res://addons/gdllm-godot-agentic-harness/gdllm_console.gd")
const Client = preload("res://addons/gdllm-godot-agentic-harness/llm_client.gd")
const SessionStore = preload("res://addons/gdllm-godot-agentic-harness/gdllm_session_store.gd")

const TEST_PATH := "user://gdllm/credential_security_test.json"

var _checks := 0
var _failures := 0


func _init() -> void:
	_cleanup()
	_check(Store.storage_path().begins_with(OS.get_config_dir()) and not Store.storage_path().begins_with("user://"), "the default credential store is editor-wide rather than project-local user://")
	Store._set_test_path(TEST_PATH)
	_test_redaction()
	_test_store()
	_test_source_split()
	_test_output_boundaries()
	Store._set_test_path("")
	_cleanup()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: %s" % label)


func _test_redaction() -> void:
	Redactor.clear_registered()
	var exact := "locally-registered-secret-987654"
	Redactor.register_secret(exact)
	_check(Redactor.redact("before %s after" % exact) == "before [REDACTED] after", "registered secrets are replaced exactly")
	_check(Redactor.redact("Authorization: Bearer abcdefghijklmnopqrstuvwxyz") == "Authorization: Bearer [REDACTED]", "Bearer headers are scrubbed")
	_check(not Redactor.redact('{"refresh_token":"refresh-value-123456"}').contains("refresh-value"), "JSON token fields are scrubbed")
	_check(Redactor.redact("sk-abcdefghijklmnopqrstuvwxyz012345") == "[REDACTED]", "standalone provider keys are scrubbed")
	var jwt := "abcdefghijkl.mnopqrstuvwx.yz0123456789"
	_check(Redactor.redact(jwt) == "[REDACTED]", "JWT-shaped tokens are scrubbed")
	Redactor.register_secret("short")
	_check(Redactor.redact("a short diagnostic") == "a [REDACTED] diagnostic", "even a short explicitly registered credential is replaced")
	var nested: Variant = Redactor.redact_variant({"message": exact, "items": ["x", "api_key=abcdefghijklmnop"]})
	_check(nested is Dictionary and not JSON.stringify(nested).contains(exact), "structured diagnostics retain shape without registered secrets")


func _test_store() -> void:
	_check(Store.backend_status()["encrypted"] == false, "the fallback never claims encryption")
	_check(Store.set_secret("api", "one", "credential-one-123456"), "a credential writes successfully")
	_check(Store.get_secret("api", "one") == "credential-one-123456", "the written credential reads back")
	var disk := FileAccess.open(TEST_PATH, FileAccess.READ)
	var on_disk := disk.get_as_text() if disk != null else ""
	disk = null # Windows locks an open file against the atomic rename below.
	_check(on_disk.contains("credential-one-123456"), "the documented plaintext fallback is honest on disk")
	_check(Store.replace_namespace("api", {"two": "credential-two-123456"}), "a namespace replaces atomically")
	_check(Store.get_secret("api", "one") == "" and Store.get_secret("api", "two") == "credential-two-123456", "replacement removes orphaned credentials")
	Redactor.clear_registered()
	Store.get_namespace("api")
	_check(Redactor.redact("credential-two-123456") == "[REDACTED]", "loading a credential namespace registers its direct string values")
	_check(not FileAccess.file_exists(TEST_PATH + ".tmp") and not FileAccess.file_exists(TEST_PATH + ".previous"), "successful replacement leaves no temporary credential copy")
	_cleanup()


func _test_source_split() -> void:
	var legacy := [
		{"id": "alpha", "name": "A", "api_key": "alpha-secret-123456"},
		{"id": "beta", "name": "B", "api_key": ""},
	]
	var split := Sources._split_keys(legacy, {"beta": "stale-beta-secret", "kept": "still-present"})
	_check(split["found_plaintext"] == true, "legacy plaintext is detected")
	_check(split["keys"].get("alpha") == "alpha-secret-123456", "legacy keys move into the credential map")
	_check(not split["keys"].has("beta") and split["keys"].has("kept"), "an explicitly cleared key is removed without dropping unrelated stored keys")
	_check(not JSON.stringify(split["metadata"]).contains("api_key") and not JSON.stringify(split["metadata"]).contains("alpha-secret"), "persisted source metadata contains no key field or value")


func _test_output_boundaries() -> void:
	Redactor.clear_registered()
	var secret := "boundary-secret-123456"
	Redactor.register_secret(secret)
	_check(not Console.format_output("safe\nAuthorization: Bearer %s" % secret, 0, "").contains(secret), "console output is redacted before relay")
	_check(not Console.format_errors([{"kind": "error", "time": "t", "title": secret, "detail": []}], 0, "").contains(secret), "debugger errors are redacted before relay")
	var client := Client.new()
	var failures: Array[String] = []
	client.request_failed.connect(func(reason: String) -> void: failures.append(reason))
	client._emit_request_failed("provider echoed %s" % secret)
	var failure := failures[0] if not failures.is_empty() else ""
	_check(not failure.contains(secret) and failure.contains("[REDACTED]"), "HTTP failure signals redact registered credentials")
	var session_store := SessionStore.new()
	session_store.active_id = "one"
	session_store.sessions = [{"id": "one", "history": [{"role": "user", "content": "sent %s" % secret}]}]
	var persisted := JSON.stringify(session_store._persistence_payload())
	_check(not persisted.contains(secret) and persisted.contains("[REDACTED]"), "session serialization redacts registered credentials in histories")
	client.free()


func _cleanup() -> void:
	for suffix in ["", ".tmp", ".previous"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(TEST_PATH + suffix)
