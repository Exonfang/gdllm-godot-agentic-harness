@tool
class_name GDLLMEditorState extends RefCounted
## The running editor's own view of the user's focus — what is selected on each editor surface, and the undo histories naming their recent actions — behind the read_editor_selection and read_undo_history tools (see GDLLMTools).
## Gathering is split from formatting so the headless suites can drive the composers with fixture state: only the gather_* half touches EditorInterface, and every caller gates that half behind Engine.is_editor_hint().
## The undo side is READ-ONLY by contract — nothing here (or anywhere in the addon) calls undo() or redo(); a revert is the user's to make.
## Every method is static — this is a namespace, not an instance.

## The most entries one list in the selection report prints before collapsing to a counted remainder, matching GDLLMTools' universal suggestion-list cap.
const MAX_LIST_ENTRIES := 12


## Snapshot of what the user has focused across the editor's surfaces, as the plain data format_selection renders; editor-only.
static func gather_selection() -> Dictionary:
	var state := {
		"active_scene": "", "open_scenes": [], "selected_nodes": [],
		"script_path": "", "script_line": 0,
		"inspector": "", "fs_paths": [], "fs_current": "",
	}
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		state["active_scene"] = root.scene_file_path if root.scene_file_path != "" else "an unsaved scene (root \"%s\")" % root.name
	for path in EditorInterface.get_open_scenes():
		state["open_scenes"].append(String(path))
	for node in EditorInterface.get_selection().get_selected_nodes():
		state["selected_nodes"].append(_node_label(node, root))
	var script_editor := EditorInterface.get_script_editor()
	var current: Script = script_editor.get_current_script() if script_editor != null else null
	if current != null:
		state["script_path"] = current.resource_path
		var base := script_editor.get_current_editor()
		if base != null:
			var code := base.get_base_editor() as TextEdit
			if code != null:
				state["script_line"] = code.get_caret_line() + 1
	state["inspector"] = _inspected_label(EditorInterface.get_inspector().get_edited_object(), root)
	for path in EditorInterface.get_selected_paths():
		state["fs_paths"].append(String(path))
	state["fs_current"] = EditorInterface.get_current_path()
	return state


## Render gather_selection's snapshot as the compact report read_editor_selection returns: one line per editor surface, an empty surface stated in place because the absence is itself the answer, every list capped with a counted remainder.
static func format_selection(state: Dictionary) -> String:
	var lines: Array[String] = []
	var active := String(state.get("active_scene", ""))
	var others: Array[String] = []
	for path in state.get("open_scenes", []):
		# An unsaved tab lists as "" — skipping it beats rendering a nameless entry, and the active-scene line already names the unsaved one that matters.
		if String(path) != active and String(path) != "":
			others.append(String(path).get_file())
	var scene_line := "Active scene: %s" % (active if active != "" else "none open")
	if not others.is_empty():
		scene_line += "; other open tabs: %s" % _capped_list(others, MAX_LIST_ENTRIES)
	lines.append(scene_line + ".")
	var nodes: Array = state.get("selected_nodes", [])
	if nodes.is_empty():
		lines.append("Selected nodes: none.")
	else:
		lines.append("Selected nodes (%d): %s." % [nodes.size(), _capped_list(nodes, MAX_LIST_ENTRIES)])
	var script_path := String(state.get("script_path", ""))
	if script_path == "":
		lines.append("Script editor: no script open.")
	else:
		var line_no := int(state.get("script_line", 0))
		lines.append("Script editor: %s%s." % [script_path, ", cursor at line %d" % line_no if line_no > 0 else ""])
	var inspected := String(state.get("inspector", ""))
	lines.append("Inspector: %s." % (inspected if inspected != "" else "nothing"))
	lines.append(_filesystem_line(state))
	return "\n".join(lines)


## Snapshot of the editor's undo histories — the active scene's and the global one — as the dicts format_undo renders; editor-only.
## Other open scenes' histories are unreachable (only the active root is exposed to deduce an id from), so their count rides along for format_undo to disclose; no scene open is its own entry, because a silently absent block would read as "scenes have no history".
static func gather_undo() -> Array:
	var histories: Array = []
	var manager := EditorInterface.get_editor_undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		var scene_label := root.scene_file_path if root.scene_file_path != "" else "unsaved scene \"%s\"" % root.name
		var id := manager.get_object_history_id(root)
		var entry := _history_state("Scene history (%s)" % scene_label, manager.get_history_undo_redo(id))
		entry["other_scenes"] = maxi(EditorInterface.get_open_scenes().size() - 1, 0)
		histories.append(entry)
	else:
		histories.append({"label": "Scene history", "no_scene": true})
	histories.append(_history_state("Global history (project settings and other non-scene edits)", manager.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)))
	return histories


## Render gather_undo's snapshots: per history the newest `window` action names, newest first, actions the user undid marked, truncation counted with the window lever named. Pure so the suites drive it with fixture state.
static func format_undo(histories: Array, window: int) -> String:
	var blocks: Array[String] = []
	for history: Dictionary in histories:
		blocks.append(_format_history(history, window))
	return "\n\n".join(blocks)


## One selected node as "path (Type)" relative to the edited scene root — the script's class_name when it has one, because that is the name the project's own code speaks.
static func _node_label(node: Node, root: Node) -> String:
	var type := node.get_class()
	var script: Script = node.get_script()
	if script != null and String(script.get_global_name()) != "":
		type = String(script.get_global_name())
	var in_scene := root != null and (node == root or root.is_ancestor_of(node))
	var path := String(root.get_path_to(node)) if in_scene else String(node.name)
	return "%s (%s)" % [path, type]


## The Inspector's object as one line — the class plus the name or path that identifies it, never a property dump.
static func _inspected_label(obj: Object, root: Node) -> String:
	if obj == null:
		return ""
	if obj is Node:
		return "node %s" % _node_label(obj as Node, root)
	if obj is Resource:
		var res := obj as Resource
		var where := res.resource_path if res.resource_path != "" else "an unsaved resource"
		return "%s (%s)" % [where, res.get_class()]
	return obj.get_class()


## The FileSystem dock's line: the selected paths, or the path being browsed when nothing is.
static func _filesystem_line(state: Dictionary) -> String:
	var fs: Array = state.get("fs_paths", [])
	var current := String(state.get("fs_current", ""))
	if fs.is_empty():
		return "FileSystem dock: nothing selected%s." % (" (browsing %s)" % current if current != "" else "")
	if fs.size() == 1:
		return "FileSystem dock: %s selected." % String(fs[0])
	return "FileSystem dock: %d selected — %s." % [fs.size(), _capped_list(fs, MAX_LIST_ENTRIES)]


## Comma-join capped at `cap` entries with a counted remainder — the shared list shape of the selection report.
static func _capped_list(entries: Array, cap: int) -> String:
	var shown := PackedStringArray()
	for entry in entries.slice(0, cap):
		shown.append(String(entry))
	var more := "" if entries.size() <= cap else " (+%d more)" % (entries.size() - cap)
	return ", ".join(shown) + more


## One UndoRedo's readable state as plain data; reads names and position only, never stepping the history.
static func _history_state(label: String, undo: UndoRedo) -> Dictionary:
	var names: Array = []
	for i in undo.get_history_count():
		names.append(undo.get_action_name(i))
	return {"label": label, "names": names, "current": undo.get_current_action(), "has_undo": undo.has_undo(), "has_redo": undo.has_redo()}


## One history block: header with counts and undo/redo availability, then the windowed newest-first action lines — "(undone)" marks actions above the current position, which redo would reapply.
## The other-scenes disclosure rides the empty case too, where it matters most: an empty active history with edits sitting in another tab's would otherwise read as "the user changed nothing".
static func _format_history(history: Dictionary, window: int) -> String:
	var label := String(history.get("label", ""))
	if bool(history.get("no_scene", false)):
		return "%s: no scene is open, so no scene history exists — the global history below is all the editor holds." % label
	var others := int(history.get("other_scenes", 0))
	var others_note := "" if others <= 0 else ("only the active scene's history is readable — the other open scene keeps its own" if others == 1 else "only the active scene's history is readable — the %d other open scenes each keep their own" % others)
	var names: Array = history.get("names", [])
	var current := int(history.get("current", -1))
	if names.is_empty():
		return "%s: empty — nothing was done here this editor session%s." % [label, "" if others_note == "" else " (" + others_note + ")"]
	var undo_note := "undo available" if bool(history.get("has_undo", false)) else "nothing to undo"
	var redo_note := "redo available" if bool(history.get("has_redo", false)) else "nothing to redo"
	var lines: Array[String] = []
	lines.append("%s — %d %s, newest first (%s; %s):" % [label, names.size(), "action" if names.size() == 1 else "actions", undo_note, redo_note])
	var stop := maxi(names.size() - window, 0)
	for i in range(names.size() - 1, stop - 1, -1):
		lines.append("  %d. %s%s" % [i + 1, String(names[i]), " (undone)" if i > current else ""])
	if stop > 0:
		lines.append("  (%d older %s not shown — pass a larger \"window\" to see more)" % [stop, "action" if stop == 1 else "actions"])
	if others_note != "":
		lines.append("  (%s)" % others_note)
	return "\n".join(lines)
