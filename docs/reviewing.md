# Reviewing this yourself

<!-- line-cap: none -- written for people, not for an agent's instruction budget. Why: agent_docs/claude-md-cap.md. -->

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
   does with each field is its own review; the adapter reviews in `agent_docs/adr/` carry
   per-field tables.

**Dependencies.** One: `github.com/quic-go/quic-go`, plus its `golang.org/x` transitive set. TLS,
HMAC, JSON and the UDP socket are the Go standard library. There is no dependency for the wire
format, the framing or the relay logic, so there is nothing to audit but this repository and Go.

## What the project claims

[security.md](security.md) is the list of claims — what a hostile client can and cannot do to a
host, what each transport does and does not protect, every limit and where it is enforced, and a
known-gaps section that says what is deliberately not defended. Each claim there names the file
and, where one exists, the test that pins it. Treat it as a list of things to disprove: a written
claim that turns out false is worth more to you than a vague codebase, because it tells you at once
how much to trust the rest. Each section there carries the date it was last checked against the
code; the older the date, the more of the check is yours to redo.

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

**The race detector** (CI runs it on every push; it has found real relay bugs local runs missed):

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

## Reading the tests

A regression test here is kept only after it has been seen failing without its fix (a rule in
`CLAUDE.md`), and each test's comment says what it failed on and when. A test still only proves
the author's model of the input, so the useful question when reading one is what it never sends:
a size it truncates, a case it skips, a value it canonicalises first. Each of those is a class of
input the suite has not tried.

**Past reviews.** `agent_docs/adr/` holds every review and hardening pass as a dated record of what
was found, what was fixed, and what was deliberately left alone. Reading the most recent one first
shows where the last reviewer looked, and therefore where the next one should look instead.

## Reporting a finding

Open an issue, with the input that triggers it if you have one. A confirmed finding gets a fix with
a test that fails without it and a dated line in `security.md`'s changelog. Game-side changes are
verified by the maintainer on screen; Go-side changes with the commands above.
