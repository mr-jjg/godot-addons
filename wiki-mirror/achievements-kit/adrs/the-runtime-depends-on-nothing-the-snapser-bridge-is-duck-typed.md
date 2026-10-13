# The runtime depends on nothing; the Snapser bridge is duck-typed

**Status:** accepted

## Metadata
- **Number:** ADR-27
- **Date:** 2026-10-12
- **Scope:** achievements_kit
- **Deciders:** Benjamin Jordan

## Context
The kit is meant for any Godot game, with or without a backend, and the runtime ships inside exported games. Depending on snapser_kit would force every consumer to vendor it; depending on editor_tool_kit from runtime code would drag editor classes into exports. Consuming games also route every backend call through their own facade autoload, which keeps calls offline-safe and declared, so the kit must not call a backend client directly.

## Decision
runtime/ and codegen/ depend on nothing outside the addon. Only plugin.gd and editor/ extend editor_tool_kit classes.

AchKitSnapserBridge is duck-typed: it accepts any Node with track(), record_stat(), wait_until_ready(), is_online(), is_booted(), the boot_finished signal and a config with is_offline(). The game's facade (a SnapKitService subclass) owns the bridge and passes itself in, along with the stat and event names.

The save store is duck-typed the same way (read, write, optional flush), so the kit depends on no save addon either.

## Consequences
A game without Snapser still gets achievements; a game with Snapser reuses the earn -> event, count -> stat and boot catch-up logic instead of rewriting it.

Every backend call still goes through the game's facade, so the facade's offline and declared-name guarantees hold.

The duck-typed surfaces are a contract the compiler does not check; the tests pin them with a fake Snapser service and a fake store, and a mismatch shows up at runtime.

editor_tool_kit is still required for the dock and for self-update, but an exported game loads only the runtime.

## Relations
_None._
