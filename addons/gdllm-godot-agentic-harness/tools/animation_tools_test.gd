extends SceneTree
## Headless regression tests for the animation tools: describe_animation's decode/compose chain and edit_animation's engine-API ops, splices, and write pipeline.
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/animation_tools_test.gd
## Exits nonzero on any failure.
## Fixtures are engine-built (ResourceSaver-canonical text), so the splice assertions measure against exactly what the engine writes.

# Preloaded rather than referenced by class_name so the test's own references survive a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMAnimation = preload("res://addons/gdllm-godot-agentic-harness/gdllm_animation.gd")

const FIXTURE_DIR := "res://addons/gdllm-godot-agentic-harness/tools"
const EDIT_SCENE := FIXTURE_DIR + "/anim_fixture_scene.tscn"
const EMPTY_SCENE := FIXTURE_DIR + "/anim_fixture_empty.tscn"
const EXT_SCENE := FIXTURE_DIR + "/anim_fixture_ext_scene.tscn"
const FIXTURE_ANIM := FIXTURE_DIR + "/anim_fixture_solo.tres"
const FIXTURE_LIB := FIXTURE_DIR + "/anim_fixture_lib.tres"
const FIXTURE_EMPTY_LIB := FIXTURE_DIR + "/anim_fixture_empty_lib.tres"
const FIXTURE_EXT_LIB := FIXTURE_DIR + "/anim_fixture_ext_lib.tres"
const FIXTURE_STREAM := FIXTURE_DIR + "/anim_fixture_stream.tres"
const FIXTURE_FRAMES := FIXTURE_DIR + "/anim_fixture_frames.tres"
const FIXTURE_BIN := FIXTURE_DIR + "/anim_fixture_bin.res"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_write_fixtures()
	_test_scan()
	_test_overview()
	_test_zoom()
	_test_window()
	_test_matching()
	_test_describe_resources()
	_test_converters()
	await _test_add_remove_move_track()
	await _test_insert_key()
	await _test_set_key()
	await _test_remove_key()
	await _test_3d_tracks()
	await _test_bezier()
	await _test_audio_ext_remap()
	await _test_animation_track()
	await _test_library_add_remove()
	await _test_standalone_and_empty_library()
	await _test_ext_library_redirect()
	await _test_embedded_resource_refusal()
	await _test_noop_and_refusals()
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


func _text(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## Load a scene fresh from disk and return the named animation off its player state — the oracle every edit assertion reads through.
func _load_anim(scene: String, key: String) -> Animation:
	var packed: PackedScene = ResourceLoader.load(scene, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null:
		return null
	var scan: Dictionary = GDLLMAnimation.players_from_state(packed.get_state())
	var found: Dictionary = GDLLMAnimation.match_animation(scan["players"], key)
	if found.has("error"):
		return null
	return found["entry"]["animation"] as Animation


func _walk_anim() -> Animation:
	var anim := Animation.new()
	anim.length = 0.6
	anim.loop_mode = Animation.LOOP_LINEAR
	var t := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(t, "Pic:position")
	anim.track_insert_key(t, 0.0, Vector2(0, 0))
	anim.track_insert_key(t, 0.5, Vector2(10, 20))
	anim.track_set_key_transition(t, 1, 2.0)
	t = anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(t, ".")
	anim.track_insert_key(t, 0.25, {"method": "do_thing", "args": [1, "two"]})
	return anim


func _cast_anim() -> Animation:
	var anim := Animation.new()
	anim.length = 1.0
	var t := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t, "Rig")
	anim.position_track_insert_key(t, 0.0, Vector3(0, 0, 0))
	t = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, "Rig")
	anim.rotation_track_insert_key(t, 0.0, Quaternion.IDENTITY)
	t = anim.add_track(Animation.TYPE_BEZIER)
	anim.track_set_path(t, "Pic:modulate:a")
	anim.bezier_track_insert_key(t, 0.0, 1.0, Vector2(-0.1, 0), Vector2(0.1, 0))
	t = anim.add_track(Animation.TYPE_ANIMATION)
	anim.track_set_path(t, "SubPlayer")
	anim.animation_track_insert_key(t, 0.0, "walk")
	t = anim.add_track(Animation.TYPE_BLEND_SHAPE)
	anim.track_set_path(t, "Face:smile")
	anim.blend_shape_track_insert_key(t, 0.0, 0.0)
	return anim


func _jingle_anim() -> Animation:
	var anim := Animation.new()
	anim.length = 0.8
	var t := anim.add_track(Animation.TYPE_AUDIO)
	anim.track_set_path(t, "Noise")
	return anim


func _grad_anim() -> Animation:
	var anim := Animation.new()
	var t := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(t, "Pic:texture")
	anim.track_insert_key(t, 0.0, Gradient.new())
	return anim


## The main fixture: one player with three libraries (bare-name collision on "cast" across the named two, "walk" shadowed by the default), an AnimatedSprite2D for the counted-not-decoded note, engine-saved so the text is ResourceSaver-canonical.
func _write_edit_scene() -> void:
	var root := Node2D.new()
	root.name = "Root"
	var sprite := Sprite2D.new()
	sprite.name = "Pic"
	root.add_child(sprite)
	sprite.owner = root
	var asprite := AnimatedSprite2D.new()
	asprite.name = "Coin"
	asprite.sprite_frames = SpriteFrames.new()
	root.add_child(asprite)
	asprite.owner = root
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	player.owner = root
	var lib := AnimationLibrary.new()
	lib.add_animation("walk", _walk_anim())
	lib.add_animation("jingle", _jingle_anim())
	lib.add_animation("grad", _grad_anim())
	var atk := AnimationLibrary.new()
	atk.add_animation("cast", _cast_anim())
	var magic := AnimationLibrary.new()
	var short := Animation.new()
	short.length = 0.2
	magic.add_animation("cast", short)
	magic.add_animation("walk", Animation.new())
	player.add_animation_library("", lib)
	player.add_animation_library("attack", atk)
	player.add_animation_library("magic", magic)
	player.autoplay = "walk"
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, EDIT_SCENE)
	root.free()


func _write_fixtures() -> void:
	_write_edit_scene()
	# A scene with a sprite but no AnimationPlayer — the scoped-miss case.
	var root := Node2D.new()
	root.name = "YSort"
	var asprite := AnimatedSprite2D.new()
	asprite.name = "Coin"
	asprite.sprite_frames = SpriteFrames.new()
	root.add_child(asprite)
	asprite.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, EMPTY_SCENE)
	root.free()
	# Standalone resources.
	var solo := _walk_anim()
	solo.resource_name = "solo"
	ResourceSaver.save(solo, FIXTURE_ANIM)
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", _walk_anim())
	lib.add_animation("run", Animation.new())
	ResourceSaver.save(lib, FIXTURE_LIB)
	ResourceSaver.save(AnimationLibrary.new(), FIXTURE_EMPTY_LIB)
	var stream := AudioStreamWAV.new()
	ResourceSaver.save(stream, FIXTURE_STREAM)
	ResourceSaver.save(SpriteFrames.new(), FIXTURE_FRAMES)
	ResourceSaver.save(_walk_anim(), FIXTURE_BIN)
	# An ext library referenced by a scene — edits must follow the storage.
	var ext_lib := AnimationLibrary.new()
	ext_lib.add_animation("spin", _walk_anim())
	ResourceSaver.save(ext_lib, FIXTURE_EXT_LIB)
	var ext_root := Node2D.new()
	ext_root.name = "ExtRoot"
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	ext_root.add_child(player)
	player.owner = ext_root
	player.add_animation_library("ext", ResourceLoader.load(FIXTURE_EXT_LIB))
	var ext_packed := PackedScene.new()
	ext_packed.pack(ext_root)
	ResourceSaver.save(ext_packed, EXT_SCENE)
	ext_root.free()


func _test_scan() -> void:
	var packed: PackedScene = ResourceLoader.load(EDIT_SCENE, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var scan: Dictionary = GDLLMAnimation.players_from_state(packed.get_state())
	_check((scan["players"] as Array).size() == 1, "one AnimationPlayer found in state")
	_check(int(scan["sprite_count"]) == 1, "AnimatedSprite2D counted, not decoded")
	var player: Dictionary = (scan["players"] as Array)[0]
	_check((player["libraries"] as Array).size() == 3, "all three libraries collected")
	_check(String(player["autoplay"]) == "walk", "autoplay read from state")
	var entries: Array = GDLLMAnimation.animation_entries(player)
	_check(entries.size() == 6, "six animations across the libraries")


func _test_overview() -> void:
	var report := await _run("describe_animation", {"scene": EDIT_SCENE})
	_check(report.contains("1 AnimationPlayer node(s)"), "overview counts players")
	_check(report.contains("autoplay \"walk\""), "overview names autoplay")
	_check(report.contains("AnimatedSprite2D/3D"), "overview discloses the sprite nodes")
	_check(report.contains("read_file"), "sprite note points at the text route")
	_check(report.contains("\"walk\" — length 0.6s, loop linear, 2 track(s), 3 key(s)"), "per-animation header line")
	_check(report.contains("library \"attack\""), "named library listed")


func _test_zoom() -> void:
	var report := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "walk"})
	_check(report.contains("track 0 — value \"Pic:position\""), "value track header")
	_check(report.contains("update continuous"), "value track update mode named")
	_check(report.contains("[0] 0s: Vector2(0, 0)"), "key line carries index, time, value")
	_check(report.contains("(transition 2)"), "non-default transition shown")
	_check(report.contains("do_thing(1, \"two\")"), "method key rendered as a call")
	_check(report.contains("the default library"), "a bare name in the default library wins by exact key — engine play() semantics")
	_check(report.contains("edit_animation"), "zoom names the write companion")
	_check(report.contains("edit_file"), "zoom names the text route for scalars")
	var cast := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "cast"})
	_check(cast.contains("2 animations match") and cast.contains("attack/cast") and cast.contains("magic/cast"), "a bare name colliding across named libraries is an ambiguity listing both keys")
	var qualified := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "magic/cast"})
	_check(qualified.contains("length 0.2s"), "qualified key picks the right library")
	var exotic := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "attack/cast"})
	_check(exotic.contains("position_3d") and exotic.contains("rotation_3d") and exotic.contains("bezier"), "3D and bezier tracks render through the engine decoders")
	var deep := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "jingle"})
	_check(deep.contains("audio \"Noise\" — 0 key(s)"), "audio track rendered with key count")


func _test_window() -> void:
	var narrowed := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "walk", "window": [0.4, 0.6]})
	_check(narrowed.contains("[1] 0.5s"), "in-window key shown")
	_check(not narrowed.contains("[0] 0s: Vector2(0, 0)"), "out-of-window key hidden")
	_check(narrowed.contains("not shown"), "hidden keys are counted, never silent")
	var bad := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "walk", "window": [0.5, 0.1]})
	_check(bad.contains("must be after"), "inverted window refused")
	var no_anim := await _run("describe_animation", {"scene": EDIT_SCENE, "window": [0, 1]})
	_check(no_anim.contains("pass \"animation\""), "window without animation names the lever")


func _test_matching() -> void:
	var miss := await _run("describe_animation", {"scene": EDIT_SCENE, "animation": "zzz"})
	_check(miss.contains("no animation matches"), "a miss says so")
	_check(miss.contains("searched " + EDIT_SCENE), "a miss names what was searched")
	var empty := await _run("describe_animation", {"scene": EMPTY_SCENE, "animation": "active"})
	_check(empty.contains("no AnimationPlayer"), "a playerless scene says so")
	_check(empty.contains("searched " + EMPTY_SCENE), "the playerless miss names the scene")
	_check(empty.contains("SpriteFrames"), "the playerless miss discloses the sprite animations that DO exist")
	var no_player := await _run("describe_animation", {"scene": EDIT_SCENE, "player": "zzz"})
	_check(no_player.contains("no single AnimationPlayer"), "a player miss lists the real players")


func _test_describe_resources() -> void:
	var solo := await _run("describe_animation", {"scene": FIXTURE_ANIM})
	_check(solo.contains("Animation — length 0.6s"), "a single Animation .tres zooms directly")
	_check(solo.contains("whichever AnimationPlayer"), "standalone read discloses path resolution")
	var lib := await _run("describe_animation", {"scene": FIXTURE_LIB})
	_check(lib.contains("AnimationLibrary — 2 animation(s)"), "a library .tres lists")
	var lib_zoom := await _run("describe_animation", {"scene": FIXTURE_LIB, "animation": "idle"})
	_check(lib_zoom.contains("track 0 — value"), "a library animation zooms by name")
	var frames := await _run("describe_animation", {"scene": FIXTURE_FRAMES})
	_check(frames.contains("SpriteFrames") and frames.contains("read_file"), "SpriteFrames read points at the text route")
	var bin := await _run("describe_animation", {"scene": FIXTURE_BIN})
	_check(bin.contains("track 0 — value"), "a binary .res Animation is still readable")


func _test_converters() -> void:
	_check(GDLLMAnimation.parse_value("Vector2(4, -7)") == Vector2(4, -7), "a Godot literal string parses")
	_check(GDLLMAnimation.parse_value("hello") == "hello", "a plain word stays a string")
	_check(GDLLMAnimation.parse_value(3) == 3, "numbers pass through")
	_check(GDLLMAnimation._as_vector3([1, 2, 3], "v").get("value") == Vector3(1, 2, 3), "a 3-array becomes Vector3 where the signature fixes it")
	_check(String(GDLLMAnimation._as_quaternion([1, 2, 3], "v").get("error", "")).contains("Quaternion"), "a 3-array is not a Quaternion")
	_check(GDLLMAnimation._as_vector2("Vector2(1, 2)", "v").get("value") == Vector2(1, 2), "vector literal accepted where Vector2 is required")
	var track_err: Dictionary = GDLLMAnimation.match_track(_walk_anim(), "zzz")
	_check(String(track_err.get("error", "")).contains("0: value \"Pic:position\""), "a track miss lists the real tracks")


func _test_add_remove_move_track() -> void:
	_write_edit_scene()
	var added := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "add_track": {"type": "value", "path": "Pic:modulate"}}, true)
	_check(added.contains("added track 2 — value \"Pic:modulate\""), "add_track reports the new index and path")
	_check(not added.contains("no node at"), "a resolving path earns no note")
	var dead := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "add_track": {"type": "value", "path": "Ghost:modulate"}}, true)
	_check(dead.contains("added track 3") and dead.contains("no node at \"Ghost\""), "a dead path is accepted AND the fact is stated")
	var escaped := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "add_track": {"type": "method", "path": "..:_on_apex"}}, true)
	_check(escaped.contains("resolves outside the scene"), "a path escaping the scene states that fact — the wild wrong-node case")
	for track_query in ["Ghost", "_on_apex"]:
		var cleanup := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "remove_track": {"track": track_query}}, true)
		_check(cleanup.contains("removed track"), "cleanup removed the noted track")
	# Instanced sub-scenes make node existence unknowable — the note must stay silent rather than guess.
	var unverifiable := GDLLMAnimation.track_target_note("Ghost:x", {"path": "AnimationPlayer", "root_node": ".."}, {"node_paths": {".": true}, "has_instances": true})
	_check(unverifiable == "", "instanced sub-scenes withhold the resolve note")
	var anim := _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and anim.get_track_count() == 3, "the track landed on disk")
	var bad_type := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "add_track": {"type": "wobble", "path": "Pic:x"}}, true)
	_check(bad_type.contains("not a track type") and bad_type.contains("position_3d"), "an unknown type lists the real ones")
	var moved := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "move_track": {"track": 2, "to": 0}}, true)
	_check(moved.contains("moved track 2 to position 0"), "move_track reports the move")
	anim = _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and String(anim.track_get_path(0)) == "Pic:modulate", "an up-move lands at the exact index")
	var down := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "move_track": {"track": 0, "to": 2}}, true)
	_check(down.contains("moved track 0 to position 2"), "a down-move reports")
	anim = _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and String(anim.track_get_path(2)) == "Pic:modulate", "a down-move lands at the exact index (insert-position compensated)")
	var removed := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "remove_track": {"track": "modulate"}}, true)
	_check(removed.contains("removed track 2"), "remove_track matches by path substring")
	anim = _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and anim.get_track_count() == 2, "the removal landed on disk")


func _test_insert_key() -> void:
	_write_edit_scene()
	var before := _text(EDIT_SCENE)
	var inserted := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "insert_key": {"track": "position", "time": 0.25, "value": "Vector2(4, -7)"}}, true)
	_check(inserted.contains("inserted key 1 at 0.25s"), "insert reports the landed index")
	var anim := _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and anim.track_get_key_value(0, 1) == Vector2(4, -7), "a Godot literal string landed as its typed value")
	# The splice must be minimal: the whole edit is one block regenerated, nothing else — measured as changed lines against the engine-canonical fixture.
	var after := _text(EDIT_SCENE)
	var diff := _changed_lines(before, after)
	# times, transitions, and values are three parallel array lines — an insert touches exactly those.
	_check(diff <= 3, "an insert_key touches only the animation's own key lines (%d line(s) changed)" % diff)
	var replaced := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "insert_key": {"track": 0, "time": 0.5, "value": "Vector2(9, 9)"}}, true)
	_check(replaced.contains("REPLACED"), "inserting at an occupied time states the replacement")
	anim = _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and anim.track_get_key_count(0) == 3, "the replacement did not add a key")
	var past := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "insert_key": {"track": 0, "time": 0.9, "value": "Vector2(0, 0)"}}, true)
	_check(past.contains("past the animation's 0.6s length"), "a key past the length is disclosed, not refused")
	var method := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "insert_key": {"track": 1, "time": 0.4, "value": {"method": "hop", "args": [2]}}}, true)
	_check(method.contains("hop(2)"), "a method key inserts with its call rendered")
	var bad_method := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "insert_key": {"track": 1, "time": 0.45, "value": "hop"}}, true)
	_check(bad_method.contains("{\"method\""), "a non-dict method value states the required shape")
	# The wild-caught shape mistake: method/args at the top level instead of nested under value must be named back, not silently ignored into "got null".
	var stray := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "insert_key": {"track": 1, "time": 0.45, "method": "hop", "args": []}}, true)
	_check(stray.contains("unknown field \"method\"") or stray.contains("unknown field \"args\""), "a stray insert_key field is named back")


func _test_set_key() -> void:
	_write_edit_scene()
	var combo := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "index": 0, "value": "Vector2(5, 5)", "time": 0.55}}, true)
	_check(combo.contains("value Vector2(0, 0) → Vector2(5, 5)") and combo.contains("time 0s → 0.55s"), "a combined value+retime reports both facts")
	var anim := _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and anim.track_get_key_time(0, 1) > 0.54 and anim.track_get_key_value(0, 1) == Vector2(5, 5), "the value landed on the retimed key — retime applied LAST")
	var by_time := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "at": 0.5, "transition": 0.5}}, true)
	_check(by_time.contains("transition 2 → 0.5"), "a key found by time changes its transition")
	var miss := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "at": 0.33, "value": "Vector2(0, 0)"}}, true)
	_check(miss.contains("no key at 0.33s") and miss.contains("0.5, 0.55"), "a time miss lists the real key times")
	var nothing := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "index": 0}}, true)
	_check(nothing.contains("changes something"), "a set_key changing nothing is refused")
	var swallow := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "at": 0.5, "time": 0.55}}, true)
	_check(swallow.contains("REPLACED") or _load_anim(EDIT_SCENE, "walk").track_get_key_count(0) == 2, "a retime onto an occupied time states the swallowed key")


func _test_remove_key() -> void:
	_write_edit_scene()
	var by_index := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "remove_key": {"track": 0, "index": 1}}, true)
	_check(by_index.contains("removed key 1 (0.5s: Vector2(10, 20))"), "remove by index reports what was removed")
	var anim := _load_anim(EDIT_SCENE, "walk")
	_check(anim != null and anim.track_get_key_count(0) == 1, "the removal landed on disk")
	var by_time := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "remove_key": {"track": 0, "at": 0.0}}, true)
	_check(by_time.contains("0 key(s) remain"), "remove by time reports the remaining count")
	var no_key := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "remove_key": {"track": 0, "index": 0}}, true)
	_check(no_key.contains("has no key 0") or no_key.contains("(none)"), "removing from an empty track states its emptiness")


func _test_3d_tracks() -> void:
	_write_edit_scene()
	var pos := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "insert_key": {"track": 0, "time": 0.5, "value": [1, 2, 3]}}, true)
	_check(pos.contains("Vector3(1, 2, 3)"), "a 3-array lands as Vector3 on a position_3d track")
	var rot := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "insert_key": {"track": 1, "time": 0.5, "value": [0, 0.479, 0, 0.878]}}, true)
	_check(rot.contains("Quaternion"), "a 4-array lands as Quaternion on a rotation_3d track")
	var wrong := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "insert_key": {"track": 0, "time": 0.6, "value": "sideways"}}, true)
	_check(wrong.contains("must be a Vector3"), "a wrong-shape 3D value names the required type")
	var anim := _load_anim(EDIT_SCENE, "attack/cast")
	_check(anim != null and anim.track_get_key_value(0, 1) == Vector3(1, 2, 3), "the 3D key landed on disk through the float-blob encoder")
	var blend := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "set_key": {"track": "Face", "at": 0.0, "value": 0.7}}, true)
	_check(blend.contains("0 → 0.7"), "a blend-shape key value changes")


func _test_bezier() -> void:
	_write_edit_scene()
	var inserted := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "insert_key": {"track": "modulate", "time": 0.5, "value": 0.0, "in_handle": [-0.2, 0], "out_handle": [0.2, 0]}}, true)
	_check(inserted.contains("(in Vector2(-0.2, 0), out Vector2(0.2, 0))"), "a bezier insert carries its handles")
	var anim := _load_anim(EDIT_SCENE, "attack/cast")
	var bezier_track := -1
	for i in anim.get_track_count():
		if anim.track_get_type(i) == Animation.TYPE_BEZIER:
			bezier_track = i
	_check(bezier_track >= 0 and anim.bezier_track_get_key_in_handle(bezier_track, 1) == Vector2(-0.2, 0), "the handles landed on disk")
	var handle := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "set_key": {"track": "modulate", "index": 0, "out_handle": [0.3, 0.1]}}, true)
	_check(handle.contains("out_handle → Vector2(0.3, 0.1)"), "a bezier handle changes alone")
	var transition := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "set_key": {"track": "modulate", "index": 0, "transition": 2}}, true)
	_check(transition.contains("store no per-key transition"), "a transition on a bezier track states the fact")
	var handle_on_value := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "index": 0, "in_handle": [0, 0]}}, true)
	_check(handle_on_value.contains("apply to bezier tracks"), "handles on a value track state the fact")


func _test_audio_ext_remap() -> void:
	_write_edit_scene()
	var inserted := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "jingle", "insert_key": {"track": 0, "time": 0.1, "stream": FIXTURE_STREAM}}, true)
	_check(inserted.contains("inserted key 0"), "an audio key inserts")
	var text := _text(EDIT_SCENE)
	_check(text.count("[ext_resource type=\"AudioStream\"") == 1, "the stream's ext_resource declaration was appended")
	var anim := _load_anim(EDIT_SCENE, "jingle")
	var stream: AudioStream = anim.audio_track_get_key_stream(0, 0) if anim != null else null
	_check(stream != null and stream.resource_path == FIXTURE_STREAM, "the audio key references the saved stream on disk")
	var second := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "jingle", "insert_key": {"track": 0, "time": 0.4, "stream": FIXTURE_STREAM}}, true)
	_check(second.contains("inserted key 1"), "a second audio key inserts")
	_check(_text(EDIT_SCENE).count("[ext_resource type=\"AudioStream\"") == 1, "the existing declaration is reused, not duplicated")
	var offset := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "jingle", "set_key": {"track": 0, "index": 0, "start_offset": 0.05}}, true)
	_check(offset.contains("start_offset → 0.05"), "an audio offset changes")
	var missing := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "jingle", "insert_key": {"track": 0, "time": 0.6, "stream": "res://nope.wav"}}, true)
	_check(missing.contains("could not be loaded"), "a missing stream path states the load failure")
	var not_stream := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "jingle", "insert_key": {"track": 0, "time": 0.6, "stream": FIXTURE_FRAMES}}, true)
	_check(not_stream.contains("not an AudioStream"), "a non-stream resource states its real class")


func _test_animation_track() -> void:
	_write_edit_scene()
	var inserted := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "insert_key": {"track": "SubPlayer", "time": 0.5, "value": "walk"}}, true)
	_check(inserted.contains("\"walk\""), "an animation-track key inserts by clip name")
	var set := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "attack/cast", "set_key": {"track": "SubPlayer", "at": 0.5, "value": "cast"}}, true)
	_check(set.contains("\"walk\" → \"cast\""), "an animation-track clip changes")
	var anim := _load_anim(EDIT_SCENE, "attack/cast")
	var anim_track := -1
	for i in anim.get_track_count():
		if anim.track_get_type(i) == Animation.TYPE_ANIMATION:
			anim_track = i
	_check(anim_track >= 0 and String(anim.animation_track_get_key_animation(anim_track, 1)) == "cast", "the clip change landed on disk")


func _test_library_add_remove() -> void:
	_write_edit_scene()
	var no_lib := await _run("edit_animation", {"scene": EDIT_SCENE, "add_animation": {"name": "dash"}}, true)
	_check(no_lib.contains("pass \"library\""), "two libraries demand naming one")
	var added := await _run("edit_animation", {"scene": EDIT_SCENE, "add_animation": {"name": "dash", "library": "", "length": 0.3, "loop": "linear"}}, true)
	_check(added.contains("Added animation \"dash\""), "add_animation reports")
	var anim := _load_anim(EDIT_SCENE, "dash")
	_check(anim != null and absf(anim.length - 0.3) < 0.001 and anim.loop_mode == Animation.LOOP_LINEAR, "the new animation landed with its length and loop")
	var text := _text(EDIT_SCENE)
	# The default library sorts dash, grad, jingle, walk — the new entry must sit where the engine would put it.
	_check(text.find("&\"dash\"") != -1 and text.find("&\"dash\"") < text.find("&\"grad\""), "the _data entry landed in the engine's sorted position")
	var dup := await _run("edit_animation", {"scene": EDIT_SCENE, "add_animation": {"name": "dash", "library": ""}}, true)
	_check(dup.contains("already has an animation \"dash\""), "a duplicate name states the collision")
	var bad_name := await _run("edit_animation", {"scene": EDIT_SCENE, "add_animation": {"name": "da:sh", "library": ""}}, true)
	_check(bad_name.contains("engine refused"), "an engine-invalid name surfaces the engine's verdict")
	var qualified := await _run("edit_animation", {"scene": EDIT_SCENE, "add_animation": {"name": "attack/slam"}}, true)
	_check(qualified.contains("Added animation \"slam\"") and qualified.contains("library \"attack\""), "a qualified name picks its library")
	var removed := await _run("edit_animation", {"scene": EDIT_SCENE, "remove_animation": {"name": "dash", "library": ""}}, true)
	_check(removed.contains("Removed animation \"dash\""), "remove_animation reports")
	_check(not _text(EDIT_SCENE).contains("dash"), "the removed animation's entry and block are gone")
	_check(_load_anim(EDIT_SCENE, "walk") != null, "the scene still loads with its other animations")
	var no_anim := await _run("edit_animation", {"scene": EDIT_SCENE, "remove_animation": {"name": "zzz", "library": ""}}, true)
	_check(no_anim.contains("has no animation \"zzz\""), "removing a missing name lists the real ones")


func _test_standalone_and_empty_library() -> void:
	var added := await _run("edit_animation", {"scene": FIXTURE_LIB, "add_animation": {"name": "leap", "length": 0.4}}, true)
	_check(added.contains("Added animation \"leap\""), "add_animation works on a standalone library .tres")
	var lib: AnimationLibrary = ResourceLoader.load(FIXTURE_LIB, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(lib != null and lib.has_animation("leap"), "the standalone library holds the new animation")
	var removed := await _run("edit_animation", {"scene": FIXTURE_LIB, "remove_animation": "leap"}, true)
	_check(removed.contains("Removed animation \"leap\""), "a bare-string spec removes by name")
	lib = ResourceLoader.load(FIXTURE_LIB, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(lib != null and not lib.has_animation("leap"), "the standalone removal landed")
	var into_empty := await _run("edit_animation", {"scene": FIXTURE_EMPTY_LIB, "add_animation": {"name": "first"}}, true)
	_check(into_empty.contains("Added animation \"first\""), "an empty library (no _data line) accepts its first animation")
	var empty_lib: AnimationLibrary = ResourceLoader.load(FIXTURE_EMPTY_LIB, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(empty_lib != null and empty_lib.has_animation("first"), "the first animation landed in the once-empty library")
	var solo := await _run("edit_animation", {"scene": FIXTURE_ANIM, "add_animation": {"name": "x"}}, true)
	_check(solo.contains("single Animation resource, not a library"), "add_animation on an Animation .tres states the mismatch")


func _test_ext_library_redirect() -> void:
	var scene_before := _text(EXT_SCENE)
	var edited := await _run("edit_animation", {"scene": EXT_SCENE, "animation": "spin", "set_key": {"track": 0, "index": 0, "value": "Vector2(3, 3)"}}, true)
	_check(edited.contains("written THERE") and edited.contains(FIXTURE_EXT_LIB), "an ext-library edit discloses where it landed")
	_check(_text(EXT_SCENE) == scene_before, "the scene file is byte-untouched")
	var lib: AnimationLibrary = ResourceLoader.load(FIXTURE_EXT_LIB, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(lib != null and lib.get_animation("spin").track_get_key_value(0, 0) == Vector2(3, 3), "the edit landed in the library's own file")
	var added := await _run("edit_animation", {"scene": EXT_SCENE, "add_animation": {"name": "orbit"}}, true)
	_check(added.contains("written THERE"), "add_animation follows the storage too")
	lib = ResourceLoader.load(FIXTURE_EXT_LIB, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(lib != null and lib.has_animation("orbit"), "the new animation landed in the library file")
	_check(_text(EXT_SCENE) == scene_before, "the scene file is still byte-untouched")


func _test_embedded_resource_refusal() -> void:
	_write_edit_scene()
	var before := _text(EDIT_SCENE)
	var refused := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "grad", "set_key": {"track": 0, "index": 0, "time": 0.1}}, true)
	_check(refused.contains("embedded"), "a key holding an embedded resource states the limit")
	_check(_text(EDIT_SCENE) == before, "the refused edit wrote nothing")


func _test_noop_and_refusals() -> void:
	_write_edit_scene()
	var before := _text(EDIT_SCENE)
	var noop := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "index": 1, "value": "Vector2(10, 20)"}}, true)
	_check(noop.contains("the file was not rewritten"), "an identical value is an honest no-op")
	_check(_text(EDIT_SCENE) == before, "the no-op wrote nothing")
	var no_action := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk"}, true)
	_check(no_action.contains("no action was given"), "a missing action lists the real ones")
	var two := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_key": {"track": 0, "index": 0, "value": 1}, "remove_key": {"track": 0, "index": 0}}, true)
	_check(two.contains("one action per call"), "two actions are refused")
	var no_anim := await _run("edit_animation", {"scene": EDIT_SCENE, "set_key": {"track": 0, "index": 0, "value": 1}}, true)
	_check(no_anim.contains("no animation was named"), "a track edit without an animation says so")
	var binary := await _run("edit_animation", {"scene": FIXTURE_BIN, "set_key": {"track": 0, "index": 0, "value": 1}}, true)
	_check(binary.contains("binary file"), "a binary .res cannot be text-spliced and says so")
	var frames := await _run("edit_animation", {"scene": FIXTURE_FRAMES, "animation": "default", "set_key": {"track": 0, "index": 0, "value": 1}}, true)
	_check(frames.contains("SpriteFrames") and frames.contains("edit_file"), "a SpriteFrames edit points at the text route")
	var scalars := await _run("edit_animation", {"scene": EDIT_SCENE, "animation": "walk", "set_length": 0.5}, true)
	_check(scalars.contains("set_length"), "an unknown action names itself in the refusal")


## Count the lines that differ between two texts of (possibly) different lengths — the minimal-diff yardstick.
func _changed_lines(a: String, b: String) -> int:
	var lines_a := a.split("\n")
	var lines_b := b.split("\n")
	if lines_a.size() != lines_b.size():
		return absi(lines_a.size() - lines_b.size()) + 1000
	var changed := 0
	for i in lines_a.size():
		if lines_a[i] != lines_b[i]:
			changed += 1
	return changed


func _cleanup() -> void:
	for path in [EDIT_SCENE, EMPTY_SCENE, EXT_SCENE, FIXTURE_ANIM, FIXTURE_LIB, FIXTURE_EMPTY_LIB, FIXTURE_EXT_LIB, FIXTURE_STREAM, FIXTURE_FRAMES, FIXTURE_BIN]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(String(path)))
