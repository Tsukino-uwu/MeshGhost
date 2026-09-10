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

# replay/ and replay/active/, EMPTY, beside the client. The client creates them at startup too, but
# shipping them means a player sees where a clip goes on the first unzip rather than after a first
# run -- and docs/config.md's "drop a file into replay/active/" then names a folder that is already
# there. Compress-Archive does preserve an empty directory (checked 2026-09-03: the nested entry
# survives as `replay\active\`), so these reach the zip rather than being quietly dropped.
$replayActive = Join-Path 'packaging\release' 'replay\active'
if (-not (Test-Path -LiteralPath $replayActive)) {
    New-Item -ItemType Directory -Force -Path $replayActive | Out-Null
}

# Each game gets its own config.json, but NOT its own copy of the client -- shipping a 9 MB
# binary per game was rejected on 2026-08-18. The player copies meshghost.exe in once per game,
# which is the one manual step in the install and is called out in each game's README.txt.
#
# WHERE the per-game config is staged changed on 2026-09-05 (the user's call): for TEVI and
# Pseudoregalia it sits in games\<game>\ beside that game's README.txt, NOT inside the mod folder
# a player drags into the game. The mods now look for meshghost.exe and config.json in the
# GAME'S ROOT folder only (CoreLauncher.cs / CoreLauncher.cpp), so a config staged inside the mod
# folder would be dragged in with the mod and then read by nothing -- the exact trap a player
# editing "the config.json in the mod folder" would fall into. The player copies this file up
# with the exe. Emerald and Crystal are unchanged: their scripts run from the release folder and
# read the config beside the script (joined 2026-09-02; plans.md "Settings" step 3).
$modFolders = @(
    'packaging\release\games\pseudoregalia',
    'packaging\release\games\tevi',
    'packaging\release\games\pokemon\emerald',
    'packaging\release\games\pokemon\crystal'
)
# Where each folder's overrides live: packaging\config-overrides\<game>.json, OUTSIDE the release
# tree. They sat inside it as games\<game>\client-config-overrides.json until 2026-09-05 and so
# shipped in every zip as an empty {} that no runtime reads -- a player found one and asked whether
# it was where name and colour go. A staging input has no business in the download; a game with
# no file here simply gets the root client block unchanged.
$overridesFor = @{
    'packaging\release\games\pseudoregalia' = 'packaging\config-overrides\pseudoregalia.json'
    'packaging\release\games\tevi' = 'packaging\config-overrides\tevi.json'
    'packaging\release\games\pokemon\emerald' = 'packaging\config-overrides\emerald.json'
    'packaging\release\games\pokemon\crystal' = 'packaging\config-overrides\crystal.json'
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
    # 'offline' and 'local_interp' joined the list on 2026-09-03 (ADR 0049 and its sibling):
    # offline is a deliberate advanced choice the user asked to keep out of the per-game files,
    # and local_interp is a render knob for a ghost this client invented that nobody should
    # need to touch -- 'interp', the one a player really does tune, stays.
    $hidden = @('keepalive', 'min_send', 'max_receive_hz_per_player', 'transport', 'tls', 'tls_fingerprint',
                'local_game_bridge', 'stats', 'game', 'game_version', 'features', 'offline', 'local_interp')
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
            # A string value is emitted quoted, a number bare (2026-09-06: Pseudoregalia's three
            # distance-tier ranges are the first numeric per-game keys; before this every override
            # became a quoted string, which is wrong for a number a player is meant to edit).
            $literal = if ($prop.Value -is [string]) { '"' + $prop.Value + '"' } else { [string]$prop.Value }
            $pattern = '("' + [regex]::Escape($prop.Name) + '"\s*:\s*)("[^"]*"|[-0-9.]+|true|false)'
            # A real match test, not "did the text change": an override whose value equals the
            # source's (Pseudoregalia's local_game_bridge, once the root config carried it) used
            # to read as "not found" and be INSERTED a second time -- a duplicate key that JSON
            # parsers resolve silently. Found by the dry run on 2026-09-02.
            if ([regex]::IsMatch($text, $pattern)) {
                $text = [regex]::Replace($text, $pattern, ('${1}' + $literal))
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
            # Appended as the LAST key of the client block, so an added key lands in the advanced
            # tier at the bottom (the tiers are the user's, 2026-08-30) rather than at the top of
            # the basics, which is where the old "connect_to" anchor put it. Anchored on the block's
            # closing brace rather than on a named key: the previous anchor was `"features"`, which
            # the hidden-key pass above had already deleted, so every addition threw (found
            # 2026-09-06 by the first numeric addition). The comma pass above has already stripped
            # the last key's comma, so the added line brings its own.
            $close = $text.LastIndexOf("`n  }")
            if ($close -lt 0) {
                throw "$ovPath adds '$($prop.Name)' but config.json's client block has no closing brace to anchor the insertion to."
            }
            $text = $text.Insert($close, ",`n    `"$($prop.Name)`": $literal")
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

# docs\ -- the player guides, copied from the repo's docs/ rather than written twice. README.txt
# used to BE the whole walkthrough at 1046 lines, which meant every rule about hosting, settings
# and troubleshooting had two homes (that file and docs/) and could only drift. Now docs/ is the
# single copy and README.txt is a map pointing into it, so a fix lands once.
#
# Staged as .txt, not .md: the reader this is for double-clicks a file, and .md has no default
# association on Windows -- it prompts "how do you want to open this?" instead of opening. The
# markdown link syntax is flattened on the way in for the same reason, so `[hosting.md](hosting.md)`
# reads as `hosting.md` in Notepad instead of as punctuation. The .md name in the link text then
# points at the .txt of the same name sitting beside it, which is close enough to follow.
#
# FOUR PAGES ARE STAGED, not every docs/*.md (2026-09-10, the user's call): how to play, how to
# host, what the settings do, what to do when it does not work. They are exactly the four
# README.txt's own map names, so the zip advertises everything it carries and carries everything it
# advertises. The other docs/ pages answer questions a reader has a browser for -- auditing the
# code, the wire protocol, putting MeshGhost in a game of their own -- and shipping them made the
# zip's docs\ folder a place to get lost in.
#
# Every EARLIER version of this comment said the opposite, and its reasoning was sound: "a subset
# needs maintaining, and the moment one staged page links to an unstaged one the reader hits a dead
# end." Eleven such pointers existed the day the subset was cut. So the subset does not rely on
# anyone maintaining it -- $stagedDocs drives both the copy and the link rewrite below, and a
# pointer to a page that is NOT staged becomes a URL rather than the name of a file the reader does
# not have. Adding a page back to the zip is one entry in this list and nothing else.
$stagedDocs = @('getting-started', 'hosting', 'config', 'troubleshooting')
$docsUrlBase = 'https://github.com/Tsukino-uwu/MeshGhost/blob/master/docs'
$docsDest = 'packaging\release\docs'
if (Test-Path $docsDest) { Remove-Item -Recurse -Force $docsDest }
New-Item -ItemType Directory -Force $docsDest | Out-Null
$docCount = 0
foreach ($doc in (Get-ChildItem 'docs\*.md' | Sort-Object Name)) {
    if ($stagedDocs -notcontains $doc.BaseName) { continue }
    # ReadAllText with an explicit UTF8 encoding, NOT Get-Content -Raw: the docs are UTF-8 with no
    # BOM, and PowerShell 5.1 reads a BOM-less file as the system ANSI codepage -- so every em dash
    # and arrow in them came through as mojibake and was then written back out as genuinely
    # corrupt UTF-8 (caught in the first dry run of this step).
    $body = [System.IO.File]::ReadAllText($doc.FullName, [System.Text.Encoding]::UTF8)
    # [label](target) -> label. Images ![alt](src) go first so the leftover '!' does not survive.
    $body = [regex]::Replace($body, '!\[([^\]]*)\]\([^)]*\)', '$1')
    $body = [regex]::Replace($body, '\[([^\]]+)\]\([^)]*\)', '$1')
    # A label that names a sibling page reads as "hosting.md", but the file beside it is
    # hosting.txt -- and since 2026-09-10 the page it names may not be in the zip at all. So the
    # extension is not rewritten blindly: a STAGED page becomes the .txt sitting beside the reader,
    # an UNSTAGED one becomes the URL of the page in the repository, and a .md that is not a docs/
    # page at all (a mention of a file elsewhere in the tree) is left exactly as written. Getting
    # that last case wrong would invent a docs/ URL for a file that was never there.
    #
    # Two shapes, one evaluator: the bare sibling name "security.md", and the same page written as
    # a REPO path, "docs/security.md", which the deeper guides use to cite each other. 39 of the
    # second kind were dead in the zip until 2026-09-10. `agent_docs/...` is deliberately NOT
    # matched -- agent_docs\ is not shipped, so those name the repository honestly and must stay as
    # they are. The lookbehind is what separates them: `_` is a word character, so `agent_docs/`
    # cannot match.
    #
    # THE PATH SHAPE GOES FIRST, and the order is load-bearing now that the evaluator can emit a
    # URL. A URL ends in ".../docs/security.md", which is itself the path shape -- so running the
    # bare pass first produced a URL that the path pass then prefixed a SECOND time (seen in the
    # dry run, 2026-09-10). This way round cannot recurse: the bare pattern's lookbehind refuses a
    # name preceded by "/", so it never matches inside a URL the path pass has already written.
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
# Checked by NAME, not by count: the list above is the whole contract with README.txt, so a page
# renamed or deleted in docs/ has to stop the release rather than quietly ship a zip whose map
# points at a file that is not in it.
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
