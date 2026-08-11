// Package relay is the game-agnostic server: it forwards protocol.State (and
// later, protocol.Event) messages between clients in a room, partitioned by
// game_id, and never runs or touches a game. It never imports internal/core
// or internal/bridge — the relay must stay ignorant of adapter-side
// concerns, the same way it's ignorant of games.
package relay

import (
	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// Room holds the connected clients for one (game_id, room name) pair. A
// Hello whose game_id doesn't match an existing room's is rejected rather
// than mixing clients from different games — see agent_docs/contract.md.
type Room struct {
	GameID string
	Name   string
	// TODO(Phase 3): members map[string]*Client, room-level limits from
	// agent_docs/contract.md (max clients per room, per-client rate limit).
}

// Client is one connected relay peer.
type Client struct {
	PlayerID string
	Conn     transport.Transport
}

// Forward routes msg to the given recipients. Shaped to take an explicit
// recipient set from day one — even though every real call today would
// pass every member of the room — so that wiring in real addressed event
// routing later (agent_docs/contract.md's Extensibility section) is a small
// localized change instead of a rewrite of this path. No implementation
// yet; the relay itself doesn't exist as a running process before Phase 3.
func (r *Room) Forward(msg protocol.Envelope, to []string) {
	panic("not implemented: Phase 3")
}
