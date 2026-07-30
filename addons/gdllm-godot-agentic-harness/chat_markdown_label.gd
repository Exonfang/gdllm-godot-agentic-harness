@tool
class_name ChatMarkdownLabel extends MarkdownLabel
## Updating MarkdownLabel settings for our taste.
## MarkdownLabel is an OPTIONAL dependency: this is the only script allowed to name it, and it is only ever loaded through GDLLMMarkdown, after the library is confirmed present.

const TABLE_ROW_TOKEN := ";$￹:%d$;" ## stand-in for a finished table row until the last pass, mimicking MarkdownLabel's escape-placeholder shape so no inline pass matches into it

## Color applied to all code spans and blocks. The session assigns it too, so a label built outside the log still matches the configured palette.
@export var code_color: Color = GDLLMColors.color(GDLLMColors.CODE) : set = _set_code_color

## Search terms washed with the configured highlight color wherever they appear in the rendered text; empty renders plain. Driven by the session's log search (see GDLLMChatSession._highlight_search_labels).
var highlight_terms: PackedStringArray = PackedStringArray() : set = _set_highlight_terms

## Finished table rows set aside while the base class's remaining passes run, indexed by their TABLE_ROW_TOKEN (see _process_table_syntax).
var _protected_rows: PackedStringArray = PackedStringArray()

## Fence character of the open code block _preprocess_line is tracking, "" outside one: an info string is stripped only on an OPENING fence, because inside a block the same text is content and stripping it there would close the block early.
var _fence_char := ""

## Length of the open block's fence; a closing fence must be at least this many of the same character.
var _fence_count := 0


## MarkdownLabel connects its OWN meta_clicked handler, which runs first and — with assume_https_links on, its default — feeds anything it doesn't recognize to OS.shell_open("https://" + meta).
## That sent every project link to the web browser. Switching it off routes only the metas the library could not handle to `unhandled_link_clicked`, which is where the session picks them up; real URLs, header anchors, and checkboxes keep going through the library exactly as before.
func _init(markdown_text: String = "") -> void:
	super(markdown_text)
	assume_https_links = false


func _set_code_color(value: Color) -> void:
	code_color = value
	queue_update()


func _set_highlight_terms(value: PackedStringArray) -> void:
	if value == highlight_terms:
		return
	highlight_terms = value
	queue_update()


func _convert_markdown(source_text: String = "") -> String:
	# Every token restores within its own line, so clearing here only keeps re-renders from growing the stash forever.
	_protected_rows.clear()
	_fence_char = ""
	_fence_count = 0
	# Color the [code] spans/blocks MarkdownLabel emits.
	var bbcode := super._convert_markdown(source_text) \
		.replace("[code]", "[code][color=#%s]" % code_color.to_html(false)) \
		.replace("[/code]", "[/color][/code]")
	# Linkify before highlighting, so the search walk steps over the [url] tags as markup and still washes the text inside them.
	bbcode = GDLLMLinks.linkify(bbcode)
	if highlight_terms.is_empty():
		return bbcode
	return GDLLMMarkdown.highlight_bbcode(bbcode, highlight_terms)


## The base class only recognizes a BARE fence, so a language-tagged one (```gdscript — how models open virtually every code block) never opened a block and its contents were rendered as prose; stripping the tag here, in the base's own before-any-syntax hook, hands its bare-fence logic a line it handles correctly.
## A closing fence stays bare by construction, so only the opening line is ever rewritten; everything else passes through untouched.
func _preprocess_line(line: String) -> String:
	var stripped := line.strip_edges()
	if _fence_char.is_empty():
		for character in ["`", "~"]:
			var count := _leading_fence_length(stripped, character)
			if count > 0:
				_fence_char = character
				_fence_count = count
				return character.repeat(count)
	elif stripped.length() >= _fence_count and stripped.count(_fence_char) == stripped.length():
		_fence_char = ""
		_fence_count = 0
	return line


## The opening-fence recognition _preprocess_line applies: three or more leading fence characters, and — for backticks, per CommonMark — no backtick in the info string; 0 when the line opens nothing.
func _leading_fence_length(stripped_line: String, character: String) -> int:
	var count := 0
	while count < stripped_line.length() and stripped_line[count] == character:
		count += 1
	if count < 3:
		return 0
	if character == "`" and character in stripped_line.substr(count):
		return 0
	return count


## Replaces the base table pass with one that formats each cell in isolation: run on the assembled row, the base class's line-wide passes pair `_`/`*`/backtick spans across cells and read [cell](2, 2) as a markdown link, splicing the table's own tags apart — rendered as engine push_cell/pop error spam on every load of a session whose reply holds a table.
## The state machine (base-class flags included) matches the base pass exactly; only the cell emission differs, and the finished row hides behind a TABLE_ROW_TOKEN until _process_custom_syntax so no later pass re-scans it.
func _process_table_syntax(line: String) -> String:
	if line.count("|") < 2:
		if _within_table:
			_within_table = false
			return "[/table]\n" + line
		return line
	_table_row += 1
	var split_line := line.trim_prefix("|").trim_suffix("|").split("|")
	var processed_line := ""
	if not _within_table:
		processed_line += "[table=%d]\n" % split_line.size()
		_within_table = true
	elif _table_row == 1:
		# The delimiter row only marks the header; it renders nothing.
		var is_delimiter := true
		for cell in split_line:
			var stripped_cell: String = cell.strip_edges()
			if stripped_cell.count("-") + stripped_cell.count(":") != stripped_cell.length():
				is_delimiter = false
				break
		if is_delimiter:
			_skip_line_break = true
			return ""
	for cell in split_line:
		processed_line += "[cell]%s[/cell]" % _process_cell_syntax(cell.strip_edges())
	_protected_rows.append(processed_line)
	return TABLE_ROW_TOKEN % (_protected_rows.size() - 1)


## One cell's inline syntax — code, image, link, emphasis — in the base class's own pass order.
func _process_cell_syntax(cell: String) -> String:
	var processed_cell := _process_inline_code_syntax(cell)
	processed_cell = _process_image_syntax(processed_cell)
	processed_cell = _process_link_syntax(processed_cell)
	return _process_text_formatting_syntax(processed_cell)


## The base class's after-every-pass hook: restore the rows the table pass set aside, cells already formatted.
func _process_custom_syntax(line: String) -> String:
	for i in _protected_rows.size():
		line = line.replace(TABLE_ROW_TOKEN % i, _protected_rows[i])
	return line
