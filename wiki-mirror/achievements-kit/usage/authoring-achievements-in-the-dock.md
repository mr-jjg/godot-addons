# Authoring achievements in the dock

**Status:** active

## Body
The **Achievements** bottom panel is the only supported way to change the definitions file. It edits an in-memory copy, shows every problem as you type, and writes the file only on **Save**.

## The panel

- **Left:** a filter (matches id, name or kind) and the list, in display order: `#`, `id`, `name`, `kind`, `target`, `flags`. `H` marks a hidden achievement; `!` marks problems (red for errors, amber for warnings only) with the problems as its tooltip. Below it: **Add**, **Duplicate**, **Delete** (asks first), and ↑ ↓ to reorder.
- **Right:** the form for the selected achievement:
  - _Identity_ — `id` (renames on Enter or when the field loses focus), `name` (1–40 characters), `description` (1–120).
  - _Trigger_ — `kind` (each declared kind as `label (mode)`, its `doc` below), `target` (>= 1), then one control per param the kind declares: a dropdown for enums (`(any)` for `""`), a text box, a spin box or a check box.
  - _Display_ — `hidden`, `hint` (editable when hidden), `icon` (path + Browse), `category` (an existing one, `(none)`, or `new…`).
  - _Preview_ — the row as the game shows it locked (`???` and the hint when hidden) and earned, plus its two save keys.
- **Bottom:** the Problems list (click one to jump to its achievement), counts (`N achievements · H hidden · per kind`, and `● unsaved changes`), **Save**, **Revert**, **Reveal file**, and a collapsed, read-only _Renames & retired_ section.

A banner appears when the file was hand-edited ("saving will normalize it"), was written by a newer schema, failed to load, does not exist yet, or changed on disk while you had unsaved edits.

## Saving

- Save validates the definitions and the kinds file. **Errors block it; warnings never do** (for example, a hidden `count` achievement with no hint is a warning).
- It writes exactly what `AchKitCodegen.serialize` produces, then reloads, so the file is always canonical.
- It refuses when the file changed on disk since it was loaded (a teammate's edit, a git checkout). Press **Revert** first, then redo your edit.
- It is disabled while the definitions or kinds file cannot be loaded, so a broken or newer-schema file is never overwritten with an empty model.
- When the editor regains focus and the file changed, the dock reloads by itself if you have no unsaved edits.
- There is no editor Undo for these edits: **Revert** reloads from disk (it asks first when you have unsaved edits).

## Ids are save keys

Each id is part of two keys in every player's save. The dock protects them:

- An id that is in the file on disk counts as **shipped**.
- **Renaming** a shipped id records `old -> new` in `RENAMED` (and repoints older entries). The tracker migrates each player's keys on the next launch, and every query for the old id answers for the new one.
- **Deleting** a shipped id adds it to `RETIRED` (together with any `RENAMED` keys that pointed at it). A retired id can never be reused.
- An id you added since the last load can be renamed or dropped freely; nothing is recorded.
- Renaming back to a former id collapses the chain.
- After a Save, every saved id counts as shipped.

So: pick ids carefully, but don't fear renaming one — the file keeps the history players need.

## Things to know

- **Order is display order.** Use ↑ ↓; the game's `rows()` follows it.
- **Changing kind** keeps only the params the new kind declares.
- **Params at the kind's default are dropped** from the file: they match anything either way, and the file stays stable when a kind gains a param.
- **Lowering a target** is safe: stored progress is capped on load, and the next report of that kind earns it.
- **New kinds** are added to the hand-written kinds file, not in the dock; the dock picks them up when that file changes. An achievement that refers to an undeclared kind shows `<unknown: x>` and is an error.
- Never hand-edit the generated file. A hand edit is "not canonical", the next Save normalizes it, and a game's check can fail on it.

## References
_None._

## Child pages
_None._
