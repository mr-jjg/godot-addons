# Definitions & kinds — AchKitSchema and AchKitCodegen

**Status:** current

## Kind
module

## Summary
The two game-owned data files and the two static classes that read, check and write them. The **kinds file** is hand-written by the game (`const KINDS`); the **definitions file** is generated GDScript (`SCHEMA`, `ACHIEVEMENTS`, `RENAMED`, `RETIRED`). `runtime/achkit_schema.gd` (`AchKitSchema`) is the one validator shared by the tracker, the dock and a game's checks; `codegen/achkit_codegen.gd` (`AchKitCodegen`) parses both files by compiling them, serializes the definitions byte-for-byte deterministically, and provides the pure model edits (rename, remove, move) the dock uses.

## Purpose
Definitions are code the game `preload`s, so the runtime pays nothing to read them and Godot's own parser is the source of truth. Generating them (rather than hand-editing) keeps the format fixed, diffs small, and — critically — lets a tool maintain `RENAMED` and `RETIRED` so a renamed or deleted id never strands a player's save keys. Kinds stay hand-written because each one is wired to a gameplay source by a programmer; as pure data, the dock can read them without running game code.

One validator for every consumer means the dock's Save gate, the tracker's load-time skip and a game's CI check can never disagree about what is valid.

## Design notes
Parsing compiles the text with GDScript.new(), source_code, reload() and get_script_constant_map(). The editor and checks therefore see exactly what the runtime's preload sees, with no resource cache and so no stale read right after a write, and it works headless.

A file is canonical when parse_text followed by serialize gives back the same text, header prefixes included. A hand edit is not canonical; the dock's next Save normalizes it, and a game's check can fail CI on it.

SCHEMA is the format version. parse_text refuses a newer SCHEMA (update achievements_kit), accepts older ones, and serialize always writes the current one.

rename and remove with shipped=false still repoint chains and erase stale RENAMED entries; only adding old -> new to RENAMED (rename) and retiring the id itself (remove) require shipped=true. An invalid operation returns an unchanged copy of the model.

String literals escape backslash, double quote, newline, tab and carriage return; everything else is written as UTF-8 verbatim. Tabs, LF, a trailing comma after every entry, one blank line between consts and a final newline.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `validate() / validate_def() / validate_kinds() / validate_renamed()` in `addons/achievements_kit/runtime/achkit_schema.gd`
- function `normalize_def() / param_matches() / canonical() / errors_only()` in `addons/achievements_kit/runtime/achkit_schema.gd`
- function `parse_text() / parse_kinds_text() — compile and read consts` in `addons/achievements_kit/codegen/achkit_codegen.gd`
- function `serialize() / is_canonical() — the deterministic writer` in `addons/achievements_kit/codegen/achkit_codegen.gd`
- function `rename() / remove() / move() — pure model edits` in `addons/achievements_kit/codegen/achkit_codegen.gd`
- file `a canonical definitions file (fixture)` in `tests/achievements_kit/fixtures/achievements.gd`
- file `a kinds file (fixture)` in `tests/achievements_kit/fixtures/kinds.gd`

## Data model
**Kinds file** — `const KINDS := {&"kind": {"label", "mode", "doc", "params"}}`. `mode` is `&"count"` or `&"max"`. `params` is `{name: {type, values?, default?}}` with `type` one of `"string"`, `"int"`, `"bool"`, `"enum"` (`values` required for `enum`). A missing `default` is `""`, `0`, `false`, or an enum's first value.

**Definitions file** — a `## GENERATED ... DO NOT EDIT BY HAND` header naming both key prefixes, then `const SCHEMA := 1`, `const ACHIEVEMENTS := {&"id": {...}}`, `const RENAMED := {}` (old id → current id) and `const RETIRED: Array[StringName] = []`. Every definition has all nine fields, in this order: `name`, `description`, `kind`, `target`, `params`, `hidden`, `hint`, `icon`, `category`. `ACHIEVEMENTS` order **is display order**; `RENAMED` and `RETIRED` are written sorted. `params` holds only params set away from the kind's default, in the kind's declared order.

**Validation rules** (`AchKitSchema.validate`, plus `validate_kinds` for the kinds file): id matches `^[a-z][a-z0-9_]{0,47}$` and is not a `RENAMED` key or retired; `name` 1–40 characters, `description` 1–120; `target` >= 1; `kind` declared; params declared and of the declared type (enum values among `values`); a non-empty `icon` exists (optional via `opts.check_icons`); `RENAMED` has no cycle and every chain ends at a live id. A hidden `count` achievement with no hint is a **warning** (prefix `"warning: "`), which never blocks a save; `errors_only()` filters warnings out.

**Param matching** (`param_matches`): for each param the achievement sets away from the kind's default, the report's `context[name]` must equal it. An unset or default-valued param matches anything.

**Codegen API** — `parse_text` / `parse_file` → `{ok, error, schema, achievements, renamed, retired}`; `parse_kinds_text` / `parse_kinds_file` → `{ok, error, kinds}`; `serialize(achievements, renamed, retired, kinds, prefixes)`; `is_canonical(text, kinds, prefixes)`; pure model edits `rename(model, old, new, shipped)`, `remove(model, id, shipped)`, `move(model, id, delta)` over `model = {achievements, renamed, retired}`.

## Usage
_None._

## Invariants & constraints
- serialize is byte-for-byte deterministic: the same model, kinds and prefixes always give the same text.
- Every definition in the generated file carries all nine fields in the fixed order.
- The schema and codegen are static, pure and headless: no editor or Control references.
- Warnings (prefixed "warning: ") never block a save; errors do.
- A retired id or a RENAMED key can never be reused as a live id.

## Synced commit
8a8bfec
