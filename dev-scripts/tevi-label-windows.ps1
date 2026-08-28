# MeshGhost -- labels each running TEVI window with which INSTALL it is, for dual-instance testing.
#
# WHY THIS EXISTS. Two TEVI copies are visually identical, and on 2026-08-28 that cost a whole
# measurement round: a charged-attack probe run was performed on one instance and read from the
# other's log, so a clean-looking result proved nothing. The user, asked which one: *"hard to keep
# track as they are identical"*. An instrument that cannot say WHICH subject it measured is not an
# instrument, and this is the cheapest possible fix for that.
#
# NOTHING SHIPS. The title is set from OUTSIDE the game with SetWindowText -- no game code, no
# plugin change, nothing in packaging/release. The label is gone the moment the game restarts,
# which is why this is a script you re-run rather than a setting.
#
#   .\tevi-label-windows.ps1          label whatever TEVI processes are running
#
# Run it after launching both games. Re-run it if either is relaunched.

[CmdletBinding()]
param(
    # Matched against the process path to decide which label a window gets. Anything not matching
    # is labelled by its own folder name rather than guessed at.
    [string]$StandalonePathMatch = $(if ($env:MESHGHOST_TEVI_DIR2) { $env:MESHGHOST_TEVI_DIR2 } else { 'tevi-14778703' })
)

$ErrorActionPreference = 'Stop'

if (-not ('MeshGhost.WinTitle' -as [type])) {
    Add-Type -Namespace MeshGhost -Name WinTitle -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool SetWindowText(IntPtr hWnd, string text);
'@
}

$procs = @(Get-Process -Name TEVI -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
if ($procs.Count -eq 0) {
    Write-Output "tevi-label-windows: no TEVI window is open."
    exit 1
}

foreach ($p in $procs) {
    $path = ''
    # A process can refuse to hand over its path; that is not a reason to skip labelling it.
    try { $path = $p.Path } catch { }
    if ($path -and $path -like "*$StandalonePathMatch*") {
        $label = 'TEVI  [B: STANDALONE]'
    } elseif ($path -like '*steamapps*') {
        $label = 'TEVI  [A: STEAM]'
    } elseif ($path) {
        # Named by its own folder rather than assigned a letter it might not deserve.
        $label = "TEVI  [$((Get-Item $path).Directory.Name)]"
    } else {
        $label = "TEVI  [pid $($p.Id)]"
    }
    [void][MeshGhost.WinTitle]::SetWindowText($p.MainWindowHandle, $label)
    Write-Output "tevi-label-windows: pid $($p.Id) -> $label"
}
