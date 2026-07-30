@tool
class_name GDLLMLoopBrakes extends RefCounted
## The tool-loop brakes one agentic run carries — the main chat holds one per turn (reset on each user send) and every fresh-context subagent one per run, because the transcript evidence that motivated them (ignored stubs, ping-pong rounds, marathon streaks) applies to any model driving a tool loop. Three tiers, gentlest first: an exact re-run has its identical body withheld behind the duplicate nudge (process_result), rounds ping-ponging A→B→A→B with repeat evidence get the oscillation nudge appended (oscillation_nudge), and a runaway — withheld stubs piling up (take_escalation) or one tool looping past its break point (track_consecutive_use) — tells the owner to stop the loop and ask the model for a progress summary. The owner shapes the stop (the chat's red redirect turn, a subagent's interrupted answer); the brakes only keep the ledgers and name the moment.

const WITHHELD_ESCALATION_THRESHOLD: int = 4 ## Withheld-duplicate firings in one run past which the gentle stubs have provably failed and the owner should stop for a progress summary (see take_escalation) — transcript-observed 29 ignored stubs in one turn, six as immediate re-repeats.
## Stand-in for the withhold stub when a duplicate read serves an edit_file recovery (see _duplicate_serves_recovery); kept here rather than in GDLLMTools because re-serving the body is loop policy, not tool policy.
const EDIT_RETRY_SERVE_NOTE := "\n\nNote: this result is identical to your earlier read, but it is served in full because your edit_file old_string for this file was not found — copy the exact text (tabs included) from THIS result."
## Appended to a mutating tool's re-served identical refusal: a refusal names the exact fix, so withholding its repeat buries that fix behind a stub the moment the model most needs it (transcript-observed 2026-07-19: the stub hid a not-found refusal's closest-region quote from the very retry the refusal asked for).
const MUTATION_REPEAT_FAILURE_NOTE := "\n\nNote: this call is IDENTICAL to one this same refusal already answered earlier this turn — you re-sent the same arguments unchanged, so it failed the same way. The fix it names still stands and requires CHANGING the call; re-sending it unchanged again cannot end differently."
## Appended to a mutating tool's re-served identical success: the repeat ran against disk again, so its body is engine truth that must serve — an edit whose old text still matches post-edit can genuinely apply twice (transcript-observed 2026-07-19: a withheld re-run of a whitespace-tolerant edit hid that it had applied again).
const MUTATION_REPEAT_SUCCESS_NOTE := "\n\nNote: this call is identical to one that already reported success earlier this turn, and it RAN AGAIN — a re-run of an edit whose old text still matches can apply a second time. If you did not mean to run it twice, re-read the changed region and undo any doubled change."

## Consecutive-use loop guard, one active streak at a time: any round using a single distinct tool extends that tool's streak, while a round using none or two-plus distinct tools breaks it — so at most one tool is ever on a streak (see track_consecutive_use). When the streak reaches that tool's break point (GDLLMTools.max_consecutive_uses) the owner stops the loop.
var _streak_name: String = "" ## The tool used in consecutive single-tool rounds so far; "" when the last round broke the streak.
var _streak_count: int = 0 ## How many consecutive rounds _streak_name has been the sole tool used; compared against that tool's break point.
## Gentler braking for repetition the streak guard can't see, transcript-observed in weak models: rounds ping-ponging between two tools, and exact re-runs of an earlier call. An exact re-run has its identical body withheld — the nudge stands in for content the conversation already carries — while the oscillation nudge appends to its round's last result; the loop continues either way, the repetition named to the model and the user alike.
## Two exceptions serve in full instead: a duplicate re-read of a file edit_file just failed to match old_string in (once — that error itself tells the model to copy from a fresh read, see _duplicate_serves_recovery), and any mutating tool's repeat (its re-run hit disk again, and a refusal's body carries the fix the stub would bury — see process_result's mutation branch).
## A repeat of a failure carrying GDLLMTools.TRANSIENT_RETRY_INVITATION is still withheld but answered in the invitation's own terms, since the model repeated the call because the harness told it to (see _repetition_note).
var _round_tool_history: Array[String] = [] ## The sole tool name of each recent single-tool round ("" for a mixed round), the last four kept; A→B→A→B here plus repeat evidence fires the oscillation nudge and clears the window (see oscillation_nudge).
var _round_repeat_history: Array[bool] = [] ## Whether each of those rounds re-ran an identical call to an identical result, in lockstep with _round_tool_history — the no-progress evidence the oscillation nudge requires before calling an alternation a loop.
var _call_results: Dictionary = {} ## The run's completed immediate calls, "name|args" -> result content; an identical call returning identical content has its body withheld and replaced by the duplicate-call nudge (see _repetition_note), unless the duplicate serves an edit_file recovery (see _duplicate_serves_recovery). A successful mutation drops the touched file's other entries (see _invalidate_touched_duplicates).
var _call_paths: Dictionary = {} ## Each recorded call's lowercased file basename ("" for pathless calls), keyed like _call_results, so a mutation can drop a touched file's entries without re-parsing signatures (see _invalidate_touched_duplicates).
var _edit_retry_paths: Dictionary = {} ## Lowercased basenames of files whose edit_file old_string was not found this run (basename -> true); each grants one duplicate re-read served in full instead of withheld (see _note_edit_not_found and _duplicate_serves_recovery).
var _withheld_count: int = 0 ## Duplicate firings this run — withheld stubs plus re-served mutation repeats, which are the same ignored-warning evidence (see process_result); at WITHHELD_ESCALATION_THRESHOLD the owner should stop the loop (see take_escalation).


## Fold one immediate call's raw result through the duplicate brakes and return {"content": what to serve, "repeated": whether the call re-ran an identical earlier call to an identical result — the no-progress evidence oscillation_nudge takes}. A repeat's body is withheld: the identical content already sits at the earlier call, so the nudge stands in for it rather than re-serving it — unless the duplicate is the one re-read granted after an edit_file old_string miss, which serves in full behind EDIT_RETRY_SERVE_NOTE and never counts toward escalation (withholding it would pit the two harness messages against each other, a transcript-observed dead end), or the repeat is a mutating tool's, which serves in full behind a repeat note and still counts (the re-run hit disk again, so the stub would hide a refusal's fix or a real second application). Deferred-subagent calls must not pass through here — re-running a delegation is nondeterministic by design.
func process_result(tool_name: String, args: Dictionary, content: String) -> Dictionary:
	_note_edit_not_found(tool_name, args, content)
	var nudge := _repetition_note(tool_name, args, content)
	_invalidate_touched_duplicates(tool_name, args, content)
	if nudge == "":
		return {"content": content, "repeated": false}
	if _duplicate_serves_recovery(tool_name, args):
		return {"content": content + EDIT_RETRY_SERVE_NOTE, "repeated": true}
	_withheld_count += 1
	if GDLLMTools.is_mutating(tool_name) and nudge == GDLLMTools.DUPLICATE_CALL_NUDGE:
		# An invited transient retry keeps its own stub (_repetition_note answers it with TRANSIENT_REPEAT_NUDGE), so this branch covers only the uninvited mutation repeat.
		var note := MUTATION_REPEAT_FAILURE_NOTE if content.begins_with("Error") else MUTATION_REPEAT_SUCCESS_NOTE
		return {"content": content + note, "repeated": true}
	return {"content": nudge, "repeated": true}


## Fold this round's tool set into the alternation tracker and return the nudge to attach to the round's last result when the last four rounds ping-ponged A→B→A→B — a two-tool cycle the single-tool streak guard resets on. The name pattern alone doesn't fire: at least one round in the window must also have re-run an identical call to an identical result (`round_repeated`, from process_result's ledger), because a check→edit→check→edit repair loop alternates the same two tools while genuinely progressing — observed as a false positive the first day live. A pattern without evidence keeps sliding, so it still fires the round a repeat finally appears. Firing clears the window, so the nudge can only repeat after four fresh rounds of the same cycling.
func oscillation_nudge(used_tools: Dictionary, round_repeated: bool) -> String:
	_round_tool_history.append(String(used_tools.keys()[0]) if used_tools.size() == 1 else "")
	_round_repeat_history.append(round_repeated)
	if _round_tool_history.size() > 4:
		_round_tool_history.pop_front()
		_round_repeat_history.pop_front()
	if _round_tool_history.size() < 4:
		return ""
	var a := _round_tool_history[0]
	var b := _round_tool_history[1]
	if a == "" or b == "" or a == b or _round_tool_history[2] != a or _round_tool_history[3] != b:
		return ""
	if not _round_repeat_history.has(true):
		return ""
	_round_tool_history.clear()
	_round_repeat_history.clear()
	return GDLLMTools.oscillation_nudge(a, b)


## Fold this round's tool calls into the consecutive-use loop guard and return the tool that has now looped past its own break point, or "" if none has. Any round that mixes tools counts as progress and breaks the streak — as does one flagged `progressed`: a tool_search that freshly ATTACHED a tool is assembling a toolset, the opposite of the spiral this guard exists for, and firing on three productive searches made the brake's own "without ever using a tool it returned" message a lie (wild-caught 2026-07-29).
func track_consecutive_use(used_tools: Dictionary, progressed := false) -> String:
	if used_tools.size() != 1 or progressed:
		_streak_name = ""
		_streak_count = 0
		return ""
	var tool_name: String = used_tools.keys()[0]
	if tool_name == _streak_name:
		_streak_count += 1
	else:
		_streak_name = tool_name
		_streak_count = 1
	var limit := GDLLMTools.max_consecutive_uses(tool_name)
	return tool_name if limit >= 0 and _streak_count >= limit else ""


## The withheld-duplicate count once it has crossed WITHHELD_ESCALATION_THRESHOLD — piling stubs mean the loop the gentler brakes provably didn't stop, so the owner should stop it and ask for a progress summary — or 0 while they still might work. Crossing resets the counter, so a loop continuing after its summary gets a fresh window rather than an instant re-trip.
func take_escalation() -> int:
	if _withheld_count < WITHHELD_ESCALATION_THRESHOLD:
		return 0
	var repeats := _withheld_count
	_withheld_count = 0
	return repeats


## Zero every ledger — the streak guard, oscillation window, duplicate ledger, edit-retry grants, and withhold escalation — so an owner reusing one instance across runs (the chat, on each user send) starts fresh.
func reset() -> void:
	_streak_name = ""
	_streak_count = 0
	_round_tool_history.clear()
	_round_repeat_history.clear()
	_call_results.clear()
	_call_paths.clear()
	_edit_retry_paths.clear()
	_withheld_count = 0


## The duplicate-call nudge that usually REPLACES an immediate tool result's body, or "": fires when this run already ran the identical call (same tool, same arguments) AND got this identical content back, so the repeat provably added nothing. A changed result (e.g. re-reading a file after editing it) stays un-nudged, and identical content alone can't clear a constant-output result like check_script's clean bill, so a mutation drops the touched file's entries instead (see _invalidate_touched_duplicates).
## A repeat of a failure that INVITED the retry answers with GDLLMTools.TRANSIENT_REPEAT_NUDGE instead: the model did what the earlier result told it to, so "repeating the call cannot help" would blame it for obeying — the body is still withheld (it is identical), but the reply reports the condition standing rather than the call being pointless.
func _repetition_note(tool_name: String, args: Dictionary, content: String) -> String:
	if tool_name == "":
		return ""
	var sig := _call_signature(tool_name, args)
	var previous: Variant = _call_results.get(sig)
	_call_results[sig] = content
	_call_paths[sig] = _call_path_basename(args)
	if previous is String and String(previous) == content:
		return GDLLMTools.TRANSIENT_REPEAT_NUDGE if content.contains(GDLLMTools.TRANSIENT_RETRY_INVITATION) else GDLLMTools.DUPLICATE_CALL_NUDGE
	return ""


## The duplicate ledger's key for one call: the tool name plus its arguments as canonical JSON.
func _call_signature(tool_name: String, args: Dictionary) -> String:
	return tool_name + "|" + JSON.stringify(args)


## Drop the duplicate ledger's other entries for a file a call just mutated, so a post-edit re-check or re-read of it serves in full: check_script's clean bill is a constant string, identical before and after an intervening edit, so the identical-content test alone reads a legitimate verify-after-edit as a pointless repeat — transcript-observed withholding two sessions' final verification batches and escalating them into the redirect. The mutating call's own entry survives, so an identical re-run of the mutation itself is still caught — served in full behind its repeat note rather than withheld (see process_result); a failed mutation ("Error…") changed nothing and clears nothing.
func _invalidate_touched_duplicates(tool_name: String, args: Dictionary, content: String) -> void:
	if not GDLLMTools.is_mutating(tool_name) or content.begins_with("Error"):
		return
	var basename := _call_path_basename(args)
	if basename == "":
		return
	var own_sig := _call_signature(tool_name, args)
	var stale := PackedStringArray()
	for sig in _call_paths:
		if sig != own_sig and String(_call_paths[sig]) == basename:
			stale.append(sig)
	for sig in stale:
		_call_results.erase(sig)
		_call_paths.erase(sig)


## Record the file an edit_file call just failed to match old_string in, granting one full duplicate re-read of it this run (see _duplicate_serves_recovery).
## Only the not-found failure grants: its error text tells the model to copy from a fresh read, which the withhold stub would otherwise contradict.
func _note_edit_not_found(tool_name: String, args: Dictionary, content: String) -> void:
	if tool_name != "edit_file" or not content.contains("was not found in"):
		return
	var basename := _call_path_basename(args)
	if basename != "":
		_edit_retry_paths[basename] = true


## Whether this duplicate call is the one free full re-read granted after an edit_file old_string miss on the same file; true consumes the grant, so the next identical read is withheld as usual.
func _duplicate_serves_recovery(tool_name: String, args: Dictionary) -> bool:
	if tool_name != "read_file" and tool_name != "read_function" and tool_name != "search_files":
		return false
	var basename := _call_path_basename(args)
	if basename == "" or not _edit_retry_paths.has(basename):
		return false
	_edit_retry_paths.erase(basename)
	return true


## Lowercased basename of the call's file argument, tried against the tools' own path-key synonyms so the ledgers match whatever spelling the model used; "" when the call names no file.
func _call_path_basename(args: Dictionary) -> String:
	for key in GDLLMTools.FILE_PATH_KEYS:
		var value := String(args.get(key, "")).strip_edges()
		if value != "":
			return value.get_file().to_lower()
	return ""
