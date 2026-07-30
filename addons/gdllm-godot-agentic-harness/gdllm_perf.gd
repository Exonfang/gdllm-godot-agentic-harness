@tool
class_name GDLLMPerf extends RefCounted
## Engine-truth performance and debugger-tab access for a running game. The game already streams every Performance monitor to the editor about once per second (the "performance:profile_frame" debugger message — always on, raw floats indexed by the Performance.Monitor enum), and ScriptEditorDebugger re-emits every incoming message on its public debug_data signal BEFORE the built-in handlers consume it — so this class records that stream passively per session and answers from real numbers, never from scraping formatted widget text. Three of the debugger's tabs are instead DRIVEN and read back: the Profiler, Visual Profiler, and Network Profiler are toggled by pressing their OWN Start/Stop button (see toggle_profiler for why the raw EditorDebuggerSession.toggle_profiler route cannot be used twice) and read from their own Trees, and the Video RAM tab is refreshed by pressing its own Reload button — so every capture this class takes is indistinguishable from one the user takes by hand, and fills the same tab in front of them. Two non-performance records ride the message stream too, because one debug_data hook is better than three: the Video RAM reply's arrival (the settle signal a refresh waits on) and the clicked-control record behind the Misc tab's fields. Every method is static — this is a namespace, not an instance.

## Most monitor frames kept per debugger session (~one per second, so roughly three minutes of history); older samples fall off the front.
const PERF_SAMPLE_CAP := 180
## read_performance's summary-window bounds, in seconds.
const DEFAULT_WINDOW_SECONDS := 30
const MAX_WINDOW_SECONDS := 180
## The most function/category rows one profile report relays before pointing at the Profiler tab for the rest.
const PROFILE_MAX_ROWS := 20
## The most render-pass rows a visual profile relays, higher than the function cap because the passes are a tree whose leaves carry the cost.
const VISUAL_MAX_ROWS := 40
## The most per-node rows a network profile relays from each of the Network Profiler's two tables.
const NETWORK_MAX_ROWS := 20
## read_video_ram's row bounds: enough of the top of a list the engine already sorted by size to answer "what is eating video memory", never the whole registry.
const VRAM_DEFAULT_ROWS := 20
const VRAM_MAX_ROWS := 100
## Most clicked-control records kept per session — comfortably above one input sequence's step cap, so a sequence's own clicks never fall off its own report.
const CLICK_RECORD_CAP := 40

## The debugger's three profiler tabs, keyed by the mode name a tool takes: the editor panel class that owns the tab (which is also how its widgets are located) and the tab's own English title, used when a result or a refusal has to name it.
const PROFILERS := {
	"functions": {"panel": "EditorProfiler", "tab": "Profiler"},
	"visual": {"panel": "EditorVisualProfiler", "tab": "Visual Profiler"},
	"network": {"panel": "EditorNetworkProfiler", "tab": "Network Profiler"},
}

## The spellings each profiler mode answers to, in the tolerant-key spirit of the tools' argument lists: a model reaches for what it wants measured ("gpu", "rpc") far more often than for the tab's name.
const PROFILER_ALIASES := {
	"functions": "functions", "function": "functions", "cpu": "functions", "script": "functions", "scripts": "functions", "code": "functions", "profiler": "functions",
	"visual": "visual", "gpu": "visual", "render": "visual", "rendering": "visual", "graphics": "visual", "draw": "visual", "visual_profiler": "visual",
	"network": "network", "net": "network", "rpc": "network", "multiplayer": "network", "bandwidth": "network", "network_profiler": "network",
}

## The monitors a default read reports, as [Performance.Monitor index, label, format kind, skip-when-always-zero]: the set that answers "how is the game doing" without dumping all 59 monitors (all=true reports everything). The skip flag drops physics/orphan lines that are zero through the whole window — a 2D game's 3D monitors are dead weight — with the omission counted in the result.
const CURATED_MONITORS := [
	[Performance.TIME_FPS, "FPS", "fps", false],
	[Performance.TIME_PROCESS, "frame time", "ms", false],
	[Performance.TIME_PHYSICS_PROCESS, "physics time", "ms", false],
	[Performance.MEMORY_STATIC, "static memory", "bytes", false],
	[Performance.OBJECT_COUNT, "objects", "count", false],
	[Performance.OBJECT_NODE_COUNT, "nodes", "count", false],
	[Performance.OBJECT_ORPHAN_NODE_COUNT, "orphan nodes", "count", true],
	[Performance.RENDER_TOTAL_OBJECTS_IN_FRAME, "objects drawn", "count", false],
	[Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME, "primitives drawn", "count", false],
	[Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME, "draw calls", "count", false],
	[Performance.RENDER_VIDEO_MEM_USED, "video memory", "bytes", false],
	[Performance.PHYSICS_2D_ACTIVE_OBJECTS, "2D active bodies", "count", true],
	[Performance.PHYSICS_2D_COLLISION_PAIRS, "2D collision pairs", "count", true],
	[Performance.PHYSICS_3D_ACTIVE_OBJECTS, "3D active bodies", "count", true],
	[Performance.PHYSICS_3D_COLLISION_PAIRS, "3D collision pairs", "count", true],
]

## The registered GDLLMDebuggerBridge, set by the plugin at load: its sessions are the only scriptable "is a game debug session active" signal, the gate every profiler press checks first.
static var bridge: EditorDebuggerPlugin = null
## Per-session monitor state keyed by the ScriptEditorDebugger's instance id: {"name", "samples": [{"at", "values"}], "custom_names"}.
static var _sessions: Dictionary = {}


## Hook the debug_data signal of every debugger session panel, idempotently; called lazily from every perf entry point so late-created sessions get picked up. Returns {"found", "hooked"} so a caller can tell "no debugger panel" from "this build's panel has no debug_data signal" — two different honest refusals.
static func ensure_connected() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"found": 0, "hooked": 0}
	var found := 0
	var hooked := 0
	for debugger in GDLLMConsole.find_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger"):
		found += 1
		if not debugger.has_signal("debug_data"):
			continue
		hooked += 1
		var handler := _on_debug_data.bind(debugger)
		if not debugger.is_connected("debug_data", handler):
			debugger.connect("debug_data", handler)
	return {"found": found, "hooked": hooked}


## One debugger message. The monitor stream is recorded in full — the frame's raw float array (indexed by Performance.Monitor, custom monitors appended from MONITOR_MAX) and the custom-monitor name announcements that give those extra indices their names — while the other three messages are recorded only for what the tabs themselves cannot say: when a Video RAM reply landed, what bandwidth a network capture saw over its whole window, and when a control was clicked.
static func _on_debug_data(msg: String, data: Array, debugger: Node) -> void:
	if msg == "performance:profile_frame":
		var values := PackedFloat32Array()
		for v in data:
			values.append(float(v))
		var samples: Array = _session_state(debugger)["samples"]
		samples.append({"at": Time.get_ticks_msec(), "values": values})
		while samples.size() > PERF_SAMPLE_CAP:
			samples.pop_front()
	elif msg == "performance:profile_names":
		var names: Array = data[0] if data.size() >= 1 and data[0] is Array else data
		var customs := PackedStringArray()
		for n in names:
			customs.append(String(n))
		_session_state(debugger)["custom_names"] = customs
	elif msg == "servers:memory_usage":
		# The Video RAM tab's reply to its own Reload button: only the arrival is stamped, since the tab renders the list this stamp says has landed, and a refresh has no other way to know the game answered.
		_session_state(debugger)["vram_at"] = Time.get_ticks_msec()
	elif msg == "multiplayer:bandwidth":
		# Reported about once per second, but ONLY while the network profiler is capturing, so these samples cover exactly the windows a capture spans — the tab itself shows the last reading alone.
		var band: Array = _session_state(debugger)["bandwidth"]
		band.append({"at": Time.get_ticks_msec(), "in": _at_float(data, 0), "out": _at_float(data, 1)})
		while band.size() > PERF_SAMPLE_CAP:
			band.pop_front()
	elif msg == "scene:click_ctrl":
		# The record behind the Misc tab's Clicked Control fields: the game sends it whenever a mouse press lands on a Control, synthetic input included (probe-verified against an Input.parse_input_event click), which makes it the only engine-side proof that a click reached a target rather than empty space. Kept as a ring, not one record, because an input sequence can click several times and reporting only the newest would hide an earlier click's miss behind a later one's landing.
		var clicks: Array = _session_state(debugger)["clicks"]
		clicks.append({"at": Time.get_ticks_msec(), "path": _at_string(data, 0), "class": _at_string(data, 1)})
		while clicks.size() > CLICK_RECORD_CAP:
			clicks.pop_front()


static func _at_float(data: Array, index: int) -> float:
	return float(data[index]) if data.size() > index else 0.0


static func _at_string(data: Array, index: int) -> String:
	return String(data[index]) if data.size() > index else ""


static func _session_state(debugger: Node) -> Dictionary:
	var key := debugger.get_instance_id()
	if not _sessions.has(key):
		_sessions[key] = {"name": String(debugger.name), "samples": [], "custom_names": PackedStringArray(), "bandwidth": [], "vram_at": 0, "clicks": []}
	var state: Dictionary = _sessions[key]
	# Static state outlives a script hot reload, so an entry recorded by an older build of this file can lack keys added since; filling them here keeps the message hook from erroring once per report right after a plugin update.
	for missing in ["bandwidth", "clicks"]:
		if not state.has(missing):
			state[missing] = []
	return state


## The recorded session states whose panels still exist, stale ids dropped in passing.
static func _live_states() -> Array:
	var out: Array = []
	for key in _sessions.keys():
		if instance_from_id(int(key)) == null:
			_sessions.erase(key)
			continue
		out.append(_sessions[key])
	return out


## The read_performance tool body: per-session monitor summaries over the window, or the honest reason there is nothing to summarize — a missing panel and a missing signal each refuse by name, and "no samples" explains the once-per-second stream and who can start a run.
static func read_performance(seconds: int, all: bool) -> String:
	if not Engine.is_editor_hint():
		return "Error: performance monitors arrive over the editor's debugger, and this session is running headless — there is no debugger to read."
	var hook := ensure_connected()
	if int(hook["found"]) == 0:
		return "Error: the debugger's session panels could not be located in this editor build — its internal layout may have changed. Tell the user the read_performance tool needs updating for this editor version."
	if int(hook["hooked"]) == 0:
		return "Error: this editor build's debugger panel has no debug_data signal to read the monitor stream from. Tell the user the read_performance tool needs updating for this editor version."
	var window := clampi(seconds if seconds > 0 else DEFAULT_WINDOW_SECONDS, 1, MAX_WINDOW_SECONDS)
	var now := Time.get_ticks_msec()
	var states := _live_states()
	var blocks: Array = []
	for state: Dictionary in states:
		var body := summarize(state["samples"], state["custom_names"], window, all, now)
		if body == "":
			continue
		if states.size() > 1:
			body = "%s:\n%s" % [state["name"], body]
		blocks.append(body)
	if not blocks.is_empty():
		return "\n\n".join(PackedStringArray(blocks))
	if EditorInterface.is_playing_scene():
		return "No performance samples have arrived yet — the game reports its monitors about once per second, so ask again in a moment."
	return "No performance samples are recorded. The game streams its Performance monitors (FPS, frame time, memory, draw calls, and so on) about once per second WHILE it runs, and nothing is running now — start a run with run_game, or ask the user to play; their session is sampled automatically."


## Pure summary of one session's samples: the curated monitor set (or every built-in with all=true) plus every custom monitor, each as avg/min/max over the window — a constant value collapses to one figure — and an honest staleness note when the newest sample predates the window, because quoting minutes-old numbers as live would be a lie. "" only when there are no samples at all.
static func summarize(samples: Array, custom_names: PackedStringArray, window_seconds: int, all: bool, now_ms: int) -> String:
	if samples.is_empty():
		return ""
	var floor_ms := now_ms - window_seconds * 1000
	var pool: Array = samples.filter(func(s: Variant) -> bool: return int(s["at"]) >= floor_ms)
	var stale_note := ""
	if pool.is_empty():
		pool = samples.slice(maxi(0, samples.size() - 3))
		var age := int(float(now_ms - int(samples[samples.size() - 1]["at"])) / 1000.0)
		stale_note = " — the game last reported %d s ago, so these are the newest samples on record, not live ones" % age
	var lines: Array = ["Performance (%d samples over the last %d s%s):" % [pool.size(), window_seconds, stale_note]]
	var omitted := 0
	if all:
		var names := builtin_monitor_names()
		for i in names.size():
			var stats := _monitor_stats(pool, i)
			if not stats.is_empty():
				lines.append(_stat_line(String(names[i]), stats, _kind_for_name(String(names[i]))))
	else:
		for entry: Array in CURATED_MONITORS:
			var stats := _monitor_stats(pool, int(entry[0]))
			if stats.is_empty():
				continue
			if bool(entry[3]) and float(stats["max"]) == 0.0:
				omitted += 1
				continue
			lines.append(_stat_line(String(entry[1]), stats, String(entry[2])))
	for j in custom_names.size():
		var stats := _monitor_stats(pool, Performance.MONITOR_MAX + j)
		if not stats.is_empty():
			lines.append(_stat_line("custom " + String(custom_names[j]), stats, "raw"))
	if omitted > 0:
		lines.append("(%d always-zero monitors omitted; pass all=true for every monitor)" % omitted)
	return "\n".join(PackedStringArray(lines))


## Editor half of run_game's perf rider: every session's samples stamped at or after `since_ms`, summarized in one compact line by the pure half below.
static func run_summary(since_ms: int) -> String:
	var pool: Array = []
	var customs := PackedStringArray()
	for state: Dictionary in _live_states():
		for sample: Dictionary in state["samples"]:
			if int(sample["at"]) >= since_ms:
				pool.append(sample)
		if (state["custom_names"] as PackedStringArray).size() > customs.size():
			customs = state["custom_names"]
	return compact_summary(pool, customs)


## Pure one-line digest for a run capture — the handful of numbers that say how the run went (FPS, frame time, draw calls, memory, nodes, plus any custom monitors), with an honest explanation when no samples arrived instead of silence.
static func compact_summary(pool: Array, custom_names: PackedStringArray) -> String:
	if pool.is_empty():
		return "Performance: no monitor samples arrived during the run — the game reports about once per second, so a longer wait_seconds captures them, and read_performance reads later ones."
	var parts: Array = []
	var fps := _monitor_stats(pool, Performance.TIME_FPS)
	if not fps.is_empty():
		parts.append("FPS avg %s (min %s)" % [_fmt(float(fps["avg"]), "fps"), _fmt(float(fps["min"]), "fps")])
	var frame := _monitor_stats(pool, Performance.TIME_PROCESS)
	if not frame.is_empty():
		parts.append("frame avg %s" % _fmt(float(frame["avg"]), "ms"))
	var draws := _monitor_stats(pool, Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	if not draws.is_empty():
		parts.append("draw calls avg %s" % _fmt(float(draws["avg"]), "count"))
	var mem := _monitor_stats(pool, Performance.MEMORY_STATIC)
	if not mem.is_empty():
		parts.append("static memory %s" % _fmt(float(mem["last"]), "bytes"))
	var nodes := _monitor_stats(pool, Performance.OBJECT_NODE_COUNT)
	if not nodes.is_empty():
		parts.append("nodes %s" % _fmt(float(nodes["last"]), "count"))
	for j in custom_names.size():
		var stats := _monitor_stats(pool, Performance.MONITOR_MAX + j)
		if not stats.is_empty():
			parts.append("%s avg %s" % [custom_names[j], String.num(float(stats["avg"]), 3)])
	return "Performance during the run (%d samples): %s. read_performance has more monitors and a longer window." % [pool.size(), ", ".join(PackedStringArray(parts))]


## Toggle one of the game's profilers (see PROFILERS) by pressing that tab's OWN Start/Stop button — the same control the user's hand reaches. The raw EditorDebuggerSession.toggle_profiler route is deliberately NOT used: it bypasses the tab's clear/re-arm state machine, so on 4.7 only the first capture after the tab's virgin state ever renders — every later raw-toggled capture reads back as an empty tab (repro-verified; it broke every second profile_game in the wild). The button path clears and fills the tab exactly as a hand-run capture does and applies the user's own profiler settings (max functions, native calls, measure mode) by construction. {"ok", "why", "sessions"}, where a false ok names the missing piece.
static func toggle_profiler(mode: String, enable: bool) -> Dictionary:
	var tab := String((PROFILERS.get(mode, {}) as Dictionary).get("tab", "Profiler"))
	if bridge == null:
		return {"ok": false, "why": "the debugger bridge is not registered — the plugin needs a reload (Project Settings → Plugins)", "sessions": 0}
	var active := active_sessions()
	if active == 0:
		return {"ok": false, "why": "no debug session is active — the game may still be starting, or nothing is running", "sessions": 0}
	var buttons := _profiler_activate_buttons(mode)
	if buttons.is_empty():
		return {"ok": false, "why": "the %s tab's Start button could not be located in this editor build — its internal layout may have changed; tell the user the profiling tools need updating for this editor version" % tab, "sessions": active}
	for button: Button in buttons:
		# A button already in the requested state is left alone, so a capture the user started by hand isn't cleared out from under them by a redundant press.
		if button.button_pressed != enable:
			button.set_pressed_no_signal(enable)
			button.emit_signal("pressed")
	return {"ok": true, "why": "", "sessions": active}


## How many debug sessions are attached — the bridge's sessions are the only scriptable "a game is really talking to the editor" signal, which every press has to check first: a panel button pressed with no session behind it pushes an engine error into the user's own Output console.
static func active_sessions() -> int:
	if bridge == null:
		return 0
	var active := 0
	for session in bridge.get_sessions():
		if session != null and session.is_active():
			active += 1
	return active


## The canonical profiler mode behind a tool's argument, "" when the spelling names none of them.
static func profiler_mode(requested: String) -> String:
	return String(PROFILER_ALIASES.get(requested.strip_edges().to_lower().replace(" ", "_"), ""))


## The Start/Stop button of every session's profiler tab of `mode`: the only toggle-mode plain Button inside the panel (its Autostart CheckBox and internal-functions CheckButton are their own classes, and its Clear button is not a toggle, so the fingerprint holds across all three tabs on 4.7). Deliberately not matched by icon: the button swaps Play for Stop while running, so an icon match would find it once and never again. [] when the layout changed — the caller must refuse by name.
static func _profiler_activate_buttons(mode: String) -> Array[Button]:
	var found: Array[Button] = []
	for prof in profiler_panels(mode):
		for node in GDLLMConsole.find_by_class(prof["panel"], "Button"):
			var button := node as Button
			if button.toggle_mode:
				found.append(button)
				break
	return found


## Every debugger session's panel for one profiler mode, as {session, panel}; [] headless or when the panel class is gone from this build.
static func profiler_panels(mode: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if not Engine.is_editor_hint() or not PROFILERS.has(mode):
		return found
	var cls := String((PROFILERS[mode] as Dictionary)["panel"])
	for debugger in GDLLMConsole.find_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger"):
		for panel in GDLLMConsole.find_by_class(debugger, cls):
			found.append({"session": String(debugger.name), "panel": panel})
	return found


## The Profiler tab's function Tree per debugger session, matched like the console tools match theirs: the EditorProfiler panel's three-column Tree (Name/Time/Calls). [] when the layout changed and nothing matches — the caller must refuse by name, never invent an empty profile.
static func profiler_trees() -> Array[Dictionary]:
	return mode_trees("functions", 3)


## The result Tree of one profiler mode per session, picked out of its panel by column count — 3 for the function list (Name/Time/Calls) and the visual list (Name/CPU/GPU), 3 and 5 for the network tab's two tables (per-node RPC, and replication sync). [] when nothing matches, which the caller must refuse by name rather than answer with an invented empty capture.
static func mode_trees(mode: String, columns: int) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for entry: Dictionary in profiler_panels(mode):
		var tree := _tree_with_columns(entry["panel"], columns)
		if tree != null:
			found.append({"session": String(entry["session"]), "tree": tree})
	return found


static func _tree_with_columns(root: Node, columns: int) -> Tree:
	for tree in GDLLMConsole.find_by_class(root, "Tree"):
		if (tree as Tree).columns == columns:
			return tree as Tree
	return null


## The Video RAM tab per debugger session, as {session, tree, total, refresh}. The tab is matched by shape — a plain VBoxContainer under the session's TabContainer holding a four-column Tree (Resource Path/Type/Format/Usage) — because its title is localized, its Reload button by the editor theme icon it carries (the identity trick the stepping buttons use, and safe here because this button never swaps its icon), and its total by being the tab's one read-only LineEdit. [] when the layout changed, which the caller must refuse by name.
static func video_ram_tabs() -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if not Engine.is_editor_hint():
		return found
	for debugger in GDLLMConsole.find_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger"):
		for tabs in debugger.get_children(true):
			if not tabs is TabContainer:
				continue
			for tab in tabs.get_children(true):
				if tab.get_class() != "VBoxContainer":
					continue
				var tree := _tree_with_columns(tab, 4)
				if tree == null:
					continue
				found.append({"session": String(debugger.name), "tree": tree, "total": _readonly_line_edit(tab), "refresh": _icon_button(tab, "Reload")})
	return found


## The Video RAM tab's total, read from the widget at call time: the tab is located BEFORE its refresh is pressed, so carrying the text along from then would report the previous refresh's figure beside this refresh's rows.
static func video_ram_total(tab: Dictionary) -> String:
	var edit: LineEdit = tab.get("total")
	return edit.text.strip_edges() if edit != null else ""


## The one read-only LineEdit under `root` — the Video RAM tab's total (the tab's other LineEdit belongs to the Tree's own search popup and is editable); null when this build's layout no longer has it.
static func _readonly_line_edit(root: Node) -> LineEdit:
	for node in GDLLMConsole.find_by_class(root, "LineEdit"):
		if not (node as LineEdit).editable:
			return node as LineEdit
	return null


## The Button under `root` carrying the editor theme icon `icon_name`, since button tooltips and labels are localized but icon names are not; null when this build's layout no longer has it.
static func _icon_button(root: Node, icon_name: String) -> Button:
	var wanted := EditorInterface.get_base_control().get_theme_icon(icon_name, "EditorIcons")
	for node in GDLLMConsole.find_by_class(root, "Button"):
		if (node as Button).icon == wanted:
			return node as Button
	return null


## The newest Video RAM reply stamp per session name, the settle signal a refresh press waits on: the game answers "servers:memory_usage" on its own schedule, and reading the tab before the reply lands would report the PREVIOUS refresh's list as this one's.
static func video_ram_stamps() -> Dictionary:
	var stamps: Dictionary = {}
	for state: Dictionary in _live_states():
		stamps[String(state["name"])] = int(state.get("vram_at", 0))
	return stamps


## One dictionary per row of the Video RAM tab's Tree — the resource's path, type, format, and the usage exactly as the tab formats it — so the composer and the tests share a shape that isn't a live Tree. The engine sends the list already sorted biggest-first, so row order is the ranking.
static func video_ram_rows(tree: Tree) -> Array:
	var out: Array = []
	var root := tree.get_root()
	if root == null:
		return out
	var item := root.get_first_child()
	while item != null:
		out.append({"path": item.get_text(0), "type": item.get_text(1), "format": item.get_text(2), "usage": item.get_text(3)})
		item = item.get_next()
	return out


## Pure composer for a video-memory read: the tab's own total, then the biggest consumers first (the engine's own ordering) capped at `limit`, with an optional case-insensitive substring filter over path/type/format. An unnamed row is an engine-internal resource with no file behind it, said outright rather than printed as a blank path, and an empty list is explained instead of read as "no video memory in use".
static func format_video_ram(rows: Array, total: String, limit: int, filter: String) -> String:
	if rows.is_empty():
		return "The Video RAM tab reports no resources in video memory. That is what a game shows before it has drawn anything, or one running on a driver with no video memory to report (a --headless run); a game with visuals on screen should list its textures and meshes here."
	var cap := clampi(limit if limit > 0 else VRAM_DEFAULT_ROWS, 1, VRAM_MAX_ROWS)
	var pool: Array = rows
	if filter != "":
		var needle := filter.to_lower()
		pool = []
		for row: Dictionary in rows:
			if ("%s %s %s" % [row["path"], row["type"], row["format"]]).to_lower().contains(needle):
				pool.append(row)
		if pool.is_empty():
			return "Video memory: %d resources totalling %s; none of them match \"%s\"." % [rows.size(), total, filter]
	var lines: Array = [_video_ram_header(rows.size(), total, pool.size(), mini(pool.size(), cap), filter)]
	for i in mini(pool.size(), cap):
		var row: Dictionary = pool[i]
		var path := String(row["path"]).strip_edges()
		var name := path if path != "" else "(engine-internal, no resource path)"
		lines.append("- %s — %s (%s, %s)" % [row["usage"], name, row["type"], row["format"]])
	if pool.size() > cap:
		lines.append("(+%d smaller resources not shown — raise \"limit\", filter by name, or open Debugger → Video RAM for the full list)" % (pool.size() - cap))
	return "\n".join(PackedStringArray(lines))


static func _video_ram_header(total_rows: int, total: String, matched: int, shown: int, filter: String) -> String:
	var tally := "%d resources in video memory, %s in total" % [total_rows, total if total != "" else "an unreported amount"]
	if filter != "":
		if shown >= matched:
			return "%s; %d match \"%s\" (biggest first):" % [tally, matched, filter]
		return "%s; %d match \"%s\", showing the %d largest of those (biggest first):" % [tally, matched, filter, shown]
	if shown >= total_rows:
		return "%s, biggest first:" % tally
	return "%s, showing the %d largest (biggest first):" % [tally, shown]


## One flat row per render pass of the Visual Profiler tab's Tree, each with its nesting depth and the tab's own CPU and GPU figures — the passes are a tree (a viewport contains canvases contain draws), so depth is what makes the report readable.
static func visual_rows(tree: Tree) -> Array:
	var out: Array = []
	var root := tree.get_root()
	if root == null:
		return out
	_walk_visual(root.get_first_child(), 0, out)
	return out


static func _walk_visual(item: TreeItem, depth: int, out: Array) -> void:
	while item != null:
		out.append({"depth": depth, "name": item.get_text(0).strip_edges(), "cpu": item.get_text(1), "gpu": item.get_text(2)})
		_walk_visual(item.get_first_child(), depth + 1, out)
		item = item.get_next()


## Pure composer for a visual (GPU) profile: the render passes as the tab nests them, each with its CPU and GPU time, capped at VISUAL_MAX_ROWS — `limit` raises the cap and `filter` narrows by pass name (matched rows print flat: nesting context belongs to the unfiltered walk). The caption is deliberate — this tab shows ONE frame's breakdown, not an average over the capture — so a reader never takes a single frame's spike for the run's cost.
static func format_visual_profile(rows: Array, limit := 0, filter := "") -> String:
	if rows.is_empty():
		return "The Visual Profiler tab shows no captured frame — the capture may have been too short to record one, or the game's renderer reports no frame timings (a --headless run has none)."
	var cap := limit if limit > 0 else VISUAL_MAX_ROWS
	var f := filter.to_lower()
	var picked: Array = rows if f == "" else rows.filter(func(row: Dictionary) -> bool: return String(row["name"]).to_lower().contains(f))
	if picked.is_empty():
		return "No render pass matches \"%s\" (%d passes in the captured frame) — call without \"filter\" for the full breakdown." % [filter, rows.size()]
	var lines: Array = ["Render passes of the frame the Visual Profiler tab currently shows (its Frame # selector picks the frame; CPU is the time the engine spent submitting the pass, GPU the time the card spent on it):"]
	for i in mini(picked.size(), cap):
		var row: Dictionary = picked[i]
		lines.append("%s- %s — CPU %s, GPU %s" % ["  ".repeat(int(row["depth"])), row["name"], row["cpu"], row["gpu"]])
	if picked.size() > cap:
		lines.append("(+%d deeper rows — raise \"limit\" or pass \"filter\" with part of a pass name; the editor's Visual Profiler tab shows the user the full breakdown)" % (picked.size() - cap))
	if f != "" and picked.size() < rows.size():
		lines.append("(%d pass(es) hidden by the filter.)" % (rows.size() - picked.size()))
	return "\n".join(PackedStringArray(lines))


## One row per node of the Network Profiler's tables, cells kept verbatim so one scraper serves both its per-node RPC table (Node/Incoming/Outgoing) and its replication table (Root/Synchronizer/Config/Count/Size).
static func network_rows(tree: Tree) -> Array:
	var out: Array = []
	var root := tree.get_root()
	if root == null:
		return out
	var item := root.get_first_child()
	while item != null:
		var cells := PackedStringArray()
		for c in tree.columns:
			cells.append(item.get_text(c))
		out.append(cells)
		item = item.get_next()
	return out


## Pure composer for a network profile: the bandwidth the game actually reported across the capture (from the stream, since the tab shows only its last reading), then the per-node RPC counts and any replication traffic. A game that used no multiplayer at all says so and names why that is the expected result for a single-player project, rather than reading as a failed capture.
static func format_network(bandwidth: Array, rpc: Array, syncs: Array, limit := 0, filter := "") -> String:
	var cap := limit if limit > 0 else NETWORK_MAX_ROWS
	var f := filter.to_lower()
	var had := rpc.size() + syncs.size()
	if f != "":
		rpc = rpc.filter(func(row: PackedStringArray) -> bool: return String(row[0]).to_lower().contains(f))
		syncs = syncs.filter(func(row: PackedStringArray) -> bool: return String(row[0]).to_lower().contains(f))
		# Traffic hidden by the filter must not read as "none was recorded" — that line diagnoses single-player projects, not a narrow filter.
		if rpc.is_empty() and syncs.is_empty() and had > 0:
			return "No node matches \"%s\" in the network capture (%d row(s) recorded) — call without \"filter\" for the full tables." % [filter, had]
	var lines: Array = []
	if bandwidth.is_empty():
		lines.append("Bandwidth: the game reported none during the capture — it reports about once per second while the network profiler runs, so a longer capture catches at least one report.")
	else:
		var down := _series(bandwidth, "in")
		var up := _series(bandwidth, "out")
		lines.append("Bandwidth over %d report(s): incoming %s avg (peak %s), outgoing %s avg (peak %s)." % [bandwidth.size(), _bytes_per_second(down["avg"]), _bytes_per_second(down["max"]), _bytes_per_second(up["avg"]), _bytes_per_second(up["max"])])
	if rpc.is_empty() and syncs.is_empty():
		lines.append("No RPC or replication traffic was recorded. For a single-player project that is the expected result — this tab only fills for nodes that send RPCs or run a MultiplayerSynchronizer.")
		return "\n".join(PackedStringArray(lines))
	if rpc.is_empty():
		lines.append("No RPCs were recorded.")
	else:
		lines.append("RPCs per node (incoming / outgoing), as the tab lists them:")
		for i in mini(rpc.size(), cap):
			var row: PackedStringArray = rpc[i]
			lines.append("- %s — in %s, out %s" % [row[0], row[1], row[2]])
		if rpc.size() > cap:
			lines.append("(+%d more nodes — raise \"limit\" or pass \"filter\" with part of a node name; the editor's Network Profiler tab shows the user the full list)" % (rpc.size() - cap))
	if not syncs.is_empty():
		lines.append("Replication (MultiplayerSynchronizer traffic):")
		for i in mini(syncs.size(), cap):
			var row: PackedStringArray = syncs[i]
			lines.append("- %s / %s (%s) — %s syncs, %s" % [row[0], row[1], row[2], row[3], row[4]])
		if syncs.size() > cap:
			lines.append("(+%d more synchronizers — raise \"limit\" or pass \"filter\" with part of a node name; the editor's Network Profiler tab shows the user the full list)" % (syncs.size() - cap))
	return "\n".join(PackedStringArray(lines))


## The bandwidth reports stamped at or after `since_ms`, newest sessions merged — the window a network capture just spanned.
static func bandwidth_since(since_ms: int) -> Array:
	var pool: Array = []
	for state: Dictionary in _live_states():
		for sample: Dictionary in state.get("bandwidth", []):
			if int(sample["at"]) >= since_ms:
				pool.append(sample)
	return pool


## The newest clicked-control record across live sessions — {"at", "path", "class"}, or {} when no control has been clicked in any run since the editor started.
static func last_click() -> Dictionary:
	var newest: Dictionary = {}
	for state: Dictionary in _live_states():
		var clicks: Array = state.get("clicks", [])
		if not clicks.is_empty() and int(clicks[clicks.size() - 1]["at"]) >= int(newest.get("at", 0)):
			newest = clicks[clicks.size() - 1]
	return newest


## Every clicked-control record stamped at or after `since_ms` across live sessions, oldest first — the clicks an input sequence's window actually saw.
static func clicks_since(since_ms: int) -> Array:
	var pool: Array = []
	for state: Dictionary in _live_states():
		for click: Dictionary in state.get("clicks", []):
			if int(click["at"]) >= since_ms:
				pool.append(click)
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["at"]) < int(b["at"]))
	return pool


## Pure one-line report of the debugger's clicked-control record (the Misc tab's fields), with its age, because a record left over from an earlier run would otherwise read as the state of this one. "" when nothing has been clicked at all.
static func format_click_record(click: Dictionary, now_ms: int) -> String:
	if click.is_empty():
		return ""
	return "Last control click the game reported: %s at %s (%s)." % [click["class"], click["path"], _ago(int(click["at"]), now_ms)]


## Pure: what a played input sequence's own clicks landed on, from EVERY record stamped within the sequence — not the newest alone, which would hide one step's miss behind another's landing. A pointer step that reached no Control is the wild failure this exists to catch — a click on empty space, on a node drawn over the target, or one that never fired — so a shortfall against the pointer steps played is counted instead of leaving the sequence reading as a success, worded around the reports' measured ~1-per-second drain (a long chain's last records can still be queued at compose time, so their absence is evidence, never proof), and a surplus is attributed to the one other pointer that exists (the user's own).
static func format_click_result(clicks: Array, pointer_steps: int) -> String:
	if clicks.is_empty():
		return "No control click has been reported for the sequence: the pointer steps landed on empty space or on a non-Control node, or the click was consumed before any Control saw it. read_game_ui's rects say what is actually where, and its click record would show a report that arrives late (the game reports clicks about once per second)."
	var body: String
	if clicks.size() == 1:
		var only: Dictionary = clicks[0]
		body = "The game reported the click landing on %s at %s — engine truth that the pointer reached a Control, not that the control acted on it." % [only["class"], only["path"]]
	else:
		var listed: Array = []
		for click: Dictionary in clicks:
			listed.append("%s at %s" % [click["class"], click["path"]])
		body = "The game reported %d control clicks during the sequence, in order: %s — engine truth that those pointers reached Controls, not that the controls acted on them." % [clicks.size(), ", then ".join(PackedStringArray(listed))]
	if clicks.size() < pointer_steps:
		body += " No control click has been reported for the other %d pointer step(s) — those landed on empty space or a non-Control node, or their reports are still queued (the game reports clicks about once per second; read_game_ui shows what arrived since)." % (pointer_steps - clicks.size())
	elif clicks.size() > pointer_steps:
		body += " That is more clicks than pointer steps, so the user's own mouse was likely playing into the game too — it is recorded the same way."
	return body


static func _ago(at_ms: int, now_ms: int) -> String:
	var seconds := int(float(maxi(0, now_ms - at_ms)) / 1000.0)
	if seconds < 1:
		return "just now"
	return "%d s ago" % seconds


static func _series(pool: Array, key: String) -> Dictionary:
	var sum := 0.0
	var peak := 0.0
	for sample: Dictionary in pool:
		sum += float(sample[key])
		peak = maxf(peak, float(sample[key]))
	return {"avg": sum / pool.size(), "max": peak}


static func _bytes_per_second(value: float) -> String:
	if value >= 1048576.0:
		return "%s MB/s" % String.num(value / 1048576.0, 2)
	if value >= 1024.0:
		return "%s KB/s" % String.num(value / 1024.0, 1)
	return "%d B/s" % int(roundf(value))


## One dictionary per category of the Profiler tab's Tree — the category row's name and time plus each child row's name/time/calls — so the report composer and the tests share a shape that isn't a live Tree.
static func profiler_rows(tree: Tree) -> Array:
	var out: Array = []
	var root := tree.get_root()
	if root == null:
		return out
	var category := root.get_first_child()
	while category != null:
		var rows: Array = []
		var child := category.get_first_child()
		while child != null:
			rows.append({"name": child.get_text(0), "time": child.get_text(1), "calls": child.get_text(2)})
			child = child.get_next()
		out.append({"name": category.get_text(0), "time": category.get_text(1), "rows": rows})
		category = category.get_next()
	return out


## Pure composer for a profile capture: category headers with their times, child rows capped at PROFILE_MAX_ROWS across the whole report (the tab ranks them, so the cap keeps the hottest), the rest reachable through `limit` and `filter` — an explicit ask is honored, matching read_video_ram's contract — and an empty tab stated rather than passed off as "nothing was slow".
static func format_profile(categories: Array, limit := 0, filter := "") -> String:
	if categories.is_empty():
		return "The Profiler tab shows no captured frame — the profiler may not have run long enough to record one."
	var cap := limit if limit > 0 else PROFILE_MAX_ROWS
	var f := filter.to_lower()
	var lines: Array = []
	var shown := 0
	var dropped := 0
	var filtered_out := 0
	for cat: Dictionary in categories:
		var head := String(cat["name"])
		if String(cat["time"]) != "":
			head += " — " + String(cat["time"])
		lines.append(head + ":")
		for row: Dictionary in cat["rows"]:
			if f != "" and not String(row["name"]).to_lower().contains(f):
				filtered_out += 1
				continue
			if shown >= cap:
				dropped += 1
				continue
			shown += 1
			var calls := String(row["calls"])
			lines.append("  %s — %s%s" % [row["name"], row["time"], " (%s calls)" % calls if calls != "" else ""])
	if dropped > 0:
		lines.append("(+%d more rows — raise \"limit\", or pass \"filter\" with part of a function's name; the editor's Profiler tab shows the user the full capture)" % dropped)
	if filtered_out > 0:
		lines.append("(%d row(s) hidden by the filter.)" % filtered_out)
	return "\n".join(PackedStringArray(lines))


## The built-in monitor names indexed by their Performance.Monitor value, read from ClassDB at call time so the table can never drift from the running engine (no scriptable get_monitor_name exists).
static func builtin_monitor_names() -> PackedStringArray:
	var names := PackedStringArray()
	names.resize(Performance.MONITOR_MAX)
	for constant in ClassDB.class_get_enum_constants("Performance", "Monitor", true):
		var value := ClassDB.class_get_integer_constant("Performance", constant)
		if value >= 0 and value < Performance.MONITOR_MAX:
			names[value] = constant
	return names


## min/avg/max/last of one monitor index across the pool; {} when no sample carries that index (an older frame from before a custom monitor existed simply doesn't count).
static func _monitor_stats(pool: Array, index: int) -> Dictionary:
	var found := false
	var vmin := 0.0
	var vmax := 0.0
	var sum := 0.0
	var last := 0.0
	var count := 0
	for sample: Dictionary in pool:
		var values: PackedFloat32Array = sample["values"]
		if index >= values.size():
			continue
		var v := values[index]
		if not found:
			vmin = v
			vmax = v
			found = true
		vmin = minf(vmin, v)
		vmax = maxf(vmax, v)
		sum += v
		last = v
		count += 1
	if not found:
		return {}
	return {"min": vmin, "max": vmax, "avg": sum / count, "last": last}


static func _stat_line(label: String, stats: Dictionary, kind: String) -> String:
	if is_equal_approx(float(stats["min"]), float(stats["max"])):
		return "- %s: %s" % [label, _fmt(float(stats["last"]), kind)]
	return "- %s: %s avg (min %s, max %s)" % [label, _fmt(float(stats["avg"]), kind), _fmt(float(stats["min"]), kind), _fmt(float(stats["max"]), kind)]


## Unit formatting per monitor kind: engine times are seconds (shown as ms), memory monitors are bytes (shown as MB), counts round to integers, and raw covers custom monitors whose unit only their author knows.
static func _fmt(value: float, kind: String) -> String:
	match kind:
		"fps":
			return String.num(value, 1)
		"ms":
			return "%s ms" % String.num(value * 1000.0, 2)
		"bytes":
			return "%s MB" % String.num(value / 1048576.0, 1)
		"count":
			return str(int(roundf(value)))
	return String.num(value, 3)


## Kind heuristic for the all=true dump, keyed off the enum names: TIME_* are seconds (except the FPS counter), *MEM* are bytes, everything else counts.
static func _kind_for_name(name: String) -> String:
	if name == "TIME_FPS":
		return "fps"
	if name.begins_with("TIME_"):
		return "ms"
	if name.contains("MEM"):
		return "bytes"
	return "count"
