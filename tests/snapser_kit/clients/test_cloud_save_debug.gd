extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitCloudSave debug & inspection (v0.3.0): debug_snapshot, fetch_remote,
## force_push, force_take_remote, simulate_new_device, delete_remote, diff_rows.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")
const FakeStorageServer := preload("res://tests/snapser_kit/clients/fake_storage_server.gd")
const FakeSaveStore := preload("res://tests/snapser_kit/clients/fake_save_store.gd")
const FakeConfig := preload("res://tests/snapser_kit/clients/fake_config.gd")
const BLOB := "/v1/storage/owner/{owner}/{access}/json-blobs/{key}"
## Under the sandbox root (set by the runner), never the real user:// dir.
var STATE_DIR: String = SnapKitConfig.data_root.path_join("snapkit_test_cloud_save_debug")

var server: FakeStorageServer
var _n: int = 0


## A FakeSaveStore that counts export_prefix calls.
class CountingStore extends "res://tests/snapser_kit/clients/fake_save_store.gd":
	var exports: int = 0
	func export_prefix(prefix: String) -> Dictionary:
		exports += 1
		return super(prefix)


func before_each() -> void:
	server = FakeStorageServer.new()
	DirAccess.make_dir_recursive_absolute(STATE_DIR)
	_clean_state()


func after_each() -> void:
	_clean_state()


func _clean_state() -> void:
	var d := DirAccess.open(STATE_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)


func _device(store: Object, debug: bool = false) -> SnapKitCloudSave:
	var t: FakeTransport = add_node(FakeTransport.new())
	server.install(t)
	var cs: SnapKitCloudSave = add_node(SnapKitCloudSave.new())
	_n += 1
	cs.state_path = "%s/state_%d.json" % [STATE_DIR, _n]
	cs.debounce_s = 30.0
	cs.debug_tools_enabled = debug
	cs.setup(SnapKitStorage.new(t), store, FakeConfig.new())
	return cs


func _transport_of(cs: SnapKitCloudSave) -> FakeTransport:
	return cs.get("_storage").get("_transport")


func _remote_env(owner: String = "user-1") -> Dictionary:
	return SnapKitCloudSave.parse_envelope(server.value_of(owner, "save_v1"))


func _writes(cs: SnapKitCloudSave) -> int:
	var n := 0
	for c in _transport_of(cs).calls:
		if int(c.method) in [HTTPClient.METHOD_PUT, HTTPClient.METHOD_POST, HTTPClient.METHOD_DELETE]:
			n += 1
	return n


func _state_of(cs: SnapKitCloudSave) -> Dictionary:
	return (cs.get("_state") as Dictionary).duplicate(true)


# ---- read-only ----------------------------------------------------------------

func test_debug_snapshot_fields_and_no_mutation() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	store.set_value("set_volume", 0.5)
	var cs := _device(store)
	check((await cs.pull()).ok, "first sync")
	var state_before := _state_of(cs)
	var calls_before := _transport_of(cs).calls.size()
	var imports_before := store.import_calls
	var snap := cs.debug_snapshot()
	for k in ["enabled", "user_id", "device_id", "blob_key", "access", "has_synced", "cas", "version",
			"synced_hash", "synced_at", "local_changed_at", "dirty", "busy", "debounce_left_s", "persisted",
			"state_path", "prefixes", "sync_keys", "merge_policy", "local_hash", "local_matches_synced"]:
		check(snap.has(k), "snapshot has " + k)
	check_eq(snap.enabled, true, "enabled")
	check_eq(snap.user_id, "user-1", "bookkeeping owner")
	check_eq(snap.device_id, cs.device_id(), "device id")
	check_eq(snap.blob_key, "save_v1", "blob key")
	check_eq(snap.access, "private", "access")
	check_eq(snap.has_synced, true, "has_synced")
	check_eq(snap.version, 1, "version")
	check_eq(snap.cas, str(SnapKitJson.dig(server.blobs, ["user-1/private/save_v1", "cas"], "")), "cas = server's")
	check_eq(snap.synced_hash, SnapKitCloudSave.data_hash({"prog_a": 1}), "synced hash")
	check_eq(snap.dirty, false, "clean")
	check_eq(snap.busy, false, "idle")
	check_eq(snap.debounce_left_s, 0.0, "no push pending")
	check_eq(snap.persisted, true, "online config -> state file written")
	check_eq(snap.state_path, cs.state_path, "state path")
	check_eq(snap.prefixes, PackedStringArray(["prog_"]), "prefixes")
	check_eq(snap.local_matches_synced, true, "local == synced")
	check_eq(_state_of(cs), state_before, "bookkeeping untouched")
	check_eq(_transport_of(cs).calls.size(), calls_before, "no request")
	check_eq(store.import_calls, imports_before, "no import")

	store.set_value("prog_a", 2)
	snap = cs.debug_snapshot()
	check_eq(snap.dirty, true, "dirty after a local change")
	check_eq(snap.local_matches_synced, false, "local differs from synced")
	check(float(snap.debounce_left_s) > 0.0, "debounce pending")
	check_eq(snap.local_hash, SnapKitCloudSave.data_hash({"prog_a": 2}), "local hash")


func test_snapshot_without_local_skips_export() -> void:
	var store := CountingStore.new()
	store.set_value("prog_a", 1)
	var cs := _device(store)
	store.exports = 0
	var snap := cs.debug_snapshot(false)
	check_eq(store.exports, 0, "with_local=false never calls export_prefix")
	check(not snap.has("local_hash") and not snap.has("local_matches_synced"), "no local fields")
	cs.debug_snapshot(true)
	check(store.exports > 0, "with_local=true exports")


func test_fetch_remote_returns_envelope_and_changes_nothing() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	var cs := _device(store)
	await cs.pull()
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope(
		{"prog_a": 5, "prog_flag": true, "prog_pos": Vector2(1, 2)}, 7, "other", 123))
	var state_before := _state_of(cs)
	var applied := []
	cs.applied.connect(func(keys: PackedStringArray) -> void: applied.append(keys))
	var writes := _writes(cs)
	var r: Dictionary = await cs.fetch_remote()
	check(r.ok, "ok")
	check_eq(r.exists, true, "exists")
	check_eq(r.version, 7, "version")
	check_eq(r.updated_at, 123, "updated_at")
	check_eq(r.device_id, "other", "device_id")
	check_eq(r.data, {"prog_a": 5, "prog_flag": true, "prog_pos": Vector2(1, 2)}, "decoded, type-faithful")
	check_eq(typeof(r.data.prog_a), TYPE_INT, "int stays int")
	check_eq(r.hash, SnapKitCloudSave.data_hash(r.data), "hash of data")
	check_eq(r.cas, str(SnapKitJson.dig(server.blobs, ["user-1/private/save_v1", "cas"], "")), "cas")
	check_eq(store.export_prefix("prog_"), {"prog_a": 1}, "local untouched")
	check_eq(_state_of(cs), state_before, "bookkeeping untouched")
	check_eq(applied, [], "nothing applied")
	check_eq(_writes(cs), writes, "no write")

	var fresh := _device(FakeSaveStore.new())
	_transport_of(fresh).uid = "user-9"
	r = await fresh.fetch_remote()
	check(r.ok and not r.exists, "no blob: ok, exists=false")
	check_eq([r.data, r.hash, r.version], [{}, "", 0], "empty fields")


func test_debug_calls_refuse_by_default() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	var cs := _device(store)
	check_eq(cs.debug_tools_enabled, false, "gate off by default")
	for r in [await cs.force_push(), await cs.force_take_remote(), await cs.simulate_new_device(),
			await cs.delete_remote()]:
		check_eq(r.ok, false, "refused")
		check_eq(r.error, SnapKitCloudSave.ERR_DEBUG_DISABLED, "debug_disabled")
	check_eq(_transport_of(cs).calls.size(), 0, "no request")
	check_eq(store.export_prefix("prog_"), {"prog_a": 1}, "local untouched")
	var none := _device(null, true)
	check_eq((await none.force_push()).error, SnapKitTransport.ERR_DISABLED, "gate on, no store -> disabled")


# ---- force push ---------------------------------------------------------------

func test_force_push_local_wins_exactly() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_flag", false)
	store.set_value("prog_n", 3)
	var cs := _device(store, true)
	await cs.pull()
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope(
		{"prog_flag": true, "prog_n": 9, "prog_remote_only": 1}, 4, "other", 50))
	var r: Dictionary = await cs.force_push()
	check(r.ok, "ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_FORCED_LOCAL, "applied")
	check_eq(r.version, 5, "remote version + 1")
	check_eq(r.conflict, false, "no race")
	check_eq(r.replaced, PackedStringArray(["prog_flag", "prog_n", "prog_remote_only"]), "replaced keys")
	var env := _remote_env()
	check_eq(env.data, {"prog_flag": false, "prog_n": 3}, "remote == local exactly (false stays false, remote-only gone)")
	check_eq(env.version, 5, "stored version")
	check_eq(env.device_id, cs.device_id(), "stamped with this device")
	check_eq(store.export_prefix("prog_"), {"prog_flag": false, "prog_n": 3}, "local untouched")
	var p: Dictionary = await cs.push()
	check(p.ok and bool(p.get("skipped", false)), "next push is skipped")
	var pulled: Dictionary = await cs.pull()
	check_eq(pulled.applied, SnapKitCloudSave.APPLIED_NONE, "next pull is none")


func test_force_push_retries_a_cas_race() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_n", 1)
	var cs := _device(store, true)
	await cs.pull()
	var raced := [false]
	_transport_of(cs).route(HTTPClient.METHOD_PUT, BLOB, func(req: Dictionary) -> Dictionary:
		if not raced[0]:
			raced[0] = true
			# Another device writes between our read and our write.
			server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_n": 8}, 10, "other", 60))
		return server._replace_blob(req))
	var r: Dictionary = await cs.force_push()
	check(r.ok, "ok after retry")
	check_eq(r.conflict, true, "race reported")
	check_eq(r.version, 11, "on top of the racer's version")
	check_eq(_remote_env().data, {"prog_n": 1}, "local still wins")


func test_force_push_creates_a_missing_blob() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_n", 2)
	var cs := _device(store, true)
	var r: Dictionary = await cs.force_push()
	check(r.ok, "ok")
	check_eq(r.version, 1, "first version")
	check_eq(_remote_env().data, {"prog_n": 2}, "created")


# ---- force take remote ----------------------------------------------------------

func test_force_take_remote_remote_wins_exactly() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_flag", true)
	store.set_value("prog_n", 9)
	store.set_value("prog_local_only", 1)
	store.set_value("set_volume", 0.5)
	var cs := _device(store, true)
	await cs.pull()
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope(
		{"prog_flag": false, "prog_n": 3, "prog_new": "x"}, 6, "other", 70))
	var applied := []
	cs.applied.connect(func(keys: PackedStringArray) -> void: applied.append(keys))
	var r: Dictionary = await cs.force_take_remote()
	check(r.ok, "ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_FORCED_REMOTE, "applied")
	check_eq(r.exact, true, "store supports replace")
	check_eq(store.export_prefix("prog_"), {"prog_flag": false, "prog_n": 3, "prog_new": "x"},
		"local == remote exactly (true became false, local-only gone)")
	check_eq(store.get_value("set_volume"), 0.5, "unsynced keys untouched")
	check_eq(r.dropped, PackedStringArray(["prog_local_only"]), "dropped")
	check_eq(r.keys, PackedStringArray(["prog_flag", "prog_local_only", "prog_n", "prog_new"]), "changed keys")
	check_eq(applied, [r.keys], "applied emitted once with the keys")
	check(not cs.is_dirty(), "import echo is not a local change")
	var writes := _writes(cs)
	var pulled: Dictionary = await cs.pull()
	check_eq(pulled.applied, SnapKitCloudSave.APPLIED_NONE, "next pull is none")
	check_eq(_writes(cs), writes, "and writes nothing")


func test_force_take_remote_without_blob_changes_nothing() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	var cs := _device(store, true)
	var before := _state_of(cs)
	var applied := []
	cs.applied.connect(func(keys: PackedStringArray) -> void: applied.append(keys))
	var r: Dictionary = await cs.force_take_remote()
	check_eq(r.ok, false, "not ok")
	check_eq(r.error, SnapKitErrors.NOT_FOUND, "not_found")
	check_eq(store.export_prefix("prog_"), {"prog_a": 1}, "local untouched")
	check_eq(applied, [], "nothing applied")
	var after := _state_of(cs)
	check_eq([after.get("has_synced", false), after.get("cas", ""), after.get("version", 0)],
		[before.get("has_synced", false), before.get("cas", ""), before.get("version", 0)], "no sync recorded")


func test_force_take_remote_two_arg_store_is_not_exact() -> void:
	var store := TwoArgStore.new()
	store.data = {"prog_a": 1, "prog_local_only": 2}
	var cs := _device(store, true)
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_a": 5}, 1, "other", 1))
	var r: Dictionary = await cs.force_take_remote()
	check(r.ok, "ok")
	check_eq(r.exact, false, "no replace arg -> not exact")
	check_eq(store.data, {"prog_a": 5, "prog_local_only": 2}, "local-only key survives")


class TwoArgStore extends RefCounted:
	var data := {}
	func export_prefix(p: String) -> Dictionary:
		var o := {}
		for k in data:
			if str(k).begins_with(p):
				o[k] = data[k]
		return o
	func import_prefix(_p: String, d: Dictionary) -> void:
		data.merge(d, true)


# ---- simulate new device / delete -----------------------------------------------

func test_simulate_new_device_restores_remote() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_flag", true)
	store.set_value("prog_n", 4)
	store.set_value("set_volume", 0.5)
	var cs := _device(store, true)
	await cs.pull()
	store.set_value("prog_unpushed", 1)
	var d0 := cs.device_id()
	var applied := []
	cs.applied.connect(func(keys: PackedStringArray) -> void: applied.append(keys))
	var r: Dictionary = await cs.simulate_new_device()
	check(r.ok, "ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_REMOTE, "first sync took the remote")
	check_eq(r.wiped, PackedStringArray(["prog_flag", "prog_n", "prog_unpushed"]), "every synced key wiped")
	check_eq(r.exact, true, "exact")
	check_eq(r.previous_device_id, d0, "previous device id")
	check(cs.device_id() != d0 and cs.device_id() != "", "new device id")
	check_eq(store.export_prefix("prog_"), {"prog_flag": true, "prog_n": 4}, "remote data back locally")
	check_eq(store.get_value("set_volume"), 0.5, "unsynced keys untouched")
	check_eq(applied.size(), 2, "applied for the wipe, then for the restore")
	check(not cs.is_dirty(), "clean")
	check_eq(cs.debug_snapshot().has_synced, true, "synced as the new device")


func test_delete_remote_resets_bookkeeping() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	var cs := _device(store, true)
	_transport_of(cs).route(HTTPClient.METHOD_DELETE, BLOB, func(req: Dictionary) -> Dictionary:
		var id := "%s/%s/%s" % [req.params.owner, req.params.access, req.params.key]
		if not server.blobs.has(id):
			return {"status": 404, "json": {"api_error_code": 5000}}
		server.blobs.erase(id)
		return {"status": 200, "json": {}})
	await cs.pull()
	var r: Dictionary = await cs.delete_remote()
	check(r.ok and r.existed, "deleted")
	check_eq(server.value_of("user-1", "save_v1"), null, "blob gone")
	check_eq(cs.debug_snapshot().has_synced, false, "next sync is a first sync")
	r = await cs.delete_remote()
	check(r.ok and not r.existed, "already gone counts as ok")
	var pulled: Dictionary = await cs.pull()
	check_eq(pulled.applied, SnapKitCloudSave.APPLIED_LOCAL, "first sync re-uploads local")


# ---- diff_rows ------------------------------------------------------------------

func test_diff_rows_statuses_and_columns() -> void:
	var local := {"a_same": 1, "b_flag": true, "c_n": 9, "d_list": [1, 2], "e_local_only": "x", "g_flag": false,
		"h_name": "guest"}
	var remote := {"a_same": 1, "b_flag": false, "c_n": 7, "d_list": [2, 3], "f_remote_only": 5, "g_flag": true,
		"h_name": "acct"}
	var policies := {"c_*": "max"}
	var local_copy := local.duplicate(true)
	var remote_copy := remote.duplicate(true)
	var rows := SnapKitCloudSave.diff_rows(local, remote, policies, false)
	var keys := rows.map(func(r: Dictionary) -> String: return r.key)
	check_eq(keys, ["a_same", "b_flag", "c_n", "d_list", "e_local_only", "f_remote_only", "g_flag", "h_name"],
		"one row per key, sorted")
	var by := {}
	for r in rows:
		by[r.key] = r
	check_eq(by.a_same.status, "same", "same")
	check_eq(by.b_flag.status, "differs", "differs")
	check_eq(by.e_local_only.status, "local_only", "local_only")
	check_eq(by.f_remote_only.status, "remote_only", "remote_only")
	check_eq(by.c_n.policy, "max", "policy column")
	check_eq(by.a_same.policy, "", "no policy")
	check_eq([by.f_remote_only.local, by.f_remote_only.in_local], [null, false], "absent local is null")
	check_eq([by.e_local_only.remote, by.e_local_only.in_remote], [null, false], "absent remote is null")
	# Explicit expectations for the interesting cells.
	check_eq([by.c_n.merge, by.c_n.take, by.c_n.account], [9, 9, 7], "max int: merge/take keep 9, account takes 7")
	check_eq([by.b_flag.merge, by.b_flag.take, by.b_flag.account], [true, true, true], "local true OR-ed everywhere")
	check_eq([by.g_flag.merge, by.g_flag.take, by.g_flag.account], [true, true, true], "remote true OR-ed everywhere")
	check_eq([by.d_list.merge, by.d_list.take, by.d_list.account], [[1, 2, 3], [2, 3], [2, 3]], "arrays")
	check_eq([by.h_name.merge, by.h_name.take, by.h_name.account], ["guest", "acct", "acct"],
		"scalar: local newer in merge, remote on take and account")
	check_eq([by.e_local_only.in_merge, by.e_local_only.in_take, by.e_local_only.in_account], [true, false, false],
		"guest-only scalar: kept by merge only")
	check_eq(local, local_copy, "local untouched")
	check_eq(remote, remote_copy, "remote untouched")
	# Every column equals the functions the pull paths use, for both recencies.
	for newer in [true, false]:
		var merged := SnapKitCloudSave.apply_policies(SnapKitCloudSave.default_merge(local, remote, newer),
			local, remote, policies)
		var taken := SnapKitCloudSave.apply_policies(remote, local, remote, policies)
		var account := SnapKitCloudSave.account_wins(local, remote, policies)
		for r in SnapKitCloudSave.diff_rows(local, remote, policies, newer):
			var k: String = r.key
			check(r.in_merge == merged.has(k) and _same(r.merge, merged.get(k)), "merge column %s (newer=%s)" % [k, newer])
			check(r.in_take == taken.has(k) and _same(r.take, taken.get(k)), "take column %s" % k)
			check(r.in_account == account.has(k) and _same(r.account, account.get(k)), "account column %s" % k)
			check(r.in_local == local.has(k) and _same(r.local, local.get(k)), "local column %s" % k)
			check(r.in_remote == remote.has(k) and _same(r.remote, remote.get(k)), "remote column %s" % k)


static func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b
