extends SceneTree
## Headless regression tests for the configuration and discovery tools: describe_project / set_project_setting (GDLLMProject), search_docs (GDLLMDocs.search), and list_dependencies.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/project_docs_deps_test.gd
## Exits nonzero on any failure. set_project_setting tests write real settings and save project.godot, then revert everything they touched — run in a worktree if that matters to you.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMProject = preload("res://addons/gdllm-godot-agentic-harness/gdllm_project.gd")
const GDLLMDocs = preload("res://addons/gdllm-godot-agentic-harness/gdllm_docs.gd")

const TMP_DIR := "res://__gdllm_deps_tmp"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_registration()
	_test_describe_project()
	_test_set_input_action()
	_test_event_spec_errors()
	_test_set_autoload()
	_test_plain_setting()
	_test_unknown_setting_guard()
	_test_search_docs()
	_test_docs_prose_cap()
	_test_setting_value_clip()
	_test_dependencies()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real execute dispatch and return its content string.
func _run(tool_name: String, args: Dictionary, allow_changes: bool = false) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes))["content"])


func _test_registration() -> void:
	for tool_name in ["describe_project", "set_project_setting", "search_docs", "list_dependencies"]:
		_check(GDLLMTools.is_registered(tool_name), "%s is registered" % tool_name)
	_check(GDLLMTools.is_mutating("set_project_setting"), "set_project_setting is mutating")
	for tool_name in ["describe_project", "search_docs", "list_dependencies"]:
		_check(not GDLLMTools.is_mutating(tool_name), "%s is read-only" % tool_name)
	_check((await _run("set_project_setting", {"setting": "input/x", "value": "Space"}, false)).begins_with("Error:"), "set_project_setting is refused while changes are off")
	var found := false
	for entry in GDLLMTools.search("project setting", true):
		if String(entry["name"]) == "set_project_setting":
			found = true
	_check(found, "tool_search finds set_project_setting")


func _test_describe_project() -> void:
	var overview := await _run("describe_project", {})
	_check(overview.contains("Main scene:"), "overview names the main scene")
	_check(overview.contains("gdllm-godot-agentic-harness"), "overview carries the project name")
	_check(overview.contains("ui_") or overview.contains("Input actions"), "overview covers input actions")
	var filtered := await _run("describe_project", {"filter": "application/config/name"})
	_check(filtered.contains("application/config/name") and filtered.contains("gdllm-godot-agentic-harness"), "filter lists the matching setting with its value")
	_check((await _run("describe_project", {"filter": "zz_no_such_prefix"})).begins_with("No project settings match"), "an unmatched filter says so")
	var one := await _run("describe_project", {"setting": "application/config/name"})
	_check(one.contains("gdllm-godot-agentic-harness"), "one exact setting shows its value")
	_check((await _run("describe_project", {"query": "application/config/name"})).contains("application/config/name"), "a schema-blind \"query\" argument acts as the filter")


func _test_set_input_action() -> void:
	var result := await _run("set_project_setting", {"setting": "input/gdllm_test_jump", "value": ["Space", "JoyButton:0"]}, true)
	_check(result.contains("Added input action"), "adding an action confirms: %s" % result)
	_check(ProjectSettings.has_setting("input/gdllm_test_jump"), "the action landed in ProjectSettings")
	var stored: Dictionary = ProjectSettings.get_setting("input/gdllm_test_jump")
	var events: Array = stored["events"]
	_check(events.size() == 2, "both events were stored")
	_check(events[0] is InputEventKey and (events[0] as InputEventKey).keycode == KEY_SPACE, "the key spec became a Space key event")
	_check(events[1] is InputEventJoypadButton and (events[1] as InputEventJoypadButton).button_index == JOY_BUTTON_A, "the joy spec became button 0")
	_check((await _run("describe_project", {"setting": "gdllm_test_jump"})).contains("Space"), "a bare action name resolves through the input/ prefix")
	var updated := await _run("set_project_setting", {"setting": "input/gdllm_test_jump", "events": ["Ctrl+Shift+S"], "deadzone": 0.3}, true)
	_check(updated.contains("Updated input action"), "re-setting reports an update")
	stored = ProjectSettings.get_setting("input/gdllm_test_jump")
	var key := stored["events"][0] as InputEventKey
	_check(key.ctrl_pressed and key.shift_pressed and key.keycode == KEY_S, "modifiers parsed from Ctrl+Shift+S")
	_check(is_equal_approx(float(stored["deadzone"]), 0.3), "the deadzone argument was honored")
	var removed := await _run("set_project_setting", {"setting": "input/gdllm_test_jump", "revert": true}, true)
	_check(removed.contains("Removed"), "revert removes a custom action")
	_check(not ProjectSettings.has_setting("input/gdllm_test_jump"), "the action is gone from ProjectSettings")


func _test_event_spec_errors() -> void:
	_check((await _run("set_project_setting", {"setting": "input/gdllm_bad", "value": "NotARealKeyName"}, true)).begins_with("Error:"), "an unknown key name is refused")
	_check(not ProjectSettings.has_setting("input/gdllm_bad"), "a refused action was not created")
	var mouse := GDLLMProject._parse_event_spec("MouseButton:Left")
	_check(mouse.has("event") and (mouse["event"] as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT, "mouse button spec parses")
	var axis := GDLLMProject._parse_event_spec("JoyAxis:1-")
	_check(axis.has("event") and (axis["event"] as InputEventJoypadMotion).axis == JOY_AXIS_LEFT_Y and (axis["event"] as InputEventJoypadMotion).axis_value == -1.0, "joy axis spec parses with its direction")
	var named_axis := GDLLMProject._parse_event_spec("JoyAxis:left_y+")
	_check(named_axis.has("event") and (named_axis["event"] as InputEventJoypadMotion).axis_value == 1.0, "a named axis parses")
	_check(GDLLMProject._parse_event_spec("Wrong+S").has("error"), "an unknown modifier is refused")
	var lower := GDLLMProject._parse_event_spec("space")
	_check(lower.has("event") and (lower["event"] as InputEventKey).keycode == KEY_SPACE, "a lower-case key name resolves")


func _test_set_autoload() -> void:
	var result := await _run("set_project_setting", {"setting": "autoload/GdllmTestState", "value": "res://addons/gdllm-godot-agentic-harness/llm_client.gd"}, true)
	_check(result.contains("Added autoload"), "adding an autoload confirms: %s" % result)
	_check(String(ProjectSettings.get_setting("autoload/GdllmTestState", "")) == "*res://addons/gdllm-godot-agentic-harness/llm_client.gd", "the autoload stored enabled (* prefix)")
	_check((await _run("set_project_setting", {"setting": "autoload/GdllmBad", "value": "res://no_such_file.gd"}, true)).begins_with("Error:"), "an autoload pointing at a missing file is refused")
	_check((await _run("set_project_setting", {"setting": "autoload/GdllmTestState", "revert": true}, true)).contains("Removed"), "revert removes the autoload")
	_check(not ProjectSettings.has_setting("autoload/GdllmTestState"), "the autoload is gone")


func _test_plain_setting() -> void:
	var result := await _run("set_project_setting", {"setting": "application/run/max_fps", "value": 60.0}, true)
	_check(result.contains("Set \"application/run/max_fps\""), "setting a plain value confirms: %s" % result)
	var stored: Variant = ProjectSettings.get_setting("application/run/max_fps")
	_check(stored is int and int(stored) == 60, "the JSON float was coerced to the setting's int type")
	_check((await _run("set_project_setting", {"setting": "application/run/max_fps", "value": "not a number"}, true)).begins_with("Error:"), "a type mismatch is refused")
	var reverted := await _run("set_project_setting", {"setting": "application/run/max_fps", "revert": true}, true)
	_check(reverted.contains("Reverted"), "reverting a built-in restores its default")
	_check(int(ProjectSettings.get_setting("application/run/max_fps")) == 0, "the default value is back")


func _test_unknown_setting_guard() -> void:
	var result := await _run("set_project_setting", {"setting": "application/run/main_scen", "value": "res://x.tscn"}, true)
	_check(result.begins_with("Error:") and result.contains("main_scene"), "a typo is refused with a near-miss suggestion")
	_check(not ProjectSettings.has_setting("application/run/main_scen"), "the typo did not create a setting")
	var created := await _run("set_project_setting", {"setting": "gdllm_test/custom_flag", "value": true, "create": true}, true)
	_check(created.contains("Created new custom setting"), "create=true allows a new custom setting")
	_check(bool(ProjectSettings.get_setting("gdllm_test/custom_flag")) == true, "the custom setting holds its value")
	await _run("set_project_setting", {"setting": "gdllm_test/custom_flag", "revert": true}, true)
	_check(not ProjectSettings.has_setting("gdllm_test/custom_flag"), "the custom setting was cleaned up")


func _test_search_docs() -> void:
	var wrap := await _run("search_docs", {"query": "text wrap"})
	_check(wrap.contains("autowrap"), "\"text wrap\" surfaces autowrap: %s" % wrap.substr(0, 200))
	var chatty := await _run("search_docs", {"query": "how do I make text wrap"})
	_check(chatty.contains("autowrap"), "stopwords are dropped from a conversational query")
	_check((await _run("search_docs", {"query": "zzqx_no_such_word"})).begins_with("No documentation entries"), "no hits says so")
	_check((await _run("search_docs", {})).begins_with("Error:"), "a missing query errors")
	var exact := await _run("search_docs", {"query": "autowrap_mode"})
	_check(exact.contains("Label.autowrap_mode"), "an exact member name ranks in the hits")


## The prose cap's lever: past MAX_PROSE_CHARS the cut names full: true — the model-callable lever the old note lacked (its Help-panel pointer serves only the user) — and full serves everything.
func _test_docs_prose_cap() -> void:
	var long_text := "z".repeat(GDLLMDocs.MAX_PROSE_CHARS + 500)
	var capped: String = GDLLMDocs._capped_prose(long_text, false)
	_check(capped.contains("500 more characters — re-run with full: true"), "the prose cut names the withheld count and the full: true lever")
	_check(capped.contains("Help panel"), "the user-facing pointer survives alongside the model lever")
	_check(GDLLMDocs._capped_prose(long_text, true) == long_text, "full: true serves the whole prose")


## The setting-value clip's lever: the list clip names the setting zoom, and the zoom itself renders whole — a zoom returning the same stump was the audit's dead end.
func _test_setting_value_clip() -> void:
	var long_value := "v".repeat(GDLLMProject.MAX_VALUE_CHARS + 60)
	_check(GDLLMProject._value_text(long_value).contains("chars total — \"setting\" with this name prints it whole"), "the list clip names the zoom lever")
	_check(GDLLMProject._value_text(long_value, true) == "\"%s\"" % long_value, "the zoom renders the value whole")


func _test_dependencies() -> void:
	var many := range(GDLLMTools.MAX_DEPENDENCY_LINES + 10)
	var capped: Array = GDLLMTools._capped_lines(many)
	_check(capped.size() == GDLLMTools.MAX_DEPENDENCY_LINES + 1 and String(capped[GDLLMTools.MAX_DEPENDENCY_LINES]).contains("full: true"), "a capped listing counts the cut and names the full: true waiver")
	_check(GDLLMTools._capped_lines(many, true).size() == many.size(), "full: true serves every dependency line")
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var script := FileAccess.open(TMP_DIR + "/user.gd", FileAccess.WRITE)
	script.store_string("extends Node\nconst ICON = preload(\"res://icon.svg\")\n")
	script.close()
	var scene := FileAccess.open(TMP_DIR + "/user.tscn", FileAccess.WRITE)
	scene.store_string("[gd_scene load_steps=3 format=3]\n\n[ext_resource type=\"Texture2D\" path=\"res://icon.svg\" id=\"1\"]\n[ext_resource type=\"Script\" path=\"%s/user.gd\" id=\"2\"]\n\n[node name=\"Root\" type=\"Sprite2D\"]\ntexture = ExtResource(\"1\")\nscript = ExtResource(\"2\")\n" % TMP_DIR)
	scene.close()
	var broken := FileAccess.open(TMP_DIR + "/broken.tres", FileAccess.WRITE)
	broken.store_string("[gd_resource type=\"LabelSettings\" load_steps=2 format=3]\n\n[ext_resource type=\"FontFile\" path=\"res://gdllm_missing_font.ttf\" id=\"1\"]\n\n[resource]\nfont = ExtResource(\"1\")\n")
	broken.close()

	var forward := await _run("list_dependencies", {"path": TMP_DIR + "/user.tscn"})
	_check(forward.contains("res://icon.svg") and forward.contains("user.gd"), "a scene's forward deps list its texture and script: %s" % forward)
	var missing := await _run("list_dependencies", {"path": TMP_DIR + "/broken.tres"})
	_check(missing.contains("MISSING"), "a dangling reference is flagged MISSING: %s" % missing)
	var script_fwd := await _run("list_dependencies", {"path": TMP_DIR + "/user.gd"})
	_check(script_fwd.contains("res://icon.svg"), "a script's preload literal shows as a forward dep")
	var reverse := await _run("list_dependencies", {"path": "res://icon.svg", "reverse": true})
	_check(reverse.contains(TMP_DIR + "/user.tscn"), "reverse finds the scene using the file")
	_check(reverse.contains(TMP_DIR + "/user.gd"), "reverse finds the script preloading the file")
	_check(reverse.contains("res://project.godot"), "reverse finds the project-settings reference (config/icon)")
	var unused := await _run("list_dependencies", {"path": TMP_DIR + "/broken.tres", "reverse": true})
	_check(unused.begins_with("Nothing in the project references"), "an unused file reports no users")
	_check((await _run("list_dependencies", {"path": "res://no_such_file.xyz"})).begins_with("Error:"), "a missing path errors")

	for f in ["user.gd", "user.tscn", "broken.tres"]:
		DirAccess.remove_absolute(TMP_DIR + "/" + f)
	DirAccess.remove_absolute(TMP_DIR)
