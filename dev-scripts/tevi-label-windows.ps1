# Labels each running TEVI window with which install it is, for dual-instance testing: two copies look identical.
# The title is set from outside the game with SetWindowText, so nothing ships and the label is gone on relaunch.
#
#   .\tevi-label-windows.ps1          label whatever TEVI processes are running
#
# Run it after launching both games. Re-run it if either is relaunched.

[CmdletBinding()]
param(
    # Matched against the process path; a window matching neither install is labelled by its own folder name.
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
        $label = "TEVI  [$((Get-Item $path).Directory.Name)]"
    } else {
        $label = "TEVI  [pid $($p.Id)]"
    }
    [void][MeshGhost.WinTitle]::SetWindowText($p.MainWindowHandle, $label)
    Write-Output "tevi-label-windows: pid $($p.Id) -> $label"
}
