# Local development

## Requirements

| Part | Needs | Install (macOS) |
|---|---|---|
| Engine | CMake 3.16+, a C++17 compiler | `brew install cmake` (Xcode supplies clang) |
| Apple apps | macOS 14+, Xcode 15+, XcodeGen | `brew install xcodegen` |
| Android app | JDK 17, Android SDK, NDK, CMake 3.22.1 (via SDK manager), Gradle 8.11 | Android Studio |
| Checks and site | Node 20+, Python 3 | `brew install node` |
| Containers (optional) | Docker with Compose | Docker Desktop |

`make setup` reports which of these are present and generates the Xcode project when XcodeGen is
installed.

## Everyday commands

| Command | Does |
|---|---|
| `make build` | Builds the engine (CMake) and, on macOS, the Swift package |
| `make test` | Engine tests (`ctest`) and, on macOS, `swift test` |
| `make validate` | Every check, then the tests; the same command CI runs |
| `make dev` | macOS: opens `platforms/apple/Soundboard.xcodeproj`. Elsewhere: serves the docs site |
| `make tokens` | Regenerates Swift, CSS and DESIGN.md from `design/tokens/obsidian.tokens.json` |
| `make site` | Regenerates `public/` and the root `index.html` |
| `make site-serve` | Serves `public/` at <http://localhost:8052/> |
| `make demo` | Runs the routing prototype; writes master, headphone and split WAVs to `out/` |

## Apple

```bash
make setup                                   # runs xcodegen in platforms/apple
open platforms/apple/Soundboard.xcodeproj
```

Schemes: **Soundboard** (the app) and **RoutingLab** (routing check). Both build for iOS and macOS
from one target. To run on an iPhone, set your team under Signing & Capabilities; nothing in the
repository holds a team ID. `Package.swift` at the root builds the engine and Swift targets without
Xcode: `swift build && swift test`.

## Android

```bash
cd platforms/android
gradle :app:testDebugUnitTest :app:assembleDebug
```

Open `platforms/android` in Android Studio to run the Routing Lab on a device. The Android project
has not been built yet; see [job 009](../../.station/jobs/009-android-app/SESSION.md).

## Engine only

```bash
cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j
ctest --test-dir engine/build --output-on-failure
```

Sanitizer builds are in [QA](qa.md#sanitizers).
