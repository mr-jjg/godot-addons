extends "res://tests/achievements_kit/achkit_test_case.gd"

## AchKitSnapserBridge against a fake service: event per earn, one coalesced stat post per
## frame, offline sends no stat, boot catch-up only when something is earned, synced summary.

const Kinds := preload("res://tests/achievements_kit/fixtures/kinds.gd")
const FakeStore := preload("res://tests/achievements_kit/fakes/fake_store.gd")
const FakeService := preload("res://tests/achievements_kit/fakes/fake_snap_service.gd")
const STAT := "achievements_earned"
const EVENT := "achievement_earned"
const EP := "b_ach_"
const PP := "b_achp_"


func _tracker(store: Object = null) -> AchKitTracker:
	var defs := {}
	for id: StringName in [&"a", &"b", &"c"]:
		defs[id] = {"name": "N " + str(id), "description": "D.", "kind": &"boards_cleared", "target": 1,
			"params": {}, "hidden": false, "hint": "", "icon": "", "category": &""}
	var t := AchKitTracker.new()
	add_node(t)
	t.configure(defs, Kinds.KINDS, {}, [], store if store != null else FakeStore.new(), EP, PP)
	return t


func _service(booted: bool = true) -> Node:
	var svc: Node = FakeService.new()
	svc.booted = booted
	add_node(svc)
	return svc


func test_earns_track_events_and_coalesce_one_stat_post() -> void:
	var svc := _service()
	var t := _tracker()
	var bridge := AchKitSnapserBridge.new(svc, t, STAT, EVENT)
	var synced: Array = []
	bridge.synced.connect(func(s: Dictionary) -> void: synced.append(s))
	t.earn(&"a")
	t.earn(&"b")
	t.debug_grant(&"c")
	check_eq(svc.tracked, [[EVENT, {"id": "a"}], [EVENT, {"id": "b"}], [EVENT, {"id": "c"}]],
		"one event per earn, at once")
	check_eq(svc.stats, [], "the stat waits for the end of the frame")
	await settle()
	check_eq(svc.stats, [[STAT, 3]], "one SET of the count for three earns in one frame")
	check_eq(synced, [{"ok": true, "error": "", "value": 3}], "synced summary")
	t.earn(&"a")
	await settle()
	check_eq(svc.stats.size(), 1, "a repeat earn sends nothing")


func test_offline_sends_no_stat() -> void:
	var svc := _service()
	svc.config.offline = true
	var t := _tracker()
	var bridge := AchKitSnapserBridge.new(svc, t, STAT, EVENT)
	var synced: Array = []
	bridge.synced.connect(func(s: Dictionary) -> void: synced.append(s))
	t.earn(&"a")
	await settle()
	check_eq(svc.stats, [], "no stat offline")
	check_eq(synced, [], "no synced offline")
	var r: Dictionary = await bridge.post_count()
	check_eq(r.error, "offline", "post_count says offline")
	var svc2 := _service()
	svc2.online = false
	var b2 := AchKitSnapserBridge.new(svc2, t, STAT, EVENT)
	check_eq((await b2.post_count()).error, "offline", "booted but not logged in")
	check_eq(svc2.stats, [], "nothing sent")


func test_boot_catch_up_only_when_something_is_earned() -> void:
	var store := FakeStore.new()
	store.data[EP + "a"] = true
	store.data[EP + "b"] = true
	var t := _tracker(store)
	var svc := _service(false)
	var bridge := AchKitSnapserBridge.new(svc, t, STAT, EVENT)
	await settle()
	check_eq(svc.stats, [], "nothing before boot")
	svc.finish_boot()
	await settle()
	check_eq(svc.stats, [[STAT, 2]], "caught up after boot")
	svc.finish_boot()
	await settle()
	check_eq(svc.stats.size(), 1, "one-shot")
	# Nothing earned: no request at boot.
	var svc0 := _service(false)
	var b0 := AchKitSnapserBridge.new(svc0, _tracker(), STAT, EVENT)
	svc0.finish_boot()
	await settle()
	check_eq(svc0.stats, [], "count 0: no request")
	# Already booted at construction: catch up at once.
	var svc1 := _service(true)
	var b1 := AchKitSnapserBridge.new(svc1, t, STAT, EVENT)
	await settle()
	check_eq(svc1.stats, [[STAT, 2]], "booted already: posts at once")
	check(bridge != null and b0 != null and b1 != null, "bridges kept alive")


func test_post_count_and_failure_summary() -> void:
	var svc := _service()
	var t := _tracker()
	var bridge := AchKitSnapserBridge.new(svc, t, STAT, EVENT)
	var r: Dictionary = await bridge.post_count()
	check_eq(r, {"ok": false, "error": "nothing_to_post", "value": 0}, "count 0 sends nothing")
	check_eq(svc.stats, [], "no request")
	svc.stat_result = {"ok": false, "error": "http_500"}
	var synced: Array = []
	bridge.synced.connect(func(s: Dictionary) -> void: synced.append(s))
	t.earn(&"a")
	await settle()
	check_eq(synced, [{"ok": false, "error": "http_500", "value": 1}], "a failed post is reported")
	svc.stat_result = {"ok": true, "error": ""}
	r = await bridge.post_count()
	check_eq(r, {"ok": true, "error": "", "value": 1}, "post now")
	check_eq(svc.stats, [[STAT, 1], [STAT, 1]], "two requests")
