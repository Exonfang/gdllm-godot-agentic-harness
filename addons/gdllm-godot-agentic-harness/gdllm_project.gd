@tool
class_name GDLLMProject extends RefCounted
## Project configuration for the describe_project / set_project_setting tools, read from and written through the live ProjectSettings singleton — engine truth, not a parse of project.godot.
## Reads are served narrow: an overview (main scene, autoloads, input actions, a changed-settings count) by default, one prefix's worth on a filter, a single value on an exact name — never the whole settings dump.
## Writes go through set_setting with per-domain validation (input actions from friendly event specs, autoloads as checked paths, plain settings coerced to their existing type) and save project.godot immediately, since project settings have no unsaved-in-editor state the way scenes do.

const MAX_FILTER_RESULTS := 60
const MAX_SUGGESTIONS := 12
const MAX_VALUE_CHARS := 160
## The editor's own default deadzone for a newly added input action.
const DEFAULT_DEADZONE := 0.5

## Friendly mouse-button names for input-event specs, matched lower-case; numeric indices are accepted too.
const MOUSE_BUTTON_NAMES := {
	"left": MOUSE_BUTTON_LEFT,
	"right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE,
	"wheel_up": MOUSE_BUTTON_WHEEL_UP,
	"wheel_down": MOUSE_BUTTON_WHEEL_DOWN,
	"wheel_left": MOUSE_BUTTON_WHEEL_LEFT,
	"wheel_right": MOUSE_BUTTON_WHEEL_RIGHT,
	"x1": MOUSE_BUTTON_XBUTTON1,
	"x2": MOUSE_BUTTON_XBUTTON2,
}

## Friendly joypad-button names (the common face/shoulder set), matched lower-case; numeric indices cover the rest.
const JOY_BUTTON_NAMES := {
	"a": JOY_BUTTON_A,
	"b": JOY_BUTTON_B,
	"x": JOY_BUTTON_X,
	"y": JOY_BUTTON_Y,
	"left_shoulder": JOY_BUTTON_LEFT_SHOULDER,
	"right_shoulder": JOY_BUTTON_RIGHT_SHOULDER,
	"start": JOY_BUTTON_START,
	"back": JOY_BUTTON_BACK,
}

## Friendly joypad-axis names, matched lower-case; numeric indices are accepted too.
const JOY_AXIS_NAMES := {
	"left_x": JOY_AXIS_LEFT_X,
	"left_y": JOY_AXIS_LEFT_Y,
	"right_x": JOY_AXIS_RIGHT_X,
	"right_y": JOY_AXIS_RIGHT_Y,
	"left_trigger": JOY_AXIS_TRIGGER_LEFT,
	"right_trigger": JOY_AXIS_TRIGGER_RIGHT,
}

## The event-spec grammar, quoted in every parse error so a failed spec comes back with the full expected shape.
const EVENT_SPEC_HELP := "Each event is a string: a key like \"Space\", \"W\", or \"Ctrl+Shift+S\" (optionally prefixed \"Key:\"), \"MouseButton:Left\" (or Right/Middle/WheelUp/WheelDown/X1/X2 or a button index), \"JoyButton:0\" (or A/B/X/Y/Start/Back/Left_Shoulder/Right_Shoulder), or \"JoyAxis:1-\" / \"JoyAxis:left_y-\" (axis then + or - for the direction)."


## The read side behind describe_project: one exact setting, a filtered listing, or the no-argument overview.
static func describe(setting: String, filter: String) -> String:
	if setting != "":
		return _one_setting(setting)
	if filter != "":
		return _filtered(filter)
	return _overview()


## The write side behind set_project_setting: validate and coerce `value` for the setting's domain, apply it, and save project.godot. `has_value` distinguishes an explicit JSON null from a missing argument; `revert` clears the setting back to its default (removing a custom one) and `create` permits a brand-new custom name.
static func apply(setting: String, value: Variant, has_value: bool, revert: bool, create: bool) -> String:
	var name := _normalize_name(setting)
	if name == "":
		return "Error: no setting name was provided. Pass the full slash-separated name, e.g. \"input/jump\" or \"application/run/main_scene\"."
	if revert:
		return _revert_setting(name)
	if not has_value or value == null:
		return "Error: no value was provided for \"%s\". Pass the new value in \"value\", or \"revert\": true to restore the default (which removes a custom setting, autoload, or input action)." % name
	var known := ProjectSettings.has_setting(name)
	if not known and not create and not name.begins_with("autoload/") and not name.begins_with("input/"):
		return _unknown_setting_message(name)
	var coerced := _coerce_value(name, value, known)
	if coerced.has("error"):
		return String(coerced["error"])
	var old_text := _value_text(ProjectSettings.get_setting(name)) if known else "(not set)"
	ProjectSettings.set_setting(name, coerced["value"])
	var save_err := ProjectSettings.save()
	if save_err != OK:
		return "Error: the setting was changed in memory but saving project.godot failed (%s). Nothing may have persisted — tell the user." % error_string(save_err)
	return _apply_confirmation(name, coerced["value"], old_text, known)


## Bare names are tolerated for the two domains where they're natural: "jump" resolves to input/jump and a known autoload name to its autoload/ entry, but only when that resolution actually exists.
static func _normalize_name(setting: String) -> String:
	var name := setting.strip_edges().trim_prefix("/")
	if name == "" or name.contains("/"):
		return name
	for prefix in ["input/", "autoload/"]:
		if ProjectSettings.has_setting(prefix + name):
			return prefix + name
	return name


## Revert one setting: a built-in is set back to its default value (which save() then drops from project.godot, since it equals the initial value), while a custom entry (setting, autoload, or input action) has no default and is erased outright via set_setting(null) — erasing a built-in that way would unregister it for the whole session.
static func _revert_setting(name: String) -> String:
	if not ProjectSettings.has_setting(name):
		return "Error: \"%s\" is not set, so there is nothing to revert. %s" % [name, _suggestion_note(name)]
	var default_value: Variant = ProjectSettings.property_get_revert(name) if ProjectSettings.property_can_revert(name) else null
	ProjectSettings.set_setting(name, default_value)
	var save_err := ProjectSettings.save()
	if save_err != OK:
		return "Error: the setting was cleared in memory but saving project.godot failed (%s). Nothing may have persisted — tell the user." % error_string(save_err)
	if default_value == null:
		return "Removed \"%s\" and saved project.godot. It was a custom entry with no built-in default, so it is gone entirely." % name
	return "Reverted \"%s\" to its default (%s) and saved project.godot." % [name, _value_text(default_value)]


## Route a new value through its domain's validation: input actions from event specs, autoloads as project paths, and everything else coerced to the existing setting's type.
static func _coerce_value(name: String, value: Variant, known: bool) -> Dictionary:
	if name.begins_with("input/"):
		return _coerce_input_action(value)
	if name.begins_with("autoload/"):
		return _coerce_autoload(value)
	return _coerce_plain(name, value, known)


## Build an input action's stored form ({deadzone, events}) from the friendly shapes the tool accepts: one event-spec string, an array of them, or an object carrying "events" and an optional "deadzone".
static func _coerce_input_action(value: Variant) -> Dictionary:
	var deadzone := DEFAULT_DEADZONE
	var specs: Array = []
	if value is Dictionary:
		var dict: Dictionary = value
		deadzone = clampf(float(dict.get("deadzone", DEFAULT_DEADZONE)), 0.0, 1.0)
		var raw_events: Variant = dict.get("events", [])
		specs = raw_events if raw_events is Array else [raw_events]
	elif value is Array:
		specs = value
	elif value is String:
		specs = [value]
	else:
		return {"error": "Error: an input action's value must be an event string, an array of them, or {\"deadzone\": ..., \"events\": [...]}. " + EVENT_SPEC_HELP}
	var events: Array = []
	for spec in specs:
		if not (spec is String):
			return {"error": "Error: input events must be strings, got %s. %s" % [type_string(typeof(spec)), EVENT_SPEC_HELP]}
		var parsed := _parse_event_spec(String(spec))
		if parsed.has("error"):
			return parsed
		events.append(parsed["event"])
	if events.is_empty():
		return {"error": "Error: an input action needs at least one event. " + EVENT_SPEC_HELP}
	return {"value": {"deadzone": deadzone, "events": events}}


## One event spec to an InputEvent, dispatching on an optional "Kind:" prefix; an unprefixed spec is a key.
static func _parse_event_spec(spec: String) -> Dictionary:
	var text := spec.strip_edges()
	var kind := "key"
	var colon := text.find(":")
	if colon > 0:
		var head := text.substr(0, colon).to_lower().replace("_", "").replace(" ", "")
		var known := {"key": "key", "mouse": "mouse", "mousebutton": "mouse", "joy": "joybutton", "joybutton": "joybutton", "joypadbutton": "joybutton", "joyaxis": "joyaxis", "joypadaxis": "joyaxis", "axis": "joyaxis", "joymotion": "joyaxis"}
		if known.has(head):
			kind = known[head]
			text = text.substr(colon + 1).strip_edges()
	match kind:
		"mouse":
			return _parse_mouse_event(text)
		"joybutton":
			return _parse_joy_button_event(text)
		"joyaxis":
			return _parse_joy_axis_event(text)
	return _parse_key_event(text)


## "Ctrl+Shift+S"-style key spec: leading tokens are modifiers, the last is the key name resolved through the engine's keycode table.
static func _parse_key_event(text: String) -> Dictionary:
	var parts := text.split("+", false)
	if parts.is_empty():
		return {"error": "Error: empty key spec. " + EVENT_SPEC_HELP}
	var event := InputEventKey.new()
	for i in parts.size() - 1:
		match String(parts[i]).strip_edges().to_lower():
			"ctrl", "control":
				event.ctrl_pressed = true
			"shift":
				event.shift_pressed = true
			"alt":
				event.alt_pressed = true
			"meta", "cmd", "win", "super":
				event.meta_pressed = true
			_:
				return {"error": "Error: unknown modifier \"%s\" in key spec \"%s\" (use Ctrl, Shift, Alt, or Meta). %s" % [parts[i], text, EVENT_SPEC_HELP]}
	var code := _find_keycode(String(parts[-1]).strip_edges())
	if code == KEY_NONE:
		return {"error": "Error: \"%s\" is not a key name the engine knows. Use the names the Input Map dialog shows, e.g. \"Space\", \"W\", \"Escape\", \"F5\", \"Up\". %s" % [parts[-1], EVENT_SPEC_HELP]}
	event.keycode = code
	return {"event": event}


## Resolve a key name through OS.find_keycode_from_string, retrying common respellings ("space", "w", "page_up") against the engine's exact names ("Space", "W", "PageUp").
static func _find_keycode(name: String) -> Key:
	for candidate in [name, name.capitalize(), name.to_upper(), name.capitalize().replace(" ", ""), name.replace("_", "").replace(" ", "")]:
		var code := OS.find_keycode_from_string(candidate)
		if code != KEY_NONE:
			return code
	return KEY_NONE


static func _parse_mouse_event(text: String) -> Dictionary:
	var token := text.strip_edges().to_lower().replace(" ", "_")
	var index := -1
	if MOUSE_BUTTON_NAMES.has(token):
		index = MOUSE_BUTTON_NAMES[token]
	elif token.is_valid_int():
		index = int(token)
	if index < 1:
		return {"error": "Error: unknown mouse button \"%s\" (use Left, Right, Middle, WheelUp, WheelDown, X1, X2, or a button index). %s" % [text, EVENT_SPEC_HELP]}
	var event := InputEventMouseButton.new()
	event.button_index = index as MouseButton
	return {"event": event}


static func _parse_joy_button_event(text: String) -> Dictionary:
	var token := text.strip_edges().to_lower().replace(" ", "_")
	var index := -1
	if JOY_BUTTON_NAMES.has(token):
		index = JOY_BUTTON_NAMES[token]
	elif token.is_valid_int():
		index = int(token)
	if index < 0:
		return {"error": "Error: unknown joypad button \"%s\" (use a button index like 0, or A/B/X/Y/Start/Back/Left_Shoulder/Right_Shoulder). %s" % [text, EVENT_SPEC_HELP]}
	var event := InputEventJoypadButton.new()
	event.button_index = index as JoyButton
	return {"event": event}


## Joypad axis spec "1-", "left_y+", or "0:+": the axis by index or name, then the direction sign (missing means +).
static func _parse_joy_axis_event(text: String) -> Dictionary:
	var token := text.strip_edges().to_lower().replace(" ", "_").trim_suffix(":")
	var sign_value := 1.0
	if token.ends_with("+") or token.ends_with("-"):
		sign_value = 1.0 if token.ends_with("+") else -1.0
		token = token.trim_suffix("+").trim_suffix("-").trim_suffix(":")
	var axis := -1
	if JOY_AXIS_NAMES.has(token):
		axis = JOY_AXIS_NAMES[token]
	elif token.is_valid_int():
		axis = int(token)
	if axis < 0:
		return {"error": "Error: unknown joypad axis \"%s\" (use an axis index plus direction like \"1-\", or a name like \"left_y-\"). %s" % [text, EVENT_SPEC_HELP]}
	var event := InputEventJoypadMotion.new()
	event.axis = axis as JoyAxis
	event.axis_value = sign_value
	return {"event": event}


## An autoload's stored form: its "*"-prefixed (enabled) project path, validated to exist so a typo can't register a dead singleton.
static func _coerce_autoload(value: Variant) -> Dictionary:
	if not (value is String) or String(value).strip_edges() == "":
		return {"error": "Error: an autoload's value is the res:// path of its script or scene, e.g. \"res://globals/game_state.gd\"."}
	var text := String(value).strip_edges()
	var enabled := not text.begins_with("-")
	var path := text.trim_prefix("-").trim_prefix("*")
	if not path.begins_with("res://"):
		path = "res://" + path.trim_prefix("/")
	if not FileAccess.file_exists(path):
		return {"error": "Error: no file exists at %s, so it can't be an autoload. Pass the res:// path of an existing script or scene." % path}
	if not path.get_extension().to_lower() in ["gd", "tscn", "scn", "res", "tres"]:
		return {"error": "Error: %s is not a script or scene, so it can't be an autoload." % path}
	return {"value": ("*" if enabled else "") + path}


## Plain settings coerce to the existing value's type so project.godot never ends up with a mistyped entry; a brand-new custom setting (create=true) is stored as given.
static func _coerce_plain(name: String, value: Variant, known: bool) -> Dictionary:
	if not known:
		return {"value": value}
	var existing: Variant = ProjectSettings.get_setting(name)
	var want := typeof(existing)
	if typeof(value) == want:
		return {"value": value}
	# JSON numbers arrive as floats, and a Godot literal in a string ("Vector2(64, 32)") covers the non-JSON types.
	if value is float and want == TYPE_INT:
		return {"value": int(value)}
	if value is int and want == TYPE_FLOAT:
		return {"value": float(value)}
	if value is String and not (existing is String):
		var parsed: Variant = str_to_var(String(value))
		if typeof(parsed) == want:
			return {"value": parsed}
	var converted: Variant = type_convert(value, want)
	if typeof(converted) == want and (value is Array or value is Dictionary or want in [TYPE_STRING, TYPE_STRING_NAME, TYPE_BOOL]):
		return {"value": converted}
	return {"error": "Error: \"%s\" holds a %s (currently %s), but the given value is a %s. Pass a matching value — a Godot literal in a string (e.g. \"Vector2(64, 32)\") works for non-JSON types." % [name, type_string(want), _value_text(existing), type_string(typeof(value))]}


## The post-save confirmation, honest about scope: what changed, what it was, and that a game-facing setting takes effect on the next run rather than in the live editor.
static func _apply_confirmation(name: String, new_value: Variant, old_text: String, known: bool) -> String:
	var lines: Array = []
	if name.begins_with("input/"):
		lines.append("%s input action \"%s\": %s." % ["Updated" if known else "Added", name.trim_prefix("input/"), _value_text(new_value)])
		lines.append("Saved to project.godot; the action is live the next time the project runs, so scripts can use it now (e.g. Input.is_action_pressed(\"%s\"))." % name.trim_prefix("input/"))
	elif name.begins_with("autoload/"):
		var target := String(new_value)
		lines.append("%s autoload \"%s\" -> %s%s." % ["Updated" if known else "Added", name.trim_prefix("autoload/"), target.trim_prefix("*"), "" if target.begins_with("*") else " (disabled)"])
		lines.append("Saved to project.godot; the singleton is available as /root/%s the next time the project runs." % name.trim_prefix("autoload/"))
	else:
		lines.append("%s \"%s\" to %s (was %s) and saved project.godot." % ["Set" if known else "Created new custom setting", name, _value_text(new_value), old_text])
	return "\n".join(lines)


## The no-argument overview: identity, main scene, autoloads, input actions, and a changed-count pointer — the narrow map of the project's configuration, never the full dump.
static func _overview() -> String:
	var lines: Array = ["Project configuration — live ProjectSettings state (what project.godot plus engine defaults resolve to):", ""]
	lines.append("Name: %s" % String(ProjectSettings.get_setting("application/config/name", "(unnamed)")))
	var features: Variant = ProjectSettings.get_setting("application/config/features", PackedStringArray())
	if features is PackedStringArray and not (features as PackedStringArray).is_empty():
		lines.append("Features: %s" % ", ".join(features))
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	lines.append("Main scene: %s" % (main_scene if main_scene != "" else "(not set — the project can't run until application/run/main_scene is set)"))
	lines.append("")
	lines.append_array(_autoload_section())
	lines.append("")
	lines.append_array(_input_section())
	lines.append("")
	lines.append("%d settings differ from their engine defaults. Browse any area with `filter` (e.g. \"display/window\", \"physics/\"), or pass `setting` for one exact value." % _changed_count())
	return "\n".join(lines)


static func _autoload_section() -> Array:
	var names := _setting_names("autoload/")
	if names.is_empty():
		return ["Autoloads: none"]
	var lines: Array = ["Autoloads (%d):" % names.size()]
	for name in names:
		var target := String(ProjectSettings.get_setting(name))
		lines.append("  %s -> %s%s" % [name.trim_prefix("autoload/"), target.trim_prefix("*"), "" if target.begins_with("*") else " (disabled)"])
	return lines


## Input actions split by origin: project-defined actions (custom, or built-ins the project overrode) are shown with their events, while untouched ui_* built-ins collapse to one count line.
static func _input_section() -> Array:
	var project_defined: Array[String] = []
	var builtin_count := 0
	for name in _setting_names("input/"):
		if _is_changed(name):
			project_defined.append(name)
		else:
			builtin_count += 1
	var lines: Array = []
	if project_defined.is_empty():
		lines.append("Input actions: none defined by the project")
	else:
		lines.append("Input actions defined by the project (%d):" % project_defined.size())
		for name in project_defined:
			lines.append("  %s: %s" % [name.trim_prefix("input/"), _value_text(ProjectSettings.get_setting(name))])
	if builtin_count > 0:
		lines.append("  (plus %d built-in ui_* actions at their defaults — filter \"input/ui\" to see them)" % builtin_count)
	return lines


## The filtered listing: every setting whose name contains the filter, values rendered compactly and changed-from-default entries marked, capped so a broad filter maps rather than floods.
static func _filtered(filter: String) -> String:
	var needle := filter.strip_edges().to_lower()
	var matches: Array[String] = []
	for name in _setting_names(""):
		if name.to_lower().contains(needle):
			matches.append(name)
	if matches.is_empty():
		return "No project settings match \"%s\". Filters match anywhere in the slash-separated name (e.g. \"window\" matches display/window/size/viewport_width); try a shorter fragment." % filter
	var shown: Array[String] = matches if matches.size() <= MAX_FILTER_RESULTS else matches.slice(0, MAX_FILTER_RESULTS)
	var lines: Array = ["%d project settings match \"%s\" (* = differs from the engine default):" % [matches.size(), filter]]
	for name in shown:
		lines.append("%s %s = %s" % ["*" if _is_changed(name) else " ", name, _value_text(ProjectSettings.get_setting(name))])
	if shown.size() < matches.size():
		lines.append("(%d of %d shown — narrow the filter to see the rest)" % [shown.size(), matches.size()])
	return "\n".join(lines)


## One setting's full detail: value, default, and the input/autoload interpretation where it applies.
static func _one_setting(setting: String) -> String:
	var name := _normalize_name(setting)
	if not ProjectSettings.has_setting(name):
		return _unknown_setting_message(name)
	var value: Variant = ProjectSettings.get_setting(name)
	# The zoom is the lever the list's clip note names, so it must never clip.
	var lines: Array = ["%s = %s" % [name, _value_text(value, true)]]
	if ProjectSettings.property_can_revert(name):
		var default_value: Variant = ProjectSettings.property_get_revert(name)
		if default_value == null:
			lines.append("Custom entry — not a built-in setting, so it has no engine default.")
		elif _is_changed(name):
			lines.append("Engine default: %s" % _value_text(default_value))
		else:
			lines.append("This is the engine default (the project doesn't override it).")
	if name.begins_with("autoload/"):
		var target := String(value)
		lines.append("Autoload \"%s\": %s the project's scene tree as /root/%s when the game runs." % [name.trim_prefix("autoload/"), "joins" if target.begins_with("*") else "is registered but DISABLED, so it does not join", name.trim_prefix("autoload/")])
	return "\n".join(lines)


## Every settings name under `prefix` (all when ""), sorted; only slash-bearing names count, which excludes the singleton's own script properties.
static func _setting_names(prefix: String) -> Array[String]:
	var names: Array[String] = []
	for p in ProjectSettings.get_property_list():
		var name := String(p["name"])
		if name.contains("/") and (prefix == "" or name.begins_with(prefix)):
			names.append(name)
	names.sort()
	return names


## Whether a setting differs from its engine default; a custom entry (null default) always counts as changed.
static func _is_changed(name: String) -> bool:
	if not ProjectSettings.property_can_revert(name):
		return true
	var default_value: Variant = ProjectSettings.property_get_revert(name)
	if default_value == null:
		return true
	return not _values_equal(ProjectSettings.get_setting(name), default_value)


## Loose equality across int/float so an int default stored back as float doesn't read as changed.
static func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) == typeof(b):
		return a == b
	if (a is int or a is float) and (b is int or b is float):
		return float(a) == float(b)
	return false


static func _changed_count() -> int:
	var count := 0
	for name in _setting_names(""):
		if _is_changed(name):
			count += 1
	return count


## Compact one-line rendering for any setting value; an input action's {deadzone, events} dictionary renders as its events' human-readable names instead of serialized objects. `whole` skips the length clip — the single-setting zoom's contract, since a zoom that returns the same stump as the list was a dead end (audit-caught).
static func _value_text(value: Variant, whole := false) -> String:
	var rendered := ""
	if value is Dictionary and (value as Dictionary).get("events") is Array:
		var names: Array = []
		for ev in value["events"]:
			if ev is InputEvent:
				names.append((ev as InputEvent).as_text())
		rendered = "%s (deadzone %s)" % [", ".join(PackedStringArray(names)) if not names.is_empty() else "no events", value.get("deadzone", DEFAULT_DEADZONE)]
	elif value is String:
		rendered = "\"%s\"" % value
	else:
		rendered = var_to_str(value).replace("\n", " ")
	if not whole and rendered.length() > MAX_VALUE_CHARS:
		rendered = rendered.substr(0, MAX_VALUE_CHARS) + "… (%d chars total — \"setting\" with this name prints it whole)" % rendered.length()
	return rendered


## Error text for a setting name that doesn't resolve, with near-miss suggestions so a typo can't silently create a new entry.
static func _unknown_setting_message(name: String) -> String:
	return "Error: no project setting named \"%s\" exists. %s To create a genuinely new custom setting under that name, call set_project_setting with \"create\": true; a new input action or autoload needs no flag, just the input/ or autoload/ prefix." % [name, _suggestion_note(name)]


static func _suggestion_note(name: String) -> String:
	var tail := name.get_slice("/", name.get_slice_count("/") - 1).to_lower()
	var suggestions: Array[String] = []
	for candidate in _setting_names(""):
		if candidate.to_lower().contains(tail) and candidate != name:
			suggestions.append(candidate)
			if suggestions.size() == MAX_SUGGESTIONS:
				break
	if suggestions.is_empty():
		return "Use describe_project with a filter to find the right name."
	return "Did you mean: %s?" % ", ".join(suggestions)
