extends SceneTree
## Headless regression tests for describe_class / describe_member's three-registry lookup: engine classes (ClassDB), this project's own class_name scripts (GDLLMClasses), and the doc-cache-only pages — the Variant types, the built-in scopes, and @GlobalScope's enums (GDLLMDocs.structure).
## Run from the project root:
##   godot --headless --script res://addons/gdllm-godot-agentic-harness/tools/class_lookup_test.gd
## Exits nonzero on any failure. The project-class half needs the global class cache, so run `godot --headless --editor --quit-after 5` once in a fresh checkout first.

# Preloaded rather than referenced by class_name so the test's own references survive a checkout whose global class cache hasn't been built yet.
const GDLLMTools = preload("res://addons/gdllm-godot-agentic-harness/gdllm_tools.gd")
const GDLLMClasses = preload("res://addons/gdllm-godot-agentic-harness/gdllm_classes.gd")
const GDLLMDocs = preload("res://addons/gdllm-godot-agentic-harness/gdllm_docs.gd")

## The fixture pair stands in for a game's own script class: two scripts chained by path, so the chain walk is testable without depending on an editor scan having registered a class_name.
const FIXTURE_PATH := "res://addons/gdllm-godot-agentic-harness/tools/class_fixture.gd"
const FIXTURE_BASE_PATH := "res://addons/gdllm-godot-agentic-harness/tools/class_fixture_base.gd"

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_test_engine_class_unchanged()
	_test_project_class_resolution()
	_test_project_class_own_members()
	_test_project_class_inherited()
	_test_project_class_filter()
	_test_project_class_member()
	_test_project_class_load_failures()
	_test_variant_type_structure()
	_test_global_enum_structure()
	_test_enum_prose_block_cap()
	_test_doc_page_member()
	_test_unknown_name_refusal()
	_test_kind_narrowing()
	_test_end_to_end()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


## Run a tool through the real execute dispatch and return its content string.
func _run(tool_name: String, args: Dictionary) -> String:
	return String((await GDLLMTools.execute(tool_name, args, false))["content"])


func _fixture() -> Script:
	return load(FIXTURE_PATH) as Script


## The ClassDB path must be untouched by the fallback ladder bolted under it.
func _test_engine_class_unchanged() -> void:
	var out := await _run("describe_class", {"class": "Sprite2D"})
	_check(out.contains("live ClassDB API"), "an engine class still reports as ClassDB truth")
	_check(out.contains("Inheritance: Sprite2D < Node2D"), "the engine inheritance chain is unchanged")
	_check(out.contains("centered"), "the engine class lists its own properties")
	var member := await _run("describe_member", {"class": "Sprite2D", "member": "get_rect"})
	_check(member.contains("Method (declared in Sprite2D)"), "an engine member still resolves through ClassDB")
	# Case-insensitivity and the prose-token fallback are ClassDB behaviors the project registry must not shadow.
	_check((await _run("describe_class", {"class": "sprite2d"})).contains("Inheritance: Sprite2D"), "a lowercased engine class still resolves")


func _test_project_class_resolution() -> void:
	var hit := GDLLMClasses.resolve("GDLLMDocs")
	_check(String(hit.get("class", "")) == "GDLLMDocs", "a registered class_name resolves")
	_check(String(hit.get("path", "")).ends_with("gdllm_docs.gd"), "the registry entry carries the script path")
	_check(String(GDLLMClasses.resolve("gdllmdocs").get("class", "")) == "GDLLMDocs", "resolution is case-insensitive")
	_check(String(GDLLMClasses.resolve("the GDLLMDocs class").get("class", "")) == "GDLLMDocs", "a prose request resolves on its first usable token")
	_check(GDLLMClasses.resolve("NotAProjectClass").is_empty(), "an unregistered name resolves to nothing")
	_check(GDLLMClasses.resolve("").is_empty(), "an empty request resolves to nothing")
	_check(GDLLMClasses.names().has("GDLLMTools"), "the name list feeds near-miss suggestions")


func _test_project_class_own_members() -> void:
	var out := GDLLMClasses.describe_script(_fixture(), true, "")
	_check(out.contains("Project script class class_fixture.gd"), "an unnamed script falls back to its file name")
	_check(out.contains("Inheritance: class_fixture.gd < class_fixture_base.gd < Resource < RefCounted < Object"), "the chain crosses both script bases and the engine base")
	_check(out.contains("read_function for one function, read_file for the file"), "the report names where the bodies are")
	_check(out.contains("take(item: Resource, index: int = -1) -> bool"), "an own method reports its full signature")
	_check(out.contains("display_name: String  [export]"), "an exported variable is marked")
	# An @export_category is a CATEGORY row like the one separating declaring scripts, so counting rows instead of matching paths ended the walk there and reported no variables at all.
	_check(out.contains("grouped_value: int  [export]"), "a variable declared after an @export_category is still reported")
	_check(not out.contains("Fixture Category") and not out.contains("Fixture Group"), "inspector headings are not reported as properties")
	_check(out.contains("contents: Array[int]"), "a typed array reports its element type")
	_check(out.contains("_hidden: float") and not out.contains("_hidden: float  [export]"), "a plain variable carries no export marker")
	_check(out.contains("instances: int  [static]"), "a static variable is listed and marked, though the script property list omits it")
	_check(out.contains("slot_changed(index: int, item: Resource)"), "an own signal reports its arguments")
	_check(out.contains("MAX_SLOTS = 12"), "an own constant reports its value")
	_check(out.contains("Kind = {") and out.contains("\"ARMOR\": 5"), "an enum arrives as the dictionary constant it is registered as")
	_check(out.contains("cannot tell an enum from any other dictionary constant"), "the enum-as-dictionary shape is disclosed rather than left to look like a missing Enums section")
	_check(out.contains("Inner classes (1)"), "an inner class gets its own section")
	# The default view is this script's own declarations: nothing from the base script, nothing from Resource.
	_check(not out.contains("base_value"), "a base script's variable is absent from the own-members view")
	_check(not out.contains("base_fired"), "a base script's signal is absent from the own-members view")
	_check(not out.contains("resource_path"), "the engine base's API is absent from the own-members view")
	_check(out.contains("shared_method() -> String"), "an override is attributed to the script that overrides it")
	_check(out.count("shared_method() -> String") == 1, "the override is not double-counted in the own-members view")


func _test_project_class_inherited() -> void:
	var out := GDLLMClasses.describe_script(_fixture(), false, "")
	_check(out.contains("each folded-in member tagged with the class that declares it"), "the inherited view says what the tags mean")
	_check(out.contains("base_value: int  [class_fixture_base.gd]"), "a base script's variable is folded in and tagged with its file")
	_check(out.contains("base_fired(what: String)  [class_fixture_base.gd]"), "a base script's signal is folded in and tagged")
	_check(out.contains("BASE_LIMIT = 3  [class_fixture_base.gd]"), "a base script's constant is folded in and tagged")
	_check(out.contains("[Resource]"), "the engine base's members are folded in and tagged with the ancestor that declares them")
	_check(out.contains("[Object]"), "the engine chain is walked to the top, not just one level")
	# The override is a genuine second declaration, so both are shown and the tag says which file each lives in; read under a filter, since folding in three engine ancestors overruns the section cap.
	var override_view := GDLLMClasses.describe_script(_fixture(), false, "shared")
	_check(override_view.count("shared_method() -> String") == 2, "an override shows both declarations in the inherited view")
	_check(override_view.contains("shared_method() -> String  [class_fixture_base.gd]"), "the shadowed declaration names the file it is in")


func _test_project_class_filter() -> void:
	var out := GDLLMClasses.describe_script(_fixture(), true, "slot")
	_check(out.contains("Filtered to members whose name contains \"slot\""), "the filter is disclosed")
	_check(out.contains("MAX_SLOTS = 12") and out.contains("slot_changed"), "the filter keeps every matching kind")
	_check(not out.contains("take(item"), "the filter drops non-matching members")
	var empty := GDLLMClasses.describe_script(_fixture(), true, "zzz")
	_check(empty.contains("No members whose name contains \"zzz\""), "an empty filter result says so rather than printing five empty sections")
	_check(empty.contains("pass inherited=true to search its bases too"), "the empty filter result names its levers")


func _test_project_class_member() -> void:
	var own := GDLLMClasses.describe_member_script(_fixture(), "take")
	_check(own.contains("Method (declared in class_fixture.gd — %s)" % FIXTURE_PATH), "an own member names the file that declares it")
	_check(own.contains("take(item: Resource, index: int = -1) -> bool"), "the member's full signature is reported")
	var inherited_member := GDLLMClasses.describe_member_script(_fixture(), "base_value")
	_check(inherited_member.contains("Property (declared in class_fixture_base.gd — %s)" % FIXTURE_BASE_PATH), "a base script's member names the base file")
	var engine_member := GDLLMClasses.describe_member_script(_fixture(), "resource_path")
	_check(engine_member.contains("Property (declared in Resource)"), "an engine member of a project class resolves through ClassDB")
	var static_member := GDLLMClasses.describe_member_script(_fixture(), "instances")
	_check(static_member.contains("Static variable (declared in class_fixture.gd"), "a static variable resolves as a member")
	var const_member := GDLLMClasses.describe_member_script(_fixture(), "MAX_SLOTS")
	_check(const_member.contains("Constant (declared in class_fixture.gd") and const_member.contains("= 12"), "a constant resolves with its value")
	var inner := GDLLMClasses.describe_member_script(_fixture(), "Inner")
	_check(inner.contains("Inner class (declared in class_fixture.gd"), "an inner class resolves as a member")
	var miss := GDLLMClasses.describe_member_script(_fixture(), "slot_change")
	_check(miss.contains("its own script, its base scripts, and Resource's engine API were all searched"), "a miss says which namespaces were searched")
	_check(miss.contains("slot_changed"), "a miss suggests the near-miss name")
	var nothing := GDLLMClasses.describe_member_script(_fixture(), "qqqqqqqq")
	_check(nothing.contains("read_file on %s" % FIXTURE_PATH), "a miss with no near-miss points at the file")


func _test_project_class_load_failures() -> void:
	var gone := GDLLMClasses.script_for({"class": "Ghost", "path": "res://__no_such_script.gd", "language": "GDScript"})
	_check(gone.has("error") and String(gone["error"]).contains("the global class list is stale"), "a registered path that no longer exists is named as a stale registry, not a broken script")
	_check(String(gone.get("error", "")).contains("search_files for \"class_name Ghost\""), "the stale-registry error names how to find where the script went")
	# A parse-broken .gd loads AS a GDScript with zero members, so without a guard the report would call a file that doesn't compile an empty class.
	var broken_path := "res://__gdllm_broken_class_fixture.gd"
	var handle := FileAccess.open(broken_path, FileAccess.WRITE)
	handle.store_string("extends Resource\n\n\nfunc oops(\n")
	handle.close()
	var broken := GDLLMClasses.script_for({"class": "Broken", "path": broken_path, "language": "GDScript"})
	DirAccess.remove_absolute(ProjectSettings.globalize_path(broken_path))
	_check(broken.has("error"), "a script that does not compile is refused rather than reported as an empty class")
	_check(String(broken.get("error", "")).contains("check_script"), "the does-not-compile error names check_script")
	var foreign := GDLLMClasses.script_for({"class": "Sharp", "path": "res://Sharp.cs", "language": "C#"})
	_check(foreign.has("error") and String(foreign["error"]).contains("C#"), "a non-GDScript class is refused by name")
	var ok := GDLLMClasses.script_for({"class": "Fixture", "path": FIXTURE_PATH, "language": "GDScript"})
	_check(ok.has("script"), "a loadable GDScript comes back as a script")


func _test_variant_type_structure() -> void:
	var out := await _run("describe_class", {"class": "Array"})
	_check(out.contains("Array is a Variant TYPE, not an Object class"), "a Variant type says why ClassDB missed it")
	_check(out.contains("documentation cache, which is generated from the same binary ClassDB is"), "the substitute registry is named and justified")
	_check(out.contains("append(value: Variant) -> void"), "a Variant type's method reports its real signature")
	_check(out.contains("slice(begin: int, end: int = 2147483647"), "argument defaults survive")
	_check(out.contains("Constructors (13)"), "constructors get their own section")
	_check(out.contains("operator [](index: int) -> Variant"), "operators are listed")
	_check(out.contains("call describe_docs with class \"Array\""), "the prose counterpart is named")
	var filtered := await _run("describe_class", {"class": "Callable", "filter": "bind"})
	_check(filtered.contains("bindv(arguments: Array) -> Callable") and not filtered.contains("get_object"), "the filter narrows a doc page the same way it narrows a class")
	var empty := await _run("describe_class", {"class": "Callable", "filter": "zzz"})
	_check(empty.contains("No members whose name contains \"zzz\" were found on Callable"), "an empty filter on a doc page says so")
	var scope := await _run("describe_class", {"class": "@GDScript"})
	_check(scope.contains("built-in scope, not a class"), "a built-in scope is named as one")
	var vec := await _run("describe_class", {"class": "Vector2"})
	_check(vec.contains("Axis { AXIS_X = 0, AXIS_Y = 1 }"), "a doc page's constants regroup into their enums")


func _test_global_enum_structure() -> void:
	var out := await _run("describe_class", {"class": "Key"})
	_check(out.contains("global enum Key — declared in @GlobalScope"), "a bare global enum name resolves to its scope")
	_check(out.contains("It is an ENUM, not a class"), "the report says why ClassDB missed it")
	_check(out.contains("KEY_ESCAPE = 4194305"), "the enum's values are reported")
	# 193 values would arrive whole without describe_class's own section cap, which the report reuses precisely so it does not.
	_check(out.contains("pass a `filter` substring to narrow"), "the value list is capped with its lever named")
	var filtered := await _run("describe_class", {"class": "Key", "filter": "escape"})
	_check(filtered.contains("KEY_ESCAPE = 4194305") and not filtered.contains("KEY_SPACE"), "the filter narrows the enum's values")
	var qualified := await _run("describe_class", {"class": "Variant.Type"})
	_check(qualified.contains("global enum Variant.Type"), "a qualified global enum name resolves too")
	_check((await _run("describe_class", {"class": "Error"})).contains("ERR_FILE_NOT_FOUND"), "another global enum resolves the same way")


## The prose counterpart of the structural cap above: describe_docs on a whole enum caps its per-value prose blocks at the same count, driven through the pure composer with synthetic hits.
func _test_enum_prose_block_cap() -> void:
	var hits: Array = []
	for i in range(30):
		hits.append({"declaring": "@GlobalScope", "enumeration": "Key", "item": {"name": "KEY_%d" % i, "value": i, "description": "Key %d." % i}})
	var block: String = GDLLMDocs._enum_block(hits)
	_check(block.contains("KEY_23 = 23"), "values up to the cap render with their prose")
	_check(not block.contains("KEY_25 = 25"), "values past the cap are not rendered")
	_check(block.contains("24 of 30 values shown"), "the remainder is counted")
	_check(block.contains("e.g. \"KEY_24\""), "the lever names a concrete omitted value to ask for")
	var small: Array = hits.slice(0, 3)
	_check(not GDLLMDocs._enum_block(small).contains("values shown"), "an under-cap enum carries no truncation line")


func _test_doc_page_member() -> void:
	var out := await _run("describe_member", {"class": "Array", "member": "append"})
	_check(out.contains("ClassDB has no entry for \"Array\""), "the delegation to the docs is disclosed, not silent")
	_check(out.contains("append(value: Variant) -> void"), "the member's signature comes back")
	_check(out.contains("push_back"), "the docs' prose rides along, which is what makes delegating better than a pointer")


func _test_unknown_name_refusal() -> void:
	var out := await _run("describe_class", {"class": "NotARealThingAnywhere"})
	_check(out.contains("is not an engine class (ClassDB), one of this project's own class_name scripts, or an engine doc page"), "the refusal names all three registries")
	_check(out.contains("read_file it by path, or search_files"), "the refusal names the tools for a script with no class_name")
	_check(out.contains("search_docs"), "the refusal names the tool for a concept rather than a name")
	# Plain containment suggested nothing for an invented name built out of a real one; the reverse direction is what catches it.
	var invented := await _run("describe_class", {"class": "StyleBoxBase"})
	_check(invented.contains("StyleBox"), "an invented name built from a real one suggests the real one")
	var near_project := await _run("describe_class", {"class": "GDLLMDoc"})
	_check(near_project.contains("GDLLMDocs (this project's script class)"), "a near-miss project class is suggested and labelled as one")
	var near_page := await _run("describe_class", {"class": "PackedByteArra"})
	_check(near_page.contains("PackedByteArray (engine doc page)"), "a near-miss doc page is suggested and labelled as one")


## `kind` narrows by SECTION where `filter` narrows by name — the axis a question about one member kind actually wants. Wild-measured: "what signals does Player emit" cost 14.4 KB as a search_files chain and 9.3 KB as a whole-class report, but 1.5 KB as its Signals section, which is the difference between winning marginally and winning outright.
func _test_kind_narrowing() -> void:
	var whole := await _run("describe_class", {"class": "Node"})
	var only_signals := await _run("describe_class", {"class": "Node", "kind": "signals"})
	_check(only_signals.contains("Signals (11)"), "the requested section is present in full")
	_check(not only_signals.contains("Methods (") and not only_signals.contains("Constants ("), "every other section is dropped")
	_check(only_signals.length() * 4 < whole.length(), "narrowing to one kind is dramatically cheaper than the whole class")
	_check(only_signals.contains("Narrowed to Signals only"), "the narrowing is disclosed, so a hidden section is never read as an absent one")
	# The inheritance chain and the header must survive, or the report stops being groundable.
	_check(only_signals.contains("Inheritance: Node < Object"), "the head survives the narrowing")

	var pair := await _run("describe_class", {"class": "Node", "kind": ["signals", "enums"]})
	_check(pair.contains("Signals (") and pair.contains("Enums ("), "a list selects several kinds")
	_check(not pair.contains("Methods ("), "a list still excludes the rest")
	for alias: String in ["funcs", "functions", "method", "Methods"]:
		var aliased := await _run("describe_class", {"class": "Node", "kind": alias})
		_check(aliased.contains("Methods (") and not aliased.contains("Signals ("), "\"%s\" resolves to the methods section" % alias)
	# The argument answers to the same synonym list every other tool's arguments do.
	_check((await _run("describe_class", {"class": "Node", "member_kind": "methods"})).contains("Methods ("), "a key synonym reaches the same argument")
	_check((await _run("describe_class", {"class": "Node", "kind": "vars"})).contains("Properties ("), "a variable spelling resolves to properties")
	# An unrecognized kind is refused rather than quietly widened back to the whole class, which would look like the argument was honored.
	var bad := await _run("describe_class", {"class": "Node", "kind": "banana"})
	_check(bad.begins_with("Error:") and bad.contains("is not a member kind"), "an unknown kind is refused by name")
	_check(bad.contains("constructors") and bad.contains("inner_classes"), "the refusal lists every kind that exists")

	# The two axes combine, and a filter that only matches inside an EXCLUDED section must read as no match rather than as a hit.
	var both := await _run("describe_class", {"class": "Control", "kind": "properties", "filter": "focus"})
	_check(both.contains("focus_mode"), "kind and filter combine")
	_check(not both.contains("Methods ("), "the kind still excludes other sections when a filter is present")
	var crossed := GDLLMClasses.describe_script(_fixture(), true, "take", {"Signals": true})
	_check(crossed.contains("No members whose name contains \"take\""), "a filter matching only an excluded section reads as no match")

	# Each rung honors it, and each names its OWN sections when asked for one it does not have.
	_check(GDLLMClasses.describe_script(_fixture(), true, "", {"Signals": true}).contains("slot_changed"), "a project class honors kind")
	_check(GDLLMClasses.describe_script(_fixture(), true, "", {"Inner classes": true}).contains("Inner classes (1)"), "a project class can be narrowed to its inner classes")
	var page := await _run("describe_class", {"class": "Array", "kind": "operators"})
	_check(page.contains("operator [](index: int) -> Variant") and not page.contains("Methods ("), "a doc page honors kind")
	var absent := await _run("describe_class", {"class": "Array", "kind": "signals"})
	_check(absent.contains("None of the requested kinds exist on this one. It reports: Constructors, Methods, Operators, Properties, Enums, Constants."), "a kind a Variant type has no section for names the ones it does have")
	var enum_absent := await _run("describe_class", {"class": "Key", "kind": "methods"})
	_check(enum_absent.contains("It reports: Constants."), "a global enum names its single section rather than returning nothing")
	_check((await _run("describe_class", {"class": "Key", "kind": "constants"})).contains("KEY_ESCAPE"), "a global enum honors the kind it does have")


func _test_end_to_end() -> void:
	for tool_name in ["describe_class", "describe_member"]:
		_check(GDLLMTools.is_registered(tool_name), "%s is registered" % tool_name)
		_check(not GDLLMTools.is_mutating(tool_name), "%s is read-only" % tool_name)
	var out := await _run("describe_class", {"class": "GDLLMDocs"})
	_check(out.contains("Project script class GDLLMDocs"), "a real registered project class resolves end to end")
	_check(out.contains("search(query: String) -> String"), "its methods carry real signatures")
	_check(out.contains("Inheritance: GDLLMDocs < RefCounted < Object"), "its chain reaches the engine base")
	var member := await _run("describe_member", {"class": "gdllmdocs", "member": "search"})
	_check(member.contains("Method (declared in GDLLMDocs"), "describe_member resolves a project class case-insensitively")
	# Reaching the capability is half of it: tool_search matches on the summary, so a model looking for a project class must land on describe_class.
	_check(String(GDLLMTools.REGISTRY["describe_class"]["summary"]).contains("class_name"), "describe_class's summary advertises project script classes")
	var found := false
	for entry in GDLLMTools.search("class_name script", false):
		if String(entry["name"]) == "describe_class":
			found = true
	_check(found, "tool_search finds describe_class from a project-class phrase")
