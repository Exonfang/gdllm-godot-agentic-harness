extends SceneTree
## Headless regression tests for file-path resolution (GDLLMTools._resolve_file_path and _file_not_found): a unique bare file name resolves, a wrongly guessed res:// directory falls back to the name search, a name shared by several files refuses with the full list, and a case/underscore near-miss is suggested — the failure modes seen when a user names a script without its path.
## Also covers the cause-naming refusals a resolved path can still earn (_file_open_error, _resource_load_cause, _write_failure_cause, _file_write_error, _resource_save_cause), including the guard that probing a failed write never truncates the file it is diagnosing.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/file_resolution_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

const FIXTURE_DIR := "res://resolve_test_fixture"
const UNIQUE := "gdllm_resolve_probe_unique.txt"
const DUP := "gdllm_resolve_probe_dup.txt"
const BROKEN_SCENE := "gdllm_resolve_probe_broken.tscn"
const SCRIPTED_SCENE := "gdllm_resolve_probe_scripted.tscn"
const HOLLOW_SCENE := "gdllm_resolve_probe_hollow.tscn"
const CORRUPT_SCENE := "gdllm_resolve_probe_corrupt.tscn"
const HOLLOW_RES := "gdllm_resolve_probe_hollow.tres"
const BINARY_RES := "gdllm_resolve_probe_hollow.res"
const BLOBBED_RES := "gdllm_resolve_probe_blobbed.tres"
const BLOBBED_TEXT := "gdllm_resolve_probe_blobbed.txt"
const ABSENT_DEP := "res://gdllm_resolve_probe_absent.gd"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_build_fixture()
	_test_unique_bare_name()
	_test_wrong_directory_guess()
	_test_ambiguous_name_refused()
	_test_ambiguous_message_lists_matches()
	_test_full_path_beats_ambiguity()
	_test_near_miss_suggested()
	_test_plain_not_found()
	_test_user_path_untouched()
	_test_read_file_end_to_end()
	_test_resolution_note()
	_test_write_guards()
	_test_search_elision()
	_test_open_failure_cause()
	_test_resource_load_cause()
	_test_write_failure_cause()
	_test_write_probe_never_truncates()
	_test_resource_save_cause()
	_test_scene_detail_filter()
	_remove_fixture()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _build_fixture() -> void:
	for sub in ["a", "b"]:
		DirAccess.make_dir_recursive_absolute(FIXTURE_DIR.path_join(sub))
	_write(FIXTURE_DIR.path_join("a").path_join(UNIQUE), "unique probe")
	_write(FIXTURE_DIR.path_join("a").path_join(DUP), "dup probe a")
	_write(FIXTURE_DIR.path_join("b").path_join(DUP), "dup probe b")
	# The cause walks read dependencies out of the file headers, so the fixtures only need to be well-formed text, never loadable.
	_write(_fixture(BROKEN_SCENE), "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"%s\" id=\"1_a\"]\n\n[node name=\"Root\" type=\"Node\"]\nscript = ExtResource(\"1_a\")\n" % ABSENT_DEP)
	_write(_fixture(SCRIPTED_SCENE), "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd\" id=\"1_a\"]\n\n[node name=\"Root\" type=\"Node\"]\nscript = ExtResource(\"1_a\")\n")
	_write(_fixture(HOLLOW_SCENE), "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n")
	_write(_fixture(CORRUPT_SCENE), "[gd_scene format=3]\n\nthis is not a scene at all\n")
	_write(_fixture(HOLLOW_RES), "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n")
	ResourceSaver.save(Resource.new(), _fixture(BINARY_RES))
	# A payload past PACKED_ARRAY_ELIDE_CHARS, so read_file's elision fires on these two — a .tres because a loadable .tscn now maps to its node tree on a plain read (seen=false covers that path); the .txt keeps the write-clears-flag check free of a validation subprocess.
	var blob := "PackedByteArray(\"%s\")" % "QUJDREVG".repeat(30)
	_write(_fixture(BLOBBED_RES), "[gd_resource type=\"Resource\" format=3]\n\n[resource]\nmetadata/blob = %s\n" % blob)
	_write(_fixture(BLOBBED_TEXT), "first line without any blob\ndata = %s\n" % blob)


func _fixture(name: String) -> String:
	return FIXTURE_DIR.path_join("a").path_join(name)


## The node-detail caps' levers: past the property cap the note names filter and the saved route's read_file waiver, a filter shows every match with its value whole, a clipped value names the filter lever, and filter without node_path is refused with the shape.
func _test_scene_detail_filter() -> void:
	var lines := ["[gd_scene format=3]", "", "[node name=\"Root\" type=\"Node\"]"]
	lines.append("metadata/long_text = \"%s\"" % "y".repeat(200))
	for i in range(45):
		lines.append("metadata/prop_%02d = %d" % [i, i])
	var path := _fixture("gdllm_resolve_probe_caps.tscn")
	_write(path, "\n".join(lines) + "\n")
	var capped := String((await GDLLMTools.execute("describe_scene_file", {"path": path, "node_path": "."}))["content"])
	_check(capped.contains("(40 of 46 shown — pass \"filter\" with part of a name for the rest, or read_file this scene file with full: true)"), "the property cap names filter and the saved-route waiver")
	_check(capped.contains("chars total)") and capped.contains("(a clipped value prints whole when \"filter\" names its property.)"), "a clipped value names the filter lever")
	_check(not capped.contains("prop_44"), "entries past the cap are withheld by default")
	var filtered := String((await GDLLMTools.execute("describe_scene_file", {"path": path, "node_path": ".", "filter": "prop_44"}))["content"])
	_check(filtered.contains("Stored properties matching \"prop_44\" (1 of 46):") and filtered.contains("prop_44 = 44"), "a filter reaches an entry past the cap")
	var whole := String((await GDLLMTools.execute("describe_scene_file", {"path": path, "node_path": ".", "filter": "long_text"}))["content"])
	_check(whole.contains("y".repeat(200)), "a filtered value prints whole, never clipped")
	var miss := String((await GDLLMTools.execute("describe_scene_file", {"path": path, "node_path": ".", "filter": "zzz"}))["content"])
	_check(miss.contains("none of 46 match \"zzz\""), "a filter matching nothing says so")
	var treeless := String((await GDLLMTools.execute("describe_scene_file", {"path": path, "filter": "prop"}))["content"])
	_check(treeless.begins_with("Error") and treeless.contains("node_path"), "filter without node_path is refused with the shape")


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _remove_fixture() -> void:
	for sub in ["a", "b"]:
		var dir_path := FIXTURE_DIR.path_join(sub)
		for entry in DirAccess.get_files_at(dir_path):
			DirAccess.remove_absolute(dir_path.path_join(entry))
		DirAccess.remove_absolute(dir_path)
	DirAccess.remove_absolute(FIXTURE_DIR)


func _test_unique_bare_name() -> void:
	var want := FIXTURE_DIR.path_join("a").path_join(UNIQUE)
	_check(GDLLMTools._resolve_file_path(UNIQUE) == want, "a bare file name unique in the project resolves to its full path")


func _test_wrong_directory_guess() -> void:
	var want := FIXTURE_DIR.path_join("a").path_join(UNIQUE)
	_check(GDLLMTools._resolve_file_path("res://totally/wrong/" + UNIQUE) == want, "a res:// path with wrong directories falls back to the unique name match")
	_check(GDLLMTools._resolve_file_path("wrong/" + UNIQUE) == want, "a relative path with wrong directories falls back to the unique name match")


func _test_ambiguous_name_refused() -> void:
	_check(GDLLMTools._resolve_file_path(DUP) == "", "a name shared by several files refuses to resolve rather than guessing one")
	_check(GDLLMTools._resolve_file_path("res://elsewhere/" + DUP) == "", "a wrong path onto a shared name refuses too")


func _test_ambiguous_message_lists_matches() -> void:
	var msg: String = GDLLMTools._file_not_found(DUP)
	var both := msg.contains(FIXTURE_DIR.path_join("a").path_join(DUP)) and msg.contains(FIXTURE_DIR.path_join("b").path_join(DUP))
	_check(both and msg.contains("full res:// path"), "the ambiguity error lists every match and asks for the full path")


func _test_full_path_beats_ambiguity() -> void:
	var full := FIXTURE_DIR.path_join("b").path_join(DUP)
	_check(GDLLMTools._resolve_file_path(full) == full, "an explicit full path to one of the shared names still resolves")


func _test_near_miss_suggested() -> void:
	var msg: String = GDLLMTools._file_not_found("GdllmResolveProbeUnique.txt")
	_check(msg.contains("Similarly named") and msg.contains(FIXTURE_DIR.path_join("a").path_join(UNIQUE)), "a PascalCase request suggests the snake_case file")
	_check(GDLLMTools._resolve_file_path("GdllmResolveProbeUnique.txt") == "", "the near-miss is only suggested, never silently resolved")


func _test_plain_not_found() -> void:
	var msg: String = GDLLMTools._file_not_found("gdllm_resolve_probe_absent.txt")
	_check(msg == "Error: no file found matching \"gdllm_resolve_probe_absent.txt\" in the project.", "a name matching nothing gets the plain not-found message")


func _test_user_path_untouched() -> void:
	_check(GDLLMTools._resolve_file_path("user://" + UNIQUE) == "", "a missing user:// path never falls back to the project search")


func _test_read_file_end_to_end() -> void:
	var ok: Dictionary = await GDLLMTools.execute("read_file", {"path": UNIQUE})
	_check(String(ok["content"]).contains("unique probe"), "read_file with a unique bare name returns the file")
	var ambiguous: Dictionary = await GDLLMTools.execute("read_file", {"path": DUP})
	_check(String(ambiguous["content"]).begins_with("Error: 2 files in the project are named"), "read_file with a shared name errors with the match list")


## The loud requested-vs-resolved disclosure (_resolution_note): silent by-name resolution taught models phantom paths they later write_file'd as duplicates, so a pathed guess is announced up front while an exact path stays clean.
func _test_resolution_note() -> void:
	var full := FIXTURE_DIR.path_join("a").path_join(UNIQUE)
	var exact := String((await GDLLMTools.execute("read_file", {"path": full}))["content"])
	_check(not exact.contains("resolved"), "an exact path gets no resolution note")
	var bare := String((await GDLLMTools.execute("read_file", {"path": UNIQUE}))["content"])
	_check(bare.contains("resolved by file name to %s" % full), "a bare name discloses the resolved full path")
	_check(not bare.contains("IMPORTANT"), "a bare name gets the calm note, not the phantom-path warning")
	var guessed := String((await GDLLMTools.execute("read_file", {"path": "res://totally/wrong/" + UNIQUE}))["content"])
	_check(guessed.begins_with("IMPORTANT: no file exists at the path you requested"), "a wrong directory guess is announced loudly up front")
	_check(guessed.contains(full) and guessed.contains("CREATE A SECOND FILE"), "the loud note names the real path and the write trap")
	var fn := String((await GDLLMTools.execute("read_function", {"path": "res://also/wrong/tool_search_test.gd", "name": "_init"}))["content"])
	_check(fn.begins_with("IMPORTANT: no file exists at the path you requested"), "read_function announces a wrong directory guess the same way")


## write_file's pre-write safety refusals: a blind overwrite of an unread existing file (_write_overwrite_seen_guard) — including one read with packed-array payloads elided, where "seen" is not the whole file — and a new file whose name collides with an existing one (_write_phantom_collision_guard), all waived by force.
func _test_write_guards() -> void:
	var ledger := GDLLMTools.SessionLedger.new()
	var live := _fixture(UNIQUE)
	# Overwrite gate: an existing file never read is refused, a shape-only view still refused, a verbatim read passes, force overrides.
	_check(GDLLMTools._write_overwrite_seen_guard(live, ledger, false).begins_with("Error:"), "overwriting an unread existing file is refused")
	_check(GDLLMTools._write_overwrite_seen_guard(live, ledger, false).contains("not read it"), "the unread refusal says the file was never read")
	_check(GDLLMTools._write_overwrite_seen_guard(live, ledger, true) == "", "force waives the overwrite gate")
	ledger.seen_files[live] = false
	_check(GDLLMTools._write_overwrite_seen_guard(live, ledger, false).contains("map/overview"), "a shape-only view is still refused, named as such")
	ledger.seen_files[live] = true
	_check(GDLLMTools._write_overwrite_seen_guard(live, ledger, false) == "", "a file seen verbatim may be overwritten")
	# Phantom-collision gate: a new file whose basename matches one existing file names it, two matches list both, force overrides, a unique name passes.
	var one := GDLLMTools._write_phantom_collision_guard("res://brand/new/" + UNIQUE, false)
	_check(one.begins_with("Error:") and one.contains(_fixture(UNIQUE)), "a new file colliding with one existing file is refused and names it")
	_check(GDLLMTools._write_phantom_collision_guard("res://brand/new/" + UNIQUE, true) == "", "force waives the collision refusal")
	var many := GDLLMTools._write_phantom_collision_guard("res://brand/new/" + DUP, false)
	_check(many.contains("2 files named") and many.contains(FIXTURE_DIR.path_join("a").path_join(DUP)), "a collision with several existing files lists them all")
	_check(GDLLMTools._write_phantom_collision_guard("res://brand/new/gdllm_no_such_probe.txt", false) == "", "a genuinely unique new basename passes the collision guard")
	# The .gd class_name warning: a script twin declaring a global class earns the duplicate-class collision note.
	var cls_twin := _fixture("gdllm_probe_class.gd")
	_write(cls_twin, "@tool\nextends Node\nclass_name GdllmProbeClass\n")
	var cls := GDLLMTools._write_phantom_collision_guard("res://elsewhere/gdllm_probe_class.gd", false)
	_check(cls.contains("global class `GdllmProbeClass`"), "a colliding .gd twin's global class_name is named in the refusal")
	DirAccess.remove_absolute(cls_twin)
	# "overwrite" must never join the force synonyms: a model passes it spontaneously on any intentional replacement, which would waive the read gate on exactly the hallucinated-content overwrites it exists to catch.
	_check(not GDLLMTools.WRITE_FORCE_KEYS.has("overwrite"), "the force synonyms exclude the natural overwrite-intent key")
	# Elided-read rung: a DEFAULT read elides packed-array payloads and marks the file seen (edits stay grounded) but refuses the wholesale overwrite — the markers stand in for data a rebuilt file cannot contain.
	var blob_ledger := GDLLMTools.SessionLedger.new()
	var blobbed := _fixture(BLOBBED_RES)
	var blob_read := String((await GDLLMTools.execute("read_file", {"path": blobbed}, false, false, {}, blob_ledger))["content"])
	_check(blob_read.contains("bytes elided>"), "the blob fixture's payload is elided in a default read")
	_check(blob_read.contains("full:true"), "an elided read's note names full:true as the route to the payloads")
	_check(blob_read.contains("(1 packed-array payload(s) elided"), "the note counts exactly the real markers in the shown text")
	_check(blob_ledger.seen_files.get(blobbed) == true, "an elided read still marks the file seen verbatim")
	_check(blob_ledger.elided_files.has(blobbed), "an elided read records the elision in the ledger")
	var elided_refusal: String = GDLLMTools._write_overwrite_seen_guard(blobbed, blob_ledger, false)
	_check(elided_refusal.begins_with("Error:") and elided_refusal.contains("elided"), "overwriting a file whose read elided payloads is refused, naming the elision")
	_check(elided_refusal.contains("edit_file") and elided_refusal.contains("full:true"), "the elided refusal routes to edit_file and names the full:true re-read unlock")
	_check(GDLLMTools._edit_file_unseen_guard(blobbed, blob_ledger) == "", "the elided read still grounds edit_file — only the wholesale overwrite is refused")
	_check(GDLLMTools._write_overwrite_seen_guard(blobbed, blob_ledger, true) == "", "force waives the elided-read refusal")
	# full:true is the deliberate escalation: every byte comes back, and holding the whole file re-grounds the wholesale overwrite — so the refusal's advice is an unlock that actually works.
	var full_read := String((await GDLLMTools.execute("read_file", {"path": blobbed, "full": true}, false, false, {}, blob_ledger))["content"])
	_check(full_read.contains("QUJDREVG") and not full_read.contains("elided>"), "a full read returns the payloads verbatim with no markers")
	_check(blob_ledger.elided_files.get(blobbed) == false, "a whole-file full read disarms the record sticky, not by erasing it")
	_check(GDLLMTools._write_overwrite_seen_guard(blobbed, blob_ledger, false) == "", "after the full read the wholesale overwrite is re-grounded and passes")
	# The wild false positive, pinned exactly: a later eliding VIEW (a search excerpt, a plain re-read) must not re-arm the gate the full read disarmed — the model still holds every byte.
	await GDLLMTools.execute("search_files", {"query": "metadata/blob", "path": blobbed}, false, false, {}, blob_ledger)
	await GDLLMTools.execute("read_file", {"path": blobbed}, false, false, {}, blob_ledger)
	_check(blob_ledger.elided_files.get(blobbed) == false, "an eliding search or plain re-read after the full read does not re-arm the record")
	_check(GDLLMTools._write_overwrite_seen_guard(blobbed, blob_ledger, false) == "", "the wholesale overwrite stays grounded after later elided views — the wild force-through ordering")
	# The flag covers the whole file, not the shown slice: a ranged read that never displays the blob still records it, because the data exists either way.
	var range_ledger := GDLLMTools.SessionLedger.new()
	await GDLLMTools.execute("read_file", {"path": blobbed, "start_line": 1, "end_line": 1}, false, false, {}, range_ledger)
	_check(range_ledger.elided_files.has(blobbed), "a ranged read outside the blob still records the elision")
	# A verbatim slice under full is still a slice: the bytes shown are real, but the record stands until the WHOLE file is held.
	var slice := String((await GDLLMTools.execute("read_file", {"path": blobbed, "full": true, "start_line": 4, "end_line": 4}, false, false, {}, range_ledger))["content"])
	_check(slice.contains("QUJDREVG"), "a ranged read under full returns the slice verbatim, payload included")
	_check(range_ledger.elided_files.has(blobbed), "a verbatim slice does not clear the record — only the whole file does")
	# A read that elided nothing records nothing, so ordinary files never hit the new rung.
	var clean_ledger := GDLLMTools.SessionLedger.new()
	await GDLLMTools.execute("read_file", {"path": live, "full": true}, false, false, {}, clean_ledger)
	_check(not clean_ledger.elided_files.has(live), "a read that elided nothing records no elision")
	_check(GDLLMTools._write_overwrite_seen_guard(live, clean_ledger, false) == "", "a blob-free file read whole still overwrites freely")
	# Authoring the whole file clears the flag: the new content is entirely model-written, so nothing unseen survives in it.
	var text_ledger := GDLLMTools.SessionLedger.new()
	var blob_text := _fixture(BLOBBED_TEXT)
	await GDLLMTools.execute("read_file", {"path": blob_text}, false, false, {}, text_ledger)
	_check(text_ledger.elided_files.has(blob_text), "the .txt blob fixture records its elision too")
	var authored := "regenerated, payload kept\ndata = PackedByteArray(\"%s\")\n" % "QUJDREVG".repeat(30)
	var rewritten := String((await GDLLMTools.execute("write_file", {"path": blob_text, "content": authored, "force": true}, true, false, {}, text_ledger))["content"])
	_check(rewritten.begins_with("Overwrote"), "a forced overwrite of the elided file proceeds")
	_check(text_ledger.elided_files.get(blob_text) == false, "authoring blob-carrying content disarms the record sticky")
	_check(GDLLMTools._write_overwrite_seen_guard(blob_text, text_ledger, false) == "", "the model-authored file overwrites freely from then on")
	# The author saw every byte it wrote, so an elided re-read of its own content must not re-arm the gate either.
	await GDLLMTools.execute("read_file", {"path": blob_text}, false, false, {}, text_ledger)
	_check(text_ledger.elided_files.get(blob_text) == false, "an elided re-read of the authored file does not re-arm the gate")


## Every raw-text server elides packed-array payloads, not just read_file — the wild bypass was a model told "the read tool elides blobs" pulling them all through search_files instead. Excerpts show the marker with true on-disk line numbers, the elision stamps the ledger so a search-first session still arms the overwrite gate, and read_function follows the same rule.
func _test_search_elision() -> void:
	var blobbed := _fixture(BLOBBED_RES)
	var search_ledger := GDLLMTools.SessionLedger.new()
	var excerpt := String((await GDLLMTools.execute("search_files", {"query": "metadata/blob", "path": blobbed}, false, false, {}, search_ledger))["content"])
	_check(excerpt.contains("bytes elided>"), "a search excerpt shows the elision marker where the payload sits")
	_check(excerpt.contains("full:true"), "an eliding search result's note names read_file full:true as the route")
	_check(not excerpt.contains("QUJDREVG"), "the raw payload never reaches a search excerpt")
	_check(excerpt.contains("4: metadata/blob"), "the excerpt's line number still matches the file on disk — elision never moves a line")
	_check(search_ledger.seen_files.get(blobbed) == true, "an excerpt still marks the file seen verbatim")
	_check(search_ledger.elided_files.has(blobbed), "the excerpt's elision stamps the ledger")
	var search_first: String = GDLLMTools._write_overwrite_seen_guard(blobbed, search_ledger, false)
	_check(search_first.begins_with("Error:") and search_first.contains("elided"), "a search-first session on a blob file still refuses the wholesale overwrite")
	# read_function under the same rule: a GDScript whose function body carries a data payload elides it and stamps. The payload rides a comment so the fixture stays compile-clean — the elision scan is text-level either way.
	var blob_gd := _fixture("gdllm_resolve_probe_blob_fn.gd")
	_write(blob_gd, "extends Node\n\n\nfunc blob_data() -> int:\n\t# PackedByteArray(\"%s\")\n\treturn 1\n" % "QUJDREVG".repeat(30))
	var fn_ledger := GDLLMTools.SessionLedger.new()
	var fn := String((await GDLLMTools.execute("read_function", {"path": blob_gd, "name": "blob_data"}, false, false, {}, fn_ledger))["content"])
	_check(fn.contains("bytes elided>") and not fn.contains("QUJDREVG"), "read_function elides a payload inside a function body")
	_check(fn_ledger.elided_files.has(blob_gd), "read_function's elision stamps the ledger too")
	DirAccess.remove_absolute(blob_gd)
	# A blob-free search neither elides nor stamps, so ordinary files never hit the gate's new rung from a search.
	var clean_ledger := GDLLMTools.SessionLedger.new()
	var clean := String((await GDLLMTools.execute("search_files", {"query": "unique probe", "path": _fixture(UNIQUE)}, false, false, {}, clean_ledger))["content"])
	_check(clean.contains("unique probe"), "a blob-free search still excerpts normally")
	_check(clean_ledger.elided_files.is_empty(), "a blob-free search stamps nothing")
	# A user's file that merely TALKS about elision must not be miscounted: the note matches the marker's exact "<N bytes elided>" shape, never the words.
	var prose := _fixture("gdllm_resolve_probe_elision_prose.txt")
	_write(prose, "notes on markers\nthe string elided> appears in these docs\nand \"<some bytes elided>\" is not a real marker either\n")
	var prose_ledger := GDLLMTools.SessionLedger.new()
	var prose_read := String((await GDLLMTools.execute("read_file", {"path": prose}, false, false, {}, prose_ledger))["content"])
	_check(prose_read.contains("<some bytes elided>") and not prose_read.contains("payload(s) elided"), "a file that talks about elision reads whole with no elision note")
	var prose_search := String((await GDLLMTools.execute("search_files", {"query": "elided", "path": prose}, false, false, {}, prose_ledger))["content"])
	_check(not prose_search.contains("payload(s) elided"), "a search excerpting that file earns no note either")
	_check(prose_ledger.elided_files.is_empty(), "and nothing arms the overwrite gate for it")
	DirAccess.remove_absolute(prose)


## A path that resolved and then would not open is a race, not a typo, so the refusal names the OS-level cause and the move it calls for instead of a bare "could not open".
func _test_open_failure_cause() -> void:
	var live := _fixture(UNIQUE)
	var lifted: String = GDLLMTools._file_open_error(live)
	_check(lifted.contains("it opens now") and lifted.contains(GDLLMTools.TRANSIENT_RETRY_INVITATION), "a condition that has already lifted is the one case the refusal invites a retry")
	var gone := _fixture("gdllm_resolve_probe_vanished.txt")
	_write(gone, "here and then not")
	DirAccess.remove_absolute(gone)
	var missing: String = GDLLMTools._file_open_error(gone)
	_check(missing.contains("gone from disk") and missing.contains("search_files"), "a file deleted between resolution and open is named as deleted and routed to search_files")
	_check(GDLLMTools._file_open_error(gone, "edit").contains("could not be opened to edit"), "the purpose the caller was attempting rides the head of the message")


## A resource that exists but will not load is almost always a broken dependency, and the engine's own dependency records can name it — the three shapes want three different fixes.
func _test_resource_load_cause() -> void:
	var broken: String = GDLLMTools._resource_load_cause(_fixture(BROKEN_SCENE))
	_check(broken.contains(ABSENT_DEP) and broken.contains("Restore"), "a dependency missing from disk is named and the fix is to restore or re-point it")
	var scripted: String = GDLLMTools._resource_load_cause(_fixture(SCRIPTED_SCENE))
	_check(scripted.contains("check_script") and scripted.contains("gdllm_tools.gd"), "every dependency present points at the depended-on script and check_script")
	_check(GDLLMTools._resource_load_cause(_fixture(HOLLOW_SCENE)).contains("[gd_scene]"), "a scene with nothing missing is sent to its own [gd_scene] header")
	_check(GDLLMTools._resource_load_cause(_fixture(HOLLOW_RES)).contains("[gd_resource]"), "a text resource is sent to its own [gd_resource] header instead")
	var binary: String = GDLLMTools._resource_load_cause(_fixture(BINARY_RES))
	_check(binary.contains("binary") and not binary.contains("read_file"), "a binary resource is never sent to read_file, which would only refuse it as non-text")
	# A missing script dependency still loads (the node comes back scriptless), so the end-to-end check needs a scene the parser itself rejects.
	var scene_call := String((await GDLLMTools.execute("describe_scene_file", {"path": _fixture(CORRUPT_SCENE)}))["content"])
	_check(scene_call.contains("could not be loaded as a scene") and scene_call.contains("[gd_scene]"), "describe_scene_file's own refusal carries the cause, not just the failure")


## A failed write states which of the three causes it was — nonexistent folder, refusing OS, or a condition already lifted — where the old wording guessed "is it read-only?" every time.
func _test_write_failure_cause() -> void:
	var no_folder := FIXTURE_DIR.path_join("nowhere").path_join("probe.txt")
	var missing_dir: String = GDLLMTools._write_failure_cause(no_folder)
	_check(missing_dir.contains(FIXTURE_DIR.path_join("nowhere")) and missing_dir.contains("does not exist"), "a write into a folder that does not exist names the folder rather than blaming the file")
	var live := _fixture(UNIQUE)
	_check(GDLLMTools._write_failure_cause(live).contains(GDLLMTools.TRANSIENT_RETRY_INVITATION), "a path that takes writes again is the one case the cause invites a retry")
	_check(GDLLMTools._file_write_error(live).contains("the changes could not be written to %s" % live), "the edit_file refusal says the changes are what did not reach disk")
	_check(GDLLMTools._file_write_error(live, "the file").contains("the file could not be written to %s" % live), "the write_file refusal names the file instead, keeping the caller's own wording")


## The probe behind the write cause must never open WRITE — the truncating mode would destroy the very file whose update just failed, turning a diagnosis into data loss.
func _test_write_probe_never_truncates() -> void:
	var path := _fixture("gdllm_resolve_probe_intact.txt")
	_write(path, "content that must survive being diagnosed")
	GDLLMTools._write_failure_cause(path)
	GDLLMTools._file_write_error(path)
	_check(FileAccess.get_file_as_string(path) == "content that must survive being diagnosed", "diagnosing a failed write leaves the file's contents untouched")


## ResourceSaver fails two unrelated ways, and the fixes do not overlap: the filesystem refusing the write, or the engine refusing to serialize the resource at all.
func _test_resource_save_cause() -> void:
	var live := _fixture(UNIQUE)
	_check(GDLLMTools._resource_save_cause(live, ERR_FILE_CANT_WRITE).contains(GDLLMTools.TRANSIENT_RETRY_INVITATION), "a write-level save error gets the same cause walk every other failed write gets")
	var serializer: String = GDLLMTools._resource_save_cause(live, ERR_INVALID_PARAMETER)
	_check(serializer.contains("refused to serialize") and serializer.contains(".tres"), "any other code names the serializer and the extension mismatch behind it")
