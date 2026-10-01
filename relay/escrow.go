package relay

// Two-party escrow: both deposits commit or neither does. The locking discipline in online.go's header governs this
// file.

import (
	"encoding/json"
	"sort"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ---------------------------------------------------------------------------
// Escrow
// ---------------------------------------------------------------------------

// escrow is one two-sided exchange. A lease grants exclusive access, never an atomic swap: if one side of a trade
// vanishes after handing over, an item is destroyed or duplicated, so both-or-neither needs its own mechanism.
type escrow struct {
	parties   [2]string
	blobs     map[string]json.RawMessage
	deposited map[string]bool
	committed map[string]bool
	phase     string
	reason    string
	timer     *time.Timer
	// terminal records are kept for protocol.EscrowRetention, so a party that dropped between the commit and its
	// message can resume and learn the outcome; otherwise both-or-neither holds only while both sockets stay up.
	terminal bool
	// terminalAt orders the eviction that keeps the table bounded; zero while live.
	terminalAt time.Time
}

func (e *escrow) isParty(id string) bool {
	return e.parties[0] == id || e.parties[1] == id
}

// escrowOwedToSuspendedLocked reports whether a party to e is away with the outcome unread, the case a retained
// record is for; a party not suspended has read it or has left. Caller holds r.mu.
func (r *Room) escrowOwedToSuspendedLocked(e *escrow) bool {
	for _, id := range e.parties {
		if id == "" {
			continue
		}
		if c, ok := r.members[id]; ok && c.suspended {
			return true
		}
	}
	return false
}

// maxEscrowRecordsPerRoom bounds the escrow table, live and terminal together. It sits well clear of the live cap,
// so a full table never refuses an open: it evicts a terminal record instead.
const maxEscrowRecordsPerRoom = 4 * protocol.MaxEscrowsPerRoom

// escrowTableFullLocked is the open-time bound: live exchanges only, per room and per opener, so retained records
// never refuse a trade. Counted rather than scanned, under r.mu on every open; the counters move only in
// openedEscrowLocked and finishEscrowLocked. Caller holds r.mu.
func (r *Room) escrowTableFullLocked(opener string) bool {
	return r.escrowsLive >= protocol.MaxEscrowsPerRoom ||
		r.escrowsLiveBy[opener] >= protocol.MaxLiveEscrowsPerMember
}

// openedEscrowLocked records a new live exchange against the room and its
// opener, evicting the oldest terminal record first if the table is at
// maxEscrowRecordsPerRoom. Caller holds r.mu.
func (r *Room) openedEscrowLocked(opener string) {
	for len(r.escrows) >= maxEscrowRecordsPerRoom {
		if !r.evictTerminalEscrowLocked() {
			// Cannot happen: live exchanges fill at most a quarter of the table. Break rather than spin if it does.
			break
		}
	}
	r.escrowsLive++
	if r.escrowsLiveBy == nil {
		r.escrowsLiveBy = make(map[string]int)
	}
	r.escrowsLiveBy[opener]++
}

// evictTerminalEscrowLocked deletes one terminal record and reports whether it found one. A record no suspended
// party is waiting on goes first, oldest first: by age alone, an uninvolved member's open-and-abort churn would push
// out a committed record a returning party still needs. If every record is owed, the oldest of those goes, so the
// table stays bounded. Caller holds r.mu.
func (r *Room) evictTerminalEscrowLocked() bool {
	pick := func(owed bool) (string, *escrow) {
		bestID, bestAt := "", time.Time{}
		var best *escrow
		for id, e := range r.escrows {
			if !e.terminal || r.escrowOwedToSuspendedLocked(e) != owed {
				continue
			}
			if best == nil || e.terminalAt.Before(bestAt) {
				bestID, bestAt, best = id, e.terminalAt, e
			}
		}
		return bestID, best
	}
	oldestID, oldest := pick(false)
	if oldest == nil {
		oldestID, oldest = pick(true)
	}
	if oldest == nil {
		return false
	}
	if oldest.timer != nil {
		oldest.timer.Stop()
	}
	delete(r.escrows, oldestID)
	return true
}

// escrowStateLocked renders the wire form. Blobs are attached only once committed, or the second depositor could
// decide its offer after seeing the first. Caller holds r.mu.
func (r *Room) escrowStateLocked(id string, e *escrow) protocol.EscrowState {
	st := protocol.EscrowState{
		ID:      id,
		Seq:     r.nextSeq(),
		Phase:   e.phase,
		Parties: []string{e.parties[0], e.parties[1]},
		Reason:  e.reason,
	}
	for _, p := range e.parties {
		if e.deposited[p] {
			st.Deposited = append(st.Deposited, p)
		}
		if e.committed[p] {
			st.Committed = append(st.Committed, p)
		}
	}
	if e.phase == protocol.EscrowPhaseCommitted {
		st.Blobs = make(map[string]json.RawMessage, len(e.blobs))
		for k, v := range e.blobs {
			st.Blobs[k] = v
		}
	}
	return st
}

// handleEscrow applies one escrow step and reports the result to both
// parties.
func (r *Room) handleEscrow(from string, req protocol.Escrow) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	if r.escrows == nil {
		r.escrows = make(map[string]*escrow)
	}
	e := r.escrows[req.ID]

	var outs []outgoing
	switch req.Op {
	case protocol.EscrowOpen:
		switch {
		case e != nil:
			// An id in use, terminal or not, is refused: reusing it would answer "did it commit?" for the wrong
			// exchange.
			if o, ok := out(protocol.TypeEscrowState, protocol.EscrowState{
				ID: req.ID, Seq: r.nextSeq(), Phase: protocol.EscrowPhaseAborted,
				Reason: protocol.EscrowReasonRejected,
			}, []string{from}); ok {
				outs = append(outs, o)
			}
		case req.With == "" || req.With == from || !r.isMemberLocked(req.With) || r.escrowTableFullLocked(from):
			if o, ok := out(protocol.TypeEscrowState, protocol.EscrowState{
				ID: req.ID, Seq: r.nextSeq(), Phase: protocol.EscrowPhaseAborted,
				Reason: protocol.EscrowReasonRejected,
			}, []string{from}); ok {
				outs = append(outs, o)
			}
		default:
			e = &escrow{
				parties:   [2]string{from, req.With},
				blobs:     make(map[string]json.RawMessage, 2),
				deposited: make(map[string]bool, 2),
				committed: make(map[string]bool, 2),
				phase:     protocol.EscrowPhaseOpen,
			}
			id := req.ID
			e.timer = time.AfterFunc(protocol.DefaultEscrowTimeout, func() { r.timeoutEscrow(id) })
			r.openedEscrowLocked(from)
			r.escrows[id] = e
			outs = append(outs, r.announceEscrowLocked(id, e)...)
		}

	case protocol.EscrowDeposit:
		if e != nil && !e.terminal && e.isParty(from) && !e.deposited[from] {
			blob := req.Blob
			if blob == nil {
				// No blob is still a deposit (a gift); JSON null gives the committed map an entry for both parties.
				blob = json.RawMessage("null")
			}
			e.blobs[from] = blob
			e.deposited[from] = true
			if e.deposited[e.parties[0]] && e.deposited[e.parties[1]] {
				e.phase = protocol.EscrowPhaseDeposited
			}
			// One announcement per step: if this step completed the exchange, only the terminal state goes, or an
			// adapter would briefly see it pending after it finished.
			if done := r.maybeCommitLocked(req.ID, e); len(done) > 0 {
				outs = append(outs, done...)
			} else {
				outs = append(outs, r.announceEscrowLocked(req.ID, e)...)
			}
		}

	case protocol.EscrowCommit:
		if e != nil && !e.terminal && e.isParty(from) && !e.committed[from] {
			// A commit before both deposits is recorded, not refused: it means "ready", so message order cannot matter.
			e.committed[from] = true
			// One announcement per step, as for a deposit.
			if done := r.maybeCommitLocked(req.ID, e); len(done) > 0 {
				outs = append(outs, done...)
			} else {
				outs = append(outs, r.announceEscrowLocked(req.ID, e)...)
			}
		}

	case protocol.EscrowAbort:
		if e != nil && !e.terminal && e.isParty(from) {
			outs = append(outs, r.finishEscrowLocked(req.ID, e, protocol.EscrowPhaseAborted, protocol.EscrowReasonAborted)...)
		}
	}
	r.mu.Unlock()

	r.deliver(outs)
}

// maybeCommitLocked completes the exchange once both parties have deposited and committed: the whole of
// both-or-neither is this one condition. Caller holds r.mu.
func (r *Room) maybeCommitLocked(id string, e *escrow) []outgoing {
	if e.terminal {
		return nil
	}
	a, b := e.parties[0], e.parties[1]
	if e.deposited[a] && e.deposited[b] && e.committed[a] && e.committed[b] {
		return r.finishEscrowLocked(id, e, protocol.EscrowPhaseCommitted, "")
	}
	return nil
}

// finishEscrowLocked drives an exchange to a terminal phase, discarding blobs unless it committed, and schedules the
// record's retirement. Caller holds r.mu.
func (r *Room) finishEscrowLocked(id string, e *escrow, phase, reason string) []outgoing {
	if e.timer != nil {
		e.timer.Stop()
	}
	if !e.terminal {
		// The only transition out of live, so the only place the counters fall; guarded so a caller that forgets
		// cannot decrement a room into refusing every open.
		r.escrowsLive--
		if n := r.escrowsLiveBy[e.parties[0]] - 1; n > 0 {
			r.escrowsLiveBy[e.parties[0]] = n
		} else {
			delete(r.escrowsLiveBy, e.parties[0])
		}
	}
	e.phase = phase
	e.reason = reason
	e.terminal = true
	e.terminalAt = time.Now()
	if phase != protocol.EscrowPhaseCommitted {
		// Aborted blobs are destroyed and never sent, which makes an abort safe to trigger on a disconnect.
		e.blobs = nil
	}
	outs := r.announceEscrowLocked(id, e)
	e.timer = time.AfterFunc(protocol.EscrowRetention, func() {
		r.mu.Lock()
		if cur, ok := r.escrows[id]; ok && cur == e {
			delete(r.escrows, id)
		}
		r.mu.Unlock()
	})
	return outs
}

// announceEscrowLocked sends the current state to both parties. Caller holds r.mu.
func (r *Room) announceEscrowLocked(id string, e *escrow) []outgoing {
	st := r.escrowStateLocked(id, e)
	if o, ok := out(protocol.TypeEscrowState, st, []string{e.parties[0], e.parties[1]}); ok {
		return []outgoing{o}
	}
	return nil
}

// timeoutEscrow aborts an exchange unfinished after protocol.DefaultEscrowTimeout, so a party that goes quiet
// without disconnecting cannot pin both blobs.
func (r *Room) timeoutEscrow(id string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	e := r.escrows[id]
	if e == nil || e.terminal {
		r.mu.Unlock()
		return
	}
	outs := r.finishEscrowLocked(id, e, protocol.EscrowPhaseAborted, protocol.EscrowReasonTimeout)
	r.mu.Unlock()
	r.deliver(outs)
}

// abortEscrowsOfLocked aborts every live exchange party is in, when a player really leaves: those can never
// complete, and the other side's blob would be held until the timeout. Caller holds r.mu.
func (r *Room) abortEscrowsOfLocked(party string) []outgoing {
	var outs []outgoing
	for id, e := range r.escrows {
		if !e.terminal && e.isParty(party) {
			outs = append(outs, r.finishEscrowLocked(id, e, protocol.EscrowPhaseAborted, protocol.EscrowReasonPartyLeft)...)
		}
	}
	return outs
}

// maxEscrowSnapshotLines bounds the escrow section of a resume snapshot to a quarter of maxSnapshotLines, as
// maxMissedEventsPerMember does: anyone can open exchanges naming a client, and without it could push that client's
// world, lease and state seeds off the snapshot.
const maxEscrowSnapshotLines = maxSnapshotLines / 4

// escrowSnapshotLocked returns the state of every exchange to is a party to, retained terminal ones included, so a
// client that dropped between commit and delivery learns the outcome. Caller holds r.mu.
func (r *Room) escrowSnapshotLocked(to string) []outgoing {
	// Live first, since those wait on this client; then terminal, newest first, since an older outcome is likelier
	// already seen.
	type held struct {
		id string
		e  *escrow
	}
	var live, done []held
	for id, e := range r.escrows {
		if !e.isParty(to) {
			continue
		}
		if e.terminal {
			done = append(done, held{id, e})
		} else {
			live = append(live, held{id, e})
		}
	}
	sort.Slice(done, func(i, j int) bool { return done[i].e.terminalAt.After(done[j].e.terminalAt) })
	// Sorted so a client's retry gets the same subset once the cap bites.
	sort.Slice(live, func(i, j int) bool { return live[i].id < live[j].id })

	var outs []outgoing
	for _, h := range append(live, done...) {
		if len(outs) >= maxEscrowSnapshotLines {
			break
		}
		if o, ok := out(protocol.TypeEscrowState, r.escrowStateLocked(h.id, h.e), []string{to}); ok {
			outs = append(outs, o)
		}
	}
	return outs
}

// isMemberLocked reports whether id is in this room. Caller holds r.mu.
func (r *Room) isMemberLocked(id string) bool {
	_, ok := r.members[id]
	return ok
}
