# Product & experience

> One application. Three platforms. A beginner mixes two tracks in seconds; an experienced DJ plays a
> full set without feeling constrained.

## 1. Challenging the brief

| Assumption in the brief | Problem | What we do instead |
|---|---|---|
| Four separate levels (Quick Control → Mix → DJ Mode → Pro Studio) | Mode switches hide state ("where did my EQ go?") and make users choose an identity up front | **One workspace with progressive density.** The same session, decks and mixer exist at every level; density reveals more of them. A beginner's EQ move is still there when they expand the view |
| A phone can cue privately with the right software | On iPhone it can't without hardware (see research); on Android it depends on the model | Say so in plain language at setup, recommend the cheapest fix (splitter cable), and make the no-cue experience genuinely good: visual beat-matching, auto-sync, and **phrase-aware automatic transitions** so cueing by ear is optional |
| Beginners need simple EQ | Beginners don't know *when* to use EQ | Transitions apply DJ technique for them (bass swap, filter sweep, echo out) on the phrase, and show what they did so it can be learned |
| BPM detection is enough | Tracks have different loudness, keys and phrase structure | Auto-gain to −10 LUFS, key detection with Camelot compatibility, phrase-aligned transitions, "what plays well next" suggestions |
| Streaming music | DRM catalogues need licensed partner integrations; Spotify is desktop-only for DJ apps | Local files first; provider-pluggable library; partnerships are a business workstream from day one |
| Bluetooth is just another output | 100–200 ms makes cueing impossible and makes visuals lie | Accept it for master, compensate visuals and the cue bus, never for cueing |
| Recording is a feature | Recording what the master sounded like is a correctness feature (post-limiter tap, never drops) | Lock-free record tap; set history with timestamps for tracklists |

## 2. Missing capabilities worth building

1. **Phrase detection** (8/16/32-bar boundaries) — transitions start on phrases, not just beats.
2. **Next-track suggestions** — tempo range, Camelot neighbours, energy, history.
3. **Key-lock / master tempo** — tempo changes without pitch change (time-stretch).
4. **Slip mode, beat-quantised hot cues and loops, censor/reverse** — expected by experienced DJs.
5. **Stems** (vocals/drums/bass/other) — on-device separation; acapella-in, instrumental-out.
6. **Ableton Link** — tempo sync with other apps and devices in the room.
7. **MIDI/HID controller mapping** with a shared mapping format across platforms; class-compliant first.
8. **Set history & tracklist export** — for radio/streaming compliance and for learning.
9. **Crash-safe performance** — the engine keeps playing if the UI stalls; the session restores mid-set.
10. **Thermal/battery awareness** — reduce waveform frame rate and analysis concurrency during a set.
11. **Interruption policy** — phone calls/notifications during a set: Do-Not-Disturb prompt, audio session interruption handling, resume without jumps.
12. **Practice mode** — the app plays the "other DJ": it sets up the next track and the learner performs the transition, with feedback.

## 3. The progressive workspace

Density is a continuous property of one layout, chosen automatically from screen size and manually by
the user (pinch on the workspace, ⌘+/⌘− on Mac).

### Level 1 — Quick Control (phone portrait, default for new users)
- One large **Now Playing** waveform (scrolling, three-band colour), artwork-free by design.
- **Up Next** card: suggested track with BPM/key compatibility badges.
- One primary action: **Mix** (picks transition style and length; starts on the next phrase).
- Master volume, a single **Bass / Mid / Treble** row, one **Filter** knob for the playing track.
- Output chip at the top: "Speaker · no headphone cue" / "Headphones cue ready" — tapping it explains.

### Level 2 — Mix (phone landscape, tablets)
- Two decks stacked: **parallel waveforms with aligned beat grids** (the fastest way to see sync).
- Crossfader, per-deck play/cue/sync, tempo, BPM/key, cue-points strip.
- Library sheet with preview-in-headphones (hold a row to preview; release to stop).
- Transition picker (Blend · Bass swap · Filter · Echo out, 4/8/16/32 beats).

### Level 3 — DJ Mode (tablet, Mac, phone landscape at high density)
- Full mixer: trim, 3-band EQ with kill, filter, channel fader, PFL, cue/master blend, headphone level.
- 8 performance pads per deck: hot cues · loops · beat jump · rolls.
- Recording, set history, quantise, key-lock, slip.

### Level 4 — Pro Studio (Mac, iPad with keyboard, Android tablets/desktop mode)
- Up to 4 decks, routing matrix (bus → device channel), latency calibration, MIDI learn,
  saved layouts per controller, sampler, external input decks.

## 4. Design language

> **Decided:** Obsidian is the default design system, and users can restyle it in Settings › Appearance
> (theme, accent, deck view including Radial, waveform colours, density). See
> [`design/appearance.md`](design/appearance.md) and `design/tokens/obsidian.tokens.json`.

- **Original, not skeuomorphic.** No fake jog wheels or brushed metal. Controls are typographic and
  geometric; the waveform is the hero.
- **Colour has meaning, never alone.** Deck A cool, deck B warm, consistently across waveform,
  pads and crossfader; every colour cue also has a label, position or shape.
- **Three-band waveform:** low = deep saturated, mid = neutral, high = bright; amplitude from the engine's
  waveform bins; beat grid as hairlines, downbeats heavier, phrase starts marked.
- **Type:** one variable sans for UI, tabular numerals for BPM/time; large numerals for the two
  numbers DJs glance at — BPM and time remaining.
- **Motion** communicates timing: beat-pulse on the sync button, phrase countdown before an automatic
  transition, no decorative animation. Reduce Motion respected.
- **Touch:** big targets (≥ 44 pt), hold-to-preview, drag on waveform to nudge (rate bend, not seek),
  two-finger drag to scrub, pinch to zoom, haptic tick on beats while nudging.
- **Desktop:** full keyboard map (space = play A, ⇧space = play B, Q/W cue, 1–8 hot cues, ←/→ beat
  jump), pointer hover reveals fine controls, every control MIDI-learnable.
- **Accessibility:** VoiceOver/TalkBack labels with values ("Deck B tempo plus 1.6 percent, synced"),
  Dynamic Type for non-performance chrome, high-contrast waveform theme, haptic beat for low-vision
  beat-matching.

## 5. The two-tracks-in-seconds flow

1. Open the app → last session restored or **Pick a track** (local files).
2. It plays. Up Next suggests a compatible track (already analysed in the background).
3. Tap **Mix**. The app syncs the next track, aligns it to the phrase, counts down, and performs a
   bass-swap blend over 16 beats.
4. A one-line note explains what happened ("Swapped the basslines at the half-way point") — learning
   by doing.

Measured target: from launch with a library to a completed transition in under 30 seconds, no
hardware, no settings.
