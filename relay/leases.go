package relay

// Lease authority over an opaque key. The locking discipline in online.go's header governs this file.

import (
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ---------------------------------------------------------------------------
// Leases
// ---------------------------------------------------------------------------

// lease is one held key. The timer makes it a lease rather than a grant: a holder that vanishes must not wedge a key
// forever, and only a clock guarantees that without knowing what the key means.
type lease struct {
	holder    string
	expiresAt time.Time
	timer     *time.Timer
}

// handleLease applies one lease request and broadcasts the result.
func (r *Room) handleLease(from string, req protocol.Lease) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	if r.leases == nil {
		r.leases = make(map[string]*lease)
	}
	l := r.leases[req.Key]

	var outs []outgoing
	broadcast := r.memberIDsLocked()
	asker := []string{from}

	switch req.Op {
	case protocol.LeaseClaim:
		switch {
		case l != nil && l.holder != from:
			// Denied, and told only to the asker: broadcasting failed claims would storm a room when it is busiest.
			if o, ok := out(protocol.TypeLeaseState, protocol.LeaseState{
				Key: req.Key, Holder: l.holder, Seq: r.nextSeq(),
				ExpiresAt: l.expiresAt.UnixMilli(), Reason: protocol.LeaseDenied,
			}, asker); ok {
				outs = append(outs, o)
			}
		case l == nil && r.leaseTableFullLocked(from):
			// A resource bound: without it a client grows the table by claiming a fresh key per message.
			if o, ok := out(protocol.TypeLeaseState, protocol.LeaseState{
				Key: req.Key, Seq: r.nextSeq(), Reason: protocol.LeaseTooMany,
			}, asker); ok {
				outs = append(outs, o)
			}
		default:
			// Free, or ours: a re-claim by the holder is a renew, so a client never loses its key to its own retry.
			outs = append(outs, r.grantLeaseLocked(req.Key, from, protocol.ClampLeaseTTL(req.TTLMs), broadcast)...)
		}

	case protocol.LeaseRenew:
		if l != nil && l.holder == from {
			outs = append(outs, r.grantLeaseLocked(req.Key, from, protocol.ClampLeaseTTL(req.TTLMs), broadcast)...)
		} else {
			// Denied, never upgraded into a claim: a client that lost its key must find out, not quietly retake it.
			st := protocol.LeaseState{Key: req.Key, Seq: r.nextSeq(), Reason: protocol.LeaseDenied}
			if l != nil {
				st.Holder = l.holder
				st.ExpiresAt = l.expiresAt.UnixMilli()
			}
			if o, ok := out(protocol.TypeLeaseState, st, asker); ok {
				outs = append(outs, o)
			}
		}

	case protocol.LeaseRelease:
		if l != nil && l.holder == from {
			outs = append(outs, r.freeLeaseLocked(req.Key, protocol.LeaseReleased, broadcast)...)
		}
		// A release from a non-holder is ignored: answering would let a peer probe which keys are held.
	}
	r.mu.Unlock()

	r.deliver(outs)
}

// maxLeasesPerMember bounds how many keys one member may hold, so it takes eight members to fill the table, the
// ratio escrow's per-member cap has to its room cap. A held key never lapses while renewed, so without this one
// member could deny every other claim, and in a world.v1 room every world write.
const maxLeasesPerMember = protocol.MaxLeasesPerRoom / 8

// leaseTableFullLocked is the claim-time bound: the room's table and this claimant's share. Only a claim for a new
// key consults it; a renew takes no new slot and must never be refused. Caller holds r.mu.
func (r *Room) leaseTableFullLocked(claimant string) bool {
	return len(r.leases) >= protocol.MaxLeasesPerRoom ||
		r.leasesBy[claimant] >= maxLeasesPerMember
}

// heldLeaseLocked and releasedLeaseLocked keep r.leasesBy in step with r.leases, in one place: a drifting count
// either locks a member out of a table with room in it or un-bounds the cap. Caller holds r.mu.
func (r *Room) heldLeaseLocked(holder string) {
	if r.leasesBy == nil {
		r.leasesBy = make(map[string]int)
	}
	r.leasesBy[holder]++
}

func (r *Room) releasedLeaseLocked(holder string) {
	if n := r.leasesBy[holder] - 1; n > 0 {
		r.leasesBy[holder] = n
	} else {
		delete(r.leasesBy, holder)
	}
}

// grantLeaseLocked gives key to holder for ttl, re-arming its expiry, and returns the change announced to `to`,
// followed, when the holder changed, by the world that holder inherits. Caller holds both sendMu and r.mu: the
// adoption snapshot is built in the same critical section as the grant, or a new holder could start writing and then
// receive a snapshot older than its own writes.
func (r *Room) grantLeaseLocked(key, holder string, ttl time.Duration, to []string) []outgoing {
	l := r.leases[key]
	// Captured before the assignment: a renew adopts nothing, so it sends no world, and the room sees only whether
	// the holder or the expiry, to the second, changed.
	previousHolder := ""
	previousExpirySec := int64(0)
	if l != nil {
		previousExpirySec = l.expiresAt.Unix()
	}
	if l == nil {
		l = &lease{}
		r.leases[key] = l
		r.heldLeaseLocked(holder)
	} else {
		previousHolder = l.holder
		// No caller hands over in place today, but the count must survive one: a miscount is a lockout until restart.
		if previousHolder != holder {
			r.releasedLeaseLocked(previousHolder)
			r.heldLeaseLocked(holder)
		}
	}
	if l.timer != nil {
		l.timer.Stop()
	}
	l.holder = holder
	l.expiresAt = time.Now().Add(ttl)
	// AfterFunc rather than a sweeper goroutine: a room that never uses leases starts nothing.
	l.timer = time.AfterFunc(ttl, func() { r.expireLease(key, holder) })

	st := protocol.LeaseState{
		Key: key, Holder: holder, Seq: r.nextSeq(),
		ExpiresAt: l.expiresAt.UnixMilli(), Reason: protocol.LeaseGranted,
	}
	// A renew that changes nothing a receiver renders goes to the asker alone, or one client's renew rate drives an
	// N-way fan-out. The expiry renders to the second, so a burst of renews collapses to one broadcast.
	announce := to
	if holder == previousHolder && l.expiresAt.Unix() == previousExpirySec {
		announce = []string{holder}
	}
	var outs []outgoing
	if o, ok := out(protocol.TypeLeaseState, st, announce); ok {
		outs = append(outs, o)
	}
	if holder != previousHolder {
		outs = append(outs, r.worldSnapshotLocked(key, holder)...)
	}
	return outs
}

// freeLeaseLocked drops key and returns the announcement. The world this key was authority over is deliberately
// kept for the next claimant, since a crashed or handing-off host's successor needs it; it goes with the room, and
// protocol.MaxWorldKeysPerRoom bounds it meanwhile. Caller holds r.mu.
func (r *Room) freeLeaseLocked(key, reason string, to []string) []outgoing {
	l := r.leases[key]
	if l == nil {
		return nil
	}
	if l.timer != nil {
		l.timer.Stop()
	}
	delete(r.leases, key)
	r.releasedLeaseLocked(l.holder)
	if o, ok := out(protocol.TypeLeaseState, protocol.LeaseState{
		Key: key, Seq: r.nextSeq(), Reason: reason,
	}, to); ok {
		return []outgoing{o}
	}
	return nil
}

// expireLease is the TTL firing. The holder and expiry checks make it a no-op after a renew or release that raced it:
// Timer.Stop cannot stop a callback already running.
func (r *Room) expireLease(key, holder string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	l := r.leases[key]
	if l == nil || l.holder != holder || time.Now().Before(l.expiresAt) {
		r.mu.Unlock()
		return
	}
	outs := r.freeLeaseLocked(key, protocol.LeaseExpired, r.memberIDsLocked())
	r.mu.Unlock()
	r.deliver(outs)
}

// releaseLeasesOfLocked frees every lease held by holder when a player really leaves; a suspended one keeps its keys
// for its resume. Caller holds r.mu.
func (r *Room) releaseLeasesOfLocked(holder string, to []string) []outgoing {
	var outs []outgoing
	for key, l := range r.leases {
		if l.holder == holder {
			outs = append(outs, r.freeLeaseLocked(key, protocol.LeaseHolderLeft, to)...)
		}
	}
	return outs
}

// leaseSnapshotLocked returns every held key's state, addressed to one resuming client. Caller holds r.mu.
func (r *Room) leaseSnapshotLocked(to string) []outgoing {
	var outs []outgoing
	for key, l := range r.leases {
		if o, ok := out(protocol.TypeLeaseState, protocol.LeaseState{
			Key: key, Holder: l.holder, Seq: r.nextSeq(),
			ExpiresAt: l.expiresAt.UnixMilli(), Reason: protocol.LeaseGranted,
		}, []string{to}); ok {
			outs = append(outs, o)
		}
	}
	return outs
}
