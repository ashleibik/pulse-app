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
| `warn` | `#FFD23F` | "Steady", wake-ups, moderate stress |
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
- Tab screens end with 96 pt of space (`DS.Space.tabBarClearance`), so their last content scrolls clear of the tab bar.
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
active underneath, then one `caption` with the time measured when the band covered under 90% of the day; asks for the missing profile details instead of guessing) → steps card (§4b-8) → "MY DAY" with a + button → daily outlook row (opens Coach) →
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

## 4b-3. Wear sensor

Settings > Band has a "Wear sensor" row: No errors or Error. After 30 minutes without a reading it shows the last one with its
time ("No errors at 7:44 PM"), and `--` before the first. A `caption` sits under it when the sensor reports errors. Pulse never says the
strap is loose: the band's loose flag was wrong on the owner's wrist (docs/METRICS.md §13).

## 4b-4. Workouts

Types are Run, Cycle, Strength, Walk, HIIT and Other. The Activity tab's + adds a past workout (type, start, end).
Pulse records workouts by itself, with nothing to confirm: walks and runs from the band's counted steps, other workouts from heart
rate (docs/METRICS.md §10). They appear in the list like any other workout. Deleting one keeps it away, and detection never changes
or removes a workout you added or confirmed. With none in 14 days, one `body` line says how Pulse finds them. Finishing a workout
under a minute long asks "Too short. Discard?" with Discard and Keep going.

## 4b-5. Stress

The sheet opens with "RIGHT NOW": the level in `display` (Calm `accent`, Moderate `warn`, High `alert`) and one line saying which hour it
reads. An hour spent moving shows "Moving", and with no recent reading it shows "Can't tell yet" with what Pulse needs. Under that: "Today"
with the time in each level, "Hour by hour" bars on the 0 to 3 scale, and "How it works". With fewer than 4 scored hours it shows "Too early
to tell" with the count so far, and leaves out the levels and bars. The Today card shows the same level and score, and says "Moving",
"Too early" or "No reading" when there is no level.

## 4b-6. Sleep stages

The Sleep tab and the Sleep page show four stages. From the top of the chart: Awake (`warn`), REM (`accent`), Light (`sleepTint` at 70%,
at least 3:1 against `surface`) and Deep (`sleepTint`). "Your night" says "Stages estimated" on the right, and each stage's sheet says
stages are estimates, not a sleep-lab measurement.

"Your night" is one connected step chart, 160 pt tall: each stage is a block 12 pt high on its row, and a 1.5 pt `tertiary` line joins
one stage to the next. The time axis shows when the sleep started and ended, with minutes, and whole hours between them (every 2 hours
on a night over 4 hours), leaving out an hour that would crowd either end. Under the chart, a 2 × 2 grid holds the four stages with
their times: Deep and Light, then REM and Awake. Under the grid, after a hairline, one "Restorative" row ("deep + REM" in `caption`,
then the time and share). The Sleep page adds a "Restorative sleep" row with its three-step level under "High sleep stress", and a
"RESTORATIVE (DEEP + REM)" line under the phases.

## 4b-7. Naps

Under the night chart, the Sleep tab has a "Naps" card (`monoCard`): each nap after that night with its times and minutes asleep
(tap one to edit it), one `caption` saying naps lower the next night's sleep need and don't change recovery, and an "Add nap"
secondary pill. "Add nap" is a sheet like "Edit sleep": "Fell asleep" and "Woke up" rows and a "Save nap" primary pill. A nap
lasts 10 minutes to 3 hours, can't be in the future and can't overlap another sleep. Today's activities list each nap as its own
"NAP" row, and "Why you needed" shows a "Naps" row when naps lowered the need.

## 4b-8. Steps

Steps are counted by the band, never estimated, so no step number carries "Estimated" (docs/METRICS.md §15).

Today has a "STEPS" card under the calories card (`monoCard`): the count in `title`, "of 10,000" (the goal) in `caption`, a progress
bar toward the goal (`accent` fill on a `border` track, full at the goal), and one `caption` with how long the band counted that day
("Counted for 9h 12m"). A day the band never counted shows `--` and the `caption` "The band counts steps while it streams its motion
to your iPhone."

The Activity tab has a "Steps" card under heart rate zones: today's count, the same "Counted for" `caption`, then "Steps by hour" bars
(`DayBarsChart`, the current hour highlighted, every third hour labelled).

Settings has a "Steps" section: a "Daily goal" row with minus / plus (1,000 steps a click, 2,000 to 30,000), a "Step counting" row
("On", "Paused: you're still", "Paused: band not worn", "Paused: band battery low", "Waiting for the band"), one `caption` footer
saying when the band counts, and a "Step test" secondary pill.

"Step test" is a sheet that checks the band's count against yours: one `body` paragraph (walk at your usual pace, count 500 steps,
tap Stop), a Start primary pill, then a big timer in `title` while it runs with a `caption` under it ("The band has counted 312 steps
so far", or why there is no count yet) and Stop (primary) / Cancel (secondary). After Stop it shows the band's count and yours side
by side, the difference in percent (`warn` past 5%, a word next to it too), an editable "You counted" row (default 500), and "Save"
(primary) / "Discard" (secondary). Saved tests are listed under it with their date, both counts and the difference, with a "Remove"
button (ask once); the title shows their average difference. The test never changes how steps are counted.

## 4b-11. Settings search

Settings pins a search field under its header: `surface` fill, `border` edge, radius `DS.Radius.field`, at least 44 pt tall, a
magnifying glass, the placeholder "Search settings" and a clear button while it holds text. Typing keeps only the sections whose name
or settings match (letter case and accents don't matter), in their usual order. With no match, one `body` line says "No settings
match "…"."

## 4b-9. VO₂ max

The Activity tab has a "VO₂ max" card under Steps (`monoCard`, "Estimated" on the right of the title): the value in `title` with
"ml/kg/min" (and "± 6" when the model gives an error) in `caption`, one `caption` saying what it came from (resting heart rate and over
how many nights; with the waist, also age and this week's workouts; without it, "Add your waist in Settings to include your activity"),
and "A trend to watch over weeks, not a lab test." With fewer than 4 of the last 7 nights it says how many nights it needs and has.
Settings > Profile has an optional "Waist" row (cm).

## 4b-10. Sleep planner

On the Sleep tab, for last night only, a "Sleep planner" card (`monoCard`, "Tonight" on the right of the title) replaces the old
"Bedtime tonight" row: a `PillPicker` with Peak, Perform and Get by, a "Wake up" row with a time picker (your usual wake-up time until
you pick one, then a secondary pill "Use my usual wake-up time"), and after a hairline "Be in bed by 10:55 PM" in `heading` (`accent`),
one `body` line with the sleep to aim for and the share of tonight's need, and one `caption` with the minutes added for the time you
usually lie awake. Without a wake-up time it asks for one. The bedtime reminder uses the same wake-up time and goal.

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
