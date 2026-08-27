# MeshGhost -- switches the TEVI adapter between BepInEx's normal plugin loading and
# ScriptEngine's hot-reloadable one, so a code change can be tested without relaunching TEVI.
#
# Why a toggle and not just "put it in scripts\": BepInEx loads every DLL under plugins\ at
# startup and ScriptEngine loads every DLL under scripts\ on top of that. With the adapter in
# both, TWO plugin instances run -- two bridge connections, two ghosts per peer, and every
# reading agrees with itself while being wrong. The two locations are mutually exclusive, which
# is what this script enforces.
#
# ScriptEngine is BepInEx's own dev tool (BepInEx.Debug, LGPL-3.0, see agent_docs/licensing.md).
# It is NOT a MeshGhost dependency and is never shipped -- it lives only in a developer's own
# game install, the same posture as BizHawk and BepInEx itself.
#
#   .\tevi-hotreload.ps1 -Status     what mode the install is in right now
#   .\tevi-hotreload.ps1 -On         move the adapter to scripts\, ready for F6 reloads
#   .\tevi-hotreload.ps1 -Deploy     rebuild and push the DLL to whichever mode is active
#   .\tevi-hotreload.ps1 -Off        move it back to plugins\, the shipping layout
#
# The loop once -On:  edit -> .\tevi-hotreload.ps1 -Deploy -> press F6 in TEVI -> watch.
#
# TWO THINGS THIS LOOP CANNOT TELL YOU, both of which have cost this repo a session before:
#   1. Anything that only goes wrong on a COLD start is invisible here -- load order, first-frame
#      nulls, a stale config. Re-confirm anything important with -Off and a real launch before it
#      counts as verified.
#   2. A reload leaves whatever the old instance parented into the SCENE behind. Plugin.cs's
#      OnDestroy despawns peer ghosts and map markers for exactly this reason; anything new that
#      spawns a GameObject has to be despawned there too, or it accumulates one orphan per F6.

[CmdletBinding()]
param(
    [switch]$On,
    [switch]$Off,
    [switch]$Deploy,
    [switch]$Status,
    # Defaults to the stock Steam location. Override for a second install (the standalone build
    # used for dual-instance testing) or set MESHGHOST_TEVI_DIR once in your environment.
    [string]$TeviDir = $(if ($env:MESHGHOST_TEVI_DIR) { $env:MESHGHOST_TEVI_DIR }
                        else { "C:\Program Files (x86)\Steam\steamapps\common\TEVI" })
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$staged   = Join-Path $repoRoot 'packaging\release\games\tevi\MeshGhost\MeshGhostTevi.dll'

$pluginDir = Join-Path $TeviDir 'BepInEx\plugins\MeshGhostTevi'
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
    # meshghost.exe has to sit beside whichever copy is live, or CoreLauncher finds no core and
    # logs that it is not starting one. MESHGHOST_NO_AUTOSTART is the other way out of this: set
    # it and start the core yourself, which is what a scripted live test does anyway.
    foreach ($d in @($pluginDir, $scriptDir)) {
        if (Test-Path (Join-Path $d 'MeshGhostTevi.dll')) {
            $hasExe = Test-Path (Join-Path $d 'meshghost.exe')
            Write-Output "                core beside the live DLL: $(if ($hasExe) { 'yes' } else { 'NO -- autostart will decline' })"
        }
    }
}

# ScriptEngine's own defaults are manual-only: EnableFileSystemWatcher is false and the reload
# is the ReloadKey (F6). Turning the watcher on is what removes the human from the loop entirely
# -- -Deploy writes the DLL into scripts\ and the reload follows from the write.
#
# Every name here was read out of the shipped ScriptEngine.dll with ilspycmd rather than taken
# from a wiki: sections [General] and [AutoReload], keys LoadOnStart / ReloadKey / QuietMode /
# IncludeSubdirectories / EnableFileSystemWatcher / AutoReloadDelay / DumpAssemblies. A
# repackaged build documented elsewhere lists the same keys under different sections, which is
# exactly why the DLL rather than the wiki is the citation. Re-check after a ScriptEngine bump.
#
# AutoReloadDelay is deliberately NOT the 3s default and NOT zero. A FileSystemWatcher fires on
# the first write of a copy, so a zero delay races the copy and loads a truncated assembly; the
# delay is the only thing standing between the loop and an intermittent "reload failed" that
# looks like a code bug. 2s is comfortably longer than a local file copy.
$engineCfg = Join-Path $TeviDir 'BepInEx\config\com.bepis.bepinex.scriptengine.cfg'

function Write-ScriptEngineConfig {
    $cfgDir = Split-Path -Parent $engineCfg
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory $cfgDir | Out-Null }
    @(
        '## Written by MeshGhost dev-scripts\tevi-hotreload.ps1 -- a DEVELOPER machine setting.',
        '## ScriptEngine is not a MeshGhost dependency and nothing here ships.',
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
    # The core has to be beside the DLL that is actually loaded, not the folder it came from.
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
    if ($mode -eq 'hot-reload') {
        $armed = (Test-Path $engineCfg) -and ((Get-Content $engineCfg -Raw) -match 'EnableFileSystemWatcher\s*=\s*true')
        if ($armed) { Write-Output "  Reloading by itself in ~2s -- nothing to press." }
        else { Write-Output "  Press F6 in TEVI (auto-reload is not armed; run -On to arm it)." }
    } else { Write-Output "  Relaunch TEVI." }
    exit 0
}
