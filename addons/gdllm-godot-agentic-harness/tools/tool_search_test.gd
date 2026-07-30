extends SceneTree
## Headless regression tests for tool_search's matching (GDLLMTools.search): exact-name pickout, every-word matching over name+summary, the result cap, and the mutating filter — plus the already-attached short-circuit, the catalog's attached markers, and the history walk that restores activations on reload.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/tool_search_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_exact_name()
	_test_name_among_filler()
	_test_every_word_must_match()
	_test_cap()
	_test_mutating_filter()
	_test_empty_query()
	_test_fresh_search_activates()
	_test_already_attached_short_circuit()
	_test_mixed_attached_and_new()
	_test_no_match_message()
	_test_gated_no_match_names_the_toggle()
	_test_catalog_markers()
	_test_history_reactivation()
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


func _test_exact_name() -> void:
	_check(_names(GDLLMTools.search("read_file", false)) == ["read_file"], "exact name returns only that tool")
	_check(_names(GDLLMTools.search("describe_class", false)) == ["describe_class"], "tools whose descriptions cross-reference a name don't ride along on its exact-name query")


func _test_name_among_filler() -> void:
	var results: Array = GDLLMTools.search("read_file with path foo.gd, full=true", false)
	_check(_names(results) == ["read_file"], "a name query with filler words still returns only the named tool")


func _test_every_word_must_match() -> void:
	_check(GDLLMTools.search("find start_screen scene file", false).is_empty(), "a project-content query matches nothing instead of most of the registry")
	var results: Array = GDLLMTools.search("edit file", true)
	_check(not results.is_empty() and String(results[0]["name"]) == "edit_file", "capability words rank the tool they name in full first")


func _test_cap() -> void:
	for query in ["scene", "file", "node", "read"]:
		var matched := GDLLMTools.search(query, true).size()
		var parsed: Variant = JSON.parse_string(String((await _search_with(query, {}, true))["content"]))
		var entries: Array = (parsed as Dictionary).get("tools", [])
		_check(entries.size() <= GDLLMTools.MAX_SEARCH_RESULTS, "single generic word \"%s\" attaches at most the cap" % query)
		if matched > GDLLMTools.MAX_SEARCH_RESULTS:
			_check(String((parsed as Dictionary).get("note", "")).contains("top %d of %d" % [GDLLMTools.MAX_SEARCH_RESULTS, matched]), "\"%s\"'s cut is disclosed with the real total" % query)
		else:
			_check(not (parsed as Dictionary).has("note"), "\"%s\" under the cap carries no cut note" % query)


func _test_mutating_filter() -> void:
	_check(GDLLMTools.search("edit_file", false).is_empty(), "a mutating tool stays hidden by exact name while changes are off")


func _test_empty_query() -> void:
	_check(GDLLMTools.search("", false).is_empty(), "an empty query returns nothing rather than the registry")


## Run tool_search through the real dispatch with an activated set and return the full {content, activate} result.
func _search_with(query: String, active: Dictionary, allow_changes: bool = false, allow_delete: bool = false) -> Dictionary:
	return await GDLLMTools.execute("tool_search", {"query": query}, allow_changes, allow_delete, active)


func _test_fresh_search_activates() -> void:
	var result := await _search_with("read_file", {})
	var content := String(result["content"])
	_check(Array(result["activate"]).has("read_file"), "a fresh search activates the tool")
	_check(not content.contains("\"parameters\""), "a fresh search emits no schema — activation attaches it to the next request instead")
	_check(content.contains("\"summary\""), "a fresh search carries the catalog summary for picking among matches")
	_check(content.contains("call it as read_file("), "a fresh search names the call shape")
	_check(not content.contains("already attached"), "a fresh search carries no attached note")


func _test_already_attached_short_circuit() -> void:
	var result := await _search_with("read_file", {"read_file": true})
	var content := String(result["content"])
	_check(content.begins_with("Already attached: read_file"), "an attached-only search answers with the short reminder")
	_check(not content.contains("\"parameters\""), "an attached-only search re-emits no schema")
	_check(Array(result["activate"]).has("read_file"), "an attached-only search still names the tool in activate")


func _test_mixed_attached_and_new() -> void:
	# A capability query that matches several describe_* tools; the first is treated as already attached.
	var matched := _names(GDLLMTools.search("describe", false))
	_check(matched.size() >= 2, "the mixed-case query matches several tools")
	var held := String(matched[0])
	var parsed: Variant = JSON.parse_string(String((await _search_with("describe", {held: true}))["content"]))
	_check(parsed is Dictionary, "a mixed search still returns a JSON block")
	var held_entry: Dictionary = {}
	var fresh_count := 0
	var schema_leaked := false
	for entry in parsed.get("tools", []):
		schema_leaked = schema_leaked or entry.has("parameters")
		if String(entry.get("name", "")) == held:
			held_entry = entry
		elif entry.has("summary"):
			fresh_count += 1
	_check(held_entry.has("note") and not held_entry.has("summary"), "the attached match is trimmed to a note")
	_check(fresh_count == mini(matched.size(), GDLLMTools.MAX_SEARCH_RESULTS) - 1, "the unattached matches carry their summaries")
	_check(not schema_leaked, "no match re-emits a schema — activation attaches those")


func _test_no_match_message() -> void:
	var result := await _search_with("zzzz qqqq", {})
	_check(String(result["content"]).begins_with("No matching tools found"), "an unmatched query reports no tools")
	_check(Array(result["activate"]).is_empty(), "an unmatched query activates nothing")


func _test_gated_no_match_names_the_toggle() -> void:
	var mutating := String((await _search_with("edit_file", {}))["content"])
	_check(not mutating.begins_with("No matching tools found"), "a gate-hidden tool doesn't answer with the generic no-match text")
	_check(mutating.contains("edit_file") and mutating.contains("\"Make changes\""), "a mutating tool's search names the tool and the Make changes toggle")
	_check(Array((await _search_with("edit_file", {}))["activate"]).is_empty(), "a gate-hidden match activates nothing")
	var both_off := String((await _search_with("delete_file", {}))["content"])
	_check(both_off.contains("\"Make changes\" and \"Delete files\""), "a destructive tool with both gates off names both toggles")
	var delete_only := String((await _search_with("delete_file", {}, true))["content"])
	_check(delete_only.contains("\"Delete files\"") and not delete_only.contains("\"Make changes\" and"), "a destructive tool with changes already on names only Delete files")
	var ungated := String((await _search_with("zzzz qqqq", {}, true, true))["content"])
	_check(ungated.begins_with("No matching tools found"), "with both gates open a genuine miss still reports no tools")


func _test_catalog_markers() -> void:
	var plain := String(GDLLMTools.tool_search_schema(false)["function"]["description"])
	_check(not plain.contains("(attached — call directly)"), "an empty active set marks nothing")
	var marked := String(GDLLMTools.tool_search_schema(false, false, {"read_file": true})["function"]["description"])
	var read_file_line := ""
	for line in marked.split("\n"):
		if line.begins_with("- read_file"):
			read_file_line = line
	_check(read_file_line.contains("(attached — call directly)"), "an attached tool's catalog line is marked")
	_check(marked.count("(attached — call directly)") == 1, "only the attached tool is marked")


func _test_history_reactivation() -> void:
	var searched_result := String((await _search_with("search_files", {}))["content"])
	var history := [
		{"role": "user", "content": "hi"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "tool_search", "arguments": {"query": "search_files"}}}]},
		{"role": "tool", "tool_name": "tool_search", "content": searched_result},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "read_file", "arguments": {"path": "x.gd"}}}]},
		{"role": "tool", "tool_name": "read_file", "content": "..."},
		{"role": "tool", "tool_name": "tool_search", "content": "Already attached: read_file. The full definition is in your tools — call it directly; do not search for it again."},
	]
	var active := GDLLMTools.active_tools_from_history(history)
	_check(active.has("read_file"), "a called tool reactivates")
	_check(active.has("search_files"), "a searched-but-never-called tool reactivates")
	_check(not active.has("tool_search"), "tool_search itself never lands in the set")
	_check(active.size() == 2, "nothing else reactivates")
	var partial := GDLLMTools.active_tools_from_history(history, 3)
	_check(partial.has("search_files") and not partial.has("read_file"), "the count cut-off sees only earlier activations")
	_check(GDLLMTools.active_tools_from_history([], -1).is_empty(), "an empty history activates nothing")
