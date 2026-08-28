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
	// Remembered before forwarding, and independent of the
	// per-recipient rate gate below: a late joiner should be seeded
	// with the newest sample, not the newest one that happened to be
	// forwarded to somebody. Recorded for every room, not only ones
	// that asked for snapshots -- see recordState.
	r.recordState(senderID, st)
	r.forwardLine(line, r.stateRecipients(senderID, st.AreaID, len(statePayload), time.Now()), true)
	return st, true
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
