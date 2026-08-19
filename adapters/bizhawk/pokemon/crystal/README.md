# Pokémon Crystal

**Status: shipping.** `meshghost_crystal.lua` is a working adapter — it dials the bridge, spawns a
real in-game object event for each peer, walks it with the game's own step mechanism, **paints any
peer the engine has no room for over the emulator instead of dropping it**, and ships in
the release (`.github/workflows/release.yml` stages it into `games/pokemon/crystal/`). It **writes
game RAM** — object RAM only, never a save. Last live confirmation 2026-08-18: a loopback ghost
walked on both vanilla and an Archipelago-patched ROM.

- Platform: Game Boy Color, played via BizHawk.
- Confirmed working roms: **"Vanilla V1.0"**, **"Archipelago 6.0.0-beta.11"** (the latter with one
  address still unmeasured — see the next bullet).
- **One address table per ROM build, chosen at startup from the header title.** Vanilla's entries
  come from our own hash-verified `pokecrystal` build; Archipelago's were each *measured*, because
  its patch rearranges WRAM non-uniformly and no constant offset recovers vanilla's addresses
  ([verified.md](../../../../agent_docs/verified.md), 2026-08-17). An entry nobody has measured stays
  `nil`, and a `nil` makes the adapter **refuse to run** rather than write somewhere plausible —
  `W_BATTLEMODE` on the Archipelago table is still `nil` and still needs one trainer battle to
  settle. An unrecognised build runs on vanilla's table with a one-line "untested" log, or refuses
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
> ([agent_docs/verified.md](../../../../agent_docs/verified.md), 2026-08-17). A write aimed at a
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
   ([agent_docs/verified.md](../../../../agent_docs/verified.md))
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

### Further work past "good enough"

Open as of 2026-08-18 — [agent_docs/status.md](../../../../agent_docs/status.md) is the
authoritative list, and [phase9.md](../../../../agent_docs/phases/phase9.md) has the detail:

- A ghost looks like **this** machine's player, not the peer — a peer's own gender needs their
  sprite loaded locally.
- `W_BATTLEMODE` is still unmeasured on the Archipelago table (`0x015A` vs `0x1234`), and one
  trainer battle settles it (`probes/ap_battlemode_probe.lua`).
- Whether a ghost survives a battle: set up twice, answered neither time.
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
  its conclusion belongs in `verified.md`.
