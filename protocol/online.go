package protocol

// The wire vocabulary past the cosmetic state plane: events, the room sequencer, leases, escrow, world custody,
// feature negotiation and resumption. The relay compares these strings for equality and does nothing else with them:
// authority over order (who was first) never requires knowing what a thing means.

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// ValidOpaqueString reports whether s is usable as an opaque identifier: within maxBytes, and valid UTF-8. An
// identifier is only ever compared by equality, and invalid UTF-8 comes back from JSON as a different string, so
// equality would silently break across the wire. A string decoded from JSON is already valid, so this guards
// in-process callers.
func ValidOpaqueString(s string, maxBytes int) bool {
	return len(s) <= maxBytes && utf8.ValidString(s)
}

// ValidOpaqueStringOnWire is ValidOpaqueString with the length measured on the bytes encoding/json writes. Use it for
// an identifier whose bound was derived from a transport budget, where an under-count means an undeliverable
// message: '<', '>' and '&' become six bytes, U+2028/U+2029 six from three, a quote or backslash two, a control byte
// six. Invalid UTF-8 needs no budget; it is refused.
func ValidOpaqueStringOnWire(s string, maxBytes int) bool {
	return utf8.ValidString(s) && opaqueStringWireLen(s) <= maxBytes
}

// opaqueStringWireLen is how many bytes s occupies inside a JSON string, quotes excluded (the message's scaffolding
// accounts for them). Exact for valid UTF-8, the only input it is given.
func opaqueStringWireLen(s string) int {
	n := len(s)
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '<' || c == '>' || c == '&':
			n += 5
		case c == '"' || c == '\\':
			n++
		case c < 0x20:
			n += 5
		case c == 0xe2:
			// U+2028 (e2 80 a8) and U+2029 (e2 80 a9): three bytes in, six on the wire.
			if i+2 < len(s) && s[i+1] == 0x80 && (s[i+2] == 0xa8 || s[i+2] == 0xa9) {
				n += 3
			}
		}
	}
	return n
}

// Capability strings a client advertises in Hello.Features. Each names one thing the relay would otherwise never do,
// so a room whose agreed set lacks one never runs that path. Versioned because a capability's meaning can change
// while its name does not: an incompatible lease protocol is "lease.v2" and simply fails to match a v1 room, where a
// Version bump would refuse every deployed client.
const (
	// FeatureEventV1 enables addressed event routing (TypeEvent); without it the relay drops events.
	FeatureEventV1 = "event.v1"
	// FeatureLeaseV1 enables lease claim/renew/release over opaque keys.
	FeatureLeaseV1 = "lease.v1"
	// FeatureEscrowV1 enables two-sided atomic exchange. It implies nothing about leases: a lease grants exclusive
	// access, never an atomic swap.
	FeatureEscrowV1 = "escrow.v1"
	// FeatureSnapshotV1 asks the relay to seed a joining client with each member's latest state, via Join.State.
	// Opt-in because it changes what a newly joined client receives.
	FeatureSnapshotV1 = "snapshot.v1"
	// FeatureResumeV1 enables session resumption: a client that drops and reconnects with its resume token keeps
	// its player_id, and the rest of the room is never told it left.
	FeatureResumeV1 = "resume.v1"
	// FeatureWorldV1 asks the relay to hold custody of a room's world: the latest opaque blob per entity, handed to
	// the next authority-lease holder and to joiners. Requires FeatureLeaseV1, and neither implies the other in
	// NormalizeFeatures: that would change the sticky FeatureSetKey and stop matching rooms that agreed on the old one.
	FeatureWorldV1 = "world.v1"
	// FeatureClockV1 makes every member stamp State.Timestamp in the relay's clock domain. The measurement itself is
	// pairwise and needs no relay state (any relay answers Pong); the feature is room-scoped because a room where only
	// some members shift is worse than one where none do.
	FeatureClockV1 = "clock.v1"
)

// Limits for everything in this file. As in limits.go, they exist so a peer cannot exhaust the relay, never so
// anything can be interpreted.
const (
	// MaxEventBytes bounds one Event.Payload, uniform across transports. It does not keep a maximal Event inside
	// a udp datagram, and a committed EscrowState overshoots in every case; netx/udpconn's
	// TestMaximalEventDoesNotFitAUDPDatagram and TestMaximalCommittedEscrowDoesNotFitAUDPDatagram pin that, and
	// changing it is a contract revision. No application-level fragmentation: send a reference, never chunks.
	MaxEventBytes = 1024

	// MaxCorrIDLen bounds Event.CorrID, which the relay only echoes so an adapter can match a reply to its request.
	MaxCorrIDLen = 64

	// MaxFeatures and MaxFeatureLen bound Hello.Features: a capability list, not a data channel, and the room check
	// turns it into a map key.
	MaxFeatures   = 16
	MaxFeatureLen = 64

	// MaxLeaseKeyLen bounds a lease key: a short opaque identifier, like MaxHelloFieldLen, not a payload.
	MaxLeaseKeyLen = 128

	// MaxLeasesPerRoom bounds the distinct keys one room may hold, so a client cannot grow the relay's lease table by
	// claiming a fresh key every message. A claim past it is denied like a claim on a held key.
	MaxLeasesPerRoom = 256

	// MaxEscrowIDLen and MaxEscrowBlobBytes bound one exchange; past this size the blob should be a reference.
	MaxEscrowIDLen     = 64
	MaxEscrowBlobBytes = 1024

	// MaxEscrowsPerRoom bounds concurrent exchanges per room, for the same reason as MaxLeasesPerRoom.
	MaxEscrowsPerRoom = 64

	// MaxLiveEscrowsPerMember bounds the live exchanges one member has opened. Counted by opener, never by
	// counterparty, or a member could lock a victim out by naming them; finished records count toward neither cap.
	MaxLiveEscrowsPerMember = 8

	// MaxHelloFieldLen bounds every string field of Hello (GameID, Room, DisplayName, GameVersion, NameColor), all
	// short human-facing text, before any of them creates or looks up a room.
	MaxHelloFieldLen = 128

	// MaxResumeTokenLen bounds Hello.ResumeToken: headroom over the relay's own ResumeTokenBytes of hex, while still
	// bounding what an attacker pushes through the pre-auth Hello.
	MaxResumeTokenLen = 128

	// ResumeTokenBytes is the crypto/rand entropy in a resume token: guessing one would steal an identity with its
	// escrows, so it must be unguessable, not just unique, which is why player_id (a counter) cannot serve.
	ResumeTokenBytes = 16
)

// Lease TTL bounds. A lease is a timed grant: a holder that vanishes must not wedge a key forever, and without game
// knowledge only a clock can guarantee that.
const (
	MinLeaseTTL     = 1 * time.Second
	MaxLeaseTTL     = 5 * time.Minute
	DefaultLeaseTTL = 30 * time.Second
)

// ClampLeaseTTL resolves a requested TTL in milliseconds: zero or negative means DefaultLeaseTTL, and anything
// outside [MinLeaseTTL, MaxLeaseTTL] is clamped rather than refused, so a silly duration never costs a claim.
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

// NormalizeFeatures trims, drops empty and invalid names, deduplicates, sorts and caps a feature list, so two clients
// advertising the same set in a different order compare equal: the room check is a string comparison of normalized
// lists. Returns nil for an empty result, so "declared nothing" has exactly one representation.
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
		// Bounded here too: validateFeatures gates only a Hello, and a Welcome's list is scanned under the core's
		// lock on every plane message. Dropped, not refused: no real feature is over-long or seventeenth.
		if !ValidOpaqueString(f, MaxFeatureLen) {
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
	// After the sort, so the cap keeps a deterministic set.
	if len(out) > MaxFeatures {
		out = out[:MaxFeatures]
	}
	return out
}

// FeatureSetKey renders a normalized feature list as one comparable string. The relay stores it per room and
// compares later joiners against it by equality.
func FeatureSetKey(features []string) string {
	return strings.Join(NormalizeFeatures(features), ",")
}

// IsRoomScopedFeature reports whether name is a capability every member of a room must agree on (something shared,
// like event.v1 or clock.v1) rather than one between a single client and the relay (resume.v1, snapshot.v1). An
// unrecognised name is room-scoped, the fail-safe direction: a shared capability treated as client-scoped would
// silently go unenforced, while the opposite mistake only asks for a config change.
func IsRoomScopedFeature(name string) bool {
	switch name {
	case FeatureResumeV1, FeatureSnapshotV1:
		return false
	}
	return true
}

// RoomScopedFeatures returns the normalized subset of features a room agrees on collectively: what the relay makes
// sticky and compares a later joiner against. The rest is honoured per client.
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

// HasFeature reports whether a feature list contains name; linear, since a list is at most MaxFeatures long.
func HasFeature(features []string, name string) bool {
	for _, f := range features {
		if f == name {
			return true
		}
	}
	return false
}

// validateFeatures reports whether a Hello's feature list is within bounds, checked at the relay before the list
// creates or matches a room.
func validateFeatures(features []string) bool {
	if len(features) > MaxFeatures {
		return false
	}
	for _, f := range features {
		// Not len(): a feature name decides what a whole room negotiates, so an invalid-UTF-8 one is a capability
		// nobody can name twice. The decoder in front keeps it off the wire, but ValidateHelloFields is exported.
		if !ValidOpaqueString(f, MaxFeatureLen) {
			return false
		}
	}
	return true
}

// ValidateHelloFields reports whether every client-supplied field of a Hello, which arrives before any
// authentication, is within its bound. It returns a plain bool, never the offending value: a caller must not log
// field contents on failure, which would write unbounded attacker-controlled bytes into the relay's log.
func ValidateHelloFields(h Hello) bool {
	for _, s := range []string{
		h.GameID, h.Room, h.DisplayName, h.GameVersion, h.NameColor,
	} {
		if len(s) > MaxHelloFieldLen {
			return false
		}
	}
	// The PAKE message has its own, larger bound: a fixed-size cryptographic message, not a name.
	if len(h.PakeKE1) > MaxPakeFieldLen {
		return false
	}
	if len(h.ResumeToken) > MaxResumeTokenLen {
		return false
	}
	return validateFeatures(h.Features)
}

// LeaseOp is what a client is asking the relay to do with a key.
type LeaseOp string

const (
	// LeaseClaim asks for exclusive hold of Key, granted to the first asker until released or expired. An adapter
	// claims before acting, never announces after: acting first puts the relay's "no" after the fact is on screen.
	LeaseClaim LeaseOp = "claim"
	// LeaseRenew extends the current holder's expiry; from anyone else it is denied, not treated as a claim.
	LeaseRenew LeaseOp = "renew"
	// LeaseRelease gives up a held key at once; from anyone but the holder it is ignored.
	LeaseRelease LeaseOp = "release"
)

// Lease is a client's request against one opaque key (client → relay).
type Lease struct {
	Op LeaseOp `json:"op"`
	// Key is opaque: the relay compares it for equality and stores it, and never parses it.
	Key string `json:"key"`
	// TTLMs is the requested hold in milliseconds, through ClampLeaseTTL; zero means DefaultLeaseTTL.
	TTLMs int `json:"ttl_ms,omitempty"`
}

// Lease state reasons: plain text on the wire, like Reject.Reason, named for Go call sites rather than a closed enum.
const (
	LeaseGranted = "granted"
	// LeaseDenied is sent only to the asker: broadcasting a failed claim would turn a contested key into a message
	// storm.
	LeaseDenied = "denied"
	// LeaseReleased is the holder giving the key up voluntarily.
	LeaseReleased = "released"
	// LeaseExpired is the TTL running out with no renew.
	LeaseExpired = "expired"
	// LeaseHolderLeft is the holder's connection dropping. The relay says which of release, expiry and disconnect
	// happened, and leaves it to the adapter to treat them differently.
	LeaseHolderLeft = "holder_left"
	// LeaseTooMany is a claim refused because the room already holds MaxLeasesPerRoom distinct keys.
	LeaseTooMany = "too many leases in room"
)

// LeaseState is the relay's answer about one key (relay to client), and the fact for everyone in the room. The relay
// judges arrival, never merit: the first claim wins by fiat, and everyone agrees because everyone was told the same.
type LeaseState struct {
	Key string `json:"key"`
	// Holder is the player_id currently holding Key, or empty for "free".
	Holder string `json:"holder,omitempty"`
	// Seq is this room's sequencer stamp, the total order every member observes (see Event.Seq).
	Seq uint64 `json:"seq"`
	// ExpiresAt is the relay's wall clock in milliseconds, so a client that synced clocks can show a countdown.
	// Zero when Holder is empty.
	ExpiresAt int64 `json:"expires_at,omitempty"`
	// Reason is one of the Lease* constants above.
	Reason string `json:"reason,omitempty"`
}

// ValidateLease reports whether a Lease request is within bounds and names a real op.
func ValidateLease(l Lease) bool {
	switch l.Op {
	case LeaseClaim, LeaseRenew, LeaseRelease:
	default:
		return false
	}
	return l.Key != "" && ValidOpaqueString(l.Key, MaxLeaseKeyLen)
}

// EscrowOp is one step of a two-sided atomic exchange. A lease grants exclusive access, never an atomic swap: in a
// trade where one side vanishes after handing over, an item is destroyed or duplicated.
type EscrowOp string

const (
	// EscrowOpen starts an exchange between the sender and With; the opener chooses the opaque id.
	EscrowOpen EscrowOp = "open"
	// EscrowDeposit hands the relay this party's opaque blob, revealed to nobody until the exchange commits.
	EscrowDeposit EscrowOp = "deposit"
	// EscrowCommit records this party's willingness to complete. The exchange completes only once both parties have
	// deposited and both have committed.
	EscrowCommit EscrowOp = "commit"
	// EscrowAbort cancels. Any abort, disconnect or timeout by either party aborts the whole exchange and discards
	// both blobs.
	EscrowAbort EscrowOp = "abort"
)

// Escrow is one step a client asks for (client to relay).
type Escrow struct {
	Op EscrowOp `json:"op"`
	// ID is opaque, chosen by the opener, unique within the room.
	ID string `json:"id"`
	// With is the counterparty's player_id, a current member: required on open, ignored otherwise.
	With string `json:"with,omitempty"`
	// Blob is this party's opaque contribution, on deposit only; the relay stores the bytes and never looks inside.
	Blob json.RawMessage `json:"blob,omitempty"`
}

// Escrow phases, carried in EscrowState.Phase.
const (
	// EscrowPhaseOpen means the exchange exists and at least one side has not deposited.
	EscrowPhaseOpen = "open"
	// EscrowPhaseDeposited means both blobs are held and the relay waits for both commits.
	EscrowPhaseDeposited = "deposited"
	// EscrowPhaseCommitted is terminal and the only phase that reveals blobs; an adapter applies the swap here and
	// nowhere else.
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

// EscrowState is the relay's report on one exchange (relay to client), sent to both parties on every phase change.
type EscrowState struct {
	ID string `json:"id"`
	// Seq is the room sequencer stamp, in the same total order as Event and LeaseState.
	Seq uint64 `json:"seq"`
	// Phase is one of the EscrowPhase* constants.
	Phase string `json:"phase"`
	// Parties is exactly the two player_ids involved, opener first.
	Parties []string `json:"parties,omitempty"`
	// Deposited lists which parties have deposited, which each side needs before committing, revealing nothing.
	Deposited []string `json:"deposited,omitempty"`
	// Committed lists which parties have committed so far.
	Committed []string `json:"committed,omitempty"`
	// Blobs is set only when Phase is EscrowPhaseCommitted, keyed by depositing player_id. Both parties receive the
	// identical map, which makes the swap both-or-neither from each side's view.
	Blobs map[string]json.RawMessage `json:"blobs,omitempty"`
	// Reason explains a terminal phase.
	Reason string `json:"reason,omitempty"`
}

// MaxStateReasonLen bounds the Reason a relay attaches to a LeaseState or EscrowState, derived from MaxHelloFieldLen
// rather than another loose 128.
const MaxStateReasonLen = MaxHelloFieldLen

// MaxEscrowParties is how many players one exchange has: two. It bounds Parties, Deposited, Committed and Blobs,
// collections a relay fills, so a receiver never iterates whatever a line can hold.
const MaxEscrowParties = 2

// ValidateLeaseState reports whether a LeaseState from a relay is within bounds, the mirror of ValidateLease. It
// measures with len(), not JSONWireLen, on purpose: the line cap already bounded the wire form, and a receiver
// stricter than its sender would drop legitimate traffic.
func ValidateLeaseState(st LeaseState) bool {
	if st.Key == "" || !ValidOpaqueString(st.Key, MaxLeaseKeyLen) {
		return false
	}
	if !ValidOpaqueString(st.Holder, MaxHelloFieldLenForID) {
		return false
	}
	return ValidOpaqueString(st.Reason, MaxStateReasonLen)
}

// ValidateEscrowState reports whether an EscrowState from a relay is within bounds: the mirror of ValidateEscrow,
// plus the collection bounds, since an EscrowState carries the whole party list.
func ValidateEscrowState(st EscrowState) bool {
	if st.ID == "" || !ValidOpaqueString(st.ID, MaxEscrowIDLen) {
		return false
	}
	switch st.Phase {
	case EscrowPhaseOpen, EscrowPhaseDeposited, EscrowPhaseCommitted, EscrowPhaseAborted:
	default:
		// A closed set, unlike Reason: an adapter switches on Phase to decide whether an item changed hands, so
		// an unknown one is a step nobody can act on.
		return false
	}
	if !ValidOpaqueString(st.Reason, MaxStateReasonLen) {
		return false
	}
	for _, ids := range [][]string{st.Parties, st.Deposited, st.Committed} {
		if len(ids) > MaxEscrowParties {
			return false
		}
		for _, id := range ids {
			if id == "" || !ValidOpaqueString(id, MaxHelloFieldLenForID) {
				return false
			}
		}
	}
	if len(st.Blobs) > MaxEscrowParties {
		return false
	}
	for id, blob := range st.Blobs {
		if id == "" || !ValidOpaqueString(id, MaxHelloFieldLenForID) {
			return false
		}
		if JSONWireLen(blob) > MaxEscrowBlobBytes {
			return false
		}
	}
	return true
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
	return JSONWireLen(e.Blob) <= MaxEscrowBlobBytes
}

// MaxHelloFieldLenForID bounds a player_id in a client-supplied field (Event.To, Escrow.With) before it becomes a
// map key. Derived from MaxHelloFieldLen, since separate literals for the same kind of identifier drift.
const MaxHelloFieldLenForID = MaxHelloFieldLen

// ValidateEvent reports whether an Event is within bounds. The relay checks it on receive, and the core both before
// sending and on receive.
func ValidateEvent(e Event) bool {
	// From is handed to the adapter as the peer an event came from, so the core bounds it too. Empty is allowed:
	// it is what a relay older than the field sends.
	if !ValidOpaqueString(e.From, MaxHelloFieldLenForID) {
		return false
	}
	if !ValidOpaqueString(e.To, MaxHelloFieldLenForID) {
		return false
	}
	if !ValidOpaqueString(e.CorrID, MaxCorrIDLen) {
		return false
	}
	return JSONWireLen(e.Payload) <= MaxEventBytes
}

// Bounds for the world plane, derived from udpconn.MaxDatagramBytes rather than MaxLineBytes: udpconn.checkWritable
// refuses an oversized datagram, reliable ones included, with only a log line to show for it, and a lost custody
// message is never superseded.
const (
	// MaxWorldKeyLen bounds one entity key, like MaxEscrowIDLen: an opaque per-object id, not a payload.
	MaxWorldKeyLen = 64

	// MaxWorldBlobBytes bounds one entity's opaque state. Derived: 1182 usable datagram bytes, minus MaxLeaseKeyLen
	// (128) for the authority, minus MaxWorldKeyLen (64), minus about 130 of JSON scaffolding, leaves about 860;
	// 768 keeps about 90 bytes of slack. The subtraction holds only because all three are measured on the wire.
	MaxWorldBlobBytes = 768

	// MaxWorldKeysPerRoom bounds how many entities one room's world may hold. Derived from udpconn's reorderWindow:
	// a reliable burst wider than it goes unacked and is retried until the connection may close, and a snapshot can
	// pack one maximal entry per message. A udpconn test asserts it.
	MaxWorldKeysPerRoom = 64

	// MaxWorldMessageBytes is the batching budget for one WorldState: a threshold, not a hard bound. A batch stops
	// growing before the next entry would cross it, but a single entry is always sent, and one maximal entry plus
	// framing stays under MaxDatagramBytes, which the udpconn test asserts.
	MaxWorldMessageBytes = 1100
)

// WorldOp is what a client is asking the relay to do with an entity key.
type WorldOp string

const (
	// WorldSet stores or replaces the latest opaque blob for a key. A set that creates a key must be reliable, and a
	// lossy one on a key the relay does not hold is ignored: on a datagram transport a lossy create could overtake a
	// reliable drop and resurrect the entity for good.
	WorldSet WorldOp = "set"
	// WorldDrop removes a key; always broadcast, and the relay forgets the blob.
	WorldDrop WorldOp = "drop"
)

// World is one write against one entity (client to relay).
type World struct {
	Op WorldOp `json:"op"`
	// Authority names the lease key this write is made under; only that lease's holder may write, so a departing
	// host's in-flight packets cannot overwrite the new host's world.
	Authority string `json:"authority"`
	// Key identifies the entity, opaque and compared only by equality.
	Key string `json:"key"`
	// Blob is the entity's opaque state on a set; the relay stores the bytes and never looks inside.
	Blob json.RawMessage `json:"blob,omitempty"`
	// Reliable selects the delivery variant only: false for motion the next update supersedes, true for a change
	// that must not be missed. Every world write is stamped and delivered under the relay's sendMu either way, so a
	// lossy write may be lost but never reordered.
	Reliable bool `json:"reliable,omitempty"`
}

// WorldEntry is one entity's state inside a WorldState: a list, so one type serves a live write and a batched
// snapshot. Batching, not fragmentation: no entry is split, and every message is complete on its own.
type WorldEntry struct {
	Key string `json:"key"`
	// Blob is absent for a drop.
	Blob json.RawMessage `json:"blob,omitempty"`
	// Dropped marks this key as removed rather than updated.
	Dropped bool `json:"dropped,omitempty"`
}

// WorldState is the relay's report about one authority's world (relay to client): a live write, a handover or join
// snapshot, or a refusal.
type WorldState struct {
	Authority string `json:"authority"`
	// Holder is the lease holder the relay considers authoritative now, or empty for none. Never filter a
	// WorldState against your roster: a world entry outlives the player who wrote it, and Holder may have left.
	Holder string `json:"holder,omitempty"`
	// Seq is this room's sequencer stamp, in the same total order as Event and LeaseState. A receiver must use it:
	// reliable and lossy delivery to one peer are independent on a datagram transport, so an adapter ignores a
	// WorldState older than what it has applied for a key, or a lossy write could overtake the snapshot seeding it.
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
	// WorldSnapshot is the whole world for one authority, sent to a client that just took the lease or joined.
	WorldSnapshot = "snapshot"
	// WorldDenied is a write from someone not holding the authority lease, sent only to the writer: holdership is
	// public already, and silence would leave a stale host believing its writes land.
	WorldDenied = "denied"
	// WorldTooMany is a write refused because the room holds MaxWorldKeysPerRoom entities, sent only to the writer
	// so a host does not believe it spawned an entity nobody has.
	WorldTooMany = "too many world keys in room"
)

// ValidateWorld reports whether a world write is within bounds and names a real op, checked at the relay on receive
// and at the core before send. Authority and Key are measured on the wire, since MaxWorldBlobBytes subtracts their
// bounds from the datagram budget; the UTF-8 half matters for Authority, which must equal the lease key it names.
func ValidateWorld(w World) bool {
	switch w.Op {
	case WorldSet, WorldDrop:
	default:
		return false
	}
	if w.Authority == "" || !ValidOpaqueStringOnWire(w.Authority, MaxLeaseKeyLen) {
		return false
	}
	if w.Key == "" || !ValidOpaqueStringOnWire(w.Key, MaxWorldKeyLen) {
		return false
	}
	return JSONWireLen(w.Blob) <= MaxWorldBlobBytes
}

// ValidateWorldState reports whether a relay's world report is within bounds, checked by the core on receive. It
// mirrors ValidateWorld exactly, so it rejects nothing a relay running this code could produce.
func ValidateWorldState(st WorldState) bool {
	if !ValidOpaqueStringOnWire(st.Authority, MaxLeaseKeyLen) {
		return false
	}
	if !ValidOpaqueString(st.Holder, MaxHelloFieldLenForID) {
		return false
	}
	if len(st.Entries) > MaxWorldKeysPerRoom {
		return false
	}
	for _, e := range st.Entries {
		if e.Key == "" || !ValidOpaqueStringOnWire(e.Key, MaxWorldKeyLen) {
			return false
		}
		if JSONWireLen(e.Blob) > MaxWorldBlobBytes {
			return false
		}
	}
	return true
}

// DefaultResumeGrace is how long the relay holds a dropped client's identity for a resume token before telling the
// room it left: long enough for core.reconnectWithBackoff's first few attempts, short enough that a departed
// player's leases and seat are not held for long.
const DefaultResumeGrace = 20 * time.Second

// DefaultEscrowTimeout is how long an exchange may sit unfinished before the relay aborts it, so a party that stops
// responding without disconnecting cannot pin both blobs forever.
const DefaultEscrowTimeout = 60 * time.Second

// EscrowRetention is how long a finished exchange's record is kept, so a party that dropped between the relay
// committing and the message arriving can resume and learn the outcome. It makes atomicity survive a crash, not only
// a refusal: without it, both-or-neither holds only while both sockets stay up.
const EscrowRetention = 60 * time.Second
