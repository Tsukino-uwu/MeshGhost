[CmdletBinding()]
param(
    # Run only the fixtures whose name matches this regex. No argument runs all of them.
    [string]$Only,
    # Run slice $Shard (1-based) of $Shards equal slices of the fixture list -- every fixture runs
    # a full preflight, so the run is as long as the list, and .github/workflows/gates.yml
    # splits it across parallel jobs the way ci.yml splits the race tests. Fixtures are dealt
    # round-robin by position, so a slice is stable until the list changes.
    [int]$Shard = 0,
    [int]$Shards = 0,
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

# For a gate that reads the FIRST match, or a specific place in a file: appending a line would
# never reach it. Replaces every match of $pattern; a fixture that needs one occurrence anchors
# the pattern. $replacement is a .NET regex replacement, so $1 refers to a group.
function Plant-Replace($wt, $relPath, $pattern, $replacement) {
    $full = Join-Path $wt $relPath
    if (-not (Test-Path -LiteralPath $full)) { throw "fixture target is missing: $relPath" }
    $existing = [System.IO.File]::ReadAllText($full)
    $n = [regex]::Matches($existing, $pattern).Count
    if ($n -eq 0) { throw "nothing in $relPath matches '$pattern' -- the fixture is aimed at nothing" }
    $after = [regex]::Replace($existing, $pattern, $replacement)
    if ($after -eq $existing) { throw "replacement in $relPath changed nothing" }
    [System.IO.File]::WriteAllText($full, $after, $utf8NoBom)
    if ([System.IO.File]::ReadAllText($full) -ne $after) { throw "replacement did not land in $relPath" }
}

function Plant-Remove($wt, $relPath) {
    & git -C $wt rm --quiet -- $relPath | Out-Null
    if (Test-Path -LiteralPath (Join-Path $wt $relPath)) { throw "removal did not land: $relPath is still there" }
    if (@(& git -C $wt ls-files -- $relPath).Count -gt 0) { throw "git still tracks $relPath after the removal" }
}

# A COMMIT in the scratch worktree, for the gates that read `git log` and cannot see a plant on
# disk. It moves the worktree's detached HEAD only; Reset-Worktree puts it back on the real HEAD.
# An identity is passed inline so the fixture does not depend on the machine's git config.
function Plant-Commit($wt, $relPath, $line, $message) {
    Plant-TextLine $wt $relPath $line
    & git -C $wt add -- $relPath | Out-Null
    & git -C $wt -c user.name=harness -c user.email=harness@example.com commit --quiet -m $message | Out-Null
    $touched = @(& git -C $wt show --name-only --format= HEAD)
    if ($touched -notcontains $relPath) { throw "the planted commit does not touch $relPath" }
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

    @{  Name = 'synced-unsent-key'
        Section = 'SYNCED.md matches the send code'
        Expect = 'FAIL'
        Why = 'a SYNCED.md row for a key the send code never sends -- the page and the code disagree'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/emulator/pokemon/emerald/SYNCED.md' "| Key | On the other screen | Sent |`n| --- | --- | --- |`n| ``planted_key`` | planted by the negative-test harness | always |" } },

    @{  Name = 'synced-unchecked-rises'
        Section = 'SYNCED.md matches the send code'
        Expect = 'FAIL'
        Why = "one more 'not checked yet' cell than recorded -- a new value arriving unguarded"
        Plant = { param($wt) Plant-TextLine $wt 'adapters/emulator/pokemon/emerald/SYNCED.md' "| Message | Direction | What happens | Checked on arrival |`n| --- | --- | --- | --- |`n| ``planted`` | to the game | planted by the negative-test harness | not checked yet |" } },

    @{  Name = 'documentation-fence'
        Section = 'No reproduced expression in documentation.md'
        Expect = 'WARN'
        Why = 'a fenced block in a documentation.md -- the shape all three reproduced-expression violations shared'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/_template/documentation.md' "``````text`nplanted by the negative-test harness`n``````" } },

    # ---- the 2026-09-16 sweep: every gate that runs under -TreeOnly gets at least one fixture ----

    @{  Name = 'duration-vague'
        Section = 'Invented durations'
        Expect = 'FAIL'
        Why = 'a duration with no number or date behind it'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: this sat broken for weeks' } },

    @{  Name = 'duration-unnumbered-span'
        Section = 'Invented durations'
        Expect = 'FAIL'
        Why = "an '<units> of' span with no number in front of it -- the second grep in that section"
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: years of work went into this' } },

    @{  Name = 'line-cap-outside-budget'
        Section = 'Reading budgets'
        Expect = 'FAIL'
        Why = 'a line-cap header on a file that is not an instruction file'
        Plant = { param($wt) Plant-FirstLine $wt 'docs/config.md' '<!-- line-cap: 500 -->' } },

    @{  Name = 'line-cap-exceeded'
        Section = 'Reading budgets'
        Expect = 'FAIL'
        Why = 'a budgeted file one line over its own declared cap'
        Plant = { param($wt)
            $p = '.claude/skills/write-a-probe/SKILL.md'
            $lines = @(Get-Content -LiteralPath (Join-Path $wt $p))
            $decl = $lines | Select-String -Pattern '<!--\s*line-cap:\s*(\d+)' | Select-Object -First 1
            $need = [int]$decl.Matches[0].Groups[1].Value - $lines.Count + 1
            Plant-TextLine $wt $p ((1..$need | ForEach-Object { "planted by the negative-test harness, line $_" }) -join "`n") } },

    @{  Name = 'entry-runs-past-one-line'
        Section = 'One-line entries'
        Expect = 'FAIL'
        Why = 'a queue entry whose detail wraps onto a second, indented line'
        Plant = { param($wt) Plant-TextLine $wt 'agent_docs/status.md' "- 2026-09-16 -- planted by the negative-test harness`n  with its detail carried onto a second line" } },

    @{  Name = 'blind-walk-armed'
        Section = 'Probe scripts: blind reflection walks'
        Expect = 'FAIL'
        Why = 'an enabled.txt on a withdrawn probe whose scripts still walk reflection'
        Plant = { param($wt) Plant-NewFile $wt 'adapters/pseudoregalia/probes/probe_pawndiff/enabled.txt' "planted by the negative-test harness`n" } },

    @{  Name = 'blind-walk-disarmed-grows'
        Section = 'Probe scripts: blind reflection walks'
        Expect = 'FAIL'
        Why = 'one more disarmed probe carrying a walk than the ratchet records'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget 'local planted = obj:ForEachProperty(function() end)' } },

    @{  Name = 'reproduced-declaration'
        Section = 'No reproduced expression ANYWHERE, not just documentation.md'
        Expect = 'FAIL'
        Why = 'a C declaration copied into a tracked text file'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness: u16 gPlantedCounter = 0;' } },

    @{  Name = 'decomp-label-returns'
        Section = 'Measured or observed only: no NEW source-derived claims (ratchet)'
        Expect = 'FAIL'
        Why = 'the retired [from the decomp] label used once more than its floor of zero'
        Plant = { param($wt) Plant-TextLine $wt $luaTarget '-- planted by the negative-test harness [from the decomp]' } },

    @{  Name = 'decomp-citation-grows'
        Section = 'Measured or observed only: no NEW source-derived claims (ratchet)'
        Expect = 'FAIL'
        Why = 'a source-file citation in a documentation.md above its recorded floor'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/emulator/pokemon/crystal/documentation.md' 'Planted by the negative-test harness: the routine is in engine/planted.asm.' } },

    @{  Name = 'script-dir-no-separator'
        Section = 'SCRIPT_DIR concatenations carry a separator (Crystal)'
        Expect = 'FAIL'
        Why = 'a SCRIPT_DIR concatenation that builds a path with no separator'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/emulator/pokemon/crystal/meshghost_crystal.lua' 'local planted = SCRIPT_DIR .. "planted.txt"' } },

    @{  Name = 'raw-bool-read'
        Section = 'Reflected bools use the property mask (Pseudoregalia)'
        Expect = 'FAIL'
        Why = 'a reflected bool read raw, with no bitfield-safe: reason'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp' 'auto planted = GetValuePtrByPropertyNameInChain<bool>(obj, STR("Planted"));' } },

    @{  Name = 'bare-wall-clock'
        Section = 'The core''s clock is injectable, and stays that way'
        Expect = 'FAIL'
        Why = 'a bare time.Now() in core with no wall-clock: reason'
        Plant = { param($wt) Plant-TextLine $wt 'core/core.go' 'var plantedByTheHarness = time.Now()' } },

    @{  Name = 'bare-interpreter'
        Section = 'No bare interpreter on PATH in dev-scripts'
        Expect = 'FAIL'
        Why = 'a dev-script calling cmd off PATH'
        Plant = { param($wt) Plant-TextLine $wt 'dev-scripts/stage-release.ps1' 'cmd /c echo planted by the negative-test harness' } },

    @{  Name = 'missing-anchor'
        Section = 'Markdown link integrity'
        Expect = 'FAIL'
        Why = 'an #anchor naming a heading the file does not have'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: [gone](#no-such-heading-planted).' } },

    @{  Name = 'link-escapes-repo'
        Section = 'Markdown link integrity'
        Expect = 'FAIL'
        Why = 'a relative link that climbs out of the repo -- depth-dependent on GitHub'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: [out](../../outside.md).' } },

    @{  Name = 'restated-rule-unlinked'
        Section = 'Canonical source for multiply-stated rules'
        Expect = 'FAIL'
        Why = 'a registered rule restated with no link to its home'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: a flag flip is not a revert.' } },

    @{  Name = 'pitfall-heading-unindexed'
        Section = 'pitfalls index coverage'
        Expect = 'FAIL'
        Why = 'a pitfalls heading with no line in INDEX.md'
        Plant = { param($wt) Plant-TextLine $wt 'agent_docs/pitfalls/method.md' '## Planted by the negative-test harness' } },

    @{  Name = 'pitfall-index-untagged'
        Section = 'pitfalls index coverage'
        Expect = 'FAIL'
        Why = 'an index line with no outcome tag'
        Plant = { param($wt) Plant-TextLine $wt 'agent_docs/pitfalls/INDEX.md' '- Planted by the negative-test harness, with no outcome tag' } },

    @{  Name = 'verified-entry-unindexed'
        Section = 'VERIFIED index coverage'
        Expect = 'FAIL'
        Why = 'a VERIFIED.md entry missing from its own index'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/tevi/VERIFIED.md' '## Planted by the negative-test harness' } },

    @{  Name = 'adapter-file-missing'
        Section = 'Adapter file set'
        Expect = 'FAIL'
        Why = 'a mandated adapter file removed'
        Plant = { param($wt) Plant-Remove $wt 'adapters/tevi/BANDAGES.md' } },

    @{  Name = 'probe-folder-unindexed'
        Section = 'Adapter file set'
        Expect = 'FAIL'
        Why = 'an adapter with probe folders and no PROBES.md to index them'
        Plant = { param($wt) Plant-Remove $wt 'adapters/pseudoregalia/PROBES.md' } },

    @{  Name = 'stale-adapter-count'
        Section = 'Adapter/game counts in living docs'
        Expect = 'FAIL'
        Why = 'a living doc counting the games with a number that is no longer true'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: all three games do this.' } },

    @{  Name = 'status-undated'
        Section = 'status.md is current'
        Expect = 'FAIL'
        Why = 'a status item carrying no date'
        Plant = { param($wt) Plant-TextLine $wt 'agent_docs/status.md' '- planted by the negative-test harness, carrying no date' } },

    @{  Name = 'status-stale'
        Section = 'status.md is current'
        Expect = 'FAIL'
        Why = 'a status item dated past the two-day window'
        Plant = { param($wt) Plant-TextLine $wt 'agent_docs/status.md' '- 2026-01-01 -- planted by the negative-test harness, never re-dated' } },

    @{  Name = 'unverified-no-state'
        Section = 'UNVERIFIED entries carry a state'
        Expect = 'FAIL'
        Why = 'a queue entry with no [READY]/[OPEN]/[DONE] state'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/tevi/UNVERIFIED.md' '## Planted by the negative-test harness' } },

    @{  Name = 'phase-log-behind'
        Section = 'Phase log freshness'
        Expect = 'FAIL'
        Why = 'three commits to an adapter after its phase log was last touched'
        Plant = { param($wt)
            foreach ($i in 1..3) { Plant-Commit $wt 'adapters/tevi/README.md' "Planted by the negative-test harness, commit $i." "harness: planted commit $i" } } },

    @{  Name = 'phase-day-unclaimed'
        Section = 'Phase log coverage'
        Expect = 'FAIL'
        Why = "a phase log whose dated headings no longer claim the days its tree changed"
        Plant = { param($wt) Plant-Replace $wt 'agent_docs/phases/phase12.md' '(?m)^(#{2,3} )2026-' '${1}2025-' } },

    @{  Name = 'flag-unregistered'
        Section = 'FLAGS.md completeness'
        Expect = 'FAIL'
        Why = 'a compile-time flag in code that the register does not name'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/emulator/pokemon/crystal/meshghost_crystal.lua' 'local PLANTED_HARNESS_FLAG = true' } },

    @{  Name = 'fuzz-target-uncensused'
        Section = 'Fuzz census: every target has a CI step and a roster row'
        Expect = 'FAIL'
        Why = 'a fuzz target with no CI step and no roster row'
        Plant = { param($wt) Plant-NewFile $wt 'bridge/planted_harness_test.go' "package bridge`n`nimport `"testing`"`n`nfunc FuzzPlantedByTheHarness(f *testing.F) { f.Fuzz(func(t *testing.T, b []byte) {}) }`n" } },

    @{  Name = 'adr-unindexed'
        Section = 'ADR index coverage'
        Expect = 'FAIL'
        Why = 'an ADR file not linked from architecture.md'
        Plant = { param($wt) Plant-NewFile $wt 'agent_docs/adr/9999-planted-by-the-negative-test-harness.md' "# 9999 planted by the negative-test harness`n" } },

    @{  Name = 'bridge-port-drift'
        Section = 'Bridge constants agree across the four adapters'
        Expect = 'FAIL'
        Why = 'one adapter on a different bridge base port'
        Plant = { param($wt) Plant-Replace $wt 'adapters/emulator/pokemon/emerald/meshghost_emerald.lua' '(?m)^local BRIDGE_BASE_PORT = 7778\r?$' 'local BRIDGE_BASE_PORT = 7779' } },

    @{  Name = 'phase-file-unindexed'
        Section = 'Phase index coverage'
        Expect = 'FAIL'
        Why = 'a phase file not linked from the phase index'
        Plant = { param($wt) Plant-NewFile $wt 'agent_docs/phases/phase99.md' "# Phase 99 -- planted by the negative-test harness`n" } },

    @{  Name = 'bridge-message-undocumented'
        Section = 'Bridge message coverage in the adapter template'
        Expect = 'FAIL'
        Why = 'a bridge message type the adapter template never names'
        Plant = { param($wt) Plant-TextLine $wt 'bridge/bridge.go' 'const plantedByTheHarness MessageType = "planted_message"' } },

    @{  Name = 'dev-script-undocumented'
        Section = 'dev-scripts README coverage'
        Expect = 'FAIL'
        Why = 'a dev-script the README does not mention'
        Plant = { param($wt) Plant-NewFile $wt 'dev-scripts/planted-by-the-harness.ps1' "# planted by the negative-test harness`n" } },

    @{  Name = 'remoteghost-field-unreleased'
        Section = 'RemoteGhost pointer fields are cleared at release (Pseudoregalia)'
        Expect = 'FAIL'
        Why = 'a new pointer field on RemoteGhost that neither release path clears'
        Plant = { param($wt) Plant-Replace $wt 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.hpp' '(struct RemoteGhost\s*\r?\n\s*\{\r?\n)' ('${1}        RC::Unreal::UObject* planted_by_the_harness{nullptr};' + "`n") } },

    @{  Name = 'findallof-grows'
        Section = 'FindAllOf ratchet (Pseudoregalia)'
        Expect = 'FAIL'
        Why = 'one FindAllOf call site more than the ratchet records'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp' '// planted by the negative-test harness: UObjectGlobals::FindAllOf(STR("Planted"), out);' } },

    @{  Name = 'raw-cache-unannotated'
        Section = 'Raw-pointer caches must say why they cannot dangle (Pseudoregalia)'
        Expect = 'FAIL'
        Why = 'a file-scope raw UObject* cache with no stale-safe: reason above it'
        Plant = { param($wt) Plant-TextLine $wt 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp' 'static UObject* g_planted_by_the_harness = nullptr;' } },

    @{  Name = 'ghost-drop-keeps-handle'
        Section = 'Dropping a ghost must drop every component attached to it (Pseudoregalia)'
        Expect = 'FAIL'
        Why = 'a ghost dropped with nothing attached to it cleared in the same breath'
        Plant = { param($wt) Plant-Replace $wt 'adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp' '(?m)^(\s*it->second\.ghost = nullptr;)' ('${1}' + "`n" + '        planted.ghost = nullptr;') } },

    @{  Name = 'hard-coded-count'
        Section = 'No hard-coded adapter or game counts in living docs'
        Expect = 'FAIL'
        Why = 'a living doc counting the mods'
        Plant = { param($wt) Plant-TextLine $wt 'docs/config.md' 'Planted by the negative-test harness: our four mods share it.' } },

    @{  Name = 'action-version-split'
        Section = 'GitHub Action versions agree across workflows'
        Expect = 'FAIL'
        Why = 'one workflow pinning an action to an older major than the rest'
        Plant = { param($wt) Plant-TextLine $wt '.github/workflows/docs.yml' '# planted by the negative-test harness: uses: actions/checkout@v1' } },

    @{  Name = 'adapter-gate-too-broad'
        Section = 'Every adapter has its own path-filtered workflow'
        Expect = 'FAIL'
        Why = 'an adapter gate filtering on a path outside its own tree'
        Plant = { param($wt) Plant-TextLine $wt '.github/workflows/tevi.yml' '      - ''docs/**''' } }
)

# The full list is kept for the coverage tally: a shard or an -Only subset must not report the
# fixtures it did not run as gaps.
$allFixtures = $fixtures
if ($Only) { $fixtures = @($fixtures | Where-Object { $_.Name -match $Only }) }
if ($Shards -gt 0 -or $Shard -gt 0) {
    if ($Shards -lt 1 -or $Shard -lt 1 -or $Shard -gt $Shards) { Write-Host "-Shard must be 1..-Shards (got $Shard of $Shards)" -ForegroundColor Red; exit 1 }
    $sliced = @()
    for ($i = 0; $i -lt $fixtures.Count; $i++) { if (($i % $Shards) -eq ($Shard - 1)) { $sliced += $fixtures[$i] } }
    $fixtures = $sliced
}
if ($fixtures.Count -eq 0) { Write-Host "no fixtures match -Only '$Only' / shard $Shard of $Shards" -ForegroundColor Red; exit 1 }

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
    # --hard to the REAL HEAD, not the worktree's: a fixture may have committed, and a reset to
    # the worktree's own HEAD would keep that commit for every fixture after it.
    & git -C $wt reset --quiet --hard $script:headSha 2>&1 | Out-Null
    & git -C $wt clean --quiet -fdx 2>&1 | Out-Null
    if ((& git -C $wt rev-parse HEAD) -ne $script:headSha) { throw "the scratch worktree did not come back to $script:headSha" }
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

$script:headSha = (& git rev-parse HEAD).Trim()

Write-Host "Negative-testing preflight's gates."
Write-Host "  tree under test:  a detached worktree at HEAD ($($script:headSha.Substring(0, 8))), under $ScratchRoot"
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
        $covered = @($allFixtures | ForEach-Object { $_.Section } | Sort-Object -Unique)
        # A section that only SKIPs under -TreeOnly cannot be fixtured by this harness at all, so
        # it is counted apart rather than listed as a gap forever.
        $live = @($baseReport.Keys | Where-Object { @($baseReport[$_] | Where-Object { $_ -ne 'SKIP' }).Count -gt 0 })
        $uncovered = @($live | Where-Object { $covered -notcontains $_ })
        Report-Info "$($covered.Count) of $($live.Count) section(s) that run under -TreeOnly have a fixture here ($($baseReport.Count - $live.Count) more need a working copy)."
        if ($uncovered.Count -gt 0) {
            Report-Info "No fixture yet (a gate whose ability to fail is assumed, not shown):"
            foreach ($s in $uncovered) { Report-Info "  - $s" }
        }
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
