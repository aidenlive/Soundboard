# Platform audio research: iOS, Android, macOS

The product lives or dies on one question: **can the DJ hear something different from the crowd?**
This document records what each platform can actually do, what needs extra hardware, and what
needs platform-specific code. It drove every decision in [`../architecture.md`](../architecture.md).

Legend: ✅ works with the device alone · 🔌 needs external hardware · ⚙️ needs platform-specific code · ❌ not possible

---

## 1. The core problem, stated precisely

A DJ needs two independent audio buses:

| Bus | Who hears it | Contents |
|---|---|---|
| **Master** | The room | The mix |
| **Cue** (headphones / PFL) | Only the DJ | The next track, previewed and beat-matched before it is audible, optionally blended with the master |

A phone has, at most, one stereo output that the OS will give an app by default. Everything below
is about getting a *second* independent stereo (or mono) path, and about being honest when there
isn't one.

The system volume buttons are not a mixer: they scale the whole hardware output, so in any shared-
output configuration (e.g. a splitter cable) they move master and cue together. The engine therefore
owns **independent master gain, headphone gain, cue/master blend and per-channel gain**, and treats the
hardware volume as a fixed calibration that the user sets once.

---

## 2. iOS / iPadOS

### Routing model
- `AVAudioSession` category `.playback` sends audio to the **last-connected output only**: one route.
- Category **`.multiRoute`** routes distinct streams to different outputs at the same time — Apple's
  own example is a USB device plus headphones — and requires observing route-change notifications
  because a route change can invalidate the configuration.
- Apple documents the valid multi-route combinations as **USB + headphones, HDMI + headphones,
  Line-out + headphones**. The OS presents them as one aggregate device; `currentRoute` tells you which
  channels of the aggregate belong to which port. Long-standing Core Audio guidance is that multi-route
  needs something in the headphone port and does **not** work with AirPlay or Bluetooth.
- A class-compliant USB interface or DJ controller with ≥ 4 outputs appears as a single multichannel
  port; `setPreferredOutputNumberOfChannels` unlocks all channels.

### What that means

| Scenario | iOS | Notes |
|---|---|---|
| Master on built-in speaker, cue in AirPods | ❌ | Speaker and Bluetooth can't be used together by one app |
| Master on Bluetooth speaker, cue in wired headphones | ❌ | Bluetooth is excluded from multi-route |
| One wired output + stereo→mono **splitter cable** | 🔌 ⚙️ | L = master (mono), R = cue (mono). The established mobile technique (djay "Split Output") |
| USB-C DAC/interface for master + wired headphones | 🔌 ⚙️ | `.multiRoute`, channel map from `currentRoute` |
| 4-channel USB interface / DJ controller | 🔌 | Single device, single clock — the best experience |
| HDMI / Line-out for master + headphones | 🔌 ⚙️ | Multi-route |
| Bluetooth master, no cue | ✅ | Works; latency must be compensated in the UI (playhead, waveform) |
| AirPlay master | ⚠️ | ~2 s buffering: playback only, not live mixing |

**Open question to verify on device (Routing Lab):** how the USB-C-to-3.5 mm adapter on USB-C iPhones
is classified (`.headphones` vs `.usbAudio`) and whether it combines with a second USB DAC through a hub
under `.multiRoute`.

### Latency
- `setPreferredIOBufferDuration(0.005)` typically yields 128–256 frames at 48 kHz on modern devices.
- `outputLatency` + `ioBufferDuration` gives the figure used for alignment and for drawing the playhead.

---

## 3. Android

### Low-latency stack
- **Oboe** (Apache-2.0, C++) wraps **AAudio** on Android 8.1+ and OpenSL ES below.
- Google's checklist: request `PerformanceMode::LowLatency`, request **Exclusive** sharing (MMAP —
  writes straight into the buffer the DSP reads), use a data callback, and don't block in it.
  Google's own measurements (round-trip): ~20 ms with all recommendations; 205 ms without low-latency
  mode; **160 ms when an app requests 44.1 kHz on AAudio** (system resampling path) vs 23 ms with Oboe's
  resampler — so the engine runs at the device's native rate.
- Exclusive mode may be refused or later revoked; the stream must be inspected after opening.

### Device selection and multichannel
- `AudioManager.getDevices(GET_DEVICES_OUTPUTS)` lists outputs with type, channel counts and
  **channel index masks**. `setDeviceId()` binds a stream to a device and **is honoured on AAudio
  (API 28+) but not on OpenSL ES** → `minSdk 28`.
- Channel index masks address USB channels by number (a 4-channel interface is `0xF`; master on 0/1,
  cue on 2/3) rather than by speaker position. AAudio opens > 2-channel streams with an index mask, so
  channel *n* of the stream is physical output *n*.

### Two outputs at once
- Android 12 added *combined audio device routing* — but through **system APIs for privileged apps**
  (`setPreferredDevicesForStrategy`), not for third-party apps. The same page notes simultaneous
  routing to multiple USB devices isn't supported; Android 14 relaxes this for USB devices *of different
  types* given kernel/vendor support.
- For a normal app, opening a second stream on a different device is **policy-dependent per phone**:
  the OS may silently re-route it. The host therefore treats a second device as a capability to
  **probe**: open, compare `getDeviceId()` with the request, fall back to master-only (and tell the user)
  if it was re-routed.

| Scenario | Android | Notes |
|---|---|---|
| 4-channel USB interface / DJ controller | 🔌 | Best path; one stream, index-mask channels |
| USB-C splitter / headphone dongle + splitter cable | 🔌 ⚙️ | Split-mono |
| Speaker (master) + wired headphones (cue) | ⚙️ probe | Works on some devices; many force media to the headset |
| USB DAC (master) + wired headset (cue) | ⚙️ probe | Different device types; vendor-dependent |
| Bluetooth master | ✅ | Latency compensation needed |

---

## 4. macOS

- Core Audio exposes every device; an app can run **any number of output devices concurrently**, each
  on its own clock. Enumeration: `kAudioHardwarePropertyDevices`, stream configuration (channels),
  transport type, latency + safety offset + buffer size.
- **Aggregate devices** (Audio MIDI Setup, or programmatically via `AudioHardwareCreateAggregateDevice`)
  combine devices into one; drift compensation is enabled per sub-device
  (`kAudioSubDevicePropertyDriftCompensation`), with a quality setting from 0–128. Historically the HAL's
  compensation was a simple sample doubling/dropping algorithm.
- Decision: prefer one multichannel device; otherwise run the cue bus on a second device through the
  engine's **own drift-compensated resampler** (cubic Hermite + PI-controlled ratio). This avoids asking
  users to build aggregate devices and gives better quality than sample dropping. Measured in tests:
  < 20 ppm ratio wander (≈ 0.03 cent), zero underruns across ±500 ppm drift with mismatched
  buffer sizes.

| Scenario | macOS |
|---|---|
| Built-in speakers (master) + headphone jack (cue) | ⚙️ two devices, drift-compensated |
| USB interface ≥ 4 ch | 🔌 single device |
| Bluetooth speaker master + wired headphones cue | ⚙️ + cue delayed to line up with the speaker |
| DJ controller with audio | 🔌 |

---

## 5. Bluetooth

| Codec / path | Typical added latency | Usable for |
|---|---|---|
| SBC / AAC (A2DP) | 100–200 ms | Master playback with compensation; **not** cueing |
| LE Audio / LC3 (Android 13+ where supported) | tens of ms | Borderline for cueing; still not recommended |
| aptX Low Latency / LC3plus | lower, hardware-specific | Rare on phones |

iOS does not expose the active codec. Neither platform lets an app choose it.

**Policy:**
1. Never deny Bluetooth — beginners will use it for master.
2. Read the OS-reported latency and **shift the waveform/playhead** so what you see matches what the room hears.
3. When master is wireless and cue is wired, **delay the cue bus** by the difference so beat-matching by
   ear still works (`sbe_engine_set_latency_compensation`).
4. Never delay the master to wait for slow headphones; report it instead.
5. AirPlay/Cast buffer for seconds: playback only.

---

## 6. Engine options evaluated

| Option | Verdict |
|---|---|
| AVAudioEngine (Apple) / AAudio directly (Android) | Good hosts, but two separate mixers to keep identical — rejected as the *engine*; used as the *host layer* |
| JUCE | Mature, cross-platform; GPL or commercial licence, large footprint, owns the app structure — rejected |
| Superpowered | DJ-focused and fast; commercial licence fees per platform, closed source — kept as fallback for time-stretch only |
| miniaudio | Excellent portable I/O; no DJ-specific routing control on mobile — not needed given native hosts |
| **Own C++17 core + thin native hosts** | ✅ Chosen. One mixer, one set of tests, identical behaviour on every platform; hosts are ~300 lines each |

Supporting libraries planned (licence-checked):
- **Time-stretch / key-lock:** Signalsmith Stretch (MIT) first; Rubber Band (GPL/commercial) as benchmark.
- **Tempo sync with other apps/devices:** Ableton Link SDK (GPLv2 or proprietary licence from Ableton).
- **Stems:** on-device source separation via Core ML / Android NNAPI-backed runtimes (Phase 3).

---

## 7. Music sources (a constraint the brief doesn't mention)

DRM-protected streaming catalogues cannot be decoded from files; they require licensed partner
integrations:
- Spotify withdrew DJ-app support in 2020 and returned in September 2025 to the **desktop** versions of
  rekordbox, Serato and djay only — mobile versions excluded.
- Apple Music opened DJ integration to rekordbox, Serato, Engine DJ and others in March 2025 (djay since 2024).
- TIDAL has been available in the major DJ apps for some time.

**Implication:** launch on local files (Files app / MediaStore / Finder, plus Apple Music library items
that are DRM-free), design the library layer for pluggable providers, and pursue partner agreements
early — they gate the beginner audience more than any feature.

---

## Sources

- [AVAudioSession.Category.multiRoute — Apple Developer](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudiosession/category-swift.struct/multiroute.md)
- [Audio Session Programming Guide: Configuring an Audio Session — Apple](https://developer.apple.com/library/ios/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html)
- [Core Audio mailing list: Multiroute audio limitations](https://lists.apple.com/archives/coreaudio-api/2013/May/msg00008.html)
- [AVAudioEngine and Multiroute — Apple Developer Forums](https://developer.apple.com/forums/thread/15416)
- [Low latency audio — Android Developers](https://developer.android.com/games/sdk/oboe/low-latency-audio)
- [Full Guide to Oboe — google/oboe](https://github.com/google/oboe/blob/main/docs/FullGuide.md)
- [Combined audio device routing — Android Open Source Project](https://source.android.com/docs/core/audio/combined-audio-routing?hl=en)
- [AudioFormat channel index masks — Android Developers](https://developer.android.com/reference/android/media/AudioFormat)
- [aaudio: fix multichannel legacy streams (AOSP commit)](https://gitlab.e.foundation/e/os/android_frameworks_av/-/commit/16c66dd1e60d6b65b846f371c2ae4bf2b673545f)
- [Core Audio mailing list: aggregate device drift compensation](https://lists.apple.com/archives/coreaudio-api/2009/Nov/msg00207.html)
- [Core Audio mailing list: drift compensation quality](https://lists.apple.com/archives/coreaudio-api/2021/Jul/msg00002.html)
- [djay: audio setup & pre-cueing — Algoriddim](https://help.algoriddim.com/topic/first-steps/audio-setup)
- [djay for Android: Split Output — Algoriddim](https://help.algoriddim.com/user-manual/djay-android/getting-started/audio)
- [Bluetooth latency when DJing: codec comparison — Inspired by Beatz](https://www.inspiredbybeatz.com/fr/latence-bluetooth-djing-choix-codec/)
- [Spotify streaming returns to DJ software — MusicRadar](https://www.musicradar.com/music-tech/dj-software/after-5-years-spotify-streaming-returns-to-dj-software-but-theres-a-catch)
- [Apple Music now integrated with more DJ apps — MacRumors](https://www.macrumors.com/2025/03/25/dj-with-apple-music/)
