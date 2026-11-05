# Job 001 · audio foundation

Status: DONE

## Objective

Research each platform's audio routing, then build a shared engine with independent master and cue buses and prove the routing before any DJ interface (PR #1).

## Completed

- Platform research: docs/research/platform-audio.md
- Engine: decks, mixer, master and cue buses, four output topologies, drift-compensated second device, sync, transitions, analysis
- Apple and Android hosts; Routing Lab apps
- Offline routing prototype

## Active

None.

## Blockers

None.

## Decisions

- [ADR 0001](../../../docs/decisions/0001-shared-cpp-engine.md) shared C++ engine behind a C API
- [ADR 0002](../../../docs/decisions/0002-cue-routing-topologies.md) four output topologies; Bluetooth is master only

## Files changed

engine/, platforms/, docs/research/, docs/architecture.md, Package.swift

## Verification

Engine tests pass, also under ASan, UBSan and TSan. The routing prototype shows the master bit-identical with headphone activity. Swift and Android code reviewed, not compiled here.

## Next actions

On-device validation: job 007.
