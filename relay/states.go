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
	"log"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ---------------------------------------------------------------------------
// The state plane's inbound path
// ---------------------------------------------------------------------------

// forwardState is everything the relay does with one inbound state: decode it,
// enforce the shared limits, stamp the sender's real id over whatever the
// payload claimed, remember it for late joiners, and fan it out. It returns the
// validated, stamped state so the dev loopback echo can reuse it, and ok=false
// for anything dropped.
//
// Extracted from handleConn's OnReceive on 2026-08-28, mechanically and with no
// behaviour change, so that relay/forward_bench_test.go measures THE path
// rather than a copy of it kept in step by hand. A benchmark that replicates
// the sequence it claims to measure stops being evidence the moment either side
// drifts, and this is the hottest path in the process.
func (r *Room) forwardState(senderID string, payload []byte) (protocol.State, bool) {
	var st protocol.State
	if err := json.Unmarshal(payload, &st); err != nil {
		return protocol.State{}, false
	}
	// Size/length/finiteness limits (agent_docs/contract.md) — drop
	// rather than truncate, so a client sees silence instead of a
	// half-forwarded, confusing state. protocol.ValidateState is
	// shared with core so both enforcement points can't
	// silently drift apart.
	if !protocol.ValidateState(st) {
		logStateDropThrottled("relay", senderID, st)
		return protocol.State{}, false
	}
	// player_id is stamped server-side from the connection's own
	// assigned id, never trusted from the payload — a peer could
	// otherwise claim someone else's id. Cheap now; Phase 4 puts
	// untrusted peers on the wire.
	st.PlayerID = senderID
	statePayload, err := json.Marshal(st)
	if err != nil {
		return protocol.State{}, false
	}
	// Built once, here, instead of marshaling the State and then marshaling an
	// Envelope around the bytes that produced -- which re-parsed, re-escaped
	// and re-copied every one of them. protocol.AppendEnvelope's own comment
	// carries the precondition that makes appending byte-identical to
	// marshaling, and the fuzz target that proves it.
	//
	// Freshly allocated per state rather than taken from a pool, deliberately:
	// forwardLine hands this exact slice to c.pending for any client still
	// waiting on its Welcome, where it outlives the call. A pool here would
	// need that copy first, and an aliasing bug on the fan-out path is not
	// worth one allocation.
	line := protocol.AppendEnvelope(nil, protocol.TypeState, statePayload)
	// A state can pass ValidateState and still marshal into a line no receiver
	// will accept. AreaID and Anim are bounded with len() (ValidOpaqueString),
	// but encoding/json escapes '&', '<' and '>' to six bytes each on the way
	// back out, and `prev` carries its own copy of both. Measured 2026-09-12:
	// an inbound line of 1185 bytes -- which this relay's own 4096-byte inbound
	// cap admits -- leaves here at 6305.
	//
	// An oversized line is not a reject: it is bufio.ErrTooLong in every OTHER
	// member's read loop, so one sender drops the whole room's ghosts with no
	// explanation anywhere. Checked BEFORE recordState so a line nobody can
	// receive is never stored and re-served to a joiner as a Join seed.
	//
	// Same ladder as core/sending.go, and measured on the bytes actually going
	// out for the same reason it measures its own there -- the bound is spent
	// on the wire. prev is pure redundancy (ADR 0045), so it goes first; the
	// whole state goes only if dropping prev was not enough. An honest client
	// already applied this bound to these same bytes before sending, so no
	// frame it would have sent is dropped here.
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
	// Remembered before forwarding, and independent of the
	// per-recipient rate gate below: a late joiner should be seeded
	// with the newest sample, not the newest one that happened to be
	// forwarded to somebody. Recorded for every room, not only ones
	// that asked for snapshots -- see recordState.
	// Remembered WITHOUT the carried previous sample (ADR 0045): a late
	// joiner is seeded with the newest sample, and the one before it is a
	// hole-filler for a receiver that was listening at the time, which a
	// joiner was not. The forwarded line above keeps it.
	recorded := st
	recorded.Prev = nil
	prevArea := r.recordState(senderID, recorded)
	r.forwardLine(line, r.stateRecipients(senderID, st.AreaID, prevArea, len(statePayload), time.Now()), true)
	if prevArea != "" && prevArea != st.AreaID {
		r.seedArrivalInto(senderID, st.AreaID)
	}
	return st, true
}

// seedArrivalInto hands a player who has just entered an area the newest state
// the relay holds for everyone already standing in it.
//
// It is the other half of the filter, and it is REQUIRED rather than a
// nicety -- because of change suppression, not despite it. A filtered client
// receives nothing from another area, so on arriving it knows nothing about
// the peers there and must wait for each of them to speak. ADR 0039 means a
// motionless peer does not speak: it re-states only every IdleKeepalive
// (250ms by default). So without this, walking into a room where somebody is
// standing still shows an empty room first and pops them in up to a keepalive
// later -- a defect that appears at every seam and gets worse the more
// successful suppression is.
//
// Sent RELIABLY. A dropped seed on the lossy state plane would reinstate
// exactly the pop this exists to remove, and unlike an ordinary state sample
// there is no next one coming to supersede it.
//
// Only for a client that opted into filtering: anyone else was already being
// sent everything and needs no catching up.
// arrivalSeedInterval is the shortest gap between two arrival seeds for one
// client. It bounds the fan-out described on Client.lastArrivalSeed without
// costing a real transition anything:
//
// A seed exists to cover the gap until each peer in the new area speaks again,
// which is at most one protocol.DefaultIdleKeepalive (250ms). Two seeds closer
// together than that are covering the same gap with the same contents -- at the
// shipped 15Hz send rate, under three states can even have arrived from any
// peer in between. And no game this repo adapts moves a player through two
// areas inside a fifth of a second: TEVI and Pseudoregalia load between rooms,
// and a Pokemon warp runs an animation.
const arrivalSeedInterval = 200 * time.Millisecond

func (r *Room) seedArrivalInto(arrival, area string) {
	r.mu.Lock()
	c, ok := r.members[arrival]
	if !ok || !c.ownAreaOnly || c.suspended {
		r.mu.Unlock()
		return
	}
	// Checked under r.mu, before the O(N) walk below rather than after it --
	// the walk and the marshals it feeds are the cost being bounded.
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

	// Built and delivered after unlocking, the same snapshot-then-act shape
	// every other handler in this package uses.
	for _, st := range seeds {
		// The peer's ORIGINAL timestamp, deliberately: core's remoteBuffer
		// renders behind live, so a sample from the recent past is what it
		// wants to interpolate from. Re-stamping it as "now" would place the
		// ghost ahead of the render time and hold it at the buffer's edge.
		if env, err := envelope(protocol.TypeState, st); err == nil {
			r.Forward(env, []string{arrival})
		}
	}
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
// It returns the area this player was in BEFORE this state, which the caller
// needs to recognise a seam crossing -- see stateRecipients' transition rule.
func (r *Room) recordState(playerID string, st protocol.State) (prevArea string) {
	r.mu.Lock()
	if r.lastState == nil {
		r.lastState = make(map[string]protocol.State)
	}
	r.lastState[playerID] = st
	// One lookup here replaces one per member per message in stateRecipients,
	// which is the whole point of caching it on the Client. Kept strictly in
	// step with the map above by living in its only writer.
	if c, ok := r.members[playerID]; ok {
		prevArea = c.lastArea
		c.lastArea = st.AreaID
	}
	r.mu.Unlock()
	return prevArea
}

// stateSnapshotLocked returns a Join carrying each other member's last known
// state, addressed to one client. Join.State has been reserved for exactly
// this since the contract was written and never populated until now; the
// receiving side already handled a populated one correctly.
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

// logStateDropThrottled says WHY a state was dropped, at most once per
// dropLogInterval per process -- the reason (protocol.StateRejectReason) is
// only computed inside the throttle window. Added 2026-09-01: both
// enforcement points dropped silently, and a Pseudoregalia sword throw that
// pushed extras past the cap presented as four unrelated ghost bugs before
// anything named the real cause. A steady stream of oversized states from one
// misbehaving adapter must not flood the log, hence the throttle rather than
// a per-drop line.
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

// logOversizedForwardThrottled reports a state that was valid but whose
// forwarded line no receiver could have read. Separate from
// logStateDropThrottled because StateRejectReason has nothing to say here --
// every field IS within its own bound, which is exactly the trap.
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
