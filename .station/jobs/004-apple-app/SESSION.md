# Job 004 · apple app

Status: DONE

## Objective

First playable Apple app: Obsidian UI on the real engine (PR #5).

## Completed

- SoundboardUI components and Quick, Mix, Library, Appearance screens
- DJSession: import, analysis, Up Next ranking, phrase-quantised Mix, cues, sync, preview
- Engine: phrase-quantised transitions, cached auto-gain

## Active

None.

## Blockers

None.

## Decisions

- [ADR 0006](../../../docs/decisions/0006-phrase-quantised-transitions.md) transitions start on the next phrase

## Files changed

platforms/apple/, engine/src/engine.*, engine/include/soundboard/sbe.h

## Verification

Engine 25 tests. The owner built and ran the app on device; the first run surfaced job 005.

## Next actions

Library persistence: job 008.
