extends SceneTree
## Headless regression tests for the configurable chat-log palette (GDLLMColors): the shipped defaults must stay byte-identical to the colors the log carried before they became settings, every role must read back its default outside the editor, hex() must reproduce the BBCode strings the render sites used to hold, and every role must carry a settings-dialog description with a tail no other described setting shares.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/log_colors_test.gd
## Exits nonzero on any failure. One "GDLLMColors: no color role named" error line is expected — an unknown-role read is asserted on purpose.

## The literal each role replaced, copied from the pre-settings source rather than from GDLLMColors, so a default edited by accident fails here.
const SHIPPED_DEFAULTS := {
	"gdllm/colors/user_background": Color(0.3, 0.5, 0.95, 0.3),
	"gdllm/colors/user_caption": Color(0.55, 0.78, 1.0),
	"gdllm/colors/agent_background": Color(0.3, 0.75, 0.45, 0.22),
	"gdllm/colors/agent_caption": Color("7ee787"),
	"gdllm/colors/redirect_background": Color(0.95, 0.35, 0.35, 0.22),
	"gdllm/colors/error_caption": Color("f2777a"),
	"gdllm/colors/tool_caption": Color("d2a8ff"),
	"gdllm/colors/attachment_caption": Color("6cb6ff"),
	"gdllm/colors/subagent_background": Color(0.6, 0.45, 0.95, 0.14),
	"gdllm/colors/task_background": Color(0.75, 0.75, 0.75, 0.1),
	"gdllm/colors/compaction_background": Color(0.94, 0.64, 0.36, 0.12),
	"gdllm/colors/status_caption": Color(1, 1, 1, 0.6),
	"gdllm/colors/warning_caption": Color("f0a45d"),
	"gdllm/colors/code": Color("a3c8ff"),
	"gdllm/colors/system_caption": Color("999999"),
	"gdllm/colors/thinking_text": Color(1, 1, 1, 0.5),
	"gdllm/colors/footer_text": Color(1, 1, 1, 0.80),
	"gdllm/colors/search_highlight": Color("ffcc0044"),
}

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_defaults()
	_test_accessors()
	_test_descriptions()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_defaults() -> void:
	_check(GDLLMColors.DEFAULTS.size() == SHIPPED_DEFAULTS.size(), "role count matches the shipped palette (%d registered, %d expected)" % [GDLLMColors.DEFAULTS.size(), SHIPPED_DEFAULTS.size()])
	for key: String in SHIPPED_DEFAULTS:
		_check(GDLLMColors.DEFAULTS.has(key), "%s is registered" % key)
		if not GDLLMColors.DEFAULTS.has(key):
			continue
		var registered: Color = GDLLMColors.DEFAULTS[key]
		var shipped: Color = SHIPPED_DEFAULTS[key]
		_check(registered == shipped, "%s defaults to the color it replaced (%s, expected %s)" % [key, registered.to_html(true), shipped.to_html(true)])
	for key: String in GDLLMColors.DEFAULTS:
		_check(key.begins_with("gdllm/colors/"), "%s sits on the colors page" % key)


func _test_accessors() -> void:
	# Outside the editor there are no editor settings to read, so every role must fall back to its default.
	_check(not Engine.is_editor_hint(), "the suite runs outside the editor, where the fallback path is the one exercised")
	for key: String in GDLLMColors.DEFAULTS:
		var default_color: Color = GDLLMColors.DEFAULTS[key]
		_check(GDLLMColors.color(key) == default_color, "color(%s) falls back to its default" % key)
		_check(GDLLMColors.hex(key) == "#" + default_color.to_html(true), "hex(%s) is its default as #rrggbbaa" % key)
	# The exact strings the render sites used to hold as literals.
	_check(GDLLMColors.hex(GDLLMColors.ERROR_CAPTION) == "#f2777aff", "the error header's BBCode color still reads f2777a")
	_check(GDLLMColors.hex(GDLLMColors.SYSTEM_CAPTION) == "#999999ff", "the system header's BBCode color still reads 999999")
	_check(GDLLMColors.hex(GDLLMColors.CODE) == "#a3c8ffff", "code spans still read a3c8ff")
	_check(GDLLMColors.hex(GDLLMColors.SEARCH_HIGHLIGHT) == "#ffcc0044", "the search wash is byte-identical to the old HIGHLIGHT_BGCOLOR literal")
	_check(GDLLMColors.color("gdllm/colors/not_a_role") == Color.WHITE, "an unknown role reads white after naming itself in an error")
	var snapshot := GDLLMColors.snapshot()
	_check(snapshot.split("|").size() == GDLLMColors.DEFAULTS.size(), "the snapshot carries every role, so any single edit changes it")
	_check(snapshot == GDLLMColors.snapshot(), "the snapshot is stable while nothing changes")


func _test_descriptions() -> void:
	var described: Dictionary = GDLLMSettingsHelp.DESCRIPTIONS
	var tails: Dictionary = {}
	for key: String in described:
		var tail := String(key).get_file()
		_check(not tails.has(tail), "described setting tail \"%s\" is unique (the help plugin matches by suffix; %s collides with %s)" % [tail, key, tails.get(tail, "")])
		tails[tail] = key
	for key: String in GDLLMColors.DEFAULTS:
		_check(described.has(key), "%s is described in the settings dialog" % key)
		_check(String(described.get(key, "")).length() > 40, "%s's description says something useful" % key)
