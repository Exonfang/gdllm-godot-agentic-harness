extends SceneTree
## Headless regression tests for the editor-awareness tools — read_editor_selection, read_undo_history, open_for_user — and GDLLMEditorState's composers.
## The live halves (gathering real editor state, actually taking focus) need the running editor; what IS testable here is registration and search reachability, argument validation, the headless refusals, open_for_user's path resolution, the undo windowing math, and both composers over fixture state.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/editor_state_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMEditorState = preload("res://addons/gdllm-godot-agentic-harness/gdllm_editor_state.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_registration()
	_test_search_reachability()
	await _test_headless_refusals()
	await _test_argument_validation()
	await _test_open_for_user_resolution()
	_test_selection_formatting()
	_test_selection_absences()
	_test_undo_windowing()
	_test_undo_markers_and_empty()
	_test_undo_scope_disclosures()
	_test_unsaved_tab_skipped()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _names(results: Array) -> Array:
	var names: Array = []
	for entry in results:
		names.append(String(entry["name"]))
	return names


func _test_registration() -> void:
	for tool_name in ["read_editor_selection", "read_undo_history", "open_for_user"]:
		_check(GDLLMTools.REGISTRY.has(tool_name), "%s is registered" % tool_name)
		_check(not GDLLMTools.is_mutating(tool_name), "%s stays available with Make changes off" % tool_name)
	_check(GDLLMTools.REPEAT_REAL_WORK_TOOLS.has("open_for_user"), "an identical re-open counts as real work, not a stale repeat")


func _test_search_reachability() -> void:
	_check("read_editor_selection" in _names(GDLLMTools.search("selection", false)), "\"selection\" finds read_editor_selection")
	_check("read_editor_selection" in _names(GDLLMTools.search("what user selected", false)), "a natural selected-what phrase finds read_editor_selection")
	_check("read_undo_history" in _names(GDLLMTools.search("undo", false)), "\"undo\" finds read_undo_history")
	_check("read_undo_history" in _names(GDLLMTools.search("recent user actions", false)), "a what-did-they-do phrase finds read_undo_history")
	_check("open_for_user" in _names(GDLLMTools.search("open file user", false)), "an open-for-them phrase finds open_for_user")
	_check(_names(GDLLMTools.search("open_for_user", false)) == ["open_for_user"], "exact name returns only open_for_user")


func _test_headless_refusals() -> void:
	var selection: Dictionary = await GDLLMTools.execute("read_editor_selection", {})
	_check(String(selection["content"]).begins_with("Error") and String(selection["content"]).contains("headless"), "read_editor_selection refuses headless naming the cause")
	var undo: Dictionary = await GDLLMTools.execute("read_undo_history", {})
	_check(String(undo["content"]).begins_with("Error") and String(undo["content"]).contains("headless"), "read_undo_history refuses headless naming the cause")
	var real_path := "res://addons/gdllm-godot-agentic-harness/gdllm_editor_state.gd"
	var open: Dictionary = await GDLLMTools.execute("open_for_user", {"path": real_path})
	var content := String(open["content"])
	_check(content.begins_with("Error") and content.contains("headless"), "open_for_user refuses headless naming the cause")
	_check(content.contains(real_path), "the headless open refusal still reports the resolved path")
	_check(content.contains("nothing was opened"), "the headless open refusal says what was withheld")


func _test_argument_validation() -> void:
	var undo: Dictionary = await GDLLMTools.execute("read_undo_history", {"bogus": 3})
	_check(String(undo["content"]).contains("unrecognized argument") and String(undo["content"]).contains("window"), "a misnamed undo argument errors naming the real key")
	var junk: Dictionary = await GDLLMTools.execute("open_for_user", {"junk": true})
	_check(String(junk["content"]).contains("unrecognized argument"), "open_for_user with only unknown keys errors instead of ignoring them")
	var missing: Dictionary = await GDLLMTools.execute("open_for_user", {})
	_check(String(missing["content"]).contains("no file was named"), "open_for_user without a path says nothing was opened and why")


func _test_open_for_user_resolution() -> void:
	var ghost: Dictionary = await GDLLMTools.execute("open_for_user", {"path": "no_such_file_anywhere.gd"})
	_check(String(ghost["content"]).begins_with("Error") and String(ghost["content"]).contains("Nothing was opened"), "an unresolvable path is refused stating nothing was opened")
	var dir: Dictionary = await GDLLMTools.execute("open_for_user", {"path": "res://addons"})
	_check(String(dir["content"]).contains("DIRECTORY"), "a directory is named as one rather than reported missing")


func _test_selection_formatting() -> void:
	var state := {
		"active_scene": "res://levels/cave.tscn",
		"open_scenes": ["res://levels/cave.tscn", "res://player/player.tscn", "res://ui/hud.tscn"],
		"selected_nodes": ["Player (Player)", "Player/Sprite2D (Sprite2D)"],
		"script_path": "res://player/player.gd",
		"script_line": 42,
		"inspector": "node Player (Player)",
		"fs_paths": ["res://player/player.gd"],
		"fs_current": "res://player/player.gd",
	}
	var out := GDLLMEditorState.format_selection(state)
	_check(out.contains("Active scene: res://levels/cave.tscn"), "the active scene leads its line")
	_check(out.contains("other open tabs: player.tscn, hud.tscn"), "other tabs list as bare names without the active one")
	_check(out.count("cave.tscn") == 1, "the active scene is not repeated in the tab list")
	_check(out.contains("Selected nodes (2): Player (Player), Player/Sprite2D (Sprite2D)"), "selected nodes list with their count")
	_check(out.contains("res://player/player.gd, cursor at line 42"), "the script line carries the cursor position")
	_check(out.contains("Inspector: node Player (Player)."), "the Inspector line names its object")
	_check(out.contains("FileSystem dock: res://player/player.gd selected"), "a single dock selection reads as one path")
	var many: Array = []
	for i in 15:
		many.append("Node%d (Node2D)" % i)
	var capped := GDLLMEditorState.format_selection({"selected_nodes": many})
	_check(capped.contains("(+3 more)"), "a long node list collapses to a counted remainder")
	var lineless := GDLLMEditorState.format_selection({"script_path": "res://a.gd"})
	_check(lineless.contains("Script editor: res://a.gd.") and not lineless.contains("cursor"), "an unknown cursor line is omitted, not shown as zero")


func _test_selection_absences() -> void:
	var out := GDLLMEditorState.format_selection({})
	_check(out.contains("Active scene: none open."), "no scene reads as an absence, not an omission")
	_check(out.contains("Selected nodes: none."), "no selection reads as an absence")
	_check(out.contains("Script editor: no script open."), "no script reads as an absence")
	_check(out.contains("Inspector: nothing."), "an empty Inspector reads as an absence")
	_check(out.contains("FileSystem dock: nothing selected."), "an empty dock selection reads as an absence")
	var browsing := GDLLMEditorState.format_selection({"fs_current": "res://levels"})
	_check(browsing.contains("nothing selected (browsing res://levels)"), "an unselected dock still names the path being browsed")


func _test_undo_windowing() -> void:
	var names: Array = []
	for i in 23:
		names.append("action %d" % (i + 1))
	var history := {"label": "Scene history (res://levels/cave.tscn)", "names": names, "current": 22, "has_undo": true, "has_redo": false}
	var out := GDLLMEditorState.format_undo([history], 15)
	_check(out.contains("23 actions, newest first (undo available; nothing to redo)"), "the header counts actions and states undo/redo availability")
	_check(out.contains("  23. action 23") and out.contains("  9. action 9"), "the window spans the newest 15 actions")
	_check(not out.contains("  8. action 8"), "actions past the window are not listed")
	_check(out.contains("(8 older actions not shown") and out.contains("\"window\""), "truncation is counted and names the lever")
	var wide := GDLLMEditorState.format_undo([history], 30)
	_check(not wide.contains("not shown"), "a window covering everything adds no truncation line")
	var both := GDLLMEditorState.format_undo([history, {"label": "Global history", "names": [], "current": -1}], 15)
	_check(both.contains("\n\n") and both.contains("Global history"), "histories render as separate blocks")


func _test_undo_markers_and_empty() -> void:
	var history := {"label": "Scene history (x)", "names": ["a", "b", "c"], "current": 0, "has_undo": true, "has_redo": true}
	var out := GDLLMEditorState.format_undo([history], 15)
	_check(out.contains("3. c (undone)") and out.contains("2. b (undone)"), "actions above the current position are marked undone")
	_check(out.contains("1. a") and not out.contains("1. a (undone)"), "the current action carries no undone mark")
	var all_undone := GDLLMEditorState.format_undo([{"label": "Scene history (x)", "names": ["a"], "current": -1}], 15)
	_check(all_undone.contains("1. a (undone)"), "a fully undone history marks every action")
	var empty := GDLLMEditorState.format_undo([{"label": "Global history", "names": [], "current": -1}], 15)
	_check(empty.contains("empty — nothing was done here this editor session"), "an empty history states the absence")
	var single := GDLLMEditorState.format_undo([{"label": "Scene history (x)", "names": ["a", "b"], "current": 1}], 1)
	_check(single.contains("(1 older action not shown"), "a singular remainder reads as one action")


func _test_undo_scope_disclosures() -> void:
	var no_scene := GDLLMEditorState.format_undo([{"label": "Scene history", "no_scene": true}], 15)
	_check(no_scene.contains("no scene is open, so no scene history exists"), "no scene open states the absence rather than dropping the block")
	var tabbed := {"label": "Scene history (x)", "names": ["a", "b"], "current": 1, "other_scenes": 2}
	var out := GDLLMEditorState.format_undo([tabbed], 15)
	_check(out.contains("(only the active scene's history is readable — the 2 other open scenes each keep their own)"), "other open scenes are disclosed as unreadable")
	var empty_tabbed := GDLLMEditorState.format_undo([{"label": "Scene history (x)", "names": [], "current": -1, "other_scenes": 1}], 15)
	_check(empty_tabbed.contains("nothing was done here this editor session (only the active scene's history is readable — the other open scene keeps its own)"), "an empty active history with other tabs open carries the disclosure where it misleads most")
	var lone := GDLLMEditorState.format_undo([{"label": "Scene history (x)", "names": ["a"], "current": 0, "other_scenes": 0}], 15)
	_check(not lone.contains("other open"), "a lone open scene adds no disclosure")


func _test_unsaved_tab_skipped() -> void:
	var out := GDLLMEditorState.format_selection({"active_scene": "res://a.tscn", "open_scenes": ["res://a.tscn", "", "res://b.tscn"]})
	_check(out.contains("other open tabs: b.tscn.") and not out.contains(", ,"), "an unsaved tab's empty path never renders as a nameless entry")
