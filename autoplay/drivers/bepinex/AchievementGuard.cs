using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;
using Newtonsoft.Json.Linq;

namespace MeshGhostAutoplay
{
    // THE ACHIEVEMENT GUARD, for any BepInEx game autoplay drives. The user, 2026-09-17, after TEVI unlocked "Squeak By" during
    // an autoplay fight: autoplay must never unlock achievements, "for any autoplay game/things that run on steam".
    //
    // While a driver is loaded, every call that unlocks an achievement or sends stats to the platform is skipped: the Steam
    // libraries' own entry points, whichever the game ships (Steamworks.NET's SteamUserStats, Facepunch.Steamworks'
    // SteamUserStats and Achievement.Trigger; names from their public APIs), and the game's own unlock methods the plugin
    // names (TEVI's GemaSteamAPIAchievements.UnlockAchievement and GemaSteamAPIAccess.TrySyncAchievements, names read from its
    // assembly). A skipped call returns its type's default (false for a bool), as if the platform had refused it.
    //
    // It is ARMED FROM THE MOMENT THE DRIVER LOADS, not when a core connects (the save guard's moment): an unlock between the two
    // would already be on the account. Like the save guard it survives a hot reload: the patches are applied once per process
    // and never removed, and the count lives in the AppDomain's data. A game restart without the driver plays normally.
    public static class AchievementGuard
    {
        public const string HarmonyId = "dev.meshghost.autoplay.achievementguard";
        private const string KeySkipped = "meshghost.autoplay.achievements.skipped";
        private const string KeyLast = "meshghost.autoplay.achievements.last";
        private const string KeyPatched = "meshghost.autoplay.achievements.patched";

        // The Steam libraries' calls that unlock or upload, by type full name.
        private static readonly Dictionary<string, string[]> SteamCalls = new Dictionary<string, string[]>
        {
            // Steamworks.NET and Facepunch.Steamworks both name their static class Steamworks.SteamUserStats.
            ["Steamworks.SteamUserStats"] = new[] { "SetAchievement", "StoreStats", "IndicateAchievementProgress", "SetStat", "AddStat", "UpdateAvgRateStat" },
            ["Steamworks.Data.Achievement"] = new[] { "Trigger" },
            ["Steamworks.Data.Stat"] = new[] { "Set", "Add", "UpdateAverageRate", "Store" },
        };

        // Applies the patches if no copy of this assembly has, to the Steam calls above and to `gameCalls` ("Type.Method", any
        // overload). Returns what it did, for the log.
        public static string Install(IEnumerable<string> gameCalls)
        {
            if (Harmony.HasAnyPatches(HarmonyId))
            {
                return "achievement guard: already in place from an earlier copy of the driver (" + (AppDomain.CurrentDomain.GetData(KeyPatched) as string) + ")";
            }
            var targets = new Dictionary<string, string[]>(SteamCalls);
            foreach (string call in gameCalls)
            {
                int dot = call.LastIndexOf('.');
                if (dot > 0) targets[call.Substring(0, dot)] = Append(targets, call.Substring(0, dot), call.Substring(dot + 1));
            }
            var h = new Harmony(HarmonyId);
            var patched = new List<string>();
            var prefix = new HarmonyMethod(typeof(AchievementGuard), nameof(Skip));
            foreach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                foreach (var kv in targets)
                {
                    Type t;
                    try
                    {
                        t = asm.GetType(kv.Key, false);
                    }
                    catch (Exception)
                    {
                        continue;
                    }
                    if (t == null) continue;
                    foreach (MethodInfo m in t.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance | BindingFlags.DeclaredOnly))
                    {
                        if (Array.IndexOf(kv.Value, m.Name) < 0 || m.IsAbstract || m.ContainsGenericParameters) continue;
                        try
                        {
                            h.Patch(m, prefix: prefix);
                            patched.Add(t.FullName + "." + m.Name + " (" + asm.GetName().Name + ")");
                        }
                        catch (Exception e)
                        {
                            patched.Add("FAILED " + t.FullName + "." + m.Name + ": " + e.Message);
                        }
                    }
                }
            }
            string list = patched.Count == 0 ? "nothing found to patch" : string.Join(", ", patched.ToArray());
            AppDomain.CurrentDomain.SetData(KeyPatched, list);
            return "ACHIEVEMENT GUARD armed while the driver is loaded: " + list;
        }

        private static string[] Append(Dictionary<string, string[]> targets, string type, string method)
        {
            var list = new List<string>(targets.TryGetValue(type, out string[] have) ? have : new string[0]) { method };
            return list.ToArray();
        }

        private static bool Skip(MethodBase __originalMethod)
        {
            int n = AppDomain.CurrentDomain.GetData(KeySkipped) is int c ? c : 0;
            AppDomain.CurrentDomain.SetData(KeySkipped, n + 1);
            AppDomain.CurrentDomain.SetData(KeyLast, __originalMethod.DeclaringType?.Name + "." + __originalMethod.Name + " at " + DateTime.Now.ToString("HH:mm:ss"));
            return false;
        }

        public static JObject Report()
        {
            return new JObject
            {
                ["skipped"] = AppDomain.CurrentDomain.GetData(KeySkipped) is int c ? c : 0,
                ["last_skipped"] = AppDomain.CurrentDomain.GetData(KeyLast) as string,
                ["patched"] = AppDomain.CurrentDomain.GetData(KeyPatched) as string,
            };
        }
    }
}
