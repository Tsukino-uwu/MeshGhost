# Phase 11 â€” Replays: recording, playback ghosts, the chaser, hotkeys, split times

**A dated record, not current fact.** Each entry says what was true while it was written; paths
and numbers are left as they were. Current state lives in `status.md`; the decisions in ADR 0047
(the replay model) and ADR 0048 (hotkeys in the core process); the roadmap entry in `plans.md`.

**What this phase is.** The wire format is already a replay format: every `protocol.State` carries
its own timestamp, area, position, orientation, anim and extras. A recording is that stream written
to a file instead of a socket; playback is a fake peer fed into the existing interpolation buffer,
so every renderer, adapter and knob works unchanged. On top of that: a "chaser" pack (the player's
own ghosts following N seconds behind), system-wide hotkeys owned by the core, and split times on
the replay ghost's nametag. Game-blind throughout â€” the adapters need no change for any of it, and
the one adapter-facing hook (the chaser's contact damage) is a per-game follow-on with its own ADR.

**Numbering note.** `phases/README.md` and `phase10.md` said "Phase 11 onward is reserved for the
fifth game and beyond"; this is Go-side feature work large enough to want its own log rather than
another entry in phase 10's component timeline, so it took the number and the fifth game takes the next.

## 2026-09-03 â€” planned, and Stage 0 written

The user's request, in one conversation: a ghost that trails and can hurt you ("similar to how
Badeline chases Madeline in Celeste"), recordings ("we are already sending/handling everything data
wise that we would need"), start/stop on a hotkey, looping a trick, playback speed, sharing files,
several replays at once, split times, and then the rules that shape it all:

- *"default to just having things in the config, and then per-adapter hotkeys need to be done if
  they are needed"* â€” and a core-owned key "makes sure it works for any/all adapters".
- *"everything goes into /replay when you record, anything you put into /replay/active would be
  the list of active recordings"* â€” no config key ever names a file.
- *"collision should always be off for recordings & the trailing ghost that can hurt you. no matter
  what setting you have in the client config. these are meant to be purely cosmetic no matter what"*.
- *"make it possible to pick X number of chasers, each one would have some delay in between so they
  don't just stack on top of each other"* â€” 4-5 chasers make doubling back a decision.
- *"just want to avoid someone ever being able to share a malicious replay file"* â€” answered by the
  one-entry-point rule in ADR 0047: a file can do what a stranger in a room can do, and no more.
- On what a recording is: *"1:1 to their gameplay"* â€” from the moment the player is in the world,
  a watched cutscene replays as a standstill, a skipped one moves earlier, a pause is a pause, the
  main menu is never in it; zone changes ride on `area_id` so a full run is one file.
- Prior art the user asked about (Trackmania, Celeste, Mario Kart â€” general knowledge, unverified)
  gave the `anchor` header key: restart at the start line, or per area.

**Stage 0 (this entry):** ADR 0047, ADR 0048, this file, the roadmap entry, the status line, the
`ideas.md` pointer, the `security-design.md` entry. Nothing built yet. Stages 1-9 follow, one commit
each: the local fake peer seam; the recorder; playback; seeks and `replay_control`; anchors;
hotkeys; save-last; the chaser pack; split times; the config/packaging/docs sweep.

## 2026-09-03 â€” Stage 1: the local fake peer seam, built and green

**What:** `core/localpeer.go` â€” `admitLocalPeer` / `feedLocalPeer` / `dropLocalPeer`, the
`replay:` / `chaser:` id namespace, and the seek primitive (`tickCount` / `awaitTick`, a counter
bumped at the end of `tickRenders`). `render_remote` gained `cosmetic` (`bridge/bridge.go`), set per
frame from the local-peer set in `sendRenderRemote` and frozen in `internal/gameblind`. The rule that
it outranks `ghost_collision` from room and client is in `contract.md`, `_template/PROTOCOL.md` and
`adapters/CLAUDE.md` (folded into the existing session-policy paragraph to hold the 700-line stack budget).

**Test:** `core/localpeer_test.go` â€” a fed peer renders through the real bridge with `cosmetic:true`
and its nametag; a relay peer through the same core never carries the flag; nothing with the local
id reaches a recording relay transport; drop â†’ despawn on the next tick and a further feed is refused;
after `forgetRelaySessionLocked` wipes the roster the next feed re-admits it. Plus the tick counter and
the id namespace. `run-gotests.bat` green (whole suite twice) and `run-gotests-race.bat` clean on this tree.

**Two things found writing it:** a test core with `c.relay` set must also set `c.relayGame`, or the
adapter's hello is refused as "already connected as game ''"; and there is no `peer_joined` message,
which is why the flag is per frame â€” the first `render_remote` is how an adapter learns a peer exists.

## 2026-09-03 â€” Stage 2: the recorder, built and green

**What:** `core/recorder.go` â€” the tap at the top of `forwardLocalState` (before the rate limit and
before the relay check, so it records offline), a lazily-opened NDJSON file with the header on line
one, a recorder-local seq and `nowMs` timestamps, idle dedupe within the keepalive, a 1s flush clock,
and a time-bounded `sampleRing` the same tap feeds (what save-last and the chaser will read).
`StartRecording` / `StopRecording` / `Recording` / `SetRingSpan`. Record-on-launch arms when the
adapter's hello is answered and stops on its disconnect (`core/bridgeserve.go`). Config: the nested
`replay` block (`record_on_launch`, `save_last`) and flags `-replay-dir` (default: `replay/` beside
the config file, read or not), `-record-on-launch`, `-replay-save-last`; `applyFileConfig` now
returns the absolute config path so the folder can sit beside it. The fake adapter gained `-record
<dir>` and an offline mode (`-relay ""`).

**Seen:** the fake adapter run offline for 3s wrote a 44-line file â€” header, then samples with seq
1..43, 50ms apart, area and anim intact. The header's `game` was empty on that run because nothing
had set it without a relay; fixed the same hour by recording the game id from the adapter's hello
(`c.adapterGameID`), which the header now prefers over the relay's.

**Tests:** `core/recorder_test.go` â€” header facts and defaults, one state per line restamped and
stripped of `prev`, no file until the first non-nil frame, dedupe holds a standstill to one line per
keepalive, area changes and nil frames never split the file, an empty recording leaves no file and
disarms the tap, the ring keeps the newest span oldest-first and clears at span 0. `cmd/meshghost`
reads the block and leaves defaults alone when it is absent. Whole suite green twice; race detector
clean; preflight clean.

**Found on the way:** the real client cannot yet record with no relay reachable â€” a hello that
cannot connect is rejected before `bridge_ready`, so the adapter never sends state. Recording
offline through `meshghost.exe` therefore wants an "offline" mode (accept the adapter, connect
later); filed as a follow-on for the sweep, not built here. The fake adapter's offline mode covers
the dev loop meanwhile.

## 2026-09-03 â€” Stage 3: playback, built and green

**What:** `core/replay.go` â€” the loader (`parseReplay`: header sanitized by the nametag functions,
speed clamped 0.1â€“4, durations clamped, `trim_start`/`auto`, `trim_end`, `skip_gaps` collapsing a
long pause to 1ms with a forced seam, every sample through `protocol.ValidateState`, line length
capped at the wire's `MaxLineBytes` before decoding, timestamps must not go backwards, 2M-sample
memory cap, `.gz` read) and the player (a goroutine per file feeding `feedLocalPeer` at
`start + (t - t0)/speed`, â‰¤50ms sleeps, seams for a recorded gap > 1.5s / a cut gap / the loop
end, a backwards clock step > 500ms re-based as a seam, the last sample held for one interp delay
plus a render tick before the ghost leaves). `StartReplays` loads `<ReplayDir>/active/` at adapter
attach (cap 16, files for another game skipped by equality, ids are the listing names) and
`launchPendingReplays` â€” one atomic in `forwardLocalState` â€” starts them at the player's first
in-game frame, so a ghost of a run lines up with the run. `StopReplays` on adapter detach. Config:
`replay.start_delay` / `-replay-start-delay` as the client-wide default a file's own `start_delay`
overrides (the user's ask, same day). Fake adapter: `-replay-dir`.

**One entry point, enforced:** `internal/gameblind/entrypoint_test.go` walks `core`'s AST and fails
if anything but the relay session and `feedLocalPeer` calls `storeRemoteState`. **Fuzz:**
`FuzzParseReplayNeverPanics` (in CI's list now, fifteen targets across six packages): 20s local
smoke, ~2.9M execs, 275 interesting inputs, no failure; anything accepted passes `ValidateState`.

**Seen:** the fake adapter, offline, played the Stage 2 recording back as `replay:pb.ndjson` â€”
`render_remote` lines walking the recorded circle, a `despawn_remote` at the loop seam, then the
next lap. **Tests:** `core/replay_test.go` â€” a 2s clip at 4x finishes in under 1.5s with its header
name and `cosmetic:true`, then despawns; nothing starts before the first in-game frame and a `nil`
frame does not count; the loop is one despawn per lap; a full-run clip aâ†’bâ†’a with 2s gaps renders
only in the player's area and comes back after the gaps; another game's file and a `.txt` are
skipped while a `.gz` loads and a future format only warns; the loader refuses what the wire refuses
(oversized line, bad position, backwards clock, no header, header only, trim leaving nothing) and
sanitizes a hostile header; trim/skip-gap arithmetic; the cap and the id namespace.
`internal/e2e/replay_e2e_test.go` runs it through the real binaries.

**Two bugs found by the tests, both in the first hour:** the gap-collapse read gaps from
already-shifted timestamps and marked two seams for one pause; and the final sample was dropped
before any tick rendered it, so a finishing replay never showed its last position.

**Suite note, same session:** the first two whole-suite runs with Stage 3 in the tree each failed on
one pre-existing test that Stage 3 does not touch â€” `netx/udpconn`'s
`TestWriteUnreliableDoesNotAllocatePerCall` reported 4 allocations per call instead of â‰¤1. It passes
5 of 5 in isolation and every other package was green both times, so it is recorded here as a flake
under whole-suite load rather than a regression, and it is the user's to decide whether it goes into
`testing.md`'s traps. Everything replay-related passed on every run.

## 2026-09-03 â€” Stage 4: seeks, replay-last and the `replay_control` bridge message, built and green

**What:** `core/replaycontrol.go` â€” `ReplayControl(action, seconds)`, the one entry point every
trigger uses (the hotkeys of Stage 5, an adapter's `replay_control`, a test). Actions:
`record_start` / `record_stop` / `record_toggle` (the recorder), `save_last` (says "not built yet"
until Stage 6), `replay_last` (plays the newest file in `replay/` itself, right now, without moving
it; a second press restarts rather than doubles), `restart` / `rewind` / `fast_forward` (a seek).
The player's run loop was rewritten around a buffered control channel: a seek computes the new clip
time, re-bases the start, binary-searches the sample index and goes through a seam; fast-forward past
the end of a non-looping clip ends it, and a restart or rewind on a finished player relaunches it.
`seconds` â‰¤ 0 means the configured `replay.seek` (`-replay-seek`, default 5s). Bridge:
`bridge.TypeReplayControl` / `ReplayControl{action, seconds}`, dispatched in `handleBridgeConn`, frozen
in `internal/gameblind`, documented in `contract.md` and the template's `PROTOCOL.md` as an ADDITION
to the core's hotkeys, never a replacement.

**A real race found by the restart test:** the seam waited for "one render tick after the drop",
but a tick already in flight when the peer was dropped satisfied the wait while having rendered the
old peer â€” so the re-feed landed before any despawn, and the ghost glided instead of jumping. Rewind
happened to pass, restart reliably failed. Fixed with a second counter bumped at the START of
`tickRenders`: a seam now waits for a tick that BEGAN after the drop to finish (`ticksBegun`).
The lesson for anything that drops-then-re-adds a peer: "a tick has passed" and "a tick that saw the
drop has passed" are different facts.

**Tests:** `core/replaycontrol_test.go` â€” restart is a seam back to the top; rewind lands earlier and
fast-forward later, each through a seam; fast-forward past the end finishes the goroutine and restart
brings it back; the same restart requested over the bridge from the fake adapter works and a nonsense
action only logs; replay-last plays the newest library file, leaves it in place, and restarts on a
second press; record actions route to the recorder; a seek with nothing loaded says so. Whole suite,
race and preflight recorded at the commit.

## 2026-09-03 â€” Stage 5: system-wide hotkeys in the core process, built and seen working

**What:** `internal/hotkey` â€” `Parse("ctrl+shift+F9")` into RegisterHotKey's modifier flags and a
virtual-key code (F1â€“F24 minus F12, Aâ€“Z, 0â€“9, and the named keys space, home, end, page up, page
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
loaded" â€” the OS hook, the dispatch and the control path, end to end, with no game and no adapter.

**Tests:** `internal/hotkey` â€” the parser table against the documented values, the refusals, the
string round trip, `Run` registering a real chord on this machine and returning on stop, and the
empty list. `cmd/meshghost` reads the block, leaves absent keys at their defaults, and keeps an empty
string as a deliberate unbind. Whole suite and race recorded at the commit.

## 2026-09-03 â€” Stage 6: save the last N seconds, built and green

**What:** `SaveLast` in `core/recorder.go` drains the ring â€” the same tap's last `replay.save_last`
of samples (30s shipped) â€” into `replay/last-YYYYMMDD-HHMMSS.ndjson` with the usual header, seq
renumbered from 1 and `recorded` set to the oldest sample's moment rather than the key press. The
ring is armed when the adapter attaches (`armRing`, beside record-on-launch), so from the player's
side nothing is ever "on": do the trick, press ctrl+shift+F10, the file is there. Independent of a
manual recording running at the same time. `ReplayControl(save_last)` now routes to it; with an empty
ring it says "nothing to save yet".

**Tests:** `core/recorder_test.go` â€” 300ms of play with a 100ms span saves at most 100ms ending at
the newest sample, numbered from 1, loads back through the replay parser, and the manual recording
alongside still holds all 30 frames; an empty ring is refused. `core/replaycontrol_test.go` updated
for the route. Whole suite and race recorded at the commit. Not driven with a keypress this stage:
the hotkeyâ†’control path was seen working in Stage 5 and save-last is one more case on it.

## 2026-09-03 â€” Stage 7: the chaser pack, built and green

**What:** `core/chaser.go` â€” `count` chasers of the player's own past, chaser i running
`delay + i*spacing` behind (the user's design: "4-5 ghosts chasing you ... if you go back somewhere
you were another ghost might be in that position"). Each is a local peer with its own buffered
channel; the recorder tap hands every stamped in-game sample to every chaser without ever blocking
the frame, and a goroutine per chaser sleeps until `sample time + its delay` and feeds it. Ids
`chaser:1..N`, tags `"<name> <i>"` (bare when there is one), colour from config. A gap over 1.5s in
the live stream (menu, loading, nil frames) is a seam for every chaser, so the pack reappears where
the player is. Count clamps to 8 and chasers plus active replays stay under the 16 local-ghost cap.
No relay, no file: it works offline. Config: the `chaser` block (`enabled`, `count`, `delay`,
`spacing`, `name`, `color`, `contact`) and `-chaser*` flags; started at adapter attach, stopped at
detach. `session_policy` gained `chaser_contact` â€” `"enabled"` only when `chaser.contact` is on â€”
de-duped together with `ghost_collision`, frozen in `internal/gameblind`, in `contract.md` and the
template as the ONE effect a cosmetic ghost may ever have, honoured only under a per-game ADR and
the user's on-screen confirmation, which no adapter has.

**Two bugs before green, both mine:** `StartChasers` held the pack's mutex while calling the tap's
re-arm, which takes the same mutex â€” a deadlock the first test found in 40s of silence; fixed by
re-arming after the unlock. And the gap test asked the chaser to reappear at x=100 while the pump kept
feeding x=0 frames â€” the pack follows the LIVE stream, so it reappeared where the player actually was;
the test was wrong, not the code.

**Tests:** `core/chaser_test.go` â€” a chaser renders ~10 samples (100ms) behind a walking player,
cosmetic, named and coloured, and despawns on stop; a pack of three at 50ms spacing renders three
peers back-to-front, "Pack 2" in the middle, and count 99 clamps to 8; off by default; a 1.6s
silence despawns it and it comes back where the player is; `session_policy` carries `chaser_contact`
only when contact is on. `internal/e2e/chaser_e2e_test.go`: `-chaser -chaser-count 2` on the real
binary renders `chaser:1` and `chaser:2`, cosmetic, "Shadow 1" named. Whole suite and race at the commit.

**Race detector, same stage:** the three chaser tests set `c.ChaserEnabled` and friends AFTER the
adapter had attached, while the bridge goroutine's `pushSessionPolicy` reads them under `c.mu` â€” a
test-ordering race (the shipped client sets every field before it serves), fixed by taking `c.mu`
around the test-side writes. Two things worth keeping: `go test -race` run by hand here fails to
build (`runtime/cgo` cannot find `stddef.h` â€” no C toolchain on the bare PATH), so the race check
goes through `dev-scripts/run-gotests-race.bat` and nothing else; and the detector's first run on
a stage is the run that counts, not the one after the fix.

## 2026-09-03 â€” Stage 8: split times on the replay ghost's nametag, built and green

**What:** `core/splittime.go` â€” on every local in-game sample (the recorder tap), for each running
replay: search a window of 60 samples either side of the last match for the nearest recorded
position in the same `area_id` (equality; Euclidean distance over the shared components, capped at 3
units so a player off the ghost's path gets no update); the delta is the player's elapsed time on
their run minus the ghost's elapsed time at that spot, positive = behind; published as `"<name>
+1.2s"` through `storeRemoteNameQuiet` (the same nametag message, without the per-change log line)
at most four times a second and only when the rounded text changes. The header name is clamped to
16 characters so the suffix survives the 24-character cap; the match resets on every seek and lap.
No adapter change: any game that draws nametags shows it.

**Tests:** `core/splittime_test.go` â€” the ghost walks x 0..99 in a second, the player at half the
pace: by x=40 the tag reads roughly `PB +0.4s` and grows; a player in another area gets no split;
a 24-character header name is clamped and the tag stays under the cap. `core/replay_test.go`'s name
check was loosened to a prefix because the tag can already carry a split by the time it is read.
One detail found by the tests: `SanitizeDisplayName` collapses runs of whitespace, so the planned
double-space separator became one space â€” the code and the tests now say what actually ships.

## 2026-09-03 â€” Stage 9: the config, packaging and docs sweep, and where Phase 11 stands

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

**Not built, on purpose:** Stage 4b's anchors (`start` / `area` restart triggers) â€” the header key is
parsed and defaults to `launch`, the behaviour is a follow-on; the chaser's contact damage in any
adapter (per game, its own ADR, the user's confirmation, Pseudoregalia first); an "offline" mode
for the real client (today a hello that cannot reach the relay is rejected before `bridge_ready`,
so `meshghost.exe` records only with a relay up â€” the fake adapter's `-relay ""` covers the dev loop).

**What the user has not seen:** any of it in a game. Every claim above is the suite's and the
binaries' offline; nothing here goes into a `VERIFIED.md` until a replay ghost, a chaser and a split
tag are watched on screen. The first live check wants Pseudoregalia with one file in `replay/active/`.

## 2026-09-03 â€” Split times become opt-in (`replay.split_times`, off by default)

The user's question on reading the recap: *"off by default? possible to toggle on/off in config?"*
It had been always-on for every replay ghost. Now `Core.SplitTimes`, the `replay.split_times` key and
`-replay-split-times`, default false: with it off the ghost's tag is the header name and nothing
else, which `core/splittime_test.go` pins; the shipped `config.json` carries `false` and
`shippedconfig_test.go` pins that too. `docs/config.md` and the README say how to turn it on. Same
question answered in passing: the `anchor` behaviours that are not built only decide when a replay
starts or restarts â€” zone changes ride on every sample's `area_id` and are unaffected.

## 2026-09-03 â€” Chasers get a spawn window

**Chaser spawn delay (the user: "so they don't just spawn on top of the player right at the start").**
A chaser had appeared exactly `delay` after the player's first in-game sample, at the spot they were
standing then â€” on a player who had not moved, that is on top of them. Now `chaser.spawn_delay`
(`-chaser-spawn-delay`, `0s` = the chaser's own delay): a chaser skips samples until the player has
been MOVING for that long, counted from the first position change and again after any live gap, so
a standing player never gets a chaser and the first appearance is `delay` behind someone already on
the move. `core/chaser_test.go` pins it: 400ms standing still spawns nothing, then movement spawns
the chaser no earlier than the window. Shipped config carries `"spawn_delay": "0s"`, pinned.

**The allocation flake, fixed instead of filed (the user's call)** â€” it is `netx/udpconn`'s, nothing
to do with replays beyond being found during this work, so its record is in `phase10.md`
(2026-09-03, "The udp allocation pin").

**The spawn window met the e2e's standing player, same hour.** `TestChaserFollowsThroughTheRealBinary`
failed on the first whole-suite run after the spawn delay landed: the shared e2e driver sends one
fixed position every frame, which under the new rule IS a player who never moved, so no chaser was
allowed to appear. The rule was right and the test's player was wrong; the chaser e2e now drives a
walking player (`startMovingAdapter`, kept beside that one test â€” every other e2e relies on the fixed
position). Worth remembering whenever a rule keys off "the player moved": a synthetic adapter that
repeats a sample is, to the core, a player standing still.

## 2026-09-03 â€” CI's race job caught what two local race runs missed

The first push of the day: Docs, fuzz (the replay loader's first campaign in CI), the shipping-target
build and the vulnerability gate all green; **the race job red**, on `TestReplayDoesNotStartBeforeTheFirstInGameFrame`
and `TestReplayLoopsWithOneSeamPerLap`. The write: `replayCore` setting `c.ReplayDir` after the
adapter had attached. The read: `StartReplays` on the bridge goroutine, during the hello. Locally the
write always landed before the read; on the runner it did not. Same shape as the chaser-field race the
local run DID catch earlier, fixed then by taking `c.mu` around the writes â€” which was the wrong lesson.
**The right one: a test sets every field the hello handler reads BEFORE the bridge serves, the way
`cmd/meshghost` does, and never after the adapter attaches.** `startLocalPeerCoreWith(t, cfg)` now
runs a hook before `ServeBridge`; `replayCore`, `playingCore` and the split-time tests use it for
`ReplayDir`, `ReplaySeek` and `SplitTimes`. Filed in `testing.md`'s traps.

## 2026-09-03 â€” Three fuzz targets, and what the first campaigns found

**The user's standard:** *"I want the fuzzer to test absolutely everything we could think about and even
things we might forget/miss."* Three targets landed, all in CI's fuzz campaign:

- `internal/hotkey` **`FuzzParseNeverPanicsAndOnlyAdmitsDocumentedChords`** â€” any string a player could
  type; anything admitted must be documented modifiers plus one documented key, never F12, never the
  Windows key, never bare, and must round-trip through `String()`. **Its first campaign found a real
  hole within 15 seconds:** `CTRL+SHIFT+ALT+ALT+0` â€” a modifier named twice was silently folded, so
  `ctrl+ctrl+a` bound `ctrl+a`. Refused now; the fuzzer's input is the regression in `testdata/fuzz/`.
- `cmd/meshghost` **`FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane`** â€” a hand-edited config.json:
  blocks that are strings or arrays, counts of -1 and 1e9, durations of "abc", a BOM, unknown keys. Must
  never panic, and a bad duration must leave the flag default rather than a zero. Clean so far.
- `core` **`FuzzEverything`** â€” one client, random config inside and outside every limit (durations of
  -7s and 48h, counts of -1 and 2^20), a 32-op alphabet over frames (walking, standing, another area,
  nil, NaN positions, 3KB extras, empty area, a million-unit jump), attach/detach, files in
  `replay/active/` (valid clips with every header key randomized, another game's, an oversized line,
  the seed itself as garbage), start/stop, every control action including nonsense, relay join/state/
  leave/welcome with random policies and local-prefixed ids, a session forget (the clock back-step),
  wall-clock gaps, the chaser pack â€” checked after every step against the player's invariants (cosmetic
  on every local render and never on a relay one; nothing local on the wire; the roster and local-ghost
  caps; the core still ticks at the end). No relay sockets, so it runs in CI and under the race job.
  **Its seed corpus found a real hang on the first run:** count 8, spacing 48h â€” legal config â€” sized
  the eighth chaser's queue to 336 hours of samples, a 120-million-entry channel allocated on the
  bridge goroutine, where the next adapter's hello is answered; the game would have sat without
  `bridge_ready` for seconds. Fixed with `maxChaserBehind` (ten minutes) and pinned by
  `TestChaserPackClampsAnAbsurdSpacingFast`. **Found the honest way:** the failure message now carries
  every goroutine's stack, and the stack said "runnable inside `StartChasers`", not "blocked".

**Also today:** CI's race job caught a test-ordering race two local race runs had missed (the entry
above), and the udp allocation pin was hardened (`phase10.md`). Filed, not built: a replay schedule
fuzzer and per-adapter fuzzers in each adapter's language behind path-gated CI jobs (`ideas.md`).

**Cost, same afternoon:** the first two-minute campaign ran 1,949 inputs, but its first forty seconds
managed twenty, on the seeds' long gaps; the per-step pacing went 3ms â†’ 1ms and the `gap` op's sleeps
were capped at 350ms (still long enough to cross a compressed stale window and, at the top entry, a
chaser seam), and a 30s campaign then ran 842 inputs. The user's point that a day-long session should
condense into seconds is only half met â€” the per-Core timings compress, the wall-clock reads and
sleeps do not â€” and the full answer, an injectable clock, is filed in `ideas.md`.

**`name_color` ships prefilled (the user, 2026-09-03, reading Pseudoregalia's staged file):** the file
carried `""` while `docs/config.md` already said `#A89975`; now the shipped root file carries the example
hex, the per-game cut inherits it, the README line says the prefill is an example and `""` removes the
box, and `TestShippedConfigDeliberateDivergences` pins it with the reason. Harmless while `name` is
blank -- a colour is ignored without a name.

**CI's first fuzz campaign on the new targets, same evening:** the race job went green on the
test-ordering fix; the fuzz job went red on `FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane` in
eleven seconds â€” `"save_last":"0s"`. Not a bug in the client: a wrong invariant in the fuzzer, which
called any zero duration "a bad value zeroed the default" when a parsed `0s` is a value the player
chose. The invariant now distinguishes an unparseable duration (must keep the default) from an explicit
zero (allowed), CI's `fuzz-failure-corpus` artifact is the regression in `testdata/fuzz/`, and a 45s
local campaign is clean. A fuzzer's first campaign tests the fuzzer as much as the code.

**CI's race job, third time today, and this one was a shipped-path bug of mine:**
`TestARelaunchedGameIsANewIdentityNotAResumedOne` â€” a relaunched game came back as the same player id.
Green locally twenty of twenty. The cause: this phase put `StopReplays`, `StopChasers` and
`StopRecording` in the bridge disconnect handler AHEAD of the goodbye to the relay, and those waits
(up to a second per player or chaser mid-seam) sat between the socket closing and the Leave; a game
relaunched inside that window was handed its old identity back under the relay's resume grace. The
goodbye now goes first and the local ghosts are torn down after â€” the relay must hear the departure
before anything that can wait. The lesson beside the earlier two: anything added to a disconnect
path goes AFTER the message that releases the identity, and a loaded runner is where that ordering
shows.

## 2026-09-03 (evening) â€” WATCHED, for the first time: recording, playback and the chaser pack

**The user, after testing in Pseudoregalia:** *"replay/recording & chaser is confirmed to work,
tested both in pseudoregalia"*. Stages 1 through 9 were built earlier the same day with the suite
and the race detector green at every one, and this log and `status.md` had both carried "nothing
watched in a game yet" since. That line is now retired. Recorded in `verified.md` on the
human-gated track.

**What the session ran, because it changes what the confirmation covers.** The deployed client was
built at 19:06; the cosmetic-flag fix (`73615c56`) edited its source at 19:22. So this ran PRE-fix
code. The confirmation stands on its own â€” recording, playback and the chaser pack demonstrably
work â€” but that fix is not covered by it, and it is exactly the kind that would hide here: it makes
a replay or chaser ghost render `cosmetic=false` for a single frame during a SEAM, so it needs a
restart, a lap or a recorded gap to occur at all, and with `chaser.contact` false by default it may
produce nothing visible even then. Watching for it wants a deliberate seam with contact on.

The fixed client has since been deployed to every install except the one the running game holds
open; that copy updates when Pseudoregalia next closes.

**Still unwatched**, so the phase is not done: split times, anchors, the chaser's contact damage,
the offline client mode, and replay/chaser rendering on the other three adapters. Those go through
the same core path, but "the same code" has never been this repo's standard for a visual claim.

## 2026-09-03 (late) â€” Local ghosts are drawn one full interpolation delay late

**Found by reading, not by watching, and it is arithmetic rather than a theory.** Three facts in
shipped code, each with its own line:

- `core/chaser.go:86,137-138` â€” a chaser stamps `s.Timestamp = due`, where `due = original +
  ch.delay`, and feeds it at wall time â‰ˆ `due`.
- `core/replay.go:476,499-501` â€” a replay player does the same against its clip's own schedule.
- `core/remotes.go:233` â€” `tickRenders` draws EVERY remote at
  `renderTime := c.nowMs() - c.InterpolationDelay.Milliseconds()`, one number for all of them,
  shipped at 450ms (ADR 0046).

A local ghost reaches that buffer through `feedLocalPeer` -> `storeRemoteState`, the same path a
relay peer takes (ADR 0047), and **nothing subtracts the interpolation delay back for a peer this
core invented**. Two consequences:

1. **A chaser configured for 3s is drawn 3.45s behind** â€” the headline knob is off by 15% â€” and a
   replay runs 450ms behind its own schedule.
2. **The split time measures a ghost nobody can see.** `core/splittime.go:126-128` searches the
   clip's RAW samples for the player's current position and compares against `now`, independent of
   render time, so the nametag reads `+0.0s` while the visible ghost is still 450ms short of that
   spot. Racing is the one feature where that is the whole point.

**Why `interp = 0` for local peers is NOT the fix**, since it is the first thing anyone will reach
for: render time would land exactly at the newest fed sample, `atAhead` (`core/interp.go:317-342`)
would take its past-the-newest branch, and with `Extrapolate` defaulting to 0 it holds the last
sample. That trades a smooth 450ms offset for a stair-step at the feed rate. The fix is a per-peer
render time â€” a local ghost needs one or two sample intervals, not 450ms â€” designed in the plan
this entry accompanies, and cross-referenced from `ideas.md`'s per-ADAPTER interp entry, which is
the same knob on a different axis.

**Why no test caught it.** `core/localpeer_test.go:27`'s `startLocalPeerCore` sets
`InterpolationDelay = 0`, and `internal/e2e/e2e_test.go:347`'s `startClient` hardcodes
`-interp 0ms` for every end-to-end test. At interp 0 the defect is invisible by construction, at
both levels at once â€” the chaser test really does measure its 100ms delay correctly, and would go
on doing so forever.

### Measurements taken while investigating, none of which had a home before

**The recorder's rate, from a real 3-minute Pseudoregalia clip:** 15,762 samples, 87.5 Hz average,
gaps of 5 to 12ms. That is the GAME's frame rate, not the send rate, and it is deliberate: the
recorder taps at the top of `forwardLocalState` (`core/sending.go:55`) BEFORE the rate limit and
before the relay check, so a recording is never rate-limited and the 15 Hz `DefaultSendHz` never
touches it. The file cost that implies â€” ~983 B/sample, ~310 MB/hour â€” is filed in `scaling.md`
with the measured shrink options.

**Replays and the chaser work with no relay -- IN THE CORE.** Confirmed by driving that real
recording through `meshghost-fakeadapter -relay ""`, which rendered `render_remote replay:...` with
no relay in existence. **CORRECTED 2026-09-03 from the user's own game log, and the correction is
the useful half: that is NOT true of the shipped client.** With no relay reachable, an adapter's
hello reaches `ConnectRelayOnAdapterHello`, the dial fails, and `bridgeserve.go:210` REFUSES the
adapter (`core: refused an adapter: core: dial relay: ... actively refused it`, once per hello as
the mod retries every ten seconds). No adapter means no in-game frames, so the recorder tap never
runs and `record_on_launch` writes NOTHING -- seen live in Pseudoregalia on 2026-09-03 with the
recorder armed and not one `core: recording to` line in the log. The tap sitting ahead of the relay
check makes recording independent of the relay INSIDE the core; it does not get the adapter past
the door, and `armRing`/`RecordOnLaunch` are downstream of the accept. So what is missing is not
cosmetic noise, it is the MODE â€” `meshghost.exe -relay ""` is an error, not a
choice. Measured cost of the retry it leaves running: one log line per 60 seconds and one refused
dial per 15 seconds, neither on the frame path. Calling that cosmetic, as this entry first did, was wrong: without the mode there is no solo session at all, so this is a blocker rather than log noise. The
user's call on the shape (2026-09-03): an `offline` boolean shipping as `false` in the root
config, an advanced setting, and deliberately NOT in any per-game override file.

### Built the same evening: the per-peer render time, an offline mode, and smaller recordings

**All three are Go-side, so they are confirmed with the tools rather than watched** (`CLAUDE.md`):
`go test ./...` green, `internal/e2e` included, and each regression test verified to FAIL on a
deliberately reintroduced defect before being kept.

1. **Per-peer render time â€” ADR 0049.** `remoteStatesAt` now takes `now` and subtracts per peer
   class: `DefaultInterpolationDelay` (450ms) for a relay peer, the new `DefaultLocalGhostDelay`
   (25ms) for a `replay:`/`chaser:` id. The end-of-clip hold and the split time moved with it. Three
   things that would have broken quietly and were handled in the same edit: local peers are kept out
   of the `dry` meter (a NETWORK statistic â€” otherwise every adapter hitch reads as a bad connection
   for anyone running a chaser), `dryLoggedAt`'s throttle moved to `now` (two render times in one
   shared field), and `Extrapolate` is forced to 0 for a ghost whose future is already on disk.
2. **`offline`** â€” `false` in the shipped root config, absent from the per-game files (the user's
   call). Enforced in `ConnectRelayOnAdapterHello`, the one funnel both dial paths pass through; a
   guard on the startup retry loop alone would have left an adapter's own hello dialling anyway.
   The e2e test **binds the relay address itself and counts accepts**, so "never dialled" is proven
   by a listener rather than by reading a log.
3. **Recordings gzip and round** â€” `replay.gzip`, on, with a plain escape hatch. 33.5x together on
   the user's real clip, ~310 MB/hour down to ~9. The rounder COPIES rather than rounding in place,
   because the ring and the chasers hold the same `State` and trimming a file must not change what a
   live ghost renders. Delta encoding stays filed, not built (`ideas.md`, `scaling.md`).

**The lesson worth keeping, and it is about test helpers rather than about interpolation.** The
defect was three lines apart in three files, arithmetically obvious once written down, and it
survived a full suite plus an e2e suite plus a fuzz target â€” because **every helper that touches a
local peer pinned the interpolation delay to zero**, for the good reason that a fed sample then
renders on the very next frame. At zero the defect cannot exist. A helper's convenience default is
a blind spot in the exact shape of the thing it makes convenient, so when a bug turns out to be
unreachable by the whole suite, look at what the helpers hold constant before looking at the code
again.

**Still owed on screen, and it is genuinely a look rather than a measurement:** a 3s chaser that
looks 3s behind, and a split time that agrees with the ghost the player can see.

## 2026-09-04 â€” Three defects the user found by playing, and a documentation pass

**The session's shape is worth keeping: every finding below came from the user running the game,
and each was a different KIND of miss.**

1. **`record_on_launch` wrote nothing, and it was not the recorder.** The log said
   `core: refused an adapter: core: dial relay: ... actively refused it` once every ten seconds:
   no relay was running, so the client refused the game, so no frames arrived, so the tap never
   ran. Fixed by ADR 0050 (a downed relay keeps the adapter and retries in the background) after
   the user's *"i just assumed both recording & playing back would work offline/without a
   server"* -- which is the right expectation, and Phase 11 is what made it right: recording and
   replays became solo features while the client still refused to start a session without a
   multiplayer server. **Two tests that pinned the OLD behaviour had to be rewritten**, and one of
   them, `TestARelayFailureRejectionSaysRelay`, guards a contract with all four adapters (they
   match "relay" in a reject reason to tell "wait here" from "walk to the next port"). It is now
   two tests: a downed relay must NOT reject, and a permanent refusal still must.
2. **A gzipped recording would not open.** *"Error 0x8000FFFF: Catastrophic failure"* from
   Explorer, and 7-Zip refused it too. `gzip -t`: `unexpected end of file`. The client exits
   through `watchParentPID`'s `os.Exit(0)` when the game closes -- the NORMAL end of a session --
   which ran no cleanup, so the gzip footer was never written. Every byte of data was intact.
   Two fixes, because there were two faults: the exit path now closes the recording, and plain
   text became the default with the size moved into per-key delta encoding (ADR 0051, 4.5x, still
   editable). **The ordering lesson: a format whose failure mode is all-or-nothing is the wrong
   default for an artefact produced by a process that is routinely killed.**
3. **A hostile display name exposed our own JSON parser.** `json_string_field` scanned for the
   next bare quote, so an escaped quote truncated the value: the nametag read `uwu325235#\`. Both
   Pokemon adapters had their decoders fixed on 2026-09-03; this was the sibling that was missed.
   Filed as READY in `pseudoregalia/UNVERIFIED.md` along with the title-screen gate, which came
   from the same recording: the menu is a real level with a real pawn, so the "no pawn" branch
   never fired and every clip opened with dead frames.

**What the user reported and asked to be logged rather than chased:** the player's own SFX go
quiet while ghosts are audible. Two shapes fit and they want different fixes -- a path escaping
the silence clause, and Unreal sound concurrency stealing the player's voices. `UNVERIFIED.md`.

**The fuzz targets stopped standing up sockets.** Both bridge-driving targets opened a listener per
iteration, which exhausts Windows' ephemeral ports in seconds; `FuzzEverything` died loudly and
wrote a corpus file that passes on re-run, and `FuzzScheduleConvergence` swallowed the error and
spent the rest of every campaign with NO ADAPTER ATTACHED. They now serve the real bridge over
`net.Pipe`. A 2-minute campaign went from ~2,000 executions to 51,632. `testing.md`, Traps.

**A documentation pass, driven by the user comparing the root README to a project they admire:**
the transports and good-to-know sections are gone (nothing lost -- `docs/security.md` and
`docs/config.md` already carried it), the opening states its promises instead of arguing for them,
and replay ghosts have a paragraph near the top because nobody scrolling past the fold knew they
existed. 274 lines to 200. Three conventions came out of it and are now in `agent_docs/README.md`:
describe our features on their own terms, keep the root README minimal, and **write the invariant,
never the inventory** -- "none of the shipped games do X" is true until it is silently false.

## 2026-09-04 (later) â€” a tester used the replay hotkeys, and one third of the report was a real defect

**The report, and it is the useful kind because it is about USING the feature rather than whether it
works:** *"being forced to use keycombinations is a bit annoying for usage, but fine enough. Also not
having any feedback except when looking at the console log is not great. And at least right now I
can't discern from the console log whether a record toggle started or stopped the recording"*.

**The third part was a real defect and is fixed.** `ReplayControl` returned only an error, so both
callers â€” the system-wide hotkey in `cmd/meshghost` and `replay_control` over the bridge â€” logged
`"done"` whichever branch ran. On `record_toggle`, one key means two opposite things, and the line
belonging to the key just pressed was the one line that said nothing. It now returns a short account
of what it ACTUALLY did (`recording STARTED -> path`, `recording STOPPED -- N sample(s) -> path`,
`REWIND 5s`), the toggle reuses the same wording as the explicit start/stop actions so the log cannot
depend on which key was pressed, and `TestRecordToggleSaysWhichWayItWent` pins that the two
directions describe themselves differently and non-emptily.

**A claim I put in the first draft of that comment was wrong and is corrected in place**, because it
would have misled the next reader: I wrote that a start was SILENT. It is not â€” `StartRecording`
logs `core: recording to <path>` (`recorder.go:543`) and `StopRecording` logs its own line, so the
recorder does distinguish the two. The fault is narrower and still real: those lines are the
*recorder's*, phrased for the recorder, and the *hotkey's* line sat next to them saying `done`. Found
by reading the test's own output rather than by re-reading the code, which is the argument for
running the thing rather than grepping it â€” the first grep looked 22 lines into a 35-line function.

**The other two are design questions and are logged, not decided** (`ideas.md`, "Replay hotkeys"):
whether a bare single key should be allowed for a system-wide hook at all, and â€” the one that
actually matters â€” that a player mid-run cannot read a console window, so real feedback means a
bridge message the adapter renders, which needs an ADR. The description this fix produces is exactly
the payload such a reply would carry, so the expensive half of that is already done.

**Go side, so verified with the tools rather than by watching:** full `run-gotests.bat` green
including `internal/e2e`, root binaries rebuilt, and `meshghost.exe` redeployed to all six copies
across the four game installs.

## 2026-09-05 â€” the chaser gets gameplay time, and a tap sized to what the adapter actually sends

**Backfilled 2026-09-11** â€” the day's detail is in [phase10.md](phase10.md)'s 2026-09-05 entry;
this is the pointer that entry needed here. `72741a66`: **the chaser runs on gameplay time**, which
stops while the adapter says the player is frozen (ADR 0053). `02d689b7`: the tap hands the pack at
most 100 samples a second â€” **the queue had been sized for that while the adapter sends ~180**, so
the sizing and the source disagreed about the same number.

## 2026-09-07 â€” the chaser pack shares one history

**Backfilled 2026-09-11**; detail in [phase10.md](phase10.md)'s 2026-09-07 entry. `29081776`: the
pack shares one history instead of a queue each. `2460ffe5`: `StartChasers` reads its config under
`c.mu` rather than bare â€” the same settings-race class the 2026-09-09 entry below closes for the
whole config.

## 2026-09-06 â€” the documentation fact check, as it touched the replay docs

No code changed. `plans.md`'s Phase 11 section still said "nothing watched in a game yet" and put
recordings "under the client's config folder": rewritten to say what has been watched, on
Pseudoregalia only (two recordings from a zip and a quoted name 2026-09-04; the chaser through a
pause and under ~180Hz 2026-09-05; the indicator twice 2026-09-05), shipped in v1.1.5 through
v1.1.7; the `replay\` folder sits beside `meshghost.exe`, which is the game's root for TEVI and
Pseudoregalia since 2026-09-05; recordings are delta-encoded (ADR 0051); the chaser renders on its
own delay (ADR 0049) and gameplay time (ADR 0053). `docs/config.md` documents the three
`replay.indicator*` keys, read by the game's mod rather than by `meshghost.exe`. `architecture.md`
lists the three bridge types this phase added. The follow-ons in this file's own list are unchanged
and still unwatched.

## 2026-09-06 (later) â€” the root `CLAUDE.md` trimmed to 183 lines, cap lowered to 200

No code changed. The user chose the ~200-line root over a 60-line one after seeing both; the record
of that choice, the sketch and the reasoning is `agent_docs/claude-md-cap.md` (the seventh case), and
the pass itself is logged in `agent_docs/doc-history.md` ("The root trim (2026-09-06)"). Six rules moved
to the nested `CLAUDE.md`s, the stack budget went 700 â†’ 650, preflight is green. Nothing in this phase's
own list changed.

## 2026-09-06 (later still) â€” the FPS that outlives a ghost: the camera rig, found by a full census

**The user's report:** frame rate down after every ghost despawn (peer, replay or chaser), fine in
the pause menu, back only after "reset to last save" or a zone change; 70 fps after 150 ghosts.

**What happened.** Windows Defender had quarantined the game root's `meshghost.exe`
(`Trojan:Script/Wacatac.B!ml`, a false positive on the unsigned Go binary) at the previous launch,
so the adapter found no core; the rig ran off the repo's own `meshghost.exe` with the game root as
its working directory, plus a local relay. A full-object census probe (`probe_leakcount/Scripts/
census.lua`, through the scratch slot) with two fake peers found every ghost object collected within
90s except `BP_PlayerCam_C`, the camera rig each ghost pawn spawns, still ticking with no owner.
Uncapped (`t.MaxFPS 0`, user's go-ahead): 0 / 36 / 68 orphan rigs = 1.68 / 2.7 / 3.4 ms a frame,
~0.025 ms per rig â€” real, and short of the 70 fps the 150-ghost session showed, so something else is
left by that path too. The probe crashed the game once on a hot-reloaded second load (a Lua error
inside `ForEachUObject` aborts the process); rewritten with a collect-only callback and one request
loop. Fix built: `GHOST_DESTROY_ORPHAN_CAMERA_RIGS` destroys the rig with the ghost and sweeps
orphans; unwatched as of this entry. User's next test, their words: *"spawn/despawn 150 ghosts a few
times, and see if the fps baseline stay the same or not"*. User also asked for the per-ghost
component inventory to vet what a ghost can do without (listed in chat from the census; the
candidates that tick are the pawn's two spring arms, `DialogueCam`, the auto-possessed
`AIController`, and `CharMoveComp`). Records: `UNVERIFIED.md` 2026-09-06, `pitfalls/by-lesson.md`
2026-09-06, `PROBES.md` (`census.lua`).

**Result, same session.** New DLL, fresh launch, cap lifted, three rounds of 150 fake peers: after
every round the world is back to one `BP_PlayerCam_C` and one pawn and the frame time back on the
pre-round baseline (1.5-1.9 ms vs 1.76-1.78 before; one 2.12 ms sample at the end, counts clean).
3,476 rigs destroyed by `release_ghost`, the sweep never fired. Peer-path despawns leave nothing
else behind. The user corrected an attribution here: their 70-fps session was 150 FAKE PEERS (before
the first performance work), not replays or chasers, so the rig leak accounts for it; the
recording/chaser despawn path is next at their request. The rounds themselves ran at 2.5 fps with
689-984 pawn objects alive because the relay kicks fake clients that cannot drain 149 peers' streams
and they reconnect -- the load rig's limit, recorded in `UNVERIFIED.md`. Preflight green (FindAllOf
ratchet 49 -> 51, both new sites named per-event / per-interval). The uncapped state lives only in
that game process. Committed; the install carries the first build of the same code, the comment-only
rebuild redeploys at the next game close.

**Later the same session -- the other two despawn paths, the local-ghost caps, the dump probe.**
Replays: ten copies of a 20s clip recorded offline by the fake adapter (`-record`), dropped in the
game root's `replay/active/`, played by three core restarts; after each round one rig, one pawn,
frame time in the baseline band. Chasers: five enabled in the config (a failed PowerShell `-replace`
truncated `config.json` to 3 bytes on the way; restored from the backup taken a line earlier -- edit
configs with Python, never a one-line PowerShell replace), the user walked, six pawns counted, the
core killed so they left by the bridge-drop path: five `CAMRIG release_ghost` lines, one rig, one
pawn, 1.85 ms. **All three despawn paths clean on the new DLL.** A tester had been stopped at 8
chasers the day before; that was the core's own `maxChasers`, with `maxActiveReplays` 16 over
replays and chasers together -- neither ever had anything to do with the relay. Both removed on the
user's call (*"allow people to do as much as their game can handle"*); the one bound left is the
roster's 512 seats, which a fuzzed count of 1<<20 is clamped to rather than allocating a million
queues. Tests pin the new behaviour (99 asked = 99 started; 19 files = 19 loaded). And `probe_dump/`:
any live object's properties as JSON without dereferencing a pointee -- first run on the local pawn
with 28 components, 3,015 properties, 0 errors; the tool for the component vetting the user wants
next. It sits in the deployed scratch slot for now; the pristine stub goes back at the session's end.

**2026-09-07 -- CI caught a data race in `StartChasers`, the cap-removal commit's own blind spot.**
The user brought run 34135127729: four jobs green, "Build, vet, test (race)" red. Two `WARNING: DATA
RACE` reports, both on `Core.StartChasers` reading `ChaserEnabled` (chaser.go:189) and `ChaserDelay`
(:200) with no lock, against the chaser test setting the same fields under `c.mu`. Not a test-only
artefact: `StartChasers` is called from the bridge goroutine when the adapter attaches
(`bridgeserve.go:182`), and `c.mu` is what guards those fields everywhere else -- `pushSessionPolicy`
reads `ChaserEnabled`/`ChaserContact` under it. The cap-removal work of 2026-09-06 added the test
that writes them at runtime, which is what gave the detector a second writer to see; the bare reads
predate it. Fix: one snapshot of all seven `Chaser*` fields under `c.mu` at the top of
`StartChasers`, with the clamping and sanitising moved onto the copies, off the lock -- no behaviour
change, and nothing under the snapshot takes `c.mu`, so no nesting. `run-gotests-race.bat`
(`-count=3`, CI's exact command) clean across all 18 packages; the re-push, run 34138905025, green on
all five jobs. The lesson is the one this repo already had in a different shape: **a green
`run-gotests.bat` is not a green CI** -- the local script cannot run `-race`, so a lock convention
that lives only in the other readers of a field goes unenforced until CI says otherwise.

**2026-09-07 -- the ~350-ghost ceiling: a slow adapter was being killed for being slow, and a
1.69 GB allocation nobody had noticed.** The tester's second report at ~350 ghosts read as the
2026-09-06 fix having failed, and it was the opposite: their own words, *"seems to not create a new
Client and instead become able again to reuse it's old one (though it deletes all the prior
chasers)"*, are that fix working -- no second core, ~10 failed sends instead of ~1,200. What it
never addressed was WHY the write timed out, because it was a recovery fix, not a cause fix.

Three ceilings existed, and only one had been under discussion. **Bridge throughput**: one
`render_remote` per remote per frame is 92,160 messages and 35.0 MB/s at 512 ghosts and 180 Hz,
against an adapter parsing a fraction of it. **Chaser memory**: 1.69 GB of channel buffer for the
tester's exact config, allocated on the bridge goroutine at attach and again at every reconnect --
found while reading the sizing arithmetic for something else, and never suspected. **Adapter render
cost**: still only measurable in the game.

Fixed in four commits, each verified Go-side before the next: the shared chaser history
(1.69 GB -> 7.20 MB, and flat in the count rather than quadratic); `throttledConn` plus a fuzzed
drain rate, which is what made the defect reproducible headlessly at all; the coalescing bridge
writer; and the reporting the user asked for. **The reproduction is the part worth keeping**: both
fake adapters in `core` were unable to express a slow reader -- one drains as fast as Go can, the
other stops dead -- so a defect that had hit a tester twice could not be produced by any count,
however large, in any test. The instrument was missing, not the effort.

Two of my own mistakes in the session, both caught by measurement rather than review. The
line-counting instrument in the new test used a size-1 buffered channel with a non-blocking send,
which keeps the FIRST unconsumed value: it reported "2 lines" where 28,415 had arrived, and it
looked exactly like a finding. And the caught-up condition in the writer compared the dropped count
against its value when the behind-period BEGAN -- a number that only grows, so the "keeping up
again" line could never have printed. Both are the same shape as the repo's standing rule that a
diagnostic can break the thing it measures.

The user's calls, made in the same exchange: the chaser pack still resets on a reattach (the
proposal to carry it across only mattered while a slow adapter could be disconnected, and a game
restart is a new session); the slow-bridge condition is reported both as one log line each way and
as a running count in `Stats`; and the batching half is left open with its benchmark rather than
taken on speculatively.

**2026-09-07 (evening) -- the live run, and the decision it settled.** The user ran 512 chasers on
the deployed build: all 512 admitted, zero re-admissions, no timeout, no failed send, clean
shutdown. The bridge half is done. The run also produced the log-flapping fix -- 23 of 31 episodes
reported a single superseded position -- and the threshold that replaced it was read off this run's
own numbers rather than guessed, which is the argument for having run it at all.

**Batching (`render_frame`) was measured and then DECLINED**, the user's call: *"think its probly
fine as it is now without B2 ? worst case we can always fix it later if it still endsup being an
issue"*. The benchmark is kept in `ideas.md` with the condition that would revive it. The reasoning
is worth keeping because it inverted mid-session: batching was proposed as the real fix while the
bridge was believed to be the wall, and by the time it could have been built the coalescing writer
had moved the wall to the game's own render cost -- 5-7 fps at 512 ghosts, measured on screen. A
plan made against a ceiling that has since moved is not a plan worth executing.

Left open and NOT a defect yet: some ghosts looked stuck in that run, with a confound I introduced
(100ms chaser spacing is shorter than a frame at 5-7 fps) -- `pseudoregalia/UNVERIFIED.md`.

**2026-09-07 (night) -- CI caught what the local race job could not, again.** The push went green on
four of five jobs; "Build, vet, test (race)" failed all three counts of
`TestGhostCollisionNotPushedBeforeTheRoomHasSpoken`. Not a data race -- a logic failure this session
introduced and could not see locally, where `run-gotests-race.bat` (`-race -count=3`, CI's exact
command) had just been clean.

The cause is the one real behavioural change in the coalescing writer: **`sendToAdapter` enqueues
now, so it returning no longer means the adapter has the message.** Ordering is still exact -- one
queue, one writer -- but delivery is asynchronous, and that test pushed a session policy and read
the adapter's inbox on the very next line. On this machine the writer goroutine won; on CI's slower
Linux runner under the race detector it lost, three times out of three.

Fixed at the root rather than in the one test: `sessionPolicies` now waits for the queue to drain
before reading, via a `waitAdapterDrained` helper, so a future test asserting on adapter delivery
cannot reintroduce the race by writing the obvious thing. The hazard is stated on `sendToAdapter`
itself, where someone will actually meet it.

Only one test in the package was exposed (it is the only one that assigns `attachedAdapter` to a
recording transport directly), which is the reason the blast radius was one line rather than a
sweep. The standing lesson holds and gained a sharper edge: **a green local race run is not a green
CI** -- previously that was said of `run-gotests.bat`, which cannot run `-race` at all; this time
the local race job itself was green and still wrong, because the defect was a timing window that
only a slower machine opens.

## 2026-09-08 â€” the input track: recording what the player pressed, as a second track

The user's ask, and the reasoning is theirs: record inputs as their own thing, because an input
record *"can't get outdated if we ever start to sync more things"* â€” and, the stronger half, because
re-driven it *"would reproduce what the game actually does instead of missing things we are not
syncing"*. A recording reproduces the fields we sync; everything the game does that we do not sync
(VFX, sound, montages, ability logic) is absent from a replay, and every gap in it is a 1:1 miss
found by hand. Frame-exactness was explicitly not wanted: drift is accepted, fidelity of MECHANISM
is the win. A third driver: the Pseudoregalia speedrun Discord owner has an always-on input
visualizer with "export the last X seconds" on a practice-mod wishlist.

The idea was already filed (`ideas.md:2739`, 2026-09-04) with its three blockers written down, and
the determinism fork already decided against inputs-as-reproduction on the engine games
(`beyond-cosmetic.md` Â§7: Emerald *"conceivable"*, TEVI/Pseudoregalia *"Never"*). Nothing there was
reopened. **Built: the CAPTURE half only, ADR 0056.** Shipped OFF behind `replay.inputs`.

**What landed.** A new bridge message `input_sample` (adapter â†’ core): edge-batches of an opaque
32-bit mask plus opaque axes, with a label table the adapter declares once. A second NDJSON track in
`replay/inputs/`, correlated to the state clip by a shared `recording_id` and by a `ts` in the same
clock domain. The ring is the always-on half â€” armed at attach whenever the feature is on, so
save-last exports input after the fact with nothing armed in advance; the file half follows the
ordinary record controls. `parseInputTrack` ships too, though nothing reads a track yet.

**Four decisions worth keeping.** A **mask, not a token list per sample**: 60â€“120 bytes an edge
against ~10, and no stable ordering, so a future diff of two runs would be set arithmetic rather
than `a.M ^ b.M`. **32 bits, not 64** â€” a JSON number is a float64 to every non-Go reader, so a
64-bit mask loses bits above 2^53. **Edges, not samples** â€” a one-frame press is two lines with
consecutive `f`, and the axis throttle may never delay a button edge. **Read the game's own merged
action state, not raw OS keys**: device-agnostic and rebind-proof for free, and structurally unable
to log what the player types in another window, which matters on a track meant to be left running.

**`replay/inputs/` is a fact about two functions, not tidiness.** `replayLast` plays the newest FILE
in `ReplayDir` and `StartReplays` reads `active/`, so a track in either would be parsed as a clip â€”
and `replayLast` picks by mod time, so a fresh track would beat every real recording the player has.
It is safe only because `replayLast` does `if e.IsDir() { continue }`. Pinned by
`TestReplayScannersIgnoreTheInputTrack` rather than by a comment, with `meshghost_inputs` as the
header key so a hand-copied file is refused with a sentence in either direction.

**A bug a test caught during the build, worth the entry on its own.** The label table arrives WITH
the first batch, but the header was snapshotted at arm time â€” so every track would have shipped with
empty labels, and a track with no labels is one nobody can interpret later. The header's table is
now filled in when the file is first opened. The lesson generalises: **a lazily-opened file cannot
take its header from the moment it was armed** if any header field is learned in between.

**A deviation from the plan, recorded so it is not "fixed" back.** The limits and validator went to
a new `bridge/inputlimits.go`, not `protocol/limits.go` where every other limit lives: `protocol`
cannot import `bridge` (bridge already imports protocol). `limits.go`'s own reason for centralizing
â€” two enforcement points that must not drift â€” does not apply, since there is one plus the loader
and both import `bridge`.

**Prior lessons applied rather than re-learned:** bounded by span AND count (G8 â€” a time-bounded
buffer at an uncapped rate is unbounded); the flood ceiling drops and never disconnects (the "client
died at 343 ghosts" failure); never blocking on the bridge reader goroutine (E5); dispatched inside
the existing switch so it inherits the impostor gate (A7 â€” which matters here, because a second
process able to write the track could put input in a player's own record that they never performed);
and the input mutex never taken under `c.rec.mu` or `c.mu`, so `StartRecording` mints the id,
releases, and only then starts the input half.

**Verified:** `run-gotests.bat` green, `run-gotests-race.bat` green, preflight clean, and a
10-minute fuzz campaign on `FuzzParseInputTrackNeverPanics` â€” 66M executions, no crashes. The four
root binaries were stale and rebuilt (the standing trap: `go build ./...` does not refresh them).

**A pre-existing flake found on the way, NOT from this work.** The first race run went red on
`TestARejectWinsARaceAgainstTheSocketClosing`. Attributed by stashing the whole change and
re-running: **10 failures in 60 on a clean tree (~17%)**, against 2 in 20 on the working tree â€” the
same rate. The failure is not the ordering the test asserts; it is `send hello: write tcp ... use of
closed network connection`, the client's hello WRITE losing to the relay closing, a second race the
test does not account for. So CI has been going red at random and a green local `-count=1` says
little about it. Filed in `status.md`, unfixed. The method is the point: **a red run on a branch is
not evidence the branch caused it â€” stash and re-run before believing either answer.**

**Open, and deliberately not started.** No adapter sends one. Pseudoregalia is first and the blocker
is honest: **there is no input read anywhere in `Plugin.cpp` today**, so which UE API is reachable is
unmeasured â€” a one-session `INPUT_API_CENSUS_PROBE` decides between the pawn's own input-derived
properties (`wallRideButtonHeld?` is a confirmed live-read BP bool) and
`IsInputKeyDown`/`WasInputKeyJustPressed`, whose `FKey`-by-value call this adapter has never made
through reflection. Sequenced after the v1.1.7 crash watcher gives a verdict, so a new DLL does not
confound it. The format is source-agnostic, so that decision gates nothing on the Go side.

**Three doors left open with their gates named, so a later session does not read capture as
permission.** (1) Re-driving a recorded GHOST from inputs: blocked on determinism per game, and on a
drive mechanism that never touches the player's controller â€” the candidate the user proposed is a
separately spawned `AIController` possessing only the ghost, driven by movement and action calls
rather than key events, which is the same "give the ghost its own instance" shape already used for
ghost-only VFX and the faked sword throw; unverified, one session to measure. (2) LIVE
input-driven ghosts: would have to be inputs PLUS state with continuous reconciliation, and the
blocking item is a world-side-effect audit, since a pawn running real character movement touches
triggers, platforms, breakables and pickups â€” today's ghost is safe BECAUSE it is posed. It also
revisits the user's own standing rule, *"Cosmetics yes, movement authority no."* (3) Driving the
LOCAL player: never in anything that ships, and already legitimate as a dev probe, which is where a
TAS-like tool would land.

## 2026-09-08 (midday) â€” the input census on Pseudoregalia, and a leftover question answered

The adapter half of ADR 0056 began where the plan said: **the census, not the C++.** The user launched
the game; the probe (`probes/probe_inputcensus/`, written against the vendored UE4SS Lua docs and
Epic's API pages, parse-checked with lupa before it cost a launch) rode the scratch slot for two
stages while they held each input ~3 s on keyboard, then on gamepad. A Lua probe changes no DLL, so
the v1.1.7 crash watcher stayed unconfounded; the DLL is the 2026-09-06 build throughout.

**The answer** (`pseudoregalia/UNVERIFIED.md`, the census entry): the hand-built `FKey` call the plan
flagged as the risk WORKS -- `IsInputKeyDown` / `GetInputAnalogKeyState` answered 118,000 times for
32 mapped keys, gamepad and keyboard, in step with the pawn. Enhanced Input's `GetBoundActionValue`
is callable and safe (55,000 calls) but Lua gets an EMPTY table back, because `FInputActionValue`
has no reflected fields; reading its value is a C++ step with one live check attached. The pawn's
own fields are partial exactly as predicted: jump, cling, move, crouch, throw yes; look, interact,
guard, lock-on, power no. The game's vocabulary is 15 `IA_*` assets, 13 bound on the pawn through 23
Blueprint input events, two mapping contexts of 35 keys. **Decision for the C++:** E first with its
bytes checked against C, A as the labelled fallback; `source` says which produced a track.

**Two instrument lessons, filed** (`pitfalls/by-lesson.md`, `checklists/before-a-probe.md`): a
`ForEach*` callback that `return false`s walks ONE entry -- the first run's summary looked complete
at 5 functions per chain and was caught only because the 2026-09-06 dump had counted 389 properties
on the same pawn; and a struct with no reflected fields returns to Lua as an empty table.

**Mid-session the user found the 512-chaser config still live** (the 2026-09-07 test): `chaser.enabled`
set false in the game-root `config.json`, the core killed so the mod respawned it clean -- the rising
probe cost (0.8 -> 10 ms a sample) was the pack. Then *"did the leak/leave anything left over?"*: a
class count said 24 then 34 pawns against 4 expected, and a flag read said **4 alive, the rest
`bActorIsBeingDestroyed`** -- the looping clips' seam despawns waiting for the engine's purge. Nothing
from the pack survived; the rigs die with their pawns. Filed as a DONE entry in `UNVERIFIED.md`.

The scratch slot holds the pristine stub again (reload confirmed in `UE4SS.log` 12:13:53); the census
logs stay in the install's scratch folder, uncommitted -- a class-schema dump is expression, the facts
are in the records. The game was left running at the user's hand; the core it spawned is theirs.

**Later the same sitting -- a tester's mod, read licence-first.** The user pointed at a tester's
`PseudoregaliaHealth` (MIT; `gh api` checked before a byte of source was read; the tester's other mod
has no licence and stayed closed). Facts only, recorded in `pseudoregalia/documentation.md`: a HUD
element can be a runtime-built UMG widget added to the viewport -- the lead for both open
recording-indicator complaints -- plus the player's HP fields, the game instance's zone string and
the enemy base classes. Nothing bears on the input track.

**Midday, the C++ half.** On the user's *"keep going until we have a working input recording"*, the
capture went into `Plugin.cpp` the same sitting: `input_track_sample` (game thread, per engine frame,
11 `GetBoundActionValue` calls plus the two sticks, edges into a bounded queue) and
`input_track_drain_and_send` (UE4SS thread, at most 64 edges an `input_sample` line, labels on the
first line after a hello), compiled in and gated by config.json's `replay.inputs`. The value read
the census could not check from Lua is checked live in C++: every jump edge against the pawn's own
`jumpButtonHeld?`, counted on the `INPUTTRACK:` log line. Built, deployed to both installs, config
armed, unwatched â€” `phase7.md`'s 2026-09-08 entry has the build; `pseudoregalia/UNVERIFIED.md` the
READY entry with what the first run has to show.

## 2026-09-08 (evening) â€” the replay input stream: ADR 0057, the core half of the ghost's inputs

The user's ask, straight after the input-display keys landed: *"can we work on making a ghost move
with inputs as well? would this also allow the game to handle things for the ghost more on its own
in a intended way and less triggers etc?"* The honest answer given and planned out with them:
half yes -- the pawn's own code produces animation, abilities, VFX and movement from inputs, which
is most of what the adapter mirrors today (mechanisms 1-12 of 19), but Unreal is not deterministic
and the viewer's world may differ, so the shape is **inputs drive, state corrects**. The plan
(seven stages, three measurements) was approved in full; the user's four calls: a ghost the
adapter spawned is OURS and may be driven (the template's "never inject, a ghost included" is
rewritten, ADR 0057), a driven pawn's audio is accepted as-is with a mute config option as future
work, a correction snaps in place, and the core half goes first because tools verify it.

**Built and green tonight -- the core half.** `remote_input`, core -> adapter: the clip's track
found by `recording_id` in `replay/inputs/` (newest wins, a first-line read per file, capped at
2,000) or inside the clip's own zip (a second archive budget, `replayMaxTrackEdgesPerArchive`),
mapped through the clip's trim window and every `skip_gaps` cut at load (`attachTrack`; edges
inside a cut are dropped and counted), streamed from the player's goroutine in 500 ms windows
after each fed sample with `at = start + (ts - t0)/speed` -- the same formula as the sample's due
time, in the domain `render_remote`'s `state.timestamp` carries -- at most 64 edges a line and 8
lines a call, the header tables re-declared behind `reset:true` after every admit (start, lap,
seek, gap seam, clock backstep). Hello-gated by a third adapter-local flag, `input_tracks`; off,
the inputs folder is never scanned (a counter proves it). Eleven tests in
`core/replayinputs_test.go`; each shown to fail under the mutation it guards (no streaming: 8 red;
no reset: 3; no gap shift: 1; just-in-time instead of ahead: 1). `FuzzEverything` gained the flag
as a config bit, a 320-edge track beside every accepted clip shape, three seeds and per-line
invariants; 90 s campaign clean at ~30k execs. `run-gotests.bat` and `-race` green; the new tests
ten times over.

**Two things the plan agent found that the design as posed had wrong**, both fixed before a line
was written: `applySkipGaps` REWRITES sample timestamps, so a track's raw `ts` does not map onto
`ts - t0` for such a clip (the clip now records its gap cuts and trim window); and a recorded-gap
seam is a drop-and-readmit too, so edges already sent past the gap are lost with the pawn and the
cursor has to be re-aimed there as well (caught by reasoning, then pinned by
`TestReplayTrackFollowsSkipGapsAndTrim`).

**Records:** ADR 0057; `contract.md` (the message, the hello flag); `_template/PROTOCOL.md` (the
section, the rewritten "never inject" rule, "never plays back" amended, "nine more" -> ten);
`internal/gameblind` (three frozen lists); `docs/config.md`; `ideas.md`'s INPUT plane entry now
carries the approved plan for the adapter half. **Next:** Stage 0 (the capture gains
`cam_yaw`/`cam_pitch` axes, `source` -> `imc_keys+bound_axes+camrot`) and Stage B (the display's
ghost half reads `remote_input`) in the next game session the user starts; then the D0 event-node
census and D1 "moves under its own power" before any drive code. No adapter reads the stream yet.

## 2026-09-09 â€” `config.json` goes live: a save is re-read and applied while running

**Backfilled 2026-09-11 from the commit log** (`66738c1c`), and it belongs here because the replay
and chaser settings were half of what was stuck.

**A tester's report opened it**: editing `config.json` mid-session changed only the input display â€”
because the mod polls that file itself â€” while **replay, chaser and hotkey settings were read once
by `main()` and copied onto plain `Core` fields.** So the one setting that appeared to work was the
one nothing in the core owned, which is exactly the shape that makes a config look live when it is
not.

- `core/settings.go` gained the setters that make a change take effect rather than merely land:
  `SetSmoothing`, `SetGhostCollisionPreference` (re-pushes the session policy),
  `SetChaserSettings` (restarts the pack), `SetReplaySettings` (re-arms the rings) and
  `SetConnectionSettings` (closes the live relay session so the existing auto-retry rejoins with
  the new `Hello`). **The replay and connection fields moved behind `settingsMu` with every read
  through an accessor** â€” a write from the poll would otherwise race.
- `cmd/meshghost/reload.go`: a 1s mtime+size poll, **applied on the second poll a change holds
  still**, so a half-written file is never read. Re-read into a fresh copy of the pre-file flag
  values, so a removed key falls back and an explicit flag still wins; one log line per changed key
  naming its effect. `startHotkeys` takes a stop channel so chords are released and re-registered.
- Tests: `core/settings_test.go`, `cmd/meshghost/reload_test.go`.

The same commit cleared the Pseudoregalia drive rig's per-pawn pointers in both release paths
(preflight's stale-pointer check) and shipped that DLL to both installs.
