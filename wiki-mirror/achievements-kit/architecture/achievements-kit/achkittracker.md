# AchKitTracker

**Status:** current

## Kind
service

## Summary
`runtime/achkit_tracker.gd` — `class_name AchKitTracker extends Node`, the runtime a game extends as an autoload. It is configured once with the definitions, the kinds, `RENAMED`, `RETIRED`, a save store and the two key prefixes; turns `report(kind, amount, context)` calls into progress and earns; answers queries (including old ids through `RENAMED`); builds view-model rows for the game's UI; and exposes debug actions and four virtuals for game policy.

## Purpose
Gameplay should only have to say what happened (`report(&"boards_cleared")`, `report(&"round_reached", 37, {"source": "quick_play"})`) and never know which achievements care. The tracker indexes valid definitions by kind, so one report moves every matching achievement, and it owns every write to the per-player keys — in an order that makes the earned signal safe to act on (toasts, a backend mirror) without any `call_deferred` workaround.

## Design notes
Write order on earn: progress is set to the target, the earned bool is written, the store is flushed (when it has flush()), the id is appended to run_earned(), and only then do earned and changed fire. A listener always sees is_earned(id) == true and the key already in the store.

Load-caused writes are deferred. After configure() and every reload(), one pass runs at the end of the frame: the RENAMED migration (an old id's true carries over, progress takes the larger of old and new, old keys are left in place, idempotent), then _backfill(). Writing inside a cloud-save import handler would be suppressed as the import's own echo, so these writes never happen inside the load. Tests and checks must wait a frame or two after configure() before asserting migrated state.

Lowering a target caps stored progress on load; the next report of that kind earns it. There is no auto-earn at load time.

Revoke is local: debug_revoke* writes false / 0. A cloud pull ORs a remote true back, so a revoke only sticks on an account after a forced push (another device still holding true restores it on its next sync).

## Components
_No components._

## Dependencies
- **calls** → [Definitions & kinds — AchKitSchema and AchKitCodegen](architecture:mv5fixl0-003c-7e7qqh) — AchKitSchema validates kinds and definitions at configure(); param_matches is the default _matches.
- **depends-on** → [The store contract](architecture:mv5fixod-003e-th0tx2) — all reads and writes of the per-player keys.

## Code references
- function `configure() — validate, index by kind, read the store, queue the post-load pass` in `addons/achievements_kit/runtime/achkit_tracker.gd`
- function `report() / earn() — the gated progress and earn paths` in `addons/achievements_kit/runtime/achkit_tracker.gd`
- function `_do_earn() — write, flush, then emit` in `addons/achievements_kit/runtime/achkit_tracker.gd`
- function `_migrate_renamed() — the deferred RENAMED migration` in `addons/achievements_kit/runtime/achkit_tracker.gd`
- function `rows() / summary() — the UI view-models` in `addons/achievements_kit/runtime/achkit_tracker.gd`
- file `tracker tests (probe tracker + staged/flushed fake store)` in `tests/achievements_kit/test_tracker.gd`

## Data model
**Setup** — `configure(defs, kinds, renamed, retired, store, earned_prefix, progress_prefix)`. Validates the kinds and the definitions with `AchKitSchema` (each problem is a `push_error` in a debug build via the `_error` hook); an invalid kind or definition is **skipped, never fatal**. Then reads the store and queues the deferred post-load pass.

**Signals** (all fire after the write): `earned(id)` after the bool is written *and flushed* (local earn or `debug_grant`; never on reload); `progressed(id, value, target)` on change only; `revoked(id)`; `changed` (earn / revoke / reload, not per progress tick); `reloaded`.

**Reporting** — `report(kind, amount := 1, context := {})`: for each unearned achievement of that kind whose params match `context` (`_matches`) and that the game allows (`_earning_allowed`): `count` adds `amount`, `max` keeps `max(progress, amount)`, clamped to the target; earns at the target. `earn(id) -> bool` is a scripted grant, gated like `report()`. `begin_run()` clears `run_earned()`.

**Queries** — `ids()`, `definition(id)`, `kind_of(id)`, `is_earned(id)`, `progress(id)` (the target once earned), `target(id)`, `earned_count()`, `total_count()`, `run_earned()`, `earned_key(id)`, `progress_key(id)`. Every query follows `RENAMED`.

**View-models** — `rows(reveal_hidden := false)` returns `{id, name, description, hint, hidden, masked, earned, progress, target, fraction, kind, kind_label, category, icon}` in display order; a masked row (hidden, unearned, not revealed) has name `"???"`, an empty description, and keeps its hint. `summary()` returns `{earned, total, categories: {cat: {earned, total}}}`.

**Reload** — `owns_key(key)`, `reload_if_owned(keys) -> bool`, `reload()` (re-reads; emits `changed` + `reloaded`, never `earned`). A game calls these from its single "after a cloud pull" point.

**Debug** (bypass the gate; never called by gameplay) — `debug_grant(id)`, `debug_revoke(id)`, `debug_revoke_all()`, `debug_set_progress(id, value)`.

**Virtuals** — `_earning_allowed(id, kind, context) -> bool` (e.g. refuse progress in a debug-touched run), `_matches(def, kind, context) -> bool` (default: `AchKitSchema.param_matches`), `_backfill()` (report what the save already implies), and the log hooks `_warn(msg)`, `_error(msg)`.

## Usage
_None._

## Invariants & constraints
- earned, progressed and revoked fire only after the value is written; earned only after the store is flushed.
- An earned achievement is final for report(): it is skipped with no writes.
- Progress is always clamped to [0, target]; progress(id) answers the target once earned.
- reload() never emits earned, so a cloud pull never re-fires toasts or backend events.
- An undeclared kind passed to report() warns once per kind per tracker instance and does nothing.
- Writes caused by a load (RENAMED migration, _backfill) run deferred, never inside configure() or reload().
- Debug actions bypass _earning_allowed; gameplay never calls them.

## Synced commit
8a8bfec
