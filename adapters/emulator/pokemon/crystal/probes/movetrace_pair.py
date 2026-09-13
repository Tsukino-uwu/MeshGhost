"""Read two instances' MESHGHOST_CRYSTAL_MOVE_TRACE logs side by side (dev tool, reads logs only).

The adapter's move trace writes probes/movetrace_<bridge port>.log: an `S` line per frame for what that
client's engine SENDS, `R` lines per drawn peer for what arrives and what the model does, `P` lines for
the pose drawn -- all stamped with the wall clock, so two emulators' logs can be paired.

  python movetrace_pair.py lag  <sender.log> <receiver.log> [since_unix_time]
      For every movement start on the sender (a position change after >= 10 still frames): the delay
      from its first engine pixel to the receiver's TARGET changing and to its MODEL moving; plus, while
      the sender walks, how far the model sits behind the sender's same-instant position.
  python movetrace_pair.py turn <sender.log> <receiver.log> <since_unix_time> <nth>
      The sender's face bytes and the receiver's drawn pose across the nth direction change.
  python movetrace_pair.py dirflip <sender.log>
      Whether the sent direction changes on the same frame as a step's first pixel.
  python movetrace_pair.py idle <sender.log>
      Whether every idle frame's position is tile-aligned.

Written 2026-09-13; every number it produced that day is in crystal/UNVERIFIED.md and VERIFIED.md.
"""
import bisect
import re
import sys

S_RE = re.compile(r"^([\d.]+) f=(\d+) S pos=(-?\d+),(-?\d+) walk=(\w+) dir=(\w+)")
R_RE = re.compile(r"^([\d.]+) f=(\d+) R (\S+) tgt=(\S+),(\S+) model=(-?\d+),(-?\d+) left=(\d+)")


def load_s(path, since=0.0):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = S_RE.match(line)
        if m and float(m[1]) >= since:
            face = re.search(r"face=(\w+)", line)
            act = re.search(r"act=(\d+)", line)
            out.append({"t": float(m[1]), "f": int(m[2]), "pos": (int(m[3]), int(m[4])), "walk": m[5],
                        "dir": m[6], "face": face[1] if face else "?", "act": act[1] if act else "?"})
    return out


def load_r(path, since=0.0):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = R_RE.match(line)
        if m and float(m[1]) >= since:
            tx = None if m[4] == "nil" else float(m[4])
            ty = None if m[5] == "nil" else float(m[5])
            out.append({"t": float(m[1]), "f": int(m[2]), "id": m[3], "tgt": (tx, ty),
                        "model": (int(m[6]), int(m[7]))})
    return out


def lag(sender, receiver, since=0.0):
    S, R = load_s(sender, since), load_r(receiver, since)
    if not S or not R:
        print("no data", len(S), len(R))
        return
    rt = [r["t"] for r in R]
    still, starts = 0, []
    for i in range(1, len(S)):
        moved = S[i]["pos"] != S[i - 1]["pos"]
        if moved and still >= 10:
            starts.append(i)
        still = 0 if moved else still + 1
    tl, ml = [], []
    for i in starts:
        t0 = S[i]["t"]
        base_t = base_m = first_t = first_m = None
        for r in R[bisect.bisect_left(rt, t0 - 0.2):]:
            if r["t"] < t0 or base_t is None:
                base_t, base_m = r["tgt"], r["model"]
                if r["t"] < t0:
                    continue
            if first_t is None and r["tgt"] != base_t:
                first_t = r
            if first_m is None and r["model"] != base_m:
                first_m = r
            if (first_t and first_m) or r["t"] > t0 + 2.0:
                break
        dt = round((first_t["t"] - t0) * 1000) if first_t else None
        dm = round((first_m["t"] - t0) * 1000) if first_m else None
        if dt is not None:
            tl.append(dt)
        if dm is not None:
            ml.append(dm)
        print(f"  start sf={S[i]['f']} {S[i-1]['pos']}->{S[i]['pos']} dir={S[i]['dir']}: target +{dt}ms, model +{dm}ms")
    for name, xs in (("target", tl), ("model", ml)):
        if xs:
            xs.sort()
            print(f"{name} onset ms: median {xs[len(xs)//2]} min {xs[0]} max {xs[-1]} (n={len(xs)})")
    st = [s["t"] for s in S]
    behind = {}
    for r in R:
        i = bisect.bisect_right(st, r["t"]) - 1
        if i >= 0 and S[i]["walk"] == "walk":
            d = abs(S[i]["pos"][0] - r["model"][0]) + abs(S[i]["pos"][1] - r["model"][1])
            behind[d] = behind.get(d, 0) + 1
    print("model behind the sender while it walks (px: frames):", dict(sorted(behind.items())))


def turn(sender, receiver, since, nth):
    S = load_s(sender, since)
    changes = [i for i in range(1, len(S)) if S[i]["dir"] != S[i - 1]["dir"]]
    if len(changes) < nth:
        print("only", len(changes), "direction changes")
        return
    i = changes[nth - 1]
    t0 = S[i]["t"]
    print("SENDER (t, frame, dir, face, act)")
    for s in S[max(0, i - 3): i + 12]:
        print(f"  {s['t'] - t0:+.3f} f={s['f']} {s['dir']} face={s['face']} act={s['act']}")
    print("RECEIVER pose")
    for line in open(receiver, encoding="utf-8", errors="replace"):
        p = line.split()
        if len(p) > 3 and p[2] == "P" and t0 - 0.06 < float(p[0]) < t0 + 0.25:
            m = re.search(r"face=(\S+) .*-> dir=(\S+) stepping=(\S+) stride=(\S+)", line)
            print(f"  {float(p[0]) - t0:+.3f} {p[1]} face={m[1]} -> dir={m[2]} stepping={m[3]} stride={m[4]}")


def dirflip(sender):
    S = load_s(sender)
    hist = {}
    for i in range(1, len(S)):
        a, b = S[i - 1], S[i]
        if b["f"] != a["f"] + 1 or b["pos"] == a["pos"]:
            continue
        if b["dir"] != a["dir"]:
            hist["same frame"] = hist.get("same frame", 0) + 1
            continue
        j = i - 1
        while j > 0 and S[j]["pos"] == S[j - 1]["pos"] and S[j]["f"] == S[j - 1]["f"] + 1 and i - j < 12:
            if S[j]["dir"] != S[j - 1]["dir"]:
                key = f"{i - j} frame(s) before"
                hist[key] = hist.get(key, 0) + 1
                break
            j -= 1
    print("direction change relative to a step's first pixel:", hist)


def idle(sender):
    S = [s for s in load_s(sender) if s["walk"] == "idle"]
    bad = [s for s in S if s["pos"][0] % 16 or s["pos"][1] % 16]
    print(f"idle frames {len(S)}, not tile-aligned {len(bad)}", [(s["f"], s["pos"]) for s in bad[:5]])


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "lag":
        lag(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 0.0)
    elif mode == "turn":
        turn(sys.argv[2], sys.argv[3], float(sys.argv[4]), int(sys.argv[5]))
    elif mode == "dirflip":
        dirflip(sys.argv[2])
    elif mode == "idle":
        idle(sys.argv[2])
    else:
        print(__doc__)
