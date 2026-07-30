extends SceneTree
## Headless regression tests for the import-pipeline tools: the `.import` map read_file returns, the sidecar fold list_directory applies, and set_import_setting's validation and reporting.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/import_tools_test.gd
## Exits nonzero on any failure.
## One test here is NOT about imports: the shared file-tool fix that points a directory path at list_directory rode this branch, and is covered here rather than left untested (see _test_directory_to_list_directory).
## Only the pure halves are here. Everything that needs the editor's own EditorFileSystem — that reimport_files takes the SOURCE path, re-reads [params] straight from disk, runs synchronously, silently drops a setting the importer does not declare, and needs update_file first for a never-scanned file — was probe-verified against a live headless editor instead, the same standard the profiler's button path was held to.

# Preloaded rather than referenced by class_name so the test's own references survive a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMImport = preload("res://addons/gdllm-godot-agentic-harness/gdllm_import.gd")

## The project's own icon is a real imported asset with a real sidecar, so the parse is tested against engine-written text rather than text this suite invented.
const REAL_ASSET := "res://icon.svg"
const REAL_IMPORT := "res://icon.svg.import"
const SCRATCH_IMPORT := "res://addons/gdllm-godot-agentic-harness/tools/import_fixture.png.import"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_sidecar_owner()
	_test_partition_listing()
	_test_read_import()
	_test_map_report()
	_test_coerce_param()
	_test_unknown_param_refusal()
	_test_verify_params()
	_test_enum_values()
	_test_importable_refusal()
	_test_headless_refusals()
	_test_list_directory_fold()
	_test_read_file_map()
	_test_end_to_end()
	_test_directory_to_list_directory()
	_cleanup()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real execute dispatch and return its content string.
func _run(tool_name: String, args: Dictionary, allow_changes := false) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes))["content"])


## A synthetic sidecar whose params are known, so the validation paths are driven against a fixed option set.
func _write_fixture() -> void:
	var config := ConfigFile.new()
	config.set_value("remap", "importer", "texture")
	config.set_value("remap", "type", "CompressedTexture2D")
	config.set_value("remap", "uid", "uid://ctestfixture001")
	config.set_value("remap", "path", "res://.godot/imported/fixture.ctex")
	config.set_value("deps", "source_file", "res://addons/gdllm-godot-agentic-harness/tools/import_fixture.png")
	config.set_value("deps", "dest_files", ["res://.godot/imported/fixture.ctex"])
	config.set_value("params", "compress/mode", 0)
	config.set_value("params", "compress/lossy_quality", 0.7)
	config.set_value("params", "mipmaps/generate", false)
	config.save(SCRATCH_IMPORT)


func _cleanup() -> void:
	if FileAccess.file_exists(SCRATCH_IMPORT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_IMPORT))


func _test_sidecar_owner() -> void:
	_check(GDLLMImport.sidecar_owner("res://a/hero.png.import") == "res://a/hero.png", "a .import names the asset it belongs to")
	_check(GDLLMImport.sidecar_owner("res://a/player.gd.uid") == "res://a/player.gd", "a .uid names the script it belongs to")
	_check(GDLLMImport.sidecar_owner("res://a/player.gd") == "", "an ordinary file is not a sidecar")
	# "import" as a whole filename has no owner to fold into, so it must stay listed rather than vanish.
	_check(GDLLMImport.sidecar_owner("res://a/notes.import") == "", "a sidecar-extensioned name with no inner extension owns nothing")


func _test_partition_listing() -> void:
	var mixed: Array = ["hero.png", "hero.png.import", "player.gd", "player.gd.uid", "notes.md"]
	var split := GDLLMImport.partition_listing(mixed)
	_check((split["shown"] as Array).size() == 3, "sidecars beside their owners are folded away")
	_check((split["folded"] as Array).size() == 2, "both sidecar kinds are counted")
	_check(not (split["shown"] as Array).has("hero.png.import"), "the folded .import is not listed")
	_check((split["shown"] as Array).has("hero.png"), "the asset itself is still listed")
	# An orphan is real information: it is what a manual delete leaves behind, and folding it would hide the evidence.
	var orphan := GDLLMImport.partition_listing(["stray.png.import", "notes.md"] as Array)
	_check((orphan["shown"] as Array).has("stray.png.import"), "a sidecar whose owner is absent stays visible")
	_check((orphan["folded"] as Array).is_empty(), "an orphan is not counted as folded")
	# Folding everything would answer a listing with nothing at all — the dead end the addon-scoped search avoids the same way.
	var only := GDLLMImport.partition_listing(["a.png.import", "b.png.import"] as Array)
	_check((only["shown"] as Array).size() == 2, "sidecars that are all a directory holds are shown")
	_check((only["folded"] as Array).is_empty(), "nothing is reported folded when nothing was")
	_check(GDLLMImport.folded_note([]) == "", "nothing folded earns no note")
	var note := GDLLMImport.folded_note(["a.import", "b.uid"] as Array)
	_check(note.contains("2 .import/.uid sidecar"), "the note counts what it folded")
	# Wild-measured: naming the flag here got it taken in 12 of 26 listings, at 2.3x the characters. The lever belongs in the schema, which is paid for once.
	_check(not note.contains("sidecars true"), "the note does not advertise the flag it would cost context to take")
	_check(note.length() < 80, "the note stays terse enough to ride every listing")
	_check(String(GDLLMTools.REGISTRY["list_directory"]["parameters"]["properties"]["sidecars"]["description"]) != "", "the lever is documented in the schema instead")
	# Wild-measured on a real project's root: folding ONE sidecar grew the listing from 245 to 378 characters, because the note costs more than the line it removed.
	_check(not GDLLMImport.fold_saves([]), "nothing to fold never folds")
	_check(not GDLLMImport.fold_saves(["icon.svg.import"] as Array), "folding a single sidecar costs more than it saves, so it is not folded")
	var many: Array[String] = []
	for i in 20:
		many.append("sprite_%02d.png.import" % i)
	_check(GDLLMImport.fold_saves(many), "a directory full of sidecars folds")


func _test_read_import() -> void:
	var info := GDLLMImport.read_import(REAL_IMPORT)
	_check(bool(info["ok"]), "a real engine-written .import parses")
	_check(str(info["importer"]) == "texture", "the importer name is read")
	_check(str(info["uid"]).begins_with("uid://"), "the asset's uid is read")
	_check(str(info["asset"]) == REAL_ASSET, "the asset is taken from [deps] source_file")
	_check((info["params"] as Dictionary).has("compress/mode"), "the params section is read")
	_check((info["param_order"] as Array).size() == (info["params"] as Dictionary).size(), "every param keeps its engine order slot")
	# The asset path resolves the same whichever end the caller has in hand.
	_check(str(GDLLMImport.read_import(REAL_ASSET)["uid"]) == str(info["uid"]), "the asset path resolves to the same sidecar")
	var missing := GDLLMImport.read_import("res://nope/absent.png")
	_check(not bool(missing["ok"]), "an asset with no sidecar reports not-imported")
	_check(str(missing["why"]).contains("never imported"), "and says why")


func _test_map_report() -> void:
	var info := GDLLMImport.read_import(REAL_IMPORT)
	var out := GDLLMImport.map_report(REAL_IMPORT, info, "valid")
	# The uid is what 131 of 131 wild reads of one of these were for, so it leads and is named for what it is.
	_check(out.contains(str(info["uid"])), "the map carries the uid")
	_check(out.contains("preload"), "the map says what the uid is for")
	_check(out.contains("CompressedTexture2D"), "the map names the imported type")
	_check(out.contains("status: imports and loads cleanly"), "a valid import is stated rather than left silent")
	# The settings are counted, not listed: that is the whole saving, and the escape hatch has to be named or it is a dead end.
	_check(not out.contains("compress/lossy_quality=0.7"), "the map does not dump the settings")
	_check(out.contains("%d import settings" % (info["params"] as Dictionary).size()), "the map counts the settings")
	_check(out.contains("\"full\": true"), "the map names the raw-text lever")
	_check(out.contains("set_import_setting"), "the map names the tool that changes them")
	_check(out.length() < FileAccess.get_file_as_string(REAL_IMPORT).length(), "the map is smaller than the file it replaces")
	var broken := GDLLMImport.map_report(REAL_IMPORT, info, "invalid")
	_check(broken.contains("FAILED"), "a failed import is stated rather than reading as an ordinary asset")
	_check(broken.contains("read_errors"), "and points at the engine's reason")
	# Wild-measured on a real PNG: an out-of-range compress/mode leaves the editor's own import flag TRUE while the texture does not load, so the two failures are separated and worded for their different fixes.
	var unloadable := GDLLMImport.map_report(REAL_IMPORT, info, "unloadable")
	_check(unloadable.contains("BROKEN"), "an import that ran but produced nothing loadable is stated")
	_check(unloadable.contains("does NOT load"), "and says what is actually wrong")
	_check(not unloadable.contains("no imported file at all"), "it is not confused with the import having produced nothing")
	_check(unloadable.contains("set_import_setting"), "and points at the settings rather than the source file")
	_check(not out.contains("BROKEN"), "a clean asset carries neither failure wording")
	var absent := GDLLMImport.map_report("res://nope/absent.png.import", GDLLMImport.read_import("res://nope/absent.png"), "")
	_check(absent.contains("never imported"), "a missing sidecar maps to its own explanation")


func _test_coerce_param() -> void:
	# A float option handed a JSON integer must stay a float: the importer reads the variant as it finds it.
	_check(typeof(GDLLMImport.coerce_param(1, 0.7)) == TYPE_FLOAT, "an int lands in a float setting as a float")
	_check(typeof(GDLLMImport.coerce_param(2.0, 0)) == TYPE_INT, "a float lands in an int setting as an int")
	_check(GDLLMImport.coerce_param(true, false) == true, "a bool setting keeps a bool")
	_check(GDLLMImport.coerce_param("3", 1.0) == 3.0, "a numeric string parses into a float setting")
	_check(GDLLMImport.coerce_param("keep", "") == "keep", "a string setting keeps its string")
	_check(GDLLMImport.coerce_param(5, null) == 5, "an unknown current type passes the value through")


func _test_unknown_param_refusal() -> void:
	_write_fixture()
	var info := GDLLMImport.read_import(SCRATCH_IMPORT)
	_check(GDLLMImport.unknown_param_refusal({"compress/mode": 1}, info) == "", "a real setting name is accepted")
	var refusal := GDLLMImport.unknown_param_refusal({"compress/bogus": 1}, info)
	_check(refusal.begins_with("Error:"), "an undeclared setting name is refused")
	# The refusal has to say nothing was written, because the engine's own reaction is to drop the name in silence.
	_check(refusal.to_lower().contains("nothing was written"), "the refusal states that nothing was written")
	_check(refusal.contains("drops unrecognized settings"), "the refusal explains why it cannot just be tried")
	_check(refusal.contains("compress/mode"), "the refusal lists the settings that do exist")
	var near := GDLLMImport.unknown_param_refusal({"mipmaps/generat": true}, info)
	_check(near.contains("mipmaps/generat → mipmaps/generate"), "a near-miss name is matched to the real one")


func _test_verify_params() -> void:
	_write_fixture()
	var before := GDLLMImport.read_import(SCRATCH_IMPORT)
	var after := GDLLMImport.read_import(SCRATCH_IMPORT)
	# Wild-measured: 12 of 30 writes in one round set a value the file already held, and every one was reported as a change.
	var noop := GDLLMImport.verify_params(after, {"compress/mode": 0}, before["params"], "texture")
	_check((noop["took"] as Array).is_empty(), "a value that was already set is not counted as a change")
	_check((noop["unchanged"] as Array).size() == 1, "it is reported as unchanged instead")
	_check(String((noop["unchanged"] as Array)[0]).contains("Lossless"), "and carries the value's meaning")
	var same := GDLLMImport.verify_params(after, {"compress/mode": 0}, {}, "texture")
	_check((same["took"] as Array).size() == 1, "a setting with no previous value reads as taken")
	_check(String((same["took"] as Array)[0]).contains("was"), "and reports what it was before")
	# The second witness on the silent drop: only the engine decides what survives an import.
	var dropped := GDLLMImport.verify_params(after, {"compress/mode": 9}, before["params"], "texture")
	_check((dropped["dropped"] as Array).size() == 1, "a value the file does not hold reads as declined")
	_check(String((dropped["dropped"] as Array)[0]).contains("it holds"), "and reports what it holds instead")
	var vanished := GDLLMImport.verify_params(after, {"gone/entirely": 1}, before["params"], "texture")
	_check((vanished["dropped"] as Array).has("gone/entirely"), "a setting the engine removed reads as declined")


## The wild failure this table exists for: three runs out of three set compress/mode to 3 and reported "Lossless" — 3 is VRAM Uncompressed, and nothing named it.
func _test_enum_values() -> void:
	_check(GDLLMImport.value_names("texture", "compress/mode").size() == 5, "the texture compress modes are known")
	_check(GDLLMImport.value_names("texture", "mipmaps/generate").is_empty(), "a non-enum option has no value names")
	# The same option name means different things per importer, so the table must be keyed by both.
	_check(str(GDLLMImport.value_names("wav", "compress/mode")[0]) == "PCM (Uncompressed)", "a WAV's compress/mode is its own list")
	_check(GDLLMImport.label_value("texture", "compress/mode", 3) == "3 (VRAM Uncompressed)", "a value is reported with its meaning")
	_check(GDLLMImport.label_value("texture", "compress/mode", 0) == "0 (Lossless)", "lossless is 0, not 3")
	_check(GDLLMImport.label_value("texture", "mipmaps/generate", true) == "true", "an unknown option's value is passed through plainly")
	_check(GDLLMImport.label_value("texture", "compress/mode", 99) == "99", "a value with no name is not invented")
	# A name is accepted in place of the index, which is what makes the safe spelling available at all.
	var by_name := GDLLMImport.resolve_value("texture", "compress/mode", "Lossless")
	_check(bool(by_name["ok"]) and int(by_name["value"]) == 0, "an enum value resolves from its name")
	var ci := GDLLMImport.resolve_value("texture", "compress/mode", "vram uncompressed")
	_check(bool(ci["ok"]) and int(ci["value"]) == 3, "the name match is case-insensitive")
	var idx := GDLLMImport.resolve_value("texture", "compress/mode", 2)
	_check(bool(idx["ok"]) and int(idx["value"]) == 2, "a legal index still passes")
	var over := GDLLMImport.resolve_value("texture", "compress/mode", 99)
	_check(not bool(over["ok"]), "an out-of-range index is refused")
	_check(str(over["why"]).contains("3 = VRAM Uncompressed"), "the refusal names every legal value with its number")
	# The value refusal states the legal values; the "nothing written" half is the shared batch note the tool appends to it, checked below.
	_check(not str(over["why"]).contains("Pass the number, or the name itself (\"\")"), "the refusal names a real example value")
	var bad_name := GDLLMImport.resolve_value("texture", "compress/mode", "Superb Quality")
	_check(not bool(bad_name["ok"]), "an invented value name is refused")
	var free := GDLLMImport.resolve_value("texture", "mipmaps/generate", true)
	_check(bool(free["ok"]) and bool(free["value"]), "an option with no known list passes its value through untouched")
	# Wild-measured: a run that set one value correctly then recited the whole enum to the user from memory, getting three of four wrong, because no refusal had fired that session.
	var legend := GDLLMImport.value_legend("texture", "compress/mode")
	_check(legend.contains("0 = Lossless") and legend.contains("2 = VRAM Compressed") and legend.contains("4 = Basis Universal"), "the legend spells out every value with its number")
	_check(GDLLMImport.value_legend("texture", "mipmaps/generate") == "", "an option with no fixed list has no legend")
	_check(str(over["why"]).contains("0 = Lossless"), "the refusal uses the same legend")
	# The batch is atomic, and a caller not told so resent an unchanged six-call batch twice.
	var note := GDLLMImport.batch_withheld_note({"compress/mode": 9, "mipmaps/generate": true}, ["compress/mode"])
	_check(note.contains("mipmaps/generate"), "the batch note names the setting that was withheld with it")
	_check(note.contains("NOT changed"), "and says it was not changed")
	_check(GDLLMImport.batch_withheld_note({"compress/mode": 9}, ["compress/mode"]).contains("Nothing was written"), "a single-setting call still states nothing was written")
	_check(not GDLLMImport.batch_withheld_note({"compress/mode": 9}, ["compress/mode"]).contains("send them all again"), "and is not told to resend a batch it never sent")


func _test_importable_refusal() -> void:
	_check(GDLLMImport.importable_refusal(REAL_ASSET) == "", "a real imported asset is accepted")
	var script_refusal := GDLLMImport.importable_refusal("res://addons/gdllm-godot-agentic-harness/gdllm_import.gd")
	_check(script_refusal.begins_with("Error:"), "a directly-loaded file is refused")
	_check(script_refusal.contains("no .import sidecar"), "the refusal names the actual reason")
	_check(script_refusal.contains("edit_resource"), "the refusal names where a .tres change goes instead")
	var missing := GDLLMImport.importable_refusal("res://nope/absent.png")
	_check(missing.contains("does not exist"), "a missing asset is refused by name")
	_check(missing.contains("not its .import sidecar"), "and steers the caller to the asset path")


func _test_headless_refusals() -> void:
	# Headless there is no EditorFileSystem, and a claim that an asset was rebuilt would be the one lie this whole change exists to remove.
	var out := await _run("set_import_setting", {"path": REAL_ASSET}, true)
	_check(out.begins_with("Error:"), "set_import_setting refuses headless")
	_check(out.contains("headless"), "the refusal names headless as the reason")
	var direct := GDLLMImport.reimport(REAL_ASSET)
	_check(not bool(direct["ok"]), "the reimport itself refuses headless")
	_check(GDLLMImport.valid_state(REAL_ASSET) == "", "no import verdict is invented outside the editor")


func _test_list_directory_fold() -> void:
	# A directory with many sidecars, where the fold is worth its disclosure line; a root with one or two is deliberately left alone (see fold_saves).
	const DENSE := "res://addons/gdllm-godot-agentic-harness/tools"
	var out := await _run("list_directory", {"path": DENSE})
	_check(out.contains("import_tools_test.gd"), "the real files are listed")
	_check(not out.contains("import_tools_test.gd.uid"), "their sidecars are folded away")
	_check(out.contains("sidecar file(s)") and out.contains("not listed"), "the fold is disclosed with a count")
	var shown := await _run("list_directory", {"path": DENSE, "sidecars": true})
	_check(shown.contains("import_tools_test.gd.uid"), "the sidecars lever lists them")
	_check(not shown.contains("not listed"), "and drops the fold note")
	_check(shown.length() > out.length(), "the fold really is the smaller listing")
	# The saving has to be real: a fold that grew the output would be a context regression dressed as a saving.
	var root := await _run("list_directory", {"path": "res://"})
	var root_raw := await _run("list_directory", {"path": "res://", "sidecars": true})
	_check(root.length() <= root_raw.length(), "a listing is never made BIGGER by folding")


func _test_read_file_map() -> void:
	var mapped := await _run("read_file", {"path": REAL_IMPORT})
	var raw := FileAccess.get_file_as_string(REAL_IMPORT)
	_check(mapped.contains("uid://"), "read_file on a .import carries the uid")
	_check(not mapped.contains("compress/lossy_quality=0.7"), "read_file on a .import does not dump the settings")
	_check(mapped.length() < raw.length(), "the map costs less than the file")
	var full := await _run("read_file", {"path": REAL_IMPORT, "full": true})
	_check(full.contains("compress/lossy_quality=0.7"), "full true still returns the raw text")
	# The numbers are on screen here with nothing to say what they mean: one wild run recited them from memory and another sent a junk value to make the refusal reveal them.
	_check(full.contains("compress/mode takes: 0 = Lossless"), "a full read explains its numeric choices")
	_check(full.contains("detect_3d/compress_to takes:"), "every choice option the file declares is explained")
	_check(full.contains("NOT part of the file"), "and the addition is marked so an edit never copies it back")
	_check(not full.contains("mipmaps/generate takes:"), "an option with no fixed list earns no legend")
	# The map deliberately does NOT carry it: it omits the values, so a legend there would explain numbers the reader cannot see.
	_check(not mapped.contains("takes: 0 = Lossless"), "the map stays lean")
	# The block is identical per importer, and a session reading six textures paid for it six times — 71% of all legend characters were duplicates.
	var again := await _run("read_file", {"path": REAL_IMPORT, "full": true})
	_check(not again.contains("compress/mode takes: 0 = Lossless"), "a second read of the same importer does not repeat the whole legend")
	_check(again.length() < full.length(), "the repeat costs less than the first")
	# The repeat must not be a back-reference to prunable history: it names what cannot be inferred from the file, and a move that needs no numbers at all.
	_check(again.contains("compress/mode") and again.contains("detect_3d/compress_to"), "the repeat still names which options are choices")
	_check(again.contains("by NAME"), "and names the spelling that never needs the numbers")
	var info2 := GDLLMImport.read_import(REAL_IMPORT)
	_check(GDLLMImport.legend_block(info2, false).length() > GDLLMImport.legend_block(info2, true).length(), "the repeat block is the smaller of the two")
	# A line range is an explicit request for exact text and must not be answered with a map.
	var ranged := await _run("read_file", {"path": REAL_IMPORT, "start_line": 1, "end_line": 4})
	_check(ranged.contains("   1: "), "a line range still returns numbered text")


func _test_end_to_end() -> void:
	_check(GDLLMTools.is_registered("set_import_setting"), "set_import_setting is registered")
	_check(GDLLMTools.is_mutating("set_import_setting"), "set_import_setting rides the Make-changes gate")
	var gated := await _run("set_import_setting", {"path": REAL_ASSET}, false)
	_check(gated.contains("Make changes"), "it is refused while Make changes is off")
	# Reaching the capability is half of it: the catalog summary is what gets a tool chosen.
	var summary := String(GDLLMTools.REGISTRY["set_import_setting"]["summary"])
	_check(summary.contains("import"), "the summary says what it is for")
	_check(summary.to_lower().contains("re-import") or summary.to_lower().contains("reimport"), "the summary advertises the plain re-import")
	for phrase in ["import settings", "reimport texture", "compression mipmaps"]:
		var found := false
		for entry in GDLLMTools.search(phrase, true):
			if String(entry["name"]) == "set_import_setting":
				found = true
		_check(found, "tool_search finds set_import_setting from \"%s\"" % phrase)


## Not an import-pipeline behavior — a shared file-tool fix that rode this branch, kept here so it is covered rather than untested.
## Wild-observed in a boon session: read_file on res://resources/augments answered "no file found matching" with nothing to try next, when the directory was right there to list.
func _test_directory_to_list_directory() -> void:
	const DIR := "res://addons/gdllm-godot-agentic-harness/tools"
	var read := await _run("read_file", {"path": DIR})
	_check(read.contains("is a DIRECTORY"), "read_file on a directory says it is one")
	_check(read.contains("list_directory"), "and names the tool that answers it")
	_check(read.contains("\"path\": \"%s\"" % DIR), "with the call spelled out")
	# The fix is in the shared composer, so every file tool inherits it.
	_check((await _run("read_function", {"path": DIR, "name": "x"})).contains("list_directory"), "read_function inherits it")
	_check((await _run("check_script", {"path": DIR})).contains("list_directory"), "check_script inherits it")
	# A genuinely missing path must not be described as a directory.
	var missing := await _run("read_file", {"path": "res://nope/absent_thing.gd"})
	_check(not missing.contains("is a DIRECTORY"), "a missing file is not called a directory")
	# search_files resolves a directory scope itself, so its own behavior is unchanged.
	_check(not (await _run("search_files", {"query": "extends", "path": DIR})).contains("is a DIRECTORY"), "a directory scope still searches normally")
