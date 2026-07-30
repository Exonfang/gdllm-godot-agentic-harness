@tool
class_name GDLLMLinks
## Turns the project files the model NAMES in its prose into clickable links that open them in the editor.
## Measured across 864 wild sessions: 26% of assistant replies name a project file (5,808 mentions, 666 distinct files), while ZERO user messages ever asked to be taken somewhere — so the navigation the transcripts actually want is the user following a reference the model already wrote, not a tool the model calls.
## That is why this is a rendering feature and not a tool: a tool would cost a catalog line on every request forever (goal 1) and would steal the editor's focus unasked, where a link costs the model's context nothing and moves only when the user clicks.
## Resolution deliberately borrows read_file's rule — a bare name resolves only when it is UNIQUE in the project — so a link lands exactly where the same name would have led the model, and an ambiguous or unknown name renders as plain text rather than a link that lies.

## The meta prefix every generated [url] carries, so a real http:// link in the model's Markdown is never mistaken for one of ours (see open).
const META_PREFIX := "gdllm-open:"

## File extensions a prose reference may name, lower-case and without the dot.
## Deliberately a fixed list rather than "any extension": a bare-name pattern that accepted anything would linkify "e.g." and version numbers, and every entry here is something the editor can actually open.
const LINKABLE_EXTENSIONS := ["gd", "tscn", "scn", "tres", "res", "gdshader", "gdshaderinc", "import", "md"]

## Directory names skipped when indexing the project — the editor cache and VCS metadata hold no file worth linking to, and .godot alone is large enough to dominate the walk.
const SKIPPED_DIRS := [".godot", ".git", ".import"]

## file name (lower-case) → every res:// path carrying that name, built lazily by _ensure_index and dropped by invalidate.
## Cached because _convert_markdown re-runs on every render — a log search re-renders every label — and resolving a bare name means walking the project.
static var _name_index: Dictionary = {}

## Whether _name_index reflects the project as it currently stands; false forces the next resolve to rebuild it.
static var _index_ready := false


## Drop the cached file index so the next resolve rebuilds it — wired to the editor's filesystem_changed, since a file added or deleted since the last build would otherwise link wrongly or not at all.
static func invalidate() -> void:
	_name_index = {}
	_index_ready = false


## The res:// path a prose reference names, or "" when nothing in the project answers to it.
## An explicit res:// path is taken as-is when it exists; a bare name resolves only when exactly one file carries it, which is read_file's own rule (see GDLLMTools._resolve_file_path) — a name shared by several files is left unlinked rather than silently pointing at one of them.
static func resolve(reference: String) -> String:
	var ref := reference.strip_edges()
	if ref == "":
		return ""
	if ref.begins_with("res://"):
		return ref if FileAccess.file_exists(ref) else ""
	if ref.contains("/"):
		var direct := "res://" + ref.trim_prefix("./").trim_prefix("/")
		return direct if FileAccess.file_exists(direct) else ""
	_ensure_index()
	var matches: PackedStringArray = _name_index.get(ref.to_lower(), PackedStringArray())
	return matches[0] if matches.size() == 1 else ""


## Wrap every resolvable file reference in `bbcode`'s text runs in a [url] carrying its resolved path, leaving the visible text exactly as the model wrote it.
## Tags are stepped over whole (the walk highlight_bbcode uses) so a reference is never matched into markup, and a run already inside a [url] is skipped so a real Markdown link is never nested inside ours.
## Runs INSIDE [code] are deliberately linkified: 92% of the res:// mentions measured in the wild sit in backticks, so skipping code spans would skip almost the whole feature.
static func linkify(bbcode: String) -> String:
	var out := ""
	var pos := 0
	var url_depth := 0
	while pos < bbcode.length():
		if bbcode[pos] == "[":
			var close := bbcode.find("]", pos)
			if close == -1:
				out += bbcode.substr(pos) if url_depth > 0 else _link_run(bbcode.substr(pos))
				break
			var tag := bbcode.substr(pos, close - pos + 1)
			if tag.begins_with("[url"):
				url_depth += 1
			elif tag == "[/url]":
				url_depth = maxi(url_depth - 1, 0)
			out += tag
			pos = close + 1
		else:
			var next_tag := bbcode.find("[", pos)
			if next_tag == -1:
				next_tag = bbcode.length()
			var run := bbcode.substr(pos, next_tag - pos)
			out += run if url_depth > 0 else _link_run(run)
			pos = next_tag
	return out


## Open what a clicked link's `meta` points at, returning whether it was one of ours — anything else (a real http:// link in the model's Markdown) is left for the caller to handle.
static func open(meta: String) -> bool:
	if not meta.begins_with(META_PREFIX):
		return false
	if not Engine.is_editor_hint():
		return true
	var payload := meta.substr(META_PREFIX.length())
	var line := 0
	var hash_at := payload.rfind("#")
	if hash_at > 0:
		line = payload.substr(hash_at + 1).to_int()
		payload = payload.substr(0, hash_at)
	if not FileAccess.file_exists(payload):
		return true
	open_in_editor(payload, line)
	return true


## Route an existing project file to the editor surface that can actually show it — scene tab, script editor (at 1-based `line` when > 0), shader editor, Inspector, or a FileSystem-dock reveal, which is the only honest answer for a .import or a .md — returning a phrase naming where it landed.
## Shared by the link click above and the open_for_user tool (GDLLMTools), so a user's click and a model's hand-off land in exactly the same place.
static func open_in_editor(path: String, line: int = 0) -> String:
	var ext := path.get_extension().to_lower()
	if ext in ["tscn", "scn"]:
		EditorInterface.open_scene_from_path(path)
		return "opened as the active scene tab"
	# The exists check keeps a file no loader handles (a .md, a .import) from printing a load error into the user's Output console on its way to the dock reveal.
	var resource: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if resource is Script:
		# edit_script's line is 1-based with 0 meaning keep position — probe-measured on 4.7: a line - 1 conversion (borrowed from the breakpoint jump, corrected there too) landed the caret one line above the target.
		EditorInterface.edit_script(resource, maxi(line, 0))
		return "opened in the script editor" + (" at line %d" % line if line > 0 else "")
	if resource != null:
		# edit_resource is the editor's own "open this in whatever plugin handles it", so it covers more than the .tres/.res this used to gate on.
		# Probe-measured on 4.7: a .gdshader loads as a Shader and a .gdshaderinc as a ShaderInclude, and edit_resource opens EITHER in the Shader Editor — a TextShaderEditor appears and is_object_edited turns true. Gating on the extension sent both to the FileSystem dock instead, which is what "linking doesn't work for shaders" looked like.
		# No line is carried: the shader editor takes none through any public call, and TextShaderEditor is not a registered class, so a shader opens at the top.
		EditorInterface.edit_resource(resource)
		return "opened in the shader editor" if resource is Shader or resource is ShaderInclude else "opened in the Inspector"
	# Only files with no loader at all reach here — a .md, a .import — where revealing the file in the dock is the most this can honestly do.
	EditorInterface.select_file(path)
	return "revealed in the FileSystem dock (no editor surface opens this file type; the user can reach it from there)"


## Linkify one tag-free run of text, leaving it untouched when it names nothing the project holds.
static func _link_run(run: String) -> String:
	if not run.contains("."):
		return run
	var regex := _reference_regex()
	var out := ""
	var pos := 0
	for m: RegExMatch in regex.search_all(run):
		var ref := m.get_string("ref")
		var target := resolve(ref)
		if target == "":
			continue
		var line := m.get_string("line").to_int()
		var meta := META_PREFIX + target + ("#%d" % line if line > 0 else "")
		out += run.substr(pos, m.get_start() - pos)
		out += "[url=%s]%s[/url]" % [meta, m.get_string()]
		pos = m.get_end()
	return run if pos == 0 else out + run.substr(pos)


## Build _name_index once per filesystem generation.
static func _ensure_index() -> void:
	if _index_ready:
		return
	_index_ready = true
	_name_index = {}
	_index_dir("res://")


## Depth-first walk adding every file under `dir_path` to _name_index, skipping the caches in SKIPPED_DIRS and any other hidden entry.
static func _index_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry in SKIPPED_DIRS:
				_index_dir(full)
		elif entry.get_extension().to_lower() in LINKABLE_EXTENSIONS:
			var key := entry.to_lower()
			var paths: PackedStringArray = _name_index.get(key, PackedStringArray())
			paths.append(full)
			_name_index[key] = paths
		entry = dir.get_next()
	dir.list_dir_end()


## The reference pattern: a res:// path or a bare file name ending in a linkable extension, with an optional ":123" or " line 123" suffix folded into the match so the whole thing becomes one link.
## The extensions are sorted LONGEST FIRST and closed with \b because alternation is leftmost-first: with "gd" ahead of "gdshader", "player.gdshader" would match "player.gd" and leave "shader" behind as text.
## Built fresh rather than cached in a static, because a RegEx compiled once and shared is not worth the reset hazard for a pattern this small.
static func _reference_regex() -> RegEx:
	var sorted := LINKABLE_EXTENSIONS.duplicate()
	sorted.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	var extensions := "|".join(sorted)
	var regex := RegEx.new()
	regex.compile("(?<ref>res://[\\w/\\-.]+\\.(?:%s)|[\\w\\-]+\\.(?:%s))\\b(?:(?::|\\s+line\\s+)(?<line>\\d{1,6}))?" % [extensions, extensions])
	return regex
