# 2026-09-11 — Neither end of the bridge blocks the other, and a superseded frame may be shed

<!-- ADR 0060. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** neither direction of the bridge is written synchronously from a path that produces
  frames. Each connection has one writer goroutine and a bounded queue; the producer enqueues and
  never waits. **A message that is a STATEMENT OF CURRENT POSITION may be dropped or replaced while
  queued; a message that is an EVENT may not.** That split is the contract's own reliable/lossy
  plane split (`contract.md`), applied to the local socket.
- **Status:** shipped. The core → adapter direction landed 2026-09-07 and this ADR is partly
  retrospective for it (review J3: it changed behaviour with no ADR and no contract update). The
  core → relay direction landed 2026-09-11 as review E5. `contract.md`'s tick model is corrected in
  the same pass.
- **Why retrospective rather than quietly folded in:** the relay's structurally identical change got
  ADR 0042, and a reader comparing the two would find one documented and one not. The coalescing
  half in particular is a visible behaviour change — 270,872 renders shed in one measured run — and
  nothing said so.

## What each direction was doing, and what it cost

**Core → adapter (2026-09-07).** The core answered every adapter frame by writing one
`render_remote` line per remote, synchronously, on the frame goroutine. At a tester's 512-chaser
pack and Pseudoregalia's ~180 Hz that is 92,160 messages and ~35 MB/s down one loopback socket,
against an adapter that can parse a fraction of it. Twice — at 343 ghosts and again at ~350 — the
socket buffer filled, a write deadline expired **with a line half-written**, and the core tore down
a session whose game was perfectly healthy and merely busy.

**Core → relay (2026-09-11).** `sendState` ran on the BRIDGE connection's read goroutine and wrote
the relay socket synchronously. So a relay that stopped reading blocked that read loop for the whole
ten-second write deadline — the bridge socket's buffer then fills, and **the adapter's next write
blocks on the game's main thread.** A frozen game, on a machine where nothing is wrong, because
something across the internet stopped reading.

Both are the same shape: a slow consumer reaching backwards through a queueless pipe and stopping a
producer that had somewhere else to be.

## What may be shed, and why that is not a loss

A `render_remote` says "this peer is here now". It is not an event; an unsent one is worthless the
moment a newer one exists for the same peer. So a newer render REPLACES an older unsent render for
that player **in place**, keeping its position in the queue — which also bounds the queue by the
number of peers, however far behind the adapter falls. What a slow adapter now costs is intermediate
ghost positions it would never have drawn, rather than the session.

A queued `state` to the relay is the same statement on the same plane, and the loss cover makes the
argument stronger rather than weaker: **a newer state's `prev` (ADR 0045) carries exactly the sample
the queue would discard**, so a receiver that gets only the newer line reconstructs both.

Everything else — despawns, nametags, policy, `bridge_ready`, recording state, events, leases,
escrow steps, world writes — is an EVENT, is never coalesced, and keeps its order. A full queue of
those means the far end is not reading at all, and the honest answer is to drop the CONNECTION,
which both ends already know how to recover from.

## The user's rule this serves

> "I never want the server/client to be the limiting factor for anything ... if you set 512, you
> should be able to eventually reach there if the game itself don't crash." (2026-09-07)

A queue is what makes that true without promising the impossible: the client stops being the thing
that fails first, and what degrades instead is fidelity the player cannot see.

## What this does NOT change

The core still interpolates and still pushes at frame rate; the adapter still holds the latest state
per id and draws all of them. **The tick model is unchanged — what changed is that "pushes every
frame" now means "offers every frame".** An adapter that keeps up sees exactly what it saw before,
byte for byte, because coalescing can only happen to a message that is still queued when a newer one
arrives, and on an adapter that is keeping up there is never one.

Nothing crosses the network differently. Both queues are on a local socket between two processes on
one machine.
