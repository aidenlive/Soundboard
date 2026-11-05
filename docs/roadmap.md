# Roadmap

Each phase ends with an exit test. Audio quality, timing and reliability gates are never waived.

## Phase 0 — Audio foundation ✅ (this commit)

- Platform research and routing decisions (`docs/research/platform-audio.md`).
- Shared C++ engine: decks, mixer, master/cue buses, four output topologies, drift-compensated second
  device, latency compensation, preview player, sync, transitions, recording tap, analysis.
- 24 automated tests incl. sanitizers; offline routing prototype proving master isolation.
- iOS/macOS and Android hosts + Routing Lab apps.

**Exit test — on-device validation matrix (next step):** run Routing Lab on each configuration and
confirm by ear + meters that the cue chirp never reaches the speakers, with no glitches over 30 minutes.

| Device | Configurations |
|---|---|
| iPhone (USB-C) | speaker · USB-C→3.5 mm + splitter · USB DAC + headphones (multi-route) · 4-ch controller · BT speaker |
| iPhone (Lightning) | Lightning→3.5 mm + splitter · camera-kit USB interface |
| Android: Pixel, Samsung, one low-cost device | speaker+headset probe · USB-C dongle + splitter · 4-ch controller · BT A2DP · LE Audio |
| Mac (Apple silicon) | built-in + headphone jack (two devices) · USB interface · BT speaker master + wired cue |

Record callback timing (p99 render time), xruns, actual buffer sizes and reported latencies per row.

## Phase 1 — Playable two-deck app (Levels 1–2)

- Library: local files (Files / MediaStore / Finder), background analysis queue, content-hash identity.
- Decoders: AVAudioFile; Android MediaExtractor + MediaCodec.
- Quick Control and Mix layouts; Mix button; Up Next suggestions; preview in headphones.
- Waveform renderer (Metal / Compose Canvas or Vulkan) at 120 Hz on capable displays.
- Session persistence; crash/interruption recovery.

**Exit:** usability test — 10 first-time users each complete a transition within 60 s unaided.

## Phase 2 — DJ Mode (Level 3)

- Key-lock (Signalsmith Stretch), slip, quantised pads, rolls, phrase detection, beat-grid editing.
- Recording to file with set history / tracklist export.
- MIDI (CoreMIDI, android.media.midi) with a shared mapping format; first 3 class-compliant controllers.
- Cross-device sync service (cue points, playlists, analysis, preferences).

**Exit:** two working DJs play 60-minute sets on phone and Mac; no xruns; sync round-trips cue edits.

## Phase 3 — Pro Studio (Level 4)

- 4 decks, routing matrix, latency calibration wizard (loopback), sampler, external input decks.
- Stems (on-device separation), Ableton Link, customisable layouts, controller profiles.
- Streaming partners (Apple Music / TIDAL / others) as agreements allow.

## Risks

| Risk | Mitigation |
|---|---|
| Android second-device routing varies by OEM | Probe + fallback already in host; device matrix in CI farm (Firebase Test Lab can't hear audio — use loopback dongles on owned devices) |
| iOS multi-route edge cases (USB-C adapters, hubs) | Routing Lab validation before UI work; splitter path always available |
| Streaming licences | Business track from Phase 1; product works fully with local files |
| Time-stretch CPU on low-end Android | Quality tiers; key-lock off by default on low tiers |
| Beat-grid accuracy on live/variable-tempo music | Dynamic grids (tempo map) in Phase 2; manual grid editing |
