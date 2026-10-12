extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitService debug & inspection (v0.3.0) through the mock gateway: the
## gates, fetch_stats, debug_snapshot, the cloud_save_* debug wrappers, and the
## debug anonymous identities (debug_login_anon / debug_return_to_primary).

const FakeStorageServer := preload("res://tests/snapser_kit/clients/fake_storage_server.gd")
const FakeSaveStore := preload("res://tests/snapser_kit/clients/fake_save_store.gd")
const PUT := HTTPClient.METHOD_PUT
const GET := HTTPClient.METHOD_GET
const CLOUD := {"blob_key": "save_v1", "sync_prefixes": ["prog_"]}

var server: FakeStorageServer


func before_each() -> void:
	server = FakeStorageServer.new()


## An online (mock) service with cloud save on `store`; every kit file in a
## fresh temp path. Not booted yet.
func _svc(mock: SnapKitMockGateway, store: Object, debug: bool = true) -> SnapKitService:
	server.install(mock)
	var svc := SnapKitService.new()
	svc.save_store = store
	svc.debug_tools_enabled = debug
	add_node(svc)
	svc.start_with_config(mock_config({"cloud_save": CLOUD}))
	svc.auth.session_path = temp_path("dbg_session_%d.json" % randi())
	svc.cloud_save.state_path = temp_path("dbg_state_%d.json" % randi())
	svc.cloud_save.call("_load_state")
	svc.debug_identities_path = temp_path("dbg_ids_%d.json" % randi())
	svc.use_mock_gateway(track_mock(mock))
	svc.transport.backoff_scale = 0.0
	return svc


## Register an anonymous user on the mock up front (an existing account) and
## return its user id.
func _existing_user(mock: SnapKitMockGateway, handle: String) -> String:
	mock.handle(PUT, "/v1/auth/login/anon", PackedStringArray(),
		JSON.stringify({"username": handle, "create_user": true}))
	return mock.user_for_handle(handle)


func _store(values: Dictionary) -> FakeSaveStore:
	var s := FakeSaveStore.new()
	for k in values:
		s.set_value(k, values[k])
	return s


# ---- gates ----------------------------------------------------------------------

func test_offline_answers_offline_for_every_new_call() -> void:
	var svc := SnapKitService.new()
	svc.save_store = FakeSaveStore.new()
	add_node(svc)
	svc.start_with_config(SnapKitConfig.from_dict({"game_id": "g", "cloud_save": CLOUD}))
	await svc.boot_finished
	var t0 := Time.get_ticks_msec()
	for r in [await svc.fetch_stats(), await svc.cloud_save_fetch_remote(), await svc.cloud_save_force_push(),
			await svc.cloud_save_force_take_remote(), await svc.cloud_save_simulate_new_device(),
			await svc.cloud_save_delete_remote(), await svc.debug_login_anon(),
			await svc.debug_return_to_primary()]:
		check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "offline")
	check(Time.get_ticks_msec() - t0 < 100, "immediately")
	check_eq((await svc.fetch_stats()).stats, {}, "stats {} when gated")
	var snap := svc.debug_snapshot()
	check_eq([snap.online, snap.booted, snap.user_id], [false, true, ""], "snapshot works offline")
	check(str(snap.offline_reason) != "", "offline reason")


func test_debug_disabled_refuses_every_mutating_call() -> void:
	var mock := SnapKitMockGateway.new()
	var store := _store({"prog_a": 1})
	var svc := _svc(mock, store, false)
	await svc.boot_finished
	check_eq(svc.cloud_save.debug_tools_enabled, false, "propagated to cloud_save")
	var uid := svc.user_id()
	var before := mock.requests.size()
	for r in [await svc.cloud_save_force_push(), await svc.cloud_save_force_take_remote(),
			await svc.cloud_save_simulate_new_device(), await svc.cloud_save_delete_remote(),
			await svc.debug_login_anon(), await svc.debug_login_anon("x", "pull"),
			await svc.debug_return_to_primary()]:
		check_eq(r.ok, false, "refused")
		check_eq(r.error, SnapKitService.ERR_DEBUG_DISABLED, "debug_disabled")
	check_eq(mock.requests.size(), before, "no request made")
	check_eq(svc.user_id(), uid, "same user")
	check_eq(svc.debug_identities(), [] as Array[Dictionary], "no identity recorded")
	check((await svc.cloud_save_fetch_remote()).ok, "read-only fetch still allowed")
	svc.debug_tools_enabled = true
	check_eq(svc.cloud_save.debug_tools_enabled, true, "setter propagates after start")
	check((await svc.cloud_save_force_push()).ok, "allowed once on")


func test_debug_login_anon_rejects_unknown_mode() -> void:
	var svc := _svc(SnapKitMockGateway.new(), FakeSaveStore.new())
	await svc.boot_finished
	check_eq((await svc.debug_login_anon("", "bogus")).error, SnapKitTransport.ERR_INVALID_ARGUMENT, "bad mode")


# ---- inspection -------------------------------------------------------------------

func test_fetch_stats_parses_get_route() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/statistics/settings/user-stats/{uid}", 200, {"user_statistics": [
		{"key": "achievements_earned", "user_id": "u", "value": "5"},
		{"key": "best_score", "user_id": "u", "value": "9007199254740993"}]})
	var svc := _svc(mock, FakeSaveStore.new())
	await svc.boot_finished
	var r: Dictionary = await svc.fetch_stats()
	check(r.ok, "ok: " + str(r.error))
	check_eq(r.stats, {"achievements_earned": 5, "best_score": 9007199254740993}, "ints, int64 kept")
	var req: Dictionary = mock.requests_to("/v1/statistics/")[-1]
	check_eq(req.path, "/v1/statistics/settings/user-stats/%s" % svc.user_id(), "GET for the session user")


func test_debug_snapshot_shape() -> void:
	var svc := _svc(SnapKitMockGateway.new(), _store({"prog_a": 1}))
	await svc.boot_finished
	var snap := svc.debug_snapshot()
	for k in ["online", "booted", "offline_reason", "user_id", "handle", "linked", "switched", "debug_tools",
			"primary_handle", "cloud_save"]:
		check(snap.has(k), "snapshot has " + k)
	check_eq([snap.online, snap.booted, snap.switched, snap.debug_tools], [true, true, false, true], "flags")
	check_eq(snap.user_id, svc.user_id(), "user id")
	check_eq(snap.handle, svc.auth.username(), "handle")
	check_eq(snap.primary_handle, "", "no primary before a debug login")
	check_eq(snap.cloud_save.user_id, svc.user_id(), "cloud-save bookkeeping owned by the session user")
	check_eq(snap.cloud_save.has_synced, true, "boot synced")
	check(snap.cloud_save.has("local_hash"), "with_local by default")
	check(not svc.debug_snapshot(false).cloud_save.has("local_hash"), "with_local=false passed through")


func test_cloud_save_wrappers_reach_cloud_save() -> void:
	var store := _store({"prog_a": 1})
	var svc := _svc(SnapKitMockGateway.new(), store)
	await svc.boot_finished
	var uid := svc.user_id()
	var applied := []
	svc.cloud_save_applied.connect(func(keys: PackedStringArray) -> void: applied.append(keys))
	var r: Dictionary = await svc.cloud_save_fetch_remote()
	check(r.ok and r.exists, "fetch_remote")
	check_eq(r.data, {"prog_a": 1}, "remote data")
	server.put_raw(uid, "save_v1", SnapKitCloudSave.make_envelope({"prog_a": 0, "prog_b": 2}, 9, "x", 1))
	r = await svc.cloud_save_force_take_remote()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_FORCED_REMOTE, "force_take_remote")
	check_eq(store.export_prefix("prog_"), {"prog_a": 0, "prog_b": 2}, "remote wins")
	check_eq(applied.size(), 1, "cloud_save_applied re-emitted")
	store.set_value("prog_b", 1)
	r = await svc.cloud_save_force_push()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_FORCED_LOCAL, "force_push")
	check_eq(SnapKitCloudSave.parse_envelope(server.value_of(uid, "save_v1")).data, {"prog_a": 0, "prog_b": 1},
		"local wins")
	r = await svc.cloud_save_simulate_new_device()
	check(r.ok, "simulate_new_device")
	check_eq(store.export_prefix("prog_"), {"prog_a": 0, "prog_b": 1}, "restored")


# ---- debug identities ---------------------------------------------------------------

func test_debug_login_anon_mints_and_records_primary() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _svc(mock, _store({"prog_a": 1}))
	await svc.boot_finished
	var primary_uid := svc.user_id()
	var primary_handle := svc.auth.username()
	var sessions := []
	svc.session_ready.connect(func(u: String) -> void: sessions.append(u))
	var r: Dictionary = await svc.debug_login_anon()
	check(r.ok, "ok: " + str(r.error))
	check(str(r.handle).begins_with("kit_test-") and r.handle != primary_handle, "fresh handle, game prefix")
	check(r.user_id != primary_uid and r.user_id != "", "a new user")
	check_eq(r.user_id, mock.user_for_handle(r.handle), "the mock's user for that handle")
	check_eq(r.previous_user_id, primary_uid, "previous user")
	check_eq(svc.user_id(), r.user_id, "service now on the new user")
	check_eq(svc.auth.username(), r.handle, "handle is this device's identity")
	check_eq(sessions, [r.user_id], "session_ready")
	check(not r.has("warning"), "no warning from an anon session")
	check_eq(r.cloud_save.applied, SnapKitCloudSave.APPLIED_ACCOUNT, "default mode: account")
	var ids := svc.debug_identities()
	check_eq(ids.size(), 2, "primary + new")
	check_eq([ids[0].handle, ids[0].user_id, ids[0].primary, ids[0].current],
		[primary_handle, primary_uid, true, false], "primary row first")
	check_eq([ids[1].handle, ids[1].user_id, ids[1].primary, ids[1].current],
		[r.handle, r.user_id, false, true], "current row")
	check(int(ids[0].created_at) > 0, "created_at")
	check_eq(svc.debug_snapshot().primary_handle, primary_handle, "primary in the snapshot")
	var file: Variant = SnapKitJson.parse(FileAccess.get_file_as_string(svc.debug_identities_path))
	check(file is Dictionary and file.get("primary") == primary_handle, "primary persisted (config online)")
	var session: Variant = SnapKitJson.parse(FileAccess.get_file_as_string(svc.auth.session_path))
	check(session is Dictionary and session.get("username") == r.handle, "session file holds the debug handle")


func test_mode_account_keeps_guest_bools_and_takes_account_ints() -> void:
	var mock := SnapKitMockGateway.new()
	var acct := _existing_user(mock, "acct-handle")
	server.put_raw(acct, "save_v1", SnapKitCloudSave.make_envelope(
		{"prog_ach": false, "prog_acct_flag": true, "prog_wins": 7}, 3, "acct-dev", 100))
	var store := _store({"prog_ach": true, "prog_wins": 40, "prog_guest_only": 5})
	var svc := _svc(mock, store)
	await svc.boot_finished
	var r: Dictionary = await svc.debug_login_anon("acct-handle", "account")
	check(r.ok, "ok: " + str(r.error))
	check_eq(svc.user_id(), acct, "on the account")
	check_eq(r.cloud_save.applied, SnapKitCloudSave.APPLIED_ACCOUNT, "account rule")
	check_eq(store.export_prefix("prog_"), {"prog_ach": true, "prog_acct_flag": true, "prog_wins": 7},
		"guest true kept (OR), account int taken, guest-only int dropped")
	check_eq(r.cloud_save.dropped, PackedStringArray(["prog_guest_only"]), "dropped")


func test_mode_pull_merges() -> void:
	var mock := SnapKitMockGateway.new()
	var acct := _existing_user(mock, "acct-handle")
	server.put_raw(acct, "save_v1", SnapKitCloudSave.make_envelope(
		{"prog_ach": false, "prog_acct_flag": true, "prog_wins": 7}, 3, "acct-dev", 100))
	var store := _store({"prog_ach": true, "prog_wins": 40, "prog_guest_only": 5})
	var svc := _svc(mock, store)
	await svc.boot_finished
	var r: Dictionary = await svc.debug_login_anon("acct-handle", "pull")
	check(r.ok, "ok")
	check_eq(r.cloud_save.applied, SnapKitCloudSave.APPLIED_MERGED, "first sync with local progress merges")
	check_eq(store.export_prefix("prog_"),
		{"prog_ach": true, "prog_acct_flag": true, "prog_wins": 40, "prog_guest_only": 5}, "merged, nothing lost")


func test_mode_none_swaps_session_only() -> void:
	var mock := SnapKitMockGateway.new()
	var store := _store({"prog_a": 1})
	var svc := _svc(mock, store)
	await svc.boot_finished
	var blob_requests := mock.requests_to("/v1/storage/").size()
	var r: Dictionary = await svc.debug_login_anon("", "none")
	check(r.ok and not r.has("cloud_save"), "no cloud-save step")
	check_eq(mock.requests_to("/v1/storage/").size(), blob_requests, "no storage request")
	check_eq(svc.cloud_save.state_user_id(), r.user_id, "bookkeeping rebound to the new user")
	check_eq(store.export_prefix("prog_"), {"prog_a": 1}, "local untouched")


func test_return_to_primary_restores_primary_user() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _svc(mock, _store({"prog_a": 1}))
	await svc.boot_finished
	check_eq((await svc.debug_return_to_primary()).error, SnapKitService.ERR_NO_PRIMARY, "nothing recorded yet")
	var primary_uid := svc.user_id()
	var dbg: Dictionary = await svc.debug_login_anon("", "none")
	check(svc.user_id() != primary_uid, "switched away")
	var r: Dictionary = await svc.debug_return_to_primary("account")
	check(r.ok, "ok")
	check_eq(svc.user_id(), primary_uid, "primary user back")
	check_eq(r.previous_user_id, dbg.user_id, "came from the debug user")
	var ids := svc.debug_identities()
	check_eq(ids.size(), 2, "still two identities")
	check(ids[0].primary and ids[0].current, "primary is current again")
	var again: Dictionary = await svc.debug_login_anon(dbg.handle, "none")
	check_eq(again.user_id, dbg.user_id, "a recorded handle is the same user again")
	check_eq(svc.debug_identities().size(), 2, "no duplicate row")


func test_debug_identity_heals_by_anon_relogin() -> void:
	var mock := SnapKitMockGateway.new()
	mock.respond(GET, "/v1/statistics/settings/user-stats/{uid}", 200, {"user_statistics": []})
	var svc := _svc(mock, FakeSaveStore.new())
	await svc.boot_finished
	var r: Dictionary = await svc.debug_login_anon("dbg-handle", "none")
	var uid: String = r.user_id
	check(not svc.auth.is_switched(), "a debug identity is not a switched session")
	var logins := mock.login_count
	mock.invalidate_sessions()
	var stats: Dictionary = await svc.fetch_stats()
	check(stats.ok, "401 healed: " + str(stats.error))
	check_eq(mock.login_count, logins + 1, "by one anon re-login")
	check_eq(svc.user_id(), uid, "as the debug user, not the primary")


func test_from_a_switched_provider_session_warns() -> void:
	var mock := SnapKitMockGateway.new()
	var svc := _svc(mock, FakeSaveStore.new())
	await svc.boot_finished
	var anon_handle := svc.auth.username()
	check(svc.auth.adopt_session({"user_id": "apple-user", "session_token": mock.issue_session("apple-user")}),
		"adopted a provider account")
	check(svc.auth.is_switched(), "switched")
	var r: Dictionary = await svc.debug_login_anon("", "none")
	check(r.ok, "proceeds")
	check_eq(r.get("warning", ""), SnapKitService.WARN_LEFT_PROVIDER, "warning")
	check_eq(r.previous_user_id, "apple-user", "left the provider account")
	check(not svc.auth.is_switched(), "no longer switched")
	var ids := svc.debug_identities()
	check_eq([ids[0].handle, ids[0].user_id, ids[0].primary], [anon_handle, "", true],
		"primary is the anon handle; its user is unknown while switched")


## Default kit paths (no per-test redirection): the identities file lands
## under SnapKitConfig.data_root (the sandbox), and nothing under user:// changes.
func test_nothing_written_outside_the_sandbox() -> void:
	await tree.process_frame
	var before := _user_files()
	var mock := SnapKitMockGateway.new()
	server.install(mock)
	var svc := SnapKitService.new()   # DEFAULT paths on purpose
	svc.save_store = _store({"prog_a": 1})
	svc.debug_tools_enabled = true
	add_node(svc)
	svc.start_with_config(mock_config({"cloud_save": CLOUD}))
	svc.use_mock_gateway(track_mock(mock))
	svc.transport.backoff_scale = 0.0
	check(await svc.wait_until_ready(), "online via mock")
	check((await svc.debug_login_anon()).ok, "debug login")
	check((await svc.debug_return_to_primary()).ok, "return")
	check((await svc.cloud_save_force_push()).ok, "force push")
	await tree.process_frame
	check(svc.debug_identities_path.begins_with(SnapKitConfig.data_root), "identities under data_root")
	check(FileAccess.file_exists(svc.debug_identities_path), "identities written (config online)")
	check_eq(_user_files(), before, "nothing created or modified under user://")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(svc.debug_identities_path))


func _user_files(dir := "user://") -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		var p := dir.path_join(f)
		out[p] = [FileAccess.get_file_as_bytes(p).size(), FileAccess.get_modified_time(p)]
	for sub in d.get_directories():
		out.merge(_user_files(dir.path_join(sub)))
	return out
