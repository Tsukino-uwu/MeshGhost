<#
.SYNOPSIS
Cuts a release: preflight, rebuild what it calls stale, preflight again, push, wait for CI, then
dispatch release.yml -- and refuse at the first red.

.DESCRIPTION
The dispatch sits behind the checks, so a release cannot be cut past a preflight FAIL. Nothing here
re-derives a check: preflight.ps1 decides what is stale and what is wrong, this script runs the
repo's own build scripts for what it names and stops on anything else, so a check added to
preflight is a check on releases too.

.PARAMETER Version
The tag, e.g. v1.2.6. Refused if it already exists on origin.

.PARAMETER HighlightsFile
A file whose contents become the release body above the generated changelog, passed to gh with
`@` so gh reads the file rather than sending its path. Scope: relay/client-specific changes, or
something big for one game, never QoL lines.

.PARAMETER Prerelease
Mark the release a pre-release.

.PARAMETER SkipCI
Dispatch without waiting for CI on HEAD. For a docs-only re-cut whose CI is already green; never
the default.

.EXAMPLE
& $env:ComSpec /c is not needed: this is PowerShell. From the repo root:
    powershell -NoProfile -ExecutionPolicy Bypass -File dev-scripts\release.ps1 -Version v1.2.6 -HighlightsFile <highlights file>
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

# git by path, never by name: `git` on PATH can resolve to a devkitPro/MSYS2 shadow with its own line-ending view.
$git = @("C:\Program Files\Git\cmd\git.exe", "C:\Program Files\Git\bin\git.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $git) { Write-Host "no Git for Windows under Program Files -- falling back to whatever 'git' on PATH is" -ForegroundColor Yellow; $git = "git" }

function Step($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor Cyan }
function Refuse($msg) { Write-Host ""; Write-Host "RELEASE REFUSED: $msg" -ForegroundColor Red; exit 1 }
function Cmd($file, $argList) {
    # Every .bat goes through ComSpec: a bare name on PATH can resolve to a devkitPro/MSYS2 shadow.
    & $env:ComSpec /c "`"$file`" $argList"
    if ($LASTEXITCODE -ne 0) { Refuse "$file exited $LASTEXITCODE" }
}

if ($Version -notmatch '^v\d+\.\d+\.\d+$') { Refuse "version must look like v1.2.6, got '$Version'" }
if ($HighlightsFile -ne "" -and -not (Test-Path -LiteralPath $HighlightsFile)) { Refuse "no highlights file at $HighlightsFile" }

Step "Repository state"
$branch = (& $git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne "master") { Refuse "on branch '$branch'; releases are cut from master" }
# Content, not status: `git status` lists files whose only difference is a line ending, and a dirty submodule
# checkout is not a change to this repository either.
& $git diff --quiet --ignore-cr-at-eol --ignore-submodules HEAD -- 2>$null
if ($LASTEXITCODE -ne 0) {
    & $git --no-pager diff --ignore-cr-at-eol --ignore-submodules --stat HEAD -- 2>$null | ForEach-Object { Write-Host $_ }
    Refuse "tracked files have uncommitted changes -- commit or stash first"
}
& $git fetch origin --tags --quiet
if ((& $git ls-remote --tags origin "refs/tags/$Version")) { Refuse "tag $Version already exists on origin" }
$behind = (& $git rev-list --count "HEAD..origin/master").Trim()
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
    $changed = @(& $git status --porcelain --untracked-files=no -- packaging/release/games)
    if ($changed.Count -eq 0) { Refuse "the build scripts ran but nothing under packaging/release/games changed -- look at their output" }
    & $git add -- packaging/release/games
    & $git commit -q -m "release prep: $($staleMods -join ' and ') DLL rebuilt from current sources (dev-scripts/release.ps1 for $Version)"
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
& $git push origin master
if ($LASTEXITCODE -ne 0) { Refuse "push failed" }
$sha = (& $git rev-parse HEAD).Trim()
Write-Host "pushed $($sha.Substring(0,8))"

if (-not $SkipCI) {
    Step "Waiting for CI on $($sha.Substring(0,8))"
    Start-Sleep -Seconds 25
    $deadline = (Get-Date).AddMinutes(40)
    # `--json` and ConvertFrom-Json, never a `-q` jq expression: PowerShell's quoting turns one into gh's usage text.
    while ($true) {
        $json = & gh run list --commit $sha -L 20 --json status,conclusion,workflowName | Out-String
        $runs = @()
        # Windows PowerShell 5.1 hands a JSON array back as one object; the ForEach-Object unrolls it.
        if ($json.Trim() -ne "") { $runs = @($json | ConvertFrom-Json | ForEach-Object { $_ }) }
        $pending = @($runs | Where-Object { $_.status -ne "completed" })
        if ($runs.Count -gt 0 -and $pending.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) { Refuse "CI did not finish within 40 minutes" }
        Start-Sleep -Seconds 30
    }
    $runs | ForEach-Object { Write-Host "$($_.status)`t$($_.conclusion)`t$($_.workflowName)" }
    $red = @($runs | Where-Object { $_.conclusion -ne "success" })
    if ($red.Count -gt 0) { Refuse "CI is red on HEAD -- read it (gh run view <id> --log-failed), fix, run this again" }
    Write-Host "every workflow on HEAD is green"

    # HEAD's runs are only what its own push triggered, and every workflow but hygiene is path-filtered, so a red race
    # run under a docs-only commit would pass: also refuse when any workflow's newest completed run on master is red.
    # Release (about to be dispatched), cancelled and skipped runs say nothing about the code.
    $json = & gh run list --branch master -L 200 --json workflowName,status,conclusion,headSha,createdAt | Out-String
    $all = @()
    if ($json.Trim() -ne "") { $all = @($json | ConvertFrom-Json | ForEach-Object { $_ }) }
    $newestRed = @($all | Where-Object { $_.status -eq "completed" -and $_.workflowName -ne "Release" -and
            $_.conclusion -notin @("cancelled", "skipped") } |
        Sort-Object createdAt -Descending | Group-Object workflowName |
        ForEach-Object { $_.Group[0] } | Where-Object { $_.conclusion -ne "success" })
    if ($newestRed.Count -gt 0) {
        $newestRed | ForEach-Object { Write-Host "$($_.conclusion)`t$($_.workflowName)`t$($_.headSha.Substring(0,8))" }
        Refuse "a workflow's newest run on master is red, though HEAD's own runs are green -- read it, fix, run this again"
    }
    Write-Host "every workflow's newest run on master is green"
}

Step "Dispatching release.yml for $Version"
$ghArgs = @("workflow", "run", "release.yml", "-f", "version=$Version", "-f", "prerelease=$($Prerelease.IsPresent.ToString().ToLower())")
if ($HighlightsFile -ne "") { $ghArgs += @("-F", "highlights=@$HighlightsFile") }
& gh @ghArgs
if ($LASTEXITCODE -ne 0) { Refuse "gh workflow run failed" }
Start-Sleep -Seconds 30
$latest = @((& gh run list --workflow release.yml -L 1 --json databaseId | Out-String) | ConvertFrom-Json | ForEach-Object { $_ })
if ($latest.Count -eq 0) { Refuse "no release run found after the dispatch" }
$runId = $latest[0].databaseId
Write-Host "release run $runId"
$deadline = (Get-Date).AddMinutes(40)
while ($true) {
    $run = (& gh run view $runId --json status,conclusion,jobs | Out-String) | ConvertFrom-Json
    if ($run.status -eq "completed") { break }
    if ((Get-Date) -gt $deadline) { Refuse "the release run did not finish within 40 minutes" }
    Start-Sleep -Seconds 30
}
@($run.jobs | ForEach-Object { $_ }) | ForEach-Object { Write-Host "$($_.conclusion)`t$($_.name)" }
if ($run.conclusion -ne "success") { Refuse "the release run failed -- gh run view $runId --log-failed" }

Step "Published"
$rel = (& gh release view $Version --json name,url,assets | Out-String) | ConvertFrom-Json
Write-Host "$($rel.name)`t$($rel.url)"
@($rel.assets | ForEach-Object { $_ }) | ForEach-Object { Write-Host "  $($_.name)`t$($_.size) bytes" }
