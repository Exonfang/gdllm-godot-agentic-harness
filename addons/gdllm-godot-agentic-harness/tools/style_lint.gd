extends SceneTree
## Self-contained GDScript style-guide linter (docs.godotengine.org "GDScript style guide") — no dependency outside this addon.
## Checks: tab indentation, trailing whitespace, comment spacing, naming conventions, class definition order, and two blank lines around top-level functions/classes. Line length is deliberately not enforced (the repo's one-sentence-per-comment-line convention overrides it).
## A definition annotated with @warning_ignore (same line or the line above) is exempt from the definition-order rule — the author has explicitly marked it deliberate — but its naming is still checked.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/style_lint.gd
## Pass file paths after `--` to lint only those; exits nonzero when problems are found.

const DEFAULT_ROOT := "res://addons/gdllm-godot-agentic-harness"

## Top-level definition categories in the order the style guide's "Code order" section prescribes; a definition whose rank is lower than one already seen is out of order.
const CATEGORY_ORDER := [
	"@tool/@icon", "class_name", "extends", "signals", "enums", "constants",
	"static variables", "@export variables", "public variables", "private variables",
	"@onready public variables", "@onready private variables", "functions/classes",
]

var _problem_count: int = 0
var _snake := RegEx.create_from_string("^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
var _private_snake := RegEx.create_from_string("^_?[a-z][a-z0-9]*(_[a-z0-9]+)*$")
var _constant_case := RegEx.create_from_string("^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*$")
var _pascal := RegEx.create_from_string("^([A-Z][a-z0-9]*)+$")
var _enum_member := RegEx.create_from_string("^([A-Za-z_][A-Za-z0-9_]*)")


func _init() -> void:
	var paths := PackedStringArray(OS.get_cmdline_user_args())
	if paths.is_empty():
		paths = _collect_scripts(DEFAULT_ROOT)
	for path in paths:
		_lint_file(path)
	if _problem_count > 0:
		print("Failure: %d style problems found in %d files" % [_problem_count, paths.size()])
	else:
		print("OK: %d files clean" % paths.size())
	quit(1 if _problem_count > 0 else 0)


func _collect_scripts(root: String) -> PackedStringArray:
	var found := PackedStringArray()
	for entry in DirAccess.get_files_at(root):
		if entry.get_extension() == "gd":
			found.append(root.path_join(entry))
	for entry in DirAccess.get_directories_at(root):
		found.append_array(_collect_scripts(root.path_join(entry)))
	return found


func _report(path: String, line: int, message: String, rule: String) -> void:
	_problem_count += 1
	print("%s:%d: %s (%s)" % [path.trim_prefix("res://"), line, message, rule])


func _lint_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_report(path, 0, "cannot open file", "io")
		return
	var lines := file.get_as_text().split("\n")
	var scan_state := {"triple": ""}
	var in_string := []  # per line: whether it started inside a multiline string
	var max_rank := -1
	var top_category := ""  # name of the highest-ranked category seen, for order messages
	var in_enum := false
	var pending_ignore := false  # a standalone @warning_ignore line suppresses the definition that follows
	for idx in lines.size():
		var raw: String = lines[idx]
		var lineno := idx + 1
		var started_in_string: bool = scan_state.triple != ""
		in_string.append(started_in_string)
		var comment_pos := _scan_line(raw, scan_state)
		# lines inside multiline strings are content, not code — leave them alone
		if started_in_string:
			continue
		if raw != raw.rstrip(" \t") and scan_state.triple == "":
			_report(path, lineno, "trailing whitespace", "trailing-whitespace")
		var code := raw if comment_pos < 0 else raw.substr(0, comment_pos)
		if comment_pos >= 0:
			_check_comment(path, lineno, raw.substr(comment_pos))
		var stripped := code.strip_edges()
		if stripped.is_empty():
			continue
		if raw.begins_with(" "):
			_report(path, lineno, "indentation uses spaces; use tabs", "indentation")
		if in_enum:
			in_enum = not _check_enum_members(path, lineno, stripped)
			continue
		# naming and ordering only apply to class-level (unindented) definitions
		if raw.begins_with("\t"):
			continue
		# A @warning_ignore is the author explicitly marking the declaration deliberate, so its placement is theirs to choose; the annotation is stripped before categorizing so naming checks still apply.
		var suppressed := pending_ignore
		var decl := stripped
		while decl.begins_with("@warning_ignore(") and decl.find(")") >= 0:
			suppressed = true
			decl = decl.substr(decl.find(")") + 1).strip_edges()
		if decl.is_empty():
			# A standalone @warning_ignore line covers the next definition, like the engine's own annotation.
			pending_ignore = suppressed
			continue
		pending_ignore = false
		var rank := _categorize(path, lineno, decl)
		if rank == 4 and decl.find("{") >= 0 and decl.find("}") < 0:
			in_enum = true
		if rank < 0:
			continue
		if rank < max_rank and not suppressed:
			_report(path, lineno, "%s after %s; expected order: %s" % [
					CATEGORY_ORDER[rank], top_category, ", ".join(CATEGORY_ORDER)],
					"definitions-order")
		elif rank > max_rank:
			max_rank = rank
			top_category = CATEGORY_ORDER[rank]
		if rank == CATEGORY_ORDER.size() - 1:
			_check_blank_lines(path, lineno, lines, in_string, idx)


## Walk `line` tracking string state carried in `state` ({triple: '"""'|"'''"|""}); returns the index where a real comment starts, or -1. Single-quoted strings never span lines (that's a parse error), so only triple-quote state persists.
func _scan_line(line: String, state: Dictionary) -> int:
	var quote := ""
	var i := 0
	while i < line.length():
		var c := line[i]
		if state.triple != "":
			if line.substr(i, 3) == state.triple:
				state.triple = ""
				i += 3
			else:
				i += 1
			continue
		if quote != "":
			if c == "\\":
				i += 2
			else:
				if c == quote:
					quote = ""
				i += 1
			continue
		if c == "#":
			return i
		if c == "\"" or c == "'":
			if line.substr(i, 3) == c.repeat(3):
				state.triple = c.repeat(3)
				i += 3
			else:
				quote = c
				i += 1
			continue
		i += 1
	return -1


## Regular comments start with "# " and doc comments with "## " per the style guide; region markers and shebangs are exempt.
func _check_comment(path: String, lineno: int, comment: String) -> void:
	if comment.begins_with("#region") or comment.begins_with("#endregion") or comment.begins_with("#!"):
		return
	var rest := comment.lstrip("#")
	if not rest.is_empty() and not rest.begins_with(" "):
		_report(path, lineno, "expected a space after '#'", "comment-format")


## Enum members are CONSTANT_CASE; returns true when this line closes the enum block.
func _check_enum_members(path: String, lineno: int, stripped: String) -> bool:
	for piece in stripped.split(","):
		var m := _enum_member.search(piece.strip_edges())
		if m and not _constant_case.search(m.get_string(1)):
			_report(path, lineno, "enum member \"%s\" is not CONSTANT_CASE" % m.get_string(1), "enum-member-name")
	return stripped.find("}") >= 0


## Identify a top-level definition's category (index into CATEGORY_ORDER, -1 for none) and check its name's casing on the way.
func _categorize(path: String, lineno: int, stripped: String) -> int:
	var words := stripped.split(" ", false)
	var first: String = words[0]
	if first == "@tool" or first.begins_with("@icon"):
		return 0
	if first == "class_name":
		_check_name(path, lineno, _pascal, _name_after(stripped, "class_name"), "class name", "PascalCase")
		return 1
	if first == "extends":
		return 2
	if first == "signal":
		var name := _name_after(stripped, "signal")
		if not _snake.search(name):
			_report(path, lineno, "signal name \"%s\" is not snake_case (no leading underscore)" % name, "signal-name")
		return 3
	if first == "enum" or stripped.begins_with("enum{"):
		var name := _name_after(stripped, "enum")
		if not name.is_empty() and name != "{":
			_check_name(path, lineno, _pascal, name, "enum name", "PascalCase")
		return 4
	if first == "const":
		var name := _name_after(stripped, "const")
		# PascalCase is allowed when the constant holds a loaded resource or class
		var loads := stripped.find("preload(") >= 0 or stripped.find("load(") >= 0
		if not _constant_case.search(name) and not (loads and _pascal.search(name)):
			_report(path, lineno, "constant name \"%s\" is not CONSTANT_CASE" % name, "constant-name")
		return 5
	if stripped.begins_with("static var "):
		_check_name(path, lineno, _private_snake, _name_after(stripped, "var"), "variable name", "snake_case")
		return 6
	if first.begins_with("@export"):
		if stripped.find("var ") >= 0:
			_check_name(path, lineno, _private_snake, _name_after(stripped, "var"), "variable name", "snake_case")
			return 7
		return -1  # a bare @export_group/@export_category annotation line
	if first == "@onready" or first == "var":
		var name := _name_after(stripped, "var")
		_check_name(path, lineno, _private_snake, name, "variable name", "snake_case")
		var private := name.begins_with("_")
		if first == "@onready":
			return 11 if private else 10
		return 9 if private else 8
	if first == "func" or stripped.begins_with("static func "):
		_check_name(path, lineno, _private_snake, _name_after(stripped, "func"), "function name", "snake_case")
		return CATEGORY_ORDER.size() - 1
	if first == "class":
		_check_name(path, lineno, _pascal, _name_after(stripped, "class"), "class name", "PascalCase")
		return CATEGORY_ORDER.size() - 1
	return -1


## Extract the identifier following `keyword` in a definition line, shorn of `(`, `:`, `=`, `{` and their trailing clauses.
func _name_after(stripped: String, keyword: String) -> String:
	var tail := stripped.substr(stripped.find(keyword) + keyword.length()).strip_edges()
	for stop in ["(", ":", "=", "{", " "]:
		var pos := tail.find(stop)
		if pos >= 0:
			tail = tail.substr(0, pos)
	return tail.strip_edges()


func _check_name(path: String, lineno: int, pattern: RegEx, name: String, what: String, style: String) -> void:
	if name.is_empty() or not pattern.search(name):
		_report(path, lineno, "%s \"%s\" is not %s" % [what, name, style], "%s-name" % what.split(" ")[0])


## Top-level functions and classes need two blank lines above them. Attached comments/annotations are skipped, as are detached section-banner comments above them — the two blank lines must sit between the whole block and the nearest real code. Lines inside multiline strings count as code, not blanks.
func _check_blank_lines(path: String, lineno: int, lines: Array, in_string: Array, idx: int) -> void:
	var j := idx - 1
	while true:
		while j >= 0 and not in_string[j]:
			var above: String = lines[j].strip_edges()
			if above.begins_with("#") or above.begins_with("@"):
				j -= 1
			else:
				break
		var blanks := 0
		while j >= 0 and not in_string[j] and lines[j].strip_edges().is_empty():
			blanks += 1
			j -= 1
		if j < 0 or blanks >= 2:
			return
		if in_string[j] or not lines[j].strip_edges().begins_with("#"):
			_report(path, lineno, "expected two blank lines before a top-level function/class definition", "blank-lines")
			return
