# 0006 · Automatic transitions start on the next phrase

Status · Accepted · 2026-11-04

## Context

A transition that starts mid-phrase sounds wrong even when beats line up. Quick and Mix modes promise a good transition from one tap.

## Decision

`sbe_transition_start_on_phrase` waits for the outgoing deck's next phrase boundary (`phrase_beats`, usually 16). The incoming deck is synced and started at once but held silent, so it is phase-locked when the blend begins. The engine reports `transition_starts_in_beats` so the UI can count down.

## Consequences

- One-tap mixes land on musical boundaries.
- A tap can take up to one phrase (about 30 s at 128 BPM) to start audibly; the countdown makes that visible.
- Phrase length depends on the beat grid being right.
