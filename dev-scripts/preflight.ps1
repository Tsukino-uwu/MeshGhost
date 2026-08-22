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

# Both slash directions. A backslash-only check ran clean for days while a forward-slash path sat
# leaking in master -- see agent_docs/pitfalls.md, "A verification rule that reports clean while
# the thing it checks is broken".
# This script excludes ITSELF, for the same reason CLAUDE.md and pitfalls.md are excluded: the
# patterns are written out literally on this line, so git grep finds them here every time. Without
# the exclusion the check reported FAIL on a perfectly clean tree -- a checker that always fails is
# as useless as one that never can, and gets ignored just as fast.
$leaks = & git grep -inIF -e 'C:\Users' -e 'C:/Users' -e '/home/' -- . ':!CLAUDE.md' ':!agent_docs/environment.md' ':!agent_docs/pitfalls.md' ':!dev-scripts/preflight.ps1'
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
# verified.md is excluded because it is APPEND-ONLY: correcting a phrase inside an entry there is a
# rewrite of the record, which is the one thing that file forbids. It holds one known bad duration
# ("long-standing 1-2 image density gap", 2026-08-21) and one legitimate external reference. A
# future entry that invents a duration will therefore NOT be caught here -- so watch it by hand.
# `licensing.md` and `access-models.md` are excluded for the opposite reason: both are ABOUT the
# outside world (licences, emulator projects, hardware), so external dates are their subject matter.
$durations = & git grep -inIE -e 'for (a |an |the last |the past )?(hour|day|week|month|year|decade)s?' -e '(hour|day|week|month|year|decade)s? (ago|later|earlier|old|behind)' -e 'long-?standing' -e 'long time' -e 'decades' -e 'over the years' -- . ':!CLAUDE.md' ':!dev-scripts/preflight.ps1' ':!agent_docs/verified.md'
if ($LASTEXITCODE -eq 0 -and $durations) {
    Report-Fail "vague duration in a tracked file -- cite a date, or a measured figure with a number:"
    $durations | ForEach-Object { Write-Host "          $_" }
} else {
    Report-Pass "no vague durations in tracked files"
}

# ---------------------------------------------------------------------------
Section "CLAUDE.md line cap"

# (Get-Content).Count, NOT Measure-Object -Line: the latter counts only NON-EMPTY lines, so it
# reported 288 for a 300-line file and would have passed a CLAUDE.md sitting 12+ lines over the
# cap. RULE 0 is stated in terms of `wc -l`, and this must measure the same thing it does.
$claudeLines = @(Get-Content CLAUDE.md).Count
if ($claudeLines -gt 300) {
    Report-Fail "CLAUDE.md is $claudeLines lines, over its 300-line cap (RULE 0). Something must come out."
} else {
    Report-Pass "CLAUDE.md is $claudeLines/300 lines"
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
