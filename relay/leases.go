package relay

// Split out of online.go on 2026-08-25, where leases, escrow, late-join
// snapshots and session resumption were four independent subsystems sharing one
// 1,115-line file. relay/world.go had already set the precedent for one
// subsystem per file; these four simply had not followed it yet.
//
// **The locking discipline in online.go's header governs this file too, and it
// is the only subtle thing here.** In short: r.mu guards the room's maps and
// every handler computes its outgoing messages under it and delivers them AFTER
// unlocking; r.sendMu is held across BOTH stamp and deliver so the total order
// assigned is the order actually sent. Lock order is always sendMu then mu.
// Read online.go's header before changing anything in this file.

import (
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ---------------------------------------------------------------------------
// Leases
// ---------------------------------------------------------------------------

// lease is one held key. The timer is what makes this a lease rather than a
// permanent grant: **the hard part is lifetime, not the sequencer**
// (agent_docs/beyond-cosmetic.md §4). A holder that vanishes mid-trade must
// not wedge a key forever, and a clock is the only thing that can guarantee
// that without knowing what the key means.
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
			// Held by someone else. Denied — and told only to the asker: a
			// failed claim is nobody else's business, and broadcasting one
			// would turn a contested key into a message storm exactly when
			// the room is busiest.
			if o, ok := out(protocol.TypeLeaseState, protocol.LeaseState{
				Key: req.Key, Holder: l.holder, Seq: r.nextSeq(),
				ExpiresAt: l.expiresAt.UnixMilli(), Reason: protocol.LeaseDenied,
			}, asker); ok {
				outs = append(outs, o)
			}
		case l == nil && r.leaseTableFullLocked(from):
			// A resource bound, not a policy: without it a client can grow
			// the relay's lease table without limit by claiming a fresh key
			// per message. Denied like any other refusal.
			if o, ok := out(protocol.TypeLeaseState, protocol.LeaseState{
				Key: req.Key, Seq: r.nextSeq(), Reason: protocol.LeaseTooMany,
			}, asker); ok {
				outs = append(outs, o)
			}
		default:
			// Free, or already ours — a re-claim by the holder is a renew,
			// which keeps a retrying client from losing its own key to its
			// own retry.
			outs = append(outs, r.grantLeaseLocked(req.Key, from, protocol.ClampLeaseTTL(req.TTLMs), broadcast)...)
		}

	case protocol.LeaseRenew:
		if l != nil && l.holder == from {
			outs = append(outs, r.grantLeaseLocked(req.Key, from, protocol.ClampLeaseTTL(req.TTLMs), broadcast)...)
		} else {
			// A renew from a non-holder is denied, never silently upgraded
			// into a claim: a client that thinks it still holds a key it lost
			// must find out, not quietly take it back.
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
		// A release from a non-holder is ignored outright — there is nothing
		// to tell anyone, and answering would let a peer probe which keys are
		// held without ever claiming one.
	}
	r.mu.Unlock()

	r.deliver(outs)
}

// maxLeasesPerMember bounds how many keys ONE member may hold at once, and it
// is derived from the room cap rather than chosen: eight members' cooperation
// to fill the table, exactly the ratio protocol.MaxLiveEscrowsPerMember has to
// protocol.MaxEscrowsPerRoom.
//
// Added 2026-09-08. Escrow was given a per-member bound in the 2026-09-02
// adversarial review and leases were not, though the abuse is the same one and
// worse here: a re-claim by the current holder is a RENEW, so a held key never
// lapses, and one member claiming protocol.MaxLeasesPerRoom keys and renewing
// them answered every other member's lease.claim with LeaseTooMany for as long
// as it kept renewing. In a world.v1 room nobody else could write to the world
// at all, since a write is only accepted from the holder of the lease it names.
// docs/security.md carried it as an accepted risk with this fix shape named.
const maxLeasesPerMember = protocol.MaxLeasesPerRoom / 8

// leaseTableFullLocked is the claim-time bound: the room's whole table, and
// this claimant's own share of it. Only a claim for a NEW key consults it -- a
// renew, and a re-claim by the current holder, take no new slot and must never
// be refused, or a member at its own cap would lose the keys it already holds
// to its own retries. Caller holds r.mu.
func (r *Room) leaseTableFullLocked(claimant string) bool {
	return len(r.leases) >= protocol.MaxLeasesPerRoom ||
		r.leasesBy[claimant] >= maxLeasesPerMember
}

// heldLeaseLocked and releasedLeaseLocked keep r.leasesBy in step with
// r.leases. Both transitions live here rather than at their call sites because
// a count that drifts one way silently locks a member out of a table with room
// in it, and the other way un-bounds the cap entirely. Caller holds r.mu.
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

// grantLeaseLocked gives key to holder for ttl, (re)arming its expiry timer,
// and returns the broadcast announcing it — followed, when the holder actually
// CHANGED and this room has world.v1, by the world that holder now inherits.
//
// Caller holds **both** sendMu and r.mu. Today only handleLease calls this and
// it holds both; the requirement is stated because a future caller holding only
// r.mu would break the handover silently rather than loudly.
//
// **The adoption snapshot is built here, in the same critical section as the
// grant, and not dispatched afterwards.** If it were dispatched afterwards the
// new holder could receive its grant, legally begin writing (it holds the lease
// now), and only then receive a snapshot built before its own writes — reverting
// itself, with the relay's map correct and the new host stale. Building it here
// and delivering it in the same sendMu window makes "grant, then snapshot" a
// fact of the total order rather than a hope.
func (r *Room) grantLeaseLocked(key, holder string, ttl time.Duration, to []string) []outgoing {
	l := r.leases[key]
	// Captured before the assignment below. A renew, and a re-claim by the
	// current holder, must produce NO snapshot: nothing was adopted, and
	// re-sending the world on every renew would put the busiest client's whole
	// world back on the wire at its renew rate.
	previousHolder := ""
	if l == nil {
		l = &lease{}
		r.leases[key] = l
		r.heldLeaseLocked(holder)
	} else {
		previousHolder = l.holder
		// A handover in place: no caller does this today (handleLease only
		// reaches here for a free key or the current holder's own renew), but
		// the count has to survive one arriving, since a miscount here is a
		// lockout nobody can clear without restarting the relay.
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
	// AfterFunc rather than a sweeper goroutine: a timer exists only while a
	// lease does, so a room that never uses leases starts nothing at all and
	// this whole subsystem stays genuinely free for the cosmetic case.
	l.timer = time.AfterFunc(ttl, func() { r.expireLease(key, holder) })

	st := protocol.LeaseState{
		Key: key, Holder: holder, Seq: r.nextSeq(),
		ExpiresAt: l.expiresAt.UnixMilli(), Reason: protocol.LeaseGranted,
	}
	var outs []outgoing
	if o, ok := out(protocol.TypeLeaseState, st, to); ok {
		outs = append(outs, o)
	}
	if holder != previousHolder {
		outs = append(outs, r.worldSnapshotLocked(key, holder)...)
	}
	return outs
}

// freeLeaseLocked drops key and returns the broadcast announcing it. Caller
// holds r.mu.
//
// **The world this key was authority over is deliberately NOT freed here.**
// Tying world lifetime to lease lifetime would destroy the world in exactly the
// case custody exists for: a host crashing arrives here via expireSuspended →
// finishLeave → releaseLeasesOfLocked, and a clean handoff arrives here too. A
// host that deliberately hands off still wants the world to survive to its
// successor. The world waits, un-owned, for the next claimant; the only thing
// that discards it is the room itself going away (dropIfEmpty), and what
// accumulates in the meantime is bounded by protocol.MaxWorldKeysPerRoom —
// a cap, not a leak.
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

// expireLease is the TTL firing. The holder check makes it idempotent
// against the timer having been superseded by a renew or a release that raced
// it — Timer.Stop cannot promise a callback already in flight did not run.
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

// releaseLeasesOfLocked frees every lease held by holder. Caller holds r.mu.
// Called when a player really leaves — not when it merely suspends, since a
// resuming client must find its keys where it left them.
func (r *Room) releaseLeasesOfLocked(holder string, to []string) []outgoing {
	var outs []outgoing
	for key, l := range r.leases {
		if l.holder == holder {
			outs = append(outs, r.freeLeaseLocked(key, protocol.LeaseHolderLeft, to)...)
		}
	}
	return outs
}

// leaseSnapshotLocked returns the current state of every held key, addressed
// to one client. Sent to a resuming client, whose own view of the room was
// discarded when its connection dropped. Caller holds r.mu.
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
