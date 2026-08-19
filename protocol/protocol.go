// Package protocol defines the wire-level message shapes shared by the relay
// protocol and the adapter bridge, per agent_docs/contract.md.
//
// This package has no internal dependencies — it is the lowest layer, pure
// data types and JSON tags. Nothing here has behavior; framing, transport,
// and dispatch live in other packages.
//
// How this package fits the whole -- the life of a connection and of a state
// message, traced across all of them -- is docs/networking.md.
package protocol

import "encoding/json"

// Version is the current protocol major version, carried in Hello and
// checked by the relay per the versioning rule in agent_docs/contract.md.
const Version = 1

// State is the packet schema's snapshot payload — the "state" message body,
// and the payload type of the adapter bridge's LocalState/RenderRemote
// messages (see bridge). Field-for-field match to the schema table
// in agent_docs/contract.md; do not add fields here without a contract
// revision recorded as an ADR in agent_docs/architecture.md.
type State struct {
	PlayerID string `json:"player_id"`
	Seq      uint64 `json:"seq"`
	// Timestamp is milliseconds, wall-clock (time.Now().UnixMilli() on
	// whichever side stamps it) — resolved in contract.md's packet-schema
	// table. Peers' wall clocks must actually agree, not just be internally
	// consistent; meaningful clock skew silently falls back to an edge
	// snapshot every tick rather than failing loudly (see
	// core/interp.go's remoteBuffer.at()).
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
	// TypeEvent is the event plane: reliable, ordered, addressed, and with a
	// payload fully opaque to the core and relay. Reserved from the start of
	// the project and implemented 2026-08-17 — see agent_docs/contract.md's
	// Extensibility section and the ADR in agent_docs/architecture.md. Only
	// routed for a room whose agreed feature set contains FeatureEventV1.
	TypeEvent MessageType = "event"
	// TypeLease and TypeLeaseState are lease authority over opaque keys:
	// the relay grants a key to the first asker and refuses the rest,
	// without ever knowing what the key means. Gated on FeatureLeaseV1.
	TypeLease      MessageType = "lease"
	TypeLeaseState MessageType = "lease_state"
	// TypeEscrow and TypeEscrowState are two-sided atomic exchange — both or
	// neither. Gated on FeatureEscrowV1. See online.go's EscrowOp for why
	// this is a separate mechanism from leases rather than a use of them.
	TypeEscrow      MessageType = "escrow"
	TypeEscrowState MessageType = "escrow_state"
	// TypeWorld and TypeWorldState are world custody: the relay holds the
	// latest opaque blob per entity and hands the same canonical set to
	// whoever takes the authority lease next, so a host leaving does not take
	// the world with it. Gated on FeatureWorldV1, which requires
	// FeatureLeaseV1 in the same room — every write names a lease key and is
	// accepted only from that lease's holder.
	TypeWorld      MessageType = "world"
	TypeWorldState MessageType = "world_state"
	TypePing       MessageType = "ping"
	TypePong       MessageType = "pong"
	// TypeReject is the relay's reply to a Hello it refuses — wrong protocol
	// version, mismatched game_id/game_version for the room, a wrong room
	// code, or a full room — or, since the send/receive rate-control feature
	// (see the ADR in agent_docs/architecture.md), a mid-session close of an
	// already-joined connection for exceeding the per-client message cap
	// (ReasonRateLimited). Sent before the relay closes the connection, so a
	// client can distinguish "refused/closed, and why" from "the relay is
	// just slow" or "the relay is down" instead of only ever seeing a bare
	// hangup. Added alongside room-code auth — see the ADR in
	// agent_docs/architecture.md.
	TypeReject MessageType = "reject"
	// TypeTransports is the relay's reply to a Hello with QueryOnly set:
	// which transports this relay serves, and on which ports. The relay
	// closes the connection immediately after sending it — no room is
	// joined, no player_id is assigned, nothing is announced to anyone.
	//
	// It exists so a client set to "auto" can discover that a relay also
	// speaks quic, and on which port, before it joins — rather than joining
	// over tcp and
	// then reconnecting — which would make every other player in the room
	// watch it leave and rejoin. The port is told rather than assumed:
	// since 2026-08-16 quic shares the relay's own port by default and
	// only moves when plain udp is also served. Added 2026-08-16; see the
	// transport discovery ADR in agent_docs/architecture.md.
	TypeTransports MessageType = "transports"
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
	// address is enough. Whether it crosses the wire readable depends on the
	// transport and the tls setting: quic is always encrypted, tcp is when
	// tls is on (off by default -- see netx/tlsx and the TLS-over-tcp ADR),
	// and udp never can be. Encrypted or not, the code itself is what is
	// sent -- so this raises the bar from "anyone with the address" to
	// "anyone with the address and the code," not to "safe against a
	// network-level attacker." See docs/security.md and the ADRs in
	// agent_docs/architecture.md.
	RoomCode string `json:"room_code,omitempty"`
	// GameVersion is the adapter-reported game/DLC version, opaque to the
	// relay and core (same discipline as GameID/AreaID/Anim — compared only
	// by equality, never parsed). Empty means "unknown" and is not checked,
	// matching how a room's first Hello with no game_id would behave — see
	// the ADR in agent_docs/architecture.md.
	GameVersion string `json:"game_version,omitempty"`
	// Features is the capability list this client advertises — see the
	// Feature* constants in online.go. Reserved from 2026-08-11 and
	// populated from 2026-08-17.
	//
	// A room's ROOM-SCOPED capabilities (IsRoomScopedFeature) are sticky on
	// first join and later joiners must match them exactly, the same way
	// GameVersion already is. That is not tidiness: if one client advertises
	// lease.v1 and claims properly while another does not and simply acts,
	// conflict resolution silently does not work, and everything looks fine
	// until it doesn't. Refusing at the handshake turns an invisible
	// correctness failure into a legible one (ReasonFeatureMismatch). The
	// relay learns no more about "lease.v1" than about "1.2.0".
	//
	// Client-scoped capabilities (resume.v1, snapshot.v1) are NOT compared —
	// they concern only this client and the relay, so they may differ freely
	// between members of one room. Welcome.Features reports what ended up in
	// force for this client specifically.
	Features []string `json:"features,omitempty"`
	// ResumeToken, when non-empty, asks the relay to reinstate the identity
	// this token was issued for (Welcome.ResumeToken) instead of assigning a
	// fresh player_id: same id, same leases, same in-flight escrows, and no
	// leave/join seen by anyone else in the room. Honoured only within
	// DefaultResumeGrace of the drop, only in the same room, and only for a
	// room whose feature set contains FeatureResumeV1.
	//
	// A token that is unknown, expired, or for another room is NOT an error
	// — the relay silently falls back to assigning a new identity, which is
	// exactly what a client with no token gets. Failing the join instead
	// would turn "you were away slightly too long" into "you cannot play."
	ResumeToken string `json:"resume_token,omitempty"`
	// MaxReceiveHz is the highest rate, in updates per second *per peer*, at
	// which this client wants the relay to forward other players' state to
	// it. Zero or absent means uncapped (the pre-existing behavior, and what
	// an older client that doesn't know this field sends). Enforced at the
	// relay, which drops the excess before it goes out on the wire —
	// discarding on receive would save the client nothing, which is the
	// entire point. Per peer, not in total: a 5Hz cap in an 8-player room is
	// up to 35 messages/sec inbound, not 5 — see core.Core.
	// MaxReceiveHz and the ADR in agent_docs/architecture.md.
	MaxReceiveHz int `json:"max_receive_hz_per_player,omitempty"`

	// QueryOnly asks the relay to reply with a Transports message and hang
	// up, instead of joining a room. Every check that guards a real join
	// still runs first — field lengths, protocol version, and above all the
	// room code — so this discloses nothing to anyone who could not already
	// have joined. That is deliberate: it means transport discovery adds no
	// pre-auth surface to a relay, which the 2026-08-14 hardening pass
	// worked to keep clear.
	//
	// An older relay does not know this field and will treat the message as
	// an ordinary Hello, joining the client for real. A client must
	// therefore be ready to receive a Welcome here and simply carry on with
	// the connection rather than assume a Transports reply — see
	// core.
	QueryOnly bool `json:"query_only,omitempty"`
}

// TransportOffer is one transport a relay serves.
//
// The port travels but the host does not, on purpose: a relay bound to
// 0.0.0.0 has no idea what address reaches it from outside, whereas the
// client necessarily already knows one — it just connected to it. Sending
// only the port means discovery keeps working through NAT and port
// forwarding without the relay ever having to learn its own public address.
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
	// SendHz is the room-wide state send rate this relay is configured for,
	// in updates per second. A client adopts it as its actual send rate
	// unless it has deliberately configured a slower one of its own (see
	// core.Core.MinSendInterval) — the effective rate is the slower
	// of the two, so a peer on a poor connection can decline to go faster
	// but can never be made to go faster than the room. Always populated by
	// a relay that knows this field; a zero here means an older relay that
	// doesn't, which a client reads as "nothing advertised" and falls back
	// to core.DefaultMinSendInterval. Deliberately not omitempty: a
	// new relay always sends a real value, so a 0 on the wire from one would
	// be a bug worth seeing rather than eliding. See the ADR in
	// agent_docs/architecture.md.
	SendHz int `json:"send_hz"`
	// GhostCollision is the room-wide ghost-collision policy this relay is
	// configured for: GhostCollisionEnabled, GhostCollisionDisabled, or ""
	// from a relay that predates the field. A client resolves it against its
	// own configured preference with ResolveGhostCollision (more restrictive
	// wins) and hands the answer to its adapter over the bridge.
	//
	// omitempty, unlike SendHz: "" here is the ordinary shape of an older
	// relay AND of a current relay whose operator set nothing, and both mean
	// the same thing — nobody expressed a policy, so every adapter's own
	// default stands. SendHz is deliberately not omitempty because a current
	// relay always has a real rate to state; this one genuinely may not.
	GhostCollision string `json:"ghost_collision,omitempty"`
	// Features is the room's agreed feature set — normalized, and identical
	// for every member (see Hello.Features). Echoed back so a client can see
	// what the room actually settled on rather than assuming its own request
	// was adopted wholesale, and so a client joining an existing room learns
	// the set it was matched against.
	Features []string `json:"features,omitempty"`
	// ResumeToken is the unguessable secret this client presents in a later
	// Hello.ResumeToken to reclaim this identity after an unexpected drop.
	// Populated only for a room whose feature set contains FeatureResumeV1;
	// empty otherwise, and empty from any relay that predates resumption.
	//
	// Treat it as a credential: anyone holding it can take over this session,
	// including its outstanding escrows. It never leaves the client that was
	// issued it, and is never broadcast to the room.
	ResumeToken string `json:"resume_token,omitempty"`
	// Resumed reports that this Welcome reinstated an existing identity
	// rather than creating one. A client uses it to know that its previous
	// player_id, leases and escrows are still live — and, more practically,
	// that it should NOT treat this as a fresh session.
	Resumed bool `json:"resumed,omitempty"`
	// ServerTimeMs is the relay's own wall clock at the moment it sent this
	// Welcome, in milliseconds. The seed for clock sync: see Pong.ServerTimeMs
	// for why a single shared clock domain matters more than it sounds.
	ServerTimeMs int64 `json:"server_time_ms,omitempty"`
}

// Reject is the relay's reply to a Hello it refuses to accept, or — since
// the send/receive rate-control feature — its notice before closing an
// already-joined connection for exceeding the per-client message cap. See
// TypeReject. Sent once, immediately before the relay closes the connection.
type Reject struct {
	Reason string `json:"reason"`
}

// Reason values the relay actually sends in Reject.Reason — named so code
// on either side of the wire can compare symbolically instead of matching
// magic strings. Not a closed/coded enum: the wire itself still just
// carries plain text (a future relay could add a new reason without a
// contract change, per the forward-compatibility rule), these constants
// exist only for the Go call sites that need to tell a few of them apart —
// e.g. core deciding whether a rejection is worth retrying
// (ReasonServerFull can resolve on its own if someone leaves; every other
// reason here requires a config change first). Added alongside room-code
// auth, see the ADR in agent_docs/architecture.md.
const (
	ReasonProtocolVersionMismatch = "protocol version mismatch"
	ReasonHelloFieldTooLong       = "hello field too long"
	ReasonInvalidRoomCode         = "invalid room code"
	ReasonGameMismatch            = "game mismatch for this room"
	ReasonGameVersionMismatch     = "game version mismatch for this room"
	// ReasonFeatureMismatch means this client's advertised capability set
	// differs from the one this room agreed on when its first member joined
	// (see Hello.Features). Sticky the same way game_version is, and refused
	// for the same reason: two members that disagree about whether leases
	// exist do not fail loudly, they fail silently and much later.
	ReasonFeatureMismatch = "feature set mismatch for this room"
	// ReasonGameNotAllowed means this relay is configured to host one
	// specific game and the client is playing a different one — a
	// server-wide restriction the operator declared up front (see
	// relay.Server.OnlyGame), not the per-room stickiness
	// ReasonGameMismatch reports. No room the client picks would help.
	ReasonGameNotAllowed = "game not allowed on this relay"
	// ReasonServerFull means the relay is already at MaxClients across
	// every room it's hosting combined, not that any one room is full —
	// see relay.Server.MaxClients.
	ReasonServerFull = "server full"
	// ReasonRateLimited means the connection exceeded the relay's per-client
	// message cap (relay.MaxMessagesPerSecond, scaled by the room's
	// configured send rate) and is being closed. Unlike every other reason
	// here, this one is typically sent *after* a successful join, not at
	// handshake — and unlike the others it is retryable: a reconnecting
	// client re-reads the room's advertised send rate from the new Welcome
	// and may well fit under the cap the second time. See
	// core.isPermanentRejectReason and the ADR in
	// agent_docs/architecture.md.
	ReasonRateLimited = "rate limited"
)

// Join announces a peer entering the room. State seeds a newly-visible
// remote ghost with its most recent known state, so it appears where it
// actually is rather than only on its next update.
//
// Populated only for a recipient that advertised FeatureSnapshotV1; for
// anyone else it is nil, as it was for every recipient before 2026-08-17.
// See relay's stateSnapshotLocked. core handles both cases.
type Join struct {
	PlayerID string `json:"player_id"`
	State    *State `json:"state,omitempty"`
}

// Leave announces a peer leaving the room. This is what drives
// despawn_remote on the adapter side of the bridge.
//
// **Also sent client -> relay, as a voluntary goodbye** (added 2026-08-17).
// PlayerID is ignored in that direction — the relay knows whose connection it
// is — and the message means "I am leaving on purpose; do not hold my session
// for a reconnect."
//
// It exists because resumption otherwise cannot tell a closed game from a bad
// connection, and guesses wrong in the case a player actually sees. Found live:
// with resume.v1 on, quitting the game left every other player staring at a
// frozen ghost for the whole grace window, because the relay only saw a socket
// close. The core discarding its own token was not enough — that only affects
// where the NEXT connection lands, and says nothing to the relay about this
// one. A client that never sends this is unaffected: it simply gets the grace
// window, which is the correct treatment for an unexplained drop.
type Leave struct {
	PlayerID string `json:"player_id"`
}

// Event is one message on the event plane: reliable, ordered, addressed,
// and opaque. See agent_docs/contract.md's Extensibility section.
//
// The two planes are kept structurally separate on purpose, and the reason
// is delivery semantics rather than tidiness. `extras` on the state plane is
// lossy, latest-wins, and re-sent ~20x/second — right for "what colour is
// this ghost's trail" and catastrophic for "I offer you this item," which is
// not an offer if it may silently vanish. Deeper data rides here, never
// there.
type Event struct {
	// To is the addressee's player_id, or empty for room broadcast. This is
	// the one field of an Event the relay reads, which is exactly why it is
	// top-level and the payload is not: **a field earns top-level status only
	// if game-agnostic code must act on it.** A top-level field the core does
	// not read is a field the core can start reading.
	To string `json:"to,omitempty"`
	// From is the sender's player_id, stamped server-side from the
	// connection's own assigned id and never trusted from the payload —
	// exactly as State.PlayerID already is, and for the same reason: a peer
	// could otherwise attribute an event to someone else.
	From string `json:"from,omitempty"`
	// Seq is the room's monotonic sequencer stamp, assigned by the relay
	// inside the same critical section that snapshots the recipients, so
	// every member of a room observes one identical total order over events,
	// lease changes and escrow changes alike.
	//
	// This is real server authority in the practically useful sense, and it
	// needs no game knowledge whatsoever: **authority over order is not
	// authority over meaning.** "You were second" needs a counter. "That move
	// was illegal" needs to understand the game, and is not on offer here.
	//
	// Distinct from State.Seq, which is a per-client counter on the lossy
	// plane and means nothing across senders.
	Seq uint64 `json:"seq,omitempty"`
	// CorrID is an opaque correlation id, echoed unchanged, so an adapter can
	// match a reply to its request without inventing a framing of its own
	// inside Payload. The relay never generates, interprets or requires one.
	CorrID string `json:"corr_id,omitempty"`
	// Payload is fully opaque to the core and relay — the same rule that
	// keeps them game-agnostic for area_id and anim is what would keep them
	// game-agnostic for a battle protocol. Bounded by MaxEventBytes, and
	// never fragmented: if it does not fit, send a reference, not chunks.
	Payload json.RawMessage `json:"payload"`
}

// Ping keeps an otherwise-quiet connection from going idle
// (core.Core.sendHeartbeats) and, since 2026-08-17, doubles as the
// clock-sync probe. Nonce is echoed in the Pong so a client can match a
// reply to the send time it recorded — previously the field existed and
// nothing read it back, which meant RTT was not merely unmeasured but not
// even computable.
type Ping struct {
	Nonce uint64 `json:"nonce"`
}

// Pong is the relay's reply.
type Pong struct {
	Nonce uint64 `json:"nonce"`
	// ServerTimeMs is the relay's own wall clock when it sent this reply, in
	// milliseconds. With the client's recorded send time and its receive
	// time, that is the standard three-timestamp estimate: RTT is t2-t0, and
	// the offset between the two clocks is serverTime - (t0+t2)/2.
	//
	// **Why the relay is the clock and not each peer:** State.Timestamp is
	// compared directly against a *local* wall clock by
	// core/interp.go's remoteBuffer.at(), so two peers whose clocks
	// disagree by more than the interpolation delay stop interpolating and
	// silently fall back to an edge snapshot every tick — no error anywhere,
	// just ghosts that look subtly wrong. A client that has measured this
	// offset stamps its outgoing timestamps in the relay's clock domain
	// instead of its own, which puts every member of a room on one shared
	// clock without any peer having to be correct about the real time.
	//
	// Zero means "not advertised" — an older relay — and a client reading
	// zero applies no offset, which is exactly the pre-2026-08-17 behaviour.
	ServerTimeMs int64 `json:"server_time_ms,omitempty"`
}
