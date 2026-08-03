@tool
class_name GDLLMTools extends RefCounted
## Registry of chat tools, exposed to the model through the narrow-context "tool_search" pattern: only `tool_search` is ever attached to a request up front, keeping the prompt's tool footprint to a single entry. That entry always carries the catalog of registered tool names and descriptions (see _catalog), so the model can see what exists; searching a name returns that tool's full parameters (and the session attaches it to later turns), so the model pays for the verbose part of a tool's schema only once it actually wants to use it. Every method is static — this is a namespace, not an instance.

const TOOL_SEARCH := "tool_search"

# How many idle user turns retire an attached tool's schema at a cache-bust boundary (see GDLLMChatSession._cross_cache_boundary; one tool_search re-attaches it) is user-configurable — see GDLLMTunables' gdllm/context section.

## Appended to tool_search's description only once this session has actually retired something: the model needs the detachment rule only when it's real, and the note first appears in the request whose tools block the retirement already rewrote, so it never costs a cache invalidation or tokens of its own before then.
const TOOL_SEARCH_RETIREMENT_NOTE := "Note: attached tools left idle for several turns are detached again to keep requests small — if a tool you had is no longer marked attached, search its name again to re-attach it."

## What a model sees in place of a pruned tool result's output; the user-facing record (stored history, activity feed) always keeps the full output. Shared by the main chat's pass and the subagent loop's (see GDLLMChatSession._prune_tool_results and GDLLMSubagent._prune_loop_results). It names the remedy rather than only the loss: the call that produced it is still right beside it in the history, arguments intact, so re-running it is a step the model can actually take.
const PRUNED_RESULT_STAMP := "[Old tool result pruned, re-run tool if output is needed again]"

## The tool a user attachment is carried as: the user's Script and Selection toggles append the read_file call that would have produced the attached text, plus its result (see GDLLMChatSession._append_attachment_pair). A real registered tool rather than an invented name, so the pruned stamp's "re-run tool" is an action the model can actually take, the schema rides along like any other used tool, and nothing downstream needs an attachment-specific branch. Must stay a REGISTRY key.
const READ_FILE := "read_file"

## The tool a scene-tree selection attachment claims ran, named here so the session builds its call without spelling the registry key (see format_attachment_scene).
const DESCRIBE_SCENE := "describe_scene"

## Tools whose results the pruning passes never touch; tool_search stays out because schema retirement already reclaims idle tool_search attachments on its own cache-boundary schedule.
const PRUNE_GUARDED_TOOLS: Array[String] = ["tool_search"]

# How many newest tool call/result pairs the pruning passes always leave intact — the model's working set for the turn in flight — is user-configurable — see GDLLMTunables' gdllm/compaction section.

## tool_search's own definition, declared with the same fields as a REGISTRY entry. Its `description` here is only the preamble — the live catalog of registered tools is appended in tool_search_schema so the model always sees the full list.
const TOOL_SEARCH_TOOL := {
	"description": "See and use the project's tools. Every available tool is listed at the end of this description with what it does; to use one, call tool_search with its name to retrieve the tool's parameters, and it then becomes available for you to call directly on a following turn. A searched tool stays attached on later requests: anything marked \"attached\" in the list below is already in your tools with its full definition — call it directly, and never search for a tool you already have. If you're unsure which fits, pass one or two words naming the capability (e.g. \"edit file\") — a tool matches only when every word appears in its name or catalog line, so a full sentence matches nothing. This finds tools, never project files or code. Reach for a tool whenever a request needs an action beyond your own knowledge (for example, reading a project file) before deciding you cannot help.",
	"max_consecutive_uses": 3,
	"loop_break_message": "You've called tool_search several times in a row without ever using a tool it returned, so the tool loop has been stopped for you. Do not search again. In a few sentences addressed to the user, summarize what you were trying to accomplish and what you suspect went wrong — for instance the capability you needed isn't among the available tools, or your searches weren't matching it. If a novel tool would solve your problem, describe it to the user. Be concise and honest about the uncertainty.",
	"parameters": {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "The name of the tool you want to use, taken from the list in this tool's description, e.g. \"read_file\". If you're unsure which tool fits, one or two capability words (e.g. \"edit file\") also work — every word must match, so don't pass a sentence, and never pass file names or code symbols.",
			},
		},
		"required": ["query"],
	},
}

# The most tools one search returns is user-configurable — see GDLLMTunables' gdllm/context section; everything a search returns is also activated onto every later turn (see execute), so that cap bounds what a single vague query can permanently attach to the conversation.

## The searchable tools, keyed by name, omitting `tool_search`. Each entry carries a one-line `summary` shown in the always-visible catalog (see _catalog), the fuller `description` returned when the tool is searched, the JSON-Schema `parameters` the model fills in to call it, `max_consecutive_uses` — its loop break point (see max_consecutive_uses) — and optionally a tailored `loop_break_message` shown when that guard trips (see loop_break_message; omit it to fall back to the generic default).
const REGISTRY := {
	"read_file": {
		"summary": "Read a text file from the project; a file past {tunable:read_file_summary_threshold_chars} chars comes back as a summarized function map (when that threshold is enabled) and a .tscn as its saved node tree instead of full text (pass full=true to force the whole file).",
		"description": "Read a UTF-8 text file (GDScript, scenes, config, JSON, docs, and so on) from the current Godot project. Short files are returned in full. While the long-file threshold is enabled ({tunable:read_file_summary_threshold_chars} chars; 0 disables it), a file beyond it is not dropped into the conversation whole — a fresh-context subagent maps it instead, returning an overview plus every function's name and parameters, so you can then use read_function to pull the actual code of a specific function when you need it. A .tscn scene likewise returns its saved node tree rather than the serialized text, at a fraction of the cost — describe_scene_file with node_path then zooms into one node's saved properties, connections, and groups. Set `full` to true to override either and get the entire file verbatim even when it is long — for the rare case you genuinely need every line rather than a map; expect it to consume much more of your context. Long packed-array data blobs in a .tres/.tscn (PackedByteArray image data, PackedVector3Array mesh vertices, and so on) are elided to markers like \"<N bytes elided>\" in every DEFAULT read, since raw serialized numbers carry no readable information; `full: true` is the one route to them — it returns the file verbatim, payloads included, which is what a wholesale rewrite of such a file needs (expect elided payloads to be large). Binary files are refused. Reading a .gd file or a .gdshader also compile-checks it with the engine automatically: any current parse/compile errors are appended to the result, and nothing is appended when the file is clean.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file, e.g. \"res://player.gd\" or \"project.godot\". A bare name — or a path whose directories turn out to be wrong — is matched by exact file name across the project; if several files share the name, the call fails and lists them so you can pass the full path of the one you mean.",
				},
				"full": {
					"type": "boolean",
					"description": "Set true to return the whole file even if it is long, skipping the summarized function map and the .tscn saved-tree view. Omit (or false) to let long files and scenes be mapped when the length threshold is enabled — the default that keeps your context narrow. Only ask for the full text when a map genuinely won't do (editing a .tscn's serialized text is the usual reason).",
				},
				"start_line": {
					"type": "integer",
					"description": "Optional 1-based first line of a range to read. A ranged read returns exactly that region verbatim — even from a long file that would otherwise be mapped — so it is the narrow way to pull a specific region (e.g. the top-level declarations a map's line numbers point at).",
				},
				"end_line": {
					"type": "integer",
					"description": "Optional 1-based last line of the range (inclusive); defaults to the end of the file when only start_line is given.",
				},
			},
			"required": ["path"],
		},
	},
	"read_function": {
		"summary": "Read the full body of one named function from a GDScript file — the narrow follow-up when a search excerpt or file map isn't enough.",
		"description": "Return the complete source of a single named function from a GDScript file in the project, header through last line. Use this when search_files or a read_file map points you at a function and you need its whole body: it pulls exactly that function instead of the entire file, keeping your context narrow. If the name isn't found, the file's actual function names are listed so you can correct it.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the GDScript file, e.g. \"res://player.gd\" or \"player.gd\". A bare name is searched for across the project.",
				},
				"name": {
					"type": "string",
					"description": "The function's name as written after \"func\", e.g. \"_ready\" or \"add_item\".",
				},
			},
			"required": ["path", "name"],
		},
	},
	"check_script": {
		"summary": "Compile-check one GDScript file or .gdshader with the engine's own compiler and get the actual errors with line numbers, or a clean bill — engine truth for \"does this compile?\".",
		"description": "Run the engine's own compiler over one .gd script or one .gdshader (headlessly — a script with the project's autoloads registered so gameplay code compiles for real, a shader through the same shading-language compiler the renderer uses) and return the real errors it reports with their line numbers, or confirm the file compiles cleanly. This is engine truth, not a guess: use it when the user says a script or shader is broken, when something outside your own editing tools may have changed one, or to confirm that an error you were shown is gone. You rarely need it right after your own edit_file/write_file calls — those already validate .gd and .gdshader content and report the errors a change introduced — and reading either via read_file flags its current errors automatically. Errors that surface in OTHER files while the project loads (a broken autoload, another plugin) are not blamed on the checked file. Two things differ for a shader: the compiler stops at the FIRST error, so a clean result after a fix is the only proof there was just one, and an error inside an #include'd file is reported naming that file and its line, since that is where the fix goes. Scenes and resources are validated by the tools that write them, and a .gdshaderinc cannot be checked alone — the engine only compiles one as part of a shader that includes it.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the .gd script or .gdshader to check, e.g. \"res://player.gd\" or \"water.gdshader\". A bare name is searched for across the project.",
				},
			},
			"required": ["path"],
		},
	},
	"read_output": {
		"summary": "Read the editor's Output console — the log panel the user sees, including a running game's prints and errors; returns the newest lines, optionally filtered.",
		"description": "Read the editor's Output console (the bottom Output panel) — the same log the user is looking at, which is where print output, warnings, and errors from both the editor and a running game land. Use it when the user refers to something \"in the console\", \"in the output\", or \"in the log\", or to see what a run just printed. Returns the newest lines (default {tunable:console_default_output_lines}, no cap on an explicit ask); pass `lines` for more or fewer, or `filter` to return only lines containing a substring (case-insensitive), still newest-last. The text is read from the panel itself, so what it currently shows is what you get: a console the user cleared reads as empty, and lines hidden by the panel's own search box or message-type filter buttons are not readable here — when such a control is actively hiding a message type (some users keep the panel's Errors filter off), the result names it, so trust that note over assuming the console holds everything. For the structured error history of game runs — stack traces included — use read_errors instead.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"lines": {
					"type": "integer",
					"description": "Newest lines to return. Defaults to {tunable:console_default_output_lines} with no cap — raise it freely when you need more of the log.",
				},
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring; only lines containing it are returned (the newest of those, up to `lines`).",
				},
			},
			"required": [],
		},
	},
	"read_errors": {
		"summary": "Read the debugger's Errors tab — the error and warning history of game runs, stack traces included.",
		"description": "Read the error history from the debugger's Errors tab: every error and warning recorded from running the project in this editor session, oldest first, each with its time, message, and detail rows — the engine-side error and source line, and the script stack trace when one was captured. A running game is a separate process whose errors arrive over the debugger and land ONLY here, so this is the tool for \"why did my game error?\". Returns the newest entries (default {tunable:console_default_error_entries}, no cap on an explicit ask); pass `limit` for more or fewer, or `filter` to return only entries whose text contains a substring (case-insensitive). The history is read from the panel itself, so a list the user cleared reads as empty. Errors raised inside the editor process (plugins, tool scripts, importers) do not appear here — they land in the Output console, which read_output shows. Any uid:// the entries mention is resolved against the engine's uid registry automatically.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"limit": {
					"type": "integer",
					"description": "Newest error entries to return. Defaults to {tunable:console_default_error_entries} with no cap — raise it freely when you need more of the history.",
				},
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring; only entries whose text (time, message, or detail rows) contains it are returned.",
				},
			},
			"required": [],
		},
	},
	"run_game": {
		"summary": "Run the game — the main scene, or one scene — through the editor's own Play machinery and capture what it prints and errors while it runs; stops it after wait_seconds unless keep_running is set.",
		"description": "Launch the project the way the user's F5 does — the editor's own Play machinery, a separate game process whose prints and errors arrive over the debugger — then watch it for `wait_seconds` (default {tunable:run_game_default_wait_seconds}, capped at {tunable:run_game_max_wait_seconds}) and return what arrived during the run: the NEW Output-console lines and the NEW debugger error entries since launch, never the whole log. By default the run is then stopped, so one call is a self-contained smoke run: launch, capture, stop. Pass `scene` to play one scene instead of the main scene (the editor's Play Custom Scene), and `keep_running` true to leave the game up for the user to drive after the capture returns — stop_game ends that run later, and read_output/read_errors keep reading its console while it lives. A run the USER started is never touched: if a game is already playing, the call refuses rather than hijacking it. The game runs the project as saved on disk; the editor's save-before-running setting decides whether unsaved editors are saved first, and the result notes when that setting is off while unsaved scenes exist. The capture also carries a one-line performance digest (FPS, frame time, draw calls, memory, nodes) from the game's monitor stream, and `profile` true additionally runs the engine's function profiler for the window and reports the hottest functions (read_performance and profile_game do both against an already-running game). A run that PAUSES in the debugger — a runtime error, or a line set_breakpoint armed — ends the watch early and the result details the break (stack and variables); to then step or resume it with debug_game the game must still be up, so pass keep_running true when a pause is the point. For headless logic verification with no game window, use run_script instead.",
		"max_consecutive_uses": 3,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "Optional res:// path (or uid://, or bare file name) of the .tscn/.scn to play, as the editor's Play Custom Scene does. Omit to play the project's main scene.",
				},
				"wait_seconds": {
					"type": "integer",
					"description": "How long to let the run play before its output is captured, in seconds. Defaults to {tunable:run_game_default_wait_seconds}, capped at {tunable:run_game_max_wait_seconds}.",
				},
				"keep_running": {
					"type": "boolean",
					"description": "Set true to leave the game running for the user after the capture returns instead of stopping it; stop_game ends it later.",
				},
				"profile": {
					"type": "boolean",
					"description": "Set true to also run the engine's function profiler for the watch window and include the hottest functions in the capture; pass \"visual\" or \"network\" instead of true to run that profiler for the window (GPU cost per render pass, or RPC traffic and bandwidth). The editor's matching Debugger tab shows the full data.",
				},
				"show": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Debug overlays to draw in this run, as the editor's Debug menu does: \"collisions\" (every collision shape and contact point), \"navigation\" (navigation meshes and links), \"paths\" (Path2D/Path3D curves), \"avoidance\" (avoidance agent radii), \"redraw\" (flash CanvasItems as they redraw). Only this run is affected — the user's own Debug menu checkboxes are put back exactly as they were.",
				},
			},
			"required": [],
		},
	},
	"suspend_game": {
		"summary": "Freeze the running game between frames, advance it one frame at a time, or let it run again — the engine's own scene suspension, where the game stays fully readable while nothing moves.",
		"description": "Stop the RUNNING game's clock without stopping the game: `action` is \"on\" (freeze it where it is), \"off\" (let it run again), or \"frame\" (advance exactly `frames` frames and freeze again, auto-freezing first if it was running). Suspended, the game draws the same frame forever and no _process, _physics_process or animation advances — but it is still ALIVE and answering, so read_game_ui, inspect_game_node, call_game_method, read_performance and read_video_ram all work normally on it. That is what makes it the tool for anything that happens too fast to watch: freeze, look at the state, advance one frame, look again — a moving-target bug becomes a series of still frames. This is NOT the debugger's break (debug_game): nothing is stopped at a line of code, there is no call stack, and the game resumes with no execution state disturbed — it is the pause between frames, not inside them. It is also not the game's OWN pause (SceneTree.paused, which read_game_ui reports as PAUSED): a pause menu still processes nodes set to run while paused, where this stops everything. Input cannot be played into a suspended game (the playback needs frames to run in), so send_game_input refuses until it is resumed. Needs a running game — run_game with keep_running true starts one — and a run that ends drops the suspension with it.",
		"max_consecutive_uses": 15,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"action": {
					"type": "string",
					"description": "\"on\" to freeze the game, \"off\" to let it run again, or \"frame\" to advance a few frames and stay frozen.",
				},
				"frames": {
					"type": "integer",
					"description": "How many frames \"frame\" advances, 1 to {tunable:suspend_max_frames} (default 1). Each frame is one full iteration: input, _process, physics, and a draw.",
				},
			},
			"required": ["action"],
		},
	},
	"inspect_game_node": {
		"summary": "Read the live state of one node in the running game — every variable its own script declares, with current values, in one call.",
		"description": "Dump what the node at `path` is actually holding inside the RUNNING game: the variables its own script declares — health, velocity, inventory, the state machine's current state — with their live values, plus where the node sits in the world and on screen. This is the answer to \"what is this thing actually doing right now\", and it needs no guessing: call_game_method's get returns one property whose name you already knew, while this returns the names WITH the values, so a node whose script you have never read is still fully readable. Nested state (a dictionary of slots holding item data) comes back nested, not summarized — read the values here rather than making a call per entry. The engine's own properties (position, collision layers, modulate, and the hundred-odd others ClassDB documents) are COUNTED rather than listed, so they cannot bury the state that matters: pass `all` true to list them, or `filter` with part of a property name to reach one by name — a filter searches the script's variables and the engine's together. Values are display data for this conversation: a Node prints as its class and live path (feed that path straight back in), other Objects as their description, and a very long value clips with the remainder counted. Works on a live run and on a SUSPENDED one (suspend_game), which is the pair that reads state at an exact frame; a game PAUSED at a breakpoint cannot answer — read_game_break has the stopped frame's own locals and members instead. read_game_ui with \"all\": true lists the paths to inspect.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The live node path to inspect, e.g. \"/root/Main/Player\" — read_game_ui lists exact paths.",
				},
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring; only properties whose name contains it are reported, e.g. \"velocity\" or \"collision\". Searches the script's variables and the engine's together. A filter also CONCENTRATES the report's size budget on what it matches, so filtering by one property's name is how to get a big value — a long inventory or state dictionary — in full when the whole-node dump had to clip it.",
				},
				"all": {
					"type": "boolean",
					"description": "Set true to also list the engine's own properties (position, collision layers, modulate, …), which are otherwise counted and left out so they cannot bury the script's state.",
				},
			},
			"required": ["path"],
		},
	},
	"reload_game_scripts": {
		"summary": "Push edited .gd files into the running game without restarting it — the game keeps its current state and starts running the new code.",
		"description": "Hot-reload scripts into the RUNNING game: the files are re-read from disk and every live instance swaps to the new code, keeping the state it has already built up — the fix applies to the game as it stands, with no restart and no replaying whatever it took to get there. With no arguments it reloads every .gd file changed since the run started (they are listed in the result); pass `paths` to reload specific ones. Only a run started by run_game can take this: hot reload has to be armed when the process launches (run_game arms it for every run it starts), and pushing a reload into a run launched without it silently does NOTHING — the change never arrives, the game keeps running as though nothing happened, and for some scripts the node running them stops processing (all measured) — so a run this session did not start is refused unless the user's own Debug menu has both Synchronize Scene Changes and Synchronize Script Changes ticked. What the reload prints or errors comes back in the result: a script that fails to compile reports there. Changes to scene files, autoloads and class definitions are not covered — those need a fresh run_game.",
		"max_consecutive_uses": 4,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"paths": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Optional res:// paths (or bare file names) of the .gd files to reload. Omit to reload everything changed since the run started.",
				},
			},
			"required": [],
		},
	},
	"stop_game": {
		"summary": "Stop the game run_game left running and capture what it printed and errored since that call's capture.",
		"description": "End the play session a previous run_game with keep_running left up, returning the Output lines and debugger error entries that arrived since that call's capture, plus the run's total time. This only stops a run this session itself started: a game the user launched (or a run predating an editor reload) is refused, because the user's play session is theirs to end — ask them to press the editor's Stop button instead. When nothing is running it says so plainly.",
		"max_consecutive_uses": 3,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {},
			"required": [],
		},
	},
	"run_script": {
		"summary": "Execute one .gd script headlessly with the engine and return its exit code and output — actual execution, where check_script only compiles.",
		"description": "Run one GDScript file for real in a fresh headless engine subprocess against this project (godot --headless --script) and return its exit code plus everything it printed — the execution counterpart to check_script's compile-only check, for verifying logic without popping a game window. The script must extend SceneTree (or MainLoop): the engine calls its _init, iterates frames, and the run ends when the script calls quit(exit_code) — the shape this project's tools/ suites use, with a nonzero exit signalling failure. The project's autoloads register as script globals after _init and before the first process frame, so code touching them should run from a first-frame step (e.g. process_frame.connect(..., CONNECT_ONE_SHOT)), not _init. Pass `args` (an array of strings) to hand the script arguments, readable via OS.get_cmdline_user_args(); pass `timeout_seconds` (default {tunable:run_script_default_timeout_seconds}, capped at {tunable:run_script_max_timeout_seconds}) when a run legitimately needs longer — a script still running at the timeout is killed and reported as killed, so a script that never quits can't park the loop. To run the actual game or a scene, use run_game.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the .gd to execute, e.g. \"res://tools/my_check.gd\". It must extend SceneTree (or MainLoop) and end by calling quit().",
				},
				"args": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Optional string arguments passed to the script after \"--\"; it reads them with OS.get_cmdline_user_args().",
				},
				"timeout_seconds": {
					"type": "integer",
					"description": "Wall-clock cap on the run, in seconds; a script still running at the cap is killed. Defaults to {tunable:run_script_default_timeout_seconds}, capped at {tunable:run_script_max_timeout_seconds}.",
				},
			},
			"required": ["path"],
		},
	},
	"read_performance": {
		"summary": "Read the running game's Performance monitors — FPS, frame time, memory, draw calls, nodes, physics, plus any custom monitors — as engine-truth numbers sampled about once per second.",
		"description": "Read the real Performance monitors of the running game: FPS, frame and physics time, static and video memory, object/node/orphan counts, draw calls and primitives, physics bodies and collision pairs — the same numbers behind the editor's Debugger → Monitors tab, received as raw values over the debugger, not read off a widget. The game streams them about once per second whenever it runs — a run the USER started with F5 is sampled exactly the same, so you can watch their play session without touching it. Each monitor is reported as avg/min/max over a window (`seconds`, default {tunable:performance_default_window_seconds}, max {tunable:performance_history_seconds}), constants collapse to one figure, and numbers from a game that already stopped are labelled with their age rather than passed off as live. Pass `all` true for every built-in monitor instead of the curated set. Custom monitors the game registers with Performance.add_custom_monitor(\"category/name\", callable) appear here automatically about a second later — add one via the editing tools when a task needs to measure something specific (an entity count, a queue length, a system's cost), run the game, and read the real numbers back. For per-function cost use profile_game; for a launch-and-measure smoke run use run_game, whose capture includes a performance digest.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"seconds": {
					"type": "integer",
					"description": "Window to summarize over, in seconds. Defaults to {tunable:performance_default_window_seconds}, capped at {tunable:performance_history_seconds} (about how much history is kept).",
				},
				"all": {
					"type": "boolean",
					"description": "Set true to report every built-in monitor (all 59, by their engine names) instead of the curated set.",
				},
			},
			"required": [],
		},
	},
	"profile_game": {
		"summary": "Run one of the engine's profilers on the live game for a few seconds — per-function CPU cost, per-pass GPU cost, or network RPC traffic — engine truth for \"what is actually slow?\".",
		"description": "Sample the running game with the engine's own profilers — the same ones the Debugger tabs' Start buttons drive, so the user watches the capture fill that tab live — for `seconds` (default {tunable:profile_game_default_seconds}, max {tunable:profile_game_max_seconds}), then switch it off again and report what it recorded. `mode` picks which profiler: \"functions\" (the default; the Profiler tab's hottest rows — frame/physics/script categories with each function's time and call count), \"visual\" (the Visual Profiler tab: one frame's render passes, each with the CPU time the engine spent submitting it and the GPU time the card spent on it — the only measurement here that sees the GPU at all, where function cost cannot), or \"network\" (the Network Profiler tab: bandwidth in and out across the capture plus per-node RPC counts and MultiplayerSynchronizer traffic — empty by design in a single-player project). Works on any live session, including one the user started with F5 (the result says whose run was profiled; profiling adds some overhead while it samples and is always turned off afterward). The full capture stays in its tab for the user to explore. Needs a running game — run_game's `profile` launches, profiles, and stops in one step, and takes a mode name too; read_performance reads the frame-level monitors instead, and read_video_ram answers what is HOLDING video memory rather than what is spending frame time.",
		"max_consecutive_uses": 3,
		"parameters": {
			"type": "object",
			"properties": {
				"seconds": {
					"type": "integer",
					"description": "How long the profiler samples the game before reporting, in seconds. Defaults to {tunable:profile_game_default_seconds}, capped at {tunable:profile_game_max_seconds}.",
				},
				"mode": {
					"type": "string",
					"description": "Which profiler to run: \"functions\" (default, per-function CPU cost), \"visual\" (per-render-pass GPU and CPU cost of one frame), or \"network\" (per-node RPC counts and bandwidth).",
				},
				"limit": {
					"type": "integer",
					"description": "How many report rows to show (default {tunable:profile_function_rows} for functions, {tunable:profile_network_rows} for network, {tunable:profile_visual_rows} for visual). Raise it when the truncation note says rows were withheld — an explicit ask is honored in full.",
				},
				"filter": {
					"type": "string",
					"description": "Substring to match report rows by name (function, render pass, or node), case-insensitive — the way to one specific row's cost when it isn't in the top rows.",
				},
			},
			"required": [],
		},
	},
	"read_video_ram": {
		"summary": "List what the running game holds in video memory, biggest first — the engine's own per-resource VRAM accounting, with the total.",
		"description": "Ask the RUNNING game what it has in video memory and report the biggest consumers: each resource's path, type, format (a texture's dimensions and pixel format, a mesh's vertex count) and its usage, plus the total — the answer to \"why is this game using 2 GB of video memory\", which nothing else here can give (read_performance's video-memory monitor reports only the one total figure). The read presses the Debugger → Video RAM tab's own Refresh button and waits for the game's reply, so the user watches the same list fill in front of them, and rows come back in the engine's own biggest-first order: `limit` caps how many are listed (default {tunable:video_ram_default_rows}, max {tunable:video_ram_max_rows}) and `filter` keeps only rows whose path, type, or format contains it. Resources with no res:// path are the engine's own internal ones (render targets, default textures) and are named as such. Works on any live session, including one the user started with F5, and a game PAUSED at a breakpoint answers this too — so it reads what was in video memory at the moment of a failure, where profile_game needs a running game. Needs a running game — run_game with keep_running true starts one — and a frozen one that never answers is said to have never answered, rather than its previous list being passed off as current.",
		"max_consecutive_uses": 3,
		"parameters": {
			"type": "object",
			"properties": {
				"limit": {
					"type": "integer",
					"description": "How many of the largest resources to list. Defaults to {tunable:video_ram_default_rows}, capped at {tunable:video_ram_max_rows}.",
				},
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring; only resources whose path, type, or format contains it are listed, e.g. \"res://textures\" or \"Mesh\".",
				},
			},
			"required": [],
		},
	},
	"read_game_ui": {
		"summary": "Find and map nodes in the running game: locate one by name, class or label anywhere in the tree, or list what is on screen with rects, world and screen positions — the target list for send_game_input, inspect_game_node and call_game_method.",
		"description": "Snapshot the RUNNING game's node tree over the editor's debugger — the live truth of what is on screen right now, not the scene file. To LOCATE something, pass `filter`: a case-insensitive substring matched against every node's name, class and displayed label, across the whole walk regardless of type, so \"Player\" finds the player node wherever it lives and \"Load Game\" finds the button that says it. Reach for that first in any real game: an unfiltered walk spends its row budget on the first nodes in tree order, which in a loaded scene of hundreds is never the one being looked for. Controls come back with their node path, class, text, window position and size (mapped through SubViewportContainer chains, so the numbers feed straight into send_game_input's mouse steps; a control whose viewport has no window position keeps local coordinates behind an explicit marker) and whether they are hidden, disabled, or focused. With `all` true every node is listed, and the gameplay nodes carry WHERE THEY ARE: a Node2D's world position plus the screen point it maps to, a Node3D's world position plus where the scene's active camera projects it (or that it is behind the camera), with rotation and scale when they are not the default — so \"is the enemy off screen\", \"did the player actually move\" and \"do these two overlap\" are answerable without calling get on one property at a time. The header also carries the current scene, pause state, and where keyboard focus sits, and a Controls-only walk names how many non-Control nodes it passed over. Works against any run attached to the editor, including one the user started with F5, and against a suspended one (suspend_game), which is how a moving scene is read one frame at a time. Pass `path` to scope the walk to one subtree — rows past the cap are dropped with a count, and scoping is the lever for more. Needs the game agent inside the run: the plugin registers the GDLLMGameAgent autoload (the Register Game Input Agent setting), and a game launched before that registration existed must be stopped and run again. describe_scene reads the EDITED scene in the editor; this reads the one actually playing, and inspect_game_node opens up any single node it lists.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring matched against every node's name, class and displayed label, anywhere under the walk — {\"filter\": \"Player\"} finds the player wherever it lives, {\"filter\": \"Button\"} every button, {\"filter\": \"Load Game\"} the control that says it. This is how to LOCATE a node in a big tree: without it the row cap is spent on the first nodes in walk order, so a deep node is unreachable unless its path is already known.",
				},
				"path": {
					"type": "string",
					"description": "Optional node path to scope the snapshot to one live subtree, e.g. \"/root/Main/UI\". Omit to walk the whole tree from /root.",
				},
				"all": {
					"type": "boolean",
					"description": "Set true to list every node (any class), not only Controls — the way to map gameplay nodes. A filter already searches every node, so this is for unfiltered walks.",
				},
			},
			"required": [],
		},
	},
	"send_game_input": {
		"summary": "Play real input into the running game — InputMap actions, keys, typed text, mouse clicks at coordinates or on a control by path — and capture what it printed and errored while the sequence played.",
		"description": "Drive the RUNNING game with a bounded sequence of real inputs, played inside the game process through Input.parse_input_event — an action step presses whatever the game's own InputMap binds to that action, so event handlers (_input, _gui_input) and polling code (Input.is_action_pressed) both see exactly what a player's hardware would produce. Each step is ONE of: {\"action\": \"jump\"} (an InputMap action; optional \"hold\" seconds before release), {\"key\": \"Space\"} (a key by name), {\"text\": \"hello\"} (typed into whatever has keyboard focus), {\"click\": \"/root/Menu/StartButton\"} (a real mouse move-press-release at that control's center — read_game_ui lists exact paths; a hidden or disabled control is refused by name, and a control drawn on top of the target would receive the click instead; controls inside SubViewportContainer-hosted SubViewports are clicked through the same forwarding chain the player's cursor uses, stretch factors included; the user's REAL mouse cursor is never moved — a small overlay cursor inside the game shows where the synthetic pointer went, and a plain click lands atomically, while a pointer step with \"hold\" spans real time and can be contested by the user's own mouse activity over the game), {\"mouse\": [x, y]} (a click at window coordinates — the same coordinates read_game_ui's rects report, so its numbers can be clicked directly; optional \"button\": \"left\"/\"right\"/\"middle\"), or {\"wait\": 0.5} (idle seconds; also combinable with any input step as a trailing settle, e.g. {\"click\": ..., \"wait\": 1.0}). One call plays at most 20 steps / about 10 seconds, then reports what actually played — steps completed, any step that stopped the sequence, where keyboard focus ended — plus the NEW Output lines and debugger errors that arrived while it played, the same capture run_game returns. The game keeps running afterwards; read_game_ui shows the resulting screen and stop_game ends a run this session started. Driving the user's own F5 session is allowed and always disclosed in the result. Needs a running game (run_game with keep_running true starts one) with the game agent inside it (a run predating the agent's registration must be restarted).",
		"max_consecutive_uses": 6,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"steps": {
					"type": "array",
					"items": {"type": "object"},
					"description": "The input steps, in order; each holds one input (action/key/text/click/mouse/wait, optional hold). A single step may also be passed directly as the call's arguments, without the array.",
				},
			},
			"required": [],
		},
	},
	"call_game_method": {
		"summary": "Call one method on one live node of the running game and get the return value back — engine truth from inside the playing game; get/set reach properties.",
		"description": "Call `method` on the node at `path` inside the RUNNING game, with optional `args` (JSON values — strings, numbers, booleans, arrays, dictionaries), and return the result plus any NEW Output lines and debugger errors the call produced — a script error from a bad call lands in that capture, never in silence. Properties are reached through the built-in get/set methods (method \"get\" with args [\"position\"], or \"set\" with args [\"visible\", false]), and anything the node's scripts could do is reachable — which is why this rides the Make changes toggle. read_game_ui (with all true) maps live node paths. The returned value is display data for this conversation only: a Node comes back as its class plus live path (feed that path straight back into another call), any other Object as its string description, and long values are clipped. A `set` reaches only the LIVE object in the running game: no project file changes, so the value lasts as long as the run does (unless the game's own saving writes it out) and a fresh run starts from what the code says. To change how the game BEHAVES in a way that outlives the run, edit the script and push it in with reload_game_scripts — which is also the pair to reach for together, since a reload replaces code but leaves already-initialized variables holding their current values, and a `set` is what moves those. Needs a running game with the game agent inside it, like the other game-driving tools; driving the user's own session is allowed and always disclosed.",
		"max_consecutive_uses": 6,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The live node path to call into, e.g. \"/root/Main/Player\" — read_game_ui lists exact paths.",
				},
				"method": {
					"type": "string",
					"description": "The method name to call on that node; \"get\"/\"set\" reach its properties.",
				},
				"args": {
					"type": "array",
					"description": "Optional arguments for the call, as JSON values in parameter order.",
				},
			},
			"required": ["path", "method"],
		},
	},
	"read_game_break": {
		"summary": "Read the state of a game paused in the debugger: what stopped it (breakpoint or runtime error), the GDScript call stack, and the frame's local and member variables.",
		"description": "Read the RUNNING game where it is paused: what stopped it — a breakpoint, a breakpoint statement, or a runtime error with its message — the GDScript call stack innermost-first (file, line, function), and the paused frame's variables: its locals, the members of self, and its globals on request. These are the real values at the moment execution stopped, which nothing else can reach: call_game_method reads a node's properties later, prints only show what a print was written for, and read_errors gives an error's stack without the state behind it. A game pauses on its own when a script hits a runtime error, or at a line set_breakpoint armed. Pass `frame` to report a caller instead of the innermost frame — the debugger's own Stack Frames list is selected, so what the user sees matches what comes back; without it the frame the list currently has selected is reported, so a selection the user moved by hand is followed, never fought — and `all` true to include globals (autoloads and named globals, otherwise counted and skipped since they are reachable by name anyway). Pass `filter` with part of a variable's name to print just the matching variables with their values WHOLE — the route to a variable the capped report dropped or a value it clipped, and nothing else can reach paused state. An error break offers no stepping (the engine forbids it) and the result says so; a break with no GDScript stack at all — what pausing from the editor between frames catches — is stated rather than reported as an empty stack. This reads and never resumes: debug_game steps or continues. While the game is paused every other game tool refuses, so a paused run is either stepped through or resumed.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"frame": {
					"type": "integer",
					"description": "Stack frame to report variables for: 0 is where execution stopped, 1 its caller, and so on, as numbered in the stack this tool prints. Omitted, the frame the debugger currently has selected is reported — frame 0 right after a break, unless the selection was moved by hand or by an earlier call.",
				},
				"all": {
					"type": "boolean",
					"description": "Set true to list the frame's globals (the project's autoloads and named globals) as well as its locals and members.",
				},
				"filter": {
					"type": "string",
					"description": "Substring to match variable names, case-insensitive. Matching variables print their values WHOLE — no length clip — and globals are searched without `all`, so this is the route to a variable past the report's caps or a value too long for it. Omit for the standard capped report.",
				},
			},
			"required": [],
		},
	},
	"debug_game": {
		"summary": "Break into a running game, or resume and step one that is paused — break, continue, step into, step over, step out — and get back where it stopped, with that frame's variables.",
		"description": "Drive execution through the debugger's own controls. On a RUNNING game, `action` \"break\" halts it at the next GDScript statement it executes, wherever that is — the way to catch a game in the act without knowing which line to suspect, where set_breakpoint needs a line chosen in advance; the result reports the stack and variables exactly as read_game_break does. On a PAUSED game, `action` is \"continue\" (resume until the next breakpoint or the end), \"step\" (into the next call), \"next\" (over the next line, staying in this function), or \"out\" (finish this function and stop in its caller). `times` repeats a step up to {tunable:debug_game_max_steps} times in one call, so watching a few lines evolve is one tool round and not one round per line; the result traces where each press landed and then reports the final break, plus anything the game printed or errored on the way. A runtime-error break cannot be stepped — the engine reports it as not steppable and only \"continue\" is offered, which resumes with the failed function abandoned. Resuming a game nobody is watching just runs it on: what stops it again is another breakpoint or another error, and if nothing does, the result says it is running rather than pretending it paused. A break stops the game INSIDE code, with a call stack and no other game tool able to reach it; suspend_game instead freezes it BETWEEN frames, where the whole game stays readable — reach for that one to look at live state, and this one to look at executing code.",
		"max_consecutive_uses": 8,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"action": {
					"type": "string",
					"description": "One of \"break\" (halt a running game at its next statement), \"continue\" (resume), \"step\" (into the next call), \"next\" (over the next line), or \"out\" (out to the caller).",
				},
				"times": {
					"type": "integer",
					"description": "How many times to repeat a step/next/out press, 1 to {tunable:debug_game_max_steps} (default 1). Ignored for \"continue\", which happens once.",
				},
				"all": {
					"type": "boolean",
					"description": "Set true to include the resulting frame's globals in the state it reports, as read_game_break's own `all` does.",
				},
			},
			"required": ["action"],
		},
	},
	"set_breakpoint": {
		"summary": "Arm or clear a breakpoint on one line of a script, through the editor's own gutter — the running game and every later run stop there.",
		"description": "Arm a breakpoint on `line` of the script at `path` so execution PAUSES there, or clear it with `remove` true. The line is armed through the editor's own script gutter: the script is opened, the breakpoint appears in its gutter and in the debugger's Breakpoints list exactly as one the user clicked, it reaches a game already running, and the next run gets it too. `line` is 1-based, the same numbering read_file and check_script report, and the result quotes the line's text back so a number counted wrong is visible immediately; a blank or comment line is armed but named as one that can never be hit, and a script with unsaved editor changes is flagged because then disk line numbers and buffer line numbers are different things. When the game reaches the line it pauses: read_game_break reads the stack and that frame's variables, debug_game steps or resumes, and every other game tool refuses until it moves. A breakpoint persists across editor restarts, so one left behind silently freezes the user's next run — the result lists what this session has armed, and clearing them when the question is answered is part of the job.",
		"max_consecutive_uses": 6,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The script to break in: a res:// path or a bare file name, e.g. \"res://player.gd\" or \"player.gd\".",
				},
				"line": {
					"type": "integer",
					"description": "The 1-based line to pause on — the numbering read_file shows. Pick a line that executes; a blank or comment line never fires.",
				},
				"remove": {
					"type": "boolean",
					"description": "Set true to clear that breakpoint instead of arming it. With no `line`, clears every breakpoint this session armed in that script; with no `path` either, clears all of them.",
				},
			},
			"required": [],
		},
	},
	"list_directory": {
		"summary": "List the files and subdirectories inside a directory (the project root by default).",
		"description": "List the immediate files and subdirectories inside one directory of the current Godot project — the project root by default, or the directory named by `path` — so its contents can be added to the conversation as context. Subdirectories are shown with a trailing \"/\"; call again with one of them as `path` to look inside it. Godot's sidecar files are folded away with a count rather than listed: a \".import\" or \".uid\" beside the file it belongs to carries nothing about the directory's contents (an asset's uid comes from read_file on the ASSET, and its import settings from set_import_setting), and in an asset folder they are otherwise most of what you would read. A sidecar whose owning file is NOT present is shown normally — that one is an orphan left behind by a delete, which is real information — and a directory holding only sidecars lists them, so nothing is ever hidden; pass `sidecars` true to list them all anyway. A directory too large for one listing is truncated with a counted line naming what remains; pass `full` true when every entry is genuinely needed.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "Optional res:// path or bare name of the directory to list, e.g. \"res://addons\" or \"addons\". Omit to list the top-level items in the project root.",
				},
				"sidecars": {
					"type": "boolean",
					"description": "Set true to also list the .import/.uid sidecar files that are folded away by default. Rarely needed — their contents are reached through read_file on the asset they belong to.",
				},
				"full": {
					"type": "boolean",
					"description": "Set true to list every entry when a large directory's listing was truncated — the truncation line reports how many entries were withheld. Rarely needed: search_files with this directory as \"path\" finds specific files without the whole dump.",
				},
			},
			"required": [],
		},
	},
	"search_files": {
		"summary": "Search the project's text files for a literal term and get an excerpt around each match, or a per-file match overview when a broad query hits too much.",
		"description": "Search the project's text files for a term and return only the surrounding context of each match — the enclosing function for GDScript, otherwise a few lines around the matching line — rather than whole files. Matching is literal, case-insensitive substring: regex and glob syntax are not supported. A query that matches too much comes back as a per-file overview of match counts instead of excerpts; re-run with `path` set to one of the listed files or directories to see the code, or pass `full` true when you genuinely want every excerpt in one result. A whole-project search covers the project's OWN files: matches inside installed addons (res://addons/) are counted and reported at the end but not excerpted, since vendored addon code is usually not what a question is about — pass `path` to search an addon deliberately, and note that when a term appears ONLY inside addons those matches are shown normally, so nothing is ever hidden. Long packed-array data payloads (PackedByteArray image or tile data and the like) appear as \"<N bytes elided>\" markers in excerpts, exactly as a default read_file shows them — read_file with full:true is the one route to the raw payloads, and text inside such a payload is not matchable here. Use read_function afterward when you need the whole body of one function a match points at.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"query": {
					"type": "string",
					"description": "The text to search for, matched as a literal, case-insensitive substring — not a regex or glob.",
				},
				"path": {
					"type": "string",
					"description": "Optional res:// path or bare name of a file or directory to limit the search to. Omit to search the whole project.",
				},
				"context_lines": {
					"type": "integer",
					"description": "Lines of context to show before and after a match when the enclosing function can't be used (non-GDScript files). Defaults to {tunable:search_default_context_lines} with no cap — raise it when a match needs more surrounding code, though read_file is usually the better tool for most of a file.",
				},
				"full": {
					"type": "boolean",
					"description": "Set true to get every excerpt even when the result is broad — waives the per-file overview fallback and the excerpt-block cap, honoring `context_lines` for every match. Reach for it when excerpts were withheld and you genuinely need them all; a scoped `path` is usually the cheaper route.",
				},
			},
			"required": ["query"],
		},
	},
	"list_dependencies": {
		"summary": "List the resources a file depends on, or with reverse=true every scene, resource, script, and project setting that references it — engine dependency records that follow UID and binary references grep can't.",
		"description": "Trace resource wiring through the engine's own dependency records: what a file depends on, or — with `reverse` set true — every file in the project that uses it. Forward (the default) lists the resources a scene or resource file references (its ext_resources, textures, scripts, sub-scenes), read from the file's dependency records without loading or instantiating anything; a reference whose recorded path has gone stale but whose UID still resolves is shown at its current location, and one that resolves nowhere is flagged MISSING. Reverse answers \"what uses this texture/scene/script?\" before you rename, move, edit, or delete it: every scene and resource file is checked through its engine dependency records — which see references search_files can't, i.e. UID-based references and binary .scn/.res files — while scripts and project.godot are checked by literal text match on the file's res:// path and its uid://. Honest limits: a path assembled dynamically in code (string concatenation, exported variables) can't be found either way, and a forward listing for a plain script shows the res:// and uid:// literals its text mentions, since the engine does not record script preloads as dependencies.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file to trace, e.g. \"res://player.tscn\" or \"icon.svg\". A bare name is searched for across the project.",
				},
				"reverse": {
					"type": "boolean",
					"description": "Set true to list what USES this file (scenes, resources, scripts, project settings referencing it) instead of what it depends on. Omit (or false) for the file's own dependencies.",
				},
				"full": {
					"type": "boolean",
					"description": "Set true to list every line when a heavily-referenced file's listing was truncated — the truncation note reports how many were withheld. These are engine-record references no other tool can recover, so a truncated reverse listing you need all of is exactly what this is for.",
				},
			},
			"required": ["path"],
		},
	},
	"describe_class": {
		"summary": "Look up any type's real API — an engine class from live ClassDB, one of THIS PROJECT's own class_name scripts, or a Variant type / global enum from the engine docs: inheritance plus every member with signatures. Pass kind=signals (or methods, properties, enums, constants) to answer about one part of a class cheaply.",
		"description": "Get a type's real API rather than recalling it from memory — the inheritance chain and the members: properties (name and type), methods (full signatures with argument types, defaults, return type, and const/static/virtual/vararg qualifiers), signals, enums, and constants. Three registries are searched in turn, so ONE call answers for any Godot name. (1) Engine classes come from the live ClassDB registry — the authoritative record of what exists in THIS build, GDExtension and registered custom classes included. (2) THIS PROJECT'S OWN class_name scripts come from the loaded script's registered API — use this instead of reading a whole script file when you want a project class's shape: it gives every method signature, exported and plain variable with its type, signal, constant, and inner class, plus the chain up through any base scripts to the engine base, and it names the file so read_function or read_file can fetch a body you actually need. (3) The Variant types (Array, Dictionary, Callable, Vector2, …), the built-in scopes (@GDScript, @GlobalScope), and @GlobalScope's global enums by their bare name (Key, Error, MouseButton) come from the engine's own documentation cache, which is the only registry that holds them — ClassDB does not. Use it to ground your work in reality: to confirm a type exists and that a method or property is really named and shaped the way you think before you write code against it. By default only the type's OWN members are shown, not those inherited; the inheritance chain is listed so you can look a parent up separately, or pass inherited=true to fold them in here (on a project class that folds in its base scripts AND its engine base, each member tagged with the class that declares it). The result is narrowed on two independent axes, and using them is what makes this cheaper than reading or grepping the source: `kind` selects one part of the API (\"signals\", \"methods\", \"properties\", \"enums\", \"constants\", plus \"constructors\"/\"operators\" on a Variant type and \"inner_classes\" on a project script), and `filter` selects members whose NAME contains a substring. A question about one kind should always pass it — \"what signals does the player emit\" is kind=signals, and on a large class that is a few hundred bytes instead of the whole API. They combine (e.g. class \"Control\", kind \"properties\", filter \"focus\"). When you already know one member's name and just need its exact shape, use describe_member instead. For what something DOES — the documentation prose rather than the API's shape — use describe_docs.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"class": {
					"type": "string",
					"description": "The name to look up: an engine class (\"Sprite2D\", \"Node\"), one of this project's own class_name scripts (\"Player\", \"InventorySlot\"), a Variant type (\"Array\", \"Callable\"), a built-in scope (\"@GDScript\", \"@GlobalScope\"), or a global enum (\"Key\", \"Error\"). Matched case-insensitively, so \"sprite2d\" also resolves. If it isn't found, close matches from all three registries are suggested.",
				},
				"kind": {
					"type": "string",
					"description": "Optional: return only ONE part of the API instead of all of it — \"signals\", \"methods\", \"properties\", \"enums\", \"constants\" (plus \"constructors\"/\"operators\" on a Variant type and \"inner_classes\" on a project script). Pass a list for two. This is the cheap way to answer a question about one member kind: on a large class it is the difference between a few hundred bytes and the whole API. Use it together with `filter` (which narrows by NAME) whenever the question is about a kind rather than a name — \"what signals does X emit\" is kind=signals.",
				},
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring narrowing the result to members whose name contains it — use it on a large class to pull just the relevant methods, properties, or constants instead of the whole API, e.g. \"focus\" or \"set_\". Omit to list every member. Narrows by NAME, where `kind` narrows by member kind; they combine.",
				},
				"inherited": {
					"type": "boolean",
					"description": "Set true to also include members inherited from parent classes, all the way up to Object. Omit (or false) to show only the members this class itself declares — the narrow default; prefer using the inheritance chain in the result to look up a parent when you can.",
				},
			},
			"required": ["class"],
		},
	},
	"describe_member": {
		"summary": "Resolve one named member — method, property, signal, enum, or constant — of an engine class or one of THIS PROJECT's own class_name scripts: its exact signature and which class declares it; the narrow follow-up to describe_class.",
		"description": "Look up a single member by exact name (case-insensitive) — the narrow follow-up to describe_class for when you already know (or think you know) a member's name and just need to confirm its real shape before writing code against it. The name is searched across every member kind — methods, properties, signals, enums, and constants — and up the whole inheritance chain, so you needn't know which ancestor declares it: each result names its declaring class. Engine classes are read from the live ClassDB registry; THIS PROJECT'S OWN class_name scripts are read from the loaded script's registered API and then up through its base scripts into its engine base, with each script hit naming the FILE that declares it, so you know where a change would go without reading anything. A method or signal comes back as its full signature; a property includes its type and, on an engine class, its default value and setter/getter; a constant notes its value and the enum it belongs to. A Variant type or built-in scope (Array, Callable, @GlobalScope) has no ClassDB entry, so the engine's own documentation answers for it instead, and says so. If the name doesn't resolve, near-miss member names are suggested so a misremembered name can be corrected. Use describe_class instead when you want to browse what a class offers rather than pin down one member, and describe_docs when you need what a member DOES — its documentation prose — rather than its shape.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"class": {
					"type": "string",
					"description": "The class to look on — an engine class (\"Sprite2D\") or one of this project's own class_name scripts (\"Player\"). Matched case-insensitively. Members inherited from ancestors, script bases included, resolve too, so pass the class you're actually working with.",
				},
				"member": {
					"type": "string",
					"description": "The member's exact name, matched case-insensitively against methods, properties, signals, enums, and constants — e.g. \"get_rect\", \"position\", \"visibility_changed\", or \"NOTIFICATION_READY\". \"Class.member\" also works, standing in for both arguments.",
				},
			},
			"required": ["class", "member"],
		},
	},
	"describe_docs": {
		"summary": "Read the engine's own documentation prose (the Help-panel text) for a Godot class or one member — what it does and how to use it; the meaning counterpart to describe_class/describe_member's structure.",
		"description": "Read the Godot engine's own documentation prose for a class, or for one member of it — the same text the editor's Help panel shows: what something does, how to use it, caveats and notes. This complements describe_class and describe_member, which give the structural API (signatures and types); use this when you need meaning and usage guidance rather than shape. The prose comes from the running editor's documentation cache, so it is version-matched to this exact engine build rather than recalled from memory, and it covers everything the Help panel does — including pages ClassDB doesn't know, like @GDScript (annotations such as @export, functions like preload), @GlobalScope, and the built-in math types (Vector2, Color, and so on). Pass just `class` for the class-level description; add `member` to get one method, property, signal, constant, enum, annotation, or theme item — searched up the inheritance chain, with near-miss names suggested when it doesn't resolve. The text uses Godot's doc markup ([code], [member x], [method y]); read it as formatting. Project scripts have no engine-doc page — for one of this project's own class_name scripts call describe_class, which reads its real API, and read_file for anything else.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"class": {
					"type": "string",
					"description": "The class or doc page to read, e.g. \"Sprite2D\", \"Vector2\", \"@GDScript\", \"@GlobalScope\". Matched case-insensitively. \"Class.member\" also works, standing in for both arguments.",
				},
				"member": {
					"type": "string",
					"description": "Optional: one member's exact name to get just its prose — a method, property, signal, constant, enum, annotation (e.g. \"@export\"), or theme item, matched case-insensitively and up the inheritance chain. Omit for the class-level description.",
				},
				"full": {
					"type": "boolean",
					"description": "Set true to get the whole prose when a long page was truncated — the truncation note reports how much was withheld. Rarely needed: `member` narrows to one entry's prose first.",
				},
			},
			"required": ["class"],
		},
	},
	"search_docs": {
		"summary": "Full-text search the engine documentation's prose for a concept and get the classes and members that cover it — the discovery step when you don't know the name describe_docs would need.",
		"description": "Search the text of the Godot engine's own documentation — every class page and member description in this build's doc cache — for the entries containing ALL your words, returned as a ranked one-line list: the class or Class.member, its kind, and a snippet of its prose. This is the discovery front end to describe_docs, for when you know the CONCEPT but not the NAME: \"text wrap\" finds Label.autowrap_mode, \"pause game\" finds what pausing actually hangs off, where describe_docs and describe_member need the name up front. Pass two or three content words naming the concept, not a sentence — every word must appear in a single entry's name or prose (common filler like \"how\" is dropped automatically), so extra words shrink the result and synonyms are worth a retry. Follow up with describe_docs on a hit to read its full prose, or describe_member for its exact signature. Like describe_docs this reads the running editor's version-matched documentation cache, so hits are this build's reality, not memory; project scripts have no doc page — use search_files for those, or describe_class when you know the class_name.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"query": {
					"type": "string",
					"description": "A few words naming the concept, e.g. \"text wrap\" or \"collision layer mask\". Case-insensitive; every word must appear in the same entry, so prefer two or three specific words over a sentence.",
				},
			},
			"required": ["query"],
		},
	},
	"describe_project": {
		"summary": "Read the project's configuration from live ProjectSettings — main scene, autoloads, input actions, and every project setting; pass filter to browse an area or setting for one exact value.",
		"description": "Inspect the project's configuration as the engine resolves it — the live ProjectSettings state (project.godot plus engine defaults), not a guess or a raw file parse. With no arguments it returns the narrow overview: project name, main scene, the autoload singletons, the input actions the project defines (with their key/button/axis events in plain words), and how many settings differ from engine defaults. Pass `filter` to list every setting whose slash-separated name contains it — e.g. \"display/window\" for window settings, \"input/\" for all input actions including the built-in ui_* set — with changed-from-default entries marked. Pass `setting` for one exact setting: its current value and its engine default. Use this before reading or writing gameplay code that leans on configuration — input actions a script polls, the main scene, autoload names — and use set_project_setting to change what you find. Note that input actions and autoloads live here, not in any scene: an action like \"jump\" is the setting input/jump, an autoload named GameState is autoload/GameState.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"setting": {
					"type": "string",
					"description": "Optional: one setting's full slash-separated name, e.g. \"application/run/main_scene\", \"input/jump\", or \"autoload/GameState\", for its exact value and default. A bare input action or autoload name resolves too.",
				},
				"filter": {
					"type": "string",
					"description": "Optional: a case-insensitive substring listing every setting whose name contains it, e.g. \"window\", \"physics/2d\", or \"input/\". Omit both arguments for the project overview.",
				},
			},
			"required": [],
		},
	},
	"set_project_setting": {
		"summary": "Change one project setting and save project.godot — plain settings validated against their real type, autoloads (autoload/Name), and input actions (input/name) built from friendly key/button/axis event specs; revert restores the default or removes a custom entry.",
		"description": "Set one project setting through the live ProjectSettings singleton and save project.godot — the write counterpart to describe_project, covering the whole configuration surface: plain settings, autoload singletons, and input-map actions. There is no unsaved-in-editor state for project settings, so the change is written to project.godot immediately and the result says so. Three domains, by name prefix: (1) an INPUT ACTION — \"input/jump\" — takes its events as friendly strings: a key like \"Space\", \"W\", or \"Ctrl+Shift+S\", \"MouseButton:Left\", \"JoyButton:0\" (or A/B/X/Y), or \"JoyAxis:1-\" (axis and direction); pass one string, an array of them, or {\"deadzone\": 0.5, \"events\": [...]} — this is how you add the \"jump\" a script's Input.is_action_pressed(\"jump\") needs. (2) an AUTOLOAD — \"autoload/GameState\" — takes the res:// path of a script or scene (validated to exist) and registers it enabled; the singleton is available as /root/GameState when the project runs. (3) any OTHER setting — \"application/run/main_scene\", \"display/window/size/viewport_width\" — takes a value coerced to the setting's real type (numbers, booleans, strings, or a Godot literal in a string like \"Vector2(64, 32)\"), and a name that doesn't exist is refused with near-miss suggestions so a typo can't silently create a dead setting; pass `create` true for a genuinely new custom setting. Pass `revert` true instead of a value to restore a built-in setting's default — which is also how you DELETE a custom setting, autoload, or input action. Gameplay-facing changes (input, autoloads) take effect the next time the project runs, not retroactively in a running game.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"setting": {
					"type": "string",
					"description": "The setting's full slash-separated name: an input action like \"input/jump\", an autoload like \"autoload/GameState\", or any project setting like \"application/run/main_scene\".",
				},
				"value": {
					"type": ["string", "number", "boolean", "array", "object"],
					"description": "The new value. For an input action: an event string (\"Space\", \"Ctrl+S\", \"MouseButton:Left\", \"JoyButton:0\", \"JoyAxis:1-\"), an array of them, or {\"deadzone\": 0.5, \"events\": [...]}. For an autoload: the res:// path of its script or scene. Otherwise: a value matching the setting's type — a Godot literal in a string (e.g. \"Vector2(64, 32)\") covers non-JSON types. Omit only when passing revert.",
				},
				"revert": {
					"type": "boolean",
					"description": "Set true to restore the setting's engine default instead of setting a value — for a custom setting, autoload, or input action (which have no default) this removes the entry entirely.",
				},
				"create": {
					"type": "boolean",
					"description": "Set true to allow creating a brand-new custom setting under a name the project doesn't know — the guard that otherwise stops a typo from silently creating a dead setting. New input/ and autoload/ entries never need it.",
				},
			},
			"required": ["setting"],
		},
	},
	"set_import_setting": {
		"summary": "Change how Godot IMPORTS an asset (a texture's compression/mipmaps, an audio file's loop, a font's antialiasing) and reimport it on the spot — or reimport with no settings to rebuild an asset whose import failed or whose source file changed.",
		"description": "Change the import settings of one asset Godot converts on import — an image, audio file, font, or 3D scene — and re-import it immediately through the editor's own filesystem, so the change is live rather than waiting for the user to rescan. These are the settings the editor's Import dock shows: they belong to the ASSET, not to any scene or resource that uses it, and they are the only place things like a texture's compression mode, mipmap generation, or SVG scale can be set. Pass `path` as the asset itself (\"res://sprites/hero.png\"), not its .import sidecar, and `settings` as an object of setting names to values, e.g. {\"compress/mode\": 0, \"mipmaps/generate\": true} — the names are exactly those in the asset's .import file, which read_file shows with \"full\": true. Each value is coerced to the type that setting already holds, so a whole number lands in a float setting as a float. Settings that are a CHOICE from a fixed list — a texture's compress/mode, its detect_3d/compress_to, roughness/mode, a WAV's compress/mode — are stored as bare numbers whose meaning nothing in the file records, so pass the NAME instead and let it be resolved: {\"compress/mode\": \"Lossless\"} is safer than guessing that lossless is 0 (it is 0; 3 is VRAM Uncompressed). A number outside that setting's list is refused with every legal value and its number named, and the result reports each value with its name so a wrong choice is visible rather than echoed back as the figure you sent. A setting name the importer does not declare is REFUSED with the real names listed and nothing written, because the engine silently DROPS an unrecognized setting on the next import rather than reporting it — a typo would otherwise report success having changed nothing. After the re-import the .import is read back and the result states which settings actually took, so a value the importer declined is never reported as set. Omit `settings` entirely to just RE-IMPORT the asset as it stands: that is the fix when an import failed and you have corrected the cause, when the source file was replaced outside the editor, or when an asset was written by another tool and has never been imported at all. The result reports whether the import then succeeded — a failed import leaves the asset unloadable, and read_errors carries the engine's reason. To change what a .tres resource holds use edit_resource instead; this tool does not touch files that are loaded directly (.gd, .tscn, .tres), which have no import step.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The imported asset's res:// path, e.g. \"res://sprites/hero.png\" — the asset itself, not its .import sidecar (a .import path is accepted and resolved to its asset).",
				},
				"settings": {
					"type": "object",
					"description": "Optional: an object of import setting names to new values, e.g. {\"compress/mode\": \"Lossless\", \"mipmaps/generate\": true}. Names must be ones the asset's importer declares (read_file the .import with \"full\": true to see them). For a setting that is a choice from a fixed list, pass the choice's NAME rather than a number — the numbers are not self-explanatory and a wrong one silently builds the asset the wrong way. Omit to re-import the asset unchanged.",
				},
			},
			"required": ["path"],
		},
	},
	"describe_scene": {
		"summary": "Inspect a scene currently open in the editor — the LIVE node tree including unsaved edits; pass node_path for one node's changed properties, signal connections, and groups.",
		"description": "Inspect the live state of a scene open in the editor — what the user is actually looking at right now, including edits not yet saved to disk. With no arguments it shows the currently edited scene as an indented node tree: each node's name, class (or script class), attached script path, and instanced-subscene markers (the .tscn a child scene comes from), without descending into instances unless the user marked them editable. Pass `scene` to pick another OPEN scene by its file path or root node name (the result lists the open scenes). Pass `node_path` (as shown in the tree, e.g. \"Player/Sprite2D\", or \".\" for the root) to zoom into ONE node: its type and script, the properties that differ from their class defaults, its persisted signal connections (incoming and outgoing), and its groups — the narrow follow-up, like describe_member is to describe_class. For a scene that is NOT open, or for what is saved on disk as opposed to the live editor state, use describe_scene_file instead. Use describe_class afterward to look up what a node's class can do.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "Optional: which OPEN scene to inspect, as its res:// path, bare file name, or root node name — matched against the editor's open scene tabs. Omit for the scene currently being edited.",
				},
				"node_path": {
					"type": "string",
					"description": "Optional: the path of one node, relative to the scene root as shown in the tree (e.g. \"Player/Sprite2D\"; \".\" is the root), to get that node's detail — non-default properties, signal connections, groups — instead of the whole tree.",
				},
				"depth": {
					"type": "integer",
					"description": "Optional: limit the tree to this many levels below the root, for a shallower overview of a deep scene. Omit for the full tree (large scenes are capped with a note either way).",
				},
				"filter": {
					"type": "string",
					"description": "Optional, with node_path: substring to match the node's property and connection names, case-insensitive. Matching properties print their values WHOLE — the route to an entry past the section caps or a value the default view clips.",
				},
			},
			"required": [],
		},
	},
	"describe_scene_file": {
		"summary": "Inspect a saved .tscn/.scn scene file from disk without instantiating it — node tree from its packed SceneState; pass node_path for one node's saved properties, connections, and groups.",
		"description": "Inspect any saved scene file (.tscn or binary .scn) in the project as the engine itself parses it — read from the file's packed SceneState WITHOUT instantiating anything, so no script runs and nothing has side effects. Default result is the saved node tree: each node's name, type (or the .tscn it is an instance of), and attached script path. Pass `node_path` (as shown in the tree, e.g. \"Player/Sprite2D\", or \".\" for the root) to zoom into ONE node: its saved property overrides (a scene file only stores properties that differ from defaults, so this list IS the node's edits), its signal connections, and its groups. Note the saved file does not descend into instanced sub-scenes — call describe_scene_file again on the instanced .tscn to see inside one. For a scene the user has OPEN in the editor — including unsaved edits — use describe_scene instead. read_file on a .tscn returns this same saved-tree view by default (its \"full\": true gives the raw serialized form when you need that); binary .scn files can only be inspected here. Use describe_class to look up what a node's type can do.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the scene file, e.g. \"res://levels/cave.tscn\" or \"cave.tscn\". A bare name is searched for across the project.",
				},
				"node_path": {
					"type": "string",
					"description": "Optional: the path of one node, relative to the scene root as shown in the tree (e.g. \"Player/Sprite2D\"; \".\" is the root), to get that node's detail — saved property overrides, signal connections, groups — instead of the whole tree.",
				},
				"depth": {
					"type": "integer",
					"description": "Optional: limit the tree to this many levels below the root, for a shallower overview of a deep scene. Omit for the full tree (large scenes are capped with a note either way).",
				},
				"filter": {
					"type": "string",
					"description": "Optional, with node_path: substring to match the node's stored property and connection names, case-insensitive. Matching properties print their values WHOLE — the route to an entry past the section caps or a value the default view clips.",
				},
			},
			"required": ["path"],
		},
	},
	"read_editor_selection": {
		"summary": "See what the user has focused in the editor right now — the selected scene nodes, active scene tab, the script and cursor line in the script editor, the Inspector's object, and the FileSystem dock selection.",
		"description": "Read what the user is looking at in the editor, as one compact snapshot: the nodes selected in the Scene dock (paths and types), the active scene tab and the other open ones, the script showing in the script editor with the line its cursor is on, the object the Inspector is showing, and what is selected in the FileSystem dock. Use it when the user says \"this node\", \"here\", \"the selected ones\", or asks about what they are working on — their live selection is what those words point at, and nothing else can see it. Each surface reports in one line, and a surface with nothing selected says so, because that absence is itself the answer. The report is a snapshot, not a feed: it does not update as the user acts, so read it again when their focus matters again (an identical result means their focus has not changed). It is read-only — it never changes the selection or moves the user's focus; open_for_user is the tool that navigates FOR them. For what a selected node contains, follow up with describe_scene and its node_path; for what the user just DID rather than what they have selected, read_undo_history.",
		"max_consecutive_uses": 3,
		"parameters": {
			"type": "object",
			"properties": {},
			"required": [],
		},
	},
	"read_undo_history": {
		"summary": "Read the editor's undo history — the user's recent actions by name, newest first, with the current undo position — to see what the user just changed.",
		"description": "Read the names of the user's recent editor actions from the editor's own undo system, newest first — the cheapest answer to \"what did the user just change\": every edit the user makes in a scene (moving a node, setting a property, adding a child) is one named action here. Two histories report: the active scene's, and the global history recording project settings and other non-scene changes. Each shows its newest `window` actions (default {tunable:undo_history_default_window}, capped at {tunable:undo_history_max_window} — action names are the user's own work, so the whole history is never dumped). An action the user has undone is marked \"(undone)\" — redo would reapply it; everything unmarked is currently applied — and each history states whether undo and redo are available. Two honest limits: script TEXT edits never appear, because the script editor keeps its own per-file undo outside these histories, so an empty history does not mean the user changed nothing; and an action's name describes the operation (\"Move Node2D\"), not always which node it hit — describe_scene shows the resulting live state. This tool is READ-ONLY by design: it never performs an undo or redo, and no tool does — if something looks like it should be reverted, tell the user; the revert is theirs to make with Ctrl+Z.",
		"max_consecutive_uses": 3,
		"parameters": {
			"type": "object",
			"properties": {
				"window": {
					"type": "integer",
					"description": "How many recent actions each history shows. Defaults to {tunable:undo_history_default_window}, capped at {tunable:undo_history_max_window}.",
				},
			},
			"required": [],
		},
	},
	"open_for_user": {
		"summary": "Open a project file in the editor for the USER to look at — a script at a line, a scene as the active tab, a resource in the Inspector, or any file revealed in the FileSystem dock — handing them the exact place you mean.",
		"description": "Take the USER to a file: open it in the editor surface that shows it, so they end up looking at the place you mean. This is the hand-off half of navigation — for when they ask to be taken somewhere (\"show me\", \"open it\", \"where does X happen\" meaning go there), or when your answer ends at one specific spot they will want on screen. The file type picks the surface: a script opens in the script editor, at `line` (1-based) when you pass one; a .tscn/.scn opens as the active scene tab; a .tres or other loadable resource opens in the Inspector (a shader in the shader editor); a file no editor surface opens (.md, a .import) is revealed in the FileSystem dock. Pass `reveal` true to only select the file in the FileSystem dock without opening anything — pointing without switching what the user is editing. This changes no files, but it DOES take the user's editor focus: call it because they asked or because your answer needs their eyes there, never speculatively, and at most once per place. The result states exactly what was opened where. Paths resolve like read_file's (res:// path, unique bare file name, or uid://); a path that resolves nowhere is refused with candidates and nothing is opened.",
		"max_consecutive_uses": 3,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file to open for the user; a bare name resolves only when exactly one file in the project carries it.",
				},
				"line": {
					"type": "integer",
					"description": "Optional, scripts only: the 1-based line to open the script at in the script editor.",
				},
				"reveal": {
					"type": "boolean",
					"description": "Optional: true selects the file in the FileSystem dock instead of opening it, leaving what the user is editing untouched.",
				},
			},
			"required": ["path"],
		},
	},
	"read_tilemap": {
		"summary": "Read what tiles are placed where in a scene's TileMapLayer nodes — per layer: cell count, bounds, tiles grouped by NAMED tile source, and which layers are empty, hidden, or disabled and which another node's script fills at runtime; pass layer for an ASCII grid map of one layer's placement (rect windows it). The decoded view of tile_map_data, which every text read elides.",
		"description": "Decode a scene's tilemap content through the engine's own TileMapLayer parser — the answer to \"what tiles are placed where\", which no text read can give: the tile_map_data property is base64 over a packed binary struct, and read_file always elides it to a byte count. With no arguments it reads the scene currently being edited LIVE (unsaved edits included); pass `scene` for a saved .tscn/.scn from disk. The default report covers every TileMapLayer: cell count, used bounds, and tiles counted per source with the source's NAME from the layer's TileSet (use describe_tileset for the full legend of what those sources are), plus which layers are empty. A layer another node holds a NodePath reference to is flagged — a script commonly fills such display layers at runtime, so tiles written there can be regenerated over. Pass `layer` (a layer's name or path from the default report) to zoom into ONE layer as an ASCII grid with a legend — the spatial view that answers \"is there a hole in this wall\"; a grid past the view cap names `rect` ([x, y, width, height] in cells) to window it. Legacy TileMap nodes (deprecated) are counted but not decoded, and instanced sub-scenes are not descended into — call this on the instanced .tscn instead.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "Optional: the res:// path or bare file name of a saved scene file to read from disk. Omit for the scene currently being edited in the editor — the LIVE state, unsaved edits included.",
				},
				"layer": {
					"type": "string",
					"description": "Optional: one TileMapLayer to zoom into, by its name or its path as shown in the default report (e.g. \"Ground\" or \"World/Ground\") — returns that layer's cells as an ASCII grid with a per-source legend.",
				},
				"rect": {
					"type": "array",
					"items": {"type": "integer"},
					"description": "Optional: [x, y, width, height] in cell coordinates, windowing the zoomed layer's grid to that region — for layers too large to render whole (the report names each layer's used rect).",
				},
			},
			"required": [],
		},
	},
	"describe_tileset": {
		"summary": "Inspect a TileSet resource — every tile source with its id and NAME (resource name or texture file), terrain sets with their named terrains, and custom data layers; kind=sources|terrains|custom_data narrows, filter matches names. The legend for read_tilemap's source ids.",
		"description": "Describe a TileSet — the palette a TileMapLayer paints from — as the engine loads it, one ranked line per tile source: its numeric id, its NAME (the source's resource name, or its texture's file name — e.g. source 9 \"stone_wall\" from stone_wall.png), and what it holds (an atlas's texture and tile count, or a scene collection's scene paths). This is what read_tilemap's per-source counts and grid legends mean, and what a script's hardcoded source-id table encodes. Also lists terrain sets (each terrain's id and name, and the set's matching mode) and custom data layers (name and type). Pass the TileSet's .tres/.res path, or a .tscn path to describe the TileSet its layers use — an embedded TileSet is only reachable that way; a scene using several distinct TileSets asks you to pick a `layer`. `kind` selects whole sections (sources, terrains, custom_data) and `filter` matches names within them, so \"what terrains exist\" costs a few lines, not the whole palette.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path (or bare file name) of the TileSet .tres/.res — or of a .tscn scene, to describe the TileSet its TileMapLayer nodes use (the only route to a TileSet embedded in the scene file).",
				},
				"kind": {
					"type": "string",
					"description": "Optional: return only ONE section instead of all three — \"sources\", \"terrains\", or \"custom_data\". Pass a list for two. \"What terrains does this tileset have\" is kind=terrains.",
				},
				"filter": {
					"type": "string",
					"description": "Optional case-insensitive substring matched against source, terrain, and custom-data-layer names — e.g. \"stone\" to find every stone source.",
				},
				"layer": {
					"type": "string",
					"description": "Optional, with a .tscn path: which TileMapLayer's TileSet to describe, when the scene's layers use more than one.",
				},
			},
			"required": ["path"],
		},
	},
	"edit_tilemap": {
		"summary": "Change tiles in a scene's TileMapLayer — set cells, fill or erase a rect, REPLACE every tile of one source with another, or paint terrain with matched edges; sources by NAME or id. A minimal text edit to the .tscn through the engine's own encoder — never hand-edit tile_map_data bytes or write custom scripts to change tiles.",
		"description": "Edit a TileMapLayer's placed tiles in a saved .tscn, through the engine's own encoder — tile_map_data is a packed binary struct, so this is the ONLY way to change tiles: never hand-edit its base64 in the file, and never write custom scripts to decode it. Pass `scene`, `layer` (name or path — read_tilemap lists them), and exactly ONE action: `cells` places explicit cells ([{at: [x, y], source, atlas?, alt?}]); `fill` floods a rect with one tile ({rect: [x, y, w, h], source, atlas?}); `replace` swaps every cell of one source for another ({from, to, rect?}) — the way to change all of one tile type at once, keeping each cell's atlas and flip; `erase` removes cells ({cells} or {rect} or {source} for every cell of that source); `terrain` paints cells with the TileSet's own terrain matching ({cells or rect, terrain by name} — use this over raw sources where terrains exist, or edges will not match). Sources and terrains go by NAME (\"Dirt Floor\") or numeric id — describe_tileset is the legend. The result reports the honest diff — added/changed/erased, what overwritten cells previously held, cells that already held the target — plus the layer's new totals; a write that changes nothing says so. The file is written as a minimal text edit (everything but the one data line byte-untouched), validated by the engine, and a clean open editor tab is reloaded; a layer another node's script references is flagged, since a script may regenerate it at runtime.",
		"mutating": true,
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "The res:// path (or bare file name) of the saved .tscn holding the layer. Binary .scn cannot be text-edited.",
				},
				"layer": {
					"type": "string",
					"description": "Which TileMapLayer to edit, by name or path as read_tilemap reports it (e.g. \"Ground\" or \"DG Floor Layer/DualGrid\").",
				},
				"cells": {
					"type": "array",
					"items": {"type": "object"},
					"description": "Place explicit cells: [{\"at\": [x, y], \"source\": name-or-id, \"atlas\": [x, y] (optional on a single-tile source), \"alt\": int (optional)}]. Capped per call — use fill or replace for bulk shapes.",
				},
				"fill": {
					"type": "object",
					"description": "Flood a rect with one tile: {\"rect\": [x, y, width, height], \"source\": name-or-id, \"atlas\": [x, y]?, \"alt\": int?}.",
				},
				"replace": {
					"type": "object",
					"description": "Swap every cell of one source for another, keeping each cell's atlas coords and flip: {\"from\": name-or-id, \"to\": name-or-id, \"rect\": [x, y, w, h] (optional scope)}.",
				},
				"erase": {
					"type": "object",
					"description": "Remove cells: {\"cells\": [[x, y], ...]} or {\"rect\": [x, y, w, h]} or {\"source\": name-or-id} to remove every cell of that source, or {\"all\": true} to clear the whole layer.",
				},
				"terrain": {
					"type": "object",
					"description": "Paint with the TileSet's terrain matching (picks edge-matched tiles, adjusts neighbors): {\"cells\": [[x, y], ...] or \"rect\": [x, y, w, h], \"terrain\": name-or-index, \"terrain_set\": int (only when the name is ambiguous)}.",
				},
			},
			"required": ["scene", "layer"],
		},
	},
	"describe_animation": {
		"summary": "Read AnimationPlayer animations through the engine's own decoder — libraries, tracks of every type, and each keyframe's index, time, and value; keys serialize as packed arrays no text read renders. Pass animation to zoom into one animation; window narrows its keys by time.",
		"description": "Decode a scene's AnimationPlayer content through the engine — keyframes serialize as parallel packed arrays and interleaved float blobs (3D transforms, bezier points) that no text read renders. With no arguments it reads the scene currently being edited LIVE (unsaved edits included); pass `scene` for a saved .tscn/.scn, or an Animation/AnimationLibrary .tres. The default report lists every AnimationPlayer with each library's animations (name, length, loop, track and key counts). Pass `animation` (a name from the overview, qualified like \"attack/back\" when libraries share names) to zoom into ONE animation: every track with its type, path, interpolation, and per-key listings — the key indices are what edit_animation's set_key/remove_key take; `window` ([start_sec, end_sec]) narrows the key listing of a long animation, and `player` picks one AnimationPlayer when several exist. Scalar properties (length, loop_mode, tracks/N/path, interp, enabled, update mode) are plain text lines in the file — edit those with edit_file; tracks and keys are edited with edit_animation. AnimatedSprite2D/3D SpriteFrames serialize as readable text and are only counted here — read_file shows them. Instanced sub-scenes are not descended into — call this on the instanced .tscn instead.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "Optional: a saved .tscn/.scn scene, or an Animation/AnimationLibrary .tres/.res, by res:// path or bare file name. Omit to read the scene open in the editor, live.",
				},
				"animation": {
					"type": "string",
					"description": "Optional: one animation to zoom into, by name as the overview lists it (e.g. \"walk\", or \"attack/back\" with its library when bare names collide) — returns its tracks and keys.",
				},
				"player": {
					"type": "string",
					"description": "Optional: which AnimationPlayer to read, by node name or path, when the scene has several.",
				},
				"window": {
					"type": "array",
					"items": {"type": "number"},
					"description": "Optional, with \"animation\": [start_sec, end_sec] — only keys inside the window are listed; track and key totals still cover the whole animation.",
				},
			},
			"required": [],
		},
	},
	"edit_animation": {
		"summary": "Change the animation data a text edit cannot: add/remove/move tracks, insert/set/remove keyframes on ANY track type (value, method, 3D transform, blend shape, bezier, audio, animation), add/remove whole animations in a library. Engine-encoded minimal edit to the .tscn/.tres — never hand-edit tracks/N/keys arrays.",
		"description": "Edit one animation's tracks and keys, or a library's animation list, in a saved .tscn/.tres through the engine's own encoder — keyframes serialize as parallel packed arrays that must stay index-aligned and time-sorted, plus interleaved float blobs for 3D/bezier keys — this tool keeps them consistent through the engine, where a hand edit of tracks/N/keys is easy to get wrong. Pass the file, `animation` (name — describe_animation lists them), and exactly ONE action: `add_track` ({type: value|position_3d|rotation_3d|scale_3d|blend_shape|method|bezier|audio|animation, path: \"Node:property\", index?}); `remove_track` ({track}); `move_track` ({track, to}); `insert_key` ({track, time, value, transition?} — value shape follows the track type: any value for value tracks, {method, args} for method, [x, y, z] for position/scale, [x, y, z, w] for rotation, a float for blend shape, a float plus in_handle/out_handle [x, y] for bezier — handles are OFFSETS from the key, x in seconds and y in value units, not absolute points — stream/start_offset/end_offset for audio, a clip name string for animation tracks; inserting at an existing key's time REPLACES that key); `set_key` ({track, index or at: time, then value/time/transition or the type's fields}); `remove_key` ({track, index or at}). Tracks go by index or path substring; string values are parsed as Godot literals when they parse (\"Vector2(4, -7)\", \"Color(1, 0, 0, 1)\"), otherwise kept as strings. `add_animation`/`remove_animation` ({name, library?, length?, loop?}) add or remove a whole animation in a player's library instead — they take no `animation` argument. Scalars (length, loop_mode, step, tracks/N/path, interp, enabled, update mode) are plain text lines — edit those with edit_file. An animation stored in a referenced .tres is edited THERE, and the result says so. The file is written as a minimal text edit, validated by loading it in a child engine, and a clean open editor tab is reloaded.",
		"mutating": true,
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "The res:// path (or bare file name) of the .tscn or .tres holding the animation. Binary .scn/.res cannot be text-edited.",
				},
				"animation": {
					"type": "string",
					"description": "Which animation to edit, by name as describe_animation reports it (e.g. \"walk\" or \"attack/back\"). Not used by add_animation/remove_animation; optional when the file itself is a single Animation .tres.",
				},
				"player": {
					"type": "string",
					"description": "Optional: which AnimationPlayer's animations to match, when the scene has several.",
				},
				"add_track": {
					"type": "object",
					"description": "Add a track: {\"type\": \"value\"|\"position_3d\"|\"rotation_3d\"|\"scale_3d\"|\"blend_shape\"|\"method\"|\"bezier\"|\"audio\"|\"animation\", \"path\": \"Node:property\", \"index\"?: int (default appends)}. The path resolves against the player's root_node (default: the player's parent). Audio and method tracks take a bare node path with no :property — audio names the AudioStreamPlayer node itself. A path naming no node in the saved scene is accepted, as the engine accepts it, and the result states the fact. Track properties (interp, update mode) keep engine defaults — change them with edit_file.",
				},
				"remove_track": {
					"type": "object",
					"description": "Remove a track and its keys: {\"track\": index-or-path-substring}. Later tracks renumber down.",
				},
				"move_track": {
					"type": "object",
					"description": "Move a track to a new index: {\"track\": index-or-path, \"to\": int} — track order is application order when tracks target the same property.",
				},
				"insert_key": {
					"type": "object",
					"description": "Insert a keyframe: {\"track\": index-or-path, \"time\": seconds, \"value\": (by track type — see the tool description), \"transition\"?: float, \"in_handle\"/\"out_handle\"?: [x, y] (bezier), \"stream\"/\"start_offset\"/\"end_offset\"? (audio)}. Inserting at an existing key's time replaces that key.",
				},
				"set_key": {
					"type": "object",
					"description": "Change an existing keyframe: {\"track\": index-or-path, \"index\": int or \"at\": its time, then any of \"value\", \"time\", \"transition\", \"in_handle\"/\"out_handle\" (bezier — [x, y] offsets from the key, x seconds, y value units), \"stream\"/\"start_offset\"/\"end_offset\" (audio)}.",
				},
				"remove_key": {
					"type": "object",
					"description": "Delete a keyframe: {\"track\": index-or-path, \"index\": int or \"at\": its time}.",
				},
				"add_animation": {
					"type": "object",
					"description": "Add a new empty animation to a library: {\"name\": \"walk\" or \"lib/walk\", \"library\"?: which library when the player has several, \"length\"?: seconds, \"loop\"?: \"none\"|\"linear\"|\"pingpong\"}. Then add tracks and keys with further calls.",
				},
				"remove_animation": {
					"type": "object",
					"description": "Remove an animation from a library: {\"name\": \"walk\" or \"lib/walk\", \"library\"?: which library}. Its data block is deleted unless something else still references it.",
				},
			},
			"required": ["scene"],
		},
	},
	"run_subagent": {
		"summary": "Delegate a self-contained task to a fresh-context subagent — it can use the project's tools too — and get back only its result, keeping your own context focused.",
		"description": "Hand a focused, self-contained task to a subagent: a fresh instance of your own model with a clean context that sees ONLY the task and context you pass here, never this conversation. It runs its own tool loop — it can read files, search the project, and use the same tools you can — to work the task, then returns just its final result to you, so its intermediate reasoning and any files it opened never enter your context. Use it to offload work you can hand off whole: investigating how some part of the project works, analyzing or summarizing material, drafting a function or docstring, or any subtask whose back-and-forth you'd rather keep out of your own context. Because the subagent starts blank, state the task completely and, in `context`, include anything specific it can't find on its own (a snippet you already have, an error message, your exact requirements); it can open project files itself, so you needn't paste those. To work several independent tasks at once, call run_subagent multiple times in a single turn — the subagents run in parallel and all of their results come back together before your next turn — so prefer fanning out over delegating one after another whenever the tasks don't depend on each other.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"task": {
					"type": "string",
					"description": "What you want the subagent to do and what to return. Be explicit and complete — it can't ask follow-up questions.",
				},
				"context": {
					"type": "string",
					"description": "Material the subagent needs that it couldn't find on its own — a code snippet you already have, an error message, exact requirements or constraints. It can read and search the project itself, so you needn't paste files here; include only what's specific to this task. Omit if the task is self-explanatory.",
				},
			},
			"required": ["task"],
		},
	},
	"use_skill": {
		"summary": "Read the full instructions of one project skill by name — the skills your system prompt lists with one-line descriptions.",
		"description": "Return the full body of one skill: project-authored instructions for a specific kind of task, stored under res://skills and listed by name and description in your system prompt. Call it when a skill's description matches the task at hand — BEFORE doing that work — and follow what it says; the skill is the project's own guidance, written to be more specific than anything you would infer. The result is the skill file's own text, always whole. A name matching no skill lists the real names, so a close guess recovers in one step.",
		"max_consecutive_uses": -1,
		"parameters": {
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "The skill's name exactly as the skills list in your system prompt gives it. Its file or directory stem under res://skills works too.",
				},
			},
			"required": ["name"],
		},
	},
	"edit_resource": {
		"summary": "Set properties on a saved resource file (.tres/.res) and write it back to disk — including ones the file does not list yet; validates each name and coerces each value to the property's declared type before setting anything.",
		"description": "Edit an existing saved resource file (.tres or .res) in the project: set one or more of its properties to new values and save the file back to the same path. A property the file does not currently store is set just the same — a .tres lists only what differs from the defaults, so a shader uniform or an @export variable added since the file was last saved is settable here without hand-writing the line for it. The resource is loaded through the editor's own cache, so an inspector already showing it reflects the edit. If that in-memory copy has unsaved editor changes (Inspector tweaks the user has not saved), saving commits them to disk along with your batch, and the result notes when that happened so you can tell the user. Pass `path` (the resource's res:// path or bare file name) and `properties`, an object mapping property name → new value. Every name is first checked against the resource's real editor-visible property list — an unknown one aborts the whole call with near-miss suggestions and writes nothing — so a batch either applies in full or not at all. Each value is coerced to the property's declared type: a JSON number or boolean sets a numeric or bool property (int vs float per the declared type); a JSON string sets a String/StringName property directly, is parsed as a Godot literal for a typed value (e.g. \"Vector2(64, 32)\", \"Color(1, 0, 0, 1)\"), or is taken as the res:// path of a resource to load for a property that holds another Resource; a JSON array becomes a Godot array (packed where the property demands). A property that holds another Resource also accepts null (clears it) or an inline object that builds an EMBEDDED sub-resource: {\"script\": ..., ...} where \"script\" names a res:// .gd, a .tres to deep-copy, or a Resource class name, and the remaining keys set the sub-resource's own properties (recursively coerced the same way) — never hand-write [sub_resource] text into a .tres for this. A type that doesn't fit the property is refused with the expected type named. On a ShaderMaterial the shader's uniforms are properties like any other, stored under a \"shader_parameter/\" prefix (e.g. \"shader_parameter/tint\"); the bare uniform name as the shader declares it is accepted too and resolved to the stored one, with the substitution disclosed. This tool does not edit inside an existing sub-resource in place — replace it wholesale with an inline object instead. Use describe_class on the resource's type, or read_file on the .tres, first when you need to know its property names and expected types.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the resource to edit, e.g. \"res://player_stats.tres\" or \"player_stats.tres\". Must be a .tres or .res file; a bare name is searched for across the project.",
				},
				"properties": {
					"type": "object",
					"description": "An object mapping property name → new value. A value may be a JSON number or boolean (for an int/float/bool property), a string (used as-is for a String/StringName property, parsed as a Godot literal such as \"Vector2(64, 32)\" or \"Color(1, 0, 0, 1)\" for a typed property, or taken as the res:// path of a resource to assign to an Object/Resource property), or a JSON array (for an array property). An Object/Resource property also takes null to clear it, or an inline object {\"script\": \"res://augment.gd\", \"amount\": 1.0} to build an embedded sub-resource. Names are validated against the resource's real properties before anything is set.",
				},
			},
			"required": ["path", "properties"],
		},
	},
	"edit_file": {
		"summary": "Edit an existing project text file by exact-string replacement — swap one uniquely-matching snippet for another (or every occurrence with replace_all); refused until you have seen the file's real text, and a .gd edit is parse-checked with any errors it introduced reported for immediate fixing.",
		"description": "Edit an existing UTF-8 text file in the project by exact-string replacement: `old_string` is found verbatim in the file and replaced with `new_string`. You must have SEEN the file's real text first: a file you have not read this session — via read_file, read_function, or search_files excerpts (a long-file map or a search overview shows shape, not text, and does not count) — is refused until you do. The match must be EXACT — every character, including indentation (a .gd here is tab-indented), trailing spaces, and line breaks — so copy the text to replace straight from a read_file or read_function result rather than retyping it (search_files excerpts carry \"  12: \" line-number prefixes that are NOT part of the file). By default `old_string` must match exactly ONE place: if it matches nothing exactly, a whitespace-tolerant fallback compares whole lines — a UNIQUE spot differing from your text only in whitespace is edited anyway, with new_string's indentation adjusted to the file's and the result disclosing exactly what landed — and failing that you are told it wasn't found, with the actual cause named when detectable (an old_string copied from a version of the file your own write already replaced is called out as stale). If it matches several places you get the count and are asked to add surrounding lines until it's unique — or set `replace_all` true to change every occurrence at once (useful for renaming a symbol). Keep `old_string` as small as it can be while still unique; you do not resend the whole file. When the edited file is a GDScript (.gd), the change is validated after writing by launching the engine headlessly: a parse/compile check and this addon's own style lint, each compared against the file's pre-edit state so only problems your edit introduced are reported. The edit is KEPT either way: one that introduces parse/compile errors leaves the file BROKEN on disk and the errors come back with their line numbers — fixing them immediately, with further edit_file calls against the text you just wrote, is then your top priority before any other work. New style-lint problems also keep the edit and come back as follow-ups to clean up. A .gdshader is validated the same way by the engine's own shading-language compiler (no style lint — that guide is GDScript's), so a broken shader is reported here rather than surfacing only when the user runs the game; note the shader compiler stops at the FIRST error, so re-check after fixing one. A .tscn or .tres is validated the same way by a headless load check, and an edit that stops the file loading is likewise kept, reported, and yours to fix at once; a .tscn that still loads is additionally checked for stored properties and node types the engine doesn't know — those load silently and are DROPPED when the scene is instantiated, so any this edit introduced come back as a warning to fix. Serialized scene/resource text must be copied verbatim from read_file (on a .tscn that means \"full\" set to true or a line range — the default saved-tree view is not text), never reconstructed from a describe_scene or describe_scene_file view. To change a PROPERTY of a .tres/.res — including one the file does not list yet, such as a shader uniform just added — prefer edit_resource, which sets it by name against the resource's real type instead of by hand-editing serialized text. A clean open scene has its tab reloaded after the edit so the editor shows the new state; a scene open with unsaved live edits is left alone, and the editor's own external-change handling resolves the conflict. The result is compact: a confirmation and a short excerpt of the changed region with a line of context on each side, never the whole file. After a successful edit the editor's filesystem is refreshed and, if the file is open in the script editor, it is reloaded there in place — unless the user has unsaved changes in it, in which case Godot prompts them to resolve the conflict as usual. Only files under res:// can be edited; binary files are refused. Never write a uid:// value you invented: UIDs are engine-assigned, an invented one can never resolve, and an edit introducing one is refused — reference dependencies by res:// path, or use the real uid a tool result reported (a write_file/create_resource confirmation, list_dependencies, or a read of the target).",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the existing file to edit, e.g. \"res://player.gd\" or \"player.gd\". A bare name is searched for across the project. The file must already exist.",
				},
				"old_string": {
					"type": "string",
					"description": "The exact existing text to replace, matched verbatim including whitespace, indentation, and line breaks. Must match a single place unless replace_all is set; include enough surrounding lines to make it unique. Copy it from a read_file or read_function result rather than retyping — search_files excerpts carry line-number prefixes that are not in the file.",
				},
				"new_string": {
					"type": "string",
					"description": "The replacement text that takes old_string's place. Use \"\" to delete the matched text. Must differ from old_string.",
				},
				"replace_all": {
					"type": "boolean",
					"description": "Set true to replace EVERY occurrence of old_string rather than requiring a single unique match — use it to rename a symbol throughout the file. Omit (or false) to require old_string to identify exactly one spot.",
				},
			},
			"required": ["path", "old_string", "new_string"],
		},
	},
	"create_resource": {
		"summary": "Create a new .tres resource file and save it into the project — from a built-in Resource class, a user script class, or a copy of an existing resource — optionally setting initial properties.",
		"description": "Create a NEW resource and save it as a .tres (or .res) file in the project, so you can author a material, theme, custom data resource, and so on without hand-writing the file. The `from` argument names the starting point and is interpreted in this order: (1) an existing resource file — a res:// path or bare name of a .tres/.res in the project — which is deep-duplicated (nested sub-resources copied, not shared with the original) as the starting point, working for user-authored resources including script-typed ones; (2) a built-in engine class that extends Resource (e.g. \"StandardMaterial3D\"), matched case-insensitively and instantiated fresh; (3) a user script class that extends Resource — either a global `class_name` (as registered in the project) or a res:// path to a .gd script — which is instantiated with new(). Give the destination in `path` (must end in .tres or .res; missing folders are created). Set `properties` to a name→value object applied after creation: values are validated against the resource's real properties (with near-miss suggestions) and coerced from JSON — numbers and bools pass through, a plain string sets a text property, a string like \"Vector2(64, 32)\" or \"Color(1, 0, 0, 1)\" is parsed for other value types, a string for an object-typed property is a res:// path that is loaded (null clears one, and an inline object {\"script\": \"res://augment.gd\", \"amount\": 1.0} builds an EMBEDDED sub-resource — so duplicating a resource and re-pointing its sub-resource to a new slot never needs hand-written .tres text), and arrays become the property's array type. Refuses to overwrite an existing file unless `overwrite` is true.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"from": {
					"type": "string",
					"description": "The starting point for the new resource, tried in order as: an existing resource file (res:// path or bare name of a .tres/.res, deep-duplicated), a built-in Resource-extending class name (e.g. \"StandardMaterial3D\", case-insensitive), or a user script class that extends Resource — a global class_name or a res:// path to a .gd script.",
				},
				"path": {
					"type": "string",
					"description": "The res:// destination path for the new file; it must end in .tres or .res, e.g. \"res://materials/red.tres\". Missing directories are created. Refused if a file already exists there unless `overwrite` is true.",
				},
				"properties": {
					"type": "object",
					"description": "Optional object of property name → initial value, applied after the resource is created. Names are validated against the resource's real properties. Numbers and bools pass through; a string sets a text property directly, or for other value types is parsed (\"Vector2(64, 32)\", \"Color(1, 0, 0, 1)\"); a string for an object-typed property is a res:// path that is loaded, null clears it, and an inline object {\"script\": \"res://augment.gd\", \"amount\": 1.0} builds an embedded sub-resource; arrays map to the property's array type. \"script\" works too — pass a res:// path to a Resource-extending .gd to build a scripted resource from a plain base class.",
				},
				"overwrite": {
					"type": "boolean",
					"description": "Set true to replace an existing file at `path`. Omit (or false) to refuse when a file already exists there, so an existing resource is never clobbered by accident.",
				},
			},
			"required": ["from", "path"],
		},
	},
	"write_file": {
		"summary": "Write a text file into the project — create a new one (directories included) or completely REPLACE an existing one with the given content; a .gd is parse-checked headlessly and any errors in the content are reported for immediate fixing.",
		"description": "Write a UTF-8 text file into the project at `path` with exactly the given `content`, creating any missing directories along the way. Use it for a genuinely new file — a new script, a config, documentation — or to REPLACE an existing file wholesale: a file already at `path` is overwritten with `content`, so only ever send a COMPLETE file, never a fragment. To change part of an existing file use edit_file instead, which edits by exact replacement and keeps the rest intact. Two safety refusals return without touching disk: overwriting an existing file you have NOT read this session is refused (read it first to confirm you mean it, since the write replaces the whole file — and a file whose read came back with \"<... elided>\" packed-array markers stays refused even after reading, because a rewrite built from that view would destroy the real data behind the markers; change such a file with edit_file, or re-read it with read_file full:true, which returns the payloads verbatim and re-grounds the wholesale write), and creating a NEW file whose name already belongs to a file elsewhere in the project is refused (you most likely meant that existing file) — set `force` true to override either once you are sure. For a new saved resource prefer create_resource, which validates properties against the resource's real type rather than writing raw text. When the written file is a GDScript (.gd) or a .gdshader it is validated afterward by launching the engine headlessly, exactly like edit_file — the engine's parser for a script, its shading-language compiler for a shader: the file is KEPT either way, and content with parse/compile errors leaves it BROKEN on disk with the errors returned line-numbered — the file then holds exactly what you sent, and fixing those errors with edit_file calls (no need to resend everything) is your top priority before any other work. Style-lint problems likewise keep the file and come back in the result as follow-ups (scripts only — the style guide is GDScript's). The editor's filesystem is refreshed afterward so the new file appears immediately. Only paths under res:// can be written, and the path must carry the file's extension. A new .gd, .gdshader or .gdshaderinc is assigned its uid and .uid sidecar on creation (those three carry their uid in a sidecar rather than in the file), and the confirmation for any of them, or for a .tscn/.tres, reports the file's real uid — the one to use in preloads. Never write a uid:// value you invented: UIDs are engine-assigned, an invented one can never resolve, and content introducing one is refused — reference dependencies by res:// path, or use the real uid a tool result reported.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// destination for the file, including its extension, e.g. \"res://scripts/spawner.gd\" or \"res://docs/design.md\". Missing directories are created. A bare name that matches an existing project file resolves to that file, which is then replaced.",
				},
				"content": {
					"type": "string",
					"description": "The full text the file will contain, written exactly as given — the COMPLETE file, since it replaces any existing content wholesale. \"\" creates an empty file.",
				},
				"force": {
					"type": "boolean",
					"description": "Set true only to override a safety refusal: to overwrite an existing file you have not read this session, or to create a new file whose name matches an existing project file on purpose. Omit it normally.",
				},
			},
			"required": ["path", "content"],
		},
	},
	"move_file": {
		"summary": "Move ONE project file to a new res:// location inside the project — its .uid/.import sidecars travel with it so uid:// references keep resolving; refused while other files still reference its old path by literal text unless force is true.",
		"description": "Move ONE existing file to a new location inside the project. The destination in `to` is either a full res:// file path or a directory to move the file into unchanged — an existing directory, or a new one ending in \"/\", created with any missing parents. Both endpoints are contained: source and destination must each land under res://, so a move can never carry a file INTO the project from outside or OUT of the project from inside — \"..\" segments, user:// paths, and paths reaching their target through a symbolic link are refused at either end, and the critical project stores (project.godot, the .godot editor cache, the .git history) are refused as source and destination alike; force overrides none of this. Moves never overwrite: an existing file at the destination refuses the move (delete_file it first if replacing it is truly intended). The file's identity travels with it — a .uid or .import sidecar moves alongside and the engine's uid registry is retargeted on the spot, so references that go through the file's uid (an [ext_resource] carrying uid=, a preload(\"uid://...\")) keep resolving after the move; a moved .import additionally has its own source-path entry rewritten, disclosed, and the editor re-imports the asset on its next scan. References by literal res:// path do NOT survive: before anything moves, the project is scanned the same way delete_file's scan looks, and if any file still references the old path by text the move is REFUSED and they are listed — update them first (edit_file for scripts and scenes, set_project_setting for autoloads and other settings), or pass force true to move anyway, knowingly breaking them; the same list then comes back as a warning on the result. Files referencing only by uid never block the move and are counted in the result — any recorded path= fallback text in them goes stale until the editor next saves them, but the uid keeps them loading. The usual honest limit applies: a path assembled dynamically in code can't be seen, so a clean scan is strong evidence, not proof. A scene currently open in the editor is refused (its open tab would re-save the file at the old path), and a moved script open in the script editor is disclosed so it can be reopened from the new path. To only change the file's name in place, rename_file is the convenience form of this same operation.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file to move, e.g. \"res://old/enemy.gd\" or \"enemy.gd\". A bare name is searched for across the project. The file must exist.",
				},
				"to": {
					"type": "string",
					"description": "The destination inside the project: a full res:// file path (\"res://actors/enemy.gd\"), or a directory to move the file into unchanged — an existing one, or a new one ending in \"/\" (\"res://actors/\"), created with any missing parents. Must stay under res://; a move never leaves or enters the project.",
				},
				"force": {
					"type": "boolean",
					"description": "Set true to move even while other files still reference the old path by literal text, knowingly breaking them (they are listed in the result). Omit (or false) to be refused with the list instead. Force never overrides containment or lets a move overwrite.",
				},
			},
			"required": ["path", "to"],
		},
	},
	"rename_file": {
		"summary": "Rename ONE project file in place — move_file constrained to the file's own directory, with the same sidecar travel, uid preservation, and literal-path reference refusal.",
		"description": "Rename ONE existing file where it stands: the file keeps its directory and takes the bare `new_name`. This is the same operation as move_file constrained to the file's own directory, and every one of its rules applies unchanged: the file must live under res:// (never a \"..\" escape, a user:// path, one reached through a symbolic link, or a critical project store), renames never overwrite an existing file, a .uid or .import sidecar is renamed alongside and the engine's uid registry retargeted so uid:// references keep resolving, and a file still referenced by its literal old path in other files REFUSES the rename with the referencing files listed — update them first, or pass force true to rename anyway, knowingly breaking them (the list comes back as a warning). Changing the extension is allowed but disclosed loudly, since the editor decides what a file IS by its extension. To change the file's directory use move_file instead.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file to rename, e.g. \"res://enemy.gd\" or \"enemy.gd\". A bare name is searched for across the project. The file must exist.",
				},
				"new_name": {
					"type": "string",
					"description": "The file's new bare name including its extension, e.g. \"goblin.gd\" — no directories, since the file stays where it is. To move it elsewhere use move_file.",
				},
				"force": {
					"type": "boolean",
					"description": "Set true to rename even while other files still reference the old path by literal text, knowingly breaking them (they are listed in the result). Omit (or false) to be refused with the list instead.",
				},
			},
			"required": ["path", "new_name"],
		},
	},
	"copy_file": {
		"summary": "Duplicate ONE project file at a new res:// path, bytes and all — the only way to copy a BINARY asset (a texture, a sound, any other imported file); the copy is given a FRESH uid instead of the source's and keeps the source's import settings.",
		"description": "Duplicate ONE existing file to a new path inside the project, byte for byte — the only way to copy a BINARY asset (a .png, .wav, .ogg, a .res), whose bytes no text tool can reproduce, and the same operation as the FileSystem dock's Duplicate. The destination in `to` is either a full res:// file path including the new file's name, or a directory to copy the file into under its own name — an existing directory, or a new one ending in \"/\", created with any missing parents. The copy never carries the source's identity: a uid in a .tscn/.tres header is rewritten to a freshly engine-generated one, a .uid sidecar (for a .gd, .gdshader, .gdshaderinc) is minted new rather than copied, and a copied .import gets a fresh uid and its own source path — two files sharing one uid means every uid:// reference resolves to only one of them, so this is not optional and the result names the new uid. An imported asset's .import sidecar IS copied, so the duplicate keeps the source's import settings (filter, mipmaps, compression) instead of falling back to defaults; the editor re-imports the copy on its next filesystem scan. Both endpoints are contained the way move_file's are: source and destination must each land under res://, so \"..\" segments, user:// paths, paths reaching their target through a symbolic link, hidden directories, and the critical project stores (project.godot, the .godot editor cache, the .git history) are refused at either end. Copies never overwrite: an existing file at the destination refuses the copy, so calling this a second time with the same arguments duplicates nothing — choose a different name, or delete_file the existing file first if replacing it is truly intended. Copying a .gd that declares a global class_name leaves two files claiming that class, which the engine rejects; the result says so and the copy's declaration must be changed at once. Nothing else in the project is touched — a copy adds a file rather than moving or removing one, so no existing reference can break and no file needs updating afterwards.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file to duplicate, e.g. \"res://sprites/coin.png\" or \"coin.png\". A bare name is searched for across the project. The file must exist.",
				},
				"to": {
					"type": "string",
					"description": "Where the duplicate goes: a full res:// path including its new file name (\"res://sprites/coin_silver.png\"), or a directory to copy it into under the source's own name — an existing one, or a new one ending in \"/\" (\"res://sprites/variants/\"), created with any missing parents. Must stay under res://, and an existing file there is never overwritten.",
				},
			},
			"required": ["path", "to"],
		},
	},
	"delete_file": {
		"summary": "Delete ONE project file — moved to the system trash (recoverable) with its .uid/.import sidecars; refused while other files still reference it unless force is true.",
		"description": "Delete ONE existing file from the project. The file is moved to the system trash when the platform provides one, so the user can still recover it; only when no trash is available is it permanently removed, and the result says which happened. A .uid or .import sidecar accompanying the file is removed with it. Before anything is deleted the whole project is scanned for references, the same way list_dependencies' reverse mode looks: scenes and resources through engine dependency records (which see UID-based and binary references), scripts and project.godot by literal text match, plus — for a .gd with a global class_name — whole-word mentions of that name. If anything still references the file the deletion is REFUSED and the referencing files are listed: update them first, or pass force true to delete anyway, knowingly breaking them — the same list then comes back as a warning on the result. The usual honest limit applies: a path assembled dynamically in code can't be seen, so a clean scan is strong evidence, not proof. Only files under res:// can be deleted, one per call; directories are refused, a path that escapes the project (\"..\" segments, a user:// path, or one reaching its target through a symbolic link) is refused before anything else, and the critical project files — project.godot, the .godot editor cache, the .git store — are refused even with force. This tool exists only while BOTH the user's \"Make changes\" and \"Delete files\" toggles are on.",
		"max_consecutive_uses": -1,
		"mutating": true,
		"destructive": true,
		"parameters": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "The res:// path or bare file name of the file to delete, e.g. \"res://old_enemy.gd\" or \"old_enemy.gd\". A bare name is searched for across the project. The file must exist.",
				},
				"force": {
					"type": "boolean",
					"description": "Set true to delete even while other files still reference this one, knowingly breaking them (they are listed in the result). Omit (or false) to be refused with the list instead, so a still-wired file is never deleted by accident.",
				},
			},
			"required": ["path"],
		},
	},
}

## Mandatory follow-ups bound to events — the generic registry behind automatic actions, so a new one is a declaration here rather than another one-off mechanism. Each entry names the `event` it fires on ("tool_completed", emitted by execute after every tool call, is the only event so far), the `tools` it applies to ("*" binds it to every tool — the registry's keys aren't reachable from a const expression), and the `action` id _run_hook_action dispatches on (an id rather than a Callable — a const can't hold one). An action returns the text to surface or "" to stay silent; a report is appended to the tool result, so the model and the user both see it (goal 2) and a silent hook costs the context nothing (goal 1). Because execute is shared, hooks fire for the main agent and subagents alike.
const EVENT_HOOKS := [
	{"event": "tool_completed", "tools": ["read_file"], "action": "check_script"},
	{"event": "tool_completed", "tools": ["edit_file", "write_file"], "action": "check_dependents"},
	{"event": "tool_completed", "tools": ["*"], "action": "broken_reminder"},
]

# Most dependent files the automatic cross-file check names before summarizing the rest (see _check_dependents_hook) is user-configurable — see GDLLMTunables' gdllm/tool_output section — so a hub-class rename doesn't flood the context.

## Fallback reflection instruction for a tool that trips its loop guard without declaring its own `loop_break_message`. Both `%s` are the tool's name (see loop_break_message).
const DEFAULT_LOOP_BREAK_MESSAGE := "You've called %s several times in a row without making progress, so the tool loop has been stopped for you. Do not call %s again. In a few sentences addressed to the user, summarize what you were trying to accomplish and what you suspect went wrong. Be concise and honest about the uncertainty."

## Reflection instruction when a run keeps re-running identical calls past the duplicate stubs and repeat notes — the escalation behind GDLLMTunables.WITHHELD_ESCALATION_THRESHOLD; `%d` is the repeat count. Same no-tools redirect flow as a streak guard trip, but asks for a progress account, since the repeats say the model has lost track of where it is.
const DUPLICATE_ESCALATION_MESSAGE := "You have re-run identical tool calls (same tool, same arguments, same unchanged result) %d times this turn, so the tool loop has been stopped for you. Do not repeat any earlier call. In a few sentences addressed to the user, summarize what you have completed so far, what remains, and where you are stuck. Be concise and honest about the uncertainty. If a well-defined chunk of the task remains, you may tell the user you can hand it to a fresh-context helper via the run_subagent tool."

## Stand-in for a tool result whose identical call (same tool, same arguments) already ran this run and returned this same content — a repeat that provably added nothing, so the body is withheld rather than re-served (see GDLLMLoopBrakes.process_result; a mutating tool's repeat instead serves in full behind a repeat note there, since its re-run hit disk again). Gentler than the streak guard: the loop continues, but the repetition is named.
const DUPLICATE_CALL_NUDGE := "Result withheld: this exact call (same tool, same arguments) already ran earlier this turn and returned this exact result — re-read it at the earlier call; re-serving it here would only repeat what this conversation already carries. Repeating the call cannot help — change the arguments or the approach, or stop and tell the user what you're stuck on."

## The closing sentence a tool appends to a failure that a later call genuinely can clear — a condition outside the model's control that resolves on its own, not a mistake in the call.
## It exists as a shared constant because the duplicate brake reads it: a withheld repeat of an invited retry must not answer with DUPLICATE_CALL_NUDGE's "repeating cannot help", which would pit two harness messages against each other (the transcript-measured dead end that motivated EDIT_RETRY_SERVE_NOTE) — so an invitation is a contract with the brake, never hand-written prose.
const TRANSIENT_RETRY_INVITATION := "This is a transient condition, so trying the call again in a moment is worthwhile."

## Stand-in for a repeat of a call whose earlier result carried TRANSIENT_RETRY_INVITATION: the retry was the invited move, so the repetition is not the model's error — but the identical body proves the condition has not cleared, so the answer names that and hands back the two moves that remain instead of re-serving it.
const TRANSIENT_REPEAT_NUDGE := "Result withheld: this exact call already ran earlier this turn and returned this same transient failure, so the condition it named has not cleared yet and the earlier result still stands. Retrying was the right move, but retrying again this turn will not clear it — carry on without what this call would have given you, and tell the user it is unavailable so they can check it themselves."

# search_files' defaults and caps — context lines around a match (an explicit context_lines ask itself is uncapped — see _search_files), excerpt blocks per result, whole-function excerpt length, the overview threshold, function names per overview line, and file-name suggestions on an empty result (the universal suggestion cap) — are user-configurable, kept small by default so a single result stays a narrow-context excerpt rather than a file dump; see GDLLMTunables' gdllm/tool_output section.
## Where installed addons live. A whole-project search sets matches under here aside (counted and disclosed, see _addon_scope_note) because vendored addon code is not the project's own — and this is a boundary about relevance, not about THIS addon: the uid lint's narrow `res://addons/gdllm-godot-agentic-harness/` skip answers a different question (what a match MEANS), and singling out our own directory would leave the other half of the noise in place.
const ADDONS_ROOT := "res://addons/"

## The one-line usage reminder search_files errors carry, so a malformed call (misnamed key, missing query) comes back with the exact expected shape instead of a dead end.
const SEARCH_USAGE := "Put the text to find in \"query\" ({\"query\": \"...\"}) — matched as a literal, case-insensitive substring — plus an optional \"path\" scoping to a file or directory."

# The character count past which read_file stops returning a file whole and has a fresh-context subagent map it instead (overview + function signatures — see _read_file), and the payload count past which a packed-array literal is elided to a count marker (serialized blobs run to kilobytes of base64 on one line, noise no model can interpret — see _elide_packed_arrays; elision runs first, so a blob-heavy but otherwise-short file is read whole rather than pointlessly mapped), are both user-configurable with 0 (or -1) disabling each — see GDLLMTunables' gdllm/tool_output section. Characters, not lines, because context cost is characters: wild-measured, 43% of all whole-file read bytes came from files under the old 1000-line gate but ≥12 KB.

## The packed-array constructors read_file elides, mapped to how many printed numbers make up one element (a Vector3 prints as three), so the marker can report true element counts. PackedStringArray is deliberately absent — its payload is readable text, not a data blob.
const ELIDABLE_PACKED_ARRAYS := {
	"PackedByteArray": 1,
	"PackedInt32Array": 1,
	"PackedInt64Array": 1,
	"PackedFloat32Array": 1,
	"PackedFloat64Array": 1,
	"PackedVector2Array": 2,
	"PackedVector3Array": 3,
	"PackedVector4Array": 4,
	"PackedColorArray": 4,
}

## System prompt for the subagent read_file spins up on a long file: it maps the file for an agent that hasn't seen it — an overview plus every declaration's signature — rather than echoing the code, so the main agent learns the file's shape cheaply and can pull specific code afterward (see _summarize_via_subagent).
const READ_FILE_SUMMARY_SYSTEM_PROMPT := "You are a code-analysis subagent embedded in the Godot editor. You are handed the full text of one source file. Produce a concise map of it for another agent that has NOT seen the file:\n\n1. A short overview (2-4 sentences) of the file's purpose and responsibilities.\n2. Every top-level declaration in source order. For a class or node, give its name and what it extends. For each function, give its full signature — name, parameters (with types when present), and return type — followed by a one-line description of what it does; mark it static when it is. List member variables and constants only briefly, and only when they matter to understanding the file.\n\nDo not reproduce function bodies or paste large code excerpts. Be terse and factual. Output Markdown. The reader can request the actual code of specific functions afterward if they need it."

## System prompt for a subagent the model spins up through the run_subagent tool: a fresh-context helper handed one self-contained task and the context the main agent chose to pass. It can't see the conversation, but it runs its own agentic tool loop (reaching the project's tools through tool_search, just like the main chat), so it can gather what it still needs and hand back only the result — keeping the main agent's working context narrow (see _run_subagent_tool and GDLLMSubagent).
const RUN_SUBAGENT_SYSTEM_PROMPT := "You are a subagent spun up by an AI assistant working inside the Godot editor to handle one self-contained task with a fresh context. You cannot see the main conversation and you cannot ask follow-up questions — but you DO have the project's tools: call tool_search to discover and then use them (reading files, searching the project, and so on) to gather anything you need beyond the task and context you were handed. Work the task through to completion, then return only the result that was asked for: no preamble, no restating of the task, and no commentary about being a subagent or offers to help further. If you genuinely cannot complete the task, say briefly and specifically what stopped you. Use Markdown when it makes the result clearer."

## Longest a delegated subagent's progress-caption label runs before it's truncated with an ellipsis, so a wordy task instruction doesn't sprawl across the caption (see _subagent_task_label).
const SUBAGENT_LABEL_MAX_CHARS := 60

## The one-line usage reminder use_skill errors carry, so a malformed call comes back with the exact expected shape.
const USE_SKILL_USAGE := "Put the skill's name in \"name\" ({\"name\": \"...\"}), exactly as the skills list in your system prompt gives it."

## Argument-name synonyms each tool accepts (see _arg_string), so a model that guesses a natural key — the catalog shows tool names, so it sometimes calls a tool without first fetching its real schema — still resolves instead of being silently ignored. The first entry is the canonical name the tool's schema advertises.
const FILE_PATH_KEYS := ["path", "file", "filename", "filepath"]
const DIR_PATH_KEYS := ["path", "directory", "dir", "folder"]
const SCOPE_PATH_KEYS := ["path", "directory", "dir", "folder", "file", "filename"]
const QUERY_KEYS := ["query", "term", "search", "text", "pattern"]
const CONTEXT_LINES_KEYS := ["context_lines", "context", "lines"]
const SEARCH_FULL_KEYS := ["full", "everything", "no_cap", "all_excerpts", "complete"]
const FUNC_NAME_KEYS := ["name", "function", "func", "function_name", "method"]
const TASK_KEYS := ["task", "prompt", "instruction", "instructions", "request"]
const CONTEXT_KEYS := ["context", "content", "material", "input", "data"]
const SKILL_NAME_KEYS := ["name", "skill", "skill_name"]
const FULL_READ_KEYS := ["full", "full_text", "no_summary", "force_full", "raw", "complete"]
const RANGE_START_KEYS := ["start_line", "start", "from_line", "line_start", "first_line"]
const RANGE_END_KEYS := ["end_line", "end", "to_line", "line_end", "last_line"]
## edit_file argument aliases (see _edit_file), tolerant of a schema-blind call the way the other tools' key lists are; the first entry of each is the canonical name the schema advertises.
const EDIT_OLD_KEYS := ["old_string", "old", "old_str", "old_text", "find", "search", "target", "from"]
const EDIT_NEW_KEYS := ["new_string", "new", "new_str", "new_text", "replacement", "to", "with"]
const EDIT_REPLACE_ALL_KEYS := ["replace_all", "all", "global", "every", "all_occurrences"]
## String.similarity floor under which a fully missed old_string gets no closest-region quote — a dissimilar line would only mislead (see _edit_file_closest_region).
const EDIT_CLOSEST_REGION_FLOOR := 0.6
## edit_resource's property-map argument, tried in order like the other synonym lists so a schema-blind model's natural key still resolves.
const EDIT_RES_PROPERTY_KEYS := ["properties", "props", "values", "vars", "variables", "changes", "fields"]
const CLASS_KEYS := ["class", "class_name", "name", "type"]
## describe_class's `kind` argument, narrowing the report to whole SECTIONS where `filter` narrows it to names — the two axes a question actually comes in. Wild-measured on the real 1666-line Player: "what signals does it emit" costs 9.3 KB as a whole-class report and 1.6 KB as its Signals section, against 14.7 KB for the search_files chain the model reaches for instead, which is the difference between the tool marginally winning and decisively winning.
## Keyed by the canonical name, valued with the section title it selects, so a rung simply matches its own section titles against the requested set.
const CLASS_KINDS := {
	"properties": "Properties",
	"methods": "Methods",
	"signals": "Signals",
	"enums": "Enums",
	"constants": "Constants",
	"constructors": "Constructors",
	"operators": "Operators",
	"inner_classes": "Inner classes",
}
## Spellings folded onto a canonical kind, so a model writing what it means ("functions", "vars", "signal") is not refused over a plural.
const CLASS_KIND_ALIASES := {
	"property": "properties", "var": "properties", "vars": "properties", "variable": "properties",
	"variables": "properties", "field": "properties", "fields": "properties", "export": "properties", "exports": "properties",
	"method": "methods", "function": "methods", "functions": "methods", "func": "methods", "funcs": "methods",
	"signal": "signals", "enum": "enums",
	"constant": "constants", "const": "constants", "consts": "constants",
	"constructor": "constructors", "operator": "operators",
	"inner": "inner_classes", "inner class": "inner_classes", "inner classes": "inner_classes", "classes": "inner_classes",
}
const CLASS_KIND_KEYS := ["kind", "kinds", "member_kind", "section", "sections", "only"]
## "query" is deliberately NOT a filter alias: session logs show a schema-blind model passes the class it wants under "query", so it falls back to the class side (see _class_arg) — as a filter it silently matched nothing.
const MEMBER_FILTER_KEYS := ["filter", "member", "contains", "search"]
const INHERITED_KEYS := ["inherited", "include_inherited", "with_inherited", "all", "ancestors"]
## describe_member's key lists omit "name" from the class side — a bare "name" argument almost always means the member.
const MEMBER_CLASS_KEYS := ["class", "class_name", "type", "target"]
const MEMBER_NAME_KEYS := ["member", "name", "method", "property", "signal", "function", "func", "constant", "enum"]
## describe_docs' member keys omit "name" — with an optional member, a bare "name" almost always means the class/page.
const DOCS_MEMBER_KEYS := ["member", "method", "property", "signal", "function", "func", "constant", "enum", "annotation"]
## The project-settings tools' argument synonyms; the filter side takes "query" too, since a schema-blind model browsing settings reaches for it.
const PROJECT_SETTING_KEYS := ["setting", "name", "key", "property", "option"]
const PROJECT_FILTER_KEYS := ["filter", "section", "prefix", "contains", "search", "query"]
const SET_SETTING_VALUE_KEYS := ["value", "to", "new_value", "val"]
const SET_SETTING_REVERT_KEYS := ["revert", "clear", "remove", "delete", "erase", "reset", "unset"]
const SET_SETTING_CREATE_KEYS := ["create", "force", "new"]
## set_import_setting's batch argument; the singular spellings are here because a model changing one setting reaches for them before it reaches for the plural.
const IMPORT_SETTINGS_KEYS := ["settings", "setting", "params", "options", "values"]
## list_directory's opt-in for the sidecar files it otherwise folds away.
const LIST_SIDECAR_KEYS := ["sidecars", "show_sidecars", "include_sidecars", "all"]
# list_directory's row cap is user-configurable (see GDLLMTunables' gdllm/tool_output section; the largest legitimate directory measured in a real project ran 163 rows, and the wild overflow was res://.godot/imported at ~700 cache entries per call), and the opt-out below waives it ("all" belongs to the sidecar list above, so it is not an alias here).
const LIST_FULL_KEYS := ["full", "full_list", "no_cap", "complete", "everything"]
## The console tools' argument synonyms: read_output's line tail, read_errors' entry limit, and the substring filter both share, tolerant of schema-blind calls like the other lists.
const CONSOLE_LINES_KEYS := ["lines", "count", "limit", "tail", "last", "n"]
const CONSOLE_LIMIT_KEYS := ["limit", "count", "errors", "tail", "last", "n", "max"]
const CONSOLE_FILTER_KEYS := ["filter", "contains", "search", "grep", "match", "query", "text"]
## The run tools' argument synonyms, tolerant of schema-blind calls like the other lists; run_script's path side adds "script", the key a model naturally reaches for there.
const RUN_SCENE_KEYS := ["scene", "path", "file", "scene_path", "filename", "target"]
const RUN_WAIT_KEYS := ["wait_seconds", "wait", "seconds", "duration", "time"]
const RUN_KEEP_KEYS := ["keep_running", "keep", "stay", "background", "leave_running"]
const RUN_ARGS_KEYS := ["args", "arguments", "argv", "params"]
const RUN_SHOW_KEYS := ["show", "debug_draw", "draw", "overlays", "visible", "visualize"]
const RUN_TIMEOUT_KEYS := ["timeout_seconds", "timeout", "max_seconds", "limit"]
const RUN_SCRIPT_PATH_KEYS := ["path", "script", "file", "filename", "filepath"]

## One-line usage reminders the run tools' argument errors carry, in the SEARCH_USAGE pattern.
const RUN_GAME_USAGE := "All arguments are optional: \"scene\" plays one scene (res:// path) instead of the main scene, \"wait_seconds\" sets the capture window (default {tunable:run_game_default_wait_seconds}, max {tunable:run_game_max_wait_seconds}), \"keep_running\": true leaves the game up for the user afterwards, and \"show\": [\"collisions\"] draws debug overlays in the run."
const RUN_SCRIPT_USAGE := "Pass the script in \"path\" ({\"path\": \"res://checks/my_check.gd\"}) — it must extend SceneTree and end with quit(); optionally \"args\" (an array of strings the script reads via OS.get_cmdline_user_args()) and \"timeout_seconds\" (default {tunable:run_script_default_timeout_seconds}, max {tunable:run_script_max_timeout_seconds})."

## The tools that execute project code — game runs, headless scripts, the game-driving tools that feed input into or call methods on a live run, and stepping a paused one back into motion. They ride the `mutating` gate (executed code can change anything the edit tools can), and _dispatch words their refusal as running code rather than modifying files.
const RUN_TOOLS := ["run_game", "stop_game", "run_script", "send_game_input", "call_game_method", "debug_game", "suspend_game", "reload_game_scripts"]

## The tools that change WHERE the project's code stops rather than running any of it. They ride the same `mutating` gate — a breakpoint halts the user's run at a line they did not choose, and that halt blocks every other game tool — with their own refusal wording, since claiming set_breakpoint runs or modifies anything would be a lie the model repeats to the user.
const DEBUG_TOOLS := ["set_breakpoint"]

## Tools whose IDENTICAL call does the work again rather than returning a stale answer: stepping a frame, arming or clearing a breakpoint, replaying an input, pushing a reload, resuming a paused game, running a script, re-importing an asset (a no-settings set_import_setting call is a rebuild), re-taking the user's focus to a place they navigated away from. Their results are numbered from the second occurrence on (see GDLLMRepeats), because the duplicate brake reads identical content as a repeat that added nothing and four such firings end the turn — measured, on four of these tools. Membership is the whole opt-in: a new tool that does real work on repeat joins this list and needs no numbering code of its own.
const REPEAT_REAL_WORK_TOOLS := ["suspend_game", "set_breakpoint", "send_game_input", "reload_game_scripts", "debug_game", "run_script", "set_import_setting", "open_for_user"]

# run_game's capture-window bounds (default covering boot plus first frames, cap keeping one call from parking the tool loop for minutes) are user-configurable — see GDLLMTunables' gdllm/tool_runtime section.
# How long after launch the editor may report no playing scene before run_game calls the launch failed (rather than mistaking slow boot for an instant crash) is user-configurable — see GDLLMTunables' gdllm/tool_runtime section.
# run_script's timeout bounds (the model may raise the default up to the cap, since a legitimate script can compute longer than a load check) and its output-line relay cap (more generous than the console default because a killed or finished subprocess's output has nowhere else to live — what it drops, only a re-run can reprint) are user-configurable — see GDLLMTunables' gdllm/tool_runtime and gdllm/tool_output sections.

## The game-driving tools' argument synonyms and usage lines, in the same tolerant-key pattern; the step dictionaries inside send_game_input's array have their own tolerant keys in GDLLMGameProtocol.
const GAME_SCOPE_KEYS := ["path", "node", "node_path", "scope", "under"]
const GAME_ALL_KEYS := ["all", "all_nodes", "everything", "nodes", "full"]
const GAME_STEPS_KEYS := ["steps", "sequence", "inputs", "input", "events"]
const GAME_CALL_PATH_KEYS := ["path", "node", "node_path", "target", "control"]
const GAME_METHOD_KEYS := ["method", "function", "func", "call", "name"]
const GAME_CALL_ARGS_KEYS := ["args", "arguments", "params", "parameters", "values"]
const READ_GAME_UI_USAGE := "All arguments are optional: \"filter\" finds nodes by name, class or label anywhere in the tree (e.g. {\"filter\": \"Player\"}), \"path\" scopes the snapshot to one live subtree (e.g. \"/root/Main/UI\"), and \"all\": true lists every node instead of only controls."
const CALL_GAME_METHOD_USAGE := "Pass the live node in \"path\" and the method in \"method\" ({\"path\": \"/root/Main/Player\", \"method\": \"take_damage\", \"args\": [10]}); \"args\" is optional."
const GAME_FILTER_KEYS := ["filter", "contains", "search", "match", "query", "name"]
## inspect_game_node's engine-properties switch, in the tolerant-key pattern; "engine" and "properties" are what a model reaches for when it wants the other half.
const INSPECT_ALL_KEYS := ["all", "engine", "engine_properties", "properties", "everything", "full"]
const INSPECT_GAME_NODE_USAGE := "Pass the live node in \"path\" ({\"path\": \"/root/Main/Player\"}); \"filter\" optionally narrows to properties whose name contains it, and \"all\": true adds the engine's own properties."
## suspend_game's argument synonyms and the spellings of each action, in the tolerant-key pattern the rest of the tools use; "pause"/"freeze" land here rather than on debug_game, whose own aliases deliberately leave them out.
const SUSPEND_ACTION_KEYS := ["action", "state", "op", "command", "do", "mode"]
const SUSPEND_FRAMES_KEYS := ["frames", "count", "steps", "times", "n"]
const SUSPEND_ALIASES := {
	"on": "on", "true": "on", "suspend": "on", "freeze": "on", "pause": "on", "stop": "on", "halt": "on", "hold": "on",
	"off": "off", "false": "off", "resume": "off", "unsuspend": "off", "unfreeze": "off", "unpause": "off", "continue": "off", "run": "off", "go": "off",
	"frame": "frame", "frames": "frame", "step": "frame", "advance": "frame", "next": "frame", "next_frame": "frame", "tick": "frame",
}
const SUSPEND_GAME_USAGE := "Pass \"action\": \"on\" to freeze the game, \"off\" to let it run again, or \"frame\" to advance a few frames ({\"action\": \"frame\", \"frames\": 3})."
# The most frames one suspend_game call may advance (stepping stays a bounded look rather than an unattended run) and the whole call's wall-clock stepping budget (a game too slow to confirm its frames reports how many it managed rather than parking the tool loop) are user-configurable — see GDLLMTunables' gdllm/tool_runtime section.
# The frame-landed poll interval and the wait for a stepped frame's prints to cross the debugger (a suspended game answers slowly, and the whole point of stepping one frame is to see what it printed) are user-configurable — see GDLLMTunables' gdllm/tool_runtime section.

## reload_game_scripts' argument synonyms and usage; the cap on how many changed scripts one reload pushes before the list is refused as too broad to be a targeted fix is user-configurable — see GDLLMTunables' gdllm/tool_runtime section.
const RELOAD_PATHS_KEYS := ["paths", "path", "files", "file", "scripts", "script"]
const RELOAD_GAME_SCRIPTS_USAGE := "Call it with no arguments to reload every .gd changed since the run started, or pass \"paths\": [\"res://player.gd\"] to reload specific files."
## The editor's Debug-menu run flags, as the project-metadata keys the engine reads at launch (EditorSettings project metadata, section "debug_options"), keyed by the name run_game's `show` takes. Both hot-reload flags are set for every run this session starts: the reload message needs BOTH armed at launch or it silently breaks the running scripts instead of updating them (probe-verified on 4.7).
const RUN_DEBUG_OPTIONS := {
	"collisions": "run_debug_collisions",
	"navigation": "run_debug_navigation",
	"paths": "run_debug_paths",
	"avoidance": "run_debug_avoidance",
	"redraw": "run_debug_canvas_redraw",
}
const RUN_DEBUG_ALIASES := {
	"collisions": "collisions", "collision": "collisions", "shapes": "collisions", "collision_shapes": "collisions", "physics": "collisions",
	"navigation": "navigation", "nav": "navigation", "navmesh": "navigation",
	"paths": "paths", "path": "paths", "curves": "paths",
	"avoidance": "avoidance", "agents": "avoidance",
	"redraw": "redraw", "canvas_redraw": "redraw", "canvas": "redraw", "repaint": "redraw",
}
## The two flags a run must be launched with for reload_game_scripts to work at all.
const RUN_RELOAD_OPTIONS := ["run_live_debug", "run_reload_scripts"]
## How each overlay reads in a result, where the argument name is a keyword and this is what the user will see drawn.
const RUN_OVERLAY_LABELS := {
	"collisions": "collision shapes and contact points",
	"navigation": "navigation meshes and links",
	"paths": "Path2D/Path3D curves",
	"avoidance": "avoidance agent radii",
	"redraw": "canvas redraw flashes",
}
# How much longer than the sequence itself the editor waits for the input reply, and the flat wait for snapshot/call replies, are user-configurable — see GDLLMTunables' gdllm/tool_runtime section.

## The debugging tools' argument synonyms and usage lines, in the same tolerant-key pattern.
const BREAK_FRAME_KEYS := ["frame", "stack_frame", "level", "index"]
const BREAK_ALL_KEYS := ["all", "globals", "everything", "full", "verbose"]
const BREAK_ACTION_KEYS := ["action", "step", "op", "command", "do"]
const BREAK_TIMES_KEYS := ["times", "count", "repeat", "steps", "n"]
const BREAK_PATH_KEYS := ["path", "script", "file", "filename", "filepath"]
const BREAK_LINE_KEYS := ["line", "line_number", "lineno", "at_line"]
const BREAK_REMOVE_KEYS := ["remove", "clear", "disable", "off", "delete"]
const READ_GAME_BREAK_USAGE := "All arguments are optional: \"frame\" reports a caller instead of the innermost frame (0 is where execution stopped) and \"all\": true includes the frame's globals."
const DEBUG_GAME_USAGE := "Pass \"action\" as one of \"break\" (halt a running game), \"continue\", \"step\" (into), \"next\" (over), or \"out\" ({\"action\": \"next\", \"times\": 3}); \"times\" repeats a step up to {tunable:debug_game_max_steps} times."
const SET_BREAKPOINT_USAGE := "Pass the script in \"path\" and the 1-based \"line\" ({\"path\": \"res://player.gd\", \"line\": 42}); add \"remove\": true to clear it, or \"remove\": true with no line to clear every breakpoint this session armed."
# How long one step press may take to land the next break, the shorter window a resume is watched for an immediate second break, and the frames the script editor gets to build the breakpoint gutter are user-configurable — see GDLLMTunables' gdllm/tool_runtime section.

## The performance tools' argument synonyms and usage lines, in the same tolerant-key pattern; run_game's profile flag rides its own list, and doubles as a profiler selector there.
const PERF_SECONDS_KEYS := ["seconds", "window", "duration", "last", "time"]
const PERF_ALL_KEYS := ["all", "everything", "full", "verbose"]
const PERF_MODE_KEYS := ["mode", "profiler", "kind", "type", "which", "target"]
const PERF_ROWS_KEYS := ["limit", "count", "rows", "top", "max", "n"]
const PERF_FILTER_KEYS := ["filter", "contains", "search", "match", "query", "name"]
const RUN_PROFILE_KEYS := ["profile", "profiler", "profile_functions"]
const VRAM_LIMIT_KEYS := ["limit", "count", "rows", "top", "max", "n"]
const VRAM_FILTER_KEYS := ["filter", "contains", "search", "grep", "match", "query", "path", "name"]
const READ_PERFORMANCE_USAGE := "All arguments are optional: \"seconds\" sets the summary window (default {tunable:performance_default_window_seconds}, max {tunable:performance_history_seconds}) and \"all\": true reports every built-in monitor instead of the curated set."
const PROFILE_GAME_USAGE := "All arguments are optional: \"seconds\" sets how long the profiler samples the live game (default {tunable:profile_game_default_seconds}, max {tunable:profile_game_max_seconds}), \"mode\" picks which profiler — \"functions\" (default), \"visual\", or \"network\" — and \"limit\"/\"filter\" control the report rows (raise the row cap, or match rows by name)."
const READ_VIDEO_RAM_USAGE := "Both arguments are optional: \"limit\" sets how many of the largest resources to list (default {tunable:video_ram_default_rows}, max {tunable:video_ram_max_rows}) and \"filter\" keeps only rows whose path, type, or format contains it (e.g. \"res://textures\")."
# profile_game's sampling-window bounds are user-configurable — see GDLLMTunables' gdllm/tool_runtime section.
# The Video RAM refresh reply wait and the clicked-control record settle are user-configurable — see GDLLMTunables' gdllm/tool_runtime section. The game drains click records at about one per second (probe-measured: adjacent clicks' records arrive almost exactly 1000 ms apart), so the last click's record trails the sequence's reply by up to a second; the settle default covers the dominant one-or-two-click case, and the composer's wording owns the cadence for longer chains rather than claiming a miss for a record still queued.
## list_dependencies' argument synonyms; the reverse side accepts the natural "who uses this" spellings.
const DEPS_PATH_KEYS := ["path", "file", "filename", "filepath", "resource", "target"]
const DEPS_REVERSE_KEYS := ["reverse", "users", "usages", "referenced_by", "reverse_deps", "who_uses", "uses"]
## create_resource argument synonyms, same tolerance pattern as the read/scene tools; "from" carries the resource's starting point and "path" its destination.
const CREATE_FROM_KEYS := ["from", "source", "base", "template", "class", "type"]
const CREATE_PATH_KEYS := ["path", "destination", "dest", "to", "target", "save_path", "file"]
const CREATE_PROPERTIES_KEYS := ["properties", "props", "values", "fields", "set"]
const CREATE_OVERWRITE_KEYS := ["overwrite", "force", "replace"]
## The key naming an inline sub-resource spec's base (see _edit_res_coerce_inline_object); "script" is canonical, the rest schema-blind tolerance.
const INLINE_OBJECT_BASE_KEYS := ["script", "class", "type", "from", "base"]

## One-line usage reminders for the docs-search, dependency, and project-settings tools, in the SEARCH_USAGE pattern.
const SEARCH_DOCS_USAGE := "Put two or three concept words in \"query\" ({\"query\": \"text wrap\"}) — every word must appear in a single doc entry's name or prose."
const LIST_DEPENDENCIES_USAGE := "Pass the file in \"path\" ({\"path\": \"res://icon.svg\"}); add \"reverse\": true to list what USES the file instead of what it depends on."
const DESCRIBE_PROJECT_USAGE := "All arguments are optional: \"setting\" reads one exact setting (e.g. \"input/jump\"), \"filter\" lists every setting whose name contains it (e.g. \"display/window\"), and neither gives the project overview."
const SET_PROJECT_SETTING_USAGE := "Pass \"setting\" (e.g. \"input/jump\", \"autoload/GameState\", \"application/run/main_scene\") and \"value\" (for an input action, event strings like \"Space\" or \"JoyButton:0\"); \"revert\": true restores the default or removes a custom entry."
const SET_IMPORT_SETTING_USAGE := "Pass the ASSET in \"path\" ({\"path\": \"res://sprites/hero.png\"}) and optionally \"settings\" as an object ({\"compress/mode\": 0}); with no settings the asset is simply re-imported."
## The extensions whose files carry engine dependency records; everything else is text for the purposes of dependency tracing.
const DEP_RESOURCE_EXTENSIONS := ["tscn", "scn", "tres", "res"]
# The most dependency/user lines one list_dependencies result prints before collapsing the rest (in the narrow-context spirit) is user-configurable — see GDLLMTunables' gdllm/tool_output section.

## The one-line usage reminder create_resource errors carry, so a malformed call comes back with the expected shape instead of a dead end.
const CREATE_RESOURCE_USAGE :="Pass \"from\" (a .tres/.res path, a built-in Resource class like \"StandardMaterial3D\", or a script class/res:// .gd path) and \"path\" (the res:// destination ending in .tres or .res); optionally \"properties\" (name→value) and \"overwrite\" (true to replace an existing file)."
## describe_scene's selector keys include "path"/"file" — a model passing a path to this tool means an open scene's file; the node-path keys deliberately omit "path", which on describe_scene_file must keep meaning the scene file.
const SCENE_SELECT_KEYS := ["scene", "path", "scene_path", "file", "filename", "root"]
const NODE_PATH_KEYS := ["node_path", "node", "nodepath", "node_name", "target"]
const DEPTH_KEYS := ["depth", "max_depth", "levels"]
const SCENE_FILTER_KEYS := ["filter", "contains", "search", "property"]
const TILEMAP_LAYER_KEYS := ["layer", "node", "node_path", "layer_name", "target"]
const TILEMAP_RECT_KEYS := ["rect", "window", "region", "bounds"]
const TILESET_KIND_KEYS := ["kind", "kinds", "section", "sections", "only"]
const TILESET_FILTER_KEYS := ["filter", "contains", "search", "name"]
const READ_TILEMAP_USAGE := "Omit arguments for the currently edited scene, or pass \"scene\" ({\"scene\": \"res://x.tscn\"}) for a saved one; optional \"layer\" zooms into one TileMapLayer as a grid and \"rect\" ([x, y, width, height] in cells) windows that grid."
const DESCRIBE_TILESET_USAGE := "Pass the TileSet in \"path\" ({\"path\": \"res://tiles.tres\"}, or a .tscn to describe the TileSet its layers use), plus optional \"kind\" (sources/terrains/custom_data), \"filter\" (name substring), and \"layer\" (which layer's TileSet, for a scene using several)."
const EDIT_TILEMAP_USAGE := "Pass \"scene\" (the .tscn), \"layer\" (name or path), and exactly ONE action: \"cells\" ([{at, source, atlas?, alt?}]), \"fill\" ({rect, source, atlas?}), \"replace\" ({from, to, rect?}), \"erase\" ({cells|rect|source}), or \"terrain\" ({cells|rect, terrain}). Sources and terrains go by name or id."

## Animation tool argument aliases and usage reminders, in the same tolerant-key pattern as the tilemap tools.
const ANIMATION_NAME_KEYS := ["animation", "anim", "animation_name", "clip"]
const ANIMATION_PLAYER_KEYS := ["player", "animation_player", "node"]
const ANIMATION_WINDOW_KEYS := ["window", "time_window", "range"]
const DESCRIBE_ANIMATION_USAGE := "Omit arguments for the currently edited scene, or pass \"scene\" ({\"scene\": \"res://x.tscn\"} — a scene file, or an Animation/AnimationLibrary .tres); optional \"animation\" zooms into one animation's tracks and keys, \"player\" picks one AnimationPlayer, and \"window\" ([start_sec, end_sec]) narrows the key listing."
const EDIT_ANIMATION_USAGE := "Pass \"scene\" (the .tscn or .tres), \"animation\" (its name — describe_animation lists them), and exactly ONE action: \"add_track\", \"remove_track\", \"move_track\", \"insert_key\", \"set_key\", or \"remove_key\" — or \"add_animation\"/\"remove_animation\", which name their library instead of \"animation\"."

## One-line usage reminders the scene inspection tools' argument errors carry, like SEARCH_USAGE, so a malformed call comes back with the expected shape instead of a dead end.
const DESCRIBE_SCENE_USAGE := "All arguments are optional: \"scene\" picks an open scene by its res:// path, file name, or root node name; \"node_path\" zooms into one node (e.g. \"Player/Sprite2D\", \".\" for the root); \"depth\" limits the tree depth; \"filter\" (with node_path) narrows the node's properties and connections by name, values printed whole."
const DESCRIBE_SCENE_FILE_USAGE := "Pass the scene file in \"path\" ({\"path\": \"res://x.tscn\"}), plus an optional \"node_path\" to zoom into one node (e.g. \"Player/Sprite2D\"), \"depth\" to limit the tree depth, and \"filter\" (with node_path) to narrow the node's properties and connections by name, values printed whole."

## The editor-awareness tools' argument synonyms and usage lines, in the same tolerant-key pattern as the other lists.
const UNDO_WINDOW_KEYS := ["window", "count", "limit", "last", "n", "actions"]
const OPEN_LINE_KEYS := ["line", "line_number", "at_line", "row"]
const OPEN_REVEAL_KEYS := ["reveal", "reveal_only", "select_only", "locate", "show_in_filesystem"]
const READ_UNDO_HISTORY_USAGE := "The one argument is optional: \"window\" is how many recent actions each history shows (default {tunable:undo_history_default_window}, capped at {tunable:undo_history_max_window})."
const OPEN_FOR_USER_USAGE := "Pass the file in \"path\" ({\"path\": \"res://player/player.gd\"}); optionally \"line\" (1-based) opens a script at that line, and \"reveal\": true selects the file in the FileSystem dock instead of opening it."
# read_undo_history's window bounds (the default covers a working stretch of edits, and the cap keeps a history of user actions from ever dumping whole) are user-configurable — see GDLLMTunables' gdllm/tool_output section.

## edit_file's one-line usage reminder, like SEARCH_USAGE, and the lines of context shown on each side of the changed region in the result excerpt so a confirmation stays a narrow snippet, not a file dump.
const EDIT_FILE_USAGE := "Pass \"path\" plus \"old_string\" (the exact text to replace) and \"new_string\" (its replacement); add \"replace_all\": true to change every occurrence instead of requiring a unique match."

# The most located errors a validation report shows with an excerpt (so a badly broken file doesn't flood the result) is user-configurable — see GDLLMTunables' gdllm/tool_output section.

## write_file argument aliases and usage reminder, in the same tolerant-key pattern as the other tools.
const WRITE_CONTENT_KEYS := ["content", "text", "contents", "body", "source", "data"]
const WRITE_FILE_USAGE := "Pass \"path\" (the res:// destination, with extension) and \"content\" (the COMPLETE text the file will hold — an existing file is replaced wholesale)."
## write_file's force flag: waives the blind-overwrite read gate and the phantom-duplicate collision refusal, nothing else. Deliberately NOT "overwrite" — a model passes that key spontaneously on any intentional replacement, which would waive the read gate on exactly the hallucinated-content calls it exists to catch; force/confirm are only ever sent in answer to a refusal.
const WRITE_FORCE_KEYS := ["force", "confirm"]

## delete_file's force flag, tried in order like the other synonym lists so a schema-blind model's natural key still resolves.
const DELETE_FORCE_KEYS := ["force", "force_delete", "confirm"]

const DELETE_FILE_USAGE := "Pass the file to delete in \"path\" ({\"path\": \"res://old.gd\"}); add \"force\": true only after accounting for the files the refusal listed as still referencing it."
# The excerpt's context lines per side, and the most changed lines an edit confirmation echoes before the middle is counted instead (the replacement text already sits in the conversation as the call's own arguments, so a long echo pays for it twice; the head and tail with real line numbers carry the placement, which is the new information), are user-configurable — see GDLLMTunables' gdllm/tool_output section.

## move_file/rename_file argument aliases and usage reminders, in the same tolerant-key pattern; force shares delete's accounting framing but never overrides containment or overwriting.
const MOVE_DEST_KEYS := ["to", "destination", "dest", "new_path", "target", "into"]
const RENAME_NAME_KEYS := ["new_name", "name", "to", "rename_to", "new_filename"]
const MOVE_FORCE_KEYS := ["force", "confirm"]
const MOVE_FILE_USAGE := "Pass the file in \"path\" and the destination in \"to\" — a full res:// file path, or a directory (existing, or ending in \"/\") to move it into ({\"path\": \"res://old/enemy.gd\", \"to\": \"res://actors/\"}); add \"force\": true only after accounting for the files the refusal listed as still referencing the old path."
const RENAME_FILE_USAGE := "Pass the file in \"path\" and its bare new file name in \"new_name\" ({\"path\": \"res://enemy.gd\", \"new_name\": \"goblin.gd\"}); to change its directory use move_file instead."

## copy_file argument aliases and usage reminder. A duplicate names two files, so the source list carries the role words a schema-blind model reaches for ("source", "from") on top of the usual path keys.
const COPY_SOURCE_KEYS := ["path", "source", "from", "file", "filename", "filepath"]
const COPY_DEST_KEYS := ["to", "destination", "dest", "new_path", "target", "copy_to", "into"]
const COPY_FILE_USAGE := "Pass the file to duplicate in \"path\" and the copy's location in \"to\" — a full res:// path with the new file name, or a directory (existing, or ending in \"/\") to copy it into under its own name ({\"path\": \"res://sprites/coin.png\", \"to\": \"res://sprites/coin_silver.png\"})."

# The wall-clock cap on one headless validation subprocess is user-configurable — see GDLLMTunables' gdllm/tool_runtime section. The checks normally finish in well under a second, but a run can wedge outright (observed contending with a live editor), and an unbounded wait there freezes the whole editor with it.

## Completion sentinels for the script-driven validation subprocesses: a run whose output lacks its pattern died before finishing, so its (possibly empty) error list is no verdict — load_check.gd prints the marker explicitly, while the linter's mandatory OK/Failure summary doubles as its own.
const LOAD_CHECK_DONE_PATTERN := "(?m)^GDLLM_CHECK_DONE$"
const LINT_DONE_PATTERN := "(?m)^(OK|Failure): "

## The file types whose uid lives in a "<path>.uid" sidecar rather than inside the file, so a NEW one has no uid at all until something mints it — probe-verified against the editor's own scan, which mints exactly these three (a .tscn/.tres carries its uid in its own header instead, and an imported asset in its .import).
const SIDECAR_UID_EXTENSIONS := ["gd", "gdshader", "gdshaderinc"]

## The source files the engine can be asked to compile on demand, and which of them is a shader — the two ride one validation path (see _classified_source_errors), differing only in the style lint, which is GDScript's alone.
const CHECKABLE_SOURCE_EXTENSIONS := ["gd", "gdshader"]
const SHADER_EXTENSION := "gdshader"

## The stderr markers tools/load_check.gd brackets one shader's compile with, so an error raised while some other shader loaded can't be blamed on the checked file (see _shader_errors_from_output).
const SHADER_BEGIN_MARKER := "GDLLM_SHADER_BEGIN: "
const SHADER_END_MARKER := "GDLLM_SHADER_END: "

## How a located shader error announces that the compiler reached it through an #include, so the verdict composers can tell "this file is wrong" from "a file this one pulls in is wrong" without re-parsing the message.
const INCLUDE_ERROR_PREFIX := "the #include'd file "

## The prefix a ShaderMaterial stores each of its shader's uniforms under, both in its property list and in the .tres — the difference between the name a uniform is declared with and the name it is set by (see _edit_res_resolve_name).
const SHADER_PARAMETER_PREFIX := "shader_parameter/"

## Every shader type the engine has. A compile refused for an unsupported type names a real mistake only when the declared type isn't one of these — otherwise the checker, not the file, is what fell short, and the run reports no verdict rather than an invented error.
const SHADER_TYPES := ["spatial", "canvas_item", "particles", "sky", "fog"]

## The engine's own wordings the shader compile speaks in, matched rather than reproduced: the SHADER ERROR channel, the refusal that names a shader type, and the null-shader complaint an empty file earns when the loader never set any code at all.
const SHADER_ERROR_MARKER := "SHADER ERROR:"
const SHADER_TYPE_REFUSAL := "Shader type (.*?) not supported in .* renderer\\."
const SHADER_ABSENT_MARKER := "Parameter \"shader\" is null."

# The cap on the child-output line quoted into a dead validation run's why (one line names the cause without spilling an error cascade into context) is user-configurable — see GDLLMTunables' gdllm/tool_output section.

## The `why` a validator reports when cancel_running_checks interrupted it, phrased to complete "the engine validation run …" in a result line.
const CHECK_CANCELLED_WHY := "was cancelled before it finished"

# describe_class's caps — the most members one section prints before it's truncated with a note steering the model to a `filter` substring (base classes like Node/Control have hundreds of methods), and the most near-miss class names suggested when a lookup doesn't resolve (the universal suggestion cap) — are user-configurable, kept small by default in the narrow-context spirit; see GDLLMTunables' gdllm/tool_output section.

## Theme-item kind → the theme_override_* property namespace that sets it per node, for the pointer describe_class/describe_member add when a Control lookup misses (see _theme_item_note).
const THEME_OVERRIDE_NAMESPACES := {
	"color": "theme_override_colors",
	"font": "theme_override_fonts",
	"font_size": "theme_override_font_sizes",
	"stylebox": "theme_override_styles",
	"constant": "theme_override_constants",
	"icon": "theme_override_icons",
}

# The scene-inspection caps — tree lines per result, property/connection lines per node's detail, and the rendered-value clip (a packed array or long text must never flood a result) — are user-configurable, kept small by default in the narrow-context spirit; see GDLLMTunables' gdllm/tool_output section.

## The ledger for callers that pass execute() none — the headless test scripts — so single-session runs need no setup; every in-editor caller passes its session's own (see SessionLedger at the end of this file).
static var _fallback_ledger := SessionLedger.new()

## Cooperative guards for the in-editor async tool chain, where a tool run can now yield frames mid-flight; everything resumes on the main thread, so plain flags are race-free. Headless runs never suspend (see _yield_frame), so each guard is provably a no-op there.
static var _mutation_busy := false ## a whole edit_file/write_file run is in flight; a second mutation interleaving could clobber its validation window
static var _baseline_paths: Dictionary = {} ## files whose on-disk text is temporarily the PRE-edit original while a validation baseline runs, by resolved path
static var _scan_count := 0 ## whole-project scans running on worker threads; a mutation must not start while one reads the tree
static var _live_check_pids: Dictionary = {} ## validation subprocesses currently running, so Stop can kill them instead of waiting them out
static var _check_epoch := 0 ## advances on cancel_running_checks; validators capture it on entry and bail once it moves
static var _game_run: Dictionary = {} ## the play session run_game started and still owns ({"scene", "started_ms", "output_base", "errors_base"}); emptied when the run ends, and an editor reload wipes it, so stop_game refuses any run it can't prove it started


## The Ollama/OpenAI-style function schema for `tool_search`, the one tool attached to every tools-enabled request, with the live catalog appended to its description (see _catalog for what the flags control). The description steers the model to reach here before answering from memory whenever it needs to act on the project.
static func tool_search_schema(allow_changes: bool = false, allow_delete: bool = false, active_tools: Dictionary = {}, retirement_disclosed: bool = false) -> Dictionary:
	var schema := _schema(TOOL_SEARCH, TOOL_SEARCH_TOOL)
	if retirement_disclosed:
		schema["function"]["description"] += "\n\n" + TOOL_SEARCH_RETIREMENT_NOTE
	schema["function"]["description"] = GDLLMTunables.fill(String(schema["function"]["description"]) + "\n\n" + _catalog(allow_changes, allow_delete, active_tools))
	return schema


## The catalog of registered tools — one "- name(args): summary" line each — built from REGISTRY at call time so it never drifts from the tools actually available. A tool in `active_tools` is marked "attached" so the model doesn't re-search tools it already holds (a transcript-observed habit). While `allow_changes` is off, mutating tools are omitted rather than listed as disabled — dead weight in the context — and one closing line says so, so the model asks the user rather than concluding the capability doesn't exist; destructive tools get the same treatment under `allow_delete`, each gate named by its own toggle.
static func _catalog(allow_changes: bool = false, allow_delete: bool = false, active_tools: Dictionary = {}) -> String:
	var lines: Array = ["Available tools — call tool_search with a name to get that tool's parameters:"]
	var hidden := 0
	var hidden_destructive := 0
	for name in REGISTRY:
		var entry: Dictionary = REGISTRY[name]
		if not allow_changes and bool(entry.get("mutating", false)):
			hidden += 1
			continue
		if not allow_delete and bool(entry.get("destructive", false)):
			hidden_destructive += 1
			continue
		var marker := " (attached — call directly)" if active_tools.has(name) else ""
		lines.append("- %s%s%s: %s" % [name, _params_hint(entry), marker, entry.get("summary", entry["description"])])
	if hidden > 0:
		lines.append("Tools that modify the project (files, resources, scenes) or run its code also exist but are hidden because the user's \"Make changes\" toggle is off; if a task needs to change or run something, ask the user to turn on Make changes.")
	if hidden_destructive > 0:
		lines.append("Tools that DELETE project files also exist but are hidden because the user's \"Delete files\" toggle is off; if a task truly needs a deletion, ask the user to turn on Delete files (next to Make changes).")
	return "\n".join(lines)


## Compact "(class, filter?)" signature for a catalog line — the canonical parameter names, optionals marked "?" — so a model that calls a tool by name without ever fetching its schema still reaches for the right keys (session logs show wrong-key guesses like "query" were the main tool-failure mode).
static func _params_hint(entry: Dictionary) -> String:
	var params: Dictionary = entry.get("parameters", {})
	var properties: Dictionary = params.get("properties", {})
	if properties.is_empty():
		return ""
	var required: Array = params.get("required", [])
	var names: Array = []
	for prop in properties:
		names.append(String(prop) + ("" if prop in required else "?"))
	return "(%s)" % ", ".join(names)


## The function schema for a registered tool by name, ready to drop into a request's `tools` array; {} if the name isn't registered.
static func schema_for(name: String) -> Dictionary:
	if not REGISTRY.has(name):
		return {}
	return _schema(name, REGISTRY[name])


static func is_registered(name: String) -> bool:
	return REGISTRY.has(name)


## The registered tools the first `count` messages of a stored history had activated — every tool an assistant turn called plus every tool a tool_search result returned, minus any a persisted cache-boundary retirement detached — so a reload (and the debug context reconstruction) restores the same set live activation and retirement built. `count` < 0 walks the whole history. Shared by _reactivate_tools_from_history and _tools_active_as_of in the chat session.
static func active_tools_from_history(history: Array, count: int = -1) -> Dictionary:
	var active: Dictionary = {}
	var limit := history.size() if count < 0 else mini(count, history.size())
	for i in limit:
		var msg: Dictionary = history[i]
		var role := String(msg.get("role", ""))
		# An attachment's synthetic call turn is the user's doing, not a model call: the live session never attaches a schema for it, so replaying one here would give a reloaded session a tool footprint its live requests never carried (the model reaches read_file through tool_search when it needs the re-read).
		if role == "assistant" and msg.has("tool_calls") and not bool(msg.get("attachment", false)):
			for tc in msg["tool_calls"]:
				var called := tool_call_name(tc)
				if called != "" and called != TOOL_SEARCH and REGISTRY.has(called):
					active[called] = true
		elif role == "tool" and String(msg.get("tool_name", "")) == TOOL_SEARCH:
			for searched in _search_result_names(String(msg.get("content", ""))):
				if REGISTRY.has(searched):
					active[searched] = true
		# A persisted cache-boundary retirement detached these schemas at this point; replaying it in order keeps the rebuilt set matching what each request actually carried (a later re-search re-adds).
		elif role == "notice" and String(msg.get("kind", "")) == "cache_boundary":
			for retired in msg.get("retired", []):
				active.erase(String(retired))
	return active


## Per-tool recency rebuilt from a stored history — {"turns": user-message count, "last_used": {tool: the user turn it last ran or (re)attached}} — the same clocks live tracking maintains, so a reloaded session ages tools against their real past instead of retiring everything at the first boundary.
static func tool_usage_from_history(history: Array) -> Dictionary:
	var turn := 0
	var last_used: Dictionary = {}
	for msg_v in history:
		var msg: Dictionary = msg_v
		var role := String(msg.get("role", ""))
		if role == "user":
			turn += 1
		# A user attachment's synthetic call turn never activated anything, so it must not stamp a recency clock either (see active_tools_from_history).
		elif role == "assistant" and msg.has("tool_calls") and not bool(msg.get("attachment", false)):
			for tc in msg["tool_calls"]:
				var called := tool_call_name(tc)
				if called != "" and REGISTRY.has(called):
					last_used[called] = turn
		elif role == "tool" and String(msg.get("tool_name", "")) == TOOL_SEARCH:
			# Attachment counts as use, so a tool searched but not yet called ages from its search, not from zero.
			for searched in _search_result_names(String(msg.get("content", ""))):
				if REGISTRY.has(searched):
					last_used[searched] = turn
	return {"turns": turn, "last_used": last_used}


## Whether any cache-boundary retirement happened within the first `count` messages (-1 = all) — the reload and per-turn-inspector source for tool_search's retirement_disclosed latch, read off the same persisted notices active_tools_from_history replays.
static func retirement_in_history(history: Array, count: int = -1) -> bool:
	var limit := history.size() if count < 0 else mini(count, history.size())
	for i in limit:
		var msg: Dictionary = history[i]
		if String(msg.get("role", "")) == "notice" and String(msg.get("kind", "")) == "cache_boundary":
			return true
	return false


## The attached tools an imminent cache rewrite can drop for free: idle for at least GDLLMTunables.SCHEMA_RETIRE_IDLE_TURNS user turns (no recorded use counts as idle forever), sorted so notices and tests are deterministic. tool_search is never a candidate — it is the way back.
static func schema_retirement_candidates(active: Dictionary, last_used: Dictionary, current_turn: int) -> PackedStringArray:
	var retired := PackedStringArray()
	for name in active:
		if String(name) == TOOL_SEARCH:
			continue
		if current_turn - int(last_used.get(name, 0)) >= GDLLMTunables.geti(GDLLMTunables.SCHEMA_RETIRE_IDLE_TURNS):
			retired.append(String(name))
	retired.sort()
	return retired


## The tool names a stored tool_search result activated, parsed back out of its JSON content; the no-match and already-attached results are plain text and yield none. Parsed through a JSON instance because JSON.parse_string logs a console error for every non-JSON result it walks past.
static func _search_result_names(content: String) -> PackedStringArray:
	var names := PackedStringArray()
	if not content.begins_with("{"):
		return names
	var json := JSON.new()
	if json.parse(content) != OK or not (json.data is Dictionary):
		return names
	for entry in json.data.get("tools", []):
		if entry is Dictionary and entry.has("name"):
			names.append(String(entry["name"]))
	return names


## Whether a tool modifies the project (files, resources, settings) rather than only reading it, per its REGISTRY `mutating` flag. Mutating tools are hidden from the catalog, filtered from search, refused by execute, and dropped from a request's attached tools while the session's "Make changes" toggle is off.
static func is_mutating(name: String) -> bool:
	return bool(_definition_for(name).get("mutating", false))


## Whether a tool destroys project files rather than only changing them, per its REGISTRY `destructive` flag — a stricter tier than `mutating` (every destructive tool is also mutating), gated the same four ways by the session's "Delete files" toggle.
static func is_destructive(name: String) -> bool:
	return bool(_definition_for(name).get("destructive", false))


## The loop break point for a tool: how many times it may be called in consecutive rounds (with no other tool in between) before the session trips its redirect guard. A negative value disables the check, letting the tool repeat without limit.
static func max_consecutive_uses(name: String) -> int:
	return int(_definition_for(name).get("max_consecutive_uses", -1))


## The one-off reflection instruction injected when a tool trips its loop guard, asking the model to explain itself before the stop notice shows (the session sends it as a user turn with no tools attached and never stores it). A tool may declare its own tailored `loop_break_message` otherwise DEFAULT_LOOP_BREAK_MESSAGE is used, naming the tool.
static func loop_break_message(name: String) -> String:
	var custom := String(_definition_for(name).get("loop_break_message", ""))
	# fill() rides along for future-proofing: no break message carries a {tunable:...} token today, but this is a model-visible surface and must stay covered if one ever does.
	return GDLLMTunables.fill(custom if custom != "" else DEFAULT_LOOP_BREAK_MESSAGE % [name, name])


## Nudge appended to a round's last tool result when the run's rounds ping-pong A→B→A→B between two tools AND some call in the cycle re-returned an already-seen result — a cycle the single-tool streak guard can't see, named only once the repeat proves it isn't converging (see GDLLMLoopBrakes.oscillation_nudge). Like DUPLICATE_CALL_NUDGE the loop continues; the pattern is only named, to the model and the user alike.
static func oscillation_nudge(a: String, b: String) -> String:
	return "\n\nNote: your last four tool rounds alternated %s → %s → %s → %s, and at least one of those calls re-returned a result you had already seen — the cycle is not converging. Break it: change your approach, or stop and tell the user what you're trying to do and what's blocking you." % [a, b, a, b]


## The definition dict for a tool by name — tool_search's own or its REGISTRY entry — or {} if the name isn't a known tool. The single lookup shared by max_consecutive_uses so tool_search and registered tools read their fields identically.
static func _definition_for(name: String) -> Dictionary:
	if name == TOOL_SEARCH:
		return TOOL_SEARCH_TOOL
	if REGISTRY.has(name):
		return REGISTRY[name]
	return {}


## Wrap a tool definition ({description, parameters, ...}) in the Ollama/OpenAI function-schema envelope under `name`. Extra fields on the definition (like max_consecutive_uses) are left out, so they never reach the model.
static func _schema(name: String, entry: Dictionary) -> Dictionary:
	# Tool prose quotes its own defaults and caps as {tunable:...} tokens; fill() substitutes the values currently configured, so the model is never told a number the settings no longer hold. The parameters pass rides a JSON round-trip to reach the nested per-argument descriptions without walking the dict by hand.
	var parameters: Variant = entry["parameters"]
	var params_json := JSON.stringify(parameters)
	if params_json.contains("{tunable:"):
		var filled: Variant = JSON.parse_string(GDLLMTunables.fill(params_json))
		if filled is Dictionary:
			parameters = filled
	return {
		"type": "function",
		"function": {
			"name": name,
			"description": GDLLMTunables.fill(String(entry["description"])),
			"parameters": parameters,
		},
	}


## Registered tools matching `query`, most-relevant first, each as {name, description, parameters}. A query word that exactly names a tool returns just the named tool(s) — the model picked from the catalog, so nothing else should ride along. Otherwise a tool matches only when EVERY query word appears in its name or one-line summary; any looser rule returned most of the registry for vague queries, so matches are strict, with ties broken toward name matches. The GDLLMTunables.TOOL_SEARCH_MAX_RESULTS activation cap is applied — and disclosed — by _tool_search, not here, so a silent cut never masquerades as the whole match set. Mutating tools are excluded while `allow_changes` is off — and destructive ones while `allow_delete` is off — matching the catalog, so a search can never activate a tool the session would refuse to run.
static func search(query: String, allow_changes: bool = false, allow_delete: bool = false) -> Array:
	var terms := query.to_lower().split(" ", false)
	var named: Array = []
	var scored: Array = []
	for name in REGISTRY:
		var entry: Dictionary = REGISTRY[name]
		if not allow_changes and bool(entry.get("mutating", false)):
			continue
		if not allow_delete and bool(entry.get("destructive", false)):
			continue
		var result := {"name": String(name), "description": entry["description"], "parameters": entry["parameters"]}
		if terms.has(String(name)):
			named.append(result)
			continue
		var haystack := String(name) + " " + String(entry.get("summary", entry["description"])).to_lower()
		var name_hits := 0
		var matched_all := not terms.is_empty()
		for term in terms:
			if not haystack.contains(term):
				matched_all = false
				break
			if String(name).contains(term):
				name_hits += 1
		if not matched_all:
			continue
		result["_score"] = name_hits
		scored.append(result)
	if not named.is_empty():
		return named
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["_score"] > b["_score"])
	var results: Array = []
	for entry in scored:
		entry.erase("_score")
		results.append(entry)
	return results


## The tools `query` would have matched with the session's gates open, as {name, remedy} entries, empty when both gates are already on. The catalog tells the model that hidden tools exist, so a search naming one must say which toggle hides it — the generic no-match text contradicts the catalog, and transcripts show a model concluding from it that the capability does not exist at all and telling the user so.
static func _gate_blocked_matches(query: String, allow_changes: bool, allow_delete: bool) -> Array:
	if allow_changes and allow_delete:
		return []
	var blocked: Array = []
	for match_entry in search(query, true, true):
		var name := String(match_entry["name"])
		var entry: Dictionary = REGISTRY[name]
		var remedy := ""
		if not allow_delete and bool(entry.get("destructive", false)):
			# A destructive tool needs both toggles, so naming only Delete files would send the user to a switch that alone changes nothing.
			remedy = "the user's \"Delete files\" toggle is off — ask the user to turn on Delete files (next to Make changes)" if allow_changes else "the user's \"Make changes\" and \"Delete files\" toggles are both off — ask the user to turn on both"
		elif not allow_changes and bool(entry.get("mutating", false)):
			remedy = "the user's \"Make changes\" toggle is off — ask the user to turn on Make changes"
		if remedy != "":
			blocked.append({"name": name, "remedy": remedy})
	return blocked


## A tool_search call's {content, activate}: every match comes back as a slim {name, summary?, note} entry, never its full schema — activation already attaches the schema to the next request's tools array, so serializing it into the result too would duplicate it in permanent history on every later request (the old first-time behavior this replaces, forward-only so stored results stay byte-identical for prompt caches). Each note includes the tool's call shape — transcripts show weak models re-search precisely when they've lost the calling syntax, and ignore a bare "do not search again" — and a fresh match adds its catalog summary so the model can pick among several. A search that only re-finds attached tools skips the JSON block entirely, and one that matched nothing only because a gate hid the tool names it and the toggle instead (see _gate_blocked_matches). Entries keep the {"tools": [{"name": …}]} shape active_tools_from_history parses to restore activations on reload. `activate` still names every match; re-activating an attached tool is a no-op.
static func _tool_search(query: String, allow_changes: bool, allow_delete: bool, active_tools: Dictionary) -> Dictionary:
	var matches := search(query, allow_changes, allow_delete)
	# The activation cap lands here so it can be disclosed: everything returned attaches to all later turns, but a silent top-5 read as "only 5 matched" (audit-caught).
	var total := matches.size()
	if total > GDLLMTunables.geti(GDLLMTunables.TOOL_SEARCH_MAX_RESULTS):
		matches = matches.slice(0, GDLLMTunables.geti(GDLLMTunables.TOOL_SEARCH_MAX_RESULTS))
	var activate := PackedStringArray()
	var attached := PackedStringArray()
	var entries: Array = []
	for match_entry in matches:
		var match_name := String(match_entry["name"])
		activate.append(match_name)
		var definition := _definition_for(match_name)
		if active_tools.has(match_name):
			attached.append(match_name)
			entries.append({"name": match_name, "note": "already attached — do not search for it again; call it now, as %s%s" % [match_name, _params_hint(definition)]})
		else:
			entries.append({"name": match_name, "summary": GDLLMTunables.fill(String(definition.get("summary", definition["description"]))), "note": "now attached to your tools — call it as %s%s" % [match_name, _params_hint(definition)]})
	var content: String
	if matches.is_empty():
		var blocked := _gate_blocked_matches(query, allow_changes, allow_delete)
		if not blocked.is_empty():
			var blocked_lines := PackedStringArray()
			for item in blocked:
				blocked_lines.append("\"%s\" exists but is hidden because %s." % [item["name"], item["remedy"]])
			return {"content": " ".join(blocked_lines) + " Nothing was attached; the capability exists, so do not tell the user it is missing — ask for the toggle, then search again.", "activate": activate}
		content = "No matching tools found. This searches the tool catalog in tool_search's description, never project files or code; retry with a tool's exact name from that list, or one or two capability words (every word must match a tool's name or catalog line)."
	elif attached.size() == matches.size():
		var shapes := PackedStringArray()
		for name in attached:
			shapes.append(name + _params_hint(_definition_for(name)))
		content = "Already attached: %s. The full definition is already in your tools list, so do NOT call tool_search again — your next action must be to CALL the tool itself: %s." % [", ".join(attached), ", ".join(shapes)]
	else:
		var payload := {"tools": entries}
		if total > GDLLMTunables.geti(GDLLMTunables.TOOL_SEARCH_MAX_RESULTS):
			payload["note"] = "top %d of %d matches attached — add a word to narrow, or name one tool from the catalog exactly" % [GDLLMTunables.geti(GDLLMTunables.TOOL_SEARCH_MAX_RESULTS), total]
		content = JSON.stringify(payload, "\t")
	return {"content": content, "activate": activate}


## Run a tool call and return {"content": String, "activate": PackedStringArray}: `content` is the result fed back to the model as the tool message, and `activate` names the tools the session should attach to later turns (a search activates everything it returned; other tools activate nothing). A tool may instead return a third key, "subagent" — a {system, prompt, label, result_preamble, tools} spec the session runs in a fresh-context model, using its reply (prefixed with result_preamble) as the tool result; see _summarize_via_subagent and _run_subagent_tool, the two producers. `allow_changes` off refuses mutating tools here — the last line of defense behind the catalog/search filtering, since a stale schema or hallucinated call can still name one — and `allow_delete` off refuses destructive tools the same way. `ledger` is the calling session's SessionLedger — its subagents pass the same one, and a caller passing none (the headless tests) shares _fallback_ledger. `repeat_owner` scopes the repeat numbering to the caller (a session or one subagent run), UNLIKE the shared ledger: repeat counts belong to one agent's turn, and a shared count would tag a fresh subagent's first call as a repeat someone else made. Unknown names return an error message rather than raising, so a hallucinated call surfaces to the model instead of breaking the loop. Every completed call flows through _apply_hooks, so EVENT_HOOKS follow-ups fire uniformly no matter which tool ran or who called it. In-editor, execute is a coroutine — mutations, subprocess checks, and scans yield frames instead of blocking the editor — so callers must await it; headless nothing ever suspends, so it resolves synchronously (the test scripts rely on this).
static func execute(name: String, args: Dictionary, allow_changes: bool = false, allow_delete: bool = false, active_tools: Dictionary = {}, ledger: SessionLedger = null, repeat_owner: String = "") -> Dictionary:
	if ledger == null:
		ledger = _fallback_ledger
	return await _apply_hooks("tool_completed", name, args, _note_repeat(name, args, await _dispatch(name, args, allow_changes, allow_delete, active_tools, ledger), repeat_owner), ledger)


## Number a repeated call whose work really happened again, so its result stops rendering identically to the last one. This is the shared half of the honesty rule the loop brake depends on: the brake keeps its full force (a genuinely pointless repeat still returns identical content and is still caught), while a tool that CHANGED something says so. A refusal is left alone — it changed nothing, so an identical one is exactly the repeat the brake should catch.
static func _note_repeat(name: String, args: Dictionary, result: Dictionary, repeat_owner: String = "") -> Dictionary:
	if not REPEAT_REAL_WORK_TOOLS.has(name):
		return result
	var content := String(result.get("content", ""))
	if content.begins_with("Error"):
		return result
	var tag := GDLLMRepeats.turn_tag(GDLLMRepeats.bump_turn(GDLLMRepeats.signature(name, args), repeat_owner))
	if tag == "":
		return result
	result["content"] = content + tag
	return result


## Yield one editor frame. Headless runs skip the suspension entirely — the test scripts call execute synchronously from SceneTree._init, where frames never iterate — so every await in the tool chain resolves immediately there and execute stays synchronous outside the editor.
static func _yield_frame() -> void:
	if Engine.is_editor_hint():
		await Engine.get_main_loop().process_frame


## Serialize whole edit_file/write_file runs: validation yields frames, and a second mutation interleaving mid-run could clobber the first one's baseline restore. Also waits out worker scans so a mutation never rewrites files a scan is reading; run_on_worker holds the counter side of that bargain. Release is a plain `_mutation_busy = false` by whoever acquired.
static func _acquire_mutation_lock() -> void:
	while _mutation_busy or _scan_count > 0:
		await _yield_frame()
	_mutation_busy = true


## Wait out any validation baseline window holding `res_path`'s PRE-edit text on disk, so a concurrent read never returns content the model would mistake for current.
static func _await_path_stable(res_path: String) -> void:
	while _baseline_paths.has(res_path):
		await _yield_frame()


## Run `job` on a worker thread and return its result, yielding editor frames until it finishes; headless it runs inline so tests stay synchronous. Jobs must touch only thread-safe APIs (FileAccess/DirAccess/RegEx/ResourceLoader) and return plain data — never EditorInterface, the scene tree, or the tool layer's statics. Entry waits out any in-flight mutation and the scan counter keeps a mutation from starting mid-scan in return (see _acquire_mutation_lock).
static func run_on_worker(job: Callable) -> Variant:
	if not Engine.is_editor_hint():
		return job.call()
	while _mutation_busy:
		await _yield_frame()
	_scan_count += 1
	var box: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void: box[0] = job.call())
	while not WorkerThreadPool.is_task_completed(task):
		await Engine.get_main_loop().process_frame
	# The pool requires this call to release the task; it returns instantly once completed.
	WorkerThreadPool.wait_for_task_completion(task)
	_scan_count -= 1
	return box[0]


## Stop-button escape hatch: kill every live validation subprocess and advance the epoch so in-flight validators skip their remaining engine runs (restoring the edited content first) instead of riding out up to four checks.
static func cancel_running_checks() -> void:
	_check_epoch += 1
	for pid in _live_check_pids:
		OS.kill(int(pid))


## The per-tool dispatch behind execute, separated so the event hooks wrap every tool through one seam.
static func _dispatch(name: String, args: Dictionary, allow_changes: bool, allow_delete: bool, active_tools: Dictionary, ledger: SessionLedger) -> Dictionary:
	if name == TOOL_SEARCH:
		return _tool_search(String(args.get("query", "")), allow_changes, allow_delete, active_tools)
	if is_mutating(name) and not allow_changes:
		# The run tools ride the mutating gate but don't rewrite files, so the refusal names what they actually do — a message claiming run_game "modifies the project" would be a lie the model repeats to the user.
		if DEBUG_TOOLS.has(name):
			return {"content": "Error: \"%s\" changes where the project's code halts — a breakpoint pauses the running game at that line — which the user's \"Make changes\" toggle also gates, and that toggle is off. Ask the user to turn on Make changes if the task needs the game stopped on a line, or work from read_output and read_errors instead." % name, "activate": PackedStringArray()}
		if RUN_TOOLS.has(name):
			return {"content": "Error: \"%s\" runs the project's own code, which the user's \"Make changes\" toggle also gates, and that toggle is off. Ask the user to turn on Make changes if the task truly needs a run, or continue without running." % name, "activate": PackedStringArray()}
		return {"content": "Error: \"%s\" modifies the project, and the user's \"Make changes\" toggle is off. Ask the user to turn on Make changes if the task truly needs it, or continue read-only." % name, "activate": PackedStringArray()}
	if is_destructive(name) and not allow_delete:
		return {"content": "Error: \"%s\" deletes project files, and the user's \"Delete files\" toggle is off. Ask the user to turn on Delete files (next to Make changes) if the task truly needs it, or continue without deleting." % name, "activate": PackedStringArray()}
	if name == "read_file":
		return await _read_file(args, ledger)
	if name == "read_function":
		return _plain(await _read_function(args, ledger))
	if name == "check_script":
		return _plain(await _check_script(args, ledger))
	if name == "read_output":
		return _plain(GDLLMConsole.read_output(_arg_int(args, CONSOLE_LINES_KEYS, 0), _arg_string(args, CONSOLE_FILTER_KEYS)))
	if name == "read_errors":
		return _plain(_read_errors(args, ledger))
	if name == "run_game":
		return _plain(await _run_game(args))
	if name == "stop_game":
		return _plain(await _stop_game())
	if name == "run_script":
		return _plain(await _run_script(args))
	if name == "read_performance":
		return _plain(_read_performance(args))
	if name == "profile_game":
		return _plain(await _profile_game(args))
	if name == "read_video_ram":
		return _plain(await _read_video_ram(args))
	if name == "suspend_game":
		return _plain(await _suspend_game(args))
	if name == "reload_game_scripts":
		return _plain(await _reload_game_scripts(args))
	if name == "read_game_ui":
		return _plain(await _read_game_ui(args))
	if name == "inspect_game_node":
		return _plain(await _inspect_game_node(args))
	if name == "send_game_input":
		return _plain(await _send_game_input(args))
	if name == "call_game_method":
		return _plain(await _call_game_method(args))
	if name == "read_game_break":
		return _plain(await _read_game_break(args))
	if name == "debug_game":
		return _plain(await _debug_game(args))
	if name == "set_breakpoint":
		return _plain(await _set_breakpoint(args))
	if name == "list_directory":
		return {"content": _list_directory(args), "activate": PackedStringArray()}
	if name == "search_files":
		return {"content": await _search_files(args, ledger), "activate": PackedStringArray()}
	if name == "describe_class":
		return _plain(await _describe_class(args))
	if name == "describe_member":
		return _plain(await _describe_member(args))
	if name == "describe_docs":
		return _plain(await GDLLMDocs.describe(_class_arg(args, CLASS_KEYS), _arg_string(args, DOCS_MEMBER_KEYS), _arg_bool(args, FULL_READ_KEYS)))
	if name == "search_docs":
		return _plain(await _search_docs(args))
	if name == "list_dependencies":
		return _plain(await _list_dependencies(args))
	if name == "describe_project":
		return _plain(_describe_project(args))
	if name == "set_project_setting":
		return _plain(_set_project_setting(args))
	if name == "set_import_setting":
		return _plain(await _set_import_setting(args))
	if name == "describe_scene":
		return _plain(_describe_scene(args))
	if name == "describe_scene_file":
		return _plain(_describe_scene_file(args))
	if name == "read_editor_selection":
		return _plain(_read_editor_selection())
	if name == "read_undo_history":
		return _plain(_read_undo_history(args))
	if name == "open_for_user":
		return _plain(_open_for_user(args))
	if name == "read_tilemap":
		return _plain(_read_tilemap(args))
	if name == "describe_tileset":
		return _plain(_describe_tileset(args))
	if name == "edit_tilemap":
		return _plain(await _edit_tilemap(args))
	if name == "describe_animation":
		return _plain(_describe_animation(args))
	if name == "edit_animation":
		return _plain(await _edit_animation(args))
	if name == "run_subagent":
		return _run_subagent_tool(args)
	if name == "use_skill":
		return _plain(await _use_skill(args, ledger))
	if name == "create_resource":
		return _plain(_create_res_tool(args))
	if name == "edit_file":
		return await _edit_file(args, ledger)
	if name == "write_file":
		return _plain(await _write_file(args, ledger))
	if name == "move_file":
		return _plain(await _move_file(args, ledger, false))
	if name == "rename_file":
		return _plain(await _move_file(args, ledger, true))
	if name == "copy_file":
		return _plain(await _copy_file(args, ledger))
	if name == "delete_file":
		return _plain(await _delete_file(args, ledger))
	if name == "edit_resource":
		return _plain(_edit_resource(args))
	return {"content": _unknown_tool_message(name), "activate": PackedStringArray()}


## The unknown-tool error, coached toward recovery: transcripts show hallucinated names (e.g. a literal "tool_call") stalling models because the bare error named no way forward. Near-miss registered names are suggested — a registered tool can be called directly by its exact name — and the tool_search route is spelled out for the rest.
static func _unknown_tool_message(name: String) -> String:
	var candidates: Array = [TOOL_SEARCH]
	for registered in REGISTRY:
		candidates.append(String(registered))
	var near := _create_res_near_miss(name, candidates)
	var hint := ""
	if not near.is_empty():
		hint = " Did you mean %s?" % ", ".join(PackedStringArray(near))
	return "Error: unknown tool \"%s\".%s Tools are discovered with tool_search: its description lists every available tool — call tool_search with a tool's exact name or one or two capability words ({\"query\": \"...\"}), then call the tool it returns by that exact name." % [name, hint]


## Fire every EVENT_HOOKS entry bound to `event` whose `tools` include this call, appending each action's report to the result so the model and the user both see it in the tool message. A result that defers to a subagent has no content yet, so a report rides its result_preamble and lands ahead of the subagent's eventual reply instead.
static func _apply_hooks(event: String, name: String, args: Dictionary, result: Dictionary, ledger: SessionLedger) -> Dictionary:
	for hook: Dictionary in EVENT_HOOKS:
		var bound := Array(hook["tools"])
		if String(hook["event"]) != event or not (bound.has("*") or bound.has(name)):
			continue
		var report: String = await _run_hook_action(String(hook["action"]), args, result, ledger)
		if report == "":
			continue
		if result.has("subagent"):
			result["subagent"]["result_preamble"] = report + "\n\n" + String(result["subagent"].get("result_preamble", ""))
		else:
			result["content"] = String(result.get("content", "")) + "\n\n" + report
	return result


## Dispatch one EVENT_HOOKS action id to its implementation, returning the text to surface ("" to stay silent); an unknown id is ignored so a stale registry entry can't break the tool loop.
static func _run_hook_action(action: String, args: Dictionary, result: Dictionary, ledger: SessionLedger) -> String:
	match action:
		"check_script":
			return await _check_script_hook(args, result, ledger)
		"check_dependents":
			return await _check_dependents_hook(args, result, ledger)
		"broken_reminder":
			return _broken_reminder_hook(args, result, ledger)
	return ""


## The check_script hook action: after a tool touches a .gd or .gdshader, compile-check it and report only when errors exist, so a clean file costs the context nothing while a broken one is flagged before the model builds on it. A call that itself failed is skipped — its own error is the story.
static func _check_script_hook(args: Dictionary, result: Dictionary, ledger: SessionLedger) -> String:
	var resolved := _resolve_file_path(_arg_string(args, FILE_PATH_KEYS))
	if resolved == "" or not CHECKABLE_SOURCE_EXTENSIONS.has(resolved.get_extension().to_lower()):
		return ""
	if String(result.get("content", "")).begins_with("Error:"):
		return ""
	var classified: Dictionary = await _classified_source_errors(resolved)
	# A dead check is disclosed instead of silently passing for clean — and it must not settle the ledgers below on a verdict that never existed.
	if not bool(classified["ok"]):
		return "Automatic check_script: the engine check on %s %s — the file was NOT validated; validation appears to be down right now, so don't re-check — if you change this file, tell the user the change goes unvalidated." % [resolved, String(classified["why"])]
	var errors: Array = classified["own_located"]
	if errors.is_empty():
		ledger.auto_check_reports.erase(resolved)
		# Engine truth that the file is clean also settles the broken-file ledger, wherever the fix came from.
		ledger.broken_files.erase(resolved)
		return ""
	# Transcript-observed: a broken-but-untouched file (48 pre-existing errors) re-dumps its full report on every read; an unchanged error set is collapsed to one self-sufficient line instead.
	var fingerprint := _error_set_fingerprint(errors)
	if String(ledger.auto_check_reports.get(resolved, "")) == fingerprint:
		# broken_files membership means an edit/write verdict blamed the model this run — those are its own unfixed errors, and calling them "pre-existing" coaxed a session into abandoning a file it broke.
		if ledger.broken_files.has(resolved):
			return "Automatic check_script: %s still has the same %d parse/compile error(s) YOUR earlier edit introduced this editor run — they remain unfixed and fixing them is your top priority; run check_script on it if you need the full list again." % [resolved, errors.size()]
		return "Automatic check_script: %s still has the same %d parse/compile error(s) last reported this editor run — unchanged and likely pre-existing; run check_script on it if you need the full list again." % [resolved, errors.size()]
	ledger.auto_check_reports[resolved] = fingerprint
	return "Automatic check_script: %s currently has %d parse/compile error(s) — account for them before building on this file:\n%s%s%s%s" % [resolved, errors.size(), "\n".join(PackedStringArray(_grouped_problem_lines(errors))), _uid_error_attribution(errors, ledger), _shader_stop_note(resolved, errors), _foreign_noise_note(classified["foreign"], resolved)]


## The check_dependents hook action: after a successful edit_file/write_file changes a .gd's top-level class_name or extends, name the files that build on it — the break is invisible locally, since this file validates clean while dependents fail with "Could not find base class". The dependent set is found textually (like list_dependencies' reverse mode) rather than by parse-checking each dependent, because the editor refreshes its global class cache asynchronously after the write, and a headless recheck racing that refresh would pass on the stale cache and miss the break. Silent when nothing changed or nothing depends on the file, so the common write costs the context nothing.
static func _check_dependents_hook(args: Dictionary, result: Dictionary, ledger: SessionLedger) -> String:
	var resolved := _resolve_file_path(_arg_string(args, FILE_PATH_KEYS))
	if resolved == "" or resolved.get_extension().to_lower() != "gd":
		return ""
	var content := String(result.get("content", ""))
	# A failed call changed nothing, and a file left broken is its own louder story — dependents can wait until it parses again.
	if content.begins_with("Error:") or content.contains("BROKEN on disk"):
		return ""
	# No previous generation means a brand-new file, which can't have taken a declaration away from anyone.
	var original := String(ledger.previous_contents.get(resolved, ""))
	if original == "":
		return ""
	var before := _script_declarations(original)
	var after := _script_declarations(FileAccess.get_file_as_string(resolved))
	var old_class := String(before["class_name"])
	var new_class := String(after["class_name"])
	var report := PackedStringArray()
	if old_class != new_class and old_class != "":
		var mentions: Dictionary = await _dependent_mentions(resolved, old_class, false)
		if int(mentions["total"]) > 0:
			var what := ("renamed `class_name %s` to `%s`" % [old_class, new_class]) if new_class != "" else ("REMOVED `class_name %s`" % old_class)
			report.append("Automatic dependent check: this write %s, but %d other file(s) still use the name %s and will break (\"Could not find base class\", an unresolved identifier) even though this file itself validates clean. Update them now, or restore the class_name:\n%s" % [what, mentions["total"], old_class, "\n".join(mentions["lines"])])
	if String(before["extends"]) != String(after["extends"]) and String(before["extends"]) != "":
		var users: Dictionary = await _dependent_mentions(resolved, new_class, true)
		if int(users["total"]) > 0:
			report.append("Automatic dependent check: this write changed the script's base type (extends %s → %s), and %d file(s) build on this script — the API and node type they inherit changed with it, so verify each still works:\n%s" % [before["extends"], after["extends"], users["total"], "\n".join(users["lines"])])
	if report.is_empty():
		return ""
	return "\n\n".join(report) + "\nThis check is textual, with the same honest limits as list_dependencies' reverse mode: a name assembled dynamically can't be seen, and a mention inside a comment can be a false positive."


## The broken_reminder hook action: while files an earlier verdict left BROKEN stay unfixed, unrelated calls are reminded of them — transcript-observed: a model wandered off a broken file and claimed success. Silent while the completed call is about a broken file itself (the repair is presumably underway), while the result already reports an error or a break (that story is louder), and for a cooldown of further calls after each firing (SessionLedger.broken_reminder_cooldown) so it never becomes a per-call nag.
static func _broken_reminder_hook(args: Dictionary, result: Dictionary, ledger: SessionLedger) -> String:
	if ledger.broken_reminder_cooldown > 0:
		ledger.broken_reminder_cooldown -= 1
		return ""
	if ledger.broken_files.is_empty():
		return ""
	var resolved := _resolve_file_path(_arg_string(args, FILE_PATH_KEYS))
	if resolved != "" and ledger.broken_files.has(resolved):
		return ""
	var content := String(result.get("content", ""))
	if content.begins_with("Error:") or content.contains("BROKEN"):
		return ""
	var paths: Array = ledger.broken_files.keys()
	paths.sort()
	ledger.broken_reminder_cooldown = GDLLMTunables.geti(GDLLMTunables.BROKEN_REMINDER_COOLDOWN)
	return "Automatic reminder: you left %d file(s) BROKEN on disk and have not fixed them yet: %s. Fix them with edit_file before finishing." % [paths.size(), ", ".join(paths)]


## The top-level class_name and extends declarations of a GDScript source, as {"class_name", "extends"} with "" for an absent one — tolerant of the combined "class_name X extends Y" line and of trailing comments. Scanning stops at the first real top-level statement, past which the declarations can no longer legally appear.
static func _script_declarations(text: String) -> Dictionary:
	var decl := {"class_name": "", "extends": ""}
	for line in text.split("\n"):
		if line.begins_with("\t") or line.begins_with(" "):
			continue
		var code := line
		var comment_at := code.find("#")
		if comment_at >= 0:
			code = code.substr(0, comment_at)
		code = code.strip_edges()
		if code == "":
			continue
		if code.begins_with("class_name "):
			var rest := code.trim_prefix("class_name ").strip_edges()
			var ext_at := rest.find(" extends ")
			if ext_at >= 0:
				decl["extends"] = rest.substr(ext_at + " extends ".length()).strip_edges()
				rest = rest.substr(0, ext_at).strip_edges()
			decl["class_name"] = rest
		elif code.begins_with("extends "):
			decl["extends"] = code.trim_prefix("extends ").strip_edges()
		elif not code.begins_with("@"):
			break
	return decl


## Worker wrapper for _dependent_mentions_scan — the whole-project walk runs off the main thread in-editor (see run_on_worker).
static func _dependent_mentions(resolved: String, class_word: String, include_path_refs: bool) -> Dictionary:
	var out: Dictionary = await run_on_worker(func() -> Dictionary: return _dependent_mentions_scan(resolved, class_word, include_path_refs))
	return out


## The project files leaning on `resolved`, as {"total": int, "lines": Array} of "- path (why)" entries capped at GDLLMTunables.DEPENDENT_MENTIONS_CAP with an honest remainder line: whole-word mentions of `class_word` (skipped when ""), plus — when `include_path_refs` — path/uid references through engine dependency records for scenes/resources and literal text match for scripts and project.godot, mirroring _reverse_dependencies. The word check needs the text form, so binary .scn/.res are only seen through their dependency records.
static func _dependent_mentions_scan(resolved: String, class_word: String, include_path_refs: bool) -> Dictionary:
	var uid_text := _uid_text_for(resolved)
	var word: RegEx = null
	if class_word != "":
		word = RegEx.create_from_string("\\b%s\\b" % class_word)
		if not word.is_valid():
			word = null # a mangled class_name (mid-typo write) must not break the hook
	var files: Array = []
	_collect_text_files("res://", files)
	var hits: Array = []
	for path_v in files:
		var path := String(path_v)
		if path == resolved:
			continue
		var ext := path.get_extension().to_lower()
		var is_resource := DEP_RESOURCE_EXTENSIONS.has(ext)
		if ext != "gd" and not is_resource and path.get_file() != "project.godot":
			continue
		if word != null and not _looks_binary(path) and word.search(FileAccess.get_file_as_string(path)) != null:
			hits.append("- %s (mentions %s)" % [path, class_word])
			continue
		if include_path_refs:
			var marker := _deps_reference_marker(path, resolved, uid_text) if is_resource else _text_reference_marker(path, resolved, uid_text)
			if marker != "-":
				hits.append("- %s (references it by path%s)" % [path, marker])
	var total := hits.size()
	if total > GDLLMTunables.geti(GDLLMTunables.DEPENDENT_MENTIONS_CAP):
		hits = hits.slice(0, GDLLMTunables.geti(GDLLMTunables.DEPENDENT_MENTIONS_CAP))
		# With path refs in play the overflow can hold engine-record references search_files structurally misses (UID-based, binary .scn/.res) — the lever that sees those is list_dependencies.
		var levers := "search_files, or list_dependencies with reverse: true," if include_path_refs else "search_files"
		hits.append("(and %d more — %s for the rest)" % [total - GDLLMTunables.geti(GDLLMTunables.DEPENDENT_MENTIONS_CAP), levers])
	return {"total": total, "lines": hits}


## The tool name out of one Ollama tool_call ({"function": {"name", "arguments"}}), or "" if malformed. Shared by the chat session and by subagents, which both drive the tool loop.
## GLM-family models occasionally leak their raw tool-call template — "name\n<arg_key>k</arg_key><arg_value>v</arg_value>" — into the name field when Ollama's server-side parser trips mid-call, so keep only the bare name that precedes the markup.
static func tool_call_name(tc: Variant) -> String:
	if tc is Dictionary and tc.get("function") is Dictionary:
		return _clean_tool_name(String(tc["function"].get("name", "")))
	return ""


## Drop any leaked template markup from a function name: keep the leading token before the first newline or angle bracket, since real tool names contain neither.
static func _clean_tool_name(raw: String) -> String:
	var cut := raw.length()
	for delim in ["\n", "<", ">"]:
		var at := raw.find(delim)
		if at != -1 and at < cut:
			cut = at
	return raw.substr(0, cut).strip_edges()


## The arguments object out of one Ollama tool_call. Ollama returns arguments already parsed, but a JSON string is tolerated too; anything else yields {}.
## When a leaked GLM template left arguments empty, the <arg_key>/<arg_value> pairs are recovered from the name field instead so the repaired call still carries its inputs.
static func tool_call_args(tc: Variant) -> Dictionary:
	if not (tc is Dictionary) or not (tc.get("function") is Dictionary):
		return {}
	var fn: Dictionary = tc["function"]
	var raw: Variant = fn.get("arguments", {})
	var parsed: Dictionary = {}
	if raw is Dictionary:
		parsed = raw
	elif raw is String:
		var decoded: Variant = JSON.parse_string(raw)
		if decoded is Dictionary:
			parsed = decoded
	if not parsed.is_empty():
		return parsed
	return _args_from_markup(String(fn.get("name", "")))


## Recover {key: value} pairs from a GLM tool-call template that leaked into the name field, where each argument reads "<arg_key>k</arg_key><arg_value>v</arg_value>" (Ollama's partial parse sometimes eats the first "<"). {} when no pairs are present.
static func _args_from_markup(name: String) -> Dictionary:
	var keys := _extract_between(name, "arg_key>", "</arg_key>")
	var values := _extract_between(name, "arg_value>", "</arg_value>")
	var out: Dictionary = {}
	for i in mini(keys.size(), values.size()):
		out[keys[i]] = _decode_arg_value(values[i])
	return out


## One recovered argument value as its intended type: the GLM template writes string arguments as raw text and everything else (numbers, bools, null, arrays, objects) as a JSON literal, so decode only when the value has a literal's shape — this keeps a bare word like a class name from tripping the JSON parser's error log.
static func _decode_arg_value(value: String) -> Variant:
	var trimmed := value.strip_edges()
	var looks_json := trimmed in ["true", "false", "null"] or trimmed.is_valid_float() \
		or trimmed.begins_with("{") or trimmed.begins_with("[") or trimmed.begins_with("\"")
	if looks_json:
		var decoded: Variant = JSON.parse_string(trimmed)
		if decoded != null or trimmed == "null":
			return decoded
	return value


## Every substring of `text` bracketed by an `open`…`close` pair, in order. Resumes past each close before seeking the next open, so a close that itself contains `open` as a substring (e.g. "</arg_key>") is never mistaken for a fresh opener.
static func _extract_between(text: String, open: String, close: String) -> Array:
	var out: Array = []
	var from := 0
	while true:
		var start := text.find(open, from)
		if start == -1:
			break
		start += open.length()
		var stop := text.find(close, start)
		if stop == -1:
			break
		out.append(text.substr(start, stop - start))
		from = stop + close.length()
	return out


## Reduce tool calls to the minimal {"function": {name, arguments}} shape Ollama accepts on a resend. The provider adds `index`/`id` fields Godot's JSON reads back as floats, which Ollama's integer `index` then rejects (HTTP 400); rebuilding from name + arguments sidesteps that. Shared so the session and subagents echo their tool calls back identically.
static func sanitize_tool_calls(tool_calls: Array) -> Array:
	var out: Array = []
	for tc in tool_calls:
		var name := tool_call_name(tc)
		if name != "":
			out.append({"function": {"name": name, "arguments": tool_call_args(tc)}})
	return out


## The value for a tool's logical parameter, tried against each name in `keys` in order so a model's natural synonym (e.g. "directory" for "path") still resolves; "" if no listed key holds a non-empty value.
static func _arg_string(args: Dictionary, keys: Array) -> String:
	for key in keys:
		if args.has(key):
			var value := String(args[key]).strip_edges()
			if value != "":
				return value
	return ""


## The class argument for the describe_* tools, tolerant of a schema-blind call: when none of `class_keys` is present the search-style QUERY_KEYS are tried too, since session logs show a model that skips tool_search overwhelmingly reaches for "query". A value carrying the intended call as a JSON string ("{\"class\": \"Panel\"}") or a spelled-out key prefix ("class: Panel") is unwrapped.
static func _class_arg(args: Dictionary, class_keys: Array) -> String:
	var value := _arg_string(args, class_keys)
	if value == "":
		value = _arg_string(args, QUERY_KEYS)
	if value.begins_with("{"):
		var decoded: Variant = JSON.parse_string(value)
		if decoded is Dictionary:
			return _class_arg(decoded, class_keys)
	for key in class_keys:
		if value.to_lower().begins_with(String(key) + ":"):
			return value.substr(String(key).length() + 1).strip_edges()
	return value


## A boolean flag argument, read from the first of `keys` present in `args`. Accepts a real bool, a model's stringified form ("true"/"1"/"yes"), or a number, since a tool call's arguments aren't always typed the way the schema asks; anything unrecognized, or no key present, reads as false.
static func _arg_bool(args: Dictionary, keys: Array) -> bool:
	for key in keys:
		if args.has(key):
			var value: Variant = args[key]
			if value is bool:
				return value
			if value is String:
				return String(value).strip_edges().to_lower() in ["true", "1", "yes", "y"]
			if value is int or value is float:
				return float(value) != 0.0
	return false


## An integer argument, read from the first of `keys` present in `args`; accepts a real number or a model's numeric string, else `fallback`.
static func _arg_int(args: Dictionary, keys: Array, fallback: int) -> int:
	for key in keys:
		if args.has(key):
			var value: Variant = args[key]
			if value is int or value is float:
				return int(value)
			if value is String and String(value).strip_edges().is_valid_int():
				return int(String(value).strip_edges())
	return fallback


## A string-array argument, read from the first of `keys` present in `args`: a real array's elements stringified, or a lone string as a one-element array — a schema-blind model passes both shapes; [] when absent.
static func _arg_string_array(args: Dictionary, keys: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for key in keys:
		if not args.has(key):
			continue
		var value: Variant = args[key]
		if value is Array:
			for item in value:
				out.append(String(item))
		elif String(value).strip_edges() != "":
			out.append(String(value).strip_edges())
		return out
	return out


## An error message when the model supplied arguments but none under a recognized key from `keys`, else "". Lets a tool report a misnamed argument instead of silently ignoring it — a filter the model believes took effect but never ran is worse than an error; `usage` states the expected shape so the retry can be correct.
static func _unexpected_arg_error(args: Dictionary, keys: Array, usage: String) -> String:
	if args.is_empty():
		return ""
	for key in keys:
		if args.has(key):
			return ""
	var got := PackedStringArray()
	for key in args.keys():
		got.append("\"%s\"" % key)
	# fill() resolves any {tunable:...} tokens the usage line quotes its defaults with, so the retry is told the numbers actually in force.
	return "Error: unrecognized argument(s) %s. %s" % [", ".join(got), GDLLMTunables.fill(usage)]


## Read the file named by `args.path` and return an execute()-shaped result: normally "<resolved path>:\n\n<contents>", but a file past GDLLMTunables.READ_FILE_SUMMARY_THRESHOLD characters defers to a `subagent` map instead (see _summarize_via_subagent) and a loadable .tscn returns its saved node tree (see _scene_read_map) — both overridden by `args.full` (whole file regardless) or a `start_line`/`end_line` range (exactly those lines verbatim, see _render_line_range). Long packed-array payloads are elided in every DEFAULT path — before the threshold is measured, so the gate judges the size that would actually be delivered (see _elide_packed_arrays) — while `full` returns them verbatim and sticky-disarms the overwrite gate (see SessionLedger.elided_files). Errors return as plain content the model can recover from; binary files are refused so a garbled blob never lands in the conversation. A path that only resolved by file-name search is disclosed loudly up front (see _resolution_note).
static func _read_file(args: Dictionary, ledger: SessionLedger) -> Dictionary:
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return _plain("Error: no path was provided. Pass the file in \"path\", e.g. {\"path\": \"res://player.gd\"}.")
	var force_full := _arg_bool(args, FULL_READ_KEYS) # model asked for the whole file even if long, so skip the summary map
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _plain(_file_not_found(requested))
	await _await_path_stable(resolved)
	if _looks_binary(resolved):
		# An imported asset is binary almost by definition, and the uid is what a read of one is for — so the refusal answers instead of dead-ending (see GDLLMImport.binary_uid_hint).
		return _plain("Error: %s looks like a binary file, not text, so it wasn't read.%s" % [resolved, GDLLMImport.binary_uid_hint(resolved)])
	# Measured across the wild transcripts: 131 of 131 reads of a .import were followed by the model using the asset's uid — one line out of a ~1,040-character file, and the whole file stayed in history forever. The map leads with that line; "full": true still gives the raw text.
	if GDLLMImport.is_import_file(resolved) and not force_full and _arg_int(args, RANGE_START_KEYS, 0) <= 0 and _arg_int(args, RANGE_END_KEYS, 0) <= 0:
		_mark_seen(resolved, false, ledger) # the map shows what the file records, not its exact text
		var info := GDLLMImport.read_import(resolved)
		return _plain(_resolution_note(requested, resolved) + GDLLMImport.map_report(resolved, info, GDLLMImport.valid_state(str(info["asset"]))))
	# Measured across the wild transcripts: a read of a .tscn cost 5.4× its describe_scene_file view, was chosen 2.5× as often, and 55% of scene reads never fed an edit — structure questions paying the full serialized price. The tree leads; "full": true still gives the raw text.
	if resolved.get_extension().to_lower() == "tscn" and not force_full and _arg_int(args, RANGE_START_KEYS, 0) <= 0 and _arg_int(args, RANGE_END_KEYS, 0) <= 0:
		var scene_map := _scene_read_map(resolved)
		if scene_map != "":
			_mark_seen(resolved, false, ledger) # the tree shows the scene's structure, not its exact text — a later edit still needs the real text
			return _plain(_scene_divergence_note(resolved) + _resolution_note(requested, resolved) + scene_map)
		# A .tscn the engine cannot load as a scene falls through to the raw text — the broken file's text is exactly what fixing it needs.
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		return _plain(_file_open_error(resolved))
	# The divergence warning rides the same prefix as the resolution note, so all three read shapes (range, map, full) carry it.
	var note := _scene_divergence_note(resolved) + _resolution_note(requested, resolved)
	var raw := file.get_as_text()
	var text := _elide_packed_arrays(raw)
	var elided := text != raw
	# `full` outranks elision: the explicit whole-file escalation returns every byte, payloads included — the one route to blob data, and what re-grounds a wholesale rewrite the overwrite gate refused (see _write_overwrite_seen_guard).
	if force_full:
		text = raw
	var line_count := _count_lines(text)
	var start_line := _arg_int(args, RANGE_START_KEYS, 0)
	var end_line := _arg_int(args, RANGE_END_KEYS, 0)
	if (start_line > 0 or end_line > 0) and line_count > 0:
		_mark_seen(resolved, true, ledger) # the range is the file's exact text, so edits inside it are grounded
		# A slice never shows the payloads outside it, so a data-carrying file stamps here even when the slice itself came back verbatim under `full`.
		if elided:
			_stamp_elided_path(resolved, ledger)
		var ranged := _render_line_range(resolved, text, line_count, start_line, end_line)
		return _plain(note + ranged + _elision_note(ranged))
	if not force_full and GDLLMTunables.geti(GDLLMTunables.READ_FILE_SUMMARY_THRESHOLD) > 0 and text.length() > GDLLMTunables.geti(GDLLMTunables.READ_FILE_SUMMARY_THRESHOLD):
		_mark_seen(resolved, false, ledger) # the map shows the file's shape, not its exact text
		if elided:
			_stamp_elided_path(resolved, ledger)
		var deferred := _summarize_via_subagent(resolved, text, line_count)
		if note != "":
			deferred["subagent"]["result_preamble"] = note + String(deferred["subagent"]["result_preamble"])
		return deferred
	_mark_seen(resolved, true, ledger)
	if force_full:
		# The model now holds every byte of the file, payloads included, so the overwrite gate stands down — STICKY false rather than an erase, because a later elided VIEW of the same content (a search excerpt, a plain re-read) doesn't reduce what the model holds and must not re-arm the gate (wild-measured: a post-full-read search re-stamped the file and the model force-overwrote through a refusal it correctly judged false). A blob-free file just clears any stale record.
		if elided:
			ledger.elided_files[resolved] = false
		else:
			ledger.elided_files.erase(resolved)
	elif elided:
		_stamp_elided_path(resolved, ledger)
	# A full read of a .import puts its bare numbers on screen; the legend is what keeps them from being interpreted from memory (see GDLLMImport.legend_block).
	var import_legend := ""
	if GDLLMImport.is_import_file(resolved):
		var import_info := GDLLMImport.read_import(resolved)
		var importer := str(import_info["importer"])
		import_legend = GDLLMImport.legend_block(import_info, ledger.legended_importers.has(importer))
		if import_legend != "":
			ledger.legended_importers[importer] = true
	return _plain("%s%s:\n\n%s%s%s" % [note, resolved, text, import_legend, _elision_note(text)])


## An execute() result carrying a finished `content` string with nothing to activate and no subagent follow-up — the shape every non-search tool returns for a directly-computed answer or an error.
static func _plain(content: String) -> Dictionary:
	return {"content": content, "activate": PackedStringArray()}


## The one-line lever appended to any result whose shown text carries elision markers: name what was withheld and the argument that returns it, so a marker is never a dead end (goal 3). Empty when nothing shown was elided — a clean read costs the context nothing. Counted by the marker's exact shape, never a substring, so a user's file that merely TALKS about elision is not miscounted (see _elision_marker_regex).
static func _elision_note(shown: String) -> String:
	var count := _elision_marker_regex().search_all(shown).size()
	if count == 0:
		return ""
	return "\n\n(%d packed-array payload(s) elided to \"<... elided>\" markers — data, not readable text. If you genuinely need them verbatim, e.g. to rebuild the whole file, call read_file with full:true, which returns every byte.)" % count


## The exact shape _elide_packed_payloads writes — "<N bytes elided>" / "<N elements elided>" — as a pattern, built fresh per call like the linkifier's small regexes. Shared by the note's count and edit_file's marker advisory, so both fire only on text a read actually produced, never on a file that happens to contain the words.
static func _elision_marker_regex() -> RegEx:
	return RegEx.create_from_string("<\\d+ (?:bytes|elements) elided>")


## The start_line/end_line slice of `text`, numbered like read_function output — the narrow escape hatch a long file's map points at, always returned verbatim even when the whole file would be mapped. Bounds are clamped to the file instead of erroring, so an off-by-a-few guess still shows the region.
static func _render_line_range(resolved: String, text: String, line_count: int, start_line: int, end_line: int) -> String:
	var lines := text.split("\n")
	var first := clampi(start_line if start_line > 0 else 1, 1, line_count)
	var last := clampi(end_line if end_line > 0 else line_count, first, line_count)
	var body: Array = ["%s (lines %d-%d of %d):" % [resolved, first, last, line_count]]
	for i in range(first - 1, last):
		body.append("%4d: %s" % [i + 1, lines[i]])
	return "\n".join(body)


## The compact view read_file returns for a loadable .tscn instead of its raw serialized text — the same saved-tree view describe_scene_file composes, behind a preamble naming the ways back to the real text. Returns "" when the file does not load as a scene or holds no nodes, so the caller falls through to the raw read: a broken .tscn is the one case where the serialized text IS the answer.
static func _scene_read_map(resolved: String) -> String:
	# Loading a PackedScene pulls in its ext-resources but instantiates nothing, so no _init/_ready/@tool code runs; CACHE_MODE_IGNORE keeps it out of the resource cache (see _describe_scene_file).
	var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not packed is PackedScene:
		return ""
	var state := (packed as PackedScene).get_state()
	if state.get_node_count() == 0:
		return ""
	var line_count := _count_lines(FileAccess.get_file_as_string(resolved))
	var preamble := "Read as a scene: the saved node tree follows instead of the raw serialized text (%d lines). Pass node_path to describe_scene_file to zoom into one node's saved properties, connections, and groups; call read_file again with \"full\" set to true when you truly need the serialized text — an edit_file of this file requires that, the tree does not count as having seen it.\n\n" % line_count
	return preamble + _scene_state_tree(state, resolved, 0)


## The result the read_file call standing in for a user attachment would have returned, formatted exactly as _read_file formats it — a whole-file read, or a numbered line range when start_line/end_line name the user's selection — and recorded in the ledger the same way a real read would, so an attached file grounds a later edit_file instead of being refused as never-shown (see _mark_seen). `text` is the editor's live buffer, not disk, which is why `unsaved` prefixes the divergence: without it the model would take a re-read as reproducing this, and silently get different content.
static func format_attachment_read(resolved: String, text: String, start_line: int, end_line: int, unsaved: bool, ledger: SessionLedger) -> String:
	_mark_seen(resolved, true, ledger)
	var note := "(Attached from the unsaved editor buffer — the file on disk still differs, so re-reading this path will not match until it is saved.)\n" if unsaved else ""
	if start_line > 0 or end_line > 0:
		return note + _render_line_range(resolved, text, _count_lines(text), start_line, end_line)
	return "%s%s:\n\n%s" % [note, resolved, text]


## The result the describe_scene call standing in for an attached scene-tree selection would have returned — produced by CALLING that tool's own composer, so the attachment and a later re-run can never render differently.
## Deliberately no _mark_seen: describe_scene's view is explicitly not valid ground for editing serialized text (edit_file says so outright), so an attached node must not unlock an edit the model has not actually read the file for.
## `ordinal`/`total` prepend WHO chose this node, which the body alone cannot say: an attachment turn is indistinguishable from the model having made the call itself, so asked "what node do I have selected" it read its own synthetic call as a guess it had made and denied being able to see the selection at all — twice in four wild sessions, while reciting the node's real properties in the same breath.
## The note carries the count because the question is often plural, and a model that can see "1 of 3" can answer it without inferring anything.
## read_file attachments deliberately get no such line (0 of 6 wild sessions misread one): their body already names the file, so the provenance is not the answer there, and a line that fires on every attachment is context paid for on every later request.
## `selected_total` above `total` means the selection outran the attach cap, which is stated rather than dropped quietly — otherwise a model asked "what nodes do I have selected" would confidently answer with a count that is simply wrong.
static func format_attachment_scene(args: Dictionary, ordinal: int = 0, total: int = 0, selected_total: int = 0) -> String:
	var body := _describe_scene(args)
	if ordinal <= 0 or total <= 0:
		return body
	var selected := maxi(selected_total, total)
	var note := ""
	if selected > total:
		note = "node %d of the %d attached here — they have %d selected in the editor's Scene dock, and the remaining %d were left off to keep this message small" % [ordinal, total, selected, selected - total]
	elif total == 1:
		note = "the one node they currently have selected in the editor's Scene dock"
	else:
		note = "node %d of the %d nodes they currently have selected in the editor's Scene dock" % [ordinal, total]
	return "(Attached by the user, not fetched by you: %s.)\n%s" % [note, body]


## Record in the session's ledger that the model was shown `res_path`: `verbatim` true for real file text, false for a shape-only view (read_file's long-file map, a search overview). A verbatim mark is never downgraded by a later shape-only view.
static func _mark_seen(res_path: String, verbatim: bool, ledger: SessionLedger) -> void:
	ledger.seen_files[res_path] = verbatim or bool(ledger.seen_files.get(res_path, false))


## Line count of `text` (newline count + 1, so a file without a trailing newline still counts its last line); 0 for empty text. Approximate by design — it only labels read output (range headers, map and scene preambles); the summary gate itself is in characters.
static func _count_lines(text: String) -> int:
	return 0 if text == "" else text.count("\n") + 1


## Replace each ELIDABLE_PACKED_ARRAYS payload in `text` longer than GDLLMTunables.PACKED_ARRAY_ELIDE_CHARS with a count marker, keeping the wrapper so the property still reads as that array type. Only payloads made purely of serialized-data characters are touched, so a code expression that constructs one is never mangled.
static func _elide_packed_arrays(text: String) -> String:
	if GDLLMTunables.geti(GDLLMTunables.PACKED_ARRAY_ELIDE_CHARS) <= 0:
		return text
	for type_name: String in ELIDABLE_PACKED_ARRAYS:
		if text.contains(type_name + "("):
			text = _elide_packed_payloads(text, type_name, ELIDABLE_PACKED_ARRAYS[type_name])
	return text


## One elision pass for one packed-array type: each qualifying `TypeName(...)` payload becomes "<N bytes elided>" (byte arrays, which serialize as base64 in Godot 4.3+ or comma-separated ints) or "<N elements elided>" (numeric arrays, whose element count is the printed numbers divided by `scalars_per_element`).
static func _elide_packed_payloads(text: String, type_name: String, scalars_per_element: int) -> String:
	var opener := type_name + "("
	var is_bytes := type_name == "PackedByteArray"
	var out := ""
	var pos := 0
	while true:
		var start := text.find(opener, pos)
		if start == -1:
			break
		var payload_start := start + opener.length()
		var close := text.find(")", payload_start)
		if close == -1:
			break
		var payload := text.substr(payload_start, close - payload_start)
		var is_data := _is_packed_byte_payload(payload) if is_bytes else _is_packed_numeric_payload(payload)
		if payload.length() > GDLLMTunables.geti(GDLLMTunables.PACKED_ARRAY_ELIDE_CHARS) and is_data:
			out += text.substr(pos, payload_start - pos)
			if is_bytes:
				out += "<%d bytes elided>" % _packed_byte_payload_size(payload)
			else:
				out += "<%d elements elided>" % ((payload.count(",") + 1) / scalars_per_element)
			pos = close
		else:
			out += text.substr(pos, payload_start - pos)
			pos = payload_start
	return out + text.substr(pos)


## Whether `payload` looks like serialized PackedByteArray data — base64 (with its quotes) or comma-separated ints — as opposed to a code expression, which may contain parentheses the scan above would cut short.
static func _is_packed_byte_payload(payload: String) -> bool:
	const EXTRAS: PackedInt32Array = [43, 47, 61, 34, 44, 32, 9, 10, 13] # + / = " , and whitespace
	for i in payload.length():
		var c := payload.unicode_at(i)
		var is_alnum := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		if not is_alnum and not EXTRAS.has(c):
			return false
	return true


## Whether `payload` is serialized numeric packed-array data: every comma-separated token must be a number or the inf/inf_neg/nan Godot prints for degenerate floats, so identifiers in a code expression fail it.
static func _is_packed_numeric_payload(payload: String) -> bool:
	for token in payload.split(","):
		var t := token.strip_edges()
		if not (t.is_valid_float() or t == "inf" or t == "inf_neg" or t == "nan"):
			return false
	return true


## Decoded byte count of a serialized PackedByteArray payload: base64 length arithmetic for the quoted form, element count for the comma-separated form.
static func _packed_byte_payload_size(payload: String) -> int:
	var trimmed := payload.strip_edges()
	if trimmed.begins_with("\""):
		var b64 := trimmed.trim_prefix("\"").trim_suffix("\"")
		var padding := b64.length() - b64.rstrip("=").length()
		return maxi(b64.length() / 4 * 3 - padding, 0)
	return payload.count(",") + 1


## An execute() result that defers a too-long file to a fresh-context subagent: no direct content, but a `subagent` spec the session runs — a model that reads `text` and returns an overview plus every function's signature, handed back as this tool's result behind `result_preamble` so the main agent knows it got a map (not the file) and can search_files for specific code afterward. `tasks_model` routes the run to the settings' Tasks Model: mapping a file is a fixed background transform, not a delegation, so it needn't tie up (or cost) the chat model.
static func _summarize_via_subagent(resolved: String, text: String, line_count: int) -> Dictionary:
	var preamble := "%s is %d lines and %d KB of text, so it was mapped by a subagent rather than read in full. An overview and its function list follow; use read_function to pull the actual code of a specific function when you need it, or call read_file again with full set to true if you truly need the entire file." % [resolved, line_count, maxi(1, text.length() / 1024)]
	var span := _top_level_span(text)
	if span > 0:
		preamble += " Its top-level code (class_name, extends, signals, consts, member variables) spans lines 1–%d; read exactly that region with start_line/end_line when you need those declarations verbatim." % span
	preamble += " This map is not the file's text, but a search_files excerpt, a read_function result, or a start_line/end_line read of the region you want to edit each counts as having seen it — edit_file only refuses when none of those has shown you the real text.\n\n"
	return {
		"content": "",
		"activate": PackedStringArray(),
		"subagent": {
			"system": READ_FILE_SUMMARY_SYSTEM_PROMPT,
			"prompt": "File: %s (%d lines)\n\n%s" % [resolved, line_count, text],
			"label": "Summarizing %s (%d lines)" % [resolved.get_file(), line_count],
			"result_preamble": preamble,
			"tasks_model": true,
			# The session skips the whole re-map when it has already delivered this exact content's map (see the cached-map branch in _on_tool_calls_received), serving cached_note instead — transcripts show unchanged long files re-mapped for ~10k chars a time.
			"map_key": resolved + "|" + text.md5_text(),
			"cached_note": "%s is %d lines long and UNCHANGED since your last read this session — the map you already received is still accurate; re-read it there. Use read_function to pull a specific function's code, or read_file with full set to true if you truly need the entire text." % [resolved, line_count],
		},
	}


## Line count of the header region before the first column-0 func — where a script's class_name, signals, consts, and member variables live — or -1 when the text has no top-level functions (a scene or data file, where the sentence would be noise). The map preamble names this span because transcripts show models dumping whole files with full=true just to see those declarations.
static func _top_level_span(text: String) -> int:
	var lines := text.split("\n")
	for i in lines.size():
		if lines[i].begins_with("func ") or lines[i].begins_with("static func "):
			return i
	return -1


## Build an execute() result that hands the model's own delegated task to a fresh-context subagent — the second producer of the `subagent` field the session runs (see _summarize_via_subagent for the first). Unlike that pure transform, this one sets `tools`, so the subagent runs its own tool loop and can read and search the project to do the task; it sees only `task` and the optional `context` the model passed, never the conversation. Its reply comes back behind result_preamble as this tool's result, keeping the subagent's own working context out of the main thread.
static func _run_subagent_tool(args: Dictionary) -> Dictionary:
	var task := _arg_string(args, TASK_KEYS)
	if task == "":
		return _plain("Error: no task was given. Put the work for the subagent in \"task\", and any specific material it needs in \"context\".")
	var context := _arg_string(args, CONTEXT_KEYS)
	var prompt := task if context == "" else "%s\n\n--- Context ---\n%s" % [task, context]
	# The subagent reaches use_skill through the shared registry, so the roster that names the skills rides its prompt too — same narrow shape as the main chat's.
	var system := RUN_SUBAGENT_SYSTEM_PROMPT
	var roster := GDLLMInstructions.skills_block(GDLLMInstructions.discover_skills())
	if roster != "":
		system += "\n\n" + roster
	return {
		"content": "",
		"activate": PackedStringArray(),
		"subagent": {
			"system": system,
			"prompt": prompt,
			"label": "Subagent: %s" % _subagent_task_label(task),
			"result_preamble": "A fresh-context subagent completed the delegated task and returned the following. It kept no memory of the conversation, so treat this as its whole answer and use it directly.\n\n",
			"tools": true,
		},
	}


## Serve one skill's full body — the on-demand half of the skills roster the system prompt lists (names and descriptions there, bodies here, so a skill costs the context nothing until a task needs one). The body always returns whole: a skill is instructions to follow, and a partial instruction set silently followed is worse than a long result. An unknown name lists the real ones and a missing library names where to create it, so no call dead-ends (goal 3).
static func _use_skill(args: Dictionary, ledger: SessionLedger) -> String:
	var unexpected := _unexpected_arg_error(args, SKILL_NAME_KEYS, USE_SKILL_USAGE)
	if unexpected != "":
		return unexpected
	var name := _arg_string(args, SKILL_NAME_KEYS)
	if name == "":
		return "Error: no skill was named, so nothing was read. " + USE_SKILL_USAGE
	var skills: Array = GDLLMInstructions.discover_skills()
	if skills.is_empty():
		if DirAccess.dir_exists_absolute(GDLLMInstructions.SKILLS_DIR):
			return "Error: nothing was read — %s exists but defines no skills. A skill is a Markdown file at %s/<name>.md or %s/<name>/SKILL.md (top level only); none is there now, so do not tell the user a skill ran." % [GDLLMInstructions.SKILLS_DIR, GDLLMInstructions.SKILLS_DIR, GDLLMInstructions.SKILLS_DIR]
		return "Error: nothing was read — this project has no %s directory, so no skills are defined. A skill is a Markdown file at %s/<name>.md or %s/<name>/SKILL.md; ask the user before creating one." % [GDLLMInstructions.SKILLS_DIR, GDLLMInstructions.SKILLS_DIR, GDLLMInstructions.SKILLS_DIR]
	var skill := GDLLMInstructions.find_skill(name, skills)
	if skill.is_empty():
		var names := PackedStringArray()
		for entry: Dictionary in skills:
			names.append(String(entry["name"]))
		return "Error: no skill is named \"%s\", so nothing was read. This project's skills: %s. Call use_skill again with one of those names exactly." % [name, ", ".join(names)]
	var path := String(skill["path"])
	await _await_path_stable(path)
	var raw := String(skill["body"])
	var body := _elide_packed_arrays(raw)
	# The served body EXCLUDES the frontmatter and edge whitespace, so it marks the file seen but never whole-verbatim: a wholesale rewrite grounded on it would silently drop the frontmatter, and the read-gate's refusal routes an edit through a real read first. An elided payload still arms the overwrite gate — the payloads exist regardless of which view showed them.
	_mark_seen(path, false, ledger)
	if body != raw:
		_stamp_elided_path(path, ledger)
	if raw == "":
		return "Skill \"%s\" (%s) has no body text — the file holds nothing past its frontmatter, so there are no instructions to follow." % [String(skill["name"]), path]
	return "Skill \"%s\" (%s):\n\n%s%s" % [String(skill["name"]), path, body, _elision_note(body)]


## A short, single-line label for a delegated subagent task, for its progress caption: the task's first non-empty line, truncated past SUBAGENT_LABEL_MAX_CHARS so a long instruction doesn't sprawl across the caption. `task` is assumed non-empty (the caller validates it).
static func _subagent_task_label(task: String) -> String:
	var line := task.strip_edges().split("\n", false)[0]
	if line.length() <= SUBAGENT_LABEL_MAX_CHARS:
		return line
	return line.substr(0, SUBAGENT_LABEL_MAX_CHARS - 1).strip_edges() + "…"


## Print the immediate contents of the directory named by `args.path` (or the project root when omitted): subdirectories (trailing "/") first, then files, with editor save-temps folded into a count line rather than listed (see _is_editor_temp) or hidden outright. A listing past GDLLMTunables.LIST_DIRECTORY_MAX_ROWS truncates with a counted line naming `full` unless `full` waives the cap; hidden directories are refused outright (see _hidden_dir_guard). An error line if the directory can't be found.
static func _list_directory(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, DIR_PATH_KEYS + LIST_SIDECAR_KEYS + LIST_FULL_KEYS, "Pass the directory in \"path\", or omit it to list the project root.")
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, DIR_PATH_KEYS)
	var dir_path := "res://" if requested == "" else _resolve_dir_path(requested)
	if dir_path == "":
		# Reached with 0 or 2+ name matches (a unique bare name resolved above), or a pathed guess whose leaf exists elsewhere — name the candidates rather than letting "no directory found" read as "does not exist anywhere".
		var twins := _find_dirs_by_name("res://", requested.trim_prefix("res://").trim_suffix("/").get_file())
		if twins.size() > 1:
			return "Error: %d directories in the project are named \"%s\": %s. Pass the full res:// path of the one you mean." % [twins.size(), requested.trim_suffix("/").get_file(), ", ".join(twins)]
		if twins.size() == 1:
			return "Error: no directory found matching \"%s\" — did you mean %s?" % [requested, twins[0]]
		return "Error: no directory found matching \"%s\" in the project." % requested
	var guard := _hidden_dir_guard(dir_path)
	if guard != "":
		return guard
	var dirs: Array[String] = []
	var files: Array[String] = []
	_list_dir(dir_path, dirs, files)
	dirs.sort()
	files.sort()
	var lines: Array = ["%s:" % dir_path]
	var rows: Array[String] = []
	for d in dirs:
		rows.append("  %s/" % d)
	var omitted := 0
	var listable: Array[String] = []
	for f in files:
		if _is_editor_temp(f):
			omitted += 1
		else:
			listable.append(f)
	# Measured across the wild transcripts: .import and .uid sidecars were 33.6% of everything this tool ever returned — a third of its whole lifetime output spent on files that only restate the name of the file above them.
	var folded: Array[String] = []
	if not _arg_bool(args, LIST_SIDECAR_KEYS):
		var split := GDLLMImport.partition_listing(listable)
		# The disclosure line is a fixed cost, so a directory with one or two sidecars is cheaper listed in full than folded — measured on a real project's root, where folding one .import grew the listing by half (see fold_saves).
		if GDLLMImport.fold_saves(split["folded"]):
			listable = split["shown"]
			folded = split["folded"]
	for f in listable:
		rows.append("  %s" % f)
	var over := rows.size() - GDLLMTunables.geti(GDLLMTunables.LIST_DIRECTORY_MAX_ROWS)
	# The cap counts what would actually print — after temp omission and sidecar folding — and truncating a single overflow row would spend the disclosure line to hide one name (the fold_saves rule), so it takes at least two.
	if over > 1 and not _arg_bool(args, LIST_FULL_KEYS):
		lines.append_array(rows.slice(0, GDLLMTunables.geti(GDLLMTunables.LIST_DIRECTORY_MAX_ROWS)))
		# The final entry is named so the hidden tail has a visible end — wild-caught: models extrapolated the cut-off pattern past the real files, and a differently-named last file was reported nonexistent. The contents-not-names clause is wild-caught too: this line's earlier "to find specific files" sent a file-NAME question into a content search whose empty result read as proof of absence.
		lines.append("  (…%d more of %d entries not shown, ending at %s — pass full: true for the whole listing, or search_files with this directory as \"path\" to search inside the files. Search matches file CONTENTS, never names: to confirm a file name exists or is absent, use full: true.)" % [over, rows.size(), rows[rows.size() - 1].strip_edges()])
	else:
		lines.append_array(rows)
	if dirs.is_empty() and files.is_empty():
		lines.append("  (empty)")
	if omitted > 0:
		lines.append("  (%d editor save-temp file(s) omitted)" % omitted)
	var folded_note := GDLLMImport.folded_note(folded)
	if folded_note != "":
		lines.append(folded_note)
	return "\n".join(lines)


## Search the project's text files (or the file/directory named by `args.path`) for `args.query` — a literal, case-insensitive substring — the narrow-context alternative to reading whole files. The whole scope is scanned first for true totals; a result that fits comes back as labelled excerpts, while a broad query that would flood the context falls back to a per-file overview the model can narrow from (see _render_search_overview). `full: true` waives that fallback and the excerpt-block cap — an explicit ask for everything gets everything, the same contract as list_directory's cap waiver.
static func _search_files(args: Dictionary, ledger: SessionLedger) -> String:
	var unexpected := _unexpected_arg_error(args, QUERY_KEYS + SCOPE_PATH_KEYS + CONTEXT_LINES_KEYS + SEARCH_FULL_KEYS, SEARCH_USAGE)
	if unexpected != "":
		return unexpected
	var query := _arg_string(args, QUERY_KEYS)
	if query == "":
		return "Error: no search query was provided. " + SEARCH_USAGE
	var full := _arg_bool(args, SEARCH_FULL_KEYS)
	# No ceiling: an explicit context ask is the model pulling detail in on demand, and refusing it strands the model mid-task (measured); only the sign is normalized.
	var context_lines := maxi(0, _arg_int(args, CONTEXT_LINES_KEYS, GDLLMTunables.geti(GDLLMTunables.SEARCH_CONTEXT_LINES)))
	var scope := _arg_string(args, SCOPE_PATH_KEYS)
	var scan_root := ""
	var files: Array[String] = []
	var scope_label := "the project"
	if scope == "":
		scan_root = "res://"
	else:
		var dir_path := _resolve_dir_path(scope)
		if dir_path != "":
			var guard := _hidden_dir_guard(dir_path)
			if guard != "":
				return guard
			scan_root = dir_path
			scope_label = dir_path
		else:
			var file_path := _resolve_file_path(scope)
			if file_path == "":
				return _file_not_found(scope, "file or directory")
			files.append(file_path)
			scope_label = file_path

	var needle := query.to_lower()
	var scan: Dictionary = await run_on_worker(func() -> Dictionary: return _search_scan(scan_root, files, needle, context_lines))
	var hits: Array = scan["hits"]
	var total_matches: int = scan["total_matches"]
	var total_blocks: int = scan["total_blocks"]

	if hits.is_empty():
		return _no_matches_message(query, scope_label, int(scan["scanned"]), scan["files"])
	# An explicit scope is honored exactly — a caller who asked for res://addons wants res://addons — so only a whole-project search sets installed addons aside.
	var addon_note := ""
	if scope == "":
		var project_hits := _non_addon_hits(hits)
		# Addon hits stand when they are ALL there is, which is what keeps a session working ON an addon — this plugin's own repo included — from being told its code is unsearchable.
		if not project_hits.is_empty() and project_hits.size() < hits.size():
			addon_note = _addon_scope_note(hits, project_hits)
			hits = project_hits
			var totals := _search_totals(hits)
			total_matches = int(totals["matches"])
			# Recomputed because it gates the overview fallback below: dropping addon files can let the project's own matches fit as excerpts where the combined set would only have fitted as a file list.
			total_blocks = int(totals["blocks"])
	if not full and hits.size() > 1 and (hits.size() > GDLLMTunables.geti(GDLLMTunables.SEARCH_OVERVIEW_FILES) or total_blocks > GDLLMTunables.geti(GDLLMTunables.SEARCH_MAX_BLOCKS)):
		for hit: Dictionary in hits:
			_mark_seen(String(hit["path"]), false, ledger) # an overview line names the file without showing its text
			_stamp_elided(hit, ledger)
		return _render_search_overview(query, scope_label, hits, total_matches) + addon_note
	for hit: Dictionary in hits:
		_mark_seen(String(hit["path"]), true, ledger)
		# Load-bearing for the overwrite gate: excerpts mark seen VERBATIM, so a search-first session on a blob-carrying file must arm the gate here or never.
		_stamp_elided(hit, ledger)
	return _render_search_excerpts(query, scope_label, hits, total_matches, total_blocks, full) + addon_note


## Record a scanned file's elision in the session's ledger — the scan detected it (see _elided_file_lines) but ran on a worker without the ledger, so the stamp lands here. Same whole-file rule as read_file's: the payloads exist regardless of which slice any result shows.
static func _stamp_elided(hit: Dictionary, ledger: SessionLedger) -> void:
	if bool(hit.get("elided", false)):
		_stamp_elided_path(String(hit["path"]), ledger)


## Arm the overwrite gate for a path whose current view elided payloads — unless the session already holds the whole file (the sticky false a whole-file full read or an authored write leaves): a later elided VIEW doesn't reduce what the model holds, and re-arming was a wild-measured false positive that taught the model to force through the refusal.
static func _stamp_elided_path(res_path: String, ledger: SessionLedger) -> void:
	if ledger.elided_files.get(res_path) != false:
		ledger.elided_files[res_path] = true


## The hits that are the PROJECT's own, dropping everything under res://addons/. Installed addons are a vendored-dependency boundary, not this plugin's own directory: measured on a real game, addons carry 1.9 MB of text against 1.7 MB of game code, so more than half of every unscoped search's excerpt budget was being spent on code the question was never about (transcript-measured: a search for a game enum came back quoting this addon's own test assertions).
static func _non_addon_hits(hits: Array) -> Array:
	var out: Array = []
	for hit: Dictionary in hits:
		if not String(hit["path"]).begins_with(ADDONS_ROOT):
			out.append(hit)
	return out


## The line a whole-project search appends when it set addon matches aside: they were scanned and counted, never silently dropped, and the argument that reaches them is spelled out (goal 2 — a bounded read discloses its bound, the same way read_output discloses a filter button).
static func _addon_scope_note(all_hits: Array, project_hits: Array) -> String:
	var files := all_hits.size() - project_hits.size()
	if files <= 0:
		return ""
	var shown: Dictionary = {}
	for hit: Dictionary in project_hits:
		shown[String(hit["path"])] = true
	var matches := 0
	for hit: Dictionary in all_hits:
		if not shown.has(String(hit["path"])):
			matches += (hit["matched"] as Array).size()
	# Kept terse deliberately: it rides EVERY partitioned search, and on a query whose addon hits are few it can cost more than the file lines it removed (measured: 42 files to 39 came out 51 chars larger). The count and the lever are what must survive; the reasoning belongs in the schema, which is paid for once.
	return "\n\n(%d more match(es) in %d file(s) under %s — installed addon code, not shown. Pass path \"%s\" to search it.)" % [matches, files, ADDONS_ROOT, ADDONS_ROOT]


## Match and excerpt-block totals recomputed over a subset of hits, so a header never quotes a count for files the result no longer shows.
static func _search_totals(hits: Array) -> Dictionary:
	var matches := 0
	var blocks := 0
	for hit: Dictionary in hits:
		matches += (hit["matched"] as Array).size()
		blocks += (hit["blocks"] as Array).size()
	return {"matches": matches, "blocks": blocks}


## The pure scan behind _search_files, shaped to run on a worker thread (see run_on_worker): walks `scan_root` (when not "") into `seed_files`, then reads and matches every file, touching no statics and no editor state. Returns {hits, total_matches, total_blocks, scanned, files}.
static func _search_scan(scan_root: String, seed_files: Array[String], needle: String, context_lines: int) -> Dictionary:
	var files: Array[String] = seed_files.duplicate()
	if scan_root != "":
		_collect_text_files(scan_root, files)
	var hits: Array = []
	var total_matches := 0
	var total_blocks := 0
	var scanned := 0
	for path in files:
		if _looks_binary(path):
			continue
		var read := _elided_file_lines(path)
		var lines: PackedStringArray = read["lines"]
		if lines.is_empty():
			continue
		scanned += 1
		var matched: Array[int] = []
		for i in lines.size():
			if String(lines[i]).to_lower().contains(needle):
				matched.append(i)
		if matched.is_empty():
			continue
		var hit := _scan_matches(path, lines, matched, context_lines)
		# Carried to _search_files so the ledger stamp happens where the ledger lives — this scan runs on a worker with no session state.
		hit["elided"] = bool(read["elided"])
		hits.append(hit)
		total_matches += matched.size()
		total_blocks += (hit["blocks"] as Array).size()
	return {"hits": hits, "total_matches": total_matches, "total_blocks": total_blocks, "scanned": scanned, "files": files}


## One file's matches condensed into a record for the search renderers: the excerpt blocks to show (overlapping matches collapsed into one), the matched line numbers, and the enclosing-function names an overview line lists. Holds no file text — the excerpt renderer re-reads the few files it shows.
static func _scan_matches(path: String, lines: PackedStringArray, matched: Array[int], context_lines: int) -> Dictionary:
	var is_gd := path.get_extension().to_lower() == "gd"
	var blocks: Array = []
	var emitted: Array[Vector2i] = [] # excerpt spans already claimed for this file, so overlapping matches don't repeat
	var func_names: Array[String] = []
	for idx in matched:
		if _index_within_any(idx, emitted):
			continue
		var block := _excerpt_for(lines, idx, context_lines, is_gd)
		block["trigger"] = idx
		emitted.append(block["span"])
		blocks.append(block)
		var fname := String(block["func_name"])
		if fname != "" and not func_names.has(fname):
			func_names.append(fname)
	return {"path": path, "matched": matched, "blocks": blocks, "func_names": func_names}


## Render the per-file overview a broad search falls back to: one "path: N matches (in funcs)" line per file, most matches first, with the instruction to re-run scoped — a map costing a few lines instead of a flood of excerpts, and honest about what it didn't show.
static func _render_search_overview(query: String, scope_label: String, hits: Array, total_matches: int) -> String:
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["matched"] as Array).size() > (b["matched"] as Array).size())
	var lines: Array = ["Found %d match(es) across %d files for \"%s\" in %s — too many to excerpt, so here is the per-file breakdown:" % [total_matches, hits.size(), query, scope_label], ""]
	var shown := mini(hits.size(), GDLLMTunables.geti(GDLLMTunables.SEARCH_MAX_BLOCKS))
	for i in shown:
		var hit: Dictionary = hits[i]
		var funcs := ""
		var names: Array[String] = hit["func_names"]
		if not names.is_empty():
			var listed := names.slice(0, GDLLMTunables.geti(GDLLMTunables.SEARCH_OVERVIEW_FUNCS))
			var more := ", …" if names.size() > listed.size() else ""
			funcs = " (in %s%s)" % [", ".join(listed), more]
		lines.append("%s: %d match(es)%s" % [hit["path"], (hit["matched"] as Array).size(), funcs])
	if hits.size() > shown:
		lines.append("…and %d more file(s)." % (hits.size() - shown))
	lines.append("")
	lines.append("Re-run with \"path\" set to one of these files or directories (or use a more specific query) to see the matching code, or pass full: true to get every excerpt in one result.")
	return "\n".join(lines)


## Render the excerpt result: each file's blocks up to GDLLMTunables.SEARCH_MAX_BLOCKS total (uncapped when `full`), headed by true totals; when the cap cuts blocks (one file dense with matches) the header says how many were omitted and names both ways through — narrowing and the full: true waiver — rather than passing the cap off as the whole count.
static func _render_search_excerpts(query: String, scope_label: String, hits: Array, total_matches: int, total_blocks: int, full := false) -> String:
	var rendered: Array = []
	for h in hits:
		if not full and rendered.size() >= GDLLMTunables.geti(GDLLMTunables.SEARCH_MAX_BLOCKS):
			break
		var hit: Dictionary = h
		var path := String(hit["path"])
		var lines := _file_lines(path)
		if lines.is_empty():
			continue
		var matched: Array[int] = hit["matched"]
		for block in hit["blocks"]:
			if not full and rendered.size() >= GDLLMTunables.geti(GDLLMTunables.SEARCH_MAX_BLOCKS):
				break
			rendered.append(_render_block(path, lines, block, matched))
	var note := ""
	if total_blocks > rendered.size():
		note = " — showing the first %d of %d excerpts; use a more specific query to narrow, or full: true for every excerpt" % [rendered.size(), total_blocks]
	var header := "Found %d match(es) in %d file(s) for \"%s\" in %s%s:" % [total_matches, hits.size(), query, scope_label, note]
	var body := header + "\n\n" + "\n\n".join(rendered)
	return body + _elision_note(body)


## The empty-result message, built to be refinable rather than a dead end: scan stats so wrong-scope and wrong-spelling look different, a literal-matching reminder when the query reads like a regex or glob, and file-name suggestions when the query is a file name that content search can never hit.
static func _no_matches_message(query: String, scope_label: String, scanned: int, files: Array) -> String:
	var msg := "No matches found for \"%s\" in %s (%d text files searched)." % [query, scope_label, scanned]
	if _looks_like_pattern(query):
		msg += " Matching is literal, case-insensitive substring — regex and glob syntax are not supported, so try a plain text fragment instead."
	var named := _files_named_like(files, query)
	if not named.is_empty():
		msg += "\nFile contents didn't match, but these file names do: %s. Use read_file to open one." % ", ".join(named)
	return msg


## Whether a query reads like a regex or glob rather than literal text — the cue to remind the model that matching is literal substring only.
static func _looks_like_pattern(query: String) -> bool:
	if query.contains("\\") or query.contains("|") or query.contains("*"):
		return true
	return query.begins_with("^") or query.ends_with("$")


## Files from the searched set whose NAME matches a file-shaped query ("llm_client.gd", "*.gd", "\\.gd$"), so a model using content search as a file finder is pointed at the files instead of dead-ending — file names never appear in file contents. Empty when the query doesn't look like a file name.
static func _files_named_like(files: Array, query: String) -> Array[String]:
	var needle := query.get_file().strip_edges().to_lower()
	var ext := ""
	if needle.begins_with("*."):
		ext = needle.substr(2)
	elif needle.begins_with("\\.") and needle.ends_with("$"):
		ext = needle.substr(2, needle.length() - 3)
	elif needle.get_extension() == "" or needle.get_extension().length() > 4 or not needle.get_extension().is_valid_identifier():
		return []
	var out: Array[String] = []
	for path in files:
		var fname := String(path).get_file().to_lower()
		var matches := fname.get_extension() == ext if ext != "" else fname.contains(needle)
		if matches:
			out.append(String(path))
			if out.size() >= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP):
				break
	return out


## The newline-normalized lines of a text file with packed-array payloads elided, or an empty array when it can't be opened (an empty file still yields one empty line, so empty means unreadable).
static func _file_lines(path: String) -> PackedStringArray:
	return _elided_file_lines(path)["lines"]


## _file_lines plus whether any elision fired, for the callers that stamp SessionLedger.elided_files. Elision here is what keeps every raw-text server consistent with read_file's default: a blob withheld there must not be fishable out of a search excerpt or a function body instead (wild-observed — a model told "the read tool elides packed-array blobs" pulled all four tile_map_data payloads through search_files, 25 KB against the 5 KB elided read); read_file's full:true is the single deliberate route to the payloads. A payload sits on one line and the marker replaces it in place, so line numbers still match the file on disk.
static func _elided_file_lines(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"lines": PackedStringArray(), "elided": false}
	var raw := file.get_as_text().replace("\r\n", "\n").replace("\r", "\n")
	var text := _elide_packed_arrays(raw)
	return {"lines": text.split("\n"), "elided": text != raw}


## The refusal for a file that resolved — so it existed when its path was checked moments earlier — and then would not open, naming the OS-level cause and the move that cause calls for: a vanished file has to be re-located, a permission or lock failure is the user's to clear and no retry can help, and a condition that has already lifted is the one case worth calling again. The code comes from a fresh open attempt rather than the caller's, since FileAccess.get_open_error() is static and any intervening open would have overwritten it.
static func _file_open_error(resolved: String, purpose := "read") -> String:
	var retry := FileAccess.open(resolved, FileAccess.READ)
	var err := FileAccess.get_open_error()
	var head := "Error: %s could not be opened to %s" % [resolved, purpose]
	if retry != null:
		return "%s a moment ago, but it opens now, so whatever held it has lifted. %s" % [head, TRANSIENT_RETRY_INVITATION]
	match err:
		ERR_FILE_NOT_FOUND:
			return "%s: it is gone from disk, though it was there when the path resolved moments ago — it has just been deleted or moved. Find its new location with search_files, or tell the user it is gone." % head
		# Godot reports a permission-denied open as the generic ERR_FILE_CANT_OPEN on Linux, so the two codes share one branch and the wording covers both causes.
		ERR_FILE_NO_PERMISSION, ERR_FILE_CANT_OPEN:
			return "%s: the operating system refused to open it, most often because of the file's permissions. No tool here can change that — tell the user to check the permissions on it." % head
		ERR_FILE_ALREADY_IN_USE, ERR_LOCKED:
			return "%s: another program holds it locked. Tell the user which file it is so they can close whatever has it open; nothing here can unlock it." % head
		_:
			return "%s (%s). Nothing in the project state explains this, so tell the user rather than retrying." % [head, error_string(err)]


## The cause clause for a resource file that exists but would not load, always a full explanation ending in the move it calls for. The dominant cause is a broken dependency — one the engine's own dependency records can name — and the two shapes want different fixes: a dependency missing outright is restored or re-referenced, while a dependency that is present leaves a script that no longer compiles as the likely culprit, which check_script can confirm. A UID-only reference counts as present when its uid still resolves, since the load follows the uid, not the stale recorded path.
static func _resource_load_cause(resolved: String) -> String:
	var missing := PackedStringArray()
	var scripts := PackedStringArray()
	for entry in ResourceLoader.get_dependencies(resolved):
		var parsed := _parse_dependency_entry(String(entry))
		var dep := String(parsed["path"])
		var uid := String(parsed["uid"])
		if dep == "" and uid == "":
			continue
		var current := _uid_current_path(uid)
		if current != "" and FileAccess.file_exists(current):
			dep = current
		elif dep == "" or not FileAccess.file_exists(dep):
			missing.append(dep if dep != "" else uid)
			continue
		if dep.get_extension().to_lower() == "gd":
			scripts.append(dep)
	if not missing.is_empty():
		return "it references %s that no longer exist%s: %s. Restore %s, or edit the reference to point at the file that replaced it." % ["files" if missing.size() > 1 else "a file", "" if missing.size() > 1 else "s", ", ".join(missing), "them" if missing.size() > 1 else "it"]
	if not scripts.is_empty():
		return "every file it references exists, so the likely cause is a script it depends on failing to compile — check %s with check_script and fix what that reports." % ", ".join(scripts)
	var ext := resolved.get_extension().to_lower()
	# A .scn/.res is binary, so sending the model to read_file would only earn it the binary-file refusal.
	if ext in ["scn", "res"]:
		return "the engine rejected the file's own contents, and it is a binary resource, so nothing here can inspect what is wrong inside it. Tell the user to restore it from version control or re-save it from the editor."
	return "the engine rejected the file's own contents. read_file it and check the %s header: a type or script the project no longer defines fails the load." % ("[gd_scene]" if ext == "tscn" else "[gd_resource]")


## The cause clause for a path that would not accept a write, naming the OS-level reason and whose move it is: a missing folder is the caller's to avoid, a read-only file or a permission failure is the user's to clear and no retry can help, and a condition that has already lifted is the one case worth calling again. An existing file is probed with READ_WRITE, never WRITE — the truncating mode would destroy the very file whose update just failed — and a file that does not exist yet is not probed at all, since creating it is what failed.
static func _write_failure_cause(dest: String) -> String:
	if not FileAccess.file_exists(dest):
		var dir := dest.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			return "the folder %s does not exist, so nothing can be written into it. Write to a path whose folder already exists, or ask the user to create that folder." % dir
		return "the file does not exist and the operating system refused to create it in %s, most often because of that folder's permissions. No tool here can change that — tell the user to check them." % dir
	var retry := FileAccess.open(dest, FileAccess.READ_WRITE)
	var err := FileAccess.get_open_error()
	if retry != null:
		return "it takes writes now, so whatever held it has lifted. %s" % TRANSIENT_RETRY_INVITATION
	match err:
		# Godot reports a permission-denied open as the generic ERR_FILE_CANT_OPEN on Linux, so the codes share one branch and the wording covers every cause.
		ERR_FILE_NO_PERMISSION, ERR_FILE_CANT_OPEN, ERR_FILE_CANT_WRITE:
			return "the operating system refused to write it, most often because the file is marked read-only. No tool here can change that — tell the user to clear the read-only flag on it."
		ERR_FILE_ALREADY_IN_USE, ERR_LOCKED:
			return "another program holds it locked. Tell the user which file it is so they can close whatever has it open; nothing here can unlock it."
		_:
			return "the operating system refused the write (%s). Nothing in the project state explains this, so tell the user rather than retrying." % error_string(err)


## The refusal for a write that failed, `subject` naming what did not reach disk so the caller's own wording survives.
static func _file_write_error(dest: String, subject := "the changes") -> String:
	return "Error: %s could not be written to %s — %s" % [subject, dest, _write_failure_cause(dest)]


## The cause clause for a failed ResourceSaver.save, split by what actually refused: a write-level code means the filesystem and gets the same walk every other failed write gets, while any other code means the engine would not serialize the resource at all — where an extension that doesn't match what is being saved is the usual culprit and the one thing the caller can change.
static func _resource_save_cause(dest: String, err: int) -> String:
	match err:
		ERR_FILE_CANT_WRITE, ERR_FILE_CANT_OPEN, ERR_FILE_NO_PERMISSION, ERR_FILE_ALREADY_IN_USE, ERR_LOCKED:
			return _write_failure_cause(dest)
		_:
			return "the engine refused to serialize it (%s). Check that the extension matches what is being saved — .tres for a text resource, .res for a binary one, and .tscn only for a PackedScene." % error_string(err)


## Return the full body of the named function from a GDScript file — the narrow follow-up to a search excerpt or file map: exactly one function's code instead of the whole file. Every same-named function is returned (inner classes can repeat a name); an unknown name lists the file's real function names so the model can correct itself instead of dead-ending.
static func _read_function(args: Dictionary, ledger: SessionLedger) -> String:
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. Pass the file in \"path\" and the function in \"name\"."
	var fname := _arg_string(args, FUNC_NAME_KEYS)
	if fname == "":
		# Transcript-observed: a ranged call with no name means the model wanted read_file's start_line/end_line; cross-hint the right tool instead of only demanding a name.
		if _arg_int(args, RANGE_START_KEYS, 0) > 0 or _arg_int(args, RANGE_END_KEYS, 0) > 0:
			return "Error: no function name was provided, and read_function has no start_line/end_line — it pulls one function by NAME. For a raw line range use read_file ({\"path\": \"...\", \"start_line\": 20, \"end_line\": 40}); to pull a function instead, pass its name in \"name\"."
		return "Error: no function name was provided. Pass it in \"name\", e.g. {\"path\": \"res://player.gd\", \"name\": \"_ready\"}."
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	if resolved.get_extension().to_lower() != "gd":
		return "Error: %s is not a GDScript file, and read_function only understands GDScript. Use read_file for other files." % resolved
	await _await_path_stable(resolved)
	var read := _elided_file_lines(resolved)
	var lines: PackedStringArray = read["lines"]
	if lines.is_empty():
		return _file_open_error(resolved)
	# Same rule as read_file: this call marks the file seen verbatim below, so a data-carrying script must arm the overwrite gate here too.
	if bool(read["elided"]):
		_stamp_elided_path(resolved, ledger)
	# Tolerate a name copied with decoration — "func add_item(item)" resolves the same as "add_item".
	var clean := fname.strip_edges().trim_prefix("static func ").trim_prefix("func ")
	var paren := clean.find("(")
	if paren != -1:
		clean = clean.substr(0, paren)
	clean = clean.strip_edges()
	var found: Array[Vector2i] = []
	var names: Array[String] = []
	for i in lines.size():
		if not _is_func_header(lines[i]):
			continue
		var n := _func_name(lines[i])
		names.append(n)
		if n.to_lower() == clean.to_lower():
			found.append(_enclosing_gdscript_range(lines, i))
	if found.is_empty():
		if names.is_empty():
			return "No functions found in %s." % resolved
		# Near-misses first (the containment rule), so a misspelling suggests its likely targets instead of dumping a large script's whole roster; the fallback list caps at the universal suggestion size.
		var near: Array[String] = []
		for n in names:
			if _node_name_near_miss(n, clean.to_lower()):
				near.append(n)
		if not near.is_empty() and near.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP):
			return "No function named \"%s\" in %s. Closest names in this file: %s." % [clean, resolved, ", ".join(near)]
		var shown: Array = names.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
		var more := ""
		if names.size() > shown.size():
			more = " (and %d more — read_file lists every function)" % (names.size() - shown.size())
		return "No function named \"%s\" in %s. Functions in this file: %s%s." % [clean, resolved, ", ".join(shown), more]
	_mark_seen(resolved, true, ledger)
	var blocks: Array = []
	for span in found:
		var body: Array = ["%s:%d-%d (func %s):" % [resolved, span.x + 1, span.y + 1, clean]]
		for li in range(span.x, span.y + 1):
			body.append("%4d: %s" % [li + 1, lines[li]])
		blocks.append("\n".join(body))
	var joined := "\n\n".join(blocks)
	return _resolution_note(requested, resolved) + joined + _elision_note(joined)


## Turn a requested path or bare file name into an existing res:// (or user://) file path, or "" if nothing resolves. A uid:// request resolves through the engine's uid registry to wherever the file lives now — GDScript accepts uids everywhere paths go, so the tools must too. An explicit path that exists is used as-is; anything else — including a res:// path whose directories were guessed wrong — falls back to an exact file-name search across the project, which only resolves when the name is UNIQUE, so a name shared by several files fails rather than silently picking one (see _file_not_found for the message that lists them).
static func _resolve_file_path(path: String) -> String:
	if path.begins_with("uid://"):
		var current := _uid_current_path(path)
		return current if current != "" and FileAccess.file_exists(current) else ""
	if path.begins_with("res://") or path.begins_with("user://"):
		if FileAccess.file_exists(path):
			return path
		if path.begins_with("user://"):
			return ""
	var direct := "res://" + path.trim_prefix("res://").trim_prefix("./").trim_prefix("/")
	if FileAccess.file_exists(direct):
		return direct
	var matches := _find_all_by_name("res://", path.get_file())
	if matches.size() == 1:
		return matches[0]
	# An extensionless name ("world_start") is unambiguous intent when exactly one file carries that stem — wild-measured at ~7 recoverable errors across two validation rounds, each costing a round trip the auto-resolve removes. A name that is also a directory stays unresolved: the directory answer (_file_not_found's list_directory pointer) is the right one there.
	if matches.is_empty() and path.get_file() != "" and path.get_file().get_extension() == "" and _resolve_dir_path(path) == "":
		var stems := _find_all_by_name("res://", path.get_file(), false, true)
		if stems.size() == 1:
			return stems[0]
	return ""


## The loud "requested X, resolved to Y" disclosure prepended when a read resolved by file-name search rather than at the requested path — silent resolution is the phantom-refactor trap: transcripts show a model reading "res://game/x.gd", silently receiving "res://scripts/x.gd", then write_file-ing the requested path as a NEW duplicate while the real file goes untouched. A bare name gets a calmer note carrying just the full path, since write_file resolves bare names to the existing file and the trap doesn't arm. "" when the request named the real location (modulo the res:// prefix), so the common case costs nothing.
static func _resolution_note(requested: String, resolved: String) -> String:
	if resolved == requested:
		return ""
	if requested.begins_with("uid://"):
		return "Note: %s is %s per the project's uid registry; the res:// path works in any later call.\n\n" % [requested, resolved]
	if resolved == "res://" + requested.trim_prefix("res://").trim_prefix("./").trim_prefix("/"):
		return ""
	var trimmed := requested.trim_prefix("./")
	if not trimmed.begins_with("res://") and not trimmed.contains("/"):
		return "Note: \"%s\" was resolved by file name to %s, the only file with that name in the project; use that full path in later calls.\n\n" % [requested, resolved]
	return "IMPORTANT: no file exists at the path you requested (\"%s\") — it was resolved BY FILE NAME to %s, the only file with that name in the project. Use %s in every later call; writing to the path you requested would CREATE A SECOND FILE there, not change this one.\n\n" % [requested, resolved, resolved]


## Turn a requested path or bare name into an existing res:// (or user://) directory path, or "" if it isn't a directory. Explicit res://user:// paths are checked as-is; anything else is tried relative to res://, then — for a bare name matching exactly one directory anywhere in the project — resolved by name the way bare file names are (wild-caught: "stress_test" dead-ended and the model told the user a directory that exists doesn't).
static func _resolve_dir_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path if DirAccess.dir_exists_absolute(path) else ""
	var name := path.trim_prefix("./").trim_prefix("/").trim_suffix("/")
	var direct := "res://" + name
	if DirAccess.dir_exists_absolute(direct):
		return direct
	if name != "" and not name.contains("/"):
		var found := _find_dirs_by_name("res://", name)
		if found.size() == 1:
			return found[0]
	return ""


## Depth-first search for every directory named `dir_name` under `root`, skipping hidden entries — the directory counterpart of _find_all_by_name, so a bare directory name resolves (or gets listed as a candidate) the way a bare file name does.
static func _find_dirs_by_name(root: String, dir_name: String) -> PackedStringArray:
	var found := PackedStringArray()
	if dir_name == "":
		return found
	var dir := DirAccess.open(root)
	if dir == null:
		return found
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with(".") or not dir.current_is_dir():
			continue
		var sub := root.path_join(entry)
		if entry == dir_name:
			found.append(sub)
		found.append_array(_find_dirs_by_name(sub, dir_name))
	dir.list_dir_end()
	return found


## Refuse an explicit path into a hidden directory (any leading-dot component), "" when clear. The walk helpers already skip hidden entries, so a typed path is held to the same line rather than opening what no listing would ever surface — wild-measured, a model debugging a broken import listed res://.godot/imported three times at ~64 KB of engine cache names per call.
static func _hidden_dir_guard(resolved: String) -> String:
	var rel := resolved.trim_prefix("res://").trim_prefix("user://")
	for part in rel.split("/", false):
		# "." and ".." are path navigation, not hidden names — wild-caught: a model spelling the project root "res://." was refused as hidden.
		if not part.begins_with(".") or part == "." or part == "..":
			continue
		if part == ".godot":
			return "Error: %s is the engine's own cache — import artifacts, compiled state, and registries that only restate project files under mangled names. Work with the real files instead: the asset's own res:// path, read_file on its .import sidecar for import state, or describe_project for settings." % resolved
		if part == ".git":
			return "Error: %s is version-control history, not project content — nothing in it is a file the project uses." % resolved
		return "Error: %s is inside a hidden directory (\"%s\"), which holds tool bookkeeping rather than project content — listings and searches always skip hidden entries, so an explicit path into one is refused the same way." % [resolved, part]
	return ""


## Depth-first search of the project tree for every file named `file_name`, returning their res:// paths. `loose` matches case- and underscore-insensitively, so a PascalCase class name finds its snake_case script. Hidden entries (leading ".", e.g. .godot/.git) are skipped.
static func _find_all_by_name(dir_path: String, file_name: String, loose := false, stem := false) -> PackedStringArray:
	var found := PackedStringArray()
	if file_name == "":
		return found
	var want := file_name.to_snake_case().to_lower() if loose else file_name
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return found
	var sub_dirs: Array[String] = []
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		if dir.current_is_dir():
			sub_dirs.append(dir_path.path_join(entry))
		else:
			# Stem matching compares against the name minus its last extension, which naturally excludes sidecars ("x.tscn.uid" stems to "x.tscn", never "x").
			var have := entry.get_basename() if stem else entry
			if (have.to_snake_case().to_lower() if loose else have) == want:
				found.append(dir_path.path_join(entry))
	dir.list_dir_end()
	for sub in sub_dirs:
		found.append_array(_find_all_by_name(sub, file_name, loose, stem))
	return found


## Failure text for a path that didn't resolve. Several files sharing the requested name are listed so the model can retry with a full path instead of guessing directories; with no exact match, near-misses by case/underscores (e.g. a PascalCase class name for a snake_case script) are suggested, then files whose basename merely contains the request or vice versa (see _basename_near_miss); otherwise a plain not-found. `noun` lets a caller name what it was looking for ("scene file", "file or directory").
static func _file_not_found(requested: String, noun := "file") -> String:
	if requested.begins_with("uid://"):
		var recorded := _uid_current_path(requested)
		if recorded != "":
			return "Error: %s is registered to %s, but that file no longer exists on disk — the uid registration is stale. Search the project for \"%s\" by name to find where it went, or tell the user it was deleted." % [requested, recorded, recorded.get_file()]
		return "Error: %s is not any file's uid in this project — likely invented (UIDs are engine-assigned, never written by hand) or left over from a deleted file. Use the file's res:// path, or the real uid a tool result reported: write_file/create_resource confirmations carry it, and read_file of a .tscn/.tres header or a script's .uid sidecar shows it." % requested
	# A DIRECTORY reaching a file tool is not a missing path — it exists, and the caller is one tool away from what it wanted. Wild-observed: read_file on res://resources/augments answered "no file found matching" and left the model to guess a filename, when the folder was right there to list. search_files can't reach this branch: it resolves a directory scope before ever composing a not-found.
	var as_dir := _resolve_dir_path(requested)
	if as_dir != "":
		return "Error: %s is a DIRECTORY, not a %s. Use list_directory ({\"path\": \"%s\"}) to see what is in it, then name one of those files here." % [as_dir, noun, as_dir]
	var file_name := requested.get_file()
	var exact := _find_all_by_name("res://", file_name)
	if exact.size() > 1:
		return "Error: %d files in the project are named \"%s\": %s. Pass the full res:// path of the one you mean." % [exact.size(), file_name, ", ".join(exact)]
	var near := _find_all_by_name("res://", file_name, true)
	if not near.is_empty():
		return "Error: no %s found matching \"%s\" in the project. Similarly named: %s." % [noun, requested, ", ".join(near)]
	var msg := "Error: no %s found matching \"%s\" in the project." % [noun, requested]
	var partial := _basename_near_miss(file_name)
	if not partial.is_empty():
		return "%s Did you mean: %s?" % [msg, ", ".join(partial)]
	return msg


## Project files whose basename contains the requested one or vice versa (case-insensitive, the reverse floored like _create_res_near_miss so a tiny name doesn't drag in everything), capped at GDLLMTunables.SUGGESTION_LIST_CAP and sorted — transcripts show a model retrying a guessed name ("seed_managem.tres") that only existed with a prefix, with no pointer to the real file.
static func _basename_near_miss(file_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	if file_name == "":
		return out
	var needle := file_name.to_lower()
	var files: Array[String] = []
	_collect_text_files("res://", files)
	for path in files:
		var base := path.get_file().to_lower()
		if base.contains(needle) or (base.get_basename().length() >= 4 and needle.contains(base)):
			out.append(path)
	out.sort()
	return out.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))


## Split the immediate children of `dir_path` into `dirs_out` (subdirectory names) and `files_out` (file names), both bare names. Hidden entries (leading ".") are skipped.
static func _list_dir(dir_path: String, dirs_out: Array, files_out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		if dir.current_is_dir():
			dirs_out.append(entry)
		else:
			files_out.append(entry)
	dir.list_dir_end()


## Whether the basename of `path` matches Godot's editor save-temp pattern ("name.ext<digits>.tmp"), written during saves and sometimes left behind — transcripts show a model citing one's stale contents as syntax evidence, so scans and listings hide them (with a count, never silently).
static func _is_editor_temp(path: String) -> bool:
	return RegEx.create_from_string("\\.\\w+\\d+\\.tmp$").search(path.get_file()) != null


## Depth-first collect the res:// paths of every file under `dir_path` into `out`. Hidden entries (leading ".", e.g. .godot/.git) and editor save-temps (see _is_editor_temp) are skipped; binary files aren't filtered here (the caller checks per file).
static func _collect_text_files(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var sub_dirs: Array[String] = []
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			sub_dirs.append(full)
		elif not _is_editor_temp(entry):
			out.append(full)
	dir.list_dir_end()
	for sub in sub_dirs:
		_collect_text_files(sub, out)


## Whether `path` looks like a binary file, judged by a null byte in its first 4 KB — cheap and good enough to keep a garbled blob out of the conversation. A missing/unreadable file reads as non-binary so the caller's own open error surfaces instead.
static func _looks_binary(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var sample := file.get_buffer(mini(4096, file.get_length()))
	for b in sample:
		if b == 0:
			return true
	return false


## Whether line `idx` falls inside any span already emitted for a file, so overlapping matches collapse into one excerpt.
static func _index_within_any(idx: int, spans: Array[Vector2i]) -> bool:
	for span in spans:
		if idx >= span.x and idx <= span.y:
			return true
	return false


## The excerpt to show for a match at `idx`, as {span, func_name, func_len, windowed}: the whole enclosing GDScript function when it fits the excerpt budget, otherwise a `context_lines` window — still annotated with the function it sits in so read_function can pull the body on demand. The budget is GDLLMTunables.SEARCH_MAX_FUNCTION_LINES at the default context but grows with an explicit larger `context_lines` ask, so a function is never windowed smaller than the window the caller asked for.
static func _excerpt_for(lines: PackedStringArray, idx: int, context_lines: int, is_gd: bool) -> Dictionary:
	var func_name := ""
	var func_len := 0
	if is_gd:
		var fspan := _enclosing_gdscript_range(lines, idx)
		if fspan.x != -1:
			func_name = _func_name(lines[fspan.x])
			func_len = fspan.y - fspan.x + 1
			if func_len <= maxi(GDLLMTunables.geti(GDLLMTunables.SEARCH_MAX_FUNCTION_LINES), 2 * context_lines + 1):
				return {"span": fspan, "func_name": func_name, "func_len": func_len, "windowed": false}
	var span := Vector2i(maxi(0, idx - context_lines), mini(lines.size() - 1, idx + context_lines))
	return {"span": span, "func_name": func_name, "func_len": func_len, "windowed": func_name != ""}


## The [header, end] line span of the GDScript function containing line `idx`, or Vector2i(-1, -1) if none does. Walks up to the nearest `func`/`static func` header, then down to the line before the next line indented no deeper than the header (trailing blanks trimmed); a match sitting past that end (e.g. between two functions) counts as uncontained.
static func _enclosing_gdscript_range(lines: PackedStringArray, idx: int) -> Vector2i:
	var header := -1
	var i := idx
	while i >= 0:
		if _is_func_header(lines[i]):
			header = i
			break
		i -= 1
	if header == -1:
		return Vector2i(-1, -1)
	var func_indent := _indent_width(lines[header])
	var end := lines.size() - 1
	var j := header + 1
	while j < lines.size():
		var line := String(lines[j])
		if line.strip_edges() != "" and _indent_width(line) <= func_indent:
			end = j - 1
			break
		j += 1
	while end > header and String(lines[end]).strip_edges() == "":
		end -= 1
	return Vector2i(header, end) if idx <= end else Vector2i(-1, -1)


static func _is_func_header(line: String) -> bool:
	var stripped := line.strip_edges()
	return stripped.begins_with("func ") or stripped.begins_with("static func ")


## The number of leading whitespace characters on a line, used to compare GDScript block depth.
static func _indent_width(line: String) -> int:
	return line.length() - line.lstrip("\t ").length()


## The bare function name from a `func`/`static func` header line, e.g. "func _ready() -> void:" -> "_ready", for labelling a search excerpt.
static func _func_name(header_line: String) -> String:
	var stripped := header_line.strip_edges()
	if stripped.begins_with("static "):
		stripped = stripped.substr(7).strip_edges()
	stripped = stripped.trim_prefix("func ").strip_edges()
	var paren := stripped.find("(")
	return stripped.substr(0, paren) if paren != -1 else stripped


## Render one search excerpt block (see _excerpt_for): a "path:line" header annotated with the enclosing function over the span's numbered lines, each matching line flagged with ">". A windowed block's header notes the function was too long to show whole and points at read_function and a larger context_lines ask.
static func _render_block(path: String, lines: PackedStringArray, block: Dictionary, matched: Array[int]) -> String:
	var span: Vector2i = block["span"]
	var suffix := ""
	if String(block["func_name"]) != "":
		if bool(block["windowed"]):
			suffix = " (in %s — a %d-line function; window shown, use read_function for the full body or re-run with a larger context_lines)" % [block["func_name"], int(block["func_len"])]
		else:
			suffix = " (in %s)" % block["func_name"]
	var body: Array = ["%s:%d%s" % [path, int(block["trigger"]) + 1, suffix]]
	for line_index in range(span.x, span.y + 1):
		var marker := ">" if line_index in matched else " "
		body.append("%s %4d: %s" % [marker, line_index + 1, lines[line_index]])
	return "\n".join(body)


## Render the live engine reference for the class named by `args.class`, read straight from ClassDB so it reflects what actually exists in this build rather than the model's memory — reality grounding, goal 2. Shows the inheritance chain and the class's own members (properties, methods, signals, enums, constants); `inherited: true` folds in inherited members and `filter` narrows to member names containing a substring, the two escape valves that keep a huge base class from flooding the context (goal 1). Errors — an unknown or misspelled class — come back as plain content the model can read and recover from, with near-miss suggestions.
static func _describe_class(args: Dictionary) -> String:
	var requested := _class_arg(args, CLASS_KEYS)
	if requested == "":
		return "Error: no class name was provided. Pass the class to look up in \"class\", e.g. \"Sprite2D\"."
	var no_inheritance := not _arg_bool(args, INHERITED_KEYS)
	var filter := _arg_string(args, MEMBER_FILTER_KEYS).to_lower()
	var kinds_arg := _class_kinds_arg(args)
	if kinds_arg.has("error"):
		return String(kinds_arg["error"])
	var kinds: Dictionary = kinds_arg["kinds"]
	var cls := _resolve_class_name(requested)
	if cls == "":
		return await _describe_non_classdb(requested, no_inheritance, filter, kinds)

	# Enum members are excluded from the plain-constants section, so gather them first regardless of the filter.
	var enum_members := _class_enum_member_set(cls, no_inheritance)
	var pairs: Array = [
		["Properties", _class_properties(cls, no_inheritance, filter)],
		["Methods", _class_methods(cls, no_inheritance, filter)],
		["Signals", _class_signals(cls, no_inheritance, filter)],
		["Enums", _class_enums(cls, no_inheritance, filter)],
		["Constants", _class_constants(cls, no_inheritance, filter, enum_members)],
	]

	var head: Array = []
	head.append("Godot engine reference for %s — the live ClassDB API, the authoritative record of what exists in this engine build (not recalled from memory)." % cls)
	head.append("")
	head.append("Inheritance: %s" % _inheritance_chain(cls))
	head.append("")
	if no_inheritance:
		head.append("Showing %s's own members only (not inherited). Look up a parent class above for inherited members, or pass inherited=true to include them here." % cls)
	else:
		head.append("Showing every member of %s, including those inherited from its parent classes." % cls)
	if filter != "":
		head.append("Filtered to members whose name contains \"%s\"." % filter)
	var kinds_note := _class_kinds_note(kinds)
	if kinds_note != "":
		head.append(kinds_note)

	# Judged against the SELECTED sections, since "nothing matched" must mean nothing the caller asked to see — a hit in a section `kind` excluded is not an answer.
	var any_member := false
	for pair in pairs:
		if (kinds.is_empty() or kinds.has(String(pair[0]))) and not (pair[1] as Array).is_empty():
			any_member = true
	if filter != "" and not any_member:
		head.append("")
		head.append("No members whose name contains \"%s\" were found on %s. Try a different substring, or omit filter to see the whole API." % [filter, cls])
		var theme_note := _theme_item_note(cls, filter)
		if theme_note != "":
			head.append(theme_note)
		return "\n".join(head)

	return "\n".join(head) + "\n\n" + "\n\n".join(_class_sections_for(pairs, kinds))


## The `kind` argument as a set of section titles ({} when absent, meaning every section), or {"error"} naming the kinds that exist. A bare string and a list both work — the `show` shape run_game already uses — since one kind is written as a string and two as a list, and an unrecognized name is refused rather than silently widened back to the whole class, which would look like the argument was honored.
static func _class_kinds_arg(args: Dictionary) -> Dictionary:
	var raw: Variant = null
	for key in CLASS_KIND_KEYS:
		if args.has(key):
			raw = args[key]
			break
	if raw == null:
		return {"kinds": {}}
	var requested: Array = raw if raw is Array else [raw]
	var kinds: Dictionary = {}
	for item in requested:
		var name := String(item).strip_edges().to_lower().replace("-", "_")
		if name == "":
			continue
		name = String(CLASS_KIND_ALIASES.get(name, name))
		if not CLASS_KINDS.has(name):
			return {"error": "Error: \"%s\" is not a member kind. Pass one of: %s (a single name or a list of them) — or omit `kind` for every section." % [item, ", ".join(CLASS_KINDS.keys())]}
		kinds[String(CLASS_KINDS[name])] = true
	return {"kinds": kinds}


## Render the [title, items] section pairs a rung produced, keeping only those `kinds` asked for ({} keeps all). A `kind` no rung of this shape has is answered with the sections it DOES have rather than an empty report — a Variant type has constructors and an engine class does not, and only the rung knows which.
static func _class_sections_for(pairs: Array, kinds: Dictionary) -> Array:
	var out: Array = []
	var titles: Array[String] = []
	for pair in pairs:
		var title := String(pair[0])
		titles.append(title)
		if kinds.is_empty() or kinds.has(title):
			out.append(_format_class_section(title, pair[1]))
	if out.is_empty():
		out.append("None of the requested kinds exist on this one. It reports: %s." % ", ".join(titles))
	return out


## The one-line disclosure the head carries when `kind` narrowed the report, so a section the model does not see is never mistaken for a section the class does not have.
static func _class_kinds_note(kinds: Dictionary) -> String:
	if kinds.is_empty():
		return ""
	var titles: Array[String] = []
	for title in kinds:
		titles.append(String(title))
	titles.sort()
	return "Narrowed to %s only — omit `kind` for every section." % ", ".join(titles)


## The canonical ClassDB name for `requested`, resolving case-insensitively so a lowercased guess ("sprite2d") still lands, or "" if no class matches. An exact hit is returned as-is to skip the scan of the whole class list.
static func _resolve_class_name(requested: String) -> String:
	if ClassDB.class_exists(requested):
		return requested
	var lowered := requested.to_lower()
	for c in ClassDB.get_class_list():
		if String(c).to_lower() == lowered:
			return String(c)
	# A prose request ("Panel class definition") usually embeds the class as one word; the first token that resolves wins.
	if requested.contains(" "):
		for token in requested.split(" ", false):
			var hit := _resolve_class_name(token)
			if hit != "":
				return hit
	return ""


## describe_class's ladder for a name ClassDB doesn't hold, because ClassDB is only one of three registries a Godot name can live in and the other two were dead ends: the project's own class_name scripts (~90 in a real game, and the dominant miss — Slot, Boon, ProjectileData all refused), then the doc cache's non-ClassDB pages (the Variant types and built-in scopes, plus @GlobalScope's enums by bare name — Array, Callable and Key were all refused too). Only when all three miss does the refusal compose, and it then names every namespace searched.
static func _describe_non_classdb(requested: String, no_inheritance: bool, filter: String, kinds: Dictionary) -> String:
	var project := GDLLMClasses.resolve(requested)
	if not project.is_empty():
		var loaded := GDLLMClasses.script_for(project)
		if loaded.has("error"):
			return String(loaded["error"])
		return GDLLMClasses.describe_script(loaded["script"] as Script, no_inheritance, filter, kinds)
	var docs: Dictionary = await GDLLMDocs.structure(requested, filter, kinds)
	if docs.has("content"):
		return String(docs["content"])
	return _unknown_class_message(requested, String(docs.get("error", "")))


## Error text for a class that resolves in none of the three registries, with up to GDLLMTunables.SUGGESTION_LIST_CAP near-miss names drawn from all of them so a misspelling is correctable wherever the real name lives, and naming the tools that answer for what has no class at all — a script with no class_name, or a concept whose name is the thing being looked for. `docs_error` is passed when the doc cache itself was the thing that failed, since then "no such page" would be a claim this run can't make.
static func _unknown_class_message(requested: String, docs_error: String = "") -> String:
	var seen: Dictionary = {}
	var suggestions: Array[String] = []
	for c in ClassDB.get_class_list():
		if _class_near_miss(requested, String(c)):
			seen[String(c)] = true
			suggestions.append(String(c))
	for c in GDLLMClasses.names():
		if _class_near_miss(requested, c) and not seen.has(c):
			seen[c] = true
			suggestions.append("%s (this project's script class)" % c)
	for c in GDLLMDocs.page_names():
		if _class_near_miss(requested, String(c)) and not seen.has(String(c)):
			seen[String(c)] = true
			suggestions.append("%s (engine doc page)" % c)
	var msg := "Error: \"%s\" is not an engine class (ClassDB), one of this project's own class_name scripts, or an engine doc page (the Variant types, @GDScript, @GlobalScope and its enums) — all three were searched." % requested
	if docs_error != "":
		msg += " Note the doc pages could not be consulted this time: %s" % docs_error
	var levers := " A project script with no class_name has no class to look up — read_file it by path, or search_files for the name. For a concept rather than a name, search_docs finds the engine term."
	if suggestions.is_empty():
		return msg + levers
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?%s" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note, levers]


## Whether `candidate` is worth suggesting for `requested`: either name contains the other, the same rule the member lookups use. The reverse direction is what catches an invented name built out of a real one — "StyleBoxBase" suggests StyleBox, where plain containment suggested nothing at all — and it carries the same length floor, or a short class name would near-miss every long request.
static func _class_near_miss(requested: String, candidate: String) -> bool:
	var needle := requested.to_lower()
	var lowered := candidate.to_lower()
	return lowered.contains(needle) or (lowered.length() >= 4 and needle.contains(lowered))


## The inheritance chain from `cls` up to Object as "Cls < Parent < … < Object", so the model can see where a class sits and which parents to look up for inherited members.
static func _inheritance_chain(cls: String) -> String:
	var chain: Array[String] = [cls]
	var parent := ClassDB.get_parent_class(cls)
	while parent != "":
		chain.append(parent)
		parent = ClassDB.get_parent_class(parent)
	return " < ".join(chain)


## The class's properties as "name: Type" lines, filtered by name substring. Group/subgroup/category headers and nameless entries in the property list are skipped so only real, addressable properties show.
static func _class_properties(cls: String, no_inheritance: bool, filter: String) -> Array:
	var out: Array[String] = []
	for p in ClassDB.class_get_property_list(cls, no_inheritance):
		var pname := String(p.get("name", ""))
		if pname == "":
			continue
		if int(p.get("usage", 0)) & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		if filter != "" and not pname.to_lower().contains(filter):
			continue
		out.append("%s: %s" % [pname, _type_label(p)])
	return out


## The class's methods as full signature lines, filtered by name substring (see _method_signature).
static func _class_methods(cls: String, no_inheritance: bool, filter: String) -> Array:
	var out: Array[String] = []
	for m in ClassDB.class_get_method_list(cls, no_inheritance):
		if filter != "" and not String(m.get("name", "")).to_lower().contains(filter):
			continue
		out.append(_method_signature(m))
	return out


## One method's signature — "name(arg: Type = default, …) -> Return" — plus any qualifiers in brackets. Trailing arguments carry their defaults (ClassDB lists defaults for the last N args), a vararg method gets a trailing "...", and static/const/virtual are read from the method flags.
static func _method_signature(m: Dictionary) -> String:
	var mname := String(m.get("name", ""))
	var margs: Array = m.get("args", [])
	var defaults: Array = m.get("default_args", [])
	var first_default := margs.size() - defaults.size()
	var parts: Array[String] = []
	for i in margs.size():
		var a: Dictionary = margs[i]
		var piece := "%s: %s" % [String(a.get("name", "arg%d" % i)), _type_label(a)]
		if i >= first_default:
			piece += " = " + _format_default(defaults[i - first_default])
		parts.append(piece)
	var flags := int(m.get("flags", 0))
	if flags & METHOD_FLAG_VARARG:
		parts.append("...")
	var sig := "%s(%s) -> %s" % [mname, ", ".join(parts), _type_label(m.get("return", {}))]
	var quals: Array[String] = []
	if flags & METHOD_FLAG_STATIC:
		quals.append("static")
	if flags & METHOD_FLAG_CONST:
		quals.append("const")
	if flags & METHOD_FLAG_VIRTUAL:
		quals.append("virtual")
	if not quals.is_empty():
		sig += "  [%s]" % " ".join(quals)
	return sig


## The class's signals as "name(arg: Type, …)" lines, filtered by name substring.
static func _class_signals(cls: String, no_inheritance: bool, filter: String) -> Array:
	var out: Array[String] = []
	for s in ClassDB.class_get_signal_list(cls, no_inheritance):
		var sname := String(s.get("name", ""))
		if filter != "" and not sname.to_lower().contains(filter):
			continue
		out.append(_signal_signature(s))
	return out


## One signal's signature — "name(arg: Type, …)" — from its ClassDB info dict.
static func _signal_signature(s: Dictionary) -> String:
	var parts: Array[String] = []
	for a in s.get("args", []):
		parts.append("%s: %s" % [String(a.get("name", "")), _type_label(a)])
	return "%s(%s)" % [String(s.get("name", "")), ", ".join(parts)]


## The class's enums as "EnumName { A = 0, B = 1 }" lines. The filter matches the enum name or any of its members, so filtering by a constant name still surfaces its enum.
static func _class_enums(cls: String, no_inheritance: bool, filter: String) -> Array:
	var out: Array[String] = []
	for e in ClassDB.class_get_enum_list(cls, no_inheritance):
		var ename := String(e)
		var members := ClassDB.class_get_enum_constants(cls, ename, no_inheritance)
		if filter != "" and not _enum_matches_filter(ename, members, filter):
			continue
		out.append(_enum_line(cls, ename, members))
	return out


## One enum rendered as "EnumName { A = 0, B = 1 }" from its member list.
static func _enum_line(cls: String, ename: String, members: PackedStringArray) -> String:
	var pairs: Array[String] = []
	for cm in members:
		pairs.append("%s = %d" % [String(cm), ClassDB.class_get_integer_constant(cls, String(cm))])
	return "%s { %s }" % [ename, ", ".join(pairs)]


## Whether an enum should survive the filter: its own name or any member name contains the substring.
static func _enum_matches_filter(ename: String, members: PackedStringArray, filter: String) -> bool:
	if ename.to_lower().contains(filter):
		return true
	for cm in members:
		if String(cm).to_lower().contains(filter):
			return true
	return false


## The class's plain integer constants as "NAME = value" lines, excluding those that belong to an enum (shown in the Enums section instead) and filtered by name substring.
static func _class_constants(cls: String, no_inheritance: bool, filter: String, enum_members: Dictionary) -> Array:
	var out: Array[String] = []
	for c in ClassDB.class_get_integer_constant_list(cls, no_inheritance):
		var cname := String(c)
		if enum_members.has(cname):
			continue
		if filter != "" and not cname.to_lower().contains(filter):
			continue
		out.append("%s = %d" % [cname, ClassDB.class_get_integer_constant(cls, cname)])
	return out


## The set (as a Dictionary of name->true) of every constant name that belongs to one of the class's enums, so the plain-constants section can leave them out.
static func _class_enum_member_set(cls: String, no_inheritance: bool) -> Dictionary:
	var members: Dictionary = {}
	for e in ClassDB.class_get_enum_list(cls, no_inheritance):
		for cm in ClassDB.class_get_enum_constants(cls, String(e), no_inheritance):
			members[String(cm)] = true
	return members


## Resolve one member of a class by exact (case-insensitive) name from live ClassDB — the narrow counterpart to _describe_class's browse: the name is tried against every member kind up the whole inheritance chain, and each hit reports its declaring class, so the model gets one member's ground truth without pulling a class's API into context. A property adds its default value and setter/getter; a constant its value and owning enum. An unresolved name comes back with near-miss suggestions rather than a dead end.
static func _describe_member(args: Dictionary) -> String:
	var requested_class := _class_arg(args, MEMBER_CLASS_KEYS)
	# Decoration is stripped before the dot-split so the dots in a pasted "(...)" aren't mistaken for a class separator.
	var member := _clean_member_name(_arg_string(args, MEMBER_NAME_KEYS))
	# "Class.member" in the member argument stands in for both.
	if member.contains("."):
		var dot := member.rfind(".")
		if requested_class == "":
			requested_class = member.substr(0, dot)
		member = member.substr(dot + 1)
	if requested_class == "":
		return "Error: no class was provided. Pass the class in \"class\" and the member in \"member\", e.g. {\"class\": \"Sprite2D\", \"member\": \"get_rect\"}."
	if member == "":
		return "Error: no member name was provided. Pass it in \"member\", e.g. {\"class\": \"Sprite2D\", \"member\": \"get_rect\"}."
	var cls := _resolve_class_name(requested_class)
	if cls == "":
		return await _describe_member_non_classdb(requested_class, member)
	var findings := _member_findings(cls, member)
	if findings.is_empty():
		return _unknown_member_message(cls, member)
	var lines: Array = ["Godot engine reference for %s.%s — the live ClassDB API, the authoritative record of what exists in this engine build (not recalled from memory)." % [cls, member], ""]
	lines.append_array(findings)
	return "\n".join(lines)


## describe_member's half of the same three-registry ladder describe_class walks: a project class_name is answered from the live script's registered API, while a doc-only page (a Variant type, a built-in scope) is answered by the engine docs and said to be — the cache carries that member's signature AND its prose, so delegating beats a refusal naming the tool the model would have to call next anyway.
static func _describe_member_non_classdb(requested_class: String, member: String) -> String:
	var project := GDLLMClasses.resolve(requested_class)
	if not project.is_empty():
		var loaded := GDLLMClasses.script_for(project)
		if loaded.has("error"):
			return String(loaded["error"])
		return GDLLMClasses.describe_member_script(loaded["script"] as Script, member)
	var docs_error: String = await GDLLMDocs.ensure_ready()
	if docs_error == "" and GDLLMDocs.has_page(requested_class):
		return "ClassDB has no entry for \"%s\" — it is an engine doc page (a Variant type or a built-in scope), so the engine's own documentation answered instead:\n\n%s" % [requested_class, await GDLLMDocs.describe(requested_class, member)]
	return _unknown_class_message(requested_class, docs_error)


## Tolerate a member name copied with decoration — "func get_rect()", "signal ready", "get_rect()" all resolve like the bare name.
static func _clean_member_name(member: String) -> String:
	var clean := member.strip_edges()
	for prefix in ["static func ", "func ", "signal ", "enum ", "const ", "var "]:
		clean = clean.trim_prefix(prefix)
	var paren := clean.find("(")
	if paren != -1:
		clean = clean.substr(0, paren)
	return clean.strip_edges()


## Every match for `member` across the class and its ancestors, one rendered line (or block) per hit, most-derived declaration first. Each ancestor is scanned for its OWN members only, so the declaring class is attributed exactly; kinds never collide in practice, but all are checked so a name shared across kinds shows every meaning.
static func _member_findings(cls: String, member: String) -> Array:
	var out: Array = []
	var needle := member.to_lower()
	var anc := cls
	while anc != "":
		for m in ClassDB.class_get_method_list(anc, true):
			if String(m.get("name", "")).to_lower() == needle:
				out.append("Method (declared in %s): %s" % [anc, _method_signature(m)])
		for p in ClassDB.class_get_property_list(anc, true):
			var pname := String(p.get("name", ""))
			if pname.to_lower() != needle or int(p.get("usage", 0)) & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
				continue
			out.append(_property_detail(cls, anc, pname, p))
		for s in ClassDB.class_get_signal_list(anc, true):
			if String(s.get("name", "")).to_lower() == needle:
				out.append("Signal (declared in %s): %s" % [anc, _signal_signature(s)])
		for e in ClassDB.class_get_enum_list(anc, true):
			var ename := String(e)
			if ename.to_lower() == needle:
				out.append("Enum (declared in %s): %s" % [anc, _enum_line(anc, ename, ClassDB.class_get_enum_constants(anc, ename, true))])
		for c in ClassDB.class_get_integer_constant_list(anc, true):
			var cname := String(c)
			if cname.to_lower() == needle:
				out.append(_constant_detail(anc, cname))
		anc = ClassDB.get_parent_class(anc)
	return out


## A property finding: "name: Type" plus its default value and setter/getter method names when the engine exposes them. The default is read off `cls` (not the declaring ancestor) so a subclass-overridden default reports what the queried class actually gets.
static func _property_detail(cls: String, anc: String, pname: String, p: Dictionary) -> String:
	var lines: Array = ["Property (declared in %s): %s: %s" % [anc, pname, _type_label(p)]]
	var default: Variant = ClassDB.class_get_property_default_value(cls, pname)
	lines.append("  default: %s" % _format_default(default))
	var setter := String(ClassDB.class_get_property_setter(cls, pname))
	var getter := String(ClassDB.class_get_property_getter(cls, pname))
	if setter != "" or getter != "":
		var access: Array[String] = []
		if setter != "":
			access.append("setter %s" % setter)
		if getter != "":
			access.append("getter %s" % getter)
		lines.append("  %s" % ", ".join(access))
	return "\n".join(lines)


## A constant finding: "NAME = value", noting the enum it belongs to when it isn't a plain constant.
static func _constant_detail(anc: String, cname: String) -> String:
	var line := "Constant (declared in %s): %s = %d" % [anc, cname, ClassDB.class_get_integer_constant(anc, cname)]
	var owner := String(ClassDB.class_get_integer_constant_enum(anc, cname, true))
	if owner != "":
		line += " (member of enum %s)" % owner
	return line


## Error text for a member that doesn't resolve, with near-miss suggestions gathered from the class's full inherited member set — names that contain the request or that the request contains — so a partial or misremembered name can be corrected; falls back to pointing at describe_class's filter for browsing.
static func _unknown_member_message(cls: String, member: String) -> String:
	var needle := member.to_lower()
	var suggestions: Array[String] = []
	for n in _all_member_names(cls):
		var lowered := n.to_lower()
		# The reverse containment needs a minimum length, or a needle like "get_pos" would drag in "get".
		if (lowered.contains(needle) or (lowered.length() >= 4 and needle.contains(lowered))) and not suggestions.has(n):
			suggestions.append(n)
	var msg := "No member named \"%s\" on %s (methods, properties, signals, enums, and constants were searched, including inherited)." % [member, cls]
	var theme_note := _theme_item_note(cls, member)
	if theme_note != "":
		msg += " " + theme_note
	if suggestions.is_empty():
		if theme_note == "":
			msg += " Call describe_class with a `filter` substring to browse the class's API."
		return msg
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]


## A pointer added when a member or filter lookup on a Control-derived class finds nothing: theme items live in ThemeDB, not ClassDB, and transcripts show a model told "no members" for one (RichTextLabel's default_color) abandoning engine truth for a project grep. Names the exact theme_override_* property when the name IS a theme item, else a generic reminder that theme items exist; "" for non-Control classes.
static func _theme_item_note(cls: String, name: String) -> String:
	if not ClassDB.is_parent_class(cls, "Control"):
		return ""
	var kind := _theme_item_kind(cls, name)
	if kind == "":
		return "Control-derived classes also have theme items (colors, fonts, styleboxes) that are not ClassDB properties; they are set through theme_override_… properties."
	return "\"%s\" is a THEME ITEM (%s) on %s, not a ClassDB property — set it through the \"%s/%s\" property, or a Theme resource." % [name, kind, cls, THEME_OVERRIDE_NAMESPACES[kind], name]


## The theme-item kind ("color", "font", …) `name` has on `cls` in the default theme, or "". The class chain is walked because theme items register under each declaring class's own type name (RichTextLabel's default_color under "RichTextLabel", inherited ones under an ancestor). The list getters are deliberate — has_font/has_font_size answer true for ANY name once the theme has a default font, which the default theme does.
static func _theme_item_kind(cls: String, name: String) -> String:
	var theme := ThemeDB.get_default_theme()
	if theme == null:
		return ""
	var anc := cls
	while anc != "":
		if theme.get_color_list(anc).has(name):
			return "color"
		if theme.get_font_list(anc).has(name):
			return "font"
		if theme.get_font_size_list(anc).has(name):
			return "font_size"
		if theme.get_stylebox_list(anc).has(name):
			return "stylebox"
		if theme.get_constant_list(anc).has(name):
			return "constant"
		if theme.get_icon_list(anc).has(name):
			return "icon"
		anc = ClassDB.get_parent_class(anc)
	return ""


## Every member name of a class including inherited, across all kinds, for near-miss suggestions. Duplicates are fine — the caller dedupes.
static func _all_member_names(cls: String) -> Array[String]:
	var names: Array[String] = []
	for m in ClassDB.class_get_method_list(cls, false):
		names.append(String(m.get("name", "")))
	for p in ClassDB.class_get_property_list(cls, false):
		if not (int(p.get("usage", 0)) & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY)):
			names.append(String(p.get("name", "")))
	for s in ClassDB.class_get_signal_list(cls, false):
		names.append(String(s.get("name", "")))
	for e in ClassDB.class_get_enum_list(cls, false):
		names.append(String(e))
	for c in ClassDB.class_get_integer_constant_list(cls, false):
		names.append(String(c))
	return names


## A readable type name from a ClassDB argument/return/property info dict: its object class when one is named, "Variant" for an untyped (nil-is-variant) slot, "void" for a nil return, otherwise the Variant type's name.
static func _type_label(info: Dictionary) -> String:
	var cls := String(info.get("class_name", ""))
	if cls != "":
		return cls
	var t := int(info.get("type", TYPE_NIL))
	if t == TYPE_NIL:
		return "Variant" if int(info.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT else "void"
	return type_string(t)


## A default argument value rendered for a signature: strings quoted, null spelled out, everything else via str() (so 0, true, Vector2(0, 0), and so on read naturally).
static func _format_default(value: Variant) -> String:
	if value == null:
		return "null"
	if value is String:
		return "\"%s\"" % value
	if value is bool:
		return "true" if value else "false"
	return str(value)


## Render one describe_class section, sorted by name and headed with its count. A section longer than GDLLMTunables.CLASS_MEMBERS_PER_SECTION is truncated with a note pointing the model at `filter`, keeping a huge base class from flooding the context; an empty section is a single "Title: none" line.
static func _format_class_section(title: String, items: Array) -> String:
	if items.is_empty():
		return "%s: none" % title
	items.sort()
	var total := items.size()
	var shown: Array = items
	var note := ""
	if total > GDLLMTunables.geti(GDLLMTunables.CLASS_MEMBERS_PER_SECTION):
		shown = items.slice(0, GDLLMTunables.geti(GDLLMTunables.CLASS_MEMBERS_PER_SECTION))
		note = " (%d of %d shown — pass a `filter` substring to narrow)" % [GDLLMTunables.geti(GDLLMTunables.CLASS_MEMBERS_PER_SECTION), total]
	var lines: Array = ["%s (%d)%s:" % [title, total, note]]
	for it in shown:
		lines.append("  " + String(it))
	return "\n".join(lines)


## Render the live node tree (or one node's detail) of a scene open in the editor — what the user is looking at right now, unsaved edits included; the live counterpart to _describe_scene_file's disk view.
static func _describe_scene(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, SCENE_SELECT_KEYS + NODE_PATH_KEYS + DEPTH_KEYS + SCENE_FILTER_KEYS, DESCRIBE_SCENE_USAGE)
	if arg_error != "":
		return arg_error
	if not Engine.is_editor_hint():
		return "Error: the editor isn't available in this run, so no live scene can be inspected. Use describe_scene_file to inspect a saved scene file instead."
	var roots := EditorInterface.get_open_scene_roots()
	var selector := _arg_string(args, SCENE_SELECT_KEYS)
	var root: Node = null
	if selector == "":
		root = EditorInterface.get_edited_scene_root()
		if root == null:
			return "Error: no scene is open in the editor. Use describe_scene_file to inspect a saved scene file instead."
	else:
		root = _resolve_open_scene(selector, roots)
		if root == null:
			return "Error: no open scene matches \"%s\". Open scenes: %s. Use describe_scene_file for a scene that isn't open." % [selector, _open_scene_list(roots)]
	var node_path := _arg_string(args, NODE_PATH_KEYS)
	var filter := _arg_string(args, SCENE_FILTER_KEYS)
	if node_path != "":
		return _live_node_detail(root, node_path, filter)
	if filter != "":
		return "Error: \"filter\" narrows one node's detail, so it needs \"node_path\" too — pass the node to inspect (\".\" is the root)."
	var lines: Array = []
	lines.append("Live scene tree of %s — the editor's current state, including unsaved edits (describe_scene_file shows what is saved on disk)." % _scene_label(root))
	if roots.size() > 1:
		var others: Array[String] = []
		for r in roots:
			if r != root:
				others.append(_scene_label(r))
		lines.append("Other open scenes: %s — pass one as `scene` to inspect it." % ", ".join(others))
	lines.append("")
	var budget := {"left": GDLLMTunables.geti(GDLLMTunables.SCENE_TREE_MAX_NODES), "hidden": 0}
	_live_tree_lines(root, root, 0, _arg_int(args, DEPTH_KEYS, 0), budget, lines)
	if int(budget["hidden"]) > 0:
		lines.append("")
		lines.append("… %d node(s) not shown — pass `node_path` to inspect one node, or `depth` to control how deep the tree goes." % int(budget["hidden"]))
	return "\n".join(lines)


## How a scene is named in headers and open-scene lists: its saved path when it has one, honestly labeled unsaved otherwise, always carrying the root name a `scene` selector can match.
static func _scene_label(root: Node) -> String:
	if root.scene_file_path == "":
		return "an unsaved scene (root \"%s\")" % root.name
	return "%s (root \"%s\")" % [root.scene_file_path, root.name]


static func _open_scene_list(roots: Array[Node]) -> String:
	var labels: Array[String] = []
	for r in roots:
		labels.append(_scene_label(r))
	return "none" if labels.is_empty() else ", ".join(labels)


## The open scene root matching `selector` case-insensitively — by full scene_file_path, its bare file name (with or without extension), or the root node's name — or null when nothing matches.
static func _resolve_open_scene(selector: String, roots: Array[Node]) -> Node:
	var needle := selector.strip_edges().to_lower()
	for root in roots:
		var path := root.scene_file_path.to_lower()
		if needle in [path, path.get_file(), path.get_file().get_basename(), String(root.name).to_lower()]:
			return root
	return null


## DFS render of a live tree into `out`, one indented label per node, under a shared node budget and optional depth cap. An instanced child scene doesn't recurse unless the user marked it editable — mirroring the Scene dock, so the model sees the same tree the user does.
static func _live_tree_lines(node: Node, root: Node, depth: int, depth_cap: int, budget: Dictionary, out: Array) -> void:
	if int(budget["left"]) <= 0:
		budget["hidden"] = int(budget["hidden"]) + _count_tree(node)
		return
	budget["left"] = int(budget["left"]) - 1
	var label := "  ".repeat(depth) + _live_node_label(node, root)
	var descendants := _count_tree(node) - 1
	var collapsed := node != root and node.scene_file_path != "" and not root.is_editable_instance(node)
	if collapsed:
		if descendants > 0:
			label += " — %d node(s) inside (describe_scene_file the instanced scene to see them)" % descendants
	elif depth_cap > 0 and depth >= depth_cap and descendants > 0:
		label += " — %d node(s) below the depth limit" % descendants
		collapsed = true
	out.append(label)
	if collapsed:
		return
	for child in node.get_children():
		_live_tree_lines(child, root, depth + 1, depth_cap, budget, out)


## Node count of a live subtree including its root, so collapsed-subtree annotations carry exact counts.
static func _count_tree(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_tree(child)
	return count


## One tree line for a live node: name, class, script and instanced-scene markers. `(editable)` flags an instance whose children the user exposed, so the model knows why it expands.
static func _live_node_label(node: Node, root: Node) -> String:
	var label := "%s (%s)" % [node.name, _node_class_label(node)]
	var script: Script = node.get_script()
	if script != null and script.resource_path != "":
		label += " [script: %s]" % script.resource_path
	if node != root and node.scene_file_path != "":
		label += " [instance: %s]" % node.scene_file_path
		if root.is_editable_instance(node):
			label += " (editable)"
	elif node != root and node.owner != null and node.owner != root and node.owner.scene_file_path != "":
		# A node INSIDE an instanced sub-scene (reachable once Editable Children is on) is declared by that sub-scene's file, not by this one — without saying so, an edit aimed at what is on screen would be made in the wrong file.
		label += " [declared in %s]" % node.owner.scene_file_path
	if node.get_scene_instance_load_placeholder():
		label += " (placeholder)"
	return label


## The class shown for a live node: the attached script's class_name when it declares one (the name the project's own code knows it by), else the engine class.
static func _node_class_label(node: Node) -> String:
	var script: Script = node.get_script()
	if script != null and String(script.get_global_name()) != "":
		return String(script.get_global_name())
	return node.get_class()


## One live node's detail — non-default properties, persisted signal connections, groups — the node_path drill-down, like describe_member is to describe_class.
static func _live_node_detail(root: Node, raw_path: String, filter := "") -> String:
	var node := _resolve_live_node(root, raw_path)
	if node == null:
		return _unknown_node_message(root, raw_path)
	var shown_path := "." if node == root else String(root.get_path_to(node))
	var lines: Array = []
	lines.append("Live state of \"%s\" in %s — the editor's current values, including unsaved edits." % [shown_path, _scene_label(root)])
	lines.append("")
	lines.append("Node: %s" % _live_node_label(node, root))
	var groups := _visible_groups(node)
	if not groups.is_empty():
		lines.append("Groups: %s" % ", ".join(groups))
	lines.append("")
	lines.append(_format_capped_section("Non-default properties", _live_property_lines(node, filter != ""), GDLLMTunables.geti(GDLLMTunables.SCENE_NODE_MAX_PROPERTIES), filter))
	lines.append("")
	var runtime := {"count": 0}
	lines.append(_format_capped_section("Signal connections (persisted)", _live_connection_lines(node, root, runtime), GDLLMTunables.geti(GDLLMTunables.SCENE_NODE_MAX_CONNECTIONS), filter))
	if int(runtime["count"]) > 0:
		lines.append("(+%d runtime, non-persisted connection(s) not shown — mostly editor wiring.)" % int(runtime["count"]))
	return "\n".join(lines)


## The live node named by a model-supplied path, tolerant of decorated forms: ".", the root's own name, and "./", "/root/", "RootName/" prefixes all resolve, since models paste back paths from earlier results in varied shapes.
static func _resolve_live_node(root: Node, raw_path: String) -> Node:
	var clean := raw_path.strip_edges().trim_prefix("./").trim_prefix("/root/")
	var root_name := String(root.name).to_lower()
	if clean == "" or clean == "." or clean.to_lower() == root_name:
		return root
	if clean.to_lower().begins_with(root_name + "/"):
		clean = clean.substr(root_name.length() + 1)
	return root.get_node_or_null(NodePath(clean))


## Error text for a live node path that doesn't resolve, suggesting paths whose node name matches the request's last segment — the describe_member near-miss convention. Names the scene that was actually searched and points at the `scene` argument when other scenes are open: transcripts show a model failing the same path three times because the error never said WHICH scene it was looking in.
static func _unknown_node_message(root: Node, raw_path: String) -> String:
	var needle := raw_path.strip_edges().get_file().to_lower()
	var suggestions: Array[String] = []
	_collect_node_path_matches(root, root, needle, suggestions)
	var msg := "Error: no node at \"%s\" in %s.%s" % [raw_path, _scene_label(root), _other_open_scenes_hint(root)]
	if suggestions.is_empty():
		return msg + " Call describe_scene without node_path to see the tree and its paths."
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]


## The coaching appended when a node lookup misses and OTHER scenes are open in the editor: only one scene is ever searched, so name the escape hatch — the `scene` argument — and what it could point at. "" headlessly or when nothing else is open.
static func _other_open_scenes_hint(root: Node) -> String:
	if not Engine.is_editor_hint():
		return ""
	var others: Array[String] = []
	for r in EditorInterface.get_open_scene_roots():
		if r != root:
			others.append(_scene_label(r))
	if others.is_empty():
		return ""
	return " Only this scene was searched — pass `scene` to target another open scene: %s." % ", ".join(others)


static func _collect_node_path_matches(node: Node, root: Node, needle: String, out: Array[String]) -> void:
	if _node_name_near_miss(String(node.name), needle):
		out.append("." if node == root else String(root.get_path_to(node)))
	for child in node.get_children():
		_collect_node_path_matches(child, root, needle, out)


## The describe_member near-miss rule applied to node names: either contains the other, with a minimum length on the reverse so a long request doesn't drag in every short name.
static func _node_name_near_miss(node_name: String, needle: String) -> bool:
	var lowered := node_name.to_lower()
	return lowered.contains(needle) or (lowered.length() >= 4 and needle.contains(lowered))


## The node's group names minus the "_"-prefixed ones the editor uses internally.
static func _visible_groups(node: Node) -> Array[String]:
	var out: Array[String] = []
	for g in node.get_groups():
		if not String(g).begins_with("_"):
			out.append(String(g))
	return out


## A live node's stored properties whose value differs from its class/script default — the same diff the scene packer makes when saving, so it reads as "what would be saved" while also catching unsaved live edits, and a stock node stays a couple of lines. For a node inside an instanced scene this diffs against class defaults, not the instance's saved values, so instance-inherited edits show too.
static func _live_property_lines(node: Node, whole := false) -> Array:
	var out: Array = []
	var script: Script = node.get_script()
	for p in node.get_property_list():
		var pname := String(p.get("name", ""))
		var usage := int(p.get("usage", 0))
		if pname == "" or pname == "script" or not (usage & PROPERTY_USAGE_STORAGE):
			continue
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		# A script default of null falls through to the ClassDB lookup; a null-defaulted script export compares right anyway.
		var default: Variant = script.get_property_default_value(pname) if script != null else null
		if default == null:
			default = ClassDB.class_get_property_default_value(node.get_class(), pname)
		if _values_equal(node.get(pname), default):
			continue
		out.append("%s = %s" % [pname, _format_property_value(node.get(pname), whole)])
	return out


## Variant equality that never trips GDScript's invalid-operands error on mismatched types: different types compare unequal, except the int/float pair which should still count as the same value.
static func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		if (a is int or a is float) and (b is int or b is float):
			return float(a) == float(b)
		return false
	return a == b


## A live node's persisted signal connections — outgoing then incoming — one line each; runtime (non-persisted) ones are only counted into `runtime`, since the editor itself wires plenty of those and they'd bury the user-authored few.
static func _live_connection_lines(node: Node, root: Node, runtime: Dictionary) -> Array:
	var out: Array = []
	for s in node.get_signal_list():
		var sname := String(s.get("name", ""))
		for conn in node.get_signal_connection_list(sname):
			var flags := int(conn.get("flags", 0))
			if not (flags & CONNECT_PERSIST):
				runtime["count"] = int(runtime["count"]) + 1
				continue
			var callable: Callable = conn.get("callable")
			out.append("%s -> %s.%s%s" % [sname, _node_ref_label(callable.get_object(), root), String(callable.get_method()), _connection_flag_notes(flags)])
	for conn in node.get_incoming_connections():
		var sig: Signal = conn.get("signal")
		# A self-connection is already listed as outgoing.
		if sig.get_object() == node:
			continue
		var flags := int(conn.get("flags", 0))
		if not (flags & CONNECT_PERSIST):
			runtime["count"] = int(runtime["count"]) + 1
			continue
		var callable: Callable = conn.get("callable")
		out.append("%s.%s -> this.%s%s" % [_node_ref_label(sig.get_object(), root), String(sig.get_name()), String(callable.get_method()), _connection_flag_notes(flags)])
	return out


## How a connection's other endpoint is named: its path relative to the scene root when it lives in this scene, else its own name or class — good enough for the rare external target.
static func _node_ref_label(obj: Object, root: Node) -> String:
	if obj == null:
		return "<freed>"
	if obj is Node:
		var n := obj as Node
		if n == root:
			return "."
		if root.is_ancestor_of(n):
			return String(root.get_path_to(n))
		return String(n.name)
	return obj.get_class()


## " [deferred, one_shot]"-style annotation for connection flags; persistence itself isn't noted since the callers only render persisted connections.
static func _connection_flag_notes(flags: int) -> String:
	var notes: Array[String] = []
	if flags & CONNECT_DEFERRED:
		notes.append("deferred")
	if flags & CONNECT_ONE_SHOT:
		notes.append("one_shot")
	return "" if notes.is_empty() else " [%s]" % ", ".join(notes)


## Render the saved node tree (or one node's saved detail) of a .tscn/.scn straight from its packed SceneState — the engine's own parse of the file, with nothing instantiated so no script code runs; the disk counterpart to _describe_scene's live view.
static func _describe_scene_file(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, FILE_PATH_KEYS + NODE_PATH_KEYS + DEPTH_KEYS + SCENE_FILTER_KEYS, DESCRIBE_SCENE_FILE_USAGE)
	if arg_error != "":
		return arg_error
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + DESCRIBE_SCENE_FILE_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	# The extension whitelist keeps this from loading arbitrary resources at all.
	if not resolved.get_extension().to_lower() in ["tscn", "scn", "res"]:
		return "Error: %s is not a scene file (.tscn/.scn). Use read_file for other files." % resolved
	# Loading a PackedScene pulls in its ext-resources (scripts compile) but instantiates nothing, so no _init/_ready/@tool code runs; CACHE_MODE_IGNORE keeps it out of the resource cache.
	var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not packed is PackedScene:
		return "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]
	var state := (packed as PackedScene).get_state()
	if state.get_node_count() == 0:
		return "Error: %s contains no nodes." % resolved
	var node_path := _arg_string(args, NODE_PATH_KEYS)
	var filter := _arg_string(args, SCENE_FILTER_KEYS)
	if node_path != "":
		return _scene_divergence_note(resolved) + _scene_state_node_detail(state, resolved, node_path, filter)
	if filter != "":
		return "Error: \"filter\" narrows one node's detail, so it needs \"node_path\" too — pass the node to inspect (\".\" is the root)."
	return _scene_divergence_note(resolved) + _scene_state_tree(state, resolved, _arg_int(args, DEPTH_KEYS, 0))


## The packed tree as indented lines: SceneState stores nodes depth-first with parents first, so index order IS pre-order and depth falls out of the stored path's segment count.
static func _scene_state_tree(state: SceneState, resolved: String, depth_cap: int) -> String:
	var lines: Array = []
	lines.append("Saved scene tree of %s — as stored on disk; an open editor tab may have unsaved changes (use describe_scene for the live state)." % resolved)
	if _scene_state_has_instances(state):
		lines.append("Instanced sub-scenes are collapsed to their root here — call describe_scene_file on the instanced .tscn to see inside one.")
	lines.append("")
	var shown := 0
	var hidden := 0
	var depth_hidden := 0
	for i in state.get_node_count():
		var depth := _scene_state_depth(state, i)
		if depth_cap > 0 and depth > depth_cap:
			depth_hidden += 1
			continue
		if shown >= GDLLMTunables.geti(GDLLMTunables.SCENE_TREE_MAX_NODES):
			hidden += 1
			continue
		shown += 1
		lines.append("  ".repeat(depth) + _scene_state_node_label(state, i))
	if depth_hidden > 0:
		lines.append("")
		lines.append("… %d node(s) below the depth limit not shown." % depth_hidden)
	if hidden > 0:
		lines.append("")
		lines.append("… %d more node(s) not shown — pass `node_path` for one node, or `depth` to limit how deep the tree goes." % hidden)
	return "\n".join(lines)


static func _scene_state_depth(state: SceneState, i: int) -> int:
	var path := _scene_state_path(state, i)
	return 0 if path == "." else path.count("/") + 1


## A packed node's path in the bare tree-relative form results display and models pass back — SceneState itself reports "./Pic", which would throw off both depth math and path matching.
static func _scene_state_path(state: SceneState, i: int) -> String:
	var path := String(state.get_node_path(i))
	return path if path == "." else path.trim_prefix("./")


static func _scene_state_has_instances(state: SceneState) -> bool:
	for i in range(1, state.get_node_count()):
		if state.get_node_instance(i) != null:
			return true
	return false


## One tree line for a packed node: name plus type, with the stored markers a scene file can carry — instance/inherits sources, placeholders, override entries for nodes living inside an instanced scene, and the attached script.
static func _scene_state_node_label(state: SceneState, i: int) -> String:
	var name := String(state.get_node_name(i))
	var type := String(state.get_node_type(i))
	# An instanced node may carry its type too (this build writes both), so the instance marker can't be the empty-type fallback.
	var label := name if type == "" else "%s (%s)" % [name, type]
	var inst: PackedScene = state.get_node_instance(i)
	if inst != null:
		# Index 0 with an instance is an inherited scene's root, not an instanced child.
		label += " [%s: %s]" % ["inherits" if i == 0 else "instance", inst.resource_path]
	elif state.is_node_instance_placeholder(i):
		label += " [placeholder: %s]" % state.get_node_instance_placeholder(i)
	elif type == "":
		label += " (override entry for a node inside an instanced scene)"
	var script_path := _scene_state_script_path(state, i)
	if script_path != "":
		label += " [script: %s]" % script_path
	return label


static func _scene_state_script_path(state: SceneState, i: int) -> String:
	for j in state.get_node_property_count(i):
		if String(state.get_node_property_name(i, j)) == "script":
			var script: Variant = state.get_node_property_value(i, j)
			return (script as Script).resource_path if script is Script else str(script)
	return ""


## One packed node's saved detail — stored properties, connections, groups. A scene file only stores values that differ from defaults, so the property list IS the node's edits.
static func _scene_state_node_detail(state: SceneState, resolved: String, raw_path: String, filter := "") -> String:
	var index := _scene_state_find_node(state, raw_path)
	if index == -1:
		return _scene_state_unknown_node_message(state, raw_path)
	var node_path := _scene_state_path(state, index)
	var lines: Array = []
	lines.append("Saved state of \"%s\" in %s — a scene file stores only the properties that differ from their defaults, so this list is the node's edits." % [node_path, resolved])
	lines.append("")
	lines.append("Node: %s" % _scene_state_node_label(state, index))
	var groups := state.get_node_groups(index)
	if not groups.is_empty():
		var names: Array[String] = []
		for g in groups:
			names.append(String(g))
		lines.append("Groups: %s" % ", ".join(names))
	lines.append("")
	lines.append(_format_capped_section("Stored properties", _scene_state_property_lines(state, index, filter != ""), GDLLMTunables.geti(GDLLMTunables.SCENE_NODE_MAX_PROPERTIES), filter, ", or read_file this scene file with full: true"))
	lines.append("")
	lines.append(_format_capped_section("Signal connections", _scene_state_connection_lines(state, node_path), GDLLMTunables.geti(GDLLMTunables.SCENE_NODE_MAX_CONNECTIONS), filter, ", or read_file this scene file with full: true"))
	return "\n".join(lines)


## The packed-node index for a model-supplied path, normalized the same way as _resolve_live_node; -1 when nothing matches.
static func _scene_state_find_node(state: SceneState, raw_path: String) -> int:
	var clean := raw_path.strip_edges().trim_prefix("./").trim_prefix("/root/")
	var root_name := String(state.get_node_name(0)).to_lower()
	if clean == "" or clean == "." or clean.to_lower() == root_name:
		return 0
	if clean.to_lower().begins_with(root_name + "/"):
		clean = clean.substr(root_name.length() + 1)
	var lowered := clean.to_lower()
	for i in state.get_node_count():
		if _scene_state_path(state, i).to_lower() == lowered:
			return i
	return -1


## Error text for a stored node path that doesn't resolve, with near-miss suggestions — and the reminder that a scene file simply doesn't store the nodes inside its instanced sub-scenes.
static func _scene_state_unknown_node_message(state: SceneState, raw_path: String) -> String:
	var needle := raw_path.strip_edges().get_file().to_lower()
	var suggestions: Array[String] = []
	for i in state.get_node_count():
		if _node_name_near_miss(String(state.get_node_name(i)), needle):
			suggestions.append(_scene_state_path(state, i))
	var msg := "Error: no node at \"%s\" is stored in this scene file. Nodes inside an instanced sub-scene aren't stored here — inspect the instanced scene file instead." % raw_path
	if suggestions.is_empty():
		return msg
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]


static func _scene_state_property_lines(state: SceneState, index: int, whole := false) -> Array:
	var out: Array = []
	for j in state.get_node_property_count(index):
		var pname := String(state.get_node_property_name(index, j))
		# The script is already on the Node line.
		if pname == "script":
			continue
		out.append("%s = %s" % [pname, _format_property_value(state.get_node_property_value(index, j), whole)])
	return out


## The stored connections touching `node_path` (as source or target), one "source.signal -> target.method" line each with deferred/one_shot/binds annotations.
static func _scene_state_connection_lines(state: SceneState, node_path: String) -> Array:
	var out: Array = []
	for c in state.get_connection_count():
		var source := String(state.get_connection_source(c)).trim_prefix("./")
		var target := String(state.get_connection_target(c)).trim_prefix("./")
		if source != node_path and target != node_path:
			continue
		var line := "%s.%s -> %s.%s" % [source, String(state.get_connection_signal(c)), target, String(state.get_connection_method(c))]
		line += _connection_flag_notes(state.get_connection_flags(c))
		var binds: Array = state.get_connection_binds(c)
		if not binds.is_empty():
			var rendered: Array[String] = []
			for b in binds:
				rendered.append(_format_property_value(b))
			line += " [binds: %s]" % ", ".join(rendered)
		var unbinds := state.get_connection_unbinds(c)
		if unbinds > 0:
			line += " [unbinds: %d]" % unbinds
		out.append(line)
	return out


## The read_editor_selection tool: one snapshot of what the user has focused across the editor's surfaces, gathered and formatted by GDLLMEditorState. Takes no arguments, so any passed are ignored the way stop_game's are.
static func _read_editor_selection() -> String:
	if not Engine.is_editor_hint():
		return "Error: reading the user's selection needs the running editor, and this session is running headless — editor state (selection, open tabs, docks) does not exist here. describe_scene_file can still inspect saved scenes from disk."
	return GDLLMEditorState.format_selection(GDLLMEditorState.gather_selection())


## The read_undo_history tool: the user's recent editor actions by name, read from the editor's own undo histories and never stepping them; the gather/format split lives in GDLLMEditorState.
static func _read_undo_history(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, UNDO_WINDOW_KEYS, READ_UNDO_HISTORY_USAGE)
	if arg_error != "":
		return arg_error
	if not Engine.is_editor_hint():
		return "Error: reading undo history needs the running editor, and this session is running headless — no editor is running, so there are no user actions to read."
	var window := clampi(_arg_int(args, UNDO_WINDOW_KEYS, GDLLMTunables.geti(GDLLMTunables.UNDO_HISTORY_DEFAULT_WINDOW)), 1, GDLLMTunables.geti(GDLLMTunables.UNDO_HISTORY_MAX_WINDOW))
	return GDLLMEditorState.format_undo(GDLLMEditorState.gather_undo(), window)


## The open_for_user tool: hand the user's editor focus to the place the model means — resolution and refusals here, the surface routing shared with the chat log's clickable links (GDLLMLinks.open_in_editor), so a tool hand-off and a link click land identically.
static func _open_for_user(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, FILE_PATH_KEYS + OPEN_LINE_KEYS + OPEN_REVEAL_KEYS, OPEN_FOR_USER_USAGE)
	if arg_error != "":
		return arg_error
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: nothing was opened — no file was named. " + OPEN_FOR_USER_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested) + " Nothing was opened."
	var hidden := _hidden_dir_guard(resolved)
	if hidden != "":
		return hidden
	if not resolved.begins_with("res://"):
		return "Error: nothing was opened — %s is outside the project's res:// tree, and the editor's docks and script editor only show project files." % resolved
	if not Engine.is_editor_hint():
		return "Error: nothing was opened — handing the user focus needs the running editor, and this session is running headless. The path resolves to %s; name it to the user instead." % resolved
	var note := _resolution_note(requested, resolved)
	if _arg_bool(args, OPEN_REVEAL_KEYS):
		EditorInterface.select_file(resolved)
		return note + "%s is now selected in the FileSystem dock; nothing was opened for editing." % resolved
	var line := _arg_int(args, OPEN_LINE_KEYS, 0)
	var where := GDLLMLinks.open_in_editor(resolved, line)
	var ignored := "" if line <= 0 or where.contains("script editor") else " (\"line\" applies only to scripts, so it was ignored)"
	return "%s%s %s%s." % [note, resolved, where, ignored]


## read_tilemap: decode a scene's TileMapLayer content — the live edited scene by default, a saved file when `scene` names one; the walking and composing live in GDLLMTilemap so both modes and the tests share one path.
static func _read_tilemap(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, SCENE_SELECT_KEYS + TILEMAP_LAYER_KEYS + TILEMAP_RECT_KEYS, READ_TILEMAP_USAGE)
	if arg_error != "":
		return arg_error
	var layer_query := _arg_string(args, TILEMAP_LAYER_KEYS)
	var window := _tilemap_window(args)
	if window.has("error"):
		return String(window["error"])
	var requested := _arg_string(args, SCENE_SELECT_KEYS)
	if requested == "":
		if not Engine.is_editor_hint():
			return "Error: reading the live edited scene needs the editor, and this session is running headless — pass \"scene\" with a saved .tscn path instead."
		var root := EditorInterface.get_edited_scene_root()
		if root == null:
			return "Error: no scene is being edited right now — open one in the editor, or pass \"scene\" with a saved .tscn path."
		var live_scan := GDLLMTilemap.layers_from_live(root)
		return GDLLMTilemap.compose_report("Tilemaps in the scene being edited (\"%s\" — LIVE editor state, unsaved edits included)." % root.name, live_scan, layer_query, window.get("rect", Rect2i()), window.has("rect"))
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested, "scene file")
	if not resolved.get_extension().to_lower() in ["tscn", "scn"]:
		return "Error: %s is not a scene file (.tscn/.scn) — this tool reads the TileMapLayer nodes a scene stores. For a TileSet resource, use describe_tileset." % resolved
	# Loading a PackedScene pulls in its ext-resources but instantiates nothing, so no _init/_ready/@tool code runs; CACHE_MODE_IGNORE keeps it out of the resource cache.
	var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not packed is PackedScene:
		return "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]
	var scan := GDLLMTilemap.layers_from_state((packed as PackedScene).get_state())
	return _scene_divergence_note(resolved) + GDLLMTilemap.compose_report("Tilemaps in %s (as saved on disk)." % resolved, scan, layer_query, window.get("rect", Rect2i()), window.has("rect"))


## Parse the optional grid window through the shared rect grammar — a window the model believes took effect but never parsed is worse than an error.
static func _tilemap_window(args: Dictionary) -> Dictionary:
	for key in TILEMAP_RECT_KEYS:
		if args.has(key):
			return GDLLMTilemap.parse_rect(args[key])
	return {}


## describe_tileset: the legend for read_tilemap's source ids — a TileSet .tres directly, or a .tscn route for the embedded case, with `kind`/`filter` narrowing on the same two axes describe_class established.
static func _describe_tileset(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, FILE_PATH_KEYS + TILESET_KIND_KEYS + TILESET_FILTER_KEYS + TILEMAP_LAYER_KEYS, DESCRIBE_TILESET_USAGE)
	if arg_error != "":
		return arg_error
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + DESCRIBE_TILESET_USAGE
	var kinds := GDLLMTilemap.normalize_kinds(_tileset_kind_args(args))
	if kinds.has("error"):
		return String(kinds["error"])
	var filter := _arg_string(args, TILESET_FILTER_KEYS)
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var ext := resolved.get_extension().to_lower()
	if ext in ["tscn", "scn"]:
		return _describe_tileset_from_scene(resolved, _arg_string(args, TILEMAP_LAYER_KEYS), filter, kinds["kinds"])
	if not ext in ["tres", "res"]:
		return "Error: %s is not a resource or scene file — describe_tileset takes a TileSet .tres/.res, or a .tscn whose TileMapLayers use one." % resolved
	var resource: Resource = ResourceLoader.load(resolved, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null:
		return "Error: %s could not be loaded — %s" % [resolved, _resource_load_cause(resolved)]
	if not resource is TileSet:
		return "Error: %s is a %s, not a TileSet. read_tilemap names each layer's TileSet; describe_scene_file shows a scene's structure." % [resolved, resource.get_class()]
	return GDLLMTilemap.describe(resource as TileSet, resolved, filter, kinds["kinds"])


## The `kind` argument's raw strings, split on commas/whitespace so "sources, terrains" and ["sources", "terrains"] read the same.
static func _tileset_kind_args(args: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for entry in _arg_string_array(args, TILESET_KIND_KEYS):
		for piece in entry.replace(",", " ").split(" ", false):
			out.append(piece)
	return out


## The .tscn route into describe_tileset — the only path to a TileSet embedded in the scene file, and the recovery when only the scene is known; a scene using several distinct TileSets asks for a `layer` rather than describing an arbitrary one.
static func _describe_tileset_from_scene(resolved: String, layer_query: String, filter: String, kinds: PackedStringArray) -> String:
	var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not packed is PackedScene:
		return "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]
	var scan := GDLLMTilemap.layers_from_state((packed as PackedScene).get_state())
	var layers: Array = scan["layers"]
	var carrying: Array = layers.filter(func(r: Dictionary) -> bool: return r["tile_set"] != null)
	if carrying.is_empty():
		if layers.is_empty():
			return "Error: %s has no TileMapLayer nodes, so there is no TileSet to describe here. Pass a TileSet .tres path directly, or use describe_scene_file to see the scene's structure." % resolved
		return "Error: none of the %d TileMapLayer node(s) in %s has a TileSet assigned — nothing to describe." % [layers.size(), resolved]
	if layer_query != "":
		var matched: Dictionary = GDLLMTilemap.match_layer(carrying, layer_query)
		if matched.has("error"):
			return String(matched["error"])
		carrying = [matched["layer"]]
	var distinct: Array = []
	for record: Dictionary in carrying:
		var known := false
		for entry: Dictionary in distinct:
			if _same_tileset(entry["tile_set"], record["tile_set"]):
				(entry["layers"] as Array).append(String(record["path"]))
				known = true
				break
		if not known:
			distinct.append({"tile_set": record["tile_set"], "layers": [String(record["path"])]})
	if distinct.size() > 1:
		var pairs := PackedStringArray()
		for entry: Dictionary in distinct:
			pairs.append("%s → %s" % [", ".join(PackedStringArray(entry["layers"])), GDLLMTilemap.tileset_label(entry["tile_set"])])
		return "Error: the layers of %s use %d distinct TileSets — pass \"layer\" to pick one: %s." % [resolved, distinct.size(), "; ".join(pairs)]
	var chosen: Dictionary = distinct[0]
	var tile_set := chosen["tile_set"] as TileSet
	var origin := ""
	if tile_set.resource_path != "" and not tile_set.resource_path.contains("::"):
		origin = "%s (used by %s in %s — describable directly via that .tres path too)" % [tile_set.resource_path, ", ".join(PackedStringArray(chosen["layers"])), resolved]
	else:
		origin = "embedded in %s (used by %s)" % [resolved, ", ".join(PackedStringArray(chosen["layers"]))]
	# A disk view of a scene open with unsaved edits must say so, like every other disk-scene reader (read_tilemap's disk branch included).
	return _scene_divergence_note(resolved) + GDLLMTilemap.describe(tile_set, origin, filter, kinds)


## Whether two layer records carry the same TileSet — by file identity when saved, by instance when embedded.
static func _same_tileset(a: Variant, b: Variant) -> bool:
	if a == b:
		return true
	if a is TileSet and b is TileSet:
		var path_a := (a as TileSet).resource_path
		return path_a != "" and not path_a.contains("::") and path_a == (b as TileSet).resource_path
	return false


## edit_tilemap: change a layer's tiles through the engine's own encoder and splice the one data line back into the .tscn — the write half of the tilemap tools, riding edit_file's writer, validator, and open-scene reload.
static func _edit_tilemap(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, SCENE_SELECT_KEYS + TILEMAP_LAYER_KEYS + Array(GDLLMTilemap.EDIT_ACTION_KEYS), EDIT_TILEMAP_USAGE)
	if arg_error != "":
		return arg_error
	var requested := _arg_string(args, SCENE_SELECT_KEYS)
	if requested == "":
		return "Error: no scene was given. " + EDIT_TILEMAP_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested, "scene file")
	var ext := resolved.get_extension().to_lower()
	if ext == "scn":
		return "Error: %s is a binary .scn, whose text cannot be spliced — only .tscn scenes can be tile-edited." % resolved
	if ext != "tscn":
		return "Error: %s is not a .tscn scene file — this tool edits the TileMapLayer data a scene stores." % resolved
	var present := PackedStringArray()
	for key in GDLLMTilemap.EDIT_ACTION_KEYS:
		if args.has(key):
			present.append(key)
	if present.is_empty():
		return "Error: no action was given — pass exactly one of cells, fill, replace, erase, or terrain. " + EDIT_TILEMAP_USAGE
	if present.size() > 1:
		return "Error: one action per call — got %s. Split them into separate edit_tilemap calls." % ", ".join(present)
	var layer_query := _arg_string(args, TILEMAP_LAYER_KEYS)
	if layer_query == "":
		return "Error: no layer was given — read_tilemap lists a scene's layers. " + EDIT_TILEMAP_USAGE
	var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not packed is PackedScene:
		return "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]
	var matched: Dictionary = GDLLMTilemap.match_layer(GDLLMTilemap.layers_from_state((packed as PackedScene).get_state())["layers"], layer_query)
	if matched.has("error"):
		return String(matched["error"])
	var record: Dictionary = matched["layer"]
	var action := present[0]
	var normalized := _edit_tilemap_spec(action, args[action], record)
	if normalized.has("error"):
		return String(normalized["error"]) + " Nothing was written."
	var diff: Dictionary = GDLLMTilemap.apply_edit(record, action, normalized["spec"])
	var text := FileAccess.get_file_as_string(resolved)
	var b64 := "" if (diff["payload"] as PackedByteArray).is_empty() else Marshalls.raw_to_base64(diff["payload"])
	var spliced: Dictionary = GDLLMTilemap.splice(text, String(record["path"]), b64)
	if spliced.has("error"):
		return String(spliced["error"]) + " Nothing was written."
	var report := GDLLMTilemap.compose_edit_report(resolved, record, String(normalized["line"]), diff, normalized["notes"])
	if String(spliced["text"]) == text:
		return report + "\n\nNothing on disk changed, so the file was not rewritten."
	await _acquire_mutation_lock()
	if not _edit_file_write(resolved, String(spliced["text"])):
		_mutation_busy = false
		return "Error: %s could not be written — is it read-only or locked by another program? Nothing was changed." % resolved
	var res_check: Dictionary = await _edit_file_validate_resource(resolved, text, String(spliced["text"]))
	_mutation_busy = false
	_edit_file_refresh_editor(resolved)
	if bool(res_check["restore_failed"]):
		return "Error: the edit could NOT be kept on disk — validation temporarily swaps the pre-edit content onto the file, and writing the edited content back failed twice, so %s holds the PRE-EDIT content and this edit is NOT saved. Re-run the same edit_tilemap call once the file is writable, and tell the user the file briefly reverted." % resolved
	var verdict := ""
	if not bool(res_check["checked"]):
		verdict = "\n\nThe engine validation run %s, so the write is UNVALIDATED — nothing is known about whether the scene still loads; tell the user this edit went unvalidated." % String(res_check["why"])
	elif not (res_check["new_load"] as Array).is_empty():
		# The spliced text is machine-generated, so a load break here is this tool's defect, not the caller's pasted text — blame accordingly.
		verdict = "\n\nWARNING: the scene no longer loads after this write (%s) — this splice is machine-generated, so that is a tool defect, not your input: restore the scene from version control and report the bug to the user rather than hand-editing the file." % ", ".join(PackedStringArray(res_check["new_load"]))
	return report + verdict + _edit_file_reload_open_scene(resolved)


## Normalize one action's raw argument into the spec apply_edit runs, the action line the report opens with, and the disclosure notes it earned — every refusal names its per-entry ordinal so a batch mistake is findable.
static func _edit_tilemap_spec(action: String, raw: Variant, record: Dictionary) -> Dictionary:
	var names: Dictionary = GDLLMTilemap.source_names(record["tile_set"])
	var notes := PackedStringArray()
	# Raw source writes into a terrain-bearing TileSet silently skip edge matching, so the bypass is disclosed wherever it applies.
	if action in ["cells", "fill", "replace"] and record["tile_set"] is TileSet and (record["tile_set"] as TileSet).get_terrain_sets_count() > 0:
		notes.append("this TileSet has terrain sets — raw source writes bypass terrain matching; the terrain action picks edge-matched tiles.")
	match action:
		"cells":
			var entries: Array = raw if raw is Array else [raw]
			if entries.is_empty():
				return {"error": "Error: \"cells\" is empty — pass [{\"at\": [x, y], \"source\": ...}, ...]."}
			if entries.size() > GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_SET_CELLS):
				return {"error": "Error: %d cells in one call is past the %d-cell cap — use fill for a rect, replace for a source swap, or split the batch." % [entries.size(), GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_SET_CELLS)]}
			var cells: Array = []
			for i in entries.size():
				if not entries[i] is Dictionary:
					return {"error": "Error: cells[%d] is not an object — each entry is {\"at\": [x, y], \"source\": ..., \"atlas\"?, \"alt\"?}." % i}
				var entry: Dictionary = entries[i]
				var at: Dictionary = GDLLMTilemap.parse_cell(entry.get("at"), "cells[%d].at" % i)
				if at.has("error"):
					return at
				var source: Dictionary = GDLLMTilemap.resolve_source(record["tile_set"], entry.get("source"), names)
				if source.has("error"):
					return {"error": "cells[%d]: %s" % [i, source["error"]]}
				var atlas: Dictionary = GDLLMTilemap.resolve_atlas(record["tile_set"], int(source["id"]), entry.get("atlas"), names, record["data"])
				if atlas.has("error"):
					return {"error": "cells[%d]: %s" % [i, atlas["error"]]}
				_note_once(notes, String(source.get("note", "")))
				_note_once(notes, String(atlas.get("note", "")))
				cells.append({"at": at["cell"], "source": int(source["id"]), "atlas": atlas["atlas"], "alt": int(entry.get("alt", 0))})
			return {"spec": {"cells": cells}, "line": "set %d cell(s)" % cells.size(), "notes": notes}
		"fill":
			if not raw is Dictionary:
				return {"error": "Error: \"fill\" takes {\"rect\": [x, y, w, h], \"source\": ...}."}
			var rect: Dictionary = GDLLMTilemap.parse_rect((raw as Dictionary).get("rect"))
			if rect.has("error"):
				return rect
			if (rect["rect"] as Rect2i).get_area() > GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_FILL_AREA):
				return {"error": "Error: the fill rect covers %d cells, past the %d-cell cap — split it into smaller rects." % [(rect["rect"] as Rect2i).get_area(), GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_FILL_AREA)]}
			var source: Dictionary = GDLLMTilemap.resolve_source(record["tile_set"], (raw as Dictionary).get("source"), names)
			if source.has("error"):
				return source
			var atlas: Dictionary = GDLLMTilemap.resolve_atlas(record["tile_set"], int(source["id"]), (raw as Dictionary).get("atlas"), names, record["data"])
			if atlas.has("error"):
				return atlas
			_note_once(notes, String(source.get("note", "")))
			_note_once(notes, String(atlas.get("note", "")))
			var spec := {"rect": rect["rect"], "source": int(source["id"]), "atlas": atlas["atlas"], "alt": int((raw as Dictionary).get("alt", 0))}
			return {"spec": spec, "line": "fill %s with %s" % [GDLLMTilemap._rect_span(rect["rect"]), GDLLMTilemap.source_label(int(source["id"]), names)], "notes": notes}
		"replace":
			if not raw is Dictionary:
				return {"error": "Error: \"replace\" takes {\"from\": source, \"to\": source, \"rect\"?}."}
			var from: Dictionary = GDLLMTilemap.resolve_source(record["tile_set"], (raw as Dictionary).get("from"), names)
			if from.has("error"):
				return {"error": "replace.from: %s" % from["error"]}
			var to: Dictionary = GDLLMTilemap.resolve_source(record["tile_set"], (raw as Dictionary).get("to"), names)
			if to.has("error"):
				return {"error": "replace.to: %s" % to["error"]}
			if int(from["id"]) == int(to["id"]):
				return {"error": "Error: replace.from and replace.to are both %s — nothing to replace." % GDLLMTilemap.source_label(int(from["id"]), names)}
			var spec := {"from": int(from["id"]), "to": int(to["id"])}
			var scope := ""
			if (raw as Dictionary).has("rect"):
				var rect: Dictionary = GDLLMTilemap.parse_rect((raw as Dictionary).get("rect"))
				if rect.has("error"):
					return rect
				spec["rect"] = rect["rect"]
				scope = " within %s" % GDLLMTilemap._rect_span(rect["rect"])
			var gaps: Dictionary = GDLLMTilemap.replace_atlas_gaps(record, int(spec["from"]), int(spec["to"]), spec.get("rect"))
			if not gaps.is_empty():
				var gap_parts := PackedStringArray()
				for coords: Vector2i in gaps:
					gap_parts.append("%s (%d cell(s))" % [coords, int(gaps[coords])])
				return {"error": "Error: %s has no tiles at the atlas coords the replaced cells carry — %s — so the swap would write tiles the renderer draws as nothing. The sources' atlas layouts differ; place those cells explicitly with \"cells\", choosing each atlas." % [GDLLMTilemap.source_label(int(spec["to"]), names), ", ".join(gap_parts)]}
			_note_once(notes, String(from.get("note", "")))
			_note_once(notes, String(to.get("note", "")))
			_note_once(notes, "replaced cells keep their atlas coords and flips; only the source changes.")
			return {"spec": spec, "line": "replace %s → %s%s" % [GDLLMTilemap.source_label(int(spec["from"]), names), GDLLMTilemap.source_label(int(spec["to"]), names), scope], "notes": notes}
		"erase":
			var spec := {}
			var line := ""
			var body: Dictionary = raw if raw is Dictionary else {"cells": raw} if raw is Array else {}
			# "all" outranks the other shapes: two wild sessions invented ±9999 rects to say "clear the layer", so the strongest stated intent wins any mixed spec.
			if body.get("all", false):
				spec = {"all": true}
				line = "erase every cell in the layer"
			elif body.has("cells"):
				var cells: Array = []
				var raw_cells: Array = body["cells"] if body["cells"] is Array else []
				if raw_cells.size() > GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_SET_CELLS):
					return {"error": "Error: %d cells in one erase is past the %d-cell cap — use a rect or a source instead." % [raw_cells.size(), GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_SET_CELLS)]}
				for i in raw_cells.size():
					var at: Dictionary = GDLLMTilemap.parse_cell(raw_cells[i], "erase.cells[%d]" % i)
					if at.has("error"):
						return at
					cells.append(at["cell"])
				if cells.is_empty():
					return {"error": "Error: \"erase\" takes {\"cells\": [[x, y], ...]}, {\"rect\": [x, y, w, h]}, {\"source\": name-or-id}, or {\"all\": true} to clear the layer."}
				spec = {"cells": cells}
				line = "erase %d cell(s)" % cells.size()
			elif body.has("rect"):
				var rect: Dictionary = GDLLMTilemap.parse_rect(body.get("rect"))
				if rect.has("error"):
					return rect
				if (rect["rect"] as Rect2i).get_area() > GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_FILL_AREA):
					# A giant rect is nearly always "clear everything" in disguise, and "split it" is absurd advice for that intent — name the spelling that says it.
					return {"error": "Error: the erase rect covers %d cells, past the %d-cell cap — to clear the WHOLE layer pass {\"all\": true}; otherwise split the rect." % [(rect["rect"] as Rect2i).get_area(), GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_FILL_AREA)]}
				spec = {"rect": rect["rect"]}
				line = "erase %s" % GDLLMTilemap._rect_span(rect["rect"])
			elif body.has("source"):
				var source: Dictionary = GDLLMTilemap.resolve_source(record["tile_set"], body.get("source"), names)
				if source.has("error"):
					return source
				_note_once(notes, String(source.get("note", "")))
				spec = {"source": int(source["id"])}
				line = "erase every cell of %s" % GDLLMTilemap.source_label(int(source["id"]), names)
			else:
				return {"error": "Error: \"erase\" takes {\"cells\": [[x, y], ...]}, {\"rect\": [x, y, w, h]}, {\"source\": name-or-id}, or {\"all\": true} to clear the layer."}
			return {"spec": spec, "line": line, "notes": notes}
		"terrain":
			if not raw is Dictionary:
				return {"error": "Error: \"terrain\" takes {\"cells\": [[x, y], ...] or \"rect\": [x, y, w, h], \"terrain\": name-or-index}."}
			var terrain: Dictionary = GDLLMTilemap.resolve_terrain(record["tile_set"], (raw as Dictionary).get("terrain"), (raw as Dictionary).get("terrain_set"))
			if terrain.has("error"):
				return terrain
			var cells: Array = []
			if (raw as Dictionary).has("cells"):
				var raw_cells: Array = (raw as Dictionary)["cells"] if (raw as Dictionary)["cells"] is Array else []
				for i in raw_cells.size():
					var at: Dictionary = GDLLMTilemap.parse_cell(raw_cells[i], "terrain.cells[%d]" % i)
					if at.has("error"):
						return at
					cells.append(at["cell"])
			elif (raw as Dictionary).has("rect"):
				var rect: Dictionary = GDLLMTilemap.parse_rect((raw as Dictionary).get("rect"))
				if rect.has("error"):
					return rect
				var r: Rect2i = rect["rect"]
				for y in range(r.position.y, r.position.y + r.size.y):
					for x in range(r.position.x, r.position.x + r.size.x):
						cells.append(Vector2i(x, y))
			if cells.is_empty():
				return {"error": "Error: \"terrain\" needs cells or a rect to paint."}
			if cells.size() > GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_TERRAIN_CELLS):
				return {"error": "Error: %d cells in one terrain paint is past the %d-cell cap — each is an engine matching step; split the region." % [cells.size(), GDLLMTunables.geti(GDLLMTunables.TILEMAP_MAX_TERRAIN_CELLS)]}
			return {"spec": {"cells": cells, "set": int(terrain["set"]), "terrain": int(terrain["terrain"])}, "line": "paint %d cell(s) with terrain \"%s\"" % [cells.size(), terrain["name"]], "notes": notes}
	return {"error": "Error: unknown action \"%s\"." % action}


static func _note_once(notes: PackedStringArray, note: String) -> void:
	if note != "" and not notes.has(note):
		notes.append(note)


## ==== Animation tools (describe_animation / edit_animation) — decode and edit through gdllm_animation.gd, riding edit_file's writer, validator, and open-scene reload. ====


## describe_animation: decode AnimationPlayer content — the live edited scene by default, a saved file when `scene` names one; walking and composing live in GDLLMAnimation so both modes and the tests share one path.
static func _describe_animation(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, SCENE_SELECT_KEYS + ANIMATION_NAME_KEYS + ANIMATION_PLAYER_KEYS + ANIMATION_WINDOW_KEYS, DESCRIBE_ANIMATION_USAGE)
	if arg_error != "":
		return arg_error
	var anim_query := _arg_string(args, ANIMATION_NAME_KEYS)
	var player_query := _arg_string(args, ANIMATION_PLAYER_KEYS)
	var window := _animation_window(args)
	if window.has("error"):
		return String(window["error"])
	var win: Vector2 = window.get("window", Vector2())
	var requested := _arg_string(args, SCENE_SELECT_KEYS)
	if requested == "":
		if not Engine.is_editor_hint():
			return "Error: reading the live edited scene needs the editor, and this session is running headless — pass \"scene\" with a saved .tscn or an animation .tres path instead."
		var root := EditorInterface.get_edited_scene_root()
		if root == null:
			return "Error: no scene is being edited right now — open one in the editor, or pass \"scene\" with a saved .tscn path."
		var live_scan := GDLLMAnimation.players_from_live(root)
		return GDLLMAnimation.compose_report("Animations in the scene being edited (\"%s\" — LIVE editor state, unsaved edits included)." % root.name, live_scan, anim_query, player_query, win, window.has("window"), "the edited scene \"%s\"" % root.name)
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var ext := resolved.get_extension().to_lower()
	if ext in ["tscn", "scn"]:
		# Loading a PackedScene pulls in its ext-resources but instantiates nothing, so no _init/_ready/@tool code runs; CACHE_MODE_IGNORE keeps it out of the resource cache.
		var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
		if packed == null or not packed is PackedScene:
			return "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]
		var scan := GDLLMAnimation.players_from_state((packed as PackedScene).get_state())
		return _scene_divergence_note(resolved) + GDLLMAnimation.compose_report("Animations in %s (as saved on disk)." % resolved, scan, anim_query, player_query, win, window.has("window"), resolved)
	if not ext in ["tres", "res"]:
		return "Error: %s is not a scene or resource file — describe_animation takes a .tscn/.scn scene, or an Animation/AnimationLibrary .tres/.res." % resolved
	var resource: Resource = ResourceLoader.load(resolved, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null:
		return "Error: %s could not be loaded — %s" % [resolved, _resource_load_cause(resolved)]
	if resource is SpriteFrames:
		return "Error: %s is a SpriteFrames resource, whose animations serialize as plain, readable text — read_file shows them and edit_file changes them." % resolved
	var report := GDLLMAnimation.describe_resource(resource, "Animation content of %s." % resolved, anim_query, win, window.has("window"))
	if report == "":
		return "Error: %s is a %s, not animation data — describe_animation reads Animation and AnimationLibrary resources, or scenes containing AnimationPlayer nodes." % [resolved, resource.get_class()]
	return report


## Parse the optional time window through the shared grammar — a window the model believes took effect but never parsed is worse than an error.
static func _animation_window(args: Dictionary) -> Dictionary:
	for key in ANIMATION_WINDOW_KEYS:
		if args.has(key):
			return GDLLMAnimation.parse_window(args[key])
	return {}


## edit_animation: mutate one animation (or a library's animation list) through the engine's own API and splice the regenerated text back into the file that stores it.
static func _edit_animation(args: Dictionary) -> String:
	var arg_error := _unexpected_arg_error(args, SCENE_SELECT_KEYS + ANIMATION_NAME_KEYS + ANIMATION_PLAYER_KEYS + Array(GDLLMAnimation.EDIT_ACTION_KEYS), EDIT_ANIMATION_USAGE)
	if arg_error != "":
		return arg_error
	var requested := _arg_string(args, SCENE_SELECT_KEYS)
	if requested == "":
		return "Error: no file was given. " + EDIT_ANIMATION_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var ext := resolved.get_extension().to_lower()
	if ext in ["scn", "res"]:
		return "Error: %s is a binary file, whose text cannot be spliced — only text .tscn/.tres files can be animation-edited here." % resolved
	if not ext in ["tscn", "tres"]:
		return "Error: %s is not a .tscn scene or .tres resource — this tool edits the Animation data those files store." % resolved
	var present := PackedStringArray()
	for key in GDLLMAnimation.EDIT_ACTION_KEYS:
		if args.has(key):
			present.append(key)
	if present.is_empty():
		# A key that is not an action (a scalar like "set_length") must be named back, or the caller believes it took effect.
		var strays := PackedStringArray()
		for key in args.keys():
			if not (String(key) in SCENE_SELECT_KEYS or String(key) in ANIMATION_NAME_KEYS or String(key) in ANIMATION_PLAYER_KEYS):
				strays.append("\"%s\"" % key)
		var stray_note := "" if strays.is_empty() else " %s is not an action here." % ", ".join(strays)
		return "Error: no action was given —%s pass exactly one of %s. %s" % [stray_note, ", ".join(GDLLMAnimation.EDIT_ACTION_KEYS), EDIT_ANIMATION_USAGE]
	if present.size() > 1:
		return "Error: one action per call — got %s. Split them into separate edit_animation calls." % ", ".join(present)
	var action := present[0]
	if action in ["add_animation", "remove_animation"]:
		return await _edit_animation_library(resolved, ext, args, action)
	var notes := PackedStringArray()
	var target := _animation_edit_target(resolved, ext, _arg_string(args, ANIMATION_NAME_KEYS), _arg_string(args, ANIMATION_PLAYER_KEYS), notes)
	if target.has("error"):
		return String(target["error"])
	var anim := target["animation"] as Animation
	var applied: Dictionary = GDLLMAnimation.apply_edit(anim, action, args[action])
	if applied.has("error"):
		return String(applied["error"]) + " Nothing was written."
	if action == "add_track" and args[action] is Dictionary:
		_note_once(notes, GDLLMAnimation.track_target_note(String((args[action] as Dictionary).get("path", "")), target.get("player", {}), target.get("scan", {})))
	var encoded := GDLLMAnimation.encode_animation(anim)
	if encoded.has("error"):
		return String(encoded["error"])
	var target_file := String(target["file"])
	var text := FileAccess.get_file_as_string(target_file)
	var remapped := GDLLMAnimation.remap_ext(text, encoded["ext"], encoded["lines"])
	var spliced := GDLLMAnimation.splice_block(String(remapped["text"]), String(target["block_id"]), remapped["body"])
	if spliced.has("error"):
		return String(spliced["error"]) + " Nothing was written."
	var lines: Array = ["Edited \"%s\" in %s — %s." % [target["label"], target_file, applied["line"]]]
	lines.append("Animation now: %s." % GDLLMAnimation.anim_header(anim))
	for note in notes:
		lines.append("NOTE: %s" % note)
	lines.append("Verify: describe_animation {\"scene\": \"%s\", \"animation\": \"%s\"}." % [resolved, target["label"]])
	var report := "\n".join(PackedStringArray(lines))
	if String(spliced["text"]) == text:
		return report + "\n\nNothing on disk changed, so the file was not rewritten."
	return await _animation_write(target_file, text, String(spliced["text"]), report)


## Resolve the animation an edit targets and the file+block that stores it — an animation matched in a scene may really live in a referenced .tres, and the splice must target where it is stored.
static func _animation_edit_target(resolved: String, ext: String, anim_query: String, player_query: String, notes: PackedStringArray) -> Dictionary:
	var anim: Animation = null
	var label := ""
	if ext == "tscn":
		var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
		if packed == null or not packed is PackedScene:
			return {"error": "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]}
		var scan := GDLLMAnimation.players_from_state((packed as PackedScene).get_state())
		var players: Array = scan["players"]
		if player_query != "":
			var matched_player: Dictionary = GDLLMAnimation.match_player(players, player_query)
			if matched_player.has("error"):
				return matched_player
			players = [matched_player["player"]]
		if anim_query == "":
			return {"error": "Error: no animation was named — pass \"animation\"; describe_animation lists this scene's animations. " + EDIT_ANIMATION_USAGE}
		var found: Dictionary = GDLLMAnimation.match_animation(players, anim_query)
		if found.has("error"):
			return {"error": GDLLMAnimation._scoped_error(String(found["error"]), resolved, scan)}
		anim = found["entry"]["animation"] as Animation
		label = String(found["entry"]["key"])
		var storage_scene := _animation_storage(anim.resource_path, resolved, "animation \"%s\"" % label, notes)
		if storage_scene.has("error"):
			return storage_scene
		# The scene's player and scan ride along even when storage redirects to a .tres — the track still plays through THIS scene's player, so its nodes are what a new track path is checked against.
		return {"animation": anim, "file": storage_scene["file"], "block_id": storage_scene["block_id"], "label": label, "player": found["entry"]["player"], "scan": scan}
	else:
		var resource: Resource = ResourceLoader.load(resolved, "", ResourceLoader.CACHE_MODE_IGNORE)
		if resource == null:
			return {"error": "Error: %s could not be loaded — %s" % [resolved, _resource_load_cause(resolved)]}
		if resource is SpriteFrames:
			return {"error": "Error: %s is a SpriteFrames resource, whose animations serialize as plain, readable text — read_file shows them and edit_file changes them. Nothing was changed." % resolved}
		if resource is Animation:
			anim = resource as Animation
			label = anim.resource_name if anim.resource_name != "" else resolved.get_file()
		elif resource is AnimationLibrary:
			if anim_query == "":
				return {"error": "Error: %s is an AnimationLibrary — pass \"animation\" naming which of its animations to edit: %s." % [resolved, ", ".join((resource as AnimationLibrary).get_animation_list())]}
			var player: Dictionary = GDLLMAnimation._blank_player("(library)")
			(player["libraries"] as Array).append({"name": "", "library": resource})
			var found: Dictionary = GDLLMAnimation.match_animation([player], anim_query)
			if found.has("error"):
				return found
			anim = found["entry"]["animation"] as Animation
			label = String(found["entry"]["key"])
		else:
			return {"error": "Error: %s is a %s, not animation data — this tool edits Animation and AnimationLibrary resources, or a scene's AnimationPlayer animations." % [resolved, resource.get_class()]}
	var storage := _animation_storage(anim.resource_path, resolved, "animation \"%s\"" % label, notes)
	if storage.has("error"):
		return storage
	# A standalone .tres has no scene to check a new track's path against, so the resolve note has nothing to say there.
	return {"animation": anim, "file": storage["file"], "block_id": storage["block_id"], "label": label, "player": {}, "scan": {}}


## Where a loaded animation or library is really stored: its own block in the named file, a sub_resource of another file, or a whole other .tres — with the redirect disclosed, since the edit lands THERE.
static func _animation_storage(rp: String, resolved: String, what: String, notes: PackedStringArray) -> Dictionary:
	var target_file := resolved
	var block_id := ""
	if rp.contains("::"):
		target_file = rp.split("::")[0]
		block_id = rp.split("::")[1]
	elif rp != "":
		target_file = rp
	if target_file != resolved:
		var target_ext := target_file.get_extension().to_lower()
		if not target_ext in ["tscn", "tres"]:
			return {"error": "Error: %s is stored in %s, a binary file whose text cannot be spliced. Nothing was changed." % [what, target_file]}
		_note_once(notes, "%s is stored in %s (referenced by %s) — the edit was written THERE." % [what, target_file, resolved])
	return {"file": target_file, "block_id": block_id}


## add_animation / remove_animation: change a library's animation list — a new engine-encoded block plus a _data entry, or the reverse.
static func _edit_animation_library(resolved: String, ext: String, args: Dictionary, action: String) -> String:
	var raw: Variant = args[action]
	var body: Dictionary = {}
	if raw is String:
		body = {"name": raw}
	elif raw is Dictionary:
		body = raw
	else:
		return "Error: \"%s\" takes a name string or an object with \"name\" — got %s." % [action, type_string(typeof(raw))]
	var name := String(body.get("name", ""))
	# "library": "" legitimately names the DEFAULT library, so absence is tracked apart from emptiness.
	var has_lib := body.has("library")
	var lib_query := String(body.get("library", ""))
	if name.contains("/") and not has_lib:
		has_lib = true
		lib_query = name.get_slice("/", 0)
		name = name.substr(lib_query.length() + 1)
	if name == "":
		return "Error: no animation name was given — pass \"name\". " + EDIT_ANIMATION_USAGE
	var found := _animation_library_target(resolved, ext, lib_query, has_lib, _arg_string(args, ANIMATION_PLAYER_KEYS))
	if found.has("error"):
		return String(found["error"])
	var lib := found["library"] as AnimationLibrary
	var lib_label := String(found["label"])
	var notes := PackedStringArray()
	var storage := _animation_storage(lib.resource_path, resolved, lib_label, notes)
	if storage.has("error"):
		return storage["error"]
	var target_file := String(storage["file"])
	var text := FileAccess.get_file_as_string(target_file)
	var spliced := {}
	var head := ""
	if action == "add_animation":
		if lib.has_animation(name):
			return "Error: %s already has an animation \"%s\". Nothing was written." % [lib_label, name]
		var anim := Animation.new()
		if body.has("length"):
			var length: Dictionary = GDLLMAnimation._as_float(body.get("length"), "length")
			if length.has("error"):
				return String(length["error"]) + " Nothing was written."
			anim.length = float(length["value"])
		if body.has("loop"):
			var loop := GDLLMAnimation.LOOP_NAMES.find(String(body.get("loop")))
			if loop < 0:
				return "Error: \"%s\" is not a loop mode. The modes are: %s. Nothing was written." % [str(body.get("loop")), ", ".join(GDLLMAnimation.LOOP_NAMES)]
			anim.loop_mode = loop
		# The engine's own name rules, surfaced as it reports them.
		var err := AnimationLibrary.new().add_animation(name, anim)
		if err != OK:
			return "Error: the engine refused the animation name \"%s\" (add_animation returned %s). Nothing was written." % [name, error_string(err)]
		var encoded := GDLLMAnimation.encode_animation(anim)
		if encoded.has("error"):
			return String(encoded["error"])
		spliced = GDLLMAnimation.splice_add_animation(text, String(storage["block_id"]), name, encoded["lines"])
		head = "Added animation \"%s\" (%s) to %s in %s." % [name, GDLLMAnimation.anim_header(anim), lib_label, target_file]
	else:
		if not lib.has_animation(name):
			return "Error: %s has no animation \"%s\". Its animations are: %s." % [lib_label, name, ", ".join(lib.get_animation_list())]
		var gone := lib.get_animation(name)
		spliced = GDLLMAnimation.splice_remove_animation(text, String(storage["block_id"]), name)
		head = "Removed animation \"%s\" (%s) from %s in %s." % [name, GDLLMAnimation.anim_header(gone), lib_label, target_file]
	if spliced.has("error"):
		return String(spliced["error"]) + " Nothing was written."
	if String(spliced.get("note", "")) != "":
		notes.append(String(spliced["note"]))
	var lines: Array = [head]
	for note in notes:
		lines.append("NOTE: %s" % note)
	lines.append("Verify: describe_animation {\"scene\": \"%s\"}." % resolved)
	var report := "\n".join(PackedStringArray(lines))
	if String(spliced["text"]) == text:
		return report + "\n\nNothing on disk changed, so the file was not rewritten."
	return await _animation_write(target_file, text, String(spliced["text"]), report)


## Resolve which AnimationLibrary an add/remove targets — one player, one library, each step erroring with the real candidates when several exist.
static func _animation_library_target(resolved: String, ext: String, lib_query: String, has_lib: bool, player_query: String) -> Dictionary:
	if ext == "tscn":
		var packed: Resource = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
		if packed == null or not packed is PackedScene:
			return {"error": "Error: %s could not be loaded as a scene — %s" % [resolved, _resource_load_cause(resolved)]}
		var scan := GDLLMAnimation.players_from_state((packed as PackedScene).get_state())
		var players: Array = scan["players"]
		if players.is_empty():
			return {"error": "Error: %s has no AnimationPlayer nodes." % resolved}
		var player := {}
		if player_query != "":
			var matched: Dictionary = GDLLMAnimation.match_player(players, player_query)
			if matched.has("error"):
				return matched
			player = matched["player"]
		elif players.size() == 1:
			player = players[0]
		else:
			return {"error": "Error: %s has %d AnimationPlayer nodes — pass \"player\" naming one of: %s." % [resolved, players.size(), GDLLMAnimation._player_name_list(players)]}
		var libs: Array = player["libraries"]
		if libs.is_empty():
			return {"error": "Error: AnimationPlayer \"%s\" has no animation libraries." % player["path"]}
		var names := PackedStringArray()
		for lib_entry: Dictionary in libs:
			names.append("\"%s\"" % lib_entry["name"])
			if (has_lib and String(lib_entry["name"]) == lib_query) or (not has_lib and libs.size() == 1):
				var lib_name := String(lib_entry["name"])
				var label := "the default library of \"%s\"" % player["path"] if lib_name == "" else "library \"%s\" of \"%s\"" % [lib_name, player["path"]]
				return {"library": lib_entry["library"], "label": label}
		if not has_lib:
			return {"error": "Error: AnimationPlayer \"%s\" has %d libraries — pass \"library\" naming one of: %s." % [player["path"], libs.size(), ", ".join(names)]}
		return {"error": "Error: AnimationPlayer \"%s\" has no library \"%s\". Its libraries are: %s." % [player["path"], lib_query, ", ".join(names)]}
	var resource: Resource = ResourceLoader.load(resolved, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null:
		return {"error": "Error: %s could not be loaded — %s" % [resolved, _resource_load_cause(resolved)]}
	if resource is AnimationLibrary:
		return {"library": resource, "label": "the library %s" % resolved}
	if resource is Animation:
		return {"error": "Error: %s is a single Animation resource, not a library — add_animation/remove_animation change an AnimationLibrary's animation list. Nothing was changed." % resolved}
	return {"error": "Error: %s is a %s, not an AnimationLibrary or a scene. Nothing was changed." % [resolved, resource.get_class()]}


## The shared write tail: lock, write, child-engine validation, editor refresh, and the honest verdict — identical to edit_tilemap's, for the same machine-generated-splice reasons.
static func _animation_write(target_file: String, old_text: String, new_text: String, report: String) -> String:
	await _acquire_mutation_lock()
	if not _edit_file_write(target_file, new_text):
		_mutation_busy = false
		return "Error: %s could not be written — is it read-only or locked by another program? Nothing was changed." % target_file
	var res_check: Dictionary = await _edit_file_validate_resource(target_file, old_text, new_text)
	_mutation_busy = false
	_edit_file_refresh_editor(target_file)
	if bool(res_check["restore_failed"]):
		return "Error: the edit could NOT be kept on disk — validation temporarily swaps the pre-edit content onto the file, and writing the edited content back failed twice, so %s holds the PRE-EDIT content and this edit is NOT saved. Re-run the same edit_animation call once the file is writable, and tell the user the file briefly reverted." % target_file
	var verdict := ""
	if not bool(res_check["checked"]):
		verdict = "\n\nThe engine validation run %s, so the write is UNVALIDATED — nothing is known about whether the file still loads; tell the user this edit went unvalidated." % String(res_check["why"])
	elif not (res_check["new_load"] as Array).is_empty():
		# The spliced text is machine-generated, so a load break here is this tool's defect, not the caller's input — blame accordingly.
		verdict = "\n\nWARNING: the file no longer loads after this write (%s) — this splice is machine-generated, so that is a tool defect, not your input: restore the file from version control and report the bug to the user rather than hand-editing it." % ", ".join(PackedStringArray(res_check["new_load"]))
	verdict += _dropped_property_note(res_check["new_prop_warns"] as Array)
	return report + verdict + _edit_file_reload_open_scene(target_file)


## A stored/live property value rendered for a result line: resources point at their file (or sub-resource class) rather than dumping contents, and anything long is cut short — a packed array or long text must never flood the context.
static func _format_property_value(value: Variant, whole := false) -> String:
	var rendered := ""
	if value is Resource and (value as Resource).resource_path != "":
		rendered = "<%s %s>" % [value.get_class(), (value as Resource).resource_path]
	elif value is Object:
		rendered = "<%s>" % (value as Object).get_class()
	elif value is NodePath:
		rendered = "^\"%s\"" % String(value)
	else:
		rendered = _format_default(value)
	if not whole and rendered.length() > GDLLMTunables.geti(GDLLMTunables.RENDERED_VALUE_MAX_CHARS):
		rendered = rendered.substr(0, GDLLMTunables.geti(GDLLMTunables.RENDERED_VALUE_MAX_CHARS)) + "… (%d chars total)" % rendered.length()
	return rendered


## Render a capped node-detail section headed with its count. A `filter` is an explicit ask: every match shows (no cap), matched against the entry's name — the text before " = " — so a huge value can never match itself; `extra_lever` rides the over-cap note for routes with a second way through (the saved route's read_file). A clipped value in an unfiltered section names the filter lever, since the clip marker alone was a dead end (audit-caught).
static func _format_capped_section(title: String, items: Array, cap: int, filter := "", extra_lever := "") -> String:
	var total := items.size()
	if filter != "":
		var f := filter.to_lower()
		var matched: Array = items.filter(func(it: Variant) -> bool: return String(it).split(" = ")[0].to_lower().contains(f))
		if matched.is_empty():
			return "%s: none of %d match \"%s\" — call without \"filter\" for the capped full list." % [title, total, filter]
		var flines: Array = ["%s matching \"%s\" (%d of %d):" % [title, filter, matched.size(), total]]
		for it in matched:
			flines.append("  " + String(it))
		return "\n".join(flines)
	if items.is_empty():
		return "%s: none" % title
	var shown: Array = items if total <= cap else items.slice(0, cap)
	var note := "" if total <= cap else " (%d of %d shown — pass \"filter\" with part of a name for the rest%s)" % [cap, total, extra_lever]
	var lines: Array = ["%s (%d)%s:" % [title, total, note]]
	var clipped := false
	for it in shown:
		clipped = clipped or String(it).contains("chars total)")
		lines.append("  " + String(it))
	if clipped:
		lines.append("  (a clipped value prints whole when \"filter\" names its property.)")
	return "\n".join(lines)


## edit_resource: load a saved .tres/.res, validate and coerce a whole batch of property changes, apply them, and save back. Loading through load() reuses the editor's cached instance so an inspector on the resource shows the edit — which also means saving commits any unsaved editor changes the user had on that copy along with the batch; the pre-send warning already put that risk to the user, so the save proceeds and the result DISCLOSES the co-commit instead of refusing (checked before the batch applies, while the divergence is still the user's). Validation runs before any set so the batch is all-or-nothing.
static func _edit_resource(args: Dictionary) -> String:
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no resource path was provided. Pass the resource file in \"path\" and the changes in \"properties\", e.g. {\"path\": \"res://stats.tres\", \"properties\": {\"speed\": 200}}."
	var props: Variant = _edit_res_properties_arg(args)
	if not (props is Dictionary) or (props as Dictionary).is_empty():
		return "Error: no properties to set. Pass \"properties\" as an object mapping property name to new value, e.g. {\"properties\": {\"speed\": 200, \"tint\": \"Color(1, 0, 0, 1)\"}}."
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var ext := resolved.get_extension().to_lower()
	# Restricted to the general serialized-resource containers; a .tscn/.gd/.png is technically a Resource too, but editing it as loose properties is meaningless or destructive.
	if ext != "tres" and ext != "res":
		return "Error: \"%s\" is not an editable resource file — edit_resource works on .tres and .res resources, not .%s files." % [resolved, ext]
	var commits_unsaved := resource_has_unsaved_edits(resolved)
	var res: Resource = load(resolved)
	if res == null:
		return "Error: \"%s\" could not be loaded as a resource — %s" % [resolved, _resource_load_cause(resolved)]
	var settable := _edit_res_settable_properties(res)
	# Validate every name up front so an unknown one aborts before anything is written.
	var named: Dictionary = {}
	var aliased: Array = []
	for pname in (props as Dictionary):
		var actual := _edit_res_resolve_name(String(pname), settable)
		if actual == "":
			return _edit_res_unknown_property_message(res, String(pname), settable)
		if named.has(actual):
			return "Error: \"%s\" and \"%s\" are the same property (a shader uniform is settable by its bare name or its stored \"%s\" name), so this batch asks for two values at once. Send one of them. Nothing was written." % [actual.trim_prefix(SHADER_PARAMETER_PREFIX), actual, SHADER_PARAMETER_PREFIX]
		if actual != String(pname):
			aliased.append("\"%s\" was set as \"%s\"" % [pname, actual])
		named[actual] = props[pname]
	# Coerce every value before applying, so a type error also aborts the whole batch cleanly.
	var coerced: Dictionary = {}
	for pname in named:
		var result := _edit_res_coerce(named[pname], settable[String(pname)])
		if not bool(result.get("ok", false)):
			return "Error: property \"%s\" %s Nothing was written." % [pname, String(result.get("error", ""))]
		coerced[String(pname)] = result["value"]
	var change_lines: Array = []
	var swap_note := ""
	if coerced.has("script"):
		# set("script") re-initializes the resource's property storage, so applying it mid-batch silently reset every property the batch didn't mention (transcript: a duplicated boon lost its icon and textures to "Set 5 properties"); the swap goes first with a snapshot restore behind it.
		var old_script: Variant = res.get("script")
		var swap := _apply_script_swap(res, coerced["script"], coerced.keys())
		change_lines.append("script: %s → %s" % [_format_property_value(old_script), _format_property_value(coerced["script"])])
		swap_note = "\n" + _script_swap_note(swap)
	for pname in coerced:
		if String(pname) == "script":
			continue
		var old_value: Variant = res.get(pname)
		res.set(pname, coerced[pname])
		change_lines.append("%s: %s → %s" % [pname, _format_property_value(old_value), _format_property_value(coerced[pname])])
	# emit_changed() before saving so any inspector or dependent redraws against the edited instance.
	res.emit_changed()
	var err := ResourceSaver.save(res, resolved)
	if err != OK:
		return "Error: the changes were applied in memory but ResourceSaver could not write \"%s\", so the file on disk is unchanged — %s" % [resolved, _resource_save_cause(resolved, err)]
	var header := "Saved %s — %d propert%s changed:" % [resolved, coerced.size(), "y" if coerced.size() == 1 else "ies"]
	var unsaved_note := ""
	if commits_unsaved:
		unsaved_note = "\n\nNote: the editor's copy of this resource carried unsaved editor changes (e.g. Inspector edits the user hadn't saved); this save committed those to disk along with the batch above. Tell the user."
	return header + "\n" + "\n".join(change_lines) + swap_note + _shader_parameter_alias_note(aliased) + unsaved_note


## The properties object out of edit_resource's args, accepting it already parsed (Ollama's default) or as a JSON string; null when no synonym key holds an object.
static func _edit_res_properties_arg(args: Dictionary) -> Variant:
	for key in EDIT_RES_PROPERTY_KEYS:
		if args.has(key):
			var value: Variant = args[key]
			if value is Dictionary:
				return value
			if value is String:
				var decoded: Variant = JSON.parse_string(value)
				if decoded is Dictionary:
					return decoded
	return null


## The resource's settable properties as name → PropertyInfo, keeping only editor-visible or stored ones (the properties an inspector shows and a .tres persists) and dropping the group/subgroup/category layout markers.
static func _edit_res_settable_properties(res: Resource) -> Dictionary:
	var out: Dictionary = {}
	for p in res.get_property_list():
		var usage := int(p.get("usage", 0))
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		if not (usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)):
			continue
		out[String(p.get("name", ""))] = p
	return out


## Whether the editor's cached instance of `resolved` would serialize differently from the file on disk. The engine has no get_unsaved_scenes() counterpart for resources, so divergence is measured directly: the cached instance and a cache-bypassing fresh load are each serialized to a scratch file and compared byte-for-byte, which keeps the comparison in engine truth (formatting, sub-resource ids, and stored-property filtering all match a real save) instead of a hand-rolled deep diff. Callers gate on the edited flag first (which implies editor context and a cached instance); the scratch save clears that flag as a side effect (the saver does that on every save, whatever the destination), so a TRUE result restores the flag it consumed and a FALSE result leaves the stale flag healed.
static func _res_cached_diverged(resolved: String) -> bool:
	var cached: Resource = ResourceLoader.load(resolved)
	var fresh: Resource = ResourceLoader.load(resolved, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if cached == null or fresh == null:
		return false
	# The disk side serializes first: it carries no meaningful flags, while scratch-saving `cached` wipes the very flag being vouched for.
	var fresh_bytes := _edit_res_state_bytes(fresh, resolved, "disk")
	# A state that can't be serialized can't be compared; a real save later will surface its own error.
	if fresh_bytes.is_empty():
		return false
	var cached_bytes := _edit_res_state_bytes(cached, resolved, "cached")
	if cached_bytes.is_empty():
		# The failed save may have wiped the flag before dying; restore it rather than heal a flag nothing compared.
		EditorInterface.set_object_edited(cached, true)
		return false
	if cached_bytes == fresh_bytes:
		return false
	EditorInterface.set_object_edited(cached, true)
	return true


## Whether the editor's cached copy of the saved resource at `resolved` carries unsaved modifications. The engine's per-object edited flag is the cheap filter — set by every property write in editor builds (Inspector edits arrive that way through UndoRedo) and cleared again by loading and by every ResourceSaver save — but it over-reports: UNDOING an Inspector edit re-flags the object (UndoRedo marks everything it touches, both directions), so a flagged copy is confirmed by _res_cached_diverged's byte-compare before being called unsaved, which also heals a stale flag along the way. Only the ROOT object's flag means anything: deserialization set()s embedded sub-resources' stored properties and never clears them, so their flags read as edited straight from a load — an Inspector edit made ONLY inside an embedded sub-resource is invisible here and escapes detection. Costs two hash lookups on the uncached majority, so the whole project can be swept at send time.
static func resource_has_unsaved_edits(resolved: String) -> bool:
	if not Engine.is_editor_hint():
		return false
	if not resolved.get_extension().to_lower() in ["tres", "res"]:
		return false
	if not _res_root_edited_flag(resolved):
		return false
	return _res_cached_diverged(resolved)


## The raw root edited flag of the cached copy at `resolved`; get_cached_ref never loads anything, so an uncached path costs two hash lookups.
static func _res_root_edited_flag(resolved: String) -> bool:
	if not ResourceLoader.has_cached(resolved):
		return false
	var cached: Resource = ResourceLoader.get_cached_ref(resolved)
	return cached != null and EditorInterface.is_object_edited(cached)


## A resource's would-be-saved form as raw bytes, via a scratch save in the editor's cache directory; empty when it cannot be serialized. `tag` keeps the two sides of a comparison in separate scratch files, and the process id keeps concurrent editor instances (this cache directory is shared machine-wide) out of each other's comparisons.
static func _edit_res_state_bytes(res: Resource, resolved: String, tag: String) -> PackedByteArray:
	var scratch := EditorInterface.get_editor_paths().get_cache_dir().path_join("gdllm_res_state_%s_%d.%s" % [tag, OS.get_process_id(), resolved.get_extension().to_lower()])
	if ResourceSaver.save(res, scratch) != OK:
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(scratch)
	DirAccess.remove_absolute(scratch)
	return bytes


## Swap a resource's script inside a property batch without wiping the rest: set("script") re-initializes property storage, silently resetting every property the batch didn't mention. Snapshots every settable value BEFORE anything is applied, applies the script, then restores each snapshot property that survives on the re-scripted resource, isn't overridden by `batch_names`, and no longer holds its snapshot value; returns {"carried": int, "dropped": Array} for the caller's disclosure.
static func _apply_script_swap(resource: Resource, script_value: Variant, batch_names: Array) -> Dictionary:
	var snapshot: Dictionary = {}
	for pname in _edit_res_settable_properties(resource):
		if String(pname) != "script":
			snapshot[String(pname)] = resource.get(String(pname))
	resource.set("script", script_value)
	var surviving := _edit_res_settable_properties(resource)
	var carried := 0
	var dropped: Array = []
	for pname in snapshot:
		if not surviving.has(pname):
			dropped.append(pname)
			continue
		if batch_names.has(pname):
			continue
		if not _values_equal(resource.get(pname), snapshot[pname]):
			resource.set(pname, snapshot[pname])
			carried += 1
	return {"carried": carried, "dropped": dropped}


## The disclosure line for a script swap inside a property batch, naming the carried count and up to GDLLMTunables.SUGGESTION_LIST_CAP properties the new script dropped — the swap must never be silent about values it moved or lost.
static func _script_swap_note(swap: Dictionary) -> String:
	var carried := int(swap["carried"])
	var note := "script changed — %d existing propert%s carried across the swap" % [carried, "y" if carried == 1 else "ies"]
	var dropped: Array = swap["dropped"]
	if not dropped.is_empty():
		dropped.sort()
		var more := "" if dropped.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (dropped.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
		note += "; dropped because the new script no longer declares them: %s%s" % [", ".join(dropped.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), more]
	return note + "."


## The disclosure both resource tools give when a bare uniform name was resolved to the prefixed one the material stores it under, or "" when none was — composed once so create_resource and edit_resource can never explain the same substitution differently.
static func _shader_parameter_alias_note(aliased: Array) -> String:
	if aliased.is_empty():
		return ""
	return "\n\nNote: %s — a ShaderMaterial exposes each of its shader's uniforms under the \"%s\" prefix, which is also how the .tres stores them. The bare name is unambiguous, so it was applied; use the prefixed name to be explicit." % [", ".join(PackedStringArray(aliased)), SHADER_PARAMETER_PREFIX]


## The settable property `name` actually refers to, or "" when nothing does. An exact match wins; failing that, a ShaderMaterial's uniform is accepted by its BARE name and resolved to the "shader_parameter/" one it is stored under.
## That fallback can never be ambiguous — the prefix is fixed, so a bare name reaches at most one property, and a resource that really has both takes the exact match first — and refusing the bare name helped nobody: it is the name the uniform is declared with in the shader, the name the inspector shows, and the name a model reads back out of its own edit (wild-measured).
static func _edit_res_resolve_name(name: String, settable: Dictionary) -> String:
	if settable.has(name):
		return name
	if settable.has(SHADER_PARAMETER_PREFIX + name):
		return SHADER_PARAMETER_PREFIX + name
	return ""


## Error text for a property name that isn't settable, with near-miss suggestions gathered from the resource's real property names — like _unknown_member_message but scoped to this instance.
static func _edit_res_unknown_property_message(res: Resource, name: String, settable: Dictionary) -> String:
	var needle := name.to_lower()
	var suggestions: Array[String] = []
	for n in settable:
		var lowered := String(n).to_lower()
		# The reverse containment needs a minimum length, or a needle like "col" would drag in every short name.
		if (lowered.contains(needle) or (lowered.length() >= 4 and needle.contains(lowered))) and not suggestions.has(String(n)):
			suggestions.append(String(n))
	var label := _edit_res_type_label(res)
	var msg := "Error: %s has no editable property named \"%s\" (nothing was written)." % [label, name]
	if suggestions.is_empty():
		# The names come from the INSTANCE, which is the only place some of them exist: a ShaderMaterial's uniforms are added by the object, so the ClassDB view this used to send callers to lists exactly one property ("shader") and could never answer the question (wild-measured against a just-added uniform).
		var real: Array = settable.keys()
		real.erase("script")
		if real.is_empty():
			return msg + " It has no settable properties at all."
		real.sort()
		var more := "" if real.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (real.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
		return msg + " Its settable properties: %s%s." % [", ".join(PackedStringArray(real.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP)))), more]
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]


## The most specific type name for a resource: its script's global class_name when it has one, otherwise the native class.
static func _edit_res_type_label(res: Resource) -> String:
	var script: Variant = res.get_script()
	if script is Script and String(script.get_global_name()) != "":
		return String(script.get_global_name())
	return res.get_class()


## Coerce one JSON-shaped value to a property's declared type (from its PropertyInfo dict), returning {ok, value} or {ok:false, error}. The error text is a sentence fragment the caller prefixes with the property name.
static func _edit_res_coerce(raw: Variant, info: Dictionary) -> Dictionary:
	var t := int(info.get("type", TYPE_NIL))
	var expected := _class_spec_label(_type_label(info))
	# A Variant-typed slot (nil-is-variant) takes the JSON value unchanged.
	if t == TYPE_NIL and int(info.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT:
		return _edit_res_ok(raw)
	# Transcript-observed: models pass null to clear an object slot (e.g. drop a copied augment), which used to be refused as unconvertible.
	if raw == null:
		if t == TYPE_OBJECT:
			return _edit_res_ok(null)
		return _edit_res_err("expects %s and cannot be null — only an object-typed property can be cleared with null." % expected)
	if raw is bool:
		if t == TYPE_BOOL:
			return _edit_res_ok(raw)
		return _edit_res_err("expects %s, but a boolean was given." % expected)
	if raw is int or raw is float:
		if t == TYPE_INT:
			return _edit_res_ok(int(raw))
		if t == TYPE_FLOAT:
			return _edit_res_ok(float(raw))
		return _edit_res_err("expects %s, but a number was given." % expected)
	if raw is String:
		return _edit_res_coerce_string(raw, t, expected, info)
	if raw is Array:
		return _edit_res_coerce_array(raw, t, expected)
	if raw is Dictionary:
		if t == TYPE_DICTIONARY:
			return _edit_res_ok(raw)
		if t == TYPE_OBJECT:
			return _edit_res_coerce_inline_object(raw, info)
		return _edit_res_err("expects %s, but an object was given." % expected)
	return _edit_res_err("could not be converted to %s." % expected)


## Coerce a JSON string to a typed property: passed through for a String/StringName, treated as a res:// resource path for an Object property, otherwise parsed with str_to_var as a Godot literal whose parsed type must match the declared one.
static func _edit_res_coerce_string(raw: String, t: int, expected: String, info: Dictionary) -> Dictionary:
	if t == TYPE_STRING:
		return _edit_res_ok(raw)
	if t == TYPE_STRING_NAME:
		return _edit_res_ok(StringName(raw))
	if t == TYPE_OBJECT:
		return _edit_res_coerce_object(raw, info)
	var parsed: Variant = str_to_var(raw)
	if parsed == null:
		return _edit_res_err("expects %s — pass it as a Godot literal string, e.g. \"%s\"." % [expected, _edit_res_literal_example(t)])
	# str_to_var will happily parse an unrelated literal (a bare number for a Vector2), so verify the parsed type before accepting, allowing only the int→float widening set() would do anyway.
	if typeof(parsed) != t and not (t == TYPE_FLOAT and parsed is int):
		return _edit_res_err("expects %s, but \"%s\" parses as %s — try e.g. \"%s\"." % [expected, raw, type_string(typeof(parsed)), _edit_res_literal_example(t)])
	if t == TYPE_FLOAT and parsed is int:
		return _edit_res_ok(float(parsed))
	return _edit_res_ok(parsed)


## Coerce a res:// path string to an Object-typed property by loading the resource there and checking it is the declared class (or a subclass), so a mismatched or missing file is refused rather than saved.
static func _edit_res_coerce_object(raw: String, info: Dictionary) -> Dictionary:
	var resolved := _resolve_file_path(raw)
	if resolved == "":
		return _edit_res_err("expects a resource — no file found for \"%s\". Pass the res:// path of a resource file, null to clear the property, or an inline object to author an EMBEDDED sub-resource, e.g. {\"script\": \"res://augment.gd\", \"amount\": 1.0}." % raw)
	var loaded: Variant = load(resolved)
	if not (loaded is Resource):
		return _edit_res_err("could not be assigned: \"%s\" would not load as a resource — %s" % [resolved, _resource_load_cause(resolved)])
	var want := String(info.get("class_name", ""))
	if want != "":
		var verdict := _resource_matches_class_spec(loaded, want)
		if not bool(verdict["ok"]):
			if String(verdict["excluded"]) != "":
				return _edit_res_err("expects a %s, but \"%s\" is a %s — a type this property specifically excludes (the inspector's picker hides it too)." % [_class_spec_label(want), resolved, _edit_res_type_label(loaded)])
			return _edit_res_err("expects a %s, but \"%s\" is a %s." % [_class_spec_label(want), resolved, _edit_res_type_label(loaded)])
	return _edit_res_ok(loaded)


## Build an EMBEDDED sub-resource for an Object-typed property from an inline spec: the base named under "script" (a res:// .gd or .tres path or a Resource class name, resolved exactly like create_resource's `from`, so a .tres is deep-duplicated and never shared) plus the remaining keys as the sub-resource's own properties, recursively validated and coerced. The built resource has no resource_path, so saving the parent serializes it as a [sub_resource] — without this path, transcripts show models hand-writing .tres text to embed one.
static func _edit_res_coerce_inline_object(spec: Dictionary, info: Dictionary) -> Dictionary:
	var base := ""
	var base_key := ""
	for key in INLINE_OBJECT_BASE_KEYS:
		if spec.has(key) and spec[key] is String and String(spec[key]) != "":
			base = String(spec[key])
			base_key = String(key)
			break
	if base == "":
		return _edit_res_err("expects a resource — an inline object must name its base under \"script\" (a res:// .gd or .tres path, or a Resource class name), with its other keys as the sub-resource's properties, e.g. {\"script\": \"res://augment.gd\", \"amount\": 1.0}.")
	var built := _create_res_instantiate(base)
	if built.has("error"):
		return _edit_res_err("could not be built from \"%s\" — %s" % [base, String(built["error"]).trim_prefix("Error: ")])
	var res := built["resource"] as Resource
	var want := String(info.get("class_name", ""))
	if want != "" and not bool(_resource_matches_class_spec(res, want)["ok"]):
		return _edit_res_err("expects a %s, but \"%s\" builds a %s." % [_class_spec_label(want), base, _edit_res_type_label(res)])
	var settable := _edit_res_settable_properties(res)
	for raw_name in spec:
		var pname := String(raw_name)
		if pname == base_key:
			continue
		if not settable.has(pname):
			# The did-you-mean treatment top-level property errors get — transcripts show rounds lost guessing nested Gradient/GradientTexture2D names against a bare refusal.
			var near := _create_res_near_miss(pname, settable.keys())
			var hint := ""
			if not near.is_empty():
				hint = " Did you mean: %s?" % ", ".join(near)
			else:
				# The guesses observed in the wild ("alpha_curve") share no substring with any real name, so the near-miss finds nothing; list the real names rather than leave the next guess equally blind.
				var names: Array = settable.keys()
				names.erase("script")
				names.sort()
				var more := "" if names.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (names.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
				hint = " Its settable properties: %s%s." % [", ".join(PackedStringArray(names.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP)))), more]
			return _edit_res_err("could not be built: %s has no editable property named \"%s\".%s" % [_edit_res_type_label(res), pname, hint])
		var coerced := _edit_res_coerce(spec[raw_name], settable[pname])
		if not bool(coerced.get("ok", false)):
			return _edit_res_err("could not be built: its property \"%s\" %s" % [pname, String(coerced.get("error", ""))])
		res.set(pname, coerced["value"])
	return _edit_res_ok(res)


## Coerce a JSON array to the declared array type, converting to the matching packed array where the property demands one; a non-array-typed property refuses it.
static func _edit_res_coerce_array(raw: Array, t: int, expected: String) -> Dictionary:
	match t:
		TYPE_ARRAY:
			return _edit_res_ok(raw)
		TYPE_PACKED_BYTE_ARRAY:
			return _edit_res_ok(PackedByteArray(raw))
		TYPE_PACKED_INT32_ARRAY:
			return _edit_res_ok(PackedInt32Array(raw))
		TYPE_PACKED_INT64_ARRAY:
			return _edit_res_ok(PackedInt64Array(raw))
		TYPE_PACKED_FLOAT32_ARRAY:
			return _edit_res_ok(PackedFloat32Array(raw))
		TYPE_PACKED_FLOAT64_ARRAY:
			return _edit_res_ok(PackedFloat64Array(raw))
		TYPE_PACKED_STRING_ARRAY:
			return _edit_res_ok(PackedStringArray(raw))
		TYPE_PACKED_VECTOR2_ARRAY:
			return _edit_res_ok(PackedVector2Array(raw))
		TYPE_PACKED_VECTOR3_ARRAY:
			return _edit_res_ok(PackedVector3Array(raw))
		TYPE_PACKED_COLOR_ARRAY:
			return _edit_res_ok(PackedColorArray(raw))
	return _edit_res_err("expects %s, but an array was given." % expected)


## Whether a loaded resource satisfies a declared object type, checking the native class and then the script's global-class inheritance chain so a custom Resource subclass is accepted.
static func _edit_res_is_a(res: Resource, expected: String) -> bool:
	if res.is_class(expected):
		return true
	var script: Variant = res.get_script()
	while script is Script:
		if String(script.get_global_name()) == expected:
			return true
		script = script.get_base_script()
	return false


## Whether a resource satisfies a property's declared class SPEC. A spec is usually one class name, but resource-picker properties carry comma-separated lists where a plain entry allows a class (subclasses and script classes included, see _edit_res_is_a) and a "-" entry excludes one: PointLight2D's texture declares "Texture2D,-AnimatedTexture,…", and taking that string as a single class name falsely rejected every valid texture (transcript-observed: a GradientTexture2D refused as not "a Texture2D,-AnimatedTexture,…"). Returns {"ok": bool, "excluded": String} — `excluded` names the vetoing entry so the refusal can say why.
static func _resource_matches_class_spec(res: Resource, spec: String) -> Dictionary:
	var allowed := false
	var excluded := ""
	for raw in spec.split(","):
		var entry := raw.strip_edges()
		if entry == "":
			continue
		if entry.begins_with("-"):
			var banned := entry.substr(1).strip_edges()
			if excluded == "" and _edit_res_is_a(res, banned):
				excluded = banned
		elif not allowed and _edit_res_is_a(res, entry):
			allowed = true
	if excluded != "":
		return {"ok": false, "excluded": excluded}
	return {"ok": allowed, "excluded": ""}


## The readable form of a declared class spec for error text: the allowed names joined with " or ", exclusions dropped — "Texture2D,-AnimatedTexture,…" reads as plain "Texture2D". A spec with no plain entry passes through untouched rather than reading as nothing.
static func _class_spec_label(spec: String) -> String:
	var names := PackedStringArray()
	for raw in spec.split(","):
		var entry := raw.strip_edges()
		if entry != "" and not entry.begins_with("-"):
			names.append(entry)
	return " or ".join(names) if not names.is_empty() else spec


## A sample Godot literal for a declared type, shown in a coercion error so the model learns the exact string form to pass.
static func _edit_res_literal_example(t: int) -> String:
	match t:
		TYPE_VECTOR2:
			return "Vector2(64, 32)"
		TYPE_VECTOR2I:
			return "Vector2i(64, 32)"
		TYPE_VECTOR3:
			return "Vector3(1, 2, 3)"
		TYPE_VECTOR3I:
			return "Vector3i(1, 2, 3)"
		TYPE_VECTOR4:
			return "Vector4(1, 2, 3, 4)"
		TYPE_RECT2:
			return "Rect2(0, 0, 64, 32)"
		TYPE_COLOR:
			return "Color(1, 0, 0, 1)"
		TYPE_QUATERNION:
			return "Quaternion(0, 0, 0, 1)"
		TYPE_NODE_PATH:
			return "NodePath(\"Player/Sprite2D\")"
	return type_string(t) + "(...)"


## A successful coercion result carrying the coerced value.
static func _edit_res_ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value}


## A failed coercion result carrying a sentence-fragment reason the caller prefixes with the property name.
static func _edit_res_err(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## Mutation-lock wrapper for edit_file: whole runs serialize so a second mutation can't interleave with this one's validation window (see _acquire_mutation_lock).
static func _edit_file(args: Dictionary, ledger: SessionLedger) -> Dictionary:
	await _acquire_mutation_lock()
	var result: Dictionary = await _edit_file_locked(args, ledger)
	_mutation_busy = false
	return result


## Edit the file named by `args.path` by exact-string replacement, returning an execute()-shaped result (see the "edit_file" REGISTRY entry). old_string/new_string are read raw and never stripped — leading and trailing whitespace is part of the match; only res:// text files are editable. A file whose real text the model has never been shown is refused (see SessionLedger.seen_files). An old_string matching nothing exactly is retried with line-wise whitespace tolerance (_edit_file_ws_fallback), and a full miss is diagnosed for its actual cause (_edit_file_not_found_message). A .gd file is validated after writing (_edit_file_validate_gd): the edit is KEPT either way, and any new problems come back with orders to fix them. Every error steers the model toward the exact fix.
static func _edit_file_locked(args: Dictionary, ledger: SessionLedger) -> Dictionary:
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return _plain("Error: no path was provided. %s" % EDIT_FILE_USAGE)
	var old_string := _edit_file_arg_raw(args, EDIT_OLD_KEYS)
	if old_string == null:
		return _plain("Error: no old_string was provided. %s" % EDIT_FILE_USAGE)
	var new_string := _edit_file_arg_raw(args, EDIT_NEW_KEYS)
	if new_string == null:
		return _plain("Error: no new_string was provided. %s" % EDIT_FILE_USAGE)
	var old_text := String(old_string)
	var new_text := String(new_string)
	if old_text == "":
		return _plain("Error: old_string is empty, so it can't identify a location. Provide the exact existing text you want to replace.")
	if old_text == new_text:
		return _plain("Error: old_string and new_string are identical, so the edit would change nothing. Provide a new_string that differs.")
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _plain(_file_not_found(requested) + " edit_file only changes an existing file — use write_file to create a new one.")
	if not resolved.begins_with("res://"):
		return _plain("Error: %s is outside res://, so it can't be edited. Only files inside the project (res://) are editable." % resolved)
	if _looks_binary(resolved):
		return _plain("Error: %s looks like a binary file, not text, so it wasn't edited." % resolved)
	var unseen_guard := _edit_file_unseen_guard(resolved, ledger)
	if unseen_guard != "":
		return _plain(unseen_guard)
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		return _plain(_file_open_error(resolved, "edit"))
	var original := file.get_as_text()
	var replace_all := _arg_bool(args, EDIT_REPLACE_ALL_KEYS)
	var count := original.count(old_text)
	var edit_at := -1
	var updated := ""
	var inserted := new_text
	var ws_note := ""
	if count == 0:
		var fallback := _edit_file_ws_fallback(original, old_text, new_text, resolved.get_extension().to_lower() == "gd")
		if fallback.is_empty():
			return _plain(_edit_file_not_found_message(resolved, original, old_text, ledger))
		if fallback.has("nested_func_decl"):
			return _plain("Error: old_string matches lines %d-%d of %s only ignoring whitespace, and the file's text there is INDENTED — inside a function or block — while your new_string declares \"%s\" at column 0. Indenting the declaration to match would nest it inside that block, which GDScript forbids for named functions, so nothing was changed. Re-read the region: to add a top-level function, anchor old_string on real column-0 text (e.g. the last line of the enclosing function); for an inner-class method, copy the file's exact leading tabs into both old_string and new_string." % [int(fallback["line_start"]), int(fallback["line_end"]), resolved, String(fallback["nested_func_decl"])])
		if not fallback.has("updated"):
			return _plain("Error: old_string does not appear exactly in %s, and a whitespace-tolerant match finds %d places, so it's ambiguous. Add more surrounding lines to old_string until it identifies the one spot you mean." % [resolved, int(fallback["matches"])])
		updated = String(fallback["updated"])
		edit_at = int(fallback["at"])
		inserted = String(fallback["inserted"])
		ws_note = String(fallback["note"])
	elif count > 1 and not replace_all:
		return _plain("Error: old_string matches %d places in %s, so it's ambiguous. Add more surrounding lines to old_string until it uniquely identifies the one spot you mean, or set replace_all to true to replace every occurrence." % [count, resolved])
	else:
		# The first replacement site is the same offset in `original` and `updated`, so it anchors the result excerpt even when new_text is empty (a deletion).
		edit_at = original.find(old_text)
		if replace_all:
			updated = original.replace(old_text, new_text)
		else:
			updated = original.substr(0, edit_at) + new_text + original.substr(edit_at + old_text.length())
	var ext := resolved.get_extension().to_lower()
	var uid_note := ""
	if ext == "tscn" or ext == "tres":
		var uid_fix := _lint_written_uid(resolved, updated, ledger)
		if not uid_fix.is_empty():
			# The uid sits in the header; an edit site past it keeps anchoring the result excerpt after the correction shifts offsets.
			if edit_at >= int(uid_fix["end"]):
				edit_at += String(uid_fix["text"]).length() - updated.length()
			updated = String(uid_fix["text"])
			uid_note = String(uid_fix["note"])
	if ext == "gd" or ext == "tscn" or ext == "tres":
		var ref_fix := _lint_new_uid_refs(resolved, original, updated, ledger)
		if String(ref_fix["error"]) != "":
			return _plain(String(ref_fix["error"]))
		for sub in ref_fix["subs"]:
			# A substitution before the edit site shifts the excerpt anchor; uid swaps never change line counts, so nothing else moves.
			if int(sub["start"]) < edit_at:
				edit_at += int(sub["delta"])
		updated = String(ref_fix["text"])
		uid_note += String(ref_fix["notes"])
	if not _edit_file_write(resolved, updated):
		return _plain(_file_write_error(resolved))
	ledger.previous_contents[resolved] = original
	var lint_note := ""
	var checked := ""
	var prop_note := ""
	var ws_para := ("\n\n" + ws_note) if ws_note != "" else ""
	var validated := true
	if CHECKABLE_SOURCE_EXTENSIONS.has(ext):
		var check: Dictionary = await _edit_file_validate_gd(resolved, original, updated)
		if bool(check["restore_failed"]):
			# Validation swapped the pre-edit content onto disk and could not swap the edit back, so the "edited" claim below would be a lie about disk state — nothing outranks reporting that truthfully.
			ledger.previous_contents.erase(resolved)
			_edit_file_refresh_editor(resolved)
			var findings := ""
			if not check["new_parse"].is_empty():
				findings = " Validation of the unsaved edited content found %d new parse/compile error(s) — correct them as you re-apply:\n%s" % [check["new_parse"].size(), "\n".join(PackedStringArray(_grouped_problem_lines(check["new_parse_located"])))]
			return _plain("Error: the edit could NOT be kept on disk — validation temporarily swaps the pre-edit content onto the file, and writing the edited content back failed twice, so %s on disk now holds the PRE-EDIT content and this edit is NOT saved. Is the file read-only, locked by another program, or the disk full? Re-apply the edit with the same edit_file call once the file is writable, and tell the user the file briefly reverted.%s" % [resolved, findings])
		if not bool(check["checked"]):
			# A dead validation subprocess proves nothing either way; claiming "engine-checked" here once told both parties a possibly-broken script was verified clean.
			validated = false
			checked = " — but the engine validation run %s, so the edit is UNVALIDATED: nothing is known about whether the file still %s. Validation appears to be down right now: do NOT re-run checks; continue at your best effort and tell the user this edit went unvalidated so they can verify it themselves" % [String(check["why"]), _source_clean_verb(resolved)]
		else:
			if not check["new_parse"].is_empty():
				_edit_file_refresh_editor(resolved)
				var noise := _foreign_noise_note(check["foreign"], resolved)
				# The pre/post diff can be fooled by run-to-run noise; check_script's ledger is the second witness — an error set already reported this run is not fresh damage, and accusing the model of it sent whole sessions proving their innocence.
				if String(ledger.auto_check_reports.get(resolved, "")) == _error_set_fingerprint(check["post_errors"]):
					# Only an ACCUSING verdict adds to broken_files, so membership here says whose damage this is; pre-existing damage must stay out, or broken_reminder would nag "YOU left it broken" about errors the model never made.
					if ledger.broken_files.has(resolved):
						return _plain("The edit was applied and SAVED. %s still has the same %d parse/compile error(s) YOUR earlier edit introduced this editor run — this edit added none, but they remain unfixed and fixing them is still your top priority; run check_script on it if you need the full list again.%s%s" % [resolved, check["post_errors"].size(), noise, ws_para])
					return _plain("The edit was applied and SAVED. %s still has the same %d parse/compile error(s) last reported this editor run — unchanged and likely pre-existing, NOT introduced by this edit; run check_script on it if you need the full list again.%s%s" % [resolved, check["post_errors"].size(), noise, ws_para])
				var located: Array = check["new_parse_located"]
				var errs := "\n".join(PackedStringArray(_grouped_problem_lines(located)))
				if not bool(check["parse_attributed"]):
					# The baseline run died, so the diff that would prove blame doesn't exist; the full list is reported with attribution honestly unknown instead of inflated into an accusation.
					return _plain("The edit was applied and SAVED, but %s now has %d parse/compile error(s) — it is BROKEN on disk until they are fixed. The pre-edit baseline check %s, so it is unknown which of these this edit introduced and which are pre-existing; fix them NOW with further edit_file calls, before any other work:\n%s%s%s%s%s%s" % [resolved, check["new_parse"].size(), String(check["why"]), errs, _edit_file_error_excerpts(updated, located), _uid_error_attribution(located, ledger), _shader_stop_note(resolved, located), noise, ws_para])
				ledger.broken_files[resolved] = true
				if _all_errors_in_includes(located):
					# The edit is still kept and the file still does not compile, but the fix belongs in the other file — saying "YOU introduced these" would send it back to edit this one.
					return _plain("The edit was applied and SAVED, but %s does not compile: the %d error(s) below are in a file it #includes, which this edit did not touch — reaching that file is what surfaced them. Fix them THERE, before any other work:\n%s%s%s%s" % [resolved, located.size(), errs, _shader_stop_note(resolved, located), noise, ws_para])
				return _plain("The edit was applied and SAVED, but it introduced %d new parse/compile error(s) — %s is now BROKEN on disk until they are fixed. YOU introduced these errors; fix them NOW with further edit_file calls, before any other work:\n%s%s%s%s%s%s" % [check["new_parse"].size(), resolved, errs, _edit_file_error_excerpts(updated, located), _uid_error_attribution(located, ledger), _shader_stop_note(resolved, located), noise, ws_para])
			if not check["new_lint"].is_empty():
				if bool(check["lint_attributed"]):
					lint_note = "\n\nNote: the edit was kept, but it introduced %d new style-lint problem(s) you may want to fix:\n%s" % [check["new_lint"].size(), "\n".join(PackedStringArray(_grouped_problem_lines(check["new_lint"])))]
				else:
					lint_note = "\n\nNote: the edit was kept, but the file has %d style-lint problem(s) — the pre-edit baseline lint did not finish, so how many this edit introduced is unknown:\n%s" % [check["new_lint"].size(), "\n".join(PackedStringArray(_grouped_problem_lines(check["new_lint"])))]
			elif not bool(check["lint_checked"]):
				lint_note = "\n\nNote: the style-lint run %s, so lint problems were not checked this time." % String(check["lint_why"])
			# The claim gates on the post check itself, not the pre/post diff, so a pre-existing-broken file never gets a clean bill it didn't earn.
			if bool(check["post_clean"]):
				checked = " — %s cleanly (engine-checked)" % _source_clean_verb(resolved)
				# Engine truth that the file is clean settles the unchanged-report fingerprint, like check_script's own clean bill.
				ledger.auto_check_reports.erase(resolved)
	elif ext in ["tscn", "tres"]:
		var res_check: Dictionary = await _edit_file_validate_resource(resolved, original, updated)
		if bool(res_check["restore_failed"]):
			# The same disk-truth override as the .gd path: the file holds the pre-edit content, so no other verdict may claim the edit landed.
			ledger.previous_contents.erase(resolved)
			_edit_file_refresh_editor(resolved)
			var findings := ""
			if not res_check["new_load"].is_empty():
				findings = " Validation of the unsaved edited content found %d new load error(s) — correct them as you re-apply:\n%s" % [res_check["new_load"].size(), "\n".join(PackedStringArray(res_check["new_load"]))]
			return _plain("Error: the edit could NOT be kept on disk — validation temporarily swaps the pre-edit content onto the file, and writing the edited content back failed twice, so %s on disk now holds the PRE-EDIT content and this edit is NOT saved. Is the file read-only, locked by another program, or the disk full? Re-apply the edit with the same edit_file call once the file is writable, and tell the user the file briefly reverted.%s" % [resolved, findings])
		if not bool(res_check["checked"]):
			validated = false
			checked = " — but the engine validation run %s, so the edit is UNVALIDATED: nothing is known about whether the file still loads. Validation appears to be down right now: do NOT re-run checks; tell the user this edit went unvalidated so they can verify it themselves" % String(res_check["why"])
		else:
			var new_load: Array = res_check["new_load"]
			if not new_load.is_empty():
				_edit_file_refresh_editor(resolved)
				var blame := "YOU broke it; fix it NOW with further edit_file calls before any other work."
				var header := "New errors:"
				if bool(res_check["attributed"]):
					ledger.broken_files[resolved] = true
				else:
					# The baseline run died, so whether this edit introduced the damage is unknown; the verdict lists everything without the accusation.
					blame = "The pre-edit baseline check %s, so it is unknown which of these errors this edit introduced; fix them NOW regardless — the file is unusable until it loads." % String(res_check["why"])
					header = "Errors (possibly including pre-existing ones):"
				return _plain("The edit was applied and SAVED, but %s does not load as a resource — it is BROKEN on disk until you fix it, and an open tab showing it was NOT reloaded while broken. %s Serialized scene/resource text is fragile — copy every region you touch VERBATIM from a read_file result, and for .tres property changes prefer edit_resource.\n\n%s\n%s%s%s%s%s" % [resolved, blame, header, "\n".join(PackedStringArray(new_load)), _edit_file_load_excerpts(updated, new_load, resolved), _uid_error_attribution(new_load, ledger), ws_para, uid_note])
			if bool(res_check["post_clean"]):
				checked = " — loads cleanly (engine-checked)"
			prop_note = _dropped_property_note(res_check["new_prop_warns"])
	# A verdict that never ran proves nothing about a file an earlier edit left broken, so the ledger only settles on a real check.
	if validated:
		ledger.broken_files.erase(resolved)
	_edit_file_refresh_editor(resolved)
	var reload_note := _edit_file_reload_open_scene(resolved)
	var where := "1 occurrence"
	if ws_note != "":
		where = "1 occurrence (whitespace-tolerant match)"
	elif replace_all:
		where = "every occurrence (%d)" % count
	var excerpt := _edit_file_excerpt(updated, inserted, edit_at)
	return _plain("Edited %s — replaced %s%s.%s Changed region:\n\n%s%s%s%s%s%s" % [resolved, where, checked, (" " + ws_note) if ws_note != "" else "", excerpt, prop_note, lint_note, reload_note, uid_note, _import_write_note(resolved)])


## Correct a hand-written uid in serialized scene/resource text before it lands on disk: transcripts show models inventing header uids ("uid://abc123…") or keeping the source file's uid when writing a copy, then churning over the damage. The engine's registry is the truth — a declared uid that isn't this path's registered one is rewritten (to the registered uid for a known file, else to a fresh engine-generated one, registered immediately so a second write this session can't collide with it) and the correction disclosed. One transcript-observed exception: a model that preloads the uid it plans to give the file has coordinated the two sides, so a collision-free invented uid that other project files already reference is KEPT and registered rather than replaced — replacing it broke the referencing script. An invented uid that gets replaced is recorded in the ledger's replaced_uids, so a later write referencing the invented text is substituted with what it became instead of landing broken (see _lint_new_uid_refs). Returns {} when the text needs no change, else {"text", "note", "end"} — `end` is the corrected region's end offset so a caller anchoring an excerpt after it can shift its offset; a kept uid returns the text unchanged with only the note.
static func _lint_written_uid(dest: String, text: String, ledger: SessionLedger) -> Dictionary:
	var re := RegEx.new()
	re.compile("^(\\[gd_(?:scene|resource)\\b[^\\]]*?\\buid=\")(uid://[^\"]*)(\")")
	var found := re.search(text)
	if found == null:
		return {}
	var declared := found.get_string(2)
	var declared_id := ResourceUID.text_to_id(declared)
	var registered_id := ResourceLoader.get_resource_uid(dest)
	var replacement := ""
	var note := ""
	if registered_id != ResourceUID.INVALID_ID:
		if declared_id == registered_id:
			return {}
		replacement = ResourceUID.id_to_text(registered_id)
		note = "\n\nNote: the content declared uid=\"%s\", but the engine's registered uid for %s is \"%s\" — the header was corrected before saving, since a changed uid breaks every uid-based reference to the file. UIDs are engine-assigned; never write one by hand." % [declared, dest, replacement]
	elif declared_id != ResourceUID.INVALID_ID and ResourceUID.has_id(declared_id):
		if ResourceUID.get_id_path(declared_id) == dest:
			return {}
		var clash := ResourceUID.get_id_path(declared_id)
		var fresh_id := ResourceUID.create_id()
		replacement = ResourceUID.id_to_text(fresh_id)
		ResourceUID.add_id(fresh_id, dest)
		note = "\n\nNote: the content declared uid=\"%s\", which is the engine-assigned uid of %s — two files must never share a uid, so it was replaced with the engine-generated \"%s\" before saving. UIDs are engine-assigned; never write one by hand." % [declared, clash, replacement]
	else:
		# A collision-free uid the engine doesn't know: keep it when it parses as a real id AND project code already references it (the coordinated case — a malformed one could never register, so keeping it helps nobody), otherwise replace — a made-up uid a model liked once is exactly what another run invents again for a different file.
		var refs: Array = _uid_reference_files(declared, dest) if declared_id != ResourceUID.INVALID_ID else []
		if not refs.is_empty():
			ResourceUID.add_id(declared_id, dest)
			var listed := ", ".join(refs.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP)))
			var more := "" if refs.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (refs.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
			return {"text": text, "note": "\n\nNote: the header uid \"%s\" is not engine-assigned, but %s%s already reference(s) it, so it was KEPT and registered to this file rather than breaking them. UIDs are normally engine-assigned — prefer referencing resources by res:// path and letting the engine assign the uid." % [declared, listed, more], "end": found.get_end(2)}
		var fresh_id := ResourceUID.create_id()
		replacement = ResourceUID.id_to_text(fresh_id)
		ResourceUID.add_id(fresh_id, dest)
		ledger.replaced_uids[declared] = replacement
		note = "\n\nNote: the content declared uid=\"%s\", which is not an engine-assigned uid for %s and nothing in the project references it — it was replaced with the engine-generated \"%s\" before saving, since an invented or copied uid collides with real ones. UIDs are engine-assigned; never write one by hand." % [declared, dest, replacement]
	var corrected := text.substr(0, found.get_start(2)) + replacement + text.substr(found.get_end(2))
	return {"text": corrected, "note": note, "end": found.get_start(2) + replacement.length()}


## Project text files (scripts, scenes, resources, project.godot) that literally contain `needle`, skipping `exclude` and this addon's own files (whose docs and tests mention example uids — a match there is never the user's coordination) — the honest textual check behind keeping a coordinated hand-written uid. Runs inline rather than through run_on_worker: its callers hold the mutation lock, which run_on_worker waits out (a deadlock), and the scan only runs on the rare invented-uid path.
static func _uid_reference_files(needle: String, exclude: String) -> Array:
	var files: Array = []
	_collect_text_files("res://", files)
	var hits: Array = []
	for path_v in files:
		var path := String(path_v)
		if path == exclude or path.begins_with("res://addons/gdllm-godot-agentic-harness/"):
			continue
		var ext := path.get_extension().to_lower()
		if ext != "gd" and not DEP_RESOURCE_EXTENSIONS.has(ext) and path.get_file() != "project.godot":
			continue
		if _looks_binary(path):
			continue
		if FileAccess.get_file_as_string(path).contains(needle):
			hits.append(path)
	return hits


## Handle the uid:// literals a write INTRODUCES — present in the new text, absent from the old. One the header lint already replaced this session is substituted with the engine uid it became (a model coordinating a script and a resource it authored, in either order), an [ext_resource] uid disagreeing with its own path= is canonicalized to the path's engine uid, and any remaining literal the engine can't resolve REFUSES the whole write — transcripts show models inventing a uid for a file they plan to create later, then churning over "Preload file does not exist" damage that a refusal turns into a correct next step before anything lands on disk. Literals already in the old text are never touched: a pre-existing stale uid elsewhere in the file must not block an unrelated edit. Returns {"text", "notes", "error", "subs"}: a non-empty error means refuse the write with it untouched; subs lists {start, delta} per substitution so edit_file can keep its excerpt anchored.
static func _lint_new_uid_refs(dest: String, old_text: String, new_text: String, ledger: SessionLedger) -> Dictionary:
	var result := {"text": new_text, "notes": "", "error": "", "subs": []}
	if dest.get_extension().to_lower() in ["tscn", "tres"]:
		_canonicalize_ext_resource_uids(old_text, result)
	var re := RegEx.create_from_string("uid://[0-9A-Za-z_-]+")
	var text := String(result["text"])
	var replacements: Array = []
	var unresolved: Array = []
	var flagged: Dictionary = {}
	for m in re.search_all(text):
		var lit := m.get_string()
		if old_text.contains(lit):
			continue
		var resolves := _uid_current_path(lit) != ""
		if not resolves and ledger.replaced_uids.has(lit):
			replacements.append({"start": m.get_start(), "lit": lit, "real": String(ledger.replaced_uids[lit])})
			continue
		if resolves or flagged.has(lit):
			continue
		flagged[lit] = true
		unresolved.append(lit)
	if not unresolved.is_empty():
		var listed := "\", \"".join(PackedStringArray(unresolved))
		result["error"] = "Error: nothing was written — the new content references \"%s\", which is not any file's uid in this project: an invented uid can never resolve, and saving it would leave %s broken. UIDs are engine-assigned; never write one by hand. Reference the dependency by its res:// path instead (in an [ext_resource], give path= and omit uid=), or create the dependency first — write_file and create_resource confirmations report the real uid to use." % [listed, dest]
		return result
	var noted: Dictionary = {}
	for i in range(replacements.size() - 1, -1, -1):
		var rep: Dictionary = replacements[i]
		var lit := String(rep["lit"])
		var real := String(rep["real"])
		text = text.substr(0, int(rep["start"])) + real + text.substr(int(rep["start"]) + lit.length())
		(result["subs"] as Array).append({"start": int(rep["start"]), "delta": real.length() - lit.length()})
		if not noted.has(lit):
			noted[lit] = true
			result["notes"] = String(result["notes"]) + "\n\nNote: \"%s\" is the uid you invented earlier — it became the engine-assigned \"%s\" when its file was saved, so this reference was substituted to match. UIDs are engine-assigned; never write one by hand." % [lit, real]
	result["text"] = text
	return result


## Rewrite an [ext_resource] uid this write introduces when it disagrees with the entry's own path= — the loader PREFERS the uid, so an invented or copied one silently redirects the reference away from the declared path, or breaks it when it resolves nowhere. The path is the model's explicit intent and its engine uid is the truth; a corrected uid unknown to the registry is registered so the rest of this write's lint sees it as real. An entry whose path is missing or has no discoverable uid is left for the unresolved check. Substitutions run right to left so earlier match offsets stay valid.
static func _canonicalize_ext_resource_uids(old_text: String, result: Dictionary) -> void:
	var entry_re := RegEx.create_from_string("\\[ext_resource\\b[^\\]]*\\]")
	var uid_re := RegEx.create_from_string("\\buid=\"(uid://[^\"]*)\"")
	var path_re := RegEx.create_from_string("\\bpath=\"([^\"]*)\"")
	var text := String(result["text"])
	var matches := entry_re.search_all(text)
	for i in range(matches.size() - 1, -1, -1):
		var entry: RegExMatch = matches[i]
		var um := uid_re.search(entry.get_string())
		var pm := path_re.search(entry.get_string())
		if um == null or pm == null:
			continue
		var declared := um.get_string(1)
		if old_text.contains(declared):
			continue
		var target := pm.get_string(1)
		if not FileAccess.file_exists(target):
			continue
		var real := _uid_text_for(target)
		if real == "" or real == declared:
			continue
		var real_id := ResourceUID.text_to_id(real)
		if real_id != ResourceUID.INVALID_ID and not ResourceUID.has_id(real_id):
			ResourceUID.add_id(real_id, target)
		var at := entry.get_start() + um.get_start(1)
		text = text.substr(0, at) + real + text.substr(at + declared.length())
		(result["subs"] as Array).append({"start": at, "delta": real.length() - declared.length()})
		result["notes"] = String(result["notes"]) + "\n\nNote: the [ext_resource] for %s declared uid=\"%s\", but that file's engine uid is \"%s\" — the entry was corrected before saving, since the loader prefers the uid and a wrong one redirects or breaks the reference. UIDs are engine-assigned; never write one by hand." % [target, declared, real]
	result["text"] = text


## Resolve every uid:// mentioned in a set of error lines against the engine's registry and say what each actually is — transcripts show a VALID uid's "Could not preload" burying a syntax error in the target file behind an apparent uid problem, and an invented uid's failure reading as mysterious. An unresolvable uid is named invented-or-stale outright (with the engine uid it became, when this session's lint replaced it); one that resolves to a live file re-attributes the failure to that file, flagging it when it is already on the session's broken list. "" when the lines mention no uid.
static func _uid_error_attribution(lines: Array, ledger: SessionLedger) -> String:
	var re := RegEx.create_from_string("uid://[0-9A-Za-z_-]+")
	var notes: Array = []
	var seen: Dictionary = {}
	for line_v in lines:
		for m in re.search_all(String(line_v)):
			var lit := m.get_string()
			if seen.has(lit):
				continue
			seen[lit] = true
			var current := _uid_current_path(lit)
			if current == "":
				var real := String(ledger.replaced_uids.get(lit, ""))
				if real != "":
					notes.append("- %s is the uid you invented earlier; it became the engine-assigned %s when its file was saved — update this reference to %s or the res:// path." % [lit, real, real])
				else:
					notes.append("- %s is not any file's uid in this project — invented, or stale from a deleted file. UIDs are engine-assigned: reference by res:// path, or use the uid a tool result reported." % lit)
			elif not FileAccess.file_exists(current):
				notes.append("- %s is registered to %s, which no longer exists on disk — a stale reference." % [lit, current])
			else:
				var broken_hint := " — and it is on this session's broken-file list" if ledger.broken_files.has(current) else ""
				notes.append("- %s correctly resolves to %s: the uid is NOT the problem — that file itself fails to load%s; fix it first." % [lit, current, broken_hint])
	if notes.is_empty():
		return ""
	return "\n\nThe uid(s) in these errors, resolved against the engine's registry:\n" + "\n".join(PackedStringArray(notes))


## The raw string value of the first of `keys` present in `args`, or null when none is present — unlike _arg_string it does NOT strip, since edit_file's old_string/new_string carry significant leading and trailing whitespace, and it distinguishes an absent key (null) from a present empty string ("").
static func _edit_file_arg_raw(args: Dictionary, keys: Array) -> Variant:
	for key in keys:
		if args.has(key):
			return String(args[key])
	return null


## The message for an old_string that matched nothing, even with whitespace tolerance: the ACTUAL cause is named whenever it is detectable — text copied from a version of the file the model's own write already replaced is called out as stale (the misleading generic advice was observed sending models chasing whitespace), and otherwise exactness is taught with a hint fitted to the FILE TYPE, since the .gd hint is about tabs but a serialized scene/resource fails for a different reason (reconstructed rather than copied text). An old_string carrying a read_file elision marker, or matching only when trimmed, gets called out directly.
static func _edit_file_not_found_message(resolved: String, original: String, old_text: String, ledger: SessionLedger) -> String:
	var previous := String(ledger.previous_contents.get(resolved, ""))
	if previous != "" and previous != original and previous.contains(old_text):
		return "Error: old_string was not found in the CURRENT text of %s — it matches this file's PREVIOUS content, which your own write_file/edit_file call replaced earlier. You are working from an outdated copy in memory. Re-read the file (or copy from the exact content of your latest write) and take old_string from what the file holds NOW." % resolved
	var msg := "Error: old_string was not found in %s. The match is exact — every character must line up, including whitespace, indentation, and line breaks." % resolved
	var ext := resolved.get_extension().to_lower()
	if ext == "gd":
		msg += " GDScript in this project is indented with tabs, not spaces."
	elif ext in ["tscn", "tres"]:
		msg += " Serialized scene/resource text must be copied VERBATIM from a read_file result — Godot's own formatting (property order, float and id formatting) can't be reconstructed from a describe_scene or describe_scene_file view."
	msg += " Copy the text to replace directly from a read_file or read_function result rather than retyping it; search_files excerpts carry \"  12: \" line-number prefixes that are not part of the file."
	# Matched by the marker's exact shape so a file that legitimately contains the word never earns the wrong diagnosis (a substring match here would tell its editor the text "never exists in the file" about text that plainly does).
	if _elision_marker_regex().search(old_text) != null:
		msg += " Your old_string contains a \"<... elided>\" marker — read_file inserts those in place of long packed-array data, and they never exist in the file itself; use only real file text."
	var trimmed := old_text.strip_edges()
	if trimmed != old_text and trimmed != "" and original.find(trimmed) >= 0:
		msg += " A match exists for the whitespace-trimmed text, so leading or trailing whitespace in your old_string is the likely mismatch."
	var region := _edit_file_closest_region(original, old_text)
	if region != "":
		msg += "\n" + region
	return msg


## The on-disk lines nearest to a fully missed old_string, quoted VERBATIM so the retry can copy real text out of the error itself — transcript-observed: a model told to "copy from a read_file result" re-read, had the identical result withheld as a duplicate, and dead-ended until the user rescued it. The probe is old_string's longest non-empty line scored with String.similarity; below the floor nothing is quoted, since a dissimilar line would only mislead.
static func _edit_file_closest_region(original: String, old_text: String) -> String:
	var probe := ""
	for line: String in old_text.split("\n"):
		if line.strip_edges() != "" and line.length() > probe.length():
			probe = line
	if probe == "":
		return ""
	var lines := original.split("\n")
	var best := 0
	var best_score := 0.0
	for i in lines.size():
		var score := probe.similarity(lines[i])
		if score > best_score:
			best_score = score
			best = i
	if best_score < EDIT_CLOSEST_REGION_FLOOR:
		return ""
	var from := maxi(best - 3, 0)
	var to := mini(best + 3, lines.size() - 1)
	var quoted := PackedStringArray()
	for i in range(from, to + 1):
		quoted.append(lines[i])
	return "Closest on-disk region (line %d) — copy your old_string from THIS text:\n%s" % [best + 1, "\n".join(quoted)]


## Refuse an edit to a file whose real text the session's model has never been shown this run (see SessionLedger.seen_files) — every transcript-observed old_string typed from memory was a guess that could not match. Empty when the edit may proceed; the refusal names the tools that show verbatim text, tailored to whether the model saw a shape-only view or nothing at all.
static func _edit_file_unseen_guard(resolved: String, ledger: SessionLedger) -> String:
	var seen: Variant = ledger.seen_files.get(resolved)
	if seen == true:
		return ""
	if seen == null:
		return "Error: you have not read %s, so nothing was changed. old_string must be copied verbatim from the file's real text — read the region first with read_file (or read_function for one function, or search_files for the spot), then retry the edit." % resolved
	return "Error: you have only seen a map/overview of %s, not its exact text, so nothing was changed. old_string must be copied verbatim from the file's real text — pull the region with read_function or search_files (or read_file with full=true for the whole file), then retry the edit." % resolved


## Whitespace-tolerant fallback for an old_string that matched nothing exactly: whole lines are compared in a normalized form where only whitespace may differ (see _ws_normalized_line). Returns {} when nothing matches even this way, {"matches": n} when several places do (ambiguous — nothing is applied), or on the UNIQUE match {"updated", "at", "inserted", "note"}: the full new file content, the char offset of the match, the replacement text with its leading whitespace translated by the old→file mapping the match exhibited, and the disclosure sentence the result must carry. Applying instead of bouncing saves the model a failure round trip — the observed intent is unambiguous — while the note keeps what happened fully visible. One intent is refused instead of applied (`is_gd` only): a column-0 `func` declaration whose lead the mapping would make non-empty returns {"nested_func_decl", "line_start", "line_end"} — GDScript has no named nested functions, so that adjustment is guaranteed breakage (transcript-observed: it buried a dev-menu handler inside another function as a "lambda" parse error).
static func _edit_file_ws_fallback(original: String, old_text: String, new_text: String, is_gd := false) -> Dictionary:
	var old_body := old_text.trim_suffix("\n")
	if old_body.strip_edges() == "":
		return {}
	var file_lines := original.split("\n")
	var old_lines := old_body.split("\n")
	if old_lines.size() > file_lines.size():
		return {}
	var norm_file: Array[String] = []
	for line: String in file_lines:
		norm_file.append(_ws_normalized_line(line))
	var norm_old: Array[String] = []
	for line: String in old_lines:
		norm_old.append(_ws_normalized_line(line))
	var starts: Array[int] = []
	for s in range(file_lines.size() - old_lines.size() + 1):
		var all_equal := true
		for k in old_lines.size():
			if norm_file[s + k] != norm_old[k]:
				all_equal = false
				break
		if all_equal:
			starts.append(s)
	if starts.is_empty():
		return {}
	if starts.size() > 1:
		return {"matches": starts.size()}
	var at_line := starts[0]
	# Map each old-side leading whitespace to the file's real one; a lead seen with two different file leads is ambiguous and dropped.
	var lead_map: Dictionary = {}
	var conflicted: Dictionary = {}
	for k in old_lines.size():
		var old_lead := _line_lead(old_lines[k])
		var file_lead := _line_lead(file_lines[at_line + k])
		if lead_map.has(old_lead) and String(lead_map[old_lead]) != file_lead:
			conflicted[old_lead] = true
		lead_map[old_lead] = file_lead
	for key in conflicted:
		lead_map.erase(key)
	var inserted_lines: Array[String] = []
	var new_body := new_text.trim_suffix("\n")
	if new_body != "":
		for line: String in new_body.split("\n"):
			var lead := _line_lead(line)
			var mapped: String = String(lead_map[lead]) if lead_map.has(lead) else _ws_extrapolate_lead(lead, lead_map)
			if is_gd and lead == "" and mapped != "" and (line.begins_with("func ") or line.begins_with("static func ")):
				return {"nested_func_decl": line.strip_edges(), "line_start": at_line + 1, "line_end": at_line + old_lines.size()}
			inserted_lines.append(mapped + line.substr(lead.length()))
	var out_lines: Array[String] = []
	for i in at_line:
		out_lines.append(file_lines[i])
	out_lines.append_array(inserted_lines)
	for i in range(at_line + old_lines.size(), file_lines.size()):
		out_lines.append(file_lines[i])
	var at := 0
	for i in at_line:
		at += file_lines[i].length() + 1
	var diff_bits: Array[String] = []
	for k in old_lines.size():
		if old_lines[k] == file_lines[at_line + k]:
			continue
		if diff_bits.size() == 2:
			diff_bits.append("…")
			break
		var old_lead := _line_lead(old_lines[k])
		var file_lead := _line_lead(file_lines[at_line + k])
		if old_lead != file_lead:
			diff_bits.append("line %d: you sent leading \"%s\" where the file has \"%s\"" % [at_line + k + 1, old_lead.c_escape(), file_lead.c_escape()])
		else:
			diff_bits.append("line %d: spacing inside or at the end of the line" % [at_line + k + 1])
	var note := "Note: old_string did not match the file's text exactly — only whitespace differs (%s) — so the uniquely matching real text at lines %d-%d was edited, with new_string's leading whitespace adjusted to the file's. The changed region shown is exactly what landed." % ["; ".join(diff_bits), at_line + 1, at_line + old_lines.size()]
	return {"updated": "\n".join(out_lines), "at": at, "inserted": "\n".join(inserted_lines), "note": note}


## A line reduced to the equality class the whitespace-tolerant fallback matches in: runs of spaces/tabs collapsed to single spaces, edges stripped — two lines equal here differ only in whitespace.
static func _ws_normalized_line(line: String) -> String:
	return " ".join(line.replace("\t", " ").split(" ", false))


## The leading run of spaces/tabs of a line.
static func _line_lead(line: String) -> String:
	var i := 0
	while i < line.length() and (line[i] == " " or line[i] == "\t"):
		i += 1
	return line.substr(0, i)


## Translate a new_string leading whitespace that no old_string line used, via the one consistent spaces→tabs unit the matched lines exhibited (models type spaces, .gd files use tabs) — e.g. every 4 spaces ↔ 1 tab lets a deeper nesting level new_string introduces land tab-indented. Returns `lead` unchanged whenever no single safe unit exists.
static func _ws_extrapolate_lead(lead: String, lead_map: Dictionary) -> String:
	if lead == "" or lead.count(" ") != lead.length():
		return lead
	var unit := 0
	for old_lead in lead_map:
		var file_lead := String(lead_map[old_lead])
		var o := String(old_lead)
		if o == file_lead or o == "" or file_lead == "":
			continue
		if o.count(" ") != o.length() or file_lead.count("\t") != file_lead.length() or o.length() % file_lead.length() != 0:
			return lead
		var ratio := int(float(o.length()) / float(file_lead.length()))
		if unit != 0 and ratio != unit:
			return lead
		unit = ratio
	if unit == 0 or lead.length() % unit != 0:
		return lead
	return "\t".repeat(int(float(lead.length()) / float(unit)))


## Reattach line numbers to the location-stripped new-parse messages using the located entries parsed from the same engine output; a message with no located twin (e.g. one the engine attributed elsewhere) stays as-is rather than being dropped.
static func _edit_file_locate_problems(new_parse: Array, located: Array) -> Array:
	var remaining := located.duplicate()
	var out: Array = []
	for msg in new_parse:
		var found := ""
		for i in remaining.size():
			if String(remaining[i]).ends_with(String(msg)):
				found = String(remaining[i])
				remaining.remove_at(i)
				break
		out.append(found if found != "" else msg)
	return out


## A compact excerpt of `content` around each "line N:" error in `located`, so a validation report shows the offending lines without echoing the whole file.
static func _edit_file_error_excerpts(content: String, located: Array) -> String:
	var pattern := RegEx.create_from_string("^line (\\d+):")
	var numbers: Array = []
	for entry in located:
		var m := pattern.search(String(entry))
		if m != null:
			numbers.append(int(m.get_string(1)))
	return _excerpt_blocks(content, numbers)


## The resource-load counterpart: the engine's "Parse error. [Resource file res://…:N]" names a line but never the text on it, so quote the culprit region from the just-written content — transcript-observed: a model burned a read and two searches locating a line this excerpt would have shown outright. Only markers naming `res_path` itself are used, since a failing dependency's line number indexes a different file.
static func _edit_file_load_excerpts(content: String, new_load: Array, res_path: String) -> String:
	var pattern := RegEx.create_from_string("\\[Resource file (res://[^\\]]+):(\\d+)\\]")
	var numbers: Array = []
	for entry in new_load:
		var m := pattern.search(String(entry))
		if m != null and m.get_string(1) == res_path:
			numbers.append(int(m.get_string(2)))
	return _excerpt_blocks(content, numbers)


## The shared renderer behind both excerpt forms: at most GDLLMTunables.EDIT_ERROR_EXCERPTS blocks of `content` around the deduplicated `numbers` — a load failure reports the same line once per load attempt, and quoting it twice says nothing new.
static func _excerpt_blocks(content: String, numbers: Array) -> String:
	var lines := content.split("\n")
	var blocks: Array = []
	var seen: Dictionary = {}
	for number in numbers:
		if blocks.size() >= GDLLMTunables.geti(GDLLMTunables.EDIT_ERROR_EXCERPTS):
			break
		var n := int(number)
		if n < 1 or n > lines.size() or seen.has(n):
			continue
		seen[n] = true
		var body: Array = []
		for i in range(maxi(0, n - 1 - GDLLMTunables.geti(GDLLMTunables.EDIT_EXCERPT_CONTEXT_LINES)), mini(lines.size() - 1, n - 1 + GDLLMTunables.geti(GDLLMTunables.EDIT_EXCERPT_CONTEXT_LINES)) + 1):
			body.append("%s %4d: %s" % [">" if i == n - 1 else " ", i + 1, lines[i]])
		blocks.append("\n".join(body))
	if blocks.is_empty():
		return ""
	return "\n\nOffending region(s):\n" + "\n---\n".join(blocks)


## Write `content` to `res_path`, returning whether it succeeded; the single writer edit_file uses for both the change and the validators' temporary baseline restores.
static func _edit_file_write(res_path: String, content: String) -> bool:
	var file := FileAccess.open(res_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return true


## Put the edited content back after a validation baseline swap, retrying once — a transient lock is survivable, but a real failure leaves the PRE-edit content on disk after the edit was already made, so the validators surface it as restore_failed and the callers report the file unsaved instead of edited.
static func _edit_file_restore(res_path: String, updated: String) -> bool:
	if _edit_file_write(res_path, updated):
		return true
	return _edit_file_write(res_path, updated)


## After a successful on-disk edit to a scene that is open: a CLEAN tab is reloaded so the editor shows the new disk state instead of clobbering it back on the user's next save, while a tab with unsaved live edits is left alone — the pre-send warning already put the collision risk to the user, and the editor's own external-change handling owns the conflict from here. Returns the note for the edit confirmation, disclosing which of the two happened; "" when the file isn't an open scene.
static func _edit_file_reload_open_scene(res_path: String) -> String:
	if not Engine.is_editor_hint():
		return ""
	if not res_path.get_extension().to_lower() in ["tscn", "scn"]:
		return ""
	if res_path in EditorInterface.get_unsaved_scenes():
		return "\n\nThe scene is open in the editor with unsaved live edits, so its tab was NOT reloaded — it does not show this edit; the editor will ask the user to resolve the disk change against their live edits."
	for root in EditorInterface.get_open_scene_roots():
		if root.scene_file_path == res_path:
			EditorInterface.reload_scene_from_path(res_path)
			return "\n\nThe scene was open in the editor; its tab was reloaded to show the new disk state."
	return ""


## Validate a just-written .tscn/.tres against its pre-edit state by load-checking it headlessly (tools/load_check.gd), returning the _resource_check_shape keys: only the load errors and unknown-property warnings the edit INTRODUCED so an already-broken file isn't blamed on this edit, plus whether the post-edit check itself ran (`checked`, with `why` naming a run that failed to launch, hung, or died — an empty error list from a dead subprocess once read as a clean engine-checked bill) and passed (`post_clean` — new_load alone can't distinguish a clean file from unchanged pre-existing damage, and the success line's engine-checked claim must not lie). When the post check ran but the BASELINE run died, `attributed` goes false and new_load/new_prop_warns carry the post check's FULL findings rather than a diff an empty baseline would inflate; the caller words its verdict without blame then. The clean case costs one subprocess; the pre-edit baseline only runs when the post-edit check found something. Both baseline-swap writes are checked: a baseline that can't be written skips the pre run and reports unattributed (an unchecked swap once diffed the post content against itself and called fresh damage pre-existing), and a restore that fails even on retry sets `restore_failed` — the file then holds the PRE-edit content and the caller must report the edit unsaved, because "saved" would be a lie about disk state a user's Ctrl+S could then silently entrench. A cancel (see cancel_running_checks) bails with the unchecked shape after restoring the edited content, carrying restore_failed if that restore was the one that failed.
static func _edit_file_validate_resource(res_path: String, original: String, updated: String) -> Dictionary:
	var epoch := _check_epoch
	var post: Dictionary = await _edit_file_load_report(res_path)
	if _check_epoch != epoch:
		return _resource_check_shape({"why": CHECK_CANCELLED_WHY})
	if not bool(post["ok"]):
		return _resource_check_shape({"why": String(post["why"])})
	if (post["errors"] as Array).is_empty() and (post["prop_warns"] as Array).is_empty():
		return _resource_check_shape({"checked": true, "post_clean": true})
	var result := _resource_check_shape({"checked": true, "post_clean": (post["errors"] as Array).is_empty()})
	_baseline_paths[res_path] = true
	if not _edit_file_write(res_path, original):
		# The baseline never reached disk, so the file still holds the edit; report the post check's full findings with attribution honestly unknown rather than diff the post content against itself.
		_baseline_paths.erase(res_path)
		result["attributed"] = false
		result["why"] = "never ran — writing the pre-edit baseline content to disk failed"
		result["new_load"] = (post["errors"] as Array).map(func(e: Dictionary) -> String: return String(e["line"]))
		result["new_prop_warns"] = post["prop_warns"]
		return result
	var pre: Dictionary = await _edit_file_load_report(res_path)
	result["restore_failed"] = not _edit_file_restore(res_path, updated)
	_baseline_paths.erase(res_path)
	if _check_epoch != epoch:
		return _resource_check_shape({"why": CHECK_CANCELLED_WHY, "restore_failed": result["restore_failed"]})
	if not bool(pre["ok"]):
		result["attributed"] = false
		result["why"] = String(pre["why"])
		result["new_load"] = (post["errors"] as Array).map(func(e: Dictionary) -> String: return String(e["line"]))
		result["new_prop_warns"] = post["prop_warns"]
		return result
	result["new_load"] = _edit_file_new_load_lines(pre["errors"], post["errors"])
	result["new_prop_warns"] = _new_plain_lines(pre["prop_warns"], post["prop_warns"])
	return result


## The _edit_file_validate_resource result shape with `overrides` applied over the no-verdict default — checked false and every list empty — so a failed or cancelled check can never read as a clean one by omission.
static func _resource_check_shape(overrides: Dictionary) -> Dictionary:
	var shape := {"new_load": [], "post_clean": false, "new_prop_warns": [], "checked": false, "why": "", "attributed": true, "restore_failed": false}
	for key in overrides:
		shape[key] = overrides[key]
	return shape


## One tools/load_check.gd run over `res_path`, split into its two channels plus the run's own fate: {"ok", "why", "errors": [{key, line}], "prop_warns": [String]} — ok false (checked against the child's completion marker) means the run died and the empty-looking channels are no verdict. Errors are the load problems the running engine reports — parse errors, missing dependencies, and the script's own failure marker — where `key` has digits masked so the pre/post diff survives the line-number shifts an edit causes, while `line` keeps the original text for display, since masking mangled the uid strings a model must act on ("uid://b#h#k#..." named nothing). prop_warns are the child's SCENE_PROP_WARN lines: stored properties and node types a loaded .tscn carries that the engine would silently drop at instantiation.
static func _edit_file_load_report(res_path: String) -> Dictionary:
	var run: Dictionary = await _edit_file_run_engine(["--script", "res://addons/gdllm-godot-agentic-harness/tools/load_check.gd", "--", res_path], LOAD_CHECK_DONE_PATTERN)
	var digits := RegEx.create_from_string("\\d+")
	var errors: Array = []
	var prop_warns: Array = []
	for line in String(run["output"]).split("\n"):
		if line.begins_with("SCENE_PROP_WARN: "):
			prop_warns.append(line.trim_prefix("SCENE_PROP_WARN: ").strip_edges())
			continue
		var at := line.find("Parse Error:")
		if at < 0:
			at = line.find("Compile Error:")
		if at < 0:
			at = line.find("Failed loading resource:")
		if at >= 0:
			var original := line.substr(at).strip_edges()
			errors.append({"key": digits.sub(original, "#", true), "line": original})
			continue
		if line.begins_with("LOAD_CHECK_FAILED"):
			errors.append({"key": "the file no longer loads as a resource", "line": "the file no longer loads as a resource"})
	return {"ok": bool(run["ok"]), "why": String(run["why"]), "errors": errors, "prop_warns": prop_warns}


## The lines of `post` unaccounted for in `pre`, multiset-compared verbatim — the plain-string counterpart to _edit_file_new_load_lines for lines that carry node paths and property names rather than shifting line numbers.
static func _new_plain_lines(pre: Array, post: Array) -> Array:
	var remaining: Array = pre.duplicate()
	var fresh: Array = []
	for line in post:
		var at: int = remaining.find(line)
		if at >= 0:
			remaining.remove_at(at)
		else:
			fresh.append(line)
	return fresh


## The advisory appended when a written .tscn stores properties or node types the engine doesn't know: the file loads, so the edit is kept and nothing is BROKEN, but each named entry is silently dropped at instantiation — this note is the only signal that ever surfaces. Only warnings the write itself introduced arrive here; pre-existing ones were diffed away like load errors.
static func _dropped_property_note(new_warns: Array) -> String:
	if new_warns.is_empty():
		return ""
	var lines := PackedStringArray()
	for warn in new_warns:
		lines.append("- " + String(warn))
	return "\n\nWarning: the file loads, but this write added %d entr%s the engine does not recognize and will silently DROP when the scene is instantiated:\n%s\nFix them with further edit_file calls; describe_class shows a class's real properties." % [new_warns.size(), "y" if new_warns.size() == 1 else "ies", "\n".join(lines)]


## The load-error entries of `post` unaccounted for in `pre`, multiset-compared on their digit-masked keys (a mere line-number shift isn't "new") but reported as their original, unmasked lines — the pairwise counterpart to _edit_file_new_problems.
static func _edit_file_new_load_lines(pre: Array, post: Array) -> Array:
	var remaining: Array = pre.map(func(e: Dictionary) -> String: return String(e["key"]))
	var fresh: Array = []
	for e in post:
		var at: int = remaining.find(String(e["key"]))
		if at >= 0:
			remaining.remove_at(at)
		else:
			fresh.append(String(e["line"]))
	return fresh


## Validate a just-written .gd file against its pre-edit state, returning the _gd_check_shape keys: the parse/compile errors and style-lint problems this edit introduced, whether the post-edit checks themselves ran, and how far the verdict can be trusted. `checked` is false when the post-edit parse run failed to launch, hung, or died (`why` names it, phrased to complete "the engine validation run …") — every list is then empty and the caller must report the change as UNVALIDATED, because an empty error list from a dead subprocess once read as a clean engine-checked bill. `post_clean` says whether the post-edit parse check passed, since the diff alone can't tell a clean file from unchanged pre-existing damage. new_parse/new_lint are normally the post-minus-baseline diff (the pre-edit content is restored around the baseline runs so both checks see the file at its real path — a copy elsewhere would trip class_name/global-class resolution); when a BASELINE run dies instead, `parse_attributed`/`lint_attributed` go false and the lists carry the post check's FULL findings, because an empty baseline would inflate pre-existing damage into "you introduced 59 errors" — the accusation trap the diff exists to avoid. Only errors the engine attributes to THIS file are diffed; other files' load noise rides along in `foreign` for disclosure. `post_errors` is the post-edit check's full own-error set, the form the caller fingerprints against check_script's pre-existing ledger. `lint_checked`/`lint_why` disclose a lint run that never finished; lint stays advisory either way. The caller keeps the edit in every case. A baseline only runs for a check the post-edit pass failed — pre-existing problems can't surface in an empty diff — so a clean edit costs two engine runs, not four. Both baseline-swap writes are checked: a baseline that can't be written skips the pre runs with attribution honestly unknown, and a restore that fails even on retry sets `restore_failed` — the file then holds the PRE-edit content and the caller must report the edit unsaved, because "saved" would be a lie about disk state a user's Ctrl+S could then silently entrench. A cancel (see cancel_running_checks) bails with the unchecked shape after restoring the edited content, carrying restore_failed if that restore was the one that failed.
static func _edit_file_validate_gd(res_path: String, original: String, updated: String) -> Dictionary:
	var epoch := _check_epoch
	# One engine run yields every error form: stripped for the pre/post diff, located for the report, foreign for disclosure.
	var post_classified: Dictionary = await _classified_source_errors(res_path)
	if _check_epoch != epoch:
		return _gd_check_shape({"why": CHECK_CANCELLED_WHY})
	if not bool(post_classified["ok"]):
		return _gd_check_shape({"why": String(post_classified["why"])})
	var post_parse: Array = post_classified["own"]
	var lint_run: Dictionary = await _source_lint_problems(res_path)
	if _check_epoch != epoch:
		return _gd_check_shape({"why": CHECK_CANCELLED_WHY})
	var post_lint: Array = lint_run["problems"] if bool(lint_run["ok"]) else []
	var result := _gd_check_shape({
		"checked": true,
		"post_clean": post_parse.is_empty(),
		"post_errors": post_classified["own_located"],
		"foreign": post_classified["foreign"],
		"lint_checked": bool(lint_run["ok"]),
		"lint_why": String(lint_run["why"]),
	})
	if post_parse.is_empty() and post_lint.is_empty():
		return result
	var pre_parse: Array = []
	var pre_lint: Array = []
	_baseline_paths[res_path] = true
	if _edit_file_write(res_path, original):
		if not post_parse.is_empty() and _check_epoch == epoch:
			var pre_classified: Dictionary = await _classified_source_errors(res_path)
			if bool(pre_classified["ok"]):
				pre_parse = pre_classified["own"]
			else:
				result["parse_attributed"] = false
				result["why"] = String(pre_classified["why"])
		if not post_lint.is_empty() and _check_epoch == epoch:
			var pre_lint_run: Dictionary = await _source_lint_problems(res_path)
			if bool(pre_lint_run["ok"]):
				pre_lint = pre_lint_run["problems"]
			else:
				result["lint_attributed"] = false
		result["restore_failed"] = not _edit_file_restore(res_path, updated)
	else:
		# The baseline never reached disk, so the file still holds the edit; both diffs would compare the post content against itself and call every fresh error pre-existing, so attribution goes honestly unknown instead.
		result["parse_attributed"] = false
		result["lint_attributed"] = false
		result["why"] = "never ran — writing the pre-edit baseline content to disk failed"
	_baseline_paths.erase(res_path)
	if _check_epoch != epoch:
		return _gd_check_shape({"why": CHECK_CANCELLED_WHY, "restore_failed": result["restore_failed"]})
	if bool(result["parse_attributed"]):
		var new_parse := _edit_file_new_problems(pre_parse, post_parse)
		result["new_parse"] = new_parse
		result["new_parse_located"] = _edit_file_locate_problems(new_parse, post_classified["own_located"])
	else:
		result["new_parse"] = post_parse
		result["new_parse_located"] = post_classified["own_located"]
	result["new_lint"] = _edit_file_new_problems(pre_lint, post_lint) if bool(result["lint_attributed"]) else post_lint
	return result


## The _edit_file_validate_gd result shape with `overrides` applied over the no-verdict default — checked false and every list empty — so a failed or cancelled check can never read as a clean one by omission.
static func _gd_check_shape(overrides: Dictionary) -> Dictionary:
	var shape := {"new_parse": [], "new_parse_located": [], "new_lint": [], "post_clean": false, "post_errors": [], "foreign": [], "checked": false, "why": "", "parse_attributed": true, "lint_checked": true, "lint_why": "", "lint_attributed": true, "restore_failed": false}
	for key in overrides:
		shape[key] = overrides[key]
	return shape


## The validate-gd shape for a BRAND-NEW .gd or .gdshader, where no pre-edit baseline exists and every error the located check attributes to the file is its own; the lint run is skipped when the parse run already died, so a wedged editor costs one timeout rather than two.
static func _write_file_new_gd_check(res_path: String) -> Dictionary:
	var classified: Dictionary = await _classified_source_errors(res_path)
	if not bool(classified["ok"]):
		return _gd_check_shape({"why": String(classified["why"])})
	var lint_run: Dictionary = await _source_lint_problems(res_path)
	return _gd_check_shape({
		"checked": true,
		"new_parse": classified["own"],
		"new_parse_located": classified["own_located"],
		"new_lint": lint_run["problems"] if bool(lint_run["ok"]) else [],
		"post_clean": (classified["own"] as Array).is_empty(),
		"post_errors": classified["own_located"],
		"foreign": classified["foreign"],
		"lint_checked": bool(lint_run["ok"]),
		"lint_why": String(lint_run["why"]),
	})


## The check_script tool: check one .gd or .gdshader with the engine's own compiler (the same load-check subprocess edit_file's validation launches — autoload-aware for a script, bracket-forced for a shader) and report its errors with line numbers, or a clean bill. Read-only — nothing is written, so unlike the edit flows it needs no baseline diff or rollback.
static func _check_script(args: Dictionary, ledger: SessionLedger) -> String:
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. Pass the .gd script or .gdshader to check in \"path\"."
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var refusal := _uncheckable_source_refusal(resolved)
	if refusal != "":
		return refusal
	await _await_path_stable(resolved)
	var classified: Dictionary = await _classified_source_errors(resolved)
	var noun := _source_noun(resolved)
	# A check that never finished proves nothing; an empty error list from a dead run once passed for a clean bill (and would wrongly settle the ledgers below).
	if not bool(classified["ok"]):
		return "Error: the engine check on %s %s — the %s was NOT validated, and nothing is known about its parse state from this call. Validation appears to be down right now: do NOT re-run the check; continue at your best effort and tell the user this file went unvalidated so they can verify it themselves." % [resolved, String(classified["why"]), noun]
	var errors: Array = classified["own_located"]
	if errors.is_empty():
		# A clean bill settles the broken-file ledger and the unchanged-report fingerprint, so a later identical error set counts as fresh damage.
		ledger.broken_files.erase(resolved)
		ledger.auto_check_reports.erase(resolved)
		if noun == "shader":
			return "%s compiles cleanly (checked with the engine's own shading-language compiler)." % resolved
		return "%s parses and compiles cleanly (checked with the project's autoloads live)." % resolved
	var fingerprint := _error_set_fingerprint(errors)
	var unchanged := String(ledger.auto_check_reports.get(resolved, "")) == fingerprint
	ledger.auto_check_reports[resolved] = fingerprint
	# Quote the offending lines like the edit verdicts do — check_script often runs on a file the model never read, and the bare line numbers cost it a read to act on.
	var body := "%d parse/compile error(s) in %s:\n%s%s%s" % [errors.size(), resolved, "\n".join(PackedStringArray(_grouped_problem_lines(errors))), _edit_file_error_excerpts(FileAccess.get_file_as_string(resolved), errors), _uid_error_attribution(errors, ledger)]
	if unchanged:
		# Transcript-observed: a model had to reason out from the grouped counts that an identical re-check meant pre-existing damage; say it outright, matching the automatic hook's framing — including whose damage it is (see the hook's broken_files branch).
		if ledger.broken_files.has(resolved):
			body += "\nThis error set is unchanged since your earlier edit left the file broken this editor run — these are YOUR unfixed errors, not pre-existing damage."
		else:
			body += "\nThis error set is unchanged since it was first reported this editor run — likely pre-existing, not from your current changes."
	return body + _shader_stop_note(resolved, errors) + _foreign_noise_note(classified["foreign"], resolved)


## The refusal check_script gives a path it cannot compile, or "" for the two it can. A .gdshaderinc is separated out because it is the near miss that has a real answer: the engine only ever compiles an include as part of a shader that pulls it in, so the lever is checking one of those, and this names them rather than leaving the caller to find them.
static func _uncheckable_source_refusal(resolved: String) -> String:
	var ext := resolved.get_extension().to_lower()
	if CHECKABLE_SOURCE_EXTENSIONS.has(ext):
		return ""
	if ext == "gdshaderinc":
		var includers := _shader_files_including(resolved)
		var lever := "check a .gdshader that includes it — its errors are reported against the include, naming this file and the line."
		if not includers.is_empty():
			lever = "check %s, which include%s it — an error inside this file is reported there, naming this file and the line." % [", ".join(PackedStringArray(includers)), "s" if includers.size() == 1 else ""]
		return "Error: %s is a shader include, which the engine never compiles on its own — it has no shader_type and only becomes code once a .gdshader pulls it in, so checking it alone would report nothing either way. Instead, %s" % [resolved, lever]
	return "Error: %s is neither a GDScript file nor a shader — check_script compiles .gd scripts and .gdshader shaders. Scenes and resources are validated by the tools that write them." % resolved


## The project's .gdshader files whose text names `res_path` in an #include, capped like every other suggestion list. A textual scan by full path or bare file name (both spellings an #include accepts), since an include leaves no trace in the engine's dependency records.
static func _shader_files_including(res_path: String) -> Array:
	var files: Array[String] = []
	_collect_text_files("res://", files)
	var found: Array = []
	for path in files:
		if found.size() >= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP):
			break
		if path.get_extension().to_lower() != SHADER_EXTENSION:
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.contains("#include") and (text.contains(res_path) or text.contains(res_path.get_file())):
			found.append(path)
	return found


## The noun one validation verdict calls `res_path` — calling a .gdshader "the script" in the very sentence that says it is broken is the kind of small lie that sends a session reading the wrong file.
static func _source_noun(res_path: String) -> String:
	return "shader" if res_path.get_extension().to_lower() == SHADER_EXTENSION else "script"


## The clean-bill verb for `res_path`: a shader compiles where a script parses, and the engine-checked claim should say which check actually ran.
static func _source_clean_verb(res_path: String) -> String:
	return "compiles" if res_path.get_extension().to_lower() == SHADER_EXTENSION else "parses"


## Whether EVERY one of `located` is an error the compiler reached through an #include. The fault then lives in a file the edit never touched — connecting to it is what surfaced the error — so a verdict claiming "YOU introduced these errors" would both accuse wrongly and contradict the report right below it, which names the other file (wild-measured: an edit that merely corrected a misspelled #include path was blamed for the semicolon already missing in the file it finally reached).
## An empty list is false rather than vacuously true: no errors is not "all of them elsewhere", and the caller only asks when it has some.
static func _all_errors_in_includes(located: Array) -> bool:
	if located.is_empty():
		return false
	for entry in located:
		if not String(entry).begins_with(INCLUDE_ERROR_PREFIX):
			return false
	return true


## The sentence a shader's error report ends with, or "" for anything else so it costs the context nothing where it isn't true. The shading-language compiler stops at the FIRST error, where GDScript reports its whole set in one run — so an identical-looking "1 parse/compile error(s)" means "the earliest of unknown many" for one and "all of it" for the other, and only saying so keeps a fixed-and-done conclusion off a shader with three more errors behind this one.
static func _shader_stop_note(res_path: String, errors: Array) -> String:
	if errors.is_empty() or res_path.get_extension().to_lower() != SHADER_EXTENSION:
		return ""
	return "\n\nNote: the shader compiler stops at the FIRST error, so this is the earliest problem and not necessarily the only one — re-check once it is fixed."


## One engine-truth check run over `res_path` (a tools/load_check.gd child), its Parse/Compile Error lines classified by the file they belong to (see _classified_parse_errors) plus "ok"/"why" saying whether the run itself completed — the shared launcher behind check_script, its automatic hook, write_file's new-file check, and the edit-validation runs. The child checks after the project's autoloads register as script globals, so autoload references — most gameplay code — compile instead of dying as "Identifier not found" (--check-only exits before autoload setup and misread every such script as an abnormal exit); a Compile Error that still surfaces is real damage, not headless noise. Completion is judged by the child's sentinel, never inferred from exit codes; ok=false means nothing is known about the script, never that it's clean. A load that fails without the engine printing why (the child's LOAD_CHECK_FAILED marker) is folded into an own error so it can't read as clean either.
static func _classified_script_errors(res_path: String) -> Dictionary:
	var run: Dictionary = await _edit_file_run_engine(["--script", "res://addons/gdllm-godot-agentic-harness/tools/load_check.gd", "--", res_path], LOAD_CHECK_DONE_PATTERN)
	var classified := _classified_parse_errors(String(run["output"]), res_path)
	classified["ok"] = bool(run["ok"])
	classified["why"] = String(run["why"])
	if classified["ok"] and String(run["output"]).contains("LOAD_CHECK_FAILED: " + res_path) and (classified["own"] as Array).is_empty():
		classified["own"] = ["the script failed to load, without the engine reporting why"]
		classified["own_located"] = (classified["own"] as Array).duplicate()
	return classified


## The classified-error run for whichever compilable source `res_path` is — the .gd parse check or the .gdshader compile — so every caller that validates a source file asks one question and gets one shape back. A shader's errors arrive in the same {"own", "own_located", "foreign", "ok", "why"} form a script's do, which is what lets the report composers, excerpts, fingerprints and broken-file ledger downstream be shared rather than written twice.
static func _classified_source_errors(res_path: String) -> Dictionary:
	if res_path.get_extension().to_lower() == SHADER_EXTENSION:
		return await _classified_shader_errors(res_path)
	return await _classified_script_errors(res_path)


## One engine-truth compile run over a .gdshader (a tools/load_check.gd child, whose bracket forces the parse the load itself defers), in _classified_script_errors' shape and judged by the same sentinel: ok=false means nothing is known about the shader, never that it compiles. A file that failed to load outright is folded into an own error for the same reason it is on the script path — a load that never happened must not read as a clean bill.
static func _classified_shader_errors(res_path: String) -> Dictionary:
	var run: Dictionary = await _edit_file_run_engine(["--script", "res://addons/gdllm-godot-agentic-harness/tools/load_check.gd", "--", res_path], LOAD_CHECK_DONE_PATTERN)
	if not bool(run["ok"]):
		return {"own": [], "own_located": [], "foreign": [], "ok": false, "why": String(run["why"])}
	# A file that never loaded prints no bracket either, so its own error is settled BEFORE the missing-bracket rail below would call the run unattributable.
	if String(run["output"]).contains("LOAD_CHECK_FAILED: " + res_path):
		return {"own": ["the shader failed to load, without the engine reporting why"], "own_located": ["the shader failed to load, without the engine reporting why"], "foreign": [], "ok": true, "why": ""}
	return _shader_errors_from_output(String(run["output"]), res_path)


## Read one shader check run's output into the classified-error shape, taking only what load_check.gd's stderr bracket attributes to `res_path` — a project can compile other shaders while this one is checked, and the engine names no file on a shader error, so the bracket is the only attribution there is.
## The compiler reports at most ONE error per run (it stops at the first), which is why the caller states as much rather than letting a count of 1 read as "one thing wrong".
## An error the engine locates inside an #include'd file keeps that file's name and line and deliberately drops the "line N:" prefix, since that number indexes the OTHER file — prefixed, the excerpt composer would quote the wrong file's line at it.
## An unsupported shader type is the file's own mistake only when the declared type isn't one the engine has: a real type refused by this check would be the checker falling short, so that case returns no verdict instead of an invented error. GDScript parse errors can never belong to a shader, so that whole channel — located or not — is other files' noise here.
static func _shader_errors_from_output(output: String, res_path: String) -> Dictionary:
	var script_noise := _classified_parse_errors(output, "")
	var foreign: Array = (script_noise["foreign"] as Array) + (script_noise["own"] as Array)
	var own: Array = []
	var own_located: Array = []
	# No bracket means the compile this verdict rests on cannot be located, so nothing is known — reporting clean here is the one answer that is never safe (wild-measured: it cleared a shader the engine's own error log said would not compile).
	if not output.contains(SHADER_BEGIN_MARKER + res_path) or not output.contains(SHADER_END_MARKER + res_path):
		return {"own": [], "own_located": [], "foreign": foreign, "ok": false, "why": "completed without compiling the shader where its errors could be attributed"}
	var lines := output.split("\n")
	var type_refusal := RegEx.create_from_string(SHADER_TYPE_REFUSAL)
	var inside := false
	for i in lines.size():
		var line := String(lines[i])
		if line.contains(SHADER_BEGIN_MARKER + res_path):
			inside = true
			continue
		if line.contains(SHADER_END_MARKER + res_path):
			inside = false
			continue
		if not inside:
			continue
		var refused := type_refusal.search(line)
		if refused != null:
			var declared := refused.get_string(1).strip_edges()
			if SHADER_TYPES.has(declared):
				return {"own": [], "own_located": [], "foreign": foreign, "ok": false, "why": "could not compile a \"shader_type %s\" shader, so nothing is known about this one" % declared}
			own.append(_shader_type_error(declared))
			own_located.append(_shader_type_error(declared))
			continue
		if line.contains(SHADER_ABSENT_MARKER):
			own.append("the engine built no shader from this file — there is no shader code to compile.")
			own_located.append("the engine built no shader from this file — there is no shader code to compile.")
			continue
		var at := line.find(SHADER_ERROR_MARKER)
		if at < 0:
			continue
		var message := _shader_message(line.substr(at + SHADER_ERROR_MARKER.length()).strip_edges())
		if own.has(message):
			continue
		own.append(message)
		own_located.append(_shader_error_location(lines, i, res_path) + message)
	return {"own": own, "own_located": own_located, "foreign": foreign, "ok": true, "why": ""}


## One SHADER ERROR message, with the engine's own wording kept and the cause appended where the wording points nowhere. The preprocessor runs ahead of the compiler and, when it rejects a directive, leaves that line in the code for the tokenizer to choke on — so EVERY preprocessor failure arrives as one message about a stray '#' character, naming neither the directive nor what was wrong with it (probe-measured: an #include whose path does not resolve, an unknown directive, and an #if with no #endif all produce it verbatim, while every directive that works compiles clean).
static func _shader_message(message: String) -> String:
	if not message.contains("Unknown character #35"):
		return message
	return "%s — the shader preprocessor rejected the directive on this line and left it in the code, which is what the tokenizer then hit. The causes are an #include whose path does not resolve, a directive name that is misspelled, and an #if with no matching #endif." % message


## The prefix locating one SHADER ERROR, read off the "at:" line the engine prints under it — "line N: " for the shader's own text, a naming clause for an error the compiler reached through an #include, and "" when no line was reported at all. The next few lines are searched rather than only the next one, because the parent interleaves the child's two output streams and a stdout excerpt block can land between the pair.
static func _shader_error_location(lines: PackedStringArray, at: int, res_path: String) -> String:
	var location := RegEx.create_from_string("\\(([^()]*):(\\d+)\\)\\s*$")
	for i in range(at + 1, mini(at + 4, lines.size())):
		var line := String(lines[i]).strip_edges()
		if not line.begins_with("at:"):
			continue
		var found := location.search(line)
		if found == null:
			return ""
		var where := found.get_string(1)
		if where == "" or where == res_path:
			return "line %s: " % found.get_string(2)
		return "%s%s has this error, at its line %s: " % [INCLUDE_ERROR_PREFIX, where, found.get_string(2)]
	return ""


## The error a shader whose declared type the engine doesn't have earns, worded as the fix — the engine's own refusal names the renderer that turned it down, which reads as a checker limitation rather than the typo it usually is (probe-measured: "shader_type CanvasItem;" produces it).
static func _shader_type_error(declared: String) -> String:
	if declared == "":
		return "the shader declares no shader_type — a .gdshader must open with one, e.g. \"shader_type canvas_item;\". The types are: %s." % ", ".join(SHADER_TYPES)
	return "\"%s\" is not a shader type. The types are: %s." % [declared, ", ".join(SHADER_TYPES)]


## Classify every Parse/Compile Error in one engine run's output by the file it belongs to, returning {"own", "own_located", "foreign"}: `own` holds `res_path`'s errors location-stripped (so a pre/post diff survives line shifts), `own_located` the same errors as "line N: message" where the engine named a line, and `foreign` display lines for errors attributed to OTHER files — a broken autoload, or a .tres whose [ext_resource] is missing, load noise a whole-output scrape used to blame on the checked script (transcript-observed at scale: one missing dependency put 48-60 such lines in every check). Compile Errors count because the check runs with autoloads registered (see _classified_script_errors), so one names real damage, not the headless autoload miss it used to be. Attribution reads the engine's two location shapes: the "res://path:N - " prefix on the error line itself (resource loaders) and the "(res://path:N)" location on the "at:" line that follows (GDScript); an error with neither stays own rather than hidden. An exact repeat of an already-seen located error is dropped: a broken script errors once when autoload setup loads it and again in the check proper, and counting both would double the report and poison the pre/post diff.
static func _classified_parse_errors(output: String, res_path: String) -> Dictionary:
	var lines := output.split("\n")
	var prefix_location := RegEx.create_from_string("(res://\\S+):(\\d+) - $")
	var at_location := RegEx.create_from_string("\\((res://\\S+):(\\d+)\\)")
	var own: Array = []
	var own_located: Array = []
	var foreign: Array = []
	var seen: Dictionary = {}
	for i in lines.size():
		var marker := "Parse Error:"
		var at := lines[i].find(marker)
		if at < 0:
			marker = "Compile Error:"
			at = lines[i].find(marker)
		if at < 0:
			continue
		var message := lines[i].substr(at + marker.length()).strip_edges()
		var pm := prefix_location.search(lines[i].substr(0, at))
		var m := pm if pm != null else (at_location.search(lines[i + 1]) if i + 1 < lines.size() else null)
		if m != null and m.get_string(1) != res_path:
			var entry := "%s:%s: %s" % [m.get_string(1), m.get_string(2), message]
			if not seen.has(entry):
				seen[entry] = true
				foreign.append(entry)
			continue
		var located := "line %s: %s" % [m.get_string(2), message] if m != null else message
		if seen.has(located):
			continue
		seen[located] = true
		own.append(message)
		own_located.append(located)
	return {"own": own, "own_located": own_located, "foreign": foreign}


## One compact line naming the load noise OTHER files emitted while `res_path` was checked — deduplicated, two examples at most, never the full dump — so an own-file "Could not preload" can be traced to its real cause without the noise being counted against the checked file. "" when there was none. The engine prints "referenced non-existent resource" for ANY dependency that fails to load, so when the named file actually exists the note says so instead of repeating the lie — transcripts show models hunting for a "missing" file that was on disk all along when the real cause was that file failing to load.
static func _foreign_noise_note(foreign: Array, res_path: String) -> String:
	if foreign.is_empty():
		return ""
	var distinct: Array = []
	for entry in foreign:
		if not distinct.has(entry):
			distinct.append(entry)
	var cause := "they usually mean another file references a missing dependency."
	var misnamed := RegEx.create_from_string("referenced non-existent resource at: (res://\\S+)")
	for entry in distinct:
		var m := misnamed.search(String(entry))
		if m == null:
			continue
		var path := m.get_string(1).trim_suffix(".")
		if FileAccess.file_exists(path):
			cause = "note: %s EXISTS on disk — the engine says \"non-existent\" for any dependency that fails to LOAD; the real cause is that file failing to load or compile (its own errors are in this report when the engine printed them), so fix that file instead of hunting for a missing one." % path
			break
	return "\n\nDuring the check, %d load error(s) also surfaced from OTHER files (e.g. %s) — they are NOT %s's errors and were not counted against it; %s" % [foreign.size(), "; ".join(PackedStringArray(distinct.slice(0, 2))), res_path, cause]


## The ledger fingerprint of one file's own error set: location-stripped, order-insensitive, so a mere line shift or reordering between runs still reads as the same damage. check_script, its automatic hook, and the edit_file/write_file verdicts all compare against this one form, so they can never disagree about whether an error set is pre-existing.
static func _error_set_fingerprint(errors: Array) -> String:
	var pattern := RegEx.create_from_string("^line (\\d+): ")
	var stripped: Array = []
	for entry in errors:
		var text := String(entry)
		var m := pattern.search(text)
		stripped.append(text.substr(m.get_string(0).length()) if m else text)
	stripped.sort()
	return "\n".join(PackedStringArray(stripped)).md5_text()


## Collapse repeated problem lines for one report: entries differing only in their "line N: " location merge into one "lines A, B, C: message", and exact duplicates (location-stripped lint problems) into "message (N occurrences)" — a mistake repeated through a file was showing the model the identical message dozens of times. Order of first appearance is kept; a lone entry passes through untouched.
static func _grouped_problem_lines(problems: Array) -> Array:
	var pattern := RegEx.create_from_string("^line (\\d+): ")
	var order: Array = []
	var locations: Dictionary = {}
	var counts: Dictionary = {}
	for entry in problems:
		var text := String(entry)
		var m := pattern.search(text)
		var msg := text.substr(m.get_string(0).length()) if m else text
		if not counts.has(msg):
			order.append(msg)
			counts[msg] = 0
			locations[msg] = PackedStringArray()
		counts[msg] = int(counts[msg]) + 1
		if m:
			locations[msg].append(m.get_string(1))
	var out: Array = []
	for msg in order:
		var count := int(counts[msg])
		var lines: PackedStringArray = locations[msg]
		if count == 1:
			out.append("line %s: %s" % [lines[0], msg] if lines.size() == 1 else msg)
		elif lines.size() == count:
			out.append("lines %s: %s" % [", ".join(lines), msg])
		else:
			# A mixed located/unlocated group can't list its lines truthfully, so it falls back to the bare count.
			out.append("%s (%d occurrences)" % [msg, count])
	return out


## The lint half of a source file's validation, run only where a linter exists: the style guide the repo's linter enforces is GDScript's, so a .gdshader reports the clean, completed shape rather than a run that never happened — a lint_checked of false would put "lint problems were not checked this time" on every shader edit, which is noise about a check that does not exist.
static func _source_lint_problems(res_path: String) -> Dictionary:
	if res_path.get_extension().to_lower() == SHADER_EXTENSION:
		return {"ok": true, "why": "", "problems": []}
	return await _edit_file_lint_problems(res_path)


## The style-lint problems the repo's own linter reports for `res_path` as {"ok", "why", "problems"}, each normalized to "message (rule)" with its "path:line:" prefix dropped so the pre/post diff ignores line-number shifts; the linter's summary and the engine banner don't match the "<file>.<ext>:<line>:" shape and are skipped. The summary line the linter always ends with is the run's completion sentinel: without it the run died early and "problems" is no verdict.
static func _edit_file_lint_problems(res_path: String) -> Dictionary:
	var run: Dictionary = await _edit_file_run_engine(["--script", "res://addons/gdllm-godot-agentic-harness/tools/style_lint.gd", "--", res_path], LINT_DONE_PATTERN)
	var pattern := RegEx.create_from_string("\\.\\w+:\\d+: (.*)")
	var problems: Array = []
	for line in String(run["output"]).split("\n"):
		var m := pattern.search(line)
		if m:
			problems.append(m.get_string(1))
	return {"ok": bool(run["ok"]), "why": String(run["why"]), "problems": problems}


## Run the running engine binary (OS.get_executable_path()) headlessly against this project with `extra_args` appended, returning {"ok", "why", "output", "exit_code"} — combined stdout+stderr plus whether the run actually completed; the shared launcher for the parse, lint, and load checks. Kept minimal (--headless, no full editor) so the subprocess stays fast. Launched through a pipe rather than OS.execute because OS.execute waits unconditionally — a wedged check would freeze the editor with it — while this drains output in a bounded poll and kills the subprocess at `timeout_ms` (GDLLMTunables.ENGINE_CHECK_TIMEOUT_MS for the validation checks; run_script passes its own, model-raisable cap). ok is false when the subprocess failed to launch, hit the timeout, or (given `done_pattern`, a regex a finished run's output always matches) died before completing: empty output from a dead run once parsed as ZERO errors and earned a false "engine-checked" clean claim, so a caller must treat ok=false as "nothing is known" — never as clean — and surface `why` (phrased to complete "the subprocess …") in its own result rather than in a push_warning nobody sees. A dead run's why also quotes the child's most telling output line (see _check_death_note), because capturing the output and then discarding it left the 2026-07-18 checker outage undiagnosable from the transcripts. In-editor each poll pass yields a frame, so the editor stays responsive for the child's whole run; headless it sleeps, keeping the test scripts synchronous.
static func _edit_file_run_engine(extra_args: Array, done_pattern := "", timeout_ms := -1) -> Dictionary:
	# -1 (a default parameter can't call the settings read) stands for the user-configurable validation cap; run_script passes its own, model-raisable figure.
	if timeout_ms < 0:
		timeout_ms = GDLLMTunables.geti(GDLLMTunables.ENGINE_CHECK_TIMEOUT_MS)
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://")])
	for a in extra_args:
		args.append(String(a))
	var pipe := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if pipe.is_empty():
		return {"ok": false, "why": "failed to launch", "output": "", "exit_code": -1, "killed": false}
	var pid := int(pipe["pid"])
	_live_check_pids[pid] = true
	var output := ""
	var killed := false
	var deadline := Time.get_ticks_msec() + timeout_ms
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() >= deadline:
			OS.kill(pid)
			killed = true
			break
		# Drain as the subprocess runs so a full pipe buffer can never stall it mid-write.
		output += _edit_file_drain_pipe(pipe["stdio"]) + _edit_file_drain_pipe(pipe["stderr"])
		if Engine.is_editor_hint():
			await Engine.get_main_loop().process_frame
		else:
			OS.delay_msec(10)
	_live_check_pids.erase(pid)
	output += _edit_file_drain_pipe(pipe["stdio"]) + _edit_file_drain_pipe(pipe["stderr"])
	if killed:
		return {"ok": false, "why": "hung and was killed after %.1f seconds (the editor or machine may have been busy)%s" % [timeout_ms / 1000.0, _check_death_note(output)], "output": output, "exit_code": -1, "killed": true}
	var exit_code := OS.get_process_exit_code(pid)
	if done_pattern != "" and RegEx.create_from_string(done_pattern).search(output) == null:
		return {"ok": false, "why": "exited before finishing its check (exit code %d)%s" % [exit_code, _check_death_note(output)], "output": output, "exit_code": exit_code, "killed": false}
	return {"ok": true, "why": "", "output": output, "exit_code": exit_code, "killed": false}


## The clause quoting a dead validation child's most telling output line into its why — the 2026-07-18 outage went undiagnosed for 39 minutes because this output was captured and discarded, while its every line named the cause. Prefers the last engine ERROR line over plain trailing noise, and when that line says the checker script ITSELF failed to load, states the plain cause: the addon install is incomplete or mid-sync, and re-syncing it fixes every check.
static func _check_death_note(output: String) -> String:
	var tail := ""
	var last_error := ""
	for line in output.split("\n"):
		var stripped := line.strip_edges()
		if stripped == "" or stripped.begins_with("Godot Engine v"):
			continue
		tail = stripped
		if stripped.contains("ERROR:"):
			last_error = stripped
	var pick := last_error if last_error != "" else tail
	if pick == "":
		return "; it printed nothing beyond the engine banner"
	if pick.length() > GDLLMTunables.geti(GDLLMTunables.CHECK_DEATH_TAIL_CHARS):
		pick = pick.substr(0, GDLLMTunables.geti(GDLLMTunables.CHECK_DEATH_TAIL_CHARS)) + "…"
	for entry_script in ["res://addons/gdllm-godot-agentic-harness/tools/load_check.gd", "res://addons/gdllm-godot-agentic-harness/tools/style_lint.gd"]:
		if output.contains("script: %s" % entry_script) or output.contains("script \"%s\"" % entry_script):
			return "; its last output line: \"%s\" — the harness's own checker script failed to load, so the addon install at res://addons/gdllm-godot-agentic-harness is likely incomplete or mid-sync; tell the user, since restoring/re-syncing the addon fixes every check" % pick
	return "; its last output line: \"%s\"" % pick


## Everything currently readable from one of the validation subprocess's pipes, without blocking; "" once the pipe is empty or closed.
static func _edit_file_drain_pipe(pipe: FileAccess) -> String:
	if pipe == null or not pipe.is_open():
		return ""
	var bytes := PackedByteArray()
	while true:
		var chunk := pipe.get_buffer(4096)
		if chunk.is_empty():
			break
		bytes.append_array(chunk)
	return bytes.get_string_from_utf8()


## The entries of `post` that aren't accounted for in `pre`, compared as a multiset so a problem present twice before and three times after counts as one new one; this is how "only NEW problems count" is enforced against a file that already had issues.
static func _edit_file_new_problems(pre: Array, post: Array) -> Array:
	var remaining := pre.duplicate()
	var fresh: Array = []
	for item in post:
		var at := remaining.find(item)
		if at >= 0:
			remaining.remove_at(at)
		else:
			fresh.append(item)
	return fresh


## A compact excerpt of the changed region in `updated`: the lines spanned by the replacement at offset `at` plus GDLLMTunables.EDIT_EXCERPT_CONTEXT_LINES lines on each side, changed lines marked ">", rendered like _render_block so a confirmation shows the edit in place without echoing the whole file. The caller passes the edit's own offset so a deletion (empty new_text) still points at the right region. A replacement past GDLLMTunables.EDIT_EXCERPT_MAX_CHANGED_LINES shows its head and tail with the middle counted, since that text is already in the conversation as the call's own new_string.
static func _edit_file_excerpt(updated: String, new_text: String, at: int) -> String:
	var lines := updated.split("\n")
	var start_line := 0 if at < 0 else updated.substr(0, at).count("\n")
	var end_line := start_line + (0 if new_text == "" else new_text.count("\n"))
	var from := maxi(0, start_line - GDLLMTunables.geti(GDLLMTunables.EDIT_EXCERPT_CONTEXT_LINES))
	var to := mini(lines.size() - 1, end_line + GDLLMTunables.geti(GDLLMTunables.EDIT_EXCERPT_CONTEXT_LINES))
	var changed := end_line - start_line + 1
	var half := GDLLMTunables.geti(GDLLMTunables.EDIT_EXCERPT_MAX_CHANGED_LINES) / 2
	var skip_from := -1
	var skip_to := -1
	if changed > GDLLMTunables.geti(GDLLMTunables.EDIT_EXCERPT_MAX_CHANGED_LINES):
		skip_from = start_line + half
		skip_to = end_line - half
	var body: Array = []
	for i in range(from, to + 1):
		if skip_from != -1 and i >= skip_from and i <= skip_to:
			if i == skip_from:
				body.append("  … %d changed lines (%d-%d) not repeated — they are the middle of the replacement just written; read_file with start_line/end_line re-shows any of them." % [skip_to - skip_from + 1, skip_from + 1, skip_to + 1])
			continue
		var marker := ">" if i >= start_line and i <= end_line else " "
		body.append("%s %4d: %s" % [marker, i + 1, lines[i]])
	return "\n".join(body)


## Tell the editor a file changed on disk so the change is picked up: update_file reindexes it and scan_sources refreshes the global class list in case a class_name moved; a script open in the script editor is reloaded on the spot so Godot's "files newer on disk" prompt never fires for a change the user already sanctioned by enabling edits. Guarded by is_editor_hint so a headless (non-editor) run — including the unit tests — skips it instead of touching an absent EditorInterface.
## The cached-shader refresh runs ahead of that gate: the resource cache is not the editor's, so a stale Shader would outlive the write in any long-lived process.
static func _edit_file_refresh_editor(res_path: String) -> void:
	_refresh_cached_shader(res_path)
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	fs.update_file(res_path)
	fs.scan_sources()
	_edit_file_reload_open_script(res_path)


## Push a just-written .gdshader's text into the Shader object already held in memory, so everything referencing it agrees with disk.
## Writing the file is not enough: a ShaderMaterial builds both its inspector rows and its .tres keys from its shader's uniform list, so until the cached Shader re-reads the file a uniform this write ADDED does not exist as far as anything holding it is concerned — wild-measured, edit_resource refused to set the very uniform the edit before it had created, and the near-miss had nothing to suggest because the property list was a generation behind.
## Only an already-cached shader is touched: loading one nobody holds would spend a file read to update nothing.
static func _refresh_cached_shader(res_path: String) -> void:
	if res_path.get_extension().to_lower() != SHADER_EXTENSION or not ResourceLoader.has_cached(res_path):
		return
	var cached: Resource = ResourceLoader.load(res_path)
	if cached is Shader:
		(cached as Shader).code = FileAccess.get_file_as_string(res_path)


## Reload the script editor's copy of `res_path` when it is open there, with the auto-reload editor setting forced on for just this call so the reload is silent regardless of the user's global preference (restored right after). A script the user has unsaved changes in is deliberately left alone — silently reloading would discard their typing — so Godot's usual conflict prompt stays the arbiter there.
static func _edit_file_reload_open_script(res_path: String) -> void:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	var open := false
	for script in script_editor.get_open_scripts():
		if script != null and script.resource_path == res_path:
			open = true
			break
	if not open:
		return
	for unsaved in script_editor.get_unsaved_files():
		if String(unsaved) == res_path or String(unsaved).get_file() == res_path.get_file():
			return
	var settings := EditorInterface.get_editor_settings()
	var auto_reload := "text_editor/behavior/files/auto_reload_scripts_on_external_change"
	var prior: Variant = settings.get_setting(auto_reload)
	settings.set_setting(auto_reload, true)
	script_editor.reload_open_files()
	settings.set_setting(auto_reload, prior)


## Mutation-lock wrapper for write_file, the same serialization as _edit_file's (see _acquire_mutation_lock).
static func _write_file(args: Dictionary, ledger: SessionLedger) -> String:
	await _acquire_mutation_lock()
	var result: String = await _write_file_locked(args, ledger)
	_mutation_busy = false
	return result


## Refuse a wholesale overwrite of an existing file whose real text the session's model has never been shown this run (see SessionLedger.seen_files) — write_file REPLACES the whole file, so overwriting one it never read risks clobbering the wrong file or content it only imagined (transcript-observed: a model rewrote an existing script from hallucination and broke it and its dependent). A path seen verbatim still refuses when that read ELIDED packed-array payloads (see SessionLedger.elided_files): the markers stand in for real data a rebuilt file cannot contain, so the honest route is edit_file, which keeps every untouched byte. Empty when the overwrite may proceed; `force` waives every rung for a deliberate blind replacement. Only call for a destination that exists.
static func _write_overwrite_seen_guard(dest: String, ledger: SessionLedger, force: bool) -> String:
	if force:
		return ""
	var seen: Variant = ledger.seen_files.get(dest)
	if seen == true:
		# Only an ARMED record (true) refuses — false is the sticky disarm a whole-file full read or an authored write leaves, and absent means nothing was ever elided.
		if ledger.elided_files.get(dest) != true:
			return ""
		return "Error: %s already EXISTS and your view of it is NOT the whole file: its long packed-array data (embedded images, mesh or tile data) was elided to \"<... elided>\" markers, so a wholesale rewrite built from that view would destroy the real payloads behind them — nothing was written. Change it with edit_file instead, which replaces only the region you name and keeps every other byte; or, if you genuinely need to rebuild the whole file, read it again with read_file full:true — that returns every byte, payloads included, and re-grounds this overwrite. Pass force:true only to overwrite anyway, knowingly dropping the elided data." % dest
	var how := "you have only seen a map/overview of it, not its real text" if seen != null else "you have not read it this session"
	return "Error: %s already EXISTS and %s, so nothing was written — write_file replaces a file wholesale, and overwriting one you have not read risks destroying the wrong file or content you never saw. Read it first (read_file, or read_function/search_files for a piece) to confirm you mean this exact file and know what you are replacing, then re-send; to change only part of it use edit_file instead, or pass force:true to overwrite it unread anyway." % [dest, how]


## Refuse creating a NEW file whose basename already belongs to one or more files elsewhere in the project — the phantom-duplicate trap: a model reads the real file (often silently inside a subagent, bypassing read_file's resolution note) then writes a same-named NEW file at a slightly wrong path, leaving the real one untouched and, for a .gd carrying a global class_name, two files claiming one class. Empty when the basename is unique or `force` is set; only meaningful for a destination that does not yet exist.
static func _write_phantom_collision_guard(dest: String, force: bool) -> String:
	if force:
		return ""
	var twins := _find_all_by_name("res://", dest.get_file())
	if twins.is_empty():
		return ""
	var class_note := ""
	if dest.get_extension().to_lower() == "gd":
		for twin: String in twins:
			var cls := _class_name_of_script(twin)
			if cls != "":
				class_note = "%s declares the global class `%s`, so a second file with the same name would collide with it. " % [twin, cls]
				break
	if twins.size() == 1:
		return "Error: nothing was written — %s does not exist yet, but a file named \"%s\" already exists at %s. You most likely meant to change THAT file: write to %s instead (or use edit_file to change part of it). %sIf you truly intend a SEPARATE second file that happens to share the name, re-send with force:true." % [dest, dest.get_file(), twins[0], twins[0], class_note]
	return "Error: nothing was written — %s does not exist yet, but %d files named \"%s\" already exist: %s. You most likely meant to change one of them: write to the one you meant instead. %sIf you truly intend yet another separate file with the same name, re-send with force:true." % [dest, twins.size(), dest.get_file(), ", ".join(twins), class_note]


## The global class_name a .gd file declares, or "" — a shallow textual scan of the leading lines (the declaration is always near the top and precedes any func), enough to warn about a duplicate-class collision without a full parse.
static func _class_name_of_script(res_path: String) -> String:
	var text := FileAccess.get_file_as_string(res_path)
	if text == "":
		return ""
	for line: String in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("class_name "):
			return stripped.substr("class_name ".length()).strip_edges().split(" ")[0].split("\t")[0]
		if stripped.begins_with("func ") or stripped.begins_with("static func "):
			break
	return ""


## Write a whole text file at `args.path` — new or replacing an existing one wholesale — creating missing directories; the creation counterpart to _edit_file, sharing its writer, .gd validation, and editor refresh. The file is KEPT even when its content fails the parse or load check: the errors come back with orders to fix them at once, and the write marks the path seen in the session's ledger since the model authored every byte. The destination is taken literally (a new file can't be resolved), except that a bare name matching an existing file resolves to it so a replacement needn't spell the full path. Two refusals guard against silent destruction before any disk write: a blind overwrite of an unread existing file, and a new file colliding with an existing basename (see _write_overwrite_seen_guard / _write_phantom_collision_guard) — both waived by `force`.
static func _write_file_locked(args: Dictionary, ledger: SessionLedger) -> String:
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + WRITE_FILE_USAGE
	var raw_content: Variant = _edit_file_arg_raw(args, WRITE_CONTENT_KEYS)
	if raw_content == null:
		return "Error: no content was provided. " + WRITE_FILE_USAGE
	var text := String(raw_content)
	var dest := requested
	if not dest.begins_with("res://"):
		var existing := _resolve_file_path(requested)
		if existing == "" and requested.begins_with("uid://"):
			return _file_not_found(requested)
		if existing == "":
			# A name several files share must not silently become a new file at res:// root — the model almost certainly meant one of them.
			var same := _find_all_by_name("res://", requested.get_file())
			if same.size() > 1:
				return "Error: %d files in the project are named \"%s\": %s. Pass the full res:// path of the one you mean, or a full new path to create another." % [same.size(), requested.get_file(), ", ".join(same)]
		dest = existing if existing != "" else "res://" + requested.trim_prefix("./").trim_prefix("/")
	if dest.get_extension() == "":
		return "Error: \"%s\" has no file extension — include one so the editor knows what the file is, e.g. \"res://notes/design.md\"." % dest
	var exists := FileAccess.file_exists(dest)
	var force := _arg_bool(args, WRITE_FORCE_KEYS)
	# Refuse before any disk mutation: a blind overwrite of an unread file, or a new file colliding with an existing basename, are the two ways write_file silently destroys or shadows the wrong file.
	if exists:
		var overwrite_refusal := _write_overwrite_seen_guard(dest, ledger, force)
		if overwrite_refusal != "":
			return overwrite_refusal
	else:
		var collision_refusal := _write_phantom_collision_guard(dest, force)
		if collision_refusal != "":
			return collision_refusal
	var original := FileAccess.get_file_as_string(dest) if exists else ""
	var dir := dest.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return "Error: couldn't create the directory %s (%s)." % [dir, error_string(made)]
	var uid_note := ""
	if dest.get_extension().to_lower() in ["tscn", "tres"]:
		var uid_fix := _lint_written_uid(dest, text, ledger)
		if not uid_fix.is_empty():
			text = String(uid_fix["text"])
			uid_note = String(uid_fix["note"])
	if dest.get_extension().to_lower() in ["gd", "tscn", "tres"]:
		var ref_fix := _lint_new_uid_refs(dest, original, text, ledger)
		if String(ref_fix["error"]) != "":
			return String(ref_fix["error"])
		text = String(ref_fix["text"])
		uid_note += String(ref_fix["notes"])
	if not _edit_file_write(dest, text):
		return _file_write_error(dest, "the file")
	var uid_mint_note := ""
	if SIDECAR_UID_EXTENSIONS.has(dest.get_extension().to_lower()) and not FileAccess.file_exists(dest + ".uid"):
		# The editor mints these uids on its async rescan and headless never does — until then a reference to the new file's uid reads as invented, so the sidecar is minted here and the id registered immediately.
		var minted_uid := ResourceUID.create_id()
		var sidecar := FileAccess.open(dest + ".uid", FileAccess.WRITE)
		if sidecar != null:
			sidecar.store_string(ResourceUID.id_to_text(minted_uid) + "\n")
			sidecar.close()
			# Registered only once the sidecar is on disk: an id without one dies with this process and the next rescan mints a different one, so handing it out would report a uid that stops resolving.
			ResourceUID.add_id(minted_uid, dest)
		else:
			uid_mint_note = "\nNOTE: the .uid sidecar for %s could not be written, so it has no uid yet — reference it by its res:// path; the editor will mint a uid on its next filesystem scan." % dest
	_mark_seen(dest, true, ledger) # the model authored this exact content, so follow-up edits are grounded
	# The file now holds only model-authored text; content that itself carries elidable payloads disarms STICKY (false), so a later elided view of what the model wrote can't re-arm the gate its author already cleared.
	if _elide_packed_arrays(text) != text:
		ledger.elided_files[dest] = false
	else:
		ledger.elided_files.erase(dest)
	if exists:
		ledger.previous_contents[dest] = original
	var verb := "Overwrote" if exists else "Created"
	var saved := "%s %s (%d lines, %d characters)" % [verb, dest, text.split("\n").size(), text.length()]
	var lint_note := ""
	var checked := ""
	var prop_note := ""
	var validated := true
	if CHECKABLE_SOURCE_EXTENSIONS.has(dest.get_extension().to_lower()):
		# An overwrite diffs against the previous content like edit_file; a brand-new file owns every error the located check attributes to it, so the baseline runs are skipped.
		var check: Dictionary
		if exists:
			check = await _edit_file_validate_gd(dest, original, text)
		else:
			check = await _write_file_new_gd_check(dest)
		if bool(check["restore_failed"]):
			# Validation swapped the previous content onto disk and could not swap the new content back; "Overwrote" would be a lie about disk state, so disk truth overrides every other verdict.
			ledger.previous_contents.erase(dest)
			_edit_file_refresh_editor(dest)
			var restore_findings := ""
			if not check["new_parse"].is_empty():
				restore_findings = " Validation of the unsaved content found %d new parse/compile error(s) — correct them as you re-send:\n%s" % [check["new_parse"].size(), "\n".join(PackedStringArray(_grouped_problem_lines(check["new_parse_located"])))]
			return "Error: the write could NOT be kept on disk — validation temporarily swaps the previous content onto the file, and writing the new content back failed twice, so %s on disk now holds its PREVIOUS content and this write is NOT saved. Is the file read-only, locked by another program, or the disk full? Re-send the same write_file call once the file is writable, and tell the user the file briefly reverted.%s" % [dest, restore_findings]
		if not bool(check["checked"]):
			# A dead validation subprocess proves nothing either way; claiming "engine-checked" here once told both parties a possibly-broken script was verified clean.
			validated = false
			checked = " — but the engine validation run %s, so the write is UNVALIDATED: nothing is known about whether it %s. Validation appears to be down right now: do NOT re-run checks; continue at your best effort and tell the user this write went unvalidated so they can verify it themselves" % [String(check["why"]), _source_clean_verb(dest)]
		else:
			if not check["new_parse"].is_empty():
				_edit_file_refresh_editor(dest)
				var noise := _foreign_noise_note(check["foreign"], dest)
				# The same second witness edit_file consults: an error set already reported this run is not fresh work of this write. Only the accusing verdict below adds to broken_files — see the edit_file counterpart.
				if exists and String(ledger.auto_check_reports.get(dest, "")) == _error_set_fingerprint(check["post_errors"]):
					if ledger.broken_files.has(dest):
						return "%s. The content still carries the same %d parse/compile error(s) YOUR earlier edit introduced this editor run — this write added none, but they remain unfixed and fixing them is still your top priority; run check_script on it if you need the full list again.%s" % [saved, check["post_errors"].size(), noise]
					return "%s. The content still carries the same %d parse/compile error(s) last reported this editor run — unchanged and likely pre-existing, NOT introduced by this write; run check_script on it if you need the full list again.%s" % [saved, check["post_errors"].size(), noise]
				var located: Array = check["new_parse_located"]
				if not bool(check["parse_attributed"]):
					# The baseline run died, so the diff that would prove blame doesn't exist; the full list is reported with attribution honestly unknown instead of inflated into an accusation.
					return "%s, but the content has %d parse/compile error(s) — the %s is BROKEN on disk until they are fixed. The pre-edit baseline check %s, so it is unknown which of these this write introduced and which were already there; fix them NOW with edit_file calls, before any other work:\n%s%s%s%s%s" % [saved, check["new_parse"].size(), _source_noun(dest), String(check["why"]), "\n".join(PackedStringArray(_grouped_problem_lines(located))), _edit_file_error_excerpts(text, located), _uid_error_attribution(located, ledger), _shader_stop_note(dest, located), noise]
				ledger.broken_files[dest] = true
				if _all_errors_in_includes(located):
					# The same correction the edit_file verdict makes: the content that was sent is not what is wrong, the file it reaches for is.
					return "%s, but the %s does not compile: the %d error(s) below are in a file it #includes, which this write did not touch — reaching that file is what surfaced them. Fix them THERE, before any other work:\n%s%s%s" % [saved, _source_noun(dest), located.size(), "\n".join(PackedStringArray(_grouped_problem_lines(located))), _shader_stop_note(dest, located), noise]
				return "%s, but the content has %d parse/compile error(s) — the %s is BROKEN on disk until they are fixed. The file holds exactly the content you just sent; YOU introduced these errors, so fix them NOW with edit_file calls, before any other work:\n%s%s%s%s%s" % [saved, check["new_parse"].size(), _source_noun(dest), "\n".join(PackedStringArray(_grouped_problem_lines(located))), _edit_file_error_excerpts(text, located), _uid_error_attribution(located, ledger), _shader_stop_note(dest, located), noise]
			if not check["new_lint"].is_empty():
				if bool(check["lint_attributed"]):
					lint_note = "\n\nNote: the file was written, but it has %d style-lint problem(s) you may want to fix:\n%s" % [check["new_lint"].size(), "\n".join(PackedStringArray(_grouped_problem_lines(check["new_lint"])))]
				else:
					lint_note = "\n\nNote: the file was written, but it has %d style-lint problem(s) — the pre-edit baseline lint did not finish, so how many this write introduced is unknown:\n%s" % [check["new_lint"].size(), "\n".join(PackedStringArray(_grouped_problem_lines(check["new_lint"])))]
			elif not bool(check["lint_checked"]):
				lint_note = "\n\nNote: the style-lint run %s, so lint problems were not checked this time." % String(check["lint_why"])
			# Transcripts show every strong-model session re-verifying clean writes with check_script batches and re-reads because nothing said the check already ran; gated on the post check so unchanged pre-existing damage earns no clean bill.
			if bool(check["post_clean"]):
				checked = " — %s cleanly (engine-checked)" % _source_clean_verb(dest)
				ledger.auto_check_reports.erase(dest)
	elif dest.get_extension().to_lower() in ["tscn", "tres"]:
		# The load check mirrors the .gd flow: an overwrite diffs against the previous content, a brand-new file owns every error and every unknown-property warning.
		var res_check: Dictionary
		if exists:
			res_check = await _edit_file_validate_resource(dest, original, text)
		else:
			var report: Dictionary = await _edit_file_load_report(dest)
			if bool(report["ok"]):
				res_check = _resource_check_shape({
					"checked": true,
					"new_load": (report["errors"] as Array).map(func(e: Dictionary) -> String: return String(e["line"])),
					"post_clean": (report["errors"] as Array).is_empty(),
					"new_prop_warns": report["prop_warns"],
				})
			else:
				res_check = _resource_check_shape({"why": String(report["why"])})
		if bool(res_check["restore_failed"]):
			# The same disk-truth override as the .gd path above.
			ledger.previous_contents.erase(dest)
			_edit_file_refresh_editor(dest)
			var restore_findings := ""
			if not res_check["new_load"].is_empty():
				restore_findings = " Validation of the unsaved content found %d new load error(s) — correct them as you re-send:\n%s" % [res_check["new_load"].size(), "\n".join(PackedStringArray(res_check["new_load"]))]
			return "Error: the write could NOT be kept on disk — validation temporarily swaps the previous content onto the file, and writing the new content back failed twice, so %s on disk now holds its PREVIOUS content and this write is NOT saved. Is the file read-only, locked by another program, or the disk full? Re-send the same write_file call once the file is writable, and tell the user the file briefly reverted.%s" % [dest, restore_findings]
		if not bool(res_check["checked"]):
			validated = false
			checked = " — but the engine validation run %s, so the write is UNVALIDATED: nothing is known about whether the file loads. Validation appears to be down right now: do NOT re-run checks; tell the user this write went unvalidated so they can verify it themselves" % String(res_check["why"])
		else:
			var new_load: Array = res_check["new_load"]
			if not new_load.is_empty():
				_edit_file_refresh_editor(dest)
				var blame := "The file holds exactly the content you just sent; fix it NOW with edit_file before any other work."
				var header := "Errors:"
				if bool(res_check["attributed"]):
					ledger.broken_files[dest] = true
				else:
					# The baseline run died, so whether this write introduced the damage is unknown; the verdict lists everything without the accusation.
					blame = "The pre-edit baseline check %s, so it is unknown which of these errors this write introduced; fix them NOW regardless — the file is unusable until it loads." % String(res_check["why"])
					header = "Errors (possibly including pre-existing ones):"
				return "%s, but it does not load as a resource — it is BROKEN on disk until you fix it, and an open tab showing it was NOT reloaded while broken. %s Hand-writing serialized scene/resource text is fragile — prefer create_resource for resources, and for scenes copy existing serialized text verbatim from read_file rather than inventing it.\n\n%s\n%s%s%s%s" % [saved, blame, header, "\n".join(PackedStringArray(new_load)), _edit_file_load_excerpts(text, new_load, dest), _uid_error_attribution(new_load, ledger), uid_note]
			if bool(res_check["post_clean"]):
				checked = " — loads cleanly (engine-checked)"
			prop_note = _dropped_property_note(res_check["new_prop_warns"])
	# A verdict that never ran proves nothing about a file an earlier edit left broken, so the ledger only settles on a real check.
	if validated:
		ledger.broken_files.erase(dest)
	_edit_file_refresh_editor(dest)
	var reload_note := _edit_file_reload_open_scene(dest) if exists else ""
	var uid_clause := ""
	if dest.get_extension().to_lower() in ["tscn", "tres"] or SIDECAR_UID_EXTENSIONS.has(dest.get_extension().to_lower()):
		# Transcripts show models re-reading a fresh .tres solely to harvest its header uid for a preload — and one inventing a uid to control it; the confirmation now carries the engine truth, for the sidecar kinds too since their uid is minted above.
		var uid_text := _uid_text_for(dest)
		if uid_text != "":
			uid_clause = "; its uid is %s" % uid_text
	return "%s%s%s.%s%s%s%s%s%s" % [saved, checked, uid_clause, prop_note, lint_note, reload_note, uid_note, uid_mint_note, _import_write_note(dest)]


## Refuse a delete target that escapes the project or is too critical to remove, returning "" when the path is safe to delete — the containment boundary the reference scan is not.
## _resolve_file_path will still resolve a res://../ traversal or a user:// path (FileAccess resolves ".." and user:// against the real filesystem), so the escape is caught HERE by globalizing the resolved path and the project root and refusing anything that lands outside the root; a bare "force" can't override it because containment is checked before force is ever consulted.
## project.godot, the .godot editor cache, and the .git store define the project, its import state, and its history — deleting into them corrupts state the trash can't cleanly restore, so they are refused even under force.
static func _delete_target_guard(resolved: String) -> String:
	var root := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var abs := ProjectSettings.globalize_path(resolved).simplify_path()
	if abs != root and not abs.begins_with(root + "/"):
		return "Error: %s resolves to %s, OUTSIDE the project directory — delete_file only removes files under res://. A path with \"..\" segments or a user:// path is refused so a deletion can never escape the project." % [resolved, abs]
	var rel := abs.substr(root.length() + 1)
	if rel == "project.godot" or rel.begins_with(".godot/") or rel.begins_with(".git/"):
		return "Error: %s is a critical project file (the project definition, the editor cache, or version-control history) and is never deleted, even with force — removing it would corrupt state the system trash can't cleanly restore. Leave it in place." % resolved
	if _symlink_in_path(root, rel):
		return "Error: %s reaches its target through a symbolic link in its path — delete_file will not follow a link, since a symlinked directory points its real file OUTSIDE the project even while the path above reads as contained. Delete the real file by its actual path instead." % resolved
	return ""


## Whether any component of `rel` (a path relative to the project `root`) is a symbolic link, the containment escape the string check above can't see.
## The globalized res:// path is compared to the root as text, but a symlinked directory anywhere in the path points its real inode elsewhere, so a delete THROUGH it still lands outside the project; Godot exposes no realpath, so this walks the path from the root outward and reports a link in ANY component.
## is_link flags only the component that is itself the link — not a file reached through it — so the whole chain is checked, not just the leaf; it fails closed, refusing a legitimate in-project symlink too rather than guessing where it leads.
## DirAccess.is_link reads the OS's link/reparse-point attribute, so this covers POSIX symlinks and, on Windows, symlinks and junctions alike.
static func _symlink_in_path(root: String, rel: String) -> bool:
	var da := DirAccess.open(root)
	if da == null:
		return false
	var walk := root
	for part in rel.split("/", false):
		walk = walk.path_join(part)
		if da.is_link(walk):
			return true
	return false


## Delete one project file, trash-first so the user can recover it, refusing while other files still reference it (see the registry description). The reference scan reuses _dependent_mentions — path/uid references plus, for a .gd, whole-word mentions of its global class_name — so refusal and forced-delete warning name exactly the files a break would land in. The vetting here runs BEFORE the mutation lock is taken: the scan goes through run_on_worker, whose entry waits out _mutation_busy, so scanning under our own hold would deadlock the editor's tool loop — and its scan counter already keeps concurrent mutations out for the scan's duration (see _acquire_mutation_lock).
static func _delete_file(args: Dictionary, ledger: SessionLedger) -> String:
	var unexpected := _unexpected_arg_error(args, FILE_PATH_KEYS + DELETE_FORCE_KEYS, DELETE_FILE_USAGE)
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + DELETE_FILE_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		if DirAccess.dir_exists_absolute(requested) and requested.begins_with("res://"):
			return "Error: %s is a directory — delete_file takes exactly one file. Delete its files individually so each removal is deliberate." % requested
		return _file_not_found(requested)
	var containment := _delete_target_guard(resolved)
	if containment != "":
		return containment
	var class_word := ""
	if resolved.get_extension().to_lower() == "gd":
		class_word = String(_script_declarations(FileAccess.get_file_as_string(resolved))["class_name"])
	var mentions: Dictionary = await _dependent_mentions(resolved, class_word, true)
	var references := "\n".join(mentions["lines"])
	if int(mentions["total"]) > 0 and not _arg_bool(args, DELETE_FORCE_KEYS):
		return "Error: %s was NOT deleted — %d file(s) still reference it and would break:\n%s\nUpdate those references first, or pass \"force\": true to delete it anyway, knowingly breaking them. (The scan is engine records plus text match; a dynamically assembled path can't be seen.)" % [resolved, int(mentions["total"]), references]
	await _acquire_mutation_lock()
	var result: String = _delete_file_locked(resolved, ledger, int(mentions["total"]), references)
	_mutation_busy = false
	return result


## Remove the already-vetted file under the mutation lock, the same serialization as _edit_file's; `mention_total`/`references` carry the pre-lock scan's findings for the forced-delete warning.
static func _delete_file_locked(resolved: String, ledger: SessionLedger, mention_total: int, references: String) -> String:
	# Trash first so the user can recover the file; only a platform without one gets a permanent remove, and the result names which happened.
	var trashed := OS.move_to_trash(ProjectSettings.globalize_path(resolved)) == OK
	if not trashed:
		var removed := DirAccess.remove_absolute(resolved)
		if removed != OK:
			return "Error: could not delete %s (%s)." % [resolved, error_string(removed)]
	var sidecars := PackedStringArray()
	var sidecar_failures := PackedStringArray()
	for sidecar in [resolved + ".uid", resolved + ".import"]:
		if FileAccess.file_exists(sidecar):
			# Trash-first like the file itself; a sidecar both attempts fail on lands in the failure list so the result never claims a removal that didn't happen.
			if OS.move_to_trash(ProjectSettings.globalize_path(sidecar)) == OK or DirAccess.remove_absolute(sidecar) == OK:
				sidecars.append(sidecar.get_file())
			else:
				sidecar_failures.append(sidecar.get_file())
	# The file no longer exists, so every per-path claim about it — seen text, elided payloads, edit history, broken verdicts, collapsed check reports — is settled, not carried forward onto a future file at the same path.
	ledger.seen_files.erase(resolved)
	ledger.elided_files.erase(resolved)
	ledger.previous_contents.erase(resolved)
	ledger.auto_check_reports.erase(resolved)
	ledger.broken_files.erase(resolved)
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			# update_file also handles a path that vanished; scan_sources drops a deleted class_name from the global class list.
			fs.update_file(resolved)
			fs.scan_sources()
	var sidecar_note := "" if sidecars.is_empty() else " along with its %s sidecar file(s)" % ", ".join(sidecars)
	var how := "moved to the system trash, so the user can recover it" if trashed else "permanently removed — this platform offered no trash to recover it from"
	var out := "Deleted %s%s (%s)." % [resolved, sidecar_note, how]
	if not sidecar_failures.is_empty():
		out += "\nWARNING: its %s sidecar file(s) could NOT be removed and remain on disk — delete them manually if they should go too." % ", ".join(sidecar_failures)
	if mention_total > 0:
		out += "\nWARNING: you forced this deletion while %d file(s) still reference it — they are broken until you update them:\n%s" % [mention_total, references]
	return out


## Refuse a two-endpoint file operation's endpoint when it escapes the project or touches its critical stores, "" when safe — _delete_target_guard's containment fence applied to BOTH endpoints, so neither a move nor a copy can carry a file across the project boundary in either direction. `verb` names the operation in the refusals, since a message that says "move" during a copy is a lie the model repeats to the user.
## The destination may not exist yet; every check here is string- or component-based (a nonexistent component is simply not a link), so it guards a path about to be created as well as one on disk.
static func _path_boundary_guard(candidate: String, role: String, verb := "move") -> String:
	var root := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var abs := ProjectSettings.globalize_path(candidate).simplify_path()
	if abs == root or not abs.begins_with(root + "/"):
		return "Error: the %s %s resolves to %s, OUTSIDE the project directory — a %s only ever runs between two res:// locations inside the project, never in from or out to anywhere else. A path with \"..\" segments or a user:// path is refused so a %s can never cross the project boundary." % [role, candidate, abs, verb, verb]
	var rel := abs.substr(root.length() + 1)
	if rel == "project.godot" or rel.begins_with(".godot/") or rel.begins_with(".git/"):
		return "Error: the %s %s is (or sits inside) a critical project store — the project definition, the editor cache, or version-control history — which no %s ever reads from or writes into; doing so would corrupt state no %s can cleanly restore. Choose a different %s." % [role, candidate, verb, verb, role]
	if _symlink_in_path(root, rel):
		return "Error: the %s %s reaches its target through a symbolic link in its path — a %s will not follow a link, since a symlinked directory points its real files OUTSIDE the project even while the path above reads as contained. Use the real path instead." % [role, candidate, verb]
	return ""


## How one resource file's dependency records relate to `target` moving: "path" when at least one reference leans on the literal path alone (it breaks), "uid" when every reference carries the file's resolvable uid (the loader follows the uid, and only the recorded path fallback goes stale), "-" for no reference.
static func _deps_move_dependence(path: String, target: String, uid_text: String) -> String:
	var kind := "-"
	for entry in ResourceLoader.get_dependencies(path):
		var parsed := _parse_dependency_entry(String(entry))
		if uid_text != "" and String(parsed["uid"]) == uid_text:
			if kind != "path":
				kind = "uid"
		elif String(parsed["path"]) == target:
			kind = "path"
	return kind


## The move counterpart of _dependent_mentions_scan, classifying every reference to `resolved` by whether it survives the file moving: a reference through the file's uid follows it (the uid travels with the file and the registry is retargeted), so only literal-path references land in `breaking`; a global class_name binds to no path at all and is not scanned. Returns {"breaking": Array of "- path (why)" lines capped like the delete scan's, "breaking_total": int, "surviving": int}.
static func _move_reference_scan(resolved: String, uid_text: String) -> Dictionary:
	var files: Array = []
	_collect_text_files("res://", files)
	var breaking: Array = []
	var surviving := 0
	for path_v in files:
		var path := String(path_v)
		if path == resolved:
			continue
		var ext := path.get_extension().to_lower()
		var is_resource := DEP_RESOURCE_EXTENSIONS.has(ext)
		if ext != "gd" and not is_resource and path.get_file() != "project.godot":
			continue
		if is_resource:
			var kind := _deps_move_dependence(path, resolved, uid_text)
			if kind == "path":
				breaking.append("- %s (references the old path with no uid to fall back on)" % path)
			elif kind == "uid":
				surviving += 1
		else:
			var text := FileAccess.get_file_as_string(path)
			if text.contains(resolved):
				breaking.append("- %s (%s)" % [path, "project settings reference the literal path" if path.get_file() == "project.godot" else "references the literal path"])
			elif uid_text != "" and text.contains(uid_text):
				surviving += 1
	var total := breaking.size()
	if total > GDLLMTunables.geti(GDLLMTunables.DEPENDENT_MENTIONS_CAP):
		breaking = breaking.slice(0, GDLLMTunables.geti(GDLLMTunables.DEPENDENT_MENTIONS_CAP))
		breaking.append("(and %d more — search_files for the rest)" % (total - GDLLMTunables.geti(GDLLMTunables.DEPENDENT_MENTIONS_CAP)))
	return {"breaking": breaking, "breaking_total": total, "surviving": surviving}


## Move one project file to a new res:// location, rename_file's `rename_only` form constraining the destination to the file's own directory. Containment is vetted at BOTH endpoints before anything else (see _path_boundary_guard) — that fence is the tool's safety contract and force never crosses it. Like delete_file, the reference vetting runs BEFORE the mutation lock is taken (see the deadlock note there): literal-path references refuse without force, while uid references survive because the file's uid travels with it.
static func _move_file(args: Dictionary, ledger: SessionLedger, rename_only: bool) -> String:
	var tool_name := "rename_file" if rename_only else "move_file"
	var usage := RENAME_FILE_USAGE if rename_only else MOVE_FILE_USAGE
	var dest_keys := RENAME_NAME_KEYS if rename_only else MOVE_DEST_KEYS
	var unexpected := _unexpected_arg_error(args, FILE_PATH_KEYS + dest_keys + MOVE_FORCE_KEYS, usage)
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + usage
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		if DirAccess.dir_exists_absolute(requested) and requested.begins_with("res://"):
			return "Error: %s is a directory — %s takes exactly one file, so move its files individually." % [requested, tool_name]
		return _file_not_found(requested)
	var guard := _path_boundary_guard(resolved, "source file")
	if guard != "":
		return guard
	var dest_raw := _arg_string(args, dest_keys)
	if dest_raw == "":
		return "Error: no %s was provided. %s" % ["new name" if rename_only else "destination", usage]
	var dest := ""
	if rename_only:
		var new_name := dest_raw.trim_prefix("res://").trim_prefix("./")
		if new_name.contains("/"):
			# A full path is tolerated when it names the file's own directory; anything else is a move, and saying so beats guessing.
			if ("res://" + new_name.trim_prefix("/")).get_base_dir() != resolved.get_base_dir():
				return "Error: \"%s\" points outside %s's own directory — rename_file only changes the file's NAME in place. Use move_file to change its location." % [dest_raw, resolved]
			new_name = new_name.get_file()
		if new_name == "":
			return "Error: no new name was provided. " + RENAME_FILE_USAGE
		dest = resolved.get_base_dir().path_join(new_name)
	else:
		dest = dest_raw
		if dest.begins_with("user://") or dest.begins_with("uid://"):
			return "Error: the destination must be a res:// location inside the project — a %s destination is refused so a move can never leave it (and a uid names an existing file, not a new place)." % dest.substr(0, 6)
		if not dest.begins_with("res://"):
			dest = "res://" + dest.trim_prefix("./").trim_prefix("/")
		if dest.ends_with("/") or DirAccess.dir_exists_absolute(dest):
			dest = dest.trim_suffix("/").path_join(resolved.get_file())
	dest = dest.simplify_path()
	if dest == resolved:
		return "Error: %s already has that %s — there is nothing to do." % [resolved, "name" if rename_only else "location"]
	if dest.get_extension() == "":
		return "Error: \"%s\" has no file extension — pass the full destination file name (or, with move_file, end a directory destination with \"/\")." % dest
	guard = _path_boundary_guard(dest, "destination")
	if guard != "":
		return guard
	if FileAccess.file_exists(dest) or DirAccess.dir_exists_absolute(dest):
		return "Error: something already exists at %s — a move never overwrites. Choose a different destination, or delete_file the existing file first if replacing it is truly intended." % dest
	for sidecar_ext: String in [".uid", ".import"]:
		if FileAccess.file_exists(resolved + sidecar_ext) and FileAccess.file_exists(dest + sidecar_ext):
			return "Error: %s already exists — the file's %s sidecar moves with it, and a move never overwrites. Choose a different destination." % [dest + sidecar_ext, sidecar_ext]
	if Engine.is_editor_hint() and resolved.get_extension().to_lower() in ["tscn", "scn"] and resolved in EditorInterface.get_open_scenes():
		return "Error: %s is open in the editor — a save of that open tab would recreate the file at its old path, splitting the scene in two. Ask the user to close it (or move it themselves in the FileSystem dock, which retargets the tab), then retry." % resolved
	var uid_text := _uid_text_for(resolved)
	var scan: Dictionary = await run_on_worker(func() -> Dictionary: return _move_reference_scan(resolved, uid_text))
	if not (scan["breaking"] as Array).is_empty() and not _arg_bool(args, MOVE_FORCE_KEYS):
		return "Error: %s was NOT %s — %d file(s) still reference its current path by literal text and would break:\n%s\nUpdate those references first (edit_file for scripts and scenes, set_project_setting for autoloads and other settings), then retry — or pass \"force\": true to proceed anyway, knowingly breaking them. References through the file's uid are safe: they follow the move. (The scan is engine records plus text match; a dynamically assembled path can't be seen.)" % [resolved, "renamed" if rename_only else "moved", int(scan["breaking_total"]), "\n".join(scan["breaking"])]
	await _acquire_mutation_lock()
	var result: String = _move_file_locked(resolved, dest, ledger, scan, uid_text, "Renamed" if rename_only else "Moved")
	_mutation_busy = false
	return result


## Perform the already-vetted move under the mutation lock: the file first, then its sidecars, a moved .import's own source-path entry rewritten to the new path, the uid registry retargeted so uid:// references keep resolving in this process, the ledger's per-path claims carried to the new path (the bytes on disk are unchanged, so what was seen stays seen), and the editor's filesystem told about both ends. `scan` carries the pre-lock reference findings for the forced-move warning and the surviving-uid count.
static func _move_file_locked(resolved: String, dest: String, ledger: SessionLedger, scan: Dictionary, uid_text: String, verb: String) -> String:
	var dest_dir := dest.get_base_dir()
	if not DirAccess.dir_exists_absolute(dest_dir):
		var made := DirAccess.make_dir_recursive_absolute(dest_dir)
		if made != OK:
			return "Error: couldn't create the directory %s (%s)." % [dest_dir, error_string(made)]
	var moved := DirAccess.rename_absolute(resolved, dest)
	if moved != OK:
		return "Error: could not move %s to %s (%s). Nothing was changed." % [resolved, dest, error_string(moved)]
	var notes := PackedStringArray()
	var sidecars := PackedStringArray()
	for sidecar_ext: String in [".uid", ".import"]:
		if not FileAccess.file_exists(resolved + sidecar_ext):
			continue
		if DirAccess.rename_absolute(resolved + sidecar_ext, dest + sidecar_ext) == OK:
			sidecars.append((resolved + sidecar_ext).get_file())
		else:
			notes.append("WARNING: its %s sidecar could NOT be moved and remains at %s — move it manually so the file keeps its identity." % [sidecar_ext, resolved + sidecar_ext])
	if FileAccess.file_exists(dest + ".import"):
		# The .import names its own asset; left stale, the editor would treat the moved asset as never imported and the old entry as an orphan.
		var import_text := FileAccess.get_file_as_string(dest + ".import")
		if import_text.contains("\"" + resolved + "\""):
			var import_file := FileAccess.open(dest + ".import", FileAccess.WRITE)
			if import_file != null:
				import_file.store_string(import_text.replace("\"" + resolved + "\"", "\"" + dest + "\""))
				import_file.close()
				notes.append("Its .import metadata was retargeted to the new path; the editor re-imports the asset on its next filesystem scan.")
	if uid_text != "":
		var id := ResourceUID.text_to_id(uid_text)
		if id != ResourceUID.INVALID_ID:
			# Retargeted immediately: the next rescan would heal it anyway, but until then every uid:// reference in this process would resolve to the old path.
			if ResourceUID.has_id(id):
				ResourceUID.set_id(id, dest)
			else:
				ResourceUID.add_id(id, dest)
	for claims: Dictionary in [ledger.seen_files, ledger.elided_files, ledger.previous_contents, ledger.auto_check_reports, ledger.broken_files]:
		if claims.has(resolved):
			claims[dest] = claims[resolved]
			claims.erase(resolved)
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.update_file(resolved)
			fs.update_file(dest)
			fs.scan_sources()
		var script_editor := EditorInterface.get_script_editor()
		if script_editor != null:
			for script in script_editor.get_open_scripts():
				if script != null and script.resource_path == resolved:
					notes.append("NOTE: the file is open in the script editor under its OLD path — reopen it from %s before editing there; saving the stale tab would recreate the old file." % dest)
					break
	var out := "%s %s to %s" % [verb, resolved, dest]
	if not sidecars.is_empty():
		out += ", its %s sidecar file(s) moving with it" % ", ".join(sidecars)
	if uid_text != "":
		out += "; its uid %s is unchanged, so uid:// references keep resolving" % uid_text
	out += "."
	if dest.get_extension().to_lower() != resolved.get_extension().to_lower():
		notes.append("WARNING: the file's extension changed from .%s to .%s — the editor decides what a file IS by its extension, so it is now treated as a different kind of file." % [resolved.get_extension(), dest.get_extension()])
	if int(scan["surviving"]) > 0:
		notes.append("%d file(s) reference it only by uid and keep working; any recorded path= fallback text in them is stale until the editor next saves them." % int(scan["surviving"]))
	if int(scan["breaking_total"]) > 0:
		notes.append("WARNING: you forced this %s while %d file(s) still reference the OLD path by literal text — they are broken until you update them:\n%s" % ["rename" if verb == "Renamed" else "move", int(scan["breaking_total"]), "\n".join(scan["breaking"])])
	for note in notes:
		out += "\n" + note
	return out


## Duplicate one project file at a new res:// path — the FileSystem dock's Duplicate, and the only route to a copy of a BINARY asset, whose bytes no text tool can reproduce. Containment is vetted at BOTH endpoints before anything is written (see _path_boundary_guard). Unlike move_file and delete_file there is no reference scan: a copy adds a file rather than moving or removing one, so no existing reference can break and nothing needs updating afterwards.
static func _copy_file(args: Dictionary, ledger: SessionLedger) -> String:
	var unexpected := _unexpected_arg_error(args, COPY_SOURCE_KEYS + COPY_DEST_KEYS, COPY_FILE_USAGE)
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, COPY_SOURCE_KEYS)
	if requested == "":
		return "Error: no path was provided. " + COPY_FILE_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		if DirAccess.dir_exists_absolute(requested) and requested.begins_with("res://"):
			return "Error: %s is a directory — copy_file duplicates exactly one file. List it with list_directory and copy its files one at a time, naming each destination, so every new file is deliberate." % requested
		return _file_not_found(requested)
	var guard := _path_boundary_guard(resolved, "source file", "copy")
	if guard != "":
		return guard
	guard = _hidden_dir_guard(resolved)
	if guard != "":
		return guard
	var dest := _arg_string(args, COPY_DEST_KEYS)
	if dest == "":
		return "Error: no destination was provided. " + COPY_FILE_USAGE
	if dest.begins_with("user://") or dest.begins_with("uid://"):
		return "Error: the destination must be a res:// location inside the project — a %s destination is refused so a copy can never leave it (and a uid names an existing file, not a new place)." % ("user://" if dest.begins_with("user://") else "uid://")
	if not dest.begins_with("res://"):
		dest = "res://" + dest.trim_prefix("./").trim_prefix("/")
	if dest.ends_with("/") or DirAccess.dir_exists_absolute(dest):
		dest = dest.trim_suffix("/").path_join(resolved.get_file())
	dest = dest.simplify_path()
	if dest == resolved:
		return "Error: %s is its own destination — a copy needs a different path or file name (e.g. \"%s\"), since a file can't be duplicated onto itself. Nothing was written." % [resolved, resolved.get_basename() + "_copy." + resolved.get_extension()]
	if dest.get_extension() == "":
		return "Error: \"%s\" has no file extension — pass the destination's full file name, or end a directory destination with \"/\" to keep the source's name." % dest
	guard = _path_boundary_guard(dest, "destination", "copy")
	if guard != "":
		return guard
	guard = _hidden_dir_guard(dest)
	if guard != "":
		return guard
	if FileAccess.file_exists(dest) or DirAccess.dir_exists_absolute(dest):
		return "Error: something already exists at %s — a copy never overwrites, so nothing was written and both files are as they were. Copy to a different name, or delete_file what is there first if replacing it is truly intended." % dest
	for sidecar_ext: String in [".uid", ".import"]:
		if FileAccess.file_exists(dest + sidecar_ext):
			# The destination itself is free, so a sidecar sitting there is orphaned — overwriting it would hand the copy an identity that belongs to whatever wrote it.
			return "Error: %s already exists even though %s does not — the copy needs its own %s sidecar and never overwrites one. Copy to a different name, or delete_file the orphaned sidecar if nothing owns it." % [dest + sidecar_ext, dest, sidecar_ext]
	await _acquire_mutation_lock()
	var result: String = _copy_file_locked(resolved, dest, ledger)
	_mutation_busy = false
	return result


## Perform the already-vetted copy under the mutation lock: the bytes first (through DirAccess, so a binary asset survives a route no String could carry it over), then the identity work that makes the copy its OWN file. Two files must never share a uid — every uid:// reference resolves to exactly one path, so a copied uid quietly steals or loses the source's references (the clash _lint_written_uid exists to undo) — so a .tscn/.tres header uid is rewritten, a .uid sidecar is minted rather than copied, and a copied .import is given a fresh uid and its own source path. The ledger's seen/elided claims carry to a byte-identical copy, so a follow-up edit needs no re-read — but NOT to one whose header was rewritten, since that copy's exact text was never shown to anyone.
static func _copy_file_locked(resolved: String, dest: String, ledger: SessionLedger) -> String:
	var dest_dir := dest.get_base_dir()
	if not DirAccess.dir_exists_absolute(dest_dir):
		var made := DirAccess.make_dir_recursive_absolute(dest_dir)
		if made != OK:
			return "Error: couldn't create the directory %s (%s). Nothing was copied." % [dest_dir, error_string(made)]
	var copied := DirAccess.copy_absolute(resolved, dest)
	if copied != OK:
		return "Error: could not copy %s to %s (%s). Nothing was written." % [resolved, dest, error_string(copied)]
	var notes := PackedStringArray()
	var uid_clause := ""
	var header_rewritten := false
	if dest.get_extension().to_lower() in ["tscn", "tres"] and not _looks_binary(dest):
		var text := FileAccess.get_file_as_string(dest)
		var found := RegEx.create_from_string("^\\[gd_(?:scene|resource)\\b[^\\]]*?\\buid=\"(uid://[^\"]*)\"").search(text)
		if found != null:
			var fresh_id := ResourceUID.create_id()
			var fresh_text := ResourceUID.id_to_text(fresh_id)
			if not _edit_file_write(dest, text.substr(0, found.get_start(1)) + fresh_text + text.substr(found.get_end(1))):
				# A copy left carrying the source's uid is worse than no copy: both files would answer to one uid until someone noticed, so the half-made duplicate goes rather than the damage. The cause is read while the file still exists, since removing it would rewrite the diagnosis.
				var cause := _write_failure_cause(dest)
				DirAccess.remove_absolute(dest)
				return "Error: %s was copied but its header still declared %s's uid and could not be rewritten, so the copy was REMOVED rather than left sharing an identity — %s Nothing remains at %s." % [dest, resolved, cause, dest]
			ResourceUID.add_id(fresh_id, dest)
			header_rewritten = true
			uid_clause += " Its header uid is the freshly minted %s — the source keeps %s, and that one line is the copy's only difference from it." % [fresh_text, found.get_string(1)]
			if ledger.seen_files.get(resolved) == true:
				uid_clause += " A follow-up edit_file on the copy needs its own read first: the rewritten line means no read of the source matches the copy's exact text."
	if SIDECAR_UID_EXTENSIONS.has(dest.get_extension().to_lower()):
		# Minted rather than copied, and registered the moment the sidecar is on disk — the same reason write_file mints for a new file: until the editor's async rescan reaches it, a reference to the copy's uid would otherwise read as invented.
		var minted := ResourceUID.create_id()
		var sidecar := FileAccess.open(dest + ".uid", FileAccess.WRITE)
		if sidecar != null:
			sidecar.store_string(ResourceUID.id_to_text(minted) + "\n")
			sidecar.close()
			ResourceUID.add_id(minted, dest)
			uid_clause += " Its .uid sidecar was minted fresh as %s; the source's was NOT copied." % ResourceUID.id_to_text(minted)
		else:
			notes.append("NOTE: the .uid sidecar for %s could not be written, so the copy has no uid yet — reference it by its res:// path; the editor mints one on its next filesystem scan." % dest)
	if FileAccess.file_exists(resolved + ".import"):
		var import_text := FileAccess.get_file_as_string(resolved + ".import").replace("\"" + resolved + "\"", "\"" + dest + "\"")
		var fresh_id := ResourceUID.INVALID_ID
		var fresh_text := ""
		var at := import_text.find("uid=\"uid://")
		if at != -1:
			# The uid an .import declares is the imported ASSET's, so a copied one would hand the duplicate the source's identity.
			var value_start := at + 5
			var value_end := import_text.find("\"", value_start)
			if value_end > value_start:
				fresh_id = ResourceUID.create_id()
				fresh_text = ResourceUID.id_to_text(fresh_id)
				import_text = import_text.substr(0, value_start) + fresh_text + import_text.substr(value_end)
		if _edit_file_write(dest + ".import", import_text):
			if fresh_id != ResourceUID.INVALID_ID:
				ResourceUID.add_id(fresh_id, dest)
				uid_clause += " Its import settings were copied with the fresh uid %s (never the source's); the editor re-imports the copy on its next filesystem scan." % fresh_text
			else:
				uid_clause += " Its import settings were copied; the editor re-imports the copy on its next filesystem scan."
		else:
			notes.append("NOTE: the .import sidecar could not be written, so the copy has no import settings of its own — the editor imports it with this file type's DEFAULTS on its next scan, and set_import_setting can then match it to %s." % resolved)
	# The copy holds the source's bytes, so what was seen of one is seen of the other — except when the header rewrite diverged them, machine-made text nobody was shown, which forfeits the claims; the edit-history and broken-file claims are the source's own and stay there either way.
	if not header_rewritten:
		for claims: Dictionary in [ledger.seen_files, ledger.elided_files]:
			if claims.has(resolved):
				claims[dest] = claims[resolved]
	_edit_file_refresh_editor(dest)
	if dest.get_extension().to_lower() == "gd":
		var declared := _class_name_of_script(dest)
		if declared != "":
			notes.append("WARNING: both files now declare the global class `%s`, which the engine refuses to load — change or remove the copy's class_name with edit_file before anything else uses it." % declared)
	if dest.get_extension().to_lower() != resolved.get_extension().to_lower():
		notes.append("WARNING: the copy's extension is .%s where the source is .%s — the editor decides what a file IS by its extension, so the copy is treated as a different kind of file." % [dest.get_extension(), resolved.get_extension()])
	if Engine.is_editor_hint() and resolved.get_extension().to_lower() in ["tscn", "scn"] and resolved in EditorInterface.get_unsaved_scenes():
		notes.append("WARNING: %s is open in the editor with UNSAVED changes — the copy holds the file's DISK state, not the user's live edits. Ask the user to save before copying if those edits belong in the duplicate." % resolved)
	var size := 0
	var opened := FileAccess.open(dest, FileAccess.READ)
	if opened != null:
		size = opened.get_length()
		opened.close()
	var out := "Copied %s to %s (%s).%s" % [resolved, dest, String.humanize_size(size), uid_clause]
	for note in notes:
		out += "\n" + note
	return out


## Warning prepended to disk-based views of a scene that is open with unsaved changes — the user's live edits aren't on disk, and a model acting on the stale text would work against a state the user no longer has. Empty outside the editor, for non-scene files, and for a clean open scene, so the common read costs nothing.
static func _scene_divergence_note(res_path: String) -> String:
	if not Engine.is_editor_hint():
		return ""
	if not res_path.get_extension().to_lower() in ["tscn", "scn"]:
		return ""
	if not res_path in EditorInterface.get_unsaved_scenes():
		return ""
	return "NOTE: %s is open in the editor with UNSAVED changes the user has not saved. The DISK state below does not show them — see the live tree with describe_scene instead; a text edit to this file would collide with those live edits, so prefer asking the user to save or discard them first.\n\n" % res_path


## Create a new resource from `from`, apply any `properties`, and save it to `path`; returns a compact confirmation or a teaching error. The whole property batch is validated before anything is applied, so a bad value never leaves a half-set file on disk.
static func _create_res_tool(args: Dictionary) -> String:
	var from := _arg_string(args, CREATE_FROM_KEYS)
	if from == "":
		return "Error: no source was given. " + CREATE_RESOURCE_USAGE
	var dest := _arg_string(args, CREATE_PATH_KEYS)
	if dest == "":
		return "Error: no destination path was given. " + CREATE_RESOURCE_USAGE
	if not dest.begins_with("res://"):
		dest = "res://" + dest.trim_prefix("./").trim_prefix("/")
	var ext := dest.get_extension().to_lower()
	if ext != "tres" and ext != "res":
		return "Error: the destination \"%s\" must end in .tres or .res, e.g. \"res://materials/red.tres\"." % dest
	if FileAccess.file_exists(dest) and not _arg_bool(args, CREATE_OVERWRITE_KEYS):
		return "Error: a file already exists at %s — pass overwrite=true to replace it, or choose a different path." % dest
	var built := _create_res_instantiate(from)
	if built.has("error"):
		return String(built["error"])
	var resource: Resource = built["resource"]
	var applied := _create_res_apply_properties(resource, _create_res_properties_arg(args))
	if applied.has("error"):
		return String(applied["error"])
	var dir := dest.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return "Error: the folder %s could not be created (%s). Its parent may be read-only or a path segment invalid; no tool here can change that, so save under a folder that already exists or tell the user." % [dir, error_string(made)]
	var saved := ResourceSaver.save(resource, dest)
	if saved != OK:
		return "Error: the resource could not be saved to %s — %s" % [dest, _resource_save_cause(dest, saved)]
	# Register the new file with the editor so it appears in the FileSystem dock; guarded for a headless run with no editor.
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.update_file(dest)
	return _create_res_confirmation(dest, resource, String(built.get("source", "")), applied.get("applied", []), String(applied.get("note", "")))


## Build the starting resource for `from`, trying it in order as an existing resource file (deep-duplicated), a built-in Resource class, then a user script class; returns {"resource", "source"} or {"error"}.
static func _create_res_instantiate(from: String) -> Dictionary:
	var as_file := _resolve_file_path(from)
	if as_file != "":
		var ext := as_file.get_extension().to_lower()
		if ext == "tres" or ext == "res":
			var loaded: Variant = ResourceLoader.load(as_file)
			if not (loaded is Resource):
				return {"error": "Error: \"%s\" is not a loadable resource file." % as_file}
			# Deep duplication so nested sub-resources are copied, never shared with the original.
			return {"resource": (loaded as Resource).duplicate(true), "source": "deep-duplicated from %s" % as_file}
		if ext == "gd":
			return _create_res_from_script(as_file)
		return {"error": "Error: \"%s\" is a .%s file, not a resource (.tres/.res) or a Resource script (.gd)." % [as_file, ext]}
	var cls := _resolve_class_name(from)
	if cls != "":
		if not ClassDB.is_parent_class(cls, "Resource"):
			return {"error": "Error: class \"%s\" exists but does not extend Resource, so it can't be saved as a .tres. `from` must name a Resource-derived class." % cls}
		if not ClassDB.can_instantiate(cls):
			return {"error": "Error: class \"%s\" is abstract and can't be instantiated — name a concrete Resource subclass." % cls}
		var inst: Variant = ClassDB.instantiate(cls)
		if not (inst is Resource):
			return {"error": "Error: class \"%s\" could not be instantiated as a Resource." % cls}
		return {"resource": inst, "source": "new %s" % cls}
	var script_path := _create_res_global_class_path(from)
	if script_path != "":
		return _create_res_from_script(script_path)
	return {"error": _create_res_unknown_from_message(from)}


## Instantiate a Resource from a .gd script path (a global class_name's script or a direct res:// path); {"resource", "source"} or a teaching {"error"} when it isn't a Resource script. In the editor a non-@tool script reports can_instantiate() false even though a data resource built from it is perfectly valid (transcript-observed: every inline sub-resource spec against a game script failed here), so that case falls back to the editor's own New Resource construction — instantiate the native base and attach the script.
static func _create_res_from_script(script_path: String) -> Dictionary:
	var loaded: Variant = ResourceLoader.load(script_path)
	if not (loaded is Script):
		return {"error": "Error: \"%s\" is not a loadable GDScript." % script_path}
	var scr := loaded as Script
	var inst: Variant = null
	if scr.can_instantiate():
		inst = scr.new()
	else:
		# can_instantiate() is false for EVERY non-@tool script inside the editor — the false negative behind those failures — while abstract and parse-broken scripts are false everywhere. Only the editor/non-tool case falls back; the rest keep the honest error.
		# An empty instance base type is the signal the script does not compile (a compiled script always has one — see GDLLMClasses.script_for), so the two remaining causes split cleanly instead of hedging.
		if not (Engine.is_editor_hint() and not scr.is_tool()):
			if scr.get_instance_base_type() == StringName():
				return {"error": "Error: script \"%s\" does not compile, so it can't be instantiated. Run check_script on %s to see what broke." % [script_path, script_path]}
			return {"error": "Error: script \"%s\" is abstract and can't be instantiated — name a concrete Resource subclass instead." % script_path}
		var base := scr.get_instance_base_type()
		if base == StringName():
			return {"error": "Error: script \"%s\" does not compile, so it can't be instantiated. Run check_script on %s to see what broke." % [script_path, script_path]}
		if not ClassDB.is_parent_class(base, "Resource"):
			return {"error": "Error: script \"%s\" extends %s, not Resource, so it can't be saved as a .tres." % [script_path, base]}
		inst = ClassDB.instantiate(base)
		(inst as Object).set_script(scr)
	if not (inst is Resource):
		var base_class := (inst as Object).get_class() if inst is Object else "non-object"
		# A Node the script produced would otherwise leak, since only Resource is what we keep.
		if inst is Node:
			(inst as Node).queue_free()
		return {"error": "Error: script \"%s\" extends %s, not Resource, so it can't be saved as a .tres." % [script_path, base_class]}
	return {"resource": inst, "source": "new %s" % script_path}


## The script path of a project global class named `from` (case-insensitive), or "" — script classes are registered in ProjectSettings, not ClassDB.
static func _create_res_global_class_path(from: String) -> String:
	var lowered := from.to_lower()
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("class", "")).to_lower() == lowered:
			return String(entry.get("path", ""))
	return ""


## Error text for a `from` that names nothing, listing near-miss Resource classes and project script classes so a misremembered name can be corrected.
static func _create_res_unknown_from_message(from: String) -> String:
	var lowered := from.to_lower()
	var suggestions: Array[String] = []
	for c in ClassDB.get_class_list():
		if ClassDB.is_parent_class(c, "Resource") and String(c).to_lower().contains(lowered):
			suggestions.append(String(c))
	for entry in ProjectSettings.get_global_class_list():
		var gname := String(entry.get("class", ""))
		if gname.to_lower().contains(lowered) and not suggestions.has(gname):
			suggestions.append(gname)
	var msg := "Error: \"%s\" matches no resource file, Resource-extending class, or Resource script in this project." % from
	if suggestions.is_empty():
		return msg + " " + CREATE_RESOURCE_USAGE
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]


## The `properties` object from `args`, tolerant of a synonym key; {} when none is a Dictionary.
static func _create_res_properties_arg(args: Dictionary) -> Dictionary:
	for key in CREATE_PROPERTIES_KEYS:
		if args.has(key) and args[key] is Dictionary:
			return args[key]
	return {}


## Validate and coerce every entry of `props` against `resource`'s real properties, then apply them all; {"applied": [...], "note": String} lists what was set plus any script-swap disclosure, or {"error"} if any name or value is bad. A rejected batch reaches no disk — the caller returns before saving — so the two keys applied ahead of the others below cost nothing when it is.
## `script` and `shader` go FIRST because neither merely sets a value: each changes WHICH properties exist. A script re-initializes storage (applying it in JSON key order silently wiped a duplicated resource's unmentioned properties — see _apply_script_swap), and a ShaderMaterial has no shader_parameter/* at all until its shader is assigned, so judging the batch before that refused every uniform of the very shader it was being pointed at, with ClassDB's lone "shader" as the only near miss on offer (wild-measured).
static func _create_res_apply_properties(resource: Resource, props: Dictionary) -> Dictionary:
	if props.is_empty():
		return {"applied": []}
	var applied: Array = []
	var note := ""
	var remaining := props.duplicate()
	for key in ["script", "shader"]:
		var opening := _create_res_valid_properties(resource)
		if not remaining.has(key) or not opening.has(key):
			continue
		var first := _edit_res_coerce(remaining[key], opening[key])
		if not bool(first.get("ok", false)):
			return {"error": "Error: property \"%s\" %s" % [key, String(first.get("error", ""))]}
		if key == "script":
			note = _script_swap_note(_apply_script_swap(resource, first["value"], props.keys()))
		else:
			resource.set(key, first["value"])
		applied.append("%s = %s" % [key, _format_property_value(first["value"])])
		remaining.erase(key)
	var valid := _create_res_valid_properties(resource)
	var coerced: Dictionary = {}
	var order: Array = []
	var aliased: Array = []
	for raw_name in remaining.keys():
		# The same bare-uniform resolution edit_resource does, so the two tools accept the same names for the same resource.
		var pname := _edit_res_resolve_name(String(raw_name), valid)
		if pname == "":
			return {"error": _edit_res_unknown_property_message(resource, String(raw_name), valid)}
		if coerced.has(pname):
			return {"error": "Error: \"%s\" and \"%s\" are the same property (a shader uniform is settable by its bare name or its stored \"%s\" name), so this batch asks for two values at once. Send one of them." % [pname.trim_prefix(SHADER_PARAMETER_PREFIX), pname, SHADER_PARAMETER_PREFIX]}
		if pname != String(raw_name):
			aliased.append("\"%s\" was set as \"%s\"" % [raw_name, pname])
		# Delegates to edit_resource's pipeline so both resource-mutating tools coerce identically.
		var result := _edit_res_coerce(remaining[raw_name], valid[pname])
		if not bool(result.get("ok", false)):
			return {"error": "Error: property \"%s\" %s" % [pname, String(result.get("error", ""))]}
		coerced[pname] = result["value"]
		order.append(pname)
	for pname in order:
		resource.set(pname, coerced[pname])
		applied.append("%s = %s" % [pname, _format_property_value(coerced[pname])])
	return {"applied": applied, "note": note + _shader_parameter_alias_note(aliased)}


## The resource's addressable properties (storage or editor usage, excluding group/category headers), keyed by name to their property-info dict; "script" stays in, matching edit_resource, so a scripted resource can be built from a plain base class.
static func _create_res_valid_properties(resource: Resource) -> Dictionary:
	var out: Dictionary = {}
	for p in resource.get_property_list():
		var pname := String(p.get("name", ""))
		var usage := int(p.get("usage", 0))
		if pname == "":
			continue
		if not (usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)):
			continue
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		out[pname] = p
	return out


## Up to GDLLMTunables.SUGGESTION_LIST_CAP names from `candidates` that near-miss `name` (either contains the other, with a length floor on the reverse), sorted — the same rule describe_member uses.
static func _create_res_near_miss(name: String, candidates: Array) -> Array:
	var needle := name.to_lower()
	var out: Array = []
	for c in candidates:
		var lowered := String(c).to_lower()
		if lowered.contains(needle) or (lowered.length() >= 4 and needle.contains(lowered)):
			out.append(String(c))
	out.sort()
	return out.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))


## A readable type name for a created resource: its global class_name when scripted, else the engine class, noting an unnamed script's path.
static func _create_res_type_label(resource: Resource) -> String:
	var base := resource.get_class()
	var scr: Variant = resource.get_script()
	if scr is Script:
		var gname := (scr as Script).get_global_name()
		if gname != "":
			return "%s (%s)" % [gname, base]
		var spath := (scr as Script).resource_path
		if spath != "":
			return "%s (script %s)" % [base, spath]
	return base


## The compact success line: the created path, its resulting type, where it came from, its uid (engine truth — transcripts show models re-reading a fresh .tres solely to harvest the header uid for a preload), the properties that were set, and any script-swap disclosure.
static func _create_res_confirmation(dest: String, resource: Resource, source: String, applied: Array, note: String = "") -> String:
	var lines: Array = []
	var origin := "" if source == "" else " (%s)" % source
	var uid_text := _uid_text_for(dest)
	var uid_clause := "" if uid_text == "" else "; its uid is %s" % uid_text
	lines.append("Created %s — %s%s%s." % [dest, _create_res_type_label(resource), origin, uid_clause])
	if applied.is_empty():
		lines.append("No properties were set.")
	else:
		lines.append("Set %d propert%s: %s" % [applied.size(), "y" if applied.size() == 1 else "ies", ", ".join(applied)])
	if note != "":
		lines.append(note)
	return "\n".join(lines)


## read_errors: argument extraction plus the uid rider — the panel scrape lives in GDLLMConsole; any uid:// the relayed entries mention is resolved against the registry here, where the ledger lives, the same treatment every other engine-error surface gets.
static func _read_errors(args: Dictionary, ledger: SessionLedger) -> String:
	var content := GDLLMConsole.read_errors(_arg_int(args, CONSOLE_LIMIT_KEYS, 0), _arg_string(args, CONSOLE_FILTER_KEYS))
	return content + _uid_error_attribution([content], ledger)


## The run_game tool: launch the project through the editor's own Play machinery (the same path as the user's F5/F6), watch it for a bounded window, and return the Output and Errors deltas the panels received over the debugger — then stop the run unless keep_running asked otherwise. A run the user already has playing is refused, never hijacked.
static func _run_game(args: Dictionary) -> String:
	if not Engine.is_editor_hint():
		return "Error: running the game needs the editor's Play machinery, and this session is running headless — there is no editor to launch it from. run_script can still execute a SceneTree script headlessly."
	var unexpected := _unexpected_arg_error(args, RUN_SCENE_KEYS + RUN_WAIT_KEYS + RUN_KEEP_KEYS + RUN_PROFILE_KEYS + RUN_SHOW_KEYS, RUN_GAME_USAGE)
	if unexpected != "":
		return unexpected
	if EditorInterface.is_playing_scene():
		return _already_playing_refusal()
	var overlays := _run_overlays(args)
	if not bool(overlays["ok"]):
		return String(overlays["why"])
	var requested := _arg_string(args, RUN_SCENE_KEYS)
	var scene := ""
	var note := ""
	var label := ""
	if requested != "":
		var resolved := _resolve_file_path(requested)
		if resolved == "":
			return _file_not_found(requested, "scene file")
		if resolved.get_extension().to_lower() not in ["tscn", "scn"]:
			return "Error: %s is not a scene file — run_game plays .tscn/.scn scenes. To execute a script headlessly use run_script." % resolved
		scene = resolved
		label = resolved
		note = _resolution_note(requested, resolved)
	else:
		var main := String(ProjectSettings.get_setting("application/run/main_scene", ""))
		if main == "":
			return "Error: no scene was given and the project has no main scene, so there is nothing to run. Set one with set_project_setting (\"application/run/main_scene\" to a res:// scene path), or pass the scene to play in \"scene\"."
		label = _resolve_file_path(main)
		if label == "":
			return "Error: the project's main scene setting (application/run/main_scene = %s) doesn't resolve to a file on disk, so the game can't start. Fix it with set_project_setting, or pass an existing scene in \"scene\"." % main
	var wait := clampi(_arg_int(args, RUN_WAIT_KEYS, GDLLMTunables.geti(GDLLMTunables.RUN_GAME_DEFAULT_WAIT)), 1, GDLLMTunables.geti(GDLLMTunables.RUN_GAME_MAX_WAIT))
	var keep := _arg_bool(args, RUN_KEEP_KEYS)
	var profile := _run_profile_mode(args)
	if profile != "" and not GDLLMPerf.PROFILERS.has(profile):
		return "Error: \"%s\" is not a profiler run_game can run. Pass profile: true for the function profiler, or \"visual\" (GPU cost per render pass) or \"network\" (RPC traffic and bandwidth) to run that one for the watch window." % profile
	GDLLMPerf.ensure_connected()
	GDLLMBreak.ensure_connected()
	var unsaved_note := _run_unsaved_note()
	var output_base := GDLLMConsole.output_baseline()
	var errors_base := GDLLMConsole.errors_baseline()
	var started_ms := Time.get_ticks_msec()
	_game_run = {"scene": label, "started_ms": started_ms, "started_unix": int(Time.get_unix_time_from_system()), "output_base": output_base, "errors_base": errors_base, "live_reload": true}
	# The launch reads these flags out of the editor's project metadata, so they are set immediately before it and put back immediately after: the user's own Debug menu is left exactly as they had it, while this run still carries what it was launched with (probe-verified — restoring right after the play call does not un-arm the process that already started).
	var previous_options := _apply_run_options(overlays["names"])
	if scene == "":
		EditorInterface.play_main_scene()
	else:
		EditorInterface.play_custom_scene(scene)
	_restore_run_options(previous_options)
	var seen_playing := false
	var profiling := false
	var deadline := started_ms + wait * 1000
	while Time.get_ticks_msec() < deadline:
		if EditorInterface.is_playing_scene():
			seen_playing = true
			if profile != "" and not profiling:
				# The debug session activates a beat after the process appears, so the toggle retries until it lands.
				profiling = bool(GDLLMPerf.toggle_profiler(profile, true).get("ok", false))
			if not GDLLMBreak.current_break().is_empty():
				# A paused game does nothing for the rest of the window, so waiting it out would only delay the report of why it stopped.
				break
		elif seen_playing or Time.get_ticks_msec() - started_ms > GDLLMTunables.geti(GDLLMTunables.RUN_GAME_LAUNCH_GRACE_MS):
			break
		await _yield_frame()
	var paused: Dictionary = GDLLMBreak.current_break()
	if not paused.is_empty():
		# Settled here, while the break is live and replying; the block itself is composed after any stop below, so its liveness wording matches how the run ends.
		await _settle_break(paused)
	var ran_s := (Time.get_ticks_msec() - started_ms) / 1000.0
	var still_playing := EditorInterface.is_playing_scene()
	var status: String
	if not still_playing and not seen_playing:
		_game_run = {}
		status = "Error: the editor never reported %s as running within %.1f s of the launch — the run most likely failed to start; the capture below may name why." % [label, GDLLMTunables.geti(GDLLMTunables.RUN_GAME_LAUNCH_GRACE_MS) / 1000.0]
	elif not still_playing:
		_game_run = {}
		status = "Ran %s; the run ended on its own after %.1f s — a quit, a crash, or the user pressing Stop. New errors below say if it crashed." % [label, ran_s]
	elif not paused.is_empty() and keep:
		status = "Ran %s; after %.1f s it PAUSED in the debugger and is still up, stopped where it broke. The break is detailed below: debug_game steps or resumes it (\"continue\"), and every other game tool refuses until it moves." % [label, ran_s]
	elif not paused.is_empty():
		EditorInterface.stop_playing_scene()
		_game_run = {}
		status = "Ran %s; after %.1f s it PAUSED in the debugger, and the run was then stopped as asked. What it broke on is below — but stepping needs a live game, so to work at that break run again with keep_running true and read_game_break there." % [label, ran_s]
	elif keep:
		status = "Ran %s for %d s; the game is STILL RUNNING for the user to drive. Call stop_game when it should end — read_output/read_errors keep reading its console meanwhile." % [label, wait]
	else:
		EditorInterface.stop_playing_scene()
		_game_run = {}
		# The last line a caller reads before deciding what to do next: stating the fact without the consequence is what let a wild run relaunch twice, each time capturing and stopping again while it waited to profile.
		status = "Ran %s for %d s, then stopped it — nothing is running now, so no other game tool can reach it. Pass \"keep_running\": true when something else needs the game up." % [label, wait]
	var profile_note := ""
	if profile != "" and not profiling:
		# A session that only activated after the window would silently start profiling here, so a late success is switched straight back off and named.
		var late: Dictionary = GDLLMPerf.toggle_profiler(profile, true)
		if bool(late["ok"]):
			GDLLMPerf.toggle_profiler(profile, false)
			profile_note = "\nProfiling was requested but the debug session only became active after the watch window — profile_game can sample it now."
		else:
			profile_note = "\nProfiling was requested but could not start: %s." % String(late["why"])
	elif profiling:
		GDLLMPerf.toggle_profiler(profile, false)
	if not keep or not still_playing:
		# Let the run's last prints cross the debugger before the capture reads the panels.
		for i in 10:
			await _yield_frame()
	# Composed after the wait so a stop above has raised the stopped signal by now: a kept run's break reports live ("PAUSED", steppable), a stopped run's as the record of a run that ended — claiming a stopped game is paused would offer stepping into nothing.
	var break_block := ""
	if not paused.is_empty():
		break_block = "\n\n" + GDLLMBreak.format_break(paused, Time.get_ticks_msec(), "the run this call started", false)
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	var perf_line := GDLLMPerf.run_summary(started_ms)
	var profile_block := "\n\n" + _profiler_mode_report(profile, started_ms) if profiling else ""
	if not _game_run.is_empty():
		# stop_game's later delta starts where this capture ended, so nothing is reported twice.
		_game_run["output_base"] = GDLLMConsole.output_baseline()
		_game_run["errors_base"] = GDLLMConsole.errors_baseline()
		_game_run["captured_at"] = Time.get_ticks_msec()
	var options_note := _run_options_note(overlays["names"], not _game_run.is_empty())
	return note + status + unsaved_note + options_note + profile_note + break_block + "\n\n" + capture + "\n\n" + perf_line + profile_block


## Which debug overlays a run_game call asked for, normalized through the tolerant alias table. An unrecognized name is refused with the five that exist rather than quietly drawing nothing, since an overlay silently skipped reads as "the engine drew it and there was nothing there". {"ok", "why", "names"}.
static func _run_overlays(args: Dictionary) -> Dictionary:
	var raw: Array = []
	for key in RUN_SHOW_KEYS:
		if args.has(key):
			raw = Array(args[key]) if args[key] is Array else [args[key]]
			break
	var names: Array = []
	for entry in raw:
		var wanted := String(entry).strip_edges().to_lower().replace(" ", "_").replace("-", "_")
		if wanted == "":
			continue
		var resolved := String(RUN_DEBUG_ALIASES.get(wanted, ""))
		if resolved == "":
			return {"ok": false, "why": "Error: \"%s\" is not a debug overlay this run can draw. The five are \"collisions\" (collision shapes and contacts), \"navigation\" (navigation meshes), \"paths\" (Path2D/Path3D curves), \"avoidance\" (agent radii) and \"redraw\" (flash CanvasItems as they redraw)." % String(entry), "names": []}
		if not names.has(resolved):
			names.append(resolved)
	return {"ok": true, "why": "", "names": names}


## Turn on the Debug-menu run flags this launch needs, returning what they were so the caller can put the user's own menu back. The two hot-reload flags ride every run: they cost nothing when unused, and a run launched without them can never take a reload later — the failure mode being that the reload stops the game's scripts rather than refusing.
static func _apply_run_options(overlays: Array) -> Dictionary:
	var previous: Dictionary = {}
	if not Engine.is_editor_hint():
		return previous
	var settings := EditorInterface.get_editor_settings()
	var wanted: Array = RUN_RELOAD_OPTIONS.duplicate()
	for name: String in overlays:
		wanted.append(String(RUN_DEBUG_OPTIONS[name]))
	for key: String in wanted:
		previous[key] = settings.get_project_metadata("debug_options", key, false)
		settings.set_project_metadata("debug_options", key, true)
	return previous


## Put the user's Debug menu back exactly as it was, whatever the launch needed.
static func _restore_run_options(previous: Dictionary) -> void:
	if not Engine.is_editor_hint():
		return
	var settings := EditorInterface.get_editor_settings()
	for key in previous:
		settings.set_project_metadata("debug_options", key, previous[key])


## What a run's launch options mean for the caller: the overlays it drew (with the user's menu named as untouched), and — only while the run is still up, where the tool can act — that its scripts can be hot-reloaded.
static func _run_options_note(overlays: Array, still_ours: bool) -> String:
	var note := ""
	if not overlays.is_empty():
		var labels: Array = []
		for name: String in overlays:
			labels.append(String(RUN_OVERLAY_LABELS[name]))
		note += "\nDrawn in this run: %s — the editor's own Debug menu checkboxes are unchanged." % ", ".join(PackedStringArray(labels))
	if still_ours:
		note += "\nHot reload is armed for this run: edit a .gd and reload_game_scripts pushes it into the game as it stands, with no restart and no lost state."
	return note


## The stop_game tool: end the run_game-owned play session and report what arrived since that call's capture. Ownership is the whole point — a run this session can't prove it started is the user's, and closing their play session out from under them is refused, not forced.
static func _stop_game() -> String:
	if not Engine.is_editor_hint():
		return "Error: stopping a game run needs the editor, and this session is running headless — nothing can be playing here."
	if not EditorInterface.is_playing_scene():
		_game_run = {}
		return "Nothing is running — the game is not currently playing, so there is nothing to stop. run_game starts a run."
	if _game_run.is_empty():
		return "Error: a game is playing, but not one this session started (the user launched it, or the editor reloaded since run_game). Refusing to close the user's play session — ask them to press the editor's Stop button if it should end."
	var scene := String(_game_run["scene"])
	var ran_s := (Time.get_ticks_msec() - int(_game_run["started_ms"])) / 1000.0
	var since := int(_game_run.get("captured_at", _game_run["started_ms"]))
	var output_base: Dictionary = _game_run["output_base"]
	var errors_base: Dictionary = _game_run["errors_base"]
	# A run stopped while paused was frozen for some of its life, which the elapsed time alone would read as time spent running.
	var was_paused: Dictionary = GDLLMBreak.current_break()
	var paused_note := "" if was_paused.is_empty() else " It was PAUSED in the debugger when stopped, on %s — it had been stopped there since, not running." % GDLLMBreak.describe_reason(String(was_paused.get("reason", "")))
	EditorInterface.stop_playing_scene()
	_game_run = {}
	# Let the run's last prints cross the debugger before the capture reads the panels.
	for i in 10:
		await _yield_frame()
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	return "Stopped %s after %.1f s total.%s\n\n%s\n\n%s" % [scene, ran_s, paused_note, capture, GDLLMPerf.run_summary(since)]


## The run_script tool: execute one .gd for real in a headless engine subprocess (the same launcher the validation checks use, with a model-raisable timeout) and relay its exit code and output — the execution counterpart to check_script.
static func _run_script(args: Dictionary) -> String:
	var requested := _arg_string(args, RUN_SCRIPT_PATH_KEYS)
	if requested == "":
		return "Error: no script path was provided. " + GDLLMTunables.fill(RUN_SCRIPT_USAGE)
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	if resolved.get_extension().to_lower() != "gd":
		return "Error: %s is not a GDScript file — run_script executes .gd scripts. A scene is run with run_game." % resolved
	await _await_path_stable(resolved)
	var timeout := clampi(_arg_int(args, RUN_TIMEOUT_KEYS, GDLLMTunables.geti(GDLLMTunables.RUN_SCRIPT_DEFAULT_TIMEOUT)), 1, GDLLMTunables.geti(GDLLMTunables.RUN_SCRIPT_MAX_TIMEOUT))
	var extra: Array = ["--script", resolved]
	var script_args := _arg_string_array(args, RUN_ARGS_KEYS)
	if not script_args.is_empty():
		extra.append("--")
		for a in script_args:
			extra.append(a)
	var run: Dictionary = await _edit_file_run_engine(extra, "", timeout * 1000)
	return _resolution_note(requested, resolved) + format_script_run(resolved, run, timeout)


## Pure composer for a game run's capture: the Output delta, the per-session error deltas, and the panel's own view-controls rider, bounded by the console tools' caps so a chatty run can't flood the result. Separated from the panel reads so the headless tests can drive it with synthetic deltas; every unreadable panel is stated rather than passed off as silence.
static func format_run_capture(output_delta: Dictionary, error_deltas: Array, hidden_note: String) -> String:
	var parts: Array = []
	if bool(output_delta.get("missing", false)):
		parts.append("The Output panel could not be read for this run, so what it printed is unknown — read_output may still reach it.")
	else:
		var lines: Array = output_delta["lines"]
		if lines.is_empty():
			parts.append("The run printed nothing new to the Output console.")
		else:
			var tail: Dictionary = GDLLMConsole.tail_lines(lines, GDLLMTunables.geti(GDLLMTunables.CONSOLE_OUTPUT_LINES))
			var window := ", newest %d shown — read_output has the full console" % (lines.size() - int(tail["omitted"])) if int(tail["omitted"]) > 0 else ""
			parts.append("New Output during the run (%d lines%s):\n%s" % [lines.size(), window, tail["text"]])
			if bool(output_delta.get("reset", false)):
				parts.append("(The Output panel was cleared as the run started — the editor's clear-on-play default — so the lines above are everything it now holds.)")
	if hidden_note != "":
		parts.append(hidden_note.strip_edges())
	parts.append(_run_errors_block(error_deltas))
	return "\n\n".join(PackedStringArray(parts))


## The errors half of a run capture: new entries across every debugger session, tallied and capped, with the session named only when more than one exists — the same disclosure read_errors gives, scoped to the run's window.
static func _run_errors_block(error_deltas: Array) -> String:
	if error_deltas.is_empty():
		return "The debugger's Errors tab could not be read for this run, so whether it errored is unknown — read_errors may still reach it."
	var flat: Array = []
	var errors := 0
	var reset := false
	var multi := error_deltas.size() > 1
	for delta: Dictionary in error_deltas:
		reset = reset or bool(delta.get("reset", false))
		for entry: Dictionary in delta["entries"]:
			if String(entry["kind"]) == "error":
				errors += 1
			flat.append("%s:\n%s" % [delta["session"], GDLLMConsole.format_error_entry(entry)] if multi else GDLLMConsole.format_error_entry(entry))
	if flat.is_empty():
		return "No new errors or warnings reached the debugger during the run."
	var shown: Array = flat.slice(maxi(0, flat.size() - GDLLMTunables.geti(GDLLMTunables.CONSOLE_ERROR_ENTRIES)))
	var window := ", newest %d shown — read_errors has the full history" % shown.size() if shown.size() < flat.size() else ""
	var body := "%d new debugger entr%s during the run (%d errors, %d warnings%s):\n%s" % [flat.size(), "y" if flat.size() == 1 else "ies", errors, flat.size() - errors, window, "\n".join(PackedStringArray(shown))]
	if reset:
		body += "\n(The Errors tab was cleared during the run, so its whole current list is counted as new.)"
	return body


## Pure composer for run_script's verdict: exit code, bounded output tail (a subprocess's output has nowhere else to live, so the drop is disclosed as unrecoverable), the timeout kill with its remedy, and the engine's wrong-base-class refusal translated into the fix.
static func format_script_run(resolved: String, run: Dictionary, timeout_s: int) -> String:
	var lines: Array = []
	for line in GDLLMConsole.output_lines(String(run["output"])):
		# The engine banner is boot noise, not the script's output.
		if not String(line).begins_with("Godot Engine v"):
			lines.append(line)
	var tail: Dictionary = GDLLMConsole.tail_lines(lines, GDLLMTunables.geti(GDLLMTunables.RUN_SCRIPT_OUTPUT_LINES))
	var output_block := "\nIt printed nothing beyond the engine banner."
	if not lines.is_empty():
		var window := ", newest %d shown — the rest is gone; only a re-run can reprint it" % (lines.size() - int(tail["omitted"])) if int(tail["omitted"]) > 0 else ""
		output_block = "\n\nIts output (%d lines%s):\n%s" % [lines.size(), window, tail["text"]]
	if bool(run.get("killed", false)):
		return "Error: %s was still running when its %d s timeout expired and was killed — there is no exit code, and nothing more will arrive. If the script legitimately needs longer, raise timeout_seconds (up to %d); if it should have finished, make sure every path reaches quit().%s" % [resolved, timeout_s, GDLLMTunables.geti(GDLLMTunables.RUN_SCRIPT_MAX_TIMEOUT), output_block]
	if not bool(run["ok"]):
		return "Error: the engine subprocess for %s %s — the script was NOT executed.%s" % [resolved, String(run["why"]), output_block]
	var verdict := "%s ran to completion with exit code %d%s." % [resolved, int(run["exit_code"]), "" if int(run["exit_code"]) == 0 else " — nonzero, which by the quit(code) convention signals failure"]
	if String(run["output"]).contains("inherit from SceneTree or MainLoop"):
		verdict += "\nThe engine refused to run it: a run_script target must `extends SceneTree` (or MainLoop), doing its work in _init (or on the first process frame, where autoloads are live) and ending with quit()."
	return verdict + output_block


## The honest rider for a run launched while the editor's save-before-running setting is off and scenes hold unsaved edits: the game played what disk holds, not what the user sees, and a capture that hid that would misattribute every resulting difference. "" in the common case (the setting defaults on, and the editor then saves before playing).
static func _run_unsaved_note() -> String:
	var settings := EditorInterface.get_editor_settings()
	var key := "run/auto_save/save_before_running"
	if not settings.has_setting(key) or bool(settings.get_setting(key)):
		return ""
	var unsaved := EditorInterface.get_unsaved_scenes()
	if unsaved.is_empty():
		return ""
	return "\nNote: the editor's save-before-running setting is off and %d open scene(s) have unsaved changes (%s) — the run used what is saved on disk, not what the user currently sees." % [unsaved.size(), ", ".join(unsaved)]


## The refusal when a game is already playing: names what runs and who owns it, and the one lever that applies — stop_game for a run this session started, the user's own Stop button otherwise.
static func _already_playing_refusal() -> String:
	var playing := EditorInterface.get_playing_scene()
	var what := playing if playing != "" else "the project"
	if _game_run.is_empty():
		return "Error: a game is already running (%s), and not one this session started — it is the user's play session. Ask them to stop it (or to say when it's done) before launching another run." % what
	return "Error: a game this session started is already running (%s). Call stop_game to end it and collect what it printed, then run again." % what


## run_game's profile flag, which doubles as a profiler selector: absent or false means no profiling, true means the function profiler, and a mode name ("visual", "gpu", "network", ...) runs that profiler for the watch window instead. A name matching none of them is returned verbatim so the caller can refuse it by name — silently running the wrong profiler, or none, would report a capture the model never asked for — and the caller tells the two apart with PROFILERS.has.
static func _run_profile_mode(args: Dictionary) -> String:
	for key in RUN_PROFILE_KEYS:
		# Read straight off the value rather than through _arg_string: the flag's own documented shape is a bool, which has no String conversion.
		if not args.has(key) or not args[key] is String:
			continue
		var requested := String(args[key]).strip_edges()
		if requested == "" or requested.to_lower() in ["true", "false", "1", "0", "yes", "no", "y", "n"]:
			break
		var named := GDLLMPerf.profiler_mode(requested)
		return named if named != "" else requested
	return "functions" if _arg_bool(args, RUN_PROFILE_KEYS) else ""


## read_performance: argument extraction only — the monitor stream, its recording, and the summary all live in GDLLMPerf.
static func _read_performance(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, PERF_SECONDS_KEYS + PERF_ALL_KEYS, READ_PERFORMANCE_USAGE)
	if unexpected != "":
		return unexpected
	return GDLLMPerf.read_performance(_arg_int(args, PERF_SECONDS_KEYS, 0), _arg_bool(args, PERF_ALL_KEYS))


## The profile_game tool: sample the live game with one of the engine's profilers for a bounded window, switch it off again, and relay that tab's own rows — with whose run was profiled stated outright, since a user session may be measured but never silently.
static func _profile_game(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, PERF_SECONDS_KEYS + PERF_MODE_KEYS + PERF_ROWS_KEYS + PERF_FILTER_KEYS, PROFILE_GAME_USAGE)
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, PERF_MODE_KEYS)
	var mode := GDLLMPerf.profiler_mode(requested) if requested != "" else "functions"
	if mode == "":
		return "Error: \"%s\" is not a profiler this tool can run. %s" % [requested, GDLLMTunables.fill(PROFILE_GAME_USAGE)]
	var tab := String((GDLLMPerf.PROFILERS[mode] as Dictionary)["tab"])
	if not Engine.is_editor_hint():
		return "Error: the engine's profilers run on a game attached to the editor's debugger, and this session is running headless — there is nothing to profile."
	if not EditorInterface.is_playing_scene():
		# The one-step route is spelled with its literal argument: the wild failure was a model that read "its profile flag" and then launched without keep_running, twice.
		return _no_run_refusal("nothing to profile", "To do it in a single call instead, run_game with \"profile\": \"%s\" launches the game, profiles it for the watch window and stops it. This tool also attaches to a run that is ALREADY up, including one the user started." % mode)
	var paused: Dictionary = GDLLMBreak.current_break()
	if not paused.is_empty():
		# A paused game draws no frames, runs no scripts, and sends no packets, so every mode would spend its whole window recording nothing and report an empty tab as if the capture had merely been short.
		return "Error: the game is PAUSED in the debugger on %s, so it is running nothing for a profiler to measure. Resume it with debug_game (\"continue\") and profile the running game; read_game_break shows where it stopped." % GDLLMBreak.describe_reason(String(paused.get("reason", "")))
	var seconds := clampi(_arg_int(args, PERF_SECONDS_KEYS, GDLLMTunables.geti(GDLLMTunables.PROFILE_GAME_DEFAULT_SECONDS)), 1, GDLLMTunables.geti(GDLLMTunables.PROFILE_GAME_MAX_SECONDS))
	GDLLMPerf.ensure_connected()
	var toggled: Dictionary = GDLLMPerf.toggle_profiler(mode, true)
	if not bool(toggled["ok"]):
		return "Error: could not start the %s profiler — %s." % [tab, String(toggled["why"])]
	var started_ms := Time.get_ticks_msec()
	var whose := _whose_run()
	var deadline := started_ms + seconds * 1000
	while Time.get_ticks_msec() < deadline and EditorInterface.is_playing_scene():
		await _yield_frame()
	var ended_early := not EditorInterface.is_playing_scene()
	GDLLMPerf.toggle_profiler(mode, false)
	# Let the final profiler frames cross the debugger before the tab is read.
	for i in 5:
		await _yield_frame()
	var ended := " (the run ended during the capture)" if ended_early else ""
	return "Profiled %s for %d s with the %s; it is switched off again, and the editor's %s tab now shows this capture for the user.\n\n%s" % [whose, seconds, _profiler_label(mode), tab, _profiler_mode_report(mode, started_ms, _arg_int(args, PERF_ROWS_KEYS, 0), _arg_string(args, PERF_FILTER_KEYS))]


## How a result names the profiler it just ran, in the terms of what was measured rather than the tab's title alone.
static func _profiler_label(mode: String) -> String:
	match mode:
		"visual":
			return "visual (GPU) profiler"
		"network":
			return "network profiler"
	return "function profiler"


## The tab readback for one profiler mode, shared by profile_game and run_game's profile flag: display truth — the same rows the user sees — with a changed layout refusing by name rather than answering with an invented empty capture. `limit`/`filter` ride through from an explicit profile_game ask; run_game's profile flag reads at the defaults.
static func _profiler_mode_report(mode: String, since_ms: int, limit := 0, filter := "") -> String:
	match mode:
		"visual":
			return _visual_tab_report(limit, filter)
		"network":
			return _network_tab_report(since_ms, limit, filter)
	return _profiler_tab_report(limit, filter)


## The Profiler tab readback: the function rows exactly as that tab formats them.
static func _profiler_tab_report(limit := 0, filter := "") -> String:
	var trees := GDLLMPerf.profiler_trees()
	if trees.is_empty():
		return _tab_layout_error("Profiler tab's function list", "Profiler")
	var blocks: Array = []
	for entry: Dictionary in trees:
		var body := GDLLMPerf.format_profile(GDLLMPerf.profiler_rows(entry["tree"]), limit, filter)
		if trees.size() > 1:
			body = "%s:\n%s" % [entry["session"], body]
		blocks.append(body)
	return "Times as the Profiler tab currently displays them (its Measure selector decides self vs inclusive):\n" + "\n\n".join(PackedStringArray(blocks))


## The Visual Profiler tab readback: the render passes of the frame that tab is showing, CPU and GPU side by side.
static func _visual_tab_report(limit := 0, filter := "") -> String:
	var trees := GDLLMPerf.mode_trees("visual", 3)
	if trees.is_empty():
		return _tab_layout_error("Visual Profiler tab's pass list", "Visual Profiler")
	var blocks: Array = []
	for entry: Dictionary in trees:
		var body := GDLLMPerf.format_visual_profile(GDLLMPerf.visual_rows(entry["tree"]), limit, filter)
		if trees.size() > 1:
			body = "%s:\n%s" % [entry["session"], body]
		blocks.append(body)
	return "\n\n".join(PackedStringArray(blocks))


## The Network Profiler tab readback: bandwidth measured across the capture window from the game's own reports, plus the tab's two tables (per-node RPCs, and replication traffic).
static func _network_tab_report(since_ms: int, limit := 0, filter := "") -> String:
	var rpc_trees := GDLLMPerf.mode_trees("network", 3)
	if rpc_trees.is_empty():
		return _tab_layout_error("Network Profiler tab's RPC list", "Network Profiler")
	var sync_trees := GDLLMPerf.mode_trees("network", 5)
	var bandwidth := GDLLMPerf.bandwidth_since(since_ms)
	var blocks: Array = []
	for i in rpc_trees.size():
		var entry: Dictionary = rpc_trees[i]
		var syncs: Array = GDLLMPerf.network_rows(sync_trees[i]["tree"]) if i < sync_trees.size() else []
		var body := GDLLMPerf.format_network(bandwidth, GDLLMPerf.network_rows(entry["tree"]), syncs, limit, filter)
		if rpc_trees.size() > 1:
			body = "%s:\n%s" % [entry["session"], body]
		blocks.append(body)
	return "\n\n".join(PackedStringArray(blocks))


## The refusal every profiler readback shares when this editor build's panel no longer matches: named, never answered with an invented empty capture, and pointing the user at the tab that does hold the data.
static func _tab_layout_error(what: String, tab: String) -> String:
	return "The %s could not be located in this editor build — its internal layout may have changed. Tell the user the profiling tools need updating for this editor version; the capture itself is in Debugger → %s." % [what, tab]


## The read_video_ram tool: press the Video RAM tab's own Refresh button, wait for the game's reply to land, and report the tab's list. The settle is the point — the tab keeps the PREVIOUS refresh's rows until the reply arrives, so reading it straight after the press would report an old list as the current one, and a game that never answers is said to have never answered.
static func _read_video_ram(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, VRAM_LIMIT_KEYS + VRAM_FILTER_KEYS, READ_VIDEO_RAM_USAGE)
	if unexpected != "":
		return unexpected
	if not Engine.is_editor_hint():
		return "Error: video memory is reported by a game attached to the editor's debugger, and this session is running headless — there is no game and no panel to ask."
	if not EditorInterface.is_playing_scene():
		return _no_run_refusal("no game to report its video memory")
	GDLLMPerf.ensure_connected()
	if GDLLMPerf.bridge == null:
		return "Error: could not ask the game for its video memory — the debugger bridge is not registered; the plugin needs a reload (Project Settings → Plugins)."
	if GDLLMPerf.active_sessions() == 0:
		# The tab's Refresh button asks the debug PEER, so pressing it with no session attached only pushes an engine error into the user's Output console.
		return "Error: the game is running but no debug session is attached yet, so there is nobody to ask for the video-memory list — it may still be starting. %s A game launched with the debugger disabled never attaches at all." % TRANSIENT_RETRY_INVITATION
	var tabs := GDLLMPerf.video_ram_tabs()
	if tabs.is_empty():
		return "Error: the debugger's Video RAM tab could not be located in this editor build — its internal layout may have changed. Tell the user the read_video_ram tool needs updating for this editor version."
	var before := GDLLMPerf.video_ram_stamps()
	var pressed := PackedStringArray()
	for tab: Dictionary in tabs:
		if tab["refresh"] == null:
			continue
		(tab["refresh"] as Button).emit_signal("pressed")
		pressed.append(String(tab["session"]))
	if pressed.is_empty():
		return "Error: the Video RAM tab's Refresh button could not be located in this editor build — its internal layout may have changed. Tell the user the read_video_ram tool needs updating for this editor version; Debugger → Video RAM still refreshes by hand."
	var answered := await _await_video_ram(before, pressed)
	var limit := _arg_int(args, VRAM_LIMIT_KEYS, 0)
	var filter := _arg_string(args, VRAM_FILTER_KEYS)
	var blocks: Array = []
	for tab: Dictionary in tabs:
		var session := String(tab["session"])
		var body := ""
		if not answered.has(session):
			# Deliberately not blaming a breakpoint: a game paused in the debugger still answers this request (probe-verified), so silence means stuck or dying, not stopped on a line.
			body = "The game did not answer the refresh within %.1f s, so nothing here would be current — it is most likely frozen, deadlocked, or on its way down (a game merely paused at a breakpoint still answers). read_errors and read_game_break say more; Debugger → Video RAM holds whatever it last reported." % (GDLLMTunables.geti(GDLLMTunables.VRAM_REPLY_TIMEOUT_MS) / 1000.0)
		else:
			body = GDLLMPerf.format_video_ram(GDLLMPerf.video_ram_rows(tab["tree"]), GDLLMPerf.video_ram_total(tab), limit, filter)
		if tabs.size() > 1:
			body = "%s:\n%s" % [session, body]
		blocks.append(body)
	return "Video memory of %s, just refreshed through the tab's own Refresh button:\n\n%s" % [_whose_run(), "\n\n".join(PackedStringArray(blocks))]


## The sessions whose Video RAM reply landed after their refresh press, waited for until every pressed session answered or the timeout runs out; a run that ends mid-wait stops it, since a dead game will never answer.
static func _await_video_ram(before: Dictionary, pressed: PackedStringArray) -> Dictionary:
	var answered: Dictionary = {}
	var deadline := Time.get_ticks_msec() + GDLLMTunables.geti(GDLLMTunables.VRAM_REPLY_TIMEOUT_MS)
	while answered.size() < pressed.size() and Time.get_ticks_msec() < deadline and EditorInterface.is_playing_scene():
		await _yield_frame()
		var now := GDLLMPerf.video_ram_stamps()
		for session in pressed:
			if int(now.get(session, 0)) > int(before.get(session, 0)):
				answered[session] = true
	return answered


## The read_game_ui tool: one live-UI snapshot over the debugger, composed by the shared protocol formatter; every transport rung that can't reach the agent refuses by name through _game_reach_error.
static func _read_game_ui(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, GAME_SCOPE_KEYS + GAME_ALL_KEYS + GAME_FILTER_KEYS, READ_GAME_UI_USAGE)
	if unexpected != "":
		return unexpected
	GDLLMPerf.ensure_connected()
	var res: Dictionary = await GDLLMGame.command({"op": "ui", "scope": _arg_string(args, GAME_SCOPE_KEYS), "all": _arg_bool(args, GAME_ALL_KEYS), "filter": _arg_string(args, GAME_FILTER_KEYS)}, GDLLMTunables.geti(GDLLMTunables.GAME_REPLY_TIMEOUT_MS))
	if not bool(res["ok"]):
		return _game_reach_error("read", String(res["why_kind"]), String(res["why"]))
	var reply: Dictionary = res["reply"]
	if not bool(reply.get("ok", false)):
		return "Error: %s" % String(reply.get("why", "the game agent gave no reason"))
	# The debugger's own clicked-control record (the Misc tab's fields) is live UI state this snapshot can't see: the agent walks the tree, while only the game reports which Control a press actually reached.
	var clicked := GDLLMPerf.format_click_record(GDLLMPerf.last_click(), Time.get_ticks_msec())
	var snapshot := GDLLMGameProtocol.format_ui_snapshot(reply)
	if clicked != "":
		snapshot += "\n" + clicked
	return snapshot + _suspended_note() + _multi_session_note(int(res["active"]))


## The inspect_game_node tool: every readable property of one live node in one round, composed by the shared protocol formatter. The walk itself runs game-side, where the node actually is; only the rendered pairs cross the wire.
static func _inspect_game_node(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, GAME_CALL_PATH_KEYS + GAME_FILTER_KEYS + INSPECT_ALL_KEYS, INSPECT_GAME_NODE_USAGE)
	if unexpected != "":
		return unexpected
	var path := _arg_string(args, GAME_CALL_PATH_KEYS)
	if path == "":
		return "Error: no node path was given. " + INSPECT_GAME_NODE_USAGE
	var res: Dictionary = await GDLLMGame.command({"op": "inspect", "path": path, "filter": _arg_string(args, GAME_FILTER_KEYS), "all": _arg_bool(args, INSPECT_ALL_KEYS)}, GDLLMTunables.geti(GDLLMTunables.GAME_REPLY_TIMEOUT_MS))
	if not bool(res["ok"]):
		return _game_reach_error("read", String(res["why_kind"]), String(res["why"]))
	var reply: Dictionary = res["reply"]
	if not bool(reply.get("ok", false)):
		return "Error: %s" % String(reply.get("why", "the game agent gave no reason"))
	return GDLLMGameProtocol.format_node_inspect(reply) + _suspended_note() + _multi_session_note(int(res["active"]))


## The suspend_game tool: freeze the running game between frames, advance it a frame at a time, or let it run again — the engine's own scene suspension, driven by the messages the editor's Game view sends. The console delta rides along because a stepped frame's prints ARE the observation: one frame of a game that prints its state is the finest-grained look at it there is.
static func _suspend_game(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, SUSPEND_ACTION_KEYS + SUSPEND_FRAMES_KEYS, SUSPEND_GAME_USAGE)
	if unexpected != "":
		return unexpected
	var raw := _arg_string(args, SUSPEND_ACTION_KEYS)
	var action := _suspend_action(raw)
	if action == "":
		if raw == "":
			return "Error: no action was given. " + SUSPEND_GAME_USAGE
		return "Error: \"%s\" is not a suspend action. %s" % [raw, SUSPEND_GAME_USAGE]
	var frames := clampi(_arg_int(args, SUSPEND_FRAMES_KEYS, 1), 1, GDLLMTunables.geti(GDLLMTunables.SUSPEND_MAX_FRAMES))
	var output_base := GDLLMConsole.output_baseline()
	var errors_base := GDLLMConsole.errors_baseline()
	var was_suspended := GDLLMGame.suspended
	var lead := ""
	if action != "off" and not was_suspended:
		# "frame" on a running game has to freeze it first: next_frame advances a clock that is already ticking, which would look like nothing happened.
		var froze := GDLLMGame.send_scene("scene:suspend_changed", [true])
		if not bool(froze["ok"]):
			return _game_reach_error("freeze", String(froze["why_kind"]), String(froze["why"]))
		GDLLMGame.suspended = true
		if action == "frame":
			lead = "The game was running, so it was frozen first. "
	elif action == "off":
		var thawed := GDLLMGame.send_scene("scene:suspend_changed", [false])
		if not bool(thawed["ok"]):
			return _game_reach_error("resume", String(thawed["why_kind"]), String(thawed["why"]))
		GDLLMGame.suspended = false
	var advanced := 0
	var first_frame := -1
	var last_frame := -1
	if action == "frame":
		# Every frame is CONFIRMED, never assumed: next_frame is a flag the game clears when it runs a frame, not a counter, so several sent inside one of its poll cycles collapse into a single frame (measured: 5 presses landing as 2–5 frames depending on spacing). Watching the agent's own frame count move is what makes "advanced 3 frames" true.
		var seen := await _game_frame_count()
		first_frame = seen
		var budget := Time.get_ticks_msec() + GDLLMTunables.geti(GDLLMTunables.SUSPEND_STEP_BUDGET_MS)
		for i in frames:
			if seen < 0 or Time.get_ticks_msec() > budget:
				break
			var stepped := GDLLMGame.send_scene("scene:next_frame", [])
			if not bool(stepped["ok"]):
				break
			var landed := await _await_frame_after(seen, budget)
			if landed <= seen:
				break
			seen = landed
			last_frame = seen
			advanced += 1
	if advanced > 0:
		await _settle_console(output_base, GDLLMTunables.geti(GDLLMTunables.SUSPEND_OUTPUT_SETTLE_MS))
	for i in 5:
		await _yield_frame()
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	return lead + _suspend_verdict(action, advanced, frames, was_suspended, _whose_run(), first_frame, last_frame) + "\n\n" + capture


## How many frames of the GAME have run, as the agent inside it counts them, or -1 when it cannot be asked. The count comes from the agent's own _process rather than any engine counter: scene suspension stops _process while the main loop, the renderer and SceneTree.get_frame() all keep running at full speed (probe-measured), so an engine counter would report frames for a game that is standing still.
static func _game_frame_count() -> int:
	var res: Dictionary = await GDLLMGame.command({"op": "ping"}, GDLLMTunables.geti(GDLLMTunables.GAME_REPLY_TIMEOUT_MS))
	if not bool(res["ok"]):
		return -1
	return int((res["reply"] as Dictionary).get("scene_frame", -1))


## Wait for the game's frame count to pass `seen`, or give up at the budget — the confirmation that one next_frame actually produced one frame.
static func _await_frame_after(seen: int, budget_ms: int) -> int:
	while Time.get_ticks_msec() < budget_ms:
		var now := await _game_frame_count()
		if now < 0 or now > seen:
			return now
		await _wait_ms(GDLLMTunables.geti(GDLLMTunables.SUSPEND_FRAME_SETTLE_MS))
	return seen


## The suspend action one spelling means, or "" when it means none of them — the same tolerant-value pattern debug_game's own action argument follows.
static func _suspend_action(raw: String) -> String:
	return String(SUSPEND_ALIASES.get(raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_"), ""))


## Pure composer for suspend_game's verdict: what state the game is in now, and what that state does and does not allow — a frozen game answers every read but takes no input, which is the one thing a caller has to know next.
static func _suspend_verdict(action: String, advanced: int, asked: int, was_suspended: bool, whose: String, from_frame: int = -1, to_frame: int = -1) -> String:
	var frozen_note := "It is still SUSPENDED: read_game_ui, inspect_game_node, call_game_method, read_performance and read_video_ram all answer normally, but send_game_input cannot play into a frozen game — resume it (\"off\") to drive it."
	match action:
		"on":
			if was_suspended:
				return "%s was ALREADY suspended and stays that way — nothing moved.\n%s" % [whose.capitalize(), frozen_note]
			return "Froze %s between frames: nothing moves, nothing processes, and the same frame stays on screen.\n%s" % [whose, frozen_note]
		"off":
			if not was_suspended:
				return "%s was NOT suspended by this session, and it is running now. (A freeze the user made in the editor's Game view is theirs, and this call would have lifted it.)" % whose.capitalize()
			return "Resumed %s — it is running again from exactly where it was frozen, with no state disturbed." % whose
	# The ordinals are what make one step distinguishable from the next. Without them every advance renders the same sentence, and the loop brake — which reads an identical call returning identical content as a repeat that added nothing — stopped two wild frame-stepping runs at its fourth firing. They are also the label an observation wants: "at frame 1040, this value read X". A game that is NOT advancing still renders identically, so the brake keeps catching genuinely futile stepping.
	var span := "" if from_frame < 0 or to_frame < 0 else " (game frames %d → %d)" % [from_frame, to_frame]
	# The ordinals also catch a suspension that is not holding: if more frames crossed than steps landed, the game ran on between presses and these readings are NOT one frame apart, whatever the count says. Measured against a --headless game, which ignores scene suspension entirely.
	var drift := ""
	if from_frame >= 0 and to_frame >= 0 and to_frame - from_frame > advanced:
		drift = "\nWARNING: %d frames actually passed for %d step%s — the game is NOT holding frozen between presses, so these readings are not single-frame apart. A headless run ignores suspension outright; otherwise something is resuming it." % [to_frame - from_frame, advanced, "" if advanced == 1 else "s"]
	if advanced < asked:
		return "Advanced %s by %d of %d frame%s%s — the rest could not be sent, so the game may have ended.%s\n%s" % [whose, advanced, asked, "" if asked == 1 else "s", span, drift, frozen_note]
	return "Advanced %s by %d frame%s%s and left it frozen there — each frame ran input, _process, physics and a draw, exactly once.%s\n%s" % [whose, advanced, "" if advanced == 1 else "s", span, drift, frozen_note]


## The trailing disclosure that a game answering a read is frozen: a snapshot of a suspended game is a still frame, and reading it as live state would explain nothing about a game that is meant to be moving.
static func _suspended_note() -> String:
	if not GDLLMGame.suspended:
		return ""
	return "\n(The game is SUSPENDED — this is a still frame, not a moving game. suspend_game \"frame\" advances it, \"off\" resumes it.)"


## Wait roughly `ms` milliseconds of real time by yielding frames, so the editor stays responsive while a suspended game takes its own time to answer.
static func _wait_ms(ms: int) -> void:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		await _yield_frame()


## Wait, bounded, for the running game's console output to actually grow past `base`. A game that is suspended — or one being reloaded — services the debugger far more slowly than a running one (probe-measured in the hundreds of milliseconds), so the few-frame settle the other game tools use reads a stepped frame's prints as silence. A frame that genuinely printed nothing pays the whole wait, which is the price of never reporting output that happened as output that did not.
static func _settle_console(base: Dictionary, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if not (GDLLMConsole.output_delta_since(base)["lines"] as Array).is_empty():
			return
		await _yield_frame()


## The reload_game_scripts tool: push edited .gd files into the running game so it keeps its state and runs the new code. The arming check is not bureaucracy — a reload sent to a run launched without both live-debug flags silently fails to APPLY (probe-measured: the edited value never arrives while the node keeps processing as before, and reloading the main scene's own script stopped it processing entirely), and a change that quietly did not happen is worse than a refusal, since everything downstream is then reasoned from a value that was never set.
static func _reload_game_scripts(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, RELOAD_PATHS_KEYS, RELOAD_GAME_SCRIPTS_USAGE)
	if unexpected != "":
		return unexpected
	if not Engine.is_editor_hint():
		return "Error: hot-reloading scripts needs the editor's debugger and a running game, and this session is running headless — run_script executes a script outright instead."
	if not EditorInterface.is_playing_scene():
		return _no_run_refusal("no game to reload scripts into", "Every run this session starts is armed for hot reload.")
	var armed := _reload_armed()
	if not bool(armed["ok"]):
		return String(armed["why"])
	var requested := _reload_paths(args)
	if not bool(requested["ok"]):
		return String(requested["why"])
	var paths: Array = requested["paths"]
	if paths.is_empty():
		return "No .gd file has changed since this run started, so there is nothing to reload. Edit a script first, or pass \"paths\" to reload specific files anyway."
	var output_base := GDLLMConsole.output_baseline()
	var errors_base := GDLLMConsole.errors_baseline()
	# The editor's own filesystem must know the file changed before the game re-reads it, exactly as saving in the script editor would.
	for path: String in paths:
		EditorInterface.get_resource_filesystem().update_file(path)
	var sent := GDLLMGame.send_scene("scene:reload_cached_files", [PackedStringArray(paths)])
	if not bool(sent["ok"]):
		return _game_reach_error("reload", String(sent["why_kind"]), String(sent["why"]))
	# A reload runs at the game's own pace and a failing script errors on the way; both need frames to cross the debugger before the capture reads, and a script that reloads into new prints is the evidence the reload took.
	await _settle_console(output_base, GDLLMTunables.geti(GDLLMTunables.SUSPEND_OUTPUT_SETTLE_MS))
	for i in 5:
		await _yield_frame()
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	return format_reload_report(paths, _whose_run(), String(armed["note"]), _reload_caveats(paths)) + _suspended_note() + "\n\n" + capture


## Pure composer for reload_game_scripts' report: what was pushed, the one check that proves it took, and only those caveats that actually apply to the files reloaded. Console output is deliberately NOT offered as evidence either way — a reload that fails to apply leaves the game running and printing exactly as before (probe-measured: an unarmed reload left the node's own _process ticking and its position advancing while the new value never arrived), so the silence that follows a good reload and a dead one are the same silence.
static func format_reload_report(paths: Array, whose: String, armed_note: String, caveats: Array) -> String:
	var lines: Array = ["Reloaded %d script%s into %s — every live instance now runs the new code and kept the state it had:" % [paths.size(), "" if paths.size() == 1 else "s", whose]]
	for path: String in paths:
		lines.append("  - %s" % path)
	if armed_note != "":
		lines.append(armed_note)
	lines.append("Confirm it took by exercising the new CODE — call a changed method, or read a property whose getter recomputes (call_game_method). Nothing in the console proves it either way: a reload that never applied leaves the game running and printing exactly as it was.")
	# The misdiagnosis this heads off, measured: after a good reload a changed `var health := 123` still read 77 on the live node while a changed method body returned its new string, so checking a plain stored variable makes a working reload look broken.
	lines.append("A reload replaces code, not state: variables already initialized keep the values they hold, so a changed default or initializer will NOT show on nodes that already exist — only on ones created afterwards. To change a live value now, set it with call_game_method.")
	if not caveats.is_empty():
		lines.append("A reload carries CODE only, and these do not travel with it: %s." % "; ".join(PackedStringArray(caveats)))
	return "\n".join(PackedStringArray(lines))


## Which of a reload's caveats actually apply to the files being pushed. A paragraph that fires on every call is noise the model pays for in every later request (goal 1) and stops being read; naming only what is really there — this file declares a class_name, that one is an autoload — keeps it worth reading.
static func _reload_caveats(paths: Array) -> Array:
	var caveats: Array = []
	var autoloads: Array = []
	var class_names: Array = []
	var exports: Array = []
	for path: String in paths:
		if _is_autoload_script(path):
			autoloads.append(path.get_file())
		var text := FileAccess.get_file_as_string(path)
		if text == "":
			continue
		for line in text.split("\n"):
			var trimmed := String(line).strip_edges()
			if trimmed.begins_with("class_name ") and not class_names.has(path.get_file()):
				class_names.append(path.get_file())
			elif trimmed.begins_with("@export") and not exports.has(path.get_file()):
				exports.append(path.get_file())
	if not autoloads.is_empty():
		caveats.append("%s %s an autoload, whose singleton keeps the instance it already built" % [", ".join(PackedStringArray(autoloads)), "is" if autoloads.size() == 1 else "are"])
	if not class_names.is_empty():
		caveats.append("%s declare%s a class_name, and that registration only changes on a fresh run_game" % [", ".join(PackedStringArray(class_names)), "s" if class_names.size() == 1 else ""])
	if not exports.is_empty():
		caveats.append("changed @export defaults in %s do not re-apply to nodes already in the scene, which keep the values their scene file set" % ", ".join(PackedStringArray(exports)))
	return caveats


## Whether a res:// script is registered as one of the project's autoloads — the singleton case a reload cannot re-instantiate.
static func _is_autoload_script(path: String) -> bool:
	for setting: Dictionary in ProjectSettings.get_property_list():
		var name := String(setting.get("name", ""))
		if not name.begins_with("autoload/"):
			continue
		var target := String(ProjectSettings.get_setting(name, "")).trim_prefix("*")
		if target == path:
			return true
		# Autoloads are commonly registered by uid; the registry resolves them in the editor, which is the only place this tool runs.
		if target.begins_with("uid://"):
			var id := ResourceUID.text_to_id(target)
			if ResourceUID.has_id(id) and ResourceUID.get_id_path(id) == path:
				return true
	return false


## Whether the running game can take a reload at all: a run this session started is armed by construction (run_game sets both flags at launch), while the user's own run is judged by their Debug menu as it stands now — the only evidence there is, and said to be exactly that. {"ok", "why", "note"}.
static func _reload_armed() -> Dictionary:
	if not _game_run.is_empty():
		if bool(_game_run.get("live_reload", false)):
			return {"ok": true, "why": "", "note": ""}
		return {"ok": false, "why": "Error: this run was started before hot reload was armed, so a reload would silently fail to apply — the change never reaches the game, which carries on as if nothing happened. Stop it (stop_game) and start it again with run_game — every run this session starts is armed.", "note": ""}
	var missing: Array = []
	for key: String in RUN_RELOAD_OPTIONS:
		if not bool(_debug_option(key)):
			missing.append("Synchronize Scene Changes" if key == "run_live_debug" else "Synchronize Script Changes")
	if missing.is_empty():
		return {"ok": true, "why": "", "note": "(This run is the user's own, so whether it was launched with hot reload armed is judged by their Debug menu, which has both options ticked now. If the run predates that, the scripts would have stopped rather than reloaded — the capture below says which.)"}
	return {"ok": false, "why": "Error: this is the user's own run, and the editor's Debug menu has %s switched off — a reload sent to a game launched without it silently fails to apply — the change never arrives, the game carries on as though nothing happened, and for some scripts the node running them stops processing. Start a run with run_game instead (every run this session starts is armed for reload), or ask the user to tick Debug → %s and run again." % [" and ".join(PackedStringArray(missing)), " and ".join(PackedStringArray(missing))], "note": ""}


## Which .gd files a reload covers: the ones named, or every script changed since the run started — the set an edit-then-reload loop means, without the model having to remember what it edited. {"ok", "why", "paths"}.
static func _reload_paths(args: Dictionary) -> Dictionary:
	var raw: Array = []
	for key in RELOAD_PATHS_KEYS:
		if args.has(key):
			raw = Array(args[key]) if args[key] is Array else [args[key]]
			break
	if not raw.is_empty():
		var resolved: Array = []
		for entry in raw:
			var path := _resolve_file_path(String(entry))
			if path == "":
				return {"ok": false, "why": _file_not_found(String(entry), "script"), "paths": []}
			if path.get_extension().to_lower() != "gd":
				return {"ok": false, "why": "Error: %s is not a .gd script — a reload swaps GDScript code, and a scene or resource change needs a fresh run_game." % path, "paths": []}
			resolved.append(path)
		return {"ok": true, "why": "", "paths": resolved}
	if _game_run.is_empty() or not _game_run.has("started_unix"):
		return {"ok": false, "why": "Error: this run was not started by this session, so there is no launch time to measure \"changed since\" against. Pass \"paths\" with the scripts to reload.", "paths": []}
	var since := int(_game_run["started_unix"])
	var files: Array = []
	_collect_text_files("res://", files)
	var changed: Array = []
	for path: String in files:
		if path.get_extension().to_lower() == "gd" and FileAccess.get_modified_time(path) >= since:
			changed.append(path)
	if changed.size() > GDLLMTunables.geti(GDLLMTunables.RELOAD_MAX_FILES):
		return {"ok": false, "why": "Error: %d .gd files have changed since this run started, which is more than a targeted reload should carry — that many changes are better taken by a fresh run_game. Pass \"paths\" to reload specific ones." % changed.size(), "paths": []}
	changed.sort()
	return {"ok": true, "why": "", "paths": changed}


## One Debug-menu run flag as the editor stores it (project metadata, section "debug_options"), false when unset — the same read the engine makes when it builds a run's arguments.
static func _debug_option(key: String) -> bool:
	if not Engine.is_editor_hint():
		return false
	return bool(EditorInterface.get_editor_settings().get_project_metadata("debug_options", key, false))


## The send_game_input tool: normalize and bound the steps here so a malformed sequence never crosses the wire, have the in-game agent play them through the real input pipeline, then report what actually played plus the console capture for the window — the deltas are the payoff: what the game printed and errored WHILE the input played.
static func _send_game_input(args: Dictionary) -> String:
	var raw := _game_steps(args)
	if raw.is_empty():
		return "Error: no input steps were provided. " + GDLLMGameProtocol.STEPS_USAGE
	var normalized: Dictionary = GDLLMGameProtocol.normalize_steps(raw)
	if not bool(normalized["ok"]):
		return "Error: " + String(normalized["why"])
	# The agent plays a sequence from _process, which a suspended game never runs: the input would sit unplayed until the timeout and come back as an unexplained silence.
	if GDLLMGame.suspended:
		return "Error: the game is SUSPENDED between frames, and input can only be played into a game that is running — the sequence would never advance. Resume it with suspend_game (\"off\") and send this again."
	var output_base := GDLLMConsole.output_baseline()
	var errors_base := GDLLMConsole.errors_baseline()
	# Hooked before the sequence plays, so a click landing on a Control is recorded while it happens rather than missed and then reported as a click that reached nothing.
	GDLLMPerf.ensure_connected()
	var started_ms := Time.get_ticks_msec()
	var res: Dictionary = await GDLLMGame.command({"op": "input", "steps": raw}, int(float(normalized["seconds"]) * 1000.0) + GDLLMTunables.geti(GDLLMTunables.GAME_REPLY_MARGIN_MS))
	if not bool(res["ok"]):
		return _game_reach_error("drive", String(res["why_kind"]), String(res["why"]))
	# The last step is parsed game-side right before the reply, so its effects — the clicked-control record, a handler's prints — can trail the reply across the wire; while the records are still short of the pointer steps played, a bounded wall-clock wait closes that race instead of composing a miss for a click that landed (a sequence that really missed pays the full wait, the price of not lying about it).
	var pointer_steps := _pointer_step_count(normalized["steps"])
	var settle_deadline := Time.get_ticks_msec() + GDLLMTunables.geti(GDLLMTunables.CLICK_RECORD_SETTLE_MS)
	while pointer_steps > 0 and GDLLMPerf.clicks_since(started_ms).size() < pointer_steps and Time.get_ticks_msec() < settle_deadline:
		await _yield_frame()
	# Let the sequence's last prints cross the debugger before the capture reads the panels.
	for i in 5:
		await _yield_frame()
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	var played := format_input_played(res["reply"], float(normalized["seconds"]), _whose_run())
	if pointer_steps > 0:
		played += "\n" + GDLLMPerf.format_click_result(GDLLMPerf.clicks_since(started_ms), pointer_steps)
	return played + _multi_session_note(int(res["active"])) + "\n\n" + capture


## How many steps of a normalized sequence push the pointer — the only steps the debugger's clicked-control records say anything about, and the count a shortfall in those records is measured against.
static func _pointer_step_count(steps: Array) -> int:
	var count := 0
	for step: Dictionary in steps:
		if String(step["kind"]) in ["click", "mouse"]:
			count += 1
	return count


## The steps array for send_game_input, tolerant of a single bare step passed as the call's own arguments — the shape a schema-blind model reaches for.
static func _game_steps(args: Dictionary) -> Array:
	for key in GAME_STEPS_KEYS:
		if args.has(key) and args[key] is Array:
			return Array(args[key])
	var step_keys: Array = GDLLMGameProtocol.STEP_ACTION_KEYS + GDLLMGameProtocol.STEP_KEY_KEYS + GDLLMGameProtocol.STEP_TEXT_KEYS + GDLLMGameProtocol.STEP_CLICK_KEYS + GDLLMGameProtocol.STEP_MOUSE_KEYS + GDLLMGameProtocol.STEP_WAIT_KEYS + GDLLMGameProtocol.STEP_HOLD_KEYS + GDLLMGameProtocol.STEP_BUTTON_KEYS
	var single := {}
	for key in step_keys:
		if args.has(key):
			single[key] = args[key]
	return [single] if not single.is_empty() else []


## Pure composer for send_game_input's verdict: what played into whose session, any per-step notes the agent recorded, the failing step's reason when the sequence had to stop, and where keyboard focus ended — the state a next click most often depends on.
static func format_input_played(reply: Dictionary, seconds: float, whose: String) -> String:
	var lines: Array = []
	if bool(reply.get("ok", false)):
		lines.append("Played %d input step(s) (~%.1f s) into %s; the game is still running." % [int(reply.get("executed", 0)), seconds, whose])
	else:
		lines.append("Error: the input sequence stopped after %d completed step(s) — %s" % [int(reply.get("executed", 0)), String(reply.get("why", "the game agent gave no reason"))])
	for note in reply.get("notes", []):
		lines.append("Note: %s" % String(note))
	var focus := String(reply.get("focus", ""))
	lines.append("Keyboard focus after the sequence: %s." % (focus if focus != "" else "nothing"))
	return "\n".join(PackedStringArray(lines))


## The call_game_method tool: one method call on one live node, its result relayed as display data, with the same reach ladder and console capture as the other game tools — an engine error the call raises lands in the capture rather than vanishing.
static func _call_game_method(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, GAME_CALL_PATH_KEYS + GAME_METHOD_KEYS + GAME_CALL_ARGS_KEYS, CALL_GAME_METHOD_USAGE)
	if unexpected != "":
		return unexpected
	var path := _arg_string(args, GAME_CALL_PATH_KEYS)
	var method := _arg_string(args, GAME_METHOD_KEYS)
	if path == "" or method == "":
		return "Error: both a node path and a method name are needed. " + CALL_GAME_METHOD_USAGE
	var call_args: Array = []
	for key in GAME_CALL_ARGS_KEYS:
		if args.has(key):
			call_args = Array(args[key]) if args[key] is Array else [args[key]]
			break
	var output_base := GDLLMConsole.output_baseline()
	var errors_base := GDLLMConsole.errors_baseline()
	var res: Dictionary = await GDLLMGame.command({"op": "call", "path": path, "method": method, "args": call_args}, GDLLMTunables.geti(GDLLMTunables.GAME_REPLY_TIMEOUT_MS))
	if not bool(res["ok"]):
		return _game_reach_error("reach", String(res["why_kind"]), String(res["why"]))
	# Let the call's prints and errors cross the debugger before the capture reads the panels.
	for i in 5:
		await _yield_frame()
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	return format_game_call(res["reply"], path, method, call_args, _whose_run()) + _multi_session_note(int(res["active"])) + "\n\n" + capture


## The read_game_break tool: report where a paused game stopped and the state at that point. The stack is not requested here — the editor asks for it the moment the game breaks — so this only waits for those replies to land before answering, which is what keeps a read from reporting an empty stack that is merely late.
static func _read_game_break(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, BREAK_FRAME_KEYS + BREAK_ALL_KEYS + GAME_FILTER_KEYS, READ_GAME_BREAK_USAGE)
	if unexpected != "":
		return unexpected
	if not Engine.is_editor_hint():
		return "Error: a paused game is read over the editor's debugger, and this session is running headless — there is no debug session to read."
	var hook := GDLLMBreak.ensure_connected()
	if int(hook["found"]) == 0:
		return "Error: the debugger's session panels could not be located in this editor build — its internal layout may have changed. Tell the user the debugging tools need updating for this editor version."
	if int(hook["hooked"]) == 0:
		return "Error: this editor build's debugger panel raises no break signals, so a paused game cannot be read from it. Tell the user the debugging tools need updating for this editor version."
	var all := _arg_bool(args, BREAK_ALL_KEYS)
	var state: Dictionary = GDLLMBreak.current_break()
	if state.is_empty():
		return GDLLMBreak.not_paused_message(EditorInterface.is_playing_scene(), GDLLMBreak.last_break(), Time.get_ticks_msec()) + GDLLMBreak.armed_note()
	await _settle_break(state)
	# The report follows the debugger's OWN selection by default — the user may have clicked a frame by hand, and the variables on record are that frame's — so the inspector and the report can never describe two different frames; only an explicit frame argument moves the selection, through the tree, as a hand would.
	var filter := _arg_string(args, GAME_FILTER_KEYS)
	var wanted := _arg_int(args, BREAK_FRAME_KEYS, -1)
	if wanted < 0:
		return GDLLMBreak.format_break(state, Time.get_ticks_msec(), _whose_run(), all, filter) + GDLLMBreak.armed_note()
	return await _read_selected_frame(state, wanted, all, filter)


## Move the debugger's Stack Frames selection to `wanted`, wait for that frame's variables, and report only once the tree AGREES that is where the selection sits. The selection is shared editor state — the user can click a frame by hand, which is exactly why the DEFAULT path reads the tree through synced_selection rather than trusting its own memory — and an explicit `frame` was the one place that selected, settled and reported without re-checking. The settle window is short (probe-measured 48–173 ms), so this guards a narrow gap; it earns its place by turning a hand-click landing inside that window into a refusal instead of one frame's variables captioned with another frame's number.
static func _read_selected_frame(state: Dictionary, wanted: int, all: bool, filter := "") -> String:
	if wanted != GDLLMBreak.synced_selection(state):
		var picked: Dictionary = GDLLMBreak.select_frame(wanted)
		if not bool(picked["ok"]):
			return "Error: %s — read it without \"frame\" for the frames that do exist." % String(picked["why"])
		await _settle_break(state)
	var landed := GDLLMBreak.synced_selection(state)
	if landed != wanted:
		return "Error: frame %d was asked for, but the debugger's Stack Frames list now has frame %d selected, so the variables on record are that frame's and reporting them as frame %d's would be a lie. Something else moved the selection while this read settled — another read_game_break in the same turn, or the user clicking a frame by hand. Ask for frame %d again on its own." % [wanted, landed, wanted, wanted]
	return GDLLMBreak.format_break(state, Time.get_ticks_msec(), _whose_run(), all, filter) + GDLLMBreak.armed_note()


## Wait for a break's stack and variables to arrive. The editor requests both on its own the moment the game breaks (probe-measured 48–173 ms behind it), so this is a settle and never a request of its own; a break with no script stack lands complete and returns immediately.
static func _settle_break(state: Dictionary) -> void:
	var deadline := Time.get_ticks_msec() + GDLLMTunables.geti(GDLLMTunables.DEBUGGER_STACK_SETTLE_MS)
	while Time.get_ticks_msec() < deadline and not GDLLMBreak.stack_landed(state):
		await _yield_frame()


## The debug_game tool: press the debugger's own stepping controls and report where execution landed. Repeats ride one call on purpose — a step per tool round would spend a conversation turn on every line — so the result is a trace plus the final state.
static func _debug_game(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, BREAK_ACTION_KEYS + BREAK_TIMES_KEYS + BREAK_ALL_KEYS, DEBUG_GAME_USAGE)
	if unexpected != "":
		return unexpected
	if not Engine.is_editor_hint():
		return "Error: stepping a paused game needs the editor's debugger, and this session is running headless — there is nothing paused to step."
	var action := GDLLMBreak.normalize_action(_arg_string(args, BREAK_ACTION_KEYS))
	if action == "":
		return "Error: no recognized action was given. " + GDLLMTunables.fill(DEBUG_GAME_USAGE)
	GDLLMBreak.ensure_connected()
	var state: Dictionary = GDLLMBreak.current_break()
	if action == "break":
		# The one action whose precondition is the opposite of the others': it needs a game that is RUNNING, and the running game has to be executing GDScript for the press to land anywhere.
		if not state.is_empty():
			return "Error: the game is already paused, so there is nothing to break into. read_game_break reads where it stopped and that frame's variables; debug_game (\"continue\") resumes it, and \"step\"/\"next\"/\"out\" walk it a line at a time."
		if not EditorInterface.is_playing_scene():
			return _no_run_refusal("nothing to break into", "Then break into it while it plays.")
		if GDLLMGame.suspended:
			return "Error: the game is SUSPENDED between frames, so it is executing nothing and a break would never land. Resume it first with suspend_game (\"off\") — or read it where it stands, since a suspended game still answers read_game_ui, inspect_game_node and call_game_method."
	elif state.is_empty():
		return "Error: the game is not paused, so there is nothing to %s. read_game_break says what is true right now; debug_game (\"break\") halts a running game wherever it is, and a game also pauses on its own when a script errors at runtime or reaches a line set_breakpoint armed." % action
	elif action != "continue" and not bool(state.get("can_debug", false)):
		return "Error: this break cannot be stepped — the engine reports it as not steppable, which is what a runtime error break is. Only \"continue\" is offered from here, and it resumes with the failed function abandoned; read_game_break shows the stack and the frame's variables while it is still paused."
	var asked_times := _arg_int(args, BREAK_TIMES_KEYS, 1)
	var times := 1 if action in ["continue", "break"] else clampi(asked_times, 1, GDLLMTunables.geti(GDLLMTunables.DEBUG_GAME_MAX_STEPS))
	# A silent clamp narrates 10 presses as if they were the whole request (audit-caught) — the cut must be named so the model knows to call again for the rest.
	var clamp_note := "" if action in ["continue", "break"] or asked_times <= GDLLMTunables.geti(GDLLMTunables.DEBUG_GAME_MAX_STEPS) else "\n(times was capped at %d of the %d asked — one call presses at most %d; call debug_game again for the rest.)" % [times, asked_times, GDLLMTunables.geti(GDLLMTunables.DEBUG_GAME_MAX_STEPS)]
	var all := _arg_bool(args, BREAK_ALL_KEYS)
	var output_base := GDLLMConsole.output_baseline()
	var errors_base := GDLLMConsole.errors_baseline()
	var trace: Array = []
	var halt := ""
	# The stepping counterpart to suspend_game's budget: a slow game with raised per-step timeouts could otherwise hold the tool loop for minutes; running out reports the presses that landed rather than pressing on.
	var budget_deadline := Time.get_ticks_msec() + GDLLMTunables.geti(GDLLMTunables.DEBUG_GAME_STEP_BUDGET_MS)
	for i in times:
		var current: Dictionary = GDLLMBreak.current_break()
		# "break" is pressed precisely BECAUSE nothing is paused; every other action needs the break it is about to move.
		if current.is_empty() and action != "break":
			break
		if i > 0 and Time.get_ticks_msec() > budget_deadline:
			halt = "the %d ms step budget ran out (raise it in Editor Settings → Gdllm → Tool Runtime)" % GDLLMTunables.geti(GDLLMTunables.DEBUG_GAME_STEP_BUDGET_MS)
			break
		var was_at := int(current.get("at", 0))
		var pressed: Dictionary = GDLLMBreak.press(action)
		if not bool(pressed["ok"]):
			if trace.is_empty():
				return "Error: %s." % String(pressed["why"])
			# A refusal mid-sequence (a step landing on an unsteppable break, say) must be carried, or the short trace reads as the game simply running on.
			halt = String(pressed["why"])
			break
		var landed: Dictionary = await _await_new_break(was_at, GDLLMTunables.geti(GDLLMTunables.BREAK_CONTINUE_WATCH_MS) if action == "continue" else GDLLMTunables.geti(GDLLMTunables.BREAK_ADVANCE_TIMEOUT_MS))
		if landed.is_empty():
			break
		await _settle_break(landed)
		trace.append(GDLLMBreak.trace_entry(landed))
	# Let anything the advanced code printed cross the debugger before the capture reads the panels.
	for i in 5:
		await _yield_frame()
	var halt_note := "" if halt == "" else "\n(Only %d of %d presses landed — %s.)" % [trace.size(), times, halt]
	var capture := format_run_capture(GDLLMConsole.output_delta_since(output_base), GDLLMConsole.errors_delta_since(errors_base), GDLLMConsole.output_hidden_note())
	return GDLLMBreak.format_advance(action, trace, GDLLMBreak.current_break(), _whose_run(), all, Time.get_ticks_msec(), EditorInterface.is_playing_scene()) + clamp_note + halt_note + "\n\n" + capture + GDLLMBreak.armed_note()


## Wait for a break newer than the one just left, or report none: a resume that hits nothing simply keeps running, which is a real outcome and not a timeout to apologize for.
static func _await_new_break(after_ms: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var state: Dictionary = GDLLMBreak.current_break()
		if not state.is_empty() and int(state.get("at", 0)) > after_ms:
			return state
		if not EditorInterface.is_playing_scene():
			return {}
		await _yield_frame()
	return {}


## The set_breakpoint tool: arm or clear one line through the editor's own gutter, so the breakpoint is as visible and as durable as one the user clicked.
static func _set_breakpoint(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, BREAK_PATH_KEYS + BREAK_LINE_KEYS + BREAK_REMOVE_KEYS, SET_BREAKPOINT_USAGE)
	if unexpected != "":
		return unexpected
	if not Engine.is_editor_hint():
		return "Error: a breakpoint is armed through the editor's script gutter, and this session is running headless — there is no editor to arm one in."
	var remove := _arg_bool(args, BREAK_REMOVE_KEYS)
	var requested := _arg_string(args, BREAK_PATH_KEYS)
	var line := _arg_int(args, BREAK_LINE_KEYS, 0)
	if remove and line <= 0:
		return await _clear_armed_breakpoints(requested)
	if requested == "":
		return "Error: no script was given. " + SET_BREAKPOINT_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested, "script")
	if resolved.get_extension().to_lower() != "gd":
		return "Error: %s is not a GDScript file — a breakpoint is armed on a line of a .gd script." % resolved
	if line <= 0:
		return "Error: no line was given, so there is no line to break on. " + SET_BREAKPOINT_USAGE
	var toggled := await _toggle_breakpoint(resolved, line, not remove)
	if not bool(toggled["ok"]):
		return "Error: %s." % String(toggled["why"])
	return GDLLMBreak.format_armed(resolved, line, not remove, String(toggled["note"]), String(toggled["text"]), EditorInterface.is_playing_scene(), bool(toggled.get("unhittable", false)), String(toggled.get("hot", ""))) + GDLLMBreak.armed_note()


## Open one script, reach its gutter, and toggle one line — the shared half of arming and clearing. {"ok", "why", "note", "text"}.
static func _toggle_breakpoint(path: String, line: int, enabled: bool) -> Dictionary:
	var opened: Dictionary = GDLLMBreak.open_script(path, line)
	if not bool(opened["ok"]):
		return {"ok": false, "why": String(opened["why"]), "note": "", "text": ""}
	# The script editor builds its text control over the frames after the open, so its gutter is only reachable once they pass.
	for i in GDLLMTunables.geti(GDLLMTunables.BREAK_EDITOR_FRAMES):
		await _yield_frame()
	var found: Dictionary = GDLLMBreak.code_edit_for(path)
	if not bool(found["ok"]):
		return {"ok": false, "why": String(found["why"]), "note": "", "text": ""}
	var result: Dictionary = GDLLMBreak.toggle_line(found["code"], line, enabled, _disk_line(path, line))
	if bool(result["ok"]):
		GDLLMBreak.record_armed(path, line, enabled)
	return result


## One line of a file as it stands on disk, 1-based, so an arming report can compare it against the editor buffer the breakpoint actually landed in.
static func _disk_line(path: String, line: int) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var lines := file.get_as_text().split("\n")
	file.close()
	return String(lines[line - 1]) if line >= 1 and line <= lines.size() else ""


## Clear the breakpoints this session armed — the cleanup lever every arming report names, since a breakpoint outlives the editor session. Breakpoints the USER set by hand are never touched: this session did not arm them, so removing them is not its call.
static func _clear_armed_breakpoints(requested: String) -> String:
	var only := ""
	if requested != "":
		only = _resolve_file_path(requested)
		if only == "":
			return _file_not_found(requested, "script")
	var targets: Array = []
	for entry: Array in GDLLMBreak.armed_list():
		if only == "" or String(entry[0]) == only:
			targets.append(entry)
	if targets.is_empty():
		return "Nothing to clear: this session has armed no breakpoints%s. Any breakpoints in the debugger's Breakpoints list are the user's own and are left alone; to remove one of those, pass its script and line explicitly with \"remove\": true." % ("" if only == "" else " in %s" % only)
	var cleared: Array = []
	var failed: Array = []
	for entry: Array in targets:
		var path := String(entry[0])
		var line := int(entry[1])
		var toggled := await _toggle_breakpoint(path, line, false)
		if bool(toggled["ok"]):
			cleared.append("%s:%d" % [path.get_file(), line])
		else:
			failed.append("%s:%d (%s)" % [path.get_file(), line, String(toggled["why"])])
	var lines: Array = []
	if not cleared.is_empty():
		lines.append("Cleared %d breakpoint(s) this session had armed: %s — the game no longer pauses there." % [cleared.size(), ", ".join(PackedStringArray(cleared))])
	if not failed.is_empty():
		lines.append("Could not clear %s — the user can remove those from the script's gutter or the debugger's Breakpoints list." % ", ".join(PackedStringArray(failed)))
	return "\n".join(PackedStringArray(lines)) + GDLLMBreak.armed_note()


## Pure composer for call_game_method's verdict; the value is display data — sanitized game-side, stringified here — never a live reference.
static func format_game_call(reply: Dictionary, path: String, method: String, call_args: Array, whose: String) -> String:
	if not bool(reply.get("ok", false)):
		return "Error: %s" % String(reply.get("why", "the game agent gave no reason"))
	var value: Variant = reply.get("value")
	var value_text := "\"%s\"" % value if value is String else str(value)
	return "Called %s.%s(%s) in %s — returned %s (%s)." % [path, method, str(call_args).trim_prefix("[").trim_suffix("]"), whose, value_text, String(reply.get("type", "?"))]


## Whose play session the game-driving tools acted on, in profile_game's wording — a user session may be driven but never silently.
static func _whose_run() -> String:
	return "the user's running session" if _game_run.is_empty() else "the run this session started"


## The disclosure when several debug sessions are live (Run Multiple Instances): the command went to one game, and which one is ambiguous enough to name.
static func _multi_session_note(active: int) -> String:
	if active <= 1:
		return ""
	return "\n(%d debug sessions are live — a multi-instance run — and the command went to the first with a game agent.)" % active


## The one refusal every game tool gives when nothing is playing. `what` completes "so there is …" and `extra` carries whatever that tool alone can add. Kept in one place because five copies had drifted apart, and the weakest of them — profile_game's, which named a `profile` flag but never `keep_running` — sent a wild run into three launches that each stopped again, ending its turn on the consecutive-use guard just as it finally got the arguments right. A refusal that names the lever is the whole doctrine; naming it five times in five wordings is how one of them ends up missing it.
static func _no_run_refusal(what: String, extra: String = "") -> String:
	var lead := "Error: nothing is running, so there is %s. Start one with run_game — pass \"keep_running\": true so the game stays up for this call to reach, since a run without it stops as soon as its capture ends — or ask the user to play, because their own session works too." % what
	return lead if extra == "" else lead + " " + extra


## The refusal ladder shared by the game-driving tools, each rung naming its lever; `verb` keeps the wording honest per tool ("read", "drive", "reach").
static func _game_reach_error(verb: String, kind: String, why: String) -> String:
	match kind:
		"headless":
			return "Error: the running game is reached over the editor's debugger, and this session is running headless — there is no game to %s." % verb
		"no_bridge":
			return "Error: the debugger bridge is not registered — the plugin needs a reload (Project Settings → Plugins)."
		"not_running":
			return _no_run_refusal("no game to %s" % verb)
		"starting":
			return "Error: the game is still starting — its debug session is not active yet. " + TRANSIENT_RETRY_INVITATION
		"breaked_late":
			return "Error: the game hit a BREAKPOINT while it was answering, so the reply never came (%s) — it is paused now, and whatever this call had already begun may be half-done. read_game_break shows where it stopped; debug_game (\"continue\") resumes it, and clearing the breakpoint first (set_breakpoint with \"remove\") is what stops it pausing again straight away." % why
		"breaked":
			return "Error: the game is paused in the debugger, so the agent inside it cannot answer — no frames pass while it is stopped. read_game_break shows what stopped it, where, and that frame's variables; debug_game steps or resumes it (\"continue\"), and then this call works again."
		"no_agent":
			return "Error: the running game carries no game agent to %s it through — it was launched before the plugin registered the GDLLMGameAgent autoload, or the Register Game Input Agent setting removed it. Stop the run and start it again; every new run loads the agent." % verb
		"version":
			return "Error: %s — the plugin updated while the game was running. Stop the run and start it again so it loads the current agent." % why
		"ended":
			return "Error: the game ended before it answered — read_output and read_errors show what it printed and errored on the way down."
		"timeout":
			return "Error: the game did not answer (%s) — it may be frozen, heavily loaded, or stuck; read_performance and read_errors can say more." % why
	return "Error: the game could not be reached (%s)." % kind


## search_docs: argument extraction only — the full-text lookup itself lives with the rest of the doc-cache logic in GDLLMDocs.
static func _search_docs(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, QUERY_KEYS, SEARCH_DOCS_USAGE)
	if unexpected != "":
		return unexpected
	var query := _arg_string(args, QUERY_KEYS)
	if query == "":
		return "Error: no search query was provided. " + SEARCH_DOCS_USAGE
	return await GDLLMDocs.search(query)


## describe_project: argument extraction only — the ProjectSettings reading lives in GDLLMProject.
static func _describe_project(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, PROJECT_SETTING_KEYS + PROJECT_FILTER_KEYS, DESCRIBE_PROJECT_USAGE)
	if unexpected != "":
		return unexpected
	return GDLLMProject.describe(_arg_string(args, PROJECT_SETTING_KEYS), _arg_string(args, PROJECT_FILTER_KEYS))


## set_project_setting: extract the name, the raw value (kept a Variant — its shape depends on the setting's domain), and the flags, then hand off to GDLLMProject. A call that spells an input action naturally — "events" (plus optional "deadzone") instead of "value" — is folded into the value object rather than rejected.
static func _set_project_setting(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, PROJECT_SETTING_KEYS + SET_SETTING_VALUE_KEYS + SET_SETTING_REVERT_KEYS + SET_SETTING_CREATE_KEYS + ["events", "deadzone"], SET_PROJECT_SETTING_USAGE)
	if unexpected != "":
		return unexpected
	var setting := _arg_string(args, PROJECT_SETTING_KEYS)
	if setting == "":
		return "Error: no setting name was provided. " + SET_PROJECT_SETTING_USAGE
	var value: Variant = null
	var has_value := false
	for key in SET_SETTING_VALUE_KEYS:
		if args.has(key):
			value = args[key]
			has_value = true
			break
	if not has_value and args.has("events"):
		value = {"events": args["events"], "deadzone": args.get("deadzone", GDLLMProject.DEFAULT_DEADZONE)}
		has_value = true
	return GDLLMProject.apply(setting, value, has_value, _arg_bool(args, SET_SETTING_REVERT_KEYS), _arg_bool(args, SET_SETTING_CREATE_KEYS))


## The note a write to a `.import` earns, and the re-import that makes the write mean anything — "" for every other file.
## This is the hole the audit named: a `.import` edited by hand changed nothing until the user happened to rescan, and both write tools reported an ordinary success, so the model believed a setting had been applied that had not been.
## The re-import runs here rather than being suggested, because the write has already happened and leaving the project in a state the result misdescribes is the failure itself; what cannot be honestly claimed is disclosed instead.
## GDLLMImport.reimport is called directly rather than through _reimport_asset: both write tools call this from INSIDE their own mutation lock, and taking it a second time would spin forever against the holder that is waiting on this call.
static func _import_write_note(dest: String) -> String:
	if not GDLLMImport.is_import_file(dest):
		return ""
	var asset := GDLLMImport.asset_path_for(dest)
	if not Engine.is_editor_hint():
		return "\n\nNOTE: this is a .import sidecar, and editing one changes nothing on its own — the asset is only rebuilt when the editor re-imports it. This session is headless, so that could not be done here; %s still holds its PREVIOUS import." % asset
	if not FileAccess.file_exists(asset):
		return "\n\nNOTE: this is a .import sidecar but %s does not exist, so there is no asset to import and this file is an orphan." % asset
	var done := GDLLMImport.reimport(asset)
	if not bool(done["ok"]):
		return "\n\nNOTE: this is a .import sidecar, and the asset could NOT be re-imported (%s), so %s still holds its previous import — the edit has not taken effect." % [str(done["why"]), asset]
	var state := GDLLMImport.valid_state(asset)
	if state == "invalid":
		return "\n\nThe asset %s was re-imported so the edit takes effect, but it now FAILS to import — loading it will fail until this is corrected. read_errors carries the engine's reason. Prefer set_import_setting over hand-editing a .import: it validates a setting's name before writing, where the engine silently drops one it does not recognize." % asset
	return "\n\nThe asset %s was re-imported, so the edit is live rather than waiting for a rescan. Prefer set_import_setting for this: it validates a setting's name before writing, where the engine silently drops one it does not recognize and reports nothing." % asset


## set_import_setting: change an asset's import settings and re-import it, or re-import it unchanged when no settings are given.
## The order is deliberate — validate the names BEFORE writing, because the engine's own reaction to a name it does not know is to drop it in silence (probe-measured on 4.7), so a write made first would be unrecoverable as a report: the file would come back holding neither the old value nor the new one, with nothing to say which happened.
static func _set_import_setting(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, FILE_PATH_KEYS + IMPORT_SETTINGS_KEYS, SET_IMPORT_SETTING_USAGE)
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, FILE_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + SET_IMPORT_SETTING_USAGE
	if not Engine.is_editor_hint():
		return "Error: re-importing an asset is the editor's own operation and this session is running headless — there is no EditorFileSystem to drive, so import settings cannot be changed."
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var asset := GDLLMImport.asset_path_for(resolved)
	var refusal := GDLLMImport.importable_refusal(asset)
	if refusal != "":
		return refusal
	var settings := _import_settings_arg(args)
	if settings == null:
		return "Error: \"settings\" must be an object of import setting names to values, e.g. {\"compress/mode\": 0}. " + SET_IMPORT_SETTING_USAGE
	var before := GDLLMImport.read_import(asset)
	var typed := {}
	if not (settings as Dictionary).is_empty():
		if not bool(before["ok"]):
			return "Error: %s cannot have its import settings changed — %s. Call this tool with no \"settings\" first to import it, then set them." % [asset, str(before["why"])]
		var unknown := GDLLMImport.unknown_param_refusal(settings, before)
		if unknown != "":
			return unknown
		var importer := str(before["importer"])
		for key: String in settings:
			# Values are resolved before coercion: an enum given by NAME is a string that coercion would push into the option's int type as garbage, and an out-of-range index has to be refused rather than typed.
			var resolved_value := GDLLMImport.resolve_value(importer, key, settings[key])
			if not bool(resolved_value["ok"]):
				# The batch is applied as one unit, so the settings NOT at fault were withheld too — saying so is what stops the whole call being resent unchanged.
				return str(resolved_value["why"]) + GDLLMImport.batch_withheld_note(settings, [key])
			typed[key] = GDLLMImport.coerce_param(resolved_value["value"], (before["params"] as Dictionary).get(key))
		var written := GDLLMImport.write_params(str(before["import_file"]), typed)
		if not bool(written["ok"]):
			return "Error: %s was not changed — %s" % [asset, str(written["why"])]
	var done := await _reimport_asset(asset)
	if not bool(done["ok"]):
		return "Error: %s" % str(done["why"])
	return _import_report(asset, typed, before)


## Drive the editor's re-import under the mutation lock, so a validation subprocess or a project scan can't read the asset mid-rewrite.
static func _reimport_asset(asset: String) -> Dictionary:
	await _acquire_mutation_lock()
	var done := GDLLMImport.reimport(asset)
	_mutation_busy = false
	return done


## The verdict after a re-import: what the settings actually became, and whether the asset imports at all.
## The settings are read back from the file rather than echoed, because only the engine decides which survive an import — and the import's own success is asked of the editor, since an asset whose import failed loads as nothing and silence about that would be the worst possible report.
static func _import_report(asset: String, requested: Dictionary, before: Dictionary) -> String:
	var after := GDLLMImport.read_import(asset)
	var state := GDLLMImport.valid_state(asset)
	var lines: Array[String] = []
	if requested.is_empty():
		lines.append("Re-imported %s." % asset)
	else:
		var check := GDLLMImport.verify_params(after, requested, before["params"] if bool(before["ok"]) else {}, str(after["importer"]))
		var took: Array = check["took"]
		var dropped: Array = check["dropped"]
		var unchanged: Array = check["unchanged"]
		if not took.is_empty():
			lines.append("Re-imported %s with %d import setting(s) changed:" % [asset, took.size()])
			for t: String in took:
				lines.append("  %s" % t)
		elif not unchanged.is_empty() and dropped.is_empty():
			lines.append("Re-imported %s, but NOTHING changed — it already held every value asked for." % asset)
		else:
			lines.append("Re-imported %s, but none of the requested settings took." % asset)
		if not unchanged.is_empty() and not took.is_empty():
			# A value that was already what was asked for is not a change, and a report that counts it as one is how a run that did nothing reads as a run that fixed something.
			lines.append("Already held that value (unchanged): %s" % ", ".join(unchanged))
		if not dropped.is_empty():
			# The second witness on the silent-drop failure: the pre-write guard should make this unreachable, so reaching it means the importer itself refused the value.
			lines.append("The importer did NOT accept: %s. It rewrote those on import, which means it rejected the value rather than the name — check the value's range or type against the .import file." % ", ".join(dropped))
		# Every CHOICE option touched spells its full list out, once per option: wild-measured, a run that set one correctly then recited the whole enum to the user from memory and got three of four values wrong, because a result naming only the value it set leaves the rest to be guessed at.
		for key: String in requested:
			var legend := GDLLMImport.value_legend(str(after["importer"]), key)
			if legend != "":
				lines.append("(%s)" % legend)
	if state == "invalid":
		lines.append("WARNING: %s does NOT import successfully in this state — the engine produced no imported file, so loading it will fail. read_errors and read_output carry the engine's reason; fix the cause and call this tool again." % asset)
	elif state == "unloadable":
		# The import step reported success and the result is still unusable, so saying only "re-imported" would be true and useless.
		# The two cases get different advice because the earlier single wording told a plain re-import to "check the value just set" when nothing had been set — wild-measured, the run that read it concluded the SOURCE FILE was corrupt and reported that to the user.
		if requested.is_empty():
			lines.append("WARNING: the import ran, but what it produced does NOT load — anything using %s gets nothing. This call changed no settings, so it did not cause this: one of the settings ALREADY on the file is holding a value its importer cannot use. Read the .import with \"full\": true and look for a value outside its option's range, and read read_errors/read_output for the engine's own message about it." % asset)
		else:
			lines.append("WARNING: the import ran, but what it produced does NOT load — anything using %s now gets nothing. Check the value just set against what the importer accepts and set it back if this call is what broke it; read_errors/read_output carry the engine's own message." % asset)
	elif state == "valid":
		lines.append("It imports cleanly%s, and the imported result loads." % (" as %s" % str(after["type"]) if str(after["type"]) != "" else ""))
	if str(after["uid"]) != "" and str(after["uid"]) != str(before.get("uid", "")):
		lines.append("Its uid is %s." % str(after["uid"]))
	lines.append("The change is live in the editor — no rescan is needed. It affects the asset itself, so everything that uses it picks it up; a game already running does not, since it loaded the old import at startup.")
	return "\n".join(lines)


## The `settings` argument as a Dictionary, {} when absent, or null when it was given as something that is not an object.
static func _import_settings_arg(args: Dictionary) -> Variant:
	for key in IMPORT_SETTINGS_KEYS:
		if args.has(key):
			var raw: Variant = args[key]
			if raw is Dictionary:
				return raw
			# A model that spelled the object as JSON text is answered rather than refused for the quoting alone.
			if raw is String:
				var parsed: Variant = JSON.parse_string(str(raw))
				return parsed if parsed is Dictionary else null
			return null
	return {}


## list_dependencies: engine-truth resource wiring in both directions — what a file depends on, or with `reverse` every project file that references it.
static func _list_dependencies(args: Dictionary) -> String:
	var unexpected := _unexpected_arg_error(args, DEPS_PATH_KEYS + DEPS_REVERSE_KEYS + LIST_FULL_KEYS, LIST_DEPENDENCIES_USAGE)
	if unexpected != "":
		return unexpected
	var requested := _arg_string(args, DEPS_PATH_KEYS)
	if requested == "":
		return "Error: no path was provided. " + LIST_DEPENDENCIES_USAGE
	var resolved := _resolve_file_path(requested)
	if resolved == "":
		return _file_not_found(requested)
	var full := _arg_bool(args, LIST_FULL_KEYS)
	if _arg_bool(args, DEPS_REVERSE_KEYS):
		return _scene_divergence_note(resolved) + await _reverse_dependencies(resolved, full)
	return _scene_divergence_note(resolved) + _forward_dependencies(resolved, full)


## The forward direction: a scene/resource file's engine dependency records, or for a text file (a script) the res:// and uid:// literals it mentions, since the engine does not record script preloads. Imported binaries (textures, audio) carry no dependencies of their own.
static func _forward_dependencies(resolved: String, full := false) -> String:
	var ext := resolved.get_extension().to_lower()
	var lines: Array = []
	var source_note := ""
	if DEP_RESOURCE_EXTENSIONS.has(ext):
		for entry in ResourceLoader.get_dependencies(resolved):
			lines.append(_dependency_line(String(entry)))
		source_note = " (engine dependency records)"
	elif not _looks_binary(resolved):
		for ref in _text_resource_refs(resolved):
			if ref != resolved:
				lines.append(_text_ref_line(ref))
		source_note = " (res:// and uid:// literals in its text — a dynamically built path can't be found this way)"
	else:
		return "%s is a binary asset with no dependency records of its own; it depends on nothing. Call list_dependencies with reverse=true to see what uses it." % resolved
	if lines.is_empty():
		return "%s depends on no other resources%s." % [resolved, source_note]
	var out: Array = ["%s depends on %d resource(s)%s:" % [resolved, lines.size(), source_note]]
	out.append_array(_capped_lines(lines, full))
	return "\n".join(out)


## Worker wrapper for _reverse_dependencies_scan — the whole-project walk runs off the main thread in-editor (see run_on_worker).
static func _reverse_dependencies(resolved: String, full := false) -> String:
	var out: String = await run_on_worker(func() -> String: return _reverse_dependencies_scan(resolved, full))
	return out


## The reverse direction: walk the whole project and report every file referencing `resolved` — scenes and resources through engine dependency records (which see UID-based and binary references), scripts and project.godot by literal text match on the path and its uid://.
static func _reverse_dependencies_scan(resolved: String, full := false) -> String:
	var uid_text := _uid_text_for(resolved)
	var files: Array = []
	_collect_text_files("res://", files)
	var users: Array = []
	for path_v in files:
		var path := String(path_v)
		if path == resolved:
			continue
		var ext := path.get_extension().to_lower()
		if DEP_RESOURCE_EXTENSIONS.has(ext):
			var marker := _deps_reference_marker(path, resolved, uid_text)
			if marker != "-":
				users.append("- %s%s" % [path, marker])
		elif ext == "gd" or path.get_file() == "project.godot":
			var marker := _text_reference_marker(path, resolved, uid_text)
			if marker != "-":
				users.append("- %s%s" % [path, marker])
	var checked_note := "Scenes and resources were checked through engine dependency records (which see UID-based and binary references); scripts and project.godot by literal text match. A path assembled dynamically in code can't be found this way."
	if users.is_empty():
		return "Nothing in the project references %s. %s" % [resolved, checked_note]
	var out: Array = ["%d file(s) reference %s:" % [users.size(), resolved]]
	out.append_array(_capped_lines(users, full))
	out.append(checked_note)
	return "\n".join(out)


## One engine dependency entry rendered readably: the recorded path when it still exists, the UID's current location when the file moved, and an explicit MISSING flag when the reference resolves nowhere.
static func _dependency_line(entry: String) -> String:
	var parsed := _parse_dependency_entry(entry)
	var path := String(parsed["path"])
	var current := _uid_current_path(String(parsed["uid"]))
	if current != "" and current != path:
		return "- %s (recorded under the stale path %s; its UID resolves here now)" % [current, path]
	if path != "" and FileAccess.file_exists(path):
		return "- " + path
	if current != "":
		return "- " + current
	var display := path if path != "" else String(parsed["uid"])
	return "- %s (MISSING — resolves to no existing file)" % display


## One text-scanned reference rendered like a dependency line, resolving a uid:// literal to its current file when the cache knows it.
static func _text_ref_line(ref: String) -> String:
	if ref.begins_with("uid://"):
		var current := _uid_current_path(ref)
		if current != "":
			return "- %s (referenced as %s)" % [current, ref]
		return "- %s (a UID this project doesn't resolve — possibly stale)" % ref
	if FileAccess.file_exists(ref):
		return "- " + ref
	return "- %s (MISSING — no such file)" % ref


## Split one engine dependency entry ("uid://…::<type>::res://…", or a bare path) into its uid and path parts; either may be absent.
static func _parse_dependency_entry(entry: String) -> Dictionary:
	var uid := ""
	var path := ""
	for token in entry.split("::"):
		if token.begins_with("uid://"):
			uid = token
		elif token != "":
			path = token
	return {"uid": uid, "path": path}


## A uid:// text's current res:// location per the editor's UID cache, or "" when it doesn't resolve.
static func _uid_current_path(uid_text: String) -> String:
	if not uid_text.begins_with("uid://"):
		return ""
	var id := ResourceUID.text_to_id(uid_text)
	if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
		return ""
	return ResourceUID.get_id_path(id)


## The uid:// text identifying a project file, tried from the loader's cache first and then from where the uid physically lives — a .uid sidecar (scripts), the file's own header tag (.tscn/.tres), or its .import (imported assets) — so UID matching works even where the cache is cold. The in-file probe accepts ONLY the [gd_scene]/[gd_resource] header's uid: in a headerless file the first uid= belongs to an [ext_resource] dependency, and reporting that as the file's own sent a session preloading its new boon through the AugIncrement script's uid (transcript-observed) — no answer beats a wrong one. The .import probe can stay a plain scan, since an .import carries no uid but its asset's.
static func _uid_text_for(resolved: String) -> String:
	var id := ResourceLoader.get_resource_uid(resolved)
	if id != ResourceUID.INVALID_ID:
		return ResourceUID.id_to_text(id)
	if FileAccess.file_exists(resolved + ".uid"):
		var sidecar := FileAccess.get_file_as_string(resolved + ".uid").strip_edges()
		if sidecar.begins_with("uid://"):
			return sidecar
	if FileAccess.file_exists(resolved) and not _looks_binary(resolved):
		var header := RegEx.create_from_string("^\\[gd_(?:scene|resource)\\b[^\\]]*?\\buid=\"(uid://[^\"]*)\"")
		var found := header.search(FileAccess.get_file_as_string(resolved))
		if found != null:
			return found.get_string(1)
	var import_path := resolved + ".import"
	if FileAccess.file_exists(import_path) and not _looks_binary(import_path):
		var text := FileAccess.get_file_as_string(import_path)
		var at := text.find("uid=\"uid://")
		if at != -1:
			var value_start := at + 5
			var value_end := text.find("\"", value_start)
			if value_end > value_start:
				return text.substr(value_start, value_end - value_start)
	return ""


## Whether one resource file's dependency records reference the target: "" for a plain path match, an explanatory marker for a UID-only match (whose recorded path went stale), "-" for no reference.
static func _deps_reference_marker(path: String, target: String, uid_text: String) -> String:
	for entry in ResourceLoader.get_dependencies(path):
		var parsed := _parse_dependency_entry(String(entry))
		if String(parsed["path"]) == target:
			return ""
		if uid_text != "" and String(parsed["uid"]) == uid_text:
			return " (by UID — the recorded path %s is stale)" % parsed["path"] if String(parsed["path"]) != "" else " (by UID)"
	return "-"


## Whether one text file (a script or project.godot) literally mentions the target's path or uid://: "" for a path mention, a marker for uid-only, "-" for neither.
static func _text_reference_marker(path: String, target: String, uid_text: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "-"
	var text := file.get_as_text()
	if text.contains(target):
		return " (project settings)" if path.get_file() == "project.godot" else ""
	if uid_text != "" and text.contains(uid_text):
		return " (by UID%s)" % (" — project settings" if path.get_file() == "project.godot" else "")
	return "-"


## Every res:// and uid:// literal in a text file, in order of first appearance, deduplicated — the script-side stand-in for engine dependency records.
static func _text_resource_refs(path: String) -> Array[String]:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var text := file.get_as_text()
	var refs: Array[String] = []
	for prefix: String in ["res://", "uid://"]:
		var from := 0
		while true:
			var at := text.find(prefix, from)
			if at == -1:
				break
			var end := at + prefix.length()
			while end < text.length() and not _is_ref_terminator(text.unicode_at(end)):
				end += 1
			from = end
			var ref := text.substr(at, end - at).rstrip(".,:;!?*…")
			if ref.length() > prefix.length() and not refs.has(ref):
				refs.append(ref)
	return refs


## Whether a character ends a res://-path literal: quotes, whitespace, backslash (an escape inside a string literal), and the bracketing/separator punctuation that can't appear in a project path.
static func _is_ref_terminator(c: int) -> bool:
	const TERMINATORS: PackedInt32Array = [34, 39, 40, 41, 91, 93, 123, 125, 44, 59, 60, 62, 92, 32, 9, 10, 13] # " ' ( ) [ ] { } , ; < > \ and whitespace
	return TERMINATORS.has(c)


## A dependency listing capped at GDLLMTunables.DEPENDENCY_LINES_CAP with a remainder note naming the waiver, so a hub resource never floods the context by default — but `full` serves every line, because these are engine-record references no other tool can recover (search_files misses UID-based and binary ones by construction).
static func _capped_lines(lines: Array, full := false) -> Array:
	var cap := GDLLMTunables.geti(GDLLMTunables.DEPENDENCY_LINES_CAP)
	if full or lines.size() <= cap:
		return lines
	var out: Array = lines.slice(0, cap)
	out.append("(and %d more not shown — pass full: true for every line)" % (lines.size() - cap))
	return out


## One chat session's tool-layer memory, passed through execute() so nothing leaks across sessions: one tab's reads must not unlock edit_file for another, and one tab's broken files must not nag another. A session's subagents share its ledger, since they work on that session's behalf. The transport guards (_mutation_busy and friends) stay static — they serialize genuinely shared resources (disk, validation subprocesses) across every session.
class SessionLedger:
	## Files whose real text the session's model has seen this editor run, by resolved path: true when verbatim text was returned (a full read_file, a read_function hit, search_files excerpts, or a write_file the model authored), false when only a shape was shown (read_file's long-file map, a search overview). edit_file refuses a path not marked true — session transcripts showed models editing files from memory, and every such old_string is a guess.
	var seen_files: Dictionary = {}
	## Data-carrying files by resolved path, tri-state: true = a raw-text server (read_file, search_files, read_function) elided a packed-array payload the session has never held, so a wholesale write_file rebuilt from that view would silently destroy it (see _write_overwrite_seen_guard); false = STICKY disarm — the model has held every byte (a whole-file full:true read, or an authored write whose content carries payloads), so later elided VIEWS must not re-arm the gate (wild-measured false positive: a post-full-read search re-stamped the file and the model forced through the refusal); absent = nothing elidable ever surfaced. Like seen_files, the record outlives external edits to the file; edit_file stays ungated, because it keeps every byte outside the matched region.
	var elided_files: Dictionary = {}
	## The on-disk text the last successful edit_file/write_file replaced, by resolved path — ONE generation of real history, kept solely to make one error truthful: a model that rewrote a file and then edits from its memory of the old text is told the actual cause (a stale copy) instead of whitespace advice (see _edit_file_not_found_message). Never written back to disk.
	var previous_contents: Dictionary = {}
	## The last check_script report per resolved path (md5 of the grouped error lines), so an unchanged report — a broken file nobody has touched — collapses to one line instead of re-dumping (see _check_script_hook).
	var auto_check_reports: Dictionary = {}
	## Files an edit_file/write_file verdict left BROKEN on disk and nothing has validated clean since, by resolved path — the ground truth behind the broken_reminder hook, so a model can't wander off mid-repair and later claim success (see _broken_reminder_hook). Cleared per path when the same path validates clean again (a clean edit_file/write_file on it, or check_script reporting it clean).
	var broken_files: Dictionary = {}
	## Completed calls the broken_reminder hook still skips before it may fire again — the configurable rate limit (GDLLMTunables.BROKEN_REMINDER_COOLDOWN) that keeps the reminder a nudge instead of a per-call nag.
	var broken_reminder_cooldown: int = 0
	## Importers whose numeric-choice legend a .import read has already spelled out this session, by importer name — the block is per-importer and identical every time, so a session reading six textures paid for it six times (wild-measured: 71% of all legend characters were duplicates). A repeat gets a pointer naming the choice options and the by-name spelling instead (see GDLLMImport.legend_block).
	var legended_importers: Dictionary = {}
	## Invented uids the write-time lint replaced with engine-assigned ones this session, invented text → real text — so a later reference to the invented uid (a model coordinating a script and a resource it authored, in either order, including across its subagents) is substituted with the real one instead of landing broken, and error attributions can name what the invented uid became (see _lint_new_uid_refs and _uid_error_attribution).
	var replaced_uids: Dictionary = {}
