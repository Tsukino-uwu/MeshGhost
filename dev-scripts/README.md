# Dev scripts

<!-- line-cap: none -- written for people, not for an agent's instruction budget. Why: agent_docs/claude-md-cap.md. -->

Developer/testing launchers used while building MeshGhost itself — not what an end user
wanting to play needs. If you just want to play with friends, use the pre-built release
instead: see [packaging/README.md](../packaging/README.md) and the repo's Releases page.

These assume `meshghost.exe`, `meshghost-relay.exe`, `meshghost-fakeadapter.exe`, and
`meshghost-netsim.exe` are built at the repo root (e.g. `go build -o meshghost.exe ./cmd/meshghost`, run from the repo
root) — each script reaches them one level up, as `..\<name>.exe` or, where the script has to
work from any working directory, `"%~dp0..\<name>.exe"`. The one exception is
`run-loopback-in-release-folder.bat` below, which is written to be copied *out* of here into a
downloaded release folder and run against its `meshghost-server.exe` instead.

**`meshghost-relay.exe` and `meshghost-server.exe` are the same program under two names** — the
local build name and the released one. Everything in this folder uses the first; a release, and
anything describing one, uses the second. [packaging/README.md](../packaging/README.md) has the
full note.

- `run-gotests.bat` — **the one command to run before calling any change to the Go client/server or
  `cmd/` done**: `go build`, `go vet`, then the whole suite twice. Needs no game, no emulator,
  and nobody watching — `internal/e2e` builds and launches the real `meshghost-server.exe` and
  `meshghost.exe` and drives a real adapter over the bridge, which is what pairing
  `run-relay-loopback.bat` with a `run-core-*.bat` used to check by hand.

  It does **not** run the race detector or the fuzzers. Race is now a separate local script (below,
  working since 2026-08-18); **fuzzing is still CI-only** (`.github/workflows/ci.yml`, a short
  campaign per push against the parsers), so a green run here is still not a green CI run.
  (`go.mod` requires Go 1.25.0, the installed toolchain is 1.26.5, and CI's `setup-go` pins 1.25 to
  match — it pinned 1.22 until 2026-08-17, which worked only because `GOTOOLCHAIN=auto` upgraded it
  silently.)
- `run-gotests-race.bat` — the race detector, the exact `go test -race -count=3 ./...` CI runs, and
  **it works on this machine as of 2026-08-18**. Run it whenever you touch concurrency; the whole
  suite is clean under it. It **probes for a C compiler Go can actually use** rather than assuming
  one, and the fix that made it work is worth knowing: setting `CC` is not enough — the compiler's
  own bin directory has to go on `PATH` ahead of the devkitPro MSYS2 `gcc`, or `as`/`ld`/its headers
  don't resolve and a perfectly good compiler fails exactly like a broken one. That single missing
  step is why MSYS2's GCC stood recorded as unusable from 2026-08-16. If no candidate passes the
  probe it says what to install (an MSYS2 mingw64 GCC, any mingw-w64 GCC, or a WSL distro), exits 1,
  and is explicit that this is a real gap rather than a pass.
- `run-gotests-stress.bat` — a different axis, not a race substitute: `-count=10 -shuffle=on
  -cpu=1,4` over the concurrency packages. Repeats, randomised order, and two different GOMAXPROCS
  values, each of which changes interleavings. ~3-4 minutes. `internal/e2e` is excluded on purpose
  (it launches real binaries per test and blew past `go test`'s 10-minute limit when included).
  **Never report it as standing in for `-race`** — CI caught a real relay race on 2026-08-16 that
  300 local runs of the same test never reproduced. Now that `-race` runs locally, run that first.
- `preflight.ps1` — read-only pre-live-test check: gofmt, the leak grep (both slash directions),
  CLAUDE.md's cap, root binaries vs source, both mod DLLs vs their `built-from.txt`, CRLF in
  LF-pinned sources, GitHub Action versions agreeing across workflows, leftover MeshGhost
  processes, and optionally the deployed DLLs in the live
  game installs (`MESHGHOST_TEVI_DLL`, `MESHGHOST_TEVI_DLL_ALT`, `MESHGHOST_PSEUDO_DLL` — env vars
  rather than literals, because install paths are machine-specific and this repo is public). It
  never builds, deploys or commits. Exit 0 = everything fresh, 1 = at least one FAIL; warnings do
  not fail the run. Run it before asking anyone to launch a game. **`-TreeOnly` runs only the
  checks a bare checkout can answer** and skips the rest, which is what
  `.github/workflows/docs.yml` runs on every `.md` push (2026-08-27); a `SKIP` is not a `PASS`, so
  run it without the switch before a live test. See `agent_docs/testing.md`.

  Its runtime counterparts, for a session already running: add `-stats=10s` to any `meshghost.exe`
  launch for a one-line client summary (link rtt, clock offset, peers known versus rendered, bytes
  in/out with an hourly rate, and the share of remote states thrown away as cross-area), and
  `-introspect` on the relay for the server side of the same picture. Both are off by default.
- `run-relay.bat` / `run-relay-loopback.bat` — a single relay, `-send-hz=100`. Deliberately NOT
  the relay's own 20Hz default: since the send/receive rate-control feature (see the ADR in
  agent_docs/architecture.md), a relay's advertised send_hz is prescriptive — a Core adopts it
  unless it has its own slower explicit `-min-send`, and the SLOWER of the two always wins. Left
  at 20Hz, this relay would silently override every `run-core-*.bat` script's own fast
  `-min-send` (below) back down to 50ms. 100Hz keeps this relay out of the way entirely, so
  each core's own `-min-send` is what actually governs local test timing, same as before this
  feature existed.
- `run-core.bat <game> [transport] [instance]` — **the dev core launcher for every game.**
  `game` is `emerald`/`crystal`/`tevi`/`pseudoregalia`; `transport` is `auto` (default),
  `tcp`, `udp` or `quic`; `instance` is `1` (default) or `2`. Instance 2 is the second client
  on one machine — bridge port 7779 and `-name=player2` instead of 7778/`player1` — which is
  what real two-player testing needs (see
  [agent_docs/phases/phase4.md](../agent_docs/phases/phase4.md)). With `instance` left at 1 it
  is also the solo/self-test core: pair it with `run-relay-loopback.bat` below instead of
  `run-relay.bat` to see your own ghost with only one game instance running.

  Always `-interp=0ms -min-send=10ms` (changed 2026-08-14, was `200ms`) — as close to
  instant/unsmoothed as the relay's per-client flood cap allows (paired with `-send-hz=100`
  above), since local dev testing has no real network jitter to smooth over and artificial
  delay only makes it harder to tell whether a remote ghost's animation genuinely matches the
  real player frame-for-frame. **Two exceptions keep their own files**, because the filename is
  what records which rig produced a reading: `run-core-emerald-trail.bat` (a real
  `-interp=200ms`, for the loopback-trail launcher) and `run-core-crystal-shipped.bat` (shipped
  250ms, judging what a real player receives).

  **Replaces nine near-identical scripts, collapsed 2026-08-25** — `run-core-emerald.bat`,
  `run-core-emerald2.bat`, `run-core-crystal.bat`, `run-core-tevi.bat`, `run-core-tevi2.bat`,
  `run-core-pseudoregalia.bat` and its `-tcp`/`-udp`/`-quic` trio. The transport trio differed
  from each other by exactly four lines, three of them comments. **A phase file or a `VERIFIED.md`
  entry naming one of the old scripts is a dated record and is left as written** — it says what
  genuinely ran that day; read `run-core-<game>.bat` as `run-core.bat <game>`, `…2.bat` as
  `… 2`, and `…-quic.bat` as `… quic`.
- `run-bizhawk-emerald.local.bat` / `run-bizhawk-emerald2.local.bat` — **not tracked** (see
  `.gitignore`; EmuHawk/ROM paths are personal and this repo is public). Per-machine BizHawk
  launchers, real paths from `agent_docs/environment.md`, pairing with the two cores above
  (instance 2 sets `MESHGHOST_BRIDGE_PORT=7779` before launch — the Lua adapter reads it,
  defaulting to 7778 to match instance 1). Exist specifically because launching EmuHawk
  directly (double-click, no env var) silently defaults both instances to the same bridge
  port with no error — found live 2026-08-14, cost a full debugging session to diagnose (see
  `agent_docs/phases/phase8.md`'s "Real non-loopback two-peer test" entry). Recreate these two
  files
  yourself (they're gitignored, not shipped) if starting fresh on a new machine — see
  `agent_docs/environment.md` for the real `EmuHawk.exe`/ROM paths to put in them.

  **Before diagnosing any two-instance local test** (Emerald, TEVI, or Pseudoregalia), confirm
  each process actually logged a distinct bridge port — launch every second instance through
  its `.local.bat`/`run-core-*2.bat` pair, never by double-clicking the game exe directly.
  Found live 2026-08-14: both instances silently shared one bridge port with no error, and a
  long pipeline trace confirmed the code was fine the whole time — the test setup was the bug.
  See `agent_docs/pitfalls.md`'s "Running two instances of the same emulator/game silently
  collide on a shared default port" entry.
- `run-bizhawk-emerald-loopback-trail.local.bat` — **not tracked**, same shape as
  `run-bizhawk-emerald.local.bat` above but also sets `MESHGHOST_LOOPBACK_TRAIL=1`. Pair with
  `run-relay-loopback.bat` below AND `run-core-emerald-trail.bat` specifically, not the plain
  `run-core.bat emerald` — see that launcher's own entry for why. By default (the plain
  BizHawk launcher above), a loopback session's ghost renders a couple tiles to the side of the
  real player, for visually comparing rendering/animation quality side by side without the two
  overlapping — found live 2026-08-14 that an exact overlap made this hard to judge. This
  variant forces the ghost back to sitting exactly on your real position instead, for the other
  real use case: verifying the ghost actually tracks position precisely, which the offset would
  obscure. Same create-it-yourself note as the plain launcher above; see
  `meshghost_emerald.lua`'s `LOOPBACK_GHOST_OFFSET_TILES_X` comment for the full rationale, and
  the same pattern applies to Pseudoregalia's/TEVI's own loopback-ghost offset if/when they get
  an equivalent launcher.
- **`MESHGHOST_COMPARE_TIERS=1` — the default way to eyeball a BizHawk drawn tier in dev.** Set it
  on the emulator launch (either Pokémon adapter honours it) and the ONE loopback ghost is rendered
  **twice at once from the same peer state**: spawned two tiles to the RIGHT, where the engine
  draws it, and painted two tiles to the LEFT, where our own pixel path does. The two are then in
  the same frame, the same lighting and the same place, which is the only way to see what the
  painted one is *missing* — no engine occlusion, a cave's darkness drawn straight over, a water
  reflection the spawned copy has and it does not, a doorway that swallows one and not the other.
  Comparing across two runs cannot answer that, because the place has changed by the time the other
  renderer is on. Pair with `run-relay-loopback.bat`. It announces itself in the log as
  `PROBE FLAG IN USE`; two ghosts is the flag, not a duplicate-spawn bug. User's request,
  2026-08-19 — see each adapter's `FLAGS.md` row.
- `run-core-emerald-trail.bat` — pairs specifically with
  `run-bizhawk-emerald-loopback-trail.local.bat` above. Unlike the instant-by-default
  `run-core.bat emerald`, this keeps a real `-interp=200ms` (the same value Phase 3 confirmed
  live — see `agent_docs/phases/phase3.md`) because the trail launcher's zero render offset
  means a ghost with no interpolation delay sits exactly on top of you with nothing visible at
  all — the delay is what makes it a visible trailing ghost instead of an invisible overlap.
- `run-fakeadapter1.bat` / `run-fakeadapter2.bat` — two headless `cmd/meshghost-fakeadapter`
  instances (circle-motion fake ghosts, no game) for testing the core/relay without BizHawk at
  all — see [agent_docs/phases/phase5.md](../agent_docs/phases/phase5.md).

  **`-transport tcp|udp|quic|auto`, added 2026-08-16.** Until then the rig never set `Transport`
  at all, so every synthetic peer inherited `netx.Kind`'s tcp zero value and **the load tiers
  below could only ever exercise tcp** — which is why the transports shipped that same day had no
  sustained-load coverage. Pair it with `run-netsim.bat` to load-test udp or quic under real
  packet loss. Confirm which transport was actually used from the client's own
  `core: relay offers ... — using <transport>` line; a preference the relay does not serve
  degrades quietly to tcp.
- `run-loadtest-relay.bat` / `run-loadtest-peers.bat` / `run-ghostload-pseudoregalia.bat` — the
  synthetic-peer load rig, for answering "how many players can this actually hold?". The
  shipped `max_clients` of 8 is a policy default, not a technical limit (see
  `relay/limits.go`), and there are three separate ceilings behind it:

  1. **Relay fan-out**, which grows with the *square* of room size — `Room.Forward` sends every
     state to every other member. Measured on the real structs, one Pseudoregalia state line is
     597 bytes, so a 16-seat room at the default 20Hz is ~2.7 MB/s of relay upload (~9.6 GB an
     hour) against ~175 KB/s down per player; a 32-seat room is ~11.3 MB/s up (~40 GB/hour).
     The host carries the quadratic term, which is why raising the cap is their bandwidth bill.
  2. **Per-client receive**, which grows linearly and won't be what breaks.
  3. **Adapter render cost** — almost certainly the one that actually binds, and the only one
     that can't be measured without a game running.

  `run-loadtest-relay.bat` + `run-loadtest-peers.bat [count]` cover tiers 1–2 headlessly (no
  game at all): N peers in one process, each a real `Core` with its own relay connection. The
  `client0_remotes` line is the rig's self-check — it is a *lower* bound (`>=N-1`), because in
  the tier-3 rig a real game client is in the room too.

  `run-ghostload-pseudoregalia.bat [count]` is tier 3: the same synthetic peers, but wearing a
  real game's `game_id`/`area_id` so **one** running copy of Pseudoregalia renders N ghosts. It
  needs `MG_AREA` and `MG_CENTER` set from a live session first — `area_id` is matched by
  equality in `core`, so a wrong value renders nothing and looks exactly like a broken
  rig rather than a mismatch. Ramp the count and read a real frame-time number (`stat unit`)
  off the game each step; add `-churn-every` to exercise ghost spawn/despawn (a full pawn-clone
  construction each time), which may cost more than steady-state rendering. Note this is a
  *rendering* load test only — synthetic peers say nothing about whether two real game
  instances can run at once, which is Phase 7.7's separate question.

  `meshghost-fakeadapter.exe` knows nothing about any game: the per-game specifics live in
  these launchers and in `loadtest-extras-pseudoregalia.json`, passed via `-extras`.
- `run-controlplane-soak.bat` — **the invariant soak for the planes past cosmetic** (events,
  leases, escrow, world custody). Starts its own relay plus 6 synthetic peers that contend for one
  key, broadcast events, run two-sided exchanges, and drive a shared world through repeated host
  handovers for 60s, while every peer continuously checks that sequencer stamps strictly increase,
  that a key is never held by two clients at once, that every exchange terminates without an abort
  delivering a deposit, and that the world never goes backwards, loses an entity across a handover,
  resurrects a dropped one, or accepts a stale host's write. Exits non-zero if any of that fails,
  so it can go in a script rather than needing someone to watch. It hardcodes
  `-relay=127.0.0.1:7911` and forwards no arguments, so soaking the same thing under loss and
  jitter means editing the script to point `-relay` at a `run-netsim.bat` proxy address rather
  than passing a flag; run the relay with `-introspect` to see what it believed while it ran.

  **Read the summary even on a pass** — a run with 0 claims denied, 0 exchanges committed, or 0
  worlds adopted is a green result that exercised nothing. And know its measured limit: against a deliberately broken
  relay it saw 51,000 events without noticing, where the in-process total-order test caught the
  same defect immediately. It complements `relay`'s tests; it does not replace them. See
  `agent_docs/testing.md`.

### Interp is PAIRED with the loopback offset — pick the matching one

A self-ghost has to be separated from the player somehow, and there are exactly two ways. Use one,
never both, and never neither:

| Loopback mode | Interp | Answers |
|---|---|---|
| Ghost **offset to the side** | **`0ms`** | *Is it 1:1?* — same pose, same timing, right now |
| Ghost **directly on the player** (no offset) | a **deliberate delay** | *Does it follow?* — visible only because it trails |

Every launcher here is the first row (`-interp=0ms`, relay at `-send-hz=100`) except
`run-core-emerald-trail.bat`, which is the second and says so in its own header.

Getting the combination wrong is what ruins a session, and both wrong combinations are silent.
Zero interp with no offset hides the ghost inside the player; **non-zero interp WITH the offset
adds a delay that makes 1:1 impossible to judge** — which is the mistake made 2026-08-17, when
interp was raised to 250ms and then 100ms to make a loopback ghost easier to see. The user spent
several sessions reporting a ghost that "starts to act a tiny bit after the player": a delay
introduced by the launcher, not by the code under test, which sent a whole investigation down a
latency path. Separation is the offset's job (`adapters/pseudoregalia/BANDAGES.md`); interp's job
is the question being asked.

The relay's `-send-hz=100` matters for the same reason: its advertised rate is prescriptive and the
effective rate is the **slower** of it and the client's own `-min-send`, so a relay left at its 20Hz
default silently drags every dev client back down, and a ghost updating at 20Hz cannot be judged
1:1 whatever interp says.

- `run-relay-online.bat` + `run-core-pseudoregalia-online.bat` — **the two-machine pair for the
  capabilities that only mean anything across a real network**: `clock.v1` (room-scoped, so both
  players must run it) and `resume.v1` (client-scoped, so it works even if the other player does
  not). Neither can be tested in loopback — one machine has one clock and no network to blip — and
  neither is visible on its own, so both scripts carry a "what to watch for" list. The relay side
  runs `-introspect`, which is the only way to see that a player is SUSPENDED rather than simply
  frozen. Read the scripts' own headers before the session: they record what resumption does and
  does not cover, measured rather than assumed.
- `run-netsim.bat` — **the adverse-network rig** (`cmd/meshghost-netsim`): a fault-injecting proxy
  between clients and a relay, adding loss, latency, jitter, reordering, duplication and
  partitions. Everything else here runs over a perfect loopback, which is the gap this closes —
  `agent_docs/testing.md` notes that real latency and jitter are untested and that interpolation
  degrades *silently* under clock skew, and the only fault injection that existed before this was
  a package-private drop counter inside `netx/udpconn`'s own tests, which cannot touch a
  running session. That injector is what found the 2026-08-16 lifecycle-ordering bug; this is the
  same idea at session scope.

  It mirrors the relay's **port numbers** on `127.0.0.2`, and that detail is load-bearing rather
  than cosmetic: transport discovery sends the port but deliberately *not* the host
  (`agent_docs/contract.md`), so a client upgrading to udp/quic reuses whatever host it first
  connected to. Same numbers on a second loopback address therefore keeps the whole
  handshake-then-upgrade path inside the proxy — a different port number would silently route the
  upgrade *around* it, and the session would look perfectly healthy while testing nothing.

  Start a relay as usual, run this, then point a client at `127.0.0.2:7777`. **The seed is printed
  at startup** — pass it back with `-seed` to replay a fault sequence, which is the difference
  between a bug report and an anecdote. Note `-loss`/`-duplicate`/`-reorder` are udp-only —
  dropping bytes out of a proxied tcp stream corrupts it instead of simulating loss, so they are
  applied to the udp/quic flows and skipped on tcp. Combining them with a mirrored tcp port is
  fine and is the normal case: the handshake is ALWAYS tcp, so every real session needs tcp
  mirrored. The tool refuses only the combination that would do nothing at all — those flags with
  no udp ports mirrored (an earlier version made *any* tcp mirroring fatal, which made `-loss`
  unusable in exactly the case it exists for).
- `run-relay-loopback.bat` — a relay that echoes a lone client's own state back as
  `<id>-ghost`. Pair with any single core (`run-core.bat emerald`, `run-core.bat tevi`,
  `run-core.bat pseudoregalia`) to see a real network round trip and your own ghost with only
  one game instance running — see
  [agent_docs/phases/phase3.md](../agent_docs/phases/phase3.md) and
  [agent_docs/phases/phase6.md](../agent_docs/phases/phase6.md).
- `run-relay-loopback-shipped.bat` — the same loopback echo at **shipped** settings: `-loopback`
  is its only departure from a released relay, so the receive rate is the default 20Hz rather
  than `run-relay-loopback.bat`'s `-send-hz=100`. That override is exactly what would invalidate
  a test asking how the renderer looks at the rate a real player receives. **Pair it with
  `run-core-crystal-shipped.bat`, never with `run-core.bat crystal`** — see the interp/offset
  pairing rule above; the two rigs answer opposite questions and mixing them produces a reading
  that belongs to neither.
- `run-loopback-in-release-folder.bat` — **the only script here meant to leave this folder.**
  Same loopback idea as above, but for someone who downloaded a release zip rather than built
  the repo: they copy this one file next to `meshghost.exe`/`meshghost-server.exe` and run it
  instead of `meshghost-server.exe`, and see a ghost of themselves with no second player and no
  second PC. Hand it out on request — it is deliberately **not** bundled into the release
  (`.github/workflows/release.yml` only zips `packaging/release/*`, so nothing here ships), and
  the release stays a clean two-exe folder with no dev-only flag sitting in it.

  Two deliberate differences from `run-relay-loopback.bat`, both from the release layout rather
  than preference: the release renames the relay to `meshghost-server.exe` and puts it in the
  *same* folder as the script rather than one level up, and there is no `-send-hz=100` override
  — that exists only to keep a dev relay out of the way of the `run-core-*.bat` scripts' own
  fast `-min-send`, so in a release folder it would just silently override the user's own
  `config.json`. It `cd /d "%~dp0"` first (the relay reads `config.json` from the working
  directory, which differs between double-clicking, dragging onto a cmd window, and Run as
  administrator) but still launches via the full `"%~dp0meshghost-server.exe"` path: cmd's
  usual "search the current directory for a command" lookup is disabled wherever
  `NoDefaultCurrentDirectoryInExePath` is set, and a bare exe name then fails with "not
  recognized as an internal or external command" while sitting right there — found live while
  testing this script. Dropped in the wrong folder it says so in plain language and exits
  rather than failing cryptically.

  **Status: confirmed on screen in a running game (2026-08-15)** — user ran it from a real
  release folder with Pseudoregalia attached and saw their own ghost standing beside them; see
  [agent_docs/verified.md](../agent_docs/verified.md)'s entry for what was observed. Fine to
  hand out. Agent-side checks cover the details underneath: `config.json` and
  `meshghost-server.log` both resolving to the release folder when launched from an unrelated
  working directory, the wrong-folder guard exiting cleanly, and a `render_remote p1-ghost`
  round trip driven by `meshghost-fakeadapter.exe`.

  **Expect it to look less smooth than the dev loopback — that's the point, not a bug.** Since
  this script omits `-send-hz=100`, the relay runs at the release `config.json`'s own `send_hz`
  (20 by default), which is what a real session actually looks like; the dev scripts' 100Hz is
  the artificial one. The difference is clearly visible side by side and was the first thing
  noticed on the live run. Rate and smoothing are tuned in `config.json` (`send_hz`, `interp`),
  the same knobs a real player has — resist adding `-send-hz` back to this script.

  Still unconfirmed *through this script*: Emerald and TEVI.

  The loopback ghost renders a short distance to the side of the real player rather than
  exactly on top of it, so the two can be compared without overlapping — that offset is
  adapter-side, not in this script: `LOOPBACK_GHOST_OFFSET_TILES_X` in
  `meshghost_emerald.lua` (2 tiles), `LOOPBACK_GHOST_OFFSET_X` in Pseudoregalia's `Plugin.cpp`
  (150), and in TEVI an inline `160f` literal in `Plugin.cs`'s `UpsertRemoteGhost` rather than a
  named constant.
- `run-core.bat tevi` / `run-core.bat tevi auto 2` — two TEVI core clients on distinct bridge
  ports (7778 / 7779), for real two-TEVI testing with a normal (non-loopback) `run-relay.bat`.
  Pair each with its own TEVI install
  (e.g. the Steam copy on 7778, a standalone build like a separate standalone TEVI build on 7779 — see
  [agent_docs/environment.md](../agent_docs/environment.md)); the standalone install's own
  `BepInEx/config/dev.meshghost.tevi.cfg` needs its `BridgePort` set to match (7779), since
  Steam already owns the default. See
  [agent_docs/phases/phase6.md](../agent_docs/phases/phase6.md)'s 6.6 entry.
- `build-tevi.bat` — not a launcher, a build step: compiles the TEVI BepInEx plugin and stages
  the result into `packaging/release/games/tevi/` for the release zip. Re-run and commit the
  result whenever `adapters/tevi/MeshGhostTevi/{Plugin.cs,BridgeClient.cs,*.csproj}` change —
  see [packaging/README.md](../packaging/README.md)'s TEVI section for why this one output is
  committed at all.
- `tevi-hotreload.ps1` — takes the relaunch out of TEVI's edit loop. Moves the adapter between
  `BepInEx\plugins\` (the shipping layout) and `BepInEx\scripts\`, where BepInEx's own
  ScriptEngine reloads it in a running game, and arms ScriptEngine's file watcher so `-Deploy`
  rebuilds, copies, and triggers the reload with nothing pressed by hand. `-Status` says which
  mode an install is in; **both at once means the adapter loads twice**, which is the failure the
  toggle exists to prevent. `-Both` applies every mode to two installs at once (the second from
  `MESHGHOST_TEVI_DIR2`) — **use it for any dual-instance session**, because deploying to one and
  not the other leaves the two copies running different adapter builds and the asymmetry reads
  exactly like a peer-vs-local bug. `-Deploy` also refreshes `meshghost.exe` beside the adapter
  and warns when the repo's own binary is older than a `.go` file, after both installs were found
  on 2026-08-28 running a core from 2026-08-18. Two things it cannot tell you — a cold-start-only
  bug, and anything a reload orphaned in the scene — are written at the top of the script.
- `pseudo-hotreload.ps1` — the same idea for Pseudoregalia, but weaker by necessity: UE4SS
  hot-reloads **Lua** mods only, so this speeds up probe iteration and does nothing for the C++
  adapter, which still costs a rebuild and a relaunch. UE4SS exposes reloading only as a keybind
  (Ctrl+R), so the script drives that key at the game window; `-Watch` does it on every `.lua`
  change. Confirm a reload in `UE4SS.log`, never from the script's own line — a reload that hit
  a Lua error reports there and leaves the OLD script running, which looks like no change at all.
- `run-core-crystal-shipped.bat` — the **complement** of `run-core.bat crystal`: no flags beyond game and bridge, so
  interpolation is `core.DefaultInterpolationDelay` (250ms) and the send rate is the default.
  Here the 250ms is the subject of the test rather than a nuisance in it. Launch it explicitly
  rather than leaning on adapter autostart — relying on autostart is what made two sessions of
  stutter work ambiguous ([phase9.md](../agent_docs/phases/phase9.md)): the settings were right
  by accident and unlogged, so nothing recorded which rig produced which reading.
- `run-core.bat pseudoregalia` — a single core client wired for Pseudoregalia
  (`-game=pseudoregalia`, bridge port 7778) — see
  [agent_docs/phases/phase7.md](../agent_docs/phases/phase7.md).
- `run-core.bat pseudoregalia tcp` / `… udp` / `… quic` — the same client pinned to one
  transport each, for live-testing the 2026-08-16 selectable-transport work. Pair any of them
  with `run-relay-loopback.bat`, which serves all three at once, so switching protocol means
  passing a different argument rather than restarting the relay.
  **Confirm which transport was actually used** — every connection handshakes over tcp and only
  then upgrades, and a preference the relay does not serve degrades quietly to a working tcp
  session, so a run that "works" proves nothing on its own. `meshghost.log` carries
  `core: relay offers ... — using <transport> at ...`; if that names something else, that run did
  not test what you meant. Two things worth watching that the automated tests cannot reach: a
  state message over `udpconn.MaxDatagramBytes` (1200) is refused rather than sent, which shows
  up as `core: send state to relay failed` rather than as silence; and the retransmit timer and
  dedup pruning only get exercised over minutes at 20Hz, not over one round trip — see CLAUDE.md's
  rule about light tests not closing load-dependent risks.
- `build-pseudoregalia.bat` — not a launcher, a build step: compiles the Pseudoregalia UE4SS
  C++ mod (`main.dll`) via its local CMake build tree and stages it into
  `packaging/release/games/pseudoregalia/`. Re-run and commit the result whenever
  `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*` or its `CMakeLists.txt` change — same
  staleness-gate pattern as `build-tevi.bat`, but CI can't build this one at all (needs the
  private UEPseudo dependency), so the build tree must already be configured locally — see
  [agent_docs/phases/phase7.md](../agent_docs/phases/phase7.md)'s 7.2 entry.
- `stage-ue4ss-runtime.bat` — stages the RE-UE4SS runtime (UE4SS.dll, settings, the MIT LICENSE)
  from the pinned `adapters/pseudoregalia/MeshGhostPseudo/RE-UE4SS` submodule into
  `packaging/release/games/pseudoregalia/`, alongside whatever `build-pseudoregalia.bat` has
  staged. The stock Mods folder is deliberately NOT staged -- see the script's own header for the
  cheat-manager/console reasoning -- and no mods.txt/mods.json ships either. Re-run whenever the
  RE-UE4SS submodule pin changes; requires the build tree already built once.

## Since autostart works, the MOD's config decides the client's settings — not these scripts

**Pseudoregalia, 2026-08-27.** The mod now starts its own core (`VERIFIED.md`), which changed
something subtle about how a dev session behaves: if you launch only a relay bat and then start the
game, **no `run-core-*.bat` is involved at all**. The client that connects is the one the mod
spawned, and it reads

```
<game>/Binaries/Win64/ue4ss/Mods/MeshGhostPseudo/config.json
```

not any flag in this folder. That file's `transport`, `room`, `name` and `interp` are what the
session actually uses.

**How it shows up**: the relay logs `joined room "default" ... over udp` when you expected quic,
because that install's config asked for udp while the dev core scripts pass no `-transport` at all
and would have defaulted to `auto` (quic preferred). Nothing about transports changed; which client
ran did.

**So when a dev session behaves unlike the flags you think you set**, check whether you actually
started a core. `meshghost.log` in that mod folder says which client it was, and the mod's own log
prints `started meshghost.exe (pid N)` when it spawned one.

## CI and repo hygiene

Not launchers at all, and not strays — one of them CI calls by name.

- `ci-fuzz.sh` — **CI runs this, do not move or delete it.** `.github/workflows/ci.yml`'s fuzz job
  invokes `bash dev-scripts/ci-fuzz.sh <package> <FuzzTarget> <fuzztime>` once per target (11 of
  them as of 2026-08-19), so renaming this file breaks the fuzz job. It exists because `go test
  -fuzz` can exit non-zero with nothing but `context deadline exceeded` when its own `-fuzztime`
  elapses mid-execution — no crashing input, nothing written to `testdata`, green on the next run.
  This wrapper fails only on a real finding, so a red fuzz run stays worth reading. Seen on CI
  2026-08-17; the script's own header has the numbers.
- `lua-forward-refs.py` — mechanical check for a name used *before* its file-scope `local` in a
  Lua file, which Lua silently resolves to a nil global rather than erroring where you would see
  it. Deliberately crude (it flags candidates, it does not parse Lua) and it understands forward
  declarations. Bit the Emerald adapter three times on 2026-08-18, each costing a live test.
- `preflight.ps1` — documented above, with the Go test scripts.

## BizHawk dev loader, screenshots and savestates

The loader is the entry point for everything in the three sections below it: BizHawk only accepts
a Lua script on the command line (`--lua=...`), and attaching or swapping one on an
ALREADY-RUNNING instance is a Lua Console GUI action nothing outside the emulator can drive.

- `bizhawk-dev-loader.lua` — attached once at launch, then watches a plain-text control file
  (`bizhawk-dev-loader.target` beside it, gitignored — `*.target` has its own `.gitignore` entry)
  naming one script per line, or `none` to run nothing. Change the file and it swaps to the new
  set on the next poll, with no relaunch and without disturbing the running game. Loaded scripts
  hook in by assigning `MESHGHOST_DEV_TICK`. Reach for it any time you would otherwise relaunch
  the emulator to try a revised probe.
- `bizhawk-screenshot.lua` — one screenshot after a fixed delay (600 frames / 10s), because the
  first version fired on its first tick and produced three "the ghost is invisible" shots of a
  game that had not spawned one yet. Use when you want the state some seconds into a session.
- `bizhawk-screenshot-loop.lua` — a numbered PNG every N frames (default 120) into a per-game
  shots folder (`MESHGHOST_SHOT_DIR` / `_PREFIX` / `_INTERVAL`, per-game because two emulators run
  at once and one shared folder means two agents overwriting each other's evidence). Use when the
  question is "what has been happening" rather than "what is on screen now" — one frame cannot
  see a blinking thing.
- `bizhawk-savestate.lua` — saves or loads one savestate slot once, then stops; edit `ACTION`/
  `SLOT` and point the loader at it. Slot 1 is the user's own, 2-10 are agent checkpoints. Use it
  to make a repeated or risky test cheap instead of re-walking to the state by hand. A savestate
  is not an in-game save.
- `load_slot.lua` — loads one savestate slot, once, then goes quiet. Slot from
  `MESHGHOST_LOAD_SLOT`, or from the same-named global set by a script loaded ahead of it (the dev
  loader shares one Lua environment, and the environment variable is fixed at emulator launch, so
  the global is the only way to change slot without relaunching). Written to put a two-instance rig
  into a known position without asking anyone to press a key. **Load it BEFORE the adapter, not
  beside it** — `crystal/UNVERIFIED.md` records a savestate load killing the adapter, and a rig has
  no need to find out whether that is still true.
- `bizhawk-hitch-meter.lua` — **standing rig for any "it feels choppy" question**, game-agnostic
  and read-only. Reports frames over 20ms, frames over 33ms, and the worst gap, because **frame
  RATE is an average and an average cannot see a hitch**: ten frames lost inside one second still
  reads as 58fps. That disagreement cost most of an hour on 2026-08-21, when every measurement
  said 59.7fps while the user saw chop. Measuring the frame-to-frame *gap* found the cause in
  minutes — and found it in the instrumentation, which is why this one buffers its own log.
- `bizhawk-syntax-check.lua` — `loadfile()`s each named Lua file and reports whether it *compiles*,
  running none of them, so no adapter socket or frame loop starts and nothing touches the game.
  Use it to catch a missing `end` from inside a live session. (It was written when this machine
  had no standalone Lua; it does now, and `preflight.ps1` runs `luac -p` over every tracked `.lua`
  on each invocation. This is still the quicker check while BizHawk is already open, and the only
  one that answers "does it compile under *this* build's embedded 5.4".)
- `zoom.ps1` — crops and nearest-neighbour upscales a region of the last screenshot so a sprite in
  a 240x160 GBA frame is legible (`-X -Y -W -H -Scale -Game -In -Out`). Nearest-neighbour on
  purpose: no smoothing inventing detail that is not there.

## BizHawk capability probes

All read-only "what can this host actually do?" scripts. A doc string in BizHawk's DLL is not
proof a function is callable — `memory.hash_region` had one and was nil at runtime — so these ask
the live build rather than trusting a list. Each writes a `.log` beside itself.

- `bizhawk-capabilities.lua` — dumps `client.getluafunctionslist()`, every function this build
  actually implements. The first thing to run when asking "what else can we drive from here?".
- `bizhawk-api-dump.lua` — the fallback for a build where that call is missing (it is absent in
  this one, checked 2026-08-18): walks the global tables (`client`, `emu`, `os`, `io`, `comm`,
  `bizstring`) and lists their keys.
- `bizhawk-savestate-probe.lua` — reports which of `savestate.save` / `load` / `saveslot` /
  `loadslot` / `saveslots` exist. Saves nothing and loads nothing.
- `bizhawk-input-probe.lua` — reports what the `joypad` and `input` libraries expose. Presses
  nothing, deliberately: driving input while someone is playing fights them for the controller.
- `bizhawk-joypad-names.lua` — dumps the keys of `joypad.get()` / `getimmediate()`, which are the
  exact button names this core expects. Reach for it when `joypad.set` silently does nothing for a
  direction, instead of guessing a third spelling.
- `bizhawk-spawn-probe.lua` — asks whether a process started via `luanet` (NLua's .NET bridge,
  `System.Diagnostics.Process`) is actually *invisible*, where `os.execute`/`io.popen` always
  flash a console window whatever shape they are given. Three countdown-paced phases ending in a
  deliberate positive control that SHOULD flash; a human watches the screen, since no machine can
  answer this one.
- `bizhawk-cheat-probe.lua` — asks which cheat-code formats this build's cheat engine accepts
  (`client.addcheat`), the question that has to come first before using cheats to reach a game
  state that would otherwise cost hours of play: BizHawk ships a GameShark decoder, and a
  CodeBreaker code fed to it does not fail loudly — it decodes to a *different* address and writes
  there. Adds codes, presses nothing.
- `bizhawk-cheat-clear.lua` — removes the six codes that probe added. Written 2026-08-18 when a
  screenshot showed BizHawk had accepted two of them, decoded them to nonsense low addresses, and
  marked them ACTIVE — an active cheat writing an arbitrary byte every frame is exactly the kind
  of thing later blamed on the adapter. Run it after the probe.

## BizHawk input driving

- `bizhawk-input-test.lua` — can a script actually MOVE the player, or does `joypad.set` merely
  exist? Checkpoints to slot 3, reads the player's map coordinates, holds RIGHT for a fixed number
  of frames (re-issued every frame — `joypad.set` applies to the next frame only), reads the
  coordinates again and reports the **delta**, then restores the checkpoint. Those coordinates are
  the independent witness; "the call did not raise an error" is not one.
- `bizhawk-input-demo.lua` — the same behavioural test in the other direction (holds Down, slot 4),
  with screenshots either side for looking at, NOT for proof.

## Adapter-specific investigation tools

Emerald-side one-offs, kept because the questions recur. Each is loaded through
`bizhawk-dev-loader.lua` and writes its own `.log` under `dev-scripts/`.

- `tile-inspect.lua` — reads the tile the player faces the way the game does and names its
  behaviour (pond/deep/ocean water, tall grass, normal). Written when the Super Rod was refused
  with "not usable here" and it was unclear whether the edited tile or the facing was wrong.
  Read-only.
- `walk-into-tile.lua` — the behavioural version of the same question: walk into the tile and see
  whether the game blocks you, which needs no redraw and no menus.
- `walk-and-shoot.lua` — walks a few tiles then screenshots, because the surf blob is only
  repositioned by the engine when its rider MOVES (`SynchronizeSurfPosition`), so a stationary
  frame cannot show whether an initial placement error corrects itself.
- `fish-sequence.lua` — drives the menu route to "Super Rod cast at water", screenshotting every
  step, and starts by backing out to a neutral overworld rather than assuming one. It scripts the
  SETUP only; fishing itself is a branching process, which is the part being watched rather than
  driven.
- `rom-swap-test.lua` — proves `client.openrom` loads an arbitrary ROM, fingerprinting the code
  around `CB2_Overworld` before *and* after within one run (a first attempt compared two separate
  runs and saw no difference, because the earlier run had left the other ROM loaded). Both paths
  come from `MESHGHOST_ROM_VANILLA` / `MESHGHOST_ROM_PATCHED`; you supply your own copies, and no
  ROM path or seed filename belongs in this repo.
- `gfxinfo-probe.lua` — dumps `ObjectEventGraphicsInfo` field by field for a handful of graphics
  ids (size, tile count, OAM shape, subsprite table), for comparing a graphic that renders as
  garbage against the player's own.
- `force-ghost-gfx.lua` — the switchboard for Emerald's ghost-graphics debug globals
  (`MESHGHOST_FORCE_GHOST_GFX`, `MESHGHOST_GHOST_PEER_GFX`, `MESHGHOST_DEBUG_SKIP_OAM_COPY`,
  `MESHGHOST_DEBUG_SHARE_PLAYER_TILES`). It assigns every one of them unconditionally because
  globals survive a loader script swap, and as committed they are all `nil` — so the file's job in
  its checked-in state is clearing that state back to the default. Edit a value to force one.
