using System;
using System.Collections.Generic;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // Whether what a reflex means to do next is safe, and what to do instead. Nothing here knows a particular enemy:
    // every box that can hurt the player (Threats.cs) is moved on by its velocity and acceleration, and each plan a
    // player has -- stand, run, hop, jump, quickdrop in the air -- is tried over the next Horizon frames against her
    // hurtbox. The arcs are from flat ground: a ceiling or a ledge is not modelled, so a plan through one is wrong only
    // when it already looks safe. A run stops at the first solid tile either side of her body (Start.MinX, MaxX).
    public static class Dodge
    {
        public const int Horizon = 45;

        // A threat can change speed, so a plan that only just misses is not taken when another keeps room: the wanted
        // plan needs WantedClearance over the first ClearanceFrames, and among safe plans the one with most room wins.
        private const int ClearanceFrames = 20;
        private const float WantedClearance = 30f, ClearanceCap = 300f, RoomCap = 200f;
        private const float Run = 6.33f, Gravity = 0.78f, MaxFall = 15f, Margin = 6f, QuickdropFall = 22.5f;
        public const int JumpHold = 24, HopHold = 3;

        // Height above the take-off point on each frame after the press begins, Jump held 24 frames and 3 frames.
        private static readonly float[] HoldRise = { 16.9f, 32.9f, 48.2f, 62.8f, 76.5f, 89.5f, 101.7f, 113.1f, 123.7f, 133.6f, 142.7f, 151.0f, 158.5f, 165.3f, 171.2f, 176.4f, 180.8f, 184.5f, 187.3f, 189.4f, 190.7f, 191.3f, 191.0f, 190.0f, 188.2f, 185.6f, 182.2f, 178.1f, 173.2f, 167.5f, 161.0f, 153.8f, 145.7f, 136.9f, 127.4f, 117.0f, 105.9f, 93.9f, 81.2f, 67.8f, 53.5f, 38.5f, 23.5f, 8.5f };
        private static readonly float[] TapRise = { 16.9f, 32.9f, 48.2f, 60.4f, 69.8f, 77.0f, 82.3f, 86.0f, 88.3f, 89.5f, 89.7f, 89.2f, 87.8f, 85.7f, 82.7f, 79.0f, 74.6f, 69.3f, 63.3f, 56.5f, 48.9f, 40.5f, 31.4f, 21.4f, 10.7f };

        // HopDropLeft/Right: a hop, then a quickdrop from its HopDropAt-th frame, so contact cannot hurt her from then
        // on: the way past an enemy's body on the ground. Carried out as a hop; in the air the Drop plans take over.
        public enum Move { Stay, Left, Right, Hop, HopLeft, HopRight, Jump, JumpLeft, JumpRight, Drop, DropLeft, DropRight, HopDropLeft, HopDropRight }

        public const int HopDropAt = 10;
        // Down is held this many frames before Jump (together they make a double jump), so a drop begins that late.
        private const int DropDelay = 4;

        public struct Plan
        {
            public Move Move;
            public int FirstHit; // the first frame ahead its path meets a threat; Horizon + 1 for none
            public int HitFrames; // how many frames of the horizon it is inside one
            // the smallest gap to any threat over the first ClearanceFrames, at most ClearanceCap
            public float Clearance;
            public float Room; // how far from the nearer wall the plan ends, at most RoomCap
            public float EndX; // where the plan has her after ClearanceFrames
            public string HitBy;
        }

        // Threats remembered between frames for their acceleration.
        private static readonly Dictionary<int, Vector2> LastVelocity = new Dictionary<int, Vector2>();

        public static bool IsJump(Move m) => (m >= Move.Hop && m <= Move.JumpRight) || IsHopDrop(m);
        public static bool IsDrop(Move m) => m >= Move.Drop && m <= Move.DropRight;
        public static bool IsHopDrop(Move m) => m == Move.HopDropLeft || m == Move.HopDropRight;

        public static int Dir(Move m)
        {
            switch (m)
            {
                case Move.Left: case Move.HopLeft: case Move.JumpLeft: case Move.DropLeft: case Move.HopDropLeft: return -1;
                case Move.Right: case Move.HopRight: case Move.JumpRight: case Move.DropRight: case Move.HopDropRight: return 1;
                default: return 0;
            }
        }

        // The state a plan starts from: where the player is, whether on the ground, the vertical speed this frame,
        // whether a jump press is still held and for how many more frames, and the ground to land on.
        public struct Start
        {
            public Vector2 Pos;
            public bool OnGround;
            public float Vy;
            public int HoldLeft;
            public float GroundY;
            public Rect Hurt; // at Pos
            public float MinX, MaxX; // how far a run can take her before a wall
            // the bottom of her hurtbox standing on the ground she last stood on: a falling box stops there
            public float Floor;
            public bool Quickdropping; // already in a quickdrop: falling QuickdropFall a frame to the ground
        }

        // The x range a run is free in from `pos`: the first solid tile left and right on her own tile row and the row
        // above, as far as 20 tiles, less half her width.
        public static void WallLimits(Vector3 pos, float halfWidth, out float minX, out float maxX)
        {
            minX = float.MinValue;
            maxX = float.MaxValue;
            // In a boss fight the camera is the arena: she stops 15.5 inside each edge, where no tile is solid.
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

        // Every plan she can take from `s`, each with its first hit: on the ground all but the drops; in the air the
        // three steering plans (a jump cannot start there) and the drops, unless already in a quickdrop.
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
                    // Contact during a quickdrop does no damage: no contact box threatens a begun quickdrop plan.
                    bool dropping = s.Quickdropping || (IsDrop(m) && f >= 2 + DropDelay) || (IsHopDrop(m) && f >= HopDropAt + 1 + DropDelay);
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
                        // A box coming down lands and rolls on (BULLET_RIBAULD_SLOWDOWN), never through the floor.
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
                            if (f < l.AppearIn) continue; // a warning beam, safe until it activates
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
                // Room from the walls where the plan ends: a corner leaves no way out of the next attack.
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
                if (IsHopDrop(m)) y = s.Pos.y + (f <= HopDropAt + DropDelay ? TapRise[f - 1] : Math.Max(0f, TapRise[HopDropAt + DropDelay - 1] - QuickdropFall * (f - HopDropAt - DropDelay)));
                else if (m == Move.Hop || m == Move.HopLeft || m == Move.HopRight) y = s.Pos.y + (f <= TapRise.Length ? TapRise[f - 1] : 0f);
                else if (IsJump(m)) y = s.Pos.y + (f <= HoldRise.Length ? HoldRise[f - 1] : 0f);
                else y = s.Pos.y;
                return new Vector2(x, y);
            }
            // In the air: rising slows by gravity while held, faster once let go; a fall caps at MaxFall.
            float vy = s.Vy;
            y = s.Pos.y;
            int hold = s.HoldLeft;
            for (int i = 0; i < f; i++)
            {
                if (s.Quickdropping || (IsDrop(m) && i >= 1 + DropDelay)) vy = -QuickdropFall;
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

        // The plan to take: `want` when nothing meets it within the horizon; else the safe plan nearest it (same
        // direction, then standing, then fewest frames in the air); when every plan is hit, the one hit latest, then
        // the one inside a threat fewest frames. With `stickX` (a fight's target), a safe plan ending nearer it beats
        // one with more room, and the wanted plan needs only StickClearance.
        private const float StickClearance = 10f;

        // `imminent`: the wanted plan stands unless hit within that many frames, so movement keeps running (a fight
        // wants the whole horizon clear). `hug`: what ending nearer the target is worth against room and clearance.
        public const float DefaultHug = 3f;

        public static Plan Choose(List<Plan> plans, Move want, float? stickX = null, int? imminent = null, float hug = DefaultHug)
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
                // Hit either way: later wins (time to plan again), then fewest frames inside (out of a beam soonest).
                int score = (p.FirstHit > Horizon ? 100000 : 0) + p.FirstHit * 1000 - p.HitFrames * 300 + (int)(Math.Max(0f, p.Room) * 2f);
                if (stickX.HasValue) score += (int)(Math.Max(0f, 400f - Mathf.Abs(p.EndX - stickX.Value)) * hug) + (int)Math.Min(p.Clearance, 40f);
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
