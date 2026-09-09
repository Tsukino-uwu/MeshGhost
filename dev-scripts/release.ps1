<#
.SYNOPSIS
Cuts a release the only way that has not failed: preflight, rebuild what it calls stale, preflight
again, push, wait for CI, then dispatch release.yml -- and refuse at the first red.

.DESCRIPTION
v1.2.6's first dispatch (2026-09-10) was refused by release.yml's staleness gate: the Pseudoregalia
DLL postdated a comment-only Plugin.cpp change. Preflight had ALREADY printed "Pseudoregalia DLL
is STALE" that evening and the dispatch was a bare `gh workflow run` that never asked -- and the
user said it was the second time a release had been cut into that gate.
The user, 2026-09-10: *"can we make it a preflight thing to rebuild dll things before a release
or something? this is the 2nd time this happened"*. This script is that: the dispatch is behind
the checks, so a release cannot be cut past a FAIL that was on screen.

ONE IMPLEMENTATION: nothing here re-derives a check. preflight.ps1 decides what is stale and what
is wrong; this script reads its verdicts, runs the repo's own build scripts for what it names,
and stops on anything else. A check added to preflight is a check on releases from then on.

.PARAMETER Version
The tag, e.g. v1.2.6. Refused if it already exists on origin.

.PARAMETER HighlightsFile
A file whose contents become the release body above the generated changelog. Passed to gh with
the `@` that makes gh read the file (without it gh sent the PATH as the body, 2026-09-07). Draft
it in chat with the user; their scope rule: relay/client-specific changes, or something big for
one game -- never QoL lines.

.PARAMETER Prerelease
Mark the release a pre-release.

.PARAMETER SkipCI
Dispatch without waiting for CI on HEAD. For a docs-only re-cut whose CI is already green; never
the default.

.EXAMPLE
& $env:ComSpec /c is not needed: this is PowerShell. From the repo root:
    powershell -NoProfile -ExecutionPolicy Bypass -File dev-scripts\release.ps1 -Version v1.2.6 -HighlightsFile C:\path\highlights.md
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$HighlightsFile = "",
    [switch]$Prerelease,
    [switch]$SkipCI
)

# Continue, not Stop: under Stop a native command's stderr line becomes a terminating error when
# captured (preflight and git both write there), and every exit code is checked by hand below.
$ErrorActionPreference = "Continue"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root

function Step($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor Cyan }
function Refuse($msg) { Write-Host ""; Write-Host "RELEASE REFUSED: $msg" -ForegroundColor Red; exit 1 }
function Cmd($file, $argList) {
    # Every .bat goes through ComSpec: a bare name on PATH has resolved to a devkitPro/MSYS2
    # shadow three times (CLAUDE.md, Method).
    & $env:ComSpec /c "`"$file`" $argList"
    if ($LASTEXITCODE -ne 0) { Refuse "$file exited $LASTEXITCODE" }
}

if ($Version -notmatch '^v\d+\.\d+\.\d+$') { Refuse "version must look like v1.2.6, got '$Version'" }
if ($HighlightsFile -ne "" -and -not (Test-Path -LiteralPath $HighlightsFile)) { Refuse "no highlights file at $HighlightsFile" }

Step "Repository state"
$branch = (& git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne "master") { Refuse "on branch '$branch'; releases are cut from master" }
# CONTENT, not status: on this machine `git status` lists files whose only difference is the line
# ending the .gitattributes would give them on the next touch (the first run of this script refused
# on nine such phantoms, every one with an empty `git diff`). A release cares that no edit is
# uncommitted, and `git diff --quiet HEAD` answers exactly that. Submodules are ignored because a
# dirty submodule checkout is not a change to this repository's content.
& git diff --quiet --ignore-submodules HEAD -- 2>$null
if ($LASTEXITCODE -ne 0) {
    & git --no-pager diff --ignore-submodules --stat HEAD -- 2>$null | ForEach-Object { Write-Host $_ }
    Refuse "tracked files have uncommitted changes -- commit or stash first"
}
& git fetch origin --tags --quiet
if ((& git ls-remote --tags origin "refs/tags/$Version")) { Refuse "tag $Version already exists on origin" }
$behind = (& git rev-list --count "HEAD..origin/master").Trim()
if ($behind -ne "0") { Refuse "HEAD is $behind commit(s) behind origin/master -- pull first" }
Write-Host "master, clean, $Version is free"

# Preflight decides. Its lines are the contract: "<Adapter> DLL is STALE" names a mod to rebuild,
# "<exe> is OLDER than" names a root binary to rebuild. Anything else that FAILs is a refusal.
function Run-Preflight {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "dev-scripts\preflight.ps1") 2>&1 | ForEach-Object { "$_" }
    return @{ lines = $out; ok = ($LASTEXITCODE -eq 0) }
}

Step "Preflight, first pass"
$p = Run-Preflight
$staleMods = @($p.lines | Where-Object { $_ -match '^\s*FAIL\s+(TEVI|Pseudoregalia) DLL is STALE' } | ForEach-Object { $Matches[1] })
$staleExes = @($p.lines | Where-Object { $_ -match '^\s*FAIL\s+(meshghost[\w-]*\.exe) is OLDER' } | ForEach-Object { $Matches[1] })
$otherFails = @($p.lines | Where-Object { $_ -match '^\s*FAIL' -and $_ -notmatch 'DLL is STALE' -and $_ -notmatch '\.exe is OLDER' })
if ($otherFails.Count -gt 0) {
    $otherFails | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Refuse "preflight FAILs that no rebuild fixes -- fix them and run this again"
}

if ($staleExes.Count -gt 0) {
    Step "Rebuilding stale root binaries: $($staleExes -join ', ')"
    foreach ($exe in $staleExes) {
        $pkg = "./cmd/" + ($exe -replace '\.exe$', '')
        & go build -o $exe $pkg
        if ($LASTEXITCODE -ne 0) { Refuse "go build $pkg failed" }
    }
}

if ($staleMods.Count -gt 0) {
    Step "Rebuilding stale mod DLLs: $($staleMods -join ', ')"
    foreach ($mod in $staleMods) {
        switch ($mod) {
            "TEVI" { Cmd (Join-Path $root "dev-scripts\build-tevi.bat") "" }
            "Pseudoregalia" { Cmd (Join-Path $root "dev-scripts\build-pseudoregalia.bat") "" }
        }
    }
    $changed = @(& git status --porcelain --untracked-files=no -- packaging/release/games)
    if ($changed.Count -eq 0) { Refuse "the build scripts ran but nothing under packaging/release/games changed -- look at their output" }
    & git add -- packaging/release/games
    & git commit -q -m "release prep: $($staleMods -join ' and ') DLL rebuilt from current sources (dev-scripts/release.ps1 for $Version)"
    if ($LASTEXITCODE -ne 0) { Refuse "commit of the rebuilt DLL(s) failed" }
    Write-Host "committed the rebuilt DLL(s); deploy them to the live installs before the next live test (feedback on record)"
}

Step "Preflight, second pass"
$p = Run-Preflight
if (-not $p.ok) {
    $p.lines | Where-Object { $_ -match '^\s*FAIL' } | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Refuse "preflight is still red after the rebuilds"
}
Write-Host "preflight clean"

Step "Push"
& git push origin master
if ($LASTEXITCODE -ne 0) { Refuse "push failed" }
$sha = (& git rev-parse HEAD).Trim()
Write-Host "pushed $($sha.Substring(0,8))"

if (-not $SkipCI) {
    Step "Waiting for CI on $($sha.Substring(0,8))"
    Start-Sleep -Seconds 25
    $deadline = (Get-Date).AddMinutes(40)
    while ($true) {
        $runs = @(& gh run list -L 20 --json status,conclusion,workflowName,headSha -q ".[] | select(.headSha==`"$sha`") | `"\(.status)`t\(.conclusion)`t\(.workflowName)`"")
        $pending = @($runs | Where-Object { $_ -match '^(in_progress|queued|waiting|requested|pending)' })
        if ($runs.Count -gt 0 -and $pending.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) { Refuse "CI did not finish within 40 minutes:`n$($runs -join "`n")" }
        Start-Sleep -Seconds 30
    }
    $runs | ForEach-Object { Write-Host $_ }
    $red = @($runs | Where-Object { $_ -notmatch "`tsuccess`t" })
    if ($red.Count -gt 0) { Refuse "CI is red on HEAD -- read it (gh run view <id> --log-failed), fix, run this again" }
    Write-Host "every workflow on HEAD is green"
}

Step "Dispatching release.yml for $Version"
$ghArgs = @("workflow", "run", "release.yml", "-f", "version=$Version", "-f", "prerelease=$($Prerelease.IsPresent.ToString().ToLower())")
if ($HighlightsFile -ne "") { $ghArgs += @("-F", "highlights=@$HighlightsFile") }
& gh @ghArgs
if ($LASTEXITCODE -ne 0) { Refuse "gh workflow run failed" }
Start-Sleep -Seconds 30
$runId = (& gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId').Trim()
Write-Host "release run $runId"
$deadline = (Get-Date).AddMinutes(40)
while ($true) {
    $st = (& gh run view $runId --json status,conclusion -q '"\(.status)\t\(.conclusion)"').Trim()
    if ($st -match '^completed') { break }
    if ((Get-Date) -gt $deadline) { Refuse "the release run did not finish within 40 minutes" }
    Start-Sleep -Seconds 30
}
& gh run view $runId --json jobs -q '.jobs[] | "\(.conclusion)\t\(.name)"' | ForEach-Object { Write-Host $_ }
if ($st -notmatch "`tsuccess$") { Refuse "the release run failed -- gh run view $runId --log-failed" }

Step "Published"
& gh release view $Version --json name,url,assets -q '"\(.name)\t\(.url)", (.assets[] | "  \(.name)\t\(.size) bytes")'
