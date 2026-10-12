class_name AchKitSnapserBridge
extends RefCounted

## Mirrors a tracker's earned achievements onto a Snapser service: one analytics event per earn
## and one aggregate statistic SET to the number held. Duck-typed, so achievements_kit does not
## depend on snapser_kit: `service` is any Node with
##   track(event: String, props: Dictionary) -> void
##   record_stat(key: String, value: int) -> Dictionary   (may be a coroutine)
##   wait_until_ready() -> bool                            (may be a coroutine)
##   is_online() -> bool, is_booted() -> bool, signal boot_finished
##   config (an object with is_offline() -> bool; null counts as offline)
## A SnapKitService (a game's Snapser autoload) has all of these. The game's facade owns the
## bridge and passes itself, so every call still goes through the facade:
##
##   var ach_bridge := AchKitSnapserBridge.new(self, Achievements, "achievements_earned",
##       "achievement_earned")
##
## Keep a reference: the bridge is RefCounted and its signal connections die with it.
##
## The event is best-effort (the kit's analytics buffer is in memory, so events from an offline
## session that quits are lost). The stat plus the cloud save are the durable record, and the
## boot catch-up repairs the stat.

## After each stat post that sent a request: {ok, error, value}.
signal synced(summary: Dictionary)

var service: Node
var tracker: AchKitTracker
var stat_key: String
var event_name: String

var _post_queued := false


func _init(p_service: Node, p_tracker: AchKitTracker, p_stat_key: String, p_event: String) -> void:
	service = p_service
	tracker = p_tracker
	stat_key = p_stat_key
	event_name = p_event
	if tracker != null:
		tracker.earned.connect(_on_earned)
	if service == null:
		return
	if service.is_booted():
		_on_boot_finished()
	else:
		service.boot_finished.connect(_on_boot_finished, CONNECT_ONE_SHOT)


## COROUTINE. SET the stat to tracker.earned_count(): the catch-up / "post now" path.
## -> {ok, error, value}. Sends nothing (and emits nothing) when the service is offline or
## the count is 0 (error "offline" / "nothing_to_post").
func post_count() -> Dictionary:
	if service == null or tracker == null:
		return {"ok": false, "error": "no_service", "value": 0}
	if _is_offline():
		return {"ok": false, "error": "offline", "value": tracker.earned_count()}
	var up: bool = await service.wait_until_ready()
	if not up or not service.is_online():
		return {"ok": false, "error": "offline", "value": tracker.earned_count()}
	var count := tracker.earned_count()
	if count <= 0:
		return {"ok": false, "error": "nothing_to_post", "value": 0}
	var r: Variant = await service.record_stat(stat_key, count)
	var res: Dictionary = r if typeof(r) == TYPE_DICTIONARY else {}
	var summary := {"ok": bool(res.get("ok", false)), "error": str(res.get("error", "")), "value": count}
	synced.emit(summary)
	return summary


func _on_earned(id: StringName) -> void:
	if service == null:
		return
	service.track(event_name, {"id": str(id)})
	# A burst of earns in one frame makes one request.
	if not _post_queued:
		_post_queued = true
		_post_now.call_deferred()


func _post_now() -> void:
	_post_queued = false
	await post_count()


## After startup (and its cloud pull): catch the stat up with anything earned offline. Only
## when there is something to report, so a fresh player's launch costs no request.
func _on_boot_finished() -> void:
	if tracker != null and tracker.earned_count() > 0:
		post_count()


func _is_offline() -> bool:
	var cfg: Variant = service.get("config")
	if cfg == null:
		return true
	if cfg is Object and (cfg as Object).has_method("is_offline"):
		return bool(cfg.is_offline())
	return false
