#!/usr/bin/env python3
"""MeshGhost -- Pokemon Emerald: where in the game is a tile with this metatile behaviour? (DEV TOOL)

Reads YOUR vanilla ROM and a symbol file from a byte-identical build of it, and scans every map's
grid for tiles whose behaviour byte is the one asked for. Prints each map with a count, and the
walkable tiles directly ABOVE one (the engine looks below a character for reflections), ready for
`cmd_drive.lua`'s `warp G.N X,Y`. Written 2026-09-16 to find real puddle, ice, bridge and Sootopolis
tiles for `borrowed_values_probe.lua` (`emerald/UNVERIFIED.md`, the per-site audit entry).

Layouts it relies on, each checked by the warps that followed landing where it said (2026-09-16):
gMapGroups -> per-group map header pointers -> header +0x00 layout -> layout {s32 width, s32 height,
+0x0C grid, +0x10 primary tileset, +0x14 secondary tileset} -> tileset +0x10 metatile attributes,
u16 per metatile, behaviour in the low byte; grid u16: metatile 0x3FF, collision 0xC00, elevation >> 12.
A group's map count is the gap to the next gMapGroup_* symbol. Nothing is read from memory; nothing
is written.

Usage: find_behaviour.py ROM SYM BEHAVIOUR [BEHAVIOUR ...]
"""
import collections
import re
import struct
import sys


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    rom = open(sys.argv[1], "rb").read()
    sym, size = {}, {}
    for line in open(sys.argv[2]):
        p = line.split()
        if len(p) >= 4:
            sym[p[3]] = int(p[0], 16)
            size[p[3]] = int(p[2], 16)
    wanted = [int(b) for b in sys.argv[3:]]

    def u32(a):
        return struct.unpack_from("<I", rom, a - 0x08000000)[0]

    def u16(a):
        return struct.unpack_from("<H", rom, a - 0x08000000)[0]

    counts = {sym[k]: size[k] // 2 for k in sym if k.startswith("gMetatileAttributes_")}
    groups = sorted(sym[k] for k in sym if re.fullmatch(r"gMapGroup_\w+", k))
    names = {sym[k]: k for k in sym if k.startswith("gMapGroup_")}
    table = sym["gMapGroups"]
    bounds = groups + [table]

    def layout_of(g, m):
        lay = u32(u32(u32(table + g * 4) + m * 4))
        w, h = struct.unpack_from("<ii", rom, lay - 0x08000000)
        prim, sec = u32(lay + 0x10), u32(lay + 0x14)
        return w, h, u32(lay + 0x0C), u32(prim + 0x10), (u32(sec + 0x10) if sec else 0)

    def tile(lay, x, y):
        w, h, grid, pa, sa = lay
        if not (0 <= x < w and 0 <= y < h):
            return None, None
        v = u16(grid + (x + w * y) * 2)
        mt = v & 0x3FF
        if mt < 512:
            b = u16(pa + mt * 2) & 0xFF if mt < counts.get(pa, 512) else None
        else:
            b = u16(sa + (mt - 512) * 2) & 0xFF if sa and mt - 512 < counts.get(sa, 0) else None
        return b, v

    found = collections.defaultdict(list)
    maps = {}
    for g in range(len(groups)):
        gp = u32(table + g * 4)
        if gp not in bounds:
            continue
        n = (bounds[bounds.index(gp) + 1] - gp) // 4
        for m in range(n):
            lay = layout_of(g, m)
            maps[(g, m)] = lay
            for y in range(lay[1]):
                for x in range(lay[0]):
                    b, _ = tile(lay, x, y)
                    if b in wanted:
                        found[b].append((g, m, x, y))

    for b in wanted:
        hits = found[b]
        per = collections.Counter((g, m) for g, m, _, _ in hits)
        print(f"behaviour {b}: {len(hits)} tiles on {len(per)} maps")
        for (g, m), c in per.most_common(8):
            print(f"  map {g}.{m} ({names.get(u32(table + g * 4))} #{m}): {c} tiles")
        above = []
        for g, m, x, y in hits:
            ab, av = tile(maps[(g, m)], x, y - 1)
            if av is not None and (av >> 10) & 3 == 0 and ab not in wanted:
                above.append(f"{g}.{m} {x},{y - 1} (behaviour {ab}, elevation {av >> 12})")
        print(f"  walkable tiles directly above one: {len(above)}")
        for a in above[:8]:
            print("    warp " + a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
