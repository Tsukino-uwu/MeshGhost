# Game shapes — what online and co-op mean in games that are not one avatar in a world

**What this is.** Every adapter this project has shipped is the same kind of game: one player model,
a continuous world, one body per player, and no multiplayer of any kind in the base game. The
contract is built for exactly that — `position`, `area_id`, `anim`, one snapshot per player. This
file is the mental model for everything else: games where you are a cursor, or a commander of many
units, or a different thing in every mode; games that already have local co-op, restricted online, or
full online; and the ways of playing together that need no live session at all.

**It sits beside three files that each answer a different question**, and it deliberately answers
none of theirs:

- [access-models.md](access-models.md) — *how do you READ a game?*
- [beyond-cosmetic.md](beyond-cosmetic.md) — *who has AUTHORITY?* (the five models, §2)
- [kill-credit.md](kill-credit.md) — *who gets the REWARD for one shared enemy?*

This one asks **what is there to represent, and what can you reach to represent it with.**

**Nothing here is scheduled, no adapter is proposed, and none of it is permission.**
[beyond-cosmetic.md](beyond-cosmetic.md) §11 warns that a future session may read analysis as a green
light; that warning applies to this file in full. Anything past Tier 2 on
[plans.md](plans.md)'s depth ladder still needs its own per-game ADR and the memory-write gate,
whatever this file makes sound cheap. Games are named here as **examples of a shape**, never as
candidates — per-game verdicts live in [candidate-games.md](candidate-games.md).

---

## The three axes

Almost every question about "how would multiplayer work in game X" is really three questions, and
they are independent:

> **The SHAPE decides what crosses the wire.
> The SEAM decides what you can reach.
> The TIMING decides what it costs.**

Then ask **presence** and **co-op** separately, because they are not the same feature and a game is
often easy for one and hopeless for the other:

- **Presence** — can I see you? Needs no shared world. This is what MeshGhost does.
- **Co-op** — do we act on the same thing? Needs a shared world. This is
  [plans.md](plans.md)'s Tier 3 cliff.

Two claims are worth stating before the detail, because both are counterintuitive and both do most
of the work in the sections below.

**A game with NO multiplayer at all is usually the easiest case.** Nothing is fighting you: no
session gating, no official servers, no anti-cheat, no protocol to satisfy. That all four shipped
adapters are such games is the correct instinct rather than a coincidence — and it is why the Union
Room investigation ended with a MeshGhost-authored spawn instead of the game's own co-op code (§2.3).

**Almost everything expensive in netcode comes from SIMULTANEITY.** Drop the requirement that two
people act at the same moment and co-op becomes nearly free: no prediction, no rollback, no authority
arbitration, no clock sync. Axis C is where all the cheap options live, and most of them are not
netcode at all.

---

## 1. Axis A — the shape: what represents you

Genres are examples of a shape, not categories of their own. There are three primitives and one way
of combining them.

| Shape | What that is | Examples |
| --- | --- | --- |
| **1. No body — a cursor, or nothing** | you are a pointer and a screen | point-and-click, menu games, rhythm games, most strategy UI |
| **2. One player model** | today's four adapters | platformers, action games |
| **3. Many units you command** | you are a *commander*; the units are not you | RTS, colony sims, tactics games |
| **4. Mixed — a different shape per mode** | **not a fourth kind: a COMPOSITION of the three above**, and the normal case | party RPGs, dungeon crawlers, strategy games with battles |

**Shapes 1-3 are the vocabulary; shape 4 is the grammar.** Most games with any depth are mixed —
a town plus a dungeon, an overworld plus a battle, a map screen plus a field — and a game that is
one single shape from start to finish is the minority. Read the first three as the words you use to
describe each *mode*, not as boxes a whole game goes into.

### Shape 1 — no body

**The cheapest presence of any shape, and it needs no contract change.** The cursor *is* the avatar,
so the existing schema covers it unmodified: `position` is the cursor's x/y, `area_id` is which
screen or menu you are on, `anim` is idle / clicking / dragging. Seeing three friends' cursors move
around the same menu is a complete, working presence feature built from fields that already exist.

**Co-op means everyone clicking one shared state**, arbitrated by order rather than by ownership. The
usual extra is a lease (§6) on anything modal — a dialogue, a cutscene, a confirmation — so two
people do not advance it at once and skip a line nobody read.

### Shape 2 — one player model

The baseline the contract was built for, and the one the rest of this repo documents. The sub-case
worth naming is **stage / lobby / arena games**, where the "world" is a match instance rather than a
place:

- **A stage id is just an `area_id`** — opaque, compared by equality, exactly as a map bank is.
- **The relay room already IS the lobby.** Joining a room and joining a lobby are the same act.
- **What decides what the world looks like is a seed** — see §6.

### Shape 3 — many units you command

This is where the question *"would everyone have their own units, or would they be shared? what would
happen if 2 people used the same unit?"* lives, and the answer is more comfortable than it looks.

**The world is shared and the units are NOT owned.** Anyone commands anything, and two commands to
one unit is already a well-defined situation, because a colony-sim or tactics unit is driven by a
command queue that the game itself writes to asynchronously. Two people issuing orders is two queue
writes; last command wins, which is what happens when one player changes their own mind. Ownership
can be layered on as etiquette — a lease per unit so two people do not fight over one pawn — but it
is a courtesy, not a correctness requirement.

**The genuinely contested resource is the clock, not the units.** A colony sim is one simulation with
time controls, so *pause* and *game speed* are the shared state that actually needs arbitration:
whose pause wins, whether anyone may unpause, what happens when one player wants to fast-forward and
another is mid-decision. That is the hard design question in this shape, and it is invisible until
you look for it — everyone expects the units to be the problem.

**The RTS variant is different and worth the contrast.** Real-time strategy is the home of
**deterministic lockstep**: every machine runs the same simulation from the same commands, and the
wire carries *orders, not unit positions*. That is why "two people ordering one unit" is a non-problem
there — both orders enter the same command stream in the same order on every machine, so every
machine reaches the same answer. Whether lockstep is available at all is per-game and decisive;
[beyond-cosmetic.md](beyond-cosmetic.md) §7 has the verdict for the games here (emulated: conceivable;
Unity and Unreal: never, because of float drift and non-deterministic update ordering).

### Shape 4 — mixed

**Not a shape but a rule: answer per mode.** A game with a town, an overworld and a turn-based fight
is shape 1, shape 2 and shape 3 in sequence, and each mode gets its own answer to both questions.

**And MeshGhost already has an answer to this, which is worth knowing before designing a new one:
`area_id` absorbs a mode change.** A battle screen, a menu, a shop and a dungeon floor are all just
opaque areas, compared by equality, and a peer in a different area is not drawn. So the existing
contract's response to a mixed-shape game is **"a mode is an area, and you only see people in your
mode"** — which needs no new mechanism, no branch on mode, and no game knowledge anywhere in
game-agnostic code. It is not a full answer for *co-op* across modes, but for presence it is
complete, and it is why the shipped adapters have never had to model a mode change as a first-class
thing.

The decision that has to be made is **what a player IS in each mode**, and it is game design rather
than netcode. Three real designs, all of which have shipped somewhere:

1. **One player drives the overworld; the others take a party member only in combat.** The natural
   fit when the party is 4 and the players are 4, and it needs nothing in the overworld at all.
2. **Everyone has an overworld body, and the parties merge at a fight.** Presence in the overworld
   (which is what this project already does) plus role assignment at the mode boundary.
3. **A party per player** — the overworld holds N independent parties that fight independently.
   Barely co-op, and the cheapest by a wide margin.

The trap in this shape is assuming the answer transfers between modes. It does not: a game can be
trivial in its town and impossible in its combat.

#### A mode can change any axis, not just the shape

Worth stating because the name "shape 4" understates it: switching modes can move a game along **any**
of the three axes. A dungeon-crawler whose town is real-time and whose dungeon is turn-based has not
changed shape at all — it is one player model throughout — it has changed **timing**, which is the
axis that decides cost (§3).

**A worked example, because it lands on four different parts of this file at once.** Take a game
with a town you walk around freely, and dungeons you enter that are randomly generated per visit,
tile-based, and turn-based (the Mystery Dungeon structure):

- **The town is a lobby and the dungeon is an instance — and the game already shipped that
  structure in singleplayer.** This is exactly shape 2's stage/arena sub-case: a persistent social
  space plus disposable seeded instances. **A game whose own design already separates "where we meet"
  from "where we play" has answered the hardest structural question for free**, because §6's *"what
  decides what the world looks like"* is already a seed, generated at entry, and already scoped to
  one instance rather than to the save.
- **The seed is shared at entry, not at session start.** Per-instance rather than per-campaign, which
  is the friendly case: nothing has to be agreed up front, and two groups can be in two different
  dungeons with no relationship between them.
- **A tile-based turn-based dungeon is the friendliest netcode in this entire document.** Positions
  are discrete, so no interpolation; nothing is real-time, so latency is invisible and prediction is
  pointless; and state being discrete means divergence is *detectable* rather than a slow visual
  drift. The genre that looks hardest — procedural layouts, many entities, a whole simulated floor —
  is the easiest one to put on a wire, because it dropped simultaneity.
- **But its clock is action-driven, which is its own question.** The world advances one step per
  player action, so with two players *someone has to decide when the world steps*: everyone acts and
  then it advances (simple, correct, and gated by the slowest player), or each player's action
  advances it (fast, and the world state races). Most co-op in this genre picks the first. It is the
  same class of question as shape 3's clock (above) and the day-end consent problem (§6) — **who may
  advance shared time** — arriving for a third time from a third direction.
- **A dungeon's own turn or wind limit scopes to the instance**, exactly as time-of-day scopes to the
  stage in §6. Consistent, and for the same reason: the limit belongs to the place, not the player.

---

## 2. Axis B — the seam: what multiplayer the game already has

Where Axis A decides design, this axis decides **feasibility**.

| Seam | What you get | What it costs |
| --- | --- | --- |
| **None** | nothing exists; you build the whole representation | the most work, and **the fewest obstacles** |
| **Local co-op** | a real second player, driven by an **input device** | the best seam there is |
| **Limited / restricted online** | machinery exists, but gated | the trap — **or the best door of all, if the gate can be satisfied rather than bypassed.** §2.3 |
| **Full online already** | it works | ask whether yours is a *different product* — §2.5 |

### 2.1 No multiplayer at all

Every adapter here. You build the body, the animation mapping and the rendering yourself, and in
exchange nothing in the game or its ecosystem is trying to stop you. **This is the good case**, and
the reason is worth internalising: the work is bounded and visible, where a gated online feature
hides its blocker behind machinery that looks usable right up until it isn't.

### 2.2 Local co-op — the best seam there is

A second player already exists as a first-class concept, and it is driven by **an input device**. Feed
that input from the network and the game does everything else itself: spawning, physics, animation,
damage, respawn, score, UI. Nothing else on this axis hands you that much.

Worked through end to end in §5, including what it costs.

### 2.3 Limited or restricted online — the trap, and the test

Machinery for other players exists in the game, which makes it look like the obvious door. Sometimes
it is. The test that decides:

> **Is the second player driven by an INPUT SOURCE, or by a NETWORK SESSION?**

**An input source is fabricable. A network session is not.** That single distinction is most of the
answer to *"is it bad to make use of the online/co-op functions already present in games?"* — and the
answer is **no, it is usually the best available seam**; the Union Room result is not a
counterexample to that, it is an example of failing this specific test.

**But the test above is a false binary, and the third option is the interesting one: PROVIDE the
network session for real.** A gated feature is unreachable *without* a session; it is not unreachable
*with* one. Standing in for the link partner — tunnelling the emulated link or peripheral over the
network — satisfies the gate by construction rather than bypassing it, and the game then does
absolutely everything itself: matching, validation, animation, RNG, and its own writes. **That is the
principle this repo has already ratified twice rather than a new argument**, and
[ideas.md](ideas.md) states it plainly about the Unreal adapter: it *"calls the engine's own
`SpawnActor`/`ProcessEvent` and lets the game do its own writing, which is why it gets animation and
lifetime for free and why the no-writes rule was never in tension there."* The 2026-08-18 Emerald
spawn ADR cleared the write gate *"by exactly that route"*.

Four things to say about it honestly, because it sounds cheaper than it is:

- **It is a capability question first, and an unsettled one.** [ideas.md](ideas.md) already records
  the analogous unknown — *"whether BizHawk's Lua API can invoke a GBA ROM function safely at all…
  BizHawk may simply not have one"* — and standing in for a link peripheral is likely **emulator-layer
  work rather than adapter-layer**, needing timing agreement between two instances. Nothing here
  asserts what any emulator can do; that is measured, not remembered.
- **It is a different product.** Both players must genuinely be in the multiplayer location in their
  own games at the same moment. A shared session, not presence across independent runs — the same
  distinction [access-models.md](access-models.md) draws about emulator netplay.
- **It puts the no-writes rule under real tension.** A link trade writes a save, entirely through the
  game's own sanctioned path. That is either the cleanest conceivable answer to the rule or a breach
  of it depending on how the rule is read, and **it is an ADR question rather than something this
  file decides.** [plans.md](plans.md) already names trading and battling as the concrete Tier 3 case.
- **It changes nothing about the cosmetic layer**, which needs no session at all. This is a door, not
  a direction.

The finding, recorded in [ideas.md](ideas.md)'s Union Room investigation (Q5), is that every entry
point into that system takes a structure populated only by the game's real wireless-link receive
path, so *"none of it can be triggered by reading memory alone, and there's no 'fake it locally'
shortcut."* The recommendation that followed was to go around it to the **generic engine primitives
underneath** — which is what both Pokémon adapters now ship. The feature was gated; the primitives it
was built from were not.

**So when a game's own multiplayer is gated, look one level down.** The thing you actually want is
rarely the multiplayer feature; it is the spawning, posing and rendering machinery the feature is
built on, which is usually general-purpose and ungated.

### 2.4 Restricted by policy rather than by code

Official servers and anti-cheat are a different kind of gate: nothing technical stops you, and the
consequence of getting it wrong lands on the player rather than on the code.
[candidate-games.md](candidate-games.md)'s Dark Souls 3 / Elden Ring entry already sets the rule and
the reasoning — the mod forces the game offline first, it fails closed, and it is treated as an
invariant of the same class as "nothing that ships writes a save" rather than a preference. Not
restated here.

### 2.5 It already has online — when that kills an adapter, and when it doesn't

**The default is to deprioritise, and that default is right.** Effort is finite; a game with no
online has demonstrated *unmet* demand, and a game with working online has demonstrated the demand is
*met*. This project has already made the call once, in
[candidate-games.md](candidate-games.md)'s Sunshine entry: *"guess it also means it won't be any
priority for us as it already has online"*.

**But the test is not "does online exist" — it is "does the existing thing deliver what we would
deliver".** The same entry keeps the caveat beside the verdict: an existing online mod deprioritises
a game *"only insofar as it delivers the same thing, and this entry's own pitch was presence between
INDEPENDENT runs, which is a different product from co-op."* Four exceptions:

1. **Different product.** Theirs is co-op — one session, one world, one save. Ours is presence
   between *independent* playthroughs, which a co-op mod cannot provide at all. Someone doing their
   own run who wants to see a friend doing theirs is not served by joining the friend's game. The
   same distinction [access-models.md](access-models.md) draws about emulator netplay.
2. **It needs something we refuse, or something the player does not have** — a ROM or engine patch
   (ruled out by `CLAUDE.md`'s no-patch rule however well it works), official servers that are gone,
   a single platform, a modified save.
3. **Cross-variant reach.** Reading state and drawing spans a vanilla build, a randomizer and a
   patched seed; a co-op mod usually pins one build.
4. **The marginal cost is not theirs.** Relay, core, transport, interpolation, culling, replay and
   the adverse-network rig are already built and shared, so a new adapter costs only the per-game
   half — where a standalone online mod costs all of it. A player already running MeshGhost keeps
   one relay, one config and one room code for the next game.

**The reframe worth closing on: an existing online mod is worth more as prior art than it threatens
as competition.** It is proof the game is instrumentable, and it has by definition already answered
the hardest question in a new adapter. [candidate-games.md](candidate-games.md)'s own rule:
*"The first question to take to prior art here is 'where does it RUN and how does it DRAW', never
'what does it sync'."* Its Super Mario Odyssey entry is filed exactly that way — *"a prior art read,
not a target"*. **Licence before source, always** ([licensing.md](licensing.md)).

---

## 3. Axis C — the timing, and the catalogue of ways to play together

The axis that reframes the other two, because it is where the cheap options are.

| Timing | What it means | What it costs |
| --- | --- | --- |
| **Simultaneous** | everyone acting at once | prediction, rollback, authority, clock sync |
| **Action-driven** | the world advances one step per player action | ordering, plus **one decision: who may advance it** |
| **Alternating** | turns, handoffs | ordering only — the sequencer, already built |
| **Asynchronous** | never at the same time | persistence only; **no liveness requirement at all** |

The middle two are where most of the good deals are. **Action-driven is worth naming separately from
turn-taking** because it is not alternation — a roguelike advances the whole world when *anyone*
acts, so with several players the only real question is whether the world steps once everybody has
moved (correct, and paced by the slowest) or on each action (fast, and racy). See §1's worked
dungeon example.

A turn-based strategy game is the clean illustration of how much this axis matters: it has almost
nothing to *show* — no continuous position, often no body — and yet co-op is nearly free, because a
turn is exactly the bounded, consensual episode [plans.md](plans.md)'s Tier 3 is defined around.
Presence is hard and co-op is easy, which is the reverse of a platformer.

### Asynchronous — no shared session at all

- **Play-by-mail turns.** A turn is a message and the "server" is a mailbox. No liveness requirement
  whatsoever; players need never be online together.
- **Replay ghosts — racing a recording.** Presence without the person. This project reached the idea
  independently and it is already filed in [ideas.md](ideas.md): *"Ghost RECORDING and racing a
  replay — the wire format is already a replay format"*, with the recording, file-size and hotkey
  work beside it.
- **Traces left in another player's world** — a note, a mark, a structure someone else built.
  Presence *without simultaneity*: no live session, no shared simulation, **only persistence.** This
  is the most interesting negative finding in this file, because persistence is precisely the row
  [beyond-cosmetic.md](beyond-cosmetic.md) §5 **REFUSED** — and refused for a product reason (*it
  stops being a thing a user runs from a `.bat` file*), not a difficulty one. **A whole family of
  online play is closed to MeshGhost today for a reason that has nothing to do with netcode.**
  **Closed by default rather than forever**: the user's position, 2026-09-07, is that the disk-free
  relay is worth keeping and the refusal is revisited only for *a specific game that needs it*.
  That section also now separates the two kinds of persistence, because this family needs the much
  narrower one — read it there rather than re-deriving it here.
- **Behaviour-cloned opponents** — an opponent driven by a recording of how a real player actually
  played. Adjacent to replay ghosts, with the ghost given agency instead of a fixed path.

### Minimal-contact online

- **Spectating.** One player, N watchers, zero authority, nothing contested. The cheapest online mode
  that exists.
- **Leaderboards and score attack.** One number, asynchronous. The actual floor of "online".
- **Races.** Same content, separate worlds, compare times — shares almost nothing, and is
  **MeshGhost's natural competitive mode**, needing no mechanism the project lacks.
- **Sync-start social play.** Voice chat plus a countdown. Zero integration, and what most people
  actually do; naming it keeps the rest of this file honest about where the bar really is.

### Asymmetric roles

A structure rather than a player count — the players are not doing the same thing:

- **Commander / director** — one player in the world, one in a map or UI layer above it. Note this
  pairs shape 2 with shape 1 inside one session.
- **Helper or co-pilot** — a second player who occupies no real slot and cannot be hurt. The cheapest
  way to add a player to a game with no room for one.
- **Antagonist** — invasions, one-versus-many. Co-op's machinery, opposite intent.

### The most transferable retrofit idea

**Drop-in / drop-out over an AI slot: the game already has a slot filled by AI, and online only
changes who fills it.** One rule that covers followers, party members and character-swap.

**But it is not the same seam as a player-2 slot, and the difference is the work:**

- A **player-2 slot** hands you a ready-made **input path** — it is designed to be driven by a
  device, so you feed it.
- An **AI slot** hands you a ready-made **body but no input path** — it is designed to be driven by
  game logic, so you must find where the AI writes its intent, write there instead, and suppress the
  AI so both are not steering at once.
- **Character-swap is the best case of all**, because the game already contains proven, shipping code
  for moving player input from one body to another. The handoff mechanism exists and is tested by
  every player who ever used it.

---

## 4. What happens when the slot cap is reached

Every seam that borrows a slot runs out of slots. **This project has already answered that question
in another context**, and the answer generalises: [ideas.md](ideas.md)'s *"Spawn to the game's cap,
then DRAW above it — SHIPPED, both Pokémon adapters."*

**Degrade the representation; do not refuse the player.**

| Tier | What the player gets | Bound by |
| --- | --- | --- |
| A | a real slot — full participation | the game's cap |
| B | **cosmetic ghost** — visible, no gameplay authority | nothing |
| C | not rendered — culled | [culling.md](culling.md) |

**The conclusion is worth stating outright: the overflow case for co-op is exactly what MeshGhost
already is.** A deeper mode that runs out of slots does not fail, it falls back to the product that
exists. The alternatives are all worse: queue and spectate until a slot frees (only works for
session-based games); raise the cap by modding (breaks balance, UI and save assumptions together);
or share one slot between two players, which is §6's contested-unit question again.

**The cap is rarely "party size".** It is whichever engine budget is scarcest — object slots, sprite
slots, save-structure size, UI elements — and **it is often dynamic**. The concrete example is in
this repo: the Union Room investigation found the object-event array capped at 16 and **shared with
every real NPC already on the current map**, with the spawn call *"silently refus[ing] the spawn"*
when none is free. A cap that varies by where the player is standing, and fails without an error.

---

## 5. Worked case: a local co-op game

The most common real question, and the one with the most surprising answer.

### 5.1 Yes, online means "take over player 2"

Implemented as **feeding player 2's input from the network**. Four costs, and the third is the one
that matters:

1. **The shared camera.** Local co-op is designed around one screen and the players cannot separate.
   This constrains the design harder than the netcode does — see §5.3.
2. **It is peer authority immediately.** A real second body has collision and damage, so one
   machine's copy must be canonical and the other becomes a display that forwards input. That is
   [beyond-cosmetic.md](beyond-cosmetic.md) §2's fifth model, with everything §2 says it costs —
   including that trust becomes total.
3. **Latency moves off the ghost and onto the character. This is the cliff.** MeshGhost draws other
   players `interp` behind real time — **450ms shipped** ([../docs/config.md](../docs/config.md)) —
   and that is affordable *precisely because nobody is controlling the remote thing*. The moment
   somebody is, that delay is input lag on their own body. **This is the sharpest line between
   presence and co-op anywhere in this file**, and it is general: the cost of a delayed remote entity
   is nothing until a human is waiting on it, at which point it is everything. Hiding it is what
   prediction and rollback are for, and they need the game to be re-simulatable from a saved state.
4. **Two slots is two slots** (§4), and feeding input is a write — which gate that lands behind
   depends on where it is written (`CLAUDE.md`'s no-writes rule, [plans.md](plans.md)'s Tier 3).

### 5.2 Is it better than streaming the game to the other player?

Three comparisons, in increasing order of how much they should drive the decision.

**Latency — a modest win, not a category change.** Streaming costs the remote player a full round
trip *plus the video codec*; netcode without prediction costs a full round trip and no codec. The
saving is the codec — one to two frames. In both models the host pays nothing and the remote player
pays everything. Only prediction changes that, and prediction is the hard part.

**Bandwidth — a decisive win, and usually the real reason such mods exist.** Grounded in this repo's
own measurement rather than asserted: [hz-ceiling.md](hz-ceiling.md) works from ~288 bytes per state
line, which at 20Hz is about **21 MB per hour per stream**. Even at ten times that for a real co-op
payload — enemies, projectiles, spawns — it is a couple of hundred MB per hour, against **roughly
5-9 GB per hour** for 1080p60 video. And the two degrade differently *in kind*: a lost state packet
costs one stale update, where a lost video packet corrupts a frame or stalls the decoder. The
adverse-network default this project tests against (an intercontinental link plus bad wifi) is
exactly where that gap widens.

**Two viewpoints — the thing streaming cannot do at all, and the actual answer.** The host renders
one framebuffer and ships it, so **streaming is one camera by construction**. Netcode renders on both
machines, so two cameras is free *technically* — and then becomes a **game-design** problem, because
local co-op levels assume a shared screen and many such games carry explicit tether logic: you cannot
cross the screen edge, or a player left behind is warped or killed. That logic lives in the game and
would have to be found and disabled, and whether the game still works afterwards is per-game.
`CLAUDE.md`'s **never assume what a game is meant to do** applies directly.

**The verdict, in the framing this repo already uses:** streaming gives you *the same game, degraded*;
netcode gives you *a different game* — one that is not split-screen any more. That is the same
distinction [candidate-games.md](candidate-games.md) draws about emulator netplay: **a different
product, not a worse one.** Worth it for two viewpoints, for more players than the local cap, or for
a weak or metered connection. Not worth it for ping alone.

### 5.3 Local AND online at once — when a player stops being a machine

**The thing that breaks is the assumption that one player is one client is one connection.** A
machine holding two local players needs a second level of identity: connection → the players on it.
This is why engines carry a *local player index* separate from a *network player id*.

Three consequences, all favourable and none obvious:

- **Desync domains are machines, not players.** Two local players share one simulation and cannot
  desync from each other; online players can. A two-plus-two session has two truth domains — **which
  is already MeshGhost's model exactly**: within a machine, truth; across machines, ghosts.
- **Latency is per-machine, not per-person.** Both local players on the host are lag-free; both on a
  remote machine pay the same round trip. A couch partner adds no latency to anyone.
- **Camera is per-machine, player is per-person.** Their decoupling is what makes two-plus-two
  coherent at all: two screens, two players each.

**For MeshGhost this is blocked by design rather than by omission.** The 2026-08-16 ADR that made a
core admit exactly one adapter did so *after finding the opposite case as a live corruption bug*: two
adapters on one core *"shared one `player_id`, `seq`, send-rate budget and `localAreaID` — two games
driving one ghost, both logging a normal connect."* Two local players through one core is that same
failure. Four ways out, in increasing cost:

1. **Two game processes, two cores — works today, no change.** The port walk already finds free
   cores, watched live 2026-08-18 with two emulators taking adjacent ports. But this is *two copies
   on one machine*, not shared-screen local co-op.
2. **One connection carrying N EQUAL players — the expensive version.** Two peers means two of
   everything identity touches: authentication, resume token, room membership, leave semantics. An
   ADR plus a [contract.md](contract.md) revision.
3. **One connection, one owner plus N GUESTS — the cheap version, and the one consoles shipped.**
   **Identity by hierarchy rather than by equality:** the owner holds the profile, the name and the
   persistence; a guest has no account, no independent resumption, and a lifetime bounded by the
   owner's — when the owner drops, the guest drops, so there is no orphaned half-session to reason
   about. Resume, room membership and leave all stay owner-scoped, so **only the state plane has to
   carry more than one player**, which is a materially smaller change than option 2. **This repo
   already has the shape of the idea**, applied to a different subject: that same ADR made
   `relayOwner` a deliberately separate field from occupancy, answering *"whose disconnect may tear
   down the relay"* — ownership-scoped lifetime, which is what a guest identity needs.
   The console *reason* is worth keeping because it explains the visible tradeoff rather than just
   the mechanism: an account there is a controller-bound profile the platform authenticates per
   account, so a guest exists to sidestep entitlement and persistence — which is **why** guests
   typically earn no stats, rank or unlocks. The tradeoff falls out of the mechanism.
4. **One adapter, two cores** — excluded by the same ADR's 1:1 rule. Named so it is not re-proposed.

**None of this is a proposal.** It is recorded in the shape [beyond-cosmetic.md](beyond-cosmetic.md)
uses: knowing which doors are open, which need building, and which are welded shut.

---

## 6. The recurring answers

Four questions come up in every shape, so they are answered once here.

**"What decides what the world looks like?"** Three answers, and which one applies decides whether
the game needs a lobby before play or can be joined in progress:

- **A seed** — procedural or randomised content, agreed once and expanded identically by everyone.
  Cheap, and it needs no relay knowledge: a seed is an opaque blob handed out on join.
- **A host's save** — one player's world is canonical and the others are visiting. This is why
  builder and survival co-op is always phrased as *"join my world"*: it is not a match, it is
  somebody's file, and when they leave it goes with them.
- **A designed level** — nothing to decide. Everyone already has it on disk.

**"What happens when two players go for the same thing?"** This splits into two questions that look
alike and are not, and conflating them is why the answer feels hard.

### Two players selecting or controlling one unit — mostly a non-problem

**Selection is local and private.** Selecting a unit is UI state on one machine; games in shape 3
generally never replicate it. Two players can have the same unit selected and nothing whatsoever
conflicts, because there is no shared state to conflict over. The thing that *looks* like the
collision is not one.

**Control is a command, and commands serialise.** Both orders enter the ordered stream, and the unit
does one then the other — exactly what happens when a single player changes their mind mid-order.
Three mechanisms, and all of them are fine:

- **Lockstep** — both commands run on every machine in the same order, so every machine agrees. A
  non-problem by construction.
- **Last-write-wins** — the ordinary case, and usually correct, for the reason above.
- **A lease** — one holder, granted to the first asker.
  [beyond-cosmetic.md](beyond-cosmetic.md) §2 has the mechanism. Usually *worse* than the problem
  here: selection is transient and constant, so locking it produces more friction than it removes.

**So the residue is a human problem, not a technical one**, and the fix is feedback rather than
arbitration: show who has what selected and whose order is current. A UI answer to a UI problem.

### Two players interacting with one object, chest or NPC — the genuinely hard one

The difference is that **an order is repeatable and an interaction CONSUMES something.** Ordering a
unit twice is harmless; opening one chest twice must not yield two items. That single distinction —
**what does this interaction consume?** — picks the model:

| The interaction | Example | What it needs |
| --- | --- | --- |
| **Consumes nothing** — idempotent | a door, a lever, a switch | **nothing.** Both setting it to "open" is harmless |
| **Consumes a thing** — one-shot | a chest, a pickup, a one-time reward | **exactly-once: a claim before acting** |
| **Modal, personal outcome** | ordinary NPC dialogue | **instance it** — each player gets their own copy, no shared state at all |
| **Modal, shared outcome** | a quest choice, a shop with shared stock | a lease **plus** a decision nobody can dodge: who decides for everyone |

**The one-shot case is the one with a shipped answer**, and it is
[beyond-cosmetic.md](beyond-cosmetic.md) §2's worked example almost literally: two clients claim the
same opaque key, the relay grants it to the first asker by fiat and refuses the rest, one game gives
the item and the other does not, and both agree permanently — with the relay never learning what a
chest or an item is.

**And it carries that section's make-or-break rule, which is the real cost:** *"Adapters must ask
BEFORE acting, never announce after."* Claim, wait, then act. Acting first and reporting after puts
the relay's "no" *after* the result is already on screen, which is a rollback problem and per-game
hard. **So every contested interaction costs a network round trip before anything visible happens** —
invisible for a turn-based game or a menu, and unacceptable for anything twitchy, which is precisely
where real games spend prediction to hide it and reintroduce rollback for a moment in doing so.

**"Did it happen" and "who gets the reward" are separate questions**, and the second is not a detail
of the first. [kill-credit.md](kill-credit.md) is the worked design for it: two players opening one
chest is the same shape as two players killing one enemy, and that file is a *precondition* for
either rather than a refinement of them.

**"Does everyone get their own, or is it shared?"** The wrong question. The right one is **who has
authority**, it is answered **per entity type rather than per game**, and the taxonomy is already
written in [beyond-cosmetic.md](beyond-cosmetic.md) §2. A single game can reasonably give players
their own inventories, share its enemies, and lease its doors.

**"Is presence or co-op the hard one?"** Neither, consistently — and they are **anticorrelated more
often than not**. A platformer is trivial presence and hard co-op; a turn-based game is the reverse.
Deciding which one you actually want is worth more than any implementation choice in this file.

### Autonomous shared state — day/night timers, weather, waves

**A category of its own, because it is the only state that changes with nobody touching it.** A day
cycle, a countdown, a hunger clock, a tide, a respawn or spawn-wave timer: all advance on their own,
so they **desync by default rather than through a conflict**. Two players who launched a minute apart
are simply at different points, and nothing went wrong.

**The relay can already tell everyone what time it is, and that is not the same thing as syncing a
game's timer.** Clock sync is BUILT — [beyond-cosmetic.md](beyond-cosmetic.md) §5's `clock.v1`,
serving `ServerTimeMs` — so agreeing on *a* clock costs nothing. Making the game believe a different
in-world time is a **memory write into a running game**, which is Tier 3 and the memory-write gate.
The cheap half and the gated half again, exactly as in §7.

Three designs, in ascending cost:

1. **Independent — everyone keeps their own.** The honest default for a cosmetic layer, and it is
   already this project's declared posture: worlds are independent and desync is expected, so you may
   see a friend's ghost in daylight while it is night for you. Odd-looking, harmless, free.
2. **Shared for display only** — everyone *sees* a common time, but its **consequences stay
   per-player**. Very much this project's flavour, and it dodges every hard case below.
3. **Shared with shared consequences** — one timer, one nightfall, everyone forced home together.
   The expensive one, and the rest of this section is about why.

**On a second player joining**, the three answers fall straight out. Independent: nothing happens at
all, which is the cleanest thing about it. Shared: the joiner has to adopt the room's current
value — mechanically free, because the relay already holds the last opaque state blob per player and
populates a late joiner's `Join.State` in a `snapshot.v1` room — but **adopting a timer mid-cycle
means the joining game jumps**, possibly from morning to moments before nightfall.

**Which is exactly the user's edge case, and it is the real difficulty: a timer's expiry is an EVENT
WITH CONSEQUENCES, and the boundary is where everything goes wrong.** Someone joining as the clock
runs out adopts a state they had no chance to prepare for and is thrown straight into the end-of-cycle
sequence; meanwhile two games will not run that transition at the same instant, because frame timing
and load times differ, so one player can be in the transition while the other is still playing. This
is the same lesson [beyond-cosmetic.md](beyond-cosmetic.md) already draws about lease lifetime — *"the
mechanism is cheap and the failure handling is where the work is"* — arriving from a different
direction, which is usually a sign the lesson is real.

**The four mitigations, all of which real games use:**

- **Join-gating** — no joining mid-cycle; you join at the start of the next one. Converts a hard
  correctness problem into a wait, and is why so many co-op games seat you "next round".
- **A grace window** — refuse joins in the last stretch before expiry. The cheap 80% of join-gating.
- **Instance the consequences** — design 2 above: share the clock, keep its effects local.
- **Pause on join** — only available if something owns the pause, which is shape 3's clock problem
  (§1) reappearing as a prerequisite rather than a curiosity.

#### Worked example: a day cycle that also spends a finite resource

The general case above gets much harder when the timer is wired into progression, and a real
structure shows why. Take a game whose day works like this (a Pikmin-shaped example, and the entry
in [candidate-games.md](candidate-games.md) is for the same series): **you may end the day early and
voluntarily; otherwise nightfall ends it and ejects you from the stage; and the whole game allows
only a limited number of days.** Three properties, and each one moves a different verdict above.

**1. Ending the day early is not a timer problem at all — it is a consent problem.** A player choosing
to end the day ends it *for everyone* if the day is shared, which is the same shape as shape 3's
pause-and-speed question (§1) rather than anything about clocks. The three answers are the familiar
ones: anybody may end it (invites griefing), the host decides, or **everyone must agree** — which is
what a ready-check is, and why so many co-op games have one. Worth noticing that a ready-check is a
lease over a *decision* rather than an object, and that ending a day is precisely the **bounded,
consensual, episodic** moment [plans.md](plans.md) says Tier 3 can actually handle. This is the
tractable part.

**2. Two different things can end the same day, and they can race.** One player confirms "end the
day" in the same moment the timer expires, and the two paths need not produce the same outcome. **This
is a genuine ordering problem and it is exactly what the relay's sequencer already exists for**: it
stamps a total order on two opaque events and every client applies the same one first, without the
relay ever learning what "nightfall" is. A clean, concrete case for sequencer authority
([beyond-cosmetic.md](beyond-cosmetic.md) §2) that costs no game knowledge at all.

**3. The day COUNT is a shared, scarce, consumed resource — and this is what changes the earlier
verdict.** Above, independent timers were called harmless: you see a friend in daylight while it is
night for you, and nothing breaks. **With a hard day limit that is no longer true.** Independent
timers mean each player burns their own days at their own rate, so the group diverges not in
appearance but in *progress against the win condition* — one player on day 12 while another is on day
9 is not a cosmetic quirk, it is two different games. And if the count is shared instead, it is a
consumed resource, which drops it straight into §6's **"consumes a thing → exactly-once"** row with
the same machinery as a chest: a day must be counted once across the whole room, or the group loses
days nobody spent.

**It also removes the mitigation that dodges everything else.** "Share the clock, keep the
consequences local" works beautifully for lighting and ambience, and it cannot work here, because the
consequence *is* the shared resource. There is no local version of spending a day.

**4. There are TWO clocks here, and scoping them the same way is the mistake.** "Time of day" and
"which day it is" look like one system and behave nothing alike: one is a property of *where you are
standing*, the other is a property of *how far the group has got*. Once separated, each has an
obvious scope:

| What | Natural scope | Why |
| --- | --- | --- |
| **Time of day** | **the stage** | it belongs to the place. Anyone in that stage shares it; stages run independently |
| **Day count** | **the group**, if shared at all | it is progression, not place — and it is the scarce resource |
| **Whether you can see each other** | already the stage | `area_id`, and this is existing behaviour |

**Scoping time to the stage fits this project unusually well, because the mechanism already exists
for something else.** `area_id` is already the unit that decides who sees whom, and the 2026-08-28
cross-area ADR already establishes the pattern a stage clock would need: *"a client entering an area
is immediately seeded with the newest state of everyone already standing in it."* Seed-on-entry is
exactly what adopting a stage's current time-of-day is.

That answers the two questions directly:

- **"Do people share the time if someone is already in that stage?"** Under stage scope, **yes — the
  first player in starts the day, and anyone arriving adopts the clock as they find it.** You arrive
  into someone's afternoon, which is coherent and reads naturally as having turned up late.
  **Adopt, never reset**: resetting a stage's clock for a newcomer would hand anyone a free time
  extension by re-entering, which quietly breaks the scarce resource in point 3.
- **"What if they are in different stages at different times of day?"** Under stage scope this is a
  non-event: one stage is at dusk, another has just started, each is internally consistent, and
  **nothing needs reconciling because nobody is in both.** The only awkward moment is the boundary —
  leaving one stage at dusk and entering another — and in a game where leaving ends your day, that
  question mostly dissolves on its own.

**Different DAY NUMBERS is the case none of this rescues, and it is the honest hard boundary.** Two
players on different days are in different game states rather than different places, so no clock
scoping helps: the thing that differs is progress, not time. The practical consequence is a rule
about when sharing has to start — **a room can be joined mid-day, but not mid-campaign.** If the day
count is to be shared, it must be shared from the session's start rather than reconciled afterwards,
because there is no correct answer to "you have used nine and I have used twelve."

**The rule worth carrying away, and it generalises past this game:**

> **Rank a timer by its CONSEQUENCE, not by its mechanism.** A cycle that only changes the lighting
> can be left unsynced forever. One that ends the level is a moderate problem. One that spends a
> finite resource governing the win condition is a shared economy, and it inherits every
> exactly-once problem in §6 — from the same clock, with the same code.

---

## 7. Three levels of sharing — and why "multiworld" is not faking events

The three get conflated constantly, and they have very different costs.

| Level | What crosses the wire | Writes the game? | Cost |
| --- | --- | --- | --- |
| **Mirroring** | "draw what happened over there, over here" | no | cheap — **today's product** |
| **Multiworld** | "a thing in MY world was designated as YOURS" | **yes** | cheap network, gated game side |
| **Full sync** | shared enemies, NPCs, world | yes | [beyond-cosmetic.md](beyond-cosmetic.md) §2, all of it |

**Multiworld redistributes OUTCOMES; it does not fake events and it does not share a world.** Every
player runs a complete, independent game — no shared enemies, no shared positions, no shared
simulation. What crosses the wire is only that a result in one player's world belongs to another: one
player opens a container, the item inside is somebody else's, and that player's own game grants it.
The worlds stay independent; only **ownership of results** moves between them.

**Why the network half is cheap.** The traffic is rare (hundreds of events across a session, not
twenty a second), discrete, and needs reliability rather than low latency — which is the reserved
event plane exactly, with the relay never learning what an item is. It is also **asynchronous** in
Axis C's sense: the recipient need not be playing at that moment.

**Why "almost no netcode" is not "almost no work".** Granting an item into the receiving game is a
**memory or save write** — Tier 3, [plans.md](plans.md)'s memory-write gate, and the most gated work
in this repo. The cheap half is the wire; the expensive half is the game. Reading the first without
the second is precisely the misreading [beyond-cosmetic.md](beyond-cosmetic.md) §11 warns about.

**Which is better is the wrong question, because they are different products.** Mirroring gives
*spatial* presence — seeing each other. Multiworld gives *progression* co-op — affecting each other.
Together they cover a great deal of what playing together feels like **without ever sharing a
simulation**, which is the genuinely interesting claim here. Full sync is the third thing, and the
only one that puts two players in the same room.

---

## 8. Two constraints that cut across every shape

Neither of these changes *what* you send. Both change *where you are allowed to stand* while you
read or draw it, and what you can honestly promise a player.

### 8.1 Threading — single, dual, many

**The number of threads does not change the protocol. It decides where the adapter may touch the
game, and it is the single most expensive category of mistake this project has made.**

Two requirements pull in opposite directions: **network work must stay off the game's thread** (or
every packet is a stutter), and **game work must stay on it** (or every read is a data race).
MeshGhost satisfies both by an architectural accident worth noticing — the adapter holds a socket to
its own **local core process**, so all network I/O happens in a different *process*, and the
adapter's only obligation is a non-blocking drain on the game's own tick. The bridge was chosen for
other reasons ([architecture.md](architecture.md)), and it happens to make the threading question
almost disappear on the side that usually causes trouble.

**Both ends of the spectrum are hard, for opposite reasons**, and it is a mistake to read
"single-threaded" as "safe".

**Single-threaded hosts** — emulator Lua, older engines, and simulation games that never grew a job
system — are honest but cramped: everything you do is frame time taken from the player, cost is
visible, blocking is fatal, and **there is nothing in-process to offload to.** The bind is sharpest
in a heavy simulation game, where the tick *is* the whole game and is usually already the slowest
thing in it: work done inside the tick slows the simulation, and work done outside it races the
simulation. **That is reported to be the shape of the difficulty for existing online mods in at least
one colony sim** (the user, 2026-09-07, on RimWorld and its historically limited multithreading) —
recorded as an outside observation rather than a measured fact, and consistent with the structure
regardless.

**This is where MeshGhost's out-of-process core stops being merely tidy and becomes the answer.**
Against a single-threaded game the network work is not on another thread, it is in another
*process*, so the game pays for a non-blocking drain and nothing else. There is no version of that
available to a mod that must do its own socket work inside the one thread the game owns.

**Multi-threaded engines are the opposite trap, and the trap is that a callback is not automatically
on the thread that owns the world.** The Pseudoregalia adapter paid for this twice, and both lessons
generalise to any modern engine:

- **A mod framework's own update hook is its own thread, not the game's.** From that adapter's rules:
  `on_update()` *"runs on UE4SS's own thread. Anything touching actor state from there is a data
  race against the engine, and it presents as **intermittent corruption rather than a crash — so it
  survives testing**"* (found 2026-08-13). Scripted callbacks carry no stronger guarantee.
- **The wrong thread does not merely cause a bug — it produces false findings about the GAME.** The
  build story records that retesting on the correct game thread found the earlier *"must hijack,
  can't spawn"* verdict was *"an artifact of running off-thread, not a fact about this game"*. An
  entire architectural conclusion, reversed. **This is the one to remember**: a threading mistake
  looks exactly like a fact about what the engine will not let you do.

**Threading also breaks measurement, which is worse than breaking behaviour** because the readings
still look reasonable. [`_template/probes.md`](../adapters/_template/probes.md) records that stalling
the game thread *"truncates the very bursts you are trying to count"*, and a 2026-08-16 regression
did per-object string work on the game thread at ~50Hz and *"truncated the very bursts it was
counting"*. That is `CLAUDE.md`'s "a diagnostic can break the thing it measures" in its most literal
form, and it is a threading bug.

**And threading constrains Axis C.** Work-stealing schedulers make update order non-deterministic,
which is a large part of why deterministic lockstep is unavailable in modern engines —
[beyond-cosmetic.md](beyond-cosmetic.md) §7's verdict. So a game's threading model quietly removes
one of the cheap options from §3 before anyone has written a line.

**The rule that falls out:** find which thread owns the world, do every read and every draw there,
marshal onto it from anywhere else, and never trust a callback's thread without checking. A ghost
that reads gameplay state and then draws is often crossing two threads, not one.

### 8.2 Mod coexistence — what can actually be promised

The question is whether MeshGhost can keep working alongside arbitrary other mods, the way it already
does across ROM hacks and cosmetic mods. **The honest answer is that presence is unusually robust to
mods, and that the limit is not gameplay but ADDRESSES.**

**Why presence is robust, and it is a real structural property rather than luck: we read and draw,
we never simulate.** Nothing is predicted, so nothing can be mispredicted. A mod that adds a double
jump shows up as the ghost double-jumping, free and correct, because what crosses the wire is the
player's actual position and animation tag rather than an inference about what they should be doing.
**Gameplay mods are close to a non-event for a cosmetic layer**, which is exactly the property a
deeper mode would lose.

Sorting mods by what they actually touch:

| What the mod changes | Effect on the adapter |
| --- | --- |
| **Content and cosmetics** — outfits, weapons, item tables | none; what a sword looks like does not move a position |
| **Gameplay and physics** — new abilities, tuning | none for presence, per the above |
| **Spawned objects** — extra NPCs, entities | competes for the **same slot budget as ghosts** (§4), shrinking a cap that is already dynamic |
| **Performance** — anything heavy | lowers frame rate, and the adapter's send rate follows it; degrades smoothness, not correctness |
| **The animation set** — new or renamed tags | `anim` is opaque and compared between clients of the **same** game, so a tag one side lacks must degrade gracefully rather than fault |
| **The binary itself** — recompiled engine, rebuilt ROM | **the actual limit.** Every address moves |

**The last row is the whole difficulty, and it is already this project's experience**: a rebuilt ROM
relocates the structures both Pokémon adapters read, which is why they detect variants rather than
assume one. [candidate-games.md](candidate-games.md) also carries the warning against wishing that
away — *"There is no `detect_rom_variant()`; a shared helper of that name has been written down twice
as though it existed, and both times it was prose only."* Detection is per-variant and measured, so
support for a rebuilt binary is a thing that is *earned* for each build, never inherited.

**A subtlety worth stating because it will surprise people: cosmetic mods are LOCAL.** A ghost is
built and drawn by the *viewer's* install from the viewer's own assets, so two players with different
outfit mods each see their own install's cosmetics on the other's ghost. That follows from
clone-based rendering rather than from a measurement, and it has not been tested across mismatched
installs — but it is the expected behaviour, it is not a bug, and it is not fixable without shipping
assets across the wire, which the licensing rules forbid regardless.

**What can honestly be promised**, in four parts — and the last is the one that matters:

1. **Mods that do not move what we read: yes, by construction.**
2. **Rebuilt binaries: only the variants that have been measured**, one at a time.
3. **Any load order: yes, and it is already a standing rule** for every adapter.
   [`_template/README.md`](../adapters/_template/README.md): *"Do not rely on load order… Needing a
   particular slot means needing every other mod to cooperate, which they will not"*, alongside *"Do
   not assume you are the only thing touching the game"* and *"Leave no trace when removed."*
4. **Failing visibly rather than silently.** This is the achievable commitment, and it is worth more
   than a compatibility list, because `CLAUDE.md`'s warning is that **a wrong address returns a
   plausible number instead of crashing.** An adapter that cannot find what it expects must say so
   and stop, never draw a ghost from whatever was at that address.

**So the promise is not "works with every mod" and should never be written that way.** The shipped
posture is the right one and already in use — name what has been tested, and say plainly that the
rest is untested. The Pseudoregalia README does exactly this: it lists the mods it is known to work
with, then states they are *"assumed to work together with other mods but haven't been tested"*.

---

## 9. What this means for MeshGhost

The contract covers **shape 1 and shape 2 natively**, stage-and-lobby games with a seed, and nothing
else without the event plane. Shape 3 co-op and world-mutating co-op stay where
[beyond-cosmetic.md](beyond-cosmetic.md) puts them, unchanged: *"Full continuous co-op with a
game-aware relay remains a different project"* (§11), reached at the point where it becomes *"a
game-specific netcode project reusing this transport"* (§2).

Axis C is what makes this section worth writing rather than a shrug, because it splits three ways:

- **Already free, or nearly.** Races, spectating and replay ghosts need no mechanism this project
  lacks; the last is already filed in [ideas.md](ideas.md).
- **Blocked by one refused decision rather than by netcode.** Every asynchronous trace-or-message
  model needs persistence and nothing else, and [beyond-cosmetic.md](beyond-cosmetic.md) §5 refused
  persistence because it changes what MeshGhost *is to run* — a product decision, and one that
  remains the user's to revisit.
- **A different project.** Anything simultaneous past Tier 2.

**Nothing here is scheduled, no adapter is proposed, and none of it is permission.**

---

## 10. Shared-slot co-op — many operators, one player

Every arrangement in §3 and §5 gives each person something of their own: a slot, a body, an AI they
displace, a role beside yours. **This one does not.** N people operate a *single* player-slot — one
civilisation, one town, one empire — and divide the work by concern rather than by territory. One
runs the economy while another handles the military and a third talks to the neighbours, all inside
the same player.

**It is the arrangement a strategy game's own multiplayer structurally cannot express.** Their online
seats each player on their own civ; allied or hostile, the unit of play is always one person per
slot. So §2.5's test — *"does the existing thing deliver what we would deliver"* — comes back clean
on exception 1: this is a **different product**, not a second copy of something that already works.
Whether any game in the genre has shipped a shared-control mode is worth **checking rather than
assuming**; if one has, §2.5's closing reframe applies and it is prior art, not competition.

### 10.1 The two games that feel like one request are not

| | Shape | Seam | Timing | Cost |
| --- | --- | --- | --- | --- |
| **A turn-based 4X** | 3 — many units | none needed | **alternating** | §3's cheap column |
| **A real-time strategy game** | 3 — many units | none needed | **simultaneous** | §3's expensive one |

Same shape, same seam, **opposite timing** — and §3 says timing is the axis that decides cost. So
"shared-slot co-op in strategy games" is not one question: in a turn-based game it is nearly free,
and in an RTS it is prediction, rollback and clock sync all over again.

### 10.2 Authority dissolves — and that is the unusual part

Everywhere else in this file, two people acting on one world means arbitration: who owns what, who
decides, who wins a race. **Sharing a slot deletes the question rather than answering it.** Everyone
on the slot already has total authority over everything in it, so there is nothing to protect anyone
from — a co-operator who wanted to ruin your game could simply sell your cities, and no mechanism
would or should stop them. No ownership, no leases for correctness, no cheating question at all.

**Two operators spending the same 100 gold is not a conflict, it is a sequence.** Both commands enter
the ordered stream; the first succeeds and the second fails "insufficient funds" — which is a normal
in-game outcome, the same one a single player gets by clicking twice quickly. §6's *"control is a
command, and commands serialise"* covers it exactly, and the shared treasury is not an
exactly-once problem because the game's own spending path already is one.

**And §6's other half is what makes two operators viable at all: selection is local and private.**
Two people can each have their own camera, their own selection and their own hotkeys over one shared
command stream, because none of that is shared state. The mechanism was already written; nothing had
connected it to this use case.

### 10.3 §4 inverts here, which happens nowhere else in this file

Every other seam borrows a slot and eventually runs out, and §4's answer is to degrade the
representation — a real slot, then a cosmetic ghost, then culled. **Shared-slot co-op fixes the slot
count at one and lets the number of players be unbounded.** It is the only shape in this document
where adding a person costs no slot budget whatsoever, which is precisely why it survives in games
whose player caps are small and whose worlds are large.

### 10.4 What is actually contested: the camera and the clock

§1's shape-3 finding predicted this — *"the genuinely contested resource is the clock, not the
units"* — and it arrives here intact, joined by a second.

- **The camera.** Two designs, and they differ entirely on this point. **One authoritative instance
  with remote operators** is correct by construction and cheap on the wire, but it renders one
  framebuffer, so it is §5.2's *"streaming is one camera by construction"* and every operator after
  the first is watching someone else's screen. **N instances agreeing on one command stream** gives
  every operator their own viewport for free, and buys that with lockstep determinism — available in
  an emulated game, and per [beyond-cosmetic.md](beyond-cosmetic.md) §7 not available in Unity or
  Unreal.
- **The clock.** In a turn-based game, *who may end the turn* is a ready-check — §6's day-end consent
  problem arriving for a fourth time, from a fourth direction. In a real-time one it is pause and
  game speed, which is §1's colony-sim question verbatim.

### 10.5 A role structure §3 does not have

§3's asymmetric roles are all **hierarchies**: a commander above a body, a helper beside one, an
antagonist against them. Shared-slot co-op adds a different structure — **peers on the same layer,
partitioned by concern**. Nobody is above anyone; the split is economy / military / diplomacy rather
than director / actor. It needs no mechanism at all, because the partition is a social agreement over
a command stream that already accepts everything from everyone.

### 10.6 What this means for MeshGhost — the halves do not overlap

**The cheap half is real:** a cursor, a camera rectangle and a selection highlight for each
operator is shape 1, which §1 says the existing contract covers unmodified — `position` is the
cursor, `area_id` is the screen. No contract change, no writes, no authority.

**And it is close to worthless on its own**, because seeing where a friend is pointing is only
meaningful if you are both pointing at the same world — and sharing the world is the entire cost.
This is the file's presence-versus-co-op anticorrelation (§6) in its sharpest form: elsewhere one of
the two is cheap and *useful*; here the cheap one is cheap and *inert* until the expensive one exists.

**Nothing here is scheduled, no adapter is proposed, and none of it is permission.**

---

## 11. Unit pools — who holds what, and which cap you hold fixed

**A correction to §1's grammar before anything else.** Shape 4 is defined there as *"a different shape
per MODE"* — a composition in **sequence**. But shapes also compose **simultaneously**: a game where
you are one avatar walking around a world who is *at the same time* commanding a bounded squad is
shape 2 and shape 3 **at once, in one mode**, and neither reading of §1 covers it. That matters here
because the avatar and the squad turn out to have different limits for different reasons.

### 11.1 The one number that is secretly two

Take a game where a player controls one body and up to some number of units — call it 100 — following
it. In singleplayer that 100 is a single rule. **With two players it splits into two rules that no
longer have to agree:**

- **The FIELD cap** — how many units may exist in the world at once. This is an **engine budget**:
  AI, pathfinding, collision, draw calls. §4 already warns that the scarcest budget is rarely "party
  size" and is *often dynamic*.
- **The SQUAD cap** — how many units one avatar may hold. This is **design and UI**: what one person
  can meaningfully steer, and what the encounters were tuned against.

**Which of the two you hold fixed is the entire design space**, and every arrangement anyone proposes
is one cell of this table:

| | Field cap | Per-player cap | Ownership | The cap is a… | Encounter balance |
| --- | --- | --- | --- | --- | --- |
| **A — one pool, first-come** | 100 | up to 100 | none | **distributed invariant** | preserved |
| **B — one pool, split** | 100 | **100/N, fixed** | none | **local invariant** | **preserved** |
| **C — a pool each, sealed** | 100×N | 100 | **invented** | local invariant | broken |
| **D — one field, a cap each** | 100×N | 100 | none | local invariant | broken |
| **E — one pool, split by type** | 100 | set by composition | **derived** | local invariant | preserved |

### 11.2 A is dominated by B, and the reason is the general lesson

They look like the same idea — one shared pool of 100 — and they are not. **A lets either player draw
up to 100, so the pool is contested**: if I hold 60 you may hold 40, and every whistle is a claim
against a scarce shared resource. That is §6's *"consumes a thing → exactly-once"* row, and it drags
in §6's make-or-break rule with it: *"Adapters must ask BEFORE acting, never announce after."* **A
network round trip before every squad change, on a real-time action performed dozens of times a
minute.** It is the worst pairing available in this file: a contested consumable on simultaneous
timing.

**B fixes each player's allowance at 100/N and the contention evaporates** — not because it is
arbitrated better, but because the two allowances sum to 100 *by construction*, so a collision is
impossible and nobody ever asks permission.

> **Same budget, same total, same fairness — but A makes the cap a DISTRIBUTED invariant and B makes
> it a LOCAL one.** A distributed invariant needs consensus; a local one needs nothing. Splitting a
> shared limit statically is almost always cheaper than sharing it dynamically, and this generalises
> well past unit pools.

### 11.3 The real decision is B versus D, and it is taste, not technique

Both are correct and cheap. They produce different games.

- **B keeps the game as designed.** The field stays at the number the encounters were tuned against,
  so nothing rebalances — and co-op becomes **coordination under scarcity**: you each have less than
  a solo player, so you have to actually cooperate. It also **needs no measurement at all**, because
  it cannot exceed the engine budget: the field total never changes.
- **D makes co-op additive.** Each player is a whole player, which feels generous and is what most
  people picture — and it hands every encounter double the force it was built for. Its viability is
  an **open measurement**, not a choice: doubling a cap §4 calls an engine budget may simply not fit.

That is §5.2's framing again — **a different product, not a worse one.** B's co-op is tighter and
harder; D's is looser and easier. Neither is the correct answer to a question about netcode, because
it is not a question about netcode.

**B's one weakness has a cheap repair.** A rigid 50/50 blocks the case where one player needs 60 for
a single big task while the other needs 10. The fix is to let players **transfer allowance
explicitly** — a lease over a rare, deliberate act rather than over every squad change, which is
exactly the *bounded, consensual episode* §6 and [plans.md](plans.md)'s Tier 3 can handle. Local by
default; one round trip only when somebody deliberately lends.

**B scales and D does not.** 100/N is defined for any number of players; 100×N runs into the engine
sooner and the balance harder with each one. B's own ceiling is a different shape: at four players
25 each may fall below the minimum a single carry task needs, at which point the partition stops
being playable for reasons that have nothing to do with the network.

### 11.4 Why C is the one to avoid

**C invents a concept the game does not have.** §1's shape-3 finding is explicit — *"the world is
shared and the units are NOT owned"* — and that is not an accident of design, it is how these games
work: a unit is **held**, not owned. It follows you because you called it, and the moment you drop it
it is nobody's. There is no persistent per-player tag anywhere, no field for one and no UI for one.
C has to add all of that.

**And it buys parallel play with it.** Two sealed pools cannot pool labour, so a task needing twenty
carriers can never be a joint effort — you get two people doing the same thing in the same map, which
is §5's third design, *"barely co-op, and the cheapest by a wide margin"*.

### 11.5 E — splitting by type instead of by player

The variant that dissolves the cap question rather than answering it: **share one pool, and give each
player a different unit TYPE.** No number is assigned to anyone; your effective cap is however many
of your type the group chose to bring, so a numeric limit is replaced by a **compositional** one.

**It is not ownership-free, and the distinction is the interesting part.** If you command one type,
that type is effectively yours — but a unit's type is **an attribute the game already models**:
real, visible, in the data, in the UI. So E gets ownership's clarity *without inventing a field*,
which is a materially different proposition from C. Ownership derived from an existing attribute is
cheap; ownership as a new per-player tag is not.

**Whether it works at all turns on one property of the type system:**

> **Split by type works where the types are meant to be COMBINED, and fails where they are meant to
> be CHOSEN.**

- **Combined-arms types** — the kind an RTS builds a battle out of, where the answer to a fight is
  *all of them at once* — partition beautifully. Every engagement wants every type, so every player
  has something to do at every moment, and the interdependence is the game's own design rather than
  an imposed rule.
- **Lock-and-key types** — the kind where a hazard admits one type and refuses the rest — partition
  badly. Those types are selected *sequentially*, so a section built around one of them leaves
  everybody else spectating. **It hands the level designer control of who is relevant this minute**,
  and they never knew two people would be playing.

**One more limit, and it is what connects E back to §10.** In a game where units are only part of
what you do, a type-split partitions **one activity, not the game**: economy is not a unit type, so
nothing in the split says who builds, who gathers or who researches. There, E is not an alternative
to §10's concern-split — it is a **sub-partition inside the military concern**, and the two compose.
Where the units *are* the whole game, E partitions everything — which is precisely why the idle-player
failure bites hardest in exactly the games where E would otherwise be the most natural fit.

### 11.6 The question that survives every option: who eats the loss?

Ownership-free options leave one thing genuinely unanswered. If I take your units into a fight and
thirty of them die, **whose loss is that?** Under A, B, D and E there is no answer, because there is
no owner — and that is *correct*, not a gap: the pool is the group's, and so is the mistake.

It is worth naming anyway, because it is [kill-credit.md](kill-credit.md)'s subject approached from
the side that file has not looked at. That one asks **who gets the reward** for a shared enemy; this
asks **who bears the cost** for a shared loss. Same machinery, opposite sign, and a game that answers
the first without the second will feel unfair in a way nobody can point at.

### 11.7 What this means for MeshGhost — the expensive shape

**A ghost of a player in this shape is not one ghost. It is up to 101.**

Every shipped adapter draws one remote body per peer. Here a peer is an avatar *plus* their entire
squad, and all of it is visible, moving and animated. That lands on two constraints at once: §4's
slot budget, which is already dynamic and already shared with the game's own spawns, and
[culling.md](culling.md), which stops being an optimisation and becomes a precondition. **The
presence-only version of this shape — the cheap tier everywhere else in this file — is dramatically
more expensive than anything the project has shipped**, and it is the rare case where the *cosmetic*
layer, not the co-op layer, is what a measurement would have to clear first.

**Nothing here is scheduled, no adapter is proposed, and none of it is permission.**

---

## Links

[beyond-cosmetic.md](beyond-cosmetic.md) (authority, the five models, the readiness gaps) ·
[plans.md](plans.md) (the depth ladder and the memory-write gate) ·
[access-models.md](access-models.md) (what a game lets you read) ·
[kill-credit.md](kill-credit.md) (who gets the reward for a shared enemy) ·
[candidate-games.md](candidate-games.md) (per-game verdicts and prior-art reads) ·
[contract.md](contract.md) (packet schema, event plane, transport) ·
[culling.md](culling.md) · [hz-ceiling.md](hz-ceiling.md) · [ideas.md](ideas.md)
