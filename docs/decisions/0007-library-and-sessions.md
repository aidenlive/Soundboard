# 0007 · One shared library; named sessions; imports copied in

Status · Accepted · 2026-11-06

## Context

M4A and other files failed to import or play on iPhone. The app kept a security-scoped bookmark to
the file the user picked. On iOS that file is only lent to the app: the bookmark can fail to
resolve later, iCloud files can be placeholders that are not downloaded, and the decoder failed
silently on some MP4 containers. Nothing was saved between launches, and the owner asked for
saved, named sessions that restore automatically.

## Decision

- **Import copies the file into the app** (`Application Support/Soundboard/media/`) under a file
  coordinator, which downloads iCloud placeholders first. Always on iOS; a setting on macOS, where
  references through security-scoped bookmarks work and libraries are large.
- **Decoding has two paths**: AVAudioFile, then AVAssetReader for anything AVFoundation can play.
  DRM-protected files are detected and named as such.
- **Files are de-duplicated by SHA-256** of their content.
- **One library for every session**: tracks, analysis, hot cues, the saved loop and playlists live
  in `library.json`. Cue points belong to the track, so they follow it into every session.
- **A session** (`sessions/<id>.json`) keeps decks (track, position, tempo, sync, loop, cue,
  channel strip), the master and headphone mixer, the queue and the library view. Sessions save
  every few seconds when something changed, and when the app goes to the background.
- **Restore** reopens the last session at launch with decks paused. It also puts decks back after
  iOS restarts its audio server.
- **Files are JSON with tolerant decoding**: unknown keys are ignored and missing keys take
  defaults. A file that cannot be read is moved aside as `.corrupt-<time>`, never overwritten.

## Consequences

- Imports cost disk space on iOS (the same as the file).
- Removing a track deletes its copy. The user's own files are never deleted.
- Android stores the same JSON documents, so a future sync service can move sessions and the
  library between devices.
- The waveform is drawn from the decode done at load (about 10 ms per minute of audio), so it is
  never stored.
