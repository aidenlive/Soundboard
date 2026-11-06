# 0008 · A vinyl platter model in the engine

Status · Accepted · 2026-11-06

## Context

The owner asked for scratching, jog-wheel interaction and pitch control that feel real, without
cluttering the default interface. Touch events arrive at 60–120 Hz with jitter. Moving the read
position directly from them zippers and clicks. A still record must be silent, and catching a
spinning record must not click.

## Decision

- **The deck owns a platter.** While a hand is on it, the read head chases the hand position
  with a 6 ms follow time and 2 ms velocity smoothing, forwards and backwards. One revolution is
  1.8 s of audio (33⅓ rpm).
- **Output level follows groove speed,** like a phono cartridge: full level from half speed up,
  fading to silence as the record stops. Holding, reversing and releasing never click.
- **Letting go hands the record to the motor:** 30 ms back to speed (CDJ feel), or the turntable
  spin-up time set in Settings › Controllers. The same motor time gives turntable starts and
  brakes on play and pause.
- **The jog edge is a decaying pitch bend** (80 ms), for beat-matching by hand. Vinyl mode off
  makes the whole wheel bend.
- **Advanced controls are disclosed progressively:**
  - The DJ layout is a switch in landscape.
  - Deck tools is a sheet.
  - Tempo and loop sizes are contextual overlays.
  - The Quick view stays a single Mix button.

## Consequences

- Scratching works identically on every platform and on future MIDI jogs: they call the same
  three functions.
- Five engine tests pin the behaviour: following the hand, holding silently, clean release, motor
  distances, and bend.
- Key lock while scratching is not applicable (a record changes pitch with speed). Key lock for
  tempo changes is still planned.
