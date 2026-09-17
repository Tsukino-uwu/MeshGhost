using System;
using System.Collections.Generic;
using System.Diagnostics;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // THE FLIGHT RECORDER (the plan's layer 4; agent_docs/phases/phase13.md, "how an agent sees a game"): the last Capacity frames
    // of game time, recorded every frame whether or not a core is connected, read by `recent` after an event to see what led to
    // it. A frame is recorded only when game time moved (Time.deltaTime above 0): while the clock is held, or the game has
    // stopped its own time (a menu, a conversation), nothing moves and nothing is kept, so the buffer holds what happened.
    //
    // A row: frame, mode, x, y, velocity x and y, on the ground, animation, logic state, HP, the driver's input held (the real
    // controller's is not seen), up to MaxEnemies living characters in view nearest first as [type index, id, x, y, hp, animation
    // index, logic state index] (what comes before an attack: a charge from a standstill gave no box to see, 2026-09-17), and
    // up to MaxBoxes live bullets not the player's -- attacks, shots, and the characters' own body and hurt boxes, which the
    // game keeps as bullets too -- nearest first as [type index, owner type index, x, y, width, height], the box's centre and
    // size as the game's hitbox drawing takes them (BulletManager._BMDebugUpdate, read as a map). Types are named once. Its own cost per frame is measured and reported (`cost`), since it runs every frame.
    public static class Recorder
    {
        public const int Capacity = 3600; // 60 seconds; one `recent` reads at most 600 of them, reaching back with until_frame
        private const int MaxEnemies = 4, MaxBoxes = 8;

        // The link caps a line at 64 KB: an answer past this is thinned (every doubled) until it fits.
        private const int AnswerBudget = 48000;

        private struct Enemy
        {
            public string Type, Anim, Logic;
            public int Id, Hp;
            public float X, Y, Stun, Armor;
            public bool Recovering;
        }

        private struct Box
        {
            public string Type, Owner;
            public float X, Y, W, H;
        }

        private sealed class Row
        {
            public int Frame, Hp;
            public string Mode, Anim, Logic, Input;
            public float X, Y, Vx, Vy;
            public bool Ground;
            public Enemy[] Enemies = new Enemy[MaxEnemies];
            public int EnemyCount;
            public Box[] Boxes = new Box[MaxBoxes];
            public int BoxCount;
        }

        private static readonly Row[] Rows = CreateRows();
        private static int next, count;

        private static readonly Stopwatch Watch = new Stopwatch();
        private static long ticksTotal;
        private static int ticksFrames;
        private static double worstMs;

        private static Row[] CreateRows()
        {
            var rows = new Row[Capacity];
            for (int i = 0; i < Capacity; i++) rows[i] = new Row();
            return rows;
        }

        private static readonly List<KeyValuePair<float, bulletScript>> NearBoxes = new List<KeyValuePair<float, bulletScript>>();
        private static readonly List<KeyValuePair<float, CharacterBase>> Near = new List<KeyValuePair<float, CharacterBase>>();

        // Once a frame from Plugin.Update, after the game's own update of that frame has moved things.
        public static void Record(CharacterBase p, string mode)
        {
            if (Time.deltaTime <= 0f || p == null || p.t == null) return;
            Watch.Reset();
            Watch.Start();
            Row r = Rows[next];
            Vector3 pos = p.t.position;
            r.Frame = Time.frameCount;
            r.Mode = mode;
            r.X = pos.x;
            r.Y = pos.y;
            if (p.phy_perfer != null)
            {
                r.Vx = p.phy_perfer._velocity.x;
                r.Vy = p.phy_perfer._velocity.y;
            }
            else
            {
                r.Vx = r.Vy = 0f;
            }
            r.Ground = p.onGround();
            r.Anim = p.aniStatus.ToString();
            r.Logic = p.logicStatus.ToString();
            r.Hp = p.health;
            r.Input = InputInjection.HeldNow();

            Near.Clear();
            CharacterManager cm = CharacterManager.Instance;
            if (cm != null && cm.characters != null && CameraScript.Instance != null)
            {
                foreach (CharacterBase c in cm.characters)
                {
                    if (c == null || c == p || c.t == null || c.health <= 0 || !c.gameObject.activeInHierarchy) continue;
                    if (Utility.isOutsideCamera(c.t.position, 64f)) continue;
                    Near.Add(new KeyValuePair<float, CharacterBase>((c.t.position - pos).sqrMagnitude, c));
                }
            }
            if (Near.Count > 1) Near.Sort((a, b) => a.Key.CompareTo(b.Key));
            r.EnemyCount = Math.Min(Near.Count, MaxEnemies);
            for (int i = 0; i < r.EnemyCount; i++)
            {
                CharacterBase c = Near[i].Value;
                r.Enemies[i] = new Enemy { Type = c.type.ToString(), Id = c.ID, Hp = c.health, X = c.t.position.x, Y = c.t.position.y, Anim = c.aniStatus.ToString(), Logic = c.logicStatus.ToString(), Stun = c.GetHitStun(), Armor = c.enemy_perfer != null ? c.GetToArmorPercent() : -1f, Recovering = c.enemy_perfer != null && c.enemy_perfer.inQuickArmorRecover };
            }

            NearBoxes.Clear();
            BulletManager bm = BulletManager.Instance;
            if (bm != null && bm.bullets_enable != null && CameraScript.Instance != null)
            {
                for (int i = 0; i < bm.bullets_enable.Length; i++)
                {
                    if (!bm.bullets_enable[i] || (bm.bullets_delay != null && i < bm.bullets_delay.Length && bm.bullets_delay[i] > 0)) continue;
                    bulletScript b = bm.GetBullet(i);
                    if (b == null || b.t == null || b.owner == p) continue;
                    Vector3 c = b.t.position + b.GetHOffset();
                    if (Utility.isOutsideCamera(c, 64f)) continue;
                    NearBoxes.Add(new KeyValuePair<float, bulletScript>((c - pos).sqrMagnitude, b));
                }
            }
            if (NearBoxes.Count > 1) NearBoxes.Sort((a, b) => a.Key.CompareTo(b.Key));
            r.BoxCount = Math.Min(NearBoxes.Count, MaxBoxes);
            for (int i = 0; i < r.BoxCount; i++)
            {
                bulletScript b = NearBoxes[i].Value;
                Vector3 c = b.t.position + b.GetHOffset();
                r.Boxes[i] = new Box { Type = b.type.ToString(), Owner = b.owner == null ? "none" : b.owner.type.ToString(), X = c.x, Y = c.y, W = b.GetHSizeW(), H = b.GetHSizeH() };
            }

            next = (next + 1) % Capacity;
            count = Math.Min(count + 1, Capacity);
            Watch.Stop();
            ticksTotal += Watch.ElapsedTicks;
            ticksFrames++;
            double ms = Watch.Elapsed.TotalMilliseconds;
            if (ms > worstMs) worstMs = ms;
        }

        // What recording costs per recorded frame: the plugin's own time in Record, not the game's.
        public static JObject Cost()
        {
            return new JObject
            {
                ["frames_recorded"] = ticksFrames,
                ["avg_ms"] = ticksFrames > 0 ? Math.Round(ticksTotal * 1000.0 / Stopwatch.Frequency / ticksFrames, 4) : 0,
                ["worst_ms"] = Math.Round(worstMs, 3),
            };
        }

        private static Row At(int back) => Rows[(next - 1 - back + Capacity * 2) % Capacity]; // back 0: the newest

        // The rows oldest first: at most `frames` recorded frames ending at `untilFrame` (or the newest), one every `every`.
        public static JObject Read(int frames, int every, int? untilFrame)
        {
            int end = 0; // how far back the newest row to read is
            if (untilFrame.HasValue)
            {
                while (end < count && At(end).Frame > untilFrame.Value) end++;
            }
            var picked = new List<Row>();
            for (int back = end; back < count && back < end + frames; back++) picked.Add(At(back));
            picked.Reverse();

            JObject answer = null;
            int used = every;
            while (true)
            {
                answer = Build(picked, used);
                answer["recorded"] = count;
                answer["cost"] = Cost();
                if (untilFrame.HasValue) answer["until_frame"] = untilFrame.Value;
                if (end >= count && count > 0) answer["note"] = "until_frame is before the oldest frame still recorded, " + At(count - 1).Frame;
                if (answer.ToString(Formatting.None).Length <= AnswerBudget || used >= 60) break;
                used *= 2;
            }
            if (used != every) answer["thinned"] = "every " + every + " did not fit the link's line, so every " + used;
            return answer;
        }

        private static JObject Build(List<Row> picked, int every)
        {
            var types = new List<string>();
            var rows = new JArray();
            for (int i = 0; i < picked.Count; i += every)
            {
                Row r = picked[i];
                var enemies = new JArray();
                for (int k = 0; k < r.EnemyCount; k++)
                {
                    Enemy e = r.Enemies[k];
                    enemies.Add(new JArray(TypeIndex(types, e.Type), e.Id, Math.Round(e.X, 1), Math.Round(e.Y, 1), e.Hp, TypeIndex(types, e.Anim), TypeIndex(types, e.Logic), Math.Round(e.Stun, 3), Math.Round(e.Armor, 3), e.Recovering ? 1 : 0));
                }
                var boxes = new JArray();
                for (int k = 0; k < r.BoxCount; k++)
                {
                    Box b = r.Boxes[k];
                    boxes.Add(new JArray(TypeIndex(types, b.Type), TypeIndex(types, b.Owner), Math.Round(b.X, 1), Math.Round(b.Y, 1), Math.Round(b.W, 1), Math.Round(b.H, 1)));
                }
                rows.Add(new JArray(r.Frame, r.Mode, Math.Round(r.X, 1), Math.Round(r.Y, 1), Math.Round(r.Vx, 2), Math.Round(r.Vy, 2), r.Ground ? 1 : 0, r.Anim, r.Logic, r.Hp, r.Input, enemies, boxes));
            }
            return new JObject
            {
                ["columns"] = new JArray("frame", "mode", "x", "y", "vx", "vy", "ground", "anim", "logic", "hp", "input", "near", "boxes"),
                ["near_columns"] = new JArray("type", "id", "x", "y", "hp", "anim", "logic", "hitstun_raw", "armor", "armor_recovering"),
                ["boxes_columns"] = new JArray("type", "owner", "x", "y", "width", "height"),
                ["types"] = new JArray(types.ToArray()),
                ["every"] = every,
                ["rows"] = rows,
            };
        }

        private static int TypeIndex(List<string> types, string name)
        {
            int i = types.IndexOf(name);
            if (i >= 0) return i;
            types.Add(name);
            return types.Count - 1;
        }

        // observe's trail, from the same record: the last `frames` recorded frames every `every`, [frame, x, y, on_ground, anim].
        public static JArray Trail(int frames, int every)
        {
            var arr = new JArray();
            int n = Math.Min(frames, count);
            for (int back = n - 1; back >= 0; back -= every)
            {
                Row r = At(back);
                arr.Add(new JArray(r.Frame, Math.Round(r.X, 1), Math.Round(r.Y, 1), r.Ground, r.Anim));
            }
            return arr;
        }
    }
}
