# Job 010 · refinement

Status: DONE

## Objective

The owner's refinement brief of 2026-11-06, shipped as one build on main (0.2.0) at the owner's
request. It covers seven areas:

- audio and track management;
- DJ capabilities;
- Settings;
- sessions;
- visualizer and second screen;
- responsive UI and typography;
- the loading experience.

Apple first; Android follows on the same engine and files (0.3.0).

## Completed

- Audio and track management:
  - Import copies files in under coordination, de-duplicated by hash.
  - Decoding falls back to AVAssetReader; DRM files are named.
  - Eject, queue, playlists, remove from every place.
  - Reset mixer, audio configuration and all settings.
- DJ capabilities:
  - Engine vinyl platter.
  - Jog wheel, pitch fader, nudge.
  - DJ layout, Deck tools (jog, loops, cues, EQ, echo), tempo popover, loop menu.
- Settings: Audio & routing, Mixing, Controllers, Library, Sessions, Visualizer, Appearance, Reset,
  About; platform badges.
- Sessions:
  - One library with cue points and saved loops.
  - Named sessions with autosave and restore at launch.
  - Restore after an iOS media reset.
- Visualizer:
  - Engine tap, FFT feed, four styles.
  - Fullscreen stage; iOS external display scene; macOS window.
- Responsive UI and typography:
  - Layout metrics and typography rules.
  - Adaptive Quick and Mix views; iPad portrait gets Mix.
- Loading: mark first, then Pulse only while loading, never together; black launch screen.

## Active

Nothing.

## Blockers

Swift cannot be compiled in the build workspace. GitHub Actions is blocked by billing.

## Decisions

- [ADR 0007](../../../docs/decisions/0007-library-and-sessions.md) library and sessions
- [ADR 0008](../../../docs/decisions/0008-vinyl-platter.md) vinyl platter
- [ADR 0009](../../../docs/decisions/0009-visualizer-and-second-screen.md) visualizer and second screen

## Files changed

`engine/` (set loop, platter, visual tap), `platforms/apple/` (most of SoundboardAudio and
SoundboardUI, app entry, project.yml, assets), tests, docs, `.station/`.

## Verification

- Engine: 32 tests, plain and under ASan, UBSan and TSan.
- Swift: two independent reviews for compile errors without a toolchain; their findings fixed.
- Not done here: compiling Swift and running on iPhone, iPad and Mac. That needs the owner's
  machines.

## Next actions

Owner builds 0.2.0 and reports errors; then job 009 (Android).
