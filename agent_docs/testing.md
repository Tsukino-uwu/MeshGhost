# Testing the Go client/server

How to run every automated check this project has, what each one actually proves, and the traps
that will otherwise be rediscovered. **This file is only about the Go packages and `cmd/`** — the
deterministic Go code. Adapters are a different standard entirely (see the bottom of this file).

Written 2026-08-16, when the tooling below was added; see `verified.md`'s entry of that date for
the evidence behind each claim here.

## Why the split exists at all: it is an anti-hallucination mechanism

**The user verifies the games. The agent verifies the server, the client and the code. That
division is the ground principle of this project and does not change.** Stated by the user
2026-08-18, when a new capability (the agent can now read emulator screenshots) raised the
question of whether it could move:

> *"verify is the way it is to make sure everything 100% works, and no hallucination or fake
> code/feature gets added. I verify/confirm the games, you verify/confirm the server/client and
> code. that should never change as it would break the core/ground principle for this project."*

**What each half is protecting against is different, which is why the standards are different:**

- **Go side — the agent's half.** `core`, `relay`, `transport`, `bridge` and `cmd/` are
  deterministic code against a contract this project owns. Nothing there rests on a guess about a
  game, so it can be settled by tools that cannot be talked into agreeing: a compiler, `go vet`, a
  suite that runs twice, `internal/e2e` driving real binaries, the race detector and the fuzzer in
  CI. The agent must run these itself and **must not** ask the user to watch. A claim here is
  backed by an exit code.
- **Adapters — the user's half.** An adapter's claims are about a running game whose internals are
  reconstructed from a decompilation and live observation. A wrong memory address does not throw:
  it returns a plausible number. A wrong write does not crash: it moves something else. So "it ran
  without errors" proves nothing, and **the only evidence that survives is a person watching the
  game do the expected thing.**

**The failure this prevents is specific, and it is not carelessness — it is confident wrongness.**
An agent can write code that compiles, produces sensible logs, and describes a feature that does
not work, then record it as done. Every link in that chain is self-consistent. The human gate
breaks the chain at the only point where reality is consulted rather than inferred. The
2026-08-18 Emerald session is the concrete case: six real bugs, every one caught by the user
looking at the screen, and **in every one the logs looked healthy** — a ghost wearing the player's
animation frames, a frozen ghost, a walk that should have been a run, a script firing on
interaction, a sprite off its grid, and ghosts leaking across route boundaries.

**Screenshots do not move this line.** The agent can take and read them (`environment.md`), which
shortens its own debugging loop — but the user's answer when asked directly was *"Keep the rule
exactly as it is"* and *"even with a picture, I still have to verify/confirm visually as well.
never take pictures as proof"*. A still frame cannot show motion, which is where the bugs were.
Use screenshots to ask a better question; never to answer one for the record.

**The practical rule, both directions:** never ask the user to confirm something the tools can
settle, and never record as confirmed something only a person can see. Getting the first wrong
wastes their time; getting the second wrong is how a feature that does not exist ends up in
`verified.md`.

## The short version

```
dev-scripts\run-gotests.bat
```

That is build + vet + the whole suite twice, and it is what CLAUDE.md requires before calling a
change to the Go client/server done. It needs no game, no emulator, and nobody watching.

**A green run here is not a green CI run.** Two checks deliberately only run in CI — the race
detector and fuzzing. See below.

## Does a new game need a two-machine test? No — with one carve-out

**Settled 2026-08-16**, when Pseudoregalia was confirmed between two real computers (`verified.md`).

A two-machine session proves the client, relay, and transport stack, and **none of that knows which
game it is serving**. Making every new adapter re-prove it is re-testing `relay` with a
game attached, which is slower, needs two people, and answers a question already answered.

So the default for a new game is: **loopback plus the Go suite is enough.**

**The carve-out is narrow and comes from this repo's own misses, not from caution.** Loopback echoes
your own state back to you, so it cannot exercise anything whose correctness depends on the peer
being *different* from you. Four things fall in that gap:

- a ghost initialised from local state rather than the peer's (this shipped, twice, undetectable
  in loopback by construction)
- a peer whose appearance, `game_version`, or area differs from yours
- real latency and jitter — loopback has ~none, and `contract.md` notes interpolation degrades
  *silently* under wall-clock skew between machines
- anything judged against the loopback ghost's deliberate sideways offset, which has already
  produced two suspected bugs that were probably the offset itself

**Rule of thumb:** loopback settles anything symmetric between the two sides; only asymmetry needs
two machines. That is a much smaller set than "every game needs a two-player session", and it is
the set that actually went wrong.

## What runs where

| Check | Local | CI (see below) | Release |
|---|---|---|---|
| `go build` / `go vet` | yes | yes | yes |
| Cross-compile the other shipped platforms | no | yes — compile only (`linux/arm64`, `darwin/amd64`, `darwin/arm64`) | yes — these are the tarballs' real binaries |
| Unit + integration suite | yes (`-count=2`) | yes (`-count=3`, Linux; `-count=2`, Windows) | yes (`-count=2`) |
| End-to-end, real binaries (`internal/e2e`) | yes | yes | yes |
| **Race detector** | **no — can't** (`run-gotests-race.bat` says why) | yes (Linux) | no |
| Concurrency stress (`-shuffle`, `-cpu`, repeats) | yes (`run-gotests-stress.bat`) | no | no |
| **Fuzzing** | seed corpus only | yes, short campaign per target (all eleven) | no |

**The race detector is the one real hole, and it has already cost a round trip.** CI caught a
relay race on 2026-08-16 (a join broadcast computed its recipients under a *second* lock
acquisition, so a client that joined in the window got a duplicate join it had already been told
about in its welcome) that 300 local runs of the same test never reproduced. The loop is
necessarily: push → CI fails → fix. `run-gotests-stress.bat` shortens that loop by repeating the
concurrency packages under shuffled order and two GOMAXPROCS values; it does not close it. The
durable lesson from that bug is cheaper than any tooling: **a test that asserts an invariant under
concurrent clients found it locally in 100 runs once written**, where the test that failed in CI
only failed by accident, in a misleading place.

CI is `.github/workflows/ci.yml`. **It only runs when a `.go` file, `go.mod`/`go.sum`, or the
workflow itself changed** — no tracked `.go` file belongs to an adapter, so that
filter is exactly "the client/server changed". A push touching only adapters, `packaging/`, or
`agent_docs/` produces no CI run at all, which is correct: nothing in CI tests an adapter. If you
want a run anyway, Actions → CI → Run workflow is unfiltered.

CI's cross-compile step is compile-only and exists for one narrow thing: a build-tag mistake in
the small per-OS seam (`cmd/meshghost`'s `parentGone` and `consoleWriter`), which compiles on the
OS you wrote it on and nowhere else. `darwin` has no runner at all, so this is its only coverage.

The release workflow gained its vet/test steps at the same time; before that it went from
checkout straight to build-and-zip, so the one artifact users download was the only Go build in
the repo that nothing verified. It vets and tests twice over — once on `ubuntu-latest` for the
Unix tarballs, once on `windows-latest` for the zip — and then runs three checks CI has no
equivalent of: the staleness gates that rehash the TEVI plugin's sources, the Pseudoregalia
plugin's sources, and the committed UE4SS runtime plus its submodule pin, failing the release
rather than shipping a DLL older than the source that produced it (see `packaging/README.md`).
Note it is `workflow_dispatch` only — it cannot start on its own,
and its `contents: write` permission is the reason CI is deliberately `contents: read`.

## The suites, and what each is actually for

- **`protocol`, `transport`, `relay`, `core`** — the ordinary
  suite. Real TCP throughout, including the adapter bridge: `core_test.go`'s `dialFakeAdapter`
  dials the core's bridge listener with `transport.Dial` and speaks real bridge NDJSON. The
  bridge is therefore *not* an untested seam, despite `cmd/meshghost-fakeadapter` using an
  in-process shortcut.
- **`netx`, `netx/udpconn`, `netx/quicconn`** — the transport
  implementations behind the `net.Listener`/`net.Conn` seam. `udpconn` carries the most, since it
  is the only one that hand-rolls reliability and ordering: sequence numbers, acks, the retry
  loop, the reorder window, and the per-connection token.
- **`bridge`** — **no test files of its own.** It is types and limits only, and it is
  covered where it is used: `core`'s `dialFakeAdapter` speaks real bridge NDJSON, and
  `internal/e2e` drives a real adapter across it. Worth knowing before assuming a bridge change
  is unguarded.
- **`cmd/meshghost`, `cmd/meshghost-relay`, `cmd/meshghost-netsim`** — each has its own tests,
  mostly around config/flag precedence and, for netsim, the fault injection itself.
- **`internal/e2e`** — builds and launches the real `meshghost-server.exe` and `meshghost.exe`,
  then drives a real adapter over the bridge and asserts a ghost completes the round trip. This
  is the only thing covering `cmd/`'s flag parsing and config wiring, and it is the automated
  form of the loopback check that used to mean launching two `.bat` files and watching.
- **`relay/world_test.go`** — world custody, and the file worth reading before touching
  that plane: four of its tests exist because the OBVIOUS implementation is wrong in four separate
  ways, each producing silent permanent divergence (two clients looking at different worlds, no
  error anywhere). They fail against that obvious version. `netx/udpconn/world_bounds_test.go`
  is the other half — the world plane's bounds are derived from udpconn's own constants, and the
  assertion lives in the only package that can see them.
- **`relay/online_test.go`, `core/online_test.go`** — the planes past cosmetic
  (events, sequencer, leases, escrow, snapshots, resumption, clock sync). **The concurrency tests
  there are the point of the file, not decoration**, and are the invariant harness
  `beyond-cosmetic.md` predicted would be the highest-value tool for this work: many clients race
  for one lease key and exactly one must win with everyone told the same answer, and several send
  events at once and every member must observe one identical total order. That second one **failed
  on its first run**, catching a real ordering defect (a sequencer stamp assigned under the room
  lock and delivered after releasing it, so two events stamped 1 and 2 could race to the socket).
  Written as an invariant over N racing clients rather than a tidy two-client sequence precisely
  because a two-client version would have passed.
- **`cmd/meshghost-fakeadapter`** — now has tests, where it had none: not of the circling
  ghosts, but of the control-plane invariant CHECKERS it grew 2026-08-17. A checker with no test
  of its own passes forever, including on every run where the thing it was watching was broken,
  which is the worst failure available to a tool whose whole job is to notice.
- **`netx/conformance_test.go`** — **the transport conformance suite: one set of
  behavioural assertions run against tcp, udp AND quic.** The point of `netx` is that the
  three are interchangeable behind one interface, so a behaviour that holds on one and not another
  breaks a documented guarantee while every per-transport test still passes — each of those only
  asks whether its own transport is self-consistent.
  **The rule for adding to it: if a behaviour is promised by the Transport contract rather than by
  one implementation, it belongs here.** Anything asserted is automatically asserted against every
  transport, including any added later.
  It has already paid for itself twice. It is the regression test for the quic close bug
  (`Close()` tore the connection down immediately after closing the stream, discarding the last
  message — which silently broke every send-before-close in the project, including the relay's
  Reject, so a refused quic client saw a bare hangup instead of the reason). And on its very first
  run it found a second divergence nobody was looking for: udp signals nothing at all on close, so
  a peer waits out the full 60s idle timeout. That one is a documented skip with the consequence
  named, not a deleted assertion.
- **`relay/leak_test.go`** — goroutine and connection-slot teardown. Both pass; these
  exist because a relay holds sessions for hours and nothing else asserted that a closed
  connection actually releases anything.

## Running the things the script doesn't

### Race detector

Local `-race` **does not work on this machine and is not worth retrying**:

- `gcc` on `PATH` resolves to a devkitPro MSYS2 copy whose headers cgo cannot use.
- The real MSYS2 GCC (15.1.0) cannot compile Go's `runtime/cgo` (first hit on Go 1.22,
  re-confirmed 2026-08-16 on Go 1.25) — its internal `-Werror`
  flags ignore `CGO_CFLAGS`, so there is no flag to work around it with.
- No WSL installed.

CI runs it on `ubuntu-latest`, where it needs no toolchain setup at all. The Go code is
platform-agnostic (`net`, `encoding/json`, no syscalls), so a race there is a race here.

**The local substitute is repetition.** `go test -count=10 ./...` has caught what `-count=1`,
`-count=2` and `-count=3` all missed. Do this whenever touching concurrency.

### Fuzzing

Only the seed corpus runs during a normal `go test`. To run a real campaign:

```
go test ./protocol -run=XXX -fuzz=FuzzValidateStateIsStableAcrossTheWire -fuzztime=10m
```

Each target's doc comment carries its own command. `-run=XXX` matches no ordinary test, so only
the fuzzing runs. One target at a time — Go does not support fuzzing several at once.

The targets, and the property each actually tests (none is a restatement of the code's own
checks):

| Target | Property |
|---|---|
| `FuzzValidateStateIsStableAcrossTheWire` | A state's validity cannot change across the marshal/unmarshal the relay performs to forward it — so nothing can pass the relay's gate and arrive invalid at a peer. |
| `FuzzValidPositionsSurviveNarrowingToFloat32` | No position that `IsValidPosition` accepts becomes ±Inf when narrowed to `float32`, which both 3D adapters do. |
| `FuzzEnvelopeUnmarshalNeverPanics` | The outermost decode fails cleanly on arbitrary bytes. |
| `FuzzReadLoopNeverExceedsItsLineLimit` | The framing layer never delivers a payload past its line limit, however the input is shaped. |
| `FuzzRelaySurvivesArbitraryLines` | A live relay fed arbitrary bytes still serves legitimate clients afterwards. |
| `FuzzListenerSurvivesArbitraryDatagrams` | A `udpconn` listener fed arbitrary datagrams — malformed headers, bad tokens, wrong sequence numbers — keeps accepting real sessions. |
| `FuzzValidateEventIsStableAcrossTheWire` | An event's validity cannot change across the relay's forward, so nothing passes the gate and arrives invalid at a peer. |
| `FuzzValidateLeaseAndEscrowNeverPanic` | The two arbitration planes' bounds checks never panic, and a resolved lease TTL always lands inside the honoured range. |
| `FuzzNormalizeFeaturesIsIdempotent` | Normalizing twice equals normalizing once, so two clients advertising the same capabilities are never refused a shared room. |
| `FuzzValidateWorldIsStableAcrossTheWire` | A world write survives the wire unchanged — including its `authority`, which is compared for equality against a lease key, so a string that mutates in transit means every write silently denied. |
| `FuzzRelaySurvivesArbitraryPostJoinMessages` | A live relay fed arbitrary messages *after* a real join still serves clients — the only coverage of the dispatch reaching `handleEvent`/`handleLease`/`handleEscrow`/`handleWorld`. |

**Two targets have now shipped written-but-unwired**, which makes it a pattern rather than a slip:
`FuzzListenerSurvivesArbitraryDatagrams` (fixed 2026-08-17) and
`FuzzValidateWorldIsStableAcrossTheWire` (written with `world.v1`, wired later the same day, having
never once run). **Adding a target is not done until `.github/workflows/ci.yml` has a step for it**,
and this table is where the next session checks. The udp one is the
most exposed of them: udp parses a stranger's bytes *before* address validation, room
code, or protocol version, and since the transport defaults changed it sits on the fallback path
rather than being opt-in.

If CI's fuzz job fails, the reproducing input is uploaded as the `fuzz-failure-corpus`
artifact. Download it, drop it into the matching `testdata/fuzz/<Target>/` directory, and
`go test ./<pkg>` replays it as an ordinary test case — commit it as a regression test.

## Traps

- **A relay fuzz target must discard `log` output** (`log.SetOutput(io.Discard)`). The fuzzer
  finds valid hellos within seconds and then produces tens of thousands a second; the resulting
  log volume, not the relay, collapses throughput to zero for ~18s at a stretch. This was
  misdiagnosed twice (as a slot leak, then a goroutine leak) before being isolated by subtraction.
- **Don't fuzz over real TCP.** A fuzzer opening sockets at that rate exhausts the Windows
  ephemeral port range and fails with a dial error that says nothing about the code under test.
  `relay/fuzz_test.go` uses an in-memory `net.Pipe` listener instead; the relay has no
  TCP-specific code, so `Serve` accepts it unchanged.
- **A shared fuzz server needs a raised `MaxClients`.** At the shipped default of 8, a dozen fuzz
  workers contend for slots and spend their time queueing rather than exploring inputs.
- **A test adapter must reconnect.** `core` deliberately closes a bridge connection when
  the relay is unreachable, so the adapter's own loop retries later (see `core.go`'s bridge
  `hello` handler and `adapters/_template/PROTOCOL.md`). An adapter without that loop appears to
  work whenever the relay happens to start first and silently never recovers otherwise.
- **A client can receive a `Leave` before its own `Welcome`.** The relay adds a joining client to
  the room before sending its Welcome, so a peer departing at that instant gets its Leave
  forwarded to the newcomer first. This is harmless in production (`core` ignores a
  Leave for a player it never knew), but a test that asserts the Welcome is the *first* message —
  as `relay_test.go`'s `expectWelcome` does — will fail on a busy room. Use a helper that skips
  ahead to the Welcome, like `leak_test.go`'s `awaitWelcome`. Found 2026-08-16 by CI: it failed
  all three `-race` runs while passing locally, purely on timing.
- **Never set `NDJSONConn.MaxLineBytes`/`IdleTimeout`/`WriteTimeout` after `FromConn`.** `FromConn`
  starts the read loop before returning, so the assignment races it. Use `FromConnWithLimits`.
  This exact mistake, in two tests, was the intermittent failure found on 2026-08-16.
- **`go build`/`vet`/`test` do not refresh the root `.exe` files** that `dev-scripts/*.bat`
  launch. Rebuild explicitly with `-o` first. (`internal/e2e` sidesteps this by building its own
  binaries into a temp dir every run, deliberately — a test silently exercising yesterday's build
  is worse than no test.)

## Soaking the planes past cosmetic, and what that does NOT cover

`dev-scripts/run-controlplane-soak.bat` starts a relay and 6 synthetic peers that contend for
one lease key, broadcast events at each other, and run two-sided exchanges for 60 seconds, while
every peer checks ordering, exclusivity and termination continuously. It exits non-zero if any
invariant failed. Point `-relay` at `run-netsim.bat`'s proxy to soak the same thing under loss
and jitter, and run the relay with `-introspect` to see what it thought was true while it ran.

**Read the summary line even on a pass.** A run reporting 0 claims denied, or 0 exchanges
committed, is a green result that exercised nothing — the counts are the only way to tell that
apart from a real pass.

**The measured limit, which is the important part.** With the relay's per-room send lock
deliberately removed — a real ordering defect — this rig ran **51,000 events across 8 peers and
reported no violations**, while `relay/online_test.go`'s total-order test caught the
same defect on its first run. The checkers are not broken; they have their own tests. A
ticker-driven rig simply produces far less contention per second than a tight burst of
goroutines, and Go's mutex handoff tends to preserve the very order the defect needs disturbed.

So: **the soak complements the unit tests and does not replace them.** Its value is duration,
real transports, and faults a unit test cannot reach. For a concurrency defect, the tight
in-process invariant test is still the sharper instrument, which is the same lesson this file
already records about the relay race found in 100 local runs.

## Running a session over a bad network

Everything above runs over a perfect loopback. `dev-scripts/run-netsim.bat`
(`cmd/meshghost-netsim`) is the way to run a **real** session — relay, client, adapter, game —
under loss, latency, jitter, reordering, duplication or partitions.

Added 2026-08-16, because the gap was already written down twice in this file (jitter and
clock skew untested; interpolation degrading *silently*) and the only fault injection in the
repo was a package-private drop counter inside `netx/udpconn`'s tests. That counter is
what found the lifecycle-ordering bug the same day — a `leave` overtaking its own `join`, which
stranded a peer's ghost for the whole session. The proxy is that idea at session scope.

Two things about it are easy to get wrong:

- **Point the client at `127.0.0.2`, not a different port.** The proxy mirrors the relay's port
  *numbers* on a second loopback address on purpose: discovery sends the port but not the host,
  so a client upgrading to udp/quic reuses the host it first connected to. A different port
  number routes the upgrade around the proxy, and the run looks healthy while testing nothing.
- **Keep the seed.** It is printed at startup and replays the fault sequence. Without it a
  failure is an anecdote. (The seed fixes the draws, not the interleaving of concurrent flows —
  the tool's own doc comment is careful about that and so should any bug report be.)

`-loss`/`-duplicate`/`-reorder` are udp-only and are refused rather than ignored when tcp is
being mirrored, because dropping bytes out of a proxied tcp stream corrupts it rather than
simulating loss — the kernel's retransmission is below where the proxy sits.

## Confirming a test can actually fail

A passing test is not evidence until it has been shown to fail when the thing it checks is
broken — the same instinct as CLAUDE.md's "it ran without errors is not evidence". For the e2e
round trip this is one edit: drop `-loopback` from the relay's flags in `startRelay`, and it must
fail with its own diagnostic rather than time out anonymously. Do this whenever adding a test
whose failure mode is "waits, then reports nothing arrived".

## What none of this covers

**Adapters.** Nothing here says anything about the BizHawk Lua, TEVI, or Pseudoregalia mods. Their
standard is unchanged and cannot be automated: was the expected thing seen happening on screen in
a running game, by the user. A wrong memory address or a wrong reflected name returns a plausible
number instead of crashing. See CLAUDE.md, `pitfalls.md`, and `effect-investigation.md`.

Also uncovered, by construction: two real game instances playing together (loopback echoes one
player's own state), and anything about rendering cost inside a game — see `dev-scripts/README.md`
on the load rig's three ceilings.
