# Status

Version 0.1.0 · draft · 2026-11-05

## What passes

| Check | Result | Where |
|---|---|---|
| `make validate` | Green on Linux; macOS adds Swift build and tests | Build workspace and fresh checkout of the 0.1.0 zip, 2026-11-05 |
| Engine tests | 25 of 25, plain, ASan + UBSan, TSan | `engine/tests/` |
| Routing prototype | Master bit-identical with headphone activity | `make demo` |
| `make e2e` | Every site page, link, asset and anchor resolves | `tools/site/e2e.mjs` |
| Swift build and tests | Built by the owner on macOS before PR #6; PR #6 not yet rebuilt | Owner's Mac |
| `make up` (Docker) | Not run: Docker Hub unreachable from the build workspace | `deploy/` |
| Android build | Never built | — |
| CI | Configured; blocked by GitHub account billing | `.github/workflows/ci.yml` |

## Open

| Item | Owner | Note |
|---|---|---|
| Rebuild and run after PR #6 | aidenlive | Decode crash and session warning fixes are unverified on device |
| On-device validation matrix | aidenlive | Job 007; needs the devices in docs/guides/qa.md |
| GitHub Actions billing | aidenlive | Until fixed, `make validate` is run by hand before merge |
| Name and trademark clearance | aidenlive | "Soundboard" is a working name |
| Tier | aidenlive | Set to `internal` (private repository); switching to `open` needs a station.center landing |
| Android first build | Claude | Job 009 |

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
| [010 refinement stage 1](jobs/010-refinement-stage-1/SESSION.md) | ACTIVE |
