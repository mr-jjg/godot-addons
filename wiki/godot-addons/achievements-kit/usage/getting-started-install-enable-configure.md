# Getting started — install, enable & configure

**Status:** active

## Body
From nothing to a project where the **Achievements** bottom panel opens on your game's files.

## 1. Vendor and enable

Copy `addons/achievements_kit/` into your project's `addons/` and commit it. For the dock and for self-update, also vendor `addons/editor_tool_kit/` (etk is the package manager for every addon here). Enable both in **Project Settings → Plugins**.

The runtime (`runtime/`) and codegen (`codegen/`) need nothing else: no `snapser_kit`, no etk, no save addon. A game that only wants the tracker can ship without the dock, but you lose the editor and self-update.

## 2. Commit the project config

Create `res://achievements_kit.config.json` **outside** the addon folder (a self-update overwrites the folder, never this file). Start from `addons/achievements_kit/achievements_kit.config.example.json`:

```json
{
  "definitions": "res://scripts/config/achievements.gd",
  "kinds": "res://scripts/config/achievement_kinds.gd",
  "earned_key_prefix": "prog_ach_",
  "progress_key_prefix": "prog_achp_",
  "icon_dir": ""
}
```

| Key | Meaning |
| --- | --- |
| `definitions` | The generated definitions file. It may not exist yet: the dock's first Save creates it and its folders. |
| `kinds` | Your hand-written kinds file (`const KINDS`). It must exist and compile. |
| `earned_key_prefix`, `progress_key_prefix` | The save-key prefixes. They go into the generated file's header and must match what your tracker passes to `configure()`. |
| `icon_dir` | Where the icon Browse dialog starts (`""` = `res://`). |

Paths are `res://` or absolute; a bare relative path is taken relative to `res://`.

Only the dock reads this file. The runtime is configured by your tracker subclass, so keep the two in agreement (a game check can compare them).

**Choosing prefixes.** Put them under whatever prefix your cloud save already syncs, and pick a progress prefix that the earned prefix does not match as a glob (`prog_ach_` vs `prog_achp_`), so a `"max"` merge policy on progress never touches the earned bools.

## 3. Write the kinds file

Kinds are the things gameplay reports. Each has a `label`, a `mode` (`&"count"` sums, `&"max"` keeps the best single value), a `doc` saying where it is reported from, and optional typed `params`:

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

Param `type` is `"string"`, `"int"`, `"bool"` or `"enum"` (`values` required for `enum`). A missing `default` is `""`, `0`, `false`, or an enum's first value. Keep the file pure data: the dock reads it without running game code.

## 4. Create the definitions file

Open the **Achievements** bottom panel. With the config in place and the kinds file compiling, it shows an empty editor and a "file doesn't exist yet" banner. Add one achievement and press **Save**: the file is created, canonical from its first commit.

(Alternatively, generate it once from a throwaway headless script with `AchKitCodegen.serialize(...)`.)

## 5. Wire the runtime

Add a tracker subclass as an autoload and call `report()` from gameplay. That is covered in _Integrating into a game_.

## Updating the addon

achievements_kit carries the `[update]` marker in its `plugin.cfg`, so the **Editor Tool Kit** dock lists it with installed → upstream versions and updates it in place. Your config, kinds and definitions files live outside the addon folder and are never touched.

## References
_None._

## Child pages
_None._
