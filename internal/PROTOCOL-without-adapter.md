# Using the relay and client from your own game (no adapter)

Every other integration document here assumes you are writing an **adapter**: a mod that reads a
game's memory from the outside and talks to a separate `meshghost.exe` over a loopback socket. That
is the right shape when you do not own the game.

This file is for the other case — **you own your game's source**, and you want the networking
compiled into it rather than shipped beside it as a second process.

> **This is unsupported, and that is not a formality.** We test the relay, the client, and our own
> adapters. We do not test anything else, we will not debug your integration, and nothing here is
> promised to keep working. The licence (MIT, see [`LICENSE`](../LICENSE)) lets you do all of this
> freely; it also disclaims all warranty, and this document is written in that spirit. If it breaks,
> it is yours to fix.
>
> What you *can* rely on is that none of it is secret: the relay is game-agnostic by construction,
> the wire format is documented, and the source is right here.

**What this file is not.** [`internal/README.md`](README.md) is the **security and privacy posture**
— every "is this safe" question belongs there. [`internal/documentation.md`](documentation.md) is
**how the Go networking layer works internally**, for someone about to change it.
[`agent_docs/contract.md`](../agent_docs/contract.md) is the **wire spec** — the packet schema, the
message types, the limits. This file assumes you have contract.md open and covers only the things it
does not tell you, plus the decisions you have to make first.

---

## Pick your route

Your real question is how much work you are signing up for.

| Route | What it means | Choose it when |
|---|---|---|
| **Ship our client alongside** | Run `meshghost.exe` as a child process and speak the loopback bridge to it ([`adapters/_template/PROTOCOL.md`](../adapters/_template/PROTOCOL.md)). Zero protocol work — it is a small JSON-per-line conversation. | You can live with a second process. This is by far the least work, and it is a real option even with full source. |
| **Reimplement the client** | Speak the relay protocol directly, from inside your game, in your language. | **The main route**, and what the rest of this file is about. Most engines are not Go. |
| **Fork or vendor the Go code** | Copy the packages into your own tree. MIT permits it. | Your game is Go, or you want the relay itself in-process. See [Why you cannot `go get` this](#why-you-cannot-go-get-this). |

**The server side needs no work at all.** `meshghost-server.exe` (built from `cmd/meshghost-relay`)
is game-agnostic by construction — it forwards opaque bytes and never learns what a position means.
Run the shipped binary unmodified and point your clients at it. Fork it only if you specifically
want the relay embedded in something.

---

## Which transport

Three are served: **tcp**, **quic**, and a bespoke reliable **udp**. Pick one — you do not need to
implement more than one.

**Use QUIC.** It is the one this project defaults to, and the reason is not novelty: a QUIC
connection carries a *reliable, ordered stream* **and** *unreliable datagrams* at the same time,
which is exactly the shape this protocol wants. Lifecycle messages (join, leave, who holds what)
must arrive in order; position updates must not — a position that arrives late is worse than one
that never arrives, because the next one is already better. TCP can only give you the first kind, so
a lost position sample stalls everything queued behind it until it is retransmitted. QUIC also
brings TLS 1.3 with it, so the session is encrypted without you doing anything.

**The one thing that decides whether this is easy: does your language have a usable QUIC library?**
Check that before anything else. QUIC is not something you implement yourself — you take a library,
the way you would take a TLS library. If your runtime does not have one you can ship, fall back to
**tcp**: it is a few hundred lines, it always works, and the relay always serves it.

**udp: don't.** See [below](#udp-really-dont).

### You do not have to handshake over TCP first

Our own client always makes a throwaway TCP connection first, asks the relay what it serves, and
then reconnects on the best answer. **That is a client-side convenience, not a relay requirement.**
Every transport gets its own listener feeding the same server, and the relay never learns which one
a connection arrived on.

So if you configure your own address and port — which you almost certainly do, since your users have
to type one anyway — **connect straight over QUIC and send `hello`.** You never need a TCP
implementation at all.

The discovery step is available if you want it: send a `hello` with `"query_only": true` and you get
back a list of offers instead of joining. Real exchange, captured from a running relay:

```text
>> {"type":"hello","payload":{"protocol_version":1,"game_id":"mygame","room":"lobby","display_name":"x","query_only":true}}
<< {"type":"transports","payload":{"offers":[{"kind":"tcp","port":7851},{"kind":"quic","port":7851}]}}
```

The relay closes the connection immediately after. Note offers carry **only a port** — the host is
whatever you already connected to, deliberately, so this works through NAT.

---

## The QUIC rules you must match exactly

None of this is in the wire spec, because until now nothing outside this repo needed it. All of it
is in [`internal/netx/quicconn/quicconn.go`](netx/quicconn/quicconn.go); get any of it wrong and you
either fail to connect or corrupt framing under load.

- **ALPN must be `meshghost`.** Mismatch fails the handshake outright — which is the intended
  outcome when something else is listening on that port.
- **TLS 1.3 minimum**, and **do not verify the certificate.** The relay generates a self-signed
  Ed25519 certificate in memory, once per process, and never writes it anywhere. There is no CA and
  no hostname to check, because the address is a bare IP a friend sent you. Be clear-eyed about what
  that buys: encryption against someone watching the network, **not** proof of who is on the other
  end. See [`internal/README.md`](README.md).
- **Enable datagrams** (RFC 9221). Without them you lose the unreliable half and QUIC buys you
  little over TCP here.
- **One client-opened bidirectional stream.** Exactly one. The relay accepts a single stream per
  connection.
- **Split the stream into whole lines before interleaving datagrams.** This is the one that will
  silently bite you. Stream bytes and datagrams both carry NDJSON lines, and they are merged into
  one logical inbound sequence. If a datagram is spliced in while the stream has delivered only half
  a line, you produce something no parser can recover — and it only happens under load, so it will
  pass every test you write by hand. Buffer the stream to line boundaries; a datagram is already
  exactly one complete line.
- **Do not close instantly after your last write.** A QUIC connection torn down immediately after
  writing can discard what you just sent. Our implementation closes the stream and then waits ~250ms
  before closing the connection. If you skip this, your goodbye `leave` may never arrive — and see
  the `leave` note below for why that matters.

---

## A minimal client, end to end

Every line below is a real capture from a running relay, not an illustration. Two clients in one
room: **alice** connects first, **bob** joins, moves, and quits.

The framing is the same on every transport: **one JSON object per line, newline-terminated, UTF-8**.
Lines are capped at 4096 bytes by the relay.

**What bob sends and receives:**

```text
>> {"type":"hello","payload":{"protocol_version":1,"game_id":"mygame","room":"lobby","display_name":"bob"}}
<< {"type":"welcome","payload":{"player_id":"p3","roster":["p2"],"send_hz":20,"server_time_ms":1786980386656}}
>> {"type":"state","payload":{"area_id":"level1","position":[12.5,0,-3.25],"anim":"run"}}
>> {"type":"leave","payload":{}}
```

**What alice sees while that happens:**

```text
<< {"type":"welcome","payload":{"player_id":"p2","roster":[],"send_hz":20,"server_time_ms":1786980385270}}
<< {"type":"join","payload":{"player_id":"p3"}}
<< {"type":"state","payload":{"player_id":"p3","seq":0,"timestamp":0,"area_id":"level1","position":[12.5,0,-3.25],"anim":"run"}}
<< {"type":"leave","payload":{"player_id":"p3"}}
```

That is the whole cosmetic protocol. Notes on it, in the order they will trip you:

- **The `hello` above is the complete minimum.** Everything else is optional. Send no `features` at
  all and none of the event/lease/escrow/world machinery ever runs for your room — which is what you
  want until you deliberately need it.
- **`player_id` is assigned by the relay**, formatted `p<N>`, and never reused. Your `welcome`'s
  `roster` is everyone who was already there — it does not include you.
- **The relay stamps `player_id` on your state and nothing else.** Look at what alice received:
  `seq` and `timestamp` came back as `0`, because bob never set them. **`timestamp` is yours to fill
  in, in wall-clock milliseconds**, and the receiving client interpolates against it — leave it at
  zero and every ghost you send will render wrong on the other side, with nothing reporting an
  error.
- **Send `leave` before you disconnect.** It is documented as relay→client, but it travels both ways:
  client→relay it means "I am quitting on purpose, do not hold my session". Skip it and — for a room
  using session resumption — everyone else stares at a frozen ghost of you until the grace window
  expires. `player_id` is ignored in that direction; the relay knows whose connection it is.
- **Keep the connection busy or it will be closed.** The relay drops an idle connection after 60s.
  Send a `ping` every 20s or so if you might go quiet; you get a `pong` back.

### When it goes wrong

A refusal arrives as one line, then the relay hangs up:

```text
>> {"type":"hello","payload":{"protocol_version":2,"game_id":"mygame","room":"lobby","display_name":"x"}}
<< {"type":"reject","payload":{"reason":"protocol version mismatch"}}
```

`reason` is plain text, not a coded enum, so match it defensively. The full set:
`protocol version mismatch`, `hello field too long`, `invalid room code`,
`game version mismatch for this room`, `feature set mismatch for this room`,
`game not allowed on this relay`, `server full`, `rate limited`, and `game mismatch for this room`
(kept for wire compatibility; a current relay no longer sends it).

**Only two are worth retrying**: `server full` resolves when somebody leaves, and `rate limited`
resolves on reconnect. Treat every other reason as permanent — retrying a version mismatch just
hammers the relay forever.

And a great deal is **not** answered at all, which is deliberate and will look like your bug:

| What you did | What happens |
|---|---|
| Sent malformed JSON | Silently dropped. No error, no close. |
| Sent anything before `hello` | Silently ignored. |
| Sent a line over 4096 bytes | Connection closed with **no `reject`** — a bare hangup. |
| Sent a `state` that fails validation | Silently dropped. |
| Used a message type the room did not negotiate | Silently dropped. |
| Sent an unknown message type | Ignored, by design — that is how new features ship without breaking you. |
| Took longer than 10s to send `hello` | Connection closed. |

One more that catches people who batch: the rate limit is a **tumbling one-second window** counting
*every* inbound line, including your `hello` and your `ping`s. The cap is
`max(120, send_hz * 6)`. Exceed it and you get `rate limited` and a close — mid-session, not at the
handshake.

---

## udp: really, don't

The third transport is a **reliability layer this project invented**. There is no RFC and no
interoperable target: a cookie-based address-validation handshake, an 8-byte per-connection session
token that every datagram must carry, big-endian per-message sequence numbers, individual acks, a
fixed 250ms retransmit with no congestion control, and a 64-deep reorder buffer. The wire format is:

```text
0xFF 0x01                        client hello
0xFF 0x02 <cookie16>             server cookie   (address challenge)
0xFF 0x03 <cookie16>             client confirm  (echoes it back)
0xFF 0x06 <token8>               server ready    (issues the token)
0xFF 0x07 <token8> <line>        unreliable payload    — 10 bytes of framing
0xFF 0x04 <token8> <seq8> <line> reliable payload      — 18 bytes of framing
0xFF 0x05 <token8> <seq8>        ack
```

Datagrams are capped at 1200 bytes total, so a reliable payload gets 1182 — **less than the 4096-byte
line limit the other transports allow**, and oversize is an error rather than a fragmentation.
Unframed datagrams are dropped, so you cannot skip the token.

You would be reimplementing a small transport protocol to get something QUIC already does better,
and **udp cannot be encrypted** — which is why our own client ranks it last and never picks it
unless it is the only thing on offer. If you still want it, the authoritative specification is the
package comment at the top of [`internal/netx/udpconn/udpconn.go`](netx/udpconn/udpconn.go). Read
that, not the surrounding inline comments.

---

## Why you cannot `go get` this

If your game is in Go, the obvious move is to import the packages. **You cannot**, for two
independent reasons, either one of which is enough on its own:

1. The module is declared as `module meshghost` — a local-only name that resolves to nothing. There
   is no host to fetch it from.
2. Every library package lives under `internal/`, and Go's toolchain refuses those imports from
   outside the owning module. `cmd/*` are all `package main`, which is not importable either.

This is deliberate, not an oversight: `internal/` is how a Go project says "I reserve the right to
reshape this freely", which is exactly the position this project wants to keep.

**So fork or vendor it.** MIT permits it outright, and it is the honest answer — you get a copy that
cannot be broken out from under you by an upstream change. If you would rather make it importable in
your fork, two mechanical changes do it, and neither alters behaviour: rename the module to a real
path, and move the packages you need out of `internal/`. Adapters are entirely unaffected either way
— they speak a socket, not a Go API.

---

## Compatibility, honestly

`protocol_version` is checked for **exact equality**. A mismatch is refused outright rather than
negotiated, so a bump would reject every existing client at once.

In practice it has stayed at `1` while six capabilities, four message types and a good number of
fields were added, because new capability travels through the `features` list plus two forward
compatibility rules: **unknown fields are ignored, and unknown message types are ignored.** Build
your client to honour both and additive changes will pass straight over it.

**That is our internal discipline, not a promise to you.** It has held so far and we intend to keep
it, but nothing here commits us to it, and there is no deprecation process for outside clients
because there is no way for us to know you exist. Pin a relay build you have tested if that matters
to you.

---

## Licensing

MeshGhost is MIT ([`LICENSE`](../LICENSE)) — commercial use, closed-source games, and modification
are all fine, provided the copyright notice travels with copies.

If you ship **our Go binaries or a build of this source**, you inherit the notices of what is
statically linked into them: quic-go (MIT), and `golang.org/x/crypto` and `golang.org/x/sys` (both
BSD-3-Clause). [`packaging/release/THIRD-PARTY-NOTICES.txt`](../packaging/release/THIRD-PARTY-NOTICES.txt)
is exactly that file, already written — copy its structure. Note `golang.org/x/net` appears in
`go.mod` but does not link, and is deliberately absent from the notices.

If you **reimplement the protocol** in your own language, you are shipping none of our code and
inherit none of this — you are implementing a format, which is not a thing MIT or anything else here
restricts.
