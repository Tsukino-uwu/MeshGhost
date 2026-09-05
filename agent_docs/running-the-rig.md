# Running the rig — the scaffolding for a live test

**What this is.** Everything about running a live test: starting the relay and the cores hidden, which
rig is the default (netsim, not a clean loopback), the TEVI two-instance runbook pointer, launching
BizHawk from PowerShell, working two games at once and which model an agent gets, what each running
emulator is for, running several agents on different work, reading a crash dump without a debugger,
and the rig notes and savestate slots that used to sit in `status.md`. Split out of
[environment.md](environment.md) on 2026-09-02; that file keeps the machine and the toolchain, this
one keeps the procedure. `CLAUDE.md`'s rule that YOU run the scaffolding and the user only opens the
game points here. `playing.md` is the sibling for driving the game itself once it is up.

## Index

- Running the scaffolding for a local test — keep it hidden
- The default dev rig is NETSIM, not a clean loopback (user's call, 2026-08-28)
- Running the TEVI two-instance rig — the runbook is in `dev-scripts/README.md`
- Launching BizHawk from PowerShell — quote the ROM path yourself, 2026-08-19
- Working two games at once, and which model an agent gets — 2026-08-19
- Every running emulator has a job — 2026-08-19
- Playing the game, and looking at it — moved 2026-08-19
- Running several agents on DIFFERENT work at once — 2026-08-19
- Crash dumps: where they are, and the tool that reads them without a debugger (2026-08-30)
- Rig notes carried out of `status.md` (2026-09-02)
- Changing a client setting WITHOUT relaunching the game — kill the core, the adapter respawns it (2026-09-04)
- `UE4SS.log` is written with a DELAY, and an empty tail is not a quiet game (2026-09-04)

---

## Running the scaffolding for a local test — keep it hidden

**User preference, 2026-08-18.** When starting the relay, a core, or any other helper process for a
local/dev test, **start it hidden and redirect its output to a log**, then read the log. Never leave
a console window per process on the user's screen.

```powershell
Start-Process -WindowStyle Hidden -FilePath ".\meshghost-relay.exe" `
  -ArgumentList "-loopback","-send-hz=100" `
  -RedirectStandardOutput "relay.log" -RedirectStandardError "relay.err.log"
```

Two reasons, and the second is the one that matters:

- **The window is pure clutter.** Its output is already going to the log, so the window shows
  nothing the log does not.
- **The user is mid-test.** Windows appearing over a running game interrupt the exact thing the
  scaffolding exists to support, and the user has to move or minimise them before playing.

**Read the log to confirm startup** — `CLAUDE.md` already requires confirming the relay/core came up
and chose the right transport, and hiding the window does not relax that. It is the log that
proves it either way; the window never did.

Live case: two visible consoles appeared over a Crystal session on 2026-08-18, which is what
prompted the preference.

### Launching a `dev-scripts` `.bat` from an agent shell — 2026-08-25

**`NoDefaultCurrentDirectoryInExePath=1` is set in the agent's shell**, so `cmd` will not run a
batch file named without a path even when its own `%CD%` is the folder holding it — `dir /b
run-relay-loopback.bat` finds the file on the very next line while `cmd /c run-relay-loopback.bat`
answers *"is not recognized as an internal or external command"*. **Always give the launcher its
absolute path**, and note the error names the file, which reads like a missing file rather than a
refused lookup. Three launches were lost to reading it that way.

Two more shapes that failed silently in the same attempt, both worth not repeating:

- **`Start-Process cmd.exe -WorkingDirectory <dir> -ArgumentList "/c","<bat> > log 2> err"`** — the
  redirection is part of the argument string, so when the bat is not found the error goes to a log
  written *before* the failure and the next read shows the PREVIOUS attempt's text. Two runs looked
  identical because nothing had been rewritten at all. **Check the log's mtime, not its contents**,
  before believing a repeated error.
- **`start /min cmd /c <bat> > log`** — `start` detaches immediately and the redirection binds to
  `start` rather than to the bat, so both logs come back empty and no process exists. Nothing
  reports an error anywhere.

**What worked**: the Bash tool with `run_in_background`, `cmd //c "<absolute path to bat>" > log
2> err`. That keeps the launcher's filename in the record, which is the whole reason `run-core.bat`
and the `-shipped` pair are separate files (see `run-core.bat`'s own header).

## The default dev rig is NETSIM, not a clean loopback (user's call, 2026-08-28)

The clean 100Hz/`-interp=0` rig is only for FIRST matching a game's movement 1:1; after that,
everything runs through `run-netsim.bat` with a bad link, to show how it will actually look -- **and since
2026-09-02 that link is the bat's no-arg WORST-CASE profile (NA<->EU ping plus bad wifi) for every rate or
interp verdict; a milder profile is a comparison, never a verdict.** Rule and recipes:
`agent_docs/testing.md` ("Running a session over a bad network") and `dev-scripts/README.md`
("The two-rig doctrine"). Why: one netsim session found three shipped bugs and a timing flaw the
clean rig structurally could not show.

## Running the TEVI two-instance rig — the runbook is in `dev-scripts/README.md`

Relay, two cores, hot-reload mode, both installs, both windows labelled, and the three ways that
rig came up broken on 2026-08-28 (each a game with no ghost and no error): **`dev-scripts/README.md`,
"Running the TEVI two-instance rig"**. It lives there rather than here because every step of it is a
script in that folder, and that file has no reading budget to spend — this one does.

## Launching BizHawk from PowerShell — quote the ROM path yourself, 2026-08-19

`Start-Process -FilePath EmuHawk.exe -ArgumentList '--lua=...', 'C:\...\bizhawk roms\...gba'`
looks right and is wrong on **Windows PowerShell 5.1**, which joins `-ArgumentList` elements with
spaces and **does not quote the ones containing spaces**. EmuHawk then receives the ROM path in
pieces, cannot open any of them, and puts up a window whose entire title is `Exception` — no game,
and nothing in any MeshGhost log to explain it, because MeshGhost never started.

Pass one argument string with the quotes embedded instead:

```powershell
$rom = '"C:\...\bizhawk roms\Roms\gba\Pokemon - Emerald Version (USA, Europe).gba"'
Start-Process -FilePath $emuhawk -ArgumentList "--lua=$loader $rom"
```

**The tell is the window title**, since a `Get-Process` check reports the emulator running either
way. Check `MainWindowTitle` after a launch: `Lua Console` means it came up, `Exception` means it
did not. Found live 2026-08-19, launching vanilla Emerald for its end-to-end confirmation pass.

## Working two games at once, and which model an agent gets — 2026-08-19

**Shape (user's standing grant, extended 2026-08-19): ONE AGENT PER BIZHAWK INSTANCE.** Not per
game — per *instance*. The main session drives one and keeps talking to the user; every other
emulator that gets launched, for any reason, gets its own agent. A third instance appeared the
same evening (an Archipelago-patched ROM, booted alongside vanilla Crystal and Emerald) and the
user's instruction was immediate: *"use a new agent for every new bizhawk instance we run/use."*

Why per instance rather than per game: an emulator is a **single-owner resource**. It has one
controller, one Lua console, one loader control file and one attached core, and two parties
driving it produce exactly the failures this file already lists — scripts swapped underneath each
other, savestates loaded mid-measurement, inputs fighting. Ownership is the point; the game it
happens to be running is incidental.

**Hand every instance-owning agent the same four things**, or it cannot stay in its lane:

| What | Example |
|---|---|
| Its emulator's **pid** | `EmuHawk 11788 is yours` |
| Its **loader control file** | `MESHGHOST_DEV_LOADER_TARGET=bizhawk-dev-loader-apcrystal.target` |
| Its **bridge port** (and its own core) | `7783` |
| The **off-limits list**: every other pid, port and control file | `11788, 22592, relay 7777, cores 7781/7786 — kill only by PID` |

A pure-manager split (the main session coordinating and driving nothing) was considered and
rejected as an extra hop with no extra hands. Never with worktree isolation: a worktree cannot
share a live emulator session (`CLAUDE.md`).

**Model: game agents get the top model, not a cheap one.** The cheaper tier is strong where a task
is *known-shaped* — run this probe, tabulate these log lines, apply this edit pattern, stage a
release — and weak where the work is *discovery*-shaped: forming a hypothesis, designing a probe
that cannot fool itself, noticing that two runs only agree because they were phase-locked. Adapter
work here is overwhelmingly the second kind, and this file is full of the evidence: a screenshot
loop whose period divided the walk cycle so every shot looked identical (2026-08-19); a sprite
question that only opened up once `AddOutdoorSprites` turned out to be per-REGION rather than
per-map; three refuted Crystal addresses that each looked settled. **A confident wrong answer here
costs a live test, which costs the user's time — the expensive resource in this project is not
tokens.** So: game-driver agents on the top model; the cheap tier for chores with a written
procedure. If cost binds, tighten the agent's scope and prompt before downgrading its model.

An agent spawned with no model override **inherits the parent's**, which is how the Emerald agent
on 2026-08-19 ran on the top model — correct there, but by inheritance rather than by decision.
Say which, deliberately, each time.

## Every running emulator has a job — 2026-08-19

**The user's rule, stated when two of four instances were sitting idle:** *"can you make it so all
4 instances of bizhawk is actually doing something... the other agents should not slack and have
no good excuses."*

An emulator instance is expensive — host CPU, a window on someone's screen, a core, a relay slot —
and an idle one is pure cost. **If an instance is running, its owner owes it work.**

**The two excuses that turned out to be wrong the day this was written**, both worth recognising
because they sound reasonable:

- **"I am blocked waiting for the user."** One agent had been waiting twenty minutes for ten
  seconds of human input to open a text box — while holding an emulator it was allowed to drive
  itself. The restriction that created the wait ("the user is at these controls") had been true
  earlier and nobody had lifted it. **A blocked agent should say what would unblock it, and then
  go and do that itself if it is permitted to.** If it genuinely cannot, it should do adjacent
  work on the same instance rather than idle.
- **"My measurement is finished."** An instance that has answered its question is a free game with
  an adapter attached, which is exactly what regression testing wants: walk it, open menus, fight
  something, cross a map boundary, and watch the adapter through states nobody scripted. Every
  crowd-test defect this project has found came from doing precisely that.

**The main session is not exempt, and is the likeliest offender**, because it is busy coordinating:
it owns an instance too, and coordination is not a reason for that instance to be parked.

**And it owes an active CHECK, not an assumption** — the user, restating this 2026-08-19 while
three agents were running: *"make sure something is happening on all 4 bizhawk instances, or at
least on the 3 that are being ran by the agents. they have no excuse to slack around and not
do/try stuffs."* An agent that has gone quiet looks exactly like an agent that is thinking, so
the coordinator polls the evidence rather than waiting to be told: each instance's adapter log is
still advancing its frame counter, its `dev-scripts/shots/<game>/` folder has new pictures, and
its loader log shows probes being armed and dropped. Any of the three going flat is the signal to
ask the agent what it is doing — and "waiting" is an answer that needs a reason attached.

**What "doing something" means**, in rough order of value: measuring an open question; playing
toward a state that gates one; a soak or regression run with the adapter attached; banking
savestates at milestones for future sessions. Reporting that an instance is idle and why is
acceptable; leaving it idle silently is not.

## Playing the game, and looking at it — moved 2026-08-19

**`agent_docs/playing.md`** now holds all of it: what an agent may do to a running game, how to
drive input, how to navigate, and how to use screenshots. It grew to a third of this file in one
day, which is how a toolchain record turns into something nobody rereads.

Read it before driving any game. This file stays what it was: host, toolchain, tool and mod
versions, and what each of those is capable of.

## Running several agents on DIFFERENT work at once — 2026-08-19

Two games in parallel is one shape (above). This is the other: agents working on unrelated things
in the same repo at the same time — e.g. one on a Go transport feature, one auditing documents,
while the main session changes an adapter live. It works, and every collision seen so far came
from a **shared resource nobody declared owning**. Declare them up front:

- **Files.** Give every agent an explicit hold list of files it must NOT edit, naming the ones
  being written live, and tell it to *report findings on those instead of fixing them*. A docs
  audit will otherwise walk straight into the file the main session is appending to.
  **`git add -A` is the other half of this**: it sweeps in another agent's half-finished work.
  Stage explicit paths when other agents are running — a probe file belonging to another agent was
  committed by accident this way.
- **Processes and ports.** Name the ports and pids that are live and off-limits. Real cases in one
  evening: an agent's `Stop-Process -Name meshghost-relay` killed another's relay mid-measurement;
  a broad `CommandLine -like '*dev-loader*'` kill took down the other game's emulator; and both
  adapters walking the same bridge range (7778-7785) had one game's adapter attach to the other
  game's core while it was reconnecting. **Set `MESHGHOST_BRIDGE_PORT` per emulator**, and kill by
  **pid**, never by name or a wildcard.
- **The core inherits the emulator's working directory**, which under the dev loader is
  `dev-scripts/`. A `config.json` an agent leaves there silently redirects the *other* session's
  core to its relay — which looked, from the far end, like peers vanishing. Clean up config files,
  and prefer an explicit `-relay` flag over a file when two sessions share a machine.
- **A shared relay is a shared resource with a cap.** One side's load test filled `-max-clients`
  and the other side's core could not join at all; worse, its adapter then respawned a core every
  ten seconds and took that emulator to 5fps. Give a load test **its own relay on its own port**.

**The orchestration itself is the main session's job**, not a background one: the main session
holds the hold lists, the port assignments and the merge order, because it is the only party that
knows what every agent is doing. User's call, 2026-08-19: *"you can manage/orchestrate them if you
think that is the right way to handle it."*

## Crash dumps: where they are, and the tool that reads them without a debugger (2026-08-30)

**Pseudoregalia writes every crash to** `%LOCALAPPDATA%\pseudoregalia\Saved\Crashes\UECC-Windows-*\`
(a `UEMinidump.dmp` plus a `CrashContext.runtime-xml`). Newest first:
`ls -t "$LOCALAPPDATA/pseudoregalia/Saved/Crashes" | head`.

**No debugger is installed on this machine** -- no `cdb.exe`, no WinDbg, no Visual Studio -- so
`dev-scripts/read-minidump.py` parses the dump directly:

```
python dev-scripts/read-minidump.py "<...>/UECC-Windows-XXXX_0000/UEMinidump.dmp"
```

It prints the exception code, the faulting address, the access kind and bad pointer, and **which
loaded module contains the faulting address**, with the offset inside it. That last line is the
one that matters: it says whether the adapter's `main.dll` or the game's own executable was
executing.

**The `CrashContext.runtime-xml`'s `<CallStack>` is usually EMPTY on this game.** Do not read that
as "the dump has nothing" -- it is the reason a whole investigation went guess-first on 2026-08-30.
Method and the cost: `adapters/_template/probes.md`, "READ THE CRASH DUMP FIRST".

## Rig notes carried out of `status.md` (2026-09-02)

`status.md` is an index of what is open, held to one dated line per item; these are how two rigs were
set up and which savestate slots hold what, which is rig knowledge, not status. Moved here verbatim on
2026-09-02. **Slot assignments drift** — re-read the adapter's `UNVERIFIED.md` before trusting one.

- **The Emerald Fly rig** (everything verified down at the end of 2026-08-26: both EmuHawk instances, both cores
  and the relay stopped, both loader targets set to `none`). The Emerald rig was relay
  (loopback, `-send-hz=100`, `-ghost-collision=disabled`) + two cores (7778 and 7779) + two
  BizHawk instances on VANILLA Emerald: instance 1 the FLYER with the dev loader, compare tiers
  and the OAM tier, instance 2 the WATCHER with the dev loader but SHIPPED rendering, so what it
  shows is what a real player sees. **A dev loader on the watcher changes nothing visual** — it
  only lets a probe be swapped without relaunching, which is what made the second half
  measurable. `emerald/probes/fly_probe.lua` runs on both (`MESHGHOST_FLY_OBSERVE` on the
  watcher). Emerald savestates, the user's: **flyer 5 same-town, 6 different-town; watcher 3 and
  4 for the two towns** — pair them so the watcher is where the flyer LANDS, or a run comes back
  clean with the bug still in it (it did, twice). **`run-relay-loopback.bat` has no
  `cd /d "%~dp0"`** — launch with the working directory set, or the exe directly.

- **DRIVE IT YOURSELF.** The user's savestates make a Fly self-testable: slot 8 same-town, slot 9
  cross-town, both "press A to fly", driven by `crystal/probes/fly_drive.lua`. Ask for an
  equivalent state before grinding live cycles at any other expensive-to-reach case — it is what
  ended the 2026-08-26 deadlock (`_template/probes.md`).
- **Savestate slots on that rig, REWRITTEN AGAIN 2026-08-27 — slots 5, 7 and 8 are now the SEAM
  states and no longer what the 08-26 list says:** 1 the user's, **5 one tile north of the Route 40
  / Route 41 seam (on the water, Surf up — encounters possible)**, **7 Route 40 one tile west of
  the Olivine seam (walk LEFT to cross)**, **8 Olivine one tile east of it (walk RIGHT to cross)**,
  **9 a LEDGE HOP (walk down one tile)**, **10 one tile below a WHIRLPOOL (hold Up to re-enter)**,
  **3 the wrong-trainer route**. The fishing and fly states that 7 and 8 used to hold are GONE —
  ask for them again rather than driving the old probes at these. **A log from a savestate-driving probe only means anything against the slot
  as it was that hour** — check before trusting an old one. **And a savestate BAKES IN any ghost
  that was on screen when it was made**, so a driven run showing one character too many is the
  state's fault, not the adapter's; `orphan_sweep.lua` or any door clears it. `crystal/UNVERIFIED.md`. `goto_map`'s undo slot is now overridable (`MESHGHOST_GOTO_UNDO_SLOT`) because its
  hardcoded 8 would eat the fly state. The savestate-is-not-a-save trap: `environment.md`.
  **`MESHGHOST_SQUARE_LOAD_STATE` loads a slot on EVERY re-attach of `square_drive` — clear it.**

## Changing a client setting WITHOUT relaunching the game — kill the core, the adapter respawns it (2026-09-04)

**A UE4SS adapter starts its own core, and it will start another one if that core dies.** So a
config change that only the CLIENT reads — send rate, interp, chaser delay, replay settings,
offline — can be applied mid-session without touching the game window:

1. Edit `config.json` in the install (the `MeshGhostPseudo` folder under `ue4ss\Mods\`).
2. `Stop-Process` the `meshghost` pid.
3. The adapter notices the bridge drop and launches a new core within a second or two.
4. **Confirm from `meshghost.log`, never from the kill** — the new run prints `=== meshghost run
   start ===` and then the settings it read, e.g. `chaser ON -- 1 ghost(s) of your own past, 8s
   behind and then every 2s`.

Measured live 2026-09-04, swapping a chaser from 60s to 8s to shorten a test loop: a new pid
seconds later, reconnected to the running game on its own, no relaunch. **What it does NOT reach:**
anything the ADAPTER reads at startup (its own toggles, the DLL itself), and the recording
restarts, so a `record_on_launch` clip is split in two.

**Why it is worth remembering:** the alternative is a game relaunch, which the root `CLAUDE.md`
calls the last resort, and the user's own words for the slow loop it replaced were *"its mostly
just me sitting around waiting for nothing to happen"*.

## `UE4SS.log` is written with a DELAY, and an empty tail is not a quiet game (2026-09-04)

`UE4SS.log` is buffered: it can sit at **0 bytes minutes into a session** and then arrive in a
lump. Twice in one session that read as "the probe is not running" when it was running perfectly —
once at startup with the file still empty, and once when a genuinely dead probe looked identical to
the buffering.

**So: never conclude anything from the tail of that file without a second reading a little later**,
and prefer a signal carrying its own clock — the core's `meshghost.log` (written by the Go side,
promptly), or a probe line with a sample counter, so a stalled instrument shows as a counter that
stopped rather than as an absence of lines.

## `tasklist` truncates the image name — match `pseudoregalia-Win64`, never the full name (2026-09-05)

A process monitor that grepped `tasklist` for `pseudoregalia-Win64-Shipping` never fired: the column
is cut to `pseudoregalia-Win64-Shipp`. Match a prefix (`pseudoregalia-Win64`), or ask `Get-Process`
by name, which does not truncate. Cost one silent monitor and a launch nobody was told about.
