# 0002 · Four output topologies; Bluetooth is master only

Status · Accepted · 2026-11-01

## Context

Headphone cueing needs two independent stereo signals. What hardware allows differs: iOS `.multiRoute` pairs USB, HDMI or line-out with wired headphones but never the speaker with Bluetooth; Android depends on the phone; macOS can open two devices. Bluetooth adds 100–300 ms of variable latency.

## Decision

The engine renders master and cue always and a router maps them to one of four topologies: master only, split mono (master left, cue right on one stereo output), multichannel (one device, separate channel pairs), separate cue device (a second stream fed through a drift-compensated FIFO). The platform's route planner picks one from what is connected. Bluetooth outputs are used for the master only.

## Consequences

- A cue or preview action can never change the master; the routing prototype proves it bit for bit.
- Without cue hardware the app still works and says why cueing is off.
- The separate-device path costs one FIFO of latency on the cue side only.
