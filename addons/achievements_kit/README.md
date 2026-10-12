# Achievements Kit

Game-agnostic achievements for Godot 4.x. It provides:
- `AchKitTracker`, a runtime tracker over the game's own save, which a game extends as an autoload;
- `AchKitSchema`, a schema and validator shared by the runtime, the editor dock and a game's checks;
- `AchKitCodegen`, which reads and writes the game's definitions file (plain, generated GDScript);
- `AchKitSnapserBridge`, an optional duck-typed adapter that mirrors earned achievements onto a Snapser service;
- an Editor Tool Kit dock where designers author achievements (0.2.0; in 0.1.0 the plugin mounts nothing).

The runtime (`runtime/`) and codegen (`codegen/`) have **no dependencies**: not on `snapser_kit`, not on
`editor_tool_kit`, not on any save addon. They load headless and in exported games. Only `plugin.gd`
and `editor/` extend `editor_tool_kit` classes, so ETK must be vendored for the dock and for self-update.

In-game UI stays per game: the kit ships view-models (`rows()`, `summary()`), signals and debug
actions, and a game lays them out with its own widgets.

## The model

- Every achievement has a **kind** (a `StringName` the game declares), a **target** (int >= 1) and
  optional **params**.
- Each kind has a **mode**:
  - `count` sums the reported amounts (lifetime counters; a one-off flag is a count with target 1);
  - `max` keeps the largest single value reported ("reach round 50 in one run").
- The game calls `report(kind, amount, context)`. An achievement of that kind whose params match the
  context moves toward its target, and earns at the target.
- Per-player truth is two save keys per achievement:
  - `<earned_prefix><id>`: bool, earned;
  - `<progress_prefix><id>`: int, progress, capped at the target.
  Nothing else is persisted. A cloud save that mirrors the store carries achievements to other
  devices with no extra code. With snapser_kit's cloud save, bools are OR-ed on every pull; give
  the progress prefix a `"max"` merge policy (e.g. `"merge_policy": {"prog_achp_*": "max"}`) so
  progress never goes backwards on a pull. Use a progress prefix that the earned prefix does not
  match as a glob, so the policy never touches the bools.
- **Ids are save keys.** Renaming or deleting one goes through `RENAMED` / `RETIRED` in the
  definitions file (the dock maintains both), so no player loses what they earned.

## Setup

1. Copy `addons/achievements_kit/` (and `addons/editor_tool_kit/`, for the dock and self-update)
   into the game's `addons/` and enable the plugin.
2. Commit `res://achievements_kit.config.json`, **outside** the addon folder so a self-update never
   overwrites it. Only the dock reads it; the runtime is configured by your tracker subclass (keep
   them in agreement; a game check can compare them). See `achievements_kit.config.example.json`:
   ```json
   {
     "definitions": "res://scripts/config/achievements.gd",
     "kinds": "res://scripts/config/achievement_kinds.gd",
     "earned_key_prefix": "prog_ach_",
     "progress_key_prefix": "prog_achp_",
     "icon_dir": ""
   }
   ```
3. Write the **kinds file** by hand (below).
4. Create the **definitions file**: in the dock (0.2.0), or once from a throwaway headless script
   through `AchKitCodegen.serialize(...)`, so it is canonical from the first commit.
5. Add the tracker autoload (below) and report from wherever each kind happens.

### The kinds file (hand-written by the game)

Pure data, so the dock can read it without running game code:

```gdscript
extends RefCounted
## Achievement trigger kinds this game reports. Hand-written (not generated).

const KINDS := {
	&"boards_cleared": {
		"label": "Boards cleared (lifetime)",
		"mode": &"count",
		"doc": "Game.board_cleared: the last block on the board broke.",
		"params": {},
	},
	&"round_reached": {
		"label": "Round reached in one run",
		"mode": &"max",
		"doc": "Game.round_survived: the round now being played.",
		"params": {
			"source": {"type": "enum", "values": ["", "quick_play", "custom"], "default": ""},
		},
	},
}
```

| Field | Type | Meaning |
|---|---|---|
| `label` | String | Shown in the dock's dropdown and in `rows()` as `kind_label`. |
| `mode` | `&"count"` or `&"max"` | See above. |
| `doc` | String | Where it's reported from. Shown in the dock. |
| `params` | `{name: {type, values?, default?}}` | `type` is `"string"`, `"int"`, `"bool"` or `"enum"`; `values` is required for `enum`. A missing `default` is `""`, `0`, `false`, or an enum's first value. |

**Param matching** (`AchKitSchema.param_matches`): for each param that the achievement sets to
something other than the kind's default, the report's `context[name]` must equal it. An unset
param, or one left at its default, matches anything.

### The definitions file (generated GDScript)

`AchKitCodegen.serialize` writes it byte-for-byte deterministically. Don't edit it by hand: a hand
edit is "not canonical" (`AchKitCodegen.is_canonical`), and the dock's next save normalizes it.

```gdscript
extends RefCounted
## GENERATED by the Achievements dock (addons/achievements_kit). DO NOT EDIT BY HAND:
## ...

const SCHEMA := 1

const ACHIEVEMENTS := {
	&"first_clear": {
		"name": "Clean Sweep",
		"description": "Clear the board.",
		"kind": &"boards_cleared",
		"target": 1,
		"params": {},
		"hidden": false,
		"hint": "",
		"icon": "",
		"category": &"",
	},
}

## Old id -> current id. Maintained by the dock; never edit by hand.
const RENAMED := {}

## Ids that were deleted after they may have shipped. Never reused.
const RETIRED: Array[StringName] = []
```

- Every field is always present, in this order: `name`, `description`, `kind`, `target`, `params`,
  `hidden`, `hint`, `icon`, `category`. Keys are quoted Strings; ids, `kind`, `category`, RENAMED
  and RETIRED entries are StringNames.
- `ACHIEVEMENTS` order **is display order**. RENAMED and RETIRED are written sorted.
- `params` holds only params set away from the kind's default, in the kind's declared order (a
  default-valued param is dropped: it matches anything either way, and the file stays stable when
  a kind gains a param). Values are String, int or bool literals.
- String literals escape `\\`, `"`, newline, tab and carriage return; everything else is UTF-8
  verbatim. Tabs, LF, a trailing comma after every entry, one blank line between consts, a final
  newline.
- `SCHEMA` is the format version. `parse_text` refuses a newer one ("update achievements_kit"),
  accepts older ones, and `serialize` always writes the current one.
- Rules: id matches `^[a-z][a-z0-9_]{0,47}$` and is not a RENAMED key or RETIRED; `name` 1-40
  characters, `description` 1-120; `target` >= 1; `kind` declared; params declared and of the
  declared type (enum values among `values`); a non-empty `icon` exists; RENAMED has no cycle and
  every chain ends at a live id. A hidden `count` achievement with no hint is a **warning**
  (prefix `"warning: "`), which never blocks a save.

### The tracker autoload

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

Then report from gameplay: `Achievements.report(&"boards_cleared")`,
`Achievements.report(&"round_reached", round, {"source": "quick_play"})`.

**Store contract** (duck-typed; pass any object with these):

```gdscript
read(key: String, default_value: Variant) -> Variant
write(key: String, value: Variant) -> void
flush() -> void      # optional; called right after an earn so an earn is never lost
```

- A debounced store with `read`/`write`/`flush` (a game's own `SaveStore`) works as-is.
- `AchKitSaveServiceStore.new(service)` adapts a `get_var_value` / `set_var_value` save service.
- `AchKitMemoryStore` is an in-memory Dictionary for tests and tools.

**API** (see the doc comments in `runtime/achkit_tracker.gd`):

| Group | Members |
|---|---|
| Signals | `earned(id)` after the bool is written **and flushed**; `progressed(id, value, target)` after the write, on change only; `revoked(id)`; `changed` (earn / revoke / reload, not per progress tick); `reloaded` |
| Setup | `configure(defs, kinds, renamed, retired, store, earned_prefix, progress_prefix)` |
| Reload | `owns_key(key)`, `reload_if_owned(keys) -> bool`, `reload()` (re-reads; emits `changed` + `reloaded`, never `earned`) |
| Queries | `ids()`, `definition(id)`, `kind_of(id)`, `is_earned(id)`, `progress(id)`, `target(id)`, `earned_count()`, `total_count()`, `run_earned()`, `earned_key(id)`, `progress_key(id)` |
| View-models | `rows(reveal_hidden := false)`: `{id, name, description, hint, hidden, masked, earned, progress, target, fraction, kind, kind_label, category, icon}`; a masked row (hidden, unearned, not revealed) has name `"???"` and description `""` and keeps its hint. `summary()`: `{earned, total, categories: {cat: {earned, total}}}` |
| Reporting | `report(kind, amount := 1, context := {})`, `earn(id) -> bool` (a scripted grant; gated like `report`), `begin_run()` |
| Debug | `debug_grant(id)`, `debug_revoke(id)`, `debug_revoke_all()`, `debug_set_progress(id, value)`; they bypass the gate |
| Virtuals | `_earning_allowed(id, kind, context) -> bool`, `_matches(def, kind, context) -> bool`, `_backfill()`; log hooks `_warn(msg)`, `_error(msg)` |

Behaviour worth knowing:

- **Validation at load.** `configure()` validates the kinds and definitions. Each problem is a
  `push_error` in a debug build; an invalid kind or definition is skipped, never fatal.
- **Write order on earn.** Progress = target and the bool `true` are written, the store is
  flushed, and only then do `earned` and `changed` fire. A listener sees `is_earned(id) == true`
  and the key already in the store.
- **An earned achievement is final.** `report()` skips it with no writes.
- **Old ids resolve.** Every query follows RENAMED (`is_earned(&"old_id")` answers for the new id).
- **Unknown kind.** `report()` with an undeclared kind warns once per kind and does nothing.
- **Load-caused writes are deferred.** After `configure()` and every `reload()`, one deferred pass
  runs at the end of the frame: the RENAMED migration (an old id's `true` carries over; progress
  takes the larger of old and new; old keys are left in place; idempotent), then `_backfill()`.
  Writing inside a cloud-save import handler would be suppressed as the import's own echo.
- **Lowering a target.** Progress is capped to the new target on load, and the next report of that
  kind earns it.
- **Revoke is local.** `debug_revoke*` writes `false` / `0`. A cloud pull ORs a remote `true` back:
  force-push afterwards to make it stick on this account (another device holding `true` restores
  it on its next sync).

## Snapser bridge

`AchKitSnapserBridge` mirrors earns onto a Snapser service: one analytics event per earn and one
aggregate statistic **SET** to the number held (idempotent; adding an achievement never needs a
new stat). It's duck-typed, so the addon doesn't depend on `snapser_kit`: the service is any `Node`
with `track()`, `record_stat()`, `wait_until_ready()`, `is_online()`, `is_booted()`, the
`boot_finished` signal and a `config` with `is_offline()`. A `SnapKitService` has all of them.
Let the game's facade own the bridge and pass itself, so every call goes through the facade:

```gdscript
# in the game's Snapser autoload (extends SnapKitService)
var ach_bridge: AchKitSnapserBridge

func _ready() -> void:
	start()
	ach_bridge = AchKitSnapserBridge.new(self, Achievements, "achievements_earned", "achievement_earned")
```

- On `tracker.earned(id)` it calls `track(event, {"id": str(id)})` at once, and schedules **one**
  coalesced `post_count()` for the end of the frame, so a burst of earns makes one request.
- `post_count()` (a coroutine, also the "post now" path) does nothing when `config.is_offline()`;
  otherwise it awaits `wait_until_ready()` and, if online with a count above 0, calls
  `record_stat(stat_key, earned_count())` and emits `synced({ok, error, value})`. It returns
  `{ok, error, value}`, with error `"offline"` or `"nothing_to_post"` when it sent nothing. A
  count of 0 is never posted.
- **Boot catch-up**: on `boot_finished` (or at once if already booted), when the count is above 0
  it posts, which repairs the stat after an offline session.
- Declare the stat (counter) and the event (`{id: string}`) on the snapend and in the game's
  `snapser_kit.config.json` `declared` section.
- The event is best-effort: snapser_kit's analytics buffer is in memory, so events from an offline
  session that quits before reconnecting are lost. The stat plus the cloud save are the durable
  record.
- Keep a reference to the bridge (it's `RefCounted`; its connections die with it).

## Tests

Headless; never touch the network or `user://`:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --import
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tests/achievements_kit/run_tests.gd [-- --filter=<substring>]
# -> "ACHKIT TESTS: N passed, 0 failed", exit 0
```

The suite lives at the repo root in `tests/achievements_kit/` (not inside the addon):
`test_schema.gd`, `test_codegen.gd`, `test_tracker.gd`, `test_bridge.gd`, with fakes in `fakes/`
(a staged/flushed store, a fake Snapser service, a probe tracker) and fixtures in `fixtures/` (a
kinds file and a canonical definitions file). `test_codegen.gd::test_parse_errors` compiles broken
GDScript on purpose, so two `SCRIPT ERROR: Parse Error` lines in the output are expected.

## Versions

- **0.1.0**: runtime tracker, schema and validator, generated-GDScript codegen, Snapser bridge.
  The plugin mounts nothing yet.
