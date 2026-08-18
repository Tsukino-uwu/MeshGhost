# Pokémon Crystal

**Status: groundwork only. There is no adapter yet** — this folder currently holds two read-only
probes and this file. Nothing here renders a ghost, opens a socket, or writes memory.

- Platform: Game Boy Color, played via BizHawk.
- Confirmed working roms: **vanilla V1.0 only** (`sha1 f4cd194b…`).
- **Archipelago (6.0.0-beta.11) is an intended target, not a supported one yet.** The ROM guard
  currently *refuses to write* on anything but vanilla V1.0, deliberately: Archipelago's Crystal
  patch rearranges WRAM non-uniformly, so a vanilla address lands on whatever now occupies it
  rather than failing cleanly ([verified.md](../../../agent_docs/verified.md), 2026-08-17).
  Supporting it means a second address table for the patched ROM, not a relaxed guard.
- Adapter language: Lua (BizHawk's scripting host), as Emerald.
- **How the game is read: an external source decompilation** —
  [`pokecrystal`](https://github.com/pret/pokecrystal), built locally and verified byte-identical
  to the ROM being played. Addresses are looked up and cited, never discovered at runtime. See
  [agent_docs/access-models.md](../../../agent_docs/access-models.md).
- **One structural difference from Emerald worth knowing up front:** Game Boy RAM labels live in
  *floating* sections, so **no address appears in the decomp's source at all** — the decomp has to
  be built to produce `pokecrystal.sym`. Toolchain and the one non-obvious trap:
  [agent_docs/environment.md](../../../agent_docs/environment.md).
- **[documentation.md](documentation.md)** describes how Crystal itself works — the two object
  arrays, how a character comes to exist, the lifecycle states. It was briefly argued that a game
  with a decompilation needed no such file; the user overturned that 2026-08-18, and every adapter
  now carries one ([adapters/_template/README.md](../../_template/README.md)).
- **[BANDAGES.md](BANDAGES.md)** is present and **empty**, which is the point of this phase.

## How this adapter will differ from Emerald's — the reason it exists

Emerald draws a ghost **over** the emulator with `gui.*`, fed by a hand-rolled decode of the
player sprite out of ROM. Crystal is instead intended to **spawn a real in-game object event** and
let the engine draw it, so palettes, occlusion, priority and animation are the game's problem
rather than ours.

That is a deliberate, recorded decision, not an implementation detail — it is the first time
MeshGhost writes game memory, and it required an ADR to clear `plans.md`'s standing no-writes
non-goal. **Read
[agent_docs/architecture.md](../../../agent_docs/architecture.md)'s 2026-08-17 entry before
touching any of this**, including its open question about whether the engine's own routine can be
*called* rather than imitated.

> **Warning — why an unrecognised ROM must never be written to.** Archipelago's Crystal patch
> rearranges WRAM **non-uniformly**; no constant offset recovers the vanilla addresses
> ([agent_docs/verified.md](../../../agent_docs/verified.md), 2026-08-17). A write aimed at a
> vanilla address on a patched ROM does not fail cleanly — it lands on whatever now occupies that
> address. The adapter must positively identify the ROM before writing and refuse to spawn
> otherwise.

## How this adapter was built

Only steps that actually happened and were confirmed are listed here.

1. Checked the licences for the whole `pret` family before reading any of it — all of them carry
   no licence file, so the same facts-only posture already used for `pokeemerald` applies.
   ([agent_docs/licensing.md](../../../agent_docs/licensing.md))
2. Built `pokecrystal` locally and confirmed the result is byte-identical both to the ROM being
   played and to the hash the decomp documents, which is what makes every address below
   authoritative rather than merely plausible.
   ([agent_docs/verified.md](../../../agent_docs/verified.md))
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

## What's here

- `domain_probe.lua` — read-only. Finds which BizHawk memory domain exposes WRAM bank 1, by
  matching the decomp's four-consecutive-bytes fingerprint and requiring both coordinates to
  change as you walk, so a lookalike cannot pass.
- `object_slot_probe.lua` — read-only. Dumps the 13 object structs live, to establish how many
  slots are genuinely free during play and what a map transition does to them. **Required
  evidence before anything is spawned**; performs no writes.
- `ap_*.lua` — read-only. The Archipelago measurement family, one probe per question: `ap_reverse`
  (coordinates, by walking one way then back), `ap_address` and `ap_struct_check` (the object
  array), `ap_mapobj` (the map-object table), `ap_state` and `ap_mapid` (map identity and game
  state), `ap_battlemode`, `ap_scroll_probe` and `ap_scroll_watch` (the scroll offsets). Each one
  exists because the address it hunts could not be derived from vanilla — see its own header for
  what was tried first and why it failed.

Both write a timestamped `.log` beside themselves, so a run leaves a record without anyone
copying text out of the Lua Console.
