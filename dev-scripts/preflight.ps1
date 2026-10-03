[CmdletBinding()]
param(
    # Run only the checks a bare checkout can answer; skip what needs built binaries, deployed DLLs or processes.
    [switch]$TreeOnly
)

# MeshGhost preflight: a read-only check run before handing over a game to test; it builds, deploys and commits nothing.
# Exit 0 when clean, 1 when any check fails; warnings do not fail the run.
# -TreeOnly skips every check that needs a working copy rather than just the tree.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
# Also sets the .NET working directory: the [IO.File] reads below resolve relative paths against it, not Set-Location.
[Environment]::CurrentDirectory = $root

$script:failures = 0
$script:warnings = 0

function Report-Pass($msg) { Write-Host "  PASS  $msg" }
function Report-Fail($msg) { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:failures++ }
function Report-Warn($msg) { Write-Host "  WARN  $msg" -ForegroundColor Yellow; $script:warnings++ }
function Section($name)    { Write-Host ""; Write-Host "== $name ==" }
function Report-Skip($msg) { Write-Host "  SKIP  $msg" -ForegroundColor DarkGray }

function Read-GateList([string]$name) {
    $entries = [ordered]@{}
    $on = $false
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root 'dev-scripts\gate-lists.txt'))) {
        if ($line -match '^\[(.+)\]') { $on = ($Matches[1] -eq $name); continue }
        if (-not $on -or $line -match '^\s*(#|$)') { continue }
        $parts = $line.Trim() -split '\s+', 2
        $entries[$parts[0]] = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }
    if ($entries.Count -eq 0) { throw "dev-scripts/gate-lists.txt has no [$name] entries" }
    return $entries
}
$gateExemptPaths = @((Read-GateList 'exempt').Keys)
$gateExempt = @($gateExemptPaths | ForEach-Object { ":!$_" })
$gateHome = @((Read-GateList 'home-patterns').Keys)
$gateClone = @((Read-GateList 'clone-patterns').Keys)
function Grep-Patterns($patterns) { $patterns | ForEach-Object { '-e'; $_ } }

# git grep exits 0 on matches, 1 on none, and above 1 when it could not run, which must never read as clean.
function Report-GrepGate($exitCode, $hits, $failMsg, $passMsg) {
    if ($exitCode -eq 0 -and $hits) {
        Report-Fail $failMsg
        $hits | ForEach-Object { Write-Host "          $_" }
    } elseif ($exitCode -gt 1) {
        Report-Fail "the grep behind '$passMsg' exited $exitCode -- it did not run, so this is NOT a clean result"
    } else {
        Report-Pass $passMsg
    }
}

# Filtered in PowerShell, not by a '*.md' pathspec: an MSYS2 git found first glob-expands that against the root.
$trackedMd = @(& git ls-files | Where-Object { $_ -like '*.md' })
if ($trackedMd.Count -lt 40) {
    Report-Fail "only $($trackedMd.Count) tracked .md file(s) found -- the listing is broken, so the doc checks below would pass vacuously. Not a clean result."
}

# Under Stop, one tracked-but-deleted file would make Get-Content end the run, so it is reported once and dropped.
$missingTracked = @($trackedMd | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingTracked.Count -gt 0) {
    Report-Fail "$($missingTracked.Count) file(s) tracked by git but missing from the working tree:"
    $missingTracked | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    $trackedMd = @($trackedMd | Where-Object { Test-Path -LiteralPath $_ })
}


# Refuses a tracked or untracked .go file that is not gofmt-clean.
Section "Go source hygiene"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

# Untracked files too: a new .go file is invisible to git ls-files until it is staged.
$goFiles = @(& git ls-files '*.go')
$goFiles += @(& git status --porcelain --untracked-files=all |
              Where-Object { $_ -like '?? *.go' -or $_ -like '?? *' -and $_ -match '\.go$' } |
              ForEach-Object { $_.Substring(3).Trim('"') })
$goFiles = @($goFiles | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)
$unformatted = & gofmt -l $goFiles
if ($unformatted) {
    Report-Fail "not gofmt-clean: $($unformatted -join ', ')  -- run: gofmt -w <file>"
} else {
    Report-Pass "all $($goFiles.Count) .go file(s) are gofmt-clean, tracked and untracked"
}
}

# Refuses an unarmed pre-commit hook, and a home path, clone path, public IP or unlisted hostname in a tracked file.
Section "Public-repo leak check"

if ($TreeOnly) {
    Report-Skip "hook arming is per-clone git config -- nothing a runner can answer"
} else {
    $hooksPath = (& git config core.hooksPath) 2>$null
    if ($hooksPath -eq ".githooks") {
        Report-Pass "core.hooksPath is .githooks -- the pre-commit leak check is armed"
    } else {
        Report-Fail "core.hooksPath is not set to .githooks, so commits are NOT being checked for machine-specific paths -- run: git config core.hooksPath .githooks"
    }
}


$leaks = & git grep -inIF @(Grep-Patterns $gateHome) -- . @gateExempt
Report-GrepGate $LASTEXITCODE $leaks "machine-identifying path in a tracked file:" `
    "no username or home-directory path in tracked files"

# Scripts only: prose legitimately quotes the clone path when it states the ask-before-touching boundary.
$clonePaths = & git grep -inIF @(Grep-Patterns $gateClone) -- '*.ps1' '*.bat' '*.sh' '*.lua' '*.go' '*.cs' '*.cpp' '*.hpp' @gateExempt
Report-GrepGate $LASTEXITCODE $clonePaths "hardcoded clone path in a tracked script -- use `$PSScriptRoot, debug.getinfo, or a path relative to the script:" `
    "no script hardcodes an absolute path to the clone"

$ipAllow = @{
    '0.0.0.0'      = 'wildcard bind'
    '1.2.3.4'      = 'placeholder address in docs and tests'
    '2.2.2.2'      = 'placeholder address in a test'
    '10.0.0.1'     = 'test fixture (core transport tests)'
    '10.0.0.5'     = 'test fixture (core transport tests)'
    '192.168.1.10' = 'documentation example of a LAN address'
    '5.4.23.3'     = 'NOT AN ADDRESS: BepInEx version'
    '5.4.23.5'     = 'NOT AN ADDRESS: BepInEx version (the standalone TEVI build)'
    '21.12.13.1'   = 'NOT AN ADDRESS: MonoMod package version, in the BepInEx projects'' packages.lock.json'
}

# The lookarounds stop a longer dotted run (UE4SS's 3.0.1.0.0) being mined for a four-part address.
$ipPattern = '(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.])'

# A coarse ERE picks files: git grep rejects lookarounds and PowerShell mangles {1,3}; .NET does the real match.
$ipFiles = & git grep -lIE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' -- . ':!dev-scripts/preflight.ps1' ':!dev-scripts/negative-test-preflight.ps1' ':!.githooks/'
$ipGrepExit = $LASTEXITCODE
$publicHits = @()
$privateHits = @()
if ($ipGrepExit -gt 1) {
    Report-Fail "the IP scan's git grep failed (exit $ipGrepExit) -- this section proved nothing; fix the grep rather than trusting the PASS"
} elseif ($ipGrepExit -le 1) {
    foreach ($f in @($ipFiles | Where-Object { $_ })) {
        $n = 0
        foreach ($line in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            $n++
            foreach ($m in [regex]::Matches($line, $ipPattern)) {
                $ip = $m.Groups[1].Value
                if ($ipAllow.ContainsKey($ip)) { continue }
                $o = $ip.Split('.') | ForEach-Object { [int]$_ }
                if ($o[0] -gt 255 -or $o[1] -gt 255 -or $o[2] -gt 255 -or $o[3] -gt 255) { continue }
                if ($o[0] -eq 127) { continue }
                if ($o[0] -eq 169 -and $o[1] -eq 254) { continue }
                if ($o[0] -ge 224) { continue }
                if ($o[0] -eq 192 -and $o[1] -eq 0 -and $o[2] -eq 2) { continue }
                if ($o[0] -eq 198 -and $o[1] -eq 51 -and $o[2] -eq 100) { continue }
                if ($o[0] -eq 203 -and $o[1] -eq 0 -and $o[2] -eq 113) { continue }
                $isPrivate = ($o[0] -eq 10) -or
                             ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) -or
                             ($o[0] -eq 192 -and $o[1] -eq 168)
                if ($isPrivate) { $privateHits += "${f}:${n}: $ip" }
                else { $publicHits += "${f}:${n}: $ip" }
            }
        }
    }
}
if ($publicHits.Count -gt 0) {
    Report-Fail "$($publicHits.Count) PUBLIC IP address(es) in tracked files -- a real host on the internet; genericize it (<relay>, <local>) or add it to this section's allowlist with a reason:"
    $publicHits | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
}
if ($privateHits.Count -gt 0) {
    Report-Warn "$($privateHits.Count) private/LAN IP address(es) in tracked files -- fine in a written example, NOT fine pasted out of someone's log:"
    $privateHits | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
}
if ($publicHits.Count -eq 0 -and $privateHits.Count -eq 0 -and $ipGrepExit -le 1) {
    Report-Pass "no IP address in a tracked file outside the allowlist, loopback and the RFC 5737 doc ranges"
}

$domainAllow = @{
    'github.com' = 'source links'; 'golang.org' = 'Go docs'; 'pkg.go.dev' = 'Go package docs'
    'go.dev' = 'Go docs'; 'go.uber.org' = 'dependency'; 'nuget.org' = 'NuGet'
    'filippo.io' = 'dependency (edwards25519/nistec, via the OPAQUE library, ADR 0067)'
    'api.nuget.org' = 'NuGet'; 'bepinex.dev' = 'BepInEx'; 'nuget.bepinex.dev' = 'BepInEx feed'
    'code.claude.com' = 'tooling'; 'signpath.org' = 'code signing'; 'signpath.io' = 'code signing'
    'www.virustotal.com' = 'scan results linked from security-design.md (2026-09-22)'
    'docs.unrealengine.com' = 'UE reference'; 'dev.epicgames.com' = 'UE reference'
    'epicgames.com' = 'UE reference'; 'docs.ue4ss.com' = 'UE4SS reference'
    'learn.microsoft.com' = 'Win32/.NET reference'; 'www.khronos.org' = 'graphics reference'
    'lua.org' = 'Lua reference'; 'www.lua.org' = 'Lua reference'
    'molecular-matters.com' = 'technical article'; 'www.humanlayer.dev' = 'technical article'
    'tasvideos.org' = 'emulator reference'; 'steamdb.info' = 'Steam build reference'
    'steamcommunity.com' = 'Steam reference'; 'www.nexusmods.com' = 'mod hosting'
    'gamebanana.com' = 'mod hosting'; 'archipelago.gg' = 'Archipelago'
    'warprandomizer.com' = 'randomizer reference'
    'demki.github.io' = 'reference'; 'kittypboxx.github.io' = 'reference'
    'carrion.wiki.gg' = 'game wiki'; 'warcraft.wiki.gg' = 'game wiki'
    'wiki.guildwars2.com' = 'game wiki'; 'ffxiv.fandom.com' = 'game wiki'
    'example.com' = 'RFC 2606 documentation domain'
    'system.io' = 'NOT A DOMAIN: C# namespace System.IO'
    'system.net' = 'NOT A DOMAIN: C# namespace System.Net'
    'microsoft.net' = 'NOT A DOMAIN: .NET framework name'
    'unicode.me' = 'NOT A DOMAIN: prose'; 'unicode.co' = 'NOT A DOMAIN: prose'
    'ref.no' = 'NOT A DOMAIN: prose'; 'e.info' = 'NOT A DOMAIN: prose'
    'env.io' = 'NOT A DOMAIN: Lua sandbox field env.io'
    'q.no' = 'NOT A DOMAIN: Lua field, a question table''s `no`'
    'question.no' = 'NOT A DOMAIN: Lua field, a question table''s `no`'
    's.info' = 'NOT A DOMAIN: Lua field, a route step''s `info`'
    'steamworks.net' = 'Steamworks.NET, the C# Steam binding (a library name)'
    'blizzardwatch.com' = 'reference article (kill-credit.md)'
}

$domainPattern = '(?i)\b[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.(com|net|org|eu|io|dev|de|uk|co|me|xyz|info|gg|tv|app|cloud|site|online|ru|fr|nl|se|no|fi|pl|it|es)\b'
$domFiles = & git grep -lIEi '[a-z0-9]\.(com|net|org|eu|io|dev|de|uk|co|me|xyz|info|gg|tv|app|cloud|site|online|ru|fr|nl|se|no|fi|pl|it|es)' -- . ':!dev-scripts/preflight.ps1' ':!dev-scripts/negative-test-preflight.ps1' ':!.githooks/'
$domGrepExit = $LASTEXITCODE
$domainHits = @()
if ($domGrepExit -gt 1) {
    Report-Fail "the hostname scan's git grep failed (exit $domGrepExit) -- this section proved nothing"
} elseif ($domGrepExit -le 1) {
    foreach ($f in @($domFiles | Where-Object { $_ })) {
        $n = 0
        foreach ($line in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            $n++
            foreach ($m in [regex]::Matches($line, $domainPattern)) {
                $host_ = $m.Value.ToLower()
                if ($domainAllow.ContainsKey($host_)) { continue }
                $parent = $false
                foreach ($k in $domainAllow.Keys) {
                    if ($host_.EndsWith(".$k")) { $parent = $true; break }
                }
                if (-not $parent) { $domainHits += "${f}:${n}: $host_" }
            }
        }
    }
}
if ($domainHits.Count -gt 0) {
    Report-Fail "$($domainHits.Count) hostname(s) in tracked files that are not on the allowlist -- if this is someone's relay or personal host, genericize it (<relay>, relay.example.com); if it is a reference link, add it to this section's allowlist:"
    $domainHits | Select-Object -Unique | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
} elseif ($domGrepExit -le 1) {
    Report-Pass "every hostname in a tracked file is an allowlisted reference, not somebody's machine"
}

# Refuses a root file outside the allowlist, and a tracked file whose own header says it must not be committed.
Section "Stray files: nothing at the root but the allowlist, nothing marked local-only"

$rootAllow = @((Read-GateList 'root-allow').Keys)
$rootTracked = @(& git ls-files | Where-Object { $_ -notmatch '/' })
$rootStray = @($rootTracked | Where-Object { $rootAllow -notcontains $_ })
if ($rootStray.Count -gt 0) {
    Report-Fail "tracked file(s) at the repo root that are not in preflight's root allowlist -- a stray, or add it there with a reason: $($rootStray -join ', ')"
} else {
    Report-Pass "the repo root holds exactly its $($rootAllow.Count) allowlisted files ($($rootTracked.Count) tracked)"
}

$localOnly = @()
foreach ($f in @(& git ls-files)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    if (@($gateExemptPaths | Where-Object { $f -eq $_ -or ($_.EndsWith('/') -and $f.StartsWith($_)) }).Count -gt 0) { continue }
    $head = @(Get-Content -LiteralPath $f -TotalCount 10 -ErrorAction SilentlyContinue)
    if (($head -join "`n") -match '(?i)deliberately untracked|do not commit') { $localOnly += $f }
}
if ($localOnly.Count -gt 0) {
    Report-Fail "tracked file(s) whose own header says they must not be committed: $($localOnly -join ', ')  -- git rm --cached it and add it to .gitignore"
} else {
    Report-Pass "no tracked file declares itself local-only in its first ten lines"
}

# Refuses a tracked binary that embeds a home-directory or clone path, unless it is a listed known leak.
Section "Machine-identifying strings inside tracked BINARIES"

$binaryPatterns = @($gateHome + $gateClone)
$binaryFiles = & git ls-files -- '*.dll' '*.exe' '*.so' '*.dylib' '*.pdb' '*.lib' '*.a' '*.bin' '*.node'

$newBinaryLeaks = @()
foreach ($bf in $binaryFiles) {
    if (-not (Test-Path -LiteralPath $bf)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($bf)
    # GetEncoding(28591): [Encoding]::Latin1 does not exist in 5.1; Latin-1 keeps every byte a character.
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $found = @()
    foreach ($p in $binaryPatterns) {
        if ($text.Contains($p)) { $found += $p }
    }
    if ($found.Count -eq 0) { continue }
    $newBinaryLeaks += "$(($bf -replace '\\', '/')) [$($found -join ', ')]"
}

if ($newBinaryLeaks.Count -gt 0) {
    Report-Fail "a tracked binary embeds a machine-identifying path (rebuild it with the build directory stripped -- /PDBALTPATH for MSVC, <PathMap> for C#, --remap-path-prefix for Rust):"
    foreach ($h in $newBinaryLeaks) { Write-Host "        $h" }
} else {
    Report-Pass "no tracked binary embeds a username or a clone path"
}

# Refuses a vague duration, or an unnumbered "<units> of" span of effort, in a tracked file.
Section "Invented durations"

# The append-only verification records are excluded: a hit there cannot be reworded without rewriting the record.
$durations = & git grep -inIE -e 'for (a |an |the last |the past )?(hour|day|week|month|year|decade)s?\b' -e '(hour|day|week|month|year|decade)s? (ago|later|earlier|old|behind)\b' -e '\b(that|this) (week|month|year|decade)s?\b' -e 'long-?standing' -e 'long time' -e '\bdecades\b' -e 'over the years' -- . ':!CLAUDE.md' ':!dev-scripts/preflight.ps1' ':!dev-scripts/negative-test-preflight.ps1' ':!agent_docs/verified.md' ':!adapters/**/VERIFIED.md'
Report-GrepGate $LASTEXITCODE $durations `
    "vague duration in a tracked file -- cite a date, or a measured figure with a number:" `
    "no vague durations in tracked files"

$unitOf = @(& git grep -inIE '\b(hour|day|week|month|year|decade)s of\b' -- . ':!CLAUDE.md' ':!dev-scripts/preflight.ps1' ':!dev-scripts/negative-test-preflight.ps1' ':!agent_docs/verified.md' ':!adapters/**/VERIFIED.md')
$unitOfCode = $LASTEXITCODE
# A lookbehind, so each occurrence is judged: one numbered figure on a line must not excuse an unnumbered one.
$unnumbered = '(?<!([0-9]|~[0-9]|\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve))\s{1,3})\b(hour|day|week|month|year|decade)s of\b'
if ($unitOfCode -gt 1) {
    Report-Fail "the '<units> of' duration grep did not run, so this is NOT a clean result (exit $unitOfCode)"
} else {
    $vague = @($unitOf | Where-Object { $_ -match $unnumbered })
    if ($vague.Count -gt 0) {
        Report-Fail "unmeasured span of effort -- say what was actually done, or give a number:"
        $vague | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every '<units> of' in a tracked file carries a number ($($unitOf.Count) checked)"
    }
}

# Refuses an instruction file or session stack over its line cap, and a line-cap header on any other file.
Section "Reading budgets"

$budgeted = @(
    'CLAUDE.md',
    'adapters/CLAUDE.md',
    'adapters/emulator/CLAUDE.md',
    'adapters/tevi/CLAUDE.md',
    'adapters/pseudoregalia/CLAUDE.md',
    '.claude/skills/new-adapter/SKILL.md',
    '.claude/skills/write-a-probe/SKILL.md',
    '.claude/skills/adversarial-review/SKILL.md',
    '.claude/skills/play-game/SKILL.md'
)
$withinCap = 0
$lineCount = @{}
foreach ($md in $budgeted) {
    if (-not (Test-Path -LiteralPath $md)) { Report-Fail "$md is in the budgeted set but does not exist"; continue }
    $head = @(Get-Content -LiteralPath $md -TotalCount 15)
    $decl = $head | Select-String -Pattern '<!--\s*line-cap:\s*(\d+)' | Select-Object -First 1
    if (-not $decl) { Report-Fail "$md is in the budgeted set but declares no <!-- line-cap: N --> in its first 15 lines"; continue }
    $cap = [int]$decl.Matches[0].Groups[1].Value
    # (Get-Content).Count, not Measure-Object -Line, which skips empty lines and would undercount against wc -l.
    $n = @(Get-Content -LiteralPath $md).Count
    $lineCount[$md] = $n
    if ($n -gt $cap) {
        Report-Fail "$md is $n lines, $($n - $cap) over its declared $cap-line cap. Something must come out first."
    } else {
        $withinCap++
    }
}
if ($withinCap -eq $budgeted.Count) {
    Report-Pass "all $($budgeted.Count) instruction files within their declared caps"
}

$strayCaps = @()
foreach ($md in $trackedMd) {
    if ($budgeted -contains $md) { continue }
    $head = @(Get-Content -LiteralPath $md -TotalCount 15)
    if ($head | Select-String -Pattern '<!--\s*line-cap:' -Quiet) { $strayCaps += $md }
}
if ($strayCaps.Count -gt 0) {
    Report-Fail "$($strayCaps.Count) file(s) outside the budgeted set still carry a line-cap header -- only instruction files are capped (claude-md-cap.md, 2026-09-02):"
    $strayCaps | Select-Object -First 15 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no line-cap header outside the $($budgeted.Count) budgeted files"
}

$stackCap = 650
$stacks = [ordered]@{
    'emulator'      = @('CLAUDE.md', 'adapters/CLAUDE.md', 'adapters/emulator/CLAUDE.md')
    'tevi'          = @('CLAUDE.md', 'adapters/CLAUDE.md', 'adapters/tevi/CLAUDE.md')
    'pseudoregalia' = @('CLAUDE.md', 'adapters/CLAUDE.md', 'adapters/pseudoregalia/CLAUDE.md')
}
$stacksOk = 0
foreach ($k in $stacks.Keys) {
    $sum = 0
    foreach ($f in $stacks[$k]) { if ($lineCount.ContainsKey($f)) { $sum += $lineCount[$f] } }
    if ($sum -gt $stackCap) {
        Report-Fail "the $k session stack loads $sum lines of rules, $($sum - $stackCap) over the $stackCap-line stack budget (root + adapters/ + host). Something comes out -- a line whose lesson is now a check first."
    } else { $stacksOk++ }
}
if ($stacksOk -eq $stacks.Count) { Report-Pass "all $($stacks.Count) session stacks within the $stackCap-line stack budget" }

# Refuses an index or queue entry that runs past one line.
Section "One-line entries"

$oneLine = @(
    @{ Path = 'agent_docs/verified.md';                        From = '^## Index'; To = '^## ' }
    @{ Path = 'adapters/tevi/VERIFIED.md';                     From = '^## Index'; To = '^## ' }
    @{ Path = 'adapters/pseudoregalia/VERIFIED.md';            From = '^## Index'; To = '^## ' }
    @{ Path = 'adapters/emulator/pokemon/emerald/VERIFIED.md'; From = '^## Index'; To = '^## ' }
    @{ Path = 'adapters/emulator/pokemon/crystal/VERIFIED.md'; From = '^## Index'; To = '^## ' }
    @{ Path = 'agent_docs/pitfalls/INDEX.md';                  From = '';          To = '' }
    @{ Path = 'agent_docs/checklists/before-a-probe.md';               From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-trusting-a-reading.md';    From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-declaring-a-fix.md';       From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-a-scripted-edit.md';       From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-mirroring-state.md';       From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-spawning-in-unreal.md';    From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-touching-lua.md';          From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/checklists/before-a-network-change.md';      From = '^## Every lesson'; To = '' }
    @{ Path = 'agent_docs/status.md';                                  From = '';          To = '' }
    @{ Path = 'agent_docs/README.md';                                  From = '^## The rules'; To = '^## How to use' }
    @{ Path = 'adapters/emulator/pokemon/crystal/UNVERIFIED.md';       From = '^## This run'; To = '^## ' }
    @{ Path = 'adapters/emulator/pokemon/emerald/UNVERIFIED.md';       From = '^## This run'; To = '^## ' }
    @{ Path = 'adapters/pseudoregalia/UNVERIFIED.md';                  From = '^## This run'; To = '^## ' }
    @{ Path = 'adapters/tevi/UNVERIFIED.md';                           From = '^## This run'; To = '^## ' }
)
$oneLineBad = @()
$oneLineBullets = 0
foreach ($spec in $oneLine) {
    if (-not (Test-Path -LiteralPath $spec.Path)) { Report-Fail "$($spec.Path) listed for the one-line check does not exist"; continue }
    $lines = @(Get-Content -LiteralPath $spec.Path)
    $in = ($spec.From -eq '')
    $prevBullet = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if (-not $in) { if ($l -match $spec.From) { $in = $true }; continue }
        if ($spec.To -ne '' -and $l -match $spec.To) { break }
        if ($l -match '^- ') { $oneLineBullets++; $prevBullet = $true; continue }
        if ($prevBullet -and $l -match '^\s+\S' -and $l -notmatch '^\s+- ') {
            $oneLineBad += "$($spec.Path):$($i + 1)"
        }
        $prevBullet = $false
    }
}
if ($oneLineBullets -eq 0) {
    Report-Fail "the one-line check found no bullets in any listed block -- it would pass vacuously. Not a clean result."
} elseif ($oneLineBad.Count -gt 0) {
    Report-Fail "$($oneLineBad.Count) index/queue entries run past one line -- an entry says WHAT and WHERE, the detail lives at the link:"
    $oneLineBad | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "$oneLineBullets index/queue entries across $($oneLine.Count) block(s) are one line each"
}

# Refuses a root meshghost*.exe that is older than the newest non-test .go file.
Section "Root binaries vs Go source"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

$newestGo = Get-ChildItem -Recurse -Filter *.go |
    Where-Object {
        $_.FullName -notmatch '\\build\\_deps\\' -and
        $_.FullName -notmatch '\\RE-UE4SS\\' -and
        # autoplay/ is its own Go module, and none of these binaries contain it.
        $_.FullName -notmatch '\\autoplay\\' -and
        $_.Name -notlike '*_test.go'
    } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

foreach ($exe in @("meshghost.exe", "meshghost-relay.exe", "meshghost-fakeadapter.exe", "meshghost-netsim.exe")) {
    if (-not (Test-Path $exe)) {
        Report-Warn "$exe is not built yet -- build it before running any dev-scripts launcher"
        continue
    }
    $built = (Get-Item $exe).LastWriteTime
    if ($built -lt $newestGo.LastWriteTime) {
        Report-Fail "$exe is OLDER than $($newestGo.Name) -- rebuild with: go build -o $exe ./cmd/$([IO.Path]::GetFileNameWithoutExtension($exe))"
    } else {
        Report-Pass "$exe is newer than the newest .go file"
    }
}
}

# Refuses an armed probe script that walks reflection blindly, and any change in the disarmed-walk count.
Section "Probe scripts: blind reflection walks"

$blindWalkers = @('ForEachProperty', 'ForEachFunction', 'ForEachFunctionInChain', 'ForEachPropertyInChain')
$probeScripts = @(Get-ChildItem -Path 'adapters' -Recurse -Filter '*.lua' -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -like '*probe*' })
$ratchetDisarmedWalks = 23
$offenders = @()
$disarmed = @()
foreach ($script in $probeScripts) {
    # UE4SS loads a mod folder only when it holds enabled.txt, so a probe without one cannot reach a running game.
    $armed = Test-Path (Join-Path $script.Directory.Parent.FullName 'enabled.txt')
    foreach ($walker in $blindWalkers) {
        # Commented-out lines are how a withdrawn probe documents itself, so they are not counted as calls.
        $hits = @(Get-Content $script.FullName | Where-Object { $_ -match [regex]::Escape($walker) -and $_ -notmatch '^\s*--' })
        if ($hits.Count -gt 0) {
            $rel = $script.FullName -replace [regex]::Escape($PWD.Path + [IO.Path]::DirectorySeparatorChar), ''
            if ($armed) { $offenders += "$rel uses $walker" } else { $disarmed += "$rel uses $walker" }
        }
    }
}
if ($offenders.Count -gt 0) {
    Report-Fail ("ARMED probe script(s) walk reflection blindly -- this crashes a live game: " + ($offenders -join '; '))
} else {
    Report-Pass "no armed probe walks reflection blindly ($($probeScripts.Count) script(s) checked)"
}
if ($disarmed.Count -gt $ratchetDisarmedWalks) {
    Report-Fail ("disarmed blind reflection walks grew to $($disarmed.Count) (recorded $ratchetDisarmedWalks) -- a probe gained a ForEach* walk; cut it, and never arm it as is: " + ($disarmed -join '; '))
} elseif ($disarmed.Count -lt $ratchetDisarmedWalks) {
    Report-Fail "disarmed blind reflection walks dropped to $($disarmed.Count) (recorded $ratchetDisarmedWalks) -- a walk was cut; lower `$ratchetDisarmedWalks in this file so the floor holds"
} else {
    Report-Pass "$($disarmed.Count) disarmed probe script(s) still carry a blind reflection walk, at the recorded floor -- arming one is the FAIL above"
}

# Refuses a committed mod DLL or staged UE4SS runtime whose recorded hashes no longer match the tree.
Section "Committed mod DLLs vs their source"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

function Check-BuiltFrom($label, $builtFromPath, $sourceDir) {
    if (-not (Test-Path $builtFromPath)) { Report-Warn "$label -- no built-from.txt at $builtFromPath"; return }
    $stale = @()
    foreach ($line in Get-Content $builtFromPath) {
        if ($line -match '^\s*#' -or $line -notmatch '^(?<file>[^:]+):\s*(?<hash>[0-9a-fA-F]{64})\s*$') { continue }
        $file = $Matches['file']; $recorded = $Matches['hash'].ToLower()
        # CMakeLists.txt sits one directory above the sources, so it is checked separately below.
        if ($file -eq 'CMakeLists.txt') { continue }
        # A name with a slash is repo-relative: the build inputs outside the source folder (global.json and the like).
        $src = if ($file.Contains('/')) { $file } else { Join-Path $sourceDir $file }
        if (-not (Test-Path $src)) { $stale += "$file (recorded, but the file is gone)"; continue }
        $actual = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $recorded) { $stale += $file }
    }
    if ($stale.Count -gt 0) {
        Report-Fail "$label DLL is STALE -- these sources changed since it was built: $($stale -join ', ')"
    } else {
        Report-Pass "$label DLL matches every source hash it was built from"
    }
}

Check-BuiltFrom "TEVI" "packaging\release\games\tevi\built-from.txt" "adapters\tevi\MeshGhostTevi"
Check-BuiltFrom "Pseudoregalia" "packaging\release\games\pseudoregalia\MeshGhostPseudo-built-from.txt" "adapters\pseudoregalia\MeshGhostPseudo\Mod\src"

$ue4ssBuiltFrom = "packaging\release\games\pseudoregalia\ue4ss-runtime-built-from.txt"
$ue4ssBin = "packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64"
if (-not (Test-Path $ue4ssBuiltFrom)) {
    Report-Warn "UE4SS runtime -- no ue4ss-runtime-built-from.txt at $ue4ssBuiltFrom"
} else {
    $ue4ssText = Get-Content -Raw -LiteralPath $ue4ssBuiltFrom
    $ue4ssStale = @()
    foreach ($pair in @(@{ Name = 'UE4SS.dll'; Path = "$ue4ssBin\ue4ss\UE4SS.dll" },
                        @{ Name = 'dwmapi.dll'; Path = "$ue4ssBin\dwmapi.dll" })) {
        if (-not (Test-Path $pair.Path)) { $ue4ssStale += "$($pair.Name) (recorded, but not staged)"; continue }
        $actual = (Get-FileHash $pair.Path -Algorithm SHA256).Hash.ToLower()
        if ($ue4ssText -notmatch [regex]::Escape($actual)) { $ue4ssStale += $pair.Name }
    }
    # The submodule pin catches a bump without re-staging, which the DLLs' own hashes cannot see.
    $pinned = $null
    if ($ue4ssText -match 're-ue4ss-submodule-commit:\s*([0-9a-f]{40})') { $pinned = $Matches[1] }
    $submodule = (& git -C "adapters\pseudoregalia\MeshGhostPseudo\RE-UE4SS" rev-parse HEAD 2>$null)
    if (-not $pinned) {
        $ue4ssStale += "the file records no re-ue4ss-submodule-commit"
    } elseif ($submodule -and $submodule.Trim() -ne $pinned) {
        $ue4ssStale += "RE-UE4SS is at $($submodule.Trim().Substring(0,8)), staged from $($pinned.Substring(0,8))"
    }
    if ($ue4ssStale.Count -gt 0) {
        Report-Fail "the staged UE4SS runtime is STALE -- re-run dev-scripts\stage-ue4ss-runtime.bat: $($ue4ssStale -join ', ')"
    } else {
        Report-Pass "the staged UE4SS runtime matches its recorded hashes and the RE-UE4SS submodule pin"
    }
}

$cmake = "adapters\pseudoregalia\MeshGhostPseudo\Mod\CMakeLists.txt"
$pseudoBuiltFrom = "packaging\release\games\pseudoregalia\MeshGhostPseudo-built-from.txt"
if ((Test-Path $cmake) -and (Test-Path $pseudoBuiltFrom)) {
    $recorded = (Select-String -Path $pseudoBuiltFrom -Pattern '^CMakeLists\.txt:\s*([0-9a-fA-F]{64})').Matches.Groups[1].Value.ToLower()
    $actual = (Get-FileHash $cmake -Algorithm SHA256).Hash.ToLower()
    if ($recorded -and $actual -ne $recorded) {
        Report-Fail "Pseudoregalia CMakeLists.txt changed since the DLL was built"
    } elseif ($recorded) {
        Report-Pass "Pseudoregalia CMakeLists.txt matches its recorded hash"
    }
}
}

# Refuses a tracked text line shaped like reproduced decompiled source: a typed declaration or struct pointer.
Section "No reproduced expression ANYWHERE, not just documentation.md"

# False positives only (prose that happens to match), never a quote judged short enough.
$exprAllow = @{
    'adapters/emulator/pokemon/crystal/VERIFIED.md' = 1   # prose: "the player's struct for *placement*"
}
# Narrow on purpose: a bare -> is how this repo's prose writes an arrow.
$exprDecl = '\b(?:EWRAM_DATA|COMMON_DATA|IWRAM_DATA|static\s+)?\b(?:u8|u16|u32|s8|s16|s32|bool8)\s+[A-Za-z_]\w*\s*(?:\[[^\]]*\])?\s*='
$exprPtr  = '\bstruct\s+\w+\s*\*\s*\w'
# Filtered in PowerShell, not by a git glob: the MSYS2 git on PATH expands *.md to the root files first.
$exprFiles = @(& git ls-files | Where-Object { $_ -match '\.(md|lua|go|ps1|bat|txt)$' })
$exprHits = @()
foreach ($f in $exprFiles) {
    if (-not (Test-Path $f)) { continue }
    $norm = ($f -replace '\\', '/')
    # Both skipped: one names the patterns, the other plants them.
    if ($norm -eq 'dev-scripts/preflight.ps1' -or $norm -eq 'dev-scripts/negative-test-preflight.ps1') { continue }
    $n = @(Select-String -Path $f -Pattern $exprDecl, $exprPtr -AllMatches).Count
    $allowed = if ($exprAllow.ContainsKey($norm)) { $exprAllow[$norm] } else { 0 }
    if ($n -gt $allowed) { $exprHits += "${norm}: $n line(s), $allowed accepted as prose" }
}
if ($exprFiles.Count -eq 0) {
    Report-Fail "no tracked text files found -- this check would pass vacuously"
} elseif ($exprHits.Count -gt 0) {
    Report-Fail ("source-shaped line(s) in tracked text -- a fact may be RECORDED with a citation, " +
        "expression may never be reproduced (CLAUDE.md, agent_docs/licensing.md). Reword it as what " +
        "the code DOES, or add the file to this section's `$exprAllow if the match is prose: " +
        ($exprHits -join "; "))
} else {
    Report-Pass "no reproduced C declaration in $($exprFiles.Count) tracked text file(s)"
}

# Refuses a fenced C block in tracked markdown: the repo writes no C, so such a fence can only be quoted source.
Section "No fenced C block in tracked markdown"

$cFenceHits = @()
foreach ($f in $trackedMd) {
    if (-not (Test-Path $f)) { continue }
    $n = @(Select-String -LiteralPath $f -Pattern '^```c\s*$').Count
    if ($n -gt 0) { $cFenceHits += "$($f -replace '\\', '/'): $n" }
}
if ($cFenceHits.Count -gt 0) {
    Report-Fail ("fenced C block(s) in tracked markdown -- quoted source never enters the repo (CLAUDE.md, " +
        "agent_docs/licensing.md); describe what the routine DOES, or move it to MEASURED.md's Not measured yet as a question: " +
        ($cFenceHits -join "; "))
} else {
    Report-Pass "no fenced C block in $($trackedMd.Count) tracked markdown file(s)"
}

# Refuses a count of decompilation file citations in adapter Lua that moved off its recorded floor.
Section "Decompilation citations in adapter Lua: a ratchet"

$luaCiteC = '\b(src|include|data|constants)/[A-Za-z0-9_/]+\.(c|h|inc)\b|\.(c|h):[0-9]'
$luaCiteAsm = '\b(engine|home|data|constants|ram|gfx|maps)/[A-Za-z0-9_/]+\.(asm|inc)\b|\.asm:[0-9]'
$luaCiteRatchet = @(
    @{ path = 'adapters/emulator/pokemon/emerald/meshghost_emerald.lua'; pattern = $luaCiteC;   floor = 0 },
    @{ path = 'adapters/emulator/pokemon/crystal/meshghost_crystal.lua'; pattern = $luaCiteAsm; floor = 0 },
    @{ path = 'adapters/emulator/pokemon/emerald/probes';                pattern = $luaCiteC;   floor = 0 },
    @{ path = 'adapters/emulator/pokemon/crystal/probes';                pattern = $luaCiteAsm; floor = 3 }
)
$luaCiteProblems = @()
foreach ($r in $luaCiteRatchet) {
    $files = if (Test-Path $r.path -PathType Container) {
        @(Get-ChildItem (Join-Path $r.path '*.lua') | ForEach-Object { $_.FullName })
    } else { @($r.path) }
    $n = 0
    foreach ($f in $files) {
        if (Test-Path $f) { $n += @(Select-String -LiteralPath $f -Pattern $r.pattern).Count }
    }
    if ($n -gt $r.floor) { $luaCiteProblems += "$($r.path): $n citation line(s), recorded $($r.floor) (grew)" }
    elseif ($n -lt $r.floor) { $luaCiteProblems += "$($r.path): $n, recorded $($r.floor) (shrank -- lower the floor in this file)" }
}
if ($luaCiteProblems.Count -gt 0) {
    Report-Fail ("decompilation citations in adapter Lua moved off their recorded floor -- a new one is a " +
        "borrowed claim: measure it, or write it as the source's reading and move the question to " +
        "MEASURED.md's Not measured yet (CLAUDE.md, agent_docs/licensing.md): " + ($luaCiteProblems -join "; "))
} else {
    Report-Pass "decompilation citations in adapter Lua at their recorded floors (4 ratchets)"
}

# Refuses the retired [from the decomp] label, or source-file citations in an adapter's documentation file, off their recorded floors.
Section "Measured or observed only: no NEW source-derived claims (ratchet)"

$ratchetDecompLabel = 0
$ratchetDecompCites = @{
    'adapters/emulator/pokemon/crystal/documentation.md' = 0
    'adapters/emulator/pokemon/emerald/documentation.md' = 0
}
$labelHits = 0
foreach ($f in @(& git ls-files | Where-Object { $_ -match '\.(md|lua|go|cs|cpp|h)$' })) {
    if (-not (Test-Path $f)) { continue }
    # The lookbehind skips a backticked mention: the rule naming the label is not a use of it.
    $labelHits += @(Select-String -LiteralPath $f -Pattern '(?<!`)\[from the decomp' -AllMatches | ForEach-Object { $_.Matches }).Count
}
if ($labelHits -gt $ratchetDecompLabel) {
    Report-Fail "the retired [from the decomp] label is used $labelHits time(s), recorded $ratchetDecompLabel -- a new source-derived claim: measure it and label it [measured <date>, <instrument>], or move it to that adapter's MEASURED.md, Not measured yet, as a question (CLAUDE.md, agent_docs/licensing.md)"
} elseif ($labelHits -lt $ratchetDecompLabel) {
    Report-Fail "the retired [from the decomp] label dropped to $labelHits (recorded $ratchetDecompLabel) -- the audit is working; lower `$ratchetDecompLabel in this file so the floor holds"
} else {
    Report-Pass "retired [from the decomp] label: $labelHits use(s), at the recorded floor"
}
$citePattern = '\b(engine|home|src|data|constants|ram|gfx|maps|include)/[A-Za-z0-9_/]+\.(asm|c|h|inc|pal)\b'
$citeProblems = @()
foreach ($f in @($trackedMd | Where-Object { $_ -like 'adapters/*documentation.md' })) {
    if (-not (Test-Path $f)) { continue }
    $norm = ($f -replace '\\', '/')
    $n = @(Select-String -LiteralPath $f -Pattern $citePattern).Count
    $allowed = if ($ratchetDecompCites.ContainsKey($norm)) { $ratchetDecompCites[$norm] } else { 0 }
    if ($n -gt $allowed) { $citeProblems += "${norm}: $n line(s) citing source files, recorded $allowed (grew)" }
    elseif ($n -lt $allowed) { $citeProblems += "${norm}: $n line(s), recorded $allowed (shrank -- lower the recorded number)" }
}
if ($citeProblems.Count -gt 0) {
    Report-Fail ("source-file citations in documentation.md moved off their recorded floor: " + ($citeProblems -join "; "))
} else {
    Report-Pass "source-file citations in documentation.md at their recorded floor (the audit lowers them)"
}

# Warns on a fenced block in an adapter's documentation file beyond the count accepted as our own probe output.
Section "No reproduced expression in documentation.md"

$fenceAllow = @{
    'adapters/emulator/pokemon/emerald/documentation.md' = 1   # probe output we produced (the surf-jump trace)
}
$docFiles = @(& git ls-files '*documentation.md')
$fenced = @()
$staleAllow = @()
foreach ($f in $docFiles) {
    if (-not (Test-Path $f)) { continue }
    $blocks = [int](@(Select-String -Path $f -Pattern '^```' -AllMatches).Count / 2)
    $norm = ($f -replace '\\', '/')
    $allowed = if ($fenceAllow.ContainsKey($norm)) { $fenceAllow[$norm] } else { 0 }
    if ($blocks -gt $allowed) { $fenced += "$norm ($blocks block(s), $allowed accepted)" }
    elseif ($blocks -lt $allowed) { $staleAllow += "$norm ($blocks block(s), $allowed accepted)" }
}
if ($docFiles.Count -eq 0) {
    Report-Fail "no documentation.md found -- this check would pass vacuously"
} elseif ($fenced.Count -gt 0) {
    Report-Warn ("NEW fenced block(s) in documentation.md -- confirm each is OUR measurement, " +
        "not reproduced expression, then record it in this section's `$fenceAllow: " + ($fenced -join ", "))
} else {
    Report-Pass "no fenced block in any adapter's documentation.md beyond the $(($fenceAllow.Values | Measure-Object -Sum).Sum) recorded as our own measurements ($($docFiles.Count) checked)"
}
if ($staleAllow.Count -gt 0) {
    Report-Warn ("`$fenceAllow accepts more blocks than exist -- lower it so a new one is still caught: " + ($staleAllow -join ", "))
}

# Refuses a tracked text file holding a control byte other than tab, newline or carriage return.
Section "Stray control bytes from a mangled escape"

$ctrlExt = @('*.md', '*.txt', '*.go', '*.lua', '*.ps1', '*.bat', '*.py', '*.yml', '*.yaml', '*.json', '*.cs', '*.cpp', '*.hpp', '*.sh')
$ctrlFiles = @(& git ls-files -- $ctrlExt)
$ctrlHits = @()
foreach ($f in $ctrlFiles) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($f)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -lt 0x20 -and $b -ne 0x09 -and $b -ne 0x0A -and $b -ne 0x0D) {
            $line = 1
            for ($j = 0; $j -lt $i; $j++) { if ($bytes[$j] -eq 0x0A) { $line++ } }
            $ctrlHits += ("{0}:{1} (byte 0x{2:X2})" -f $f, $line, $b)
            break
        }
    }
}
if ($ctrlFiles.Count -eq 0) {
    Report-Fail "no text files found -- the control-byte check would pass vacuously"
} elseif ($ctrlHits.Count -gt 0) {
    Report-Fail "$($ctrlHits.Count) file(s) hold a stray control byte -- almost always a backslash escape eaten by a scripted edit; check the PATH or string on that line:"
    $ctrlHits | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no stray control bytes in $($ctrlFiles.Count) tracked text file(s)"
}

# Refuses a tracked .lua file that does not compile under luac -p.
Section "Lua parses"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

# Absolute path on purpose: lua is not on PATH, and a bare name can resolve to the wrong install.
$luac = "C:/msys64/mingw64/bin/luac.exe"
if (-not (Test-Path $luac)) {
    Report-Warn "luac not found at $luac -- skipping the Lua parse check (see environment.md)"
} else {
    $luaFiles = @(& git ls-files '*.lua')
    $broken = @()
    foreach ($f in $luaFiles) {
        $out = & $luac -p $f 2>&1
        if ($LASTEXITCODE -ne 0) { $broken += "$f -- $out" }
    }
    if ($broken.Count -gt 0) {
        foreach ($b in $broken) { Report-Fail "does not parse: $b" }
    } else {
        Report-Pass "all $($luaFiles.Count) tracked .lua files parse under Lua 5.4"
    }
}
}

# Refuses a Lua file that reaches a name through _ENV while also declaring it local: a use above its local.
Section "Lua globals resolve"
if ($TreeOnly) { Report-Skip "needs luac, a working copy" } else {

if (-not (Test-Path $luac)) {
    Report-Warn "luac not found at $luac -- skipping the Lua globals check"
} else {
    $luaFiles = @(& git ls-files '*.lua')
    $shadowed = @()
    foreach ($f in $luaFiles) {
        $listing = & $luac -l -l -p $f 2>$null
        if ($LASTEXITCODE -ne 0) { continue }   # "Lua parses" already reports this file
        # Case-sensitive sets on purpose: Lua names are, and PowerShell's @{} keys and -match are not.
        $locals = New-Object 'System.Collections.Generic.HashSet[string]'
        $env = New-Object 'System.Collections.Generic.HashSet[string]'
        $inLocals = $false
        foreach ($line in $listing) {
            if ($line -match '^locals \(') { $inLocals = $true; continue }
            if ($line -match '^(upvalues|constants) \(|^(main|function) <') { $inLocals = $false }
            if ($inLocals -and $line -match '^\s*\d+\s+([A-Za-z_][A-Za-z0-9_]*)\s') { [void]$locals.Add($Matches[1]) }
            if ($line -match '\t(GETTABUP|SETTABUP)\s.*_ENV "([A-Za-z_][A-Za-z0-9_]*)"') { [void]$env.Add($Matches[2]) }
        }
        $both = @($env | Where-Object { $locals.Contains($_) } | Sort-Object)
        if ($both.Count -gt 0) { $shadowed += "$f -- $($both -join ', ')" }
    }
    if ($luaFiles.Count -eq 0) {
        Report-Fail "no tracked .lua files found -- the globals check would pass vacuously"
    } elseif ($shadowed.Count -gt 0) {
        Report-Fail "$($shadowed.Count) Lua file(s) reach a name as a GLOBAL that is also declared local -- a use above its local, or a bare assignment (agent_docs/checklists/before-touching-lua.md):"
        $shadowed | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "no tracked .lua file reaches a declared local through _ENV ($($luaFiles.Count) files)"
    }
}
}

# Refuses a SCRIPT_DIR concatenation in Crystal whose literal does not open with a path separator.
Section "SCRIPT_DIR concatenations carry a separator (Crystal)"

$crystal = 'adapters/emulator/pokemon/crystal/meshghost_crystal.lua'
if (-not (Test-Path $crystal)) {
    Report-Fail "$crystal is missing -- the separator check would pass vacuously"
} else {
    $lines = @(Get-Content -LiteralPath $crystal)
    $bad = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*--') { continue }
        foreach ($m in [regex]::Matches($l, 'SCRIPT_DIR\s*\.\.\s*"([^"]*)"')) {
            if ($m.Groups[1].Value -notmatch '^[/\\]') {
                $bad += "$crystal`:$($i + 1)  SCRIPT_DIR .. `"$($m.Groups[1].Value)`""
            }
        }
    }
    if ($bad.Count -gt 0) {
        Report-Fail "$($bad.Count) SCRIPT_DIR concatenation(s) in Crystal do not start with a separator -- this file's SCRIPT_DIR has no trailing one, so these build a path that never opens:"
        $bad | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every SCRIPT_DIR concatenation in Crystal opens with a separator"
    }
}

# Refuses a raw GetValuePtrByPropertyNameInChain<bool> read in Pseudoregalia that lacks a bitfield-safe: note.
Section "Reflected bools use the property mask (Pseudoregalia)"

$boolFiles = @(& git ls-files -- 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*.cpp' 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*.hpp')
$rawBool = @()
foreach ($f in $boolFiles) {
    $lines = @(Get-Content -LiteralPath $f)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -notmatch 'GetValuePtrByPropertyNameInChain<bool>') { continue }
        if ($l -match '^\s*//') { continue }
        if ($l -match 'bitfield-safe:') { continue }
        $rawBool += "$f`:$($i + 1)"
    }
}
if ($boolFiles.Count -eq 0) {
    Report-Fail "no Pseudoregalia Mod/src files found -- the reflected-bool check would pass vacuously"
} elseif ($rawBool.Count -gt 0) {
    Report-Fail "$($rawBool.Count) raw <bool> reflection read(s) -- a reflected bool is a bitfield, read it through FBoolProperty::GetPropertyValueInContainer or say why not (bitfield-safe:):"
    $rawBool | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no raw GetValuePtrByPropertyNameInChain<bool> read in $($boolFiles.Count) Pseudoregalia source file(s)"
}

# Refuses a bare time.* call in core that neither goes through c.clk() nor carries a wall-clock: note.
Section "The core's clock is injectable, and stays that way"

$clockPattern = 'time\.(Now|Since|Sleep|After|NewTicker|NewTimer|Tick)\('
# Tests are excluded before the vacuity guard, so an over-eager filter still fails on an empty set.
$clockFiles = @(& git ls-files -- 'core/*.go' | Where-Object { $_ -notlike '*_test.go' -and $_ -ne 'core/clock.go' })
$clockBare = @()
foreach ($f in $clockFiles) {
    $lines = @(Get-Content -LiteralPath $f)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -notmatch $clockPattern) { continue }
        if ($l -match '^\s*//') { continue }
        if ($l -match 'wall-clock:') { continue }
        $clockBare += "$f`:$($i + 1)"
    }
}
if ($clockFiles.Count -eq 0) {
    Report-Fail "no core/*.go files found -- the clock check would pass vacuously"
} elseif ($clockBare.Count -gt 0) {
    Report-Fail "$($clockBare.Count) bare time.* call(s) in core -- route it through c.clk() (core/clock.go) or mark the line `wall-clock:` with the reason:"
    $clockBare | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every time.* in $($clockFiles.Count) core file(s) is either injectable or marked wall-clock:"
}

# Refuses a dev-scripts line that invokes cmd, cmake, lua or luac by bare name instead of a resolved path.
Section "No bare interpreter on PATH in dev-scripts"

$scriptFiles = @(& git ls-files -- 'dev-scripts/*.ps1' 'dev-scripts/*.bat')
$bareCalls = @()
foreach ($f in $scriptFiles) {
    $lines = @(Get-Content -LiteralPath $f)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*(#|::|rem\s|echo\s)' ) { continue }
        if ($l -match '(^|[&|;(]\s*|\bcall\s+)(cmd|cmake|lua|luac)(\.exe)?(\s|$)') {
            $bareCalls += "$f`:$($i + 1): $($l.Trim())"
        }
    }
}
if ($scriptFiles.Count -eq 0) {
    Report-Fail "no dev-scripts .ps1/.bat found -- the bare-interpreter check would pass vacuously"
} elseif ($bareCalls.Count -gt 0) {
    Report-Fail "$($bareCalls.Count) bare interpreter invocation(s) in dev-scripts -- use `$env:ComSpec or an absolute path (CLAUDE.md, the PATH rule):"
    $bareCalls | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no bare cmd/cmake/lua/luac invocation across $($scriptFiles.Count) dev-scripts"
}

# Refuses CRLF in an LF-pinned adapter source, which the release gate would hash as a stale DLL.
Section "LF-pinned sources"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

$pinned = @(& git ls-files 'adapters/tevi/MeshGhostTevi/*.cs' 'adapters/tevi/MeshGhostTevi/*.csproj' `
    'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*.cpp' 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*.hpp' `
    'adapters/pseudoregalia/MeshGhostPseudo/Mod/CMakeLists.txt')
$crlf = @()
foreach ($f in $pinned) {
    if (-not (Test-Path $f)) { continue }
    $bytes = [IO.File]::ReadAllBytes($f)
    for ($i = 1; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A -and $bytes[$i - 1] -eq 0x0D) { $crlf += $f; break }
    }
}
if ($crlf.Count -gt 0) {
    Report-Fail "CRLF in LF-pinned source: $($crlf -join ', ')  -- fix with: perl -pi -e 's/\r\n/\n/g' <file>, THEN rebuild"
} else {
    Report-Pass "every LF-pinned adapter source is still LF"
}
}

# Refuses a tracked .bat that is not pinned eol=crlf, or one checked out LF in this working copy.
Section "CRLF-pinned batch files"
$batFiles = @(& git ls-files '*.bat')
if ($batFiles.Count -lt 5) {
    Report-Fail "expected to find tracked .bat files and found $($batFiles.Count) -- this check did not run, so it is NOT a clean result"
} else {
    # The attribute, not only the bytes: it decides what every clone checks out, whatever this machine holds.
    $unpinned = @()
    foreach ($f in $batFiles) {
        $attr = (& git check-attr eol -- $f) -replace '^.*: eol: ', ''
        if ($attr -ne 'crlf') { $unpinned += "$f (eol: $attr)" }
    }
    if ($unpinned.Count -gt 0) {
        Report-Fail "$($unpinned.Count) tracked .bat file(s) are not pinned eol=crlf -- add them to .gitattributes, or a clone that does not convert gets LF and cmd.exe mis-parses their labels:"
        $unpinned | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "all $($batFiles.Count) tracked .bat file(s) are pinned eol=crlf"
    }

    if ($TreeOnly) {
        Report-Skip "the on-disk byte check needs a working copy, not just the tree"
    } else {
        $lfOnDisk = @()
        foreach ($f in $batFiles) {
            if (-not (Test-Path $f)) { continue }
            $bytes = [IO.File]::ReadAllBytes($f)
            $sawCRLF = $false
            for ($i = 1; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -eq 0x0A -and $bytes[$i - 1] -eq 0x0D) { $sawCRLF = $true; break }
            }
            if (-not $sawCRLF -and $bytes.Length -gt 0) { $lfOnDisk += $f }
        }
        if ($lfOnDisk.Count -gt 0) {
            Report-Fail "$($lfOnDisk.Count) .bat file(s) are LF in this working copy despite the pin -- refresh them with: git rm --cached -r . ; git reset --hard  (or delete the file and git checkout -- <file>):"
            $lfOnDisk | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
        } else {
            Report-Pass "every .bat in this working copy is CRLF on disk"
        }
    }
}

# Refuses a mod DLL deployed into a live game install that differs from the staged build.
Section "Deployed copies in the live game installs"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

function Check-Deployed($label, $stagedPath, $envName) {
    $deployed = [Environment]::GetEnvironmentVariable($envName)
    if (-not $deployed) { Report-Warn "$label -- set $envName to also check the deployed copy"; return }
    if (-not (Test-Path $deployed)) { Report-Fail "$label -- $envName points at a file that does not exist: $deployed"; return }
    if (-not (Test-Path $stagedPath)) { Report-Fail "$label -- nothing staged at $stagedPath"; return }
    $a = (Get-FileHash $stagedPath -Algorithm SHA256).Hash
    $b = (Get-FileHash $deployed -Algorithm SHA256).Hash
    if ($a -ne $b) {
        Report-Fail "$label deployed copy DIFFERS from the freshly built one -- the game would run stale code. Copy it out again."
    } else {
        Report-Pass "$label deployed copy matches the built one"
    }
}

Check-Deployed "TEVI" "packaging\release\games\tevi\MeshGhost\MeshGhostTevi.dll" "MESHGHOST_TEVI_DLL"
Check-Deployed "TEVI (alt install)" "packaging\release\games\tevi\MeshGhost\MeshGhostTevi.dll" "MESHGHOST_TEVI_DLL_ALT"
Check-Deployed "Pseudoregalia" "packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\dlls\main.dll" "MESHGHOST_PSEUDO_DLL"
}

# Refuses a relative markdown link that does not resolve, climbs out of the repo, or names a missing heading.
Section "Markdown link integrity"

$rootFull = (Resolve-Path -LiteralPath $root).Path
$slugCache = @{}
function Get-HeadingSlugs($mdPath) {
    if ($slugCache.ContainsKey($mdPath)) { return $slugCache[$mdPath] }
    $body = (Get-Content -Raw -Encoding UTF8 -LiteralPath $mdPath) -replace '(?s)```.*?```', ''
    $seen = @{}
    foreach ($h in [regex]::Matches($body, '(?m)^#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$')) {
        $t = $h.Groups[1].Value
        $t = $t -replace '`', ''
        $t = [regex]::Replace($t, '\[([^\]]*)\]\([^)]*\)', '$1')
        $t = $t -replace '\*\*|__|\*', ''
        $slug = $t.Trim().ToLowerInvariant()
        $slug = [regex]::Replace($slug, '[^\w\- ]', '')
        $slug = $slug -replace ' ', '-'
        if ($seen.ContainsKey($slug)) {
            $n = $seen[$slug]; $seen[$slug] = $n + 1
            $seen["$slug-$n"] = 1
        } else {
            $seen[$slug] = 1
        }
    }
    $slugCache[$mdPath] = $seen
    return $seen
}
$badLinks = @()
$escapedLinks = @()
$badAnchors = @()
$linkCount = 0
foreach ($md in $trackedMd) {
    $dir = Split-Path -Parent $md
    if (-not $dir) { $dir = "." }
    $body = (Get-Content -Raw -Encoding UTF8 -LiteralPath $md) -replace '(?s)```.*?```', ''
    foreach ($m in [regex]::Matches($body, '(?<!\!)\]\(([^)#\s]*)(#[^)\s]*)?\)')) {
        $target = $m.Groups[1].Value
        $anchor = $m.Groups[2].Value
        if (-not $target -and -not $anchor) { continue }
        if ($target -match '^[a-z]+:' -or $target.StartsWith('<')) { continue }
        $targetPath = if ($target) { Join-Path $dir ([uri]::UnescapeDataString($target)) } else { $md }
        if ($target) {
            $linkCount++
            $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull $targetPath))
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $escapedLinks += "$md -> $target"
                continue
            }
            if (-not (Test-Path -LiteralPath $targetPath)) { $badLinks += "$md -> $target"; continue }
        }
        if ($anchor -and $targetPath -like '*.md') {
            $a = [uri]::UnescapeDataString($anchor.Substring(1)).ToLowerInvariant()
            if ($a -match '^l\d+(-l\d+)?$') { continue }
            $slugs = Get-HeadingSlugs $targetPath
            if (-not $slugs.ContainsKey($a)) { $badAnchors += "$md -> $target#$a" }
        }
    }
}
if ($linkCount -lt 400) {
    Report-Fail "only $linkCount relative link(s) seen across $($trackedMd.Count) files -- the scan is broken, so a clean result here means nothing"
}
if ($badLinks.Count -gt 0) {
    Report-Fail "$($badLinks.Count) broken relative markdown link(s):"
    $badLinks | Sort-Object -Unique | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every relative markdown link resolves ($linkCount checked)"
}
if ($escapedLinks.Count -gt 0) {
    Report-Fail "$($escapedLinks.Count) markdown link(s) climb out of the repo -- GitHub resolves these against /blob/<branch>/, so the right number of ../ depends on the file's depth and a copied link breaks silently. Link the GitHub page absolutely:"
    $escapedLinks | Sort-Object -Unique | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no markdown link climbs out of the repo (a GitHub page is linked absolutely)"
}
if ($badAnchors.Count -gt 0) {
    Report-Fail "$($badAnchors.Count) markdown anchor(s) name a heading the target does not have:"
    $badAnchors | Sort-Object -Unique | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every markdown #anchor names a heading in its target"
}

$ghMd = @(& git ls-files -- '.github/*.md' '.github/**/*.md' | Sort-Object -Unique)
$ghRel = @()
foreach ($g in $ghMd) {
    if (-not (Test-Path -LiteralPath $g)) { continue }
    $ghBody = (Get-Content -Raw -Encoding UTF8 -LiteralPath $g) -replace '(?s)```.*?```', ''
    foreach ($m in [regex]::Matches($ghBody, '(?<!\!)\]\(([^)\s]+)\)')) {
        $target = $m.Groups[1].Value
        # An in-page #anchor is the one relative form these surfaces do resolve.
        if ($target -match '^[a-z]+:' -or $target.StartsWith('#')) { continue }
        $ghRel += "${g}: $target"
    }
}
if ($ghMd.Count -eq 0) {
    Report-Fail "no tracked .md under .github/ -- this check would pass vacuously"
} elseif ($ghRel.Count -gt 0) {
    Report-Fail "$($ghRel.Count) relative link(s) in .github/ markdown; GitHub's own surfaces for these files drop the branch segment and 404 -- use https://github.com/<owner>/<repo>/blob/master/<path>:"
    $ghRel | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every link in $($ghMd.Count) .github/ markdown file(s) is absolute (those surfaces drop the branch from relative ones)"
}

# Refuses a registered multiply-stated rule restated without a nearby link to its home file.
Section "Canonical source for multiply-stated rules"

$canon = @(
    @{ Name = "a flag flip is not a revert"
       Pattern = 'flag flip is not a revert'
       Home = 'agent_docs/pitfalls/method.md'
       LinkTo = 'pitfalls' }   # matches both the pitfalls index and its record, each one hop from the home
    @{ Name = "the eight after-the-fact bandage tells"
       Pattern = 'tells that only show up later'
       Home = 'adapters/_template/BANDAGES.md'
       LinkTo = '_template/BANDAGES.md' }
    @{ Name = "the 2026-08-17 module move disclaimer"
       Pattern = 'predate the 2026-08-17 module move'
       Home = 'agent_docs/README.md'
       HomePattern = 'internal/protocol\|transport'
       LinkTo = 'README.md' }
    @{ Name = "status.md's two-lines-per-item rule"
       Pattern = 'two lines per item'
       Home = 'agent_docs/claude-md-cap.md'
       LinkTo = 'claude-md-cap.md' }
    @{ Name = "the UNVERIFIED READY/OPEN/DONE state rule"
       Pattern = 'READY\*\* \(built'
       Home = 'adapters/_template/UNVERIFIED.md'
       HomePattern = 'carries a state'
       LinkTo = '_template/UNVERIFIED.md' }
    @{ Name = "the build story is one step per CAPABILITY"
       Pattern = 'step per capability'
       Home = 'CLAUDE.md'
       LinkTo = 'CLAUDE.md' }
    @{ Name = "the phase file is the complete running log"
       Pattern = 'append.{0,40}(active|its) phase file'
       Home = 'agent_docs/phases/README.md'
       HomePattern = 'running log'
       LinkTo = 'phases/README.md' }
)
foreach ($rule in $canon) {
    $homePat = if ($rule.HomePattern) { $rule.HomePattern } else { $rule.Pattern }
    $homeText = if (Test-Path $rule.Home) { Get-Content -Raw -Encoding UTF8 -LiteralPath $rule.Home } else { "" }
    if ($homeText -notmatch $homePat) {
        Report-Fail "'$($rule.Name)' is registered as living in $($rule.Home), but that file does not state it"
        continue
    }
    # The pointer must sit within four lines of the statement: a whole-file match is vouched for by any link.
    $strays = @()
    foreach ($md in $trackedMd) {
        if ($md -eq $rule.Home) { continue }
        if ($md -eq 'agent_docs/doc-history.md') { continue }  # the restructuring record quotes these rules
        $lines = @(Get-Content -LiteralPath $md)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch $rule.Pattern) { continue }
            $lo = [math]::Max(0, $i - 4)
            $hi = [math]::Min($lines.Count - 1, $i + 4)
            $near = ($lines[$lo..$hi] -join "`n")
            if ($near -notmatch [regex]::Escape($rule.LinkTo)) { $strays += "${md}:$($i + 1)" }
        }
    }
    if ($strays.Count -gt 0) {
        Report-Fail "'$($rule.Name)' is restated without linking to $($rule.Home):"
        $strays | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "'$($rule.Name)' -- every copy links to $($rule.Home)"
    }
}

# Warns, never fails, when a _template file was last committed over a day before an adapter's counterpart.
Section "_template back-port freshness"

# Commit dates, not mtimes: an mtime is only when the file was checked out.
function Git-LastCommit($path) {
    if (-not (Test-Path $path)) { return $null }
    $ts = & git log -1 --format=%ct -- $path
    if ($ts) { return [int]$ts } else { return $null }
}
$adapters = @(
    "adapters/emulator/pokemon/crystal", "adapters/emulator/pokemon/emerald",
    "adapters/pseudoregalia", "adapters/tevi"
)
$lagging = @()
foreach ($name in @("README.md", "FLAGS.md", "BANDAGES.md", "documentation.md", "SYNCED.md")) {
    $tplTime = Git-LastCommit "adapters/_template/$name"
    if (-not $tplTime) { continue }
    foreach ($a in $adapters) {
        $aTime = Git-LastCommit "$a/$name"
        # One day of slack: a sub-day gap is almost always this session's own back-port commits.
        if ($aTime -and ($aTime - $tplTime) -gt 86400) {
            $days = [math]::Round(($aTime - $tplTime) / 86400.0, 1)
            $lagging += "_template/$name is $days day(s) behind $a/$name"
        }
    }
}
if ($lagging.Count -gt 0) {
    Report-Warn "$($lagging.Count) template file(s) last changed before an adapter's counterpart -- check nothing needs back-porting:"
    $lagging | Sort-Object -Unique | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "_template is no older than any shipped adapter's counterpart"
}

# Refuses a pitfalls heading missing from the index, an index line with no outcome tag, or a missing checklist.
Section "pitfalls index coverage"

$pitIndex = "agent_docs/pitfalls/INDEX.md"
$pitBodies = @(Get-ChildItem -LiteralPath "agent_docs/pitfalls" -Filter '*.md' | Where-Object { $_.Name -ne 'INDEX.md' } | Sort-Object Name)
if (-not (Test-Path -LiteralPath $pitIndex)) {
    Report-Fail "$pitIndex is missing -- every pitfalls heading is supposed to be listed there with its outcome"
} elseif ($pitBodies.Count -eq 0) {
    Report-Fail "agent_docs/pitfalls/ holds no body files -- the entries are supposed to live there"
} else {
    $pitLines = @(Get-Content -LiteralPath $pitIndex)
    $indexed = @{}
    $untagged = @()
    $badPage = @()
    for ($i = 0; $i -lt $pitLines.Count; $i++) {
        $l = $pitLines[$i]
        if ($l -notmatch '^- (.+)$') { continue }
        $entry = $Matches[1].Trim()
        if ($entry -match '^(.*\S)\s+\[(CHECK: [^\]]+|RULE: [^\]]+|RECORD)\]$') {
            $title = $Matches[1].Trim()
            $tag = $Matches[2]
            if ($title -match '^\[([^\]]+)\]\(') { $title = $Matches[1].Trim() }
            $indexed[$title] = $true
            if ($tag -match '^RULE: checklists/([A-Za-z0-9._-]+\.md)$' -and -not (Test-Path -LiteralPath "agent_docs/checklists/$($Matches[1])")) {
                $badPage += "$($i + 1): $tag"
            }
        } else {
            $untagged += "$($i + 1): $entry"
            if ($entry -match '^\[([^\]]+)\]\(') { $entry = $Matches[1].Trim() }
            $indexed[$entry] = $true
        }
    }
    $missing = @()
    foreach ($b in $pitBodies) {
        $lines = @(Get-Content -LiteralPath $b.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            # Entry level only: a '### ' belongs to its '## ' entry; the few '### ' entries were indexed by hand.
            if ($l -notmatch '^## ') { continue }
            $title = ($l -replace '^## ', '').Trim()
            if (-not $indexed.ContainsKey($title)) { $missing += "$($b.Name):$($i+1): $title" }
        }
    }
    if ($indexed.Count -lt 100) {
        Report-Fail "$pitIndex lists only $($indexed.Count) entr(ies) -- the index is broken, so coverage would pass vacuously"
    }
    if ($missing.Count -gt 0) {
        Report-Fail "$($missing.Count) pitfalls heading(s) missing from $pitIndex -- add one tagged line each:"
        $missing | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    }
    if ($untagged.Count -gt 0) {
        Report-Fail "$($untagged.Count) index line(s) carry no outcome -- end each with [CHECK: ...], [RULE: <file>] or [RECORD] (agent_docs/pitfalls.md):"
        $untagged | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    }
    if ($badPage.Count -gt 0) {
        Report-Fail "$($badPage.Count) index line(s) name a checklist page that does not exist:"
        $badPage | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    }
    if ($missing.Count -eq 0 -and $untagged.Count -eq 0 -and $badPage.Count -eq 0 -and $indexed.Count -ge 100) {
        Report-Pass "every pitfalls heading across $($pitBodies.Count) body file(s) is indexed with an outcome ($($indexed.Count) lines)"
    }
}

# Refuses a VERIFIED or MEASURED entry that is missing from its own file's index.
Section "VERIFIED index coverage"

# -like ignores case, so '*VERIFIED.md' also matches the UNVERIFIED queues, which drain and need no index.
$verifiedFiles = @(& git ls-files | Where-Object {
    ($_ -like '*VERIFIED.md' -or $_ -eq 'agent_docs/verified.md') -and $_ -notlike '*UNVERIFIED.md'
})
$structural = @('Confirmed facts', 'Entry format', 'Split per game — 2026-08-25')
if ($verifiedFiles.Count -eq 0) {
    Report-Fail "no VERIFIED.md files found -- this check would pass vacuously, which is not a clean result"
} else {
    $vMissing = @()
    $vIndexed = 0
    $vChecked = 0
    foreach ($vf in $verifiedFiles) {
        if ($vf -like 'adapters/_template/*') { continue }   # the template has no entries yet
        $lines = @(Get-Content -LiteralPath $vf)
        $idxAt = ($lines | Select-String -Pattern '^## Index — every entry in this file$' | Select-Object -First 1).LineNumber
        if (-not $idxAt) {
            Report-Fail "$vf has no index section -- an append-only record needs one, it only grows"
            continue
        }
        $indexed = @{}
        for ($i = $idxAt; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## ') { break }
            if ($lines[$i] -match '^- (.+)$') { $indexed[$Matches[1].Trim()] = $true }
        }
        $vIndexed += $indexed.Count
        $vChecked++
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^#{2,3} ') { continue }
            $title = ($lines[$i] -replace '^#{2,3} ', '').Trim()
            if ($structural -contains $title) { continue }
            if ($title -eq 'Index — every entry in this file') { continue }
            if (-not $indexed.ContainsKey($title)) { $vMissing += "${vf}:$($i+1): $title" }
        }
    }
    if ($vMissing.Count -gt 0) {
        Report-Fail "$($vMissing.Count) verified entr(ies) missing from their file's index -- add one line each:"
        $vMissing | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every verified entry across $vChecked file(s) ($vIndexed indexed) appears in its own index"
    }
}

$measuredFiles = @(& git ls-files -- '*MEASURED.md' | Where-Object { $_ -notlike 'adapters/_template/*' })
$mMissing = @()
$mChecked = 0
foreach ($mf in $measuredFiles) {
    if (-not (Test-Path -LiteralPath $mf)) { continue }
    $lines = @(Get-Content -LiteralPath $mf -Encoding UTF8)
    $idxAt = ($lines | Select-String -Pattern '^## Index$' | Select-Object -First 1).LineNumber
    if (-not $idxAt) {
        Report-Fail "$mf has no ## Index section -- a record that only grows needs one"
        continue
    }
    $indexed = @{}
    for ($i = $idxAt; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## ') { break }
        if ($lines[$i] -match '^- (Not measured yet: )?(.+)$') { $indexed[$Matches[2].Trim()] = $true }
    }
    $mChecked++
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^### ') { continue }
        $title = ($lines[$i] -replace '^### ', '').Trim()
        if (-not $indexed.ContainsKey($title)) { $mMissing += "${mf}:$($i+1): $title" }
    }
}
if ($mMissing.Count -gt 0) {
    Report-Fail "$($mMissing.Count) MEASURED.md entr(ies) missing from their file's index -- add one line each:"
    $mMissing | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
} elseif ($mChecked -gt 0) {
    Report-Pass "every MEASURED.md entry across $mChecked file(s) appears in its own index"
}

# Refuses an adapter missing a mandated file, or holding a probe folder of 3+ scripts with no root probe index.
Section "Adapter file set"

$mandated = @('README.md', 'documentation.md', 'BANDAGES.md', 'FLAGS.md', 'SYNCED.md', 'VERIFIED.md', 'UNVERIFIED.md', 'MEASURED.md')
$adapterDirs = @(& git ls-files | Where-Object { $_ -like '*/documentation.md' } |
                 ForEach-Object { Split-Path $_ -Parent } |
                 ForEach-Object { $_ -replace '\\', '/' } |
                 Where-Object { $_ -ne 'adapters/_template' })
if ($adapterDirs.Count -eq 0) {
    Report-Fail "no adapter directories found -- the file-set check has nothing to enforce, which is not a clean result"
} else {
    $missingFiles = @()
    foreach ($d in $adapterDirs) {
        foreach ($m in $mandated) {
            if (-not (Test-Path -LiteralPath "$d/$m")) { $missingFiles += "$d/$m" }
        }
    }

    $unindexed = @()
    foreach ($d in $adapterDirs) {
        $probeScripts = @{}
        foreach ($f in @(& git ls-files -- "$d")) {
            # Extension test first: every -match overwrites $Matches, so the directory capture must be the last match.
            if ($f -notmatch '\.(lua|py|cs|cpp)$') { continue }
            $rel = ($f -replace '\\', '/').Substring($d.Length + 1)
            if ($rel -notmatch '^(probe[^/]*)/') { continue }
            $pd = $Matches[1]
            if (-not $probeScripts.ContainsKey($pd)) { $probeScripts[$pd] = 0 }
            $probeScripts[$pd]++
        }
        $rootIndex = (Test-Path -LiteralPath "$d/PROBES.md")
        foreach ($pd in $probeScripts.Keys) {
            if ($probeScripts[$pd] -le 2) { continue }
            if ($rootIndex) { continue }
            $unindexed += "$d/$pd ($($probeScripts[$pd]) scripts)"
        }
    }

    if ($missingFiles.Count -gt 0) {
        Report-Fail "$($missingFiles.Count) mandated adapter file(s) missing -- _template has a template for each:"
        $missingFiles | ForEach-Object { Write-Host "          $_" }
    }
    if ($unindexed.Count -gt 0) {
        Report-Fail "probe director(ies) with no index -- an unindexed probe folder hides what writes memory:"
        $unindexed | ForEach-Object { Write-Host "          $_" }
    }
    if ($missingFiles.Count -eq 0 -and $unindexed.Count -eq 0) {
        Report-Pass "all $($adapterDirs.Count) adapters carry the mandated file set, and every adapter with probes has a root PROBES.md"
    }
}

# Refuses a living doc whose whole-set adapter/game count no longer matches the number of adapters.
Section "Adapter/game counts in living docs"

$countWords = @{ 'one' = 1; 'two' = 2; 'three' = 3; 'four' = 4; 'five' = 5; 'six' = 6; 'seven' = 7; 'eight' = 8; 'nine' = 9; 'ten' = 10 }
$trueCount = $adapterDirs.Count
$countScope = @($trackedMd | Where-Object {
    ($_ -like 'agent_docs/*' -and $_ -notlike 'agent_docs/phases/*' -and $_ -notlike 'agent_docs/pitfalls/*' -and
     $_ -notlike 'agent_docs/adr/*' -and $_ -ne 'agent_docs/doc-history.md' -and
     $_ -ne 'agent_docs/verified.md' -and $_ -ne 'agent_docs/unverified.md') -or
    $_ -like 'docs/*' -or $_ -eq 'README.md' -or $_ -like '*CLAUDE.md' -or $_ -like 'adapters/_template/*' -or
    $_ -like 'adapters/*/README.md' -or $_ -like 'adapters/*/documentation.md' -or
    $_ -like 'adapters/emulator/pokemon/*/README.md' -or $_ -like 'adapters/emulator/pokemon/*/documentation.md'
} | Where-Object { $_ -notlike '*VERIFIED.md' })
$staleCounts = @()
$countChecked = 0
$countRe = '(?i)\b(?:all|the)\s+(one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:(?:shipped|real|live|current|existing)\s+)?(adapters|games)\b\s*(\w+)?'
foreach ($md in $countScope) {
    $lines = @(Get-Content -LiteralPath $md)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # A dated statement keeps its number: it was true when it was written.
        if ($line -match '\b(?:19|20)[0-9]{2}\b' -or $line -match 'at the time') { continue }
        foreach ($m in [regex]::Matches($line, $countRe)) {
            $next = $m.Groups[3].Value
            # A restrictive clause makes it a subset, not a claim about the whole set.
            if ($next -match '^(?i)(that|which|who|whose|furthest|closest|nearest|sharing|using|running|built|written)$') { continue }
            $countChecked++
            $n = $countWords[$m.Groups[1].Value.ToLower()]
            if ($n -ne $trueCount) {
                $staleCounts += "${md}:$($i + 1): `"$($m.Value.Trim())`" -- there are $trueCount"
            }
        }
    }
}
if ($countScope.Count -eq 0 -or $trueCount -eq 0) {
    Report-Fail "the adapter/game count gate found nothing in scope -- it would pass vacuously"
} elseif ($staleCounts.Count -gt 0) {
    Report-Fail "$($staleCounts.Count) living doc(s) state an adapter/game count that is no longer true -- correct the number, or say which subset or date it means:"
    $staleCounts | Sort-Object -Unique | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "$countChecked whole-set adapter/game count claim(s) across $($countScope.Count) living doc(s) all say $trueCount"
}

# Refuses a status item that is undated, stale, over two lines, or re-dated unchanged more than once.
Section "status.md is current"

$statusPath = "agent_docs/status.md"
$statusMaxAgeDays = 2
# Two wrapped lines at this file's ~105-column width, plus slack.
$statusMaxItemChars = 215
$statusCarried = @()
$statusLong = @()
if (-not (Test-Path -LiteralPath $statusPath)) {
    Report-Fail "$statusPath is missing"
} else {
    # Age is measured against this file's last commit (or now, if uncommitted), so a quiet repo never goes red.
    $dirty = @(& git status --porcelain -- $statusPath)
    if ($dirty.Count -gt 0) { $refDate = (Get-Date).Date } else {
        $ts = & git log -1 --format=%ct -- $statusPath
        $refDate = if ($ts) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$ts)).LocalDateTime.Date } else { (Get-Date).Date }
    }
    $sLines = @(Get-Content -LiteralPath $statusPath)
    $undated = @(); $stale = @(); $items = 0; $statusPinned = 0
    for ($i = 0; $i -lt $sLines.Count; $i++) {
        $l = $sLines[$i]
        if ($l -notmatch '^- ') { continue }
        $items++
        $dates = [regex]::Matches($l, '20\d\d-\d\d-\d\d') | ForEach-Object { $_.Value }
        if (-not $dates) { $undated += "$($i + 1): $($l.Substring(0, [math]::Min(70, $l.Length)))"; continue }
        $newest = ($dates | Sort-Object | Select-Object -Last 1)
        $age = ($refDate - [datetime]::ParseExact($newest, 'yyyy-MM-dd', $null)).TotalDays
        # A PINNED item skips only the age check; the length limit still applies.
        if ($l -cmatch '\bPINNED\b') { $statusPinned++ }
        elseif ($age -gt $statusMaxAgeDays) { $stale += "$($i + 1): $newest ($([int]$age) days) $($l.Substring(0, [math]::Min(60, $l.Length)))" }
        if ($l.Length -gt $statusMaxItemChars) {
            $statusLong += "$($i + 1): $($l.Length) chars (~$([math]::Round($l.Length / 105.0)) lines) $($l.Substring(0, [math]::Min(50, $l.Length)))"
        }
        if (([regex]::Matches($l, 're-(checked|dated)')).Count -ge 2 -and $l -match 'unchanged') {
            $statusCarried += "$($i + 1): $($l.Substring(0, [math]::Min(70, $l.Length)))"
        }
    }
    if ($statusLong.Count -gt 0) {
        Report-Fail "$($statusLong.Count) status item(s) over two lines -- move the detail to the adapter's UNVERIFIED.md, ideas.md, plans.md or risks.md and leave a pointer (agent_docs/claude-md-cap.md):"
        $statusLong | Select-Object -First 10 | ForEach-Object { Write-Host "          $_" }
    }
    if ($statusCarried.Count -gt 0) {
        Report-Fail "$($statusCarried.Count) status item(s) re-dated 'unchanged' more than once -- that is not short-term memory; move it to the file that tracks it and keep a pointer here:"
        $statusCarried | Select-Object -First 10 | ForEach-Object { Write-Host "          $_" }
    }
    if ($items -eq 0) {
        Report-Fail "$statusPath lists no items -- the currency check would pass vacuously"
    }
    if ($undated.Count -gt 0) {
        Report-Fail "$($undated.Count) status item(s) carry no date -- every item says when it was last re-checked:"
        $undated | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    }
    if ($stale.Count -gt 0) {
        Report-Fail "$($stale.Count) status item(s) are more than $statusMaxAgeDays days old against $($refDate.ToString('yyyy-MM-dd')) -- re-date what is still current, move the rest to plans.md / ideas.md / the adapter's UNVERIFIED.md / risks.md:"
        $stale | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    }
    if ($items -gt 0 -and $undated.Count -eq 0 -and $stale.Count -eq 0) {
        Report-Pass "$items status item(s), all dated within $statusMaxAgeDays days of $($refDate.ToString('yyyy-MM-dd')) ($statusPinned pinned)"
    }
}

# Refuses an UNVERIFIED queue entry with no [READY]/[OPEN]/[DONE] state, or a queue with no 'This run' block.
Section "UNVERIFIED entries carry a state"

$queueFiles = @(& git ls-files -- 'adapters/*/UNVERIFIED.md' 'adapters/emulator/pokemon/*/UNVERIFIED.md') | Where-Object { $_ -notlike 'adapters/_template/*' }
$untaggedQ = @(); $noHead = @(); $qEntries = 0
foreach ($q in $queueFiles) {
    $ql = @(Get-Content -LiteralPath $q)
    if (-not ($ql | Select-String -Pattern '^## This run' -Quiet)) { $noHead += $q }
    for ($i = 0; $i -lt $ql.Count; $i++) {
        $l = $ql[$i]
        if ($l -notmatch '^## ') { continue }
        if ($l -match '^## This run') { continue }
        $qEntries++
        if ($l -notmatch '^## \[(READY|OPEN|DONE)\] ') { $untaggedQ += "$q`:$($i + 1): $($l.Substring(0, [math]::Min(70, $l.Length)))" }
    }
}
if ($queueFiles.Count -lt 4) {
    Report-Fail "only $($queueFiles.Count) UNVERIFIED queue(s) found -- the adapter file set says four; this check would pass vacuously"
} elseif ($untaggedQ.Count -gt 0 -or $noHead.Count -gt 0) {
    if ($untaggedQ.Count -gt 0) {
        Report-Fail "$($untaggedQ.Count) UNVERIFIED entr(y/ies) carry no state -- start the heading with [READY], [OPEN] or [DONE] (_template/UNVERIFIED.md):"
        $untaggedQ | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    }
    if ($noHead.Count -gt 0) {
        Report-Fail "$($noHead.Count) queue(s) have no '## This run -- watch these first' block: $($noHead -join ', ')"
    }
} else {
    Report-Pass "$qEntries UNVERIFIED entries across $($queueFiles.Count) queues carry a state, every queue has a 'This run' block"
}

# Refuses a live phase log that trails its adapter by lag-max commits or more since its last entry.
Section "Phase log freshness"

$phaseMapFile = Join-Path $PSScriptRoot 'phase-map.txt'
if (-not (Test-Path -LiteralPath $phaseMapFile)) { Report-Fail "dev-scripts/phase-map.txt is missing -- the phase-log gate and the pre-commit hook both read it" }
$phaseMap = [ordered]@{}
$phaseLagMax = 3
foreach ($line in (Get-Content -LiteralPath $phaseMapFile)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $parts = $t -split '\s+'
    if ($parts[0] -eq 'lag-max') { $phaseLagMax = [int]$parts[1]; continue }
    $phaseMap[$parts[0]] = $parts[1..($parts.Count - 1)]
}

$phaseStale = @()
foreach ($pf in $phaseMap.Keys) {
    if (-not (Test-Path -LiteralPath $pf)) { Report-Fail "$pf is in the phase map but does not exist"; continue }
    $last = & git log -1 --format=%H -- $pf
    if (-not $last) { continue }
    $args = @('rev-list', '--count', "$last..HEAD", '--') + $phaseMap[$pf]
    $n = [int](& git @args)
    if ($n -ge $phaseLagMax) {
        $phaseStale += "$pf -- $n commit(s) to $($phaseMap[$pf] -join ', ') since its last entry"
    }
}
if ($phaseStale.Count -gt 0) {
    Report-Fail "$($phaseStale.Count) live phase log(s) have fallen behind their adapter -- a phase file is the COMPLETE running log of its work; append this session's dated entry (agent_docs/phases/README.md):"
    $phaseStale | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every live phase log is within $phaseLagMax adapter commits of its last entry"
}

# Refuses a date on which a phase log's tree changed but no dated section heading claims the day.
Section "Phase log coverage"

$phaseCoverFloor = '2026-09-02'
$phaseUncovered = @()
foreach ($pf in $phaseMap.Keys) {
    if (-not (Test-Path -LiteralPath $pf)) { continue }
    $text = [IO.File]::ReadAllText((Join-Path $root $pf))
    $covered = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -notmatch '^#{2,3}\s') { continue }
        foreach ($m in [regex]::Matches($line, '(20\d\d)-(\d\d)-(\d\d)(?:/(\d\d))?')) {
            $covered["$($m.Groups[1].Value)-$($m.Groups[2].Value)-$($m.Groups[3].Value)"] = $true
            if ($m.Groups[4].Success) { $covered["$($m.Groups[1].Value)-$($m.Groups[2].Value)-$($m.Groups[4].Value)"] = $true }
        }
    }
    # Start at the first dated heading: a component log's earlier history is a backfill list, by design.
    if ($covered.Count -gt 0) {
        # @(...) matters: a one-key hashtable's keys unroll to a string, and [0] would return its first character.
        $start = @($covered.Keys | Sort-Object)[0]
    } else {
        $start = @(& git log --diff-filter=A --format=%ad --date=short -- $pf)[-1]
        if (-not $start) { continue }
    }
    if ([string]::Compare($start, $phaseCoverFloor) -lt 0) { $start = $phaseCoverFloor }
    # git reads a bare --since date as that day at the current time of day, dropping that day's earlier commits.
    $dateArgs = @('log', '--no-merges', '--date=short', '--format=%ad', "--since=$start 00:00") +
                @('--') + $phaseMap[$pf]
    $dates = @(& git @dateArgs | Sort-Object -Unique)
    foreach ($d in $dates) {
        if ($covered.ContainsKey($d)) { continue }
        $mine = @(& git @(@('log', '--no-merges', '--format=%H', "--since=$d 00:00", "--until=$d 23:59", '--') + $phaseMap[$pf]))
        $sibling = ''
        foreach ($other in $phaseMap.Keys) {
            if ($other -eq $pf) { continue }
            $theirs = @(& git @(@('log', '--no-merges', '--format=%H', "--since=$d 00:00", "--until=$d 23:59", '--') + $phaseMap[$other]))
            $shared = @($mine | Where-Object { $theirs -contains $_ })
            if ($shared.Count -eq 0) { continue }
            # The sibling must itself claim the day, or it is no better off than this one.
            $otherText = [IO.File]::ReadAllText((Join-Path $root $other))
            if (($otherText -split "`r?`n" | Where-Object { $_ -match '^#{2,3}\s' -and $_ -match [regex]::Escape($d) }).Count -gt 0) {
                $sibling = " -- $($shared.Count) of those commit(s) are logged in $(Split-Path $other -Leaf); a pointer line is enough"
                break
            }
        }
        $phaseUncovered += "$pf -- $d changed $($phaseMap[$pf][0]) with no dated heading claiming it$sibling"
    }
}
if ($phaseUncovered.Count -gt 0) {
    Report-Fail "$($phaseUncovered.Count) date(s) where a phase file's tree changed and no section heading claims the day -- A ONE-LINE POINTER IS A COMPLETE ENTRY (agent_docs/phases/README.md):"
    $phaseUncovered | Select-Object -First 15 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every date since $phaseCoverFloor on which a live phase file's tree changed is claimed by a dated heading ($($phaseMap.Count) log(s))"
}

# Refuses a GitHub repo cited in a living doc that the licensing register does not list.
Section "Licensing gate"

$licText = Get-Content -Raw -Encoding UTF8 -LiteralPath 'agent_docs/licensing.md'
$licExempt = @('agent_docs/ideas.md', 'agent_docs/candidate-games.md', 'agent_docs/security-design.md', 'agent_docs/doc-history.md')
$licScope = @($trackedMd | Where-Object {
    ($_ -like 'agent_docs/*' -and $_ -notlike 'agent_docs/phases/*' -and $_ -notlike 'agent_docs/pitfalls/*') -or
    $_ -like 'docs/*' -or $_ -eq 'README.md' -or $_ -like '*CLAUDE.md' -or $_ -like 'adapters/_template/*' -or
    $_ -like 'adapters/*/README.md' -or $_ -like 'adapters/*/documentation.md' -or $_ -like 'adapters/emulator/pokemon/*/README.md' -or $_ -like 'adapters/emulator/pokemon/*/documentation.md'
} | Where-Object { $licExempt -notcontains $_ -and $_ -notlike '*VERIFIED.md' })
$unlicensed = @(); $cited = 0
foreach ($md in $licScope) {
    $t = Get-Content -Raw -Encoding UTF8 -LiteralPath $md
    foreach ($m in [regex]::Matches($t, 'github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')) {
        $repo = $m.Groups[1].Value -replace '\.git$', ''
        if ($repo -match '/MeshGhost$') { continue }
        $cited++
        if ($licText -notmatch [regex]::Escape($repo)) { $unlicensed += "$md -- $repo" }
    }
}
if ($licScope.Count -eq 0) {
    Report-Fail "the licensing gate found no files in scope -- it would pass vacuously"
} elseif ($unlicensed.Count -gt 0) {
    Report-Fail "$($unlicensed.Count) repo citation(s) in living docs are not in agent_docs/licensing.md -- read the licence and record it before using the project (CLAUDE.md):"
    $unlicensed | Sort-Object -Unique | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every repo cited in $($licScope.Count) living doc(s) ($cited citation(s)) is recorded in licensing.md"
}

# Refuses a compile-time flag in adapter source that the adapter's flag register does not name.
Section "FLAGS.md completeness"

$flagSets = @(
    @{ Adapter = 'adapters/pseudoregalia'; Register = 'adapters/pseudoregalia/FLAGS.md'
       Files = @('adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*.cpp', 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*.hpp')
       Pattern = 'constexpr\s+bool\s+([A-Za-z_][A-Za-z0-9_]*)' }
    @{ Adapter = 'adapters/tevi'; Register = 'adapters/tevi/FLAGS.md'
       Files = @('adapters/tevi/MeshGhostTevi/*.cs')
       Pattern = '(?:const|static\s+readonly)\s+bool\s+([A-Za-z_][A-Za-z0-9_]*)' }
    # Lua flags sit at column 0: scratch globals set inside functions are not flags.
    @{ Adapter = 'adapters/emulator/pokemon/emerald'; Register = 'adapters/emulator/pokemon/emerald/FLAGS.md'
       Files = @('adapters/emulator/pokemon/emerald/meshghost_emerald.lua')
       Pattern = '^(?:local\s+)?([A-Z][A-Z0-9_]{3,})\s*=\s*(?:true|false)\b' }
    @{ Adapter = 'adapters/emulator/pokemon/crystal'; Register = 'adapters/emulator/pokemon/crystal/FLAGS.md'
       Files = @('adapters/emulator/pokemon/crystal/meshghost_crystal.lua')
       Pattern = '^(?:local\s+)?([A-Z][A-Z0-9_]{3,})\s*=\s*(?:true|false)\b' }
)
$flagMissing = @(); $flagsSeen = 0
foreach ($fs in $flagSets) {
    if (-not (Test-Path -LiteralPath $fs.Register)) { Report-Fail "$($fs.Register) is missing"; continue }
    $reg = Get-Content -Raw -Encoding UTF8 -LiteralPath $fs.Register
    $srcFiles = @(& git ls-files -- $fs.Files)
    foreach ($f in $srcFiles) {
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -cmatch $fs.Pattern) {
                $name = $Matches[1]; $flagsSeen++
                if ($reg -notmatch [regex]::Escape($name)) { $flagMissing += "$($fs.Register) lacks $name ($f)" }
            }
        }
    }
}
if ($flagsSeen -eq 0) {
    Report-Fail "no compile-time flags found in any adapter source -- the FLAGS.md check would pass vacuously"
} elseif ($flagMissing.Count -gt 0) {
    Report-Fail "$($flagMissing.Count) flag(s) exist in code and not in the register -- the register only wins over the code if it is complete (CLAUDE.md):"
    $flagMissing | Sort-Object -Unique | Select-Object -First 20 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "$flagsSeen compile-time flag(s) across four adapters are all named in their FLAGS.md"
}

# Refuses a synced-keys page whose keys differ from the send code, or whose check cells are empty or off the ratchet.
Section "SYNCED.md matches the send code"

$syncedSets = @(
    @{ Doc = 'adapters/pseudoregalia/SYNCED.md'; Src = 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp'
       Start = 'std::string local_state = std::format\('; End = 'json_escape\(area_id\)'
       Key = '\\"([a-z_]+)\\":'; Unchecked = 0 }
    @{ Doc = 'adapters/tevi/SYNCED.md'; Src = 'adapters/tevi/MeshGhostTevi/BridgeClient.cs'
       Start = 'public void SendLocalState\('; End = 'object extras = extrasMap;'
       Key = '(?:extrasMap\["|\{\s*")([a-z_]+)"'; Unchecked = 0 }
    @{ Doc = 'adapters/emulator/pokemon/crystal/SYNCED.md'; Src = 'adapters/emulator/pokemon/crystal/meshghost_crystal.lua'
       Start = '^\s*extras = \{'; End = 'arth = artH'
       Key = '(?<![=~<>])\b([a-z]+)\s*=(?!=)'; Unchecked = 0 }
    @{ Doc = 'adapters/emulator/pokemon/emerald/SYNCED.md'; Src = 'adapters/emulator/pokemon/emerald/meshghost_emerald.lua'
       Start = '^local function encodeLocalState\('; End = '^local ENCODED_NO_SEND'
       Key = '"([a-z_]+)":%[sd]'; Unchecked = 0 }
)
$syncedBase = @('type', 'payload', 'state', 'area_id', 'position', 'orientation', 'anim', 'extras')
$syncedProblems = @(); $syncedKeysSeen = 0
foreach ($ss in $syncedSets) {
    if (-not (Test-Path -LiteralPath $ss.Doc)) { $syncedProblems += "$($ss.Doc) is missing"; continue }
    if (-not (Test-Path -LiteralPath $ss.Src)) { $syncedProblems += "$($ss.Src) is missing -- update this section's table"; continue }

    $codeKeys = @{}; $inBlock = $false; $blockDone = $false
    foreach ($line in (Get-Content -LiteralPath $ss.Src)) {
        if ($blockDone) { break }
        if (-not $inBlock -and $line -match $ss.Start) { $inBlock = $true }
        if ($inBlock) {
            foreach ($m in [regex]::Matches($line, $ss.Key)) {
                $k = $m.Groups[1].Value
                if ($syncedBase -notcontains $k) { $codeKeys[$k] = $true }
            }
            if ($line -match $ss.End) { $blockDone = $true }
        }
    }
    if (-not $blockDone -or $codeKeys.Count -eq 0) {
        $syncedProblems += "$($ss.Src): the send block ($($ss.Start) .. $($ss.End)) was not found or held no keys -- the extractor no longer fits the code"
        continue
    }
    $syncedKeysSeen += $codeKeys.Count

    $docKeys = @{}; $unchecked = 0; $section = ''; $groups = [ordered]@{}
    $header = $null; $checkCol = -1; $isKeyTable = $false; $isDetails = $false; $lineNo = 0
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $ss.Doc)) {
        $lineNo++
        if ($line -match '^## (.+)$') { $section = $Matches[1] }
        if ($line -notmatch '^\|') { $header = $null; continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($null -eq $header) {
            $header = $cells
            $checkCol = [array]::IndexOf($cells, 'Checked on arrival')
            $isKeyTable = ($cells[0] -eq 'Key')
            $isDetails = ($checkCol -ge 0)
            continue
        }
        if ($cells[0] -match '^-+$') { continue }
        if ($checkCol -ge 0) {
            if ($checkCol -ge $cells.Count -or $cells[$checkCol] -eq '') {
                $syncedProblems += "$($ss.Doc):$lineNo has an empty 'Checked on arrival' cell -- write the check, or 'not checked yet'"
            } elseif ($cells[$checkCol] -match 'not checked yet') { $unchecked++ }
        }
        if ($isKeyTable -and $cells[0] -match '^`([a-z_]+)`$') {
            $k = $Matches[1]; $docKeys[$k] = $true
            $g = "$section|$(if ($isDetails) { 'details' } else { 'summary' })"
            if (-not $groups.Contains($g)) { $groups[$g] = @() }
            $groups[$g] += $k
        }
    }

    foreach ($k in $codeKeys.Keys) { if (-not $docKeys.ContainsKey($k)) { $syncedProblems += "$($ss.Doc) does not list '$k', which $($ss.Src) sends" } }
    foreach ($k in $docKeys.Keys) { if (-not $codeKeys.ContainsKey($k)) { $syncedProblems += "$($ss.Doc) lists '$k', which $($ss.Src) does not send" } }
    foreach ($g in @($groups.Keys)) {
        if ($g -notlike '*|summary') { continue }
        $name = $g.Substring(0, $g.Length - '|summary'.Length)
        $d = "$name|details"
        $sum = ($groups[$g] | Sort-Object) -join ','
        $det = if ($groups.Contains($d)) { ($groups[$d] | Sort-Object) -join ',' } else { '' }
        if ($sum -ne $det) { $syncedProblems += "$($ss.Doc) '## $name': the summary table and its details table list different keys" }
    }
    if ($unchecked -gt $ss.Unchecked) {
        $syncedProblems += "$($ss.Doc) has $unchecked 'not checked yet' cell(s), recorded $($ss.Unchecked) -- a new value arrives unguarded: guard it, or raise the number here on purpose"
    } elseif ($unchecked -lt $ss.Unchecked) {
        $syncedProblems += "$($ss.Doc) is down to $unchecked 'not checked yet' cell(s) (recorded $($ss.Unchecked)) -- the guards are landing; lower Unchecked in this section so the floor holds"
    }
}
if ($syncedProblems.Count -gt 0) {
    Report-Fail "$($syncedProblems.Count) SYNCED.md problem(s) -- the page is the guard checklist, so it must match the code:"
    $syncedProblems | Select-Object -First 30 | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "$syncedKeysSeen extras key(s) across $($syncedSets.Count) adapters match their SYNCED.md, every one with a check cell"
}

# Refuses a Go fuzz target with no CI step (or declared opt-out), or with no row in the testing roster.
Section "Fuzz census: every target has a CI step and a roster row"

$fuzzTargets = @{}
foreach ($f in @(Get-ChildItem -Recurse -File -Filter '*_test.go' | Where-Object { $_.FullName -notmatch '\\(\.git|node_modules)\\' })) {
    $rel = (Resolve-Path -Relative $f.FullName) -replace '^\.[\\/]', '' -replace '\\', '/'
    $pkgDir = './' + ($rel -replace '/[^/]+$', '')
    foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), '(?m)^func\s+(Fuzz\w+)\s*\(')) {
        # Keyed by package too: two packages declare the same Fuzz target name.
        $fuzzTargets["$pkgDir $($m.Groups[1].Value)"] = $rel
    }
}
if ($fuzzTargets.Count -eq 0) {
    Report-Fail "no Fuzz targets found at all -- this gate is looking in the wrong place"
} else {
    $ciText = ''
    if (Test-Path -LiteralPath '.github/workflows/ci.yml') { $ciText = Get-Content -LiteralPath '.github/workflows/ci.yml' -Raw }
    $rosterText = ''
    if (Test-Path -LiteralPath 'agent_docs/testing.md') { $rosterText = Get-Content -LiteralPath 'agent_docs/testing.md' -Raw }

    $noStep = @()
    $noRow  = @()
    foreach ($key in ($fuzzTargets.Keys | Sort-Object)) {
        $pkgDir, $name = $key -split ' ', 2
        $src = Get-Content -LiteralPath $fuzzTargets[$key] -Raw
        # An opt-out is declared above the func as "// fuzz-census: no-ci-step -- <reason>", never inferred.
        $optOut = $src -match ('(?m)^//\s*fuzz-census:\s*no-ci-step\b.*\r?\n(?:.*\r?\n)??func\s+' + [regex]::Escape($name) + '\s*\(')
        # A real step line, not a substring: a target named only in a ci.yml comment has no step.
        $stepLine = '(?m)^[ \t]*' + [regex]::Escape($pkgDir) + '[ \t]+' + [regex]::Escape($name) + '[ \t]+\d+[smh]\b'
        if (-not $optOut -and $ciText -notmatch $stepLine) { $noStep += "$name ($($fuzzTargets[$key]))" }
        if ($rosterText -notmatch [regex]::Escape($name)) { $noRow += "$name ($($fuzzTargets[$key]))" }
    }
    if ($noStep.Count -gt 0) {
        Report-Fail ("{0} fuzz target(s) have no step in ci.yml -- they never run:`n          {1}" -f $noStep.Count, ($noStep -join "`n          "))
    }
    if ($noRow.Count -gt 0) {
        Report-Fail ("{0} fuzz target(s) are missing from agent_docs/testing.md's roster -- the next reviewer cannot see them:`n          {1}" -f $noRow.Count, ($noRow -join "`n          "))
    }
    if ($noStep.Count -eq 0 -and $noRow.Count -eq 0) {
        Report-Pass "all $($fuzzTargets.Count) fuzz target(s) have a CI step (or a documented opt-out) and a roster row"
    }
}

# Refuses an ADR file the architecture index does not link, or an ADR sequence number used twice.
Section "ADR index coverage"

$adrDir = "agent_docs/adr"
$archFile = "agent_docs/architecture.md"
if (-not (Test-Path -LiteralPath $adrDir)) {
    Report-Fail "$adrDir does not exist -- the decision log is supposed to live there"
} else {
    $archText = Get-Content -LiteralPath $archFile -Raw
    $adrFiles = @(Get-ChildItem -LiteralPath $adrDir -Filter '*.md' | Sort-Object Name)
    if ($adrFiles.Count -eq 0) {
        Report-Fail "$adrDir holds no .md files -- not a clean result, the log should be there"
    } else {
        $unlinked = @()
        foreach ($f in $adrFiles) {
            if ($archText -notmatch [regex]::Escape("adr/$($f.Name)")) { $unlinked += $f.Name }
        }

        $seen = @{}
        $dupes = @()
        foreach ($f in $adrFiles) {
            # Unnumbered files are research, not decisions: skipped here, though they must still be linked.
            if ($f.Name -notmatch '^(\d{4})-') { continue }
            $n = $Matches[1]
            if ($seen.ContainsKey($n)) { $dupes += "$n used by $($seen[$n]) and $($f.Name)" }
            else { $seen[$n] = $f.Name }
        }

        if ($unlinked.Count -gt 0) {
            Report-Fail "$($unlinked.Count) ADR file(s) not linked from $archFile's index -- add one line each:"
            $unlinked | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
        }
        if ($dupes.Count -gt 0) {
            Report-Fail "duplicate ADR sequence number(s):"
            $dupes | ForEach-Object { Write-Host "          $_" }
        }
        if ($unlinked.Count -eq 0 -and $dupes.Count -eq 0) {
            Report-Pass "every ADR ($($adrFiles.Count) files, $($seen.Count) numbered) is linked from architecture.md's index"
        }
    }
}

# Refuses bridge port, port-walk or busy-port cooldown constants that differ between adapters.
Section "Bridge constants agree across the four adapters"

$bridgeSources = @{
    'Emerald (Lua)'         = @('adapters/emulator/pokemon/emerald/meshghost_emerald.lua')
    'Crystal (Lua)'         = @('adapters/emulator/pokemon/crystal/meshghost_crystal.lua')
    'Pseudoregalia (C++)'   = @('adapters/pseudoregalia/MeshGhostPseudo/Mod/src/BridgeClient.hpp')
    'TEVI (C#)'             = @('adapters/tevi/MeshGhostTevi/BridgeClient.cs',
                                'adapters/tevi/MeshGhostTevi/Plugin.cs')
}
$bridgeProblems = @()
$basePorts = @{}
$portCounts = @{}
$cooldownSeconds = @{}

foreach ($name in $bridgeSources.Keys) {
    $missingSrc = @($bridgeSources[$name] | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingSrc.Count -gt 0) {
        $bridgeProblems += "$name -- source not found at $($missingSrc -join ', ')"
        continue
    }
    $text = ($bridgeSources[$name] | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_ }) -join "`n"

    if ($text -match 'BRIDGE_BASE_PORT\s*(?:=|\s)\s*(\d+)') { $basePorts[$name] = [int]$Matches[1] }
    elseif ($text -match 'DefaultBridgePort\s*=\s*(\d+)') { $basePorts[$name] = [int]$Matches[1] }
    else { $bridgeProblems += "$name -- no bridge base port found (renamed?)" }

    if ($text -match 'BRIDGE_PORT_COUNT\s*(?:=|\s)\s*(\d+)') { $portCounts[$name] = [int]$Matches[1] }
    elseif ($text -match 'BridgePortCount\s*=\s*(\d+)') { $portCounts[$name] = [int]$Matches[1] }
    else { $bridgeProblems += "$name -- no bridge port-walk count found (renamed?)" }

    # Units differ by language (frames at 60fps, milliseconds, seconds), so all are compared in seconds.
    if ($text -match 'BUSY_PORT_COOLDOWN_FRAMES\s*=\s*(\d+)') {
        $cooldownSeconds[$name] = [int]$Matches[1] / 60
    } elseif ($text -match 'BUSY_PORT_COOLDOWN\s*\{\s*(\d+)\s*\}') {
        $cooldownSeconds[$name] = [int]$Matches[1] / 1000
    } elseif ($text -match 'BusyPortCooldown\s*=\s*TimeSpan\.FromSeconds\((\d+)\)') {
        $cooldownSeconds[$name] = [int]$Matches[1]
    } else {
        $bridgeProblems += "$name -- no busy-port cooldown found (renamed?)"
    }
}

function Assert-Agree($label, $table, $expected) {
    $bad = @()
    foreach ($k in $table.Keys) {
        if ($table[$k] -ne $expected) { $bad += "$k = $($table[$k])" }
    }
    if ($bad.Count -gt 0) {
        return "$label disagrees (want $expected): " + ($bad -join '; ')
    }
    return $null
}

# 7778 is what packaging/release/config.json ships and every README hands out.
$p = Assert-Agree 'bridge base port' $basePorts 7778
if ($p) { $bridgeProblems += $p }
$p = Assert-Agree 'bridge port-walk count' $portCounts 8
if ($p) { $bridgeProblems += $p }
$p = Assert-Agree 'busy-port cooldown (seconds)' $cooldownSeconds 10
if ($p) { $bridgeProblems += $p }

if ($bridgeProblems.Count -gt 0) {
    Report-Fail "the four bridge clients have drifted apart:"
    $bridgeProblems | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "bridge constants agree across all $($basePorts.Count) adapters (port 7778, 8-port walk, 10s cooldown)"
}

# Refuses a phase file that no row of the phase index links.
Section "Phase index coverage"

$phaseDir = "agent_docs/phases"
$phaseIndex = "agent_docs/phases/README.md"
if (-not (Test-Path -LiteralPath $phaseIndex)) {
    Report-Fail "$phaseIndex does not exist -- the phase index is supposed to live there"
} else {
    $phaseText = Get-Content -LiteralPath $phaseIndex -Raw
    $phaseDirFull = (Resolve-Path -LiteralPath $phaseDir).Path
    $phaseFiles = @(Get-ChildItem -LiteralPath $phaseDir -Filter '*.md' -Recurse |
        Where-Object { $_.Name -ne 'README.md' } | Sort-Object FullName)
    $unlinkedPhases = @()
    foreach ($f in $phaseFiles) {
        # A row links a file by its path relative to phases/, with forward slashes.
        $rel = $f.FullName.Substring($phaseDirFull.Length).TrimStart('\', '/').Replace('\', '/')
        if ($phaseText -notmatch [regex]::Escape("($rel)")) { $unlinkedPhases += $rel }
    }
    if ($unlinkedPhases.Count -gt 0) {
        Report-Fail "$($unlinkedPhases.Count) phase file(s) not linked from $phaseIndex -- add one row each:"
        $unlinkedPhases | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every phase file ($($phaseFiles.Count)) is linked from the phase index"
    }
}

# Refuses a bridge message type that the adapter template's protocol page never names.
Section "Bridge message coverage in the adapter template"

$bridgeGo = "bridge/bridge.go"
$protoDoc = "adapters/_template/PROTOCOL.md"
if (-not (Test-Path -LiteralPath $bridgeGo)) {
    Report-Fail "$bridgeGo does not exist -- the bridge message types are supposed to live there"
} elseif (-not (Test-Path -LiteralPath $protoDoc)) {
    Report-Fail "$protoDoc does not exist -- the adapter protocol template is supposed to live there"
} else {
    $protoText = Get-Content -LiteralPath $protoDoc -Raw
    $wireNames = @([regex]::Matches(
        (Get-Content -LiteralPath $bridgeGo -Raw),
        'MessageType\s*=\s*"([a-z_]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # Delimited match only: a bare substring lets ordinary prose (the word "world") pass as documentation.
    $tick  = [char]0x60   # built from char codes: both are punishing to quote inside a PowerShell string
    $quote = [char]0x22
    $undocumented = @($wireNames | Where-Object {
        $n = [regex]::Escape($_)
        ($protoText -notmatch ($tick + $n + $tick)) -and ($protoText -notmatch ($quote + $n + $quote))
    })
    if ($wireNames.Count -eq 0) {
        Report-Fail "found no MessageType constants in $bridgeGo -- this check has stopped working, fix it rather than deleting it"
    } elseif ($undocumented.Count -gt 0) {
        Report-Fail "$($undocumented.Count) bridge message type(s) exist in $bridgeGo but appear nowhere in $protoDoc -- a new adapter built from the template would never know they exist:"
        $undocumented | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "all $($wireNames.Count) bridge message type(s) appear in the adapter template"
    }
}

# Refuses a tracked dev-script that the dev-scripts readme does not name.
Section "dev-scripts README coverage"

$devIndex = "dev-scripts/README.md"
if (-not (Test-Path -LiteralPath $devIndex)) {
    Report-Fail "$devIndex does not exist"
} else {
    $devText = Get-Content -LiteralPath $devIndex -Raw
    $devScripts = @(& git ls-files 'dev-scripts/*.bat' 'dev-scripts/*.ps1' 'dev-scripts/*.lua' 'dev-scripts/*.sh')
    $undocumented = @()
    foreach ($s in $devScripts) {
        $name = Split-Path -Leaf $s
        if ($name -eq 'preflight.ps1') { continue }   # this file; it documents itself by running
        if ($devText -notmatch [regex]::Escape($name)) { $undocumented += $name }
    }
    if ($undocumented.Count -gt 0) {
        Report-Fail "$($undocumented.Count) dev-script(s) not mentioned in $devIndex :"
        $undocumented | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every tracked dev-script ($($devScripts.Count)) is named in dev-scripts/README.md"
    }
}

# Refuses a RemoteGhost pointer field that either release path does not mention.
Section "RemoteGhost pointer fields are cleared at release (Pseudoregalia)"

$rgHpp = "adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.hpp"
$rgCpp = "adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp"
if ((Test-Path $rgHpp) -and (Test-Path $rgCpp)) {
    $hppLines = @(Get-Content -LiteralPath $rgHpp)
    $structStart = -1; $structEnd = -1
    for ($i = 0; $i -lt $hppLines.Count; $i++) {
        if ($structStart -lt 0 -and $hppLines[$i] -match '^\s*struct RemoteGhost\b') { $structStart = $i; continue }
        if ($structStart -ge 0 -and $hppLines[$i] -match '^    \};') { $structEnd = $i; break }
    }
    if ($structStart -lt 0 -or $structEnd -lt 0) {
        Report-Fail "could not locate the RemoteGhost struct in $rgHpp -- fix this check, do not delete it"
    } else {
        $fields = @()
        for ($i = $structStart; $i -lt $structEnd; $i++) {
            if ($hppLines[$i] -match 'RC::Unreal::\w+\*\s*(\w+)\s*\{') { $fields += $Matches[1] }
        }
        $cppText = Get-Content -LiteralPath $rgCpp -Raw
        $bodies = @{}
        foreach ($fn in @('release_all_ghosts', 'release_ghost')) {
            if ($cppText -match "(?s)auto Plugin::$fn\(.*?\n    \}") { $bodies[$fn] = $Matches[0] }
        }
        if ($fields.Count -eq 0 -or $bodies.Count -ne 2) {
            Report-Fail "RemoteGhost release check could not parse its inputs (fields=$($fields.Count), bodies=$($bodies.Count)) -- fix this check, do not delete it"
        } else {
            $unreleased = @()
            foreach ($f in $fields) {
                foreach ($fn in $bodies.Keys) {
                    # Word boundary, not substring: nametag_plate must not be satisfied by nametag_plate_mid.
                    if ($bodies[$fn] -notmatch "\b$([regex]::Escape($f))\b") { $unreleased += "$f (missing from $fn)" }
                }
            }
            if ($unreleased.Count -gt 0) {
                Report-Fail ("RemoteGhost pointer field(s) not mentioned in a release path -- the stale-pointer family's next member:`n          " + ($unreleased -join "`n          "))
            } else {
                Report-Pass "every RemoteGhost pointer field ($($fields.Count)) is mentioned in both release paths"
            }
        }
    }
} else {
    Report-Skip "Pseudoregalia sources not present"
}

# Refuses a change in the FindAllOf call-site count until the recorded count is updated.
Section "FindAllOf ratchet (Pseudoregalia)"

$expectedFindAllOf = 47
$faCount = (Select-String -LiteralPath "adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp" -Pattern 'UObjectGlobals::FindAllOf\(' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
if ($null -eq $faCount) { $faCount = 0 }
if ($faCount -eq $expectedFindAllOf) {
    Report-Pass "FindAllOf call sites: $faCount (matches the recorded count)"
} elseif ($faCount -gt $expectedFindAllOf) {
    Report-Fail "FindAllOf call sites grew: $faCount vs recorded $expectedFindAllOf -- name the new site's cadence (one-shot / per-event / per-interval / per-tick / per-ghost-per-tick, per _template/README.md's write-time checklist) in a comment at the site, confirm it is not on a steady per-tick path, then bump `$expectedFindAllOf in this file"
} else {
    Report-Fail "FindAllOf call sites shrank: $faCount vs recorded $expectedFindAllOf -- good news, probably; update `$expectedFindAllOf in this file so the ratchet holds at the new floor"
}

# Refuses a file-scope raw UObject/AActor cache without a stale-safe: annotation above it.
Section "Raw-pointer caches must say why they cannot dangle (Pseudoregalia)"

$pluginPath = "adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp"
$pluginLines = Get-Content -LiteralPath $pluginPath
$cachePattern = '^\s*(static\s+)?(std::vector<\s*(UObject|AActor)\s*\*\s*>|(UObject|AActor)\s*\*)\s+g_\w+\s*[={;]'
$unannotated = @()
for ($i = 0; $i -lt $pluginLines.Count; $i++) {
    if ($pluginLines[$i] -match $cachePattern) {
        $lo = [Math]::Max(0, $i - 6)
        $window = $pluginLines[$lo..$i] -join "`n"
        if ($window -notmatch 'stale-safe:') {
            $unannotated += ("line " + ($i + 1) + ": " + $pluginLines[$i].Trim())
        }
    }
}
if ($unannotated.Count -eq 0) {
    Report-Pass "every file-scope raw UObject*/AActor* cache carries a stale-safe: annotation"
} else {
    Report-Fail ("raw-pointer cache(s) with no stale-safe: annotation -- say why it cannot dangle (hook-cleared and never freed mid-level, or per-use validated), or hold FWeakObjectPtr instead: " + ($unannotated -join "; "))
}

# Refuses a ghost-drop site that keeps a handle to a component attached to the dropped ghost.
Section "Dropping a ghost must drop every component attached to it (Pseudoregalia)"

$ghostDropTokens = @('vfx_components.clear()', 'weapon_fly_component = nullptr', 'recall_glow_component = nullptr')
$dropLines = @()
for ($i = 0; $i -lt $pluginLines.Count; $i++) {
    if ($pluginLines[$i] -match '\.ghost = nullptr;') { $dropLines += $i }
}
$dropFails = @()
# Each drop site is checked over the lines since the previous one, so each site answers for itself.
$prev = 0
foreach ($d in $dropLines) {
    $window = $pluginLines[$prev..$d] -join "`n"
    $missing = @($ghostDropTokens | Where-Object { $window -notmatch [regex]::Escape($_) })
    if ($missing.Count -gt 0) {
        $dropFails += ("line " + ($d + 1) + " drops the ghost without: " + ($missing -join ", "))
    }
    $prev = $d + 1
}
if ($dropLines.Count -eq 0) {
    Report-Fail 'no ghost-drop site found in Plugin.cpp -- this check has stopped checking anything'
} elseif ($dropFails.Count -eq 0) {
    Report-Pass ("every ghost-drop site (" + $dropLines.Count + ") clears the components attached to that ghost")
} else {
    Report-Fail ("a ghost was dropped while a handle to something attached to it was kept -- clear it in the same breath: " + ($dropFails -join "; "))
}

# Refuses an undated line in a living doc that counts the adapters or games.
Section "No hard-coded adapter or game counts in living docs"

$countFiles = @(Get-ChildItem -LiteralPath (Join-Path $root "docs") -Filter *.md) +
    @(Get-ChildItem -LiteralPath (Join-Path $root "adapters\_template") -Filter *.md) +
    @(Get-Item -LiteralPath (Join-Path $root "README.md"))
$countHits = @()
foreach ($f in $countFiles) {
    $n = 0
    foreach ($line in Get-Content -LiteralPath $f.FullName) {
        $n++
        # A dated line is a record of that day, not a living claim.
        if ($line -match '20\d\d-\d\d-\d\d') { continue }
        if ($line -match '(?i)\b(all|the|our|these) (three|four|five|six|seven|eight|3|4|5|6|7|8) (shipped |existing |current )?(adapters|games|mods)\b|\b(three|four|five|six|seven|eight) shipped (adapters|games|mods)\b') {
            $countHits += "$($f.FullName.Substring($root.Length + 1)):$n"
        }
    }
}
if ($countHits.Count -eq 0) {
    Report-Pass "no living doc counts the adapters or games (say 'every shipped adapter')"
} else {
    Report-Fail "$($countHits.Count) line(s) count the adapters/games -- a count is stale the day the next game lands; say 'every shipped adapter', or date the line if it is a record:"
    $countHits | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
}

# Refuses a GitHub Action pinned to different commits or versions across workflows.
Section "GitHub Action versions agree across workflows"

$wfDir = Join-Path $root ".github\workflows"
if (Test-Path $wfDir) {
    $uses = @{}
    foreach ($wf in Get-ChildItem -LiteralPath $wfDir -Filter *.yml) {
        foreach ($m in [regex]::Matches((Get-Content -Raw -Encoding UTF8 -LiteralPath $wf.FullName),
                '(?m)^\s*(?:-\s*)?uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@([0-9a-f]{40}|[^\s#]+)[ \t]*(?:#[ \t]*(v[0-9][0-9.]*))?')) {
            $name, $ref, $note = $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value
            # A SHA pin carries its release in the trailing comment, so both must agree.
            $ver = if ($ref -match '^[0-9a-f]{40}$') { "$(if ($note) { $note } else { 'no # vN' }) at $($ref.Substring(0, 12))" } else { $ref }
            if (-not $uses.ContainsKey($name)) { $uses[$name] = @{} }
            if (-not $uses[$name].ContainsKey($ver)) { $uses[$name][$ver] = @() }
            $uses[$name][$ver] += $wf.Name
        }
    }
    $split = @()
    foreach ($name in $uses.Keys) {
        if ($uses[$name].Keys.Count -gt 1) {
            $detail = ($uses[$name].Keys | Sort-Object | ForEach-Object {
                "$_ in $(($uses[$name][$_] | Sort-Object -Unique) -join ', ')" }) -join "; "
            $split += "$name -- $detail"
        }
    }
    if ($split.Count -gt 0) {
        Report-Fail "$($split.Count) action(s) pinned to different versions across workflows:"
        $split | Sort-Object | ForEach-Object { Write-Host "          $_" }
        Write-Host "          Raise the older ones. A workflow added later is how this happens."
    } else {
        Report-Pass "every action used in $((Get-ChildItem -LiteralPath $wfDir -Filter *.yml).Count) workflow(s) is at one version"
    }
}
# Refuses an adapter with no path-filtered workflow, or an adapter gate filtering beyond adapters/.
Section "Every adapter has its own path-filtered workflow"

$wfDir2 = Join-Path $root ".github\workflows"
$adapterDirs2 = @(& git ls-files | Where-Object { $_ -like 'adapters/*/documentation.md' -or $_ -like 'adapters/*/*/documentation.md' -or $_ -like 'adapters/*/*/*/documentation.md' } |
                  ForEach-Object { $_ -replace '/documentation\.md$', '' } |
                  Where-Object { $_ -notlike '*_template*' } | Sort-Object -Unique)
if (-not (Test-Path $wfDir2) -or $adapterDirs2.Count -eq 0) {
    Report-Fail "no workflows or no adapters found -- this check would pass vacuously"
} else {
    $gates = @{}
    foreach ($wf in Get-ChildItem -LiteralPath $wfDir2 -Filter *.yml) {
        $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $wf.FullName
        $paths = @([regex]::Matches($raw, "(?m)^\s+-\s+'([^']+)'\s*$") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        # Only a workflow naming an adapters/ path is an adapter gate; language gates are repo-wide on purpose.
        if (@($paths | Where-Object { $_ -like 'adapters/*' }).Count -gt 0) { $gates[$wf.Name] = $paths }
    }
    $probs = @()
    foreach ($name in $gates.Keys) {
        $own = ".github/workflows/$name"
        $stray = @($gates[$name] | Where-Object { $_ -notlike 'adapters/*' -and $_ -ne $own })
        if ($stray.Count -gt 0) {
            $probs += "$name is an adapter gate but also filters on $($stray -join ', ') -- an adapter gate may name only adapters/** and its own file"
        }
    }
    foreach ($a in $adapterDirs2) {
        $covered = @($gates.Keys | Where-Object {
            $g = $gates[$_]
            @($g | Where-Object { $p = ($_ -replace '/\*\*$', ''); $a -eq $p -or $a -like "$p/*" }).Count -gt 0
        })
        if ($covered.Count -eq 0) {
            $probs += "$a has no path-filtered workflow -- add one gated on its own tree (see adapters/_template/README.md)"
        }
    }
    if ($probs.Count -gt 0) {
        Report-Fail "$($probs.Count) adapter-workflow problem(s):"
        $probs | Sort-Object | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "all $($adapterDirs2.Count) adapter(s) are covered by $($gates.Count) path-filtered gate(s), none broader than its own tree"
    }
}

# Refuses a scratch probe slot, in the repo or the deployed copy, that still holds a probe.
Section "The scratch probe slot is EMPTY"
$scratch = Join-Path $root "adapters\pseudoregalia\probes\probe_scratch\Scripts\main.lua"
if (-not (Test-Path $scratch)) {
    Report-Fail "adapters\pseudoregalia\probes\probe_scratch\Scripts\main.lua is missing -- the scratch slot's pristine stub is what a session restores to; recreate it (see PROBES.md)"
} else {
    # Comments are stripped first: the stub's own header names these verbs.
    $body = (Get-Content $scratch -Raw) -replace '(?s)--\[\[.*?\]\]', '' -replace '(?m)--.*$', ''
    $verbs = @("LoopAsync", "FindAllOf", "ExecuteInGameThread", "StaticFindObject", "RegisterHook", "ForEachProperty", "LoadAsset")
    $found = $verbs | Where-Object { $body -match [regex]::Escape($_) }
    if ($found) {
        Report-Fail ("the scratch probe slot still holds a probe (" + ($found -join ", ") + ") -- copy it somewhere it will be found by name, then restore probes/probe_scratch/Scripts/main.lua's stub")
    } else {
        Report-Pass "the scratch probe slot is empty (no probe left loaded under a name that describes nothing)"
    }
}

# The deployed slot's path is machine-specific, so it is checked only when the variable is set.
$deployedScratch = $env:MESHGHOST_PSEUDO_SCRATCH
if ($deployedScratch) {
    if (-not (Test-Path $deployedScratch)) {
        Report-Warn "MESHGHOST_PSEUDO_SCRATCH is set but nothing is there: $deployedScratch"
    } else {
        $deployedBody = (Get-Content $deployedScratch -Raw) -replace '(?s)--\[\[.*?\]\]', '' -replace '(?m)--.*$', ''
        $deployedFound = @("LoopAsync", "FindAllOf", "ExecuteInGameThread", "StaticFindObject", "RegisterHook") |
            Where-Object { $deployedBody -match [regex]::Escape($_) }
        if ($deployedFound) {
            Report-Fail ("the DEPLOYED scratch slot still holds a probe (" + ($deployedFound -join ", ") + ") -- it will load at the next launch: $deployedScratch")
        } else {
            Report-Pass "the deployed scratch probe slot is empty too"
        }
    }
} else {
    Report-Warn "Pseudoregalia -- set MESHGHOST_PSEUDO_SCRATCH to also check the DEPLOYED scratch slot (the one that actually loads)"
}

# A ratchet: the count may only fall, and each fall is recorded here so it cannot creep back up.
function Report-Ratchet([string]$what, [int]$count, [int]$floor, [string]$fix, $examples) {
    if ($count -eq $floor) {
        if ($floor -eq 0) { Report-Pass "no $what" } else { Report-Pass "$what`: $count, at the recorded floor" }
    } elseif ($count -gt $floor) {
        Report-Fail "$what`: $count, above the recorded floor of $floor -- $fix"
        @($examples) | Select-Object -First 10 | ForEach-Object { Write-Host "          $_" }
    } else {
        # A warning, not a failure: a code commit cannot carry the gate change that lowers the floor.
        Report-Warn "$what`: $count, below the recorded floor of $floor -- lower the floor in preflight.ps1 to $count"
    }
}

# Refuses a source file with no code-map row, a shipped config key the config page omits, a build step with no
# Status line, or a Contents list that differs from its file's headings.
Section "Doc coverage"
$floorNoCodeMapRow = 0
$floorStepNoStatus = 0

$codeMapText = if (Test-Path -LiteralPath 'agent_docs/code-map.md') { [System.IO.File]::ReadAllText((Join-Path $root 'agent_docs/code-map.md')) } else { '' }
$mapped = @(& git ls-files -- '*.go' '*.cs' '*.cpp' '*.hpp' '*.lua' '*.py' | Where-Object {
    $_ -notmatch '_test\.go$' -and $_ -notmatch '/testdata/' -and $_ -notmatch '(^|/)tests?/' -and
    $_ -notmatch '\.Tests/' -and $_ -notmatch '/probes/' -and $_ -notmatch '^dev-scripts/' })
# A probe gets one row per folder: the probes folder itself, or a probe's own folder under it.
$mapped += @(& git ls-files | Where-Object { $_ -match '^(.+?/probes)/(([^/]+)/)?[^/]+$' } | ForEach-Object {
    if ($Matches[3]) { "$($Matches[1])/$($Matches[3])" } else { $Matches[1] } } | Sort-Object -Unique)
$noRow = @($mapped | Where-Object { -not $codeMapText.Contains($_) })
Report-Ratchet 'source files and probe folders with no agent_docs/code-map.md row' $noRow.Count $floorNoCodeMapRow `
    'give each a row in agent_docs/code-map.md' $noRow

$configDoc = [System.IO.File]::ReadAllText((Join-Path $root 'docs/config.md'))
$configKeys = New-Object System.Collections.Generic.List[string]
function Add-ConfigKeys($node, [string]$prefix) {
    foreach ($p in $node.PSObject.Properties) {
        $configKeys.Add("$prefix$($p.Name)")
        if ($p.Value -is [System.Management.Automation.PSCustomObject]) { Add-ConfigKeys $p.Value "$prefix$($p.Name)." }
    }
}
Add-ConfigKeys ([System.IO.File]::ReadAllText((Join-Path $root 'packaging/release/config.json')) | ConvertFrom-Json) ''
$undocumented = @($configKeys | Where-Object {
    $leaf = ($_ -split '\.')[-1]
    -not ($configDoc.Contains("``$leaf``") -or $configDoc.Contains("""$leaf""") -or $configDoc.Contains("``$_``")) })
if ($configKeys.Count -eq 0) {
    Report-Fail "packaging/release/config.json yielded no keys -- the reader is broken, not the docs"
} elseif ($undocumented.Count -gt 0) {
    Report-Fail "$($undocumented.Count) shipped config key(s) that docs/config.md never names: $($undocumented -join ', ')"
} else {
    Report-Pass "all $($configKeys.Count) keys in packaging/release/config.json are named in docs/config.md"
}

$noStatus = @()
$stepCount = 0
foreach ($readme in @('adapters/tevi/README.md', 'adapters/pseudoregalia/README.md',
                      'adapters/emulator/pokemon/emerald/README.md', 'adapters/emulator/pokemon/crystal/README.md')) {
    $inStory = $false
    $step = $null
    $text = ''
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root $readme)) + @('## end')) {
        if ($line -match '^## ') {
            if ($step -and $text -notmatch '\*\*Status:\*\*') { $noStatus += "${readme}: step $step" }
            $step = $null
            $inStory = ($line -eq '## How this adapter was built')
            continue
        }
        if (-not $inStory) { continue }
        if ($line -match '^(\d+)\. ') {
            if ($step -and $text -notmatch '\*\*Status:\*\*') { $noStatus += "${readme}: step $step" }
            $step = $Matches[1]; $text = $line; $stepCount++
        } elseif ($step) { $text += "`n$line" }
    }
}
if ($stepCount -eq 0) { Report-Fail "no build steps found under '## How this adapter was built' -- the reader is broken" }
Report-Ratchet 'adapter build steps with no **Status:** line' $noStatus.Count $floorStepNoStatus `
    'end each build step with **Status:** <state> (date)' $noStatus

$contentsBad = @()
foreach ($md in @(& git ls-files -- '*.md')) {
    $mdText = [System.IO.File]::ReadAllText((Join-Path $root $md))
    if ($mdText -notmatch '(?m)^## Contents\s*$') { continue }
    $prose = [regex]::Replace($mdText, '(?ms)^```.*?^```', '')
    $wanted = @([regex]::Matches($prose, '(?m)^## (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'Contents' })
    $block = ($prose -split '(?m)^## Contents\s*$', 2)[1]
    $block = ($block -split '(?m)^## ', 2)[0]
    $listed = @([regex]::Matches($block, '(?m)^\s*(?:[-*]|\d+\.) \[(.+?)\]\(#[^)]*\)') | ForEach-Object { $_.Groups[1].Value })
    if (($wanted -join "`n") -ne ($listed -join "`n")) { $contentsBad += $md }
}
if ($contentsBad.Count -gt 0) {
    Report-Fail "Contents list(s) that differ from their file's '## ' headings, in order: $($contentsBad -join ', ')"
} else {
    Report-Pass "every '## Contents' list matches its file's headings"
}

# Refuses a date, "the user", a review ID or a .md pointer in a code comment.
Section "Comment traces in code"

# The comment text of each line: whole-line and trailing comments, and block comments, by the file's syntax.
function Get-CommentTexts([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    $marker = switch ($ext) {
        { $_ -in '.go', '.cs', '.cpp', '.hpp', '.h', '.c' } { '//' }
        '.lua' { '--' }
        { $_ -in '.ps1', '.py', '.sh', '.yml' } { '#' }
        '.bat' { 'REM' }
    }
    $open = switch ($ext) { { $_ -in '.go', '.cs', '.cpp', '.hpp', '.h', '.c' } { '/*' } '.lua' { '--[[' } '.ps1' { '<#' } default { $null } }
    $close = switch ($ext) { { $_ -in '.go', '.cs', '.cpp', '.hpp', '.h', '.c' } { '*/' } '.lua' { ']]' } '.ps1' { '#>' } default { $null } }
    $inBlock = $false
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root $path))) {
        if ($inBlock) { $line; if ($line.Contains($close)) { $inBlock = $false }; continue }
        $t = $line.Trim()
        if ($open -and $t.StartsWith($open)) { $line; if (-not $t.Substring($open.Length).Contains($close)) { $inBlock = $true }; continue }
        if ($ext -eq '.bat') { if ($t -match '^(@?rem\b|::)') { $line }; continue }
        # Strings are blanked first, so a marker inside one is not a comment.
        $code = [regex]::Replace($line, '"(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)*''', '""')
        if ($marker -eq '#') {
            $m = [regex]::Match($code, '(^|\s)#(?!!)')
            if ($m.Success) { $code.Substring($m.Index) }
        } else {
            $i = $code.IndexOf($marker)
            if ($i -ge 0) { $code.Substring($i) }
        }
    }
}
$traceFiles = @(& git ls-files -- '*.go' '*.cs' '*.cpp' '*.hpp' '*.h' '*.c' '*.lua' '*.ps1' '*.py' '*.sh' '*.bat' '.github/workflows/*.yml' '.githooks/*')
$traces = @{ Date = @(); User = @(); Review = @(); Md = @() }
foreach ($f in $traceFiles) {
    # A hook has no extension: it is shell, and only its whole-line comments are read.
    $texts = if ($f -like '.githooks/*' -and -not [System.IO.Path]::GetExtension($f)) {
        @([System.IO.File]::ReadAllLines((Join-Path $root $f)) | Where-Object { $_ -match '^\s*#(?!!)' })
    } else { @(Get-CommentTexts $f) }
    foreach ($c in $texts) {
        # A Go directive is code the toolchain reads (//go:embed names its file), not a comment to trim.
        if ($c -match '^\s*//go:') { continue }
        if ($c -match '\b20\d\d-\d\d-\d\d\b') { $traces.Date += $f }
        if ($c -match "(?i)\bthe user\b|\buser's\b|\(user\b") { $traces.User += $f }
        if ($c -match '\b(PM|X\d)-\d+\b|\breview [A-Z]\d+\b|\bpass-\d') { $traces.Review += $f }
        if ($c -match '(?i)\b[\w./-]*\w\.md\b') { $traces.Md += $f }
    }
}
$traceFix = 'move it to agent_docs/ (a game fact to that adapter''s MEASURED.md) and keep one line of why, per CLAUDE.md'
$traceKinds = [ordered]@{ Date = 'a date'; User = 'the user'; Review = 'a review ID'; Md = 'a .md pointer' }
$traceBad = 0
foreach ($k in $traceKinds.Keys) {
    if ($traces[$k].Count -gt 0) {
        $traceBad++
        Report-Fail "$($traces[$k].Count) code comment line(s) carrying $($traceKinds[$k]) -- $traceFix"
        $traces[$k] | Group-Object | Select-Object -First 10 | ForEach-Object { Write-Host "          $($_.Name) ($($_.Count))" }
    }
}
if ($traceBad -eq 0) { Report-Pass "no code comment carries a date, the user, a review ID or a .md pointer ($($traceFiles.Count) files)" }

# Refuses a workflow action not pinned to a full commit SHA with a version comment, or a workflow whose top-level
# permissions are not {}.
Section "Workflows pinned (ratchet)"
$floorUnpinnedUses = 0
$floorWorkflowPermissions = 0
$unpinned = @()
$openPermissions = @()
foreach ($wf in @(& git ls-files -- '.github/workflows/*.yml')) {
    $lines = [System.IO.File]::ReadAllLines((Join-Path $root $wf))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^\s*(?:-\s*)?uses:\s*(\S+)(.*)$')
        if ($m.Success -and $m.Groups[1].Value -notmatch '^\./') {
            # Groups, not $Matches: each -match below would overwrite $Matches.
            $ref = $m.Groups[1].Value
            if ($ref -notmatch '@[0-9a-f]{40}$' -or $m.Groups[2].Value -notmatch '#\s*v\d') { $unpinned += "${wf}:$($i + 1): $ref" }
        }
    }
    if (-not ($lines -contains 'permissions: {}')) { $openPermissions += $wf }
}
Report-Ratchet 'workflow actions not pinned to a SHA with a # vN comment' $unpinned.Count $floorUnpinnedUses `
    'pin it: uses: owner/repo@<40-hex SHA> # vN' $unpinned
Report-Ratchet 'workflows whose top-level permissions are not {}' $openPermissions.Count $floorWorkflowPermissions `
    'set top-level permissions: {} and grant each job only what it needs' $openPermissions

# Refuses a floating NuGet version, a project without a restore lockfile or deterministic build, a missing SDK pin,
# or a go.mod without an exact toolchain.
Section "Dependencies pinned (ratchet)"
$floorUnpinnedDeps = 0
$unpinnedDeps = @()
foreach ($proj in @(& git ls-files -- '*.csproj')) {
    $xml = [System.IO.File]::ReadAllText((Join-Path $root $proj))
    foreach ($m in [regex]::Matches($xml, '<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"')) {
        if ($m.Groups[2].Value -notmatch '^\d+(\.\d+)*$') { $unpinnedDeps += "${proj}: $($m.Groups[1].Value) $($m.Groups[2].Value) is not an exact version" }
    }
    if ($xml -notmatch '<RestorePackagesWithLockFile>\s*true') { $unpinnedDeps += "${proj}: no RestorePackagesWithLockFile" }
    $lock = Join-Path (Split-Path $proj) 'packages.lock.json'
    if (-not (@(& git ls-files -- ($lock -replace '\\', '/')).Count)) { $unpinnedDeps += "${proj}: no tracked packages.lock.json beside it" }
    if ($xml -notmatch '<Deterministic>\s*true') { $unpinnedDeps += "${proj}: no <Deterministic>true" }
}
if (-not (@(& git ls-files -- 'global.json').Count)) { $unpinnedDeps += 'global.json: no tracked SDK pin at the root' }
foreach ($mod in @(& git ls-files -- 'go.mod' '*/go.mod')) {
    if (-not ([System.IO.File]::ReadAllText((Join-Path $root $mod)) -match '(?m)^toolchain go\d+\.\d+\.\d+\s*$')) { $unpinnedDeps += "${mod}: no exact toolchain line" }
}
Report-Ratchet 'unpinned or non-reproducible build inputs' $unpinnedDeps.Count $floorUnpinnedDeps `
    'pin it exactly (a version, a lockfile, global.json, a toolchain line)' $unpinnedDeps

# Warns about MeshGhost processes or dev-script launcher shells left running from an earlier run.
Section "Leftover scaffolding"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

# meshghost-server is the relay's shipped name: one program, two names.
$strays = Get-Process -Name "meshghost", "meshghost-relay", "meshghost-server", "meshghost-fakeadapter", "meshghost-netsim" -ErrorAction SilentlyContinue
if ($strays) {
    Report-Warn "MeshGhost processes are already running -- close them before a clean test:"
    $strays | ForEach-Object { Write-Host "          $($_.ProcessName) (pid $($_.Id))" }
} else {
    Report-Pass "no MeshGhost processes left running"
}

# Every run-*.bat ends at a pause, so its cmd.exe outlives the binary and holds no port.
$shells = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*dev-scripts*" }
if ($shells) {
    Report-Warn "launcher shells left over from an earlier run (their binaries are already gone) -- close them:"
    $shells | ForEach-Object { Write-Host "          cmd.exe (pid $($_.ProcessId)) $($_.CommandLine.Trim())" }
} else {
    Report-Pass "no leftover dev-script launcher shells"
}
}

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "PREFLIGHT FAILED: $($script:failures) problem(s), $($script:warnings) warning(s)." -ForegroundColor Red
    if ($TreeOnly) {
        Write-Host "These are all answerable from the tree alone -- no game, no build, no install needed."
    } else {
        Write-Host "Fix these before asking anyone to launch a game -- a live cycle costs them a real playthrough."
    }
    exit 1
}
if ($TreeOnly) {
    # Not "safe to hand over a game": this mode skipped the checks on what a game would load.
    Write-Host "Tree checks clean ($($script:warnings) warning(s)). Run without -TreeOnly before handing over a game." -ForegroundColor Green
} else {
    Write-Host "Preflight clean ($($script:warnings) warning(s)). Safe to hand over a game." -ForegroundColor Green
}
exit 0
