# AchKitSnapserBridge

**Status:** current

## Kind
component

## Summary
`runtime/achkit_snapser_bridge.gd` — `class_name AchKitSnapserBridge extends RefCounted`, an optional adapter that mirrors a tracker's earns onto a Snapser service: **one analytics event per earn** and **one aggregate statistic SET to the number of achievements held**. Duck-typed, so the addon never depends on `snapser_kit`; the game's facade owns the bridge and passes itself in, so every backend call still goes through the facade.

## Purpose
Every game that uses Snapser needs the same earn → event, count → stat and boot catch-up logic; writing it once avoids subtle drift (double posts, lost offline earns, a stat that never repairs). A game without Snapser simply never constructs the bridge and still gets achievements.

## Design notes
The event is best-effort: snapser_kit's analytics buffer is in memory, so events from an offline session that quits before reconnecting are lost. The stat plus the cloud save are the durable record.

Keep a reference to the bridge (for example a var on the facade autoload). It is RefCounted, and its signal connections die with it.

## Components
_No components._

## Dependencies
- **depends-on** → [AchKitTracker](architecture:mv5fixit-003a-4rlniu) — listens to earned(id) and reads earned_count().

## Code references
- class `AchKitSnapserBridge` in `addons/achievements_kit/runtime/achkit_snapser_bridge.gd`
- function `post_count() — the coalesced, idempotent stat SET` in `addons/achievements_kit/runtime/achkit_snapser_bridge.gd`
- file `a fake Snapser service for bridge tests` in `tests/achievements_kit/fakes/fake_snap_service.gd`
- file `bridge tests` in `tests/achievements_kit/test_bridge.gd`

## Data model
`AchKitSnapserBridge.new(service: Node, tracker: AchKitTracker, stat_key: String, event: String)`.

The service may be any `Node` with `track()`, `record_stat()`, `wait_until_ready()`, `is_online()`, `is_booted()`, the `boot_finished` signal and a `config` with `is_offline()`. A `SnapKitService` has all of them.

- **On `tracker.earned(id)`** — calls `track(event, {"id": str(id)})` at once, and schedules **one** coalesced `post_count()` for the end of the frame, so a burst of earns makes one request.
- **`post_count()`** (a coroutine; also the debug "post stat now" path) — returns `{ok, error, value}`. Does nothing when `config.is_offline()` (`error: "offline"`); otherwise awaits `wait_until_ready()` and, if online with a count above 0, calls `record_stat(stat_key, earned_count())` and emits `synced({ok, error, value})`. A count of 0 is never posted (`error: "nothing_to_post"`). `synced` fires only when a request was actually sent.
- **Boot catch-up** — on `boot_finished` (or at once if already booted), when the count is above 0 it posts, which repairs the stat after an offline session.

Declare the stat (a counter) and the event (`{id: string}`) on the snapend and in the game's `snapser_kit.config.json` `declared` section; an undeclared stat or event is refused.

## Usage
_None._

## Invariants & constraints
- The bridge has no compile-time dependency on snapser_kit; the service is duck-typed.
- The statistic is SET to earned_count(), never incremented, so a repeat post is harmless and adding an achievement never needs a new stat.
- Offline, post_count() sends nothing and returns error "offline"; a count of 0 is never posted.
- A burst of earns in one frame produces one stat request.

## Synced commit
8a8bfec
