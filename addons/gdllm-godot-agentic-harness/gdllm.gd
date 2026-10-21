@tool
extends EditorPlugin
## Creates an embedded AI chat within your project to assist with general questions.

## The game-driving tools' in-game half: the autoload name the agent registers under and the script it runs (see _sync_game_agent).
const GAME_AGENT_AUTOLOAD := "GDLLMGameAgent"
const GAME_AGENT_SCRIPT := "res://addons/gdllm-godot-agentic-harness/gdllm_game_agent.gd"
## Editor-settings path of the shortcut that shows or hides the chat dock.
## Can be remapped under Editor Settings → Shortcuts.
const TOGGLE_SHORTCUT := GDLLMSettings.TOGGLE_DOCK_SHORTCUT
## The default key for the dock toggle (combined with platform modifier + shift)
const DEFAULT_TOGGLE_KEY := KEY_G

var gdllm_chat: GDLLMChatDock ## Dockable chat panel between the agent and the editor.
var settings_help: GDLLMSettingsHelp ## Renders setting descriptions in the Editor Settings dialog, which has no native channel for plugin setting docs.
var debugger_bridge: GDLLMDebuggerBridge ## Foothold in the editor debugger, granting the session access the profiler toggle needs (see GDLLMPerf) and carrying the game-driving tools' messages (see GDLLMGame).
## True while the toggle shortcut has the chat panel removed from the docks; the node stays in the tree under the plugin so its sessions and in-flight work keep running.
var _dock_hidden := false
## The slot the panel occupied when it was hidden, so showing it again returns it to the same place.
var _hidden_dock_slot := DOCK_SLOT_LEFT_UL


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

	# The scrapped CTRL+G completion feature registered a GDLLMUtils autoload; drop it from a project that still carries it.
	if ProjectSettings.has_setting("autoload/GDLLMUtils"):
		remove_autoload_singleton("GDLLMUtils")

	# Keep the game agent's autoload matched to its setting — now (covers installs enabled before the agent existed, where _enable_plugin never re-runs) and on every settings change (the checkbox is the remove lever, and it must act on the spot).
	_sync_game_agent()
	EditorInterface.get_editor_settings().settings_changed.connect(_sync_game_agent)

	# The chat log's file links resolve through a cached index of the project; a file added or deleted since it was built would otherwise link wrongly or not at all (see GDLLMLinks).
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(GDLLMLinks.invalidate)

	# Register the toggle before the dock's UI is built, so its header tooltip can read the live binding.
	_register_toggle_shortcut()

	# add the dockable chat panel
	gdllm_chat = GDLLMChatDock.new()
	add_control_to_dock(DOCK_SLOT_LEFT_UL, gdllm_chat)

	# Pickers fill instantly from the cached list GDLLMSettings.register just loaded; a sweep now runs only on demand (opening a picker, or the Connections dialog) so boot never blocks on model HTTP. Only a first-ever run with no cache sweeps once here, so the initial picker isn't just the default model. Deferred so the dock has finished _ready first.
	if GDLLMSettings.get_available_models().is_empty():
		gdllm_chat.refresh_all_models.call_deferred()

	print("GDLLM loaded!")


## Register the dock toggle under Editor Settings → Shortcuts using the editor's normal default/override model.
## Makes the entry appear, lets the user remap it, and lets a cleared binding persist as disabled with Revert restoring the default.
func _register_toggle_shortcut() -> void:
	var settings := EditorInterface.get_editor_settings()
	var shortcut := Shortcut.new()
	var key := InputEventKey.new()
	key.keycode = DEFAULT_TOGGLE_KEY
	if OS.get_name() == "macOS":
		key.meta_pressed = true
	else:
		key.ctrl_pressed = true
	key.shift_pressed = true
	shortcut.events.append(key)
	var default_events := shortcut.events.duplicate(true)
	var existing := settings.get_shortcut(TOGGLE_SHORTCUT)
	if existing == null:
		shortcut.set_meta("original", default_events)
		settings.add_shortcut(TOGGLE_SHORTCUT, shortcut)
	elif not existing.has_meta("original"):
		# A shortcut loaded from the settings file carries no `original` metadata,
		# which the Shortcuts UI needs to list it and to revert it.
		# Record the default here, but leave the user's events untouched: a remap stays, and a
		# deliberately cleared (disabled) binding stays empty.
		existing.set_meta("original", default_events)


## Show or hide the chat dock from anywhere in the editor.
## Handled here rather than on the dock so it works in whatever editor area holds focus.
## Hiding removes the dock's tab entirely so the editor space collapses;
## the node is re-parented under the plugin (hidden) so its sessions and in-flight requests keep running,
## then re-added on the next press.
func _shortcut_input(event: InputEvent) -> void:
	if not is_instance_valid(gdllm_chat):
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.is_echo():
		return
	if not EditorInterface.get_editor_settings().is_shortcut(TOGGLE_SHORTCUT, event):
		return
	_toggle_dock()
	get_viewport().set_input_as_handled()


func _toggle_dock() -> void:
	_dock_hidden = not _dock_hidden
	if _dock_hidden:
		_hidden_dock_slot = _dock_slot()
		remove_control_from_docks(gdllm_chat)
		add_child(gdllm_chat)
		gdllm_chat.visible = false
	else:
		gdllm_chat.visible = true
		remove_child(gdllm_chat)
		add_control_to_dock(_hidden_dock_slot, gdllm_chat)
		_select_dock_tab.call_deferred()


## Used when docked in a spot with tabs.
## Make the chat panel the current tab of its dock slot.
## `add_control_to_dock` appends the tab without selecting it, so re-showing would otherwise
## land behind whatever was active there (the Inspector, typically).
## Deferred so it runs after the editor's own add/layout pass.
func _select_dock_tab() -> void:
	var node: Node = gdllm_chat
	while node != null:
		var parent := node.get_parent()
		if parent is TabContainer:
			var tabs := parent as TabContainer
			var index := tabs.get_tab_idx_from_control(node)
			if index >= 0:
				tabs.current_tab = index
			return
		node = parent


## The slot the chat panel currently occupies, read from the editor's slot container name
## (the plugin API has no slot getter).
## Falls back to the left-upper slot when the panel is floating or its slot container is unrecognized.
func _dock_slot() -> int:
	var node := gdllm_chat.get_parent()
	while node != null:
		match String(node.name):
			"DockSlotLeftUL": return DOCK_SLOT_LEFT_UL
			"DockSlotLeftBL": return DOCK_SLOT_LEFT_BL
			"DockSlotLeftUR": return DOCK_SLOT_LEFT_UR
			"DockSlotLeftBR": return DOCK_SLOT_LEFT_BR
			"DockSlotRightUL": return DOCK_SLOT_RIGHT_UL
			"DockSlotRightBL": return DOCK_SLOT_RIGHT_BL
			"DockSlotRightUR": return DOCK_SLOT_RIGHT_UR
			"DockSlotRightBR": return DOCK_SLOT_RIGHT_BR
			"DockSlotBottomL", "DockSlotBottomR": return DOCK_SLOT_BOTTOM
		node = node.get_parent()
	return DOCK_SLOT_LEFT_UL


## Fresh enable: register the agent autoload the game-driving tools talk to (per its setting). _enter_tree's sync covers installs that enabled the plugin before the agent existed.
func _enable_plugin() -> void:
	_sync_game_agent()


## Disabling the plugin takes its project footprint with it; re-enabling restores it.
func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/" + GAME_AGENT_AUTOLOAD):
		remove_autoload_singleton(GAME_AGENT_AUTOLOAD)
		_save_project_settings()


## Keep the GDLLMGameAgent autoload registered exactly while its setting says so, each change disclosed in the Output console — a project-file write should never be silent. Idempotent and cheap, so it can ride every settings_changed.
func _sync_game_agent() -> void:
	var want := GDLLMSettings.is_game_agent_enabled()
	var registered := ProjectSettings.has_setting("autoload/" + GAME_AGENT_AUTOLOAD)
	if want and not registered:
		add_autoload_singleton(GAME_AGENT_AUTOLOAD, GAME_AGENT_SCRIPT)
		_save_project_settings()
		print("GDLLM: registered the %s autoload (Project Settings → Globals) — the in-game half of the game-driving tools; the %s setting removes it." % [GAME_AGENT_AUTOLOAD, GDLLMSettings.GAME_AGENT])
	elif not want and registered:
		remove_autoload_singleton(GAME_AGENT_AUTOLOAD)
		_save_project_settings()
		print("GDLLM: removed the %s autoload (%s is off); games already running keep the agent they launched with until restarted." % [GAME_AGENT_AUTOLOAD, GDLLMSettings.GAME_AGENT])


## add/remove_autoload_singleton only update the in-memory ProjectSettings, but a launched game reads project.godot from DISK — an unsaved registration would never reach the game, so the change is saved on the spot (the same persistence set_project_setting uses).
func _save_project_settings() -> void:
	var save_err := ProjectSettings.save()
	if save_err != OK:
		push_warning("GDLLM: project.godot could not be saved (%s) — the %s autoload change will not reach launched games until the project is saved." % [error_string(save_err), GAME_AGENT_AUTOLOAD])


func _exit_tree() -> void:
	# The agent autoload itself stays registered across unloads by design — _disable_plugin removes it when the user actually disables the plugin.
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
		if not _dock_hidden:
			remove_control_from_docks(gdllm_chat)
		gdllm_chat.queue_free()
		gdllm_chat = null
