package relay

// World custody: the relay holds the latest opaque blob per entity and hands the same set to whoever takes the
// authority lease next, so which peer takes over does not change what the world becomes. Custody, not simulation:
// the relay stores bytes it cannot read, and running the world stays on a client.
//
// Lock order is sendMu then mu, as in online.go; every entry point below takes both.

import (
	"encoding/json"
	"log"
	"sort"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// worldKey identifies one entity by its authority and its own opaque key: separate namespaces make a collision
// between two authorities impossible rather than something the relay would have to adjudicate.
type worldKey struct {
	authority string
	key       string
}

// worldEntry is one entity's stored state.
type worldEntry struct {
	blob json.RawMessage
	// seq is the stamp of the write that produced this value, for introspection only.
	seq uint64
}

// handleWorld applies one write and broadcasts the result, in handleLease's shape.
func (r *Room) handleWorld(from string, req protocol.World) {
	// Held for lossy writes too: a write stamped before another and delivered after it would leave the relay's map
	// and every client disagreeing, and nothing would correct it.
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
		// Not the authority: a departing host's in-flight writes must not overwrite the new host's world. Answered,
		// so a stale host learns it has stopped being authoritative.
		holder := ""
		if l != nil {
			holder = l.holder
		}
		outs = r.packWorldLocked(req.Authority, holder, protocol.WorldDenied, nil, []string{from})

	case req.Op == protocol.WorldSet && !exists && !req.Reliable:
		// A lossy write may not create a key: on a datagram transport a stale set could overtake a reliable drop and
		// resurrect the entity. Logged once, since a denial per lossy write would answer the busiest plane at its rate.
		r.worldLossyCreateOnce.Do(func() {
			log.Printf("relay: room %q: a lossy world write tried to create key %q under authority %q "+
				"-- ignored; a write that creates a key must be sent reliably, or it can be overtaken "+
				"by a drop and resurrect the entity",
				r.Name, req.Key, req.Authority)
		})

	case req.Op == protocol.WorldSet && !exists && len(r.world) >= protocol.MaxWorldKeysPerRoom:
		// A resource bound, answered so a host does not believe it spawned an entity nobody has. Overwriting an
		// existing entry never counts against it.
		outs = r.packWorldLocked(req.Authority, from, protocol.WorldTooMany, nil, []string{from})

	case req.Op != protocol.WorldSet && req.Op != protocol.WorldDrop:
		// An op this switch does not name is ignored, never stored, so the bounds above do not rest on
		// protocol.ValidateWorld alone. Silent, since WorldDenied would claim the writer is not the authority.
		r.worldUnknownOpOnce.Do(func() {
			log.Printf("relay: room %q: a world write named op %q, which is neither %q nor %q -- ignored",
				r.Name, req.Op, protocol.WorldSet, protocol.WorldDrop)
		})

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
		// The writer is excluded from its own broadcast, unlike an event: it is the authority and already knows what
		// it wrote. It learns of failure by a denial and of success by silence.
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
		// A lossy write keeps lossy delivery, so a stale position is never retransmitted behind a newer one. A drop
		// is always reliable: a lost drop is never corrected, since snapshots go only to joiners.
		unreliable = !req.Reliable && req.Op != protocol.WorldDrop
	}
	r.mu.Unlock()

	for i := range outs {
		outs[i].unreliable = unreliable
	}
	r.deliver(outs)
}

// worldMessageLocked builds one WorldState with a stamp the caller already took, so it can store the stamp alongside
// the state. Caller holds sendMu and r.mu.
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

// packWorldLocked splits entries across as many WorldState messages as keep each inside
// protocol.MaxWorldMessageBytes, stamping each. Batching, not fragmentation: every message is complete, no entry is
// split, and an oversized entry goes alone, since a maximal entry still fits a datagram with its framing. An empty
// list still produces the one message that carries a denial. Caller holds sendMu and r.mu.
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

// worldLineBytes is one WorldState's size on the wire, measured rather than estimated: a guess that drifted would be
// a silent truncation on a datagram transport. The stamp is measured at its widest, so a batch cannot overflow later.
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

// sortWorldEntries puts a snapshot's entries in a stable order, so the same world always batches the same way and a
// size regression fails rather than flakes.
func sortWorldEntries(entries []protocol.WorldEntry) {
	sort.Slice(entries, func(i, j int) bool { return entries[i].Key < entries[j].Key })
}

// worldSnapshotLocked returns one authority's whole world, addressed to the new lease holder that adopts it. Caller
// holds both sendMu and r.mu, for grantLeaseLocked's reason.
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
	// An empty world still produces a snapshot: until its adoption lands, a new holder cannot tell "nothing to
	// adopt" from "not arrived yet", and writing early would silently roll the world back.
	sortWorldEntries(entries)
	holder := ""
	if l := r.leases[authority]; l != nil {
		holder = l.holder
	}
	return r.packWorldLocked(authority, holder, protocol.WorldSnapshot, entries, []string{to})
}

// worldSnapshotAllLocked returns every authority's world, addressed to a joining or resuming client. Unlike
// stateSnapshotLocked it is not gated on snapshot.v1: world.v1 is room-scoped, so every member has it. Caller holds
// sendMu and r.mu.
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
