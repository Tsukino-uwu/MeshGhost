# Multi-relay — how more than one relay could carry a room, and why relays never talk to each other

**What this is.** A design on file, not work. The user asked on 2026-09-15 how an MMO runs "one
world" across many servers (the login / world / channel processes of a MapleStory server pack; the
zone servers and layers of WoW) and whether that shape would let MeshGhost scale from a private
group up to that. The answer: a room is already the shard, the area filter is already the
interest management, and the only missing piece for more than one machine is a **router** that
assigns areas to relays. **Nothing here is scheduled.** The tripwire that would schedule it: a
room whose busiest single area saturates one machine's uplink. Until then one relay is the whole
cluster. Numbers are the extrapolations in [scaling.md](scaling.md), re-measured before anything
is acted on.

## The one-line answer

Two players can only play together when their states pass through the same process. Today that
process is the one relay; with several relays it is the relay that owns the area they both stand
in. Nothing else changes. Relays never forward to each other, because every fact a room has about
an area lives on the relay that owns that area.

## The MMO shape, mapped onto MeshGhost

Gameplay traffic never crosses a server boundary in any of these systems. Two players on
different channels of the same map do not see each other; that is the design. What crosses is
tickets, chat and saved characters, all small.

| MMO piece | what it does | MeshGhost |
|---|---|---|
| login server (gateway) | authenticates, hands out a ticket and an address | the router: **missing** |
| channel / zone server | one process simulating some maps, a few hundred players | a relay process, which already exists |
| world server (broker) | whisper, party, guild, the list of live channels | none, by design: rooms are private groups, not a population |
| shared database | the character every channel loads | none needed: a ghost has no persistent character |
| channel switch | save, one-time ticket, client reconnects to the new port | the crossing below: the client reconnects, nobody is moved |

## Why splitting helps, and what it cannot help

- **Relays forwarding to each other does not reduce the cost.** Every state still reaches every
  recipient, so each machine still sends the full amount plus the copy between them; the 1000-peer
  table in [scaling.md](scaling.md) (uplink, not CPU, is what does not run) is unchanged by how
  many machines share it.
- **Splitting by AREA does.** A client with `own_area_only` receives only its own area
  (`contract.md`, "`own_area_only`", ADR 0041), so it only needs the relay that owns that area.
  A thousand-person room becomes several rooms-worth of areas, each under one machine's link.
- **One area never spans two relays.** So the busiest single area sets the ceiling, and a crowded
  area is a [culling.md](culling.md) and [crowd-limits.md](crowd-limits.md) problem, never a
  server-count one. An MMO's answer to a crowded city is a second copy of it whose crowds do not
  see each other; MeshGhost's is the game's own crowd limit plus culling.

## The three programs

- **Router**: a new small binary, `cmd/meshghost-router`, listening on its own port. It holds the
  list of live relays and answers one question per connection: "room X, area Y, which address?" It
  carries no player state and is idle between lookups. It can live on the same machine as a relay.
- **Relay**: one new optional flag, `-router <addr>`. Unset, the relay is exactly today's. Set, it
  connects out to the router on startup and registers (below).
- **Client**: may be pointed at a router instead of a relay. It asks, is given a relay address,
  disconnects from the router, and from then on is today's client-to-relay connection.

```
router VPS:   meshghost-router -listen :9000
VPS1:         meshghost-server -listen :8080 -router router.example:9000
VPS2:         meshghost-server -listen :8080 -router router.example:9000
player:       meshghost -connect router.example:9000 -room Tuesday
```

The router is only needed with more than one relay. One relay, no router, is today's setup.

## Registration: how the router knows the relays

A relay started with `-router` opens one connection to the router, announces its public address
and its capacity, and keeps that connection open as a heartbeat carrying its client count and
bytes per second. That heartbeat is the only connection a relay ever makes to another program,
and it never carries game traffic. Startup order is router, then relays, then players; a player
who asks before any relay has registered is told none is available. The alternative for a host
who runs machines they control is a fixed list of relay addresses in the router's config, which
lets the router start last. Either way a registration is accepted only from an identity the
router was told to expect ("Who trusts whom", below).

## Assignment: how areas land on relays

The router never holds a game's list of maps. `area_id` is opaque to the core and the relay
(`brief.md`; the `internal/gameblind` tests, `architecture.md`), and it stays opaque here: the
router sees the same string the relay already compares by equality, handed up from the adapter
through the core.

- **A formula, not a table.** The area label is consistent-hashed onto the live relay list. Same
  label, same relay, for every player who asks. An area is "assigned" the first time anyone asks
  about it; an area nobody enters costs nothing.
- **Consistent hashing, specifically.** With a naive hash, adding or removing a relay changes the
  owner of almost every area and everyone reconnects at once. With consistent hashing each relay
  owns a slice of the number line and a change moves only the areas in the affected slice.
- **Optional pins.** Router config may pin text-matched labels to a named relay, for a host who
  knows one area is a hotspot and wants it alone on the biggest machine. Still no game knowledge:
  the router matches text the host typed.
- **Load.** The hash evens out the NUMBER of areas, not the number of people. A smarter router uses
  the heartbeat to prefer lighter relays when an area is first assigned and when a room is created.
  A live, crowded area is never moved to balance; moving it disconnects everyone in it at once.
  Rebalancing is for empty areas and for a relay joining or leaving.

## The crossing, step by step

A player walks from an area owned by relay A into one owned by relay B.

1. The core sees the adapter's `area_id` change. It already acts on this moment today, because it
   is when the render filter changes.
2. The core asks the router for the new area and is told relay B.
3. It connects to relay B, joins the room there, and receives the seed of everyone already in the
   new area, reliably, the same rule the single-relay contract has now.
4. It sends its last state to relay A so the area being left sees it walk out (the crossing state
   is delivered to the area left, as today), then closes A.
5. All states go to B. The people already there see the player appear where the game put them.

Everyone crossing does the same, so at any moment relay A holds everyone standing in A's areas and
relay B everyone in B's. Two friends crossing together land on B together; a friend who stays is
hidden, which the area filter does on one relay too.

**Keeping it 1:1.** The gap between steps 3 and 5 is a round trip, and a ghost that pops in after
the new map draws is not 1:1. The core pre-connects to relay B when the game starts a transition,
or holds connections to the relays owning neighbouring areas, so the switch is between two open
sockets and the seed is in hand before the new map is drawn. The adapter and the game know nothing
of any of this.

## Membership proof across relays

Today the room code is proven to one relay and bound to that relay's TLS identity (ADR 0067).
With several relays the client proves it once to the router and receives a short-lived ticket any
relay of that room accepts, the login-server ticket of the MMO shape. This is the one new protocol
piece and a contract revision when built: a new ADR then, not now. The proof goes to the router,
which holds the room record in a cluster ("Who trusts whom", below).

## Who trusts whom

Written 2026-09-15, from the user's question that day: should the relay and the router prove
themselves to each other, strict and manual, so the router knows every relay it hands areas to
is the host's? Yes, and with a credential of its own that no client ever sees: the room code is
the players' secret and stays theirs. The extra work is assumed worth it at the scale that needs
a router at all (the user's call); one relay without a router is today's setup and pays none of it.

**What an unproven registration would cost.** A relay that registers is assigned areas, and
from then on receives every state of every player standing in them and may inject any ghost into
them. Registration is where the cluster is either the host's or anyone's.

**Strict, the default: the identities already on disk, pinned both ways.** Every relay persists
a TLS identity and writes its fingerprint to `private/server.fingerprint` (ADR 0066); a router
gets the same. The router's config lists, one line per relay, the fingerprint of each relay it
accepts, and a registration from any other certificate is refused whatever it announces. Each
relay is started with the router's fingerprint and refuses any other router. No trust on first use
on this leg in either direction, no secret to leak, and removing a relay is deleting a line. The
cost is the manual part: a new relay is a config edit, and a relay reinstalled without its
`private/` folder is a new identity that drops out until it is listed.

**Optional, looser: a cluster secret.** One long random value the operator generates once and
puts in the router's config and every relay's. At registration the relay proves it holds the
value with a keyed MAC over the TLS session's exporter, so the value never crosses the wire, and
relays then come and go with no router edit. The price is one value shared by every machine: a
copy leaking from any relay admits a rogue relay until the value is rotated everywhere, and the
router tells relays apart by address only.

**Why neither is a PAKE.** OPAQUE (ADR 0067) is there because the room code is short and typed
by a human, and a PAKE denies an interceptor an offline guess at a short secret. A cluster secret
is machine-generated and read from a file, so it can be 32 random bytes and a keyed MAC over it is
already unguessable; a PAKE here would buy a round trip and an Argon2id step for nothing. The pin
list has no secret at all.

**The player's trust in a relay chains from the router.** The router's answer to "room X, area
Y" carries the relay's address and its fingerprint, learned at registration. The client pins that
fingerprint for the connection, so ADR 0066's trust-on-first-use path is never taken for a relay
in a cluster. The one identity a player still meets cold is the router's, remembered on first use
as a relay is today, or pinned from a value the host published beside the address.

**Where the room code goes.** ADR 0067 binds the OPAQUE login to one relay's fingerprint, which
cannot hold when a player is meant to land on any of several. In a cluster the router is the
OPAQUE server: it holds the one record per room, bound to its own fingerprint, and issues the
ticket of the previous section; a relay in a cluster holds no room code and accepts the ticket.
The pin list and the cluster secret are configuration, not protocol; the ticket stays the one
new protocol piece.

## Failure

A relay's heartbeat stops. The router removes it and re-spreads its areas over the survivors. Its
clients drop, ask the router again, and land on the new owners; they see a blip and then everyone
in their area again. Everyone on the other relays is unaffected. A zone server crashing in an MMO
looks the same from the player's chair.

## What stops being true

Anything that deliberately looks across areas breaks. Emerald's `render_all_areas` (cross-map
ghosts in adjacent areas; ADR 0036) and any client without `own_area_only` see only the people on
their own relay. A client without the filter is asking for every state in the room, which is
exactly the load the split exists to avoid, so a split room must refuse that option, or the router
must copy every state to every relay and the split buys nothing. Every MMO makes the same trade:
you never see the other layer.

## Honest sizing

| figure | value | source |
|---|---|---|
| one full 8-seat room, 20 Hz | ~1.2 GB/h | `scaling.md`, "What Hz could Go actually carry" |
| rooms of that shape on one 1 Gbps host | on the order of a few hundred | derived from the line above; not measured |
| 1000 peers in one room, area-filtered to ~8 visible, 20 Hz | ~450 Mbps uplink | `scaling.md`, 1000-peer extrapolation |

The split only matters when one AREA's crowd exceeds one machine, which is hundreds of people in
one place and past every game's own crowd limit (`crowd-limits.md`). Everything above is fitted
from benchmarks to 128 peers and extrapolated; nothing past 16 peers has run for real
(`scaling.md`, "The principle"). Re-measure before acting.
