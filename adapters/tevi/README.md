# TEVI

**Status: second target game (chosen 2026-08-11, replacing Ori: Will of the Wisps), shipped —
Phase 6 fully done 2026-08-13.**

- Unity, 2D movement-focused platformer/metroidvania — the genre where ghost co-op is most
  visually satisfying, which is the same reasoning the brief used for Ori, and why it took the
  second slot over the two Ori titles (see
  [agent_docs/architecture.md](../../agent_docs/architecture.md)'s 2026-08-11 decision;
  Pseudoregalia was slated last from the brief onwards, never a second-slot candidate).
- **How the game is read: the shipped artifact documents itself.** `Assembly-CSharp.dll` is managed
  Mono bytecode, decompiled locally with ILSpy to read real class and field names, and the adapter
  compiles against it — so a wrong name is a build error, not a silent runtime nothing. A little C#
  reflection reaches non-public members. This is the easiest of the three access models the project
  has used, and it is why this adapter was by far the fastest. See
  [agent_docs/access-models.md](../../agent_docs/access-models.md).
- **[documentation.md](documentation.md)** describes how TEVI itself works — reaching the player
  through `EventManager`, the gap between the logic position and the drawn position, the player's
  Unity `Animator` clips addressed by name (the playable characters are *not* Spine, though other
  things in the game are), facing as a sprite flip, and the map screen's separate coordinate
  system. It was previously argued that a game with a readable managed assembly needed no such
  file; **the user overturned that 2026-08-18** and every adapter now carries one — being able to
  look something up is not the same as having looked
  ([adapters/_template/README.md](../_template/README.md)'s folder convention).
- Owned by the project author, unlike the Ori titles (see
  [adapters/oribf/README.md](../oribf/README.md)), which was the deciding factor.
- IL2CPP vs Mono build status: **confirmed Mono** (2026-08-11) — see
  [agent_docs/environment.md](../../agent_docs/environment.md)'s Unity/TEVI section for the
  file evidence (`Assembly-CSharp.dll` present, no `GameAssembly.dll`, `doorstop_config.ini`
  has `[UnityMono]`). BepInEx/Harmony tooling applies directly; no IL2CPP interop/unhollowing
  step needed. BepInEx 5.4.23.3 is already installed on this machine's TEVI copy and confirmed
  loading a third-party plugin.
- Phase 6 is **fully done, confirmed 2026-08-13** (including 6.6, two real players, and 6.7,
  the map marker) — see [agent_docs/plans.md](../../agent_docs/plans.md)'s Phase 6 entry and
  [agent_docs/phases/phase6.md](../../agent_docs/phases/phase6.md). This adapter was built from
  the template Phase 5 extracted (`adapters/_template/`) — see
  [agent_docs/phases/phase5.md](../../agent_docs/phases/phase5.md).

## Custom features

Map marker for other player ghosts, shows a constantly tracking/updating tiny tevi bunny icon
for where other players are in your current zone (as long as you have discovered/seen the maps
before). Known limitation: it only refreshes when a `render_remote` arrives, so a peer who stops
sending leaves their marker frozen where it was — see
[agent_docs/status.md](../../agent_docs/status.md).

## How this adapter was built

Second game, and by far the fastest: about 1 hour from start to a ghost following the player
with all animations working. Server/client and the general approach were already proven by
the `bizhawk/pokemon/emerald` adapter, so this was adapter-only work. BepInEx plus being able to
decompile the game made this easier and faster than Emerald, even though Emerald had a full
source decompilation available to reference — a lot of things (notably the animations) just
worked as soon as they were wired up, with no equivalent of Emerald's memory-probing phase.

Roughly in order (mostly [agent_docs/phases/phase6.md](../../agent_docs/phases/phase6.md) —
item 8 below was found later, during a cross-adapter review pass, and lives in
[agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) and
[agent_docs/verified.md](../../agent_docs/verified.md) instead):

1. Purple box as proof of concept (same first step as Emerald).
2. Cyan box following the player.
3. Replaced the box with the actual sprite.
4. Added animations.
5. Wired up real networking; the first real test hit the relay's 120 msg/sec rate limit for
   real, since TEVI's `Update()` runs uncapped — fixed with a client-side send-rate cap in the
   core, not the adapter. (6.4/6.5)
6. Hit a blocker testing with two players locally — Steam won't run two instances of the same
   game at once — resolved by downloading a second, standalone build via `steamcmd`.
7. Made ghosts hide when the peer is in a different zone (a real gap where remotes weren't
   filtered by area at all). (6.6)
8. Found and fixed a separate bug, later, during a cross-adapter review pass: a ghost
   recreated during a peer's own zone transition could go permanently invisible, because it
   inherited a disabled sprite-renderer field from the live character at clone time.
9. Added a marker on TEVI's own pause-screen map showing where the other player is, gated by
   the local player's own fog-of-war so it doesn't leak undiscovered rooms. (6.7)

### Further work past "good enough"

- A per-remote redraw trace (position/active-state/scene, throttled to once every 2s per
  remote) was added in `Plugin.cs`'s `UpsertRemoteGhost` while chasing the zone-transition
  invisible-ghost bug in item 8 above. That bug is root-caused and fixed, so the trace is now
  gated behind `DIAG_REDRAW_TRACE` (default `false`) — flip it on only when chasing a similar
  live repro.
- Still open, found live 2026-08-15: a ghost's charged-attack VFX don't render — the animations
  play, the effects don't. Not root-caused; see
  [agent_docs/phases/phase6.md](../../agent_docs/phases/phase6.md)'s Notes.
