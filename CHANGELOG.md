# Changelog

Versions follow semver. The top entry matches `version` in `station.json` and the latest git tag.

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
