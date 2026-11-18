"""
make_metric_vectors.py: write shared/test-vectors/metrics_v2.json.

The Python reference computes expected outputs for a set of deterministic inputs. The Swift
tests (ios/PulseCore/Tests/PulseCoreTests/MetricsParityTests.swift) load the same file and
must produce the same numbers. That's how we know the two implementations agree.

    python -m tools.make_metric_vectors          # from re-toolkit/
"""

from __future__ import annotations

import json
import random
from pathlib import Path

from metrics import ALGORITHM_VERSION
from metrics.hrv import clean_rr, overnight_rmssd, resting_hr, rmssd
from metrics.load import recovery, sleep_need, strain_from_trimp, trimp
from metrics.sleep import classify, cole_kripke, sessions

OUT = Path(__file__).resolve().parents[2] / "shared" / "test-vectors" / f"metrics_v{ALGORITHM_VERSION}.json"


def r1(x: float) -> float:
    """Inputs are rounded to 0.1 so the JSON stays readable (outputs keep full precision)."""
    return round(x, 1)


def build_vectors() -> dict:
    rng = random.Random(2026)

    # ---- RR cleaning + RMSSD -------------------------------------------------------
    clean_series = [r1(rng.gauss(900, 30)) for _ in range(40)]
    artifacts = list(clean_series)
    artifacts[10] = 1800.0   # missed beat (two beats merged)
    artifacts[20] = 450.0    # extra beat (one beat split)
    artifacts[30] = 2500.0   # out of range
    artifacts[35] = 250.0    # out of range
    rr_inputs = [clean_series, artifacts, [800.0, 820.0, 790.0]]
    rr_clean = [{"input": x, "expected": clean_rr(x)} for x in rr_inputs]
    rmssd_cases = [{"input": c["expected"], "min_pairs": mp, "expected": rmssd(c["expected"], mp)}
                   for c in rr_clean for mp in (1, 20)]

    # ---- Overnight HRV ------------------------------------------------------------
    minute_rr = [[r1(rng.gauss(920, 40)) for _ in range(65)] for _ in range(30)]
    for minute in minute_rr[::3]:      # what the real band does: filler values and impossible beats
        minute[4], minute[30], minute[50] = 500.0, 1900.0, 2400.0
    asleep_mask = [not (7 <= i <= 8 or i == 21) for i in range(30)]
    overnight = [{"minute_rr": minute_rr, "asleep": asleep_mask, "expected": overnight_rmssd(minute_rr, asleep_mask)},
                 {"minute_rr": minute_rr[:12], "asleep": asleep_mask[:12],
                  "expected": overnight_rmssd(minute_rr[:12], asleep_mask[:12])}]

    # ---- Resting HR ------------------------------------------------------------------
    minute_hr = [r1(58 + 4 * ((i % 30) / 30) + rng.gauss(0, 0.8)) for i in range(60)]
    minute_hr[25] = None
    resting = [{"minute_hr": minute_hr, "window": 10, "expected": resting_hr(minute_hr, 10)},
               {"minute_hr": [60.0, None, 61.0], "window": 10, "expected": resting_hr([60.0, None, 61.0], 10)}]

    # ---- Cole-Kripke ---------------------------------------------------------------
    activity = [r1(abs(rng.gauss(10, 8))) for _ in range(30)]
    activity[5] = None
    ck = [{"activity": activity, "expected": cole_kripke(activity)}]

    # ---- Sleep classification + sessions --------------------------------------------
    hr, act = [], []

    def block(minutes, hr_mean, hr_sd, act_mean, act_sd):
        for _ in range(minutes):
            hr.append(r1(rng.gauss(hr_mean, hr_sd)))
            act.append(r1(max(0.0, rng.gauss(act_mean, act_sd))))

    block(120, 76, 3, 12, 1)       # evening, awake
    block(100, 55, 1, 1.5, 0.5)    # asleep
    block(3, 70, 2, 60, 5)         # awakening
    block(150, 54, 1, 1.5, 0.5)    # asleep
    block(1, 70, 2, 60, 5)         # brief awakening
    block(110, 56, 1, 1.5, 0.5)    # asleep
    block(90, 78, 3, 14, 1)        # morning, awake
    for _ in range(20):            # band off (charging)
        hr.append(None)
        act.append(None)
    block(45, 58, 1, 1.5, 0.5)     # afternoon nap
    block(60, 80, 3, 15, 1)        # awake
    flags = classify(hr, act)
    sleep_cases = [{"hr": hr, "activity": act, "blocks": None, "expected_asleep": flags,
                    "expected_sessions": sessions(flags)}]

    # Two nights where the second one runs 6 bpm higher: per-block thresholds must still find it.
    hr2, act2 = [], []
    for night_hr in (52, 58):
        for minutes, h, a in ((300, night_hr + 20, 12), (420, night_hr, 1.5), (720, night_hr + 20, 12)):
            for _ in range(minutes):
                hr2.append(r1(rng.gauss(h + (8 if h == night_hr and len(hr2) % 1440 < 360 else 0), 1)))
                act2.append(r1(max(0.0, rng.gauss(a, 0.5))))
    blocks2 = [i // 1440 for i in range(len(hr2))]
    flags2 = classify(hr2, act2, blocks2)
    sleep_cases.append({"hr": hr2, "activity": act2, "blocks": blocks2, "expected_asleep": flags2,
                        "expected_sessions": sessions(flags2)})

    # ---- Strain ------------------------------------------------------------------------
    rest, maximum = 55.0, 190.0
    hard_run = [r1(rest + 0.8 * (maximum - rest) + rng.gauss(0, 3)) for _ in range(60)]
    easy_day = [r1(rest + rng.gauss(14, 3)) for _ in range(600)]
    mixed = easy_day[:100] + [None] * 10 + hard_run[:30]
    strain_cases = []
    for name, series, sex in (("hard_run", hard_run, "male"), ("easy_day", easy_day, "male"),
                              ("mixed", mixed, "male"), ("hard_run_female", hard_run, "female")):
        t = trimp(series, rest, maximum, sex)
        strain_cases.append({"name": name, "minute_hr": series, "resting": rest, "maximum": maximum, "sex": sex,
                             "expected_trimp": t, "expected_strain": strain_from_trimp(t)})

    # ---- Sleep need ------------------------------------------------------------------
    need_inputs = [(480.0, None, None, None), (480.0, 15.5, 480.0, 400.0), (480.0, 21.0, 600.0, 200.0),
                   (450.0, 8.0, 450.0, 470.0)]
    need_cases = [{"goal": g, "previous_strain": s, "previous_need": n, "previous_asleep": a,
                   "expected": sleep_need(g, s, n, a)} for g, s, n, a in need_inputs]

    # ---- Recovery --------------------------------------------------------------------
    base_hrv = [62.0, 58.5, 65.2, 60.1, 59.8, 63.3, 61.0]
    base_rhr = [54.0, 55.2, 53.1, 54.6, 53.9, 54.4, 55.0]
    rec_inputs = [
        ("at_baseline", 61.3, 54.3, 450.0, 480.0, base_hrv, base_rhr),
        ("great_night", 72.0, 51.5, 500.0, 480.0, base_hrv, base_rhr),
        ("rough_night", 45.0, 59.0, 300.0, 520.0, base_hrv, base_rhr),
        ("short_baseline", 60.0, 54.0, 450.0, 480.0, base_hrv[:3], base_rhr[:3]),
        ("flat_baseline", 61.0, 54.0, 480.0, 480.0, [61.0] * 5, [54.0] * 5),
        ("no_hrv", None, 54.0, 450.0, 480.0, base_hrv, base_rhr),
    ]
    rec_cases = [{"name": n, "hrv": h, "rhr": r, "sleep_minutes": s, "need": nd, "baseline_hrv": bh,
                  "baseline_rhr": br, "expected": recovery(h, r, s, nd, bh, br)}
                 for n, h, r, s, nd, bh, br in rec_inputs]

    return {
        "algorithm_version": ALGORITHM_VERSION,
        "generated_by": "re-toolkit/tools/make_metric_vectors.py",
        "tolerance": 1e-9,
        "rr_clean": rr_clean,
        "rmssd": rmssd_cases,
        "overnight_rmssd": overnight,
        "resting_hr": resting,
        "cole_kripke": ck,
        "sleep": sleep_cases,
        "strain": strain_cases,
        "sleep_need": need_cases,
        "recovery": rec_cases,
    }


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(build_vectors(), indent=1) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
