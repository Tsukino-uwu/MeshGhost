# Current status

## Active status

**Phase 8.1's three-tier ladder (`spawn -> OAM -> drawn`) is built; 2026-08-21's later session took
it onto the WATER and through a CAVE, and found that most of what a character does in either place
had never reached the two tiers that draw for themselves.** Eight fixes, seven user-confirmed on
screen. Full record and every measurement: `verified.md` and `pitfalls.md` for that date; the game
facts behind them are in the adapter's `documentation.md`.

- **Confirmed this session:** the cave fade (a cave mouth fades to WHITE, invisible to a
  downward-only brightness ratio); the OAM tier's surf blob and reflection; reflections for any
  ghost on reflective ground rather than only while surfing; the water ripple trail; the OAM
  comparison position; a ghost spawning in its idle pose; and the reflection's row and width.
- **NOT confirmed, and first on the list:** **frame rate.** The session added per-frame work to both
  self-drawn tiers and never re-measured. `probes/fpshold.lua` against a bare control, before
  anything else. `unverified.md` has the full not-confirmed list.
- **The unpinned jump arc is built and unwatched** — both self-drawn tiers used to draw a peer
  SLIDING over a ledge, and compare mode structurally cannot show it, because it pins. Judging it
  needs compare mode OFF. `unverified.md`.
- **Diving was never reached.** The user was taken to Route 126 and asked to be put back; nothing
  underwater has been seen. Underwater is a different mechanism from surfing. `unverified.md`.
- **ASK BEFORE WARPING THE PLAYER.** Standing rule from this session, and it is about their session,
  not about cheating (which is permitted): *"always ask before you teleport"*. `probes/goto_map.lua`
  checkpoints to savestate slot 8 first, so slot 8 is the undo.
- **The two method lessons that cost the most, both in `pitfalls.md`:** never judge a tier against
  another tier you have not verified — a long hunt compared the painted ghost against a spawned one
  that was itself in the wrong pose — and measure a target's BEHAVIOUR across several frames before
  changing how you draw it, not just its position in one.
- **The ACRO BIKE IS DONE**, and Phases 6 (TEVI) and 7 (Pseudoregalia) are done. Crystal has none of
  the hardware-tier work and none of this session's.
- **Frame rate is a SHIPPING requirement and nothing may pass that breaks it** — user, 2026-08-21:
  *"there can't be any fps drops like this in a shipped/release"*. Measure against a bare control.

## Picking this up in a new session — rewritten 2026-08-21 (second session that day)

**Nothing of mine is running.** The relay and the core were shut down and verified gone, and the
listening ports were checked empty. **The EMULATOR is still up** — one vanilla Emerald instance in
Sootopolis City (`g0.n7`), with the dev loader attached but **detached from every target**
(`bizhawk-dev-loader-emerald.target` reads `none`).

**That detach is deliberate, and worth knowing before wondering where the core went:** killing the
core alone is not enough, because a live adapter AUTOSTARTS a default-flags one within seconds and
it takes the bridge port. Drop the adapter first, then the core, then check the ports.

To bring the rig back, from the repo root, hidden (`environment.md`):

```
meshghost-relay.exe -loopback -max-clients=200 -send-hz=100 -ghost-collision=disabled
meshghost.exe -game=emerald -bridge=127.0.0.1:7778 -name=player1 -interp=0ms -min-send=10ms -transport=tcp
```

`-max-clients` DEFAULTS TO 8 and silently refuses everyone past it. Rebuild the binaries with
`-o` first: `go build` does not refresh the named `.exe` files the `.bat` launchers run.

**The loader's control file is `dev-scripts/bizhawk-dev-loader-emerald.target`** (gitignored, one
absolute path per line, loaded in order). **The flags file it names lives in the SESSION scratchpad,
so a new session must write its own before the adapter line** — the loader shares one Lua
environment, so an unset global keeps whatever the last session left there. Set EVERY dev flag
explicitly, `false` included. The standing dev default is in `FLAGS.md`; the compare layout is now
OAM, drawn, player, spawned, left to right, all in one row.

**Useful things this session left behind:**

- `probes/cavewarp_probe.lua` and `probes/ripple_probe.lua` — new, and both write timestamped logs
  beside themselves. `probes/README.md` says what each is for.
- **`grant_test_kit.lua` belongs in the loader set whenever the player is being driven** — it tops
  Repel up every half second, and without it a scripted ten-second surf walked into a wild battle
  and the measurement captured the battle transition instead.
- **A screenshot cannot see the drawn tier** (it is a Lua overlay painted after the frame) but CAN
  see the OAM tier, because that one is real hardware sprites. **Diffing two screenshots — one with
  the adapter loaded, one with it dropped — isolates exactly what our ghosts contribute**, and
  reading the PNG host-side with a few lines of Python gives per-pixel answers the emulator's Lua
  API does not expose (`emu.getscreenpixel` does not exist on this build).
- **The OAM buffer is directly comparable to the engine's own**: entries 0..63 are the game's,
  64..127 are ours, and "is our sprite the same as the engine's?" is a field-by-field read rather
  than a question for the user.

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
- **Drawn-tier visual parity: Emerald is close, not done.** 2026-08-21 found reflections gated to
  surfing, no wake, and a one-row flip error. Crystal's tier still has none of any of it.
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
- **Emerald: the Acro Bike's wheelie POSE is not reproduced** — those actions never report
  finished for a ghost and strand it; the watchdog frees it. `unverified.md`.
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
