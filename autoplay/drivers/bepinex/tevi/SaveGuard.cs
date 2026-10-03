using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using ES3Internal;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // While armed, every save file the game or a mod opens is opened in autoplay/states/tevi/shadow/ instead, copied
    // fresh from the real folder as the guard arms, and the autosave is skipped. A shadow, not a refusal: a new game
    // reads back the slot pointer it just wrote, so a refused write loads another slot. Easy Save resolves every
    // relative save path through ES3Settings.FullPath, where a postfix redirects it; ES3IO's writes and deletes, and
    // the destination of its moves and copies, refuse a path left in the real folder. Without a repo there is no
    // shadow and the guard only refuses.
    //
    // It arms when a core first welcomes the driver and stays armed until the game exits, so a driver with no core
    // leaves ordinary play alone. Patched once per process and never removed, with its state in the AppDomain, so it
    // survives a hot reload without a gap; a change to this file needs a game restart.
    public static class SaveGuard
    {
        public const string HarmonyId = "dev.meshghost.autoplay.saveguard.shadow";
        private const string KeyArmed = "meshghost.autoplay.guard.armed";
        private const string KeyRoot = "meshghost.autoplay.guard.root";
        private const string KeyShadow = "meshghost.autoplay.guard.shadow";
        private const string KeyRedirected = "meshghost.autoplay.guard.redirected";
        private const string KeyRefused = "meshghost.autoplay.guard.refused";
        private const string KeyLastRefused = "meshghost.autoplay.guard.last_refused";
        private const string KeyAutosavesHeld = "meshghost.autoplay.guard.autosaves_held";
        private const string KeyLog = "meshghost.autoplay.guard.log";

        private static readonly object Gate = new object();

        // Records the real save folder and the shadow's (null without a repo) and patches unless an earlier copy has.
        public static string Install(string persistentDataPath, string shadowRoot)
        {
            AppDomain.CurrentDomain.SetData(KeyRoot, Normalize(persistentDataPath).TrimEnd('/'));
            if (!Armed) AppDomain.CurrentDomain.SetData(KeyShadow, shadowRoot == null ? null : Normalize(shadowRoot).TrimEnd('/'));
            if (Harmony.HasAnyPatches(HarmonyId))
            {
                return "save guard: patches already in place from an earlier copy of the driver; armed=" + Armed;
            }
            if (Harmony.HasAnyPatches("dev.meshghost.autoplay.saveguard"))
            {
                return "save guard: an OLDER guard (refusing, not shadowing) is patched into this process; restart the game";
            }
            var h = new Harmony(HarmonyId);
            var self = typeof(SaveGuard);
            h.Patch(AccessTools.PropertyGetter(typeof(ES3Settings), nameof(ES3Settings.FullPath)),
                postfix: new HarmonyMethod(self, nameof(FullPathPostfix)));
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

        public static string ShadowRoot => AppDomain.CurrentDomain.GetData(KeyShadow) as string;

        private static string RealRoot => AppDomain.CurrentDomain.GetData(KeyRoot) as string ?? "";

        // Copies the real save folder into a fresh shadow, then arms. The logs Unity keeps there and Steam's .vdf are
        // left out: they are not saves, and a log is tens of megabytes.
        public static string Arm()
        {
            if (Armed) return "save guard: already armed";
            string shadow = ShadowRoot, real = RealRoot;
            string how;
            if (shadow == null)
            {
                how = "REFUSING writes to " + real + " (no repo in the driver's config, so no shadow folder: a new game there loads the recent slot instead)";
            }
            else
            {
                if (Directory.Exists(shadow)) Directory.Delete(shadow, recursive: true);
                int files = 0;
                foreach (string src in Directory.GetFiles(real, "*", SearchOption.AllDirectories))
                {
                    string ext = Path.GetExtension(src).ToLowerInvariant();
                    if (ext == ".log" || ext == ".vdf") continue;
                    string rel = Normalize(src).Substring(real.Length).TrimStart('/');
                    string dst = shadow + "/" + rel;
                    Directory.CreateDirectory(Path.GetDirectoryName(dst));
                    File.Copy(src, dst);
                    files++;
                }
                Directory.CreateDirectory(shadow);
                how = "SHADOWING " + real + " in " + shadow + " (" + files + " files copied)";
            }
            AppDomain.CurrentDomain.SetData(KeyArmed, true);
            return "SAVE GUARD ARMED until the game exits: " + how + "; autosaves held";
        }

        public static JObject Report()
        {
            return new JObject
            {
                ["armed"] = Armed,
                ["shadow"] = ShadowRoot,
                ["paths_redirected"] = Count(KeyRedirected),
                ["writes_refused"] = Count(KeyRefused),
                ["last_refused"] = AppDomain.CurrentDomain.GetData(KeyLastRefused) as string,
                ["autosaves_held"] = Count(KeyAutosavesHeld),
            };
        }

        // Guard decisions since the last drain, for the plugin's log.
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
                if (line == null) return;
                var q = AppDomain.CurrentDomain.GetData(KeyLog) as List<string> ?? new List<string>();
                if (q.Count < 200) q.Add(line);
                AppDomain.CurrentDomain.SetData(KeyLog, q);
            }
        }

        private static string Normalize(string path) => (path ?? "").Replace('\\', '/');

        // The part of path under the real save folder ("" for the folder itself), or null when it is not in it.
        private static string UnderReal(string path)
        {
            string p = Normalize(path), real = RealRoot;
            if (real.Length == 0) return null;
            if (string.Equals(p.TrimEnd('/'), real, StringComparison.OrdinalIgnoreCase)) return "";
            return p.StartsWith(real + "/", StringComparison.OrdinalIgnoreCase) ? p.Substring(real.Length + 1) : null;
        }

        private static readonly HashSet<string> RedirectedOnce = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        private static void FullPathPostfix(ref string __result)
        {
            if (!Armed) return;
            string shadow = ShadowRoot;
            if (shadow == null) return;
            string rel = UnderReal(__result);
            if (rel == null) return;
            __result = rel.Length == 0 ? shadow : shadow + "/" + rel;
            bool first;
            lock (Gate) first = RedirectedOnce.Add(rel);
            if (first) Note(KeyRedirected, "shadowed " + (rel.Length == 0 ? "(the folder)" : rel));
        }

        private static bool Decide(string what, string path)
        {
            if (!Armed || UnderReal(path) == null) return true;
            lock (Gate) AppDomain.CurrentDomain.SetData(KeyLastRefused, what + " " + path);
            Note(KeyRefused, "REFUSED " + what + " " + path);
            return false;
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
