# Phase 11 — Replays: recording, playback ghosts, the chaser, hotkeys, split times

**A dated record, not current fact.** Each entry says what was true while it was written; paths
and numbers are left as they were. Current state lives in `status.md`; the decisions in ADR 0047
(the replay model) and ADR 0048 (hotkeys in the core process); the roadmap entry in `plans.md`.

**What this phase is.** The wire format is already a replay format: every `protocol.State` carries
its own timestamp, area, position, orientation, anim and extras. A recording is that stream written
to a file instead of a socket; playback is a fake peer fed into the existing interpolation buffer,
so every renderer, adapter and knob works unchanged. On top of that: a "chaser" pack (the player's
own ghosts following N seconds behind), system-wide hotkeys owned by the core, and split times on
the replay ghost's nametag. Game-blind throughout — the adapters need no change for any of it, and
the one adapter-facing hook (the chaser's contact damage) is a per-game follow-on with its own ADR.

**Numbering note.** `phases/README.md` and `phase10.md` said "Phase 11 onward is reserved for the
fifth game and beyond"; this is Go-side feature work large enough to want its own log rather than
another entry in phase 10's component timeline, so it took the number and the fifth game takes the next.

## 2026-09-03 — planned, and Stage 0 written

The user's request, in one conversation: a ghost that trails and can hurt you ("similar to how
Badeline chases Madeline in Celeste"), recordings ("we are already sending/handling everything data
wise that we would need"), start/stop on a hotkey, looping a trick, playback speed, sharing files,
several replays at once, split times, and then the rules that shape it all:

- *"default to just having things in the config, and then per-adapter hotkeys need to be done if
  they are needed"* — and a core-owned key "makes sure it works for any/all adapters".
- *"everything goes into /replay when you record, anything you put into /replay/active would be
  the list of active recordings"* — no config key ever names a file.
- *"collision should always be off for recordings & the trailing ghost that can hurt you. no matter
  what setting you have in the client config. these are meant to be purely cosmetic no matter what"*.
- *"make it possible to pick X number of chasers, each one would have some delay in between so they
  don't just stack on top of each other"* — 4-5 chasers make doubling back a decision.
- *"just want to avoid someone ever being able to share a malicious replay file"* — answered by the
  one-entry-point rule in ADR 0047: a file can do what a stranger in a room can do, and no more.
- On what a recording is: *"1:1 to their gameplay"* — from the moment the player is in the world,
  a watched cutscene replays as a standstill, a skipped one moves earlier, a pause is a pause, the
  main menu is never in it; zone changes ride on `area_id` so a full run is one file.
- Prior art the user asked about (Trackmania, Celeste, Mario Kart — general knowledge, unverified)
  gave the `anchor` header key: restart at the start line, or per area.

**Stage 0 (this entry):** ADR 0047, ADR 0048, this file, the roadmap entry, the status line, the
`ideas.md` pointer, the `security-design.md` entry. Nothing built yet. Stages 1-9 follow, one commit
each: the local fake peer seam; the recorder; playback; seeks and `replay_control`; anchors;
hotkeys; save-last; the chaser pack; split times; the config/packaging/docs sweep.

## 2026-09-03 — Stage 1: the local fake peer seam, built and green

**What:** `core/localpeer.go` — `admitLocalPeer` / `feedLocalPeer` / `dropLocalPeer`, the
`replay:` / `chaser:` id namespace, and the seek primitive (`tickCount` / `awaitTick`, a counter
bumped at the end of `tickRenders`). `render_remote` gained `cosmetic` (`bridge/bridge.go`), set per
frame from the local-peer set in `sendRenderRemote` and frozen in `internal/gameblind`. The rule that
it outranks `ghost_collision` from room and client is in `contract.md`, `_template/PROTOCOL.md` and
`adapters/CLAUDE.md` (folded into the existing session-policy paragraph to hold the 700-line stack budget).

**Test:** `core/localpeer_test.go` — a fed peer renders through the real bridge with `cosmetic:true`
and its nametag; a relay peer through the same core never carries the flag; nothing with the local
id reaches a recording relay transport; drop → despawn on the next tick and a further feed is refused;
after `forgetRelaySessionLocked` wipes the roster the next feed re-admits it. Plus the tick counter and
the id namespace. `run-gotests.bat` green (whole suite twice) and `run-gotests-race.bat` clean on this tree.

**Two things found writing it:** a test core with `c.relay` set must also set `c.relayGame`, or the
adapter's hello is refused as "already connected as game ''"; and there is no `peer_joined` message,
which is why the flag is per frame — the first `render_remote` is how an adapter learns a peer exists.

## 2026-09-03 — Stage 2: the recorder, built and green

**What:** `core/recorder.go` — the tap at the top of `forwardLocalState` (before the rate limit and
before the relay check, so it records offline), a lazily-opened NDJSON file with the header on line
one, a recorder-local seq and `nowMs` timestamps, idle dedupe within the keepalive, a 1s flush clock,
and a time-bounded `sampleRing` the same tap feeds (what save-last and the chaser will read).
`StartRecording` / `StopRecording` / `Recording` / `SetRingSpan`. Record-on-launch arms when the
adapter's hello is answered and stops on its disconnect (`core/bridgeserve.go`). Config: the nested
`replay` block (`record_on_launch`, `save_last`) and flags `-replay-dir` (default: `replay/` beside
the config file, read or not), `-record-on-launch`, `-replay-save-last`; `applyFileConfig` now
returns the absolute config path so the folder can sit beside it. The fake adapter gained `-record
<dir>` and an offline mode (`-relay ""`).

**Seen:** the fake adapter run offline for 3s wrote a 44-line file — header, then samples with seq
1..43, 50ms apart, area and anim intact. The header's `game` was empty on that run because nothing
had set it without a relay; fixed the same hour by recording the game id from the adapter's hello
(`c.adapterGameID`), which the header now prefers over the relay's.

**Tests:** `core/recorder_test.go` — header facts and defaults, one state per line restamped and
stripped of `prev`, no file until the first non-nil frame, dedupe holds a standstill to one line per
keepalive, area changes and nil frames never split the file, an empty recording leaves no file and
disarms the tap, the ring keeps the newest span oldest-first and clears at span 0. `cmd/meshghost`
reads the block and leaves defaults alone when it is absent. Whole suite green twice; race detector
clean; preflight clean.

**Found on the way:** the real client cannot yet record with no relay reachable — a hello that
cannot connect is rejected before `bridge_ready`, so the adapter never sends state. Recording
offline through `meshghost.exe` therefore wants an "offline" mode (accept the adapter, connect
later); filed as a follow-on for the sweep, not built here. The fake adapter's offline mode covers
the dev loop meanwhile.

## 2026-09-03 — Stage 3: playback, built and green

**What:** `core/replay.go` — the loader (`parseReplay`: header sanitized by the nametag functions,
speed clamped 0.1–4, durations clamped, `trim_start`/`auto`, `trim_end`, `skip_gaps` collapsing a
long pause to 1ms with a forced seam, every sample through `protocol.ValidateState`, line length
capped at the wire's `MaxLineBytes` before decoding, timestamps must not go backwards, 2M-sample
memory cap, `.gz` read) and the player (a goroutine per file feeding `feedLocalPeer` at
`start + (t - t0)/speed`, ≤50ms sleeps, seams for a recorded gap > 1.5s / a cut gap / the loop
end, a backwards clock step > 500ms re-based as a seam, the last sample held for one interp delay
plus a render tick before the ghost leaves). `StartReplays` loads `<ReplayDir>/active/` at adapter
attach (cap 16, files for another game skipped by equality, ids are the listing names) and
`launchPendingReplays` — one atomic in `forwardLocalState` — starts them at the player's first
in-game frame, so a ghost of a run lines up with the run. `StopReplays` on adapter detach. Config:
`replay.start_delay` / `-replay-start-delay` as the client-wide default a file's own `start_delay`
overrides (the user's ask, same day). Fake adapter: `-replay-dir`.

**One entry point, enforced:** `internal/gameblind/entrypoint_test.go` walks `core`'s AST and fails
if anything but the relay session and `feedLocalPeer` calls `storeRemoteState`. **Fuzz:**
`FuzzParseReplayNeverPanics` (in CI's list now, fifteen targets across six packages): 20s local
smoke, ~2.9M execs, 275 interesting inputs, no failure; anything accepted passes `ValidateState`.

**Seen:** the fake adapter, offline, played the Stage 2 recording back as `replay:pb.ndjson` —
`render_remote` lines walking the recorded circle, a `despawn_remote` at the loop seam, then the
next lap. **Tests:** `core/replay_test.go` — a 2s clip at 4x finishes in under 1.5s with its header
name and `cosmetic:true`, then despawns; nothing starts before the first in-game frame and a `nil`
frame does not count; the loop is one despawn per lap; a full-run clip a→b→a with 2s gaps renders
only in the player's area and comes back after the gaps; another game's file and a `.txt` are
skipped while a `.gz` loads and a future format only warns; the loader refuses what the wire refuses
(oversized line, bad position, backwards clock, no header, header only, trim leaving nothing) and
sanitizes a hostile header; trim/skip-gap arithmetic; the cap and the id namespace.
`internal/e2e/replay_e2e_test.go` runs it through the real binaries.

**Two bugs found by the tests, both in the first hour:** the gap-collapse read gaps from
already-shifted timestamps and marked two seams for one pause; and the final sample was dropped
before any tick rendered it, so a finishing replay never showed its last position.

**Suite note, same session:** the first two whole-suite runs with Stage 3 in the tree each failed on
one pre-existing test that Stage 3 does not touch — `netx/udpconn`'s
`TestWriteUnreliableDoesNotAllocatePerCall` reported 4 allocations per call instead of ≤1. It passes
5 of 5 in isolation and every other package was green both times, so it is recorded here as a flake
under whole-suite load rather than a regression, and it is the user's to decide whether it goes into
`testing.md`'s traps. Everything replay-related passed on every run.

## 2026-09-03 — Stage 4: seeks, replay-last and the `replay_control` bridge message, built and green

**What:** `core/replaycontrol.go` — `ReplayControl(action, seconds)`, the one entry point every
trigger uses (the hotkeys of Stage 5, an adapter's `replay_control`, a test). Actions:
`record_start` / `record_stop` / `record_toggle` (the recorder), `save_last` (says "not built yet"
until Stage 6), `replay_last` (plays the newest file in `replay/` itself, right now, without moving
it; a second press restarts rather than doubles), `restart` / `rewind` / `fast_forward` (a seek).
The player's run loop was rewritten around a buffered control channel: a seek computes the new clip
time, re-bases the start, binary-searches the sample index and goes through a seam; fast-forward past
the end of a non-looping clip ends it, and a restart or rewind on a finished player relaunches it.
`seconds` ≤ 0 means the configured `replay.seek` (`-replay-seek`, default 5s). Bridge:
`bridge.TypeReplayControl` / `ReplayControl{action, seconds}`, dispatched in `handleBridgeConn`, frozen
in `internal/gameblind`, documented in `contract.md` and the template's `PROTOCOL.md` as an ADDITION
to the core's hotkeys, never a replacement.

**A real race found by the restart test:** the seam waited for "one render tick after the drop",
but a tick already in flight when the peer was dropped satisfied the wait while having rendered the
old peer — so the re-feed landed before any despawn, and the ghost glided instead of jumping. Rewind
happened to pass, restart reliably failed. Fixed with a second counter bumped at the START of
`tickRenders`: a seam now waits for a tick that BEGAN after the drop to finish (`ticksBegun`).
The lesson for anything that drops-then-re-adds a peer: "a tick has passed" and "a tick that saw the
drop has passed" are different facts.

**Tests:** `core/replaycontrol_test.go` — restart is a seam back to the top; rewind lands earlier and
fast-forward later, each through a seam; fast-forward past the end finishes the goroutine and restart
brings it back; the same restart requested over the bridge from the fake adapter works and a nonsense
action only logs; replay-last plays the newest library file, leaves it in place, and restarts on a
second press; record actions route to the recorder; a seek with nothing loaded says so. Whole suite,
race and preflight recorded at the commit.

## 2026-09-03 — Stage 5: system-wide hotkeys in the core process, built and seen working

**What:** `internal/hotkey` — `Parse("ctrl+shift+F9")` into RegisterHotKey's modifier flags and a
virtual-key code (F1–F24 minus F12, A–Z, 0–9, and the named keys space, home, end, page up, page
down, insert, delete; the
Windows key, F12 and a bare key are refused with the documented reason), and `Run`: on Windows one
`LockOSThread` goroutine forces its message queue into existence with `PeekMessageW`, registers every
chord with `MOD_NOREPEAT`, reports each outcome, loops on `GetMessageW` (checking -1), fires on
`WM_HOTKEY`, stops on a `WM_APP+1` posted with `PostThreadMessageW`, and unregisters on the way out;
elsewhere it logs once and blocks. Every constant and call is from learn.microsoft.com, re-read this
session and cited in ADR 0048 (`MSG` including `lPrivate`; `WM_APP` rather than posting `WM_QUIT`
from outside, which its page forbids). `cmd/meshghost`: the `hotkeys` config block (six chords), the
`-hotkey-*` flags, `startHotkeys` wiring each press to `core.ReplayControl` on its own goroutine so the
key loop never waits on a seek or a disk flush. Linux cross-build of the package passes.

**Seen:** the real `meshghost.exe`, run hidden with no relay reachable, logged all six chords bound;
synthetic ctrl+shift+F9 (`SendKeys`) started a recording and ctrl+shift+F5 answered "no replay is
loaded" — the OS hook, the dispatch and the control path, end to end, with no game and no adapter.

**Tests:** `internal/hotkey` — the parser table against the documented values, the refusals, the
string round trip, `Run` registering a real chord on this machine and returning on stop, and the
empty list. `cmd/meshghost` reads the block, leaves absent keys at their defaults, and keeps an empty
string as a deliberate unbind. Whole suite and race recorded at the commit.

## 2026-09-03 — Stage 6: save the last N seconds, built and green

**What:** `SaveLast` in `core/recorder.go` drains the ring — the same tap's last `replay.save_last`
of samples (30s shipped) — into `replay/last-YYYYMMDD-HHMMSS.ndjson` with the usual header, seq
renumbered from 1 and `recorded` set to the oldest sample's moment rather than the key press. The
ring is armed when the adapter attaches (`armRing`, beside record-on-launch), so from the player's
side nothing is ever "on": do the trick, press ctrl+shift+F10, the file is there. Independent of a
manual recording running at the same time. `ReplayControl(save_last)` now routes to it; with an empty
ring it says "nothing to save yet".

**Tests:** `core/recorder_test.go` — 300ms of play with a 100ms span saves at most 100ms ending at
the newest sample, numbered from 1, loads back through the replay parser, and the manual recording
alongside still holds all 30 frames; an empty ring is refused. `core/replaycontrol_test.go` updated
for the route. Whole suite and race recorded at the commit. Not driven with a keypress this stage:
the hotkey→control path was seen working in Stage 5 and save-last is one more case on it.

## 2026-09-03 — Stage 7: the chaser pack, built and green

**What:** `core/chaser.go` — `count` chasers of the player's own past, chaser i running
`delay + i*spacing` behind (the user's design: "4-5 ghosts chasing you ... if you go back somewhere
you were another ghost might be in that position"). Each is a local peer with its own buffered
channel; the recorder tap hands every stamped in-game sample to every chaser without ever blocking
the frame, and a goroutine per chaser sleeps until `sample time + its delay` and feeds it. Ids
`chaser:1..N`, tags `"<name> <i>"` (bare when there is one), colour from config. A gap over 1.5s in
the live stream (menu, loading, nil frames) is a seam for every chaser, so the pack reappears where
the player is. Count clamps to 8 and chasers plus active replays stay under the 16 local-ghost cap.
No relay, no file: it works offline. Config: the `chaser` block (`enabled`, `count`, `delay`,
`spacing`, `name`, `color`, `contact`) and `-chaser*` flags; started at adapter attach, stopped at
detach. `session_policy` gained `chaser_contact` — `"enabled"` only when `chaser.contact` is on —
de-duped together with `ghost_collision`, frozen in `internal/gameblind`, in `contract.md` and the
template as the ONE effect a cosmetic ghost may ever have, honoured only under a per-game ADR and
the user's on-screen confirmation, which no adapter has.

**Two bugs before green, both mine:** `StartChasers` held the pack's mutex while calling the tap's
re-arm, which takes the same mutex — a deadlock the first test found in 40s of silence; fixed by
re-arming after the unlock. And the gap test asked the chaser to reappear at x=100 while the pump kept
feeding x=0 frames — the pack follows the LIVE stream, so it reappeared where the player actually was;
the test was wrong, not the code.

**Tests:** `core/chaser_test.go` — a chaser renders ~10 samples (100ms) behind a walking player,
cosmetic, named and coloured, and despawns on stop; a pack of three at 50ms spacing renders three
peers back-to-front, "Pack 2" in the middle, and count 99 clamps to 8; off by default; a 1.6s
silence despawns it and it comes back where the player is; `session_policy` carries `chaser_contact`
only when contact is on. `internal/e2e/chaser_e2e_test.go`: `-chaser -chaser-count 2` on the real
binary renders `chaser:1` and `chaser:2`, cosmetic, "Shadow 1" named. Whole suite and race at the commit.

**Race detector, same stage:** the three chaser tests set `c.ChaserEnabled` and friends AFTER the
adapter had attached, while the bridge goroutine's `pushSessionPolicy` reads them under `c.mu` — a
test-ordering race (the shipped client sets every field before it serves), fixed by taking `c.mu`
around the test-side writes. Two things worth keeping: `go test -race` run by hand here fails to
build (`runtime/cgo` cannot find `stddef.h` — no C toolchain on the bare PATH), so the race check
goes through `dev-scripts/run-gotests-race.bat` and nothing else; and the detector's first run on
a stage is the run that counts, not the one after the fix.

## 2026-09-03 — Stage 8: split times on the replay ghost's nametag, built and green

**What:** `core/splittime.go` — on every local in-game sample (the recorder tap), for each running
replay: search a window of 60 samples either side of the last match for the nearest recorded
position in the same `area_id` (equality; Euclidean distance over the shared components, capped at 3
units so a player off the ghost's path gets no update); the delta is the player's elapsed time on
their run minus the ghost's elapsed time at that spot, positive = behind; published as `"<name>
+1.2s"` through `storeRemoteNameQuiet` (the same nametag message, without the per-change log line)
at most four times a second and only when the rounded text changes. The header name is clamped to
16 characters so the suffix survives the 24-character cap; the match resets on every seek and lap.
No adapter change: any game that draws nametags shows it.

**Tests:** `core/splittime_test.go` — the ghost walks x 0..99 in a second, the player at half the
pace: by x=40 the tag reads roughly `PB +0.4s` and grows; a player in another area gets no split;
a 24-character header name is clamped and the tag stays under the cap. `core/replay_test.go`'s name
check was loosened to a prefix because the tag can already carry a split by the time it is read.
One detail found by the tests: `SanitizeDisplayName` collapses runs of whitespace, so the planned
double-space separator became one space — the code and the tests now say what actually ships.

## 2026-09-03 — Stage 9: the config, packaging and docs sweep, and where Phase 11 stands

**What:** `packaging/release/config.json` carries the three one-line blocks (`replay`, `chaser`,
`hotkeys`) above `"features"`, so the per-game cut keeps them: the release staging dry run
(`stage-release.ps1 -NoBuild`) was run and TEVI's staged `config.json` showed all three intact
(the per-game files are ignored build artefacts, staged at release time; the root file is the
source). `cmd/meshghost/shippedconfig_test.go` pins that a release never records or chases by
surprise, that contact ships off, and that the six chords match the flag defaults. `docs/config.md`
gained three rows; `packaging/release/README.txt` a REPLAYS section under ADVANCED written for a
player; `adapters/_template/README.md` the paragraph that replays need nothing from an adapter and
that the contact half needs a per-game ADR and the user's on-screen confirmation.

**Where this leaves Phase 11.** Everything game-blind in the plan is built, tested and committed one
stage at a time, whole suite and race detector green at each: the local fake peer seam and
`render_remote.cosmetic`; the recorder (launch-to-quit, 1:1 from the first in-game sample); playback
from `replay/active/` with seams instead of glides; seeks, replay-last and `replay_control`;
system-wide hotkeys in the core process; save-last; the chaser pack; split times; this sweep. Seen
working with no game: the fake adapter recording and replaying offline, and the real `meshghost.exe`
starting a recording from a synthetic ctrl+shift+F9.

**Not built, on purpose:** Stage 4b's anchors (`start` / `area` restart triggers) — the header key is
parsed and defaults to `launch`, the behaviour is a follow-on; the chaser's contact damage in any
adapter (per game, its own ADR, the user's confirmation, Pseudoregalia first); an "offline" mode
for the real client (today a hello that cannot reach the relay is rejected before `bridge_ready`,
so `meshghost.exe` records only with a relay up — the fake adapter's `-relay ""` covers the dev loop).

**What the user has not seen:** any of it in a game. Every claim above is the suite's and the
binaries' offline; nothing here goes into a `VERIFIED.md` until a replay ghost, a chaser and a split
tag are watched on screen. The first live check wants Pseudoregalia with one file in `replay/active/`.
