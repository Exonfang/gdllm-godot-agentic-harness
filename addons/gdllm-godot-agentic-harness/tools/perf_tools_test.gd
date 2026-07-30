extends SceneTree
## Headless regression tests for the performance and debugger-tab tools' pure halves (GDLLMPerf): the monitor-stream summaries (curated set, all-monitors dump, unit formatting, always-zero omission, staleness honesty, custom monitors), the run capture's compact digest, the ClassDB-derived monitor name table, the Profiler/Visual Profiler/Video RAM/Network Profiler tab scrapes and their report composers, the profiler-mode normalization both profile_game and run_game's flag share, the clicked-control record behind the Misc tab, and the headless/bridge refusals — driven with synthetic samples and Trees because the real streams exist only against a running game.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/perf_tools_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const Perf = preload("res://addons/gdllm-godot-agentic-harness/gdllm_perf.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_monitor_names()
	_test_summarize()
	_test_summarize_stale_and_all()
	_test_compact_summary()
	_test_profiler_scrape()
	_test_profile_format()
	_test_profiler_modes()
	_test_video_ram()
	_test_visual_profile()
	_test_network_profile()
	_test_click_records()
	_test_click_ring()
	_test_refusals()
	_test_profile_no_run()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## One synthetic monitor frame: FPS, frame seconds, static-memory bytes, node count, and optionally one custom monitor value appended past MONITOR_MAX.
func _sample(at: int, fps: float, frame_s: float, mem: float, nodes: float, custom: Array = []) -> Dictionary:
	var values := PackedFloat32Array()
	values.resize(Performance.MONITOR_MAX + custom.size())
	values[Performance.TIME_FPS] = fps
	values[Performance.TIME_PROCESS] = frame_s
	values[Performance.MEMORY_STATIC] = mem
	values[Performance.OBJECT_NODE_COUNT] = nodes
	for i in custom.size():
		values[Performance.MONITOR_MAX + i] = float(custom[i])
	return {"at": at, "values": values}


func _test_monitor_names() -> void:
	var names := Perf.builtin_monitor_names()
	_check(names.size() == Performance.MONITOR_MAX, "the name table covers every built-in monitor")
	_check(String(names[Performance.TIME_FPS]) == "TIME_FPS", "names index by their enum value")
	_check(String(names[Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME]) == "RENDER_TOTAL_DRAW_CALLS_IN_FRAME", "a later monitor lands on its own index too")


func _test_summarize() -> void:
	var samples: Array = [
		_sample(1000, 58.0, 0.016, 84.0 * 1048576.0, 1000.0, [5.0]),
		_sample(2000, 60.0, 0.016, 84.0 * 1048576.0, 1000.0, [5.0]),
		_sample(3000, 62.0, 0.016, 84.0 * 1048576.0, 1000.0, [5.0]),
	]
	var body: String = Perf.summarize(samples, PackedStringArray(["game/enemies"]), 30, false, 3500)
	_check(body.begins_with("Performance (3 samples over the last 30 s):"), "the header counts samples and names the window")
	_check(body.contains("- FPS: 60.0 avg (min 58.0, max 62.0)"), "a varying monitor reports avg with its range")
	_check(body.contains("- frame time: 16.0 ms"), "a constant monitor collapses to one figure, seconds shown as ms")
	_check(body.contains("- static memory: 84.0 MB"), "memory monitors are shown in MB")
	_check(body.contains("- nodes: 1000"), "counts are shown as integers")
	_check(body.contains("- custom game/enemies: 5"), "custom monitors ride the same summary under their registered name")
	_check(body.contains("always-zero monitors omitted"), "zero physics monitors are omitted with the omission counted")
	_check(not body.contains("collision pairs"), "an always-zero monitor's line is not relayed")
	_check(Perf.summarize([], PackedStringArray(), 30, false, 0) == "", "no samples yields no summary, for the caller to explain")


func _test_summarize_stale_and_all() -> void:
	var samples: Array = [_sample(1000, 60.0, 0.016, 84.0 * 1048576.0, 1000.0)]
	var stale: String = Perf.summarize(samples, PackedStringArray(), 30, false, 500000)
	_check(stale.contains("not live ones"), "samples older than the window are labelled stale, never passed off as live")
	_check(stale.contains("499 s ago"), "the staleness note carries the age")
	var everything: String = Perf.summarize(samples, PackedStringArray(), 30, true, 1500)
	_check(everything.contains("TIME_FPS"), "all=true reports monitors under their engine names")
	_check(everything.contains("MEMORY_STATIC"), "all=true includes monitors the curated set formats differently")


func _test_compact_summary() -> void:
	var pool: Array = [
		_sample(1000, 58.0, 0.016, 84.0 * 1048576.0, 1000.0),
		_sample(2000, 62.0, 0.016, 84.0 * 1048576.0, 1000.0),
	]
	var line: String = Perf.compact_summary(pool, PackedStringArray())
	_check(line.begins_with("Performance during the run (2 samples):"), "the digest counts its samples")
	_check(line.contains("FPS avg 60.0 (min 58.0)") and line.contains("frame avg 16.0 ms"), "the digest carries FPS and frame time")
	_check(line.contains("static memory 84.0 MB") and line.contains("nodes 1000"), "the digest carries memory and node count")
	_check(line.contains("read_performance has more monitors"), "the digest names the deeper tool")
	var none: String = Perf.compact_summary([], PackedStringArray())
	_check(none.contains("no monitor samples arrived"), "a sample-less run is explained, not silent")


func _test_profiler_scrape() -> void:
	var tree := Tree.new()
	tree.columns = 3
	var root := tree.create_item()
	var cat := tree.create_item(root)
	cat.set_text(0, "Script Functions")
	cat.set_text(1, "12.5 ms")
	var row := tree.create_item(cat)
	row.set_text(0, "_process")
	row.set_text(1, "8.2 ms")
	row.set_text(2, "600")
	var categories: Array = Perf.profiler_rows(tree)
	_check(categories.size() == 1, "one entry per category row")
	_check(String(categories[0]["name"]) == "Script Functions" and String(categories[0]["time"]) == "12.5 ms", "the category keeps its name and time")
	var rows: Array = categories[0]["rows"]
	_check(rows.size() == 1 and String(rows[0]["name"]) == "_process" and String(rows[0]["calls"]) == "600", "child rows carry name, time, and calls")
	var bare := Tree.new()
	_check(Perf.profiler_rows(bare).is_empty(), "a rootless tree scrapes to no categories")
	bare.free()
	tree.free()


func _test_profile_format() -> void:
	_check(String(Perf.format_profile([])).contains("shows no captured frame"), "an empty capture is stated, never read as nothing-was-slow")
	var rows: Array = []
	for i in Perf.PROFILE_MAX_ROWS + 4:
		rows.append({"name": "fn_%d" % i, "time": "1.0 ms", "calls": "10"})
	var report: String = Perf.format_profile([{"name": "Script Functions", "time": "20 ms", "rows": rows}])
	_check(report.begins_with("Script Functions — 20 ms:"), "the category header carries its time")
	_check(report.contains("fn_0 — 1.0 ms (10 calls)"), "rows carry name, time, and calls")
	_check(report.contains("(+4 more rows — raise \"limit\""), "rows past the cap are counted and the limit lever named")
	_check(not report.contains("fn_%d" % (Perf.PROFILE_MAX_ROWS + 1)), "capped rows are not relayed")
	var lifted: String = Perf.format_profile([{"name": "Script Functions", "time": "20 ms", "rows": rows}], Perf.PROFILE_MAX_ROWS + 4)
	_check(lifted.contains("fn_%d" % (Perf.PROFILE_MAX_ROWS + 3)) and not lifted.contains("more rows"), "an explicit limit lifts the cap in full")
	var picked: String = Perf.format_profile([{"name": "Script Functions", "time": "20 ms", "rows": rows}], 0, "fn_%d" % (Perf.PROFILE_MAX_ROWS + 2))
	_check(picked.contains("fn_%d — 1.0 ms" % (Perf.PROFILE_MAX_ROWS + 2)), "a filter reaches a row past the cap")
	_check(picked.contains("hidden by the filter"), "the filter counts what it hid")


## The mode spellings profile_game takes and run_game's profile flag reuses; an unknown one must come back as a refusal rather than quietly running the default profiler.
func _test_profiler_modes() -> void:
	_check(Perf.profiler_mode("functions") == "functions" and Perf.profiler_mode("CPU") == "functions", "the function profiler answers to its own name and to what it measures")
	_check(Perf.profiler_mode("gpu") == "visual" and Perf.profiler_mode("Visual Profiler") == "visual", "the visual profiler answers to gpu and to its tab name")
	_check(Perf.profiler_mode("rpc") == "network" and Perf.profiler_mode("multiplayer") == "network", "the network profiler answers to what it measures")
	_check(Perf.profiler_mode("sideways") == "", "an unknown mode resolves to nothing for the caller to refuse")
	_check(String(Tools._run_profile_mode({})) == "", "run_game without the flag profiles nothing")
	_check(String(Tools._run_profile_mode({"profile": true})) == "functions", "profile: true stays the function profiler")
	_check(String(Tools._run_profile_mode({"profile": "gpu"})) == "visual", "a mode name on the flag selects that profiler")
	_check(String(Tools._run_profile_mode({"profile": "sideways"})) == "sideways", "an unknown mode name comes back verbatim for the caller to refuse, never silently dropped")
	_check(String(Tools._run_profile_mode({"profile": true, "profiler": "sideways"})) == "sideways", "a bool riding beside the unknown name neither masks it nor crashes the walk")


## The Video RAM tab's scrape and composer: the engine sends the list already sorted biggest-first, so row order is the ranking and the cap keeps the top of it.
func _test_video_ram() -> void:
	var tree := Tree.new()
	tree.columns = 4
	var root := tree.create_item()
	var rows_in: Array = [
		["res://art/atlas.png", "CompressedTexture2D", "4096x4096 RGBA8", "64.00 MiB"],
		["", "Texture2D", "1914x2105 RGB8", "11.52 MiB"],
		["res://models/tree.mesh", "Mesh", "24 Vertices", "288 B"],
	]
	for row: Array in rows_in:
		var item := tree.create_item(root)
		for c in 4:
			item.set_text(c, String(row[c]))
	var rows: Array = Perf.video_ram_rows(tree)
	_check(rows.size() == 3 and String(rows[0]["path"]) == "res://art/atlas.png", "every row is scraped, biggest first as the engine sent it")
	_check(String(rows[1]["type"]) == "Texture2D" and String(rows[1]["format"]) == "1914x2105 RGB8", "type and format come off their own columns")
	var body: String = Perf.format_video_ram(rows, "75.53 MiB", 0, "")
	_check(body.begins_with("3 resources in video memory, 75.53 MiB in total, biggest first:"), "the header carries the count and the tab's own total")
	_check(body.contains("- 64.00 MiB — res://art/atlas.png (CompressedTexture2D, 4096x4096 RGBA8)"), "a row reads usage first, then what is using it")
	_check(body.contains("(engine-internal, no resource path)"), "a pathless resource is named as internal, not printed as a blank")
	var capped: String = Perf.format_video_ram(rows, "75.53 MiB", 1, "")
	_check(capped.contains("showing the 1 largest") and capped.contains("(+2 smaller resources not shown"), "the cap keeps the biggest and counts what it dropped")
	_check(not capped.contains("tree.mesh"), "rows past the cap are not relayed")
	var filtered: String = Perf.format_video_ram(rows, "75.53 MiB", 0, "mesh")
	_check(filtered.contains("1 match \"mesh\"") and filtered.contains("tree.mesh") and not filtered.contains("atlas.png"), "the filter matches path, type, or format and says how many hit")
	var none: String = Perf.format_video_ram(rows, "75.53 MiB", 0, "shader")
	_check(none.contains("none of them match \"shader\""), "a filter matching nothing says so instead of printing an empty list")
	var empty: String = Perf.format_video_ram([], "", 0, "")
	_check(empty.contains("no resources in video memory") and empty.contains("headless"), "an empty list is explained, including the driver case that legitimately reports none")
	tree.free()


## The Visual Profiler's pass tree: the passes nest (a viewport holds canvases hold draws), so the scrape carries depth and the composer indents by it.
func _test_visual_profile() -> void:
	var tree := Tree.new()
	tree.columns = 3
	var root := tree.create_item()
	var outer := tree.create_item(root)
	outer.set_text(0, " Render Viewports")
	outer.set_text(1, "0.02 ms")
	outer.set_text(2, "0.31 ms")
	var inner := tree.create_item(outer)
	inner.set_text(0, "Render CanvasItems")
	inner.set_text(1, "0.01 ms")
	inner.set_text(2, "0.28 ms")
	var rows: Array = Perf.visual_rows(tree)
	_check(rows.size() == 2 and int(rows[0]["depth"]) == 0 and int(rows[1]["depth"]) == 1, "nesting is kept as a depth per row")
	_check(String(rows[0]["name"]) == "Render Viewports", "the engine's own leading space on a nested pass name is trimmed")
	var body: String = Perf.format_visual_profile(rows)
	_check(body.contains("CPU is the time the engine spent submitting the pass"), "the caption says what each column means")
	_check(body.contains("Frame # selector"), "the report states it is ONE frame, not an average over the capture")
	_check(body.contains("- Render Viewports — CPU 0.02 ms, GPU 0.31 ms"), "a pass carries both its CPU and GPU time")
	_check(body.contains("  - Render CanvasItems"), "a child pass is indented under its parent")
	var many: Array = []
	for i in Perf.VISUAL_MAX_ROWS + 3:
		many.append({"depth": 0, "name": "pass_%d" % i, "cpu": "0.1 ms", "gpu": "0.2 ms"})
	var long_report: String = Perf.format_visual_profile(many)
	_check(long_report.contains("(+3 deeper rows"), "rows past the cap are counted and pointed at the tab")
	_check(String(Perf.format_visual_profile([])).contains("shows no captured frame"), "an empty capture is stated, never read as a frame that cost nothing")
	tree.free()


## The Network Profiler's two tables plus the bandwidth the game reported across the window — and the single-player case, where empty tables are the expected result and must not read as a failed capture.
func _test_network_profile() -> void:
	var rpc := Tree.new()
	rpc.columns = 3
	var rpc_root := rpc.create_item()
	var node_row := rpc.create_item(rpc_root)
	node_row.set_text(0, "/root/Main/Player")
	node_row.set_text(1, "12")
	node_row.set_text(2, "34")
	var rows: Array = Perf.network_rows(rpc)
	_check(rows.size() == 1 and String(rows[0][0]) == "/root/Main/Player" and String(rows[0][2]) == "34", "a node's row keeps every column verbatim")
	var bandwidth: Array = [{"at": 1000, "in": 2048.0, "out": 512.0}, {"at": 2000, "in": 6144.0, "out": 0.0}]
	var body: String = Perf.format_network(bandwidth, rows, [])
	_check(body.contains("incoming 4.0 KB/s avg (peak 6.0 KB/s)"), "bandwidth is averaged and peaked across the capture, not read off the tab's last figure")
	_check(body.contains("outgoing 256 B/s avg"), "small rates stay in bytes per second")
	_check(body.contains("- /root/Main/Player — in 12, out 34"), "per-node RPC counts are relayed")
	var quiet: String = Perf.format_network([], [], [])
	_check(quiet.contains("reported none during the capture"), "a capture with no bandwidth report explains the once-per-second cadence")
	_check(quiet.contains("single-player project that is the expected result"), "empty tables read as the expected single-player result, not as a failure")
	var syncs: Array = [PackedStringArray(["/root/Main", "Sync", "config", "8", "1.2 KiB"])]
	var replicated: String = Perf.format_network(bandwidth, rows, syncs)
	_check(replicated.contains("- /root/Main / Sync (config) — 8 syncs, 1.2 KiB"), "replication rows carry their synchronizer and size")
	rpc.free()


## The clicked-control records behind the Misc tab: the only engine-side proof a click reached a Control, which is worthless without its age (a record from an earlier run), its window (records from before the sequence), or its full count (one step's miss hidden behind another's landing).
func _test_click_records() -> void:
	_check(Perf.format_click_record({}, 5000) == "", "no record makes no claim at all")
	var click: Dictionary = {"at": 1000, "path": "/root/Main/Play", "class": "Button"}
	var line: String = Perf.format_click_record(click, 4000)
	_check(line.contains("Button at /root/Main/Play") and line.contains("3 s ago"), "the record carries what was clicked and how long ago")
	_check(Perf.format_click_record(click, 1000).contains("just now"), "a fresh record says so rather than reporting 0 s")
	var landed: String = Perf.format_click_result([click], 1)
	_check(landed.contains("landing on Button at /root/Main/Play"), "a click recorded during the sequence is reported as engine truth that the pointer reached a Control")
	_check(landed.contains("not that the control acted on it"), "the claim stops where the evidence does")
	_check(not landed.contains("No control click has been reported"), "a full tally earns no shortfall note")
	_check(Perf.format_click_result([], 2).contains("landed on empty space"), "no record at all names the failure it most likely was")
	var second: Dictionary = {"at": 1500, "path": "/root/Main/Quit", "class": "Button"}
	var both: String = Perf.format_click_result([click, second], 2)
	_check(both.contains("2 control clicks") and both.contains("/root/Main/Play, then Button at /root/Main/Quit"), "every click in the window is listed in order, never the newest alone")
	var shortfall: String = Perf.format_click_result([click], 3)
	_check(shortfall.contains("landing on Button at /root/Main/Play") and shortfall.contains("No control click has been reported for the other 2 pointer step(s)"), "steps whose clicks reached nothing are counted beside the one that landed")
	_check(shortfall.contains("still queued"), "the shortfall owns the reports' once-per-second drain instead of claiming a definitive miss")
	var surplus: String = Perf.format_click_result([click, second], 1)
	_check(surplus.contains("more clicks than pointer steps") and surplus.contains("user's own mouse"), "extra clicks are attributed to the only other pointer that exists rather than claimed for the sequence")


## clicks_since and last_click read the per-session rings the debug_data hook fills; driven through an injected session keyed to a real live Node, since only a live instance id survives _live_states' pruning.
func _test_click_ring() -> void:
	var host := Node.new()
	Perf._sessions[host.get_instance_id()] = {
		"name": "Test Session", "samples": [], "custom_names": PackedStringArray(), "bandwidth": [], "vram_at": 0,
		"clicks": [
			{"at": 1000, "path": "/root/A", "class": "Button"},
			{"at": 3000, "path": "/root/B", "class": "CheckBox"},
		],
	}
	var all_clicks: Array = Perf.clicks_since(500)
	_check(all_clicks.size() == 2 and String(all_clicks[0]["path"]) == "/root/A", "clicks_since returns the window's records oldest first")
	var late: Array = Perf.clicks_since(2000)
	_check(late.size() == 1 and String(late[0]["path"]) == "/root/B", "records before the window are excluded, so an old click is never claimed for a new sequence")
	_check(String(Perf.last_click()["path"]) == "/root/B", "last_click is the ring's newest record")
	Perf._sessions.erase(host.get_instance_id())
	host.free()
	_check(Perf.clicks_since(0).is_empty(), "no sessions means no records, not an error")


func _test_refusals() -> void:
	var hook: Dictionary = Perf.ensure_connected()
	_check(int(hook["found"]) == 0, "headless finds no debugger panels to hook")
	var toggled: Dictionary = Perf.toggle_profiler("functions", true)
	_check(not bool(toggled["ok"]) and String(toggled["why"]).contains("bridge"), "an unregistered bridge is named, not worked around")
	_check(Perf.profiler_panels("visual").is_empty() and Perf.video_ram_tabs().is_empty(), "headless locates no debugger panels to read")
	var perf: Dictionary = await Tools.execute("read_performance", {})
	_check(String(perf["content"]).begins_with("Error:") and String(perf["content"]).contains("headless"), "read_performance refuses by name in a headless run")
	var profile: Dictionary = await Tools.execute("profile_game", {})
	_check(String(profile["content"]).contains("headless"), "profile_game refuses by name in a headless run")
	var bad_mode: Dictionary = await Tools.execute("profile_game", {"mode": "sideways"})
	_check(String(bad_mode["content"]).contains("not a profiler this tool can run") and String(bad_mode["content"]).contains("\"visual\""), "an unknown mode is refused with the three that exist named")
	var vram: Dictionary = await Tools.execute("read_video_ram", {})
	_check(String(vram["content"]).begins_with("Error:") and String(vram["content"]).contains("headless"), "read_video_ram refuses by name in a headless run")
	var bogus: Dictionary = await Tools.execute("read_performance", {"bogus": 1})
	_check(String(bogus["content"]).begins_with("Error:") and String(bogus["content"]).contains("seconds"), "an unrecognized argument comes back with the usage shape")
	var bogus_vram: Dictionary = await Tools.execute("read_video_ram", {"bogus": 1})
	_check(String(bogus_vram["content"]).begins_with("Error:") and String(bogus_vram["content"]).contains("limit"), "read_video_ram's unrecognized argument comes back with its usage shape")
	var catalog := String(Tools.tool_search_schema(false)["function"]["description"])
	_check(catalog.contains("read_performance") and catalog.contains("profile_game") and catalog.contains("read_video_ram"), "the performance and video-memory tools are read tools, listed even with Make changes off")


## profile_game's not-running refusal: the wild failure was a model that read "its profile flag" and launched twice without keep_running, capturing and stopping each time.
func _test_profile_no_run() -> void:
	var text := Tools._no_run_refusal("nothing to profile", "To do it in a single call instead, run_game with \"profile\": \"network\" launches the game, profiles it for the watch window and stops it. This tool also attaches to a run that is ALREADY up, including one the user started.")
	_check(text.contains("\"profile\": \"network\""), "the one-step route is spelled with its literal argument, not described")
	_check(text.contains("ALREADY up"), "and says the tool attaches to a running game, which the wild model explicitly wondered about")
	_check(text.contains("keep_running"), "while still naming the two-step route's argument")
