# 0009 · Visualizer from the master tap, on its own screen

Status · Accepted · 2026-11-06

## Context

The owner asked for customisable real-time visualizers, kept independent of the mixing
interface, that can be cast or extended to external displays and run full screen at shows.

## Decision

- **The engine publishes a visual tap:** the newest 8192 mono master samples, written after the
  latency-compensation delay so pictures match the speakers. Any thread can read it with
  `sbe_engine_read_visual`. Reading never blocks the audio thread.
- **A `VisualizerFeed` turns the tap into frames:** a 2048-point FFT into 32 log bands (fast attack,
  slow release), a 512-sample scope, the level, and the beat phase of the deck on air. It runs only
  while a visualizer is on screen.
- **Four styles share one frame:** Spectrum, Radial, Scope and Pulse (the brand element, driven by
  the music). Three palettes; spectral uses the waveform band colours.
- **Second screen by platform:**
  - **iOS and iPadOS:** an external display or AirPlay screen gets its own non-interactive scene
    with the visualizer (a setting can turn it off). The phone keeps the decks.
  - **macOS:** the visualizer is a separate window that can move to any display and go full screen.
  - **Android (later):** the Presentation API on a secondary display.
- **On the device itself**, a full-screen stage with auto-hiding controls.

## Consequences

- The visualizer cannot affect audio: it only reads a copy of the master.
- Mirroring is replaced on iOS when the setting is on, which is what a performer wants. Turning it
  off restores normal mirroring.
