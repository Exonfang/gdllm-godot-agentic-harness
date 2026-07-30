@tool
class_name GDLLMMarkdown
## The chat log's Markdown seam: decides whether model replies render through the MarkdownLabel addon or fall back to a plain RichTextLabel, builds the right label, and holds the search-highlight walker both render paths share — plus the system prompt's {markdown_rendering} placeholder, so the model is always told how its replies actually render.
## MarkdownLabel is optional: it may be absent from the project (only this plugin was installed), or present but declined via the Render Markdown Responses editor setting (installed for the game, not wanted here). Either way the fallback is the same — verbatim text in a standard RichTextLabel — so nothing here may name ChatMarkdownLabel or MarkdownLabel at compile time; the one script that does (chat_markdown_label.gd) is reached only through load(), after the library is confirmed present.

## Where the library's own script lives when installed the standard way; the global class list covers a nonstandard location.
const LIBRARY_SCRIPT_PATH := "res://addons/markdownlabel/markdownlabel.gd"

## Our MarkdownLabel subclass, loadable only while the library is present (its extends would fail to resolve otherwise).
const CHAT_LABEL_PATH := "res://addons/gdllm-godot-agentic-harness/chat_markdown_label.gd"

## The system prompt's Markdown placeholder and the instruction it becomes for each render state (see GDLLMSettings._apply_placeholders). The plain-text state instructs AGAINST Markdown rather than just dropping the ask: models write Markdown for structured answers unprompted (wild-validated 2026-07-30), and in the plain label that syntax shows raw.
const PROMPT_PLACEHOLDER := "{markdown_rendering}"
const PROMPT_SENTENCE := "Your responses are rendered as Markdown, so use Markdown formatting."
const PROMPT_SENTENCE_PLAIN := "Your responses are shown as plain text, exactly as written, so do not use Markdown formatting."

## The loaded chat label script; null until the first successful probe. A library-absent probe is NOT cached, so installing MarkdownLabel mid-session takes effect on the next rendered message, and is_chat_markdown stays a pointer compare for the highlight walker that runs per node per search keystroke.
static var _chat_label_script: GDScript = null

## Whether the library looked present but our subclass failed to load anyway. Cached because that load prints engine errors — retrying per rendered message would spam them for a state a retry can't fix.
static var _load_failed := false


## Whether the MarkdownLabel library is installed and our label subclass compiles against it. Loads the subclass on first success and keeps it.
static func available() -> bool:
	if _chat_label_script != null:
		return true
	if _load_failed or not _library_present():
		return false
	var script: GDScript = load(CHAT_LABEL_PATH)
	if script == null or not script.can_instantiate():
		_load_failed = true
		return false
	_chat_label_script = script
	return true


## Whether replies should render as Markdown right now: the library is available AND the user hasn't turned rendering off. The setting lives in EditorSettings, so it's only consulted in the editor; headless runs (the test scripts) get availability alone.
static func enabled() -> bool:
	if Engine.is_editor_hint() and not GDLLMSettings.is_markdown_responses_enabled():
		return false
	return available()


## A fresh ChatMarkdownLabel when Markdown rendering is on, or null to tell the caller to build its plain fallback. Typed RichTextLabel because the subclass can't be named here; callers reach its members through set()/connect().
static func make_label() -> RichTextLabel:
	if not enabled():
		return null
	return _chat_label_script.new()


## Whether `node` is one of make_label's Markdown labels — the dynamic stand-in for `node is ChatMarkdownLabel`, which would drag the library back into every caller's compile.
static func is_chat_markdown(node: Node) -> bool:
	return _chat_label_script != null and node.get_script() == _chat_label_script


## Expand PROMPT_PLACEHOLDER to the sentence matching the render state. Pure on purpose — callers pass enabled(), tests pass both values.
static func apply_prompt_placeholder(prompt: String, render_on: bool) -> String:
	return prompt.replace(PROMPT_PLACEHOLDER, PROMPT_SENTENCE if render_on else PROMPT_SENTENCE_PLAIN)


static func _library_present() -> bool:
	if FileAccess.file_exists(LIBRARY_SCRIPT_PATH):
		return true
	for entry in ProjectSettings.get_global_class_list():
		# The entry's path is checked too: the class list is a disk cache that outlives a deleted addon, and probing a stale entry would print load errors on every rendered message.
		if String(entry.get("class", "")) == "MarkdownLabel" and FileAccess.file_exists(String(entry.get("path", ""))):
			return true
	return false


## Wrap every case-insensitive occurrence of `terms` in `bbcode`'s text runs with a [bgcolor] in the configured search-highlight color. Tags are skipped whole so a term never matches into markup (a match spanning a tag boundary goes unhighlighted). Shared by the Markdown labels (see ChatMarkdownLabel._convert_markdown), the plain fallback labels, and the session's plain-text log labels (see GDLLMChatSession._highlight_search_labels).
static func highlight_bbcode(bbcode: String, terms: PackedStringArray) -> String:
	var out := ""
	var pos := 0
	while pos < bbcode.length():
		if bbcode[pos] == "[":
			var close := bbcode.find("]", pos)
			if close == -1:
				out += _mark_terms(bbcode.substr(pos), terms)
				break
			out += bbcode.substr(pos, close - pos + 1)
			pos = close + 1
		else:
			var next_tag := bbcode.find("[", pos)
			if next_tag == -1:
				next_tag = bbcode.length()
			out += _mark_terms(bbcode.substr(pos, next_tag - pos), terms)
			pos = next_tag
	return out


## Wrap the matches within one tag-free text run, merging overlapping ranges across terms so nested [bgcolor]s never emit.
static func _mark_terms(text: String, terms: PackedStringArray) -> String:
	var ranges: Array[Vector2i] = []
	var lower := text.to_lower()
	for term in terms:
		var needle := term.to_lower()
		if needle.is_empty():
			continue
		var from := 0
		while true:
			var at := lower.find(needle, from)
			if at == -1:
				break
			ranges.append(Vector2i(at, at + needle.length()))
			from = at + needle.length()
	if ranges.is_empty():
		return text
	ranges.sort()
	var merged: Array[Vector2i] = []
	for r in ranges:
		var last := merged.size() - 1
		if merged.is_empty() or r.x > merged[last].y:
			merged.append(r)
		else:
			merged[last].y = maxi(merged[last].y, r.y)
	var wash := GDLLMColors.hex(GDLLMColors.SEARCH_HIGHLIGHT)
	var out := ""
	var pos := 0
	for r in merged:
		out += text.substr(pos, r.x - pos)
		out += "[bgcolor=%s]%s[/bgcolor]" % [wash, text.substr(r.x, r.y - r.x)]
		pos = r.y
	out += text.substr(pos)
	return out
