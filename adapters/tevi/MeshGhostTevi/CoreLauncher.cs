using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using BepInEx;

namespace MeshGhostTevi
{
    // Starts meshghost.exe alongside TEVI and takes it down with the game. The child gets -exit-with-pid, so it exits
    // even after a crash that runs no shutdown hook; Stop() on a clean quit makes the ghost leave the room at once. A
    // leftover core would hold the bridge port, and the next launch would attach to a core with no game behind it.
    internal sealed class CoreLauncher
    {
        // Opting out is a supported configuration: an antivirus may object to one program starting another.
        private const string NoAutostartEnv = "MESHGHOST_NO_AUTOSTART";

        // A core needs a moment to bind; spawning again sooner piles up processes fighting over one port.
        private static readonly TimeSpan SpawnCooldown = TimeSpan.FromSeconds(5);

        private readonly Action<string> log;
        private Process child;
        // The port the child was told to serve; a busy answer from it means another game took the child.
        private int childPort;
        private DateTime lastSpawn = DateTime.MinValue;
        private bool disabled;
        private bool loggedReuse;

        internal CoreLauncher(Action<string> log)
        {
            this.log = log;
        }

        // Every frame while the bridge is not connected; returns at once unless a spawn is due.
        internal void TickDisconnected(int bridgePort, int lastBusyPort)
        {
            // Our own child's port answered busy while the child lives: another game reached it first. The child is
            // forgotten, not killed, so a fresh core starts at the cursor. Only on busy, never on silence: forgetting
            // on silence made two restarting instances chase each other's fresh cores round the range.
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
                // Said once, and naming the folder: "not found" with no location helps nobody.
                disabled = true;
                log("MeshGhost: meshghost.exe was not found -- not starting a core. Put it in the TEVI " +
                    "folder (the one with TEVI.exe) alongside config.json; if it was there, check " +
                    "whether antivirus removed it.");
                return;
            }

            lastSpawn = DateTime.UtcNow;
            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = exe,
                    // No relay settings: the child reads the config.json a player edits, which -relay would override.
                    Arguments = $"-exit-with-pid={Process.GetCurrentProcess().Id} -bridge=127.0.0.1:{bridgePort}",
                    WorkingDirectory = Path.GetDirectoryName(exe),
                    // No console at all, so no window flashes; show_console in config.json makes the core allocate one.
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                child = Process.Start(startInfo);
                childPort = bridgePort;
                log($"MeshGhost: started a core ({exe}, pid {child?.Id}) on bridge port {bridgePort} -- " +
                    "its config.json, meshghost.log and replay folder live in that folder.");
            }
            catch (Exception e)
            {
                child = null;
                log($"MeshGhost: could not start meshghost.exe: {e.Message}");
            }
        }

        // Logged once: whether it started its own core or found one is the first question when two processes appear.
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
                // Not worth failing a shutdown over: -exit-with-pid ends it a moment later.
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

        // "autostart": false in the config.json beside meshghost.exe: use whichever core is running, never start one.
        // Absent, or anything but false, means autostart; the environment variable saying no is still a no.
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

        // "map_markers": false in the same config.json hides peers' markers on the pause-menu map; absent, or anything
        // but false, means on. The stamp lets the plugin re-apply it when the file changes, without a restart.
        public static bool ConfigSaysNoMapMarkers(out System.DateTime stamp)
        {
            stamp = System.DateTime.MinValue;
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
                    stamp = File.GetLastWriteTimeUtc(cfg);
                    return Regex.IsMatch(File.ReadAllText(cfg), "\"map_markers\"\\s*:\\s*false");
                }
            }
            catch
            {
            }
            return false;
        }

        // Where the bridge port range starts, from the config.json the player edits, so local_game_bridge moves the
        // adapter and the core together.
        public static int ResolveBridgeBasePort(int fallback)
        {
            // The environment wins: the variable every adapter reads, so one launcher setting moves every game's range.
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
                    // The first config.json found wins even without the key: a later one belongs to another install.
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

        // The client, its config.json, log and replays live in the game's root folder, the one holding TEVI.exe, and
        // nowhere else, so a config has one place to be. MESHGHOST_CORE_DIR is the dev override for a dev-built client.
        private static IEnumerable<string> CoreSearchDirs()
        {
            yield return Environment.GetEnvironmentVariable("MESHGHOST_CORE_DIR");
            yield return Paths.GameRootPath;
        }
    }
}
