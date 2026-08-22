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
  suite that runs twice, `internal/e2e` driving real binaries, the race detector (locally and in
  CI, since 2026-08-18) and the fuzzer in CI. The agent must run these itself and **must not** ask the user to watch. A claim here is
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

### The vanilla ROM is the promise; patched ROMs are best-effort

**Added 2026-08-18, on the user's call**, and it is the one place the visual gate is tiered:

> *"I think its fine if you confirm/verify Archipelago/other patches on your own as 'working' that
> way. but the vanilla always have to be checked/confirmed by me explicitly still. the base game
> should 100% work after i have verified it. other patches/modified rom/iso stuffs can just be
> 'assumed to work cuz AI checked them'. but only the vanilla/base rom/iso will be personally 100%
> verified."*

- **Vanilla / base ROM — the user watches, always.** This is what the project actually promises
  works, so nothing about it is recorded on the agent's own say-so, screenshot or not.
- **Patched, randomised or otherwise modified ROMs — the agent may confirm from its own
  screenshots**, and should label them as such (e.g. *"agent-verified on an Archipelago seed"*).
  The claim being made is weaker on purpose: it is "this looked right when checked" rather than
  "a person has seen this work".

**Why the split is sound rather than a convenience:** a patched ROM is one of an unbounded number
of generated variants that nobody can promise for, and its failures are usually address-shaped
(something moved) rather than subtle-behaviour-shaped — which is exactly the kind of thing a
screenshot and a log *can* settle. The vanilla ROM is a single, fixed artefact that every user
shares, so it is worth the human's time and the others are not.

**What does not change:** the agent still cannot confirm vanilla visuals, a screenshot is still not
evidence there, and a patched-ROM confirmation must never be written up in a way that reads as
covering vanilla too.

**Screenshots do not move this line.** The agent can take and read them (`environment.md`), which
shortens its own debugging loop — but the user's answer when asked directly was *"Keep the rule
exactly as it is"* and *"even with a picture, I still have to verify/confirm visually as well.
never take pictures as proof"*. A still frame cannot show motion, which is where the bugs were.
Use screenshots to ask a better question; never to answer one for the record.

**The gate is on the claim, not on the activity** (user, 2026-08-18): *"you are fine to test/try
things, and fix them... it just means i will have to confirm personally at the end that EVERYTHING
works as intended"*. Iterating, breaking things, and fixing them needs no supervision — only the
finished result needs the user's eyes. So batch the asking: run the loop to a coherent stopping
point, then hand over one list of what to check, rather than interrupting after every change with
"does this look right?" — intermediate states often do not survive the next fix, and the user's
attention is the scarce resource this whole toolchain exists to protect.

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

### Restated 2026-08-18, because an agent talked itself back out of it

The user, after an agent described a day of loopback testing as "not two-player confirmed" and
implied that was a gap:

> *"we already know the server/client works, its seperated from the adapters on purpose. we don't
> have to test/confirm if a game works online, as it either works online, or the adapter does not
> work at all to begin with... TEVI/Crystal don't need any 'online confirmation', nor does any
> future adapters/games at this point. the server/client + adapter split/modular setup is already
> proven."*

**"Does this game work online" is not a question about the game.** The client, relay and transport
do not know which game they are carrying — that is the whole point of the split, and it has been
demonstrated end to end on two real machines twice (Emerald, then Pseudoregalia). A new adapter
either speaks the bridge correctly, in which case the proven stack carries it, or it does not, in
which case it fails locally in loopback and two machines would only tell you the same thing more
slowly. **So: TEVI, Crystal and every future adapter need no online confirmation.**

**What the carve-out has actually cost, measured rather than feared (user, 2026-08-18):** *"it
only needed 2 actual peers, for the pole rotation in pseudoregalia. everything else has been fine
with just loopback with offset."* **One case, across four adapters and the whole project.** That
is the real weight of the list above: it is not four common gaps, it is a small set of possible
ones from which exactly one has ever bitten — Pseudoregalia's pole rotation, cleared 2026-08-16
when two real players were finally in a room together.

So the list stays, because the one case was genuine and invisible in a mirror by construction —
but it should be read as *"the rare thing to keep in mind"*, not as a standing doubt about
loopback results. **Loopback with the sideways offset is the normal, sufficient way to confirm an
adapter**, and treating it as second-best misreads four adapters' worth of evidence.

**Do not confuse this with the carve-out above.** The carve-out is not about whether networking
works; it is about **adapter behaviour that depends on the peer differing from you** — a ghost
built from local state, a peer of the other gender, real latency. Those are properties of the
adapter's own rendering, invisible in a mirror, and they stay on the list. Everything else about
"is it online" is settled and should not be re-litigated per game.

## What runs where

| Check | Local | CI (see below) | Release |
|---|---|---|---|
| `go build` / `go vet` | yes | yes | yes |
| Cross-compile the other shipped platforms | no | yes — compile only (`linux/arm64`, `darwin/amd64`, `darwin/arm64`) | yes — these are the tarballs' real binaries |
| Unit + integration suite | yes (`-count=2`) | yes (`-count=3`, Linux; `-count=2`, Windows) | yes (`-count=2`) |
| End-to-end, real binaries (`internal/e2e`) | yes | yes | yes |
| **Race detector** | **yes, with the PATH recipe below** (was "can't" until 2026-08-18) | yes (Linux) | no |
| Concurrency stress (`-shuffle`, `-cpu`, repeats) | yes (`run-gotests-stress.bat`) | no | no |
| **Fuzzing** | seed corpus only | yes, short campaign per target (all eleven) | no |
| **gofmt** | yes (`dev-scripts/preflight.ps1`) | yes — `gofmt -l` on tracked `.go`, added 2026-08-18 | no |

**The race detector used to be the one real hole, and it cost a round trip before it was
closed.** CI caught a relay race on 2026-08-16 (a join broadcast computed its recipients under a
*second* lock acquisition, so a client that joined in the window got a duplicate join it had
already been told about in its welcome) that 300 local runs of the same test never reproduced. At
the time the loop was necessarily: push → CI fails → fix. **That is no longer true — as of
2026-08-18 `-race` runs locally**, via the `PATH` recipe in the Race detector section below and
`dev-scripts/run-gotests-race.bat`, so a suspected race can be settled before a push.
`run-gotests-stress.bat` still helps by repeating the concurrency packages under shuffled order
and two GOMAXPROCS values. The durable lesson from that bug is cheaper than any tooling:
**a test that asserts an invariant under concurrent clients found it locally in 100 runs once
written**, where the test that failed in CI only failed by accident, in a misleading place.

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
- **`netx`, `netx/udpconn`, `netx/quicconn`, `netx/tlsx`** — the transport
  implementations behind the `net.Listener`/`net.Conn` seam. `udpconn` carries the most, since it
  is the only one that hand-rolls reliability and ordering: sequence numbers, acks, the retry
  loop, the reorder window, and the per-connection token. `tlsx` (TLS over tcp, 2026-08-19) is
  tested for its own behaviour — the first-byte sniff, refusing plaintext under `required`,
  fingerprint pinning — while `netx/tls_test.go` asserts the thing that actually matters, with a
  recording proxy between client and relay: **the room code is not present in the bytes on the
  wire**. That test has a deliberate negative control in the same function (with `tls` off the
  room code *is* captured), so it fails both when the feature breaks and when the test stops
  watching the right traffic.
- **`bridge`** — **no test files of its own.** It is types and limits only, and it is
  covered where it is used: `core`'s `dialFakeAdapter` speaks real bridge NDJSON, and
  `internal/e2e` drives a real adapter across it. Worth knowing before assuming a bridge change
  is unguarded.
- **`internal/gameblind`** — the structural rules, made mechanical (2026-08-20). Five tests, no
  network and no game: **no game name in library code** (comments and tests are exempt — naming
  the game a rule came from is documentation, and Go-side tests use game ids as sample data);
  **library imports stay generic**; **the wire's field lists are frozen**, so a field only one
  game needs cannot be added silently; **the three stay three** — a forbidden-import list
  that fails if server, client and adapter start merging (`_test.go` files exempt, since `core`'s
  own tests start a real relay on purpose); and **adapters never speak the relay protocol**, read
  out of the Lua/C#/C++ sources as text, vendored dependencies skipped. Read the file's header
  before changing any of it: it carries the user's wording of the rule and the burden of proof for
  a new wire field. Each was proven to fail against a deliberate violation before being kept.
- **`cmd/meshghost`, `cmd/meshghost-relay`, `cmd/meshghost-netsim`** — each has its own tests,
  mostly around config/flag precedence and, for netsim, the fault injection itself.
- **`internal/e2e`** — builds and launches the real `meshghost-server.exe` and `meshghost.exe`,
  then drives a real adapter over the bridge and asserts a ghost completes the round trip. This
  is the only thing covering `cmd/`'s flag parsing and config wiring **end to end, against the
  real binaries** — the bullet above lists each `cmd/` package's own unit tests, which cover
  precedence in isolation; this is the automated
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
  **`credit_test.go` (2026-08-19) is the third checker and a different kind of thing**: it is where
  `kill-credit.md`'s design is executable. Its claims are arithmetic over an ordered stream — a
  duplicate cannot double-count, a ratchet cannot resurrect, a stale generation cannot leak,
  participants cannot disagree about when something died — so they are settled here rather than by
  watching a game. Writing the tests immediately falsified two pieces of the first implementation
  (a bystander folded nothing and so had nothing to adopt when it joined in; an encounter first
  seen mid-fight wrongly claimed to have watched it from the start), which is the argument for
  writing them before believing a model.
  The live form is `-enemies N -features event.v1`, best run through `cmd/meshghost-netsim` on udp
  so loss and reordering are real:

  ```
  meshghost-relay.exe -addr 127.0.0.1:7777 -transport udp
  meshghost-netsim.exe -listen 127.0.0.2 -target 127.0.0.1 -loss 0.05 -jitter 25ms -latency 20ms -reorder 0.05
  meshghost-fakeadapter.exe -relay 127.0.0.2:7777 -transport udp -room soak -clients 4       -game-id credittest -features event.v1 -enemies 3 -enemy-reset-every 8s -duration 60s
  ```

  Each client gets a different difficulty scale, so the ratchet actually fires; a run where
  everyone agreed on maximum health would check the easy half of the model and call the hard half
  green. **Zero kills, and zero agreed deaths in a multi-client run with resets on, are both
  reported as violations rather than warnings** — same rule as the world plane's zero-writes check,
  and for the same reason: a checker that reports success for a run it never started is worse than
  no checker. Verified to have teeth on 2026-08-19 by regressing one client's fold and watching
  invariant 13 name it against the two healthy peers.
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
- **`core/reconnect_test.go`, `core/resume_test.go`, `internal/e2e/restart_e2e_test.go`** — what
  happens when something restarts, added 2026-08-22. The teardown that runs on a relay drop clears
  thirteen per-connection values and only one of them had a test; the roster is among them, and it
  is a trust boundary, so an id outliving the connection that named it is a security property
  rather than a tidiness one. The resume files are the first tests anywhere to run the CLIENT half
  of resumption — the relay's half was well covered, but nothing had ever exercised storing the
  token, presenting it, or discarding it when the game closes. The e2e trio kills and restarts the
  relay, the client, and the adapter in turn. Each carries its own negative control, because a
  restart test that never actually caused an outage passes for free.
- **`relay/leak_test.go`** — goroutine and connection-slot teardown. Both pass; these
  exist because a relay holds sessions for hours and nothing else asserted that a closed
  connection actually releases anything.

## Known gaps, not yet written

Found by a coverage survey on 2026-08-22 and **recorded rather than fixed**, because the same pass
was spent closing the restart/re-attach cluster instead (`core/reconnect_test.go`,
`core/resume_test.go`, `internal/e2e/restart_e2e_test.go`). Ranked by what a bug there would cost.

1. **The bridge and protocol message-type STRINGS are pinned nowhere.** No Go test contains the
   literal `"render_remote"`, `"bridge_ready"` or `"session_policy"` — the Go side uses the
   constants, while every shipped adapter hard-codes the strings in Lua/C#/C++. Renaming a
   constant's *value* compiles, keeps this entire suite green, and breaks every game.
   `internal/gameblind`'s `TestWireFieldsAreFrozen` freezes both packages' *field names* and is the
   obvious place to freeze the type values too.
2. **Relay resource bounds and refusal reasons.** `MaxLeasesPerRoom` and `MaxEscrowsPerRoom` have
   zero coverage while their world-plane twin `WorldTooMany` is tested — the asymmetry is the tell.
   The escrow timeout, which is the deadlock backstop for both-or-neither, has no test and no test
   seam; `Server.ResumeGrace` is the precedent for adding one. Four reject reasons — server-full,
   protocol-version, invalid-room-code, game-version — are asserted only as "some reject happened",
   so a relay that closed the connection *without* its reason would still pass.
3. **Transport conformance and fault injection.** `netx/conformance_test.go` carries four
   assertions and never sends anything unreliable, so the reliable/unreliable split is unasserted
   across transports — the one place a divergence is cheapest to catch. `WriteTimeout` has no test
   anywhere in the repo. Line limits are tested only at the no-delimiter extreme, never at the
   boundary and never for resync. And `cmd/meshghost-netsim`'s own `-duplicate`, `-reorder` and
   partial-loss paths have no tests, which is exactly the "a checker with no test of its own passes
   forever" failure this file already warns about for the fakeadapter checkers.

## Running the things the script doesn't

### Race detector

**Local `-race` DOES work on this machine, as of 2026-08-18.** This section said the opposite
("does not work and is not worth retrying") from 2026-08-16 until then, and the whole
`run-gotests-race.bat` / "CI is the only place it runs" arrangement was built on that. It was
wrong about the *reason*, which is why the retry that disproved it was cheap.

Run it exactly like this — the `PATH` prefix is the load-bearing part:

```sh
export CC="C:/msys64/mingw64/bin/gcc.exe" CGO_ENABLED=1 PATH="/c/msys64/mingw64/bin:$PATH"
go test -race -count=2 ./...
```

- Setting `CC` **alone is not enough** and fails with `runtime/cgo: cgo.exe: exit status 2`,
  which is the failure the old note recorded and read as "this compiler cannot build cgo". The
  compiler needs the rest of its own toolchain (`as`, `ld`, its headers) resolvable, and that
  only happens when its `bin` directory is ahead of the devkitPro copy on `PATH`.
- `gcc` on the bare `PATH` still resolves to the devkitPro MSYS2 copy whose headers cgo cannot
  use (`stddef.h: No such file or directory`). That part of the old note was correct, and it is
  the same shadowing trap `pitfalls.md` records for `cmake` and `cmd`.
- Verified end to end on 2026-08-18: with the fix in `relay/online.go` reverted, `-race`
  reported the `sess.timer` race at `online.go:844` against reads at `:876` and `:913`; with it
  restored, the full suite is clean at `-count=2`. So it does not merely build — it detects.

CI still runs it on `ubuntu-latest`, where it needs no toolchain setup at all, and that stays
the authority. The Go code is platform-agnostic (`net`, `encoding/json`, no syscalls), so a race
there is a race here — but the point of the recipe above is that a suspected race no longer has
to be pushed to find out.

**The local substitute is repetition.** `go test -count=10 ./...` has caught what `-count=1`,
`-count=2` and `-count=3` all missed. Do this whenever touching concurrency.

### Fuzzing

Only the seed corpus runs during a normal `go test`. To run a real campaign:

```
go test ./protocol -run=XXX -fuzz=FuzzValidateStateIsStableAcrossTheWire -fuzztime=10m
```

Four of the eleven targets carry a version of that command in their own doc comment (`protocol`,
`transport`, and both in `relay/fuzz_test.go` — those say `-fuzztime=60s`, and the two older ones
say `-run=Fuzz` rather than `-run=XXX`); for the rest, substitute the package and target name into
the line above. `-run=XXX` matches no ordinary test, so only
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
- **A test adapter that sends a state exactly once is a flaky test.** `forwardLocalState` DROPS a
  frame arriving inside `MinSendInterval` rather than deferring it, and nothing resends it — so a
  one-shot frame is lost for good whenever the core's read loop happens to process it back to back
  with the previous one. A real adapter sends its current state continuously; a test must too, from
  inside the wait loop. Two cross-area tests in `core_test.go` had this; local `-count=10` sweeps
  never caught it and CI's `-race` job failed one on 2026-08-22.
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

`-loss`/`-duplicate`/`-reorder` are udp-only, and mirroring tcp alongside them is **allowed** —
which matters, because the handshake is always tcp, so every real session needs tcp mirrored and
refusing the combination made `-loss` unusable in exactly the case it exists for. Instead the tool
prints a `NOTE` saying the faults reached the udp flows only; the mirrored tcp ports get
`-latency`/`-jitter`/`-partition` and nothing else, because dropping bytes out of a proxied tcp
stream corrupts it rather than simulating loss — the kernel's retransmission is below where the
proxy sits. The only **refusal** is asking for those flags when *no* udp ports are mirrored at all,
where they would silently do nothing.

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

## Watching a running system: `-introspect` and `-stats`

Neither needs a game, and both are off unless asked for. They are the two halves of the same
picture, and they should broadly agree with each other -- if they do not, one of them is wrong,
which is itself the finding.

**Relay: `meshghost-relay -introspect=10s`.** Logs what the server believes: rooms, members and
their transports, leases, escrows, world custody, and -- added 2026-08-18 -- the **cross-area state
fan-out**: how many recipients each state message reached, how many of those an area-equality
filter would have suppressed, weighted by payload bytes, plus how many distinct areas the room's
members are spread across. Measurement only; nothing branches on it. Deliberately prints counts
rather than `area_id` strings, because those are opaque game data and a host may paste a dump into
an issue.

**Client: `meshghost -stats=10s`.** The counterpart: link health (rtt, clock offset -- both were
measured and shown to nobody until this existed), peers known versus actually rendered, bytes in
and out with an hourly rate, and the share of received remote states this client discarded because
the sender was in another area.

**The gap between "known" and "rendered" is the thing to look at.** It is almost always the
cross-area filter, and a client showing many known and few rendered is paying full inbound cost for
ghosts it never draws -- which is the entire argument for filtering at the relay
(`agent_docs/risks.md`, "Cross-area state fan-out").

Driving them without a game:

```
meshghost-relay.exe -addr=127.0.0.1:7941 -transport=tcp -introspect=3s
meshghost.exe -relay=127.0.0.1:7941 -room=demo -game=faketest -name=me -bridge=127.0.0.1:7999 -stats=4s
meshghost-fakeadapter.exe -relay=127.0.0.1:7941 -room=demo -game-id=faketest -clients=2 -area-id=town -duration=12s
meshghost-fakeadapter.exe -relay=127.0.0.1:7941 -room=demo -game-id=faketest -clients=2 -area-id=cave -duration=12s
```

Two fakeadapter processes with different `-area-id` is how you get a room that is genuinely split
across areas -- one process gives every peer it runs the same area. Sanity check for the maths: 4
peers split 2-and-2 means each state reaches 3 peers of whom 2 are elsewhere, so the relay should
report 67% cross-area, and it does.

**A client with no adapter attached reports 0% cross-area, and that is correct, not a bug.**
`localAreaID` is only set from a real adapter frame, and an unknown local area filters nothing --
the core's fail-open rule. It will still show the full inbound byte cost, which is a
useful demonstration on its own.

## `dev-scripts/preflight.ps1` — run this before handing anyone a game

Read-only: it inspects and reports, never builds, deploys or commits. Every check in it exists
because that exact thing went wrong and cost a live test, and a live cycle costs the user a real
game launch and a replayed save, so this is the cheapest minute in the loop.

```
powershell -ExecutionPolicy Bypass -File dev-scripts\preflight.ps1
```

What it checks: gofmt on tracked `.go`; the public-repo leak grep in **both** slash directions;
CLAUDE.md's 300-line cap; the four root `.exe` files being newer than the newest non-test `.go`
(`go build ./...` does NOT refresh them, and `dev-scripts/*.bat` launch those exact names); both
committed mod DLLs against every source hash in their `built-from.txt`, which reproduces
`release.yml`'s staleness gate locally; CRLF in the LF-pinned adapter sources; and any MeshGhost
process left running from a previous session.

Optionally also compares the DEPLOYED copies in the live game installs against the freshly built
ones — set `MESHGHOST_TEVI_DLL`, `MESHGHOST_TEVI_DLL_ALT` and `MESHGHOST_PSEUDO_DLL`. Env vars
rather than literals because install paths are machine-specific and this is a public repo. Worth
setting: the repo's staging copy being fresh does not mean the GAME is running it.

**Two bugs it had on its first run, both worth knowing about, because both are the shape where a
checker quietly passes:**
- It compared the binaries against `*_test.go` too, so a test edit reported four fresh binaries as
  stale. Over-eager rather than dangerous, but it trains a reader to ignore the check.
- It measured CLAUDE.md with `Measure-Object -Line`, which counts only NON-EMPTY lines: it read
  288 for a 300-line file and would have passed a CLAUDE.md sitting 12+ lines over the cap. RULE 0
  is written in terms of `wc -l`, so the gate now uses `(Get-Content).Count`, which measures the
  same thing. **A gate that disagrees with the rule it enforces is worse than no gate.**
