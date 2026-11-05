# Soundboard

A cross-platform DJ application for iPhone, Android and macOS. It is simple enough to mix two tracks
in seconds and deep enough to play a full set.

This repository starts where the brief says to start: **audio first.** It holds the platform
research, a shared low-latency audio engine with independent master and headphone-cue buses, and
native audio hosts for each platform. It also includes a Routing Lab app for checking the routing on
real hardware before the full DJ interface is built on top.

## What's here

| Path | What |
|---|---|
| [`docs/research/platform-audio.md`](docs/research/platform-audio.md) | What iOS, Android and macOS can and can't do for DJ audio routing, Bluetooth, hardware and engine options |
| [`docs/architecture.md`](docs/architecture.md) | Engine signal flow, threading, output topologies, analysis, session/sync model |
| [`docs/product.md`](docs/product.md) | Assumptions challenged, missing capabilities, progressive workspace, design language |
| [`docs/roadmap.md`](docs/roadmap.md) | Phases, exit tests, on-device validation matrix, risks |
| [`docs/design/appearance.md`](docs/design/appearance.md) | Obsidian design system (default) and the user-selectable Appearance model |
| [`docs/brand.md`](docs/brand.md) · [`brand/`](brand) | Split mark, Pulse element, app icons and usage rules |
| [`design/tokens/`](design/tokens) | OKLCH palette and semantic tokens (themes, accents, waveform schemes) |
| [`engine/`](engine) | Soundboard Engine: shared C++17 core with a C API (`sbe.h`), tests and an offline routing prototype |
| [`platforms/apple/`](platforms/apple) | Swift package `SoundboardAudio` (AVAudioSession, Core Audio, AUAudioUnit host) + Routing Lab (iOS/macOS) |
| [`platforms/android/`](platforms/android) | Oboe/AAudio host (C++/JNI), Kotlin route planning, Routing Lab (Compose) |

## How headphone cueing works on each platform

| | Device alone | Splitter cable | USB interface / controller | Two outputs at once |
|---|---|---|---|---|
| iPhone | Master only | ✅ mono master + mono cue | ✅ | USB/HDMI/line-out + headphones via multi-route |
| Android | Master only | ✅ | ✅ | Depends on the phone (checked at runtime) |
| Mac | Two devices (speakers + headphone jack) | ✅ | ✅ | ✅ (drift-compensated) |

Where cueing isn't possible, the app says so plainly and still offers sync, visual beat-matching and
automatic phrase-aligned transitions.

## Build & test

```bash
# Engine (Linux/macOS/Windows): tests + routing prototype  (macOS: brew install cmake)
cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j
ctest --test-dir engine/build --output-on-failure
engine/build/sbe_routing_demo /tmp            # writes master/headphones/multichannel/split WAVs

# Apple (Swift package: engine + host + tests)
swift build && swift test
brew install xcodegen && (cd platforms/apple && xcodegen) && open platforms/apple/RoutingLab.xcodeproj

# Android (Routing Lab app + unit tests); requires Android SDK + NDK
cd platforms/android && gradle :app:testDebugUnitTest :app:assembleDebug
```

The engine has no dependencies. Oboe comes in through Gradle (prefab). The Apple side uses only
system frameworks.

## Status

Phase 0 (audio foundation) is complete. The engine passes 24 tests under AddressSanitizer,
UndefinedBehaviorSanitizer and ThreadSanitizer. The routing prototype confirms that headphone
activity leaves the master **bit-identical**. Next is the on-device validation matrix in
[`docs/roadmap.md`](docs/roadmap.md), then the Level 1–2 app.

The Swift package and the Android app have been code-reviewed but not yet compiled. GitHub Actions
(`.github/workflows/ci.yml`) builds and tests both, along with the engine on Linux and macOS, as soon
as Actions can run on this account.
