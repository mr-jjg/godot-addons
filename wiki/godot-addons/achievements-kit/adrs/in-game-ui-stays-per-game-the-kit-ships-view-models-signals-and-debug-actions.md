# In-game UI stays per game; the kit ships view-models, signals and debug actions

**Status:** accepted

## Metadata
- **Number:** ADR-28
- **Date:** 2026-10-12
- **Scope:** achievements_kit
- **Deciders:** Benjamin Jordan

## Context
The games that consume these addons use unrelated UI stacks: code-built themed widgets in one, a studio style system in another, this repo's ui_kit router in a third. A themeable in-game achievements panel would need a style-adapter layer about as big as each game's own panel, and an addon here must not depend on a studio-owned UI library.

## Decision
achievements_kit ships no in-game Control code. Its UI contract is headless: AchKitTracker.rows(reveal_hidden) (precomputed rows with masking for hidden achievements), summary() (totals and per-category counts), the earned / progressed / revoked / changed / reloaded signals, and the debug actions.

Each game lays these out with its own widgets: a list panel, earn toasts, debug panels. Revisit an unstyled reference panel once a second consumer exists.

## Consequences
With rows precomputed, a game's achievements panel is a small amount of its own widget code and always matches the rest of the game.

Masking rules ("???", hidden hint) live in one place, the tracker, so every game shows hidden achievements the same way.

There is no out-of-the-box visual: a new consumer must write its own panel and toasts before players see anything.

## Relations
_None._
