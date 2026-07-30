@tool
class_name GDLLMImport extends RefCounted
## Engine-truth access to the project's IMPORT pipeline — the `.import` sidecar an imported asset carries, and the editor's own re-import of that asset.
## Nothing here existed before: `EditorFileSystem.reimport_files` was never called anywhere in the addon, so a change to a `.import` sat inert until the user happened to rescan, and the tools reported a write that had done nothing.
## Two measured failures shape it, both counted across the wild transcripts of a real game project.
## Reading: 131 of 131 read_file calls on a `.import` were followed by the model using the asset's `uid://` — it wanted ONE line and was handed the whole file, 136,219 characters of permanent history to deliver about 3,700 characters of signal.
## Listing: `.import` and `.uid` sidecars are 33.6% of everything list_directory ever returned (21.4% and 12.2%), a third of that tool's entire lifetime output spent on files no session ever asked about.
## Every method is static — this is a namespace, not an instance.

## The sidecar extensions folded out of a directory listing: each belongs to the file whose name it extends and carries nothing a listing is ever asked for.
const SIDECAR_EXTENSIONS := ["import", "uid"]
## Most import settings rendered before the rest collapse to a count; a texture importer alone declares ~26, and a listing of them is not what a map is for.
const MAX_LISTED_PARAMS := 40
## The value names behind the numeric import options that are ENUMS, keyed "<importer>/<option>".
## Nothing script-reachable carries these, all four candidates probed on 4.7: ClassDB reports ZERO properties for every ResourceImporter* class and none can be instantiated, the documentation cache has the importers' prose but not their value lists, and ProjectSettings holds importer_defaults only for a project that has customized them. So this is a version-pinned table read out of the engine's own PROPERTY_HINT_ENUM hint strings — the same treatment the Output panel's filter keys get — and an option ABSENT from it is passed through with its value unchecked rather than guessed at.
## It is keyed by importer as well as option because one name means different things per importer: "compress/mode" is Lossless..Basis Universal for a texture and PCM..Quite OK Audio for a WAV, so a table keyed by option alone would validate an audio file against a texture's values.
## Wild-measured, this is the failure it exists for: asked to make textures lossless, three runs out of three set compress/mode to 3 — VRAM Uncompressed — and reported "Lossless" to the user, because the number carried no meaning anywhere and nothing refused it.
const OPTION_VALUE_NAMES := {
	"texture/compress/mode": ["Lossless", "Lossy", "VRAM Compressed", "VRAM Uncompressed", "Basis Universal"],
	"texture/compress/normal_map": ["Detect", "Enable", "Disabled"],
	"texture/compress/channel_pack": ["sRGB Friendly", "Optimized"],
	"texture/compress/hdr_compression": ["Disabled", "Opaque Only", "Always"],
	"texture/roughness/mode": ["Detect", "Disabled", "Red", "Green", "Blue", "Alpha", "Gray"],
	"texture/detect_3d/compress_to": ["Disabled", "VRAM Compressed", "Basis Universal"],
	"wav/compress/mode": ["PCM (Uncompressed)", "IMA ADPCM", "Quite OK Audio"],
}


## The file a sidecar belongs to ("res://icon.svg" for "res://icon.svg.import"), or "" when `path` is not a sidecar name.
## Judged by extension alone: the owner need not exist, since an ORPHANED sidecar is exactly the case a listing must keep showing.
static func sidecar_owner(path: String) -> String:
	if not SIDECAR_EXTENSIONS.has(path.get_extension().to_lower()):
		return ""
	var owner := path.substr(0, path.length() - path.get_extension().length() - 1)
	return owner if owner.get_extension() != "" else ""


## Split a directory's file names into the ones a listing shows and the sidecars it folds away.
## A sidecar is folded only when its OWNER is listed beside it — one whose owner is absent is an orphan left by a manual delete, which is real information and stays visible.
## Sidecars that are ALL a directory holds are shown too: folding them would answer a listing of that directory with nothing at all, the dead end the addon-scoped search avoids the same way.
static func partition_listing(files: Array) -> Dictionary:
	var present := {}
	for f: String in files:
		present[f] = true
	var shown: Array[String] = []
	var folded: Array[String] = []
	for f: String in files:
		var owner := sidecar_owner(f)
		if owner != "" and present.has(owner):
			folded.append(f)
		else:
			shown.append(f)
	if shown.is_empty():
		return {"shown": folded, "folded": [] as Array[String]}
	return {"shown": shown, "folded": folded}


## The one line disclosing what partition_listing folded away, or "" when it folded nothing.
## Terse on purpose: it rides every listing of an asset directory, and the reasoning that earns it belongs in the schema, which is paid for once.
static func folded_note(folded: Array) -> String:
	if folded.is_empty():
		return ""
	# Terse on purpose, and deliberately NOT advertising the sidecars flag: the first wording named it here and the model took it in 12 of 26 wild listings, spending 2.3x the characters (11,437 against 5,068 on average) to see files it had no use for. The lever lives in the schema, which is paid for once — the same reasoning the addon-scoped search note follows.
	return "  (+%d .import/.uid sidecar file(s), one per file above, not listed)" % folded.size()


## Whether folding these sidecars away actually buys anything, given that the disclosure line replacing them is a fixed cost.
## Measured on a real project's root, where folding a SINGLE .import grew the listing from 245 to 378 characters: a saving that is a loss is not worth the indirection, and a directory of two or three files should read as itself.
## The comparison is against the note this exact set would produce, so the rule needs no tuning if the wording changes.
static func fold_saves(folded: Array) -> bool:
	if folded.is_empty():
		return false
	var removed := 0
	for f: String in folded:
		removed += f.length() + 3 # each listed line carries a two-space indent and a newline
	return removed > folded_note(folded).length()


## Whether `path` names a `.import` sidecar.
static func is_import_file(path: String) -> bool:
	return path.get_extension().to_lower() == "import"


## The `.import` path for an asset, or the path itself when it already is one.
static func import_path_for(path: String) -> String:
	return path if is_import_file(path) else path + ".import"


## The imported asset a path refers to: the owner for a `.import`, the path itself otherwise.
static func asset_path_for(path: String) -> String:
	if not is_import_file(path):
		return path
	var owner := sidecar_owner(path)
	return owner if owner != "" else path


## Everything the engine records about one asset's import, read from its `.import` sidecar.
## Returns {ok, why, asset, importer, type, uid, dest_files, params (Dictionary), param_order (Array)}; `ok` false with `why` set when there is no readable sidecar.
## `[deps] source_file` is preferred over the sidecar's own name because it is what the engine reimports by, and a hand-moved `.import` can disagree with it.
static func read_import(path: String) -> Dictionary:
	var import_file := import_path_for(path)
	var out := {"ok": false, "why": "", "import_file": import_file, "asset": asset_path_for(path), "importer": "", "type": "", "uid": "", "dest_files": [] as Array[String], "params": {}, "param_order": [] as Array[String]}
	if not FileAccess.file_exists(import_file):
		out["why"] = "there is no %s, so the engine has never imported it" % import_file
		return out
	var config := ConfigFile.new()
	var err := config.load(import_file)
	if err != OK:
		out["why"] = "%s could not be parsed (%s)" % [import_file, error_string(err)]
		return out
	out["ok"] = true
	out["importer"] = str(config.get_value("remap", "importer", ""))
	out["type"] = str(config.get_value("remap", "type", ""))
	out["uid"] = str(config.get_value("remap", "uid", ""))
	var source := str(config.get_value("deps", "source_file", ""))
	if source != "":
		out["asset"] = source
	var dest: Array[String] = []
	for d in (config.get_value("deps", "dest_files", []) as Array):
		dest.append(str(d))
	if dest.is_empty():
		var single := str(config.get_value("remap", "path", ""))
		if single != "":
			dest.append(single)
	out["dest_files"] = dest
	var params := {}
	var order: Array[String] = []
	if config.has_section("params"):
		for key in config.get_section_keys("params"):
			params[key] = config.get_value("params", key)
			order.append(key)
	out["params"] = params
	out["param_order"] = order
	return out


## The compact view read_file returns for a `.import` instead of its raw text.
## The uid leads because that is measurably what the read is for — 131 of 131 wild reads of one of these harvested it — and the settings are counted rather than listed, since the file is only ever opened for them when something is about to change one.
## `import_valid` is the editor's own verdict (see valid_state) or "" where nothing can be asked, and a broken import says so here rather than reading as an ordinary asset.
static func map_report(path: String, info: Dictionary, import_valid: String) -> String:
	if not bool(info["ok"]):
		return "%s: %s." % [path, str(info["why"])]
	# Wild-measured, the first wording of this map saved only 25% against the raw file (775 characters against 1,029) because it spelled the asset's full path THREE times and closed with a paragraph of bookkeeping prose. On a real project's paths that is most of the map, so the path is stated once and everything below refers to "it".
	var asset := str(info["asset"])
	var lines: Array[String] = ["%s — import metadata for %s:" % [str(info["import_file"]), asset]]
	if str(info["uid"]) != "":
		lines.append("uid: %s (the ASSET's uid — what preload(\"uid://...\") of it uses)" % str(info["uid"]))
	else:
		lines.append("uid: none yet — reference it by res:// path.")
	if str(info["type"]) != "":
		lines.append("imports as: %s, via the \"%s\" importer" % [str(info["type"]), str(info["importer"])])
	if import_valid == "invalid":
		lines.append("status: FAILED — the import produced no file at all, so loading it fails. read_errors/read_output carry the engine's reason; fix that, then set_import_setting to rebuild.")
	elif import_valid == "unloadable":
		# A different failure from the one above and it wants a different fix: the import RAN, so a setting is the suspect rather than the source file. Wild-measured, a run that read only the earlier wording concluded the source PNG was corrupt and told the user so.
		lines.append("status: BROKEN — the import ran but what it produced does NOT load, so anything using it gets nothing. A SETTING holding a value its importer cannot use is the usual cause, not the source file; read this with \"full\": true to see the values and set_import_setting to correct one. read_errors/read_output carry the engine's own message.")
	elif import_valid == "valid":
		# Short, but never silent: with no line at all, "checked and healthy" would read exactly like "nothing checked this", which is the case outside the editor.
		lines.append("status: imports and loads cleanly.")
	var params: Dictionary = info["params"]
	if not params.is_empty():
		lines.append("%d import settings (%s, …) — values omitted here; read with \"full\": true for them, set_import_setting to change one." % [params.size(), ", ".join(_sample_keys(info["param_order"]))])
	return "\n".join(lines)


## Up to three setting names, for the map's "e.g." — enough to show what the importer is about without listing it.
static func _sample_keys(order: Array) -> Array:
	var out: Array[String] = []
	for key: String in order:
		out.append(key)
		if out.size() == 3:
			break
	return out


## The uid clause appended to read_file's binary refusal for an imported asset, so a model reading a .png for its uid is answered instead of dead-ended.
## Measured: every wild read of a `.import` was a uid harvest, and the asset itself is the path the model has in hand.
static func binary_uid_hint(path: String) -> String:
	var info := read_import(path)
	if not bool(info["ok"]) or str(info["uid"]) == "":
		return ""
	return " It is an imported asset: its uid is %s (what a preload(\"uid://...\") of it uses), it imports as %s, and set_import_setting changes how it is imported." % [str(info["uid"]), str(info["type"])]


## The verdict on an asset's last import: "valid", "invalid" (the import step itself failed), "unloadable" (it produced a file that does not load), "unknown" (the editor has never scanned it), or "" outside the editor.
## The editor's own flag is NOT enough on its own, which is the whole reason for the second half: probe-measured on 4.7, an out-of-range `compress/mode` leaves `get_file_import_is_valid` TRUE while the imported texture fails to load, so the flag alone would hand a clean bill to an asset nothing can use.
## The two failures want different fixes and are therefore kept apart: an import that produced nothing versus one that produced something broken.
## The load is CACHE-IGNORING, and that is the whole correctness of the check rather than a detail — wild-measured against a real PNG broken by an out-of-range compress/mode, a cached load returned the PREVIOUS good copy and the map reported "imports cleanly" about an asset that provably returns null. The same trap the shader check found: a verdict read from a cache describes the generation before the one being asked about.
static func valid_state(asset: String) -> String:
	if not Engine.is_editor_hint():
		return ""
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		return ""
	var dir: EditorFileSystemDirectory = filesystem.get_filesystem_path(asset.get_base_dir() + "/")
	if dir == null:
		return "unknown"
	var idx := dir.find_file_index(asset.get_file())
	if idx < 0:
		return "unknown"
	if not dir.get_file_import_is_valid(idx):
		return "invalid"
	return "valid" if ResourceLoader.load(asset, "", ResourceLoader.CACHE_MODE_IGNORE) != null else "unloadable"


## Re-import `asset` through the editor's own EditorFileSystem and report what changed on disk.
## The call is synchronous — probe-measured at ~5 ms on 4.7, with `is_importing()` already false and the new resource already swapped in on return — so nothing here waits on a signal that has already fired.
## An asset the editor has never scanned (one just written by another tool) is registered with update_file first, which is what turns a bare source file into an importable entry; probe-verified as the pair that imports a brand-new file.
static func reimport(asset: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "why": "re-importing is the editor's own operation and this session is running headless — there is no EditorFileSystem to drive."}
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		return {"ok": false, "why": "the editor's filesystem could not be reached in this editor build. Tell the user the import tools need updating for this editor version."}
	if valid_state(asset) == "unknown":
		# A file the editor has not scanned is not reimportable at all; reimport_files would print "Can't find file" and return nothing, so the entry is created first.
		filesystem.update_file(asset)
	filesystem.reimport_files(PackedStringArray([asset]))
	return {"ok": true, "why": ""}


## The value names for one option, or [] when this option is not a known enum (see OPTION_VALUE_NAMES).
static func value_names(importer: String, option: String) -> Array:
	return OPTION_VALUE_NAMES.get("%s/%s" % [importer, option], [])


## Render a value as the engine would name it — "3 (VRAM Uncompressed)" — or plainly where nothing is known about it.
## The number alone is what let three wild runs report VRAM Uncompressed as "Lossless": a report that echoes back the figure it was handed confirms the caller's belief instead of testing it.
static func label_value(importer: String, option: String, value: Variant) -> String:
	var names := value_names(importer, option)
	var idx := int(value) if typeof(value) in [TYPE_INT, TYPE_FLOAT] else -1
	if names.is_empty() or idx < 0 or idx >= names.size():
		return str(value)
	return "%s (%s)" % [str(value), str(names[idx])]


## Resolve a requested value for one option: an enum option accepts its index or its NAME (case-insensitive), anything else passes through untouched.
## Returns {ok, value, why} — `ok` false with a refusal naming every legal value, since an out-of-range index is silently accepted by the importer and only shows up later as a wrongly-built asset.
static func resolve_value(importer: String, option: String, value: Variant) -> Dictionary:
	var names := value_names(importer, option)
	if names.is_empty():
		return {"ok": true, "value": value, "why": ""}
	if typeof(value) == TYPE_STRING:
		var wanted := str(value).strip_edges().to_lower()
		for i in names.size():
			if str(names[i]).to_lower() == wanted:
				return {"ok": true, "value": i, "why": ""}
		if not wanted.is_valid_float():
			return {"ok": false, "value": null, "why": _value_refusal(importer, option, value, names)}
	var idx := int(value) if typeof(value) in [TYPE_INT, TYPE_FLOAT, TYPE_STRING] else -1
	if idx < 0 or idx >= names.size():
		return {"ok": false, "value": null, "why": _value_refusal(importer, option, value, names)}
	return {"ok": true, "value": idx, "why": ""}


## One option's legal values written out as "0 = Lossless, 1 = Lossy, …", or "" where the option is not a known choice.
## This rides a SUCCESSFUL change as well as a refusal, which is the point: wild-measured, a run that fixed an asset correctly then told the user the modes were "0 Lossless, 1 Lossy/DXT, 2 VRAM Uncompressed, 3 Basis Universal" — three of the four wrong — because no refusal had fired that session and the result named only the single value it set, leaving the rest to memory.
static func value_legend(importer: String, option: String) -> String:
	var names := value_names(importer, option)
	if names.is_empty():
		return ""
	var listed: Array[String] = []
	for i in names.size():
		listed.append("%d = %s" % [i, str(names[i])])
	return "%s takes: %s." % [option, ", ".join(listed)]


## The value legends for every CHOICE option a `.import` actually declares — appended to a FULL read of one, where its numbers are on screen with nothing to say what they mean.
## Two wild signals a round apart say those numbers are unreadable where they live: a model answering "what compression mode is this?" read the file and then recited the value names from memory (wrong, the round before), and another sent a deliberately invalid value — "ZZZ" — purely to make the refusal hand it the legal ones. The file records bare integers, so anything reading it either already knows the mapping or invents one.
## It rides the FULL read rather than the map because the map omits values entirely, and a legend explaining numbers the reader cannot see would be cost without an answer.
## Marked as not being part of the file, since a full read is otherwise the file's own bytes and text copied out of it for an edit must not pick this up.
## `repeat` true once this importer's legend has already been spelled out in the session: the block is per-importer and byte-identical every time, and wild-measured 71% of all legend characters were the same text re-sent for the second through sixth texture read of one turn.
## The repeat is a POINTER rather than a back-reference to history, because history is prunable — it names which options are choices (the part that cannot be inferred from the file) and the by-name spelling, so a caller whose earlier legend has been compacted away still has a safe move rather than a dead end.
static func legend_block(info: Dictionary, repeat := false) -> String:
	if not bool(info["ok"]):
		return ""
	var importer := str(info["importer"])
	var lines: Array[String] = []
	var options: Array[String] = []
	for key: String in info["param_order"]:
		var legend := value_legend(importer, key)
		if legend != "":
			lines.append("  " + legend)
			options.append(key)
	if lines.is_empty():
		return ""
	if repeat:
		# Only the option NAMES survive the trim: which settings are choices cannot be read off the file, while the values were spelled out once already and can be had again by setting one by name.
		return "\n\n(read_file addition, not file content — numbered choices: %s. Values listed on this session's first \"%s\" read; set any by NAME to skip the numbers.)" % [", ".join(options), importer]
	return "\n\n(Added by read_file, NOT part of the file — what its numeric choices mean:\n%s)" % "\n".join(lines)


## The refusal for a value no legal setting of this option has, listing each one with the number that selects it.
static func _value_refusal(importer: String, option: String, value: Variant, names: Array) -> String:
	return "Error: %s is not a value the \"%s\" importer accepts for %s. %s Pass the number, or the name itself (\"%s\"), and note that these are NOT interchangeable — nothing else reports which one a number means, so a wrong number silently builds the asset the wrong way." % [str(value), importer, option, value_legend(importer, option), str(names[0])]


## The line a refusal owes a batch: the write is applied as one unit, so a call stopped by one bad setting leaves the GOOD ones in that call unwritten too.
## Wild-measured, a model not told this resent the same six-call batch twice — it had no way to know its valid setting had also been withheld, so re-sending everything looked like the safe move.
static func batch_withheld_note(settings: Dictionary, rejected: Array) -> String:
	var others: Array[String] = []
	for key: String in settings:
		if not rejected.has(key):
			others.append(key)
	if others.is_empty():
		return "\n\nNothing was written."
	return "\n\nNothing in this call was written — the settings in one call are applied together, so %s %s NOT changed either. Correct the value above and send them all again." % [", ".join(others), "was" if others.size() == 1 else "were"]


## The requested setting names this importer does not declare, in request order — the batch half of unknown_param_refusal, shared so the caller can name what was withheld alongside them.
static func unknown_keys(settings: Dictionary, info: Dictionary) -> Array:
	var params: Dictionary = info["params"]
	var unknown: Array[String] = []
	for key: String in settings:
		if not params.has(key):
			unknown.append(key)
	return unknown


## Coerce `value` to the type the option already holds, since an option's CURRENT value is the only statement of its type the engine exposes to scripts.
## A float option handed the JSON integer 1 must not become an int: the importer reads the variant as it finds it, and the mismatch surfaces later as a wrong import rather than an error here.
## A string carrying a Godot literal ("Vector2(64, 32)") is parsed the way set_project_setting parses one, which is how the non-JSON option types are reachable at all.
static func coerce_param(value: Variant, current: Variant) -> Variant:
	if typeof(current) == TYPE_NIL:
		return value
	if typeof(value) == TYPE_STRING and typeof(current) != TYPE_STRING:
		var parsed: Variant = str_to_var(str(value))
		if parsed != null and typeof(parsed) == typeof(current):
			return parsed
	# A number arriving as text is the common shape of a schema-blind call, and it must land as the option's own numeric type rather than as a string the importer will not read.
	var numeric := typeof(value) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL] or (typeof(value) == TYPE_STRING and str(value).is_valid_float())
	match typeof(current):
		TYPE_FLOAT:
			return float(value) if numeric else value
		TYPE_INT:
			return int(float(value)) if numeric else value
		TYPE_BOOL:
			return bool(value) if typeof(value) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL] else value
		TYPE_STRING:
			return str(value)
	return value


## Refuse a settings batch naming an option the importer does not declare, listing what it does declare.
## This guard is the whole honesty of the write: probe-measured on 4.7, an unrecognized key is SILENTLY DROPPED by the reimport — the engine rewrites [params] with its own option set and says nothing — so a typo'd name would be written, vanish, and report success having changed nothing.
static func unknown_param_refusal(settings: Dictionary, info: Dictionary) -> String:
	var unknown := unknown_keys(settings, info)
	if unknown.is_empty():
		return ""
	var near: Array[String] = []
	for bad: String in unknown:
		for real: String in info["param_order"]:
			var a := bad.to_lower()
			var b := real.to_lower()
			if a == b or a.contains(b) or b.contains(a) or b.get_file() == a.get_file():
				near.append("%s → %s" % [bad, real])
				break
	var lines: Array[String] = ["Error: the \"%s\" importer for %s declares no setting called %s." % [str(info["importer"]), str(info["asset"]), ", ".join(unknown)]]
	if not near.is_empty():
		lines.append("Did you mean: %s." % ", ".join(near))
	lines.append("Writing a name it does not declare would change nothing — the engine drops unrecognized settings on the next import without reporting it.")
	lines.append("Its real settings are: %s" % ", ".join(_capped_names(info["param_order"])))
	return "\n".join(lines) + batch_withheld_note(settings, unknown)


## The importer's option names for a refusal, capped so a large importer cannot flood the context with its own schema.
static func _capped_names(order: Array) -> Array:
	var out: Array[String] = []
	for key: String in order:
		out.append(key)
		if out.size() == MAX_LISTED_PARAMS:
			out.append("… and %d more (read_file the .import with \"full\": true for all of them)" % (order.size() - MAX_LISTED_PARAMS))
			break
	return out


## Write `settings` into the `.import`'s [params], leaving every other section untouched — the engine's bookkeeping (the cache path, the dependency list, the uid) is never rewritten by hand.
static func write_params(import_file: String, settings: Dictionary) -> Dictionary:
	var config := ConfigFile.new()
	var err := config.load(import_file)
	if err != OK:
		return {"ok": false, "why": "%s could not be parsed (%s)" % [import_file, error_string(err)]}
	for key: String in settings:
		config.set_value("params", key, settings[key])
	err = config.save(import_file)
	if err != OK:
		return {"ok": false, "why": "%s could not be written (%s)" % [import_file, error_string(err)]}
	return {"ok": true, "why": ""}


## Compare what was asked for against what the `.import` holds after the reimport, so a setting the engine declined is reported as declined rather than as set.
## Returns {took, dropped, unchanged} — `dropped` is the case the unknown-key guard exists to prevent, kept as a second witness because only the engine decides what survives an import.
## A value that was ALREADY what was asked for is separated out rather than counted as a change: wild-measured, 12 of 30 writes in one round set a value the file already held, and a report calling those "changed" is how a run that did nothing reads as a run that fixed something.
static func verify_params(after: Dictionary, requested: Dictionary, before: Dictionary, importer := "") -> Dictionary:
	var took: Array[String] = []
	var dropped: Array[String] = []
	var unchanged: Array[String] = []
	var params: Dictionary = after["params"]
	for key: String in requested:
		if not params.has(key):
			dropped.append(key)
		elif str(params[key]) == str(requested[key]):
			var now := label_value(importer, key, params[key])
			if before.has(key) and str(before[key]) == str(params[key]):
				unchanged.append("%s = %s" % [key, now])
			else:
				took.append("%s = %s (was %s)" % [key, now, label_value(importer, key, before[key]) if before.has(key) else "unset"])
		else:
			dropped.append("%s (it holds %s, not the %s asked for)" % [key, label_value(importer, key, params[key]), label_value(importer, key, requested[key])])
	return {"took": took, "dropped": dropped, "unchanged": unchanged}


## Refuse a path that is not something the engine imports, naming why — the check that has to happen HERE because reimport_files itself cannot report failure.
## Probe-measured on 4.7: an unknown path, a `.import` passed instead of its asset, and a file with no importer each print an error to stderr and return Nil, so a call made without this guard looks exactly like a successful one.
static func importable_refusal(asset: String) -> String:
	if not FileAccess.file_exists(asset):
		return "Error: %s does not exist, so there is nothing to import. Pass the ASSET's path (e.g. res://sprites/hero.png), not its .import sidecar." % asset
	if FileAccess.file_exists(import_path_for(asset)):
		return ""
	if Engine.is_editor_hint() and valid_state(asset) == "unknown":
		return ""
	return "Error: %s has no .import sidecar, which means the engine does not import it — it is loaded directly, the way a .gd, .tscn or .tres is. Only assets Godot converts on import (images, audio, fonts, 3D scenes) have import settings. To change what a .tres holds use edit_resource; to change a text file use edit_file." % asset
