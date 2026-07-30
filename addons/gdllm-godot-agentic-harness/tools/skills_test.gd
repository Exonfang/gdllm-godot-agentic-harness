extends SceneTree
## Headless regression tests for project context: AGENTS.md reading and disclosure transitions, skills discovery and frontmatter parsing, the roster block, and the use_skill tool through the real execute dispatch.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/skills_test.gd
## Exits nonzero on any failure.
## use_skill reads the real res://skills location, so those tests create it at the project root and remove it after — the suite asserts up front that the checkout has none of its own.

# Preloaded rather than referenced by class_name so the test's own references survive a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMInstructions = preload("res://addons/gdllm-godot-agentic-harness/gdllm_instructions.gd")

const SKILLS_ROOT := "res://skills"
const FIXTURE_AGENTS := "res://addons/gdllm-godot-agentic-harness/tools/agents_fixture.md"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_agents_read()
	_test_agents_pick()
	_test_agents_events()
	_test_agents_notice_text()
	_test_agents_block()
	_test_format_tokens()
	_test_parse_skill()
	_test_registration()
	await _test_use_skill_no_dir()
	_write_skill_fixtures()
	_test_discovery()
	_test_conflicts()
	_test_skill_file_capitalization()
	_test_roster()
	_test_find_skill()
	await _test_use_skill_happy()
	await _test_use_skill_unknown()
	await _test_use_skill_whole()
	await _test_use_skill_empty_body()
	_cleanup_skills()
	await _test_use_skill_empty_dir()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real execute dispatch and return its content string.
func _run(tool_name: String, args: Dictionary, ledger: GDLLMTools.SessionLedger = null, allow_changes: bool = false) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes, false, {}, ledger))["content"])


func _test_agents_read() -> void:
	var absent: Dictionary = GDLLMInstructions.read_agents("")
	_check(String(absent["state"]) == "" and String(absent["text"]) == "", "no path reads as the absent state")
	var missing: Dictionary = GDLLMInstructions.read_agents("res://no_such_agents_file.md")
	_check(String(missing["state"]) == "error" and String(missing["error"]) != "", "an unreadable path reads as the error state with a cause")
	var file := FileAccess.open(FIXTURE_AGENTS, FileAccess.WRITE)
	file.store_string("Always use tabs.\n")
	file.close()
	var snap: Dictionary = GDLLMInstructions.read_agents(FIXTURE_AGENTS)
	_check(String(snap["state"]) == ("%s\nAlways use tabs.\n" % FIXTURE_AGENTS).md5_text(), "content reads as its path+content md5 state")
	_check(String(snap["text"]) == "Always use tabs.\n", "content text comes back whole")
	var twin_path := FIXTURE_AGENTS.get_basename() + "_twin.md"
	var twin := FileAccess.open(twin_path, FileAccess.WRITE)
	twin.store_string("Always use tabs.\n")
	twin.close()
	_check(String(GDLLMInstructions.read_agents(twin_path)["state"]) != String(snap["state"]), "identical content at the other candidate path is a different state — the attached block names the path")
	DirAccess.remove_absolute(twin_path)
	_check(GDLLMInstructions.agents_mtime(FIXTURE_AGENTS) > 0, "an existing file has a nonzero mtime")
	_check(GDLLMInstructions.agents_mtime("") == 0, "no path has mtime 0")
	file = FileAccess.open(FIXTURE_AGENTS, FileAccess.WRITE)
	file.store_string("  \n\t\n")
	file.close()
	snap = GDLLMInstructions.read_agents(FIXTURE_AGENTS)
	_check(String(snap["state"]) == "empty", "whitespace-only content reads as the empty state")
	DirAccess.remove_absolute(FIXTURE_AGENTS)


func _test_agents_pick() -> void:
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["Agents.md"])) == "Agents.md", "any capitalization is respected")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["aGeNtS.MD"])) == "aGeNtS.MD", "a wild capitalization is respected")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["agents.md", "AGENTS.md"])) == "AGENTS.md", "the uppercase conventional spelling wins a collision")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["Agents.md", "agents.md"])) == "agents.md", "the lowercase conventional spelling wins over an unconventional one")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["agents.MD", "Agents.md"])) == "Agents.md", "no conventional spelling picks alphabetically for a deterministic winner")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["README.md", "project.godot"])) == "", "unrelated files pick nothing")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["AGENTS.markdown", "AGENTS.txt"])) == "", "other extensions pick nothing")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["Gdllm.md"])) == "Gdllm.md", "any capitalization of the harness override is respected")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["AGENTS.md", "gdllm.md"])) == "gdllm.md", "the harness override outranks the conventional AGENTS.md")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["GDLLM.md", "agents.md", "Gdllm.md"])) == "GDLLM.md", "the fully capitalized GDLLM.md wins a spelling conflict")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["Gdllm.md", "gdllm.md"])) == "gdllm.md", "the lowercase conventional override spelling wins over an unconventional one")
	_check(GDLLMInstructions.agents_pick(PackedStringArray(["gDllm.md", "Gdllm.md", "AGENTS.md"])) == "Gdllm.md", "unconventional override spellings tie-break alphabetically and still outrank AGENTS.md")


func _test_agents_events() -> void:
	var md5_a := "a".md5_text()
	var md5_b := "b".md5_text()
	_check(GDLLMInstructions.agents_event("", md5_a) == "attached", "no file to content is attached")
	_check(GDLLMInstructions.agents_event("empty", md5_a) == "attached", "empty to content is attached")
	_check(GDLLMInstructions.agents_event("error", md5_a) == "attached", "error to content is attached")
	_check(GDLLMInstructions.agents_event(md5_a, md5_b) == "changed", "content to different content is changed")
	_check(GDLLMInstructions.agents_event(md5_a, md5_a) == "", "unchanged content discloses nothing")
	_check(GDLLMInstructions.agents_event("", "") == "", "still-absent discloses nothing")
	_check(GDLLMInstructions.agents_event(md5_a, "") == "removed", "content to no file is removed")
	_check(GDLLMInstructions.agents_event(md5_a, "empty") == "empty", "content to empty discloses the empty state")
	_check(GDLLMInstructions.agents_event("", "error") == "unreadable", "no file to error discloses unreadable")
	_check(GDLLMInstructions.agents_event("error", "error") == "", "a persisting error discloses once")
	_check(GDLLMInstructions.attached_key(md5_a) == md5_a, "content state stands for its own bytes")
	_check(GDLLMInstructions.attached_key("empty") == "" and GDLLMInstructions.attached_key("error") == "" and GDLLMInstructions.attached_key("") == "", "every no-block state stands for no bytes")


func _test_agents_notice_text() -> void:
	var attached := GDLLMInstructions.agents_notice_text("attached", "res://AGENTS.md", 1234, "")
	_check(attached.contains("res://AGENTS.md") and attached.contains("~309 tokens"), "attached notice names the file and its estimated token cost")
	var changed := GDLLMInstructions.agents_notice_text("changed", "res://AGENTS.md", 300, "")
	_check(changed.contains("~75 tokens") and changed.contains("changed"), "changed notice names the new token cost")
	var unreadable := GDLLMInstructions.agents_notice_text("unreadable", "res://AGENTS.md", 0, "File not found")
	_check(unreadable.contains("File not found") and unreadable.contains("no project instructions attached"), "unreadable notice names the cause and the consequence")
	_check(GDLLMInstructions.agents_notice_text("empty", "res://agents.md", 0, "").contains("res://agents.md"), "empty notice names the file")
	_check(GDLLMInstructions.agents_notice_text("removed", "", 0, "").contains("no longer"), "removed notice states the consequence")


func _test_agents_block() -> void:
	var block := GDLLMInstructions.agents_block("res://AGENTS.md", "Use tabs.\n")
	_check(block.contains("res://AGENTS.md") and block.contains("Use tabs."), "block carries the path and the text")
	_check(GDLLMInstructions.agents_block("res://AGENTS.md", "  \n") == "", "whitespace-only text composes no block")


func _test_format_tokens() -> void:
	_check(GDLLMInstructions.format_tokens(999) == "~250 tokens", "a small file renders as whole estimated tokens")
	_check(GDLLMInstructions.format_tokens(8000) == "~2.0k tokens", "a large file renders in k units")
	_check(GDLLMInstructions.format_tokens(1234) == "~309 tokens", "the estimate follows the plugin-wide chars/4 rule")


func _test_parse_skill() -> void:
	var full := "---\nname: Fancy Name\ndescription: \"Does fancy things.\"\nlicense: ignored\n---\n\n# Body heading\nBody text.\n"
	var skill: Dictionary = GDLLMInstructions.parse_skill(full, "fallback")
	_check(String(skill["name"]) == "Fancy Name", "frontmatter name wins")
	_check(String(skill["description"]) == "Does fancy things.", "frontmatter description wins, quotes stripped")
	_check(String(skill["body"]).begins_with("# Body heading"), "body excludes the frontmatter")
	var bare: Dictionary = GDLLMInstructions.parse_skill("# Tile painting rules\nUse the atlas.\n", "tile-painting")
	_check(String(bare["name"]) == "tile-painting", "no frontmatter falls back to the stem")
	_check(String(bare["description"]) == "Tile painting rules", "fallback description is the first body line, heading marks stripped")
	var long_line := "x".repeat(200)
	var truncated: Dictionary = GDLLMInstructions.parse_skill(long_line, "long")
	_check(String(truncated["description"]).length() <= GDLLMInstructions.SKILL_FALLBACK_DESCRIPTION_CHARS and String(truncated["description"]).ends_with("…"), "over-long fallback description truncates with an ellipsis")
	var unclosed := "---\nname: never closed\nstill body"
	var rule: Dictionary = GDLLMInstructions.parse_skill(unclosed, "rule")
	_check(String(rule["name"]) == "rule" and String(rule["body"]).begins_with("---"), "an unclosed opening --- is body, not frontmatter")
	_check(String(GDLLMInstructions.parse_skill("", "blank")["description"]) == "(no description)", "an empty body still gets a description placeholder")
	var crlf: Dictionary = GDLLMInstructions.parse_skill("---\r\nname: Crlf Skill\r\ndescription: Windows endings.\r\n---\r\nBody line.\r\n", "crlf")
	_check(String(crlf["name"]) == "Crlf Skill" and String(crlf["description"]) == "Windows endings.", "CRLF frontmatter parses — stripped lines shed the \\r")
	# The engine strips a UTF-8 BOM in get_file_as_string (probe-verified), which is what keeps a Windows-authored skill's frontmatter recognizable; pinned through a real file so an engine change surfaces here.
	var bom_path := FIXTURE_AGENTS.get_basename() + "_bom.md"
	var bom_file := FileAccess.open(bom_path, FileAccess.WRITE)
	bom_file.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	bom_file.store_string("---\nname: Bommed\n---\nBody.\n")
	bom_file.close()
	var bommed: Dictionary = GDLLMInstructions.parse_skill(FileAccess.get_file_as_string(bom_path), "bom")
	_check(String(bommed["name"]) == "Bommed", "a BOM-opened file still parses its frontmatter")
	DirAccess.remove_absolute(bom_path)


func _test_registration() -> void:
	var names := _search_names(GDLLMTools.search("use_skill", false, false))
	_check(names == ["use_skill"], "exact name search returns use_skill")
	_check(_search_names(GDLLMTools.search("skill", false, false)).has("use_skill"), "the word a model would ask in finds use_skill")
	var catalog := String(GDLLMTools.tool_search_schema(false, false)["function"]["description"])
	_check(catalog.contains("use_skill(name)"), "the catalog carries use_skill with its call shape")


func _test_use_skill_no_dir() -> void:
	_check(not DirAccess.dir_exists_absolute(SKILLS_ROOT), "precondition: the checkout has no res://skills of its own")
	var content := await _run("use_skill", {"name": "anything"})
	_check(content.begins_with("Error:") and content.contains("no res://skills directory"), "no skills dir refuses naming where to create one")
	_check(content.contains("SKILL.md"), "no-dir refusal spells out both file conventions")


func _write_skill_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(SKILLS_ROOT + "/alpha")
	DirAccess.make_dir_recursive_absolute(SKILLS_ROOT + "/beta")
	var file := FileAccess.open(SKILLS_ROOT + "/alpha/SKILL.md", FileAccess.WRITE)
	file.store_string("---\nname: Alpha Painter\ndescription: Paints alpha tiles.\n---\nAlways paint alpha tiles with the alpha brush.\n")
	file.close()
	file = FileAccess.open(SKILLS_ROOT + "/beta/SKILL.md", FileAccess.WRITE)
	file.store_string("# Beta dir guide\nThe directory convention wins.\n")
	file.close()
	file = FileAccess.open(SKILLS_ROOT + "/beta.md", FileAccess.WRITE)
	file.store_string("# Beta flat guide\nThe flat file loses the collision.\n")
	file.close()
	file = FileAccess.open(SKILLS_ROOT + "/notes.txt", FileAccess.WRITE)
	file.store_string("not a skill\n")
	file.close()


func _test_discovery() -> void:
	var skills: Array = GDLLMInstructions.discover_skills()
	_check(skills.size() == 2, "two skills discovered (the .txt ignored, the collision folded)")
	var names := PackedStringArray()
	for skill: Dictionary in skills:
		names.append(String(skill["name"]))
	_check(Array(names) == ["Alpha Painter", "beta"], "skills come back sorted by name")
	var beta: Dictionary = GDLLMInstructions.find_skill("beta", skills)
	_check(String(beta["path"]) == SKILLS_ROOT + "/beta/SKILL.md", "the directory convention wins a name collision")
	var signature := GDLLMInstructions.skills_signature()
	_check(signature.contains("alpha/SKILL.md") and signature.contains("beta.md"), "the signature names every skill file")
	var file := FileAccess.open(SKILLS_ROOT + "/gamma.md", FileAccess.WRITE)
	file.store_string("# Gamma\nBody.\n")
	file.close()
	_check(GDLLMInstructions.skills_signature() != signature, "adding a skill changes the signature")
	DirAccess.remove_absolute(SKILLS_ROOT + "/gamma.md")


func _test_conflicts() -> void:
	var conflicts: Array = []
	GDLLMInstructions.discover_skills(GDLLMInstructions.SKILLS_DIR, conflicts)
	_check(conflicts.size() == 1, "the fixture library holds exactly the beta collision")
	var caption := String(conflicts[0]) if not conflicts.is_empty() else ""
	_check(caption.contains("beta/SKILL.md") and caption.contains("beta.md"), "the collision caption names both files")
	_check(caption.contains("not listed") and caption.contains("Rename"), "the caption states the outcome and the fix")
	for stem in ["gamma_one", "gamma_two"]:
		var file := FileAccess.open("%s/%s.md" % [SKILLS_ROOT, stem], FileAccess.WRITE)
		file.store_string("---\nname: Gamma\n---\nBody.\n")
		file.close()
	conflicts = []
	var skills: Array = GDLLMInstructions.discover_skills(GDLLMInstructions.SKILLS_DIR, conflicts)
	_check(skills.size() == 4, "a flat-vs-flat name collision keeps both files listed")
	var flat := ""
	for entry in conflicts:
		if String(entry).contains("gamma_two.md"):
			flat = String(entry)
	_check(flat.contains("gamma_one.md") and flat.contains("stem"), "the flat collision caption names both files and the stem route")
	DirAccess.remove_absolute(SKILLS_ROOT + "/gamma_one.md")
	DirAccess.remove_absolute(SKILLS_ROOT + "/gamma_two.md")


func _test_skill_file_capitalization() -> void:
	DirAccess.make_dir_recursive_absolute(SKILLS_ROOT + "/delta")
	var file := FileAccess.open(SKILLS_ROOT + "/delta/skill.md", FileAccess.WRITE)
	file.store_string("---\nname: Delta\n---\nLowercase spelling works.\n")
	file.close()
	var conflicts: Array = []
	var skills: Array = GDLLMInstructions.discover_skills(GDLLMInstructions.SKILLS_DIR, conflicts)
	_check(not GDLLMInstructions.find_skill("Delta", skills).is_empty(), "a lowercase skill.md is discovered")
	_check(conflicts.size() == 1, "one readable spelling raises no capitalization conflict")
	file = FileAccess.open(SKILLS_ROOT + "/delta/SKILL.md", FileAccess.WRITE)
	file.store_string("---\nname: Delta\n---\nUppercase wins.\n")
	file.close()
	conflicts = []
	skills = GDLLMInstructions.discover_skills(GDLLMInstructions.SKILLS_DIR, conflicts)
	var delta := GDLLMInstructions.find_skill("Delta", skills)
	_check(String(delta.get("path", "")).ends_with("delta/SKILL.md"), "the exact SKILL.md spelling wins a capitalization conflict")
	_check(String(delta.get("body", "")).contains("Uppercase wins"), "the winning spelling's body is the one served")
	var cap := ""
	for entry in conflicts:
		if String(entry).contains("spellings of SKILL.md"):
			cap = String(entry)
	_check(cap.contains("delta") and cap.contains("skill.md") and cap.contains("SKILL.md"), "the capitalization caption names the winner and the ignored file")
	_check(GDLLMInstructions.skills_signature().contains("delta/skill.md"), "the losing spelling still signs, so deleting it reads as a change")
	DirAccess.remove_absolute(SKILLS_ROOT + "/delta/skill.md")
	DirAccess.remove_absolute(SKILLS_ROOT + "/delta/SKILL.md")
	DirAccess.remove_absolute(SKILLS_ROOT + "/delta")


func _test_roster() -> void:
	var roster := GDLLMInstructions.skills_block(GDLLMInstructions.discover_skills())
	_check(roster.contains("- Alpha Painter: Paints alpha tiles."), "roster lists a skill as one name-description line")
	_check(roster.contains("use_skill"), "roster names the tool that pulls a body")
	_check(not roster.contains("alpha brush"), "roster carries no skill bodies")
	_check(GDLLMInstructions.skills_block([]) == "", "no skills composes no block")


func _test_find_skill() -> void:
	var skills: Array = GDLLMInstructions.discover_skills()
	_check(String(GDLLMInstructions.find_skill("Alpha Painter", skills).get("name", "")) == "Alpha Painter", "exact name matches")
	_check(String(GDLLMInstructions.find_skill("alpha painter", skills).get("name", "")) == "Alpha Painter", "case-insensitive name matches")
	_check(String(GDLLMInstructions.find_skill("alpha", skills).get("name", "")) == "Alpha Painter", "the directory stem matches")
	_check(GDLLMInstructions.find_skill("delta", skills).is_empty(), "an unknown name matches nothing")


func _test_use_skill_happy() -> void:
	var ledger := GDLLMTools.SessionLedger.new()
	var content := await _run("use_skill", {"name": "Alpha Painter"}, ledger)
	_check(content.begins_with("Skill \"Alpha Painter\" (res://skills/alpha/SKILL.md)"), "result header names the skill and its file")
	_check(content.contains("Always paint alpha tiles"), "result carries the skill body")
	var skill_path := SKILLS_ROOT + "/alpha/SKILL.md"
	_check(ledger.seen_files.get(skill_path) == false, "the served body marks the file seen but not whole-verbatim — it excludes the frontmatter")
	var edit := await _run("edit_file", {"path": skill_path, "old_string": "alpha brush", "new_string": "beta brush"}, ledger, true)
	_check(edit.begins_with("Error:") and edit.contains("nothing was changed"), "use_skill alone does not ground an edit — the read-gate routes through a real read")
	var overwrite := await _run("write_file", {"path": skill_path, "content": "rebuilt without frontmatter"}, ledger, true)
	_check(overwrite.begins_with("Error:") and overwrite.contains("nothing was written"), "use_skill alone does not ground a wholesale overwrite — the frontmatter it never served would be lost")
	_check(FileAccess.get_file_as_string(skill_path).contains("name: Alpha Painter"), "the refused overwrite left the frontmatter on disk")
	var by_stem := await _run("use_skill", {"skill": "beta"})
	_check(by_stem.contains("The directory convention wins."), "the skill synonym key and stem lookup serve the body")


func _test_use_skill_unknown() -> void:
	var content := await _run("use_skill", {"name": "delta"})
	_check(content.begins_with("Error:") and content.contains("nothing was read"), "unknown name refuses and says what was withheld")
	_check(content.contains("Alpha Painter") and content.contains("beta"), "unknown-name refusal lists the real skill names")
	var missing := await _run("use_skill", {})
	_check(missing.begins_with("Error:") and missing.contains("\"name\""), "a nameless call points at the name argument")
	var misnamed := await _run("use_skill", {"tool": "alpha"})
	_check(misnamed.begins_with("Error: unrecognized argument"), "an unrecognized key is named rather than ignored")


func _test_use_skill_whole() -> void:
	var lines := PackedStringArray()
	for i in 500:
		lines.append("Line %03d of the very long skill body, padded for length." % i)
	var body := "\n".join(lines)
	var file := FileAccess.open(SKILLS_ROOT + "/long.md", FileAccess.WRITE)
	file.store_string("---\nname: Long Guide\n---\n" + body)
	file.close()
	var content := await _run("use_skill", {"name": "Long Guide"})
	_check(content.contains(body), "a long skill comes back whole — instructions are never split into parts")
	_check(not content.contains("part") and not content.contains("[Skill continues"), "a long result carries no windowing residue")
	var stray := await _run("use_skill", {"name": "Long Guide", "part": 2})
	_check(stray.contains(body), "a stray part key still serves the whole body — nothing is withheld")
	DirAccess.remove_absolute(SKILLS_ROOT + "/long.md")


func _test_use_skill_empty_body() -> void:
	var file := FileAccess.open(SKILLS_ROOT + "/hollow.md", FileAccess.WRITE)
	file.store_string("---\nname: Hollow\ndescription: All frontmatter, no body.\n---\n")
	file.close()
	var content := await _run("use_skill", {"name": "Hollow"})
	_check(content.contains("has no body text") and not content.contains(":\n\n"), "an all-frontmatter skill says it holds no instructions rather than serving nothing as work")
	DirAccess.remove_absolute(SKILLS_ROOT + "/hollow.md")


func _test_use_skill_empty_dir() -> void:
	DirAccess.make_dir_recursive_absolute(SKILLS_ROOT)
	var content := await _run("use_skill", {"name": "anything"})
	_check(content.begins_with("Error:") and content.contains("defines no skills"), "an empty skills dir refuses naming the conventions")
	DirAccess.remove_absolute(SKILLS_ROOT)


func _cleanup_skills() -> void:
	for path in [SKILLS_ROOT + "/alpha/SKILL.md", SKILLS_ROOT + "/beta/SKILL.md", SKILLS_ROOT + "/beta.md", SKILLS_ROOT + "/notes.txt"]:
		DirAccess.remove_absolute(path)
	for dir in [SKILLS_ROOT + "/alpha", SKILLS_ROOT + "/beta", SKILLS_ROOT]:
		DirAccess.remove_absolute(dir)


func _search_names(results: Array) -> Array:
	var names: Array = []
	for entry in results:
		names.append(String(entry["name"]))
	return names
