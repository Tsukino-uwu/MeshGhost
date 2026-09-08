# 2026-09-08 — A replay streams its input track beside its frames

<!-- ADR 0057. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** a new bridge message, `remote_input`, core → adapter: a replay ghost's recorded
  input track (ADR 0056), streamed **ahead** of the ghost's frames in windows, each edge carrying
  `at` — the render-clock time it is due, in the same domain `render_remote`'s `state.timestamp`
  already carries — so the adapter applies a press on the frame the ghost's rendered state reaches
  it. The core finds a clip's track by `recording_id` in `replay/inputs/`, or inside the clip's
  own zip, maps the edges through the same trim and `skip_gaps` surgery the samples had, and
  re-declares the header tables behind `reset:true` after every seam. Sent only to an adapter
  whose `hello` set `input_tracks`; never on the wire.
- **Status:** Go side built and tested 2026-09-08 (suite, `-race`, a 90 s `FuzzEverything`
  campaign, every new test shown to fail under the mutation it guards). **No adapter reads it
  yet**; Pseudoregalia's input display ghost half is first, and the same stream is what a driven
  ghost will consume.
- **Scope, and the reconciliation this ADR makes:** the core is a courier and drives nothing.
  What the ADAPTER may do with the stream is settled here too, on the user's call the same day:
  **a pawn the adapter spawned may be driven by it; the local player's controller or pawn, and any
  actor the game owns, may not.** `_template/PROTOCOL.md` said "never inject, a ghost included";
  ADR 0056 and `ideas.md` said "a ghost driven by inputs is fine — it is ours". The second stands,
  narrowed: only that pawn, only under the adapter's own shipped-off setting, and only with the
  recorded state correcting it (below).

## Why the render clock, and why ahead

A replay sample is fed at `due = start + (ts − t0)/speed` and rendered, `local_interp` later, with
`state.timestamp = renderTime` (`core/remotes.go`, `interp.go`). A track's `ts` is stamped in the
same clock as the clip's samples (`core/inputrecorder.go`), so an edge's `at` is the same formula
on the same numbers, and "apply when `state.timestamp >= at`" aligns a press to a rendered frame
with no offset table and no adapter-side clock.

Sending an edge at its due moment instead would put it behind the adapter writer's queue — which
holds a line for hundreds of milliseconds under a slow adapter and one poll interval under a
healthy one (`core/adapterwriter.go`) — and the adapter would apply it late by exactly that,
unmeasurably. A 500 ms window ahead makes alignment independent of the bridge; the cost is a few
hundred buffered edges per ghost on the adapter's side. `TestReplayStreamsItsTrackOnTheRenderClock`
pins both halves: `at` equals the sample's own due time, and every line lands before the render
it is due on.

## Why every seam is a reset

A loop, a seek, a recorded gap, a clock step — each is `replayPlayer.seam`, a drop-and-readmit
that reaches the adapter as `despawn_remote` and a fresh pawn. Edges already sent ahead of the seam
were for that pawn; the adapter drops them with it. So the cursor is re-aimed after every admit and
the next line carries `reset:true` plus the labels, axes and source again — sent from the player's
own goroutine AFTER the sample that follows the seam, which is what keeps it behind the despawn
(the writer preserves order for every non-render message). The tables are sticky between resets,
exactly as `input_sample`'s are.

## Why the track is mapped through trim and skip_gaps at load

`applyTrim` drops samples and `applySkipGaps` REWRITES their timestamps (`core/replay.go`), so a
raw `ts` does not map onto `ts − t0` for such a clip. The clip now records the trim window and every
gap cut, and `attachTrack` puts the edges through the same surgery once: outside the window,
dropped; inside a cut, dropped and counted (the ghost was despawned there); after a cut, shifted by
the cumulative cut. `TestReplayTrackFollowsSkipGapsAndTrim` fails on the raw stamps.

## Why a hello flag and no config key

An adapter that cannot use a track — the emulated games, an adapter with no display — must pay
nothing: not a directory scan, not a parse, not a line on the bridge. `input_tracks` on the hello
is adapter-local like `render_all_areas` and `interpolate_orientation`, changes nothing on the
wire, and off it the core never looks in `replay/inputs/` at all
(`TestReplayTrackIsNeverSentToAnAdapterThatDidNotAsk` counts the scans). A core config key would
have to be set by a person for a fact only the adapter knows.

## Why a header scan and not an index

The lookup is one first-line read per track, newest first, capped at 2,000 files, once per replay
load. An on-disk index would add a write path, a staleness case and a corruption case to save a
fraction of a second at a folder size nobody has. Duplicate ids resolve to the newest file.

## The zip case

A clip zipped to send to someone can carry its track beside it: an entry whose first line has the
`meshghost_inputs` key is parsed as a track under the archive's own edge budget
(`replayMaxTrackEdgesPerArchive`, the `replayMaxSamplesPerArchive` lesson applied a second time)
and matched to the archive's clips by `recording_id`. Unmatched either way is logged, never
refused. A track past the per-clip cap (`replayMaxTrackEdges`, 500,000) is truncated and the clip
still plays: an edge missing from the end of a run costs the ghost a press, not its position.

## What the stream permits, and the determinism question it sidesteps

ADR 0056 named three gates on re-driving a pawn from a track: determinism per game, a drive that
never touches the player's controller, and the standing ban on driving the local player. This ADR
settles the third (above) and, for a ghost corrected by recorded state, makes the first moot: the
track is the ghost's **animation** mechanism, the recorded state stays its **position** mechanism,
and divergence is bounded by one correction rather than compounding. *"The inputs replay but the
run diverges"* — the failure `ideas.md` names — cannot last longer than the adapter's correction
threshold. The second gate is the adapter's measurement to make, and it is not made here.

The stream does not preclude a chaser: the message has no clip or file field, and a chaser would
stream the always-on input ring with `at = ts + delay`. Not built; nothing schedules it.

## Records

`agent_docs/contract.md` (bridge messages, the hello flags); `adapters/_template/PROTOCOL.md`
(the section, and the two sentences this revises); `internal/gameblind` (the frozen field lists,
with the burden of proof for `at` and `reset`); `core/replayinputs.go` and its test file;
`agent_docs/phases/phase11.md`, 2026-09-08.
