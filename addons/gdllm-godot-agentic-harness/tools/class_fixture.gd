extends "res://addons/gdllm-godot-agentic-harness/tools/class_fixture_base.gd"
## Derived half of class_lookup_test's fixture pair, carrying one of every member kind describe_class reports for a project script class: a signal, an enum, a constant, a static variable, an export, a typed container, a private variable, an inner class, and an override of the base's method.

signal slot_changed(index: int, item: Resource)

enum Kind { WEAPON, ARMOR = 5, TRINKET }

const MAX_SLOTS := 12

static var instances: int = 0

@export_category("Fixture Category")
@export var display_name: String = "slot"

@export_group("Fixture Group")
@export var grouped_value: int = 7

var contents: Array[int] = []
var _hidden: float = 0.5


class Inner:
	var x: int = 1


func take(item: Resource, index: int = -1) -> bool:
	return item != null and index >= -1


func shared_method() -> String:
	return "derived"
