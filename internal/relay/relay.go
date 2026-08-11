// Package relay is the game-agnostic server: it forwards protocol.State (and
// later, protocol.Event) messages between clients in a room, partitioned by
// game_id, and never runs or touches a game. It never imports internal/core
// or internal/bridge — the relay must stay ignorant of adapter-side
// concerns, the same way it's ignorant of games.
package relay

import (
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
// doesn't match an existing room's is rejected rather than mixing clients
// from different games — see agent_docs/contract.md.
type Room struct {
	GameID string
	Name   string

	mu      sync.Mutex
	members map[string]*Client
}

// Client is one connected relay peer.
type Client struct {
	PlayerID string
	Conn     transport.Transport
}

func newRoom(gameID, name string) *Room {
	return &Room{GameID: gameID, Name: name, members: make(map[string]*Client)}
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

	r.mu.Lock()
	defer r.mu.Unlock()
	for _, id := range to {
		c, ok := r.members[id]
		if !ok {
			continue
		}
		if err := c.Conn.Send(payload); err != nil {
			log.Printf("relay: send to %s failed: %v", id, err)
		}
	}
}

// tryAdd adds c unless the room is already at MaxClientsPerRoom, atomically
// with the capacity check (unlike a separate size()-then-add, which would
// race two simultaneous joins past the limit). ok is false if the room was
// full; the caller refuses the connection, same as a game_id mismatch.
func (r *Room) tryAdd(c *Client) (ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.members) >= MaxClientsPerRoom {
		return false
	}
	r.members[c.PlayerID] = c
	return true
}

func (r *Room) remove(playerID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.members, playerID)
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
}

// NewServer creates an empty Server with no rooms.
func NewServer() *Server {
	return &Server{rooms: make(map[string]*Room)}
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

// joinOrCreateRoom returns the named room, creating it (with gameID) if it
// doesn't exist yet. ok is false if the room already exists under a
// different game_id — the caller must refuse the connection rather than
// mix clients from different games.
func (s *Server) joinOrCreateRoom(gameID, name string) (r *Room, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, exists := s.rooms[name]
	if !exists {
		r = newRoom(gameID, name)
		s.rooms[name] = r
		return r, true
	}
	if r.GameID != gameID {
		return nil, false
	}
	return r, true
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
	nd := transport.FromConn(conn)

	var (
		mu       sync.Mutex
		room     *Room
		playerID string

		rateMu     sync.Mutex
		rateWindow time.Time
		rateCount  int
	)

	nd.OnError(func(err error) {
		log.Printf("relay: connection error: %v", err)
	})

	nd.OnDisconnect(func(err error) {
		mu.Lock()
		r, id := room, playerID
		mu.Unlock()
		if r == nil {
			return
		}
		r.remove(id)
		leave, _ := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: id})
		r.Forward(leave, r.roster())
		s.dropIfEmpty(r)
	})

	nd.OnReceive(func(payload []byte) {
		// Limits, enforced starting Phase 3 (agent_docs/contract.md) —
		// these guard against a malformed or careless peer, not a
		// determined attacker (the relay is no-auth through Phase 4). Both
		// checks close the connection outright rather than silently
		// dropping the one offending message: a client that sends an
		// oversized line or floods the relay isn't behaving as this
		// project's own adapters do, and there's nothing to gain from
		// staying connected to find out why.
		if len(payload) > MaxLineBytes {
			log.Printf("relay: line exceeds MaxLineBytes (%d bytes), closing connection", MaxLineBytes)
			_ = nd.Close()
			return
		}

		rateMu.Lock()
		now := time.Now()
		if now.Sub(rateWindow) >= time.Second {
			rateWindow = now
			rateCount = 0
		}
		rateCount++
		rateExceeded := rateCount > MaxMessagesPerSecond
		rateMu.Unlock()
		if rateExceeded {
			log.Printf("relay: client exceeded %d messages/second, closing connection", MaxMessagesPerSecond)
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
			// Versioning rule (agent_docs/contract.md): a mismatched major
			// version is refused outright, not guessed at.
			if hello.ProtocolVersion != protocol.Version {
				_ = nd.Close()
				return
			}
			joined, ok := s.joinOrCreateRoom(hello.GameID, hello.Room)
			if !ok {
				// game_id doesn't match this room's existing clients.
				_ = nd.Close()
				return
			}

			rosterBeforeJoin := joined.roster()
			newID := s.nextPlayerID()
			if !joined.tryAdd(&Client{PlayerID: newID, Conn: nd}) {
				// Room already at MaxClientsPerRoom (agent_docs/contract.md
				// Limits) — refuse the same way a game_id mismatch is
				// refused, rather than letting a room grow unbounded.
				_ = nd.Close()
				s.dropIfEmpty(joined)
				return
			}

			mu.Lock()
			room, playerID = joined, newID
			mu.Unlock()

			sendEnvelope(nd, protocol.TypeWelcome, protocol.Welcome{
				PlayerID: newID,
				Roster:   rosterBeforeJoin,
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
			// Size limits (agent_docs/contract.md) — drop rather than
			// truncate, so a client sees silence instead of a
			// half-forwarded, confusing state.
			if len(st.Position) > MaxPositionLen {
				return
			}
			if len(st.Extras) > 0 {
				extrasBytes, err := json.Marshal(st.Extras)
				if err != nil || len(extrasBytes) > MaxExtrasBytes {
					return
				}
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
			r.Forward(stateEnv, r.allExcept(id))

			if s.Loopback {
				// Dev-only Phase 3 loopback (agent_docs/phases/phase3.md):
				// echo the same state back to the sender alone, under a
				// synthetic ghost id, so a lone client exercises a real
				// core->relay->core round trip. See the Server.Loopback
				// doc comment.
				ghost := st
				ghost.PlayerID = id + "-ghost"
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
