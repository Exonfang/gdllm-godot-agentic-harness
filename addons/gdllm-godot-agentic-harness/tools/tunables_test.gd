extends SceneTree
## Headless contract tests for the configurable tunables (GDLLMTunables): every spec must be described for the settings dialog with a unique key tail (fill() depends on tail uniqueness absolutely), every default must sit inside a well-formed range on the spinbox grid with min/max/step typed like the default, every capped_by must name a real sibling with no cap of its own and a default the sibling's default already satisfies (so headless answers equal in-editor answers at defaults), the pure _resolve rule must clamp and cap correctly under synthetic values (the in-editor path the headless getters never exercise), every {tunable:...} token in the model-visible registry prose must resolve through fill(), and — the dead-knob guard — every spec key must be READ (a geti/getf call, not a comment mention) somewhere in production code, so a setting can never again be registered and described while its call site keeps a hardcoded number (the regression review caught on the dependency-lines cap).
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/tunables_test.gd
## Exits nonzero on any failure. One "GDLLMTunables: fill() found no tunable" error line is expected — the unknown-token behavior is asserted on purpose.

## The runtime sources the dead-knob guard sweeps, recursively: every shipped script except the tunables/help pair (which reference every key by definition) and this tools directory.
const RUNTIME_DIR := "res://addons/gdllm-godot-agentic-harness"
const GUARD_EXEMPT := ["gdllm_tunables.gd", "gdllm_settings_help.gd"]
const GUARD_SKIP_DIRS := ["tools"]

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_specs_described()
	_test_spec_ranges()
	_test_capped_by()
	_test_resolve()
	_test_headless_defaults()
	_test_protocol_couplings()
	_test_fill_round_trip()
	_test_fill_unknown_tail()
	_test_every_key_read_in_production()
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAILED: %s" % what)


## Every registered tunable carries settings-dialog prose long enough to actually explain it (the GDLLMColors description contract, extended to the tunables), and every key's tail — the segment fill() tokens address it by — is unique.
func _test_specs_described() -> void:
	var tails: Dictionary = {}
	for key: String in GDLLMTunables.SPECS:
		var described: bool = GDLLMSettingsHelp.DESCRIPTIONS.has(key)
		_check(described, "%s has a settings-dialog description" % key)
		if described:
			_check(String(GDLLMSettingsHelp.DESCRIPTIONS[key]).length() > 40, "%s's description is a real explanation, not a stub" % key)
		var tail := key.get_slice("/", 2)
		_check(not tails.has(tail), "%s's key tail \"%s\" is unique (fill() addresses tunables by tail)" % [key, tail])
		tails[tail] = true


## Every spec is well formed: a positive step, min below max, min/max/step typed like the default (registration branches on the default's type while the range hint interpolates all three, so a mixed spec would register a spinbox whose hint lies about its type), and a default inside the range on the spinbox grid (min + k*step reaches it — an off-grid default can never be re-entered with the spinner once nudged).
func _test_spec_ranges() -> void:
	for key: String in GDLLMTunables.SPECS:
		var spec: Dictionary = GDLLMTunables.SPECS[key]
		_check(float(spec["step"]) > 0.0, "%s's step is positive" % key)
		_check(float(spec["min"]) < float(spec["max"]), "%s's min sits below its max" % key)
		var wants_float: bool = spec["default"] is float
		_check((spec["min"] is float) == wants_float and (spec["max"] is float) == wants_float and (spec["step"] is float) == wants_float, "%s's min/max/step are typed like its default" % key)
		var default_value: float = float(spec["default"])
		_check(default_value >= float(spec["min"]), "%s's default is not below its min" % key)
		_check(bool(spec.get("or_greater", false)) or default_value <= float(spec["max"]), "%s's default is not above its max" % key)
		if float(spec["step"]) > 0.0:
			var steps := (default_value - float(spec["min"])) / float(spec["step"])
			_check(absf(steps - roundf(steps)) < 0.0001, "%s's default is reachable on its spinbox step grid" % key)


## capped_by must name a registered sibling that carries no capped_by of its own (keeping _value's pair resolution single-hop by construction), whose default already satisfies the pair (headless reads skip stored values, so inconsistent DEFAULTS would split headless and in-editor behavior), and whose floor is no lower than the capped knob's own (so the cap can never push a value below its registered range).
func _test_capped_by() -> void:
	for key: String in GDLLMTunables.SPECS:
		var spec: Dictionary = GDLLMTunables.SPECS[key]
		if not spec.has("capped_by"):
			continue
		var bound := String(spec["capped_by"])
		_check(GDLLMTunables.SPECS.has(bound), "%s's capped_by names a registered tunable" % key)
		if not GDLLMTunables.SPECS.has(bound):
			continue
		var bound_spec: Dictionary = GDLLMTunables.SPECS[bound]
		_check(not bound_spec.has("capped_by"), "%s's capped_by target carries no capped_by of its own" % key)
		_check(float(spec["default"]) <= float(bound_spec["default"]), "%s's default already satisfies its capped_by sibling's default" % key)
		_check(float(bound_spec["min"]) >= float(spec["min"]), "%s's capped_by sibling can never bound it below its own min" % key)


## The pure resolution rule, driven with synthetic stored/bound values — the clamp-and-cap logic the headless getters never reach (in the editor it runs on every read), including the garbage-in-default-out rail for hand-edited settings files.
func _test_resolve() -> void:
	var spec := {"default": 10, "min": 5, "max": 50, "step": 1}
	_check(int(GDLLMTunables._resolve(spec, 30, null)) == 30, "_resolve passes an in-range value through")
	_check(int(GDLLMTunables._resolve(spec, "garbage", null)) == 10, "_resolve resolves a non-numeric stored value to the default")
	_check(int(GDLLMTunables._resolve(spec, null, null)) == 10, "_resolve resolves a null stored value to the default")
	_check(int(GDLLMTunables._resolve(spec, NAN, null)) == 10, "_resolve resolves a NaN stored value to the default")
	_check(int(GDLLMTunables._resolve(spec, INF, null)) == 10, "_resolve resolves +inf to the default rather than riding past the max")
	_check(int(GDLLMTunables._resolve(spec, -INF, null)) == 10, "_resolve resolves -inf to the default")
	_check(int(GDLLMTunables._resolve(spec, 2, null)) == 5, "_resolve lifts a below-min value to min")
	_check(int(GDLLMTunables._resolve(spec, 90, null)) == 50, "_resolve caps an above-max value at max")
	var open := {"default": 10, "min": 5, "max": 50, "step": 1, "or_greater": true}
	_check(int(GDLLMTunables._resolve(open, 90, null)) == 90, "_resolve lets or_greater keep an above-max value")
	_check(int(GDLLMTunables._resolve(spec, 30, 20)) == 20, "_resolve caps at a lower capped_by bound")
	_check(int(GDLLMTunables._resolve(spec, 30, 40)) == 30, "_resolve leaves a value under its capped_by bound alone")
	_check(int(GDLLMTunables._resolve(spec, 90, 20)) == 20, "_resolve applies range clamp and pair cap together")


## Outside the editor every getter answers with the shipped default — the property the whole headless suite leans on (the capped_by pass is provably a no-op there, per _test_capped_by's default-consistency check).
func _test_headless_defaults() -> void:
	for key: String in GDLLMTunables.SPECS:
		var spec: Dictionary = GDLLMTunables.SPECS[key]
		if spec["default"] is float:
			_check(GDLLMTunables.getf(key) == float(spec["default"]), "%s reads back its default headless (getf)" % key)
		else:
			_check(GDLLMTunables.geti(key) == int(spec["default"]), "%s reads back its default headless (geti)" % key)


## Couplings to constants outside GDLLMTunables (which is deliberately class-reference-free, so it cannot assert them itself): the click-record floor must cover one input sequence's step cap, or a sequence's own clicks could fall off its own report.
func _test_protocol_couplings() -> void:
	var spec: Dictionary = GDLLMTunables.SPECS[GDLLMTunables.CLICK_RECORD_CAP]
	_check(int(spec["min"]) >= GDLLMGameProtocol.MAX_STEPS, "CLICK_RECORD_CAP's floor covers GDLLMGameProtocol.MAX_STEPS")


## Every {tunable:...} token in the model-visible prose — tool descriptions, nested parameter descriptions, tool_search's own definition, and EVERY string constant GDLLMTools declares (usage lines, break messages, nudges — anything that could reach the model) — must resolve through fill(); a typo'd tail would otherwise ship a literal token to the model.
func _test_fill_round_trip() -> void:
	var token_count := 0
	for name in GDLLMTools.REGISTRY:
		var entry_json := JSON.stringify(GDLLMTools.REGISTRY[name])
		token_count += entry_json.count("{tunable:")
		_check(not GDLLMTunables.fill(entry_json).contains("{tunable:"), "every token in %s's registry entry resolves through fill()" % name)
	var search_json := JSON.stringify(GDLLMTools.TOOL_SEARCH_TOOL)
	_check(not GDLLMTunables.fill(search_json).contains("{tunable:"), "every token in tool_search's own definition resolves through fill()")
	var constant_map: Dictionary = (GDLLMTools as Script).get_script_constant_map()
	for const_name in constant_map:
		var value: Variant = constant_map[const_name]
		if not (value is String):
			continue
		token_count += String(value).count("{tunable:")
		_check(not GDLLMTunables.fill(String(value)).contains("{tunable:"), "every token in GDLLMTools.%s resolves through fill()" % const_name)
	_check(token_count > 0, "the registry prose actually carries tunable tokens (the mechanism is live, not vestigial)")


## An unknown tail must survive fill() visibly (and raise the push_error the header calls expected) — a silent blank would hide the typo from the transcript that could catch it.
func _test_fill_unknown_tail() -> void:
	_check(GDLLMTunables.fill("x {tunable:no_such_tail} y").contains("{tunable:no_such_tail}"), "an unknown token stays visible in the filled text")
	_check(GDLLMTunables.fill("plain text") == "plain text", "token-free text passes through fill() untouched")


## The dead-knob guard: every SPECS key's constant is READ — a literal geti( or getf( call — somewhere in the runtime sources, swept recursively (registration and help are exempt — they touch every key by definition; a bare GDLLMTunables.<CONST> mention is NOT enough, because comments and prose satisfy that while reading nothing). A key that fails here is registered and described but changes nothing.
func _test_every_key_read_in_production() -> void:
	var sources := _collect_sources(RUNTIME_DIR)
	_check(sources != "", "the runtime sources were collected")
	var constant_map: Dictionary = (GDLLMTunables as Script).get_script_constant_map()
	for const_name in constant_map:
		var value: Variant = constant_map[const_name]
		if not (value is String and GDLLMTunables.SPECS.has(value)):
			continue
		var read := sources.contains("geti(GDLLMTunables.%s)" % const_name) or sources.contains("getf(GDLLMTunables.%s)" % const_name)
		_check(read, "%s is read (geti/getf) somewhere in production code — not a dead knob" % const_name)


## The guard's source sweep: every non-exempt .gd under `path`, recursing into subdirectories except the skipped ones.
func _collect_sources(path: String) -> String:
	var sources := ""
	var dir := DirAccess.open(path)
	if dir == null:
		return ""
	for file in dir.get_files():
		if file.ends_with(".gd") and not GUARD_EXEMPT.has(file):
			sources += FileAccess.get_file_as_string("%s/%s" % [path, file])
	for sub in dir.get_directories():
		if not GUARD_SKIP_DIRS.has(sub):
			sources += _collect_sources("%s/%s" % [path, sub])
	return sources
