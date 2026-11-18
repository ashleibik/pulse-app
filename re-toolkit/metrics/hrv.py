"""RR cleaning, RMSSD, overnight HRV, resting HR.  Spec: docs/METRICS.md §1-3."""

import math

from .stats import mean, median

RR_MIN_MS = 300.0
RR_MAX_MS = 2000.0
FILLER_RR_MS = 500.0   # the band writes exactly this when it has no beat to report


def clean_rr(rr, half_window=5, tolerance=0.20):
    """
    Returns a list the same length as `rr`, with rejected beats replaced by None.
    Keeping positions matters: RMSSD may only pair beats that are truly next to each other.
    """
    valid = [float(x) if RR_MIN_MS <= x <= RR_MAX_MS else None for x in rr]
    out = []
    for i, x in enumerate(valid):
        if x is None:
            out.append(None)
            continue
        lo, hi = max(0, i - half_window), min(len(valid), i + half_window + 1)
        neighbours = [v for v in valid[lo:hi] if v is not None]
        m = median(neighbours)
        out.append(x if abs(x - m) <= tolerance * m else None)
    return out


def clean_beats(rr, tolerance=0.20):
    """clean_rr without the filler value, and without a beat >20% away from the clean beat right before it."""
    out = clean_rr([0.0 if x == FILLER_RR_MS else x for x in rr], tolerance=tolerance)
    previous = None
    for i, beat in enumerate(out):
        if beat is not None and previous is not None and abs(beat - previous) > tolerance * previous:
            out[i] = None
        previous = out[i]
    return out


def rmssd(rr, min_pairs=20):
    """RMSSD over adjacent pairs where both beats are present. None if too few pairs."""
    total, n = 0.0, 0
    for a, b in zip(rr, rr[1:]):
        if a is not None and b is not None:
            d = b - a
            total += d * d
            n += 1
    if n < min_pairs:
        return None
    return math.sqrt(total / n)   # sqrt, not ** 0.5: must match Swift's squareRoot() exactly


def overnight_rmssd(minute_rr, asleep, segment_minutes=5, min_segments=3):
    """
    minute_rr: list (one per minute) of lists of RR in ms.  asleep: list of bools (asleep AND worn).
    Median of 5-minute-segment RMSSDs over fully-asleep stretches.
    """
    values = []
    i, n = 0, len(minute_rr)
    while i + segment_minutes <= n:
        if all(asleep[i:i + segment_minutes]):
            # Each minute is cleaned alone, and the None between minutes stops a pair forming across them.
            beats = []
            for minute in minute_rr[i:i + segment_minutes]:
                beats += clean_beats([float(x) for x in minute]) + [None]
            v = rmssd(beats)
            if v is not None:
                values.append(v)
            i += segment_minutes
        else:
            i += 1
    return median(values) if len(values) >= min_segments else None


def resting_hr(minute_hr, window=10):
    """Lowest mean over `window` consecutive non-None minutes. None if there's no such window."""
    best = None
    for i in range(0, len(minute_hr) - window + 1):
        w = minute_hr[i:i + window]
        if any(v is None for v in w):
            continue
        m = mean(w)
        if best is None or m < best:
            best = m
    return best
