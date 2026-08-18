# Current status

## Active status

**Phase 8 (Emerald) is the live one as of 2026-08-18** — the shipped adapter now SPAWNS a real
object event instead of drawing an overlay, so the engine owns animation, palette and occlusion.
Confirmed piece by piece on screen; **the end-to-end pass and five other items are still queued in
`unverified.md`, which is the file to read next.** `phases/phase8.md`.

**Phase 7 (Pseudoregalia) 7.7 is DONE** — two real players on two machines, confirmed 2026-08-16
with the Linux tester. It cleared pole rotation; the rest of the two-player-blocked list below is
now testable but not yet re-judged. Phase 6 (TEVI) is done.

**Landed 2026-08-16** (autostart on Windows+Proton, v0.7.0, admission control, the camera/rig fix,
no more through-wall ghosts; Go side: quic default, ordered udp, `cmd/meshghost-netsim`) and
**2026-08-17** (a sliding ghost posed via the game's own crouch path, retiring the +43 render-Z
bandage; Go side: the planes past cosmetic — events, sequencer, leases, escrow, snapshots,
resumption, clock sync, and world custody, all opt-in and unused by any adapter) — full record in `verified.md`,
`plans.md`, `architecture.md` and `adapters/pseudoregalia/BANDAGES.md`.

**Also 2026-08-17, Go side:** two handshake races CI's race job caught and local runs never did
(a message could beat a client's own Welcome; a rejected connect left a half-open relay behind),
and the six library packages moved out of `internal/` to the repo root under the module's real
path — importable from outside, with no stability promised. See the ADR in `architecture.md`.

**Phase 9 (Crystal): the whole cosmetic mechanism is DONE, confirmed on screen 2026-08-18** — a
player-looking character spawned on demand anywhere, that WALKS with the game's own step
animation, with the adapter drawing, animating and interpolating nothing. Networking is the
largest remaining piece. `phases/phase9.md`.

Roadmap: `plans.md`. Per-phase log: `phases/`. Evidence for all of the above: `verified.md`.

## Genuinely open items

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

### Deferred by the 2026-08-18 audit-and-refactor pass

The pass fixed two real relay bugs, four adapter defects and ~60 stale doc claims; these were
identified, scoped and deliberately NOT done, because each needs a live game to judge or is large
enough that bundling it would make one confirmation pass unable to isolate a regression.

- **`Plugin.cpp`'s `game_thread_tick()` is ~4,000 lines in a 10,347-line file.** Its neighbours are
  already extracted (`tick_remote_weapon`, `tick_afterimage_discovery`); the per-remote blocks are
  the next ones. Behaviour-preserving but on the adapter's hot path — needs a live session.
- **The two BizHawk Lua adapters duplicate ~400-500 lines each** (JSON codec, socket loader, port
  walk, framing). Shared `adapters/bizhawk/lib/` would need a matching `release.yml` staging change.
- **Probe boilerplate: an identical 47-line block across 8 Crystal probes**, including the ROM
  guard. Do the guard and `detect_rom_variant()` first — eight divergeable copies of "refuse to
  write unless the checksum matches" is the risk, not the line count.
- **`cmd/meshghost` and `cmd/meshghost-relay` duplicate ~120 lines of config/log plumbing**
  (`stripBOM` is byte-identical). An `internal/cfg` package; both mains' comments already say
  "mirrored in".
- **TEVI: the `bridge_ready` send gate and the port walk.** Registered as entry 5 in
  `adapters/tevi/BANDAGES.md` with the reason it was not rushed.

### Was blocked on a two-player session — now unblocked (7.7 confirmed 2026-08-16)

Two real players on two machines, confirmed on screen — `verified.md`. These need re-judging now
that a peer's state genuinely differs from the local player's, which loopback could never show:

- ~~A fresh ghost shows the LOCAL player's state, not the peer's.~~ **CLOSED 2026-08-17** — a
  synthetic peer rendered with default appearance, not the local save. `verified.md`.
- **Ghost collision: keeping it ON, still WIP.** Enemies can no longer hit the ghost (confirmed
  2026-08-17); the player still can. `risks.md`, `verified.md`.
- **Killing a ghost leaves the player respawning at 0/empty health** — player melee only; the HUD
  is fine, the value isn't. Suspect shared health state. `verified.md` 2026-08-17.
- **Ghost vanishes while a peer is on a pole**, then returns stuck in a climb pose. Cause unknown,
  two suspects ruled out; `phase7.md`. (Pole *rotation* was the separate item, cleared 2026-08-16.)
- **A thrown sword near a save crystal.** Suspected a loopback-offset artifact rather than a real
  bug; a two-machine session settles it. `verified.md`.

### Open, not blocked

- **Crystal: a ghost looks like THIS machine's player, not the peer** — a peer's own gender needs
  their sprite loaded locally. `phases/phase9.md`.
- **Crystal/Archipelago: `wBattleMode` unmeasured** — 0x015A vs 0x1234, needs one trainer battle.
  Everything else is measured and a loopback ghost walks on the AP ROM. `phases/phase9.md`.
- **Crystal: does a ghost survive a battle?** Set up twice, answered neither time. `phase9.md`.
- **The core dropped its relay connection twice on quic** — `use of closed network connection`,
  ~40s apart, reconnecting each time; moving to tcp stopped it. Go side. `verified.md` 2026-08-18.
- **Duplicate ghost spawn on every level load** — two ghosts per peer, the `remotes` entry going
  present -> absent within three ticks, leaving an orphaned pawn nobody tracks. `verified.md`.
- **Two different games at once: half fixed** — the user-visible symptom of the bridge-shape gap
  below. Pseudoregalia's port walk is built but **not yet watched live**. `ideas.md`.
- **TEVI's FullMap marker goes stale** — it only refreshes on a `render_remote`, so a peer who
  stops sending leaves a marker frozen where it was. Shipped bug, not hypothetical. `ideas.md`.
- **TEVI lags the template's bridge shape** — no autostart, no port walk, no `bridge_ready`.
  Both Pokémon adapters got the walk and the ack 2026-08-18, **untested live**. `_template/PROTOCOL.md`.
- **Emerald's shipped adapter spawns instead of drawing** — user-confirmed piece by piece
  2026-08-18 (appears, follows, walks, runs, on-grid, no leak); **no end-to-end pass yet.**
- **Awaiting a confirmation pass**: the spawn adapter and the whole test toolchain were built and
  self-tested the same day. Nothing in either is "done" until the user confirms the result.
- **Emerald: a peer's own state (surf/bike/fishing) is not rendered yet** — the state is its
  `graphicsId` and all player states share one palette tag, so this is now scoped. `phase8.md`.
- **Emerald: Archipelago ROMs still use the overlay** — `gSprites`' shift is unmeasured, so the
  spawn path refuses to write there. `adapters/bizhawk/pokemon/emerald/BANDAGES.md`.
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
- **TLS for TCP, toggleable** — `tcp` is plaintext NDJSON while `quic` is encrypted. **Off in dev**
  (plaintext is how a session gets debugged: netcat, capture, netsim), **on for release**. `ideas.md`.
- **Relay-safety follow-ups**: `quic` is now the default so room codes are encrypted by default but
  still **not authenticated**; TEVI's `game_version` isn't real; adapters' parsing never audited. `docs/security.md`.
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
