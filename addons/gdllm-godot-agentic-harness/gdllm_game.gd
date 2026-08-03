@tool
class_name GDLLMGame extends RefCounted
## Editor-side transport for the game-driving tools: sends "gdllm:cmd" requests to the agent autoload inside the running game through the registered GDLLMDebuggerBridge and matches its "gdllm:result" replies back by request id. This class only moves messages and states why it can't — every tool result's prose lives with the tool bodies in GDLLMTools, so a transport failure comes back as a {why_kind, why} pair for the caller to word. Every method is static — this is a namespace, not an instance.

# The presence-probe ping budget is user-configurable — see GDLLMTunables' gdllm/tool_runtime section: long enough for a frame round-trip on a loaded game, short enough that refusing an agent-less run doesn't park the tool loop.

## The registered GDLLMDebuggerBridge, set by the plugin at load, the only scriptable route to EditorDebuggerSession objects.
static var bridge: EditorDebuggerPlugin = null
## Debugger sessions by the session id _setup_session reported, so hellos and replies can be matched to a sendable session object.
static var _sessions: Dictionary = {}
## Agent protocol version per session id, recorded from each run's hello (or a successful ping probe) and erased when its session stops.
static var _agents: Dictionary = {}
## Replies awaiting pickup, keyed by request id.
static var _pending: Dictionary = {}
static var _next_id: int = 1
## Whether this editor has the running game's scene processing suspended (see send_scene): editor-side knowledge, since the freeze is a message we sent and the game reports nothing about it. Cleared when any run ends, because a new process starts unsuspended.
static var suspended: bool = false


## Adopt a debugger session the bridge just learned about; its stopped signal retires the run's agent record, so a later run must say hello again.
static func track_session(session: EditorDebuggerSession, session_id: int) -> void:
	if session == null or _sessions.has(session_id):
		return
	_sessions[session_id] = session
	session.stopped.connect(func() -> void:
		_agents.erase(session_id)
		suspended = false)


## One captured "gdllm:*" message from a game process; returns true so the bridge marks it consumed either way.
static func on_capture(message: String, data: Array, session_id: int) -> bool:
	if message == "gdllm:hello":
		_agents[session_id] = int(data[0]) if data.size() >= 1 else 0
	elif message == "gdllm:result" and data.size() == 2 and data[1] is Dictionary:
		_pending[int(data[0])] = data[1]
	return true


## Send one command to the running game's agent and await its reply: {"ok", "reply", "active", "why_kind", "why"}. A false ok names its rung — "headless", "no_bridge", "not_running", "starting", "breaked", "no_agent", "version", "ended", or "timeout" — for the tool body to word; `active` counts the live debug sessions so multi-instance runs can be disclosed. In-editor this is a coroutine (frames pass while the game answers); the headless rung resolves synchronously, which the tests rely on.
static func command(payload: Dictionary, timeout_ms: int) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("headless")
	if bridge == null:
		return _fail("no_bridge")
	var live := _active_sessions()
	if live.is_empty():
		return _fail("starting" if EditorInterface.is_playing_scene() else "not_running")
	var chosen_id := -1
	for entry: Array in live:
		if _agents.has(int(entry[0])):
			chosen_id = int(entry[0])
			break
	if chosen_id < 0:
		# The hello can be lost to an editor reload mid-run, so probe before refusing; a real agent answers a ping inside the probe window.
		var probe_id := int(live[0][0])
		var pong := await _roundtrip(_sessions[probe_id], {"op": "ping"}, GDLLMTunables.geti(GDLLMTunables.GAME_PING_TIMEOUT_MS))
		if not bool(pong["ok"]):
			return _fail("no_agent")
		_agents[probe_id] = int((pong["reply"] as Dictionary).get("version", 0))
		chosen_id = probe_id
	if int(_agents[chosen_id]) != GDLLMGameProtocol.VERSION:
		return _fail("version", "the run carries agent protocol %d and this editor speaks %d" % [int(_agents[chosen_id]), GDLLMGameProtocol.VERSION])
	var session: EditorDebuggerSession = _sessions[chosen_id]
	if session.is_breaked():
		return _fail("breaked")
	var out := await _roundtrip(session, payload, timeout_ms)
	if not bool(out["ok"]):
		# A command that goes unanswered because the game BROKE while answering is not a frozen or overloaded game, and saying so sent wild runs looking for a performance problem that was not there. The break is the answer, and it may have arrived part-way through the work.
		if String(out["why_kind"]) == "timeout" and session.is_breaked():
			return _fail("breaked_late", "no answer within %.1f s" % (timeout_ms / 1000.0))
		return _fail(String(out["why_kind"]), "no answer within %.1f s" % (timeout_ms / 1000.0))
	return {"ok": true, "reply": out["reply"], "active": live.size(), "why_kind": "", "why": ""}


## Whether the presently running game has a live agent recorded — the cheap presence check UI affordances may read; tools go through command, whose probe is authoritative.
static func agent_recorded() -> bool:
	for entry: Array in _active_sessions():
		if _agents.has(int(entry[0])):
			return true
	return false


## Send one of the ENGINE's own "scene:" messages to the running game. These are handled by the core debugger inside the game process, not by the agent autoload, so no hello, no protocol version and no reply are involved — which is exactly why the ladder here is shorter than command's: only the transport itself can fail. {"ok", "active", "why_kind", "why"}.
static func send_scene(message: String, data: Array) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("headless")
	if bridge == null:
		return _fail("no_bridge")
	var live := _active_sessions()
	if live.is_empty():
		return _fail("starting" if EditorInterface.is_playing_scene() else "not_running")
	var session: EditorDebuggerSession = live[0][1]
	# A game stopped at a breakpoint is frozen by the DEBUGGER, a different freeze with a different key: scene messages queue up unheard until it resumes.
	if session.is_breaked():
		return _fail("breaked")
	session.send_message(message, data)
	return {"ok": true, "reply": {}, "active": live.size(), "why_kind": "", "why": ""}


static func _fail(kind: String, why: String = "") -> Dictionary:
	return {"ok": false, "reply": {}, "active": 0, "why_kind": kind, "why": why}


## The tracked sessions currently attached to a running game, as [session_id, session] pairs in tracking order.
static func _active_sessions() -> Array:
	var live: Array = []
	for session_id in _sessions:
		var session: EditorDebuggerSession = _sessions[session_id]
		if session != null and session.is_active():
			live.append([session_id, session])
	return live


## One request/reply exchange on one session: {"ok", "reply", "why_kind"}. A session going inactive mid-wait is the game ending, not a timeout, and is named apart.
static func _roundtrip(session: EditorDebuggerSession, payload: Dictionary, timeout_ms: int) -> Dictionary:
	var id := _next_id
	_next_id += 1
	session.send_message("gdllm:cmd", [id, payload])
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if _pending.has(id):
			var reply: Dictionary = _pending[id]
			_pending.erase(id)
			return {"ok": true, "reply": reply, "why_kind": ""}
		if not session.is_active():
			return {"ok": false, "reply": {}, "why_kind": "ended"}
		await Engine.get_main_loop().process_frame
	return {"ok": false, "reply": {}, "why_kind": "timeout"}
