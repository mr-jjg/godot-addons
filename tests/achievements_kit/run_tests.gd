extends SceneTree

## Headless runner for the achievements_kit suite:
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script res://tests/achievements_kit/run_tests.gd [-- --filter=<substring>]
##
## Discovers res://tests/achievements_kit/**/test_*.gd (each extends achkit_test_case.gd),
## runs every test_* method, prints one line per test and a summary, and exits 0 only if
## everything passed. --filter matches against "<file>::<test>". The suite must write nothing
## under user:// (checked at the end): tests use in-memory stores and committed fixtures.

const ROOT := "res://tests/achievements_kit"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var user_before := user_files()
	for i in 3:
		await process_frame
	var filter := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.trim_prefix("--filter=")

	var passed := 0
	var failed := 0
	for path in _discover(ROOT):
		var script: Script = load(path)
		if script == null or not script.can_instantiate():
			print("FAIL %s: script failed to load" % path)
			failed += 1
			continue
		var case: Object = script.new()
		case.set("tree", self)
		for m in script.get_script_method_list():
			var mname: String = m["name"]
			if not mname.begins_with("test_"):
				continue
			var label := "%s::%s" % [path.get_file(), mname]
			if filter != "" and not label.contains(filter):
				continue
			case.set("failures", PackedStringArray())
			await case.call("before_each")
			await case.call(mname)
			await case.call("after_each")
			case.call("_free_nodes")
			var fails: PackedStringArray = case.get("failures")
			if fails.is_empty():
				passed += 1
				print("  ok   %s" % label)
			else:
				failed += 1
				print("  FAIL %s" % label)
				for f in fails:
					print("         - %s" % f)

	await process_frame   # let queue_free()d test nodes go before exit
	var leaked := diff_files(user_before, user_files())
	if not leaked.is_empty():
		failed += 1
		print("  FAIL suite wrote under user://:")
		for p in leaked:
			print("         - %s" % p)
	print("ACHKIT TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


## path -> [size, modified time] for files under `dir` (recursive). Godot's own log files
## (user://logs/) are ignored.
static func user_files(dir := "user://") -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		var p := dir.path_join(f)
		out[p] = [FileAccess.get_file_as_bytes(p).size(), FileAccess.get_modified_time(p)]
	for sub in d.get_directories():
		if dir == "user://" and sub == "logs":
			continue
		out.merge(user_files(dir.path_join(sub)))
	return out


static func diff_files(before: Dictionary, after: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for p in after:
		if not before.has(p):
			out.append("created " + p)
		elif before[p] != after[p]:
			out.append("modified " + p)
	for p in before:
		if not after.has(p):
			out.append("deleted " + p)
	return out


func _discover(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	var subdirs := dir.get_directories()
	var files := dir.get_files()
	files.sort()
	for f in files:
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	subdirs.sort()
	for d in subdirs:
		out.append_array(_discover(dir_path.path_join(d)))
	return out
