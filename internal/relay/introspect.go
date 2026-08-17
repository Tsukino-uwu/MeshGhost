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

// RoomSnapshot is one room's whole visible state.
type RoomSnapshot struct {
	Name        string
	GameID      string
	GameVersion string
	Features    []string
	// Seq is the room sequencer's current value — how many ordered control
	// messages this room has issued. Mostly useful as a liveness signal: a
	// room where something is stuck shows a seq that has stopped moving.
	Seq     uint64
	Members []MemberSnapshot
	Leases  []LeaseSnapshot
	Escrows []EscrowSnapshot
}

// Snapshot is the whole relay's visible state at one moment.
type Snapshot struct {
	Clients    int
	MaxClients int
	// SuspendedSessions is how many dropped identities are being held. The
	// COUNT only: the tokens themselves are credentials and never appear.
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
		Clients:           s.clientCount,
		MaxClients:        s.MaxClients,
		SuspendedSessions: len(s.suspended),
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
	}
	for _, c := range r.members {
		out.Members = append(out.Members, MemberSnapshot{
			PlayerID:     c.PlayerID,
			Transport:    c.transport,
			Suspended:    c.suspended,
			MaxReceiveHz: c.maxReceiveHz,
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

	sort.Slice(out.Members, func(i, j int) bool { return out.Members[i].PlayerID < out.Members[j].PlayerID })
	sort.Slice(out.Leases, func(i, j int) bool { return out.Leases[i].Key < out.Leases[j].Key })
	sort.Slice(out.Escrows, func(i, j int) bool { return out.Escrows[i].ID < out.Escrows[j].ID })
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
		for _, m := range r.Members {
			fmt.Fprintf(&b, "\n    %s over %s", m.PlayerID, m.Transport)
			if m.MaxReceiveHz > 0 {
				fmt.Fprintf(&b, ", capped at %dHz per peer", m.MaxReceiveHz)
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

func reasonSuffix(reason string) string {
	if reason == "" {
		return ""
	}
	return " (" + reason + ")"
}
