# Snapser gets one aggregate statistic, not one per achievement

**Status:** accepted

## Metadata
- **Number:** ADR-26
- **Date:** 2026-10-12
- **Scope:** achievements_kit
- **Deciders:** Benjamin Jordan

## Context
A game mirroring achievements onto Snapser could declare one statistic per achievement. But every statistic must be declared on the snapend and in the game's client config before use (an undeclared one is refused), so each new achievement would become a backend change and a config change, and a typo would silently drop data. The per-player truth already lives in the synced save; the backend mostly needs an aggregate for leaderboards and analytics, plus an event stream for funnels.

## Decision
AchKitSnapserBridge sends one analytics event per earn (the event name chosen by the game, payload {id}) and keeps one aggregate counter statistic SET to tracker.earned_count(). There is no statistic per achievement.

The stat is SET, never incremented: a burst of earns in a frame coalesces into one request, and the bridge re-posts the count on boot to repair the stat after an offline session.

## Consequences
Adding, renaming or retiring an achievement never needs a snapend or config change.

Posting is idempotent: a repeated or catch-up post can never double-count.

The backend cannot answer which achievements a player holds from statistics alone; that comes from the cloud save, or from the event stream for analytics.

Events are best-effort (the analytics buffer is in memory); the stat plus the cloud save are the durable record.

## Relations
_None._
