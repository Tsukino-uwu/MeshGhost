# Current status

<!-- line-cap: none -- capped PER ITEM instead (two lines each) -- a flat cap was tried here and failed. Why: agent_docs/claude-md-cap.md. -->

## Active status

**Active phase: 9 — Crystal.** Emerald is PARKED, feature complete as of 2026-08-21 on the user's
call (*"i consider the game to be fully synced up animation and effect wise now"*), handed off the
same day: *"i will move on to crystal and not work more on emerald right now."* `verified.md`.

- **Emerald work is not scheduled.** A new animation/effect item for it needs a reason it is not
  polish or a custom feature; a real fault is a defect against a finished adapter. `phase8.md`.
- **Crystal is where the gap is.** Both tiers were confirmed good at the dev rig's own settings
  2026-08-22/23; most of what is open below is a fix built since and never watched. `verified.md`.
- **Rig SHUT DOWN.** It DID run 2026-08-25 for the four-adapter smoke test (`verified.md`), on ROM
  **V1.0**. Rebuild with `run-relay-loopback-shipped.bat` + `run-core-crystal-shipped.bat`.
- **NEXT SESSION STARTS HERE: Crystal's six animation classes still need ONE live run** — never
  seen on screen. What to watch: `crystal/UNVERIFIED.md`. The movement work below landed first.
- **Savestate slots on that rig:** 1 the user's, 7 their Route 39 spot, 8 `goto_map`'s undo, **9 the
  9x9 square start**. The mechanism, and the savestate-is-not-a-save trap: `environment.md`.

## Genuinely open items

- **60 commits are UNPUSHED as of 2026-08-25, eight of them `.go`** — so CI has seen none of it,
  including the bridge-bind guard. Last run 2026-08-23, green. `gh run list` once pushed; the user pushes.
- **One doc item left open on purpose** — incident narrative still inside several ADRs and one
  `risks.md` bullet. (`status.md`'s own length was the other; drained 2026-08-25.) `doc-history.md` §5.
- **Four refactors deferred by the 2026-08-18 audit** — `game_thread_tick()`, the two Lua adapters'
  duplication, Crystal's probe boilerplate, TEVI's send gate. (`internal/cfg` shipped.) `ideas.md`.
- **The append-only ledgers are indexed, not split** — every entry is dated 2026-08, so the period
  axis does not exist yet; all five carry an index and a check. `doc-history.md`, "The third pass".
- **Both Lua adapters are near the 200-local wall** — Emerald 197, Crystal 188, re-measured with
  `luac` 2026-08-25 (not grepped). The modules fix is designed, not started. `emulator/CLAUDE.md`.

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
- **Emerald's real-panel clip count was REACHED, not played to** — the position was written, so it
  says nothing about whether ordinary play produces that overlap. `verified.md` 2026-08-19.
- **18 Emerald probes and dev-scripts were rewritten to resolve their own directory (2026-08-25)** —
  they PARSE (preflight runs `luac -p` on all of them); none has been RUN in a game. `pitfalls.md`.
- **Crystal's loopback ghost moved to Emerald's 2-tile side offset (2026-08-25)** — user's request;
  parses, never watched, and the gate to `-ghost` ids is the part to check. `crystal/UNVERIFIED.md`.
- **Crystal's promotion seam and drawn stop were rebuilt 2026-08-25** — three layers plus the stop
  freeze, all traced clean, user's read is hedged. `crystal/UNVERIFIED.md`.
- **The drawn tier's beat is smoother than the engine's, and stays that way for now** — user's call;
  the retiring mechanism is written down. `crystal/BANDAGES.md` #2.
- **Crystal's crowd cost is measured on Route 39, and the numbers are a FLOOR** — the rig cannot
  cycle `prog`, so no run exercised the drawn tier's stepping path. `crowd-limits.md` 2026-08-25.

**Crystal's open work is grouped, not listed one fix per line** (2026-08-25). Sixteen entries here
were each a two-line restatement of a heading in `crystal/UNVERIFIED.md`, which is a 1,186-line
queue carrying the detail, what to watch, and what correct looks like. An index of an index goes
stale in two places at once; these six say which SUBSYSTEM is unsettled and send you there.

- **Crystal, drawn tier — unwatched since 2026-08-23.** Three jitter bugs, text-box clipping, the
  two-panel phone call, inline `hSCX`/`hSCY`, and bike/surf/ledges/warps. `crystal/UNVERIFIED.md`.
- **Crystal, spawned tier — six fixes built, none watched.** Promotion, whole-tile drift, step
  trigger, shoving, the trainer-clone hang, battle survival. `crystal/UNVERIFIED.md`.
- **Crystal: the 2026-08-25 evening ran ELEVEN fixes** — surf art (confirmed), bike gait, stop
  drift, step chaining, stride band, pedal cadence, path retrace, tier sync, probe gating — and
  ended smooth on screen at 60fps; per-fix confirmations still pending. `crystal/UNVERIFIED.md`.
- **Crystal: in-place animations are BUILT and UNWATCHED (2026-08-25)** — one rule replaced the bump
  special case: read the peer's facing byte. **This is what the next live run is for.** `crystal/UNVERIFIED.md`.
- **Crystal's drawn tier has no visual parity yet** — no reflection, wake, grass or cave clip, and a
  peer's own sprite only when its tiles are resident. (Emerald's closed 2026-08-21.) `phases/phase9.md`.
- **Crystal's hardware (OAM) tier: built, reaches the screen, shipped OFF, never judged on screen.**
  Adds 0-1 characters and does NOT get free occlusion. `FLAGS.md`, `crystal/UNVERIFIED.md`.
- **Crystal, known gaps rather than faults** — no fall for Fly/Teleport/Dig, no emote object, the
  transition hold fires late, and a vanilla crowd battle was never reached. `phases/phase9.md`.
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

`unverified.md` (**index to the per-game queues — what the user has not confirmed yet**) ·
`plans.md` (roadmap) · `phases/phase6.md`|`phase7.md`|`phase8.md`|`phase9.md` (per-phase log) · `risks.md`
(assumptions) · `verified.md` (Go-side and cross-game confirmed facts, plus the index to each
adapter's own `VERIFIED.md`) · `pitfalls.md` (symptom → cause → fix, and the
diagnostic methodology rules).

## Update guidance

**The rule lives in `CLAUDE.md`, which is always loaded** — an index of what is open, not a record;
two lines per item, maximum; delete an item the moment it is fixed and confirmed; overwrite in
place when the phase changes rather than appending. **Why it is per-item and not a flat line cap
(this file reached 628 lines with a flat cap nominally in force):**
[claude-md-cap.md](claude-md-cap.md).

Stated once, here as a pointer, because a rule with three homes drifts — and this one had them.
