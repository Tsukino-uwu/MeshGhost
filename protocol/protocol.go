// Package protocol defines the wire-level message shapes shared by the relay protocol and the adapter bridge.
//
// It is the lowest layer, with no internal dependencies. Its behaviour is limited to validating, clamping and
// normalizing its own field values (ValidateState, ClampSendHz, NormalizeFeatures, ResolveGhostCollision and the
// rest); framing, transport and dispatch live in other packages.
package protocol

import "encoding/json"

// Version is the protocol version this build sends, in Hello and in Welcome. Acceptance is checked against
// MinProtocolVersion, a separate number.
const Version = 3

// MinProtocolVersion is the oldest peer this build talks to, on either side: a relay accepts a client at or above
// it, and a core accepts a relay at or above it. Compare against this floor, never against Version, which would be
// an exact match in disguise.
//
// Raise it only when the wire changes in a way older builds cannot survive, as the maintainer's decision, client and
// relay together. An adapter's own floor (bridge.Hello.MinProtocolVersion) is the knob for "this mod needs a newer
// relay", and it can only tighten.
const MinProtocolVersion = 3

// State is the packet schema's snapshot payload: the "state" message body, and the payload of the bridge's
// LocalState/RenderRemote messages. Field for field the contract's schema table; a new field is a contract revision.
type State struct {
	PlayerID string `json:"player_id"`
	Seq      uint64 `json:"seq"`
	// Timestamp is wall-clock milliseconds. Peers' clocks must agree: skew silently drops interpolation to an edge
	// snapshot every tick (core/interp.go's remoteBuffer.at) rather than failing.
	Timestamp int64 `json:"timestamp"`
	// AreaID is opaque: compare by equality only.
	AreaID string `json:"area_id"`
	// Position is variable-length by design (2 floats for a 2D game, 3 for 3D); never fix its length.
	Position []float64 `json:"position"`
	// Orientation is optional and opaque: RawMessage keeps whatever shape the adapter sent.
	Orientation json.RawMessage `json:"orientation,omitempty"`
	// Anim is opaque: compare by equality only, and only between clients of the same game_id.
	Anim string `json:"anim"`
	// Extras is free-form, game-specific, and opaque to the core.
	Extras map[string]any `json:"extras,omitempty"`
	// Prev is the sender's previous sample as a delta against this one, loss cover for the lossy state plane
	// (prev.go). The relay forwards it untouched and never stores it; older peers ignore it.
	Prev *StatePrev `json:"prev,omitempty"`
}

// MessageType identifies the payload shape of an Envelope.
type MessageType string

const (
	TypeHello   MessageType = "hello"
	TypeWelcome MessageType = "welcome"
	TypeJoin    MessageType = "join"
	TypeLeave   MessageType = "leave"
	TypeState   MessageType = "state"
	// TypeEvent is the event plane: reliable, ordered, addressed, with a payload opaque to the core and relay.
	// Routed only in a room whose agreed features contain FeatureEventV1.
	TypeEvent MessageType = "event"
	// TypeLease and TypeLeaseState are lease authority over opaque keys, gated on FeatureLeaseV1.
	TypeLease      MessageType = "lease"
	TypeLeaseState MessageType = "lease_state"
	// TypeEscrow and TypeEscrowState are two-sided atomic exchange, both or neither, gated on FeatureEscrowV1.
	TypeEscrow      MessageType = "escrow"
	TypeEscrowState MessageType = "escrow_state"
	// TypeWorld and TypeWorldState are world custody, so a host leaving does not take the world with it. Gated on
	// FeatureWorldV1, which requires FeatureLeaseV1: a write names a lease key and is accepted only from its holder.
	TypeWorld      MessageType = "world"
	TypeWorldState MessageType = "world_state"
	TypePing       MessageType = "ping"
	TypePong       MessageType = "pong"
	// TypePrefs updates per-client settings first stated in the Hello, for when the truth is not known at connect
	// time: a core connects at startup, and its adapter attaches when the game launches. Client to relay only; an
	// older relay ignores it as an unknown type and keeps forwarding everything, which is the fail-open direction.
	TypePrefs MessageType = "prefs"
	// TypeReject is the relay's reply to a refused Hello, or its notice before closing a joined connection over the
	// message cap: sent before the close, so a client can tell "refused, and why" from a relay that is slow or down.
	TypeReject MessageType = "reject"

	// TypePake carries one step of the room-code proof (package pake): the relay's KE2 answering a hello's PakeKE1,
	// then the client's KE3. Only between a hello and its Welcome or Transports; ignored anywhere else.
	TypePake MessageType = "pake"
	// TypeTransports is the relay's reply to a Hello with QueryOnly set: which transports it serves, on which
	// ports. The relay closes right after: no room joined, no player_id assigned, nothing announced. It lets an
	// "auto" client find quic before joining, rather than joining over tcp and visibly reconnecting.
	TypeTransports MessageType = "transports"
)

// Envelope is the outer shape of every relay-protocol and bridge message. Payload is decoded by Type; an unknown
// Type is ignored, not an error, for forward compatibility.
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
	// NameColor is this client's nametag colour as "#RRGGBB" (see SanitizeNameColor), or empty for no preference.
	// Ignored when DisplayName is empty, since there is then no tag to colour.
	NameColor string `json:"name_color,omitempty"`
	// PakeKE1 is the first message of the room-code proof, base64; the code itself never crosses the wire. A relay
	// with a code refuses a hello without it, and one with none ignores it.
	PakeKE1 string `json:"pake_ke1,omitempty"`
	// GameVersion is the adapter-reported version, opaque to relay and core: compared by equality, never parsed.
	// Empty means unknown and is not checked.
	GameVersion string `json:"game_version,omitempty"`
	// Features is the capability list this client advertises. Room-scoped ones (IsRoomScopedFeature) are sticky on
	// first join and a later joiner must match them exactly (ReasonFeatureMismatch); client-scoped ones are not
	// compared.
	Features []string `json:"features,omitempty"`
	// ResumeToken asks the relay to reinstate the identity it was issued for, within DefaultResumeGrace and in the
	// same room. An unknown, expired or foreign token is not an error: the relay assigns a fresh identity.
	ResumeToken string `json:"resume_token,omitempty"`
	// MaxReceiveHz is the highest rate, per peer, at which this client wants others' state; zero means uncapped.
	// The relay drops the excess before sending, since discarding on receive would save the client nothing.
	MaxReceiveHz int `json:"max_receive_hz_per_player,omitempty"`

	// QueryOnly asks for a Transports reply and a hang-up instead of a join. Every check guarding a real join runs
	// first, so discovery adds no pre-auth surface. An older relay joins the client for real, so a client must be
	// ready for a Welcome here.
	QueryOnly bool `json:"query_only,omitempty"`

	// OwnAreaOnly declares that this client renders only peers in its own area_id, so the relay may skip the rest;
	// absent means send everything, so being wrong costs bandwidth, never ghosts. A field, not a Features entry: an
	// unrecognised feature is room-scoped and sticky, which would make a room mixed with an older relay unjoinable.
	OwnAreaOnly bool `json:"own_area_only,omitempty"`
}

// TransportOffer is one transport a relay serves. The port travels but not the host: a relay bound to 0.0.0.0
// cannot know its outside address, while the client already knows one.
type TransportOffer struct {
	// Kind is "tcp", "udp", or "quic".
	Kind string `json:"kind"`
	Port int    `json:"port"`
}

// Transports is the relay's reply to a QueryOnly Hello.
type Transports struct {
	Offers []TransportOffer `json:"offers"`
}

// Welcome is the relay's reply to a successful Hello.
type Welcome struct {
	PlayerID string   `json:"player_id"`
	Roster   []string `json:"roster"`
	// ProtocolVersion is the relay's own Version, so the floor runs both ways: a client can refuse a relay below
	// its minimum. Absent (0) means a relay older than the field, which any floor refuses.
	ProtocolVersion int `json:"protocol_version,omitempty"`
	// Nametags carries the sanitized labels of players already in the room, keyed by player_id, since a Join is
	// only sent for an arrival and names stay out of the per-frame state stream. Ids with no name are omitted.
	Nametags map[string]Nametag `json:"nametags,omitempty"`
	// SendHz is the room's state send rate in updates per second; a client adopts it unless it configured a slower
	// one. Zero means an older relay. Not omitempty: a current relay always sends a value, so a 0 is a bug to see.
	SendHz int `json:"send_hz"`
	// GhostCollision is the room's policy, resolved against the client's own with ResolveGhostCollision. omitempty,
	// unlike SendHz, because "" is a real answer: nobody set a policy.
	GhostCollision string `json:"ghost_collision,omitempty"`
	// Features is the feature set in force for this client, normalized: the room's agreed set plus this client's
	// own client-scoped ones (see Hello.Features).
	Features []string `json:"features,omitempty"`
	// ResumeToken is the secret this client presents in a later Hello to reclaim this identity after a drop, set
	// only with FeatureResumeV1. A credential: whoever holds it can take over the session, so it stays on this client.
	ResumeToken string `json:"resume_token,omitempty"`
	// Resumed reports that this Welcome reinstated an existing identity, leases and escrows included.
	Resumed bool `json:"resumed,omitempty"`
	// ServerTimeMs is the relay's wall clock in milliseconds when it sent this Welcome, the seed for clock sync.
	ServerTimeMs int64 `json:"server_time_ms,omitempty"`
}

// Reject is the relay's reply to a Hello it refuses, or its notice before closing a joined connection over the
// per-client message cap. Sent once, just before the relay closes the connection.
type Reject struct {
	Reason string `json:"reason"`
	// Code is the stable name for this refusal and the thing to branch on; Reason is prose for a log. A reader that
	// does not recognise a code falls back to Retryable, and only then to its own prose table.
	Code string `json:"code,omitempty"`
	// Retryable says whether reconnecting could succeed without the player changing anything. The zero value means
	// permanent, the conservative answer for a relay that never set it.
	Retryable bool `json:"retryable,omitempty"`
}

// Reject codes, one per Reason constant, in the same order. Frozen once shipped: renamed only by a contract
// revision, since adapters in several languages compare the literals. A new refusal gets a new code, and a reader
// that does not recognise one falls back rather than guesses, which is what makes adding one safe.
const (
	CodeProtocolVersionMismatch = "protocol_version_mismatch"
	CodeHelloFieldTooLong       = "hello_field_too_long"
	CodeInvalidRoomCode         = "invalid_room_code"
	CodeGameMismatch            = "game_mismatch"
	CodeGameVersionMismatch     = "game_version_mismatch"
	CodeFeatureMismatch         = "feature_mismatch"
	CodeGameNotAllowed          = "game_not_allowed"
	CodeServerFull              = "server_full"
	CodeRateLimited             = "rate_limited"
)

// Pake is the payload of a TypePake envelope: exactly one of the two, base64.
type Pake struct {
	KE2 string `json:"ke2,omitempty"`
	KE3 string `json:"ke3,omitempty"`
}

// MaxPakeFieldLen bounds a base64 PAKE message on the wire (Hello.PakeKE1, Pake.KE2, Pake.KE3): pake.MaxMessageLen
// bytes encoded, with room to spare. Checked with the other hello fields before anything is decoded.
const MaxPakeFieldLen = 1536

// RetryableForCode answers whether reconnecting could succeed for a known code, and whether it knows the code. One
// table for both sides, so the relay's Reject.Retryable and the core's reading cannot disagree; on known == false a
// caller falls back to Reject.Retryable. Only a full room and a rate limit are retryable; the rest need a config edit.
func RetryableForCode(code string) (retryable, known bool) {
	switch code {
	case CodeServerFull, CodeRateLimited:
		return true, true
	case CodeProtocolVersionMismatch, CodeHelloFieldTooLong, CodeInvalidRoomCode,
		CodeGameMismatch, CodeGameVersionMismatch, CodeFeatureMismatch, CodeGameNotAllowed:
		return false, true
	}
	return false, false
}

// CodeForReason maps a Reason constant to its code, for a caller that picks the refusal at runtime
// (joinOrCreateRoom). It matches the constants exactly and returns "" for anything else, so a hand-written reason
// reads as unknown rather than being mis-classified as one it resembles.
func CodeForReason(reason string) string {
	switch reason {
	case ReasonProtocolVersionMismatch:
		return CodeProtocolVersionMismatch
	case ReasonHelloFieldTooLong:
		return CodeHelloFieldTooLong
	case ReasonInvalidRoomCode:
		return CodeInvalidRoomCode
	case ReasonGameMismatch:
		return CodeGameMismatch
	case ReasonGameVersionMismatch:
		return CodeGameVersionMismatch
	case ReasonFeatureMismatch:
		return CodeFeatureMismatch
	case ReasonGameNotAllowed:
		return CodeGameNotAllowed
	case ReasonServerFull:
		return CodeServerFull
	case ReasonRateLimited:
		return CodeRateLimited
	}
	return ""
}

// AcceptsPeerVersion reports whether a peer advertising v is new enough for this build. Both ends use it, so the
// floor means one thing; v == 0 is a peer from before the field, which the plain comparison refuses.
func AcceptsPeerVersion(v int) bool { return v >= MinProtocolVersion }

// Reason values the relay sends in Reject.Reason, named so Go call sites compare symbolically. Not a closed set:
// the wire carries plain text, and a future relay may add one. A relay with no Code is classified by
// core.isPermanentRejectReason, where only ReasonServerFull and ReasonRateLimited are retryable.
const (
	ReasonProtocolVersionMismatch = "protocol version mismatch"
	ReasonHelloFieldTooLong       = "hello field too long"
	ReasonInvalidRoomCode         = "invalid room code"
	ReasonGameMismatch            = "game mismatch for this room"
	ReasonGameVersionMismatch     = "game version mismatch for this room"
	// ReasonFeatureMismatch: the client's capability set differs from the room's. Sticky like game_version, since
	// members that disagree about whether leases exist fail silently and much later.
	ReasonFeatureMismatch = "feature set mismatch for this room"
	// ReasonGameNotAllowed: the relay hosts one game (relay.Server.OnlyGame) and no room the client picks would help.
	ReasonGameNotAllowed = "game not allowed on this relay"
	// ReasonServerFull means the relay is at MaxClients across every room combined, not that one room is full.
	ReasonServerFull = "server full"
	// ReasonRateLimited: the connection exceeded the per-client message cap and is being closed. Usually sent after
	// a join, and retryable: a reconnecting client re-reads the room's send rate and may fit under the cap.
	ReasonRateLimited = "rate limited"
)

// Join announces a peer entering the room. State seeds the new ghost with its latest state, so it appears where it
// is; it is set only for a recipient that advertised FeatureSnapshotV1.
type Join struct {
	PlayerID string `json:"player_id"`
	State    *State `json:"state,omitempty"`
	// Nametag is this peer's label, sanitized by the relay; nil means draw nothing. Never an identity, and a
	// receiver sanitizes it again, since a relay is not trusted to have done so.
	Nametag *Nametag `json:"nametag,omitempty"`
}

// Nametag is what a peer chose to be labelled as: a name, and optionally a colour, which means nothing without the
// name. Both are sanitized (SanitizeDisplayName, SanitizeNameColor) before they are stored or forwarded.
type Nametag struct {
	// Name is the sanitized display name; the relay stores no tag at all when it is empty.
	Name string `json:"name"`
	// Color is "#RRGGBB", or empty for the adapter's default colour.
	Color string `json:"color,omitempty"`
}

// Leave announces a peer leaving the room, which drives despawn_remote. Also sent client to relay as a voluntary
// goodbye (PlayerID ignored): "do not hold my session for a reconnect", which resumption cannot otherwise tell from
// a bad connection.
type Leave struct {
	PlayerID string `json:"player_id"`
}

// Event is one message on the event plane: reliable, ordered, addressed, and opaque. It stays separate from the
// state plane for delivery semantics: extras is lossy and latest-wins, right for a trail colour and wrong for an
// item offer.
type Event struct {
	// To is the addressee's player_id, or empty for room broadcast: top-level because it is the one field the relay
	// reads.
	To string `json:"to,omitempty"`
	// From is the sender's player_id, stamped by the relay from the connection and never trusted from the payload.
	From string `json:"from,omitempty"`
	// Seq is the room's sequencer stamp, assigned as the recipients are snapshotted, so every member sees one total
	// order over events, leases and escrows. Distinct from State.Seq, a per-client counter on the lossy plane.
	Seq uint64 `json:"seq,omitempty"`
	// CorrID is an opaque correlation id, echoed unchanged, so an adapter can match a reply to its request.
	CorrID string `json:"corr_id,omitempty"`
	// Payload is opaque, bounded by MaxEventBytes and never fragmented: if it does not fit, send a reference.
	Payload json.RawMessage `json:"payload"`
}

// Ping keeps an otherwise-quiet connection from going idle (core.Core.sendHeartbeats) and doubles as the clock-sync
// probe: Nonce is echoed in the Pong so a client can match a reply to the send time it recorded.
type Ping struct {
	Nonce uint64 `json:"nonce"`
}

// Prefs updates settings this client stated in its Hello, typically sent when an adapter attaches. Every field is
// a pointer so absent means unchanged rather than false.
type Prefs struct {
	// OwnAreaOnly has the meaning it has on Hello: this client renders only peers sharing its area_id.
	OwnAreaOnly *bool `json:"own_area_only,omitempty"`
}

// Pong is the relay's reply to a Ping.
type Pong struct {
	Nonce uint64 `json:"nonce"`
	// ServerTimeMs is the relay's wall clock in milliseconds when it replied: with send time t0 and receive time t2,
	// RTT is t2-t0 and the offset serverTime - (t0+t2)/2. The relay is the one clock a room's members can share,
	// so none has to be right about the real time. Zero means an older relay, and no offset is applied.
	ServerTimeMs int64 `json:"server_time_ms,omitempty"`
}
