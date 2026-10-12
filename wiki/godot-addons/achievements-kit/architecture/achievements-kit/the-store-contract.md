# The store contract

**Status:** current

## Kind
component

## Summary
The duck-typed interface `AchKitTracker` persists through: any object with `read(key, default_value) -> Variant`, `write(key, value) -> void` and, optionally, `flush() -> void`. The kit ships two implementations — `AchKitMemoryStore` (an in-memory Dictionary for tests and tools) and `AchKitSaveServiceStore` (adapts a `get_var_value` / `set_var_value` save service) — and a game's own debounced save store usually satisfies the contract as-is.

## Purpose
The tracker must not depend on any particular save addon, and it must not invent its own save file: achievements belong in the same save the game already syncs, so a cloud save that mirrors the store carries them to other devices with no extra code. A three-method duck-typed contract is the smallest surface that lets any game plug its store in.

## Design notes
```gdscript
read(key: String, default_value: Variant) -> Variant
write(key: String, value: Variant) -> void
flush() -> void      # optional; called right after an earn so an earn is never lost
```

flush() is optional but strongly recommended for a debounced store: the tracker calls it immediately after writing an earn, before emitting earned, so a crash or quit right after an earn never loses it.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `AchKitMemoryStore` in `addons/achievements_kit/runtime/achkit_memory_store.gd`
- class `AchKitSaveServiceStore` in `addons/achievements_kit/runtime/achkit_save_service_store.gd`
- file `a staged/flushed fake store used to prove the write-then-flush order` in `tests/achievements_kit/fakes/fake_store.gd`

## Data model
The contract: `read(key: String, default_value: Variant) -> Variant`, `write(key: String, value: Variant) -> void`, and optionally `flush() -> void` (called right after an earn so an earn is never lost).

Keys the tracker writes, per achievement: `<earned_prefix><id>` (bool) and `<progress_prefix><id>` (int, 0..target). The prefixes come from `configure()`.

- **`AchKitMemoryStore`** — `data: Dictionary` and `flush_count: int` are public for assertions; also `has(key)` and `clear()`. Arrays and dictionaries are deep-copied on read and write. Nothing persists.
- **`AchKitSaveServiceStore.new(service)`** — forwards `read` to `service.get_var_value` and `write` to `service.set_var_value`; `flush()` calls the service's own `flush()` when it has one (a write-through service needs none).

**Cloud save.** With snapser_kit's cloud save, bools are OR-ed on every pull, so earns merge across devices for free. Ints are not maxed without a policy, so give the progress prefix a `"max"` merge policy (e.g. `"merge_policy": {"prog_achp_*": "max"}`) and choose a progress prefix the earned prefix does not match as a glob, so the policy never touches the bools.

## Usage
_None._

## Invariants & constraints
- The store contract is duck-typed; the addon depends on no save addon.
- The tracker writes only its two key families; it never erases keys (old RENAMED keys are left in place).

## Synced commit
8a8bfec
