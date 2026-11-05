# QA

## Automated

`make validate` runs, in order:

| Step | Command | Fails when |
|---|---|---|
| Dependency pins | `node tools/deps/check.mjs` | A Gradle version is dynamic (`+`, ranges, `latest`), or `Package.swift` gains a dependency without `Package.resolved` |
| Design tokens | `python3 design/tokens/generate.py --check` | Swift, CSS or DESIGN.md differ from the token JSON |
| Site | `node tools/site/build.mjs --check` | `public/` or `index.html` differ from what the generator writes |
| Dev logins | `node tools/logins/check.js` | A default in code or config is missing from [dev-logins.md](dev-logins.md) |
| Typecheck | engine build with `-Werror`; `swift build` on macOS; `node --check` on tools | Any compile error or engine warning |
| Lint | `node tools/station/check.mjs` | The Station layout, manifest, version agreement, README shape, job files or links are wrong |
| Tests | `ctest`; `swift test` on macOS | Any test fails |

`make e2e` checks the built site: every page opens, every relative link and asset resolves, every
in-page anchor exists. `make shots` retakes `docs/screenshot.png` with headless Chrome.

### Sanitizers

```bash
cmake -S engine -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all"
cmake --build build-asan -j && ./build-asan/sbe_tests
cmake -S engine -B build-tsan -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_FLAGS="-fsanitize=thread"
cmake --build build-tsan -j && ./build-tsan/sbe_tests concurrent
```

CI runs both (`.github/workflows/ci.yml`).

## On-device validation matrix

Run Routing Lab in each configuration. Confirm by ear and by the meters that the high cue chirp
never reaches the speakers, with no glitches over 30 minutes. Record p99 render time, xruns, actual
buffer size and reported latency per row in [job 007](../../.station/jobs/007-hardware-validation/SESSION.md).

| Device | Configurations |
|---|---|
| iPhone (USB-C) | speaker · USB-C to 3.5 mm + splitter · USB DAC + headphones (multi-route) · 4-channel controller · Bluetooth speaker |
| iPhone (Lightning) | Lightning to 3.5 mm + splitter · camera-kit USB interface |
| Android: Pixel, Samsung, one low-cost device | speaker + headset probe · USB-C dongle + splitter · 4-channel controller · Bluetooth A2DP · LE Audio |
| Mac (Apple silicon) | built-in + headphone jack (two devices) · USB interface · Bluetooth speaker master + wired cue |

## Before a release

1. `make validate` and `make e2e` green.
2. Matrix rows touched by the change re-run on hardware.
3. Light and dark (OLED, Graphite, Daylight) checked on a phone and a Mac.
4. `make shots`, `make site`, `make dist`; fresh-checkout test from the zip.
