extends SceneTree
## Headless regression tests for the session's context accounting (GDLLMChatSession.token_usage): the `context` figure the header and the manage table report, and the window-resolution rule that figure is judged against (GDLLMContexts.window_for + the declared window's entry shapes in GDLLMEfforts).
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/context_accounting_test.gd
## Exits nonzero on any failure. Only static pure logic is exercised, so no UI, model, or EditorSettings is touched.
##
## What these guard: `context` must name the context the NEXT request will carry, which is the newest request's prompt + reply, cleared at a committed summary until the first report after it. Reading the largest instead — the shape this replaced — leaves the header quoting a pre-compaction peak that no longer exists, so the header and the attach row's meter disagree about the same session right after a compaction. Both read the same anchor rule (see _last_reported_tokens_in, whose instance half needs the live UI and so is not covered here); these tests pin the static half of it.
## The window checks pin the declared-window contract: the stored entry keeps its readable shapes (a plain level array until a TTL or window is set, only set keys stored), the declared figure round-trips, and the accessors stay headless-safe — window_for now reads through GDLLMEfforts, whose EditorSettings access must answer "unconfigured" rather than erroring where no editor exists.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Session = preload("res://addons/gdllm-godot-agentic-harness/gdllm_chat_session.gd")
const Efforts = preload("res://addons/gdllm-godot-agentic-harness/gdllm_efforts.gd")
const Contexts = preload("res://addons/gdllm-godot-agentic-harness/gdllm_contexts.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_newest_not_largest()
	_test_summary_clears_until_next_report()
	_test_display_only_records_never_set_context()
	_test_estimate_fallback()
	_test_declared_window_entry_shapes()
	_test_window_resolution_headless()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _reported(t_in: int, t_out: int) -> Dictionary:
	return {"role": "assistant", "content": "", "stats": {"tokens_in": t_in, "tokens_out": t_out}}


func _estimated(e_in: int, e_out: int) -> Dictionary:
	return {"role": "assistant", "content": "", "stats": {"est_tokens_in": e_in, "est_tokens_out": e_out}}


func _user() -> Dictionary:
	return {"role": "user", "content": "do the thing"}


func _context(history: Array) -> int:
	return int(Session.token_usage(history)["context"])


func _test_newest_not_largest() -> void:
	var grown: Array = [_user(), _reported(100, 50), _user(), _reported(180, 20)]
	_check(_context(grown) == 200, "a growing session reports its newest request's context")
	# The regression: reading the largest would answer 150 here and keep answering it for the rest of the session.
	var shrunk: Array = [_user(), _reported(100, 50), _user(), _reported(60, 10)]
	_check(_context(shrunk) == 70, "a shrunk context reports the newest request, not the session's peak")
	_check(int(Session.token_usage(shrunk)["rep_in"]) == 160, "shrinking the context leaves the cumulative sums untouched")
	_check(_context([]) == 0 and _context([_user()]) == 0, "a session with nothing reported has no context figure")


func _test_summary_clears_until_next_report() -> void:
	var committed: Array = [_user(), _reported(100, 50), {"role": "notice", "kind": "summary", "split": 1, "summary": "..."}]
	_check(_context(committed) == 0, "a committed summary clears the figure — every earlier report describes a context it replaced")
	var resumed: Array = committed.duplicate()
	resumed.append(_reported(30, 5))
	_check(_context(resumed) == 35, "the first request reporting after a summary sets the new, smaller figure")
	var other_notice: Array = [_reported(100, 50), {"role": "notice", "kind": "compaction", "steps": []}]
	_check(_context(other_notice) == 150, "a non-summary notice — a prune-only compaction event — leaves the figure standing")


func _test_display_only_records_never_set_context() -> void:
	var with_task: Array = [_reported(100, 50), {"role": "task", "task": "title", "stats": {"tokens_in": 900, "tokens_out": 900}}]
	_check(_context(with_task) == 150, "a background Tasks-Model run never rides the session's context, so it can't set the figure")
	_check(int(Session.token_usage(with_task)["rep_in"]) == 1000, "a background run still counts toward the cumulative sums")
	var with_sub: Array = [_reported(100, 50), {"role": "assistant", "content": "", "subagent_activity": [{"type": "stats", "stats": {"tokens_in": 800, "tokens_out": 400}}]}]
	_check(_context(with_sub) == 150, "a subagent thread's usage never enters the main context, so it can't set the figure")
	_check(int(Session.token_usage(with_sub)["subagent_rep_in"]) == 800, "a subagent's usage still counts toward its own split of the sums")
	var with_plain: Array = [_reported(100, 50), _user()]
	_check(_context(with_plain) == 150, "a message carrying no usage at all leaves the newest reported figure standing")


func _test_estimate_fallback() -> void:
	var usage: Dictionary = Session.token_usage([_estimated(40, 10)])
	_check(int(usage["context"]) == 50, "a request whose provider reported nothing contributes its estimate to the figure")
	_check(bool(usage["est_fallback_used"]), "an estimated contribution is flagged so the header can label it honestly")
	var mixed: Array = [_estimated(400, 100), _reported(60, 10)]
	_check(_context(mixed) == 70, "a reported request after an estimated one still sets the figure from the newest")


func _test_declared_window_entry_shapes() -> void:
	var levels: Array = ["high", "low"]
	_check(Efforts.make_entry(levels, 0, 0) is Array, "neither TTL nor window set keeps the original readable level-array shape")
	var ttl_only: Variant = Efforts.make_entry(levels, 300, 0)
	_check(ttl_only is Dictionary and not ttl_only.has("context_window_tokens"), "a TTL-only entry stores no window key at all")
	var window_only: Variant = Efforts.make_entry(levels, 0, 131072)
	_check(window_only is Dictionary and not window_only.has("cache_cold_gap_seconds"), "a window-only entry stores no TTL key at all")
	_check(Efforts.window_from_entry(window_only) == 131072, "a declared window round-trips through the stored entry")
	var both: Variant = Efforts.make_entry(levels, 300, 131072)
	_check(int(both.get("cache_cold_gap_seconds", 0)) == 300 and Efforts.window_from_entry(both) == 131072 and Array(both.get("levels", [])) == levels, "an entry carrying all three knobs keeps each intact")
	_check(Efforts.window_from_entry(levels) == 0, "the pre-window level-array shape reads as unconfigured, not an error")
	_check(Efforts.window_from_entry(null) == 0 and Efforts.window_from_entry({"context_window_tokens": -5}) == 0, "a missing or non-positive figure is unconfigured, never a window")


func _test_window_resolution_headless() -> void:
	# No editor settings exist in this run; the accessors must answer "unconfigured" instead of erroring, or every window_for caller in the suites dies with them.
	_check(Efforts.get_config() == {}, "the efforts config reads as empty where no editor exists")
	_check(Efforts.context_window_for("src::model") == 0, "an unconfigured model declares no window")
	Contexts._windows = {"src::model": 4096}
	Contexts._loaded = true
	_check(Contexts.window_for("src::model") == 4096, "with nothing declared, window_for still answers from the probed cache")
	_check(Contexts.window_for("src::other") == 0, "a model in neither store stays an honest unknown")
