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
