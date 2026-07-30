extends Resource
## Base half of class_lookup_test's fixture pair: a plain script another script extends BY PATH, so the script-chain walk is exercised without registering a class_name the test would then depend on the editor having scanned.

signal base_fired(what: String)

const BASE_LIMIT := 3

var base_value: int = 1


func base_method(a: int) -> int:
	return a


func shared_method() -> String:
	return "base"
