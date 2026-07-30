extends SceneTree
## Headless regression tests for the console tools' pure halves (GDLLMConsole): the Output-console tail formatter, the debugger error-history formatter, and the Tree scrape behind it, driven with synthetic data because the real panels exist only in a live editor.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/console_tools_test.gd
## Exits nonzero on any failure.
## What these guard: the tail/filter/clamp arithmetic (newest lines win, filter counts stay honest, a runaway line is clipped with a count), the entry scrape reading the engine's own _is_warning/_is_error item marks and flattening child rows, the honest empty-panel and no-match messages, the per-entry detail-row cap, and the headless refusals — a headless run must refuse by name rather than answer with an invented empty console.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class cache hasn't been built yet.
const Console = preload("res://addons/gdllm-godot-agentic-harness/gdllm_console.gd")
const Tools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_output_tail()
	_test_output_filter()
	_test_output_clip_and_empty()
	_test_error_entries_scrape()
	_test_error_format()
	_test_headless_refusals()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_output_tail() -> void:
	var tailed := Console.format_output("a\nb\nc\nd", 2, "")
	_check(tailed.ends_with("c\nd"), "the tail keeps the newest lines in order")
	_check(tailed.begins_with("Output console: 4 lines total, showing the newest 2 ("), "a truncated tail says how much it shows of how much")
	_check(tailed.contains("raise \"lines\""), "a truncated tail names the lines lever")
	_check(not tailed.contains("\nb\n"), "lines older than the tail are not relayed")
	var whole := Console.format_output("a\nb\nc\nd\n", 0, "")
	_check(whole.begins_with("Output console (4 lines):"), "a defaulted count that fits shows everything, trailing newline dropped")
	var oversized := Console.format_output("a\nb\nc", 900, "")
	_check(oversized.begins_with("Output console (3 lines):"), "an oversized request is honored against what exists, not an error")


func _test_output_filter() -> void:
	var matched := Console.format_output("foo one\nbar\nFOO two", 10, "foo")
	_check(matched.contains("foo one") and matched.contains("FOO two"), "the filter matches case-insensitively")
	_check(not matched.contains("bar"), "non-matching lines are dropped")
	_check(matched.begins_with("Output console: 3 lines total; 2 contain \"foo\":"), "the filter header counts matches against the total")
	var none := Console.format_output("alpha\nbeta", 10, "gamma")
	_check(none == "Output console: 2 lines; none contain \"gamma\".", "a filter that matches nothing says so instead of returning an empty body")
	var windowed := Console.format_output("x\nx\nx\nx", 2, "x")
	_check(windowed.begins_with("Output console: 4 lines total; 4 contain \"x\", showing the newest 2 of those ("), "a filtered tail names both the match count and the window")


func _test_output_clip_and_empty() -> void:
	_check(Console.format_output("", 10, "") == "The Output console is currently empty — nothing has been printed since it was last cleared.", "an empty console is stated, not returned as blank text")
	var long_line := "y".repeat(Console.MAX_LINE_CHARS + 150)
	var clipped := Console.format_output(long_line, 10, "")
	_check(clipped.contains("(+150 more chars)"), "a runaway line is clipped with the elided count")
	_check(not clipped.contains(long_line), "the full runaway line is never relayed")


func _test_error_entries_scrape() -> void:
	var tree := Tree.new()
	tree.columns = 2
	var root := tree.create_item()
	var err := tree.create_item(root)
	err.set_meta("_is_error", true)
	err.set_text(0, "0:00:01")
	err.set_text(1, "Node not found: \"Player\"")
	var src := tree.create_item(err)
	src.set_text(0, "<C++ Source>")
	src.set_text(1, "scene/main/node.cpp:1691")
	var frame := tree.create_item(err)
	frame.set_text(0, "<Stack Trace>")
	frame.set_text(1, "_ready (res://main.gd:12)")
	var warn := tree.create_item(root)
	warn.set_meta("_is_warning", true)
	warn.set_text(0, "0:00:02")
	warn.set_text(1, "Deprecated call")
	var entries := Console.error_entries(tree)
	_check(entries.size() == 2, "one entry per top-level tree item")
	_check(String(entries[0]["kind"]) == "error" and String(entries[1]["kind"]) == "warning", "kind follows the engine's own _is_warning/_is_error marks")
	_check(String(entries[0]["time"]) == "0:00:01" and String(entries[0]["title"]).contains("Player"), "time and message come from the two visible columns")
	_check(entries[0]["detail"].size() == 2 and String(entries[0]["detail"][0]) == "<C++ Source> scene/main/node.cpp:1691", "child rows flatten both columns into one line")
	_check(entries[1]["detail"].is_empty(), "an entry without children carries no detail rows")
	var bare := Tree.new()
	_check(Console.error_entries(bare).is_empty(), "a rootless tree scrapes to no entries")
	bare.free()
	tree.free()


func _test_error_format() -> void:
	_check(Console.format_errors([], 0, "").begins_with("The debugger's error history is empty"), "an empty history is stated and points editor-side errors at read_output")
	var entries: Array = [
		{"kind": "error", "time": "0:00:01", "title": "boom", "detail": ["<C++ Error> failed", "<Stack Trace> _ready (res://a.gd:3)"]},
		{"kind": "warning", "time": "0:00:02", "title": "creaky", "detail": []},
		{"kind": "error", "time": "0:00:03", "title": "boom again", "detail": []},
	]
	var whole := Console.format_errors(entries, 0, "")
	_check(whole.begins_with("Debugger error history, 3 entries (2 errors, 1 warnings), oldest first:"), "the header tallies errors and warnings")
	_check(whole.contains("[0:00:01] ERROR: boom") and whole.contains("[0:00:02] WARNING: creaky"), "entries carry time, kind, and message")
	_check(whole.contains("  <C++ Error> failed"), "detail rows ride indented under their entry")
	var tailed := Console.format_errors(entries, 2, "")
	_check(not tailed.contains("boom\n") and tailed.contains("boom again"), "the limit keeps the newest entries")
	_check(tailed.begins_with("Debugger error history, 3 entries (2 errors, 1 warnings), showing the newest 2"), "a truncated history says how much it shows")
	var filtered := Console.format_errors(entries, 0, "BOOM")
	_check(filtered.contains("boom again") and not filtered.contains("creaky"), "the filter matches entry text case-insensitively")
	var none := Console.format_errors(entries, 0, "nowhere")
	_check(none == "Debugger error history: 3 entries (2 errors, 1 warnings); none contain \"nowhere\".", "a filter that matches nothing says so")
	var deep: Array = []
	for i in Console.MAX_ERROR_DETAIL_ROWS + 3:
		deep.append("frame %d" % i)
	var capped := Console.format_errors([{"kind": "error", "time": "t", "title": "deep", "detail": deep}], 0, "")
	_check(capped.contains("(+3 more detail rows)"), "detail rows past the cap collapse to a count")
	_check(not capped.contains("frame %d" % (Console.MAX_ERROR_DETAIL_ROWS + 1)), "capped detail rows are not relayed")


func _test_headless_refusals() -> void:
	var output := Console.read_output(0, "")
	_check(output.begins_with("Error:") and output.contains("headless"), "read_output refuses by name in a headless run")
	var errors := Console.read_errors(0, "")
	_check(errors.begins_with("Error:") and errors.contains("headless"), "read_errors refuses by name in a headless run")
	var dispatched: Dictionary = await Tools.execute("read_output", {"tail": 5})
	_check(String(dispatched["content"]).begins_with("Error:"), "the registry dispatch reaches the console tool rather than answering unknown-tool")
	var errors_dispatched: Dictionary = await Tools.execute("read_errors", {})
	_check(String(errors_dispatched["content"]).contains("headless"), "read_errors dispatches through the registry with the same honest refusal")
