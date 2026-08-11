// Package protocol defines the wire-level message shapes shared by the relay
// protocol and the adapter bridge, per agent_docs/contract.md.
//
// This package has no internal dependencies — it is the lowest layer, pure
// data types and JSON tags. Nothing here has behavior; framing, transport,
// and dispatch live in other packages.
package protocol

import "encoding/json"

// Version is the current protocol major version, carried in Hello and
// checked by the relay per the versioning rule in agent_docs/contract.md.
const Version = 1

// State is the packet schema's snapshot payload — the "state" message body,
// and the payload type of the adapter bridge's LocalState/RenderRemote
// messages (see internal/bridge). Field-for-field match to the schema table
// in agent_docs/contract.md; do not add fields here without a contract
// revision recorded as an ADR in agent_docs/architecture.md.
type State struct {
	PlayerID string `json:"player_id"`
	Seq      uint64 `json:"seq"`
	// Timestamp is milliseconds, consistent per client. See contract.md's
	// open question on whether this is wall-clock or client-relative —
	// unresolved until Phase 1.
	Timestamp int64 `json:"timestamp"`
	// AreaID is opaque. Compare by equality only; never branch on contents
	// outside the adapter that produced it.
	AreaID string `json:"area_id"`
	// Position is variable-length by design — 2 floats for Emerald, 3 for
	// 3D games. Do not fix this at a specific length.
	Position []float64 `json:"position"`
	// Orientation is optional and opaque (scalar, vector, or quaternion
	// depending on the adapter). json.RawMessage preserves whatever shape
	// the adapter sent without the core needing to understand it.
	Orientation json.RawMessage `json:"orientation,omitempty"`
	// Anim is opaque. Compare by equality only; tags are only ever
	// meaningful between two clients running the same game_id.
	Anim string `json:"anim"`
	// Extras is free-form, game-specific, and opaque to the core.
	Extras map[string]any `json:"extras,omitempty"`
}

// MessageType identifies the payload shape of an Envelope.
type MessageType string

const (
	TypeHello   MessageType = "hello"
	TypeWelcome MessageType = "welcome"
	TypeJoin    MessageType = "join"
	TypeLeave   MessageType = "leave"
	TypeState   MessageType = "state"
	// TypeEvent is reserved and not implemented. See the Extensibility
	// section of agent_docs/contract.md — the payload is opaque to the core
	// and relay by design, and routing for it does not exist yet.
	TypeEvent MessageType = "event"
	TypePing  MessageType = "ping"
	TypePong  MessageType = "pong"
)

// Envelope is the outer shape of every relay-protocol and bridge message.
// Payload is decoded based on Type; unknown Type values are ignored per the
// forward-compatibility rule in agent_docs/contract.md, not treated as an
// error.
type Envelope struct {
	Type    MessageType     `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// Hello is sent by a client to the relay to join a room.
type Hello struct {
	ProtocolVersion int    `json:"protocol_version"`
	GameID          string `json:"game_id"`
	Room            string `json:"room"`
	DisplayName     string `json:"display_name"`
	// Features is a capability list a client advertises. Reserved: nothing
	// populates or consumes real values yet. See contract.md's Features
	// section for why this field exists before anything uses it.
	Features []string `json:"features,omitempty"`
}

// Welcome is the relay's reply to a successful Hello.
type Welcome struct {
	PlayerID string   `json:"player_id"`
	Roster   []string `json:"roster"`
}

// Join announces a peer entering the room, with its most recent state if
// known — this is what a client uses to seed a newly-visible remote ghost.
type Join struct {
	PlayerID string `json:"player_id"`
	State    *State `json:"state,omitempty"`
}

// Leave announces a peer leaving the room. This is what drives
// despawn_remote on the adapter side of the bridge.
type Leave struct {
	PlayerID string `json:"player_id"`
}

// Event is reserved and not implemented — see agent_docs/contract.md's
// Extensibility section. Payload is opaque to the core and relay; To is the
// addressee, or empty for room broadcast. No code sends, routes, or
// consumes this type yet.
type Event struct {
	To      string          `json:"to,omitempty"`
	Payload json.RawMessage `json:"payload"`
}

// Ping/Pong are the liveness check; RTT derived from them feeds the
// interpolation delay per agent_docs/contract.md.
type Ping struct {
	Nonce uint64 `json:"nonce"`
}

type Pong struct {
	Nonce uint64 `json:"nonce"`
}
