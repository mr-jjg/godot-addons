extends "res://tests/achievements_kit/achkit_test_case.gd"

## AchKitSchema: every rule of validate / validate_kinds, warnings vs errors, param_matches,
## canonical, normalize_def.

const Kinds := preload("res://tests/achievements_kit/fixtures/kinds.gd")


func _def(over: Dictionary = {}) -> Dictionary:
	var d := {"name": "Clean Sweep", "description": "Clear the board.", "kind": &"boards_cleared",
		"target": 1, "params": {}, "hidden": false, "hint": "", "icon": "", "category": &""}
	d.merge(over, true)
	return d


func _problems(d: Variant, id: StringName = &"first_clear", opts: Dictionary = {}) -> PackedStringArray:
	return AchKitSchema.validate({id: d}, Kinds.KINDS, {}, [], opts)


func test_valid_set_has_no_problems() -> void:
	var defs := {
		&"first_clear": _def(),
		&"round_q": _def({"kind": &"round_reached", "target": 50, "params": {"source": "quick_play"}}),
		&"flagged": _def({"kind": &"flags", "params": {"tag": "x", "level": 3, "hard": true},
			"category": &"misc", "hidden": true, "hint": "Hmm."}),
	}
	check_eq(AchKitSchema.validate(defs, Kinds.KINDS, {&"old": &"first_clear"}, [&"gone"]),
		PackedStringArray(), "valid set")
	check_eq(AchKitSchema.validate_kinds(Kinds.KINDS), PackedStringArray(), "fixture kinds valid")
	check_eq(AchKitSchema.validate({}, Kinds.KINDS), PackedStringArray(), "empty set valid")


func test_id_pattern() -> void:
	for good: String in ["a", "x_1", "first_clear", "a".repeat(48)]:
		check(AchKitSchema.is_valid_id(good), "valid id %s" % good)
	for bad: String in ["", "First", "1abc", "a-b", "_x", "a b", "a".repeat(49), "é"]:
		check(not AchKitSchema.is_valid_id(bad), "invalid id %s" % bad)
	check_problem(_problems(_def(), &"Bad-Id"), "Bad-Id: id must be", "bad id reported")


func test_id_collides_with_renamed_or_retired() -> void:
	var defs := {&"first_clear": _def(), &"other": _def()}
	var p := AchKitSchema.validate(defs, Kinds.KINDS, {&"first_clear": &"other"}, [&"other"])
	check_problem(p, "first_clear: id is also a RENAMED key", "id is a RENAMED key")
	check_problem(p, "other: id was retired", "id is retired")


func test_fields_missing_unknown_and_types() -> void:
	var d := _def()
	d.erase("hint")
	check_problem(_problems(d), "first_clear: missing field \"hint\"", "missing field")
	check_problem(_problems(_def({"colour": "red"})), "unknown field \"colour\"", "unknown field")
	check_problem(_problems(_def({"name": 5})), "name must be a String", "name type")
	check_problem(_problems(_def({"target": "3"})), "target must be an int", "target type")
	check_problem(_problems(_def({"target": 3.0})), "target must be an int", "float target")
	check_problem(_problems(_def({"hidden": 1})), "hidden must be a bool", "hidden type")
	check_problem(_problems(_def({"params": []})), "params must be a Dictionary", "params type")
	check_problem(_problems(_def({"kind": 5})), "kind must be a StringName", "kind type")
	check_problem(_problems(_def({"icon": null})), "icon must be a String", "icon type")
	check_problem(_problems("nope"), "definition must be a Dictionary", "def not a dict")
	# A Lua-style / StringName key is ambiguous: keys must be quoted Strings.
	var sn_key := {&"name": "X", "description": "D", "kind": &"boards_cleared", "target": 1,
		"params": {}, "hidden": false, "hint": "", "icon": "", "category": &""}
	check_problem(_problems(sn_key), "must be a quoted String", "StringName field key")
	# String kind/category are accepted (the codegen writes them as StringNames).
	check_eq(_problems(_def({"kind": "boards_cleared", "category": "c"})), PackedStringArray(),
		"String kind/category ok")


func test_text_limits_and_target() -> void:
	check_problem(_problems(_def({"name": ""})), "name must not be empty", "empty name")
	check_problem(_problems(_def({"description": "   "})), "description must not be empty", "blank desc")
	check_problem(_problems(_def({"name": "n".repeat(41)})), "name is 41 characters (max 40)", "long name")
	check_eq(_problems(_def({"name": "n".repeat(40)})), PackedStringArray(), "40-char name ok")
	check_problem(_problems(_def({"description": "d".repeat(121)})), "(max 120)", "long description")
	check_problem(_problems(_def({"target": 0})), "first_clear: target must be >= 1", "target 0")
	check_problem(_problems(_def({"target": -4})), "target must be >= 1", "negative target")


func test_kind_and_params() -> void:
	check_problem(_problems(_def({"kind": &"nope"})), "kind \"nope\" is not a declared kind", "unknown kind")
	check_problem(_problems(_def({"params": {"source": "x"}})),
		"param \"source\" is not declared by kind \"boards_cleared\"", "undeclared param")
	var r := {"kind": &"round_reached"}
	check_problem(_problems(_def(r.merged({"params": {"source": "sampler"}}))),
		"\"sampler\" is not one of", "enum value not in values")
	check_problem(_problems(_def(r.merged({"params": {"source": 3}}))), "must be a String", "enum type")
	check_eq(_problems(_def(r.merged({"params": {"source": &"curated"}}))), PackedStringArray(),
		"StringName enum value ok")
	var f := {"kind": &"flags"}
	check_problem(_problems(_def(f.merged({"params": {"tag": 1}}))), "param \"tag\" must be a String", "string")
	check_problem(_problems(_def(f.merged({"params": {"level": "1"}}))), "param \"level\" must be an int", "int")
	check_problem(_problems(_def(f.merged({"params": {"hard": 1}}))), "param \"hard\" must be a bool", "bool")


func test_hidden_count_without_hint_is_a_warning() -> void:
	var p := _problems(_def({"hidden": true, "hint": ""}))
	check_eq(p.size(), 1, "one problem")
	check(p.size() == 1 and AchKitSchema.is_warning(p[0]), "it is a warning: %s" % var_to_str(p))
	check_eq(AchKitSchema.errors_only(p), PackedStringArray(), "no errors")
	check_eq(_problems(_def({"hidden": true, "hint": "Look up."})), PackedStringArray(), "with hint")
	check_eq(_problems(_def({"hidden": true, "kind": &"round_reached", "target": 5})), PackedStringArray(),
		"max kind: no warning")
	var mixed := _problems(_def({"hidden": true, "target": 0}))
	check_eq(AchKitSchema.errors_only(mixed).size(), 1, "errors_only keeps the error")


func test_icons() -> void:
	check_problem(_problems(_def({"icon": "res://nope/missing.png"})), "icon \"res://nope/missing.png\" does not exist",
		"missing icon")
	check_eq(_problems(_def({"icon": "res://nope/missing.png"}), &"first_clear", {"check_icons": false}),
		PackedStringArray(), "check_icons false")
	check_eq(_problems(_def({"icon": "res://tests/achievements_kit/fixtures/kinds.gd"})), PackedStringArray(),
		"existing resource ok")


func test_renamed_dangling_and_cycle() -> void:
	var defs := {&"first_clear": _def()}
	check_problem(AchKitSchema.validate(defs, Kinds.KINDS, {&"a": &"nope"}), "not a live achievement", "dangling")
	check_problem(AchKitSchema.validate(defs, Kinds.KINDS, {&"a": &"b", &"b": &"a"}), "RENAMED: cycle", "cycle")
	check_problem(AchKitSchema.validate(defs, Kinds.KINDS, {&"a": &"a"}), "RENAMED: cycle", "self cycle")
	check_eq(AchKitSchema.validate(defs, Kinds.KINDS, {&"a": &"b", &"b": &"first_clear"}), PackedStringArray(),
		"chain ending at a live id")
	check_problem(AchKitSchema.validate(defs, Kinds.KINDS, {&"a": &"gone"}, [&"gone"]), "not a live achievement",
		"renamed to a retired id")


func test_validate_kinds() -> void:
	var bad := {
		&"m": {"mode": &"sum"},
		&"nomode": {"label": "x"},
		&"t": {"mode": &"count", "params": {"p": {"type": "float"}}},
		&"e": {"mode": &"count", "params": {"p": {"type": "enum"}}},
		&"e2": {"mode": &"count", "params": {"p": {"type": "enum", "values": []}}},
		&"d": {"mode": &"max", "params": {"p": {"type": "enum", "values": ["a", "b"], "default": "c"}}},
		&"i": {"mode": &"count", "params": {"p": {"type": "int", "default": "0"}}},
		&"nd": "not a dict",
		&"lbl": {"mode": &"count", "label": 3},
	}
	var p := AchKitSchema.validate_kinds(bad)
	check_problem(p, "kind m: mode must be", "unknown mode")
	check_problem(p, "kind nomode: mode must be", "missing mode")
	check_problem(p, "kind t: param \"p\" type must be one of", "unknown param type")
	check_problem(p, "kind e: enum param \"p\" needs a non-empty values", "enum without values")
	check_problem(p, "kind e2: enum param \"p\" needs a non-empty values", "enum with empty values")
	check_problem(p, "kind d: param \"p\" default \"c\" is not one of", "default not in values")
	check_problem(p, "kind i: param \"p\" default must be an int", "default wrong type")
	check_problem(p, "kind nd: must be a Dictionary", "kind not a dict")
	check_problem(p, "kind lbl: label must be a String", "label type")
	check_eq(AchKitSchema.validate_kinds({&"ok": {"mode": "count"}}), PackedStringArray(), "String mode ok")


func test_param_matches() -> void:
	var kind: Dictionary = Kinds.KINDS[&"round_reached"]
	var any := _def({"kind": &"round_reached", "params": {}})
	check(AchKitSchema.param_matches(any, kind, {}), "unset matches empty context")
	check(AchKitSchema.param_matches(any, kind, {"source": "curated"}), "unset matches anything")
	var at_default := _def({"kind": &"round_reached", "params": {"source": ""}})
	check(AchKitSchema.param_matches(at_default, kind, {"source": "curated"}), "default matches anything")
	check(AchKitSchema.param_matches(at_default, kind, {}), "default matches no context")
	var quick := _def({"kind": &"round_reached", "params": {"source": "quick_play"}})
	check(AchKitSchema.param_matches(quick, kind, {"source": "quick_play"}), "specific matches equal")
	check(AchKitSchema.param_matches(quick, kind, {"source": &"quick_play"}), "StringName context matches")
	check(not AchKitSchema.param_matches(quick, kind, {"source": "curated"}), "specific rejects other")
	check(not AchKitSchema.param_matches(quick, kind, {}), "specific rejects missing")
	check(not AchKitSchema.param_matches(quick, kind, {"source": 3}), "type mismatch is no match (no error)")
	var fk: Dictionary = Kinds.KINDS[&"flags"]
	var lvl := _def({"kind": &"flags", "params": {"level": 3, "hard": true}})
	check(AchKitSchema.param_matches(lvl, fk, {"level": 3, "hard": true, "tag": "z"}), "int+bool match")
	check(not AchKitSchema.param_matches(lvl, fk, {"level": 2, "hard": true}), "int differs")
	check(not AchKitSchema.param_matches(lvl, fk, {"level": "3", "hard": true}), "int vs String")


func test_canonical_follows_chains() -> void:
	var renamed := {&"a": &"b", &"b": &"c"}
	check_eq(AchKitSchema.canonical(&"a", renamed), &"c", "two hops")
	check_eq(AchKitSchema.canonical(&"b", renamed), &"c", "one hop")
	check_eq(AchKitSchema.canonical(&"c", renamed), &"c", "live id unchanged")
	check_eq(AchKitSchema.canonical(&"zzz", renamed), &"zzz", "unknown unchanged")
	var c := AchKitSchema.canonical(&"x", {&"x": &"y", &"y": &"x"})
	check(c == &"x" or c == &"y", "a cycle terminates")


func test_normalize_def() -> void:
	var fk: Dictionary = Kinds.KINDS[&"flags"]
	var n := AchKitSchema.normalize_def({"name": "N", "kind": "flags",
		"params": {"zz": 1, "hard": true, "tag": &"t", "level": 0}}, fk)
	check_eq(n.keys(), ["name", "description", "kind", "target", "params", "hidden", "hint", "icon", "category"],
		"field order")
	check_eq(n.kind, &"flags", "kind is a StringName")
	check_eq(n.category, &"", "category default")
	check_eq(n.target, 1, "target default")
	check_eq(n.hidden, false, "hidden default")
	check_eq(n.params.keys(), ["tag", "hard", "zz"], "kind order, default-valued dropped, extras sorted after")
	check_eq(n.params.tag, "t", "StringName param written as String")
