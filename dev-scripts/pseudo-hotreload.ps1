# Reloads Pseudoregalia's UE4SS Lua mods without relaunching the game, by sending UE4SS's own hot-reload keybind
# (Ctrl+R) to the game window. Lua probes only: the C++ adapter still needs a rebuild and a relaunch.
# UE4SS exposes reloading only as HotReloadKey in UE4SS-settings.ini (its vendored docs list no folder watcher), so the
# game window has to take focus; for a scripted reload, probe_reloader's request file needs none.
#
#   .\pseudo-hotreload.ps1            reload now
#   .\pseudo-hotreload.ps1 -Watch     reload every time a file under the Lua mod folder changes

[CmdletBinding()]
param(
    [switch]$Watch,
    # Where the Lua probes live, for -Watch. Defaults to this repo's own copies.
    [string]$WatchPath,
    # Wildcard: the window belongs to 'pseudoregalia-Win64-Shipping', and a windowless 'pseudoregalia' stub also runs.
    [string]$ProcessName = 'pseudoregalia*'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $WatchPath) { $WatchPath = Join-Path $repoRoot 'adapters\pseudoregalia' }

Add-Type -AssemblyName System.Windows.Forms

# SendKeys posts to whatever is focused, so the game window is brought forward first. Focus is not restored after:
# stealing it back mid-reload has its own races.
if (-not ('MeshGhost.Win32' -as [type])) {
    Add-Type -Namespace MeshGhost -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
}

# Reports through $script:ReloadOk, not a return value: beside Write-Output lines, a `return $false` would hand the
# caller a truthy array and swallow the messages.
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
# One save can raise several events; a quiet period keeps it to one reload, since each one steals focus.
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
