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
| `features` capability list on `hello` | `protocol.go`, `contract.md` | **BUILT 2026-08-17** — seven capabilities, sticky per room |
| Recipient-set forwarding | `relay.Room.Forward(msg, to []string)` | **built** — shaped for addressed routing from the start, and that shape paid off exactly as intended |
| Unknown *fields* ignored | `contract.md` | built |
| Unknown *message types* ignored | both dispatch switches | built |
| `send` reliable **and ordered** on every transport | `contract.md`, `udpconn` | built (ordering added 2026-08-16) |
| Room sequencer, one total order | `relay/online.go` | **BUILT 2026-08-17** |
| Lease / escrow / snapshot / resumption / clock sync | `relay/online.go`, `core/online.go` | **BUILT 2026-08-17** |
| World custody (`world` / `world_state`, latest opaque blob per entity, handed to whoever takes the authority lease) | `relay/world.go`, `core/online.go` | **BUILT 2026-08-17** — gated on `world.v1`, requires `lease.v1` |

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

**Peer authority answers who *simulates* an enemy and not who may *kill* it.** The moment several
clients share one, "is it dead?" and "who gets the reward?" become separate questions with no
obvious default, and neither is answerable from anything in this section. That is worked out in
`kill-credit.md`, which is a precondition for enemy/boss sync rather than a refinement of it.

#### Who is the host, and what happens when they leave

The obvious follow-up — the first player joins and is host, then leaves after others have arrived —
and the useful answer is that "hosting" is three separate jobs. The relay should take two of them
and can never take the third.

**1. Designation — the relay, and it already does this.** "Who owns the enemies" is an opaque key.
`lease.v1` grants it to the first asker, refuses the rest, and tells every member the same answer
by fiat; the relay learns nothing about what the key means. The lifecycle falls straight out of
what the lease already does:

- **A host leaving** releases its lease with `holder_left`, and the next claimant takes over. No
  election to write and no split-brain to resolve, because one claim is picked by arrival and
  everyone is told the same thing.
- **A host blipping** does not migrate at all if the room negotiated `resume.v1`: the identity and
  its lease are held for the grace window and a reconnect inside it resumes as the same holder.
  Migrating on every packet loss would be far worse than the outage.
- **A host crashing** migrates once that window expires — deliberately slower than a clean exit,
  which is the right trade for something this disruptive.
- **Nobody left** is fine: an empty room is dropped, and whoever arrives next claims the key
  uncontested.

**2. Custody of the world — the relay should hold it too, and this is the better answer. BUILT
2026-08-17 as `world.v1`.** The
tempting design is for the incoming host to adopt from its own last-known view, but every peer has
a slightly different and slightly stale one, so which peer takes over changes what the world
becomes. Instead let the relay keep the latest **opaque** blob per entity and hand it to whoever
takes the lease. That is the same trick escrow already uses for its deposits and `Join.State`
already uses for late joiners — the relay stores bytes it cannot read — so it stays exactly as dumb
while giving migration one canonical source instead of N approximations. It also fixes late joins
for free: a player arriving mid-session gets the world from the relay rather than waiting for the
host to re-describe it.

**3. Simulation — never the relay.** Running the AI, resolving damage, deciding what the enemies
actually do is the one excluded model, because it is the point where the relay would have to
understand the game. That is the line the whole architecture rests on and none of the above moves
it: the relay decides *who* simulates and stores *what they last said*, and never simulates.

What shipping it actually cost was four corrections to that paragraph's obvious implementation,
each of which would have produced silent permanent divergence — two clients looking at different
worlds, with no error anywhere. They are recorded as an ADR in `architecture.md` and asserted by
tests in `relay/world_test.go` that fail without them: a lossy write may not skip the sequencer's
lock; the adoption snapshot must be built *inside* the lease grant; world lifetime must never be
tied to lease lifetime; and the pre-existing late-join seed had the same missing lock, which only
state's own self-correction was hiding. A fifth arrived from the soak rig rather than from reading:
**a lossy write replaces the whole blob**, so a blob mixing a continuously-superseded field with
one that must not regress can be dragged backwards by an inbound reorder — the two kinds of state
belong on separate keys.

**What is still genuinely hard is the handover, not the bookkeeping.** Whatever the old host knew
and never sent — RNG state, AI internals, half-finished timers — is gone at migration, and shows up
as a visible discontinuity: enemies snapping to their last replicated pose, or forgetting what they
were doing. Custody by the relay narrows that to "everything that was never transmitted" rather
than "everything the new host happened to miss", which is a real improvement but not a solution.
Same shape as the lease-lifetime problem this document already calls the hard part: **the mechanism
is cheap and the failure handling is where the work is.** None of it is relay work; all of it is
per-game.

**It does not need a save write**, which is worth stating because the instinct is to assume it
does: spawning and driving entities is runtime state, exactly like the ghost pawn the Pseudoregalia
adapter already clones and poses through the game's own systems. `CLAUDE.md`'s save rule is
untouched by any of this.

#### There is no host: authority is per loaded zone (2026-09-15)

The subsection above says "who owns the enemies" as if it were one key, and a user question showed
the hole in that reading: *"what happens if another player goes to another zone the host hasn't
been to / is not currently in? Who has ownership / decides what happens in multiple separated
zones?"* The case in mind was Rain World, which the user describes as loading and simulating one
whole zone at a time, with every other zone unloaded until a player enters it. A "host" that
decides the world from its own view has no view of a zone it never loaded.

**The answer is that nothing built is world-scoped, so nothing built needs a host.** A lease is
held per opaque key (`relay/leases.go`), custody is namespaced per authority key (`relay/world.go`'s
`worldKey`), a new holder adopts only that key's blobs (`worldSnapshotLocked`), and releasing a key
deliberately leaves its world in place (`freeLeaseLocked`). So the unit of authority is **whatever
the game loads as a unit**, and the lease key names it — `zone:<id>` — one owner per loaded zone,
different zones with different owners, a player alone in a zone owning it. The first player into a
zone owns it, exactly as the user guessed. Every case falls out of the primitives with no relay
change:

| Case | What happens |
|---|---|
| Enter a zone nobody has loaded | The claim is uncontested; the adoption snapshot carries custody's last blobs for that key, if anyone was ever there |
| Enter a zone someone else owns | The claim is refused; the adapter suppresses its own spawning and renders the owner's stream |
| The owner leaves, others remain | The owner's game unloads the zone, so it releases; the next claimant among those still inside takes over, seeded from custody |
| The owner leaves, the zone is empty | It unloads everywhere and custody holds it un-owned until the next entrant. Nobody simulates an empty zone — which is exactly what singleplayer does, so this case is 1:1 for free |
| Two players enter at once | Arrival picks one, the same as every other lease |
| State that belongs to the group, not a zone (a cycle timer) | Its own coarser key, held by whoever asked first; granularities coexist on one primitive |

**The claim has to go out when the transition starts, not when the zone is up.** Claim → wait →
act still holds, and a load screen is the one place the round trip is free: the answer lands before
the zone's first simulated frame. A game that cannot stall its load has already spawned everything
locally by the time it hears "no", and the loser despawns at the load boundary — a rollback, but
the only kind that is invisible.

**What it costs is that the handover stops being exceptional.** The discontinuity above — enemies
snapping to their last replicated pose, forgetting what they were doing — is paid on every zone
crossing where somebody stays behind, not once per host disconnect. One handover is cheaper than a
world-wide key would make it, because adoption sends only that key's blobs; the total is not.

Two things per-zone authority does not answer, and they stay open:

- **An entity that crosses zones.** A creature walking from one owner's zone into another's is a
  handoff between two authorities: a `drop` under one key and a `set` under another, by two
  different clients, and nothing makes that atomic — custody is namespaced by authority precisely
  so the relay never has to arbitrate the collision. Coarser zones, or a per-game handoff rule, are
  the options; nothing built decides it (`kill-credit.md` #20).
- **The ceiling is per room, not per zone.** `contract.md`'s 64 entities of custody are shared by
  every loaded zone in the room (`kill-credit.md` #19).

**And one coupling to refuse.** The adapter derives the zone key from what its game loads as a
unit; the core never derives it from `area_id`, whose granularity is chosen for what the adapter
*displays* (`culling.md`) and can legitimately differ. Same rule as `CLAUDE.md`'s "compare by
equality only": the moment game-agnostic code turns an `area_id` into an authority key, it is
branching on its contents. Nothing here needs a save write — custody is runtime state, as the
paragraph above already says — and, as everywhere in this file, recording it is not permission.

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

**SHIPPED 2026-08-17, exactly as argued.** This is no longer a proposal: `newRoom` stores
`protocol.RoomScopedFeatures(features)` on the room, and `joinOrCreateRoom` rejects a join whose
`protocol.FeatureSetKey` differs from the room's — the `GameVersion` pattern, by string equality,
with the relay still learning nothing about what any capability means. Only the *room-scoped* half
is agreed this way; per-client capabilities stay per-client.

### Per room, never per user — and a personal override only ever lowers (2026-09-15)

The user asked whether "sync more or less" could be a per-client config toggle. It cannot, and the
reason is the hazard above: "shared" only means something if every member shares it, so a client
that syncs enemies beside one that does not suppresses its spawns and waits for a stream the other
never sends. Nothing errors and the two worlds silently diverge. **How much is shared is a property
of the room**, settled the way the feature set already is — the first joiner's choice becomes the
room's, a later joiner whose config wants something else is refused with a reason.

What a per-user setting may legitimately do is the one-way rule ADR 0035 already established for
ghost collision: a room can turn a thing off for everyone, and a client can opt further out for
itself, but a client can never force more onto others. And "more or less" is not one slider: the
depth ladder gives the level, and inside a level the choice is per entity class (`kill-credit.md`'s
liveness, credit and difficulty; `game-shapes.md`'s own inventories, shared enemies, leased
doors). The practical form is a **named preset the adapter defines** — "ghosts", "shared world" —
that expands into a feature set plus per-class policies. The relay sees only the opaque strings.

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
| **Persistence** | **REFUSED as the default**, and reopenable on a concrete game need as an opt-in (2026-09-07) — rooms still deleted when empty; nothing on disk but the log | **No** — new subsystem, and see below |
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

#### Reopenable on a concrete game need — the user's position, 2026-09-07

**The refusal stands as the default and is not closed forever.** The user's framing, on being shown
what it rules out: *"its kinda nice that the server don't really need to save/use anything or make
any files except for the log file. but i guess it can be considered if a game would ever need
something persistent"*. So the bar for revisiting is **a specific game that needs it**, not a general
argument that it would be nice — and the disk-free relay is treated as a feature worth keeping rather
than an accident to be corrected. `game-shapes.md` §3 records what the refusal currently costs: every
asynchronous way of playing together (leaving a note, a mark or a structure for someone to find
later) needs storage and *nothing else* — no simultaneity, no authority, no prediction.

**Whoever revisits it should first notice that "persistence" is two different things, and only one of
them is what this section refused.**

- **Durable relay state** — rooms, leases, identities and exchanges surviving a restart. This is the
  expensive one and the refusal above is about it: a schema the relay understands, therefore
  migrations, corruption handling and backups, therefore an operated service.
- **A bounded dead-drop** — an opaque blob left for a recipient, size-capped and expiring. Much
  narrower, and **the relay already stores exactly this shape in memory**: escrow deposits, world
  custody and `Join.State` late-join seeds are all opaque blobs it cannot read. The delta is that one
  survives a restart and carries a TTL. There is no schema to migrate, because there is no schema.

**That narrowing is an observation for a future session, not a recommendation and not permission** —
§11 applies here as everywhere. It still crosses the line this section drew (anything on disk is
something that can be corrupted, filled or leaked, and it is still a file the host now owns), so it
is a smaller step rather than a free one. But the asynchronous family needs only the second kind, and
pricing it against the first would overstate it substantially.

#### If it is ever built: opt-in, never the default — the user's second condition, 2026-09-07

*"I think its an option we should consider, but also as an opt in and not the default if possible?
not all games will need it."* **That lands exactly on the rule §3 already ratified** — *"Everything
past cosmetic is adapter-opt-in via `features`, never relay-imposed via `game_id`"* — so the shape is
settled and the mechanism is already built: persistence would be one more `.v1` capability on the
existing sticky, room-scoped feature set, alongside `world.v1` and `escrow.v1`. A game that does not
need it never asks, and the code path never runs for that room.

**But it is the first capability that would need TWO levels of opt-in, and that difference is the
part worth recording.** Every other capability costs only the clients that negotiate it. This one
costs **the person running the relay**, who owns the disk, the cleanup and the backup:

1. **Relay-side, off unless the host turns it on.** No flag, no storage, no file — ever.
2. **Room-side, negotiated via `features`**, exactly as today.
3. **A room asking for it on a relay without storage is refused at join**, which needs no new
   mechanism: `joinOrCreateRoom` already rejects a feature-set mismatch by string equality.

**The invariant to preserve, stated so it can be tested rather than assumed: a relay nobody
configured writes nothing but its log.** Worth knowing that this is currently true *structurally* —
as of 2026-09-07 there is no file-writing call anywhere in `relay/` or `cmd/meshghost-relay/` outside
a test, so the property is enforced by absence, which is the strongest form there is. **The moment
storage exists, absence stops guaranteeing it and it becomes something a test must pin.**

**Superseded 2026-09-15 by ADR 0066: an unconfigured relay now writes more than its log.** TLS is
always on and the relay's identity is persisted — `private/server.key`, `server.crt`,
`server.fingerprint` and a `README.txt`, written through `netx/tlsx.WriteFileAtomic` beside the
relay's config. So "enforced by absence" no longer holds and the disk-free relay this section
called a feature worth keeping is already gone. What survives is the narrower claim, and it is the
one that matters: **the relay writes only about itself, never a byte a client sent it.** That is
now the line, and the shape below is what crossing it would look like.

**And the honest half: opt-in makes the DEFAULT cost zero, not the TOTAL cost.** The code, its tests,
its corruption handling and its security surface exist in the tree whether or not anyone enables it.
A dead-drop is untrusted, client-keyed data written to a host's disk, so bounded total bytes, a TTL,
and never deriving a filename from a client-supplied string are requirements rather than polish —
see [security-design.md](security-design.md). "Opt-in" answers *who pays at runtime*; it does not
answer *whether the project wants to carry it*, and that second question is the one §11 reserves.

#### The shape, agreed 2026-09-15 — a design on record, nothing built

Fleshed out with the user across one conversation (the Rain World zone question, then Carrion as a
"share everything" case, then the lobby, then the `private/` precedent). Recorded so the next
session starts from these decisions rather than re-deriving them. **The user's bar is unchanged:
built with the first shared-world adapter, not before**, and Carrion is still an unopened candidate
(`candidate-games.md`).

**1. A lobby is a wait, not a role.** Whoever arrives first already creates the room and fixes its
feature set, version and policies, by arrival — that is the only "host" the authority side needs,
and it is deliberately not a simulation role (§2, "There is no host"). What a shared world adds is a
*wait*: a client's game must not load a world until the room has told it whether it is **seeding**
or **adopting**. That is claim → wait → act applied to the whole world instead of one item. Three
pieces, none a new relay subsystem:

- the room as it exists (join or create, sticky features, refuse mismatches);
- **the world origin as a leased key** — the first claimant seeds custody from its own save, and
  everyone after adopts from custody; the relay stores bytes it cannot read, exactly as `Join.State`
  does today, and never learns that a save was involved;
- **holding the game before world load**, adapter-side and per game: the adapter keeps the game at
  the main menu, or whatever state precedes loading a world, until the core says seed or adopt.
  This is the only genuinely new capability, and it is entirely about what a given game allows.

**2. Whose save is the world: the first one in, every session — unless custody persists.** With no
persistence the room dies when its last member leaves, and the next session's first arrival seeds
again from *their* save. That is fine as long as everyone plays together, because each client's
game wrote its own save from the same shared state, so the saves agree; it forks the moment
someone plays alone in between. Every host-saved co-op game has exactly this property, and the two
honest answers are theirs: accept it, or store the world on the relay. **Nothing here writes a
save: the game writes its own, through its own mechanism, from the state the adapter fed it.**
`CLAUDE.md`'s rule is untouched, and a shared-world preset still needs its per-game ADR to say so
explicitly, because "the game did it" is the exact sentence that rule exists to be suspicious of.

**3. Persisting custody is the dead-drop, and the split is world yes, authority never.**

- **World custody may persist**, as the bounded dead-drop this section already priced: an opaque
  blob per key, a size cap on the total, a TTL, and a file name never derived from a client string.
  Corruption handling is cheap *because the relay cannot read the blobs*: no schema, so no migration
  ever; a bad file is a hash mismatch and the answer is discard and start fresh, which is what a
  dropped room does today. Backup is the host copying a folder.
- **Leases never touch disk.** A lease means "this connected client is simulating this key right
  now"; across a restart every holder is gone, so a persisted lease is wrong or immediately
  released. Same for identities and exchanges — the refusal above stands for durable relay state.
- **Both opt-ins stand**: off unless the relay host turns it on, negotiated per room via
  `features`, refused at join on a relay without it (the three-step list above, unchanged).
- **A new binding, found here:** a world keyed by game and room *name* on a shared relay would
  hand one group's world to the next group that picks the same name. The stored world has to be
  bound to the room code as well — which is one more reason the code should leave the wire as a
  PAKE (ADR 0066's plan step 5) before any of this is built, so the binding is to something proven.

**4. What persistence does not simplify, so nobody expects it to.** The hold before world load is
still per-game work; persistence only makes "adopt" the usual answer. Suppressing the game's own
authority for every entity type in a zone someone else owns is still the deepest per-game work on
the list. And the custody ceiling — 64 entities per room, derived from the reorder window, not from
storage — is untouched: a world the size of a save probably wants **one origin blob** rather than
sixty-four small ones, and that sizing question is open (`kill-credit.md` #19).

**5. One shipped behaviour flips under a shared-world preset.** A downed relay no longer refuses
the game (ADR 0050), which is right for ghosts. A shared session cannot start offline, so that
preset must refuse instead — one more thing settled at join, never in a config file.

As everywhere in this file: a shape on record is not permission. Building any of it is a contract
revision with its own ADR, and the memory-write gate in `plans.md` applies.

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
  §9, uniform won: one number rather than a capability difference that only shows up in the field,
  at the cost of a smaller ceiling than a stream transport could carry. **The number does not yet
  deliver that intent** — 1024 bounds the *payload*, and a maximal envelope is 1321 bytes, over
  `udpconn.MaxDatagramBytes`. See §9 below and `risks.md`; pinned since 2026-08-18 by
  `netx/udpconn/world_bounds_test.go`.
- **`seq` is inert.** `protocol.State.seq` is documented "for ordering", written by
  `core`, and read by nothing. **Still true, and now deliberately so**: the event plane
  got its own room-wide `Event.Seq` rather than reusing this one, because a per-client counter on a
  lossy plane means nothing across senders and a total order has to come from the relay. The two
  are different things that happen to share a word.
- **Versioning is the one that matters most.** `ProtocolVersion` is an exact-equality check, so any
  bump hard-rejects every existing client. New capability must therefore travel via `features` plus
  the unknown-field/unknown-type tolerance, and a `Version` bump stays reserved for genuinely
  breaking changes. **Stating this is most of what keeps the door open** — it is the difference
  between adding a feature and orphaning every deployed client. **Held in practice 2026-08-17**:
  seven capabilities (`event`, `lease`, `escrow`, `snapshot`, `resume`, `world`, `clock` — all `.v1`),
  four message types, and eight new fields shipped with `ProtocolVersion`
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

Not "if it is important" — if `core` or `relay` must *read* it. On the event
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

That turned `MaxEventBytes` — at the time a placeholder in `contract.md` with **no number** — into
a real decision with two honest options:

1. **Uniform**: set it to what every transport can carry (~1200 minus overhead). Simple, and
   restrictive for everyone because of udp.
2. **Transport-dependent**: a udp client genuinely cannot do large events. A real capability
   difference, and exactly the kind of thing `features` exists to negotiate.

**CLOSED 2026-08-17 at 1024 bytes, uniform** (option 1) — see §"Closed decisions" above.
**And option 1 was not achieved**: 1024 was set against the *payload*, so a maximal envelope is
1321 bytes and still exceeds the udp budget it was meant to fit inside. The choice stands; the
number does not yet implement it. `risks.md` has the measurement, `bandages-core.md` the entry.

**Argue against app-level chunking.** Fragmenting a payload across lossy datagrams reinvents TCP,
badly, and worse than the version the kernel already provides. If a payload is big the answer is a
stream transport, or sending a *reference* rather than the data.

## 10. Tooling — what would have to exist to test any of this

Most of the rig already exists and is better than it looks: `cmd/meshghost-fakeadapter` doubles as
an N-client synthetic load generator, `internal/e2e` launches the real binaries, `-loopback` gives
a one-machine round trip, the race detector runs locally as well as in CI (since 2026-08-18), and
CI runs all eleven fuzz targets. `testing.md` and `dev-scripts/README.md` are the inventory.

What is missing splits cleanly by **which bug class it catches**:

| Tool | Catches | Status |
|---|---|---|
| **Adverse-network proxy** | anything that only breaks under loss/latency/jitter/reorder/partition | **BUILT 2026-08-16** — `cmd/meshghost-netsim` |
| **Invariant harness over N clients** | concurrency bugs (one lease holder, no dupe/loss, consistent order) | **BUILT 2026-08-17** — `relay/online_test.go` |
| **Divergence detector** | two peers silently disagreeing about shared state | reserved |
| **Record / replay** | a desync seen once and never again | reserved |
| **Crash injection at protocol points** | atomicity — the half-finished trade | **BUILT 2026-08-17** — `relay/online_test.go`'s crash-mid-exchange tests |
| **Relay introspection** | "what does the server think is true right now" | **BUILT 2026-08-17** — `Server.Snapshot`, `meshghost-relay -introspect`; extended 2026-08-18 with cross-area state fan-out counters (`StateFanoutSnapshot`) |
| **Client-side link/render stats** | "what does the client see, and how much of it does it throw away" | **BUILT 2026-08-18** — `meshghost -stats=<dur>` (`core/stats.go`): rtt, clock offset, peers known vs rendered, bytes in/out |

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

`plans.md` (depth ladder, non-goals) · `kill-credit.md` (the worked design for one problem this
file leaves open: who gets the reward, and when a shared enemy is dead) · `contract.md` (event
plane, packet schema, transport contract) · `architecture.md` (the exclusion, and the ADR log) · `access-models.md` (what each game
lets you read) · `bandages-core.md` (Go-side compensations) · `culling.md` (area granularity is the adapter's display choice, never an authority boundary)
