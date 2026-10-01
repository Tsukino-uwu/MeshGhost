// Package bridge defines the message shapes exchanged between an adapter and its local core: the adapter bridge. It
// uses the relay protocol's NDJSON framing but is a separate, localhost-only channel; an adapter holds a socket to its
// own local core and nothing else, and never speaks the relay's messages.
//
// LocalState, RenderRemote and DespawnRemote are the wire form of the three-function adapter interface
// (get_local_state, render_remote, despawn_remote). A real adapter speaks this wire protocol, not a Go interface;
// core.Adapter serves in-process test hosts only.
//
// Hello comes first and declares the game, and BridgeReady or Reject answers it. The event, lease, escrow and world
// messages exist only for an adapter that asked for the matching capability; the cosmetic default is the three above.
package bridge

import (
	"encoding/json"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The seven types below that only embed one protocol type (Event, Lease, LeaseState, Escrow, EscrowState, World,
// WorldState) are load-bearing: their own names keep the bridge and relay channels from sharing a Go type by accident,
// and each carries its adapter-facing rule on the type the adapter receives. Copying the fields out instead would give
// internal/gameblind's frozen wire-field check two places to disagree.

// MessageType identifies which bridge message an Envelope carries. It is distinct from protocol.MessageType because
// the bridge is a separate channel, not a reuse of the relay's vocabulary.
type MessageType string

const (
	TypeHello         MessageType = "hello"
	TypeLocalState    MessageType = "local_state"
	TypeRenderRemote  MessageType = "render_remote"
	TypeDespawnRemote MessageType = "despawn_remote"
	// TypeRemoteName carries a peer's nametag once, when it is learned. It is not a render_remote field because that
	// is sent every frame per peer.
	TypeRemoteName MessageType = "remote_name"
	// TypeBridgeReady and TypeReject are the core's two answers to a Hello.
	TypeBridgeReady MessageType = "bridge_ready"
	TypeReject      MessageType = "reject"
	// TypeReplayControl is adapter -> core: an in-game binding for the core's replay hotkeys. Optional.
	TypeReplayControl MessageType = "replay_control"
	// TypePlayerFrozen is adapter -> core, sent on change: the game holds the player still outside gameplay (an item
	// popup, the pause menu). Only the chaser pack reads it, stopping its clock so a pause costs it no delay; the
	// recorder, the replay ghosts and the wire ignore it. Optional.
	TypePlayerFrozen MessageType = "player_frozen"
	// TypeChaserReset is adapter -> core, with no payload: start the chaser pack over, sent where the game restarts
	// the player (a death that reloads the level). The ghosts and their recording go, and a fresh pack waits for the
	// spawn delay again. Why it was sent stays the adapter's fact. Optional.
	TypeChaserReset MessageType = "chaser_reset"
	// TypeInputSample is adapter -> core: what the player pressed, as a track beside the state recording and never a
	// field on state, since inputs change at frame rate. The core only records it; driving the local player from it
	// is forbidden in anything that ships. Optional.
	TypeInputSample MessageType = "input_sample"
	// TypeRemoteInput is core -> adapter: a replay ghost's recorded input track, streamed beside its frames, with At
	// the one value the core adds. Sent only to an adapter whose hello set InputTracks, and never on the wire.
	TypeRemoteInput MessageType = "remote_input"
	// TypeSessionPolicy is core -> adapter: the room-wide rules the host set, which only the adapter can apply.
	TypeSessionPolicy MessageType = "session_policy"
	// TypeRecordingState is core -> adapter, sent on change: whether a recording is running. The hotkeys live in the
	// core, which cannot draw, so this is how an adapter shows a recording toggle. State rather than an event, so an
	// adapter that attaches mid-recording still learns it.
	TypeRecordingState MessageType = "recording_state"
	// The planes past cosmetic: an adapter that never sends these and never asks for the capability in its Hello is
	// unaffected by them.
	//
	// TypeEvent is the one bridge message that travels in both directions: an event is between two players and has no
	// natural direction.
	TypeEvent MessageType = "event"
	// TypeLease and TypeEscrow are adapter -> core requests; TypeLeaseState and TypeEscrowState are the answers. A
	// request and a fact about the room are separate types so an adapter cannot act on its own unanswered claim.
	TypeLease       MessageType = "lease"
	TypeLeaseState  MessageType = "lease_state"
	TypeEscrow      MessageType = "escrow"
	TypeEscrowState MessageType = "escrow_state"
	// TypeWorld is an adapter -> core write against one entity the relay holds custody of; TypeWorldState is what the
	// room agreed on, kept apart for the same reason, so an adapter never draws an entity its own write was denied.
	TypeWorld      MessageType = "world"
	TypeWorldState MessageType = "world_state"
)

// Envelope is the outer shape of every bridge message, one per NDJSON line. It is its own type rather than
// protocol.Envelope so the two channels never share a Go type.
type Envelope struct {
	Type    MessageType     `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// Hello is the adapter's first message on a bridge connection, declaring which game it is for, so the core connects to
// the relay only once an adapter says what game it is. GameID is opaque: the core forwards it into the relay Hello's
// game_id and never inspects it.
type Hello struct {
	GameID string `json:"game_id"`
	// GameVersion is the adapter-reported game version, opaque and forwarded like GameID; empty means unknown, and
	// core.Core.GameVersion overrides it.
	GameVersion string `json:"game_version,omitempty"`
	// Features are the capabilities this adapter asks the core to negotiate for it (protocol's Feature* constants),
	// merged with the core's own list and never inspected. A capability is something only the adapter can know; the
	// address, transport and rate stay the core's. Absent means cosmetic only, compatible with any room.
	Features []string `json:"features,omitempty"`

	// MinProtocolVersion is the oldest relay this adapter works with: an adapter that depends on a field an older
	// relay does not forward would otherwise connect and silently miss it. A floor, only ever stricter than
	// protocol.MinProtocolVersion, which the core enforces first; absent or 0 means no opinion. It is raised by hand,
	// only for a major or security update to the adapter, to the client's version at that time.
	MinProtocolVersion int `json:"min_protocol_version,omitempty"`

	// RenderAllAreas asks the core to deliver every remote's state regardless of area and leave area-based despawns to
	// the adapter, for an adapter that translates a neighbouring map's coordinates itself. Adapter-local, not a room
	// feature, so it never fragments room compatibility; an adapter that sets it takes over all area-based hiding.
	RenderAllAreas bool `json:"render_all_areas,omitempty"`

	// InterpolateOrientation asks the core to include the orientation bracket (RenderRemote's OrientationFrom,
	// OrientationTo and InterpT) on every render_remote. Opt-in to save bridge bytes, since only an adapter with
	// continuous orientation can use it, and an adapter that sets it must interpolate. Adapter-local, not a room
	// feature.
	InterpolateOrientation bool `json:"interpolate_orientation,omitempty"`

	// InputTracks asks the core to stream a replay ghost's recorded input track as remote_input messages; off, the
	// core never looks for a track. Adapter-local, not a room feature.
	InputTracks bool `json:"input_tracks,omitempty"`
}

// Event is one event-plane message, in either direction. Adapter -> core, To, CorrID and Payload are read and the
// relay stamps From and Seq; core -> adapter it arrives fully stamped. Payload is opaque to the core and the relay.
type Event struct {
	protocol.Event
}

// Lease is an adapter -> core lease request over an opaque key. Ask before acting: the answer arrives later as a
// LeaseState, and acting first puts a refusal after something already on screen.
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

// EscrowState is the core -> adapter report on an exchange. An adapter applies the swap on phase "committed" and on no
// other phase, because every other one can still end in an abort.
type EscrowState struct {
	protocol.EscrowState
}

// World is an adapter -> core write against one entity, under an authority lease this adapter must already hold. From
// anyone but that lease's holder it is answered with a WorldState carrying protocol.WorldDenied.
type World struct {
	protocol.World
}

// WorldState is the core -> adapter report: a live write from the current host, the whole world on adoption or join,
// or a refusal. Apply these in Seq order and ignore anything older than what was applied for a key: on a datagram
// transport a lossy write can land ahead of the reliable snapshot meant to seed it.
type WorldState struct {
	protocol.WorldState
}

// BridgeReady is the core's answer to an accepted Hello: this core is available and now yours. An adapter walking a
// range of ports cannot tell acceptance from silence, so success is explicit. It carries no payload.
type BridgeReady struct{}

// RecordingState is the payload of TypeRecordingState. StartedUnixMs is when the recording began (0 when not
// recording), so the adapter counts the elapsed time itself and one that attaches mid-recording shows the true time;
// the bridge is loopback, so both ends share the wall clock.
type RecordingState struct {
	Recording     bool  `json:"recording"`
	StartedUnixMs int64 `json:"started_unix_ms,omitempty"`
}

// SessionPolicy is core -> adapter: the room-wide policy for this session, resolved from what the relay advertised and
// this client's own config. It is a message rather than a BridgeReady field because the core can re-handshake with the
// relay without the adapter reconnecting, so the policy can change mid-session. Sent after BridgeReady once the room's
// policy is known, and again on every change; the core expects no reply.
type SessionPolicy struct {
	// GhostCollision is protocol.GhostCollisionEnabled or protocol.GhostCollisionDisabled, never empty: the core
	// resolves the unset case. Enabled leaves the adapter's own defaults standing and never demands a solid ghost;
	// disabled is binding, no ghost blocks anything. An adapter that cannot honour disabled says so once in its log.
	GhostCollision string `json:"ghost_collision"`
	// ChaserContact is "hurt" or "kill" when the player turned the chaser's contact hook on, absent otherwise: hurt is
	// what an enemy's touch does in this game, kill a guaranteed death. It applies to chaser ghosts only (ids
	// `chaser:<n>`), and an adapter honours it through the game's own damage or death path, never by writing health.
	// Every other cosmetic rule (never solid, blocking, damageable, targetable) still holds.
	ChaserContact string `json:"chaser_contact,omitempty"`
}

// ReplayControl is adapter -> core: one replay action from an in-game binding of the adapter's own. Action is one of
// record_start, record_stop, record_toggle, save_last, replay_last, restart, rewind, fast_forward (core.ReplayAction);
// Seconds applies to rewind and fast_forward, 0 meaning the configured seek. The core logs the outcome and sends no
// reply. It adds to the core's hotkeys and never replaces them.
type ReplayControl struct {
	Action  string `json:"action"`
	Seconds int    `json:"seconds,omitempty"`
}

// PlayerFrozen is the payload of TypePlayerFrozen: true while the game holds the player still outside gameplay, false
// when play resumes. Sent on change only; a repeat of the current value is harmless.
type PlayerFrozen struct {
	Frozen bool `json:"frozen"`
}

// InputSample is the payload of TypeInputSample: a batch of the moments the player's input changed. Buttons are a
// bitmask with a label table, so the core never learns what a button means and an edge stays a few bytes. The adapter
// names its own buttons, preferably from the game's merged action state rather than raw OS keys, which also cannot
// capture typing outside the game.
type InputSample struct {
	// Labels names bits 0..n-1 of each edge's Mask and Axes the slots of Ax. Sticky: sent on a connection's first
	// batch and again only on change. Opaque; the core copies them into the track's file header.
	Labels []string `json:"labels,omitempty"`
	Axes   []string `json:"axes,omitempty"`
	// Source is an opaque tag naming where the adapter read these bits, so a later reader can refuse a source it does
	// not understand.
	Source string `json:"source,omitempty"`
	// Drop is how many edges the adapter dropped since the last batch because its queue was full, so a reader can tell
	// a lossy region from a quiet one.
	Drop uint32 `json:"drop,omitempty"`
	// Edges are in order and never coalesced; empty only on a batch that carries Labels.
	Edges []InputEdge `json:"edges"`
}

// InputEdge is one moment the input changed. Edges, not samples, so a one-frame press is two edges with consecutive F
// and no sampling rate can erase it.
type InputEdge struct {
	// F is the adapter's own frame counter and T its own millisecond stamp, both monotonic and kept verbatim: the core
	// stamps each batch on receipt, and F keeps the frame spacing inside a batch.
	F uint64 `json:"f"`
	T int64  `json:"t"`
	// M is the button mask, bit i meaning Labels[i], compared only for equality. 32 bits because a JSON number is a
	// float64 to every reader but Go.
	M uint32 `json:"m"`
	// Ax are the analog axes, quantized by the adapter; absent means unchanged since the previous edge.
	Ax []float64 `json:"ax,omitempty"`
}

// RemoteInput is core -> adapter: a window of a replay ghost's recorded input edges, ahead of when they are due. The
// adapter buffers them per player and applies each on the first render_remote whose state.timestamp reaches its At.
// Labels, Axes and Source are the track's header, sticky, sent after every Reset. A Reset (the clip started, looped or
// was seeked) or a despawn_remote means drop every edge held for this player.
type RemoteInput struct {
	PlayerID string            `json:"player_id"`
	Labels   []string          `json:"labels,omitempty"`
	Axes     []string          `json:"axes,omitempty"`
	Source   string            `json:"source,omitempty"`
	Reset    bool              `json:"reset,omitempty"`
	Edges    []RemoteInputEdge `json:"edges"`
}

// RemoteInputEdge is one InputEdge plus At, the one value the core adds: the render-clock time the edge is due,
// rebased like the clip's samples (start, speed, trim, skip_gaps).
type RemoteInputEdge struct {
	F  uint64    `json:"f"`
	T  int64     `json:"t"`
	M  uint32    `json:"m"`
	Ax []float64 `json:"ax,omitempty"`
	At int64     `json:"at"`
}

// Reject is core -> adapter when a Hello cannot be accepted, just before the core closes the connection. Reason is a
// sentence for the adapter's log; Code is what an adapter branches on.
type Reject struct {
	Reason string `json:"reason"`
	// Code is the stable, machine-readable name for this refusal. Never match Reason's text instead: every permanent
	// refusal contains "relay" and busy does not. Empty means an older core; an unknown code falls back to Retryable.
	Code string `json:"code,omitempty"`
	// Retryable says whether reconnecting could succeed without the player changing something: false for a wrong room
	// code, true for a full room.
	Retryable bool `json:"retryable,omitempty"`
}

// Reject codes an adapter may branch on. These name the core's own refusals; a relay refusal carries the relay's code
// through unchanged (protocol's Code* constants). Frozen once shipped: adapters compare against these literals.
const (
	// CodeBusy means this core already has a game attached, so the adapter tries the next port. Retryable is false:
	// retrying this core is pointless, which is a different question from looking elsewhere.
	CodeBusy = "busy"
	// CodeAlreadyServing means this core serves a different game_id: walk on, and a second core for the other game is
	// the answer.
	CodeAlreadyServing = "already_serving"
)

// LocalState is adapter -> core once per adapter frame, the wire form of get_local_state(). A nil State means don't
// send this frame (the player is in a menu or another non-renderable state).
type LocalState struct {
	State *protocol.State `json:"state"`
}

// RenderRemote is core -> adapter at frame rate, already interpolated: an upsert into the set of remote ghosts the
// adapter owns and redraws every frame, not a one-shot draw call. State is a value, not a pointer: a nil would reach
// an adapter whose only way to draw nothing is a despawn.
type RenderRemote struct {
	PlayerID string         `json:"player_id"`
	State    protocol.State `json:"state"`
	// The orientation bracket: the two opaque orientation blobs State's position was interpolated between, and the
	// fraction between them; all absent when the core has no honest pair, which means use State.Orientation. The core
	// cannot parse an orientation, so facing steps at the send rate; an adapter with continuous rotation interpolates
	// From to To at InterpT itself, shortest-arc. InterpT can exceed 1 under -extrapolate. Bridge-only, never on
	// protocol.State. The blobs are peer-controlled, bounded only by protocol.MaxOrientationBytes: parse defensively.
	OrientationFrom json.RawMessage `json:"orientation_from,omitempty"`
	OrientationTo   json.RawMessage `json:"orientation_to,omitempty"`
	InterpT         float64         `json:"interp_t,omitempty"`
	// Cosmetic is true for a ghost this core invented (a replay or a chaser) and absent for a real peer. An adapter
	// treats it as a picture, never solid, blocking, damageable or targetable, whatever ghost_collision says. Sent per
	// frame because the first render_remote is how an adapter learns a peer exists. Never on the network.
	Cosmetic bool `json:"cosmetic,omitempty"`
}

// RemoteName is core -> adapter when a peer's nametag becomes known: on join, and for everyone present when this
// adapter attaches. An empty DisplayName, the default, means draw no nametag at all. The relay and then the core
// sanitize it; render it as plain text only, never through a markup-capable path. Never an identity: PlayerID is.
type RemoteName struct {
	PlayerID    string `json:"player_id"`
	DisplayName string `json:"display_name"`
	// Color is "#RRGGBB", or empty for the adapter's own default; six hex digits, so it reads with no parser.
	Color string `json:"color,omitempty"`
}

// DespawnRemote is core -> adapter: remove a ghost from the set render_remote fills, sent on the first frame a ghost
// drawn before is no longer rendered (it left, changed area or went silent).
type DespawnRemote struct {
	PlayerID string `json:"player_id"`
}
