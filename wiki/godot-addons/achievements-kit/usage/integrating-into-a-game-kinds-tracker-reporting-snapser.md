# Integrating into a game — kinds, tracker, reporting & Snapser

**Status:** active

## Body
Once the dock is configured, the runtime needs four things from the game: a tracker autoload, a store, report calls wherever each kind happens, and (optionally) a reload hook and a Snapser bridge.

## The tracker autoload

Extend `AchKitTracker` and configure it in `_ready()` with the same files and prefixes as `res://achievements_kit.config.json`:

```gdscript
extends AchKitTracker
const Defs := preload("res://scripts/config/achievements.gd")
const Kinds := preload("res://scripts/config/achievement_kinds.gd")

func _ready() -> void:
	configure(Defs.ACHIEVEMENTS, Kinds.KINDS, Defs.RENAMED, Defs.RETIRED, SaveStore,
			"prog_ach_", "prog_achp_")

## Optional: refuse progress in some situations (e.g. a debug-touched run).
func _earning_allowed(_id: StringName, _kind: StringName, _context: Dictionary) -> bool:
	return true

## Optional: report what the save already implies (e.g. a best score kept elsewhere).
func _backfill() -> void:
	report(&"run_score", BestScores.best())
```

Register it as an autoload (for example `Achievements`) after your save store, so the store exists when `configure()` runs.

`configure()` validates everything. An invalid kind or definition is skipped with a `push_error` in debug builds, never a crash.

## The store

Pass any object with `read(key, default_value)`, `write(key, value)` and, ideally, `flush()`:

- a game's own debounced save store with those methods works as-is;
- `AchKitSaveServiceStore.new(service)` adapts a `get_var_value` / `set_var_value` save service;
- `AchKitMemoryStore` is an in-memory Dictionary for tests and tools.

The tracker flushes right after an earn, before it emits `earned`, so an earn survives a crash.

## Reporting from gameplay

```gdscript
Achievements.report(&"boards_cleared")                               # count: +1
Achievements.report(&"round_reached", round, {"source": "quick_play"})  # max: best value
```

- `count` kinds add `amount`; `max` kinds keep the largest single `amount`. Per-run state stays in the game: report the run's value, and the tracker keeps only the best.
- An achievement moves only when its non-default params equal `context[name]`. Unset or default-valued params match anything.
- `earn(id)` grants one achievement directly (a scripted secret); it is gated like `report()`.
- Call `begin_run()` when a run starts if you want `run_earned()` for an end-of-run screen.
- Reporting an undeclared kind warns once and does nothing; a game check should assert every declared kind is actually reported somewhere.

## Showing achievements

The kit ships no UI. Lay out its view-models with your own widgets:

- `rows(reveal_hidden := false)` — one dictionary per achievement in display order: `{id, name, description, hint, hidden, masked, earned, progress, target, fraction, kind, kind_label, category, icon}`. A masked row (hidden and unearned) reads `"???"` with an empty description and keeps its hint.
- `summary()` — `{earned, total, categories: {cat: {earned, total}}}`.
- Signals: `earned(id)` for toasts (fires after the write and flush), `progressed(id, value, target)`, `revoked(id)`, `changed` to refresh a panel, `reloaded`.

## Cloud save and reloads

The tracker keeps exactly two keys per achievement in your store, so a cloud save that mirrors the store carries achievements across devices with no extra code.

- With snapser_kit's cloud save, bools are OR-ed on every pull. Give the **progress** prefix a `"max"` merge policy (e.g. `"merge_policy": {"prog_achp_*": "max"}`) so progress never goes backwards.
- After a pull imports keys, call `reload_if_owned(keys)` (or `reload()`) from your single post-import reload point. Reload never emits `earned`, so a pull never re-fires toasts or backend events.
- Writes caused by a load (the `RENAMED` migration and `_backfill()`) run deferred at the end of the frame, never inside the import handler, where they would be suppressed as the import's own echo.

## Mirroring to Snapser (optional)

Let the game's Snapser facade own an `AchKitSnapserBridge` and pass itself, so every backend call still goes through the facade:

```gdscript
# in the game's Snapser autoload (extends SnapKitService)
var ach_bridge: AchKitSnapserBridge

func _ready() -> void:
	start()
	ach_bridge = AchKitSnapserBridge.new(self, Achievements, "achievements_earned", "achievement_earned")
```

- Each earn sends the analytics event `{id}`; a burst of earns makes one stat request, a **SET** of the earned count (idempotent).
- On boot it re-posts the count, repairing the stat after an offline session. Offline it sends nothing.
- Declare the stat (counter) and the event (`{id: string}`) on the snapend and in the game's `snapser_kit.config.json` `declared` section; undeclared names are refused.
- Keep the bridge referenced (it is `RefCounted`).
- `ach_bridge.post_count()` is a ready-made "post stat now" debug action.

## Debug actions

`debug_grant(id)`, `debug_revoke(id)`, `debug_revoke_all()` and `debug_set_progress(id, value)` bypass `_earning_allowed`; gate them behind your own debug-build check. A revoke is local: the next cloud pull ORs a remote `true` back unless you force-push afterwards (snapser_kit 0.3.0's `cloud_save_force_push()`).

## A game-side check

A cheap CI check catches most mistakes before they ship:

```gdscript
var kinds := Kinds.KINDS
var prefixes := {"earned": "prog_ach_", "progress": "prog_achp_"}
assert(AchKitCodegen.is_canonical(FileAccess.get_file_as_string(DEFS_PATH), kinds, prefixes))
assert(AchKitSchema.validate_kinds(kinds).is_empty())
assert(AchKitSchema.errors_only(AchKitSchema.validate(
		Defs.ACHIEVEMENTS, kinds, Defs.RENAMED, Defs.RETIRED)).is_empty())
```

`is_canonical` also compares the header prefixes, so it fails if the dock config and the tracker disagree.

## References
_None._

## Child pages
_None._
