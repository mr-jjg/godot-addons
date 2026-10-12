extends RefCounted

## A store for AchKitTracker tests that keeps staged writes apart from flushed ones, so a test
## can prove an earn was flushed before `earned` fired. read() sees staged values first, like
## a debounced SaveStore.

## Flushed values.
var data: Dictionary = {}
## Written but not yet flushed.
var pending: Dictionary = {}
var reads := 0
var writes := 0
var flushes := 0
## [key, value] per write, in order.
var write_log: Array = []


func read(key: String, default_value: Variant) -> Variant:
	reads += 1
	if pending.has(key):
		return pending[key]
	return data.get(key, default_value)


func write(key: String, value: Variant) -> void:
	writes += 1
	pending[key] = value
	write_log.append([key, value])


func flush() -> void:
	flushes += 1
	data.merge(pending, true)
	pending.clear()


## The current value (staged or flushed), or `default_value`.
func value(key: String, default_value: Variant = null) -> Variant:
	return pending.get(key, data.get(key, default_value))
