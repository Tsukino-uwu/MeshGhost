package relay

// Relay introspection: "what does the server think is true right now."
//
// agent_docs/beyond-cosmetic.md §10 listed this as reserved, and until
// 2026-08-17 that was right — **a relay that forwards and forgets has no state
// worth inspecting.** Rooms and a client count are visible from the log lines
// join and leave already print. That changed the moment the relay started
// holding facts nobody else can see: who holds which lease and for how much
// longer, which exchanges are mid-flight and how far along, and whose identity
// is parked waiting for a reconnect. A wedged trade or a key nobody can claim
// is now a question the log cannot answer, because the relevant state is a map
// in memory rather than an event that was printed once.
//
// **This is a snapshot function, not an endpoint.** The relay has no
// introspection port, no HTTP server, and nothing new to authenticate. That is
// deliberate: agent_docs/architecture.md's transport-discovery ADR worked to
// keep the relay free of any pre-auth surface, and adding a status listener
// would hand that back for a debugging convenience. cmd/meshghost-relay's
// -introspect instead logs this to the relay's own log, which is where a host
// is already looking and which is already trusted with join/leave lines.
//
// **Nothing here exposes a secret.** Resume tokens are credentials — anyone
// holding one can take over that session, including its outstanding exchanges
// — so only their COUNT appears. Escrow blobs are the contents of a trade in
// progress and are likewise never rendered; only how far the exchange has got.

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/textfmt"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// MemberSnapshot is one client's visible state in a room.
type MemberSnapshot struct {
	PlayerID string
	// Transport is "tcp", "udp" or "quic" — a room may legitimately mix them.
	Transport string
	// Suspended means this identity is parked waiting for a reconnect: still
	// in the roster, receiving nothing. The single most confusing state to
	// debug without this, because such a client looks present in every log
	// line that ever mentioned it and is silently unreachable.
	Suspended bool
	// MaxReceiveHz is this client's own requested per-peer cap; 0 is uncapped.
	MaxReceiveHz int
	// Features is this member's CLIENT-scoped capabilities only — the
	// room-scoped ones are a property of the room and are reported there
	// instead of repeated on every line.
	//
	// Without this the tool could not answer the question it most obviously
	// invites once a player drops: "why was that identity not held?" The
	// answer is usually "that client never asked for resume.v1", which is
	// per-client and therefore invisible on the room's own feature line.
	Features []string
}

// LeaseSnapshot is one held key.
type LeaseSnapshot struct {
	Key    string
	Holder string
	// ExpiresIn is how long the current hold has left. Negative means the
	// expiry timer has fired but has not been processed yet, which is a
	// legitimate transient rather than a bug.
	ExpiresIn time.Duration
}

// EscrowSnapshot is one exchange. Blobs are deliberately absent — see the
// file comment.
type EscrowSnapshot struct {
	ID        string
	Phase     string
	Parties   []string
	Deposited []string
	Committed []string
	// Terminal means this record is finished and is only being kept for its
	// retention window, so a party that dropped before hearing the outcome
	// can still be told it on resume.
	Terminal bool
	Reason   string
}

// WorldSnapshot is one entity the relay holds custody of. The blob is
// deliberately absent — same posture as escrow blobs (see the file comment),
// plus its size, which is the part a host debugging "why is this room's world
// so big" actually needs.
type WorldSnapshot struct {
	Authority string
	Key       string
	// Holder is whoever currently holds the authority lease, or empty for
	// nobody. Empty is a normal, expected state rather than a fault: the world
	// deliberately outlives its authority, waiting for a successor to adopt it.
	Holder    string
	BlobBytes int
	Seq       uint64
}

// StateFanoutSnapshot answers one question: how much of this room's state
// fan-out crosses areas, and how much of that the relay's own filter is
// removing. Until 2026-08-28 there was no filter and this only reported what
// one WOULD save, which is why SuppressibleShare is named for a hypothetical.
//
// Counts and bytes only -- the area_id STRINGS are deliberately never exposed
// here. They are opaque game data, a host may paste an introspect dump into an
// issue, and the relay having no idea what an area means is a promise this file
// should not be the one to break. DistinctAreas is a count for the same reason:
// a room where it is always 1 is a room where filtering can save nothing.
type StateFanoutSnapshot struct {
	// StatesIn is how many state messages this room has accepted for
	// forwarding -- the liveness denominator; if this is not moving, the rest
	// means nothing.
	StatesIn uint64
	// Recipients is the sum over those messages of how many members each was
	// fanned out to. This is the O(n^2) term made visible.
	Recipients uint64
	// CrossAreaRecipients is how many of those recipients were in another
	// area: both areas known, and different. It is the CEILING on what area
	// filtering can suppress, not what it did suppress.
	CrossAreaRecipients uint64
	// FilteredRecipients is what the filter actually dropped -- cross-area AND
	// the recipient having declared own_area_only. It is lower than
	// CrossAreaRecipients by exactly the traffic to clients that did not opt
	// in: the cross-map adapters, and any client too old to know the field.
	// The gap between the two is therefore the remaining headroom.
	FilteredRecipients uint64
	// The same three numbers weighted by message size, which is what actually
	// matters on the wire. Payload only, excluding the envelope -- see
	// stateRecipients for why, and why the shares are unaffected by that.
	PayloadBytes          uint64
	CrossAreaPayloadBytes uint64
	FilteredPayloadBytes  uint64
	// DistinctAreas is how many different areas the room's members are
	// currently spread across.
	DistinctAreas int
}

// offeredBytes is the pre-filter total: what this room would have put on the
// wire with no area filtering at all. Both shares below divide by it, so
// neither can end up comparing a post-filter numerator against a post-filter
// denominator and reporting a share that shrinks as the filter gets better.
func (f StateFanoutSnapshot) offeredBytes() uint64 {
	return f.PayloadBytes + f.FilteredPayloadBytes
}

// SuppressibleShare is the fraction of state bytes that area filtering COULD
// remove, 0 to 1 -- the ceiling, reached only if every client opted in. This is
// the number the relay-side filtering decision originally rested on, and it
// stays meaningful afterwards as the size of the opportunity.
func (f StateFanoutSnapshot) SuppressibleShare() float64 {
	if f.offeredBytes() == 0 {
		return 0
	}
	return float64(f.CrossAreaPayloadBytes) / float64(f.offeredBytes())
}

// SavedShare is the fraction area filtering ACTUALLY removed. It equals
// SuppressibleShare in a room where every client opted in, and is lower by the
// share going to cross-map adapters and older clients.
func (f StateFanoutSnapshot) SavedShare() float64 {
	if f.offeredBytes() == 0 {
		return 0
	}
	return float64(f.FilteredPayloadBytes) / float64(f.offeredBytes())
}

// RoomSnapshot is one room's whole visible state.
type RoomSnapshot struct {
	Name        string
	GameID      string
	GameVersion string
	Features    []string
	// Seq is the room sequencer's current value — how many ordered control
	// messages this room has issued. Mostly useful as a liveness signal: a
	// room where something is stuck shows a seq that has stopped moving.
	Seq uint64
	// StateFanout is the cross-area measurement described on Room's counters:
	// how much of this room's state traffic every recipient's core throws away
	// at render time. Measurement only -- nothing in the relay branches on it.
	StateFanout StateFanoutSnapshot
	Members     []MemberSnapshot
	Leases      []LeaseSnapshot
	Escrows     []EscrowSnapshot
	World       []WorldSnapshot
}

// Snapshot is the whole relay's visible state at one moment.
type Snapshot struct {
	Clients    int
	MaxClients int
	// SuspendedSessions is how many dropped identities are currently being
	// held waiting for a reconnect — not how many resumable sessions exist,
	// which for a healthy room is simply everyone. The COUNT only: the tokens
	// themselves are credentials and never appear.
	SuspendedSessions int
	Rooms             []RoomSnapshot
}

// Snapshot captures the relay's current state.
//
// Room pointers are collected under s.mu and then each room is locked
// separately, rather than locking a room while still holding s.mu. Nothing in
// this package currently nests those the other way round, so the nested form
// would also be safe today — but it would make this function the reason a
// future r.mu-then-s.mu path becomes a deadlock, and a debugging aid must not
// be the thing that constrains the code it inspects.
func (s *Server) Snapshot() Snapshot {
	s.mu.Lock()
	snap := Snapshot{
		Clients:    s.clientCount,
		MaxClients: s.MaxClients,
	}
	// Counted, not len(s.suspended): that map holds every LIVE identity too,
	// since a session is registered when its token is issued rather than when
	// it drops (see resume.go's suspendedSession). Reporting the map size
	// would say "3 suspended sessions" about a healthy three-player room,
	// which is exactly the kind of confidently wrong number a debugging aid
	// must never produce.
	for _, sess := range s.suspended {
		if sess.suspended {
			snap.SuspendedSessions++
		}
	}
	if snap.MaxClients <= 0 {
		snap.MaxClients = DefaultMaxClients
	}
	rooms := make([]*Room, 0, len(s.rooms))
	for _, r := range s.rooms {
		rooms = append(rooms, r)
	}
	s.mu.Unlock()

	now := time.Now()
	for _, r := range rooms {
		snap.Rooms = append(snap.Rooms, r.snapshot(now))
	}
	// Stable ordering, so two snapshots taken a second apart can be eyeballed
	// against each other — map iteration order would make every line move.
	sort.Slice(snap.Rooms, func(i, j int) bool { return snap.Rooms[i].Name < snap.Rooms[j].Name })
	return snap
}

func (r *Room) snapshot(now time.Time) RoomSnapshot {
	r.mu.Lock()
	defer r.mu.Unlock()

	out := RoomSnapshot{
		Name:        r.Name,
		GameID:      r.GameID,
		GameVersion: r.GameVersion,
		Features:    append([]string(nil), r.features...),
		Seq:         r.seqCounter,
		StateFanout: StateFanoutSnapshot{
			StatesIn:              r.statesIn,
			Recipients:            r.stateRecipientsOut,
			CrossAreaRecipients:   r.stateRecipientsCross,
			FilteredRecipients:    r.stateRecipientsFiltered,
			PayloadBytes:          r.stateBytesForwarded,
			CrossAreaPayloadBytes: r.stateBytesCrossArea,
			FilteredPayloadBytes:  r.stateBytesFiltered,
		},
	}
	// Counted from live membership rather than from lastState, so a departed
	// member's stale area never inflates it.
	areas := make(map[string]struct{}, len(r.members))
	for id := range r.members {
		if st, ok := r.lastState[id]; ok && st.AreaID != "" {
			areas[st.AreaID] = struct{}{}
		}
	}
	out.StateFanout.DistinctAreas = len(areas)
	for _, c := range r.members {
		clientScoped := make([]string, 0, len(c.features))
		for _, f := range c.features {
			if !protocol.IsRoomScopedFeature(f) {
				clientScoped = append(clientScoped, f)
			}
		}
		out.Members = append(out.Members, MemberSnapshot{
			PlayerID:     c.PlayerID,
			Transport:    c.transport,
			Suspended:    c.suspended,
			MaxReceiveHz: c.maxReceiveHz,
			Features:     clientScoped,
		})
	}
	for key, l := range r.leases {
		out.Leases = append(out.Leases, LeaseSnapshot{
			Key:       key,
			Holder:    l.holder,
			ExpiresIn: l.expiresAt.Sub(now).Truncate(time.Millisecond),
		})
	}
	for id, e := range r.escrows {
		es := EscrowSnapshot{
			ID:       id,
			Phase:    e.phase,
			Parties:  []string{e.parties[0], e.parties[1]},
			Terminal: e.terminal,
			Reason:   e.reason,
		}
		for _, p := range e.parties {
			if e.deposited[p] {
				es.Deposited = append(es.Deposited, p)
			}
			if e.committed[p] {
				es.Committed = append(es.Committed, p)
			}
		}
		out.Escrows = append(out.Escrows, es)
	}
	for wk, e := range r.world {
		holder := ""
		if l := r.leases[wk.authority]; l != nil {
			holder = l.holder
		}
		out.World = append(out.World, WorldSnapshot{
			Authority: wk.authority,
			Key:       wk.key,
			Holder:    holder,
			BlobBytes: len(e.blob),
			Seq:       e.seq,
		})
	}

	sort.Slice(out.Members, func(i, j int) bool { return out.Members[i].PlayerID < out.Members[j].PlayerID })
	sort.Slice(out.Leases, func(i, j int) bool { return out.Leases[i].Key < out.Leases[j].Key })
	sort.Slice(out.Escrows, func(i, j int) bool { return out.Escrows[i].ID < out.Escrows[j].ID })
	sort.Slice(out.World, func(i, j int) bool {
		if out.World[i].Authority != out.World[j].Authority {
			return out.World[i].Authority < out.World[j].Authority
		}
		return out.World[i].Key < out.World[j].Key
	})
	return out
}

// String renders a snapshot as the multi-line block cmd/meshghost-relay
// writes to its log.
//
// Written to be readable by a host rather than parsed by a program: this
// answers "why can nobody claim that key" and "is that trade stuck", which are
// questions someone asks while staring at a terminal. A machine-readable form
// would need a stable format and therefore a compatibility promise, for a
// consumer that does not exist.
//
// A room with nothing beyond members collapses to one line, so the common case
// — a purely cosmetic room, which is every room today — does not bury the one
// room that has something going on.
func (s Snapshot) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "relay state: %d/%d client slots in use, %d room(s), %d suspended session(s)",
		s.Clients, s.MaxClients, len(s.Rooms), s.SuspendedSessions)
	for _, r := range s.Rooms {
		fmt.Fprintf(&b, "\n  room %q game=%q", r.Name, r.GameID)
		if r.GameVersion != "" {
			fmt.Fprintf(&b, " version=%q", r.GameVersion)
		}
		fmt.Fprintf(&b, " members=%d seq=%d", len(r.Members), r.Seq)
		if len(r.Features) > 0 {
			fmt.Fprintf(&b, " features=%s", strings.Join(r.Features, ","))
		}
		// Only once the room has actually forwarded something: a line reading
		// "0 states, 0% cross-area" on a freshly created room is noise that
		// looks like a measurement.
		if f := r.StateFanout; f.StatesIn > 0 {
			fmt.Fprintf(&b, "\n    state fan-out: %d states to %d recipients (%s), %d area(s)",
				f.StatesIn, f.Recipients, textfmt.Bytes(f.PayloadBytes), f.DistinctAreas)
			fmt.Fprintf(&b, "\n      cross-area: %d recipients, %s -- %.0f%% of offered bytes are for a peer in another area",
				f.CrossAreaRecipients, textfmt.Bytes(f.CrossAreaPayloadBytes), f.SuppressibleShare()*100)
			fmt.Fprintf(&b, "\n      filtered: %d recipients, %s -- %.0f%% of offered bytes never sent (the rest go to clients that render other areas)",
				f.FilteredRecipients, textfmt.Bytes(f.FilteredPayloadBytes), f.SavedShare()*100)
		}
		for _, m := range r.Members {
			fmt.Fprintf(&b, "\n    %s over %s", m.PlayerID, m.Transport)
			if m.MaxReceiveHz > 0 {
				fmt.Fprintf(&b, ", capped at %dHz per peer", m.MaxReceiveHz)
			}
			if len(m.Features) > 0 {
				fmt.Fprintf(&b, ", %s", strings.Join(m.Features, "+"))
			}
			if m.Suspended {
				// Called out in words rather than a flag: a suspended member
				// is present in the roster and receiving nothing, which is
				// exactly the state someone debugging a frozen ghost needs
				// spelled out.
				b.WriteString(" -- SUSPENDED, holding its identity for a reconnect")
			}
		}
		for _, l := range r.Leases {
			fmt.Fprintf(&b, "\n    lease %q held by %s, expires in %s", l.Key, l.Holder, l.ExpiresIn)
		}
		// Rolled up per authority rather than one line per entity: a room with
		// a full world has MaxWorldKeysPerRoom of them, and 64 lines of
		// "entity, 300 bytes" would bury the members and leases above. The
		// question this answers is "is a world being held, how big, and does
		// anyone own it" -- the individual keys are the adapter's business.
		for _, w := range rollUpWorld(r.World) {
			fmt.Fprintf(&b, "\n    world %q: %d entit%s, %d bytes held",
				w.Authority, w.Entities, plural(w.Entities), w.Bytes)
			if w.Holder == "" {
				// Worth spelling out: this is what an orphaned world looks
				// like, and it is the state custody exists to produce rather
				// than a fault. Someone reading this while wondering why nobody
				// is simulating needs the difference stated.
				b.WriteString(" -- NOBODY holds this authority, waiting for a successor to adopt it")
			} else {
				fmt.Fprintf(&b, ", held by %s", w.Holder)
			}
		}
		for _, e := range r.Escrows {
			fmt.Fprintf(&b, "\n    exchange %q between %s: %s (deposited %d/2, committed %d/2)",
				e.ID, strings.Join(e.Parties, " and "), e.Phase, len(e.Deposited), len(e.Committed))
			if e.Terminal {
				fmt.Fprintf(&b, " -- finished%s, kept briefly so a reconnecting party can be told",
					reasonSuffix(e.Reason))
			}
		}
	}
	return b.String()
}

// worldRollup is one authority's world summarized for the log.
type worldRollup struct {
	Authority string
	Holder    string
	Entities  int
	Bytes     int
}

// rollUpWorld groups a room's entities by authority, preserving the sorted
// order snapshot already put them in.
func rollUpWorld(entries []WorldSnapshot) []worldRollup {
	var out []worldRollup
	for _, w := range entries {
		if len(out) == 0 || out[len(out)-1].Authority != w.Authority {
			out = append(out, worldRollup{Authority: w.Authority, Holder: w.Holder})
		}
		cur := &out[len(out)-1]
		cur.Entities++
		cur.Bytes += w.BlobBytes
	}
	return out
}

func plural(n int) string {
	if n == 1 {
		return "y"
	}
	return "ies"
}

func reasonSuffix(reason string) string {
	if reason == "" {
		return ""
	}
	return " (" + reason + ")"
}
