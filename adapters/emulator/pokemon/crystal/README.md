# Pokémon Crystal

**Status: shipping, and under active work — Phase 9.** `meshghost_crystal.lua` dials the bridge,
spawns a real in-game object event for each peer, walks it with the game's own step mechanism, and
ships in the release (`release.yml` runs `dev-scripts/stage-release.ps1`, which stages it into
`games/pokemon/crystal/`). It
**writes game RAM** — object RAM only, never a save.

**Three tiers, which is this adapter's headline structure.** A peer is rendered by the best one
that will take it, and never dropped: **spawned** (a real object event the engine walks, animates
and occludes for us), then **hardware** (written straight into the game's own sprite buffer so the
PPU draws it — shipped OFF, see [FLAGS.md](FLAGS.md)), then **drawn** (painted over the emulator
for any peer the first two have no room for).

**Last live confirmation 2026-08-27**: the first **mixed-build room** — one Archipelago client and
one vanilla client, two emulators, two cores — where seven faults were found and fixed on screen.
Before that, 2026-08-26: ledge hops, Dig/Escape Rope, fishing, the Fly landing, ice glides and the
party-menu gate; movement itself — both gaits, both tiers, surf and the bike — 2026-08-25.
**What is confirmed and what is not is [VERIFIED.md](VERIFIED.md) and
[UNVERIFIED.md](UNVERIFIED.md)**, in that order: every confirmation before the mixed session is a
loopback ghost on vanilla V1.0 at the dev rig's interpolation, the hardware tier has never been
judged on screen at all, and the mixed room has only ever been run on one map with two players.

- Platform: Game Boy Color, played via BizHawk.
- Confirmed working roms: "Vanilla V1.0", "Archipelago 6.0.0-beta.11".
- Intended, not yet tested: **Vanilla V1.1**, **speedchoice v8.1**. Each needs its own address
  table before it is more than a fallback — today an unrecognised build runs on vanilla's table
  with a one-line "untested" log. The two are not equal work: `pokecrystal` lists V1.1 as one of
  its own build targets with its own hash, so that table can be *built and hash-verified* the way
  V1.0's was, while speedchoice is a patch needing each entry *measured*, as Archipelago's were.
- **One address table per ROM build, chosen at startup from the header title.** Vanilla's entries
  come from our own hash-verified `pokecrystal` build; Archipelago's were each *measured*, because
  its patch rearranges WRAM non-uniformly and no constant offset recovers vanilla's addresses
  ([VERIFIED.md](VERIFIED.md), 2026-08-17). An entry nobody has measured stays `nil` rather than
  reading a plausible address, and a `nil` in any of the ten the adapter must read or write makes
  it **refuse to run**. Eleven optional entries are unmeasured on the Archipelago table and turn
  a feature off instead of refusing: `W_USEDSPRITES` (a peer's own appearance), `W_STATEFLAGS`
  (the hardware tier), the `W_MAPCONNECTIONS`/`W_MAPWIDTH`/`W_MAPHEIGHT` trio (cross-map ghosts),
  `W_SPRITEUPDATESON` (the drawn tier's UI gate never fires), and the five party/icon entries the
  Fly landing reads (no Fly arrival on that build). (This said "two entries" until 2026-09-01 —
  only the first two had ever been counted.) Every switch: [FLAGS.md](FLAGS.md).
- Adapter language: Lua (BizHawk's scripting host), as Emerald.
- **How the game is read: an external source decompilation** —
  [`pokecrystal`](https://github.com/pret/pokecrystal), built locally and verified byte-identical
  to the ROM being played. Vanilla addresses are looked up and cited, never discovered at runtime —
  but a *patched* cartridge is outside what any decomp describes, so the tables that differ (the
  gait table, the sprite table) are read off the ROM at load and checked against a signature. See
  [agent_docs/access-models.md](../../../../agent_docs/access-models.md).
- **One structural difference from Emerald worth knowing up front:** Game Boy RAM labels live in
  *floating* sections, so **no address appears in the decomp's source at all** — the decomp has to
  be built to produce `pokecrystal.sym`. Toolchain and the one non-obvious trap:
  [agent_docs/environment.md](../../../../agent_docs/environment.md).
- **[documentation.md](documentation.md)** describes how Crystal itself works — the two object
  arrays, how a character comes to exist, the lifecycle states, and each movement class the adapter
  mirrors. Every adapter carries one, decompilation or not
  ([adapters/_template/README.md](../../../_template/README.md)).
- **[BANDAGES.md](BANDAGES.md)** carries this adapter's shipped compensations, and
  **[FLAGS.md](FLAGS.md)** its runtime switches.

## Limits that come from the game, not from us

Measured 2026-08-19 and 2026-08-25 with real peers over the real relay, not estimated. Full tables
and method: [agent_docs/crowd-limits.md](../../../../agent_docs/crowd-limits.md).

- **Nine ghosts on one map**, in both maps first tested. Crystal has 13 object structs and 16 map
  objects, and every map spends some of both on its own NPCs first — so the exact number is
  per-map, and **which pool runs out changes**: outdoors the structs go first, indoors the map
  objects do. A busy map is far tighter: Route 39's own cast holds 11 of the 13 structs, leaving
  **two**.
- **Ten characters on screen at once, ever — a hardware ceiling.** The Game Boy has 40 sprite
  entries and an overworld character uses exactly 4. With the hardware fully saturated at 40 of 40,
  all ten still drew correctly on screen.
- **Past the limit, a peer is DRAWN rather than dropped** (2026-08-19, on the user's call). The
  engine renders as many as it can hold; everything beyond that is painted over the emulator,
  which no engine or hardware limit applies to. Measured: **a character on every visible tile —
  89 of 89 — at 60fps**, user-confirmed. The trade is that a drawn peer has no collision, no
  engine animation, and occlusion we re-implement; it is registered in [BANDAGES.md](BANDAGES.md)
  with the full cost. `MESHGHOST_CRYSTAL_DRAW_OVERFLOW=0` turns it off, and then extra peers are
  simply absent, which is the older behaviour.
- **Painting is free to about 98 characters and then falls off a cliff.** The 2026-08-25 pacing
  runs hold a flat 60fps to 98 painted peers, at a cost visible only as hitches (about one 20-28ms
  frame a second past ~34); at 158 the frame rate halves. Both are an order of magnitude past any
  real session. **Those numbers are a FLOOR** — the synthetic crowd never exercised the drawn
  tier's stepping animation, so a crowd of real walking peers costs more.
- **In practice**: everyone is visible, and the engine's slots go to whoever is actually moving.
  A peer that has not changed tile for **a minute** stops blocking and moves to the drawn tier, and
  a peer you shove into stops blocking within half a second — so nobody can park on a doorway.
  (Five seconds until 2026-08-26 — that described "stood still briefly". [FLAGS.md](FLAGS.md).)
  Ghosts stack on each other freely; they collide with the player, not with one another.

## How this adapter differs from Emerald's — the reason it exists

Emerald began by drawing a ghost **over** the emulator with `gui.*`. Crystal instead **spawns a
real in-game object event** from its first line and lets the engine draw it, so palettes,
occlusion, priority and animation are the game's problem rather than ours. That was the user's
call — *"so we don't start doing this game with bandaids from the get go"* — and it is a recorded
decision, not an implementation detail: it is the first time MeshGhost writes game memory, and it
required an ADR to clear `plans.md`'s standing no-writes non-goal. **Read
[agent_docs/architecture.md](../../../../agent_docs/architecture.md)'s 2026-08-17 entry before
touching any of this.**

> **Warning — why an unrecognised ROM must never be written to.** Archipelago's Crystal patch
> rearranges WRAM **non-uniformly**; no constant offset recovers the vanilla addresses
> ([VERIFIED.md](VERIFIED.md), 2026-08-17). A write aimed at a vanilla address on a patched ROM
> does not fail cleanly — it lands on whatever now occupies that address. So the adapter
> identifies the ROM from its header title first and picks a *measured* table for it; a build it
> recognises whose table is missing an address it must read refuses to run, and one it does not
> recognise at all runs on vanilla's table only after saying so in its first log line
> (`MESHGHOST_CRYSTAL_STRICT=1` turns that into a refusal).

## How this adapter was built

Only steps that actually happened are listed here, roughly in order. Anything called confirmed was
confirmed by the user on screen and is dated in [VERIFIED.md](VERIFIED.md); anything built but
unwatched says so and is in [UNVERIFIED.md](UNVERIFIED.md).

1. Checked the licences for the whole `pret` family before reading any of it — all of them carry
   no licence file, so the same facts-only posture already used for `pokeemerald` applies.
   ([agent_docs/licensing.md](../../../../agent_docs/licensing.md))
2. Built `pokecrystal` locally and confirmed the result is byte-identical both to the ROM being
   played and to the hash the decomp documents, which is what makes every address below
   authoritative rather than merely plausible. ([VERIFIED.md](VERIFIED.md))
3. Pulled the player and map addresses out of the resulting `pokecrystal.sym`, including the four
   consecutive bytes `wMapGroup`/`wMapNumber`/`wYCoord`/`wXCoord` that later served as a
   fingerprint for identifying them in a live game.
4. Confirmed live how to actually reach those addresses from BizHawk, which was the one thing the
   decomp could not answer — Game Boy WRAM is banked, so a bank-1 address needs the right domain.
   `System Bus` and `WRAM` both work and agree exactly. (`probes/domain_probe.lua`)
5. Got a ghost to exist by borrowing the game's own machinery rather than drawing anything: a free
   map object plus a free object struct, copied from a real NPC the engine is already driving. It
   walks with the game's own step animation and faces the right way, and this adapter draws,
   animates and interpolates nothing. Confirmed on screen 2026-08-18; the long version, including
   what a map load does to it, is in `agent_docs/phases/phase9.md`.
6. Made it work on an Archipelago-patched ROM, which needed every address measured again rather
   than adjusted. The patch moves WRAM by different amounts in different places — seven addresses
   by +7, the object array by +6, the map-object table by −0x2A — so the adapter keeps one table
   per ROM build, picked by the header title, and an unmeasured entry stays `nil` so it refuses to
   run instead of writing somewhere plausible. A loopback ghost walked on that ROM the same day.
   The measurement techniques are in `adapters/_template/probes.md`; the trap is in `pitfalls.md`.
7. Measured how many ghosts the game can actually hold, then stopped dropping the rest. Nine on a
   map and ten characters on screen are the engine's and the hardware's own ceilings, and the
   user's call on seeing them was that nobody should pop in and out — so peers past the ceiling are
   **painted over the emulator** instead — a character on every visible tile at 60fps, confirmed
   2026-08-19. That tier owes the engine's occlusion back by hand, which Crystal makes possible
   because it publishes where its UI rectangles are (step 20). Registered as a compensation in
   [BANDAGES.md](BANDAGES.md).
8. Added the hardware (OAM) tier between the other two, on the user's request. A peer whose tiles
   are already resident in VRAM is written into the game's own sprite buffer, so it gets the
   engine's live palettes, day/night and fades for no per-pixel Lua. It allocates downward from
   the tail the engine leaves free, so the Game Boy's per-scanline sprite limit drops a ghost
   rather than one of the game's own characters. It buys **zero to one** extra character, not
   capacity, and does **not** get occlusion free — a text box is background tiles with the
   BG-to-OAM priority bit clear, so a sprite draws in front of it. Shipped OFF: nothing about how
   it looks has been confirmed on screen. [FLAGS.md](FLAGS.md), [UNVERIFIED.md](UNVERIFIED.md).
9. Made the painted tier hold its position and its facing, which took a whole session and six
   attempts at the facing alone. Three of the faults were the same shape: a rule this file had
   already worked out — take the MINIMUM x across a character's four hardware sprite entries,
   because their order mirrors when the sprite flips — living in one function and missing from the
   one next to it. The fourth was subtler: a ghost built to look like the local player is
   indistinguishable from them in the hardware's own sprite table, so the tier was learning the
   player's artwork from its own ghost. `pitfalls.md` has each; the method that found them all was
   one small trace, written after four fixes reasoned from the code had failed on screen.
10. Made the painted ghost actually WALK, which needed a fact about the game nobody had established:
    a sprite has six views, not three. Three standing, and three STEPPING that sit 0x80 higher in the
    character's own graphics — confirmed on the player and on an NPC at a different tile base, so it
    is relative rather than an absolute region. A guard added the previous day to stop the tier
    learning from the wrong character had capped the offset at 12, which discarded every stepping
    frame as foreign; it was right about the danger and wrong about the number.
11. Fixed the spawned ghost sliding off its tile, which turned out to be a step that covered 14px of
    a 16px tile. Found by re-anchoring a standing ghost to the tile it claims to be on and logging
    how far it had to move — the correction was 2px on essentially every step, which named the step
    length rather than the sprite writes that had been suspected. Two things were removed one at a
    time to get there, with a measurement after each and no third guess.
12. Made the painted ghost move like the engine rather than like a position feed, which took a whole
    session and nine distinct defects across three layers — the world coordinate, the paint, and the
    walk cycle — each of which read clean on instruments built in its own frame while the layer under
    it was wrong. What settled it was measuring the PAINTED SCREEN POSITION, one character per frame:
    the number the eye actually watches. The ghost now commits whole tiles like a Crystal character,
    decides only at tile boundaries, and advances on the frames the camera itself scrolls, copying
    its delta. Full chain in [pitfalls.md](../../../../agent_docs/pitfalls.md); the instruments,
    which outlast the fix, in [probes.md](../../../_template/probes.md).
13. Made the seam between the tiers invisible, which is where the general rule came from: **a tier
    handover is a POSITION handover, and it needs an overlap.** An idle peer is demoted to the drawn
    tier and promoted back the moment it moves — so "starts walking after standing still" is a
    re-spawn every time. Placing the new object on the peer's current tile paid a whole tile of
    disagreement in one frame, and dropping the painted copy on the same frame left a hole neither
    tier filled. Promote onto the tile the painted model is actually over, then hold both until the
    engine is seen drawing the new one.
14. Found that a drawn ghost outlived the server being shut down, from a repro the user proposed.
    `disconnect()` forgets every peer, which is enough for real engine objects and does nothing to
    pixels already painted — and because the overlay is in SCREEN space, the frozen last frame
    appeared to follow the player around. **A memory dump cannot see a rendering artefact**: two
    confident diagnoses were both wrong because both looked in WRAM. `pitfalls.md`.
15. Moved the ghost's sub-tile position out of `extras` and into `position`, which is the most
    expensive lesson of this phase and is not Crystal-specific. The core interpolates every
    component of `position` and passes `extras` through latest-wins, so a renderer mixing the two
    is combining terms that describe different instants — a stutter by construction, invisible at
    the dev rig's `-interp=0ms` and only real at the shipped delay, which was the one configuration
    nobody was testing. Back-ported to [_template/README.md](../../../_template/README.md).
16. Made surfing, the bike and ordinary walking 1:1 on both tiers — eleven fixes in one session,
    confirmed 2026-08-25 (*"moving perfect, surf working, bike working"*). A surfing peer had been
    drawn as a walking character standing on the sea because the drawn tier's decoded-tile cache
    was never invalidated at all, despite a comment claiming a map load cleared it — and a surf
    mount rewrites the player's tiles in place, with no map load. The bike needed the peer's gait
    carried on the wire as the engine's own group number rather than inferred from its speed.
17. Replaced the bump special case with one rule for every in-place animation: read the peer's own
    action byte and let each tier honour it. That is what makes a whirlpool spin, and it is also
    what makes an **ice glide** correct — a gliding player reads "moving while STANDING", which is
    the game's own description of it, so the ghost is given the engine's `SLIDING` bit and skips
    the walk cycle entirely. Ice confirmed 2026-08-26; the whirlpool's spawned half is not, and
    the reason is in [UNVERIFIED.md](UNVERIFIED.md) — the game freezes every other object during
    the forced spin, so loopback cannot show the case at all.
18. Made a peer fish, which needed three things the wire was not carrying and one it was carrying
    wrongly. The pose was already there — `OBJECT_FACING` states it outright — but the ROD came
    from `FishingRodGFX`, which the game loads and then immediately overwrites with the real
    fishing sheet, so the drawn rod was somebody else's art. The bite's little shake is
    `OBJECT_SPRITE_Y_OFFSET`, now on the wire; the "!" is a separate map object, found by a scan
    and identified by matching the tiles the game loaded against the cartridge's own table, so
    peers get every emote rather than that one. Confirmed on screen 2026-08-26.
19. Fixed a fault fishing only happened to expose: the drawn tier calibrated screen space against
    OAM entries 0-3 assuming they were the player's, but the engine emits by PRIORITY — so while
    any high-priority object was up (the "!" is one), every painted ghost sat a tile too high. The
    player's entries are now found by their tile block instead of by their position in the list.
    `agent_docs/pitfalls/by-lesson.md`.
20. Stopped painting a ghost over a full-screen menu, twice over. The game keeps ONE scratch slot
    for the menu rectangle, so a "can't use that here" box replacing the party menu left a single
    remembered rectangle protecting six rows of a screen that was entirely menu — the tier now
    keeps a list. And the gate itself became positive rather than a deny-list: `wSpriteUpdatesEnabled`
    is the game's own "may a character be shown at all", cleared on the way into every full-screen
    UI, which is one test instead of a list nobody can finish. Confirmed 2026-08-26.
21. Made a peer arrive by Fly as the POKEMON that carried them, descending on the engine's own
    decaying-cosine spiral read off the decompilation rather than tuned, and becoming the character
    as it lands. The species crosses the wire, latched with the map-entry byte because the party
    index moves the moment a menu opens. Confirmed same-town and cross-town 2026-08-26 — and it
    **retired a bandage the same day it was added**, a skyfall drop that stood in while the real
    landing was still unmeasured. [BANDAGES.md](BANDAGES.md).
22. Made a ledge hop the engine's own jump, which produced the rule worth carrying to the next
    adapter: **send the QUESTION, not the engine's own byte.** Copying the peer's transmitted arc
    gave a frozen ghost; writing one step type instead gave both tiles, both halves of the arc and
    the right pace, generated on the receiver's clock. The wire carries "is this peer hopping?",
    because the player's own step type drives the camera and copying it would drag the view. Both
    tiers get a shadow under the ghost. Confirmed 2026-08-26.
23. Confirmed Dig and Escape Rope together, because they are one routine differing by a single
    byte — a counterclockwise spin in place on departure, spin-and-flicker on arrival, and no
    vertical movement at all. It needed no new code: the action byte was already on the wire and
    both tiers already honoured it. It also deleted a phrase from the source that had never been
    true — there is no Dig fall; Teleport is the class that raises the sprite, and it remains
    unmeasured. Confirmed 2026-08-26.
24. Put an Archipelago client and a vanilla client in one room — the first mixed-build session this
    project has run — and seven faults came out of it, each invisible to a same-build test. The
    patched cartridge's camera is two *different* HRAM bytes, so the drawn tier's clock read dead
    values and a standing peer painted itself gliding; it also has a **fourth gait** vanilla lacks,
    which the camera's plausibility test rejected as a register rebase. The rest were one shape: a
    peer's appearance learned from the LOCAL player, which says nothing about a peer on the other
    build. Everything a build can move is now read off that cartridge rather than assumed.
25. **FEATURE COMPLETE, 2026-08-27.** The user's own line, added by hand and deliberately left
    without a description — **the scope of it has not been stated, and nothing here should invent
    one.** Read it against the open list directly below, which still has Teleport unbuilt and
    RUNNING's gait unmeasured on the Archipelago build; whether those sit inside or outside this
    call is the user's to say. `UNVERIFIED.md` carries the question.

### Further work past "good enough"

Open as of 2026-08-27 — [agent_docs/status.md](../../../../agent_docs/status.md) is the
authoritative list, [UNVERIFIED.md](UNVERIFIED.md) has every measurement waiting on a look, and
[phase9.md](../../../../agent_docs/phases/phase9.md) has the narrative.

- **The mixed room has run on ONE map with two players.** Everything before it was a loopback
  ghost, whose motion is the local player's own — so a peer flying, digging or spinning while the
  watcher does not is still largely unexercised.
- **Nothing crosses builds by assumption.** Sprite ids, item ids and gaits each differ between
  vanilla and the Archipelago seed, and each had to be measured. Turbo is fixed and confirmed;
  **RUNNING is untested and its gait unmeasured**, and surf is unreached on that build.
- **The shipped 250ms interpolation has not been re-judged** since the drawn tier was rebuilt.
  Every confirmation above is at the dev rig's `-interp=0ms`, which is the configuration a 1:1
  judgement needs and the one that hides a whole class of fault.
- **The hardware (OAM) tier has never been judged on screen**, and ships off for that reason.
- **Teleport is the last action class** — not built, not measured, not watched.
- **A ghost does not survive a battle** — fixed 2026-08-19 (the stale bookkeeping used to drive one
  of the game's own NPCs around); a real battle still needs watching.
- **A peer wearing a sprite this machine's player is not** — routed to the drawn tier, which reads
  the cartridge and can render anything, rather than spawned wearing the wrong character.
- `W_USEDSPRITES` and `W_STATEFLAGS` are still unmeasured on the Archipelago table, so a peer's own
  sprite is off there and the hardware tier does not run on that build at all. `0x1A17` was
  **refuted** as its `wPlayerState`. (`W_BATTLEMODE` was settled 2026-08-19: `0x1234`.)

## What's here

- `meshghost_crystal.lua` — **the adapter, and the only file that ships.** It walks bridge ports
  7778-7785 for a core that will have it, gates every spawn on the game's own map-state bytes,
  spawns one object event per peer (a map object plus an object struct, cross-linked, built from a
  live NPC template wearing the player's sprite), and moves each ghost by writing the game's own
  step-initiation set once per tile. For every peer the engine can hold it draws, animates and
  interpolates nothing; only the overflow tiers do any of those, and only because the game cannot.
- `documentation.md`, `BANDAGES.md`, `FLAGS.md` — how Crystal itself works, the shipped
  compensations, and the runtime switches.
- `VERIFIED.md`, `UNVERIFIED.md` — what the user has confirmed on screen, and the queue of what is
  measured and still waiting for them to look.
- `probes/` — every development tool, and none of it ships. Eighty scripts covering the address
  hunt, the spawn recipe worked out one failure at a time, the Archipelago re-measurement, and the
  savestate-driven rigs that make an expensive state (a fly, a ledge, a whirlpool) repeatable.
  **Twenty of them WRITE and seventeen hold the controller**; they are indexed, one line each, in
  [probes/README.md](probes/README.md) — read that rather than the folder listing.
- `logs/` — where the adapter's own runs land, one timestamped `.log` per script load (probes write
  theirs beside themselves in `probes/`). A run therefore leaves a record without anyone copying
  text out of the Lua Console; `.gitignore` covers every `.log`, because a run once read belongs
  in `VERIFIED.md`.
