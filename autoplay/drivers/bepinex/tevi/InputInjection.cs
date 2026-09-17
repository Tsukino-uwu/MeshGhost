using System;
using System.Collections.Generic;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using Rewired;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // PRESS: input the game reads as its own. TEVI reads every button and axis through Rewired's Player (its
    // InputButtonManager and InputAxisManager wrap it, and other code calls it directly; names read from the Steam
    // build's assemblies, 2026-09-17), so a postfix on Player's read methods reaches every caller the same way. A
    // held action is ORed with the real controller: nothing the player presses is lost.
    //
    // A hold is by frame number, never by call order: an action held from frame S for N frames reads held on frames
    // S to S+N-1, "down" on S and "up" on S+N, whichever script asks and however often in a frame. An axis action is
    // named with a sign ("XAxis-" for -1); a button action by its name. The names are the game's own, read from
    // Rewired at runtime (observe's input_actions).
    //
    // WHILE A PRESS RUNS THIS DRIVER HOLDS INPUT. Unlike the save guard these patches go with the plugin: removed in
    // OnDestroy and applied again by the next copy after a hot reload.
    public static class InputInjection
    {
        public const string HarmonyId = "dev.meshghost.autoplay.input";

        private struct Hold
        {
            public int ActionId;
            public float Value;
            public int Start;
            public int End; // first frame not held
        }

        private static readonly List<Hold> Holds = new List<Hold>();
        private static Dictionary<string, int> idsByName;
        private static Harmony harmony;

        public static void Install()
        {
            if (harmony != null) return;
            harmony = new Harmony(HarmonyId);
            var self = typeof(InputInjection);
            // Each read has an id overload and a name overload: <postfix>Id and <postfix>Name below.
            PatchPair("GetButton", "ButtonPostfix");
            PatchPair("GetButtonDown", "ButtonDownPostfix");
            PatchPair("GetButtonUp", "ButtonUpPostfix");
            PatchPair("GetButtonRepeating", "ButtonDownPostfix");
            PatchPair("GetNegativeButton", "NegativeButtonPostfix");
            PatchPair("GetNegativeButtonDown", "NegativeButtonDownPostfix");
            PatchPair("GetAxis", "AxisPostfix");
            PatchPair("GetAxisRaw", "AxisPostfix");
            harmony.Patch(AccessTools.Method(typeof(Player), nameof(Player.GetAnyButton)), postfix: new HarmonyMethod(self, nameof(AnyButtonPostfix)));
        }

        private static void PatchPair(string method, string postfix)
        {
            var self = typeof(InputInjection);
            harmony.Patch(AccessTools.Method(typeof(Player), method, new[] { typeof(int) }), postfix: new HarmonyMethod(self, postfix + "Id"));
            harmony.Patch(AccessTools.Method(typeof(Player), method, new[] { typeof(string) }), postfix: new HarmonyMethod(self, postfix + "Name"));
        }

        public static void Uninstall()
        {
            harmony?.UnpatchSelf();
            harmony = null;
            Holds.Clear();
            MuteReal = false;
        }

        // Whether the game hears the keyboard and mouse while unfocused, read only. The user, 2026-09-17: a TEVI started
        // while another window had focus took typing from that window (dialogue advanced, the pause menu opened), until
        // its own window had been clicked once and left; after that it ignored input while unfocused. A hold above is
        // added after Rewired's read, so it reaches the game either way.
        public static JObject FocusReport()
        {
            if (!ReInput.isReady) return null;
            return new JObject
            {
                ["ignore_input_when_unfocused_raw"] = ReInput.configuration.ignoreInputWhenAppNotInFocus,
                ["application_focused_raw"] = Application.isFocused,
                ["real_input_muted"] = MuteReal,
            };
        }

        public static bool Busy => Holds.Count > 0;

        // The game's Rewired actions as it defines them: id, name, and whether an axis.
        public static JArray Actions()
        {
            var arr = new JArray();
            if (!ReInput.isReady) return arr;
            foreach (InputAction a in ReInput.mapping.Actions)
            {
                arr.Add(new JObject { ["id"] = a.id, ["name"] = a.name, ["type"] = a.type.ToString() });
            }
            return arr;
        }

        // Schedules buttons for frames from the next frame on. Returns an error, or null and the first frame after the
        // release frame, when the press has been seen through.
        public static string Schedule(IList<string> buttons, int frames, out int doneFrame)
        {
            doneFrame = 0;
            if (!ReInput.isReady) return "Rewired is not ready yet";
            if (Holds.Count > 0) return "a press is still running";
            var parsed = new List<Hold>();
            int start = Time.frameCount + 1;
            string err = Parse(buttons, start, frames, parsed);
            if (err != null) return err;
            Holds.AddRange(parsed);
            doneFrame = start + frames + 1;
            return null;
        }

        // Names to holds from `start` for `frames`, added to `into`; an error names what is wrong, and adds nothing more.
        private static string Parse(IList<string> buttons, int start, int frames, List<Hold> into)
        {
            foreach (string raw in buttons)
            {
                string name = (raw ?? "").Trim();
                float value = 1f;
                if (name.EndsWith("+") || name.EndsWith("-"))
                {
                    value = name.EndsWith("-") ? -1f : 1f;
                    name = name.Substring(0, name.Length - 1);
                }
                InputAction action = Find(name);
                if (action == null)
                {
                    var names = new List<string>();
                    foreach (InputAction a in ReInput.mapping.Actions) names.Add(a.type == InputActionType.Axis ? a.name + "+/-" : a.name);
                    return "no action named \"" + raw + "\"; the game's actions: " + string.Join(", ", names.ToArray());
                }
                bool signed = raw.Trim().EndsWith("+") || raw.Trim().EndsWith("-");
                if (action.type == InputActionType.Axis && !signed)
                {
                    return "\"" + action.name + "\" is an axis: name it " + action.name + "+ or " + action.name + "-";
                }
                if (action.type != InputActionType.Axis && signed && value < 0)
                {
                    return "\"" + action.name + "\" is a button, which has no negative side";
                }
                into.Add(new Hold { ActionId = action.id, Value = value, Start = start, End = start + frames });
            }
            return null;
        }

        // A SEQUENCE: several holds, each from its own offset after the next frame, overlapping as they like. All are checked
        // before any is scheduled. Returns an error, or null and the first frame after the last release.
        public static string ScheduleSequence(IList<KeyValuePair<IList<string>, KeyValuePair<int, int>>> steps, out int doneFrame)
        {
            doneFrame = 0;
            if (!ReInput.isReady) return "Rewired is not ready yet";
            if (Holds.Count > 0) return "a press is still running";
            var all = new List<Hold>();
            int start = Time.frameCount + 1, end = start;
            foreach (var step in steps)
            {
                int from = step.Value.Key, frames = step.Value.Value;
                string err = Parse(step.Key, start + from, frames, all);
                if (err != null) return err;
                end = Math.Max(end, start + from + frames);
            }
            Holds.AddRange(all);
            doneFrame = end + 1;
            return null;
        }

        // A REFLEX's input, decided each frame for the next: Keep holds an action on the next frame, extending a hold that is on
        // now (so the game sees one long hold, never a fresh press), or starting one; Tap presses it for `frames` from the next
        // frame, only when nothing holds it now or ends on the next frame (so each tap reads as its own press). Keep returns
        // false for an action the game does not have; Tap returns true only when it began a new press.
        public static bool Keep(string name)
        {
            if (!TryAction(name, out int id, out float value)) return false;
            int f = Time.frameCount;
            for (int i = 0; i < Holds.Count; i++)
            {
                Hold h = Holds[i];
                if (h.ActionId == id && h.Value == value && h.End == f + 1)
                {
                    h.End = f + 2;
                    Holds[i] = h;
                    return true;
                }
            }
            Holds.Add(new Hold { ActionId = id, Value = value, Start = f + 1, End = f + 2 });
            return true;
        }

        public static bool Tap(string name, int frames)
        {
            if (!TryAction(name, out int id, out float value)) return false;
            int f = Time.frameCount;
            foreach (Hold h in Holds)
            {
                if (h.ActionId == id && h.End >= f) return false; // still held or just released: no new press this frame
            }
            Holds.Add(new Hold { ActionId = id, Value = value, Start = f + 1, End = f + 1 + frames });
            return true;
        }

        // A quickdrop, as a reflex's input for the next frame: Down held, and Jump pressed only once Down has been held QuickdropDownFirst
        // frames. Pressed on the same frame, the game took Down and Jump for a double jump and threw her up (every one of five double
        // jumps in the flight recorder began with both on one frame; every quickdrop had Down held two frames or more first, 2026-09-17,
        // Ribauld on Infernal BBQ, where the jump carried her into his charge). Returns true when Jump was pressed.
        private const int QuickdropDownFirst = 2, QuickdropPress = 4;

        public static bool Quickdrop()
        {
            if (!Keep("YAxis-") || !TryAction("YAxis-", out int id, out float value)) return false;
            int f = Time.frameCount;
            foreach (Hold h in Holds)
            {
                if (h.ActionId != id || h.Value != value || h.End != f + 2 || f + 1 - h.Start < QuickdropDownFirst) continue;
                if (!Tap("Jump", QuickdropPress)) return false;
                // Down stays held through the whole press: let go a frame after it began (the dodge changing its plan), the rest of the
                // press read as a jump in the air and made a double jump (1272795, the same fight).
                for (int i = 0; i < Holds.Count; i++)
                {
                    Hold d = Holds[i];
                    if (d.ActionId == id && d.Value == value && d.End == f + 2)
                    {
                        d.End = Math.Max(d.End, f + 1 + QuickdropPress);
                        Holds[i] = d;
                    }
                }
                return true;
            }
            return false;
        }

        private static bool TryAction(string name, out int id, out float value)
        {
            id = -1;
            value = 1f;
            if (!ReInput.isReady || string.IsNullOrEmpty(name)) return false;
            if (name.EndsWith("+") || name.EndsWith("-"))
            {
                value = name.EndsWith("-") ? -1f : 1f;
                name = name.Substring(0, name.Length - 1);
            }
            InputAction a = Find(name);
            if (a == null) return false;
            id = a.id;
            return true;
        }

        // Ends every hold now: one still held is let go on the next frame (so the game sees it released), and one not begun
        // is dropped. Returns how many were cut.
        public static int CutShort()
        {
            int f = Time.frameCount, cut = 0;
            for (int i = Holds.Count - 1; i >= 0; i--)
            {
                Hold h = Holds[i];
                if (h.Start > f)
                {
                    Holds.RemoveAt(i);
                    cut++;
                }
                else if (h.End > f + 1)
                {
                    h.End = f + 1;
                    Holds[i] = h;
                    cut++;
                }
            }
            return cut;
        }

        // Called every frame by the plugin: a hold whose release frame has passed is forgotten.
        public static void Expire()
        {
            int f = Time.frameCount;
            Holds.RemoveAll(h => f > h.End);
        }

        private static InputAction Find(string name)
        {
            foreach (InputAction a in ReInput.mapping.Actions)
            {
                if (string.Equals(a.name, name, StringComparison.OrdinalIgnoreCase)) return a;
            }
            return null;
        }

        private static int IdOf(string name)
        {
            if (idsByName == null)
            {
                if (!ReInput.isReady) return -1;
                idsByName = new Dictionary<string, int>(StringComparer.Ordinal);
                foreach (InputAction a in ReInput.mapping.Actions) idsByName[a.name] = a.id;
            }
            return name != null && idsByName.TryGetValue(name, out int id) ? id : -1;
        }

        // The injected value of an action on this frame: +1 or -1 while held, 0 otherwise.
        private static float Held(int actionId)
        {
            int f = Time.frameCount;
            foreach (Hold h in Holds)
            {
                if (h.ActionId == actionId && f >= h.Start && f < h.End) return h.Value;
            }
            return 0f;
        }

        // How many frames after this one a hold of the action still runs (0 when none does).
        public static int FramesLeft(string name)
        {
            if (!TryAction(name, out int id, out float _)) return 0;
            int f = Time.frameCount, left = 0;
            foreach (Hold h in Holds)
            {
                if (h.ActionId == id && h.Start <= f + 1) left = Math.Max(left, h.End - f - 1);
            }
            return left;
        }

        // The driver's holds on this frame by name, an axis with its sign ("XAxis+ Jump"); empty when none.
        public static string HeldNow()
        {
            if (Holds.Count == 0 || !ReInput.isReady) return "";
            int f = Time.frameCount;
            var names = new List<string>();
            foreach (Hold h in Holds)
            {
                if (f < h.Start || f >= h.End) continue;
                InputAction a = ReInput.mapping.GetAction(h.ActionId);
                string n = a == null ? h.ActionId.ToString() : a.type == InputActionType.Axis ? a.name + (h.Value < 0 ? "-" : "+") : a.name;
                if (!names.Contains(n)) names.Add(n);
            }
            return string.Join(" ", names.ToArray());
        }

        // Whether a hold of this action on this side (sign) begins, or is released, on this frame.
        private static bool Edge(int actionId, float sign, bool release)
        {
            int f = Time.frameCount;
            foreach (Hold h in Holds)
            {
                if (h.ActionId == actionId && Mathf.Sign(h.Value) == sign && f == (release ? h.End : h.Start)) return true;
            }
            return false;
        }

        // While true, what Rewired reads from the real keyboard, mouse and pads is dropped before the holds above are added:
        // the plugin sets it each frame while the save guard is armed (a core has connected since launch; mcpcall drops the link
        // between calls) and the game's window is not focused. The user, 2026-09-17:
        // after a restore reloads the game it takes typing from other windows again (the pause menu opened mid-press) until
        // its window is focused and left once more. Focused, the player's own input reaches the game as always.
        public static bool MuteReal;

        private static void ButtonPostfixId(int __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0 && Held(__0) > 0f) __result = true; }
        private static void ButtonPostfixName(string __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0) ButtonPostfixId(IdOf(__0), ref __result); }

        private static void ButtonDownPostfixId(int __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0 && Edge(__0, 1f, false)) __result = true; }
        private static void ButtonDownPostfixName(string __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0) ButtonDownPostfixId(IdOf(__0), ref __result); }

        private static void ButtonUpPostfixId(int __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0 && Edge(__0, 1f, true)) __result = true; }
        private static void ButtonUpPostfixName(string __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0) ButtonUpPostfixId(IdOf(__0), ref __result); }

        private static void NegativeButtonPostfixId(int __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0 && Held(__0) < 0f) __result = true; }
        private static void NegativeButtonPostfixName(string __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0) NegativeButtonPostfixId(IdOf(__0), ref __result); }

        private static void NegativeButtonDownPostfixId(int __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0 && Edge(__0, -1f, false)) __result = true; }
        private static void NegativeButtonDownPostfixName(string __0, ref bool __result) { if (MuteReal) __result = false; if (!__result && Holds.Count > 0) NegativeButtonDownPostfixId(IdOf(__0), ref __result); }

        private static void AxisPostfixId(int __0, ref float __result)
        {
            if (MuteReal) __result = 0f;
            if (Holds.Count == 0) return;
            float v = Held(__0);
            if (v != 0f && Mathf.Abs(v) > Mathf.Abs(__result)) __result = v;
        }
        private static void AxisPostfixName(string __0, ref float __result) { if (MuteReal) __result = 0f; if (Holds.Count > 0) AxisPostfixId(IdOf(__0), ref __result); }

        private static void AnyButtonPostfix(ref bool __result)
        {
            if (MuteReal) __result = false;
            if (__result || Holds.Count == 0) return;
            int f = Time.frameCount;
            foreach (Hold h in Holds)
            {
                if (f >= h.Start && f < h.End && h.Value > 0f)
                {
                    __result = true;
                    return;
                }
            }
        }
    }
}
