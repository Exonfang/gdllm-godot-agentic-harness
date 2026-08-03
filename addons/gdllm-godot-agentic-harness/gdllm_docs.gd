@tool
class_name GDLLMDocs extends RefCounted
## Engine documentation prose for the describe_docs tool, read from the editor's own documentation cache — the per-user, per-version file (editor_doc_cache-<major>.<minor>.res) the editor itself maintains and rebuilds on version changes, so the text is the running build's Help-panel prose by construction.
## The cache's `classes` meta holds one Dictionary per class, covering everything the Help panel shows — including non-ClassDB pages like @GDScript, @GlobalScope, and the Variant math types — which is why this is the prose source rather than --doctool (whose dump carries empty descriptions: it merges prose from disk, never from the binary).
## Like the other describe_* tools this exists for reality grounding: prose is pulled per class or per member on demand, never dumped wholesale into context.

# The prose, search-hit, snippet, enum, and suggestion caps this file renders under are user-configurable — see GDLLMTunables' gdllm/tool_output section.
## Scoring weights: a query word in the entry's own name beats one in the class name, which beats prose hits, so exact terminology surfaces above passing mentions.
const SCORE_NAME := 4
const SCORE_CLASS := 2
const SCORE_BRIEF := 2
const SCORE_PROSE := 1
const SCORE_EXACT_NAME := 8

## The doc-entry sections that hold named members, with the label a hit renders under.
const MEMBER_SECTIONS := {
	"methods": "Method",
	"properties": "Property",
	"signals": "Signal",
	"constants": "Constant",
	"annotations": "Annotation",
	"constructors": "Constructor",
	"operators": "Operator",
	"theme_properties": "Theme property",
}

## Parsed doc entries keyed by lower-case class name, plus the canonical names for suggestions. Loaded once per editor session on first use; the docs can't change while this build runs.
static var _docs: Dictionary = {}
static var _names: PackedStringArray = PackedStringArray()
static var _loading := false ## a first load is in flight on a worker; concurrent callers wait on it instead of starting their own


## The prose lookup behind describe_docs: the class's own description, or one member's, as plain text for the tool result. Errors (cache unavailable, unknown class or member) come back as readable content with suggestions so the model can recover.
static func describe(requested_class: String, requested_member: String, full := false) -> String:
	var err: String = await _ensure_loaded()
	if err != "":
		return err
	var cls := requested_class.strip_edges()
	var member := requested_member.strip_edges()
	# "Class.member" in either slot stands in for both arguments, mirroring describe_member.
	if member == "" and cls.contains(".") and not _docs.has(cls.to_lower()):
		var dot := cls.rfind(".")
		member = cls.substr(dot + 1)
		cls = cls.substr(0, dot)
	elif member.contains("."):
		var mdot := member.rfind(".")
		if _docs.has(member.substr(0, mdot).to_lower()):
			cls = member.substr(0, mdot)
			member = member.substr(mdot + 1)
	if cls == "":
		return "Error: no class was provided. Pass the class or doc page to read in \"class\", e.g. \"Sprite2D\" or \"@GDScript\"."
	var entry: Dictionary = _docs.get(cls.to_lower(), {})
	# A prose request ("PanelContainer class") usually embeds the page name as one word; the first token that resolves wins.
	if entry.is_empty() and cls.contains(" "):
		for token in cls.split(" ", false):
			if _docs.has(token.to_lower()):
				cls = token
				entry = _docs[cls.to_lower()]
				break
	if entry.is_empty():
		return _unknown_class_message(cls)
	if member == "":
		return _capped_prose(_class_prose(entry), full)
	return _capped_prose(_member_prose(entry, member), full)


## The full-text lookup behind search_docs: every class page and member whose name or prose carries ALL the query's content words, ranked and returned one line each — the discovery step for when the model knows the concept ("make text wrap") but not the term (autowrap_mode), with describe_docs as the follow-up.
static func search(query: String) -> String:
	var err: String = await _ensure_loaded()
	if err != "":
		return err
	var words := _content_words(query)
	if words.is_empty():
		return "Error: no search words were given. Pass one or more words naming the concept, e.g. \"text wrap\" or \"pause game\"."
	var best: Dictionary = {}
	for key in _docs:
		_collect_search_hits(_docs[key], words, best)
	if best.is_empty():
		return "No documentation entries contain all of: %s. Every word must appear in a single entry's name or prose — try fewer, simpler, or different words (\"wrap\" rather than \"word wrapping\")." % ", ".join(words)
	var hits := best.values()
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"] if a["score"] != b["score"] else String(a["label"]) < String(b["label"]))
	var shown: Array = hits if hits.size() <= GDLLMTunables.geti(GDLLMTunables.DOCS_SEARCH_MAX_HITS) else hits.slice(0, GDLLMTunables.geti(GDLLMTunables.DOCS_SEARCH_MAX_HITS))
	var note := "" if hits.size() <= GDLLMTunables.geti(GDLLMTunables.DOCS_SEARCH_MAX_HITS) else " (top %d of %d — add words to narrow)" % [GDLLMTunables.geti(GDLLMTunables.DOCS_SEARCH_MAX_HITS), hits.size()]
	var lines: Array = ["Documentation entries matching \"%s\" — %d hit(s)%s. Read one in full with describe_docs:" % [" ".join(words), hits.size(), note]]
	for hit in shown:
		var snippet := String(hit["snippet"])
		lines.append("- %s (%s)%s" % [hit["label"], hit["kind"], ": " + snippet if snippet != "" else ""])
	return "\n".join(lines)


## Load the cache if it isn't loaded yet; "" on success, else the same readable error describe() would have returned. Public so describe_class's fallback ladder can consult the docs and, when the cache is the thing that failed, say so rather than reporting the name as nonexistent.
static func ensure_ready() -> String:
	return await _ensure_loaded()


## Whether the cache holds a page under this name (case-insensitive); false until a successful ensure_ready().
static func has_page(name: String) -> bool:
	return _docs.has(name.strip_edges().to_lower())


## Every doc page name, for the near-miss suggestions a class lookup that missed everywhere offers; empty until a successful load.
static func page_names() -> PackedStringArray:
	return _names


## The STRUCTURAL view describe_class falls back to when ClassDB and the project's class_name registry both miss — the Variant types (Array, Callable, Vector2), the built-in scopes (@GDScript, @GlobalScope), and @GlobalScope's enums by their bare name (Key, Error, MouseButton), none of which ClassDB has ever held.
## The doc cache is generated from the same binary ClassDB is, so its signatures are this build's truth; what it adds is the types ClassDB has no registry for. Returns {"content"}, {"error"} when the cache itself is unavailable, or {} when the name genuinely matches nothing here.
static func structure(requested: String, filter: String, kinds: Dictionary = {}) -> Dictionary:
	var err: String = await _ensure_loaded()
	if err != "":
		return {"error": err}
	var cls := requested.strip_edges()
	var entry: Dictionary = _docs.get(cls.to_lower(), {})
	if not entry.is_empty():
		return {"content": _page_structure(entry, filter.to_lower(), kinds)}
	var global_enum := _global_enum_name(cls)
	if global_enum != "":
		return {"content": _global_enum_structure(global_enum, filter.to_lower(), kinds)}
	return {}


## One doc page's members rendered in describe_class's own section shape, so a Variant type reads exactly like an engine class.
static func _page_structure(entry: Dictionary, filter: String, kinds: Dictionary) -> String:
	var cls := String(entry["name"])
	var kind := "a built-in scope, not a class" if cls.begins_with("@") else "a Variant TYPE, not an Object class"
	var head: Array = []
	head.append("Godot structural reference for %s — read from this build's documentation cache, which is generated from the same binary ClassDB is. %s is %s, so ClassDB (describe_class's usual source) has no entry for it; this is the same API, from the registry that does hold it." % [cls, cls, kind])
	head.append("")
	if String(entry.get("inherits", "")) != "":
		head.append("Inherits: %s" % entry["inherits"])
		head.append("")
	if filter != "":
		head.append("Filtered to members whose name contains \"%s\"." % filter)
	var kinds_note := GDLLMTools._class_kinds_note(kinds)
	if kinds_note != "":
		head.append(kinds_note)
	head.append("For what any of these DO — the prose — call describe_docs with class \"%s\", adding `member` for one of them." % cls)

	var pairs: Array = []
	for section in ["constructors", "methods", "operators"]:
		pairs.append([String(MEMBER_SECTIONS[section]) + "s", _callable_lines(entry, section, filter)])
	pairs.append(["Properties", _property_lines(entry, filter)])
	var grouped := _grouped_constants(entry, filter)
	pairs.append(["Enums", grouped["enums"]])
	pairs.append(["Constants", grouped["constants"]])

	var any_member := false
	for pair in pairs:
		if (kinds.is_empty() or kinds.has(String(pair[0]))) and not (pair[1] as Array).is_empty():
			any_member = true
	if filter != "" and not any_member:
		head.append("")
		head.append("No members whose name contains \"%s\" were found on %s. Try a different substring, or omit filter to see the whole API." % [filter, cls])
		return "\n".join(head)
	return "\n".join(head) + "\n\n" + "\n\n".join(GDLLMTools._class_sections_for(pairs, kinds))


## Signature lines for one callable section (constructors, methods, operators), filtered by name substring.
static func _callable_lines(entry: Dictionary, section: String, filter: String) -> Array:
	var out: Array = []
	if not (entry.get(section) is Array):
		return out
	for item in entry[section]:
		if not (item is Dictionary):
			continue
		if filter != "" and not String(item.get("name", "")).to_lower().contains(filter):
			continue
		out.append(_callable_signature(item))
	return out


## "name: Type (default: x)" lines for a page's properties — on @GlobalScope these are the engine singletons, which live nowhere else.
static func _property_lines(entry: Dictionary, filter: String) -> Array:
	var out: Array = []
	if not (entry.get("properties") is Array):
		return out
	for item in entry["properties"]:
		if not (item is Dictionary):
			continue
		var pname := String(item.get("name", ""))
		if filter != "" and not pname.to_lower().contains(filter):
			continue
		var line := "%s: %s" % [pname, item.get("type", "Variant")]
		if item.has("default_value"):
			line += " (default: %s)" % item["default_value"]
		out.append(line)
	return out


## A page's constants split the way describe_class splits them — one line per enum, the rest as plain constants — since the cache stores both in one flat list keyed by an `enumeration` field. The filter matches an enum's own name or any of its members, so filtering by a constant still surfaces its enum.
static func _grouped_constants(entry: Dictionary, filter: String) -> Dictionary:
	var order: Array[String] = []
	var by_enum: Dictionary = {}
	var plain: Array = []
	if not (entry.get("constants") is Array):
		return {"enums": [], "constants": plain}
	for item in entry["constants"]:
		if not (item is Dictionary):
			continue
		var cname := String(item.get("name", ""))
		var enumeration := String(item.get("enumeration", ""))
		if enumeration == "":
			if filter == "" or cname.to_lower().contains(filter):
				plain.append("%s = %s" % [cname, item.get("value", "")])
			continue
		if not by_enum.has(enumeration):
			by_enum[enumeration] = []
			order.append(enumeration)
		(by_enum[enumeration] as Array).append(item)
	var enums: Array = []
	for enumeration in order:
		var line := _enum_structure_line(enumeration, by_enum[enumeration], filter)
		if line != "":
			enums.append(line)
	return {"enums": enums, "constants": plain}


## One enum as "Name { A = 0, B = 1 }", capped so @GlobalScope's 193-value Key doesn't arrive as a single unbounded line; the cap names `filter` as the lever, and a filter that matched only some members lists just those.
static func _enum_structure_line(enumeration: String, items: Array, filter: String) -> String:
	var name_hit := filter != "" and _enum_short_name(enumeration).contains(filter)
	var shown: Array = []
	for item in items:
		if filter == "" or name_hit or String(item.get("name", "")).to_lower().contains(filter):
			shown.append(item)
	if shown.is_empty():
		return ""
	var note := ""
	if shown.size() > GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP):
		note = ", … (%d of %d — pass a `filter` substring for the rest)" % [GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP), shown.size()]
		shown = shown.slice(0, GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP))
	var pairs: Array[String] = []
	for item in shown:
		pairs.append("%s = %s" % [item.get("name", ""), item.get("value", "")])
	return "%s { %s%s }" % [enumeration, ", ".join(pairs), note]


## The canonical name of a @GlobalScope enum matching `requested` — its bare name ("Key") or its qualified one ("Variant.Type") — or "". GDScript's un-namespaced enums live only here, so a model asking describe_class for one has nowhere else to land.
static func _global_enum_name(requested: String) -> String:
	var lowered := requested.strip_edges().to_lower()
	if lowered == "":
		return ""
	var entry: Dictionary = _docs.get("@globalscope", {})
	if not (entry.get("constants") is Array):
		return ""
	for item in entry["constants"]:
		if not (item is Dictionary):
			continue
		var enumeration := String(item.get("enumeration", ""))
		if enumeration != "" and (enumeration.to_lower() == lowered or _enum_short_name(enumeration) == lowered):
			return enumeration
	return ""


## One @GlobalScope enum's values as a Constants section, so describe_class's cap and `filter` bound it exactly as they bound an engine class's — 193 KEY_* values would otherwise arrive whole.
static func _global_enum_structure(enumeration: String, filter: String, kinds: Dictionary) -> String:
	var entry: Dictionary = _docs.get("@globalscope", {})
	var values: Array = []
	for item in entry.get("constants", []):
		if not (item is Dictionary) or String(item.get("enumeration", "")) != enumeration:
			continue
		var cname := String(item.get("name", ""))
		if filter != "" and not cname.to_lower().contains(filter):
			continue
		values.append("%s = %s" % [cname, item.get("value", "")])
	var head: Array = []
	head.append("Godot structural reference for the global enum %s — declared in @GlobalScope and read from this build's documentation cache. It is an ENUM, not a class, so ClassDB (describe_class's usual source) has no entry for it. Its values are used unqualified in GDScript (KEY_A, ERR_FILE_NOT_FOUND); the type itself is written %s." % [enumeration, enumeration])
	if filter != "":
		head.append("Filtered to values whose name contains \"%s\"." % filter)
	head.append("For what a value MEANS, call describe_docs with class \"@GlobalScope\" and the value as `member`.")
	# An enum is all constants, so `kind` can only ever select that one section here — and asking for any other must say so rather than return an empty report.
	return "\n".join(head) + "\n\n" + "\n\n".join(GDLLMTools._class_sections_for([["Constants", values]], kinds))


## Filler words a conversational query carries ("how do I make text wrap") are dropped before matching, since requiring them would empty the result; if nothing survives the filter, the original words stand.
static func _content_words(query: String) -> PackedStringArray:
	const STOPWORDS := ["how", "do", "does", "i", "a", "an", "the", "to", "in", "on", "of", "is", "it", "my", "me", "you", "can", "what", "when", "with", "make", "use"]
	var words := query.strip_edges().to_lower().split(" ", false)
	var kept := PackedStringArray()
	for word in words:
		if not STOPWORDS.has(word):
			kept.append(word)
	return kept if not kept.is_empty() else words


## Score one class page and each of its members against the query, folding results into `best` keyed by label so same-name overloads (constructors, operators) collapse to their best-scoring block.
static func _collect_search_hits(entry: Dictionary, words: PackedStringArray, best: Dictionary) -> void:
	var cls := String(entry["name"])
	var brief := String(entry.get("brief_description", ""))
	var class_desc := String(entry.get("description", ""))
	var class_score := _search_score(words, cls, "", brief, class_desc)
	if class_score > 0:
		_record_hit(best, cls, "class", class_score, _search_snippet(words, brief, class_desc))
	for section in MEMBER_SECTIONS:
		if not (entry.get(section) is Array):
			continue
		for item in entry[section]:
			if not (item is Dictionary):
				continue
			var mname := String(item.get("name", ""))
			var mdesc := String(item.get("description", ""))
			var score := _search_score(words, mname, cls, "", mdesc)
			if score > 0:
				_record_hit(best, "%s.%s" % [cls, mname], String(MEMBER_SECTIONS[section]).to_lower(), score, _search_snippet(words, "", mdesc))


static func _record_hit(best: Dictionary, label: String, kind: String, score: int, snippet: String) -> void:
	if best.has(label) and int(best[label]["score"]) >= score:
		return
	best[label] = {"label": label, "kind": kind, "score": score, "snippet": snippet}


## An entry's relevance: 0 unless EVERY word appears somewhere in it, else weighted per-word hits — its own name over its class's name over prose — plus a bonus when a single word IS the name, so exact terminology tops the list.
static func _search_score(words: PackedStringArray, name: String, cls: String, brief: String, desc: String) -> int:
	var total := 0
	for word in words:
		var word_score := 0
		if name.findn(word) != -1:
			word_score += SCORE_NAME
		if cls != "" and cls.findn(word) != -1:
			word_score += SCORE_CLASS
		if brief != "" and brief.findn(word) != -1:
			word_score += SCORE_BRIEF
		if desc != "" and desc.findn(word) != -1:
			word_score += SCORE_PROSE
		if word_score == 0:
			return 0
		total += word_score
	if words.size() == 1 and name.to_lower().trim_prefix("@") == String(words[0]).trim_prefix("@"):
		total += SCORE_EXACT_NAME
	return total


## The one-line context shown with a hit: the brief description when the entry has one, else a window around the first matched word in the prose, flattened and clipped with ellipses.
static func _search_snippet(words: PackedStringArray, brief: String, desc: String) -> String:
	var source := brief if brief.strip_edges() != "" else desc
	if source.strip_edges() == "":
		return ""
	var pos := -1
	for word in words:
		pos = source.findn(word)
		if pos != -1:
			break
	var start := maxi(0, pos - 40)
	var window := _flatten_prose(source.substr(start, GDLLMTunables.geti(GDLLMTunables.DOCS_SNIPPET_CHARS)))
	if start > 0:
		window = "…" + window
	if start + GDLLMTunables.geti(GDLLMTunables.DOCS_SNIPPET_CHARS) < source.length():
		window += "…"
	return window


## Prose collapsed to one plain line for a snippet: doc markup's newlines and tabs become spaces and runs of spaces collapse.
static func _flatten_prose(text: String) -> String:
	var flat := text.replace("\n", " ").replace("\t", " ").strip_edges()
	while flat.contains("  "):
		flat = flat.replace("  ", " ")
	return flat


## Load and index the doc cache on first use. Returns "" on success or an honest, model-readable error: a missing file is transient (the editor rebuilds the cache shortly after startup) so nothing is cached and a later call retries. The multi-megabyte load and its indexing run on a worker thread in-editor (GDLLMTools.run_on_worker), so the session's first docs call doesn't hitch the editor; a concurrent first caller waits on the in-flight load rather than starting a second.
static func _ensure_loaded() -> String:
	while _loading:
		await Engine.get_main_loop().process_frame
	if not _docs.is_empty():
		return ""
	var path := _cache_path()
	if not FileAccess.file_exists(path):
		return "Error: the editor's documentation cache (%s) doesn't exist yet — the editor rebuilds it shortly after startup. %s If it keeps failing, tell the user their editor's docs cache is missing." % [path, GDLLMTools.TRANSIENT_RETRY_INVITATION]
	_loading = true
	var built: Dictionary = await GDLLMTools.run_on_worker(func() -> Dictionary: return _load_cache(path))
	_loading = false
	if built.is_empty():
		return _format_error(path)
	_docs = built["docs"]
	_names = built["names"]
	return ""


## The pure load-and-index behind _ensure_loaded, shaped to run on a worker thread: returns {docs, names}, or {} when the cache is unreadable. Touches no statics.
static func _load_cache(path: String) -> Dictionary:
	# CACHE_MODE_IGNORE keeps the multi-megabyte resource out of the resource cache; we copy what we need and drop it.
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res == null or not res.has_meta("classes"):
		return {}
	var docs: Dictionary = {}
	var names := PackedStringArray()
	for entry in res.get_meta("classes"):
		if entry is Dictionary and entry.has("name"):
			var n := String(entry["name"])
			docs[n.to_lower()] = entry
			names.append(n)
	if docs.is_empty():
		return {}
	return {"docs": docs, "names": names}


static func _format_error(path: String) -> String:
	_docs.clear()
	_names.clear()
	return "Error: the editor's documentation cache (%s) couldn't be read — its internal format may have changed in this Godot version. Documentation prose is unavailable, but describe_class and describe_member still give the structural API." % path


## The doc cache's path for the running build: the editor names it by major.minor in its per-user cache directory, which is exactly the version-swapping behavior we want. EditorPaths resolves self-contained installs; the OS fallback exists only for headless test runs where no editor is up.
static func _cache_path() -> String:
	var dir := ""
	if Engine.is_editor_hint():
		dir = EditorInterface.get_editor_paths().get_cache_dir()
	else:
		dir = OS.get_cache_dir().path_join("godot")
	var v := Engine.get_version_info()
	return dir.path_join("editor_doc_cache-%d.%d.res" % [v.major, v.minor])


## The class-level page: brief and full description plus tutorial links — meaning, not structure; member lists stay with describe_class.
static func _class_prose(d: Dictionary) -> String:
	var cls := String(d["name"])
	var lines: Array = ["Godot documentation for %s — the engine's own prose from this editor build's documentation cache (not recalled from memory)." % cls, ""]
	if String(d.get("inherits", "")) != "":
		lines.append("Inherits: %s" % d["inherits"])
	_append_status(d, lines)
	var brief := _clean_prose(String(d.get("brief_description", "")))
	var desc := _clean_prose(String(d.get("description", "")))
	if brief == "" and desc == "":
		lines.append("The engine docs carry no prose for %s." % cls)
	if brief != "":
		lines.append("")
		lines.append(brief)
	if desc != "" and desc != brief:
		lines.append("")
		lines.append(desc)
	var tutorials: Array = []
	for t in d.get("tutorials", []):
		if t is Dictionary:
			tutorials.append("- %s: %s" % [t.get("title", "link"), _substitute_docs_url(String(t.get("link", "")))])
	if not tutorials.is_empty():
		lines.append("")
		lines.append("Tutorials:")
		lines.append_array(tutorials)
	return "\n".join(lines)


## One member's prose, searched by name across every section and up the inheritance chain; an enum name with no direct hit comes back as its grouped values.
static func _member_prose(entry: Dictionary, member: String) -> String:
	var cls := String(entry["name"])
	var hits := _find_member_hits(entry, member)
	if hits.is_empty():
		return _unknown_member_message(entry, member)
	var lines: Array = ["Godot documentation for %s.%s — the engine's own prose from this editor build's documentation cache (not recalled from memory)." % [cls, member], ""]
	lines.append("\n\n".join(hits))
	return "\n".join(lines)


## Every block matching `member` along the inheritance chain. Same-name overloads (constructors, operators) all land; a name that only matches as an enum's type falls back to the grouped enum block.
static func _find_member_hits(entry: Dictionary, member: String) -> Array:
	# Leading "@" is stripped from both sides so "export" finds the "@export" annotation and vice versa.
	var target := member.to_lower().trim_prefix("@")
	var hits: Array = []
	var enum_hits: Array = []
	var d := entry
	while not d.is_empty():
		var declaring := String(d.get("name", ""))
		for section in MEMBER_SECTIONS:
			if not (d.get(section) is Array):
				continue
			for item in d[section]:
				if not (item is Dictionary):
					continue
				if String(item.get("name", "")).to_lower().trim_prefix("@") == target:
					hits.append(_member_block(declaring, section, item))
				elif section == "constants" and _enum_short_name(String(item.get("enumeration", ""))) == target:
					enum_hits.append({"declaring": declaring, "enumeration": item["enumeration"], "item": item})
		d = _docs.get(String(d.get("inherits", "")).to_lower(), {})
	if hits.is_empty() and not enum_hits.is_empty():
		hits.append(_enum_block(enum_hits))
	return hits


## An enum's unqualified lower-case name ("Node.InternalMode" -> "internalmode"), or "" when there is no enum.
static func _enum_short_name(enumeration: String) -> String:
	if enumeration == "":
		return ""
	return enumeration.get_slice(".", enumeration.get_slice_count(".") - 1).to_lower()


## One member hit: a compact signature-style header naming its kind and declaring class, any deprecation notice, then the prose.
static func _member_block(declaring: String, section: String, item: Dictionary) -> String:
	var head := ""
	match section:
		"properties", "theme_properties":
			head = "%s: %s" % [item.get("name", ""), item.get("type", "")]
			if item.has("default_value"):
				head += " (default: %s)" % item["default_value"]
		"constants":
			head = "%s = %s" % [item.get("name", ""), item.get("value", "")]
			if String(item.get("enumeration", "")) != "":
				head += " (enum %s)" % item["enumeration"]
		_:
			head = _callable_signature(item)
	var lines: Array = ["%s (declared in %s): %s" % [MEMBER_SECTIONS[section], declaring, head]]
	_append_status(item, lines)
	var prose := _clean_prose(String(item.get("description", "")))
	lines.append(prose if prose != "" else "(The engine docs carry no prose for this member.)")
	return "\n".join(lines)


## All of one enum's values gathered into a single block, for when the model asks about the enum rather than one constant. Capped at the same count as the structural line — @GlobalScope's 193-value Key would otherwise arrive as one prose flood — with the remainder counted and the per-value lever named.
static func _enum_block(enum_hits: Array) -> String:
	var first: Dictionary = enum_hits[0]
	var lines: Array = ["Enum %s (declared in %s):" % [first["enumeration"], first["declaring"]]]
	for hit in enum_hits.slice(0, GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP)):
		var item: Dictionary = hit["item"]
		var prose := _clean_prose(String(item.get("description", "")))
		lines.append("")
		lines.append("%s = %s" % [item.get("name", ""), item.get("value", "")])
		if prose != "":
			lines.append(prose)
	if enum_hits.size() > GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP):
		var next_name := String((enum_hits[GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP)]["item"] as Dictionary).get("name", ""))
		lines.append("")
		lines.append("(%d of %d values shown — pass one value's own name as `member` (e.g. \"%s\") for its prose.)" % [GDLLMTunables.geti(GDLLMTunables.DOCS_ENUM_VALUES_CAP), enum_hits.size(), next_name])
	return "\n".join(lines)


## "name(arg: Type = default, …) -> Return [qualifiers]" from a method/signal/annotation/constructor/operator item; sections without a return type or qualifiers simply omit them.
static func _callable_signature(item: Dictionary) -> String:
	var parts: Array = []
	for a in item.get("arguments", []):
		if not (a is Dictionary):
			continue
		var p := "%s: %s" % [a.get("name", ""), a.get("type", "Variant")]
		if a.has("default_value"):
			p += " = %s" % a["default_value"]
		parts.append(p)
	var sig := "%s(%s)" % [item.get("name", ""), ", ".join(PackedStringArray(parts))]
	if String(item.get("return_type", "")) != "":
		sig += " -> %s" % item["return_type"]
	if String(item.get("qualifiers", "")) != "":
		sig += " [%s]" % item["qualifiers"]
	return sig


## Surface a doc entry's deprecated/experimental marker; the key's value is the explanation when the docs give one.
static func _append_status(d: Dictionary, lines: Array) -> void:
	for key in ["deprecated", "experimental"]:
		if not d.has(key):
			continue
		var msg := _clean_prose(String(d[key]))
		lines.append("%s%s" % [key.capitalize(), "." if msg == "" else ": %s" % msg])


## Doc prose arrives with the XML source's leading-tab indentation baked in; strip the common indent (preserving [codeblock] internals' relative indent) and resolve $DOCS_URL — the size cap lives in _capped_prose, at the whole-result level. The Godot doc markup itself ([code], [member x], …) is left verbatim — it's ground truth.
static func _clean_prose(raw: String) -> String:
	var lines := raw.split("\n")
	var min_tabs := -1
	for line in lines:
		if line.strip_edges() == "":
			continue
		var t := 0
		while t < line.length() and line[t] == "\t":
			t += 1
		min_tabs = t if min_tabs == -1 else mini(min_tabs, t)
	if min_tabs > 0:
		for i in lines.size():
			lines[i] = lines[i].substr(min_tabs)
	var text := "\n".join(lines).strip_edges()
	return _substitute_docs_url(text)


## The whole-result prose cap, applied once at describe()'s exit instead of per block (per-block caps could still stack past any budget): past GDLLMTunables.DOCS_PROSE_MAX_CHARS the text is cut with a note naming full: true — the model-callable lever the old note lacked (it pointed only at the Help panel, a surface the model cannot open) — alongside the Help-panel pointer that still serves the user.
static func _capped_prose(text: String, full: bool) -> String:
	if full or text.length() <= GDLLMTunables.geti(GDLLMTunables.DOCS_PROSE_MAX_CHARS):
		return text
	return text.substr(0, GDLLMTunables.geti(GDLLMTunables.DOCS_PROSE_MAX_CHARS)) + "\n[... %d more characters — re-run with full: true for the whole text. The user can also read it in the editor's Help panel.]" % (text.length() - GDLLMTunables.geti(GDLLMTunables.DOCS_PROSE_MAX_CHARS))


## Doc links use a $DOCS_URL placeholder; point it at this build's minor-version manual.
static func _substitute_docs_url(text: String) -> String:
	var v := Engine.get_version_info()
	return text.replace("$DOCS_URL", "https://docs.godotengine.org/en/%d.%d" % [v.major, v.minor])


## Error text for a doc page that doesn't resolve, with near-miss suggestions; also says what the docs cover, since project scripts have no engine-doc page.
static func _unknown_class_message(requested: String) -> String:
	var lowered := requested.to_lower()
	var suggestions: Array[String] = []
	for n in _names:
		if String(n).to_lower().contains(lowered):
			suggestions.append(String(n))
	var msg := "Error: the engine docs have no page named \"%s\"." % requested
	if suggestions.is_empty():
		return msg + " Docs exist only for engine classes and built-in pages (e.g. \"@GDScript\", \"@GlobalScope\"), not for this project's own scripts — for one of those call describe_class, which reads the script's real API, and read_file for the rest. Names are matched case-insensitively but must otherwise be exact."
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return msg + " Did you mean: %s%s?" % [", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]


## Error text for a member with no doc block, with near-miss member names gathered along the inheritance chain — names containing the request or contained by it — so a misremembered name can be corrected.
static func _unknown_member_message(entry: Dictionary, member: String) -> String:
	var cls := String(entry["name"])
	var target := member.to_lower().trim_prefix("@")
	var suggestions: Array[String] = []
	var d := entry
	while not d.is_empty():
		for section in MEMBER_SECTIONS:
			if not (d.get(section) is Array):
				continue
			for item in d[section]:
				if not (item is Dictionary):
					continue
				var iname := String(item.get("name", ""))
				var lowered := iname.to_lower().trim_prefix("@")
				if lowered != "" and (lowered.contains(target) or target.contains(lowered)) and not suggestions.has(iname):
					suggestions.append(iname)
		d = _docs.get(String(d.get("inherits", "")).to_lower(), {})
	var msg := "Error: the docs for %s (or its ancestors) have no member named \"%s\"." % [cls, member]
	if suggestions.is_empty():
		return msg + " Call describe_class to browse what %s actually has." % cls
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return msg + " Did you mean: %s%s?" % [", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]
