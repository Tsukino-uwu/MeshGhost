using System;
using System.Collections.Generic;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // TELLS: what an enemy does before an attack, learned by watching, so the dodge can see an attack before its box exists. Up close a
    // box that is born on top of the player cannot be dodged by boxes alone: Ribauld's charge starts from a standstill and his speeddown
    // shot spawns at his gun, and every hit while hugging him was one of those (2026-09-17). His logic state gave each away: ATTACK2 16
    // frames before every charge, ATTACK4 32 frames before the shot, ATTACK1 before the bomb ring (the flight recorder, same date).
    //
    // Nothing here knows an enemy. Every frame, each character's logic state and when it began are kept; when a bullet that can hurt the
    // player is born to a character, its birth is a sample for (character type, the state it was in): how many frames into that state,
    // the box's offset from the character (x turned by the way it faces) and size, and its mean velocity over its first VelocityFrames
    // (Ribauld's charge box stood still its first frame and then ran with him, so a velocity read a frame after birth was 0). From then on a
    // character entering a state with samples is, to the dodge, those boxes appearing after their delay (Threats.Threat.AppearIn). The
    // table lives in the AppDomain's data, so a hot reload keeps what was learned, and in a file under the repo's gitignored
    // autoplay/states/tevi/ (TableFile, set by the plugin), read when the AppDomain has none: a game restart keeps it too.
    public static class Tells
    {
        private const string Key = "meshghost.autoplay.tells.v2";
        private const int MaxDelay = 150, MaxSamples = 6, VelocityFrames = 10;

        public sealed class Sample
        {
            public int Delay;
            public float Dx, Dy, W, H, Vx, Vy; // Dx and Vx turned so positive is the way the character faced
            public string Type;
        }

        private sealed class Seen
        {
            public string State;
            public int Since;
            public int Facing;
        }

        private static readonly Dictionary<int, Seen> States = new Dictionary<int, Seen>(); // by character instance id
        private static readonly Dictionary<int, int> BulletBorn = new Dictionary<int, int>(); // live slots already sampled
        private static readonly Dictionary<int, Sample> Pending = new Dictionary<int, Sample>(); // born last frame, waiting for velocity
        private static readonly Dictionary<int, Vector2> PendingCentre = new Dictionary<int, Vector2>();
        private static readonly Dictionary<int, int> PendingBorn = new Dictionary<int, int>();
        private static Dictionary<string, List<Sample>> table;
        private static int lastFileWrite = -1000;
        public static string TableFile; // autoplay/states/tevi/tells.json, when the plugin knows the repo

        private static Dictionary<string, List<Sample>> Table
        {
            get
            {
                if (table != null) return table;
                table = new Dictionary<string, List<Sample>>();
                string json = AppDomain.CurrentDomain.GetData(Key) as string;
                if (json == null && TableFile != null && System.IO.File.Exists(TableFile))
                {
                    try { json = System.IO.File.ReadAllText(TableFile); } catch (Exception) { json = null; }
                }
                if (json != null)
                {
                    try
                    {
                        table = JsonConvert.DeserializeObject<Dictionary<string, List<Sample>>>(json) ?? table;
                    }
                    catch (Exception)
                    {
                        // a table from an older copy of this class: start again
                    }
                }
                return table;
            }
        }

        private static void Save()
        {
            string json = JsonConvert.SerializeObject(table);
            AppDomain.CurrentDomain.SetData(Key, json);
            if (TableFile == null || Time.frameCount - lastFileWrite < 120) return; // a bomb ring is 8 samples in a frame
            lastFileWrite = Time.frameCount;
            try
            {
                System.IO.File.WriteAllText(TableFile, json);
            }
            catch (Exception)
            {
                // the file is a convenience: the AppDomain copy stands
            }
        }

        private static int Facing(CharacterBase c) => c.direction.ToString() == "LEFT" ? -1 : 1;

        // Once a frame, from Plugin.Update, whether or not a core is connected.
        public static void Frame(CharacterBase p)
        {
            CharacterManager cm = CharacterManager.Instance;
            BulletManager bm = BulletManager.Instance;
            if (p == null || cm == null || cm.characters == null || bm == null || bm.bullets_enable == null) return;
            int f = Time.frameCount;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == p || c.t == null) continue;
                int id = c.GetInstanceID();
                string st = c.logicStatus.ToString();
                if (!States.TryGetValue(id, out Seen s) || s.State != st) States[id] = s = new Seen { State = st, Since = f, Facing = Facing(c) };
            }

            // Velocity for the ones born VelocityFrames ago (or gone sooner: the mean over the frames they lived).
            foreach (var kv in new List<KeyValuePair<int, Sample>>(Pending))
            {
                int age = f - PendingBorn[kv.Key];
                bulletScript b = bm.GetBullet(kv.Key);
                bool alive = b != null && b.t != null && bm.bullets_enable[kv.Key];
                if (alive && age < VelocityFrames) continue;
                float turn = kv.Value.Vx; // the facing sign was kept here until now
                if (alive && age > 0)
                {
                    Vector3 off = b.GetHOffset();
                    var c = new Vector2(b.t.position.x + off.x, b.t.position.y + off.y);
                    Vector2 v = (c - PendingCentre[kv.Key]) / age;
                    kv.Value.Vx = v.x * turn;
                    kv.Value.Vy = v.y;
                }
                else
                {
                    kv.Value.Vx = 0f;
                }
                Pending.Remove(kv.Key);
                PendingCentre.Remove(kv.Key);
                PendingBorn.Remove(kv.Key);
                Save();
            }

            for (int i = 0; i < bm.bullets_enable.Length; i++)
            {
                if (!bm.bullets_enable[i])
                {
                    BulletBorn.Remove(i);
                    continue;
                }
                if (BulletBorn.ContainsKey(i)) continue;
                bulletScript b = bm.GetBullet(i);
                if (b == null || b.t == null || b.owner == null || b.owner == p || b.owner.t == null || b.damage == 0f) continue;
                float w = b.GetHSizeW(), h = b.GetHSizeH();
                if (w <= 0f) continue; // not grown yet: sampled when it is
                BulletBorn[i] = f;
                string type = b.type.ToString();
                if (type == "BODYBOX" || type == "ENEMY_HURTBOX") continue; // always there, not an attack
                if (!States.TryGetValue(b.owner.GetInstanceID(), out Seen s)) continue;
                int delay = f - s.Since;
                if (delay > MaxDelay) continue;
                Vector3 off = b.GetHOffset();
                var centre = new Vector2(b.t.position.x + off.x, b.t.position.y + off.y);
                int facing = s.Facing;
                var sample = new Sample
                {
                    Delay = delay,
                    Dx = (centre.x - b.owner.t.position.x) * facing,
                    Dy = centre.y - b.owner.t.position.y,
                    W = w,
                    H = h,
                    Vx = facing, // replaced by the turned velocity next frame
                    Type = type,
                };
                string key = b.owner.type + "|" + s.State;
                if (!Table.TryGetValue(key, out List<Sample> list)) Table[key] = list = new List<Sample>();
                list.Add(sample);
                if (list.Count > MaxSamples) list.RemoveAt(0);
                Pending[i] = sample;
                PendingCentre[i] = centre;
                PendingBorn[i] = f;
                Save();
            }
        }

        // The attacks the characters in view are winding up, as threats that appear after their learned delay, placed where each
        // character stands now and turned the way it faces now.
        public static void Predict(CharacterBase p, List<Threats.Threat> into)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (p == null || cm == null || cm.characters == null) return;
            int f = Time.frameCount, n = 0;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == p || c.t == null || !c.gameObject.activeInHierarchy || c.health <= 0) continue;
                if (!States.TryGetValue(c.GetInstanceID(), out Seen s)) continue;
                if (!Table.TryGetValue(c.type + "|" + s.State, out List<Sample> list)) continue;
                int inState = f - s.Since, facing = Facing(c);
                foreach (Sample x in list)
                {
                    // Samples well past their time mean this wind-up does not always end in that attack: wait at most a little longer.
                    int appearIn = x.Delay - inState;
                    if (appearIn < -2 || appearIn > Dodge.Horizon) continue;
                    var centre = new Vector2(c.t.position.x + x.Dx * facing, c.t.position.y + x.Dy);
                    into.Add(new Threats.Threat
                    {
                        Slot = -2000000 - (n++),
                        Type = "TELL_" + x.Type,
                        Owner = c.type.ToString(),
                        Box = new Rect(centre.x - x.W / 2f, centre.y - x.H / 2f, x.W, x.H),
                        Velocity = new Vector2(x.Vx * facing, x.Vy),
                        MinCx = float.MinValue,
                        MaxCx = float.MaxValue,
                        AppearIn = Math.Max(0, appearIn),
                    });
                }
            }
        }

        // Whether any attack of this character type has been seen.
        public static bool Known(string type)
        {
            foreach (string key in Table.Keys)
            {
                if (key.StartsWith(type + "|")) return true;
            }
            return false;
        }

        public static JObject Report()
        {
            var o = new JObject();
            foreach (var kv in Table)
            {
                var arr = new JArray();
                foreach (Sample x in kv.Value) arr.Add(new JArray(x.Type, x.Delay, Math.Round(x.Dx), Math.Round(x.Dy), Math.Round(x.W), Math.Round(x.H), Math.Round(x.Vx, 1), Math.Round(x.Vy, 1)));
                o[kv.Key] = arr;
            }
            return o;
        }
    }
}
