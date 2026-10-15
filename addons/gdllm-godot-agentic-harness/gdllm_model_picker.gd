@tool
class_name GDLLMModelPicker
extends Button
## A dropdown-styled button that opens a searchable model list: a filter field over an ItemList of qualified "source::model" ids, each shown by its friendly label with the exact id as its tooltip. Used by each session's model picker and by the Effort Configuration and Favorite Models dialogs' add-model rows.
## The picker only offers and reports; the owner decides what a choice means. It shows `current` (starred when a favorite) or `placeholder` when that's empty, and emits model_chosen for every pick — including a re-pick of `current`, which the owner may treat as a no-op.

signal model_chosen(qualified: String) ## A model was picked from the list (click, double-click, or Enter).

const POPUP_SIZE := Vector2i(380, 320) ## The popup's floor size; it widens to the button when the button is wider.

var placeholder := "Select model..." ## Button text while `current` is empty.
var hint := "" ## Standing tooltip text; when `current` is set it follows a first line naming the exact qualified id, which the clipped label can't show.
var mark_favorites := true ## Star the stored favorites on the button and in the list. Off where a star would misinform, e.g. the Favorite Models dialog's own add list, whose unsaved edits the stored list doesn't reflect yet.

var _models := PackedStringArray() ## The ordered qualified ids the list offers.
var _current := "" ## The highlighted qualified id; see set_current.
var _popup: PopupPanel ## Built lazily on first open.
var _search_edit: LineEdit
var _item_list: ItemList
var _filtered := PackedStringArray() ## The qualified ids currently shown, index-aligned with _item_list.


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	# A long model name must never set the row's minimum width: in the dock, the row's minimum is the dock's, and a dock too wide for its slot sends the editor's dock layout into an unconverging relayout loop that hangs the whole editor at boot (100% CPU in text-server errors). Clip instead — the popup still shows full names.
	clip_text = true
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pressed.connect(_toggle_popup)
	draw.connect(_draw_arrow)


func _ready() -> void:
	_reserve_arrow_space()
	refresh()


## Replace the offered ids, in display order (the caller applies any favorites ordering), and repaint the button.
func set_models(models: PackedStringArray) -> void:
	_models = models
	refresh()


func get_models() -> PackedStringArray:
	return _models


## Set the id the button shows and the open list highlights; "" shows the placeholder.
func set_current(qualified: String) -> void:
	_current = qualified
	refresh()


func get_current() -> String:
	return _current


## Repaint the button's text, star, and tooltip from the current state and stored favorites (call after a favorites edit).
func refresh() -> void:
	if _current == "":
		icon = null
		text = placeholder
		tooltip_text = hint
		return
	var label := GDLLMSources.label_for(_current)
	icon = null
	text = label
	if mark_favorites and GDLLMFavorites.get_list().has(_current):
		var star := favorite_icon()
		if star != null:
			icon = star
		else:
			text = "★ " + label
	tooltip_text = "Current model: %s" % _current + ("\n" + hint if hint != "" else "")


## The editor's star icon marking a favorite, or null when the theme lacks it (callers fall back to a text star).
static func favorite_icon() -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon("Favorites", "EditorIcons"):
		return theme.get_icon("Favorites", "EditorIcons")
	return null


## Dress the button in the OptionButton's styleboxes so it matches neighboring dropdowns, each widened on the right by the theme arrow's width (the room an OptionButton reserves internally) so clipped text ends before the arrow instead of under it. The type is named explicitly because a theme_type_variation of "OptionButton" is ignored unless the theme declares it as a variation.
func _reserve_arrow_space() -> void:
	if not has_theme_icon("arrow", "OptionButton"):
		return
	var arrow_width := get_theme_icon("arrow", "OptionButton").get_width()
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := get_theme_stylebox(state, "OptionButton").duplicate() as StyleBox
		style.content_margin_right = style.get_margin(SIDE_RIGHT) + arrow_width
		add_theme_stylebox_override(state, style)


## Draw the theme's OptionButton arrow at the trailing edge, placed and tinted per button state the way OptionButton draws its own; a plain Button has no arrow of its own.
func _draw_arrow() -> void:
	if not has_theme_icon("arrow", "OptionButton"):
		return
	var arrow := get_theme_icon("arrow", "OptionButton")
	var tint := Color.WHITE
	if get_theme_constant("modulate_arrow", "OptionButton") != 0:
		var color_name := "font_focus_color" if has_focus() else "font_color"
		match get_draw_mode():
			BaseButton.DRAW_PRESSED:
				color_name = "font_pressed_color"
			BaseButton.DRAW_HOVER, BaseButton.DRAW_HOVER_PRESSED:
				color_name = "font_hover_color"
			BaseButton.DRAW_DISABLED:
				color_name = "font_disabled_color"
		tint = get_theme_color(color_name, "OptionButton")
	var margin := get_theme_constant("arrow_margin", "OptionButton")
	var at := Vector2(size.x - arrow.get_width() - margin, floorf(absf(size.y - arrow.get_height()) / 2.0))
	draw_texture(arrow, at, tint)


func _ensure_popup() -> void:
	if is_instance_valid(_popup):
		return
	_popup = PopupPanel.new()
	add_child(_popup)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(POPUP_SIZE)
	vbox.add_theme_constant_override("separation", 6)
	_popup.add_child(vbox)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search model..."
	_search_edit.clear_button_enabled = true
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon("Search", "EditorIcons"):
		_search_edit.right_icon = theme.get_icon("Search", "EditorIcons")
	_search_edit.text_changed.connect(_filter)
	_search_edit.gui_input.connect(_on_search_gui_input)
	vbox.add_child(_search_edit)

	_item_list = ItemList.new()
	_item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_item_list.allow_reselect = true
	_item_list.item_clicked.connect(_on_item_clicked)
	_item_list.item_activated.connect(_choose)
	_item_list.gui_input.connect(_on_list_gui_input)
	vbox.add_child(_item_list)


## Open the popup beneath the button with an empty filter, or close it if it's already open.
func _toggle_popup() -> void:
	if disabled:
		return
	if is_instance_valid(_popup) and _popup.visible:
		_popup.hide()
		return
	_ensure_popup()
	_search_edit.text = ""
	_filter("")
	var at := Vector2i(get_screen_position())
	var button_size := Vector2i(size)
	_popup.popup(Rect2i(at.x, at.y + button_size.y, maxi(button_size.x, POPUP_SIZE.x), POPUP_SIZE.y))
	_search_edit.call_deferred("grab_focus")


## Show the models whose label or qualified id contains `filter_text` (case-insensitive), selecting `current` when shown, else the first match while filtering.
func _filter(filter_text: String) -> void:
	if not is_instance_valid(_item_list):
		return
	_item_list.clear()
	_filtered.clear()
	var needle := filter_text.strip_edges().to_lower()
	var favorites := GDLLMFavorites.get_list() if mark_favorites else PackedStringArray()
	var star := favorite_icon()
	var selected := -1
	for qid in _models:
		var label := GDLLMSources.label_for(qid)
		if needle != "" and not label.to_lower().contains(needle) and not qid.to_lower().contains(needle):
			continue
		_filtered.append(qid)
		var index: int
		if favorites.has(qid):
			index = _item_list.add_item(label, star) if star != null else _item_list.add_item("★ " + label)
		else:
			index = _item_list.add_item(label)
		_item_list.set_item_tooltip(index, qid)
		if qid == _current:
			selected = index
	if selected == -1 and needle != "" and _item_list.item_count > 0:
		selected = 0
	if selected != -1:
		_item_list.select(selected)
		_item_list.ensure_current_is_visible()


## Keyboard control from the search field: Up/Down move the selection, Enter picks it (or the first match), Escape closes.
func _on_search_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.is_pressed() and not event.is_echo()):
		return
	var selected := _item_list.get_selected_items()
	match (event as InputEventKey).keycode:
		KEY_DOWN, KEY_UP:
			if _item_list.item_count > 0:
				var step := 1 if (event as InputEventKey).keycode == KEY_DOWN else -1
				var target := 0 if selected.is_empty() else clampi(selected[0] + step, 0, _item_list.item_count - 1)
				_item_list.select(target)
				_item_list.ensure_current_is_visible()
			_search_edit.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			if not selected.is_empty():
				_choose(selected[0])
			elif _item_list.item_count > 0:
				_choose(0)
			_search_edit.accept_event()
		KEY_ESCAPE:
			_popup.hide()
			_search_edit.accept_event()


func _on_list_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo() and (event as InputEventKey).keycode == KEY_ESCAPE:
		_popup.hide()
		_item_list.accept_event()


func _on_item_clicked(index: int, _at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_LEFT:
		_choose(index)


## Close the popup and report the model at `index` of the filtered list.
func _choose(index: int) -> void:
	_popup.hide()
	if index >= 0 and index < _filtered.size():
		model_chosen.emit(_filtered[index])
