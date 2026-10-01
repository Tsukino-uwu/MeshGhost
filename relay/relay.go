// Package relay is the game-agnostic server: it forwards protocol.State messages between clients in a room,
// partitioned by game_id, and never runs or touches a game. It also arbitrates the planes past cosmetic (addressed
// events, a room sequencer, leases, escrow, world custody and session resumption), which all stay dumb: every key,
// id and payload is opaque, and none of it runs for a room that did not opt in. It never imports core or bridge.
//
// The Go package APIs follow module semver, but what 1.0 marks is the wire protocol: third-party use of these
// packages is untested, so pin a version, and running the shipped meshghost-server binary is the tested route.
package relay

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/throttle"
	"github.com/Tsukino-uwu/MeshGhost/pake"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// Room holds the connected clients for one room name. A Hello whose game_id, or declared game_version, does not
// match the room's is rejected rather than mixing games.
type Room struct {
	GameID      string
	GameVersion string
	Name        string

	// joining counts clients handed this room by joinOrCreateRoom that have not added themselves yet: without it,
	// dropIfEmpty could remove the room in that window and the joiner would add itself to a room nobody can reach.
	// Guarded by Server.mu, not Room.mu, because dropIfEmpty reads it there.
	joining int

	// key is this room's identity in Server.rooms (see roomKey), stored so nothing deletes by name alone.
	key string

	// features is this room's agreed room-scoped capability set, sticky from its first member's Hello; a joiner whose
	// set differs is refused. Client-scoped capabilities concern one client and the relay, so they live on Client.
	// Written once in newRoom before the room is published, so it needs no lock.
	features []string

	// sendMu serializes the control plane (events, lease and escrow changes, the leave that ends a session) from its
	// stamp until it is written to every recipient, or two events stamped 1 and 2 can race to the socket out of
	// order. Lock order is always sendMu then mu. The state plane, lossy and latest-wins, does not take it.
	sendMu sync.Mutex

	mu      sync.Mutex
	members map[string]*Client
	// memberCount is len(members), maintained under mu by putMemberLocked and deleteMemberLocked and readable
	// without it, so dropIfEmpty, under Server.mu, never takes r.mu. Nothing else may read it in place of len(members).
	memberCount atomic.Int64

	// Everything below is guarded by mu.

	// seqCounter is this room's sequencer: one total order over events and lease and escrow changes.
	seqCounter uint64
	// leases maps an opaque key to its current holder. nil until first use.
	leases map[string]*lease
	// leasesBy is how many keys each member holds, so leaseTableFullLocked bounds one member without a scan;
	// maintained at the grant and the free in leases.go.
	leasesBy map[string]int
	// escrows maps an opaque exchange id to its record, retained terminal ones included; bounded by
	// maxEscrowRecordsPerRoom.
	escrows map[string]*escrow
	// escrowsLive and escrowsLiveBy count live exchanges, in total and per opener, so escrowTableFullLocked is O(1);
	// maintained at the two transitions in escrow.go.
	escrowsLive   int
	escrowsLiveBy map[string]int
	// missedEvents is each suspended member's backlog of stamped events, replayed by resumeSnapshot: the event plane
	// is reliable, and an addressed event leaves no seq gap a returning client could notice. nil until needed.
	missedEvents map[string][]protocol.Event
	// lastState is each member's most recent valid state, recorded in every room to seed late joiners; it also gives
	// the fan-out counters each member's area.
	lastState map[string]protocol.State
	// world is this room's custody map: the latest opaque blob per entity, namespaced by the authority lease it was
	// written under. It outlives the lease and its writer by design (see freeLeaseLocked).
	world map[worldKey]*worldEntry

	// Cross-area fan-out counters, read by snapshot(): what was sent after filtering (Out, BytesForwarded), what went
	// to a recipient in another area, the ceiling a filter could reach (Cross, BytesCrossArea), and what the filter
	// suppressed (Filtered, BytesFiltered). Forwarded+Filtered is the pre-filter total both shares divide by. A
	// recipient counts as elsewhere only when both areas are known and differ.
	statesIn                uint64
	stateRecipientsOut      uint64
	stateRecipientsCross    uint64
	stateRecipientsFiltered uint64
	stateBytesForwarded     uint64
	stateBytesCrossArea     uint64
	stateBytesFiltered      uint64

	// Once-per-room log lines that would otherwise repeat at a plane's message rate. Not under mu: one fires from a
	// path that already holds it. worldWithoutLeaseOnce reports world.v1 without lease.v1, logged rather than refused,
	// since making one feature imply the other would change the sticky FeatureSetKey of rooms that already agreed.
	worldWithoutLeaseOnce   sync.Once
	worldLossyCreateOnce    sync.Once
	snapshotTruncatedOnce   sync.Once
	missedEventsDroppedOnce sync.Once
	worldUnknownOpOnce      sync.Once
}

// Client is one connected relay peer.
type Client struct {
	PlayerID string
	Conn     transport.Transport

	// maxReceiveHz is this client's requested per-peer receive cap, already clamped; 0 is uncapped. Written once
	// before the Client is published into Room.members, like transport, nametag and features, so it needs no lock.
	maxReceiveHz int

	// transport is which transport this client arrived over, for logging only: a room may mix them, and a host
	// chasing a stuttering ghost needs to know which.
	transport string

	// nametag is this client's label as other players see it, sanitized once here at the edge so no path can forward
	// or log the raw name. nil means no nametag is drawn.
	nametag *protocol.Nametag

	// features is this client's full capability set, kept for its client-scoped half (resume.v1, snapshot.v1), which
	// may differ between members of one room.
	features []string

	// ownAreaOnly mirrors Hello.OwnAreaOnly: the relay may drop states from other areas, which this client's core
	// would discard; absent means forward everything. Guarded by Room.mu, since protocol.TypePrefs changes it once
	// the adapter attaches.
	ownAreaOnly bool

	// lastArea is this client's last reported area_id, cached so the filter reads it once per member per message
	// without copying a State out of Room.lastState; seeded on join and resume. Guarded by Room.mu.
	lastArea string

	// lastArrivalSeed is when this client last got an arrival seed: a seed is an N-way fan-out driven by one
	// client's area changes, so it is throttled by arrivalSeedInterval. Guarded by Room.mu.
	lastArrivalSeed time.Time

	// out is this client's outbound queue and writer, so a peer that stopped draining blocks only itself. Never
	// reassigned; nil only for Clients that tests build directly, which write inline.
	out *outbox

	// suspended marks a client whose connection dropped but whose identity is held for a resume: it stays in the
	// roster, and Room.forward writes nothing to it. Guarded by Room.mu.
	suspended bool

	// holdUntilWelcome reports that this client's Welcome is not written yet, so pending holds what the room sends it
	// until then. The client joins Room.members before its Welcome, which carries the roster captured with the add, so
	// another goroutine's Leave could otherwise reach the socket first; skipping instead would lose a Leave the
	// newcomer's roster still lists. A hold, so the zero value delivers normally. Guarded by Room.mu.
	holdUntilWelcome bool
	pending          [][]byte
	// pendingUnreliable[i] says whether pending[i] is a state sample, so forwardLine's overflow drops the class the
	// outbox drops.
	pendingUnreliable []bool
	// pendingDropLogged latches the "dropping further ones" line to once per client. Guarded by Room.mu.
	pendingDropLogged bool

	// gateMu guards lastStateTo, when a State from each sender was last forwarded to this client. Every sender's
	// OnReceive goroutine writes it, so unlike handleConn's per-connection state it needs a lock.
	gateMu      sync.Mutex
	lastStateTo map[string]time.Time
}

// allowStateFrom reports whether a State from sender may be forwarded to c now under c's maxReceiveHz, and records it
// if so, before any Send, since a failed Send means a recipient already leaving. A minimum-interval gate, so the rate
// is quantized to senderHz/ceil(senderHz/capHz); excess samples are dropped, never queued. Uncapped takes no lock.
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

// forgetSender purges sender from c's receive gate when sender leaves: player_ids are never reused, so entries would
// otherwise accumulate.
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

// Forward routes msg reliably to the given recipients.
func (r *Room) Forward(msg protocol.Envelope, to []string) {
	r.forward(msg, to, false)
}

// ForwardUnreliable is Forward for the lossy, latest-wins state plane: on a datagram transport it skips
// retransmission, so a lost sample is superseded rather than arriving stale. A separate method, not a flag, so a
// caller that forgets which it wanted gets the reliable one.
func (r *Room) ForwardUnreliable(msg protocol.Envelope, to []string) {
	r.forward(msg, to, true)
}

func (r *Room) forward(msg protocol.Envelope, to []string, unreliable bool) {
	payload, err := json.Marshal(msg)
	if err != nil {
		// Envelope always marshals; nothing here builds one with an unmarshalable payload.
		log.Printf("relay: BUG: envelope failed to marshal: %v", err)
		return
	}
	r.forwardLine(payload, to, unreliable)
}

// forwardLine is forward once the wire bytes exist; the state plane builds its line with protocol.AppendEnvelope and
// comes in here. payload is retained for a client still waiting on its Welcome, so a caller may not reuse it.
func (r *Room) forwardLine(payload []byte, to []string, unreliable bool) {
	// Targets are taken under the lock and sent to after releasing it, so a stalled member cannot freeze the room.
	type target struct {
		id   string
		conn transport.Transport
		out  *outbox
	}
	r.mu.Lock()
	targets := make([]target, 0, len(to))
	for _, id := range to {
		// A suspended member has no connection: skipped silently, not logged per message for the whole grace window.
		c, ok := r.members[id]
		if !ok || c.suspended || c.Conn == nil {
			continue
		}

		// Held until its Welcome is written, state included: in a room without snapshot.v1 a dropped sample leaves its
		// sender invisible until it speaks again.
		if c.holdUntilWelcome {
			// The outbox's two-class policy: a dropped state is harmless, a dropped join or leave leaves a peer
			// invisible for the session. A large room alone can fill this during one Welcome write.
			if len(c.pending) >= maxPendingBeforeWelcome {
				drop := -1
				for i, u := range c.pendingUnreliable {
					if u {
						drop = i
						break
					}
				}
				switch {
				case drop >= 0:
					c.pending = append(c.pending[:drop], c.pending[drop+1:]...)
					c.pendingUnreliable = append(c.pendingUnreliable[:drop], c.pendingUnreliable[drop+1:]...)
				case unreliable:
					// Every held line is a lifecycle line, so this sample yields, as in the outbox.
					continue
				default:
					// A connection genuinely failing; logged once per client, since this runs in the fan-out loop.
					if !c.pendingDropLogged {
						c.pendingDropLogged = true
						log.Printf("relay: %s has not been welcomed after %d queued lifecycle messages -- "+
							"dropping further ones until its Welcome completes", id, maxPendingBeforeWelcome)
					}
					continue
				}
			}
			c.pending = append(c.pending, payload)
			c.pendingUnreliable = append(c.pendingUnreliable, unreliable)
			continue
		}

		targets = append(targets, target{id: id, conn: c.Conn, out: c.out})
	}
	r.mu.Unlock()

	for _, t := range targets {
		// Handed to the client's own writer, so a peer that stopped draining cannot starve the rest or the sender.
		if t.out != nil {
			if !t.out.enqueue(outMsg{line: payload, unreliable: unreliable}) {
				// A reliable line at a full queue: this peer is not reading. Closed here, so its OnDisconnect drives
				// the normal leave path and the client retries.
				log.Printf("relay: %s is not draining its connection (%d messages queued) — disconnecting it",
					t.id, maxOutboxLines)
				_ = t.conn.Close()
			}
			continue
		}
		// No writer: a Client built directly by a test, written inline.
		var err error
		if unreliable {
			err = t.conn.SendUnreliable(payload)
		} else {
			err = t.conn.Send(payload)
		}
		if err != nil {
			log.Printf("relay: send to %s failed: %v", t.id, err)
		}
	}
}

// putMemberLocked and deleteMemberLocked are the only writers of r.members, so r.memberCount cannot drift; a
// replacement (a resume reusing an id) moves neither. Caller holds r.mu.
func (r *Room) putMemberLocked(c *Client) {
	if _, existed := r.members[c.PlayerID]; !existed {
		r.memberCount.Add(1)
	}
	r.members[c.PlayerID] = c
}

func (r *Room) deleteMemberLocked(id string) {
	if _, existed := r.members[id]; existed {
		r.memberCount.Add(-1)
	}
	delete(r.members, id)
}

// tryAdd adds c to the room, for tests; production joins use tryAddAndSnapshotRoster.
func (r *Room) tryAdd(c *Client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.putMemberLocked(c)
}

// maxPendingBeforeWelcome bounds Client.pending, what the room sends a joiner while its Welcome is written. A large
// room can fill it within one write, which is why forwardLine's overflow drops by class.
const maxPendingBeforeWelcome = 64

// boundWelcomeRoster trims the roster, and the nametags with it, until the Welcome's marshalled envelope fits budget,
// and returns the members it could not carry, which the caller sends as Joins. budget comes from sendBudget, since a
// udp connection carries less than a receiver's scanner accepts. Measured rather than counted: encoding/json escapes
// the '&', '<' and '>' a name may hold to six bytes each. A binary search, since adding a member never shrinks it.
func boundWelcomeRoster(w protocol.Welcome, roster []string, names map[string]protocol.Nametag, budget int) (protocol.Welcome, []string) {
	withPrefix := func(k int) protocol.Welcome {
		out := w
		out.Roster = roster[:k]
		out.Nametags = nil
		for _, id := range roster[:k] {
			if tag, ok := names[id]; ok {
				if out.Nametags == nil {
					out.Nametags = make(map[string]protocol.Nametag, k)
				}
				out.Nametags[id] = tag
			}
		}
		return out
	}
	if welcomeLineBytes(withPrefix(len(roster)), budget) <= budget {
		return withPrefix(len(roster)), nil
	}
	// Largest prefix that fits; 0 is still sent, since a Welcome with no roster carries the client's own id and token.
	lo, hi := 0, len(roster)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if welcomeLineBytes(withPrefix(mid), budget) <= budget {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return withPrefix(lo), roster[lo:]
}

// welcomeLineBytes is what sendEnvelope would put on the wire for this Welcome; a marshal failure reports over budget,
// so the caller shrinks rather than grows.
func welcomeLineBytes(w protocol.Welcome, budget int) int {
	env, err := envelope(protocol.TypeWelcome, w)
	if err != nil {
		return budget + 1
	}
	b, err := json.Marshal(env)
	if err != nil {
		return budget + 1
	}
	return len(b)
}

// markWelcomedAndFlush ends the pre-Welcome hold for playerID and delivers what was held, in order; call it right
// after the Welcome is written. It sends outside r.mu, and clears the hold only in the critical section that sees an
// empty queue: clearing it first would let forward write a newer message while older ones still drain.
func (r *Room) markWelcomedAndFlush(playerID string) {
	for {
		r.mu.Lock()
		c, ok := r.members[playerID]
		if !ok {
			r.mu.Unlock()
			return
		}
		if len(c.pending) == 0 {
			c.holdUntilWelcome = false
			r.mu.Unlock()
			return
		}
		queued, conn := c.pending, c.Conn
		c.pending = nil
		// Always cleared together: two slices indexed together drift once one is reset alone.
		c.pendingUnreliable = nil
		r.mu.Unlock()

		if conn == nil {
			// Nothing to write to; drop the hold so this cannot spin.
			r.mu.Lock()
			if c, ok := r.members[playerID]; ok {
				c.holdUntilWelcome = false
				c.pending = nil
				c.pendingUnreliable = nil
			}
			r.mu.Unlock()
			return
		}
		for _, payload := range queued {
			if err := conn.Send(payload); err != nil {
				log.Printf("relay: flushing queued message to %s failed: %v", playerID, err)
				r.mu.Lock()
				if c, ok := r.members[playerID]; ok {
					c.holdUntilWelcome = false
					c.pending = nil
					c.pendingUnreliable = nil
				}
				r.mu.Unlock()
				return
			}
		}
	}
}

// tryAddAndSnapshotRoster adds c and returns the roster as it stood just before, with its members' nametags (nil when
// nobody has one), in one critical section: two concurrent joiners snapshotting separately could each miss the other,
// and core drops a State from an unrostered id. Capacity is reserved by the caller, so this cannot fail.
func (r *Room) tryAddAndSnapshotRoster(c *Client) (rosterBeforeJoin []string, namesBeforeJoin map[string]protocol.Nametag) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rosterBeforeJoin = make([]string, 0, len(r.members))
	for id, m := range r.members {
		rosterBeforeJoin = append(rosterBeforeJoin, id)
		if m.nametag != nil {
			if namesBeforeJoin == nil {
				namesBeforeJoin = make(map[string]protocol.Nametag, len(r.members))
			}
			namesBeforeJoin[id] = *m.nametag
		}
	}
	r.seedLastAreaLocked(c)
	r.putMemberLocked(c)
	return rosterBeforeJoin, namesBeforeJoin
}

// sanitizedNametag builds the label other players will see from a Hello, or nil when no name survives sanitizing. A
// colour without a name goes with it: there is no tag to colour.
func sanitizedNametag(hello protocol.Hello) *protocol.Nametag {
	name := protocol.SanitizeDisplayName(hello.DisplayName)
	if name == "" {
		return nil
	}
	return &protocol.Nametag{
		Name:  name,
		Color: protocol.SanitizeNameColor(hello.NameColor),
	}
}

// nametagName is the name for a log line, and "" for a player without one.
func nametagName(n *protocol.Nametag) string {
	if n == nil {
		return ""
	}
	return n.Name
}

// seedLastAreaLocked gives a Client the area this room remembers for its player id. On resume the Client is new while
// lastState holds the real area, and the filter fails open on an empty one. Caller holds r.mu.
func (r *Room) seedLastAreaLocked(c *Client) {
	if st, ok := r.lastState[c.PlayerID]; ok {
		c.lastArea = st.AreaID
	}
}

func (r *Room) remove(playerID string) {
	r.mu.Lock()
	if gone, ok := r.members[playerID]; ok && gone.out != nil {
		// Stops this client's writer once its queue drains, or it leaks a goroutine per player.
		gone.out.close()
	}
	r.deleteMemberLocked(playerID)
	// A real departure leaves nobody to replay the event backlog to.
	delete(r.missedEvents, playerID)
	remaining := make([]*Client, 0, len(r.members))
	for _, c := range r.members {
		remaining = append(remaining, c)
	}
	r.mu.Unlock()

	// After unlocking r.mu, so no gateMu is ever taken under it.
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

// stateRecipients returns which other members should receive a State from sender now: area filtering for those who
// opted in, then each recipient's maxReceiveHz gate, consulted after unlocking r.mu. Only state is ever throttled; a
// throttled leave would strand a frozen ghost. payloadBytes feeds the counters only, and excludes the envelope, a
// constant per line that leaves the shares unchanged, so the hot path never marshals just to count.
func (r *Room) stateRecipients(sender, senderArea, senderPrevArea string, payloadBytes int, now time.Time) []string {
	r.mu.Lock()
	members := make([]*Client, 0, len(r.members))
	var cross, filtered uint64
	crossed := senderPrevArea != "" && senderPrevArea != senderArea
	for id, c := range r.members {
		if id == sender || c.suspended {
			continue
		}
		// Before the receive gate, so a cross-area message never consumes a recipient's rate-gate slot.
		elsewhere := senderArea != "" && c.lastArea != "" && c.lastArea != senderArea
		if elsewhere {
			cross++
			// A strict subset of core.remoteStatesAt's render-time check, so it only removes what the recipient's
			// core would discard; every condition fails open.
			if c.ownAreaOnly {
				// A peer leaving this area is announced only by its first state with the new area_id, so that one is
				// delivered here, or its ghost stands frozen at the doorway until DefaultRemoteStaleAfter.
				if crossed && c.lastArea == senderPrevArea {
					members = append(members, c)
					continue
				}
				filtered++
				continue
			}
		}
		members = append(members, c)
	}
	r.statesIn++
	r.stateRecipientsCross += cross
	r.stateRecipientsFiltered += filtered
	r.stateBytesCrossArea += cross * uint64(payloadBytes)
	r.stateBytesFiltered += filtered * uint64(payloadBytes)
	r.mu.Unlock()

	ids := make([]string, 0, len(members))
	for _, c := range members {
		if c.allowStateFrom(sender, now) {
			ids = append(ids, c.PlayerID)
		}
	}

	// Recipients and bytes are counted after the receive gate, which decides who is written to; the area counters
	// stay above, since an area-filtered message never reaches the gate.
	if len(ids) > 0 {
		r.mu.Lock()
		r.stateRecipientsOut += uint64(len(ids))
		r.stateBytesForwarded += uint64(len(ids)) * uint64(payloadBytes)
		r.mu.Unlock()
	}
	return ids
}

// Server accepts relay-protocol connections and dispatches them into Rooms keyed by game_id and room name. It is the
// running process behind cmd/meshghost-relay.
type Server struct {
	mu        sync.Mutex
	rooms     map[string]*Room
	idCounter uint64

	// suspended maps a resume token to the identity it reinstates, live identities included, since a session is
	// registered when its token is issued. Guarded by mu; in memory only.
	suspended map[string]*suspendedSession

	// The log lines a stranger can cause, each throttled to one a second with a count, so they cannot roll the log.
	refusedHelloLine throttle.Line
	helloTimeoutLine throttle.Line
	connErrorLine    throttle.Line
	rateLimitLine    throttle.Line
	oversizedLine    throttle.Line

	// ResumeGrace overrides protocol.DefaultResumeGrace when non-zero, so a test can wait the window out.
	ResumeGrace time.Duration

	// Loopback is a dev-only flag: every State forwarded to a room is also echoed to its sender with PlayerID
	// rewritten to "<id>-ghost", a real round trip with one client. Never on outside dev and testing.
	Loopback bool

	// HelloTimeout bounds how long an unauthenticated connection may sit without completing a Hello and joining a
	// room. Zero means DefaultHelloTimeout.
	HelloTimeout time.Duration

	// RoomCode, when non-empty, is the code every client must prove (package pake) before joining. Empty, the
	// default, means auth is off.
	RoomCode string

	// PakeIdentity is the identity the room-code proof binds to: this relay's certificate fingerprint, so a client's
	// proof fails against a relay presenting any other certificate. Empty means pake.UnboundIdentity, a test and dev
	// value. Read at the first hello after a code is set; change it before Serve.
	PakeIdentity string

	// SourceGuard, when set, budgets wrong room codes per client address. Nil, the default in tests, leaves one
	// guess per connection as the only bound.
	SourceGuard SourceGuard

	// The cached room-code proof server (pakeServer) and the code it was built for; pakeFaultLine throttles the line
	// for a proof that cannot be set up at all.
	pakeMu        sync.Mutex
	pakeSrv       *pake.Server
	pakeCode      string
	pakeFaultLine throttle.Line

	// OnlyGame, when non-empty, restricts this relay to one game: a Hello with another game_id is refused at the
	// handshake. Server-wide, unlike Room.GameID, and compared by equality only.
	OnlyGame string

	// MaxClients bounds how many clients this relay accepts in total, across every room; zero means
	// DefaultMaxClients. Read on every join attempt, so a change takes effect at once.
	MaxClients int

	// IdleTimeout overrides transport.DefaultIdleTimeout when non-zero, for tests that need a short idle window.
	IdleTimeout time.Duration

	// SendHz is the room-wide state send rate this relay advertises in every Welcome; zero means
	// protocol.DefaultSendHz, and out-of-range values are clamped at the use site. Prescriptive but not enforced:
	// the only hard limit is the flood cap, which scales from it.
	SendHz int

	// GhostCollision is the room-wide ghost-collision policy this relay advertises in every Welcome: enabled,
	// disabled, or "" for unset, which clients treat as enabled. Advisory: the relay knows no game, so it cannot
	// check an adapter honours it. Normalized at the use site.
	GhostCollision string

	// Offers is what a QueryOnly Hello is answered with: the transports this relay serves and their ports, set by
	// cmd/meshghost-relay, since the relay is handed net.Listeners and cannot tell them apart. Empty answers an empty
	// list, which a client treats as an older relay.
	Offers []protocol.TransportOffer

	// clientCount is the number of clients holding a reserved slot. Guarded by mu.
	clientCount int
}

// pendingProof is a hello parked on the room-code proof, between the relay's KE2 and the client's KE3.
type pendingProof struct {
	hello protocol.Hello
	sess  *pake.Session
}

// pakeServer is the OPAQUE server for the current room code, rebuilt when the code or the identity changes. Cached
// because registration runs Argon2id.
func (s *Server) pakeServer() (*pake.Server, error) {
	code := s.roomCode()
	identity := s.PakeIdentity
	if identity == "" {
		identity = pake.UnboundIdentity
	}
	s.pakeMu.Lock()
	defer s.pakeMu.Unlock()
	if s.pakeSrv != nil && s.pakeCode == code && s.pakeSrv.Identity() == identity {
		return s.pakeSrv, nil
	}
	srv, err := pake.NewServer(code, identity)
	if err != nil {
		return nil, err
	}
	s.pakeSrv, s.pakeCode = srv, code
	return srv, nil
}

// SourceGuard is the relay's view of per-address policy, typed on net.Conn on purpose: the relay never reads a
// client's address, the guard (netx/srclimit) calls RemoteAddr on its side. RemoteAddr is a net.Conn method, so it
// crosses every wrapper in the stack, where a method type-asserted on the connection would not.
type SourceGuard interface {
	// Blocked reports whether conn's source has used up its budget of wrong room codes and must be refused before
	// the code is compared, the right code included.
	Blocked(conn net.Conn) bool
	// NoteAuthFailure charges one wrong room code to conn's source. The relay charges it when a proof begins, not
	// when it fails, so logins held open in parallel cannot outrun the budget.
	NoteAuthFailure(conn net.Conn)
	// NoteAuthSuccess refunds the attempt charged when conn's proof began, because it proved the right code.
	NoteAuthSuccess(conn net.Conn)
}

// SetRoomCode, SetOnlyGame and SetMaxClients change the settings a running relay re-reads from its config, without
// disconnecting anyone: the next hello or join sees them. Written under s.mu because every connection's hello path
// reads them through roomCode and onlyGame; MaxClients is read directly where s.mu is already held, since a getter
// there would deadlock.
func (s *Server) SetRoomCode(code string) {
	s.mu.Lock()
	s.RoomCode = code
	s.mu.Unlock()
}

func (s *Server) SetOnlyGame(gameID string) {
	s.mu.Lock()
	s.OnlyGame = gameID
	s.mu.Unlock()
}

func (s *Server) SetMaxClients(n int) {
	s.mu.Lock()
	s.MaxClients = n
	s.mu.Unlock()
}

func (s *Server) roomCode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.RoomCode
}

func (s *Server) onlyGame() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.OnlyGame
}

// NewServer creates an empty Server with no rooms.
func NewServer() *Server {
	return &Server{rooms: make(map[string]*Room), HelloTimeout: DefaultHelloTimeout, MaxClients: DefaultMaxClients}
}

// transportOffers returns a copy of Offers taken under the lock, so the JSON encoder never races a reconfiguration.
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

// tryReserveSlot reserves one of the server's MaxClients slots atomically with the capacity check, so two joins
// cannot race past the limit; ok is false at capacity. Every reserved slot needs exactly one later releaseSlot.
func (s *Server) tryReserveSlot() (ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.clientCount >= EffectiveMaxClients(s.MaxClients) {
		return false
	}
	s.clientCount++
	return true
}

// releaseSlot returns one slot reserved by tryReserveSlot, once a joined client disconnects.
func (s *Server) releaseSlot() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clientCount--
}

// resolveSendHz returns this relay's configured send rate through protocol.ClampSendHz; zero means DefaultSendHz.
func (s *Server) resolveSendHz() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return protocol.ClampSendHz(s.SendHz)
}

// resolveGhostCollision returns this relay's ghost-collision policy, normalized. "" stays "", so a client can tell
// "nobody configured a policy" from "the host chose enabled".
func (s *Server) resolveGhostCollision() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return protocol.NormalizeGhostCollision(s.GhostCollision)
}

// Serve accepts connections on ln, handling each on its own goroutine, until Accept fails with an error that is not
// temporary (typically because ln was closed).
func (s *Server) Serve(ln net.Listener) error {
	var backoff time.Duration
	for {
		conn, err := ln.Accept()
		if err != nil {
			// A temporary error (EMFILE, which a stranger can cause by holding connections) backs off and retries,
			// as net/http.Server.Serve does: returning would take every room down.
			if ne, ok := err.(net.Error); ok && ne.Temporary() { //nolint:staticcheck // the deprecation is about timeouts; EMFILE is exactly what this asks
				if backoff == 0 {
					backoff = 5 * time.Millisecond
				} else if backoff *= 2; backoff > time.Second {
					backoff = time.Second
				}
				log.Printf("relay: accept: %v — retrying in %s", err, backoff)
				time.Sleep(backoff)
				continue
			}
			return err
		}
		backoff = 0
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
		if n, ok := sendFailedLine.Allow(); ok {
			log.Printf("relay: send %s failed: %v (%d such failure(s) so far)", t, withoutAddress(err), n)
		}
	}
}

// sendFailedLine throttles sendEnvelope's failure line, which a stranger reaches before admission (a refused hello,
// then a reset). Package-level, so one budget covers every connection.
var sendFailedLine throttle.Line

// withoutAddress strips the peer address a *net.OpError prints: the relay never writes a client's IP to its log.
func withoutAddress(err error) error {
	var op *net.OpError
	if errors.As(err, &op) && op.Err != nil {
		return op.Err
	}
	return err
}

// rejectFor builds the wire Reject for a reason: the prose a human reads, the stable code anything else branches on,
// and whether reconnecting could help. Every refusal goes through here so the three cannot disagree.
func rejectFor(reason string) protocol.Reject {
	code := protocol.CodeForReason(reason)
	retryable, _ := protocol.RetryableForCode(code)
	return protocol.Reject{Reason: reason, Code: code, Retryable: retryable}
}

// rejectAndClose sends a protocol.Reject with reason, logs the refusal, then closes conn, so every pre-join refusal
// tells the client why instead of hanging up like a relay that is down.
func (s *Server) rejectAndClose(conn *transport.NDJSONConn, hello protocol.Hello, reason string) {
	// The display name is sanitized, since a refused hello is still attacker-controlled, and the line is throttled,
	// since a stranger cycling connections would flood it.
	if n, ok := s.refusedHelloLine.Allow(); ok {
		log.Printf("relay: refused hello (%s): game_id=%q room=%q display_name=%q (%d refused so far)",
			reason, hello.GameID, hello.Room, protocol.SanitizeDisplayName(hello.DisplayName), n)
	}
	sendEnvelope(conn, protocol.TypeReject, rejectFor(reason))
	// Graceful, not Close: a reset would throw away the Reject.
	conn.CloseGracefully(handshakeCloseDrain)
}

// roomKey is the key a room lives under in Server.rooms: its game_id and its name, so two games using the default
// room name never lock each other out. Length-prefixed, since a JSON string can hold any separator byte and a crafted
// game_id could otherwise land a client in another game's room.
func roomKey(gameID, name string) string {
	return fmt.Sprintf("%d:%s:%s", len(gameID), gameID, name)
}

// joinOrCreateRoom returns the named room for this game, creating it if needed. reason is non-empty when the caller
// must refuse the connection rather than mix clients with incompatible capabilities or versions.
func (s *Server) joinOrCreateRoom(gameID, gameVersion, name string, features []string) (r *Room, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := roomKey(gameID, name)
	r, exists := s.rooms[key]
	if !exists {
		r = newRoom(gameID, gameVersion, name, features)
		r.key = key
		s.rooms[key] = r
		// Held against being swept until the caller joins (Room.joining); every caller pairs it with finishJoin.
		r.joining++
		return r, ""
	}
	// The key already makes game_id equal. Room-scoped sets must match exactly, empty included, or one client could
	// claim a lease properly while another simply acts; client-scoped ones involve no peer.
	if protocol.FeatureSetKey(r.features) != protocol.FeatureSetKey(protocol.RoomScopedFeatures(features)) {
		return nil, protocol.ReasonFeatureMismatch
	}
	// Compared only once both sides declare a version: an adapter that reports none must not be refused.
	if r.GameVersion != "" && gameVersion != "" && r.GameVersion != gameVersion {
		return nil, protocol.ReasonGameVersionMismatch
	}
	r.joining++
	return r, ""
}

// finishJoin releases the hold joinOrCreateRoom took, once the caller has joined or given up; handleConn defers it,
// so every early return in the hello path is covered.
func (s *Server) finishJoin(r *Room) {
	s.mu.Lock()
	if r.joining > 0 {
		r.joining--
	}
	s.mu.Unlock()
	// A room held only by a joiner that gave up would otherwise sit in the table empty forever.
	s.dropIfEmpty(r)
}

// dropIfEmpty removes r from the room table if it has no members, so abandoned rooms do not accumulate.
func (s *Server) dropIfEmpty(r *Room) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// memberCount, not size(), so r.mu is never taken under s.mu. The lock-free read is safe here only: with s.mu
	// held and joining == 0 no join is in flight, so the count can only fall, and a later leave sweeps again.
	if r.memberCount.Load() == 0 && r.joining == 0 {
		// By key, not name: two games can hold rooms of the same name.
		if cur, ok := s.rooms[r.key]; ok && cur == r {
			delete(s.rooms, r.key)
		}
	}
}

func (s *Server) nextPlayerID() string {
	n := atomic.AddUint64(&s.idCounter, 1)
	return fmt.Sprintf("p%d", n)
}

// transportName labels a connection for logging without importing a transport package: netx/udpconn and
// netx/quicconn implement TransportName, and anything else is tcp-shaped.
func transportName(conn net.Conn) string {
	if n, ok := conn.(interface{ TransportName() string }); ok {
		return n.TransportName()
	}
	return "tcp"
}

// sendBudget is the largest payload one reliable Send can carry to this client: the smaller of what a receiver's
// line scanner accepts (protocol.MaxPayloadBytes) and what this connection carries, which on udp is far less. A
// Transport that reports nothing leaves the protocol bound; a transport can never raise it past what a receiver
// accepts.
func sendBudget(conn transport.Transport) int {
	m, ok := conn.(interface{ MaxPayloadBytes() int })
	if !ok {
		return protocol.MaxPayloadBytes
	}
	if n := m.MaxPayloadBytes(); n > 0 && n < protocol.MaxPayloadBytes {
		return n
	}
	return protocol.MaxPayloadBytes
}

// handleConn drives one client connection for its whole lifetime: the opening Hello, joining a Room, forwarding
// State messages to the rest of the room, and cleaning up on disconnect.
func (s *Server) handleConn(conn net.Conn) {
	// The line limit is set at construction, so it holds before the read loop's first Scan. A zero idle timeout means
	// transport's default; tests shrink it through s.IdleTimeout.
	nd := transport.FromConnWithLimits(conn, protocol.MaxLineBytes, s.IdleTimeout, 0)

	var (
		mu       sync.Mutex
		room     *Room
		playerID string

		// client is this connection's room entry and resumeToken the single-use secret that would let it reclaim
		// playerID after a drop. OnDisconnect reads both, so they live under mu.
		client      *Client
		resumeToken string

		// pending is a hello parked between the room-code proof's KE2 and KE3; OnDisconnect charges an abandoned
		// proof to the source's budget.
		pending *pendingProof

		// The rest need no mutex: only OnReceive touches them, and transport calls it serially, one goroutine per
		// connection.
		rateWindow time.Time
		// A float because the bucket drains by a fraction of a message per nanosecond.
		rateCount float64
		// rateRejected latches once the rate limit trips, so lines still arriving during the drain are ignored
		// rather than each re-tripping it.
		rateRejected bool

		// handshakeRejected is the same latch for the handshake refusals: CloseGracefully keeps reading during the
		// drain, so without it a refused peer's pipelined second hello could complete a join over a half-closed
		// socket, and each pipelined line could log twice.
		handshakeRejected bool

		// loopbackGhostSent tracks whether this connection was sent a Join for its own "<id>-ghost".
		loopbackGhostSent bool
	)

	// rejectHandshake is the only way to refuse a hello on this connection: latching and rejecting are one action,
	// so a refused connection never acts on its next hello.
	rejectHandshake := func(hello protocol.Hello, reason string) {
		handshakeRejected = true
		s.rejectAndClose(nd, hello, reason)
	}

	// Resolved once, so the enforced cap is the one this connection's Welcome advertised, never a later setting.
	sendHz := s.resolveSendHz()
	msgLimit := MaxMessagesPerSecondFor(sendHz)

	// A connection that never joins is closed: the idle timeout resets on any line, so pings alone would hold it.
	helloTimeout := s.HelloTimeout
	if helloTimeout <= 0 {
		helloTimeout = DefaultHelloTimeout
	}
	// Counted from accept: tlsx's sniff and handshake run first under a timeout of the same length, and charging the
	// window again here would let a stranger hold a socket for both. A listener without AcceptedAt gets it all.
	helloWait := helloTimeout
	if a, ok := conn.(interface{ AcceptedAt() time.Time }); ok {
		if at := a.AcceptedAt(); !at.IsZero() {
			helloWait -= time.Since(at)
			if helloWait < 0 {
				helloWait = 0
			}
		}
	}
	helloTimer := time.AfterFunc(helloWait, func() {
		mu.Lock()
		stillWaiting := room == nil
		mu.Unlock()
		if stillWaiting {
			if n, ok := s.helloTimeoutLine.Allow(); ok {
				log.Printf("relay: connection did not complete hello within %s, closing (%d so far)", helloTimeout, n)
			}
			_ = nd.Close()
		}
	})

	// admit is everything a trusted hello leads to: discovery, the single-game check, the room, the seat, the Welcome.
	// One body for both entry points, the plain hello and the room-code proof's last message.
	admit := func(hello protocol.Hello) {
		// After the field-length, version and room-code checks in OnReceive and before the room table: a caller
		// learns nothing it could not by joining, and no room, id, slot or member is touched.
		if hello.QueryOnly {
			sendEnvelope(nd, protocol.TypeTransports, protocol.Transports{Offers: s.transportOffers()})
			// Latched like every terminating hello: the drain keeps reading, and a pipelined second hello would
			// otherwise run a whole join, which every member sees as a ghost that appears and vanishes.
			handshakeRejected = true
			// Graceful: a reset would lose the offer, and the client would fall back to guessing a transport.
			nd.CloseGracefully(handshakeCloseDrain)
			return
		}

		// After the field-length bound, so the game_id rejectAndClose logs is bounded; empty OnlyGame hosts any game.
		if only := s.onlyGame(); only != "" && hello.GameID != only {
			rejectHandshake(hello, protocol.ReasonGameNotAllowed)
			return
		}
		joined, reason := s.joinOrCreateRoom(hello.GameID, hello.GameVersion, hello.Room, hello.Features)
		if reason != "" {
			rejectHandshake(hello, reason)
			return
		}
		// Releases Room.joining on every exit; one missed exit would pin the room in the table for the process's life.
		defer s.finishJoin(joined)

		// Resumption comes before a slot or an id, since a resuming client still holds both. A token that is unknown,
		// expired or for another room yields nil, and the client joins fresh rather than being refused.
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
			// MaxClients counts every room; a room created only for this attempt goes in the deferred finishJoin.
			rejectHandshake(hello, protocol.ReasonServerFull)
			s.dropIfEmpty(joined)
			return
		}

		newID := s.nextPlayerID()
		newClient := &Client{
			PlayerID:     newID,
			Conn:         nd,
			maxReceiveHz: protocol.ClampReceiveHz(hello.MaxReceiveHz),
			ownAreaOnly:  hello.OwnAreaOnly,
			transport:    transportName(conn),
			// Sanitized once, here: every later use reads this field, so no path can pass on the raw Hello string.
			nametag:  sanitizedNametag(hello),
			features: protocol.NormalizeFeatures(hello.Features),
			// Set before the add, so forward never reaches this client unheld; markWelcomedAndFlush clears it.
			holdUntilWelcome: true,
		}
		// Started before the add, so no fan-out reaches this client without a writer.
		newClient.out = newOutbox(newID, nd)
		rosterBeforeJoin, rosterNames := joined.tryAddAndSnapshotRoster(newClient)

		// Minted only for a client that asked for resumption, so the cosmetic case never holds an identity past a
		// disconnect. A minting failure leaves the session unresumable rather than refusing the join.
		newToken := ""
		if newClient.wants(protocol.FeatureResumeV1) {
			var err error
			if newToken, err = newResumeToken(); err != nil {
				log.Printf("relay: could not mint a resume token for %s: %v — this session will not be resumable", newID, err)
				newToken = ""
			}
		}

		// Registered now, not on disconnect, or a resume would work only once the relay had noticed the drop.
		s.registerSession(joined, newID, newToken, "")

		mu.Lock()
		room, playerID, client, resumeToken = joined, newID, newClient, newToken
		mu.Unlock()
		helloTimer.Stop()

		// The sanitized nametag, never hello.DisplayName: a raw name can hold newlines that forge lines in the log.
		log.Printf("relay: %s (%q) joined room %q as game %q over %s",
			newID, nametagName(newClient.nametag), hello.Room, hello.GameID, transportName(conn))

		// Bounded, so room size never becomes a wire-format ceiling: members the Welcome cannot carry follow as
		// ordinary Joins on this connection before the hold is released, as if they had joined a moment later.
		welcome, overflowRoster := boundWelcomeRoster(protocol.Welcome{
			PlayerID: newID,
			SendHz:   sendHz,
			// Lets a client refuse a relay older than its own minimum; an absent version is below any floor.
			ProtocolVersion: protocol.Version,
			GhostCollision:  s.resolveGhostCollision(),
			// The room's agreed set plus the client-scoped capabilities this client got: what is in force for it.
			Features:     effectiveFeatures(joined, newClient),
			ResumeToken:  newToken,
			ServerTimeMs: time.Now().UnixMilli(),
		}, rosterBeforeJoin, rosterNames, sendBudget(nd))
		sendEnvelope(nd, protocol.TypeWelcome, welcome)

		for _, id := range overflowRoster {
			j := protocol.Join{PlayerID: id}
			if tag, ok := rosterNames[id]; ok {
				t := tag
				j.Nametag = &t
			}
			sendEnvelope(nd, protocol.TypeJoin, j)
		}

		// Delivers what the room sent while this client was being added, still ahead of the seeding below.
		joined.markWelcomedAndFlush(newID)

		// Everyone's last state and the room's world, after the Welcome: a client drops state for an id its roster
		// does not list.
		joined.joinSnapshot(newID)

		join, err := envelope(protocol.TypeJoin, protocol.Join{
			PlayerID: newID,
			Nametag:  newClient.nametag,
		})
		if err == nil {
			// The roster captured with the add, not the current members: a later joiner already has this client in its
			// own Welcome roster, and would get a duplicate join.
			joined.Forward(join, rosterBeforeJoin)
		}
	}

	nd.OnError(func(err error) {
		// Throttled: a stranger controls how many connections there are.
		if n, ok := s.connErrorLine.Allow(); ok {
			log.Printf("relay: connection error: %v (%d so far)", err, n)
		}
	})

	nd.OnDisconnect(func(err error) {
		helloTimer.Stop()
		mu.Lock()
		r, id, c, token := room, playerID, client, resumeToken
		pending = nil
		mu.Unlock()
		if r == nil {
			// A proof started and never finished stays charged from its KE2: a client that learned there its code is
			// wrong hangs up, and that costs what a wrong KE3 does.
			return
		}

		if token != "" && c != nil {
			// Park the identity instead of a leave, only while this connection is id's live one: a resume installs a
			// new Client under the same id, and suspending on the superseded connection would mute its replacement.
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
		// The transport already closed on an oversized line; a flood of well-sized ones is closed outright, not
		// filtered, since no adapter of ours floods.
		if rateRejected || handshakeRejected {
			// Draining after a refusal: no second Reject per line, and no second hello acted on.
			return
		}
		// A leaky bucket, not a tumbling window, so any one-second span allows the same: every per-message fan-out in
		// this package is bounded by this number alone. Floored at zero, so an idle client gets its full burst.
		now := time.Now()
		if !rateWindow.IsZero() {
			rateCount -= float64(msgLimit) * now.Sub(rateWindow).Seconds()
			if rateCount < 0 {
				rateCount = 0
			}
		}
		rateWindow = now
		rateCount++
		if rateCount > float64(msgLimit) {
			// A Reject, not a bare hangup, and a retryable one: a reconnecting client re-reads send_hz from its new
			// Welcome and may fit under the cap.
			if n, ok := s.rateLimitLine.Allow(); ok {
				log.Printf("relay: client exceeded %d messages/second, rejecting and closing connection (%d so far)", msgLimit, n)
			}
			sendEnvelope(nd, protocol.TypeReject, rejectFor(protocol.ReasonRateLimited))
			// Graceful: a close over the unread flood answers with a TCP reset, which can discard the Reject.
			rateRejected = true
			nd.CloseGracefully(rateLimitDrain)
			return
		}

		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}

		mu.Lock()
		r, id := room, playerID
		mu.Unlock()

		if r == nil {
			// A hello parked on the room-code proof accepts only the proof's last step, judged once either way.
			mu.Lock()
			pp := pending
			mu.Unlock()
			if pp != nil {
				if env.Type != protocol.TypePake {
					return
				}
				var pk protocol.Pake
				if err := json.Unmarshal(env.Payload, &pk); err != nil || len(pk.KE3) > protocol.MaxPakeFieldLen {
					return
				}
				mu.Lock()
				pending = nil
				mu.Unlock()
				ke3, derr := base64.StdEncoding.DecodeString(pk.KE3)
				if derr != nil || pp.sess.Finish(ke3) != nil {
					// Already charged when the KE2 went out.
					rejectHandshake(pp.hello, protocol.ReasonInvalidRoomCode)
					return
				}
				if s.SourceGuard != nil {
					s.SourceGuard.NoteAuthSuccess(conn)
				}
				admit(pp.hello)
				return
			}
			if env.Type != protocol.TypeHello {
				return
			}
			var hello protocol.Hello
			if err := json.Unmarshal(env.Payload, &hello); err != nil {
				return
			}
			// Checked first, and logged without the field values, since those are the unbounded bytes this refuses.
			if !protocol.ValidateHelloFields(hello) {
				if n, ok := s.oversizedLine.Allow(); ok {
					log.Printf("relay: refused hello (%s): a field exceeded %d bytes (%d so far)", protocol.ReasonHelloFieldTooLong, protocol.MaxHelloFieldLen, n)
				}
				sendEnvelope(nd, protocol.TypeReject, rejectFor(protocol.ReasonHelloFieldTooLong))
				// Latched, but not via rejectHandshake, whose log line prints the fields this refuses as unbounded.
				handshakeRejected = true
				nd.CloseGracefully(handshakeCloseDrain) // the Reject must survive the close
				return
			}
			// A floor, not equality: a newer client is accepted, since unknown JSON fields are ignored and refusing it
			// would make every relay upgrade a synchronised one.
			if !protocol.AcceptsPeerVersion(hello.ProtocolVersion) {
				rejectHandshake(hello, protocol.ReasonProtocolVersionMismatch)
				return
			}
			// Room-code auth, before the room table: the hello carries the proof's first message, and the relay answers
			// KE2 and parks the hello until KE3. Nothing the client sends is the code.
			if s.roomCode() != "" {
				// The per-address budget, before any work: a blocked source is told "rate limited" without its attempt
				// being judged, so the reply says nothing about whether it was right.
				if s.SourceGuard != nil && s.SourceGuard.Blocked(conn) {
					rejectHandshake(hello, protocol.ReasonRateLimited)
					return
				}
				ps, err := s.pakeServer()
				if err != nil {
					// A library fault, not the client's: refusing everyone is the only safe answer, and the line tells
					// the host why.
					if n, ok := s.pakeFaultLine.Allow(); ok {
						log.Printf("relay: the room-code proof cannot be set up (%v) -- refusing every join until it can (%d so far)", err, n)
					}
					rejectHandshake(hello, protocol.ReasonInvalidRoomCode)
					return
				}
				ke1, derr := base64.StdEncoding.DecodeString(hello.PakeKE1)
				if hello.PakeKE1 == "" || derr != nil {
					// No proof: a client without a code (one older than the proof was already refused by version).
					if s.SourceGuard != nil {
						s.SourceGuard.NoteAuthFailure(conn)
					}
					rejectHandshake(hello, protocol.ReasonInvalidRoomCode)
					return
				}
				ke2, sess, err := ps.Respond(ke1)
				if err != nil {
					if s.SourceGuard != nil {
						s.SourceGuard.NoteAuthFailure(conn)
					}
					rejectHandshake(hello, protocol.ReasonInvalidRoomCode)
					return
				}
				// Charged before the answer and refunded by a right KE3; SourceGuard.NoteAuthFailure says why.
				if s.SourceGuard != nil {
					s.SourceGuard.NoteAuthFailure(conn)
				}
				sendEnvelope(nd, protocol.TypePake, protocol.Pake{KE2: base64.StdEncoding.EncodeToString(ke2)})
				mu.Lock()
				pending = &pendingProof{hello: hello, sess: sess}
				mu.Unlock()
				return
			}
			admit(hello)
			return
		}

		switch env.Type {
		case protocol.TypeState:
			// In forwardState so the benchmark can call it; what follows is only the dev loopback echo.
			st, ok := r.forwardState(id, env.Payload)
			if !ok {
				return
			}

			if s.Loopback {
				ghostID := id + "-ghost"

				if !loopbackGhostSent {
					// Joined once, to this connection alone, since a core drops state for an id never announced. The
					// sender's nametag plus "-ghost" (fixed after the hello) makes nametags testable on one machine.
					ghostJoin := protocol.Join{PlayerID: ghostID}
					if client != nil && client.nametag != nil && client.nametag.Name != "" {
						ghostJoin.Nametag = &protocol.Nametag{
							Name:  client.nametag.Name + "-ghost",
							Color: client.nametag.Color,
						}
					}
					if join, err := envelope(protocol.TypeJoin, ghostJoin); err == nil {
						r.Forward(join, []string{id})
					}
					loopbackGhostSent = true
				}

				ghost := st
				ghost.PlayerID = ghostID
				ghostEnv, err := envelope(protocol.TypeState, ghost)
				if err == nil {
					// Unreliable like any state; the ghost's Join stays reliable, or every echo would be dropped.
					r.ForwardUnreliable(ghostEnv, []string{id})
				}
			}
		case protocol.TypeEvent:
			// Gated on the room's agreed features, so a deeper plane runs only where it was opted into, with no game_id
			// branch.
			if !r.hasFeature(protocol.FeatureEventV1) {
				return
			}
			var ev protocol.Event
			if err := json.Unmarshal(env.Payload, &ev); err != nil {
				return
			}
			if !protocol.ValidateEvent(ev) {
				// Dropped, not truncated: an oversized event should have carried a reference to the data.
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
				// Said once, in words: a host looking at a world that never appears has no other way to find out.
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
				// Dropped, not truncated, as an oversized event is.
				return
			}
			r.handleWorld(id, req)
		case protocol.TypeLeave:
			// A voluntary goodbye: clearing the token sends OnDisconnect down finishLeave instead of suspending, so the
			// room hears a real leave at once. The payload is unread; the connection already knows whose it is.
			mu.Lock()
			resumeToken = ""
			mu.Unlock()
			s.forgetSessionsOf(r, id)
			_ = nd.Close()
			return
		case protocol.TypePrefs:
			var prefs protocol.Prefs
			if err := json.Unmarshal(env.Payload, &prefs); err != nil {
				return
			}
			if prefs.OwnAreaOnly != nil {
				// Under r.mu, where stateRecipients reads it: unlike its neighbours, it changes after publication.
				r.mu.Lock()
				if c, ok := r.members[id]; ok {
					c.ownAreaOnly = *prefs.OwnAreaOnly
				}
				r.mu.Unlock()
			}
		case protocol.TypePing:
			var ping protocol.Ping
			if err := json.Unmarshal(env.Payload, &ping); err != nil {
				return
			}
			// Stamped as late as possible, so the client's offset estimate measures the network, not relay queueing.
			sendEnvelope(nd, protocol.TypePong, protocol.Pong{
				Nonce:        ping.Nonce,
				ServerTimeMs: time.Now().UnixMilli(),
			})
		default:
			// Unknown types (a hello after joining, a newer client's type) are ignored, as unknown fields are.
		}
	})
}
