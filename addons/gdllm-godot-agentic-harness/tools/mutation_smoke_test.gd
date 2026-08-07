extends SceneTree
## Headless regression tests for the mutating chat tools — edit_file, write_file, move_file, rename_file, copy_file, edit_resource, create_resource — and the "Make changes" gate around them.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/mutation_smoke_test.gd
## Exits nonzero on any failure. Editor-only behavior (open-scene reloads and their dirty-tab skip, the unsaved-resource sweep) can't run headless and is exercised in the editor instead.

const TMP_DIR := "res://__gdllm_smoke_tmp"

const MUTATING_TOOLS := ["edit_file", "write_file", "move_file", "rename_file", "copy_file", "edit_resource", "create_resource"]

const RES_SCRIPT := """extends Resource
@export var speed: float = 1.0
@export var count: int = 0
@export var active: bool = false
@export var offset: Vector2 = Vector2.ZERO
@export var tint: Color = Color.WHITE
@export var mat: Material
@export var tags: PackedStringArray = []
"""

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	_test_synchronous_headless()
	_test_gating()
	_test_seen_gate()
	_test_edit_file()
	_test_edit_file_scene_validation()
	_test_scene_unknown_property_warning()
	_test_write_file()
	_test_delete_file()
	_test_move_rename()
	_test_copy_file()
	_test_ws_fallback_and_stale()
	_test_dependent_check()
	_test_grouped_problems()
	_test_script_declarations()
	_test_edit_resource()
	_test_create_resource()
	_test_inline_subresource()
	_test_uid_lint()
	_test_uid_ref_block()
	_test_uid_ledger_substitution()
	_test_ext_resource_uid_canonicalized()
	_test_uid_error_attribution()
	_test_reverse_uid_lookup()
	_test_uid_path_input()
	_test_load_error_display()
	_test_auto_check_collapse()
	_test_load_check_fresh_uid()
	_test_broken_reminder()
	_test_not_found_closest_region()
	_test_script_swap_preserves()
	_test_engine_checked_clause()
	_test_unvalidated_check_detection()
	_test_creation_uid_disclosure()
	_test_check_script_unchanged_framing()
	_test_error_classification()
	_test_edit_ledger_demotion()
	_test_scene_divergence_note()
	_test_class_spec_matching()
	_cleanup()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real dispatch (including the mutating and destructive gates) and return the model-facing content.
func _run(tool_name: String, args: Dictionary, allow_changes: bool, allow_delete: bool = false) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes, allow_delete)).get("content", ""))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## Pin the dual-mode contract every test here leans on: execute is a coroutine, but its suspension points all sit behind Engine.is_editor_hint(), so headless an await resolves in place and this _init-driven suite runs synchronously. If that breaks, the suite strands at the first await and never reaches quit() — the hang itself is the failure signal — while this check pins the resolved shape.
func _test_synchronous_headless() -> void:
	var raw: Variant = await GDLLMTools.execute("read_file", {"path": "res://project.godot"})
	_check(raw is Dictionary, "await execute resolves to the result Dictionary headless (got %s)" % type_string(typeof(raw)))


func _test_gating() -> void:
	for tool_name in MUTATING_TOOLS:
		_check(GDLLMTools.is_mutating(tool_name), "%s is flagged mutating" % tool_name)
		_check((await _run(tool_name, {}, false)).begins_with("Error: \"%s\" modifies the project" % tool_name), "%s refused while Make changes is off" % tool_name)
	_check(not GDLLMTools.is_mutating("read_file"), "read_file is not flagged mutating")
	var off_catalog := String(GDLLMTools.tool_search_schema(false)["function"]["description"])
	_check(not off_catalog.contains("edit_file("), "catalog hides mutating tools while off")
	_check(off_catalog.contains("hidden because the user's \"Make changes\" toggle is off"), "catalog notes the hidden tools while off")
	var on_catalog := String(GDLLMTools.tool_search_schema(true)["function"]["description"])
	for tool_name in MUTATING_TOOLS:
		_check(on_catalog.contains(tool_name + "("), "catalog lists %s while on" % tool_name)
	_check(not on_catalog.contains("\"Make changes\" toggle is off"), "catalog drops the mutating hidden-tools note while on")
	var found_off := GDLLMTools.search("edit file", false).any(func(e: Dictionary) -> bool: return e["name"] == "edit_file")
	var found_on := GDLLMTools.search("edit file", true).any(func(e: Dictionary) -> bool: return e["name"] == "edit_file")
	_check(not found_off, "search excludes mutating tools while off")
	_check(found_on, "search returns mutating tools while on")


## The read-before-edit gate: edit_file refuses a file whose real text was never shown, and each verbatim view — read_file, read_function, search_files excerpts, the model's own write_file — unlocks it; a shape-only view does not.
func _test_seen_gate() -> void:
	var s1 := TMP_DIR + "/gate_search.txt"
	_write(s1, "alpha needle_gate here\nomega\n")
	var out := await _run("edit_file", {"path": s1, "old_string": "omega", "new_string": "OMEGA"}, true)
	_check(out.contains("have not read"), "edit_file refuses a file never shown")
	_check(_read(s1).contains("omega"), "the refused edit touched nothing")
	await _run("search_files", {"query": "needle_gate", "path": s1}, false)
	out = await _run("edit_file", {"path": s1, "old_string": "omega", "new_string": "OMEGA"}, true)
	_check(out.begins_with("Edited"), "search_files excerpts unlock edit_file")
	var s2 := TMP_DIR + "/gate_func.gd"
	_write(s2, "extends RefCounted\n\n\nfunc gate() -> int:\n\treturn 10\n")
	out = await _run("edit_file", {"path": s2, "old_string": "return 10", "new_string": "return 11"}, true)
	_check(out.contains("have not read"), "edit_file refuses a .gd never shown")
	await _run("read_function", {"path": s2, "name": "gate"}, false)
	out = await _run("edit_file", {"path": s2, "old_string": "return 10", "new_string": "return 11"}, true)
	_check(out.begins_with("Edited"), "read_function unlocks edit_file")
	var s3 := TMP_DIR + "/gate_map.txt"
	_write(s3, "alpha\nbeta\n")
	GDLLMTools._fallback_ledger.seen_files[s3] = false
	out = await _run("edit_file", {"path": s3, "old_string": "alpha", "new_string": "ALPHA"}, true)
	_check(out.contains("map/overview"), "a shape-only view still refuses and says why")
	var s4 := TMP_DIR + "/gate_written.txt"
	await _run("write_file", {"path": s4, "content": "written once\n"}, true)
	out = await _run("edit_file", {"path": s4, "old_string": "once", "new_string": "twice"}, true)
	_check(out.begins_with("Edited"), "write_file grounds follow-up edits without a read")


func _test_edit_file() -> void:
	var txt := TMP_DIR + "/sample.txt"
	_write(txt, "line one\nbeta\nline three\nbeta\nline five\n")
	await _run("read_file", {"path": txt}, false)
	var out := await _run("edit_file", {"path": txt, "old_string": "line one", "new_string": "LINE ONE"}, true)
	_check(out.begins_with("Edited"), "edit_file unique replace confirms")
	_check(_read(txt).contains("LINE ONE"), "edit_file unique replace hit disk")
	out = await _run("edit_file", {"path": txt, "old_string": "zeta", "new_string": "x"}, true)
	_check(out.contains("was not found"), "edit_file 0-match errors")
	out = await _run("edit_file", {"path": txt, "old_string": " line three ", "new_string": "LINE THREE"}, true)
	_check(out.begins_with("Edited") and out.contains("whitespace"), "edit_file whitespace-drifted old_string is applied with disclosure")
	_check(_read(txt).contains("LINE THREE"), "the tolerant match hit disk")
	out = await _run("edit_file", {"path": txt, "old_string": "beta", "new_string": "x"}, true)
	_check(out.contains("matches 2 places"), "edit_file ambiguity errors with the count")
	out = await _run("edit_file", {"path": txt, "old_string": "beta", "new_string": "BETA", "replace_all": true}, true)
	_check(_read(txt).count("BETA") == 2, "edit_file replace_all replaced both")
	# A deletion's excerpt must anchor at the deleted region, not the top of the file; the file is longer than the excerpt window so the two are distinguishable.
	var del := TMP_DIR + "/deletion.txt"
	_write(del, "l01\nl02\nl03\nl04\nl05\nl06\nl07\nl08\nl09\nl10\nl11\nl12\n")
	await _run("read_file", {"path": del}, false)
	out = await _run("edit_file", {"path": del, "old_string": "l08\n", "new_string": ""}, true)
	_check(not _read(del).contains("l08"), "edit_file deletion hit disk")
	_check(out.contains("l07") and not out.contains("l01"), "edit_file deletion excerpt anchors at the deleted region")
	# A long replacement's echo is the model's own new_string paid twice, so the excerpt windows it: head and tail with real line numbers, the middle counted.
	var big := TMP_DIR + "/big_replace.txt"
	_write(big, "top\nREPLACE_ME\nbottom\n")
	await _run("read_file", {"path": big}, false)
	var wall := PackedStringArray()
	for i in range(30):
		wall.append("wall_%02d" % i)
	out = await _run("edit_file", {"path": big, "old_string": "REPLACE_ME", "new_string": "\n".join(wall)}, true)
	_check(out.contains("wall_00") and out.contains("wall_29"), "a long replacement's excerpt keeps its head and tail")
	_check(not out.contains("wall_15"), "the middle of a long replacement is not echoed back")
	_check(out.contains("10 changed lines (12-21) not repeated"), "the omitted middle is counted with its line span")
	_check(_read(big).contains("wall_15"), "the windowed echo is display-only; every line hit disk")
	var gd := TMP_DIR + "/sample_script.gd"
	_write(gd, "extends RefCounted\n\n\nfunc ok() -> int:\n\treturn 1\n")
	await _run("read_file", {"path": gd}, false)
	out = await _run("edit_file", {"path": gd, "old_string": "return 1", "new_string": "return ("}, true)
	_check(out.contains("BROKEN"), "edit_file .gd parse break reports the file as broken")
	_check(out.contains("line "), "edit_file .gd parse errors carry line numbers")
	_check(out.contains("Offending region"), "edit_file .gd parse errors excerpt the offending lines")
	_check(_read(gd).contains("return ("), "edit_file .gd parse break keeps the edit on disk")
	out = await _run("edit_file", {"path": gd, "old_string": "return (", "new_string": "return 2 "}, true)
	_check(out.contains("style-lint problem"), "edit_file .gd new lint problem is reported")
	_check(_read(gd).contains("return 2"), "edit_file repairs the broken script and keeps the fix")


func _test_write_file() -> void:
	var out := await _run("write_file", {"path": TMP_DIR + "/subdir/new.txt", "content": "hello\nworld\n"}, true)
	_check(out.begins_with("Created"), "write_file creates a new file with directories")
	_check(_read(TMP_DIR + "/subdir/new.txt") == "hello\nworld\n", "write_file content hit disk verbatim")
	out = await _run("write_file", {"path": TMP_DIR + "/subdir/new.txt", "content": "other"}, true)
	_check(out.begins_with("Overwrote") and _read(TMP_DIR + "/subdir/new.txt") == "other", "write_file replaces an existing file by default")
	out = await _run("write_file", {"path": TMP_DIR + "/noext", "content": "x"}, true)
	_check(out.contains("extension"), "write_file requires an extension")
	out = await _run("write_file", {"path": "res://../fence_escape.txt", "content": "x"}, true)
	_check(out.contains("OUTSIDE the project"), "write_file's literal destination is fenced — a res://../ escape writes nothing")
	out = await _run("create_resource", {"from": "Resource", "path": "res://../fence_escape.tres"}, true)
	_check(out.contains("OUTSIDE the project"), "create_resource's destination is fenced the same way")
	# user:// sits inside the fence: a NEW user:// file is created where it says, sidecar-free (uids belong to the project tree), and stays editable and deletable.
	out = await _run("write_file", {"path": "user://gdllm_smoke_user.gd", "content": "extends RefCounted\nvar n := 1\n"}, true)
	_check(out.begins_with("Created") and FileAccess.file_exists("user://gdllm_smoke_user.gd"), "write_file creates a new user:// file at the spelled path")
	_check(out.contains("UNVALIDATED"), "a user:// script write says the engine validation did not run")
	_check(not FileAccess.file_exists("user://gdllm_smoke_user.gd.uid"), "no .uid sidecar is minted outside res:// — uids belong to the project tree")
	out = await _run("edit_file", {"path": "user://gdllm_smoke_user.gd", "old_string": "var n := 1", "new_string": "var n := 2"}, true)
	_check(out.begins_with("Edited") and _read("user://gdllm_smoke_user.gd").contains("var n := 2"), "edit_file edits a user:// file")
	_check(out.contains("UNVALIDATED"), "a user:// edit is disclosed as unvalidated too")
	_check(not FileAccess.file_exists("user://gdllm_smoke_user.gd.uid"), "the user:// edit minted no .uid sidecar — the lints are project-tree services")
	# The automatic check hook is a project-tree service too: a non-project script gets no verdict issued from this project's context.
	out = await _run("write_file", {"path": "user://gdllm_smoke_user.gd", "content": "extends RefCounted\nfunc broken( -> void:\n"}, true)
	_check(out.contains("UNVALIDATED"), "a broken non-project script still lands, disclosed as unvalidated")
	out = await _run("read_file", {"path": "user://gdllm_smoke_user.gd"}, false)
	_check(not out.contains("Automatic check_script"), "no automatic check verdict is issued for a non-project script")
	out = await _run("delete_file", {"path": "user://gdllm_smoke_user.gd", "force": true}, true, true)
	_check(out.begins_with("Deleted") and not FileAccess.file_exists("user://gdllm_smoke_user.gd"), "delete_file removes a user:// file")
	# A user:// write whose content declares a uid header lands as sent, and the confirmation must not present that header as an engine-assigned uid.
	var user_uid_res := "user://gdllm_smoke_" + "wr_uid.tres"
	out = await _run("write_file", {"path": user_uid_res, "content": "[gd_resource type=\"Resource\" format=3 uid=\"uid://smokeinvented\"]\n\n[resource]\n"}, true)
	_check(_read(user_uid_res).contains("uid://smokeinvented"), "the user:// content landed exactly as sent, uid header included")
	_check(out.contains("uid://smokeinvented") and out.contains("inert"), "the confirmation discloses the header uid as unverified inert text")
	_check(not out.contains("its uid is"), "the confirmation never presents the header as the file's engine uid")
	DirAccess.remove_absolute(user_uid_res)
	# The critical stores are refused by the WRITE path too, not only delete/move/copy — the session records are the transparency ledger.
	out = await _run("write_file", {"path": "user://gdllm/sessions.json", "content": "{}", "force": true}, true)
	_check(out.contains("critical store"), "write_file refuses the session records even with force")
	_check(GDLLMTools._critical_store_guard("user://gdllm/sessions.json", "edits") != "", "the shared critical-store guard answers for the edit path")
	out = await _run("create_resource", {"from": "Resource", "path": "user://gdllm/evil.tres"}, true)
	_check(out.contains("critical store"), "create_resource refuses a destination inside the session records")
	DirAccess.make_dir_recursive_absolute("user://gdllm")
	ResourceSaver.save(Resource.new(), "user://gdllm/gdllm_smoke_probe.tres")
	out = await _run("edit_resource", {"path": "user://gdllm/gdllm_smoke_probe.tres", "properties": {"resource_name": "x"}}, true)
	_check(out.contains("critical store"), "edit_resource refuses a resource inside the session records — every mutating tool consults the one guard")
	DirAccess.remove_absolute("user://gdllm/gdllm_smoke_probe.tres")
	# The scene/animation splice tools mutate files too, so they consult the same guard before their type gate — project.godot resolves and would otherwise reach the "not a .tscn" refusal instead.
	out = await _run("edit_tilemap", {"scene": "res://project.godot", "erase": [[0, 0]]}, true)
	_check(out.contains("critical store"), "edit_tilemap refuses a critical store ahead of its scene-type gate")
	out = await _run("edit_animation", {"scene": "res://project.godot", "set_length": {"name": "x", "length": 1.0}}, true)
	_check(out.contains("critical store"), "edit_animation refuses a critical store ahead of its file-type gate")
	_check(GDLLMTools._in_critical_store("res://.godot"), "res://.godot itself is critical, matched exactly like .git")
	out = await _run("write_file", {"path": "res://.godot", "content": "x"}, true)
	_check(out.contains("critical store") and not FileAccess.file_exists("res://.godot"), "a FILE named .godot can never be created at the project root")
	# check_script carries the hook's project-side gate: a non-project script gets no verdict from this project's context.
	_write("user://gdllm_smoke_check.gd", "extends RefCounted\n")
	out = await _run("check_script", {"path": "user://gdllm_smoke_check.gd"}, false)
	_check(out.begins_with("Error") and out.contains("ungroundable"), "check_script refuses a non-project script instead of judging it with this project's autoloads")
	DirAccess.remove_absolute("user://gdllm_smoke_check.gd")
	# A user:// directory handed to a file tool is named as one — the diagnosis runs on any fenced tree.
	DirAccess.make_dir_recursive_absolute("user://gdllm_smoke_probe_dir")
	out = await _run("delete_file", {"path": "user://gdllm_smoke_probe_dir", "force": true}, true, true)
	_check(out.contains("is a directory"), "a user:// directory is named as a directory, not reported missing")
	DirAccess.remove_absolute("user://gdllm_smoke_probe_dir")
	# Case-folded compares where the VOLUME resolves names case-insensitively: the same file in another case is the same file. The override forces both verdicts on one machine; production probes the volume itself (see _root_case_insensitive).
	GDLLMTools._fs_case_override = true
	var case_root := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	_check(GDLLMTools._path_is_or_under(case_root.to_upper() + "/player.gd", case_root), "a case-variant in-project path reads as inside on a case-insensitive volume")
	_check(GDLLMTools._in_critical_store(case_root + "/.GIT/config"), "a case-variant spelling of a critical store is still critical there")
	GDLLMTools._fs_case_override = false
	_check(not GDLLMTools._path_is_or_under(case_root.to_upper() + "/player.gd", case_root), "a case-sensitive volume keeps the exact compare")
	GDLLMTools._fs_case_override = null
	GDLLMTools._case_probe_cache.clear()
	_check(GDLLMTools._path_is_or_under(case_root + "/player.gd", case_root), "the probed verdict never breaks the exact-case compare")
	_check(GDLLMTools._root_case_insensitive(case_root) == GDLLMTools._root_case_insensitive(case_root), "the volume probe is stable across calls")
	# With the fence dropped, a NEW absolute destination is honored literally instead of being re-rooted into the project.
	var w_root := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var w_outside := w_root.path_join("..").simplify_path().path_join("gdllm_smoke_abs_write.txt")
	GDLLMSettings.headless_allow_outside_tool_calls = true
	out = await _run("write_file", {"path": w_outside, "content": "outside\n"}, true)
	_check(out.begins_with("Created") and out.contains(w_outside) and FileAccess.file_exists(w_outside), "with the fence dropped, write_file creates a new file at the absolute path it was given")
	_check(not FileAccess.file_exists("res://" + w_outside.trim_prefix("/")), "nothing was re-rooted into the project")
	GDLLMSettings.headless_allow_outside_tool_calls = false
	DirAccess.remove_absolute(w_outside)
	var gd := TMP_DIR + "/written.gd"
	out = await _run("write_file", {"path": gd, "content": "extends RefCounted\n\n\nfunc twice(x: int) -> int:\n\treturn x * 2\n"}, true)
	_check(out.begins_with("Created"), "write_file creates a valid .gd")
	out = await _run("write_file", {"path": TMP_DIR + "/broken.gd", "content": "extends RefCounted\n\n\nfunc broken( -> int:\n"}, true)
	_check(out.contains("BROKEN") and FileAccess.file_exists(TMP_DIR + "/broken.gd"), "write_file keeps a new .gd that fails the parse check and says so")
	_check(out.contains("line "), "write_file parse errors carry line numbers")
	_check(out.contains("Offending region"), "write_file parse errors excerpt the offending lines")
	out = await _run("write_file", {"path": gd, "content": "extends RefCounted\n\n\nfunc broken( -> int:\n"}, true)
	_check(out.contains("BROKEN") and _read(gd).contains("func broken("), "a replacement that fails the parse check still lands")
	out = await _run("edit_file", {"path": gd, "old_string": "func broken( -> int:\n", "new_string": "func broken() -> int:\n\treturn 1\n"}, true)
	_check(out.begins_with("Edited") and _read(gd).contains("return 1"), "edit_file repairs the broken script write_file left")
	out = await _run("write_file", {"path": TMP_DIR + "/linty.gd", "content": "extends RefCounted\n\n\nfunc padded() -> int:\n\treturn 3 \n"}, true)
	_check(out.contains("style-lint problem") and FileAccess.file_exists(TMP_DIR + "/linty.gd"), "write_file keeps a .gd with only lint problems and notes them")
	var bad_scn := TMP_DIR + "/bad_written.tscn"
	out = await _run("write_file", {"path": bad_scn, "content": "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node2D\"]\nmodulate = Color(\"c7fcff\")\n"}, true)
	_check(out.contains("BROKEN") and out.contains("Offending region") and out.contains("modulate = Color(\"c7fcff\")"), "write_file .tscn load break excerpts the culprit line")
	out = await _run("edit_file", {"path": bad_scn, "old_string": "modulate = Color(\"c7fcff\")\n", "new_string": ""}, true)
	_check(out.begins_with("Edited"), "the broken scene write_file leftover is repaired")
	# Repair the deliberately broken file so its BROKEN ledger entry doesn't nag every later test through the broken_reminder hook.
	out = await _run("edit_file", {"path": TMP_DIR + "/broken.gd", "old_string": "func broken( -> int:\n", "new_string": "func broken() -> int:\n\treturn 1\n"}, true)
	_check(out.begins_with("Edited"), "the broken write_file leftover is repaired")


## The delete_file tool and its "Delete files" gate: destructive tools hide behind their own toggle even while Make changes is on, deletion removes sidecars and settles the ledger, and a still-referenced file refuses without force.
func _test_delete_file() -> void:
	_check(GDLLMTools.is_destructive("delete_file"), "delete_file is flagged destructive")
	_check(GDLLMTools.is_mutating("delete_file"), "delete_file is also flagged mutating")
	_check(not GDLLMTools.is_destructive("edit_file"), "edit_file is not flagged destructive")
	var changes_only := String(GDLLMTools.tool_search_schema(true)["function"]["description"])
	_check(not changes_only.contains("delete_file("), "catalog hides delete_file while Delete files is off")
	_check(changes_only.contains("\"Delete files\" toggle is off"), "catalog notes the hidden delete tools while only edits are on")
	var both := String(GDLLMTools.tool_search_schema(true, true)["function"]["description"])
	_check(both.contains("delete_file(") and not both.contains("hidden because"), "catalog lists delete_file and drops every hidden note with both toggles on")
	_check(GDLLMTools.search("delete_file", true).is_empty(), "search hides delete_file by exact name while Delete files is off")
	_check(GDLLMTools.search("delete_file", true, true).size() == 1, "search returns delete_file with both toggles on")
	var out := await _run("delete_file", {"path": "res://project.godot"}, true)
	_check(out.begins_with("Error: \"delete_file\" deletes project files"), "delete_file is refused while Delete files is off, naming its toggle")
	out = await _run("delete_file", {"path": "res://project.godot"}, false)
	_check(out.begins_with("Error: \"delete_file\" modifies the project"), "the Make changes gate still fronts the delete gate")
	# An unreferenced file deletes, sidecar included, and a repeat errors instead of pretending.
	var doomed := TMP_DIR + "/doomed.gd"
	_write(doomed, "extends RefCounted\n")
	# Assembled at runtime so the reference scan never matches this file's own source on the sidecar's uid text.
	_write(doomed + ".uid", "uid://" + "placeholder" + "\n")
	out = await _run("delete_file", {"path": doomed}, true, true)
	_check(out.begins_with("Deleted " + doomed), "delete_file deletes an unreferenced file")
	_check(not FileAccess.file_exists(doomed), "the file is gone from the project")
	_check(not FileAccess.file_exists(doomed + ".uid"), "the .uid sidecar went with it")
	_check(out.contains("doomed.gd.uid"), "the sidecar removal is disclosed")
	out = await _run("delete_file", {"path": doomed}, true, true)
	_check(out.begins_with("Error:"), "deleting a missing file errors")
	# A referenced file refuses, names its users, and force overrides with the same list as a warning.
	var kept := TMP_DIR + "/kept_target.gd"
	_write(kept, "extends RefCounted\n")
	var user := TMP_DIR + "/kept_user.gd"
	_write(user, "extends RefCounted\nconst DEP := preload(\"%s\")\n" % kept)
	out = await _run("delete_file", {"path": kept}, true, true)
	_check(out.begins_with("Error:") and out.contains("NOT deleted") and out.contains(user), "a referenced file refuses deletion and names the referencing file")
	_check(FileAccess.file_exists(kept), "the refused deletion touched nothing")
	out = await _run("delete_file", {"path": kept, "force": true}, true, true)
	_check(out.begins_with("Deleted") and out.contains("WARNING") and out.contains(user), "force deletes anyway, carrying the same list as a warning")
	_check(not FileAccess.file_exists(kept), "the forced deletion hit disk")
	# The dangling preload must not pollute later validation runs in this suite.
	DirAccess.remove_absolute(user)
	# A class_name still used by name blocks the deletion too (assembled at runtime so this file never word-matches it).
	var cname := "GdllmSmokeDelete" + "Probe"
	var named := TMP_DIR + "/named_target.gd"
	_write(named, "class_name %s\nextends RefCounted\n" % cname)
	var name_user := TMP_DIR + "/named_user.gd"
	_write(name_user, "extends RefCounted\n# builds on %s\n" % cname)
	out = await _run("delete_file", {"path": named}, true, true)
	_check(out.begins_with("Error:") and out.contains(name_user), "a class_name still used by name blocks the deletion")
	# Containment: a path escaping the project and user:// is refused before the scan, force can't override it, and the refusal names the setting that would lift it.
	var root_abs := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var outside_abs := root_abs.path_join("..").simplify_path().path_join("gdllm_outside_sentinel.txt")
	_write(outside_abs, "outside")
	out = await _run("delete_file", {"path": "res://../gdllm_outside_sentinel.txt", "force": true}, true, true)
	_check(out.contains("OUTSIDE the project"), "a res://../ traversal is refused as outside the project")
	_check(out.contains("Allow Tool Calls Outside"), "the refusal names the setting that would lift the fence")
	_check(FileAccess.file_exists(outside_abs), "the out-of-project file was not touched, even with force")
	# The guard itself, unit-tested so the dangerous targets never risk a real deletion inside this suite.
	_check(GDLLMTools._delete_target_guard("res://../secret.txt").contains("OUTSIDE"), "the guard refuses a .. escape")
	_check(GDLLMTools._delete_target_guard("res://..\\secret.txt").contains("OUTSIDE"), "a backslash spelling of the same escape is refused too")
	_check(GDLLMTools._delete_target_guard("user://save.tres") == "", "a user:// path is inside the fence — the user's data directory is the model's to work in")
	_check(GDLLMTools._delete_target_guard("res://project.godot").contains("critical"), "the guard refuses project.godot even though it lives under res://")
	_check(GDLLMTools._delete_target_guard("res://.godot/uid_cache.bin").contains("critical"), "the guard refuses a .godot editor-cache file")
	_check(GDLLMTools._delete_target_guard("res://.git/config").contains("critical"), "the guard refuses a .git file")
	_check(GDLLMTools._delete_target_guard("res://.git").contains("critical"), "the guard refuses .git itself — a FILE in a git worktree, whose loss severs the checkout")
	_check(GDLLMTools._delete_target_guard("user://gdllm/sessions.json").contains("critical"), "the plugin's own session records are critical — the transparency record is never the model's to remove")
	_check(GDLLMTools._delete_target_guard(TMP_DIR + "/plain.gd") == "", "the guard passes an ordinary project file")
	# The is-a-directory diagnostic must not speak for a fence-refused path — answering "is a directory" would confirm an outside directory exists.
	var leak_dir := root_abs.path_join("..").simplify_path().path_join("gdllm_leak_probe_dir")
	DirAccess.make_dir_recursive_absolute(leak_dir)
	out = await _run("delete_file", {"path": "res://../gdllm_leak_probe_dir", "force": true}, true, true)
	_check(out.contains("OUTSIDE the project") and not out.contains("is a directory"), "a fence-refused outside directory gets the fence refusal, not an existence-confirming diagnostic")
	DirAccess.remove_absolute(leak_dir)
	# The single toggle drops the fence wholesale — but never the critical-store refusals.
	GDLLMSettings.headless_allow_outside_tool_calls = true
	_check(GDLLMTools._delete_target_guard("res://../secret.txt") == "", "the Allow Outside setting drops the fence")
	_check(GDLLMTools._delete_target_guard("res://.godot/uid_cache.bin").contains("critical"), "the critical stores stay refused with the fence dropped")
	out = await _run("delete_file", {"path": "res://../gdllm_outside_sentinel.txt", "force": true}, true, true)
	_check(out.begins_with("Deleted") and not FileAccess.file_exists(outside_abs), "with the fence dropped, the outside delete goes through end to end")
	GDLLMSettings.headless_allow_outside_tool_calls = false
	DirAccess.remove_absolute(outside_abs)
	# A symlink is the user's own setup: the fence judges the call's text and never chases where a path really leads, so a path through a link works exactly as it does for the user.
	var link_da := DirAccess.open(root_abs)
	var tmp_abs := ProjectSettings.globalize_path(TMP_DIR).simplify_path()
	var sym_out_dir := root_abs.path_join("..").simplify_path().path_join("gdllm_sym_outside")
	DirAccess.make_dir_recursive_absolute(sym_out_dir)
	var sym_victim := sym_out_dir.path_join("victim.txt")
	_write(sym_victim, "victim")
	var link_dir_abs := tmp_abs.path_join("sym_linked")
	_check(link_da.create_link(sym_out_dir, link_dir_abs) == OK, "test setup: a directory symlink is created inside the project")
	var through_path := TMP_DIR + "/sym_linked/victim.txt"
	_check(FileAccess.file_exists(through_path), "test setup: the outside victim is reachable through the link")
	_check(GDLLMTools._delete_target_guard(through_path) == "", "a path through the user's own symlink passes the guard — the fence never chases links")
	out = await _run("delete_file", {"path": through_path, "force": true}, true, true)
	_check(out.begins_with("Deleted"), "a delete through a symlinked directory follows the user's own setup")
	_check(not FileAccess.file_exists(sym_victim), "the delete landed on the link's real target, as that setup intends")
	DirAccess.remove_absolute(link_dir_abs)
	DirAccess.remove_absolute(sym_out_dir)
	# Deleting a broken file settles its ledger entries, so the reminder can't nag about a file that no longer exists.
	GDLLMTools._fallback_ledger.broken_reminder_cooldown = 0
	var broken := TMP_DIR + "/deleted_broken.gd"
	out = await _run("write_file", {"path": broken, "content": "extends RefCounted\n\n\nfunc nope( -> int:\n"}, true)
	_check(out.contains("BROKEN"), "the setup write leaves the file broken")
	out = await _run("delete_file", {"path": broken}, true, true)
	_check(out.begins_with("Deleted"), "a broken file can still be deleted")
	GDLLMTools._fallback_ledger.broken_reminder_cooldown = 0
	out = await _run("write_file", {"path": TMP_DIR + "/after_delete.txt", "content": "x\n"}, true)
	_check(not out.contains("Automatic reminder"), "deleting a broken file settles the broken-file ledger")


## move_file/rename_file: containment refused at BOTH endpoints (force overriding neither), sidecar travel with uid retargeting, the literal-path refusal with force override, uid-only references passing through, the no-overwrite rule, and the ledger claims following the file.
func _test_move_rename() -> void:
	_check(GDLLMTools.is_mutating("move_file") and not GDLLMTools.is_destructive("move_file"), "move_file is mutating but not destructive")
	_check(GDLLMTools.is_mutating("rename_file") and not GDLLMTools.is_destructive("rename_file"), "rename_file is mutating but not destructive")
	# A plain move into a "/"-suffixed directory creates it, and the seen-file claim travels so a follow-up edit needs no re-read.
	var seen := TMP_DIR + "/mv_seen.txt"
	_write(seen, "alpha\nbeta\n")
	await _run("read_file", {"path": seen}, false)
	var out := await _run("move_file", {"path": seen, "to": TMP_DIR + "/mv_sub/"}, true)
	_check(out.begins_with("Moved"), "move_file moves into a created directory")
	_check(not FileAccess.file_exists(seen) and _read(TMP_DIR + "/mv_sub/mv_seen.txt") == "alpha\nbeta\n", "the move hit disk intact")
	out = await _run("edit_file", {"path": TMP_DIR + "/mv_sub/mv_seen.txt", "old_string": "alpha", "new_string": "ALPHA"}, true)
	_check(out.begins_with("Edited"), "the seen-file claim travels with the move — no re-read required")
	# The .uid sidecar travels and the registry is retargeted, so a uid-carrying reference neither blocks the move nor breaks.
	var dep := TMP_DIR + "/mv_dep.gd"
	await _run("write_file", {"path": dep, "content": "extends Resource\n"}, true)
	var dep_uid := _read(dep + ".uid").strip_edges()
	_write(TMP_DIR + "/mv_uid_user.tres", "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" uid=\"%s\" path=\"%s\" id=\"1_a\"]\n\n[resource]\nscript = ExtResource(\"1_a\")\n" % [dep_uid, dep])
	out = await _run("move_file", {"path": dep, "to": TMP_DIR + "/mv_sub/mv_dep.gd"}, true)
	_check(out.begins_with("Moved") and out.contains("keep resolving"), "a uid-carrying ext_resource reference does not block the move")
	_check(FileAccess.file_exists(TMP_DIR + "/mv_sub/mv_dep.gd.uid"), "the .uid sidecar moved with the file")
	_check(ResourceUID.get_id_path(ResourceUID.text_to_id(dep_uid)) == TMP_DIR + "/mv_sub/mv_dep.gd", "the uid registry follows the move")
	_check(out.contains("reference it only by uid"), "the surviving uid reference is counted in the result")
	# A literal-path reference refuses without force and force carries the breakage warning.
	var target := TMP_DIR + "/mv_target.txt"
	_write(target, "data\n")
	var path_user := TMP_DIR + "/mv_path_user.gd"
	_write(path_user, "extends RefCounted\nconst P := \"%s\"\n" % target)
	out = await _run("move_file", {"path": target, "to": TMP_DIR + "/mv_sub/"}, true)
	_check(out.begins_with("Error:") and out.contains("NOT moved") and out.contains(path_user), "a literal-path reference refuses the move and is named")
	_check(FileAccess.file_exists(target), "the refused move touched nothing")
	out = await _run("move_file", {"path": target, "to": TMP_DIR + "/mv_sub/", "force": true}, true)
	_check(out.begins_with("Moved") and out.contains("WARNING") and out.contains(path_user), "force moves anyway, carrying the breakage warning")
	DirAccess.remove_absolute(path_user)
	# Renames stay in place; a directory in new_name steers to move_file instead of guessing.
	out = await _run("rename_file", {"path": TMP_DIR + "/mv_sub/mv_seen.txt", "new_name": "renamed_seen.txt"}, true)
	_check(out.begins_with("Renamed") and _read(TMP_DIR + "/mv_sub/renamed_seen.txt").contains("ALPHA"), "rename_file renames in place")
	out = await _run("rename_file", {"path": TMP_DIR + "/mv_sub/renamed_seen.txt", "new_name": "elsewhere/x.txt"}, true)
	_check(out.begins_with("Error:") and out.contains("move_file"), "a new_name with a foreign directory steers to move_file")
	out = await _run("rename_file", {"path": TMP_DIR + "/mv_sub/renamed_seen.txt", "new_name": "..\\bs_escape.txt"}, true)
	_check(out.begins_with("Error:") and out.contains("move_file") and FileAccess.file_exists(TMP_DIR + "/mv_sub/renamed_seen.txt"), "a backslashed traversal in new_name is caught like the slashed one — a rename never relocates")
	out = await _run("rename_file", {"path": TMP_DIR + "/mv_sub/renamed_seen.txt", "new_name": "renamed_seen.txt"}, true)
	_check(out.begins_with("Error:") and out.contains("nothing to do"), "renaming to the same name errors")
	# Moves never overwrite, force or not.
	_write(TMP_DIR + "/mv_exists.txt", "old\n")
	_write(TMP_DIR + "/mv_src.txt", "new\n")
	out = await _run("move_file", {"path": TMP_DIR + "/mv_src.txt", "to": TMP_DIR + "/mv_exists.txt", "force": true}, true)
	_check(out.begins_with("Error:") and out.contains("never overwrites"), "a move refuses an existing destination even with force")
	_check(_read(TMP_DIR + "/mv_exists.txt") == "old\n" and FileAccess.file_exists(TMP_DIR + "/mv_src.txt"), "the refused overwrite touched neither file")
	# Containment end-to-end: with the fence up, neither endpoint may cross outside, and force never overrides it.
	out = await _run("move_file", {"path": TMP_DIR + "/mv_src.txt", "to": "res://../mv_escaped.txt", "force": true}, true)
	_check(out.contains("OUTSIDE") and FileAccess.file_exists(TMP_DIR + "/mv_src.txt"), "a destination outside the project is refused even with force")
	var root_abs := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var outside := root_abs.path_join("..").simplify_path().path_join("gdllm_mv_outside.txt")
	_write(outside, "outside")
	out = await _run("move_file", {"path": "res://../gdllm_mv_outside.txt", "to": TMP_DIR + "/mv_in.txt", "force": true}, true)
	_check(out.contains("OUTSIDE") and FileAccess.file_exists(outside) and not FileAccess.file_exists(TMP_DIR + "/mv_in.txt"), "a source outside the project is refused even with force — nothing is pulled in")
	# With the fence dropped by the setting, the same outside source moves in — the toggle is the single lever.
	GDLLMSettings.headless_allow_outside_tool_calls = true
	out = await _run("move_file", {"path": "res://../gdllm_mv_outside.txt", "to": TMP_DIR + "/mv_in.txt", "force": true}, true)
	_check(out.begins_with("Moved") and FileAccess.file_exists(TMP_DIR + "/mv_in.txt") and not FileAccess.file_exists(outside), "with the fence dropped, an outside source moves into the project end to end")
	GDLLMSettings.headless_allow_outside_tool_calls = false
	DirAccess.remove_absolute(TMP_DIR + "/mv_in.txt")
	# A move keeps a file in its own tree while the fence is up; user:// relocations work within user://.
	out = await _run("move_file", {"path": TMP_DIR + "/mv_src.txt", "to": "user://gdllm_smoke_mv.txt", "force": true}, true)
	_check(out.begins_with("Error:") and out.contains("its own tree") and FileAccess.file_exists(TMP_DIR + "/mv_src.txt"), "a res:// file refuses a user:// destination with the same-tree rule, honestly worded")
	# Assembled at runtime so the reference scan never matches this file's own text (the suite's convention for probe names).
	var user_mv_a := "user://gdllm_smoke_" + "mv_a.txt"
	var user_mv_b := "user://gdllm_smoke_" + "mv_b.txt"
	_write(user_mv_a, "u\n")
	out = await _run("move_file", {"path": user_mv_a, "to": user_mv_b}, true)
	_check(out.begins_with("Moved") and _read(user_mv_b) == "u\n" and not FileAccess.file_exists(user_mv_a), "a user:// file relocates within user://")
	# The full-path-in-own-directory tolerance works for user:// spellings too, judged on the sanitized form.
	var user_mv_c := "user://gdllm_smoke_" + "mv_c.txt"
	out = await _run("rename_file", {"path": user_mv_b, "new_name": user_mv_c}, true)
	_check(out.begins_with("Renamed") and FileAccess.file_exists(user_mv_c), "a user:// rename spelled as a full path in its own directory lands")
	DirAccess.remove_absolute(user_mv_c)
	out = await _run("move_file", {"path": TMP_DIR + "/mv_sub/renamed_seen.txt", "to": TMP_DIR + "/bs_sub\\", "force": true}, true)
	_check(out.begins_with("Moved") and FileAccess.file_exists(TMP_DIR + "/bs_sub/renamed_seen.txt"), "a backslashed directory destination carries the same new-directory intent as the slashed spelling")
	# The boundary guard itself, unit-tested on both roles so the dangerous targets never risk a real move in this suite.
	_check(GDLLMTools._path_boundary_guard("res://../escape.txt").contains("OUTSIDE"), "the boundary guard refuses a .. escape")
	_check(GDLLMTools._path_boundary_guard("user://save.dat") == "", "a user:// endpoint is inside the fence (the same-tree rule, not the fence, pairs it with a user:// other end)")
	_check(GDLLMTools._path_boundary_guard("res://project.godot").contains("critical"), "the boundary guard refuses project.godot")
	_check(GDLLMTools._path_boundary_guard("res://.godot/uid_cache.bin").contains("critical"), "the boundary guard refuses the editor cache as a destination")
	_check(GDLLMTools._path_boundary_guard("res://.git/config").contains("critical"), "the boundary guard refuses the .git store")
	_check(GDLLMTools._path_boundary_guard(TMP_DIR + "/fine.txt") == "", "the boundary guard passes an ordinary project path")
	# An extension change lands but is disclosed loudly.
	out = await _run("rename_file", {"path": TMP_DIR + "/mv_src.txt", "new_name": "mv_src.md"}, true)
	_check(out.begins_with("Renamed") and out.contains("extension changed"), "an extension change is disclosed as a warning")
	# An extensionless file (a LICENSE, a Makefile) is a real project file: relocating it must not demand an extension it doesn't have, while an extensioned source keeps the directory-intent refusal.
	var license := TMP_DIR + "/LICENSE"
	_write(license, "license text\n")
	out = await _run("move_file", {"path": license, "to": TMP_DIR + "/mv_docs/"}, true)
	_check(out.begins_with("Moved") and FileAccess.file_exists(TMP_DIR + "/mv_docs/LICENSE"), "an extensionless file moves into a directory under its own name")
	out = await _run("rename_file", {"path": TMP_DIR + "/mv_docs/LICENSE", "new_name": "NOTICE"}, true)
	_check(out.begins_with("Renamed") and FileAccess.file_exists(TMP_DIR + "/mv_docs/NOTICE"), "an extensionless file renames to another extensionless name")
	out = await _run("move_file", {"path": TMP_DIR + "/mv_src.md", "to": TMP_DIR + "/mv_noext"}, true)
	_check(out.begins_with("Error:") and out.contains("no file extension") and FileAccess.file_exists(TMP_DIR + "/mv_src.md"), "an extensioned source still refuses an extensionless destination — that spelling means unstated directory intent")


## copy_file: the binary bytes surviving intact, the three ways a copy could steal the source's uid all minting fresh instead, the refusal ladder, and the ledger claims carrying to a duplicate whose bytes are the source's.
func _test_copy_file() -> void:
	_check(GDLLMTools.is_mutating("copy_file") and not GDLLMTools.is_destructive("copy_file"), "copy_file is mutating but not destructive")
	_check(GDLLMTools.search("duplicate file", true).size() == 1, "copy_file is reachable from tool_search by \"duplicate file\"")
	_check(GDLLMTools.search("copy asset", true).size() == 1, "copy_file is reachable from tool_search by \"copy asset\"")
	# A binary asset with its .import: the bytes round-trip untouched, the settings carry, and the copy's uid is its own.
	var png := TMP_DIR + "/cp_coin.png"
	var bytes := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0xFF, 0x7F, 0x00])
	var raw := FileAccess.open(png, FileAccess.WRITE)
	raw.store_buffer(bytes)
	raw.close()
	var src_import_uid := ResourceUID.id_to_text(ResourceUID.create_id())
	_write(png + ".import", "[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\nuid=\"%s\"\n\n[deps]\n\nsource_file=\"%s\"\n\n[params]\n\ncompress/mode=0\n" % [src_import_uid, png])
	var silver := TMP_DIR + "/cp_coin_silver.png"
	var out := await _run("copy_file", {"path": png, "to": silver}, true)
	_check(out.begins_with("Copied " + png + " to " + silver), "copy_file copies a binary asset")
	_check(FileAccess.get_file_as_bytes(silver) == bytes, "the copy is byte-identical to the source")
	var copied_import := _read(silver + ".import")
	_check(copied_import.contains("source_file=\"%s\"" % silver), "the copied .import names the COPY as its source file")
	_check(copied_import.contains("compress/mode=0"), "the copied .import carries the source's import settings")
	_check(not copied_import.contains(src_import_uid), "the copied .import does NOT carry the source's uid")
	_check(_read(png + ".import").contains(src_import_uid), "the source's own .import was left untouched")
	_check(out.contains("re-imports"), "the result says the editor re-imports the copy")
	# A .tres carries its uid in its own header, so the copy's header must be rewritten and registered to the copy.
	var src_res_uid := ResourceUID.id_to_text(ResourceUID.create_id())
	var slot := TMP_DIR + "/cp_slot.tres"
	_write(slot, "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\nmetadata/label = \"open\"\n" % src_res_uid)
	var locked := TMP_DIR + "/cp_slot_locked.tres"
	out = await _run("copy_file", {"path": slot, "to": locked}, true)
	var locked_text := _read(locked)
	_check(out.begins_with("Copied") and not locked_text.contains(src_res_uid), "a copied .tres header does not keep the source's uid")
	_check(locked_text.contains("metadata/label = \"open\"") and _read(slot).contains(src_res_uid), "only the header uid changed, and the source kept its own")
	var fresh_res_uid := GDLLMTools._uid_text_for(locked)
	_check(fresh_res_uid.begins_with("uid://") and ResourceUID.get_id_path(ResourceUID.text_to_id(fresh_res_uid)) == locked, "the copy's fresh header uid is registered to the copy")
	_check(out.contains(fresh_res_uid), "the result names the fresh uid")
	_check(not out.contains("needs its own read"), "no read-first advice when the source was never seen")
	# A rewritten header makes the copy one machine-made line different from anything shown, so the seen claim must NOT carry to it.
	await _run("read_file", {"path": slot}, false)
	var relocked := TMP_DIR + "/cp_slot_relocked.tres"
	out = await _run("copy_file", {"path": slot, "to": relocked}, true)
	_check(out.begins_with("Copied") and out.contains("needs its own read"), "a seen source's rewritten copy says a follow-up edit needs its own read")
	out = await _run("edit_file", {"path": relocked, "old_string": "\"open\"", "new_string": "\"locked\""}, true)
	_check(out.begins_with("Error:") and out.contains("not read"), "the seen claim does NOT carry to a header-rewritten copy")
	await _run("read_file", {"path": relocked}, false)
	out = await _run("edit_file", {"path": relocked, "old_string": "\"open\"", "new_string": "\"locked\""}, true)
	_check(out.begins_with("Edited"), "reading the rewritten copy grounds its edit")
	# A .uid sidecar is minted for the copy, never copied — write_file's own minting rule.
	var script := TMP_DIR + "/cp_script.gd"
	await _run("write_file", {"path": script, "content": "extends RefCounted\n"}, true)
	var script_uid := _read(script + ".uid").strip_edges()
	var script_copy := TMP_DIR + "/cp_script_two.gd"
	out = await _run("copy_file", {"path": script, "to": script_copy}, true)
	var copy_uid := _read(script_copy + ".uid").strip_edges()
	_check(out.begins_with("Copied") and copy_uid.begins_with("uid://") and copy_uid != script_uid, "the copy's .uid sidecar is minted fresh, not the source's")
	_check(ResourceUID.get_id_path(ResourceUID.text_to_id(copy_uid)) == script_copy, "the minted sidecar uid is registered to the copy")
	# A duplicated global class_name is an engine-level break the result must name.
	var declaring := TMP_DIR + "/cp_declaring.gd"
	_write(declaring, "class_name GdllmSmokeCopyProbe\nextends RefCounted\n")
	out = await _run("copy_file", {"path": declaring, "to": TMP_DIR + "/cp_declaring_two.gd"}, true)
	_check(out.contains("GdllmSmokeCopyProbe") and out.contains("WARNING"), "copying a script with a global class_name warns about the duplicate class")
	# Two files declaring one class would poison every later validation subprocess in this suite.
	DirAccess.remove_absolute(TMP_DIR + "/cp_declaring_two.gd")
	DirAccess.remove_absolute(TMP_DIR + "/cp_declaring_two.gd.uid")
	DirAccess.remove_absolute(declaring)
	# The seen claim carries, because the copy holds the bytes the source was read as.
	var seen_src := TMP_DIR + "/cp_seen.txt"
	_write(seen_src, "alpha\nbeta\n")
	await _run("read_file", {"path": seen_src}, false)
	out = await _run("copy_file", {"path": seen_src, "to": TMP_DIR + "/cp_sub/"}, true)
	_check(out.begins_with("Copied") and _read(TMP_DIR + "/cp_sub/cp_seen.txt") == "alpha\nbeta\n", "a directory destination copies the file into it under its own name, creating the directory")
	out = await _run("edit_file", {"path": TMP_DIR + "/cp_sub/cp_seen.txt", "old_string": "alpha", "new_string": "ALPHA"}, true)
	_check(out.begins_with("Edited"), "the seen-file claim carries to the copy — no re-read required")
	_check(_read(seen_src) == "alpha\nbeta\n", "editing the copy left the source alone")
	# An extensionless source copies to an extensionless destination — the directory-intent refusal is judged against the source's own name.
	var cp_plain := TMP_DIR + "/MAKEFILE"
	_write(cp_plain, "all:\n")
	out = await _run("copy_file", {"path": cp_plain, "to": TMP_DIR + "/MAKEFILE_TWO"}, true)
	_check(out.begins_with("Copied") and _read(TMP_DIR + "/MAKEFILE_TWO") == "all:\n", "an extensionless file copies to an extensionless destination")
	# A user:// copy keeps the source's bytes verbatim — uid header included — and the result must disclose the kept uid as inert rather than presenting it as the copy's identity.
	var user_res := "user://gdllm_smoke_" + "cp_keep.tres"
	var user_res_copy := "user://gdllm_smoke_" + "cp_keep_two.tres"
	var kept_uid := ResourceUID.id_to_text(ResourceUID.create_id())
	_write(user_res, "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % kept_uid)
	out = await _run("copy_file", {"path": user_res, "to": user_res_copy}, true)
	_check(out.begins_with("Copied") and _read(user_res_copy).contains(kept_uid), "a user:// copy keeps the source's bytes verbatim, uid header included")
	_check(out.contains(kept_uid) and out.contains("inert"), "the kept source uid is disclosed as inert, never as the copy's own")
	DirAccess.remove_absolute(user_res)
	DirAccess.remove_absolute(user_res_copy)
	# The refusal ladder, each naming its way out.
	out = await _run("copy_file", {"path": png, "to": silver}, true)
	_check(out.begins_with("Error:") and out.contains("never overwrites") and out.contains("delete_file"), "an identical repeat refuses instead of duplicating again")
	_check(FileAccess.get_file_as_bytes(silver) == bytes, "the refused overwrite left the existing file untouched")
	out = await _run("copy_file", {"path": png, "to": png}, true)
	_check(out.begins_with("Error:") and out.contains("its own destination"), "copying a file onto itself is refused")
	out = await _run("copy_file", {"path": TMP_DIR, "to": TMP_DIR + "/cp_dir_copy"}, true)
	_check(out.begins_with("Error:") and out.contains("directory"), "a directory source is refused, one file at a time")
	out = await _run("copy_file", {"path": png, "to": TMP_DIR + "/cp_no_ext"}, true)
	_check(out.begins_with("Error:") and out.contains("no file extension"), "a destination with no extension is refused, naming the \"/\" form")
	out = await _run("copy_file", {"path": png, "to": "res://.secret/cp_hidden.png"}, true)
	_check(out.begins_with("Error:") and out.contains("hidden directory"), "a hidden destination directory is refused")
	out = await _run("copy_file", {"path": png, "to": "res://../cp_escaped.png"}, true)
	_check(out.contains("OUTSIDE") and not out.contains("moved"), "a destination outside the project is refused")
	out = await _run("copy_file", {"path": png, "to": "user://cp_crossed.png"}, true)
	_check(out.begins_with("Error:") and out.contains("its own tree") and not FileAccess.file_exists("user://cp_crossed.png"), "a copy refuses to cross from res:// into user:// while the fence is up")
	out = await _run("copy_file", {"path": "res://../gdllm_copy_outside.png", "to": TMP_DIR + "/cp_pulled_in.png"}, true)
	_check(out.begins_with("Error:") and not FileAccess.file_exists(TMP_DIR + "/cp_pulled_in.png"), "a source outside the project is refused — nothing is pulled in")
	out = await _run("copy_file", {"path": "cp_no_such_file.png", "to": TMP_DIR + "/cp_x.png"}, true)
	_check(out.begins_with("Error:") and not out.contains("Copied"), "an unresolvable source errors without copying")
	_write(TMP_DIR + "/cp_sub/cp_twin.txt", "one\n")
	_write(TMP_DIR + "/cp_twin.txt", "two\n")
	out = await _run("copy_file", {"path": "cp_twin.txt", "to": TMP_DIR + "/cp_twin_copy.txt"}, true)
	_check(out.begins_with("Error:") and out.contains(TMP_DIR + "/cp_sub/cp_twin.txt") and out.contains(TMP_DIR + "/cp_twin.txt"), "an ambiguous bare name lists every candidate instead of guessing")
	out = await _run("copy_file", {"path": png, "to": TMP_DIR + "/cp_wrong_kind.bin"}, true)
	_check(out.begins_with("Copied") and out.contains("extension"), "a copy that changes the extension lands but is disclosed")


## The two not-found coaches added after transcript analysis: a whitespace-only old_string mismatch is applied anyway with loud disclosure (round trips derail small models), and an old_string copied from content the model itself replaced is named STALE instead of getting whitespace advice.
func _test_ws_fallback_and_stale() -> void:
	# Spurious leading tab, as observed in real transcripts: the model sent "\tvar ..." where the file has column-0 "var ...".
	var gd := TMP_DIR + "/ws_fallback.gd"
	_write(gd, "extends RefCounted\n\nvar speed: int = 5\n\n\nfunc go() -> int:\n\treturn speed\n")
	await _run("read_file", {"path": gd}, false)
	var out := await _run("edit_file", {"path": gd, "old_string": "\tvar speed: int = 5", "new_string": "\tvar speed: int = 9"}, true)
	_check(out.begins_with("Edited") and out.contains("whitespace"), "ws fallback applies a unique whitespace-only match and discloses it")
	_check(_read(gd).contains("var speed: int = 9") and not _read(gd).contains("\tvar speed"), "ws fallback landed with the file's real indentation")
	# Spaces-for-tabs drift with a DEEPER level introduced by new_string: the inferred 4-spaces↔tab unit must extrapolate.
	var deep := TMP_DIR + "/ws_deep.gd"
	_write(deep, "extends RefCounted\n\n\nfunc calc() -> int:\n\tvar total := 0\n\tfor i in 3:\n\t\ttotal += i\n\treturn total\n")
	await _run("read_file", {"path": deep}, false)
	out = await _run("edit_file", {"path": deep, "old_string": "func calc() -> int:\n    var total := 0\n    for i in 3:\n        total += i\n    return total", "new_string": "func calc() -> int:\n    var total := 0\n    for i in 3:\n        if i > 0:\n            total += i\n    return total"}, true)
	_check(out.begins_with("Edited"), "ws fallback applies a spaces-for-tabs block")
	_check(_read(deep).contains("\t\tif i > 0:") and _read(deep).contains("\t\t\ttotal += i"), "the inferred indent unit extrapolates to a deeper new level")
	# Two normalized-identical regions are ambiguous — nothing is applied.
	var amb := TMP_DIR + "/ws_ambiguous.txt"
	_write(amb, "alpha\nbeta\nmid\nalpha\nbeta\n")
	await _run("read_file", {"path": amb}, false)
	out = await _run("edit_file", {"path": amb, "old_string": "alpha \nbeta", "new_string": "x"}, true)
	_check(out.contains("whitespace-tolerant match finds 2"), "ws fallback ambiguity errors with the count")
	_check(_read(amb).contains("alpha"), "the ambiguous fallback applied nothing")
	# The transcript case behind the nested-func refusal: a column-0 func anchored on lines that are really inside a function must bounce, not land indented as an illegal named nested function.
	var nest := TMP_DIR + "/ws_nested_func.gd"
	_write(nest, "extends RefCounted\n\n\nfunc outer() -> int:\n\tvar a := 1\n\tvar b := 2\n\treturn a + b\n")
	await _run("read_file", {"path": nest}, false)
	out = await _run("edit_file", {"path": nest, "old_string": "var a := 1\nvar b := 2", "new_string": "var a := 1\nvar b := 2\n\n\nfunc added() -> int:\n\treturn 3"}, true)
	_check(out.begins_with("Error:") and out.contains("nest it inside"), "ws fallback refuses to re-indent a func declaration into a block")
	_check(out.contains("func added() -> int:"), "the nested-func refusal names the declaration it refused")
	_check(not _read(nest).contains("added"), "the refused nested-func fallback applied nothing")
	var stale := TMP_DIR + "/stale_hint.gd"
	_write(stale, "extends RefCounted\n\n\nfunc first() -> int:\n\treturn 1\n")
	await _run("read_file", {"path": stale}, false)
	await _run("write_file", {"path": stale, "content": "extends RefCounted\n\n\nfunc second() -> int:\n\treturn 2\n"}, true)
	out = await _run("edit_file", {"path": stale, "old_string": "\treturn 1\n", "new_string": "\treturn 3\n"}, true)
	_check(out.contains("PREVIOUS content"), "a stale old_string names the real cause")
	_check(out.contains("Re-read the file"), "the stale error leads with the action")
	_check(_read(stale).contains("return 2"), "the stale edit applied nothing")
	# Genuinely invented text still gets the plain not-found teaching.
	out = await _run("edit_file", {"path": stale, "old_string": "never existed anywhere", "new_string": "x"}, true)
	_check(out.contains("was not found") and not out.contains("PREVIOUS"), "invented text still gets the plain not-found")


## The automatic cross-file dependent check: an extends change or class_name removal names the files still leaning on the script, textually, while an edit leaving the declarations alone stays silent.
func _test_dependent_check() -> void:
	# The class name is assembled at runtime so this test file's own source never word-matches it.
	var cname := "GdllmSmokeProbe" + "Dep"
	var target := TMP_DIR + "/dep_target.gd"
	var by_name := TMP_DIR + "/dep_by_name.gd"
	var by_path := TMP_DIR + "/dep_by_path.gd"
	await _run("write_file", {"path": target, "content": "class_name %s\nextends RefCounted\n" % cname}, true)
	_write(by_name, "extends RefCounted\n# relies on %s\n" % cname)
	_write(by_path, "extends RefCounted\nconst DEP := preload(\"%s\")\n" % target)
	var out := await _run("edit_file", {"path": target, "old_string": "extends RefCounted", "new_string": "extends Resource"}, true)
	_check(out.contains("base type") and out.contains(by_path) and out.contains(by_name), "an extends change lists the path- and name-based dependents")
	out = await _run("edit_file", {"path": target, "old_string": "class_name %s\n" % cname, "new_string": ""}, true)
	_check(out.contains("REMOVED") and out.contains(by_name), "a class_name removal lists the files still using the name")
	_check(not out.contains(by_path), "a class_name removal doesn't drag in path-only references")
	out = await _run("edit_file", {"path": target, "old_string": "extends Resource", "new_string": "extends Resource\n\nvar body := 1"}, true)
	_check(not out.contains("Automatic dependent check"), "an edit leaving the declarations alone stays silent")


func _test_grouped_problems() -> void:
	var grouped: Array = GDLLMTools._grouped_problem_lines(["line 3: foo", "line 9: foo", "bar (rule)", "bar (rule)", "line 4: baz"])
	_check(grouped == ["lines 3, 9: foo", "bar (rule) (2 occurrences)", "line 4: baz"], "repeated problems collapse to one line each with their occurrences")
	_check(GDLLMTools._grouped_problem_lines(["line 7: solo"]) == ["line 7: solo"], "a lone located problem passes through untouched")


func _test_script_declarations() -> void:
	var decl: Dictionary = GDLLMTools._script_declarations("@tool\nclass_name Foo extends Node2D # note\n\nfunc _ready() -> void:\n\tpass\n")
	_check(decl["class_name"] == "Foo" and decl["extends"] == "Node2D", "the combined class_name/extends line parses with its comment stripped")
	decl = GDLLMTools._script_declarations("extends \"res://base.gd\"\nvar x := 1\nclass_name Late\n")
	_check(decl["extends"] == "\"res://base.gd\"" and decl["class_name"] == "", "scanning stops at the first real statement")


func _test_edit_resource() -> void:
	var script_path := TMP_DIR + "/smoke_res.gd"
	_write(script_path, RES_SCRIPT)
	var scr: Script = load(script_path)
	var inst: Resource = scr.new()
	var res_path := TMP_DIR + "/smoke.tres"
	ResourceSaver.save(inst, res_path)
	var mat_path := TMP_DIR + "/mat.tres"
	ResourceSaver.save(StandardMaterial3D.new(), mat_path)
	var out := await _run("edit_resource", {"path": res_path, "properties": {"speed": 4.5, "count": 7, "active": true, "offset": "Vector2(64, 32)", "tint": "Color(1, 0, 0, 1)", "mat": mat_path, "tags": ["a", "b"]}}, true)
	_check(out.begins_with("Saved"), "edit_resource batch confirms")
	var reloaded: Resource = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(reloaded.get("speed") == 4.5 and reloaded.get("count") == 7 and bool(reloaded.get("active")), "edit_resource scalars hit disk")
	out = await _run("edit_resource", {"path": res_path, "properties": {"count": "3.0"}}, true)
	_check(out.begins_with("Saved"), "a stringified float lands on an int property")
	_check((ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Resource).get("count") == 3, "the int property took the string-float's integer self")
	out = await _run("edit_resource", {"path": res_path, "properties": {"count": "2.9"}}, true)
	_check(out.begins_with("Error") and out.contains("parses as"), "a fractional string keeps its teaching refusal — nothing truncates silently")
	out = await _run("edit_resource", {"path": res_path, "properties": {"count": "1e19"}}, true)
	_check(out.begins_with("Error"), "a whole float past int range keeps its refusal instead of overflowing into garbage")
	await _run("edit_resource", {"path": res_path, "properties": {"count": 7}}, true)
	_check(reloaded.get("offset") == Vector2(64, 32) and reloaded.get("tint") == Color(1, 0, 0, 1), "edit_resource literals hit disk")
	_check(reloaded.get("mat") is StandardMaterial3D, "edit_resource object path loaded and saved")
	_check(reloaded.get("tags") == PackedStringArray(["a", "b"]), "edit_resource array coerced to packed")
	out = await _run("edit_resource", {"path": res_path, "properties": {"spee": 1.0}}, true)
	_check(out.contains("Did you mean") and out.contains("speed"), "edit_resource unknown property suggests near miss")
	out = await _run("edit_resource", {"path": res_path, "properties": {"offset": "5"}}, true)
	_check(out.contains("Vector2"), "edit_resource wrong literal teaches the expected type")
	out = await _run("edit_resource", {"path": res_path, "properties": {"speed": 9.0, "bogus": 1}}, true)
	var after: Resource = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(out.begins_with("Error") and after.get("speed") == 4.5, "edit_resource batch is all-or-nothing")


func _test_create_resource() -> void:
	var out := await _run("create_resource", {"from": "standardmaterial3d", "path": TMP_DIR + "/new_mat.tres"}, true)
	_check(out.begins_with("Created") and out.contains("StandardMaterial3D"), "create_resource from built-in class (case-insensitive)")
	out = await _run("create_resource", {"from": TMP_DIR + "/smoke_res.gd", "path": TMP_DIR + "/from_script.tres", "properties": {"speed": 3.5, "offset": "Vector2(4, 5)"}}, true)
	_check(out.begins_with("Created"), "create_resource from script with properties")
	var made: Resource = ResourceLoader.load(TMP_DIR + "/from_script.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(made.get("speed") == 3.5 and made.get("offset") == Vector2(4, 5), "create_resource properties hit disk")
	out = await _run("create_resource", {"from": TMP_DIR + "/smoke.tres", "path": TMP_DIR + "/dup.tres"}, true)
	_check(out.contains("deep-duplicated"), "create_resource duplicates an existing .tres")
	await _run("edit_resource", {"path": TMP_DIR + "/dup.tres", "properties": {"count": 99}}, true)
	var original: Resource = ResourceLoader.load(TMP_DIR + "/smoke.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(original.get("count") == 7, "create_resource duplicate is independent of the original")
	out = await _run("create_resource", {"from": "StandardMaterial3D", "path": TMP_DIR + "/new_mat.tres"}, true)
	_check(out.contains("overwrite"), "create_resource refuses to clobber without overwrite")
	out = await _run("create_resource", {"from": "StandardMaterial3D", "path": TMP_DIR + "/new_mat.tres", "overwrite": true}, true)
	_check(out.begins_with("Created"), "create_resource overwrites when asked")
	out = await _run("create_resource", {"from": "StandrdMaterial3D", "path": TMP_DIR + "/x.tres"}, true)
	_check(out.contains("StandardMaterial3D"), "create_resource bad class suggests the near miss")
	out = await _run("create_resource", {"from": TMP_DIR + "/smoke_res.gd", "path": TMP_DIR + "/bad.tres", "properties": {"speed": "zoom"}}, true)
	_check(out.contains("float") and not FileAccess.file_exists(TMP_DIR + "/bad.tres"), "create_resource bad value aborts before saving")
	out = await _run("create_resource", {"from": "Resource", "path": TMP_DIR + "/scripted.tres", "properties": {"script": TMP_DIR + "/smoke_res.gd"}}, true)
	_check(out.begins_with("Created"), "create_resource builds a scripted resource from a plain base")
	var scripted: Resource = ResourceLoader.load(TMP_DIR + "/scripted.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(scripted.get_script() != null and scripted.get("speed") == 1.0, "create_resource scripted resource keeps its script and defaults on disk")


## The transcript-observed boon shape: an Object property holding an EMBEDDED sub-resource, which used to be settable only from a file path — forcing every model into hand-written .tres text. Inline objects build one, null clears one, and both compose with create_resource's deep duplication.
func _test_inline_subresource() -> void:
	var aug_script := TMP_DIR + "/aug.gd"
	_write(aug_script, "extends Resource\n\n@export var amount: float = 0.0\n")
	var holder_script := TMP_DIR + "/holder.gd"
	_write(holder_script, "extends Resource\n\n@export var label: String = \"\"\n@export var aug: Resource\n")
	var holder: Resource = (load(holder_script) as Script).new()
	var holder_path := TMP_DIR + "/holder.tres"
	ResourceSaver.save(holder, holder_path)
	var out := await _run("edit_resource", {"path": holder_path, "properties": {"aug": {"script": aug_script, "amount": 2.5}}}, true)
	_check(out.begins_with("Saved"), "edit_resource inline object builds an embedded sub-resource")
	_check(_read(holder_path).contains("[sub_resource"), "the saved .tres serializes an embedded [sub_resource]")
	var reloaded: Resource = ResourceLoader.load(holder_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var aug: Variant = reloaded.get("aug")
	_check(aug is Resource and aug.get("amount") == 2.5, "the inline sub-resource carries its coerced properties")
	out = await _run("edit_resource", {"path": holder_path, "properties": {"aug": null}}, true)
	_check(out.begins_with("Saved"), "edit_resource null clears an object property")
	reloaded = ResourceLoader.load(holder_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(reloaded.get("aug") == null, "the cleared property hit disk")
	out = await _run("edit_resource", {"path": holder_path, "properties": {"label": null}}, true)
	_check(out.begins_with("Error") and out.contains("null"), "null on a non-object property is refused with teaching")
	out = await _run("edit_resource", {"path": holder_path, "properties": {"aug": {"amount": 1.0}}}, true)
	_check(out.begins_with("Error") and out.contains("script"), "an inline object without a base names the expected shape")
	out = await _run("edit_resource", {"path": holder_path, "properties": {"aug": {"script": aug_script, "amout": 1.0}}}, true)
	_check(out.begins_with("Error") and out.contains("amout"), "an inline object's bad property is named")
	out = await _run("edit_resource", {"path": holder_path, "properties": {"aug": {"script": aug_script, "amount_value": 1.0}}}, true)
	_check(out.contains("Did you mean") and out.contains("amount"), "an inline object's bad property gets the did-you-mean treatment")
	out = await _run("edit_resource", {"path": holder_path, "properties": {"aug": {"script": aug_script, "alpha_curve": 1.0}}}, true)
	_check(out.contains("settable properties") and out.contains("amount"), "a no-substring guess gets the real property names instead of nothing")
	# The duplicated-boon flow in one call: copy the holder and re-point its embedded sub-resource, no raw .tres text involved.
	await _run("edit_resource", {"path": holder_path, "properties": {"aug": {"script": aug_script, "amount": 2.5}, "label": "orig"}}, true)
	out = await _run("create_resource", {"from": holder_path, "path": TMP_DIR + "/holder_copy.tres", "properties": {"label": "copy", "aug": {"script": aug_script, "amount": 9.0}}}, true)
	_check(out.begins_with("Created"), "create_resource accepts inline sub-resource properties")
	var copy: Resource = ResourceLoader.load(TMP_DIR + "/holder_copy.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(copy.get("label") == "copy" and copy.get("aug") is Resource and copy.get("aug").get("amount") == 9.0, "the copy's inline sub-resource landed independently")
	var original: Resource = ResourceLoader.load(holder_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(original.get("aug").get("amount") == 2.5 and original.get("label") == "orig", "the original's embedded sub-resource is untouched by the copy")


## Hand-written header uids — invented or kept from a duplicated file — are corrected to engine truth before landing, with the correction disclosed; the one kept case is a collision-free uid the project's own code already references (a model coordinating a preload with the header it plans to write). The fake uids are assembled at runtime so this file never literally contains them — the reference scan reads project text, this test included.
func _test_uid_lint() -> void:
	var invented := "uid://" + "abc123" + "456789"
	var fake := "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % invented
	var p := TMP_DIR + "/uid_fake.tres"
	var out := await _run("write_file", {"path": p, "content": fake}, true)
	_check(out.contains("never write one by hand"), "write_file corrects an unreferenced invented uid and teaches")
	var on_disk := _read(p)
	_check(not on_disk.contains(invented), "the invented uid did not land on disk")
	var re := RegEx.new()
	re.compile("uid=\"(uid://[^\"]+)\"")
	var found := re.search(on_disk)
	_check(found != null and ResourceUID.has_id(ResourceUID.text_to_id(found.get_string(1))), "the replacement uid is engine-registered")
	var assigned := found.get_string(1)
	out = await _run("write_file", {"path": p, "content": fake.replace(invented, "uid://" + "def987" + "654321")}, true)
	_check(not _read(p).contains("def987"), "an overwritten invented uid is corrected too")
	await _run("read_file", {"path": p}, false)
	out = await _run("edit_file", {"path": p, "old_string": assigned, "new_string": "uid://" + "zzz999" + "zzz999z"}, true)
	_check(not _read(p).contains("zzz999"), "edit_file corrects a hand-changed uid")
	_check(out.contains("never write one by hand"), "the edit_file correction is disclosed")
	var no_uid := TMP_DIR + "/uid_none.tres"
	out = await _run("write_file", {"path": no_uid, "content": "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n"}, true)
	_check(out.begins_with("Created") and not out.contains("never write one by hand"), "a header without a uid is left alone")
	# The coordinated case: a script already preloads the uid the model gives the new file — replacing it would break that script, so it is kept and registered. Engine-generated (unregistered) so it is guaranteed to parse as a real id.
	var planned := ResourceUID.id_to_text(ResourceUID.create_id())
	_write(TMP_DIR + "/uid_user.gd", "extends RefCounted\n\nvar boon := preload(\"%s\")\n" % planned)
	var kept_path := TMP_DIR + "/uid_kept.tres"
	out = await _run("write_file", {"path": kept_path, "content": "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % planned}, true)
	_check(out.contains("KEPT") and out.contains(TMP_DIR + "/uid_user.gd"), "a referenced invented uid is kept, naming the referencing file")
	_check(_read(kept_path).contains(planned), "the kept uid stays in the header")
	_check(ResourceUID.has_id(ResourceUID.text_to_id(planned)) and ResourceUID.get_id_path(ResourceUID.text_to_id(planned)) == kept_path, "the kept uid is registered to the new file")
	# A uid another file already owns is a collision, referenced or not — replaced, naming the owner.
	out = await _run("write_file", {"path": TMP_DIR + "/uid_clash.tres", "content": "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % planned}, true)
	_check(out.contains("never share a uid") and out.contains(kept_path), "a colliding uid is replaced, naming its owner")
	_check(not _read(TMP_DIR + "/uid_clash.tres").contains(planned), "the colliding uid did not land on disk")


## The transcript-dominant fabrication: a script referencing an invented uid is refused BEFORE disk, while a stale uid already in the file never blocks an unrelated edit.
func _test_uid_ref_block() -> void:
	var p := TMP_DIR + "/uid_block.gd"
	var out := await _run("write_file", {"path": p, "content": "extends RefCounted\n\nvar dep := preload(\"uid://binvented0000\")\n"}, true)
	_check(out.begins_with("Error: nothing was written"), "write_file refuses a script referencing an invented uid")
	_check(not FileAccess.file_exists(p), "the refused script never landed on disk")
	_write(p, "extends RefCounted\n\nvar stale := \"uid://bstale0000000\"\nvar n := 1\n")
	await _run("read_file", {"path": p}, false)
	out = await _run("edit_file", {"path": p, "old_string": "var n := 1", "new_string": "var n := 2"}, true)
	_check(out.begins_with("Edited"), "a pre-existing unresolved uid does not block an unrelated edit")
	out = await _run("edit_file", {"path": p, "old_string": "var n := 2", "new_string": "var n := preload(\"uid://bfake99999999\")"}, true)
	_check(out.begins_with("Error: nothing was written"), "edit_file refuses introducing an invented uid")
	_check(_read(p).contains("var n := 2"), "the refused edit touched nothing")


## The fabrication ledger: a replaced header uid is remembered, and a later script referencing the invented text gets it substituted with what it became instead of landing broken.
func _test_uid_ledger_substitution() -> void:
	var invented := "uid://" + "bled12" + "3456789"
	var p := TMP_DIR + "/uid_led.tres"
	var out := await _run("write_file", {"path": p, "content": "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % invented}, true)
	_check(out.contains("replaced with the engine-generated"), "the invented header uid was replaced")
	var re := RegEx.create_from_string("uid=\"(uid://[^\"]+)\"")
	var real := re.search(_read(p)).get_string(1)
	var s := TMP_DIR + "/uid_led_user.gd"
	out = await _run("write_file", {"path": s, "content": "extends RefCounted\n\nvar dep := preload(\"%s\")\n" % invented}, true)
	_check(out.begins_with("Created"), "a script referencing the replaced uid is written, not refused")
	_check(out.contains("substituted to match"), "the substitution is disclosed")
	_check(_read(s).contains(real) and not _read(s).contains(invented), "the script carries the engine uid, not the invented one")
	_check(not out.contains("BROKEN"), "the substituted preload passes the engine check")


## An [ext_resource] uid disagreeing with its own path= is canonicalized to the path's engine uid — and a brand-new script has that uid at all because write_file mints its .uid sidecar on creation.
func _test_ext_resource_uid_canonicalized() -> void:
	var script_path := TMP_DIR + "/canon_dep.gd"
	var out := await _run("write_file", {"path": script_path, "content": "extends Resource\n"}, true)
	_check(out.contains("its uid is uid://"), "a new script's confirmation reports its minted uid")
	var real := _read(script_path + ".uid").strip_edges()
	_check(real.begins_with("uid://"), "write_file minted the script's .uid sidecar")
	var p := TMP_DIR + "/canon.tres"
	out = await _run("write_file", {"path": p, "content": "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" uid=\"uid://bwrong0000000\" path=\"%s\" id=\"1_x\"]\n\n[resource]\nscript = ExtResource(\"1_x\")\n" % script_path}, true)
	_check(out.contains("the entry was corrected before saving"), "the mismatched ext_resource uid correction is disclosed")
	_check(_read(p).contains(real) and not _read(p).contains("bwrong"), "the saved file carries the path's engine uid")
	_check(not out.contains("BROKEN"), "the canonicalized resource passes the load check")


## Engine uid errors come back translated against the registry: an invented uid is named as such, and a VALID uid whose target is broken is re-attributed to the target — the transcript case of a scene syntax error surfacing as an apparent uid problem.
func _test_uid_error_attribution() -> void:
	var bad := TMP_DIR + "/attr_bad.gd"
	_write(bad, "extends RefCounted\n\nconst DEP = preload(\"uid://battr00000000\")\n")
	var out := await _run("check_script", {"path": bad}, false)
	_check(out.contains("not any file's uid"), "check_script names an invented uid as such")
	var target := TMP_DIR + "/attr_target.tres"
	await _run("write_file", {"path": target, "content": "[gd_resource type=\"Resource\" format=3 uid=\"uid://battrinvent00\"]\n\n[resource]\n"}, true)
	var re := RegEx.create_from_string("uid=\"(uid://[^\"]+)\"")
	var tuid := re.search(_read(target)).get_string(1)
	_write(target, "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\nbroken = = =\n" % tuid)
	var loader := TMP_DIR + "/attr_loader.gd"
	_write(loader, "extends RefCounted\n\nconst DEP = preload(\"%s\")\n" % tuid)
	out = await _run("check_script", {"path": loader}, false)
	_check(out.contains("the uid is NOT the problem") and out.contains(target), "a valid uid's failure is re-attributed to its broken target")


## The audited blind spot: a script that references an imported asset ONLY by uid — the uid living in the asset's .import, the only place it exists for a binary — must surface in reverse dependencies and block a delete.
func _test_reverse_uid_lookup() -> void:
	var png := TMP_DIR + "/probe_sprite.png"
	_write(png, "fake image bytes")
	var sprite_uid := ResourceUID.id_to_text(ResourceUID.create_id())
	_write(png + ".import", "[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\nuid=\"%s\"\npath=\"res://.godot/imported/probe.ctex\"\n" % sprite_uid)
	_write(TMP_DIR + "/probe_user.gd", "extends RefCounted\n\nvar tex := preload(\"%s\")\n" % sprite_uid)
	var out := await _run("list_dependencies", {"path": png, "reverse": true}, false)
	_check(out.contains("probe_user.gd") and out.contains("by UID"), "reverse deps finds a script preloading an imported asset's uid")
	out = await _run("delete_file", {"path": png}, true, true)
	_check(out.contains("was NOT deleted") and out.contains("probe_user.gd"), "delete_file refuses the uid-referenced asset, naming the referencing script")


## uid:// works as a path argument anywhere a res:// path does, with the resolution disclosed; an unresolvable one gets the engine-truth error instead of a file-name search miss.
func _test_uid_path_input() -> void:
	var p := TMP_DIR + "/uid_input.tres"
	await _run("write_file", {"path": p, "content": "[gd_resource type=\"Resource\" format=3 uid=\"uid://binput0000000\"]\n\n[resource]\n"}, true)
	var re := RegEx.create_from_string("uid=\"(uid://[^\"]+)\"")
	var real := re.search(_read(p)).get_string(1)
	var out := await _run("read_file", {"path": real}, false)
	_check(out.contains("[gd_resource") and out.contains("per the project's uid registry"), "read_file accepts a uid:// path and disclosed the resolution")
	out = await _run("read_file", {"path": "uid://bnothing000000"}, false)
	_check(out.contains("not any file's uid"), "an unregistered uid:// path gets the engine-truth error")


## Load-check errors reach the model unmasked (digits intact — a masked "uid://b#h#..." named nothing actionable), while the pre/post diff still compares digit-masked keys so pre-existing errors aren't blamed on an edit. Mirrors the transcript case: a script preloading a uid that doesn't exist.
func _test_load_error_display() -> void:
	# Regenerate until the uid text carries a digit, so the unmasked assertion actually exercises the masking path.
	var missing_uid := ResourceUID.id_to_text(ResourceUID.create_id())
	var has_digit := RegEx.create_from_string("\\d")
	while has_digit.search(missing_uid) == null:
		missing_uid = ResourceUID.id_to_text(ResourceUID.create_id())
	_write(TMP_DIR + "/bad_loader.gd", "extends Resource\n\nconst DEP = preload(\"%s\")\n" % missing_uid)
	var broken := "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" path=\"%s/bad_loader.gd\" id=\"1_x\"]\n\n[resource]\nscript = ExtResource(\"1_x\")\n" % TMP_DIR
	var p := TMP_DIR + "/load_err.tres"
	var out := await _run("write_file", {"path": p, "content": broken}, true)
	_check(out.contains("BROKEN"), "a resource whose script preloads a missing uid fails the load check")
	_check(out.contains(missing_uid), "the failing uid reaches the model unmasked")
	# An edit leaving the same errors in place (only a property added) must not blame them on the edit, digit-masked keys matching across the line shift.
	await _run("read_file", {"path": p}, false)
	out = await _run("edit_file", {"path": p, "old_string": "[resource]\nscript", "new_string": "[resource]\nmetadata/x = 1\nscript"}, true)
	_check(out.begins_with("Edited") and not out.contains("BROKEN"), "unchanged pre-existing load errors aren't attributed to an edit")
	_check(not out.contains("loads cleanly"), "a file with pre-existing load errors earns no engine-checked claim")


## The automatic check_script report on an unchanged broken file collapses to one self-sufficient line after its first full dump — transcripts show a file with 48 pre-existing errors re-dumping them on every read.
func _test_auto_check_collapse() -> void:
	var broken := TMP_DIR + "/auto_broken.gd"
	_write(broken, "extends RefCounted\n\n\nfunc bad( -> int:\n\treturn 1\n")
	var out := await _run("read_file", {"path": broken}, false)
	_check(out.contains("Automatic check_script") and out.contains("account for them"), "reading a broken script reports its errors in full")
	out = await _run("read_file", {"path": broken}, false)
	_check(out.contains("still has the same") and not out.contains("account for them"), "an unchanged report collapses to one line on the next read")
	_check(out.contains("likely pre-existing") and not out.contains("YOUR earlier edit"), "a never-edited broken file keeps the pre-existing framing")
	_write(broken, "extends RefCounted\n\n\nfunc bad() -> int:\n\treturn nonexistent_symbol\n")
	out = await _run("read_file", {"path": broken}, false)
	_check(out.contains("account for them"), "a changed error set reports in full again")


## The load check runs in a child process whose uid registry (.godot/uid_cache.bin) can't see a uid this process registered moments ago through the kept-uid lint, so a coordinated preload pair came back BROKEN while the same result's uid note said KEPT; load_check.gd now registers the target's and its siblings' header uids in-child.
func _test_load_check_fresh_uid() -> void:
	# The coordinated pair exactly as the transcript built it: a .tres carrying a planned uid the lint KEEPS (a script references it), then a second .tres whose script preloads that uid.
	var planned := ResourceUID.id_to_text(ResourceUID.create_id())
	var user_script := TMP_DIR + "/fresh_uid_user.gd"
	_write(user_script, "extends Resource\n\nconst BOON = preload(\"%s\")\n" % planned)
	var kept := TMP_DIR + "/fresh_uid_boon.tres"
	var out := await _run("write_file", {"path": kept, "content": "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % planned}, true)
	_check(out.contains("KEPT"), "the planned uid is kept and registered in-process")
	var holder := "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" path=\"%s\" id=\"1_a\"]\n\n[resource]\nscript = ExtResource(\"1_a\")\n" % user_script
	out = await _run("write_file", {"path": TMP_DIR + "/fresh_uid_holder.tres", "content": holder}, true)
	_check(not out.contains("BROKEN"), "a resource whose script preloads the just-kept sibling uid passes the load check")


## A file an edit_file/write_file verdict left BROKEN keeps nagging on unrelated calls — rate-limited to once every three — until something validates it clean, so a model can't wander off mid-repair and claim success.
func _test_broken_reminder() -> void:
	GDLLMTools._fallback_ledger.broken_files.clear()
	GDLLMTools._fallback_ledger.broken_reminder_cooldown = 0
	var broken := TMP_DIR + "/reminder_broken.gd"
	var out := await _run("write_file", {"path": broken, "content": "extends RefCounted\n\n\nfunc nope( -> int:\n"}, true)
	_check(out.contains("BROKEN") and not out.contains("Automatic reminder"), "the breaking call itself is not reminded")
	var other := TMP_DIR + "/reminder_other.txt"
	out = await _run("write_file", {"path": other, "content": "unrelated\n"}, true)
	_check(out.contains("Automatic reminder") and out.contains(broken), "an unrelated call is reminded of the broken file by path")
	out = await _run("write_file", {"path": other, "content": "unrelated 2\n"}, true)
	_check(not out.contains("Automatic reminder"), "the rate limit holds the next call")
	out = await _run("write_file", {"path": other, "content": "unrelated 3\n"}, true)
	_check(not out.contains("Automatic reminder"), "the rate limit holds a second call")
	out = await _run("write_file", {"path": other, "content": "unrelated 4\n"}, true)
	_check(out.contains("Automatic reminder"), "the reminder fires again once the rate limit clears")
	GDLLMTools._fallback_ledger.broken_reminder_cooldown = 0
	out = await _run("check_script", {"path": broken}, false)
	_check(not out.contains("Automatic reminder"), "a call about the broken file itself is not nagged")
	out = await _run("edit_file", {"path": broken, "old_string": "func nope( -> int:\n", "new_string": "func nope() -> int:\n\treturn 1\n"}, true)
	_check(out.begins_with("Edited"), "the repair edit validates clean")
	GDLLMTools._fallback_ledger.broken_reminder_cooldown = 0
	out = await _run("write_file", {"path": other, "content": "unrelated 5\n"}, true)
	_check(not out.contains("Automatic reminder"), "the reminder clears once the file validates clean")


## A fully missed old_string quotes the nearest on-disk region verbatim, so the retry can copy real text out of the error itself — a weak model dead-ended when the re-read it was told to do came back withheld as a duplicate.
func _test_not_found_closest_region() -> void:
	var gd := TMP_DIR + "/closest.gd"
	_write(gd, "extends RefCounted\n\nvar health_points: int = 100\n\n\nfunc apply_damage(amount: int) -> void:\n\thealth_points -= amount\n")
	await _run("read_file", {"path": gd}, false)
	var out := await _run("edit_file", {"path": gd, "old_string": "var health_points: int = 250", "new_string": "var health_points: int = 50"}, true)
	_check(out.contains("Closest on-disk region (line 3)"), "a near-miss old_string gets the closest-region quote with its line number")
	_check(out.contains("var health_points: int = 100"), "the quoted region is the verbatim on-disk line")
	out = await _run("edit_file", {"path": gd, "old_string": "qqq www zzz xxx", "new_string": "y"}, true)
	_check(out.contains("was not found") and not out.contains("Closest on-disk region"), "a dissimilar old_string skips the quote silently")


## Swapping `script` inside a property batch used to silently wipe every property the batch didn't mention (set("script") re-initializes storage); the snapshot restore now carries survivors across and the disclosure names the count and the drops.
func _test_script_swap_preserves() -> void:
	var script_a := TMP_DIR + "/swap_a.gd"
	_write(script_a, "extends Resource\n\n@export var power: float = 1.0\n@export var tag: String = \"\"\n@export var extra: int = 0\n")
	var script_b := TMP_DIR + "/swap_b.gd"
	_write(script_b, "extends Resource\n\n@export var power: float = 1.0\n@export var tag: String = \"\"\n@export var speed: float = 0.0\n")
	var src := TMP_DIR + "/swap_src.tres"
	var inst: Resource = (load(script_a) as Script).new()
	inst.set("power", 7.5)
	inst.set("tag", "boon")
	inst.set("extra", 9)
	ResourceSaver.save(inst, src)
	var out := await _run("create_resource", {"from": src, "path": TMP_DIR + "/swap_copy.tres", "properties": {"script": script_b}}, true)
	_check(out.begins_with("Created") and out.contains("carried across the swap"), "create_resource script swap discloses the carry")
	_check(out.contains("2 existing properties carried"), "the disclosure names the carry count")
	_check(out.contains("extra"), "the dropped property is named")
	var copy: Resource = ResourceLoader.load(TMP_DIR + "/swap_copy.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(copy.get("power") == 7.5 and copy.get("tag") == "boon", "unlisted shared properties survive the script swap")
	var target := TMP_DIR + "/swap_edit.tres"
	var inst2: Resource = (load(script_a) as Script).new()
	inst2.set("power", 3.25)
	inst2.set("tag", "keep")
	inst2.set("extra", 4)
	ResourceSaver.save(inst2, target)
	out = await _run("edit_resource", {"path": target, "properties": {"script": script_b, "power": 6.0}}, true)
	_check(out.begins_with("Saved") and out.contains("carried across the swap"), "edit_resource script swap discloses the carry")
	_check(out.contains("extra"), "edit_resource names the dropped property")
	var edited: Resource = ResourceLoader.load(target, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(edited.get("power") == 6.0 and edited.get("tag") == "keep", "the batch value wins while the unlisted property survives")
	_check(edited.get("extra") == null, "a property the new script drops is gone")


## Success lines say the engine check already ran — transcripts show strong models re-verifying every clean write with check_script batches and whole-file re-reads because nothing said so.
func _test_engine_checked_clause() -> void:
	var gd := TMP_DIR + "/checked_ok.gd"
	var out := await _run("write_file", {"path": gd, "content": "extends RefCounted\n\n\nfunc fine() -> int:\n\treturn 4\n"}, true)
	_check(out.contains("parses cleanly (engine-checked)"), "write_file .gd success says the parse check ran")
	await _run("read_file", {"path": gd}, false)
	out = await _run("edit_file", {"path": gd, "old_string": "return 4", "new_string": "return 5"}, true)
	_check(out.contains("parses cleanly (engine-checked)"), "edit_file .gd success says the parse check ran")
	var scn := _save_scene("checkedscene")
	# full: true — the plain .tscn read is the shape-only scene map and would leave the edit gate unsatisfied.
	await _run("read_file", {"path": scn, "full": true}, false)
	out = await _run("edit_file", {"path": scn, "old_string": "type=\"Node2D\"", "new_string": "type=\"Sprite2D\""}, true)
	_check(out.contains("loads cleanly (engine-checked)"), "edit_file .tscn success says the load check ran")
	var trs := TMP_DIR + "/checked_res.tres"
	out = await _run("write_file", {"path": trs, "content": "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n"}, true)
	_check(out.contains("loads cleanly (engine-checked)"), "write_file .tres success says the load check ran")
	await _run("read_file", {"path": trs}, false)
	out = await _run("edit_file", {"path": trs, "old_string": "[resource]\n", "new_string": "[resource]\nmetadata/x = 1\n"}, true)
	_check(out.contains("loads cleanly (engine-checked)"), "a .tres edit is engine-checked")
	out = await _run("write_file", {"path": TMP_DIR + "/checked_plain.txt", "content": "plain\n"}, true)
	_check(not out.contains("engine-checked"), "a non-validated extension gets no clause")


## A validation run that dies before finishing must never read as clean: the launcher flags a missing completion sentinel, and a load the engine fails silently is folded into an own error — empty output from a dead subprocess once parsed as zero errors and earned a false "engine-checked" claim.
func _test_unvalidated_check_detection() -> void:
	# --version exits 0 without running any check script, so requiring a sentinel must flag the run as unfinished.
	var run: Dictionary = await GDLLMTools._edit_file_run_engine(["--version"], GDLLMTools.LOAD_CHECK_DONE_PATTERN)
	_check(not bool(run["ok"]) and String(run["why"]).contains("exited before finishing"), "a run that never prints its completion sentinel reports ok=false")
	run = await GDLLMTools._edit_file_run_engine(["--version"])
	_check(bool(run["ok"]) and int(run["exit_code"]) == 0, "a completed run with no sentinel requirement reports ok=true and its exit code")
	# A target the child can't load at all completes with its sentinel but prints no error lines; the LOAD_CHECK_FAILED marker must surface as an own error rather than a clean bill.
	var classified: Dictionary = await GDLLMTools._classified_script_errors(TMP_DIR + "/never_written_check_target.gd")
	_check(bool(classified["ok"]) and not (classified["own"] as Array).is_empty(), "a target that fails to load without engine errors is an error verdict, never clean")
	var good := TMP_DIR + "/sentinel_good.tres"
	_write(good, "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n")
	var report: Dictionary = await GDLLMTools._edit_file_load_report(good)
	_check(bool(report["ok"]) and (report["errors"] as Array).is_empty(), "a completed load check earns its clean verdict through the sentinel")
	var lint: Dictionary = await GDLLMTools._edit_file_lint_problems("res://example_script.gd")
	_check(bool(lint["ok"]), "a completed lint run reports ok=true via its summary sentinel")


## Creation confirmations carry the new file's uid, so a follow-up preload doesn't cost a re-read — transcripts show models re-reading fresh .tres files solely to harvest header uids, and one inventing a uid to control it. Verified empirically: HEADLESS ResourceSaver stamps no header uid and registers nothing (editor builds do both), so the brand-new headless case asserts the graceful omission and the presence cases run against a registered or header uid.
func _test_creation_uid_disclosure() -> void:
	var out := await _run("create_resource", {"from": "Resource", "path": TMP_DIR + "/uid_disclosed.tres"}, true)
	_check(out.begins_with("Created") and not out.contains("its uid is"), "the clause is omitted gracefully when headless save yields no uid")
	var pre := TMP_DIR + "/uid_disclosed_pre.tres"
	var id := ResourceUID.create_id()
	# Simulate what the editor's save path provides for free: the destination's uid known to the registry.
	ResourceUID.add_id(id, pre)
	out = await _run("create_resource", {"from": "Resource", "path": pre}, true)
	var re := RegEx.create_from_string("its uid is (uid://[0-9a-z]+)")
	var found := re.search(out)
	_check(found != null and found.get_string(1) == ResourceUID.id_to_text(id), "create_resource confirms with the registered non-empty uid")
	var planned := ResourceUID.id_to_text(ResourceUID.create_id())
	_write(TMP_DIR + "/uid_disclosed_user.gd", "extends RefCounted\n\nvar x := preload(\"%s\")\n" % planned)
	out = await _run("write_file", {"path": TMP_DIR + "/uid_disclosed_written.tres", "content": "[gd_resource type=\"Resource\" format=3 uid=\"%s\"]\n\n[resource]\n" % planned}, true)
	_check(out.contains("its uid is " + planned), "write_file discloses the kept header uid")
	out = await _run("write_file", {"path": TMP_DIR + "/uid_disclosed_none.tres", "content": "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n"}, true)
	_check(not out.contains("its uid is"), "the clause is omitted when no uid resolves")
	# The transcript case behind the header-only probe: a headerless .tres whose first uid= line is a dependency's must not have that uid claimed as its own.
	var dep_gd := TMP_DIR + "/uid_dep_script.gd"
	_write(dep_gd, "extends Resource\n")
	var dep_id := ResourceUID.create_id()
	ResourceUID.add_id(dep_id, dep_gd)
	var dep_uid := ResourceUID.id_to_text(dep_id)
	out = await _run("write_file", {"path": TMP_DIR + "/uid_headerless_dep.tres", "content": "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" uid=\"%s\" path=\"%s\" id=\"1_a\"]\n\n[resource]\nscript = ExtResource(\"1_a\")\n" % [dep_uid, dep_gd]}, true)
	_check(out.begins_with("Created") and not out.contains(dep_uid), "a dependency's ext_resource uid is never reported as the new file's own")


## An explicit check_script whose error set matches what was already reported this run says so outright, instead of leaving the model to reason out pre-existing damage from the grouped counts.
func _test_check_script_unchanged_framing() -> void:
	var broken := TMP_DIR + "/recheck_broken.gd"
	_write(broken, "extends RefCounted\n\n\nfunc oops( -> int:\n\treturn 1\n")
	var out := await _run("check_script", {"path": broken}, false)
	_check(out.contains("parse/compile error") and not out.contains("unchanged since it was first reported"), "the first explicit report carries no unchanged framing")
	_check(out.contains("Offending region") and out.contains("func oops( -> int:"), "check_script excerpts the offending lines")
	out = await _run("check_script", {"path": broken}, false)
	_check(out.contains("unchanged since it was first reported") and out.contains("pre-existing"), "the second identical report is framed as pre-existing")
	_write(broken, "extends RefCounted\n\n\nfunc oops() -> int:\n\treturn undeclared_thing\n")
	out = await _run("check_script", {"path": broken}, false)
	_check(not out.contains("unchanged since it was first reported"), "a changed error set drops the framing")
	# When the model's own edit broke the file, the unchanged framing must own that instead of calling it pre-existing (transcript-observed: "pre-existing" coaxed a session into abandoning a file it broke).
	var blamed := TMP_DIR + "/recheck_blamed.gd"
	_write(blamed, "extends RefCounted\n\n\nfunc ok() -> int:\n\treturn 1\n")
	await _run("read_file", {"path": blamed}, false)
	await _run("edit_file", {"path": blamed, "old_string": "return 1", "new_string": "return undeclared_thing"}, true)
	await _run("check_script", {"path": blamed}, false)
	out = await _run("check_script", {"path": blamed}, false)
	_check(out.contains("YOUR unfixed errors") and not out.contains("likely pre-existing"), "an unchanged set the model's own edit introduced is framed as its own")
	_write(blamed, "extends RefCounted\n\n\nfunc ok() -> int:\n\treturn 1\n")
	await _run("check_script", {"path": blamed}, false)


## Parse errors are attributed to the file they belong to before any diffing or blame: another file's [ext_resource]/preload load noise (48-60 lines per check in the wild, varying run to run) must never inflate an edit's "new error" count or a check_script report, but it must stay visible as separated noise.
func _test_error_classification() -> void:
	var output := "\n".join([
		"ERROR: res://other.tres:5 - Parse Error: [ext_resource] referenced non-existent resource at: res://missing.gd",
		"   at: (scene/resources/resource_format_text.cpp:284)",
		"ERROR: res://second.tres:9 - Parse Error: [ext_resource] referenced non-existent resource at: res://missing.gd",
		"   at: (scene/resources/resource_format_text.cpp:284)",
		"SCRIPT ERROR: Parse Error: Could not preload resource file \"res://other.tres\".",
		"          at: GDScript::reload (res://game.gd:12)",
		"SCRIPT ERROR: Parse Error: Unexpected token in class body.",
		"          at: GDScript::reload (res://elsewhere.gd:3)",
		"SCRIPT ERROR: Parse Error: Unattributed oddity.",
		"some unrelated line",
	])
	var classified: Dictionary = GDLLMTools._classified_parse_errors(output, "res://game.gd")
	_check(classified["own"] == ["Could not preload resource file \"res://other.tres\".", "Unattributed oddity."], "only the checked file's own (or unattributed) errors are kept for diffing")
	_check(classified["own_located"] == ["line 12: Could not preload resource file \"res://other.tres\".", "Unattributed oddity."], "own errors keep their line numbers for the report")
	_check(classified["foreign"].size() == 3 and String(classified["foreign"][0]).begins_with("res://other.tres:5:"), "other files' errors are classified as foreign, with their origin named")
	var noise := GDLLMTools._foreign_noise_note(classified["foreign"], "res://game.gd")
	_check(noise.contains("NOT res://game.gd's errors") and noise.contains("3 load error(s)"), "the noise note separates foreign errors without hiding them")
	_check(noise.contains("res://second.tres:9") and not noise.contains("res://elsewhere.gd:3:"), "the note carries two examples at most, deduplicated")
	_check(noise.contains("missing dependency") and not noise.contains("EXISTS on disk"), "a genuinely absent dependency keeps the missing-dependency framing")
	# The engine emits "non-existent" for any failed load; when the named file is on disk the note must say so, or the reader hunts for a missing file that exists (transcript-observed with goal_telemetry.gd).
	var real := "res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd"
	var lying := GDLLMTools._foreign_noise_note(["res://q.tres:10: [ext_resource] referenced non-existent resource at: %s." % real], "res://game.gd")
	_check(lying.contains("%s EXISTS on disk" % real) and lying.contains("instead of hunting for a missing one") and not lying.contains("missing dependency"), "an existing file blamed as non-existent is traced to its failed load instead")
	_check(GDLLMTools._foreign_noise_note([], "res://game.gd") == "", "no foreign noise, no note")
	# Compile errors count as real damage now that checks run with autoloads registered, and a broken script erroring twice in one run — at autoload setup and in the check proper — must report once.
	var compile_output := "\n".join([
		"SCRIPT ERROR: Compile Error: Identifier not found: Missing",
		"          at: GDScript::reload (res://game.gd:7)",
		"SCRIPT ERROR: Compile Error: Identifier not found: Missing",
		"          at: GDScript::reload (res://game.gd:7)",
		"SCRIPT ERROR: Compile Error: Identifier not found: Missing",
		"          at: GDScript::reload (res://other.gd:4)",
	])
	var compiled: Dictionary = GDLLMTools._classified_parse_errors(compile_output, "res://game.gd")
	_check(compiled["own_located"] == ["line 7: Identifier not found: Missing"], "compile errors are scraped and an exact located repeat collapses to one")
	_check(compiled["foreign"] == ["res://other.gd:4: Identifier not found: Missing"], "another file's compile error stays foreign")
	_check(GDLLMTools._error_set_fingerprint(["line 3: foo", "bar"]) == GDLLMTools._error_set_fingerprint(["bar", "line 9: foo"]), "the ledger fingerprint ignores line shifts and ordering")
	_check(GDLLMTools._error_set_fingerprint(["line 3: foo"]) != GDLLMTools._error_set_fingerprint(["line 3: foo", "line 3: foo"]), "the fingerprint still counts duplicates")


## The pre/post diff can be fooled by run-to-run noise (transcripts: "59 new" / "71 new" accusations that were a missing dependency's load noise); check_script's ledger is the second witness, so an error set already reported this editor run is never blamed on the edit that ran into it.
func _test_edit_ledger_demotion() -> void:
	var p := TMP_DIR + "/ledger_demo.gd"
	var clean := "extends RefCounted\n\n\nfunc ok() -> int:\n\treturn 1\n"
	_write(p, clean)
	await _run("read_file", {"path": p}, false)
	var out := await _run("edit_file", {"path": p, "old_string": "return 1", "new_string": "return undeclared_thing"}, true)
	_check(out.contains("YOU introduced"), "a genuinely new error set is still accused")
	# Put that same error set in the ledger the way a session would (an explicit check_script), rewind the file, and replay the edit: same diff, but now a known set — and one the model's FIRST edit was blamed for, so the demotion says whose it is.
	await _run("check_script", {"path": p}, false)
	_write(p, clean)
	out = await _run("edit_file", {"path": p, "old_string": "return 1", "new_string": "return undeclared_thing"}, true)
	_check(out.contains("YOUR earlier edit") and not out.contains("YOU introduced"), "a re-landed error set already blamed on the model is demoted with honest attribution")
	_check(GDLLMTools._fallback_ledger.broken_files.has(p), "the demoted verdict still records the file as broken")
	out = await _run("read_file", {"path": p}, false)
	_check(out.contains("YOUR earlier edit") and not out.contains("likely pre-existing"), "the automatic hook attributes the model's own unfixed errors instead of calling them pre-existing")
	_write(p, clean)
	await _run("check_script", {"path": p}, false)
	_check(not GDLLMTools._fallback_ledger.auto_check_reports.has(p), "a clean check settles the shared ledger")
	# The not-your-damage variant: the set was reported (read hook fills the ledger) with NO edit verdict blaming the model, then an edit re-lands it — pre-existing framing, and the broken-file ledger stays out of it.
	var q := TMP_DIR + "/ledger_demo_pre.gd"
	var q_clean := "extends RefCounted\n\n\nfunc oops() -> int:\n\treturn 1\n"
	_write(q, "extends RefCounted\n\n\nfunc oops() -> int:\n\treturn undeclared_thing\n")
	await _run("read_file", {"path": q}, false)
	_write(q, q_clean)
	out = await _run("edit_file", {"path": q, "old_string": "return 1", "new_string": "return undeclared_thing"}, true)
	_check(out.contains("likely pre-existing") and not out.contains("YOUR earlier edit"), "a never-blamed error set keeps the pre-existing framing")
	_check(not GDLLMTools._fallback_ledger.broken_files.has(q), "pre-existing damage stays out of the broken-file ledger")
	_write(q, q_clean)
	await _run("check_script", {"path": q}, false)


## The disk/live divergence warning on scene reads is editor-only, so headless reads of scene files stay clean.
func _test_scene_divergence_note() -> void:
	_check(GDLLMTools._scene_divergence_note("res://x.tscn") == "", "the divergence warning is editor-only, so headless reads stay clean")


## Picker SPECS ("Texture2D,-AnimatedTexture,…") name a base plus exclusions, not one class name; taking them verbatim falsely rejected every valid resource in the wild (a GradientTexture2D orb refused as not a "Texture2D,-AnimatedTexture,…"). edit_resource's object coercion resolves them through this matcher.
func _test_class_spec_matching() -> void:
	_check(bool(GDLLMTools._resource_matches_class_spec(GradientTexture2D.new(), "Texture2D,-AnimatedTexture")["ok"]), "a base-class subclass passes a picker spec (the wild false rejection)")
	var verdict := GDLLMTools._resource_matches_class_spec(AnimatedTexture.new(), "Texture2D,-AnimatedTexture")
	_check(not bool(verdict["ok"]) and String(verdict["excluded"]) == "AnimatedTexture", "an excluded subclass is refused, naming the exclusion")
	_check(not bool(GDLLMTools._resource_matches_class_spec(Resource.new(), "Texture2D,-AnimatedTexture")["ok"]), "an unrelated resource is refused")
	_check(GDLLMTools._class_spec_label("Texture2D,-AnimatedTexture") == "Texture2D", "the spec label drops exclusions")
	_check(GDLLMTools._class_spec_label("Font,FontVariation") == "Font or FontVariation", "a multi-base spec reads as alternatives")


## A saved one-node scene file at TMP_DIR/`name`.tscn, for the load-check tests.
func _save_scene(name: String) -> String:
	var packed := PackedScene.new()
	var scene_root := Node2D.new()
	scene_root.name = name.capitalize()
	packed.pack(scene_root)
	var path := TMP_DIR + "/%s.tscn" % name
	ResourceSaver.save(packed, path)
	scene_root.free()
	return path


func _test_edit_file_scene_validation() -> void:
	var scn := _save_scene("editable")
	# full: true because a plain .tscn read returns the shape-only scene map, which deliberately leaves the edit gate unsatisfied.
	await _run("read_file", {"path": scn, "full": true}, false)
	var out := await _run("edit_file", {"path": scn, "old_string": "type=\"Node2D\"", "new_string": "type=\"Sprite2D\""}, true)
	_check(out.begins_with("Edited"), "edit_file .tscn valid edit passes the load check")
	out = await _run("edit_file", {"path": scn, "old_string": "[node", "new_string": "[nod"}, true)
	_check(out.contains("BROKEN"), "edit_file .tscn load break reports the file as broken")
	_check(_read(scn).contains("[nod "), "edit_file .tscn load break keeps the edit on disk")
	out = await _run("edit_file", {"path": scn, "old_string": "[nod ", "new_string": "[node "}, true)
	_check(out.begins_with("Edited"), "edit_file repairs the broken scene file")
	# The transcript case behind the load excerpts: GDScript-only Color("hex") syntax, which the engine reports as a bare "Parse error." with only a line number.
	var tag_line := _read(scn).split("\n")[2]
	out = await _run("edit_file", {"path": scn, "old_string": tag_line, "new_string": tag_line + "\nmodulate = Color(\"c7fcff\")"}, true)
	_check(out.contains("BROKEN") and out.contains("Offending region"), "edit_file .tscn load break excerpts the offending region")
	_check(out.contains("modulate = Color(\"c7fcff\")"), "the load-break excerpt quotes the culprit line itself")
	out = await _run("edit_file", {"path": scn, "old_string": "\nmodulate = Color(\"c7fcff\")", "new_string": ""}, true)
	_check(out.begins_with("Edited"), "removing the culprit line passes the load check again")
	out = await _run("edit_file", {"path": scn, "old_string": "text that is not in the file", "new_string": "x"}, true)
	_check(out.contains("copied VERBATIM"), "edit_file .tscn not-found hint teaches verbatim copying")
	_check(not out.contains("tabs"), "edit_file .tscn not-found hint drops the .gd tabs advice")
	out = await _run("edit_file", {"path": scn, "old_string": "<24 bytes elided>", "new_string": "x"}, true)
	_check(out.contains("never exist in the file"), "edit_file elision-marker old_string is called out")


## The unknown-property check on scene writes: a stored property or node type the engine doesn't know loads fine and is silently dropped at instantiation — the one failure text edits used to hide completely — so the load check flags exactly what an edit introduced, and nothing more.
func _test_scene_unknown_property_warning() -> void:
	var scn := TMP_DIR + "/propcheck.tscn"
	await _run("write_file", {"path": scn, "content": "[gd_scene format=3]\n\n[node name=\"Propcheck\" type=\"Node2D\"]\n"}, true)
	var out := await _run("edit_file", {"path": scn, "old_string": "[node name=\"Propcheck\" type=\"Node2D\"]", "new_string": "[node name=\"Propcheck\" type=\"Node2D\"]\npositon = Vector2(3, 4)"}, true)
	_check(out.contains("silently DROP") and out.contains("\"positon\""), "a typo'd property is flagged as dropped")
	_check(out.contains("position"), "the warning suggests the real property name")
	_check(out.contains("loads cleanly (engine-checked)"), "the warning rides a kept, loading file — nothing is BROKEN")
	out = await _run("edit_file", {"path": scn, "old_string": "positon = Vector2(3, 4)", "new_string": "positon = Vector2(3, 4)\nvisible = false"}, true)
	_check(not out.contains("silently DROP"), "a pre-existing bogus property is not re-blamed on an unrelated edit")
	out = await _run("edit_file", {"path": scn, "old_string": "visible = false", "new_string": "visible = false\nmetadata/note = 1\nparameters/blend = 0.5"}, true)
	_check(not out.contains("silently DROP"), "slash-namespaced names are never accused")
	out = await _run("edit_file", {"path": scn, "old_string": "type=\"Node2D\"", "new_string": "type=\"Spritee2D\""}, true)
	_check(out.contains("unknown type \"Spritee2D\""), "an unknown node type loads silently and is flagged")
	var script_path := TMP_DIR + "/propcheck_script.gd"
	_write(script_path, "extends Node2D\n\n@export var speed := 1.0\n")
	var scripted := TMP_DIR + "/propcheck_scripted.tscn"
	var content := "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]\n\n[node name=\"Root\" type=\"Node2D\"]\nscript = ExtResource(\"1\")\nspeed = 2.0\nspede = 3.0\n" % script_path
	out = await _run("write_file", {"path": scripted, "content": content}, true)
	_check(out.contains("\"spede\"") and out.contains("silently DROP"), "a bogus script-variable name on a brand-new file is flagged")
	_check(not out.contains("\"speed\""), "the script's real exported variable is not accused")


func _cleanup() -> void:
	_remove_dir_recursive(TMP_DIR)


func _remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_remove_dir_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)
