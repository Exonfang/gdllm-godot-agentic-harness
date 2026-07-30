@tool
class_name GDLLMRepeats extends RefCounted
## Occurrence counters for results that would otherwise render identically after doing real work. The tool loop's duplicate brake reads "same call, same arguments, same content" as a repeat that added nothing and stops the turn at its fourth firing (see GDLLMLoopBrakes) — a rule that is true of every honest tool and false of one whose text hides what it changed. Four tools were caught by it in wild use: suspend_game's frame steps, its freeze/resume pair, set_breakpoint's arm-and-clear cycle, and debug_game's continues onto a per-frame breakpoint. Each was fixed the same way, so the counting lives here once instead of four times.
##
## The number belongs to the TOOL's result, never to the brake: a count the brake stamped on itself would defeat the check it exists to make, while a count the tool reports describes what actually happened. That is also why it appears only from the second occurrence on — a call that has not repeated has nothing to disclose, and the tag costs no context until it earns it (goal 1).
##
## Two scopes, matching the two lifetimes these events really have. TURN counters clear on each user send, in step with the brake's own ledger, and key on the exact call — per OWNER (a session or one subagent run), because loop-brake ledgers are per-owner too and a shared count would tag a subagent's first call as a repeat the main chat made. RUN counters clear when a game run ends, for events the engine raises rather than the model — a break is numbered even though no tool call produced it. Every method is static: this is a namespace, not an instance.

## Per-turn occurrence counts, an owner's id mapping to its own signature-keyed counts; each owner's set clears with its own loop brakes.
static var _turn: Dictionary = {}
## Per-run occurrence counts keyed by event name; cleared when a game run ends.
static var _run: Dictionary = {}


## Record one more occurrence of `key` this turn for `owner` and return the new count, 1 for a first call.
static func bump_turn(key: String, owner: String = "") -> int:
	var counts: Dictionary = _turn.get_or_add(owner, {})
	counts[key] = int(counts.get(key, 0)) + 1
	return int(counts[key])


## Record one more occurrence of `key` in this run and return the new count.
static func bump_run(key: String) -> int:
	_run[key] = int(_run.get(key, 0)) + 1
	return int(_run[key])


static func count_run(key: String) -> int:
	return int(_run.get(key, 0))


## Drop one owner's per-turn counts; called where that owner's loop brakes reset (a session's user send, a subagent run's start and end), so the two ledgers can never disagree about what "this turn" means.
static func reset_turn(owner: String = "") -> void:
	_turn.erase(owner)


## Drop the per-run counts; called when a game run ends, so the next run numbers its own events from one.
static func reset_run() -> void:
	_run.clear()


## The signature one call is counted under — the tool and its arguments, matching what the duplicate brake keys on, so the tag appears exactly where that brake would otherwise misfire and nowhere else.
static func signature(tool_name: String, args: Dictionary) -> String:
	return tool_name + "|" + JSON.stringify(args)


## What a repeated call appends to its own result, or "" for a first occurrence. It states that the work happened again, in the brake's own terms, because that is the claim the identical text would otherwise contradict.
static func turn_tag(occurrence: int) -> String:
	if occurrence < 2:
		return ""
	return "\n(Identical call #%d this turn — it ran again and did the work again, so this is not a repeat that added nothing.)" % occurrence


## An engine event's number within the run, in the wording the debugging reports quote ("break #3 of this run"), or "" when nothing has been counted.
static func run_tag(noun: String, occurrence: int) -> String:
	if occurrence < 1:
		return ""
	return " — %s #%d of this run" % [noun, occurrence]
