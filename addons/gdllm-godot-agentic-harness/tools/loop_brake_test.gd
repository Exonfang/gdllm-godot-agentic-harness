extends SceneTree
## Headless regression tests for the shared tool-loop brakes (GDLLMLoopBrakes, carried by the main chat per turn and by every subagent per run): the duplicate-call note (identical call returning an identical result), the mutation invalidation that keeps a post-edit re-check of the touched file from being withheld, the A→B→A→B oscillation nudge — which only fires when some round in the cycle also repeated a result, since a productive check→edit→check→edit repair loop must stay un-nudged — the edit-retry grant that serves one duplicate re-read in full after an edit_file old_string miss, the full serve every mutating tool's repeat gets behind its repeat note (a refusal's fix must not be buried, a second application must not be hidden), and the two run-stoppers: the withhold escalation and the consecutive-use streak guard — plus the record a tripped stopper leaves behind, the redirect notice the session appends when the guard fires rather than when the reflection answers.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/loop_brake_test.gd
## Exits nonzero on any failure. The brakes are pure state (RefCounted), so no UI is involved.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Brakes = preload("res://addons/gdllm-godot-agentic-harness/gdllm_loop_brakes.gd")
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const Session = preload("res://addons/gdllm-godot-agentic-harness/gdllm_chat_session.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_repetition_note()
	_test_mutation_invalidates_duplicates()
	_test_oscillation_needs_repeat_evidence()
	_test_oscillation_evidence_anywhere_in_window()
	_test_oscillation_pattern_gates()
	_test_edit_retry_recovery()
	_test_transient_retry_repeat()
	_test_transient_invitation_is_never_hand_written()
	_test_send_reset_clears_retry_grants()
	_test_process_result_and_escalation()
	_test_recovery_serve_via_process_result()
	_test_mutation_repeat_serves_in_full()
	_test_streak_guard()
	_test_redirect_record()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_repetition_note() -> void:
	var brakes := Brakes.new()
	_check(brakes._repetition_note("read_file", {"path": "a.gd"}, "content A") == "", "a first call gets no duplicate note")
	_check(brakes._repetition_note("read_file", {"path": "a.gd"}, "content A") != "", "an identical call returning the identical result is nudged")
	_check(brakes._repetition_note("read_file", {"path": "a.gd"}, "content B") == "", "a repeat whose result changed stays un-nudged")
	_check(brakes._repetition_note("read_file", {"path": "b.gd"}, "content A") == "", "different arguments are a different call")
	_check(brakes._repetition_note("", {}, "x") == "", "a malformed empty-name call is exempt")
	# The note replaces the duplicate's body at the call site, so its text must stand alone as the whole result.
	_check(Tools.DUPLICATE_CALL_NUDGE.begins_with("Result withheld"), "the duplicate note reads as a stand-in body, not an appendix")
	# Ignored withholds escalate into the redirect at a small threshold; the instruction formats the repeat count in.
	_check(GDLLMTunables.geti(GDLLMTunables.WITHHELD_ESCALATION_THRESHOLD) >= 2, "the withhold escalation threshold leaves room for honest re-reads")
	_check((Tools.DUPLICATE_ESCALATION_MESSAGE % 7).contains("7 times"), "the escalation instruction carries the repeat count")


## Each simulated call runs _repetition_note then _invalidate_touched_duplicates, mirroring process_result's order.
func _test_mutation_invalidates_duplicates() -> void:
	var brakes := Brakes.new()
	var clean := "res://ui/boon_control.gd parses and compiles cleanly."
	var edited := "Edited res://ui/boon_control.gd — replaced 1 occurrence — parses cleanly (engine-checked)."
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, clean) == "", "a first check records silently")
	brakes._repetition_note("edit_file", {"path": "res://ui/boon_control.gd"}, edited)
	brakes._invalidate_touched_duplicates("edit_file", {"path": "res://ui/boon_control.gd"}, edited)
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, clean) == "", "a re-check after an edit touched the file serves in full")
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, clean) != "", "a re-check nothing touched since is withheld as before")
	var miss := "Error: old_string was not found in res://ui/boon_control.gd."
	brakes._repetition_note("edit_file", {"path": "res://ui/boon_control.gd"}, miss)
	brakes._invalidate_touched_duplicates("edit_file", {"path": "res://ui/boon_control.gd"}, miss)
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, clean) != "", "a failed edit changed nothing and clears nothing")
	brakes._invalidate_touched_duplicates("edit_file", {"path": "res://ui/other.gd"}, "Edited res://ui/other.gd — replaced 1 occurrence.")
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, clean) != "", "a mutation on another file clears nothing here")
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, "1 parse/compile error(s) in res://ui/boon_control.gd") == "", "a changed check result stays un-nudged, as before")
	# The ledger keys on lowercased basename, so the mutation's spelling needn't match the check's.
	brakes._repetition_note("edit_file", {"file": "Boon_Control.gd"}, edited)
	brakes._invalidate_touched_duplicates("edit_file", {"file": "Boon_Control.gd"}, edited)
	_check(brakes._repetition_note("check_script", {"path": "res://ui/boon_control.gd"}, clean) == "", "a bare-name synonym-key edit clears the same file's entries")
	# The mutation keeps its own entry, so re-running the identical mutation is still detected (process_result then serves it in full behind the repeat note).
	var wrote := "Overwrote res://ui/boon_control.gd (10 lines, 200 characters)."
	brakes._repetition_note("write_file", {"path": "res://ui/boon_control.gd", "content": "x"}, wrote)
	brakes._invalidate_touched_duplicates("write_file", {"path": "res://ui/boon_control.gd", "content": "x"}, wrote)
	_check(brakes._repetition_note("write_file", {"path": "res://ui/boon_control.gd", "content": "x"}, wrote) != "", "an identical re-run of the same successful write is still detected")
	# A mutating call that names no file (a settings write) has nothing to clear and must not misfire.
	brakes._invalidate_touched_duplicates("set_project_setting", {"setting": "application/config/name", "value": "X"}, "Set application/config/name.")
	_check(brakes._repetition_note("write_file", {"path": "res://ui/boon_control.gd", "content": "x"}, wrote) != "", "a pathless mutation leaves the ledger alone")
	brakes.reset()
	_check(brakes._call_paths.is_empty(), "the reset clears the path ledger too")


func _test_oscillation_needs_repeat_evidence() -> void:
	var brakes := Brakes.new()
	_check(brakes.oscillation_nudge({"check_script": true}, false) == "", "one round can't cycle")
	_check(brakes.oscillation_nudge({"edit_file": true}, false) == "", "two rounds can't cycle")
	_check(brakes.oscillation_nudge({"check_script": true}, false) == "", "three rounds can't cycle")
	_check(brakes.oscillation_nudge({"edit_file": true}, false) == "", "a progressing check→edit→check→edit repair loop stays un-nudged")
	# The alternation keeps sliding, so the round a repeat finally appears still completes a window and fires.
	var fired: String = brakes.oscillation_nudge({"check_script": true}, true)
	_check(fired.contains("alternated") and fired.contains("edit_file") and fired.contains("check_script"), "the same cycle fires once repeat evidence appears")
	_check(brakes.oscillation_nudge({"edit_file": true}, true) == "", "firing cleared the window, so the next round starts fresh")


func _test_oscillation_evidence_anywhere_in_window() -> void:
	var brakes := Brakes.new()
	_check(brakes.oscillation_nudge({"read_file": true}, true) == "", "an early repeat alone doesn't fire")
	_check(brakes.oscillation_nudge({"search_files": true}, false) == "", "window still filling")
	_check(brakes.oscillation_nudge({"read_file": true}, false) == "", "window still filling")
	var fired: String = brakes.oscillation_nudge({"search_files": true}, false)
	_check(fired.contains("read_file") and fired.contains("search_files"), "repeat evidence anywhere in the window fires the completed cycle")


func _test_oscillation_pattern_gates() -> void:
	var brakes := Brakes.new()
	for i in 6:
		_check(brakes.oscillation_nudge({"check_script": true}, true) == "", "a same-tool streak is the streak guard's job, not the oscillator's (round %d)" % (i + 1))
	brakes = Brakes.new()
	_check(brakes.oscillation_nudge({"read_file": true}, true) == "", "window filling")
	_check(brakes.oscillation_nudge({"edit_file": true}, true) == "", "window filling")
	_check(brakes.oscillation_nudge({"read_file": true, "edit_file": true}, true) == "", "a mixed round enters the window as a pattern breaker")
	_check(brakes.oscillation_nudge({"edit_file": true}, true) == "", "the mixed round broke the alternation even with repeats everywhere")


func _test_edit_retry_recovery() -> void:
	var brakes := Brakes.new()
	var miss := "Error: old_string was not found in res://ui/boon_control.gd. The match is exact — every character must line up."
	brakes._note_edit_not_found("edit_file", {"path": "res://ui/boon_control.gd"}, "Edited res://ui/boon_control.gd (1 replacement).")
	brakes._note_edit_not_found("check_script", {"path": "res://ui/boon_control.gd"}, miss)
	_check(not brakes._duplicate_serves_recovery("read_file", {"path": "res://ui/boon_control.gd"}), "a successful edit or another tool's error opens no grant")
	brakes._note_edit_not_found("edit_file", {"path": "res://ui/boon_control.gd"}, miss)
	_check(not brakes._duplicate_serves_recovery("edit_file", {"path": "res://ui/boon_control.gd"}), "a non-read tool never spends the grant")
	_check(not brakes._duplicate_serves_recovery("read_file", {"path": "res://ui/other.gd"}), "an unrelated path leaves the grant alone")
	_check(brakes._duplicate_serves_recovery("read_file", {"path": "res://ui/boon_control.gd"}), "a full-path re-read of the failed file is served")
	_check(not brakes._duplicate_serves_recovery("read_file", {"path": "res://ui/boon_control.gd"}), "the grant is spent after its one free serve")
	# The ledger keys on lowercased basename, so a bare-name or synonym-key spelling still matches the recorded path.
	brakes._note_edit_not_found("edit_file", {"file": "Boon_Control.gd"}, miss)
	_check(brakes._duplicate_serves_recovery("read_function", {"path": "boon_control.gd"}), "a bare-name read_function spends the same grant")
	brakes._note_edit_not_found("edit_file", {"path": "res://ui/boon_control.gd"}, miss)
	_check(brakes._duplicate_serves_recovery("search_files", {"file": "boon_control.gd"}), "search_files scoped to the failed file is served too")
	# The served body carries the tying note, not the withhold stub, so the model knows why the duplicate came back in full.
	_check(Brakes.EDIT_RETRY_SERVE_NOTE.contains("served in full"), "the recovery note explains the full serve")


## A retry the harness ITSELF invited must not come back accused of pointless repetition — the two-harness-messages-collide dead end (transcript-measured 2026-07-18, when check_script's "try again in a moment" met "Repeating the call cannot help").
func _test_transient_retry_repeat() -> void:
	var brakes := Brakes.new()
	var transient := "Error: the editor's documentation cache doesn't exist yet. %s" % Tools.TRANSIENT_RETRY_INVITATION
	var plain := "Error: the docs have no page named \"Sprit2D\"."
	_check(brakes._repetition_note("describe_docs", {"class": "Node"}, transient) == "", "a first transient failure is recorded, not nudged")
	_check(brakes._repetition_note("describe_docs", {"class": "Node"}, transient) == Tools.TRANSIENT_REPEAT_NUDGE, "the invited retry is answered in the invitation's own terms")
	_check(brakes._repetition_note("describe_docs", {"class": "Area2D"}, plain) == "", "a first ordinary failure is recorded, not nudged")
	_check(brakes._repetition_note("describe_docs", {"class": "Area2D"}, plain) == Tools.DUPLICATE_CALL_NUDGE, "an uninvited repeat still gets the ordinary duplicate nudge — the brake did not go soft on every error")
	# Detection stays wholesale even for errors: a model re-running a failing mutation is still counted and noted (process_result re-serves the refusal behind the repeat note instead of the stub).
	var miss := "Error: old_string was not found in res://a.gd."
	brakes._repetition_note("edit_file", {"path": "res://a.gd"}, miss)
	_check(brakes._repetition_note("edit_file", {"path": "res://a.gd"}, miss) == Tools.DUPLICATE_CALL_NUDGE, "a repeated failing edit is still detected")
	# Both nudges replace the body outright, so each must stand alone as a whole result.
	_check(Tools.TRANSIENT_REPEAT_NUDGE.begins_with("Result withheld"), "the transient nudge reads as a stand-in body, not an appendix")
	_check(not Tools.TRANSIENT_REPEAT_NUDGE.contains("cannot help"), "the transient nudge never tells the model that obeying the invitation was pointless")
	brakes = Brakes.new()
	brakes.process_result("describe_docs", {"class": "Node"}, transient)
	var repeat: Dictionary = brakes.process_result("describe_docs", {"class": "Node"}, transient)
	_check(String(repeat["content"]) == Tools.TRANSIENT_REPEAT_NUDGE, "process_result withholds the identical transient body")
	_check(bool(repeat["repeated"]), "a withheld transient repeat is still the oscillation guard's repeat evidence")
	_check(brakes._withheld_count == 1, "an invited retry still counts toward the escalation, so a genuine retry loop is braked")


## The invitation is a contract with the duplicate brake, not prose: a tool that hand-writes its own retry advice would earn the accusing nudge again, so the phrasing may only reach a result through the shared constant.
func _test_transient_invitation_is_never_hand_written() -> void:
	_check(Tools.TRANSIENT_RETRY_INVITATION.length() > 20, "the invitation is distinctive enough to match on")
	for path in ["res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd", "res://addons/gdllm-godot-agentic-harness/gdllm_docs.gd", "res://addons/gdllm-godot-agentic-harness/gdllm_project.gd"]:
		var source := FileAccess.get_file_as_string(path)
		_check(source != "", "%s is readable" % path)
		_check(_hand_written_retry_lines(source).is_empty(), "%s invites retries only through TRANSIENT_RETRY_INVITATION, not hand-written prose (offending lines: %s)" % [path.get_file(), ", ".join(_hand_written_retry_lines(source))])


## The 1-based line numbers of a source's model-facing strings that tell the model to try a call again in their own words; comment lines are prose about the code, not results the brake will ever see.
func _hand_written_retry_lines(source: String) -> PackedStringArray:
	var offenders := PackedStringArray()
	var lines := source.split("\n")
	for i in lines.size():
		var stripped := String(lines[i]).strip_edges()
		if stripped.begins_with("#"):
			continue
		if stripped.to_lower().contains("try again"):
			offenders.append(str(i + 1))
	return offenders


func _test_send_reset_clears_retry_grants() -> void:
	var brakes := Brakes.new()
	brakes._note_edit_not_found("edit_file", {"path": "res://a.gd"}, "Error: old_string was not found in res://a.gd.")
	brakes.reset()
	_check(not brakes._duplicate_serves_recovery("read_file", {"path": "res://a.gd"}), "the reset clears the retry grants")


## The composed entry point both loops call per immediate result, and the escalation the subagent ends its run on.
func _test_process_result_and_escalation() -> void:
	var brakes := Brakes.new()
	var first: Dictionary = brakes.process_result("read_file", {"path": "a.gd"}, "content A")
	_check(String(first["content"]) == "content A" and not bool(first["repeated"]), "a first call serves untouched")
	var repeat: Dictionary = brakes.process_result("read_file", {"path": "a.gd"}, "content A")
	_check(String(repeat["content"]) == Tools.DUPLICATE_CALL_NUDGE and bool(repeat["repeated"]), "an identical re-run is withheld behind the nudge as the whole body")
	_check(brakes.take_escalation() == 0, "one withhold stays below the escalation threshold")
	for i in GDLLMTunables.geti(GDLLMTunables.WITHHELD_ESCALATION_THRESHOLD):
		brakes.process_result("read_file", {"path": "a.gd"}, "content A")
	_check(brakes.take_escalation() >= GDLLMTunables.geti(GDLLMTunables.WITHHELD_ESCALATION_THRESHOLD), "ignored stubs pile up into the escalation")
	_check(brakes.take_escalation() == 0, "taking the escalation resets its window")


func _test_recovery_serve_via_process_result() -> void:
	var brakes := Brakes.new()
	brakes.process_result("read_file", {"path": "res://a.gd"}, "body")
	brakes.process_result("edit_file", {"path": "res://a.gd", "old_string": "x", "new_string": "y"}, "Error: old_string was not found in res://a.gd.")
	var served: Dictionary = brakes.process_result("read_file", {"path": "res://a.gd"}, "body")
	_check(String(served["content"]) == "body" + Brakes.EDIT_RETRY_SERVE_NOTE, "the granted re-read serves in full behind the recovery note")
	_check(bool(served["repeated"]), "a served recovery still counts as the oscillation guard's repeat evidence")
	_check(brakes._withheld_count == 0, "a served recovery never counts toward the escalation")


## A mutating tool's repeat serves its real body, never the stub — transcript-verified 2026-07-19 in two shapes: a retried refused edit whose stub buried the refusal's closest-region fix, and a re-run whitespace-tolerant edit whose stub hid that it had applied against disk again.
func _test_mutation_repeat_serves_in_full() -> void:
	var brakes := Brakes.new()
	var miss := "Error: old_string was not found in res://a.gd. Closest on-disk region (line 254) — copy your old_string from THIS text: x"
	var edit_args := {"path": "res://a.gd", "old_string": "x", "new_string": "y"}
	brakes.process_result("edit_file", edit_args, miss)
	var retried: Dictionary = brakes.process_result("edit_file", edit_args, miss)
	_check(String(retried["content"]) == miss + Brakes.MUTATION_REPEAT_FAILURE_NOTE, "an identical refused edit re-serves the refusal behind the failure note")
	_check(bool(retried["repeated"]), "the re-served refusal is still the oscillation guard's repeat evidence")
	_check(brakes._withheld_count == 1, "the re-served refusal still counts toward the escalation")
	var applied := "Edited res://b.gd — replaced 1 occurrence (whitespace-tolerant match)."
	var apply_args := {"path": "res://b.gd", "old_string": "p", "new_string": "q"}
	brakes.process_result("edit_file", apply_args, applied)
	var reran: Dictionary = brakes.process_result("edit_file", apply_args, applied)
	_check(String(reran["content"]) == applied + Brakes.MUTATION_REPEAT_SUCCESS_NOTE, "an identical re-applied edit serves its real result behind the double-application note")
	# A mutating failure that invited its own retry keeps the transient stub — the invitation contract outranks the mutation serve.
	var revert := "Error: the write could NOT be kept on disk. %s" % Tools.TRANSIENT_RETRY_INVITATION
	var write_args := {"path": "res://c.gd", "content": "z"}
	brakes.process_result("write_file", write_args, revert)
	var invited: Dictionary = brakes.process_result("write_file", write_args, revert)
	_check(String(invited["content"]) == Tools.TRANSIENT_REPEAT_NUDGE, "an invited mutating retry still answers in the invitation's own terms")
	# A read tool's repeat keeps the plain stub (an ungranted path, so the edit-retry grant can't serve it), so the mutation serve widened nothing else.
	brakes.process_result("read_file", {"path": "res://d.gd"}, "body")
	var read_repeat: Dictionary = brakes.process_result("read_file", {"path": "res://d.gd"}, "body")
	_check(String(read_repeat["content"]) != "body" and String(read_repeat["content"]).begins_with("Result withheld"), "a non-mutating repeat is withheld as before")
	# Both notes ride a served body, so they must read as appendices, never claim withholding.
	_check(Brakes.MUTATION_REPEAT_FAILURE_NOTE.begins_with("\n\n") and Brakes.MUTATION_REPEAT_SUCCESS_NOTE.begins_with("\n\n"), "the repeat notes read as appendices to a served body")
	_check(not Brakes.MUTATION_REPEAT_FAILURE_NOTE.contains("withheld") and not Brakes.MUTATION_REPEAT_SUCCESS_NOTE.contains("withheld"), "the repeat notes never claim the body was withheld")
	# Piling noted repeats still stop the run: the escalation is the backstop the serve must not weaken.
	brakes = Brakes.new()
	brakes.process_result("edit_file", edit_args, miss)
	for i in GDLLMTunables.geti(GDLLMTunables.WITHHELD_ESCALATION_THRESHOLD):
		brakes.process_result("edit_file", edit_args, miss)
	_check(brakes.take_escalation() >= GDLLMTunables.geti(GDLLMTunables.WITHHELD_ESCALATION_THRESHOLD), "ignored repeat notes still pile into the escalation")


func _test_streak_guard() -> void:
	var brakes := Brakes.new()
	var limit: int = Tools.max_consecutive_uses("tool_search")
	_check(limit >= 2, "tool_search declares a break point for the streak guard to trip on")
	for i in limit - 1:
		_check(brakes.track_consecutive_use({"tool_search": true}) == "", "a streak below the break point keeps running (round %d)" % (i + 1))
	_check(brakes.track_consecutive_use({"tool_search": true}) == "tool_search", "the streak trips at the tool's break point")
	brakes = Brakes.new()
	for i in limit - 1:
		brakes.track_consecutive_use({"tool_search": true})
	brakes.track_consecutive_use({"tool_search": true, "read_file": true})
	for i in limit - 1:
		_check(brakes.track_consecutive_use({"tool_search": true}) == "", "a mixed round broke the streak, so the count starts over (round %d)" % (i + 1))
	brakes = Brakes.new()
	for i in limit * 2:
		_check(brakes.track_consecutive_use({"read_file": true}) == "", "a tool without a break point never trips (round %d)" % (i + 1))
	brakes = Brakes.new()
	for i in limit * 2:
		_check(brakes.track_consecutive_use({"tool_search": true}, true) == "", "a fresh-attach search round never extends the streak (round %d)" % (i + 1))
	brakes = Brakes.new()
	for i in limit - 1:
		brakes.track_consecutive_use({"tool_search": true})
	brakes.track_consecutive_use({"tool_search": true}, true)
	for i in limit - 1:
		_check(brakes.track_consecutive_use({"tool_search": true}) == "", "a fresh attach reset the streak, so the count starts over (round %d)" % (i + 1))
	_check(brakes.track_consecutive_use({"tool_search": true}) == "tool_search", "unproductive rounds after the reset still reach the break point")


## What a tripped guard leaves in the record. The redirect is the loudest thing the system does unasked, and its whole persisted form is the notice entry the session appends when the guard fires — before the reflection request exists, so a reflection that fails, is stopped, or never goes out still leaves the interrupt on the record.
func _test_redirect_record() -> void:
	var streak: PackedStringArray = Session._redirect_notice_texts("tool_search", "", "", false)
	_check("tool_search" in streak[0] and "tool_search" in streak[1], "the streak guard's default texts name the looping tool")
	_check(streak[0].ends_with(Session.REDIRECT_REFLECTION_CLAUSE), "a redirect whose request went out promises the summary below it")
	var abandoned: PackedStringArray = Session._redirect_notice_texts("tool_search", "", "", true)
	_check(abandoned[1] == streak[1], "an abandoned redirect keeps the same header — the guard fired either way")
	_check(abandoned[0].ends_with(Session.REDIRECT_ABANDONED_CLAUSE) and not (Session.REDIRECT_REFLECTION_CLAUSE in abandoned[0]), "an abandoned redirect promises no summary instead")
	# The escalation passes its own WHY; the outcome clause is appended at the one point it is known, so the two callers can never disagree about it.
	var escalated: PackedStringArray = Session._redirect_notice_texts("", "It re-ran identical calls.", "⚠ Interrupted repetitive tool loop", false)
	_check(escalated[0] == "It re-ran identical calls." + Session.REDIRECT_REFLECTION_CLAUSE, "an overriding caller supplies the WHY and inherits the outcome clause")
	var s: Variant = Session.new()
	s._history.assign([
		{"role": "user", "content": "go"},
		{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "tool_search", "arguments": {}}}]},
		{"role": "tool", "tool_name": "tool_search", "content": "hits"},
		{"role": "notice", "kind": "redirect", "reason": streak[0], "label": streak[1], "instruction": "Stop and summarize."},
		{"role": "assistant", "content": "I was looking for…", "redirected": true},
	])
	_check(s._redirect_instruction_before(4) == "Stop and summarize.", "the reflection instruction is recoverable from the notice, not the reply")
	_check(s._redirect_instruction_before(2) == "", "the walk stops at the first real message rather than reaching an earlier redirect")
	s._history.remove_at(4) # the reflection failed or was stopped: no reply ever landed
	_check(String(s._history[3].get("reason", "")) == streak[0], "the interrupt survives a redirect that produced no reply")
	s.free()
