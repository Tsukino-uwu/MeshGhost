package relay

// The room sequencer and the event plane, plus the outgoing/deliver helpers every plane file shares.
//
// Nothing here understands a game: a lease key, escrow id, event payload or feature name is opaque, compared for
// equality and never parsed. The relay arbitrates by arrival, never by merit, since judging is simulation authority.
//
// Locking, followed by every plane file: r.mu guards members, leases, escrows, lastState and seqCounter, and every
// handler builds its outgoing messages under it and delivers after unlocking, since a Send can block for a whole
// WriteTimeout. r.sendMu is held across both stamp and deliver by every entry point, timers included, or two handlers
// stamped 1 and 2 race to the socket out of order. Lock order is always sendMu then mu.

import (
	"log"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// outgoing is one message and its recipients, computed under r.mu and sent after unlocking.
type outgoing struct {
	env protocol.Envelope
	to  []string
	// unreliable asks deliver for the lossy variant; only a lossy world write sets it.
	unreliable bool
}

// deliver sends each outgoing, reliably unless it asked otherwise: a decision, unlike a position sample, is never
// superseded by the next. The flag selects the delivery variant only; every outgoing is still stamped and delivered
// under sendMu, so a lossy one may be lost but never reordered.
func (r *Room) deliver(outs []outgoing) {
	for _, o := range outs {
		if o.unreliable {
			r.ForwardUnreliable(o.env, o.to)
			continue
		}
		r.Forward(o.env, o.to)
	}
}

// out builds an outgoing, or returns ok=false if the payload could not be marshaled, which for this package's
// plain-data payloads is a bug worth logging, not a condition to handle.
func out(t protocol.MessageType, payload any, to []string) (outgoing, bool) {
	env, err := envelope(t, payload)
	if err != nil {
		log.Printf("relay: BUG: %s payload failed to marshal: %v", t, err)
		return outgoing{}, false
	}
	return outgoing{env: env, to: to}, true
}

// hasFeature reports whether this room's agreed feature set contains name. The set is fixed by the first member and
// a joiner that disagrees is refused at the handshake, so this needs no lock.
func (r *Room) hasFeature(name string) bool {
	return protocol.HasFeature(r.features, name)
}

// wants reports whether this client asked for a client-scoped capability; room-scoped ones are Room.hasFeature's.
func (c *Client) wants(name string) bool {
	return protocol.HasFeature(c.features, name)
}

// effectiveFeatures is what is in force for one client, echoed in its Welcome: the room's room-scoped set plus the
// client-scoped capabilities this client asked for.
func effectiveFeatures(r *Room, c *Client) []string {
	out := append([]string(nil), r.features...)
	for _, f := range c.features {
		if !protocol.IsRoomScopedFeature(f) {
			out = append(out, f)
		}
	}
	return protocol.NormalizeFeatures(out)
}

// nextSeq returns this room's next sequencer stamp. Caller holds r.mu: the stamp is assigned in the same critical
// section that snapshots the recipients, so the assigned order is the order every member observes. It starts at 1,
// so a zero Seq means unstamped.
func (r *Room) nextSeq() uint64 {
	r.seqCounter++
	return r.seqCounter
}

// memberIDsLocked returns every current member's id, suspended ones included: Room.forward is what declines to write
// to them. Caller holds r.mu.
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

// handleEvent stamps and routes one client event, overwriting From with the sender's relay-assigned id. The sender
// always gets its own event back: the stamp is the relay's, so the echo is how it learns where its event landed in
// the total order. An event addressed to a player not in the room reaches only that echo, with no error: the relay
// cannot tell a typo from a player who just left.
func (r *Room) handleEvent(from string, ev protocol.Event) {
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
	// A suspended recipient gets the event held for its resume instead of dropped.
	for _, id := range to {
		if c, ok := r.members[id]; ok && c.suspended {
			r.queueMissedEventLocked(id, ev)
		}
	}
	r.mu.Unlock()

	if o, ok := out(protocol.TypeEvent, ev, to); ok {
		r.deliver([]outgoing{o})
	}
}

// maxMissedEventsPerMember bounds one suspended member's event backlog to a quarter of maxSnapshotLines, so a full
// backlog cannot push the escrow, world and lease lines off the resume snapshot. The grace window can carry more, so
// this is a ceiling on the guarantee; overflow is logged once per room.
const maxMissedEventsPerMember = 64

// queueMissedEventLocked holds one stamped event for a suspended member, to be replayed by resumeSnapshot. Caller
// holds r.mu and sendMu, so the backlog is in the sequencer's order; Room.remove drops it with a member that left.
func (r *Room) queueMissedEventLocked(id string, ev protocol.Event) {
	if r.missedEvents == nil {
		r.missedEvents = make(map[string][]protocol.Event)
	}
	q := r.missedEvents[id]
	if len(q) >= maxMissedEventsPerMember {
		// A broadcast goes first, or anyone's broadcasts could push out the events addressed to this member; within
		// a class, oldest first, since the newer half of a conversation is the half a returning client answers.
		drop := 0
		for i, held := range q {
			if held.To == "" {
				drop = i
				break
			}
		}
		q = append(q[:drop], q[drop+1:]...)
		r.missedEventsDroppedOnce.Do(func() {
			log.Printf("relay: room %q: %s missed more than %d events while it was away "+
				"-- the oldest are being dropped, so its replay on resume will be incomplete",
				r.Name, id, maxMissedEventsPerMember)
		})
	}
	r.missedEvents[id] = append(q, ev)
}

// missedEventsLocked takes and clears the backlog held for a returning member, as outgoings addressed to it alone.
// The events keep their original Seq: re-stamping would place a peer's action after things that happened later.
// Caller holds r.mu.
func (r *Room) missedEventsLocked(to string) []outgoing {
	q := r.missedEvents[to]
	if len(q) == 0 {
		return nil
	}
	delete(r.missedEvents, to)
	outs := make([]outgoing, 0, len(q))
	for _, ev := range q {
		if o, ok := out(protocol.TypeEvent, ev, []string{to}); ok {
			outs = append(outs, o)
		}
	}
	return outs
}
