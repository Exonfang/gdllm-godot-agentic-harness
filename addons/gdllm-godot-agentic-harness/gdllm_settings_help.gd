@tool
class_name GDLLMSettingsHelp
extends EditorInspectorPlugin
## Injects always-visible descriptions for the plugin's settings into the Editor Settings dialog. The engine offers plugins no description channel there — add_property_info carries only name/type/hint/hint_string and the hover help bit reads engine class docs a plugin can't extend — so each described setting gets a dim caption rendered above its row instead.

## User-facing prose per full setting path, written for a reader who doesn't know harness jargon — each explains its concept (context window, buffer, prune, prompt cache), not just its mechanics. Adding an entry here is all it takes to describe another setting.
const DESCRIPTIONS := {
	GDLLMSettings.MARKDOWN_RESPONSES: "Renders the assistant's replies as formatted Markdown — headings, bold, code blocks, tables — through the MarkdownLabel addon, when that addon is installed in the project. Turn this off to show replies exactly as the model wrote them, as plain text in a standard label: useful when MarkdownLabel is installed for your game but you'd rather this plugin not use it. When the addon isn't installed at all, replies get the same plain rendering automatically, whatever this is set to. Either way nothing is lost or hidden — the text is identical, only the formatting changes — and the role headers and clickable project-file links are kept, since those come from this plugin, not from Markdown. Applies to messages rendered from now on; already-rendered messages keep their look until their session is next rebuilt (reloading the session or restarting the editor). The system prompt follows along: its {markdown_rendering} placeholder asks the model for Markdown formatting while Markdown actually renders, and asks it to write plainly when not — models produce Markdown unprompted, and in the plain label that syntax would show as raw symbols.",
	GDLLMSettings.GAME_AGENT: "Keeps a small autoload (GDLLMGameAgent, visible under Project Settings → Globals) registered in the project — the in-game half of the game-driving tools, which lets the assistant read the running game's UI, click its buttons, play real input, and call methods on live nodes, always through the editor's debugger connection. The autoload does nothing at all in a game launched without a debugger (a normal export stays untouched), and everything it does for the assistant is shown in the chat like any other tool call. Turning this off removes the autoload from the project immediately; games already running keep the agent they launched with until restarted.",
	GDLLMSettings.AUTO_COMPACTION: "Automatically shrinks what the model sees when a conversation is about to outgrow its context window (the fixed number of tokens a model can read at once). Before every request the plugin predicts the next prompt's size; when it would no longer fit, old tool-result outputs are dropped from the model's view — the chat log and the stored transcript always keep everything, and every pass is disclosed in the log. When off, nothing is ever compacted automatically — the chat's Compact button still works on demand — and an overlong conversation risks being truncated silently by the provider (Ollama drops the oldest messages without reporting it), so a red warning posts in the chat once a request is predicted past the window.",
	GDLLMSettings.COMPACTION_BUFFER: "Safety headroom, in tokens, kept between the predicted size of the next request and the model's context window: compaction triggers once the prediction gets within this many tokens of the window. Predictions are estimates and the model's reply also needs room, so the buffer absorbs both. Raise it if conversations still overflow before compaction fires; lower it to use more of the window; 0 waits until the window itself is predicted full. The default covers the worst prediction miss measured in live logs plus a typical reply.",
	GDLLMSettings.COMPACTION_PRUNE_THRESHOLD: "Tool-result pruning never runs while the conversation is predicted smaller than this many tokens, so a small conversation is never touched even when the compaction trigger fires. A skipped pass says so in its log entry. 0 lets pruning run at any size. Pressing the chat's Compact button waives this floor — an explicit request needs no protection from itself.",
	GDLLMSettings.COMPACTION_PRUNE_MIN_RECOVERY: "The fewest tokens a pruning pass must reclaim before it commits. Providers cache the unchanged front of a conversation between requests (the prompt cache), and a prune rewrites history from the oldest dropped result forward, so the next request re-processes everything after that point — a tiny recovery would cost more than it saves. A pass that can't reach this figure prunes nothing and reports the shortfall. 0 commits any recovery.",
	GDLLMSettings.COMPACTION_SUMMARIZATION: "When pruning old tool results alone can't shrink the conversation enough, compaction's second pass has the session's model write a structured summary that stands in for the older part of the conversation in the model's view (the newest share set below stays verbatim). Turn this off to never summarize automatically: pruning stays the only automatic pass, a shortfall it can't cover is noted in the log, a conversation still predicted past the window gets the red over-window warning, and the manual Compact dialog's summarize checkbox starts unchecked (checking it there still runs one summarization on demand). The chat log and stored transcript always keep the full history either way.",
	GDLLMSettings.COMPACTION_IN_SUBAGENTS: "Also compacts inside subagents (the fresh-context helpers the chat delegates tasks to), whose own tool transcripts grow the same way the conversation's does. When a subagent's next request is predicted past its model's context window, its old tool-result outputs are replaced by short markers in what the model sees; the activity panel keeps every full output and each prune is disclosed there. Subagents are never summarized — pruning is their only pass. Ignored while the master switch above is off.",
	GDLLMSettings.COMPACTION_TAIL_PERCENT: "When compaction has to summarize the conversation (pruning old tool results alone wasn't enough), this is the share of the model-visible conversation — newest first — kept verbatim; everything older is replaced in the model's view by a structured summary written by the session's own model. The split never separates a tool call from its result: it lands on a message you wrote. 30 keeps the newest 30% and summarizes the older 70%. The chat log and stored transcript always keep the full history; an orange panel marks where the replacement begins.",
	GDLLMSettings.CACHE_TTL_FALLBACK: "How many seconds a conversation can sit idle before its provider prompt cache is presumed expired. Providers cache the unchanged front of a conversation between requests, but only for a limited lifetime (the cache TTL) — once it lapses, the next request re-processes everything anyway, which makes that moment a free opportunity to trim context (retiring idle tool schemas today; disclosed in the log). Each model can carry its provider's real TTL in the Effort Configuration dialog (the ⚡ button beside the model picker); this value applies to models without one. The default 300 is Anthropic's 5-minute TTL, the shortest documented among supported providers, so trimming never invalidates a cache that was still alive. 0 presumes the cache always expired — only sensible for a provider that caches nothing. On Anthropic sources the effective value (this fallback, or the model's own figure) is also requested with every send: anything over 300 asks for Anthropic's 1-hour cache tier, which doubles the cache-write cost in exchange for the longer lifetime, so raising this fallback affects Anthropic billing, not just the local presumption.",
	GDLLMSettings.COMPACTION_DEBUG: "Turns on the compaction debugging overrides. While off, every debug value is ignored entirely, so a value left over from an old debugging session can't distort real compaction behavior.",
	GDLLMSettings.COMPACTION_DEBUG_THRESHOLD: "Debug only: stands in for the model's context window, in tokens, so compaction can be exercised on a small conversation instead of a genuinely full one. While active the buffer is treated as 0, so the trigger fires exactly at this figure, and the log labels each trigger as debug-tripped. 0 keeps the override off; ignored unless Enable Debugging Tools is on.",
	GDLLMColors.USER_BACKGROUND: "Background wash behind every message you wrote, and behind the row marking a model change — both are yours. Every color on this page ships set to the value the chat log has always used, all of them chosen against the dark editor theme, so a light theme is exactly the case worth retuning here; the revert arrow beside a row puts the original back. An edit repaints the open chats within a moment, except one mid-reply, which repaints when it next reloads.",
	GDLLMColors.USER_CAPTION: "Text color of the disclosure rows on your own turns — the \"You wrote...\" and \"You attached...\" lines — and of the model-change row's caption.",
	GDLLMColors.AGENT_BACKGROUND: "Background wash behind the assistant's final answer, the green counterpart to the wash behind your messages. Also fills the small panel that holds the \"Response generated!\" notice.",
	GDLLMColors.AGENT_CAPTION: "Text color of the \"Generated response…\" row above each answer, and of the \"Response generated!\" notice that appears when a reply lands while you have scrolled away from the bottom.",
	GDLLMColors.REDIRECT_BACKGROUND: "Background wash behind a reply the plugin forced rather than the model volunteering it — what you get when a runaway tool loop is cut short and the model is asked to summarize where it got to. The red counterpart to the assistant's green.",
	GDLLMColors.ERROR_CAPTION: "The color for everything that failed or was cut short: the \"Error\" header on a failed request, redirect and interruption notices, a subagent or background task that ended in failure, and the context meter once the conversation is close to overflowing the model's window.",
	GDLLMColors.TOOL_CAPTION: "Text color of every tool row — \"Called <tool>\" and \"Result from <tool>\" — and of the subagent panels, whose inner runs are made of the same rows.",
	GDLLMColors.ATTACHMENT_CAPTION: "Text color of the rows carrying something you attached to a message (a script, a selection, a scene node). They are shaped like tool rows because the model reads them the same way, but they are colored apart because you supplied them and the model did not go fetch them.",
	GDLLMColors.SUBAGENT_BACKGROUND: "Background wash grouping a subagent's whole inner run — its reasoning, tool calls, and results — into one nested block, so a helper's work reads as belonging to the turn that spawned it. Faint by design: it sits under rows that carry their own colors.",
	GDLLMColors.TASK_BACKGROUND: "Background wash behind work the plugin runs for itself on the small Tasks model, such as generating a session's title. Neutral gray because the run belongs to neither you nor the assistant.",
	GDLLMColors.COMPACTION_BACKGROUND: "Background wash behind a compaction panel — the disclosure that appears whenever the plugin shrinks what the model can see to keep a long conversation inside its context window, and behind the summary it starts from afterwards.",
	GDLLMColors.STATUS_CAPTION: "The dim default for every caption without a role of its own: reasoning traces, the \"generating response…\" placeholder, the sent-to-model disclosures, and the context meter while it has nothing to warn about.",
	GDLLMColors.WARNING_CAPTION: "The color for approaching trouble rather than trouble itself: compaction headers, and the context meter once the last prompt filled half the model's context window (the error color takes over past 80%).",
	GDLLMColors.CODE: "Text color of code — both inline spans and fenced blocks — inside chat messages, so code stands out from the prose around it.",
	GDLLMColors.SYSTEM_CAPTION: "Text color of the \"System\" header on a message that belongs to neither you nor the assistant. Rare in practice; it exists so no message can ever render unlabeled.",
	GDLLMColors.THINKING_TEXT: "Text color of a reasoning trace's body — the model's own thinking, shown in full but dimmed so a long trace never competes with the answer it precedes. Raise its brightness to read traces more comfortably.",
	GDLLMColors.FOOTER_TEXT: "Text color of the small bookkeeping footers inside the log — the token-count and speed line beneath a reply, and the \"sent to …\" line beneath your own message — dimmed so the numbers never compete with the conversation.",
	GDLLMColors.SEARCH_HIGHLIGHT: "Wash drawn behind matches when you search the chat log from the field in its header. Translucent by default so the text stays readable over whatever bubble it lands on — keep some transparency, or matches will be highlighted into illegibility.",
}

const CAPTION_ALPHA := 0.6 ## Same dim white the chat log uses for its status captions.
const CAPTION_TOP_MARGIN := 8 ## Binds a caption to the setting row below it rather than the one above.


func _can_handle(object: Object) -> bool:
	# The settings dialogs inspect EditorSettings/ProjectSettings through this internal proxy and nothing else uses it, so this scopes the captions to those dialogs and keeps them out of scene and resource inspectors.
	return object.get_class() == "SectionedInspectorFilter"


func _parse_property(object: Object, _type: Variant.Type, name: String, _hint_type: PropertyHint, _hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	var key := _full_key(name)
	if key == "":
		return false
	# The proxy strips the selected section from names, so confirm this bare name really forwards to our editor setting and not to a same-named property elsewhere.
	if not is_same(object.get(name), EditorInterface.get_editor_settings().get_setting(key)):
		return false
	add_custom_control(_caption(String(DESCRIPTIONS[key])))
	return false


## The full described setting path whose tail matches `name` as the dialog's proxy exposes it — section-stripped ("buffer_tokens"), partially stripped from a parent section ("compaction/buffer_tokens"), or whole — or "" for a property that isn't ours.
func _full_key(name: String) -> String:
	for key in DESCRIPTIONS:
		var full := String(key)
		if full == name or full.ends_with("/" + name):
			return full
	return ""


## A dim, wrapping caption holding `text`, top-margined so it reads as belonging to the setting row rendered beneath it.
func _caption(text: String) -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", CAPTION_TOP_MARGIN)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.self_modulate = Color(1, 1, 1, CAPTION_ALPHA)
	margin.add_child(label)
	return margin
