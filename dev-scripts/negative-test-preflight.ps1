[CmdletBinding()]
param(
    # Run only the fixtures whose name matches this regex. No argument runs all of them.
    [string]$Only,
    # Leave the scratch worktree in place afterwards, to look at what a fixture actually planted.
    [switch]$KeepWorktree,
    # Outside the clone on purpose: a worktree INSIDE it would be walked by preflight's own
    # filesystem scans (the probe-script check enumerates adapters\ with Get-ChildItem, not git),
    # so every probe would be counted twice and the tree under test would not be the tree.
    [string]$ScratchRoot = (Join-Path $env:TEMP "meshghost-negtest")
)

# MeshGhost -- prove that preflight's gates can FAIL.
#
# WHY THIS EXISTS. On 2026-09-11 the leak check's new IP scan reported PASS on a tree with a
# planted public address in it, through three independent bugs: a POSIX grep that rejected the
# lookarounds outright (exit 128), a PowerShell brace mangling that turned the pattern into a
# revision, and an exit-code test that read "I could not run" as "nothing found". Every one of
# them was invisible in the only direction anyone ever ran the check -- against a clean tree,
# where the right answer and the broken answer are the same word.
#
# THE RULE THAT CAME OUT OF IT: a gate never seen to fail is indistinguishable from a gate that
# cannot fail. The corollary is that "we negative-tested it once" is not durable either, because
# all three of those bugs entered a check that had been correct earlier. So this is a standing
# harness rather than an audit: it plants a real violation, runs preflight, and asserts the
# section NAMES it.
#
# HOW IT WORKS. A detached git worktree at HEAD is the tree under test -- never your working copy,
# which may hold uncommitted work and which a planted leak must never touch. The preflight script
# copied into it is YOUR WORKING COPY'S, so this tests the script you are about to commit against
# a known-clean tree. One fixture per run, reset in between, so a FAIL is attributable to exactly
# one planted violation.
#
# Read-only with respect to the clone: it writes only under $ScratchRoot and removes the worktree
# when it is done.
#
# Exit code 0 = every fixture's gate saw its violation. 1 = at least one gate did not.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Explicit, never bare `powershell` off PATH -- CLAUDE.md's rule, and the reason preflight has a
# section for it. $PSHOME is whichever edition is running this script, so this resolves to 5.1's
# powershell.exe locally and to pwsh.exe under a CI job that uses `shell: pwsh` -- the same two
# editions docs.yml and a local run already put preflight through.
$psExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = Join-Path $PSHOME "pwsh.exe" }
if (-not (Test-Path -LiteralPath $psExe)) { throw "no PowerShell executable in `$PSHOME ($PSHOME)" }

$script:harnessFailures = 0

function Report-Pass($msg) { Write-Host "  PASS  $msg" }
function Report-Fail($msg) { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:harnessFailures++ }
function Report-Warn($msg) { Write-Host "  WARN  $msg" -ForegroundColor Yellow }
function Report-Info($msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Plant helpers.
#
# EVERY ONE OF THEM READS THE FILE BACK. A plant that silently did nothing is the exact failure
# this harness exists to catch, one level up: the fixture would report "the gate did not see it"
# when there was nothing to see, and the fix would be applied to an innocent gate. CLAUDE.md's
# rule for scripted edits -- grep the result, never trust the write -- applies hardest to the
# script whose whole job is distrusting a clean result.

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Plant-TextLine($wt, $relPath, $line) {
    $full = Join-Path $wt $relPath
    if (-not (Test-Path -LiteralPath $full)) { throw "fixture target is missing: $relPath" }
    $existing = [System.IO.File]::ReadAllText($full)
    $nl = if ($existing -match "`r`n") { "`r`n" } else { "`n" }
    [System.IO.File]::WriteAllText($full, $existing + $nl + $line + $nl, $utf8NoBom)
    $after = [System.IO.File]::ReadAllText($full)
    if (-not $after.Contains($line)) { throw "plant did not land in ${relPath}: $line" }
}

function Plant-FirstLine($wt, $relPath, $line) {
    $full = Join-Path $wt $relPath
    if (-not (Test-Path -LiteralPath $full)) { throw "fixture target is missing: $relPath" }
    $existing = [System.IO.File]::ReadAllText($full)
    [System.IO.File]::WriteAllText($full, $line + "`n" + $existing, $utf8NoBom)
    if (-not ([System.IO.File]::ReadAllText($full)).StartsWith($line)) { throw "plant did not land at the top of $relPath" }
}

function Plant-NewFile($wt, $relPath, $text) {
    $full = Join-Path $wt $relPath
    [System.IO.File]::WriteAllText($full, $text, $utf8NoBom)
    # git add, not add -N: the gates that matter here read `git ls-files`, and an intent-to-add
    # entry with no blob behind it is a needless difference from what a real commit would look like.
    & git -C $wt add -- $relPath | Out-Null
    $listed = @(& git -C $wt ls-files -- $relPath)
    if (-not $listed) { throw "plant was written but git does not track it: $relPath" }
}

function Plant-Bytes($wt, $relPath, [byte[]]$bytes) {
    $full = Join-Path $wt $relPath
    if (-not (Test-Path -LiteralPath $full)) { throw "fixture target is missing: $relPath" }
    $before = [System.IO.File]::ReadAllBytes($full)
    $after = New-Object byte[] ($before.Length + $bytes.Length)
    [Array]::Copy($before, 0, $after, 0, $before.Length)
    [Array]::Copy($bytes, 0, $after, $before.Length, $bytes.Length)
    [System.IO.File]::WriteAllBytes($full, $after)
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($full))
    $planted = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    if (-not $text.Contains($planted)) { throw "byte plant did not land in $relPath" }
}

# A tracked Lua probe script is the quietest place in the tree to plant a leak: the markdown gates
# (caps, one-line entries, link integrity, licensing, indexes) cannot see it, a `--` line cannot
# change what Lua parses to, and the blind-reflection check skips comments by design. So a fixture
# planted here trips the gate it is aimed at and nothing else, which is what makes an unexpected
# FAIL elsewhere meaningful rather than noise.
$luaTarget = 'adapters/pseudoregalia/probes/probe_ghost/Scripts/main.lua'

# ---------------------------------------------------------------------------
# The fixtures.
#
# Section names must match preflight's `Section "..."` text EXACTLY -- a typo here would look
# like a gate that stopped reporting, so the harness checks the name exists in the baseline run
# and refuses to guess.
$fixtures = @(
    @{  Name = 'leak-home-path'
        Section = 'Public-repo leak check'
        Expect = 'FAIL'
        Why = 'a Windows home-directory path in a tracked file'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: C:\Users\someone\dev\thing.lua' } },

    @{  Name = 'leak-home-path-forward-slash'
        Section = 'Public-repo leak check'
        Expect = 'FAIL'
        Why = 'the same path with forward slashes -- the direction that once sat leaking in master'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: C:/Users/someone/dev/thing.lua' } },

    @{  Name = 'leak-clone-path'
        Section = 'Public-repo leak check'
        Expect = 'FAIL'
        Why = 'a script hardcoding an absolute path to the clone (the zoom.ps1 case, 2026-09-07)'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: C:\dev\MeshGhost\dev-scripts\shots' } },

    @{  Name = 'leak-public-ip'
        Section = 'Public-repo leak check'
        Expect = 'FAIL'
        Why = 'a public IP address -- the case the 2026-09-11 scan reported PASS on'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: relay at 8.8.4.4' } },

    @{  Name = 'leak-private-ip'
        Section = 'Public-repo leak check'
        Expect = 'WARN'
        Why = 'an RFC1918 address -- the lower severity, which is a separate code path'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: peer at 192.168.44.7' } },

    @{  Name = 'leak-hostname'
        Section = 'Public-repo leak check'
        Expect = 'FAIL'
        Why = "someone's relay hostname, which carries a person's chosen name and resolves from anywhere"
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: relay at ghosts.notarealhost.xyz' } },

    @{  Name = 'binary-embedded-path'
        Section = 'Machine-identifying strings inside tracked BINARIES'
        Expect = 'FAIL'
        Why = 'a username embedded in a tracked binary, where -I made every text scanner blind'
        Plant = { param($wt) Plant-Bytes $wt 'adapters/emulator/pokemon/emerald/lib/x64/socket-windows-5-4.dll' ([System.Text.Encoding]::ASCII.GetBytes("`0C:\Users\someone\build\obj.pdb`0")) } },

    @{  Name = 'root-stray-file'
        Section = 'Stray files: nothing at the root but the allowlist, nothing marked local-only'
        Expect = 'FAIL'
        Why = 'a scratch note committed at the repo root'
        Plant = { param($wt) Plant-NewFile $wt 'HARNESS-SCRATCH.md' "# Scratch`n`nplanted by the negative-test harness.`n" } },

    @{  Name = 'local-only-header'
        Section = 'Stray files: nothing at the root but the allowlist, nothing marked local-only'
        Expect = 'FAIL'
        Why = "a tracked file whose own header says do not commit (the 2026-09-08 checklist)"
        Plant = { param($wt) Plant-FirstLine $wt $luaTarget '-- do not commit -- planted by the negative-test harness' } },

    @{  Name = 'licensing-uncited-repo'
        Section = 'Licensing gate'
        Expect = 'FAIL'
        Why = 'a third-party repo cited in a living doc and absent from licensing.md'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: see github.com/notarealowner/notarealrepo for the format.' } },

    @{  Name = 'stray-control-byte'
        Section = 'Stray control bytes from a mangled escape'
        Expect = 'FAIL'
        Why = 'a backslash escape eaten by a scripted edit, left in the file as its byte'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget ("-- planted by the negative-test harness: replay" + [char]7 + "ctive") } },

    @{  Name = 'scratch-probe-occupied'
        Section = 'The scratch probe slot is EMPTY'
        Expect = 'FAIL'
        Why = 'a probe left in the slot that loads at every launch under a name describing nothing'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/pseudoregalia/probes/probe_scratch/Scripts/main.lua' 'local planted = FindAllOf("Pawn")' } },

    @{  Name = 'broken-relative-link'
        Section = 'Markdown link integrity'
        Expect = 'FAIL'
        Why = 'a relative link to a file that does not exist -- broken silently in every viewer'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: [gone](../no-such-folder/absent.md).' } },

    @{  Name = 'github-relative-link'
        Section = 'Markdown link integrity'
        Expect = 'FAIL'
        Why = "a relative link in .github/, where GitHub's own surfaces drop the branch segment (2026-09-11, both CONTRIBUTING.md links)"
        Plant = { param($wt) Plant-TextLine $wt '.github/CONTRIBUTING.md' 'Planted by the negative-test harness: [the rules](../CLAUDE.md).' } },

    @{  Name = 'documentation-fence'
        Section = 'No reproduced expression in documentation.md'
        Expect = 'WARN'
        Why = 'a fenced block in a documentation.md -- the shape all three reproduced-expression violations shared'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/_template/documentation.md' "``````text`nplanted by the negative-test harness`n``````" } }
)

if ($Only) { $fixtures = @($fixtures | Where-Object { $_.Name -match $Only }) }
if ($fixtures.Count -eq 0) { Write-Host "no fixtures match -Only '$Only'" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Running preflight in the worktree, and reading its report back.

function Invoke-Preflight($wt) {
    $script = Join-Path $wt "dev-scripts\preflight.ps1"
    # ErrorActionPreference is relaxed for exactly this call. Windows PowerShell 5.1 wraps every
    # stderr line from a native command in an ErrorRecord, so under `Stop` a preflight run that
    # merely PRINTS a warning to stderr kills this harness mid-sweep -- and it did, on the third
    # fixture, taking the remaining ten with it. A gate that throws is a result this harness has
    # to REPORT, not one it may die of.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $script -TreeOnly 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    return @{ Lines = @($out | ForEach-Object { $_.ToString() }); Exit = $code }
}

# section name -> @('FAIL', 'WARN', 'PASS', ...) in the order reported.
function Read-Report($lines) {
    $report = [ordered]@{}
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^== (.+) ==$') { $current = $Matches[1]; if (-not $report.Contains($current)) { $report[$current] = @() }; continue }
        if ($null -eq $current) { continue }
        if ($line -match '^  (PASS|FAIL|WARN|SKIP)\s') { $report[$current] += $Matches[1] }
    }
    return $report
}

function Reset-Worktree($wt) {
    & git -C $wt reset --quiet HEAD -- . 2>&1 | Out-Null
    & git -C $wt checkout --quiet --force -- . 2>&1 | Out-Null
    & git -C $wt clean --quiet -fdx 2>&1 | Out-Null
    # The reset just restored the COMMITTED preflight. The point of this harness is the script in
    # the working copy -- the one about to be committed -- so it goes back in after every reset.
    Copy-Item -LiteralPath (Join-Path $root "dev-scripts\preflight.ps1") `
              -Destination (Join-Path $wt "dev-scripts\preflight.ps1") -Force
}

# ---------------------------------------------------------------------------
$wt = Join-Path $ScratchRoot "worktree"
if (Test-Path -LiteralPath $wt) {
    & git worktree remove --force $wt 2>&1 | Out-Null
    if (Test-Path -LiteralPath $wt) { Remove-Item -Recurse -Force -LiteralPath $wt }
}
New-Item -ItemType Directory -Force -Path $ScratchRoot | Out-Null

Write-Host "Negative-testing preflight's gates."
Write-Host "  tree under test:  a detached worktree at HEAD ($(& git rev-parse --short HEAD)), under $ScratchRoot"
Write-Host "  script under test: your working copy's dev-scripts\preflight.ps1"
Write-Host "  fixtures:         $($fixtures.Count)"

& git worktree add --detach --quiet $wt HEAD
if ($LASTEXITCODE -ne 0) { Write-Host "could not create the scratch worktree" -ForegroundColor Red; exit 1 }

try {
    Reset-Worktree $wt

    Write-Host ""
    Write-Host "== Baseline (nothing planted) =="
    $base = Invoke-Preflight $wt
    $baseReport = Read-Report $base.Lines
    if ($baseReport.Count -eq 0) {
        Report-Fail "preflight produced no sections at all -- it did not run, so every fixture below would be meaningless"
        Report-Info ($base.Lines | Select-Object -Last 10)
        exit 1
    }
    $baseFails = @($baseReport.Keys | Where-Object { $baseReport[$_] -contains 'FAIL' })
    if ($baseFails.Count -gt 0) {
        # Not fatal: a fixture whose own section is already failing is the only one this ruins,
        # and that is caught per fixture below. Everything else still tests cleanly.
        Report-Warn "HEAD is not preflight-clean -- section(s) already failing: $($baseFails -join '; ')"
    } else {
        Report-Pass "HEAD reports clean across $($baseReport.Count) section(s) -- a planted FAIL below is the fixture's doing"
    }

    Write-Host ""
    foreach ($f in $fixtures) {
        Write-Host "== $($f.Name) =="
        Report-Info "plants: $($f.Why)"

        if (-not $baseReport.Contains($f.Section)) {
            Report-Fail "no section named `"$($f.Section)`" in preflight's output -- the fixture is aimed at nothing (renamed section?)"
            continue
        }
        if ($baseReport[$f.Section] -contains $f.Expect) {
            Report-Fail "`"$($f.Section)`" already reports $($f.Expect) on a clean tree -- this fixture proves nothing until that is fixed"
            continue
        }

        Reset-Worktree $wt
        try { & $f.Plant $wt } catch {
            Report-Fail "the plant itself failed, so the gate was never tested: $($_.Exception.Message)"
            continue
        }

        $run = Invoke-Preflight $wt
        $report = Read-Report $run.Lines

        if (-not $report.Contains($f.Section)) {
            Report-Fail "preflight did not reach `"$($f.Section)`" with the fixture planted -- it errored out; this is not a clean result"
            Report-Info ($run.Lines | Select-Object -Last 6)
            continue
        }

        if ($report[$f.Section] -contains $f.Expect) {
            Report-Pass "`"$($f.Section)`" reported $($f.Expect) -- the gate sees it"
            if ($f.Expect -eq 'FAIL' -and $run.Exit -eq 0) {
                Report-Fail "...but preflight still exited 0, so nothing downstream (CI, release.ps1) would stop"
            }
        } else {
            Report-Fail "`"$($f.Section)`" did NOT report $($f.Expect) -- the gate is blind to this, and a clean run from it means nothing"
            $named = @($run.Lines | Where-Object { $_ -match '^  (FAIL|WARN)\s' })
            if ($named) { Report-Info "what it did report: $($named[0].Trim())" }
        }

        # Cross-talk: a fixture that trips OTHER sections is not wrong, but it makes the next
        # person read an unrelated FAIL as a real one. Worth naming, never worth failing on.
        $bled = @()
        foreach ($s in $report.Keys) {
            if ($s -eq $f.Section) { continue }
            foreach ($sev in @('FAIL', 'WARN')) {
                $now = @($report[$s] | Where-Object { $_ -eq $sev }).Count
                $then = if ($baseReport.Contains($s)) { @($baseReport[$s] | Where-Object { $_ -eq $sev }).Count } else { 0 }
                if ($now -gt $then) { $bled += "$s ($sev)" }
            }
        }
        if ($bled.Count -gt 0) { Report-Info "also tripped, by design or not: $($bled -join '; ')" }
    }

    # ---------------------------------------------------------------------------
    # The audit trail. A section with no fixture is not necessarily broken -- most of preflight's
    # gates were born printing FAIL on the violation that caused them, which is a negative test
    # that happened once, for free. This lists what has never been proved able to fail HERE, so
    # the gap is visible rather than assumed.
    if (-not $Only) {
        Write-Host ""
        Write-Host "== Coverage =="
        $covered = @($fixtures | ForEach-Object { $_.Section } | Sort-Object -Unique)
        $uncovered = @($baseReport.Keys | Where-Object { $covered -notcontains $_ })
        Report-Info "$($covered.Count) of $($baseReport.Count) -TreeOnly section(s) have a fixture here."
        Report-Info "No fixture yet (a gate whose ability to fail is assumed, not shown):"
        foreach ($s in $uncovered) { Report-Info "  - $s" }
    }
}
finally {
    if ($KeepWorktree) {
        Write-Host ""
        Write-Host "worktree left at $wt -- remove it with: git worktree remove --force `"$wt`""
    } else {
        & git worktree remove --force $wt 2>&1 | Out-Null
        if (Test-Path -LiteralPath $wt) { Remove-Item -Recurse -Force -LiteralPath $wt -ErrorAction SilentlyContinue }
        & git worktree prune 2>&1 | Out-Null
    }
}

Write-Host ""
if ($script:harnessFailures -gt 0) {
    Write-Host "NEGATIVE TEST FAILED: $($script:harnessFailures) gate(s) did not see a violation planted in front of them." -ForegroundColor Red
    Write-Host "A gate that cannot fail is worse than no gate: it is a gate everyone trusts."
    exit 1
}
Write-Host "Every fixture's gate reported the violation planted for it." -ForegroundColor Green
exit 0
