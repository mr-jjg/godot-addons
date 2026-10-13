# Definitions are generated GDScript consts, written only by the dock

**Status:** accepted

## Metadata
- **Number:** ADR-24
- **Date:** 2026-10-12
- **Scope:** achievements_kit
- **Deciders:** Benjamin Jordan

## Context
Achievement definitions need three audiences served at once: the **runtime**, which must read them cheaply in an exported game; **designers**, who should edit them without a programmer; and **every player's save**, because each id is part of two save keys. A data file (JSON, `.tres`) would need a loader, a cache and its own type rules, and a free-form hand-edited file gives no place to record that an id was renamed or deleted — so a tidy-up silently strands players' earned keys. The consuming studio already keeps other content (for example a shop catalog) as GDScript consts with a `RENAMED` map, and that pattern has held up.

## Decision
The game's definitions file is plain GDScript: const SCHEMA, const ACHIEVEMENTS (id -> nine fixed fields, in display order), const RENAMED (old id -> current id) and const RETIRED (ids deleted after they may have shipped). The runtime preloads it.

The file is generated: AchKitCodegen.serialize writes it byte-for-byte deterministically under a DO NOT EDIT BY HAND header, and the Achievements dock is the only intended writer. The dock maintains RENAMED and RETIRED on every rename or delete of a shipped id.

Tools read the file by compiling its text (GDScript.new(), source_code, reload(), get_script_constant_map()), never through the resource cache. Kinds stay in a separate, hand-written const file, because each kind is wired to a gameplay source by a programmer.

## Consequences
The runtime pays nothing to load definitions, and the editor, the checks and the game all see exactly what Godot's own parser sees, with no stale cached read after a Save.

Renames and deletions are safe by construction: the tracker migrates RENAMED keys and refuses to reuse RETIRED ids, so no player loses an earn to a tidy-up.

A hand edit is detectable: is_canonical fails on any text the dock would not have written, so a game can gate CI on it, and the dock's next Save normalizes it.

Diffs stay small and reviewable (fixed field order, default-valued params dropped, sorted RENAMED / RETIRED), but merge conflicts in the file must be resolved by re-saving from the dock rather than by hand.

The format is versioned by SCHEMA: an older addon refuses a newer file instead of overwriting it.

## Relations
_None._
