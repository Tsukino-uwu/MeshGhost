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
	"encoding/json"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ---------------------------------------------------------------------------
// Escrow
// ---------------------------------------------------------------------------

// escrow is one two-sided exchange.
//
// **A lease grants exclusive access, never an atomic swap.** A trade is
// two-sided — both or neither — and if one side vanishes after handing over,
// an item is destroyed or duplicated; that is exactly where historical
// Pokémon trading exploits came from (agent_docs/beyond-cosmetic.md §5). No
// amount of lease discipline prevents it, which is why this is a separate
// mechanism rather than a use of the one above.
type escrow struct {
	parties   [2]string
	blobs     map[string]json.RawMessage
	deposited map[string]bool
	committed map[string]bool
	phase     string
	reason    string
	timer     *time.Timer
	// terminal records are kept for protocol.EscrowRetention after they
	// finish, so a party that dropped between the relay committing and the
	// message arriving can resume and be told the outcome. Without that,
	// "both or neither" holds only while both sockets stay up — the case that
	// never fails in testing and always fails in the field.
	terminal bool
}

func (e *escrow) isParty(id string) bool {
	return e.parties[0] == id || e.parties[1] == id
}

// escrowStateLocked renders the wire form. Blobs are attached ONLY once committed:
// until then neither side may see the other's contribution, or the second
// depositor could decide what to offer after seeing what it was offered.
// Caller holds r.mu.
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
			// An id already in use, terminal or not. Refused rather than
			// reopened: reusing an id that a counterparty may still be
			// holding a terminal record for is how a "did it commit?" answer
			// silently becomes the wrong exchange's.
			if o, ok := out(protocol.TypeEscrowState, protocol.EscrowState{
				ID: req.ID, Seq: r.nextSeq(), Phase: protocol.EscrowPhaseAborted,
				Reason: protocol.EscrowReasonRejected,
			}, []string{from}); ok {
				outs = append(outs, o)
			}
		case req.With == "" || req.With == from || !r.isMemberLocked(req.With) || len(r.escrows) >= protocol.MaxEscrowsPerRoom:
			// No counterparty, itself, someone who is not here, or the room
			// is already at its concurrent-exchange bound.
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
			r.escrows[id] = e
			outs = append(outs, r.announceEscrowLocked(id, e)...)
		}

	case protocol.EscrowDeposit:
		if e != nil && !e.terminal && e.isParty(from) && !e.deposited[from] {
			blob := req.Blob
			if blob == nil {
				// A deposit with no blob is still a deposit — an adapter may
				// legitimately offer nothing on one side (a gift). Stored as
				// JSON null so the committed map has an entry for both
				// parties either way.
				blob = json.RawMessage("null")
			}
			e.blobs[from] = blob
			e.deposited[from] = true
			if e.deposited[e.parties[0]] && e.deposited[e.parties[1]] {
				e.phase = protocol.EscrowPhaseDeposited
			}
			// One announcement per step, never two. If this step completed
			// the exchange, the terminal state (with the blobs) is the only
			// thing worth sending — emitting the intermediate state first
			// would hand both parties a "deposited" immediately followed by a
			// "committed" for the same step, and an adapter watching phases
			// would briefly see the exchange as still pending after it had
			// already finished.
			if done := r.maybeCommitLocked(req.ID, e); len(done) > 0 {
				outs = append(outs, done...)
			} else {
				outs = append(outs, r.announceEscrowLocked(req.ID, e)...)
			}
		}

	case protocol.EscrowCommit:
		if e != nil && !e.terminal && e.isParty(from) && !e.committed[from] {
			// A commit before both deposits is recorded, not refused: it
			// means "I am ready", and the exchange still cannot complete
			// until both blobs are in. That keeps the ordering of the two
			// messages from mattering, which over a network it should not.
			e.committed[from] = true
			// One announcement per step, never two. If this step completed
			// the exchange, the terminal state (with the blobs) is the only
			// thing worth sending — emitting the intermediate state first
			// would hand both parties a "deposited" immediately followed by a
			// "committed" for the same step, and an adapter watching phases
			// would briefly see the exchange as still pending after it had
			// already finished.
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

// maybeCommitLocked completes the exchange once both parties have deposited
// AND both have committed — the whole of "both or neither" is this one
// condition. Caller holds r.mu.
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

// finishEscrowLocked drives an exchange to a terminal phase, discarding blobs
// unless it committed, and schedules the record's retirement. Caller holds
// r.mu.
func (r *Room) finishEscrowLocked(id string, e *escrow, phase, reason string) []outgoing {
	if e.timer != nil {
		e.timer.Stop()
	}
	e.phase = phase
	e.reason = reason
	e.terminal = true
	if phase != protocol.EscrowPhaseCommitted {
		// Aborted: the blobs are destroyed here and never sent to anyone,
		// which is what makes an abort safe to trigger on a disconnect.
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

// announceEscrowLocked sends the current state to both parties. Caller holds
// r.mu.
func (r *Room) announceEscrowLocked(id string, e *escrow) []outgoing {
	st := r.escrowStateLocked(id, e)
	if o, ok := out(protocol.TypeEscrowState, st, []string{e.parties[0], e.parties[1]}); ok {
		return []outgoing{o}
	}
	return nil
}

// timeoutEscrow aborts an exchange that has sat unfinished for
// protocol.DefaultEscrowTimeout. Without this, one party simply going quiet
// without disconnecting pins both sides' blobs indefinitely.
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

// abortEscrowsOfLocked aborts every live exchange party is in. Caller holds
// r.mu. Called when a player really leaves — an in-flight exchange whose
// counterparty is gone can never complete, and leaving it open would hold the
// other side's blob hostage until the timeout.
func (r *Room) abortEscrowsOfLocked(party string) []outgoing {
	var outs []outgoing
	for id, e := range r.escrows {
		if !e.terminal && e.isParty(party) {
			outs = append(outs, r.finishEscrowLocked(id, e, protocol.EscrowPhaseAborted, protocol.EscrowReasonPartyLeft)...)
		}
	}
	return outs
}

// escrowSnapshotLocked returns the current state of every exchange to is a
// party to, including terminal ones still within their retention window.
// This is the half of resumption that makes atomicity survive a crash: a
// client that dropped in the instant between commit and delivery learns the
// outcome instead of being left permanently unsure. Caller holds r.mu.
func (r *Room) escrowSnapshotLocked(to string) []outgoing {
	var outs []outgoing
	for id, e := range r.escrows {
		if !e.isParty(to) {
			continue
		}
		if o, ok := out(protocol.TypeEscrowState, r.escrowStateLocked(id, e), []string{to}); ok {
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
