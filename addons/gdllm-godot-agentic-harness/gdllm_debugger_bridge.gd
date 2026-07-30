@tool
class_name GDLLMDebuggerBridge extends EditorDebuggerPlugin
## The plugin's foothold in the editor debugger: registering an instance via EditorPlugin.add_debugger_plugin is what grants access to EditorDebuggerSession objects — the only scriptable "is a debug session active" signal (see GDLLMPerf.toggle_function_profiler's gate) and the send_message route that carries the game-driving tools' commands to the agent autoload inside the running game (see GDLLMGame). It captures ONLY the plugin's own "gdllm" prefix; core messages ("performance:*", "servers:*") never reach plugin captures — the built-in handlers consume them first — so the monitor stream is read off ScriptEditorDebugger's debug_data signal instead (see GDLLMPerf.ensure_connected).


func _setup_session(session_id: int) -> void:
	GDLLMGame.track_session(get_session(session_id), session_id)


func _has_capture(capture: String) -> bool:
	return capture == "gdllm"


func _capture(message: String, data: Array, session_id: int) -> bool:
	return GDLLMGame.on_capture(message, data, session_id)
