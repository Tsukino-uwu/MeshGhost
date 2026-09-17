using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // GOTO over TEVI's collision grid: a route to a tile, walked the way a player moves -- runs, jumps held for the height they need,
    // falls -- chosen from the game's own tiles (WorldManager.areadata.hitbox, TILESIZE 56, a tile x / 56 and -y / 56 + 1, as
    // Surroundings.Tile). Made after two hand-timed tries at a shaft of pass-through platforms failed (2026-09-17).
    //
    // What the grid's bytes mean, measured against a picture of the cell (MEASURED.md): 1 solid, 255 a platform stood on from above
    // and jumped up through, 2-254 slopes (walked). A standing tile is an open tile over a solid tile, a platform or a slope; the tile
    // above it must be open too for her to pass (a low ceiling cut a jump to 48 units, 2026-09-17).
    //
    // Links between standing tiles: a step to either side, level or a slope's tile up or down; a fall off an edge to the first standing
    // tile below within FallRows; a jump up to JumpRows rows and across to JumpCols columns, when every tile the arc passes (straight up
    // from the take-off tile to the target row plus one, then across at that row) is open, platforms counting as open. The route is the
    // cheapest by frames: a step 9, a fall 12 plus 3 a row, a jump 30 plus 9 a column.
    //
    // Carrying it out, a frame at a time: toward the next tile's centre; for a jump, from within JumpAim of the take-off tile's centre,
    // Jump held HoldFor(rows) frames (measured rises: 12 frames rise about 144, 24 about 191, MEASURED.md), steering toward the target
    // only once she is above its floor; planned again from where she stands every Replan frames or when she is off the route. As little
    // time in the air as possible (the user, 2026-09-17: "try to land asap whenever possible and keep moving"): over a jump's landing
    // tile and above its floor, or over the column a fall drops down, she quickdrops (22.5 units a frame, straight down).
    public static class Navigate
    {
        private const int JumpRows = 3, JumpCols = 5, FallRows = 24, Replan = 20, Margin = 60, MaxNodes = 20000; // a full jump carries about 5 tiles across (46 frames at 6.33)
        private const float JumpAim = 14f, Run = 6.33f;

        private static byte[] grid;
        private static int maxX, maxY;
        private static bool[,] destroyed;

        private static bool Load()
        {
            WorldManager wm = WorldManager.Instance;
            if (wm == null || wm.areadata == null || wm.areadata.hitbox == null || MainVar.instance == null) return false;
            grid = wm.areadata.hitbox;
            maxX = MainVar.instance.MaxTileX;
            maxY = MainVar.instance.MaxTileY;
            destroyed = wm.tileDestroyed;
            return true;
        }

        private static byte At(int x, int y)
        {
            if (x < 0 || y < 0 || x >= maxX || y >= maxY) return 1;
            if (destroyed != null && destroyed[x, y]) return 0;
            return grid[x + y * maxX];
        }

        private static bool Open(int x, int y) => At(x, y) == 0 || At(x, y) == 255;
        private static bool Slope(int x, int y) { byte b = At(x, y); return b >= 2 && b <= 254; }
        private static bool Floor(int x, int y) { byte b = At(x, y); return b != 0; } // solid, platform or slope under her

        // A tile she can stand in: open (or a slope's tile, which she walks inside), something under it, and room for her body above.
        private static bool Stand(int x, int y)
        {
            bool here = At(x, y) == 0 || Slope(x, y);
            return here && Floor(x, y + 1) && (Open(x, y - 1) || Slope(x, y - 1));
        }

        private struct Edge
        {
            public int To;
            public int Cost;
            public int Kind; // 0 step, 1 fall, 2 jump
            public int Rows;
        }

        private static int Key(int x, int y) => x + y * maxX;

        private static IEnumerable<Edge> Edges(int x, int y)
        {
            for (int d = -1; d <= 1; d += 2)
            {
                int nx = x + d;
                for (int dy = -1; dy <= 1; dy++)
                {
                    if (Stand(nx, y + dy) && (dy >= 0 || Open(x, y - 1)))
                    {
                        yield return new Edge { To = Key(nx, y + dy), Cost = 9, Kind = 0 };
                        goto nextSide;
                    }
                }
                // Off the edge: the column beside falls to the first standing tile.
                if (Open(nx, y) && !Floor(nx, y + 1))
                {
                    for (int r = 1; r <= FallRows; r++)
                    {
                        if (!Open(nx, y + r) && !Slope(nx, y + r)) break;
                        if (Stand(nx, y + r))
                        {
                            yield return new Edge { To = Key(nx, y + r), Cost = 12 + 3 * r, Kind = 1, Rows = r };
                            break;
                        }
                    }
                }
            nextSide:;
            }
            // Jumps: up 0..JumpRows rows, across 0..JumpCols columns (0 across only when going up, through a platform).
            for (int up = 0; up <= JumpRows; up++)
            {
                // straight up from the take-off tile, one row above the target row for her head
                bool clear = true;
                for (int r = 1; r <= up + 1 && clear; r++) clear = Open(x, y - r);
                if (!clear) break;
                for (int d = -1; d <= 1; d += 2)
                {
                    for (int across = up == 0 ? 2 : 0; across <= JumpCols; across++)
                    {
                        if (across == 0 && d > 0) continue;
                        int tx = x + d * across, ty = y - up;
                        bool path = true;
                        for (int c = 1; c <= across && path; c++) path = Open(x + d * c, ty - 1) && Open(x + d * c, ty);
                        if (!path) break;
                        if (!Stand(tx, ty) || (across <= 1 && up == 0)) continue;
                        // Climbing and crossing far in one jump leaves little time above the target's floor: priced up (a 2-up, 5-across
                        // jump fell short into a shaft, 2026-09-17, where climbing one more platform and crossing level would do).
                        yield return new Edge { To = Key(tx, ty), Cost = 30 + 9 * across + 4 * up + 12 * up * Math.Max(0, across - 2), Kind = 2, Rows = up };
                    }
                }
            }
        }

        private static List<int> Route(int sx, int sy, int gx, int gy, out int explored)
        {
            explored = 0;
            int start = Key(sx, sy), goal = Key(gx, gy);
            var dist = new Dictionary<int, int> { [start] = 0 };
            var prev = new Dictionary<int, int>();
            var open = new SortedSet<(int, int)> { (0, start) };
            int minX = Math.Min(sx, gx) - Margin, maxXb = Math.Max(sx, gx) + Margin, minY = Math.Min(sy, gy) - Margin, maxYb = Math.Max(sy, gy) + Margin;
            while (open.Count > 0 && explored < MaxNodes)
            {
                var first = open.Min;
                open.Remove(first);
                int k = first.Item2;
                if (first.Item1 > dist[k]) continue;
                explored++;
                if (k == goal) break;
                int x = k % maxX, y = k / maxX;
                foreach (Edge e in Edges(x, y))
                {
                    int ex = e.To % maxX, ey = e.To / maxX;
                    if (ex < minX || ex > maxXb || ey < minY || ey > maxYb) continue;
                    int nd = dist[k] + e.Cost;
                    if (!dist.TryGetValue(e.To, out int old) || nd < old)
                    {
                        dist[e.To] = nd;
                        prev[e.To] = k;
                        open.Add((nd, e.To));
                    }
                }
            }
            if (!dist.ContainsKey(goal)) return null;
            var path = new List<int>();
            for (int k = goal; ; k = prev[k])
            {
                path.Add(k);
                if (k == start) break;
            }
            path.Reverse();
            return path;
        }

        // The standing tile under her: her position's tile, or the one below while she is just above a floor.
        private static bool Here(CharacterBase p, out int tx, out int ty)
        {
            Surroundings.Tile(p.t.position, out tx, out ty);
            if (Stand(tx, ty)) return true;
            if (Stand(tx, ty + 1)) { ty++; return true; }
            return false;
        }

        private static float CentreX(int tx) => tx * 56f + 28f;
        private static float StandY(int ty) => -(ty - 1) * 56f; // her position standing in tile ty (the cell measured y -9072 for row 163)

        // How long Jump is held: by the rows to rise, and a full hold for a long way across (a 6-frame hop meant for a level 5-tile gap fell
        // short into the shaft below, 2026-09-17).
        private static int HoldFor(int rows, int across) => across >= 3 ? 24 : rows <= 0 ? 8 : rows == 1 ? 12 : rows == 2 ? 16 : 24;

        private static void Quickdrop()
        {
            InputInjection.Keep("YAxis-");
            InputInjection.Tap("Jump", 4);
        }

        // GOTO {x, y}: world units, as observe's location reads them; or {tile_x, tile_y}. Ends `arrived`, `no_route`, `stuck` (no
        // progress for 120 frames), `mode_changed`, `damage_taken` (hp dropped: the caller decides), or `timeout`.
        public static Func<JToken> Goto(JObject args, int frameLimit, Func<CharacterBase> player, Func<string> mode, Func<bool, JObject> observe)
        {
            if (!Load()) throw new Exception("no area grid loaded");
            CharacterBase me = player();
            if (me == null || me.t == null) throw new Exception("no player");
            if (mode() != "play") throw new Exception("goto starts in play, not in " + mode());
            int gx, gy;
            if (args["tile_x"] != null && args["tile_y"] != null)
            {
                gx = (int)args["tile_x"];
                gy = (int)args["tile_y"];
            }
            else if (args["x"] != null && args["y"] != null)
            {
                Surroundings.Tile(new Vector3((float)args["x"], (float)args["y"], 0f), out gx, out gy);
            }
            else throw new Exception("goto needs x and y (world) or tile_x and tile_y");
            if (!Stand(gx, gy) && Stand(gx, gy + 1)) gy++;
            if (!Stand(gx, gy)) throw new Exception("tile " + gx + "," + gy + " is not a place she can stand");

            int start = Time.frameCount, hpStart = me.health, lastPlan = -9999, lastProgressFrame = start, replans = 0, jumps = 0;
            int bestLeft = int.MaxValue; // tiles of route left from the best point reached: progress is along the route, not straight at the goal
            List<int> path = null;
            int step = 0, jumpFrom = -1, jumpRows = 0, jumpTarget = -1;
            bool steerEarly = false;
            var plannedFrom = new JArray();

            JObject Done(string outcome, JObject extra = null)
            {
                CharacterBase p = player();
                var o = new JObject
                {
                    ["outcome"] = outcome,
                    ["frames"] = Time.frameCount - start,
                    ["goal_tile"] = new JArray(gx, gy),
                    ["replans"] = replans,
                    ["jumps"] = jumps,
                    ["hp_start"] = hpStart,
                    ["hp_end"] = p != null ? (JToken)p.health : null,
                    ["route_len"] = path != null ? (JToken)path.Count : null,
                    ["after"] = observe(false),
                };
                if (extra != null) o.Merge(extra);
                return o;
            }

            return () =>
            {
                CharacterBase p = player();
                if (p == null || p.t == null) return Done("lost");
                if (mode() != "play") return Done("mode_changed");
                if (p.health < hpStart) return Done("damage_taken");
                if (Time.frameCount - start >= frameLimit) return Done("timeout");
                Load();
                Vector3 pos = p.t.position;
                bool onGround = p.onGround();
                if (Time.frameCount - lastProgressFrame > 120) return Done("stuck", new JObject { ["at"] = new JArray(Math.Round(pos.x), Math.Round(pos.y)) });

                if (onGround && Here(p, out int hx, out int hy))
                {
                    if (hx == gx && hy == gy && Mathf.Abs(pos.x - CentreX(gx)) < 20f) return Done("arrived");
                    int idx = path == null ? -1 : path.IndexOf(Key(hx, hy));
                    if (jumpFrom >= 0 && Key(hx, hy) != jumpFrom) jumpFrom = -1; // the jump landed somewhere
                    if (path == null || idx < 0 || Time.frameCount - lastPlan >= Replan && jumpFrom < 0)
                    {
                        path = Route(hx, hy, gx, gy, out int explored);
                        lastPlan = Time.frameCount;
                        replans++;
                        if (plannedFrom.Count < 30) plannedFrom.Add(new JArray(hx, hy, path?.Count ?? -1, explored));
                        if (path == null) return Done("no_route", new JObject { ["from_tile"] = new JArray(hx, hy), ["explored"] = explored, ["planned_from"] = plannedFrom });
                        idx = 0;
                    }
                    step = idx;
                    if (path.Count - step < bestLeft)
                    {
                        bestLeft = path.Count - step;
                        lastProgressFrame = Time.frameCount;
                    }
                }

                if (path == null) return null;
                if (step + 1 >= path.Count)
                {
                    InputInjection.Keep(pos.x < CentreX(gx) ? "XAxis+" : "XAxis-");
                    return null;
                }
                int cur = path[step], next = path[step + 1];
                int cx = cur % maxX, cy = cur / maxX, nx = next % maxX, ny = next / maxX;

                if (jumpFrom >= 0)
                {
                    // In a jump: steer toward the target once above its floor.
                    int tgt = jumpTarget;
                    int tx = tgt % maxX, ty = tgt / maxX;
                    float dxT = CentreX(tx) - pos.x;
                    if (steerEarly || pos.y > StandY(ty) - 20f || jumpRows <= 0)
                    {
                        if (Mathf.Abs(dxT) > 6f) InputInjection.Keep(dxT > 0 ? "XAxis+" : "XAxis-");
                    }
                    if (!onGround && Mathf.Abs(dxT) < 18f && pos.y > StandY(ty) + 24f && p.logicStatus.ToString() != "QUICKDROP") Quickdrop();
                    if (onGround && Time.frameCount - lastPlan > 6 && p.phy_perfer != null && Mathf.Abs(p.phy_perfer._velocity.y) < 1f) jumpFrom = -1;
                    return null;
                }

                bool isJump = ny < cy || Math.Abs(nx - cx) > 1;
                bool isFall = !isJump && ny > cy + 1;
                if (isJump && onGround)
                {
                    float aim = CentreX(cx) - pos.x;
                    if (Mathf.Abs(aim) > JumpAim)
                    {
                        InputInjection.Keep(aim > 0 ? "XAxis+" : "XAxis-");
                        return null;
                    }
                    int rows = cy - ny;
                    if (InputInjection.Tap("Jump", HoldFor(rows, Math.Abs(nx - cx))))
                    {
                        jumps++;
                        jumpFrom = cur;
                        jumpRows = rows;
                        jumpTarget = next;
                        // Steer from the take-off when every tile between, from her row up to the target's, is open: no corner to catch.
                        steerEarly = true;
                        int dir = Math.Sign(nx - cx);
                        for (int c = 1; c <= Math.Abs(nx - cx) && steerEarly; c++)
                        {
                            for (int r = ny; r <= cy && steerEarly; r++) steerEarly = Open(cx + dir * c, r) || (r == cy && Slope(cx + dir * c, r));
                        }
                        lastPlan = Time.frameCount; // keep the route through the jump
                    }
                    return null;
                }
                float toward = CentreX(nx) - pos.x;
                if (isFall && !onGround && Mathf.Abs(toward) < 18f && p.logicStatus.ToString() != "QUICKDROP")
                {
                    Quickdrop();
                    return null;
                }
                if (Mathf.Abs(toward) > 4f || isFall) InputInjection.Keep((isFall ? nx - cx : toward) > 0 ? "XAxis+" : "XAxis-");
                return null;
            };
        }
    }
}
