using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

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
        private DateTime lastSpawn = DateTime.MinValue;
        private bool disabled;
        private bool loggedReuse;

        internal CoreLauncher(Action<string> log)
        {
            this.log = log;
        }

        // Called every frame while the bridge is NOT connected. Cheap: it returns immediately in
        // every case except the one where a spawn is actually due.
        internal void TickDisconnected(int bridgePort)
        {
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
        private static string FindCoreExe()
        {
            try
            {
                string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(dir))
                {
                    return null;
                }
                string exe = Path.Combine(dir, "meshghost.exe");
                return File.Exists(exe) ? exe : null;
            }
            catch
            {
                return null;
            }
        }
    }
}
