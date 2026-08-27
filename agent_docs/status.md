# Current status

<!-- line-cap: none -- capped PER ITEM instead (two lines each) -- a flat cap was tried here and failed. Why: agent_docs/claude-md-cap.md. -->

## Active status

**Active phase: 9 — Crystal, with Emerald reopened for two states.** Feature complete 2026-08-21,
*"i consider the game to be fully synced up animation and effect wise now"* — but the boat and Fly
were the two never tested. Fly is now built, bandaged and partly confirmed; the boat is built and
has never been looked at. `verified.md`.

- **Emerald Fly is BANDAGED, not finished** (2026-08-26, user: *"good nuff for now"* but *"not
  properly working fully yet"*). Four compensations named: `emerald/BANDAGES.md` §4.
- **Fly's confirmed scope is ONE case** — a same-town fly watched from a second instance; both
  self-drawn tiers and the cross-town case are not. `emerald/VERIFIED.md`, `UNVERIFIED.md`.
- **The Emerald BOAT is built and has NEVER been watched.** Nothing on 2026-08-26 touched it;
  rails are not built for either. `emerald/UNVERIFIED.md`.
- **Nothing is running** (verified gone end of 2026-08-26: both EmuHawk instances, both cores
  and the relay stopped, both loader targets set to `none`). The Emerald rig was relay
  (loopback, `-send-hz=100`, `-ghost-collision=disabled`) + two cores (7778 and 7779) + two
  BizHawk instances on VANILLA Emerald: instance 1 the FLYER with the dev loader, compare tiers
  and the OAM tier, instance 2 the WATCHER with the dev loader but SHIPPED rendering, so what it
  shows is what a real player sees. **A dev loader on the watcher changes nothing visual** — it
  only lets a probe be swapped without relaunching, which is what made the second half
  measurable. `emerald/probes/fly_probe.lua` runs on both (`MESHGHOST_FLY_OBSERVE` on the
  watcher). Emerald savestates, the user's: **flyer 5 same-town, 6 different-town; watcher 3 and
  4 for the two towns** — pair them so the watcher is where the flyer LANDS, or a run comes back
  clean with the bug still in it (it did, twice). **`run-relay-loopback.bat` has no
  `cd /d "%~dp0"`** — launch with the working directory set, or the exe directly.
- **Two Go-side fixes are UNWATCHED** (2026-08-26): the adapter no longer throws on a map change
  (it was crashing and the dev loader was unloading it — `attempt to index a nil value (local 'g')`
  in the loader log), and `applyPeerAction` no longer races the engine on the action byte.
  `crystal/UNVERIFIED.md`.
- **NEXT SESSION STARTS HERE: hop a ledge and THEN cast a rod, in one session** — the jump shadow
  and the fishing rod share vtile `$fc` and have never been on screen together. `crystal/UNVERIFIED.md`.
- **A savestate load crashed the adapter; fixed, trigger not reproduced** — load the savestate that
  originally broke it. Second door into a dereference closed the same day. `crystal/UNVERIFIED.md`.
- **Teleport is the LAST action class: not built, not measured, not watched.** Unlike Dig it is
  mostly `yoff`, and whether the player's object carries it is the Fly question. `crystal/UNVERIFIED.md`.
- **DRIVE IT YOURSELF.** The user's savestates make a Fly self-testable: slot 8 same-town, slot 9
  cross-town, both "press A to fly", driven by `crystal/probes/fly_drive.lua`. Ask for an
  equivalent state before grinding live cycles at any other expensive-to-reach case — it is what
  ended the 2026-08-26 deadlock (`_template/probes.md`).
- **Savestate slots on that rig:** 1 the user's, **7 FISHING (rod on SELECT)**, **8 SAME-TOWN fly**,
  **9 REUSED TWICE ON 2026-08-26 — now a LEDGE HOP (walk down one tile); it was the cross-town fly,
  then an Escape Rope**, **10 one tile below a WHIRLPOOL (hold Up to re-enter)**, **3 the
  wrong-trainer route**. **A log from a savestate-driving probe only means anything against the slot
  as it was that hour** — check before trusting an old one. **And a savestate BAKES IN any ghost
  that was on screen when it was made**, so a driven run showing one character too many is the
  state's fault, not the adapter's; `orphan_sweep.lua` or any door clears it. `crystal/UNVERIFIED.md`. `goto_map`'s undo slot is now overridable (`MESHGHOST_GOTO_UNDO_SLOT`) because its
  hardcoded 8 would eat the fly state. The savestate-is-not-a-save trap: `environment.md`.
  **`MESHGHOST_SQUARE_LOAD_STATE` loads a slot on EVERY re-attach of `square_drive` — clear it.**

## Genuinely open items

- **Crystal is THREE names from Lua's 200-local ceiling and Emerald is TWO** (re-measured
  2026-08-26; Crystal's entry said 188 and was already stale when it broke the build). `emulator/CLAUDE.md`.
- **NOTHING SINCE 2026-08-25 IS PUSHED, AND CI HAS NEVER SEEN IT** — 51 commits ahead of
  `origin/master` on 2026-08-27, one of them `.go` (`protocol/limits.go`). `gh run list` at session start.
- **One doc item left open on purpose** — incident narrative still inside several ADRs and one
  `risks.md` bullet. (`status.md`'s own length was the other; drained 2026-08-25.) `doc-history.md` §5.
- **Four refactors deferred by the 2026-08-18 audit** — `game_thread_tick()`, the two Lua adapters'
  duplication, Crystal's probe boilerplate, TEVI's send gate. (`internal/cfg` shipped.) `ideas.md`.
- **The append-only ledgers are indexed, not split** — every entry is dated 2026-08, so the period
  axis does not exist yet; all five carry an index and a check. `doc-history.md`, "The third pass".

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
  the retiring mechanism is written down. `crystal/BANDAGES.md` #3 (renumbered 2026-08-27).
- **Crystal's crowd cost is measured on Route 39, and the numbers are a FLOOR** — the rig cannot
  cycle `prog`, so no run exercised the drawn tier's stepping path. `crowd-limits.md` 2026-08-25.

**Crystal's open work is grouped, not listed one fix per line** (2026-08-25). Sixteen entries here
were each a two-line restatement of a heading in `crystal/UNVERIFIED.md`, a 55-entry queue carrying
the detail, what to watch, and what correct looks like. An index of an index goes stale in two
places at once — and this paragraph proved it on itself, having said "these six" over a list of
fifteen and called that queue 1,186 lines when it was 2,426 (both corrected 2026-08-27). The group
below says which SUBSYSTEM is unsettled and sends you there; it is deliberately not counted here.

- **The Archipelago camera was two DEAD BYTES** — `$FFCF`/`$FFD0` never change there; it is
  `$FFC7`/`$FFC8`, measured. `crystal/FLAGS.md`.
- **That build has a FOURTH gait (8px/tick) and repoints 5 of 102 sprite ids** — so sprite ids,
  item ids and gaits all fail to cross builds. `crystal/UNVERIFIED.md`.
- **Turbo bike is fixed and confirmed; RUNNING is untested and its gait UNMEASURED** — do not
  assume one. Surf is unreached on that build. `crystal/UNVERIFIED.md`.
- **`0x1A17` was REFUTED as that build's `wPlayerState`** — fit two states, failed the third; the
  second address here to do that. `crystal/UNVERIFIED.md`.
- **Three instruments filtered before printing and each gave a confident wrong answer** — the
  session's most expensive lesson, four cases dated. `pitfalls.md`.
- **Crystal, drawn tier — unwatched since 2026-08-23.** Three jitter bugs, text-box clipping, the
  two-panel phone call, inline `hSCX`/`hSCY`, and bike/surf/ledges/warps. `crystal/UNVERIFIED.md`.
- **Crystal, spawned tier — six fixes built, none watched.** Promotion, whole-tile drift, step
  trigger, shoving, the trainer-clone hang, battle survival. `crystal/UNVERIFIED.md`.
- **Crystal's remaining action class is Teleport alone** — not built, not measured, not watched.
  Spin, ice, fishing, Fly and Dig/Escape Rope are all confirmed. `crystal/VERIFIED.md`.
- **Fly is unwatched for a REMOTE peer** — every 2026-08-26 confirmation was loopback, where the
  peer's fly is also the watcher's. Needs two machines. `crystal/VERIFIED.md`.
- **Crystal: in-place animations are BUILT and UNWATCHED (2026-08-25)** — one rule replaced the bump
  special case: read the peer's facing byte. **This is what the next live run is for.** `crystal/UNVERIFIED.md`.
- **Crystal's drawn tier has no visual parity yet** — no reflection, wake, grass or cave clip, and a
  peer's own sprite only when its tiles are resident. (Emerald's closed 2026-08-21.) `phases/phase9.md`.
- **Crystal's hardware (OAM) tier: built, reaches the screen, shipped OFF, never judged on screen.**
  Adds 0-1 characters and does NOT get free occlusion. `FLAGS.md`, `crystal/UNVERIFIED.md`.
- **Crystal, known gaps rather than faults** — the transition hold fires late, and a vanilla crowd
  battle was never reached. (The Fly/Dig fall and the emote were closed 2026-08-26, unwatched.)
  `phases/phase9.md`.
- **The core dropped its relay connection twice on quic** — `use of closed network connection`,
  ~40s apart; moving to tcp stopped it. Go side. `verified.md` 2026-08-18.
- **Duplicate ghost spawn on every level load** — two ghosts per peer, the `remotes` entry going
  present -> absent within three ticks, leaving an orphaned pawn nobody tracks. `verified.md`.
- **Two different games at once: half fixed** — the user-visible symptom of the bridge-shape gap
  below. Pseudoregalia's port walk is built but **not yet watched live**. `ideas.md`.
- **TEVI's FullMap marker goes stale** — it only refreshes on a `render_remote`, so a peer who
  stops sending leaves a marker frozen where it was. Shipped bug; a probe now exists to measure the
  age, and has never been run. `tevi/UNVERIFIED.md`, `tevi/PROBES.md`.
- **TEVI's bridge shape is COMPLETE and UNWATCHED (2026-08-27)** — send gate and 8-port walk built,
  DLL rebuilt and deployed, never run in the game. `tevi/UNVERIFIED.md`.
- **Pseudoregalia: a hard crash mid-session after the pause menu opened twice** — not root-caused,
  not attributable to MeshGhost on the evidence. `verified.md` 2026-08-17.
- **Pseudoregalia: a `Fatal Error!` on game exit**, seen once, never root-caused. Not the
  2026-08-16 transition crash, which is fixed.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, effects don't.
  `tevi/UNVERIFIED.md`, `phase6.md` (2026-08-15).
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
