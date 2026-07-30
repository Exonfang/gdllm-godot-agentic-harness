@tool
class_name GDLLMFavorites
## Pure logic over the user's favorite models: an ordered list of qualified "source::model" ids, edited in the dock's Favorite Models dialog.
## Every model picker floats these to the top in exactly this order, each marked with a star; the order is the user's own and is never re-sorted.
## A favorite whose model no sweep currently reports simply has nothing to float — it stays stored so it resurfaces when its source returns.

const SETTINGS_KEY := "gdllm/models/favorites_fallback" ## EditorSettings key holding the list as a JSON array string (["source::model", ...] in display order). Named "…_fallback" like the sources and efforts keys — the Favorite Models dialog is the primary editor; this is the readable fallback.


## The stored favorites in display order, or an empty list when nothing is stored yet or the stored value is unparseable.
static func get_list() -> PackedStringArray:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTINGS_KEY):
		return PackedStringArray()
	var parsed: Variant = JSON.parse_string(String(es.get_setting(SETTINGS_KEY)))
	return PackedStringArray(parsed) if parsed is Array else PackedStringArray()


## Persist the favorites as a JSON string. Writing it emits EditorSettings.settings_changed, which is how every open session's model picker picks the change up (see GDLLMChatDock._on_editor_settings_changed).
static func save_list(favorites: PackedStringArray) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTINGS_KEY, JSON.stringify(Array(favorites)))


## `models` reordered for a picker: the favorites it carries first, in stored order, then the rest in their given order. A favorite `models` doesn't carry is skipped, not invented — pickers only offer what a sweep reported.
static func apply_order(models: PackedStringArray) -> PackedStringArray:
	var favorites := get_list()
	var out := PackedStringArray()
	for qid in favorites:
		if models.has(qid):
			out.append(qid)
	for qid in models:
		if not favorites.has(qid):
			out.append(qid)
	return out
