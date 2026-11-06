# Job 010 · refinement stage 1

Status: ACTIVE

## Objective

First of three stages of the owner's refinement brief (2026-11-06): track management, formats,
reset controls, Settings beyond Appearance, and persistent named sessions. Apple first; Android
follows on the same engine and file formats.

## Completed

- Import copies files in under a file coordinator, de-duplicates by content hash, and analyses
  two files at a time.
- Decoder falls back to AVAssetReader; DRM-protected files are named.
- `LibraryStore` (tracks, playlists, cue points, saved loop), `SessionStore` (named sessions) and
  `PreferencesStore`.
- `DJSession`: queue, eject, mixer reset, startup phases, autosave, restore, and session switching.
- Library screen: All tracks, Queue and playlists; sorting; selection mode; swipe and menus.
- Settings: Audio & routing, Mixing, Controllers, Library, Sessions, Reset, About.
- Engine: `sbe_deck_set_loop` with a test.

## Active

Waiting for the owner's Mac build of the stage-1 PR.

## Blockers

Swift cannot be compiled in the build workspace.

## Decisions

- [ADR 0007](../../../docs/decisions/0007-library-and-sessions.md)

## Files changed

`engine/` (set loop), `platforms/apple/Sources/SoundboardAudio/` (Track, AudioFormats,
CoreAudioDevices), `platforms/apple/Sources/SoundboardUI/Model/` (Persistence, Preferences,
Library, Sessions, DJSession), `Screens/` (LibraryView, SettingsView, RootView, Shared, Quick,
Mix), `Tests/SoundboardUITests/PersistenceTests.swift`, docs.

## Verification

- Engine: 26 tests pass.
- Swift: not compiled here; the owner builds on macOS.

## Next actions

- Fix whatever the Mac build reports.
- Stage 2: scratch and jog, pitch, progressive DJ controls.
