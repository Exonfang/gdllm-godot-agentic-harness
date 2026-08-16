@tool
extends EditorPlugin
## Creates an embedded AI chat within your project to assist with general questions.

## The game-driving tools' in-game half: the autoload name the agent registers under and the script it runs (see _sync_game_agent).
const GAME_AGENT_AUTOLOAD := "GDLLMGameAgent"
const GAME_AGENT_SCRIPT := "res://addons/gdllm-godot-agentic-harness/gdllm_game_agent.gd"

var gdllm_chat: GDLLMChatDock ## Dockable chat panel between the agent and the editor.
var settings_help: GDLLMSettingsHelp ## Renders setting descriptions in the Editor Settings dialog, which has no native channel for plugin setting docs.
var debugger_bridge: GDLLMDebuggerBridge ## Foothold in the editor debugger, granting the session access the profiler toggle needs (see GDLLMPerf) and carrying the game-driving tools' messages (see GDLLMGame).


func _enter_tree() -> void:
	# register the plugin's editor settings before anything reads them
	GDLLMSettings.register()

	# describe them in the settings dialog (an inspector plugin, because the dialog offers no description API)
	settings_help = GDLLMSettingsHelp.new()
	add_inspector_plugin(settings_help)

	# Register the debugger foothold and start recording the monitor stream every running game already sends (see GDLLMPerf).
	debugger_bridge = GDLLMDebuggerBridge.new()
	add_debugger_plugin(debugger_bridge)
	GDLLMPerf.bridge = debugger_bridge
	GDLLMGame.bridge = debugger_bridge
	GDLLMPerf.ensure_connected()

	# Record break state from load, not from the first debugging tool call: a game can break before any tool asks, and the stack it reports arrives once (see GDLLMBreak).
	GDLLMBreak.ensure_connected()

	# The scrapped CTRL+G completion feature once registered GDLLMUtils, but old releases recorded no ownership metadata. Preserve any surviving value: deleting by name alone could remove another plugin's singleton.
	if ProjectSettings.has_setting("autoload/GDLLMUtils"):
		push_warning("GDLLM: preserved the legacy GDLLMUtils autoload because its exact ownership cannot be proven; remove it manually if it still points to retired GDLLM code.")

	# Keep the game agent's autoload matched to its setting — now (covers installs enabled before the agent existed, where _enable_plugin never re-runs) and on every settings change (the checkbox is the remove lever, and it must act on the spot).
	_sync_game_agent()
	EditorInterface.get_editor_settings().settings_changed.connect(_sync_game_agent)

	# The chat log's file links resolve through a cached index of the project; a file added or deleted since it was built would otherwise link wrongly or not at all (see GDLLMLinks).
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(GDLLMLinks.invalidate)

	# add the dockable chat panel
	gdllm_chat = GDLLMChatDock.new()
	add_control_to_dock(DOCK_SLOT_LEFT_UL, gdllm_chat)

	# Pickers fill instantly from the cached list GDLLMSettings.register just loaded; a sweep now runs only on demand (opening a picker, or the Connections dialog) so boot never blocks on model HTTP. Only a first-ever run with no cache sweeps once here, so the initial picker isn't just the default model. Deferred so the dock has finished _ready first.
	if GDLLMSettings.get_available_models().is_empty():
		gdllm_chat.refresh_all_models.call_deferred()

	print("GDLLM loaded!")


## Fresh enable: register the agent autoload the game-driving tools talk to (per its setting). _enter_tree's sync covers installs that enabled the plugin before the agent existed.
func _enable_plugin() -> void:
	_sync_game_agent()


## Disabling the plugin takes its project footprint with it; re-enabling restores it.
func _disable_plugin() -> void:
	_apply_game_agent_autoload(false)


## Keep the GDLLMGameAgent autoload registered exactly while its setting says so, each change disclosed in the Output console — a project-file write should never be silent. Idempotent and cheap, so it can ride every settings_changed.
func _sync_game_agent() -> void:
	_apply_game_agent_autoload(GDLLMSettings.is_game_agent_enabled())


## Apply the consented autoload state as one save+verify transaction. Foreign name collisions are preserved, and any failed or unverifiable save is rolled back rather than leaving editor memory and project.godot disagreeing.
func _apply_game_agent_autoload(enabled: bool) -> void:
	var result := GDLLMProjectMutation.sync_autoload(GAME_AGENT_AUTOLOAD, GAME_AGENT_SCRIPT, enabled)
	if not bool(result["ok"]):
		push_warning("GDLLM: " + String(result["message"]))
	elif bool(result["changed"]):
		print("GDLLM: %s The %s setting is the explicit project.godot consent and removal control." % [String(result["message"]), GDLLMSettings.GAME_AGENT])


func _exit_tree() -> void:
	# The agent autoload itself stays registered across an editor/plugin reload; _disable_plugin removes only the exact value GDLLM owns when the user actually disables the plugin.
	var settings := EditorInterface.get_editor_settings()
	if settings.settings_changed.is_connected(_sync_game_agent):
		settings.settings_changed.disconnect(_sync_game_agent)

	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(GDLLMLinks.invalidate):
		filesystem.filesystem_changed.disconnect(GDLLMLinks.invalidate)

	if settings_help:
		remove_inspector_plugin(settings_help)
		settings_help = null

	if debugger_bridge:
		remove_debugger_plugin(debugger_bridge)
		GDLLMPerf.bridge = null
		GDLLMGame.bridge = null
		debugger_bridge = null

	# remove the chat dock (its own children, including its client, are freed with it)
	if gdllm_chat:
		# Give the script editors their deselect-on-focus-loss behavior back before the dock goes away.
		gdllm_chat.restore_editor_selection_behavior()
		remove_control_from_docks(gdllm_chat)
		gdllm_chat.queue_free()
		gdllm_chat = null
