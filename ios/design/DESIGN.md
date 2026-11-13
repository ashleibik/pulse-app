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
| `sheet` **(our choice)** | `#FFFFFF` | `#111111` | Background of sheets (in dark mode one step lighter than the screen, so you can see where the sheet starts) |

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
| Good / bad trend | Arrow + size + word: "▲ 3 better", "▼ 12m worse", "no change". Never green / red |
| What helped / hurt recovery | A bar growing right (helped) or left (hurt) from the middle, plus a signed number: "+3", "−18" |
| Sleep phases | Their own labelled row in the chart, plus a gray level: Restful `primary`, Light `tertiary`, Awake `secondary` |
| Heart-rate zones | Label (Z1–Z5) and bar length. All bars `primary` |
| Risky actions (replace demo data) | A confirmation dialog that says what will happen. No red buttons |

## 3. Typography

Font: **SF Pro** (the iOS system font). iOS switches to the *Display* cut automatically at 20 pt
and above, so headlines are SF Pro Display without bundling anything.

| Style | Size | Weight | Tracking | Text style (Dynamic Type) | Used for |
|---|---|---|---|---|---|
| `hero` | 64–76 | Bold | −4% of the size | scales with Large Title, capped at +20% | The one number of the screen (76 in the big recovery ring, 64 elsewhere) |
| `welcome headline` | 44 | Bold | −1.5 | scales with Large Title, capped at 56 | Welcome pages only |
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
- **Tab screens and sheets have no navigation bar.** A slim header (title left, actions right,
  `ScreenHeader` in code) is pinned at the top on a solid background, so content scrolls under
  it cleanly. On sheets the action is a round close button.
- **Pushed screens** (Recovery, a workout) keep the system navigation bar, so the standard back
  button and the swipe-back gesture work.
- **Every screen starts with its answer**: one hero number with a caption above and one line
  below. Then sections, each with a bold heading.

## 5. Shapes

| Thing | Shape |
|---|---|
| Card | `surface` fill, corner radius **24**, continuous corners, no border, no shadow, padding 20–24 |
| Primary button | Pill (fully rounded), `primary` fill, `onPrimary` text, height 52 |
| Secondary button | Pill, `surface` fill, `primary` text, height 52 |
| Icon button | Circle 44, `surface` fill, `primary` icon |
| Pill picker | Small pills (height 36), selected = `primary` fill, others = `surface` fill. Replaces the segmented control |
| Row | Label left (`body`), value right (`bodyStrong`), 52 high, hairline between rows |
| Status pill | Capsule with a 1 pt `border` outline, `caption` text |
| Bars and tracks | Capsules (fully rounded ends) |

One primary button per screen at most. Disabled buttons fade to 40%.
On sheets, `surface`-filled controls use `border` instead (in dark mode the sheet itself is `surface`).

## 6. Icons

SF Symbols, **regular weight**, monochrome, outline versions (`moon`, not `moon.fill`) outside the
tab bar. Large illustrative icons (welcome pages, empty states) are **thin**. Icons are `primary`
or `secondary`, never tinted. The tab bar keeps the iOS standard (filled when selected)
**(our choice)**.

## 7. Charts

Swift Charts, black and gray only.
- No gridlines. X labels in `caption` / `secondary`.
- **Bars** (`DayBarsChart`): rounded (capsule), no Y axis. **Past days `muted`, today (or the
  selected day) `primary`.** A day without data keeps a small stub so the row has no hole.
  Up to 14 bars get a weekday letter each; more than that get the day of the month once a week.
- **Lines** (`LineChart`): thin (2 pt), round joins, `primary`. A few quiet numbers on the right
  give the scale. Trend lines mark today with a dot. **(our choice:** a light gray line was too
  faint to read, so for lines "today" is the dot, not the color.)
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

Every screen is in the Mono design: Today, Recovery, Sleep, Activity, Workout, Trends, Settings,
Welcome and the metric sheets. The old dark, colorful theme (`Theme.swift`) is deleted.

Checked so far: both appearances in simulator screenshots (GitHub Actions). **Not checked yet:**
the animations and haptics in motion, Dynamic Type at large sizes, and VoiceOver on a real device.

## 12. Checklist for a new screen

1. Does it start with its answer (one hero number or one sentence)?
2. Only `DS` tokens: no hard-coded colors, sizes or animations?
3. Two weights, sentence case, one line per metric?
4. At most two cards and one primary button?
5. Does every state read without color?
6. Light and dark screenshot taken? VoiceOver label on every block?
