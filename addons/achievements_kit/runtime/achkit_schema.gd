class_name AchKitSchema
extends RefCounted

## The achievements schema and validator, shared by the runtime tracker, the editor dock and a
## game's own checks. Static and pure: no editor, scene tree or addon dependencies, so it loads
## headless and in exported games.
##
## A definition (one entry of the generated file's ACHIEVEMENTS, keyed by its id):
##   {"name": String, "description": String, "kind": StringName, "target": int >= 1,
##    "params": {param: String|int|bool}, "hidden": bool, "hint": String, "icon": String,
##    "category": StringName}
## A kind (one entry of the game's hand-written KINDS):
##   {"label": String, "mode": &"count"|&"max", "doc": String,
##    "params": {param: {"type": "string"|"int"|"bool"|"enum", "values"?: Array, "default"?: v}}}
##
## Problems come back as human sentences naming the id and field ("first_clear: target must
## be >= 1"). Warnings carry the prefix "warning: " (see is_warning()): a tool shows them but
## still lets you save.

## Format version of the generated definitions file (its `const SCHEMA`).
const SCHEMA_VERSION := 1
## Every definition field, in the order the codegen writes them.
const FIELDS: Array[String] = ["name", "description", "kind", "target", "params", "hidden", "hint",
	"icon", "category"]
## count: sum every reported amount (lifetime counters, one-off flags with target 1).
## max: keep the largest single value reported ("reach round 50 in one run").
const MODES: Array[StringName] = [&"count", &"max"]
const PARAM_TYPES: Array[String] = ["string", "int", "bool", "enum"]
const ID_PATTERN := "^[a-z][a-z0-9_]{0,47}$"
const NAME_MAX := 40
const DESCRIPTION_MAX := 120
const WARNING_PREFIX := "warning: "

static var _id_re: RegEx = null


## Every problem with `defs` (id -> definition) against `kinds`, `renamed` (old id -> id) and
## `retired` (ids deleted after they may have shipped). Empty = valid. The kinds file itself is
## checked by validate_kinds(), not here.
## opts: {"check_icons": bool (default true): a non-empty icon must be an existing resource}
static func validate(defs: Dictionary, kinds: Dictionary, renamed: Dictionary = {},
		retired: Array = [], opts: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	var renamed_keys := {}
	for k: Variant in renamed:
		renamed_keys[StringName(str(k))] = true
	var retired_set := {}
	for r: Variant in retired:
		retired_set[StringName(str(r))] = true
	for id: Variant in defs:
		var sid := StringName(str(id))
		out.append_array(validate_def(sid, defs[id], kinds, opts))
		if renamed_keys.has(sid):
			out.append("%s: id is also a RENAMED key (an old id); pick another id" % sid)
		if retired_set.has(sid):
			out.append("%s: id was retired; retired ids are never reused" % sid)
	out.append_array(validate_renamed(defs, renamed))
	return out


## Problems with one definition (no cross-definition checks). The dock uses it to flag rows.
static func validate_def(id: StringName, def: Variant, kinds: Dictionary,
		opts: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	if not is_valid_id(str(id)):
		out.append("%s: id must be 1-48 of a-z, 0-9 and _, starting with a letter" % id)
	if typeof(def) != TYPE_DICTIONARY:
		out.append("%s: definition must be a Dictionary" % id)
		return out
	var d: Dictionary = def
	for k: Variant in d:
		if typeof(k) != TYPE_STRING:
			out.append("%s: field key %s must be a quoted String" % [id, var_to_str(k)])
		elif not FIELDS.has(k):
			out.append("%s: unknown field \"%s\"" % [id, k])
	for f in FIELDS:
		if not d.has(f):
			out.append("%s: missing field \"%s\"" % [id, f])
	var type_ok := {}
	for f in FIELDS:
		type_ok[f] = d.has(f) and _field_type_ok(f, d[f])
		if d.has(f) and not type_ok[f]:
			out.append("%s: %s must be %s" % [id, f, _field_type_name(f)])
	if type_ok["name"]:
		_check_text(out, id, "name", d["name"], NAME_MAX)
	if type_ok["description"]:
		_check_text(out, id, "description", d["description"], DESCRIPTION_MAX)
	if type_ok["target"] and int(d["target"]) < 1:
		out.append("%s: target must be >= 1" % id)
	var kind := {}
	if type_ok["kind"]:
		var kname := StringName(str(d["kind"]))
		if not kinds.has(kname):
			out.append("%s: kind \"%s\" is not a declared kind" % [id, kname])
		elif typeof(kinds[kname]) == TYPE_DICTIONARY:
			kind = kinds[kname]
	if type_ok["params"] and not kind.is_empty():
		var declared: Dictionary = kind.get("params", {}) if typeof(kind.get("params")) == TYPE_DICTIONARY else {}
		var params: Dictionary = d["params"]
		for p: Variant in params:
			var pname := str(p)
			if not declared.has(pname):
				out.append("%s: param \"%s\" is not declared by kind \"%s\"" % [id, pname, d["kind"]])
				continue
			var err := _param_value_problem(declared[pname], params[p])
			if err != "":
				out.append("%s: param \"%s\" %s" % [id, pname, err])
	if (type_ok["hidden"] and type_ok["hint"] and bool(d["hidden"]) and str(d["hint"]).strip_edges() == ""
			and StringName(str(kind.get("mode", ""))) == &"count"):
		out.append(WARNING_PREFIX + "%s: hidden with no hint, so players see only \"???\"" % id)
	if type_ok["icon"] and bool(opts.get("check_icons", true)):
		var icon := str(d["icon"])
		if icon != "" and not (ResourceLoader.exists(icon) or FileAccess.file_exists(icon)):
			out.append("%s: icon \"%s\" does not exist" % [id, icon])
	return out


## RENAMED problems: a cycle, or a chain that does not end at a live id (dangling).
static func validate_renamed(defs: Dictionary, renamed: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var keys: Array = renamed.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for k: Variant in keys:
		var chain: Array[StringName] = [StringName(str(k))]
		var cur := StringName(str(k))
		var cyclic := false
		while renamed.has(cur):
			cur = StringName(str(renamed[cur]))
			if chain.has(cur):
				chain.append(cur)
				cyclic = true
				break
			chain.append(cur)
		var path := " -> ".join(chain.map(func(s: StringName) -> String: return str(s)))
		if cyclic:
			out.append("RENAMED: cycle %s" % path)
		elif not defs.has(cur):
			out.append("RENAMED: %s ends at \"%s\", which is not a live achievement" % [path, cur])
	return out


## Every problem with the game's kinds file (kind name -> kind).
static func validate_kinds(kinds: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for name: Variant in kinds:
		out.append_array(validate_kind(StringName(str(name)), kinds[name]))
	return out


## Problems with one kind.
static func validate_kind(name: StringName, kind: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if str(name) == "":
		out.append("kind \"\": a kind needs a name")
	if typeof(kind) != TYPE_DICTIONARY:
		out.append("kind %s: must be a Dictionary" % name)
		return out
	var k: Dictionary = kind
	if not k.has("mode") or not _is_stringish(k["mode"]) or not MODES.has(StringName(str(k["mode"]))):
		out.append("kind %s: mode must be &\"count\" or &\"max\"" % name)
	for f in ["label", "doc"]:
		if k.has(f) and typeof(k[f]) != TYPE_STRING:
			out.append("kind %s: %s must be a String" % [name, f])
	if not k.has("params"):
		return out
	if typeof(k["params"]) != TYPE_DICTIONARY:
		out.append("kind %s: params must be a Dictionary" % name)
		return out
	var params: Dictionary = k["params"]
	for p: Variant in params:
		var spec: Variant = params[p]
		if typeof(spec) != TYPE_DICTIONARY:
			out.append("kind %s: param \"%s\" must be a Dictionary" % [name, p])
			continue
		var type := str(spec.get("type", ""))
		if not PARAM_TYPES.has(type):
			out.append("kind %s: param \"%s\" type must be one of %s" % [name, p, ", ".join(PARAM_TYPES)])
			continue
		if type == "enum":
			var values: Variant = spec.get("values")
			if typeof(values) != TYPE_ARRAY or (values as Array).is_empty():
				out.append("kind %s: enum param \"%s\" needs a non-empty values array" % [name, p])
				continue
			for v: Variant in values:
				if not _is_stringish(v):
					out.append("kind %s: enum param \"%s\" values must be Strings" % [name, p])
					break
		if spec.has("default"):
			var err := _param_value_problem(spec, spec["default"])
			if err != "":
				out.append("kind %s: param \"%s\" default %s" % [name, p, err])
	return out


## A copy of `def` with every field present (defaults filled in), kind/category as StringName,
## and params in the kind's declared order (undeclared params kept after them, sorted, so a
## bad file still round-trips for the validator to report). A param left at the kind's default
## is dropped: it matches anything either way, and dropping it keeps the generated file stable
## when a kind gains a param.
static func normalize_def(def: Dictionary, kind: Dictionary) -> Dictionary:
	var params_in: Dictionary = def.get("params", {}) if typeof(def.get("params")) == TYPE_DICTIONARY else {}
	var declared: Dictionary = kind.get("params", {}) if typeof(kind.get("params")) == TYPE_DICTIONARY else {}
	var params := {}
	for p: Variant in declared:
		var pname := str(p)
		if params_in.has(pname):
			var v: Variant = _param_literal(params_in[pname])
			if typeof(declared[p]) == TYPE_DICTIONARY and _same(v, param_default(declared[p])):
				continue
			params[pname] = v
	var extra: Array = []
	for p: Variant in params_in:
		if not declared.has(str(p)):
			extra.append(str(p))
	extra.sort()
	for pname: String in extra:
		params[pname] = _param_literal(params_in[pname])
	var target: Variant = def.get("target", 1)
	return {
		"name": str(def.get("name", "")),
		"description": str(def.get("description", "")),
		"kind": StringName(str(def.get("kind", ""))),
		"target": int(target) if typeof(target) in [TYPE_INT, TYPE_FLOAT] else 1,
		"params": params,
		"hidden": bool(def.get("hidden", false)) if typeof(def.get("hidden")) == TYPE_BOOL else false,
		"hint": str(def.get("hint", "")),
		"icon": str(def.get("icon", "")),
		"category": StringName(str(def.get("category", ""))),
	}


## Does a report's `context` satisfy `def`'s params? For each param the achievement sets to
## something other than the kind's default, context[param] must equal it. An unset param, or
## one left at its default, matches anything.
static func param_matches(def: Dictionary, kind: Dictionary, context: Dictionary) -> bool:
	var params: Variant = def.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		return true
	var declared: Dictionary = kind.get("params", {}) if typeof(kind.get("params")) == TYPE_DICTIONARY else {}
	for p: Variant in params:
		var pname := str(p)
		var want: Variant = params[p]
		if typeof(declared.get(pname)) == TYPE_DICTIONARY and _same(want, param_default(declared[pname])):
			continue
		var got: Variant = null
		if context.has(pname):
			got = context[pname]
		elif context.has(StringName(pname)):
			got = context[StringName(pname)]
		else:
			return false
		if not _same(got, want):
			return false
	return true


## The kind param's default: its "default", else "" / 0 / false, or an enum's first value.
static func param_default(spec: Dictionary) -> Variant:
	if spec.has("default"):
		return spec["default"]
	match str(spec.get("type", "")):
		"int":
			return 0
		"bool":
			return false
		"enum":
			var values: Variant = spec.get("values", [])
			return values[0] if typeof(values) == TYPE_ARRAY and not (values as Array).is_empty() else ""
	return ""


## Follow `renamed` from `id` to the id it lives under now (chains followed; a cycle stops at
## the first repeat). An id that was never renamed comes back unchanged.
static func canonical(id: StringName, renamed: Dictionary) -> StringName:
	var cur := id
	var seen := {cur: true}
	while renamed.has(cur):
		cur = StringName(str(renamed[cur]))
		if seen.has(cur):
			break
		seen[cur] = true
	return cur


static func is_valid_id(id: String) -> bool:
	if _id_re == null:
		_id_re = RegEx.create_from_string(ID_PATTERN)
	return _id_re.search(id) != null


static func is_warning(problem: String) -> bool:
	return problem.begins_with(WARNING_PREFIX)


## `problems` without the warnings (what blocks a save).
static func errors_only(problems: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for p in problems:
		if not is_warning(p):
			out.append(p)
	return out


# ---- internals -----------------------------------------------------------------

static func _field_type_ok(field: String, v: Variant) -> bool:
	match field:
		"name", "description", "hint", "icon":
			return typeof(v) == TYPE_STRING
		"kind", "category":
			return _is_stringish(v)
		"target":
			return typeof(v) == TYPE_INT
		"params":
			return typeof(v) == TYPE_DICTIONARY
		"hidden":
			return typeof(v) == TYPE_BOOL
	return false


static func _field_type_name(field: String) -> String:
	match field:
		"kind", "category":
			return "a StringName"
		"target":
			return "an int"
		"params":
			return "a Dictionary"
		"hidden":
			return "a bool"
	return "a String"


static func _check_text(out: PackedStringArray, id: StringName, field: String, v: String, max_len: int) -> void:
	if v.strip_edges() == "":
		out.append("%s: %s must not be empty" % [id, field])
	elif v.length() > max_len:
		out.append("%s: %s is %d characters (max %d)" % [id, field, v.length(), max_len])


## "" if `v` is a valid value for the param `spec`, else what's wrong ("must be an int").
static func _param_value_problem(spec: Dictionary, v: Variant) -> String:
	match str(spec.get("type", "")):
		"string":
			return "" if _is_stringish(v) else "must be a String"
		"int":
			return "" if typeof(v) == TYPE_INT else "must be an int"
		"bool":
			return "" if typeof(v) == TYPE_BOOL else "must be a bool"
		"enum":
			if not _is_stringish(v):
				return "must be a String"
			var values: Variant = spec.get("values", [])
			if typeof(values) == TYPE_ARRAY:
				for allowed: Variant in values:
					if _same(allowed, v):
						return ""
			return "\"%s\" is not one of %s" % [v, JSON.stringify(values)]
	return "has an unknown type"


## Params are written as String, int or bool literals (a StringName becomes a String).
static func _param_literal(v: Variant) -> Variant:
	return str(v) if typeof(v) == TYPE_STRING_NAME else v


static func _is_stringish(v: Variant) -> bool:
	return typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME


## Equality that never errors across types: String == StringName by text, int == float by
## value, otherwise the types must match. (Godot's == errors on e.g. String vs int.)
static func _same(a: Variant, b: Variant) -> bool:
	if _is_stringish(a) and _is_stringish(b):
		return str(a) == str(b)
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
		return a == b
	return ta == tb and a == b
