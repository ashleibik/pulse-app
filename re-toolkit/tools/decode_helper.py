"""
decode_helper.py: find the meaning of unknown bytes by comparing captures.

Run from re-toolkit/ (globs like captures/*.jsonl work on Windows too):

    python -m tools.decode_helper summary captures/*.jsonl
        What packet types arrived, on which characteristic, how long, how many.

    python -m tools.decode_helper diff captures/x.jsonl --type 0x2f --start 0 --end 32
        Packets lined up row by row. Bytes that changed since the previous row are highlighted,
        bytes that never change are dimmed. Your eye finds counters/timestamps/sensors fast.

    python -m tools.decode_helper fields captures/x.jsonl --type 0x2f
        Per-offset stats plus automatic guesses: "timestamp?", "counter?", "float32?".

    python -m tools.decode_helper labels captures/rest.jsonl captures/walk.jsonl --type 0x2f
        Which bytes differ most between labels (resting vs walking -> motion/HR fields).

    python -m tools.decode_helper hr captures/x.jsonl --type 0x2f
        Correlate every byte with the TRUE heart rate from standard 0x2A37 (needs a capture
        made with --hr-broadcast). A byte with r close to 1.0 is almost certainly HR.

Offsets are always into the INNER bytes (inner[0] = packet type), the same convention as
docs/PROTOCOL.md.
"""

from __future__ import annotations

import argparse
import bisect
import glob
import json
import math
import os
import statistics
import struct
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

from protocol.constants import PLAUSIBLE_UNIX_MIN, PacketType, char_name, enum_name

sys.stdout.reconfigure(errors="replace")


# ======================================================================================
# Loading
# ======================================================================================

@dataclass
class Pkt:
    t: float
    label: str
    char: str
    ptype: int
    inner: bytes


@dataclass
class Capture:
    packets: list[Pkt]
    hrm: list[tuple[float, int]]   # (time, true HR from 0x2A37), sorted by time


def expand(paths: list[str]) -> list[Path]:
    out: list[Path] = []
    for p in paths:
        matches = glob.glob(p)
        out += [Path(m) for m in sorted(matches)] if matches else [Path(p)]
    return out


def load(paths: list[str]) -> Capture:
    packets, hrm = [], []
    for path in expand(paths):
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue  # a half-written last line if the tool was killed
                if rec.get("kind") == "frame" and rec.get("valid"):
                    raw = bytes.fromhex(rec["hex"])
                    inner = raw[4:-4]
                    if inner:
                        packets.append(Pkt(rec["t"], rec.get("label", "?"), rec.get("char", "?"), inner[0], inner))
                elif rec.get("kind") == "hrm" and rec.get("hr"):
                    hrm.append((rec["t"], rec["hr"]))
    hrm.sort()
    return Capture(packets, hrm)


def select(cap: Capture, ptype: int | None, length: int | None, label: str | None, char: str | None) -> list[Pkt]:
    pk = cap.packets
    if ptype is not None:
        pk = [p for p in pk if p.ptype == ptype]
    if label:
        pk = [p for p in pk if p.label == label]
    if char:
        pk = [p for p in pk if char.lower() in (p.char.lower(), char_name(p.char).lower())]
    if length is None and pk:
        # Packets of different lengths are different layouts. Compare like with like.
        length, n = Counter(len(p.inner) for p in pk).most_common(1)[0]
        others = len(pk) - n
        if others:
            print(f"(using the most common length {length}; {others} packets of other lengths skipped, use --len)")
    return [p for p in pk if len(p.inner) == length] if length is not None else pk


# ======================================================================================
# Analysis (pure functions, unit-tested)
# ======================================================================================

def byte_stats(inners: list[bytes]) -> list[dict]:
    """For each offset: distinct values, min, max, mean, and whether it ever changes."""
    n = min(len(b) for b in inners)
    out = []
    for off in range(n):
        col = [b[off] for b in inners]
        out.append({
            "offset": off, "distinct": len(set(col)), "min": min(col), "max": max(col),
            "mean": statistics.fmean(col), "constant": len(set(col)) == 1,
        })
    return out


def guess_fields(inners: list[bytes]) -> list[tuple[int, str, str]]:
    """
    Try common multi-byte interpretations at every offset. Returns (offset, guess, example).
    These are HINTS, not facts. Confirm by eye with `diff`.
    """
    n = min(len(b) for b in inners)
    latest = time.time() + 365 * 86400  # timestamps from the future are coincidences
    guesses = []
    off = 0
    while off < n - 1:
        u16 = [struct.unpack_from("<H", b, off)[0] for b in inners]
        if off + 4 <= n:
            u32 = [struct.unpack_from("<I", b, off)[0] for b in inners]
            if all(PLAUSIBLE_UNIX_MIN <= v <= latest for v in u32):
                guesses.append((off, "u32 unix timestamp?", str(u32[0])))
                off += 4  # these 4 bytes are explained; don't guess inside them
                continue
            if len(set(u32)) > 1 and _is_counter(u32):
                guesses.append((off, "u32 counter?", f"{u32[0]}..{u32[-1]}"))
                off += 4
                continue
            f32 = [struct.unpack_from("<f", b, off)[0] for b in inners]
            if (len(set(f32)) > 1 and all(math.isfinite(v) and 1e-3 < abs(v) < 64 for v in f32)):
                guesses.append((off, "float32 (sensor? e.g. accel in g)", f"{f32[0]:.4f}"))
                off += 4
                continue
        if len(set(u16)) > 1 and _is_counter(u16):
            guesses.append((off, "u16 counter?", f"{u16[0]}..{u16[-1]}"))
            off += 2
            continue
        off += 1
    return guesses


def _is_counter(values: list[int]) -> bool:
    """Mostly increases by the same small step (allowing for occasional gaps)."""
    if len(values) < 3:
        return False
    steps = [b - a for a, b in zip(values, values[1:])]
    step, count = Counter(steps).most_common(1)[0]
    return 0 < step <= 16 and count >= 0.8 * len(steps)


def label_differences(packets: list[Pkt], top: int = 10) -> list[tuple[int, float, dict[str, float]]]:
    """
    Rank offsets by how differently they behave between labels.
    score = (largest mean - smallest mean) / (average spread + 1). Bigger means more label-dependent.
    """
    by_label: dict[str, list[bytes]] = defaultdict(list)
    for p in packets:
        by_label[p.label].append(p.inner)
    if len(by_label) < 2:
        return []
    n = min(len(p.inner) for p in packets)
    constant = {s["offset"] for s in byte_stats([p.inner for p in packets]) if s["constant"]}
    results = []
    for off in range(n):
        if off in constant:
            continue
        means, spreads = {}, []
        for lbl, rows in by_label.items():
            col = [r[off] for r in rows]
            means[lbl] = statistics.fmean(col)
            spreads.append(statistics.pstdev(col))
        score = (max(means.values()) - min(means.values())) / (statistics.fmean(spreads) + 1)
        results.append((off, round(score, 2), {k: round(v, 1) for k, v in means.items()}))
    results.sort(key=lambda r: r[1], reverse=True)
    return results[:top]


def pearson(xs: list[float], ys: list[float]) -> float:
    if len(xs) < 3:
        return 0.0
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    return 0.0 if sxx == 0 or syy == 0 else sxy / math.sqrt(sxx * syy)


def hr_correlation(packets: list[Pkt], hrm: list[tuple[float, int]], max_gap_s: float = 2.0,
                   top: int = 10) -> tuple[int, list[tuple[int, str, float]]]:
    """
    Pair each packet with the 0x2A37 HR reading closest in time (within max_gap_s), then
    compute the correlation between HR and every byte (u8) and byte pair (u16 LE).
    Returns (number of matched packets, [(offset, "u8"/"u16", r)]).
    """
    times = [t for t, _ in hrm]
    pairs: list[tuple[bytes, int]] = []
    for p in packets:
        i = bisect.bisect_left(times, p.t)
        best = min((j for j in (i - 1, i) if 0 <= j < len(times)), key=lambda j: abs(times[j] - p.t), default=None)
        if best is not None and abs(times[best] - p.t) <= max_gap_s:
            pairs.append((p.inner, hrm[best][1]))
    if len(pairs) < 3:
        return len(pairs), []
    hrs = [float(h) for _, h in pairs]
    n = min(len(b) for b, _ in pairs)
    constant = {s["offset"] for s in byte_stats([b for b, _ in pairs]) if s["constant"]}
    results = []
    for off in range(n):
        if off in constant:
            continue
        results.append((off, "u8", pearson([float(b[off]) for b, _ in pairs], hrs)))
        # Skip u16 candidates where one byte never changes: that's just the other byte scaled
        # by 1 or 256, so it would tie with the real u8 field and hide it.
        if off + 2 <= n and off not in constant and off + 1 not in constant:
            results.append((off, "u16", pearson([float(struct.unpack_from("<H", b, off)[0]) for b, _ in pairs], hrs)))
    results.sort(key=lambda r: abs(r[2]), reverse=True)
    return len(pairs), [(o, k, round(r, 3)) for o, k, r in results[:top]]


# ======================================================================================
# Printing
# ======================================================================================

class Colors:
    def __init__(self, enabled: bool) -> None:
        if enabled and os.name == "nt":
            os.system("")  # enables ANSI colour codes in the classic Windows console
        self.on = enabled

    def _c(self, code: str, s: str) -> str:
        return f"\033[{code}m{s}\033[0m" if self.on else s

    def changed(self, s): return self._c("1;33", s)   # bold yellow
    def const(self, s): return self._c("2", s)        # dim
    def head(self, s): return self._c("36", s)        # cyan


def cmd_summary(cap: Capture, _args, _col) -> None:
    groups = Counter((char_name(p.char), p.ptype, len(p.inner)) for p in cap.packets)
    labels = defaultdict(set)
    for p in cap.packets:
        labels[(char_name(p.char), p.ptype, len(p.inner))].add(p.label)
    print(f"{'char':<10} {'type':<22} {'inner len':>9} {'count':>7}  labels")
    for (ch, pt, ln), n in sorted(groups.items()):
        print(f"{ch:<10} 0x{pt:02x} {enum_name(PacketType, pt):<17} {ln:>9} {n:>7}  {', '.join(sorted(labels[(ch, pt, ln)]))}")
    print(f"\n0x2A37 heart-rate readings: {len(cap.hrm)}")


def cmd_diff(pkts: list[Pkt], args, col: Colors) -> None:
    inners = [p.inner for p in pkts][: args.rows]
    end = min(args.end, min(len(b) for b in inners))
    stats = byte_stats(inners)
    print(col.head("off   " + " ".join(f"{o:02d}" for o in range(args.start, end))))
    prev = None
    for p, b in zip(pkts, inners):
        cells = []
        for o in range(args.start, end):
            h = f"{b[o]:02x}"
            if stats[o]["constant"]:
                h = col.const(h)
            elif prev is not None and prev[o] != b[o]:
                h = col.changed(h)
            cells.append(h)
        print(f"{p.label[:5]:<5} " + " ".join(cells))
        prev = b
    print(col.const("\ndim = never changes   ") + col.changed("yellow = changed since previous row"))


def cmd_fields(pkts: list[Pkt], _args, col: Colors) -> None:
    inners = [p.inner for p in pkts]
    print(col.head("Per-byte stats (constant bytes hidden):"))
    print(f"{'off':>4} {'distinct':>8} {'min':>4} {'max':>4} {'mean':>7}")
    for s in byte_stats(inners):
        if not s["constant"]:
            print(f"{s['offset']:>4} {s['distinct']:>8} {s['min']:>4} {s['max']:>4} {s['mean']:>7.1f}")
    const = [s["offset"] for s in byte_stats(inners) if s["constant"]]
    print(col.const(f"constant offsets: {const}"))
    print(col.head("\nGuesses (hints, verify with `diff`):"))
    for off, guess, example in guess_fields(inners):
        print(f"  inner[{off}]  {guess:<36} e.g. {example}")


def cmd_labels(pkts: list[Pkt], _args, col: Colors) -> None:
    res = label_differences(pkts)
    if not res:
        print("Need packets from at least 2 different labels.")
        return
    print(col.head("Offsets that differ most between labels:"))
    for off, score, means in res:
        print(f"  inner[{off:>3}]  score {score:>6}   means {means}")


def cmd_hr(pkts: list[Pkt], args, col: Colors, cap: Capture) -> None:
    n, res = hr_correlation(pkts, cap.hrm)
    print(f"matched {n} packets with a 0x2A37 reading within 2 s")
    if not res:
        print("Not enough matches. Make a capture with:  python -m tools.sniff --hr-broadcast --realtime")
        return
    print(col.head("Bytes most correlated with true heart rate (|r| near 1 = strong):"))
    for off, kind, r in res:
        print(f"  inner[{off:>3}] {kind:<4} r = {r:+.3f}")


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description="Compare WHOOP captures to map unknown bytes.")
    p.add_argument("mode", choices=["summary", "diff", "fields", "labels", "hr"])
    p.add_argument("files", nargs="+", help="capture .jsonl files (globs ok)")
    p.add_argument("--type", type=lambda s: int(s, 0), help="packet type, e.g. 0x2f")
    p.add_argument("--len", type=int, dest="length", help="only packets with this inner length")
    p.add_argument("--label", help="only packets with this label")
    p.add_argument("--char", help="only this characteristic (e.g. DATA or 61080005)")
    p.add_argument("--rows", type=int, default=40, help="diff: max rows")
    p.add_argument("--start", type=int, default=0, help="diff: first offset")
    p.add_argument("--end", type=int, default=32, help="diff: last offset (exclusive)")
    p.add_argument("--no-color", action="store_true")
    args = p.parse_args(argv)

    col = Colors(not args.no_color and sys.stdout.isatty())
    cap = load(args.files)
    if not cap.packets:
        print("No valid frames found in those files.")
        return
    if args.mode == "summary":
        cmd_summary(cap, args, col)
        return
    pkts = select(cap, args.type, args.length, args.label, args.char)
    if not pkts:
        print("No packets match those filters. Run `summary` first to see what's there.")
        return
    print(f"{len(pkts)} packets, inner length {len(pkts[0].inner)}\n")
    if args.mode == "diff":
        cmd_diff(pkts, args, col)
    elif args.mode == "fields":
        cmd_fields(pkts, args, col)
    elif args.mode == "labels":
        cmd_labels(pkts, args, col)
    elif args.mode == "hr":
        cmd_hr(pkts, args, col, cap)


if __name__ == "__main__":
    main()
