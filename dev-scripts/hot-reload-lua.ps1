# Triggers UE4SS's Lua hot reload in a running game, so a probe reloads with nobody pressing a key.
# UE4SS reads the key through a keyboard hook on the focused window, so this activates the game window, sends a real
# keystroke, and gives focus back.
#
# Usage:
#   pwsh dev-scripts/hot-reload-lua.ps1                 # every running pseudoregalia
#   pwsh dev-scripts/hot-reload-lua.ps1 -Key <key>      # when HotReloadKey is not F10
#   pwsh dev-scripts/hot-reload-lua.ps1 -ProcessName TEVI -Key F6   # ScriptEngine's ReloadKey (tevi-hotreload.ps1)
#
# -Key must match HotReloadKey in that install's UE4SS-settings.ini, and must not collide with a game or UE4SS binding.

param(
    [string]$ProcessName = "pseudoregalia-Win64-Shipping",
    [string]$Key = "F10"
)

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

$targets = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowHandle -ne 0 }

if (-not $targets) {
    Write-Output "no running '$ProcessName' with a window -- nothing to reload"
    exit 0
}

$previous = [Win32Focus]::GetForegroundWindow()

foreach ($p in $targets) {
    try {
        [Microsoft.VisualBasic.Interaction]::AppActivate($p.Id)
        Start-Sleep -Milliseconds 250
        [System.Windows.Forms.SendKeys]::SendWait("{$Key}")
        Start-Sleep -Milliseconds 150
        Write-Output "sent {$Key} to pid $($p.Id)"
    } catch {
        Write-Output "could not activate pid $($p.Id): $($_.Exception.Message)"
    }
}

if ($previous -ne [IntPtr]::Zero) {
    [void][Win32Focus]::SetForegroundWindow($previous)
}
