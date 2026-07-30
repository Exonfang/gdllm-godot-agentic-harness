extends SceneTree
## Headless regression tests for .gdshader validation: the pure scrape that turns one check run's output into the classified-error shape the .gd path already speaks, the wordings a shader verdict differs in, check_script's accept/refuse ladder, and the whole chain end to end against real engine subprocesses — a broken shader caught and a clean one cleared.
## The engine-output fixtures below are verbatim captures from real 4.7 runs, since the whole feature is a scrape of wordings this repo does not own.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/shader_check_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

const SHADER_PATH := "res://gdllm_shader_check_a.gdshader"
const CLEAN_FIXTURE := "res://gdllm_shader_check_clean.gdshader"
const BROKEN_FIXTURE := "res://gdllm_shader_check_broken.gdshader"
const MATERIAL_FIXTURE := "res://gdllm_shader_check_material.tres"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_own_error()
	_test_include_error()
	_test_shader_type()
	_test_preprocessor_error()
	_test_missing_bracket_is_no_verdict()
	_test_absent_shader()
	_test_clean_and_attribution()
	_test_location_lookahead()
	_test_verdict_wording()
	_test_check_script_refusals()
	_test_end_to_end()
	_test_write_and_edit_end_to_end()
	_test_shader_material_parameters()
	_test_create_resource_shader_parameters()
	_test_include_fault_is_not_blamed_on_the_edit()
	_test_uid_sidecar()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## One check run's output with `body` inside the bracket load_check.gd prints around the compile, plus the surrounding noise a real run carries — the child's sentinel, and the stdout excerpt block the engine prints on its OTHER stream, which the parent's two-pipe drain can splice in anywhere.
func _run_output(body: String, outside := "") -> String:
	return "--Main Shader--\n    6 | 	vec3 c = COLOR.rgb;\nE   7-> 	COLOR.rgb = c + nope;\n%s%s\n%s\n%s\nGDLLM_CHECK_DONE\n" % [outside, Tools.SHADER_BEGIN_MARKER + SHADER_PATH, body, Tools.SHADER_END_MARKER + SHADER_PATH]


func _test_own_error() -> void:
	var out := _run_output("SHADER ERROR: Unknown identifier in expression: 'nope'.\n          at: (null) (:7)\nERROR: Shader compilation failed.\n   at: shader_set_code (servers/rendering/dummy/storage/material_storage.cpp:192)")
	var classified := Tools._shader_errors_from_output(out, SHADER_PATH)
	_check(bool(classified["ok"]), "a completed run reports a verdict")
	_check(classified["own"] == ["Unknown identifier in expression: 'nope'."], "the error's own form is the message alone, so a line shift can't read as fresh damage")
	_check(classified["own_located"] == ["line 7: Unknown identifier in expression: 'nope'."], "and its located form carries the line the engine named, in the shape the .gd path already speaks")
	# The located form is what the excerpt composer keys on; without the shared "line N:" shape a shader error would come back with no quoted line.
	_check(Tools._edit_file_error_excerpts("1\n2\n3\n4\n5\n6\nseven\n8\n", classified["own_located"]).contains("seven"), "so the shared excerpt composer quotes the offending line")
	# The engine names no file on a main-shader error, so the bracket is the only attribution there is.
	var elsewhere := Tools._shader_errors_from_output(out, "res://other.gdshader")
	_check((elsewhere["own"] as Array).is_empty(), "an error bracketed under another path is not this file's")
	_check(not bool(elsewhere["ok"]), "and with no bracket of its own that run is no verdict about it either")


func _test_include_error() -> void:
	var out := _run_output("SHADER ERROR: Expected a ';' after 'return'.\n          at: (null) (res://shared/util.gdshaderinc:3)")
	var classified := Tools._shader_errors_from_output(out, SHADER_PATH)
	var located := String((classified["own_located"] as Array)[0])
	_check(located.contains("res://shared/util.gdshaderinc") and located.contains("line 3"), "an error the compiler reached through an #include names that file and its line")
	# That number indexes the OTHER file: prefixed "line 3:", the excerpt composer would quote line 3 of the shader and point the fix at the wrong text.
	_check(not located.begins_with("line 3:"), "and deliberately drops the own-file line prefix")
	_check(Tools._edit_file_error_excerpts("a\nb\nc\nd\n", classified["own_located"]) == "", "so no excerpt of the including file is quoted at it")
	# _edit_file_locate_problems pairs the stripped and located forms by suffix, which is what keeps the include's location on an edit_file verdict.
	_check(Tools._edit_file_locate_problems(classified["own"], classified["own_located"]) == classified["own_located"], "the stripped form still pairs back to the located one")


func _test_shader_type() -> void:
	var typo := Tools._shader_errors_from_output(_run_output("ERROR: Shader type CanvasItem not supported in Dummy renderer.\n   at: shader_set_code (servers/rendering/dummy/storage/material_storage.cpp:185)"), SHADER_PATH)
	var message := String((typo["own_located"] as Array)[0])
	_check(message.contains("\"CanvasItem\" is not a shader type"), "a declared type the engine doesn't have is named as the mistake it is")
	_check(message.contains("canvas_item") and message.contains("spatial") and message.contains("fog"), "and the real types are listed, since the case is nearly always a spelling")
	# The engine blames its renderer, which reads as a limitation of this check rather than the typo it is — and sent nobody to the shader_type line.
	_check(not message.contains("Dummy renderer"), "the engine's renderer wording is not passed through")
	var missing := Tools._shader_errors_from_output(_run_output("ERROR: Shader type  not supported in Dummy renderer."), SHADER_PATH)
	_check(String((missing["own_located"] as Array)[0]).contains("declares no shader_type"), "a shader with no shader_type at all is told to add one")
	# A REAL type refused would mean this check fell short, not that the file is wrong; an invented error there would be an accusation with nothing behind it.
	var limited := Tools._shader_errors_from_output(_run_output("ERROR: Shader type sky not supported in Dummy renderer."), SHADER_PATH)
	_check(not bool(limited["ok"]) and (limited["own"] as Array).is_empty(), "a type the engine really has, refused, yields no verdict rather than a fabricated error")
	_check(String(limited["why"]).contains("sky"), "and says which type went unchecked")


## The preprocessor runs ahead of the compiler and leaves a rejected directive in the code, so every one of its failures arrives as one message about a stray '#' that names neither the directive nor the problem.
func _test_preprocessor_error() -> void:
	var out := _run_output("SHADER ERROR: Tokenizer: Unknown character #35: '#'\n          at: (null) (:2)")
	var classified := Tools._shader_errors_from_output(out, SHADER_PATH)
	var message := String((classified["own_located"] as Array)[0])
	_check(message.contains("Unknown character #35"), "the engine's own wording is kept")
	_check(message.contains("#include whose path does not resolve"), "with the causes it points at named, since the message alone points nowhere")
	_check(message.begins_with("line 2: "), "still located at the offending directive")
	# Every other message stands on its own and must not collect advice it didn't earn.
	_check(Tools._shader_message("Invalid assignment of 'vec3' to 'float'.") == "Invalid assignment of 'vec3' to 'float'.", "an ordinary error is passed through untouched")


## The one answer that is never safe. A shader the PROJECT uses is compiled during boot, so its error prints before the bracket and a re-query of that same instance is silent — which reported a file CLEAN that the engine's own error log said would not compile (wild-measured, then reproduced against the real project).
func _test_missing_bracket_is_no_verdict() -> void:
	var body := "SHADER ERROR: Expected a ',' or ';'.\n          at: (null) (:7)\n"
	# The exact shape of the wild failure: the compile happened, its error printed, but not where it could be attributed.
	var unbracketed := Tools._shader_errors_from_output("%sGDLLM_CHECK_DONE\n" % body, SHADER_PATH)
	_check(not bool(unbracketed["ok"]), "a run with no bracket at all is no verdict")
	_check((unbracketed["own"] as Array).is_empty() and String(unbracketed["why"]) != "", "it reports nothing known, with a reason, rather than a clean bill")
	# A clean shader and an unattributable one must not look the same, or the rail buys nothing.
	_check(bool(Tools._shader_errors_from_output(_run_output(""), SHADER_PATH)["ok"]), "while a bracketed compile that printed nothing is still clean")
	var half := Tools._shader_errors_from_output("%s%s\n%sGDLLM_CHECK_DONE\n" % [Tools.SHADER_BEGIN_MARKER, SHADER_PATH, body], SHADER_PATH)
	_check(not bool(half["ok"]), "a bracket that opens and never closes is no verdict either — the compile may have been cut short")


func _test_absent_shader() -> void:
	var empty := Tools._shader_errors_from_output(_run_output("ERROR: Parameter \"shader\" is null.\n   at: get_shader_parameter_list (servers/rendering/dummy/storage/material_storage.cpp:197)"), SHADER_PATH)
	_check(String((empty["own_located"] as Array)[0]).contains("no shader code"), "a file the engine built no shader from is stated, not passed off as clean")


func _test_clean_and_attribution() -> void:
	var clean := Tools._shader_errors_from_output(_run_output(""), SHADER_PATH)
	_check(bool(clean["ok"]) and (clean["own"] as Array).is_empty() and (clean["foreign"] as Array).is_empty(), "a compile that printed nothing is clean")
	# Another shader loading during the check would otherwise be blamed on this file, which is the whole reason load_check.gd brackets its compile.
	var outside := "SHADER ERROR: Expected a ';'.\n          at: (null) (:2)\n"
	var bracketed := Tools._shader_errors_from_output(_run_output("", outside), SHADER_PATH)
	_check((bracketed["own"] as Array).is_empty(), "a shader error raised outside the bracket is not counted against the checked file")
	# A GDScript parse error can never belong to a .gdshader, so the whole script channel is other files' noise here — located or not.
	var noisy := Tools._shader_errors_from_output(_run_output("", "ERROR: res://autoload.gd:12 - Parse Error: Identifier \"nope\" not declared.\n"), SHADER_PATH)
	_check((noisy["own"] as Array).is_empty(), "a broken autoload's parse error is never the shader's")
	_check((noisy["foreign"] as Array).size() == 1, "it rides the foreign channel instead, so the noise is still disclosed")
	_check(Tools._foreign_noise_note(noisy["foreign"], SHADER_PATH).contains("OTHER files"), "and reaches the shared disclosure note")


func _test_location_lookahead() -> void:
	# The parent drains the child's two streams separately, so the engine's stdout excerpt can land between a SHADER ERROR and the "at:" line that locates it.
	var spliced := PackedStringArray(["SHADER ERROR: Invalid render mode: 'nope'.", "    2 | render_mode nope;", "          at: (null) (:2)"])
	_check(Tools._shader_error_location(spliced, 0, SHADER_PATH) == "line 2: ", "the location is still found past an interleaved output line")
	var lost := PackedStringArray(["SHADER ERROR: Something.", "noise", "noise", "noise", "          at: (null) (:9)"])
	_check(Tools._shader_error_location(lost, 0, SHADER_PATH) == "", "and an error with no reachable location reports none rather than guessing one")


func _test_verdict_wording() -> void:
	_check(Tools._source_noun(SHADER_PATH) == "shader" and Tools._source_noun("res://a.gd") == "script", "a verdict calls a shader a shader")
	_check(Tools._source_clean_verb(SHADER_PATH) == "compiles" and Tools._source_clean_verb("res://a.gd") == "parses", "and says which check earned the clean bill")
	# GDScript reports its whole error set in one run while the shader compiler stops at the first, so an identical-looking count means different things.
	var note := Tools._shader_stop_note(SHADER_PATH, ["line 7: nope"])
	_check(note.contains("FIRST error"), "a shader's error report says the compiler stopped at the first error")
	_check(Tools._shader_stop_note("res://a.gd", ["line 7: nope"]) == "", "a script's does not, since its list is the whole set")
	_check(Tools._shader_stop_note(SHADER_PATH, []) == "", "and a clean shader pays no context for the note")
	# The style guide the linter enforces is GDScript's; a shader must not report a lint run that never happened.
	var lint: Dictionary = await Tools._source_lint_problems(SHADER_PATH)
	_check(bool(lint["ok"]) and (lint["problems"] as Array).is_empty(), "a shader's lint half reports the completed-and-clean shape, not a failed run")


func _test_check_script_refusals() -> void:
	_check(Tools._uncheckable_source_refusal("res://a.gd") == "" and Tools._uncheckable_source_refusal("res://a.gdshader") == "", "both compilable sources are accepted")
	var other := Tools._uncheckable_source_refusal("res://icon.png")
	_check(other.contains(".gd scripts and .gdshader shaders"), "anything else is refused naming both kinds that can be checked")
	# The near miss with a real answer: the engine only ever compiles an include as part of a shader that pulls it in.
	var include := Tools._uncheckable_source_refusal("res://shared/util.gdshaderinc")
	_check(include.contains("never compiles on its own"), "a shader include is refused with the reason, not as an unknown file type")
	_check(include.contains(".gdshader"), "and pointed at the shader that would report its errors")


func _test_end_to_end() -> void:
	_write(CLEAN_FIXTURE, "shader_type canvas_item;\n\nuniform float amount = 1.0;\n\nvoid fragment() {\n\tCOLOR.rgb *= amount;\n}\n")
	# A missing semicolon: the shape a hand-edited shader fails in, and the one the old toolset shipped to disk unremarked.
	_write(BROKEN_FIXTURE, "shader_type canvas_item;\n\nvoid fragment() {\n\tvec3 c = COLOR.rgb\n\tCOLOR.rgb = c;\n}\n")
	var clean: Dictionary = await Tools._classified_shader_errors(CLEAN_FIXTURE)
	_check(bool(clean["ok"]), "the real check run completes")
	_check((clean["own"] as Array).is_empty(), "a valid shader really compiles clean through the engine")
	var broken: Dictionary = await Tools._classified_shader_errors(BROKEN_FIXTURE)
	_check(bool(broken["ok"]), "the run over a broken shader completes too")
	# The load alone proves nothing here: a .gdshader loads whatever its text says, which is why load_check.gd forces the compile.
	_check((broken["own"] as Array).size() == 1, "and the engine's own compiler catches the missing semicolon")
	_check(String((broken["own_located"] as Array)[0]).begins_with("line "), "reported against a line of the file")
	var ledger = Tools.SessionLedger.new()
	var verdict: String = await Tools._check_script({"path": BROKEN_FIXTURE}, ledger)
	_check(verdict.contains("parse/compile error(s)") and verdict.contains("FIRST error"), "check_script reports it with the stops-at-first caveat")
	_check(ledger.auto_check_reports.has(BROKEN_FIXTURE), "and fingerprints it like any other error set, so an unchanged re-check collapses")
	var cleared: String = await Tools._check_script({"path": CLEAN_FIXTURE}, ledger)
	_check(cleared.contains("compiles cleanly"), "a clean shader earns the compile-checked bill")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CLEAN_FIXTURE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BROKEN_FIXTURE))


## The surface the gap was actually reported against: a model writing or editing a shader used to be told nothing at all, and the error waited for the user to run the game.
func _test_write_and_edit_end_to_end() -> void:
	var broken := "shader_type canvas_item;\n\nvoid fragment() {\n\tCOLOR.rgb = missing_thing;\n}\n"
	var written: String = await _run("write_file", {"path": BROKEN_FIXTURE, "content": broken})
	_check(written.contains("BROKEN on disk"), "write_file reports a shader that does not compile instead of confirming the write")
	_check(written.contains("the shader is BROKEN"), "and calls it a shader, not a script")
	_check(written.contains("missing_thing"), "quoting the engine's own complaint")
	_check(written.contains("FIRST error"), "with the stops-at-first caveat a shader's count needs")
	var fixed: String = await _run("edit_file", {"path": BROKEN_FIXTURE, "old_string": "missing_thing", "new_string": "vec3(1.0)"})
	_check(fixed.contains("compiles cleanly (engine-checked)"), "and the fixing edit earns the compile-checked clean bill")
	# The style guide the linter enforces is GDScript's, so a shader edit must not report a lint run at all.
	_check(not fixed.contains("style-lint"), "no style-lint note rides a shader edit")
	var still_broken: String = await _run("edit_file", {"path": BROKEN_FIXTURE, "old_string": "COLOR.rgb = vec3(1.0);", "new_string": "COLOR.rgb = vec3(1.0)"})
	_check(still_broken.contains("BROKEN on disk") and still_broken.contains("YOU introduced"), "an edit that breaks a working shader is attributed to the edit that broke it")
	var writes_clean: String = await _run("write_file", {"path": BROKEN_FIXTURE, "content": "shader_type canvas_item;\n\nvoid fragment() {\n\tCOLOR.rgb = vec3(1.0);\n}\n", "force": true})
	_check(writes_clean.contains("compiles cleanly (engine-checked)"), "and a clean overwrite says which check cleared it")
	# The third surface: a shader the model merely READS is checked by the same automatic hook a script's read fires, so damage nobody touched is flagged before it is built on.
	var read_clean: String = await _run("read_file", {"path": BROKEN_FIXTURE}, false)
	_check(not read_clean.contains("Automatic check_script"), "reading a clean shader appends nothing, so it costs the context nothing")
	_write(BROKEN_FIXTURE, "shader_type canvas_item;\n\nvoid fragment() {\n\tCOLOR.rgb = gone;\n}\n")
	var read_broken: String = await _run("read_file", {"path": BROKEN_FIXTURE}, false)
	_check(read_broken.contains("Automatic check_script") and read_broken.contains("gone"), "and reading a broken one flags it without being asked")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BROKEN_FIXTURE))


## The follow-up half of a shader edit, and where two wild failures landed: having added a uniform, the model went to persist it on the material that uses the shader.
func _test_shader_material_parameters() -> void:
	_write(BROKEN_FIXTURE, "shader_type canvas_item;\n\nuniform float tint_amount = 0.5;\n\nvoid fragment() {\n\tCOLOR.rgb *= tint_amount;\n}\n")
	var material := ShaderMaterial.new()
	material.shader = load(BROKEN_FIXTURE)
	ResourceSaver.save(material, MATERIAL_FIXTURE)
	# A uniform the shader ALREADY had: the bare name is what the shader declares and the inspector shows, so refusing it helped nobody.
	var bare: String = await _run("edit_resource", {"path": MATERIAL_FIXTURE, "properties": {"tint_amount": 0.25}})
	_check(bare.contains("Saved"), "a uniform set by its bare name is applied, not refused")
	_check(bare.contains("shader_parameter/tint_amount"), "and the substitution is disclosed rather than done quietly")
	var prefixed: String = await _run("edit_resource", {"path": MATERIAL_FIXTURE, "properties": {"shader_parameter/tint_amount": 0.75}})
	_check(prefixed.contains("Saved") and not prefixed.contains("was set as"), "the explicit stored name still works and earns no substitution note")
	# Both spellings in one batch are two values for one property; last-wins would silently drop one.
	var clash: String = await _run("edit_resource", {"path": MATERIAL_FIXTURE, "properties": {"tint_amount": 0.1, "shader_parameter/tint_amount": 0.2}})
	_check(clash.contains("same property") and clash.contains("Nothing was written"), "asking for both spellings at once is refused rather than resolved by luck")
	# The wild dead end: ClassDB knows exactly one ShaderMaterial property ("shader"), so describe_class could never answer this.
	var unknown: String = await _run("edit_resource", {"path": MATERIAL_FIXTURE, "properties": {"totally_absent": 1.0}})
	_check(not unknown.contains("describe_class"), "an unknown name is not sent to a class view that cannot list shader parameters")
	_check(unknown.contains("shader_parameter/tint_amount"), "it is answered with the instance's real settable names instead")
	# The staleness that caused the wild refusal: the material reads its rows from the shader's uniform list, so a uniform an edit ADDS does not exist until the cached Shader re-reads the file.
	var added: String = await _run("edit_file", {"path": BROKEN_FIXTURE, "old_string": "uniform float tint_amount = 0.5;", "new_string": "uniform float tint_amount = 0.5;\nuniform float fresh_uniform = 1.0;"})
	_check(added.contains("compiles cleanly"), "the uniform-adding edit lands")
	var fresh: String = await _run("edit_resource", {"path": MATERIAL_FIXTURE, "properties": {"fresh_uniform": 0.5}})
	_check(fresh.contains("Saved"), "and the material can set the uniform that edit just created, in the same run")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BROKEN_FIXTURE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MATERIAL_FIXTURE))


## The other half of the same wall, wild-measured on create_resource: a fresh ShaderMaterial has no shader_parameter/* until its shader is assigned, so a batch naming both was judged against a material that had not yet become what it was being built into.
func _test_create_resource_shader_parameters() -> void:
	_write(BROKEN_FIXTURE, "shader_type canvas_item;\n\nuniform float tint_amount = 0.5;\nuniform vec4 tint : source_color = vec4(1.0);\n\nvoid fragment() {\n\tCOLOR.rgb *= tint_amount;\n}\n")
	var made: String = await _run("create_resource", {"from": "ShaderMaterial", "path": MATERIAL_FIXTURE, "overwrite": true, "properties": {"shader": BROKEN_FIXTURE, "shader_parameter/tint_amount": 0.25, "tint": "Color(1, 0, 0, 1)"}})
	_check(made.contains("Created"), "a material is built with its shader's uniforms in the same batch")
	_check(made.contains("shader_parameter/tint_amount = 0.25"), "the prefixed uniform is set rather than refused")
	_check(made.contains("shader_parameter/tint = "), "and a bare one resolves to the stored name, as it does in edit_resource")
	_check(made.contains("was set as"), "with the substitution disclosed in the words both tools share")
	# ClassDB knows one ShaderMaterial property, so "Did you mean: shader?" was the only thing the old near-miss could offer for any uniform.
	var unknown: String = await _run("create_resource", {"from": "ShaderMaterial", "path": MATERIAL_FIXTURE, "overwrite": true, "properties": {"shader": BROKEN_FIXTURE, "not_a_uniform": 1.0}})
	_check(unknown.begins_with("Error:") and unknown.contains("shader_parameter/tint_amount"), "an unknown name is answered with the material's real properties")
	_check(not unknown.contains("Did you mean: shader?"), "not with the lone class property that used to be the only suggestion")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BROKEN_FIXTURE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MATERIAL_FIXTURE))


## Wild-measured: an edit that merely corrected a misspelled #include path was told "YOU introduced these errors" about the semicolon already missing in the file it finally reached — an accusation that contradicted the report right below it, which named the other file.
func _test_include_fault_is_not_blamed_on_the_edit() -> void:
	var inc := "res://gdllm_shader_check_inc.gdshaderinc"
	_write(inc, "float half_of(float v) {\n\treturn v * 0.5\n}\n")
	_write(BROKEN_FIXTURE, "shader_type canvas_item;\n#include \"res://gdllm_shader_check_typo.gdshaderinc\"\n\nvoid fragment() {\n\tCOLOR.r = half_of(0.5);\n}\n")
	var fixed: String = await _run("edit_file", {"path": BROKEN_FIXTURE, "old_string": "gdllm_shader_check_typo.gdshaderinc", "new_string": "gdllm_shader_check_inc.gdshaderinc"})
	_check(fixed.contains(inc), "the verdict names the #include'd file the fault is in")
	_check(not fixed.contains("YOU introduced"), "and does not accuse the edit that only reached it")
	_check(fixed.contains("Fix them THERE"), "it points the fix at that file instead of back at this one")
	# The edit is still kept and the shader still does not compile — softening the blame must not soften the state.
	_check(fixed.contains("does not compile"), "while still saying the edited file does not compile")
	# A fault in the file's OWN text keeps the accusation, or the correction would blunt every real one.
	_write(inc, "float half_of(float v) {\n\treturn v * 0.5;\n}\n")
	var own: String = await _run("edit_file", {"path": BROKEN_FIXTURE, "old_string": "COLOR.r = half_of(0.5);", "new_string": "COLOR.r = half_of(0.5)"})
	_check(own.contains("YOU introduced"), "an error in the edited file's own text is still attributed to the edit")
	for path in [inc, BROKEN_FIXTURE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".uid"))


## A .gdshader carries its uid in a sidecar, exactly like a .gd — and headless has no rescan to mint one, so a reference to a fresh shader's uid would resolve nowhere.
func _test_uid_sidecar() -> void:
	for path in [BROKEN_FIXTURE, "res://gdllm_shader_check_inc.gdshaderinc"]:
		var body := "shader_type canvas_item;\n\nvoid fragment() {\n\tCOLOR.rgb = vec3(1.0);\n}\n"
		if path.ends_with("inc"):
			body = "float half_of(float v) {\n\treturn v * 0.5;\n}\n"
		var written: String = await _run("write_file", {"path": path, "content": body})
		_check(FileAccess.file_exists(path + ".uid"), "%s gets its .uid sidecar minted on creation" % path.get_extension())
		var text := FileAccess.get_file_as_string(path + ".uid").strip_edges()
		_check(text.begins_with("uid://"), "the sidecar holds a uid, in the one-line form the editor writes")
		# A uid nothing can resolve is worse than none at all, so the id is registered the moment the sidecar lands.
		_check(ResourceUID.has_id(ResourceUID.text_to_id(text)), "and the id resolves, so a reference to it is not read as invented")
		_check(written.contains(text), "the confirmation reports it, so the uid needs no follow-up read to discover")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".uid"))


func _run(tool_name: String, args: Dictionary, allow_changes := true) -> String:
	return String((await Tools.execute(tool_name, args, allow_changes)).get("content", ""))


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check(false, "the fixture %s could be written" % path)
		return
	file.store_string(text)
	file.close()
