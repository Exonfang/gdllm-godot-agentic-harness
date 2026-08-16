@tool
class_name GDLLMPathPolicy extends RefCounted
## Canonical, link-aware path policy shared by every local-agent filesystem tool.
##
## Godot does not expose no-follow file handles, so callers must still validate as
## close as possible to the operation. This class removes the larger lexical-only
## hole: every existing component is inspected and links are resolved before the
## project/user boundary is decided.

const MAX_LINK_HOPS := 64


static func canonicalize(requested: String, allow_external: bool) -> Dictionary:
	if requested == "" or requested.begins_with("uid://"):
		return {"path": requested, "absolute": requested, "error": ""}
	var absolute := _absolute_spelling(requested)
	var resolved := _resolve_existing_links(absolute)
	if String(resolved["error"]) != "":
		return {"path": "", "absolute": "", "error": String(resolved["error"])}
	absolute = String(resolved["absolute"])
	for scheme: String in ["res://", "user://"]:
		var root_result := _resolve_existing_links(ProjectSettings.globalize_path(scheme).replace("\\", "/").simplify_path())
		if String(root_result["error"]) != "":
			continue
		var root := String(root_result["absolute"]).trim_suffix("/")
		if not is_or_under(absolute, root):
			continue
		var relative := absolute.substr(root.length()).trim_prefix("/")
		return {"path": scheme if relative == "" else scheme + relative, "absolute": absolute, "error": ""}
	if allow_external:
		return {"path": absolute, "absolute": absolute, "error": ""}
	return {
		"path": "",
		"absolute": absolute,
		"error": "Error: %s resolves through the filesystem to %s, OUTSIDE the project and its user:// data directory — tool calls only reach files inside those two places. Move the file into one of those trees, or turn on \"Allow Tool Calls Outside Project Or User Directories\" explicitly." % [requested, absolute],
	}


## Re-run canonicalization for an already accepted path and fail if its physical
## destination changed. This narrows link-swap races; it cannot provide an
## atomic no-follow open because GDScript exposes no such handle.
static func revalidate(accepted_path: String, allow_external: bool) -> String:
	var now := canonicalize(accepted_path, allow_external)
	if String(now["error"]) != "":
		return String(now["error"])
	if not equivalent_spelling(accepted_path, String(now["path"])):
		return "Error: %s changed destination while the tool call was being checked; the operation was refused. Retry after the filesystem is stable." % accepted_path
	return ""


static func is_sensitive(path: String) -> bool:
	if path.begins_with("uid://"):
		return false
	var absolute := ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path()
	var session_root := ProjectSettings.globalize_path("user://gdllm").replace("\\", "/").simplify_path().trim_suffix("/")
	if is_or_under(absolute, session_root):
		return true
	if is_or_under(absolute, GDLLMCredentialStore.storage_path().get_base_dir()):
		return true
	var lower_parts := PackedStringArray(absolute.to_lower().split("/", false))
	for protected_dir: String in [".git", ".godot", ".ssh", ".aws", ".azure"]:
		if lower_parts.has(protected_dir):
			return true
	var file_name := absolute.get_file().to_lower()
	if file_name == ".env" or file_name.begins_with(".env."):
		return true
	if file_name in ["credentials", "credentials.json", "secrets.json", "id_rsa", "id_ed25519", ".git-credentials", ".netrc", ".npmrc", ".pypirc"]:
		return true
	var extension := file_name.get_extension()
	return extension in ["pem", "p12", "pfx", "key"]


static func sensitive_error(path: String) -> String:
	if not is_sensitive(path):
		return ""
	return "Error: %s is a protected credential, session, editor-cache, or version-control path. Its contents are deliberately excluded from model context." % path


static func entry_is_link(parent: String, entry: String) -> bool:
	var dir := DirAccess.open(parent)
	return dir != null and dir.is_link(entry)


static func is_or_under(absolute: String, root: String) -> bool:
	var a := absolute.replace("\\", "/").simplify_path()
	var r := root.replace("\\", "/").simplify_path().trim_suffix("/")
	if _case_insensitive_volume(r):
		a = a.to_lower()
		r = r.to_lower()
	return a == r or a.begins_with(r + "/")


static func equivalent_spelling(a: String, b: String) -> bool:
	var absolute_a := ProjectSettings.globalize_path(a).replace("\\", "/").simplify_path()
	var absolute_b := ProjectSettings.globalize_path(b).replace("\\", "/").simplify_path()
	return is_or_under(absolute_a, absolute_b) and is_or_under(absolute_b, absolute_a)


static func _absolute_spelling(requested: String) -> String:
	var normalized := requested.replace("\\", "/")
	if not _is_os_absolute(normalized) and not normalized.begins_with("res://") and not normalized.begins_with("user://"):
		normalized = "res://" + normalized.trim_prefix("./").trim_prefix("/")
	return ProjectSettings.globalize_path(normalized).replace("\\", "/").simplify_path()


static func _resolve_existing_links(initial: String) -> Dictionary:
	var pending := initial.replace("\\", "/").simplify_path()
	var seen := {}
	for _hop in range(MAX_LINK_HOPS + 1):
		var split := _split_absolute(pending)
		var current := String(split["root"])
		var parts: PackedStringArray = split["parts"]
		var followed := false
		for index in range(parts.size()):
			var component := parts[index]
			var parent := current
			var candidate := parent.path_join(component).replace("\\", "/").simplify_path()
			var dir := DirAccess.open(parent)
			if dir == null or not dir.is_link(component):
				current = candidate
				continue
			var identity := candidate.to_lower() if _case_insensitive_volume(candidate) else candidate
			if seen.has(identity):
				return {"absolute": "", "error": "Error: %s contains a symbolic-link or junction cycle; the path was refused." % initial}
			seen[identity] = true
			var target := dir.read_link(component).replace("\\", "/")
			if target == "":
				return {"absolute": "", "error": "Error: the link at %s could not be resolved; the path was refused fail-closed." % candidate}
			if not _is_os_absolute(target):
				target = parent.path_join(target)
			var tail := "/".join(parts.slice(index + 1))
			pending = target.path_join(tail).simplify_path() if tail != "" else target.simplify_path()
			followed = true
			break
		if not followed:
			return {"absolute": current, "error": ""}
	return {"absolute": "", "error": "Error: %s traverses too many symbolic links or junctions; the path was refused." % initial}


static func _split_absolute(path: String) -> Dictionary:
	var normalized := path.replace("\\", "/").simplify_path()
	if normalized.substr(1, 2) == ":/":
		return {"root": normalized.substr(0, 3), "parts": PackedStringArray(normalized.substr(3).split("/", false))}
	return {"root": "/", "parts": PackedStringArray(normalized.trim_prefix("/").split("/", false))}


static func _is_os_absolute(path: String) -> bool:
	return path.begins_with("/") or path.substr(1, 2) == ":/"


static func _case_insensitive_volume(_path: String) -> bool:
	# Godot's supported Windows filesystems are case-insensitive by default.
	# Other platforms retain exact comparisons; their case-sensitive defaults are
	# the safer fail-closed choice for a containment check.
	return OS.get_name() == "Windows"
