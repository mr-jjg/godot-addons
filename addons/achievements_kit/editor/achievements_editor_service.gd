@tool
extends "res://addons/editor_tool_kit/tool_service.gd"

## Headless-testable core of the Achievements dock (a ToolService). It loads the game's kinds
## file and generated definitions file (paths from the game's res://achievements_kit.config.json),
## holds the in-memory model, applies every edit the dock offers, validates through AchKitSchema
## and writes through AchKitCodegen.serialize, so what it saves is byte-for-byte what the game's
## check expects.
##
## No Control / EditorInterface references: it loads and runs under `godot --headless`
## (tests/achievements_kit/test_editor_service.gd). The only editor-side seam is
## ContentStore.save_all's filesystem rescan, which is skipped outside the editor.
##
## Ids are save keys. A rename or delete of an id that is in the file on disk ("shipped": a
## build may have written its keys to a player's save) is recorded in RENAMED / RETIRED through
## AchKitCodegen.rename / remove; an id added since the last load is renamed or dropped freely.
## Saving reloads from disk, so ids just saved count as shipped from then on.
##
## Every mutating call returns ok() / err() (ToolService) and emits `changed` on success.

const ContentStore := preload("res://addons/editor_tool_kit/content_store.gd")

## The consuming game's config, read from res:// root (NOT from inside this addon: a
## self-update overwrites the addon folder but never this file).
const CONFIG_PATH := "res://achievements_kit.config.json"
const DEFAULTS := {
	"definitions": "",          # the generated definitions file (required)
	"kinds": "",                # the game's hand-written kinds file (required)
	"earned_key_prefix": "",    # save-key prefix for the earned bool ("" -> codegen default)
	"progress_key_prefix": "",  # save-key prefix for the progress int ("" -> codegen default)
	"icon_dir": "",             # where the icon Browse dialog starts ("" -> res://)
}
## Fields set_field() accepts (the id goes through rename(), params through set_param()).
const EDITABLE_FIELDS: Array[String] = ["name", "description", "kind", "target", "hidden", "hint",
	"icon", "category"]

## Emitted after every load and every successful edit, so the dock re-renders.
signal changed

## Which config file to read. Tests point it at a temp file; the editor keeps CONFIG_PATH.
var config_path := CONFIG_PATH
## The merged config (DEFAULTS applied).
var config: Dictionary = {}
## The game's KINDS (kind name -> kind), as parsed from the kinds file.
var kinds: Dictionary = {}
## {"achievements": {id: def}, "renamed": {old: id}, "retired": Array[StringName]}
var model: Dictionary = _empty_model()

var _shipped := {}             # id -> true for every id in the file on disk at the last load
var _disk_exists := false      # the definitions file existed at the last load
var _disk_hash := ""           # sha256 of its text at the last load ("" when missing)
var _canonical := true         # parse(text) then serialize == text, at the last load
var _defs_error := ""          # the definitions file exists but did not parse
var _schema_newer := false     # ... because its SCHEMA is newer than this addon knows
var _kinds_error := ""         # the kinds file is missing or did not parse


# ---- config -----------------------------------------------------------------------


## Load the game's config over DEFAULTS. A missing file gives pure defaults (not configured).
func load_config() -> Dictionary:
	config = DEFAULTS.duplicate(true)
	config.merge(ContentStore.load_json(config_path), true)
	return config


## True once the config names both the definitions file and the kinds file.
func is_configured() -> bool:
	return str(config.get("definitions", "")) != "" and str(config.get("kinds", "")) != ""


func definitions_path() -> String:
	return _resolve(str(config.get("definitions", "")))


func kinds_path() -> String:
	return _resolve(str(config.get("kinds", "")))


func icon_dir() -> String:
	var d := str(config.get("icon_dir", ""))
	return _resolve(d) if d != "" else "res://"


## {"earned": ..., "progress": ...}, the save-key prefixes the header and preview show.
func prefixes() -> Dictionary:
	var e := str(config.get("earned_key_prefix", ""))
	var p := str(config.get("progress_key_prefix", ""))
	return {
		"earned": e if e != "" else str(AchKitCodegen.DEFAULT_PREFIXES.earned),
		"progress": p if p != "" else str(AchKitCodegen.DEFAULT_PREFIXES.progress),
	}


func earned_key(id: StringName) -> String:
	return str(prefixes().earned) + str(id)


func progress_key(id: StringName) -> String:
	return str(prefixes().progress) + str(id)


# ---- load -------------------------------------------------------------------------


## Read the config, the kinds file and the definitions file from disk, dropping any unsaved
## edits. Remembers the definitions text's hash (save() refuses if it changes) and the set of
## ids on disk ("shipped"). A missing definitions file is not an error: the model starts empty
## and Save creates it. -> ok({count}) or err(why)
func reload() -> Dictionary:
	load_config()
	kinds = {}
	model = _empty_model()
	_shipped = {}
	_disk_exists = false
	_disk_hash = ""
	_canonical = true
	_defs_error = ""
	_schema_newer = false
	_kinds_error = ""
	clear_dirty()
	if not is_configured():
		changed.emit()
		return err("not configured: create %s (see achievements_kit.config.example.json)" % config_path)

	var k := AchKitCodegen.parse_kinds_file(kinds_path())
	if k.ok:
		kinds = k.kinds
	else:
		_kinds_error = "kinds file %s: %s" % [kinds_path(), k.error]

	var path := definitions_path()
	if FileAccess.file_exists(path):
		_disk_exists = true
		var parsed := AchKitCodegen.parse_file(path)
		_disk_hash = str(parsed.text).sha256_text()
		_schema_newer = int(parsed.schema) > AchKitSchema.SCHEMA_VERSION
		if parsed.ok:
			model = {
				"achievements": _sn_keyed(parsed.achievements),
				"renamed": _sn_renamed(parsed.renamed),
				"retired": parsed.retired,
			}
			for id: StringName in model.achievements:
				_shipped[id] = true
			_canonical = _kinds_error != "" or AchKitCodegen.is_canonical(str(parsed.text), kinds, prefixes())
		else:
			_defs_error = "definitions file %s: %s" % [path, parsed.error]
	changed.emit()
	if _kinds_error != "":
		return err(_kinds_error)
	if _defs_error != "":
		return err(_defs_error)
	return ok({"count": model.achievements.size()})


## Drop unsaved edits and reload from disk (there is no UndoRedo in 0.2.0).
func revert() -> Dictionary:
	return reload()


## Did the definitions file change on disk since the last load (edited, created or deleted)?
func disk_changed() -> bool:
	var path := definitions_path()
	if not FileAccess.file_exists(path):
		return _disk_exists
	if not _disk_exists:
		return true
	return FileAccess.get_file_as_string(path).sha256_text() != _disk_hash


func file_exists() -> bool:
	return _disk_exists


## The definitions file on disk is not what the dock would write (hand-edited, or an older
## schema): saving normalizes it.
func is_canonical_on_disk() -> bool:
	return _canonical


func schema_newer() -> bool:
	return _schema_newer


## Why the files could not be loaded ("" when they could). A non-empty value blocks save().
func load_error() -> String:
	if _kinds_error != "":
		return _kinds_error
	return _defs_error


func is_shipped(id: StringName) -> bool:
	return _shipped.has(id)


# ---- reads ------------------------------------------------------------------------


## Ids in display order.
func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: Variant in model.achievements:
		out.append(StringName(str(id)))
	return out


func has_id(id: StringName) -> bool:
	return model.achievements.has(id)


## The definition for `id` ({} when unknown). A copy: edit through the mutators.
func get_def(id: StringName) -> Dictionary:
	var d: Variant = model.achievements.get(id, {})
	return (d as Dictionary).duplicate(true) if typeof(d) == TYPE_DICTIONARY else {}


## Ids whose id, name or kind contains `text` (case-insensitive), in display order.
func filter_ids(text: String) -> Array[StringName]:
	var needle := text.strip_edges().to_lower()
	var out: Array[StringName] = []
	for id in ids():
		var d := get_def(id)
		if (needle == "" or str(id).to_lower().contains(needle)
				or str(d.get("name", "")).to_lower().contains(needle)
				or str(d.get("kind", "")).to_lower().contains(needle)):
			out.append(id)
	return out


## Kind names in the kinds file's order.
func kind_names() -> Array[StringName]:
	var out: Array[StringName] = []
	for k: Variant in kinds:
		out.append(StringName(str(k)))
	return out


## "label (mode)" for a declared kind, "<unknown: x>" otherwise.
func kind_caption(kind: StringName) -> String:
	if not kinds.has(kind) or typeof(kinds[kind]) != TYPE_DICTIONARY:
		return "<unknown: %s>" % kind
	var k: Dictionary = kinds[kind]
	return "%s (%s)" % [str(k.get("label", kind)), str(k.get("mode", "?"))]


## The kind's declared params (name -> spec), {} for an unknown kind.
func kind_params(kind: StringName) -> Dictionary:
	var k: Variant = kinds.get(kind)
	if typeof(k) != TYPE_DICTIONARY or typeof((k as Dictionary).get("params")) != TYPE_DICTIONARY:
		return {}
	return (k as Dictionary).params


## Distinct non-empty categories, in order of first use.
func categories() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in ids():
		var c := StringName(str(get_def(id).get("category", "")))
		if c != &"" and not out.has(c):
			out.append(c)
	return out


## Every problem: the kinds file's, a load failure, then AchKitSchema.validate on the in-memory
## model. Entries starting with AchKitSchema.WARNING_PREFIX are warnings and never block save().
func problems() -> PackedStringArray:
	var out := PackedStringArray()
	if not is_configured():
		return out
	if _kinds_error != "":
		out.append(_kinds_error)
	if _defs_error != "":
		out.append(_defs_error)
	out.append_array(AchKitSchema.validate_kinds(kinds))
	out.append_array(AchKitSchema.validate(model.achievements, kinds, model.renamed, model.retired))
	return out


## problems() without the warnings: what blocks a save.
func errors() -> PackedStringArray:
	return AchKitSchema.errors_only(problems())


## The problems that name `id` (the dock's "!" flag).
func problems_for(id: StringName) -> PackedStringArray:
	var out := PackedStringArray()
	for p in problems():
		if problem_id(p) == id:
			out.append(p)
	return out


## The achievement a problem is about (&"" when it names none, e.g. a RENAMED or kind problem).
func problem_id(problem: String) -> StringName:
	var text := problem.trim_prefix(AchKitSchema.WARNING_PREFIX)
	var at := text.find(": ")
	if at <= 0:
		return &""
	var id := StringName(text.substr(0, at))
	return id if has_id(id) else &""


## The row as the game shows it (AchKitTracker.rows() rules), locked and earned, plus the save
## keys. {} when unknown. -> {id, hidden, target, earned_key, progress_key,
##   locked: {name, description, hint, masked, progress}, earned: {name, description}}
func preview_row(id: StringName) -> Dictionary:
	if not has_id(id):
		return {}
	var d := get_def(id)
	var hidden := bool(d.get("hidden", false)) if typeof(d.get("hidden")) == TYPE_BOOL else false
	var target := int(d.get("target", 1)) if typeof(d.get("target")) == TYPE_INT else 1
	return {
		"id": id,
		"hidden": hidden,
		"target": target,
		"earned_key": earned_key(id),
		"progress_key": progress_key(id),
		"locked": {
			"name": "???" if hidden else str(d.get("name", "")),
			"description": "" if hidden else str(d.get("description", "")),
			"hint": str(d.get("hint", "")),
			"masked": hidden,
			"progress": "0 / %d" % target,
		},
		"earned": {
			"name": str(d.get("name", "")),
			"description": str(d.get("description", "")),
		},
	}


## {total, hidden, per_kind: {kind: n}} (kinds in first-use order).
func stats() -> Dictionary:
	var hidden := 0
	var per_kind := {}
	for id in ids():
		var d := get_def(id)
		if d.get("hidden") == true:
			hidden += 1
		var k := StringName(str(d.get("kind", "")))
		per_kind[k] = int(per_kind.get(k, 0)) + 1
	return {"total": model.achievements.size(), "hidden": hidden, "per_kind": per_kind}


## The exact text save() would write.
func serialized_text() -> String:
	return AchKitCodegen.serialize(model.achievements, model.renamed, model.retired, kinds, prefixes())


# ---- edits ------------------------------------------------------------------------


## Append a new achievement of `kind`, with every field at its default (AchKitSchema.normalize_def)
## and a name made from the id.
func add(id: StringName, kind: StringName) -> Dictionary:
	var gate := _check_new_id(id)
	if gate != "":
		return err(gate)
	if not kinds.has(kind):
		return err("kind \"%s\" is not declared in the kinds file" % kind)
	var def := {"name": str(id).capitalize(), "kind": kind, "target": 1}
	model.achievements[id] = AchKitSchema.normalize_def(def, _kind(kind))
	return _edited({"id": id})


## Copy `id` to `new_id`, placed right after it.
func duplicate_entry(id: StringName, new_id: StringName) -> Dictionary:
	if not has_id(id):
		return err("no achievement \"%s\"" % id)
	var gate := _check_new_id(new_id)
	if gate != "":
		return err(gate)
	var copy := get_def(id)
	var out := {}
	for k: Variant in model.achievements:
		out[k] = model.achievements[k]
		if StringName(str(k)) == id:
			out[new_id] = copy
	model.achievements = out
	return _edited({"id": new_id})


## Set one field of `id` (see EDITABLE_FIELDS), coerced to the field's type. Changing the kind
## keeps only the params the new kind declares.
func set_field(id: StringName, field: String, value: Variant) -> Dictionary:
	if not has_id(id):
		return err("no achievement \"%s\"" % id)
	if field == "id":
		return rename(id, StringName(str(value)))
	if field == "params":
		return err("set params one at a time with set_param()")
	if not EDITABLE_FIELDS.has(field):
		return err("unknown field \"%s\"" % field)
	var d := get_def(id)
	match field:
		"target":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] and not str(value).is_valid_int():
				return err("target must be a whole number")
			d.target = int(value)
		"hidden":
			d.hidden = bool(value)
		"kind", "category":
			d[field] = StringName(str(value).strip_edges())
		_:
			d[field] = str(value)
	if field == "kind":
		# Keep only the params the new kind declares (a wrong-typed value shows as a problem).
		var keep := {}
		var declared := kind_params(d.kind)
		var params: Variant = d.get("params", {})
		if typeof(params) == TYPE_DICTIONARY:
			for p: Variant in params:
				if declared.has(str(p)):
					keep[str(p)] = params[p]
		d.params = keep
	return _store(id, d)


## Set one param of `id`. It must be declared by the achievement's kind; the value is coerced
## to the param's type and an enum value must be one of its values. A value equal to the kind's
## default is dropped when saved (it matches anything either way).
func set_param(id: StringName, param: String, value: Variant) -> Dictionary:
	if not has_id(id):
		return err("no achievement \"%s\"" % id)
	var d := get_def(id)
	var declared := kind_params(StringName(str(d.get("kind", ""))))
	if not declared.has(param) or typeof(declared[param]) != TYPE_DICTIONARY:
		return err("param \"%s\" is not declared by kind \"%s\"" % [param, d.get("kind", "")])
	var spec: Dictionary = declared[param]
	var v: Variant
	match str(spec.get("type", "")):
		"int":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] and not str(value).is_valid_int():
				return err("param \"%s\" must be a whole number" % param)
			v = int(value)
		"bool":
			v = bool(value)
		"enum":
			v = str(value)
			var values: Variant = spec.get("values", [])
			if typeof(values) != TYPE_ARRAY or not (values as Array).map(
					func(x: Variant) -> String: return str(x)).has(v):
				return err("param \"%s\": \"%s\" is not one of %s" % [param, v, JSON.stringify(values)])
		_:
			v = str(value)
	var params: Dictionary = d.params if typeof(d.get("params")) == TYPE_DICTIONARY else {}
	params[param] = v
	d.params = params
	return _store(id, d)


## Rename `old_id` to `new_id` in place. RENAMED gains old -> new only when old_id is in the file
## on disk (shipped); renaming back to a former id collapses the chain (AchKitCodegen.rename).
func rename(old_id: StringName, new_id: StringName) -> Dictionary:
	if not has_id(old_id):
		return err("no achievement \"%s\"" % old_id)
	if old_id == new_id:
		return ok({"id": new_id})
	if has_id(new_id):
		return err("\"%s\" is already an achievement" % new_id)
	if not AchKitSchema.is_valid_id(str(new_id)):
		return err("\"%s\": an id is 1-48 of a-z, 0-9 and _, starting with a letter" % new_id)
	if (model.retired as Array).has(new_id):
		return err("\"%s\" was retired; retired ids are never reused" % new_id)
	if model.renamed.has(new_id) and AchKitSchema.canonical(new_id, model.renamed) != old_id:
		return err("\"%s\" is an old id of \"%s\" (RENAMED); pick another id" % [
			new_id, AchKitSchema.canonical(new_id, model.renamed)])
	var shipped := is_shipped(old_id)
	model = AchKitCodegen.rename(model, old_id, new_id, shipped)
	return _edited({"id": new_id, "recorded": shipped})


## Delete `id`. When it is in the file on disk (shipped) it is RETIRED and never reusable; RENAMED
## entries that pointed at it are retired too (AchKitCodegen.remove).
func remove(id: StringName) -> Dictionary:
	if not has_id(id):
		return err("no achievement \"%s\"" % id)
	var shipped := is_shipped(id)
	model = AchKitCodegen.remove(model, id, shipped)
	return _edited({"id": id, "retired": shipped})


## Move `id` by `delta` places in display order (clamped to the ends).
func move(id: StringName, delta: int) -> Dictionary:
	if not has_id(id):
		return err("no achievement \"%s\"" % id)
	var before := ids()
	model = AchKitCodegen.move(model, id, delta)
	if ids() == before:
		return ok({"id": id, "moved": false})
	return _edited({"id": id, "moved": true})


# ---- save -------------------------------------------------------------------------


## Write the model through AchKitCodegen.serialize. Refuses when the files did not load, when the
## definitions file changed on disk since the last load ("Revert first"), or when there are
## errors (warnings never block). On success reloads from disk. -> ok({path, bytes}) or err(why)
func save() -> Dictionary:
	if not is_configured():
		return err("not configured: create %s" % config_path)
	if load_error() != "":
		return err("cannot save: %s" % load_error())
	if disk_changed():
		return err("%s changed on disk since it was loaded: Revert first (your edits here are lost)"
			% definitions_path())
	var path := definitions_path()
	var text := serialized_text()
	if errors().is_empty() and not DirAccess.dir_exists_absolute(path.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var r := ContentStore.save_all([{"path": path, "text": text}], _save_gate, true)
	if not bool(r.get("ok", false)):
		return err(str(r.get("error", "save failed")))
	reload()
	return ok({"path": path, "bytes": text.to_utf8_buffer().size()})


# ---- internals --------------------------------------------------------------------


## ContentStore.save_all's validate callable: the errors (never the warnings), as an Array.
func _save_gate() -> Array:
	return Array(errors())


func _check_new_id(id: StringName) -> String:
	if not AchKitSchema.is_valid_id(str(id)):
		return "\"%s\": an id is 1-48 of a-z, 0-9 and _, starting with a letter" % id
	if has_id(id):
		return "\"%s\" is already an achievement" % id
	if (model.retired as Array).has(id):
		return "\"%s\" was retired; retired ids are never reused" % id
	if model.renamed.has(id):
		return "\"%s\" is an old id of \"%s\" (RENAMED); pick another id" % [
			id, AchKitSchema.canonical(id, model.renamed)]
	return ""


## Store an edited def, normalized against its kind (the form the file will have).
func _store(id: StringName, d: Dictionary) -> Dictionary:
	model.achievements[id] = AchKitSchema.normalize_def(d, _kind(StringName(str(d.get("kind", "")))))
	return _edited({"id": id})


func _edited(data: Dictionary) -> Dictionary:
	mark_dirty()
	changed.emit()
	return ok(data)


func _kind(kind: StringName) -> Dictionary:
	var k: Variant = kinds.get(kind)
	return k if typeof(k) == TYPE_DICTIONARY else {}


static func _empty_model() -> Dictionary:
	var retired: Array[StringName] = []
	return {"achievements": {}, "renamed": {}, "retired": retired}


## Keys as StringName (a hand-edited file may use plain Strings), order kept.
static func _sn_keyed(d: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in d:
		out[StringName(str(k))] = d[k]
	return out


static func _sn_renamed(d: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in d:
		out[StringName(str(k))] = StringName(str(d[k]))
	return out


## res:// and user:// paths and absolute paths are used as given; anything else is relative to
## res://.
static func _resolve(path: String) -> String:
	if path == "" or path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	return "res://".path_join(path)
