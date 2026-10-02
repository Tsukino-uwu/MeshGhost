using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // A route to a tile over the game's own collision grid (byte 1 solid, 255 a platform stood on from above and jumped
    // up through, 2-254 slopes), walked as a player moves: steps, falls and jumps held for the height they need,
    // cheapest by frames. A standing tile needs the tile above it open too. Carried out a frame at a time, planned
    // again every Replan frames or off the route, quickdropping over a landing to spend little time in the air. Every
    // move goes through the fight's dodge unless `dodge` is false; `stop_on_damage` ends at the first hit.
    public static class Navigate
    {
        private const int UpCost = 20; // a row of a jump's rise, above two steps (9 each): walk higher before jumping
        // a full jump carries about 5 tiles across (46 frames at 6.33)
        private const int JumpRows = 3, JumpCols = 5, FallRows = 24, Replan = 20, Margin = 60, MaxNodes = 20000;
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
        // solid, platform or slope under her
        private static bool Floor(int x, int y) { byte b = At(x, y); return b != 0; }

        // A tile she can stand in: open (or a slope's tile), something under it, and room for her body above.
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
            // Each row of rise is priced above two steps (UpCost), so the route walks as high as it can first and jumps
            // from the spot that leaves the least to climb.
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
                        // Climbing and crossing far in one jump leaves little time above the target's floor: priced up.
                        yield return new Edge { To = Key(tx, ty), Cost = 30 + 9 * across + UpCost * up + 12 * up * Math.Max(0, across - 2), Kind = 2, Rows = up };
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
        private static float StandY(int ty) => -(ty - 1) * 56f; // her position standing in tile ty

        // How long Jump is held: by the rows to rise, and a full hold for a long way across.
        private static int HoldFor(int rows, int across) => across >= 3 ? 24 : rows <= 0 ? 8 : rows == 1 ? 12 : rows == 2 ? 16 : 24;

        private static bool EnemyBelow(CharacterBase p)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null) return false;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == p || c.t == null || !c.gameObject.activeInHierarchy || c.health <= 0 || c.maxhealth >= 99999) continue;
                float dx = c.t.position.x - p.t.position.x, dy = c.t.position.y - p.t.position.y;
                if (Mathf.Abs(dx) < 60f && dy < -20f && dy > -250f) return true;
            }
            return false;
        }

        private static CharacterBase EnemyAhead(CharacterBase p, int sign)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null) return null;
            CharacterBase best = null;
            float bestDx = float.MaxValue;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == p || c.t == null || !c.gameObject.activeInHierarchy || c.health <= 0 || c.maxhealth >= 99999) continue;
                if (c.isBoss.ToString() != "NONE") continue;
                float dx = (c.t.position.x - p.t.position.x) * sign, dy = c.t.position.y - p.t.position.y;
                if (dx < 30f || dx > 180f || Mathf.Abs(dy) > 60f) continue;
                if (dx < bestDx) { bestDx = dx; best = c; }
            }
            return best;
        }

        private static CharacterBase OrbAhead(CharacterBase p, int sign)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null) return null;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c.t == null || !c.gameObject.activeInHierarchy || c.type.ToString() != "EnergyBall") continue;
                float dx = (c.t.position.x - p.t.position.x) * sign, dy = c.t.position.y - p.t.position.y;
                if (dx < 60f || dx > 450f || Mathf.Abs(dy) > 50f) continue;
                if (c.phy_perfer != null && c.phy_perfer._velocity.magnitude / 60f > 3f) continue; // already flying
                return c;
            }
            return null;
        }

        private static void Quickdrop()
        {
            InputInjection.Quickdrop();
        }

        // {x, y} in world units, or {tile_x, tile_y}. Ends `arrived`, `no_route`, `stuck` (no progress for 120 frames),
        // `mode_changed`, `damage_taken` (the caller decides) or `timeout`.
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
            // tiles of route left from the best point reached: progress is along the route, not straight at the goal
            int bestLeft = int.MaxValue;
            List<int> path = null;
            int step = 0, jumpFrom = -1, jumpRows = 0, jumpTarget = -1, hits = 0, dodges = 0, lastHp = me.health;
            bool steerEarly = false;
            int lastStomp = -1000;
            // frames standing over a planned fall that does not happen: a duct cover the grid does not show
            int overDropSince = -1;
            bool dodge = (bool?)args["dodge"] ?? true, stopOnDamage = (bool?)args["stop_on_damage"] ?? false;
            // the route times its own quickdrops; step in only for a close hit
            var guard = new Reflexes.Guard(me) { PreferDrop = false, Imminent = 14 };
            float groundY = me.t.position.y;

            // The route's move through the dodge this frame: true when the dodge took and carried out another plan.
            bool Vetoed(CharacterBase p, Dodge.Move want)
            {
                if (!dodge) return false;
                Dodge.Move move = guard.Check(p, want, groundY);
                if (move == want) return false;
                dodges++;
                guard.Execute(move, p.onGround());
                return true;
            }
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
                    ["hits_taken"] = hits,
                    ["dodges"] = dodges,
                    ["last_dodge"] = guard.LastDodge,
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
                if (p.health < lastHp)
                {
                    hits++;
                    if (stopOnDamage) return Done("damage_taken");
                }
                lastHp = p.health;
                if (Time.frameCount - start >= frameLimit) return Done("timeout");
                Load();
                Vector3 pos = p.t.position;
                bool onGround = p.onGround();
                if (onGround) groundY = pos.y;
                if (Time.frameCount - lastProgressFrame > 120) return Done("stuck", new JObject { ["at"] = new JArray(Math.Round(pos.x), Math.Round(pos.y)) });

                if (onGround && !Here(p, out int _, out int _))
                {
                    // On ground the grid shows open (a duct cover, say): hop and quickdrop through it.
                    if (overDropSince < 0) overDropSince = Time.frameCount;
                    if (Time.frameCount - overDropSince > 10)
                    {
                        if (!Vetoed(p, Dodge.Move.Hop) && InputInjection.Tap("Jump", 8)) jumps++;
                        overDropSince = Time.frameCount;
                    }
                    return null;
                }
                if (!onGround && overDropSince >= 0 && path == null && p.phy_perfer != null && p.phy_perfer._velocity.y <= 0f && p.logicStatus.ToString() != "QUICKDROP")
                {
                    if (!Vetoed(p, Dodge.Move.Drop)) Quickdrop();
                    return null;
                }
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

                // In the air over an enemy: quickdrop onto it once, contact cannot hurt her then, and steer on through
                // the bounce; stomping again keeps her hovering over it while it winds up.
                if (!onGround && Time.frameCount - lastStomp < 45)
                {
                    int away = gx * 56 + 28 > pos.x ? 1 : -1;
                    InputInjection.Keep(away > 0 ? "XAxis+" : "XAxis-");
                    return null;
                }
                if (!onGround && p.logicStatus.ToString() != "QUICKDROP" && EnemyBelow(p))
                {
                    Quickdrop();
                    lastStomp = Time.frameCount;
                    return null;
                }
                if (path == null) return null;
                // Forward first: safe plans ending nearest the route's next tile win; backing off is only for a hit.
                guard.StickX = CentreX(path[Math.Min(step + 1, path.Count - 1)] % maxX);
                if (step + 1 >= path.Count)
                {
                    Dodge.Move last = pos.x < CentreX(gx) ? Dodge.Move.Right : Dodge.Move.Left;
                    if (!Vetoed(p, last)) InputInjection.Keep(pos.x < CentreX(gx) ? "XAxis+" : "XAxis-");
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
                    bool steer = (steerEarly || pos.y > StandY(ty) - 20f || jumpRows <= 0) && Mathf.Abs(dxT) > 6f;
                    bool drop = !onGround && Mathf.Abs(dxT) < 18f && pos.y > StandY(ty) + 24f && p.logicStatus.ToString() != "QUICKDROP";
                    Dodge.Move airWant = drop ? Dodge.Move.Drop : steer ? (dxT > 0 ? Dodge.Move.Right : Dodge.Move.Left) : Dodge.Move.Stay;
                    if (Vetoed(p, airWant)) return null;
                    if (steer) InputInjection.Keep(dxT > 0 ? "XAxis+" : "XAxis-");
                    if (drop) Quickdrop();
                    if (onGround && Time.frameCount - lastPlan > 6 && p.phy_perfer != null && Mathf.Abs(p.phy_perfer._velocity.y) < 1f) jumpFrom = -1;
                    return null;
                }

                // A one-tile step onto or off a slope is walked (stairs are slopes); a jump is a rise or a gap.
                bool stairs = Math.Abs(nx - cx) == 1 && ny == cy - 1 && (Slope(nx, ny) || Slope(nx, ny + 1) || Slope(cx, cy) || Slope(cx, cy + 1));
                bool isJump = (ny < cy && !stairs) || Math.Abs(nx - cx) > 1;
                bool isFall = !isJump && ny > cy + 1;
                if (isJump && onGround)
                {
                    float aim = CentreX(cx) - pos.x;
                    if (Mathf.Abs(aim) > JumpAim)
                    {
                        if (!Vetoed(p, aim > 0 ? Dodge.Move.Right : Dodge.Move.Left)) InputInjection.Keep(aim > 0 ? "XAxis+" : "XAxis-");
                        return null;
                    }
                    if (Vetoed(p, nx > cx ? Dodge.Move.JumpRight : nx < cx ? Dodge.Move.JumpLeft : Dodge.Move.Jump)) return null;
                    int rows = cy - ny;
                    if (InputInjection.Tap("Jump", HoldFor(rows, Math.Abs(nx - cx))))
                    {
                        jumps++;
                        jumpFrom = cur;
                        jumpRows = rows;
                        jumpTarget = next;
                        // Steer from take-off when every tile up to the target's row is open: no corner to catch.
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
                // Standing over the drop and not falling: something the grid does not hold covers it (a ventilation
                // duct, which a quickdrop breaks). Hop and quickdrop onto it.
                if (isFall && onGround && Mathf.Abs(pos.x - CentreX(nx)) < 30f)
                {
                    if (overDropSince < 0) overDropSince = Time.frameCount;
                    if (Time.frameCount - overDropSince > 10)
                    {
                        if (!Vetoed(p, Dodge.Move.Hop) && InputInjection.Tap("Jump", 8)) jumps++;
                        overDropSince = Time.frameCount;
                    }
                }
                else if (onGround) overDropSince = -1;
                if (!onGround && overDropSince >= 0 && p.phy_perfer != null && p.phy_perfer._velocity.y <= 0f && p.logicStatus.ToString() != "QUICKDROP")
                {
                    if (!Vetoed(p, Dodge.Move.Drop)) Quickdrop();
                    return null;
                }
                if (isFall && !onGround && Mathf.Abs(toward) < 18f && p.logicStatus.ToString() != "QUICKDROP")
                {
                    if (!Vetoed(p, Dodge.Move.Drop)) Quickdrop();
                    return null;
                }
                bool move = Mathf.Abs(toward) > 4f || isFall;
                int sign = (isFall ? nx - cx : (int)Mathf.Sign(toward));
                // A blastorb resting on the way is jumped at a run, never shot: a shot orb can land back in her path.
                if (onGround && sign != 0)
                {
                    // Any body on her level in the way is hurdled the same way: a normal enemy cannot keep up after.
                    CharacterBase orb = OrbAhead(p, sign) ?? EnemyAhead(p, sign);
                    if (orb != null && Mathf.Abs(orb.t.position.x - pos.x) < 180f)
                    {
                        // A running jump at the first standing tile two or more past the orb, steered all the way.
                        Surroundings.Tile(orb.t.position, out int ox, out int oy);
                        int land = -1;
                        for (int k = 2; k <= JumpCols + 1 && land < 0; k++)
                        {
                            for (int r = -1; r <= 1 && land < 0; r++) if (Stand(ox + sign * k, cy + r)) land = Key(ox + sign * k, cy + r);
                        }
                        if (land >= 0 && InputInjection.Tap("Jump", 24))
                        {
                            jumps++;
                            jumpFrom = cur;
                            jumpTarget = land;
                            jumpRows = 0;
                            steerEarly = true;
                            lastPlan = Time.frameCount;
                            InputInjection.Keep(sign > 0 ? "XAxis+" : "XAxis-");
                            return null;
                        }
                    }
                }
                Dodge.Move groundWant = !move ? Dodge.Move.Stay : sign > 0 ? Dodge.Move.Right : Dodge.Move.Left;
                if (Vetoed(p, groundWant)) return null;
                if (move) InputInjection.Keep(sign > 0 ? "XAxis+" : "XAxis-");
                return null;
            };
        }
    }
}
