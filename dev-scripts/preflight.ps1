# MeshGhost -- run this BEFORE handing the user a game to test.
#
# Every check here exists because the thing it checks actually went wrong and cost a live test.
# A live cycle costs the user a real game launch and a replayed save, so the cheapest possible
# minute is the one spent proving the artifacts are the ones we think they are.
#
# Read-only: it inspects and reports, and changes nothing. It never builds, never deploys and
# never commits, so it is safe to run at any point.
#
# Exit code 0 = everything fresh. 1 = at least one FAIL. Warnings do not fail the run.
#
# Optional environment variables, for the deployed-copy check. They are env vars rather than
# literals on purpose: install paths are machine-specific and this is a public repo.
#   MESHGHOST_TEVI_DLL        full path to the deployed MeshGhostTevi.dll
#   MESHGHOST_TEVI_DLL_ALT    a second TEVI install (the dual-instance one, if you have it)
#   MESHGHOST_PSEUDO_DLL      full path to the deployed MeshGhostPseudo main.dll

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$script:failures = 0
$script:warnings = 0

function Report-Pass($msg) { Write-Host "  PASS  $msg" }
function Report-Fail($msg) { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:failures++ }
function Report-Warn($msg) { Write-Host "  WARN  $msg" -ForegroundColor Yellow; $script:warnings++ }
function Section($name)    { Write-Host ""; Write-Host "== $name ==" }

# Tracked markdown, listed WITHOUT a git pathspec glob. `git ls-files '*.md'` cannot be trusted
# here: PowerShell resolves `git` to the devkitPro/MSYS2 copy on this machine, whose runtime
# glob-expands `*.md` against the top-level directory BEFORE git sees it -- so it returned the 2
# root-level files instead of all 70, and both doc checks below "passed" while a deliberately
# broken link sat in the tree. (`*.lua` escapes this only by luck: nothing matches at top level,
# so the pattern reaches git intact.) Fourth appearance of the wrong-install-on-PATH trap --
# CLAUDE.md and pitfalls.md carry the other three.
$trackedMd = @(& git ls-files | Where-Object { $_ -like '*.md' })
if ($trackedMd.Count -lt 40) {
    Report-Fail "only $($trackedMd.Count) tracked .md file(s) found -- the listing is broken, so the doc checks below would pass vacuously. Not a clean result."
}


# ---------------------------------------------------------------------------
Section "Go source hygiene"

$unformatted = & gofmt -l (& git ls-files '*.go')
if ($unformatted) {
    Report-Fail "not gofmt-clean: $($unformatted -join ', ')  -- run: gofmt -w <file>"
} else {
    Report-Pass "every tracked .go file is gofmt-clean"
}

# ---------------------------------------------------------------------------
Section "Public-repo leak check"

# IS THE HOOK EVEN ON? The scan below finds a leak that is already in the working tree; the hook
# is what stops one entering HISTORY, where it cannot be taken back. Hooks are not carried by
# `git clone`, so a fresh clone has this switched off and nothing says so -- which is exactly the
# state in which the 2026-08-23 leak was committed.
$hooksPath = (& git config core.hooksPath) 2>$null
if ($hooksPath -eq ".githooks") {
    Report-Pass "core.hooksPath is .githooks -- the pre-commit leak check is armed"
} else {
    Report-Fail "core.hooksPath is not set to .githooks, so commits are NOT being checked for machine-specific paths -- run: git config core.hooksPath .githooks"
}


# Both slash directions. A backslash-only check ran clean for days while a forward-slash path sat
# leaking in master -- see agent_docs/pitfalls.md, "A verification rule that reports clean while
# the thing it checks is broken".
# This script excludes ITSELF, for the same reason CLAUDE.md and pitfalls.md are excluded: the
# patterns are written out literally on this line, so git grep finds them here every time. Without
# the exclusion the check reported FAIL on a perfectly clean tree -- a checker that always fails is
# as useless as one that never can, and gets ignored just as fast.
$leaks = & git grep -inIF -e 'C:\Users' -e 'C:/Users' -e '/home/' -e '/Users/' -- . ':!CLAUDE.md' ':!agent_docs/environment.md' ':!agent_docs/pitfalls.md' ':!dev-scripts/preflight.ps1' ':!.githooks/' ':!.github/workflows/'
if ($LASTEXITCODE -eq 0 -and $leaks) {
    Report-Fail "machine-identifying path in a tracked file:"
    $leaks | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no username or home-directory path in tracked files"
}

# ---------------------------------------------------------------------------
Section "Invented durations"

# CLAUDE.md says "cite dates, not durations", and this repo's first commit is 2026-08-11 -- so any
# phrase claiming months or years about our own work is false on arrival and gets worse with age.
#
# WHY THIS IS A GREP AND NOT A RULE. The rule existed and was broken four times: three on
# 2026-08-16, and again on 2026-08-21 with "for months" written about a rule two days old. The last
# one is the reason this check exists, because of HOW it happened -- the duration was not a claim
# anyone believed, it was an intensifier that filled a slot in a sentence wanting emphasis, and was
# never examined. A rule against writing durations only catches someone who notices they are
# writing one. A grep does not need anyone to notice.
#
# The same shape as the leak check above, and excluded the same way: this file and CLAUDE.md both
# spell the patterns out, so they would match themselves forever.
#
# If a hit is genuinely about an EXTERNAL project's history ("rgbds has shipped for years"), rewrite
# it with a date or a version rather than silencing the check -- a date is better writing there too.
# Four such hits were reworded when this check was added; none of them lost anything by it.
#
# TWO GATES, because the units divide cleanly and only one of them can be judged by grep alone.
# The first is repo-wide and covers what is IMPOSSIBLE here; the second covers everything else but
# only on lines being added. `pitfalls.md` is no longer excluded from the first: it was, and that is
# where 2026-08-23's "for days" landed unchallenged.
#
# verified.md AND the per-adapter VERIFIED.md files (split out of it 2026-08-25) are excluded
# because they are APPEND-ONLY: correcting a phrase inside an entry there is a
# rewrite of the record, which is the one thing that file forbids. It holds one known bad duration
# ("long-standing 1-2 image density gap", 2026-08-21, now in adapters/pseudoregalia/VERIFIED.md)
# and one legitimate external reference. A
# future entry that invents a duration will therefore NOT be caught here -- so watch it by hand.
# `licensing.md` and `access-models.md` are excluded for the opposite reason: both are ABOUT the
# outside world (licences, emulator projects, hardware), so external dates are their subject matter.
$durations = & git grep -inIE -e 'for (a |an |the last |the past )?(hour|day|week|month|year|decade)s?' -e '(hour|day|week|month|year|decade)s? (ago|later|earlier|old|behind)' -e 'long-?standing' -e 'long time' -e 'decades' -e 'over the years' -- . ':!CLAUDE.md' ':!dev-scripts/preflight.ps1' ':!agent_docs/verified.md' ':!adapters/**/VERIFIED.md'
if ($LASTEXITCODE -eq 0 -and $durations) {
    Report-Fail "vague duration in a tracked file -- cite a date, or a measured figure with a number:"
    $durations | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no vague durations in tracked files"
}

# ---------------------------------------------------------------------------
Section "Reading budgets"

# RULE 0's 300-line cap on CLAUDE.md holds BECAUSE this script checks it. Every other file the
# project mandates as required reading had no such backstop, and the inventory on 2026-08-25 was
# ~1,701 lines before an ordinary session and ~14,500-18,500 before a new adapter's first file.
# Prose alone does not hold a budget -- status.md went from 50 to 628 lines with a cap nominally
# in force.
#
# A file declares its own cap in its header, so adding a mandated file does not mean editing this
# script:   <!-- line-cap: N -->
#
# (Get-Content).Count, NOT Measure-Object -Line: the latter counts only NON-EMPTY lines, so it
# reported 288 for a 300-line file and would have passed a CLAUDE.md sitting 12+ lines over the
# cap. The rules are stated in terms of `wc -l`, and this must measure the same thing they do.
$capped = 0
$withinCap = 0
foreach ($md in $trackedMd) {
    $head = @(Get-Content -LiteralPath $md -TotalCount 15)
    $decl = $head | Select-String -Pattern '<!--\s*line-cap:\s*(\d+)' | Select-Object -First 1
    if (-not $decl) { continue }
    $cap = [int]$decl.Matches[0].Groups[1].Value
    $n = @(Get-Content -LiteralPath $md).Count
    $capped++
    if ($n -gt $cap) {
        $over = $n - $cap
        Report-Fail "$md is $n lines, $over over its declared $cap-line cap. Something must come out first."
    } else {
        $withinCap++
    }
}
if ($capped -eq 0) {
    Report-Fail "no file declared a line-cap -- the budget check found nothing to enforce, which is not a clean result"
} elseif ($withinCap -eq $capped) {
    Report-Pass "$capped file(s) within their declared reading budgets"
} else {
    Report-Pass "$withinCap of $capped capped file(s) within budget"
}

# ---------------------------------------------------------------------------
Section "Root binaries vs Go source"

# dev-scripts/*.bat launch these exact named binaries. go build/vet/test do NOT refresh them, so a
# bug repro can run against binaries a full day stale -- found live 2026-08-14.
$newestGo = Get-ChildItem -Recurse -Filter *.go |
    Where-Object {
        $_.FullName -notmatch '\\build\\_deps\\' -and
        $_.FullName -notmatch '\\RE-UE4SS\\' -and
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

# ---------------------------------------------------------------------------
Section "Committed mod DLLs vs their source"

# Reproduces .github/workflows/release.yml's staleness gate locally. CI cannot build these (a
# proprietary game DLL and a private UE4SS dependency), which is exactly why they are committed --
# and exactly why they go stale silently. Both were stale on 2026-08-18.
function Check-BuiltFrom($label, $builtFromPath, $sourceDir) {
    if (-not (Test-Path $builtFromPath)) { Report-Warn "$label -- no built-from.txt at $builtFromPath"; return }
    $stale = @()
    foreach ($line in Get-Content $builtFromPath) {
        if ($line -match '^\s*#' -or $line -notmatch '^(?<file>[^:]+):\s*(?<hash>[0-9a-fA-F]{64})\s*$') { continue }
        $file = $Matches['file']; $recorded = $Matches['hash'].ToLower()
        # Skipped here and checked separately below: it sits one directory up from the sources,
        # so Join-Path would look for it in the wrong place and report a fresh DLL as stale.
        if ($file -eq 'CMakeLists.txt') { continue }
        $src = Join-Path $sourceDir $file
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

# CMakeLists.txt lives one level up from Mod\src, so it is checked separately.
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

# ---------------------------------------------------------------------------
Section "Lua parses"

# Every adapter and probe is Lua, and nothing else in this repo checks that it COMPILES.
# BizHawk embeds Lua 5.4, so a syntax error does not fail loudly -- the script simply never
# loads, which from the outside looks like "the ghost did not appear" and costs a live cycle
# to diagnose. Two tracked probes were found on 2026-08-25 that had NEVER parsed.
#
# luac -p compiles without running, so nothing here touches a game. It also catches Lua's
# 200-local-per-chunk ceiling, which is a compile-time error and has bitten this project
# three times, each time discovered by an adapter silently failing to load in a live session.
#
# Absolute path on purpose: `lua` is not on PATH, and CLAUDE.md's rule about PATH shadowing
# (cmake, cmd, gcc) applies to interpreters most of all. Install with:
#   C:/msys64/usr/bin/pacman.exe -S mingw-w64-x86_64-lua
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

# ---------------------------------------------------------------------------
Section "LF-pinned sources"

# .gitattributes pins these to eol=lf because the release gate hashes them on a Windows runner.
# A scripted edit that writes CRLF makes the gate fail claiming the DLL is stale when it is fresh,
# and rebuilding "to fix it" re-bakes the same wrong hash. Found live twice.
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

# ---------------------------------------------------------------------------
Section "Deployed copies in the live game installs"

# The repo's staging copy being fresh does NOT mean the game is running it. A full cleanup pass
# once rebuilt both DLLs, verified the in-repo gates, and never copied them out -- which would have
# had a loopback test across three games silently exercising pre-cleanup code.
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

# ---------------------------------------------------------------------------
Section "Markdown link integrity"


# Every relative .md link must resolve. Four broken ones sat in the tree unnoticed until
# 2026-08-25: the staged-context pass copied rule text between files without adjusting the link
# depth, and a fifth pointed at adapters/oribf/, a folder deleted on 2026-08-25.
# A broken relative link fails silently in every markdown viewer, so nothing surfaces it.
$badLinks = @()
foreach ($md in $trackedMd) {
    $dir = Split-Path -Parent $md
    if (-not $dir) { $dir = "." }
    foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $md), '\]\(([^)#\s]+\.md)(#[^)]*)?\)')) {
        $target = $m.Groups[1].Value
        if ($target -match '^[a-z]+://') { continue }
        if (-not (Test-Path (Join-Path $dir $target))) { $badLinks += "$md -> $target" }
    }
}
if ($badLinks.Count -gt 0) {
    Report-Fail "$($badLinks.Count) broken relative markdown link(s):"
    $badLinks | Sort-Object -Unique | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "every relative markdown link resolves"
}

# ---------------------------------------------------------------------------
Section "Canonical source for multiply-stated rules"

# A rule stated in many files drifts, and prose asking people not to let it drift does not stop
# it: on 2026-08-25 the bandage register said "seven after-the-fact tells" in two files and
# "eight" in three more, while ALL of them listed seven. The canonical list has eight. Nobody
# noticed because nothing checked.
#
# The rule enforced here: a file may STATE one of these rules only if it is the rule's home, or
# it links to the home. A copy that links cannot silently drift free of its source -- the reader
# always has one hop to the version that is maintained.
$canon = @(
    @{ Name = "a flag flip is not a revert"
       Pattern = 'flag flip is not a revert'
       Home = 'agent_docs/pitfalls.md'
       LinkTo = 'pitfalls.md' }
    @{ Name = "the eight after-the-fact bandage tells"
       Pattern = 'tells that only show up later'
       Home = 'adapters/_template/BANDAGES.md'
       LinkTo = '_template/BANDAGES.md' }
    @{ Name = "the 2026-08-17 module move disclaimer"
       Pattern = 'predate the 2026-08-17 module move'
       Home = 'agent_docs/README.md'
       HomePattern = 'internal/protocol\|transport'
       LinkTo = 'README.md' }
)
foreach ($rule in $canon) {
    $homePat = if ($rule.HomePattern) { $rule.HomePattern } else { $rule.Pattern }
    $homeText = if (Test-Path $rule.Home) { Get-Content -Raw -LiteralPath $rule.Home } else { "" }
    if ($homeText -notmatch $homePat) {
        Report-Fail "'$($rule.Name)' is registered as living in $($rule.Home), but that file does not state it"
        continue
    }
# The pointer must sit NEAR the statement, not merely somewhere in the same file. A whole-file
# match is satisfied by an unrelated mention -- status.md cites pitfalls.md in its own link
# footer, which would vouch for a drifted copy of the rule pasted anywhere above it. This is the
# same defect as licensing.md's unanchored provenance grep, found in this very check while
# negative-testing it on 2026-08-25. Write the check, then try to fool it.
    $strays = @()
    foreach ($md in $trackedMd) {
        if ($md -eq $rule.Home) { continue }
        if ($md -eq 'agent_docs/ideas.md') { continue }   # the restructuring record QUOTES these rules
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

# ---------------------------------------------------------------------------
Section "_template back-port freshness"

# CLAUDE.md requires _template/ never to lag a shipped adapter: a rule, file or trap added to a
# real adapter is back-ported in the SAME pass. That was prose only, and _template/documentation.md
# sat untouched from 2026-08-18 through the whole Crystal phase.
#
# Commit dates, not file mtimes -- mtime is when the file was checked out, which says nothing.
# A WARN, not a FAIL: an adapter register gaining one game-specific entry is not a template gap.
# It is here to make the gap visible, which is the part that was missing.
function Git-LastCommit($path) {
    if (-not (Test-Path $path)) { return $null }
    $ts = & git log -1 --format=%ct -- $path
    if ($ts) { return [int]$ts } else { return $null }
}
$adapters = @(
    "adapters/bizhawk/pokemon/crystal", "adapters/bizhawk/pokemon/emerald",
    "adapters/pseudoregalia", "adapters/tevi"
)
$lagging = @()
foreach ($name in @("README.md", "FLAGS.md", "BANDAGES.md", "documentation.md")) {
    $tplTime = Git-LastCommit "adapters/_template/$name"
    if (-not $tplTime) { continue }
    foreach ($a in $adapters) {
        $aTime = Git-LastCommit "$a/$name"
        # One day of slack: the rule is "back-port in the SAME pass", so a sub-day gap is almost
        # always this session's own commits, and a check that cries wolf every session is a check
        # nobody reads -- which is exactly how the pitfalls.md taxonomy stopped being maintained.
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

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
Section "pitfalls.md index coverage"

# pitfalls.md carries two structures on purpose -- host/subsystem groups for part of it, and
# lesson-shaped chronological entries for the rest -- with one index over both. An index survives
# where the half-finished taxonomy did not, because adding an entry costs ONE line, and because a
# check can verify it. Nothing can mechanically verify "is this filed under the right theme",
# which is why the taxonomy was not finished (decided 2026-08-25).
$pit = "agent_docs/pitfalls.md"
$pitLines = @(Get-Content -LiteralPath $pit)
$idxStart = ($pitLines | Select-String -Pattern '^## Index — every entry in this file$').LineNumber
if (-not $idxStart) {
    Report-Fail "$pit has no index section -- every heading is supposed to be listed in one"
} else {
    # the index runs to the first heading after it that is not one of its own ### sub-groups
    $idxEnd = $pitLines.Count
    for ($i = $idxStart; $i -lt $pitLines.Count; $i++) {
        if ($pitLines[$i] -match '^## ' ) { $idxEnd = $i; break }
    }
    $indexed = @{}
    for ($i = $idxStart; $i -lt $idxEnd; $i++) {
        if ($pitLines[$i] -match '^- (.+)$') { $indexed[$Matches[1].Trim()] = $true }
    }
    $missing = @()
    for ($i = $idxEnd; $i -lt $pitLines.Count; $i++) {
        $l = $pitLines[$i]
        # Entry-level only: a '### ' under a '## ' entry is part of that entry, not an entry of
        # its own, and indexing those would make the index longer than useful. The themed '### '
        # sections are listed in the index too, but are not required by this check.
        if ($l -notmatch '^## ') { continue }
        $title = ($l -replace '^## ', '').Trim()
        if (-not $indexed.ContainsKey($title)) { $missing += "line $($i+1): $title" }
    }
    if ($missing.Count -gt 0) {
        Report-Fail "$($missing.Count) pitfalls.md heading(s) missing from its index -- add one line each:"
        $missing | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every pitfalls.md heading ($($indexed.Count) indexed) appears in its index"
    }
}

# ---------------------------------------------------------------------------
Section "Leftover scaffolding"

# Leaving a relay alive is how a later run silently binds the wrong port.
$strays = Get-Process -Name "meshghost", "meshghost-relay", "meshghost-fakeadapter", "meshghost-netsim" -ErrorAction SilentlyContinue
if ($strays) {
    Report-Warn "MeshGhost processes are already running -- close them before a clean test:"
    $strays | ForEach-Object { Write-Host "          $($_.ProcessName) (pid $($_.Id))" }
} else {
    Report-Pass "no MeshGhost processes left running"
}

# ---------------------------------------------------------------------------
Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "PREFLIGHT FAILED: $($script:failures) problem(s), $($script:warnings) warning(s)." -ForegroundColor Red
    Write-Host "Fix these before asking anyone to launch a game -- a live cycle costs them a real playthrough."
    exit 1
}
Write-Host "Preflight clean ($($script:warnings) warning(s)). Safe to hand over a game." -ForegroundColor Green
exit 0
