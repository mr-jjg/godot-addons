class_name AchKitSaveServiceStore
extends RefCounted

## Adapts a SaveService-style object (get_var_value(key, default) / set_var_value(key, value),
## optionally flush()) to AchKitTracker's store contract. Use it when a game has no store with
## read/write of its own:
##
##   configure(Defs.ACHIEVEMENTS, Kinds.KINDS, Defs.RENAMED, Defs.RETIRED,
##           AchKitSaveServiceStore.new(SaveService), "prog_ach_", "prog_achp_")
##
## Duck-typed: the addon does not depend on any particular save addon.

var service: Object


func _init(p_service: Object) -> void:
	service = p_service


func read(key: String, default_value: Variant) -> Variant:
	return service.get_var_value(key, default_value)


func write(key: String, value: Variant) -> void:
	service.set_var_value(key, value)


## The service's own flush() when it has one; a write-through service needs none.
func flush() -> void:
	if service.has_method("flush"):
		service.flush()
