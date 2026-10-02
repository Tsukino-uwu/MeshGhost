<#
.SYNOPSIS
Assembles the Windows release into packaging\release\, exactly as a real release does.

.DESCRIPTION
packaging\release\ holds only the hand-written half (the READMEs, config.json and the committed
TEVI/Pseudoregalia mods). This adds the Go binaries, the Emerald/Crystal adapter scripts, each
game's config.json and the player guides, so a release can be tried without cutting one: the
launchers in dev-scripts reach the adapters at their source paths and never exercise the layout a
player installs.

release.yml calls this same script rather than repeating its steps: a second copy would drift, and
a dry run that stages something slightly different from the release reports success about the
wrong thing.

.PARAMETER NoBuild
Skip building the two .exe files. release.yml passes this because it builds them in its own
earlier steps (with the same flags) and needs them at the repo root for other jobs.

.PARAMETER ForRelease
Accepted for release.yml's sake; a no-op.

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
    # The same flags release.yml uses (-trimpath, not stripped), so a dry run stages the binary shape the release ships.
    go build -trimpath -o meshghost.exe ./cmd/meshghost
    if ($LASTEXITCODE -ne 0) { throw 'go build ./cmd/meshghost failed' }
    # Renamed on the way in: one program, two names.
    go build -trimpath -o meshghost-server.exe ./cmd/meshghost-relay
    if ($LASTEXITCODE -ne 0) { throw 'go build ./cmd/meshghost-relay failed' }
}

foreach ($exe in @('meshghost.exe', 'meshghost-server.exe')) {
    if (-not (Test-Path $exe)) {
        throw "$exe is not at the repo root. Run without -NoBuild, or build it first."
    }
}

# Removes one key from a client block held as text: a scalar line, or a nested block closed by the first } line at
# its own indent (not a brace counter: a wrong counter is wrong silently, an unclosed block throws). A missing key
# throws too: it was renamed or deleted, and $gameOnly must follow.
function Remove-ClientKey {
    param([string]$Text, [string]$Name)

    $lines = $Text -split "`r?`n"
    $open = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^\s*"' + [regex]::Escape($Name) + '"\s*:')) { $open = $i; break }
    }
    if ($open -lt 0) {
        throw "stage-release: client key '$Name' is not in packaging\release\config.json -- if it was renamed or removed, update `$gameOnly."
    }
    $last = $open
    if ($lines[$open] -match '\{\s*$') {
        $indent = ($lines[$open] -replace '^(\s*).*$', '$1')
        $close = -1
        for ($i = $open + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^' + $indent + '\},?\s*$')) { $close = $i; break }
        }
        if ($close -lt 0) {
            throw "stage-release: client key '$Name' opens a block that never closes at its own indent."
        }
        $last = $close
    }
    $kept = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -ge $open -and $i -le $last) { continue }
        $kept += $lines[$i]
    }
    return ($kept -join "`n")
}

Write-Host '== Staging into packaging\release\ =='
# A running relay or client holds its .exe open, and restaging mid-session is ordinary: an identical binary is skipped,
# and a locked one that differs fails naming the process rather than with a raw IOException.
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

# replay\active\, empty: the client creates it too, but shipped, a player sees where a clip goes on the first unzip.
# Compress-Archive keeps an empty directory, so it reaches the zip.
$replayActive = Join-Path 'packaging\release' 'replay\active'
if (-not (Test-Path -LiteralPath $replayActive)) {
    New-Item -ItemType Directory -Force -Path $replayActive | Out-Null
}

# Each game gets its own config.json but not its own client: the player copies meshghost.exe in once per game.
# TEVI's and Pseudoregalia's sits in games\<game>\, not in the mod folder: the mods read meshghost.exe and config.json
# from the game's root only, so one dragged in with the mod would be read by nothing. Emerald's and Crystal's scripts
# read the config beside the script.
$modFolders = @(
    'packaging\release\games\pseudoregalia',
    'packaging\release\games\tevi',
    'packaging\release\games\pokemon\emerald',
    'packaging\release\games\pokemon\crystal'
)
# Overrides live outside the release tree so a staging input never ships; a game with no file gets the root client
# block unchanged.
$overridesFor = @{
    'packaging\release\games\pseudoregalia' = 'packaging\config-overrides\pseudoregalia.json'
    'packaging\release\games\tevi' = 'packaging\config-overrides\tevi.json'
    'packaging\release\games\pokemon\emerald' = 'packaging\config-overrides\emerald.json'
    'packaging\release\games\pokemon\crystal' = 'packaging\config-overrides\crystal.json'
}
foreach ($f in $modFolders) {
    New-Item -ItemType Directory -Force $f | Out-Null
    # The root config.json's "client" block, verbatim, with this game's overrides on top: the overrides hold only the
    # keys that differ, so the client settings have one copy. Text surgery, not ConvertTo-Json, which reorders the keys
    # and loses the layout: two tiers, basics, a blank line, then the advanced set.
    $root = Get-Content packaging\release\config.json -Raw
    $cStart = $root.IndexOf('  "client": {')
    $cEnd = if ($cStart -ge 0) { $root.IndexOf("`n  },", $cStart) } else { -1 }
    if ($cStart -lt 0 -or $cEnd -lt 0) {
        throw 'packaging\release\config.json has no "client": { ... }, block shaped the way staging expects'
    }
    $text = "{`n" + $root.Substring($cStart, $cEnd - $cStart) + "`n  }`n}`n"
    # A per-game file carries only what a player might touch; every hidden key takes the built-in default, which equals
    # the shipped value, and the root config.json keeps the complete set. 'tls' and 'tls_fingerprint' are obsolete and
    # listed only to strip them from a stale root config.
    $hidden = @('keepalive', 'min_send', 'max_receive_hz_per_player', 'transport', 'tls', 'tls_fingerprint',
                'local_game_bridge', 'stats', 'game', 'game_version', 'features', 'offline', 'local_interp')
    foreach ($h in $hidden) {
        $text = [regex]::Replace($text, '(?m)^\s*"' + [regex]::Escape($h) + '"\s*:.*\r?\n', '')
    }
    # A key one game's mod reads is stripped from every other game's file; the root config.json keeps them all.
    # notClientSettings in cmd/meshghost/main.go says these keys belong to a mod; this says which. Removed, not moved
    # into the override files: an override value is a scalar, and input_display is a laid-out block.
    $gameOnly = @{
        'map_markers'   = 'tevi'           # TEVI's pause-menu peer markers (CoreLauncher.cs)
        'input_display' = 'pseudoregalia'  # Pseudoregalia's input overlay (Plugin.cpp)
    }
    foreach ($key in $gameOnly.Keys) {
        if ($gameOnly[$key] -eq (Split-Path $f -Leaf)) { continue }
        $text = Remove-ClientKey -Text $text -Name $key
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
            # A string is emitted quoted, a number bare, a bool on its own: [string]$true is "True", not JSON.
            $literal = if ($prop.Value -is [string]) { '"' + $prop.Value + '"' }
                       elseif ($prop.Value -is [bool]) { if ($prop.Value) { 'true' } else { 'false' } }
                       else { [string]$prop.Value }
            $pattern = '("' + [regex]::Escape($prop.Name) + '"\s*:\s*)("[^"]*"|[-0-9.]+|true|false)'
            # A real match test, not "did the text change": an override equal to the source would be inserted again.
            if ([regex]::IsMatch($text, $pattern)) {
                $text = [regex]::Replace($text, $pattern, ('${1}' + $literal))
                $applied += "$($prop.Name) (replaced)"
                continue
            }
            # Not in the block: inserted, since a game may need a key the shared block omits, and reported as
            # "(added)", so a misspelled key shows up as a new setting. Appended last, anchored on the closing brace
            # (a named key may be one the passes above deleted), so it lands in the advanced tier; the comma pass
            # already took the last key's comma, so the added line brings its own.
            $close = $text.LastIndexOf("`n  }")
            if ($close -lt 0) {
                throw "$ovPath adds '$($prop.Name)' but config.json's client block has no closing brace to anchor the insertion to."
            }
            $text = $text.Insert($close, ",`n    `"$($prop.Name)`": $literal")
            $applied += "$($prop.Name) (added)"
        }
        Write-Host "  $game config: overrode $($applied -join ', ')"
    }
    # A no-BOM encoder, not Set-Content -Encoding utf8: PowerShell 5.1 writes a BOM there, and the source has none.
    [System.IO.File]::WriteAllText((Join-Path (Resolve-Path $f) 'config.json'), $text, (New-Object System.Text.UTF8Encoding $false))
}
# Emerald and Crystal: the scripts, and the LuaSocket build beside each. Their config.json was
# staged by the loop above; the exe stays at the release root, where the scripts look for it.
New-Item -ItemType Directory -Force packaging\release\games\pokemon\emerald | Out-Null
Copy-Item adapters\emulator\pokemon\emerald\meshghost_emerald.lua packaging\release\games\pokemon\emerald\ -Force
# A previous run's lib\ goes first: Copy-Item -Recurse into an existing directory nests the source inside it.
if (Test-Path packaging\release\games\pokemon\emerald\lib) {
    Remove-Item -Recurse -Force packaging\release\games\pokemon\emerald\lib
}
Copy-Item -Recurse -Force adapters\emulator\pokemon\emerald\lib packaging\release\games\pokemon\emerald\lib

# Crystal's lib\ is Emerald's, the same LuaSocket build: the source tree has one copy, a release one per game folder.
New-Item -ItemType Directory -Force packaging\release\games\pokemon\crystal | Out-Null
Copy-Item adapters\emulator\pokemon\crystal\meshghost_crystal.lua packaging\release\games\pokemon\crystal\ -Force
# Same re-run guard as Emerald's above.
if (Test-Path packaging\release\games\pokemon\crystal\lib) {
    Remove-Item -Recurse -Force packaging\release\games\pokemon\crystal\lib
}
Copy-Item -Recurse -Force adapters\emulator\pokemon\emerald\lib packaging\release\games\pokemon\crystal\lib

# The experiment flag would run an Archipelago ROM on an unconfirmed address. Checked at the source: the copies above
# name their files, so a guard on the staged folder could never fire.
if (Test-Path adapters\emulator\pokemon\crystal\ap_try.flag) {
    throw 'ap_try.flag must never be packaged'
}

# A relay run from packaging\release\ writes its identity into private\, and a client its known_servers.json. Shipped,
# server.key would make every install the same relay to every client that had connected to any of them.
if (Test-Path packaging\release\private) {
    throw 'packaging\release\private\ exists (a relay was run from the release folder); delete it -- server.key is a private key and must never be packaged'
}
if (Test-Path packaging\release\known_servers.json) {
    throw 'packaging\release\known_servers.json exists (a client was run from the release folder); delete it -- a release ships nobody''s remembered servers'
}

# docs\: the player guides, copied from the repo's docs/ so each has one home, as .txt with the links flattened,
# since .md has no default association on Windows. Only the four README.txt's map names are staged; $stagedDocs
# drives both the copy and the link rewrite, so a pointer to an unstaged page becomes its URL.
$stagedDocs = @('getting-started', 'hosting', 'config', 'troubleshooting')
$docsUrlBase = 'https://github.com/Tsukino-uwu/MeshGhost/blob/master/docs'
$docsDest = 'packaging\release\docs'
if (Test-Path $docsDest) { Remove-Item -Recurse -Force $docsDest }
New-Item -ItemType Directory -Force $docsDest | Out-Null
$docCount = 0
foreach ($doc in (Get-ChildItem 'docs\*.md' | Sort-Object Name)) {
    if ($stagedDocs -notcontains $doc.BaseName) { continue }
    # An explicit UTF8 encoding, not Get-Content -Raw: PowerShell 5.1 reads a BOM-less file as the ANSI codepage.
    $body = [System.IO.File]::ReadAllText($doc.FullName, [System.Text.Encoding]::UTF8)
    # [label](target) -> label. Images ![alt](src) go first so the leftover '!' does not survive.
    $body = [regex]::Replace($body, '!\[([^\]]*)\]\([^)]*\)', '$1')
    $body = [regex]::Replace($body, '\[([^\]]+)\]\([^)]*\)', '$1')
    # A staged page becomes the .txt beside it, an unstaged docs page its repository URL, and any other .md name stays
    # as written. Two shapes: a bare sibling name and a docs/ repo path; agent_docs/ is not shipped and not matched, as
    # `_` is a word character. The path pass goes first: a URL ends in the path shape, and the bare pattern's
    # lookbehind refuses a name after "/", so neither pass rewrites the other's output.
    $pointer = {
        param($m)
        $page = $m.Groups[1].Value
        if ($stagedDocs -contains $page) { return "$page.txt" }
        if (Test-Path -LiteralPath "docs\$page.md") { return "$docsUrlBase/$page.md" }
        return $m.Value
    }
    $body = [regex]::Replace($body, '(?<!\w)docs/([a-z0-9][a-z0-9-]*)\.md\b', $pointer)
    $body = [regex]::Replace($body, '(?<![\w/\\.])([a-z0-9][a-z0-9-]*)\.md\b', $pointer)
    $out = Join-Path $docsDest ($doc.BaseName + '.txt')
    [System.IO.File]::WriteAllText($out, $body, (New-Object System.Text.UTF8Encoding $false))
    $docCount++
}
# By name, not count: a page renamed or deleted in docs/ must stop the release, not ship a map to a missing file.
$missingDocs = @($stagedDocs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $docsDest "$_.txt")) })
if ($missingDocs.Count -gt 0) {
    throw "docs\ staged $docCount of $($stagedDocs.Count) guide(s) -- missing: $($missingDocs -join ', '). README.txt points at getting-started, hosting, troubleshooting and config by name, so the zip would ship dead pointers."
}
Write-Host "  docs\: staged $docCount guide(s) from docs\*.md"

Write-Host ''
Write-Host 'Staged. packaging\release\ now holds what a player unzips:'
Write-Host '  meshghost.exe / meshghost-server.exe / config.json'
Write-Host '  games\pokemon\emerald\  games\pokemon\crystal\   (adapter + lib, load in place)'
Write-Host '  games\tevi\  games\pseudoregalia\                (install into the game, then'
Write-Host '                                                    copy meshghost.exe in beside the mod)'
Write-Host '  docs\                                             (the player guides, from docs\*.md)'
Write-Host ''
Write-Host 'What this does NOT prove: the zip step, the Linux/macOS builds, and the staleness'
Write-Host 'gates release.yml runs against the committed mod DLLs. Those stay CI-only.'
