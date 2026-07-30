@tool
class_name GDLLMSubagent extends Node
## A fresh-context helper the chat spins up to offload a self-contained task to its own model instance, then hand only the result back to the main agent — the narrow-context idea one level down: the subagent sees the task it's given, never the main conversation. It runs headless (no UI): handed a task it either answers in one shot (tool-less — the shape read_file uses to map a long file) or, when given tools, runs its own agentic tool loop (tool_search → read_file/search_files/…, exactly like the main chat) until it has an answer. Add it to the tree, `await run(...)`, use the returned text, then free it; `cancel()` interrupts it (and any nested subagent) for the Stop button.

signal request_finished(outcome: Dictionary) ## Internal: resolves one _send()'s await exactly once with {kind: "text"|"tools"|"error"|"cancelled", ...}; guarded by _done so a late signal (or a cancel racing a completion) can't double-fire.
signal activity(event: Dictionary) ## Emitted for each step the subagent takes — its reasoning, intermediate notes, tool calls, tool results, and per-request usage stats, plus (forwarded) those of any nested subagent — so the chat can surface the whole inner run rather than hiding it behind a spinner. Each event carries a `depth` for indentation. Live `phase` events (reasoning started, answer started) additionally steer the panel's bottom status row mid-request. Display only: never fed back to any model.

var was_cancelled: bool = false ## True once cancel() interrupted this run (or a nested one), so the caller can abort its turn instead of using the empty result. Also read inside the loop to bail between steps.
var mutation_ledger: PackedStringArray = PackedStringArray() ## The tool layer's own record of this run's successful mutating calls ("<tool> <target>" lines, a nested run's entries merged in), appended to a tools-enabled answer so the parent can diff engine truth against whatever the subagent claims it did.
var _client: LLMClient ## Private client owned by this subagent and freed with it, so its request can't collide with the main session's.
var _nested: GDLLMSubagent = null ## A subagent this one is itself running (a long-file map or a nested delegation); tracked so cancel() propagates down the chain.
var _done: bool = false ## Whether the in-flight request's await has already been resolved, so a completion arriving after a cancel (or vice versa) is ignored.
var _depth: int = 1 ## This subagent's nesting level, stamped on the activity events it emits so the chat can indent nested runs inside their parent's (set in run()).
var _turn_thinking: String = "" ## Reasoning accumulated for the in-flight request via thinking_delta, emitted as a `thinking` activity event once the turn resolves, then reset by the next _send().
var _allow_changes: bool = false ## The spawning session's "Make changes" state at launch, inherited so a subagent can never mutate more than the chat that spawned it.
var _allow_delete: bool = false ## The spawning session's "Delete files" state at launch, inherited the same way so a subagent can never delete more than the chat that spawned it.
var _ledger: GDLLMTools.SessionLedger = null ## The spawning session's tool ledger, shared so this run's reads and verdicts land in that session's record; null lets execute() fall back to its shared default (bare headless runs).
var _qualified_source: String = "" ## The run's source and model as a qualified id, stamped on stats events so each footer names who answered (set in run()).
var _reported_base: int = 0 ## The compaction predictor's base: the newest provider-reported prompt+output token count in the tool loop, 0 until a request reports usage (the trigger stays silent without one, like the main chat's).
var _delta_from: int = 0 ## Messages index the predictor's chars/4 delta counts from — everything at or past it postdates the reported base.
var _compact_refusal_noted: bool = false ## A prune skip or refusal has been disclosed this run, so later rounds don't re-post the same unchanged reason (see _note_compaction_refusal).
var _over_window_noted: bool = false ## The over-window warning has been disclosed for the current overflow; re-armed once a prediction lands back under the window, mirroring the main chat's once-per-overflow rule.
var _repeat_scope: String = "" ## This run's own GDLLMRepeats owner id, set in run() — repeat numbering is per-agent like the loop brakes, so a fresh run's first call is never tagged as a repeat the main chat (or another run) made.


## The source a deferred `subagent` spec runs on: the caller's own `fallback` normally, or the settings' Tasks Model when the spec sets `tasks_model` — a pure transform like read_file's file map is a background chore fit for the small tasks model, unlike a delegation, which stays on the chat model. An unconfigured tasks model falls back to the caller's source so a flagged spec still runs.
static func spec_source(spec: Dictionary, fallback: Dictionary) -> Dictionary:
	if not bool(spec.get("tasks_model", false)) or GDLLMSettings.get_tasks_model() == "":
		return fallback
	var source := GDLLMSettings.get_tasks_source_and_model()
	if String(source.get("model", "")) == "" or String(source.get("base_url", "")) == "":
		return fallback
	return source


## One ledger line for an executed tool call — "<tool> <path>" plus " (left BROKEN)" when the result says the file was left broken — or "" for a call that only read, errored, or was refused, so the ledger holds exactly what the tool layer actually changed. The target is resolved through the same argument synonyms GDLLMTools reads, falling back to the bare tool name.
static func ledger_entry(tool_name: String, args: Dictionary, result_content: String) -> String:
	if not GDLLMTools.is_mutating(tool_name) or result_content.begins_with("Error"):
		return ""
	var entry := tool_name
	for key in GDLLMTools.FILE_PATH_KEYS:
		if args.has(key) and String(args[key]).strip_edges() != "":
			entry += " " + String(args[key]).strip_edges()
			break
	if result_content.contains("BROKEN on disk"):
		entry += " (left BROKEN)"
	return entry


## Run `prompt` on the resolved `source` (endpoint + key + wire format + model, from GDLLMSources.resolve_qualified) under `system_prompt` and return the model's answer. With `use_tools` false it's a single tool-less turn (a pure transform, e.g. mapping a file). With `use_tools` true it runs an agentic loop — the model reaches the project's tools through tool_search just as the main chat does — until it produces a final answer or is cancelled; the loop has no iteration cap, but it carries the main chat's loop brakes (see GDLLMLoopBrakes) and its setting-gated context compaction (tool-result pruning; see _maybe_compact), and a tripped escalation ends the run with the model's own progress summary as its answer (see _break_loop) — the top-level Stop (cancel) remains the manual brake. `depth` is this subagent's nesting level (1 for one the main chat spawned), stamped on its activity events so the chat can indent nested runs. `allow_changes` is the spawning session's "Make changes" state, gating mutating tools exactly as it does in the main chat, and `allow_delete` its "Delete files" state, gating destructive ones the same way. `ledger` is the spawning session's tool ledger, shared down the whole subagent chain. A request failure resolves to an "Error: …" string the caller can surface; a cancel resolves to "" with was_cancelled set.
func run(source: Dictionary, system_prompt: String, prompt: String, use_tools: bool = false, depth: int = 1, allow_changes: bool = false, allow_delete: bool = false, ledger: GDLLMTools.SessionLedger = null) -> String:
	_allow_changes = allow_changes
	_allow_delete = allow_delete
	_ledger = ledger
	mutation_ledger = PackedStringArray()
	_client = LLMClient.new()
	add_child(_client)
	_client.configure_from(source) # the caller resolves the source: the parent's model, or the Tasks Model for a spec that flagged tasks_model (see spec_source)
	_client.response_received.connect(_on_response)
	_client.tool_calls_received.connect(_on_tool_calls)
	_client.request_failed.connect(_on_failed)
	_client.thinking_delta.connect(_on_thinking_delta)
	_client.generating_started.connect(_on_generating_started)
	_depth = depth
	_qualified_source = GDLLMSources.make_qualified(String(source.get("source_id", "")), String(source.get("model", "")))
	# The composed instructions are the one part of a run the activity events don't already carry, so disclose them first — they persist and replay with the rest of the panel, and nesting forwards them like every other event (goal 2).
	_emit({"type": "subagent_prompt", "system": system_prompt, "prompt": prompt, "model": _qualified_source})

	var messages: Array = [{"role": "user", "content": prompt}]
	if not use_tools:
		var solo := await _send(messages, system_prompt, [])
		_emit_thinking()
		_emit_stats(solo)
		return _final_text(solo)

	var active_tools: Dictionary = {} # tools the subagent has discovered via tool_search, attached to later turns (same narrow-context flow as the main chat)
	var brakes := GDLLMLoopBrakes.new() # the same per-run loop brakes the main chat carries; a tripped escalation ends the run with a progress summary (see _break_loop)
	_repeat_scope = "subagent:%d" % get_instance_id()
	GDLLMRepeats.reset_turn(_repeat_scope) # a reused instance id must never inherit a freed run's counts
	while true:
		if was_cancelled:
			return ""
		_maybe_compact(messages, system_prompt)
		var outcome := await _send(messages, system_prompt, _build_tools(active_tools))
		if was_cancelled:
			return ""
		_emit_thinking() # surface this turn's reasoning before whatever it decided to do with it
		match String(outcome.get("kind", "")):
			"error":
				return _failure_text(String(outcome.get("reason", "")))
			"text":
				_emit_stats(outcome)
				return _with_ledger(_final_text(outcome))
			"tools":
				var tool_calls: Array = outcome.get("tool_calls", [])
				var preamble := String(outcome.get("content", ""))
				if preamble.strip_edges() != "":
					_emit({"type": "assistant_text", "text": preamble})
				_emit_stats(outcome) # after the turn's note, before its tool calls — where the main chat places a message's footer
				# Echo the assistant tool-call turn back so the model sees its own calls, sanitized to the shape Ollama accepts on resend.
				var echo := {"role": "assistant", "content": preamble, "tool_calls": GDLLMTools.sanitize_tool_calls(tool_calls)}
				# A provider that must see its raw turn echoed to continue the loop (Anthropic) left its blocks on the outcome; carry them so the adapter can replay the turn verbatim (see LLMClient.last_assistant_blocks).
				if outcome.get("assistant_blocks") is Array and not outcome["assistant_blocks"].is_empty():
					echo["assistant_blocks"] = outcome["assistant_blocks"]
				messages.append(echo)
				# This outcome's reported usage covers everything up to and including the echo just appended (its output count spans the reply), so the compaction predictor's delta restarts after it.
				var usage: Dictionary = outcome.get("stats", {}) if outcome.get("stats") is Dictionary else {}
				if int(usage.get("tokens_in", 0)) > 0:
					_reported_base = int(usage["tokens_in"]) + int(usage.get("tokens_out", 0))
					_delta_from = messages.size()
				var used_this_round: Dictionary = {} # the round's distinct tool names, feeding the streak and oscillation guards exactly as the main chat's rounds do
				for tc in tool_calls:
					var called := GDLLMTools.tool_call_name(tc)
					if called != "":
						used_this_round[called] = true
						# A direct call to an unattached registered tool attaches its schema for the rest of the loop — the same rule the main chat's rounds apply.
						if called != GDLLMTools.TOOL_SEARCH and GDLLMTools.REGISTRY.has(called):
							active_tools[called] = true
				var round_repeated := false # a call this round re-ran identically with an identical result — the no-progress evidence the oscillation nudge requires
				var fresh_activation := false # a search this round attached a NEW tool — the progress signal that resets the streak guard (see track_consecutive_use)
				for i in tool_calls.size():
					var tc: Variant = tool_calls[i]
					var tool_name := GDLLMTools.tool_call_name(tc)
					var call_args := GDLLMTools.tool_call_args(tc)
					_emit({"type": "tool_call", "name": tool_name, "args": call_args})
					var result: Dictionary = await GDLLMTools.execute(tool_name, call_args, _allow_changes, _allow_delete, active_tools, _ledger, _repeat_scope)
					for activated in result.get("activate", PackedStringArray()):
						if not active_tools.has(activated):
							fresh_activation = true
						active_tools[activated] = true
					var content := String(result.get("content", ""))
					# A tool may defer to a further subagent (a long file to map, or a nested delegation); run it and use its reply, bailing if a cancel propagated up. Its own steps forward up while it runs, landing between this call and its result.
					if result.has("subagent"):
						content = await _run_nested(result["subagent"], source, depth)
						if was_cancelled:
							return ""
					var entry := ledger_entry(tool_name, call_args, content)
					if entry != "":
						mutation_ledger.append(entry)
					# The main chat's loop brakes on the raw result (the ledger above already recorded engine truth): a duplicate's body is withheld behind the nudge (mutations instead serve in full behind a repeat note); nested-subagent replies are exempt as nondeterministic by design.
					if not result.has("subagent"):
						var braked: Dictionary = brakes.process_result(tool_name, call_args, content)
						round_repeated = round_repeated or bool(braked["repeated"])
						content = String(braked["content"])
					if i == tool_calls.size() - 1:
						content += brakes.oscillation_nudge(used_this_round, round_repeated)
					_emit({"type": "tool_result", "name": tool_name, "content": content})
					messages.append({"role": "tool", "content": content, "tool_name": tool_name})
				# The same escalations the main chat redirects on; with no UI to redirect, the run ends with the model's account of its progress as its answer.
				var repeats := brakes.take_escalation()
				if repeats > 0:
					return await _break_loop(messages, system_prompt, GDLLMTools.DUPLICATE_ESCALATION_MESSAGE % repeats,
							"%d identical re-runs despite duplicate warnings" % repeats)
				var looping_tool := brakes.track_consecutive_use(used_this_round, fresh_activation)
				if looping_tool != "":
					return await _break_loop(messages, system_prompt, GDLLMTools.loop_break_message(looping_tool),
							"%d consecutive rounds of %s without progress" % [GDLLMTools.max_consecutive_uses(looping_tool), looping_tool])
			_:
				return "" # cancelled
	return "" # unreachable; the loop only exits via return


func _exit_tree() -> void:
	# The run's repeat counts die with it, so the static ledger doesn't accumulate one orphaned scope per freed run.
	if _repeat_scope != "":
		GDLLMRepeats.reset_turn(_repeat_scope)


## Interrupt an in-flight run: flag it cancelled, silence the request (and any nested subagent), and resume run() with an empty, cancelled result. The resume is deferred so a caller cancelling from a UI event (the Stop button) fully unwinds before run() continues.
func cancel() -> void:
	was_cancelled = true
	if is_instance_valid(_client):
		_client.cancel()
	if _nested != null:
		_nested.cancel()
	_resolve.call_deferred({"kind": "cancelled"})


## Issue one chat request and await its single outcome as {kind, ...}. Resets the per-request guard so each send resolves independently; a cancel mid-flight resolves it as {kind: "cancelled"}. The request's wall-clock lands on the outcome as `seconds`, feeding the stats footer's inferred throughput when the provider reports no timing.
func _send(messages: Array, system_prompt: String, tools: Array) -> Dictionary:
	_done = false
	_turn_thinking = ""
	var started := Time.get_ticks_msec()
	_client.send_chat_request(messages, system_prompt, tools)
	var outcome: Dictionary = await request_finished
	outcome["seconds"] = (Time.get_ticks_msec() - started) / 1000.0
	return outcome


## Run a tool's deferred `subagent` spec as a nested subagent — on this run's `source`, or the Tasks Model when the spec asks (see spec_source) — and return its reply behind the spec's result_preamble. A cancel of the nested run propagates up so the whole chain unwinds.
func _run_nested(spec: Dictionary, source: Dictionary, depth: int) -> String:
	var nested := GDLLMSubagent.new()
	add_child(nested)
	_nested = nested
	nested.activity.connect(_forward_activity) # bubble the nested run's steps up so the chat surfaces them too, indented by their deeper depth
	var nested_source := spec_source(spec, source)
	var label := String(spec.get("label", "Working"))
	# A nested run on a model other than this run's names the swap in its caption, matching the disclosure a top-level subagent panel gives.
	if String(nested_source.get("model", "")) != String(source.get("model", "")) or String(nested_source.get("source_id", "")) != String(source.get("source_id", "")):
		label += " · %s" % String(nested_source.get("model", ""))
	# Announce the nested run before its steps, stamped with its own deeper depth — without a caption a quiet run (no thinking, no reported tokens) would be entirely invisible.
	activity.emit({"type": "subagent_caption", "label": label, "depth": depth + 1})
	var nested_use_tools := bool(spec.get("tools", false))
	var text: String = await nested.run(nested_source, String(spec.get("system", "")), String(spec.get("prompt", "")), nested_use_tools, depth + 1, _allow_changes, _allow_delete, _ledger)
	# The nested run's changes are this run's changes too, so the record handed to the parent stays complete.
	mutation_ledger.append_array(nested.mutation_ledger)
	if nested.was_cancelled:
		was_cancelled = true
	_nested = null
	nested.queue_free()
	if was_cancelled:
		return ""
	# A failed nested run's preamble would frame the error as the delivered result (a map "follows" when none does), so the failure text stands alone with its own next-step guidance.
	if text.begins_with("Error:"):
		return text
	return String(spec.get("result_preamble", "")) + text


## A loop guard tripped mid-run: name the interruption in the activity feed (the red counterpart of the main chat's redirect notice), then re-send the conversation with the reflection `instruction` and NO tools, so the model must answer in prose — the same stop-and-account redirect the main chat performs. That summary becomes the run's answer, prefixed with the stop and its `reason` so the parent agent knows the run was interrupted rather than finished.
func _break_loop(messages: Array, system_prompt: String, instruction: String, reason: String) -> String:
	_emit({"type": "redirect", "text": "⚠ Loop guard stopped this run (%s) — asking the model for a progress summary" % reason})
	messages.append({"role": "user", "content": instruction})
	_maybe_compact(messages, system_prompt)
	var outcome := await _send(messages, system_prompt, [])
	if was_cancelled:
		return ""
	_emit_thinking()
	if String(outcome.get("kind", "")) == "error":
		return _failure_text(String(outcome.get("reason", "")))
	_emit_stats(outcome)
	return _with_ledger("[This subagent was stopped by its loop guard (%s); its own progress summary follows.]\n\n%s" % [reason, _final_text(outcome)])


## The main chat's compaction trigger and over-window guard, one level down (see GDLLMChatSession._maybe_trigger_compaction / _maybe_warn_over_window): before each tool-loop request, predict its size — the newest reported usage plus a chars/4 estimate of everything appended since — and once prediction + buffer reaches the model's window, prune old tool-result outputs from the loop's messages. No summarization runs down here: a subagent's growth IS tool results, exactly what pruning reclaims. The inner transcript is working state the activity feed has already surfaced in full, so the prune edits it in place, and every commit, refusal, and still-over-window outcome is disclosed as an activity event that persists with the panel (goal 2). The PASS is gated exactly like the main chat's — silent while the window is unknown, until a request has reported usage, and when compaction is switched off — but the window GUARD is not held back with it (also like the main chat): a prediction past the window still warns with no reported base (flagged as an estimate) or with compaction off, on the same asymmetry — a false warning self-corrects on the next report while a silent truncation is neither, and a run on a provider that reports no usage would otherwise go unwatched for its whole length.
func _maybe_compact(messages: Array, system_prompt: String) -> void:
	var window := GDLLMContexts.window_for(_qualified_source)
	var debug_window := GDLLMSettings.get_compaction_debug_override()
	if debug_window > 0:
		window = debug_window
	# No window to judge against — neither the pass nor the guard can fire, exactly like the main chat's trigger.
	if window <= 0:
		return
	var chars := 0
	for i in range(_delta_from, messages.size()):
		chars += String(messages[i].get("content", "")).length()
		if messages[i].get("tool_calls") is Array:
			chars += JSON.stringify(messages[i]["tool_calls"]).length()
		# A run IS one trailing tool loop after its task message, so every stored provider echo block re-rides every continuation — unlike the main chat, where only the newest loop's blocks do. Omitting them under-predicts, the one direction that ends in a silently truncated request.
		if messages[i].get("assistant_blocks") is Array:
			chars += JSON.stringify(messages[i]["assistant_blocks"]).length()
	# No reported base to arm the pass with — _delta_from sits at 0, so the estimate spans the whole run and must cover the system prompt too (a reported base already counted it) — but the window is still guarded: a false warning is cheap and self-correcting, and a provider that reports no usage stays here for the entire run.
	if _reported_base <= 0:
		_note_over_window(LLMClient.estimate_tokens(chars + system_prompt.length()), window, true)
		return
	var estimated := LLMClient.estimate_tokens(chars)
	var predicted := _reported_base + estimated
	# Compaction switched off (master or within-subagents) still guards the window; warning is the only honest move left, as with the main chat's master switch off.
	if not GDLLMSettings.is_auto_compaction_enabled() or not GDLLMSettings.is_subagent_compaction_enabled():
		_note_over_window(predicted, window, false)
		return
	if predicted + GDLLMSettings.get_compaction_buffer_tokens() < window:
		_over_window_noted = false
		return
	var saved := _prune_loop_results(messages, predicted)
	_note_over_window(predicted - saved, window, false)


## The subagent counterpart of the main chat's over-window warning (see GDLLMChatSession._maybe_warn_over_window): the coming request is predicted past the model's window and no available pass got it back under, so the provider would reject it or silently truncate its oldest part — disclosed as a red activity note, the run's only honest move left. Fires once per overflow (_over_window_noted), re-arming as soon as a prediction lands back under. `estimate_only` marks a prediction with no reported base behind it, named as an estimate rather than quoted like a measurement.
func _note_over_window(predicted: int, window: int, estimate_only: bool) -> void:
	if predicted < window:
		_over_window_noted = false
		return
	if _over_window_noted:
		return
	_over_window_noted = true
	var compaction_on := GDLLMSettings.is_auto_compaction_enabled() and GDLLMSettings.is_subagent_compaction_enabled()
	var advice := _over_window_advice(estimate_only, compaction_on)
	_emit({"type": "redirect", "text": "⚠ This run's next request is predicted at ~%s tokens, past its model's %s-token context window%s" % [String.num_int64(predicted), String.num_int64(window), advice]})


## The tail of the over-window warning, resolved from why the guard fired: an estimate with no reported base behind it, compaction switched off (the lever to pull), or a genuine overflow the pruning pass couldn't clear. Static and settings-free so the message ladder is testable headless, mirroring GDLLMChatSession._over_window_advice.
static func _over_window_advice(estimate_only: bool, compaction_on: bool) -> String:
	if estimate_only:
		return " — a chars/4 estimate, since no request in this run has reported usage yet; the provider may reject it or silently truncate its oldest part."
	if not compaction_on:
		return " with compaction disabled — enable Automatic Context Compaction and Compaction Within Subagents (Editor Settings → Gdllm → Compaction), or the provider may reject it or silently truncate its oldest part."
	return " even after compaction — the provider may reject it or silently truncate its oldest part."


## Pruning inside the loop's messages, under the same user settings and eligibility as the main chat's pass (see GDLLMChatSession._prune_tool_results); the swap writes the messages array directly, since the loop's transcript is working state rather than stored history — the activity feed above keeps every full output. A skip or refusal is disclosed once per run rather than re-posted on every continuation. Returns the tokens reclaimed.
func _prune_loop_results(messages: Array, predicted: int) -> int:
	var threshold := GDLLMSettings.get_prune_threshold_tokens()
	if predicted < threshold:
		_note_compaction_refusal("Compaction skipped: this run's predicted ~%s-token context is under the %s-token pruning threshold (Editor Settings → Gdllm → Compaction)." % [String.num_int64(predicted), String.num_int64(threshold)])
		return 0
	var candidates := prune_candidates(messages)
	var chosen: Array = candidates["indices"]
	var saved := int(candidates["saved"])
	var min_recovery := GDLLMSettings.get_prune_min_recovery_tokens()
	if chosen.is_empty() or saved < min_recovery:
		if chosen.is_empty():
			_note_compaction_refusal("Compaction found no tool results left to prune — errored results, tool_search, and the newest %d call/result pairs are exempt." % GDLLMTools.PRUNE_KEEP_RECENT_PAIRS)
		else:
			_note_compaction_refusal("Compaction could reclaim only ~%s tokens, under the %s-token minimum recovery (Editor Settings → Gdllm → Compaction), so nothing was pruned." % [String.num_int64(saved), String.num_int64(min_recovery)])
		return 0
	for i in chosen:
		messages[i]["content"] = GDLLMTools.PRUNED_RESULT_STAMP
	_compact_refusal_noted = false
	_emit({"type": "compaction", "text": "⚡ Compacted this run's context: %d old tool result%s (~%s tokens) now ride as short prune markers in its later requests; the full outputs above are unchanged." % [chosen.size(), "" if chosen.size() == 1 else "s", String.num_int64(saved)]})
	return saved


## The loop-message indices a prune would clear, oldest first, plus the tokens clearing them reclaims, as {indices, saved} — the same eligibility the main chat's pass applies: guarded tools, errored results, already-pruned entries, the newest PRUNE_KEEP_RECENT_PAIRS pairs, and results not longer than the stamp are all exempt. Static and settings-free so the policy is testable headless.
static func prune_candidates(messages: Array) -> Dictionary:
	var tool_indices: Array[int] = []
	for i in messages.size():
		if messages[i] is Dictionary and String(messages[i].get("role", "")) == "tool":
			tool_indices.append(i)
	tool_indices.resize(maxi(0, tool_indices.size() - GDLLMTools.PRUNE_KEEP_RECENT_PAIRS))
	var stamp_tokens := LLMClient.estimate_tokens(GDLLMTools.PRUNED_RESULT_STAMP.length())
	var chosen: Array[int] = []
	var saved := 0
	for i in tool_indices:
		var content := String(messages[i].get("content", ""))
		if GDLLMTools.PRUNE_GUARDED_TOOLS.has(String(messages[i].get("tool_name", ""))) or content == GDLLMTools.PRUNED_RESULT_STAMP or content.begins_with("Error:"):
			continue
		var gain := LLMClient.estimate_tokens(content.length()) - stamp_tokens
		if gain <= 0:
			continue
		chosen.append(i)
		saved += gain
	return {"indices": chosen, "saved": saved}


## Disclose a prune skip or refusal as an orange activity note, once per run — the trigger re-evaluates before every continuation, and re-posting an unchanged reason each round would drown the feed; a committed prune re-arms it, since the next refusal would be new information.
func _note_compaction_refusal(text: String) -> void:
	if _compact_refusal_noted:
		return
	_compact_refusal_noted = true
	_emit({"type": "compaction", "text": "⚡ " + text})


## The tools attached to a subagent's request: always tool_search, plus every tool it has activated by searching — the same narrow-context footprint AND gate filter the main chat uses (see GDLLMChatSession._tools_for_active_set): a gated tool's schema is dead weight on a request whose every call to it would be refused.
func _build_tools(active_tools: Dictionary) -> Array:
	var tools: Array = [GDLLMTools.tool_search_schema(_allow_changes, _allow_delete, active_tools)]
	for tool_name in active_tools:
		if not _allow_changes and GDLLMTools.is_mutating(tool_name):
			continue
		if not _allow_delete and GDLLMTools.is_destructive(tool_name):
			continue
		var schema := GDLLMTools.schema_for(tool_name)
		if not schema.is_empty():
			tools.append(schema)
	return tools


## Append the run's tool-layer record to a tools-enabled final answer — engine truth the parent can diff against the subagent's own claims of what it changed, which transcripts show can be pure invention. Cancelled and errored returns pass through untouched, and tool-less transform runs never reach here.
func _with_ledger(text: String) -> String:
	if was_cancelled or text.begins_with("Error:"):
		return text
	if mutation_ledger.is_empty():
		return text + "\n\n[Tool-layer record: this subagent changed no files or nodes.]"
	return text + "\n\n[Tool-layer record — files/nodes this subagent actually changed (its own account above may differ): %s]" % "; ".join(mutation_ledger)


## Collapse a terminal request outcome into the run's return string: the reply text (a cut-short one carrying its truncation note), any preamble text that rode alongside tool calls, an "Error: …" line, or "" when cancelled.
func _final_text(outcome: Dictionary) -> String:
	match String(outcome.get("kind", "")):
		"text":
			return String(outcome.get("text", "")) + _truncation_note(outcome)
		"tools":
			return String(outcome.get("content", ""))
		"error":
			return _failure_text(String(outcome.get("reason", "")))
		_:
			return ""


## The disclosure appended to a reply the provider or transport cut short (see LLMClient's `truncated` stat), so a partial answer — or a transform run's half-finished file map — is never handed to the parent as whole; unlike the display-only stamp the main chat uses, this rides the result itself, because the result IS what the parent model consumes.
static func _truncation_note(outcome: Dictionary) -> String:
	var stats: Dictionary = outcome.get("stats", {})
	if not bool(stats.get("truncated", false)):
		return ""
	var stop := String(stats.get("stop_reason", ""))
	if stop == "length":
		return "\n\n[Note: this reply hit the model's output-token limit and was cut off — treat it as incomplete.]"
	if stop != "":
		return "\n\n[Note: the provider ended this reply early (stop reason \"%s\") — treat it as incomplete.]" % stop
	return "\n\n[Note: the connection dropped before this reply finished — treat it as incomplete.]"


## A failed run's report to the parent model: the cause plus the decision it now faces — a cause alone leaves the parent knowing what broke but not whether to retry, take over, or surface it.
static func _failure_text(reason: String) -> String:
	return "Error: the subagent could not complete its task: %s [Next step: retry the subagent once if the cause reads as transient (timeout, dropped connection); otherwise do the task yourself with your own tools, or tell the user what is blocking it.]" % reason


func _on_response(text: String, stats: Dictionary) -> void:
	_resolve({"kind": "text", "text": text, "stats": stats})


func _on_tool_calls(tool_calls: Array, content: String, stats: Dictionary) -> void:
	# The client's raw echo blocks (Anthropic tool loops) ride the outcome so run() can attach them to the assistant echo it appends.
	_resolve({"kind": "tools", "tool_calls": tool_calls, "content": content, "stats": stats, "assistant_blocks": _client.last_assistant_blocks.duplicate(true)})


func _on_failed(reason: String) -> void:
	_resolve({"kind": "error", "reason": reason})


## Resolve the in-flight request's await with `outcome`, but only once — the first of reply/tools/error/cancel to arrive wins and the rest are ignored.
func _resolve(outcome: Dictionary) -> void:
	if _done:
		return
	_done = true
	request_finished.emit(outcome)


func _on_thinking_delta(chunk: String) -> void:
	# The request's first reasoning byte flips the live status row to the thinking phase.
	if _turn_thinking == "" and chunk != "":
		_emit({"type": "phase", "phase": "thinking"})
	_turn_thinking += chunk


## The model switched from reasoning to writing its answer; surfaced so the status row can flip to the generating phase, exactly as the main chat's placeholder does.
func _on_generating_started() -> void:
	_emit({"type": "phase", "phase": "generating"})


## Emit `event` as this subagent's activity, stamped with its nesting depth so the chat can indent it. A nested subagent's events arrive already stamped and are forwarded unchanged (see _forward_activity).
func _emit(event: Dictionary) -> void:
	event["depth"] = _depth
	activity.emit(event)


## Emit the reasoning accumulated for the just-finished request as a `thinking` event, if any, so nothing the subagent reasoned through stays hidden.
func _emit_thinking() -> void:
	if _turn_thinking.strip_edges() != "":
		_emit({"type": "thinking", "text": _turn_thinking})


## Surface one request's usage as a `stats` activity event — the subagent counterpart of the main chat's per-message footer, carrying the client's estimates and any provider-reported counts alike. Skipped only when neither kind of count exists: a model-only footer on every inner turn would be clutter, not data.
func _emit_stats(outcome: Dictionary) -> void:
	var stats: Dictionary = outcome.get("stats", {})
	var any_count := false
	for key in ["tokens_in", "tokens_out", "est_tokens_in", "est_tokens_out"]:
		if int(stats.get(key, 0)) > 0:
			any_count = true
	if not any_count:
		return
	_emit({"type": "stats", "stats": stats, "seconds": float(outcome.get("seconds", 0.0)), "model": _qualified_source})


## Re-emit a nested subagent's activity as our own so it bubbles up to the chat; the event keeps its own deeper depth for indentation.
func _forward_activity(event: Dictionary) -> void:
	activity.emit(event)
