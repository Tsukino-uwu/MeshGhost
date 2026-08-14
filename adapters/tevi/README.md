# TEVI

**Status: second target game (chosen 2026-08-11, replacing Ori: Will of the Wisps).**

- Unity, 2D movement-focused platformer/metroidvania — the genre where ghost co-op is most
  visually satisfying, and the reason it was picked over Pseudoregalia for the second slot.
- Owned by the project author, unlike the Ori titles (see
  [adapters/oribf/README.md](../oribf/README.md)), which was the deciding factor.
- IL2CPP vs Mono build status: **confirmed Mono** (2026-08-11) — see
  [agent_docs/environment.md](../../agent_docs/environment.md)'s Unity/TEVI section for the
  file evidence (`Assembly-CSharp.dll` present, no `GameAssembly.dll`, `doorstop_config.ini`
  has `[UnityMono]`). BepInEx/Harmony tooling applies directly; no IL2CPP interop/unhollowing
  step needed. BepInEx 5.4.23.3 is already installed on this machine's TEVI copy and confirmed
  loading a third-party plugin.
- Phase 6 in progress. Phase 5 froze the adapter template (`adapters/_template/`) — see
  [agent_docs/phases/phase5.md](../../agent_docs/phases/phase5.md).

## How this adapter was built

Second game, and by far the fastest: about 1 hour from start to a ghost following the player
with all animations working. Server/client and the general approach were already proven by
the `pokemon/emerald` adapter, so this was adapter-only work. BepInEx plus being able to
decompile the game made this easier and faster than Emerald, even though Emerald had a full
source decompilation available to reference — a lot of things (notably the animations) just
worked as soon as they were wired up, with no equivalent of Emerald's memory-probing phase.

Roughly in order (all of it is [agent_docs/phases/phase6.md](../../agent_docs/phases/phase6.md)):

1. Purple box as proof of concept (same first step as Emerald).
2. Cyan box following the player.
3. Replaced the box with the actual sprite.
4. Added animations.
5. Made ghosts hide when the peer is in a different zone, and fixed a bug where a ghost could
   turn invisible when changing zones.

### Further work past "good enough"

None logged yet — add entries here if work on this adapter resumes past Phase 6.
