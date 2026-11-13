"""Strain, sleep need, recovery.  Spec: docs/METRICS.md §5-7."""

import math

from .stats import clamp, mean, phi, sample_sd

# Banister TRIMP coefficients (Morton, Fitz-Clarke & Banister 1990)
TRIMP_COEFFICIENTS = {"male": (0.64, 1.92), "female": (0.86, 1.67)}
MIN_HRR = 0.2          # our choice: ignore everyday low-intensity minutes
STRAIN_K = 130.0       # our choice: hard 60-min run (HRr 0.8) ~= strain 14
MAX_STRAIN = 21.0
MIN_BASELINE_NIGHTS = 4


def max_hr_tanaka(age_years):
    """Tanaka, Monahan & Seals 2001."""
    return 208.0 - 0.7 * age_years


def trimp(minute_hr, resting, maximum, sex="male"):
    a, b = TRIMP_COEFFICIENTS.get(sex, TRIMP_COEFFICIENTS["male"])
    reserve = maximum - resting
    if reserve <= 0:
        return 0.0
    total = 0.0
    for hr in minute_hr:
        if hr is None:
            continue
        x = (hr - resting) / reserve
        if x < MIN_HRR:
            continue
        x = min(x, 1.0)
        total += x * a * math.exp(b * x)
    return total


def strain_from_trimp(t):
    return MAX_STRAIN * (1.0 - math.exp(-t / STRAIN_K))


def sleep_need(goal, previous_strain, previous_need, previous_asleep):
    need = goal
    if previous_strain is not None:
        need += 6.0 * max(0.0, previous_strain - 10.0)
    if previous_need is not None and previous_asleep is not None:
        need += 0.5 * max(0.0, previous_need - previous_asleep)
    return min(need, 600.0)


def recovery(hrv, rhr, sleep_minutes, need, baseline_hrv, baseline_rhr):
    if hrv is None or rhr is None:
        return None
    if len(baseline_hrv) < MIN_BASELINE_NIGHTS or len(baseline_rhr) < MIN_BASELINE_NIGHTS:
        return None
    ln_base = [math.log(v) for v in baseline_hrv]
    z_hrv = (math.log(hrv) - mean(ln_base)) / max(sample_sd(ln_base), 0.05)
    z_rhr = (rhr - mean(baseline_rhr)) / max(sample_sd(baseline_rhr), 1.0)
    ratio = min(sleep_minutes / need, 1.1) if (sleep_minutes is not None and need > 0) else 0.0
    z_sleep = clamp((ratio - 0.9) / 0.1, -3.0, 2.0)
    c = 0.6 * z_hrv - 0.25 * z_rhr + 0.15 * z_sleep
    return clamp(100.0 * phi(c), 1.0, 99.0)
