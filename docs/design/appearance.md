# Design system: Obsidian, plus user-selectable Appearance

**Decision (2026-11-05):** Obsidian is the default look. Users can change it later in **Settings ›
Appearance**. The radial deck view from the "Signal" exploration ships as an Appearance option, not
as a separate app style.

Design canvas: *Soundboard — design directions* → page **Obsidian (chosen)**. The Appearance screen
on that page is interactive.

Tokens: [`design/tokens/obsidian.tokens.json`](../../design/tokens/obsidian.tokens.json). The colour
standard is OKLCH only, uses semantic tokens, and has one brand colour per product.

## Obsidian in one paragraph

Obsidian is a precision instrument on true black. The waveform is the hero: lows, mids and highs are
drawn as three overlaid bands in blue, orange and white. A beat grid, phrase markers ("DROP · 8 BARS")
and a whole-track overview with sections and hot-cue ticks sit around it. All numbers use Geist Mono
tabular figures; the UI uses Geist. The accent colour is reserved for "go" actions and states: Mix,
playing, sync, the selected value. Everything else is neutral. Controls are drawn, not stock: arc
knobs, segmented pickers, segmented meters, and pads with cue-colour bars. Corners are tight
(4–8 px), dividers are hairlines, and there is no decorative gradient or glow.

## The Appearance model

| Setting | Options (default first) | What it changes |
|---|---|---|
| Theme | OLED Black · Graphite · Daylight | Neutral-to-semantic mapping (`color-background` … `color-text-muted`) |
| Accent | Volt (lime) · Signal (pink) · Ice (cyan) · Ember (orange) · Violet | `color-primary` / `-hover` / `-active`, the single brand family |
| Deck view | Linear · Radial · Lanes | Which waveform component the deck renders |
| Waveform colours | Spectral · Accent · Mono | `color-wave-low` / `-mid` / `-high` |
| Density | Comfortable · Compact | Spacing scale and control sizes, with 44 pt minimum touch targets kept |
| Follow system light/dark | off | Switches OLED ↔ Daylight with the OS |
| Per-controller layouts | on | Remembers deck view and density for each MIDI controller profile |

### Rules

1. **Components only read semantic tokens.** A theme, accent or waveform choice only changes token
   values. No component has a branch per theme.
2. **One accent at a time.** The accent replaces the brand family. Semantic colours (success, warning,
   error, info) and hot-cue colours never change with it, so meaning stays stable.
3. **Deck view is a component swap, not a skin.** Linear, Radial and Lanes all take the same input:
   the three-band waveform bins, beat grid, phrases, cues and play position. They render it
   differently. Mixer, pads and transport don't change.
4. **Accessibility holds in every combination.** Text tokens keep at least 4.5:1 against their
   surfaces in all three themes. Text on the accent uses `color-on-primary` (near-black), which
   clears 4.5:1 on all five accents at the 500 step. The radial view always shows BPM, time and
   phrase as text inside the ring, not only as graphics.
5. **Performance is protected.** Changing appearance never touches the audio engine. Deck-view
   rendering budgets are the same: 120 Hz on ProMotion, and the waveform drawn on the GPU (Metal /
   Compose `Canvas`).

### Code

- `design/tokens/generate.py` writes `ObsidianTokens.generated.swift` from the JSON. Re-run it after
  any token change; a test fails if the Swift data drifts from the JSON.
- `SemanticPalette.resolve(_:)` resolves references for one Appearance. Components read
  `@Environment(\.obsidian)` and use semantic colours only.
- Waveform presets: Spectral, Deck tint (deck B overrides), High contrast, Accent, Mono, and Custom
  with guardrails: adjacent bands must differ by at least 0.12 OKLCH lightness. Mid is lifted first,
  then High falls back to white, and every adjustment is explained to the user.

### Platform mapping

- **SwiftUI:** `AppearanceSettings` (`@Observable`, persisted with `@AppStorage`) produces a `Theme`
  value injected through `@Environment`. Semantic colours are `Color` values built from OKLCH
  (converted to Display P3 at build time), resolved per theme and accent.
- **Compose:** a `SoundboardTheme(appearance)` composable provides a `SoundboardColors` class through
  a `CompositionLocal`. Settings are stored in DataStore.
- **Sync:** Appearance is part of the synced preferences, so the same look follows the user across
  devices. Per-controller layouts are stored per device.

## What changed from earlier rounds

- Round 1 felt too basic and Android-like: pill buttons, stock sliders, card stacks.
- Its colours came from auto-generated ramps and looked muddy. Every colour is now chosen by hand.
- Glass (vertical lanes) is kept as the **Lanes** deck view. Signal's ring is kept as **Radial**.
