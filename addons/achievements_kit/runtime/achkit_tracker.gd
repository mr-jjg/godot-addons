class_name AchKitTracker
extends Node

## Game-agnostic achievements runtime. A game extends it as an autoload, calls configure() once
## with its definitions, kinds and save store, and reports what happens in play:
##
##   extends AchKitTracker
##   const Defs := preload("res://scripts/config/achievements.gd")
##   const Kinds := preload("res://scripts/config/achievement_kinds.gd")
##   func _ready() -> void:
##       configure(Defs.ACHIEVEMENTS, Kinds.KINDS, Defs.RENAMED, Defs.RETIRED, SaveStore,
##               "prog_ach_", "prog_achp_")
##   ...
##   report(&"boards_cleared")                 # count kind: +1
##   report(&"round_reached", 37, {"source": "quick_play"})   # max kind: best value seen
##
## Per-player truth is two save keys per achievement: <earned_prefix><id> (bool, earned) and
## <progress_prefix><id> (int, capped at the target). Nothing else is persisted, so a cloud save
## that mirrors the store carries achievements across devices with no extra code.
##
## Store contract (duck-typed; Ballgame's SaveStore satisfies it as-is):
##   read(key: String, default_value: Variant) -> Variant
##   write(key: String, value: Variant) -> void
##   flush() -> void      (optional; called right after an earn so an earn is never lost)
## AchKitSaveServiceStore adapts a get_var_value/set_var_value service; AchKitMemoryStore is a
## Dictionary for tests and tools.
##
## Signals fire AFTER the value is written (and, for `earned`, flushed), so a listener reads
## is_earned(id) == true and the store already holds the key.

## After the bool is written AND flushed (a local earn or a debug grant). Never on reload().
signal earned(id: StringName)
## After the progress int is written; only when it changed.
signal progressed(id: StringName, value: int, target: int)
## A debug revoke, after the write.
signal revoked(id: StringName)
## Earn, revoke, reset or reload (not per progress tick).
signal changed
## After reload() re-read the store.
signal reloaded

var _store: Object = null
var _earned_prefix := ""
var _progress_prefix := ""
var _kinds: Dictionary = {}           ## kind -> kind dict (valid kinds only)
var _defs: Dictionary = {}            ## id -> normalized def, display order (valid defs only)
var _by_kind: Dictionary = {}         ## kind -> Array[StringName] of ids
var _renamed: Dictionary = {}         ## old id -> id
var _retired: Array[StringName] = []
var _earned_now: Dictionary = {}      ## id -> bool
var _progress_now: Dictionary = {}    ## id -> int
var _run_earned: Array[StringName] = []
var _warned_kinds: Dictionary = {}
var _post_load_queued := false
var _configured := false


## Wire everything and load. Validates (one error per problem in a debug build; invalid kinds
## and definitions are skipped, not fatal), indexes definitions by kind, reads the store, then
## schedules the deferred post-load pass (RENAMED migration, then _backfill()).
func configure(defs: Dictionary, kinds: Dictionary, renamed: Dictionary, retired: Array,
		store: Object, earned_prefix: String, progress_prefix: String) -> void:
	_kinds = {}
	for k: Variant in kinds:
		var kname := StringName(str(k))
		var problems := AchKitSchema.validate_kind(kname, kinds[k])
		for p in problems:
			_error("[AchKit] " + p)
		if problems.is_empty():
			_kinds[kname] = kinds[k]
	_renamed = {}
	for k: Variant in renamed:
		_renamed[StringName(str(k))] = StringName(str(renamed[k]))
	_retired = []
	for r: Variant in retired:
		_retired.append(StringName(str(r)))
	_defs = {}
	_by_kind = {}
	var check := {"check_icons": false}
	for id: Variant in defs:
		var sid := StringName(str(id))
		var problems := AchKitSchema.errors_only(AchKitSchema.validate_def(sid, defs[id], _kinds, check))
		if _renamed.has(sid) or _retired.has(sid):
			problems.append("%s: id is also a RENAMED key or RETIRED; skipped" % sid)
		if not problems.is_empty():
			for p in problems:
				_error("[AchKit] " + p)
			continue
		var def := AchKitSchema.normalize_def(defs[id], _kinds[StringName(str(defs[id]["kind"]))])
		_defs[sid] = def
		if not _by_kind.has(def.kind):
			var bucket: Array[StringName] = []
			_by_kind[def.kind] = bucket
		(_by_kind[def.kind] as Array[StringName]).append(sid)
	for p in AchKitSchema.validate_renamed(defs, renamed):
		_error("[AchKit] " + p)
	if store == null:
		_error("[AchKit] configure(): no store; using an in-memory store (nothing persists)")
		store = AchKitMemoryStore.new()
	_store = store
	_earned_prefix = earned_prefix
	_progress_prefix = progress_prefix
	_warned_kinds = {}
	_run_earned = []
	_configured = true
	_read_store()
	_queue_post_load()


# ---- reload (called by the game's single reload point) ---------------------------------

## The key is one of this tracker's (starts with either prefix).
func owns_key(key: String) -> bool:
	return (_earned_prefix != "" and key.begins_with(_earned_prefix)) \
		or (_progress_prefix != "" and key.begins_with(_progress_prefix))


## reload() when any of `keys` is owned. Returns whether it did.
func reload_if_owned(keys: PackedStringArray) -> bool:
	for k in keys:
		if owns_key(k):
			reload()
			return true
	return false


## Re-read every value from the store (after a cloud pull or any import). Emits changed and
## reloaded; never earned (what arrived was earned elsewhere). Schedules the post-load pass.
func reload() -> void:
	if not _configured:
		return
	_read_store()
	changed.emit()
	reloaded.emit()
	_queue_post_load()


# ---- queries -----------------------------------------------------------------------

## Live ids in display order.
func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in _defs:
		out.append(id)
	return out


## The normalized definition, or {} for an unknown id. Old (renamed) ids resolve.
func definition(id: StringName) -> Dictionary:
	var cid := _canon(id)
	return (_defs[cid] as Dictionary).duplicate(true) if _defs.has(cid) else {}


## The kind dict of `id`'s kind, or {}.
func kind_of(id: StringName) -> Dictionary:
	var cid := _canon(id)
	if not _defs.has(cid):
		return {}
	return (_kinds.get(_defs[cid].kind, {}) as Dictionary).duplicate(true)


func is_earned(id: StringName) -> bool:
	return bool(_earned_now.get(_canon(id), false))


## Progress toward the target (the target itself once earned).
func progress(id: StringName) -> int:
	var cid := _canon(id)
	if not _defs.has(cid):
		return 0
	if is_earned(cid):
		return target(cid)
	return int(_progress_now.get(cid, 0))


func target(id: StringName) -> int:
	var cid := _canon(id)
	return int(_defs[cid].target) if _defs.has(cid) else 0


## Earned live ids (retired or unknown keys in the store never count).
func earned_count() -> int:
	var n := 0
	for id: StringName in _defs:
		if _earned_now.get(id, false):
			n += 1
	return n


func total_count() -> int:
	return _defs.size()


## Ids earned since the last begin_run(), in the order earned.
func run_earned() -> Array[StringName]:
	return _run_earned.duplicate()


func earned_key(id: StringName) -> String:
	return _earned_prefix + str(id)


func progress_key(id: StringName) -> String:
	return _progress_prefix + str(id)


## View-model rows in display order, for a game's own achievements screen:
## {id, name, description, hint, hidden, masked, earned, progress, target, fraction, kind,
##  kind_label, category, icon}. masked = hidden and not earned and not reveal_hidden; a masked
## row has name "???" and description "" and keeps its hint.
func rows(reveal_hidden: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: StringName in _defs:
		var d: Dictionary = _defs[id]
		var got := is_earned(id)
		var masked: bool = d.hidden and not got and not reveal_hidden
		var tgt: int = d.target
		var prog := progress(id)
		var kind: Dictionary = _kinds.get(d.kind, {})
		out.append({
			"id": id,
			"name": "???" if masked else d.name,
			"description": "" if masked else d.description,
			"hint": d.hint,
			"hidden": d.hidden,
			"masked": masked,
			"earned": got,
			"progress": prog,
			"target": tgt,
			"fraction": 1.0 if got else clampf(float(prog) / float(maxi(tgt, 1)), 0.0, 1.0),
			"kind": d.kind,
			"kind_label": str(kind.get("label", d.kind)),
			"category": d.category,
			"icon": d.icon,
		})
	return out


## {earned, total, categories: {category: {earned, total}}}; categories in first-use order,
## &"" for uncategorised.
func summary() -> Dictionary:
	var cats := {}
	for id: StringName in _defs:
		var cat: StringName = _defs[id].category
		if not cats.has(cat):
			cats[cat] = {"earned": 0, "total": 0}
		cats[cat].total += 1
		if is_earned(id):
			cats[cat].earned += 1
	return {"earned": earned_count(), "total": total_count(), "categories": cats}


# ---- reporting ----------------------------------------------------------------------

## Something happened in play. count kinds: progress += amount; max kinds: progress =
## max(progress, amount). Capped at the target; earns at progress >= target. Only this kind's
## unearned achievements whose params match `context` (_matches) and that the game allows
## (_earning_allowed) move; an earned one is skipped with no writes. An unknown kind warns once
## and does nothing.
func report(kind: StringName, amount: int = 1, context: Dictionary = {}) -> void:
	if not _kinds.has(kind):
		if not _warned_kinds.has(kind):
			_warned_kinds[kind] = true
			_warn("[AchKit] report(): unknown kind \"%s\" (not in the kinds file); ignored" % kind)
		return
	if not _by_kind.has(kind):
		return
	var k: Dictionary = _kinds[kind]
	var is_max := StringName(str(k.get("mode", ""))) == &"max"
	for id: StringName in (_by_kind[kind] as Array[StringName]):
		if _earned_now.get(id, false):
			continue
		var d: Dictionary = _defs[id]
		if not _matches(d, k, context):
			continue
		if not _earning_allowed(id, kind, context):
			continue
		var tgt: int = d.target
		var old := int(_progress_now.get(id, 0))
		var now := maxi(old, amount) if is_max else old + amount
		now = clampi(now, 0, tgt)
		if now != old:
			_set_progress(id, now)
		if now >= tgt:
			_do_earn(id)


## Grant `id` directly (a scripted secret). Gated like report(). True if newly earned.
func earn(id: StringName) -> bool:
	var cid := _canon(id)
	if not _defs.has(cid):
		_warn("[AchKit] earn(): unknown achievement \"%s\"" % id)
		return false
	if is_earned(cid):
		return false
	if not _earning_allowed(cid, _defs[cid].kind, {}):
		return false
	_do_earn(cid)
	return true


## A run started: run_earned() starts empty.
func begin_run() -> void:
	_run_earned.clear()


# ---- debug (bypass the gate; never called by gameplay) ------------------------------------

## Earn `id` now (emits earned, so a toast and any Snapser mirror fire).
func debug_grant(id: StringName) -> void:
	var cid := _canon(id)
	if _defs.has(cid) and not is_earned(cid):
		_do_earn(cid)


## Write false / 0 and emit revoked. Local only: a cloud pull ORs a remote true back.
func debug_revoke(id: StringName) -> void:
	var cid := _canon(id)
	if not _defs.has(cid):
		return
	_revoke(cid)
	changed.emit()


## Revoke every earned or progressed achievement; one changed at the end.
func debug_revoke_all() -> void:
	var any := false
	for id: StringName in _defs:
		if is_earned(id) or int(_progress_now.get(id, 0)) > 0:
			_revoke(id)
			any = true
	if any:
		changed.emit()


## Set progress (clamped to 0..target). Reaching the target earns.
func debug_set_progress(id: StringName, value: int) -> void:
	var cid := _canon(id)
	if not _defs.has(cid):
		return
	var tgt: int = _defs[cid].target
	var now := clampi(value, 0, tgt)
	if now != int(_progress_now.get(cid, 0)):
		_set_progress(cid, now)
	if now >= tgt and not is_earned(cid):
		_do_earn(cid)


# ---- virtuals for the game subclass ------------------------------------------------------

## May `id` move or earn right now? Default true. Ballgame: false inside a Debug-touched run.
func _earning_allowed(_id: StringName, _kind: StringName, _context: Dictionary) -> bool:
	return true


## Do a report's `context` and `def`'s params match? Default AchKitSchema.param_matches.
func _matches(def: Dictionary, kind: Dictionary, context: Dictionary) -> bool:
	return AchKitSchema.param_matches(def, kind, context)


## Report values the save already implies (e.g. a best score kept elsewhere). Runs deferred
## after configure() and every reload(), after the RENAMED migration. Default no-op.
func _backfill() -> void:
	pass


## Log hooks (a test subclass may capture them).
func _warn(message: String) -> void:
	push_warning(message)


func _error(message: String) -> void:
	if OS.is_debug_build():
		push_error(message)


# ---- internals -----------------------------------------------------------------------

func _canon(id: StringName) -> StringName:
	return AchKitSchema.canonical(id, _renamed)


func _read_store() -> void:
	_earned_now = {}
	_progress_now = {}
	for id: StringName in _defs:
		_earned_now[id] = _read_bool(earned_key(id))
		_progress_now[id] = clampi(_read_int(progress_key(id)), 0, int(_defs[id].target))


func _read_bool(key: String) -> bool:
	var v: Variant = _store.read(key, false)
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
	return false


func _read_int(key: String) -> int:
	var v: Variant = _store.read(key, 0)
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return int(v)
		TYPE_BOOL:
			return 1 if v else 0
	return 0


func _set_progress(id: StringName, value: int) -> void:
	_store.write(progress_key(id), value)
	_progress_now[id] = value
	progressed.emit(id, value, int(_defs[id].target))


## Write progress = target and the bool, flush, record, and only then emit.
func _do_earn(id: StringName) -> void:
	var tgt: int = _defs[id].target
	if int(_progress_now.get(id, 0)) != tgt:
		_store.write(progress_key(id), tgt)
		_progress_now[id] = tgt
	_store.write(earned_key(id), true)
	_earned_now[id] = true
	_flush()
	if not _run_earned.has(id):
		_run_earned.append(id)
	earned.emit(id)
	changed.emit()


func _revoke(id: StringName) -> void:
	_store.write(earned_key(id), false)
	_store.write(progress_key(id), 0)
	_earned_now[id] = false
	_progress_now[id] = 0
	_run_earned.erase(id)
	_flush()
	revoked.emit(id)


func _flush() -> void:
	if _store.has_method("flush"):
		_store.flush()


## Writes caused by a load never run inside the load (a cloud-save import handler would
## suppress them as its own echo): queue one pass for the end of the frame.
func _queue_post_load() -> void:
	if _post_load_queued:
		return
	_post_load_queued = true
	_post_load.call_deferred()


func _post_load() -> void:
	_post_load_queued = false
	if not _configured:
		return
	if _migrate_renamed():
		changed.emit()
	_backfill()


## For each old id -> canonical id: carry an earned bool over (OR) and keep the larger progress.
## Old keys are left in place (harmless; the store has no erase). Idempotent. -> anything written
func _migrate_renamed() -> bool:
	var wrote_bool := false
	var any := false
	for old: StringName in _renamed:
		var to := _canon(old)
		if not _defs.has(to) or _defs.has(old):
			continue
		var tgt: int = _defs[to].target
		if _read_bool(earned_key(old)) and not _earned_now.get(to, false):
			_store.write(earned_key(to), true)
			_earned_now[to] = true
			wrote_bool = true
			any = true
		var p := clampi(maxi(_read_int(progress_key(old)), int(_progress_now.get(to, 0))), 0, tgt)
		if p != int(_progress_now.get(to, 0)):
			_store.write(progress_key(to), p)
			_progress_now[to] = p
			any = true
	if wrote_bool:
		_flush()
	return any
