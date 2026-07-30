extends SceneTree
## Headless regression tests for GDLLMMarkdown — the seam that makes the MarkdownLabel addon optional: availability probing, the label factory the session renders replies through, the walker-side type check, and the search-highlight statics both render paths share.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/markdown_render_test.gd
## Exits nonzero on any failure. This repo vendors the addon, so the available() == true half is what runs here; the fallback branch in GDLLMChatSession._build_message_content needs the addon absent and is covered by wild validation in a project without it.

# Preloaded rather than referenced by class_name so the test survives a checkout whose global class cache hasn't been built yet.
const GDLLMMarkdown = preload("res://addons/gdllm-godot-agentic-harness/gdllm_markdown.gd")
const GDLLMSettings = preload("res://addons/gdllm-godot-agentic-harness/gdllm_settings.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_availability()
	_test_factory_and_type_check()
	_test_prompt_placeholder()
	_test_highlight_wraps_matches()
	_test_highlight_skips_markup()
	_test_highlight_merges_overlaps()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("  FAIL: ", label)


## This repo vendors the addon, so the probe must find it — and headless runs have no EditorSettings, so enabled() must equal availability rather than touching the setting.
func _test_availability() -> void:
	_check(FileAccess.file_exists(GDLLMMarkdown.LIBRARY_SCRIPT_PATH), "the vendored library sits where the probe looks")
	_check(GDLLMMarkdown.available(), "the probe finds the vendored library")
	_check(GDLLMMarkdown.enabled(), "enabled() is availability alone outside the editor")


func _test_factory_and_type_check() -> void:
	var label: Variant = GDLLMMarkdown.make_label()
	_check(label != null, "make_label builds a label while Markdown rendering is on")
	_check(label is RichTextLabel, "the label is a RichTextLabel underneath, so every generic label path still applies")
	_check("markdown_text" in label, "the label carries MarkdownLabel's markdown_text")
	_check(label.has_signal("unhandled_link_clicked"), "the label carries the link extension point the session hooks")
	_check(GDLLMMarkdown.is_chat_markdown(label), "is_chat_markdown claims the factory's own label")
	var plain := RichTextLabel.new()
	_check(not GDLLMMarkdown.is_chat_markdown(plain), "is_chat_markdown declines a plain RichTextLabel — the fallback labels must take the generic highlight path")
	plain.free()
	label.free()


## Both branches are pure, so the render-off half is coverable here even though this repo vendors the addon.
func _test_prompt_placeholder() -> void:
	var d: String = GDLLMSettings.DEFAULT_CHAT_SYSTEM_PROMPT
	_check(d.contains(GDLLMMarkdown.PROMPT_PLACEHOLDER), "the default chat prompt carries the placeholder, not a hard-coded Markdown line")
	_check(not d.contains(GDLLMMarkdown.PROMPT_SENTENCE), "the Markdown instruction lives only behind the placeholder")
	var on := GDLLMMarkdown.apply_prompt_placeholder(d, true)
	_check(on.contains(GDLLMMarkdown.PROMPT_SENTENCE), "rendering on expands the placeholder to the Markdown instruction")
	_check(not on.contains(GDLLMMarkdown.PROMPT_PLACEHOLDER), "no placeholder text leaks into a sent prompt")
	var off := GDLLMMarkdown.apply_prompt_placeholder(d, false)
	_check(off.contains(GDLLMMarkdown.PROMPT_SENTENCE_PLAIN), "rendering off swaps in the write-plainly instruction — silence alone doesn't stop models writing Markdown")
	_check(not off.contains(GDLLMMarkdown.PROMPT_SENTENCE), "rendering off never claims replies render as Markdown")
	_check(not off.contains(GDLLMMarkdown.PROMPT_PLACEHOLDER), "no placeholder text leaks in the off state either")


func _test_highlight_wraps_matches() -> void:
	var out := GDLLMMarkdown.highlight_bbcode("the Sprite2D node", PackedStringArray(["sprite2d"]))
	_check(out == "the [bgcolor=%s]Sprite2D[/bgcolor] node" % GDLLMColors.hex(GDLLMColors.SEARCH_HIGHLIGHT), "a match is wrapped case-insensitively, the rest untouched")
	_check(GDLLMMarkdown.highlight_bbcode("no match here", PackedStringArray(["absent"])) == "no match here", "text without a match is returned unchanged")
	_check(GDLLMMarkdown.highlight_bbcode("anything", PackedStringArray()) == "anything", "no terms highlights nothing")


func _test_highlight_skips_markup() -> void:
	var bb := "[color=#ff0000]red[/color] color"
	var out := GDLLMMarkdown.highlight_bbcode(bb, PackedStringArray(["color"]))
	_check(out.contains("[color=#ff0000]") and out.contains("[/color]"), "a term never matches into a tag")
	_check(out.contains("[bgcolor=%s]color[/bgcolor]" % GDLLMColors.hex(GDLLMColors.SEARCH_HIGHLIGHT)), "the same term still matches in the text run beside the tag")


func _test_highlight_merges_overlaps() -> void:
	var out := GDLLMMarkdown.highlight_bbcode("abcd", PackedStringArray(["abc", "bcd"]))
	_check(out == "[bgcolor=%s]abcd[/bgcolor]" % GDLLMColors.hex(GDLLMColors.SEARCH_HIGHLIGHT), "overlapping terms merge into one wash instead of nesting")
