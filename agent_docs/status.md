# Current status

## Active status

**Phase 9 (Crystal) is the live one as of 2026-08-19.** `phases/phase9.md`, `plans.md` 9.1.

- **Crystal renders peers in TWO tiers now**: spawned real objects up to what the game can draw,
  and everything past that PAINTED over the emulator. A character on every visible tile at 60fps,
  user-confirmed. `verified.md` 2026-08-19, `crowd-limits.md`.
- **Emerald's equivalent is built but ships OFF** (`MESHGHOST_EMERALD_DRAWN_OVERFLOW`) — its UI
  regions could not be located reliably, so a drawn ghost would paint over text boxes.
- Phases 6 (TEVI), 7 (Pseudoregalia) and 8 (Emerald) are done; 8's queue is in `unverified.md`.

**Everything below this line is an INDEX of what is open.** Two lines per item, and the detail
lives in `verified.md`, `pitfalls.md` or a phase file — see the update guidance at the bottom.

Roadmap: `plans.md`. Per-phase log: `phases/`. Evidence: `verified.md`. What the user has not
confirmed yet: `unverified.md`.

## Picking this up in a new session — written 2026-08-19, and the first thing to read

**The opening move, in order.** Four emulators are running and nobody owns them; a session that
starts working without doing this will drive an instance another agent is also driving.

1. **Find the four instances** and match each to its ROM:
   `Get-CimInstance Win32_Process -Filter "Name='EmuHawk.exe'" | ForEach-Object { $_.ProcessId; $_.CommandLine }`
   — the `--lua=` argument names the loader control file, which is what identifies it.
2. **Keep ONE instance for yourself** — vanilla Crystal is the natural choice, it is the adapter
   with the most recent unconfirmed work — and **spawn one agent per remaining instance** (three).
   That is the standing rule, not a suggestion: `environment.md`, "One agent per BizHawk INSTANCE".
3. **Hand each agent four things**, or it cannot stay in its lane: its emulator's **pid**, its
   **loader control file**, its **bridge port**, and the **off-limits list** of every other pid,
   port and control file — plus "kill only by PID, never by name or wildcard".
4. **Start with the two measurements that are one step from landing** (below). Both unblock a
   patched-ROM build that currently refuses to run or falls back to an older render path.
5. **Take screenshots into `dev-scripts/shots/<game>/`** and look before acting — three of four
   games produced no pictures at all last session, which left nobody able to see what they did.



**Four BizHawk instances were left RUNNING when the session that built all this ended.** The
emulators survive; the agents driving them do not. Each needs a new owner (one agent per instance
— `environment.md`), and each was mid-task:

| ROM | Bridge port | Loader control file | Where it got to |
|---|---|---|---|
| Vanilla Crystal | 7781 | `bizhawk-dev-loader-crystal.target` | Soak run, invariant watcher clean, ~44 synthetic peers drawn |
| Vanilla Emerald | 7778 | `bizhawk-dev-loader-emerald.target` | Proving its drawn tier's panel clipping by counting skipped runs |
| **Archipelago Crystal** | 7783 | `bizhawk-dev-loader-apcrystal.target` | **Errand done; the rival battle in Cherrygrove is the trainer battle that settles `W_BATTLEMODE`** |
| **Archipelago Emerald** | 7784 | `bizhawk-dev-loader-apemerald.target` | **`gSprites` measured three times independently as `0x02020630` — i.e. NOT shifted from vanilla — pending confirmation that the spawn path actually engages** |

(pids change; find them with `Get-CimInstance Win32_Process -Filter "Name='EmuHawk.exe'"` and match
on the `--lua=` control file. A relay is on 7777 with `-max-clients=250`.)

**All four were deliberately PAUSED before the session ended**, so nothing is mid-action:

- **Every loader control file was reduced to the adapter alone** — no driver scripts, no probes,
  no input. Add scripts back to a control file to resume that instance (remember: the loader
  reloads when the SET OF PATHS changes, so re-adding a path is what triggers it).
- **All synthetic peers were stopped.** Relaunch a screen-filling crowd with
  `scratchpad/grid3.ps1 -px <x> -py <y>` (one peer per visible tile, positioned round the player)
  or a smaller set with `meshghost-fakeadapter.exe` directly — see `crowd-limits.md` for the flags.
- **The emulators, their cores and the relay are still running**, so an instance is one control
  file edit away from working again. Nothing needs relaunching unless a window has been closed.
- **No agent is running.** Every one was stopped explicitly; their work is committed, including
  two agents' in-flight Emerald changes saved as an explicit WIP commit.

**Two Archipelago measurements are one step from landing**, and both are worth finishing before
anything new: Crystal needs a trainer battle fought on the way back to Cherrygrove, and Emerald
needs a peer spawned to prove the render path switches. Neither address is written into an
`ADDRESSES` table yet — deliberately, since neither is confirmed.

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

- **Ghost collision: keeping it ON, still WIP.** Enemies can no longer hit the ghost (confirmed
  2026-08-17); the player still can. `risks.md`, `verified.md`.
- **Killing a ghost leaves the player respawning at 0/empty health** — player melee only; the HUD
  is fine, the value isn't. Suspect shared health state. `verified.md` 2026-08-17.
- **Ghost vanishes while a peer is on a pole**, then returns stuck in a climb pose. Cause unknown,
  two suspects ruled out; `phase7.md`. (Pole *rotation* was the separate item, cleared 2026-08-16.)
- **A thrown sword near a save crystal.** Suspected a loopback-offset artifact rather than a real
  bug; a two-machine session settles it. `verified.md`.

### Open, not blocked

- **Crystal's drawn tier is unconfirmed**: animation, facing and text-box clipping all landed
  2026-08-19 after the fill-the-screen test. `unverified.md`, `crowd-limits.md`.
- **Crystal/Emerald: ghost animation completeness** — surf/bike ride on the sprite id already sent;
  fishing, bump, spin, emote and Fly need `OBJECT_ACTION`/`OBJECT_FACING`. `phases/phase9.md`.
- **Crystal: a peer's own sprite is used when its tiles are resident, not otherwise** — but the
  DRAWN tier could read any sprite from ROM, which would close it. `phases/phase9.md`.
- **Crystal/Archipelago: the address table is COMPLETE** — `wBattleMode` = `0x1234`, measured
  2026-08-19 in the rival battle; the adapter no longer refuses on that ROM. Needs a live look.
- **Crystal: a ghost does NOT survive a battle** — answered from the code 2026-08-19 and fixed
  (it used to hijack an NPC); a real battle still needs watching. `phase9.md`, `unverified.md`.
- **The core dropped its relay connection twice on quic** — `use of closed network connection`,
  ~40s apart, reconnecting each time; moving to tcp stopped it. Go side. `verified.md` 2026-08-18.
- **Duplicate ghost spawn on every level load** — two ghosts per peer, the `remotes` entry going
  present -> absent within three ticks, leaving an orphaned pawn nobody tracks. `verified.md`.
- **Two different games at once: half fixed** — the user-visible symptom of the bridge-shape gap
  below. Pseudoregalia's port walk is built but **not yet watched live**. `ideas.md`.
- **TEVI's FullMap marker goes stale** — it only refreshes on a `render_remote`, so a peer who
  stops sending leaves a marker frozen where it was. Shipped bug, not hypothetical. `ideas.md`.
- **TEVI lags the template's bridge shape** — handles `bridge_ready`/`reject` and autostarts a
  core (both 2026-08-18, both confirmed live); the PORT WALK is the remaining gap.
  `_template/PROTOCOL.md`.
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
