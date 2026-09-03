# Phase 10 — the online stack: relay, client core, protocol, transports

**Status: open-ended, by design.** Created 2026-09-01 on the user's call: the Go side had no phase
file of its own, so its history lived scattered across ADRs, `scaling.md`, `hz-ceiling.md` and
`testing.md` with no single place to look back on how and when things were made. This file is that
place, **the same way Emerald got its "own" phase file (phase 8) after being built mixed into
phases 1-5.5** — the early phases interleaved server, client and Emerald because everything had to
be built at once and the project's shape was not yet settled (the user's own account, 2026-09-01).

**Scope: everything game-blind** — `relay`, `core`, `protocol`, `transport`, `bridge`, `netx`,
`cmd/`, `internal/` — one file for server AND client deliberately, not one each: nearly every
event here spans both (a relay queue exists because of client stalls; a protocol default is
inherited by both ends), so two files would write most entries twice or file them arbitrarily.
**Phase 11 is the replay work (2026-09-03, its own log because it is feature-sized); the fifth
game takes 12 onward.**

Unlike the adapter phases this is a **component log, not a bounded stretch of work** — it has no
"done". One dated entry per session or feature, appended in the same pass that closes the work
(`phases/README.md`'s keep-it-fed rule). Detail stays where it lives — an ADR per decision, the
measurements in `scaling.md`/`hz-ceiling.md`/`crowd-limits.md`, the runtime facts in
`agent_docs/verified.md` — this file is the timeline that says when and why, and points.

## Backfill — the stack's history up to the file's creation

Compressed from the ADR index (`architecture.md` — each ADR file's name carries its date) and the
commit log. Pre-2026-08-17 paths in the sources cited here are `internal/...`; see the module-move
note in `agent_docs/README.md`.

- **2026-08-08 → 08-11 — the shape.** Minimal game-agnostic adapter contract (ADR 0001), JSON as
  the Phase-0 wire format (0002), `area_id`/`anim` opaque (0003), Go core+relay as one codebase,
  two binaries (0004), relay unauthenticated through the early phases (0006), and an opaque event
  plane plus a `features` field reserved on day one so capability could be added without breaking
  deployed clients (0007). Built inside phases 3-5 (loopback → two players → the core extracted
  against a fake adapter, no game).
- **2026-08-12** — the core caps its own send rate to the relay (0009); the adapter declares
  `game_id` over the bridge rather than the config (0010).
- **2026-08-13** — a bridge disconnect closes the relay connection, so a closed game is a real
  `leave` (0011); `remoteStatesAt` filters remotes by `area_id` (0012). First real online session
  between two machines that evening (`agent_docs/verified.md`, the MYWANIP entry).
- **2026-08-14** — room-code auth and the peer `game_version` check, rejected at handshake
  (0013); relay lifecycle logging and permanent-vs-retryable rejects (0014); two full review
  passes across the layer (0015); the core auto-retries a dropped relay connection (0016).
- **2026-08-15** — the room's send rate becomes operator-configurable, slower-side-wins (0017);
  a relay can be restricted to a single game (0018).
- **2026-08-16 — the transport day.** `NDJSONConn` loses no message before switchover (0020);
  selectable tcp/udp/quic (0021) with discovery (`transports`, 0022), the
  handshake-is-always-tcp revision (0023) and the udp per-connection token (0024). An adapter
  may autostart its own local core (0025-0026).
- **2026-08-17 — the planes, and the module leaves `internal/`.** One adapter per core answered
  explicitly (0027); the event/lease/escrow/world planes past cosmetic (0028), capability scope
  (0029), rooms keyed by game+name (0030), world custody (0031); the packages move to the repo
  root and become importable (0032). The `event.v1` plane ships the same day.
- **2026-08-19** — TLS over tcp (self-signed, sniffing listener, optional pin); ghost collision
  becomes a host-set room policy resolved stricter-side-wins (0035).
- **2026-08-20** — an adapter may take area visibility away from the core (`render_all_areas`,
  0036); `internal/gameblind` makes the game-blindness rules mechanical tests.
- **2026-08-25** — `internal/cfg` extracted from the two mains' duplicated config plumbing.
- **2026-08-28 — the architecture week, in one day.** The first benchmark of the relay fan-out
  path (`e79f9e0`), then the fixes it earned: state lines built once via `AppendEnvelope`
  (`b5bd8f7`), the one allocation that scaled with room size (`b6eb327`); **a client stops
  restating an unchanged state** (ADR 0039, `IdleKeepalive` + the bracket sample, ~70% of states
  suppressed in real play); **the render model becomes three knobs chosen per game** —
  interp/curve/extrapolate+predict — and the snapshot buffer's count-bound bug is found and the
  sweep's three real bugs with it (ADR 0040, `fc4eb5c`); **the relay filters cross-area state
  for clients that ask** (`own_area_only`, ADR 0041, `b71fe22`) so the curve stops being
  quadratic; **every client gets its own outbound queue and writer** (ADR 0042, `955e2df`) so a
  stalled peer is its own problem. Nametags cross the stack the same day — `display_name`
  sanitized, `welcome.nametags`/`join.nametag`, `remote_name` over the bridge (`1246432`,
  `3698d4d`); the adapter-arrival declaration (`af32ed3`); the four-adapter bridge-port config
  (`15b2715`); a client that cannot dial a transport stops choosing it (`9089ddf`).
- **2026-08-29 — what CI's slower runner and the fuzzer knew.** The schedule fuzzer caught a
  change with no benefit (`43c4453`, `f4d525c`); a test was measuring the machine, not the ghost
  (`11e8173`); two more reconnect-deafness bugs (`4fa7ea7`); a reconnect cadence tests can
  compress (`f25b38c`, dated 08-28).
- **2026-08-30 — the Hz-ceiling program, and the orientation bracket.** The high-rate ceiling
  measured rather than derived and pinned as a test (`9d70eee`, `2b6abfd` — limits are
  per-LAYER, the cliff per-CLIENT); `maxSnapshots` stops being a functional bound (1024 as a
  pure memory cap, the time window rules — `c8aad58`); the results split out as `hz-ceiling.md`.
  **The core hands the adapter its orientation bracket** (ADR 0043, `1c960dd`), made an
  adapter-requested capability the same day (`b74a1d1`). The adaptive-Hz/1000-cap/JSON-vs-binary
  design work lands in `scaling.md`/`ideas.md`; the settings-defined-once plan in `plans.md`.
- **2026-09-01 — 15Hz, proven then inherited.** The send-rate floor watched rung by rung on
  Pseudoregalia, a blind 15-vs-20 A/B scored at chance, and interp measured per link tier
  (`956790c`); **`DefaultSendHz` drops 20 → 15 for every game**, the flood-cap derivation trap
  it sprang is pinned as a test, and the hang it shook loose was a real shutdown deadlock, fixed
  (`c16441f`). The relay stops dropping invalid states silently (`StateRejectReason`, throttled
  logging) after a silent drop hid a Pseudoregalia `extras` overflow.

- **2026-09-02 — loss cover, and the review's own regression found the same night.** Every state at 25Hz
  and slower carries the sample before it as a delta (ADR 0045, `abcbad1`), with `-loss-cover=false` as
  the A/B switch (`e5a6865`). Then TEVI's post-review run: ghosts snapping at every interp through
  `meshghost-netsim`, and the adversarial review's `netx.LimitListener` (`d91f8a8`, 01:28) turned out to
  embed `net.Conn` as an interface, hiding `WriteUnreliable` — every state the relay forwarded over quic
  or udp rode the reliable stream from 01:28 until `341a768` (21:45). Found with two new stats-line
  meters (`buffer dry`, `transit`) and a `QLOGDIR`-gated qlog tracer on `netx/quicconn`; regression test
  `TestLimitListenerKeepsTheUnreliableWrite`. Suite and `-race` green. `agent_docs/verified.md`, "The
  limiter hid WriteUnreliable".

- **2026-09-02 (late) — `DefaultInterpolationDelay` 250 → 450ms (ADR 0046)**, the user's call after all four
  games were climbed on the worst-case proxy at 15Hz; the release config, the template and the READMEs
  follow, `shippedconfig_test.go` keeps them in step, no per-game override remains.

- **2026-09-02 (late) — the shipped configs restructured and `ghost_collision` disabled by default.** The
  user's 2026-08-30 tiers (plans.md, "Settings: defined once") finally staged: basics, a blank line,
  the advanced set, and NO comments — every explanation moved to `packaging/release/README.txt`'s
  "THE BASICS" / "ADVANCED" lists, which now cover every key the client and relay read (`min_send`,
  `stats`, `resume_grace_seconds`, `curve`/`extrapolate`/`predict` included). The relay's
  `-ghost-collision` default is `disabled` and the e2e expectation follows; `stage-release.ps1` inserts
  an added override key at the END of the client block instead of the top.

## Open

What is open on this stack at any moment is `agent_docs/status.md`'s job, not this file's —
today's snapshot there includes the catmull-rom uneven-spacing defect, `internal/e2e`'s
`freePort` TOCTOU, and the two shipped settings that reach too few adapters.

## 2026-09-03 — Replays: the Go side gained recording, playback, seeks and a bridge control message; logged in phase 11

Feature-sized Go-side work took its own log today rather than another entry here: **`phase11.md`** holds
the per-stage record (the local fake peer seam and `render_remote.cosmetic`; the recorder; playback from
`replay/active/` with seams instead of glides; seeks, replay-last and the `replay_control` bridge message;
the system-wide hotkey package next). What touched this log's components: `core` (new files
`localpeer.go`, `recorder.go`, `replay.go`, `replaycontrol.go`, a tap at the top of `forwardLocalState`,
a tick-started counter in `tickRenders`), `bridge` (`cosmetic` on `render_remote`, the new
`replay_control` type), `internal/gameblind` (the one-entry-point check for `storeRemoteState`, two new
frozen field lists), `internal/e2e` (a replay through the real binaries), `cmd/meshghost` (the `replay`
config block and flags), `cmd/meshghost-fakeadapter` (`-record`, `-replay-dir`, an offline mode). The
decisions: ADR 0047 and ADR 0048. Whole suite and race detector green at every stage's commit.

## 2026-09-03 — Replays, continued: hotkeys, save-last, the chaser pack, split times (phase 11 stages 5–8)

Still logged in `phase11.md`; what touched this log's components since the morning entry: `internal/hotkey`
(new: the system-wide key loop, Windows API cited in ADR 0048, a no-op elsewhere), `cmd/meshghost` (the
`hotkeys` and `chaser` config blocks, their flags, `startHotkeys`), `core` (new `chaser.go` and
`splittime.go`; `SaveLast` in `recorder.go`; a quiet variant of `storeRemoteName`; the split hook beside
the recorder tap), `bridge` (`session_policy.chaser_contact`), `internal/gameblind` (the field frozen),
`internal/e2e` (the chaser through the real binaries). The race detector caught one test-ordering race
in the chaser tests and found nothing in the shipped paths; a by-hand `go test -race` cannot build here
(no C toolchain on the bare PATH), so the race check goes through `run-gotests-race.bat` only.

## 2026-09-03 — The udp allocation pin stops flaking and starts catching

Found while the phase 11 suite runs kept tripping over it; fixed on the user's call rather than filed.

`netx/udpconn`'s
`TestWriteUnreliableDoesNotAllocatePerCall` failed twice under whole-suite load with "4.0 per call".
Trying to reproduce it — 40 runs with `core` and `relay` suites running alongside — never did, so the
fix is structural rather than aimed at a symptom: (1) the drain goroutine set a read deadline per read,
an allocation on this process inside the measured window, and now sets one before the window; (2) the
count is the MINIMUM over five `AllocsPerRun` batches, because a regression allocates in every batch
and a stray allocation from another goroutine only in some. **And the threshold was wrong all along:**
removing the buffer reuse on purpose measures exactly 1.00 per call, the real code 0.00, and the old
`got > 1` passed the broken code — proven by breaking `conn.go`, watching the test pass, then fail
after the bound became `got >= 1`, then restoring and running 20 clean passes. The lesson for any
allocation pin: measure the regression you mean to catch before choosing the number.


## 2026-09-03 — Three fuzz targets land in CI; the race job's catch is fixed at the source

The afternoon's three Go-side commits, in this log's components: `core` (`FuzzEverything`, the chaser
queue clamp `maxChaserBehind` it found, and the test helpers now setting every hello-read field before
the bridge serves — the test-ordering race CI's race job caught), `internal/hotkey` (a fuzz target and
the duplicate-modifier refusal it found on its first campaign), `cmd/meshghost` (a fuzz target over the
hand-edited config, and the shipped `name_color` pinned as a deliberate divergence), `.github` (three
fuzz entries; eighteen targets CI now runs). Detail and the findings: `phase11.md`, same day; the
trap: `testing.md`. Whole suite and race detector clean locally at each commit.

## 2026-09-03 (evening) — FuzzEverything had never once loaded a clip; the seam it was written to reach was dead

Picking up the three fuzzing/clock entries from `ideas.md` and planning them out properly first (that
plan corrected two of my own claims in the entries before a line was written). The first item was
meant to be small: add the two ops the replay-schedule entry names, plus seeds for the seam shapes.

**What actually turned up.** Adding a seam seed meant reading the `-v` log to check the seam ran, and
every single seed printed `replay skipped: f01.ndjson: line 1 is not a replay header: json: cannot
unmarshal string into ... speed`. `fuzzEverythingClip` read nine header keys from the whole step byte,
but the op is selected with `b&0x1F`, so bits 0-4 are pinned to `file.valid`'s index and `speed`
— read from bits 3..1 — was always the string `"fast"`. Every clip that function had ever produced was
refused. **Playback-from-a-file had never run in the target that exists to fuzz it**, and the 2s
recorded gap written into that function to produce a seam had never executed. Replays only ever
started through `ctl.replayLast`/`ctl.saveLast` on a real recording, which is why the logs looked busy.

**Fixed in `b7205acb`:** eight deliberate clip shapes off the three bits that are genuinely free,
five the loader must accept and three it must refuse, pinned by a new
`TestFuzzEverythingClipShapesAreWhatTheyClaim` so the split cannot rot silently again. The cheap route
to a seam is `skip_gaps`, which collapses a 2s recorded gap to one millisecond while still marking a
forced seam, so the path costs about a millisecond instead of two seconds.

**Also in that commit.** `clock.backStep`, riding the parameter bits the `relay.forget` slot does not
use — the second op the entry asked for (`relay.reset`) turned out redundant, because a forget already
lands under a live replay, and it clears `c.clock` and `c.lastNowMs`, so it RESETS `nowMsLocked`'s
never-go-backwards clamp rather than driving it. Only a back-step that keeps the session up does that.
`nowMs` monotonicity is now an invariant checked after every step. Two seeds: the collapsed-gap seam,
and a back-step landing between two seeks under a live replay.

**Corrected in the record, not just the code.** The entry's third ask, race coverage, was already
satisfied — `go test` without `-fuzz` runs the seed corpus and the race job runs `./...` at
`-count=3`. And my own earlier correction to `ideas.md`, that the replay seam was already reachable,
was wrong for a subtler reason than the original claim: the code to reach it existed and was dead. The
chaser seam is separately unreachable, on live timestamps, and that one does want the virtual clock.
Lesson filed: `pitfalls/method.md`, "A fuzz target that exercises nothing passes exactly like one that
exercises everything".

`dev-scripts/run-gotests.bat` green, including `internal/e2e`.

## 2026-09-03 (evening, second) — the shape bound the size caps never were

The Lua harness from `phase8.md`/`phase9.md` found the same exposure from the adapter end that
`security-design.md` had measured from the Go end on 2026-08-24 and left frozen: `extras` and
`orientation` are bounded by SIZE and never by SHAPE, so 490 levels of nesting fit inside the 1024
bytes `extras` allows and 127 inside `orientation`'s 256. Asked where the bound belonged, the user's
call was **both, adapter first**, which lifted that entry's do-not-build hold for this one change.

`MaxJSONDepth = 32` in `protocol/limits.go`, on both fields. Two checkers, because the fields differ:
a walk over the decoded `map[string]any` for `extras`, and a byte scan for `orientation`, which is a
`json.RawMessage` and is never decoded here. The scan counts brackets outside string literals, so a
brace inside a quaternion's label is not nesting.

**Placed so the hot path does not pay.** `extrasLengthBound` already refuses to recurse and returns
ok=false the moment it meets a nested container, so nesting was ALREADY the slow path; the depth walk
sits just past that early return. A flat scalar map — what every shipped adapter sends, as that
function's own comment records — returns before reaching it.

**32 rather than the adapters' 64** so nothing an adapter would refuse ever arrives at one, and the
core covers a third-party adapter that has no guard of its own.

`TestDepthBoundRefusesWhatTheSizeCapAdmits` pins the measured numbers and was checked to FAIL without
the bound by raising the constant: at depth 490 it reports 987 bytes, matching the 986 measured on
2026-08-24 — a size check could never have caught it. `FuzzDepthBoundsAgreeAndNeverPanic` pins the two
checkers against each other, because `orientation` rides on the scanner alone; 28.8M executions clean
in a 60s local campaign, and it is now the nineteenth target in CI's fuzz job.

`dev-scripts/run-gotests.bat` green, `internal/e2e` included.
