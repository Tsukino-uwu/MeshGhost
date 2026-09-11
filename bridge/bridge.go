// Package bridge defines the message shapes exchanged between an adapter
// and its local core process — the "adapter bridge" in agent_docs/contract.md.
// Same NDJSON framing as the relay protocol, but this
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

// A note on the seven types below that are nothing but a struct embedding one
// protocol type (Event, Lease, LeaseState, Escrow, EscrowState, World,
// WorldState). That looks like pure ceremony and it is load-bearing, so it is
// written down here rather than rediscovered and "cleaned up":
//
//   - Having its own name is what stops the two channels sharing a Go type by
//     accident. The bridge and the relay protocol are separate by contract, and
//     the compiler is the only thing that keeps a refactor from quietly wiring
//     one into the other.
//   - Each wrapper carries adapter-facing semantics that exist nowhere in the
//     protocol type -- EscrowState's apply-on-committed-and-no-other-phase rule,
//     WorldState's apply-in-seq-order rule, Lease's ask-before-acting rule. Those
//     are instructions to whoever writes the next adapter, and they belong on the
//     type that adapter actually receives.
//
// Making them independent instead would duplicate the field lists and give
// internal/gameblind's frozen wire-field check two places to disagree. Deleting
// them would collapse the separation this package exists to express. They stay.

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
	// TypeRemoteName carries a peer's nametag, and is DELIBERATELY NOT a field
	// on render_remote. A name changes at most once in a session while
	// render_remote is sent every frame per peer, so putting it there would
	// ship the same string tens of thousands of times, and cost every adapter
	// a string allocation per peer per frame to parse a value that did not
	// change. This arrives once, when the name is learned.
	TypeRemoteName MessageType = "remote_name"
	// TypeBridgeReady and TypeReject are the core's two possible answers to a
	// Hello, added 2026-08-16 so an adapter can tell whether a core is actually
	// available to it -- see BridgeReady's doc comment for why silence was not
	// good enough.
	TypeBridgeReady MessageType = "bridge_ready"
	TypeReject      MessageType = "reject"
	// TypeReplayControl is adapter -> core, added 2026-09-03 (ADR 0047): an
	// in-game binding for the replay actions the core's own system-wide
	// hotkeys perform. Optional -- an adapter that never sends it loses
	// nothing, because the hotkeys exist regardless (ADR 0048).
	TypeReplayControl MessageType = "replay_control"
	// TypePlayerFrozen is adapter -> core, added 2026-09-05 (ADR 0053), pushed
	// ON CHANGE: the game is holding the player still and this is not gameplay
	// (an item popup, the pause menu, any modal). The core's ONE consumer is the
	// chaser pack, whose clock stops while it is set -- so a pause costs the
	// chaser no delay and it never converges onto a player who cannot move. The
	// recorder, the replay ghosts and the wire are untouched by design (the
	// user's call, 2026-09-05: "only want it to affect chaser, not
	// recordings/replay ghosts"). Optional: an adapter that never sends it keeps
	// today's behaviour exactly.
	TypePlayerFrozen MessageType = "player_frozen"
	// TypeInputSample is adapter -> core, added 2026-09-08 (ADR 0056): what the
	// player PRESSED, as a track of its own beside the state recording. It is a
	// SECOND track, never a field on state -- inputs change at frame rate and a
	// 15Hz sample of them would be a lie, and the state plane does not grow new
	// fields for deeper features (agent_docs/beyond-cosmetic.md).
	//
	// Nothing plays one back. This slice records only: the core writes the track
	// to replay/inputs/ and never drives anything with it. Driving a ghost from
	// inputs is a later, per-game ADR blocked on determinism; driving the LOCAL
	// player is forbidden in anything that ships, and the two live one bug apart.
	//
	// Optional -- an adapter that never sends it loses nothing.
	TypeInputSample MessageType = "input_sample"
	// TypeRemoteInput is core -> adapter, added 2026-09-08 (ADR 0057): a replay
	// ghost's recorded input track, streamed beside the ghost's frames. The
	// edges are the track's own (opaque mask, opaque axes, the adapter's own
	// frame and millisecond stamps) plus ONE value the core computes: `at`,
	// the render-clock time the edge is due, in the same domain render_remote's
	// state.timestamp carries. The core still knows nothing about what a bit
	// means and drives nothing with it; it is a courier between a file and the
	// adapter that wrote the file's shape.
	//
	// Sent only to an adapter whose hello asked (Hello.InputTracks), only for a
	// ghost the core invented from a clip that has a track, and never on the
	// wire. Optional: an adapter that ignores it is unaffected.
	TypeRemoteInput MessageType = "remote_input"
	// TypeSessionPolicy is core -> adapter, added 2026-08-19: the room-wide
	// rules the host set, that the adapter is the only party able to apply.
	// See SessionPolicy for why this is a message of its own rather than a
	// field on BridgeReady.
	TypeSessionPolicy MessageType = "session_policy"
	// TypeRecordingState is core -> adapter, pushed ON CHANGE: is a recording
	// running right now. It exists because the hotkeys are system-wide and live
	// in the core (ADR 0048), which by construction can never draw -- so the only
	// feedback a recording toggle had was a console line, and a player mid-run
	// cannot read one. The user, with the console hidden: "was unsure if f9 was
	// doing something or not when using it. i usually did f9 2-3 times then f11".
	//
	// STATE, not an event: it answers "am I recording", continuously, so an
	// adapter that attaches mid-recording learns the truth without having missed
	// a toast. Same shape and same reasoning as session_policy above.
	TypeRecordingState MessageType = "recording_state"
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

	// MinProtocolVersion is the OLDEST relay this ADAPTER will work with, and
	// it is the adapter's half of the floor the relay and the core already have
	// on either side of the wire (protocol.MinProtocolVersion, ADR 0058).
	//
	// WHY AN ADAPTER GETS A SAY AT ALL, when it never learns a relay address
	// and never sends a byte off-machine. The core's floor answers "can these
	// two builds talk", which is a property of the WIRE. This one answers a
	// different question that only the adapter can answer: an adapter that
	// depends on a field the relay did not forward -- because that relay
	// predates it -- does not fail at the handshake. It connects, renders, and
	// is quietly missing the thing it was written for, which is the failure
	// mode this whole project keeps rediscovering. Saying the number turns a
	// silent degradation into a refusal that names both versions.
	//
	// It is a FLOOR and never an equality, for the same reason the wire's is:
	// additive change is the only kind this protocol makes, so a newer relay's
	// extra fields are ignored rather than fatal. And it can only ever be
	// STRICTER than the core's own -- the core refuses anything below
	// protocol.MinProtocolVersion first, whatever an adapter says, so this
	// cannot be used to talk a core into accepting a relay it should not.
	//
	// Absent or 0 means "no opinion", which is what every shipped adapter sends
	// today and what keeps an older adapter working unchanged.
	//
	// **WHEN TO RAISE IT, the user's call 2026-09-11: a MAJOR or SECURITY
	// update to that adapter, and nothing else.** Syncing a bit more or a bit
	// less of a game visually is not a reason -- the client and the relay
	// already carry the safety and security floor between them, and raising
	// this for a cosmetic change would refuse rooms for no gain and split the
	// player base over something nobody can see.
	//
	// **RAISING IT IS THE MAINTAINER'S CALL AND IS SAID OUT LOUD, never inferred
	// from a diff** (the user, 2026-09-11). An adapter is allowed to LAG -- one
	// with no changes simply keeps the number it has. When an adapter does get
	// a major change, its floor is set to whatever the CLIENT is at that time,
	// which is what makes "the mod and the client were shipped together" a
	// checkable statement rather than a hope.
	MinProtocolVersion int `json:"min_protocol_version,omitempty"`

	// RenderAllAreas asks the core to deliver every remote's state regardless
	// of area, and to leave area-based despawns to the adapter. The core's
	// own cross-area filter (remoteStatesAt, ADR 2026-08-13) exists because a
	// remote rendered at another zone's raw coordinates is garbage -- which
	// is true exactly until an adapter can translate a neighboring map's
	// coordinates itself. Emerald's cross-map ghosts do (2026-08-20): the
	// adapter knows the game's own map-connection graph, so the CORE's
	// equality filter despawned every follower for the ~100ms an echoed
	// area_id lags a real crossing -- a visible pop per seam, on every seam.
	//
	// Adapter-local, deliberately NOT a room feature: it changes what this
	// core sends its own adapter and nothing on the wire, so it must not
	// fragment room compatibility the way feature-set matching would.
	// Absent means false, which is exactly the old behaviour; an adapter
	// that sets it takes over ALL area-based hiding, including for maps it
	// cannot translate.
	RenderAllAreas bool `json:"render_all_areas,omitempty"`

	// InterpolateOrientation asks the core to include the orientation bracket
	// on every render_remote -- the two opaque orientation blobs position was
	// interpolated between, and the fraction between them. See RenderRemote's
	// OrientationFrom/To/InterpT for what they are and ADR 0043 for why the
	// core cannot do this interpolation itself.
	//
	// **OPT-IN, AND THAT IS AN EFFICIENCY DECISION, NOT A SAFETY ONE.** The
	// bracket is game-blind to compute, so the core could send it to everyone
	// -- and did, briefly, on the day it was added. But only an adapter whose
	// orientation is CONTINUOUS can use it: a stepped facing is CORRECT for a
	// game with four compass directions or a flipped sprite, where there is no
	// midpoint between "west" and "north" to render. Sending two extra blobs
	// per peer per frame to three adapters that discard them is pure waste on
	// the bridge, and this project does not dismiss a saving for being small
	// (plans.md, "Efficiency is a standing goal").
	//
	// Absent means false, which is byte-for-byte the behaviour that shipped
	// before the bracket existed. An adapter that sets it must actually
	// interpolate -- see adapters/_template/README.md's three-families
	// section for which maths its own orientation shape needs.
	//
	// Adapter-local, deliberately NOT a room feature, for the same reason
	// RenderAllAreas is not: it changes what this core hands its own adapter
	// and nothing on the wire, so it must never fragment room compatibility.
	// Two peers in one room may disagree about it and neither can tell.
	InterpolateOrientation bool `json:"interpolate_orientation,omitempty"`

	// InputTracks asks the core to stream a replay ghost's recorded input track
	// beside its frames, as remote_input messages (ADR 0057). Off, the core
	// never even looks for a track: an adapter that cannot use one -- the
	// emulated games, an adapter with no input display -- pays nothing, not a
	// directory scan, not a parse, not a line on the bridge.
	//
	// Adapter-local, deliberately NOT a room feature, exactly as RenderAllAreas
	// and InterpolateOrientation are not: it changes what this core hands its
	// own adapter and nothing on the wire. Absent means false.
	InputTracks bool `json:"input_tracks,omitempty"`
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

// SessionPolicy is sent core -> adapter: the room-wide policy in force for
// this session, resolved by the core from what the relay advertised and what
// this client configured for itself.
//
// # Why this is not a field on BridgeReady
//
// BridgeReady is documented as deliberately payload-free, on the argument
// that anything worth knowing is "either the adapter's own input or none of
// its business". A host-set room policy is a third category that did not
// exist when that was written -- it is not the adapter's input, and it is
// squarely the adapter's business, because the adapter is the only party in
// the whole system that can actually apply it.
//
// The reason it still is not a handshake field is timing, not category. The
// core can re-handshake with the relay in the background (reconnectWithBackoff)
// without the adapter ever reconnecting, and a reconnecting client re-reads
// the room's advertised values from the new Welcome -- so a policy delivered
// once, on the bridge handshake, would silently go stale the first time the
// relay came back with different settings, or when a client resumed into a
// different relay entirely. A policy that can change mid-session needs a
// message that can be sent again.
//
// Sent immediately after BridgeReady, and again whenever the resolved value
// changes. An adapter that ignores it is unaffected by its existence, which
// is what keeps it compatible with an adapter built before it: the core does
// not wait for a reply and there is none to send.
// RecordingState is the payload of TypeRecordingState: whether the core is
// recording right now.
//
// TWO FIELDS, and the second one exists because of a specific failure case. The
// shape is an indicator, not a readout -- the user: "just a red circle would be
// pretty clear on its own and also stand out more and look better/simplistic" --
// plus the elapsed time, which they then asked for on its own merits: "so you
// know how long you have recorded as right now there is no feedback at all for
// that either".
//
// StartedUnixMs is WHEN, not HOW LONG, so the adapter counts up locally and this
// message stays a push-on-change rather than a once-a-second heartbeat. It also
// makes the mid-recording attach correct: an adapter that comes up while a
// recording is already running (a game relaunched during one) shows the true
// elapsed time instead of starting from zero. Both processes are on the same
// machine by construction -- the bridge is loopback only -- so a wall clock is
// a shared clock here.
//
// 0 when Recording is false. A file name or a sample count is deliberately not
// here: nothing draws them.
type RecordingState struct {
	Recording     bool  `json:"recording"`
	StartedUnixMs int64 `json:"started_unix_ms,omitempty"`
}

type SessionPolicy struct {
	// GhostCollision is protocol.GhostCollisionEnabled or
	// protocol.GhostCollisionDisabled -- never "", because the core resolves
	// absent-on-both-sides to enabled before sending. An adapter therefore
	// never has to know about the unset case or carry a default of its own.
	//
	// "enabled" means the adapter's OWN defaults stand, including any place
	// it already makes a ghost passable. It is not an instruction to make a
	// ghost solid: the core has no idea what collision means in this game and
	// is in no position to demand it. "disabled" is binding -- no ghost
	// blocks anything, at any time.
	//
	// An adapter that CANNOT honor "disabled" should say so in its own log
	// once, rather than silently appearing to comply. Nothing checks, and
	// nothing can: this is advisory the whole way down.
	GhostCollision string `json:"ghost_collision"`
	// ChaserContact is "enabled" when the player turned the chaser's contact
	// hook on (ADR 0047), absent otherwise. It is the ONE effect a cosmetic
	// ghost may ever have -- an overlap that hurts on touch, never solidity --
	// and an adapter honours it only under its own per-game ADR and the
	// user's on-screen confirmation. No shipped adapter does yet; every
	// other rule about cosmetic ghosts (never solid, blocking, damageable,
	// targetable) holds whatever this says.
	ChaserContact string `json:"chaser_contact,omitempty"`
}

// ReplayControl is sent adapter -> core to trigger one replay action from an
// in-game binding of the adapter's own. Action is one of record_start,
// record_stop, record_toggle, save_last, replay_last, restart, rewind,
// fast_forward (core.ReplayAction). Seconds applies to rewind and
// fast_forward; 0 or absent means the client's configured seek. The core
// logs the outcome and sends no reply: nothing an adapter would do differs
// on success or failure, and a player reads the core log either way.
//
// This is an ADDITION to the core's hotkeys, never a replacement: the
// actions work in every game without it, and an adapter that adds it only
// gains a key its own settings screen can show.
type ReplayControl struct {
	Action  string `json:"action"`
	Seconds int    `json:"seconds,omitempty"`
}

// PlayerFrozen is the payload of TypePlayerFrozen: true while the game holds
// the player still outside gameplay, false when play resumes. STATE, not an
// event, and sent on change only; a repeat of the current value is harmless.
type PlayerFrozen struct {
	Frozen bool `json:"frozen"`
}

// InputSample is the payload of TypeInputSample: a BATCH of the moments the
// player's input changed, adapter -> core.
//
// WHY A BITMASK AND A LABEL TABLE, rather than a list of button names per
// sample. The core must not learn what any button MEANS, which rules out it
// reading a name; and a track whose whole premise is "cheap enough to leave
// running" cannot spend 60-120 bytes per edge on strings that repeat. A mask
// costs ~10, makes the core's identical-check an integer compare, and has a
// stable bit order -- so a future diff of two runs is `a.M ^ b.M` rather than
// set arithmetic. The labels ride along once so the FILE stays readable by a
// person; the core copies them into a header and never reads one.
//
// WHY THE ADAPTER NAMES ITS OWN BUTTONS. What counts as input is per game --
// eight buttons on a handheld, a stick and a camera axis on a 3D platformer,
// a cursor somewhere else -- and none of that is the core's business. The
// recommended source is the GAME's already-merged action state rather than raw
// OS keys, which makes a track device-agnostic and rebind-proof, and which
// structurally cannot capture what the player types outside the game.
type InputSample struct {
	// Labels names bit 0..n-1 of each edge's Mask, and Axes names the slots of
	// Ax. STICKY: sent on the first batch of a connection and again only when
	// they change, exactly like a delta'd extras key -- absent means unchanged.
	// Opaque to the core, which copies them into the track's file header and
	// never reads one.
	Labels []string `json:"labels,omitempty"`
	Axes   []string `json:"axes,omitempty"`
	// Source is an opaque provenance tag naming WHERE the adapter read these
	// bits (say "pawn_properties"). It exists so a track is self-describing: a
	// reader built later can refuse one whose source it does not understand,
	// instead of silently trusting bits that mean something else.
	Source string `json:"source,omitempty"`
	// Drop is how many edges the ADAPTER dropped since the last batch, because
	// its own queue was full. Recording that input was lost is strictly better
	// than losing it silently -- a reader can tell a lossy region from a quiet
	// one, which it could not do from a gap alone.
	Drop uint32 `json:"drop,omitempty"`
	// Edges are in order and never coalesced. Empty is legal only on a batch
	// that carries Labels, which is how an adapter declares its table before
	// the player has touched anything.
	Edges []InputEdge `json:"edges"`
}

// InputEdge is one moment the input changed. Edges, not samples: a button is
// written when it goes down and when it comes up, so a one-frame press is two
// edges with consecutive F and no sampling rate can erase it.
type InputEdge struct {
	// F is the adapter's own frame counter and T its own millisecond stamp,
	// both monotonic, both kept VERBATIM. They are the adapter's domains, not
	// the core's: the core stamps each batch with its own clock on receipt, so
	// a track correlates to the state recording by that stamp while F and T
	// preserve the exact frame spacing inside a batch that one receipt stamp
	// would smear. A hold's length stays expressible in FRAMES, which is the
	// property a future re-drive needs and a millisecond stamp cannot give.
	F uint64 `json:"f"`
	T int64  `json:"t"`
	// M is the button mask, bit i meaning Labels[i]. Opaque to the core, which
	// compares it to the previous one for equality and never decomposes it.
	//
	// 32 bits deliberately, not 64: a JSON number is a float64 to every reader
	// that is not Go, so a 64-bit mask would silently lose bits above 2^53. If
	// 32 is ever too few the growth path is a second field for the high bits,
	// additive, no format bump.
	M uint32 `json:"m"`
	// Ax are the analog axes -- a stick, a camera, a cursor. Absent means
	// unchanged since the previous edge. Quantized by the adapter rather than
	// sampled sparsely, so a reader gets an exact value and not a guess.
	Ax []float64 `json:"ax,omitempty"`
}

// RemoteInput is core -> adapter (ADR 0057): a window of a replay ghost's
// recorded input edges, ahead of when they are due. The adapter buffers them
// per player and applies each one on the first render_remote for that player
// whose state.timestamp is at or past the edge's At -- so a press lands on the
// frame the ghost's rendered state reaches it, whatever the bridge's latency.
//
// Labels, Axes and Source are the track's own header tables, copied verbatim
// (InputSample's rule, and the file's): STICKY, carried on the first line after
// every Reset and absent otherwise. Reset marks a discontinuity -- the clip
// started, looped, was seeked -- and means "drop every edge you are holding
// for this player; what follows is a fresh window". A despawn_remote for the
// player means the same, since the ghost it applied to is gone.
type RemoteInput struct {
	PlayerID string            `json:"player_id"`
	Labels   []string          `json:"labels,omitempty"`
	Axes     []string          `json:"axes,omitempty"`
	Source   string            `json:"source,omitempty"`
	Reset    bool              `json:"reset,omitempty"`
	Edges    []RemoteInputEdge `json:"edges"`
}

// RemoteInputEdge is one InputEdge plus At, the ONLY value the core adds: the
// render-clock time this edge is due, computed from the track's own timestamp
// through the same rebasing the clip's samples get (start, speed, trim,
// skip_gaps). F, T, M and Ax are the file's, verbatim, so a hold's length is
// still expressible in the recording adapter's own frames.
type RemoteInputEdge struct {
	F  uint64    `json:"f"`
	T  int64     `json:"t"`
	M  uint32    `json:"m"`
	Ax []float64 `json:"ax,omitempty"`
	At int64     `json:"at"`
}

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
	// Code is the stable, machine-readable name for this refusal, and it is the
	// field an adapter is meant to branch on. Reason stays a sentence for the
	// adapter's log.
	//
	// Added 2026-09-08 for a defect, not for tidiness: every shipped adapter was
	// matching the REASON for the substring "relay" to decide whether to wait or
	// walk to the next port -- and the heuristic is inverted, because every
	// PERMANENT refusal contains that word (the core renders relay refusals as
	// "core: relay refused connection: %s") while the one refusal that means
	// "try the next port", busy, does not. So a wrong room code was read as "the
	// relay is briefly down" and retried forever, with the player never told.
	//
	// Empty means a core older than this field; an adapter that does not
	// recognise a code falls back to Retryable, and only then to whatever it
	// used to do.
	Code string `json:"code,omitempty"`
	// Retryable says whether reconnecting could plausibly succeed without the
	// player changing something. False for a wrong room code; true for a room
	// that happened to be full. See the same field on protocol.Reject for why a
	// flag exists next to the code.
	Retryable bool `json:"retryable,omitempty"`
}

// Reject codes an adapter may branch on. These name the CORE's own refusals;
// a refusal that came from the relay carries the relay's code through unchanged
// (protocol's Code* constants), so an adapter sees one namespace.
//
// Frozen once shipped, like the protocol codes: four adapters in three languages
// compare against these literals.
const (
	// CodeBusy means this core already has a game attached. THE ONE REFUSAL
	// THAT MEANS "TRY THE NEXT PORT" -- everything else means stop and tell the
	// player. Retryable is false for it, deliberately: retrying THIS core is
	// pointless, which is a different question from whether the adapter should
	// keep looking elsewhere, and conflating the two is the bug this whole
	// change exists to fix.
	CodeBusy = "busy"
	// CodeAlreadyServing means this core is connected as a different game_id.
	// Like busy, walking on is right; unlike busy, a second core for the other
	// game is the actual answer.
	CodeAlreadyServing = "already_serving"
)

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
	// The orientation bracket: the two opaque orientation blobs State's
	// position was interpolated BETWEEN, and how far between them the render
	// time fell. Absent (all three empty/zero) whenever the core has no honest
	// pair, which is the signal to use State.Orientation unchanged -- what
	// every adapter did before these existed, and what an adapter that ignores
	// them still does. See core.orientBracket for the full reasoning.
	//
	// BRIDGE-ONLY, DELIBERATELY: these are not on protocol.State and must
	// never be, because nothing here crosses the network. Both blobs are
	// already on the wire as consecutive samples; this is the core telling
	// the adapter which two it used, over a local socket, at zero bandwidth
	// cost to the relay link.
	//
	// WHY AN ADAPTER WOULD WANT THEM: the core is forbidden to parse an
	// orientation, so it cannot interpolate one -- it holds the older
	// bracket's value until the render time crosses the newer sample, which
	// makes facing a STEP FUNCTION at the send rate. That is correct for a
	// game with four facings and wrong for one with continuous 3D rotation,
	// where it reads as choppy on a fast turn and fine on a slow one. An
	// adapter for such a game interpolates between From and To at T itself --
	// shortest-arc, since 350 degrees to 10 must travel +20 and not -340.
	//
	// T CAN EXCEED 1. Under prediction (`-extrapolate`) the arc continues past
	// To for the same window position is predicted over, so that facing and
	// position stay on one clock. An adapter that does not want prediction on
	// rotation clamps it; one that does, does not.
	//
	// PEER-CONTROLLED BYTES, like every other field on this message: both
	// blobs came from a remote peer via the relay and are bounded only by
	// protocol.MaxOrientationBytes. Parse defensively.
	OrientationFrom json.RawMessage `json:"orientation_from,omitempty"`
	OrientationTo   json.RawMessage `json:"orientation_to,omitempty"`
	InterpT         float64         `json:"interp_t,omitempty"`
	// Cosmetic is true for a ghost this core INVENTED -- a replay of a
	// recording, or the chaser (ADR 0047) -- and absent for a real peer. An
	// adapter treats a cosmetic ghost as a picture: never solid, never
	// blocking, never damageable, never a target, WHATEVER session_policy's
	// ghost_collision says (the user's rule, 2026-09-03). Per frame rather
	// than a one-shot message because there is no peer_joined message: the
	// first render_remote is how an adapter learns a peer exists, so a flag
	// sent once could be missed by an adapter that attached late. Bridge-only,
	// never on protocol.State: a cosmetic ghost is never on the network.
	Cosmetic bool `json:"cosmetic,omitempty"`
}

// RemoteName is sent core -> adapter when a peer's nametag becomes known: on
// join, and for everyone already present when this adapter attaches (an adapter
// can attach long after the core connected, so it must be told what it missed --
// the same reason pushAreaPreference exists).
//
// DISPLAYNAME IS EMPTY FOR A PLAYER WITH NO NAME, which is the shipped default,
// and an adapter MUST then draw no nametag at all rather than an empty box.
// The user's rule, 2026-08-28: "if its blank it should not display/do anything,
// it should only have a text box/show something if a custom name is put in".
//
// Sanitized twice before it reaches here -- once by the relay and once by this
// core, which does not trust the relay to have done it (protocol.
// SanitizeDisplayName is idempotent precisely so the second pass is free and
// cannot disagree with the first). An adapter may render it as PLAIN TEXT and
// nothing else: never through a rich-text or markup-capable path, where a name
// would become markup injection.
//
// NEVER AN IDENTITY. PlayerID is; two peers may carry the same DisplayName.
type RemoteName struct {
	PlayerID    string `json:"player_id"`
	DisplayName string `json:"display_name"`
	// Color is "#RRGGBB", or empty for "use your own default". An adapter that
	// cannot colour text ignores it and still draws the name; one that can may
	// read it as three bytes with no parser, which is exactly why the wire shape
	// is six hex digits and nothing else.
	Color string `json:"color,omitempty"`
}

// DespawnRemote is sent core -> adapter to remove an entry from that set,
// driven by a relay Leave message reaching the core.
type DespawnRemote struct {
	PlayerID string `json:"player_id"`
}
