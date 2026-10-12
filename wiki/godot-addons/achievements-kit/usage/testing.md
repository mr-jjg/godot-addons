# Testing

**Status:** active

## Body
## The addon's suite

Headless; it never touches the network or `user://`. Run from the godot-addons repo root:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --import
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tests/achievements_kit/run_tests.gd [-- --filter=<substring>]
# -> "ACHKIT TESTS: N passed, 0 failed", exit 0
```

`test_codegen.gd::test_parse_errors` compiles broken GDScript on purpose, so two `SCRIPT ERROR: Parse Error` lines in the output are expected.

The suite lives at the repo root in `tests/achievements_kit/`, not inside the addon, so it is never vendored:

| File | Covers |
| --- | --- |
| `test_schema.gd` | id pattern and collisions with RENAMED / RETIRED, fields and types, text limits, kinds and params, the hidden-without-hint warning, icons, RENAMED dangling entries and cycles, `validate_kinds`, `param_matches`, `canonical`, `normalize_def` |
| `test_codegen.gd` | a byte-for-byte reference file, round-trips, determinism, field order and format, the header, hand-edited files not canonical, parse errors, file I/O, rename / remove / move |
| `test_tracker.gd` | count and max modes, params filtering, capping, earned-once after write and flush, gating, `reload_if_owned`, RENAMED migration, deferred backfill, rows and summary, unknown kinds, debug actions, `run_earned`, invalid definitions skipped, both store adapters |
| `test_bridge.gd` | an event per earn and one coalesced stat post, no stat offline, boot catch-up only when something is earned, `post_count()` results |
| `test_editor_service.gd` | the dock's service against temp files under `OS.get_cache_dir()` (load, filter, add, edit, rename, remove, move, problems, Save bytes, Save refused after an external edit, Revert, a missing file created, load errors blocking Save), plus a headless build of the dock |

Fakes are in `fakes/` (a staged/flushed store, a fake Snapser service, a probe tracker) and fixtures in `fixtures/` (a kinds file and a canonical definitions file, using the prefixes `test_ach_` / `test_achp_`). `achkit_test_case.gd` provides `check`, `check_eq`, `check_problem`, `add_node` and `settle()` (await a few frames so the tracker's deferred post-load pass has run).

To check the dock loads in a real editor (no output means no errors):

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit 2>&1 \
    | grep -iE "error|failed" | grep -i achievements_kit
```

Some things still need a human in the editor: the split layout, the Browse icon dialog, the Add / Duplicate dialogs, the Delete / Revert confirmations, rename on Enter or click-away, Reveal file, auto-reload on focus and the filesystem rescan after Save.

## Testing in a game

- Use `AchKitMemoryStore` to test a tracker subclass without touching the real save: assert on `store.data` and `store.flush_count`.
- After `configure()` or `reload()`, wait a frame or two before asserting migrated or backfilled state; that pass is deferred by design.
- Add a check scene (not a `-s` script, if your tracker reads other autoloads) that runs `AchKitCodegen.is_canonical`, `AchKitSchema.validate_kinds` and `AchKitSchema.errors_only(AchKitSchema.validate(...))` against the game's real files, and asserts every declared kind is reported somewhere.
- The Snapser bridge is offline-safe: under an offline config `post_count()` returns `error: "offline"` and sends nothing.

## References
_None._

## Child pages
_None._
