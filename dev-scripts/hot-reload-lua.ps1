# Triggers UE4SS's Lua hot reload in a running game, so the AGENT reloads a probe rather than
# asking the user to press a key.
#
# The user's rule, 2026-08-31: "you should do as much as possible on your own. making me press f10
# every single time wouldn't be any better than me having to manually restart the game, it adds
# friction and slows down the intended workflow." Live reload only pays off if the whole loop is
# automatic -- edit the probe, call this, read the log.
#
# UE4SS reads its hot-reload key with a keyboard hook on the focused window, so the key has to be
# sent to the game window as a real keystroke. This activates the window, sends it, and then puts
# focus back where it was, which keeps the interruption to a fraction of a second.
#
# Usage:
#   pwsh dev-scripts/hot-reload-lua.ps1                 # every running pseudoregalia
#   pwsh dev-scripts/hot-reload-lua.ps1 -Key F10        # if HotReloadKey differs
#   pwsh dev-scripts/hot-reload-lua.ps1 -ProcessName TEVI
#
# HotReloadKey lives in each install's UE4SS-settings.ini and must match -Key. It is F10 for
# Pseudoregalia here: the default R is the sword-throw key, so every throw would reload every mod.

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

# Give the user their window back.
if ($previous -ne [IntPtr]::Zero) {
    [void][Win32Focus]::SetForegroundWindow($previous)
}
