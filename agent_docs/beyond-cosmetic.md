# Beyond cosmetic — what a deeper online mode would actually take

**MeshGhost is visual-only, and that is not changing here.** Nothing in this file is scheduled,
proposed, or approved. It exists because the architecture must never *trap* the project at
cosmetic, and the way to guarantee that is to know — before anyone needs it — which doors are
already open, which need building, and which are welded shut.

Read `plans.md`'s depth ladder first for the tier framing (0 cosmetic → 3 consensual interaction),
and `contract.md`'s Extensibility section for the reserved event plane. This file is the *concept*
layer under both: sync models, authority, and the honest gap list.

---

## 1. What is already reserved, and already built

A future session should not re-derive any of this. It exists today:

| Thing | Where | State |
|---|---|---|
| Depth ladder, Tier 0-3 | `plans.md` | documented |
| Event plane (`event` type, `to` addressee, opaque payload) | `contract.md` Extensibility, `protocol.go` | **declared, no routing** |
| `features` capability list on `hello` | `protocol.go`, `contract.md` | **declared, nothing populates it** |
| Recipient-set forwarding | `relay.Room.Forward(msg, to []string)` | **built** — shaped for addressed routing from the start |
| Unknown *fields* ignored | `contract.md` | built |
| Unknown *message types* ignored | both dispatch switches | built |
| `send` reliable **and ordered** on every transport | `contract.md`, `udpconn` | built (ordering added 2026-08-16) |

The single most valuable one is `features`: it had to exist *before* clients shipped, because a
client built without it has no way to say what it supports. That one field is most of why deeper
work is still possible at all.

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
| **Simulation authority** | runs game logic, validates actions | **yes — excluded** |

Sequencer and lease authority are *real* server authority in the practically useful sense, and both
keep the relay completely dumb. They are the same trick `area_id` and `anim` already use: an opaque
string compared by equality, nothing more.

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

| Gap | State today | Dumb relay enough? |
|---|---|---|
| **Atomicity / escrow** | **discussed nowhere in this repo** | **Yes** — relay holds an opaque blob, releases on commit/abort |
| **Late-join world snapshot** | `Join.State` reserved but never populated; relay stores no per-player state at all | **Yes** — relay keeps the last opaque state blob per player |
| **Clock sync** | ping/pong exists, but core has no `TypePong` handler and records no send time — RTT is not even computable | **Yes** — relay serves time |
| **Stable identity** | `player_id` is a bare counter, resets on relay restart, no session resumption | **No** — new subsystem |
| **Persistence** | rooms deleted when empty; nothing on disk but the log | **No** — new subsystem |
| **Anti-cheat** | none possible | **Never** — catching a lie requires knowing what is true |

Three ride the same opaque-blob trick. Two are genuinely new subsystems. Exactly one is impossible
by construction — and **knowing which one is impossible is worth more than the rest.**

### Atomicity deserves the most emphasis

It is the one gap with real-world precedent for damage, and the repo has never written a word about
it. **A lease grants exclusive *access*, never an atomic *swap*.** A trade is two-sided — both or
neither — and if one side vanishes after handing over, an item is destroyed or duplicated. That is
exactly where historical Pokémon trading exploits came from.

`plans.md` currently asserts trades are tractable *because* they are bounded and consensual, and
never examines the one-side-vanishes case. The repo is protected today only by accident: nothing
game-affecting is implemented at all.

### Persistence changes the project's character

Worth flagging separately: a persistent relay needs storage, backups, migrations and corruption
handling. It stops being a thing a user runs from a `.bat` file. That is a bigger change than its
one table row suggests.

---

## 6. The near-free implementation path (a cost note, not a proposal)

Recorded so nobody re-scopes it from scratch:

- `Room.forward` already serialises under `r.mu` to snapshot targets, so a per-room monotonic stamp
  assigned inside that existing critical section is a handful of lines.
- `Room.Forward` already takes an explicit recipient set, shaped that way deliberately for addressed
  routing.

**The sequencer half is cheap.** Leases, escrow and lifetime handling are not.

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

- **`MaxEventBytes`** is a documentation placeholder in `contract.md` with no number.
- **`seq` is inert.** `protocol.State.seq` is documented "for ordering", written by
  `internal/core`, and read by nothing. Ordering is currently a transport property; if anything ever
  needs application-level ordering, this is the field waiting for it.
- **Versioning is the one that matters most.** `ProtocolVersion` is an exact-equality check, so any
  bump hard-rejects every existing client. New capability must therefore travel via `features` plus
  the unknown-field/unknown-type tolerance, and a `Version` bump stays reserved for genuinely
  breaking changes. **Stating this is most of what keeps the door open** — it is the difference
  between adding a feature and orphaning every deployed client.

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

For scale, a measured Pseudoregalia state line is **597 bytes** — already half the udp budget. A
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
a one-machine round trip, and CI runs the race detector plus five fuzz targets. `testing.md` and
`dev-scripts/README.md` are the inventory.

What is missing splits cleanly by **which bug class it catches**:

| Tool | Catches | Status |
|---|---|---|
| **Adverse-network proxy** | anything that only breaks under loss/latency/jitter/reorder/partition | **BUILT 2026-08-16** — `cmd/meshghost-netsim` |
| **Invariant harness over N clients** | concurrency bugs (one lease holder, no dupe/loss, consistent order) | reserved |
| **Divergence detector** | two peers silently disagreeing about shared state | reserved |
| **Record / replay** | a desync seen once and never again | reserved |
| **Crash injection at protocol points** | atomicity — the half-finished trade | reserved |
| **Relay introspection** | "what does the server think is true right now" | reserved |

**Only the first was built, and only because it has a present-day consumer** — the rest would be
code with nothing to exercise it, which is the same reasoning the event plane itself was reserved
under. The proxy earned its place immediately: `testing.md` already recorded that jitter and clock
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
