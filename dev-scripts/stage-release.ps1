<#
.SYNOPSIS
Assembles the Windows release into packaging\release\, exactly as a real release does.

.DESCRIPTION
There was no way to try a release without cutting one. packaging\release\ holds only the
hand-written half -- the READMEs, config template, and the committed TEVI/Pseudoregalia mods --
while the Go binaries and the Emerald/Crystal adapter scripts were added by
.github/workflows/release.yml and existed nowhere else. So "does the RELEASE work" could only be
answered after tagging, and every local test ran against dev-scripts instead, which reach the
adapters at their source paths and never exercise the layout a player actually installs.

.gitignore has referred to "a local dry run" since the Emerald entry was written; this is it.

ONE IMPLEMENTATION, TWO CALLERS. release.yml invokes this script rather than repeating its
steps. That is deliberate and it is the whole point: a second copy of the staging logic would
drift from the first, and a local dry run that stages something slightly different from the
release is worse than no dry run at all, because it reports success about the wrong thing. This
repo has paid for that shape more than once -- most recently a fix written in Crystal and never
brought back to Emerald (2026-08-28), which cost a session at 5fps.

.PARAMETER NoBuild
Skip building the two .exe files. release.yml passes this because it builds them in its own
earlier steps (with the same -ldflags) and needs them at the repo root for other jobs.

.PARAMETER ForRelease
Remove games\client-config-template.json from the staged tree after copying it into each mod
folder. Only a real release does this: the template is a TRACKED file, and deleting it during a
local dry run would show up as a deletion in git status.

.EXAMPLE
pwsh dev-scripts\stage-release.ps1
Builds and stages. Afterwards packaging\release\ is what a player unzips.
#>
[CmdletBinding()]
param(
    [switch]$NoBuild,
    [switch]$ForRelease
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not $NoBuild) {
    Write-Host '== Building the client and server (release flags) =='
    # The same -ldflags release.yml uses. Without them a local dry run stages binaries a few MB
    # larger than the shipped ones, which is a difference worth not having when the thing being
    # tested is the release.
    go build -ldflags="-s -w" -o meshghost.exe ./cmd/meshghost
    if ($LASTEXITCODE -ne 0) { throw 'go build ./cmd/meshghost failed' }
    # Renamed on the way in: one program, two names. packaging\README.md has the why.
    go build -ldflags="-s -w" -o meshghost-server.exe ./cmd/meshghost-relay
    if ($LASTEXITCODE -ne 0) { throw 'go build ./cmd/meshghost-relay failed' }
}

foreach ($exe in @('meshghost.exe', 'meshghost-server.exe')) {
    if (-not (Test-Path $exe)) {
        throw "$exe is not at the repo root. Run without -NoBuild, or build it first."
    }
}

Write-Host '== Staging into packaging\release\ =='
Copy-Item meshghost.exe packaging\release\ -Force
Copy-Item meshghost-server.exe packaging\release\ -Force

# Each mod that installs INTO a game gets its own config.json, but NOT its own copy of the
# client -- the mod starts the client from beside its own DLL, and shipping a 9 MB binary per
# game was rejected on 2026-08-18. The player copies meshghost.exe in once per game, which is
# the one manual step in the install and is called out in each game's README.txt.
$modFolders = @(
    'packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo',
    'packaging\release\games\tevi\MeshGhost'
)
foreach ($f in $modFolders) {
    Copy-Item packaging\release\games\client-config-template.json "$f\config.json" -Force
}
if ($ForRelease) {
    Remove-Item packaging\release\games\client-config-template.json
}

# Emerald and Crystal are not in $modFolders at all: their scripts load from the release folder
# itself, so they reach the root exe and config with no copy of anything.
New-Item -ItemType Directory -Force packaging\release\games\pokemon\emerald | Out-Null
Copy-Item adapters\emulator\pokemon\emerald\meshghost_emerald.lua packaging\release\games\pokemon\emerald\ -Force
Copy-Item -Recurse -Force adapters\emulator\pokemon\emerald\lib packaging\release\games\pokemon\emerald\lib

# Crystal's lib\ comes from Emerald's: it is the same BizHawk LuaSocket build, and
# adapters/emulator/pokemon/crystal/ deliberately has no copy of its own -- in a source checkout
# the script falls back to ../emerald/lib/x64/, and a release gives each game folder its own so
# that fallback is never needed by a player.
New-Item -ItemType Directory -Force packaging\release\games\pokemon\crystal | Out-Null
Copy-Item adapters\emulator\pokemon\crystal\meshghost_crystal.lua packaging\release\games\pokemon\crystal\ -Force
Copy-Item -Recurse -Force adapters\emulator\pokemon\emerald\lib packaging\release\games\pokemon\crystal\lib

# An experiment flag beside the adapter would make it run an Archipelago ROM on an unconfirmed
# address. Checked at the SOURCE, not in the staged folder: the copies above are a list of
# exactly two files, so the flag could never be there and a guard looking there could never fire.
if (Test-Path adapters\emulator\pokemon\crystal\ap_try.flag) {
    throw 'ap_try.flag must never be packaged'
}

Write-Host ''
Write-Host 'Staged. packaging\release\ now holds what a player unzips:'
Write-Host '  meshghost.exe / meshghost-server.exe / config.json'
Write-Host '  games\pokemon\emerald\  games\pokemon\crystal\   (adapter + lib, load in place)'
Write-Host '  games\tevi\  games\pseudoregalia\                (install into the game, then'
Write-Host '                                                    copy meshghost.exe in beside the mod)'
Write-Host ''
Write-Host 'What this does NOT prove: the zip step, the Linux/macOS builds, and the staleness'
Write-Host 'gates release.yml runs against the committed mod DLLs. Those stay CI-only.'
