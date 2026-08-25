# Current status

## Active status

**Active phase: 9 — Crystal.** Emerald is PARKED, feature complete as of 2026-08-21 on the user's
call (*"i consider the game to be fully synced up animation and effect wise now"*), handed off the
same day: *"i will move on to crystal and not work more on emerald right now."* `verified.md`.

- **Emerald work is not scheduled.** A new animation/effect item for it needs a reason it is not
  polish or a custom feature; a real fault is a defect against a finished adapter. `phase8.md`.
- **Ferry and rails: assumed to work, never tested, deliberately NOT open items.** The user dropped
  them from here on purpose; the assumption is recorded so it cannot decay. `unverified.md`.
- **Crystal is where the gap is.** Both tiers were confirmed good at the dev rig's own settings
  2026-08-22/23; most of what is open below is a fix built since and never watched. `verified.md`.
- **Rig SHUT DOWN, still — no rig ran on 2026-08-25 either**; ROM **V1.0**. Rebuild with
  `run-relay-loopback-shipped.bat` + `run-core-crystal-shipped.bat` — shipped 250ms/20Hz.
- **NEXT SESSION STARTS HERE: Crystal's in-place animations are built and need ONE live run.**
  Five things to watch, with what correct looks like, are in `unverified.md` (2026-08-25).
- **Savestate slots on that rig:** 1 the user's, 7 their Route 39 spot, 8 `goto_map`'s undo, **9 the
  9x9 square start**. The mechanism, and the savestate-is-not-a-save trap: `environment.md`.

## Genuinely open items

- **Everything after `7f95e8b` is UNPUSHED as of 2026-08-25, and two commits are `.go`** — so CI
  has never seen the bridge-bind guard or its test. `gh run list` once pushed; the user pushes.
- **Staged-context pass DONE 2026-08-25** (`64c3162`..`47d4537`): nested `adapters/CLAUDE.md` +
  `bizhawk/CLAUDE.md`, two skills, `CLAUDE.md` 299->278. Volume problem NOT solved. `ideas.md`.
- **Doc restructuring still open: the rule/evidence condense, four duplications, three preflight
  checks, the `verified.md` per-game split.** All designed and measured in `ideas.md` (2026-08-25).
- **Five refactors deferred by the 2026-08-18 audit** — `game_thread_tick()`, the two Lua
  adapters' duplication, Crystal's probe boilerplate, `internal/cfg`, TEVI's send gate. `ideas.md`.

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

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
- **Crystal's drawn tier has no visual parity yet** — no reflection, no wake, no grass, no cave
  clip. (Emerald's equivalent closed 2026-08-21.) `verified.md`.
- **A vanilla battle with a crowd was never reached** — our own spawned ghosts boxed the player in
  on the way to grass, which `crowd-limits.md` predicts. `unverified.md`, `pitfalls.md`.
- **Emerald's real-panel clip count was REACHED, not played to** — the position was written, so it
  says nothing about whether ordinary play produces that overlap. `verified.md` 2026-08-19.
- **Crystal's phone-call panel is two panels** — full-width at the top plus the ordinary bottom
  box; the row-12 test sees only the bottom one. Detection unwritten. `unverified.md`.
- **Crystal's drawn-tier text-box clipping is unconfirmed** — it still rests on the 2026-08-19
  fill-the-screen test. (The walk cycle itself closed 2026-08-22.) `verified.md`.
- **Crystal: in-place animations are BUILT and UNWATCHED (2026-08-25)** — one rule replaced the bump
  special case: read the peer's facing byte. Turn, spin, fishing, Dig/Teleport, Fly. `unverified.md`.
- **Crystal's drawn tier jitter: three bugs fixed 2026-08-23, user says it looks fine — NOT settled.**
  Wrong camera register, unsettled K reference, sampler below early returns. `unverified.md`, `pitfalls.md`.
- **Crystal: `hSCX`/`hSCY` are inline literals, not in the per-build `ADDRESSES` table** — and the
  Archipelago build's pair is assumed, never measured. `unverified.md`.
- **Crystal: four promotion fixes, none watched** — the frame hole, the 2px hop, the donor's facing
  at spawn, and the drawn tier's bump. `unverified.md` (2026-08-23).
- **Crystal: the spawned ghost drifts a WHOLE TILE, periodically** — engine put it in `step_type=5`
  with a live duration while STANDING; suspect inherited donor movement. `unverified.md`.
- **Crystal: the spawned ghost's step trigger moved off the lerped tile onto the peer's progress** —
  jitter 6 frames -> 2, measured A/B, NOT watched. `STEP_TRIGGER_PROG=0` reverts. `unverified.md`.
- **Crystal's drawn tier is untested on bike/surf/ledges/warps and with a real peer** — the camera
  model clamps to 2-4px gaits and has only met walking on loopback. `unverified.md`.
- **Crystal: shoving a MOVING ghost aside is fixed but not watched** — it compared one tile where the
  engine blocks on two. The idle rule is still unreachable for a walker. `unverified.md` (2026-08-23).
- **Crystal: a ghost cloned a TRAINER and hung the game — fixed 2026-08-23, NOT confirmed.** Third
  bug of one root cause (inherited donor identity). `pitfalls.md`, `unverified.md`.
- **Crystal's transition hold spends its 30 frames after the world is ready, not during the
  crossing** — measured, fix built and reverted as worse. `unverified.md`, `phases/phase9.md`.
- **Crystal's hardware (OAM) tier: built, reaches the screen, shipped OFF, never judged on screen.**
  Adds 0-1 characters and does NOT get free occlusion. `FLAGS.md`, `unverified.md`.
- **Crystal: a peer sending action 8 would have had its ghost's BODY replaced by the `!` box** —
  the emote is a separate map object, never a player action. Removed 2026-08-25. `unverified.md`.
- **Crystal: no fall for Fly/Teleport/Dig, and no emote above a peer at all** — the sprite Y offset
  is not on the wire, and the `!` needs its own object. Known gaps, not faults. `phases/phase9.md`.
- **18 Emerald probes and dev-scripts were rewritten to resolve their own directory (2026-08-25)** —
  no Lua on this machine to parse them, so none has been run since. `pitfalls.md`.
- **Emerald CROSSED Lua's 200-local ceiling and did not compile at all** — fixed 2026-08-22 by
  consolidating seven constants onto two tables; now 197. Not yet loaded in a real session.
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
- **Loopback offset puts the ghost inside/above sloped geometry** — a rig artefact, since a real
  peer's position is always valid. Weigh loopback-only anomalies accordingly. `verified.md`.
- **Pseudoregalia: a hard crash mid-session after the pause menu opened twice** — not root-caused,
  not attributable to MeshGhost on the evidence. `verified.md` 2026-08-17.
- **Pseudoregalia: a `Fatal Error!` on game exit**, seen once, never root-caused. Not the
  2026-08-16 transition crash, which is fixed.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, effects don't.
  `phase6.md` (2026-08-15).
- **Emerald: VRAM/sprite injection** — Stage 1 ran 2026-08-14 and is written up; Stages 2–5 not
  started. `ideas.md`, `environment.md`.
- **Receive rate cap** — `max_receive_hz_per_player` never watched live; needs two clients at
  different caps. (The send side was confirmed on screen 2026-08-15.) `architecture.md` ADR.
- **Client/server safety: scoped into three layers, none built** — core shape caps, adapter range
  checks, deployment fixes. `ideas.md`, "What safe to play with random people means" (2026-08-24).
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
