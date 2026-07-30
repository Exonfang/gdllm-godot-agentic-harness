@tool
class_name GDLLMAnimation extends RefCounted
## Engine-truth access to ANIMATION content — keyframes serialize as parallel packed arrays and interleaved float blobs no text read renders and no text edit can safely rewrite.
## The tool surface is derived from docs/animation-api-audit.md: every engine function whose serialized form is NOT a whole-line text edit gets an op here; everything that IS stays with edit_file and is deliberately absent.
## The keystone mirrors the tilemap suite: the ENGINE decodes and encodes for us — SceneState property values yield real Animation objects off-tree, and ResourceSaver's [resource] body for one is byte-identical to the .tscn sub_resource body, so nothing here parses or assembles the key arrays by hand.
## Errors surface what happened — the failing input and the real state — with no remedial advice built in; where the engine accepts an input silently, so does this.
## Every method is static — this is a namespace, not an instance.

## Keys listed per track before the rest collapse and the `window` lever is named.
const MAX_KEYS_LISTED := 24
## Animations listed per player before the rest collapse to a count.
const MAX_ANIMATIONS_LISTED := 40
## Tracks rendered per zoomed animation before the rest collapse to a count.
const MAX_TRACKS_LISTED := 40
## Rendered key values past this are clipped — a giant value must never flood the context.
const MAX_VALUE_CHARS := 120
## The one action spec each edit_animation call carries.
const EDIT_ACTION_KEYS: Array[String] = ["add_track", "remove_track", "move_track", "insert_key", "set_key", "remove_key", "add_animation", "remove_animation"]
## Animation.TrackType values as words, indexed by the enum.
const TRACK_TYPE_NAMES: Array[String] = ["value", "position_3d", "rotation_3d", "scale_3d", "blend_shape", "method", "bezier", "audio", "animation"]
## Animation.InterpolationType values as words, indexed by the enum.
const INTERP_NAMES: Array[String] = ["nearest", "linear", "cubic", "linear angle", "cubic angle"]
## Animation.UpdateMode values as words, indexed by the enum.
const UPDATE_NAMES: Array[String] = ["continuous", "discrete", "capture"]
## Animation.LoopMode values as words, indexed by the enum.
const LOOP_NAMES: Array[String] = ["none", "linear", "pingpong"]
## Key times within this are the same key — stored times are float32, so an exact float match on a JSON time fails.
const KEY_TIME_EPSILON := 0.0005
## The one-line split of edit routes, appended to zoomed reads. The claim is the true risk, not an impossibility — a wild session text-edited value-track keys correctly four times, so "not text-editable" would be a lie; what edit_animation actually buys is engine-kept alignment of the parallel arrays and the opaque 3D/bezier blobs.
const EDIT_POINTER := "Edits: edit_animation changes tracks and keys through the engine — their parallel arrays must stay index-aligned and time-sorted, and 3D/bezier keys are packed float blobs. Scalar lines (length, loop_mode, step, tracks/N/path, interp, enabled, update) are plain text: edit_file."


## ==== Reading (describe_animation) ====


## Collect every AnimationPlayer stored in a packed scene's state — no instantiation, so no script runs.
## AnimatedSprite2D/3D nodes are counted, not decoded: SpriteFrames serialize as plain text (audit verdict: read_file covers them).
static func players_from_state(state: SceneState) -> Dictionary:
	var players: Array = []
	var sprite_count := 0
	var node_paths := {}
	var has_instances := false
	for i in state.get_node_count():
		node_paths[_state_path(state, i)] = true
		if i > 0 and state.get_node_instance(i) != null:
			has_instances = true
		var type := String(state.get_node_type(i))
		if type == "":
			continue
		if ClassDB.is_parent_class(type, "AnimationPlayer"):
			var record := _blank_player(_state_path(state, i))
			for j in state.get_node_property_count(i):
				var prop := String(state.get_node_property_name(i, j))
				var value: Variant = state.get_node_property_value(i, j)
				if prop.begins_with("libraries/") and value is AnimationLibrary:
					(record["libraries"] as Array).append({"name": prop.trim_prefix("libraries/"), "library": value})
				elif prop == "autoplay":
					record["autoplay"] = String(value)
				elif prop == "root_node" and value is NodePath:
					record["root_node"] = String(value)
				elif prop == "script" and value is Script:
					record["script"] = (value as Script).resource_path
			players.append(record)
		elif ClassDB.is_parent_class(type, "AnimatedSprite2D") or ClassDB.is_parent_class(type, "AnimatedSprite3D"):
			sprite_count += 1
	return {"players": players, "sprite_count": sprite_count, "node_paths": node_paths, "has_instances": has_instances}


## Collect the same records from a live edited tree — one record shape, so the composer never cares which mode fed it.
static func players_from_live(root: Node) -> Dictionary:
	var players: Array = []
	var sprite_count := 0
	var node_paths := {}
	var nodes: Array = []
	_collect_nodes(root, nodes)
	for node: Node in nodes:
		node_paths[String(root.get_path_to(node))] = true
		if node is AnimationPlayer:
			var player := node as AnimationPlayer
			var record := _blank_player(String(root.get_path_to(node)))
			record["autoplay"] = player.autoplay
			record["root_node"] = String(player.root_node)
			record["script"] = _script_path(node)
			for lib_name in player.get_animation_library_list():
				(record["libraries"] as Array).append({"name": String(lib_name), "library": player.get_animation_library(lib_name)})
			players.append(record)
		elif node is AnimatedSprite2D or node is AnimatedSprite3D:
			sprite_count += 1
	return {"players": players, "sprite_count": sprite_count, "node_paths": node_paths, "has_instances": false}


## Flatten one player's libraries into animation entries — the key is what play() takes: "lib/name", bare for the default library.
static func animation_entries(player: Dictionary) -> Array:
	var entries: Array = []
	for lib_entry: Dictionary in player["libraries"]:
		var lib_name := String(lib_entry["name"])
		var lib := lib_entry["library"] as AnimationLibrary
		if lib == null:
			continue
		for anim_name in lib.get_animation_list():
			var key := String(anim_name) if lib_name == "" else "%s/%s" % [lib_name, anim_name]
			entries.append({"key": key, "library": lib_name, "name": String(anim_name), "animation": lib.get_animation(anim_name), "player": player})
	return entries


## Match one AnimationPlayer by exact path, unique leaf name, or unique substring — every miss lists the real paths.
static func match_player(players: Array, query: String) -> Dictionary:
	if players.is_empty():
		return {"error": "Error: this scene has no AnimationPlayer nodes to match \"%s\" against." % query}
	var lowered := query.to_lower()
	for record: Dictionary in players:
		if String(record["path"]).to_lower() == lowered:
			return {"player": record}
	var by_name: Array = players.filter(func(r: Dictionary) -> bool: return String(r["path"]).get_file().to_lower() == lowered)
	if by_name.size() == 1:
		return {"player": by_name[0]}
	var by_substring: Array = players.filter(func(r: Dictionary) -> bool: return String(r["path"]).to_lower().contains(lowered))
	if by_substring.size() == 1:
		return {"player": by_substring[0]}
	return {"error": "Error: no single AnimationPlayer matches \"%s\". The players are: %s." % [query, _player_name_list(players)]}


## Match one animation by its qualified key ("attack/back"), bare name, or unique substring, across every listed player — an ambiguity or miss lists the real keys.
static func match_animation(players: Array, query: String) -> Dictionary:
	var entries: Array = []
	for player: Dictionary in players:
		entries.append_array(animation_entries(player))
	if entries.is_empty():
		return {"error": "Error: %s no AnimationPlayer animations exist to match \"%s\" against." % [_players_scope(players), query]}
	var lowered := query.to_lower()
	var exact: Array = entries.filter(func(e: Dictionary) -> bool: return String(e["key"]).to_lower() == lowered)
	if exact.size() == 1:
		return {"entry": exact[0]}
	var by_name: Array = entries.filter(func(e: Dictionary) -> bool: return String(e["name"]).to_lower() == lowered)
	if by_name.size() == 1:
		return {"entry": by_name[0]}
	if exact.size() > 1 or by_name.size() > 1:
		var hits: Array = exact if exact.size() > 1 else by_name
		return {"error": "Error: %d animations match \"%s\": %s." % [hits.size(), query, _entry_key_list(hits, players.size() > 1)]}
	var by_substring: Array = entries.filter(func(e: Dictionary) -> bool: return String(e["key"]).to_lower().contains(lowered))
	if by_substring.size() == 1:
		return {"entry": by_substring[0]}
	if by_substring.size() > 1:
		return {"error": "Error: \"%s\" matches %d animations: %s." % [query, by_substring.size(), _entry_key_list(by_substring, players.size() > 1)]}
	return {"error": "Error: no animation matches \"%s\". The animations are: %s." % [query, _entry_key_list(entries, players.size() > 1)]}


## Parse a [start_sec, end_sec] window value — the time analog of the tilemap rect.
static func parse_window(value: Variant) -> Dictionary:
	if not value is Array or (value as Array).size() != 2:
		return {"error": "Error: \"window\" takes [start_sec, end_sec] as two numbers, e.g. [0.0, 0.5]."}
	var numbers: Array[float] = []
	for item in (value as Array):
		if not (item is int or item is float):
			return {"error": "Error: \"window\" takes [start_sec, end_sec] as two numbers, e.g. [0.0, 0.5]."}
		numbers.append(float(item))
	if numbers[1] <= numbers[0]:
		return {"error": "Error: the window's end (%s) must be after its start (%s)." % [time_str(numbers[1]), time_str(numbers[0])]}
	return {"window": Vector2(numbers[0], numbers[1])}


## Compose the scene-mode report: an all-players overview, or one animation's tracks and keys when `anim_query` selects one.
## `scope` names what was searched ("the edited scene \"YSort\"", "res://player.tscn") so a miss never leaves the searched place unnamed.
static func compose_report(origin: String, scan: Dictionary, anim_query: String, player_query: String, window: Vector2, has_window: bool, scope := "") -> String:
	var players: Array = scan["players"]
	if player_query != "":
		var matched := match_player(players, player_query)
		if matched.has("error"):
			return _scoped_error(String(matched["error"]), scope, scan)
		players = [matched["player"]]
	if anim_query == "" and has_window:
		return "Error: \"window\" narrows ONE animation's key listing — pass \"animation\" naming which; the no-argument overview lists them."
	if anim_query != "":
		var found := match_animation(players, anim_query)
		if found.has("error"):
			return _scoped_error(String(found["error"]), scope, scan)
		return compose_zoom(origin, found["entry"], window, has_window)
	return _compose_overview(origin, scan, players, player_query != "")


## A match error with the searched place named and, when the scene animates through SpriteFrames instead, that fact stated.
static func _scoped_error(error: String, scope: String, scan: Dictionary) -> String:
	var out := error
	if scope != "":
		out = out.trim_suffix(".") + " (searched %s)." % scope
	if int(scan.get("sprite_count", 0)) > 0:
		out += " The scene's %d AnimatedSprite2D/3D node(s) hold SpriteFrames animations, which serialize as plain text — read_file shows them." % int(scan["sprite_count"])
	return out


## One zoomed animation: header scalars with named enum values, then per-track key listings, windowed and capped.
static func compose_zoom(origin: String, entry: Dictionary, window: Vector2, has_window: bool) -> String:
	var anim := entry["animation"] as Animation
	var player: Dictionary = entry["player"]
	var lib_label := "the default library" if String(entry["library"]) == "" else "library \"%s\"" % entry["library"]
	var lines: Array = [origin]
	lines.append("Animation \"%s\" (%s on \"%s\") — %s" % [entry["key"], lib_label, player["path"], anim_header(anim)])
	if has_window:
		lines.append("Showing keys in window %s..%ss — track and key totals cover the whole animation." % [time_str(window.x), time_str(window.y)])
	lines.append("")
	lines.append_array(_track_lines(anim, window, has_window))
	lines.append("")
	lines.append(EDIT_POINTER)
	return "\n".join(PackedStringArray(lines))


## Describe a standalone animation resource: an Animation zooms directly, an AnimationLibrary lists (anim_query zooms). Returns "" for a resource class this tool does not read.
static func describe_resource(resource: Resource, origin: String, anim_query: String, window: Vector2, has_window: bool) -> String:
	if resource is Animation:
		var lines: Array = [origin]
		lines.append("Animation — %s" % anim_header(resource as Animation))
		if has_window:
			lines.append("Showing keys in window %s..%ss — track and key totals cover the whole animation." % [time_str(window.x), time_str(window.y)])
		lines.append("")
		lines.append_array(_track_lines(resource as Animation, window, has_window))
		lines.append("")
		lines.append("Track paths resolve relative to whichever AnimationPlayer plays this animation, not to this file.")
		lines.append(EDIT_POINTER)
		return "\n".join(PackedStringArray(lines))
	if resource is AnimationLibrary:
		var lib := resource as AnimationLibrary
		var player := _blank_player("(standalone library)")
		(player["libraries"] as Array).append({"name": "", "library": lib})
		if anim_query != "":
			var found := match_animation([player], anim_query)
			if found.has("error"):
				return String(found["error"])
			var anim := found["entry"]["animation"] as Animation
			var lines: Array = [origin]
			lines.append("Animation \"%s\" in this library — %s" % [found["entry"]["key"], anim_header(anim)])
			lines.append("")
			lines.append_array(_track_lines(anim, window, has_window))
			lines.append("")
			lines.append("Track paths resolve relative to whichever AnimationPlayer uses this library, not to this file.")
			lines.append(EDIT_POINTER)
			return "\n".join(PackedStringArray(lines))
		if has_window:
			return "Error: \"window\" narrows ONE animation's key listing — pass \"animation\" naming which of this library's animations: %s." % ", ".join(lib.get_animation_list())
		var lines: Array = [origin]
		lines.append("AnimationLibrary — %d animation(s):" % lib.get_animation_list().size())
		lines.append_array(_library_lines("  ", lib))
		lines.append("")
		lines.append("Pass \"animation\" (a name above) for one animation's tracks and keys.")
		return "\n".join(PackedStringArray(lines))
	return ""


## ==== Editing (edit_animation) — the write half, same engine-encoder keystone. ====


## Resolve one track by index or by path substring — every miss or ambiguity lists the real tracks with their indices.
static func match_track(anim: Animation, query: Variant) -> Dictionary:
	if anim.get_track_count() == 0:
		return {"error": "Error: this animation has no tracks."}
	if query == null:
		return {"error": "Error: no \"track\" was given — an index or a track path. " + track_list(anim)}
	if query is int or query is float or (query is String and String(query).is_valid_int()):
		var idx := int(query) if not query is String else String(query).to_int()
		if idx < 0 or idx >= anim.get_track_count():
			return {"error": "Error: track %d does not exist — this animation has %d track(s). %s" % [idx, anim.get_track_count(), track_list(anim)]}
		return {"track": idx}
	if not query is String:
		return {"error": "Error: \"track\" is an integer index or a track-path string. " + track_list(anim)}
	var lowered := String(query).to_lower()
	var hits: Array[int] = []
	for i in anim.get_track_count():
		var path := String(anim.track_get_path(i)).to_lower()
		if path == lowered:
			return {"track": i}
		if path.contains(lowered):
			hits.append(i)
	if hits.size() == 1:
		return {"track": hits[0]}
	if hits.size() > 1:
		return {"error": "Error: \"%s\" matches %d tracks. %s" % [query, hits.size(), track_list(anim)]}
	return {"error": "Error: no track path contains \"%s\". %s" % [query, track_list(anim)]}


## Resolve one key from a spec body: "index" directly, or "at" as a time tolerating float32 storage error — a miss lists the track's real key times.
static func find_key(anim: Animation, track: int, body: Dictionary) -> Dictionary:
	if body.has("index") or body.has("key"):
		var raw: Variant = body.get("index", body.get("key"))
		if not (raw is int or raw is float):
			return {"error": "Error: \"index\" must be an integer, got %s." % value_string(raw)}
		var idx := int(raw)
		if idx < 0 or idx >= anim.track_get_key_count(track):
			return {"error": "Error: track %d has no key %d — it has %d key(s), at: %s." % [track, idx, anim.track_get_key_count(track), key_time_list(anim, track)]}
		return {"key": idx}
	if body.has("at"):
		var at := _as_float(body.get("at"), "at")
		if at.has("error"):
			return at
		for k in anim.track_get_key_count(track):
			if absf(anim.track_get_key_time(track, k) - float(at["value"])) < KEY_TIME_EPSILON:
				return {"key": k}
		return {"error": "Error: track %d has no key at %ss. Its key times are: %s." % [track, time_str(float(at["value"])), key_time_list(anim, track)]}
	return {"error": "Error: no key was named — pass \"index\" (from describe_animation's listing) or \"at\" (a key's time in seconds)."}


## Parse one incoming value: strings are tried as Godot literals through the engine's own parser ("Vector2(4, -7)", "Color(1, 0, 0, 1)"), falling back to the raw string; everything else passes through.
static func parse_value(raw: Variant) -> Variant:
	if raw is String:
		var parsed: Variant = str_to_var(raw)
		return parsed if parsed != null else raw
	return raw


## Validate and apply one action to an off-tree Animation through the engine's own API. Mutation only happens past every check, and the caller discards the object on error, so a refusal never half-applies.
static func apply_edit(anim: Animation, action: String, raw: Variant) -> Dictionary:
	var body: Dictionary = raw if raw is Dictionary else {}
	match action:
		"add_track":
			if not raw is Dictionary:
				return {"error": "Error: \"add_track\" takes {\"type\": one of %s, \"path\": \"Node:property\", \"index\"?: int}." % ", ".join(TRACK_TYPE_NAMES)}
			var type_idx := TRACK_TYPE_NAMES.find(String(body.get("type", "")))
			if type_idx < 0:
				return {"error": "Error: \"%s\" is not a track type. The types are: %s." % [str(body.get("type", "")), ", ".join(TRACK_TYPE_NAMES)]}
			var path := String(body.get("path", ""))
			if path == "":
				return {"error": "Error: \"add_track\" needs a \"path\" — the NodePath the track animates, e.g. \"Sprite2D:frame\"."}
			var at := -1
			if body.has("index"):
				var idx := _as_int(body.get("index"), "index")
				if idx.has("error"):
					return idx
				at = int(idx["value"])
				if at < 0 or at > anim.get_track_count():
					return {"error": "Error: index %d is outside 0..%d (the animation has %d track(s))." % [at, anim.get_track_count(), anim.get_track_count()]}
			var new_idx := anim.add_track(type_idx, at)
			if new_idx < 0:
				return {"error": "Error: the engine refused to add the track (add_track returned %d)." % new_idx}
			anim.track_set_path(new_idx, NodePath(path))
			return {"line": "added track %d — %s \"%s\", no keys yet" % [new_idx, TRACK_TYPE_NAMES[type_idx], path]}
		"remove_track":
			var track := match_track(anim, body.get("track") if raw is Dictionary else raw)
			if track.has("error"):
				return track
			var t := int(track["track"])
			var label := "%s \"%s\"" % [track_type_name(anim.track_get_type(t)), anim.track_get_path(t)]
			var keys := anim.track_get_key_count(t)
			anim.remove_track(t)
			var renumber := " — later tracks renumbered down" if t < anim.get_track_count() else ""
			return {"line": "removed track %d (%s) and its %d key(s)%s" % [t, label, keys, renumber]}
		"move_track":
			if not raw is Dictionary:
				return {"error": "Error: \"move_track\" takes {\"track\": index-or-path, \"to\": int}."}
			var track := match_track(anim, body.get("track"))
			if track.has("error"):
				return track
			var to := _as_int(body.get("to"), "to")
			if to.has("error"):
				return to
			var t := int(track["track"])
			var dest := int(to["value"])
			if dest < 0 or dest >= anim.get_track_count():
				return {"error": "Error: \"to\" %d is outside 0..%d." % [dest, anim.get_track_count() - 1]}
			if dest == t:
				return {"line": "track %d is already at position %d" % [t, dest]}
			# track_move_to takes an insert-before position, which after the removal lands one short when moving down — compensated so "to" means the final index.
			anim.track_move_to(t, dest + 1 if dest > t else dest)
			return {"line": "moved track %d to position %d — tracks between renumbered" % [t, dest]}
		"insert_key":
			if not raw is Dictionary:
				return {"error": "Error: \"insert_key\" takes {\"track\": index-or-path, \"time\": seconds, \"value\": ... (shape depends on the track type), \"transition\"?: float}."}
			return _apply_insert_key(anim, body)
		"set_key":
			if not raw is Dictionary:
				return {"error": "Error: \"set_key\" takes {\"track\": index-or-path, \"index\" or \"at\", then any of \"value\", \"time\", \"transition\", \"in_handle\"/\"out_handle\" (bezier), \"stream\"/\"start_offset\"/\"end_offset\" (audio)}."}
			return _apply_set_key(anim, body)
		"remove_key":
			if not raw is Dictionary:
				return {"error": "Error: \"remove_key\" takes {\"track\": index-or-path, \"index\" or \"at\"}."}
			var track := match_track(anim, body.get("track"))
			if track.has("error"):
				return track
			var t := int(track["track"])
			var key := find_key(anim, t, body)
			if key.has("error"):
				return key
			var k := int(key["key"])
			var was := "%ss: %s" % [time_str(anim.track_get_key_time(t, k)), key_value_string(anim, t, k)]
			anim.track_remove_key(t, k)
			return {"line": "removed key %d (%s) from track %d — %d key(s) remain" % [k, was, t, anim.track_get_key_count(t)]}
	return {"error": "Error: unknown action \"%s\"." % action}


## The type-dispatched half of insert_key — each track type's value shape follows its engine insert function's signature.
static func _apply_insert_key(anim: Animation, body: Dictionary) -> Dictionary:
	# A stray field silently ignored reads as accepted — a wild session sent top-level method/args, was told only "got null", and burned 8 calls; the strays must be named (set_key already does this).
	var known := ["track", "time", "value", "transition", "in_handle", "out_handle", "stream", "start_offset", "end_offset"]
	for arg_key in body:
		if not String(arg_key) in known:
			return {"error": "Error: \"insert_key\" got an unknown field \"%s\" — the fields are: %s." % [arg_key, ", ".join(PackedStringArray(known))]}
	var track := match_track(anim, body.get("track"))
	if track.has("error"):
		return track
	var t := int(track["track"])
	var at := _as_float(body.get("time"), "time")
	if at.has("error"):
		return at
	var time := float(at["value"])
	var type := anim.track_get_type(t)
	var before := anim.track_get_key_count(t)
	var idx := -1
	match type:
		Animation.TYPE_VALUE:
			if not body.has("value"):
				return {"error": "Error: \"insert_key\" on a value track needs a \"value\"."}
			idx = anim.track_insert_key(t, time, parse_value(body.get("value")))
		Animation.TYPE_METHOD:
			var call := _as_method_call(body.get("value"))
			if call.has("error"):
				return call
			idx = anim.track_insert_key(t, time, call["value"])
		Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D:
			var v3 := _as_vector3(body.get("value"), "value")
			if v3.has("error"):
				return v3
			idx = anim.track_insert_key(t, time, v3["value"])
		Animation.TYPE_ROTATION_3D:
			var q := _as_quaternion(body.get("value"), "value")
			if q.has("error"):
				return q
			idx = anim.track_insert_key(t, time, q["value"])
		Animation.TYPE_BLEND_SHAPE:
			var f := _as_float(body.get("value"), "value")
			if f.has("error"):
				return f
			idx = anim.track_insert_key(t, time, float(f["value"]))
		Animation.TYPE_BEZIER:
			var f := _as_float(body.get("value"), "value")
			if f.has("error"):
				return f
			var in_h := _as_vector2(body.get("in_handle", Vector2.ZERO), "in_handle")
			if in_h.has("error"):
				return in_h
			var out_h := _as_vector2(body.get("out_handle", Vector2.ZERO), "out_handle")
			if out_h.has("error"):
				return out_h
			idx = anim.bezier_track_insert_key(t, time, float(f["value"]), in_h["value"], out_h["value"])
		Animation.TYPE_AUDIO:
			var stream := _as_stream(body.get("stream"))
			if stream.has("error"):
				return stream
			var offsets := {"start_offset": 0.0, "end_offset": 0.0}
			for field in ["start_offset", "end_offset"]:
				if body.has(field):
					var f := _as_float(body.get(field), field)
					if f.has("error"):
						return f
					offsets[field] = float(f["value"])
			idx = anim.audio_track_insert_key(t, time, stream["value"], float(offsets["start_offset"]), float(offsets["end_offset"]))
		Animation.TYPE_ANIMATION:
			var clip: Variant = body.get("value")
			if not clip is String or String(clip) == "":
				return {"error": "Error: \"insert_key\" on an animation track takes \"value\" as the clip's animation name string, got %s." % value_string(clip)}
			idx = anim.animation_track_insert_key(t, time, String(clip))
	if idx < 0:
		return {"error": "Error: the engine refused the key (its insert function returned %d) — the value was %s." % [idx, value_string(body.get("value"))]}
	if body.has("transition"):
		var gate := _transition_gate(type)
		if gate != "":
			return {"error": gate}
		var tr := _as_float(body.get("transition"), "transition")
		if tr.has("error"):
			return tr
		anim.track_set_key_transition(t, idx, float(tr["value"]))
	var verb := "inserted key %d" % idx
	# The engine replaces silently when a key already sits at the time (probed: the count stays flat) — the result must not read as a second key.
	if anim.track_get_key_count(t) == before:
		verb = "REPLACED the key already at that time (key %d)" % idx
	var past := "" if time <= anim.length else " — past the animation's %ss length" % time_str(anim.length)
	return {"line": "%s at %ss on track %d (%s \"%s\") — now %s%s" % [verb, time_str(time), t, track_type_name(type), anim.track_get_path(t), key_value_string(anim, t, idx), past]}


## The type-dispatched half of set_key — value/handles/stream/offsets/transition first, the retime LAST, because track_set_key_time re-sorts keys and would invalidate the index mid-edit.
static func _apply_set_key(anim: Animation, body: Dictionary) -> Dictionary:
	var track := match_track(anim, body.get("track"))
	if track.has("error"):
		return track
	var t := int(track["track"])
	var key := find_key(anim, t, body)
	if key.has("error"):
		return key
	var k := int(key["key"])
	var type := anim.track_get_type(t)
	var known := ["track", "index", "key", "at", "value", "time", "transition", "in_handle", "out_handle", "stream", "start_offset", "end_offset"]
	for arg_key in body:
		if not String(arg_key) in known:
			return {"error": "Error: \"set_key\" got an unknown field \"%s\" — the fields are: %s." % [arg_key, ", ".join(PackedStringArray(known))]}
	var changes := PackedStringArray()
	if body.has("value"):
		var applied := _set_key_value(anim, t, k, type, body.get("value"), changes)
		if applied.has("error"):
			return applied
	if body.has("in_handle") or body.has("out_handle"):
		if type != Animation.TYPE_BEZIER:
			return {"error": "Error: \"in_handle\"/\"out_handle\" apply to bezier tracks; track %d is a %s track." % [t, track_type_name(type)]}
		for field in ["in_handle", "out_handle"]:
			if not body.has(field):
				continue
			var v2 := _as_vector2(body.get(field), field)
			if v2.has("error"):
				return v2
			if field == "in_handle":
				anim.bezier_track_set_key_in_handle(t, k, v2["value"])
			else:
				anim.bezier_track_set_key_out_handle(t, k, v2["value"])
			changes.append("%s → %s" % [field, var_to_str(v2["value"])])
	if body.has("stream") or body.has("start_offset") or body.has("end_offset"):
		if type != Animation.TYPE_AUDIO:
			return {"error": "Error: \"stream\"/\"start_offset\"/\"end_offset\" apply to audio tracks; track %d is a %s track." % [t, track_type_name(type)]}
		if body.has("stream"):
			var stream := _as_stream(body.get("stream"))
			if stream.has("error"):
				return stream
			anim.audio_track_set_key_stream(t, k, stream["value"])
			changes.append("stream → %s" % value_string(stream["value"]))
		for field in ["start_offset", "end_offset"]:
			if not body.has(field):
				continue
			var f := _as_float(body.get(field), field)
			if f.has("error"):
				return f
			if field == "start_offset":
				anim.audio_track_set_key_start_offset(t, k, float(f["value"]))
			else:
				anim.audio_track_set_key_end_offset(t, k, float(f["value"]))
			changes.append("%s → %s" % [field, time_str(float(f["value"]))])
	if body.has("transition"):
		var gate := _transition_gate(type)
		if gate != "":
			return {"error": gate}
		var tr := _as_float(body.get("transition"), "transition")
		if tr.has("error"):
			return tr
		var old_tr := anim.track_get_key_transition(t, k)
		anim.track_set_key_transition(t, k, float(tr["value"]))
		changes.append("transition %s → %s" % [num_str(old_tr), num_str(float(tr["value"]))])
	if body.has("time"):
		var new_time := _as_float(body.get("time"), "time")
		if new_time.has("error"):
			return new_time
		var old_time := anim.track_get_key_time(t, k)
		var count_before := anim.track_get_key_count(t)
		anim.track_set_key_time(t, k, float(new_time["value"]))
		changes.append("time %ss → %ss" % [time_str(old_time), time_str(float(new_time["value"]))])
		# A retime onto an occupied time can swallow the key that was there — a fact the caller cannot see in the result otherwise.
		if anim.track_get_key_count(t) < count_before:
			changes.append("the key previously at %ss was REPLACED by this one" % time_str(float(new_time["value"])))
		k = -1
	if changes.is_empty():
		return {"error": "Error: \"set_key\" changes something about the key — pass \"value\", \"time\", \"transition\", or a type-specific field."}
	var where := "key %d of track %d" % [k, t] if k >= 0 else "the key on track %d" % t
	return {"line": "%s: %s" % [where, "; ".join(changes)]}


## Apply a new value to key k of a track, by the type's own setter — the shapes follow the engine signatures, same as insert.
static func _set_key_value(anim: Animation, t: int, k: int, type: int, raw: Variant, changes: PackedStringArray) -> Dictionary:
	var old := key_value_string(anim, t, k)
	match type:
		Animation.TYPE_VALUE:
			anim.track_set_key_value(t, k, parse_value(raw))
		Animation.TYPE_METHOD:
			var call := _as_method_call(raw)
			if call.has("error"):
				return call
			anim.track_set_key_value(t, k, call["value"])
		Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D:
			var v3 := _as_vector3(raw, "value")
			if v3.has("error"):
				return v3
			anim.track_set_key_value(t, k, v3["value"])
		Animation.TYPE_ROTATION_3D:
			var q := _as_quaternion(raw, "value")
			if q.has("error"):
				return q
			anim.track_set_key_value(t, k, q["value"])
		Animation.TYPE_BLEND_SHAPE, Animation.TYPE_BEZIER:
			var f := _as_float(raw, "value")
			if f.has("error"):
				return f
			if type == Animation.TYPE_BEZIER:
				anim.bezier_track_set_key_value(t, k, float(f["value"]))
			else:
				anim.track_set_key_value(t, k, float(f["value"]))
		Animation.TYPE_AUDIO:
			return {"error": "Error: an audio key has no single \"value\" — its fields are \"stream\", \"start_offset\", \"end_offset\"."}
		Animation.TYPE_ANIMATION:
			if not raw is String or String(raw) == "":
				return {"error": "Error: an animation-track key's \"value\" is the clip's animation name string, got %s." % value_string(raw)}
			anim.animation_track_set_key_animation(t, k, String(raw))
	changes.append("value %s → %s" % [old, key_value_string(anim, t, k)])
	return {}


## Which track types carry a per-key transition — the serialized transitions array/slots exist for value, 3D, blend-shape, and method tracks only.
static func _transition_gate(type: int) -> String:
	if type in [Animation.TYPE_BEZIER, Animation.TYPE_AUDIO, Animation.TYPE_ANIMATION]:
		return "Error: %s tracks store no per-key transition." % track_type_name(type)
	return ""


## ==== Text splicing — the minimal-diff write ResourceSaver cannot do for a shared file. ====


## Serialize one animation through the engine's own encoder — a temp ResourceSaver .tres whose [resource] body is byte-identical to the sub_resource body the engine writes in a scene.
static func encode_animation(anim: Animation) -> Dictionary:
	DirAccess.make_dir_recursive_absolute("user://gdllm")
	var tmp := "user://gdllm/anim_encode_tmp.tres"
	var err := ResourceSaver.save(anim, tmp)
	if err != OK:
		return {"error": "Error: the engine could not serialize the edited animation (ResourceSaver: %s). Nothing was written." % error_string(err)}
	var text := FileAccess.get_file_as_string(tmp)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	return harvest(text)


## Split a temp .tres into its [resource] body and its ext_resource table. A [sub_resource] in the temp save means a key value holds a resource EMBEDDED in the animation, which a regenerated block cannot carry — refused with the fact stated.
static func harvest(tres_text: String) -> Dictionary:
	if tres_text.contains("[sub_resource"):
		return {"error": "Error: a key value in this animation holds a resource embedded in the file (it serializes as a sub_resource), which this tool cannot re-serialize into the target file. Nothing was written."}
	var ext: Array = []
	var ext_re := RegEx.create_from_string("^\\[ext_resource .*?path=\"([^\"]*)\".*?id=\"([^\"]*)\"\\]")
	for line in tres_text.split("\n"):
		var m := ext_re.search(line)
		if m != null:
			ext.append({"line": line, "path": m.get_string(1), "id": m.get_string(2)})
	var marker := tres_text.find("[resource]\n")
	if marker < 0:
		return {"error": "Error: the engine encoder produced no [resource] block — this is a tool defect; nothing was written. Report it to the user."}
	var lines := tres_text.substr(marker + "[resource]\n".length()).split("\n")
	while lines.size() > 0 and lines[lines.size() - 1].strip_edges() == "":
		lines.remove_at(lines.size() - 1)
	return {"lines": lines, "ext": ext}


## Map a harvested body's ExtResource references onto the target file's own ext_resource table — reusing declarations whose path already exists, appending the ones it lacks — and return the updated file text plus the rewritten body.
static func remap_ext(text: String, ext: Array, body: PackedStringArray) -> Dictionary:
	if ext.is_empty():
		return {"text": text, "body": body}
	var lines := text.split("\n")
	var ext_re := RegEx.create_from_string("^\\[ext_resource .*?path=\"([^\"]*)\".*?id=\"([^\"]*)\"\\]")
	var by_path := {}
	var last_ext := -1
	for i in lines.size():
		var m := ext_re.search(lines[i])
		if m != null:
			by_path[m.get_string(1)] = m.get_string(2)
			last_ext = i
	var map := {}
	var new_lines := PackedStringArray()
	for entry: Dictionary in ext:
		var path := String(entry["path"])
		if by_path.has(path):
			map[String(entry["id"])] = String(by_path[path])
			continue
		var new_id := unique_id(text + "\n".join(new_lines), str(by_path.size() + new_lines.size() + 1))
		map[String(entry["id"])] = new_id
		new_lines.append(String(entry["line"]).replace("id=\"%s\"" % entry["id"], "id=\"%s\"" % new_id))
	var out_body := PackedStringArray()
	for line in body:
		var rewritten := line
		for tmp_id in map:
			rewritten = rewritten.replace("ExtResource(\"%s\")" % tmp_id, "ExtResource(\"%s\")" % map[tmp_id])
		out_body.append(rewritten)
	if new_lines.is_empty():
		return {"text": text, "body": out_body}
	var insert_at := last_ext + 1
	if last_ext < 0:
		# No ext table yet: the canonical spot is after the header line and its blank line, with a blank line closing the new table.
		insert_at = mini(2, lines.size())
		new_lines.append("")
	var out := PackedStringArray()
	for i in insert_at:
		out.append(lines[i])
	out.append_array(new_lines)
	for i in range(insert_at, lines.size()):
		out.append(lines[i])
	return {"text": "\n".join(out), "body": out_body}


## Replace one block's body in resource-file text, touching nothing else — block_id names a [sub_resource id="…"], "" names the [resource] block of a standalone .tres.
static func splice_block(text: String, block_id: String, body: PackedStringArray) -> Dictionary:
	var lines := text.split("\n")
	var wanted := "[resource]" if block_id == "" else "id=\"%s\"]" % block_id
	var block_start := -1
	var block_end := lines.size()
	for i in lines.size():
		if _block_header_re().search(lines[i]) == null:
			continue
		if block_start >= 0:
			block_end = i
			break
		if block_id == "" and lines[i] == wanted:
			block_start = i
		elif block_id != "" and lines[i].begins_with("[sub_resource ") and lines[i].ends_with(wanted):
			block_start = i
	if block_start < 0:
		return {"error": "Error: no block with id \"%s\" was found in the file text — the file may have changed since it was read." % block_id}
	var trailing := 0
	for i in range(block_end - 1, block_start, -1):
		if lines[i].strip_edges() != "":
			break
		trailing += 1
	var out := PackedStringArray()
	for i in range(0, block_start + 1):
		out.append(lines[i])
	out.append_array(body)
	for _i in trailing:
		out.append("")
	for i in range(block_end, lines.size()):
		out.append(lines[i])
	return {"text": "\n".join(out)}


## ==== Library splices (add_animation / remove_animation) — the _data dict and its sub_resource blocks. ====


## The `&"name": SubResource("id")` (or ExtResource) entries of one library block's _data dict, in file order.
static func lib_data_entries(lines: PackedStringArray, start: int, end: int) -> Array:
	var entry_re := RegEx.create_from_string("^&\"(.*)\": (SubResource|ExtResource)\\(\"([^\"]*)\"\\),?$")
	var entries: Array = []
	for i in range(start + 1, end):
		var m := entry_re.search(lines[i])
		if m != null:
			entries.append({"name": m.get_string(1), "kind": m.get_string(2), "id": m.get_string(3)})
	return entries


## Insert a new animation into a library block: a fresh [sub_resource type="Animation"] block spliced in _data's sorted position, and the _data entry itself — the engine sorts _data alphabetically on save (probed), so the insert matches what it would write.
static func splice_add_animation(text: String, lib_block_id: String, name: String, body: PackedStringArray) -> Dictionary:
	var lines := text.split("\n")
	var bounds := _find_block(lines, lib_block_id)
	if bounds.has("error"):
		return bounds
	var entries := lib_data_entries(lines, int(bounds["start"]), int(bounds["end"]))
	var new_id := unique_id(text, "Animation")
	var insert_pos := entries.size()
	for i in entries.size():
		if String(entries[i]["name"]) > name:
			insert_pos = i
			break
	entries.insert(insert_pos, {"name": name, "kind": "SubResource", "id": new_id})
	var rebuilt := _rebuild_data(lines, int(bounds["start"]), int(bounds["end"]), entries)
	if rebuilt.has("error"):
		return rebuilt
	lines = rebuilt["lines"]
	# The new block goes where the engine would put it: before the next entry's own block, or before the library block when the new name sorts last.
	var successor_header := ""
	for i in range(insert_pos + 1, entries.size()):
		if String(entries[i]["kind"]) == "SubResource":
			successor_header = "id=\"%s\"]" % entries[i]["id"]
			break
	var block_lines := PackedStringArray(["[sub_resource type=\"Animation\" id=\"%s\"]" % new_id])
	block_lines.append_array(body)
	block_lines.append("")
	var at := -1
	for i in lines.size():
		if successor_header != "" and lines[i].begins_with("[sub_resource ") and lines[i].ends_with(successor_header):
			at = i
			break
		if successor_header == "" and _is_block_line(lines[i], lib_block_id):
			at = i
			break
	if at < 0:
		return {"error": "Error: the library block for the new animation was not found after the _data rewrite — this is a tool defect; nothing was written. Report it to the user."}
	var out := PackedStringArray()
	for i in at:
		out.append(lines[i])
	out.append_array(block_lines)
	for i in range(at, lines.size()):
		out.append(lines[i])
	return {"text": "\n".join(out), "id": new_id}


## Remove one animation from a library block: its _data entry always, and its sub_resource block when nothing else in the file still references it.
static func splice_remove_animation(text: String, lib_block_id: String, name: String) -> Dictionary:
	var lines := text.split("\n")
	var bounds := _find_block(lines, lib_block_id)
	if bounds.has("error"):
		return bounds
	var entries := lib_data_entries(lines, int(bounds["start"]), int(bounds["end"]))
	var removed := {}
	var kept: Array = []
	for entry: Dictionary in entries:
		if String(entry["name"]) == name and removed.is_empty():
			removed = entry
		else:
			kept.append(entry)
	if removed.is_empty():
		return {"error": "Error: the _data dict of this library block has no entry \"%s\" — the file may have changed since it was read." % name}
	var rebuilt := _rebuild_data(lines, int(bounds["start"]), int(bounds["end"]), kept)
	if rebuilt.has("error"):
		return rebuilt
	lines = rebuilt["lines"]
	var note := ""
	var ref := "%s(\"%s\")" % [removed["kind"], removed["id"]]
	if String(removed["kind"]) == "ExtResource":
		note = "the animation's data lives in its own file, which still exists on disk"
		lines = _drop_unreferenced_ext(lines, String(removed["id"]))
	elif not "\n".join(lines).contains(ref):
		var span := _sub_resource_span(lines, String(removed["id"]))
		if span.x >= 0:
			var out := PackedStringArray()
			for i in lines.size():
				if i < span.x or i >= span.y:
					out.append(lines[i])
			lines = out
	else:
		note = "its sub_resource block stays — something else in the file still references it"
	return {"text": "\n".join(lines), "note": note}


## ==== Shared rendering and small helpers ====


static func track_type_name(type: int) -> String:
	return TRACK_TYPE_NAMES[type] if type >= 0 and type < TRACK_TYPE_NAMES.size() else "type %d" % type


## One key's value rendered by its track type's own getter — resources point at their file, never dump contents.
static func key_value_string(anim: Animation, track: int, key: int) -> String:
	match anim.track_get_type(track):
		Animation.TYPE_METHOD:
			var v: Dictionary = anim.track_get_key_value(track, key)
			var args := PackedStringArray()
			for arg in (v.get("args", []) as Array):
				args.append(value_string(arg))
			return "%s(%s)" % [v.get("method", "?"), ", ".join(args)]
		Animation.TYPE_BEZIER:
			return "%s (in %s, out %s)" % [String.num(anim.bezier_track_get_key_value(track, key), 4), var_to_str(anim.bezier_track_get_key_in_handle(track, key)), var_to_str(anim.bezier_track_get_key_out_handle(track, key))]
		Animation.TYPE_AUDIO:
			var parts := PackedStringArray([value_string(anim.audio_track_get_key_stream(track, key))])
			if anim.audio_track_get_key_start_offset(track, key) != 0.0:
				parts.append("start %s" % time_str(anim.audio_track_get_key_start_offset(track, key)))
			if anim.audio_track_get_key_end_offset(track, key) != 0.0:
				parts.append("end %s" % time_str(anim.audio_track_get_key_end_offset(track, key)))
			return " ".join(parts)
		Animation.TYPE_ANIMATION:
			return "\"%s\"" % anim.animation_track_get_key_animation(track, key)
	return value_string(anim.track_get_key_value(track, key))


## A value rendered for a result line: resources point at their file, anything long is clipped.
static func value_string(value: Variant) -> String:
	if value is Object:
		var res := value as Resource
		if res != null and res.resource_path != "" and not res.resource_path.contains("::"):
			return "<%s %s>" % [res.get_class(), res.resource_path]
		return "<%s>" % (value as Object).get_class()
	var rendered := var_to_str(value).replace("\n", " ")
	if rendered.length() > MAX_VALUE_CHARS:
		rendered = rendered.substr(0, MAX_VALUE_CHARS) + "… (%d chars total)" % rendered.length()
	return rendered


## Seconds rendered at millisecond-ish precision — stored times are float32, and 0.36500000953674 must read as 0.365; whole numbers drop the ".0".
static func time_str(t: float) -> String:
	return num_str(t)


## A float rendered for display: at most 4 decimals, whole numbers drop the ".0".
static func num_str(f: float) -> String:
	var s := String.num(f, 4)
	return s.trim_suffix(".0") if s.ends_with(".0") else s


static func anim_header(anim: Animation) -> String:
	var loop := LOOP_NAMES[anim.loop_mode] if anim.loop_mode < LOOP_NAMES.size() else "mode %d" % anim.loop_mode
	var keys := 0
	for i in anim.get_track_count():
		keys += anim.track_get_key_count(i)
	var head := "length %ss, loop %s, %d track(s), %d key(s)" % [time_str(anim.length), loop, anim.get_track_count(), keys]
	# The engine default step comes from the engine, not a guess — it moved between versions.
	if not is_equal_approx(anim.step, Animation.new().step):
		head += ", step %ss" % time_str(anim.step)
	return head


static func track_list(anim: Animation) -> String:
	var parts := PackedStringArray()
	for i in mini(anim.get_track_count(), MAX_TRACKS_LISTED):
		parts.append("%d: %s \"%s\"" % [i, track_type_name(anim.track_get_type(i)), anim.track_get_path(i)])
	if anim.get_track_count() > MAX_TRACKS_LISTED:
		parts.append("… %d more" % (anim.get_track_count() - MAX_TRACKS_LISTED))
	return "The tracks are — %s." % "; ".join(parts)


static func key_time_list(anim: Animation, track: int) -> String:
	var parts := PackedStringArray()
	for k in mini(anim.track_get_key_count(track), MAX_KEYS_LISTED):
		parts.append(time_str(anim.track_get_key_time(track, k)))
	if anim.track_get_key_count(track) > MAX_KEYS_LISTED:
		parts.append("… %d more" % (anim.track_get_key_count(track) - MAX_KEYS_LISTED))
	return ", ".join(parts) if not parts.is_empty() else "(none)"


## Generate an id unique within `text`, engine-style: prefix + "_" + 5 random chars.
static func unique_id(text: String, prefix: String) -> String:
	while true:
		var candidate := "%s_%s" % [prefix, Resource.generate_scene_unique_id()]
		if not text.contains("\"%s\"" % candidate):
			return candidate
	return ""


static func _block_header_re() -> RegEx:
	return RegEx.create_from_string("^\\[(gd_scene|gd_resource|ext_resource|sub_resource|resource|node|connection|editable)[ \\]]")


static func _is_block_line(line: String, block_id: String) -> bool:
	if block_id == "":
		return line == "[resource]"
	return line.begins_with("[sub_resource ") and line.ends_with("id=\"%s\"]" % block_id)


## Locate one block's bounds: start is its header line, end is the next header line (or EOF).
static func _find_block(lines: PackedStringArray, block_id: String) -> Dictionary:
	var start := -1
	var end := lines.size()
	for i in lines.size():
		if _block_header_re().search(lines[i]) == null:
			continue
		if start >= 0:
			end = i
			break
		if _is_block_line(lines[i], block_id):
			start = i
	if start < 0:
		return {"error": "Error: no block with id \"%s\" was found in the file text — the file may have changed since it was read." % block_id}
	return {"start": start, "end": end}


## Rewrite one library block's _data dict from an entry list, in the engine's own layout — or remove it entirely when no entries remain (the engine elides an empty dict).
static func _rebuild_data(lines: PackedStringArray, start: int, end: int, entries: Array) -> Dictionary:
	var data_lines := PackedStringArray()
	if not entries.is_empty():
		data_lines.append("_data = {")
		for i in entries.size():
			var entry: Dictionary = entries[i]
			var comma := "," if i < entries.size() - 1 else ""
			data_lines.append("&\"%s\": %s(\"%s\")%s" % [entry["name"], entry["kind"], entry["id"], comma])
		data_lines.append("}")
	var span_start := -1
	var span_end := -1
	for i in range(start + 1, end):
		if lines[i].begins_with("_data = {"):
			span_start = i
			for j in range(i, end):
				if lines[j] == "}" or lines[j].ends_with("}"):
					span_end = j + 1
					break
			break
	var out := PackedStringArray()
	if span_start < 0:
		# No _data yet (an empty library elides the default): the dict opens the block's properties.
		for i in range(0, start + 1):
			out.append(lines[i])
		out.append_array(data_lines)
		for i in range(start + 1, lines.size()):
			out.append(lines[i])
		return {"lines": out}
	if span_end < 0:
		return {"error": "Error: the _data dict of this library block never closes — the file text looks malformed; nothing was written."}
	for i in range(0, span_start):
		out.append(lines[i])
	out.append_array(data_lines)
	for i in range(span_end, lines.size()):
		out.append(lines[i])
	return {"lines": out}


## The [start, end) line span of one sub_resource block, trailing blank lines included; (-1, -1) when absent.
static func _sub_resource_span(lines: PackedStringArray, id: String) -> Vector2i:
	var start := -1
	for i in lines.size():
		if start < 0:
			if lines[i].begins_with("[sub_resource ") and lines[i].ends_with("id=\"%s\"]" % id):
				start = i
			continue
		if _block_header_re().search(lines[i]) != null:
			return Vector2i(start, i)
	return Vector2i(start, lines.size()) if start >= 0 else Vector2i(-1, -1)


## Drop an ext_resource declaration once nothing references it anymore.
static func _drop_unreferenced_ext(lines: PackedStringArray, id: String) -> PackedStringArray:
	if "\n".join(lines).contains("ExtResource(\"%s\")" % id):
		return lines
	var out := PackedStringArray()
	for line in lines:
		if line.begins_with("[ext_resource ") and line.ends_with("id=\"%s\"]" % id):
			continue
		out.append(line)
	return out


static func _blank_player(path: String) -> Dictionary:
	return {"path": path, "script": "", "autoplay": "", "root_node": "..", "libraries": []}


## SceneState reports "./Pic"; the bare tree-relative form is what results display and models pass back.
static func _state_path(state: SceneState, i: int) -> String:
	var path := String(state.get_node_path(i))
	return path if path == "." else path.trim_prefix("./")


static func _collect_nodes(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_collect_nodes(child, out)


## The factual check an add_track result carries: whether the new track's node exists in the scene as saved. Stated, never enforced — the engine itself accepts any path — and withheld entirely when instanced sub-scenes make the answer unknowable.
static func track_target_note(track_path: String, player: Dictionary, scan: Dictionary) -> String:
	if player.is_empty() or scan.is_empty() or bool(scan.get("has_instances", false)):
		return ""
	var root_node := String(player.get("root_node", ".."))
	var root := _join_node_path(String(player["path"]), root_node)
	if root == "":
		return ""
	var node_part := track_path.split(":")[0]
	var target := _join_node_path(root, node_part)
	if target == "":
		return "track path \"%s\" resolves outside the scene as saved (the player's root_node is \"%s\")." % [track_path, root_node]
	if (scan.get("node_paths", {}) as Dictionary).has(target):
		return ""
	return "the scene as saved has no node at \"%s\" — the new track's path \"%s\" resolved against the player's root_node \"%s\"." % [target, track_path, root_node]


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


static func _script_path(node: Node) -> String:
	var script: Variant = node.get_script()
	return (script as Script).resource_path if script is Script else ""


static func _player_name_list(players: Array) -> String:
	var names := PackedStringArray()
	for record: Dictionary in players:
		names.append("\"%s\"" % String(record["path"]))
	return ", ".join(names)


static func _players_scope(players: Array) -> String:
	if players.is_empty():
		return "this scene has no AnimationPlayer nodes, so"
	if players.size() == 1:
		return "AnimationPlayer \"%s\" holds no animations, so" % String((players[0] as Dictionary)["path"])
	return "the %d AnimationPlayer node(s) hold no animations, so" % players.size()


## Animation keys listed for an error or overview, with the owning player named only when several exist.
static func _entry_key_list(entries: Array, with_player: bool) -> String:
	var names := PackedStringArray()
	for entry: Dictionary in entries.slice(0, MAX_ANIMATIONS_LISTED):
		var name := "\"%s\"" % String(entry["key"])
		if with_player:
			name += " (on %s)" % String((entry["player"] as Dictionary)["path"])
		names.append(name)
	if entries.size() > MAX_ANIMATIONS_LISTED:
		names.append("… %d more" % (entries.size() - MAX_ANIMATIONS_LISTED))
	return ", ".join(names)


## Per-track blocks for one zoomed animation: a header line, then its keys (windowed, capped).
static func _track_lines(anim: Animation, window: Vector2, has_window: bool) -> Array:
	var lines: Array = []
	if anim.get_track_count() == 0:
		lines.append("No tracks.")
		return lines
	for i in mini(anim.get_track_count(), MAX_TRACKS_LISTED):
		var type := anim.track_get_type(i)
		var head := "track %d — %s \"%s\" — %d key(s)" % [i, track_type_name(type), anim.track_get_path(i), anim.track_get_key_count(i)]
		if type != Animation.TYPE_BEZIER and type != Animation.TYPE_AUDIO and type != Animation.TYPE_ANIMATION:
			head += ", %s" % (INTERP_NAMES[anim.track_get_interpolation_type(i)] if anim.track_get_interpolation_type(i) < INTERP_NAMES.size() else "interp %d" % anim.track_get_interpolation_type(i))
		if type == Animation.TYPE_VALUE:
			var mode := anim.value_track_get_update_mode(i)
			head += ", update %s" % (UPDATE_NAMES[mode] if mode < UPDATE_NAMES.size() else "mode %d" % mode)
		if not anim.track_is_enabled(i):
			head += " [disabled]"
		if anim.track_is_imported(i):
			head += " [imported]"
		lines.append(head)
		lines.append_array(_key_lines(anim, i, window, has_window))
	if anim.get_track_count() > MAX_TRACKS_LISTED:
		lines.append("… %d more track(s) — pass \"window\" to narrow, or read specific tracks by re-calling." % (anim.get_track_count() - MAX_TRACKS_LISTED))
	return lines


## One track's key listing: index, time, value, and any non-default transition — the index is what set_key/remove_key take.
static func _key_lines(anim: Animation, track: int, window: Vector2, has_window: bool) -> Array:
	var lines: Array = []
	var shown := 0
	var skipped := 0
	for k in anim.track_get_key_count(track):
		var t := anim.track_get_key_time(track, k)
		if has_window and (t < window.x or t > window.y):
			skipped += 1
			continue
		if shown >= MAX_KEYS_LISTED:
			skipped += 1
			continue
		shown += 1
		var line := "  [%d] %ss: %s" % [k, time_str(t), key_value_string(anim, track, k)]
		if not anim.track_get_type(track) in [Animation.TYPE_BEZIER, Animation.TYPE_AUDIO, Animation.TYPE_ANIMATION]:
			var tr := anim.track_get_key_transition(track, k)
			if not is_equal_approx(tr, 1.0):
				line += " (transition %s)" % num_str(tr)
		lines.append(line)
	if skipped > 0:
		var lever := "narrow \"window\"" if has_window else "pass \"window\" ([start_sec, end_sec])"
		lines.append("  … %d key(s) not shown — %s to see them." % [skipped, lever])
	return lines


## The all-players overview: per player, each library's animations with their key names, autoplay, and the counted-but-not-decoded sprite nodes.
static func _compose_overview(origin: String, scan: Dictionary, players: Array, narrowed: bool) -> String:
	var lines: Array = [origin]
	var head := "%d AnimationPlayer node(s)." % players.size()
	if not narrowed and int(scan["sprite_count"]) > 0:
		head += " %d AnimatedSprite2D/3D node(s) also animate here via SpriteFrames, which serialize as plain text — read_file shows them." % int(scan["sprite_count"])
	if bool(scan["has_instances"]):
		head += " Instanced sub-scenes are not descended into — call describe_animation on the instanced .tscn to see inside one."
	lines.append(head)
	for player: Dictionary in players:
		lines.append("")
		var pline := "\"%s\"" % player["path"]
		if String(player["autoplay"]) != "":
			pline += " — autoplay \"%s\"" % player["autoplay"]
		if String(player["script"]) != "":
			pline += " [script %s]" % player["script"]
		var libs: Array = player["libraries"]
		pline += " — %d librar%s" % [libs.size(), "y" if libs.size() == 1 else "ies"]
		lines.append(pline)
		for lib_entry: Dictionary in libs:
			var lib := lib_entry["library"] as AnimationLibrary
			if lib == null:
				lines.append("  library \"%s\": (not loadable)" % lib_entry["name"])
				continue
			var lib_name := String(lib_entry["name"])
			var lib_label := "default library" if lib_name == "" else "library \"%s\"" % lib_name
			var storage := ""
			if lib.resource_path != "" and not lib.resource_path.contains("::"):
				storage = " (stored in %s)" % lib.resource_path
			lines.append("  %s%s:" % [lib_label, storage])
			lines.append_array(_library_lines("    ", lib))
	if not players.is_empty():
		lines.append("")
		lines.append("Pass \"animation\" (a name above) for one animation's tracks and keys.")
	return "\n".join(PackedStringArray(lines))


static func _library_lines(indent: String, lib: AnimationLibrary) -> Array:
	var lines: Array = []
	var names := lib.get_animation_list()
	for i in mini(names.size(), MAX_ANIMATIONS_LISTED):
		var anim := lib.get_animation(names[i])
		lines.append("%s\"%s\" — %s" % [indent, names[i], anim_header(anim)])
	if names.size() > MAX_ANIMATIONS_LISTED:
		lines.append("%s… %d more" % [indent, names.size() - MAX_ANIMATIONS_LISTED])
	if names.is_empty():
		lines.append("%s(no animations)" % indent)
	return lines


## ==== Value shape converters — each follows the engine signature of the op that takes it, so nothing is inferred. ====


static func _as_float(raw: Variant, label: String) -> Dictionary:
	var v := parse_value(raw)
	if v is int or v is float:
		return {"value": float(v)}
	return {"error": "Error: \"%s\" must be a number, got %s." % [label, value_string(raw)]}


static func _as_int(raw: Variant, label: String) -> Dictionary:
	if raw is int or raw is float:
		return {"value": int(raw)}
	return {"error": "Error: \"%s\" must be an integer, got %s." % [label, value_string(raw)]}


static func _as_vector2(raw: Variant, label: String) -> Dictionary:
	var v := parse_value(raw)
	if v is Vector2:
		return {"value": v}
	if _num_array(v, 2):
		return {"value": Vector2(_num(v, 0), _num(v, 1))}
	return {"error": "Error: \"%s\" must be a Vector2 — [x, y] or \"Vector2(x, y)\" — got %s." % [label, value_string(raw)]}


static func _as_vector3(raw: Variant, label: String) -> Dictionary:
	var v := parse_value(raw)
	if v is Vector3:
		return {"value": v}
	if _num_array(v, 3):
		return {"value": Vector3(_num(v, 0), _num(v, 1), _num(v, 2))}
	return {"error": "Error: \"%s\" must be a Vector3 — [x, y, z] or \"Vector3(x, y, z)\" — got %s." % [label, value_string(raw)]}


static func _as_quaternion(raw: Variant, label: String) -> Dictionary:
	var v := parse_value(raw)
	if v is Quaternion:
		return {"value": v}
	if _num_array(v, 4):
		return {"value": Quaternion(_num(v, 0), _num(v, 1), _num(v, 2), _num(v, 3))}
	return {"error": "Error: \"%s\" must be a Quaternion — [x, y, z, w] components or \"Quaternion(x, y, z, w)\" — got %s." % [label, value_string(raw)]}


## A method-track key value: {"method": name, "args": [...]}, each arg through the literal parser.
static func _as_method_call(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not (raw as Dictionary).has("method") or not (raw as Dictionary)["method"] is String:
		return {"error": "Error: a method-track key's \"value\" is {\"method\": \"name\", \"args\": [...]}, got %s." % value_string(raw)}
	var args_raw: Variant = (raw as Dictionary).get("args", [])
	if not args_raw is Array:
		return {"error": "Error: \"args\" must be an array, got %s." % value_string(args_raw)}
	var args: Array = []
	for arg in (args_raw as Array):
		args.append(parse_value(arg))
	return {"value": {"method": StringName(String((raw as Dictionary)["method"])), "args": args}}


## An audio key's stream, loaded from its res:// path — the load failure or the wrong class is stated as-is.
static func _as_stream(raw: Variant) -> Dictionary:
	if not raw is String or String(raw) == "":
		return {"error": "Error: \"stream\" must be the res:// path of an audio stream resource, got %s." % value_string(raw)}
	var res: Resource = ResourceLoader.load(String(raw), "", ResourceLoader.CACHE_MODE_REUSE)
	if res == null:
		return {"error": "Error: %s could not be loaded as a resource." % raw}
	if not res is AudioStream:
		return {"error": "Error: %s loaded as a %s, not an AudioStream." % [raw, res.get_class()]}
	return {"value": res}


static func _num_array(raw: Variant, size: int) -> bool:
	if not raw is Array or (raw as Array).size() != size:
		return false
	for item in (raw as Array):
		if not (item is int or item is float):
			return false
	return true


static func _num(raw: Variant, i: int) -> float:
	return float((raw as Array)[i])
