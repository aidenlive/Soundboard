# 0003 · Obsidian is the default design system; users can change its look

Status · Accepted · 2026-11-03

## Context

Two design rounds were reviewed on the design canvas. The owner chose Obsidian (OLED black, three-band spectral waveform, Geist, lime accent) and also liked the radial deck view from another direction. Colour follows the OKLCH standard the owner supplied: one primary family, semantic tokens, shared names across themes.

## Decision

Obsidian is the default. Settings › Appearance lets the user change theme (OLED, Graphite, Daylight), accent, deck view (linear, radial, lanes), waveform scheme and density. All of it is data in `design/tokens/obsidian.tokens.json`, resolved at runtime; components read semantic tokens only. Custom waveform colours are allowed within guardrails (adjacent bands at least 0.12 apart in OKLCH lightness).

## Consequences

- Every combination is tested for contrast; adding a theme is a JSON change.
- Waveform colours carry meaning (low, mid, high), so presets keep bands distinguishable.
- The token JSON is the source; Swift, CSS and DESIGN.md are generated from it (ADR 0005).
