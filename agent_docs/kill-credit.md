# Kill credit and participation — the foundation under any enemy sync

**Nothing here is scheduled, and nothing here is approval.** This is the concept layer for one
problem, sitting under `beyond-cosmetic.md` the way that file sits under `plans.md`'s depth ladder.
Anything past Tier 2 still needs its own per-game ADR in `adr/` and the memory-write
gate in `plans.md`. A later session reading a worked-out design as a decision to build it is
misreading it exactly as badly as `beyond-cosmetic.md`'s last section warns.

Filed 2026-08-19 from the `ideas.md` entry, and written out because of what that entry claimed:
**kill credit is the precondition for ever syncing enemies or bosses at all.** Without it there is
no principled answer to "is this enemy dead?", so shared enemies are not buildable. A naive "the
boss died" broadcast kills it for people who never fought it — denying them the fight *and* the
reward, and leaving it unkillable for them afterwards.

**The finding that changes how expensive this looks: it needs no changes to `relay`, `core`,
`protocol` or the wire contract.** Everything below rides `event.v1`, `lease.v1` and `world.v1`
exactly as they were built 2026-08-17. All of the game-specific work is in an adapter, which is
where `CLAUDE.md` requires it to live. If an implementation ever finds itself wanting a `game_id`
branch or a relay that understands damage, it has left this design.

---

## The core idea

> **Don't sync "the enemy is dead". Sync *damage*, and let every client's own game arrive at death
> by itself.**

Each client keeps its own copy of the enemy. Damage dealt by anyone is published as an ordered,
opaque event; a client applies that stream to its own copy **if and only if it is a participant**.
A participant's copy reaches zero on its own, at about the same moment as every other participant's,
and dies through the game's **own** death path. A non-participant's copy never receives a point of
it and stands at full health.

Why this is the right primitive and not an implementation detail:

- **Death becomes derived, not announced.** The death animation, the corpse, the drops, the
  soul/rune award, the fog gate, the "enemy felled" banner — all of it is the game doing what it
  already does when you kill something. That is the stated bar ("as if you normally kill an enemy
  in a game"), and it is the same instinct as letting the game's own systems drive a ghost rather
  than reimplementing them.
- **No reward is ever written by us.** We never grant items, runes or XP; the game grants them
  because the game killed the enemy. The read-only default and the absolute save rule are untouched
  — which they would *not* be under a "boss died, now hand everyone the loot" design.
- **There is no last-hit concept to get wrong.** Simultaneous kills, kill-stealing and last-hit
  races all evaporate: everyone crosses zero on their own copy.
- **Per-client liveness falls out for free** rather than needing its own mechanism — it is just
  "did I apply the ledger". And a game that wants the opposite gets that for free too (see
  Policies).
- **No formula divergence.** Reports carry *final, post-mitigation* numbers computed by the dealer
  and applied as plain subtraction. Nobody re-runs a damage formula, so nobody drifts. The one
  precondition — that the number means the same thing on every client — is where difficulty modes
  can break it, and has its own section.

### Three questions that get conflated, and must not be

| Question | Answer | Where it lives |
|---|---|---|
| **Authority** — who simulates the enemy? | one peer, holding an opaque authority lease | already built: `lease.v1` + `world.v1` |
| **Liveness** — is it alive *in my world*? | per-client, derived from the ledger | adapter |
| **Credit** — do I get the reward? | per-client, derived from participation | adapter |

Treating these as one question is the failure mode. They have different answers, different owners,
and only the first involves the relay at all.

---

## The model

### Keys and planes

One enemy is one opaque key — `er:limgrave:tree-sentinel:g7` — a string the relay compares by
equality and understands nothing about. Two planes, split the way `contract.md`'s world-custody
section already instructs:

- **Pose and AI** — a `world` key written **lossily** by the authority lease holder. Continuous,
  superseded every tick, safe to drop.
- **The damage ledger** — increments published as `event`s by the *dealer* (reliable, ordered,
  sequencer-stamped, echoed to the sender), with the running total folded into a `world` key
  written **reliably** by the lease holder, so late joiners and a successor host get it from relay
  custody.

Keeping those on separate keys is not tidiness. `contract.md` records that a lossy write replaces
the whole blob, so a blob mixing a continuously-superseded field with one that must never regress
can be dragged backwards by a reorder and never corrects itself.

### Participation

- You become a participant on your **first damage report** for the current generation. One point is
  enough.
- **Credit at death requires all three: you dealt damage, you are alive, and you are in the
  encounter.** Die and run back — you keep it, with no need to land another hit. Die and stay dead
  — nothing. Tag-and-wander gets caught by the same rule.
- A non-participant never applies the ledger, so its copy simply never loses health.
- **Joining mid-fight** means catching up: on your first report you apply the accumulated total, so
  your copy snaps from full health to wherever the fight actually is. **This is a real visible
  discontinuity** and it is the price of showing non-participants a pristine copy at all. It is
  what happens in any MMO when you attack a mob someone else has been fighting; the difference is
  that no MMO showed you a pristine copy beforehand.

### Generations

Every reset — leash, wipe, respawn, a rest that re-populates an area — bumps a **generation
counter** in the key, and reports from an older generation are discarded. Without it a report in
flight across a reset lands on the fresh enemy and quietly damages it, or a re-fight inherits the
last fight's totals. Cheap now; invisible and maddening later.

### Exactly-once application

Each report carries `(dealer_id, dealer_seq)` and every client keeps an applied-set. The sequencer
guarantees one identical total order, but a client resuming after a blip — or folding both the
event stream and an adoption snapshot — can otherwise apply the same hit twice.

### Signed deltas

The ledger carries **signed** amounts, not damage only. Enemy regeneration and heals have to ride
the same stream or the totals drift away from what each client's copy actually shows.

---

## Policies — the above is the *default*, not the only answer

The default is the assumed behaviour; **a game selects a different policy per entity class where
its own design demands one**, and this needs no second mechanism. The ledger is unchanged; what
varies is who applies it.

| Axis | Options | Decides |
|---|---|---|
| **Liveness** | `per-participant` (default) · `shared` | who applies the ledger, and therefore who sees it die |
| **Credit** | `participants` (default) · `killer` · `everyone` | who receives the game's reward |
| **Difficulty** | `ratchet` (default) · `match-required` · `normalized` · `independent` | how an enemy is scaled when clients *disagree* about its size |
| **Player-count scaling** | `none` (default) · opt-in per entity class | whether more players makes an enemy tougher at all |

Set independently. The default combination is `per-participant` + `participants` + `ratchet` +
`none` — which, for a group all playing the same difficulty, means **every enemy behaves exactly as
the game shipped it**.

Two worked examples, both of which came from asking what specific games actually do:

- **Rain World — `shared` liveness.** Everything in a zone is loaded and simulated at once, so a
  creature someone else killed genuinely *is* dead for everybody; a per-client copy standing back up
  would contradict how the game models its world. Every client applies the ledger regardless of
  participation. Credit stays a separate question and can still be `participants` or `killer`.
- **TEVI — split by entity class, inside one adapter.** Bosses take the default, because a boss kill
  is an event with a reward attached. Ordinary roaming enemies take `shared` liveness, because TEVI
  already respawns them when you leave a room and re-enter within a zone — so "it died for everyone
  and came back later" is the game's existing behaviour rather than a compromise. **The policy is
  per entity class, not per game**, and that is the important half of this example.

**One consequence that is easy to miss: under `shared` liveness the reset predicate becomes shared
too.** TEVI's respawn is "the room was left and re-entered" — with one shared copy that has to mean
*everyone* left and re-entered. Otherwise one player standing still keeps a room permanently cleared
for the others, while another walking in and out resurrects enemies mid-fight for everybody. The
generation bump is the mechanism; agreeing *when* to bump is per-game work, and it is genuinely
harder under `shared` than under the default.

Rain World also runs straight into the entity ceiling below: a zone simulated all at once is many
more creatures than a boss arena.

---

## Difficulty modes — the unit problem

A boss can have different maximum health on each client, because each player picked their own
difficulty. This exposes a rule the design needs stated outright:

> **The ledger must carry damage in a unit that means the same thing on every client.**

Absolute health is not that unit when maximum health differs. Deal 400 to a 1000 HP boss and you
have done 40% of the fight; deal 400 to the same boss at 3000 HP and you have done 13%. Applying
one absolute number to two differently-sized copies makes them die at different times — and under
`shared` liveness it is outright contradictory, because there is then no answer to "is it dead".

**Difficulty is also much broader than health**: it typically changes enemy damage output, attack
patterns, spawn counts and invulnerability windows. Fixing only the health axis leaves two players
fighting visibly different bosses.

### The default: `ratchet` — hardest difficulty present, and it never goes down

> **An encounter's scale is the running maximum over its participants, and it only ever increases.**
> It starts from whoever opens the fight, ratchets up when someone on a higher difficulty joins in,
> and never decreases — not when that player leaves, not when someone easier joins, not on a death.
> Only a generation bump recomputes it from scratch.

In the ordinary case — everyone on the same difficulty — **nothing ever ratchets**, and the
behaviour is indistinguishable from refusing mismatched difficulties outright.

#### Who counts as "present"? The participants, and nobody else

The tempting answer is "everyone in the area when the fight starts", and it does not survive the
obvious objection: **people stagger into a boss room**, so there is no crisp moment to evaluate.
Two clients can genuinely disagree about whether someone had entered "yet" — one has them loaded,
another has not seen their `area_id` change, a third is mid-transition — and no authority can settle
it without game knowledge. That generalises into the rule worth remembering:

> **Presence is a fuzzy, unordered, per-client observation. Damaging something is a discrete event
> with an exact position in the room's total order.** Build the shared rule on the one the sequencer
> can order.

So the scale is the running maximum over the players who have actually **damaged** it, folded in
sequencer order. Every client folding the same ordered stream computes the same maximum at the same
point — no agreement protocol, no presence tracking, and no decision about whether an "area" means
a room or a zone. Stagger stops being a problem rather than being solved: a latecomer who joins the
fight simply ratchets it.

**This holds under `shared` liveness too**, which is why it is the universal rule rather than a
per-policy one: a bystander sharing the copy sees it at the participants' scale, and the moment they
join in, it ratchets to include them.

#### How a ratchet preserves progress without re-valuing anything

Each ledger entry is recorded as a fraction of the scale in force when it was dealt, and remaining
health is `(1 - Σfractions) × current_max`. A ratchet therefore changes what *future* damage is
worth and never what past damage was worth. The visible effect is the kind one: **the maximum grows
and the proportion remaining does not move.** No damage is refunded, no progress is lost, and no
entry is ever rewritten.

Two consequences to state plainly, because both will surprise someone:

- **A fight can get harder mid-way and never gets easier again.** If the Hard player leaves right
  after ratcheting it up, everyone else finishes the harder version. That follows directly from
  "never scale downwards" and is intended, not a bug.
- **The opener's damage is worth slightly more.** The first hit lands against the first attacker's
  own scale, so an Easy player opening before a Hard player joins contributed a larger fraction than
  they otherwise would have. The alternative — waiting to see who shows up before the first hit
  counts — is the stagger problem again.

**Presence does not disappear from the design**, it just stops being a *shared* decision. The credit
rule still requires being alive and in the encounter at the kill, but each client evaluates that
locally, about itself, on its own copy, at its own moment of death. Nobody has to agree with anybody,
so stagger cannot hurt there either.

### Player-count scaling is a different knob, and its default is off

These look alike and are not:

- **The ratchet resolves a disagreement.** Two clients think the same boss is a different size
  because they picked different difficulty modes; somebody has to win, and it is the harder one.
- **Player-count scaling invents difficulty the game never had.** Making a boss tougher because
  three people are fighting it is a design change to the game, not a reconciliation of anything.

So it is its own axis, per entity class, defaulting to `none`:

- **Super Mario Sunshine — `none`, everywhere.** The game scales nothing for anyone, and its enemies
  should not get harder just because more players are present. Leaving it alone is the correct
  answer, not a missing feature.
- **Super Metroid — `none` for ordinary enemies, boss health scaling opt-in.** Bosses could
  reasonably carry more health with more players while the regular enemies stay exactly as they are
  — split by entity class, in one adapter, like TEVI's liveness split.

**It is a decision about what a game is meant to feel like, so it is the user's call per game and is
never inferred from the code.** `CLAUDE.md` requires confirmation of intent before changing what the
player experiences, and inventing a difficulty curve a game never had is squarely that. The default
is `none` precisely so that doing nothing is the path of least resistance.

Health scaling is not free even where it is wanted: games with HP-gated phase transitions, scripted
deaths, or a tuned item economy (Super Metroid's missile supply being the obvious one) can respond
to a bigger health pool in ways that are not simply "the fight lasts longer".

### The alternatives, recorded and not adopted

- **`match-required`** — fold difficulty into the sticky `game_version` string an adapter already
  sends (`tevi-mod-1.4.2+hard`) and let the relay refuse a mismatched join at the handshake, before
  any state is exchanged, comparing strings and learning nothing. **Zero new mechanism**, and worth
  keeping on the shelf as the strict setting for a game whose difficulties change attack patterns so
  much that mixing them is incoherent past health.
- **`normalized`** — every copy keeps its own scale and they die together on fractions. Its real
  cost is not rounding: it silently runs the fight at the pace of the *lowest* difficulty present,
  which is the downward scaling that was explicitly ruled out.
- **`independent`** — absolute numbers against each client's own maximum, with the boss dying at
  different moments for different people. Coherent only under `per-participant` liveness, never
  under `shared`.

---

## The visibility cost, stated plainly

Under the default, a non-participant renders the same host-driven pose as everyone else — one enemy,
in one place, doing one thing — and only health, phase transitions and death are per-client. When it
dies for the fighters, **the non-participant is left standing beside a copy that did not die**, and
the pose stream it was rendering stops; their local simulation takes over from there. Multi-phase
bosses are where this is sharpest, since a non-participant's copy never transitions at all.

That is the accepted cost of "it stays alive for that client". If it proves unacceptable in
practice, the fallback is **reward-only gating** — one shared enemy that dies for everyone, with
participation gating only the reward. Recorded as the fallback, not adopted.

---

## Hard cases

1. **Killed by the environment or another enemy** — the game's own path; a non-participant's copy
   dying locally is simply their own kill.
2. **Damage over time, summons, pets, thrown items** — attributed to the owner, reported by the
   owner's client.
3. **A player leaves mid-fight** — dropped from the participant set; their entries stay in the
   ledger, because they happened.
4. **Host migration mid-fight** — relay custody hands the running total to the successor; the
   generation and the applied-set prevent a double-apply.
5. **Late join mid-fight** — the world snapshot carries the total; they are not a participant until
   they hit it.
6. **Overkill** — clamp at zero, first crossing wins; there is no last hit to award.
7. **Multi-phase bosses and HP-gated transitions** — the ledger drives them identically for every
   participant, and not at all for a non-participant.
8. **A wipe** — generation bump; ledger and participation cleared.
9. **Reordered or duplicated reports** — applied-set plus sequencer order.
10. **A participant disconnects between their last hit and the kill** — not present, so no credit;
    the fight is unaffected for everyone else.
11. **Two clients at different generations** — a client ignores anything not matching its own
    generation and re-seeds from custody.
12. **An enemy the game respawns naturally** — new generation, new key.
13. **A lying client** — out of scope by construction; see below.
14. **A shared-liveness reset only one player triggers** — under `shared` the reset predicate must
    be agreed by the whole room. One player walking out and back in must not resurrect a room's
    enemies mid-fight for everyone else.
15. **Mixed policies in one area** — a `shared` trash mob beside a `per-participant` boss is normal
    and must work; the policy belongs to the entity class and both ride the same ledger.
16. **A difficulty change mid-session** — upward is just another ratchet; downward must not lower an
    encounter already in progress. Under `match-required` it instead invalidates the sticky
    `game_version` the room agreed on, and the adapter has to rejoin rather than let the room drift.
17. **The high-difficulty player leaves after ratcheting** — the scale stays; the rest finish the
    harder fight.
18. **A ratchet landing at the same moment as a kill** — harmless under fractions: a copy already at
    zero remaining is dead, and growing the maximum cannot resurrect it.
19. **The 64-entity ceiling.** `contract.md` bounds world custody at 64 entities per room — derived
    from `udpconn`'s reorder window, not chosen — with blobs ≤768 bytes. Comfortable for bosses and
    genuinely tight for a field full of trash mobs. **This is the first place the design meets a
    real number rather than a worry.**

---

## Prior art — how other games actually answer this

Every option below was tried by somebody at scale, which is why the shape of the answer is not a
guess.

- **World of Warcraft — tapping.** Damaging a mob "taps" it; its nameplate greys out for everyone
  else and only the tapper or their party gets XP, loot and the corpse. Retail widened this to up to
  five ungrouped tappers, and since Dragonflight tags are no longer faction-specific. Outdoors only
  — inside an instance the whole party shares credit. **Rejected**: single-owner tagging is exactly
  the kill-stealing dynamic this design exists to avoid.
- **Old School RuneScape — first attacker or most damage.** Taggable monsters drop to whoever
  attacked first; untaggable ones, including most bosses, drop to whoever dealt the most damage,
  with some using a coffer that pays everyone who participated. **Rejected** for the general case:
  one winner per kill.
- **Guild Wars 2 — per-player loot with a damage threshold.** Loot is unique to each player and what
  one receives does not affect another, so kill-stealing does not exist as a concept. Credit needs
  roughly 5-10% of the enemy's health, supporting an ally transfers some of their damage to your
  participation, and there is a cap around the first 50 qualifying players. **Closest to what we
  want** — take the per-player-reward half, drop the threshold and the cap.
- **FFXIV — FATE contribution medals.** Gold/silver/bronze by contribution, with the reward scaled
  to the medal. **Rejected**: graded rewards are not "as if you killed it normally".
- **Elden Ring Seamless Co-op — per-world progress.** Progress applies only to actions taken while
  in a given player's world; a player who dies during a boss spectates and still receives the
  rewards; anyone resting at a site of grace resets enemies for the whole party. **The most directly
  relevant precedent**, reached from the same constraints — and we deliberately differ from it on
  death. It also scales enemies **up** for more co-operators (mimicking Elden Ring's own 25/50/75%
  buff for 1/2/3), never down; cited for the *direction*, and explicitly not as an argument for
  turning player-count scaling on by default, since Elden Ring ships that curve itself and most
  games do not.

Checked 2026-08-19; per `CLAUDE.md`, a dated fact is true as of its date, and live games change
their own rules.

Sources: [Warcraft Wiki — Tap](https://warcraft.wiki.gg/wiki/Tap) ·
[Blizzard Watch — mob tagging in Dragonflight](https://blizzardwatch.com/2022/10/20/mob-tagging-dragonflight/) ·
[RuneScape Wiki — Drops](https://runescape.wiki/w/Drops) ·
[GW2 Wiki — Loot](https://wiki.guildwars2.com/wiki/Loot) ·
[GW2 Wiki — Participation](https://wiki.guildwars2.com/wiki/Participation) ·
[FFXIV Wiki — FATE](https://ffxiv.fandom.com/wiki/FATE) ·
[Seamless Co-op (Nexus Mods)](https://www.nexusmods.com/eldenring/mods/510)

---

## What this deliberately is not

- **Not anti-cheat.** Reports are self-reported and the relay cannot validate content — catching a
  lie requires knowing what is true, which is simulation authority and excluded by construction
  (`beyond-cosmetic.md` §4). This is a model for playing with friends, not a security model.
- **Not a relay or core change.** If an implementation wants a `game_id` branch or a relay that
  understands damage, it has left this design.
- **Not a save write.** Rewards are granted by the game because the game killed the enemy.
- **Not a rebalance.** Every default is chosen so a group on one difficulty gets exactly the game
  the game shipped. Making anything harder is opt-in, per entity class, per game, and on the user's
  say-so.
- **Not approval.** See the top of this file.

---

## If this is ever built

1. **Prove the rules in Go, with no game — DONE 2026-08-19.**
   `cmd/meshghost-fakeadapter/credit.go` is the third synthetic-peer scenario, beside
   `controlplane.go` and `world.go`: N clients on *different difficulty scales* damaging shared
   synthetic enemies over the event plane, each folding the same ordered ledger and deciding for
   itself what died and what it earned. It carries invariants 9-16 above, `credit_test.go` gives
   each of them the defect it exists to catch, and the live form soaks through
   `cmd/meshghost-netsim` on udp with loss and reordering. `testing.md` has the recipe.

   **Two pieces of this design were wrong on first implementation and the tests caught both**,
   which is the whole argument for building the rig before an adapter leans on the model: a
   bystander that folded nothing had nothing to adopt when it finally swung (the mid-fight catch-up
   above silently did not happen), and an encounter first seen mid-fight wrongly counted itself as
   having watched the fight from its start. Both are pinned by tests now.

   **What it does NOT cover**, and should not be read as covering: liveness policies other than
   `per-participant`, credit policies other than `participants`, player-count scaling, world custody
   of the ledger for late joiners and host migration, and every per-game question about what
   "alive and in the encounter" means. The arithmetic is settled; the game-facing half is not.
2. **Then a game**, behind its own ADR. Nothing above changes that gate.

---

## Links

`ideas.md` (the backlog entry this came from) · `beyond-cosmetic.md` (authority models, the
readiness gaps, the line that stays) · `contract.md` (the event, lease and world planes this is
built on) · `plans.md` (the depth ladder and the memory-write gate) · `architecture.md` (where a
per-game ADR would go)
