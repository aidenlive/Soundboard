# Job 002 · design direction

Status: DONE

## Objective

Give the owner design directions to pick from before the full app is built (PR #3).

## Completed

- Rounds 1 and 2 on the design canvas
- Obsidian chosen as default, radial deck view kept as an option
- Appearance model: theme, accent, deck view, waveform scheme, density
- Token pipeline: design/tokens/obsidian.tokens.json to Swift

## Active

None.

## Blockers

None.

## Decisions

- [ADR 0003](../../../docs/decisions/0003-obsidian-and-appearance.md) Obsidian default with user Appearance

## Files changed

design/tokens/, docs/design/appearance.md, platforms/apple/Sources/SoundboardUI/Design/

## Verification

Design-system tests: every combination resolves, WCAG contrast in every theme, JSON and Swift parity.

## Next actions

None.
