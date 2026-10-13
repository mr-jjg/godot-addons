# achievements_kit

**Status:** active

## Overview
**achievements_kit** — game-agnostic achievements for Godot 4.x. A runtime **tracker** (`AchKitTracker`) that a game extends as an autoload and that keeps per-player truth as two keys per achievement in the game's own save; a shared **schema and validator** (`AchKitSchema`); **generated-GDScript definitions** read and written by `AchKitCodegen`; an optional, duck-typed **Snapser bridge** (`AchKitSnapserBridge`) that mirrors earns as one analytics event each plus one aggregate statistic; and an **Achievements** editor dock (Editor Tool Kit) where designers author achievements without touching the generated file. The runtime and codegen have no dependencies and run headless and in exported games; only the dock needs `editor_tool_kit`. In-game UI stays per game: the kit ships view-models (`rows()`, `summary()`), signals and debug actions. Configured per project via `res://achievements_kit.config.json` (dock) and the tracker subclass's `configure()` call (runtime). Managed by etk's self-update dock.

## Contents
- [Architecture](toc:mv5fihp1-0031-gckvi5)
- [Usage](toc:mv5fihqx-0033-ag3ff5)
- [ADRs](toc:mv5fihsy-0035-sb2k9f)
