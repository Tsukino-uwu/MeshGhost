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
