package relay

// The relay's side of everything past the cosmetic state plane: the room
// sequencer, event routing, lease authority, escrow, and the per-room
// bookkeeping session resumption needs. Design reasoning lives in
// agent_docs/beyond-cosmetic.md; the ADR is in agent_docs/architecture.md.
//
// **Nothing in this file understands a game, and that is a property to
// defend, not a coincidence.** Every identifier that crosses it — a lease
// key, an escrow id, an event payload, a feature name — is an opaque string
// or an opaque blob, compared for equality and never parsed, exactly like
// area_id and anim already are (CLAUDE.md's opaque-field rule). The relay
// arbitrates by *arrival*, never by merit: it picks the first claim and that
// becomes the fact by fiat, and everyone agrees because everyone was told the
// same answer, not because the answer was right. Judging rightness is
// simulation authority, which is excluded by construction.
//
// Locking discipline, which is the only subtle thing here, and which two
// separate locks exist to express:
//
//   - r.mu guards members, leases, escrows, lastState and seqCounter. Every
//     handler computes its outgoing messages under it and delivers them AFTER
//     unlocking, via the outgoing/deliver pair — the same snapshot-then-act
//     shape Room.forward uses, and for the same reason (a Send can block for a
//     whole WriteTimeout against a stalled peer, and doing that under r.mu
//     would freeze every other operation in the room).
//   - r.sendMu is held across BOTH halves — stamp and deliver — by every entry
//     point in this file, including the timer callbacks. Without it the total
//     order is assigned correctly and then delivered in a different one, since
//     two handlers can be stamped 1 and 2 and race to the socket after each
//     has released r.mu. That is precisely what a sequencer exists to prevent,
//     and it failed the total-order test the first time it ran.
//
// **Lock order is always sendMu then mu.** Nothing here may take r.mu and then
// reach for sendMu.

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// outgoing is one message and the recipients it goes to, computed under r.mu
// and sent after unlocking. Bundling them keeps every handler in this file to
// one shape: build outs, unlock, deliver.
type outgoing struct {
	env protocol.Envelope
	to  []string
	// unreliable asks deliver for the lossy variant. Set by exactly one
	// caller — a lossy world write in world.go — and false everywhere else.
	unreliable bool
}

// deliver sends each outgoing, reliably unless it asked otherwise. Reliable is
// the default and covers everything in this file: it all carries a decision —
// who holds a key, whether a trade completed — and unlike a cosmetic position
// sample, a dropped one is never superseded by the next.
//
// This used to say there was no unreliable variant on purpose. That was right
// while the control plane was only decisions; world.v1 added a plane where a
// write can be a continuous position sample that the next update supersedes, so
// the exception is now real. **It selects the delivery variant only.** Every
// outgoing here, lossy ones included, is still stamped and delivered under
// sendMu, so a lossy message may be lost and can never be reordered against
// another — see world.go's handleWorld and protocol.World.Reliable.
func (r *Room) deliver(outs []outgoing) {
	for _, o := range outs {
		if o.unreliable {
			r.ForwardUnreliable(o.env, o.to)
			continue
		}
		r.Forward(o.env, o.to)
	}
}

// out builds an outgoing, or returns ok=false if the payload could not be
// marshaled (which nothing in this package can actually cause — every
// payload here is plain data — so a false is a bug worth logging, not a
// condition to handle).
func out(t protocol.MessageType, payload any, to []string) (outgoing, bool) {
	env, err := envelope(t, payload)
	if err != nil {
		log.Printf("relay: BUG: %s payload failed to marshal: %v", t, err)
		return outgoing{}, false
	}
	return outgoing{env: env, to: to}, true
}

// hasFeature reports whether this room's agreed feature set contains name.
// The set is fixed when the room's first member joins and never changes, so
// this needs no lock — a later joiner that disagrees is refused at the
// handshake rather than allowed to alter it (protocol.ReasonFeatureMismatch).
func (r *Room) hasFeature(name string) bool {
	return protocol.HasFeature(r.features, name)
}

// wants reports whether this client asked for a client-scoped capability.
// Room-scoped ones are answered by Room.hasFeature instead — the room agreed
// on those collectively, and a single client's opinion of them is not a
// question that can be asked.
func (c *Client) wants(name string) bool {
	return protocol.HasFeature(c.features, name)
}

// effectiveFeatures is what is actually in force for one client: the room's
// agreed room-scoped set, plus the client-scoped capabilities this client
// asked for. Echoed in its Welcome so a client reads back what it really has
// rather than a room-wide answer to a per-client question.
func effectiveFeatures(r *Room, c *Client) []string {
	out := append([]string(nil), r.features...)
	for _, f := range c.features {
		if !protocol.IsRoomScopedFeature(f) {
			out = append(out, f)
		}
	}
	return protocol.NormalizeFeatures(out)
}

// nextSeq returns this room's next sequencer stamp. Caller holds r.mu, which
// is the entire trick: the stamp is assigned inside the same critical section
// that snapshots the recipient set, so the order the relay assigns is the
// order every member observes. A counter, incremented under a lock already
// being taken — this is what agent_docs/beyond-cosmetic.md §6 meant by "the
// sequencer half is cheap."
//
// Starts at 1, so a zero Seq on the wire is unambiguously "unstamped" rather
// than "the first one".
func (r *Room) nextSeq() uint64 {
	r.seqCounter++
	return r.seqCounter
}

// memberIDsLocked returns every current member's id, suspended ones included.
// Caller holds r.mu. Suspended members are included because they are still in
// the room as far as identity is concerned — Room.forward is what actually
// declines to write to them.
func (r *Room) memberIDsLocked() []string {
	ids := make([]string, 0, len(r.members))
	for id := range r.members {
		ids = append(ids, id)
	}
	return ids
}

// ---------------------------------------------------------------------------
// Event plane
// ---------------------------------------------------------------------------

// handleEvent stamps and routes one client event. from is the sender's
// relay-assigned id, which overwrites whatever the payload claimed — the
// same server-side stamping State.PlayerID already gets, and for the same
// reason.
//
// The sender always receives its own event back. That is deliberate and is
// what makes the sequencer useful rather than decorative: the stamp is the
// relay's, so the sender has no other way to learn where its own event landed
// in the total order, and a client that cannot place its own action in the
// order cannot reason about anyone else's either. An adapter tells its own
// echo apart by comparing From against its player_id.
//
// An event addressed to a player_id that is not in the room is delivered to
// nobody but the sender's own echo. No error is sent back: the relay has no
// way to distinguish "typo" from "they left half a second ago", and an
// adapter waiting on a reply already has to handle a reply that never comes.
func (r *Room) handleEvent(from string, ev protocol.Event) {
	// See Room.sendMu: the stamp and its delivery must not be separable, or
	// two concurrent events are stamped in one order and sent in another.
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	ev.From = from

	r.mu.Lock()
	ev.Seq = r.nextSeq()
	var to []string
	if ev.To == "" {
		to = r.memberIDsLocked()
	} else {
		to = []string{from}
		if ev.To != from {
			if _, ok := r.members[ev.To]; ok {
				to = append(to, ev.To)
			}
		}
	}
	r.mu.Unlock()

	if o, ok := out(protocol.TypeEvent, ev, to); ok {
		r.deliver([]outgoing{o})
	}
}

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
		case l == nil && len(r.leases) >= protocol.MaxLeasesPerRoom:
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
	} else {
		previousHolder = l.holder
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

// ---------------------------------------------------------------------------
// Late-join snapshot
// ---------------------------------------------------------------------------

// recordState remembers a player's most recent valid state, so a client
// joining later can be shown an existing player immediately instead of
// waiting for that player's next update.
//
// Recorded unconditionally, where this used to be gated on the room having
// asked for snapshots. Once snapshot.v1 became client-scoped the gate could no
// longer be answered here at all — the sender's own capabilities say nothing
// about whether some future joiner will want a seed — and the storage is one
// State per member, bounded by MaxClients, which is not worth a condition. The
// gate that survives is the one that matters: whether to SEND a seed, which is
// the receiving client's own question.
func (r *Room) recordState(playerID string, st protocol.State) {
	r.mu.Lock()
	if r.lastState == nil {
		r.lastState = make(map[string]protocol.State)
	}
	r.lastState[playerID] = st
	r.mu.Unlock()
}

// stateSnapshotLocked returns a Join carrying each other member's last known
// state, addressed to one client. Join.State has been reserved for exactly
// this since the contract was written and never populated until now; the
// receiving side (core) already handled a populated one correctly.
// Caller holds r.mu.
func (r *Room) stateSnapshotLocked(to string) []outgoing {
	// The RECIPIENT's own capability, not the room's: a seed changes only what
	// this one client receives, so a room may freely mix members that want one
	// and members that do not.
	recipient, ok := r.members[to]
	if !ok || !recipient.wants(protocol.FeatureSnapshotV1) {
		return nil
	}
	var outs []outgoing
	for id, st := range r.lastState {
		if id == to {
			continue
		}
		if _, stillHere := r.members[id]; !stillHere {
			continue
		}
		snapshot := st
		if o, ok := out(protocol.TypeJoin, protocol.Join{PlayerID: id, State: &snapshot}, []string{to}); ok {
			outs = append(outs, o)
		}
	}
	return outs
}

// forgetState drops a departed player's snapshot, so a long-lived relay does
// not accumulate one per player who ever visited. Called only on a real
// leave — a suspended (resumable) player keeps its snapshot, which is what
// lets it come back without every peer's ghost of it jumping.
func (r *Room) forgetState(playerID string) {
	r.mu.Lock()
	delete(r.lastState, playerID)
	r.mu.Unlock()
}

// ---------------------------------------------------------------------------
// Session resumption
// ---------------------------------------------------------------------------

// suspendedSession is a dropped client's identity, held for
// protocol.DefaultResumeGrace in case it comes back.
//
// **Stable identity is one of the two genuinely new subsystems**
// agent_docs/beyond-cosmetic.md §5 names (the other, persistence, is
// deliberately not built): player_id is a bare counter that resets on relay
// restart, and before this there was no session resumption at all — the
// contract said so outright. Everything here is in memory and dies with the
// process, which is the honest boundary: this survives a network blip, not a
// relay restart.
type suspendedSession struct {
	token    string
	playerID string
	room     *Room
	// timer is the grace countdown, set only while suspended.
	timer *time.Timer
	// suspended distinguishes an identity whose connection has dropped from
	// one that is still live.
	//
	// A session is registered when its token is ISSUED, not when the client
	// drops, and that is the fix for the case that matters. Registering only
	// on disconnect means a resume works solely when the relay noticed the
	// drop FIRST — and on quic it routinely does not, because a hard-killed
	// peer sends no close frame and the connection sits there until quic's own
	// idle timeout (measured 2026-08-17: ~17s, against an immediate RST on
	// tcp). A client that reconnects inside that window presented a token
	// matching nothing, got a fresh player_id, and left its old ghost standing
	// until the timeout — strictly worse than not having resumption at all,
	// and precisely the blip resumption exists for.
	suspended bool
}

// newResumeToken mints an unguessable session token. crypto/rand, not the
// player_id counter: this is the one value in the relay that must be
// unguessable rather than merely unique, because anyone holding it can take
// over the session it names — including its outstanding escrows.
func newResumeToken() (string, error) {
	b := make([]byte, protocol.ResumeTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// resumeGrace resolves how long a dropped identity is held.
func (s *Server) resumeGrace() time.Duration {
	if s.ResumeGrace > 0 {
		return s.ResumeGrace
	}
	return protocol.DefaultResumeGrace
}

// suspend parks a dropped client's identity instead of removing it from the
// room, and arms the grace timer that gives up on it.
//
// The client stays in Room.members, marked suspended: that keeps the roster
// consistent for anyone who joins during the window (they are told about a
// player who is briefly away, rather than never learning of them at all),
// while Room.forward declines to write to it. Removing it and re-adding on
// resume would have needed a Join broadcast that only some members should
// receive, which is not a thing the roster can express.
func (s *Server) suspend(r *Room, c *Client, token string) {
	r.mu.Lock()
	c.suspended = true
	c.Conn = nil
	r.mu.Unlock()

	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil {
		// The session should already be registered from when its token was
		// issued (registerSession). A missing one means the token was rotated
		// or the identity already left, so there is nothing to hold.
		s.mu.Unlock()
		return
	}
	sess.suspended = true
	// The timer is created and stored under s.mu, not after it. Every other
	// access to sess.timer -- forgetSessionsOf's Stop, takeSession's Stop --
	// is reached from s.mu, so assigning it outside was a genuine unguarded
	// write: a client reconnecting with its token in the same instant the
	// relay notices the old socket died is the routine quic takeover case,
	// not a rare one. resumeGrace takes no lock, so this is safe to hold.
	sess.timer = time.AfterFunc(s.resumeGrace(), func() { s.expireSuspended(token) })
	s.mu.Unlock()
	log.Printf("relay: %s dropped from room %q — holding its identity for %s in case it reconnects",
		c.PlayerID, r.Name, s.resumeGrace())
}

// registerSession records a live identity under the token just issued to it,
// replacing any previous token for the same identity (tokens are single-use
// and rotate on every Welcome).
func (s *Server) registerSession(r *Room, playerID, token, replacing string) {
	if token == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.suspended == nil {
		s.suspended = make(map[string]*suspendedSession)
	}
	if replacing != "" {
		delete(s.suspended, replacing)
	}
	s.suspended[token] = &suspendedSession{token: token, playerID: playerID, room: r}
}

// forgetSessionsOf drops every token belonging to playerID, called when that
// identity really leaves. Without it a long-lived relay accumulates one dead
// entry per departed player, and — worse — a stale token could later resume an
// identity that no longer exists.
func (s *Server) forgetSessionsOf(r *Room, playerID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for token, sess := range s.suspended {
		if sess.room == r && sess.playerID == playerID {
			if sess.timer != nil {
				sess.timer.Stop()
			}
			delete(s.suspended, token)
		}
	}
}

// takeSession removes and returns the session for token, if it is for the room
// the client is asking to rejoin. A token for another room is refused here and
// the caller falls back to a fresh join — reinstating an identity into a room
// it never belonged to would hand its player_id to strangers.
//
// **A session that is still LIVE is returned too, not just a suspended one.**
// That is a takeover, and it is the case that makes resumption work in
// practice rather than only in tests: a client whose connection died without
// the relay noticing (routine on quic, where nothing is sent on a hard kill
// and the connection lingers until the idle timeout) reconnects while the
// relay still believes the old one is fine. Refusing there — the original
// behaviour — handed it a fresh player_id and left its old ghost standing.
// Since only the holder of the token can do this, and the token is
// unguessable, a takeover is always the legitimate owner returning.
//
// Single-use: the token is consumed whether or not the caller goes on to
// succeed, and a fresh one is issued in the new Welcome.
func (s *Server) takeSession(token, roomName, gameID string) *suspendedSession {
	if token == "" {
		return nil
	}
	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil || sess.room.Name != roomName || sess.room.GameID != gameID {
		s.mu.Unlock()
		return nil
	}
	delete(s.suspended, token)
	s.mu.Unlock()
	if sess.timer != nil {
		sess.timer.Stop()
	}
	return sess
}

// expireSuspended is the grace window running out: the client is not coming
// back, so this becomes an ordinary leave — the room is told, leases are
// freed, in-flight escrows abort, and the server slot is returned.
func (s *Server) expireSuspended(token string) {
	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil {
		s.mu.Unlock()
		return
	}
	delete(s.suspended, token)
	s.mu.Unlock()

	log.Printf("relay: %s did not reconnect within %s — treating it as a real leave", sess.playerID, s.resumeGrace())
	s.finishLeave(sess.room, sess.playerID)
}

// finishLeave is everything that happens when a player really goes: leases
// freed, live escrows aborted, snapshot forgotten, membership removed, the
// room told, and the server-wide slot released. Shared by the immediate path
// (a client with no resumption) and the grace-expiry path above, so the two
// cannot drift.
func (s *Server) finishLeave(r *Room, playerID string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	to := r.memberIDsLocked()
	outs := r.releaseLeasesOfLocked(playerID, to)
	outs = append(outs, r.abortEscrowsOfLocked(playerID)...)
	r.mu.Unlock()
	r.deliver(outs)

	r.forgetState(playerID)
	r.remove(playerID)
	s.forgetSessionsOf(r, playerID)
	s.releaseSlot()

	leave, err := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: playerID})
	if err == nil {
		r.Forward(leave, r.roster())
	}

	// The join line's own comment calls join and leave a pair of lifecycle
	// events -- but only the join was ever printed, so a live session log
	// showed (2026-08-19) seventeen joins and not one departure, and a host
	// reading it could not tell who was still in a room or whether anything
	// was leaking. One line per occurrence, and it belongs HERE rather than at
	// a call site because finishLeave is the single choke point every real
	// departure passes through -- which is the reason this function exists.
	// The two call sites that already print WHY (the resume grace expired, a
	// token could not be minted) still do; this says it actually completed.
	log.Printf("relay: %s left room %q (%d still there)", playerID, r.Name, r.size())

	s.dropIfEmpty(r)
}

// resumeInto reinstates a suspended identity onto a fresh connection. It
// returns the client's new room entry and its next single-use resume token,
// or ok=false if the identity could not be reinstated — in which case the
// caller falls back to an ordinary join, and this has already finished the
// old identity off so its slot and leases are not orphaned.
//
// Nothing is broadcast: the room was never told this player left, so it must
// not now be told it arrived. That is the entire user-visible point — a
// network blip stops costing everyone else a despawn and respawn.
//
// A NEW Client replaces the old map entry rather than the old one being
// mutated in place. That keeps Client's write-once fields (maxReceiveHz,
// transport) genuinely write-once, so a resumed client may arrive on a
// different transport or with a different receive cap without introducing a
// race against allowStateFrom, which reads those fields outside r.mu.
func (s *Server) resumeInto(nd transport.Transport, transportName string, r *Room, sess *suspendedSession, hello protocol.Hello, sendHz int) (*Client, string, bool) {
	newToken, err := newResumeToken()
	if err != nil {
		log.Printf("relay: could not mint a resume token for %s: %v — completing its leave instead", sess.playerID, err)
		s.finishLeave(r, sess.playerID)
		return nil, "", false
	}

	resumed := &Client{
		PlayerID:     sess.playerID,
		Conn:         nd,
		maxReceiveHz: protocol.ClampReceiveHz(hello.MaxReceiveHz),
		transport:    transportName,
		features:     protocol.NormalizeFeatures(hello.Features),
		// Same window as a fresh join: this Client is published into
		// r.members below and only then sent its Welcome, so without the
		// hold a broadcast in between reaches the socket first. See
		// Client.holdUntilWelcome.
		holdUntilWelcome: true,
	}

	r.mu.Lock()
	prev, ok := r.members[sess.playerID]
	if !ok {
		// The grace window expired between takeSession and here, so the
		// identity is already gone. Joining fresh is correct.
		r.mu.Unlock()
		return nil, "", false
	}
	previousConn := prev.Conn
	r.members[sess.playerID] = resumed
	roster := make([]string, 0, len(r.members))
	for id := range r.members {
		if id != sess.playerID {
			roster = append(roster, id)
		}
	}
	r.mu.Unlock()

	sendEnvelope(nd, protocol.TypeWelcome, protocol.Welcome{
		PlayerID:       sess.playerID,
		Roster:         roster,
		SendHz:         sendHz,
		GhostCollision: s.resolveGhostCollision(),
		Features:       effectiveFeatures(r, resumed),
		ResumeToken:    newToken,
		Resumed:        true,
		ServerTimeMs:   time.Now().UnixMilli(),
	})

	// Welcome is on the wire; release the hold and deliver anything the room
	// produced while this resumption was being wired up.
	r.markWelcomedAndFlush(sess.playerID)

	// Close the connection being taken over, if it was still open. Its
	// OnDisconnect then finds r.members[id] is no longer its own Client and
	// does nothing — the stale-callback guard that already existed for the
	// suspended case covers the live one identically. Closing AFTER the swap
	// is what makes that true, so the order here is load-bearing.
	if previousConn != nil {
		_ = previousConn.Close()
	}

	// Sent after Welcome for the same reason a fresh join's seed is: the
	// client rebuilds its roster from Welcome and drops state for any id it
	// has not been told about.
	r.resumeSnapshot(sess.playerID)

	s.registerSession(r, sess.playerID, newToken, sess.token)

	took := "resumed its session"
	if !sess.suspended {
		// Worth distinguishing in the log: a takeover means the relay never
		// saw the old connection die, which on quic is the normal case and on
		// tcp usually means something odder. Someone reading this log to
		// explain a duplicate ghost needs to know which happened.
		took = "took over its still-open session (the relay had not yet noticed the old connection was gone)"
	}
	log.Printf("relay: %s reconnected to room %q and %s over %s", sess.playerID, r.Name, took, transportName)
	return resumed, newToken, true
}

// resumeSnapshot is everything a reinstated client needs to rebuild the view
// it lost when its connection dropped: every other member's last known state,
// every held lease, and every exchange it is a party to.
func (r *Room) resumeSnapshot(to string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	outs := r.stateSnapshotLocked(to)
	outs = append(outs, r.leaseSnapshotLocked(to)...)
	outs = append(outs, r.escrowSnapshotLocked(to)...)
	// A resuming client that is NOT the host has missed every lossy world write
	// sent while it was away, and nothing else will ever resend them — a lossy
	// write is superseded by the next one, not retried.
	outs = append(outs, r.worldSnapshotAllLocked(to)...)
	r.mu.Unlock()
	r.deliver(outs)
}

// joinSnapshot is what a newly-joined client is seeded with: every other
// member's last known state, and the room's whole world.
//
// **It takes sendMu, which the seed it replaced did not.** The old inline block
// in handleConn locked mu, built the state snapshot, unlocked and delivered,
// with no serialization against a concurrent broadcast. State got away with
// that because a stale seed self-corrects within 50ms — the next sample from
// that player overwrites it. A WORLD seed does not: delivered after a
// concurrently-broadcast newer write, it leaves the joiner permanently stale
// with nothing to correct it. Factored into the same shape as resumeSnapshot,
// which already took sendMu for the same reason.
//
// The converse ordering is already safe: a broadcast that wins the race
// finishes first, so a snapshot built afterwards is newer by construction.
func (r *Room) joinSnapshot(to string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	outs := r.stateSnapshotLocked(to)
	outs = append(outs, r.worldSnapshotAllLocked(to)...)
	r.mu.Unlock()
	r.deliver(outs)
}
