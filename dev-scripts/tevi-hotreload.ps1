# Switches the TEVI adapter between BepInEx's normal plugin loading and ScriptEngine's hot-reloadable one, so a code
# change can be tested without relaunching TEVI. The two folders are exclusive: in both, the adapter loads twice.
# ScriptEngine (BepInEx.Debug) is a developer-machine tool, never a MeshGhost dependency and never shipped.
#
#   .\tevi-hotreload.ps1 -Status     what mode the install is in right now
#   .\tevi-hotreload.ps1 -On         move the adapter to scripts\ and arm auto-reload
#   .\tevi-hotreload.ps1 -Deploy     rebuild and push the DLL to whichever mode is active
#   .\tevi-hotreload.ps1 -Off        move it back to plugins\, the shipping layout
#
# The loop once -On:  edit -> .\tevi-hotreload.ps1 -Deploy -> the watcher reloads it (F6 if it does not) -> watch.
#
# Two things this loop cannot tell you:
#   1. Anything only a cold start shows: load order, first-frame nulls, a stale config. Re-confirm with -Off and a
#      real launch before it counts as verified.
#   2. What the old instance left in the scene. Plugin.cs's OnDestroy despawns peer ghosts and map markers; anything
#      new that spawns a GameObject must be despawned there too, or each reload leaves an orphan.

[CmdletBinding()]
param(
    [switch]$On,
    [switch]$Off,
    [switch]$Deploy,
    [switch]$Status,
    # Defaults to the stock Steam location; pass another install, or set MESHGHOST_TEVI_DIR.
    [string]$TeviDir = $(if ($env:MESHGHOST_TEVI_DIR) { $env:MESHGHOST_TEVI_DIR }
                        else { "C:\Program Files (x86)\Steam\steamapps\common\TEVI" }),
    # Apply to both installs; the second is MESHGHOST_TEVI_DIR2, a machine-specific path kept out of this repo.
    [switch]$Both
)

$ErrorActionPreference = 'Stop'

# Deploying to one install and not the other leaves two adapter builds running, which looks exactly like a
# peer-vs-local bug.
if ($Both) {
    $second = $env:MESHGHOST_TEVI_DIR2
    if (-not $second) {
        Write-Output "tevi-hotreload: -Both needs MESHGHOST_TEVI_DIR2 set to the second install."
        exit 1
    }
    $fwd = @{}
    foreach ($k in 'On','Off','Deploy','Status') { if ($PSBoundParameters[$k]) { $fwd[$k] = $true } }
    foreach ($dir in @($TeviDir, $second)) {
        Write-Output "===== $dir"
        & $PSCommandPath @fwd -TeviDir $dir
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    exit 0
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$staged   = Join-Path $repoRoot 'packaging\release\games\tevi\MeshGhost\MeshGhostTevi.dll'

# The shipping folder, under the name build-tevi.bat stages; a wrong name here makes -On load the adapter twice.
$pluginDir = Join-Path $TeviDir 'BepInEx\plugins\MeshGhost'
$scriptDir = Join-Path $TeviDir 'BepInEx\scripts'
$pluginDll = Join-Path $pluginDir 'MeshGhostTevi.dll'
$scriptDll = Join-Path $scriptDir 'MeshGhostTevi.dll'

if (-not (Test-Path $TeviDir)) {
    Write-Output "tevi-hotreload: no TEVI install at '$TeviDir'."
    Write-Output "  Pass -TeviDir <path> or set MESHGHOST_TEVI_DIR."
    exit 1
}

$engine = Join-Path $TeviDir 'BepInEx\plugins\ScriptEngine.dll'

function Get-Mode {
    $inPlugins = Test-Path $pluginDll
    $inScripts = Test-Path $scriptDll
    if ($inPlugins -and $inScripts) { return 'BOTH' }
    if ($inScripts) { return 'hot-reload' }
    if ($inPlugins) { return 'shipping' }
    return 'absent'
}

function Show-Status {
    $mode = Get-Mode
    Write-Output "tevi-hotreload: install    $TeviDir"
    Write-Output "                mode       $mode"
    Write-Output "                ScriptEngine $(if (Test-Path $engine) { 'installed' } else { 'NOT INSTALLED -- -On will not reload anything' })"
    if ($mode -eq 'BOTH') {
        Write-Output ""
        Write-Output "  BOTH copies are present, so the adapter loads TWICE -- two bridge"
        Write-Output "  connections and two ghosts per peer. Run -On or -Off to pick one."
    }
    # CoreLauncher looks for meshghost.exe in the game root and nowhere else, whichever copy of the DLL is live.
    # MESHGHOST_NO_AUTOSTART is the other way out: set it and start the core yourself.
    $hasExe = Test-Path (Join-Path $TeviDir 'meshghost.exe')
    Write-Output "                core in the game root (beside TEVI.exe): $(if ($hasExe) { 'yes' } else { 'NO -- autostart will decline' })"
}

# ScriptEngine's defaults are manual-only (watcher off, F6); arming the watcher makes -Deploy's write the reload.
# Section and key names were read from the shipped ScriptEngine.dll, not a wiki: re-check after a ScriptEngine bump.
# AutoReloadDelay is not zero: the watcher fires on a copy's first write, and zero would load a truncated assembly.
$engineCfg = Join-Path $TeviDir 'BepInEx\config\com.bepis.bepinex.scriptengine.cfg'

function Write-ScriptEngineConfig {
    $cfgDir = Split-Path -Parent $engineCfg
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory $cfgDir | Out-Null }
    @(
        '## Written by MeshGhost dev-scripts\tevi-hotreload.ps1 -- a DEVELOPER machine setting.',
        '## ScriptEngine is not a MeshGhost dependency and nothing here ships.',
        '',
        '[General]',
        '',
        '## LOAD THE SCRIPTS FOLDER AT STARTUP. Without this the adapter sits in BepInEx\scripts',
        '## unloaded on every launch -- no ghost, no error, looking exactly like a broken mod --',
        '## until somebody presses F6. This file is REWRITTEN WHOLE by -On, and the first version',
        '## of it omitted this section entirely: BepInEx then regenerated [General] with the',
        '## shipped default of false, so -On silently disarmed the very loop it had just armed.',
        '## Found live 2026-08-28, with two instances launched into a title screen and no adapter.',
        '# Setting type: Boolean',
        '# Default value: false',
        'LoadOnStart = true',
        '',
        '## The manual trigger, kept as a fallback for when the watcher below misses a write.',
        '# Setting type: KeyboardShortcut',
        '# Default value: F6',
        'ReloadKey = F6',
        '',
        '[AutoReload]',
        '',
        '## Watches the scripts directory and reloads all plugins when a file changes.',
        '# Setting type: Boolean',
        '# Default value: false',
        'EnableFileSystemWatcher = true',
        '',
        '## Delay in seconds from detecting a change to plugins being reloaded.',
        '# Setting type: Single',
        '# Default value: 3',
        'AutoReloadDelay = 2',
        ''
    ) | Set-Content -Path $engineCfg -Encoding utf8
    Write-Output "tevi-hotreload: armed auto-reload in $engineCfg"
}

if ($Status -or -not ($On -or $Off -or $Deploy)) {
    Show-Status
    exit 0
}

if ($On -and $Off) { Write-Output "tevi-hotreload: -On and -Off are mutually exclusive."; exit 1 }

if ($On) {
    if (-not (Test-Path $engine)) {
        Write-Output "tevi-hotreload: ScriptEngine.dll is not in BepInEx\plugins -- nothing would reload."
        Write-Output "  Get it from https://github.com/BepInEx/BepInEx.Debug/releases (ScriptEngine_*.zip)."
        exit 1
    }
    if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory $scriptDir | Out-Null }
    if (Test-Path $pluginDll) { Move-Item $pluginDll $scriptDll -Force }
    elseif (-not (Test-Path $scriptDll)) {
        if (-not (Test-Path $staged)) { Write-Output "tevi-hotreload: no DLL in plugins\ and nothing staged -- run build-tevi.bat first."; exit 1 }
        Copy-Item $staged $scriptDll -Force
    }
    # The symbols move with the DLL: ScriptEngine reads it through Mono.Cecil with symbols, and a DLL with no .pdb
    # throws SymbolsNotFoundException out of ScriptEngine.Awake, so nothing loads and the watcher is never armed.
    $pluginPdb = Join-Path $pluginDir 'MeshGhostTevi.pdb'
    $scriptPdb = Join-Path $scriptDir 'MeshGhostTevi.pdb'
    if (Test-Path $pluginPdb) { Move-Item $pluginPdb $scriptPdb -Force }
    elseif (-not (Test-Path $scriptPdb)) {
        $builtPdb = Join-Path $repoRoot 'adapters\tevi\MeshGhostTevi\bin\Release\MeshGhostTevi.pdb'
        if (Test-Path $builtPdb) { Copy-Item $builtPdb $scriptPdb -Force }
        else { Write-Output "tevi-hotreload: WARNING -- no MeshGhostTevi.pdb anywhere; ScriptEngine will refuse to load this." }
    }

    $srcExe = Join-Path $pluginDir 'meshghost.exe'
    if (Test-Path $srcExe) { Copy-Item $srcExe (Join-Path $scriptDir 'meshghost.exe') -Force }
    Write-ScriptEngineConfig
    Write-Output "tevi-hotreload: ON -- adapter is in BepInEx\scripts, auto-reload armed."
    Write-Output "  -Deploy now reloads the adapter by itself; F6 still works as a manual trigger."
    Show-Status
    exit 0
}

if ($Off) {
    if (-not (Test-Path $pluginDir)) { New-Item -ItemType Directory $pluginDir | Out-Null }
    if (Test-Path $scriptDll) { Move-Item $scriptDll $pluginDll -Force }
    # Back with its DLL: left in scripts\, it would make the next -On think the symbols were already handled.
    $scriptPdb = Join-Path $scriptDir 'MeshGhostTevi.pdb'
    if (Test-Path $scriptPdb) { Move-Item $scriptPdb (Join-Path $pluginDir 'MeshGhostTevi.pdb') -Force }
    Remove-Item (Join-Path $scriptDir 'meshghost.exe') -Force -ErrorAction SilentlyContinue
    Write-Output "tevi-hotreload: OFF -- adapter is back in BepInEx\plugins (the shipping layout)."
    Write-Output "  This is the layout a cold start tests, and the only one a release resembles."
    Show-Status
    exit 0
}

if ($Deploy) {
    Write-Output "tevi-hotreload: building..."
    & "$env:ComSpec" /c (Join-Path $PSScriptRoot 'build-tevi.bat')
    if ($LASTEXITCODE -ne 0) { Write-Output "tevi-hotreload: build failed, nothing deployed."; exit 1 }
    $mode = Get-Mode
    $target = switch ($mode) {
        'hot-reload' { $scriptDll }
        'shipping'   { $pluginDll }
        default      { $null }
    }
    if (-not $target) { Write-Output "tevi-hotreload: mode is '$mode' -- run -On or -Off first."; exit 1 }
    Copy-Item $staged $target -Force
    # Never report a copy by echoing what was copied -- compare the two files independently.
    $ok = (Get-FileHash $staged).Hash -eq (Get-FileHash $target).Hash
    Write-Output "tevi-hotreload: deployed to $mode at $target (hash match: $ok)"
    if (-not $ok) { exit 1 }

    # ScriptEngine will not load a DLL without its .pdb, and build-tevi.bat stages only the DLL, so the pdb comes here.
    $pdbSrc = Join-Path $repoRoot 'adapters\tevi\MeshGhostTevi\bin\Release\MeshGhostTevi.pdb'
    $pdbDst = Join-Path (Split-Path $target) 'MeshGhostTevi.pdb'
    if (Test-Path $pdbSrc) {
        Copy-Item $pdbSrc $pdbDst -Force
        Write-Output "                symbols deployed (hash match: $((Get-FileHash $pdbSrc).Hash -eq (Get-FileHash $pdbDst).Hash))"
    } elseif ($mode -eq 'hot-reload') {
        Write-Output "                WARNING: no MeshGhostTevi.pdb -- ScriptEngine will refuse to load this."
    }

    # Copy-Item keeps the source's LastWriteTime and the watcher fires on LastWrite, so the destination is stamped:
    # the deploy is the trigger, whether or not the bytes moved.
    if ($mode -eq 'hot-reload') {
        $now = Get-Date
        (Get-Item $target).LastWriteTime = $now
        if (Test-Path $pdbDst) { (Get-Item $pdbDst).LastWriteTime = $now }
    }

    $repoExe = Join-Path $repoRoot 'meshghost.exe'
    if (Test-Path $repoExe) {
        $exeTarget = Join-Path (Split-Path $target) 'meshghost.exe'
        # Copying over a running core throws (the exe is locked), so compare first and treat a lock as a warning: an
        # adapter reload does not need the core replaced.
        $exeOk = (Test-Path $exeTarget) -and ((Get-FileHash $repoExe).Hash -eq (Get-FileHash $exeTarget).Hash)
        if ($exeOk) {
            Write-Output "                core already current"
        } else {
            try {
                Copy-Item $repoExe $exeTarget -Force -ErrorAction Stop
                $exeOk = (Get-FileHash $repoExe).Hash -eq (Get-FileHash $exeTarget).Hash
                Write-Output "                core refreshed (hash match: $exeOk)"
                if (-not $exeOk) { exit 1 }
            } catch {
                Write-Output "                WARNING: core is STALE and could not be replaced (a core is running from it)."
                Write-Output "                  Stop the running core(s) and re-run -Deploy if the core changed."
            }
        }
        # go build/vet/test do not refresh the root .exe; this warns rather than builds, so a reading names its binary.
        $newestGo = Get-ChildItem $repoRoot -Recurse -Filter *.go -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newestGo -and $newestGo.LastWriteTime -gt (Get-Item $repoExe).LastWriteTime) {
            Write-Output "                WARNING: meshghost.exe is OLDER than $($newestGo.Name)."
            Write-Output "                  go build -o meshghost.exe .\cmd\meshghost   (from the repo root)"
        }
    }
    if ($mode -eq 'hot-reload') {
        $armed = (Test-Path $engineCfg) -and ((Get-Content $engineCfg -Raw) -match 'EnableFileSystemWatcher\s*=\s*true')
        if ($armed) { Write-Output "  Reloading by itself in ~2s -- nothing to press." }
        else { Write-Output "  Press F6 in TEVI (auto-reload is not armed; run -On to arm it)." }
    } else { Write-Output "  Relaunch TEVI." }
    exit 0
}
