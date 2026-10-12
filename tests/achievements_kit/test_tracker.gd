extends "res://tests/achievements_kit/achkit_test_case.gd"

## AchKitTracker: modes, params, caps, signal order (after write and flush), the gate, reload,
## RENAMED migration, the deferred post-load pass, rows/summary, debug actions.

const Kinds := preload("res://tests/achievements_kit/fixtures/kinds.gd")
const FakeStore := preload("res://tests/achievements_kit/fakes/fake_store.gd")
const ProbeTracker := preload("res://tests/achievements_kit/fakes/probe_tracker.gd")
const EP := "t_ach_"
const PP := "t_achp_"


func _def(name: String, kind: StringName, target: int, over: Dictionary = {}) -> Dictionary:
	var d := {"name": name, "description": name + ".", "kind": kind, "target": target, "params": {},
		"hidden": false, "hint": "", "icon": "", "category": &""}
	d.merge(over, true)
	return d


func _defs() -> Dictionary:
	return {
		&"first_clear": _def("Clean Sweep", &"boards_cleared", 1),
		&"clear_3": _def("Janitor", &"boards_cleared", 3, {"category": &"boards"}),
		&"round_10": _def("Deep Run", &"round_reached", 10),
		&"round_5_quick": _def("Quick", &"round_reached", 5, {"params": {"source": "quick_play"},
			"category": &"boards"}),
		&"secret": _def("Look to the Stars", &"unlock_earned", 1, {"params": {"unlock": "outer_wilds"},
			"hidden": true, "hint": "Look up.", "category": &"secrets"}),
	}


func _make(store: Object, defs: Dictionary = {}, renamed: Dictionary = {}, retired: Array = []) -> ProbeTracker:
	var t: ProbeTracker = ProbeTracker.new()
	add_node(t)
	t.configure(_defs() if defs.is_empty() else defs, Kinds.KINDS, renamed, retired, store, EP, PP)
	return t


func test_count_mode() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	t.report(&"boards_cleared")
	check(t.is_earned(&"first_clear"), "first_clear earned at 1")
	check_eq(t.progress(&"clear_3"), 1, "clear_3 at 1")
	t.report(&"boards_cleared", 1)
	check_eq(t.progress(&"clear_3"), 2, "clear_3 at 2")
	check_eq(s.value(PP + "clear_3"), 2, "progress written")
	check(not t.is_earned(&"clear_3"), "not yet")
	t.report(&"boards_cleared")
	check(t.is_earned(&"clear_3"), "clear_3 earned at 3")
	check_eq(s.value(EP + "clear_3"), true, "bool written")
	check_eq(t.errors, PackedStringArray(), "no config errors")


func test_max_mode() -> void:
	var t := _make(FakeStore.new())
	t.report(&"round_reached", 4)
	check_eq(t.progress(&"round_10"), 4, "best 4")
	t.report(&"round_reached", 2)
	check_eq(t.progress(&"round_10"), 4, "a lower value keeps the best")
	t.report(&"round_reached", 7)
	check_eq(t.progress(&"round_10"), 7, "a higher value replaces it")
	t.report(&"round_reached", 10)
	check(t.is_earned(&"round_10"), "earned at the target")


func test_params_filter() -> void:
	var t := _make(FakeStore.new())
	t.report(&"round_reached", 6)
	check_eq(t.progress(&"round_10"), 6, "unparameterised moves")
	check_eq(t.progress(&"round_5_quick"), 0, "source-specific ignores a report without the source")
	t.report(&"round_reached", 6, {"source": "curated"})
	check(not t.is_earned(&"round_5_quick"), "other source ignored")
	t.report(&"round_reached", 6, {"source": "quick_play"})
	check(t.is_earned(&"round_5_quick"), "matching source earns")
	t.report(&"unlock_earned", 1, {"unlock": "gold"})
	check(not t.is_earned(&"secret"), "other unlock ignored")
	t.report(&"unlock_earned", 1, {"unlock": "outer_wilds"})
	check(t.is_earned(&"secret"), "matching unlock earns")


func test_progress_capped_at_target() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	t.report(&"boards_cleared", 99)
	check_eq(s.value(PP + "clear_3"), 3, "count capped")
	t.report(&"round_reached", 999)
	check_eq(s.value(PP + "round_10"), 10, "max capped")
	t.report(&"boards_cleared", -5)
	check_eq(t.progress(&"clear_3"), 3, "earned stays")
	var t2 := _make(FakeStore.new())
	t2.report(&"boards_cleared", -5)
	check_eq(t2.progress(&"clear_3"), 0, "never below 0")


func test_earned_once_after_write_and_flush() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	var seen: Array = []
	t.earned.connect(func(id: StringName) -> void:
		seen.append([id, s.data.get(EP + str(id)), s.data.get(PP + str(id)), t.is_earned(id)]))
	var changes := [0]
	t.changed.connect(func() -> void: changes[0] += 1)
	for i in 5:
		t.report(&"boards_cleared")
	check_eq(seen, [[&"first_clear", true, 1, true], [&"clear_3", true, 3, true]],
		"one earned each, after the bool and progress were flushed")
	check_eq(changes[0], 2, "changed once per earn")


func test_earned_achievement_writes_nothing_more() -> void:
	var s := FakeStore.new()
	var t := _make(s, {&"first_clear": _def("A", &"boards_cleared", 1)})
	t.report(&"boards_cleared")
	var writes: int = s.writes
	var progressed := [0]
	t.progressed.connect(func(_id: StringName, _v: int, _t: int) -> void: progressed[0] += 1)
	t.report(&"boards_cleared", 3)
	check_eq(s.writes, writes, "no writes after earned")
	check_eq(progressed[0], 0, "no progressed after earned")
	check(not t.earn(&"first_clear"), "earn() on an earned id is false")


func test_progressed_only_on_change() -> void:
	var t := _make(FakeStore.new())
	var seen: Array = []
	t.progressed.connect(func(id: StringName, v: int, tgt: int) -> void: seen.append([id, v, tgt]))
	t.report(&"round_reached", 4)
	t.report(&"round_reached", 3)
	t.report(&"round_reached", 4)
	check_eq(seen, [[&"round_10", 4, 10]], "one progressed")


func test_earn_and_gate() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	t.allow = false
	check(not t.earn(&"secret"), "gated earn refused")
	check(not t.is_earned(&"secret"), "not earned")
	check_eq(s.writes, 0, "nothing written")
	t.allow = true
	var seen: Array = []
	t.earned.connect(func(id: StringName) -> void: seen.append(id))
	check(t.earn(&"secret"), "earn ok")
	check(not t.earn(&"secret"), "second earn false")
	check_eq(seen, [&"secret"], "one earned")
	check(not t.earn(&"nope"), "unknown id false")
	check_eq(t.warnings.size(), 1, "unknown id warned")


func test_gate_blocks_progress() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	t.allow = false
	var signals := [0]
	t.progressed.connect(func(_i: StringName, _v: int, _t: int) -> void: signals[0] += 1)
	t.earned.connect(func(_i: StringName) -> void: signals[0] += 1)
	for i in 5:
		t.report(&"boards_cleared")
	t.report(&"round_reached", 50)
	check_eq(t.progress(&"clear_3"), 0, "no progress")
	check(not t.is_earned(&"first_clear"), "no earn")
	check_eq(s.writes, 0, "no writes")
	check_eq(signals[0], 0, "no signals")


func test_reload_if_owned() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	var counts := {"earned": 0, "changed": 0, "reloaded": 0}
	t.earned.connect(func(_i: StringName) -> void: counts.earned += 1)
	t.changed.connect(func() -> void: counts.changed += 1)
	t.reloaded.connect(func() -> void: counts.reloaded += 1)
	# A cloud pull lands in the store behind the tracker's back.
	s.data[EP + "clear_3"] = true
	s.data[PP + "clear_3"] = 3
	s.data[PP + "round_10"] = 6
	check(not t.reload_if_owned(PackedStringArray(["sax_other", "t_achx"])), "foreign keys: no reload")
	check(not t.is_earned(&"clear_3"), "not re-read yet")
	check(t.owns_key(EP + "x") and t.owns_key(PP + "x") and not t.owns_key("t_ac"), "owns_key")
	check(t.reload_if_owned(PackedStringArray(["sax_other", EP + "clear_3"])), "owned key: reload")
	check(t.is_earned(&"clear_3"), "earned after reload")
	check_eq(t.progress(&"round_10"), 6, "progress after reload")
	check_eq(counts, {"earned": 0, "changed": 1, "reloaded": 1}, "changed + reloaded, never earned")
	await settle()
	check_eq(counts.earned, 0, "still no earned after the post-load pass")


func test_renamed_migration() -> void:
	var s := FakeStore.new()
	s.data[EP + "old_clear"] = true
	s.data[PP + "old_clear"] = 1
	s.data[PP + "old_round"] = 7
	s.data[PP + "round_10"] = 3
	s.data[PP + "older"] = 9
	s.data[PP + "round_5_quick"] = 4
	var renamed := {&"old_clear": &"first_clear", &"old_round": &"round_10", &"older": &"older2",
		&"older2": &"round_5_quick"}
	var t := _make(s, {}, renamed)
	var earned_seen := [0]
	t.earned.connect(func(_i: StringName) -> void: earned_seen[0] += 1)
	check(not t.is_earned(&"first_clear"), "not migrated synchronously (deferred)")
	check_eq(s.writes, 0, "no writes inside configure")
	await settle()
	check(t.is_earned(&"first_clear"), "bool carried over (OR)")
	check(t.is_earned(&"old_clear"), "the old id resolves")
	check_eq(s.value(EP + "first_clear"), true, "new bool written")
	check_eq(t.progress(&"round_10"), 7, "progress is the max of old and new")
	check_eq(t.progress(&"round_5_quick"), 5, "a chain resolves; capped at the target")
	check_eq(s.value(EP + "old_clear"), true, "old keys left in place")
	check_eq(earned_seen[0], 0, "a migration is not a new earn")
	var writes: int = s.writes
	t.reload()
	await settle()
	check_eq(s.writes, writes, "idempotent: a second pass writes nothing")
	# The new id's larger progress wins.
	var s2 := FakeStore.new()
	s2.data[PP + "old_round"] = 2
	s2.data[PP + "round_10"] = 8
	var t2 := _make(s2, {}, {&"old_round": &"round_10"})
	await settle()
	check_eq(t2.progress(&"round_10"), 8, "larger new progress kept")
	check_eq(s2.writes, 0, "nothing to write")


func test_backfill_is_deferred_after_load() -> void:
	var t := _make(FakeStore.new())
	check_eq(t.backfills, 0, "not inside configure")
	await settle()
	check_eq(t.backfills, 1, "ran after configure")
	t.reload()
	t.reload()
	check_eq(t.backfills, 1, "not inside reload")
	await settle()
	check_eq(t.backfills, 2, "ran once after two reloads in one frame")


func test_rows_and_summary() -> void:
	var t := _make(FakeStore.new())
	t.report(&"boards_cleared")
	var rows := t.rows()
	check_eq(rows.map(func(r: Dictionary) -> StringName: return r.id),
		[&"first_clear", &"clear_3", &"round_10", &"round_5_quick", &"secret"], "display order")
	var secret: Dictionary = rows[4]
	check(secret.masked, "hidden + unearned is masked")
	check_eq(secret.name, "???", "masked name")
	check_eq(secret.description, "", "masked description")
	check_eq(secret.hint, "Look up.", "hint kept")
	check_eq(secret.kind, &"unlock_earned", "kind")
	check_eq(secret.kind_label, "Unlock earned", "kind label")
	var revealed: Dictionary = t.rows(true)[4]
	check(not revealed.masked and revealed.name == "Look to the Stars", "reveal_hidden")
	var clear3: Dictionary = rows[1]
	check_eq([clear3.earned, clear3.progress, clear3.target], [false, 1, 3], "clear_3 row")
	check(is_equal_approx(clear3.fraction, 1.0 / 3.0), "fraction")
	check_eq(clear3.category, &"boards", "category")
	check_eq(rows[0].fraction, 1.0, "earned fraction 1")
	t.earn(&"secret")
	check(not t.rows()[4].masked, "earned hidden is not masked")
	var sm := t.summary()
	check_eq(sm.earned, 2, "summary earned")
	check_eq(sm.total, 5, "summary total")
	check_eq(sm.categories.keys(), [&"", &"boards", &"secrets"], "categories in first-use order")
	check_eq(sm.categories[&"boards"], {"earned": 0, "total": 2}, "boards")
	check_eq(sm.categories[&""], {"earned": 1, "total": 2}, "uncategorised")
	check_eq(sm.categories[&"secrets"], {"earned": 1, "total": 1}, "secrets")


func test_earned_count_ignores_unknown_and_retired_keys() -> void:
	var s := FakeStore.new()
	s.data[EP + "gone"] = true
	s.data[EP + "never_existed"] = true
	s.data[EP + "first_clear"] = true
	var t := _make(s, {}, {}, [&"gone"])
	check_eq(t.earned_count(), 1, "only live ids")
	check_eq(t.total_count(), 5, "total")
	check(not t.is_earned(&"gone"), "retired not earned")


func test_unknown_kind_warns_once() -> void:
	var t := _make(FakeStore.new())
	t.report(&"nope")
	t.report(&"nope", 3)
	check_eq(t.warnings.size(), 1, "one warning per kind")
	t.report(&"nope2")
	check_eq(t.warnings.size(), 2, "another kind warns")


func test_debug_revoke() -> void:
	var s := FakeStore.new()
	var t := _make(s)
	t.begin_run()
	t.report(&"boards_cleared", 2)
	check_eq(t.run_earned(), [&"first_clear"] as Array[StringName], "run_earned")
	var revoked: Array = []
	t.revoked.connect(func(id: StringName) -> void: revoked.append([id, s.data.get(EP + str(id)),
		s.data.get(PP + str(id))]))
	t.debug_revoke(&"first_clear")
	check_eq(revoked, [[&"first_clear", false, 0]], "revoked after write (flushed)")
	check(not t.is_earned(&"first_clear"), "not earned")
	check_eq(t.run_earned(), [] as Array[StringName], "out of run_earned")
	t.debug_grant(&"secret")
	revoked.clear()
	var changes := [0]
	t.changed.connect(func() -> void: changes[0] += 1)
	t.debug_revoke_all()
	check_eq(revoked.map(func(r: Array) -> StringName: return r[0]), [&"clear_3", &"secret"],
		"revoke_all: every earned or progressed id")
	check_eq(changes[0], 1, "one changed")
	check_eq(t.earned_count(), 0, "nothing earned")
	check_eq(t.progress(&"clear_3"), 0, "progress reset")


func test_debug_grant_and_set_progress_bypass_the_gate() -> void:
	var t := _make(FakeStore.new())
	t.allow = false
	var seen: Array = []
	t.earned.connect(func(id: StringName) -> void: seen.append(id))
	t.debug_grant(&"round_10")
	check(t.is_earned(&"round_10"), "granted while gated")
	t.debug_set_progress(&"clear_3", 2)
	check_eq(t.progress(&"clear_3"), 2, "set")
	t.debug_set_progress(&"clear_3", 99)
	check(t.is_earned(&"clear_3"), "filling earns")
	check_eq(seen, [&"round_10", &"clear_3"], "earned emitted for debug earns")


func test_run_earned_and_begin_run() -> void:
	var t := _make(FakeStore.new())
	t.begin_run()
	t.report(&"boards_cleared", 3)
	check_eq(t.run_earned(), [&"first_clear", &"clear_3"] as Array[StringName], "this run")
	t.begin_run()
	check_eq(t.run_earned(), [] as Array[StringName], "reset")


func test_invalid_definitions_are_skipped() -> void:
	var defs := _defs()
	defs[&"bad_target"] = _def("Bad", &"boards_cleared", 0)
	defs[&"bad_kind"] = _def("Bad", &"nope", 1)
	var t := _make(FakeStore.new(), defs)
	check(not t.ids().has(&"bad_target") and not t.ids().has(&"bad_kind"), "invalid skipped")
	check_eq(t.total_count(), 5, "valid ones kept")
	check(t.errors.size() >= 2, "each problem logged: %s" % var_to_str(t.errors))
	check_eq(t.definition(&"bad_kind"), {}, "unknown definition is {}")
	check_eq(t.definition(&"clear_3").target, 3, "definition")
	check_eq(t.kind_of(&"round_10").mode, &"max", "kind_of")
	check_eq(t.earned_key(&"x"), EP + "x", "earned_key")
	check_eq(t.progress_key(&"x"), PP + "x", "progress_key")


func test_memory_and_save_service_stores() -> void:
	var mem := AchKitMemoryStore.new()
	var t := _make(mem)
	t.report(&"boards_cleared")
	check_eq(mem.data.get(EP + "first_clear"), true, "memory store holds the bool")
	check(mem.flush_count > 0, "flushed on earn")
	var svc := _FakeSaveService.new()
	var t2 := _make(AchKitSaveServiceStore.new(svc))
	t2.report(&"boards_cleared")
	check_eq(svc.vars.get(EP + "first_clear"), true, "SaveService store writes set_var_value")
	svc.vars[EP + "clear_3"] = true
	t2.reload()
	check(t2.is_earned(&"clear_3"), "reads get_var_value")


class _FakeSaveService extends RefCounted:
	var vars := {}

	func get_var_value(key: String, default_value: Variant) -> Variant:
		return vars.get(key, default_value)

	func set_var_value(key: String, value: Variant) -> void:
		vars[key] = value
