# Brand

**Primary mark: Split.** **Supporting element: Pulse.** Decided 2026-11-05. Design canvas: page
**Brand — final**.

## Split, the primary mark

The mark is two halves of one circle (r = 34 in a 100-unit box), offset by ±6 like two beats being
aligned, with a gap of 4 between them. Together they read as an **S**.
- **White** is the master: what the room hears.
- **Lime** is the cue: what's in your headphones.

The mark tells the product's core story, and it holds up down to 16 px.

| Asset | File |
|---|---|
| Mark for dark backgrounds (primary) | `brand/logo/split-mark.svg` |
| Mark for light backgrounds | `brand/logo/split-mark-on-light.svg` |
| Mono white / mono black | `brand/logo/split-mark-mono-white.svg`, `split-mark-mono-black.svg` |
| App icon master (1024) | `brand/app-icon/app-icon-master.svg`, `app-icon-1024.png` |
| Apple app icon (iOS + macOS sizes) | `platforms/apple/RoutingLab/Assets.xcassets/AppIcon.appiconset` |
| Android adaptive icon (with monochrome layer for themed icons) | `platforms/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` |

**Rules**
- Keep a quarter of the mark's height clear on every side.
- Minimum size: 16 px for the mark alone, 24 px mark height in a lockup.
- Never rotate, mirror or recolour the halves, never swap white and lime, and never add effects.
- On light backgrounds use the black + Lime 700 version. On a lime background use the black version.
- Lockup: the mark plus the lowercase wordmark "soundboard" in Geist SemiBold, tracking −0.035 em. The
  wordmark cap-height sits at about half the mark's height, with a gap of 0.3× the mark between them.

## Pulse, the supporting element

Pulse is a row of waveform bars riding an S-curve, with a tall lime centre bar as the playhead.
**It means "sound is happening."**

Use it for:
- the launch and splash loader;
- the analysis progress indicator;
- the now-playing indicator in the library;
- patterns on marketing material, empty states and merchandise.

Never use it as a button, and never use it in place of the logo. Animated, the bars breathe in sequence
(1.1 s cycle, 90 ms stagger). With Reduce Motion on, Pulse is shown still.

Files: `brand/pulse/pulse.svg`, `brand/pulse/pulse-animated.svg`.

## Colour

The brand colours are the Obsidian tokens (`design/tokens/obsidian.tokens.json`). OKLCH is the source
of truth. Asset formats that can't hold OKLCH (PNG, Android vector drawables) carry these sRGB
conversions:

| Token | OKLCH | sRGB |
|---|---|---|
| neutral-950 (black) | oklch(0 0 0) | `#000000` |
| neutral-50 (white) | oklch(0.975 0.006 260) | `#F4F7FB` |
| lime-500 (Volt) | oklch(0.88 0.21 128) | `#AFF03C` |
| lime-700 (on light) | oklch(0.67 0.179 128) | `#75A800` |

The user's Appearance accent changes the in-app UI only. **The logo and app icon always stay white +
Volt lime.**

## Open item

Clear the name before final release. "Soundboard" is a common word and existing products use it.
Run a trademark and App Store / Play Store name search. If the name changes, the Split mark still
works as an S for any S-name, or stands alone.
