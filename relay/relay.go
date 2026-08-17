// Package relay is the game-agnostic server: it forwards protocol.State
// messages between clients in a room, partitioned by game_id, and never
// runs or touches a game. Since 2026-08-17 it also arbitrates the planes past
// cosmetic — addressed events, a room sequencer, leases, escrow, and session
// resumption — all of which live in online.go and all of which stay dumb:
// every key, id and payload there is opaque, and none of it runs for a room
// that did not opt in. It never imports core
// or bridge — the relay must stay ignorant of adapter-side
// concerns, the same way it's ignorant of games.
//
// Pre-1.0: no API stability guarantee. This package may change shape in any
// release, and third-party use is untested and unsupported. Running the
// shipped meshghost-server binary unmodified is the route we actually test.
// See the repo README and docs/integrating.md.
package relay

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// Room holds the connected clients for one room name. A Hello whose game_id
// (or, once declared, game_version) doesn't match an existing room's is
// rejected rather than mixing clients from different games/versions — see
// agent_docs/contract.md and the ADR in agent_docs/architecture.md.
type Room struct {
	GameID      string
	GameVersion string
	Name        string

	// joining counts clients that have been handed this room by
	// joinOrCreateRoom but have not added themselves to it yet.
	//
	// It exists because those are two separate critical sections: a joiner takes
	// s.mu to find or create the room, releases it, reserves a slot and mints an
	// id, and only then takes r.mu to add itself. If the room's last existing
	// member leaves inside that window, dropIfEmpty sees an empty room and
	// removes it from Server.rooms -- and the joiner then adds itself to a room
	// nobody can reach, because the next client asking for that name gets a
	// fresh one. Both are "connected", neither errors, and the ghosts simply
	// never appear. Same class as the roster-snapshot race, and just as silent.
	//
	// Guarded by Server.mu, NOT Room.mu: dropIfEmpty is the reader and it holds
	// Server.mu, so this has to live under the same lock as the rooms map it
	// protects an entry in.
	joining int

	// key is this room's identity in Server.rooms — game_id and name together,
	// see roomKey. Stored so dropIfEmpty can find its own entry without
	// recomputing, and so nothing is tempted to delete by name alone.
	key string

	// features is this room's agreed ROOM-SCOPED capability set, normalized
	// and sticky from its first member's Hello — a later joiner whose own
	// room-scoped set differs is refused (protocol.ReasonFeatureMismatch).
	// Client-scoped capabilities (resume, snapshot) are deliberately NOT in
	// here: they concern one client and the relay, no peer participates in
	// them, and making them sticky would cost a lockstep reconfiguration of
	// everyone for nothing. See protocol.IsRoomScopedFeature for the split and
	// agent_docs/beyond-cosmetic.md §3 for why the room-scoped half must be
	// matched exactly. Written once in newRoom, before the room is published
	// into Server.rooms, and never mutated, so it needs no lock.
	features []string

	// sendMu serializes the CONTROL plane — events, lease changes, escrow
	// changes, and the leave that ends a session — from the moment a
	// sequencer stamp is assigned until that message has been written to
	// every recipient.
	//
	// It is load-bearing, not defensive. Stamping under mu and then sending
	// after releasing it produces a correct total order that is delivered in
	// the wrong one: two concurrent events can be stamped 1 and 2 and then
	// race to the socket, so a client receives 2 before 1. That is exactly
	// what a sequencer exists to prevent, and it failed the total-order test
	// on the first run of it. The alternative — sending while holding mu —
	// is the shape that was deliberately removed from Room.forward, because
	// one stalled peer would freeze every other operation in the room.
	//
	// **Lock order is always sendMu then mu, never the reverse.** Room.forward
	// takes mu internally, so anything that delivers while holding sendMu is
	// consistent with that; nothing may take mu and then reach for sendMu.
	//
	// The state plane deliberately does NOT go through this: it is lossy and
	// latest-wins by contract, so ordering it would cost the hot path a
	// serialization point to guarantee something it does not need.
	sendMu sync.Mutex

	mu      sync.Mutex
	members map[string]*Client

	// Everything below is guarded by mu, and exists only for rooms whose
	// feature set actually asked for it — see online.go.

	// seqCounter is this room's monotonic sequencer: one total order over
	// events, lease changes and escrow changes, assigned inside the same
	// critical section that snapshots recipients. Starts at 0, so the first
	// stamp issued is 1 and a zero on the wire means "unstamped".
	seqCounter uint64
	// leases maps an opaque key to its current holder. nil until first use.
	leases map[string]*lease
	// escrows maps an opaque exchange id to its record, including terminal
	// ones inside their retention window. nil until first use.
	escrows map[string]*escrow
	// lastState is each member's most recent valid state, for seeding a
	// late joiner via Join.State. nil unless FeatureSnapshotV1 is on.
	lastState map[string]protocol.State
	// world is this room's custody map: the latest opaque blob per entity,
	// namespaced by the authority lease it was written under. nil until first
	// use, and deliberately outlives the lease and the client that wrote it —
	// see freeLeaseLocked and world.go.
	world map[worldKey]*worldEntry

	// Two once-per-room complaints about adapter misconfiguration, each of
	// which would otherwise repeat at the world plane's own message rate.
	// sync.Once carries its own synchronization, so neither is under mu — and
	// neither must be, since one of them fires from a path that already holds
	// it.
	//
	// worldWithoutLeaseOnce: this room negotiated world.v1 without lease.v1, so
	// every write names an authority that cannot exist. Logged rather than
	// rejected at the handshake, because making one feature imply the other in
	// NormalizeFeatures would change the sticky FeatureSetKey and silently stop
	// matching rooms that already agreed on the old string.
	//
	// worldLossyCreateOnce: an adapter tried to create a world key with a lossy
	// write. See world.go.
	worldWithoutLeaseOnce sync.Once
	worldLossyCreateOnce  sync.Once
}

// Client is one connected relay peer.
type Client struct {
	PlayerID string
	Conn     transport.Transport

	// maxReceiveHz is this client's own requested per-peer receive cap from
	// its Hello (protocol.Hello.MaxReceiveHz, already resolved through
	// protocol.ClampReceiveHz); 0 means uncapped. Written once when this
	// Client is constructed, before it is published into Room.members, and
	// never mutated after — so unlike gateMu/lastStateTo below it needs no
	// lock of its own.
	maxReceiveHz int

	// transport is which transport this client arrived over ("tcp", "udp",
	// "quic"), for logging only — nothing routes on it, and the relay
	// forwards identically regardless. Written once at construction, before
	// this Client is published into Room.members, so it needs no lock.
	//
	// Worth having because a room may legitimately mix transports: without
	// this, a host looking at "why is this player's ghost stuttering" has no
	// way to tell whether they are on udp or tcp short of asking them to read
	// their own client log. Gap noticed during the first live three-transport
	// test, 2026-08-16.
	transport string

	// features is this client's own full advertised capability set, normalized.
	// The room already agreed on the room-scoped half (Room.features); this is
	// kept per client for the CLIENT-scoped half — whether to hold this
	// client's identity after a drop (resume.v1), and whether to seed it on
	// join (snapshot.v1) — which no peer participates in and which therefore
	// may legitimately differ between two members of one room. Written once at
	// construction, before this Client is published into Room.members, so like
	// maxReceiveHz and transport it needs no lock.
	features []string

	// suspended marks a client whose connection dropped but whose identity
	// the relay is still holding, waiting out protocol.DefaultResumeGrace in
	// case it reconnects with its resume token (see online.go's
	// suspendedSession). It stays in Room.members so the roster a later
	// joiner receives is still complete, but Room.forward writes nothing to
	// it — Conn is nil. Guarded by Room.mu, unlike the write-once fields
	// above, because it is flipped after the Client is published.
	suspended bool

	// holdUntilWelcome reports that this client's own Welcome has not been
	// written to its connection yet, so nothing may be sent to it before
	// then; pending holds the reliable messages waiting behind it.
	//
	// handleConn adds a client to Room.members (tryAddAndSnapshotRoster) and
	// only then sends its Welcome, because the Welcome carries the roster
	// captured atomically with that add. Between those two lines the client
	// is a full member, so Room.forward — running on some OTHER connection's
	// goroutine — will happily write to it. If the room's last other occupant
	// disconnects in that window, its Leave reaches the socket BEFORE the
	// Welcome, and the protocol's one ordering guarantee ("Welcome is the
	// first message a client receives") is broken. core reads its
	// player_id and roster out of Welcome, so anything arriving first refers
	// to a session the client does not yet believe it has.
	//
	// Skipping such a client instead of queueing would be worse than the
	// race: rosterBeforeJoin is snapshotted at the add, so a Leave that lands
	// in the window is one the newcomer's roster still contains — drop it and
	// that peer is a ghost it never despawns.
	//
	// Guarded by Room.mu, like suspended, because both are written after the
	// Client is published into Room.members.
	//
	// Deliberately phrased as a HOLD rather than as "welcomed", so the zero
	// value means "deliver normally". Clients are also built directly in
	// tests and by the resume path, and none of those owe anyone a Welcome;
	// a "welcomed bool" would silently hold their traffic forever.
	// handleConn is the one place that opts in.
	//
	// Found by CI's race job 2026-08-17 as an intermittent
	// TestJoinRacingTheLastLeaveIsNotOrphaned failure ("got message type
	// \"leave\", want \"welcome\"").
	holdUntilWelcome bool
	pending          [][]byte

	// gateMu guards lastStateTo, which maps a *sender's* player_id to the
	// last time a State from that sender was forwarded *to this client*.
	// This is the one piece of per-connection state that does not inherit
	// handleConn's "OnReceive is serial, so no mutex needed" invariant: it
	// is per-recipient but read and written by the *sender's* OnReceive
	// goroutine, so every other member of the room can touch one recipient's
	// gate concurrently. See the ADR in agent_docs/architecture.md.
	gateMu      sync.Mutex
	lastStateTo map[string]time.Time
}

// allowStateFrom reports whether a State from sender may be forwarded to c
// right now, given c's own requested maxReceiveHz, and records the decision
// if so. A minimum-interval gate, not a token bucket — the same shape as
// core.Core.forwardLocalState's own throttle, and with the same consequence:
// the achievable effective rate is quantized to
// senderHz/ceil(senderHz/capHz), so e.g. a 15Hz cap against a 20Hz sender
// yields 10Hz, not 15. Acceptable because ghosts are cosmetic
// (agent_docs/contract.md's state plane is explicitly lossy, latest-wins) —
// excess samples are dropped, never coalesced or queued, so this can neither
// grow memory nor add latency. hz <= 0 (uncapped, the default and the only
// behavior an older client can get) returns true immediately without
// touching the map or the lock at all.
func (c *Client) allowStateFrom(sender string, now time.Time) bool {
	if c.maxReceiveHz <= 0 {
		return true
	}
	interval := time.Second / time.Duration(c.maxReceiveHz)
	c.gateMu.Lock()
	defer c.gateMu.Unlock()
	if c.lastStateTo == nil {
		c.lastStateTo = make(map[string]time.Time)
	}
	last, ok := c.lastStateTo[sender]
	if ok && now.Sub(last) < interval {
		return false
	}
	c.lastStateTo[sender] = now
	return true
}

// forgetSender purges sender's entry from c's own receive gate. Called when
// sender leaves the room: player_ids are never reused (nextPlayerID), so
// without this a long-lived relay with real churn would accumulate one
// stale map entry per departed sender in every remaining member's gate.
func (c *Client) forgetSender(sender string) {
	c.gateMu.Lock()
	defer c.gateMu.Unlock()
	delete(c.lastStateTo, sender)
}

func newRoom(gameID, gameVersion, name string, features []string) *Room {
	return &Room{
		GameID:      gameID,
		GameVersion: gameVersion,
		Name:        name,
		features:    protocol.RoomScopedFeatures(features),
		members:     make(map[string]*Client),
	}
}

// Forward routes msg to the given recipients. Shaped to take an explicit
// recipient set rather than hardcoding room-wide broadcast, so that wiring
// in real addressed event routing later (agent_docs/contract.md's
// Extensibility section) is a small localized change instead of a rewrite
// of this path.
func (r *Room) Forward(msg protocol.Envelope, to []string) {
	r.forward(msg, to, false)
}

// ForwardUnreliable is Forward for the state plane only, which
// agent_docs/contract.md defines as lossy and latest-wins. Identical to
// Forward on tcp; on a datagram transport it skips retransmission, so a
// lost sample is superseded by the next one rather than arriving stale and
// out of order behind it.
//
// Deliberately a separate method rather than a flag on Forward: every OTHER
// use — join, leave, reject, the loopback ghost's own join — must stay
// reliable, and a caller that forgets which it wanted gets the safe one.
// See the transport ADR in agent_docs/architecture.md.
func (r *Room) ForwardUnreliable(msg protocol.Envelope, to []string) {
	r.forward(msg, to, true)
}

func (r *Room) forward(msg protocol.Envelope, to []string, unreliable bool) {
	payload, err := json.Marshal(msg)
	if err != nil {
		// Envelope's fields always marshal; nothing in this project builds
		// one with a channel, func, or other unmarshalable payload.
		log.Printf("relay: BUG: envelope failed to marshal: %v", err)
		return
	}

	// Snapshot the target connections under the lock, then send after
	// releasing it. This used to send while holding r.mu for the whole
	// loop; now that NDJSONConn.Send can block for up to its own
	// WriteTimeout against a stalled peer (see transport.go), holding the
	// lock across every recipient's Send meant one stalled room member
	// could freeze every other room operation — joins, leaves, roster
	// reads, other Forward calls — for the same duration. Found while
	// scoping relay-safety hardening, agent_docs/architecture.md's
	// room-code/version ADR.
	type target struct {
		id   string
		conn transport.Transport
	}
	r.mu.Lock()
	targets := make([]target, 0, len(to))
	for _, id := range to {
		// A suspended member is still in the room (so rosters stay complete)
		// but has no connection to write to — skipped silently rather than
		// attempted, since a Send against a nil/closed conn would log a
		// failure per message per second for the whole grace window.
		c, ok := r.members[id]
		if !ok || c.suspended || c.Conn == nil {
			continue
		}

		// A member whose Welcome has not been written yet must not be sent
		// anything ahead of it — see Client.welcomed. Reliable traffic is
		// held and flushed in order by markWelcomedAndFlush; lossy state is
		// dropped instead of queued, because the state plane is
		// latest-wins by contract and this client is about to be seeded
		// with everyone's current state by joinSnapshot anyway. Queueing it
		// would only deliver a sample that is already stale on arrival.
		if c.holdUntilWelcome {
			if !unreliable {
				if len(c.pending) < maxPendingBeforeWelcome {
					c.pending = append(c.pending, payload)
				} else {
					// Only reachable if this client's own Welcome write is
					// blocked for as long as it takes the room to produce 64
					// lifecycle messages, which means the connection is
					// already failing. Logged rather than grown without
					// bound, so one stalled joiner cannot be used to make the
					// relay allocate.
					log.Printf("relay: %s has not been welcomed after %d queued messages — dropping further ones until its Welcome completes", id, maxPendingBeforeWelcome)
				}
			}
			continue
		}

		targets = append(targets, target{id: id, conn: c.Conn})
	}
	r.mu.Unlock()

	for _, t := range targets {
		send := t.conn.Send
		if unreliable {
			send = t.conn.SendUnreliable
		}
		if err := send(payload); err != nil {
			log.Printf("relay: send to %s failed: %v", t.id, err)
		}
	}
}

// tryAdd adds c to the room. Test-only: production joins go through
// tryAddAndSnapshotRoster below, which combines the add with a roster
// snapshot under one critical section (see its own doc comment for why
// that combination matters). Kept as a smaller building block for tests
// that don't need the snapshot.
func (r *Room) tryAdd(c *Client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.members[c.PlayerID] = c
}

// tryAddAndSnapshotRoster adds c and returns the roster as it stood
// immediately before the add, all under one r.mu critical section.
// Combining these matters: two clients joining concurrently via separate
// roster() + tryAdd() calls could each snapshot the roster before either
// had actually added itself, so neither would ever learn about the other
// through its own Welcome or the resulting Join broadcast. With the roster
// cross-check core now does on receive (agent_docs/architecture.md's
// ADR), that isn't just a cosmetic gap anymore — it's a silently invisible
// peer, since a State for an unrostered id is dropped outright. Found in a
// review pass. Like tryAdd, capacity is already reserved server-wide by
// the caller, so this cannot fail.
// maxPendingBeforeWelcome bounds Client.pending. The window it covers is
// normally microseconds — the gap between a client being added to a room and
// its own Welcome being written — so this is a backstop against a stalled
// write, not a working queue depth.
const maxPendingBeforeWelcome = 64

// markWelcomedAndFlush ends the pre-Welcome hold for playerID: from here on
// Room.forward writes to it directly, and anything that arrived while it was
// held is delivered now, in the order it was produced.
//
// Must be called immediately after the client's Welcome has been written and
// before anything else is sent to it, so the ordering the protocol promises —
// Welcome first, then the room's traffic in order — holds on the wire and not
// merely in the code that produced it.
//
// Sends after releasing r.mu, matching Room.forward's own snapshot-then-send
// shape: a stalled joiner must not freeze the room it is joining.
func (r *Room) markWelcomedAndFlush(playerID string) {
	r.mu.Lock()
	c, ok := r.members[playerID]
	if !ok {
		r.mu.Unlock()
		return
	}
	c.holdUntilWelcome = false
	queued, conn := c.pending, c.Conn
	c.pending = nil
	r.mu.Unlock()

	if conn == nil {
		return
	}
	for _, payload := range queued {
		if err := conn.Send(payload); err != nil {
			log.Printf("relay: flushing queued message to %s failed: %v", playerID, err)
			return
		}
	}
}

func (r *Room) tryAddAndSnapshotRoster(c *Client) (rosterBeforeJoin []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rosterBeforeJoin = make([]string, 0, len(r.members))
	for id := range r.members {
		rosterBeforeJoin = append(rosterBeforeJoin, id)
	}
	r.members[c.PlayerID] = c
	return rosterBeforeJoin
}

func (r *Room) remove(playerID string) {
	r.mu.Lock()
	delete(r.members, playerID)
	remaining := make([]*Client, 0, len(r.members))
	for _, c := range r.members {
		remaining = append(remaining, c)
	}
	r.mu.Unlock()

	// Purge playerID's entry from every remaining member's own receive gate
	// (Client.forgetSender), after unlocking r.mu — never while holding it,
	// same reasoning as Forward's own snapshot-then-act shape: no other lock
	// is taken here, so there is no ordering to get wrong later.
	for _, c := range remaining {
		c.forgetSender(playerID)
	}
}

func (r *Room) size() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.members)
}

// roster returns every current member's player_id, in no particular order.
func (r *Room) roster() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	ids := make([]string, 0, len(r.members))
	for id := range r.members {
		ids = append(ids, id)
	}
	return ids
}

// stateRecipients returns which of the room's other members should receive
// a State from sender right now, applying each recipient's own
// maxReceiveHz cap (Client.allowStateFrom). Snapshots member pointers under
// r.mu and then consults each recipient's own gate after unlocking, so this
// never nests one lock inside the other and never does per-recipient work
// under the room lock — same reasoning as Forward's own snapshot-then-act
// shape. Recording the decision here rather than after a successful Send is
// deliberate: a Send failure means the recipient is gone or stalled, and
// re-crediting it a slot would be work for a connection that's already on
// its way out. Only ever called for state — join/leave/welcome/reject/pong
// go through roster(), a roster captured atomically with a membership
// change, or a direct recipient list instead, so they are never throttled (a
// throttled leave would strand a permanently frozen ghost).
func (r *Room) stateRecipients(sender string, now time.Time) []string {
	r.mu.Lock()
	members := make([]*Client, 0, len(r.members))
	for id, c := range r.members {
		if id != sender && !c.suspended {
			members = append(members, c)
		}
	}
	r.mu.Unlock()

	ids := make([]string, 0, len(members))
	for _, c := range members {
		if c.allowStateFrom(sender, now) {
			ids = append(ids, c.PlayerID)
		}
	}
	return ids
}

// Server accepts relay-protocol connections and dispatches them into Rooms
// keyed by room name. This is the running process behind
// cmd/meshghost-relay.
type Server struct {
	mu        sync.Mutex
	rooms     map[string]*Room
	idCounter uint64

	// suspended maps a resume token to the identity it reinstates, for
	// clients that dropped from a room whose feature set includes
	// protocol.FeatureResumeV1. Guarded by mu, same as rooms — session
	// bookkeeping is one small critical section, not worth its own lock. In
	// memory only: this survives a network blip, not a relay restart, which
	// is the honest boundary of an unpersisted identity (see online.go's
	// suspendedSession and agent_docs/beyond-cosmetic.md §5).
	suspended map[string]*suspendedSession

	// ResumeGrace overrides protocol.DefaultResumeGrace — how long a dropped
	// identity is held before the room is told it left. Zero means "use the
	// default", the same zero-means-default convention as HelloTimeout and
	// MaxClients. Exists so a test can use a window it can actually wait out.
	ResumeGrace time.Duration

	// Loopback is a dev-only Phase 3 flag (see agent_docs/phases/phase3.md):
	// when set, every State forwarded normally to the rest of a room is
	// additionally echoed back to its sender alone, with PlayerID rewritten
	// to "<id>-ghost". This exercises a real core->relay->core round trip
	// and real interpolation with only one physical client, without
	// core needing to change at all — storeRemoteState's existing
	// "ignore my own player_id" guard stays correct because the echoed
	// state carries a different id. Never set outside dev/testing; a real
	// second peer (Phase 4) makes this unnecessary and it must not ship on
	// by default.
	Loopback bool

	// HelloTimeout bounds how long an unauthenticated connection may sit
	// without completing a Hello and joining a room before the relay closes
	// it. Zero means "use DefaultHelloTimeout" (NewServer's default);
	// overridable per-Server the same way Loopback is, so tests can use a
	// short window instead of waiting out the real default.
	HelloTimeout time.Duration

	// RoomCode, when non-empty, is the shared secret every Hello.RoomCode
	// must match (constant-time comparison) before the relay accepts a
	// join. Empty (the default) means auth is off — the relay accepts any
	// Hello with a valid protocol version and matching game_id, the
	// pre-existing posture for a friend-hosted session. See the ADR in
	// agent_docs/architecture.md and docs/security.md for what this does
	// and doesn't defend against.
	RoomCode string

	// OnlyGame, when non-empty, restricts this relay to a single game: any
	// Hello whose game_id differs is refused at the handshake. Empty (the
	// default) means "host any game", the pre-existing posture. Distinct
	// from Room.GameID, which is per-room and sticky-on-first-join (one
	// relay can host an Emerald room and a TEVI room side by side) — this
	// is server-wide and declared up front by whoever's hosting, for a
	// dedicated single-game server. Compared by equality only, like every
	// other use of game_id. See the ADR in agent_docs/architecture.md.
	OnlyGame string

	// MaxClients bounds how many clients this relay accepts in total,
	// summed across every room it's hosting — not per room (see
	// DefaultMaxClients). Zero means "use DefaultMaxClients", the same
	// zero-means-default convention as HelloTimeout. Read fresh on every
	// join attempt (tryReserveSlot), so changing it mid-Serve takes effect
	// immediately rather than only for rooms created afterward.
	MaxClients int

	// IdleTimeout overrides transport.DefaultIdleTimeout for every
	// connection this relay accepts. Zero means "use transport's own
	// default" — same zero-means-default convention as HelloTimeout.
	// Exists for tests that need a short, waitable idle window rather than
	// the real 60s default; a real deployment should leave this unset.
	IdleTimeout time.Duration

	// SendHz is the room-wide state send rate this relay advertises to
	// every client in its Welcome, in updates per second. Zero means
	// protocol.DefaultSendHz; out-of-range values are clamped
	// (protocol.ClampSendHz) at the use site (resolveSendHz) rather than
	// refused, the same zero-means-default/resolve-late convention as
	// MaxClients and HelloTimeout. Prescriptive but not enforced: raising
	// this genuinely makes every ghost in every room on this relay update
	// more often (and costs every peer that much more bandwidth in both
	// directions), but nothing makes a client honor it — the only hard
	// limit is the flood cap, which scales from this value (see
	// maxMessagesPerSecond). See the ADR in agent_docs/architecture.md.
	SendHz int

	// Offers is what a QueryOnly Hello is answered with: the transports
	// this relay actually serves, and their ports. Set by
	// cmd/meshghost-relay from the listeners it created, because only the
	// caller knows what it bound — relay is handed net.Listeners
	// and deliberately cannot tell one transport from another, which is the
	// whole reason it needed no changes to gain two of them.
	//
	// Empty (the default, and what every test gets) means discovery answers
	// with an empty list, which a client treats exactly as it treats an
	// older relay: nothing to upgrade to, carry on where you are.
	Offers []protocol.TransportOffer

	// clientCount is the number of clients currently holding a reserved
	// slot, guarded by mu (the same lock already used for the rooms map,
	// rather than a separate one — server-wide join bookkeeping is a
	// single small critical section, not worth its own lock).
	clientCount int
}

// NewServer creates an empty Server with no rooms.
func NewServer() *Server {
	return &Server{rooms: make(map[string]*Room), HelloTimeout: DefaultHelloTimeout, MaxClients: DefaultMaxClients}
}

// transportOffers snapshots Offers under the lock. Returns a copy so a
// caller cannot retain a slice the server might later replace, and so the
// JSON encoder can never race a reconfiguration.
func (s *Server) transportOffers() []protocol.TransportOffer {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.Offers) == 0 {
		return nil
	}
	out := make([]protocol.TransportOffer, len(s.Offers))
	copy(out, s.Offers)
	return out
}

// tryReserveSlot reserves one of the server's MaxClients slots, atomically
// with the capacity check (unlike a separate count()-then-increment, which
// would race two simultaneous joins past the limit). ok is false if the
// relay was already at capacity across all rooms combined; the caller
// refuses the connection before it ever reaches a room. Every reserved
// slot must be matched by exactly one later releaseSlot call.
func (s *Server) tryReserveSlot() (ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	maxClients := s.MaxClients
	if maxClients <= 0 {
		maxClients = DefaultMaxClients
	}
	if s.clientCount >= maxClients {
		return false
	}
	s.clientCount++
	return true
}

// releaseSlot returns one previously reserved slot (see tryReserveSlot),
// called once a joined client disconnects.
func (s *Server) releaseSlot() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clientCount--
}

// resolveSendHz returns this relay's configured send rate, clamped through
// protocol.ClampSendHz (zero means "use protocol.DefaultSendHz", same
// zero-means-default convention as MaxClients).
func (s *Server) resolveSendHz() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return protocol.ClampSendHz(s.SendHz)
}

// Serve accepts connections on ln, handling each on its own goroutine,
// until Accept returns an error (typically because ln was closed).
func (s *Server) Serve(ln net.Listener) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go s.handleConn(conn)
	}
}

func envelope(t protocol.MessageType, payload any) (protocol.Envelope, error) {
	b, err := json.Marshal(payload)
	if err != nil {
		return protocol.Envelope{}, err
	}
	return protocol.Envelope{Type: t, Payload: b}, nil
}

func sendEnvelope(conn transport.Transport, t protocol.MessageType, payload any) {
	env, err := envelope(t, payload)
	if err != nil {
		log.Printf("relay: BUG: %s payload failed to marshal: %v", t, err)
		return
	}
	b, err := json.Marshal(env)
	if err != nil {
		log.Printf("relay: BUG: %s envelope failed to marshal: %v", t, err)
		return
	}
	if err := conn.Send(b); err != nil {
		log.Printf("relay: send %s failed: %v", t, err)
	}
}

// rejectAndClose sends a protocol.Reject with reason, logs the refusal for
// the relay operator's own visibility, then closes conn. Every pre-join
// refusal (bad protocol version, wrong room code, mismatched game_id/
// game_version, a full room) goes through this instead of a bare Close, so
// a client sees why it was refused instead of an anonymous hangup
// indistinguishable from "the relay is down" or "just slow" — see the ADR
// in agent_docs/architecture.md. The server-side log line is new alongside
// this same work: previously a rejected connection left no trace at all in
// the relay's own log, so a host had no way to tell "nobody's trying to
// connect" from "someone's trying and failing." One line per rejection —
// this only fires at handshake, never per state message, so it can't spam.
func rejectAndClose(conn transport.Transport, hello protocol.Hello, reason string) {
	log.Printf("relay: refused hello (%s): game_id=%q room=%q display_name=%q", reason, hello.GameID, hello.Room, hello.DisplayName)
	sendEnvelope(conn, protocol.TypeReject, protocol.Reject{Reason: reason})
	_ = conn.Close()
}

// roomKey is the key a room lives under in Server.rooms: its game_id AND its
// name, not the name alone.
//
// **This is what "partitioned by game_id" in the package comment actually
// means**, and until 2026-08-17 it was only half true — rooms were keyed by
// name, and a client whose game differed from the room's was refused with
// ReasonGameMismatch instead. Since `room` ships defaulted to "default" for
// every game, that made two different games on one server lock each other out
// by default: the first group in took "default", and everyone else got a
// mismatch with no hint that the fix was to invent a room name. The relay
// advertises itself as hosting any number of games at once, so the default
// configuration breaking exactly that was a bug, not a setting.
//
// Length-prefixed rather than joined with a separator: both halves come
// straight off the wire, and JSON can carry any byte in a string (including
// NUL), so a plain "a|b" join would let a crafted game_id land a client in
// another game's room. The length makes the split unambiguous whatever the
// contents.
func roomKey(gameID, name string) string {
	return fmt.Sprintf("%d:%s:%s", len(gameID), gameID, name)
}

// joinOrCreateRoom returns the named room FOR THIS GAME, creating it if it
// doesn't exist yet. Two games using the same room name get two separate
// rooms and never see each other. reason is empty on success; non-empty
// describes why the caller must refuse the connection rather than mix clients
// with incompatible capabilities or versions.
func (s *Server) joinOrCreateRoom(gameID, gameVersion, name string, features []string) (r *Room, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := roomKey(gameID, name)
	r, exists := s.rooms[key]
	if !exists {
		r = newRoom(gameID, gameVersion, name, features)
		r.key = key
		s.rooms[key] = r
		// Held against being swept until the caller has actually joined; see
		// Room.joining. Every path that returns a room does this, and every
		// caller must pair it with finishJoin.
		r.joining++
		return r, ""
	}
	// No game_id check: a room is now reached only through its own game's key,
	// so r.GameID == gameID by construction. protocol.ReasonGameMismatch is
	// consequently no longer reachable from here and is kept only for the wire
	// (an older relay still sends it, and a client must still understand it).
	// Feature stickiness, over the ROOM-SCOPED subset only. Unlike GameVersion
	// below, an EMPTY set on either side is a real value that must still
	// match: the hazard being closed is precisely "one client advertises
	// lease.v1 and claims properly while another doesn't and simply acts,"
	// where conflict resolution silently does not work and everything looks
	// fine until it doesn't (agent_docs/beyond-cosmetic.md §3). Treating empty
	// as "unknown, don't check" — the right call for a version string — would
	// leave exactly that case open.
	//
	// Client-scoped capabilities are excluded because no peer participates in
	// them, so there is nothing to disagree about: one client may resume its
	// session in a room where nobody else can, and the others cannot tell.
	// Compared as normalized joined strings, so the same capabilities in a
	// different order still match.
	if protocol.FeatureSetKey(r.features) != protocol.FeatureSetKey(protocol.RoomScopedFeatures(features)) {
		return nil, protocol.ReasonFeatureMismatch
	}
	// GameVersion is only compared once both sides have actually declared
	// one (protocol.Hello.GameVersion's doc comment) — an adapter that
	// doesn't report a version yet must not be refused, and a room's first
	// member sets the version other members are then compared against.
	if r.GameVersion != "" && gameVersion != "" && r.GameVersion != gameVersion {
		return nil, protocol.ReasonGameVersionMismatch
	}
	r.joining++
	return r, ""
}

// finishJoin releases the hold joinOrCreateRoom took, once the caller has
// either joined the room or given up on it. Every successful joinOrCreateRoom
// must be paired with exactly one of these -- handleConn does it with a defer,
// so every early return in the hello path is covered.
func (s *Server) finishJoin(r *Room) {
	s.mu.Lock()
	if r.joining > 0 {
		r.joining--
	}
	s.mu.Unlock()
	// A room held only by this pending join, whose joiner then gave up (a
	// refused slot, a failed resume), would otherwise sit in the table empty
	// forever -- dropIfEmpty declined to sweep it precisely because of the hold.
	s.dropIfEmpty(r)
}

// dropIfEmpty removes r from the room table if it currently has no
// members, so abandoned rooms don't accumulate for the life of the server.
func (s *Server) dropIfEmpty(r *Room) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// joining > 0 means a client has been handed this room and is about to add
	// itself; sweeping now would strand it somewhere unreachable.
	if r.size() == 0 && r.joining == 0 {
		// Keyed by r.key, not r.Name: two games can hold a room of the same
		// name, and deleting by name would evict the wrong one.
		if cur, ok := s.rooms[r.key]; ok && cur == r {
			delete(s.rooms, r.key)
		}
	}
}

func (s *Server) nextPlayerID() string {
	n := atomic.AddUint64(&s.idCounter, 1)
	return fmt.Sprintf("p%d", n)
}

// handleConn drives one client connection for its whole lifetime: waiting
// for the opening Hello, joining a Room, forwarding State messages to the
// rest of the room, and cleaning up on disconnect.
// transportName labels a connection for logging without relay
// having to import any transport package: netx/udpconn and
// netx/quicconn each implement TransportName, and anything else
// (a real TCP conn, a net.Pipe in tests) is tcp-shaped by definition. Same
// structural-interface approach transport uses for its unreliable
// write path, and it keeps this package's import list unchanged.
func transportName(conn net.Conn) string {
	if n, ok := conn.(interface{ TransportName() string }); ok {
		return n.TransportName()
	}
	return "tcp"
}

func (s *Server) handleConn(conn net.Conn) {
	// MaxLineBytes is the relay's own, tighter limit rather than
	// transport's generous package default — via FromConnWithLimits, not a
	// post-construction field set, so it's in effect before the read
	// loop's first Scan (found as a real, if narrow, race in a review
	// pass: transport.FromConn already starts that goroutine before
	// returning). IdleTimeout is normally left at 0 ("use transport's own
	// default", DefaultIdleTimeout) — s.IdleTimeout exists so a test can
	// shrink it to something waitable, e.g. proving Core's heartbeat
	// (core's sendHeartbeats) actually keeps an otherwise-quiet
	// connection alive past it. 0 for write timeout: the relay has no need
	// for a different value there.
	nd := transport.FromConnWithLimits(conn, protocol.MaxLineBytes, s.IdleTimeout, 0)

	var (
		mu       sync.Mutex
		room     *Room
		playerID string

		// client is this connection's entry in room.members, and resumeToken
		// is the single-use secret that would let it reclaim playerID after
		// an unexpected drop (empty for a room without
		// protocol.FeatureResumeV1, which is every room that hasn't opted
		// in). Both are read by OnDisconnect to decide whether the drop is a
		// real leave or a suspension, so both live under mu with room and
		// playerID rather than in the OnReceive-only group below.
		client      *Client
		resumeToken string

		// rateWindow/rateCount need no mutex of their own, unlike mu above
		// (which helloTimer's separate AfterFunc goroutine also touches):
		// both are only ever read or written from inside the OnReceive
		// callback below, which transport's readLoop calls serially, one
		// goroutine per connection. A rateMu sync.Mutex guarding them was
		// removed in a review pass as genuinely unnecessary, not just
		// redundant defense-in-depth.
		rateWindow time.Time
		rateCount  int

		// loopbackGhostSent tracks whether this connection has already been
		// sent a Join for its own synthetic "<id>-ghost" — needed once
		// s.Loopback's roster-trust fix below is added. No mutex needed, same
		// reasoning as rateWindow/rateCount above (OnReceive is single-
		// goroutine per connection).
		loopbackGhostSent bool
	)

	// Resolved once, here, rather than per message: the enforced cap must
	// match what this connection's own Welcome advertises, and re-reading
	// s.SendHz mid-session would let the relay enforce a limit it never told
	// this client about. Same no-mutex reasoning as rateWindow/rateCount —
	// computed before OnReceive is registered, read only from inside it. See
	// the ADR in agent_docs/architecture.md.
	sendHz := s.resolveSendHz()
	msgLimit := maxMessagesPerSecond(sendHz)

	// HelloTimeout: a connection that never completes a Hello and joins a
	// room is closed after this long, rather than held open indefinitely.
	// transport's own IdleTimeout doesn't cover this on its own — it resets
	// on *any* successfully read line, so a connection could stay under the
	// idle timeout forever by sending pings without ever joining. Found
	// while scoping relay-safety hardening, agent_docs/architecture.md's
	// room-code/version ADR.
	helloTimeout := s.HelloTimeout
	if helloTimeout <= 0 {
		helloTimeout = DefaultHelloTimeout
	}
	helloTimer := time.AfterFunc(helloTimeout, func() {
		mu.Lock()
		stillWaiting := room == nil
		mu.Unlock()
		if stillWaiting {
			log.Printf("relay: connection did not complete hello within %s, closing", helloTimeout)
			_ = nd.Close()
		}
	})

	nd.OnError(func(err error) {
		log.Printf("relay: connection error: %v", err)
	})

	nd.OnDisconnect(func(err error) {
		helloTimer.Stop()
		mu.Lock()
		r, id, c, token := room, playerID, client, resumeToken
		mu.Unlock()
		if r == nil {
			return
		}

		if token != "" && c != nil {
			// This room does resumption. Park the identity rather than
			// announcing a leave — but only if this connection is still the
			// live one for id. A resumed session installs a NEW Client under
			// the same player_id, so a late OnDisconnect from the superseded
			// connection must do nothing at all; suspending on it would
			// silently mute the connection that just took over. Same
			// stale-callback hazard core's relayOwner exists for.
			r.mu.Lock()
			stillOurs := r.members[id] == c
			r.mu.Unlock()
			if stillOurs {
				s.suspend(r, c, token)
			}
			return
		}

		s.finishLeave(r, id)
	})

	nd.OnReceive(func(payload []byte) {
		// MaxLineBytes is now enforced by transport.go during the read
		// itself (nd.MaxLineBytes, set above), so an oversized line never
		// reaches this callback at all — the connection is already closed.
		//
		// MaxMessagesPerSecond still guards against a flood of
		// legitimately-sized messages, which line-length enforcement can't
		// catch. Closes the connection outright rather than silently
		// dropping the offending messages: a client flooding the relay
		// isn't behaving as this project's own adapters do, and there's
		// nothing to gain from staying connected to find out why.
		now := time.Now()
		if now.Sub(rateWindow) >= time.Second {
			rateWindow = now
			rateCount = 0
		}
		rateCount++
		if rateCount > msgLimit {
			// A Reject before the close, not a bare hangup — same posture as
			// rejectAndClose's handshake refusals, applied here for the first
			// time to an already-joined connection. ReasonRateLimited is
			// classified retryable by core.isPermanentRejectReason: a
			// reconnecting client re-reads this room's advertised send_hz
			// from the new Welcome and may well fit under the cap the second
			// time. See the ADR in agent_docs/architecture.md.
			log.Printf("relay: client exceeded %d messages/second, rejecting and closing connection", msgLimit)
			sendEnvelope(nd, protocol.TypeReject, protocol.Reject{Reason: protocol.ReasonRateLimited})
			_ = nd.Close()
			return
		}

		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			// Malformed line from a client that isn't speaking the
			// protocol at all; nothing useful to do but drop it.
			return
		}

		mu.Lock()
		r, id := room, playerID
		mu.Unlock()

		if r == nil {
			// Only a Hello is accepted before the connection has joined a
			// room; anything else this early is ignored.
			if env.Type != protocol.TypeHello {
				return
			}
			var hello protocol.Hello
			if err := json.Unmarshal(env.Payload, &hello); err != nil {
				return
			}
			// Every Hello string field was previously unbounded — found
			// while auditing for malicious-peer hardening alongside
			// room-code auth. Checked first, before anything else
			// (including the version check below), and logged without the
			// raw field values: an oversized field is exactly the case
			// rejectAndClose's normal logging (which prints the field
			// contents) would defeat the point of bounding, writing
			// unbounded attacker-controlled bytes into the relay's own log
			// on every attempt. Found in a review pass.
			if len(hello.GameID) > MaxHelloFieldLen || len(hello.Room) > MaxHelloFieldLen ||
				len(hello.DisplayName) > MaxHelloFieldLen || len(hello.RoomCode) > MaxHelloFieldLen ||
				len(hello.GameVersion) > MaxHelloFieldLen ||
				len(hello.ResumeToken) > protocol.MaxResumeTokenLen ||
				!protocol.ValidateFeatures(hello.Features) {
				log.Printf("relay: refused hello (%s): a field exceeded %d bytes", protocol.ReasonHelloFieldTooLong, MaxHelloFieldLen)
				sendEnvelope(nd, protocol.TypeReject, protocol.Reject{Reason: protocol.ReasonHelloFieldTooLong})
				_ = nd.Close()
				return
			}
			// Versioning rule (agent_docs/contract.md): a mismatched major
			// version is refused outright, not guessed at. Every hello
			// field is now known to be <= MaxHelloFieldLen (checked
			// above), so rejectAndClose's logging below is bounded too.
			if hello.ProtocolVersion != protocol.Version {
				rejectAndClose(nd, hello, protocol.ReasonProtocolVersionMismatch)
				return
			}
			// Room-code auth (agent_docs/architecture.md's ADR): checked
			// before touching the room table at all, same "reject at
			// handshake, before any state flows" shape as the version and
			// game_id checks. subtle.ConstantTimeCompare so a wrong guess
			// can't be timed byte-by-byte; an empty configured s.RoomCode
			// means auth is off (the pre-existing no-auth posture).
			if s.RoomCode != "" {
				given := []byte(hello.RoomCode)
				want := []byte(s.RoomCode)
				if len(given) != len(want) || subtle.ConstantTimeCompare(given, want) != 1 {
					rejectAndClose(nd, hello, protocol.ReasonInvalidRoomCode)
					return
				}
			}
			// Transport discovery. Placed deliberately AFTER the field-length,
			// protocol-version and room-code checks above and BEFORE the room
			// table is touched: a caller learns nothing here it could not have
			// learned by simply joining, so this adds no pre-auth surface —
			// which is the property that made an explicit query preferable to
			// having clients join over tcp and then reconnect. No room is
			// joined, no player_id assigned, no slot reserved, and nobody in
			// any room is told anything. See the transport discovery ADR in
			// agent_docs/architecture.md.
			if hello.QueryOnly {
				sendEnvelope(nd, protocol.TypeTransports, protocol.Transports{Offers: s.transportOffers()})
				_ = nd.Close()
				return
			}

			// Single-game relay (agent_docs/architecture.md's ADR): checked
			// here, after the field-length bound (so the game_id
			// rejectAndClose logs is <= MaxHelloFieldLen) and before the
			// room table is touched or a slot reserved, same "reject at
			// handshake, before any state flows" shape as the checks above.
			// An empty s.OnlyGame means the relay hosts any game, the
			// pre-existing posture.
			if s.OnlyGame != "" && hello.GameID != s.OnlyGame {
				rejectAndClose(nd, hello, protocol.ReasonGameNotAllowed)
				return
			}
			joined, reason := s.joinOrCreateRoom(hello.GameID, hello.GameVersion, hello.Room, hello.Features)
			if reason != "" {
				rejectAndClose(nd, hello, reason)
				return
			}
			// Releases the hold joinOrCreateRoom took (Room.joining), whichever
			// way this callback returns -- joined, refused for a full server, or
			// resumed. A defer rather than a call per exit precisely because
			// there are several exits and missing one would pin a room in the
			// table for the life of the process.
			defer s.finishJoin(joined)

			// Session resumption, before a slot is reserved or an id
			// assigned: a resuming client's slot was never released and its
			// player_id already exists, so both of those steps would be
			// wrong. A token that is unknown, expired, or for another room
			// simply yields nil here and the client joins fresh — being away
			// slightly too long must degrade to "you get a new identity", not
			// to "you cannot play".
			if protocol.HasFeature(hello.Features, protocol.FeatureResumeV1) && hello.ResumeToken != "" {
				if sess := s.takeSession(hello.ResumeToken, hello.Room, hello.GameID); sess != nil && sess.room == joined {
					if resumedClient, newToken, ok := s.resumeInto(nd, transportName(conn), joined, sess, hello, sendHz); ok {
						mu.Lock()
						room, playerID, client, resumeToken = joined, sess.playerID, resumedClient, newToken
						mu.Unlock()
						helloTimer.Stop()
						return
					}
				}
			}

			if !s.tryReserveSlot() {
				// Relay already at MaxClients across every room combined
				// (agent_docs/contract.md Limits) — refuse the same way a
				// game_id mismatch is refused, rather than letting total
				// connections grow unbounded. dropIfEmpty cleans up if
				// joinOrCreateRoom just created this room for this attempt.
				rejectAndClose(nd, hello, protocol.ReasonServerFull)
				s.dropIfEmpty(joined)
				return
			}

			newID := s.nextPlayerID()
			newClient := &Client{
				PlayerID:     newID,
				Conn:         nd,
				maxReceiveHz: protocol.ClampReceiveHz(hello.MaxReceiveHz),
				transport:    transportName(conn),
				features:     protocol.NormalizeFeatures(hello.Features),
				// Set BEFORE the add below, so there is no instant at which
				// this client is reachable by Room.forward without the hold
				// in place. Cleared by markWelcomedAndFlush once its Welcome
				// has been written — see Client.holdUntilWelcome.
				holdUntilWelcome: true,
			}
			rosterBeforeJoin := joined.tryAddAndSnapshotRoster(newClient)

			// A resume token is minted only for a room that asked for
			// resumption, so nothing is issued — and no identity is ever held
			// past a disconnect — for the cosmetic case. A minting failure
			// (crypto/rand unavailable, which does not happen on any
			// supported platform) degrades to a session that simply cannot
			// resume, rather than a refused join.
			newToken := ""
			if newClient.wants(protocol.FeatureResumeV1) {
				var err error
				if newToken, err = newResumeToken(); err != nil {
					log.Printf("relay: could not mint a resume token for %s: %v — this session will not be resumable", newID, err)
					newToken = ""
				}
			}

			// Registered now, while the connection is healthy — not on
			// disconnect. See suspendedSession: registering late is what made a
			// resume only work when the relay had already noticed the drop.
			s.registerSession(joined, newID, newToken, "")

			mu.Lock()
			room, playerID, client, resumeToken = joined, newID, newClient, newToken
			mu.Unlock()
			helloTimer.Stop()

			// Join/leave are lifecycle events, not per-frame state, so one
			// line per occurrence can't spam — previously the relay's own
			// log recorded nothing at all for a connect/join, only its own
			// startup line, leaving a host with no way to tell "nobody's
			// connecting" from "someone's connecting and I can't see it."
			log.Printf("relay: %s (%q) joined room %q as game %q over %s",
				newID, hello.DisplayName, hello.Room, hello.GameID, transportName(conn))

			sendEnvelope(nd, protocol.TypeWelcome, protocol.Welcome{
				PlayerID: newID,
				Roster:   rosterBeforeJoin,
				SendHz:   sendHz,
				// The room's agreed set PLUS whatever client-scoped
				// capabilities this particular client asked for and got — so
				// what a client reads back is what is actually in force for
				// it, not a room-wide answer to a per-client question.
				Features:     effectiveFeatures(joined, newClient),
				ResumeToken:  newToken,
				ServerTimeMs: time.Now().UnixMilli(),
			})

			// Welcome is on the wire, so this client may now be written to
			// directly — and anything the room produced while it was being
			// added is delivered here, still ahead of the seeding below.
			// See Client.welcomed for the race this closes.
			joined.markWelcomedAndFlush(newID)

			// Seed the newcomer with what everyone else looks like right now,
			// and with the room's world, so both appear immediately instead
			// of only on their next update. Sent after Welcome — the client's
			// roster comes from Welcome, and it drops state for any id it has
			// not been told about (the roster-trust rule) — and only to this
			// connection, since nobody else needs it.
			joined.joinSnapshot(newID)

			join, err := envelope(protocol.TypeJoin, protocol.Join{PlayerID: newID})
			if err == nil {
				// rosterBeforeJoin, NOT allExcept(newID): the recipient set must be
				// the one captured atomically with the add above, not whoever happens
				// to be a member by the time this line runs.
				//
				// Caught by CI's race job 2026-08-16 as an intermittent
				// TestOversizedPositionDropped failure ("c2 unexpectedly received
				// join"). allExcept re-took the lock, so a client that joined in the
				// window between this client's add and this broadcast was included --
				// and it had already been told about this client in its OWN welcome
				// roster. It therefore got a duplicate, late join for a player it
				// already knew about. The window is normally microseconds, which is
				// why 300 local runs never reproduced it and the race detector's much
				// slower scheduling did.
				joined.Forward(join, rosterBeforeJoin)
			}
			return
		}

		switch env.Type {
		case protocol.TypeState:
			var st protocol.State
			if err := json.Unmarshal(env.Payload, &st); err != nil {
				return
			}
			// Size/length/finiteness limits (agent_docs/contract.md) — drop
			// rather than truncate, so a client sees silence instead of a
			// half-forwarded, confusing state. protocol.ValidateState is
			// shared with core so both enforcement points can't
			// silently drift apart.
			if !protocol.ValidateState(st) {
				return
			}
			// player_id is stamped server-side from the connection's own
			// assigned id, never trusted from the payload — a peer could
			// otherwise claim someone else's id. Cheap now; Phase 4 puts
			// untrusted peers on the wire.
			st.PlayerID = id
			stateEnv, err := envelope(protocol.TypeState, st)
			if err != nil {
				return
			}
			// Remembered before forwarding, and independent of the
			// per-recipient rate gate below: a late joiner should be seeded
			// with the newest sample, not the newest one that happened to be
			// forwarded to somebody. No-op unless the room asked for
			// snapshots.
			r.recordState(id, st)
			r.ForwardUnreliable(stateEnv, r.stateRecipients(id, time.Now()))

			if s.Loopback {
				// Dev-only Phase 3 loopback (agent_docs/phases/phase3.md):
				// echo the same state back to the sender alone, under a
				// synthetic ghost id, so a lone client exercises a real
				// core->relay->core round trip. See the Server.Loopback
				// doc comment.
				ghostID := id + "-ghost"

				if !loopbackGhostSent {
					// Found live 2026-08-14: the 2026-08-14 roster-trust
					// hardening ADR (agent_docs/architecture.md) made
					// core.storeRemoteState drop any State for a
					// player_id it never saw announced via Welcome/Join —
					// correct against a real relay, but this synthetic
					// ghost id was never joined at all, so every echoed
					// state was silently dropped and no ghost ever spawned
					// in loopback mode. Nobody re-tested loopback after that
					// hardening landed until now. Fix: announce a one-time
					// Join for the ghost id, sent only to this connection
					// (not broadcast — no other real peer should ever learn
					// about another client's own loopback ghost), before
					// the first echoed state.
					if join, err := envelope(protocol.TypeJoin, protocol.Join{PlayerID: ghostID}); err == nil {
						r.Forward(join, []string{id})
					}
					loopbackGhostSent = true
				}

				ghost := st
				ghost.PlayerID = ghostID
				ghostEnv, err := envelope(protocol.TypeState, ghost)
				if err == nil {
					// State, so unreliable like any other — the loopback
					// ghost's own Join above stays reliable, since losing
					// that would leave every echoed state dropped by
					// core.storeRemoteState's roster check.
					r.ForwardUnreliable(ghostEnv, []string{id})
				}
			}
		case protocol.TypeEvent:
			// Gated on the room's agreed feature set, which is how every
			// deeper capability stays adapter-opt-in rather than
			// relay-imposed: a room that never asked for events never runs
			// this path, and the relay needs no per-game table and no
			// game_id branch to arrange that.
			if !r.hasFeature(protocol.FeatureEventV1) {
				return
			}
			var ev protocol.Event
			if err := json.Unmarshal(env.Payload, &ev); err != nil {
				return
			}
			if !protocol.ValidateEvent(ev) {
				// Dropped, not truncated and not fragmented — an oversized
				// event means the payload should have been a reference to
				// the data rather than the data.
				return
			}
			r.handleEvent(id, ev)
		case protocol.TypeLease:
			if !r.hasFeature(protocol.FeatureLeaseV1) {
				return
			}
			var req protocol.Lease
			if err := json.Unmarshal(env.Payload, &req); err != nil {
				return
			}
			if !protocol.ValidateLease(req) {
				return
			}
			r.handleLease(id, req)
		case protocol.TypeEscrow:
			if !r.hasFeature(protocol.FeatureEscrowV1) {
				return
			}
			var req protocol.Escrow
			if err := json.Unmarshal(env.Payload, &req); err != nil {
				return
			}
			if !protocol.ValidateEscrow(req) {
				return
			}
			r.handleEscrow(id, req)
		case protocol.TypeWorld:
			if !r.hasFeature(protocol.FeatureWorldV1) {
				return
			}
			if !r.hasFeature(protocol.FeatureLeaseV1) {
				// world.v1 without lease.v1 is an incoherent combination: every
				// write names an authority lease key, and a room with no leases
				// has none, so every write would be denied. Said once, in words,
				// rather than silently — a host staring at a world that never
				// appears has no other way to find this out.
				r.worldWithoutLeaseOnce.Do(func() {
					log.Printf("relay: room %q negotiated world.v1 without lease.v1 -- every world write "+
						"will be denied, because a write is only accepted from the holder of the lease "+
						"it names and this room has no leases", r.Name)
				})
				return
			}
			var req protocol.World
			if err := json.Unmarshal(env.Payload, &req); err != nil {
				return
			}
			if !protocol.ValidateWorld(req) {
				// Dropped, not truncated and not fragmented — the same answer an
				// oversized event gets, for the same reason.
				return
			}
			r.handleWorld(id, req)
		case protocol.TypeLeave:
			// A voluntary goodbye (protocol.Leave): this client is going on
			// purpose, so its identity must NOT be held for a reconnect.
			// Clearing the token is what makes OnDisconnect below take the
			// finishLeave path instead of suspending — the room hears a real
			// leave immediately, which is what a player who just quit should
			// look like to everyone else.
			//
			// The payload is not read at all: player_id would be the client's
			// own claim, and the connection already knows whose it is.
			mu.Lock()
			resumeToken = ""
			mu.Unlock()
			s.forgetSessionsOf(r, id)
			_ = nd.Close()
			return
		case protocol.TypePing:
			var ping protocol.Ping
			if err := json.Unmarshal(env.Payload, &ping); err != nil {
				return
			}
			// ServerTimeMs is stamped as late as possible — right here, not
			// at the top of the callback — so the client's offset estimate
			// measures the network rather than this relay's own queueing.
			sendEnvelope(nd, protocol.TypePong, protocol.Pong{
				Nonce:        ping.Nonce,
				ServerTimeMs: time.Now().UnixMilli(),
			})
		default:
			// Unknown/unhandled types (a hello after already joining, a
			// message type from a newer client) are ignored, not treated as
			// an error — the same forward-compatibility posture as unknown
			// fields.
		}
	})
}
