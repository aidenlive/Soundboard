# Architecture

One audio engine, three thin platform hosts, one session model.

```
┌──────────────────────────── App (per platform, native UI) ───────────────────────────┐
│  iOS: SwiftUI (touch-first)   Android: Jetpack Compose   macOS: SwiftUI + AppKit      │
│  Library · Decks · Mixer · Workspace layouts · MIDI mapping · Sync client             │
└───────────────▲──────────────────────────────────────────────▲───────────────────────┘
                │ commands (lock-free)                          │ status (atomics, 30–120 Hz)
┌───────────────┴──────────── Platform audio host ─────────────┴───────────────────────┐
│  Route discovery → RoutePlanner → device streams                                      │
│  iOS: AVAudioSession + RemoteIO AUAudioUnit   macOS: Core Audio HAL AUAudioUnit(s)     │
│  Android: AudioManager + Oboe/AAudio stream(s)                                         │
└───────────────▲───────────────────────────────────────────────────────────────────────┘
                │ sbe.h (C ABI)
┌───────────────┴──────────── Soundboard Engine (C++17, shared) ────────────────────────┐
│  Decks ─► Channel strips ─► Crossfader ─► Master bus ─► Limiter ─► Record tap          │
│                 └─(PFL)──► Cue bus ◄── Preview player                                  │
│                                  └─► Headphone mix (cue/master blend, gain, limiter)  │
│  Router: Master-only · Split-mono · Multichannel · Separate cue device (drift FIFO)   │
│  Sync (tempo + phase PLL) · Transitions · Analysis (BPM/grid, key, loudness, waveform)│
└───────────────────────────────────────────────────────────────────────────────────────┘
```

## Engine (`engine/`)

### Signal flow

```
Deck n ─ trim (+auto-gain) ─ 3-band isolator EQ ─ bipolar filter ─┬─ PFL ─────────────► Cue Σ
                                                                  └─ fader ─ echo ─ xfader ─► Master Σ
Preview player ───────────────────────────────────────────────────────────────────────► Cue Σ

Master Σ ─ master gain ─ look-ahead limiter ─┬─ record tap
                                             ├─ (blend) ─► Headphones = Cue Σ·(1−m) + Master·m
                                             └─ latency-compensation delay ─► router
Headphones ─ headphone gain ─ safety limiter ─ latency-compensation delay ─► router
```

| Block | Implementation | Why |
|---|---|---|
| Deck playback | Cubic Hermite interpolation, variable rate, 4 ms start/stop ramps, 3 ms crossfaded jumps | Seeks, loops, hot cues and stops are click-free (tested: worst step equals the signal's own slope) |
| EQ | Linkwitz–Riley 4th-order 3-band isolator, all-pass compensated | Flat (±0.05 dB) at unity, full band kill (−56 dB low, −44 dB high) — club-mixer behaviour |
| Filter | TPT state-variable LP→HP series pair | Stable under fast sweeps; transparent at centre; no topology switch at zero |
| Crossfader | Constant-power with curve blend to sharp cut | Equal loudness when blending, scratch-cut when wanted; parked side is bit-exact silence |
| Limiter | Look-ahead min-hold + box-average gain | Mathematically guaranteed ceiling, no instantaneous gain steps |
| Echo | Beat-synced, filtered feedback, post-fader | "Echo out" tails survive the fader cut |
| Sync | One-shot tempo + phase match, then PLL (±1 %) | Locks within ~1 s, follows leader tempo changes; half/double-time aware |
| Transitions | Blend · Bass swap · Filter sweep · Echo out, beat-length | The beginner "Mix" button |
| Drift FIFO | SPSC ring + Hermite resampler + PI ratio control | Second device on its own clock (macOS, Android) |

### Threading

- **Audio thread** calls `render()`/`renderCue()`. It never locks, allocates, frees or logs.
- **Control thread** calls everything else. Each call becomes a `Command` on a lock-free SPSC queue,
  drained at the start of the next callback: changes land on block boundaries, in order.
- **Track memory**: the control side owns `shared_ptr`s; the audio thread sees raw pointers.
  A generation counter acknowledges swaps so a buffer is only freed after the audio thread has let go.
- **Status**: decks and buses publish relaxed atomics after each callback; the UI polls at display rate.

Verified with ThreadSanitizer (400 concurrent load/play/EQ/loop operations against a running audio
thread) and AddressSanitizer/UBSan across the full suite.

### Output topologies

| Topology | Device view | Used when |
|---|---|---|
| `MASTER_ONLY` | stereo master | No second path exists — UI explains how to get one |
| `SPLIT_MONO` | L = master mono, R = cue mono | Splitter cable on one stereo jack |
| `MULTICHANNEL` | master on pair *a*, cue on pair *b* | 4-ch interface/controller; iOS multi-route aggregate |
| `SEPARATE_CUE_DEVICE` | master device + cue device | macOS two devices; Android when the policy allows |

`RoutePlanner` (Swift and Kotlin, identical rules, unit-tested on both) picks the topology from the
reported outputs, in that preference order, and computes latency alignment.

### Analysis (background thread)

- **BPM + beat grid**: spectral-flux onset envelope → autocorrelation over a folding range →
  whole-track comb alignment for sub-0.01 BPM precision → kick-band check to put the grid on the beat,
  not the off-beat. Tested at 87–140 BPM: exact BPM, grid within ±1 ms.
- **Key**: chromagram vs Krumhansl–Kessler profiles; Camelot code and harmonic compatibility.
- **Loudness**: ITU-R BS.1770-4 integrated LUFS (reference coefficients reproduced exactly); drives
  auto-gain so beginners never ride the trim.
- **Waveform**: low/mid/high peak bins for the three-colour waveform.

## Platform hosts (`platforms/`)

| | iOS | macOS | Android |
|---|---|---|---|
| Discovery | `AVAudioSession.currentRoute`, route-change / interruption / media-reset notifications | Core Audio device list, transport type, latency | `AudioManager.getDevices`, `AudioDeviceCallback` |
| Output | RemoteIO `AUAudioUnit`, N channels | HAL `AUAudioUnit` per device | Oboe stream(s), LowLatency + Exclusive, index-mask channels |
| Second path | `.multiRoute` aggregate | second device + drift FIFO | second stream, probed, fallback |
| Decode | `AVAudioFile` | `AVAudioFile` | `MediaExtractor` + `MediaCodec` (Phase 1) |

Both apps ship a **Routing Lab** screen: it plays a low pulse on the master and a high chirp on the
cue, with meters and the plan explanation, so routing is validated *by ear on real hardware* before any
DJ UI is built on top.

## Session model and sync

Local-first, synced when online. Shared schema across platforms (SQLite on every device):

| Entity | Key fields | Sync rule |
|---|---|---|
| Track | content hash (first/last 1 MB + duration) + optional audio fingerprint | Identity follows the audio, not the file path |
| Analysis | track id, grid (bpm, first beat), key, LUFS, waveform blob | Deterministic — recomputed locally if missing; manual grid edits win |
| Cue points / loops | track id, slot, frame, label, colour | Per-field last-writer-wins with hybrid logical clocks |
| Playlists / crates | ordered track ids | Operation-based list CRDT (insert/move/remove) |
| Session / set history | ordered entries with timestamps | Append-only |
| Preferences | key/value | LWW |

CloudKit is not available on Android, so sync is a small service of our own (HTTPS + Postgres, or a
hosted CRDT store) with end-to-end encryption of user data. Audio files themselves are not synced by
default (licensing and size); the library matches by content hash on each device.

## Modules

```
engine/            C++ core (no platform code) — tests, routing prototype
platforms/apple/   SoundboardAudio (Swift package: session, devices, host, tracks) + Routing Lab
platforms/android/ Oboe host (C++/JNI) + Kotlin audio layer + Routing Lab
(planned)
shared/schema/     Session database schema + migrations (shared SQL)
features/          library, mixer UI, performance pads, MIDI mapping, recording, sync — per platform,
                   behind the same engine API
```
