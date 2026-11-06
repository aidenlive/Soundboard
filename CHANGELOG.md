# Changelog

Versions follow semver. The top entry matches `version` in `station.json` and the latest git tag.

## 0.2.0 · 2026-11-06

The owner's refinement brief, all seven areas, on iPhone and Mac (Android follows on the same
engine and file formats).

### Added

- DJ layout (landscape: MIX · DJ). Two on-screen jog wheels with vinyl scratching, pitch faders
  (±8/16/50 %), nudge, and phase between the decks ([ADR 0008](docs/decisions/0008-vinyl-platter.md)).
- Deck tools for any deck (record button, or the deck's ⋯): jog, beat loops ¼–32 with halve,
  double and reloop, beat jump, hot cues, EQ, and beat-synced echo.
- Contextual overlays: tap a BPM for pitch, nudge, sync and range. The loop button's menu holds
  every loop size.
- Visualizer: Spectrum, Radial, Scope and Pulse, with colour, sensitivity, beat motion and track
  info. It has a fullscreen stage. On iPhone and iPad an external display or AirPlay screen gets
  the visualizer instead of a mirror; on Mac it opens in its own window for a second display
  ([ADR 0009](docs/decisions/0009-visualizer-and-second-screen.md)).
- Launch sequence: the Split mark alone, then Pulse only if loading is still running, never
  together. Black launch screen. Reduce Motion respected.
- Layout rules: readouts use tabular figures and keep their width, titles stay on one line, and
  labels shrink before they clip. Quick view scales its deck to the screen and moves the knobs into
  Deck tools on short phones. Pads move into Deck tools when the Mix view is narrow. iPad portrait
  gets the Mix layout.
- Engine: vinyl platter (`sbe_deck_jog_touch`, `jog_scratch`, `jog_bend`, `set_motor_time`) and a
  visual tap of the master output (`sbe_engine_read_visual`). 32 tests.

- Saved sessions: named sessions with decks, mixer, queue and library view. They save
  automatically, and the last one reopens at launch with decks paused
  ([ADR 0007](docs/decisions/0007-library-and-sessions.md)).
- Persistent library with playlists and a per-session queue. Cue points and the saved loop are
  kept with each track.
- Removing tracks from decks (eject), from the queue, from playlists and from the library, with
  selection mode for several at once.
- Reset controls for the mixer, the audio configuration and all settings.
- Settings pages: Audio & routing (output pickers, monitoring, buffer size, master ceiling),
  Mixing, Controllers, Library, Sessions, Reset and About. Platform-only settings are badged.
- Engine: `sbe_deck_set_loop` restores a saved loop.

### Fixed

- M4A and other files that failed to import or play. Files are copied in under file
  coordination, which also downloads iCloud files. Decoding falls back to AVAssetReader.
  Copy-protected files get a clear message.
- Decks survive an iOS audio-server restart.

## 0.1.0 · 2026-11-05

First tagged version. Audio foundation complete; the Apple app plays two decks on the real engine.

### Added

- **Engine** (`engine/`): shared C++17 core behind a C API (`sbe.h`).
  - Decks, three-band isolator EQ, filter, crossfader curves, master and cue buses with PFL and a
    cue/master headphone blend, look-ahead limiters, preview player.
  - Four output topologies: master only, split mono, multichannel, separate cue device with
    drift compensation.
  - Sync (tempo and phase), phrase-quantised transitions, beat echo.
  - Analysis: BPM and beat grid, key with Camelot codes, BS.1770 loudness, three-band waveform.
  - 25 tests, also run under AddressSanitizer, UndefinedBehaviorSanitizer and ThreadSanitizer;
    an offline routing prototype that proves the master is bit-identical with headphone activity.
- **Apple** (`platforms/apple/`): `SoundboardAudio` host (AVAudioSession, Core Audio, AUAudioUnit),
  `SoundboardUI` (Obsidian components, Quick, Mix, Library and Appearance screens), the Soundboard
  and Routing Lab apps.
- **Android** (`platforms/android/`): Oboe host over JNI, Kotlin route planning, Routing Lab app.
  Not yet built.
- **Design**: Obsidian design system in OKLCH (`design/tokens/`) with themes, accents and waveform
  schemes chosen in Settings › Appearance.
- **Brand**: Split mark, Pulse element and app icons (`brand/`).
- **Station 1.2.1 layout**: manifest, `.station/`, docs site and design kit in `public/`, root
  `index.html`, Makefile, checks in `make validate`, `deploy/`, archive and audit reports.

### Fixed

- iOS: decoding no longer crashes on files whose reported length is 0; the audio session activates
  off the main thread (PR #6).
- macOS: unsafe pointer warning in `CoreAudioDevices` (PR #2).

### Dependencies

- Oboe 1.9.3 and AndroidX libraries, pinned in `platforms/android/gradle/libs.versions.toml`.
- No new dependencies for the Station tooling: `tools/` uses Node 20+ and Python 3 standard
  libraries only. Docker is optional and used only by `make up`.
