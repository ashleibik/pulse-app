"""
Tests for decode_helper using a SYNTHETIC capture. We plant fields at known offsets and
check the helper finds them, which proves the tool works before real data exists.
"""

import json
import random
import struct

from protocol.frames import build_frame
from tools.decode_helper import (
    byte_stats, guess_fields, hr_correlation, label_differences, load, select,
)


def _fake_capture(path, seed=1):
    """
    Fake 0x2F records with known fields:
      inner[3:7]  u32 counter   inner[7:11] u32 timestamp   inner[17] HR
      inner[20]   motion: low when 'resting', high when 'walking'
    plus matching 0x2A37 'hrm' lines.
    """
    rnd = random.Random(seed)
    t0 = 1_750_000_000
    lines = []
    for i in range(120):
        label = "resting" if i < 60 else "walking"
        hr = 55 + rnd.randint(-3, 3) if label == "resting" else 100 + rnd.randint(-8, 8)
        inner = bytearray(24)
        inner[0], inner[1] = 0x2F, 24
        struct.pack_into("<I", inner, 3, 5000 + i)
        struct.pack_into("<I", inner, 7, t0 + i)
        inner[17] = hr
        inner[20] = rnd.randint(0, 5) if label == "resting" else rnd.randint(80, 120)
        inner[22] = rnd.randint(0, 255)  # pure noise
        t = t0 + i
        lines.append({"t": t, "label": label, "kind": "frame", "valid": True,
                      "char": "61080005-8d6d-82b8-614a-1c8cb0f8dcc6", "hex": build_frame(bytes(inner)).hex()})
        lines.append({"t": t + 0.2, "label": label, "kind": "hrm", "hr": hr, "rr_ms": []})
    path.write_text("\n".join(json.dumps(x) for x in lines))


def test_finds_planted_fields(tmp_path):
    f = tmp_path / "cap.jsonl"
    _fake_capture(f)
    cap = load([str(f)])
    pkts = select(cap, 0x2F, None, None, None)
    assert len(pkts) == 120 and len(cap.hrm) == 120

    inners = [p.inner for p in pkts]
    stats = byte_stats(inners)
    assert stats[0]["constant"] and stats[1]["constant"]

    guesses = {off: g for off, g, _ in guess_fields(inners)}
    assert "counter" in guesses[3]
    assert "timestamp" in guesses[7]

    top_label_offset = label_differences(pkts)[0][0]
    assert top_label_offset in (17, 20)       # HR and motion both change with activity

    n, res = hr_correlation(pkts, cap.hrm)
    assert n == 120
    off, kind, r = res[0]
    assert (off, kind) == (17, "u8") and r > 0.99   # the HR byte is found
