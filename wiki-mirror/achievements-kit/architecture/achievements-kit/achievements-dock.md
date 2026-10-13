# Achievements dock

**Status:** current

## Kind
component

## Summary
The **Achievements** bottom panel, built on Editor Tool Kit as a *service + a view*. `editor/achievements_editor_service.gd` is a headless `ToolService` that owns an in-memory model of the definitions file, validates with `AchKitSchema`, applies the pure `AchKitCodegen` edits, and saves exactly `AchKitCodegen.serialize(...)`. `editor/dock.gd` only lays out controls and re-renders on the service's `changed` signal. `plugin.gd` declares both via `_config()` (`panel: "Achievements"`).

## Purpose
Designers should add and tune achievements without editing generated code or understanding save keys. The dock makes the safe path the only path: every edit is validated as you type, Save is refused while anything is invalid or stale, and renames and deletions of shipped ids are recorded in `RENAMED` / `RETIRED` automatically, so no player loses an earn because someone tidied an id.

## Design notes
Edits apply to an in-memory model; nothing touches disk until Save. There is no editor UndoRedo: Revert reloads from disk, asking first when there are unsaved edits.

Save is refused when the config is missing, the definitions or kinds file failed to load, the file changed on disk since it was loaded (a teammate's edit, a git checkout: Revert first), or there are errors. Warnings never block. When the editor regains focus and the file changed, the dock reloads by itself if there are no unsaved edits.

An id present in the file on disk counts as shipped. Renaming a shipped id adds old -> new to RENAMED and repoints older entries; deleting one adds it to RETIRED, together with any RENAMED keys that pointed at it. An id added since the last load is renamed or dropped freely. Renaming back to a former id collapses the chain. After a Save, the saved ids count as shipped.

New entries are normalized with AchKitSchema.normalize_def, so params at the kind default are dropped. Changing an achievement's kind keeps only the params the new kind declares. New ids can never reuse a retired id or a RENAMED key.

## Components
_No components._

## Dependencies
- **calls** → [Definitions & kinds — AchKitSchema and AchKitCodegen](architecture:mv5fixl0-003c-7e7qqh) — parse, validate, normalize, the pure model edits, and serialize on Save.
- **implements** → [ToolService](architecture:mql3cw8b-01r9-lncvao) — the service extends editor_tool_kit's ToolService; the plugin extends EditorToolPlugin.

## Code references
- file `the headless ToolService (model, validation, save)` in `addons/achievements_kit/editor/achievements_editor_service.gd`
- file `the bottom-panel view` in `addons/achievements_kit/editor/dock.gd`
- function `_config() — declares panel, service and dock` in `addons/achievements_kit/plugin.gd`
- file `example per-project config` in `addons/achievements_kit/achievements_kit.config.example.json`
- file `service tests against temp files, plus a headless build of the dock` in `tests/achievements_kit/test_editor_service.gd`

## Data model
**Config** — `res://achievements_kit.config.json` (outside the addon): `definitions` (may not exist yet; the first Save creates it and its folders), `kinds` (must exist and compile), `earned_key_prefix` and `progress_key_prefix` (written into the file header and shown in the preview; must match the tracker's `configure()` prefixes), `icon_dir` (where Browse starts; `""` = `res://`). Paths are `res://` or absolute; a bare relative path is relative to `res://`. Without the file, the panel shows setup instructions.

**Layout** — left: a filter (id, name or kind), the list (`#`, `id`, `name`, `kind`, `target`, `flags`: `H` hidden, `!` has problems — red for errors, amber for warnings only, problems as tooltip), and Add, Duplicate, Delete (confirmed), up/down. Right: a form with *Identity* (`id` renames on Enter or focus loss, `name`, `description`), *Trigger* (`kind` as `label (mode)` with its `doc`, `target`, one control per declared param), *Display* (`hidden`, `hint`, `icon` + Browse, `category`) and *Preview* (locked and earned rows as the game shows them, plus the two save keys). Below: Problems (click to select), counts and an unsaved marker, Save, Revert, Reveal file, and a collapsed read-only *Renames & retired* section. Banners flag a hand-edited file, a newer schema, a load failure, a missing file, or an on-disk change during unsaved edits.

**Service API** — each mutator returns `{ok: true, ...}` or `{ok: false, error}` and emits `changed` on success: `load_config`, `is_configured`, `reload`, `revert`, `save`, `add(id, kind)`, `duplicate_entry(id, new_id)`, `set_field(id, field, value)`, `set_param(id, param, value)`, `rename(old_id, new_id)`, `remove(id)`, `move(id, delta)`; queries `problems`, `errors`, `problems_for(id)`, `problem_id(problem)`, `ids`, `get_def`, `filter_ids`, `categories`, `preview_row`, `stats`, `kind_names`, `kind_caption`, `kind_params`, `serialized_text`, `disk_changed`, `is_shipped`, `load_error`, `file_exists`, `is_canonical_on_disk`, `schema_newer`, `prefixes`. `config_path` can be pointed elsewhere for tests.

## Usage
_None._

## Invariants & constraints
- The service holds no Control or EditorInterface references and runs under godot --headless.
- Save writes exactly AchKitCodegen.serialize(...) and never overwrites a file it could not load (broken or newer schema).
- Save never clobbers an on-disk change made since the last load.
- Renaming or deleting a shipped id is always recorded in RENAMED / RETIRED.
- Project config lives outside addons/achievements_kit/, so a self-update never clobbers it.

## Synced commit
8a8bfec
