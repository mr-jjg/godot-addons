class_name AchKitMemoryStore
extends RefCounted

## An in-memory store for AchKitTracker (tests, tools, a game with no save yet). Satisfies the
## tracker's store contract: read / write / flush. Nothing persists.

## key -> value. Read it directly in tests.
var data: Dictionary = {}
## How many times flush() ran.
var flush_count: int = 0


func read(key: String, default_value: Variant) -> Variant:
	var v: Variant = data.get(key, default_value)
	return v.duplicate(true) if typeof(v) in [TYPE_ARRAY, TYPE_DICTIONARY] else v


func write(key: String, value: Variant) -> void:
	data[key] = value.duplicate(true) if typeof(value) in [TYPE_ARRAY, TYPE_DICTIONARY] else value


func flush() -> void:
	flush_count += 1


func has(key: String) -> bool:
	return data.has(key)


func clear() -> void:
	data.clear()
