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
	"log"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
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
