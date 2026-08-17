# Beyond cosmetic — what a deeper online mode would actually take

**MeshGhost is visual-only, and that is not changing here.** It exists because the architecture
must never *trap* the project at cosmetic, and the way to guarantee that is to know — before
anyone needs it — which doors are already open, which need building, and which are welded shut.

**Status, 2026-08-17: every door this file said a dumb relay could open has been built** (ADR in
`architecture.md`; the wire contract is now in `contract.md`). What that does and does not change:

- It is **primitives, not permission.** Nothing in a shipped adapter uses any of it, everything is
  off unless every member of a room opts in, and **anything past Tier 2 on `plans.md`'s depth
  ladder still needs its own per-game ADR and the memory-write gate.** A future session reading
  "escrow exists" as "trading is approved" is misreading it exactly as badly as this file's last
  section warns.
- The three gaps this file identified as *not* dumb-relay-shaped stay open, and for three
  different reasons — see §4 and §5. One of them is impossible rather than unbuilt.
- The analysis below is kept as written, because the reasoning is what makes the code
  reviewable. Where a section describes something now built, it is marked **BUILT**.

Read `plans.md`'s depth ladder first for the tier framing (0 cosmetic → 3 consensual interaction),
and `contract.md`'s Extensibility section for the reserved event plane. This file is the *concept*
layer under both: sync models, authority, and the honest gap list.

---

## 1. What is already reserved, and already built

A future session should not re-derive any of this. It exists today:

| Thing | Where | State |
|---|---|---|
| Depth ladder, Tier 0-3 | `plans.md` | documented |
| Event plane (`event` type, `to` addressee, opaque payload) | `contract.md` Extensibility, `protocol.go` | **BUILT 2026-08-17** — routed, stamped, gated on `event.v1` |
| `features` capability list on `hello` | `protocol.go`, `contract.md` | **BUILT 2026-08-17** — six capabilities, sticky per room |
| Recipient-set forwarding | `relay.Room.Forward(msg, to []string)` | **built** — shaped for addressed routing from the start, and that shape paid off exactly as intended |
| Unknown *fields* ignored | `contract.md` | built |
| Unknown *message types* ignored | both dispatch switches | built |
| `send` reliable **and ordered** on every transport | `contract.md`, `udpconn` | built (ordering added 2026-08-16) |
| Room sequencer, one total order | `relay/online.go` | **BUILT 2026-08-17** |
| Lease / escrow / snapshot / resumption / clock sync | `relay/online.go`, `core/online.go` | **BUILT 2026-08-17** |

The single most valuable one is `features`: it had to exist *before* clients shipped, because a
client built without it has no way to say what it supports. That one field is most of why deeper
work was still possible at all — **and it was: every capability below travels on it, and none of
them needed a `ProtocolVersion` bump, so no deployed client was orphaned.** Reserving one field
in 2026-08-11 is the whole reason 2026-08-17 was additive.

---

## 2. Authority — the taxonomy that matters

The governing insight, and the thing most likely to be got wrong by someone reasoning quickly:

> **Authority over *order* is not authority over *meaning*. Only the second requires game
> knowledge.**

"You were second, so you lose" needs a counter. "That move was illegal" needs to understand the
game. Those are different powers, and conflating them is what makes people conclude that any
server authority is impossible here. It isn't.

### The four models

| Model | What the relay does | Needs game knowledge? |
|---|---|---|
| **Client authority** (today) | forwards; each client owns only itself | no |
| **Sequencer authority** | stamps a total order on opaque events | **no** |
| **Lease authority** | grants an opaque key to the first asker, refuses the rest | **no** |
| **Simulation authority** *(in the relay)* | runs game logic, validates actions | **yes — excluded** |
| **Peer authority** *(in a client)* | forwards one client's entity state to the rest | **no** |

Sequencer and lease authority are *real* server authority in the practically useful sense, and both
keep the relay completely dumb. They are the same trick `area_id` and `anim` already use: an opaque
string compared by equality, nothing more.

### Peer authority, added 2026-08-17 — the model this table was missing

The fifth row came out of a user question — *"a full online would require even the player to spawn
in online, so nothing is bound/placed in the game itself, same for enemies… disabled by default,
but spawned in online"* — and it is worth its own note, because the original four rows quietly
implied that anything past lease authority needed a game-aware relay. It does not.

**Nothing says the simulation has to run in the relay.** Let one *client* own the enemies, spawn
them, run their AI, and stream their state; every other client suppresses its own spawning and
renders what it is told. The relay forwards opaque per-entity blobs and understands exactly as
little as it does today. That is the ordinary dedicated-host model, and it is how most co-op games
actually work.

**Why this matters: it sidesteps determinism entirely.** §7's lockstep answer is per-game and
mostly negative — Unity and Unreal drift on floats and update ordering, so two copies cannot be
made to agree by replaying inputs. Peer authority never asks them to agree: only one copy decides
anything, and the rest are displays. So the constraint that rules lockstep out for the two modern
games does not apply here at all.

What it costs instead, and none of it is relay work:

- **Suppressing the local game's own authority, comprehensively.** Every native spawn, trigger and
  AI tick for a peer-owned entity has to stop running locally, or both copies simulate and neither
  matches. That is the deepest per-game work in the list, and it is all-or-nothing per entity type.
- **Volume.** The state plane carries one snapshot per *player*. This needs one per *entity*, which
  is a different scale of traffic — still opaque to the relay, but a real protocol sizing question
  rather than a free extension of what exists.
- **Latency, with no arbitration to hide behind.** A remotely-owned enemy is always as old as the
  round trip. Real games spend prediction and rollback on exactly this, and that is a substantial
  project of its own.
- **Trust becomes total.** The owning peer's word is final for everything it owns, so a modified
  client is not merely lying about itself. Fine among friends, which is this project's setting;
  worth being explicit that it is not a security model.

**It does not need a save write**, which is worth stating because the instinct is to assume it
does: spawning and driving entities is runtime state, exactly like the ghost pawn the Pseudoregalia
adapter already clones and poses through the game's own systems. `CLAUDE.md`'s save rule is
untouched by any of this.

So the honest position is that the ceiling is **movable by a game's adapter**, not by the relay,
and that the thing which decides it is how much of a game's own authority can be switched off
rather than anything in this repo. At that point it is a game-specific netcode project reusing this
transport — §11's line, unchanged.

### Why it stays dumb: the relay never judges merit, only arrival

It picks the first claim, and that becomes the fact by fiat. Everyone agrees because everyone was
told the same answer — not because the answer was correct on the merits. Arbitrary-but-consistent
is the whole trick. Judging *rightness* is what would require understanding the game.

```text
Adapter A → relay:  claim "route103:rarecandy"
Adapter B → relay:  claim "route103:rarecandy"
relay → everyone:   "A holds route103:rarecandy"
```

Two opaque strings compared for equality. The relay does not know what a rare candy is, that Route
103 is a place, or that anything was picked up. A's game gives the item; B's doesn't; both agree,
permanently.

### The rule that makes or breaks it

**Adapters must ask BEFORE acting, never announce after.** An adapter that acts locally and then
reports puts the relay's "no" *after* the fact is already on screen — a rollback problem, per-game
and genuinely hard. The flow is claim → wait → act.

**So every contested action costs a network round trip before anything visible happens.** Invisible
for a turn-based trade or battle. Unacceptable for anything twitchy, which is why action games
invented prediction and rollback.

Worth noting that this lands independently on the same boundary the depth ladder already drew —
bounded, consensual, turn-based interactions. Two separate lines of reasoning reaching the same
place is a good sign the boundary is real rather than arbitrary.

### The modularity split survives intact

- **Relay** — order and leases over opaque keys. No game knowledge.
- **Core** — forwards, applies order. No game knowledge.
- **Adapter** — the only layer that knows what a key *means*, or what to do on losing one.

---

## 3. Per-game opt-in falls out for free

**The relay implements a primitive; an adapter chooses whether to ever call it.** A game that needs
no leases simply never claims, and the code path never runs for that room. So the relay needs no
per-game table and no `game_id` branch — which would break CLAUDE.md's core rule anyway.

That generalises into the door-keeping rule this whole file exists to state:

> **Everything past cosmetic is adapter-opt-in via `features`, never relay-imposed via `game_id`.**

A corollary worth stating, because the alternative looks tempting: an adapter that needs ordering
should simply *use the reliable plane*, which is ordered on all three transports. It should not ask
the relay to steer it onto a particular transport. Opt-in from the adapter beats imposition from
the relay, and needs no game knowledge on either side.

### Hazard: capability mismatch inside one room

If one client advertises `lease.v1` and claims properly while another doesn't and simply acts,
conflict resolution silently does not work — everything looks fine until it doesn't.

**Clean fix that stays dumb: reuse the `GameVersion` pattern exactly.** `relay.joinOrCreateRoom`
already makes `GameVersion` sticky on first join and rejects mismatches by string equality. A
feature set can work identically. The relay would learn no more about `lease.v1` than it currently
learns about `1.2.0`.

---

## 4. What the dumb-relay models do NOT buy

The honest section, because this is where an enthusiastic future session would overreach.

- **Not anti-cheat.** A lying client still lies; ordering never validates content. "The server
  disagrees that you did 9999 damage" is simulation authority, full stop.
- **Not full sync on its own.** Ordering is necessary, not sufficient — two clients applying the
  same ordered log to different local state still diverge. It *is* sufficient for bounded,
  consensual interactions, which is exactly Tier 3.
- **The hard part is lease lifetime, not the sequencer.** What happens when a holder disconnects
  mid-trade: timeout, reclamation, what the other side is told. Real work, not a few lines.

---

## 5. The readiness gap table

Arbitration is roughly one fifth of what "full online" means. The useful question is not "how much
work" but **which gaps the opacity trick still covers** — because that is what decides whether the
relay can stay dumb.

| Gap | State | Dumb relay enough? |
|---|---|---|
| **Atomicity / escrow** | **BUILT 2026-08-17** — open/deposit/commit/abort, blobs revealed only on commit | **Yes** — relay holds an opaque blob, releases on commit/abort |
| **Late-join world snapshot** | **BUILT 2026-08-17** — `Join.State` populated for a `snapshot.v1` room | **Yes** — relay keeps the last opaque state blob per player |
| **Clock sync** | **BUILT 2026-08-17** — `Pong.ServerTimeMs`, lowest-RTT estimator, applied under `clock.v1` | **Yes** — relay serves time |
| **Stable identity** | **BUILT 2026-08-17** — `resume_token`, a grace window, no leave/join seen by the room | **No** — was a new subsystem, and is one |
| **Persistence** | **REFUSED** — rooms still deleted when empty; nothing on disk but the log | **No** — new subsystem, and see below |
| **Anti-cheat** | **impossible** | **Never** — catching a lie requires knowing what is true |

Three rode the same opaque-blob trick and were cheap. One was a genuinely new subsystem and was
built anyway, because escrow is not honest without it (see below). One was refused on grounds
that have nothing to do with difficulty. Exactly one is impossible by construction — and
**knowing which one is impossible is still worth more than the rest.**

### Atomicity deserves the most emphasis

It is the one gap with real-world precedent for damage, and the repo has never written a word about
it. **A lease grants exclusive *access*, never an atomic *swap*.** A trade is two-sided — both or
neither — and if one side vanishes after handing over, an item is destroyed or duplicated. That is
exactly where historical Pokémon trading exploits came from.

`plans.md` asserts trades are tractable *because* they are bounded and consensual, and never
examines the one-side-vanishes case. That case is now the one the implementation is built around:
an exchange completes only when both parties have deposited **and** both have committed, any
disconnect or timeout aborts it and destroys both blobs, and a terminal record is retained for 60s
so a party that dropped between the commit and its delivery can resume and be told the outcome.

**That retention is why stable identity was built alongside escrow rather than after it.** Without
resumption, "both or neither" holds only for as long as both sockets stay up — which is the case
that never fails in testing and always fails in the field. Escrow without resumption would have
been a guarantee that is true in every test and false in the only situation it exists for.

### Persistence changes the project's character — and was refused for that reason

A persistent relay needs storage, backups, migrations and corruption handling. It stops being a
thing a user runs from a `.bat` file. That is a bigger change than its one table row suggests, and
it is why the 2026-08-17 pass built the other five rows and deliberately did not build this one.

The honest boundary it leaves: **resumption survives a network blip, not a relay restart.** Rooms,
leases, exchanges and identities all live in memory and die with the process. A host who restarts
their relay mid-trade aborts it, and every client rejoins with a fresh `player_id`. Making that
survivable is the one remaining thing that would change what MeshGhost *is* to run.

---

## 6. The near-free implementation path (a cost note, not a proposal)

Recorded so nobody re-scopes it from scratch:

- `Room.forward` already serialises under `r.mu` to snapshot targets, so a per-room monotonic stamp
  assigned inside that existing critical section is a handful of lines.
- `Room.Forward` already takes an explicit recipient set, shaped that way deliberately for addressed
  routing.

**The sequencer half is cheap.** Leases, escrow and lifetime handling are not — and that
estimate held exactly. The sequencer was a counter incremented inside a lock already being taken;
what it actually cost was the *delivery* guarantee nobody had priced, a per-room send lock held
across stamp-and-send (see §10's invariant-harness row). Lease lifetime and escrow atomicity were the bulk of the work,
as predicted.

---

## 7. Deterministic lockstep — the no-arbiter alternative

There is a fourth way that needs no arbiter at all: both sides run the same simulation from the same
inputs, and the relay just forwards inputs. Fighting games and RTSs work this way.

**It needs determinism, so the answer is per-game and decisive:**

- **Emerald** — emulated, deterministic by construction, already frame-stepped. Conceivable.
- **TEVI / Pseudoregalia** — Unity and Unreal: float drift, frame-rate-dependent physics,
  non-deterministic update ordering. Never.

This is the same shape as `access-models.md`'s framing that what you can *read* about a game
predicts an adapter's difficulty — here, what you can *reproduce* predicts how deep it can go.

---

## 8. Protocol-level gaps to close first

- **`MaxEventBytes`** — **CLOSED 2026-08-17 at 1024 bytes, uniform.** Of the two honest options in
  §9, uniform won: it keeps a whole event envelope under `udpconn.MaxDatagramBytes`, so an event
  means the same thing on every transport and size needs no negotiation. The cost is a smaller
  ceiling than a stream transport could carry, paid so there is one number rather than a
  capability difference that only shows up in the field.
- **`seq` is inert.** `protocol.State.seq` is documented "for ordering", written by
  `internal/core`, and read by nothing. **Still true, and now deliberately so**: the event plane
  got its own room-wide `Event.Seq` rather than reusing this one, because a per-client counter on a
  lossy plane means nothing across senders and a total order has to come from the relay. The two
  are different things that happen to share a word.
- **Versioning is the one that matters most.** `ProtocolVersion` is an exact-equality check, so any
  bump hard-rejects every existing client. New capability must therefore travel via `features` plus
  the unknown-field/unknown-type tolerance, and a `Version` bump stays reserved for genuinely
  breaking changes. **Stating this is most of what keeps the door open** — it is the difference
  between adding a feature and orphaning every deployed client. **Held in practice 2026-08-17**:
  six capabilities, four message types, and eight new fields shipped with `ProtocolVersion`
  untouched, riding `features` plus the unknown-field/unknown-type tolerance exactly as planned.

---

## 9. Schema and sizing — what a deeper mode would carry, and how big it can be

### The state plane does not grow. That is the whole point of two planes

`contract.md` says it outright: the state plane *"does not grow new fields for deeper features; it
stays exactly what it is now."* Deeper data rides `event`, not `state`.

**`extras` is the tempting wrong answer, and the reason is delivery semantics rather than
vagueness.** `extras` is a `state` field, so anything in it is lossy, latest-wins, and re-sent
~20×/second. That is right for "what colour is this ghost's trail" and catastrophic for "I offer
you this Pokémon" — a trade offer sent 20 times a second on a plane that may silently drop it is
not a trade offer. The repo already reached this conclusion once for a smaller feature: `ideas.md`
rejected nameplates-via-`extras` as *"the wrong layer — `extras` is per-state free-form data, not
identity."*

So the answer to "is `extras` too vague to carry more?" is that it is not vague enough to be the
problem. It is on the wrong plane.

### How much to split: by treatment, never by meaning

> **A field earns top-level status only if game-agnostic code must act on it.**

Not "if it is important" — if `internal/core` or `internal/relay` must *read* it. On the event
plane that is `to` (the relay routes on it, already reserved) and plausibly a correlation id (to
match a reply to its request). Everything else belongs in the opaque payload.

**Why so few:** a top-level field the core does not read is a field the core can *start* reading.
Opacity is a guardrail, not laziness — note that `area_id` and `anim` are top-level *because* the
core compares them, and CLAUDE.md still has to explicitly forbid branching on their contents. That
pull is strong enough to have needed a written rule. Two pieces of data treated identically by
game-agnostic code belong in the same blob however different they are semantically.

### Sizing: one message is one line, sent whole

There is **no application-level fragmentation anywhere**. Two separate ceilings apply:

| Limit | Value | Behaviour past it |
|---|---|---|
| `protocol.MaxLineBytes` | 4096 | line refused |
| `udpconn.MaxDatagramBytes` | 1200 | **refused, not split** — `contract.md`: *"Large `extras` therefore means `tcp`"* |
| `protocol.MaxExtrasBytes` | 1024 | validation failure |

For scale, a measured Pseudoregalia state line is **at least 597 bytes** — that figure is a floor,
taken before `extras` grew from 14 keys to 25 — already half the udp budget. A
Pokémon party would not fit in 1200 bytes, nowhere close.

**The ceiling largely evaporates on the right transport, which is the useful part.** The reliable
plane on `tcp` and `quic` is a *stream*, so it has no datagram limit — only `MaxLineBytes`. Events
are rare and reliable, so they ride the stream rather than datagrams. Raw `udp` is the only
transport with the hard 1200 wall.

That turns `MaxEventBytes` — today a placeholder in `contract.md` with **no number** — into a real
decision with two honest options:

1. **Uniform**: set it to what every transport can carry (~1200 minus overhead). Simple, and
   restrictive for everyone because of udp.
2. **Transport-dependent**: a udp client genuinely cannot do large events. A real capability
   difference, and exactly the kind of thing `features` exists to negotiate.

**Argue against app-level chunking.** Fragmenting a payload across lossy datagrams reinvents TCP,
badly, and worse than the version the kernel already provides. If a payload is big the answer is a
stream transport, or sending a *reference* rather than the data.

## 10. Tooling — what would have to exist to test any of this

Most of the rig already exists and is better than it looks: `cmd/meshghost-fakeadapter` doubles as
an N-client synthetic load generator, `internal/e2e` launches the real binaries, `-loopback` gives
a one-machine round trip, and CI runs the race detector plus all six fuzz targets. `testing.md` and
`dev-scripts/README.md` are the inventory.

What is missing splits cleanly by **which bug class it catches**:

| Tool | Catches | Status |
|---|---|---|
| **Adverse-network proxy** | anything that only breaks under loss/latency/jitter/reorder/partition | **BUILT 2026-08-16** — `cmd/meshghost-netsim` |
| **Invariant harness over N clients** | concurrency bugs (one lease holder, no dupe/loss, consistent order) | **BUILT 2026-08-17** — `internal/relay/online_test.go` |
| **Divergence detector** | two peers silently disagreeing about shared state | reserved |
| **Record / replay** | a desync seen once and never again | reserved |
| **Crash injection at protocol points** | atomicity — the half-finished trade | **BUILT 2026-08-17** — `internal/relay/online_test.go`'s crash-mid-exchange tests |
| **Relay introspection** | "what does the server think is true right now" | **BUILT 2026-08-17** — `Server.Snapshot`, `meshghost-relay -introspect` |

**The second was built the moment it had something to be an invariant about**, and immediately
earned it: the total-order test failed on its first run, catching a real ordering defect (a stamp
assigned under the room lock and delivered after releasing it, so two concurrent events could be
stamped 1 and 2 and race to the socket). That is the predicted failure mode landing exactly where
this table said it would. Two more followed once the code existed to need them:

- **Relay introspection** earned its place by the relay finally having state worth inspecting. A
  relay that forwards and forgets has nothing to report; one holding leases, exchanges and parked
  identities can be wedged in ways no log line records. Deliberately a snapshot logged by the
  relay itself, not a status port — adding a listener would hand back the pre-auth surface the
  transport-discovery ADR worked to keep clear.
- **Crash injection** turned out to be tests rather than a tool: dropping a party's socket at a
  chosen protocol point is one `Close()` in an existing test client. The case that mattered is a
  party crashing between the relay committing an exchange and the message arriving, then resuming
  to learn the outcome — the path the whole retention mechanism exists for, and one that was
  built before it was tested.

**A finding worth more than either tool.** The soak rig, run against a deliberately broken relay
(per-room send lock removed), saw 51,000 events and reported nothing, while the in-process
total-order test caught the same defect immediately. Load and duration are not a substitute for
contention density. See `testing.md`.

The remaining two — divergence detection and record/replay — stay reserved, and honestly should:
nothing shares state to diverge yet, which is the condition that would make them mean anything. The proxy earned its place immediately: `testing.md` already recorded that jitter and clock
skew were untested and that interpolation degrades *silently* under skew, and the unit-scale
version of exactly this tool found the lifecycle-ordering bug on 2026-08-16.

**The pattern to reuse when the others are built** is `testing.md`'s own durable lesson, which is
worth more than any of these tools: *a test that asserts an invariant under concurrent clients
found a relay race locally in 100 runs once written*, where the race detector only caught it by
accident, in a misleading place. For full online — which is almost entirely concurrency bugs — the
invariant harness is therefore the highest-value item on that list, not the flashiest one.

**Divergence detection is the genuinely new one.** Every existing check asks "did the message
arrive". Full online asks "do two machines agree", and nothing in the repo can answer that today
because nothing is shared. The standard approach is each client periodically hashing its own view
and comparing; the first divergent tick localises the bug. Worth knowing that the answer is
already well-established rather than something to invent.

## 11. The line that stays

**Full continuous co-op with a game-aware relay remains a different project.** `architecture.md`
records it as architecturally excluded rather than merely unapproved, and that stands.

Two corrections this file makes to the *reasoning* behind that exclusion — neither of which lifts
it:

1. The stated reason is that full co-op "needs a permanent arbiter" and "any arbiter would have to
   be game-aware". That is true of **simulation authority** and **false of sequencer and lease
   authority**, which arbitrate without understanding anything.
2. It is also false of **lockstep**, which has no arbiter at all.

So the exclusion is right and its stated justification is too broad. **Recording that is not
permission.** Anything past Tier 2 needs its own per-game ADR, and the memory-write gate in
`plans.md` applies regardless of which sync model is chosen. A future session reading this section
as a green light is misreading it.

---

## Links

`plans.md` (depth ladder, non-goals) · `contract.md` (event plane, packet schema, transport
contract) · `architecture.md` (the exclusion, and the ADR log) · `access-models.md` (what each game
lets you read) · `bandages-core.md` (Go-side compensations)
