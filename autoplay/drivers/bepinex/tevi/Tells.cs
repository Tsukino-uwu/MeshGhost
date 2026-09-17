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
    // autoplay/states/tevi/ (TableFile, set by the plugin), read when the AppDomain has none: a game restart keeps it too. A thrown
    // explosive (SpawnFrame) is sampled the same way, as SPAWN_<type>.
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
            public bool Followed; // an attack was born during this stay in the state
        }

        // How often each (type|state) was entered, and how often an attack followed while in it. A state an enemy rests in is a poor tell:
        // Ribauld's bomb ring was born after he went back to NORMAL, so every NORMAL predicted a ring 23 frames on and she stood idle
        // through it (the user, 2026-09-17: "there should also be a gap to get in some more attacks instead of just standing idle").
        // A state is predicted only while an attack followed at least FollowShare of its last entries (after MinEntries).
        private const int MinEntries = 3, EntryWindow = 20;
        private const float FollowShare = 0.5f;
        private static readonly Dictionary<string, Queue<bool>> Entries = new Dictionary<string, Queue<bool>>();

        private static void Close(string key, bool followed)
        {
            if (!Entries.TryGetValue(key, out Queue<bool> q)) Entries[key] = q = new Queue<bool>();
            q.Enqueue(followed);
            while (q.Count > EntryWindow) q.Dequeue();
        }

        private static bool Reliable(string key)
        {
            if (!Entries.TryGetValue(key, out Queue<bool> q) || q.Count < MinEntries) return true;
            int n = 0;
            foreach (bool b in q) if (b) n++;
            return n >= FollowShare * q.Count;
        }

        private static readonly Dictionary<int, Seen> States = new Dictionary<int, Seen>(); // by character instance id
        private static readonly Dictionary<int, int> BulletBorn = new Dictionary<int, int>(); // live slots already sampled
        private static readonly Dictionary<int, Sample> Pending = new Dictionary<int, Sample>(); // born last frame, waiting for velocity
        private static readonly Dictionary<int, Vector2> PendingCentre = new Dictionary<int, Vector2>();
        private static readonly Dictionary<int, int> PendingBorn = new Dictionary<int, int>();
        // Thrown explosives: a character that explodes (Threats.IsExplosive) coming into play is an attack too, and not a bullet. Ribauld's
        // orb appeared 25 units from her 26 frames into his ATTACK1 and went off on her 8 frames later, with nothing for the dodge to see
        // first (2026-09-17, Infernal BBQ; the user: "still getting hit a lot when the orbs are being thrown out"). Its birth is sampled for
        // the nearest other living character within SpawnOwnerReach, as its touch box grown by the orb's own body.
        private const float SpawnOwnerReach = 300f, SpawnBox = Threats.TouchBox + 50f;
        private static readonly Dictionary<int, bool> CharActive = new Dictionary<int, bool>();
        private static readonly Dictionary<int, KeyValuePair<CharacterBase, Sample>> PendingChar = new Dictionary<int, KeyValuePair<CharacterBase, Sample>>();
        private static readonly Dictionary<int, Vector2> PendingCharAt = new Dictionary<int, Vector2>();
        private static readonly Dictionary<int, int> PendingCharBorn = new Dictionary<int, int>();
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
                if (!States.TryGetValue(id, out Seen s) || s.State != st)
                {
                    if (s != null) Close(c.type + "|" + s.State, s.Followed);
                    States[id] = s = new Seen { State = st, Since = f, Facing = Facing(c) };
                }
            }

            SpawnFrame(p, cm, f);

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
                s.Followed = true;
                if (!Table.TryGetValue(key, out List<Sample> list)) Table[key] = list = new List<Sample>();
                list.Add(sample);
                if (list.Count > MaxSamples) list.RemoveAt(0);
                Pending[i] = sample;
                PendingCentre[i] = centre;
                PendingBorn[i] = f;
                Save();
            }
        }

        private static bool spawnPrimed; // the first frame after a (re)load only notes what is already active: none of it was just thrown

        private static void SpawnFrame(CharacterBase p, CharacterManager cm, int f)
        {
            bool primed = spawnPrimed;
            spawnPrimed = true;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == p || c.t == null) continue;
                int id = c.GetInstanceID();
                bool active = c.gameObject.activeInHierarchy;
                bool was = CharActive.TryGetValue(id, out bool w) && w;
                CharActive[id] = active;
                if (!primed || !active || was || !Threats.IsExplosive(c.type.ToString())) continue;
                if (Utility.isOutsideCamera(c.t.position, 64f)) continue; // a whole area's orbs coming into being as it loads
                CharacterBase owner = null;
                float best = SpawnOwnerReach;
                foreach (CharacterBase o in cm.characters)
                {
                    if (o == null || o == p || o == c || o.t == null || !o.gameObject.activeInHierarchy || o.health <= 0) continue;
                    if (Threats.IsExplosive(o.type.ToString())) continue;
                    float d = Vector2.Distance(o.t.position, c.t.position);
                    if (d < best)
                    {
                        best = d;
                        owner = o;
                    }
                }
                if (owner == null || !States.TryGetValue(owner.GetInstanceID(), out Seen s)) continue;
                int delay = f - s.Since;
                if (delay > MaxDelay) continue;
                var sample = new Sample
                {
                    Delay = delay,
                    Dx = (c.t.position.x - owner.t.position.x) * s.Facing,
                    Dy = c.t.position.y - owner.t.position.y,
                    W = SpawnBox,
                    H = SpawnBox,
                    Vx = s.Facing,
                    Type = "SPAWN_" + c.type,
                };
                string key = owner.type + "|" + s.State;
                s.Followed = true;
                if (!Table.TryGetValue(key, out List<Sample> list)) Table[key] = list = new List<Sample>();
                list.Add(sample);
                if (list.Count > MaxSamples) list.RemoveAt(0);
                PendingChar[id] = new KeyValuePair<CharacterBase, Sample>(c, sample);
                PendingCharAt[id] = new Vector2(c.t.position.x, c.t.position.y);
                PendingCharBorn[id] = f;
                Save();
            }
            foreach (var kv in new List<KeyValuePair<int, KeyValuePair<CharacterBase, Sample>>>(PendingChar))
            {
                CharacterBase c = kv.Value.Key;
                Sample x = kv.Value.Value;
                int age = f - PendingCharBorn[kv.Key];
                bool alive = c != null && c.t != null && c.gameObject.activeInHierarchy;
                if (alive && age < VelocityFrames) continue;
                float turn = x.Vx;
                if (alive && age > 0)
                {
                    Vector2 v = (new Vector2(c.t.position.x, c.t.position.y) - PendingCharAt[kv.Key]) / age;
                    x.Vx = v.x * turn;
                    x.Vy = v.y;
                }
                else x.Vx = 0f;
                PendingChar.Remove(kv.Key);
                PendingCharAt.Remove(kv.Key);
                PendingCharBorn.Remove(kv.Key);
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
                if (!Table.TryGetValue(c.type + "|" + s.State, out List<Sample> list) || !Reliable(c.type + "|" + s.State)) continue;
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

        // The shortest learned delay from a state's start to an attack of this character type (thrown explosives left out), or null.
        public static int? FastestLead(string type)
        {
            int? best = null;
            foreach (var kv in Table)
            {
                if (!kv.Key.StartsWith(type + "|")) continue;
                foreach (Sample x in kv.Value)
                {
                    if (x.Type.StartsWith("SPAWN_")) continue;
                    if (best == null || x.Delay < best.Value) best = x.Delay;
                }
            }
            return best;
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
