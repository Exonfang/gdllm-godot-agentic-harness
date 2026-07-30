extends SceneTree
## Headless regression tests for the read-side narrow-context hardening: ranged reads, the long-file map preamble, file-not-found near-misses, editor save-temp exclusion, and the theme-item pointer.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/narrow_read_test.gd
## Exits nonzero on any failure.

const TMP_DIR := "res://__gdllm_narrow_tmp"
## A scratch directory UNDER res://addons, so the addon-scope split is exercised by a real path rather than a mocked one; it carries no plugin.cfg, so the editor never treats it as an addon.
const ADDON_TMP_DIR := "res://addons/__gdllm_search_tmp"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	_test_long_file_map_and_ranged_read()
	_test_scene_read_map()
	_test_read_function_range_hint()
	_test_not_found_near_miss()
	_test_search_context_uncapped()
	_test_search_full_waiver()
	_test_read_function_miss_suggestions()
	_test_editor_temps()
	_test_hidden_guard_and_row_cap()
	_test_bare_dir_resolution()
	_test_theme_item_pointer()
	_test_addon_search_scope()
	_cleanup()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real dispatch and return the model-facing content.
func _run(tool_name: String, args: Dictionary, allow_changes: bool) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes)).get("content", ""))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A synthetic over-threshold file shaped like a script: a 12-line header, two blank lines, then column-0 funcs — so the top-level span is 14 and a range hits known lines. The func bodies are padded so the file crosses the character threshold well under 1000 lines — the wild shape the old line gate missed.
func _make_long_file() -> String:
	var lines: Array[String] = ["extends RefCounted"]
	for i in range(2, 13):
		lines.append("var pad_%d := %d" % [i, i])
	var text := "\n".join(lines)
	while text.length() < GDLLMTools.READ_FILE_SUMMARY_THRESHOLD_CHARS + 1000:
		lines.append("")
		lines.append("")
		lines.append("func f_%d() -> void:" % lines.size())
		lines.append("\tpass  # padded so character cost outruns line count")
		text = "\n".join(lines)
	var path := TMP_DIR + "/long_sample.txt"
	_write(path, text + "\n")
	return path


func _test_long_file_map_and_ranged_read() -> void:
	var long_path := _make_long_file()
	var long_text := FileAccess.get_file_as_string(long_path)
	_check(long_text.split("\n").size() < 1000 and long_text.length() > GDLLMTools.READ_FILE_SUMMARY_THRESHOLD_CHARS, "the fixture is under the old 1000-line gate but over the character threshold")
	var mapped: Dictionary = await GDLLMTools.execute("read_file", {"path": long_path})
	_check(mapped.has("subagent"), "a file over the character threshold defers to the map subagent")
	var preamble := String(mapped.get("subagent", {}).get("result_preamble", ""))
	_check(preamble.contains(" KB of text"), "the map preamble names the size that triggered it")
	_check(preamble.contains("spans lines 1–14"), "the map preamble names the real top-level span")
	_check(preamble.contains("start_line/end_line"), "the map preamble points at ranged reads")
	_check(preamble.contains("edit_file only refuses when none of those has shown you the real text"), "the map preamble carries the non-scary read-gate wording")
	_check(not preamble.contains("will refuse this file until"), "the old scary wording is gone")
	_check(GDLLMTools._fallback_ledger.seen_files.get(long_path) == false, "the map marks the file shape-only")
	var ranged: Dictionary = await GDLLMTools.execute("read_file", {"path": long_path, "start_line": 2, "end_line": 12})
	_check(not ranged.has("subagent"), "a ranged read of a long file returns directly, not the map")
	var out := String(ranged.get("content", ""))
	_check(out.contains("(lines 2-12 of"), "the ranged read labels its span and the file's true length")
	_check(out.contains("var pad_2 := 2") and out.contains("var pad_12 := 12"), "the ranged read returns the requested region")
	_check(not out.contains("func f_"), "the ranged read stops at end_line")
	_check(GDLLMTools._fallback_ledger.seen_files.get(long_path) == true, "a ranged read marks the file seen verbatim")
	out = await _run("edit_file", {"path": long_path, "old_string": "var pad_3 := 3", "new_string": "var pad_3 := 30"}, true)
	_check(out.begins_with("Edited"), "a ranged read unlocks edit_file for the region it showed")
	out = await _run("read_file", {"path": long_path, "start_line": 1, "end_line": 99999}, false)
	_check(out.contains("extends RefCounted") and out.contains("(lines 1-"), "out-of-range bounds clamp to the file instead of erroring")
	var short_path := TMP_DIR + "/short_sample.txt"
	_write(short_path, "alpha\nbeta\ngamma\ndelta\n")
	out = await _run("read_file", {"path": short_path, "start_line": 2, "end_line": 3}, false)
	_check(out.contains("beta") and out.contains("gamma") and not out.contains("alpha"), "a ranged read works on a short file too")
	var sparse_path := TMP_DIR + "/sparse_sample.txt"
	var sparse := "x\n".repeat(1500)
	_write(sparse_path, sparse)
	_check(sparse.split("\n").size() > 1000 and sparse.length() < GDLLMTools.READ_FILE_SUMMARY_THRESHOLD_CHARS, "the sparse fixture is over the old line gate but small in characters")
	var whole: Dictionary = await GDLLMTools.execute("read_file", {"path": sparse_path})
	_check(not whole.has("subagent") and String(whole.get("content", "")).contains("x"), "a many-line but small file is returned whole — the gate is characters, not lines")


## read_file on a .tscn defaults to the saved-tree map (shape-only, so the edit gate stays unsatisfied), full/range still return the real text, and a .tscn the engine cannot load falls through to the raw read.
func _test_scene_read_map() -> void:
	var p := TMP_DIR + "/map_sample.tscn"
	_write(p, "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node2D\"]\n\n[node name=\"Hero\" type=\"Sprite2D\" parent=\".\"]\n")
	var out := await _run("read_file", {"path": p}, false)
	_check(out.contains("Saved scene tree of") and out.contains("Hero"), "a .tscn read defaults to the saved node tree")
	_check(not out.contains("[node name="), "the tree view carries no raw serialized text")
	_check(out.contains("(6 lines)") and out.contains("\"full\" set to true"), "the map names the withheld size and the full: true way back to the text")
	_check(GDLLMTools._fallback_ledger.seen_files.get(p) == false, "the scene map marks the file shape-only")
	out = await _run("edit_file", {"path": p, "old_string": "Hero", "new_string": "Hero2"}, true)
	_check(out.begins_with("Error") and out.contains("full=true"), "the scene map does not unlock edit_file, and the refusal names full=true")
	out = await _run("read_file", {"path": p, "start_line": 5, "end_line": 5}, false)
	_check(out.contains("[node name=\"Hero\""), "a ranged read of a .tscn still returns the raw lines")
	out = await _run("read_file", {"path": p, "full": true}, false)
	_check(out.contains("[node name=\"Root\"") and out.contains("[node name=\"Hero\""), "full: true returns the whole serialized text")
	_check(GDLLMTools._fallback_ledger.seen_files.get(p) == true, "a full read marks the scene seen verbatim")
	var broken := TMP_DIR + "/broken_sample.tscn"
	_write(broken, "[gd_scene format=3]\nthis line is not scene syntax\n")
	out = await _run("read_file", {"path": broken}, false)
	_check(out.contains("this line is not scene syntax"), "a .tscn that fails to load falls through to the raw text")


## read_function called like read_file — a line range, no name — names the right tool instead of only demanding a name; transcript-observed, a model was left to guess the fallback.
func _test_read_function_range_hint() -> void:
	var p := TMP_DIR + "/range_hint.gd"
	_write(p, "extends RefCounted\n\n\nfunc alpha() -> void:\n\tpass\n")
	var out := await _run("read_function", {"path": p, "start_line": "2", "end_line": "4"}, false)
	_check(out.begins_with("Error") and out.contains("read_file") and out.contains("start_line"), "a ranged no-name call cross-hints read_file, string-typed bounds included")
	out = await _run("read_function", {"path": p}, false)
	_check(out.begins_with("Error") and out.contains("_ready") and not out.contains("start_line"), "a plain no-name call keeps the simple ask")


func _test_not_found_near_miss() -> void:
	_write(TMP_DIR + "/cipc_seed_managem.tres", "placeholder\n")
	var out := await _run("read_file", {"path": "seed_managem.tres"}, false)
	_check(out.begins_with("Error") and out.contains("Did you mean") and out.contains("cipc_seed_managem.tres"), "a guessed basename contained in a real one is suggested")
	out = await _run("read_file", {"path": "extra_cipc_seed_managem.tres"}, false)
	_check(out.contains("Did you mean") and out.contains("cipc_seed_managem.tres"), "a real basename contained in the guess is suggested")
	out = await _run("read_file", {"path": "zz_no_such_file_qq.xyz"}, false)
	_check(out.begins_with("Error") and not out.contains("Did you mean"), "a total miss stays a plain not-found")


func _test_editor_temps() -> void:
	_check(GDLLMTools._is_editor_temp("res://ui/hud_cl.tscn741764901.tmp"), "a save-temp path is recognized")
	_check(GDLLMTools._is_editor_temp("custom_dual_grid.tscn8477123.tmp"), "a bare save-temp basename is recognized")
	_check(not GDLLMTools._is_editor_temp("res://plain.tmp"), "a plain .tmp without the ext+digits shape is kept")
	_check(not GDLLMTools._is_editor_temp("res://notes.txt"), "a normal file is kept")
	var sub := TMP_DIR + "/temps"
	DirAccess.make_dir_recursive_absolute(sub)
	_write(sub + "/hud_cl.tscn741764901.tmp", "gdllm_temp_needle_xyz\n")
	_write(sub + "/real.txt", "real content\n")
	var files: Array[String] = []
	GDLLMTools._collect_text_files(sub, files)
	_check(files.has(sub + "/real.txt"), "_collect_text_files keeps normal files")
	_check(not files.has(sub + "/hud_cl.tscn741764901.tmp"), "_collect_text_files skips editor save-temps")
	var out := await _run("search_files", {"query": "gdllm_temp_needle_xyz", "path": sub}, false)
	_check(not out.contains("hud_cl.tscn741764901.tmp"), "search_files never surfaces a save-temp")
	out = await _run("list_directory", {"path": sub}, false)
	_check(out.contains("real.txt") and not out.contains("hud_cl"), "list_directory omits editor save-temps")
	_check(out.contains("(1 editor save-temp file(s) omitted)"), "list_directory counts what it omitted")


## The one model-controllable size knob: an explicit oversized context ask is honored in full — a stranded model asking for more context must get it, not a silent clamp — and a larger ask also lifts the whole-function excerpt budget.
func _test_search_context_uncapped() -> void:
	var lines := PackedStringArray()
	for i in range(201):
		lines.append("cfg_line_%03d = %d" % [i, i])
	lines[100] += " ctx_cap_needle_zq"
	var path := TMP_DIR + "/ctx_cap.cfg"
	_write(path, "\n".join(lines) + "\n")
	var out := await _run("search_files", {"query": "ctx_cap_needle_zq", "path": path, "context": 400}, false)
	_check(out.contains("cfg_line_000") and out.contains("cfg_line_200"), "an oversized context ask is honored past the old 30-line cap")
	var floored := await _run("search_files", {"query": "ctx_cap_needle_zq", "path": path, "context": -5}, false)
	_check(floored.contains("cfg_line_100"), "a negative context still shows the matching line itself")
	var gd_lines := PackedStringArray(["extends RefCounted", "", "func long_fn() -> void:"])
	for i in range(40):
		gd_lines.append("\tvar fn_var_%02d := %d" % [i, i])
	gd_lines[20] += " # ctx_fn_needle_qz"
	var gd_path := TMP_DIR + "/ctx_fn.gd"
	_write(gd_path, "\n".join(gd_lines) + "\n")
	var windowed := await _run("search_files", {"query": "ctx_fn_needle_qz", "path": gd_path}, false)
	_check(windowed.contains("window shown"), "a >30-line function is still windowed at the default context")
	_check(windowed.contains("larger context_lines"), "the windowed header names the context_lines lever")
	var whole := await _run("search_files", {"query": "ctx_fn_needle_qz", "path": gd_path, "context": 50}, false)
	_check(not whole.contains("window shown") and whole.contains("fn_var_39"), "a larger context ask lifts the whole-function budget")


## The waiver over both unwaivable caps: full: true turns a would-be overview into real excerpts and uncaps the 40-block excerpt list, while each capped default names the waiver at the moment it withholds.
func _test_search_full_waiver() -> void:
	var many := TMP_DIR + "/many"
	DirAccess.make_dir_recursive_absolute(many)
	for i in range(12):
		_write("%s/f_%02d.txt" % [many, i], "alpha\nwaiver_needle_zj file %d\nomega\n" % i)
	var overview := await _run("search_files", {"query": "waiver_needle_zj", "path": many}, false)
	_check(overview.contains("per-file breakdown"), "12 matching files still fall back to the overview by default")
	_check(overview.contains("full: true"), "the overview names the full: true waiver")
	var full := await _run("search_files", {"query": "waiver_needle_zj", "path": many, "full": true}, false)
	_check(not full.contains("per-file breakdown") and full.contains("waiver_needle_zj file 11"), "full: true returns every file's excerpt instead of the overview")
	var dense := PackedStringArray()
	for i in range(500):
		dense.append("dense_line_%03d" % i)
	for m in range(0, 500, 10):
		dense[m] += " dense_needle_zj"
	var dense_path := TMP_DIR + "/dense.cfg"
	_write(dense_path, "\n".join(dense) + "\n")
	var capped := await _run("search_files", {"query": "dense_needle_zj", "path": dense_path, "context": 1}, false)
	_check(capped.contains("showing the first 40 of 50 excerpts") and capped.contains("full: true"), "the block cap names its count and the waiver")
	_check(not capped.contains("dense_line_490"), "blocks past the cap are withheld by default")
	var all_blocks := await _run("search_files", {"query": "dense_needle_zj", "path": dense_path, "context": 1, "full": true}, false)
	_check(all_blocks.contains("dense_line_490") and not all_blocks.contains("showing the first"), "full: true uncaps the excerpt blocks with no truncation note")


## The miss error's roster: near-misses first, then a capped list — never every function in a large script.
func _test_read_function_miss_suggestions() -> void:
	var body := PackedStringArray(["extends RefCounted"])
	for i in range(GDLLMTools.MAX_CLASS_SUGGESTIONS + 2):
		body.append("")
		body.append("")
		body.append("func fn_%02d() -> void:" % i)
		body.append("\tpass")
	var path := TMP_DIR + "/many_funcs.gd"
	_write(path, "\n".join(body) + "\n")
	var near := await _run("read_function", {"path": path, "name": "fn_07x"}, false)
	_check(near.contains("Closest names in this file: fn_07"), "a near-miss suggests its likely target instead of the whole roster")
	var missed := await _run("read_function", {"path": path, "name": "nosuchfn"}, false)
	_check(missed.contains("(and 2 more — read_file lists every function)"), "a plain miss caps the roster with a counted remainder naming the lever")
	_check(not missed.contains("fn_%02d" % (GDLLMTools.MAX_CLASS_SUGGESTIONS + 1)), "names past the cap are not printed")


## The wild overflow both halves guard against: a model debugging a broken import listed res://.godot/imported three times at ~64 KB of engine cache names per call, through the one context-facing tool that had no bound at all.
func _test_hidden_guard_and_row_cap() -> void:
	var engine_cache := TMP_DIR + "/.godot"
	var stash := TMP_DIR + "/.stash"
	DirAccess.make_dir_recursive_absolute(engine_cache)
	DirAccess.make_dir_recursive_absolute(stash)
	var out := await _run("list_directory", {"path": engine_cache}, false)
	_check(out.begins_with("Error:") and out.contains("engine's own cache"), "a .godot component is refused as the engine cache")
	_check(out.contains(".import"), "the refusal points at the real levers instead")
	out = await _run("list_directory", {"path": stash}, false)
	_check(out.begins_with("Error:") and out.contains("hidden directory"), "any other hidden component is refused generically")
	out = await _run("search_files", {"query": "anything", "path": engine_cache}, false)
	_check(out.begins_with("Error:") and out.contains("engine's own cache"), "a search scoped into a hidden directory meets the same refusal")
	out = await _run("list_directory", {"path": "res://."}, false)
	_check(not out.begins_with("Error:"), "the project root spelled res://. is navigation, not a hidden name")

	var crowd := TMP_DIR + "/crowd"
	DirAccess.make_dir_recursive_absolute(crowd)
	var total := GDLLMTools.MAX_LIST_ROWS + 20
	for i in range(total):
		_write("%s/entry_%03d.txt" % [crowd, i], "x")
	out = await _run("list_directory", {"path": crowd}, false)
	_check(out.contains("(…20 more of %d entries not shown" % total), "an over-cap listing truncates with a counted line")
	_check(out.contains("full: true") and out.contains("search_files"), "the truncation line names both levers")
	_check(out.contains("ending at entry_%03d.txt" % (total - 1)), "the truncation line names the final entry, bounding the hidden tail")
	_check(out.contains("CONTENTS, never names"), "the search lever states it matches contents, not file names")
	_check(not out.contains("entry_%03d.txt" % (total - 10)), "rows past the cap are not printed")
	out = await _run("list_directory", {"path": crowd, "full": true}, false)
	_check(out.contains("entry_%03d.txt" % (total - 1)) and not out.contains("not shown"), "full waives the cap and lists everything")
	# One overflow row would spend the disclosure line to hide one name, so the cap takes at least two (the fold_saves rule).
	var edge := TMP_DIR + "/edge"
	DirAccess.make_dir_recursive_absolute(edge)
	for i in range(GDLLMTools.MAX_LIST_ROWS + 1):
		_write("%s/edge_%03d.txt" % [edge, i], "x")
	out = await _run("list_directory", {"path": edge}, false)
	_check(not out.contains("not shown") and out.contains("edge_%03d.txt" % GDLLMTools.MAX_LIST_ROWS), "a single overflow row lists whole instead of truncating")
	_check(String(GDLLMTools.REGISTRY["list_directory"]["parameters"]["properties"]["full"]["description"]) != "", "the full lever is documented in the schema")


## Wild-caught in PR #23's validation round: a bare "stress_test" dead-ended in "no directory found" and the model told the user a directory that exists doesn't — file names resolved project-wide, directory names did not.
func _test_bare_dir_resolution() -> void:
	var uniq := TMP_DIR + "/uniq_dir_zq"
	DirAccess.make_dir_recursive_absolute(uniq)
	_write(uniq + "/inside.txt", "bare_dir_needle_zq\n")
	DirAccess.make_dir_recursive_absolute(TMP_DIR + "/twin_a/twin_zq")
	DirAccess.make_dir_recursive_absolute(TMP_DIR + "/twin_b/twin_zq")
	var out := await _run("list_directory", {"path": "uniq_dir_zq"}, false)
	_check(out.begins_with(uniq + ":") and out.contains("inside.txt"), "a bare name matching one directory resolves and lists it")
	out = await _run("search_files", {"query": "bare_dir_needle_zq", "path": "uniq_dir_zq"}, false)
	_check(out.contains("inside.txt"), "a search scoped by bare directory name resolves the same way")
	out = await _run("list_directory", {"path": "twin_zq"}, false)
	_check(out.begins_with("Error:") and out.contains("twin_a/twin_zq") and out.contains("twin_b/twin_zq"), "an ambiguous bare name lists every candidate")
	out = await _run("list_directory", {"path": "res://nowhere/uniq_dir_zq"}, false)
	_check(out.begins_with("Error:") and out.contains("did you mean " + uniq), "a pathed guess whose leaf exists elsewhere gets a did-you-mean")
	out = await _run("list_directory", {"path": "zzqq_nothing"}, false)
	_check(out == "Error: no directory found matching \"zzqq_nothing\" in the project.", "a name matching nothing keeps the plain not-found")


func _test_theme_item_pointer() -> void:
	var out := await _run("describe_class", {"class": "RichTextLabel", "filter": "default_color"}, false)
	_check(out.contains("THEME ITEM (color)"), "a theme-item filter miss is identified with its kind")
	_check(out.contains("theme_override_colors/default_color"), "the pointer names the exact override property")
	out = await _run("describe_member", {"class": "RichTextLabel", "member": "default_color"}, false)
	_check(out.contains("THEME ITEM (color)") and out.contains("theme_override_colors/default_color"), "describe_member gets the same theme-item answer")
	out = await _run("describe_class", {"class": "RichTextLabel", "filter": "qqqqzzz"}, false)
	_check(out.contains("theme items") and out.contains("theme_override_"), "a nonsense filter on a Control class gets the generic theme pointer")
	out = await _run("describe_class", {"class": "Resource", "filter": "qqqqzzz"}, false)
	_check(not out.contains("THEME ITEM") and not out.contains("theme items"), "a non-Control class gets no theme pointer")
	out = await _run("describe_class", {"class": "Panel", "filter": "panel"}, false)
	_check(out.contains("THEME ITEM (stylebox)") and out.contains("theme_override_styles/panel"), "a stylebox theme item reports its kind and override namespace")


## A whole-project search spends its excerpt budget on the project's OWN code. Measured on a real game, res://addons carries 1.9 MB of text against 1.7 MB of game code, so more than half of every unscoped scan was code the question was never about — wild-measured as a search for a game enum coming back quoting this addon's own test assertions.
func _test_addon_search_scope() -> void:
	DirAccess.make_dir_recursive_absolute(ADDON_TMP_DIR)
	# Assembled at runtime so the literal never appears in THIS file, which lives under res://addons and would otherwise match its own search and skew the counts.
	var term := "ZzUnique" + "SearchTerm" + "Qq"
	_write(TMP_DIR + "/game_side.gd", "extends Node\n\nvar %s := 1\n" % term)
	_write(ADDON_TMP_DIR + "/addon_side.gd", "extends Node\n\nvar %s := 2\nvar %s_two := 3\n" % [term, term])

	var both := await _run("search_files", {"query": term}, false)
	_check(both.contains("game_side.gd"), "a whole-project search shows the project's own match")
	_check(not both.contains("addon_side.gd"), "it does not excerpt a match inside an installed addon")
	_check(both.contains("(2 more match(es) in 1 file(s) under res://addons/"), "the addon matches are counted rather than dropped")
	_check(both.contains("Pass path \"res://addons/\""), "the note names the argument that reaches them")
	# The header must describe what is SHOWN; quoting the combined scan would claim files the result does not carry.
	_check(both.contains("Found 1 match(es) in 1 file(s)"), "the header counts only the shown files")

	# An explicit scope is honored exactly — a caller who asked for an addon wants that addon.
	var scoped := await _run("search_files", {"query": term, "path": ADDON_TMP_DIR}, false)
	_check(scoped.contains("addon_side.gd"), "an explicit addon scope searches there")
	_check(not scoped.contains("not shown"), "a scoped search sets nothing aside and says nothing about it")

	# When a term lives ONLY inside addons, withholding it would be a dead end — this is what keeps a session working ON an addon (this plugin's own repo included) usable.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR + "/game_side.gd"))
	var addon_only := await _run("search_files", {"query": term}, false)
	_check(addon_only.contains("addon_side.gd"), "a term found only inside addons is shown rather than withheld")
	_check(not addon_only.contains("not shown"), "and carries no set-aside note, since nothing was set aside")
	_remove_dir_recursive(ADDON_TMP_DIR)


func _cleanup() -> void:
	_remove_dir_recursive(TMP_DIR)
	_remove_dir_recursive(ADDON_TMP_DIR)


func _remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	# The hidden-guard fixtures live in leading-dot directories, which get_files/get_directories skip by default.
	dir.include_hidden = true
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_remove_dir_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)
