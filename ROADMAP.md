# Roadmap

What is next, by version. Each version ends with an exit test; audio quality, timing and
reliability gates are never waived. What already shipped is in [CHANGELOG.md](CHANGELOG.md).

## 0.3.0 · Audio validated on hardware; Android app

- Run Routing Lab through the [on-device validation matrix](docs/guides/qa.md#on-device-validation-matrix)
  on iPhone, Android and Mac.
- Record callback timing (p99 render time), xruns, actual buffer sizes and reported latencies per row.

- Android: MediaExtractor and MediaCodec decoding; Compose screens on the same tokens, sessions
  and library format; jog wheel and visualizer (Presentation API for a second display).

**Exit:** the cue chirp never reaches the speakers in any configuration, with no glitches over 30
minutes; the Android app reaches parity with 0.2.0.

## 0.4.0 · Reliable everywhere

- Crash recovery beyond autosave (resume after a crash mid-set).
- Measure SwiftUI `Canvas` waveform performance on device; move to Metal if it misses 120 Hz.
- Wire `SoundboardUI` spacing and radius literals to the generated `space` and `radius` tokens.

**Exit:** 10 first-time users each complete a transition within 60 seconds unaided.

## 0.5.0 · DJ Mode depth (Level 3)

- Key-lock (Signalsmith Stretch), slip, rolls, phrase detection, beat-grid editing.
- Recording to file with set history and tracklist export.
- MIDI (CoreMIDI, android.media.midi) with a shared mapping format; the first three
  class-compliant controllers.
- Cross-device sync service: cue points, playlists, analysis, preferences.

**Exit:** two working DJs play 60-minute sets on phone and Mac; no xruns; sync round-trips cue edits.

## 0.6.0 · Pro Studio (Level 4)

- Four decks, routing matrix, latency calibration wizard (loopback), sampler, external input decks.
- Stems (on-device separation), Ableton Link, customisable layouts, controller profiles.
- Streaming partners (Apple Music, TIDAL, others) as agreements allow.

## Risks

| Risk | Mitigation |
|---|---|
| Android second-device routing varies by OEM | Probe and fallback already in the host; test on owned devices with loopback dongles (cloud device farms cannot hear audio) |
| iOS multi-route edge cases (USB-C adapters, hubs) | Routing Lab validation before UI work; the splitter path is always available |
| Streaming licences | Business track runs in parallel; the product works fully with local files |
| Time-stretch CPU on low-end Android | Quality tiers; key-lock off by default on low tiers |
| Beat-grid accuracy on live or variable-tempo music | Dynamic grids (tempo map) in 0.4.0; manual grid editing |
| Name and trademark | "Soundboard" is a working name; clearance before any public release |
