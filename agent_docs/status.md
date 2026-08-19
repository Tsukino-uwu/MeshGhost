# Current status

## Active status

**Phase 9 (Crystal) is the live one as of 2026-08-19.** `phases/phase9.md`, `plans.md` 9.1.

- **Crystal renders peers in TWO tiers now**: spawned real objects up to what the game can draw,
  and everything past that PAINTED over the emulator. A character on every visible tile at 60fps,
  user-confirmed. `verified.md` 2026-08-19, `crowd-limits.md`.
- **Emerald's spawned tier passed end to end**, and `MESHGHOST_COMPARE_TIERS` (both renderers on
  screen at once) then found a dozen defects in one session, fishing last. `verified.md` 2026-08-19.
- **The core's `-interp` default is 250ms**, measured rather than guessed — 100ms visibly chopped
  an engine-driven ghost. `verified.md`, `bandages-core.md` entry 1.
- Phases 6 (TEVI), 7 (Pseudoregalia) and 8 (Emerald) are done; 8's queue is in `unverified.md`.

**Everything below this line is an INDEX of what is open.** Two lines per item, and the detail
lives in `verified.md`, `pitfalls.md` or a phase file — see the update guidance at the bottom.

Roadmap: `plans.md`. Per-phase log: `phases/`. Evidence: `verified.md`. What the user has not
confirmed yet: `unverified.md`.

## Picking this up in a new session — rewritten 2026-08-19 afternoon, and the first thing to read

**The four-emulator session described here before is GONE** — none of those processes survived.
What is running now is a single vanilla Emerald instance, left up after its end-to-end
confirmation pass:

| ROM | BizHawk pid | Bridge | Loader control file |
|---|---|---|---|
| Vanilla Emerald | 31012 | 7778 | `bizhawk-dev-loader-emerald.target` |

(pids change; match on the `--lua=` argument. The relay on 7777 carries `-loopback`, so the one
client sees a self-ghost; the core is pinned to `-transport=tcp`, deliberately, to keep a quic drop
from being mistaken for a ghost bug. The loader control file holds the adapter plus
`probes/textbox_probe.lua`; drop the probe before judging performance.)

**The opening move, in order:**

1. **Claim instances.** One agent per BizHawk INSTANCE, and hand each its pid, control file, bridge
   port and the off-limits list of everyone else's — `environment.md`. Kill only by PID, never by
   name or wildcard.
2. **Read `playing.md` before driving anything.** Cheats are permitted to make progress as of
   2026-08-19, including collision and tile edits; that file is the whole permission set.
3. **Resume the four missions**, which are settled and should not be re-derived:
   - **Archipelago Crystal and Archipelago Emerald: full playthroughs**, start to finish. Every
     state they pass through is adapter coverage nobody scripted.
   - **Vanilla Crystal and Vanilla Emerald: ghost animation completeness** — surf, Fly, bikes,
     fishing and the rest. The enumeration is already in `phases/phase9.md`.
4. **Screenshot into `dev-scripts/shots/<game>/` and look before acting.** `client.screenshot()`
   only — never a window capture — and remember it cannot see a drawn-tier ghost.
5. **Launching BizHawk from PowerShell: quote the ROM path inside a single argument string.**
   `Start-Process -ArgumentList` on PS 5.1 does not quote array elements, so a path with spaces
   arrives split and EmuHawk opens an `Exception` window instead of the game (2026-08-19).

**Both Archipelago blockers are CLOSED** (`wBattleMode` = `0x1234`; the graphics-info pointer table
shifts by `0x7530`), so neither adapter refuses on a patched ROM any more. What replaced them at
the top of the list is below.

## Genuinely open items

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

### Deferred by the 2026-08-18 audit-and-refactor pass

The pass fixed two real relay bugs, four adapter defects and ~60 stale doc claims; these were
identified, scoped and deliberately NOT done, because each needs a live game to judge or is large
enough that bundling it would make one confirmation pass unable to isolate a regression.

- **`Plugin.cpp`'s `game_thread_tick()` is ~4,000 lines in a 10,347-line file.** Per-remote blocks
  are the next extraction; on the adapter's hot path, so it needs a live session.
- **The two BizHawk Lua adapters duplicate ~400-500 lines each** (JSON codec, socket loader, port
  walk, framing). Shared `adapters/bizhawk/lib/` would need a matching `release.yml` staging change.
- **Probe boilerplate: an identical 47-line block across 8 Crystal probes**, including the ROM
  guard. Do the guard and `detect_rom_variant()` first — divergence is the risk, not the lines.
- **`cmd/meshghost` and `cmd/meshghost-relay` duplicate ~120 lines of config/log plumbing**
  (`stripBOM` is byte-identical) — an `internal/cfg` package; both mains already say "mirrored in".
- **TEVI: the `bridge_ready` send gate, and the port walk.** The message is RECOGNISED as of
  2026-08-18 but not yet waited on before sending. Entry 5 in `adapters/tevi/BANDAGES.md`.

### Was blocked on a two-player session — now unblocked (7.7 confirmed 2026-08-16)

Two real players on two machines, confirmed on screen — `verified.md`. These need re-judging now
that a peer's state genuinely differs from the local player's, which loopback could never show:

- **Ghost collision: answered as a setting, not a yes/no.** ADR 2026-08-19 in `architecture.md`
  makes it a host-set room policy with a one-way client override; decided, not implemented.
- **Killing a ghost leaves the player respawning at 0/empty health** — player melee only; the HUD
  is fine, the value isn't. Suspect shared health state. `verified.md` 2026-08-17.
- **Ghost vanishes while a peer is on a pole**, then returns stuck in a climb pose. Cause unknown,
  two suspects ruled out; `phase7.md`. (Pole *rotation* was the separate item, cleared 2026-08-16.)
- **A thrown sword near a save crystal.** Suspected a loopback-offset artifact rather than a real
  bug; a two-machine session settles it. `verified.md`.

### Open, not blocked

- **Ghost collision policy: Go side DONE, adapters not wired.** Config, wire and bridge all ship
  and are tested; no adapter reads `session_policy` yet, so nothing changes on screen. ADR 2026-08-19.
- **Drawn-tier visual parity: EMERALD IS DONE** (occlusion, shadow, reflection all confirmed
  2026-08-20, `verified.md`). Crystal's tier still has none of it.
- **A vanilla battle with a crowd was never reached** — our own spawned ghosts boxed the player in
  on the way to grass, which `crowd-limits.md` predicts. `unverified.md`, `pitfalls.md`.
- **Emerald's real-panel clip count was REACHED, not played to** — the position was written, so it
  says nothing about whether ordinary play produces that overlap. `verified.md` 2026-08-19.
- **Crystal's phone-call panel is two panels** — full-width at the top plus the ordinary bottom
  box; the row-12 test sees only the bottom one. Detection unwritten. `unverified.md`.
- **Crystal's drawn tier is unconfirmed**: animation, facing and text-box clipping all landed
  2026-08-19 after the fill-the-screen test. `unverified.md`, `crowd-limits.md`.
- **Crystal/Emerald: ghost animation completeness** — Emerald fishing is DONE and 1:1 on both tiers
  (`verified.md` 2026-08-19); bikes and surfing are next, same class. `unverified.md`.
- **Crystal has none of 2026-08-19's Emerald animation fixes**, and its drawn tier ships ON —
  the paused-sprite and derived-offset traps apply there too. `pitfalls.md`, three Emerald entries.
- **Crystal: a peer's own sprite is used when its tiles are resident, not otherwise** — but the
  DRAWN tier could read any sprite from ROM, which would close it. `phases/phase9.md`.
- **Crystal: a ghost does NOT survive a battle** — answered from the code 2026-08-19 and fixed
  (it used to hijack an NPC); a real battle still needs watching. `phase9.md`, `unverified.md`.
- **The core dropped its relay connection twice on quic** — `use of closed network connection`,
  ~40s apart; moving to tcp stopped it. Go side. `verified.md` 2026-08-18.
- **Duplicate ghost spawn on every level load** — two ghosts per peer, the `remotes` entry going
  present -> absent within three ticks, leaving an orphaned pawn nobody tracks. `verified.md`.
- **Two different games at once: half fixed** — the user-visible symptom of the bridge-shape gap
  below. Pseudoregalia's port walk is built but **not yet watched live**. `ideas.md`.
- **TEVI's FullMap marker goes stale** — it only refreshes on a `render_remote`, so a peer who
  stops sending leaves a marker frozen where it was. Shipped bug, not hypothetical. `ideas.md`.
- **TEVI lags the template's bridge shape** — `bridge_ready`/`reject` and autostart landed
  2026-08-18; the PORT WALK is the remaining gap. `_template/PROTOCOL.md`.
- **Emerald peer state: SPAWNED tier confirmed (fishing), DRAWN tier cannot** — the painted path
  only knows the walk/run pic tables, so a bike/surf/rod peer paints as walking. `verified.md`.
- **Loopback offset puts the ghost inside/above sloped geometry** — a rig artefact, since a real
  peer's position is always valid. Weigh loopback-only anomalies accordingly. `verified.md`.
- **Pseudoregalia: a hard crash mid-session after the pause menu opened twice** — not root-caused,
  not attributable to MeshGhost on the evidence. `verified.md` 2026-08-17.
- **Pseudoregalia: a `Fatal Error!` on game exit**, seen once, never root-caused. Not the
  2026-08-16 transition crash, which is fixed.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, effects don't.
  `phase6.md` (2026-08-15).
- **Emerald: surf, Mach/Acro Bike, ledges, rails** — ghost snaps badly; combined probe script
  ready, **not yet run**. `phase8.md`.
- **Emerald: VRAM/sprite injection** — Stage 1 ran 2026-08-14 and is written up; Stages 2–5 not
  started. `ideas.md`, `environment.md`.
- **Receive rate cap** — `max_receive_hz_per_player` never watched live; needs two clients at
  different caps. (The send side was confirmed on screen 2026-08-15.) `architecture.md` ADR.
- **Encrypted everywhere except udp, authenticated nowhere** — tcp gained TLS 2026-08-19, so both
  default transports encrypt; nothing proves a relay is who it says. `docs/security.md`.
- **Relay-safety follow-ups**: TEVI's `game_version` isn't real; adapters' parsing never audited;
  no per-IP cap, which TLS handshakes make more interesting. `docs/security.md`.
- **Transports: quic default confirmed with a real game attached** (2026-08-16, shared port, no
  flags). Open: no sustained-load or two-machine test yet, no per-IP cap. `verified.md`, `risks.md`.
- **A served-but-unforwarded transport strands a client** — discovery knows what a relay offers,
  not whether the path works, so it retries instead of falling back to tcp. Docs-only for now.
- **The planes past cosmetic have no live consumer.** Built and Go-tested 2026-08-17 (world custody
  added the same day); no adapter asks for any capability yet. `beyond-cosmetic.md`, `architecture.md` ADR.
- **A maximal `event`/committed `escrow_state` exceeds a udp datagram and is silently dropped** —
  pre-existing, unreached today, and its own decision to fix. `risks.md`.
- **An adapter's declared `features` are ignored when the core is started with `-game`**, since it
  connects to the relay before any adapter speaks. Lazy path only. `core/core.go`.
- **udp signals nothing on close, so a dropped udp peer freezes for up to 60s** — tcp is instant,
  quic ~17s. Fix is a token-carrying control frame. `netx/conformance_test.go`.
- **`clock.v1` never tested against a genuinely skewed peer** — needs two machines with
  deliberately different clocks. `dev-scripts/run-core-pseudoregalia-online.bat` step 3.
- **quic's drop detection (~17s) dominates any resume grace** — `quicConfig` sets no
  `MaxIdleTimeout`. `verified.md` 2026-08-17, `architecture.md` ADR.
- **Nameplates / one-shot peer effects are now unblocked** — both were parked for want of the
  event plane, which exists. Needs per-adapter work. `ideas.md`.

## Links

`unverified.md` (**what the user has not confirmed yet** — read before claiming anything works) ·
`plans.md` (roadmap) · `phases/phase6.md`|`phase7.md`|`phase8.md`|`phase9.md` (per-phase log) · `risks.md`
(assumptions) · `verified.md` (confirmed facts) · `pitfalls.md` (symptom → cause → fix, and the
diagnostic methodology rules).

## Update guidance

This file is an **index of what is open**, not a record of anything. Every item here is a pointer;
the record lives in `verified.md`, `pitfalls.md`, or a phase file.

- **Two lines per item, maximum: what is open, and where the detail lives.** A third line means it
  belongs in `verified.md`/`pitfalls.md`/`phases/phaseN.md` — move it, leave a pointer. (Replaced a
  flat line cap on 2026-08-16, which capped the file but not per-item verbosity, so it crept back.)
- **Delete an item the moment it is fixed and confirmed** — never leave a "FIXED" entry behind.
- Update whenever the active phase changes — overwrite in place, never append.
