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
game takes 13 onward** (12 became the delivery pipeline — packaging, releases, CI and the gates —
on 2026-09-11; see [phase12.md](phase12.md) for the line between it and this file: **phase 10 is
what runs, phase 12 is what ships and what checks**).

Unlike the adapter phases this is a **component log, not a bounded stretch of work** — it has no
"done". One dated entry per session or feature, appended in the same pass that closes the work
(`phases/README.md`'s keep-it-fed rule). Detail stays where it lives — an ADR per decision, the
measurements in `scaling.md`/`hz-ceiling.md`/`crowd-limits.md`, the runtime facts in
`agent_docs/verified.md` — this file is the timeline that says when and why, and points.

## Backfill — the stack's history up to the file's creation

Compressed from the ADR index (`architecture.md` — each ADR file's name carries its date) and the
commit log. Pre-2026-08-17 paths in the sources cited here are `internal/...`; see the module-move
note in `agent_docs/README.md`.

- **2026-08-08 → 2026-08-11 — the shape.** Minimal game-agnostic adapter contract (ADR 0001), JSON as
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
- **2026-08-21 → 2026-08-23 — doc gates, not stack changes.** The date rule became a grep because
  the rule alone did not hold (`575e770b`), every doc was read against the code (`c4017f7d`), and
  the no-invented-durations rule got a check that actually catches them (`01cd8e85`). No Go-side
  behaviour changed; listed so the dates are not silent. *(Added 2026-09-11.)*
- **2026-08-22 — the test suite learns to fail.** Eight commits, and the theme is that several
  tests had never exercised what they claimed. The client half of session resumption **had never
  run** (`fe33e659`); an e2e case that kills and restarts the relay, the client and the adapter
  was added (`0032b6af`); what a dropped relay connection must forget got pinned (`7f62c730`); and
  *"a frame sent exactly once is a frame that can be dropped"* (`ded21ffb`). Two real defects fell
  out: **`"the room hasn't answered yet"` is not `"the room said nothing"`** (`9e1d15dd`) — both
  are an empty `relayGhostCollision`, and `ResolveGhostCollision("", "")` is ENABLED, so a
  `session_policy` pushed before any `Welcome` tells an adapter its ghosts may be solid in a room
  that disabled them; caught by CI's `-race` job, fixed with `relayPolicyKnown`. And **a blob must
  be bounded by the bytes it BECOMES, not the bytes it is** (`8faec7c2`): `encoding/json` escapes
  `<`, `>` and `&` as six-byte sequences, so 130 bytes of `&` in hand are 774 on the wire — every
  bound in the package was under-counting by up to six times, in the one direction that matters,
  and a write the sender validated would be rejected by the receiver with nothing able to explain
  why. `JSONWireLen` now measures what the encoder will actually write. *(Added 2026-09-11.)*
- **2026-08-25** — `internal/cfg` extracted from the two mains' duplicated config plumbing.
- **2026-08-27 — three races and a dead session, all found by CI rather than locally.** **A
  relaunched game could get a dead session** (`4664c9b8`): CI failed once in two runs on
  `TestARelaunchedGameGetsAWorkingSessionAgain` and **twenty-five local `-race` runs never
  reproduced it**. `ConnectRelayOnAdapterHello`'s already-connected fast path returned nil without
  touching `c.relayOwner`, so ownership stayed with the DEPARTING bridge — the replacement adapter
  had a working session, then the connection closed under it and sixty seconds of nothing
  followed. Also: a data race on `reconnectLogInterval` (`be87db37`), **plain udp takes the odd
  port, not quic** (`efa66931`), `udpconn.go` split into the four concerns whose cut lines were
  already drawn in it (`148f5f39`), and **the doc gates existed while CI never ran one**, so they
  held only when somebody remembered (`18e4d49b`). *(Added 2026-09-11.)*
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

## 2026-09-03 (night) — the virtual clock, stages 1 and 2, and two design corrections found by building it

From `ideas.md`'s virtual-clock entry. Staged deliberately small, because this is the one workstream
in the plan large enough to have a stated abort criterion: if the first slice could not be made
deterministic in a three-line commit, the design was wrong and the thing to do was stop, not push on
into `online.go`. It could.

**Stage 1 (`0e75ea99`) — the interface, proved on the recorder's flush pair.** Chosen as first
precisely because it is the smallest: one struct, three lines of production code, no goroutine, no
lock interaction, already covered by tests. The recorder flushes on a one-second timer so a crash
loses at most a second; that boundary now costs nothing to cross.

**Correction 1: the interface needs `Since`, not just `Now`.** The entry proposed a bare
`now func() time.Time`. Every duration in this package is a `time.Time` FIELD plus a reader
elsewhere — `lastSendAt` written in `sending.go:140` and read by `time.Since` at `:84` and `:109`,
`lastFlush` the same shape. Convert the writer alone and the code computes `wallNow − virtualStored`,
which at any fake epoch is an enormous positive or a negative: a rate limiter that never limits, or
one that never sends, with nothing crashing and no test naming the cause. **So the unit of conversion
is a field plus every reader of it, never a call site.** Checked, not asserted: reverting the single
`time.Since` while keeping the two writes makes the stage-1 test fail at once, reporting a file that
flushed with no time passing.

**Correction 2: `awaitTick` needed a cancel escape before it could be virtualised, and that is a
prerequisite rather than a step (this commit).** It had no stop channel — a bare deadline loop
polling every 2ms — and it is called from `chaser.go:92`, `replay.go:360` and `replay.go:456`, which
is to say from inside the goroutines `halt()` exists to interrupt. So `halt()` closed a channel
nothing was listening to, both `Stop` functions fell through to their one-second joins, and each
abandoned replay leaked a goroutine. At the wall clock that is wasteful; under a virtual clock it is
fatal, because a test that never advances time would park every replay and chaser there forever. The
test uses a five-second deadline so a regression takes five seconds instead of milliseconds.

**Also corrected in the record:** the site count is 32, not the 24 I first wrote — the five missed
are all `time.Since` readers. And `remotes.go:34` is a five-second log throttle, not staleness;
staleness comes from `nowMs()`, so converting the root covers it.

**Not converted, deliberately, with the reason written at each site:** the recorder's filename and
header stamps (they end up in a file somebody reads, and `replayFileName` deduplicates against the
real filesystem), the ping/RTT pairing (it measures the network), the relay session's dial backoff
and timeouts, transport discovery, and the two one-second goroutine joins.

Still ahead: `nowMsLocked` itself, `awaitTick`'s polling, the two due-waits, and the preflight
ratchet that keeps a mixed clock from coming back.

Suite green including `internal/e2e`; race detector clean.

## 2026-09-03 (night, second) — the clock's ROOT, the send-rate trio, and the ratchet that keeps it

**Stage 3, the root.** `nowMsLocked` now reads the injectable clock. That one call is where every
timestamp on outgoing state, every render time remotes are interpolated at, and every due time a
replay or chaser sleeps until comes from — so converting it converts staleness, interpolation,
playback pacing and the chaser pack together, and none of those needed a clock of their own. The
test advances eight hours and asserts it cost no real time; the monotonic clamp is checked in the
same test by stepping the clock backwards an hour.

**The offset stays wall-derived, deliberately.** `clockAdjustLocked` comes from RTT samples measured
against the real network, which a virtual clock cannot measure. So `nowMsLocked` is now a virtual
`Now()` plus a wall-measured scalar. That is sound — the scalar is a number a test can set — but it
is written at the site, because it looks like an inconsistency and someone would otherwise "fix" it
back into a mixed clock.

**Stage 4, the send-rate trio.** `lastSendAt` and BOTH its readers (`sending.go:84`, `:109`) moved
together. This is the exemplar the whole design note is about: converting the write alone would have
left two `time.Since` calls computing `wallNow − virtualStored`.

**Stage 5, the ratchet.** Every remaining bare `time.*` in `core/*.go` — 23 of them across a dozen
files — now carries an inline `wall-clock:` note saying why it stays: socket deadlines, dial backoff,
the ping pairing that MEASURES the network, the two shutdown joins where a virtual clock would turn a
leak into a hang, the adapter frame poll, and the artefact timestamps written into replay files.
Preflight's new "The core's clock is injectable, and stays that way" fails a bare call that has
neither a `c.clk()` nor a note.

Three things that check is built to survive, because a check nobody can trust is worse than none:
`_test.go` is excluded (tests legitimately sleep by the hundred), the exclusion runs BEFORE the
vacuity guard so an over-eager filter cannot make it pass on an empty set, and it was confirmed to
FAIL by deleting one marker — it named `core/stats.go:219` exactly.

Suite green including `internal/e2e`; race detector clean.

**Left for later, and small:** `awaitTick`'s own polling and the two due-waits still read the wall
clock for their SLEEP, while their due times already come from the virtual `nowMs`. That split is
deliberate for now and marked as such: a virtual sleep needs the fake clock to be advanced by
something, which is the "advance until quiescent" helper the entry in `ideas.md` describes and this
session did not build.

## 2026-09-03 (night, third) — a replay ghost could render NOT cosmetic, and only the repaired fuzzer could see it

CI's fuzz job failed on the push that landed the clock work, on `FuzzEverything`:

```
after ctl.restart: render for "replay:f01.ndjson" has cosmetic=false
ran: attach frame.walk file.valid startReplays frame.walk frame.walk ctl.restart
```

**A real defect in shipped code, and a direct consequence of fixing the generator earlier the same
day.** Before that fix no clip ever loaded, so `startReplays` never produced a replay ghost and this
path had never once executed in the target built to exercise it. Repairing the fuzzer immediately
found what it had been unable to look at.

**Cause.** `sendRenderRemote` built `render_remote.cosmetic` from `c.isLocalPeer(id)`, a membership
lookup in `c.localPeers`. A seam DROPS the peer and re-admits it — every restart, every lap, every
recorded gap — so a render tick landing inside that window found the id absent and sent
`cosmetic=false` for a replay ghost. ADR 0047 says a replay or chaser ghost is cosmetic whatever
`ghost_collision` says, so that frame told an adapter the ghost was solid and damageable. On a game
that acts on it (Pseudoregalia's chaser contact) that is visible behaviour, not a technicality.

**Fix.** Build the flag from `isLocalPeerID(id)`, the prefix check. The namespaces cannot collide —
that function's own comment records that relay ids come from the relay's counter and never carry a
`replay:`/`chaser:` prefix — so the id is authoritative where membership is transient. The old
`isLocalPeer` helper was DELETED rather than left beside it: it had no other caller, and its
existence is what made the wrong choice available. A note in its place says why.

**Intermittent, which is the other half of the lesson.** The downloaded input passed on the first
local run and failed at `-count=60`. A single green run against a fuzz reproducer proves nothing;
the repo's own `-count=10` rule exists for this and was not enough here either.

Corpus committed at `core/testdata/fuzz/FuzzEverything/e69f253af52a10b7`. Suite green, 90s local
campaign clean, race detector clean.

## 2026-09-03 (late) — Go-side work this session was Phase 11's, not this one's

Four commits touched `core` and `cmd` after the entry above, and none of them is virtual-clock
work: the per-peer render delay (ADR 0049), the offline client mode, and gzipped/rounded
recordings. All three are logged in [phase11.md](phase11.md), 2026-09-03 (late). Noted here so the
gap in this file is a decision rather than a lapse.

**What it does mean for this phase:** the due-wait sleeps are still wall-clock, and the
advance-until-quiescent helper is still unbuilt. Nothing this session changed that, and one thing
sharpened the need for it — `FuzzEverything`'s chaser seam is still unreachable because a step's
gap caps at 350ms against a wall-clock 1500ms threshold (`ideas.md`), which is exactly the case the
virtual clock exists to close.

## 2026-09-04 — Still Phase 11's work, not this one's

Four more commits to `core` and `cmd` since the note above, and none of them is virtual-clock work
either: a downed relay no longer refuses the game (ADR 0050), recordings became plain text with
per-key delta encoding (ADR 0051), and both bridge-driving fuzz targets moved off sockets onto
`net.Pipe`. All logged in [phase11.md](phase11.md), 2026-09-04.

**What it means for THIS phase is unchanged**: the due-wait sleeps are still wall-clock and the
advance-until-quiescent helper is still unbuilt. One thing sharpened the need again — the fuzz
targets now run ~25x more executions per campaign, which makes the wall-clock-gated chaser seam the
remaining thing a campaign cannot reach.

## 2026-09-04 (late) — the last of the session, still Phase 11's

Four more commits to `core` and `cmd`, none of them virtual-clock work: `replay/active` reads
`.zip` (and a zip of several clips is several ghosts), a half-written final line loses that line
rather than the whole recording, `FuzzEverything` grew zip coverage, and the chaser ships
unlabelled. All in [phase11.md](phase11.md), 2026-09-04.

**One of them is worth a pointer from here**, because it is about this phase's own instrument: the
truncation bug lived inside an op ORDER `FuzzEverything` already generates and was never found,
because it also needed 64KiB of recording before the writer's buffer flushed mid-line. A fuzz
target explores order well and scale badly — `testing.md`'s Traps now says so, and it is the same
shape as this phase's open item, where a compressed clock cannot reach a wall-clock threshold.

## 2026-09-04 (late) — three test fixes, and what this file is actually for

**Read this before adding another pointer entry.** `preflight.ps1`'s `$phaseMap` names
**this file as the Go side's running log** — `core`, `relay`, `protocol`, `transport`, `bridge`,
`netx`, `cmd`, `internal` — so every Go-side commit belongs here whatever phase's story it is part
of. Three entries today said "this is Phase 11's work, see phase11.md" and then tripped the same
check again on the next commit, which is what fighting a tool looks like. The narrative can live in
the active phase's file; the log line lives here.

**The three, all test-side, all found by CI after a green local run:**

- **`FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane`, red in eleven seconds** on
  `{"Client":{"replAY":{"sAve_lAst":"0"}}}`. The client was right: it decodes into a struct, so
  `encoding/json` matches tags case-insensitively and `"0"` is a duration a player chose. The
  test's own mirror is a `map[string]any`, where a key keeps the file's case, so its lookup for
  `save_last` missed and it called a correct outcome a bug. **A test that mirrors a decoder must
  mirror how that decoder matches names.** Second failure of this target in two days and the same
  shape one layer down — the first (2026-09-03) did not know an explicit zero from a bad value.
- **A one-tick race in a test written the same day.**
  `TestALocalGhostStillInterpolatesRatherThanEdgeHolding` read `nowMs()` twice — once to place its
  samples, once to compute the render time — so a millisecond boundary between them moved the
  answer by one. Green locally, green in CI, and **red in the release workflow on the same
  commit**. Fixed by deriving both ends from one reading rather than by widening the comparison,
  which would have hidden the next real off-by-one. `testing.md`, Traps.
- **Three of my own comments cited durations rather than dates**, which `CLAUDE.md` forbids because
  they are false on arrival. The tree-only gate caught it in CI; my last local preflight predated
  the files.

**Standing item for this phase, unchanged:** the due-wait sleeps are still wall-clock and the
advance-until-quiescent helper is unbuilt.

## 2026-09-04 — `recording_state`, the first core → adapter STATE message since `session_policy`

**Built for a defect that is entirely about where the core CANNOT reach** (ADR 0052). The record
hotkey is system-wide and lives here (ADR 0048), and this side never touches a game — so the only
feedback a recording toggle could give was a console line. The user runs with the console hidden:
*"I have the console hidden, and was unsure if f9 was doing something or not when using it. i
usually did f9 2-3 times then f11"*. And the failure is not about being careless: with the log open,
having fixed those very lines earlier the same day to say which direction the toggle went, I read
them, decided a recording was running, pressed the toggle to stop it and started one instead.

**Shape, and why each half is what it is:**

- **STATE, not an event.** An event is lost on anybody not attached to hear it; the question is *am
  I recording right now*, so it is pushed on change AND on attach, and an adapter that comes up
  mid-recording is told rather than waiting for the next toggle. Same shape as `session_policy`,
  which was the only other message in this direction.
- **`started_unix_ms`, not an elapsed duration.** Elapsed would mean a message per second forever;
  the start instant means the adapter counts locally and this stays push-on-change. It also makes
  the mid-recording attach show the true elapsed time rather than starting from zero.
- **A wall clock is sound here and would not be at the relay.** The bridge is loopback-only by
  construction, so the two processes are on one machine. That is a property of THIS hop, and the
  comment says so, because the same field on a relay message would be wrong.

**THE FIRST VERSION DEADLOCKED, AND THE TEST HUNG RATHER THAN FAILED.** `StartRecording` holds
`c.rec.mu` through a defer for its whole body, and the push called `Recording()`, which wants that
same mutex; Go mutexes are not reentrant. The fix splits the push into a values-taking half that
touches only `c.mu`, and the whole path now reads the recorder and RELEASES it before taking the
other lock, so the two are never held at once and no caller can invert them. **A hang is the shape
this class of bug always takes** — it is worth recognising on sight, because a 300-second tool
timeout reads like a slow suite rather than a defect.

**Tested:** both edges (start pushes with a start time, stop pushes with it zeroed so nothing can
keep counting under a hidden indicator) and the de-dupe, which is what makes the unconditional
attach-time push affordable. Full suite green twice.

## 2026-09-05 — the chaser gets a gameplay clock and a rate-safe tap, and the depth bound gets its off-by-one

**`player_frozen` and the gameplay clock (ADR 0053, commit 72741a66).** A new bridge message,
adapter → core, on change. The chaser pack's sleeps now run on wall time minus every frozen span
(`Core.gameplayNowMs`), and frames taken while frozen are never offered to it — so a pause menu or
item popup costs the chaser no delay and it never converges onto a player who cannot move. A
CLOCK rather than a filter, because queued frames would still fall due on the wall clock and the
first frame after a freeze would read as a seam. Recordings, the ring and the wire are untouched by
the user's call. `TestChaserHoldsWhileThePlayerIsFrozen` fails without it (the chaser walked 21 →
31 onto a player held at 31). Pseudoregalia sends it from the engine's own pause state; the other
three adapters do not yet.

**The tap thins to 100 samples a second (commit 02d689b7).** Each chaser's queue was sized as
`delay + 2s` at an ASSUMED 100Hz; Pseudoregalia sends ~180 (one per frame). A full queue drops the
NEWEST samples until its oldest fall due — a run of ~0.44×delay−1.1s — over the 1.5s seam threshold
from a 7s delay up, so chasers 3..8 despawned and respawned on the player with a period of exactly
delay + spawn window, watched live and read off the log. `chaserOfferIntervalMs` makes the sizing
an invariant; `TestChaserTapThinsTheAdapterFrameRate` fails without it (473 of 500 queued). The
lesson is in `pitfalls/by-lesson.md`: size from a rate you enforce, and know which end you drop.

**Two CI reds after the push (commit 09cc7269).** A harness data race in the recording-state tests
(`ReplayDir` set after attach while `StartReplays` read it on the bridge goroutine — flaky, fixed by
setting it before the bridge serves), and a real finding from `FuzzDepthBoundsAgreeAndNeverPanic`:
`jsonDepthWithinLimit` tested the bound on entry, so the scalar inside 32 nested arrays counted as a
33rd level and the walk refused what the byte scanner accepted. Containers only now; the input is a
committed seed. Suite and `-race` green after each.

## 2026-09-05 (night) — the release job found a Linux-only flake: a Reject lost to a TCP reset

The v1.1.7 release job's own Go test step failed `TestRateLimitedClientReceivesRejectBeforeClose`
while every path-filtered gate on the same commit was green and no Go had changed. The relay's log
showed the tell: one reject logged, then the same connection re-tripping the limit per queued line
with a failed send behind each. Cause: `Send(Reject)` then `Close()` on a socket holding the client's
unread flood is a RST, and a reset can discard the Reject in the client's receive buffer — Linux
behaviour, which is why 40 Windows runs never showed it. Fix: `transport.CloseGracefully` (half-close,
drain under a deadline, close on the peer's FIN or the deadline) used by the rate-limit path, plus a
`rateRejected` latch so the drained lines are ignored. New regression test in `transport`; suite and
`-race` run before the commit. Record: `pitfalls/by-lesson.md`, `testing.md` Traps.

## 2026-09-06 — the replay cap counted the dead

A tester's log: `hotkey replay_last: 16 replays are already active (the cap)` with nothing playing.
A finished player closed its `done` channel and stayed in `c.replays`; every cap check measured the
map's length, so sixteen record-and-replay cycles of distinct clips in one session (each recording its
own file, each replay_last its own player) exhausted the cap for the rest of the session. Fix:
`pruneFinishedReplaysLocked` before every cap check, so the cap bounds LIVE ghosts, which is what it
was for. `TestReplayLastIsNotCappedByReplaysThatAlreadyFinished` fails without it with the tester's
exact message. Suite and `-race` run before the commit.

## 2026-09-06 — the documentation fact check, as it touched the Go side's docs

No Go code changed. The repo-wide pass (`agent_docs/doc-history.md`, 2026-09-06) compared the
contract and the people-facing docs against `protocol/`, `bridge/`, `relay/`, `core/`, the two mains
and `ci.yml`.

- `contract.md`: `hello` gains `name_color`, `welcome` gains `ghost_collision` (ADR 0035), `prefs` is applied silently and the `prefs_ack` it named never existed; the `tls` line said the binaries default to `off` while the Transport section and both mains say `auto`; the bridge `hello` gains `interpolate_orientation` (ADR 0043); Limits gains `MaxJSONDepth` (32) and `MaxDisplayNameBytes`/`Runes` (64/24). All match shipped code under existing ADRs; no revision.
- `architecture.md`: the bridge has 18 types (`replay_control`, `player_frozen`, `recording_state` were missing); `internal/hotkey` listed and named in `cmd/meshghost`'s imports.
- `testing.md`: "all fourteen" fuzz targets became 25 in the tree, 19 campaigned by CI; the table lists every target; the six without a `ci.yml` step are named with their reasons (`FuzzSchedule` and `FuzzNameDeliverySurvivesAnyConnectOrdering` are socket-bound by design; the two sanitizer pins and the two encoder pins were never wired, a decision written down as one); `FuzzScheduleConvergence` corrected to `FuzzSchedule`; the `internal/` test inventory.
- `docs/config.md`: `autostart`, the three `replay.indicator*` keys and `predict: damped` documented; `ghost_collision` and `resume_grace_seconds` shipped values corrected; "one file ships" became the root file plus a client-only copy per game. `docs/security.md` and `docs/networking.md`: the depth and display-name bounds. `docs/reviewing.md`: CI fuzzes a written list, not every target. `.github/workflows/ci.yml`: the header comment says so too (comment only; the next push will run CI on it).
- Left as a Go-side note: `core/schedule_convergence_fuzz_test.go`'s comment still says "the shipped 250ms interp", a test comment a docs pass does not touch.

## 2026-09-06 — the local-ghost caps come out: chasers and replay files are bounded by the roster only

A tester had been stopped at 8 chasers and blamed a relay capped at 16; it was `maxChasers` in
`core/chaser.go`, with `maxActiveReplays` (16) over replays and chasers together in `core/replay.go`
and `replaycontrol.go` -- neither ever touched the relay, since a local ghost never leaves the
machine. Both removed on the user's call (*"just make it unlimited/no cap? allow people to do as much
as their game can handle"*). The one bound left is `protocol.MaxRosterSize` (512 seats, shared with
real peers): `admitLocalPeer` already refuses past it and logs once, and `startChasers` clamps a
count to it so the fuzzer's 1<<20 never allocates a million queues. `maxChaserBehind` (10 min) stays.
Tests pin the new behaviour -- `TestChaser...` 99 asked = 99 started and 1<<20 = 512;
`TestReplayNoCapAndPrefixNeverEscapeTheFolder` 19 files = 19 loaded; the everything-fuzzer's
local-ghost invariant is now files + chaser count. `run-gotests.bat` green, root binaries rebuilt
with `-o`, `meshghost.exe` deployed to all four game roots and the release staging copy. The flag
text and `docs/config.md` say "no cap". Context: `phase11.md` 2026-09-06 (the camera-rig session).

## 2026-09-06 (evening) — the caps came off, and a tester found what was behind them

The same day's cap removal (above) let a tester run **512 chasers**, and their two logs are the
first real load this core has seen from a game that cannot keep up. Their report: *"game lived, the
client died spawning to many ghosts (and would get restarted to start another 340 ghosts before
crashing eventually)"*.

**Nothing crashed.** At 353 admitted chasers a `render_remote` write hit the 10-second
`transport.DefaultWriteTimeout` on a socket the game had stopped draining (its own heartbeat shows
`lines_received` frozen for exactly ten seconds while `send_ok` kept climbing). `transport.Send`
closes on a failed write; the mod saw the close, re-dialled the same port, and was told **"busy:
this core already has a game attached"** 6 ms later — by the core whose adapter socket had just
died. So the mod walked to the next port and started a second core, over and over.

**The window:** the admission slot is freed by `OnDisconnect`, which fires from the READ loop, and
the read loop was the goroutine still inside the frame handler failing those writes. The peer knows
first: closing a socket with unread data sends a RESET.

**Fixed in three parts** — `Core.sendToAdapter` (one funnel, cleanup on any goroutine's failed
write), `onAdapterFrame` stopping at the first failure instead of logging 1,200 more, and the hello
handler treating an incumbent whose socket `IsClosed` as not busy. `transport.NDJSONConn.IsClosed`
is new and set inside the close itself. Regression:
`TestADeadAdapterSocketFreesTheCoreForTheReconnect` — **5/5 fail before, 10/10 pass after**;
`run-gotests.bat` green. Records: `verified.md`, `pitfalls/by-lesson.md`, `status.md`.

**Left open, measured not guessed:** the adapter sends frames from UE4SS's thread at ~171/s while
its game thread rendered 17 fps, and the core answers every frame per ghost — ~59,000 lines a
second. `ideas.md`, 2026-09-06.

## 2026-09-06 (night) — the push, and what CI caught that no local run could

The dead-adapter fix went to `master` and CI's **Linux race job** failed on
`TestBridgeHelloGameVersionReachesRelay` -- everything else (build, vet, cross-compile, gofmt, the
shipping-target job, the 13-minute fuzz campaign) green. Not the new code: the job's log shows a
refused hello arriving at the core as a bare EOF, classified as a TRANSIENT drop, retried, and only
recognised as permanent on the second attempt -- by which point the path that closes the bridge had
been passed. Cause: `rejectAndClose` closed behind unread data, and a reset discards the `Reject` the
client has not read yet. The 2026-09-05 graceful-close fix had been applied to the rate-limit path
alone.

Fixed at all three handshake sites with `handshakeCloseDrain`, and pinned by
`relay.TestARefusedHelloDeliversItsRejectBehindUnreadData`, which fails with the reset on Windows
too. Records: `verified.md`, `pitfalls/by-lesson.md` (with the rule about grepping every
write-then-hang-up site when such a lesson is first filed), `status.md`.

## 2026-09-06 (night) — the fuzzer's peer space, widened, deadlocked the evening's own fix

The user, told that `FuzzEverything` only ever exercised eight relay peers: *"it should test high
amount of peers + above the cap/invalid stuffs as well i think ?"*. Widened the same evening -- a
wide id space off the step index, a flood of `MaxRosterSize + 88` joins in one step, eight hostile
ids, and leaves that do not always match a join.

**It failed 11.5 s into a 120 s campaign, on the dead-adapter fix committed earlier the same evening (`7334a38c`).**
`StartRecording` holds `c.rec.mu`, pushes the recording state, the write fails, and the new failure
path ran `StopRecording` -- which waits for that lock. The reproduction hung for the full ten
minutes rather than failing; the goroutine dump named both frames.

The disconnect handling is now split by which locks it needs: `releaseAdapterSlot` (one `c.mu`
section, calls nothing, still immediate) and `finishBridgeTeardown` (other locks, own goroutine from
a send failure, successor-guarded). Corpus entry committed at
`core/testdata/fuzz/FuzzEverything/37fd8ac0c532160b`. A 3-minute campaign after the fix: 27,413
executions, 80 new interesting inputs, clean. Records: `verified.md`, `pitfalls/by-lesson.md`,
`ideas.md`, `status.md`.

## 2026-09-06 (night, later) — the third axis: recordings, and the point where scale stops paying

The user, checking the widening: *"so now we are doing a random amount of peer, recording & chasing
ghosts ? above/below the cap and also invalid stuffs ?"*. Answered by reading the target rather than
from memory: chasers already (0, 1, 2, 3, 8, 9, -1, 1,048,576), peers now, recordings only for
CONTENT -- at most ~24 files a run, so the 512-seat roster was never approached from that side.

A zip of `MaxRosterSize + 40` clips closed it and then had to be pulled back out. 512 replay ghosts
rendering over the bridge cost ~10 s an execution; the target went from 207 execs/s to zero and the
engine killed the worker as hung (that input does not reproduce and is not committed). The fuzzer
keeps eight clips a zip; the crowd became
`core.TestAZipOfMoreClipsThanTheRosterHasSeats` -- 552 clips, exactly 512 admitted, 0.04 s. The peer
flood stays, because a join with no state renders nothing and 600 of them are nearly free.

Records: `verified.md` (the same 2026-09-06 entry, extended), `testing.md` (the cost rule, beside
the order-vs-scale one).


## 2026-09-07 — mapping the games this contract was NOT built for, and a refusal that became a door

Docs only; no code, no adapter, no contract change. The user asked how online and co-op would work
in games that are not one avatar in a world -- stage/lobby, turn-based, RTS, colony sims, cursor-only
and point-and-click, base-builders, mode-switching party games, follower and character-swap parties,
local co-op -- and said plainly that they had no mental model for it. New concept doc,
`agent_docs/game-shapes.md` (915 lines), indexed in `agent_docs/README.md`, sitting beside
`access-models.md` (how you READ a game), `beyond-cosmetic.md` (who has AUTHORITY) and
`kill-credit.md` (who gets the REWARD). Nothing scheduled, no adapter proposed.

**Three axes, the third the user's own framing** (*"some games have no coop/online, some games have
local coop, some have limited/restricted online etc -- along with multiple different shapes"*): the
SHAPE decides what crosses the wire, the SEAM decides what you can reach, the TIMING decides what it
costs. Then presence and co-op asked separately, because they are anticorrelated more often than not.

**What the file found, each grounded in something this repo had already paid for:**

- Union Room did not fail for being the game's own co-op. It failed one test -- is the second player
  driven by an INPUT SOURCE or a NETWORK SESSION -- and only the first is fabricable.
- The overflow case for co-op is what MeshGhost already is: `ideas.md`'s "spawn to the game's cap,
  then DRAW above it" generalises to a slot/ghost/cull ladder. Caps are often dynamic (Emerald's
  16 object events are shared with the map's real NPCs).
- Latency is free until a human waits on it. The shipped 450ms `interp` works precisely because
  nobody controls the remote thing -- which is why netcode beats streaming on viewpoints and
  bandwidth (~21 MB/h per stream against 5-9 GB/h video) rather than on ping.
- Two local players through one core is the exact corruption ADR 0027 fixed; the cheap way out is
  guest identity by hierarchy, which `relayOwner` already shapes.
- Threading is not a protocol question, and BOTH ends are hard: off-thread work produced a false
  finding about the GAME itself ("must hijack, can't spawn" was an artifact), while single-threaded
  hosts have nowhere to offload -- the out-of-process core is the answer to the second.
- Mod support can promise "fails visibly", never "works with everything": presence is robust to
  gameplay mods by construction, and rebuilt binaries are the real limit.

**Two corrections the user made to claims of mine that were too tidy**, both now in the file:
the input-source/network-session test was a false binary -- you can PROVIDE the session rather than
fabricate past it, which satisfies the gate by construction and is the principle already ratified by
the Unreal adapter and the 2026-08-18 Emerald spawn ADR (four caveats recorded, including that a
link trade writes a save through the game's own path, which is an ADR question); and "multithreaded
is where the trap is" understated the single-threaded case.

**The refusal that moved.** Tracing which families of online play MeshGhost cannot reach found that
every asynchronous one (a note or mark left for someone to find later) needs storage and *nothing
else* -- no simultaneity, no authority, no prediction -- so it is closed by §5's REFUSED persistence
row rather than by netcode. Two dated positions from the user followed, both now in
`beyond-cosmetic.md` §5:

1. *"its kinda nice that the server don't really need to save/use anything or make any files except
   for the log file. but i guess it can be considered if a game would ever need something
   persistent"* -- so the row is now **REFUSED as the default**, reopened only for a concrete game
   need, and the disk-free relay is a feature to keep rather than an accident.
2. *"an option we should consider, but also as an opt in and not the default if possible? not all
   games will need it"* -- which lands on §3's already-ratified rule, so persistence would be one
   more `.v1` capability on the sticky room-scoped feature set.

Also recorded there, as observations for whoever revisits and explicitly not permission: "persistence"
is **two** things and only durable relay state carries the stated cost -- a bounded, expiring,
opaque dead-drop is a shape the relay already holds in memory (escrow deposits, world custody,
`Join.State` seeds), so the delta is surviving a restart plus a TTL, with no schema to migrate. It
would be the first capability needing **two** levels of opt-in, because it is the first that costs
the relay's operator rather than the negotiating clients. And the invariant that makes the default
safe is currently free: as of 2026-09-07 there is no file-writing call anywhere in `relay/` or
`cmd/meshghost-relay/` outside a test, so "a relay nobody configured writes nothing but its log"
holds by ABSENCE -- the moment storage exists it becomes something a test must pin.

Four commits (`fedd5259`, `d1e583d3`, `049b4928`, `b342c15a`), preflight clean throughout, not
pushed. Records: `agent_docs/game-shapes.md`, `beyond-cosmetic.md` §5, `agent_docs/README.md`.

## 2026-09-07 (later) — the full-project stale-fact sweep

**The ask**, the user's words: *"make sure things are up to date and not stale, fact check things
across files, and to try to fix up things in places if possible"* — a correctness pass over what
the repo ASSERTS, not a restructuring. Plus two new `game-shapes.md` sections, written first.

**The governing rule**, the user's, and it shaped every decision below: *"docs/md's are most likely
stale, while current files + code is the actual fact. I don't want to accidentally have collision
re-enabled as a default for example due to you thinking that was the right fact."* So when a doc
and the code disagreed, **the doc was wrong and the doc got changed** — with two deliberate
exceptions, both recorded below. Checked mechanically rather than by reading the diff: across the
whole session, `git diff` on `protocol/limits.go`, `core/core.go`, `relay/limits.go`,
`packaging/release/config.json` and `packaging/config-overrides/` shows **no changed literal**, and
every hunk in the first two is comment-only.

**The method that made it worth doing.** A prior survey's findings were re-checked by six parallel
read-only agents against current source, and **that pass corrected the survey in about twenty
places** — wrong line numbers throughout, two findings that were simply false (the `.gitignore` DLL
negations already exist; `golang.org/x/text` is not a dependency at all), several counts that were
low (25 dangling ADR references, not 20; 23 stale-number lines, not 17; 97 `constexpr bool`, not
96), and one issue filed as "latent" that turned out to be live. **A survey is a hypothesis.** Every
number written this session was read from its source rather than from the doc that quoted it.

### The two things that were not documentation

**A live defect, upgraded from "latent" by tracing it properly.** `core/relaysession.go` returned a
plain `fmt.Errorf` for a bridge hello whose `game_id` differs from the one this Core already
serves. `bridgeserve.go:141` refuses a hello only when `IsPermanentRejectErr` is true, and that is
false for a plain error — so the mismatched adapter was **accepted**: it took the one adapter slot,
was sent `bridge_ready`, started recording/replays/chasers, and `retryRelayForSoloAdapter` then
span forever on an error that can never clear. `bridgeserve.go:151-154`'s own comment already
assumed this case reached `rejectBridge`; it never did. Reachable in ordinary use (`-game X` plus an
adapter for game Y), and hidden whenever a live incumbent holds the slot — which is why the
dead-incumbent release path is exactly where it bites.

Fixed with a new `AlreadyServingError`, deliberately NOT by reusing `RejectError`, whose message
says "relay refused connection" — a lie here, and that string is what `rejectBridge` sends to the
player. `contract.md:871-872` had claimed this refusal all along, so **the code was brought up to
the contract rather than the contract edited down to the code**. Regression test proven to fail
without the fix; suite green, race clean at `-count=3`.

**A regression I caused, caught, and then guarded.** A one-word `sed` edit to a COMMENT in
`run-core.bat` rewrote every line ending in the file; the commit stored it as LF where it had been
CRLF. One-line content diff, green tree, and it still ran here because `core.autocrlf=true`
re-smudges on checkout. `.gitattributes` had no `*.bat` rule at all, so 17 of 22 were already LF —
including both test runners, whose `go test ... || goto :failed` is what decides whether a failing
suite reports failure. Now pinned, with a preflight section that checks the ATTRIBUTE first (bytes
here say nothing about a Linux runner) and both halves deliberately broken once to prove they fail.
Full write-up, including what was and was NOT demonstrated: `pitfalls/method.md`.

### What the sweep actually found

Roughly forty stale assertions across `_template/`, `contract.md`, `scaling.md`, the ADRs, the
adapter docs and the Go comments. The ones worth naming:

- **`contract.md`'s port rule was inverted AND described a refusal that does not exist.** Quic keeps
  the shared port; plain udp is what silently relocates. The same false refusal sat in two Go
  comments and in ADR 0027.
- **`join.state` and `resume_token` were scoped to the ROOM**, where `relay/states.go:182-187` is
  explicit that it is the recipient's own capability — and the contract already said so itself, two
  sections down, in its own feature-scoping table.
- **`DefaultIdleKeepalive`'s comment argued from an equality that has not existed since ADR 0046**
  ("250ms is deliberately the same figure as `DefaultInterpolationDelay`"). The conclusion survives;
  the stated reason did not, so it now states the inequality it actually relies on.
- **A fabricated measurement** in Emerald's `BANDAGES.md`: a "ripple 151" subpriority inside a list
  labelled *measured*, where the source comment had measured only 152/150/148/135.
- **Twenty ADR cross-references** left dangling by the 2026-08-25 one-file-per-ADR split, which
  `architecture.md:130` records as done "unreworded" — which is precisely why they survived.

### Two checks added, and one deliberately NOT added

Both new preflight sections were broken on purpose before being trusted, per this repo's twice-paid
lesson about gates that report clean because they cannot run: **CRLF-pinned batch files**, and a
**hardcoded-clone-path** scan scoped to scripts (`dev-scripts/zoom.ps1` shipped one as a default
parameter and passed all four existing privacy scanners, which match home-directory forms only).

**The backticked-path check the plan called for was NOT built, and the reason is a real finding.**
The sweep ran: every backticked token that looks like a path, across all living docs. It returned no
defects the pass had not already fixed — and, decisively, **both real stale pointers it was meant to
catch were bare filenames with no slash** (`client-config-template.json`,
`client-config-overrides.json`). A path-shaped checker would have missed both, and a
bare-filename checker drowns in the repo's own deliberate shorthand (`BANDAGES.md`, `contract.md`,
`FLAGS.md` are written that way everywhere on purpose). **A gate that cannot catch the two cases
that motivated it is not worth its false positives.**

Also left alone after checking: `.gitignore`'s `/vendor/` is not dead but *protective* — a future
`go mod vendor` would otherwise sweep thousands of files into a `git add -A` — and its "redundant"
narrow log entries sit directly under comments recording the near-miss that produced their
wildcards.

Twenty-six commits, none pushed. Preflight clean (full, not just `-TreeOnly`), `run-gotests.bat`
green across 18 packages, `run-gotests-race.bat` clean.

### Still awaiting the user's call, so it is written here rather than left in a chat

**`status.md` carries ten items that describe themselves as resolved**, and its own header says a
fixed-and-confirmed item is deleted the moment it is (`CLAUDE.md:156`). They were listed and **not
removed**: that is ten deletions from the file the user reads daily, and the file is theirs.

`:15` (refused hello, "FIXED and confirmed"), `:17` (reconnect at ~343 ghosts), `:31` (chaser
despawn cycle), `:32` (recording indicator, "out of the queue"), `:38` (frozen-player), `:40`
(reset-to-save crash), `:45` (CI red twice, both fixed), `:46` (Archipelago coexistence — a RECORD,
which `:8` says never belongs here), `:30` (which self-flags: *"it is a RECORD not an open item —
`phase7.md` holds it; droppable from here on the user's call"*), and `:47` ("Nothing is running", a
state snapshot rather than an open item).

**`:22` is a TRIM, not a deletion** — its first clause is confirmed and its last is not: *"Open
cousin: a player afterimage born on a ghost can lose its own silhouette."* Deleting the whole line
would lose a live item, which is the failure mode this cleanup exists to avoid.

The two report-only buckets from the same pass are in [ideas.md](../ideas.md): the four-way adapter
duplication, and the 13 dev-scripts whose only mention is the README entry preflight requires.

## 2026-09-07 — the bridge stopped being able to kill a busy game

Go-side work, run and confirmed with the tools; the full account, its numbers and the two mistakes
made along the way are in [phase11.md](phase11.md)'s 2026-09-07 entry, because the defect surfaced
through the chaser pack and the pack is Phase 11's. Recorded here because it is `core`, and this
file is the Go side's running log.

Four commits: the chaser pack's shared history (1.69 GB of private queues down to 7.20 MB, and flat
in the count); `throttledConn` plus a fuzzed adapter drain rate, which is the instrument that made a
twice-live defect reproducible headlessly for the first time; the coalescing bridge writer, so a
slow adapter is sent less rather than disconnected; and the reporting the user asked for. Five
further `FuzzEverything` axes closed in the same pass after the user asked what else was not being
fuzzed — `player_frozen` turned out to appear in no fuzz target in the repo at all.

Left open with a benchmark rather than taken on: batching a tick into one `render_frame` line, which
is a bridge protocol revision. `verified.md`'s 2026-09-07 entry carries the numbers that would
justify it and the `MaxLineBytes` decision that comes with it.

## 2026-09-07 (night) — two CI findings on one evening's pushes

Both caught by CI after a local run that was green, which is the only reason either is written here
rather than nowhere.

**The race job: `sendToAdapter` is asynchronous now.** The coalescing writer (phase11's entry has
the work) changed a property nothing had stated: the call returning no longer means the adapter has
the message. Ordering is still exact — one queue, one writer — but delivery is not synchronous, and
`TestGhostCollisionNotPushedBeforeTheRoomHasSpoken` pushed a session policy and read the adapter's
inbox on the next line. The writer goroutine won that race here and lost it on CI's slower runner,
three counts out of three. Fixed at the root: the helper waits for the queue to drain, so a future
test cannot reintroduce it by writing the obvious thing, and the hazard is stated on `sendToAdapter`
itself. **`run-gotests-race.bat` — `-race -count=3`, CI's exact command — had been clean minutes
before the push**, which sharpens the standing lesson: it used to be said of `run-gotests.bat`,
which cannot run `-race` at all; here the local race job itself was green and still wrong, because
the defect was a timing window only a slower machine opens.

**The fuzz job: a nil extras map bounded two bytes short.** `extrasLengthBound` opened with
`len(extras) == 0 -> return 2` ("just `{}`"), which is true of an empty map and false of a nil one —
`encoding/json` writes nil as `null`, four bytes. Harmless in place (`extrasWithinLimit`
short-circuits `len == 0`, and four bytes cannot approach the limit) and fixed anyway, because the
bound may only ever over-estimate: an under-estimate is the one direction that could accept early.
Found on a push touching neither `protocol` nor extras, from an input (`null`) trivial enough that
it had simply never been generated in the life of that target — the case for a time-boxed campaign
on every push rather than a targeted one. CI's input is committed as the regression.

**And the count gate.** `preflight.ps1` gained "Adapter/game counts in living docs" after the user
noticed a stale "the largest and hardest of the four" — narrow by design, since a naive scan finds
40+ hits of which one was stale. It found that one: `_template/README.md` said "the two shipped
adapters" where it meant the two BizHawk ones. `pitfalls/by-lesson.md` has the reasoning and the
five negative tests.

## 2026-09-08 — a 23-agent adversarial review, and the 39 fixes it justified

**The user asked for a broad adversarial review and got one: 23 read-only agents over the server,
the client, the protocol, the four adapters and the cross-cutting concerns.** Nothing was changed by
the review pass itself. The working checklist is the untracked `REVIEW-FINDINGS.md` at the root —
one line per finding with a file:line, a failure scenario, and a mark for whether the parent session
re-verified it rather than taking an agent's word. What follows is what the review taught, not a
list of what it found; the checklist is the list.

**Three findings were one missing bound, and only the collation showed it.** Three agents, working
different files, reported a spinning replay goroutine, a frozen ghost immune to stale pruning, and
ordinary clock skew deleting a peer every tick. All three were `protocol.ValidateState` never
bounding `Timestamp` — the one field on a state that nothing checked anywhere. `MaxTimestampMs` is
`1<<42`, chosen so no difference between two ACCEPTED timestamps can overflow a `time.Duration`,
which is what both the replay player and the interpolator convert one to. One check closed all
three. The lesson is about the shape of the review, not the bug: a per-file reviewer cannot see a
root cause that only shows up as three unrelated symptoms.

**Two bugs were masking each other, and fixing one alone would have made things worse.**
`CloseGracefully` degraded to a hard close for every non-TLS connection, because `limitedConn` and
`prefixConn` embed `net.Conn` as an interface and neither re-exposed `CloseWrite` — the third
instance of that wrapper bug (`WriteUnreliable` 2026-09-02, then these two). Separately, a refused
hello was not terminal: the drain kept re-entering the whole hello block, so a second hello on a
rejected connection could complete a REAL join, taking a `max_clients` slot and spawning a ghost on
every screen that despawned two seconds later. The first bug was hiding the second, because there
was no drain to re-enter. They landed together, and the regression test demonstrates the join rather
than describing it.

**`tls_fingerprint` was bypassable two independent ways, found by two agents who never spoke.** The
pin matched any certificate in the chain rather than the leaf — and with `InsecureSkipVerify` set on
purpose (a bare IP has no CA), only `rawCerts[0]` is bound to the handshake, so an attacker
presenting `[attacker_leaf, copied_relay_cert]` passed. And under the shipped `tls: auto`, a pin
FAILURE was indistinguishable from "this relay is too old for TLS", so it fell back to plaintext:
the pin turned MITM detection into an automatic downgrade. A pin now forces `required`, on the
user's call.

**Bounds computed on unescaped bytes, twice.** `maxWelcomeRoster = 32` (2026-09-01) was sized on "a
nametag entry ~60 bytes with a maximal name". `SanitizeDisplayName` permits `&`, `<` and `>`, and
`encoding/json` escapes each to six characters, so a maximal entry is ~173 bytes: measured, a
welcome was 3787 B at 20 members and **6019 B at the cap of 32**, against `MaxLineBytes` 4096 — the
incident that cap was added for, reopened at a fifth of the player count, under a green test whose
fixture used unescaped ASCII. Same root in the world plane: authority and key were measured with
`len()` while the blob they were subtracted from was measured on the wire, so a maximal
`world_state` was 2075 bytes rather than 1115 and became undeliverable to every datagram peer. Both
bounds are now measured on the bytes that actually go out.

**The instruments flatter the code, and that is the finding most likely to matter later.** netsim's
loss is memoryless Bernoulli with no burst state: at the no-arg profile that is a 200 ms triple-gap
every ~9 minutes and a 267 ms quad about once every three hours, where real bad wifi loses 200-400 ms
in correlated bursts many times a minute. **Nothing in the default profile exercises the
150-500 ms correlated-gap regime an interpolation buffer is sized for**, which is what ADR 0046's
450 ms ladder was judging — and the error direction is that 450 may be UNDER-sized. The partition is
also global and simultaneous, so "one peer drops while the room keeps moving" has never been
produced, and `-reorder-delay` 60 ms sits below 15 Hz's 66.7 ms spacing so the documented 3%
reordering mostly does not reorder. Separately, the fake adapter's renders bypass `sendToAdapter`
entirely — a direct Go method call, no marshal, no queue, no coalescing — which is structurally why
it hid the ~350-ghost bridge ceiling, and its headline renders/s is `tick_rate x remotes`, a
restatement of the flags. None of this is fixed; it is recorded so no rate or interp verdict rests
on it unexamined.

**Tests that cannot fail, including two of ours written this session.** The suite audit reproduced a
live flake rather than arguing one: `waitAdapterDrained`, added the same day (commit `1f44bc29`) with the
writer, polled `queueLen() == 0` — but `run()` clears the queue when it TAKES a batch and writes it
several syscalls later, so the helper raced the wire it exists to observe. 1 failure in 500 with the
old helper, 0 in 1500 with `idle()`. `ci-fuzz.sh` exited 0 when a target name matched nothing,
because `-fuzz` takes a regexp and a non-match is a warning — so renaming a fuzz target silently
deleted its campaign with CI green. And TEVI's fuzz harness feeds `anim_time`/`temp_pause` while the
decoder reads `extras["anim_t"]`/`["pause"]`, so its non-finite assertion inspects nothing and
prints "0 non-finite (want 0)" unconditionally — in the file whose own header cites the 2026-09-03
lesson about exactly that. Two of the parent session's own new tests had the same shape and were
caught only by neutralising the fix and watching them still pass.

**The leak scanners could not see the file that was leaking.** All three used `grep -I`, which is
*defined* as "treat a binary file as containing no match" — so the one file type a path reaches
without anyone typing it was the one type nothing could see. `preflight.ps1 -TreeOnly` printed
"PASS no username or home-directory path in tracked files" while a tracked, shipped `UE4SS.dll`
carried the maintainer's Windows username 86 times and a clone path 65 times, and three more mod
DLLs carried one each. Compounding it, the tree-wide scan lived in `ci.yml`, which triggers on
`**.go` — so a push touching only a `.ps1`, `.bat`, `.txt`, `.cs`, `.cpp`, `.lua` or a binary was
scanned by nothing, while the hook told the reader "CI re-runs the same scan over the whole tree".
`hygiene.yml` now carries no path filter, the scanners read binaries, and the four known offenders
are LISTED with the rebuild each needs rather than excluded — an allowlist that silences a real
violation being the failure the section exists to fix.

**Six agents then fixed disjoint file sets in parallel**, each forbidden from running `git` (the
parent hit an index-lock collision doing it by hand) and each required to confirm its regression test
fails with only its own fix neutralised. That worked, at the cost of a tree that did not build
end-to-end while they ran. Two of them independently found things their brief did not name: a lost
`ready` token on the udp "connection already exists" path, and a self-deadlock writing a rotation
notice through the very `log` the writer serves.

**A verification rule that reported a correct link broken.** `preflight.ps1`'s anchor check read
UTF-8 as ANSI (Windows PowerShell 5.1's `Get-Content` default), so an em dash in a heading became
three mojibake characters and the slug never matched. It failed noisily here, but the same mangling
would as happily hide a real break in any heading with a non-ASCII character, and this repo's prose
is full of em dashes. All ten raw reads were patched.

**What is NOT done.** 109 findings remain open in `REVIEW-FINDINGS.md`, mostly LOW-severity and the
adapter-side C++/Lua/C# work, which needs a game and the user's eyes. Two contract proposals came out
of comparing against Archipelago (whose `MultiServer.py` was read for facts only, MIT and already
cleared): `protocol_version` should be a FLOOR rather than exact equality — AP's default is
`minver > version` against a rarely-bumped minimum, and MeshGhost currently runs AP's opt-in strict
mode as its only mode — and a reject reason should be a machine-readable code rather than prose,
which is the root of all four adapters substring-matching it and getting the sense inverted. Both
are ADR-shaped and were deliberately not slipped into this sweep.

**Closing the sweep: the two contract proposals were PLANNED, not built (2026-09-08).** The user's
three calls, recorded in `plans.md` ("Compatibility: a version floor both ways, and a reject code")
with the reasoning left in `ideas.md`: the floor runs BOTH ways rather than Archipelago's one-sided
minimum; the wire carries a reject code AND an explicit `retryable` flag, which is what removes the
standing footgun where `isPermanentRejectReason` treats anything unrecognised as permanent; and the
Go side lands first with the adapters following one per play session, since they are additive and
keep working untouched. On the one point where the user overrode the proposal -- a relay that
advertises no version is REFUSED, not allowed-and-logged -- the cost is written down beside the
decision: that half is the only non-additive piece, so relay operators must update in lockstep and
the release notes have to say so.

Two process notes from the same day. Committing the ideas entry is what caught a bug I had
introduced earlier the same day: adding the clone-path patterns to `.githooks/pre-commit`'s TEXT scan made
it refuse an ordinary edit to `ideas.md` over a sentence QUOTING the rule. `preflight.ps1`'s own
clone-path check has been scripts-only from the start and says why; the hook now matches it. Three
copies of one rule, changed in one place -- the same shape as the `pitfalls/` split that broke CI on
2026-08-25. And the duration gate caught a vague-duration phrase that had already landed in a commit,
because the hook scans paths and preflight scans durations: the two gates do not overlap, which is
worth knowing when deciding which one a new rule belongs in.

**Access models: eleven external projects read, and a category the file was missing (2026-09-08).**
Separate thread from the compatibility work above, doc-only, no code touched. The user asked how an
Archipelago client works with Dolphin without a patched image, then supplied a mixed list of ten more
(recomps, PC ports, Dolphin, PCSX2, BizHawk). Every licence was read from the project's own `LICENSE`
file before anything else and recorded in `licensing.md` — eleven new rows, two of them GPL-3 and
handled as facts-with-a-citation only. Three of the Archipelago forks report `NOASSERTION` on the
badge and MIT in the file, the gap that table has recorded since 2026-08-14; it held again.

What `access-models.md` gained, in two commits (`c7dfa842`, `22f48cc7`):

- **A fourth answer to the emulator drawing question**, which the file had left at three, all
  host-side. An external process can write assembled machine code into emulated RAM at runtime and
  let the GAME draw — no patched image, no forked emulator, so the GPL question never arises. It is
  the patch-and-cable shape from the Real hardware section, minus the patch and minus the cable.
- **Native ports and static recompilations are not emulator targets.** SoH's Archipelago "client" is
  a launcher handing the port an `archipelago://` URL; the recomp mod does its own networking
  in-process. Both are inject-and-socket — an ordinary adapter with the mod loader already built and
  drawing already solved. Cheapest shape in the file, and it was not in the file at all.
- **PINE came off `(verify)`** on the PCSX2 row: two independent projects drive it on unmodified
  images, and it carries `TITLE`/`ID` and `SAVE_STATE` alongside sized reads and writes.

**The finding worth remembering is the convergence, not the mechanism.** TTYD's game-side mod (GPL-3,
read for facts, nothing derived) already renders peer ghosts on GameCube, and independently arrived
at opaque map/anim name strings compared by equality, a magic plus a layout version where the client
refuses to write into a block it does not understand, and a deliberately generous watchdog. Its own
header records the trap: an in-game self-consistency check cannot do the version job, because it only
ever compares the block against what the same build wrote. That is this repo's wire-freeze
discipline, reached by someone else on a different platform — which is the strongest evidence yet
that `area_id`/`anim`-as-opaque is a correct rule rather than a local convention. Its Dolphin config
also retired an open risk from the same day's earlier section: the client raises MEM1 to 64 MB, well
past the real console's 24 MB, so free guest RAM is a much softer constraint on an emulator than on
hardware.

**What was deliberately NOT decided.** The injection route collides with a call recorded 2026-09-04
in `licensing.md`, which files console-style code injection as a closed door, citing `CLAUDE.md`'s
"nothing that ships writes a save, game state, or a ROM patch — ever". The new section says so in its
own words instead of quietly winning the argument, lists the three distinctions that might survive
(it is not a ROM patch; Crystal's adapter already writes emulated RAM; but it does put our code in
the game's execution), and leaves the call to the user and an ADR. **Nothing here is built,
scheduled, or a commitment**, and none of the eleven projects is a dependency.

### The same day, second half: the compatibility change, and nine agents in parallel

**The two contract proposals were planned WITH the user and then built** (`plans.md`,
"Compatibility: a version floor both ways, and a reject code"). Their three calls: the floor runs
both ways rather than Archipelago's one-sided minimum; the wire carries a reject code AND an
explicit `retryable` flag; the Go side lands first with the adapters following one per play session.
Then a fourth, which is the one that shaped the rest: **break everything older, once**, so the floor
has a clean line to work from. `protocol.Version` 1 -> 2, `MinProtocolVersion` 2.

Two wording corrections in that conversation are worth keeping, because both would have inverted the
design if they had gone unremarked. The user first said "at or above the current version" and then
corrected it to "min version or above" -- the two readings are opposites in effect, since comparing
against the current version is an exact match in disguise and rebuilds the flag day the floor exists
to remove. The plan now states the concrete case a future implementer can test against: **a v2.3
client must work with a v2.0 relay.** And "no version = older/unsupported" needed no special case at
all once the cutover was drawn at 2: a peer advertising nothing is below the floor by construction.

**Is a version spoofable?** The user asked, and the answer was checked rather than assumed:
Archipelago's `MultiServer.py` does NOTHING beyond the comparison -- no signature, no attestation,
no checksum, and nothing validating that a client behaves like the version it claims; the only real
auth is a slot name and an optional password. So ours is trivially spoofable and that is the same
trade. **The floor protects against accidental mismatch, not against a liar**, and it should not be
described in `docs/security.md` as if it did.

**The user then asked for the version to be fuzzed, and that was the right instinct**: both existing
relay targets hard-coded `protocol.Version` in their hello, so it was the one field nothing varied --
on the day it stopped being a constant comparison and became a decision with two outcomes.
`FuzzHelloProtocolVersion` drives negatives, zero, both int32 edges, and asserts the relay's verdict
matches `protocol.AcceptsPeerVersion` exactly, which is what stops the two ends drifting into "some
players cannot join". 67,881 executions clean, wired into CI as its own step.

**Then nine agents on disjoint file sets**, at the user's explicit ask to use as many as possible.
The pattern from the first wave held -- strict file ownership, `git` forbidden, every regression test
confirmed failing with only its own fix neutralised -- and the cost is the same: the tree does not
build end to end while they run, and three of them reported transient breakage in files they did not
own.

**THE BEST FINDING OF THE DAY CAME FROM AN AGENT REFUSING ITS BRIEF.** It was told "exactly
`MaxLineBytes` must be ACCEPTED", tried it, watched it fail, and reported the PREMISE as wrong rather
than adjusting the test to match. `bufio.Scanner` counts the delimiter against its own buffer, so a
payload of exactly the limit never fits: 4095 delivered, 4096 refused. **Every sender bound in the
repo was one byte optimistic, including both guards added earlier the same day** -- an envelope of
exactly 4096 passed the check, went out, and killed the receiver's read loop with the very
`ErrTooLong` the check existed to prevent. `MaxPayloadBytes = MaxLineBytes - 1` now holds it in one
place, pinned against the real scanner so a future Go release fails the test rather than the
production path.

**Two agent outputs needed correcting rather than accepting.** The docs agent replaced a false README
claim ("replay and chaser ghosts are ALWAYS just pictures") with a closer one -- that Emerald and
Crystal make them solid. Also wrong: neither Lua adapter references chaser or replay ids at all, and
Crystal ships the DRAWN tier with its spawn tier default-off since 2026-09-02, so the "a spawned
ghost blocks its tile" comment is in code that does not run. It would also have put an unconfirmed
on-screen claim about the vanilla games in front of users, which is what the user-verifies-the-games
rule is for. And the relay-session agent's E9 fix required INVERTING an existing test that asserted
the defect -- its concern (a stale ceiling freezing timestamps) was legitimate, so the replacement
spells out both failure modes rather than flipping the comparison.

**What the gates caught, this half.** The wire-freeze tests from the morning caught all three new
protocol fields the moment they appeared. The version test had to be updated because it asserted the
OLD semantics, so the change could not land silently. The duration gate caught three more vague
durations, one of them written into the phase entry ABOUT the duration gate. And the pre-commit hook
refused an ordinary edit to `ideas.md` -- correctly, from its own point of view, because the
clone-path patterns had been added to its TEXT scan that morning and the rule text legitimately
quotes that path; `preflight.ps1` had been scripts-only from the start and said why, so the hook now
matches it. Committing `REVIEW-FINDINGS.md` was refused for the same class of reason: a findings file
about a leaked path had quoted the literal path.

**One failure was NOT explained.** During a parallel full-suite run `./core/` failed once; the
captured tail held only teardown noise and not the test name, and seven subsequent core runs plus a
full suite pass are clean. Filed as O3 with the only useful instruction available: capture the whole
output next time, because without a test name there is nothing to bisect.

## 2026-09-08 — the Go side of the input track, logged here as well as in phase11

Three Go-touching commits since this file's last entry, all the input track (ADR 0056), whose full
account is `phase11.md`'s 2026-09-08 entries because the feature is a replay feature; this file is
the Go side's own log, so the pointer lives here too:

- `5e70a57e` — `input_sample` on the bridge, `bridge/inputlimits.go` (the limits live in `bridge`,
  not `protocol/limits.go`: `protocol` cannot import `bridge`), `core/inputrecorder.go` and
  `core/inputtrack.go`, the `replay.inputs` flag and config key, shipped off. Suite, race and a
  10-minute fuzz campaign green. The pre-existing ~17% `-race` flake in
  `TestARejectWinsARaceAgainstTheSocketClosing` was attributed the same evening (`status.md`).
- `5f23f1ca` — one unmarked `time.Now()` in `inputrecorder.go` marked `wall-clock:` (an artefact
  timestamp, the same as its neighbour); preflight's clock gate had caught it.
- `cb869f7d` — `bridge/inputlimits_test.go`: the Pseudoregalia adapter's exact `input_sample`
  lines, byte for byte as its `std::format` calls shape them, pinned as accepted by
  `ValidateInputSample`, so a change on either side that breaks the other is a red test and not a
  silently dropped track.

Nothing in `core` changed for the adapter half; the format was source-agnostic by design.

**Later the same day -- the `input_display` config section.** `79acc726`: the section lands in
every shipped config.json and `docs/config.md`, and `cmd/meshghost/shippedconfig_test.go` pins it
off. The core does not read it (the adapter does; unknown keys pass the decoder); the test exists
so a release cannot ship an overlay on. The ghost half of that display is the next Go work: the
core streaming a clip's input track to the adapter beside the clip, a new core -> adapter message
and therefore an ADR.

**Evening, the input_display keys.** Three more commits touching `cmd/` and `packaging/`: the
`input_display` section grew `unit`, `count_side` and `fps_note` (the last shipped off at the
user's call), each landing in every shipped config and `docs/config.md`, with
`shippedconfig_test.go` still pinning the section off. No core change; the adapter reads the
keys. Pushed at the end of the session -- the next session reads CI first.

## 2026-09-08 (night) — ADR 0057, the replay input stream, logged here as well as in phase11

One Go-touching change after v1.2.5: `remote_input` on the bridge (`bridge/bridge.go`, a third
adapter-local hello flag `input_tracks`), `core/replayinputs.go`, the track lookup and zip case in
`core/inputtrack.go` and `core/replay.go`, the frozen lists in `internal/gameblind`. The full
account is `phase11.md`'s 2026-09-08 (evening) entry, because it is a replay feature; suite, race
and a 90 s `FuzzEverything` campaign green, the eleven new tests each shown able to fail.

## 2026-09-08 — CI red twice on the evening push; both fixed, the flake was a second race

`gh run list` on the session's first read: run 34234373461 red in two jobs, the rest green.

- **`TestARejectWinsARaceAgainstTheSocketClosing` under `-race -count=3`** — the ~17% flake
  `status.md` had recorded that morning. The failing message was never the ordering the test
  asserts: it was `send hello: write tcp ... use of closed network connection`, the hello WRITE
  failing. Cause: the read loop starts at dial, so a relay that writes the Reject and half-closes
  before the hello lands has the Reject in the buffered channel AND the socket closed by the
  read loop's OnDisconnect before `conn.Send` runs; the send path returned the write error and
  never looked at the reject channel. Same class as the 2026-09-08 select fix, one step earlier.
  Fix in `core/relaysession.go`: the send-error path drains the reject channel non-blocking
  first, exactly as the `gone` case does. Measured locally (mingw gcc, `-race -count=50`):
  without the fix attempts 5 and 30 fail; with it 50/50 pass. The existing test is the
  regression test; nothing added.
- **`FuzzHelloProtocolVersion`** reported "a real failing input", but the failure was
  `listen tcp 127.0.0.1:0: bind: address already in use` after 22 s and ~55k execs — the
  harness listened AND dialled over real TCP once per iteration and exhausted the ephemeral
  ports. The input it wrote is meaningless and was not committed. Fix: one relay on the
  in-memory `pipeListener` for the whole campaign, as the two targets in `fuzz_test.go` already
  do, join log silenced. Local 30 s campaign: 756k execs, ~40k/s (CI on TCP managed ~2k/s), clean.

Lesson for the fuzz side: `ci-fuzz.sh` treats "Failing input written to" as a real finding, and a
harness that fails on a resource it exhausts itself produces one. Any new relay target starts from
`pipeListener`, never `startServerWith`.

`run-gotests.bat`, `run-gotests-race.bat` green. The release the user asked for (v1.2.5) waits on
CI confirming this push.

**Later: the push after that (run 34243302137) was red on two DIFFERENT things**, both fixed in the
next commit; the two above stayed green.

- **`FuzzEverything` found a real input** (`core/testdata/fuzz/FuzzEverything/f131a0858b74689b`,
  committed): the fake adapter's decoder got "unexpected end of JSON input". Cause was in
  `transport`, not `core`: `bufio.ScanLines` hands back an unterminated remainder at EOF as a
  final line, and the read loop delivered it. The shape is routine — Send closes the connection
  when a write fails on its deadline, and the front half of that line is already on the wire, so
  the peer sees half a message then FIN. Fix: the split function consumes a torn tail with no
  token. `transport/torntail_test.go` pins it (fails without the fix: `{"b":` delivered). Every
  reader shares this — core←adapter, core←relay, relay←client — so a timed-out write anywhere
  no longer produces a phantom message at the other end.
- **`TestADeadAdapterSocketFreesTheCoreForTheReconnect` under `-race`**: the busy refusal was
  CORRECT. The CI log shows the core never logged its own write failure before B's hello; adapter
  A's own 2 s write deadline fired first (the run took 2.66 s) because the core's reader fell
  behind on a loaded runner, so B met a live incumbent. The test now treats A's timeout as "keep
  pushing the remaining bytes" and only a non-timeout error as the core's close; the 20 s guard
  still covers a core that never gives up. 20/20 under `-race` locally.

Both gates green, a 45 s local `FuzzEverything` campaign clean. Lesson filed here rather than
`pitfalls.md` because both are Go-side: a fuzz finding in one package's harness can be a defect
in the package UNDER it, and a test whose precondition is "the core closed the socket" has to
observe that event, not a deadline of its own.

**Third red run (34247545500), same test, the other way round**: this time the core "never gave
up writing" inside 20 s. Reproduced locally with `-cpu 1` (fails 5/5, with or without `-race`);
a goroutine dump at 10 s showed the core's reader idle in Read, the writer idle, and all 512
chaser goroutines runnable at once. The cause was the TEST's fake clock: A's write loop advanced
it 5 ms per frame, and on one CPU the scheduler alternated "A runs and advances the clock" with
"the core drains A's buffered frames", so every sample the core stamped carried the same
gameplay time, `movingSince` never reached the 1 ms spawn window, nothing rendered, no write
failed. Two changes, both test-only: the real clock (movement is visible however goroutines
interleave), and 4 KB socket buffers on both ends of A's connection (`smallWriteBufferListener`)
so the first frame's batch already overflows them instead of several autotuned megabytes.
`-cpu 1` 10/10 under `-race`, default CPUs 20/20, both gates green.

Worth a look later, not for the release: 512 chaser goroutines all waking on every sample is a
thundering herd, and on a starved box it is what pushed the reader and the adapter off the CPU.

**The v1.2.5 release dispatch (run 34254121068) failed in `build-and-package`** before any tag or
release existed: the Windows packaging runner re-runs the suite, and `internal/e2e`'s
`TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner` could not find a port -- 200 tcp probes
in a row answered "forbidden by its access permissions", Windows' text for a reserved port. The
2026-08-20 `freePort` asked udp for a number and probed tcp on it; this runner's exclusions were on
the TCP side, and Windows hands out ephemeral ports sequentially, so 200 draws were 200 neighbours
inside one block. `freePort` now rotates three sources (udp :0, tcp :0, a random number in
20000-48999) and probes every candidate on both protocols. Test-only; the e2e package passed
locally after it. Same commit passed CI's own Windows job minutes earlier -- luck of the draw,
exactly the 2026-08-16 shape.

**v1.2.5 published** (release run 34256965402, on `17d8ad67`): three assets, the user's own
highlights as the body, not a prerelease. Five CI reds stood between the user's ask and the tag,
all Go-side and all accounted for above; two were real defects in shipped code (the hello-send
reject race, the torn-tail delivery), three were test or harness faults.

## 2026-09-09 (late) — config.json is live: a save is re-read and applied by the client

A tester's report, relayed by the user: editing config.json mid-session changed the input display
and nothing else. Why: the Pseudoregalia mod polls the file for its own keys, while every client
setting was read once by `cmd/meshghost/main.go` and copied onto plain `Core` fields -- replay,
chaser and hotkeys never looked again. The user's call: *"basically make everything refresh if
edit/save is used"*. Built (Go side, mine to verify, suite + race green):

- `core/settings.go`: `SetSmoothing` (under `c.mu`, refuses a bad curve/predict), `SetGhostCollisionPreference`
  (clears the de-dupe key, re-pushes the session policy), `SetChaserSettings` (restarts the pack),
  `SetReplaySettings` (re-arms the rings), `SetConnectionSettings` (closes the live relay session so
  the existing auto-retry rejoins with the new Hello; offline off with a game attached dials). The
  replay/connection fields were read bare from several goroutines, so they now sit behind
  `settingsMu` and every read goes through an accessor -- a write from the poll would otherwise be
  a data race the -race suite would catch.
- `cmd/meshghost/reload.go`: a 1 s mtime+size poll that applies on the second poll a change holds
  still (an editor's two-step save), re-reads into a FRESH copy of the pre-file flag values (a
  removed key falls back; an explicit flag still wins), diffs, applies per group, logs one line per
  changed key with its effect ("applied", "the next recording", "rejoining", "needs the client
  relaunched"). Hotkeys are released and re-registered through a stop channel `startHotkeys` now takes.
- Tests: `core/settings_test.go` (pack restart, policy re-push through a real relay + fake adapter,
  a rejoin observed as a second `OnRelayConnected`, ring re-arm) and `cmd/meshghost/reload_test.go`
  (every key named with old -> new, a refused curve keeps the old, a quiet save logs nothing, the
  watcher on a real file: second-poll apply, removed-key fallback, flag pin honoured).
- Suite and -race: every touched package green (`core` 124 s / 233 s under -race, `cmd/meshghost`,
  `relay`, `transport`, `bridge`). `netx/udpconn` and `cmd/meshghost-netsim` FAILED on this machine
  after a reboot with `dial udp 127.0.0.1: The requested address is not valid in its context` --
  a plain Go program dialing UDP to loopback fails the same way outside the repo, so it is the
  machine's network stack tonight, not the code (both untouched); CI's runners are the check.

Same evening, the tester's second point: `input_display.always` was confusing (they had to set
both `player` and `always`). Removed at the user's call -- the panel shows whenever `player`/`ghost`
is on -- and then decoupled from `replay.indicator` too, which used to hide both panels (the user:
*"the input history should be its own thing"*). Pseudoregalia DLL `0a944434aa98`, both installs;
unwatched. Not touched: the mod-read keys (`ghost_range*`, `replay.indicator*`, `input_display`),
which the mod already polls, and TEVI's mod, whose own config reads were not audited tonight.

## 2026-09-09 (afternoon) -- SignPath declined; a stray file found on the public repo, and the gate it now has

**SignPath Foundation declined the application** (submitted 2026-09-06) on visibility grounds, with a reapplication invited; `security-design.md`'s code-signing entry holds the letter's substance and the alternatives, none adopted. Releases stay unsigned.

**The user found `REVIEW-FINDINGS.md` on GitHub.** It had been committed on 2026-09-08 (`80fc0f3f`) despite its own header saying it was deliberately untracked; untracked again in `3d34e694` and ignored from now on. It stays in history; a rewrite of public history was offered as the user's decision and not taken. The lesson and the two new gates (root allowlist, local-only header) are in `pitfalls/by-lesson.md`, proven to fail on a plant before being trusted. The Docs run on the first push of the day failed on two older drive-rig gates (five unindexed pitfalls, one unannotated pointer cache), fixed in `a9f547ca`.

**Crystal is active** (`phase9.md`, this date) -- the next adapter to make ready for a second person.

## 2026-09-10 (night) — the release's CI: a relay restarted on a held port, and the VPN that reddened the local run

Pushing the evening's Crystal work for v1.2.6, the race job failed
`TestAutomaticTransportIsNotSilentlyDowngradedByARelayRestart`: the relay killed mid-test and
started again on the same freePort number logged `bind: address already in use` four seconds
after the old one was reaped -- the freePort TOCTOU `testing.md` records, in a restart shape.
Fixed in the harness only: `restartRelay` starts the relay again when the process exits before
its listener answers, a second apart up to ten times, and checks the process is alive after a
probe dial that connected (whatever holds the port may accept too).
`TestRestartRelayRetriesWhileThePortIsHeld` holds the port the runner's way -- a dialled
connection's local end -- and fails without the retry; its first version half-closed the holder
and Linux kept the port in FIN_WAIT_2 for a minute (ten refusals after the "release" on CI), so
both ends now close together. CI green on `8a0edd92`. Locally, `run-gotests.bat` was red on five
`netx/udpconn` tests with Windows' "address not valid in its context" on every loopback UDP dial:
Mullvad, connected since 2026-09-09 and off before that (the last green local run was 2026-09-08); disconnected, green in the same minute
(`environment.md`, onboarding checklist). The age-out re-admission fix (`fc89c4ab`, earlier that
day) had its first CI run in this batch and passed.

**v1.2.6 published, 2026-09-10 (release run 34418254910, on `c54cd21a`)**: three assets, the
user's own highlights as the body, not a prerelease. The first dispatch was refused by the
release's staleness gate (the Pseudoregalia DLL postdated a comment-only Plugin.cpp change, and
preflight had said so that evening -- the user: the second release to hit that gate). The
answer is `dev-scripts/release.ps1`, which puts the dispatch behind preflight: rebuild what it
names stale, refuse on any other FAIL, push, wait for every workflow on HEAD, dispatch with the
highlights file, wait for the run. Its own first three runs each refused or looped on the machine
rather than the repo -- nine line-ending phantoms in `git status` (the check now reads content),
PowerShell's `git` being the devkitPro shadow (git by path now), and a jq expression quoted through
two shells into gh's usage text (JSON parsed in PowerShell now, arrays unrolled for 5.1). The
fourth cut the release. `pitfalls/by-lesson.md` has the gate lesson; the DLL was deployed to both
Pseudoregalia installs and the client exe to all four game roots.

## 2026-09-10 (late) — TEVI: orbitars, their trail, the dodge fade, core expansions; a hot-reload script that double-loaded

**What was asked.** Whether driving TEVI with inputs would buy anything (no: replay clips, loopback
and hot reload already cover it, and the expensive half of the loop is the user's eyes); then *"we
are still not syncing some attack VFX, or the orbitars"*; then how bullet-hell netplay handles
projectiles. The projectile plan is in `ideas.md` (the orbitar entry). Then: start both TEVI copies
and add the orbitars.

**The rig came up double-loaded.** `tevi-hotreload.ps1 -On` looked for the shipping DLL in
`plugins\MeshGhostTevi\`, the pre-2026-08-28 folder; the deployed layout is `plugins\MeshGhost\`.
So `-Status` said "absent", `-On` copied a second DLL into `scripts\`, and the Steam copy loaded the
adapter TWICE -- two "MeshGhost v0.2.0 loaded" lines, two cores spawned on 7778 -- the exact defect
the script's header says it exists to prevent. Fixed the path, closed the game, relaunched Steam
first then the standalone; one reject on 7778 then ready on 7779, as the runbook expects. Launch
method recorded for next time: Steam copy via `steam://rungameid/2230650` (or its exe while Steam
is up), standalone via its own `TEVI.exe`.

**Built, in order, each hot-deployed and the user watching** (`tevi/UNVERIFIED.md` has the entry):
orbitars as logic-stripped prefab clones fed the peer's renderer facts (*"okay orbitars sync now"*);
the crystal-ring afterimage trail from the plugin's `FixedUpdate` (user asked for it next); the
dodge afterimage decay 6.67 instead of 1.5 (user: yellow images *"appearing way too much"*; the
game's own branch literal); core expansions -- the orb-to-human flash as a one-shot and a summon
ghost (player rig clone with the summon's animator controller, found by `subowner`). Every clone
is named under `MeshGhostRemote_<id>` so the orphan sweep recognises orbs, trails and summons.

**Dev cheats.** User: *"can you give me infinite energy, hp, meter, charge, bars etc"*, later the
crystals too (*"that's fine for a cheat/dev tool"* on them being save data). A separate
`devtools/MeshGhostTeviDevCheats` DLL, loaded by ScriptEngine from `scripts\`, never staged --
`PROBES.md` explains the exception. NuGet is unreachable from the sandbox: restore from the local
package cache with `--source`.

**Seen by the user:** the orbs, the orb trail and the dodge fade (*"works fine"*). **Found next:**
the blue trails spawned too few afterimages because the trail timer ran per MESSAGE inside the
upsert, not per frame -- moved to a per-frame tick with the peer's real trail parameters (unwatched).
**Not working, then re-derived:** the core expansions -- no summon row ever left the sender because
the first build mirrored OrbBall's legacy SkillUsing/SUMMON path; the real one is the BOOST system
(`UseBoost` -> `BoostSystem` -> `OrbsToHumanoid`, a NOAI Celia/Sable made visible ~0.33s after an
orb-to-humanoid trail). Rebuilt on that: summon ghost by type, visible flag, a cloned trail object
both ways. Unwatched at the entry's end. **Lesson:** an `ideas.md` note that names a mechanism
("summon") is a hypothesis; read the input handler's path before building on the note. **Next:** the user's
move list (in `UNVERIFIED.md`) walked with `DIAG_POOL_WATCH` on, one table row per missing effect;
then the projectile spawn event (`ideas.md`).

**Later the same night, each on the user's next look:** *"it does the summon thing now, but not the
barrier"* -> the boost shield (`FXVShield`, cloned with `isBoostShield` cleared by reflection so it
never blocks the watcher's bullets) and the platforms; *"the summon is supposed to stay still"* ->
world-fixed things now travel as absolute positions, never root-relative; *"is it due to having the
yellow trail things on me"* -> yes, the timed trail must win LAST as in the game's order. Also the
dev cheat gained `swap` (clears `BadgeCD_ChangeOrbCharger` / `NoOrbChange`) and `crystal`, and
`"map_markers"` entered config.json for the pause-map markers. Lifting the wait between core
expansions was declined: one boost state machine, and `OrbsToHumanoid` refuses while a Celia or
Sable exists.

**The barrier, three more rounds (2026-09-10, late).** Frozen ghost + no barrier: one NullReference
per message from `SetMainColor` on a clone whose Awake never ran (template parked inactive), and the
catch logged only `e.Message` -- the trace, once logged, settled it in one read. Then "no bloom, no
fade, stays too long": a timing probe showed the fade STARTING on the peer's beat, so it was
rendering, not timing; `FXVShield.SetMaterial` strips `ACTIVATION_EFFECT_ON` from the material the
clone is later built from. Lessons filed: a swallowed exception's message is not a diagnosis, log the
trace once; a clone of a self-configuring component inherits its POST-setup state (the same class of
fault as the 2026-08-14 `basesprite.enabled` clone) -- here a material with a keyword already
stripped. `tevi/UNVERIFIED.md` has the entry; the user's last word: *"yee looks correct now i think"*.

**Projectiles, the last track of the night (2026-09-10).** User: *"now i think we are just missing
all the projectiles from everything -- orbitars, some of the core expansions"*. Built in the order
`ideas.md` had already argued for, and the argument held up:

1. **Census first** (`DIAG_BULLET_WATCH`, event-triggered per birth/death, off again now). The user
   fired every orbitar shot kind in a row; every bullet flew with **zero** speed and angle drift and
   died inside a second, peak 29 alive. That is the whole justification for spawn-and-fly: a bullet
   is a pure function of its birth, so nothing needs streaming and lockstep was never available to
   us anyway (two separate worlds, no shared simulation).
2. **The dormant-prefab trick.** The receiver spawns the game's own bullet prefab but never
   registers it in `BulletManager`'s pool, so the game never ticks it: it cannot hit, check walls,
   or spend anything, while still being a real `bulletScript` that the game's own pooled follower
   effects accept and follow. That is what makes the visual exact without a gameplay plane -- most
   TEVI bullets are `USE_PS` and have no sprite at all; the effect IS the bullet on screen.
3. **Two faults the first live look found**, both fixed and unwatched at the entry's end: the
   follower effect is attached after `ShootBullet` (so a birth read on the same frame carried none,
   and those shots flew invisible -- births are re-scanned inside the ring now), and the muzzle
   flashes are not tied to a bullet at all, so they needed their own ring with an
   "effects we lit ourselves" exclusion to stop symmetric peers echoing.
4. **The extras cap bit once**: a core expansion's burst put one frame at 1047 bytes against the
   core's 1024, and an oversize state is dropped WHOLE -- a frozen ghost, not a lost bullet. Ring
   narrowed to 150ms and `BridgeClient` now trims oldest births first when a frame nears the cap.

**Session end.** Both TEVI processes exited; relay and both cores torn down. `tevi/UNVERIFIED.md`
leads with the projectile entry -- that is the first thing to judge next session. Still open after
it: the orbs' return glow (`GlowOrbsEffect`), the orb's Light on a ghost, the summon's own attacks,
and the death-event/per-kind-correction rungs of the projectile plan.


## 2026-09-10 — the player docs: `README.txt` split into `docs/`, one copy, staged into the zip

**The ask.** The user wanted "a proper easy/simple to follow" hosting and playing guide, readable
on the repo, and said the release `README.txt` was "really bloated and hard to read" and should be
split. Their framing of the player half: *"a player should never have to do anything complicated
or with lot of friction"*, *"assume the avrg player/user don't even know what a port is"*, and
each page should carry *"a simple version but also a normal bit more detailed version"*.

**The gap was shape, not content.** `packaging/release/README.txt` was 1046 lines of plaintext
that already covered everything — port forwarding, the `send_hz` bandwidth tables, `max_clients`
vs upload, transports, collision, antivirus, Proton — but it shipped only inside the zip, was
invisible on GitHub, and interleaved player and host concerns. Rewriting it from scratch would
have thrown away measured numbers; the work was re-cutting it.

**What landed.**

1. `docs/getting-started.md` (133 lines) — the player path only. No ports, no command line, no
   jargon: download, install the game's mod, set three keys, start the game. The per-game install
   is one short paragraph each pointing at `games\<game>\README.txt`. Ends with the no-server case
   (recording, replays, chaser), which needs nobody else.
2. `docs/hosting.md` (286 lines) — a "short version" (run the exe, four ways to be reachable, give
   out the address) then "the longer version" with the reasoning. Added the thing the old file had
   no answer for: a **VPN route** (Radmin VPN, Hamachi, ZeroTier, Tailscale) for anyone behind
   CGNAT or a router they do not control, framed as a normal way to host rather than a workaround.
   Every measured table carried over verbatim.
3. `docs/troubleshooting.md` (208 lines) — logs first, then the causes in frequency order; absorbs
   autostart, the antivirus section, Proton/Wine, two-instances-on-one-machine and the collision
   table.
4. `packaging/release/README.txt` — 1046 lines down to **97**: what is in the folder, what to read,
   a five-minute version, and each game's status. It is a map now, not the content.

**The drift decision, which is the part worth remembering.** Splitting the zip README into more
`.txt` files would have given every rule two homes — the exact shape `CLAUDE.md` warns about, and
the reason the old file could contradict itself (its `listen_udp` server entry was a mangled
paste of the transport entry, and its `replay.gzip` block said both "(off)" and "(on)" a few lines
apart; both are gone with the sections). So `docs/` is the single copy and
`stage-release.ps1` restages **every** `docs/*.md` into the zip as `docs\*.txt` on each run —
`.gitignore`d, never committed. `release.yml` already calls that script and already zips
`packaging\release\*` wholesale, so the workflow needed no change.

Two things the first dry run caught, both now commented in the script: PowerShell 5.1's
`Get-Content -Raw` reads a BOM-less UTF-8 file as system ANSI, so every em dash was staged as
genuine mojibake (`[System.IO.File]::ReadAllText` with an explicit encoding fixes it); and the
flattened links pointed at `.md` names that do not exist in the zip, so a bare `<name>.md` token
is rewritten to `.txt`. Staged as `.txt` rather than `.md` because `.md` has no default
association on Windows and prompts "how do you want to open this?" — friction for exactly the
reader these pages are for.

**Preflight caught two hard-coded game counts** ("all four mods ignore it") in the new pages —
reworded to "every shipped mod". The remaining `FLAGS.md` failure is the uncommitted TEVI
`GhostBulletsRunGameBehaviour` work, untouched here.

Living pointers updated: the root `README.md` docs list and Setup section, `docs/config.md`'s
"where to read more", and the three in `packaging/README.md` that named `README.txt` as the place
a rule is documented. The dated references in `adr/`, `risks.md` and the other phase files are
left alone — they are records of what was true on their date.

**Not verified by the user.** These are docs, so there is nothing on screen to confirm; what is
confirmed is that `stage-release.ps1 -NoBuild` stages 11 guides with correct encoding and live
pointers, and that preflight is clean apart from the pre-existing TEVI flag.

## 2026-09-10 (later) — the player docs, trimmed to what a reader needs, and two checks that were not checking

Continues the entry above, after the user read what had been written.

**What the user cut, and the rules behind the cuts.** Each began as a specific edit and generalised
into a rule now in agent memory:

- *"no need to include things like 'takes 5min' or dumb made up durations"* — nobody had measured
  it. The same shape `CLAUDE.md` already bans elsewhere -- but preflight's duration check matches
  only the larger units, so **"minutes" passes straight through it**.
- *"or even just including 'this does not include x,y,z'"* — "No ports, no command line, no
  accounts" plants three worries to reassure against one.
- *"we don't need extra fluff and stuffs inside the release itself. it should be a guide on how to
  use it/where to place things. and nothing else"* — whoever reads a file inside the zip has
  already downloaded MeshGhost; they are not deciding whether to want it. The release `README.txt`
  lost its opening pitch, the status table and the ROM disclaimer: **1046 → 74 lines**.
- *"if something is in the release its considered good enought already"* — the `EXPERIMENTAL`
  blocks came out of TEVI's and Pseudoregalia's shipped READMEs. Pseudoregalia's black flash stayed
  as one line: a thing a player will see is information, a confidence label is a hedge.
- The root README's Setup became three links. Checked rather than assumed before cutting — every
  removed fact has a home, and the one that mattered (the ROM line, a policy statement rather than
  a step) survives in the Licence section and in `getting-started.md`.

**A correction worth keeping.** I attributed "No shared items, enemies, health or story progress"
to the user; it is AI-generated prose that had settled into both the release README and the root
one. Do not assume existing wording is theirs.

**Two checks that were not checking what they claimed.**

1. The zip's staged guides cited each other as REPO paths (`docs/security.md`), which name nothing
   in a zip where the file is `docs\security.txt` beside them — **39 dead pointers**. The staging
   step now rewrites those too, while leaving `agent_docs/...` alone, since that folder genuinely
   does not ship. The lookbehind is what separates them: `_` is a word character.
2. The user hit **"Error loading page"** on `docs/getting-started.md`'s Releases link. GitHub
   resolves relative links against `/blob/<branch>/`, so `../../releases` is right from a root file
   and one `../` short from `docs/`. Preflight's relative-link scan **already had a rule for this
   and was skipping it** — an exemption commented "GitHub route", written for `README.md` and
   applied at every depth, so it exempted exactly the form whose correctness depends on depth. The
   exemption is removed. Folded into that section rather than added beside it; my first attempt was
   a second checker, which is the two-homes drift this repo keeps paying for.

Both negative-tested against the real defect. Audit while there: 978 relative links across 175
tracked `.md`, 0 broken, 0 escaping. `pitfalls/by-lesson.md` carries both lessons, indexed.

**Also this session, on the Go side's behalf:** `docs/hosting.md` and `docs/security.md` now record
that `tlsx.Auto` escalates itself to `Required` once the discovery leg completes a TLS handshake
(`core/transportpick.go`) — a default client against a default relay refuses an unencrypted
session, which neither document said. No code change; the docs were behind the behaviour.

**Still unconfirmed and only the user can close it:** the three Crystal items at the top of that
adapter's `UNVERIFIED.md`.

## 2026-09-11 — the docs' voice: what the reader does not need to know about how we work

**The root README lost its Contributing and Licence sections.** The user's read, checked against
Archipelago's root README before acting on it: that project names contributing but no ROMs, no
legally-obtained copies and no licence section, and both of ours were saying what GitHub's sidebar
already says — MIT from `LICENSE`, `.github/CONTRIBUTING.md` as its own link plus the issue/PR
banner. The one fact the sidebar does not carry, bringing your own copy of the game, is already
stated where somebody acts on it (`docs/getting-started.md`, and each adapter's README). 35 lines
to 25, no anchor links into either section. The last Setup link was also relabelled: "All docs"
promised more than `docs/README.md` holds, which is the PLAYER docs and not `agent_docs/`. It
landed on the conventional plain noun, "Documentation", after "The rest of the docs" and every
qualifier tried read as awkward — the label was doing work the list does not need it to do.

**Both README indexes were checked for completeness and were already complete** — `docs/` (10 of
10), `agent_docs/` (31 of 31 at the top level), and every sub-index below it: 58 ADRs plus the
prior-art file in `architecture.md`, 8 checklists, 12 phase files, 4 `pitfalls/` files.

**Then the voice.** The user, reading `agent_docs/README.md`, found a verbatim chat quote of
themselves in the docs-rules section *"a bit personal/weird to have in the repo"*. It was a style
rule quoting a chat message, and the quote said nothing the rule did not — unlike a
`VERIFIED.md` quote, which IS the confirmation the repo gates on and stays verbatim. Rewritten in
the project's voice, date kept. `All three are the user's` became `All three are standing rules,
not conventions to renegotiate` — the personal framing goes, the signal that a future session may
not renegotiate them stays.

**The sweep that followed, across everything a user or an outside dev opens.** Four more, and only
one of them player-facing:

- `docs/security.md` — "The user retired that reasoning outright" → "That reasoning was retired
  outright". A reviewer reading the security posture does not know who "the user" is.
- `packaging/README.md`, three times — "the user's call" / "the user's explicit preference". Worth
  fixing past the flavour: that page uses "user" to mean the PLAYER two lines away ("silently
  wipes the user's settings"), so one word was carrying two meanings in a paragraph.

Deliberately left: the reader-voice headings in `troubleshooting.md` and `antivirus.md` ("My
antivirus flagged it") are the right register for a symptom page; the `agent_docs/` links in
`reviewing.md`, `networking.md` and `integrating.md` are the point of those pages; and every
`VERIFIED.md` / `UNVERIFIED.md` quote stays exactly as the user said it.

**The lesson, if it is one:** a quote of the user is evidence in a record and clutter in a rule.
The test is whether the sentence would still gate something if the quotation marks came off.

**Two defects in `docs/hosting.md`, both found by the user reading it.** "Step 2, three ways" has
listed four since D (rent a VPS) was added, and option C was the only `###` in a file where every
other heading is `##` — A, B and D are bold lines — which is why it read as a different tier
rather than as the third of four peers. Both fixed at the source; the zip's `hosting.txt` is
generated from it by `stage-release.ps1` and is gitignored, so it needs no separate edit.

**Then the count came out entirely.** A third copy of it was in the numbered list ("pick whichever
of the three below") and had gone stale the same way, which is this repo's own *write the
invariant, never the inventory* rule (`agent_docs/README.md`) catching the page that broke it: a
hard-coded count of options is an inventory, and adding D silently falsified two sentences nobody
was looking at. Both now read "the options below" and "Step 2, your options". The
numbers-then-letters scheme is deliberate and stays — 1-4 are sequential steps, A-D are
mutually exclusive alternatives for step 2, and numbering both would make "step 2, option 3"
collide with "step 3".

**And then the LAN option came out, on the user's call.** "Everyone is on the same network
already" was two lines saying do nothing, and the user's read was that the page does not need it.
The one real cost was that the VPN option ended with "and then you are in case A" — its whole
pitch was that it converts your situation into the easy one — so that clause now says what it
means directly ("so your machine is already reachable to them"). B/C/D became A/B/C; nothing
else in the tree referenced the removed option or its letters.

**The transports section was arguing with itself about udp.** The user, reading it: the page
*"kinda makes udp still sound better/best but also trying to backpedal and explain why its bad"*.
It was worse than tone -- the quic row said "same loss handling as udp, so the same benefit on a
bad connection" while the udp row said "best on a genuinely bad connection", which cannot both be
true, and the Short version then recommended `tcp,udp` for flaky connections, the opposite of the
advice three lines above it.

**Nothing in the records ever measured udp against quic.** `verified.md` has the works-on-every-
transport facts and no relative behaviour at all, so "best on a genuinely bad connection and the
lightest of the three" was an assertion, and it is the sentence the rest of the section was
contorting around. Replaced with what is structurally true and already stated in the code:
`core/transportpick.go` has logged *"Use quic for the same loss behaviour with encryption, or
tcp"* since the pinned-udp warning was written. The docs had drifted from the core, not the other
way round.

The stance the page now takes, which is the user's and the code's: quic is preferred always, tcp
is the fallback that makes connecting easy, and udp is never preferred when quic is available --
it is the same loss behaviour with the encryption, the shared port and the troubleshooting given
up. It stays offered, framed as the raw path under quic being available on its own, because a
host being able to pick a transport is the same kind of knob as `send_hz` and interp.

**Left open, deliberately, as a decision and not a docs edit:** whether udp should stop being a
shipped option at all and survive only as a test/fuzz path for quic work. The user raised it;
nothing was changed on it. It needs a plan or an ADR, not a paragraph.

**Then udp came out of `hosting.md` entirely, on the user's call** -- *"we shouldn't try to
encurage using it over quic"*. Rewriting the row to be honest about udp still left a host reading
a page that offers a choice where there is not one: quic is preferred always, tcp is the fallback
that makes connecting easy, and no client picks plain udp on its own. So the section is now
`Transports -- tcp and quic`: the udp row, its forwarding row, the `listen_udp` 7780 paragraph,
the summary row and the udp half of the TLS-exceptions paragraph are gone, and the "isn't UDP the
fast one?" callout now answers about the PROTOCOL under quic rather than about a transport the
page no longer offers.

**It stays configurable, and the reference keeps it.** `docs/config.md` still documents
`transport`, `listen_udp` and the never-encrypted property -- the user's framing is that picking a
protocol should stay as available as changing `send_hz` or interp. The one repair that needed:
`listen_udp`'s row said "the forwarding advice below", which pointed at the hosting paragraph just
deleted and at nothing in its own file, so that row now carries the forward-UDP-on-7780-too fact
itself. A pointer whose target is deleted elsewhere is the failure mode a link checker cannot
see, because the words are not a link.

**Unsynced on purpose:** `packaging/release/docs/*.txt` are gitignored and regenerated from these
`.md` by `stage-release.ps1`, so the earlier edits in this session that hand-mirrored them were
unnecessary work. The release staging is the sync.

**The "Short version" table went too, on the user's call** -- *"TCP is not 'simpler' and the
default already works"*. It was three rows: two of them now answered a question with the same
`tcp,quic` the paragraph above had already given, and the third sold `tcp` on a simplicity it does
not have (tcp is served whether or not you list it, and quic shares its port number, so choosing
tcp saves nothing a host does). The table had been a udp-redirection device without either of us
noticing -- its flaky-connections row existed to steer people off `tcp,udp`, and once udp was gone
the row was answering itself. **The shape to watch for: a summary table that survives the thing it
was summarising away from.**

**Logged in `status.md`** as an open question: what plain `udp` is FOR now that no doc offers it.
Two preflight checks bounced the entry before it fit -- an index entry is ONE physical line, and a
status item is capped by CHARACTER count (216 was over; 147 passed), which is stricter than the
"two lines" the file's own header describes.

**And the "isn't UDP the fast one?" callout, for the same reason.** With no udp option on the
page it was rebutting a misconception the reader no longer has a way to act on. Its one fact that
still mattered -- loss handling is not SPEED -- moved into the quic row as a clause. Three
removals in a row from one page, all the same shape: **content written to steer readers away from
an option outlives the option, and reads as fluff or as an argument with nobody.**


## 2026-09-11 — a Proton client never had quic, and the log never said which transport it used

The user asked why their Linux tester seemed stuck on tcp. Two crash folders the tester had sent
for an unrelated fix (the mirrored-VFX crash, 2026-09-10) still had the `meshghost.log`s in them,
and they answered it completely.

**The cause is not quic.** Every failure reads
`quicconn: dial <relay>: listen udp 0.0.0.0:0: wsaioctl: winapi error #10045`. The address is the
LOCAL wildcard socket, so nothing was ever sent and the relay was never involved -- and the relay
was plainly serving quic, since the line above lists it among the offers. Go's `netFD.init` issues
`WSAIoctl(SIO_UDP_CONNRESET)` and, since the fix for golang/go#68614, `SIO_UDP_NETRESET`, and
RETURNS the error instead of ignoring it; Wine does not implement them and answers `WSAEOPNOTSUPP`.
That fails **every udp socket in the process**, so plain `udp` was equally impossible -- it was
simply never reached, because `netx.AutoPreference` returns at tcp before udp. Two builds a day
apart failed identically, so nothing here regressed recently.

**What the logs showed that reasoning would not have.** Sixteen `using quic` lines across eight
launches and **not one line naming tcp**: `chooseTransport` returned at its `want == netx.TCP`
branch, which sat above the `log.Printf` announcing the choice. The transport actually in use could
be learned only from the `read tcp ...` inside a later DISCONNECT message. Separately, the dial
error's hint asked "is the relay serving quic?" -- pointing whoever read it at the one thing that
could not be the cause. And the condemnation in `Core.unusableTransports` is per-process while the
core exits with the game, so the tester paid two doomed dials and 1-7 s of connect delay on every
single launch, forever.

**Three fixes.** The tcp choice is logged like any other. `quicconn.dialHint` separates a local
socket failure (`*net.OpError` with Op `listen`, which `quic.DialAddr` returns unwrapped) from a
relay-side one and says so. And `netx.UDPUsable` opens a udp socket once at startup: in `auto` mode
a machine that cannot, and a relay that offers quic or udp, skips both with one explanatory line
instead of dialling. An explicit `transport` is still never moved silently.

**Why a probe and not a Wine check, and not a config key.** The user's first instinct was a
config toggle, correctly scoped: on under Proton, off for a native Linux client. But both clients
read the SAME `config.json` out of the same game folder, so no key in it can tell them apart -- it
would pin the native client to tcp too. The probe asks about THIS PROCESS, which is exactly the
distinction wanted, needs no Wine detection, and stays right for a future Wine that implements the
ioctls. `transport: "tcp"` already existed for anyone who wants the hard override.

Tests: `core/transportlog_test.go`, `core/udpcapability_test.go`, `netx/quicconn/dialhint_test.go`
(all negative-tested). Lesson filed in `pitfalls/by-lesson.md`.

## 2026-09-11 (later) — the gates got negative-tested, and three of them could not fail

**Where it started.** The previous session's rule — *a gate never seen to fail is
indistinguishable from one that cannot* — with the user asking the obvious follow-on: is it worth
negative-testing everything? The answer taken was: yes, but as a standing harness rather than an
audit, and triaged by what a silent PASS costs, because most of preflight's sections were born
printing FAIL on the violation that caused them and that is a negative test that already happened.

**What was built.** `dev-scripts/negative-test-preflight.ps1`. A detached git worktree at `HEAD`
under `%TEMP%` is the tree under test (never the working copy, which may hold uncommitted work and
which a planted leak must never touch); the preflight copied into it is the **working copy's**, so
it tests the script about to be committed. Fifteen fixtures, one planted violation per run, reset
in between so a FAIL is attributable to one plant. Every plant reads the file back — a plant that
quietly did nothing looks exactly like a blind gate, and the fix would then land on an innocent
check. It ends by listing the sections with no fixture, so the gap is visible rather than assumed:
8 of 47 covered. `.github/workflows/gates.yml` runs it on any change to preflight, the harness or
the hook. ~25s per fixture locally.

**What it found, all three on the first pass.**

1. **Two sections were reading a different tree.** `Set-Location` moves PowerShell's location and
   not the .NET process working directory; four sections read through `[IO.File]` with a relative
   path. `Test-Path` (PowerShell's location) said the file was there, `ReadAllBytes` then read the
   same relative path out of another tree. A planted username sat in a tracked `.dll` while the
   gate said *"no NEW tracked binary embeds a machine-identifying path"*. Fixed with
   `[Environment]::CurrentDirectory = $root`. **The check was correct and pointed elsewhere** —
   invisible in the only direction anyone had ever run it, from the repo root against a clean tree.
2. **A gate scoped to a filename.** The user clicked both links in `.github/CONTRIBUTING.md` and
   got `/blob/CLAUDE.md` and `/blob/agent_docs/README.md`: GitHub drops the branch segment when it
   renders a file out of `.github/`. The check for that existed, written 2026-09-06 for the
   Security tab and keyed to `SECURITY.md`. Widened to every tracked `.md` under `.github/`.
3. **A WARN that was always on.** The reproduced-expression check warned on every clean run it ever
   had, over one accepted block of Emerald's own probe output. Now a ratchet, per file.

**Left open.** 39 sections with no fixture (`status.md` carries it). The disarmed-probe warning
prints 21 entries every run and is the same always-on shape as (3) — a candidate for the same
treatment. The records: `pitfalls/by-lesson.md`, under the UNPROVEN entry.
