"""
Tiny statistics helpers with EXACT definitions (docs/METRICS.md §0).

We avoid statistics.fmean / sum() on purpose: Python 3.12+ uses compensated summation for
floats, which can differ from Swift's plain left-to-right sum in the last decimal place.
Writing the loops ourselves keeps Python and Swift bit-for-bit comparable.
"""

import math


def mean(xs):
    total = 0.0
    for x in xs:
        total += x
    return total / len(xs)


def median(xs):
    s = sorted(xs)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 == 1 else (s[mid - 1] + s[mid]) / 2.0


def sample_sd(xs):
    m = mean(xs)
    total = 0.0
    for x in xs:
        total += (x - m) * (x - m)
    return math.sqrt(total / (len(xs) - 1))


def lower_percentile(xs, p):
    s = sorted(xs)
    return s[int(math.floor(p * (len(s) - 1)))]


def phi(x):
    """Standard normal cumulative distribution function."""
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def clamp(x, lo, hi):
    return max(lo, min(hi, x))
