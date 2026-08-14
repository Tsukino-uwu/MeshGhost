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
	// TypeReject is the relay's reply to a Hello it refuses — wrong protocol
	// version, mismatched game_id/game_version for the room, a wrong room
	// code, or a full room. Sent before the relay closes the connection, so
	// a client can distinguish "refused, and why" from "the relay is just
	// slow" or "the relay is down" instead of only ever seeing a bare
	// hangup. Added alongside room-code auth — see the ADR in
	// agent_docs/architecture.md.
	TypeReject MessageType = "reject"
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
	// RoomCode is a shared secret the relay compares (constant-time)
	// against its own configured code before allowing a join. An empty
	// configured code on the relay means auth is off — the pre-existing,
	// still-supported posture for a friend-hosted session where a bare
	// address is enough. Crosses the wire in plaintext, same as every other
	// field here: internal/transport has no TLS, so this raises the bar
	// from "anyone with the address" to "anyone with the address and the
	// code," not to "safe against a network-level attacker." See
	// internal/README.md and the ADR in agent_docs/architecture.md.
	RoomCode string `json:"room_code,omitempty"`
	// GameVersion is the adapter-reported game/DLC version, opaque to the
	// relay and core (same discipline as GameID/AreaID/Anim — compared only
	// by equality, never parsed). Empty means "unknown" and is not checked,
	// matching how a room's first Hello with no game_id would behave — see
	// the ADR in agent_docs/architecture.md.
	GameVersion string `json:"game_version,omitempty"`
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

// Reject is the relay's reply to a Hello it refuses to accept — see
// TypeReject. Sent once, immediately before the relay closes the
// connection.
type Reject struct {
	Reason string `json:"reason"`
}

// Reason values the relay actually sends in Reject.Reason — named so code
// on either side of the wire can compare symbolically instead of matching
// magic strings. Not a closed/coded enum: the wire itself still just
// carries plain text (a future relay could add a new reason without a
// contract change, per the forward-compatibility rule), these constants
// exist only for the Go call sites that need to tell a few of them apart —
// e.g. internal/core deciding whether a rejection is worth retrying
// (ReasonRoomFull can resolve on its own if someone leaves; every other
// reason here requires a config change first). Added alongside room-code
// auth, see the ADR in agent_docs/architecture.md.
const (
	ReasonProtocolVersionMismatch = "protocol version mismatch"
	ReasonHelloFieldTooLong       = "hello field too long"
	ReasonInvalidRoomCode         = "invalid room code"
	ReasonGameMismatch            = "game mismatch for this room"
	ReasonGameVersionMismatch     = "game version mismatch for this room"
	ReasonRoomFull                = "room full"
)

// Join announces a peer entering the room. State is reserved for seeding a
// newly-visible remote ghost with its most recent known state, but
// internal/relay does not track or populate it today — every Join it sends
// has State == nil (found stale in a review pass; the receiving side,
// internal/core, already handles a populated State correctly if a future
// relay change starts sending one).
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
