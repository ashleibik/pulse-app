# Pulse design system: "Glow"

A dark app where the data glows. Chosen by the owner on 2026-11-15, replacing the earlier
monochrome "Mono" system (black / white / gray only).

**How to use this file:** it is the source of truth for how Pulse looks. Change the spec here
first, then the code. Every token exists in code as `DS.…` in
[`Pulse/App/Design.swift`](../Pulse/App/Design.swift); screens never hard-code a color, size or
animation. (The helpers `monoCard`, `monoBackground`, `monoSheet` kept their old names.)

## 1. Principles

1. **One answer per screen.** The most important number is huge and it glows.
2. **Dark and calm, with one bright accent.** Color is rare, so it means something.
3. **Color is never the only signal.** A word or a number always says the same thing.
4. **Alive, not busy.** The ring twinkles, numbers count up, then everything rests.
5. **Honest.** Estimates are labelled as estimates; simulated data is labelled as simulated.

## 2. Color (dark only)

| Token | Value | Used for |
|---|---|---|
| `background` | `#05070A` | Screens |
| `surface` | `#12161B` | Cards, quiet buttons |
| `sheet` | `#0E1216` | Sheets |
| `border` | `#232A31` | Hairlines, empty tracks, card edges |
| `primary` | `#FFFFFF` | Main text and numbers |
| `secondary` | `#9BA3AC` | Captions, labels |
| `tertiary` | `#59626B` | Chevrons, target ranges. Not for text |
| `muted` | `#2A323A` | Past data in charts |
| `accent` | `#1DE9A6` | The glow: today's data, the ring, primary buttons, "Ready" |
| `warn` | `#FFD23F` | "Steady", wake-ups, elevated stress |
| `alert` | `#FF5C5C` | "Rest", things that lowered a score, high stress |
| `onAccent` | `#03130D` | Text on an accent fill |
| `sleepTint` | `#8AB4E8` | The Sleep ring and sleep data |
| `strainTint` | `#3D9BFF` | The Strain ring and strain data |

Recovery uses green / yellow / red **plus** the word Ready / Steady / Rest. Good / bad changes
are written out ("▲ 3 better"). There is no light theme.

## 3. Typography

SF Pro. Big numbers and headlines use the **condensed** width; labels are small caps with wide
letter spacing. Two weights: Bold and Regular.

| Style | Size | Notes |
|---|---|---|
| hero | 64–84 | condensed bold, the one number of the screen |
| `display` | 34 | condensed bold; state words in CAPS |
| `title` | 28 | condensed bold; stat values |
| `heading` | 22 | bold |
| `label` | 13 | bold CAPS, tracking 1.6; section titles |
| `body` / `bodyStrong` | 17 | sentences / row values |
| `caption` | 13 | supporting text in `secondary` |

All styles follow Dynamic Type.

## 4. Layout and shapes

- 8 pt grid; side padding 24; 48 between sections.
- Cards: `surface`, radius 22, 1 pt `border` edge. Few of them.
- Buttons: pills, height 52. Primary = `accent` fill with a glow, dark text. Secondary = quiet fill.
- Tab screens and sheets pin a slim header (`ScreenHeader`); pushed screens keep the system bar.
  The title never truncates: the status pill next to it gives way first.
- Syncing is invisible (no sheets, popups, toasts or spinners). The status pill (`StatusPill`) shows
  the band battery when all is well, and a `warn` outline + one word only when something needs you
  (Bluetooth off, band not found, battery low, sync problem). Pull to refresh on any tab is the
  manual way; "Sync now", "Sync anyway" (only while paused for low battery) and the log live in
  Settings > Band, and act in place without opening a sheet.

## 4b. Today (home)

Top to bottom: header (settings · "‹ TODAY ›" day switcher · band battery) → three rings
(Sleep %, Recovery %, Strain) → two monitor cards (Health: "within range n/n metrics";
Stress: level + value + time) → calories card (`title` number, labelled "Estimated", resting +
active underneath; asks for the missing profile details instead of guessing) → "MY DAY" with a + button → daily outlook row (opens Coach) →
today's activities card (sleep and workouts as rows with their times; Add / Start activity) →
live heart rate. The rings use `sleepTint`, the recovery zone colour, and `strainTint`.
Tapping a ring opens its page: a big ring + score, a card of rows (each with a three-step
Poor / Sufficient / Optimal indicator, or today vs your 30-day average with ▲▼), then one
plain-language paragraph.
- Minimum tap target 44 pt.

## 4b-2. Sleep is only shown when it is finished

A sleep appears once you are clearly up again; until then the night stays empty. The Sleep tab and
the Sleep page have a pencil button that opens "Edit sleep" (fix the times, or "I wasn't asleep").
Settings > Your data offers to undo those edits. Settings > Band has a "Motion check" sheet.

Minutes with no band data are unknown: the night's chart leaves them empty, they count as neither
asleep nor awake, and one `caption` under the phases says how long they were.

When Pulse is unsure about a sleep, the Sleep tab and the Sleep page show an "Is this right?" card
(`monoCard`) under the night's summary: `heading` title, one `body` sentence with the reason, and
three pills stacked full width: "Yes" (primary), "Fix times" and "Not asleep" (secondary). "Fix times"
opens "Edit sleep", and "Not asleep" asks once before removing the sleep. An answered card does not
come back, and the answer teaches Pulse about similar nights.

## 4c. Home Screen widget

Last night at a glance: recovery ring (zone colour + the word), sleep score and sleep time. Small
shows the ring with both sleep numbers under it; medium adds the word and when it was updated. No
number is ever invented: before the first night, and in the widget gallery, values show `--`.

## 5. The glow

- `GlowOrb`: a ring of ~300 twinkling particles behind the recovery number. The lit part shows
  the score; a thin exact arc on the rim gives the precise reading.
- `.glow(color)`: a soft halo. Only on the ring, the highlighted bar, and primary buttons.
- Lines get a soft fade underneath instead of a halo.

## 6. Charts

- Bars (`DayBarsChart`): plain SwiftUI, one button per day. Past `muted`, today `accent` + glow.
- Lines (`LineChart`): Swift Charts, 2 pt `accent` line, fade below, quiet numbers on the right.
  Touch and hold to read a value.
- No gridlines. Every chart has a VoiceOver summary.

## 7. Motion and accessibility

- Ring draws in and numbers count up over 1.2 s; sections rise in; buttons give when pressed.
- Light haptics on taps that open something.
- **Reduce Motion:** the particles stand still and nothing counts or rises.
- VoiceOver reads each block as one sentence. Nothing depends on color alone.

## 8. Not checked yet

Everything here has only been seen in simulator screenshots or not at all: the particle ring's
performance on a real phone, the animations in motion, Dynamic Type at large sizes, VoiceOver.
