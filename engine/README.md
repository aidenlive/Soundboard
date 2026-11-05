# Soundboard Engine

A shared C++17 DJ audio engine with no dependencies and a plain C API (`include/soundboard/sbe.h`) for
Swift and JNI.

## Features
- 1–4 decks: Hermite-interpolated variable-rate playback, CDJ-style cue, 8 hot cues, beat loops,
  beat jump, nudge, quantise. Every transport action is declicked.
- Mixer: trim and auto-gain, Linkwitz–Riley 3-band isolator EQ with kill, bipolar SVF filter,
  fader, beat-synced echo, constant-power and cut crossfader curves.
- Buses: master with a look-ahead limiter and record tap. Headphone cue with PFL, cue/master blend,
  its own gain and a safety limiter. Library preview into the headphones only.
- Routing: master-only, split-mono, multichannel, and a separate cue device (with drift
  compensation). Per-bus latency compensation.
- Sync: tempo + phase match with a PLL lock, half/double-time aware.
- Transitions: blend, bass swap, filter sweep, echo out — all beat-length.
- Analysis: BPM + beat grid, key (Camelot), BS.1770 loudness, 3-band waveform.

## Layout
```
include/soundboard/sbe.h   C API (the only header hosts need)
src/                       engine, deck, DSP, FIFOs, analysis, WAV I/O
tests/test_main.cpp        24 tests, dependency-free
testing/synth.hpp          deterministic synthetic tracks for tests and the prototype
tools/routing_demo.cpp     offline routing prototype
```

## Run
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
./build/sbe_tests                 # optional filter: ./build/sbe_tests sync
./build/sbe_routing_demo /tmp     # or: ./build/sbe_routing_demo /tmp a.wav b.wav
```

Real-time rules on the audio thread: no locks, no allocation, no frees, no I/O. All control calls
travel over a lock-free SPSC queue, and track memory is released only after the audio thread
acknowledges the swap.
