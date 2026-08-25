# Pokémon Crystal

<!-- line-cap: 300 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Status: shipping.** `meshghost_crystal.lua` is a working adapter — it dials the bridge, spawns a
real in-game object event for each peer, walks it with the game's own step mechanism, and ships in
the release (`.github/workflows/release.yml` stages it into `games/pokemon/crystal/`). It **writes
game RAM** — object RAM only, never a save.

**Three tiers, which is this adapter's headline structure.** A peer is rendered by the best one
that will take it, and never dropped: **spawned** (a real object event the engine walks, animates
and occludes for us), then **hardware** (written straight into the game's own sprite buffer so the
PPU draws it — shipped OFF, see [FLAGS.md](FLAGS.md)), then **drawn** (painted over the emulator
for any peer the first two have no room for).

**Last live confirmation 2026-08-23**: the drawn tier's motion and walk cycle, at the dev rig's
settings. Earlier: a character on every visible tile at 60fps (2026-08-19), and a loopback ghost
walking on both vanilla and an Archipelago-patched ROM the day before that. **What is confirmed
and what is not is `agent_docs/status.md` and `UNVERIFIED.md`** — several fixes since 2026-08-22
are built but unwatched, and the hardware tier has never been judged on screen at all.

- Platform: Game Boy Color, played via BizHawk.
- Confirmed working roms: "Vanilla V1.0", "Archipelago 6.0.0-beta.11".
- Intended, not yet tested: **Vanilla V1.1**, **speedchoice v8.1**. Each needs its own address
  table before it is more than a fallback — today an unrecognised build runs on vanilla's table
  with a one-line "untested" log. The two are not equal work: `pokecrystal` lists V1.1 as one of
  its own build targets with its own hash, so that table can be *built and hash-verified* the way
  V1.0's was, while speedchoice is a patch and needs each entry *measured*, as Archipelago's were.

- **One address table per ROM build, chosen at startup from the header title.** Vanilla's entries
  come from our own hash-verified `pokecrystal` build; Archipelago's were each *measured*, because
  its patch rearranges WRAM non-uniformly and no constant offset recovers vanilla's addresses
  ([VERIFIED.md](VERIFIED.md), 2026-08-17). An entry nobody has measured stays
  `nil`, and a `nil` makes the adapter **refuse to run** rather than write somewhere plausible —
  **two** entries on the Archipelago table are still `nil` — `W_USEDSPRITES`, which switches a
  peer's own appearance off on that build, and `W_STATEFLAGS`, which turns the hardware tier off
  there — rather than reading a plausible address. An unrecognised build runs on vanilla's table with a one-line "untested" log, or refuses
  outright under `MESHGHOST_CRYSTAL_STRICT=1`. Every switch: [FLAGS.md](FLAGS.md).
- Adapter language: Lua (BizHawk's scripting host), as Emerald.
- **How the game is read: an external source decompilation** —
  [`pokecrystal`](https://github.com/pret/pokecrystal), built locally and verified byte-identical
  to the ROM being played. Addresses are looked up and cited, never discovered at runtime. See
  [agent_docs/access-models.md](../../../../agent_docs/access-models.md).
- **One structural difference from Emerald worth knowing up front:** Game Boy RAM labels live in
  *floating* sections, so **no address appears in the decomp's source at all** — the decomp has to
  be built to produce `pokecrystal.sym`. Toolchain and the one non-obvious trap:
  [agent_docs/environment.md](../../../../agent_docs/environment.md).
- **[documentation.md](documentation.md)** describes how Crystal itself works — the two object
  arrays, how a character comes to exist, the lifecycle states. It was briefly argued that a game
  with a decompilation needed no such file; the user overturned that 2026-08-18, and every adapter
  now carries one ([adapters/_template/README.md](../../../_template/README.md)).
- **[BANDAGES.md](BANDAGES.md)** carries this adapter's shipped compensations, and
  **[FLAGS.md](FLAGS.md)** its runtime switches.

## Limits that come from the game, not from us

Measured 2026-08-19 with real peers over the real relay, not estimated. Full table and method:
[agent_docs/crowd-limits.md](../../../../agent_docs/crowd-limits.md).

- **Nine ghosts on one map**, in both maps tested. Crystal has 13 object structs and 16 map
  objects, and every map spends some of both on its own NPCs first — so the exact number is
  per-map, and **which pool runs out changes**: outdoors the structs go first, indoors the map
  objects do.
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
- **In practice**: everyone is visible, and the engine's slots go to whoever is actually moving.
  A peer that has not changed tile for five seconds stops blocking and moves to the drawn tier, and
  a peer you shove into stops blocking within half a second — so nobody can park on a doorway.
  Ghosts stack on each other freely; they collide with the player, not with one another.

## How this adapter differs from Emerald's — the reason it exists

Emerald draws a ghost **over** the emulator with `gui.*`, fed by a hand-rolled decode of the
player sprite out of ROM. Crystal instead **spawns a real in-game object event** and lets the
engine draw it, so palettes, occlusion, priority and animation are the game's problem rather than
ours.

That is a deliberate, recorded decision, not an implementation detail — it is the first time
MeshGhost writes game memory, and it required an ADR to clear `plans.md`'s standing no-writes
non-goal. **Read
[agent_docs/architecture.md](../../../../agent_docs/architecture.md)'s 2026-08-17 entry before
touching any of this**, including its open question about whether the engine's own routine can be
*called* rather than imitated.

> **Warning — why an unrecognised ROM must never be written to.** Archipelago's Crystal patch
> rearranges WRAM **non-uniformly**; no constant offset recovers the vanilla addresses
> ([VERIFIED.md](VERIFIED.md), 2026-08-17). A write aimed at a
> vanilla address on a patched ROM does not fail cleanly — it lands on whatever now occupies that
> address. So the adapter identifies the ROM from its header title first and picks a *measured*
> table for it; a build it recognises but has not fully measured refuses to run, and one it does
> not recognise at all runs on vanilla's table only after saying so in its first log line
> (`MESHGHOST_CRYSTAL_STRICT=1` turns that into a refusal).

## How this adapter was built

Only steps that actually happened and were confirmed are listed here.

1. Checked the licences for the whole `pret` family before reading any of it — all of them carry
   no licence file, so the same facts-only posture already used for `pokeemerald` applies.
   ([agent_docs/licensing.md](../../../../agent_docs/licensing.md))
2. Built `pokecrystal` locally and confirmed the result is byte-identical both to the ROM being
   played and to the hash the decomp documents, which is what makes every address below
   authoritative rather than merely plausible.
   ([VERIFIED.md](VERIFIED.md))
3. Pulled the player and map addresses out of the resulting `pokecrystal.sym`, including the four
   consecutive bytes `wMapGroup`/`wMapNumber`/`wYCoord`/`wXCoord` that later served as a
   fingerprint for identifying them in a live game.
4. Confirmed live how to actually reach those addresses from BizHawk, which was the one thing the
   decomp could not answer — Game Boy WRAM is banked, so a bank-1 address needs the right domain.
   `System Bus` and `WRAM` both work and agree exactly. (`domain_probe.lua`)
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
7. Made the painted tier hold its position and its facing, which took a whole session and six
   attempts at the facing alone. Three of the faults were the same shape: a rule this file had
   already worked out — take the MINIMUM x across a character's four hardware sprite entries,
   because their order mirrors when the sprite flips — living in one function and missing from the
   one next to it. The fourth was subtler: a ghost built to look like the local player is
   indistinguishable from them in the hardware's own sprite table, so the tier was learning the
   player's artwork from its own ghost. `pitfalls.md` has each; the method that found them all was
   one small trace, written after four fixes reasoned from the code had failed on screen.
8. Made the painted ghost actually WALK, which needed a fact about the game nobody had established:
   a sprite has six views, not three. Three standing, and three STEPPING that sit 0x80 higher in the
   character's own graphics — confirmed on the player and on an NPC at a different tile base, so it
   is relative rather than an absolute region. A guard added the previous day to stop the tier
   learning from the wrong character had capped the offset at 12, which discarded every stepping
   frame as foreign; it was right about the danger and wrong about the number. The stride is chosen
   from how far into its step the peer is rather than from a timer here, so it cannot drift against
   the peer's feet.
9. Fixed the spawned ghost sliding off its tile, which turned out to be a step that covered 14px of
   a 16px tile. Found by re-anchoring a standing ghost to the tile it claims to be on and logging
   how far it had to move — the correction was 2px on essentially every step, which named the step
   length rather than the sprite writes that had been suspected. Two things were removed one at a
   time to get there, with a measurement after each and no third guess.

10. Made the painted ghost move like the engine rather than like a position feed, which took a whole
    session and nine distinct defects across three layers — the world coordinate, the paint, and the
    walk cycle — each of which read clean on instruments built in its own frame while the layer under
    it was wrong. What settled it was measuring the PAINTED SCREEN POSITION, one character per frame:
    the number the eye actually watches. The ghost now commits whole tiles like a Crystal character,
    decides only at tile boundaries, and advances on the frames the camera itself scrolls, copying
    its delta; it is painted in the camera's own coordinate frame, so the seam that a tile-plus-
    progress origin opens at every step boundary is gone. Full chain in
    [pitfalls.md](../../../../agent_docs/pitfalls.md); the instruments, which outlast the fix, in
    [probes.md](../../../_template/probes.md).

11. Added the hardware (OAM) tier between the other two, on the user's request. A peer whose tiles
    are already resident in VRAM is written into the game's own sprite buffer, so it gets the
    engine's live palettes, day/night and fades for no per-pixel Lua. It allocates downward from
    the tail the engine leaves free, so the Game Boy's per-scanline sprite limit drops a ghost
    rather than one of the game's own characters. It buys **zero to one** extra character, not
    capacity, and does **not** get occlusion free — a text box is background tiles with the
    BG-to-OAM priority bit clear, so a sprite draws in front of it. Shipped OFF: nothing about how
    it looks has been confirmed on screen. [FLAGS.md](FLAGS.md), `UNVERIFIED.md`.

12. Made a peer fish, which needed three things the wire was not carrying and one it was carrying
    wrongly. The pose was already there — `OBJECT_FACING` states it outright — but the ROD came
    from `FishingRodGFX`, which the game loads and then immediately overwrites with the real
    fishing sheet, so the drawn rod was somebody else's art. The bite's little shake is
    `OBJECT_SPRITE_Y_OFFSET`, now on the wire and shared with the Fly and Dig falls; the "!" is a
    separate map object, found by a scan and identified by matching the tiles the game loaded
    against the cartridge's own table, so peers get every emote rather than that one.
    Confirmed on screen 2026-08-26. `VERIFIED.md`, `documentation.md`.

13. Fixed a fault fishing only happened to expose: the drawn tier calibrated screen space against
    OAM entries 0-3 assuming they were the player's, but the engine emits by PRIORITY — so while
    any high-priority object was up (the "!" is one), every painted ghost sat a tile too high. The
    player's entries are now found by their tile block instead of by their position in the list.
    `pitfalls/by-lesson.md`.

### Further work past "good enough"

Open as of 2026-08-22 — [agent_docs/status.md](../../../../agent_docs/status.md) is the
authoritative list, and [phase9.md](../../../../agent_docs/phases/phase9.md) has the detail.

**Where the two tiers actually stand**, in the user's own words at the end of 2026-08-22, because
it is the most honest summary of this adapter available: the **drawn** ghost is *"perfect but not
animated"* — its position, facing and placement are all confirmed 1:1 and its walk cycle has never
been seen running — and the **spawned** ghost is *"somewhat decent but still some yank"*. Neither
is finished, and the drawn one is now the better-behaved of the two, which is the reverse of what
the tier ladder intends.

- A ghost wears the peer's own sprite when this map has those tiles loaded (2026-08-19), and falls
  back to this machine's player otherwise — the other gender is never loaded, so that case still
  looks like you. **The drawn tier could close it**: it reads pixels rather than borrowing the
  engine's, so it is not limited to what the map loaded.
- `W_USEDSPRITES` is still unmeasured on the Archipelago table, so a peer's own sprite is off
  there — and so is `W_STATEFLAGS`, which means the hardware (OAM) tier does not run on that
  build at all. (`W_BATTLEMODE` was settled 2026-08-19 by one trainer battle: `0x1234`.)
- A ghost does **not** survive a battle — answered from the code 2026-08-19, and the stale
  bookkeeping it used to leave behind would drive one of the game's own NPCs around. Fixed; a
  real battle still needs watching.
- Two real machines: everything confirmed so far was a loopback ghost.

## What's here

- `meshghost_crystal.lua` — **the adapter, and the only file that ships.** It walks bridge ports
  7778-7785 for a core that will have it, gates every spawn on the game's own map-state bytes,
  spawns one object event per peer (a map object plus an object struct, cross-linked, built from a
  live NPC template wearing the player's sprite), and moves each ghost by writing the game's own
  step-initiation set once per tile. For every peer the engine can hold, it draws, animates and interpolates nothing; only the
overflow tier added 2026-08-19 does any of those, and only because the game cannot.
- `documentation.md`, `BANDAGES.md`, `FLAGS.md` — how Crystal itself works, the shipped
  compensations, and the runtime switches.
- `probes/` — every development tool, and none of it ships. Twenty-odd scripts covering the
  address hunt, the spawn recipe worked out one failure at a time, and the Archipelago
  re-measurement. **Indexed, one line each, in [probes/README.md](probes/README.md)** — read that
  rather than the folder listing.
- `logs/` — where the adapter's own runs land, one timestamped `.log` per script load (probes write
  theirs beside themselves in `probes/`). A run therefore leaves a record without anyone copying
  text out of the Lua Console; `.gitignore` covers every `.log`, because once a run has been read
  its conclusion belongs in `VERIFIED.md`.
