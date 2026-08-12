# TEVI

**Status: second target game (chosen 2026-08-11, replacing Ori: Will of the Wisps).**

- Unity, 2D movement-focused platformer/metroidvania — the genre where ghost co-op is most
  visually satisfying, and the reason it was picked over Pseudoregalia for the second slot.
- Owned by the project author, unlike the Ori titles (see `adapters/oribf/README.md`),
  which was the deciding factor.
- IL2CPP vs Mono build status: **confirmed Mono** (2026-08-11) — see
  `agent_docs/environment.md`'s Unity/TEVI section for the file evidence (`Assembly-CSharp.dll`
  present, no `GameAssembly.dll`, `doorstop_config.ini` has `[UnityMono]`). BepInEx/Harmony
  tooling applies directly; no IL2CPP interop/unhollowing step needed. BepInEx 5.4.23.3 is
  already installed on this machine's TEVI copy and confirmed loading a third-party plugin.
- Phase 6 in progress. Phase 5 froze the adapter template (`adapters/_template/`) — see
  `agent_docs/phases/phase5.md`.
