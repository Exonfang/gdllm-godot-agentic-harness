extends SceneTree
## Headless regression tests for the compaction decisions that are pure enough to reach without a UI: the summarization split's turn-boundary walk in both its directions (GDLLMChatSession._summary_split_index), the history estimate a token target's overhead deduction is measured against, the remedy the over-window warning names (GDLLMChatSession._over_window_advice), and the model-downshift guard — the advice branch a swap to a smaller window earns, the standing row's wording, the condition it tracks (cleared by a swap back that fits, untouched while the window is unknown), and the attribution a reported base carries once the model that measured it is gone.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/summary_split_test.gd
## Exits nonzero on any failure. The session node is instantiated but never enters a tree, so no UI, model, or EditorSettings is touched.
##
## What these guard: the percentage default walks BACK to a turn boundary (its figure is a floor on what stays verbatim), while a token target walks FORWARD (its figure is a ceiling on the result) — the wild failure was one 20k-token assistant turn sitting on the boundary, which the backward walk dragged whole into the verbatim tail, landing a 64k target near 120k. The forward walk must still yield to the fit guard's head ceiling and fall back to the backward walk when the ceiling or the end of history blocks it, and a budget smaller than any message must compact maximally rather than refuse.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Session = preload("res://addons/gdllm-godot-agentic-harness/gdllm_chat_session.gd")
const LLM = preload("res://addons/gdllm-godot-agentic-harness/llm_client.gd")
const Contexts = preload("res://addons/gdllm-godot-agentic-harness/gdllm_contexts.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_percentage_walks_back()
	_test_target_walks_forward_past_fat_turn()
	_test_target_falls_back_at_end_of_history()
	_test_target_yields_to_head_ceiling()
	_test_tiny_budget_compacts_maximally()
	_test_head_must_hold_something()
	_test_percentage_dominant_last_message_still_skips()
	_test_history_estimate_tokens()
	_test_focused_summary_is_the_whole_context()
	_test_focused_bridge_admits_the_focus()
	_test_focused_prompt_carries_the_focus()
	_test_focused_fit_guard_keeps_the_smallest_tail()
	_test_over_window_advice()
	_test_stall_advice()
	_test_latches_rebuild_from_history()
	_test_prune_selection_policy()
	_test_downshift_advice()
	_test_downshift_notice_tracks_the_condition()
	_test_cross_model_base_is_labelled()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _u(n: int) -> Dictionary:
	return {"role": "user", "content": "x".repeat(n)}


func _a(n: int) -> Dictionary:
	return {"role": "assistant", "content": "x".repeat(n)}


func _ac(n: int) -> Dictionary:
	return {"role": "assistant", "content": "x".repeat(n), "tool_calls": [{"function": {"name": "t", "arguments": {}}}]}


func _t(n: int) -> Dictionary:
	return {"role": "tool", "content": "x".repeat(n)}


## A session node carrying `history`, never entering any tree — the split walk and the estimators only read _history, so nothing else needs to exist. Untyped so the test parses without the global class cache.
func _session(history: Array) -> Variant:
	var s: Variant = Session.new()
	s._history.assign(history)
	return s


## The wild shape: one user turn, then a tool loop whose third round carries a fat assistant turn on the split boundary.
func _fat_turn_history() -> Array:
	return [_u(1000), _ac(100), _t(1000), _ac(20000), _t(1000), _ac(100), _t(1000), _a(500)]


## Chars the verbatim tail from `split` carries — what a target budgets and what the wild failure blew out.
func _tail_chars(s: Variant, split: int) -> int:
	return int(s._request_span_chars(split, s._history.size(), s._history.size()))


func _test_percentage_walks_back() -> void:
	var s := _session(_fat_turn_history())
	# tail 20% puts the budget point on the tool result at index 4; the floor semantics keep MORE verbatim, so the walk goes back to the fat turn at 3.
	_check(s._summary_split_index(20) == 3, "percentage mode walks back to the boundary that grows the tail")
	s.free()


func _test_target_walks_forward_past_fat_turn() -> void:
	var s := _session(_fat_turn_history())
	# The same budget point, but a ~3000-char tail budget is a ceiling: walking back would drag the 20k-char turn into the tail, walking forward clears it.
	var split: int = s._summary_split_index(20, 3000)
	_check(split == 5, "a token target walks forward to the boundary that keeps the tail under budget")
	# The property the index only stands in for, and the regression itself: the old backward walk landed a tail ~7x the budget.
	_check(_tail_chars(s, split) <= 3000, "the target's tail lands at or under budget")
	_check(_tail_chars(s, s._summary_split_index(20)) > 3000 * 5, "the percentage walk on the same history blows that budget wide open")
	s.free()


func _test_target_falls_back_at_end_of_history() -> void:
	# Mid-loop shape: nothing but tool results after the budget point, so no forward boundary exists.
	var s := _session([_u(1000), _ac(100), _t(8000), _t(8000)])
	_check(s._summary_split_index(20, 9000) == 1, "a target with no boundary ahead falls back to the backward walk")
	s.free()


func _test_target_yields_to_head_ceiling() -> void:
	var s := _session([_u(1000), _ac(100), _t(3000), _t(2000), _ac(5000), _t(100), _a(500)])
	# The capped budget lands the candidate on the tool result at 3, and the forward boundary at 4 would need a head past the 5000-char ceiling, so the walk falls back past the tool results to 1.
	_check(s._summary_split_index(20, 600, 5000) == 1, "the forward walk yields to the fit guard's head ceiling and falls back")
	_check(s._summary_split_index(20, 600) == 6, "the same target without a ceiling walks forward under budget")
	s.free()


func _test_tiny_budget_compacts_maximally() -> void:
	var s := _session(_fat_turn_history())
	# A 4-char tail budget is smaller than any message: the old rule skipped outright, the target rule compacts to the last legal boundary instead.
	_check(s._summary_split_index(20, 4) == 7, "a budget smaller than any message compacts maximally rather than refusing")
	s.free()


func _test_head_must_hold_something() -> void:
	var s := _session([_u(1000)])
	_check(s._summary_split_index(20, 4) == -1, "a split leaving nothing to summarize is still refused under a target")
	s.free()


func _test_percentage_dominant_last_message_still_skips() -> void:
	# The budget loop exhausts without a candidate when the last message dominates; only a tail budget may then compact maximally, the percentage path keeps refusing.
	var s := _session([_u(100), _a(10000)])
	_check(s._summary_split_index(30) == -1, "percentage mode still refuses when the last message dominates the budget")
	s.free()


func _test_history_estimate_tokens() -> void:
	var s := _session([_u(1000), _a(500), {"role": "notice", "kind": "compaction"}, _u(100)])
	_check(s._history_estimate_tokens() == 400, "the history estimate counts model-visible content only, display records free")
	s.free()
	# With a committed summary, the estimate is its replacement message plus the span from its split — the same swap the request build applies.
	var summary := {"role": "notice", "kind": "summary", "split": 2, "summary": "the gist"}
	var anchored := _session([_u(1000), _a(500), _u(100), _a(60), summary])
	var expected: int = LLM.estimate_tokens(Session._summary_message_text(summary).length() + 160)
	_check(anchored._history_estimate_tokens() == expected, "an anchored history is measured as summary message plus post-split span")
	anchored.free()


## The focused compaction's defining promise: a summary whose split is the end of history leaves the model that one message and nothing else.
func _test_focused_summary_is_the_whole_context() -> void:
	var summary := {"role": "notice", "kind": "summary", "split": 4, "summary": "the gist", "focus": "the save system", "whole": true}
	var s := _session([_u(1000), _ac(100), _t(1000), _a(500), summary])
	var request: Array = s._history_for_request()
	_check(request.size() == 1, "a focused summary leaves exactly one message in the model's context")
	_check(String(request[0].get("role", "")) == "user" and "the gist" in String(request[0].get("content", "")), "that message is the summary, sent as a user message")
	# Everything appended after the commit still rides, or the session could never continue.
	s._history.append(_u(50))
	_check(int(s._history_for_request().size()) == 2, "messages appended after the focused summary still ride behind it")
	s.free()


func _test_focused_bridge_admits_the_focus() -> void:
	var text: String = Session._summary_message_text({"summary": "the gist", "focus": "the save system"})
	_check("the save system" in text, "the focused bridge names the focus the summary was written under")
	# The rail this guards: under the unfocused bridge a model reads a focus-weighted record as complete, so whatever the focus dropped looks like work that never happened.
	_check("condensed or dropped" in text, "the focused bridge tells the model the summary is deliberately partial")
	_check(not (Session.SUMMARY_BRIDGE in text), "a focused summary never rides the unfocused bridge")
	_check(Session.SUMMARY_BRIDGE in Session._summary_message_text({"summary": "the gist"}), "an ordinary summary's bridge is untouched")


func _test_focused_prompt_carries_the_focus() -> void:
	var s := _session([_u(10), _a(10)])
	var head: Array = s._summary_head(2)
	var plain: String = s._summary_prompt(head)
	var focused: String = s._summary_prompt(head, "the save system", true)
	_check("the save system" in focused and Session.SUMMARY_TEMPLATE in focused, "the focused request carries the focus and still carries the nine-section template")
	_check(not ("the save system" in plain), "an unfocused request is unchanged")
	_check("stays verbatim" in plain and not ("stays verbatim" in focused), "a whole-conversation request drops the framing that promises a verbatim tail")
	s.free()


## A focused run keeps no tail, so when its own request will not fit the model the fit guard resizes with a zero-char tail budget: the split must still land on a turn boundary, the head must clear the ceiling, and no later boundary may fit — anything else would keep more verbatim than the fit forced.
func _test_focused_fit_guard_keeps_the_smallest_tail() -> void:
	var s := _session(_fat_turn_history())
	var split: int = s._summary_split_index(20, 0, 3000)
	_check(split >= 0 and s._starts_a_turn(split), "the focused resize lands on a turn boundary")
	_check(int(s._summary_head_chars(split)) <= 3000, "the focused resize keeps the head under the fit ceiling")
	var later_fits := false
	for i in range(split + 1, s._history.size()):
		if s._starts_a_turn(i) and int(s._summary_head_chars(i)) <= 3000:
			later_fits = true
	_check(not later_fits, "no later boundary would have fit, so the tail left verbatim is the smallest the ceiling allows")
	s.free()


func _test_over_window_advice() -> void:
	# The regression this guards: a first request over the window used to be told to lower the pruning thresholds, advice that cannot work when there is no earlier conversation to prune.
	var alone: String = Session._over_window_advice(true, true, true)
	_check("Shorten the message" in alone, "a request carrying only the pending message is told to shorten it")
	_check(not ("threshold" in alone), "that advice never points at compaction settings no pass could act on")
	# Everywhere else the strongest disabled lever wins, master switch before summarization.
	_check("Automatic Context Compaction" in Session._over_window_advice(false, false, false), "the disabled master switch outranks the disabled summarization pass")
	_check("summarization pass" in Session._over_window_advice(false, true, false), "a disabled summarization pass is named when the master switch is on")
	_check("threshold" in Session._over_window_advice(false, true, true), "with everything enabled the remedy is a clean session or lower thresholds")
	# only_pending_message wins over every settings state, since no lever below it can reclaim anything.
	_check(Session._over_window_advice(true, false, false) == alone, "the nothing-to-reclaim case outranks the settings ladder")


## A stalled trigger must name the specific lever that unsticks it, and the over-window ladder must know a pass that is enabled yet breaker-suspended cannot be the remedy.
func _test_stall_advice() -> void:
	_check("Enable the summarization pass" in Session._stall_advice(false, false), "a disabled summarization pass is the stall's named lever")
	_check("re-arm" in Session._stall_advice(true, true), "a tripped breaker names the model switch that re-arms it")
	_check("focused compaction" in Session._stall_advice(true, false), "a conversation no split can act on is pointed at a clean session or a focused run")
	_check("re-arm" in Session._over_window_advice(false, true, true, 0, true), "the over-window advice names the suspended pass rather than thresholds it cannot use")
	_check("threshold" in Session._over_window_advice(false, true, true, 0, false), "an unsuspended pass keeps the thresholds advice")


## A reload must neither re-post a warning the record already carries nor resume events a stall paused — both latches rebuild from the persisted notices, newest decisive record winning.
func _test_latches_rebuild_from_history() -> void:
	# The cache is filled in memory rather than through store(), which would write the editor's real context cache from a test run.
	Contexts._loaded = true
	Contexts._windows = {"src::m": 128000}
	var warn := {"role": "notice", "kind": "over_window", "predicted": 200000, "window": 128000, "advice": ""}
	var stall := {"role": "notice", "kind": "compaction_stalled", "predicted": 200000, "window": 128000, "advice": ""}
	var committed := {"role": "notice", "kind": "compaction", "steps": [{"name": "p", "saved": 5000}]}
	var standing := _session([_u(100), warn, stall])
	_check(standing._derive_over_window_warned(), "a standing over-window warning keeps its latch set across a reload")
	_check(standing._derive_compaction_stalled(), "a standing stalled notice keeps the stall latch set across a reload")
	standing.free()
	var reclaimed := _session([_u(100), warn, stall, committed])
	_check(not reclaimed._derive_over_window_warned(), "a committed pass after the warning re-arms it")
	_check(not reclaimed._derive_compaction_stalled(), "and re-opens the trigger's events")
	reclaimed.free()
	# A report landing under the window is the recorded stand-in for the live latch's under-window re-arm.
	var under := _session([_u(100), warn, {"role": "assistant", "content": "", "stats": {"tokens_in": 60000, "tokens_out": 500}}])
	under._qualified_model = "src::m"
	_check(not under._derive_over_window_warned(), "a report landing under the window re-arms the warning")
	under.free()
	var still_over := _session([_u(100), {"role": "assistant", "content": "", "stats": {"tokens_in": 140000, "tokens_out": 500}}, warn])
	still_over._qualified_model = "src::m"
	_check(still_over._derive_over_window_warned(), "a warning newer than every report stays latched")
	still_over.free()
	Contexts._windows = {}


## The stall check asks _prune_selection what a prune would do without stamping anything, so it must share _prune_tool_results' exact eligibility.
func _test_prune_selection_policy() -> void:
	var summary := {"role": "notice", "kind": "summary", "split": 2, "summary": "gist"}
	var hist: Array = [_u(100), _t(4000), summary]
	for i in 5:
		hist.append(_t(4000))
	hist[3]["content"] = "Error: nope"
	var s := _session(hist)
	var sel: Dictionary = s._prune_selection(int(s._history.size()))
	# Of the five results past the split, the newest three are kept and the errored one is exempt, leaving one; the pre-split result is already out of the model's view.
	_check(Array(sel["indices"]).size() == 1 and Array(sel["indices"]).has(4), "eligibility matches the committing pass: past the split, older than the keep window, not errored")
	_check(int(sel["saved"]) > 0, "the selection reports the tokens a commit would reclaim")
	s.free()


## A downshift is its own cause — the conversation did not grow, the ceiling under it dropped — so its remedy is its own branch: compact now, or pick a model that actually holds this much.
func _test_downshift_advice() -> void:
	var switched: String = Session._over_window_advice(false, true, true, 320000)
	_check("at least ~320k tokens" in switched, "the downshift advice names the window a model would need")
	_check("Compact this conversation now" in switched, "and offers compacting in place as the other lever")
	# No setting changed, so no settings-ladder branch can be the right answer here.
	_check(Session._over_window_advice(true, false, false, 320000) == switched, "a model switch outranks both the settings ladder and the nothing-to-reclaim case")
	_check(not ("at least ~" in Session._over_window_advice(false, true, true)), "an ordinary overflow's advice is untouched by the new branch")


## The downshift row states a condition rather than recording an event, so it must come and go with the condition — and never enter history, where clearing it would mean rewriting history.
func _test_downshift_notice_tracks_the_condition() -> void:
	var text: String = Session._downshift_row_text("src::small", 320000, 40000, "src::big", "src::big", 336000)
	_check("src::small" in text and "switched from src::big" in text, "the row names the model that no longer fits and the one it was switched from")
	_check("at least ~336k tokens" in text, "and carries the switch branch's advice")
	_check("reported by src::big, before the switch" in text, "a base counted by the model just left is attributed, not quoted as the new one's own")
	_check(not ("switched from" in Session._downshift_row_text("src::small", 320000, 40000, "", "", 336000)), "a reload, with no swap to attribute, states the condition alone")
	# The cache is filled in memory rather than through store(), which would write the editor's real context cache from a test run.
	Contexts._loaded = true
	Contexts._windows = {"src::small": 40000, "src::big": 1000000}
	var reply := {"role": "assistant", "content": "x".repeat(100), "model": "src::big", "stats": {"tokens_in": 300000, "tokens_out": 500}}
	var s := _session([_u(100), reply])
	s._message_list = VBoxContainer.new()
	var row := Label.new()
	s._message_list.add_child(row)
	s._downshift_notice = row
	_check(s._history.size() == 2, "the row is never written to history — clearing it would otherwise mean rewriting history")
	# Swapping back to a model that holds the conversation must take the row down on the spot; that staleness was the reported bug.
	s._qualified_model = "src::big"
	s._refresh_downshift_notice()
	_check(not is_instance_valid(s._downshift_notice), "swapping back to a model that fits clears the row")
	# An unknown window can neither raise nor clear it: any comparison would be invented.
	var kept := Label.new()
	s._message_list.add_child(kept)
	s._downshift_notice = kept
	s._qualified_model = "src::unprobed"
	s._refresh_downshift_notice()
	_check(is_instance_valid(s._downshift_notice), "an unknown window leaves whatever is showing alone rather than guessing")
	s._message_list.free()
	s.free()
	Contexts._windows = {}


## A reported base that predates a model switch is still used — a neighbouring tokenizer beats chars-per-token — but every figure quoted from it says who measured it.
func _test_cross_model_base_is_labelled() -> void:
	var reply := {"role": "assistant", "content": "x".repeat(100), "model": "src::old", "stats": {"tokens_in": 40000, "tokens_out": 500}}
	var s := _session([_u(100), reply, _u(100)])
	s._qualified_model = "src::new"
	var prediction: Dictionary = s._predict_next_prompt()
	_check(String(prediction.get("base_model", "")) == "src::old", "a base counted by the model the session has left is named on the prediction")
	_check(String(Session._prediction_basis(prediction).get("measured_on", "")) == "src::old", "the notice carries that attribution")
	var entry := {}
	Session._note_cross_model_base(entry, prediction, "src::new")
	var note := String(entry.get("note", ""))
	_check("src::old" in note and "src::new" in note, "the compaction event says which model measured the base and which window it is judged against")
	s._qualified_model = "src::old"
	var same: Dictionary = s._predict_next_prompt()
	_check(not same.has("base_model"), "an ordinary same-model prediction carries no attribution")
	_check(Session._prediction_basis(same).is_empty(), "and adds nothing to its notice")
	var untouched := {}
	Session._note_cross_model_base(untouched, same, "src::old")
	_check(untouched.is_empty(), "and no note at all")
	s.free()
