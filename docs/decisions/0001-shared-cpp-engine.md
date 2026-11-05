# 0001 · Shared C++ engine behind a C API

Status · Accepted · 2026-11-01

## Context

The app runs on iOS, macOS and Android. DJ audio needs sample-accurate mixing, sync and analysis with no allocation on the audio thread. Writing that three times (Swift, Kotlin) triples the bugs in the part that matters most, and neither language guarantees real-time safety.

## Decision

One C++17 engine (`engine/`) does every sample of audio: decks, mixer, buses, routing, sync, transitions and analysis. It exposes a C API (`sbe.h`) so Swift imports it directly and Android reaches it through JNI. Platform hosts only discover devices, open streams and call `sbe_engine_render`. Commands go through a lock-free queue; track memory is released by generation counter.

## Consequences

- One set of tests (25, plus sanitizers) covers every platform's audio.
- Platform code stays thin, but UI state must be mirrored from engine status by polling.
- Contributors need C++ for audio work; the C API is the stable boundary.
