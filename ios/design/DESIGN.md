# Pulse design system: "Mono"

Inspired by mobbin.com: clean, modern, monochrome. Big heavy type, lots of white space, soft gray
shapes, black pill buttons.

**How to use this file:** this is the source of truth for how Pulse looks. Change the spec here
first, then the code. Every token below exists in code as `DS.…` in
[`Pulse/App/Design.swift`](../Pulse/App/Design.swift); screens never hard-code a color, size or
animation.

Lines marked **(our choice)** were not in the original brief. They fill a gap and can be changed.

## 1. Principles

1. **One answer per screen.** The most important number is huge. Everything else is quiet.
2. **Black, white and grays only.** Meaning comes from words, size and fill amount, never from color.
3. **Type and space do the separating.** Fewer boxes. A card is the exception, not the default.
4. **Short copy.** One line per metric. Details live behind a tap.
5. **Alive, not busy.** Things draw in, count up and respond to touch, then get out of the way.

## 2. Color

| Token | Light | Dark | Used for |
|---|---|---|---|
| `background` | `#FFFFFF` | `#000000` | Screen background |
| `surface` | `#F5F5F5` | `#111111` | Cards, secondary buttons, icon buttons |
| `border` | `#EAEAEA` | `#1F1F1F` | Hairlines, empty tracks (ring, bars) |
| `primary` | `#111111` | `#FFFFFF` | Main text, filled data, primary buttons |
| `secondary` | `#6B6B6B` | `#8A8A8A` | Captions, labels, supporting text |
| `tertiary` | `#A3A3A3` | `#5C5C5C` **(our choice)** | Chevrons, target ranges, disabled. **Not for text** |
| `muted` **(our choice)** | `#D4D4D4` | `#333333` | Past data in charts |
| `onPrimary` | `#FFFFFF` | `#000000` | Text on a primary button |

Rules:
- No accent colors, no gradients, no glows.
- No shadows, except one very soft shadow on floating sheets (the system sheet shadow is enough).
- `tertiary` is too faint for reading (about 2.5:1 on white). Text is always `primary` or
  `secondary`, which both pass WCAG AA (4.5:1) on `background` and `surface`.

### State without color

| What | How it is shown |
|---|---|
| Recovery | Ring fill amount + one word: **Ready** (67–100), **Steady** (34–66), **Rest** (0–33), **Learning** (no baseline yet) |
| Strain vs target | Black fill on a gray track, target range as a darker gray band, plus one line of advice |
| Up / down vs normal | Arrow glyph and words: "▲ 3 vs normal", "at your normal" |
| Data source | Words in the status pill: "Demo data", later "Synced 5 min ago" |
| Good / bad trend | Words ("better", "worse"), never green / red |

## 3. Typography

Font: **SF Pro** (the iOS system font). iOS switches to the *Display* cut automatically at 20 pt
and above, so headlines are SF Pro Display without bundling anything.

| Style | Size | Weight | Tracking | Text style (Dynamic Type) | Used for |
|---|---|---|---|---|---|
| `hero` | 76 (64–80 allowed) | Bold | −3 | scales with Large Title, capped at 92 | The one number of the screen |
| `display` | 34 | Bold | −0.8 | Large Title | State word, screen headline |
| `title` | 28 | Bold | −0.5 | Title 1 | Stat values |
| `heading` | 22 | Bold | −0.3 | Title 2 | Section headings |
| `body` | 17 | Regular | 0 | Body | Sentences, row titles |
| `bodyStrong` | 17 | Bold | 0 | Body | Button labels, row values |
| `caption` | 13 | Regular | 0 | Footnote | Labels, units, supporting text (`secondary`) |

Rules:
- **Two weights only: Bold and Regular.** No semibold, medium or light.
- Numbers use monospaced digits so they don't wobble while counting.
- Sentence case everywhere. No ALL CAPS labels.

## 4. Layout

- **8 pt grid.** Spacing tokens: `xs 4`, `s 8`, `m 16`, `l 24`, `xl 32`, `xxl 48`.
- **Side padding 24.**
- Between sections: `xxl` (48). Inside a section: `s`–`m`.
- Prefer white space, then a hairline (`border`, 1 pt), then a card. In that order.
- At most **one or two cards per screen**.
- Minimum tap target 44 × 44 pt.
- No navigation bar on main screens. A slim header (title left, actions right) is pinned at the
  top on a solid `background`, so content scrolls under it cleanly.

## 5. Shapes

| Thing | Shape |
|---|---|
| Card | `surface` fill, corner radius **24**, continuous corners, no border, no shadow, padding 20–24 |
| Primary button | Pill (fully rounded), `primary` fill, `onPrimary` text, height 52 |
| Secondary button | Pill, `surface` fill, `primary` text, height 52 |
| Icon button | Circle 44, `surface` fill, `primary` icon |
| Status pill | Capsule with a 1 pt `border` outline, `caption` text |
| Bars and tracks | Capsules (fully rounded ends) |

One primary button per screen at most.

## 6. Icons

SF Symbols, **regular weight**, monochrome, outline versions (`moon`, not `moon.fill`) outside the
tab bar. Icons are `primary` or `secondary`, never tinted. The tab bar keeps the iOS standard
(filled when selected) **(our choice)**.

## 7. Charts

Swift Charts, black and gray only.
- No gridlines, no Y axis. X labels in `caption` / `secondary`.
- Bars: rounded (capsule). Lines: thin (2 pt), round joins.
- **Past data `muted`, today `primary`.**
- Every chart has a VoiceOver summary in words.

## 8. Copy

- One line per metric. If it needs a second sentence, it goes behind a tap.
- Plain words: "at your normal", "less than you needed".
- Numbers first, explanation second.

## 9. Motion

| Token | Animation | Used for |
|---|---|---|
| `Motion.draw` | Smooth spring, 1.2 s, no bounce | Ring drawing in, numbers counting up, bars growing |
| `Motion.spring` | Spring, response 0.45, damping 0.8 | Sections rising in, layout changes |
| `Motion.press` | Spring, response 0.25, damping 0.7 | Buttons shrinking to 96% while pressed |

- On appear: sections fade and rise 16 pt, staggered 60 ms apart.
- The hero number counts up from 0 while the ring draws.
- Light haptic on every tap that opens something; selection tick on tab change.
- Sheets and tabs use the system transitions.
- **Reduce Motion on:** no rising, no counting, no drawing. Values just appear with a short fade.

## 10. Accessibility

- Light and dark mode both supported (follows the system).
- Dynamic Type: every style maps to a system text style. The hero is capped so it stays inside the ring.
- VoiceOver: each block reads as one sentence ("Recovery, 37 percent, Steady"). Decorative shapes are hidden.
- Nothing depends on color (see *State without color*).

## 11. Rollout

| Screen | Status |
|---|---|
| Today | **Mono** (this spec) |
| Recovery detail, Sleep, Activity, Workout detail, Trends, Settings, Welcome, metric sheets | Old dark design, pinned dark with `legacyDarkTheme()` until rebuilt |

Old tokens live in `Theme` (`Pulse/App/Theme.swift`) and are deleted once every screen is moved.
