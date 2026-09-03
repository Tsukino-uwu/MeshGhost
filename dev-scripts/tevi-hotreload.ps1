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
                        else { "C:\Program Files (x86)\Steam\steamapps\common\TEVI" }),
    # Apply to BOTH installs. The second one comes from MESHGHOST_TEVI_DIR2, which is where a
    # machine-specific path belongs -- this is a public repo and a second install is nobody
    # else's layout.
    [switch]$Both
)

$ErrorActionPreference = 'Stop'

# Dual-instance testing is the case this exists for. Deploying to one install and not the other
# leaves two TEVI copies running DIFFERENT adapter builds, and the resulting asymmetry looks
# exactly like a peer-vs-local bug -- the most expensive kind of wrong answer this repo has, since
# every instrument then agrees with itself. -Both keeps them in step.
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
    # THE SYMBOLS MOVE WITH THE DLL, and leaving them behind is fatal rather than untidy.
    # ScriptEngine reads the assembly through Mono.Cecil WITH symbols, so a DLL in scripts\ with
    # no .pdb beside it throws SymbolsNotFoundException out of ScriptEngine.Awake -- which kills
    # the whole component, so LoadOnStart loads nothing AND the file watcher is never armed. The
    # game then runs with no adapter and no MeshGhost line in the log, looking exactly like a
    # broken mod. -Deploy already knew this (see its own comment below); -On did not, and moved
    # only the DLL. Found live 2026-08-28, immediately after LoadOnStart was fixed.
    $pluginPdb = Join-Path $pluginDir 'MeshGhostTevi.pdb'
    $scriptPdb = Join-Path $scriptDir 'MeshGhostTevi.pdb'
    if (Test-Path $pluginPdb) { Move-Item $pluginPdb $scriptPdb -Force }
    elseif (-not (Test-Path $scriptPdb)) {
        $builtPdb = Join-Path $repoRoot 'adapters\tevi\MeshGhostTevi\bin\Release\MeshGhostTevi.pdb'
        if (Test-Path $builtPdb) { Copy-Item $builtPdb $scriptPdb -Force }
        else { Write-Output "tevi-hotreload: WARNING -- no MeshGhostTevi.pdb anywhere; ScriptEngine will refuse to load this." }
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
    # Back with its DLL. Harmless in plugins\ (BepInEx does not read symbols there), and leaving
    # it in scripts\ would make the next -On think symbols were already handled.
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

    # ScriptEngine reads the assembly WITH SYMBOLS (Mono.Cecil, ReadSymbols), so a DLL with no
    # .pdb beside it throws SymbolsNotFoundException and the plugin never loads at all -- the
    # game looks fine and simply has no adapter in it. build-tevi.bat deliberately stages only
    # the DLL, because a .pdb has no business in packaging/release/, so the copy happens here:
    # the symbols are part of the DEV loop, not part of what ships. Found live 2026-08-28, on
    # the first reload ever attempted in the game.
    $pdbSrc = Join-Path $repoRoot 'adapters\tevi\MeshGhostTevi\bin\Release\MeshGhostTevi.pdb'
    $pdbDst = Join-Path (Split-Path $target) 'MeshGhostTevi.pdb'
    if (Test-Path $pdbSrc) {
        Copy-Item $pdbSrc $pdbDst -Force
        Write-Output "                symbols deployed (hash match: $((Get-FileHash $pdbSrc).Hash -eq (Get-FileHash $pdbDst).Hash))"
    } elseif ($mode -eq 'hot-reload') {
        Write-Output "                WARNING: no MeshGhostTevi.pdb -- ScriptEngine will refuse to load this."
    }

    # Copy-Item PRESERVES the source's LastWriteTime, and ScriptEngine's watcher fires on
    # LastWrite. So a rebuild that produced a byte-identical DLL copies an identical timestamp,
    # nothing appears to change, and the reload silently does not happen -- while every line
    # above still says "deployed". Stamping the destination makes the deploy the trigger,
    # independent of whether the bytes moved. Found live 2026-08-28: the first reload test
    # reported success and had reloaded nothing.
    if ($mode -eq 'hot-reload') {
        $now = Get-Date
        (Get-Item $target).LastWriteTime = $now
        if (Test-Path $pdbDst) { (Get-Item $pdbDst).LastWriteTime = $now }
    }

    # The CORE goes stale independently of the adapter, and silently. Both installs were found
    # running a meshghost.exe from 2026-08-18 on 2026-08-28, predating the very port-walk fix the
    # next live test was meant to watch. A test against a stale core
    # confirms nothing and looks like a confirmation, so the copy happens here rather than being
    # something to remember.
    $repoExe = Join-Path $repoRoot 'meshghost.exe'
    if (Test-Path $repoExe) {
        $exeTarget = Join-Path (Split-Path $target) 'meshghost.exe'
        # Already identical is the common case, and copying over a RUNNING core throws -- the exe
        # is locked while a core is up, which is most of the time during a live session. Compare
        # first, and treat a locked file as information rather than as a failure: an adapter
        # reload does not need the core replaced, and aborting the deploy over it would stop the
        # thing that actually was going to reload. Found live 2026-08-28, when this aborted a
        # deploy mid-session.
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
        # go build/vet/test do NOT refresh the root .exe files -- this warns rather than building,
        # because rebuilding the Go side silently inside an adapter deploy would hide which
        # binary a reading came from.
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
