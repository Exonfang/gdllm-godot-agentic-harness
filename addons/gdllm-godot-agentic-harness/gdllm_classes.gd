@tool
class_name GDLLMClasses extends RefCounted
## Structural reference for the project's OWN script classes — the `class_name` declarations ProjectSettings registers, which ClassDB has never held.
## describe_class and describe_member dead-ended on every one of them (wild-measured: Slot three times, Boon, ValueSlider, ProjectileData), so the model fell back to reading whole script files to learn a signature — the narrow-context goal inverted, and on the project's own code rather than the engine's.
## Everything here is read off the live GDScript's registered API rather than parsed out of its text, so it reports what the engine actually loaded; bodies and comments stay behind read_file, which the report names.

# The rendered-constant clip this file browses under is user-configurable — see GDLLMTunables' gdllm/tool_output section (a script's lookup table is a constant like any other and would otherwise flood a browse).


## The global-class registry entry for `requested` (case-insensitive), or {} when the project declares no such class_name.
static func resolve(requested: String) -> Dictionary:
	var lowered := requested.strip_edges().to_lower()
	if lowered == "":
		return {}
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("class", "")).to_lower() == lowered:
			return entry
	# A prose request ("the Slot class") usually embeds the name as one word; the first token that resolves wins, mirroring the ClassDB resolver.
	if requested.contains(" "):
		for token in requested.split(" ", false):
			var hit := resolve(token)
			if not hit.is_empty():
				return hit
	return {}


## Every class_name the project registers, for the near-miss suggestions a lookup that missed everywhere offers.
static func names() -> Array[String]:
	var out: Array[String] = []
	for entry in ProjectSettings.get_global_class_list():
		out.append(String(entry.get("class", "")))
	return out


## The loaded Script behind a registry entry as {"script"}, or a teaching {"error"}. The two ways this fails want opposite fixes, so they are separated: a registered path that no longer exists means the global class list is stale, while a path that exists and still won't load is almost always a parse error — which hides the class from the engine too, so the error names the tool that shows what broke rather than reporting the class as missing.
static func script_for(entry: Dictionary) -> Dictionary:
	var cls := String(entry.get("class", ""))
	var path := String(entry.get("path", ""))
	if String(entry.get("language", "")) != "GDScript":
		return {"error": "Error: \"%s\" is a %s class (%s). Only GDScript classes can be described here — use read_file on the source." % [cls, entry.get("language", "non-GDScript"), path]}
	if not FileAccess.file_exists(path):
		return {"error": "Error: the project still registers \"%s\" as a class_name in %s, but that file does not exist — the global class list is stale, so the script was moved or deleted outside the editor. Run search_files for \"class_name %s\" to find where it went." % [cls, path, cls]}
	var loaded: Variant = ResourceLoader.load(path)
	# A parse-broken .gd still comes back AS a GDScript — with no base type, no members, and nothing to say it failed (probe-measured on 4.7) — so describing it would report an empty class as the truth about a file that simply doesn't compile. Every script that compiled has a base type, so an empty one is the signal.
	if not (loaded is Script) or String((loaded as Script).get_instance_base_type()) == "":
		return {"error": "Error: the project registers \"%s\" as a class_name in %s, but that script does not compile, so the engine has no API for it to report — and the class is invisible to the rest of the project too, not just here. Run check_script on %s to see what broke." % [cls, path, path]}
	return {"script": loaded}


## describe_class's report for one of the project's own class_name scripts, in describe_class's own section shape so the two read the same: the inheritance chain across script and engine bases, then the members, narrowed by `filter` and bounded by `no_inheritance`.
static func describe_script(script: Script, no_inheritance: bool, filter: String, kinds: Dictionary = {}) -> String:
	var chain := _script_chain(script)
	var cls := script_label(script)
	var native := String(script.get_instance_base_type())
	var links: Array[Script] = [chain[0]]
	if not no_inheritance:
		links = chain

	var props: Array = []
	var methods: Array = []
	var signals: Array = []
	var enums: Array = []
	var constants: Array = []
	var inner: Array = []
	var has_dict_constant := false
	for i in links.size():
		var link: Script = links[i]
		# Only the requested class's own members go untagged; everything folded in says which file to open to change it.
		var tag := "" if i == 0 else "  [%s]" % script_label(link)
		_collect_script_members(link, tag, filter, props, methods, signals, constants, inner)
		for value in link.get_script_constant_map().values():
			if value is Dictionary:
				has_dict_constant = true
	if not no_inheritance:
		_collect_engine_members(native, filter, props, methods, signals, enums, constants)

	var head: Array = []
	head.append("Project script class %s — declared in %s. This is one of the project's OWN class_name scripts, read from the live script's registered API; ClassDB, which describe_class normally reads, holds engine classes only. Bodies and comments are not in this view — read_function for one function, read_file for the file." % [cls, script.resource_path])
	head.append("")
	head.append("Inheritance: %s" % _inheritance_chain(chain, native))
	head.append("")
	if no_inheritance:
		head.append("Showing what %s itself declares. Pass inherited=true to fold in its base scripts and %s's engine API, or call describe_class on any name in the chain above." % [cls, native])
	else:
		head.append("Showing every member of %s — its own, its base scripts', and %s's engine API — each folded-in member tagged with the class that declares it." % [cls, native])
	if filter != "":
		head.append("Filtered to members whose name contains \"%s\"." % filter)
	var kinds_note := GDLLMTools._class_kinds_note(kinds)
	if kinds_note != "":
		head.append(kinds_note)
	# Only worth saying where the enums it explains would actually be looked for.
	if has_dict_constant and (kinds.is_empty() or kinds.has("Constants") or kinds.has("Enums")):
		head.append("A GDScript `enum` is registered as a dictionary constant, so enums appear under Constants (Kind = { \"WEAPON\": 0 }) rather than in an Enums section — the script's registered API cannot tell an enum from any other dictionary constant.")

	var pairs: Array = [
		["Properties", props], ["Methods", methods], ["Signals", signals],
		["Enums", enums], ["Constants", constants],
	]
	# An engine class never has inner classes, so a standing "none" line here would be noise on every project class that has none — unless `kind` asked for exactly that, where "none" is the answer.
	if not inner.is_empty() or kinds.has("Inner classes"):
		pairs.append(["Inner classes", inner])

	var any_member := false
	for pair in pairs:
		if (kinds.is_empty() or kinds.has(String(pair[0]))) and not (pair[1] as Array).is_empty():
			any_member = true
	if filter != "" and not any_member:
		head.append("")
		head.append("No members whose name contains \"%s\" were found on %s. Try a different substring, omit filter to see the whole class, or pass inherited=true to search its bases too." % [filter, cls])
		return "\n".join(head)

	return "\n".join(head) + "\n\n" + "\n\n".join(GDLLMTools._class_sections_for(pairs, kinds))


## describe_member's report for one member of a project script class: every match down the script chain and then up the engine base's ClassDB chain, each naming its declaring class and — for a script — the file that declares it, which is where a change would go.
static func describe_member_script(script: Script, member: String) -> String:
	var cls := script_label(script)
	var needle := member.to_lower()
	var findings: Array = []
	for link in _script_chain(script):
		var where := script_label(link)
		for m in _own_methods(link):
			if String(m.get("name", "")).to_lower() == needle:
				findings.append("Method (declared in %s — %s): %s" % [where, link.resource_path, GDLLMTools._method_signature(m)])
		for p in _own_properties(link):
			if String(p.get("name", "")).to_lower() == needle:
				findings.append("Property (declared in %s — %s): %s: %s%s" % [where, link.resource_path, p.get("name", ""), _property_type(p), _export_marker(p)])
		for p in _own_static_properties(link):
			if String(p.get("name", "")).to_lower() == needle:
				findings.append("Static variable (declared in %s — %s): %s: %s" % [where, link.resource_path, p.get("name", ""), GDLLMTools._type_label(p)])
		for key in link.get_script_constant_map():
			if String(key).to_lower() != needle:
				continue
			var value: Variant = link.get_script_constant_map()[key]
			if value is Script:
				findings.append("Inner class (declared in %s — %s): %s" % [where, link.resource_path, key])
			else:
				findings.append("Constant (declared in %s — %s): %s = %s" % [where, link.resource_path, key, _constant_value(value)])
		for s in _own_signals(link):
			if String(s.get("name", "")).to_lower() == needle:
				findings.append("Signal (declared in %s — %s): %s" % [where, link.resource_path, GDLLMTools._signal_signature(s)])
	var native := String(script.get_instance_base_type())
	findings.append_array(GDLLMTools._member_findings(native, member))
	if findings.is_empty():
		return _unknown_member_message(script, native, member)
	var lines: Array = ["Reference for %s.%s — %s is one of the project's OWN class_name scripts, so its members are read from the live script's registered API; anything inherited from %s comes from ClassDB." % [cls, member, cls, native], ""]
	lines.append_array(findings)
	return "\n".join(lines)


## A script's display name: its class_name when it has one, else its file, since an unnamed base script has no other handle to offer.
static func script_label(script: Script) -> String:
	var global_name := String(script.get_global_name())
	return global_name if global_name != "" else String(script.resource_path).get_file()


## The script chain most-derived first — a GDScript extends another script as often as it extends an engine class, and each link declares its own members.
static func _script_chain(script: Script) -> Array[Script]:
	var chain: Array[Script] = []
	var link := script
	while link != null:
		chain.append(link)
		link = link.get_base_script()
	return chain


## "Slot < Panel < Container < … < Object": the script bases by name, then the engine chain from the native base, so every rung is a name describe_class can be called on.
static func _inheritance_chain(chain: Array[Script], native: String) -> String:
	var parts: Array[String] = []
	for link in chain:
		parts.append(script_label(link))
	var anc := native
	while anc != "":
		parts.append(anc)
		anc = ClassDB.get_parent_class(anc)
	return " < ".join(parts)


## Append one script link's own members to the gathering arrays, tagged and filtered.
static func _collect_script_members(link: Script, tag: String, filter: String, props: Array, methods: Array, signals: Array, constants: Array, inner: Array) -> void:
	for p in _own_properties(link):
		var pname := String(p.get("name", ""))
		if _filtered_out(pname, filter):
			continue
		props.append("%s: %s%s%s" % [pname, _property_type(p), _export_marker(p), tag])
	for p in _own_static_properties(link):
		var sname := String(p.get("name", ""))
		if _filtered_out(sname, filter):
			continue
		props.append("%s: %s  [static]%s" % [sname, GDLLMTools._type_label(p), tag])
	for m in _own_methods(link):
		if _filtered_out(String(m.get("name", "")), filter):
			continue
		methods.append(GDLLMTools._method_signature(m) + tag)
	for s in _own_signals(link):
		if _filtered_out(String(s.get("name", "")), filter):
			continue
		signals.append(GDLLMTools._signal_signature(s) + tag)
	for key in link.get_script_constant_map():
		if _filtered_out(String(key), filter):
			continue
		var value: Variant = link.get_script_constant_map()[key]
		if value is Script:
			inner.append("%s%s" % [key, tag])
		else:
			constants.append("%s = %s%s" % [key, _constant_value(value), tag])


## Append the engine base's ClassDB members, walked one ancestor at a time so each is tagged with the class that really declares it rather than merged anonymously.
static func _collect_engine_members(native: String, filter: String, props: Array, methods: Array, signals: Array, enums: Array, constants: Array) -> void:
	var anc := native
	while anc != "":
		var tag := "  [%s]" % anc
		for line in GDLLMTools._class_properties(anc, true, filter):
			props.append(String(line) + tag)
		for line in GDLLMTools._class_methods(anc, true, filter):
			methods.append(String(line) + tag)
		for line in GDLLMTools._class_signals(anc, true, filter):
			signals.append(String(line) + tag)
		for line in GDLLMTools._class_enums(anc, true, filter):
			enums.append(String(line) + tag)
		for line in GDLLMTools._class_constants(anc, true, filter, GDLLMTools._class_enum_member_set(anc, true)):
			constants.append(String(line) + tag)
		anc = ClassDB.get_parent_class(anc)


## The methods this script itself declares: get_script_method_list() returns the script's own entries followed by its whole base chain's, so the leading slice is exactly what this file adds — an override appears twice, once here and once under its base, which is what keeps the count exact (probe-measured on 4.7).
static func _own_methods(script: Script) -> Array:
	var all := script.get_script_method_list()
	return all.slice(0, all.size() - _inherited_count(script, true))


## The signals this script itself declares, by the same leading-slice rule the methods use.
static func _own_signals(script: Script) -> Array:
	var all := script.get_script_signal_list()
	return all.slice(0, all.size() - _inherited_count(script, false))


## How many of a script's listed methods (or signals) came from its base chain rather than from the script itself.
static func _inherited_count(script: Script, want_methods: bool) -> int:
	var base := script.get_base_script()
	if base == null:
		return 0
	return (base as Script).get_script_method_list().size() if want_methods else (base as Script).get_script_signal_list().size()


## The variables this script itself declares. The property list interleaves one category row per declaring script, that script's path in its hint_string, so the rows between this script's row and the next script's belong to it.
## An @export_category is a category row TOO, told apart only by carrying no path — matching on the path rather than counting rows is what keeps a script that uses one from reporting no variables at all (wild-measured against a real game's Slot, whose @export_group headings were also arriving as properties named "Node Connections: void").
static func _own_properties(script: Script) -> Array:
	var own_path := String(script.resource_path)
	var out: Array = []
	for p in script.get_script_property_list():
		var usage := int(p.get("usage", 0))
		var declaring := String(p.get("hint_string", ""))
		if usage & PROPERTY_USAGE_CATEGORY and declaring != "":
			if declaring != own_path:
				break
			continue
		# The inspector headings @export_category/@export_group/@export_subgroup are layout, not members.
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		out.append(p)
	return out


## The static variables this script declares. They are absent from get_script_property_list() — a static lives on the Script object itself — so a report that skipped them would call a real member missing, the one failure a grounding tool must not have (probe-measured on 4.7).
static func _own_static_properties(script: Script) -> Array:
	var inherited: Dictionary = {}
	var base := script.get_base_script()
	if base != null:
		for p in (base as Script).get_property_list():
			if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				inherited[String(p.get("name", ""))] = true
	var out: Array = []
	for p in script.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE and not inherited.has(String(p.get("name", ""))):
			out.append(p)
	return out


## A script variable's type as the source writes it: the engine's own label, plus the element types a typed Array or Dictionary carries in its hint — the part the plain label flattens to "Array"/"Dictionary", and exactly what a caller writing code against the variable needs.
static func _property_type(p: Dictionary) -> String:
	var hint := int(p.get("hint", 0))
	var spec := String(p.get("hint_string", ""))
	if hint == PROPERTY_HINT_ARRAY_TYPE and spec != "":
		return "Array[%s]" % _element_type(spec)
	if hint == PROPERTY_HINT_DICTIONARY_TYPE and spec.contains(";"):
		return "Dictionary[%s, %s]" % [_element_type(spec.get_slice(";", 0)), _element_type(spec.get_slice(";", 1))]
	return GDLLMTools._type_label(p)


## One element type out of a container hint, which encodes an object element as "24/34:Texture2D" and a plain one as its bare name.
static func _element_type(spec: String) -> String:
	return spec.get_slice(":", spec.get_slice_count(":") - 1)


## The "[export]" marker on a script variable the inspector shows, which is the difference between a value a scene or .tres can carry and one only code sets.
static func _export_marker(p: Dictionary) -> String:
	var usage := int(p.get("usage", 0))
	return "  [export]" if usage & (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE) else ""


## A constant's value rendered on one line and clipped, so a big table costs a line rather than a page.
static func _constant_value(value: Variant) -> String:
	var text := GDLLMTools._format_default(value)
	if text.length() <= GDLLMTunables.geti(GDLLMTunables.BROWSE_VALUE_MAX_CHARS):
		return text
	return text.substr(0, GDLLMTunables.geti(GDLLMTunables.BROWSE_VALUE_MAX_CHARS)) + "… (+%d more chars — read_file for the whole value)" % (text.length() - GDLLMTunables.geti(GDLLMTunables.BROWSE_VALUE_MAX_CHARS))


static func _filtered_out(name: String, filter: String) -> bool:
	return filter != "" and not name.to_lower().contains(filter)


## Error text for a member that resolves nowhere on a project class, with near-misses drawn from the whole script chain AND the engine base — the two namespaces a script class member can live in.
static func _unknown_member_message(script: Script, native: String, member: String) -> String:
	var cls := script_label(script)
	var needle := member.to_lower()
	var candidates: Array[String] = []
	for link in _script_chain(script):
		for m in _own_methods(link):
			candidates.append(String(m.get("name", "")))
		for p in _own_properties(link):
			candidates.append(String(p.get("name", "")))
		for p in _own_static_properties(link):
			candidates.append(String(p.get("name", "")))
		for s in _own_signals(link):
			candidates.append(String(s.get("name", "")))
		for key in link.get_script_constant_map():
			candidates.append(String(key))
	candidates.append_array(GDLLMTools._all_member_names(native))
	var suggestions: Array[String] = []
	for n in candidates:
		var lowered := n.to_lower()
		# The reverse containment needs a minimum length, or a needle like "get_pos" would drag in "get".
		if (lowered.contains(needle) or (lowered.length() >= 4 and needle.contains(lowered))) and not suggestions.has(n):
			suggestions.append(n)
	var msg := "No member named \"%s\" on %s (its own script, its base scripts, and %s's engine API were all searched)." % [member, cls, native]
	if suggestions.is_empty():
		return msg + " Call describe_class on %s to see everything it declares, or read_file on %s." % [cls, script.resource_path]
	suggestions.sort()
	var note := "" if suggestions.size() <= GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP) else " (and %d more)" % (suggestions.size() - GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))
	return "%s Did you mean: %s%s?" % [msg, ", ".join(suggestions.slice(0, GDLLMTunables.geti(GDLLMTunables.SUGGESTION_LIST_CAP))), note]
