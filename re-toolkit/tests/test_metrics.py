"""Python reference metrics: hand-checked examples + 'the shared vectors file is up to date'."""

import json
import math

import pytest

from metrics.hrv import clean_beats, clean_rr, overnight_rmssd, resting_hr, rmssd
from metrics.load import max_hr_tanaka, recovery, sleep_need, strain_from_trimp, trimp
from metrics.sleep import classify, cole_kripke, sessions
from metrics.stats import lower_percentile, median, sample_sd
from tools.make_metric_vectors import OUT, build_vectors


# ------------------------------------------------------------- helpers

def test_stats_definitions():
    assert median([3, 1, 2]) == 2
    assert median([4, 1, 3, 2]) == 2.5
    assert sample_sd([2, 4, 4, 4, 5, 5, 7, 9]) == pytest.approx(2.13809, abs=1e-5)
    assert lower_percentile(list(range(1, 11)), 0.10) == 1     # floor(0.1 * 9) = 0
    assert lower_percentile(list(range(1, 101)), 0.10) == 10   # floor(0.1 * 99) = 9


# ------------------------------------------------------------- HRV

def test_rmssd_by_hand():
    # diffs 10, -20, 10 -> sqrt((100 + 400 + 100) / 3) = sqrt(200)
    assert rmssd([800, 810, 790, 800], min_pairs=1) == pytest.approx(math.sqrt(200))
    assert rmssd([800, 810, 790, 800]) is None                  # < 20 pairs


def test_clean_rr_rejects_artifacts_but_keeps_positions():
    rr = [900.0] * 21
    rr[10] = 1800.0   # missed beat
    rr[15] = 2600.0   # impossible
    out = clean_rr(rr)
    assert len(out) == len(rr)
    assert out[10] is None and out[15] is None
    assert out.count(None) == 2


def test_rmssd_never_pairs_across_a_rejected_beat():
    # without the gap rule, 900 -> 950 would count as a 50 ms difference
    assert rmssd([900.0, None, 950.0, 950.0], min_pairs=1) == 0.0


def test_overnight_needs_three_segments():
    minute = [[900.0, 910.0] * 30]
    assert overnight_rmssd(minute * 14, [True] * 14) is None   # only 2 full 5-min segments
    assert overnight_rmssd(minute * 15, [True] * 15) == pytest.approx(10.0)


def test_resting_hr_is_lowest_10_minute_mean():
    hr = [60.0] * 30 + [50.0] * 10 + [60.0] * 30
    assert resting_hr(hr) == 50.0
    hr[35] = None     # a gap breaks every window containing it
    assert resting_hr(hr) > 50.0


# ------------------------------------------------------------- sleep

def test_cole_kripke_formula():
    # One burst of movement at minute 4. Each nearby minute sees it through a different weight:
    # minute 4 as A[i] (230), minute 2 as A[i+2] (67), minute 8 as A[i-4] (106).
    act = [0.0] * 9
    act[4] = 6000.0
    d = cole_kripke(act)
    assert d[4] == 230.0              # 230 * 6000 / 6000
    assert d[2] == 67.0               # it's A[i+2] for minute 2
    assert d[8] == 106.0              # it's A[i-4] for minute 8
    assert d[1] == 0.0                # out of the window


def test_session_rules():
    flags = [False] * 5 + [True] * 50 + [False] * 3 + [True] * 40 + [False] * 100 + [True] * 12 + [False] * 5
    s = sessions(flags)
    assert s[0] == {"start": 5, "end": 98, "asleep": 90, "awake": 3, "disturbances": 1, "is_nap": True}
    # the 12-minute run is a seed but the session is shorter than 20 minutes -> dropped
    assert len(s) == 1


def test_restless_patch_stays_inside_the_night():
    # 60 asleep, then a 45-minute restless patch (5 asleep / 4 awake, repeated), then 60 asleep.
    restless = ([True] * 5 + [False] * 4) * 5
    flags = [True] * 60 + restless + [True] * 60
    s = sessions(flags)
    assert len(s) == 1 and s[0]["start"] == 0 and s[0]["end"] == len(flags)
    assert s[0]["disturbances"] == 5
    # ...but 45 minutes fully awake splits it
    flags = [True] * 60 + [False] * 45 + [True] * 60
    assert len(sessions(flags)) == 2


def test_sleep_detection_on_a_simple_night():
    hr = [75.0] * 60 + [55.0] * 240 + [76.0] * 60
    act = [12.0] * 60 + [1.0] * 240 + [12.0] * 60
    s = sessions(classify(hr, act))
    assert len(s) == 1
    assert abs(s[0]["start"] - 60) <= 2 and abs(s[0]["end"] - 300) <= 3


# ------------------------------------------------------------- load + recovery

def test_strain_examples():
    assert trimp([60.0] * 600, 55, 190) == 0.0                   # sitting around: below HRr 0.2
    run = trimp([55 + 0.8 * 135] * 60, 55, 190)
    assert strain_from_trimp(run) == pytest.approx(14.0, abs=0.5)  # calibration target
    assert strain_from_trimp(1e9) == pytest.approx(21.0)
    assert max_hr_tanaka(30) == 187.0


def test_sleep_need_examples():
    assert sleep_need(480, None, None, None) == 480
    assert sleep_need(480, 15, 480, 400) == 480 + 30 + 40
    assert sleep_need(480, 21, 600, 0) == 600                     # capped


def test_recovery_examples():
    base_hrv, base_rhr = [60.0, 62.0, 58.0, 61.0, 59.0], [54.0, 55.0, 53.0, 54.0, 54.0]
    at_base = recovery(60.0, 54.0, 432.0, 480.0, base_hrv, base_rhr)   # 432/480 = 0.9 -> zSleep 0
    assert at_base == pytest.approx(50.0, abs=1.5)
    assert recovery(75.0, 51.0, 480.0, 480.0, base_hrv, base_rhr) > 85
    assert recovery(45.0, 59.0, 300.0, 480.0, base_hrv, base_rhr) < 10
    assert recovery(60.0, 54.0, 450.0, 480.0, base_hrv[:3], base_rhr[:3]) is None


# ------------------------------------------------------------- shared vectors

def test_vectors_file_is_up_to_date():
    """If this fails: run `python -m tools.make_metric_vectors` and commit the JSON."""
    assert OUT.exists(), "vectors file missing"
    on_disk = json.loads(OUT.read_text(encoding="utf-8"))
    fresh = json.loads(json.dumps(build_vectors()))
    assert on_disk == fresh


def test_protocol_vectors_file_is_up_to_date():
    """If this fails: run `python -m tools.make_protocol_vectors` and commit the JSON."""
    from tools import make_protocol_vectors as pv
    assert pv.OUT.exists(), "protocol vectors file missing"
    on_disk = json.loads(pv.OUT.read_text(encoding="utf-8"))
    assert on_disk == json.loads(json.dumps(pv.build_vectors()))


def test_clean_beats_drops_filler_impossible_beats_and_big_jumps():
    beats = [900.0] * 20
    beats[3], beats[8], beats[12] = 500.0, 2400.0, 1500.0
    clean = clean_beats(beats)
    assert clean[3] is None and clean[8] is None and clean[12] is None
    assert sum(b is not None for b in clean) == 17
    step = clean_beats([800.0] * 6 + [980.0] * 6)
    assert step[6] is None and step[5] == 800.0 and step[7] == 980.0


def test_overnight_rmssd_never_pairs_beats_across_two_minutes():
    minutes = [[900.0 + (i % 2) * 40.0] * 60 for i in range(15)]
    assert overnight_rmssd(minutes, [True] * 15) == 0.0
