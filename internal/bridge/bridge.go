// Package bridge defines the message shapes exchanged between an adapter
// and its local core process — the "adapter bridge" in agent_docs/contract.md.
// Same NDJSON framing as the relay protocol (internal/transport), but this
// is a separate, localhost-only channel: an adapter may hold a socket to
// its own local core and nothing else. It never speaks internal/protocol's
// relay messages directly.
//
// Three of these four message shapes are the wire form of the three-function
// adapter interface from the brief (get_local_state / render_remote /
// despawn_remote). A real adapter (BizHawk Lua, or any future host) speaks
// this wire protocol; it does not implement a Go interface — see
// internal/core.Adapter for the one Go interface in this project, which is
// scoped to the Phase 5 in-process test adapter only, not to real adapters.
// The fourth, Hello, is connection setup: it comes first, before any
// LocalState, and declares which game this adapter is for.
package bridge

import (
	"encoding/json"

	"meshghost/internal/protocol"
)

// MessageType identifies which of the bridge message shapes an Envelope
// carries. Deliberately distinct from protocol.MessageType: the bridge is a
// separate, private channel per agent_docs/contract.md's "two protocols"
// section, not a reuse of the relay's message vocabulary, even though both
// use the same {type, payload} envelope shape.
type MessageType string

const (
	TypeHello         MessageType = "hello"
	TypeLocalState    MessageType = "local_state"
	TypeRenderRemote  MessageType = "render_remote"
	TypeDespawnRemote MessageType = "despawn_remote"
	// TypeBridgeReady and TypeReject are the core's two possible answers to a
	// Hello, added 2026-08-16 so an adapter can tell whether a core is actually
	// available to it -- see BridgeReady's doc comment for why silence was not
	// good enough.
	TypeBridgeReady MessageType = "bridge_ready"
	TypeReject      MessageType = "reject"
)

// Envelope is the outer shape of every bridge message, one per NDJSON
// line. Kept as its own type (rather than reusing protocol.Envelope) so
// the two channels never share a Go type by accident.
type Envelope struct {
	Type    MessageType     `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// Hello is sent adapter -> core as the first message on a new bridge
// connection, before any LocalState, declaring which game this adapter is
// for. Opaque to the core: GameID is forwarded verbatim into the relay
// Hello's game_id (internal/protocol.Hello) and never inspected — same
// opaque-string rule as area_id/anim, per CLAUDE.md and
// agent_docs/contract.md. Lets the core defer connecting to the relay until
// an adapter actually shows up and says what game it is, instead of the
// user having to type it into a config file — see
// agent_docs/architecture.md's ADR.
type Hello struct {
	GameID string `json:"game_id"`
	// GameVersion is the adapter-reported game/DLC version, opaque to the
	// core the same way GameID is — forwarded verbatim into the relay
	// Hello's game_version (internal/protocol.Hello) and never inspected.
	// Empty means "unknown"; internal/core.Core.GameVersion can override
	// whatever the adapter reports, mirroring how -game/config already lets
	// a caller with no real adapter attached force a game_id. Added
	// alongside room-code auth — see the ADR in agent_docs/architecture.md.
	GameVersion string `json:"game_version,omitempty"`
}

// BridgeReady is sent core -> adapter as the answer to an accepted Hello:
// this core is available and is now yours.
//
// It exists because the bridge had no positive acknowledgement at all. A core
// only ever sent RenderRemote/DespawnRemote, and only once a peer existed, so
// an adapter could not tell "accepted" from "still starting up" from "wrong
// program listening on this port" -- it could only infer success from silence
// over time. That guess became unaffordable once adapters started walking a
// range of ports looking for a free core (agent_docs/architecture.md's
// probe-upward ADR): silence is exactly what a busy core used to answer with.
//
// Deliberately carries no payload fields. It answers one question -- may I use
// you -- and anything else worth knowing (the game, the relay) is already
// either the adapter's own input or none of its business.
type BridgeReady struct{}

// Reject is sent core -> adapter when a Hello cannot be accepted, immediately
// before the core closes the connection. Reason is human-readable and meant for
// the adapter's log, not for branching on: an adapter's correct response to any
// rejection is the same, which is to try the next port.
//
// Before this, a refused Hello was answered by closing the socket with no
// explanation, which an adapter could not distinguish from a crashed core, a
// core still binding its port, or an unrelated program. That silence is what
// made "two games at once" fail invisibly.
type Reject struct {
	Reason string `json:"reason"`
}

// LocalState is sent adapter -> core once per adapter frame tick, the wire
// form of get_local_state(). State == nil means "don't send this frame"
// (e.g. player in a menu or other non-renderable state — see the open
// question in agent_docs/contract.md).
type LocalState struct {
	State *protocol.State `json:"state"`
}

// RenderRemote is sent core -> adapter. Per the tick model in
// agent_docs/contract.md, this is an *upsert* into a set of remote ghosts
// the adapter owns and redraws every frame — not a one-shot draw call. The
// core pushes this at frame rate, already interpolated.
type RenderRemote struct {
	PlayerID string         `json:"player_id"`
	State    protocol.State `json:"state"`
}

// DespawnRemote is sent core -> adapter to remove an entry from that set,
// driven by a relay Leave message reaching the core.
type DespawnRemote struct {
	PlayerID string `json:"player_id"`
}
