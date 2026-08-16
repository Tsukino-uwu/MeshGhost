# Testing the Go client/server

How to run every automated check this project has, what each one actually proves, and the traps
that will otherwise be rediscovered. **This file is only about `internal/` and `cmd/`** — the
deterministic Go code. Adapters are a different standard entirely (see the bottom of this file).

Written 2026-08-16, when the tooling below was added; see `verified.md`'s entry of that date for
the evidence behind each claim here.

## The short version

```
dev-scripts\run-gotests.bat
```

That is build + vet + the whole suite twice, and it is what CLAUDE.md requires before calling a
change to `internal/` or `cmd/` done. It needs no game, no emulator, and nobody watching.

**A green run here is not a green CI run.** Two checks deliberately only run in CI — the race
detector and fuzzing. See below.

## Does a new game need a two-machine test? No — with one carve-out

**Settled 2026-08-16**, when Pseudoregalia was confirmed between two real computers (`verified.md`).

A two-machine session proves the client, relay, and transport stack, and **none of that knows which
game it is serving**. Making every new adapter re-prove it is re-testing `internal/relay` with a
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
| Unit + integration suite | yes (`-count=2`) | yes (`-count=3`, Linux; `-count=2`, Windows) | yes (`-count=2`) |
| End-to-end, real binaries (`internal/e2e`) | yes | yes | yes |
| **Race detector** | **no — can't** (`run-gotests-race.bat` says why) | yes (Linux) | no |
| Concurrency stress (`-shuffle`, `-cpu`, repeats) | yes (`run-gotests-stress.bat`) | no | no |
| **Fuzzing** | seed corpus only | yes, short campaign per target | no |

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
workflow itself changed** — every tracked `.go` file lives under `internal/` or `cmd/`, so that
filter is exactly "the client/server changed". A push touching only adapters, `packaging/`, or
`agent_docs/` produces no CI run at all, which is correct: nothing in CI tests an adapter. If you
want a run anyway, Actions → CI → Run workflow is unfiltered.

The release workflow gained its vet/test steps at the same time; before that it went from
checkout straight to build-and-zip, so the one artifact users download was the only Go build in
the repo that nothing verified. Note it is `workflow_dispatch` only — it cannot start on its own,
and its `contents: write` permission is the reason CI is deliberately `contents: read`.

## The suites, and what each is actually for

- **`internal/protocol`, `internal/transport`, `internal/relay`, `internal/core`** — the ordinary
  suite. Real TCP throughout, including the adapter bridge: `core_test.go`'s `dialFakeAdapter`
  dials the core's bridge listener with `transport.Dial` and speaks real bridge NDJSON. The
  bridge is therefore *not* an untested seam, despite `cmd/meshghost-fakeadapter` using an
  in-process shortcut.
- **`internal/e2e`** — builds and launches the real `meshghost-server.exe` and `meshghost.exe`,
  then drives a real adapter over the bridge and asserts a ghost completes the round trip. This
  is the only thing covering `cmd/`'s flag parsing and config wiring, and it is the automated
  form of the loopback check that used to mean launching two `.bat` files and watching.
- **`internal/relay/leak_test.go`** — goroutine and connection-slot teardown. Both pass; these
  exist because a relay holds sessions for hours and nothing else asserted that a closed
  connection actually releases anything.

## Running the things the script doesn't

### Race detector

Local `-race` **does not work on this machine and is not worth retrying**:

- `gcc` on `PATH` resolves to a devkitPro MSYS2 copy whose headers cgo cannot use.
- The real MSYS2 GCC (15.1.0) cannot compile Go 1.22's `runtime/cgo` — its internal `-Werror`
  flags ignore `CGO_CFLAGS`, so there is no flag to work around it with.
- No WSL installed.

CI runs it on `ubuntu-latest`, where it needs no toolchain setup at all. The Go code is
platform-agnostic (`net`, `encoding/json`, no syscalls), so a race there is a race here.

**The local substitute is repetition.** `go test -count=10 ./...` has caught what `-count=1`,
`-count=2` and `-count=3` all missed. Do this whenever touching concurrency.

### Fuzzing

Only the seed corpus runs during a normal `go test`. To run a real campaign:

```
go test ./internal/protocol -run=XXX -fuzz=FuzzValidateStateIsStableAcrossTheWire -fuzztime=10m
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
  `internal/relay/fuzz_test.go` uses an in-memory `net.Pipe` listener instead; the relay has no
  TCP-specific code, so `Serve` accepts it unchanged.
- **A shared fuzz server needs a raised `MaxClients`.** At the shipped default of 8, a dozen fuzz
  workers contend for slots and spend their time queueing rather than exploring inputs.
- **A test adapter must reconnect.** `internal/core` deliberately closes a bridge connection when
  the relay is unreachable, so the adapter's own loop retries later (see `core.go`'s bridge
  `hello` handler and `adapters/_template/PROTOCOL.md`). An adapter without that loop appears to
  work whenever the relay happens to start first and silently never recovers otherwise.
- **A client can receive a `Leave` before its own `Welcome`.** The relay adds a joining client to
  the room before sending its Welcome, so a peer departing at that instant gets its Leave
  forwarded to the newcomer first. This is harmless in production (`internal/core` ignores a
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

## Running a session over a bad network

Everything above runs over a perfect loopback. `dev-scripts/run-netsim.bat`
(`cmd/meshghost-netsim`) is the way to run a **real** session — relay, client, adapter, game —
under loss, latency, jitter, reordering, duplication or partitions.

Added 2026-08-16, because the gap was already written down twice in this file (jitter and
clock skew untested; interpolation degrading *silently*) and the only fault injection in the
repo was a package-private drop counter inside `internal/netx/udpconn`'s tests. That counter is
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
