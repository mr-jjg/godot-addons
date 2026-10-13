# Per-player truth is one earned bool and one progress int per achievement, in the game's synced save

**Status:** accepted

## Metadata
- **Number:** ADR-25
- **Date:** 2026-10-12
- **Scope:** achievements_kit
- **Deciders:** Benjamin Jordan

## Context
Achievement state has to survive restarts, follow the player to other devices, merge sensibly when two devices both made progress, and survive an anonymous-to-signed-in account switch. Games that use the kit already have a save store, and with snapser_kit a cloud save that mirrors chosen key prefixes, ORs bools on every pull and applies per-glob merge policies. A separate achievements file or a backend-only record would need its own sync and conflict rules, and a single packed blob (a list or dictionary under one key) would merge as a whole value, losing one device's earns.

## Decision
The tracker persists exactly two keys per achievement in the game's own store: <earned_prefix><id> (bool) and <progress_prefix><id> (int, capped at the target). Nothing else is persisted; the prefixes are passed to configure() by the game.

Games put both prefixes under what their cloud save already syncs, give the progress prefix a max merge policy, and choose a progress prefix the earned prefix does not match as a glob, so the policy never touches the bools.

## Consequences
Cross-device sync needs no achievement-specific code: an earn on any device survives every merge because bools are OR-ed, and with the max policy progress never goes backwards.

Each achievement merges independently, so two devices earning different achievements offline both keep theirs.

Ids become save keys, which is why renames and deletions go through RENAMED / RETIRED (see the generated-definitions ADR).

Revoking is hard by design: a local false is OR-ed back by the next pull, so a debug revoke only sticks on an account after a forced push, and another device holding true restores it on its next sync.

After a pull the game must call the tracker's reload; load-caused writes (migration, backfill) are deferred so they are not swallowed as the import's own echo.

## Relations
_None._
