# Reviewing this yourself

A guide for auditing this project before hosting a relay or playing with strangers: which code
runs where, what the project claims about it, and how to run the adversarial checks on your own
machine. Nothing here asks for trust in the author or the tests; it points at what to read and what
to run.

Two facts a reviewer should have up front. The code in this repository is written entirely by an
AI agent, directed and tested by the maintainer. And the relay is internet-facing, so the standard
that matters is the one for network code: not "does it work" but "what happens on the input nobody
planned for".

## What runs on which machine

Two different questions, two different surfaces:

| You want to... | What runs on your machine | The code a stranger can reach |
| --- | --- | --- |
| **Host a relay** | `meshghost-relay` (`meshghost-server.exe` in a release) | `relay/`, `transport/`, `netx/` (`udpconn`, `quicconn`, `tlsx`), `protocol/`, `internal/cfg`, `internal/textfmt`, and `cmd/meshghost-relay/main.go` |
| **Play** | `meshghost` (the core) plus the game's adapter | `core/` on the relay side, then `bridge/` and the adapter on the game side |

The adapters never touch the internet. An adapter holds one localhost socket to its own core and
nothing else; it never learns a relay address (`agent_docs/contract.md`, hard rules). So a host
review is the first row, and it is a few thousand lines, not the whole repository. Do not take that
on faith either: Go compiles only what a binary imports, so `go list -deps ./cmd/meshghost-relay |
grep MeshGhost` prints that row and you have the exact code in the process you would run. And every
socket the tree opens is greppable:

```sh
grep -rnE 'net\.(Listen|Dial|ListenPacket|ListenUDP)|quic\.(Listen|Dial|Transport)' --include=*.go . | grep -v _test.go
```

Read that output knowing two things. Most hits are `net.Listener` *types* and comments rather than
calls — roughly a dozen of them open anything. And **there is no `quic.Listen` call in this tree**:
QUIC is served by `Listen` on a `quic.Transport` value (`netx/quicconn/quicconn.go`), over the
`net.ListenUDP` this pattern does catch, so grepping for the obvious name finds the type declaration
and a comment instead of the line that starts serving.

If you want the whole shape before the surfaces, [agent_docs/orientation.md](../agent_docs/orientation.md)
is the project in plain words, written for the maintainer: its first three sections are how a ghost
travels from one game to another and which folder holds what, and the rest is internal working
practice you can skip.

## Where the bytes go

A review of network code is mostly following attacker-controlled bytes from the socket to every
place they are used, and asking at each step what has been checked so far. This is that path, so
you can start reading at the right line instead of the top of the file.

**Into the relay** (what a host exposes):

1. `cmd/meshghost-relay/main.go` binds one listener per configured transport through
   `netx.ListenWithTLS`. Every listener is wrapped in `netx.LimitListener` (a cap on open
   connections, per listener and since 2026-09-15 per client address too — `netx/srclimit`) and,
   for tcp with TLS on, `netx/tlsx` (the TLS-or-plaintext sniff). quic is `netx/quicconn`,
   presenting a datagram socket as a `net.Listener`; `netx/udpconn` is the same idea for plain udp
   and is compiled only under the `meshghost_devudp` build tag — a release binary contains none of
   it (`go tool nm` on the binary finds no `udpconn` symbol).
2. `relay.Server.Serve` accepts and starts `handleConn` (`relay/relay.go`). That function is the
   whole per-connection state machine and is worth reading end to end: it wraps the socket in
   `transport.NDJSONConn` with `protocol.MaxLineBytes` as the line cap (enforced *during* the read,
   in `transport/transport.go`'s `readLoop`), arms the hello timer, and registers `OnReceive`.
3. `OnReceive` runs, in order: **the already-rejected latch** (`rateRejected || handshakeRejected`,
   `relay/relay.go`) — read that one first, because its absence was a live hole found by the
   2026-09-07 review: a refused peer could pipeline a second, valid `hello` during the graceful-close
   drain and complete a genuine join over a half-closed socket, taking a `max_clients` slot and
   spawning a ghost on every real player's screen; then the per-second flood cap; JSON decode of the
   envelope; if not yet joined, only a `hello` is accepted, and its checks run field-length →
   protocol version → room code (constant-time) → query-only → single-game restriction → room
   join/create → resume → slot reservation. Everything before the room is touched is where a
   stranger with no code lives.
4. Once joined, each message type is decoded into its struct and passed through the matching
   `protocol.Validate*` (`protocol/limits.go`, `protocol/online.go`) before anything is done with
   it; deeper planes are gated on the room's negotiated features. State fans out through
   `Room.forward` into each recipient's `outbox` (`relay/outbox.go`), which is what protects
   everyone else from one peer that stops reading.

**Into a player's machine** (what a peer or a hostile relay reaches):

5. `core/relaysession.go`'s `handleRelayMessage` is the only reader of the relay socket. It
   keeps its own roster (bounded), drops state for any id it never saw announced, re-validates
   every field, and re-sanitizes names (`core/remotenames.go`).
6. What survives is written to the bridge (`bridge/bridge.go`, localhost only) as `render_remote`
   and friends, and the adapter renders it. The adapter never sees the relay. What each adapter
   does with each field is its own review, and each adapter's own folder carries it —
   `documentation.md` for how that game works and `FLAGS.md` for every switch it has, in
   `adapters/pseudoregalia/`, `adapters/tevi/`, and `adapters/emulator/pokemon/<game>/` for the
   two Pokémon ROMs. **Start an adapter review at its `SYNCED.md`**: every value that game sends
   and receives, what the other player's game does with it, and how each one is checked on
   arrival. A value with no check says `not checked yet` in its row, so those rows are the
   adapter's open attack surface, listed; preflight fails if the page and the send code disagree.

**Dependencies.** One: `github.com/quic-go/quic-go`, plus its `golang.org/x` transitive set. TLS,
HMAC, JSON and the UDP socket are the Go standard library. There is no dependency for the wire
format, the framing or the relay logic, so there is nothing to audit but this repository and Go.

## What the project claims

[security.md](security.md) is the list of claims — what a hostile client can and cannot do to a
host, what each transport does and does not protect, every limit and where it is enforced, and a
known-gaps section that says what is deliberately not defended. Each claim there names the file
and, where one exists, the test that pins it. Treat it as a list of things to disprove: a written
claim that turns out false is worth more to you than a vague codebase, because it tells you at once
how much to trust the rest. One section carries the date it was last checked against the code, and
the rest are dated by the change they record rather than by a re-check — so an undated claim there
is one nobody has re-read recently, and is the place to start.

[networking.md](networking.md) explains the transports and the limits from the operator's side.
[agent_docs/contract.md](../agent_docs/contract.md) is the wire protocol itself, and its Limits
section lists most bounds with the constant name each comes from. It is not exhaustive: the
`world.v1` bounds and a few others live only in the code, so `protocol/limits.go`,
`protocol/online.go` and `bridge/inputlimits.go` are the authority when the two disagree.

## Run the adversarial checks yourself

You need Go (the version in `go.mod`) and a clone. Nothing else. Nothing here needs a game.

**The whole suite, twice, including the end-to-end test that launches the real binaries and drives
a real adapter over the bridge:**

```sh
go build ./... && go vet ./... && go test -count=2 ./...
```

**The race detector** (CI runs it on every push; it has found real relay bugs local runs missed):

```sh
go test -race -count=3 ./...
```

**The fuzzers.** These feed inputs nobody chose into the parsers and the listeners, and they are
the part that does not share the author's blind spots. Run any of them for as long as your
suspicion lasts; CI runs a short campaign against nearly all of them on each push — as of
2026-09-10, **25 explicit steps in `.github/workflows/ci.yml` against the 27 `Fuzz*` targets in the
tree**, across eight packages, one step per target (since 2026-09-15 one line per target, spread across six
parallel shards so the job takes its longest shard's time rather than the sum). The two with no step are the schedule fuzzers in `core`, opt-in on
purpose because each stands up a real relay socket; only `FuzzSchedule` still runs its seeds in the ordinary
test job, from the target plus a committed corpus in `core/testdata/fuzz/`.
`FuzzNameDeliverySurvivesAnyConnectOrdering` runs **nothing** — its skip is before `f.Fuzz`, so it
takes the seeds with it. This page claimed otherwise until 2026-09-12, in the same paragraph that
warns the census is maintained by hand. (A third, `FuzzParseInputTrackNeverPanics`, was unwired until 2026-09-10 — a file
parser that shipped with an ADR and no step, while this page and two others said the gap was only
the socket-bound pair. Worth knowing as a reviewer: the census is maintained by hand.) (The property-style targets that pin an encoder against its decoder have their own steps
too, since 2026-09-06 — they used to run only as ordinary tests.) Nothing here needs
trusting CI — the targets are ordinary `go test -fuzz` functions:

```sh
# the relay, fed arbitrary lines before and after a join
go test -run='^$' -fuzz='^FuzzRelaySurvivesArbitraryLines$' -fuzztime=5m ./relay
go test -run='^$' -fuzz='^FuzzRelaySurvivesArbitraryPostJoinMessages$' -fuzztime=5m ./relay
# the udp listener, fed arbitrary datagrams -- dev build only since 2026-09-15, so the tag is needed
go test -tags meshghost_devudp -run='^$' -fuzz='^FuzzListenerSurvivesArbitraryDatagrams$' -fuzztime=5m ./netx/udpconn
# every wire decoder
go test -run='^$' -fuzz='^FuzzEnvelopeUnmarshalNeverPanics$' -fuzztime=2m ./protocol
go test -run='^$' -fuzz='^FuzzEnvelopeUnmarshalNeverPanics$' -fuzztime=2m ./bridge
```

The full list is `grep -rn '^func Fuzz' --include=*_test.go .`. The CI campaign is a written list
of steps in `ci.yml`, one per target, so compare the two yourself: a target the grep finds and the
workflow lacks is one only a local run has ever fuzzed.

**Verify a release binary came from this source.** Releases are built with `-trimpath` and no cgo,
so a build of the same tag with the same Go version is byte-identical to the shipped file. The
shipped file says how it was built:

```sh
go version -m meshghost-server.exe     # prints the Go version, the module version and the build flags
```

Then, on any machine, with that Go version installed:

```sh
git checkout v1.2.3
# The Windows version resource (Properties > Details) is generated at build time, so it has to be
# regenerated the same way; the version is the tag without its v. Skip this for a Linux or macOS build.
go run github.com/tc-hib/go-winres@v0.3.3 make --in cmd/meshghost-relay/winres/winres.json --out cmd/meshghost-relay/rsrc --arch amd64 --product-version 1.2.3 --file-version 1.2.3
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -o meshghost-server.exe ./cmd/meshghost-relay
sha256sum meshghost-server.exe         # compare with the digest GitHub shows beside the release asset
```

A matching digest means the asset is exactly this source; a mismatch means either a different Go
version (check the first command) or a file that is not what the tag builds.

**Drive a relay by hand.** The tcp transport is newline-delimited JSON inside TLS (every
connection, since 2026-09-15; a plaintext `nc` is closed at the first byte), so the hand tool is
`openssl s_client -connect host:7777 -alpn meshghost -quiet` and typing. The protocol is in
`agent_docs/contract.md`; the reject reasons you will get back are in `protocol/protocol.go`.

## Reading the tests

A regression test here is kept only after it has been seen failing without its fix (a rule in
`CLAUDE.md`), and each test's comment says what it failed on and when. A test still only proves
the author's model of the input, so the useful question when reading one is what it never sends:
a size it truncates, a case it skips, a value it canonicalises first. Each of those is a class of
input the suite has not tried.

## The decision records worth reading

`agent_docs/adr/` is the full decision log, one dated file per decision, and it is long. These are
the ones that carry security weight, in the order a reviewer would want them:

- [0044 — the first adversarial review](../agent_docs/adr/0044-2026-09-02-the-first-adversarial-review-and-what-it-changed.md):
  what hostile readers found, what was fixed, what was left alone and why. Read this first; it
  shows where the last review looked, so the next one can look elsewhere. Three passes followed
  (2026-09-07, 2026-09-12, 2026-09-13); the fourth was the first to ask the question a host asks —
  "I want to run this on a server" — with nine read-only reviewers split by where the attacker
  stands (a stranger with the address, an on-path observer, a room member, a hostile relay, the
  test instruments themselves). Its findings and fixes are the 2026-09-15 section of
  [security.md](security.md); its two decisions are
  [0064 — per-source state lives in `netx` and is never logged](../agent_docs/adr/0064-2026-09-15-per-source-state-lives-in-netx-and-is-never-logged.md)
  and [0065 — plain udp is dormant](../agent_docs/adr/0065-2026-09-15-plain-udp-is-dormant-behind-a-build-tag.md).
- [0013 — room-code auth and the game-version check](../agent_docs/adr/0013-2026-08-14-add-room-code-auth-and-a-peer-game-version-check.md)
  and [0015 — the two review passes that hardened the relay](../agent_docs/adr/0015-2026-08-14-two-review-passes-across-the-go-layer-and-all.md):
  the first hardening, and why auth is a relay-side check rather than a client-side one.
- [0023 — the handshake is always tcp](../agent_docs/adr/0023-2026-08-16-revision-the-handshake-is-always-tcp-transport.md),
  [0021 — selectable transports](../agent_docs/adr/0021-2026-08-16-selectable-transport-tcp-udp-quic.md),
  [0022 — transport discovery](../agent_docs/adr/0022-2026-08-16-transport-discovery-transport-auto.md):
  why the room code crosses tcp whatever a session ends up on, and what that means for TLS.
- [0024 — the udp per-connection token](../agent_docs/adr/0024-2026-08-16-udp-per-connection-token-the-second-half-of-the.md):
  the two-part udp admission design (cookie, then token), and what it does and does not defend.
- [0042 — every client gets its own outbound queue](../agent_docs/adr/0042-2026-08-28-every-client-gets-its-own-outbound-queue-and-writer.md)
  and [0020 — the transport loses no message before the read loop starts](../agent_docs/adr/0020-2026-08-16-transport-ndjsonconn-loses-no-message-before.md):
  how one stalled peer is kept from freezing a room, and the framing layer's guarantees.
- [0030 — rooms are keyed by game and name](../agent_docs/adr/0030-2026-08-17-rooms-are-keyed-by-game-id-and-name-so-a-server.md):
  why two games cannot collide on a room name, and the first-joiner rule that fixes a room's
  version and features (the room-squatting gap in `security.md` follows from it).
- [0028 — the planes past cosmetic](../agent_docs/adr/0028-2026-08-17-the-planes-past-cosmetic-event-routing-sequencer.md)
  and [0031 — world custody](../agent_docs/adr/0031-2026-08-17-world-custody-the-relay-holds-the-world-and-four.md):
  the opt-in features no shipped game uses yet, which is where the relay first started retaining
  one client's bytes for another. Relevant only if a host enables a game that negotiates them.
- [0006 — the relay ran unauthenticated through the early phases](../agent_docs/adr/0006-2026-08-11-relay-runs-unauthenticated-through-phases-3-4.md):
  the starting posture everything above was added to, for context.

The rest of the folder is rendering, adapter and workflow decisions, and can be skipped for a
security review.

## Reporting a finding

Open an issue, with the input that triggers it if you have one. A confirmed finding gets a fix with
a test that fails without it and a dated entry in one of `security.md`'s "What changed" sections. Game-side changes are
verified by the maintainer on screen; Go-side changes with the commands above.
