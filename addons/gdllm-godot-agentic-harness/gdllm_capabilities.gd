@tool
class_name GDLLMCapabilities
extends RefCounted
## Immutable, fail-closed authority carried from one chat session through every subagent and tool dispatch.
## A capability name is useful only inside a complete read-only set produced here: missing, unknown, mutable, or internally inconsistent dictionaries grant nothing.

const READ_PROJECT := "read_project"
const READ_EXTERNAL := "read_external"
const RUN_PROJECT_CODE := "run_project_code"
const CONTROL_EDITOR := "control_editor"
const MUTATE_PROJECT := "mutate_project"
const DELETE_FILES := "delete_files"
const MUTATE_PROJECT_SETTINGS := "mutate_project_settings"

const ALL := [
	READ_PROJECT,
	READ_EXTERNAL,
	RUN_PROJECT_CODE,
	CONTROL_EDITOR,
	MUTATE_PROJECT,
	DELETE_FILES,
	MUTATE_PROJECT_SETTINGS,
]


## Build the authority for one session snapshot. `tools_enabled` is the outer gate; every capability is false when tools are off, irrespective of stale pressed states in hidden controls.
static func from_session(tools_enabled: bool, make_changes: bool, delete_files: bool, run_project_code: bool, read_external: bool) -> Dictionary:
	var capabilities := _blank()
	if tools_enabled:
		capabilities[READ_PROJECT] = true
		capabilities[READ_EXTERNAL] = read_external
		capabilities[RUN_PROJECT_CODE] = run_project_code
		capabilities[CONTROL_EDITOR] = true
		capabilities[MUTATE_PROJECT] = make_changes
		capabilities[DELETE_FILES] = make_changes and delete_files
		capabilities[MUTATE_PROJECT_SETTINGS] = make_changes
	return _freeze(capabilities)


## A completely denied set, still carrying the full schema so downstream code never has to infer what an absent key meant.
static func none() -> Dictionary:
	return _freeze(_blank())


## Whether `capability` is granted. Unknown names and any malformed or mutable set fail closed.
static func permits(capabilities: Dictionary, capability: String) -> bool:
	if not is_valid(capabilities) or not (capability in ALL):
		return false
	return bool(capabilities[capability])


## Validate the boundary object itself, not just the requested key. This prevents a caller from smuggling one true key in a partial dictionary or widening a set after it was handed to a subagent.
static func is_valid(capabilities: Dictionary) -> bool:
	if not capabilities.is_read_only() or capabilities.size() != ALL.size():
		return false
	for key in ALL:
		if not capabilities.has(key) or not (capabilities[key] is bool):
			return false
	for key in capabilities:
		if not (String(key) in ALL):
			return false
	if bool(capabilities[READ_EXTERNAL]) and not bool(capabilities[READ_PROJECT]):
		return false
	if bool(capabilities[RUN_PROJECT_CODE]) and not bool(capabilities[READ_PROJECT]):
		return false
	if bool(capabilities[CONTROL_EDITOR]) and not bool(capabilities[READ_PROJECT]):
		return false
	if bool(capabilities[MUTATE_PROJECT]) and not bool(capabilities[READ_PROJECT]):
		return false
	if bool(capabilities[DELETE_FILES]) and not bool(capabilities[MUTATE_PROJECT]):
		return false
	if bool(capabilities[MUTATE_PROJECT_SETTINGS]) and not bool(capabilities[MUTATE_PROJECT]):
		return false
	return true


## A serializable copy for display-only history stamps. It is deliberately mutable because JSON persistence does not preserve Dictionary read-only state; never pass it back into dispatch without rebuilding through from_session.
static func snapshot(capabilities: Dictionary) -> Dictionary:
	if not is_valid(capabilities):
		return _blank()
	return capabilities.duplicate(true)


static func _blank() -> Dictionary:
	var capabilities := {}
	for key in ALL:
		capabilities[key] = false
	return capabilities


static func _freeze(capabilities: Dictionary) -> Dictionary:
	capabilities.make_read_only()
	return capabilities
