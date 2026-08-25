# Phase 4 — Two players

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).
> **Adapter paths predate the 2026-08-25 folder rename** — read any `adapters/bizhawk/` as
> `adapters/emulator/`. Left as written for the same reason: a phase file records what was true
> while the phase ran.

Folded back into `agent_docs/plans.md` as complete (2026-08-11); kept here for the detailed
task-by-task record. Per `agent_docs/README.md`'s rule: a phase earns a file when it's live,
and gets folded back once it's done. **Status: complete** — all success criteria below
confirmed live with two real BizHawk/Emerald instances, including the battle/menu ghost-hiding
follow-up (see below), which was closed out shortly after the phase itself, in the same
session.

## Purpose

Prove the first real multiplayer milestone: two independent BizHawk/Emerald instances, each
running its own adapter -> bridge -> core, joined to the same relay room, each rendering the
other's ghost. Everything through Phase 3 was one physical client (loopback echo standing in
for a second player); this phase replaces that echo with an actual second peer and finds out
whether the join/leave and interpolation paths built ahead of schedule (see
`agent_docs/status.md`'s "Go networking layer" section) hold up against real network behavior
instead of a synthetic one.

## Setup (per `agent_docs/status.md`'s "Next step")

- One `meshghost-relay` process, **without** `-loopback` — that flag fakes a second player and
  would add a confusing phantom third ghost alongside a real second one.
- Two `meshghost.exe` processes, each with distinct `-bridge` and `-name` flags, joined to the
  same `-relay`/`-room`/`-game`. `cmd/meshghost/main.go` already exposes all of these flags
  (confirmed: `-relay`, `-bridge`, `-game`, `-room`, `-name`, `-interp` — no Go changes needed
  for this alone).
- Two BizHawk instances, each with its own Emerald ROM instance, each running the adapter
  script pointed at its own core's bridge port.

## Known gap, closed

`adapters/bizhawk/pokemon/emerald/probes/phase3_loopback.lua:55` hardcoded `local BRIDGE_PORT = 7778` — as written,
two BizHawk instances couldn't point at two separate core processes without editing the
script. **Closed**: `adapters/bizhawk/pokemon/emerald/probes/phase4_multiplayer.lua` is a new script (Phase 3's file
stays as-is, a historical record of a completed phase, per the project's one-script-per-phase
convention) that is otherwise identical but reads `BRIDGE_PORT` from the
`MESHGHOST_BRIDGE_PORT` environment variable, falling back to 7778 (the same default
`cmd/meshghost/main.go`'s own `-bridge` flag uses) when unset — so a single instance still
needs zero setup. `os.getenv` was already confirmed available in this BizHawk Lua sandbox in
Phase 3 (used for `PROCESSOR_ARCHITECTURE`), so this isn't a new unverified API. Two instances:
set `MESHGHOST_BRIDGE_PORT` in the environment each BizHawk process inherits before launching
it, matching each instance's `meshghost.exe -bridge=127.0.0.1:<port>`. Not yet run live against
two real BizHawk instances — that's the next task below.

## Tasks

- [x] Close the `BRIDGE_PORT` gap above — `adapters/bizhawk/pokemon/emerald/probes/phase4_multiplayer.lua`.
- [x] Start one `meshghost-relay` (no `-loopback`), two `meshghost.exe` processes with distinct
      `-bridge`/`-name` on the same `-relay`/`-room`/`-game`, two BizHawk instances.
- [x] Confirm on screen: each client renders the other's ghost, tracking correctly.
- [x] Join test: start client A first, walk around, then start client B — confirm A's screen
      shows B's ghost appear (not just B seeing A).
- [x] Leave test (clean): close one adapter/core cleanly — confirm the other side despawns the
      ghost. Confirmed with a real peer for the first time (Phase 3's despawn coverage was all
      disconnect-of-self). Also found and confirmed: closing only the adapter (not the core)
      correctly does *not* despawn — the peer's core is still in the room.
- [x] Leave test (unclean): kill one core process or its BizHawk instance without a clean
      shutdown — confirm the other side still despawns rather than freezing a stale ghost.
      Confirmed via Task Manager End Task on a core process — both the relay-side despawn and
      the killed peer's own `drainBridge` disconnect-detection generalized correctly past the
      loopback synthetic peer.
- [x] Re-confirm no flicker and correct interpolation with two independently-moving real
      players. Confirmed, no drift/flicker reported, with the caveat that the placeholder
      magenta-box art makes subtle stutter hard to judge by eye.
- [x] Record every confirmed fact in `agent_docs/verified.md`, human-gated as always. Four new
      entries added covering the join/render milestone, clean leave, unclean leave, and the
      battle-anchor bug below.

## Deferred, deliberately

- **Battle-skip gating — closed out.** Two-player testing surfaced exactly the bad in-battle
  ghost render Phase 2 predicted. Found and cited a real `pokeemerald` signal
  (`gMain.callback2` vs `CB2_Overworld`, confirmed live via `adapters/bizhawk/pokemon/emerald/probes/battle_probe.lua`)
  that turned out to generalize beyond battle specifically — it also covers every full-screen
  pause-menu submenu (Pokédex, Bag, Player Card, Options), while correctly leaving NPC dialogue
  ungated. Wired into `phase4_multiplayer.lua` as `inOverworld()` and confirmed live: ghosts
  correctly hide and reshow around battle and every submenu, strictly per-viewer (a remote's own
  menu/battle state never affects whether it's drawn on someone else's screen). See
  `agent_docs/verified.md` for the full entries. A related, separate bug found and fixed in the
  same session: remote ghosts rendered one tile too high (sprite-anchor vs. tile-position
  mismatch) — fixed with a `GHOST_Y_CORRECTION` constant, confirmed on screen.
- **The noisy `core: send state to relay failed` log spam** after a relay disconnect, deferred
  from Phase 3 as harmless. Fix opportunistically if convenient while touching `internal/core`
  for other reasons this phase; not worth a dedicated task.
- **Room codes** — explicitly a separate post-Phase-4 item per `agent_docs/plans.md`, not part
  of this phase's success criteria.
- **Archipelago-coexistent adapter** — out of scope; still needs its own address re-derivation
  against a patched ROM whenever it's picked up.

## Success criteria

- Two independently-running BizHawk/Emerald instances, joined to the same relay/room, each
  show the other's ghost on screen, confirmed by the user watching it happen — not inferred
  from clean logs or a successful build.
- A peer joining after the other is already in-session is visible to the earlier client.
- A peer leaving — both clean and unclean — despawns correctly on the other side.
- No flicker or drift with two real, independently-moving players.

## Links

- `agent_docs/status.md` — the "Next step" section this file expands on.
- `agent_docs/phases/phase3.md` — the loopback phase this one replaces the echo from, and the
  source of the two disconnect-handling bugs being re-verified here against a real peer.
- `agent_docs/contract.md` — packet schema, adapter interface, transport, tick model.
- `agent_docs/plans.md` — roadmap; Post-Phase-4 room codes are next after this.
- `agent_docs/verified.md` — where confirmed facts land, after live verification.
