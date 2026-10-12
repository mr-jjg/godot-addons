extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitAuth debug identities (v0.3.0): is_switched() and login_anon_as().

const PUT := HTTPClient.METHOD_PUT


func test_login_anon_as_persists_handle_and_clears_switched() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	var auth: SnapKitAuth = s.auth
	check(await auth.ensure_session(), "first login")
	var first_handle := auth.username()
	check(not auth.is_switched(), "anon session is not switched")
	check(auth.adopt_session({"user_id": "prov", "session_token": mock.issue_session("prov")}), "adopt provider")
	check(auth.is_switched(), "switched after adopt_session")
	var seen := []
	auth.session_changed.connect(func(u: String) -> void: seen.append(u))
	var r: Dictionary = await auth.login_anon_as("dbg-1")
	check(r.ok, "ok: " + str(r.error))
	check_eq(r.handle, "dbg-1", "handle")
	check_eq(r.user_id, mock.user_for_handle("dbg-1"), "the mock's user for the handle")
	check_eq(r.previous_handle, first_handle, "previous handle")
	check_eq(r.previous_user_id, "prov", "previous user")
	check_eq(auth.user_id, r.user_id, "session user")
	check_eq(auth.username(), "dbg-1", "handle is the device identity")
	check(not auth.is_switched(), "switched cleared")
	check(auth.has_session(), "session held")
	check_eq(seen, [r.user_id], "session_changed once")
	var file: Variant = SnapKitJson.parse(FileAccess.get_file_as_string(auth.session_path))
	check(file is Dictionary and file.get("username") == "dbg-1" and file.get("switched") == false, "persisted")
	var reloaded := SnapKitAuth.new()
	add_node(reloaded)
	reloaded.session_path = auth.session_path
	reloaded.setup(mock_config(), s.transport)
	check_eq([reloaded.username(), reloaded.user_id, reloaded.is_switched()], ["dbg-1", r.user_id, false],
		"a fresh process loads the debug identity")


func test_login_anon_as_heals_by_anon_relogin() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	var auth: SnapKitAuth = s.auth
	var r: Dictionary = await auth.login_anon_as("dbg-2")
	check(r.ok, "ok")
	auth._expires_at = 0
	mock.invalidate_sessions()
	check(await auth.ensure_session(), "lost session heals")
	check_eq(auth.user_id, r.user_id, "same debug user (anon re-login with the debug handle)")


func test_login_anon_as_failure_keeps_session() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock)
	var auth: SnapKitAuth = s.auth
	await auth.ensure_session()
	var uid := auth.user_id
	var handle := auth.username()
	var seen := []
	auth.session_changed.connect(func(u: String) -> void: seen.append(u))
	check_eq((await auth.login_anon_as("")).error, SnapKitTransport.ERR_INVALID_ARGUMENT, "empty handle")
	mock.respond(PUT, "/v1/auth/login/anon", 500, {})
	var r: Dictionary = await auth.login_anon_as("dbg-3")
	check_eq(r.ok, false, "failed")
	check_eq([r.previous_handle, r.previous_user_id, r.user_id], [handle, uid, uid], "result names the kept user")
	check_eq([auth.user_id, auth.username()], [uid, handle], "session and handle untouched")
	check_eq(seen, [], "no session_changed")
	check(auth.has_session(), "still signed in")


func test_login_anon_as_offline() -> void:
	var mock := SnapKitMockGateway.new()
	var s := mock_stack(mock, SnapKitConfig.from_dict({}))
	var r: Dictionary = await s.auth.login_anon_as("dbg-4")
	check_eq(r.error, SnapKitTransport.ERR_OFFLINE, "offline")
	check_eq(mock.requests.size(), 0, "no request")
