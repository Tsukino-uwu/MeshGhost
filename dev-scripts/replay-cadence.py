#!/usr/bin/env python3
"""Turn "that replay ghost looks stuttery" into a number.

    python dev-scripts/replay-cadence.py <clip.ndjson> [more clips...]

A replay ghost renders LocalInterpolationDelay behind (25 ms by default) and
local ghosts never extrapolate (core/remotes.go: `ahead = 0` for a local id), so
when the render clock passes the newest sample the buffer returns that sample
unchanged -- the ghost freezes on it until the next one is due, then jumps.
Every gap in a clip wider than that delay is one freeze-and-jump.

So the question "why does this look stuttery" is answerable from the file alone,
with no game running and nobody judging a screen:

  * how far apart the samples are, and what share exceed 25 ms;
  * whether the wide gaps are LOAD (irregular, and the character moves further
    across them) or a TIMER (a hard floor, same move per sample either way).

The second is what this exists for. Written 2026-09-06, when two clips from a
Linux/Proton tester showed 27-30% of updates over 25 ms with a hard floor at
exactly 40 ms -- Linux's delayed-ACK minimum -- and identical movement per
sample on both sides of the gap. That is not a frame rate: it is Nagle holding
one small write per frame until the previous is acknowledged, because no adapter
set TCP_NODELAY. A Windows clip recorded the same day sat at 0.6%.

Read the "move per sample" line first. If the two numbers match, the frames were
produced steadily and only their DELIVERY bunched, which is a transport problem
and not the game's.
"""

import json
import math
import os
import sys

LOCAL_INTERP_MS = 25  # core.DefaultLocalGhostDelay
BANDS = [("0-5", 0, 5), ("6-15", 6, 15), ("16-25", 16, 25), ("26-40", 26, 40),
         ("41-60", 41, 60), ("61-100", 61, 100), (">100", 101, 10 ** 9)]


def load(path):
    header, rows = None, []
    with open(path, "rb") as f:
        for n, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line.decode("utf-8"))
            except Exception:
                continue
            if n == 0 and "meshghost_replay" in o:
                header = o
                continue
            if "timestamp" in o:
                rows.append((o["timestamp"], o.get("position") or []))
    return header, rows


def dist(a, b):
    if not a or not b or len(a) != len(b):
        return 0.0
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def median(v):
    v = sorted(v)
    return v[len(v) // 2] if v else 0.0


def report(path):
    header, rows = load(path)
    if len(rows) < 3:
        print("%s: not a replay clip with samples" % path)
        return
    print("=" * 78)
    print(os.path.basename(path))
    if header:
        print("  recorded %s   name %r   speed %s   loop %s"
              % (header.get("recorded"), header.get("name"), header.get("speed"), header.get("loop")))

    stamps = sorted({t for t, _ in rows})
    span = (stamps[-1] - stamps[0]) / 1000.0
    gaps = sorted(b - a for a, b in zip(stamps, stamps[1:]))
    n = len(gaps)
    over = [g for g in gaps if g > LOCAL_INTERP_MS]
    print("  %d samples, %d distinct updates over %.3fs -> %.1f updates/s"
          % (len(rows), len(stamps), span, len(stamps) / span))
    print("  median %dms   p95 %dms   worst %dms"
          % (gaps[n // 2], gaps[int(n * 0.95)], gaps[-1]))
    print("  OVER %dms (one freeze-and-jump each): %d of %d (%.1f%%)"
          % (LOCAL_INTERP_MS, len(over), n, 100.0 * len(over) / n))
    for name, lo, hi in BANDS:
        c = sum(1 for g in gaps if lo <= g <= hi)
        if c:
            print("    %-8s %5d %5.1f%% %s" % (name + "ms", c, 100.0 * c / n, "#" * int(46.0 * c / n)))
    # A floor only means something once there are enough stalls to have one; a
    # handful of wide gaps in an otherwise clean clip is just the player standing
    # still, and calling that a timer signature would be a confident wrong answer.
    if len(over) >= 20:
        print("  stall floor %dms, median stall %dms  (a hard floor is a TIMER, not load;"
              " Linux delayed-ACK minimum is 40ms)" % (min(over), median(over)))

    near = [dist(p1, p2) for (t1, p1), (t2, p2) in zip(rows, rows[1:]) if t2 - t1 <= 5]
    far = [dist(p1, p2) for (t1, p1), (t2, p2) in zip(rows, rows[1:]) if t2 - t1 > LOCAL_INTERP_MS]
    if near and far:
        print("  move per sample: %.2f units across a <=5ms gap, %.2f across a >%dms gap"
              % (median(near), median(far), LOCAL_INTERP_MS))
        # Three readings, and the idle one has to be checked FIRST: a clip whose
        # wide gaps are the player standing still has near-zero movement across
        # them, which would otherwise read as "the same move either way" and give
        # a confident wrong answer on a perfectly healthy clip.
        if median(far) < 0.1 * median(near):
            print("    -> barely any movement across the wide gaps: those are IDLE moments, not"
                  " stutter. A clip like this is fine.")
        elif len(over) < 0.05 * n:
            print("    -> too few wide gaps (%.1f%%) to matter either way." % (100.0 * len(over) / n))
        else:
            ratio = median(far) / median(near) if median(near) else 0
            if ratio < 1.5:
                print("    -> the SAME move either way: frames were produced steadily and only"
                      " their DELIVERY bunched. Look at the transport, not the frame rate.")
            else:
                print("    -> %.1fx further across the wide gaps: the game really was producing"
                      " frames more slowly there." % ratio)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for p in sys.argv[1:]:
        report(p)
