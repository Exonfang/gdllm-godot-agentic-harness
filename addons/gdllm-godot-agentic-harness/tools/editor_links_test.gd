extends SceneTree
## Headless regression tests for GDLLMLinks — the chat log's clickable file references.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/editor_links_test.gd
## Exits nonzero on any failure. The click itself needs the editor and is not testable here; what IS testable is everything that decides WHETHER a reference becomes a link and where it points.

# Preloaded rather than referenced by class_name so the test survives a checkout whose global class cache hasn't been built yet.
const GDLLMLinks = preload("res://addons/gdllm-godot-agentic-harness/gdllm_links.gd")
const GDLLMMarkdown = preload("res://addons/gdllm-godot-agentic-harness/gdllm_markdown.gd")

## A real, uniquely-named file in this project — the resolvable case every link rests on.
const REAL_PATH := "res://addons/gdllm-godot-agentic-harness/gdllm_links.gd"
const REAL_NAME := "gdllm_links.gd"

## Two files sharing one name, written for the ambiguity case and removed again — nothing in this repo is duplicated, and a name that resolves to several files must NOT become a link.
const DUP_DIR_A := "res://addons/gdllm-godot-agentic-harness/tools/link_fixture_a"
const DUP_DIR_B := "res://addons/gdllm-godot-agentic-harness/tools/link_fixture_b"
const DUP_NAME := "link_dup_fixture.gd"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_resolve()
	_test_linkify_basic()
	_test_linkify_inside_code()
	_test_line_numbers()
	_test_leaves_alone()
	_test_extension_precedence()
	_test_ambiguous_name()
	_test_open_contract()
	_test_label_does_not_route_to_browser()
	_test_node_attachment_states_its_provenance()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("  FAIL: ", label)


## A reference resolves exactly as read_file would: an explicit path that exists, a bare name that is unique, and nothing else.
func _test_resolve() -> void:
	_check(GDLLMLinks.resolve(REAL_PATH) == REAL_PATH, "an existing res:// path resolves to itself")
	_check(GDLLMLinks.resolve(REAL_NAME) == REAL_PATH, "a unique bare name resolves to its path")
	_check(GDLLMLinks.resolve("res://addons/gdllm-godot-agentic-harness/does_not_exist.gd") == "", "a res:// path that doesn't exist resolves to nothing")
	_check(GDLLMLinks.resolve("totally_made_up_name.gd") == "", "an unknown bare name resolves to nothing")
	_check(GDLLMLinks.resolve("") == "", "an empty reference resolves to nothing")


func _test_linkify_basic() -> void:
	var out := GDLLMLinks.linkify("see %s for the walker" % REAL_NAME)
	_check(out.contains("[url=%s%s]%s[/url]" % [GDLLMLinks.META_PREFIX, REAL_PATH, REAL_NAME]), "a bare name becomes a url carrying its resolved path")
	_check(out.begins_with("see ") and out.ends_with(" for the walker"), "the surrounding prose is untouched")
	var full := GDLLMLinks.linkify("in %s we walk" % REAL_PATH)
	_check(full.contains("[url=%s%s]%s[/url]" % [GDLLMLinks.META_PREFIX, REAL_PATH, REAL_PATH]), "an explicit res:// path links to itself")
	# The visible text must stay byte-identical to what the model wrote, or the log stops being a faithful record (goal 2).
	_check(_strip_tags(full) == "in %s we walk" % REAL_PATH, "linkifying changes no visible character")


## 92% of the res:// mentions measured in the wild sit inside backticks, so a walker that skipped [code] would skip almost the whole feature.
func _test_linkify_inside_code() -> void:
	var bb := "look at [code][color=#a3c8ff]%s[/color][/code] now" % REAL_NAME
	var out := GDLLMLinks.linkify(bb)
	_check(out.contains("[url=%s%s]" % [GDLLMLinks.META_PREFIX, REAL_PATH]), "a reference inside a code span still links")
	_check(out.contains("[code][color=#a3c8ff]"), "the code and color tags survive intact")


func _test_line_numbers() -> void:
	var colon := GDLLMLinks.linkify("%s:42 explodes" % REAL_NAME)
	_check(colon.contains("[url=%s%s#42]%s:42[/url]" % [GDLLMLinks.META_PREFIX, REAL_PATH, REAL_NAME]), "a :line suffix rides the meta and stays inside the link text")
	var worded := GDLLMLinks.linkify("%s line 7 explodes" % REAL_NAME)
	_check(worded.contains("#7]"), "a \"line N\" suffix is recognized too")
	_check(_strip_tags(worded) == "%s line 7 explodes" % REAL_NAME, "the worded form's visible text is unchanged")


func _test_leaves_alone() -> void:
	var prose := "there is no file here, just prose about 4.7 and e.g. things"
	_check(GDLLMLinks.linkify(prose) == prose, "prose naming no file is returned unchanged")
	var unknown := "check made_up_thing.gd please"
	_check(GDLLMLinks.linkify(unknown) == unknown, "an unresolvable name is left as plain text, never a link that lies")
	# A real Markdown link must not gain a nested [url] inside it.
	var existing := "[url=https://example.com]%s[/url]" % REAL_NAME
	_check(GDLLMLinks.linkify(existing) == existing, "a reference already inside a url is left alone")
	_check(not GDLLMLinks.linkify("visit https://example.com/x.gd now").contains(GDLLMLinks.META_PREFIX), "a bare http URL is not turned into a project link")


## Alternation is leftmost-first, so "gd" ahead of "gdshader" would match "link_ext_fixture.gd" out of "link_ext_fixture.gdshader" and link the wrong file — or, with no such .gd, strand "shader" outside the link.
## Driven against a REAL fixture pair sharing one stem, since that is the case where getting it wrong points the user at a different file rather than merely rendering oddly.
func _test_extension_precedence() -> void:
	var stem := "res://addons/gdllm-godot-agentic-harness/tools/link_ext_fixture"
	for suffix in [".gd", ".gdshader"]:
		var f := FileAccess.open(stem + suffix, FileAccess.WRITE)
		f.store_string("// fixture\n")
		f.close()
	GDLLMLinks.invalidate()
	var out := GDLLMLinks.linkify("the file link_ext_fixture.gdshader compiles")
	_check(out.contains("[url=%s%s.gdshader]link_ext_fixture.gdshader[/url]" % [GDLLMLinks.META_PREFIX, stem]), "a .gdshader links to the shader, not to the .gd sharing its stem")
	_check(_strip_tags(out) == "the file link_ext_fixture.gdshader compiles", "the .gdshader name is never split mid-extension")
	_check(GDLLMLinks.linkify("and link_ext_fixture.gd too").contains("[url=%s%s.gd]" % [GDLLMLinks.META_PREFIX, stem]), "the .gd beside it still links to itself")
	for suffix in [".gd", ".gdshader"]:
		DirAccess.remove_absolute(stem + suffix)
	GDLLMLinks.invalidate()


func _test_ambiguous_name() -> void:
	for dir_path in [DUP_DIR_A, DUP_DIR_B]:
		DirAccess.make_dir_recursive_absolute(dir_path)
		var f := FileAccess.open(dir_path.path_join(DUP_NAME), FileAccess.WRITE)
		f.store_string("extends Node\n")
		f.close()
	GDLLMLinks.invalidate()
	_check(GDLLMLinks.resolve(DUP_NAME) == "", "a name carried by two files resolves to nothing rather than picking one")
	var text := "both are %s here" % DUP_NAME
	_check(GDLLMLinks.linkify(text) == text, "an ambiguous name is left unlinked")
	for dir_path in [DUP_DIR_A, DUP_DIR_B]:
		DirAccess.remove_absolute(dir_path.path_join(DUP_NAME))
		DirAccess.remove_absolute(dir_path)
	GDLLMLinks.invalidate()
	_check(GDLLMLinks.resolve(REAL_NAME) == REAL_PATH, "the index rebuilds after invalidation")


## open() reports whether the meta was ours, so the caller can hand a real Markdown link to the browser instead.
func _test_open_contract() -> void:
	_check(not GDLLMLinks.open("https://example.com"), "a non-project meta is declined")
	_check(not GDLLMLinks.open(""), "an empty meta is declined")
	_check(GDLLMLinks.open(GDLLMLinks.META_PREFIX + REAL_PATH), "a project meta is claimed")
	_check(GDLLMLinks.open(GDLLMLinks.META_PREFIX + "res://gone.gd#12"), "a claimed meta whose file vanished is still claimed, not passed to the browser")


## The wiring regression that shipped once and had to be found by hand: MarkdownLabel connects its own meta_clicked first and, with assume_https_links at its default, hands anything it doesn't recognize to OS.shell_open("https://" + meta) — so every project link opened the WEB BROWSER.
## The label must therefore leave that switch off, which is what routes our metas to unhandled_link_clicked instead; a project link reaching the browser is the one outcome this feature must never produce.
func _test_label_does_not_route_to_browser() -> void:
	# Built through the seam the session itself uses, so this file stays loadable in a project without the optional MarkdownLabel addon (where there is no label to test).
	var label := GDLLMMarkdown.make_label()
	if label == null:
		print("  SKIP: MarkdownLabel addon not present, no chat label to test")
		return
	_check(not label.get("assume_https_links"), "the chat label does not let MarkdownLabel guess https:// for an unrecognized meta")
	_check(label.get("automatic_links"), "real URLs, header anchors and checkboxes are still handled by the library")
	_check(label.has_signal("unhandled_link_clicked"), "the extension point the session hooks exists")
	# A meta the library would have shell_opened must be one OUR resolver claims, or the browser gets it.
	_check(GDLLMLinks.open(GDLLMLinks.META_PREFIX + REAL_PATH), "a project meta is claimed before any browser fallback can run")
	_check(not GDLLMLinks.META_PREFIX.contains("://"), "the meta prefix is not URL-shaped, so it can never be mistaken for a web link")
	# Drive the REAL signal path, which is what the first version got wrong: the earlier probe called GDLLMLinks.open() directly and so never exercised the library handler sitting in front of it.
	# In MarkdownLabel._on_meta_clicked the shell_open branches all `return`, so reaching unhandled_link_clicked is proof the browser was NOT invoked.
	var seen: Array = []
	label.connect("unhandled_link_clicked", func(m: Variant) -> void: seen.append(m))
	var project_meta := GDLLMLinks.META_PREFIX + REAL_PATH
	label.meta_clicked.emit(project_meta)
	_check(seen.size() == 1 and String(seen[0]) == project_meta, "a clicked project link reaches our handler instead of the browser")
	label.free()


## The wild failure this exists to stop: an attachment turn is indistinguishable from a call the model made itself, so asked "what node do I have selected" it read its own synthetic describe_scene call as a guess and answered "I don't actually have a tool that reads the editor's current selection" — while reciting that very node's properties. Two of four sessions.
## Headless has no editor, so the body itself is an error string; what is testable here is that the provenance line is prepended, says who chose the node, and carries the count a plural question needs.
func _test_node_attachment_states_its_provenance() -> void:
	var single := GDLLMTools.format_attachment_scene({"node_path": "."}, 1, 1)
	_check(single.begins_with("(Attached by the user, not fetched by you:"), "the note leads the body, where it cannot be missed")
	_check(single.contains("the one node they currently have selected"), "a single selection reads as the node the user selected")
	_check(single.contains("Scene dock"), "the note names where the selection came from")
	var second := GDLLMTools.format_attachment_scene({"node_path": "A/B"}, 2, 3)
	_check(second.contains("node 2 of the 3 nodes"), "a multi-selection numbers each node so a plural question is answerable")
	_check(GDLLMTools.format_attachment_scene({"node_path": "A"}, 1, 1, 1).contains("the one node"), "a genuine single selection reads as one node")
	# A selection larger than the attach cap must state the shortfall: a model answering "what nodes do I have selected" from a capped set would otherwise give a confidently wrong count.
	var capped := GDLLMTools.format_attachment_scene({"node_path": "A"}, 3, 20, 34)
	_check(capped.contains("node 3 of the 20 attached here"), "a capped selection numbers within what was attached")
	_check(capped.contains("they have 34 selected"), "a capped selection states the real total")
	_check(capped.contains("remaining 14 were left off"), "a capped selection counts what it withheld")
	_check(not GDLLMTools.format_attachment_scene({"node_path": "A"}, 1, 3, 3).contains("left off"), "an uncapped selection claims nothing was withheld")
	# Without the ordinals it must stay byte-identical to the tool, so a re-run and the estimate path are unaffected.
	var bare := GDLLMTools.format_attachment_scene({"node_path": "."})
	_check(not bare.contains("Attached by the user"), "no note is added when no ordinal is supplied")
	_check(bare == GDLLMTools.format_attachment_scene({"node_path": "."}, 0, 0), "an explicit zero ordinal is the same as none")


## Visible text with every BBCode tag removed — what the reader actually sees.
func _strip_tags(bbcode: String) -> String:
	var out := ""
	var pos := 0
	while pos < bbcode.length():
		if bbcode[pos] == "[":
			var close := bbcode.find("]", pos)
			if close == -1:
				return out + bbcode.substr(pos)
			pos = close + 1
		else:
			var next_tag := bbcode.find("[", pos)
			if next_tag == -1:
				next_tag = bbcode.length()
			out += bbcode.substr(pos, next_tag - pos)
			pos = next_tag
	return out
