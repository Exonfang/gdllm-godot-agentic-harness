@tool
class_name GDLLMColors
## The chat log's palette, as editor settings under gdllm/colors/. Every color the log paints with is one of the roles below, shared by every site that means the same thing — one edit repaints all of them. The defaults are the colors the log has always carried, so an untouched install looks exactly as before; they were picked against the dark editor theme, which is why a light-theme reader can now raise their own contrast without a code change.

const USER_BACKGROUND := "gdllm/colors/user_background" ## Wash behind a message you wrote (and behind a "Changed model to…" row, which belongs to you the same way).
const USER_CAPTION := "gdllm/colors/user_caption" ## Caption on your own turn's disclosures — brighter than the dim status captions, tinted like USER_BACKGROUND.
const AGENT_BACKGROUND := "gdllm/colors/agent_background" ## Wash behind the agent's final response — the green counterpart to USER_BACKGROUND.
const AGENT_CAPTION := "gdllm/colors/agent_caption" ## Caption on the agent response's disclosure, and on the "Response generated!" notice.
const REDIRECT_BACKGROUND := "gdllm/colors/redirect_background" ## Wash behind a reply the system forced (e.g. after cutting a tool loop short) — the red counterpart to AGENT_BACKGROUND.
const ERROR_CAPTION := "gdllm/colors/error_caption" ## Everything that went wrong or was cut short: the inline "Error" header, redirect and interruption notices, a failed subagent or task, the context meter's danger tier.
const TOOL_CAPTION := "gdllm/colors/tool_caption" ## Caption on tool calls, tool results, and the subagent panels whose inner runs are made of them.
const ATTACHMENT_CAPTION := "gdllm/colors/attachment_caption" ## Caption on the synthetic call/result pair carrying something you attached — the tool family's shape, but your color, since you attached it and the model did not fetch it.
const SUBAGENT_BACKGROUND := "gdllm/colors/subagent_background" ## Faint wash grouping a subagent's whole inner run into one nested block — purple, the tool family's hue.
const TASK_BACKGROUND := "gdllm/colors/task_background" ## Faint wash behind a background Tasks-Model run (title generation) — neutral, since the run belongs to the plugin rather than any chat role.
const COMPACTION_BACKGROUND := "gdllm/colors/compaction_background" ## Faint wash behind a compaction disclosure — WARNING_CAPTION's hue, tying the panel to the context meter's warning state.
const STATUS_CAPTION := "gdllm/colors/status_caption" ## The dim default for captions with no role of their own: thought traces, the "generating response…" placeholder, the context meter at rest.
const WARNING_CAPTION := "gdllm/colors/warning_caption" ## Compaction headers and the context meter once the last prompt filled CONTEXT_WARN_SHARE of the model's window.
const CODE := "gdllm/colors/code" ## Code spans and blocks inside a message, so they stand out from prose.
const SYSTEM_CAPTION := "gdllm/colors/system_caption" ## The "System" header on a message whose role is neither yours nor the agent's.
const THINKING_TEXT := "gdllm/colors/thinking_text" ## The reasoning trace's body, dimmed so a churning trace never competes with the reply it precedes.
const FOOTER_TEXT := "gdllm/colors/footer_text" ## The dim bookkeeping footers under a turn — the token/throughput line beneath a reply and the "sent to …" line beneath your message.
const SEARCH_HIGHLIGHT := "gdllm/colors/search_highlight" ## Wash behind log-search matches; translucent by default so it reads over any bubble tint.

## Every configurable color's shipped default, keyed by its setting path. GDLLMSettings.register() defines the whole section from this map, and every read falls back to it — so adding a role here and a description in GDLLMSettingsHelp is all a new log color takes.
const DEFAULTS := {
	USER_BACKGROUND: Color(0.3, 0.5, 0.95, 0.3),
	USER_CAPTION: Color(0.55, 0.78, 1.0),
	AGENT_BACKGROUND: Color(0.3, 0.75, 0.45, 0.22),
	AGENT_CAPTION: Color("7ee787"),
	REDIRECT_BACKGROUND: Color(0.95, 0.35, 0.35, 0.22),
	ERROR_CAPTION: Color("f2777a"),
	TOOL_CAPTION: Color("d2a8ff"),
	ATTACHMENT_CAPTION: Color("6cb6ff"),
	SUBAGENT_BACKGROUND: Color(0.6, 0.45, 0.95, 0.14),
	TASK_BACKGROUND: Color(0.75, 0.75, 0.75, 0.1),
	COMPACTION_BACKGROUND: Color(0.94, 0.64, 0.36, 0.12),
	STATUS_CAPTION: Color(1, 1, 1, 0.6),
	WARNING_CAPTION: Color("f0a45d"),
	CODE: Color("a3c8ff"),
	SYSTEM_CAPTION: Color("999999"),
	THINKING_TEXT: Color(1, 1, 1, 0.5),
	FOOTER_TEXT: Color(1, 1, 1, 0.80),
	SEARCH_HIGHLIGHT: Color("ffcc0044"),
}


## The user's color for `key` (one of the constants above), or the shipped default when it is unset, holds something that isn't a Color, or is read outside the editor.
static func color(key: String) -> Color:
	if not DEFAULTS.has(key):
		push_error("GDLLMColors: no color role named \"%s\" — pass one of GDLLMColors' key constants (DEFAULTS lists every registered role)." % key)
		return Color.WHITE
	var fallback: Color = DEFAULTS[key]
	# A headless --script run has no editor settings to read; the shipped palette is the honest answer there (the GDLLMEfforts.get_config precedent).
	if not Engine.is_editor_hint():
		return fallback
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(key):
		return fallback
	var stored: Variant = es.get_setting(key)
	return stored if stored is Color else fallback


## `key`'s color as a "#rrggbbaa" string for the render sites that interpolate it into BBCode instead of setting it on a node.
static func hex(key: String) -> String:
	return "#" + color(key).to_html(true)


## A comparable snapshot of the whole palette, so a settings_changed listener can tell an actual color edit from any other write (see GDLLMChatDock._on_editor_settings_changed).
static func snapshot() -> String:
	var parts := PackedStringArray()
	for key: String in DEFAULTS:
		parts.append(color(key).to_html(true))
	return "|".join(parts)
