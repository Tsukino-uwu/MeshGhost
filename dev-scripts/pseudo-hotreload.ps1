# MeshGhost -- reloads Pseudoregalia's UE4SS Lua mods without relaunching the game, by driving
# UE4SS's own hot-reload keybind (Ctrl+R) at the game window.
#
# WHAT THIS DOES AND DOES NOT REACH. UE4SS hot-reloads LUA mods. The MeshGhost Pseudoregalia
# ADAPTER is a C++ mod compiled into a DLL, and nothing reloads that -- a change to Mod\src still
# costs a rebuild and a relaunch. What this speeds up is PROBE iteration (probe_ghost,
# probe_socket), which is where the measuring happens anyway.
#
# WHY A KEYSTROKE AND NOT A FILE WATCHER. UE4SS exposes reloading only as the keybind configured
# by HotReloadKey in UE4SS-settings.ini (default: R, with Ctrl always required). There is no
# watch-the-folder setting in the vendored docs -- checked against
# adapters\pseudoregalia\MeshGhostPseudo\RE-UE4SS\docs\, not from memory. So the key has to be
# pressed, and this presses it. The cost is that the game window must come to the foreground for
# a moment, which BizHawk's dev loader and TEVI's ScriptEngine watcher both avoid.
#
#   .\pseudo-hotreload.ps1            reload now
#   .\pseudo-hotreload.ps1 -Watch     reload every time a file under the Lua mod folder changes
#
# The -Watch form is the closest thing to TEVI's loop: edit a probe, save, and the running game
# picks it up with nothing pressed by hand.

[CmdletBinding()]
param(
    [switch]$Watch,
    # Where the Lua probes live, for -Watch. Defaults to this repo's own copies.
    [string]$WatchPath,
    # Wildcard, because the WINDOW belongs to 'pseudoregalia-Win64-Shipping' while a plain
    # 'pseudoregalia' launcher stub also exists with no window at all -- the exact-name default
    # matched only the stub and reported "no window" with the game running (2026-08-29).
    [string]$ProcessName = 'pseudoregalia*'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $WatchPath) { $WatchPath = Join-Path $repoRoot 'adapters\pseudoregalia' }

Add-Type -AssemblyName System.Windows.Forms

# SetForegroundWindow is the only reliable way to make a keystroke land in another process's
# window; SendKeys posts to whatever is focused. Restoring focus afterwards is deliberately NOT
# attempted -- stealing it back mid-reload has its own races, and the game is where you want to
# be looking anyway.
if (-not ('MeshGhost.Win32' -as [type])) {
    Add-Type -Namespace MeshGhost -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
}

# Reports through $script:ReloadOk rather than a return value. A PowerShell function emits
# EVERYTHING it writes as its output, so a `return $false` alongside Write-Output lines hands the
# caller an ARRAY -- which is truthy, and swallows the messages so nothing prints. Found by
# running it: the first version printed nothing at all and reported success on a game that was
# not running.
function Invoke-Reload {
    $script:ReloadOk = $false
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) {
        # Not an error in -Watch: the game is simply not up yet, and saying so beats silence.
        Write-Output "pseudo-hotreload: no '$ProcessName' window -- nothing to reload."
        return
    }
    [void][MeshGhost.Win32]::ShowWindow($proc.MainWindowHandle, 9)   # SW_RESTORE
    [void][MeshGhost.Win32]::SetForegroundWindow($proc.MainWindowHandle)
    Start-Sleep -Milliseconds 300      # the window has to actually have focus before the keys go
    [System.Windows.Forms.SendKeys]::SendWait('^r')
    Write-Output "pseudo-hotreload: sent Ctrl+R to $ProcessName (pid $($proc.Id))."
    # Never report the keystroke as proof the reload happened -- UE4SS.log is the independent
    # read, and it is where a Lua syntax error in the reloaded file will show up instead.
    Write-Output "  Confirm in UE4SS.log, not from this line: a reload that hit a Lua error"
    Write-Output "  reports there and leaves the OLD script running, which looks like no change."
    $script:ReloadOk = $true
}

if (-not $Watch) { Invoke-Reload; if ($script:ReloadOk) { exit 0 } else { exit 1 } }

if (-not (Test-Path $WatchPath)) { Write-Output "pseudo-hotreload: nothing at '$WatchPath'."; exit 1 }
Write-Output "pseudo-hotreload: watching $WatchPath for *.lua changes. Ctrl+C to stop."

$fsw = New-Object System.IO.FileSystemWatcher $WatchPath, '*.lua'
$fsw.IncludeSubdirectories = $true
$fsw.EnableRaisingEvents = $true
# Editors write a file in several operations, so one save can raise several events. Coalescing
# on a short quiet period is what stops a single save from firing four reloads, each of which
# steals focus.
$last = [datetime]::MinValue
try {
    while ($true) {
        $r = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
        if ($r.TimedOut) { continue }
        if (([datetime]::Now - $last).TotalMilliseconds -lt 1500) { continue }
        $last = [datetime]::Now
        Start-Sleep -Milliseconds 400          # let the editor finish writing
        Write-Output "pseudo-hotreload: $($r.Name) changed."
        Invoke-Reload
    }
} finally {
    $fsw.EnableRaisingEvents = $false
    $fsw.Dispose()
}
