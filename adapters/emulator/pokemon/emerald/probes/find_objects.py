#!/usr/bin/env python3
"""MeshGhost -- Pokemon Emerald: which characters does a map place, with their raw template bytes? (DEV TOOL)

Reads YOUR vanilla ROM and a symbol file from a byte-identical build of it, and lists each map's
character templates: the list behind the map header's second pointer's first count, 24 bytes an entry,
where id +0, graphic +1 and x/y +4/+6 were measured against a live map (`emerald/MEASURED.md`, the map
entry, 2026-09-16). Written 2026-09-16 to find an undefeated trainer for autoplay's first trainer
battle: `--nonzero-at 0x0C` keeps only entries with a nonzero u16 at that offset, the field the decomp
names trainerType -- a place to LOOK, settled only by a trainer that spots the player there.

The header walk is `find_behaviour.py`'s (gMapGroups -> group -> header). Nothing is read from memory;
nothing is written.

Usage: find_objects.py ROM SYM GROUP [--nonzero-at OFFSET]
"""
import re
import struct
import sys


def main():
    args = sys.argv[1:]
    if len(args) < 3:
        print(__doc__)
        return 2
    nonzero_at = None
    if "--nonzero-at" in args:
        i = args.index("--nonzero-at")
        nonzero_at = int(args[i + 1], 0)
        del args[i:i + 2]
    rom = open(args[0], "rb").read()
    sym = {}
    for line in open(args[1]):
        p = line.split()
        if len(p) >= 4:
            sym[p[3]] = int(p[0], 16)
    group = int(args[2])

    def u32(a):
        return struct.unpack_from("<I", rom, a - 0x08000000)[0]

    groups = sorted(sym[k] for k in sym if re.fullmatch(r"gMapGroup_\w+", k))
    table = sym["gMapGroups"]
    bounds = groups + [table]
    gp = u32(table + group * 4)
    n = (bounds[bounds.index(gp) + 1] - gp) // 4
    for m in range(n):
        header = u32(gp + m * 4)
        events = u32(header + 4)
        if not 0x08000000 <= events < 0x0A000000:
            continue
        count, objects = rom[events - 0x08000000], u32(events + 4)
        rows = []
        for i in range(count):
            e = rom[objects - 0x08000000 + i * 24: objects - 0x08000000 + (i + 1) * 24]
            if nonzero_at is not None and struct.unpack_from("<H", e, nonzero_at)[0] == 0:
                continue
            x, y = struct.unpack_from("<hh", e, 4)
            rows.append(f"    id {e[0]} graphic {e[1]} at {x},{y} | +08.. {e[8:24].hex()}")
        if rows:
            print(f"map {group}.{m}: {len(rows)} of {count}")
            print("\n".join(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
