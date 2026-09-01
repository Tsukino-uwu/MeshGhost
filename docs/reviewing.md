# Reviewing this yourself

<!-- line-cap: none -- written for people, not for an agent's instruction budget. Why: agent_docs/claude-md-cap.md. -->

**Start here if you want to check this project before hosting a relay or playing with strangers,
and you do not want to take anyone's word for it.** That is the right instinct. **All of this code
was written by an AI agent** — the maintainer directs, tests on screen and decides, and has not
hand-written any of it, and that will stay true until someone else contributes without one. And
networking code is exactly where things work perfectly until someone sends the request nobody
expected. Nothing below asks you to trust the author, the agent,
or the tests. It tells you where to look, what the project claims, and how to run the adversarial
checks on your own machine so that what you believe is what you saw.

## What runs on which machine

Two different questions, two different surfaces:

| You want to... | What runs on your machine | The code a stranger can reach |
| --- | --- | --- |
| **Host a relay** | `meshghost-relay` (`meshghost-server.exe` in a release) | `relay/`, `transport/`, `netx/` (`udpconn`, `quicconn`, `tlsx`), `protocol/`, and `cmd/meshghost-relay/main.go` |
| **Play** | `meshghost` (the core) plus the game's adapter | `core/` on the relay side, then `bridge/` and the adapter on the game side |

The adapters never touch the internet. An adapter holds one localhost socket to its own core and
nothing else; it never learns a relay address (`agent_docs/contract.md`, hard rules). So a host
review is the first row, and it is a few thousand lines, not the whole repository. Do not take that
on faith either: Go compiles only what a binary imports, so follow the imports from
`cmd/meshghost-relay/main.go` and you have the exact code in the process you would run. And every
socket the tree opens is greppable:

```sh
grep -rnE 'net\.(Listen|Dial|ListenPacket|ListenUDP)|quic\.(Listen|Dial)' --include=*.go . | grep -v _test.go
```

## Where the bytes go

A review of network code is mostly following attacker-controlled bytes from the socket to every
place they are used, and asking at each step what has been checked so far. This is that path, so
you can start reading at the right line instead of the top of the file.

**Into the relay** (what a host exposes):

1. `cmd/meshghost-relay/main.go` binds one listener per configured transport through
   `netx.ListenWithTLS`. Every listener is wrapped in `netx.LimitListener` (a cap on open
   connections) and, for tcp with TLS on, `netx/tlsx` (the TLS-or-plaintext sniff). udp and quic
   are `netx/udpconn` and `netx/quicconn`, each presenting a datagram socket as a `net.Listener`.
   udp's admission cookie and per-connection token live in `netx/udpconn/cookies.go` and
   `listener.go`; that is the code that decides whether a spoofed packet costs the relay anything.
2. `relay.Server.Serve` accepts and starts `handleConn` (`relay/relay.go`). That function is the
   whole per-connection state machine and is worth reading end to end: it wraps the socket in
   `transport.NDJSONConn` with `protocol.MaxLineBytes` as the line cap (enforced *during* the read,
   in `transport/transport.go`'s `readLoop`), arms the hello timer, and registers `OnReceive`.
3. `OnReceive` runs, in order: the per-second flood cap; JSON decode of the envelope; if not yet
   joined, only a `hello` is accepted, and its checks run field-length → protocol version → room
   code (constant-time) → query-only → single-game restriction → room join/create → resume →
   slot reservation. Everything before the room is touched is where a stranger with no code
   lives.
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
   does with each field is the part reviewed last (ADR 0044's peer-to-adapter section).

**Dependencies.** One: `github.com/quic-go/quic-go`, plus its `golang.org/x` transitive set. TLS,
HMAC, JSON and the UDP socket are the Go standard library. There is no dependency for the wire
format, the framing or the relay logic, so there is nothing to audit but this repository and Go.

## What the project claims

[security.md](security.md) is the list of claims — what a hostile client can and cannot do to a
host, what each transport does and does not protect, every limit and where it is enforced, and a
known-gaps section that says what is deliberately not defended. Each claim there names the file
and, where one exists, the test that pins it. Treat it as a list of things to disprove: a written
claim that turns out false is worth more to you than a vague codebase, because it tells you at once
how much to trust the rest. The claims were last checked against the code, line by line, on
2026-09-02, and the date is on the section.

[networking.md](networking.md) explains the transports and the limits from the operator's side.
[agent_docs/contract.md](../agent_docs/contract.md) is the wire protocol itself, and its Limits
section is the authoritative list of every bound with its constant name.

## Run the adversarial checks yourself

You need Go (the version in `go.mod`) and a clone. Nothing else. Nothing here needs a game.

**The whole suite, twice, including the end-to-end test that launches the real binaries and drives
a real adapter over the bridge:**

```sh
go build ./... && go vet ./... && go test -count=2 ./...
```

**The race detector**, which is what caught the most recent relay bug before anyone did:

```sh
go test -race -count=3 ./...
```

**The fuzzers.** These feed inputs nobody chose into the parsers and the listeners, and they are
the part that does not share the author's blind spots. Run any of them for as long as your
suspicion lasts; CI runs a short campaign against every one on each push. Nothing here needs
trusting CI — the targets are ordinary `go test -fuzz` functions:

```sh
# the relay, fed arbitrary lines before and after a join
go test -run='^$' -fuzz='^FuzzRelaySurvivesArbitraryLines$' -fuzztime=5m ./relay
go test -run='^$' -fuzz='^FuzzRelaySurvivesArbitraryPostJoinMessages$' -fuzztime=5m ./relay
# the UDP listener, fed arbitrary datagrams (up to 60000 bytes -- see below for why that number matters)
go test -run='^$' -fuzz='^FuzzListenerSurvivesArbitraryDatagrams$' -fuzztime=5m ./netx/udpconn
# every wire decoder
go test -run='^$' -fuzz='^FuzzEnvelopeUnmarshalNeverPanics$' -fuzztime=2m ./protocol
go test -run='^$' -fuzz='^FuzzEnvelopeUnmarshalNeverPanics$' -fuzztime=2m ./bridge
```

The full list is `grep -rn '^func Fuzz' --include=*_test.go .` — fourteen targets across five
packages at the time of writing, and CI counts them the same way rather than trusting a list.

**Drive a relay by hand.** The tcp transport is newline-delimited JSON and, unless the host set
`"tls": "required"`, plaintext on the same port, so `nc host 7777` and typing is a valid attack.
The protocol is in `agent_docs/contract.md`; the reject reasons you will get back are in
`protocol/protocol.go`.

## Read the tests with the right question

Every regression test in this repository was watched failing before its fix was kept — that is a
rule (`CLAUDE.md`), and the tests' own comments say what they failed on and when. But a test
written by the author proves the author's model of the input, and the honest question for a
reviewer is not "does this test pass" but **"what does this test never send?"** That question is
how the 2026-09-02 review found that the UDP fuzzer had been truncating its own inputs to the very
limit whose overflow crashed the relay. `agent_docs/adr/0044-*.md` is that review in full: what was
found, what was fixed, what was left alone and why. It is the most useful thing to read after this
page, because it shows you what the last set of hostile eyes found and therefore what the next set
should look past.

## If you find something

Open an issue, or say so wherever you found the project. A confirmed finding gets a fix with a
test that fails without it, a line in `security.md`'s changelog with the date, and your name on it
if you want it there. The maintainer verifies every game-side change by watching it on screen and
the Go side with the commands above; a report that includes the input that triggers it is one that
can be turned into a regression test the same day.
