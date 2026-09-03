# 2026-09-03 — A local ghost renders on its own delay, not the network's

<!-- ADR 0049. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the render time is per PEER CLASS, not one number for the room.
  `core.DefaultLocalGhostDelay` is 25ms and applies to every ghost this core invented — the
  `replay:` and `chaser:` ids of ADR 0047 — while `DefaultInterpolationDelay` (450ms, ADR 0046)
  continues to apply to every peer learned from the relay. Configurable as `local_interp` /
  `-local-interp`, shipped in the root `config.json` and deliberately absent from the per-game
  files.
- **Status:** built 2026-09-03, the Go suite and `internal/e2e` green, and every regression test
  below verified to FAIL on a reintroduced defect. Not yet watched in a game; the visual check
  (a 3s chaser looking 3s behind, a split time agreeing with the ghost on screen) is queued.
- **Why:** ADR 0047's strength is that nothing downstream of `storeRemoteState` can tell a local
  ghost from a relay peer. `tickRenders` took that literally and drew both one
  `InterpolationDelay` in the past — but a chaser and a replay stamp their samples with the wall
  time they are meant to be AT, so the delay was charged twice. **A chaser configured for 3s was
  drawn at 3.45s**, the headline knob off by 15%, and a replay ran 450ms behind its own schedule.
- **Why not zero, which is the obvious answer:** the render time would land exactly on the newest
  fed sample, `atAhead` takes its past-the-newest branch, and with `Extrapolate` at its default of
  0 it holds. That trades a smooth offset for a stair-step at the feed rate. One or two sample
  intervals is what is wanted; the recorder taps every adapter frame (87.5 Hz measured on a real
  Pseudoregalia clip), so 25ms is about two of them and covers any feed at 40 Hz or better.
- **The two dependent sites, both of which had to move with it:** the end-of-clip hold
  (`core/replay.go`), which exists so a finished ghost's last position is drawn before the drop;
  and the split time (`core/splittime.go`), which now measures against the ghost that is ON
  SCREEN rather than the schedule it was fed on — the tag read `+0.0s` while the visible ghost was
  still 450ms short of that spot, in the one feature racing a ghost is for. The correction is
  subtracted RAW: `clip.speed` converts clip time to wall time, and a render delay is already wall
  time.
- **Two things the split into classes would otherwise have broken**, both handled in the same
  change: local peers are kept out of the `dry` meter, which is a NETWORK health statistic and
  would otherwise report every adapter stutter as a bad connection for anyone running a chaser;
  and `Extrapolate` is forced to 0 for them, since predicting a ghost whose future is already on
  disk invents motion over data we hold and pollutes the extrapolation counters.
- **Why the id, not roster membership:** `isLocalPeerID` is the same predicate `render_remote`'s
  cosmetic flag is built from, for the same reason (`core/localpeer.go`) — a seam drops and
  re-admits a local peer, so a membership test would move that ghost's render time by 425ms
  mid-lap and teleport it.
- **Why no test caught the original defect, which is the part worth carrying:** every helper that
  touches a local peer pinned the interpolation delay to 0 — `core/localpeer_test.go`'s
  `startLocalPeerCore` and `internal/e2e`'s `startClient` alike — and at 0 the defect cannot
  exist. The chaser test measured its delay correctly throughout and would have gone on doing so
  forever. `core/localrender_test.go` and the two e2e tests now run at the shipped 450ms on
  purpose.
- **Related:** `ideas.md`'s per-ADAPTER interpolation delay (2026-08-28) is the same knob on a
  different axis — per game rather than per peer class — and still wants its measurement before it
  wants a mechanism. The per-peer plumbing here is where it would land.
