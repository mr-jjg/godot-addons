extends "res://tests/achievements_kit/achkit_test_case.gd"

## The Achievements dock's headless service (addons/achievements_kit/editor/). Every test gets a
## fresh temp dir under OS.get_cache_dir() (never user://) holding a config, the fixture kinds
## file and the fixture definitions file, and removes it afterwards.

const ServiceT := preload("res://addons/achievements_kit/editor/achievements_editor_service.gd")
const DockT := preload("res://addons/achievements_kit/editor/dock.gd")
const FIXTURE_DEFS := "res://tests/achievements_kit/fixtures/achievements.gd"
const FIXTURE_KINDS := "res://tests/achievements_kit/fixtures/kinds.gd"
const PREFIXES := {"earned": "test_ach_", "progress": "test_achp_"}

var _dir := ""
var _changed := 0


func before_each() -> void:
	_dir = OS.get_cache_dir().path_join("achkit_editor_test_%d" % OS.get_process_id())
	_rm_rf(_dir)
	DirAccess.make_dir_recursive_absolute(_dir)
	_write(_defs_path(), FileAccess.get_file_as_string(FIXTURE_DEFS))
	_write(_dir.path_join("kinds.gd"), FileAccess.get_file_as_string(FIXTURE_KINDS))
	_write(_config_path(), JSON.stringify({
		"definitions": _defs_path(),
		"kinds": _dir.path_join("kinds.gd"),
		"earned_key_prefix": PREFIXES.earned,
		"progress_key_prefix": PREFIXES.progress,
		"icon_dir": "",
	}))
	_changed = 0


func after_each() -> void:
	_rm_rf(_dir)


# ---- tests ------------------------------------------------------------------------


func test_unconfigured() -> void:
	var svc := _service(false)
	svc.config_path = _dir.path_join("missing.config.json")
	var r: Dictionary = svc.reload()
	check(not r.ok, "reload fails when unconfigured")
	check(not svc.is_configured(), "not configured")
	check(svc.problems().is_empty(), "no problems when unconfigured")
	check(svc.ids().is_empty(), "empty model")
	check(not svc.save().ok, "save refused")
	check_eq(svc.config.get("definitions"), "", "defaults applied")


func test_load() -> void:
	var svc := _service()
	check(svc.is_configured(), "configured")
	check_eq(svc.ids(), _ids([&"first_clear", &"round_10_quick", &"secret"]), "ids in file order")
	check(svc.file_exists(), "file exists")
	check(svc.is_canonical_on_disk(), "fixture is canonical")
	check(not svc.schema_newer(), "schema not newer")
	check_eq(svc.load_error(), "", "no load error")
	check(svc.problems().is_empty(), "fixture has no problems: %s" % svc.problems())
	check(svc.is_shipped(&"secret"), "on-disk id is shipped")
	check(not svc.is_dirty(), "clean after load")
	check_eq(svc.model.renamed, {&"old_clear": &"first_clear"}, "RENAMED loaded")
	check_eq(svc.model.retired, _ids([&"gone"]), "RETIRED loaded")
	check_eq(svc.categories(), _ids([&"runs", &"secrets"]), "categories, first-use order, no empty")
	check_eq(svc.kind_names().size(), 4, "kinds loaded")
	check_eq(svc.kind_caption(&"round_reached"), "Round reached in one run (max)", "kind caption")
	check_eq(svc.kind_caption(&"nope"), "<unknown: nope>", "unknown kind caption")
	check_eq(svc.prefixes(), PREFIXES, "prefixes from config")
	var st: Dictionary = svc.stats()
	check_eq(st.total, 3, "stats total")
	check_eq(st.hidden, 1, "stats hidden")
	check_eq(st.per_kind.get(&"round_reached"), 1, "stats per kind")
	var row: Dictionary = svc.preview_row(&"secret")
	check_eq(row.locked.name, "???", "masked name while locked")
	check_eq(row.locked.description, "", "masked description while locked")
	check_eq(row.locked.hint, "Look to the stars.", "hint shown while locked")
	check_eq(row.earned.name, "Look to the Stars", "real name once earned")
	check_eq(row.earned_key, "test_ach_secret", "earned key")
	check_eq(row.progress_key, "test_achp_secret", "progress key")
	check_eq(svc.preview_row(&"round_10_quick").locked.progress, "0 / 10", "locked progress text")
	check(svc.preview_row(&"nope").is_empty(), "unknown id has no preview")


func test_filter() -> void:
	var svc := _service()
	check_eq(svc.filter_ids(""), svc.ids(), "empty filter keeps all")
	check_eq(svc.filter_ids("QUICK"), _ids([&"round_10_quick"]), "matches id, case-insensitive")
	check_eq(svc.filter_ids("sweep"), _ids([&"first_clear"]), "matches name")
	check_eq(svc.filter_ids("unlock_earned"), _ids([&"secret"]), "matches kind")


func test_add() -> void:
	var svc := _service()
	check(not svc.add(&"Bad Id", &"flags").ok, "invalid id refused")
	check(not svc.add(&"secret", &"flags").ok, "existing id refused")
	check(not svc.add(&"gone", &"flags").ok, "retired id refused")
	check(not svc.add(&"old_clear", &"flags").ok, "RENAMED key refused")
	check(not svc.add(&"fresh", &"nope").ok, "undeclared kind refused")
	check_eq(_changed, 0, "refusals emit nothing")
	check(not svc.is_dirty(), "refusals leave it clean")
	var r: Dictionary = svc.add(&"flag_one", &"flags")
	check(r.ok, "add ok")
	check_eq(svc.ids()[-1], &"flag_one", "appended")
	var d: Dictionary = svc.get_def(&"flag_one")
	check_eq(d.name, "Flag One", "name from id")
	check_eq(d.kind, &"flags", "kind")
	check_eq(d.target, 1, "target default")
	check_eq(d.params, {}, "params default")
	check_eq(d.keys(), Array(AchKitSchema.FIELDS), "every field, in order")
	check(svc.is_dirty(), "dirty")
	check_eq(_changed, 1, "changed emitted")
	check(not svc.is_shipped(&"flag_one"), "a new id is not shipped")
	check_problem(svc.problems(), "flag_one: description must not be empty", "new entry needs a description")

	r = svc.duplicate_entry(&"first_clear", &"second_clear")
	check(r.ok, "duplicate ok")
	check_eq(svc.ids().slice(0, 3), _ids([&"first_clear", &"second_clear", &"round_10_quick"]),
		"copy placed after the source")
	check_eq(svc.get_def(&"second_clear"), svc.get_def(&"first_clear"), "copy is identical")
	check(not svc.duplicate_entry(&"first_clear", &"secret").ok, "duplicate onto an existing id refused")
	check(not svc.duplicate_entry(&"nope", &"x").ok, "duplicate of unknown id refused")


func test_edit_fields_and_params() -> void:
	var svc := _service()
	check(svc.set_field(&"first_clear", "name", "Spotless").ok, "name")
	check(svc.set_field(&"first_clear", "description", "Clear\nit.").ok, "description")
	check(svc.set_field(&"first_clear", "target", "5").ok, "target from text")
	check(not svc.set_field(&"first_clear", "target", "five").ok, "non-numeric target refused")
	check(svc.set_field(&"first_clear", "hidden", true).ok, "hidden")
	check(svc.set_field(&"first_clear", "hint", "Sweep.").ok, "hint")
	check(svc.set_field(&"first_clear", "category", "boards").ok, "category")
	check(not svc.set_field(&"first_clear", "colour", "red").ok, "unknown field refused")
	check(not svc.set_field(&"first_clear", "params", {}).ok, "params need set_param")
	check(not svc.set_field(&"nope", "name", "x").ok, "unknown id refused")
	var d: Dictionary = svc.get_def(&"first_clear")
	check_eq(d.name, "Spotless", "name stored")
	check_eq(d.description, "Clear\nit.", "description stored")
	check_eq(d.target, 5, "target is an int")
	check_eq(d.hidden, true, "hidden stored")
	check_eq(d.category, &"boards", "category is a StringName")
	check_eq(svc.categories(), _ids([&"boards", &"runs", &"secrets"]), "new category first (first use)")

	check(svc.add(&"flagged", &"flags").ok, "add flags")
	check(svc.set_param(&"flagged", "tag", "boss").ok, "string param")
	check(svc.set_param(&"flagged", "level", "3").ok, "int param from text")
	check(svc.set_param(&"flagged", "hard", true).ok, "bool param")
	check(not svc.set_param(&"flagged", "level", "lots").ok, "non-numeric int param refused")
	check(not svc.set_param(&"flagged", "nope", 1).ok, "undeclared param refused")
	check_eq(svc.get_def(&"flagged").params, {"tag": "boss", "level": 3, "hard": true},
		"params in the kind's declared order, typed")
	check(svc.set_param(&"flagged", "level", 0).ok, "param back to default")
	check(not svc.get_def(&"flagged").params.has("level"), "a param at the kind default is dropped")

	check(not svc.set_param(&"round_10_quick", "source", "nope").ok, "enum value outside values refused")
	check(svc.set_param(&"round_10_quick", "source", "curated").ok, "enum value")
	check_eq(svc.get_def(&"round_10_quick").params, {"source": "curated"}, "enum stored")
	check(svc.set_field(&"round_10_quick", "kind", "flags").ok, "kind change")
	check_eq(svc.get_def(&"round_10_quick").params, {}, "kind change drops params the new kind lacks")
	check(svc.set_field(&"round_10_quick", "kind", "mystery").ok, "an unknown kind can be stored")
	check_problem(svc.problems(), "round_10_quick: kind \"mystery\" is not a declared kind",
		"unknown kind is a problem")


func test_rename() -> void:
	var svc := _service()
	check(not svc.rename(&"first_clear", &"Bad").ok, "invalid id refused")
	check(not svc.rename(&"first_clear", &"secret").ok, "taken id refused")
	check(not svc.rename(&"first_clear", &"gone").ok, "retired id refused")
	check(not svc.rename(&"nope", &"x").ok, "unknown id refused")

	var r: Dictionary = svc.rename(&"first_clear", &"clean_sweep")
	check(r.ok and r.recorded, "shipped rename recorded")
	check_eq(svc.ids()[0], &"clean_sweep", "position kept")
	check_eq(svc.model.renamed, {&"first_clear": &"clean_sweep", &"old_clear": &"clean_sweep"},
		"RENAMED gains old -> new and the chain collapses")
	check(svc.problems().is_empty(), "still valid: %s" % svc.problems())

	r = svc.rename(&"clean_sweep", &"first_clear")
	check(r.ok and not r.recorded, "renaming back")
	check_eq(svc.model.renamed, {&"old_clear": &"first_clear"}, "renaming back restores RENAMED")

	check(svc.add(&"draft", &"flags").ok, "add")
	r = svc.rename(&"draft", &"draft_two")
	check(r.ok and not r.recorded, "unshipped rename not recorded")
	check(not svc.model.renamed.has(&"draft"), "no RENAMED entry for an id never on disk")
	check(not svc.rename(&"draft_two", &"old_clear").ok, "an old id of another achievement is refused")
	check(svc.set_field(&"draft_two", "id", "draft_three").ok, "set_field id renames")
	check(svc.has_id(&"draft_three"), "renamed through set_field")


func test_remove() -> void:
	var svc := _service()
	check(svc.add(&"draft", &"flags").ok, "add")
	var r: Dictionary = svc.remove(&"draft")
	check(r.ok and not r.retired, "unshipped id just dropped")
	check(not (svc.model.retired as Array).has(&"draft"), "not retired")
	r = svc.remove(&"first_clear")
	check(r.ok and r.retired, "shipped id retired")
	check_eq(svc.model.retired, _ids([&"gone", &"first_clear", &"old_clear"]),
		"the id and the RENAMED keys that pointed at it are retired")
	check(svc.model.renamed.is_empty(), "dangling RENAMED entry erased")
	check(not svc.remove(&"first_clear").ok, "removing twice refused")
	check(not svc.add(&"first_clear", &"flags").ok, "a retired id cannot come back")
	check(svc.problems().is_empty(), "still valid: %s" % svc.problems())


func test_move() -> void:
	var svc := _service()
	var r: Dictionary = svc.move(&"secret", -1)
	check(r.ok and r.moved, "moved")
	check_eq(svc.ids(), _ids([&"first_clear", &"secret", &"round_10_quick"]), "order after move")
	_changed = 0
	r = svc.move(&"first_clear", -5)
	check(r.ok and not r.moved, "clamped at the top: no move")
	check_eq(_changed, 0, "a no-op move emits nothing")
	check(svc.move(&"first_clear", 99).ok, "move to the end")
	check_eq(svc.ids()[-1], &"first_clear", "clamped to the end")
	check(not svc.move(&"nope", 1).ok, "unknown id refused")


func test_problems_errors_and_warnings() -> void:
	var svc := _service()
	check(svc.set_field(&"first_clear", "name", "").ok, "blank the name")
	check_problem(svc.problems(), "first_clear: name must not be empty", "error reported")
	check_eq(svc.problems_for(&"first_clear").size(), 1, "problems_for the row")
	check(svc.problems_for(&"secret").is_empty(), "other rows clean")
	check_eq(svc.problem_id("first_clear: name must not be empty"), &"first_clear", "problem -> id")
	check_eq(svc.problem_id("RENAMED: cycle a -> b -> a"), &"", "a problem naming no live id")
	var before := FileAccess.get_file_as_string(_defs_path())
	var r: Dictionary = svc.save()
	check(not r.ok, "an error blocks the save")
	check(str(r.get("error", "")).contains("name must not be empty"), "the refusal says why")
	check_eq(FileAccess.get_file_as_string(_defs_path()), before, "nothing written")
	check(svc.is_dirty(), "still dirty")

	check(svc.set_field(&"first_clear", "name", "Clean Sweep").ok, "fix it")
	check(svc.set_field(&"secret", "hint", "").ok, "hidden count kind with no hint")
	var warn := false
	for p in svc.problems():
		if AchKitSchema.is_warning(p) and p.contains("secret: hidden with no hint"):
			warn = true
	check(warn, "warning reported: %s" % svc.problems())
	check(svc.errors().is_empty(), "warnings are not errors")
	check_eq(svc.problem_id(svc.problems()[0]), &"secret", "a warning maps to its id")
	r = svc.save()
	check(r.ok, "a warning does not block the save: %s" % r)
	check_eq(svc.get_def(&"secret").hint, "", "saved and reloaded")


func test_save_writes_serialize_bytes() -> void:
	var svc := _service()
	var fixture := FileAccess.get_file_as_string(FIXTURE_DEFS)
	check(svc.save().ok, "save unchanged")
	check_eq(FileAccess.get_file_as_string(_defs_path()), fixture, "an unchanged save rewrites the same bytes")

	check(svc.add(&"flagged", &"flags").ok, "add")
	check(svc.set_field(&"flagged", "description", "Tab\there \"quoted\" \\ é.").ok, "description")
	check(svc.set_param(&"flagged", "tag", "boss").ok, "param")
	check(svc.rename(&"first_clear", &"clean_sweep").ok, "rename")
	check(svc.remove(&"round_10_quick").ok, "remove")
	var expect := AchKitCodegen.serialize(svc.model.achievements, svc.model.renamed, svc.model.retired,
		svc.kinds, PREFIXES)
	check_eq(svc.serialized_text(), expect, "serialized_text is the codegen output")
	var r: Dictionary = svc.save()
	check(r.ok, "save ok: %s" % r)
	var text := FileAccess.get_file_as_string(_defs_path())
	check_eq(text, expect, "the file is byte-identical to AchKitCodegen.serialize")
	check_eq(int(r.bytes), text.to_utf8_buffer().size(), "bytes reported")
	check(AchKitCodegen.is_canonical(text, svc.kinds, PREFIXES), "canonical")
	check(text.contains("test_ach_<id>, test_achp_<id>"), "header names the configured prefixes")
	check(not svc.is_dirty(), "clean after save")
	check(svc.is_shipped(&"flagged"), "a saved id counts as shipped from then on")
	var parsed := AchKitCodegen.parse_text(text)
	check_eq(parsed.renamed, {&"first_clear": &"clean_sweep", &"old_clear": &"clean_sweep"}, "RENAMED on disk")
	check_eq(parsed.retired, _ids([&"gone", &"round_10_quick"]), "RETIRED on disk")
	check(svc.rename(&"flagged", &"flag_two").ok and svc.model.renamed.has(&"flagged"),
		"renaming a just-saved id is recorded")


func test_save_refused_after_external_edit() -> void:
	var svc := _service()
	check(svc.set_field(&"first_clear", "name", "Mine").ok, "edit")
	var theirs := FileAccess.get_file_as_string(_defs_path()) + "# someone else\n"
	_write(_defs_path(), theirs)
	check(svc.disk_changed(), "disk change detected")
	var r: Dictionary = svc.save()
	check(not r.ok, "save refused")
	check(str(r.get("error", "")).contains("changed on disk"), "refusal says changed on disk")
	check(str(r.get("error", "")).contains("Revert first"), "refusal says Revert first")
	check_eq(FileAccess.get_file_as_string(_defs_path()), theirs, "their edit survives")

	DirAccess.remove_absolute(_defs_path())
	check(svc.disk_changed(), "a deleted file is a change too")
	check(not svc.save().ok, "save refused after delete")

	_write(_defs_path(), theirs)
	check(svc.revert().ok, "revert")
	check(not svc.disk_changed(), "in sync after revert")
	check(not svc.is_canonical_on_disk(), "their hand edit is not canonical")
	check(svc.save().ok, "save after revert")
	check(svc.is_canonical_on_disk(), "saving normalizes it")


func test_revert() -> void:
	var svc := _service()
	check(svc.set_field(&"first_clear", "name", "Mine").ok, "edit")
	check(svc.remove(&"secret").ok, "remove")
	check(svc.is_dirty(), "dirty")
	_changed = 0
	check(svc.revert().ok, "revert ok")
	check_eq(_changed, 1, "revert emits changed")
	check(not svc.is_dirty(), "clean")
	check_eq(svc.get_def(&"first_clear").name, "Clean Sweep", "edit dropped")
	check(svc.has_id(&"secret"), "removal dropped")
	check_eq(svc.model.retired, _ids([&"gone"]), "RETIRED back to disk")


func test_missing_definitions_file_is_created() -> void:
	DirAccess.remove_absolute(_defs_path())
	var cfg := JSON.parse_string(FileAccess.get_file_as_string(_config_path())) as Dictionary
	cfg.definitions = _dir.path_join("new/sub/achievements.gd")
	_write(_config_path(), JSON.stringify(cfg))
	var svc := _service(false)
	check(svc.reload().ok, "a missing definitions file is not an error")
	check(not svc.file_exists(), "no file yet")
	check(svc.ids().is_empty(), "empty model")
	check(svc.add(&"first", &"boards_cleared").ok, "add")
	check(svc.set_field(&"first", "description", "Do it.").ok, "describe")
	var expect: String = svc.serialized_text()
	check(svc.save().ok, "save creates the file and its folders")
	check_eq(FileAccess.get_file_as_string(svc.definitions_path()), expect, "written")
	check(svc.file_exists(), "exists now")


func test_load_errors_block_save() -> void:
	# Compiles, but has no ACHIEVEMENTS (a real syntax error is covered by test_codegen and would
	# add a third expected "Parse Error" line to the output).
	var broken := "extends RefCounted\nconst SCHEMA := 1\n"
	_write(_defs_path(), broken)
	var svc := _service(false)
	var r: Dictionary = svc.reload()
	check(not r.ok, "a file that does not parse fails the load")
	check(svc.load_error() != "", "load_error set")
	check_problem(svc.problems(), "no `const ACHIEVEMENTS", "load error is a problem")
	check(not svc.save().ok, "save refused")
	check_eq(FileAccess.get_file_as_string(_defs_path()), broken, "the broken file is untouched")

	_write(_defs_path(), FileAccess.get_file_as_string(FIXTURE_DEFS).replace("const SCHEMA := 1",
		"const SCHEMA := 99"))
	check(not svc.reload().ok, "a newer schema fails the load")
	check(svc.schema_newer(), "schema_newer")

	_write(_defs_path(), FileAccess.get_file_as_string(FIXTURE_DEFS))
	DirAccess.remove_absolute(_dir.path_join("kinds.gd"))
	r = svc.reload()
	check(not r.ok, "a missing kinds file fails the load")
	check(svc.load_error().contains("kinds file"), "kinds error named")
	check_eq(svc.ids().size(), 3, "definitions still shown")
	check(not svc.save().ok, "save refused without kinds")


func test_dock_builds_headless() -> void:
	var svc := _service(false)   # the dock loads it in _ready, like the plugin does
	var dock: Control = DockT.new()
	dock.service = svc
	add_node(dock)
	await settle()
	check(dock.has_method("select_id"), "dock exposes select_id")
	dock.call("select_id", &"secret")
	await settle()
	check_eq(dock.call("selected_id"), &"secret", "selection")
	check(svc.set_field(&"secret", "name", "Stars").ok, "edit while the dock is open")
	check(svc.add(&"flagged", &"flags").ok, "add while the dock is open")
	dock.call("select_id", &"flagged")
	await settle()
	check_eq(dock.call("selected_id"), &"flagged", "new row selectable")
	check(svc.revert().ok, "revert while the dock is open")
	await settle()
	check_eq(dock.call("selected_id"), &"", "selection cleared when its id is gone")


# ---- helpers ----------------------------------------------------------------------


func _service(load_now := true) -> Node:
	var svc: Node = ServiceT.new()
	add_node(svc)
	svc.config_path = _config_path()
	svc.changed.connect(_on_changed)
	if load_now:
		svc.reload()
		_changed = 0
	return svc


func _on_changed() -> void:
	_changed += 1


func _config_path() -> String:
	return _dir.path_join("achievements_kit.config.json")


func _defs_path() -> String:
	return _dir.path_join("achievements.gd")


func _ids(a: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for v: Variant in a:
		out.append(StringName(str(v)))
	return out


static func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


static func _rm_rf(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)
