# Verified facts

<!-- line-cap: none -- append-only human-gated record -- a cap would mean deleting evidence to add evidence. Why: agent_docs/claude-md-cap.md. -->

This file records facts that have been confirmed by observing actual behavior in a running
game. See `CLAUDE.md` for the full rule; summary:

- No inferred or speculative values are allowed.
- Every entry must include a source, such as a memory address, API, or documentation
  reference.
- This file is append-only, and gated on evidence whose standard depends on what is being
  claimed. There are two tracks, and **every entry must say which one it is**:
  - **Anything visual or gameplay-facing — how it looks, how it feels, whether it works in
    the game — is human-gated**: it goes in only after the user has personally watched the
    behavior happen. This is the whole adapter surface, and the user is the only one who can
    close it.
  - **Go-side facts — the Go packages, `cmd/`, the relay, the transports — are agent-confirmed**,
    established by running the tools (`dev-scripts/run-gotests.bat`, a log line, a console
    read) and recorded without waiting on the user. That code is deterministic against a
    contract we own, which is exactly why `CLAUDE.md` separates the three.

  In neither track is a successful build or a plausible-looking number sufficient grounds for
  an entry. **Append-only means don't rewrite or delete an
  existing entry's original observation** — it does not forbid adding newly confirmed detail
  to an existing entry (e.g. extending it with a later live-confirmed edge case), which has
  happened before (see the TEVI fog-of-war entry's own edit history) and is a legitimate use,
  as long as what was originally observed stays intact. Superseding an entry (below) is always
  a new entry plus an annotation, never an edit to the old one.
- **A fact confirmed against one build/ROM/version is not automatically true of another.**
  State the scope explicitly in `Notes` whenever it plausibly matters (which ROM revision or
  patch, which game/engine build) — several early entries stated a fact as if build-independent
  and were later directly contradicted by the same fact on a different build (see the
  Archipelago-ROM entries below, and the `Superseded by` annotations they prompted on the
  vanilla-only entries they corrected). When in doubt, state the scope.

## Entry format

Copy this block per fact:

```text
### <short claim, e.g. "Emerald local player X position">

- Date:
- Observed: <what was seen on screen, and what action produced it, e.g. "printed value
  decreased by 16 per tile when walking left in Littleroot Town">
- Source: <exact file + symbol/line in the referenced repo, or doc page + section>
- Notes: <build/ROM/version scope this was confirmed under, if it plausibly matters; any other
  conditional detail — edge cases found, caveats>
```

## Index — every entry in this file

**Titles only, one line per entry, and `dev-scripts/preflight.ps1` fails if an entry is missing
from it.** Added 2026-08-25: this file is append-only and only grows, so without an index the
cheapest way to find a fact was to read the whole record. Now it is to read this list.

**Entries sit at two heading levels** — the earliest are `###` under "Confirmed facts", later ones
are `##` — and both are indexed. The levels are historical and are deliberately NOT normalised:
changing an entry's heading is a rewrite of the record, which is the one thing this file forbids.

**Adding an entry costs one line here.** That is the whole maintenance contract, and it is the
reason this is an index rather than a taxonomy — nothing can mechanically check that an entry is
filed under the right theme, but anything can check that it is listed.

- <short claim, e.g. "Emerald local player X position">
- BizHawk loads a Lua script as an in-memory string chunk, not a file — debug.getinfo can't recover its path
- io.popen("cd") reliably returns the script's own directory in BizHawk Lua
- BizHawk's gui.* drawn graphics persist across frames — they do not auto-clear
- internal/core did not despawn remotes when its own relay connection was lost
- Phase 4: real peer leaving (core process closes) despawns correctly; adapter-only disconnect does not
- Phase 5: Core runs standalone against an in-process fake adapter, no game attached
- Core-relay heartbeat, found live and fixed (idle-timeout reconnect-ID churn)
- Automated Go-side test/debug tooling, and a real intermittent-failure bug it found
- The bug this found (real, pre-existing, now fixed)
- What was added
- Fuzz campaigns actually run (all clean, no failures)
- Two environment facts worth not rediscovering
- CI's first real run: no data race, one over-strict test of my own
- Selectable transport (`tcp`/`udp`/`quic`) — 2026-08-16, established with the Go tools
- Transport discovery (`transport: "auto"`) — 2026-08-16, established with the Go tools
- UDP per-connection token — 2026-08-16, established with the Go tools
- A real bug found in review, and a test that first failed to catch it — 2026-08-16
- 2026-08-16 — "use of closed network connection" in the relay log was ours, and is fixed
- 2026-08-16 — CI's race job found a relay race, and chasing it found a worse bug in the core
- 2026-08-16 — A release failed on a port that was free for tcp but forbidden for udp
- 2026-08-16 — The client shows a console under Wine by default (Windows side verified)
- udp's reliable path was reliable but NOT ordered — found and fixed 2026-08-16
- quic became the default path, and shares the relay's port — 2026-08-16
- The synthetic-peer rig could only ever test tcp — fixed 2026-08-16
- Two transport-divergence bugs, found by a loopback re-test and the suite it prompted
- World custody (`world.v1`) — the relay holds a world it cannot read, and hands it on
- A maximal event and a committed escrow are too large for a udp datagram (pre-existing, not fixed)
- 2026-08-17 — The Go packages moved out of `internal/` and the module took its real path
- Red and Blue are byte-identical in RAM — one adapter covers both
- Platinum: ROM matches the decomp's Rev 1 target, but nothing is built
- NOTE: `internal/X` package paths throughout this file predate the 2026-08-17 move (2026-08-18)
- CORRECTION: the two "`-race` cannot run on this machine" entries above are wrong (2026-08-18)
- CORRECTION: `MaxEventBytes`' "comfortably under a datagram" claim, now pinned by tests (2026-08-18)
- 2026-08-18 — v0.9.5 released as a pre-release, and the asset hashes are real
- 2026-08-18 — CORRECTION: the release hash table was redundant and has been removed
- 2026-08-18 — Autostart works in all four adapters, confirmed live
- Both renderers side by side, and the first two gaps it found — 2026-08-19
- 1. The drawn tier moved at the NETWORK's pace, not the game's — fixed and confirmed
- 2. A facing change drew as one static frame — fixed and confirmed
- 3. Visible for a moment during a house transition — half fixed
- The comparison keeps paying: four more, and one of them was the SPAWNED tier — 2026-08-19
- A spawned ghost stuck in a running pose — fixed
- Door transitions, both directions — fixed, and the second attempt was the better design
- Scene brightness, which is the gap the user predicted before any of this existed
- And the one that took four attempts, because it was the wrong question three times
- The comparison's last two answers: pin it, and give the core more delay — 2026-08-19
- Matching the engine's movement is not reachable, so compare mode stops trying
- The spawned ghost's own chop was ARRIVAL CADENCE, and `-interp` fixes it
- 2026-08-21 — HBlank multiplexing is closed by decision, not left open
- RULE CHANGE — the gate on this file tightened (2026-08-21)
- All four adapters still run end to end after the doc/refactor pass — 2026-08-25
- A relaunched game could get a DEAD session, and CI caught it once in two runs (2026-08-27)
- The render-knob sweep: damped prediction wins on a jittery link, and two bugs fell out first (2026-08-28)


## Split per game — 2026-08-25

**This file used to hold all four games and the Go side, interleaved chronologically, at 10,174
lines.** It was the most frequently touched file in the repo. On 2026-08-25 the per-game entries
moved, verbatim and in their original order, to a `VERIFIED.md` beside each adapter's own
`README.md`/`FLAGS.md`/`BANDAGES.md`/`documentation.md`:

| Game | File | Entries |
| --- | --- | --- |
| Pokémon Crystal | [../adapters/emulator/pokemon/crystal/VERIFIED.md](../adapters/emulator/pokemon/crystal/VERIFIED.md) | 65 |
| Pokémon Emerald | [../adapters/emulator/pokemon/emerald/VERIFIED.md](../adapters/emulator/pokemon/emerald/VERIFIED.md) | 120 |
| Pseudoregalia | [../adapters/pseudoregalia/VERIFIED.md](../adapters/pseudoregalia/VERIFIED.md) | 104 |
| TEVI | [../adapters/tevi/VERIFIED.md](../adapters/tevi/VERIFIED.md) | 18 |
| Go side, cross-game, governance | this file | 37 |

**What stayed here**: the Go packages, `cmd/`, the relay and transports; releases and CI;
cross-game method entries (the side-by-side renderer comparison, which both Pokémon adapters
carry); access-model groundwork for games with no adapter folder (Red/Blue, Platinum); the
governance entries, including the RULE CHANGE that tightened this file's own gate.

**The rule used to split it, its correction, and every conservation check** are in
[ideas.md](ideas.md), "Doc restructuring". Worth knowing before trusting a similar operation: the
segmentation rule as first written filed 12 dated headings as sub-headings and would have moved ten
Go-side/Emerald/Crystal entries into Crystal's file, while the line-count conservation check still
passed. **Conservation catches loss; it cannot catch misfiling.**

**Two cross-file references survived the split and are marked in place** — entry 262's
Pseudoregalia correction cites a Go-side transport entry that stayed here, and the RULE CHANGE
entry cites an Emerald entry that moved. Both name their target by title.

## Confirmed facts

### BizHawk loads a Lua script as an in-memory string chunk, not a file — debug.getinfo can't recover its path

- Date: 2026-08-11
- Observed: `phase3_loopback.lua` computed its own directory via
  `debug.getinfo(1, "S").source`, expecting a `@`-prefixed file path. Running it live threw
  `NLua.Exceptions.LuaScriptException: [string "main"]:130: The specified module could not be
  found` — the `[string "main"]` chunk-name format (Lua's standard formatting for a chunk name
  with no `@`/`=` prefix) proved `source` was just the literal string `"main"`, not a file path,
  so every path built from it silently resolved to `./` relative to BizHawk's own working
  directory instead of the script's real location.
- Source: `TASEmulators/BizHawk` `src/BizHawk.Client.Common/lua/LuaLibraries.cs`,
  `SpawnCoroutineAndSandbox`: `var content = File.ReadAllText(file); var main =
  _lua.LoadString(content, "main");` — the script's text is read in C# and loaded as an
  in-memory chunk, never via a file-path load.
- Notes: the working fix (see next entry) is `io.popen("cd")`, not `debug.getinfo`. Any future
  BizHawk Lua work in this project should assume the same: there is no reliable way to recover
  "this script's own file path" from inside the script via chunk/debug metadata.

### io.popen("cd") reliably returns the script's own directory in BizHawk Lua

- Date: 2026-08-11
- Observed: after the `debug.getinfo` approach above failed, switched to
  `io.popen("cd"):read("*l")` (matching the identical, documented workaround already used by
  Archipelago's `connector_bizhawk_generic.lua`/`socket.lua`). Confirmed independently via
  `cmd /c cd` from a shell with the working directory set to the script's folder, printing
  exactly that path with no extra output — and confirmed live in BizHawk that paths built from
  this (`lib/x64/socket-windows-5-4.dll`, `lib/x64/lua54.dll`, `assets/ghost_placeholder.bmp`)
  all resolved correctly once used.
- Source: `TASEmulators/BizHawk` `src/BizHawk.Client.Common/lua/LuaSandbox.cs`, `Sandbox()` →
  `CoolSetCurrentDirectory` → (Windows) `BizHawk.Common.CWDHacks.Set`, confirmed by reading
  `src/BizHawk.Common/Win32/CWDHacks.cs` to be a direct P/Invoke of the real
  `SetCurrentDirectoryW` — BizHawk genuinely sets the OS process working directory to the
  script's own directory before running it, restoring the previous value after.
- Notes: matches Archipelago's own script's comment ("for some reason `./` isn't working, so
  use a horrible hack to get the pwd") — that project independently found the same thing.

### BizHawk's gui.* drawn graphics persist across frames — they do not auto-clear

- Date: 2026-08-11
- Observed: closing the relay (and separately, the core) while `phase3_loopback.lua` was
  running left the ghost frozen on screen indefinitely — even after the underlying data was
  confirmed correctly cleared (`internal/core`'s remotes map empty, the Lua adapter's own
  `remotes` table empty), the last-drawn image simply stayed visible, because nothing had ever
  called `gui.clearGraphics()`. Adding an unconditional `gui.clearGraphics()` at the top of
  every frame (before any connect/send/draw logic) fixed it — confirmed live: killing the
  relay and separately the core each now make the ghost disappear instantly.
- Source: `TASEmulators/BizHawk` `Assets/Lua/_docs_luacats/gui.d.lua`
  (`gui.clearGraphics` — "clears all lua drawn graphics from the screen", a function that would
  be meaningless if the overlay already auto-cleared); real precedent in BizHawk's own bundled
  scripts calling it every frame for moving overlays (`Assets/Lua/Doom/doom.lua`,
  `Assets/Lua/Genesis/Gargoyles.lua`, `Assets/Lua/Genesis/Earthworm Jim 2.lua`,
  `Assets/Lua/SNES/Super Mario World.lua`).
- Notes: **corrects a wrong assumption stated in `agent_docs/contract.md`'s tick model since
  Phase 2** ("BizHawk's `gui.*` overlay is cleared every frame") — that claim was never
  actually tested against "stop drawing entirely," only against "draw every frame vs. draw at
  network rate," and turned out to be false for the former case. Phase 2's own ghost never hit
  this because it drew unconditionally every single frame for the phase's whole duration. The
  redraw-every-frame requirement itself was already correct; only the stated reason, and the
  missing explicit clear call, were wrong. `contract.md` has been corrected in place.

### internal/core did not despawn remotes when its own relay connection was lost

- Date: 2026-08-11
- Observed: killing the relay process mid-session left the loopback ghost's last known
  position sitting in `internal/core`'s `remotes` map forever — `remoteBuffer.at()` holds the
  newest sample with no extrapolation once render time passes it, and nothing about the
  existing per-frame tick logic had a reason to notice the relay was gone, since only an
  explicit `Leave` message (impossible once the relay itself is unreachable) previously drove a
  despawn. Fixed with `Core.dropAllRemotes()`, wired into the relay connection's
  `OnDisconnect` handler — confirmed live afterward: killing the relay now makes the ghost
  disappear immediately, and the core's own log shows `core: relay disconnected` at the exact
  moment.
- Source: `internal/core/core.go` (`ConnectRelay`'s `OnDisconnect` handler, `dropAllRemotes`);
  regression test `TestOwnRelayDisconnectDespawnsRemotes` in `internal/core/core_test.go`.
- Notes: distinct from the pre-existing, already-correct `TestDisconnectDespawnsRemote`, which
  covers a *peer* disconnecting (driven by a real `Leave` message) — this is the core's *own*
  relay connection dying, which has no `Leave` to drive it.

### Phase 4: real peer leaving (core process closes) despawns correctly; adapter-only disconnect does not

- Date: 2026-08-11
- Observed: closing only the BizHawk/Lua adapter for `player2` (leaving its core process
  running and still connected to the relay) left `player2`'s ghost frozen at its last position
  on `player1`'s screen — correct, since the relay had no `Leave` to broadcast. Separately
  closing `player2`'s core process (clean window close) triggered an immediate despawn of the
  ghost on `player1`'s screen. Reconnecting a fresh BizHawk/core pair afterward was stamped a
  new sequential ID (`p3`, not `p2`) by the relay, as expected from `nextPlayerID`'s
  connection-order counter.
- Source: `internal/relay/relay.go` (`nextPlayerID`, `Leave` broadcast on disconnect);
  `internal/core`'s existing per-remote despawn-on-`Leave` logic (unmodified from before Phase
  3).
- Notes: first real-second-peer confirmation that an adapter dying alone does *not* end the
  session (by design — the peer might just be relaunching BizHawk), only the core's relay
  connection dropping does.

### Phase 5: Core runs standalone against an in-process fake adapter, no game attached

- Date: 2026-08-11
- Observed: `run-relay.bat` plus two `run-fakeadapter{1,2}.bat` (these three scripts were at
  the repo root at the time; moved to `dev-scripts/` 2026-08-11, same content, see
  `agent_docs/phases/phase5.md`) (`meshghost-fakeadapter.exe
  -name=alice -radius=10 -period=4` and `-name=bob -radius=6 -period=6`) run in separate
  console windows. Each window's `render_remote` lines showed the *other* client's position
  continuously changing — radius holding steady (~10 and ~6 respectively) while the angle kept
  advancing sample to sample, consistent with each tracing its own circle — not frozen, not
  jumping to garbage values. User watched both windows and confirmed this.
- Source: `internal/core/core.go`'s new `Core.RunAdapter` (in-process driver added this phase,
  reusing the existing `tickRenders` diff logic also used by the bridge-wire path) and
  `cmd/meshghost-fakeadapter/main.go`'s `circleAdapter`, which satisfies `core.Adapter` and is a
  pure function of wall-clock time — no game, no bridge socket, no import of anything under
  `adapters/`.
- Notes: this is the Phase 5 milestone from `agent_docs/plans.md` — proof the core has no
  game-specific leaks. `TestRunAdapterInProcess` in `internal/core/core_test.go` covers the same
  path with an assertion (two in-process Cores exchanging state over a real relay); this entry
  is the additional human-observed confirmation the automated test can't provide on its own.
  Console print rate is throttled to `-log-every` (default 500ms) per remote — `RunAdapter`
  itself still ticks at the full `-tick` rate (default ~60fps) underneath; only the demo's
  logging is throttled, not the core's drive loop.

### Core-relay heartbeat, found live and fixed (idle-timeout reconnect-ID churn)

- Date: 2026-08-14
- Observed: while testing the above, the user noticed the relay and core logs climbing through
  player IDs (`p1`→`p2`→...→`p6`) roughly once a minute, each preceded by an `i/o timeout` on
  both sides. Root cause: a core process with no adapter attached (or any adapter reporting
  `get_local_state()==nil` for a stretch, e.g. a player parked at a menu) never calls
  `forwardLocalState`, so nothing was ever sent on an otherwise-healthy relay connection.
  `transport.DefaultIdleTimeout` (60s, added in the same-day relay-safety sweep) then killed it,
  the sweep's own auto-reconnect fix immediately redialed, and `nextPlayerID` (a
  never-reused monotonic counter) handed out a fresh id each cycle — which every other real peer
  would see as a leave+join/ghost despawn-respawn once a minute, not just log noise. Fixed:
  `Core.sendHeartbeats` (`internal/core/core.go`), started on every successful `ConnectRelay`,
  sends a `Ping` every `DefaultHeartbeatInterval` (20s) for as long as that connection stays
  current; the relay already replied to `Ping` with `Pong` (`internal/relay/relay.go`) but
  nothing on the client side had ever sent one. `go build`/`vet`/`test` clean; both named
  binaries (`meshghost.exe`, `meshghost-relay.exe`) rebuilt. Re-tested live: user left an
  idle core connected well past the old 60s failure point and confirmed no further
  timeout/reconnect messages appeared in either log — same connection, same player id, the
  whole time.
- Source: `internal/core/core.go` (`DefaultHeartbeatInterval`, `sendHeartbeats`);
  `internal/protocol/protocol.go` (`TypePing`/`TypePong`, `Ping`/`Pong`, pre-existing but
  unused by any real sender until now); `internal/relay/relay.go` (pre-existing `TypePing`
  handler).
- Notes: found by the user asking a question about the logs, not by the agent's own review —
  same pattern as the two same-day-follow-up gaps in the relay-safety hardening entry above.
  Not yet re-tested with a real second peer connected during the old failure window (to directly
  observe the leave/join churn this fixes from another client's point of view) — the fix is
  confirmed to stop the reconnect loop itself, not separately confirmed from a second peer's
  perspective.

## Automated Go-side test/debug tooling, and a real intermittent-failure bug it found

- Date: 2026-08-16
- **Established by the agent with the Go tools, not watched by the user** — which is the standard
  for `internal/`+`cmd/` per CLAUDE.md. Nothing here touches an adapter or a running game.

### The bug this found (real, pre-existing, now fixed)

- `internal/transport`'s `TestOversizedLineWithNoDelimiterClosesConnection` and
  `TestIdleTimeoutClosesConnection` both did `server := FromConn(conn)` and *then* assigned
  `server.MaxLineBytes` / `server.IdleTimeout`. `FromConn` starts the read loop **before it
  returns**, so those assignments race `readLoop`'s own read of the same fields — precisely the
  race `transport.go`'s `MaxLineBytes` doc comment already warned about and told callers to avoid
  by using `FromConnWithLimits`. Production code had been fixed; these two tests had not.
- Symptom when `readLoop` won the race: the limit stayed at the 64KiB/60s default, the test's
  8192-byte write never tripped it, no disconnect arrived, and the test failed on its 2s timeout.
- **Found by `go test -count=10 ./...`**, which failed once. `-count=1` and `-count=2` had both
  passed repeatedly beforehand, including a `-count=3` full-suite run minutes earlier.
- Fixed by switching both to `FromConnWithLimits`, which sets the fields before starting the
  goroutine. Verified with `-count=60` on the package (clean) and a repeat of the original
  `-count=10` full-suite run (clean). The package also got measurably faster, consistent with the
  diagnosis: it no longer sometimes waits out a 2s timeout.

### What was added

- `.github/workflows/ci.yml` — build, vet, `go test -race -count=3` on Linux, a fuzz campaign, and
  a Windows build+test job, on every push/PR. **Before this the repo had no CI for the Go code at
  all**; `release.yml` was the only workflow.
- `release.yml` now runs vet + tests before it builds and publishes. It previously went from
  checkout straight to build-and-zip, so the one artifact users actually download was the only Go
  build in the repo that nothing verified.
- `internal/e2e` — builds and launches the real `meshghost-server.exe`/`meshghost.exe` and drives a
  real adapter over the bridge. Covers `cmd/`'s flag/config wiring, which nothing else did, and
  replaces the by-hand `run-relay-loopback.bat` + `run-core-*.bat` loopback check. Its adapter
  reconnects, because `internal/core` deliberately closes a bridge connection when the relay is
  unreachable (see `core.go`'s bridge `hello` handler) and every real adapter has that loop.
- Fuzz targets for the three parsing layers, with the properties chosen to be non-tautological:
  state validity is unchanged by a marshal/unmarshal forward, accepted positions cannot become
  ±Inf when narrowed to float32, and the framing layer never delivers past its line limit.
- `internal/relay/leak_test.go` — goroutine-leak and connection-slot-leak tests. Both pass; no leak
  exists. Worth keeping because a relay holds sessions for hours and nothing else asserted teardown.
- `dev-scripts/run-gotests.bat` — the whole local gate in one command.

### Fuzz campaigns actually run (all clean, no failures)

- `FuzzValidateStateIsStableAcrossTheWire`: 23.3M executions.
- `FuzzValidPositionsSurviveNarrowingToFloat32`: 16.5M executions.
- `FuzzReadLoopNeverExceedsItsLineLimit`: 8.7M executions.
- `FuzzRelaySurvivesArbitraryLines`: 3.3M executions.
- The e2e round-trip test was negative-controlled: dropping `-loopback` from the relay makes it
  fail with its own diagnostic, so it can detect a break rather than merely passing.

### Two environment facts worth not rediscovering

- **`-race` cannot run on this machine.** `gcc` on `PATH` resolves to a devkitPro MSYS2 copy whose
  headers cgo can't use, and the real MSYS2 GCC 15.1.0 can't compile Go 1.22's `runtime/cgo`
  (its internal `-Werror` flags ignore `CGO_CFLAGS`). No WSL installed either. This is why the
  race detector runs on `ubuntu-latest` in CI, where it needs no toolchain setup — the Go code is
  platform-agnostic, so a race there is a race here. A second instance of CLAUDE.md's
  "a build tool on `PATH` may silently resolve to the wrong install".
- **The relay fuzz target must discard `log` output.** With logging on, the fuzzer finds valid
  hellos quickly and the resulting log volume — not the relay — collapses throughput to zero for
  ~18s at a stretch. Diagnosed by subtraction after two wrong guesses (a slot leak and a goroutine
  leak, both disproven by the leak tests above).

## CI's first real run: no data race, one over-strict test of my own

- Date: 2026-08-16
- **Established by the agent from the CI logs** (`gh run view 31927088210 --log-failed`), not
  watched by the user.
- The `-race` job's first execution ever — the check that could not be run locally. Result:
  **no data race anywhere.** `cmd/meshghost`, `cmd/meshghost-relay`, `internal/core`,
  `internal/e2e`, `internal/protocol` and `internal/transport` all passed clean under
  `-race -count=3` on Linux, including the e2e tests that launch the real binaries.
- The one failure was `TestNoGoroutineLeakAcrossManyConnections`, added the same day, failing all
  three runs with `got message type "leave", want "welcome"`. Not a leak and not a race: the test
  used `expectWelcome`, which requires the Welcome to be the *first* message received.
- **The underlying relay behaviour is real and benign**: a joining client is added to its room
  before its Welcome is sent, so a peer disconnecting at that moment can have its Leave forwarded
  to the newcomer first. `internal/core` ignores a Leave for a player it never knew about, so
  nothing is broken on the wire — but a test asserting on first-message ordering will fail on a
  busy room. Fixed by skipping ahead to the Welcome (`awaitWelcome` in `leak_test.go`).
- Worth noting for future flake-hunting: this passed locally every time, including at `-count=20`
  and with `GOMAXPROCS=2`, and only ever failed on CI. Not everything reproduces on this machine.

## Selectable transport (`tcp`/`udp`/`quic`) — 2026-08-16, established with the Go tools

Per `CLAUDE.md`'s split, all of the below is Go-side and was confirmed by running the tools
directly, **not** by watching a game. Nothing here is a claim about anything on screen.

- **All three transports carry a real session through an unmodified relay.**
  `TestRelayOverUDP`, `TestRelayOverQUIC`, and `TestRelayMixesAllThreeTransportsInOneRoom`
  (`internal/relay/relay_transport_test.go`): hello, welcome, join and forwarded state, with
  `internal/relay` containing no transport-aware line.
- **A room really can mix transports.** Three clients, one each on tcp/udp/quic, all see each
  other's joins and state. This is what makes the setting a feature rather than a way to
  partition the player base.
- **The shipped binaries can actually turn it on.** `internal/e2e`'s
  `TestReleaseBinariesRoundTripAGhostOnEveryTransport` launches the real `meshghost.exe` and
  `meshghost-server.exe` with `-transport udp` / `-transport quic` and drives a ghost through the
  full bridge → client → relay → client → bridge round trip.
- **`Send` used to issue two writes**, payload then `'\n'` — invisible over TCP, two datagrams per
  message over UDP. Fixed, and `TestSendIssuesExactlyOneWritePerMessage` was confirmed to fail
  against the old version by reverting it and watching it report 4 writes for 2 messages, rather
  than assumed to.
- **Reliability behaves as designed under real loss.** With a deterministic loss-injecting proxy,
  a `Send` payload survives its first 3 datagrams being dropped and is delivered exactly once,
  while a `SendUnreliable` payload is dropped and never retransmitted. The reliable test was also
  confirmed to fail with the retransmit loop disabled.
- **TCP and UDP genuinely share a port number** (`TestTCPAndUDPShareAPortNumber`), so `tcp,udp`
  costs one port. QUIC cannot share with `udp` and has its own.
- **quic-go exposes a working `ExportKeyingMaterial`** over a TLS 1.3 connection
  (`TestHandshakeIsTLS13`). This was the open question gating the shelved room-code
  channel-binding design in `ideas.md` — it would drop straight into `quic`.
- **The UDP demultiplexer survives hostile input.** `FuzzListenerSurvivesArbitraryDatagrams`,
  1,482,717 executions in 30s, no crashes and no wedged listener. Worth recording *how* that
  number was reached: the first version of the target dialled a fresh socket per execution and
  stalled at ~20k execs with the rate pinned at 0/sec, while still reporting PASS — a green run
  that was measuring almost nothing. Replacing the liveness check with a raw hello on an
  already-open socket raised throughput ~70x.
- **Full suite green at `-count=10`**, per `CLAUDE.md`'s concurrency rule, including
  `internal/e2e`.

## Transport discovery (`transport: "auto"`) — 2026-08-16, established with the Go tools

- **A real client given only a tcp address finds and uses quic.** Confirmed twice: by
  `internal/e2e`'s `TestAutoTransportUpgradesToQUIC` (real binaries, `-transport auto`, full ghost
  round trip, asserting on the client's own log), and by hand against a relay serving all three —
  the client logged `relay offers tcp:48001, udp:48001, quic:48003 — using quic at
  127.0.0.1:48003`. It could not have guessed that port; quic runs on a different one.
- **Discovery discloses nothing without the room code.** `TestQueryOnlyStillRequiresTheRoomCode`:
  a wrong code gets a `reject`, not a transport list, and the correct code gets the list. This is
  the property that made "ask before joining" acceptable rather than a new pre-auth endpoint.
- **A query never joins.** `TestQueryOnlyReturnsTheTransportListAndDoesNotJoin` watches an
  existing room member and asserts it sees nothing at all — no `join`, no `player_id` consumed.
  That is the entire point of asking first rather than joining and reconnecting.
- **An offer-less relay is harmless**, replying with an empty list, which every pre-existing test
  server exercises for free.
- **Full suite green at `-count=10`** after the change, including `internal/e2e`.

## UDP per-connection token — 2026-08-16, established with the Go tools

Added after the user asked whether the CelesteNet UDP measures were needed here. They were: the
address-validation cookie gated *admission* only, so a connection was identified by source
address alone and anyone able to spoof a live client's ip:port could inject state into its
session — the gap `internal/README.md` already cited CelesteNet's token as closing.

- `TestInjectionFromTheRightAddressWithTheWrongTokenIsDropped` forges a correctly-framed
  datagram from the client's **real** source address with a token that is merely wrong, and
  confirms it is dropped **and** that the targeted session keeps working afterwards.
- `TestUnframedDatagramsAreIgnored` covers the bypass: bare NDJSON lines were previously valid
  unreliable payloads, so leaving them accepted would have made the token optional in practice.
- Fuzzing re-run against the new framing: **4,837,744 executions in 25s**, 27 new interesting
  inputs, no crashes and no wedged listener, with seeds added for every token-carrying frame
  shape.
- Full suite green, including `internal/e2e` driving the real binaries over udp.

Technique only — no CelesteNet code was read or copied; the reference is this repo's own
prior-art summary, and a per-connection secret is generic (TCP sequence numbers, SYN cookies,
QUIC connection IDs).

## A real bug found in review, and a test that first failed to catch it — 2026-08-16

Found by a documentation-writing pass reading `udpconn` closely, not by any test.

**The bug:** a reliable udp payload was acknowledged *before* delivery. Delivery into a `Conn` is
non-blocking and drops when the 64-deep queue is full, so under a burst the sender would receive
its ack, never retransmit, and the dedup record would have suppressed the retransmit anyway — a
`join`, `leave` or `welcome` could vanish while `Write` reported success. Fixed by delivering
first and acking only on success; a duplicate is still re-acked, since a lost ack is exactly why
a sender retries.

**Worth recording more than the bug:** the first regression test written for it **passed against
the buggy code**. It flooded and drained through the public API, and the receive queue was not
reliably full at the deciding instant, so the failure never triggered — a green test that proved
nothing, the same shape as the earlier fuzz target that reported PASS while frozen at 20k
executions. Replaced with one that saturates the queue directly and asserts the precise property
(**an undeliverable payload must not be acknowledged**), then confirmed to fail against the
restored bug before being kept.

Also fixed in the same pass: `contract.md` claimed `auto` was the shipped client default (it is
`udp`), `internal/README.md`'s CelesteNet section still said the UDP token was hypothetical, and
a doc comment in `relay.go` had been merged onto the wrong function.

## 2026-08-16 — "use of closed network connection" in the relay log was ours, and is fixed

**Established with the tools** (real binaries, reproduced then re-run after the fix), prompted by
the user spotting the line in a relay window and asking for it to be checked rather than assumed.

- **Reproduced deterministically.** A client on `-transport=udp` (the shipped default) made the
  relay log `relay: connection error: read tcp ...: use of closed network connection` immediately
  before **every** successful join. On `-transport=tcp` it never appeared.
- **Cause, ours entirely.** The relay closes the tcp connection itself after answering a
  `query_only` transport-discovery hello (`internal/relay/relay.go`). Its read loop was parked in
  `scanner.Scan()`, so that Close came back as `net.ErrClosed` — and `transport.fail()` only
  special-cased `io.EOF`, so it reported our own deliberate close through `OnError`.
- **Fixed in `internal/transport`, not the relay**, because every deliberate `Close()` in the
  codebase had the same problem (rejected hello, hello timeout, oversized line, rate-limit trip) —
  each already logs its own reason, then got a second, scarier line about it. `net.ErrClosed` can
  only be produced by this process closing the socket, never by a peer or the network.
- **Verified after the fix, against rebuilt binaries:** a udp client now joins with no error line
  at all, and — the control that matters — a client killed outright is *still* reported
  (`wsarecv: An existing connection was forcibly closed by the remote host`). Suppressing our own
  close did not suppress real ones. `OnDisconnect` still fires in both cases.
- Regression test: `TestLocalCloseDoesNotReportAnError` (`internal/transport`). Full suite green,
  plus `-count=10` on transport/relay/core/netx since this touches a read loop.

Cosmetic in effect, but it put an error line at the top of the very log a remote tester is now
asked to send back — which is why it was worth chasing rather than explaining away.

## 2026-08-16 — CI's race job found a relay race, and chasing it found a worse bug in the core

**Established with the tools.** CI run 31949407557 failed the race job on an intermittent
`TestOversizedPositionDropped` ("c2 unexpectedly received join") — a test that had nothing to do
with joins, which is what made it misleading.

- **Bug 1, the relay (pre-existing).** A joining client's roster was captured atomically with the
  add (`tryAddAndSnapshotRoster`), but its join was then broadcast to `allExcept(newID)` — a
  SECOND, later lock acquisition. A client that joined in the window between another client's add
  and its broadcast was therefore included, despite already having been told about that client in
  its own welcome roster. Fixed by forwarding to the roster captured with the add; `allExcept` had
  no other callers and was removed.
- **Bug 2, the core (worse, found by the test written for bug 1).** The relay adds a client to the
  room *before* sending that client's welcome, so a concurrent joiner's `join` can arrive ahead of
  our own `welcome`. `Welcome` assigned `c.roster` outright, erasing that peer — and states from
  anyone outside the roster are dropped by design, so **two players starting at the same moment
  could simply never see each other for the whole session.** Welcome now merges; the roster is
  cleared explicitly on disconnect instead (it was relying on Welcome's replace as its reset).
- **Not reproducible locally by luck, reproducible by construction.** 300 local runs of the
  failing test, then 50+ full-package runs and 100+ targeted runs, never reproduced bug 1. A test
  asserting the *invariant* under concurrent clients
  (`TestJoinIsNeverSentForAPlayerAlreadyInTheWelcomeRoster`) reproduced bug 2 within 100 runs on
  the first try. Regression tests for both, plus `TestJoinArrivingBeforeWelcomeIsNotErased` in
  `internal/core`.
- **Local tooling gap re-measured** (Go 1.25): `-race` still cannot run here — the `gcc` on PATH is
  devkitPro's (fails on `stddef.h`), MSYS2's own GCC 15.1 fails inside `runtime/cgo`, and
  `wsl.exe` is present with no distro installed. `dev-scripts/run-gotests-race.bat` now probes for
  a usable compiler and reports the gap instead of it being invisible;
  `run-gotests-stress.bat` (`-count=10 -shuffle=on -cpu=1,4`, ~3-4 min, e2e excluded) is what
  works today. Full suite green after both fixes.

**Caveat kept deliberately:** a `join` arriving before `welcome` is still possible on the wire.
Fixing that relay-side would mean holding the room lock across a network write to a brand-new
connection; tolerating it in the core is cheaper and robust to any relay that behaves this way.

## 2026-08-16 — A release failed on a port that was free for tcp but forbidden for udp

**Established with the tools**, from the failed Release run's own log. Three e2e tests failed at
once on the windows-latest runner — both udp and quic subtests of
`TestReleaseBinariesRoundTripAGhostOnEveryTransport`, plus `TestAutoTransportUpgradesToQUIC`.

The relay said exactly why, and it was not our code:

    listen udp on 127.0.0.1:63503: bind: An attempt was made to access a socket
    in a way forbidden by its access permissions.

That is Windows `WSAEACCES` on a **udp** bind, for a port the test had obtained seconds earlier by
listening on **tcp**. `e2e_test.go`'s `freePort` asked the OS for a tcp port and handed the number
to the relay, which binds the same number for udp (and another for quic, udp underneath) — two
different questions that were being treated as one. Windows can answer them differently:
Hyper-V/WinNAT reserve blocks of the ephemeral range, and a udp bind inside one is refused outright.

`freePort` now probes udp on the candidate number as well and asks for another if it fails.

**Not reproducible on the dev machine, and the reason is worth recording:**
`netsh int ipv4 show excludedportrange udp` lists no exclusions here, so a udp bind never fails on
a tcp-free port. The failure needs a machine that reserves ranges, which the runner does and this
one does not.

**Luck-of-the-draw, which is worse than a reliable failure**: the same code had passed on the
Windows job minutes earlier (CI run 31952340980), so re-running the release would have "fixed" it
and taught us nothing. Full suite green after the fix, e2e repeated at `-count=3`.

## 2026-08-16 — The client shows a console under Wine by default (Windows side verified)

**Established with the tools**, from the user's suggestion: if MeshGhost is going to be invisible,
it should only be invisible where we have actually watched it clean up after itself.

- **On real Windows it stays hidden.** Ran the freshly built `meshghost.exe` here: no window
  appeared and the log contains no Wine line, confirming `runningUnderWine` does not false-positive
  on the platform where hidden IS the feature.
- **Wine detection** resolves `wine_get_version` in ntdll — Wine's own ntdll exports it and real
  Windows has no equivalent. Traceable, not from memory: Wine's `dlls/ntdll/version.c`, and the
  long-standing documented answer to "how do I detect Wine".
- **It is only a default.** `-show-console` or `show_console` in config.json still decides;
  regression tests cover both the four-way default matrix and a config file overriding it.
- **Caught while writing it:** the shipped mod-folder config template had `"show_console": false`
  set explicitly, which would have overridden the new default and disabled the safety valve for
  exactly the Proton users it exists for. The key is now absent from the template on purpose, with
  a comment saying why, since absent means "decide per platform".

**Untested, and the whole point of the change:** that the window actually appears under Proton, and
whether the client there dies with the game at all. If it turns out cleanup works fine through
Wine, this default becomes noise and should be reconsidered — noted in the code as well.

**What to ask the Proton tester, specifically:** after quitting the game, is the MeshGhost console
window still open? That single question separates the two outcomes that matter. Gone means the
Wine-hosted client dies with the game and the whole autostart lifecycle holds there — at which
point the visible console is noise and the default should be reconsidered. Still open means the
orphan case is real under Wine, and `-exit-with-pid` does not survive that boundary; the window is
then doing its job, and the fix belongs in the mod (a native client started by hand, per the
reuse path, avoids the problem entirely). Either answer is worth having; "it worked" alone is not.

## udp's reliable path was reliable but NOT ordered — found and fixed 2026-08-16

**Established with the Go tools, not by watching a game** — `internal/netx/udpconn` and
`internal/core` are deterministic code against a contract we own, which is exactly the case
CLAUDE.md says to confirm with tests rather than a live session.

- **The claim that was wrong.** `contract.md` promised the reserved event plane would be "reliable,
  ordered", and `udpconn.Write`'s doc comment told callers they "get TCP-like semantics". The
  receive path delivered every payload the moment it arrived and deduped by seq, with no
  resequencing buffer — so retransmission bought delivery, never order. `udp` is the client default.
- **Confirmed before anything was changed, in two places.** At the wire level, arming the lossy
  proxy to drop exactly one datagram made `leave` overtake `join`: delivered `{"type":"leave"}` then
  `{"type":"join"}`, the reverse of the write order. At the consumer level, driving
  `handleRelayMessage` with that same reordering left the departed peer sitting in the roster —
  `delete` on an absent key is a no-op, so the late `join` re-adds someone already gone and nothing
  will ever remove them again. **Their ghost would stay on screen for the rest of the session.**
- **Reachability**: needs a join's first datagram lost *and* the peer leaving inside the ~6s
  retransmit budget (`retryInterval` 250ms × `maxRetries` 24). Rare, not theoretical — and silent,
  since every layer reports success.
- **Fixed at the transport, not the consumer.** A guard in `internal/core` would have been smaller
  but would have *corrected* the symptom while the cause kept running, which is the shape
  `adapters/_template`'s no-bandage rule names. `udpconn` now holds out-of-order payloads in a
  bounded window and releases them in sequence. Detail and the rejected options: the ADR in
  `architecture.md`.
- **Verification**: `dev-scripts/run-gotests.bat` green (build, vet, full suite twice, including
  `internal/e2e`), plus `-count=10` on `udpconn`, `core`, `relay` and `transport`. The race detector
  could not run locally — no C toolchain on this machine — so that remains CI's job, as CLAUDE.md
  already states.
- **Two pre-existing properties deliberately kept**: a buffered payload is not acked until actually
  delivered (the "ack only what was delivered" rule, which exists because `deliver` drops on a full
  queue), and window overflow declines to hold rather than dropping, leaving the sender's retransmit
  to cover it.

## quic became the default path, and shares the relay's port — 2026-08-16

**Established with the tools, not by watching a game.** Confirmed against real binaries on this
machine; no adapter or game involved.

- **The mismatch that prompted it**: the client's `-transport` defaulted to `udp` while the relay
  served `tcp` only, so *every* default session asked for something it could not have and fell back
  to tcp. The client's stated default was never honourable by a default relay.
- **Now**: client defaults to `auto`, relay to `tcp,quic`. Confirmed live —
  `core: relay offers tcp:7796, quic:7796 — using quic at 127.0.0.1:7796`, with the loopback ghost
  rendering throughout.
- **quic shares `-addr`'s port number** (`tcp:7796` and `quic:7796` above, tcp and udp being
  separate port spaces). This was a NAT decision: serving quic by default would otherwise have
  turned hosting from "forward 7777" into "forward 7777 and 7780". The relay now also prints
  `to accept players from outside this machine, forward: 7796/tcp (tcp), 7796/udp (quic)` at
  startup, protocol by protocol, because those are two separate rules on most routers.
- **Serving `udp` and `quic` together refuses to start**, with the actionable message rather than
  quietly relocating quic to a port nobody forwarded. Confirmed: *"serving both udp and quic needs a
  port for quic: udp has already taken 127.0.0.1:7794's udp port... Pass -listen-quic (e.g.
  127.0.0.1:7780)"*. `dev-scripts/run-relay-loopback.bat` is that case and now passes the flag.
- **What this does and does not buy.** Encryption against a passive observer, including the room
  code — but **not authentication**: `quicconn` uses a self-signed in-memory cert with
  `InsecureSkipVerify`. Also the only transport where `contract.md`'s lossy state plane is actually
  lossy, since on tcp `SendUnreliable` *is* `Send`. Both recorded in the ADR.
- **Verification**: `dev-scripts/run-gotests.bat` green (build, vet, full suite twice, including
  `internal/e2e`, whose transport tests set `-listen-quic` explicitly and were unaffected).

## The synthetic-peer rig could only ever test tcp — fixed 2026-08-16

`cmd/meshghost-fakeadapter` never set `core.Core.Transport` at all, so every synthetic peer
inherited `netx.Kind`'s tcp zero value. **Both load-test tiers in `dev-scripts/README.md` were
therefore tcp-only**, which is why the transports shipped that same day had no sustained-load
coverage — the rig structurally could not produce it. Added `-transport tcp|udp|quic|auto`, parsed
strictly like `cmd/meshghost`'s (a typo must not silently downgrade to the tcp zero value).
Confirmed: `-transport udp` through the new fault proxy logged `using udp`, dropped 43 of ~366
datagrams at a 10% loss setting, and kept rendering ghosts.

### Two transport-divergence bugs, found by a loopback re-test and the suite it prompted

- Date: 2026-08-17
- Observed: agent-run from process logs and tests; the trigger was a user-watched loopback session.
- **A clean game-close was being treated as a network blip.** With `resume.v1` on, quitting the
  game made the relay log `p1 dropped from room "default" — holding its identity for 20s`, so every
  other player would have watched a frozen ghost for the whole grace window. The core discarding
  its own resume token was never enough: that only decides where the NEXT connection lands and says
  nothing to the relay about this one. Fixed by a voluntary `leave` sent client -> relay before a
  deliberate hangup. An unexplained drop still gets the grace, which is the whole point.
- **`quicconn.Close()` discarded the last message written before it.** It closed the stream and
  tore down the QUIC connection in the same breath; closing a stream only signals FIN, and the
  bytes cannot be delivered once the connection is gone. Confirmed by the goodbye above landing on
  tcp and vanishing on quic, and by the regression test failing when the fix is reverted.
  **This silently broke every send-before-close in the project on quic** — including the relay's
  `Reject`, so a client refused for a wrong room code saw a bare hangup instead of the reason,
  which is the entire thing `rejectAndClose` exists to prevent. Fixed with a bounded linger before
  the connection teardown; `Close()` itself still does not block.
- **A third divergence, found by the new conformance suite on its first run and NOT fixed:** udp
  signals nothing on close, so a peer waits out `transport.DefaultIdleTimeout` (60s), against an
  immediate RST on tcp and ~17s on quic. Left as a documented skip with the consequence named,
  because the fix is a new control frame in the project's most exposed parser and deserves its own
  pass. The goodbye above covers the common case there regardless.
- Notes: the first bug was found only because the user asked "no need to test loopback?" after I
  had moved on — the earlier on-screen confirmation was against an older build, and the join and
  close paths had changed under it since. Worth recording as a methodology point, not just a bug:
  **a confirmation is against a build, not against a project**, and it goes stale the moment the
  code it covered changes.

### World custody (`world.v1`) — the relay holds a world it cannot read, and hands it on

- Date: 2026-08-17
- Established with the Go tools, not on screen: no adapter uses this plane and no game was
  involved. Recorded under CLAUDE.md's "the Go client/server is the opposite case" rule.
- **What was confirmed.** `dev-scripts/run-gotests.bat` green (build, vet, the whole suite twice,
  including `internal/e2e`), plus `internal/relay` and `internal/core` at `-count=10`. The race
  detector could not run locally (no cgo toolchain here, as CLAUDE.md already notes); CI covers it.
- **The end-to-end proof is `TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner`**, which
  drives the real `meshghost.exe` and `meshghost-relay.exe`: a host writes two entities, its
  PROCESS is killed outright (no goodbye, no release), a second client claims the authority and is
  handed the same world byte-for-byte, and a third client that was never present joins and sees the
  current world. That is the scenario the feature exists for and the one no in-process test can
  reach.
- **Soaked under real loss.** `cmd/meshghost-fakeadapter` with `-host-entities 5 -migrate-every 2s`
  through `cmd/meshghost-netsim` at 5% loss / 5% reorder / 20ms latency over udp: 4 clients, all
  four planes on at once (events, leases, escrow, world), 2 minutes, 40 handovers, ~5000 entity
  writes, **no invariant violations**. The same run on tcp and on lossless udp was also clean.
- **The soak found two things reading did not**, both adapter-facing rules rather than relay bugs,
  and both of which passed cleanly on tcp first — the shape of thing that ships:
  1. **A lossy write replaces the whole blob**, so a blob mixing a continuously-superseded field
     with one that must not regress gets dragged backwards wholesale by an inbound reorder, and the
     relay's copy becomes the stale one that later snapshots propagate. Discrete state and
     continuous position belong on separate keys. The rig now models that.
  2. **An adoption must always send exactly one snapshot, empty world included**, or a new host
     cannot tell "nothing to adopt" from "my adoption has not landed yet" — and a host that guesses
     wrong renumbers from a stale view and rolls the world back for everyone.
- Two checker bugs were also found and fixed, both of which had accused a correctly-behaving relay:
  a lease *renew* re-broadcasts `granted` (so arming adoption on any grant was wrong), and the
  rig's exclusivity check tracked one holder across all keys, which only worked while one key
  existed.
- Detail: the ADR in `architecture.md` (2026-08-17, world custody), `contract.md`'s World custody
  section, and `internal/relay/world_test.go`, whose four "corrections" tests fail against the
  obvious implementation.

### A maximal event and a committed escrow are too large for a udp datagram (pre-existing, not fixed)

- Date: 2026-08-17
- Established by measurement while deriving the world plane's bounds, not by a failure in the
  field: a maximal `Event` marshals to **1321 bytes** and a committed `EscrowState` carrying two
  1024-byte blobs to **2294**, against 1182 usable (`udpconn.MaxDatagramBytes` 1200 minus 18 bytes
  of framing). Both fail `udpconn.checkWritable` — reliable plane included — and the refusal is
  only a `relay: send to pX failed:` log line, so the message is lost for that recipient and never
  superseded.
- Unreached today: nothing uses these planes at all. Recorded in `risks.md` as its own decision
  rather than fixed here, because shrinking the constants is a contract change.

## 2026-08-17 — The Go packages moved out of `internal/` and the module took its real path

**Track: agent-confirmed** (Go side — established with the tools, no game and no watching, per
this file's own two-track rule).

**What is now true.** The module is `github.com/Tsukino-uwu/MeshGhost`, and `protocol`,
`transport`, `bridge`, `core`, `relay` and `netx` (with `netx/udpconn`, `netx/quicconn`) live at
the repo root and are importable from outside. `internal/` holds `e2e` and nothing else. Design
and rationale: the 2026-08-17 ADR in `architecture.md`.

**How it was confirmed.**
- `go build ./...`, `go vet ./...`, and `go test -count=2 ./...` all clean, including
  `internal/e2e` (68.7s), which builds and launches the real `meshghost-server.exe` and
  `meshghost.exe` **by package path** — the only check that exercises the two build-path string
  literals, since those are not compile-checked.
- `go test -count=10 -shuffle=on -cpu=1,4` clean across `relay`, `core`, `transport`, `netx`
  (relay alone: 254s), per `CLAUDE.md`'s repeat-the-suite rule.
- **A throwaway module outside the repo**, with a `replace` directive, imported all six packages
  by their new paths, compiled, and ran — printing `protocol.Version`, a `core.Core` field, a
  `relay.Server` field and a `netx` kind. This is the only check that actually demonstrates the
  goal; the existing suite passes identically with the packages still private, so a green suite
  is not evidence for this claim.
- `git diff -M -C` showed the change as renames plus one-line import edits: 472 insertions
  against 471 deletions across 76 files, with no logic hunk anywhere.

**Reading older entries in this file.** Entries dated before 2026-08-17 name packages as
`internal/<pkg>/…`. Those map 1:1 to `<pkg>/…` — drop the `internal/` segment. **`internal/e2e`
did not move.** This file was deliberately not swept: it is a dated record, and rewriting a past
observation to match a later layout would falsify it. The same applies to `agent_docs/phases/`.

**Not covered by this entry.** Nothing about behaviour changed, so nothing here is a claim about
runtime behaviour beyond "the same tests still pass". No adapter was touched, built, or run.

### Red and Blue are byte-identical in RAM — one adapter covers both

- Date: 2026-08-17
- Observed: comparing `pokered.sym` and `pokeblue.sym` from the verified builds above — of 21,128
  symbols each, 20,460 are identical and 668 per side differ. Restricting to **WRAM** labels
  (`00:c***`/`00:d***`), **all 2,624 are identical, with zero differences.** The key four agree
  exactly: `wCurMap` `00:d35e`, `wYCoord` `00:d361`, `wXCoord` `00:d362`,
  `wPlayerDirection` `00:d52a`. Also `wSpriteStateData1` `00:c100`, `wWalkCounter` `00:cfc5`,
  `wPlayerMovingDirection` `00:d528`, `wCurMapHeight`/`wCurMapWidth` `00:d368`/`00:d369`.
- Source: `pret/pokered` build artifacts `pokered.sym` and `pokeblue.sym`.
- Notes: **this answers whether Red and Blue need separate handling: for our purposes, no.** The
  668 differing symbols are all ROM-side (species data, sprites, text) — the parts a *randomizer*
  cares about and a presence adapter does not. One address table, no per-version branching.
  Independently corroborated by Archipelago's own structure: `worlds/pokemon_rb` is a single world
  with logic shared, but ships **two** patch files (`basepatch_red.bsdiff4`,
  `basepatch_blue.bsdiff4`) — separate ROM patches, shared everything else, exactly the split the
  symbol diff predicts.

### Platinum: ROM matches the decomp's Rev 1 target, but nothing is built

- Date: 2026-08-17
- Observed: the user's `Pokemon - Platinum Version (USA) (Rev 1).nds` hashes to
  `0862ec35b24de5c7e2dcb88c9eea0873110d755c`, which `pokeplatinum`'s `README.md` documents as its
  **Rev 1** target.
- Source: `pret/pokeplatinum` `README.md`.
- Notes: **not built, and it is the only one of the four that cannot be with what is installed.**
  Its `INSTALL.md` needs `bison flex gcc git make ninja python arm-none-eabi-gcc p7zip libpng`;
  devkitPro's msys2 supplies the first several from its `msys` repo but has **no mingw64/ucrt64
  repos**, so `mingw-w64-ucrt-x86_64-arm-none-eabi-gcc` and `mingw-w64-x86_64-libpng` are
  unavailable there. Needs a standalone MSYS2 or WSL. **Also note `pokeplatinum` describes itself
  as a WIP decompilation**, unlike the complete-and-matching pokered/pokecrystal/pokeemerald/
  pokefirered — so symbol coverage may be partial even after a successful build, and that should be
  checked before assuming a Platinum adapter is a tier-2 lookup.

### NOTE: `internal/X` package paths throughout this file predate the 2026-08-17 move (2026-08-18)

- Date: 2026-08-18
- Confirmed by: `ls internal/`, `git log --diff-filter=D -- internal/README.md`, and the ADR in
  `architecture.md`. No runtime facts here; this file is append-only, so a bookkeeping note is the
  only way to correct ~60 stale paths without rewriting dated records.
- **The six library packages left `internal/` for the repo root on 2026-08-17** — `protocol`,
  `relay`, `core`, `transport`, `bridge`, `netx` — so they can be imported from outside the module,
  with no stability promised. **Read every `internal/X` in the entries above as `X/`.**
- **`internal/` now holds only `e2e`**, which really does still live there, so `internal/e2e` is
  correct wherever it appears.
- **`internal/README.md` was deleted** in "Let an outside program actually use this, in Go or in
  anything". Entries citing it are citing a file that no longer exists; its content became
  `docs/networking.md` and `docs/security.md`.
- **Deliberately not rewritten line by line.** Each entry was correct on its own date, and this
  file's value is that it records what was true when. The same note now sits at the top of
  `phases/phase3.md` through `phase8.md`.

### CORRECTION: the two "`-race` cannot run on this machine" entries above are wrong (2026-08-18)

- Date: 2026-08-18
- Confirmed by: **the Go tools, by me, no game and no user watching** — the standard `CLAUDE.md`
  sets for the Go half. Appended rather than editing, per this file's append-only rule.
- **Superseded entries:** the 2026-08-16 "`-race` cannot run on this machine" entry and the later
  "Local tooling gap re-measured (Go 1.25): `-race` still cannot run here". Both were correct that
  devkitPro's `gcc` cannot build cgo; both were **wrong that no local `-race` was possible**.
- **The working recipe** is `CC=C:/msys64/mingw64/bin/gcc.exe CGO_ENABLED=1` **plus**
  `PATH=/c/msys64/mingw64/bin:$PATH`. Setting `CC` alone fails (`runtime/cgo: cgo.exe: exit status
  2`) because the compiler needs its own `as`/`ld`/headers resolvable ahead of devkitPro's copy —
  the same wrong-install-on-`PATH` trap already recorded for `cmake` and `cmd`.
- **Run by me while auditing the docs:** `go test -race -count=1` clean on `protocol`, `relay`,
  `core`, `netx`, `netx/quicconn`, `netx/udpconn`. `dev-scripts/run-gotests-race.bat` is the
  packaged form; `testing.md`'s Race detector section holds the recipe and caveats, and
  `pitfalls.md` the diagnosis.
- **Read every earlier claim in this file that the race detector is CI-only as dated, not as a
  property of the machine.** CI's Linux `-race` job is unchanged and remains the authority.

### CORRECTION: `MaxEventBytes`' "comfortably under a datagram" claim, now pinned by tests (2026-08-18)

- Date: 2026-08-18
- Confirmed by: reading `protocol/online.go` and `netx/udpconn/world_bounds_test.go` — source
  reads, not a runtime observation.
- **`protocol.MaxEventBytes` (1024) does NOT keep a maximal `event` envelope under
  `udpconn.MaxDatagramBytes` (1200).** Its own doc comment used to say it did; the comment was
  corrected on 2026-08-18 and now states the real relationship, naming the two tests that assert
  it: `TestMaximalEventDoesNotFitAUDPDatagram` and
  `TestMaximalCommittedEscrowDoesNotFitAUDPDatagram`.
- **The constants are unchanged** — 1024 still, and the underlying risk (a maximal event or a
  committed escrow is undeliverable to a udp peer) is still open and still unreached, since no
  adapter uses those planes. `risks.md` has the measurement; `bandages-core.md` the register entry.
- What changed is only that the documentation stopped asserting a relationship that does not hold,
  and that the gap can no longer widen unnoticed.

### 2026-08-18 — v0.9.5 released as a pre-release, and the asset hashes are real

**Track: measured by the agent with the tools (no game, no watching).**

Cut from `6128da1` via the Release workflow with `version=v0.9.5`, `prerelease=true`. Every step
green, including all three staleness gates (TEVI, Pseudoregalia, UE4SS runtime) and the first run
of the new `Hash the release assets` step. Three assets published: the Windows zip (24.1 MB), and
the Linux and macOS tarballs (20.0 / 20.6 MB).

**The hash table was verified end to end rather than assumed.** `docs/antivirus.md` and the
packaged README have told a user with a flagged download to compare their SHA-256 against the
Releases page since long before anything published one. Downloaded
`MeshGhost-linux-v0.9.5.tar.gz` from the release and hashed it locally:

    published:  c48239b6657d58d8ed1c128b51ed644bf2b622a5f6dfd6c46904913306149819
    downloaded: c48239b6657d58d8ed1c128b51ed644bf2b622a5f6dfd6c46904913306149819

Identical. So the advice now works for the person it was written for, which it did not before —
"a hash appeared in the release body" would not have shown that on its own.

**Marked pre-release on the user's call, for a specific reason:** TEVI's 2026-08-18 changes
(`bridge_ready`/`reject` handling, draining the bridge below the in-play gate, despawning peer
ghosts on a real main-menu return) and its DLL bump to `PluginVersion = "0.2.0"` have **not been
watched live**. The version bump in particular is a hard reject at the relay against any peer
still on 0.1.0. Not a defect — an untested change, labelled as one.

CI on `aad43cb` (the commit carrying all of today's Go work) passed beforehand: build, vet,
cross-compiles, the new gofmt gate, `-race -count=3`, and all eleven fuzz targets.

### 2026-08-18 — CORRECTION: the release hash table was redundant and has been removed

**Supersedes the v0.9.5 entry above**, which recorded the new `Hash the release assets` step as
making `docs/antivirus.md`'s "every release asset shows a SHA-256" claim true for the first time.

**That claim was already true.** GitHub computes and displays a `sha256:` digest beside every
uploaded release asset, and returns the same value from the API
(`gh api repos/.../releases/tags/v0.9.5 -q '.assets[].digest'` — checked, and it matched our table
byte for byte). The audit that prompted the feature checked whether the WORKFLOW published a hash,
found it did not, and concluded the docs were wrong — without checking whether GitHub published
one.

So the step was removed the same day and the release body is now just the generated changelog. The
verification in that earlier entry — downloading the asset back and re-hashing it — was real and
its result stands; it simply proved a number GitHub was already publishing.

**The durable part is the mistake, not the feature.** "Our code does not do X" and "X does not
happen" are different claims, and the gap between them is where a whole unnecessary feature fitted.

### 2026-08-18 — Autostart works in all four adapters, confirmed live

**Track: user-confirmed on screen, plus process-level checks the agent ran.**

Every adapter now starts its own client and takes it down with the game. Pseudoregalia has since
2026-08-16; TEVI, Emerald and Crystal were added today.

- **TEVI**: launched with no client running; a core appeared whose path was the mod folder's own
  copy, joined the relay over quic as p4 advertising plugin 0.2.0, and was gone after quitting.
- **Emerald, four ways**: start/close; two adapters in one emulator reusing one core; two
  emulators taking 7778 and 7779; closing one of two killing only its own core — verified by port
  ownership rather than by counting.
- **Crystal**: two instances, cores on 7778 and 7779, ROM guard reporting vanilla V1.0, closing
  one taking exactly one core.

**The bug worth remembering** was found only by the two-emulator case: the launcher spawned on
`BRIDGE_BASE_PORT` while the port walk was correctly reporting it busy, so the second copy got a
core that could not bind and exited instantly. It now spawns on the first port the sweep found
empty. Single-instance testing would never have shown it — the user asked for that case
specifically.

## Both renderers side by side, and the first two gaps it found — 2026-08-19

`MESHGHOST_COMPARE_TIERS` renders the one loopback ghost twice from the same peer state: spawned
two tiles right (the engine draws it), painted two tiles left (our pixel path). The user's request
and the intended dev default for this question — see each adapter's `FLAGS.md`.

It paid for itself immediately. **Within a minute of the first look**, three differences that
months of one-renderer-at-a-time testing had not surfaced:

### 1. The drawn tier moved at the NETWORK's pace, not the game's — fixed and confirmed

*"really stuttery/choppy"* while moving, and *"moving/catching up with the player too fast"*
next to a spawned ghost that *"properly follows"*. **One bug behind both.** A spawned ghost is
walked by the engine, tile to tile, over the game's own 16 frames (8 running); the drawn tier
painted the peer wherever the newest sample said it was. Samples arrive at the relay's rate in
jumps of whatever distance had accumulated, so the ghost moved at 20Hz in packet-sized steps.

The fix reuses the pacing the adapter already had for the local player (`STEP_DURATION_FRAMES`,
measured live 2026-08-11 and re-confirmed 2026-08-14): a drawn peer now glides between TILES over
those same frame counts, snapping only when the jump exceeds one tile (a warp, or first sight).
**User-confirmed after the fix: *"think they look/feel identical now"*.**

Also fixed alongside: the status line reported `drawn=0` while a painted ghost was on screen,
because the count was gated on the overflow tier's flag rather than on anything being painted.

### 2. A facing change drew as one static frame — fixed and confirmed

*"its not doing animations when standing still and doing facing directions"*, and asked what the
spawned one does differently: *"drawn one only 'faces the direction', it does not animate/move the
legs"*.

**A turn in place is an animation in this game, and a measured one.** `probes/turn_and_door_probe.lua`
sampled the player's own sprite frame by frame:

- the engine has a dedicated turn animation — animation numbers **8-11**, one per direction,
  against **0-3** standing and **4-7** walking;
- it lasts **exactly 8 frames, 92 times out of 92, with zero variance**;
- and 8 frames is exactly one `WALK_POSE_DURATIONS` hold, so what it plays is **one walk stride of
  the new direction** before settling into the standing frame.

The turn reaches the adapter as `anim=idle` with a new orientation, because the game reports
`runningState = 1` for it and anything that is not 2 classifies as idle — which is why the drawn
tier saw a facing change with no animation attached and drew one static frame. It now plays that
stride for those 8 frames. **User-confirmed: *"facing direction animations work now"*.**

### 3. Visible for a moment during a house transition — half fixed

**Entering is fixed and confirmed; leaving is not.** The two are not the same event.

*Entering*, the engine hides the PLAYER's own sprite for the whole transition — the invisible bit
(0x04) in the sprite's flags at +0x3e, set 44 frames before the map id even changes and cleared
once the new map is up, ~50 frames end to end. The drawn tier now stops on exactly that: while the
game will not draw its own player, there is nobody for a ghost to stand beside.

*Leaving*, that flag is NOT set — the sprite is live again (flags 03) while the screen is still
fading in, so the guard does not fire and the ghost paints through the fade. **The suspected cause
is the one the user predicted before any of this was built:** a fade dims everything the PPU draws,
and a ghost painted after the PPU is never dimmed by anything. Same family as a dark cave. The
probe now also samples the GBA's own blend registers (BLDCNT/BLDALPHA at 0x04000050/52 — hardware,
the same footing as the BGnCNT read that located the tilemaps), to find out whether the fade is
visible there before anything is built on it. **BLDY at 0x04000054 is write-only and reads as open
bus** (it came back as `BC01` during ordinary play), so the fade amount is not readable that way.

**The instrumentation for it was written, run, and taken straight back out** — a per-frame
`console.log` (facing changes, then 90 frames of object counts after each area change) and the
user's next words were *"its spamming the console lag, and the game is lagging"*. Removed within
the minute; the log went back to its normal cadence and the counters read the same as before.
`CLAUDE.md`'s rule earned again, in the smallest possible way: **a diagnostic can break the thing
it measures**, and BizHawk's console is expensive enough that once per frame is already too much.
Whatever measures this next has to sample into a buffer and print once, or write straight to a
file — not to the console, and not every frame.

## The comparison keeps paying: four more, and one of them was the SPAWNED tier — 2026-08-19

All found by looking at both renderers at once (`MESHGHOST_COMPARE_TIERS`), all **user-confirmed on
screen** the same session.

### A spawned ghost stuck in a running pose — fixed

*"the injected/spawned ghost gets stuck in a wrong pose/sprite after stopping after a run, the drawn
one looks fine"*, and then, precisely: *"it does idle->walk fine. but can't do run -> idle without
getting stuck in the run animation"*. We drive a run by issuing one run action per tile; when the
peer stops we simply stop issuing them, and the engine leaves the object parked on the last frame.
A walk ends on a standing frame by itself, which is exactly why only `run -> idle` showed it. The
ghost now asks the engine to face the way it already faces — the game's own way of settling a
character. **Confirmed: *"spawned ghost looks fine now, not getting stuck after running anymore"*.**

**This is the first defect the comparison found on the spawned side**, and it had been shipping.

### Door transitions, both directions — fixed, and the second attempt was the better design

Entering was fixed first with a hard cut on the engine hiding the player's own sprite. It worked,
and the user's comparison found something better in our own fix for the *other* direction:
*"leaving the house even looks better than entering the house"* — because leaving is carried by the
scene-brightness scaling, which FADES the ghost out with everything else, while entering snapped it
away. The flag is now only a backstop for the part of the transition where the screen is already
black, and the fade does the visible work both ways.

Neither signal alone would do: a dark cave is dim with the player perfectly visible, and the first
frames of a door are hidden while the scene is still bright. **Confirmed: *"leaving a house hides
the drawn ghost properly now"*, then *"enter/leaving a house looks great now"*.**

### Scene brightness, which is the gap the user predicted before any of this existed

Painted pixels are decoded from the CARTRIDGE palette, so they were always full brightness while
everything the PPU draws is dimmed by whatever fade, cave or night sits in palette RAM. The drawn
tier now measures the live OBJ palette the player's own sprite is using against the ROM palette its
own pixels came from, and scales its runs by that ratio: 32 reads a frame, nothing per peer, one
comparison when nothing is dimming. The house-exit confirmation above is this working.

**A negative worth keeping: BLDCNT is NOT the fade signal on this game.** It reads `1E40` through
ordinary play and through the transition alike, and BLDY at 0x04000054 is write-only, returning
open bus (`BC01`). The palette is where the fade is visible.

### And the one that took four attempts, because it was the wrong question three times

A drawn ghost looked choppy *while running*. Three movement models were tried and rejected on the
user's eyes — ramp from the last tile (snapped back every step), ramp from the current position
(each step covered a different distance in fixed time, so the speed visibly varied), and constant
speed at the engine's rate. The last is right and stayed; it was not enough, because the ghost's
movement was never the problem.

**The clue was which "running" mattered: the PLAYER's.** A drawn ghost is positioned relative to
the local player, against the adapter's SMOOTHED estimate of them, while being drawn at their real
pixel position — a mismatch this file has carried a note about since 2026-08-14. It is invisible
until the player moves, which is why it looked like a ghost problem.

Measured over 240 consecutive frames of a run: **the player's sprite position plus
`gTotalCameraPixelOffset` is constant to the pixel — 120,112, zero variance** — and that offset's
remainder mod 16 is the sub-tile phase, counting evenly by 2 every frame and handing over to the
tile counter with no discontinuity (tile 17 at -158 is 17.875; at -144 it is 17.0; tile 16 at -142
is 16.875). The player's continuous position is therefore its tile plus that phase, exactly, and
the estimate is out of the drawing path altogether.

## The comparison's last two answers: pin it, and give the core more delay — 2026-08-19

### Matching the engine's movement is not reachable, so compare mode stops trying

Five rewrites of the drawn tier's movement were judged by eye and none matched the spawned ghost.
The reason is structural: **a spawned ghost's timing comes from the engine's step scheduler** --
when a step starts, how long it is held -- and the adapter does not drive that scheduler. Ours
comes from when packets land. Average lag, smoothness and walk cadence can all be matched, and
are; the SHAPE of the engine's starts and stops cannot be.

So with `MESHGHOST_COMPARE_TIERS` the painted copy is now placed from the **spawned ghost's own
sprite**, mirrored across the player. Pixel-locked by construction, which makes every remaining
difference a rendering one -- occlusion, cave darkness, water reflection, palette, clipping --
which is what the mode was asked for. Real overflow peers have no spawned copy and keep the filter.

### The spawned ghost's own chop was ARRIVAL CADENCE, and `-interp` fixes it

**User-confirmed, and this is the significant one for shipping:** at the core's default `-interp`
of **100ms** the spawned ghost visibly chops during a run — *"it also feels like the spawned one
has some slight chop during running sometimes"*. At **250ms** the user's verdict was
*"it actually just looks 1:1:1 perfect now, drawn/player/spawn"*.

Nothing about the adapter changed between those two readings. The mechanism is plain once stated:
**an engine-driven ghost can only start a step when it has been told the peer moved**, and
positions arrive 8-20 times a second while the game steps on its own schedule. Whatever slack the
core does not absorb, the ghost shows as a hitch — and a tile game shows it more than most, because
a step is a discrete commitment rather than a nudge.

**This is a case for raising the shipped default, and it is the user's call**: 250ms costs a peer
being rendered a quarter-second behind where they are — a little over a tile at walking pace — and
buys motion nobody can fault. Recorded here rather than changed unilaterally, since it trades
latency for smoothness for every game, not just this one. Set for the test with a `config.json`
in the adapter's folder, which the adapter-spawned core reads from its own working directory: the
only way to change that flag without relaunching the emulator and losing the session.

## 2026-08-21 — HBlank multiplexing is closed by decision, not left open

**User-confirmed, in their own terms:** *"bizhawk don't support it, and we want to keep lua instead
of patching. so yee thats also confirmed i guess ?"* -- both halves, which are the two independent
reasons the 2026-08-21 ADR gives:

1. **The emulator cannot drive it.** BizHawk 2.11's `event` library, read out of the DLL rather than
   recalled, has no scanline or LYC callback of any kind.
2. **The alternative is ruled out on purpose.** The classic technique needs code inside the ROM, and
   BizHawk adapters are Lua-only so MeshGhost keeps working on top of an Archipelago seed.

(The third reason stands on its own and is a fact about the GAME rather than a choice: with 128
hardware entries and about five in use on a normal map, there is no sprite-count limit to beat.)

**Recorded as CLOSED rather than unscheduled**, because the difference matters: an unscheduled idea
invites someone to schedule it, and this one is attractive enough to come back otherwise.

### RULE CHANGE — the gate on this file tightened (2026-08-21)

- Date: 2026-08-21, user-directed, in these words: *"you are not allowed to claim anything is
  'verified' adapter/game wise before i confirm that its done visually myself... you should only
  verify/confirm the server/client things."*
- **From here on, no adapter/game-side entry about the BASE/VANILLA game may be added to this
  file on the agent's own evidence — not a probe log, a console read, or an agent screenshot.**
  Agent measurements live in `unverified.md` until the user confirms on screen. **Patched ROMs
  (Archipelago etc.) stay agent-confirmable visually — user's correction, same day** — as do
  Go-side facts (core/relay/transport/bridge/cmd). `CLAUDE.md` carries the rule.
- **The entry "how a character actually gets onto the water, measured on the player" (moved
  2026-08-25 to [../adapters/emulator/pokemon/emerald/VERIFIED.md](../adapters/emulator/pokemon/emerald/VERIFIED.md)) is
  hereby reclassified as UNVERIFIED under the new rule.** Its measurements also fed a diagnosis
  the user's screen later contradicted the same day — the correction is in `pitfalls.md` ("THE
  PAIR was wrong — and fixing it did NOT clear the symptoms"). Appended rather than deleted,
  because this file is append-only; treat `unverified.md` as its current home.

## All four adapters still run end to end after the doc/refactor pass — 2026-08-25

**Cross-game, so it lives here rather than in any one adapter's file.** Human-gated track: the user
watched each game and said so.

- Date: 2026-08-25.
- Observed: each adapter in turn against a loopback relay on one machine, one at a time on the
  same bridge port (7778), every other rig torn down between games. The user's words, per game:
  *"Emerald works"*, *"crystal works"*, *"TEVI works"*, *"pseudoregalia works"*.
  - **Emerald** — vanilla `(USA, Europe)`, dev settings (`-interp=0ms`, `-min-send=10ms`,
    relay `-send-hz=100`), ghost offset 2 tiles to the side.
  - **Crystal** — V1.0, **shipped** settings (250ms interpolation, 20Hz), ghost at offset 0 and
    therefore trailing. The user confirmed it works and asked for Emerald's side offset instead;
    that change is in the adapter and unwatched — `crystal/UNVERIFIED.md`.
  - **TEVI** — Steam install. The mod started its own core, found 7778 already taken, and attached
    to the running one instead: the port-collision behaviour working as designed, seen in
    `BepInEx/LogOutput.log`.
  - **Pseudoregalia** — Steam install, Zone_Tower. `UE4SS.log` reported
    `send_ok=7908 send_fail=0 lines_received=7907 lines_malformed=0`, and every
    `remote p1-ghost redraw` line had `intended` exactly equal to `actual`.
- Source: `dev-scripts/meshghost.log` and `meshghost-server.log` per game for the relay/core side;
  `dev-scripts/bizhawk-dev-loader-{emerald,crystal}.log` for the two Lua attaches;
  the two mods' own logs above.
- Notes: **what this was worth testing for.** Sixty commits sat unpushed, including a `core.go`
  split into six files, a `relay/online.go` split into four, `internal/cfg`, the bridge's first
  tests, and Emerald's fix for crossing Lua's 200-local ceiling — which had never once been loaded
  in a running game, and would have failed to compile at all if it were still over. It loaded.
  Agent-confirmed alongside it, per the Go-side track: `dev-scripts/run-gotests.bat` green (build,
  vet, whole suite ×2 including `internal/e2e` at 158s), preflight clean, and both mod DLLs
  hash-matched to their sources and to the copies deployed in the live installs.
- Scope: **one machine, loopback, one client per game.** This says every adapter still reaches the
  screen; it says nothing about two real peers, which is where the open items in `status.md` live.


## A relaunched game could get a DEAD session, and CI caught it once in two runs (2026-08-27)

- Date: 2026-08-27
- Observed: `internal/e2e`'s `TestARelaunchedGameGetsAWorkingSessionAgain` failed under `-race` in
  CI with *"no ghost completed the round trip within 1m0s of relaunching the adapter"*. The log
  shows the replacement adapter attaching and being told the room's ghost-collision policy — so it
  had a working relay session — and then `core: relay disconnected: use of closed network
  connection` with the player leaving the room, followed by 60s of nothing.
- Source: `core/relaysession.go`'s `ConnectRelayOnAdapterHello`, already-connected fast path;
  `core/bridgeserve.go`'s `OnDisconnect` (`owns := c.relayOwner == nd`).
- Notes: **Go side, confirmed with the tools, no game involved.** The fast path returned `nil`
  without touching `c.relayOwner`, so ownership stayed with the DEPARTING bridge connection. The
  departing connection's disconnect handler tears the relay session down whenever
  `c.relayOwner == nd` — still true after it had been replaced — and disarms auto-retry in the same
  breath, leaving the Core with an attached adapter, no relay connection and nothing to redial it.
  What a player would see: restart the game quickly and the session is dead until you restart
  again. **Pre-existing, so v0.9.7 carries it too.**

  **Fix:** ownership follows the current adapter. The fast path now transfers `relayOwner` and
  re-arms auto-retry onto the live bridge connection; re-arming is part of the fix, since a relay
  connection already dying at transfer time is then redialled through a live socket instead of a
  dead one.

  **What isolated it, and the part worth keeping.** Four experiments with the real binaries and no
  game: a cold core answers a hello in 14ms (so no timeout was too tight), a core told to use a
  taken port does not walk but exits, a second adapter is refused in 13ms, and an empty port gives
  a dial refusal rather than a reject.

  **The first regression test PASSED without the fix**, which is worse than no test.
  `reattachFakeAdapter` retries until the core accepts, and by then the departing connection's
  teardown has already closed the relay session — so the second hello took the ordinary
  not-connected path and never reached the branch the bug lives in. Rewritten to call
  `ConnectRelayOnAdapterHello` directly with a second bridge connection while the first session is
  live, which reaches that branch every time. It now fails on both assertions without the fix.
  Racing for the real interleaving would have been the flaky test that hid the bug: the window is
  between the departing connection releasing the admission slot and its relay `Close` landing, and
  25 local `-race` runs of the e2e test never hit it.

## The render-knob sweep: damped prediction wins on a jittery link, and two bugs fell out first (2026-08-28)

- Confirmed by: the user, on screen, across thirteen configurations in one session -- TEVI, the
  loopback ghost 160px beside the player, driven through `meshghost-netsim` at 60ms latency,
  ±25ms jitter, 2% loss, 2% reordering. One variable per run, tabulated as it went; the flags are
  ADR 0040 (`curve`, `extrapolate`, `predict`) and ADR 0039 (`keepalive`).
- **The winner for that link: `interp 100ms`, `predict damped`, `extrapolate 100-150ms`, `curve
  linear`** -- the user's read on the final re-confirmation run: long left/right *"looks fine"*,
  spam *"looks fine i think ?"*, jumping *"looks fine, but feels a bit slow/delayed"* plus a tiny
  ground sink. **Those two residuals are OPEN, not accepted** (the bar is 1:1): the sink's real fix
  is adapter-side -- the game knows where its floors are and can be asked, the core cannot -- and
  the jump lag is the damped/accelerated trade with neither side good enough yet. `status.md`.
- **`interp` below the link's jitter CAUSES chop, confirmed by A/B**: 50ms interp under ±25ms
  jitter turned steady walking and jumping choppy; returning to 100ms cured it. The render time
  crossing between interpolation and prediction every frame is the mechanism.
- **Two variants were tried and made things visibly worse, and are kept only as options**:
  `accelerated` prediction (*"left/right looks snappy/bad, same for jumping"* -- a second
  derivative of jittery samples) and cross-frame confidence smoothing (steady walking turned
  choppy; reverted outright after a clean A/B against the identical unsmoothed run).
- **Two shipped bugs were found by the network alone, before any knob could be judged**: datagram
  REORDERING broke `remoteBuffer`'s ordering assumption and every ghost snapped/teleported
  (*"no more snap/teleporting"* after the ordered-insert fix, `core/reorder_test.go`, verified
  failing without the fix); and the animation phase correction's hard re-seek made idle ghosts
  twitch under jitter (*"idle looks fine now"* after the adapter-side speed-nudge fix --
  `tevi/VERIFIED.md`). Neither was visible in any clean-loopback session before this one.
- **Also confirmed live in the same session**: change suppression ran throughout (`unchanged
  states re-sent every 250ms` in every log) with no visible effect on the ghost, which is its
  success condition; and the extrapolation meter reported prediction doing real work on the bad
  link (avg ~32ms ahead, cap hits only after loss) versus ~nothing on clean localhost.
- **Scope**: one machine, one game, a loopback ghost, simulated faults. Not yet judged: two real
  machines, the other three games, and any shipped-default change -- deliberately none was made.
- Source: `core/interp.go`, `core/sending.go`, `core/remotes.go`, `cmd/meshghost/main.go`;
  regression tests under `core/*_test.go`; the sweep table in `dev-scripts/README.md`.
