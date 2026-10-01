package relay

// The locking discipline in online.go's header governs this file.

import (
	"encoding/json"
	"log"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/throttle"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ---------------------------------------------------------------------------
// The state plane's inbound path
// ---------------------------------------------------------------------------

// forwardState is everything the relay does with one inbound state: decode, validate, stamp the sender's real id,
// remember it for late joiners, and fan it out. It returns the stamped state for the dev loopback echo, and ok=false
// for anything dropped. Its own function so forward_bench_test.go measures this path, not a copy of it.
func (r *Room) forwardState(senderID string, payload []byte) (protocol.State, bool) {
	var st protocol.State
	if err := json.Unmarshal(payload, &st); err != nil {
		return protocol.State{}, false
	}
	// Dropped rather than truncated, so a client sees silence instead of a half-forwarded state; ValidateState is
	// shared with core so the two enforcement points cannot drift.
	if !protocol.ValidateState(st) {
		logStateDropThrottled("relay", senderID, st)
		return protocol.State{}, false
	}
	// Never trusted from the payload, or a peer could claim someone else's id.
	st.PlayerID = senderID
	statePayload, err := json.Marshal(st)
	if err != nil {
		return protocol.State{}, false
	}
	// Freshly allocated rather than pooled: forwardLine hands this slice to c.pending, where it outlives the call.
	line := protocol.AppendEnvelope(nil, protocol.TypeState, statePayload)
	// A valid state can re-encode past the cap (json escapes '&', '<' and '>' to six bytes, prev repeats them), which
	// is ErrTooLong in every receiver. Checked before recordState; prev, pure redundancy, goes first (core/sending.go).
	if len(line) > protocol.MaxPayloadBytes {
		if st.Prev != nil {
			st.Prev = nil
			if p, err := json.Marshal(st); err == nil {
				statePayload = p
				line = protocol.AppendEnvelope(nil, protocol.TypeState, statePayload)
			}
		}
		if len(line) > protocol.MaxPayloadBytes {
			logOversizedForwardThrottled(senderID, len(line))
			return protocol.State{}, false
		}
	}
	// Recorded before forwarding and regardless of the rate gate, so a joiner gets the newest sample; without prev,
	// which only fills holes for a receiver that was listening at the time.
	recorded := st
	recorded.Prev = nil
	prevArea := r.recordState(senderID, recorded)
	r.forwardLine(line, r.stateRecipients(senderID, st.AreaID, prevArea, len(statePayload), time.Now()), true)
	if prevArea != "" && prevArea != st.AreaID {
		r.seedArrivalInto(senderID, st.AreaID)
	}
	return st, true
}

// arrivalSeedInterval is the shortest gap between two arrival seeds for one client, bounding their fan-out at no cost
// to a real transition: a seed covers at most one core.DefaultIdleKeepalive, and no adapted game crosses areas faster.
const arrivalSeedInterval = 200 * time.Millisecond

// seedOversizedLine throttles the oversized-seed line process-wide; a Room has no handle on its Server.
var seedOversizedLine throttle.Line

// seedArrivalInto hands a player who just entered an area the newest state held for everyone already in it, if it
// opted into area filtering. Change suppression makes a motionless peer silent until its keepalive, so without this
// an arriving client sees an empty area and the peers pop in later. Sent reliably: no next sample supersedes a seed.
func (r *Room) seedArrivalInto(arrival, area string) {
	r.mu.Lock()
	c, ok := r.members[arrival]
	if !ok || !c.ownAreaOnly || c.suspended {
		r.mu.Unlock()
		return
	}
	// Checked before the O(N) walk below, which is the cost being bounded.
	now := time.Now() // wall-clock: a rate limit on a real client's real message rate
	if !c.lastArrivalSeed.IsZero() && now.Sub(c.lastArrivalSeed) < arrivalSeedInterval {
		r.mu.Unlock()
		return
	}
	c.lastArrivalSeed = now
	var seeds []protocol.State
	for id, m := range r.members {
		if id == arrival || m.suspended || m.lastArea != area {
			continue
		}
		if st, ok := r.lastState[id]; ok {
			seeds = append(seeds, st)
		}
	}
	r.mu.Unlock()

	for _, st := range seeds {
		// The peer's original timestamp: core renders behind live, and re-stamping it now would hold the ghost at
		// the buffer's edge.
		if env, err := envelope(protocol.TypeState, st); err == nil {
			r.Forward(env, []string{arrival})
		}
	}
}

// ---------------------------------------------------------------------------
// Late-join snapshot
// ---------------------------------------------------------------------------

// recordState remembers a player's most recent valid state for late joiners, in every room: storage is one State per
// member, and whether to send a seed is the recipient's question. It returns the area the player was in before this
// state, so the caller can recognise a seam crossing.
func (r *Room) recordState(playerID string, st protocol.State) (prevArea string) {
	r.mu.Lock()
	if r.lastState == nil {
		r.lastState = make(map[string]protocol.State)
	}
	r.lastState[playerID] = st
	// Cached on the Client so stateRecipients looks it up once per message, not once per member; kept in step by
	// living in the map's only writer.
	if c, ok := r.members[playerID]; ok {
		prevArea = c.lastArea
		c.lastArea = st.AreaID
	}
	r.mu.Unlock()
	return prevArea
}

// stateSnapshotLocked returns a Join carrying each other member's last known state, addressed to one client. Caller
// holds r.mu.
func (r *Room) stateSnapshotLocked(to string) []outgoing {
	// The recipient's capability, not the room's: a seed changes only what this one client receives.
	recipient, ok := r.members[to]
	if !ok || !recipient.wants(protocol.FeatureSnapshotV1) {
		return nil
	}
	seedBudget := protocol.MaxPayloadBytes
	if recipient.Conn != nil {
		seedBudget = sendBudget(recipient.Conn)
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
		// Measured as a join, 24 + len(id) bytes more: a stored state just under the cap would put the joiner in an
		// ErrTooLong reconnect loop, where dropping the seed costs one state of lateness. prev goes first.
		if snapshot.Prev != nil {
			snapshot.Prev = nil
		}
		o, ok := out(protocol.TypeJoin, protocol.Join{PlayerID: id, State: &snapshot}, []string{to})
		if !ok {
			continue
		}
		// Against the recipient's own budget (sendBudget), not the protocol's: a udp connection takes less.
		if n := len(protocol.AppendEnvelope(nil, o.env.Type, o.env.Payload)); n > seedBudget {
			// Throttled: a member controls how large its seed is.
			if count, ok := seedOversizedLine.Allow(); ok {
				log.Printf("relay: room %q: %s's seed for %s is %d bytes as a join, over the %d that connection can take -- "+
					"not seeding it (they appear on that peer's next state) (%d so far)", r.Name, id, to, n, seedBudget, count)
			}
			continue
		}
		outs = append(outs, o)
	}
	return outs
}

// forgetState drops a departed player's snapshot on a real leave; a suspended player keeps it, so peers' ghosts of it
// do not jump when it resumes.
func (r *Room) forgetState(playerID string) {
	r.mu.Lock()
	delete(r.lastState, playerID)
	r.mu.Unlock()
}

// logStateDropThrottled says why a state was dropped, at most once per dropLogInterval per process, so one
// misbehaving adapter cannot flood the log; the reason is only computed inside the window.
func logStateDropThrottled(who, playerID string, st protocol.State) {
	now := time.Now()
	last := lastStateDropLog.Load()
	if last != nil && now.Sub(*last) < dropLogInterval {
		return
	}
	stamp := now
	lastStateDropLog.Store(&stamp)
	log.Printf("%s: dropping state from %s: %s (repeats suppressed for %s)", who, playerID, protocol.StateRejectReason(st), dropLogInterval)
}

const dropLogInterval = 5 * time.Second

var lastStateDropLog atomic.Pointer[time.Time]

// logOversizedForwardThrottled reports a valid state whose forwarded line no receiver could read. StateRejectReason
// has nothing to say here: every field is within its own bound.
func logOversizedForwardThrottled(playerID string, size int) {
	now := time.Now()
	last := lastOversizedForwardLog.Load()
	if last != nil && now.Sub(*last) < dropLogInterval {
		return
	}
	stamp := now
	lastOversizedForwardLog.Store(&stamp)
	log.Printf("relay: NOT forwarding a %d-byte state from %s -- a receiver accepts at most %d, "+
		"and an over-long line drops its connection rather than rejecting the message. Every field "+
		"is within its own limit; something in area_id/anim/orientation/extras is near maximum and "+
		"grows when re-encoded (repeats suppressed for %s)",
		size, playerID, protocol.MaxPayloadBytes, dropLogInterval)
}

var lastOversizedForwardLog atomic.Pointer[time.Time]
