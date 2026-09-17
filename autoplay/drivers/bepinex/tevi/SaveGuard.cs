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
    // THE SAVE GUARD. While armed, TEVI's save folder is a SHADOW COPY: every file the game or a mod opens there, to read
    // or to write, is opened in autoplay/states/tevi/shadow/ instead, copied fresh from the real folder the moment the
    // guard arms. The real folder is never written, and the game still reads back what it wrote. The game's autosave
    // does not run at all. The user, 2026-09-17: the unmodded saves must never change, and the driver holds the autosave.
    //
    // WHY A SHADOW AND NOT A REFUSAL (measured 2026-09-17, agent_docs/phases/autoplay/tevi.md): the first guard refused
    // every write but autoplay's slot. A new game in slot 39 then writes "recent slot 39" to tevisystem.sav and, after
    // its scene reload, reads that pointer back to pick the slot to load; the refused write left it at 0, and the "new
    // game" loaded the player's autosave instead. A guard that changes what the game reads back breaks the thing it
    // guards. Redirecting keeps every read and write the game's own, only in another folder.
    //
    // Where it sits (names read from the Steam build's assemblies, 2026-09-17): Easy Save 3 resolves every relative save
    // path through ES3Settings.FullPath (persistentDataPath + "/" + path), and the game and the Randomizer save only
    // through ES3. A postfix on that getter rewrites any path in the real folder to the shadow's. ES3IO's own file
    // moves, writes and deletes then refuse any path still inside the real folder, as a backstop for a path that did
    // not come through FullPath. SaveManager.ReallyDoAutoSave is skipped. Without a repo in the driver's config there is
    // no shadow folder, and the guard falls back to refusing, with the new-game problem above: say so in the log.
    //
    // It ARMS when the driver first welcomes a core and stays armed until the game exits. A driver left in scripts\
    // with no core never arms, so ordinary play saves as usual. Restart the game to play normally after a session.
    //
    // It SURVIVES A HOT RELOAD. ScriptEngine loads a new copy of this assembly and destroys the old plugin; patches
    // removed and re-applied would leave a gap. So the patches are applied once per process (their Harmony id is checked
    // first) and never removed, and their state lives in the AppDomain's data, which every copy of this assembly reads.
    // Changing this file's code therefore needs a game restart to take effect.
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

        // Called by the plugin on Awake: records the real save folder and the shadow's (null without a repo) and applies
        // the patches if no copy of this assembly has. Returns what it did, for the log.
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

        // Copies the real save folder into a fresh shadow, then arms. The logs Unity keeps there are left out: they are
        // not saves, and one is tens of megabytes. Returns what it did, for the log.
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
