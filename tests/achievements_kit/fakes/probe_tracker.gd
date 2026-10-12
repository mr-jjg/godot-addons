extends AchKitTracker

## An AchKitTracker that records what the virtuals and log hooks saw, and whose gate a test
## can close.

var allow := true
var backfills := 0
var warnings := PackedStringArray()
var errors := PackedStringArray()


func _earning_allowed(_id: StringName, _kind: StringName, _context: Dictionary) -> bool:
	return allow


func _backfill() -> void:
	backfills += 1


func _warn(message: String) -> void:
	warnings.append(message)


func _error(message: String) -> void:
	errors.append(message)
