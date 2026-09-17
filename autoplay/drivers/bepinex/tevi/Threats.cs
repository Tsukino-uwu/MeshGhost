using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // What can hurt the player, as the game tests it (bulletScript.isHit and CheckHitCharacter, read as a map; names from the
    // Steam build's assemblies, 2026-09-17): a live bullet not the player's own, with damage above 0 and a box, overlapping
    // the player's hurtbox -- Bodybox wide and high, centred at her x plus its x offset, and at the height of the game's own
    // hitbox display (GameSystem.hitboxDisplay), lower while sliding. The characters' contact damage is a bullet of this kind
    // too (ENEMY_HURTBOX). What each rule does in play is measured before a reflex relies on it (adapters/tevi/MEASURED.md).
    //
    // LASERS are not bullets: a LaserController2D hurts through a circle cast from its position along its forward, of radius
    // OverAll_Size / offsize times its extra hitbox width, as far as length / 10 times OverAll_Size, once its private `hurt` is
    // on (LaserController2D, read as a map; found 2026-09-17 when a hit read bullet type NORMAL with no box near the player:
    // Ribauld's cut-in laser). The game keeps no list of live lasers (they come from a spawn pool), so a postfix on
    // GemaPoolManager.CreateLaser notes each one made, and one gone inactive is forgotten. Reading only.
    //
    // EXPLOSIVES: some characters are a blast waiting to happen, and the blast's bullet is born with no box and grows to its full
    // size a frame or two later -- too late to step out of. TEVI's blastorb (EnergyBall) explodes as it comes within about 42 units
    // of the player (EnergyBall, read as a map), and its ENERGYBALL_EXPLODE box read 0x0 for two frames, then 405x405 (measured
    // 2026-09-17, the Ribauld fight). So a character whose type has been seen to explode is itself a threat of its blast's size,
    // moving with it: the table starts with that measurement and learns any other from a bullet it sees grow from 0x0. The user,
    // 2026-09-17: "the orb only explode when it touch something, not when laying idle on the ground" -- so a still one is only
    // its touch distance (TouchReach each side), and a moving one too ("only dangerous if you touch them or they are pushed into
    // you"), except where its path meets another character, which sets it off: there it is its whole blast. Two blasts on 2026-09-17
    // came from treating every moving orb as its blast, when no plan escapes a 405-wide box closing at 20 units a frame and the
    // least-bad one ran into it. A still orb that hops straight up is detonating (below): all of its blast.
    //
    // A box that belongs to a character (its centre within a tile of the character: a body, a charge) stops at walls when moved on,
    // as the character does: Ribauld's charge, predicted to carry on past a wall, stopped under the player's landing (2026-09-17).
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

        // The live lasers not the player's, as segments with a radius: the length and size each is growing toward, whichever is
        // larger, since a warning beam becomes the hurting one where it stands.
        public static List<Laser> ReadLasers(CharacterBase p)
        {
            var list = new List<Laser>();
            for (int i = Lasers.Count - 1; i >= 0; i--)
            {
                LaserController2D l = Lasers[i];
                if (l == null || !l.gameObject.activeInHierarchy)
                {
                    Lasers.RemoveAt(i);
                    continue;
                }
                if (LaserOwner != null && LaserOwner.GetValue(l) as CharacterBase == p) continue;
                float size = Math.Max(l.OverAll_Size, LaserTargetSize != null ? (float)LaserTargetSize.GetValue(l) : 0f);
                float extra = LaserExtraWidth != null ? (float)LaserExtraWidth.GetValue(l) : 1f;
                float reach = Math.Max(l.length, l.tlength) / 10f * size;
                Vector3 fwd = l.transform.forward;
                var dir = new Vector2(fwd.x, fwd.y);
                if (dir.sqrMagnitude < 1e-6f) continue;
                dir.Normalize();
                var from = new Vector2(l.transform.position.x, l.transform.position.y);
                list.Add(new Laser
                {
                    From = from,
                    To = from + dir * reach,
                    Radius = size / LaserController2D.offsize * extra,
                    Hurting = LaserHurt != null && (bool)LaserHurt.GetValue(l),
                    Type = LaserBulletType != null ? LaserBulletType.GetValue(l).ToString() : "LASER",
                });
            }
            return list;
        }

        // Whether a moving explosive's straight path over the next second comes within a tile and a half of a living character other
        // than itself and the player, which would set it off there.
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

        // How a shot's heading has turned relative to the player, frame by frame: a `speeddown` shot passed under her, turned and
        // came back (2026-09-17), which a straight line never predicts. Turning toward her for HomingFrames frames in a row, it homes.
        private const int HomingFrames = 6;
        private static readonly Dictionary<int, int> TurningToward = new Dictionary<int, int>();

        private const float TouchReach = 48f, StillSpeed = 0.5f;

        private static readonly Dictionary<int, Vector2> LastCentre = new Dictionary<int, Vector2>();
        private static readonly Dictionary<string, Vector2> BlastSize = new Dictionary<string, Vector2> { ["EnergyBall"] = new Vector2(405f, 405f) };
        private static readonly HashSet<int> BornEmpty = new HashSet<int>();
        private static readonly Dictionary<int, Vector2> LastVelocity = new Dictionary<int, Vector2>();

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

        // Every bullet that could hurt the player, in view (plus a margin), with its velocity. Call once a frame at most: the
        // velocity is the change since the last call that saw the same slot on the frame before.
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
                if (BornEmpty.Remove(i) && b.owner != null)
                {
                    // A blast: born with no box, grown now. Its owner's type explodes this big.
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
                if (b.owner.t != null && Mathf.Abs(b.owner.t.position.x - c.x) < 56f && v.x != 0f)
                {
                    Dodge.WallLimits(b.owner.t.position, w / 2f, out float lo, out float hi);
                    threat.MinCx = Math.Min(lo, c.x);
                    threat.MaxCx = Math.Max(hi, c.x);
                }
                list.Add(threat);
            }
            // Attacks being wound up, from the tells learned so far.
            Tells.Predict(p, list);
            // Characters that explode, as their blast (keyed apart from bullet slots by a negative id).
            CharacterManager cm = CharacterManager.Instance;
            if (cm != null && cm.characters != null)
            {
                foreach (CharacterBase ch in cm.characters)
                {
                    if (ch == null || ch == p || ch.t == null || !ch.gameObject.activeInHierarchy) continue;
                    if (!BlastSize.TryGetValue(ch.type.ToString(), out Vector2 size)) continue;
                    var c = new Vector2(ch.t.position.x, ch.t.position.y + 10f);
                    if (Utility.isOutsideCamera(c, margin)) continue;
                    int key = -1 - (ch.GetInstanceID() & 0x3fffffff);
                    Vector2 v = Vector2.zero;
                    if (LastCentre.TryGetValue(key, out Vector2 last) && LastFrame.TryGetValue(key, out int lf) && lf == f - 1) v = c - last;
                    LastCentre[key] = c;
                    LastFrame[key] = f;
                    // A hop in place is a detonation: both orbs in Ribauld's arena rose and fell straight, with no sideways speed, and went
                    // off as they landed on the same frame (2026-09-17), hitting her 122 units from one.
                    bool hopping = Mathf.Abs(v.x) < 1f && Mathf.Abs(v.y) >= 2f;
                    if (!hopping && (v.magnitude < StillSpeed || !PathMeetsCharacter(cm, ch, p, c, v))) size = new Vector2(TouchReach * 2f, TouchReach * 2f);
                    list.Add(new Threat { Slot = key, Type = "BLAST_OF_" + ch.type, Owner = ch.type.ToString(), Box = new Rect(c.x - size.x / 2f, c.y - size.y / 2f, size.x, size.y), Velocity = v, MinCx = float.MinValue, MaxCx = float.MaxValue });
                }
            }
            return list;
        }
    }
}
