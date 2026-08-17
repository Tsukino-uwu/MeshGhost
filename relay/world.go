package relay

// World custody: the relay holds the latest opaque blob per entity and hands
// the same canonical set to whoever takes the authority lease next.
//
// **This is custody, not simulation.** "Host" is really three jobs, and the
// relay can hold exactly two of them: *designation* (who is authoritative),
// which lease.v1 already does, and *custody* (holding the world so a successor
// can adopt it), which is this file. The third — *simulation*, running the AI
// and resolving damage — stays on a client and is excluded by architecture,
// because it is the only one that requires understanding the game.
//
// Without custody a new host adopts from its OWN last-known view; every peer's
// is slightly different and slightly stale, so *which* peer takes over changes
// what the world becomes. With it, adoption is a fact the relay states rather
// than a guess each client makes. The relay still understands nothing: it
// stores bytes it cannot read, exactly as escrow already does for deposits and
// Join.State does for late joiners. See agent_docs/beyond-cosmetic.md's
// peer-authority section and the ADR in agent_docs/architecture.md.
//
// **Lock order is sendMu then mu, never the reverse**, the same as online.go —
// restated here because every entry point below takes both.

import (
	"encoding/json"
	"log"
	"sort"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// worldKey identifies one entity: the authority it belongs to, and its own
// opaque key.
//
// Keyed by BOTH deliberately. Two authorities colliding on one key has no
// defined resolution — neither holder is wrong, and picking one would make the
// relay adjudicate a question about game content, which is the line it does not
// cross. Separate namespaces make the collision impossible instead of
// arbitrating it.
type worldKey struct {
	authority string
	key       string
}

// worldEntry is one entity's stored state.
type worldEntry struct {
	blob json.RawMessage
	// seq is the stamp of the write that produced this value. Kept for
	// introspection only — nothing branches on it.
	seq uint64
}

// handleWorld applies one write and broadcasts the result. Mirrors handleLease
// exactly: take sendMu, compute everything under mu, unlock, deliver.
func (r *Room) handleWorld(from string, req protocol.World) {
	// See Room.sendMu. Held for lossy writes too: Reliable selects the
	// delivery variant, never the serialization. A write that skipped this
	// could be stamped before another and delivered after it, leaving the
	// relay's map holding one value while every client's last-received is a
	// different one — and nothing would ever correct that, because snapshots
	// go only to joiners and a key may never be written again.
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	if r.world == nil {
		r.world = make(map[worldKey]*worldEntry)
	}
	wk := worldKey{authority: req.Authority, key: req.Key}
	_, exists := r.world[wk]
	l := r.leases[req.Authority]

	var outs []outgoing
	var unreliable bool

	switch {
	case l == nil || l.holder != from:
		// Not the authority. This is the case custody exists to survive: a
		// departing host's in-flight packets must not overwrite the new host's
		// world after handover. Answered explicitly rather than dropped, so a
		// stale host learns it has stopped being authoritative.
		holder := ""
		if l != nil {
			holder = l.holder
		}
		outs = r.packWorldLocked(req.Authority, holder, protocol.WorldDenied, nil, []string{from})

	case req.Op == protocol.WorldSet && !exists && !req.Reliable:
		// A lossy write that would CREATE a key. Ignored — see
		// protocol.WorldSet: the lossy and reliable planes are independent on a
		// datagram transport, so honouring this would let a stale set that was
		// dispatched before a reliable drop arrive after it and resurrect the
		// entity permanently. Requiring creation to be reliable puts creation
		// and deletion on the same ordered plane, where they cannot overtake
		// each other.
		//
		// Logged once per room rather than answered per write: this is a
		// programming error in the adapter, not a per-request outcome, and a
		// denial per lossy write would answer the busiest plane at its own rate.
		r.worldLossyCreateOnce.Do(func() {
			log.Printf("relay: room %q: a lossy world write tried to create key %q under authority %q "+
				"-- ignored; a write that creates a key must be sent reliably, or it can be overtaken "+
				"by a drop and resurrect the entity",
				r.Name, req.Key, req.Authority)
		})

	case req.Op == protocol.WorldSet && !exists && len(r.world) >= protocol.MaxWorldKeysPerRoom:
		// A resource bound, not a policy — the same shape as LeaseTooMany, and
		// answered rather than dropped for the same reason: silence would leave
		// a host believing it spawned an entity nobody has. Overwriting an
		// entry that already exists never counts against the cap.
		outs = r.packWorldLocked(req.Authority, from, protocol.WorldTooMany, nil, []string{from})

	default:
		seq := r.nextSeq()
		entry := protocol.WorldEntry{Key: req.Key}
		if req.Op == protocol.WorldDrop {
			delete(r.world, wk)
			entry.Dropped = true
		} else {
			r.world[wk] = &worldEntry{blob: req.Blob, seq: seq}
			entry.Blob = req.Blob
		}
		// **The writer is excluded from its own broadcast**, unlike an event —
		// where the echo is how a sender learns its own stamp. Here the writer
		// is by definition the authoritative source and already knows what it
		// wrote, so echoing would only double the busiest client's inbound. It
		// learns of failure by an explicit denial and of success by silence.
		// This is a decision, not an oversight.
		to := make([]string, 0, len(r.members))
		for id := range r.members {
			if id != from {
				to = append(to, id)
			}
		}
		if o, ok := r.worldMessageLocked(req.Authority, from, protocol.WorldWritten, seq,
			[]protocol.WorldEntry{entry}, to); ok {
			outs = append(outs, o)
		}
		// A lossy write keeps its lossy delivery: on a datagram transport a
		// stale position is then never retransmitted late behind a newer one,
		// which is the real value ForwardUnreliable has here.
		unreliable = !req.Reliable
	}
	r.mu.Unlock()

	for i := range outs {
		outs[i].unreliable = unreliable
	}
	r.deliver(outs)
}

// worldMessageLocked builds one WorldState. Caller holds r.mu and has already
// taken the stamp, so a caller that needs to record the stamp alongside the
// state it just stored can do so. Caller holds sendMu too, since this only
// ever produces something about to be delivered.
func (r *Room) worldMessageLocked(authority, holder, reason string, seq uint64,
	entries []protocol.WorldEntry, to []string) (outgoing, bool) {
	return out(protocol.TypeWorldState, protocol.WorldState{
		Authority: authority,
		Holder:    holder,
		Seq:       seq,
		Entries:   entries,
		Reason:    reason,
	}, to)
}

// packWorldLocked splits entries across as many WorldState messages as it
// takes to keep each one inside protocol.MaxWorldMessageBytes, stamping each
// separately. Caller holds sendMu AND r.mu.
//
// Splitting is BATCHING, not fragmentation: every message it produces is
// independently complete and applicable, no entry is ever split, and there is
// no reassembly. A single entry too large for the budget is emitted anyway —
// the budget is a threshold, and a maximal entry still fits a datagram with its
// framing (protocol.MaxWorldMessageBytes).
//
// An empty entries list still produces exactly one message, which is what
// carries a denial or a refusal.
func (r *Room) packWorldLocked(authority, holder, reason string, entries []protocol.WorldEntry, to []string) []outgoing {
	var outs []outgoing
	emit := func(batch []protocol.WorldEntry) {
		if o, ok := r.worldMessageLocked(authority, holder, reason, r.nextSeq(), batch, to); ok {
			outs = append(outs, o)
		}
	}

	var batch []protocol.WorldEntry
	for _, e := range entries {
		candidate := append(batch[:len(batch):len(batch)], e)
		if len(batch) > 0 && worldLineBytes(authority, holder, reason, candidate) > protocol.MaxWorldMessageBytes {
			emit(batch)
			batch = []protocol.WorldEntry{e}
			continue
		}
		batch = candidate
	}
	if len(batch) > 0 || len(entries) == 0 {
		emit(batch)
	}
	return outs
}

// worldLineBytes is how many bytes one WorldState occupies on the wire,
// measured rather than estimated — the envelope wrapper, the JSON field names
// and the blobs' own encoding are all real cost, and a guess that drifted from
// them would be a silent truncation on a datagram transport rather than an
// error.
//
// The stamp is measured at its widest so a batch sized now cannot overflow
// later under a larger sequencer value.
func worldLineBytes(authority, holder, reason string, entries []protocol.WorldEntry) int {
	env, err := envelope(protocol.TypeWorldState, protocol.WorldState{
		Authority: authority,
		Holder:    holder,
		Seq:       ^uint64(0),
		Entries:   entries,
		Reason:    reason,
	})
	if err != nil {
		return protocol.MaxWorldMessageBytes + 1
	}
	b, err := json.Marshal(env)
	if err != nil {
		return protocol.MaxWorldMessageBytes + 1
	}
	return len(b)
}

// sortWorldEntries puts a snapshot's entries in a stable order. Map iteration
// is deliberately randomized in Go, so without this the same world would batch
// differently every time it was sent — which turns a size regression into a
// flake rather than a failure, and makes two snapshots impossible to eyeball
// against each other.
func sortWorldEntries(entries []protocol.WorldEntry) {
	sort.Slice(entries, func(i, j int) bool { return entries[i].Key < entries[j].Key })
}

// worldSnapshotLocked returns one authority's whole world, addressed to one
// client. This is what a new lease holder adopts.
//
// Caller holds **both** sendMu and r.mu. Both, not either: see
// grantLeaseLocked, where building this in the same critical section as the
// grant is what makes "grant, then snapshot" a fact of the total order rather
// than a hope.
func (r *Room) worldSnapshotLocked(authority, to string) []outgoing {
	if !r.hasFeature(protocol.FeatureWorldV1) {
		return nil
	}
	var entries []protocol.WorldEntry
	for wk, e := range r.world {
		if wk.authority != authority {
			continue
		}
		entries = append(entries, protocol.WorldEntry{Key: wk.key, Blob: e.blob})
	}
	// **An empty world still produces a snapshot**, and that is not tidiness.
	// A new holder has to know when it may start writing: until its adoption
	// has landed it cannot tell "there is nothing to adopt" from "what I am
	// about to overwrite has not arrived yet", and a host that guesses wrong
	// writes generation 1 over a world already at generation 2 — a rollback,
	// silent, and permanent. One small message per handover buys the
	// difference. Found by cmd/meshghost-fakeadapter's own soak, 2026-08-17.
	sortWorldEntries(entries)
	holder := ""
	if l := r.leases[authority]; l != nil {
		holder = l.holder
	}
	return r.packWorldLocked(authority, holder, protocol.WorldSnapshot, entries, []string{to})
}

// worldSnapshotAllLocked returns every authority's world, addressed to one
// client — what a joining or resuming client needs to see the same room as
// everyone already in it. Caller holds sendMu AND r.mu.
//
// **Deliberately NOT gated on the recipient's snapshot.v1**, unlike
// stateSnapshotLocked. That gate is right for state, which is a per-client
// convenience; world.v1 is room-scoped, so every member of the room has it by
// construction, and copying the state gate wholesale here would silently leave
// late joiners looking at an empty world.
func (r *Room) worldSnapshotAllLocked(to string) []outgoing {
	if !r.hasFeature(protocol.FeatureWorldV1) {
		return nil
	}
	byAuthority := make(map[string][]protocol.WorldEntry, len(r.world))
	for wk, e := range r.world {
		byAuthority[wk.authority] = append(byAuthority[wk.authority],
			protocol.WorldEntry{Key: wk.key, Blob: e.blob})
	}
	authorities := make([]string, 0, len(byAuthority))
	for a := range byAuthority {
		authorities = append(authorities, a)
	}
	sort.Strings(authorities)

	var outs []outgoing
	for _, a := range authorities {
		entries := byAuthority[a]
		sortWorldEntries(entries)
		holder := ""
		if l := r.leases[a]; l != nil {
			holder = l.holder
		}
		outs = append(outs, r.packWorldLocked(a, holder, protocol.WorldSnapshot, entries, []string{to})...)
	}
	return outs
}
