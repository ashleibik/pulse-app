"""Sleep detection from HR + motion.  Spec: docs/METRICS.md §4."""

from .stats import lower_percentile

# Cole & Kripke 1992, 1-minute epochs: weights for A[i-4] .. A[i+2]
COLE_KRIPKE_WEIGHTS = (106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0)
COLE_KRIPKE_DIVISOR = 6000.0   # calibrated to OUR activity units, not the 1992 device (re-calibrate in Phase 5)
HR_GATE_MARGIN = 15.0


def cole_kripke(activity):
    a = [0.0 if v is None else float(v) for v in activity]
    n = len(a)
    out = []
    for i in range(n):
        total = 0.0
        for k, w in enumerate(COLE_KRIPKE_WEIGHTS):
            j = i + k - 4
            if 0 <= j < n:
                total += w * a[j]
        out.append(total / COLE_KRIPKE_DIVISOR)
    return out


def hr_thresholds(hr, blocks):
    """HR gate per block: 10th percentile of the block's worn HR + margin (None if the block has no data)."""
    worn_by_block = {}
    for v, b in zip(hr, blocks):
        if v is not None:
            worn_by_block.setdefault(b, []).append(v)
    return {b: lower_percentile(vals, 0.10) + HR_GATE_MARGIN for b, vals in worn_by_block.items()}


def classify(hr, activity, blocks=None):
    """
    One bool per minute: asleep?
    blocks: one block id per minute (24 h from local noon, computed by the caller). None = a single block.
    """
    if blocks is None:
        blocks = [0] * len(hr)
    thresholds = hr_thresholds(hr, blocks)
    d = cole_kripke(activity)
    return [hr[i] is not None and activity[i] is not None and d[i] < 1.0 and hr[i] < thresholds[blocks[i]]
            for i in range(len(hr))]


def sessions(asleep, min_seed=10, max_gap=30, min_session=20, nap_limit=180, restless_gap=120):
    """Group asleep minutes into sessions. Indices are minute positions; end is exclusive."""
    seeds = []
    i, n = 0, len(asleep)
    while i < n:
        if asleep[i]:
            j = i
            while j < n and asleep[j]:
                j += 1
            if j - i >= min_seed:
                seeds.append([i, j])
            i = j
        else:
            i += 1

    merged = []
    for s in seeds:
        if merged:
            gap_start, gap_end = merged[-1][1], s[0]
            gap = gap_end - gap_start
            asleep_in_gap = sum(1 for k in range(gap_start, gap_end) if asleep[k])
            if gap <= max_gap or (gap <= restless_gap and asleep_in_gap * 4 >= gap):
                merged[-1][1] = s[1]
                continue
        merged.append(list(s))

    out = []
    for start, end in merged:
        span = end - start
        if span < min_session:
            continue
        awake, disturbances, previous_asleep = 0, 0, True
        for k in range(start, end):
            if not asleep[k]:
                awake += 1
                if previous_asleep:
                    disturbances += 1
            previous_asleep = asleep[k]
        out.append({"start": start, "end": end, "asleep": span - awake, "awake": awake,
                    "disturbances": disturbances, "is_nap": span < nap_limit})
    return out
