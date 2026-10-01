package relay

// Relay introspection: what the server believes right now, for state that lives only in memory (leases, exchanges,
// parked identities). A snapshot the relay logs itself, not an endpoint, so it adds no pre-auth surface. Nothing here
// exposes a secret: resume tokens appear only as a count, and escrow and world blobs never.

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
	// Transport is "tcp", "udp" or "quic"; a room may mix them.
	Transport string
	// Suspended means this identity is parked waiting for a reconnect: in the roster, receiving nothing.
	Suspended bool
	// MaxReceiveHz is this client's own requested per-peer cap; 0 is uncapped.
	MaxReceiveHz int
	// Features is this member's client-scoped capabilities only (room-scoped ones are on the room), which answers
	// why an identity was not held: that client never asked for resume.v1.
	Features []string
}

// LeaseSnapshot is one held key.
type LeaseSnapshot struct {
	Key    string
	Holder string
	// ExpiresIn is how long the hold has left; negative is a fired timer not yet processed, a legitimate transient.
	ExpiresIn time.Duration
}

// EscrowSnapshot is one exchange; its blobs are deliberately absent.
type EscrowSnapshot struct {
	ID        string
	Phase     string
	Parties   []string
	Deposited []string
	Committed []string
	// Terminal means the record is finished and kept only for its retention window, so a party that dropped can
	// still learn the outcome.
	Terminal bool
	Reason   string
}

// WorldSnapshot is one entity the relay holds custody of: its size, never its blob.
type WorldSnapshot struct {
	Authority string
	Key       string
	// Holder is the authority lease's holder, or empty: the world outlives its authority by design.
	Holder    string
	BlobBytes int
	Seq       uint64
}

// StateFanoutSnapshot answers how much of this room's state fan-out crosses areas, and how much of that the relay's
// filter removes. Counts and bytes only: area_id strings are opaque game data and are never exposed here.
type StateFanoutSnapshot struct {
	// StatesIn is how many state messages this room accepted for forwarding: the liveness denominator.
	StatesIn uint64
	// Recipients sums, over those messages, how many members each reached after the receive-rate gate: the O(n^2)
	// term.
	Recipients uint64
	// CrossAreaRecipients is how many of those were in another known area: the ceiling on what area filtering can
	// suppress, not what it did.
	CrossAreaRecipients uint64
	// FilteredRecipients is what the filter dropped: cross-area and the recipient declared own_area_only. The gap to
	// CrossAreaRecipients is traffic to clients that did not opt in.
	FilteredRecipients uint64
	// The same three weighted by payload size, envelope excluded (see stateRecipients); PayloadBytes is post-gate and
	// so post-filter.
	PayloadBytes          uint64
	CrossAreaPayloadBytes uint64
	FilteredPayloadBytes  uint64
	// DistinctAreas is how many areas the room's members are spread across; always 1 means filtering saves nothing.
	DistinctAreas int
}

// offeredBytes is the pre-filter total, what the room would have sent with no area filtering. Both shares divide by
// it, so neither shrinks as the filter improves. What the receive-rate gate refused was never sent and is not in it.
func (f StateFanoutSnapshot) offeredBytes() uint64 {
	return f.PayloadBytes + f.FilteredPayloadBytes
}

// SuppressibleShare is the fraction of state bytes area filtering could remove, 0 to 1: the ceiling, reached only if
// every client opted in.
func (f StateFanoutSnapshot) SuppressibleShare() float64 {
	if f.offeredBytes() == 0 {
		return 0
	}
	return float64(f.CrossAreaPayloadBytes) / float64(f.offeredBytes())
}

// SavedShare is the fraction area filtering actually removed, lower than SuppressibleShare by the share going to
// clients that did not opt in.
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
	// Seq is the room sequencer's current value; a stuck room shows it stopped moving.
	Seq uint64
	// StateFanout is the cross-area measurement; nothing in the relay branches on it.
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
	// SuspendedSessions is how many dropped identities are held waiting for a reconnect, not how many resumable
	// sessions exist; the tokens never appear.
	SuspendedSessions int
	Rooms             []RoomSnapshot
}

// Snapshot captures the relay's current state. Room pointers are collected under s.mu and each room is locked after
// releasing it, so a debugging aid never creates a lock order the code it inspects must respect.
func (s *Server) Snapshot() Snapshot {
	s.mu.Lock()
	snap := Snapshot{
		Clients:    s.clientCount,
		MaxClients: s.MaxClients,
	}
	// Counted, not len(s.suspended): that map holds every live identity too, registered when its token is issued.
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
	// Stable ordering, so two snapshots a second apart can be compared by eye.
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
	// Counted from live membership, so a departed member's stale area never inflates it.
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

// String renders a snapshot as the multi-line block cmd/meshghost-relay logs, for a host to read rather than a
// program to parse. A purely cosmetic room collapses to one line, so it does not bury a room with something going on.
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
			// %q: a stranger chooses the room's feature strings, and a newline in one would forge lines in this dump.
			fmt.Fprintf(&b, " features=%q", strings.Join(r.Features, ","))
		}
		// Only once the room has forwarded something: zeros on a new room would look like a measurement.
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
				// Spelled out: in the roster and receiving nothing is the state behind a frozen ghost.
				b.WriteString(" -- SUSPENDED, holding its identity for a reconnect")
			}
		}
		for _, l := range r.Leases {
			fmt.Fprintf(&b, "\n    lease %q held by %s, expires in %s", l.Key, l.Holder, l.ExpiresIn)
		}
		// Rolled up per authority: a full world's MaxWorldKeysPerRoom lines would bury the members and leases above.
		for _, w := range rollUpWorld(r.World) {
			fmt.Fprintf(&b, "\n    world %q: %d entit%s, %d bytes held",
				w.Authority, w.Entities, plural(w.Entities), w.Bytes)
			if w.Holder == "" {
				// An orphaned world is what custody exists to produce, not a fault, so it is spelled out.
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

// rollUpWorld groups a room's entities by authority, keeping the order snapshot sorted them in.
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
