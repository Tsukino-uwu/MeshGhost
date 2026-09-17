using System;
using System.Collections.Generic;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // DODGE: whether what a reflex means to do next is safe, and what to do instead. The user, 2026-09-17: boss fights "preferably"
    // without taking any damage -- "damage/hitless boss fights, means we have a good way to handle combat and are doing things
    // properly" (a goal, not a requirement), and harder difficulties bring more moves and more projectiles, so nothing here knows a
    // particular enemy: it reads every box that can hurt the player (Threats.cs), moves each on by its measured velocity and
    // acceleration, and tries a few plans a player has -- stand, run either way, a hop or a full jump either way, steering while in
    // the air -- over the next Horizon frames, against the player's own hurtbox.
    //
    // The player's motion, measured on the Steam build (adapters/tevi/MEASURED.md, "Jump arcs by hold, and the hurtbox"): running
    // 6.33 units a frame; a jump's rise per frame from the ground in HoldRise (Jump held) and TapRise (Jump let go after 3 frames);
    // falling gains about 0.78 a frame each frame up to 15. The arcs are from flat ground with nothing overhead: a ceiling or a
    // ledge is not modelled, so a plan through one is wrong in the way that matters least (it is only chosen when it looks safe).
    // Walls are: a run stops at the first solid tile (byte 1 of the game's collision grid) either side of her on the rows her body
    // is in (Start.MinX, MaxX), found cornered against one on 2026-09-17 while every plan still ran through it.
    //
    // In the air a quickdrop (down held, Jump pressed) is a plan too: the frame after the press she falls 22.5 units a frame, straight,
    // until she lands (measured 2026-09-17). The user: "don't forget that you can use quickdrop to get back to the ground quickly, to be
    // able to jump/dodge new things".
    public static class Dodge
    {
        public const int Horizon = 45;

        // A threat can change speed (Ribauld's charge went from 6 to 18 units a frame as he landed, 2026-09-17), so a plan that only
        // just misses is not taken when another keeps room: the wanted plan needs WantedClearance over the first ClearanceFrames, and
        // among safe plans the one with most room wins.
        private const int ClearanceFrames = 20;
        private const float WantedClearance = 30f, ClearanceCap = 300f, RoomCap = 200f;
        private const float Run = 6.33f, Gravity = 0.78f, MaxFall = 15f, Margin = 6f, QuickdropFall = 22.5f;
        public const int JumpHold = 24, HopHold = 3;

        // Height above the take-off point on each frame after the press begins, Jump held 24 frames and 3 frames (MEASURED.md).
        private static readonly float[] HoldRise = { 16.9f, 32.9f, 48.2f, 62.8f, 76.5f, 89.5f, 101.7f, 113.1f, 123.7f, 133.6f, 142.7f, 151.0f, 158.5f, 165.3f, 171.2f, 176.4f, 180.8f, 184.5f, 187.3f, 189.4f, 190.7f, 191.3f, 191.0f, 190.0f, 188.2f, 185.6f, 182.2f, 178.1f, 173.2f, 167.5f, 161.0f, 153.8f, 145.7f, 136.9f, 127.4f, 117.0f, 105.9f, 93.9f, 81.2f, 67.8f, 53.5f, 38.5f, 23.5f, 8.5f };
        private static readonly float[] TapRise = { 16.9f, 32.9f, 48.2f, 60.4f, 69.8f, 77.0f, 82.3f, 86.0f, 88.3f, 89.5f, 89.7f, 89.2f, 87.8f, 85.7f, 82.7f, 79.0f, 74.6f, 69.3f, 63.3f, 56.5f, 48.9f, 40.5f, 31.4f, 21.4f, 10.7f };

        // HopDropLeft/Right: a hop, then a quickdrop from its HopDropAt-th frame, so contact cannot hurt her from then on: the way past an
        // enemy's body on the ground (normal enemies are run past, the user, 2026-09-17; the Quickdrop tutorial: contact during it does no
        // damage). Carried out as a hop; in the air the Drop plans take over.
        public enum Move { Stay, Left, Right, Hop, HopLeft, HopRight, Jump, JumpLeft, JumpRight, Drop, DropLeft, DropRight, HopDropLeft, HopDropRight }
        public const int HopDropAt = 10;

        public struct Plan
        {
            public Move Move;
            public int FirstHit; // the first frame ahead its path meets a threat; Horizon + 1 for none
            public int HitFrames; // how many frames of the horizon it is inside one
            public float Clearance; // the smallest gap to any threat over the first ClearanceFrames, at most ClearanceCap
            public float Room; // how far from the nearer wall the plan ends, at most RoomCap
            public float EndX; // where the plan has her after ClearanceFrames
            public string HitBy;
        }

        // Threats remembered between frames for their acceleration.
        private static readonly Dictionary<int, Vector2> LastVelocity = new Dictionary<int, Vector2>();

        public static bool IsJump(Move m) => (m >= Move.Hop && m <= Move.JumpRight) || m >= Move.HopDropLeft;
        public static bool IsDrop(Move m) => m >= Move.Drop && m <= Move.DropRight;
        public static bool IsHopDrop(Move m) => m >= Move.HopDropLeft;

        public static int Dir(Move m)
        {
            switch (m)
            {
                case Move.Left: case Move.HopLeft: case Move.JumpLeft: case Move.DropLeft: case Move.HopDropLeft: return -1;
                case Move.Right: case Move.HopRight: case Move.JumpRight: case Move.DropRight: case Move.HopDropRight: return 1;
                default: return 0;
            }
        }

        // The state a plan starts from: where the player is, whether on the ground, the vertical speed this frame, whether a jump
        // press is still held and for how many more frames, and the ground to land on.
        public struct Start
        {
            public Vector2 Pos;
            public bool OnGround;
            public float Vy;
            public int HoldLeft;
            public float GroundY;
            public Rect Hurt; // at Pos
            public float MinX, MaxX; // how far a run can take her before a wall
            public float Floor; // the bottom of her hurtbox standing on the ground she last stood on: a falling box stops there
            public bool Quickdropping; // already in a quickdrop: falling QuickdropFall a frame to the ground
        }

        // The x range a run is free in from `pos`: the first solid tile left and right on her own tile row and the row above,
        // as far as 20 tiles, less half her width.
        public static void WallLimits(Vector3 pos, float halfWidth, out float minX, out float maxX)
        {
            minX = float.MinValue;
            maxX = float.MaxValue;
            // In a boss fight the camera is the arena: the player stopped 15.5 inside each edge of the view in Ribauld's (view 22266.5 to
            // 23545.5, stops at 22282 and 23530; 2026-09-17), where no tile is solid.
            if (EventManager.Instance != null && EventManager.Instance.isBossMode() && CameraScript.Instance != null)
            {
                minX = CameraScript.Instance.GetEdgeLeft() + 15.5f;
                maxX = CameraScript.Instance.GetEdgeRight() - 15.5f;
            }
            WorldManager wm = WorldManager.Instance;
            if (wm == null || wm.areadata == null || wm.areadata.hitbox == null || MainVar.instance == null) return;
            int maxTx = MainVar.instance.MaxTileX, maxTy = MainVar.instance.MaxTileY;
            float size = MainVar.instance.TILESIZE;
            Surroundings.Tile(pos, out int tx, out int ty);
            bool Solid(int x, int y)
            {
                if (x < 0 || x >= maxTx || y < 0 || y >= maxTy) return true;
                if (wm.tileDestroyed != null && wm.tileDestroyed[x, y]) return false;
                return wm.areadata.hitbox[x + y * maxTx] == 1;
            }
            for (int d = 1; d <= 20; d++)
            {
                if (Solid(tx + d, ty) || Solid(tx + d, ty - 1))
                {
                    maxX = Math.Min(maxX, (tx + d) * size - halfWidth);
                    break;
                }
            }
            for (int d = 1; d <= 20; d++)
            {
                if (Solid(tx - d, ty) || Solid(tx - d, ty - 1))
                {
                    minX = Math.Max(minX, (tx - d + 1) * size + halfWidth);
                    break;
                }
            }
        }

        // Every plan the player can take from `s`, each with its first hit. On the ground all nine; in the air only the three
        // steering plans (a jump cannot start in the air).
        public static List<Plan> Evaluate(Start s, List<Threats.Threat> threats, List<Threats.Laser> lasers)
        {
            var accel = new Dictionary<int, Vector2>();
            foreach (Threats.Threat t in threats)
            {
                Vector2 a = Vector2.zero;
                if (t.Velocity != Vector2.zero && LastVelocity.TryGetValue(t.Slot, out Vector2 lv) && lv != Vector2.zero)
                {
                    a = t.Velocity - lv;
                    a.x = Mathf.Clamp(a.x, -2f, 2f);
                    a.y = Mathf.Clamp(a.y, -2f, 2f);
                }
                accel[t.Slot] = a;
                LastVelocity[t.Slot] = t.Velocity;
            }
            var plans = new List<Plan>();
            foreach (Move m in (Move[])Enum.GetValues(typeof(Move)))
            {
                if (!s.OnGround && IsJump(m)) continue;
                if (IsDrop(m) && (s.OnGround || s.Quickdropping)) continue;
                int hit = Horizon + 1, frames = 0;
                float clearance = ClearanceCap;
                string by = null;
                for (int f = 1; f <= Horizon; f++)
                {
                    Vector2 p = Position(s, m, f);
                    Rect me = new Rect(s.Hurt.x + (p.x - s.Pos.x) - Margin, s.Hurt.y + (p.y - s.Pos.y) - Margin, s.Hurt.width + 2 * Margin, s.Hurt.height + 2 * Margin);
                    string inside = null;
                    // Contact during a quickdrop does no damage (the game's Quickdrop tutorial; the user, 2026-09-17: quickdrop on an enemy
                    // "to deal some damage/gain some iframes"): a contact box is not a threat to a quickdrop plan once it has begun.
                    bool dropping = s.Quickdropping || (IsDrop(m) && f >= 2) || (IsHopDrop(m) && f >= HopDropAt + 1);
                    foreach (Threats.Threat t in threats)
                    {
                        if (dropping && t.Type == "ENEMY_HURTBOX") continue;
                        if (f < t.AppearIn) continue;
                        Vector2 a = accel.TryGetValue(t.Slot, out Vector2 acc) ? acc : Vector2.zero;
                        int since = f - t.AppearIn;
                        Vector2 d = t.Velocity * since + 0.5f * a * since * since;
                        if (t.Homing)
                        {
                            // It follows her: at its speed, straight at where this plan puts her, frame by frame.
                            Vector2 at = t.Box.center, speed = new Vector2(t.Velocity.magnitude, 0f);
                            for (int k = 1; k <= f; k++)
                            {
                                Vector2 target = Position(s, m, k) + (s.Hurt.center - s.Pos);
                                Vector2 step = target - at;
                                at += step.magnitude <= speed.x ? step : step.normalized * speed.x;
                            }
                            d = at - t.Box.center;
                        }
                        float cx = Mathf.Clamp(t.Box.center.x + d.x, t.MinCx, t.MaxCx);
                        d.x = cx - t.Box.center.x;
                        // A box coming down lands and rolls on (BULLET_RIBAULD_SLOWDOWN, 2026-09-17), never falls through the floor.
                        if (d.y < 0f && t.Box.yMin + d.y < s.Floor) d.y = Math.Min(0f, s.Floor - t.Box.yMin);
                        var moved = new Rect(t.Box.x + d.x, t.Box.y + d.y, t.Box.width, t.Box.height);
                        if (f <= ClearanceFrames) clearance = Math.Min(clearance, Gap(moved, me));
                        if (moved.Overlaps(me))
                        {
                            inside = t.Type;
                            break;
                        }
                    }
                    if (inside == null)
                    {
                        float reach = Math.Max(me.width, me.height) / 2f;
                        foreach (Threats.Laser l in lasers)
                        {
                            float away = Threats.DistanceToSegment(me.center, l.From, l.To) - l.Radius - reach;
                            if (f <= ClearanceFrames) clearance = Math.Min(clearance, Math.Max(0f, away));
                            if (away < 0f)
                            {
                                inside = l.Type;
                                break;
                            }
                        }
                    }
                    if (inside == null) continue;
                    frames++;
                    if (hit > Horizon)
                    {
                        hit = f;
                        by = inside;
                    }
                }
                // Room from the walls where the plan ends: a corner leaves no way out of the next attack (pinned twice, 2026-09-17).
                Vector2 end = Position(s, m, Horizon);
                float room = Math.Min(RoomCap, Math.Min(end.x - s.MinX, s.MaxX - end.x));
                plans.Add(new Plan { Move = m, FirstHit = hit, HitFrames = frames, HitBy = by, Clearance = clearance, Room = room, EndX = Position(s, m, ClearanceFrames).x });
            }
            return plans;
        }

        private static float Gap(Rect a, Rect b)
        {
            float dx = Math.Max(0f, Math.Max(a.xMin - b.xMax, b.xMin - a.xMax));
            float dy = Math.Max(0f, Math.Max(a.yMin - b.yMax, b.yMin - a.yMax));
            return Mathf.Sqrt(dx * dx + dy * dy);
        }

        // Where the player is `f` frames on under plan `m`.
        public static Vector2 Position(Start s, Move m, int f)
        {
            float x = Mathf.Clamp(s.Pos.x + Dir(m) * Run * f, Math.Min(s.MinX, s.Pos.x), Math.Max(s.MaxX, s.Pos.x));
            float y;
            if (s.OnGround)
            {
                if (IsHopDrop(m)) y = s.Pos.y + (f <= HopDropAt ? TapRise[f - 1] : Math.Max(0f, TapRise[HopDropAt - 1] - QuickdropFall * (f - HopDropAt)));
                else if (m == Move.Hop || m == Move.HopLeft || m == Move.HopRight) y = s.Pos.y + (f <= TapRise.Length ? TapRise[f - 1] : 0f);
                else if (IsJump(m)) y = s.Pos.y + (f <= HoldRise.Length ? HoldRise[f - 1] : 0f);
                else y = s.Pos.y;
                return new Vector2(x, y);
            }
            // In the air: rising while held slows by gravity; let go it slows faster (the tap arc's ratio); falling speeds up to MaxFall.
            float vy = s.Vy;
            y = s.Pos.y;
            int hold = s.HoldLeft;
            for (int i = 0; i < f; i++)
            {
                if (s.Quickdropping || (IsDrop(m) && i >= 1)) vy = -QuickdropFall;
                else if (vy > 0f && hold <= 0) vy = vy * 0.77f - 0.2f;
                else vy = Math.Max(vy - Gravity, -MaxFall);
                hold--;
                y += vy;
                if (y <= s.GroundY)
                {
                    y = s.GroundY;
                    vy = 0f;
                }
            }
            return new Vector2(x, y);
        }

        // The plan to take: `want` when nothing meets it within the horizon; otherwise the safe plan nearest to it (same direction
        // first, then standing, then the fewest frames in the air); and when every plan is hit, the one hit latest, then the one inside
        // a threat for the fewest frames (out of a laser's beam soonest).
        // With `stickX` (a fight's target), a safe plan that ends nearer it wins over one with more room, and the wanted plan needs only
        // StickClearance. The user, 2026-09-17: "try to hugg and be close to the boss as much as possible and melee it, whenever its
        // safe to do so", "prefer sticking onto the boss, rather than staying far away or playing it super safe".
        private const float StickClearance = 10f;

        // `imminent`: when given, the wanted plan stands unless it is hit within that many frames (movement: the user, 2026-09-17, "just
        // keep running, don't pause/quickdrop randomly"); a fight leaves it out and wants the whole horizon clear.
        public static Plan Choose(List<Plan> plans, Move want, float? stickX = null, int? imminent = null)
        {
            Plan wanted = plans.Find(p => p.Move == want);
            float needed = stickX.HasValue ? StickClearance : WantedClearance;
            if (plans.Exists(p => p.Move == want))
            {
                if (imminent.HasValue ? wanted.FirstHit > imminent.Value : wanted.FirstHit > Horizon && wanted.Clearance >= needed) return wanted;
            }
            Plan best = default(Plan);
            int bestScore = int.MinValue;
            foreach (Plan p in plans)
            {
                // Hit either way: later is worth most (time to plan again: a roll hit in 3 frames was taken over one in 32, 2026-09-17),
                // then fewest frames inside (out of a laser's beam, where every plan is hit at once).
                int score = (p.FirstHit > Horizon ? 100000 : 0) + p.FirstHit * 1000 - p.HitFrames * 300 + (int)(Math.Max(0f, p.Room) * 2f);
                if (stickX.HasValue) score += (int)(Math.Max(0f, 400f - Mathf.Abs(p.EndX - stickX.Value)) * 3f) + (int)Math.Min(p.Clearance, 40f);
                else score += (int)(p.Clearance * 2f);
                if (Dir(p.Move) == Dir(want)) score += 30;
                if (!IsJump(p.Move)) score += 20;
                else if (p.Move == Move.Hop || p.Move == Move.HopLeft || p.Move == Move.HopRight) score += 10;
                if (score > bestScore)
                {
                    bestScore = score;
                    best = p;
                }
            }
            return best;
        }
    }
}
