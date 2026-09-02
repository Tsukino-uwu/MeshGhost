using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using BepInEx;

namespace MeshGhostTevi
{
    // Starts meshghost.exe alongside TEVI, and takes it down again with the game.
    //
    // MeshGhost is meant to feel like part of starting the game, not a second program the player
    // has to remember. Pseudoregalia's mod has done this since 2026-08-16 (CoreLauncher.cpp,
    // confirmed working under Proton with a Linux tester); this is the same design in C#, and the
    // decisions below are its decisions -- they were paid for once already and are not re-derived
    // here.
    //
    // AUTO-CLOSE is the half that is easy to forget. The child gets -exit-with-pid=<our pid>, so it
    // exits on its own if this process dies in any way at all, including a crash where no shutdown
    // hook runs. Stop() is the clean path on a normal quit: killing it there means the player's
    // ghost leaves the room immediately rather than when the relay's idle timeout eventually
    // notices. Belt and braces, because a leftover core holds the bridge port and the next launch
    // then attaches to a core with no game behind it.
    internal sealed class CoreLauncher
    {
        // Opting out is a supported configuration, not a debug switch: an antivirus that objects to
        // one program starting another is a real thing that happens to real players, and the
        // documented answer is to set this and start the core yourself.
        private const string NoAutostartEnv = "MESHGHOST_NO_AUTOSTART";

        // A core needs a moment to bind its listener. Spawning again before then is how you end up
        // with a pile of processes fighting over one port.
        private static readonly TimeSpan SpawnCooldown = TimeSpan.FromSeconds(5);

        private readonly Action<string> log;
        private Process child;
        // The port the child was told to serve. The walk moving off it is the signal below.
        private int childPort;
        private DateTime lastSpawn = DateTime.MinValue;
        private bool disabled;
        private bool loggedReuse;

        internal CoreLauncher(Action<string> log)
        {
            this.log = log;
        }

        // Called every frame while the bridge is NOT connected. Cheap: it returns immediately in
        // every case except the one where a spawn is actually due.
        internal void TickDisconnected(int bridgePort, int lastBusyPort)
        {
            // OUR OWN CHILD'S PORT ANSWERED "BUSY" WHILE THE CHILD IS STILL ALIVE. That means
            // another game reached it first (two copies launched close together: the second's
            // core bound the shared base port before the first's, and the first attached to it).
            // "My child is running" was read as "I have a core" and no spawn ever followed, so the
            // walk found silence on every other port and looped forever -- the standalone copy
            // sat like that for minutes on 2026-09-02. The child is not killed: a game is using
            // it. It is FORGOTTEN, so a fresh core is started at the cursor.
            //
            // ONLY on "busy", never because the cursor moved on: the first version of this also
            // forgot the child when the walk left its port on silence, and two instances
            // restarting together then chased each other's fresh cores round the range (watched
            // on Emerald the same night: three cores for two games).
            if (ChildStillRunning() && childPort != 0 && lastBusyPort == childPort)
            {
                log($"MeshGhost: the core this adapter started (pid {child.Id}, port {childPort}) is serving " +
                    $"another game -- leaving it to that game and starting another on port {bridgePort}.");
                child = null;
                childPort = 0;
            }
            if (disabled || ChildStillRunning())
            {
                return;
            }
            if (DateTime.UtcNow - lastSpawn < SpawnCooldown)
            {
                return;
            }

            if (Environment.GetEnvironmentVariable(NoAutostartEnv) != null)
            {
                disabled = true;
                log($"MeshGhost: {NoAutostartEnv} is set -- not starting a core. Start meshghost.exe yourself.");
                return;
            }
            if (ConfigSaysNoAutostart())
            {
                disabled = true;
                log("MeshGhost: \"autostart\": false in config.json -- not starting a core. Start meshghost.exe yourself.");
                return;
            }

            string exe = FindCoreExe();
            if (exe == null)
            {
                // Said once, not every frame, and it names the folder rather than the failure:
                // "meshghost.exe not found" with no location is the least useful form of this.
                disabled = true;
                log("MeshGhost: meshghost.exe is not beside this plugin -- not starting a core. " +
                    "It should sit in the same MeshGhost folder as MeshGhostTevi.dll, alongside " +
                    "config.json; if it was there, check whether antivirus removed it.");
                return;
            }

            lastSpawn = DateTime.UtcNow;
            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = exe,
                    // No relay settings passed. The child reads config.json out of its own
                    // directory, which is the file a player edits -- passing -relay here would
                    // silently override it and make that file look broken.
                    Arguments = $"-exit-with-pid={Process.GetCurrentProcess().Id} -bridge=127.0.0.1:{bridgePort}",
                    WorkingDirectory = Path.GetDirectoryName(exe),
                    // The console app never gets a console at all, so there is no window to flash
                    // and hide. A player who wants one back sets show_console in config.json, which
                    // the core acts on itself by allocating one after the fact.
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                child = Process.Start(startInfo);
                childPort = bridgePort;
                log($"MeshGhost: started a core ({Path.GetFileName(exe)}, pid {child?.Id}) on bridge port {bridgePort}.");
            }
            catch (Exception e)
            {
                child = null;
                log($"MeshGhost: could not start meshghost.exe: {e.Message}");
            }
        }

        // Called once per connection. "Did it start its own core or find mine?" is the first
        // question worth asking when someone reports two processes or a stale config, and with no
        // console window anywhere this log line is where they would look.
        internal void TickConnected()
        {
            if (child == null && !loggedReuse)
            {
                loggedReuse = true;
                log("MeshGhost: using a core that was already running.");
            }
        }

        internal void Stop()
        {
            if (!ChildStillRunning())
            {
                child = null;
                return;
            }
            try
            {
                child.Kill();
                log("MeshGhost: stopped the core it started.");
            }
            catch (Exception e)
            {
                // Not worth failing a shutdown over -- -exit-with-pid gets it a moment later.
                log($"MeshGhost: could not stop the core ({e.Message}); it will exit on its own.");
            }
            child = null;
        }

        private bool ChildStillRunning()
        {
            try
            {
                return child != null && !child.HasExited;
            }
            catch (InvalidOperationException)
            {
                // Never started, or already reaped.
                return false;
            }
        }

        // Resolved from THIS ASSEMBLY's location, not the working directory and not the game's
        // install path. Neither of those is reliable: the plugin is dropped into the game's
        // BepInEx/plugins tree, and a game's working directory is whatever its launcher chose. The
        // one thing that is always true is that meshghost.exe ships beside this DLL.
        // Where the bridge port range starts, from the config.json the player actually edits.
        //
        // Until 2026-08-28 this adapter's only port setting was BepInEx's own BridgePort, so
        // "local_game_bridge" in config.json moved the CORE and not the adapter, and the two then
        // never found each other -- the setting did not fail loudly, it silently broke the
        // connection. Reported on Pseudoregalia as "setting the config to 7780 it still starts at
        // 7778"; the same defect, in a different language, and all four adapters had a version.
        //
        // Searched in CoreSearchDirs order, because config.json travels WITH meshghost.exe --
        // "the client reads the config.json in its own folder" is what every game's README says,
        // so the first directory holding the exe is the one holding the config that governs it.
        //
        // Parsed by hand rather than with a JSON library: the shape is fixed ("host:port", quoted)
        // and this assembly deliberately carries no JSON dependency. Anything unrecognised falls
        // through to the caller's fallback rather than throwing.
        // "autostart": false in the config.json beside meshghost.exe says "do not start a client;
        // use whichever one is running". The user's call 2026-09-03: the environment variable
        // above did the same job, but "environment variable" means nothing to most players and
        // a line in the file they already edit does. Same search order and the same hand parse
        // as ResolveBridgeBasePort, for the same reasons; absent, or anything but false, means
        // autostart. The variable still works -- either one saying no is a no.
        public static bool ConfigSaysNoAutostart()
        {
            try
            {
                foreach (string dir in CoreSearchDirs())
                {
                    if (string.IsNullOrEmpty(dir))
                    {
                        continue;
                    }
                    string cfg = Path.Combine(dir, "config.json");
                    if (!File.Exists(cfg))
                    {
                        continue;
                    }
                    return Regex.IsMatch(File.ReadAllText(cfg), "\"autostart\"\\s*:\\s*false");
                }
            }
            catch
            {
            }
            return false;
        }

        public static int ResolveBridgeBasePort(int fallback)
        {
            // The environment wins, and it is the same variable name the two Lua adapters use, so
            // one launcher setting moves every game's range the same way.
            try
            {
                string env = Environment.GetEnvironmentVariable("MESHGHOST_BRIDGE_PORT");
                if (!string.IsNullOrEmpty(env)
                    && int.TryParse(env, out int fromEnv)
                    && fromEnv >= 1 && fromEnv <= 65535)
                {
                    return fromEnv;
                }
            }
            catch
            {
            }

            try
            {
                foreach (string dir in CoreSearchDirs())
                {
                    if (string.IsNullOrEmpty(dir))
                    {
                        continue;
                    }
                    string cfg = Path.Combine(dir, "config.json");
                    if (!File.Exists(cfg))
                    {
                        continue;
                    }
                    Match m = Regex.Match(
                        File.ReadAllText(cfg),
                        "\"local_game_bridge\"\\s*:\\s*\"[^\"]*:(\\d+)\"");
                    if (m.Success
                        && int.TryParse(m.Groups[1].Value, out int port)
                        && port >= 1 && port <= 65535)
                    {
                        return port;
                    }
                    // The first config.json found wins even without the key: a later one belongs
                    // to a different install, and silently preferring it is worse than the default.
                    break;
                }
            }
            catch
            {
            }

            return fallback;
        }

        private static string FindCoreExe()
        {
            try
            {
                foreach (string dir in CoreSearchDirs())
                {
                    if (string.IsNullOrEmpty(dir))
                    {
                        continue;
                    }
                    string exe = Path.Combine(dir, "meshghost.exe");
                    if (File.Exists(exe))
                    {
                        return exe;
                    }
                }
                return null;
            }
            catch
            {
                return null;
            }
        }

        // Beside this assembly first, which is the shipping case and the only one a player ever
        // hits. The rest exist because of ONE dev-only fact, measured 2026-08-28: BepInEx's
        // ScriptEngine (the hot-reload tool, dev-scripts/tevi-hotreload.ps1) loads a plugin from
        // BYTES, so Assembly.Location is the EMPTY STRING and "beside this assembly" resolves to
        // nowhere. The adapter then correctly reported that no core sat beside it and declined to
        // start one -- which is right, and left the whole hot-reload loop unable to autostart.
        //
        // Deliberately NOT a scan: each entry is a specific place meshghost.exe legitimately is.
        // Paths.* are BepInEx's own; a wrong name here is a build error, not a silent miss, since
        // this project compiles against BepInEx.Core (agent_docs/access-models.md).
        private static IEnumerable<string> CoreSearchDirs()
        {
            string here = null;
            try { here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); }
            catch { }
            yield return here;

            // An explicit override wins over any guess, and is the escape hatch if a future
            // loader breaks all of the below.
            yield return Environment.GetEnvironmentVariable("MESHGHOST_CORE_DIR");

            // Where tevi-hotreload.ps1 puts the core in hot-reload mode.
            yield return Path.Combine(Paths.BepInExRootPath, "scripts");
            // And where the shipping layout puts it, for a hot-reloaded build whose core was
            // never copied across.
            yield return Path.Combine(Paths.PluginPath, "MeshGhostTevi");
            yield return Path.Combine(Paths.PluginPath, "MeshGhost");
        }
    }
}
