extends SceneTree
## Headless regression tests for the tilemap read tools: read_tilemap's decode/compose chain and describe_tileset's sectioned legend.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/tilemap_tools_test.gd
## Exits nonzero on any failure.
## Everything here is pure or file-driven — the one editor-only branch (the live edited scene default) is covered down to its headless refusal, and the live WALK itself is driven against a real in-memory node tree, so only the EditorInterface hand-off is untested headlessly.

# Preloaded rather than referenced by class_name so the test's own references survive a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMTilemap = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tilemap.gd")

const FIXTURE_DIR := "res://addons/gdllm-godot-agentic-harness/tools"
const FIXTURE_TILESET := FIXTURE_DIR + "/tilemap_fixture_tileset.tres"
const FIXTURE_TILESET_B := FIXTURE_DIR + "/tilemap_fixture_tileset_b.tres"
const FIXTURE_SCENE := FIXTURE_DIR + "/tilemap_fixture_scene.tscn"
const FIXTURE_SCENE_MULTI := FIXTURE_DIR + "/tilemap_fixture_multi.tscn"
const FIXTURE_STYLEBOX := FIXTURE_DIR + "/tilemap_fixture_stylebox.tres"
const EDIT_SCENE := FIXTURE_DIR + "/tilemap_fixture_edit.tscn"
const FIXTURE_TERRAIN_TILESET := FIXTURE_DIR + "/tilemap_fixture_terrain.tres"
const TERRAIN_SCENE := FIXTURE_DIR + "/tilemap_fixture_terrain_scene.tscn"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_write_fixtures()
	_test_decode()
	_test_source_names()
	_test_join_node_path()
	_test_layers_from_state()
	_test_layers_from_live()
	_test_overview_report()
	_test_layer_matching()
	_test_grid_render()
	_test_grid_window_and_cap()
	_test_describe_tileset()
	_test_describe_tileset_kinds()
	_test_describe_tileset_scene_route()
	_test_refusals()
	_test_end_to_end()
	_test_splice_precision()
	await _test_edit_gate()
	await _test_edit_set()
	await _test_edit_fill_and_erase()
	await _test_edit_replace()
	await _test_edit_terrain()
	await _test_edit_empty_layer_insert()
	await _test_edit_refusals()
	_cleanup()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real execute dispatch and return its content string.
func _run(tool_name: String, args: Dictionary, allow_changes := false) -> String:
	return String((await GDLLMTools.execute(tool_name, args, allow_changes))["content"])


## The known payload every decode/grid assertion is written against: sources 3 and 7 at fixed cells, one flipped cell, built through the engine's own encoder.
func _known_payload() -> PackedByteArray:
	var layer := TileMapLayer.new()
	layer.set_cell(Vector2i(0, 0), 3, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(1, 0), 3, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(2, 0), 7, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(1, 1), 3, Vector2i(0, 0), 1)
	var data: PackedByteArray = layer.tile_map_data
	layer.free()
	return data


## Fixtures are engine-built where the engine's encoding matters (payload, TileSet .tres) and hand-written where node-tag text matters (the scene), per the ResourceSaver unique_id caveat.
func _write_fixtures() -> void:
	var tile_set := TileSet.new()
	var atlas := TileSetAtlasSource.new()
	atlas.resource_name = "stone"
	atlas.texture = ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8))
	atlas.texture_region_size = Vector2i(16, 16)
	atlas.create_tile(Vector2i(0, 0))
	atlas.create_tile(Vector2i(1, 0))
	atlas.create_alternative_tile(Vector2i(0, 0))
	tile_set.add_source(atlas, 3)
	var bare := TileSetAtlasSource.new()
	bare.texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	bare.create_tile(Vector2i(0, 0))
	tile_set.add_source(bare, 7)
	tile_set.add_terrain_set(0)
	tile_set.add_terrain(0, 0)
	tile_set.set_terrain_name(0, 0, "Gnarled Wood")
	tile_set.add_custom_data_layer(0)
	tile_set.set_custom_data_layer_name(0, "hardness")
	tile_set.set_custom_data_layer_type(0, TYPE_INT)
	ResourceSaver.save(tile_set, FIXTURE_TILESET)
	var second := TileSet.new()
	var lone := TileSetAtlasSource.new()
	lone.resource_name = "props"
	second.add_source(lone, 0)
	ResourceSaver.save(second, FIXTURE_TILESET_B)
	ResourceSaver.save(StyleBoxFlat.new(), FIXTURE_STYLEBOX)
	var b64 := Marshalls.raw_to_base64(_known_payload())
	var one_cell := TileMapLayer.new()
	one_cell.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0), 0)
	var one_b64 := Marshalls.raw_to_base64(one_cell.tile_map_data)
	one_cell.free()
	_write_text(FIXTURE_SCENE, """[gd_scene load_steps=3 format=3]

[ext_resource type="TileSet" path="%s" id="1"]
[ext_resource type="Script" path="%s/class_fixture.gd" id="2"]

[node name="Root" type="Node2D"]

[node name="Ground" type="TileMapLayer" parent="."]
tile_map_data = PackedByteArray("%s")
tile_set = ExtResource("1")

[node name="Display" type="TileMapLayer" parent="."]

[node name="Controller" type="Node2D" parent="."]
script = ExtResource("2")
display_ref = NodePath("../Display")

[node name="Old" type="TileMap" parent="."]

[node name="A" type="Node2D" parent="."]

[node name="Dup" type="TileMapLayer" parent="A"]

[node name="B" type="Node2D" parent="."]

[node name="Dup" type="TileMapLayer" parent="B"]
visible = false
enabled = false
""" % [FIXTURE_TILESET, FIXTURE_DIR, b64])
	_write_text(FIXTURE_SCENE_MULTI, """[gd_scene load_steps=3 format=3]

[ext_resource type="TileSet" path="%s" id="1"]
[ext_resource type="TileSet" path="%s" id="2"]

[node name="Root" type="Node2D"]

[node name="First" type="TileMapLayer" parent="."]
tile_map_data = PackedByteArray("%s")
tile_set = ExtResource("1")

[node name="Second" type="TileMapLayer" parent="."]
tile_map_data = PackedByteArray("%s")
tile_set = ExtResource("2")
""" % [FIXTURE_TILESET, FIXTURE_TILESET_B, one_b64, one_b64])


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _test_decode() -> void:
	var decoded := GDLLMTilemap.decode(_known_payload())
	_check(int(decoded["count"]) == 4, "decode counts the 4 cells")
	_check(Rect2i(decoded["rect"]) == Rect2i(0, 0, 3, 2), "decode reports the used rect")
	_check(int((decoded["by_source"] as Dictionary).get(3, 0)) == 3, "decode counts source 3's cells")
	_check(int((decoded["by_source"] as Dictionary).get(7, 0)) == 1, "decode counts source 7's cell")
	_check(int((decoded["cells"] as Dictionary).get(Vector2i(2, 0), -1)) == 7, "decode maps a cell to its source")
	_check(int(decoded["alt_count"]) == 1, "decode counts the flipped/alternative cell")
	_check(not bool(decoded["undecodable"]), "a decodable payload is not flagged")
	var empty := GDLLMTilemap.decode(PackedByteArray())
	_check(int(empty["count"]) == 0 and not bool(empty["undecodable"]), "an empty payload is an empty layer, not corruption")
	# A version stamp the engine rejects: the payload must read as corrupt, never as an empty layer.
	var garbage := PackedByteArray([255, 255, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
	var bad := GDLLMTilemap.decode(garbage)
	_check(int(bad["count"]) == 0 and bool(bad["undecodable"]), "an undecodable payload is flagged, not passed off as empty")


func _test_source_names() -> void:
	var tile_set := TileSet.new()
	var named := TileSetAtlasSource.new()
	named.resource_name = "Debt Coffer"
	tile_set.add_source(named, 0)
	var textured := TileSetAtlasSource.new()
	var tex := ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	tex.resource_path = "res://sprites/tiles/stone_wall.png"
	textured.texture = tex
	tile_set.add_source(textured, 9)
	var embedded := TileSetAtlasSource.new()
	var etex := ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	etex.resource_path = "res://x.tres::ImageTexture_abc"
	embedded.texture = etex
	tile_set.add_source(embedded, 11)
	var names := GDLLMTilemap.source_names(tile_set)
	_check(String(names.get(0, "")) == "Debt Coffer", "resource_name wins as the source name")
	_check(String(names.get(9, "")) == "stone_wall", "a texture's file name is the fallback name")
	_check(not names.has(11), "an embedded texture's :: path is not passed off as a name")
	_check(GDLLMTilemap.source_names(null).is_empty(), "no TileSet means no names, not a crash")
	_check(GDLLMTilemap.source_label(9, names) == "source 9 (stone_wall)", "a named source labels as id (name)")
	_check(GDLLMTilemap.source_label(5, names) == "source 5", "an unnamed source labels bare")


func _test_join_node_path() -> void:
	_check(GDLLMTilemap._join_node_path("DG Wall Layer/DualGrid", "../TileMapLayer DGDisplay") == "DG Wall Layer/TileMapLayer DGDisplay", "a ../ sibling reference resolves")
	_check(GDLLMTilemap._join_node_path(".", "Air Layer") == "Air Layer", "a root-owned child reference resolves")
	_check(GDLLMTilemap._join_node_path("A/B", "../../C") == "C", "a double step up resolves")
	_check(GDLLMTilemap._join_node_path(".", "../Escape") == "", "a path escaping the scene resolves to nothing")
	_check(GDLLMTilemap._join_node_path("A", "../B:position") == "B", "a subname references the node that owns it")


func _test_layers_from_state() -> void:
	var packed: PackedScene = ResourceLoader.load(FIXTURE_SCENE, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var scan := GDLLMTilemap.layers_from_state(packed.get_state())
	var layers: Array = scan["layers"]
	_check(layers.size() == 4, "the 4 TileMapLayers are found (legacy TileMap excluded)")
	_check(int(scan["legacy"]) == 1, "the legacy TileMap is counted")
	var by_path := {}
	for record: Dictionary in layers:
		by_path[record["path"]] = record
	_check(by_path.has("Ground") and by_path.has("Display") and by_path.has("A/Dup") and by_path.has("B/Dup"), "layer paths are tree-relative")
	_check(not (by_path["Ground"]["data"] as PackedByteArray).is_empty(), "Ground carries its stored payload")
	_check(by_path["Ground"]["tile_set"] is TileSet, "Ground carries its loaded TileSet")
	_check((by_path["Display"]["data"] as PackedByteArray).is_empty(), "Display is empty on disk")
	_check(bool(by_path["B/Dup"]["hidden"]) and bool(by_path["B/Dup"]["disabled"]), "stored visible/enabled false become markers")
	var refs: Array = by_path["Display"]["refs"]
	_check(refs.size() == 1, "the NodePath reference to Display is detected")
	_check(String(refs[0]["property"]) == "display_ref" and String(refs[0]["by"]) == "Controller", "the reference names its property and holder")
	_check(String(refs[0]["by_script"]).ends_with("class_fixture.gd"), "the holder's script rides the reference")


func _test_layers_from_live() -> void:
	var root := Node2D.new()
	root.name = "Root"
	var ground := TileMapLayer.new()
	ground.name = "Ground"
	ground.set_cell(Vector2i(5, 5), 2, Vector2i(0, 0), 0)
	root.add_child(ground)
	var display := TileMapLayer.new()
	display.name = "Display"
	root.add_child(display)
	var holder := Node2D.new()
	holder.name = "Holder"
	var script := GDScript.new()
	script.source_code = "extends Node2D\n@export var display_ref: NodePath\n"
	script.reload()
	holder.set_script(script)
	root.add_child(holder)
	holder.set("display_ref", NodePath("../Display"))
	var scan := GDLLMTilemap.layers_from_live(root)
	var layers: Array = scan["layers"]
	_check(layers.size() == 2, "the live walk finds both layers")
	var by_path := {}
	for record: Dictionary in layers:
		by_path[record["path"]] = record
	_check(by_path.has("Ground") and by_path.has("Display"), "live paths match the state walk's shape")
	var decoded := GDLLMTilemap.decode(by_path["Ground"]["data"])
	_check(int(decoded["count"]) == 1 and int((decoded["cells"] as Dictionary).get(Vector2i(5, 5), -1)) == 2, "a live layer's cells decode from its snapshotted data")
	var refs: Array = by_path["Display"]["refs"]
	_check(refs.size() == 1 and String(refs[0]["property"]) == "display_ref", "a live NodePath script variable referencing a layer is detected")
	root.free()


func _test_overview_report() -> void:
	var report := await _run("read_tilemap", {"scene": FIXTURE_SCENE})
	_check(report.contains("as saved on disk"), "the overview names its disk origin")
	_check(report.contains("4 TileMapLayer node(s), 1 with tiles"), "the overview counts layers and which carry tiles")
	_check(report.contains("1 legacy TileMap node(s)"), "a legacy TileMap is disclosed rather than silently skipped")
	_check(report.contains("Ground — 4 cells in x 0..2, y 0..1"), "the tiled layer reports count and bounds")
	_check(report.contains("3× source 3 (stone)"), "tiles are counted per source under the source's NAME")
	_check(report.contains("1× source 7"), "an unnamed source is counted bare")
	_check(report.contains("1 flipped/alternative cell(s)"), "flipped/alternative cells are disclosed")
	_check(report.contains("Layers with no tiles (3)"), "empty layers collapse to a counted line")
	_check(report.contains("referenced as \"display_ref\" by Controller"), "a referenced layer carries the regeneration warning")
	_check(report.contains("class_fixture.gd"), "the warning names the referencing script")
	_check(report.contains("can be regenerated over"), "the warning explains the consequence")
	_check(report.contains("[hidden]") and report.contains("[disabled]"), "hidden/disabled markers survive into the report")
	_check(report.contains("Pass \"layer\""), "the overview names the grid lever")


func _test_layer_matching() -> void:
	_check((await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "Ground"})).contains("Grid — columns"), "a unique name matches its layer")
	_check((await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "A/Dup"})).contains("A/Dup"), "a full path matches exactly")
	var ambiguous := await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "Dup"})
	_check(ambiguous.contains("Error") and ambiguous.contains("\"A/Dup\"") and ambiguous.contains("\"B/Dup\""), "an ambiguous name lists the full paths")
	var missing := await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "zzz"})
	_check(missing.contains("no TileMapLayer matches") and missing.contains("\"Ground\""), "a miss lists the real layers")


func _test_grid_render() -> void:
	var report := await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "Ground"})
	_check(report.contains("y=0: AAB"), "row y=0 renders both sources as symbols")
	_check(report.contains("y=1: .A."), "row y=1 renders the gap as a dot")
	_check(report.contains("A = source 3 (stone) — 3 cell(s) in view"), "the legend names symbol A with its in-view count")
	_check(report.contains("B = source 7 — 1 cell(s) in view"), "the legend keeps an unnamed source bare")
	_check(report.contains("y grows downward"), "the grid states its orientation")


func _test_grid_window_and_cap() -> void:
	var windowed := await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "Ground", "rect": [0, 0, 2, 1]})
	_check(windowed.contains("window x 0..1, y 0..0"), "a rect window is disclosed against the used rect")
	_check(windowed.contains("y=0: AA") and not windowed.contains("AAB"), "the window clips the render")
	_check(windowed.contains("A = source 3 (stone) — 2 cell(s) in view"), "legend counts are in-view, not whole-layer")
	var empty_window := await _run("read_tilemap", {"scene": FIXTURE_SCENE, "layer": "Ground", "rect": [50, 50, 3, 3]})
	_check(empty_window.contains("no cells in this window"), "an empty window says so instead of rendering dots")
	# The auto-pick: rect with no layer, on a scene where exactly one layer has tiles.
	_check((await _run("read_tilemap", {"scene": FIXTURE_SCENE, "rect": [0, 0, 2, 1]})).contains("y=0: AA"), "rect alone zooms the only tiled layer")
	var multi := await _run("read_tilemap", {"scene": FIXTURE_SCENE_MULTI, "rect": [0, 0, 2, 1]})
	_check(multi.contains("Error") and multi.contains("\"First\"") and multi.contains("\"Second\""), "rect with several tiled layers asks for one by name")
	# rect on a scene whose layers all store no tiles: name the real condition, never "pass \"layer\" naming one of: ." against an empty list.
	var bare := {"path": "Empty", "script": "", "data": PackedByteArray(), "tile_set": null, "hidden": false, "disabled": false, "refs": []}
	var no_grid := GDLLMTilemap.compose_report("Test.", {"layers": [bare], "legacy": 0, "has_instances": false}, "", Rect2i(0, 0, 2, 2), true)
	_check(no_grid.contains("no layer in this scene stores any tiles"), "rect on an all-empty scene says there is no grid to window")
	_check(no_grid.contains("Drop \"rect\""), "and points at the overview instead of a layer name")
	# The cap: a layer too big to render whole, driven through the pure composer against an in-memory record.
	var big := TileMapLayer.new()
	for x in 80:
		for y in 60:
			big.set_cell(Vector2i(x, y), 1, Vector2i(0, 0), 0)
	var record := {"path": "Big", "script": "", "data": big.tile_map_data, "tile_set": null, "hidden": false, "disabled": false, "refs": []}
	big.free()
	var scan := {"layers": [record], "legacy": 0, "has_instances": false}
	var capped := GDLLMTilemap.compose_report("Test.", scan, "Big", Rect2i(), false)
	_check(capped.contains("4800 cells, past the %d-cell view cap" % GDLLMTilemap.MAX_GRID_CELLS), "an over-cap grid is withheld with the arithmetic shown")
	_check(capped.contains("\"rect\": [x, y, width, height]"), "the cap names the rect lever")
	_check(capped.contains("4800 cells in x 0..79, y 0..59"), "the counts still cover the whole layer")
	var windowed_big := GDLLMTilemap.compose_report("Test.", scan, "Big", Rect2i(0, 0, 4, 2), true)
	_check(windowed_big.contains("y=0: AAAA"), "a rect brings the big layer under the cap")
	# The consequence clause is per-report, not per-note: on the real project the per-note form repeated twelve times in one overview, ~1.4 KB of duplicate text.
	var ref_a := {"path": "DGDisplay", "script": "", "data": PackedByteArray(), "tile_set": null, "hidden": false, "disabled": false, "refs": [{"property": "display_layer", "by": "DualGrid", "by_script": ""}]}
	var ref_b := {"path": "DGMix1", "script": "", "data": PackedByteArray(), "tile_set": null, "hidden": false, "disabled": false, "refs": [{"property": "mix_layer_1", "by": ".", "by_script": ""}]}
	var multi_ref := GDLLMTilemap.compose_report("Test.", {"layers": [ref_a, ref_b], "legacy": 0, "has_instances": false}, "", Rect2i(), false)
	_check(multi_ref.count("can be regenerated over") == 1, "the consequence clause states once per report, not per note")
	_check(multi_ref.count("NOTE: referenced") == 2, "while every reference is still disclosed")
	_check(multi_ref.contains("by the scene root"), "a root-held reference reads as the scene root, not as \".\"")
	var zoom_ref := GDLLMTilemap.compose_report("Test.", {"layers": [ref_a], "legacy": 0, "has_instances": false}, "DGDisplay", Rect2i(), false)
	_check(zoom_ref.contains("can be regenerated over"), "a zoomed empty referenced layer keeps the clause")


func _test_describe_tileset() -> void:
	var report := await _run("describe_tileset", {"path": FIXTURE_TILESET})
	_check(report.contains("16×16 square tiles"), "the header states tile size and shape")
	_check(report.contains("2 source(s), 1 terrain set(s), 1 custom data layer(s)"), "the header counts the sections")
	_check(report.contains("3 \"stone\" — atlas"), "a named source lists id and name")
	_check(report.contains("2 tile(s), 1 alternative(s)"), "tile and alternative counts ride the source line")
	_check(report.contains("7 (unnamed)"), "an unnamed source says so rather than inventing a name")
	_check(report.contains("set 0 (match corners and sides): 1 terrain(s) — 0 \"Gnarled Wood\""), "terrains list their set mode, ids, and names")
	_check(report.contains("0 \"hardness\" (int)"), "custom data layers carry name and type")


func _test_describe_tileset_kinds() -> void:
	var terrains_only := await _run("describe_tileset", {"path": FIXTURE_TILESET, "kind": "terrains"})
	_check(terrains_only.contains("Gnarled Wood") and not terrains_only.contains("atlas"), "kind=terrains drops the sources section")
	_check(terrains_only.contains("Showing only: terrains"), "the narrowing is disclosed in the head")
	_check((await _run("describe_tileset", {"path": FIXTURE_TILESET, "kind": "terrain"})).contains("Gnarled Wood"), "a singular alias resolves")
	var two := await _run("describe_tileset", {"path": FIXTURE_TILESET, "kind": "sources, custom_data"})
	_check(two.contains("atlas") and two.contains("hardness") and not two.contains("Gnarled Wood"), "a two-section list selects both and only both")
	var unknown := await _run("describe_tileset", {"path": FIXTURE_TILESET, "kind": "physics"})
	_check(unknown.contains("unknown kind \"physics\"") and unknown.contains("sources, terrains, custom_data"), "an unknown kind is refused with the three that exist")
	var filtered := await _run("describe_tileset", {"path": FIXTURE_TILESET, "filter": "stone"})
	_check(filtered.contains("3 \"stone\"") and not filtered.contains("7 (unnamed)"), "a filter narrows sources by name")
	var miss := await _run("describe_tileset", {"path": FIXTURE_TILESET, "filter": "zzz"})
	_check(miss.contains("No name in the selected section(s) contains \"zzz\""), "a filter miss reads as a miss, not an empty TileSet")


func _test_describe_tileset_scene_route() -> void:
	var report := await _run("describe_tileset", {"path": FIXTURE_SCENE})
	_check(report.contains("tilemap_fixture_tileset.tres") and report.contains("used by Ground"), "a scene with one TileSet describes it, naming the layer and the .tres route")
	_check(report.contains("3 \"stone\""), "the scene route reaches the same sections")
	var multi := await _run("describe_tileset", {"path": FIXTURE_SCENE_MULTI})
	_check(multi.contains("Error") and multi.contains("2 distinct TileSets") and multi.contains("First") and multi.contains("Second"), "a scene using two TileSets asks for a layer")
	_check((await _run("describe_tileset", {"path": FIXTURE_SCENE_MULTI, "layer": "Second"})).contains("\"props\""), "the layer argument picks that layer's TileSet")


func _test_refusals() -> void:
	var headless := await _run("read_tilemap", {})
	_check(headless.contains("headless") and headless.contains("\"scene\""), "the live default refuses headless by name, naming the scene lever")
	_check((await _run("read_tilemap", {"scene": FIXTURE_TILESET})).contains("not a scene file"), "a non-scene path is refused")
	_check((await _run("read_tilemap", {"scene": "res://nope_absent.tscn"})).contains("Error"), "a missing scene is refused")
	# Extensionless stem resolution: "world_start" for world_start.tscn cost a recoverable error ~7 times across two wild rounds; a unique stem is unambiguous intent.
	var stem := await _run("read_tilemap", {"scene": "tilemap_fixture_scene"})
	_check(stem.contains("Tilemaps in res://addons/gdllm-godot-agentic-harness/tools/tilemap_fixture_scene.tscn"), "an extensionless unique stem resolves to its file")
	_check((await _run("read_tilemap", {"scene": "tilemap_fixture_nope"})).contains("Error"), "an extensionless miss still errors")
	_check((await _run("read_file", {"path": "res://addons/gdllm-godot-agentic-harness/tools"})).contains("is a DIRECTORY"), "an extensionless directory path is still answered as a directory, never stem-resolved to a file")
	_check((await _run("read_tilemap", {"scene": FIXTURE_SCENE, "rect": [1, 2, 3]})).contains("[x, y, width, height]"), "a malformed rect is refused with the expected shape")
	_check((await _run("read_tilemap", {"scene": FIXTURE_SCENE, "rect": [0, 0, 0, 5]})).contains("at least 1 cell"), "a zero-size rect is refused")
	_check((await _run("read_tilemap", {"bogus": 1})).contains("unrecognized argument"), "an unrecognized argument is named instead of ignored")
	var not_tileset := await _run("describe_tileset", {"path": FIXTURE_STYLEBOX})
	_check(not_tileset.contains("StyleBoxFlat, not a TileSet"), "a non-TileSet resource is refused with its real class")
	_check((await _run("describe_tileset", {"path": FIXTURE_DIR + "/tilemap_tools_test.gd"})).contains("not a resource or scene file"), "a script path is refused with what the tool takes")
	_check((await _run("describe_tileset", {})).contains("no path was provided"), "a missing path names the usage")


func _test_end_to_end() -> void:
	# Both are reads: they must work with Make changes off and sit in the catalog there.
	var gated := await _run("read_tilemap", {"scene": FIXTURE_SCENE}, false)
	_check(not gated.contains("Make changes"), "read_tilemap runs with Make changes off")
	# The last two phrases are the wild-measured discovery gap: state-vocabulary questions (0/3 and 1/4 discovery) answered correctly but through ~110 KB of search where the 3.2 KB overview held the answer.
	for phrase in ["tilemap", "tiles placed", "tileset terrains", "tile map grid", "empty layers", "hidden disabled"]:
		var found_one := false
		for entry in GDLLMTools.search(phrase, false):
			var found_name := String(entry["name"])
			if found_name == "read_tilemap" or found_name == "describe_tileset":
				found_one = true
		_check(found_one, "tool_search finds a tilemap tool from \"%s\"" % phrase)


## A fresh copy of the fixture scene for each edit test, so edits never contaminate the read tests' expectations or each other.
func _write_edit_scene() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE_SCENE)
	_write_text(EDIT_SCENE, text)


## A terrain-armed tileset (the probe pattern: tiles carrying terrain ids and peering bits), which the read fixture deliberately lacks.
func _write_terrain_fixtures() -> void:
	var ts := TileSet.new()
	ts.add_terrain_set(0)
	ts.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_SIDES)
	ts.add_terrain(0, 0)
	ts.set_terrain_name(0, 0, "Wood")
	var atlas := TileSetAtlasSource.new()
	atlas.resource_name = "wood_tiles"
	atlas.texture = ImageTexture.create_from_image(Image.create(64, 16, false, Image.FORMAT_RGBA8))
	atlas.texture_region_size = Vector2i(16, 16)
	for i in 4:
		atlas.create_tile(Vector2i(i, 0))
		var td := atlas.get_tile_data(Vector2i(i, 0), 0)
		td.terrain_set = 0
		td.terrain = 0
		if i > 0:
			td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_LEFT_SIDE, 0)
		if i < 3:
			td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)
	ts.add_source(atlas, 5)
	ResourceSaver.save(ts, FIXTURE_TERRAIN_TILESET)
	_write_text(TERRAIN_SCENE, """[gd_scene load_steps=2 format=3]

[ext_resource type="TileSet" path="%s" id="1"]

[node name="Root" type="Node2D"]

[node name="Wood" type="TileMapLayer" parent="."]
tile_set = ExtResource("1")
""" % FIXTURE_TERRAIN_TILESET)


func _test_splice_precision() -> void:
	var text := """[gd_scene format=3]

[node name="Root" type="Node2D"]

[node name="A" type="TileMapLayer" parent="."]
tile_map_data = PackedByteArray("AAAA")
tile_set = null

[node name="B" type="TileMapLayer" parent="."]
tile_map_data = PackedByteArray("BBBB")
"""
	var out := GDLLMTilemap.splice(text, "A", "CCCC")
	_check(String(out["text"]).contains("PackedByteArray(\"CCCC\")"), "the target line is replaced")
	_check(String(out["text"]).contains("PackedByteArray(\"BBBB\")"), "the other layer's payload is untouched")
	_check(String(out["text"]).count("tile_map_data") == 2, "no lines are added or lost on a replace")
	var removed := GDLLMTilemap.splice(text, "A", "")
	_check(not String(removed["text"]).contains("CCCC") and String(removed["text"]).count("tile_map_data") == 1, "an emptied layer's property line is removed, matching engine serialization")
	var inserted := GDLLMTilemap.splice(text.replace("tile_map_data = PackedByteArray(\"BBBB\")\n", ""), "B", "DDDD")
	_check(String(inserted["text"]).contains("[node name=\"B\" type=\"TileMapLayer\" parent=\".\"]\ntile_map_data = PackedByteArray(\"DDDD\")"), "a layer without the property gets the line inserted under its header")
	_check(GDLLMTilemap.splice(text, "Nope", "EE").has("error"), "an unknown layer path is an error, not a silent no-op")


func _test_edit_gate() -> void:
	var refusal := await _run("edit_tilemap", {"scene": FIXTURE_SCENE, "layer": "Ground", "erase": {"rect": [0, 0, 1, 1]}}, false)
	_check(refusal.contains("Make changes"), "edit_tilemap rides the Make-changes gate")
	var gated := false
	var open := false
	for entry in GDLLMTools.search("edit_tilemap", false):
		if String(entry["name"]) == "edit_tilemap":
			gated = true
	for entry in GDLLMTools.search("edit_tilemap", true):
		if String(entry["name"]) == "edit_tilemap":
			open = true
	_check(not gated and open, "the tool is searchable only when changes are allowed")
	for phrase in ["change tiles", "replace tiles", "paint terrain"]:
		var found := false
		for entry in GDLLMTools.search(phrase, true):
			if String(entry["name"]) == "edit_tilemap":
				found = true
		_check(found, "tool_search finds edit_tilemap from \"%s\"" % phrase)


func _test_edit_set() -> void:
	_write_edit_scene()
	var original := FileAccess.get_file_as_string(EDIT_SCENE)
	var report := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": [
		{"at": [10, 10], "source": "stone", "atlas": [1, 0]},
		{"at": [11, 10], "source": 7},
	]}, true)
	_check(report.contains("2 added"), "two new cells report as added")
	_check(report.contains("\"stone\" resolved to source 3 (stone)"), "by-name source resolution is disclosed")
	_check(report.contains("Layer now: 6 cells"), "the new layer state rides the result as the oracle")
	_check(report.contains("read_tilemap"), "the visual verification lever is named")
	var after := FileAccess.get_file_as_string(EDIT_SCENE)
	var diff_lines := 0
	var before_lines := original.split("\n")
	var after_lines := after.split("\n")
	for i in mini(before_lines.size(), after_lines.size()):
		if before_lines[i] != after_lines[i]:
			diff_lines += 1
	_check(diff_lines == 1 and before_lines.size() == after_lines.size(), "exactly one line of the file changed")
	var readback := await _run("read_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "rect": [10, 10, 2, 1]})
	_check(readback.contains("2 cell(s) in view") or readback.contains("y=10: AB"), "read_tilemap sees the placed cells")
	var again := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": [
		{"at": [10, 10], "source": "stone", "atlas": [1, 0]},
		{"at": [11, 10], "source": 7},
	]}, true)
	_check(again.contains("2 already held the target"), "a repeated identical set reports as no change")
	_check(again.contains("file was not rewritten"), "a no-op does not rewrite the file")


func _test_edit_fill_and_erase() -> void:
	_write_edit_scene()
	var fill := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "fill": {"rect": [20, 20, 3, 2], "source": 7}}, true)
	_check(fill.contains("6 added"), "a fill reports the cells it added")
	_check(fill.contains("fill x 20..22, y 20..21"), "the fill's action line states its rect")
	var overwrite := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "fill": {"rect": [20, 20, 2, 1], "source": "stone", "atlas": [0, 0]}}, true)
	_check(overwrite.contains("2 changed"), "overwriting reports changed, not added")
	_check(overwrite.contains("previously held: 2× source 7"), "overwritten cells' prior occupants are counted")
	var erase := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "erase": {"rect": [20, 20, 3, 2]}}, true)
	_check(erase.contains("6 erased"), "an erase counts what it removed")
	var by_source := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "erase": {"source": 7}}, true)
	_check(by_source.contains("erase every cell of source 7") and by_source.contains("1 erased"), "erase by source removes that source's cells")
	# The whole-layer spelling: two wild sessions invented ±9999 rects to say "clear the layer" and were refused with advice ("split it") that made no sense for the intent.
	_write_edit_scene()
	var all := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "erase": {"all": true}}, true)
	_check(all.contains("erase every cell in the layer") and all.contains("4 erased"), "erase all clears the whole layer")
	_check(all.contains("The layer is now empty"), "the emptied layer is stated outright")
	_check((await _run("read_tilemap", {"scene": EDIT_SCENE})).contains("0 with tiles"), "the cleared layer survives a fresh read as empty")
	var again_all := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "erase": {"all": true}}, true)
	_check(again_all.contains("nothing changed") and again_all.contains("file was not rewritten"), "clearing an already-empty layer is an honest no-op")
	var giant := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "erase": {"rect": [-9999, -9999, 19998, 19998]}}, true)
	_check(giant.contains("{\"all\": true}"), "the over-cap erase refusal names the whole-layer spelling")


func _test_edit_replace() -> void:
	_write_edit_scene()
	var report := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "replace": {"from": "stone", "to": 7}}, true)
	_check(report.contains("replace source 3 (stone) → source 7"), "the action line names both sources")
	_check(report.contains("3 changed"), "every cell of the source is swapped")
	_check(report.contains("previously held: 3× source 3 (stone)"), "the replaced cells' prior identity is counted")
	_check(report.contains("keep their atlas coords"), "the atlas-kept rule is disclosed")
	var same := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "replace": {"from": 7, "to": 7}}, true)
	_check(same.contains("nothing to replace"), "from == to is refused, not silently no-opped")
	var unknown := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "replace": {"from": "granite", "to": 7}}, true)
	_check(unknown.contains("no source is named \"granite\"") and unknown.contains("stone"), "an unknown name is refused with the real names")
	_check(unknown.contains("Nothing was written"), "the refusal says the write was withheld")
	# The atlas-gap guard: put a stone cell on its second tile, then replace toward a source that lacks that tile.
	_write_edit_scene()
	var seeded := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": [{"at": [30, 30], "source": "stone", "atlas": [1, 0]}]}, true)
	_check(seeded.contains("1 added"), "the gap fixture cell lands")
	var gap := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "replace": {"from": "stone", "to": 7}}, true)
	_check(gap.contains("no tiles at the atlas coords") and gap.contains("(1, 0)"), "a replace into a source lacking the carried atlas is refused naming the gap")
	_check(gap.contains("\"cells\""), "the refusal names the explicit-cells way through")


func _test_edit_terrain() -> void:
	_write_terrain_fixtures()
	var report := await _run("edit_tilemap", {"scene": TERRAIN_SCENE, "layer": "Wood", "terrain": {"rect": [0, 0, 3, 1], "terrain": "Wood"}}, true)
	_check(report.contains("paint 3 cell(s) with terrain \"Wood\""), "the action line names the terrain painted")
	_check(report.contains("3 added"), "terrain painting reports its added cells")
	var readback := await _run("read_tilemap", {"scene": TERRAIN_SCENE, "layer": "Wood"})
	_check(readback.contains("3× source 5 (wood_tiles)"), "the painted cells decode with the terrain source")
	var unknown := await _run("edit_tilemap", {"scene": TERRAIN_SCENE, "layer": "Wood", "terrain": {"rect": [0, 0, 1, 1], "terrain": "Lava"}}, true)
	_check(unknown.contains("no terrain is named \"Lava\"") and unknown.contains("\"Wood\""), "an unknown terrain is refused with the real ones")
	_write_edit_scene()
	var no_sets := await _run("edit_tilemap", {"scene": FIXTURE_SCENE_MULTI, "layer": "Second", "terrain": {"rect": [0, 0, 1, 1], "terrain": "Wood"}}, true)
	_check(no_sets.contains("defines no terrain sets"), "a tileset without terrain sets refuses the terrain action")
	var bypass := await _run("edit_tilemap", {"scene": TERRAIN_SCENE, "layer": "Wood", "cells": [{"at": [9, 9], "source": 5, "atlas": [0, 0]}]}, true)
	_check(bypass.contains("bypass terrain matching"), "a raw write into a terrain-bearing tileset discloses the bypass")


func _test_edit_empty_layer_insert() -> void:
	_write_edit_scene()
	var report := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Display", "cells": [{"at": [0, 0], "source": 3, "atlas": [0, 0]}]}, true)
	_check(report.contains("1 added"), "an empty layer accepts its first cell")
	_check(report.contains("referenced as \"display_ref\" by Controller"), "the referenced-layer warning rides the edit result")
	_check(report.contains("prefer the layer that OWNS the data"), "the warning tells the editor where authored data lives")
	var readback := await _run("read_tilemap", {"scene": EDIT_SCENE})
	_check(readback.contains("2 with tiles"), "the inserted property line survives a fresh read")


func _test_edit_refusals() -> void:
	_write_edit_scene()
	_check((await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground"}, true)).contains("no action was given"), "a call without an action names the five")
	var two := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "fill": {"rect": [0, 0, 1, 1], "source": 7}, "erase": {"rect": [0, 0, 1, 1]}}, true)
	_check(two.contains("one action per call") and two.contains("fill, erase"), "two actions in one call are refused by name")
	_check((await _run("edit_tilemap", {"scene": EDIT_SCENE, "erase": {"rect": [0, 0, 1, 1]}}, true)).contains("no layer was given"), "a missing layer is refused naming read_tilemap")
	_check((await _run("edit_tilemap", {"scene": FIXTURE_TILESET, "layer": "x", "erase": {"rect": [0, 0, 1, 1]}}, true)).contains("not a .tscn"), "a non-scene path is refused")
	var big_cells: Array = []
	for i in GDLLMTilemap.MAX_SET_CELLS + 1:
		big_cells.append({"at": [i, 0], "source": 7})
	var capped := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": big_cells}, true)
	_check(capped.contains("past the %d-cell cap" % GDLLMTilemap.MAX_SET_CELLS) and capped.contains("fill"), "an over-cap cell batch is refused naming the bulk verbs")
	var big_fill := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "fill": {"rect": [0, 0, 200, 200], "source": 7}}, true)
	_check(big_fill.contains("past the %d-cell cap" % GDLLMTilemap.MAX_FILL_AREA), "an over-cap fill rect is refused with its arithmetic")
	var bad_id := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "fill": {"rect": [0, 0, 1, 1], "source": 99}}, true)
	_check(bad_id.contains("no source 99") and bad_id.contains("stone"), "an id the TileSet lacks is refused with the real sources")
	var no_atlas := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": [{"at": [0, 0], "source": "stone"}]}, true)
	_check(no_atlas.contains("\"atlas\" must say which one"), "a multi-tile source without atlas is refused listing its tiles")
	# The layer's own convention rides the refusal — wild-measured as the difference between a one-call retry and a probe script (or a wrong guess shipped as success).
	_check(no_atlas.contains("Existing cells of this source in this layer use atlas (0, 0) (3 of 3)"), "the refusal names the atlas the layer's existing cells use")
	var seeded := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": [{"at": [40, 40], "source": "stone", "atlas": [1, 0]}]}, true)
	_check(seeded.contains("1 added"), "the mixed-distribution fixture cell lands")
	var mixed := await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "cells": [{"at": [0, 0], "source": "stone"}]}, true)
	_check(mixed.contains("use atlas (0, 0) (3 of 4), (1, 0) (1 of 4)"), "a mixed distribution lists biggest first with counts")
	# The First layer carries the tileset but no stone cells, so there is no convention to consult.
	var no_cells := await _run("edit_tilemap", {"scene": FIXTURE_SCENE_MULTI, "layer": "First", "cells": [{"at": [0, 0], "source": "stone"}]}, true)
	_check(no_cells.contains("\"atlas\" must say which one") and not no_cells.contains("Existing cells"), "a layer holding none of the source stays silent rather than inventing a convention")
	_check((await _run("edit_tilemap", {"scene": EDIT_SCENE, "layer": "Ground", "erase": {}}, true)).contains("\"erase\" takes"), "an empty erase spec states the three shapes")


func _cleanup() -> void:
	for path in [FIXTURE_TILESET, FIXTURE_TILESET_B, FIXTURE_SCENE, FIXTURE_SCENE_MULTI, FIXTURE_STYLEBOX, EDIT_SCENE, FIXTURE_TERRAIN_TILESET, TERRAIN_SCENE]:
		DirAccess.remove_absolute(path)
