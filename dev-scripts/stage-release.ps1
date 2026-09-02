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
Accepted for release.yml's sake and currently a no-op. It used to remove the client config
template after staging; since 2026-09-02 there is no template -- every game's config.json is
cut from the root config.json's "client" block -- so there is nothing to remove.

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
# A running relay or client HOLDS its .exe open, and staging while one runs is an ordinary thing to
# do -- mid-session you often want to restage a config without stopping the session. So an
# identical binary is skipped rather than copied, and a locked one that genuinely DIFFERS fails
# with a message naming the process, instead of a raw IOException from Copy-Item.
function Copy-Binary($name) {
    $dest = Join-Path 'packaging\release' $name
    if ((Test-Path $dest) -and (Get-FileHash $name).Hash -eq (Get-FileHash $dest).Hash) {
        Write-Host "  $name already staged and identical -- skipped (safe while it is running)"
        return
    }
    try {
        Copy-Item $name $dest -Force
    } catch [System.IO.IOException] {
        $proc = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($name)) -ErrorAction SilentlyContinue
        if ($proc) {
            throw "$name is running (pid $($proc.Id -join ', ')) and the staged copy differs -- stop it and re-run."
        }
        throw
    }
}
Copy-Binary 'meshghost.exe'
Copy-Binary 'meshghost-server.exe'

# Each mod that installs INTO a game gets its own config.json, but NOT its own copy of the
# client -- the mod starts the client from beside its own DLL, and shipping a 9 MB binary per
# game was rejected on 2026-08-18. The player copies meshghost.exe in once per game, which is
# the one manual step in the install and is called out in each game's README.txt.
# Every folder that gets a config.json from the template. Emerald and Crystal joined on
# 2026-09-02 (the user's ask; plans.md "Settings" step 3): their scripts point the core they
# start at the config beside the script, so each Pokemon game carries its own settings the way
# TEVI and Pseudoregalia do, and an overrides file beside the script works for them the same way.
$modFolders = @(
    'packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo',
    'packaging\release\games\tevi\MeshGhost',
    'packaging\release\games\pokemon\emerald',
    'packaging\release\games\pokemon\crystal'
)
# Where each folder's overrides live: games\<game>\ for the mod-folder games (the mod folder is a
# level or more below), the folder itself for the Pokemon pair (the script IS the folder).
$overridesFor = @{
    'packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo' = 'packaging\release\games\pseudoregalia\client-config-overrides.json'
    'packaging\release\games\tevi\MeshGhost' = 'packaging\release\games\tevi\client-config-overrides.json'
    'packaging\release\games\pokemon\emerald' = 'packaging\release\games\pokemon\emerald\client-config-overrides.json'
    'packaging\release\games\pokemon\crystal' = 'packaging\release\games\pokemon\crystal\client-config-overrides.json'
}
foreach ($f in $modFolders) {
    New-Item -ItemType Directory -Force $f | Out-Null
    # The shared template, with this game's own overrides applied on top if it has any. The
    # overrides file holds ONLY the keys that differ, so the template stays the single copy --
    # duplicating a whole config per game would guarantee the two drift. Since 2026-09-02 the
    # files carry NO comments at all (the user's call: explanations live in README.txt), and the
    # layout is two tiers, basics then a blank line then the advanced set.
    #
    # Applied as a targeted text replacement rather than by parsing and re-emitting JSON:
    # round-tripping through ConvertTo-Json reorders the keys and reflows the file, which would
    # lose the tier layout.
    # The source is the root config.json's "client" block, verbatim -- one copy of the client
    # settings for the whole release (the separate template it used to be cut from was dropped
    # on 2026-09-02, the user's call, once no comments needed a home of their own). Two keys in
    # it are meaningless for some games (local_game_bridge, game) and harmless: an adapter that
    # passes -bridge overrides the first, and an empty game is "unset".
    $root = Get-Content packaging\release\config.json -Raw
    $cStart = $root.IndexOf('  "client": {')
    $cEnd = if ($cStart -ge 0) { $root.IndexOf("`n  },", $cStart) } else { -1 }
    if ($cStart -lt 0 -or $cEnd -lt 0) {
        throw 'packaging\release\config.json has no "client": { ... }, block shaped the way staging expects'
    }
    $text = "{`n" + $root.Substring($cStart, $cEnd - $cStart) + "`n  }`n}`n"
    # A per-game file carries only what a player might touch: the basics, collision and the render
    # group. Everything else (keepalive, rate caps, transport and tls pins, the machine-local
    # bridge, diagnostics, the protocol-level trio) is ABSENT and takes the built-in default, which
    # equals the shipped value; the root config.json keeps the complete set for the server and the
    # hand-run client, and README.txt's ADVANCED list says a missing key can be added to a game's
    # file. The user's call, 2026-09-03: no good reason for a player to turn tls off or pick udp.
    $hidden = @('keepalive', 'min_send', 'max_receive_hz_per_player', 'transport', 'tls', 'tls_fingerprint',
                'local_game_bridge', 'stats', 'game', 'game_version', 'features')
    foreach ($h in $hidden) {
        $text = [regex]::Replace($text, '(?m)^\s*"' + [regex]::Escape($h) + '"\s*:.*\r?\n', '')
    }
    $text = [regex]::Replace($text, '(\r?\n)(\s*\r?\n)+', '$1$1')        # one blank line at most
    $text = [regex]::Replace($text, '\r?\n\s*\r?\n(\s*})', "`n" + '$1')     # none before a closing brace
    $text = [regex]::Replace($text, ',(\s*\r?\n\s*})', '$1')               # no comma on the last key
    $game = Split-Path $f -Leaf
    $ovPath = $overridesFor[$f]
    if (Test-Path $ovPath) {
        $ov = Get-Content $ovPath -Raw | ConvertFrom-Json
        $applied = @()
        foreach ($prop in $ov.PSObject.Properties) {
            if ($prop.Name -like '_comment*') { continue }
            $pattern = '("' + [regex]::Escape($prop.Name) + '"\s*:\s*)"[^"]*"'
            # A real match test, not "did the text change": an override whose value equals the
            # source's (Pseudoregalia's local_game_bridge, once the root config carried it) used
            # to read as "not found" and be INSERTED a second time -- a duplicate key that JSON
            # parsers resolve silently. Found by the dry run on 2026-09-02.
            if ([regex]::IsMatch($text, $pattern)) {
                $text = [regex]::Replace($text, $pattern, ('${1}"' + $prop.Value + '"'))
                $applied += "$($prop.Name) (replaced)"
                continue
            }
            # Not in the template. INSERT it into the client block rather than failing, because a
            # game may legitimately need a setting the shared template deliberately omits --
            # local_game_bridge is exactly that: honoured by Pseudoregalia, meaningless for TEVI,
            # so it must not sit in the file every game gets.
            #
            # The old behaviour here was to throw, which protected against a typo silently doing
            # nothing. That protection is kept in a different form: an addition is REPORTED as
            # "(added)" in this script's output, so a misspelled key shows up as a new setting
            # appearing rather than an existing one changing. Watch that line.
            # Anchored on the LAST key of the client block, so an added key lands in the advanced
            # tier at the bottom (the tiers are the user's, 2026-08-30) rather than at the top of
            # the basics, which is where the old "connect_to" anchor put it.
            $anchor = '"features"'
            $at = $text.IndexOf($anchor)
            if ($at -lt 0) {
                throw "$ovPath adds '$($prop.Name)' but config.json's client block has no `"features`" line to anchor the insertion to."
            }
            $lineStart = $text.LastIndexOf("`n", $at) + 1
            $indent = ($text.Substring($lineStart) -replace '(?s)^(\s*).*', '$1')
            $text = $text.Insert($lineStart, "$indent`"$($prop.Name)`": `"$($prop.Value)`",`n")
            $applied += "$($prop.Name) (added)"
        }
        Write-Host "  $game config: overrode $($applied -join ', ')"
    }
    # WriteAllText with an explicit no-BOM encoder, NOT Set-Content -Encoding utf8: PowerShell
    # 5.1 writes a BOM for that, and the tracked config.json has none. internal/cfg.StripBOM means
    # a BOM would in fact load fine -- it exists because Windows editors save them -- but a staged
    # file that differs from its source by three invisible bytes is a difference nobody wants to
    # rediscover.
    [System.IO.File]::WriteAllText((Join-Path (Resolve-Path $f) 'config.json'), $text, (New-Object System.Text.UTF8Encoding $false))
}
# Emerald and Crystal: the scripts, and the LuaSocket build beside each. Their config.json was
# staged by the loop above; the exe stays at the release root, where the scripts look for it.
New-Item -ItemType Directory -Force packaging\release\games\pokemon\emerald | Out-Null
Copy-Item adapters\emulator\pokemon\emerald\meshghost_emerald.lua packaging\release\games\pokemon\emerald\ -Force
# Remove any staged lib\ from a previous run first: Copy-Item -Recurse into an EXISTING
# directory copies the source INTO it, so a re-run used to leave a doubled lib\lib\ nesting
# in the staged tree (found 2026-09-01; CI stages into a clean checkout and never saw it).
if (Test-Path packaging\release\games\pokemon\emerald\lib) {
    Remove-Item -Recurse -Force packaging\release\games\pokemon\emerald\lib
}
Copy-Item -Recurse -Force adapters\emulator\pokemon\emerald\lib packaging\release\games\pokemon\emerald\lib

# Crystal's lib\ comes from Emerald's: it is the same BizHawk LuaSocket build, and
# adapters/emulator/pokemon/crystal/ deliberately has no copy of its own -- in a source checkout
# the script falls back to ../emerald/lib/x64/, and a release gives each game folder its own so
# that fallback is never needed by a player.
New-Item -ItemType Directory -Force packaging\release\games\pokemon\crystal | Out-Null
Copy-Item adapters\emulator\pokemon\crystal\meshghost_crystal.lua packaging\release\games\pokemon\crystal\ -Force
# Same re-run guard as Emerald's above.
if (Test-Path packaging\release\games\pokemon\crystal\lib) {
    Remove-Item -Recurse -Force packaging\release\games\pokemon\crystal\lib
}
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
