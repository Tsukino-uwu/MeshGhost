[CmdletBinding()]
param(
    # Run ONLY the checks that a bare checkout can answer, skipping everything that needs a
    # working copy (built binaries, deployed DLLs, installed toolchains, running processes).
    # This is what .github/workflows/docs.yml runs on every push touching a .md file, because
    # until 2026-08-27 nothing in CI ran any of the doc gates at all -- they held only when
    # somebody remembered this script, and commit b77b2cf shipped _template/probes.md four lines
    # over its own declared cap, trimmed back two commits later, which is what that looks like.
    [switch]$TreeOnly
)

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
function Report-Skip($msg) { Write-Host "  SKIP  $msg" -ForegroundColor DarkGray }

# Both grep gates below are three-way, and used not to be. `git grep` exits 0 for "matches found",
# 1 for "none", and >1 for "I could not run" -- and `if ($LASTEXITCODE -eq 0 -and $hits)` sent that
# third case straight to the PASS branch. A gate that reports clean when it could not run is the
# "check that lists no files passes every time" failure, twice over, and it is why this lives in one
# function rather than being written out at each call site.
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

# A file git tracks but the working tree does not have kills every loop below, because
# $ErrorActionPreference = "Stop" turns Get-Content's "path not found" into a terminating error --
# so the script dies mid-run with a raw .NET stack and no section summary, and deleting one doc
# made preflight LESS informative than leaving it broken. Found 2026-08-25 while testing that the
# adapter-file-set check could actually fail; it crashed in three separate loops in turn.
# Reported once here and filtered out, rather than guarded at each of the three call sites --
# one home, like every other rule in this repo.
$missingTracked = @($trackedMd | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingTracked.Count -gt 0) {
    Report-Fail "$($missingTracked.Count) file(s) tracked by git but missing from the working tree:"
    $missingTracked | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    $trackedMd = @($trackedMd | Where-Object { Test-Path -LiteralPath $_ })
}


# ---------------------------------------------------------------------------
Section "Go source hygiene"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

# TRACKED AND UNTRACKED BOTH, since 2026-08-27. `git ls-files` lists only what git already
# knows about, so a brand-new .go file -- which is exactly what adding a test looks like -- was
# invisible to this check until it was staged. It happened the same day this comment was written:
# a new test file was written, this check was run and reported clean, and the file went into the
# commit unformatted. CI's own gofmt step caught nothing either, for the same reason it caught
# nothing here: it runs after the add. Same shape as "a check that lists no files passes every
# time", one step earlier in the process.
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

# ---------------------------------------------------------------------------
Section "Public-repo leak check"

# IS THE HOOK EVEN ON? The scan below finds a leak that is already in the working tree; the hook
# is what stops one entering HISTORY, where it cannot be taken back. Hooks are not carried by
# `git clone`, so a fresh clone has this switched off and nothing says so -- which is exactly the
# state in which the 2026-08-23 leak was committed.
# A WORKING-COPY question, not a tree one, so -TreeOnly skips it: hooks are per-clone git config,
# a CI runner has none and never commits, and failing there would say nothing about the code. The
# leak GREP below is the tree half and runs everywhere. Split 2026-08-27, on the first run of
# .github/workflows/docs.yml -- which failed on exactly this and nothing else, which is the gate
# doing its job on the person who wrote it.
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


# Both slash directions. A backslash-only check ran clean for days while a forward-slash path sat
# leaking in master -- see agent_docs/pitfalls.md, "A verification rule that reports clean while
# the thing it checks is broken".
# This script excludes ITSELF, for the same reason CLAUDE.md and pitfalls.md are excluded: the
# patterns are written out literally on this line, so git grep finds them here every time. Without
# the exclusion the check reported FAIL on a perfectly clean tree -- a checker that always fails is
# as useless as one that never can, and gets ignored just as fast.
$leaks = & git grep -inIF -e 'C:\Users' -e 'C:/Users' -e '/home/' -e '/Users/' -- . ':!CLAUDE.md' ':!agent_docs/environment.md' ':!agent_docs/pitfalls.md' ':!agent_docs/pitfalls/' ':!dev-scripts/preflight.ps1' ':!.githooks/' ':!.github/workflows/'
Report-GrepGate $LASTEXITCODE $leaks "machine-identifying path in a tracked file:" `
    "no username or home-directory path in tracked files"

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
$durations = & git grep -inIE -e 'for (a |an |the last |the past )?(hour|day|week|month|year|decade)s?\b' -e '(hour|day|week|month|year|decade)s? (ago|later|earlier|old|behind)\b' -e 'long-?standing' -e 'long time' -e '\bdecades\b' -e 'over the years' -- . ':!CLAUDE.md' ':!dev-scripts/preflight.ps1' ':!agent_docs/verified.md' ':!adapters/**/VERIFIED.md'
Report-GrepGate $LASTEXITCODE $durations `
    "vague duration in a tracked file -- cite a date, or a measured figure with a number:" `
    "no vague durations in tracked files"

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
# SINCE 2026-08-25 A FILE MUST DECLARE ONE OR THE OTHER, and silence is a FAIL. Checking only the
# files that happened to declare a cap made an unbudgeted file invisible to this check, which is
# how ~21,000 lines across the nine largest documents came to have no backstop at all while the
# 15 that did sat at 92-97% full. "It has no cap" and "nobody gave it one" looked identical.
#
#   <!-- line-cap: N -->     bounded content an AGENT loads: rules, reference, a guide, an index
#   <!-- line-cap: none -- reason -->    a record, register or queue -- OR a document for people
#
# The exemption is not a loophole, it is the other half of the rule. claude-md-cap.md's argument
# is "cap the thing that actually grows" -- and for a LOG the thing that grows is the number of
# entries, which is real signal about the project. Capping VERIFIED.md would mean deleting
# evidence in order to add evidence; capping a BANDAGES.md would hide the exact smell it exists to
# show. A record is bounded by SPLITTING it, the way the ADR log was, never by refusing entries.
#
# THIRD CATEGORY, added 2026-08-27 on the user's call: a cap is a budget on the AGENT's instruction
# budget, so a file no agent loads has none to spend. Each game's README.md and documentation.md,
# docs/, packaging/ and dev-scripts/ READMEs are written for people and are exempt for that reason,
# not because they are records. Everything an agent auto-loads or is told to read end to end stays
# capped. claude-md-cap.md's fourth case is the argument; this comment is only the pointer.
$capped = 0
$withinCap = 0
$exempt = 0
$undeclared = @()
foreach ($md in $trackedMd) {
    # agent_docs/adr/ is exempt as a directory rather than 39 near-identical marker lines: one ADR
    # is one decision, immutable once written, and its own index check above already governs it.
    if ($md -like 'agent_docs/adr/*') { $exempt++; continue }

    $head = @(Get-Content -LiteralPath $md -TotalCount 15)
    $decl = $head | Select-String -Pattern '<!--\s*line-cap:\s*(\d+)' | Select-Object -First 1
    $none = $head | Select-String -Pattern '<!--\s*line-cap:\s*none' | Select-Object -First 1
    if ($none) { $exempt++; continue }
    if (-not $decl) { $undeclared += $md; continue }

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
if ($undeclared.Count -gt 0) {
    Report-Fail "$($undeclared.Count) tracked .md file(s) declare neither a line-cap nor an exemption -- an unbudgeted file is invisible to this check:"
    $undeclared | Select-Object -First 15 | ForEach-Object { Write-Host "          $_" }
}
if ($capped -eq 0) {
    Report-Fail "no file declared a line-cap -- the budget check found nothing to enforce, which is not a clean result"
} elseif ($withinCap -eq $capped -and $undeclared.Count -eq 0) {
    Report-Pass "$capped file(s) within their declared reading budgets, $exempt declared exempt"
} else {
    Report-Pass "$withinCap of $capped capped file(s) within budget, $exempt declared exempt"
}

# ---------------------------------------------------------------------------
Section "Root binaries vs Go source"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

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
}

# ---------------------------------------------------------------------------
Section "Probe scripts: blind reflection walks"

# **The gate behind the rule, added after the rule alone failed to hold (2026-08-29).**
#
# A probe crashed a live game three times in one day, twice by calling a UFunction on everything
# FindAllOf returned, then once more by walking ForEachProperty and stringifying every property it
# named -- an object-valued one hands back a pointer, and touching it dereferences whatever that
# was. A Lua pcall does not catch an access violation in native code, so the probe cannot defend
# itself and neither can the reviewer who reads it afterwards. The user's call after the third:
# make it so new probes cannot do this again.
#
# So this refuses the enumerators themselves in any probe script. Reading a NAMED property is fine
# and is what every probe here actually needs; enumerating what an object happens to HOLD is what
# is banned. Grow a written list between runs instead -- adapters/pseudoregalia/CLAUDE.md.
$blindWalkers = @('ForEachProperty', 'ForEachFunction', 'ForEachFunctionInChain', 'ForEachPropertyInChain')
$probeScripts = @(Get-ChildItem -Path 'adapters' -Recurse -Filter '*.lua' -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -like '*probe*' })
# **Armed is the line, not merely present.** UE4SS loads a probe folder because it carries an
# enabled.txt, so a disarmed probe cannot reach a running game whatever it contains -- and a
# finished probe that keeps its enabled.txt is a probe that logs through somebody else's test.
# An armed offender FAILS; a disarmed one is named as a warning so nobody arms it by accident.
$offenders = @()
$disarmed = @()
foreach ($script in $probeScripts) {
    $armed = Test-Path (Join-Path $script.Directory.Parent.FullName 'enabled.txt')
    foreach ($walker in $blindWalkers) {
        # Commented lines are how the withdrawn stage documents itself, and a warning about a
        # comment would train everyone to ignore this check.
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
if ($disarmed.Count -gt 0) {
    Report-Warn ("disarmed probe(s) carry a blind reflection walk -- do not arm one without cutting it: " + ($disarmed -join '; '))
}

# ---------------------------------------------------------------------------
Section "Committed mod DLLs vs their source"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

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
}

# ---------------------------------------------------------------------------
Section "No reproduced expression in documentation.md"

# Each adapter's documentation.md records HOW THE GAME WORKS, under a header rule of its own:
# facts may be explained, expression may never be reproduced -- no source text, no disassembly,
# no data tables copied wholesale. CLAUDE.md's licensing rule is where that comes from.
#
# NOTHING WAS CHECKING IT, and three violations reached master before a person read the file:
# a sixteen-entry jump-arc table, a sprite template's assembly line, and a script's command
# sequence, all in Crystal's, all added 2026-08-26 while writing up work that had just been
# confirmed. Every one of them is a case where the fact and the source's own FORM look identical
# -- writing out a table you also measured feels like recording a measurement.
#
# So this greps for the shape rather than the content: a fenced block inside documentation.md.
# A fence is not automatically a violation -- probe OUTPUT we produced ourselves is a measurement
# and is allowed, which is why this WARNS and never fails. It exists to put a human's eye back on
# the one construct all three violations shared.
$docFiles = @(& git ls-files '*documentation.md')
$fenced = @()
foreach ($f in $docFiles) {
    if (-not (Test-Path $f)) { continue }
    $n = @(Select-String -Path $f -Pattern '^```' -AllMatches).Count
    if ($n -gt 0) { $fenced += "$f ($([int]($n / 2)) block(s))" }
}
if ($fenced.Count -eq 0) {
    Report-Pass "no fenced blocks in any adapter's documentation.md ($($docFiles.Count) checked)"
} else {
    Report-Warn ("fenced block(s) in documentation.md -- confirm each is OUR measurement, " +
        "not reproduced expression: " + ($fenced -join ", "))
}

# ---------------------------------------------------------------------------
Section "Lua parses"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

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
}

# ---------------------------------------------------------------------------
Section "LF-pinned sources"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

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
}

# ---------------------------------------------------------------------------
Section "Deployed copies in the live game installs"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

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
}

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
       Home = 'agent_docs/pitfalls/method.md'
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
    @{ Name = "status.md's two-lines-per-item rule"
       Pattern = 'two lines per item'
       Home = 'agent_docs/claude-md-cap.md'
       LinkTo = 'claude-md-cap.md' }
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
        if ($md -eq 'agent_docs/doc-history.md') { continue }  # the restructuring record QUOTES these rules
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
    "adapters/emulator/pokemon/crystal", "adapters/emulator/pokemon/emerald",
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
Section "pitfalls index coverage"

# pitfalls.md carries two structures on purpose -- host/subsystem groups for part of it, and
# lesson-shaped chronological entries for the rest -- with one index over both. An index survives
# where the half-finished taxonomy did not, because adding an entry costs ONE line, and because a
# check can verify it. Nothing can mechanically verify "is this filed under the right theme",
# which is why the taxonomy was not finished (decided 2026-08-25).
#
# SPLIT 2026-08-25: the index stayed in pitfalls.md and the entries moved to pitfalls/, so reading
# the lessons costs 200 lines instead of 5,180. The index did not move, because ~17 files link to
# agent_docs/pitfalls.md and every one of them still resolves. Same shape as architecture.md and
# its adr/ directory. This check therefore scans the DIRECTORY and looks the headings up in the
# index file -- an entry added to a body file without an index line is one nobody will find.
$pit = "agent_docs/pitfalls.md"
$pitBodies = @(Get-ChildItem -LiteralPath "agent_docs/pitfalls" -Filter '*.md' | Sort-Object Name)
$pitLines = @(Get-Content -LiteralPath $pit)
$idxStart = ($pitLines | Select-String -Pattern '^## Index — every entry in this file$').LineNumber
if (-not $idxStart) {
    Report-Fail "$pit has no index section -- every heading is supposed to be listed in one"
} elseif ($pitBodies.Count -eq 0) {
    Report-Fail "agent_docs/pitfalls/ holds no .md files -- the entries are supposed to live there"
} else {
    $indexed = @{}
    for ($i = $idxStart; $i -lt $pitLines.Count; $i++) {
        if ($pitLines[$i] -match '^- (.+)$') {
            # Index lines may be a bare title or a [title](link); take the title either way.
            $entry = $Matches[1].Trim()
            if ($entry -match '^\[([^\]]+)\]\(') { $entry = $Matches[1].Trim() }
            $indexed[$entry] = $true
        }
    }
    # WIDENED 2026-08-27: pitfalls.md's own headings are checked too, and an ENTRY there is a FAIL
    # rather than something to index. This check scanned only the directory, so 10 full entries that
    # had been appended straight into pitfalls.md were governed by nothing -- none was in its own
    # index, while the file's header claims "this file IS the index" and README.md promises preflight
    # fails an unindexed entry. Both were true of pitfalls/ and neither of pitfalls.md.
    $missing = @()
    $strays = @($pitLines | Select-String -Pattern '^## ' | Where-Object {
        $_.Line -ne '## Index — every entry in this file'
    })
    if ($strays.Count -gt 0) {
        Report-Fail "$($strays.Count) entry heading(s) in $pit itself -- it is the INDEX; entries go at the end of pitfalls/by-lesson.md:"
        $strays | Select-Object -First 12 | ForEach-Object { Write-Host "          $($_.LineNumber): $($_.Line)" }
    }
    foreach ($b in $pitBodies) {
        $lines = @(Get-Content -LiteralPath $b.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            # Entry-level only: a '### ' under a '## ' entry is part of that entry, not an entry of
            # its own, and indexing those would make the index longer than useful.
            if ($l -notmatch '^## ') { continue }
            $title = ($l -replace '^## ', '').Trim()
            if (-not $indexed.ContainsKey($title)) { $missing += "$($b.Name):$($i+1): $title" }
        }
    }
    if ($missing.Count -gt 0) {
        Report-Fail "$($missing.Count) pitfalls heading(s) missing from $pit -- add one line each:"
        $missing | Select-Object -First 12 | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every pitfalls heading across $($pitBodies.Count) file(s) ($($indexed.Count) indexed) appears in $pit"
    }
}

# ---------------------------------------------------------------------------
Section "VERIFIED index coverage"

# The verified records are append-only and only grow: 3,654 and 3,685 lines for Pseudoregalia and
# Emerald as of 2026-08-25. They cannot be capped -- capping a record means deleting evidence in
# order to add evidence -- and splitting them by period does not work yet, because every entry in
# every one of them is dated 2026-08 (the repo began 2026-08-11). So the control is an index:
# reading it costs ~150 lines instead of ~3,700, and adding an entry costs one line.
#
# Same shape as the pitfalls check above, and the same reasoning: nothing can mechanically verify
# that an entry is filed under the right theme, but anything can verify that it is listed.
#
# Entries sit at BOTH ## and ### -- the earliest are ### under "Confirmed facts", later ones are ##
# -- and both are indexed. The levels are historical and deliberately not normalised, because
# rewriting an entry's heading is a rewrite of an append-only record.
# -notlike '*UNVERIFIED.md' is load-bearing, and PowerShell's case-INSENSITIVE -like is why: both
# "UNVERIFIED.md" and "agent_docs/unverified.md" match '*VERIFIED.md', so the first version of this
# check demanded an index on all three queue files. A queue is the opposite case -- it DRAINS, its
# size is how much the user has not confirmed yet, and indexing a list that is meant to reach zero
# is work for nothing.
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
            if ($lines[$i] -match '^## ') { break }          # the index ends at the next ## section
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

# ---------------------------------------------------------------------------
Section "Adapter file set"

# _template/README.md's folder-convention table has mandated a file set per adapter since it was
# written, and nothing checked it. That is a rule enforced by whoever remembers it, which is the
# same as unenforced: TEVI and Pseudoregalia had no UNVERIFIED.md and nobody noticed, and
# Pseudoregalia's three probe directories went unindexed from the day they were created.
#
# An adapter is any directory holding a documentation.md (the one file every adapter must have
# from the moment its folder exists), excluding _template itself.
$mandated = @('README.md', 'documentation.md', 'BANDAGES.md', 'FLAGS.md', 'VERIFIED.md', 'UNVERIFIED.md')
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

    # UNVERIFIED.md IS mandated, since 2026-08-27 and on the user's call. It used to be exempt
    # "because a queue with nothing pending should not exist", and TEVI and Pseudoregalia had none
    # for that reason -- while status.md carried unwatched items for both. The exemption was
    # protecting exactly the two adapters that needed the file, and the premise behind it was
    # never true. A queue is created with the adapter now.
    #
    # Probe indexes ARE checked, because an unindexed probe folder hides writing tools -- see
    # _template/probes-README.md. A probe directory is one whose name starts with "probe"; it
    # needs an index once it holds more than two scripts, and that index may be its own README.md
    # or a PROBES.md at the adapter root (Pseudoregalia's case: UE4SS forces one mod directory per
    # probe, so there is no single probes/ folder to index from the inside).
    $unindexed = @()
    foreach ($d in $adapterDirs) {
        $probeScripts = @{}
        foreach ($f in @(& git ls-files -- "$d")) {
            # Extension test FIRST, and $pd captured immediately: every -match writes $Matches, so
            # testing the extension after the directory match overwrites the captured group with
            # the file extension. It did, and the check reported ".../lua (46 scripts)".
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
            if ($rootIndex -or (Test-Path -LiteralPath "$d/$pd/README.md")) { continue }
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
        Report-Pass "all $($adapterDirs.Count) adapters carry the mandated file set, and every probe folder is indexed"
    }
}

# ---------------------------------------------------------------------------
Section "ADR index coverage"

# The decision log was split out of architecture.md on 2026-08-25 -- 2,332 of its 2,501 lines --
# into one file per ADR under agent_docs/adr/. The index stayed in architecture.md, because every
# citation in this repo says "the <date> ADR in architecture.md" and there are many; moving the
# index would have broken all of them at once for no gain.
#
# That makes the index the single point of failure: an ADR file nobody links is an ADR nobody
# finds, and it fails silently -- exactly the shape of the pitfalls index problem above. Two
# things are checked: every file in adr/ is linked from the index, and no sequence number is used
# twice (numbers are how a new ADR picks its next value, so a duplicate quietly overwrites the
# ordering).
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

        # Sequence numbers: the NNNN- prefix. prior-art-celestenet.md carries none by design --
        # it is research, not a decision -- so files without a numeric prefix are skipped here
        # rather than failed. They still have to be linked, which the check above covers.
        $seen = @{}
        $dupes = @()
        foreach ($f in $adrFiles) {
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

# ---------------------------------------------------------------------------
Section "Bridge constants agree across the four adapters"

# The bridge client is implemented FOUR times, in THREE languages that share no
# code -- Lua (Emerald, Crystal), C++ (Pseudoregalia), C# (TEVI). Until now the
# only thing keeping their constants in step was a comment: BridgeClient.hpp says
# in as many words that its reconnect interval "matches the shape of TEVI's own
# BridgeClient.cs ReconnectInterval (2s), a different language but the same
# problem". A comment cannot fail a build, and four hand-maintained copies of one
# number is the same shape as the four VERIFIED.md preambles that drifted.
#
# Compared in REAL UNITS, not literals, because each language states them its own
# way: 600 frames at 60fps, 10000ms, and "10s" are the same cooldown. That is also
# why this cannot be a plain grep for a shared string.
#
# A value found nowhere is reported rather than silently passing -- a renamed
# constant would otherwise make its adapter drop out of the comparison and leave
# the remaining ones agreeing with each other.
#
# TEVI JOINED THIS COMPARISON 2026-08-27, when it grew a port walk -- see the note that used to sit
# below this check, which said it should be deleted on exactly that day. Its two constants live in
# two different files (the base port is a BepInEx config default in Plugin.cs, the walk count is in
# BridgeClient.cs), so an adapter may name several sources and they are concatenated.
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
    $text = ($bridgeSources[$name] | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join "`n"

    # C# spells these BridgePortCount / DefaultBridgePort; the others use the SCREAMING form.
    if ($text -match 'BRIDGE_BASE_PORT\s*(?:=|\s)\s*(\d+)') { $basePorts[$name] = [int]$Matches[1] }
    elseif ($text -match 'DefaultBridgePort\s*=\s*(\d+)') { $basePorts[$name] = [int]$Matches[1] }
    else { $bridgeProblems += "$name -- no bridge base port found (renamed?)" }

    if ($text -match 'BRIDGE_PORT_COUNT\s*(?:=|\s)\s*(\d+)') { $portCounts[$name] = [int]$Matches[1] }
    elseif ($text -match 'BridgePortCount\s*=\s*(\d+)') { $portCounts[$name] = [int]$Matches[1] }
    else { $bridgeProblems += "$name -- no bridge port-walk count found (renamed?)" }

    # Frames at 60fps for the emulator adapters, milliseconds for C++.
    if ($text -match 'BUSY_PORT_COOLDOWN_FRAMES\s*=\s*(\d+)') {
        $cooldownSeconds[$name] = [int]$Matches[1] / 60
    } elseif ($text -match 'BUSY_PORT_COOLDOWN\s*\{\s*(\d+)\s*\}') {
        $cooldownSeconds[$name] = [int]$Matches[1] / 1000
    } elseif ($text -match 'BusyPortCooldown\s*=\s*TimeSpan\.FromSeconds\((\d+)\)') {
        # C# states it in seconds outright, which is the whole reason this compares real units.
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

# All four adapters are in this comparison as of 2026-08-27. Until then TEVI was deliberately
# absent -- fixed port from BepInEx config, no walk -- stated in the pass message rather than
# silently skipped, with a note saying this carve-out was what to delete when TEVI grew one. It did.
if ($bridgeProblems.Count -gt 0) {
    Report-Fail "the four bridge clients have drifted apart:"
    $bridgeProblems | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "bridge constants agree across all $($basePorts.Count) adapters (port 7778, 8-port walk, 10s cooldown)"
}

# ---------------------------------------------------------------------------
Section "Phase index coverage"

# Phase files were the ONE required-reading class with no index and no check. ADRs, pitfalls
# entries and VERIFIED entries all have both; CLAUDE.md routes evidence into phases/phaseN.md by
# name, and agent_docs/README.md links the phases/ DIRECTORY but no file inside it. So a phase
# file could be added and referenced from nowhere -- including the 1,904-line phase7.md and the
# in-progress phase9.md, neither of which was reachable from the doc index. Index added
# 2026-08-25 with this check, on the same reasoning as the three above it.
$phaseDir = "agent_docs/phases"
$phaseIndex = "agent_docs/phases/README.md"
if (-not (Test-Path -LiteralPath $phaseIndex)) {
    Report-Fail "$phaseIndex does not exist -- the phase index is supposed to live there"
} else {
    $phaseText = Get-Content -LiteralPath $phaseIndex -Raw
    $phaseFiles = @(Get-ChildItem -LiteralPath $phaseDir -Filter '*.md' |
        Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name)
    $unlinkedPhases = @()
    foreach ($f in $phaseFiles) {
        if ($phaseText -notmatch [regex]::Escape("($($f.Name))")) { $unlinkedPhases += $f.Name }
    }
    if ($unlinkedPhases.Count -gt 0) {
        Report-Fail "$($unlinkedPhases.Count) phase file(s) not linked from $phaseIndex -- add one row each:"
        $unlinkedPhases | ForEach-Object { Write-Host "          $_" }
    } else {
        Report-Pass "every phase file ($($phaseFiles.Count)) is linked from the phase index"
    }
}

# ---------------------------------------------------------------------------
Section "Bridge message coverage in the adapter template"

# _template/PROTOCOL.md is what a new adapter is BUILT FROM, and it had never heard of
# session_policy or remote_name -- so every adapter written from it handled four bridge messages
# and silently ignored two. That is the whole reason ghost_collision does nothing in any game and
# nametags reach one adapter of four (agent_docs/plans.md, "Settings: defined once, honoured
# everywhere"). The standing rule is that _template/ may never lag, but nothing CHECKED it: a
# message could be added to bridge/bridge.go and the template never told, which is exactly what
# happened. This is the mechanical half of that rule -- it cannot tell whether an explanation went
# stale, only that a message exists which the template has never heard of. Added 2026-08-30.
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
    # DELIMITED match only -- backticked or quoted. A bare substring would let ordinary prose
    # satisfy this: "world" occurs 16 times in that file and only once as the message name, so a
    # loose test would report a permanently green check for a message nobody had documented.
    $tick  = [char]0x60   # backtick and double quote built from char codes rather than escaped:
    $quote = [char]0x22   # both are punishing to quote correctly inside a PowerShell string.
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

# ---------------------------------------------------------------------------
Section "dev-scripts README coverage"

# Same failure shape one folder over: dev-scripts/README.md documents the launchers, and six
# tracked scripts were missing from it on 2026-08-25 (bizhawk-hitch-meter.lua, the two Crystal
# launchers, the pseudoregalia udp/quic launchers, run-relay-loopback-shipped.bat). An undocumented
# launcher is one nobody reaches for, which is how a rig gets rebuilt by hand instead.
#
# Only tracked .bat/.ps1/.lua/.sh in dev-scripts/ itself are checked -- not subfolders, and not
# the per-machine *.local.bat, which are gitignored and therefore never tracked anyway.
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

# ---------------------------------------------------------------------------
Section "RemoteGhost pointer fields are cleared at release (Pseudoregalia)"

# Added 2026-09-01, after the FOURTH member of one bug family: a raw pointer field added to
# RemoteGhost that no release path cleared (the thrown prop, the VFX map, the projectile actor,
# then the nametag trio -- the last one shipped as an intermittent use-after-free crash that
# consumed two sessions; pitfalls/by-lesson.md, "The reset-to-save crash"). The release-path
# comment predicting exactly this existed the whole time, which is the point: a comment cannot
# fail a build, and this family has proven it needs a check that can. Every `RC::Unreal::T*`
# field declared in the RemoteGhost struct must be MENTIONED in BOTH release_all_ghosts and
# release_ghost -- mention is the proxy (assignment styles differ between the two), and a field
# that is deliberately safe to keep still earns its line as a comment naming it there.
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
                    # Word-boundary match, not substring: "nametag_plate" must not be satisfied
                    # by "nametag_plate_mid" -- the first negative test of this check passed when
                    # it should have failed for exactly that reason.
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

Section "GitHub Action versions agree across workflows"

# WHY THIS EXISTS. On 2026-08-17 every workflow was moved off the Node 20 runtime, because GitHub
# removes it from the runners "later in the fall of 2026" -- a warning with a deadline. On
# 2026-08-25 a NEW workflow (lua.yml) was added carrying actions/checkout@v4, and the deprecation
# warning came back on 2026-08-26. Nothing had regressed; a new file was simply written with the
# old pattern, and no check existed to notice.
#
# The rule is SELF-MAINTAINING on purpose: no version is hardcoded here, because a hardcoded one
# goes stale and this file would then be the thing that is wrong. Instead, every workflow must use
# the same major version of a given action as every other workflow. Bump one and this demands the
# rest -- which is exactly the failure mode above, caught at the commit rather than at the run.
$wfDir = Join-Path $root ".github\workflows"
if (Test-Path $wfDir) {
    $uses = @{}
    foreach ($wf in Get-ChildItem -LiteralPath $wfDir -Filter *.yml) {
        foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $wf.FullName),
                'uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(v[0-9]+)')) {
            $name, $ver = $m.Groups[1].Value, $m.Groups[2].Value
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

# ---------------------------------------------------------------------------
Section "Leftover scaffolding"
if ($TreeOnly) { Report-Skip "needs a working copy, not just the tree" } else {

# Leaving a relay alive is how a later run silently binds the wrong port.
# meshghost-server is the RELAY'S SHIPPED NAME -- one program, two names, per packaging/README.md.
# It was missing here until 2026-08-28, so a relay left running from a staged release (which is
# exactly what a release dry run leaves behind) reported "no MeshGhost processes left running".
# The check that exists to stop a stale relay silently binding the port was blind to the only name
# a player ever sees.
$strays = Get-Process -Name "meshghost", "meshghost-relay", "meshghost-server", "meshghost-fakeadapter", "meshghost-netsim" -ErrorAction SilentlyContinue
if ($strays) {
    Report-Warn "MeshGhost processes are already running -- close them before a clean test:"
    $strays | ForEach-Object { Write-Host "          $($_.ProcessName) (pid $($_.Id))" }
} else {
    Report-Pass "no MeshGhost processes left running"
}

# The launcher SHELL outlives the binary it started. Every run-*.bat ends at a `pause`, so killing
# meshghost.exe/meshghost-relay.exe leaves its cmd.exe sitting there forever -- holding no port, so
# the check above passes and reports the tree clean. Found 2026-08-25: this said "no MeshGhost
# processes left running" while two shells from an hour-old session were still open, and eight more
# accumulated over one four-adapter test pass. Harmless individually; the reason to catch them is
# that they are indistinguishable from a rig someone is still USING, so the next session cannot tell
# what it is allowed to kill.
$shells = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*dev-scripts*" }
if ($shells) {
    Report-Warn "launcher shells left over from an earlier run (their binaries are already gone) -- close them:"
    $shells | ForEach-Object { Write-Host "          cmd.exe (pid $($_.ProcessId)) $($_.CommandLine.Trim())" }
} else {
    Report-Pass "no leftover dev-script launcher shells"
}
}

# ---------------------------------------------------------------------------
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
    # Deliberately does NOT say "safe to hand over a game": this mode skipped every check that
    # could tell you whether the artifacts a game would load are the ones we think they are.
    Write-Host "Tree checks clean ($($script:warnings) warning(s)). Run without -TreeOnly before handing over a game." -ForegroundColor Green
} else {
    Write-Host "Preflight clean ($($script:warnings) warning(s)). Safe to hand over a game." -ForegroundColor Green
}
exit 0
