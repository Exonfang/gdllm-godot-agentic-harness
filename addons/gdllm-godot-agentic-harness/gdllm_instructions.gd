@tool
class_name GDLLMInstructions
extends RefCounted
## Project-authored context for the model, in two shapes: the instruction file that rides the system prompt whole (GDLLM.md, the harness-specific override, or the generic AGENTS.md), and the res://skills library that rides it as a name+description roster with full bodies pulled on demand through use_skill (see GDLLMTools).
## Every method is static and pure over the filesystem — the per-session caching, disclosure, and cache-boundary decisions live in GDLLMChatSession, which calls these at its send points.

## The project-instruction file names, one inner list per stem in priority order: any spelling of gdllm.md outranks any spelling of agents.md, so a harness-specific file can override the generic one. Within a stem the conventional spellings win before an alphabetical tie-break.
const AGENTS_PREFERRED := [["GDLLM.md", "gdllm.md"], ["AGENTS.md", "agents.md"]]

## Where skills live: res://skills/<name>/SKILL.md (directory convention, any capitalization of SKILL.md, the exact spelling winning) or res://skills/<name>.md (flat), top level only.
const SKILLS_DIR := "res://skills"

## Longest fallback description taken from a skill's first body line when its frontmatter declares none.
const SKILL_FALLBACK_DESCRIPTION_CHARS := 120


# --- AGENTS.md ---

## The project-instructions path that exists ("" when none does): GDLLM.md or AGENTS.md at the project root in any capitalization, gdllm.md outranking agents.md and the conventional spelling winning within a stem.
static func agents_path() -> String:
	var dir := DirAccess.open("res://")
	if dir == null:
		return ""
	var name := agents_pick(dir.get_files())
	return "res://" + name if name != "" else ""


## The winning name among `files` that spell a project-instruction stem in any capitalization ("" when none do): stems in AGENTS_PREFERRED order, and within a stem the conventional spellings first, then alphabetical so the pick stays deterministic.
static func agents_pick(files: PackedStringArray) -> String:
	for preferred: Array in AGENTS_PREFERRED:
		var stem := String(preferred[0]).to_lower()
		var found := PackedStringArray()
		for file in files:
			if file.to_lower() == stem:
				found.append(file)
		if found.is_empty():
			continue
		for name: String in preferred:
			if found.has(name):
				return name
		found.sort()
		return found[0]
	return ""


## Modified time of `path`, 0 for "" — the cheap per-send stat the session compares before re-reading.
static func agents_mtime(path: String) -> int:
	return int(FileAccess.get_modified_time(path)) if path != "" else 0


## Read the instructions at `path` into {"state", "text", "error"}. `state` is the one value the session compares, persists, and derives notices from: "" for no file, "empty", "error" (cause in `error`), or the md5 of path + content — the path folds in because the attached block names it, so even identical content under the other candidate name reads as the byte change it is and the state and the attached bytes can never disagree.
static func read_agents(path: String) -> Dictionary:
	if path == "":
		return {"state": "", "text": "", "error": ""}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"state": "error", "text": "", "error": error_string(FileAccess.get_open_error())}
	var text := file.get_as_text()
	if text.strip_edges() == "":
		return {"state": "empty", "text": "", "error": ""}
	return {"state": ("%s\n%s" % [path, text]).md5_text(), "text": text, "error": ""}


## The system-prompt block carrying the project instructions, or "" when nothing is attached.
static func agents_block(path: String, text: String) -> String:
	if text.strip_edges() == "":
		return ""
	return "## Project instructions (%s)\n\n%s" % [path, text.strip_edges()]


## The prompt bytes a state stands for — the md5 for attached content, "" for every no-block state — so an "empty" to "removed" transition never reads as a byte change while "attached" to "changed" always does.
static func attached_key(state: String) -> String:
	return "" if state in ["", "empty", "error"] else state


## The disclosure a state transition earns — "attached", "changed", "empty", "unreadable", "removed" — or "" when none is due. `old_state` is what was last disclosed (persisted on the session record), so a reload of an unchanged file announces nothing.
static func agents_event(old_state: String, new_state: String) -> String:
	if new_state == old_state:
		return ""
	if new_state == "":
		return "removed" if old_state != "" else ""
	if new_state == "empty":
		return "empty"
	if new_state == "error":
		return "unreadable"
	return "changed" if attached_key(old_state) != "" else "attached"


## The disclosure caption for one instructions-file event: the file (path, so the renderer can linkify it) and its estimated token cost, never its contents — the text is the user's own file, so path + cost is the honest altitude and the context inspector shows the exact bytes on request.
static func agents_notice_text(event: String, path: String, chars: int, error: String) -> String:
	match event:
		"attached":
			return "📋 %s attached (%s) — its project instructions now ride the system prompt." % [path, format_tokens(chars)]
		"changed":
			return "📋 %s changed (now %s) — the updated instructions ride the system prompt from this request on." % [path, format_tokens(chars)]
		"empty":
			return "📋 %s is empty — no project instructions attached." % path
		"unreadable":
			return "📋 %s exists but can't be read (%s) — no project instructions attached." % [path, error]
		"removed":
			return "📋 The project's instructions file is gone — its instructions no longer ride the system prompt."
	return ""


## `chars` as an estimated token figure for the disclosure captions — the same chars/4 rule the context meter uses (LLMClient.estimate_tokens), ~-prefixed because it is an estimate.
static func format_tokens(chars: int) -> String:
	var tokens := LLMClient.estimate_tokens(chars)
	if tokens < 1000:
		return "~%d tokens" % tokens
	return "~%.1fk tokens" % (tokens / 1000.0)


# --- Skills ---

## Every skill defined at `root`'s top level, sorted by name: [{"name", "description", "path", "body"}]. The directory convention wins a name collision with a flat file, and hidden entries never scan. Every name collision appends a caption to `conflicts` (see conflict_text), so the caller can surface what the roster silently resolved.
static func discover_skills(root: String = SKILLS_DIR, conflicts: Array = []) -> Array:
	var out: Array = []
	var first_by_name := {}
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for sub in dir.get_directories():
		var dir_path := root.path_join(sub)
		var candidates := skill_file_candidates(dir_path)
		if candidates.is_empty():
			continue
		var path := dir_path.path_join(candidates[0])
		for i in range(1, candidates.size()):
			conflicts.append("⚠️ %s holds %d spellings of SKILL.md — only %s is read; %s is ignored. Remove one to clear the conflict." % [dir_path, candidates.size(), candidates[0], candidates[i]])
		var skill := parse_skill(FileAccess.get_file_as_string(path), sub)
		skill["path"] = path
		var key := String(skill["name"]).to_lower()
		if first_by_name.has(key):
			conflicts.append(conflict_text(String(skill["name"]), String(first_by_name[key]), path, false))
		else:
			first_by_name[key] = path
		out.append(skill)
	for file in dir.get_files():
		if file.get_extension().to_lower() != "md":
			continue
		var path := root.path_join(file)
		var skill := parse_skill(FileAccess.get_file_as_string(path), file.get_basename())
		var key := String(skill["name"]).to_lower()
		if first_by_name.has(key):
			var kept := String(first_by_name[key])
			# The directory convention wins over a flat file; a flat-vs-flat collision keeps both, the loser reachable by stem.
			var dropped := kept.get_file() == "SKILL.md"
			conflicts.append(conflict_text(String(skill["name"]), kept, path, dropped))
			if dropped:
				continue
		else:
			first_by_name[key] = path
		skill["path"] = path
		out.append(skill)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["name"]) < String(b["name"]))
	return out


## Every file in `dir_path` spelling SKILL.md in any capitalization, winner first: the exact conventional name, then alphabetical so the pick stays deterministic.
static func skill_file_candidates(dir_path: String) -> PackedStringArray:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return PackedStringArray()
	var found := PackedStringArray()
	for file in dir.get_files():
		if file.to_lower() == "skill.md":
			found.append(file)
	found.sort()
	var exact := found.find("SKILL.md")
	if exact > 0:
		found.remove_at(exact)
		found.insert(0, "SKILL.md")
	return found


## The caption one skill-name collision earns: both files named, the outcome stated, and the fix pointed at (goal 3). `other_dropped` is true when `other` lost to the directory convention and is not listed at all.
static func conflict_text(name: String, kept: String, other: String, other_dropped: bool) -> String:
	if other_dropped:
		return "⚠️ Two skills share the name \"%s\": %s and %s. The directory convention wins, so %s is not listed. Rename one to list both." % [name, kept, other, other]
	return "⚠️ Two skills share the name \"%s\": %s and %s. Only %s answers to that name; %s stays reachable by its own file stem. Rename one to resolve the conflict." % [name, kept, other, kept, other]


## Parse one skill file: an optional leading "---" frontmatter block read for `name:` and `description:` (other keys tolerated and ignored), the dir/file stem and first body line as fallbacks. Returns {"name", "description", "body"}; the body never includes the frontmatter.
static func parse_skill(text: String, fallback_name: String) -> Dictionary:
	var body := text
	var meta := {}
	var lines := text.split("\n")
	if not lines.is_empty() and lines[0].strip_edges() == "---":
		for i in range(1, lines.size()):
			var line := lines[i].strip_edges()
			if line == "---":
				body = "\n".join(lines.slice(i + 1))
				break
			var colon := line.find(":")
			if colon > 0:
				meta[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		# An opening "---" that never closes is a horizontal rule, not frontmatter — keep the whole text and forget the keys.
		if body == text:
			meta = {}
	var name := String(meta.get("name", "")).strip_edges()
	if name == "":
		name = fallback_name
	var description := String(meta.get("description", "")).strip_edges()
	if description == "":
		description = _fallback_description(body)
	return {"name": name, "description": description, "body": body.strip_edges()}


## Cheap change detector for the skills roster: every skill file's path and mtime joined, so a per-send compare re-scans only when something under res://skills actually changed. File mtimes rather than the directory's, because descriptions live in file contents.
static func skills_signature(root: String = SKILLS_DIR) -> String:
	var dir := DirAccess.open(root)
	if dir == null:
		return ""
	var parts := PackedStringArray()
	for sub in dir.get_directories():
		var dir_path := root.path_join(sub)
		# Every capitalization variant signs, not just the winner, so deleting a loser (which changes the winner) still reads as a change.
		for file in skill_file_candidates(dir_path):
			var path := dir_path.path_join(file)
			parts.append("%s|%d" % [path, FileAccess.get_modified_time(path)])
	for file in dir.get_files():
		if file.get_extension().to_lower() == "md":
			var path := root.path_join(file)
			parts.append("%s|%d" % [path, FileAccess.get_modified_time(path)])
	return "\n".join(parts)


## The roster block the system prompt carries: one "name: description" line per skill plus the use_skill route — names and one-liners only, the narrow-context trade that keeps bodies on disk until a task asks for one. "" when no skills exist.
static func skills_block(skills: Array) -> String:
	if skills.is_empty():
		return ""
	var lines := PackedStringArray()
	for skill: Dictionary in skills:
		lines.append("- %s: %s" % [skill["name"], skill["description"]])
	return "## Skills\n\nThis project defines skills — its own instructions for specific kinds of task, stored under res://skills. When a skill's description matches the task at hand, read its full instructions with the use_skill tool before doing that work.\n%s" % "\n".join(lines)


## The discovered skill answering to `name` — exact, else case-insensitive, else by its file or directory stem — or {} when none does.
static func find_skill(name: String, skills: Array) -> Dictionary:
	for skill: Dictionary in skills:
		if String(skill["name"]) == name:
			return skill
	var lower := name.to_lower()
	for skill: Dictionary in skills:
		if String(skill["name"]).to_lower() == lower:
			return skill
	for skill: Dictionary in skills:
		var path := String(skill["path"])
		if path.get_file().get_basename().to_lower() == lower or path.get_base_dir().get_file().to_lower() == lower:
			return skill
	return {}


## The description a skill without one gets: its first non-empty body line, heading marks stripped, truncated to SKILL_FALLBACK_DESCRIPTION_CHARS.
static func _fallback_description(body: String) -> String:
	for line in body.split("\n"):
		var stripped := line.strip_edges().lstrip("# ").strip_edges()
		if stripped == "":
			continue
		if stripped.length() > SKILL_FALLBACK_DESCRIPTION_CHARS:
			return stripped.substr(0, SKILL_FALLBACK_DESCRIPTION_CHARS - 1).strip_edges() + "…"
		return stripped
	return "(no description)"
