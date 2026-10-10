extends SceneTree
## Headless regression tests for immutable, fail-closed session authority.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/capabilities_test.gd

const GDLLMCapabilities = preload("res://addons/gdllm-godot-agentic-harness/gdllm_capabilities.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_denied_set()
	_test_session_mapping()
	_test_outer_tools_gate()
	_test_fail_closed_shapes()
	_test_snapshot_is_not_authority()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: %s" % label)


func _test_denied_set() -> void:
	var capabilities := GDLLMCapabilities.none()
	_check(GDLLMCapabilities.is_valid(capabilities), "the denied set is a complete valid boundary object")
	_check(capabilities.is_read_only(), "the denied set is immutable")
	for capability in GDLLMCapabilities.ALL:
		_check(not GDLLMCapabilities.permits(capabilities, capability), "the denied set refuses %s" % capability)


func _test_session_mapping() -> void:
	var capabilities := GDLLMCapabilities.from_session(true, true, true, true, true)
	_check(GDLLMCapabilities.is_valid(capabilities), "a session snapshot is valid and read-only")
	for capability in GDLLMCapabilities.ALL:
		_check(GDLLMCapabilities.permits(capabilities, capability), "the fully opted-in session grants %s" % capability)
	var no_edits := GDLLMCapabilities.from_session(true, false, true, false, false)
	_check(GDLLMCapabilities.permits(no_edits, GDLLMCapabilities.READ_PROJECT), "tools grant project reads")
	_check(GDLLMCapabilities.permits(no_edits, GDLLMCapabilities.CONTROL_EDITOR), "tools grant editor control")
	_check(not GDLLMCapabilities.permits(no_edits, GDLLMCapabilities.DELETE_FILES), "delete cannot outlive mutation")
	_check(not GDLLMCapabilities.permits(no_edits, GDLLMCapabilities.MUTATE_PROJECT_SETTINGS), "project settings cannot outlive mutation")
	_check(not GDLLMCapabilities.permits(no_edits, GDLLMCapabilities.RUN_PROJECT_CODE), "execution stays independently off")


func _test_outer_tools_gate() -> void:
	var capabilities := GDLLMCapabilities.from_session(false, true, true, true, true)
	for capability in GDLLMCapabilities.ALL:
		_check(not GDLLMCapabilities.permits(capabilities, capability), "tools-off refuses stale %s consent" % capability)


func _test_fail_closed_shapes() -> void:
	var mutable := {}
	for capability in GDLLMCapabilities.ALL:
		mutable[capability] = true
	_check(not GDLLMCapabilities.is_valid(mutable), "a mutable dictionary is not authority")
	_check(not GDLLMCapabilities.permits(mutable, GDLLMCapabilities.READ_PROJECT), "mutable authority fails closed")
	mutable.erase(GDLLMCapabilities.DELETE_FILES)
	mutable.make_read_only()
	_check(not GDLLMCapabilities.is_valid(mutable), "a missing key fails the whole set closed")
	var unknown := GDLLMCapabilities.none().duplicate(true)
	unknown["future_unreviewed_capability"] = true
	unknown.make_read_only()
	_check(not GDLLMCapabilities.is_valid(unknown), "an unknown key fails the whole set closed")
	_check(not GDLLMCapabilities.permits(GDLLMCapabilities.none(), "future_unreviewed_capability"), "an unknown requested capability is denied")


func _test_snapshot_is_not_authority() -> void:
	var capabilities := GDLLMCapabilities.from_session(true, true, false, false, false)
	var snapshot := GDLLMCapabilities.snapshot(capabilities)
	_check(not snapshot.is_read_only(), "a persistence snapshot is intentionally mutable")
	_check(not GDLLMCapabilities.permits(snapshot, GDLLMCapabilities.MUTATE_PROJECT), "a JSON-shaped snapshot cannot be reused as authority")
	snapshot[GDLLMCapabilities.DELETE_FILES] = true
	_check(not GDLLMCapabilities.permits(snapshot, GDLLMCapabilities.DELETE_FILES), "mutating a snapshot cannot widen authority")
