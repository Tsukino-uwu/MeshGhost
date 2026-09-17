using System;
using System.Collections.Generic;
using System.Reflection;
using ES3Internal;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // THE SAVE GUARD. While armed, nothing in this game process writes, moves or deletes a file in TEVI's save folder
    // except autoplay's own slot, and the game's autosave does not run at all. Asked for by the user 2026-09-17: the
    // driver holds the autosave off, and autoplay's saves go only to the slots granted it (vanilla 36-39, Randomizer
    // 36-80; this driver uses one, WorkingSlot). The unmodded saves are the ones that must never change.
    //
    // Where it sits (names read from the Steam build's assemblies, 2026-09-17; agent_docs/phases/autoplay/tevi.md):
    // every save the game and the Randomizer make is an ES3File whose Sync writes a ".tmp" that ES3IO.CommitBackup
    // then moves over the real file; a slot is deleted through ES3.DeleteFile. Sync and DeleteFile are refused for
    // any other file, so no stray .tmp is left beside a real save; ES3IO's own file moves are refused too, as a
    // backstop for a path this list does not know. SaveManager.ReallyDoAutoSave is skipped, which is where an
    // autosave writes slot 0, a backup slot and the recent-slot pointer.
    //
    // It ARMS when the driver first welcomes a core and stays armed until the game exits: once autoplay may have
    // changed the game, nothing of this process may reach the player's saves. A driver left in scripts\ with no core
    // never arms, so ordinary play saves as usual. Restart the game to play normally after a session.
    //
    // It SURVIVES A HOT RELOAD. ScriptEngine loads a new copy of this assembly and destroys the old plugin; patches
    // removed and re-applied would leave a gap in which an autosave could land. So the patches are applied once per
    // process (their Harmony id is checked first) and never removed, and their state -- armed, the allowed names,
    // the counts -- lives in the AppDomain's data, which every copy of this assembly reads. Changing this file's
    // code therefore needs a game restart to take effect; the log line on load says which copy is guarding.
    public static class SaveGuard
    {
        public const string HarmonyId = "dev.meshghost.autoplay.saveguard";
        private const string KeyArmed = "meshghost.autoplay.guard.armed";
        private const string KeyAllowed = "meshghost.autoplay.guard.allowed";
        private const string KeyRoot = "meshghost.autoplay.guard.root";
        private const string KeyRefused = "meshghost.autoplay.guard.refused";
        private const string KeyAllowedCount = "meshghost.autoplay.guard.allowed_count";
        private const string KeyLastRefused = "meshghost.autoplay.guard.last_refused";
        private const string KeyAutosavesHeld = "meshghost.autoplay.guard.autosaves_held";
        private const string KeyLog = "meshghost.autoplay.guard.log";

        private static readonly object Gate = new object();

        // Called by the plugin on Awake: applies the patches if no copy of this assembly has, and records the save
        // folder and the allowed names. Returns what it did, for the log.
        public static string Install(string persistentDataPath, IEnumerable<string> allowedRelativeNames)
        {
            var allowed = new List<string>();
            foreach (string n in allowedRelativeNames) allowed.Add(Normalize(n));
            AppDomain.CurrentDomain.SetData(KeyRoot, Normalize(persistentDataPath) + "/");
            AppDomain.CurrentDomain.SetData(KeyAllowed, allowed.ToArray());
            if (Harmony.HasAnyPatches(HarmonyId))
            {
                return "save guard: patches already in place from an earlier copy of the driver; armed=" + Armed;
            }
            var h = new Harmony(HarmonyId);
            var self = typeof(SaveGuard);
            h.Patch(AccessTools.Method(typeof(ES3File), nameof(ES3File.Sync), new[] { typeof(ES3Settings) }),
                prefix: new HarmonyMethod(self, nameof(SyncPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3), nameof(ES3.DeleteFile), new[] { typeof(ES3Settings) }),
                prefix: new HarmonyMethod(self, nameof(SettingsPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.CommitBackup), new[] { typeof(ES3Settings) }),
                prefix: new HarmonyMethod(self, nameof(SettingsPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.DeleteFile), new[] { typeof(string) }),
                prefix: new HarmonyMethod(self, nameof(FirstPathPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.WriteAllBytes), new[] { typeof(string), typeof(byte[]) }),
                prefix: new HarmonyMethod(self, nameof(FirstPathPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.DeleteDirectory), new[] { typeof(string) }),
                prefix: new HarmonyMethod(self, nameof(FirstPathPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.MoveFile), new[] { typeof(string), typeof(string) }),
                prefix: new HarmonyMethod(self, nameof(SecondPathPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.CopyFile), new[] { typeof(string), typeof(string) }),
                prefix: new HarmonyMethod(self, nameof(SecondPathPrefix)));
            h.Patch(AccessTools.Method(typeof(ES3IO), nameof(ES3IO.MoveDirectory), new[] { typeof(string), typeof(string) }),
                prefix: new HarmonyMethod(self, nameof(SecondPathPrefix)));
            h.Patch(AccessTools.Method(typeof(SaveManager), nameof(SaveManager.ReallyDoAutoSave)),
                prefix: new HarmonyMethod(self, nameof(AutoSavePrefix)));
            return "save guard: patches applied by this copy of the driver; armed=" + Armed;
        }

        public static bool Armed => AppDomain.CurrentDomain.GetData(KeyArmed) is bool b && b;

        public static void Arm()
        {
            AppDomain.CurrentDomain.SetData(KeyArmed, true);
        }

        public static JObject Report()
        {
            return new JObject
            {
                ["armed"] = Armed,
                ["allowed"] = new JArray(AppDomain.CurrentDomain.GetData(KeyAllowed) as string[] ?? new string[0]),
                ["writes_refused"] = Count(KeyRefused),
                ["writes_allowed"] = Count(KeyAllowedCount),
                ["last_refused"] = AppDomain.CurrentDomain.GetData(KeyLastRefused) as string,
                ["autosaves_held"] = Count(KeyAutosavesHeld),
            };
        }

        // Guard decisions since the last drain, for the plugin's log. Written from inside a save, read on the next frame.
        public static List<string> DrainLog()
        {
            lock (Gate)
            {
                var q = AppDomain.CurrentDomain.GetData(KeyLog) as List<string>;
                AppDomain.CurrentDomain.SetData(KeyLog, null);
                return q ?? new List<string>();
            }
        }

        private static int Count(string key) => AppDomain.CurrentDomain.GetData(key) is int n ? n : 0;

        private static void Note(string countKey, string line)
        {
            lock (Gate)
            {
                AppDomain.CurrentDomain.SetData(countKey, Count(countKey) + 1);
                var q = AppDomain.CurrentDomain.GetData(KeyLog) as List<string> ?? new List<string>();
                if (q.Count < 200) q.Add(line);
                AppDomain.CurrentDomain.SetData(KeyLog, q);
            }
        }

        private static string Normalize(string path) => (path ?? "").Replace('\\', '/');

        // Whether path is one of the allowed save files, or one of ES3's working copies of it (.tmp, .tmp.bak, .bac).
        public static bool IsAllowed(string path)
        {
            string p = Normalize(path);
            foreach (string suffix in new[] { ".tmp.bak", ".tmp", ".bac", ".bak" })
            {
                if (p.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                {
                    p = p.Substring(0, p.Length - suffix.Length);
                    break;
                }
            }
            string root = AppDomain.CurrentDomain.GetData(KeyRoot) as string ?? "";
            if (root.Length == 0 || !p.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return false;
            string rel = p.Substring(root.Length);
            foreach (string a in AppDomain.CurrentDomain.GetData(KeyAllowed) as string[] ?? new string[0])
            {
                if (string.Equals(rel, a, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static bool Decide(string what, string path)
        {
            if (!Armed) return true;
            if (IsAllowed(path))
            {
                Note(KeyAllowedCount, "allowed " + what + " " + path);
                return true;
            }
            lock (Gate) AppDomain.CurrentDomain.SetData(KeyLastRefused, what + " " + path);
            Note(KeyRefused, "REFUSED " + what + " " + path);
            return false;
        }

        private static string FullPath(ES3Settings settings)
        {
            try
            {
                return (settings ?? new ES3Settings()).FullPath;
            }
            catch (Exception e)
            {
                return "<no path: " + e.Message + ">";
            }
        }

        private static bool SyncPrefix(ES3File __instance, ES3Settings __0)
        {
            return Decide("ES3File.Sync", FullPath(__0 ?? __instance.settings));
        }

        private static bool SettingsPrefix(MethodBase __originalMethod, ES3Settings __0)
        {
            return Decide(__originalMethod.DeclaringType.Name + "." + __originalMethod.Name, FullPath(__0));
        }

        private static bool FirstPathPrefix(MethodBase __originalMethod, string __0)
        {
            return Decide(__originalMethod.DeclaringType.Name + "." + __originalMethod.Name, __0);
        }

        private static bool SecondPathPrefix(MethodBase __originalMethod, string __1)
        {
            return Decide(__originalMethod.DeclaringType.Name + "." + __originalMethod.Name, __1);
        }

        private static bool AutoSavePrefix()
        {
            if (!Armed) return true;
            // What the skipped method would have cleared, so the game does not ask again every frame.
            MainVar.instance._isAutoSave = false;
            Note(KeyAutosavesHeld, "HELD an autosave (SaveManager.ReallyDoAutoSave skipped) at frame " + Time.frameCount);
            return false;
        }
    }
}
