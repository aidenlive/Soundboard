# Job 005 · ios decode fix

Status: DONE

## Objective

Fix the crash and warning from the first on-device run (PR #6).

## Completed

- Chunked decoding; zero-length files throw instead of aborting
- Audio session activated off the main thread
- Route-change loop removed

## Active

None.

## Blockers

None.

## Decisions

None beyond the fix.

## Files changed

platforms/apple/Sources/SoundboardAudio/Track.swift, AudioSessionController.swift, platforms/apple/Sources/SoundboardUI/Model/DJSession.swift, platforms/apple/RoutingLab/RoutingLabModel.swift

## Verification

Not compiled here (no Swift toolchain). Needs a rebuild and device run by the owner.

## Next actions

Owner rebuilds and confirms.
