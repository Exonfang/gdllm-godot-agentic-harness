@tool
class_name GDLLMTilemap extends RefCounted
## Engine-truth access to TILEMAP content — the one part of a scene every read tool elides: `tile_map_data` is base64 over a packed binary struct, 83–90% of a real project's world-scene bytes, and before this the model could not tell which tiles a level holds at all.
## The keystone is that the ENGINE decodes the format for us: an off-tree TileMapLayer handed the bytes yields every cell through its own API (probe-measured byte-identical round trip), so nothing here parses the struct by hand.
## Naming rides the same principle: a TileSet's sources carry their resource_name or their texture's file name, which recovers exactly the meaning gameplay scripts encode as bare integers.
## Every method is static — this is a namespace, not an instance.

## Cell area past which a grid render is withheld and the `rect` window named instead, since a grid is roughly one character per cell.
const MAX_GRID_CELLS := 4000
## Layer names listed before the empty-layer line collapses to a count.
const MAX_LAYERS_LISTED := 24
## Sources listed per TileSet before the rest collapse to a count.
const MAX_SOURCES_LISTED := 40
## Per-source entries on one layer's tiles line before the rest collapse to a count.
const MAX_SOURCES_PER_LINE := 12
## Scene paths listed for one scenes-collection source before the rest collapse to a count.
const MAX_SCENE_TILES_LISTED := 12
## Grid symbols assigned to sources in ascending id order; sources past the palette share "?" with a legend note.
const GRID_SYMBOLS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"
## The three describe_tileset sections `kind` selects between.
const KIND_SECTIONS: Array[String] = ["sources", "terrains", "custom_data"]
## Tolerant spellings for each section, since a model asks in its own words.
const KIND_ALIASES := {
	"source": "sources", "sources": "sources", "tiles": "sources", "atlas": "sources", "atlases": "sources",
	"terrain": "terrains", "terrains": "terrains", "terrain_set": "terrains", "terrain_sets": "terrains",
	"custom_data": "custom_data", "custom": "custom_data", "data": "custom_data", "metadata": "custom_data",
}
## TileSet.tile_shape values as words, indexed by the enum.
const TILE_SHAPE_NAMES: Array[String] = ["square", "isometric", "half-offset square", "hexagon"]
## TileSet terrain-set modes as words, indexed by the enum.
const TERRAIN_MODE_NAMES: Array[String] = ["match corners and sides", "match corners", "match sides"]
## Explicit cells per edit_tilemap set/erase call — a bulk shape belongs to fill/replace, and arguments are permanent history.
const MAX_SET_CELLS := 200
## Rect area cap for edit_tilemap's fill/erase/terrain rects.
const MAX_FILL_AREA := 10000
## Terrain cells per edit_tilemap call — each is an engine matching step.
const MAX_TERRAIN_CELLS := 200
## The one action spec each edit_tilemap call carries.
const EDIT_ACTION_KEYS: Array[String] = ["cells", "fill", "replace", "erase", "terrain"]


## Collect every TileMapLayer stored in a packed scene's state — no instantiation, so no script runs.
## Legacy TileMap nodes are counted rather than decoded (deprecated, different storage), and instanced sub-scenes are flagged since SceneState does not descend into them.
static func layers_from_state(state: SceneState) -> Dictionary:
	var layers: Array = []
	var legacy := 0
	var has_instances := false
	var by_path := {}
	var scripts_by_path := {}
	for i in state.get_node_count():
		if i > 0 and state.get_node_instance(i) != null:
			has_instances = true
		var path := _state_path(state, i)
		var type := String(state.get_node_type(i))
		for j in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, j)) == "script":
				var script: Variant = state.get_node_property_value(i, j)
				if script is Script:
					scripts_by_path[path] = (script as Script).resource_path
		if type == "TileMap":
			legacy += 1
			continue
		if type == "" or not ClassDB.is_parent_class(type, "TileMapLayer"):
			continue
		var record := _blank_record(path)
		for j in state.get_node_property_count(i):
			var prop := String(state.get_node_property_name(i, j))
			var value: Variant = state.get_node_property_value(i, j)
			match prop:
				"tile_map_data":
					if value is PackedByteArray:
						record["data"] = value
				"tile_set":
					if value is TileSet:
						record["tile_set"] = value
				"visible":
					record["hidden"] = value is bool and value == false
				"enabled":
					record["disabled"] = value is bool and value == false
		by_path[path] = record
		layers.append(record)
	for record: Dictionary in layers:
		record["script"] = String(scripts_by_path.get(record["path"], ""))
	# A NodePath property resolving to a layer is the file's own evidence that other code holds it — the display-layer pattern where a script fills the referenced layer at runtime.
	for i in state.get_node_count():
		var owner := _state_path(state, i)
		for j in state.get_node_property_count(i):
			var value: Variant = state.get_node_property_value(i, j)
			if not value is NodePath:
				continue
			var target := _join_node_path(owner, String(value))
			if target == "" or target == owner or not by_path.has(target):
				continue
			(by_path[target]["refs"] as Array).append({
				"property": String(state.get_node_property_name(i, j)),
				"by": owner,
				"by_script": String(scripts_by_path.get(owner, "")),
			})
	return {"layers": layers, "legacy": legacy, "has_instances": has_instances}


## Collect every TileMapLayer under a live root node — same record shape as the state walk, so the composer never cares which mode fed it.
## The layer's data is snapshotted through the property (probe-verified current after live edits) and decoded off-tree, so composing never touches the live node again.
static func layers_from_live(root: Node) -> Dictionary:
	var layers: Array = []
	var legacy := 0
	var nodes: Array = []
	_collect_nodes(root, nodes)
	var by_node := {}
	for node: Node in nodes:
		if node.get_class() == "TileMap":
			legacy += 1
			continue
		if not node is TileMapLayer:
			continue
		var layer := node as TileMapLayer
		var record := _blank_record(String(root.get_path_to(node)))
		record["script"] = _script_path(node)
		record["data"] = layer.tile_map_data
		record["tile_set"] = layer.tile_set
		record["hidden"] = not layer.visible
		record["disabled"] = not layer.enabled
		by_node[node] = record
		layers.append(record)
	for node: Node in nodes:
		for prop: Dictionary in node.get_property_list():
			if int(prop.get("type", 0)) != TYPE_NODE_PATH:
				continue
			var value: Variant = node.get(String(prop["name"]))
			if not value is NodePath or (value as NodePath).is_empty():
				continue
			var target := node.get_node_or_null(value)
			if target == null or target == node or not by_node.has(target):
				continue
			(by_node[target]["refs"] as Array).append({
				"property": String(prop["name"]),
				"by": String(root.get_path_to(node)),
				"by_script": _script_path(node),
			})
	return {"layers": layers, "legacy": legacy, "has_instances": false}


## Decode one layer's stored bytes through a throwaway TileMapLayer — the engine's own parser, never a hand-rolled one.
static func decode(data: PackedByteArray) -> Dictionary:
	var layer := TileMapLayer.new()
	if not data.is_empty():
		layer.tile_map_data = data
	var cells := layer.get_used_cells()
	var by_source := {}
	var map := {}
	var alt := 0
	for cell: Vector2i in cells:
		var sid := layer.get_cell_source_id(cell)
		by_source[sid] = int(by_source.get(sid, 0)) + 1
		map[cell] = sid
		if layer.get_cell_alternative_tile(cell) != 0:
			alt += 1
	var out := {
		"rect": layer.get_used_rect(),
		"count": cells.size(),
		"by_source": by_source,
		"cells": map,
		"alt_count": alt,
		# A sizeable payload yielding zero cells is corruption or a format-version mismatch, and must never read as an empty layer.
		"undecodable": data.size() > 2 and cells.is_empty(),
	}
	layer.free()
	return out


## Map every source id in a TileSet to its human name — resource_name first, else the texture's file name, the route that recovers meaning from a tileset nobody labeled.
static func source_names(tile_set: Variant) -> Dictionary:
	var names := {}
	if tile_set == null or not tile_set is TileSet:
		return names
	var ts := tile_set as TileSet
	for i in ts.get_source_count():
		var sid := ts.get_source_id(i)
		var name := _source_name(ts.get_source(sid))
		if name != "":
			names[sid] = name
	return names


## Compose the read_tilemap report: an all-layers overview, or one layer's grid when `layer_query` (or a window with a single tiled layer) selects one.
static func compose_report(origin: String, scan: Dictionary, layer_query: String, window: Rect2i, has_window: bool) -> String:
	var layers: Array = scan["layers"]
	if layer_query == "" and has_window:
		var tiled: Array = layers.filter(func(r: Dictionary) -> bool: return not (r["data"] as PackedByteArray).is_empty())
		if tiled.size() == 1:
			return _compose_zoom(origin, tiled[0], window, has_window)
		# No tiled layer means no grid to window at all — pointing at a layer list that would render empty is a dead end.
		if tiled.is_empty():
			return "Error: no layer in this scene stores any tiles, so there is no grid for \"rect\" to window. Drop \"rect\" for the overview, which lists the scene's %d TileMapLayer node(s) and their state." % layers.size()
		return "Error: \"rect\" windows ONE layer's grid, and this scene has %d layers with tiles — pass \"layer\" naming one of: %s." % [tiled.size(), _layer_name_list(tiled)]
	if layer_query != "":
		var matched := match_layer(layers, layer_query)
		if matched.has("error"):
			return String(matched["error"])
		return _compose_zoom(origin, matched["layer"], window, has_window)
	return _compose_overview(origin, scan)


## Compose the describe_tileset report — header always, then the sections `kinds` selects, names narrowed by `filter`.
static func describe(tile_set: TileSet, origin: String, filter: String, kinds: PackedStringArray) -> String:
	var selected := kinds if not kinds.is_empty() else PackedStringArray(KIND_SECTIONS)
	var lines: Array = [_tileset_header(tile_set, origin)]
	if not kinds.is_empty():
		lines.append("Showing only: %s — the other sections exist and were not searched." % ", ".join(kinds))
	if filter != "":
		lines.append("Filtered to names containing \"%s\"." % filter)
	lines.append("")
	var shown := 0
	if selected.has("sources"):
		shown += _append_sources(lines, tile_set, filter)
	if selected.has("terrains"):
		shown += _append_terrains(lines, tile_set, filter)
	if selected.has("custom_data"):
		shown += _append_custom_data(lines, tile_set, filter)
	if filter != "" and shown == 0:
		lines.append("No name in the selected section(s) contains \"%s\" — %d source(s), %d terrain set(s), and %d custom data layer(s) exist in this TileSet." % [filter, tile_set.get_source_count(), tile_set.get_terrain_sets_count(), tile_set.get_custom_data_layers_count()])
	return "\n".join(PackedStringArray(lines))


## Normalize the `kind` argument to canonical section names, refusing an unknown one with the three that exist rather than quietly widening.
static func normalize_kinds(raw: PackedStringArray) -> Dictionary:
	var out := PackedStringArray()
	for entry in raw:
		var key := entry.strip_edges().to_lower()
		if key == "":
			continue
		if not KIND_ALIASES.has(key):
			return {"error": "Error: unknown kind \"%s\" — the sections are: %s. Omit `kind` for all of them." % [entry, ", ".join(KIND_SECTIONS)]}
		var canonical := String(KIND_ALIASES[key])
		if not out.has(canonical):
			out.append(canonical)
	return {"kinds": out}


## "source 9 (stone_wall)", or bare "source 9" when no name is known.
static func source_label(sid: int, names: Dictionary) -> String:
	var name := String(names.get(sid, ""))
	return "source %d (%s)" % [sid, name] if name != "" else "source %d" % sid


static func _blank_record(path: String) -> Dictionary:
	return {"path": path, "script": "", "data": PackedByteArray(), "tile_set": null, "hidden": false, "disabled": false, "refs": []}


## SceneState reports "./Pic"; the bare tree-relative form is what results display and models pass back.
static func _state_path(state: SceneState, i: int) -> String:
	var path := String(state.get_node_path(i))
	return path if path == "." else path.trim_prefix("./")


## Resolve a stored NodePath against its owner's tree-relative path, "" when it escapes the scene; subnames are irrelevant to which NODE is referenced.
static func _join_node_path(owner: String, np: String) -> String:
	if np.begins_with("/"):
		return ""
	var node_part := np.split(":")[0]
	var segments: Array = [] if owner == "." else Array(owner.split("/"))
	for seg in node_part.split("/", false):
		if seg == ".":
			continue
		if seg == "..":
			if segments.is_empty():
				return ""
			segments.pop_back()
		else:
			segments.append(seg)
	if segments.is_empty():
		return "."
	var parts := PackedStringArray()
	for seg in segments:
		parts.append(String(seg))
	return "/".join(parts)


static func _collect_nodes(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_collect_nodes(child, out)


static func _script_path(node: Node) -> String:
	var script: Variant = node.get_script()
	return (script as Script).resource_path if script is Script else ""


static func _source_name(source: TileSetSource) -> String:
	if source == null:
		return ""
	if source.resource_name != "":
		return source.resource_name
	if source is TileSetAtlasSource:
		var tex := (source as TileSetAtlasSource).texture
		# A texture embedded in the .tres has a "::"-suffixed path whose basename is noise, not a name.
		if tex != null and tex.resource_path != "" and not tex.resource_path.contains("::"):
			return tex.resource_path.get_file().get_basename()
	return ""


## Match one layer by exact path, then by unique name, then by unique substring — every ambiguity or miss lists the real paths, never a dead end.
static func match_layer(layers: Array, query: String) -> Dictionary:
	if layers.is_empty():
		return {"error": "Error: this scene has no TileMapLayer nodes to match \"%s\" against." % query}
	var lowered := query.to_lower()
	for record: Dictionary in layers:
		if String(record["path"]).to_lower() == lowered:
			return {"layer": record}
	var by_name: Array = layers.filter(func(r: Dictionary) -> bool: return String(r["path"]).get_file().to_lower() == lowered)
	if by_name.size() == 1:
		return {"layer": by_name[0]}
	if by_name.size() > 1:
		return {"error": "Error: %d layers are named \"%s\" — pass the full path of one: %s." % [by_name.size(), query, _layer_name_list(by_name)]}
	var by_substring: Array = layers.filter(func(r: Dictionary) -> bool: return String(r["path"]).to_lower().contains(lowered))
	if by_substring.size() == 1:
		return {"layer": by_substring[0]}
	if by_substring.size() > 1:
		return {"error": "Error: \"%s\" matches %d layers — pass the full path of one: %s." % [query, by_substring.size(), _layer_name_list(by_substring)]}
	return {"error": "Error: no TileMapLayer matches \"%s\". The layers are: %s." % [query, _layer_name_list(layers)]}


## `with_markers` rides the empty-layer overview line, where a hidden or disabled layer is often the whole answer to "why don't I see my tiles"; error listings stay bare.
static func _layer_name_list(layers: Array, with_markers := false) -> String:
	var names := PackedStringArray()
	for record: Dictionary in layers.slice(0, MAX_LAYERS_LISTED):
		var name := "\"%s\"" % String(record["path"])
		if with_markers and bool(record["hidden"]):
			name += " [hidden]"
		if with_markers and bool(record["disabled"]):
			name += " [disabled]"
		names.append(name)
	if layers.size() > MAX_LAYERS_LISTED:
		names.append("… %d more — describe_scene_file lists every layer node" % (layers.size() - MAX_LAYERS_LISTED))
	return ", ".join(names)


static func _rect_span(rect: Rect2i) -> String:
	return "x %d..%d, y %d..%d" % [rect.position.x, rect.position.x + rect.size.x - 1, rect.position.y, rect.position.y + rect.size.y - 1]


static func tileset_label(tile_set: Variant) -> String:
	if tile_set == null or not tile_set is TileSet:
		return "none"
	var path := (tile_set as TileSet).resource_path
	if path == "" or path.contains("::"):
		return "embedded in the scene"
	return path


## One layer's overview block: the head line with its markers, the tiles line, and any reference note.
static func _layer_block(record: Dictionary, decoded: Dictionary) -> Array:
	var head := "%s — %d cells in %s" % [record["path"], decoded["count"], _rect_span(decoded["rect"])]
	if String(record["script"]) != "":
		head += " [script %s]" % record["script"]
	if bool(record["hidden"]):
		head += " [hidden]"
	if bool(record["disabled"]):
		head += " [disabled]"
	var lines: Array = [head]
	if bool(decoded["undecodable"]):
		lines.append("  NOTE: its stored payload (%d bytes) decoded to no cells — possibly corrupt, or written by a different engine version." % (record["data"] as PackedByteArray).size())
		return lines
	lines.append("  tileset %s — %s" % [tileset_label(record["tile_set"]), _tiles_line(decoded, source_names(record["tile_set"]), record["tile_set"])])
	var ref_note := _refs_note(record)
	if ref_note != "":
		lines.append("  " + ref_note)
	return lines


static func _tiles_line(decoded: Dictionary, names: Dictionary, tile_set: Variant) -> String:
	var ids: Array = (decoded["by_source"] as Dictionary).keys()
	ids.sort()
	var parts := PackedStringArray()
	for sid: int in ids.slice(0, MAX_SOURCES_PER_LINE):
		parts.append("%d× %s" % [int(decoded["by_source"][sid]), source_label(sid, names)])
	if ids.size() > MAX_SOURCES_PER_LINE:
		parts.append("+%d more source(s) — pass \"layer\" to zoom this layer's full legend" % (ids.size() - MAX_SOURCES_PER_LINE))
	var line := "tiles: " + ", ".join(parts)
	if int(decoded["alt_count"]) > 0:
		line += "; %d flipped/alternative cell(s)" % int(decoded["alt_count"])
	if tile_set == null and not ids.is_empty():
		line += " (no TileSet assigned — source ids shown bare)"
	return line


## The derived-layer disclosure: a NodePath held by another node is the file's own evidence that code may regenerate this layer, the wall a write would otherwise hit silently.
## The consequence clause is appended once per report by _explain_first_ref — on the real project it repeated twelve times in one overview, ~1.4 KB of duplicate text, the same waste the import legend's dedup was measured against.
static func _refs_note(record: Dictionary) -> String:
	var refs: Array = record["refs"]
	if refs.is_empty():
		return ""
	var parts := PackedStringArray()
	for ref: Dictionary in refs:
		var holder := "the scene root" if String(ref["by"]) == "." else String(ref["by"])
		var part := "as \"%s\" by %s" % [ref["property"], holder]
		if String(ref["by_script"]) != "":
			part += " (script %s)" % ref["by_script"]
		parts.append(part)
	return "NOTE: referenced %s." % ", ".join(parts)


## Append the regeneration warning to the report's FIRST reference note, where it explains every one below it.
static func _explain_first_ref(lines: Array) -> void:
	for i in lines.size():
		if String(lines[i]).contains("NOTE: referenced"):
			lines[i] = String(lines[i]).trim_suffix(".") + " — whatever holds such a reference may fill or overwrite the referenced layer at runtime, so edits to any referenced layer can be regenerated over."
			return


static func _compose_overview(origin: String, scan: Dictionary) -> String:
	var layers: Array = scan["layers"]
	var lines: Array = [origin]
	var tiled: Array = []
	var empty: Array = []
	for record: Dictionary in layers:
		if (record["data"] as PackedByteArray).is_empty():
			empty.append(record)
		else:
			tiled.append(record)
	var head := "%d TileMapLayer node(s), %d with tiles." % [layers.size(), tiled.size()]
	if int(scan["legacy"]) > 0:
		head += " %d legacy TileMap node(s) (deprecated) are not decoded here — this tool reads TileMapLayer nodes." % int(scan["legacy"])
	if bool(scan["has_instances"]):
		head += " Instanced sub-scenes are not descended into — call read_tilemap on the instanced .tscn to see inside one."
	lines.append(head)
	if layers.is_empty():
		return "\n".join(PackedStringArray(lines))
	for record: Dictionary in tiled:
		lines.append("")
		lines.append_array(_layer_block(record, decode(record["data"])))
	if not empty.is_empty():
		lines.append("")
		lines.append("Layers with no tiles (%d): %s" % [empty.size(), _layer_name_list(empty, true)])
		for record: Dictionary in empty:
			var note := _refs_note(record)
			if note != "":
				lines.append("  \"%s\": %s" % [record["path"], note])
	if not tiled.is_empty():
		lines.append("")
		lines.append("Pass \"layer\" (a layer's name or path) for an ASCII grid of one layer's cell placement.")
	_explain_first_ref(lines)
	return "\n".join(PackedStringArray(lines))


static func _compose_zoom(origin: String, record: Dictionary, window: Rect2i, has_window: bool) -> String:
	var decoded := decode(record["data"])
	var lines: Array = [origin]
	lines.append_array(_layer_block(record, decoded))
	_explain_first_ref(lines)
	if int(decoded["count"]) == 0:
		if not bool(decoded["undecodable"]):
			lines.append("  This layer has no tiles.")
		return "\n".join(PackedStringArray(lines))
	var used: Rect2i = decoded["rect"]
	var view := window if has_window else used
	lines.append("")
	if view.get_area() > MAX_GRID_CELLS:
		lines.append("The grid spans %d×%d = %d cells, past the %d-cell view cap — pass \"rect\": [x, y, width, height] (in cells; the used rect is %s) to window it. The counts above cover the whole layer." % [view.size.x, view.size.y, view.get_area(), MAX_GRID_CELLS, _rect_span(used)])
		return "\n".join(PackedStringArray(lines))
	var window_note := " (window %s of used rect %s)" % [_rect_span(view), _rect_span(used)] if has_window else ""
	lines.append("Grid%s — columns are x %d..%d left to right, rows are y %d..%d top to bottom (y grows downward, as on screen); \".\" = empty:" % [window_note, view.position.x, view.position.x + view.size.x - 1, view.position.y, view.position.y + view.size.y - 1])
	lines.append_array(_grid_lines(decoded["cells"], source_names(record["tile_set"]), view))
	return "\n".join(PackedStringArray(lines))


## Render the window as symbol rows plus a legend with in-view counts, so two different frames never read as the same picture.
static func _grid_lines(cells: Dictionary, names: Dictionary, view: Rect2i) -> Array:
	var counts := {}
	for y in range(view.position.y, view.position.y + view.size.y):
		for x in range(view.position.x, view.position.x + view.size.x):
			var sid: Variant = cells.get(Vector2i(x, y))
			if sid != null:
				counts[int(sid)] = int(counts.get(int(sid), 0)) + 1
	if counts.is_empty():
		return ["(no cells in this window)"]
	var ids: Array = counts.keys()
	ids.sort()
	var symbol_of := {}
	for i in ids.size():
		symbol_of[ids[i]] = GRID_SYMBOLS[i] if i < GRID_SYMBOLS.length() else "?"
	var label_width := maxi(str(view.position.y).length(), str(view.position.y + view.size.y - 1).length())
	var rows: Array = []
	for y in range(view.position.y, view.position.y + view.size.y):
		var row := ""
		for x in range(view.position.x, view.position.x + view.size.x):
			var sid: Variant = cells.get(Vector2i(x, y))
			row += "." if sid == null else String(symbol_of[int(sid)])
		rows.append("y=%s: %s" % [str(y).lpad(label_width), row])
	rows.append("Legend:")
	var overflow := 0
	for i in ids.size():
		if i < GRID_SYMBOLS.length():
			rows.append("  %s = %s — %d cell(s) in view" % [symbol_of[ids[i]], source_label(int(ids[i]), names), int(counts[ids[i]])])
		else:
			overflow += 1
	if overflow > 0:
		rows.append("  ? = %d more source(s) past the symbol palette — narrow with \"rect\" to tell them apart." % overflow)
	return rows


static func _tileset_header(tile_set: TileSet, origin: String) -> String:
	var shape := TILE_SHAPE_NAMES[tile_set.tile_shape] if tile_set.tile_shape < TILE_SHAPE_NAMES.size() else "shape %d" % tile_set.tile_shape
	return "TileSet %s — %d×%d %s tiles; %d source(s), %d terrain set(s), %d custom data layer(s)." % [origin, tile_set.tile_size.x, tile_set.tile_size.y, shape, tile_set.get_source_count(), tile_set.get_terrain_sets_count(), tile_set.get_custom_data_layers_count()]


## Append the Sources section, returning how many entries the filter let through.
static func _append_sources(lines: Array, tile_set: TileSet, filter: String) -> int:
	var entries: Array = []
	for i in tile_set.get_source_count():
		var sid := tile_set.get_source_id(i)
		var source := tile_set.get_source(sid)
		var name := _source_name(source)
		if filter != "" and not name.to_lower().contains(filter.to_lower()):
			continue
		entries.append(_source_entry(sid, name, source))
	if entries.is_empty():
		lines.append("Sources: none" if filter == "" else "Sources: none matching the filter (of %d)." % tile_set.get_source_count())
		return 0
	var note := "" if entries.size() <= MAX_SOURCES_LISTED else " (%d of %d shown — pass a \"filter\" substring to narrow)" % [MAX_SOURCES_LISTED, entries.size()]
	lines.append("Sources (%d)%s:" % [entries.size(), note])
	for entry: String in entries.slice(0, MAX_SOURCES_LISTED):
		lines.append("  " + entry)
	return entries.size()


static func _source_entry(sid: int, name: String, source: TileSetSource) -> String:
	var label := "%d \"%s\"" % [sid, name] if name != "" else "%d (unnamed)" % sid
	if source is TileSetAtlasSource:
		var atlas := source as TileSetAtlasSource
		var tex_path := atlas.texture.resource_path if atlas.texture != null else ""
		var entry := "%s — atlas %s, %d tile(s)" % [label, tex_path if tex_path != "" else "(no texture)", atlas.get_tiles_count()]
		var alts := 0
		for t in atlas.get_tiles_count():
			alts += atlas.get_alternative_tiles_count(atlas.get_tile_id(t)) - 1
		if alts > 0:
			entry += ", %d alternative(s)" % alts
		return entry
	if source is TileSetScenesCollectionSource:
		var scenes := source as TileSetScenesCollectionSource
		var paths := PackedStringArray()
		for t in mini(scenes.get_scene_tiles_count(), MAX_SCENE_TILES_LISTED):
			var packed := scenes.get_scene_tile_scene(scenes.get_scene_tile_id(t))
			paths.append(packed.resource_path if packed != null else "(empty)")
		if scenes.get_scene_tiles_count() > MAX_SCENE_TILES_LISTED:
			paths.append("… %d more — read_file this TileSet's .tres for the rest" % (scenes.get_scene_tiles_count() - MAX_SCENE_TILES_LISTED))
		return "%s — scene collection, %d scene(s): %s" % [label, scenes.get_scene_tiles_count(), ", ".join(paths)]
	return "%s — %s" % [label, source.get_class()]


## Append the Terrain sets section, returning how many terrain names the filter let through.
static func _append_terrains(lines: Array, tile_set: TileSet, filter: String) -> int:
	if tile_set.get_terrain_sets_count() == 0:
		lines.append("Terrain sets: none")
		return 0
	var shown := 0
	var set_lines: Array = []
	for s in tile_set.get_terrain_sets_count():
		var terrains := PackedStringArray()
		for t in tile_set.get_terrains_count(s):
			var name := tile_set.get_terrain_name(s, t)
			if filter != "" and not name.to_lower().contains(filter.to_lower()):
				continue
			terrains.append("%d \"%s\"" % [t, name])
		if terrains.is_empty() and filter != "":
			continue
		shown += terrains.size()
		var mode := int(tile_set.get_terrain_set_mode(s))
		var mode_name := TERRAIN_MODE_NAMES[mode] if mode < TERRAIN_MODE_NAMES.size() else "mode %d" % mode
		set_lines.append("  set %d (%s): %d terrain(s) — %s" % [s, mode_name, tile_set.get_terrains_count(s), ", ".join(terrains)])
	if set_lines.is_empty():
		lines.append("Terrain sets: none matching the filter (of %d set(s))." % tile_set.get_terrain_sets_count())
		return 0
	lines.append("Terrain sets (%d):" % tile_set.get_terrain_sets_count())
	lines.append_array(set_lines)
	return shown


## Append the Custom data section, returning how many layer names the filter let through.
static func _append_custom_data(lines: Array, tile_set: TileSet, filter: String) -> int:
	if tile_set.get_custom_data_layers_count() == 0:
		lines.append("Custom data layers: none")
		return 0
	var parts := PackedStringArray()
	for i in tile_set.get_custom_data_layers_count():
		var name := tile_set.get_custom_data_layer_name(i)
		if filter != "" and not name.to_lower().contains(filter.to_lower()):
			continue
		parts.append("%d \"%s\" (%s)" % [i, name, type_string(tile_set.get_custom_data_layer_type(i))])
	if parts.is_empty():
		lines.append("Custom data layers: none matching the filter (of %d)." % tile_set.get_custom_data_layers_count())
		return 0
	lines.append("Custom data layers (%d): %s" % [tile_set.get_custom_data_layers_count(), ", ".join(parts)])
	return parts.size()


## ==== Editing (edit_tilemap) — the write half, built on the same engine-decoder keystone. ====
## The demand shape is measured, not guessed: the wild session this exists for asked to "change all dirt in the floor dual grid layer", then spent 45 interrupted turns hand-decoding tile_map_data bytes through five custom scripts — bulk transforms addressed by source name, never single cells by coordinate.
## Every edit decodes into an off-tree layer, applies through the engine's own API, and REBUILDS into a fresh layer before serializing: an in-place erase leaves a dead 12-byte slot (probe-measured), while the rebuild is byte-identical to what the engine itself writes.


## Parse a [x, y, width, height] rect value — one grammar for read windows and edit specs.
static func parse_rect(value: Variant) -> Dictionary:
	if not value is Array or (value as Array).size() != 4:
		return {"error": "Error: a rect takes [x, y, width, height] as four integers in cell coordinates, e.g. [-17, -13, 35, 39]."}
	var numbers: Array[int] = []
	for item in (value as Array):
		if not (item is int or item is float):
			return {"error": "Error: a rect takes [x, y, width, height] as four integers in cell coordinates, e.g. [-17, -13, 35, 39]."}
		numbers.append(int(item))
	if numbers[2] < 1 or numbers[3] < 1:
		return {"error": "Error: rect width and height must be at least 1 cell (got %d×%d)." % [numbers[2], numbers[3]]}
	return {"rect": Rect2i(numbers[0], numbers[1], numbers[2], numbers[3])}


## Parse one [x, y] cell coordinate.
static func parse_cell(value: Variant, label: String) -> Dictionary:
	if value is Array and (value as Array).size() == 2 and ((value as Array)[0] is int or (value as Array)[0] is float) and ((value as Array)[1] is int or (value as Array)[1] is float):
		return {"cell": Vector2i(int((value as Array)[0]), int((value as Array)[1]))}
	return {"error": "Error: %s takes an [x, y] pair of integers." % label}


## Resolve a source given by id or NAME against the layer's TileSet — by name is what the wild demand used ("all dirt"), and a wrong id is invisible tiles at runtime, so an id the TileSet lacks is refused with the real list.
static func resolve_source(tile_set: Variant, value: Variant, names: Dictionary) -> Dictionary:
	var has_set := tile_set is TileSet
	if value is int or value is float or (value is String and String(value).is_valid_int()):
		var sid := int(value) if not value is String else String(value).to_int()
		if has_set and not (tile_set as TileSet).has_source(sid):
			return {"error": "Error: this TileSet has no source %d. Its sources are: %s." % [sid, _source_id_list(tile_set as TileSet, names)]}
		var note := "" if has_set else "the layer has no TileSet, so source %d could not be validated" % sid
		return {"id": sid, "note": note}
	if not value is String:
		return {"error": "Error: a source is an integer id or a name string."}
	if not has_set:
		return {"error": "Error: this layer has no TileSet, so source names cannot be resolved — pass a numeric source id."}
	var query := String(value).strip_edges().to_lower()
	var exact := -1
	var partial: Array[int] = []
	for sid: int in names:
		var name := String(names[sid]).to_lower()
		if name == query:
			exact = sid
		elif name.contains(query):
			partial.append(sid)
	if exact >= 0:
		return {"id": exact, "note": "\"%s\" resolved to %s" % [value, source_label(exact, names)]}
	if partial.size() == 1:
		return {"id": partial[0], "note": "\"%s\" resolved to %s" % [value, source_label(partial[0], names)]}
	if partial.size() > 1:
		var options := PackedStringArray()
		for sid in partial:
			options.append(source_label(sid, names))
		return {"error": "Error: \"%s\" matches several sources — pass one of: %s." % [value, ", ".join(options)]}
	return {"error": "Error: no source is named \"%s\". The sources are: %s." % [value, _source_id_list(tile_set as TileSet, names)]}


static func _source_id_list(tile_set: TileSet, names: Dictionary) -> String:
	var parts := PackedStringArray()
	for i in mini(tile_set.get_source_count(), MAX_SOURCES_LISTED):
		parts.append(source_label(tile_set.get_source_id(i), names))
	# A disambiguation list that silently ends is a completeness claim — the name the caller wanted may be exactly the one past the cap.
	if tile_set.get_source_count() > MAX_SOURCES_LISTED:
		parts.append("… %d more — describe_tileset with a \"filter\" substring lists the rest" % (tile_set.get_source_count() - MAX_SOURCES_LISTED))
	return ", ".join(parts)


## Resolve a terrain by name (searched across every set) or index, with the set disambiguated only when it must be.
static func resolve_terrain(tile_set: Variant, value: Variant, set_arg: Variant) -> Dictionary:
	if not tile_set is TileSet:
		return {"error": "Error: this layer has no TileSet, so there are no terrains to paint."}
	var ts := tile_set as TileSet
	if ts.get_terrain_sets_count() == 0:
		return {"error": "Error: this TileSet defines no terrain sets, so there is nothing to terrain-match — use cells/fill/replace with plain sources instead."}
	var wanted_set := int(set_arg) if (set_arg is int or set_arg is float) else -1
	if value is int or value is float:
		var s := wanted_set if wanted_set >= 0 else 0
		if s >= ts.get_terrain_sets_count() or int(value) >= ts.get_terrains_count(s) or int(value) < 0:
			return {"error": "Error: terrain %d does not exist in terrain set %d. %s" % [int(value), s, _terrain_list(ts)]}
		return {"set": s, "terrain": int(value), "name": ts.get_terrain_name(s, int(value))}
	if not value is String:
		return {"error": "Error: a terrain is a name string or an integer index."}
	var query := String(value).strip_edges().to_lower()
	var hits: Array = []
	for s in ts.get_terrain_sets_count():
		if wanted_set >= 0 and s != wanted_set:
			continue
		for t in ts.get_terrains_count(s):
			if ts.get_terrain_name(s, t).to_lower() == query:
				hits.append({"set": s, "terrain": t, "name": ts.get_terrain_name(s, t)})
	if hits.size() == 1:
		return hits[0]
	if hits.size() > 1:
		return {"error": "Error: \"%s\" names a terrain in %d terrain sets — pass terrain_set to pick one." % [value, hits.size()]}
	return {"error": "Error: no terrain is named \"%s\". %s" % [value, _terrain_list(ts)]}


static func _terrain_list(ts: TileSet) -> String:
	var parts := PackedStringArray()
	for s in ts.get_terrain_sets_count():
		for t in ts.get_terrains_count(s):
			parts.append("set %d: %d \"%s\"" % [s, t, ts.get_terrain_name(s, t)])
	return "The terrains are: %s." % ", ".join(parts)


## Pick the atlas coords for a placement: given coords validated against the source, a single-tile source inferred, a multi-tile source refused with its tiles — a guessed tile is painted pixels.
## The refusal consults the LAYER's existing cells of that source first, because the wild rounds showed both failure modes a bare tile list produces: one session wrote a custom probe script (twice, in two rounds) to learn "existing grass uses (0, 3)", and another guessed (0, 0) — wrong — and shipped it with every report reading as success.
static func resolve_atlas(tile_set: Variant, sid: int, given: Variant, names: Dictionary, data := PackedByteArray()) -> Dictionary:
	var source: TileSetSource = (tile_set as TileSet).get_source(sid) if tile_set is TileSet and (tile_set as TileSet).has_source(sid) else null
	if given != null:
		var parsed := parse_cell(given, "atlas")
		if parsed.has("error"):
			return parsed
		var coords: Vector2i = parsed["cell"]
		if source is TileSetAtlasSource and not (source as TileSetAtlasSource).has_tile(coords):
			return {"error": "Error: %s has no tile at atlas %s. Its tiles are: %s." % [source_label(sid, names), coords, _atlas_tile_list(source as TileSetAtlasSource)]}
		return {"atlas": coords}
	if source is TileSetAtlasSource:
		var atlas := source as TileSetAtlasSource
		if atlas.get_tiles_count() == 1:
			return {"atlas": atlas.get_tile_id(0)}
		var hint := " For terrain tiles, the terrain action picks matched tiles itself." if tile_set is TileSet and (tile_set as TileSet).get_terrain_sets_count() > 0 else ""
		return {"error": "Error: %s has %d tiles, so \"atlas\" must say which one: %s.%s%s" % [source_label(sid, names), atlas.get_tiles_count(), _atlas_tile_list(atlas), _atlas_usage_note(data, sid), hint]}
	if source is TileSetScenesCollectionSource:
		return {"error": "Error: %s is a scene collection — placing scene tiles is not supported; scene-tile cells can be erased or replaced FROM, not placed." % source_label(sid, names)}
	# No TileSet to consult: (0, 0) is the only defensible default, and the caller discloses it.
	return {"atlas": Vector2i.ZERO, "note": "no TileSet to consult — atlas defaulted to (0, 0)"}


## The atlas coords a replace would carry into the target source but the target has no tile at — written anyway they are valid data the renderer draws as nothing, so the gaps are refused with their counts before any write.
static func replace_atlas_gaps(record: Dictionary, from_id: int, to_id: int, rect: Variant) -> Dictionary:
	if not record["tile_set"] is TileSet or not (record["tile_set"] as TileSet).has_source(to_id):
		return {}
	var target: TileSetSource = (record["tile_set"] as TileSet).get_source(to_id)
	if not target is TileSetAtlasSource:
		return {}
	var layer := TileMapLayer.new()
	if not (record["data"] as PackedByteArray).is_empty():
		layer.tile_map_data = record["data"]
	var gaps := {}
	for cell: Vector2i in layer.get_used_cells():
		if layer.get_cell_source_id(cell) != from_id:
			continue
		if rect is Rect2i and not (rect as Rect2i).has_point(cell):
			continue
		var coords := layer.get_cell_atlas_coords(cell)
		if not (target as TileSetAtlasSource).has_tile(coords):
			gaps[coords] = int(gaps.get(coords, 0)) + 1
	layer.free()
	return gaps


## The layer's own answer to "which tile": how its existing cells of this source are distributed across atlas coords, biggest first — "" when the layer holds none, since there is nothing to consult.
static func _atlas_usage_note(data: PackedByteArray, sid: int) -> String:
	if data.is_empty():
		return ""
	var layer := TileMapLayer.new()
	layer.tile_map_data = data
	var tally := {}
	var total := 0
	for cell: Vector2i in layer.get_used_cells():
		if layer.get_cell_source_id(cell) != sid:
			continue
		total += 1
		var coords := layer.get_cell_atlas_coords(cell)
		tally[coords] = int(tally.get(coords, 0)) + 1
	layer.free()
	if total == 0:
		return ""
	var entries: Array = tally.keys()
	entries.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return int(tally[a]) > int(tally[b]))
	var parts := PackedStringArray()
	for coords: Vector2i in entries.slice(0, 3):
		parts.append("%s (%d of %d)" % [coords, int(tally[coords]), total])
	var more := " and %d more" % (entries.size() - 3) if entries.size() > 3 else ""
	return " Existing cells of this source in this layer use atlas %s%s." % [", ".join(parts), more]


static func _atlas_tile_list(atlas: TileSetAtlasSource) -> String:
	var parts := PackedStringArray()
	for t in mini(atlas.get_tiles_count(), MAX_SOURCES_PER_LINE):
		parts.append(str(atlas.get_tile_id(t)))
	if atlas.get_tiles_count() > MAX_SOURCES_PER_LINE:
		parts.append("… %d more — read_file this TileSet's .tres with \"full\": true lists every tile" % (atlas.get_tiles_count() - MAX_SOURCES_PER_LINE))
	return ", ".join(parts)


## Every cell a layer holds, keyed by coords, with its full identity — the before/after halves of the edit diff.
static func _snapshot(layer: TileMapLayer) -> Dictionary:
	var snap := {}
	for cell: Vector2i in layer.get_used_cells():
		snap[cell] = [layer.get_cell_source_id(cell), layer.get_cell_atlas_coords(cell), layer.get_cell_alternative_tile(cell)]
	return snap


## Apply one action to a working copy of the layer and report the honest diff — including cells the action itself never named, which terrain matching adjusts on neighbors.
static func apply_edit(record: Dictionary, action: String, spec: Dictionary) -> Dictionary:
	var working := TileMapLayer.new()
	if not (record["data"] as PackedByteArray).is_empty():
		working.tile_map_data = record["data"]
	if record["tile_set"] is TileSet:
		working.tile_set = record["tile_set"]
	var before := _snapshot(working)
	var named := 0
	match action:
		"cells":
			for entry: Dictionary in spec["cells"]:
				working.set_cell(entry["at"], entry["source"], entry["atlas"], entry["alt"])
			named = (spec["cells"] as Array).size()
		"fill":
			var rect: Rect2i = spec["rect"]
			for y in range(rect.position.y, rect.position.y + rect.size.y):
				for x in range(rect.position.x, rect.position.x + rect.size.x):
					working.set_cell(Vector2i(x, y), spec["source"], spec["atlas"], spec["alt"])
			named = rect.get_area()
		"replace":
			for cell: Vector2i in working.get_used_cells():
				if working.get_cell_source_id(cell) != int(spec["from"]):
					continue
				if spec.has("rect") and not (spec["rect"] as Rect2i).has_point(cell):
					continue
				named += 1
				working.set_cell(cell, spec["to"], working.get_cell_atlas_coords(cell), working.get_cell_alternative_tile(cell))
		"erase":
			for cell: Vector2i in _erase_targets(working, spec):
				named += 1
				working.erase_cell(cell)
		"terrain":
			working.set_cells_terrain_connect(spec["cells"], spec["set"], spec["terrain"])
			named = (spec["cells"] as Array).size()
	var after := _snapshot(working)
	working.free()
	# The canonical rebuild: an in-place edit leaves dead slots in the payload, a replay into a fresh layer is byte-identical to the engine's own serialization.
	var rebuilt := TileMapLayer.new()
	for cell: Vector2i in after:
		var v: Array = after[cell]
		rebuilt.set_cell(cell, v[0], v[1], v[2])
	var payload: PackedByteArray = rebuilt.tile_map_data
	rebuilt.free()
	return _diff_report(before, after, named, payload)


static func _erase_targets(working: TileMapLayer, spec: Dictionary) -> Array:
	var targets: Array = []
	if spec.has("cells"):
		return spec["cells"]
	if spec.has("all"):
		return Array(working.get_used_cells())
	for cell: Vector2i in working.get_used_cells():
		if spec.has("rect") and (spec["rect"] as Rect2i).has_point(cell):
			targets.append(cell)
		elif spec.has("source") and working.get_cell_source_id(cell) == int(spec["source"]):
			targets.append(cell)
	return targets


static func _diff_report(before: Dictionary, after: Dictionary, named: int, payload: PackedByteArray) -> Dictionary:
	var added := 0
	var changed := 0
	var erased := 0
	var prior_counts := {}
	for cell: Vector2i in after:
		if not before.has(cell):
			added += 1
		elif before[cell] != after[cell]:
			changed += 1
			var prior: int = before[cell][0]
			prior_counts[prior] = int(prior_counts.get(prior, 0)) + 1
	for cell: Vector2i in before:
		if not after.has(cell):
			erased += 1
			var prior: int = before[cell][0]
			prior_counts[prior] = int(prior_counts.get(prior, 0)) + 1
	return {
		"added": added, "changed": changed, "erased": erased,
		"unchanged": maxi(named - added - changed - erased, 0),
		# Cells the action never named but the diff moved — terrain matching adjusting neighbors.
		"beyond_named": maxi(added + changed + erased - named, 0),
		"prior_counts": prior_counts, "payload": payload,
	}


## Splice one layer's payload into the scene text, touching nothing else — the minimal-diff write ResourceSaver cannot do (it rewrites the whole file and churns every id).
static func splice(text: String, layer_path: String, b64: String) -> Dictionary:
	var lines := text.split("\n")
	var header := RegEx.create_from_string("^\\[node name=\"([^\"]*)\"(?:.*?parent=\"([^\"]*)\")?")
	var block_start := -1
	var block_end := lines.size()
	for i in lines.size():
		var m := header.search(lines[i])
		if m == null:
			if block_start >= 0 and lines[i].begins_with("["):
				block_end = i
				break
			continue
		if block_start >= 0:
			block_end = i
			break
		var parent := m.get_string(2)
		var path := "."
		if parent != "":
			path = m.get_string(1) if parent == "." else parent + "/" + m.get_string(1)
		if path == layer_path:
			block_start = i
	if block_start < 0:
		return {"error": "Error: no node block for \"%s\" was found in the scene text — the file may have changed since it was read." % layer_path}
	var prop_line := "tile_map_data = PackedByteArray(\"%s\")" % b64
	for i in range(block_start + 1, block_end):
		if lines[i].begins_with("tile_map_data = "):
			if b64 == "":
				lines.remove_at(i)
			else:
				lines[i] = prop_line
			return {"text": "\n".join(lines)}
	if b64 == "":
		# Emptying a layer that stored nothing: the engine serializes no property at all, so neither do we.
		return {"text": text}
	lines.insert(block_start + 1, prop_line)
	return {"text": "\n".join(lines)}


## Compose the edit confirmation: the diff, the new layer state inline (the immediate oracle), and every disclosure the edit earned.
static func compose_edit_report(scene: String, record: Dictionary, action_line: String, diff: Dictionary, notes: PackedStringArray) -> String:
	var lines: Array = ["Edited \"%s\" in %s — %s." % [record["path"], scene, action_line]]
	var parts := PackedStringArray()
	if int(diff["added"]) > 0:
		parts.append("%d added" % int(diff["added"]))
	if int(diff["changed"]) > 0:
		parts.append("%d changed" % int(diff["changed"]))
	if int(diff["erased"]) > 0:
		parts.append("%d erased" % int(diff["erased"]))
	if int(diff["unchanged"]) > 0:
		parts.append("%d already held the target (no change)" % int(diff["unchanged"]))
	if parts.is_empty():
		parts.append("nothing changed")
	var summary := "Cells: " + ", ".join(parts) + "."
	var priors: Dictionary = diff["prior_counts"]
	if not priors.is_empty():
		var prior_parts := PackedStringArray()
		var ids: Array = priors.keys()
		ids.sort()
		var names := source_names(record["tile_set"])
		for sid: int in ids:
			prior_parts.append("%d× %s" % [int(priors[sid]), source_label(sid, names)])
		summary += " Overwritten/erased cells previously held: %s." % ", ".join(prior_parts)
	if int(diff["beyond_named"]) > 0:
		summary += " Terrain matching also adjusted %d neighboring cell(s) the action did not name." % int(diff["beyond_named"])
	lines.append(summary)
	var decoded := decode(diff["payload"])
	if int(decoded["count"]) == 0:
		lines.append("The layer is now empty.")
	else:
		lines.append("Layer now: %d cells in %s — %s" % [int(decoded["count"]), _rect_span(decoded["rect"]), _tiles_line(decoded, source_names(record["tile_set"]), record["tile_set"])])
	for note in notes:
		lines.append("NOTE: %s" % note)
	var ref_note := _refs_note(record)
	if ref_note != "":
		lines.append(ref_note.trim_suffix(".") + " — verify the change survives a run, and prefer the layer that OWNS the data if this one is display-only.")
	lines.append("Verify visually: read_tilemap {\"scene\": \"%s\", \"layer\": \"%s\"}." % [scene, record["path"]])
	return "\n".join(PackedStringArray(lines))
