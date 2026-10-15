extends SceneTree
## Headless regression tests for project custom tools (GDLLMCustomTools): discovery and loading, the trust rules (user-written files load, model-written ones wait for approval of exactly the reviewed content, a corrupt store fails closed), enable toggles, load errors that point at the fix, and the full path through GDLLMTools — catalog, search, gates, and dispatch.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/custom_tools_test.gd
## Exits nonzero on any failure. Fixtures live under user:// and are removed afterward.

# Preloaded rather than referenced by class_name so the test's own references survive a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMCustomTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_custom_tools.gd")

const BASE := "user://gdllm_custom_tools_test"
const ROOT := BASE + "/tools"
const STORE := BASE + "/store.json"

const READ_ONLY_TOOL := """@tool
extends RefCounted
const DESCRIPTION := "Greets someone by name.\\nReturns the greeting."
const PARAMETERS := {"type": "object", "properties": {"who": {"type": "string"}}, "required": ["who"]}
const READ_ONLY := true
func execute(args: Dictionary) -> String:
	await Engine.get_main_loop().process_frame
	return "hello " + String(args.get("who", ""))
"""

const MUTATING_TOOL := """@tool
extends RefCounted
const DESCRIPTION := "Pretends to change the project."
func execute(args: Dictionary) -> String:
	return "changed"
"""

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	# The coroutine fixture awaits the main loop's frame, which exists only once _init has yielded.
	await process_frame
	_clean()
	await _test_user_tools_load()
	await _test_gates()
	_test_model_written_pending()
	_test_approval()
	_test_disable()
	_test_load_errors()
	_test_corrupt_store()
	await _test_dispatch_notes_pending()
	_clean()
	GDLLMCustomTools.reset_for_tests(GDLLMCustomTools.ROOT, GDLLMCustomTools.STORE_PATH)
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _fresh() -> void:
	_clean()
	DirAccess.make_dir_recursive_absolute(ROOT)
	GDLLMCustomTools.reset_for_tests(ROOT, STORE)


func _clean() -> void:
	for dir_path in [ROOT, BASE]:
		var dir := DirAccess.open(dir_path)
		if dir != null:
			for file in dir.get_files():
				dir.remove(file)
	DirAccess.remove_absolute(ROOT)
	DirAccess.remove_absolute(BASE)


func _write(name: String, text: String) -> String:
	var path := "%s/%s.gd" % [ROOT, name]
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	GDLLMCustomTools.invalidate()
	return path


func _state(name: String) -> String:
	GDLLMCustomTools.invalidate()
	for row: Dictionary in GDLLMCustomTools.status():
		if String(row["name"]) == name:
			return String(row["state"])
	return ""


func _run(tool_name: String, args: Dictionary, allow_changes: bool = false) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes, false, {}, null))["content"])


func _test_user_tools_load() -> void:
	_fresh()
	_write("greet", READ_ONLY_TOOL)
	_check(_state("greet") == "ready", "a file written outside any tool call is the user's and loads")
	_check(GDLLMTools.is_registered("greet"), "a loaded custom tool is registered")
	_check(GDLLMTools.schema_for("greet")["function"]["parameters"]["required"] == ["who"], "its schema carries the declared PARAMETERS")
	var found := GDLLMTools.search("greet")
	_check(found.size() == 1 and String(found[0]["name"]) == "greet", "tool_search finds it by name")
	var catalog := String(GDLLMTools.tool_search_schema()["function"]["description"])
	_check(catalog.contains("- greet(who): Greets someone by name."), "the catalog lists it with its first description line as the summary")
	_check(await _run("greet", {"who": "Ada"}) == "hello Ada", "dispatch awaits a coroutine execute() and returns its text")


func _test_gates() -> void:
	_fresh()
	_write("change_it", MUTATING_TOOL)
	var catalog := String(GDLLMTools.tool_search_schema()["function"]["description"])
	_check(not catalog.contains("change_it"), "a tool not declared READ_ONLY is hidden while Make changes is off")
	_check((await _run("change_it", {})).contains("isn't declared read-only"), "calling it anyway explains the gate and the READ_ONLY remedy")
	_check(await _run("change_it", {}, true) == "changed", "with Make changes on it runs")


func _test_model_written_pending() -> void:
	_fresh()
	GDLLMCustomTools.begin_model_call()
	var path := _write("greet", READ_ONLY_TOOL)
	var newly := GDLLMCustomTools.end_model_call()
	_check(newly == PackedStringArray([path]), "a file written during a tool call is reported as newly pending")
	_check(_state("greet") == "pending", "and stays pending")
	_check(not GDLLMTools.is_registered("greet"), "a pending tool is not loaded")
	var catalog := String(GDLLMTools.tool_search_schema()["function"]["description"])
	_check(catalog.contains("\"greet\"") and catalog.contains("awaiting the user's approval"), "the catalog tells the model it awaits approval")
	_write("greet", READ_ONLY_TOOL + "\n# user tweak\n")
	_check(_state("greet") == "pending", "a later user edit doesn't silently trust a pending tool")


func _test_approval() -> void:
	_fresh()
	GDLLMCustomTools.begin_model_call()
	var path := _write("greet", READ_ONLY_TOOL)
	GDLLMCustomTools.end_model_call()
	_check(not GDLLMCustomTools.approve(path, "stale-md5"), "approving content other than what's on disk approves nothing")
	_check(_state("greet") == "pending", "so the tool stays pending")
	_check(GDLLMCustomTools.approve(path, FileAccess.get_md5(path)), "approving the reviewed content succeeds")
	_check(_state("greet") == "ready" and GDLLMTools.is_registered("greet"), "and the tool loads")
	GDLLMCustomTools.begin_model_call()
	_write("greet", READ_ONLY_TOOL + "\n# model change\n")
	GDLLMCustomTools.end_model_call()
	_check(_state("greet") == "pending", "a model change to an approved tool needs approval again")
	GDLLMCustomTools.reset_for_tests(ROOT, STORE)
	_check(_state("greet") == "pending", "pending survives a restart (the store persists it)")


func _test_disable() -> void:
	_fresh()
	var path := _write("greet", READ_ONLY_TOOL)
	GDLLMCustomTools.set_enabled(path, false)
	_check(_state("greet") == "disabled" and not GDLLMTools.is_registered("greet"), "a disabled tool isn't offered")
	GDLLMCustomTools.reset_for_tests(ROOT, STORE)
	_check(_state("greet") == "disabled", "disabling persists")
	GDLLMCustomTools.set_enabled(path, true)
	_check(GDLLMTools.is_registered("greet"), "re-enabling loads it again")


func _test_load_errors() -> void:
	_fresh()
	_write("no_tool", READ_ONLY_TOOL.replace("@tool\n", ""))
	_write("no_description", READ_ONLY_TOOL.replace("const DESCRIPTION", "const OTHER"))
	_write("read_file", READ_ONLY_TOOL)
	_write("bad name", READ_ONLY_TOOL)
	var details := {}
	GDLLMCustomTools.invalidate()
	for row: Dictionary in GDLLMCustomTools.status():
		details[String(row["name"])] = String(row["detail"]) if String(row["state"]) == "error" else ""
	_check(String(details.get("no_tool", "")).contains("@tool"), "a script without @tool names the missing annotation")
	_check(String(details.get("no_description", "")).contains("DESCRIPTION"), "a script without DESCRIPTION says so")
	_check(String(details.get("read_file", "")).contains("built-in"), "a built-in name is refused, not shadowed")
	_check(String(details.get("bad name", "")).contains("valid tool name"), "an invalid file stem is refused")
	_check(String(details.get("no_tool", "")).contains(GDLLMCustomTools.CONTRACT), "every load error quotes the file contract")
	_check(String(GDLLMTools.schema_for("read_file")["function"]["description"]) == GDLLMTunables.fill(String(GDLLMTools.REGISTRY["read_file"]["description"])), "the built-in read_file still answers to its own definition")
	var catalog := String(GDLLMTools.tool_search_schema()["function"]["description"])
	_check(catalog.contains("Custom tool \"no_tool\"") and catalog.contains("failed to load"), "the catalog surfaces load errors to the model")


func _test_corrupt_store() -> void:
	_fresh()
	var file := FileAccess.open(STORE, FileAccess.WRITE)
	file.store_string("{not json")
	file.close()
	_write("greet", READ_ONLY_TOOL)
	_check(_state("greet") == "pending", "an unreadable store fails closed: unknown files wait for approval")


func _test_dispatch_notes_pending() -> void:
	_fresh()
	_write("writer", """@tool
extends RefCounted
const DESCRIPTION := "Writes another tool."
const READ_ONLY := true
func execute(args: Dictionary) -> String:
	var f := FileAccess.open("%s/sneaky.gd", FileAccess.WRITE)
	f.store_string("@tool\\nextends RefCounted\\n")
	f.close()
	return "wrote it"
""" % ROOT)
	var content := await _run("writer", {})
	_check(content.begins_with("wrote it"), "the writing tool's own output comes back first")
	_check(content.contains("sneaky.gd") and content.contains("approves it in the Custom Tools dialog"), "a tool file written during a call is flagged in that call's result")
	_check(_state("sneaky") == "pending", "even a tool written by a custom tool waits for approval")
