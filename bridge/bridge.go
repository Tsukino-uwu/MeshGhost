// Package bridge defines the message shapes exchanged between an adapter
// and its local core process — the "adapter bridge" in agent_docs/contract.md.
// Same NDJSON framing as the relay protocol (transport), but this
// is a separate, localhost-only channel: an adapter may hold a socket to
// its own local core and nothing else. It never speaks protocol's
// relay messages directly.
//
// Three of these message shapes are the wire form of the three-function
// adapter interface from the brief (get_local_state / render_remote /
// despawn_remote). A real adapter (BizHawk Lua, or any future host) speaks
// this wire protocol; it does not implement a Go interface - see
// core.Adapter for the one Go interface in this project, which is
// scoped to the Phase 5 in-process test adapter only, not to real adapters.
//
// Hello, BridgeReady and Reject are connection setup: Hello comes first,
// before any LocalState, and declares which game this adapter is for. The
// event/lease/escrow/world pairs exist only for an adapter that asked for
// the matching capability, and an adapter that asked for none never sees
// them - the shipped cosmetic default is exactly the three above.
//
// How this package fits the whole -- the life of a connection and of a state
// message, traced across all of them -- is docs/networking.md.
package bridge

import (
	"encoding/json"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
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
	// The planes past cosmetic, added 2026-08-17 — see
	// agent_docs/beyond-cosmetic.md and the ADR in agent_docs/architecture.md.
	// An adapter that never sends one of these, and never asks for the
	// matching capability in its Hello, is completely unaffected by their
	// existence: the core forwards nothing it never receives.
	//
	// TypeEvent travels in BOTH directions, the only bridge message that
	// does. That asymmetry with local_state/render_remote is inherent rather
	// than a shortcut: the state plane is a one-way sample of the local
	// player pushed up and a one-way render of remotes pushed down, whereas
	// an event is a message between two players and has no natural direction.
	TypeEvent MessageType = "event"
	// TypeLease and TypeEscrow are adapter -> core requests; TypeLeaseState
	// and TypeEscrowState are the core -> adapter answers. Deliberately
	// separate types per direction, rather than one echoed shape: a request
	// and a fact about the room are different things, and an adapter that
	// mixes them up would act on its own unanswered claim.
	TypeLease       MessageType = "lease"
	TypeLeaseState  MessageType = "lease_state"
	TypeEscrow      MessageType = "escrow"
	TypeEscrowState MessageType = "escrow_state"
	// TypeWorld is an adapter -> core write against one entity the relay holds
	// custody of; TypeWorldState is the core -> adapter report. Same
	// request/fact split as lease above, and for the same reason: a write is
	// this adapter's intent, a WorldState is what the room actually agreed on,
	// and an adapter that conflated them would draw an entity its own write
	// was denied.
	TypeWorld      MessageType = "world"
	TypeWorldState MessageType = "world_state"
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
// Hello's game_id (protocol.Hello) and never inspected — same
// opaque-string rule as area_id/anim, per CLAUDE.md and
// agent_docs/contract.md. Lets the core defer connecting to the relay until
// an adapter actually shows up and says what game it is, instead of the
// user having to type it into a config file — see
// agent_docs/architecture.md's ADR.
type Hello struct {
	GameID string `json:"game_id"`
	// GameVersion is the adapter-reported game/DLC version, opaque to the
	// core the same way GameID is — forwarded verbatim into the relay
	// Hello's game_version (protocol.Hello) and never inspected.
	// Empty means "unknown"; core.Core.GameVersion can override
	// whatever the adapter reports, mirroring how -game/config already lets
	// a caller with no real adapter attached force a game_id. Added
	// alongside room-code auth — see the ADR in agent_docs/architecture.md.
	GameVersion string `json:"game_version,omitempty"`
	// Features is what this adapter asks the core to negotiate with the relay
	// on its behalf (protocol's Feature* constants). Opaque here in
	// the same sense GameID is — the core merges it with its own configured
	// list and forwards the union, never inspecting an individual name.
	//
	// An adapter having a say in this is not a breach of "an adapter has no
	// say in how the core reaches the relay": a capability is a statement
	// about what this adapter can do, which nothing else can know, whereas
	// the address, transport and rate are properties of the connection and
	// remain entirely the core's. An adapter still never learns a relay
	// address and never sends a byte off-machine.
	//
	// Absent, the default, means "cosmetic only" and is what every shipped
	// adapter sends — leaving the client wire-compatible with any room, since
	// a room's feature set is matched exactly.
	Features []string `json:"features,omitempty"`
}

// Event is one event-plane message, in either direction. Adapter -> core it
// is an outbound event (To, CorrID and Payload are read; From and Seq are
// ignored and stamped by the relay); core -> adapter it is an inbound one,
// fully stamped.
//
// Payload is opaque end to end. A game-specific schema — a trade offer, a
// battle turn — lives entirely inside the adapter that defines it and is
// never understood by the core or the relay, which is the same rule that
// keeps them game-agnostic for area_id and anim.
type Event struct {
	protocol.Event
}

// Lease is an adapter -> core lease request over an opaque key.
//
// **Ask before acting, never announce after.** The answer comes back as a
// LeaseState, asynchronously; an adapter that acts locally and then claims
// has put the relay's refusal after the fact is already on screen, which is a
// rollback problem this project does not solve.
type Lease struct {
	protocol.Lease
}

// LeaseState is the core -> adapter answer: who holds a key right now.
type LeaseState struct {
	protocol.LeaseState
}

// Escrow is an adapter -> core step in a two-sided atomic exchange.
type Escrow struct {
	protocol.Escrow
}

// EscrowState is the core -> adapter report on an exchange. An adapter
// applies the swap on phase "committed" and on no other phase, because every
// other one can still end in an abort.
type EscrowState struct {
	protocol.EscrowState
}

// World is an adapter -> core write against one entity, under an authority
// lease this adapter must already hold. Accepted only from that lease's
// holder, so an adapter that has not claimed (or has just lost) the authority
// gets a WorldState carrying protocol.WorldDenied rather than silence.
type World struct {
	protocol.World
}

// WorldState is the core -> adapter report: a live write from the current
// host, the whole world on adoption or join, or a refusal.
//
// **An adapter applies these in Seq order and ignores anything older than what
// it already applied for a key.** The relay guarantees a total order, but the
// reliable and lossy planes are independent on a datagram transport, so a lossy
// write can still land ahead of the reliable snapshot meant to seed it. The
// stamp is what makes that recoverable rather than silently wrong.
type WorldState struct {
	protocol.WorldState
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
