extends SceneTree
## Headless regression tests for the model picker's filter matching (GDLLMModelPicker.matches_filter):
## Separators in the query and the model's label/id compare as spaces, every query word must be present,
## and an empty or punctuation-only query matches everything.
## The fixture is a real qualified id and the label GDLLMSources.label_for would render for it.
##
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/model_picker_match_test.gd
## Exits nonzero on any failure.

# Preloaded rather than referenced by class_name so the test runs in a checkout whose global class
# cache hasn't been built yet.
const Picker = preload("res://addons/gdllm-godot-agentic-harness/gdllm_model_picker.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_matches_all_components()
	_test_empty_queries()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _test_matches_all_components() -> void:
	var label := "OpenAI · deepseek/deepseek-v4.1-flash-1017"
	var qid := "openai::deepseek/deepseek-v4.1-flash-1017"
	_check(Picker.matches_filter("deepseek v4", label, qid), "id with separator is found with a space")
	_check(Picker.matches_filter("deepseek-v4", label, qid), "the id's own separator still works")
	_check(Picker.matches_filter("deepseek/v4", label, qid), "a slash separator works")
	_check(Picker.matches_filter("v4 deepseek", label, qid), "query component order doesn't matter")
	_check(Picker.matches_filter("deepseek flash 1017", label, qid), "every component matches, in any order")
	_check(Picker.matches_filter("openai", label, qid), "the source is searchable")
	_check(not Picker.matches_filter("deepseek v5", label, qid), "an absent component excludes the model")


func _test_empty_queries() -> void:
	_check(Picker.matches_filter(""), "an empty query matches everything")
	_check(Picker.matches_filter("---"), "a punctuation-only query matches everything")
