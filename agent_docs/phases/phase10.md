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
introduced hours earlier: adding the clone-path patterns to `.githooks/pre-commit`'s TEXT scan made
it refuse an ordinary edit to `ideas.md` over a sentence QUOTING the rule. `preflight.ps1`'s own
clone-path check has been scripts-only from the start and says why; the hook now matches it. Three
copies of one rule, changed in one place -- the same shape as the `pitfalls/` split that broke CI on
2026-08-25. And the duration gate caught a "runs for weeks" that had already landed in a commit,
because the hook scans paths and preflight scans durations: the two gates do not overlap, which is
worth knowing when deciding which one a new rule belongs in.
