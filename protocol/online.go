package protocol

// This file is the wire vocabulary for everything past the cosmetic state
// plane: the event plane, the room sequencer, lease authority, escrow, room
// feature negotiation, and session resumption. The design reasoning — why a
// relay can arbitrate at all without understanding a game, and which gaps
// this does NOT close — lives in agent_docs/beyond-cosmetic.md; this file is
// only the shapes and their limits.
//
// The governing rule, restated here because every type below depends on it:
// **the relay compares these strings for equality and does nothing else with
// them.** A lease key, an escrow id, an event payload and a feature name are
// all as opaque to relay as area_id and anim already are. Authority
// over *order* (who was first) never requires knowing what a thing *means*.

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// ValidOpaqueString reports whether s is usable as one of this protocol's
// opaque identifiers: within maxBytes, and valid UTF-8.
//
// **The UTF-8 half is not tidiness, and it is not about the contents.** The
// contract permits exactly one operation on an opaque string — comparison by
// equality — and a string that is not valid UTF-8 does not survive JSON:
// encoding/json replaces each invalid byte with U+FFFD on the way out. So the
// key a sender wrote and the key every receiver compares are different
// strings, and equality silently stops working across the wire. That is a
// worse failure than a refusal, because nothing reports it.
//
// The replacement also EXPANDS (one bad byte becomes three), which is how this
// was found: FuzzValidateEventIsStableAcrossTheWire produced a corr_id that
// passed the length check before being marshaled and failed it afterwards, so
// a client's own validation accepted an event the relay would then silently
// drop. The length asymmetry is the symptom; the broken equality is the
// disease, and rejecting invalid UTF-8 fixes both at once rather than
// budgeting for worst-case expansion.
//
// Not reachable from the wire itself — a string decoded from JSON is already
// valid UTF-8, because the decoder did the same replacement on the way in — so
// this guards the in-process callers: core's exported send paths, and
// any future in-process adapter that builds these values in Go.
func ValidOpaqueString(s string, maxBytes int) bool {
	return len(s) <= maxBytes && utf8.ValidString(s)
}

// Capability strings a client advertises in Hello.Features. Each names one
// thing the relay is asked to do that it would otherwise never do; a room
// whose agreed feature set lacks one has that code path stay completely
// unused for its whole life, which is what makes all of this opt-in rather
// than imposed (agent_docs/beyond-cosmetic.md §3 — the relay needs no
// per-game table and no game_id branch, which CLAUDE.md forbids anyway).
//
// Versioned from the start (".v1") because a capability's *meaning* can
// change while its name doesn't. A future incompatible lease protocol is
// "lease.v2" and simply fails to match a v1 room, which is exactly the
// behaviour wanted — as opposed to a Version bump, which hard-rejects every
// deployed client (see agent_docs/contract.md's versioning rule).
const (
	// FeatureEventV1 enables addressed event routing (TypeEvent). Without
	// it the relay drops events rather than forwarding them.
	FeatureEventV1 = "event.v1"
	// FeatureLeaseV1 enables lease claim/renew/release over opaque keys.
	FeatureLeaseV1 = "lease.v1"
	// FeatureEscrowV1 enables two-sided atomic exchange. Implies nothing
	// about leases: a lease grants exclusive *access*, never an atomic
	// *swap*, and conflating the two is where historical trading exploits
	// came from (agent_docs/beyond-cosmetic.md §5).
	FeatureEscrowV1 = "escrow.v1"
	// FeatureSnapshotV1 asks the relay to seed a joining client with each
	// existing member's most recent state, via Join.State. Opt-in only
	// because it changes what a newly-joined client receives, and every
	// pre-2026-08-17 client got nothing.
	FeatureSnapshotV1 = "snapshot.v1"
	// FeatureResumeV1 enables session resumption: a client that drops
	// unexpectedly and reconnects with its resume token keeps its player_id,
	// and the rest of the room is never told it left at all.
	FeatureResumeV1 = "resume.v1"
	// FeatureWorldV1 asks the relay to hold custody of a room's world: the
	// latest opaque blob per entity, handed as a canonical set to whoever
	// takes the authority lease next, and to anyone who joins.
	//
	// **Custody is not designation.** lease.v1 already answers "who is
	// authoritative" and hands the key to the next claimant when a holder
	// leaves. What it cannot do is say what that successor inherits: without
	// custody a new host adopts from its OWN last-known view, every peer's
	// view is slightly different and slightly stale, and so *which* peer takes
	// over changes what the world becomes. This closes that, and fixes late
	// joins by the same mechanism.
	//
	// Requires FeatureLeaseV1 in the same room — every write names a lease key
	// and is accepted only from that lease's holder. The two are deliberately
	// NOT merged and neither implies the other in NormalizeFeatures: implying
	// one from the other would change the sticky FeatureSetKey and silently
	// stop matching rooms that already agreed on the old string.
	FeatureWorldV1 = "world.v1"
	// FeatureClockV1 is purely informational — clock sync is a pairwise
	// client/relay measurement that needs no room agreement and no relay
	// state, and a relay that has never heard of it still answers Pong. It
	// is advertised so a room's feature set honestly describes what its
	// members do, since a client using relay time stamps its state
	// timestamps in a different clock domain than one that doesn't.
	FeatureClockV1 = "clock.v1"
)

// Limits for everything in this file. Same discipline as limits.go: bounds
// exist so a peer cannot exhaust the relay, never so anything can be
// interpreted.
const (
	// MaxEventBytes bounds one Event.Payload. agent_docs/beyond-cosmetic.md
	// §9 laid out the honest choice here as uniform-vs-transport-dependent,
	// and this is the uniform answer: 1024 keeps a whole event envelope
	// comfortably under udpconn.MaxDatagramBytes (1200), so an event means
	// the same thing on every transport and no capability negotiation is
	// needed for size. The alternative — a bigger ceiling that udp clients
	// silently cannot use — buys a larger number and pays for it with a
	// difference that only shows up in the field.
	//
	// There is deliberately NO application-level fragmentation. If a payload
	// does not fit, the answer is a *reference* to the data rather than the
	// data (an escrow id, a key), never chunking: fragmenting across a lossy
	// plane reinvents TCP badly, and the reliable plane already is TCP.
	MaxEventBytes = 1024

	// MaxCorrIDLen bounds Event.CorrID, the one piece of an event other than
	// To that game-agnostic code has any reason to look at (matching a reply
	// to its request). Opaque; the relay only echoes it.
	MaxCorrIDLen = 64

	// MaxFeatures / MaxFeatureLen bound Hello.Features. Small on purpose:
	// this is a capability list, not a data channel, and the room-stickiness
	// check below turns it into a map key.
	MaxFeatures   = 16
	MaxFeatureLen = 64

	// MaxLeaseKeyLen bounds a lease key. 128 matches MaxHelloFieldLen's
	// reasoning — short opaque identifiers, not payloads.
	MaxLeaseKeyLen = 128

	// MaxLeasesPerRoom bounds how many distinct keys one room may hold at
	// once, so a client cannot make the relay's lease table grow without
	// bound by claiming a fresh key every message. A claim past this is
	// denied, exactly like a claim on a held key.
	MaxLeasesPerRoom = 256

	// MaxEscrowIDLen / MaxEscrowBlobBytes bound one exchange. The blob is
	// the opaque thing being swapped — or, past this size, a reference to it.
	MaxEscrowIDLen     = 64
	MaxEscrowBlobBytes = 1024

	// MaxEscrowsPerRoom bounds concurrent exchanges per room, same
	// exhaustion reasoning as MaxLeasesPerRoom.
	MaxEscrowsPerRoom = 64

	// MaxResumeTokenLen bounds Hello.ResumeToken. The relay's own tokens are
	// ResumeTokenBytes of hex; this is generous headroom so a future longer
	// token needs no contract change, while still bounding what an attacker
	// can push through the pre-auth Hello path.
	MaxResumeTokenLen = 128

	// ResumeTokenBytes is how much entropy the relay puts in a resume token.
	// 16 bytes (128 bits) makes guessing one — which would let an attacker
	// steal an in-flight identity, including its outstanding escrows —
	// infeasible, and the token is generated with crypto/rand, never a
	// counter. This is the one place in the relay where a value must be
	// unguessable rather than merely unique, which is exactly why player_id
	// (a bare counter) cannot serve as one.
	ResumeTokenBytes = 16
)

// Lease TTL bounds. A lease is a *timed* grant, never a permanent one: the
// hard part of lease authority is lifetime, not the grant itself
// (agent_docs/beyond-cosmetic.md §4). A holder that vanishes mid-trade must
// not wedge a key forever, and the only thing that can guarantee that
// without game knowledge is a clock.
const (
	MinLeaseTTL     = 1 * time.Second
	MaxLeaseTTL     = 5 * time.Minute
	DefaultLeaseTTL = 30 * time.Second
)

// ClampLeaseTTL resolves a requested lease TTL in milliseconds to a usable
// duration: zero or negative means "use DefaultLeaseTTL" (the same
// zero-means-default convention as ClampSendHz and Server.MaxClients), and
// anything outside [MinLeaseTTL, MaxLeaseTTL] is clamped rather than
// refused — a client must not lose a claim it would otherwise have won
// because it asked for a slightly silly duration.
func ClampLeaseTTL(ms int) time.Duration {
	if ms <= 0 {
		return DefaultLeaseTTL
	}
	d := time.Duration(ms) * time.Millisecond
	if d < MinLeaseTTL {
		return MinLeaseTTL
	}
	if d > MaxLeaseTTL {
		return MaxLeaseTTL
	}
	return d
}

// NormalizeFeatures trims, drops empties, deduplicates and sorts a feature
// list, so two clients that advertise the same capabilities in a different
// order (or twice) are recognised as advertising the same set. The relay's
// room-stickiness check is a string comparison of the normalized lists, so
// normalizing is what keeps that check from rejecting an identical set for a
// cosmetic difference.
//
// Returns nil for an empty result rather than an empty slice, so "declared
// nothing" has exactly one representation on the wire and in the room table.
func NormalizeFeatures(features []string) []string {
	if len(features) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(features))
	out := make([]string, 0, len(features))
	for _, f := range features {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		if _, dup := seen[f]; dup {
			continue
		}
		seen[f] = struct{}{}
		out = append(out, f)
	}
	if len(out) == 0 {
		return nil
	}
	sort.Strings(out)
	return out
}

// FeatureSetKey renders a normalized feature list as one comparable string.
// The relay stores this per room and compares later joiners against it by
// equality — learning no more about "lease.v1" than it currently learns
// about the game version "1.2.0" (agent_docs/beyond-cosmetic.md §3).
func FeatureSetKey(features []string) string {
	return strings.Join(NormalizeFeatures(features), ",")
}

// IsRoomScopedFeature reports whether name is a capability every member of a
// room must agree on, as opposed to one that concerns only a single client and
// the relay.
//
// The distinction is not bookkeeping — it decides whether turning a capability
// on costs a coordinated reconfiguration of everyone in the room:
//
//   - **Room-scoped** capabilities describe something shared. event.v1,
//     lease.v1 and escrow.v1 are protocols *between peers*, and a member that
//     does not speak one silently fails to participate — the hazard
//     agent_docs/beyond-cosmetic.md §3 exists to close. clock.v1 is subtler
//     but the same: it changes which clock State.Timestamp is expressed in, and
//     a room where some members shift and others don't is worse than one where
//     nobody does.
//   - **Client-scoped** capabilities describe something between one client and
//     the relay, which no peer participates in or can even observe.
//     resume.v1 asks the relay to hold *this* client's identity after a drop.
//     snapshot.v1 asks it to seed *this* client on join. A peer neither
//     consents to nor is affected by either.
//
// Forcing the second kind through the sticky room check was the original
// design and it was wrong: it made enabling resumption cost a lockstep
// reconfiguration of every player, for a feature none of them take part in —
// friction with no safety bought, and the surest way to have nobody bother.
//
// **An unrecognised name is treated as room-scoped.** That is the fail-safe
// direction: a future room-scoped capability wrongly classified as client-
// scoped would silently not be enforced, which is exactly the invisible
// mismatch this whole mechanism exists to prevent, whereas the opposite
// mistake merely asks for a coordinated config change that was not strictly
// necessary. Annoying beats silently broken.
func IsRoomScopedFeature(name string) bool {
	switch name {
	case FeatureResumeV1, FeatureSnapshotV1:
		return false
	}
	return true
}

// RoomScopedFeatures returns the normalized subset of features that a room
// agrees on collectively. This is what the relay makes sticky and compares a
// later joiner against; the rest is honoured per client.
func RoomScopedFeatures(features []string) []string {
	out := make([]string, 0, len(features))
	for _, f := range NormalizeFeatures(features) {
		if IsRoomScopedFeature(f) {
			out = append(out, f)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// HasFeature reports whether an already-normalized (or not) feature list
// contains name. Linear because these lists are at most MaxFeatures long.
func HasFeature(features []string, name string) bool {
	for _, f := range features {
		if f == name {
			return true
		}
	}
	return false
}

// ValidateFeatures reports whether a Hello's feature list is within bounds.
// Checked at the relay before the list is used to create or match a room,
// same stage as the hello-field length checks.
func ValidateFeatures(features []string) bool {
	if len(features) > MaxFeatures {
		return false
	}
	for _, f := range features {
		if len(f) > MaxFeatureLen {
			return false
		}
	}
	return true
}

// LeaseOp is what a client is asking the relay to do with a key.
type LeaseOp string

const (
	// LeaseClaim asks for exclusive hold of Key. Granted to the first asker
	// and denied to everyone else until it is released or expires.
	//
	// **The adapter must ask BEFORE acting, never announce after**
	// (agent_docs/beyond-cosmetic.md §2). A client that acts locally and then
	// claims has put the relay's "no" after the fact is already on screen,
	// which is a rollback problem — per-game, and genuinely hard. The flow is
	// claim → wait → act, and it costs a network round trip before anything
	// visible happens. That is invisible for a turn-based trade and
	// unacceptable for anything twitchy, which is the real boundary on how
	// deep this can go.
	LeaseClaim LeaseOp = "claim"
	// LeaseRenew extends the current holder's expiry. From anyone else it is
	// denied; a renew is not a claim in disguise.
	LeaseRenew LeaseOp = "renew"
	// LeaseRelease gives up a held key immediately. From anyone but the
	// holder it is ignored.
	LeaseRelease LeaseOp = "release"
)

// Lease is a client's request against one opaque key (client → relay).
type Lease struct {
	Op LeaseOp `json:"op"`
	// Key is opaque. The relay compares it for equality and stores it; it
	// never parses it, and two clients running different games could not
	// meaningfully share one anyway (they cannot share a room at all).
	Key string `json:"key"`
	// TTLMs is the requested hold duration in milliseconds, clamped through
	// ClampLeaseTTL. Zero means DefaultLeaseTTL.
	TTLMs int `json:"ttl_ms,omitempty"`
}

// Lease state reasons. Plain text on the wire, like Reject.Reason — these
// constants exist for Go call sites, not as a closed enum.
const (
	LeaseGranted = "granted"
	// LeaseDenied is sent only to the asker. A failed claim is nobody else's
	// business and broadcasting it would turn a contested key into a
	// message storm.
	LeaseDenied = "denied"
	// LeaseReleased is the holder giving the key up voluntarily.
	LeaseReleased = "released"
	// LeaseExpired is the TTL running out with no renew.
	LeaseExpired = "expired"
	// LeaseHolderLeft is the holder's connection dropping. Distinct from
	// expired because an adapter may reasonably treat a clean release, a
	// timeout, and a disconnect differently — the relay does not, and says
	// which happened rather than deciding for it.
	LeaseHolderLeft = "holder_left"
	// LeaseTooMany is a claim refused because the room is already holding
	// MaxLeasesPerRoom distinct keys.
	LeaseTooMany = "too many leases in room"
)

// LeaseState is the relay's answer about one key (relay → client), and the
// authoritative fact for everyone in the room.
//
// The relay never judges merit, only arrival: it picks the first claim and
// that becomes the fact by fiat. Everyone agrees because everyone was told
// the same answer, not because the answer was correct on the merits.
// Arbitrary-but-consistent is the whole trick, and judging *rightness* is
// what would require understanding the game.
type LeaseState struct {
	Key string `json:"key"`
	// Holder is the player_id currently holding Key, or empty for "free".
	Holder string `json:"holder,omitempty"`
	// Seq is this room's monotonic sequencer stamp — the total order every
	// member observes. See Event.Seq.
	Seq uint64 `json:"seq"`
	// ExpiresAt is the relay's own wall clock in milliseconds, so a client
	// that has done clock sync can render a countdown. Zero when Holder is
	// empty.
	ExpiresAt int64 `json:"expires_at,omitempty"`
	// Reason is one of the Lease* constants above.
	Reason string `json:"reason,omitempty"`
}

// ValidateLease reports whether a Lease request is within bounds and names a
// real op.
func ValidateLease(l Lease) bool {
	switch l.Op {
	case LeaseClaim, LeaseRenew, LeaseRelease:
	default:
		return false
	}
	return l.Key != "" && ValidOpaqueString(l.Key, MaxLeaseKeyLen)
}

// EscrowOp is one step of a two-sided atomic exchange.
//
// This exists because **a lease grants exclusive access, never an atomic
// swap** (agent_docs/beyond-cosmetic.md §5). A trade is two-sided — both or
// neither — and if one side vanishes after handing over, an item is
// destroyed or duplicated. That is exactly where historical Pokémon trading
// exploits came from, and no amount of lease discipline prevents it.
type EscrowOp string

const (
	// EscrowOpen starts an exchange between the sender and With. The id is
	// chosen by the opener and is opaque.
	EscrowOpen EscrowOp = "open"
	// EscrowDeposit hands the relay this party's opaque blob. The relay
	// holds it and reveals it to nobody until the exchange commits.
	EscrowDeposit EscrowOp = "deposit"
	// EscrowCommit records this party's willingness to complete. The
	// exchange completes only once BOTH parties have deposited and BOTH have
	// committed — which is the entire point.
	EscrowCommit EscrowOp = "commit"
	// EscrowAbort cancels. Any abort, disconnect, or timeout by either party
	// aborts the whole exchange and discards both blobs.
	EscrowAbort EscrowOp = "abort"
)

// Escrow is one step a client asks for (client → relay).
type Escrow struct {
	Op EscrowOp `json:"op"`
	// ID is opaque, chosen by the opener, unique within the room.
	ID string `json:"id"`
	// With is the counterparty's player_id — required on open, ignored
	// otherwise. Must be a current member of the room.
	With string `json:"with,omitempty"`
	// Blob is this party's opaque contribution, on deposit only. The relay
	// stores the bytes and never looks inside; what a blob means is entirely
	// the adapter's business, exactly like an event payload.
	Blob json.RawMessage `json:"blob,omitempty"`
}

// Escrow phases, carried in EscrowState.Phase.
const (
	// EscrowPhaseOpen means the exchange exists and at least one side has
	// not deposited yet.
	EscrowPhaseOpen = "open"
	// EscrowPhaseDeposited means both blobs are held and the relay is
	// waiting for both commits.
	EscrowPhaseDeposited = "deposited"
	// EscrowPhaseCommitted is terminal and is the ONLY state in which blobs
	// are revealed. An adapter applies the swap here and nowhere else.
	EscrowPhaseCommitted = "committed"
	// EscrowPhaseAborted is terminal; blobs are discarded and never sent.
	EscrowPhaseAborted = "aborted"
)

// Escrow abort reasons.
const (
	EscrowReasonAborted   = "aborted by party"
	EscrowReasonPartyLeft = "party left"
	EscrowReasonTimeout   = "timed out"
	EscrowReasonRejected  = "rejected"
)

// EscrowState is the relay's report on one exchange (relay → client), sent
// to both parties on every phase change.
type EscrowState struct {
	ID string `json:"id"`
	// Seq is the room sequencer stamp, same total order as Event and
	// LeaseState.
	Seq uint64 `json:"seq"`
	// Phase is one of the EscrowPhase* constants.
	Phase string `json:"phase"`
	// Parties is exactly the two player_ids involved, opener first.
	Parties []string `json:"parties,omitempty"`
	// Deposited lists which parties have deposited so far — the fact each
	// side needs to decide whether to commit, without revealing anything.
	Deposited []string `json:"deposited,omitempty"`
	// Committed lists which parties have committed so far.
	Committed []string `json:"committed,omitempty"`
	// Blobs is populated ONLY when Phase == EscrowPhaseCommitted, keyed by
	// depositing player_id. Both parties receive the identical map, which is
	// what makes the swap both-or-neither from each side's point of view.
	Blobs map[string]json.RawMessage `json:"blobs,omitempty"`
	// Reason explains a terminal phase.
	Reason string `json:"reason,omitempty"`
}

// ValidateEscrow reports whether an Escrow request is within bounds.
func ValidateEscrow(e Escrow) bool {
	switch e.Op {
	case EscrowOpen, EscrowDeposit, EscrowCommit, EscrowAbort:
	default:
		return false
	}
	if e.ID == "" || !ValidOpaqueString(e.ID, MaxEscrowIDLen) {
		return false
	}
	if !ValidOpaqueString(e.With, MaxHelloFieldLenForID) {
		return false
	}
	return len(e.Blob) <= MaxEscrowBlobBytes
}

// MaxHelloFieldLenForID bounds a player_id appearing in a client-supplied
// field (Event.To, Escrow.With). Relay-assigned ids are tiny ("p12"), so
// this is only about refusing an unbounded string before it is used as a map
// key — relay has its own MaxHelloFieldLen for Hello's fields, and
// this exists in protocol/ because core needs the same bound on the
// values it sends.
const MaxHelloFieldLenForID = 128

// ValidateEvent reports whether an Event is within bounds. Checked at the
// relay on receive and at the core before send, the same two-enforcement-
// point discipline as ValidateState.
func ValidateEvent(e Event) bool {
	if !ValidOpaqueString(e.To, MaxHelloFieldLenForID) {
		return false
	}
	if !ValidOpaqueString(e.CorrID, MaxCorrIDLen) {
		return false
	}
	return len(e.Payload) <= MaxEventBytes
}

// ---------------------------------------------------------------------------
// World custody
// ---------------------------------------------------------------------------

// Bounds for the world plane. Unlike every other limit in this file, these are
// derived from udpconn.MaxDatagramBytes rather than from MaxLineBytes, and the
// difference is not cosmetic: udpconn.checkWritable refuses any datagram over
// 1200 bytes minus its framing, INCLUDING a reliable one, and the refusal
// surfaces only as a "relay: send to pX failed:" log line. A message that does
// not fit is therefore lost for that recipient and — being a custody message —
// never superseded. See agent_docs/contract.md for the arithmetic, and §9 of
// the same file for the pre-existing constants that do NOT satisfy this.
const (
	// MaxWorldKeyLen bounds one entity key. 64 matches MaxEscrowIDLen, the
	// closest existing analogue: an opaque per-object id, not a payload.
	MaxWorldKeyLen = 64

	// MaxWorldBlobBytes bounds one entity's opaque state. Derived: 1182 usable
	// datagram bytes, minus MaxLeaseKeyLen (128) for the authority, minus
	// MaxWorldKeyLen (64), minus ~130 of JSON scaffolding, leaves ~860. 768
	// takes that with ~90 bytes of slack rather than sitting on the edge.
	MaxWorldBlobBytes = 768

	// MaxWorldKeysPerRoom bounds how many entities one room's world may hold.
	//
	// **Derived, not chosen**, the same discipline as RateLimitHeadroomMultiple:
	// udpconn's reorderWindow is 64, and a reliable burst wider than that
	// window is not held by the receiver, is therefore not acked, retries at
	// 250ms x maxRetries and can eventually close the connection. 64 is the
	// pathological worst case of a snapshot that packs exactly one maximal
	// entry per message. The relationship is asserted by a test in package
	// udpconn, which is the only place that can see the unexported constant.
	//
	// ~58KB per room at the maximum, which is a CAP, not a leak: entries are
	// bounded, and the only thing that discards them automatically is the room
	// itself going away. See relay/world.go on why lifetime is deliberately not
	// tied to the lease.
	MaxWorldKeysPerRoom = 64

	// MaxWorldMessageBytes is the batching budget for one WorldState carrying
	// several entries. It is a THRESHOLD, not a hard bound: a batch stops
	// growing once the next entry would cross it, but a single entry is always
	// emitted even if it alone exceeds this (a maximal one renders to ~1115
	// bytes, which still fits a datagram with its framing). The hard guarantee
	// — one maximal entry plus framing under MaxDatagramBytes — is what the
	// udpconn test asserts.
	MaxWorldMessageBytes = 1100
)

// WorldOp is what a client is asking the relay to do with an entity key.
type WorldOp string

const (
	// WorldSet stores (or replaces) the latest opaque blob for a key.
	//
	// **A set that CREATES a key must be sent reliably.** A lossy set on a key
	// the relay does not currently hold is ignored, and that rule exists to
	// close a reordering hole one hop earlier than the relay: the lossy and
	// reliable planes are independent on a datagram transport, so a lossy set
	// dispatched before a reliable drop can arrive after it, resurrecting an
	// entity permanently — the relay's map has it deleted, so no snapshot ever
	// contradicts the resurrection and a late joiner sees a different world
	// from an existing member. Requiring the creating write to be reliable
	// makes creation and deletion travel the same ordered plane, so they can
	// never overtake each other. It costs nothing real: a spawn is a discrete
	// transition, which is already what Reliable is for.
	WorldSet WorldOp = "set"
	// WorldDrop removes a key. Always broadcast; the relay forgets the blob.
	WorldDrop WorldOp = "drop"
)

// World is one write against one entity (client → relay).
type World struct {
	Op WorldOp `json:"op"`
	// Authority names the lease key this write is made under. The relay
	// accepts it only from that lease's current holder — a pure string
	// comparison, teaching the relay nothing about the game, and the thing
	// that prevents the specific failure custody exists to survive: a
	// departing host's in-flight packets overwriting the new host's world
	// after handover.
	//
	// Bounded by MaxLeaseKeyLen rather than a constant of its own, because it
	// must be able to name any lease key and a second bound would drift.
	Authority string `json:"authority"`
	// Key identifies the entity, opaque and compared only by equality.
	Key string `json:"key"`
	// Blob is the entity's opaque state, on a set. The relay stores the bytes
	// and never looks inside, exactly like an escrow deposit.
	Blob json.RawMessage `json:"blob,omitempty"`
	// Reliable selects the DELIVERY VARIANT of this write and nothing else.
	//
	// False for continuous motion, which the next update supersedes; true for
	// a change that must not be missed (an enemy dying, a door opening, and
	// every write that creates a key — see WorldSet). The relay stores the
	// latest either way, so a snapshot is always complete regardless.
	//
	// **It never selects the serialization.** Every world write is stamped and
	// delivered under the relay's sendMu, lossy ones included, so a lossy write
	// may be LOST but is never REORDERED against another write. Skipping that
	// would let a stale set land after a newer one with nothing to correct it,
	// since snapshots only go to joiners and a key may never be written again.
	// The reasoning is in the ADR in agent_docs/architecture.md.
	Reliable bool `json:"reliable,omitempty"`
}

// WorldEntry is one entity's state inside a WorldState. A message carries a
// LIST so one type serves both a single live write and a batched snapshot.
//
// That is batching, not fragmentation: no entry is ever split, every message is
// independently complete and applicable, and there is no reassembly or chunk
// index anywhere. EscrowState.Blobs already carries a map of opaque blobs in
// one message, so the precedent is established.
type WorldEntry struct {
	Key string `json:"key"`
	// Blob is absent for a drop.
	Blob json.RawMessage `json:"blob,omitempty"`
	// Dropped marks this key as removed rather than updated.
	Dropped bool `json:"dropped,omitempty"`
}

// WorldState is the relay's report about one authority's world (relay →
// client): a live write, a handover or join snapshot, or a refusal.
type WorldState struct {
	Authority string `json:"authority"`
	// Holder is the lease holder the relay considers authoritative for this
	// authority right now, or empty for none.
	//
	// **Never filter a WorldState against your roster.** core drops
	// State for an id it was never told about, and applying the same instinct
	// here would be silently wrong: a world entry legitimately outlives the
	// player who wrote it, and Holder may name someone who has already left
	// by the time a snapshot is read. A "helpful" roster check would discard
	// exactly the adopted world that custody exists to preserve.
	Holder string `json:"holder,omitempty"`
	// Seq is this room's monotonic sequencer stamp, the same total order as
	// Event and LeaseState.
	//
	// **A receiver must use it.** The relay guarantees a total order, and it
	// delivers every world message under one lock so that order is real — but
	// the reliable and lossy planes are independent on a datagram transport,
	// so two messages to ONE peer can still land out of order between them. An
	// adapter therefore ignores a WorldState older than what it has already
	// applied for a key. Without that, a lossy write can overtake the reliable
	// snapshot that was meant to seed it and then be reverted by it.
	Seq uint64 `json:"seq"`
	// Entries is what changed, or the whole world for a snapshot.
	Entries []WorldEntry `json:"entries,omitempty"`
	// Reason is one of the World* constants below.
	Reason string `json:"reason,omitempty"`
}

// WorldState reasons. Plain text on the wire, like every other Reason here.
const (
	// WorldWritten is a live write being broadcast to the rest of the room.
	WorldWritten = "written"
	// WorldSnapshot is the whole world for one authority, sent to a client
	// that just took the lease or just joined.
	WorldSnapshot = "snapshot"
	// WorldDenied is a write from someone who does not hold the named
	// authority lease. Sent only to the writer.
	//
	// Explicit rather than silent, and it leaks nothing: lease holdership is
	// already broadcast to the whole room, the amplification is 1:1, and the
	// sender is inbound-flood-capped. Silence here would leave a stale host
	// believing its writes are landing.
	WorldDenied = "denied"
	// WorldTooMany is a write refused because the room already holds
	// MaxWorldKeysPerRoom entities. Sent only to the writer — silence would
	// leave a host believing it spawned an entity nobody has.
	WorldTooMany = "too many world keys in room"
)

// ValidateWorld reports whether a world write is within bounds and names a
// real op. Checked at the relay on receive and at the core before send, the
// same two-enforcement-point discipline as ValidateState.
//
// ValidOpaqueString applies to BOTH Authority and Key, and its UTF-8 half is
// load-bearing for the first of those specifically: a non-UTF-8 string
// round-trips through JSON as a *different* string, so an invalid authority
// would compare unequal to the lease key it names at the relay while the
// client's own validation passed — every write silently denied, with nothing
// anywhere reporting why.
func ValidateWorld(w World) bool {
	switch w.Op {
	case WorldSet, WorldDrop:
	default:
		return false
	}
	if w.Authority == "" || !ValidOpaqueString(w.Authority, MaxLeaseKeyLen) {
		return false
	}
	if w.Key == "" || !ValidOpaqueString(w.Key, MaxWorldKeyLen) {
		return false
	}
	return len(w.Blob) <= MaxWorldBlobBytes
}

// ValidateWorldState reports whether a relay's world report is within bounds.
// Checked by core on receive: a hostile or compromised relay is not
// trusted to have enforced its own limits, the same posture ValidateState and
// ValidateEvent already take on that side.
func ValidateWorldState(st WorldState) bool {
	if !ValidOpaqueString(st.Authority, MaxLeaseKeyLen) {
		return false
	}
	if !ValidOpaqueString(st.Holder, MaxHelloFieldLenForID) {
		return false
	}
	if len(st.Entries) > MaxWorldKeysPerRoom {
		return false
	}
	for _, e := range st.Entries {
		if e.Key == "" || !ValidOpaqueString(e.Key, MaxWorldKeyLen) {
			return false
		}
		if len(e.Blob) > MaxWorldBlobBytes {
			return false
		}
	}
	return true
}

// DefaultResumeGrace is how long the relay holds a dropped client's identity
// — its player_id, its leases, and its escrows — waiting for it to come
// back with a resume token, before giving up and telling the room it left.
//
// The value is a compromise between two real costs. Too short and a
// reconnect after a brief network blip still despawns the ghost for
// everyone, which is the whole thing resumption exists to prevent. Too long
// and a genuinely departed player's leases stay held, blocking everyone else
// from a key nobody is coming back for — and the slot stays counted against
// the relay's MaxClients. 20s comfortably covers
// core.reconnectWithBackoff's first few attempts (1s, 2s, 4s, 8s)
// while staying well under the point where a room notices a frozen ghost.
const DefaultResumeGrace = 20 * time.Second

// DefaultEscrowTimeout is how long an exchange may sit unfinished before the
// relay aborts it on its own. Without this a half-finished trade pins both
// parties' blobs (and, in practice, their leases) forever whenever one side
// simply stops responding without disconnecting — the "half-finished trade"
// case agent_docs/beyond-cosmetic.md §10 names as needing crash injection to
// test properly.
const DefaultEscrowTimeout = 60 * time.Second

// EscrowRetention is how long a terminal (committed or aborted) exchange
// record is kept after it finishes, so a party that dropped in the moment
// between the relay committing and the message arriving can resume and be
// told the outcome instead of being left permanently unsure whether the swap
// happened.
//
// **This is the piece that makes atomicity survive a crash rather than only
// a refusal**, and it is why resumption and escrow are built together rather
// than separately: without it, "both or neither" holds only for as long as
// both sockets stay up, which is precisely the case that never fails in
// testing and always fails in the field.
const EscrowRetention = 60 * time.Second
