extends SceneTree
## Headless engine-truth check for project files: loads each path given after "--" and exits nonzero on failure, so edit_file/write_file/check_script can validate a change with the engine's own loaders. A .gd gets the full parse+analyze+compile pipeline; a .tscn/.tres a real load; a .gdshader the shading-language compile the load alone never performs (see _compile_shader). The engine prints its own parse/dependency errors; the marker line below only flags a load that failed without one. A .tscn that loads is additionally walked for stored properties and node types the engine doesn't know (SCENE_PROP_WARN lines), because those load fine and are then DROPPED silently at instantiation.
## The check waits one frame: autoloads register as script globals between _init and the first process_frame (even quit() in _init doesn't skip that), and only then does a script referencing an autoload — most gameplay code — compile. Checking in _init failed every such script with "Compile Error: Identifier not found", and --check-only, which exits before autoload setup, could never see past it.
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/load_check.gd -- res://x.tscn


func _init() -> void:
	for path in OS.get_cmdline_user_args():
		_register_header_uids(path)
	process_frame.connect(_check, CONNECT_ONE_SHOT)


func _check() -> void:
	var failures := 0
	for path in OS.get_cmdline_user_args():
		# CACHE_MODE_REPLACE forces a real parse even if something in this process (the autoload chain) already touched the file.
		var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if res == null:
			failures += 1
			print("LOAD_CHECK_FAILED: %s" % path)
		elif res is PackedScene:
			_scene_property_warnings(res)
		elif res is Shader:
			_compile_shader(path)
	# Completion sentinel for the parent: a run whose output lacks this line died before finishing, and its (possibly empty) error list must not be read as a verdict.
	print("GDLLM_CHECK_DONE")
	quit(1 if failures > 0 else 0)


## Compile the shader at `path` inside a bracket, so the parent can tell this file's errors from those of a shader something else in the project pulled in.
## Loading a .gdshader proves nothing on its own: the loader hands its text to a Shader whatever it says, and the engine defers the shading-language parse until something asks the shader for its data — so the uniform query below IS the compile, and without it every broken shader checks out clean (probe-measured: a load alone printed nothing for a shader missing a semicolon).
## The load is CACHE_MODE_IGNORE rather than the caller's cached instance, and that is the whole correctness of this check: a shader the PROJECT uses is already loaded and compiled by the time autoload setup finishes, its error printed then — outside this bracket — and a re-query of that same instance emits nothing at all, so the bracket came back empty and the file was reported CLEAN while the engine's own error log said otherwise (wild-measured on a shader whose material a boot-loaded scene referenced). A cache-ignoring load builds a shader nothing has compiled yet, so the parse always happens here, where it can be attributed.
## The markers ride printerr because the engine's shader errors go to stderr and the parent drains stdout and stderr separately: only same-stream ordering survives that, so a print() bracket could land around the wrong text.
func _compile_shader(path: String) -> void:
	printerr("GDLLM_SHADER_BEGIN: %s" % path)
	var fresh: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh is Shader:
		var _uniforms := (fresh as Shader).get_shader_uniform_list()
	printerr("GDLLM_SHADER_END: %s" % path)


## Walk a loaded PackedScene's saved nodes and print one SCENE_PROP_WARN line per stored property missing from its node's type — checked against a bare instance's property list plus the attached script's declared variables — and per node type ClassDB doesn't know. This channel is the only place a typo in hand-edited scene text ever surfaces; the parent diffs the lines pre/post so only what an edit introduced is reported. Names containing "/" are skipped (metadata/…, parameters/…): most belong to dynamic registries a bare instance can't enumerate, and accusing a valid save would be worse than missing a typo'd override.
func _scene_property_warnings(scene: PackedScene) -> void:
	var state := scene.get_state()
	var cache := {}
	for i in state.get_node_count():
		var type := String(state.get_node_type(i))
		# An instanced-scene or override entry carries no type; its properties belong to the instanced file, which gets its own check when edited.
		if type == "":
			continue
		var shown := String(state.get_node_path(i)).trim_prefix("./")
		if not ClassDB.class_exists(type):
			print("SCENE_PROP_WARN: node \"%s\" has unknown type \"%s\" — no such class exists in this engine build." % [shown, type])
			continue
		# An abstract class yields no bare instance to enumerate, so its properties go unchecked rather than mis-accused.
		if not ClassDB.can_instantiate(type):
			continue
		var script: Variant = null
		var script_broken := false
		for j in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, j)) != "script":
				continue
			var value: Variant = state.get_node_property_value(i, j)
			if value is Script:
				script = value
			elif value != null:
				script_broken = true
		# A script that failed to load would false-flag every variable it declares, so the whole node is skipped.
		if script_broken:
			continue
		var valid: Dictionary = _valid_property_names(type, script, cache)
		var label := type if script == null else "%s + %s" % [type, (script as Script).resource_path.get_file()]
		for j in state.get_node_property_count(i):
			var pname := String(state.get_node_property_name(i, j))
			if pname == "script" or pname.contains("/") or valid.has(pname):
				continue
			print("SCENE_PROP_WARN: node \"%s\": \"%s\" is not a property of %s%s." % [shown, pname, label, _near_miss_clause(pname, valid)])


## Every property name a bare `type` instance reports plus the declared variables of `script` and its base chain, as a name→true set, cached per type+script pair so a scene full of one node type instantiates it once. Nothing here runs user code: the bare instance is a plain engine class and get_script_property_list reads the compiled script without instantiating it.
func _valid_property_names(type: String, script: Variant, cache: Dictionary) -> Dictionary:
	var key := type if script == null else type + "|" + (script as Script).resource_path
	if cache.has(key):
		return cache[key]
	var names := {}
	var instance: Object = ClassDB.instantiate(type)
	if instance != null:
		for p in instance.get_property_list():
			names[String(p.get("name", ""))] = true
		if not instance is RefCounted:
			instance.free()
	var walk: Variant = script
	while walk is Script:
		for p in (walk as Script).get_script_property_list():
			names[String(p.get("name", ""))] = true
		walk = (walk as Script).get_base_script()
	cache[key] = names
	return names


## " (did you mean …?)" naming up to three real properties the unknown name resembles, or "". Similarity-scored rather than the parent's contains-either rule alone, because property typos are usually transpositions ("positon") that substring containment never catches.
func _near_miss_clause(pname: String, valid: Dictionary) -> String:
	var needle := pname.to_lower()
	var scored: Array = []
	for candidate in valid:
		var lc := String(candidate).to_lower()
		var score := needle.similarity(lc)
		if lc.contains(needle) or (needle.length() >= 4 and needle.contains(lc)):
			score = maxf(score, 0.75)
		if score >= 0.7:
			scored.append({"name": String(candidate), "score": score})
	if scored.is_empty():
		return ""
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"])
	var names := PackedStringArray()
	for entry in scored.slice(0, 3):
		names.append(String(entry["name"]))
	return " (did you mean %s?)" % ", ".join(names)


## This child's uid registry comes from .godot/uid_cache.bin, which cannot yet hold a uid the parent registered for a just-written file (ResourceUID has no cache-persist API) — a coordinated preload of that uid failed here as "does not exist" while the parent's own note said KEPT. Registering the header uids of the target's sibling .tscn/.tres files — and the sidecar uids of siblings that carry one (.gd, .gdshader, .gdshaderinc), which write_file now mints on creation — in this process's memory lets those fresh references, including between two just-written files, resolve; a uid the cache already knows is left alone.
func _register_header_uids(target: String) -> void:
	var paths: Array[String] = [target]
	var dir := target.get_base_dir()
	for entry in DirAccess.get_files_at(dir):
		var sibling := dir.path_join(entry)
		if sibling != target:
			paths.append(sibling)
	for path in paths:
		var ext := path.get_extension().to_lower()
		if ext == "uid":
			var owner := path.get_basename()
			var sidecar := FileAccess.get_file_as_string(path).strip_edges()
			var sid := ResourceUID.text_to_id(sidecar) if sidecar.begins_with("uid://") else ResourceUID.INVALID_ID
			if sid != ResourceUID.INVALID_ID and not ResourceUID.has_id(sid) and FileAccess.file_exists(owner):
				ResourceUID.add_id(sid, owner)
			continue
		if ext not in ["tscn", "tres"]:
			continue
		var id := ResourceUID.text_to_id(_header_uid(path))
		if id != ResourceUID.INVALID_ID and not ResourceUID.has_id(id):
			ResourceUID.add_id(id, path)


## The uid="uid://…" declared in the file's [gd_scene]/[gd_resource] header tag, or "" — only the first line is read, keeping the sibling sweep cheap.
func _header_uid(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var header := file.get_line()
	file.close()
	var re := RegEx.new()
	re.compile("^\\[gd_(?:scene|resource)\\b[^\\]]*?\\buid=\"(uid://[^\"]+)\"")
	var found := re.search(header)
	return found.get_string(1) if found else ""
