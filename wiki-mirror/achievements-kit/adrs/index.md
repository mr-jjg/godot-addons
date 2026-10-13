# ADRs

**Status:** active

## Overview
Decisions behind the addon: definitions are generated GDScript written only by the dock, per-player truth is one bool and one int per achievement in the game's synced save, Snapser gets one aggregate statistic rather than one per achievement, the runtime depends on nothing and talks to Snapser only through a duck-typed bridge, and in-game UI stays per game.

## Contents
- [Definitions are generated GDScript consts, written only by the dock](decision-record:mv5fodcq-00e0-nfbph)
- [Per-player truth is one earned bool and one progress int per achievement, in the game's synced save](decision-record:mv5fosqi-00eo-chsfmg)
- [Snapser gets one aggregate statistic, not one per achievement](decision-record:mv5foss9-00eq-lymatc)
- [The runtime depends on nothing; the Snapser bridge is duck-typed](decision-record:mv5fosx0-00es-51ld1r)
- [In-game UI stays per game; the kit ships view-models, signals and debug actions](decision-record:mv5fosys-00eu-ccen1j)
