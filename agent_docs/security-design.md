# Security design — the unscheduled work behind `docs/security.md`

**What this is.** The design notes, audits and open questions for making MeshGhost safe to play with
strangers: transport security, the three layers of "safe with random people", the peer-data safety
requirements every adapter owes, the ACE audit of where peer-controlled data reaches a sink, structural
validation of `extras` and `orientation`, the game-blind question, bridge authentication, the
`only_game` default, and code signing. **Nothing here is scheduled.** `docs/security.md` is the shipped
posture and what is already true; this is the thinking that has not shipped. Moved out of `ideas.md`
on 2026-09-02 so a reader of `docs/security.md` can find it — it had been invisible there, ~1,075
lines inside a brainstorm file.

**Reference projects named here have not had their licences checked** (`ideas.md`'s rule applies —
this file is exempt from `licensing.md`'s gate until something from a project is USED).

## Index

- Relay/client — transport security (TLS) — **CONFIDENTIALITY HALF DONE 2026-08-19**
- What "safe to play with random people" means — the three layers, and where each one has to live
- PEER-DATA SAFETY REQUIREMENTS for every adapter — the user wants these enforced, not advised
- The ACE audit: where peer-controlled data actually reaches a dangerous sink (2026-08-27)
- Structural validation of `extras` AND `orientation` — bounding SHAPE without ever reading MEANING (BUILT 2026-09-03)
- Should the Go side stay game-blind? — and the middle path the rule already permits
- The bridge is unauthenticated and loopback only by DEFAULT, not by enforcement
- A blank `only_game` should mean "this project's games", not "anything" — layer 3's open-relay default
- Code signing the Windows binaries (SignPath OSS)

---

## Relay/client — transport security (TLS) — **CONFIDENTIALITY HALF DONE 2026-08-19**

**What shipped**: `off`/`auto`/`required` on both binaries, an in-memory self-signed certificate,
one port serving both TLS and plaintext (a one-byte sniff), optional fingerprint pinning, and no
silent downgrade. The load-bearing test puts a recording proxy between client and relay and
asserts the room code is **absent** from the captured bytes, with a negative control in the same
test proving the tap is watching. ADR in `architecture.md`.

**What is still open, and it is the more interesting half**: this encrypts, it does not
authenticate. Pinning is opt-in and has to be re-copied after a relay restart. The design below
for **channel binding** (`tls-exporter`, RFC 9266) — proving knowledge of the room code without
putting it on the wire at all — is the eventual answer and was deliberately left out, because it
is a protocol change with a downgrade-hole of its own. The two smaller items (open-relay default,
per-IP cap) are also still open, and TLS makes the second one more pressing: a handshake is CPU an
unauthenticated stranger can ask for.

### Original entry

Not an adapter item and not on the depth ladder at all: this is the Go side, so it's
confirmable with the tools rather than by watching a game (`CLAUDE.md`'s split). Researched
2026-08-16 to the point of a full implementation plan; **deliberately not scheduled** — nothing
is broken today, and one of the costs below argues for waiting.

> **Largely overtaken later the same day (2026-08-16) by selectable transports and the quic
> default.** `quic`'s handshake is TLS 1.3, and the shipped pair is `auto` on the client against
> `tcp,quic` on the relay, so a default session is already encrypted and the room code no longer
> crosses the wire in the clear. **What this section still describes accurately is the
> authentication half**: quic's certificate is unverified, so it stops a passive eavesdropper and
> not an active man-in-the-middle — and the channel-binding design in point 3 below is exactly
> what would close that, since `tls.ConnectionState.ExportKeyingMaterial` is confirmed working on
> the quic path. TLS-over-`tcp` remains unbuilt, and `tcp`/`udp` are still plaintext when named
> explicitly. Read the "what's actually missing" and "why it's worth doing" paragraphs below as
> written before that change. Mirrors `risks.md`'s TLS entry.

### What's actually missing

Only confidentiality. The application layer is already hardened: server-stamped `player_id`
(`relay/relay.go:825`, never trusted from the payload), constant-time room-code compare
(`:653-660`), hello timeout, per-connection flood cap, global client cap, `ValidateState` that
drops rather than truncates, and a fuzz harness driving the relay over `net.Pipe`. What's left is
that `transport` is plaintext NDJSON over TCP, so `room_code` crosses the wire readable
— already recorded at `risks.md:111`, `contract.md:195`, and the room-code ADR's own "a separate,
larger piece of work" note at `architecture.md:494`. (True of `tcp`; see the note at the top of
this section for what the quic default changed.)

**Adapters are not affected by any of this, at all.** An adapter speaks only the *bridge*
protocol to a local core on `127.0.0.1:7778` — a different socket from the relay one. The bridge
stays plaintext loopback. Nothing in `adapters/` changes, now or later.

### The shape it would take

1. **Three-way mode**, `off` / `auto` / `required`, one config key and one flag on each binary.
   `auto` sniffs the first byte of each accepted connection — `0x16` is a TLS ClientHello, `{` is
   NDJSON — so one port serves both and hand-driving a relay with netcat still works. Releases
   would ship `required` on both sides.
2. **No files anywhere.** The relay generates an in-memory Ed25519 self-signed certificate once
   per process. Nothing ever verifies it by fingerprint, so a file on disk would buy zero
   security while putting a private key next to the exe in a zip people re-share.
3. **Identity via TLS channel binding** (`tls-exporter`, RFC 9266), not certificates or pinned
   fingerprints — because the end user configures nothing. After the handshake both ends derive
   the same connection-unique secret via `tls.ConnectionState.ExportKeyingMaterial`; the client
   sends `HMAC-SHA256(room_code, ekm)` in place of the raw code, the relay computes the same and
   compares constant-time, and mirrors its own proof back in `Welcome` under a second label.
   Someone terminating TLS in the middle sees *different* keying material on each leg, so they
   can't forge or forward a valid proof. Net: the room code stops crossing the wire at all,
   interception is blocked, and nobody copies a hex string.
4. Structurally small. `relay.Serve` takes any `net.Listener` and `handleConn` any `net.Conn`
   (proven by the `net.Pipe` fuzz harness), so framing, relay logic and core need no change —
   the work is a new `tlsx` leaf package, two optional `protocol` fields, and the two
   `cmd/` binaries. `protocol.Version` stays at 1 (additive optional fields, same precedent as
   the room-code ADR). Full plan, including the compatibility matrix and the test list, was
   written 2026-08-16 and would need re-deriving — the design above is the durable part.

### Why it's worth doing

Anyone on the network path — shared wifi, a VPN provider, an ISP — currently reads the room code
out of the third packet. This makes that impossible, and makes relay impersonation impossible
too. It would also be the **first security setting a stale binary cannot silently disable**: a
`required` client refuses to send anything to a plaintext relay, which is exactly what
room-code auth could not do (`risks.md:101-110`).

### Costs, honestly

- **Antivirus, and this one is ours specifically.** The exes already draw false-positive trojan
  flags. Certificate generation plus encrypted outbound traffic hits two classic heuristic
  triggers, so this could plausibly make that worse. **This is the reason to sequence it after
  the SignPath OSS code-signing work, not before** — it's the only cost here that would actually
  reach users.
- **Reading a real session off the wire stops working.** netcat-driving survives under `auto`,
  but a packet capture between two real binaries goes opaque — the property
  `docs/security.md`'s "Why TCP is the mandatory handshake leg" section argues for. `tls: off` is the way back.
- **~10-15% more traffic.** Roughly 25 bytes of TLS record overhead per message; at 20 Hz that's
  about 1.8 MB/hour per direction against 150-250 byte packets. Post-handshake CPU is
  immeasurable — AES-GCM moves gigabytes per second and this sends four kilobytes.
- **A new way for a version mismatch to break a release.** Today a stale binary silently
  downgrades; after this a `required` client hard-fails. That's the intent, but it's still a new
  support case where mixed versions error instead of limping along.
- **Bug risk in a path that currently works.** The room-code check splits into two branches, and
  getting the split wrong would create a downgrade hole where none exists. The plan's answer is a
  test asserting that a TLS connection sending a *raw* room code is refused, not accepted.

### Was mTLS considered? Yes — it is the certificate route point 3 already rejected (asked 2026-08-24)

**Not worth building, and not because it is weak.** Mutual TLS authenticates the *client* to the
relay. That job is already done by the room code, and the room code's remaining weakness is not
that it is a weak secret — it is that it **crosses the wire**, so it is replayable by anyone who
can read it (plain `udp` always; `quic` or unpinned `tcp` against an active man-in-the-middle).
Channel binding fixes exactly that weakness with no new artefact for the player to hold. mTLS
fixes it by replacing the shared secret with a per-player keypair, which costs a great deal more.

**What mTLS would genuinely add over channel binding — three things, all real:**

- **Per-player revocation.** Today the only way to remove one player is to change the room code,
  which evicts everyone. A client certificate can be dropped individually.
- **Rejection before the relay allocates anything.** An unauthorised client fails in the TLS
  handshake, before `handleConn`, before the hello timeout holds a goroutine and a socket — which
  is the per-IP-cap concern in the section below, answered at a different layer.
- **A durable identity a room code cannot express**, which is the shape any future
  reputation/ban-list or non-cosmetic authority plane would want (`beyond-cosmetic.md`).

**Why it still loses, for what this project actually ships:**

- **It breaks the distribution model.** A room code is a string you paste into a chat window. A
  client certificate is a *file per player*, issued by the host, that has to reach each of them
  and be kept. `packaging/release/README.txt`'s host-for-friends flow does not survive that, and
  point 2 above already refused to put a private key next to the exe in a zip people re-share.
- **The host becomes a CA.** Issuing, storing, expiring and revoking certificates is persistent
  state the relay has never had — today's certificate is in-memory and regenerated every restart
  (which is already why a pinned fingerprint has to be re-copied, `docs/security.md`). mTLS
  cannot be in-memory: the CA has to outlive the process, so this adds key material on disk, a
  lifetime policy, and a recovery story for losing it.
- **It fixes the leg that is already fine and misses the two that are not.** The unauthenticated
  legs are `udp` (no DTLS in Go at all, so mTLS cannot reach it) and `quic`'s *server*
  certificate, which is unverified — an active man-in-the-middle presenting their own cert is
  accepted. **That is a server-authentication hole; mTLS is client authentication and does not
  close it.** Extending the fingerprint pin to the quic path closes it, and channel binding
  closes it without anyone comparing a hex string.

**So the order that actually buys security here**, cheapest and highest-value first: (1) extend
the `tls_fingerprint` pin to the quic path, so the pin stops covering only the tcp leg; (2) the
channel binding in point 3, which retires the room-code-on-the-wire problem on both TLS
transports at once; (3) the per-IP cap below. mTLS sits behind all three.

**When to revisit:** if MeshGhost ever grows a **long-lived public relay** — one where the host
does not personally know every player, wants to ban one without evicting the rest, and is already
running persistent state — the distribution cost stops being the objection, because such a host
has an account system to hang certificates off anyway. Nothing on `plans.md` heads there today.
The same trigger applies to anything past Tier 2 that needs a peer's identity to *mean* something
rather than merely be distinct.

### Two smaller, cheaper items found alongside it

Both are independent of TLS and could land first.

- **The shipped relay default is an open relay.** `packaging/release/config.json` has
  `listen_on: "0.0.0.0:7777"` with `room_code: ""`. Keeping `0.0.0.0` is right — narrowing it
  breaks the host-for-friends flow `packaging/release/README.txt` already walks through — but the
  empty code deserves a louder warning than it currently gets. Auto-generating a random room code
  when none is set would close it properly, at the cost of the zero-config "just give them the
  address" flow; that's a product call, not a technical one.
- **No per-IP connection cap.** `MaxClients` (8, global) is reserved only *after* a successful
  Hello (`relay.go:753`), so N unauthenticated connections each hold a goroutine and a socket for
  `HelloTimeout`. TLS would make each one cost real handshake CPU an unauthenticated stranger can
  trigger, so a handshake timeout is part of the plan above. A real per-IP cap needs
  `conn.RemoteAddr()`, which `docs/security.md`'s privacy section asserts is never called anywhere
  as a privacy property — so it needs its own decision rather than being smuggled into a TLS
  change.

### Follow-up: let the relay advertise its transports — BUILT 2026-08-16, same day

**Done, and no longer an idea.** Filed here in the morning and implemented the same day as
`transport: "auto"` — see the transport discovery ADR in `architecture.md` and the entry in
`verified.md`.

Kept as a one-paragraph record because the *reasoning* is worth not re-deriving: auto-probing
cannot work (quic is on a different port and a client knows only one address), advertising in
`Welcome` would have meant joining first and then reconnecting — which every other player in the
room would see as a leave and rejoin, since `contract.md` guarantees no session resumption — so
the client asks *before* joining instead. The query answers only after the room-code check, which
is what stops it becoming the relay's one pre-auth endpoint.

### Prior art: how pseudoregalia-multiplayer splits reliable vs unreliable (checked 2026-08-16)

Checked when the user asked whether MeshGhost needs WebSocket, having noticed that project using
it for something beyond its Archipelago connection. Facts read from its own
`docs/application-protocol.md` (MIT, approved read-only reference in `licensing.md`); no code
read or copied.

It uses **both WebSocket and UDP**: "Communication between client and server consists of both
WebSocket messages and UDP packets." The author's stated reason is worth quoting, because it is
the same problem MeshGhost hit and a different answer to it — "I like using UDP for the state
updates, but I didn't want to write my own 'connection based, in order, guaranteed delivery'
protocol on top of UDP. I can get that from WebSockets relatively easily."

**Same split, different solution.** MeshGhost reached the identical conclusion — lossy for
per-frame state, reliable for lifecycle — and expressed it as `Send`/`SendUnreliable` over one
connection. Where they delegated the reliable half to a second protocol, we wrote the retransmit
/ack/dedup layer in `netx/udpconn` that they explicitly chose not to write. Their
reasoning is sound and the cost of ours was real: that layer is where the one genuine bug of the
day lived (acking before delivering, `verified.md` 2026-08-16), which delegating would have
avoided.

**Why we still don't want WebSocket.** QUIC is the better version of what they use it for: the
same reliable-plus-unreliable split, but one connection rather than two, one path through NAT,
standardised, and encrypted — WebSocket being an HTTP-derived framing layer whose reason for
existing (browsers cannot open raw sockets) does not apply to a native client. The one case that
would change this is hosting: some PaaS providers and restrictive networks route only HTTP(S), so
a relay behind such a proxy is reachable over WSS on 443 and nothing else. If that ever comes up,
`netx` makes it a fourth `Kind` with no change to `relay` or `core`.

## What "safe to play with random people" means — the three layers, and where each one has to live

**Unscheduled umbrella entry. Read this before the two entries below it; they are layers 1 and 3.**
**Layer 3 gained a concrete proposal on 2026-08-27** — *"A blank `only_game` should mean 'this
project's games', not 'anything'"*, further down this file, which is the open-relay-default row of
the table below.
Written 2026-08-24 at the end of a measured security pass, so a future session starts from a
definition instead of an open-ended audit. **Nothing here is queued** — the user's call the same
day was to brainstorm and plan before building anything.

**The finding that makes this tractable: the client-to-client surface is finite and small.** The
relay never passes bytes through — it re-encodes every forwarded message from the parsed,
validated struct — so the only thing that reaches another player is a struct the relay itself
wrote. That reduces "what can a hostile peer do to me" to "what are the fields that struct
carries", which is a list, not a search. See the enumerated table in the bridge entry below.

**Three layers, each closing something the other two structurally cannot:**

| Layer | Closes | Where it MUST live | Cost |
|---|---|---|---|
| 1. Shape caps on `extras` + `orientation` | structure (nesting, key count, value types) | **core** — game-agnostic, so it can be done once for every adapter that will ever exist, third-party included | one contract narrowing + ADR |
| 2. Range checks on peer-derived numbers | meaning (`act = 4294967295`, `sprite = 200` where 40 exist) | **adapter** — the only component permitted to know what those mean | small: Crystal has 4 extras fields, Pseudoregalia 26 and already clamps the dangerous ones |
| 3. Deployment: bridge bind, per-IP pre-auth cap, open-relay default | exposure and resource abuse | **`cmd/`** — not client-to-client at all | each independent and small |

> **Before building layer 1 or layer 2, read "Should the Go side stay game-blind?" below.** It
> describes a third option — adapter-declared constraints the core enforces without interpreting —
> that would change WHERE layers 1 and 2 live and could merge them. Deciding that first is cheaper
> than building layer 2 per adapter and then discovering it belonged in one negotiated place.
>
> **The user endorsed that third option on 2026-08-27, for EVERY adapter, and the same entry now
> carries a correction: enforce on RECEIVE against the LOCAL adapter's bounds, not room-negotiated
> ones.** Layer 2 as tabled below — range checks written per adapter, by hand, per game — is the
> thing that changes shape if this is built, so read it before starting layer 2 rather than after.

**Layer 1 cannot do layer 2's job, and that is the architecture working, not a shortfall.** The
core may never be game-aware (`CLAUDE.md`, ADR 08-20), so it can bound SHAPE but never MEANING.
The adapter is the only trust boundary for meaning. Pseudoregalia already models this correctly —
`clamp_to_uint8` (`Plugin.cpp:1573`) exists because `static_cast<uint8_t>(double)` on NaN or an
out-of-range value is *undefined behaviour*, and its comment states plainly that extras "reach
here unchecked". The two Lua adapters do not do this yet. **Back-port the rule to `_template/`
when layer 2 happens**, so the next adapter starts with it.

**`area_id` and `anim` are already finished and must not be "hardened" again** — bounded to 256
and UTF-8-validated by `ValidOpaqueString`. The core compares them by equality only, so there is
nothing further it could check without breaking the opacity rule.

### The honest residual — what stays true even with all three layers done

**A peer can still make their ghost look wrong or move oddly in your game.** They legitimately
control their own character's appearance; that is the feature, not a vulnerability. Do not chase
it as one.

**The line the three layers actually draw, and the thing to test against:** a peer cannot crash
you, cannot write outside their own ghost's fields, and cannot reach another player except
through a struct your own relay parsed, validated and re-serialized. That is a defensible
definition of safe for a cosmetic ghost layer — and unlike "no vulnerabilities", it is a claim
that can be checked.

**What is NOT in scope of any of the three, and needs its own decision:** relay authentication.
Nothing proves a relay is who it says it is — the `tls_fingerprint` pin is opt-in, covers the tcp
leg only, and must be re-copied after every relay restart. Joining a stranger's relay is a
different threat model from hosting for strangers, and only the channel-binding work above
addresses it. Do not let the three layers above create a false sense that this one is covered.

### How authoritative online games / MMOs handle this, and why most of it cannot transfer

**General architecture, not a claim about any specific title.** The rule everything follows from is
that clients send **inputs, not state**: the server accepts "I pressed forward this tick", simulates,
and emits its own state. Position is computed, never received. That single inversion removes whole
vulnerability classes by construction — speedhacks, teleports and duplication are not attacks the
server blocks, they are facts the client was never the source of. Layered on top: plausibility
checks even *with* authority (movement delta vs max speed), schema-first binary protocols
(unparseable fails at the codec, "extra fields" does not exist), interest management (you receive
only what you may see), and per-connection/per-account rate limits against a revocable identity.

**MeshGhost cannot adopt the main one, and that is an ADR rather than an oversight.** The core may
never be game-aware, so the relay can never simulate, so it can never be authoritative. This is
structurally a state-forwarding architecture — the model authoritative games explicitly reject.
**The question that resolves it is what there is to steal:** an MMO holds items, currency and
progression, where a successful attack is permanent and profitable. MeshGhost holds what a ghost
looks like this frame. **Cosmetic-only is itself the largest security decision this project has
made**, and it is what makes a forwarding architecture defensible here.

**What does transfer — two already present:**

- **Schema-first**, by a different route: a binary schema rejects unmodelled data at the codec;
  the relay re-encoding from a validated struct makes unmodelled fields evaporate the same way.
  Same guarantee, different mechanism.
- **Rate limiting**, partially: `send_hz`, the per-peer receive cap and the per-connection flood
  cap exist. The gap is *pre-auth*, which is the per-IP cap already listed above.
- **Plausibility checking — the one genuinely missing idea, and a NEW layer-2 candidate.**
  `ValidateState` checks that a position is finite and within `MaxPositionComponent`, but never
  that a peer moved a plausible distance *since their last update*. A peer teleporting thousands of
  tiles per frame passes every check that exists. **It cannot live in the core** — a plausible
  delta depends on the game's units and speeds — so it is layer 2, alongside the `extras` range
  checks, and belongs in the same per-adapter pass.

**The gap authority would have closed and nothing here does: an authenticated, revocable
identity.** A room code is shared and cannot be revoked per person. That is the same gap the mTLS
discussion circled and that channel binding only partly addresses — see the transport-security
entry.

### How worried to actually be — calibration, so this is neither panicked nor dismissed

**Player-to-player code execution essentially does not happen in authoritative online games, and
the reason is exactly the property the relay already has.** An attack of that kind needs the
victim's client to parse bytes the attacker controls; under server authority it never does,
because the bytes were written by the server. On the wire, MeshGhost is in the good category.

**When the exceptions do happen they cluster in three shapes**: peer-hosted / host-migration games
where the "server" is another player's machine; user-generated-content paths where clients parse
peer-supplied *content* the server forwards unexamined; and mod layers with hand-rolled parsers
running inside the game process. **MeshGhost sits in all three at once** — the relay is hosted by
whoever is hosting, `extras` is structurally a UGC channel (opaque by contract, forwarded
unexamined), and the final consumer is a hand-rolled recursive-descent parser inside BizHawk or
UE4SS. The Go side compensates well for the first shape. **Nothing currently compensates for the
third**, which is why the adapter-parser items keep recurring in this entry.

**Keep the severity honest — ACE is the LEAST likely outcome here, and this entry should not be
read as claiming otherwise.** Everything actually measured points at hangs and wedged game state,
not code execution: Lua is memory-safe, and peer values reach memory as VALUES written into
addresses derived from our own ghost slot. The one place undefined behaviour is genuinely
reachable — `static_cast<uint8_t>(double)` on a NaN or out-of-range peer value — **is already
defended** (`clamp_to_uint8`, `Plugin.cpp:1573`). The realistic worst case is a frozen emulator or
an absurd-looking ghost: a bug, not a breach.

**So the reason to do this work is COST, not fear.** Bounding two fields in `ValidateState`,
adding a `pos > #s` guard to two loops and range-checking three numbers in Crystal is a few hours
with tests, against a Go side that already carries 11 fuzz targets and validators shared by both
ends. It is cheap enough not to be worth carrying as an unknown — which is a better and more
durable reason than a threat estimate. **If a future pass finds one of these items has become
expensive or invasive, that is a reason to drop it, not to escalate it.**

### How Archipelago handles the same problem — read 2026-08-24, facts only

**Why it is worth comparing at all:** Archipelago is the one adjacent project MeshGhost already
has to coexist with (the emulator adapters are designed to run on top of an AP seed), it is
cleared MIT and read directly (`licensing.md`), and it solves the same client -> server -> client
shape. `MultiServer.py` read for facts; no code copied, and nothing below is a recommendation to
imitate it.

**The headline: Archipelago DOES forward client-controlled structure verbatim, deliberately.**
`Bounce` (`MultiServer.py:2149`) takes the client's own `args` dict, overwrites `cmd` with
`"Bounced"`, serializes that same dict and broadcasts it to matching clients — no schema on the
payload. `Set` (`:2176`) is a shared mutable key-value store any client can write, on which the
server applies a client-chosen operation, then broadcasts the result to every subscribed client.
Both are advertised features, with responsibility pushed to the receiving client. **MeshGhost's
re-encode-from-a-validated-struct is the more conservative choice, and this is the clearest
evidence that it is a choice rather than an accident.**

**But the comparison flatters MeshGhost on the axis AP actually cares about.** AP is a game-state
authority — it holds item and location state, so its real adversary is a client that *cheats*
(claiming a location it never checked). That threat class does not exist here, because cosmetic-only
is itself a security decision. Do not read "MeshGhost validates more" as "MeshGhost is more secure
than Archipelago"; they are defending different things.

| | Archipelago | MeshGhost |
|---|---|---|
| message size cap | no `max_size` passed to `websockets.serve` (`:2728`), so the library default (1MB) applies | 4096, deliberately chosen |
| compression on untrusted data | permessage-deflate enabled (`:2731`) | none |
| validation style | ad-hoc per command (`type(args["keys"]) != list`) | shared `Validate*` per type, used by relay AND core, 11 fuzz targets |
| forwarding | re-serializes the client's own dict | re-encodes from a validated struct |
| TLS | real certificates via `--cert` (`:2678`) | self-signed, bare IP, no CA possible |
| web surface | a Flask host — uploads, generation, accounts | **none at all** |

**The TLS row is the instructive one and explains a design decision here.** AP can use real
certificates because it is a *hosted service* on a public domain. MeshGhost is peer-hosted against
bare IPs, where there is no hostname to verify and no CA to verify it against — which is exactly
*why* the fingerprint pin exists rather than being a weaker substitute for something better.
Different deployment models, not one being lax.

**The one concrete thing worth taking:** AP's `Say` handler (`:2141`) requires
`type(args["text"]) is str` **and** `.isprintable()` before text reaches other players — it
rejects control characters, not just oversized ones. MeshGhost has no equivalent because nothing
peer-controlled is displayed yet. **Nameplates would change that**, which is why the requirement is
now written into the nameplates entry above rather than left to be rediscovered.

## PEER-DATA SAFETY REQUIREMENTS for every adapter — the user wants these enforced, not advised

**The user, 2026-08-27:** *"I want things like this to be strictly enforced/required for all
adapters. so that meshghost is actually safe to use, and feels safe to use"*, having drawn the line
*"i never want someone else to do anything malicious/harmful towards someone elses computer"* while
accepting that a peer making their own ghost look wrong is fine.

**Read the ACE audit below first** — it is the evidence. This entry is what turning that audit into
a standing requirement would take.

**STATUS: LOGGED, NOT DESIGNED, AND NOT A NICE-TO-HAVE.** The user's instruction, same day: *"just
log to ideas for now, how to handle it is an issue for another time. but it is something i feel
strongely about actually doing for this project and not being sloppy with"*. So **the WHAT below is
the user's stated intent for the project and the HOW is deliberately open** — the enforcement column
is one sketch, not a decision, and a future session should feel free to replace the mechanism while
keeping the requirement. Two things follow from how strongly it was put:

- **It does not expire by being unscheduled.** `ideas.md` holds unscheduled work, and the ordinary
  reading of an entry here is "act on it when picked". This one carries an explicit commitment, so
  it is not a candidate to quietly drop.
- **"Not being sloppy with" rules out the tempting version** — writing the requirements into
  `_template/` as prose, calling the adapter contract updated, and moving on. That is precisely the
  failure `internal/gameblind` was created to end, and this session found three more instances of it
  in one pass. A requirement without a check is not a smaller version of this idea; it is the thing
  this idea exists to avoid.

### Why this cannot be prose, stated once so it is not re-litigated

`internal/gameblind`'s own header already settled this argument for the game-blindness rule: *"Prose
is a statement of intent, not enforcement: nothing failed when it was crossed. These tests fail."*
Every requirement below therefore names **what breaks when it is violated** — and one that cannot
name that is a wish, not a requirement, and is marked as such.

**This session is itself the evidence.** Three doc gates were found reporting PASS while checking
nothing, a shipped flag had no register row, a register row described a deleted flag, and the first
regression test written for the relay-ownership race passed without the fix. Every one of those was
a rule that existed in prose. The ones that held were the ones with a check behind them.

### The requirements, and what would enforce each

| # | Requirement | Enforceable by | Confidence |
|---|---|---|---|
| **R1** | **No peer-controlled value reaches a code-execution primitive.** `load`/`loadstring`/`dofile`/`os.execute`/`io.popen`, `Activator`/`Type.GetType`, `dlopen`/`LoadLibrary`. | A grep gate: those primitives may appear only with a **literal** argument, or not at all. Same shape as the existing canonical-source and invented-durations gates. | **High** — mechanical, and the current tree already passes it (only `io.popen("cd")`). |
| **R2** | **No peer-controlled value reaches a file path.** No filename, directory or path component derived from `player_id`, `area_id`, `anim`, or any `extras` key. | A grep gate over file-opening calls (`io.open`, `File.*`, `ofstream`, `client.screenshot`) flagging any argument expression that mentions a known peer field name. | **High** — the peer field set is small and fixed by the contract, so the pattern list is closed. |
| **R3** | **Every peer field an adapter reads is REGISTERED with its bound**, and the register is complete. | A mandated per-adapter register plus a completeness check — **exactly the pattern that already works for `FLAGS.md`**, where 2026-08-27 found a shipped flag with no row AND a row for a deleted flag, in both directions. Diff "fields the source reads" against "fields the register declares". | **High** — proven pattern, and the one that makes R4-R7 auditable instead of vibes. |
| **R4** | **No peer value bounds a loop or sizes an allocation.** Counts are edge triggers (`target > last_seen`), never `for i < peerCount`. | Partly greppable; fully checkable against R3's register, which marks which fields are counts. | **Medium** — the grep catches the obvious form; the register catches the rest. |
| **R5** | **No peer string is used as a lookup NAME without an allowlist.** Not "is the result the right type" — that is the current state and it is weaker. | R3's register declares each string field's permitted value set; a grep flags known lookup calls (`StaticFindObject`, `anim.Play`, reflection by name) taking a peer field. | **Medium** — closes both gaps the audit found. |
| **R6** | **Every per-peer map is keyed by the relay-assigned `player_id`**, never a peer-chosen string. | Grep for indexing by `anim`/`area_id`; `player_id`'s key space is bounded by `MaxClients`. | **High** — currently true, and cheap to keep true. |
| **R7** | **Peer numerics are clamped before narrowing.** `static_cast<uint8_t>(double)` is UB for NaN — not merely wrapping. | Hard to grep in C++ generally. R3's register plus a review rule; Pseudoregalia's `clamp_to_uint8` is the reference implementation. | **Low as a gate**, high as a documented requirement. Say so rather than pretend. |

### Where these requirements have to live

**In the adapter contract, not a doc nobody opens.** The mandated file set, the bridge shape and the
`FLAGS.md` register are already per-adapter obligations that `preflight.ps1` checks; this is the
same kind of thing. Concretely: R3's register becomes a mandated file (or a section of an existing
one), `adapters/_template/` carries the stub and the rules, `/new-adapter` sequences it, and
`preflight.ps1` fails an adapter missing it — the same machinery, no new mechanism.

**The honest limit: this can only bind adapters in THIS repo.** A third-party adapter — which
`docs/integrating.md` actively invites — cannot be made to run our greps. For those, the only thing
that helps is enforcement on the RECEIVE side by the core, against constraints the adapter declared:
see "Should the Go side stay game-blind?" and its 2026-08-27 correction. **That is the difference
between "our adapters are careful" and "MeshGhost is safe", and it is why the receive-side design is
the strategic item rather than the greps.**

### "Feels safe" is a separate requirement, and it needs different work

The user asked for both: *"actually safe to use, and feels safe to use"*. The second does not follow
from the first, and it is not marketing — it is being able to **show** the property.

- **State what is STRUCTURAL versus what is AUDITED, and never blur them.** Three layers, in
  descending strength: the victim never parses attacker bytes (structural — the relay re-marshals
  from a validated struct); both ends validate, including against a hostile relay (structural);
  per-sink handling in the receiving adapter (**audited, per field set, re-earned on every new
  field**). A reader told only "we validate everything" has been given less than they need.
- **Never claim more than the layer supports.** "No ACE was found by tracing every peer field to its
  sink on 2026-08-27" is true and checkable. "ACE is impossible" is not, and one confident
  overstatement costs more trust than the whole audit buys.
- **Publish the threat model, including what is deliberately out of scope** — a peer making their
  own ghost look wrong, and the fact that a relay HOST necessarily sees player IPs while other
  players never do. `docs/security.md` already gets the IP half right; the peer-data half belongs
  beside it.
- **The checks are the artifact.** A user can read a grep gate in `preflight.ps1` and a CI workflow
  and verify the claim themselves. That is what makes a safety claim inspectable rather than
  asserted, and it is the same reason `internal/gameblind` is tests rather than a paragraph.

### If only one thing gets built

**R3, the per-adapter peer-field register with a completeness check.** It is the cheapest, it reuses
a pattern that already caught real drift in both directions this same day, and it converts R4, R5
and R7 from "someone reviewed it once" into something a machine re-checks on every push. R1 and R2
are worth adding at the same time because they are pure greps against a closed pattern list and the
tree already passes both.

## The ACE audit: where peer-controlled data actually reaches a dangerous sink (2026-08-27)

**The goal, in the user's words:** *"I just want it to be safe with random people, no ACE or
malicious data being sent back/forth between anyone if someone decides to be a bad actor"*, and
*"we should make sure to clamp/enforce what can be sent to the server, and into other games so that
nothing is ever malicious/bad"*.

**This entry is the evidence layers 1 and 2 above were missing.** Those describe where checks should
live; nobody had traced where hostile data can actually GO. Audited 2026-08-27 by following every
peer-controlled field to its sink. **The headline: no arbitrary code execution was found, and the
two real gaps are both "a peer can NAME a thing".**

### Already defended — do not re-audit these

| Surface | Why it holds |
|---|---|
| **Lua code execution** | No `load`/`loadstring`/`dofile` anywhere in either shipped adapter. The only `io.popen` in each is the literal string `"cd"` (`crystal:537`, `emerald:480`) — no peer data reaches a shell. |
| **Lua memory writes** | Lua table indexing is memory-safe (an out-of-range index yields `nil`, not a read), and BizHawk bounds its own memory domains. A hostile value corrupts the **emulated** game at worst — annoying, not host ACE. |
| **Crystal's peer sprite id** | Validated against the cartridge before use: `ENGINE.spriteSig(id)` must match and the peer's own `gfx` must agree, then `residentSpriteTile(id)` must resolve, or the ghost is dropped rather than drawn wrong. The id is written as a VALUE at a locally-computed offset, never as part of an address. |
| **Position** | The core rejects non-finite outright and bounds magnitude (`protocol.IsValidPosition`, `MaxPositionComponent`) — enforced at both ends, so no adapter has to. |
| **Byte passthrough** | The relay never forwards bytes; it re-encodes every message from the parsed, validated struct. What reaches a peer is a struct the relay itself wrote. |
| **Parsers** | 13 fuzz targets across 5 packages in CI (`protocol` 7, `bridge` 2, `relay` 2, `transport` 1, `netx/udpconn` 1). |
| **Pseudoregalia's narrowing UB** | `clamp_to_uint8` (15 call sites) exists because `static_cast<uint8_t>(double)` is **undefined behaviour** — not merely wrapping — for NaN or out-of-range input, and `move_state`/`action_state`/`anim_jump_type`/`movement_mode` all arrive from a peer's `extras`. Found and fixed in an earlier review pass. |
| **Peer counts** | `land_count`, `jump_count`, `afterimage_count`, `montage_count` are edge-triggered comparisons (`target > last_seen`), never loop bounds or indices. A hostile huge count fires an action **once**. Verified: no `for` loop is bounded by a peer value. |

### Gap 1 — a peer can name any UObject in the running game (Pseudoregalia)

`Plugin.cpp:9383` passes a peer-supplied string to an engine-wide lookup by name:

```cpp
UObject* montage_obj = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, to_wide_ascii(remote.target_montage).c_str());
```

**Not ACE, and the reason matters:** the very next lines type-check the result and refuse anything
whose class is not `AnimMontage`, so there is no type confusion into `call_montage_play`. Someone
already reasoned about this.

**What is still wrong with it:** the check is "is it an AnimMontage", not "is it one of the montages
this adapter expects". So a peer can play **any** montage in the loaded game on their own ghost, and
the warning line on a miss tells them whether an arbitrary object name exists — a small
object-enumeration oracle driven entirely by remote input. **The fix is an allowlist of the montage
names the adapter actually mirrors**, which is a fixed, tiny set.

### Gap 2 — a peer names a Unity animation state — CLOSED IN CODE 2026-08-28, unwatched

`Plugin.cs` — `visual.Pc.anim.Play(state.Anim)` — handed a peer string straight to Unity's animator,
bounded only by `protocol.MaxAnimLen` (256) and UTF-8 validity.

**Not ACE** (managed, memory-safe; an unknown state is a no-op or a warning). But it was unvalidated
against anything, so a peer could put their ghost into any state the controller defines, and a peer
alternating two bogus names defeated the `!= visual.LastAnim` guard and produced a Unity warning
**every frame** — log flood rather than a crash. It is the one row in the table below that crossed
the user's stated line.

**The fix, built 2026-08-28: `IsPlayableAnimName`, checked against the ghost's OWN Animator
controller rather than a list written in the adapter.** `Animator.HasState` performs the same
name → state lookup `Play` does, over every layer, so anything rejected is something `Play` could
not have found either — an exact bound rather than an approximation, and one that invents no
animation vocabulary (`contract.md`: `anim` is opaque outside the adapter that produced it). A
length bound sits in front of the hash, and a rejection is logged **once per name per peer, first
four only**, because an unthrottled complaint would reproduce the very per-frame log line being
fixed. Both `Play` call sites — the name change and the phase correction — are gated on it.

**Unwatched.** The regression it could cause is visible rather than subtle: if the controller's
state names did not match the clip names `GetAnimationTrueName()` reports, real animations would be
refused and every ghost would hold one pose. That cannot be true of the current build — the
animation and phase sync are confirmed on screen, which means `Play` is resolving these names today
— but it is what to look at. `adapters/tevi/UNVERIFIED.md`.

### Gap 3 — the systemic one, and the reason this keeps being per-adapter work

**`extras` is bounded only by TOTAL SERIALIZED BYTES** (`protocol.MaxExtrasBytes`, 1024) — not by
per-field type, range, finiteness, key count or nesting depth. Pseudoregalia's own comment says so
outright: *"extras values reach here unchecked"*. So **every adapter must clamp every field
itself, correctly, forever** — and the two gaps above are simply the places that has not been done
yet. That is the argument for the receive-side, adapter-declared constraints in the game-blind entry
below: it turns "every adapter remembers" into "the core enforces what the adapter declared".

### The line the user actually drew, 2026-08-27 — and the audit against IT

*"A peer can still make their own ghost do cosmetically wrong things"* — *"this is fine, but i never
want someone else to do anything malicious/harmful towards someone elses computer"*.

**That is a narrower and far more tractable requirement than "nothing bad ever", and it is the one
to design against.** Cosmetic misbehaviour confined to the sender's own ghost is explicitly out of
scope. What matters is whether peer-controlled data can reach anything on the RECIPIENT's machine.
Audited against exactly that, and every one of these was traced rather than assumed:

| Vector on the recipient's machine | Finding |
|---|---|
| **Code execution** | **No path found.** No `load`/`loadstring`/`dofile` in either Lua adapter; the only `io.popen` is the literal `"cd"`. |
| **Native memory corruption** | The one real hazard — `static_cast<uint8_t>(NaN)` is UB — is clamped in 15 places. The one peer-named engine lookup is type-checked against `AnimMontage` before use. |
| **File write / path traversal** | **No peer data reaches any file path.** Adapter log names are built from pid + date + bridge port (`crystal:572`, `emerald:564`); Emerald's cache path is the literal `logs/xmap_cache.txt`. There is no attacker-influenced filename anywhere. |
| **Unbounded memory growth** | Every per-peer map is keyed by the RELAY-ASSIGNED `player_id`, bounded by `MaxClients` (8) — not by a peer-chosen string. The one map keyed by `AreaID` (`relay/introspect.go:241`) is built per-snapshot from live membership and discarded, so its size is member count, not key space. |
| **Loop-bound abuse** | No `for` loop anywhere is bounded by a peer value; the counts are edge-triggered comparisons. |
| **Disk growth** | **The one thing that crossed the line, and it is now fixed in code (2026-08-28, unwatched).** TEVI's `anim.Play(state.Anim)` was unvalidated, and a peer alternating two bogus names defeated the `LastAnim` dedupe to produce a Unity warning **every frame** — disk and CPU on the recipient, driven entirely by remote input. `IsPlayableAnimName` now refuses any name the ghost's own controller does not have, and logs at most four rejections per peer. See gap 2 above. |
| **Relay/core process integrity** | Bounded by the per-field caps in `protocol/limits.go` and covered by 13 fuzz targets. |

**So on the stated line, the answer today appears to be: nothing a peer sends can harm your
computer, with one exception that is disk-growth rather than compromise.** That is a much stronger
claim than "no ACE" and it is the one worth defending.

**The structural caveat, which is the whole reason gap 3 matters.** The absence of a path is a
property of the CURRENT field set, not a guarantee about the next one. `extras` is bounded only by
total serialized bytes, so a field added later reaches every adapter unvalidated and nothing in the
Go side would catch a new sink. **Every row above would have to be re-audited by hand on each new
field.** Adapter-declared constraints enforced on RECEIVE turn that from a recurring audit into an
invariant.

### The star topology, and what it does NOT cover

**The user, same day:** *"the star topology makes sure people don't have to share their ip with
random people, but i also want it to be 'safe' to play with randoms"*.

**The IP-privacy half is real and enforced, not just intended.** Every client talks only to the
relay; the relay re-encodes rather than forwarding bytes, no message type carries an IP, and
`conn.RemoteAddr()` has no call site anywhere in `relay`, `core` or `cmd/` (`docs/security.md`'s
privacy section states it and a grep confirms it). **Players cannot learn each other's addresses.**

**What it does not cover, and this is not a gap so much as the shape of a star:** the relay operator
sees every player's address, necessarily — they are the one accepting the connections. So *"safe to
play with randoms"* splits in two, and only one half is a code problem:

- **Safe from other PLAYERS** — delivered by the topology, plus the data audit above.
- **Safe from the HOST** — a trust decision, not a property. Joining a stranger's relay means giving
  that stranger your IP, and no amount of clamping changes it. The honest mitigations are social
  (host your own, or join someone you know) or infrastructural (a community relay run by someone
  trusted). **`docs/security.md` already says this** — *"the relay is still the one party that COULD
  see a real IP ... unavoidable for any relay architecture — but right now it doesn't even use that
  information"* — so this is a restatement for the threat model, not a doc gap.

### CORRECTION: "the adapter has no network access" does NOT close the peer-to-peer data path

**The user asked the right question, 2026-08-27:** *"so it couldn't technically send something to the
client, that send it to the server, and then another client gets it, and that causes their game to
run/do things outside of the game?"*

**That path is real, and it is THE attack path.** A hostile party — a modified adapter, a modified
core, or most realistically a hand-written client that just speaks the protocol — crafts state that
travels adapter → core → relay → victim's core → victim's adapter → **writes into the victim's game
memory.** Every hop is the legitimate one.

**An earlier version of this entry cited "an adapter never touches the network" as protection here.
That was wrong, and it is worth recording why**, because the underlying claim is true and load-
bearing for something else. `docs/security.md` makes it in the PRIVACY section and states it
narrowly: a compromised adapter cannot *learn anything about* another player's machine. That is
about information flowing OUT. Generalising it to "no route to another player's machine" imports it
into a threat model it was never making an argument about — the attacker here does not need the
adapter to have network access, because the core will carry the payload for it.

**What actually defends this path, in order of how structural each one is:**

1. **The victim never parses attacker-controlled BYTES — and this one is genuinely structural.** The
   relay does not pass bytes through; `Room.forward` re-marshals from the parsed, validated struct
   (`relay/relay.go:336`, `json.Marshal(msg)`). So a hostile peer cannot put malformed JSON, deep
   nesting or a parser exploit in front of the victim's decoder: the victim only ever parses bytes
   the RELAY serialized. That eliminates the whole parser-exploit class between peers rather than
   auditing it away, and it is why the 13 fuzz targets are about robustness rather than the last
   line of defence.
2. **Both ends validate, including against a hostile relay.** `core/remotes.go` runs
   `protocol.ValidateState` on everything arriving FROM the relay — length, size and finiteness
   caps — explicitly *"since a hostile or compromised relay was previously trusted completely"*. So
   point 1 degrading (a malicious HOST, who does control the bytes) does not leave the victim
   undefended.
3. **Per-sink handling in the victim's own adapter.** This is the layer that decides whether an
   in-schema value can do harm, and it is the one with no structural backstop — see gaps 1-3 above.
   Today it holds: no sink reaches code execution, memory corruption or the filesystem. That is an
   AUDIT RESULT, not an invariant.

**So the honest answer to the question is: it cannot happen today, and the reason is not the
topology — it is that points 1 and 2 reduce the attacker to in-schema field values, and point 3 was
traced field by field and found clean.** The part that should make anyone uncomfortable is that
point 3 is re-earned on every new field, which is exactly the argument for adapter-declared
constraints enforced on receive.

### What this means for the goal as stated

**"No ACE" appears to hold today**, on this evidence, and mostly by deliberate work rather than
luck. **"Nothing malicious/bad ever"** does not hold and cannot be reached by clamping alone: a peer
can still make their own ghost do cosmetically wrong things (any montage, any anim state), and the
honest framing is that the blast radius is *your view of their ghost*, never your game's control
flow. Ranking the remaining work by what it actually buys:

1. **Allowlist the two named sinks** (gaps 1 and 2) — small, local, closes the only two unbounded
   peer-controlled name lookups in the tree.
2. **Per-field `extras` bounds, declared by the adapter and enforced on RECEIVE by the core** (gap
   3) — the structural fix, and the one that stops this recurring per adapter.
3. **A per-IP pre-auth cap** — already tracked; DoS, not ACE, and unrelated to peer data.

**Not worth doing:** hunting for ACE in the Lua adapters. The sandbox and BizHawk's domain bounds
mean the worst case is a corrupted emulated save state, and the audit above found no path even to
that from a validated field.

## Structural validation of `extras` AND `orientation` — bounding SHAPE without ever reading MEANING

**BUILT 2026-09-03.** `MaxJSONDepth = 32` in `protocol/limits.go`, enforced on both fields by
`ValidateState`, with `StateRejectReason` naming the shape rather than a size that is not the
problem. Regression test `TestDepthBoundRefusesWhatTheSizeCapAdmits` (which fails without the
bound, checked by raising the constant), and `FuzzDepthBoundsAgreeAndNeverPanic` in CI, pinning the
raw-byte scanner against the decoded walk — orientation is bounded by the scanner ALONE, so a
scanner more permissive than the walk would be a hole in the one field never decoded here. The
research below is left as written, because it is why the bound exists and it is still the argument
for the number.

> **The hold was lifted for THIS change only, by the user, 2026-09-03**, when the same exposure
> turned up from the other end: an adapter-side fuzzer found that Emerald's Lua decoder followed
> nesting 5000 levels deep while Crystal refused past 64. Asked where the bound belonged, the
> user's answer was **both, adapter first**. The adapters were fixed the same day; this is the
> other half.
>
> The 2026-08-24 hold it replaces read: *"i will def want to brainstorm/plan it out even more
> before we actually do anything extra for server/client security anyway."* **That still stands
> for everything else on this page** — one lifted item is not a lifted page.

**Why 32 rather than the adapters' 64:** it sits below what every adapter enforces, so nothing an
adapter would refuse ever reaches one, and it is still an order of magnitude above anything a game
has sent. Defence in depth in the literal sense — the core protects every adapter including a
third-party one, and each adapter still protects itself.

**The gap.** `State.Extras` is `map[string]any` (`protocol/protocol.go:47`) and `ValidateState`
checks exactly one thing about it: total serialized size <= `MaxExtrasBytes` (1024). Nothing bounds
its *structure*. Measured 2026-08-24 with a throwaway test against the real `ValidateState`:

```
depth   10: extras wire bytes=  26  ValidateState=true
depth  100: extras wire bytes= 206  ValidateState=true
depth  400: extras wire bytes= 806  ValidateState=true
depth  490: extras wire bytes= 986  ValidateState=true
```

A 490-level-deep nested value passes every check in under 1KB. The relay forwards it
(`relay/relay.go:1364`), the receiving core re-serializes it faithfully, and it arrives at every
other player's adapter — where each Lua adapter's hand-rolled recursive-descent decoder
(`meshghost_crystal.lua:528`, *"not a general JSON library"*) tries to descend 490 levels. The
`pcall` at the bottom of that decoder should turn a Lua stack overflow into a dropped message
rather than a hang, **but that is an assumption and has not been run in BizHawk's own Lua.**

**`orientation` has the identical bug — measured 2026-08-24, after this entry was first written
against `extras` alone.** It is `json.RawMessage` (`protocol/protocol.go:42`) and `ValidateState`
bounds only its wire length (`MaxOrientationBytes`, 256), never its structure:

```
depth    5: orientation wire bytes=  10  ValidateState=true
depth   50: orientation wire bytes= 100  ValidateState=true
depth  120: orientation wire bytes= 240  ValidateState=true
depth  127: orientation wire bytes= 254  ValidateState=true
```

**So the fix must cover both fields, not just `extras`.** Same cause (a size bound standing in for
a shape bound), same fix, same commit.

**`area_id` and `anim` need nothing further, and this is worth writing down so nobody "hardens"
them again.** Both are already bounded to 256 bytes AND validated as UTF-8 by `ValidOpaqueString`
inside `ValidateState`. The core is permitted to compare them by equality and nothing else, so
there is no further check it could perform without becoming game-aware. Confirmed 2026-08-24 that
a max-length arbitrary-byte `area_id`/`anim` passes — which is correct behaviour, not a gap. Any
remaining risk from those two lives entirely in what an ADAPTER does with the string.

**Why this is NOT a violation of the opacity rule, which is the whole point of the entry.**
`CLAUDE.md` says `area_id`, `anim` and `extras` are opaque to the core and that no config or
feature may make the core game-aware. That rule means **do not interpret the contents** — it does
not mean **accept any structure**. No legitimate game state is 490 objects deep; that is a
structural fact about JSON, not a semantic fact about any game. So the core can reject it while
staying exactly as blind to meaning as it is today.

**The shape it would take.** Three caps in `ValidateState`, alongside the existing byte bound: a
nesting-depth cap, a key-count cap, and a restriction on value types. Applies on both existing
enforcement points at once, since relay and core already share the function.

**Size the caps from what shipped adapters actually send — measured 2026-08-24, not assumed:**

| Adapter | extras keys | max depth | value shapes |
|---|---|---|---|
| Crystal | 4 (`sprite`, `act`, `prog`, `face`) | 1 | numbers |
| Pseudoregalia | 26 | **2** | numbers, short strings, **arrays of floats** |

**Pseudoregalia sends arrays** — `weapon_pos`, `weapon_rot` and `afterimage_color` are
`[float, ...]` (`Plugin.cpp:8560-8600`). So "flat map of scalars" is NOT a safe restriction: it
would refuse a shipped adapter. The workable rule is **scalars and arrays of scalars, depth <= 4,
<= 64 keys** — roughly 2x the observed depth and 2.5x the observed key count. At those numbers the
contract-narrowing risk is close to theoretical: a third-party adapter would have to exceed twice
the depth the most complex shipped adapter uses before it noticed.

**Why it is worth doing at this layer rather than per adapter.** It fixes the problem once for
every adapter that exists or is ever written, including third-party ones
(`docs/integrating.md`) that will not have read this file. It also *shrinks* the adapter-side
work: once the core guarantees a flat map of scalars, an adapter only has to range-check the
numbers it already reads, instead of defending against arbitrary structure.

**What it does NOT cover, and where that work belongs.** Semantic bounds — "`sprite` is 1-255",
"`act` is 0-7" — can only live in the adapter, which is the one component permitted to know what
those mean. That is the architecture working, not a workaround: the core is the trust boundary for
*shape*, the adapter is the trust boundary for *meaning*. Crystal already does this correctly for
`sprite` (`meshghost_crystal.lua:1359`, bounds 1-255 and refuses an implausible ROM pointer) and
~~**not at all for `act`, `prog` and `face`, which are `tonumber`'d with no range check**
(`:5084-5099`)~~. The rule belongs in `_template/` so the next adapter starts with it.

> **CORRECTED 2026-09-04, and the correction is a lesson about how to audit.** That struck claim
> was read off the READ SITES, and a read site is not a sink. Traced field by field to where each
> value actually means something: `act` passes `ACTIONS.peer`, a seven-value allowlist, before any
> write; `face` reaches `facingFrames.pose`, which handles it entirely by range test (`< 0x10`,
> `== 0xFF`, `0x10..0x13`) and `& 3` masks and never indexes with the raw byte; `prog` is
> overwritten by a locally computed `math.floor(along) % 16` on the moving path and elsewhere only
> compared. `fly` reaches `iconGfx`, bounded to species 1-251; `emote` reaches `emoteGfx`, bounded
> 0-11; `entry` is an equality test. **Emerald was audited the same day and is bounded too** --
> every `tonumber` there is followed by an explicit range check on the next line, the three
> boolean-ish fields are coerced with `~= 0`, and `gfx` is bounded inside `graphicsInfo` (integer,
> 0-255, every ROM pointer validated before use).
>
> **So the layer-2 work this entry scoped for the two Lua adapters is largely already done**, and
> doing it again would be churn with real regression risk against the 1:1 bar. What the audit
> should have asked, and what the next one must: *where does this value END UP*, not *is there a
> check on the line that reads it*. `tonumber` with a bound three lines later is bounded; a
> beautifully checked read whose value then indexes a table is not.

**Costs and risks.**

- **It is a contract narrowing, so it needs an ADR, not a quiet edit.** `contract.md` currently
  promises free-form `extras`. At the caps above nothing shipped breaks — but a third-party
  adapter written against the current contract legitimately could, and would start being refused.
  Decide the caps generously, and from the measured table, not from a guess: the first version of
  this entry proposed "flat scalars only" on the strength of reading Crystal alone, which would
  have refused Pseudoregalia's float arrays.
- **Refuse or truncate?** `ValidateState` refuses the whole state today. Refusing means one bad
  field makes a peer vanish rather than look wrong; that is the existing posture
  (`ValidateState` "drops rather than truncates") and should stay, but it is worth saying out loud.
- Needs a fuzz target in the `protocol` package's existing set and a regression test that fails
  without the fix.

### Should third-party adapter support be dropped, to let our own adapters be locked down harder?

**Asked by the user 2026-08-24, alongside: "i still don't really want to bake server/client things
into the adapters themself, just so things stay modular/split and its easy to add more
adapter/games etc." Answer: the trade buys nothing, and the two instincts are the same instinct.**

- **Dropping third-party support would not make our adapters more secure.** The security comes
  from the CORE enforcing the caps, and that enforcement is identical whether third-party adapters
  exist or not. The only thing third-party support costs here is that the cap has to be chosen
  generously rather than tightly — and the measured table above shows generous is cheap.
- **"Third-party adapter support" and "easy to add more adapters/games" are one property, not
  two.** What makes both true is the bridge contract being documented and stable
  (`docs/integrating.md`, `_template/PROTOCOL.md`). Damaging one damages the other; the second is
  the thing the project actually depends on.
- **"Don't bake server/client things into the adapters" is the argument FOR putting this in the
  core, not against it.** If the core does not bound shape, then every adapter must defend itself
  against arbitrary JSON — that IS the baking-in, repeated per game forever. The core bounding
  shape once is what lets an adapter stay dumb about networking and range-check only the handful
  of numbers it already reads.

**So the design question is not "third-party or not". It is only "how generous are the caps", and
that is answerable by measurement** — see the table above.

**Worth carrying into the design pass:** Pseudoregalia already documents this exact gap and
defends against it. `clamp_to_uint8` (`Plugin.cpp:1573`) exists because
`static_cast<uint8_t>(double)` on NaN or an out-of-range value is *undefined behaviour*, not
merely wrapping, and its comment states plainly that extras "reach here unchecked". So the one
adapter where memory safety is genuinely at stake already does the adapter-side half correctly;
the two Lua adapters do not. Whatever the core ends up enforcing, that asymmetry is the model to
back-port, and the rule belongs in `_template/`.

**Related, found in the same 2026-08-24 pass and NOT this entry:** the two `while true` loops in
each Lua decoder have no end-of-input guard and run away on unbalanced input (local-only
reachability — the core always emits well-formed JSON); the relay has no per-IP pre-auth cap;
the shipped relay config is an open relay. The first is adapter work; the last two are already
above in the transport-security entry.

## Should the Go side stay game-blind? — and the middle path the rule already permits

**Unscheduled. Raised by the user 2026-08-24**: *"would breaking the 'don't have game knowledge'
thing in the server/client be a good or bad thing?"* **Recommendation: do not break it — but there
is a third option that is not 'blind' or 'aware', and it should be what layers 1 and 2 above are
evaluated against before either is built.**

**What the rule actually forbids, which is narrower than it sounds.** The user's own words
(2026-08-20, quoted in `internal/gameblind/gameblind_test.go`): *"its fine to have the `game_id`
etc, know what game it is. but specifically for 'game knowledge' on what the games do/how they
work."* **Identity is permitted; mechanics are not.** A label may be carried, compared and logged;
it may never be the thing a behaviour is chosen by. That distinction is what leaves the door open
below.

**Real pros of breaking it — not strawmen:**

- Layer 2 collapses into layer 1: semantic validation lives in one place instead of per adapter,
  and is enforced before anything reaches a game process.
- Plausibility checks (position delta per tick) become possible server-side, where today they can
  only exist in an adapter.
- Server authority becomes conceivable at all — the only real path to anti-cheat if the deeper
  planes ever gain a live consumer.

**Real cons, and they land precisely on the properties the project is built for:**

- **"Easy to add a game" dies.** Every new game becomes a core change AND a relay change, a
  release of both, and every player updating before anyone can play it. Today an adapter is
  self-contained.
- **Third-party adapters die outright** — they cannot ship core changes, so the ceiling becomes
  "games the maintainer personally implements".
- **A relay operator must run a relay that knows about games they do not play**, and relay updates
  become gated on game support.
- **Version skew triples.** Adapter and core today agree on wire SHAPE; they would have to agree
  on game SEMANTICS, so a stale relay would be wrong about a game rather than merely older.
- **`TestWireFieldsAreFrozen` would have to be deleted**, and that is the check that catches the
  realistic failure. Per its own comment: nobody writes `if game == "emerald"` after reading the
  rule — the real drift is CONTRACT CREEP, a field one game needs "just passed through".
- **The property the user named as the upside — that the networking "just works" when separated
  from games — exists BECAUSE of this constraint, not alongside it.** The Go side is fuzzable and
  unit-testable precisely because it cannot be game-shaped.

### The middle path: adapter-declared constraints, enforced but never interpreted

**Neither blind nor aware.** At join, an adapter declares its own bounds **as data** — "this
extras key is an integer 0-255", "max position delta per tick is 16", "depth <= 2". The relay and
core enforce them and **never learn what `sprite` means**: they see a numeric range, not a
mechanic. That is squarely the *"dumb/generic things in the server/client... if it allows us to
reuse things for other games"* the same 2026-08-20 quote already permits.

**It fits an existing tested pattern rather than inventing one.** Room-scoped feature stickiness
already works exactly this way — the first joiner sets it, later joiners must match
(`relay/relay.go:897`), the same shape as `Room.GameID`. A constraint set would ride the same
mechanism, which also closes the obvious hole: **a hostile late joiner cannot widen the bounds,
because the room's set is already fixed.**

**What it buys:** semantic validation enforced centrally, plausibility checks made possible,
third-party adapters still working (they declare their own bounds), and no core change per game.

**Honest risks:**

- **Self-attested.** Sticky-on-first-join covers the late joiner, but the FIRST joiner defines the
  room's limits — fine when hosting friends, weaker when joining strangers.
- **A protocol addition**, so it needs an ADR and a deliberate `TestWireFieldsAreFrozen` edit —
  which is exactly where that test intends the burden of proof to be stated.
- **Schema creep is the failure mode.** Grown into a mini-language it becomes game knowledge with
  extra steps. Keep it to numeric ranges plus the depth/key caps and nothing more.

**Why the recommendation is "do not break it":** every pro above is downstream of server
authority, which would have to be actually BUILT to collect, while every con lands on the two
properties that are the point of the project. The middle path gets most of the security benefit
for a fraction of the cost, and it does not require deciding today.

### ENDORSED BY THE USER, 2026-08-27 — and for EVERY adapter, not as an option

*"i think this should be a thing for all adapters, to ensure they are 'safe' to play with random
people. and no one being able to send bad/malicious data to anyone else"*, and, immediately after:
*"while still keeping the server/client dumb & not knowing how games work ofc, if possible"*.

**So this stops being one of three options to weigh and becomes the intended direction.** Two things
follow that the entry above did not say:

**1. It belongs in the ADAPTER CONTRACT, not just the protocol.** "A thing for all adapters" means
declaring constraints becomes part of what an adapter IS — `adapters/_template/PROTOCOL.md`, the
mandated file set, and `/new-adapter`'s sequence — the same way the bridge shape and the port walk
already are. An adapter that declares nothing is then a visible gap rather than the default, which
is the difference between a property the project has and one it hopes for.

**2. "If possible" — yes, and this is the one part of the design that makes it possible.**
Constraints travel as DATA (a numeric range, a depth cap, a key count) and are enforced by
comparison. The Go side never learns that `sprite` is a sprite. That is the same permitted use as
`game_id`: carried, compared, logged, never the thing a behaviour is chosen by. No `internal/gameblind`
check has to be weakened, and `TestWireFieldsAreFrozen` gets a deliberate edit for the new field,
which is exactly where that test intends the burden of proof to sit.

### The correction the user's goal forces: enforce on RECEIVE, against the LOCAL adapter's bounds

**The room-negotiated, sticky-on-first-join design above does NOT achieve *"no one being able to
send bad/malicious data to anyone else"*, and this is worth being blunt about.** Its own risk list
concedes the first joiner defines the room's limits — so joining a stranger's room means that
stranger's declared bounds govern what may reach your game. A hostile host declares wide bounds and
the protection is gone precisely when it was wanted.

**The fix inverts where enforcement happens, and it is simpler than the negotiated version.** Your
core validates incoming peer state against **your own adapter's** declared constraints — the
adapter that is about to render it — not against anything the room agreed. Then:

- **A hostile host cannot widen your bounds**, because your bounds were never up for negotiation.
- **No stickiness, no first-joiner rule, no trust in any remote party.** The mechanism stops being a
  negotiation and becomes a local receive filter, which is strictly less protocol to get wrong.
- **It composes with mismatched adapter versions.** An older peer sending a field your adapter now
  bounds differently is rejected by your rules, not theirs.
- **It is where the trust boundary actually is.** The relay re-encodes every forwarded message from
  a validated struct (see the umbrella entry), so the last hop before a game process is the core —
  and that is the only place a check protects *you* rather than protecting everyone equally from
  nobody in particular.

**What the negotiated version is still for** — and why this is a refinement rather than a
replacement: agreeing bounds room-wide is how you stop a peer being rendered inconsistently across
different players, which is a different goal from not being attacked. If both are wanted they can
coexist, but **only the receive-side one delivers the sentence the user actually wrote**, so it is
the one to build first.

**Unchanged from above:** schema creep is still the failure mode. Numeric ranges plus the depth and
key caps, and nothing that could grow into a mini-language — a schema rich enough to express a
mechanic is game knowledge with extra steps.

## The bridge is unauthenticated and loopback only by DEFAULT, not by enforcement

**Unscheduled. Not on the depth ladder — Go side, confirmable with the tools rather than by
watching a game. Found 2026-08-24** in the same "is it safe to play with random people" pass as
the `extras` entry above. **Parked at the user's request, not queued** — offered as a same-day fix
and deliberately filed here instead.

**The gap.** `core/core.go:263` states as a fact that *"the adapter bridge is always loopback
TCP"*, and `contract.md` says the same. Nothing enforces it. The bind address is a flag
(`cmd/meshghost/main.go:517`, default `127.0.0.1:7778`) **and** a config key `local_game_bridge`
(`:111`), and it reaches `net.Listen("tcp", *bridgeAddr)` (`:766`) with no loopback check and no
warning line.

**Why this is worse than an ordinary misconfiguration.** The bridge has **no authentication at
all** — no room code, no hello check, nothing — and correctly needs none *given* the loopback
assumption. Break the assumption and there is nothing underneath it: a non-loopback bind turns the
machine into an open "drive my game and read my whole session" service for anyone on the LAN.

**The realistic path is config sharing, not a typo.** `config.json` is exactly the file a host
sends friends so they can join, and `local_game_bridge` sits in it beside the settings they are
meant to edit. One host with `0.0.0.0` in theirs propagates it to everyone they play with.

**The shape it would take.** Parse the bridge address, and if the host part is not loopback,
either refuse to start or warn loudly and require an explicit `-bridge-allow-remote`. Refusing is
probably right — there is no legitimate use for a remote bridge today, and `_template/PROTOCOL.md`
tells every adapter author to connect to `127.0.0.1`. Small, self-contained, needs no contract
change and no game session.

**Not to be bundled with the `extras` design pass above.** That one is a contract narrowing that
wants deliberate thought; this one is an unenforced invariant the docs already claim is enforced.
Different risk, different review, separate commits.

### Why the rest of the client -> relay -> client path is already sound (enumerated 2026-08-24)

Recorded so a future pass does not re-audit what is fine. **Every payload-carrying message type a
client can send is validated before the relay acts on it**, one-to-one:

| Client sends | Validator |
|---|---|
| `state` | `ValidateState` (`relay/relay.go:1356`) |
| `event` | `ValidateEvent` |
| `lease` | `ValidateLease` |
| `escrow` | `ValidateEscrow` |
| `world` | `ValidateWorld` |
| `leave`, `ping` | no payload |
| anything else | **ignored, never forwarded** (`relay.go:1514` default case) |

**The load-bearing property is that the relay never passes bytes through.** It re-encodes each
forwarded message from the parsed, validated struct (`envelope(protocol.TypeState, st)`), so a
client cannot smuggle extra JSON fields, malformed bytes, or anything the struct does not model —
the bytes another client receives were written by the relay, not by the sender. With the receiver
re-running the same validator (`core/core.go:1203`), dropping states from any `player_id` not in
the roster (`:1215`), `player_id` being server-stamped, and `display_name` never being
redistributed at all, **the entire client-to-client surface is the set of fields that struct
legitimately carries.** Of those, only `extras`, `area_id`, `anim` and `orientation` have contents
the core is contractually forbidden from interpreting — which is precisely what the `extras`
entry above is about.

## A blank `only_game` should mean "this project's games", not "anything" — layer 3's open-relay default

**The user's ask, 2026-08-27:** *"blank/default should only accept adapters from this project by
default. not 'anything'"* — *"to avoid random games utilizing servers / actually make it possible to
enforce and clamp values that adapters/games send etc"*.

**This is not a new idea so much as a concrete proposal for a gap already named:** layer 3 of the
"safe to play with random people" umbrella above lists *"open-relay default"* alongside the bridge
bind and the per-IP cap. Today `OnlyGame == ""` means *host any game* and the relay logs
`hosting any game (no "only_game" set)` (`relay/relay.go:1201-1203`,
`cmd/meshghost-relay/main.go:554`). Anyone who can reach the port and speak the protocol gets a
room, whatever `game_id` they claim.

### The half that is straightforward, and the trap in implementing it

Generalise `only_game` (one label, equality) to an allowed SET (many labels, equality) — the same
operation, and `game_id` comparison by equality is explicitly the permitted use.

**The trap: the list may not live in Go.** `internal/gameblind`'s `TestGoSideNeverBranchesOnAGame`
fails on *a game name appearing in a library package's code at all*, or in `cmd/` outside help text.
So a hardcoded `[]string{"emerald", "crystal", ...}` in `relay/` is not a philosophical problem, it
is **a red test** — and rightly, since the whole point is that the Go side never enumerates games.

**So the list is CONFIGURATION, not code.** `packaging/release/config.json` already ships the
defaults a host runs with; an `allowed_games` array there gives "the default accepts only this
project's games" with no game name anywhere in the Go side. The relay compares an incoming
`game_id` against a configured set it never looks inside. A host who wants the old posture sets it
empty (or to `"any"`) deliberately, which is the right way round: the permissive option becomes a
choice someone made rather than the thing that happens when nobody chose.

### The half that needs care: what "enforce and clamp values" can and cannot mean

**Per-game clamps in the relay are forbidden, and knowing the game-set does not unlock them.** The
rule in the user's own words (2026-08-20, quoted in `internal/gameblind`): *"its fine to have the
`game_id` etc, know what game it is. but specifically for 'game knowledge' on what the games do/how
they work"* — a label *"may be carried, compared to another label, and logged. It may never be the
thing a behaviour is chosen by."* `if game == "crystal" { maxSprite = 40 }` is exactly the shape
that is out.

**What an allowlist genuinely does buy, and it is worth having:**

- **Tightening the GENERIC caps, for everyone, because the population is known.** Several existing
  bounds are deliberately generous rather than measured — `protocol.MaxPositionComponent` is 1e7 and
  its own comment calls it *"headroom, not a realistic in-game bound"*. With the set of adapters
  known and measurable, those can be narrowed globally without a single per-game branch.
- **It makes layer 2 reachable at all.** Range checks on peer-derived numbers must live in the
  adapter (only it may know what a value means) — and an adapter can only be trusted to do that if
  the adapters on the room are ones that do it. That is the real link between the two halves of the
  ask, and it is a deployment property, not a relay feature.

**Read "Should the Go side stay game-blind?" below before building either.** Its middle path —
adapter-declared constraints the core enforces without interpreting — is the one mechanism that
gives real per-value enforcement while keeping the Go side blind, and it would change where this
belongs.

### The cost, which is the part to decide first

**This repo actively invites third-party adapters.** `docs/integrating.md` is a guide for putting
MeshGhost in *your own* game in any language, and the README's design claim is that *"a new game is
an adapter and nothing else"*. A default-deny allowlist refuses every one of those by default —
including a legitimate adapter someone wrote for a game we have never heard of, which is a use the
project explicitly wants. That is a real tension, not a detail to discover during implementation.

**And note the overlap with what already exists:** `room_code` is the actual secret for keeping
strangers off a relay, and it is already the documented answer (README: *"`room` is a label, not a
password. `room_code` is the optional actual secret"*). An allowlist stops the wrong GAME; a room
code stops the wrong PERSON. The user's stated worry is *"random games utilizing servers"*, which is
the first — so the two are complementary, and the honest framing is that this closes a different
hole rather than a better version of the same one.

**Open questions for whoever picks this up:** does an unknown `game_id` get a `reject` naming the
reason (consistent with how `only_game` refuses today, and kinder to a third-party author) or a
silent hangup? Does the shipped list live in `config.json` alone, or does `packaging/` generate it
from the adapter folders so it cannot drift from what actually ships? And is the default for a
**self-hosted** relay the same as for whatever a future public/community relay would want?

## Code signing the Windows binaries (SignPath OSS)

**Named publicly as the intended fix 2026-08-16**, in the "My antivirus flagged it" text that now
lives at `docs/antivirus.md`, so it needs an entry of its own rather than the single sequencing
mention it had inside the TLS idea. Unstarted.

**What it is:** SignPath offers free code-signing certificates and a signing service to open-source
projects. The build would sign `meshghost.exe` and `meshghost-server.exe` in
`.github/workflows/release.yml` before they are packaged.

**What it addresses, and what it does not** — worth separating, because they are three different
mechanisms and signing only fully solves one:

- **Authenticode** — "who published this, and has it been altered since". Signing answers this
  outright. This is the part that is simply fixed.
- **SmartScreen reputation** — a per-publisher score built from how many people have downloaded and
  run your signed files. A *new* certificate starts with none, so the first releases can still warn.
  An EV certificate is granted reputation immediately; SignPath's OSS offering is not EV, so this
  is earned over time rather than granted.
- **Defender's `!ml` verdicts** — a machine-learning judgement over a profile, of which signing and
  reputation are two inputs among several (prevalence, network behaviour, whether a process was
  started by a person or by another program). Signing improves the odds. It does not guarantee an
  outcome, and `README.md` deliberately does not promise one.

**Cost:** an application to SignPath's OSS programme, a project/artifact configuration on their
side, and a CI change with a signing step and a secret. The signing itself is a service call, not a
certificate file sitting in the repo — which matters here, since a private key in a public repo
would be exactly the sort of thing `CLAUDE.md`'s "nothing that couldn't be published" rule forbids.

**Why it keeps coming up:** it is now the mitigation named by three separate entries in
`risks.md` — the general false-positive one, the autostart one (a mod starting an unsigned exe is
dropper-shaped), and TLS (which would add cert generation plus encrypted traffic on top). It is the
only one of those where the work is bounded and the benefit reaches users directly.

## Replay files: one entry point for remote state (2026-09-03)

**The user's requirement:** *"just want to avoid someone ever being able to share a malicious replay
file"*. Phase 11 (ADR 0047) lets a player record their own state stream to a file and play it back
as a ghost, and share the file.

**The guarantee, and why it is structural rather than a second audit:** a replay file can do
exactly what a stranger in a public room can do, and nothing more, because a replayed sample
enters the core through the SAME function a relay packet does — `storeRemoteState`, with
`protocol.ValidateState` in front of it — and **the loader is forbidden a second entry point**.
`internal/gameblind` gains a check that only the relay session and the local-peer feeder call it,
so a new path cannot appear unnoticed. Every row of the ACE audit above therefore covers replays
for free, and every future adapter allowlist does too.

**On top, in the loader:** line size capped at the wire's maximum state size before decoding;
the header's `name`/`color` pass through `SanitizeDisplayName`/`SanitizeNameColor`; `speed` and
every duration are clamped; no file content ever becomes a path or a name the core acts on (file
names come from the directory scan, files open only under `replay/`, cleaned and prefix-checked);
a fuzz target pins the loader the way the wire parsers are pinned.

**The residual, stated honestly:** the same one the audit accepts for peers — a hostile file can
make its own ghost look wrong on the viewer's screen. It cannot touch the viewer's game or machine.
**No tamper detection**, by design: the file is on the player's machine, the code is public, and
editing is a supported use; nothing (no score, no time) is derived from a file.
