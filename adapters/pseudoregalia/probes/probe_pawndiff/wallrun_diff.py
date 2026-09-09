"""Diff the latest GHOST ENTRY snapshot against the latest PLAYER ENTRY snapshot in a
wallrun-*.log written by probes/probe_pawndiff/Scripts/wallrun_entry.lua. Usage:
python wallrun_diff.py <log> [ENTRY|+250ms|BEFORE]
Prints every key whose value differs, and the keys present on one side only."""
import sys, re

path = sys.argv[1]
phase = sys.argv[2] if len(sys.argv) > 2 else "ENTRY"
snaps = []  # (header, dict)
cur = None
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if line.startswith("--- "):
        cur = (line[4:], {})
        snaps.append(cur)
    elif cur and line.startswith("  ") and " = " in line:
        k, v = line[2:].split(" = ", 1)
        cur[1][k] = v

def latest(who):
    for h, d in reversed(snaps):
        if h.startswith(who) and (" " + phase) in h:
            return h, d
    return None, None

ph, pd = latest("PLAYER")
gh, gd = latest("GHOST")
print("player:", ph)
print("ghost: ", gh)
if not pd or not gd:
    sys.exit("missing a side")
keys = sorted(set(pd) | set(gd))
n = 0
for k in keys:
    a, b = pd.get(k, "<absent>"), gd.get(k, "<absent>")
    if a != b:
        n += 1
        print(f"  {k}: player={a} ghost={b}")
print(f"{n} differing of {len(keys)}")
