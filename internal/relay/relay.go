// Package relay is the game-agnostic server: it forwards protocol.State
// messages between clients in a room, partitioned by game_id, and never
// runs or touches a game. protocol.Event is reserved for a future addressed
// event plane (agent_docs/contract.md's Extensibility section) but has no
// routing here yet. It never imports internal/core
// or internal/bridge — the relay must stay ignorant of adapter-side
// concerns, the same way it's ignorant of games.
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

	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// Room holds the connected clients for one room name. A Hello whose game_id
// (or, once declared, game_version) doesn't match an existing room's is
// rejected rather than mixing clients from different games/versions — see
// agent_docs/contract.md and the ADR in agent_docs/architecture.md.
type Room struct {
	GameID      string
	GameVersion string
	Name        string

	mu      sync.Mutex
	members map[string]*Client
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

func newRoom(gameID, gameVersion, name string) *Room {
	return &Room{GameID: gameID, GameVersion: gameVersion, Name: name, members: make(map[string]*Client)}
}

// Forward routes msg to the given recipients. Shaped to take an explicit
// recipient set rather than hardcoding room-wide broadcast, so that wiring
// in real addressed event routing later (agent_docs/contract.md's
// Extensibility section) is a small localized change instead of a rewrite
// of this path.
func (r *Room) Forward(msg protocol.Envelope, to []string) {
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
		if c, ok := r.members[id]; ok {
			targets = append(targets, target{id: id, conn: c.Conn})
		}
	}
	r.mu.Unlock()

	for _, t := range targets {
		if err := t.conn.Send(payload); err != nil {
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
// cross-check internal/core now does on receive (agent_docs/architecture.md's
// ADR), that isn't just a cosmetic gap anymore — it's a silently invisible
// peer, since a State for an unrostered id is dropped outright. Found in a
// review pass. Like tryAdd, capacity is already reserved server-wide by
// the caller, so this cannot fail.
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

// allExcept returns every current member's player_id other than exclude —
// the recipient set for "broadcast to the rest of the room".
func (r *Room) allExcept(exclude string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	ids := make([]string, 0, len(r.members))
	for id := range r.members {
		if id != exclude {
			ids = append(ids, id)
		}
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
// go through allExcept or a direct recipient list instead, so they are
// never throttled (a throttled leave would strand a permanently frozen
// ghost).
func (r *Room) stateRecipients(sender string, now time.Time) []string {
	r.mu.Lock()
	members := make([]*Client, 0, len(r.members))
	for id, c := range r.members {
		if id != sender {
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

	// Loopback is a dev-only Phase 3 flag (see agent_docs/phases/phase3.md):
	// when set, every State forwarded normally to the rest of a room is
	// additionally echoed back to its sender alone, with PlayerID rewritten
	// to "<id>-ghost". This exercises a real core->relay->core round trip
	// and real interpolation with only one physical client, without
	// internal/core needing to change at all — storeRemoteState's existing
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
	// agent_docs/architecture.md and internal/README.md for what this does
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

// joinOrCreateRoom returns the named room, creating it (with gameID/
// gameVersion) if it doesn't exist yet. reason is empty on success;
// non-empty describes why the caller must refuse the connection rather
// than mix clients from different games or incompatible versions.
func (s *Server) joinOrCreateRoom(gameID, gameVersion, name string) (r *Room, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, exists := s.rooms[name]
	if !exists {
		r = newRoom(gameID, gameVersion, name)
		s.rooms[name] = r
		return r, ""
	}
	if r.GameID != gameID {
		return nil, protocol.ReasonGameMismatch
	}
	// GameVersion is only compared once both sides have actually declared
	// one (protocol.Hello.GameVersion's doc comment) — an adapter that
	// doesn't report a version yet must not be refused, and a room's first
	// member sets the version other members are then compared against.
	if r.GameVersion != "" && gameVersion != "" && r.GameVersion != gameVersion {
		return nil, protocol.ReasonGameVersionMismatch
	}
	return r, ""
}

// dropIfEmpty removes r from the room table if it currently has no
// members, so abandoned rooms don't accumulate for the life of the server.
func (s *Server) dropIfEmpty(r *Room) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.size() == 0 {
		if cur, ok := s.rooms[r.Name]; ok && cur == r {
			delete(s.rooms, r.Name)
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
func (s *Server) handleConn(conn net.Conn) {
	// MaxLineBytes is the relay's own, tighter limit rather than
	// transport's generous package default — via FromConnWithLimits, not a
	// post-construction field set, so it's in effect before the read
	// loop's first Scan (found as a real, if narrow, race in a review
	// pass: transport.FromConn already starts that goroutine before
	// returning). IdleTimeout is normally left at 0 ("use transport's own
	// default", DefaultIdleTimeout) — s.IdleTimeout exists so a test can
	// shrink it to something waitable, e.g. proving Core's heartbeat
	// (internal/core's sendHeartbeats) actually keeps an otherwise-quiet
	// connection alive past it. 0 for write timeout: the relay has no need
	// for a different value there.
	nd := transport.FromConnWithLimits(conn, protocol.MaxLineBytes, s.IdleTimeout, 0)

	var (
		mu       sync.Mutex
		room     *Room
		playerID string

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
		r, id := room, playerID
		mu.Unlock()
		if r == nil {
			return
		}
		r.remove(id)
		s.releaseSlot()
		leave, _ := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: id})
		r.Forward(leave, r.roster())
		s.dropIfEmpty(r)
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
				len(hello.GameVersion) > MaxHelloFieldLen {
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
			joined, reason := s.joinOrCreateRoom(hello.GameID, hello.GameVersion, hello.Room)
			if reason != "" {
				rejectAndClose(nd, hello, reason)
				return
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
			rosterBeforeJoin := joined.tryAddAndSnapshotRoster(&Client{
				PlayerID:     newID,
				Conn:         nd,
				maxReceiveHz: protocol.ClampReceiveHz(hello.MaxReceiveHz),
			})

			mu.Lock()
			room, playerID = joined, newID
			mu.Unlock()
			helloTimer.Stop()

			// Join/leave are lifecycle events, not per-frame state, so one
			// line per occurrence can't spam — previously the relay's own
			// log recorded nothing at all for a connect/join, only its own
			// startup line, leaving a host with no way to tell "nobody's
			// connecting" from "someone's connecting and I can't see it."
			log.Printf("relay: %s (%q) joined room %q as game %q", newID, hello.DisplayName, hello.Room, hello.GameID)

			sendEnvelope(nd, protocol.TypeWelcome, protocol.Welcome{
				PlayerID: newID,
				Roster:   rosterBeforeJoin,
				SendHz:   sendHz,
			})

			join, err := envelope(protocol.TypeJoin, protocol.Join{PlayerID: newID})
			if err == nil {
				joined.Forward(join, joined.allExcept(newID))
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
			// shared with internal/core so both enforcement points can't
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
			r.Forward(stateEnv, r.stateRecipients(id, time.Now()))

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
					// internal/core.storeRemoteState drop any State for a
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
					r.Forward(ghostEnv, []string{id})
				}
			}
		case protocol.TypePing:
			var ping protocol.Ping
			if err := json.Unmarshal(env.Payload, &ping); err != nil {
				return
			}
			sendEnvelope(nd, protocol.TypePong, protocol.Pong{Nonce: ping.Nonce})
		default:
			// Unknown/unhandled types (event is reserved but not
			// implemented; hello after already joining; anything else)
			// are ignored, not treated as an error — the same
			// forward-compatibility posture as unknown fields.
		}
	})
}
