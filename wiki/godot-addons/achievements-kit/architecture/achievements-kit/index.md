# Achievements Kit

**Status:** current

## Kind
package

## Summary
**Achievements Kit** (`addons/achievements_kit/`) — game-agnostic achievements in four runtime pieces and one editor piece. `AchKitTracker` (a `Node` the game extends as an autoload) turns `report(kind, amount, context)` calls into progress and earns, persisted as two keys per achievement in the game's own save store. `AchKitSchema` is the single validator shared by the runtime, the dock and a game's own checks. `AchKitCodegen` reads and writes the game's **definitions file** — plain, generated GDScript consts — byte-for-byte deterministically. `AchKitSnapserBridge` is an optional duck-typed adapter that mirrors earns onto a Snapser service. The **Achievements** bottom-panel dock (Editor Tool Kit) is where designers author the definitions. **Vendored** into a consuming project under `addons/achievements_kit/` yet **sourced** from this repo and self-updated by etk.

## Purpose
Achievements are the same problem in every game: a list of goals, a way for gameplay to say "this happened", per-player progress that survives restarts and devices, a backend mirror, and a way for a designer to add a goal without a programmer. The kit solves the shared part once and leaves the game-shaped parts to the game.

Two rules from the kinds model cover nearly every achievement: a `count` kind sums what is reported (lifetime counters, one-off flags with target 1) and a `max` kind keeps the largest single value ("reach round 50 in one run"). Per-run state stays in the game; the tracker only keeps the best value. Because **ids are save keys**, renames and deletions are recorded in the definitions file (`RENAMED`, `RETIRED`) so no player ever loses what they earned.

The kit deliberately ships **no in-game UI**: consuming games have unrelated UI stacks, so the contract is view-model rows, a summary, signals and debug actions, and each game lays them out with its own widgets.

## Design notes
_No design notes._

## Components
- [AchKitTracker](architecture:mv5fixit-003a-4rlniu)
- [Definitions & kinds — AchKitSchema and AchKitCodegen](architecture:mv5fixl0-003c-7e7qqh)
- [The store contract](architecture:mv5fixod-003e-th0tx2)
- [AchKitSnapserBridge](architecture:mv5fixrb-003g-wczuch)
- [Achievements dock](architecture:mv5fixtb-003i-4o3p5x)

## Dependencies
- **depends-on** → [Editor Tool Kit](architecture:mql3ccsv-01q2-v81c5e) — the dock and plugin.gd only (EditorToolPlugin / ToolService bases) plus the self-update dock; the runtime and codegen never depend on it.
- **owns** → [AchKitTracker](architecture:mv5fixit-003a-4rlniu) — the runtime a game extends as an autoload.
- **owns** → [Definitions & kinds — AchKitSchema and AchKitCodegen](architecture:mv5fixl0-003c-7e7qqh) — schema, validator and the generated-file reader/writer.
- **exposes** → [The store contract](architecture:mv5fixod-003e-th0tx2) — the duck-typed persistence interface a game's save satisfies.
- **owns** → [AchKitSnapserBridge](architecture:mv5fixrb-003g-wczuch) — optional backend mirror.
- **owns** → [Achievements dock](architecture:mv5fixtb-003i-4o3p5x) — the designer-facing editor.

## Code references
- class `AchKitTracker — the runtime tracker a game extends` in `addons/achievements_kit/runtime/achkit_tracker.gd`
- class `AchKitSchema — validator shared by runtime, dock and checks` in `addons/achievements_kit/runtime/achkit_schema.gd`
- class `AchKitCodegen — parse / serialize the definitions file` in `addons/achievements_kit/codegen/achkit_codegen.gd`
- class `AchKitSnapserBridge — duck-typed Snapser mirror` in `addons/achievements_kit/runtime/achkit_snapser_bridge.gd`
- class `AchKitMemoryStore — in-memory store for tests and tools` in `addons/achievements_kit/runtime/achkit_memory_store.gd`
- class `AchKitSaveServiceStore — adapts a get_var_value / set_var_value save service` in `addons/achievements_kit/runtime/achkit_save_service_store.gd`
- file `the dock's headless ToolService` in `addons/achievements_kit/editor/achievements_editor_service.gd`
- file `the bottom-panel view` in `addons/achievements_kit/editor/dock.gd`
- file `version + [update] marker (the ship signal)` in `addons/achievements_kit/plugin.cfg`
- file `headless test runner` in `tests/achievements_kit/run_tests.gd`

## Data model
Folders and what may depend on what:

- **`runtime/`** — `achkit_tracker.gd`, `achkit_schema.gd`, `achkit_snapser_bridge.gd`, `achkit_memory_store.gd`, `achkit_save_service_store.gd`. No dependencies: not on `snapser_kit`, not on `editor_tool_kit`, not on any save addon. Loads headless and in exported games.
- **`codegen/`** — `achkit_codegen.gd`. Static and headless; used by the dock and by a game's checks (and once, by hand, to create the first definitions file).
- **`editor/`** + **`plugin.gd`** — the only code that extends `editor_tool_kit` classes.

Files the **game** owns, outside the addon folder so a self-update never overwrites them:

- the **kinds file** (hand-written; `const KINDS`);
- the **definitions file** (generated; `SCHEMA`, `ACHIEVEMENTS`, `RENAMED`, `RETIRED`);
- `res://achievements_kit.config.json` (read by the dock only: file paths, the two key prefixes, the icon folder);
- the tracker subclass autoload, which passes the same files and prefixes to `configure()`.

Per-player state is exactly two save keys per achievement — `<earned_prefix><id>` (bool) and `<progress_prefix><id>` (int, capped at target). Nothing else is persisted.

## Usage
Vendor `addons/achievements_kit/` (and `addons/editor_tool_kit/` for the dock and self-update), enable the plugin, commit `res://achievements_kit.config.json`, hand-write the kinds file, create the definitions file from the **Achievements** bottom panel, then add a tracker subclass as an autoload and call `report()` from gameplay. See the Usage guides for the step-by-step.

## Invariants & constraints
- runtime/ and codegen/ depend on nothing outside the addon; only plugin.gd and editor/ extend editor_tool_kit classes.
- The addon ships no in-game Control code: UI contract is rows(), summary(), the signals and the debug actions.
- Per-player truth is two save keys per achievement (earned bool, progress int); nothing else is persisted.
- Ids are save keys: renaming or deleting a shipped id is recorded in RENAMED / RETIRED, never silently dropped.
- Game-owned files (kinds, definitions, config JSON) live outside addons/achievements_kit/, so a self-update never clobbers them.
- No backend specifics in the addon: the Snapser bridge is duck-typed and the stat/event names are passed in by the game.

## Synced commit
8a8bfec
