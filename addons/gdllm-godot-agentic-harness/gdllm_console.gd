@tool
class_name GDLLMConsole extends RefCounted
## Engine-truth access to the editor's Output console and the debugger's Errors tab, read from the editor's own panels — the same widgets the user is looking at, and the only place a running game's prints and errors land in this process (the game is a separate process whose output arrives over the debugger, never through any API this plugin could hook). Panels are located by class fingerprint rather than stored node paths, so a dock rearrangement can't silently point these at the wrong widget, and a panel that can't be found refuses honestly instead of answering with an empty console. Every method is static — this is a namespace, not an instance.

const DEFAULT_OUTPUT_LINES := 40
const DEFAULT_ERROR_LIMIT := 10
## Longest single relayed line; the remainder is elided with a count so one runaway line can't flood the context.
const MAX_LINE_CHARS := 400
## Most detail rows (engine error, source line, stack frames) relayed per error entry before the remainder collapses to a count.
const MAX_ERROR_DETAIL_ROWS := 12
## The panel's message-type filter buttons in 4.7's MessageType order, by the EditorSettings keys their states persist under: a type toggled off is dropped from the panel's text entirely, so a read that didn't disclose it would pass a silently gutted console off as the whole log — probe-measured on a real setup whose console hid every error this way.
const OUTPUT_FILTER_SETTINGS := [[1, "Errors"], [3, "Warnings"], [0, "Standard Messages"], [4, "Editor Messages"], [2, "Rich Standard Messages"]]


## The newest lines of the Output console, filtered when `filter` is non-empty; `lines` <= 0 means the default. The panel itself is the source, so what it currently shows is what is readable — a cleared console reads as empty.
static func read_output(lines: int, filter: String) -> String:
	if not Engine.is_editor_hint():
		return "Error: the Output console exists only inside the editor UI, and this session is running headless — there is no panel to read."
	var label := _output_label()
	if label == null:
		return "Error: the Output panel's log could not be located in this editor build — its internal layout may have changed. Tell the user the read_output tool needs updating for this editor version."
	return format_output(label.get_parsed_text(), lines, filter) + _output_hidden_note()


## The newest entries of the debugger's Errors tab across every session, filtered when `filter` is non-empty; `limit` <= 0 means the default.
static func read_errors(limit: int, filter: String) -> String:
	if not Engine.is_editor_hint():
		return "Error: the debugger's error history exists only inside the editor UI, and this session is running headless — there is no panel to read."
	var sessions := _error_trees()
	if sessions.is_empty():
		return "Error: the debugger's Errors list could not be located in this editor build — its internal layout may have changed. Tell the user the read_errors tool needs updating for this editor version."
	var blocks: Array = []
	for session in sessions:
		var body := format_errors(error_entries(session["tree"]), limit, filter)
		if sessions.size() > 1:
			body = "%s:\n%s" % [session["session"], body]
		blocks.append(body)
	return "\n\n".join(PackedStringArray(blocks))


## Editor-only baseline for a run capture: the Output panel's current trimmed line count and last line, from which output_delta_since measures what a run printed; {} when the panel can't be located (or headless, where none exists).
static func output_baseline() -> Dictionary:
	if not Engine.is_editor_hint():
		return {}
	var label := _output_label()
	if label == null:
		return {}
	var lines := output_lines(label.get_parsed_text())
	return {"count": lines.size(), "last": String(lines[lines.size() - 1]) if not lines.is_empty() else ""}


## Editor-only: the Output lines added since `baseline`, as lines_delta's shape plus "missing" — true when the panel (or the baseline itself) could not be read, which a caller must disclose rather than passing off as "printed nothing".
static func output_delta_since(baseline: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint() or baseline.is_empty():
		return {"lines": [], "reset": false, "missing": true}
	var label := _output_label()
	if label == null:
		return {"lines": [], "reset": false, "missing": true}
	var delta := lines_delta(int(baseline["count"]), String(baseline["last"]), output_lines(label.get_parsed_text()))
	delta["missing"] = false
	return delta


## Editor-only errors baseline: entry count per debugger session name; {} when the debugger's trees can't be located.
static func errors_baseline() -> Dictionary:
	if not Engine.is_editor_hint():
		return {}
	var counts := {}
	for session in _error_trees():
		counts[String(session["session"])] = error_entries(session["tree"]).size()
	return counts


## Editor-only: per-session error entries added since `baseline`, each entries_delta's shape plus "session"; a session unseen at baseline counts from zero, and [] means the trees could not be read at all.
static func errors_delta_since(baseline: Dictionary) -> Array:
	var out: Array = []
	if not Engine.is_editor_hint():
		return out
	for session in _error_trees():
		var delta := entries_delta(error_entries(session["tree"]), int(baseline.get(String(session["session"]), 0)))
		delta["session"] = String(session["session"])
		out.append(delta)
	return out


## Public face of the view-controls rider for the run tools' capture reports, which disclose a filtered panel the same way read_output does; "" headless, where no panel exists to have controls.
static func output_hidden_note() -> String:
	return _output_hidden_note() if Engine.is_editor_hint() else ""


## Public face of _format_entry for the run tools' capture reports, which render error entries outside this class.
static func format_error_entry(entry: Dictionary) -> String:
	return _format_entry(entry)


## Public face of the class-fingerprint walker for the other panel-reading namespaces (GDLLMPerf), so the one editor-widget location strategy lives in one place.
static func find_by_class(root: Node, cls: String) -> Array[Node]:
	return _find_by_class(root, cls)


## Pure formatter behind read_output, separated so the headless tests can drive it: tail selection, filtering, clamping, and the honest empty and no-match messages.
static func format_output(text: String, lines: int, filter: String) -> String:
	var all: Array = output_lines(text)
	if all.is_empty():
		return "The Output console is currently empty — nothing has been printed since it was last cleared."
	# An explicit ask is honored uncapped — the whole panel if asked — matching the search_files contract; only the DEFAULT stays small.
	var cap := lines if lines > 0 else DEFAULT_OUTPUT_LINES
	var pool: Array = all
	if filter != "":
		var needle := filter.to_lower()
		pool = all.filter(func(line: Variant) -> bool: return String(line).to_lower().contains(needle))
		if pool.is_empty():
			return "Output console: %d lines; none contain \"%s\"." % [all.size(), filter]
	var shown: Array = pool.slice(maxi(0, pool.size() - cap))
	var body: Array = []
	for line in shown:
		body.append(_clip_line(String(line)))
	return "%s\n%s" % [_output_header(all.size(), pool.size(), shown.size(), filter), "\n".join(PackedStringArray(body))]


## Pure formatter behind read_errors, separated so the headless tests can drive it with synthetic entries.
static func format_errors(entries: Array, limit: int, filter: String) -> String:
	if entries.is_empty():
		return "The debugger's error history is empty: no errors or warnings have been recorded from running the project (nothing has run, or the user cleared it). Errors raised inside the editor itself land in the Output console instead — read_output shows those."
	# Same contract as format_output: an explicit ask is honored uncapped.
	var cap := limit if limit > 0 else DEFAULT_ERROR_LIMIT
	var errors := 0
	for entry: Dictionary in entries:
		if String(entry["kind"]) == "error":
			errors += 1
	var pool: Array = entries
	if filter != "":
		var needle := filter.to_lower()
		pool = entries.filter(func(entry: Variant) -> bool: return _entry_text(entry).to_lower().contains(needle))
		if pool.is_empty():
			return "Debugger error history: %d entries (%d errors, %d warnings); none contain \"%s\"." % [entries.size(), errors, entries.size() - errors, filter]
	var shown: Array = pool.slice(maxi(0, pool.size() - cap))
	var body: Array = []
	for entry: Dictionary in shown:
		body.append(_format_entry(entry))
	return "%s\n%s" % [_errors_header(entries.size(), errors, pool.size(), shown.size(), filter), "\n".join(PackedStringArray(body))]


## One dictionary per recorded error — kind from the engine's own _is_warning/_is_error item marks, the two visible columns (time, message), and each child row (engine error, source line, stack frames) flattened to one line — so the formatter and the tests share a shape that isn't a live Tree.
static func error_entries(tree: Tree) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root := tree.get_root()
	if root == null:
		return out
	var item := root.get_first_child()
	while item != null:
		var detail: Array = []
		var child := item.get_first_child()
		while child != null:
			detail.append(("%s %s" % [child.get_text(0), child.get_text(1)]).strip_edges())
			child = child.get_next()
		out.append({
			"kind": "warning" if item.has_meta("_is_warning") else "error",
			"time": item.get_text(0),
			"title": item.get_text(1),
			"detail": detail,
		})
		item = item.get_next()
	return out


## Pure: split into lines with the trailing blanks trimmed — the one line shape format_output and the run-capture deltas share, so their counts can never disagree.
static func output_lines(text: String) -> Array:
	var all: Array = Array(text.split("\n"))
	while not all.is_empty() and String(all[all.size() - 1]).strip_edges() == "":
		all.remove_at(all.size() - 1)
	return all


## Pure delta behind output_delta_since: the lines past a baseline of `count` lines ending in `last`, as {"lines", "reset"}. Fewer lines than the baseline means the panel was cleared since (reset — everything present is newer than the baseline), and a changed boundary line is included in the delta, because the panel's collapse-duplicates option grows a repeat counter on an existing line instead of appending.
static func lines_delta(count: int, last: String, lines: Array) -> Dictionary:
	if lines.size() < count:
		return {"lines": lines.duplicate(), "reset": true}
	var start := count
	if count > 0 and String(lines[count - 1]) != last:
		start = count - 1
	return {"lines": lines.slice(start), "reset": false}


## Pure delta behind errors_delta_since: the entries past `baseline`, as {"entries", "reset"} — reset (everything returned) when the list shrank under the baseline, i.e. was cleared since.
static func entries_delta(entries: Array, baseline: int) -> Dictionary:
	if entries.size() < baseline:
		return {"entries": entries.duplicate(), "reset": true}
	return {"entries": entries.slice(baseline), "reset": false}


## Pure: the newest `cap` of `lines`, each clipped like format_output's, joined plus how many older lines were left out — the bounded tail the run tools' reports relay instead of a whole capture.
static func tail_lines(lines: Array, cap: int) -> Dictionary:
	var shown: Array = lines.slice(maxi(0, lines.size() - cap))
	var body: Array = []
	for line in shown:
		body.append(_clip_line(String(line)))
	return {"text": "\n".join(PackedStringArray(body)), "omitted": lines.size() - shown.size()}


static func _output_header(total: int, matched: int, shown: int, filter: String) -> String:
	if filter == "":
		if shown == total:
			return "Output console (%d lines):" % total
		return "Output console: %d lines total, showing the newest %d (raise \"lines\", or pass \"filter\" to reach older ones by content):" % [total, shown]
	if shown == matched:
		return "Output console: %d lines total; %d contain \"%s\":" % [total, matched, filter]
	return "Output console: %d lines total; %d contain \"%s\", showing the newest %d of those (raise \"lines\", or narrow the filter):" % [total, matched, filter, shown]


static func _errors_header(total: int, errors: int, matched: int, shown: int, filter: String) -> String:
	var tally := "%d entries (%d errors, %d warnings)" % [total, errors, total - errors]
	if filter == "":
		if shown == total:
			return "Debugger error history, %s, oldest first:" % tally
		return "Debugger error history, %s, showing the newest %d (oldest of those first — raise \"limit\", or pass \"filter\" to reach older entries by content):" % [tally, shown]
	if shown == matched:
		return "Debugger error history, %s; %d contain \"%s\":" % [tally, matched, filter]
	return "Debugger error history, %s; %d contain \"%s\", showing the newest %d of those (raise \"limit\", or narrow the filter):" % [tally, matched, filter, shown]


static func _format_entry(entry: Dictionary) -> String:
	var rows: Array = ["[%s] %s: %s" % [entry["time"], String(entry["kind"]).to_upper(), _clip_line(String(entry["title"]))]]
	var detail: Array = entry["detail"]
	for i in mini(detail.size(), MAX_ERROR_DETAIL_ROWS):
		rows.append("  %s" % _clip_line(String(detail[i])))
	if detail.size() > MAX_ERROR_DETAIL_ROWS:
		rows.append("  (+%d more detail rows)" % (detail.size() - MAX_ERROR_DETAIL_ROWS))
	return "\n".join(PackedStringArray(rows))


static func _entry_text(entry_v: Variant) -> String:
	var entry: Dictionary = entry_v
	return "%s %s %s %s" % [entry["time"], entry["kind"], entry["title"], " ".join(PackedStringArray(entry["detail"]))]


static func _clip_line(line: String) -> String:
	if line.length() <= MAX_LINE_CHARS:
		return line
	return "%s… (+%d more chars)" % [line.left(MAX_LINE_CHARS), line.length() - MAX_LINE_CHARS]


## Every node of engine class `cls` under `root`, matched by get_class because the editor's panel classes are internal C++ types no script can name; internal children are walked too, since the editor builds its panels with them.
static func _find_by_class(root: Node, cls: String) -> Array[Node]:
	var found: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children(true):
			stack.append(child)
		if node.get_class() == cls:
			found.append(node)
	return found


## The honest rider about the panel's own view controls: any message-type filter toggled off and any text in the panel's search box also limit what this read can see, and an "empty" console under an active filter would otherwise be a silent lie.
static func _output_hidden_note() -> String:
	var hidden: Array = []
	var settings := EditorInterface.get_editor_settings()
	for entry: Array in OUTPUT_FILTER_SETTINGS:
		var key := "_editor_log_filter_%d" % int(entry[0])
		if settings.has_setting(key) and not bool(settings.get_setting(key)):
			hidden.append(String(entry[1]))
	var parts: Array = []
	if not hidden.is_empty():
		parts.append("the %s filter button(s) are toggled off, so those message types are missing from the panel and from this read" % " and ".join(PackedStringArray(hidden)))
	var search := _output_search_text()
	if search != "":
		parts.append("its search box is set to \"%s\", so only lines matching that are readable" % search)
	if parts.is_empty():
		return ""
	return "\n\nNote: the Output panel's own view controls are limiting what it shows — %s. If you need what's hidden, ask the user to reset those controls in the Output panel." % "; ".join(PackedStringArray(parts))


## The panel's search box text, scraped from its one LineEdit; the box is session-local so no setting records it.
static func _output_search_text() -> String:
	for panel in _find_by_class(EditorInterface.get_base_control(), "EditorLog"):
		for box in _find_by_class(panel, "LineEdit"):
			return (box as LineEdit).text.strip_edges()
	return ""


## The Output panel's log widget: the RichTextLabel inside the editor's EditorLog panel (exactly one exists).
static func _output_label() -> RichTextLabel:
	for panel in _find_by_class(EditorInterface.get_base_control(), "EditorLog"):
		for label in _find_by_class(panel, "RichTextLabel"):
			return label as RichTextLabel
	return null


## The Errors tab's Tree per debugger session, as {session, tree}. The tab is matched by shape — a plain VBoxContainer directly under the session's top TabContainer carrying a direct two-column Tree child — because its title is localized and the tree unnamed; on 4.7 that fingerprint is unique among the debugger's tabs.
static func _error_trees() -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for debugger in _find_by_class(EditorInterface.get_base_control(), "EditorDebuggerNode"):
		for session in _find_by_class(debugger, "ScriptEditorDebugger"):
			var tree := _session_error_tree(session)
			if tree != null:
				found.append({"session": String(session.name), "tree": tree})
	return found


static func _session_error_tree(session: Node) -> Tree:
	for tabs in session.get_children(true):
		if not tabs is TabContainer:
			continue
		for tab in tabs.get_children(true):
			if tab.get_class() != "VBoxContainer":
				continue
			for child in tab.get_children(true):
				if child is Tree and child.columns == 2:
					return child as Tree
	return null
