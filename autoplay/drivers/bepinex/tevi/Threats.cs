using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // What can hurt the player: a live bullet not hers, with damage and a box, overlapping her hurtbox; contact damage
    // is one too (ENEMY_HURTBOX). Lasers are not bullets: one hurts through a circle cast along its forward once its
    // private `hurt` is on, and the game keeps no list of live ones, so a postfix on GemaPoolManager.CreateLaser notes
    // each one made. Reading only.
    //
    // An exploding character's blast is born with no box and grows a frame or two later, too late to step out of, so a
    // type seen to explode is itself a threat of its blast's size, learned from an EXPLODE bullet seen to grow. An orb
    // goes off only on touch, so a still or moving one is only its touch distance, except where its path meets another
    // character or it hops straight up from rest: there it is its whole blast.
    public static class Threats
    {
        public const string HarmonyId = "dev.meshghost.autoplay.threats";
        private static Harmony harmony;
        private static readonly List<LaserController2D> Lasers = new List<LaserController2D>();
        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        private static readonly FieldInfo LaserHurt = typeof(LaserController2D).GetField("hurt", Private);
        private static readonly FieldInfo LaserTargetSize = typeof(LaserController2D).GetField("tOverAll_Size", Private);
        private static readonly FieldInfo LaserExtraWidth = typeof(LaserController2D).GetField("extraHitboxWidth", Private);
        private static readonly FieldInfo LaserBulletType = typeof(LaserController2D).GetField("type", Private);
        private static readonly FieldInfo LaserOwner = typeof(LaserController2D).GetField("owner", Private);

        public struct Laser
        {
            public Vector2 From, To;
            public float Radius;
            public bool Hurting;
            public string Type;
            // frames of game time until it hurts: 0 when it does, or when how long its warning lasts is not known yet
            public int AppearIn;
        }

        // A laser's warning beam is safe until it activates, at the same x: each laser's age is counted in frames of
        // game time, and the age at which a type first hurts is learned, the shortest seen.
        private static readonly Dictionary<LaserController2D, int> LaserAge = new Dictionary<LaserController2D, int>();
        private static readonly Dictionary<LaserController2D, int> LaserAgedAt = new Dictionary<LaserController2D, int>();
        private static readonly Dictionary<string, int> WarnFrames = new Dictionary<string, int> { ["RIBAULD_CUTIN_LASER"] = 56 };

        public static JToken WarnTable()
        {
            var o = new Newtonsoft.Json.Linq.JObject();
            foreach (var kv in WarnFrames) o[kv.Key] = kv.Value;
            return o;
        }

        public static void Install()
        {
            if (harmony != null) return;
            harmony = new Harmony(HarmonyId);
            harmony.Patch(AccessTools.Method(typeof(GemaPoolManager), "CreateLaser", new[] { typeof(Bullet.LaserType), typeof(Vector3), typeof(float) }),
                postfix: new HarmonyMethod(typeof(Threats), nameof(CreateLaserPostfix)));
        }

        public static void Uninstall()
        {
            harmony?.UnpatchSelf();
            harmony = null;
            Lasers.Clear();
        }

        private static void CreateLaserPostfix(LaserController2D __result)
        {
            if (__result != null && !Lasers.Contains(__result)) Lasers.Add(__result);
        }

        // The live lasers not the player's, as segments with a radius: the length and size each is growing toward,
        // whichever is larger, since a warning beam becomes the hurting one where it stands.
        public static List<Laser> ReadLasers(CharacterBase p)
        {
            var list = new List<Laser>();
            for (int i = Lasers.Count - 1; i >= 0; i--)
            {
                LaserController2D l = Lasers[i];
                if (l == null || !l.gameObject.activeInHierarchy)
                {
                    Lasers.RemoveAt(i);
                    if (l != null)
                    {
                        LaserAge.Remove(l);
                        LaserAgedAt.Remove(l);
                    }
                    continue;
                }
                // Aged once a frame of game time, however often it is read.
                if (Time.deltaTime > 0f && (!LaserAgedAt.TryGetValue(l, out int agedAt) || agedAt != Time.frameCount))
                {
                    LaserAgedAt[l] = Time.frameCount;
                    LaserAge[l] = LaserAge.TryGetValue(l, out int a) ? a + 1 : 1;
                }
                LaserAge.TryGetValue(l, out int age);
                if (LaserOwner != null && LaserOwner.GetValue(l) as CharacterBase == p) continue;
                float size = Math.Max(l.OverAll_Size, LaserTargetSize != null ? (float)LaserTargetSize.GetValue(l) : 0f);
                float extra = LaserExtraWidth != null ? (float)LaserExtraWidth.GetValue(l) : 1f;
                float reach = Math.Max(l.length, l.tlength) / 10f * size;
                Vector3 fwd = l.transform.forward;
                var dir = new Vector2(fwd.x, fwd.y);
                if (dir.sqrMagnitude < 1e-6f) continue;
                dir.Normalize();
                var from = new Vector2(l.transform.position.x, l.transform.position.y);
                bool hurting = LaserHurt != null && (bool)LaserHurt.GetValue(l);
                string type = LaserBulletType != null ? LaserBulletType.GetValue(l).ToString() : "LASER";
                if (hurting && age > 0 && (!WarnFrames.TryGetValue(type, out int w) || age < w)) WarnFrames[type] = age;
                int appearIn = !hurting && WarnFrames.TryGetValue(type, out int warn) ? Math.Max(0, warn - age) : 0;
                list.Add(new Laser
                {
                    From = from,
                    To = from + dir * reach,
                    Radius = size / LaserController2D.offsize * extra,
                    Hurting = hurting,
                    Type = type,
                    AppearIn = appearIn,
                });
            }
            return list;
        }

        // Whether a moving explosive's straight path over the next second comes within a tile and a half of a living
        // character other than itself and the player, which would set it off there.
        private static bool PathMeetsCharacter(CharacterManager cm, CharacterBase self, CharacterBase p, Vector2 from, Vector2 v)
        {
            Vector2 to = from + v * 60f;
            foreach (CharacterBase other in cm.characters)
            {
                if (other == null || other == self || other == p || other.t == null || !other.gameObject.activeInHierarchy || other.health <= 0) continue;
                if (other.maxhealth >= 99999) continue; // another orb
                if (DistanceToSegment(new Vector2(other.t.position.x, other.t.position.y), from, to) < 84f) return true;
            }
            return false;
        }

        public static float DistanceToSegment(Vector2 p, Vector2 a, Vector2 b)
        {
            Vector2 ab = b - a;
            float t = ab.sqrMagnitude > 0f ? Mathf.Clamp01(Vector2.Dot(p - a, ab) / ab.sqrMagnitude) : 0f;
            return Vector2.Distance(p, a + ab * t);
        }
        // A character's threat slot, apart from bullet slots.
        public static int CharacterKey(CharacterBase ch) => -1 - (ch.GetInstanceID() & 0x3fffffff);

        public const float TouchBox = TouchReach * 2f;

        // Whether characters of this type have been seen to explode (the blast table).
        public static bool IsExplosive(string type) => BlastSize.ContainsKey(type);

        public struct Threat
        {
            public int Slot;
            public string Type, Owner;
            public Rect Box;
            public Vector2 Velocity; // world units a frame, from its last position; zero the first frame it is seen
            public float MinCx, MaxCx; // how far its centre can move before a wall: unbounded for a projectile
            public bool Homing; // its heading has been turning toward the player: it follows her
            public int AppearIn; // frames until it exists: 0 for a live box, the learned delay for a tell (Tells.cs)
        }

        // How a shot's heading has turned relative to the player: a count up one each frame it turns toward her and
        // down two each frame it does not; at HomingFrames it homes, which a straight line never predicts.
        private const int HomingFrames = 6;
        private static readonly Dictionary<int, int> TurningToward = new Dictionary<int, int>();

        // StillSpeed 3: orbs on blastvines sway a little every frame; a knocked orb flies at 20-30 units a frame.
        private const float TouchReach = 48f, StillSpeed = 3f;

        private static readonly Dictionary<int, Vector2> LastCentre = new Dictionary<int, Vector2>();
        private static readonly Dictionary<string, Vector2> BlastSize = new Dictionary<string, Vector2> { ["EnergyBall"] = new Vector2(405f, 405f) };
        private static readonly HashSet<int> BornEmpty = new HashSet<int>();
        private static readonly Dictionary<int, Vector2> LastVelocity = new Dictionary<int, Vector2>();
        // How many frames in a row each explosive has lain still, and whether its current hop began from rest.
        private static readonly Dictionary<int, int> StillFor = new Dictionary<int, int>();
        private static readonly Dictionary<int, bool> HopFromRest = new Dictionary<int, bool>();
        private const int RestFrames = 30;

        public static JToken BlastTable()
        {
            var o = new Newtonsoft.Json.Linq.JObject();
            foreach (var kv in BlastSize) o[kv.Key] = new Newtonsoft.Json.Linq.JArray(kv.Value.x, kv.Value.y);
            return o;
        }
        private static readonly Dictionary<int, int> LastFrame = new Dictionary<int, int>();

        public static bool PlayerHurtbox(CharacterBase p, out Rect box)
        {
            box = default(Rect);
            if (p == null || p.t == null || GameSystem.Instance == null || GameSystem.Instance.hitboxDisplay == null) return false;
            float w = p.GetHitboxW(), h = p.GetHitboxH();
            if (w <= 0f || h <= 0f) return false;
            float cx = p.t.position.x + p.GetHitboxOffsetX();
            float cy = GameSystem.Instance.hitboxDisplay.transform.position.y + (p.isSlide() ? MainVar.instance.SlideHitboxOffY : 0f);
            box = new Rect(cx - w / 2f, cy - h / 2f, w, h);
            return true;
        }

        // Every bullet that could hurt the player, in view (plus a margin), with its velocity. Call once a frame at
        // most: the velocity is the change since the last call that saw the same slot on the frame before.
        public static List<Threat> Read(CharacterBase p, float margin)
        {
            var list = new List<Threat>();
            BulletManager bm = BulletManager.Instance;
            if (bm == null || bm.bullets_enable == null || p == null || CameraScript.Instance == null) return list;
            int f = Time.frameCount;
            for (int i = 0; i < bm.bullets_enable.Length; i++)
            {
                if (!bm.bullets_enable[i] || (bm.bullets_delay != null && i < bm.bullets_delay.Length && bm.bullets_delay[i] > 0)) continue;
                bulletScript b = bm.GetBullet(i);
                if (b == null || b.t == null || b.owner == null || b.owner == p || b.damage == 0f) continue;
                float w = b.GetHSizeW(), h = b.GetHSizeH();
                bool fresh = !LastFrame.TryGetValue(i, out int seenAt) || seenAt < f - 1;
                if (w <= 0f)
                {
                    if (fresh) BornEmpty.Add(i);
                    LastFrame[i] = f;
                    continue;
                }
                // Only an explosion teaches a blast: an ordinary attack can also be born with no box and grow.
                if (BornEmpty.Remove(i) && b.owner != null && b.type.ToString().Contains("EXPLODE"))
                {
                    string owner = b.owner.type.ToString();
                    if (!BlastSize.TryGetValue(owner, out Vector2 known) || known.x * known.y < w * h) BlastSize[owner] = new Vector2(w, h);
                }
                Vector3 off = b.GetHOffset();
                var c = new Vector2(b.t.position.x + off.x, b.t.position.y + off.y);
                if (Utility.isOutsideCamera(c, margin)) continue;
                Vector2 v = Vector2.zero;
                if (LastCentre.TryGetValue(i, out Vector2 last) && LastFrame.TryGetValue(i, out int lf) && lf == f - 1) v = c - last;
                LastCentre[i] = c;
                LastFrame[i] = f;
                var threat = new Threat { Slot = i, Type = b.type.ToString(), Owner = b.owner.type.ToString(), Box = new Rect(c.x - w / 2f, c.y - h / 2f, w, h), Velocity = v, MinCx = float.MinValue, MaxCx = float.MaxValue };
                if (v.sqrMagnitude > 1f && LastVelocity.TryGetValue(i, out Vector2 lastV) && lastV.sqrMagnitude > 1f && p.t != null)
                {
                    Vector2 toPlayer = new Vector2(p.t.position.x, p.t.position.y) - c;
                    bool turning = Vector2.Angle(v, toPlayer) + 0.5f < Vector2.Angle(lastV, toPlayer);
                    TurningToward.TryGetValue(i, out int n);
                    TurningToward[i] = turning ? n + 1 : Math.Max(0, n - 2);
                    threat.Homing = TurningToward[i] >= HomingFrames;
                }
                if (fresh) TurningToward.Remove(i);
                LastVelocity[i] = v;
                // A box on its character (a body, a charge) stops at walls, as the character does.
                if (b.owner.t != null && Mathf.Abs(b.owner.t.position.x - c.x) < 56f && v.x != 0f)
                {
                    Dodge.WallLimits(b.owner.t.position, w / 2f, out float lo, out float hi);
                    threat.MinCx = Math.Min(lo, c.x);
                    threat.MaxCx = Math.Max(hi, c.x);
                }
                list.Add(threat);
            }
            Tells.Predict(p, list);
            // Characters that explode, as their blast.
            CharacterManager cm = CharacterManager.Instance;
            if (cm != null && cm.characters != null)
            {
                foreach (CharacterBase ch in cm.characters)
                {
                    if (ch == null || ch == p || ch.t == null || !ch.gameObject.activeInHierarchy) continue;
                    if (!BlastSize.TryGetValue(ch.type.ToString(), out Vector2 size)) continue;
                    var c = new Vector2(ch.t.position.x, ch.t.position.y + 10f);
                    if (Utility.isOutsideCamera(c, margin)) continue;
                    int key = CharacterKey(ch);
                    Vector2 v = Vector2.zero;
                    if (LastCentre.TryGetValue(key, out Vector2 last) && LastFrame.TryGetValue(key, out int lf) && lf == f - 1) v = c - last;
                    LastCentre[key] = c;
                    LastFrame[key] = f;
                    // A hop in place from rest detonates as it lands; a thrown orb bounces many times without one.
                    StillFor.TryGetValue(key, out int still);
                    bool moving = v.magnitude >= StillSpeed;
                    if (!moving && still >= 2) HopFromRest[key] = false; // the top of a hop reads still for a frame
                    else if (still >= RestFrames) HopFromRest[key] = true;
                    StillFor[key] = moving ? 0 : still + 1;
                    bool hopping = Mathf.Abs(v.x) < 1f && Mathf.Abs(v.y) >= 2f && HopFromRest.TryGetValue(key, out bool fromRest) && fromRest;
                    if (!hopping && (v.magnitude < StillSpeed || !PathMeetsCharacter(cm, ch, p, c, v))) size = new Vector2(TouchReach * 2f, TouchReach * 2f);
                    list.Add(new Threat { Slot = key, Type = "BLAST_OF_" + ch.type, Owner = ch.type.ToString(), Box = new Rect(c.x - size.x / 2f, c.y - size.y / 2f, size.x, size.y), Velocity = v, MinCx = float.MinValue, MaxCx = float.MaxValue });
                }
            }
            return list;
        }
    }
}
