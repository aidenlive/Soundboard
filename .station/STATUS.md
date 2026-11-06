# Status

Version 0.2.0 · draft · 2026-11-06

## What passes

| Check | Result | Where |
|---|---|---|
| `make validate` | Green on Linux; macOS adds Swift build and tests | Build workspace and fresh checkout of the 0.1.0 zip, 2026-11-05 |
| Engine tests | 32 of 32, plain, ASan + UBSan, TSan | `engine/tests/` |
| Routing prototype | Master bit-identical with headphone activity | `make demo` |
| `make e2e` | Every site page, link, asset and anchor resolves | `tools/site/e2e.mjs` |
| Swift build and tests | 0.2.0 not yet compiled: reviewed for compile errors without a toolchain | Owner's Mac |
| `make up` (Docker) | Not run: Docker Hub unreachable from the build workspace | `deploy/` |
| Android build | Never built | — |
| CI | Configured; blocked by GitHub account billing | `.github/workflows/ci.yml` |

## Open

| Item | Owner | Note |
|---|---|---|
| Build and run 0.2.0 | aidenlive | All Swift since PR #6 is uncompiled; paste Xcode errors |
| Tag v0.2.0 | aidenlive | This workspace cannot create tags: `git tag -a v0.2.0 -m "Soundboard 0.2.0" && git push origin v0.2.0` |
| On-device validation matrix | aidenlive | Job 007; needs the devices in docs/guides/qa.md |
| GitHub Actions billing | aidenlive | Until fixed, `make validate` is run by hand before merge |
| Name and trademark clearance | aidenlive | "Soundboard" is a working name |
| Tier | aidenlive | Set to `internal` (private repository); switching to `open` needs a station.center landing |
| Android app to 0.2.0 parity | Claude | Job 009, version 0.3.0 |

## Jobs

| Job | Status |
|---|---|
| [001 audio foundation](jobs/001-audio-foundation/SESSION.md) | DONE |
| [002 design direction](jobs/002-design-direction/SESSION.md) | DONE |
| [003 brand](jobs/003-brand/SESSION.md) | DONE |
| [004 apple app](jobs/004-apple-app/SESSION.md) | DONE |
| [005 ios decode fix](jobs/005-ios-decode-fix/SESSION.md) | DONE |
| [006 station adoption](jobs/006-station-adoption/SESSION.md) | DONE |
| [007 hardware validation](jobs/007-hardware-validation/SESSION.md) | PLANNED |
| [008 library persistence](jobs/008-library-persistence/SESSION.md) | DONE |
| [009 android app](jobs/009-android-app/SESSION.md) | PLANNED |
| [010 refinement](jobs/010-refinement/SESSION.md) | DONE |
