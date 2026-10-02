package core

// The send path: local state out to the relay, and keeping the link alive.

import (
	"bytes"
	"encoding/json"
	"log"
	"reflect"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// effectiveSendInterval returns the slower of the relay's advertised interval and this Core's own floor, or
// DefaultMinSendInterval when neither is set: a client that set MinSendInterval did so for its own connection, and the
// relay has no business overriding that upward. Caller holds c.mu.
func (c *Core) effectiveSendInterval() time.Duration {
	d := c.MinSendInterval
	if c.serverSendInterval > d {
		d = c.serverSendInterval
	}
	if d <= 0 {
		d = DefaultMinSendInterval
	}
	return d
}

// forwardLocalState stamps and sends state to the relay, if there is one; nil means not this frame. Sends are capped to
// effectiveSendInterval however often the adapter calls, and a frame not sent is never stamped, so it costs no seq.
func (c *Core) forwardLocalState(state *protocol.State) {
	if state == nil {
		return
	}
	// The recorder tap, before the rate limit and the relay check, so a recording is the densest copy and works
	// offline.
	c.recordLocal(state)
	// The first in-game frame starts a loaded replay, so a ghost lines up with the run rather than the main menu.
	c.launchPendingReplays()
	// Split times: a windowed nearest-sample search, cheap enough for the frame path.
	c.updateSplits(state)

	c.mu.Lock()
	// Recorded on every real frame, sent or not: the cross-area filter needs the adapter's current area, not the last
	// one sent.
	c.localAreaID = state.AreaID
	relay := c.relay
	if relay == nil {
		// No relay yet: the normal state while ConnectRelayOnAdapterHello waits for an adapter.
		c.mu.Unlock()
		return
	}
	interval := c.effectiveSendInterval()
	elapsed := c.clk().Since(c.lastSendAt)
	if c.lastSendAt.IsZero() {
		elapsed = interval // always allow the first send
	}
	if elapsed < interval {
		c.mu.Unlock()
		return
	}
	// Change suppression: an identical state is not worth a packet, and most of a session is spent standing still. The
	// keepalive keeps silence and absence distinguishable, for the relay, for a late joiner who has never seen this
	// player, and on a lossy transport, where a suppressed packet's loss would otherwise last until the player moves.
	unchanged := c.IdleKeepalive > 0 && sameSentState(c.lastSentState, state)
	if unchanged && c.clk().Since(c.lastSendAt) < c.IdleKeepalive {
		// lastSendAt stays put: the next changed frame must go out as soon as the ordinary rate limit allows.
		c.suppressedSinceSend = true
		c.mu.Unlock()
		atomic.AddUint64(&c.stats.statesSuppressed, 1)
		return
	}

	// The bracket sample makes suppression invisible: a receiver interpolates between the samples around its render
	// time, so resuming after a silence would creep across the whole gap. Re-stating the unchanged state 1ms before the
	// changed one holds the ghost still until the instant it moved.
	var bracket *protocol.State
	if !unchanged && c.suppressedSinceSend && c.lastSentState != nil {
		b := *c.lastSentState
		bracket = &b
	}
	c.suppressedSinceSend = false
	kept := *state
	kept.PlayerID = ""
	kept.Seq = 0
	kept.Timestamp = 0
	c.lastSentState = &kept

	c.lastSendAt = c.clk().Now()
	playerID := c.playerID
	carryPrev := c.redundancyOnLocked(interval)
	c.mu.Unlock()

	// One frame's packets go out together and in order, each recorded as the next one's predecessor: the loss cover is
	// correct only if previous means the packet sent just before. Serialized on sendMu, not c.mu, which nowMs needs.
	c.sendMu.Lock()
	defer c.sendMu.Unlock()

	if bracket != nil {
		bs := *bracket
		bs.PlayerID = playerID
		bs.Seq = atomic.AddUint64(&c.seq, 1)
		bs.Timestamp = c.nowMs() - 1
		c.attachPrev(&bs, carryPrev)
		c.sendState(relay, bs)
		atomic.AddUint64(&c.stats.bracketsSent, 1)
	}

	st := *state
	st.PlayerID = playerID
	st.Seq = atomic.AddUint64(&c.seq, 1)
	// On the relay's clock when the room negotiated clock sync, else the local one: a room only needs one clock to
	// agree on.
	st.Timestamp = c.nowMs()
	c.attachPrev(&st, carryPrev)
	c.sendState(relay, st)
}

// redundancyOnLocked says whether a state sent at this interval carries the sample before it. Caller holds c.mu.
func (c *Core) redundancyOnLocked(interval time.Duration) bool {
	gate := c.RedundancyMinInterval
	if gate == 0 {
		gate = DefaultRedundancyMinInterval
	}
	return gate > 0 && interval >= gate
}

// attachPrev makes st carry the last state sent, as a delta, when the cover is on, and records st as the next one's
// predecessor either way, without a prev of its own, so a delta is always against a plain sample. Caller holds
// c.sendMu.
func (c *Core) attachPrev(st *protocol.State, carry bool) {
	if carry && c.lastSentWire != nil {
		st.Prev = protocol.BuildPrev(c.lastSentWire, st)
		atomic.AddUint64(&c.stats.prevCarried, 1)
	}
	kept := *st
	kept.Prev = nil
	c.lastSentWire = &kept
}

// sendHeartbeats sends a Ping on conn every HeartbeatInterval (none when it is 0 or less) while conn is this Core's
// relay connection, so a link with no real traffic is not killed by the relay's idle timeout. It exits quietly once
// conn is replaced or closed; the disconnect handler does the rest.
func (c *Core) sendHeartbeats(conn transport.Transport) {
	interval := c.HeartbeatInterval
	if interval <= 0 {
		return
	}
	var nonce uint64
	// One ping is a heartbeat; a short burst first is a clock measurement, since at the heartbeat's pace the estimate
	// would take a minute to form. Spaced at the shorter of the probe and heartbeat intervals, or the burst would delay
	// the keepalive sent alongside it.
	probeGap := initialClockProbeInterval
	if interval < probeGap {
		probeGap = interval
	}
	for i := 0; i < initialClockProbeCount; i++ {
		if !c.sendPing(conn, &nonce) {
			return
		}
		time.Sleep(probeGap) // wall-clock: paces real pings for an RTT measurement
	}

	ticker := time.NewTicker(interval) // wall-clock: the ping cadence measures the network
	defer ticker.Stop()
	for range ticker.C {
		if !c.sendPing(conn, &nonce) {
			return
		}
	}
}

// sendPing sends one Ping on conn and records when it went out, for the matching Pong's round trip and clock offset.
// False once conn is not this Core's relay connection or the send fails.
func (c *Core) sendPing(conn transport.Transport, nonce *uint64) bool {
	c.mu.Lock()
	stillCurrent := c.relay == conn
	c.mu.Unlock()
	if !stillCurrent {
		return false
	}
	*nonce++
	payload, err := json.Marshal(protocol.Ping{Nonce: *nonce})
	if err != nil {
		return true
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypePing, Payload: payload})
	if err != nil {
		return true
	}
	// Recorded before the send: a send that blocks is part of the round trip, and stamping after would bias it low.
	c.recordPingSent(*nonce, time.Now()) // wall-clock: the other half of the RTT measurement
	return conn.Send(env) == nil
}

func (c *Core) sendState(relay transport.Transport, st protocol.State) {
	payload, err := json.Marshal(st)
	if err != nil {
		log.Printf("core: BUG: state failed to marshal: %v", err)
		return
	}
	// One pass: AppendEnvelope wraps the payload without marshalling it again, which matters on the game's own machine.
	env := protocol.AppendEnvelope(nil, protocol.TypeState, payload)
	// The line cap, checked on send: every field can be legal and the line still too long, and the relay drops the
	// whole connection on an over-long line instead of rejecting it, so the player despawns and respawns under a new
	// id. The prev goes first, being pure redundancy; the whole state only if that is not enough.
	if len(env) > protocol.MaxPayloadBytes && st.Prev != nil {
		full := len(env)
		st.Prev = nil // st is this function's own copy; attachPrev's record is unaffected
		if p, err := json.Marshal(st); err == nil {
			env = protocol.AppendEnvelope(nil, protocol.TypeState, p)
		}
		if len(env) <= protocol.MaxPayloadBytes {
			noteOversizedState(&oversizedPrevDropped, "core: state was %d bytes with its loss-cover "+
				"prev attached, over the %d-byte line limit -- sent it without the prev (%d bytes). "+
				"Redundancy is off for this frame only; nothing else changes.",
				full, protocol.MaxPayloadBytes, len(env))
		}
	}
	if len(env) > protocol.MaxPayloadBytes {
		noteOversizedState(&oversizedDropped, "core: NOT sending a %d-byte state -- the line limit is "+
			"%d bytes and the relay drops the whole connection on an over-long line rather than "+
			"rejecting the message. Something in this frame's area_id/anim/orientation/extras is "+
			"near its own maximum; shrink it in the adapter.",
			len(env), protocol.MaxPayloadBytes)
		return
	}
	// Unreliable, since the state plane is lossy and latest-wins: a retransmitted position would arrive stale. Queued,
	// not written, so a relay that stops reading cannot freeze the game through this goroutine.
	if !c.sendToRelay(relay, env, true) {
		return
	}
	atomic.AddUint64(&c.stats.statesSent, 1)
	atomic.AddUint64(&c.stats.bytesSent, uint64(len(env)))
}

// oversizedPrevDropped and oversizedDropped count each half of the send-side line-cap check and pace its logging. An
// oversized state repeats every frame while the player stays put, so noteOversizedState prints occurrences 1, 2, 4, 8
// and on: no clock needed (these are per-process, the injectable clock per-Core), and deterministic for a test.
var (
	oversizedPrevDropped atomic.Uint64
	oversizedDropped     atomic.Uint64
)

// noteOversizedState logs format at power-of-two occurrences of n.
func noteOversizedState(n *atomic.Uint64, format string, args ...any) {
	count := n.Add(1)
	if count&(count-1) != 0 { // not a power of two: this occurrence stays quiet
		return
	}
	if count == 1 {
		log.Printf(format, args...)
		return
	}
	log.Printf(format+" (occurrence %d)", append(args, count)...)
}

// sameSentState says whether this state would render exactly as the last one sent. Seq and Timestamp differ every frame
// by design, and PlayerID is stamped after this. Every other field is compared without interpretation: Orientation and
// Extras are opaque to the core.
func sameSentState(prev *protocol.State, cur *protocol.State) bool {
	if prev == nil || cur == nil {
		return false
	}
	if prev.AreaID != cur.AreaID || prev.Anim != cur.Anim {
		return false
	}
	if !samePosition(prev.Position, cur.Position) {
		return false
	}
	if !bytes.Equal(prev.Orientation, cur.Orientation) {
		return false
	}
	// Extras keeps reflect.DeepEqual: it is free-form, and the cheap fields above short-circuit almost every changed
	// frame.
	return reflect.DeepEqual(prev.Extras, cur.Extras)
}

// samePosition is reflect.DeepEqual for a []float64 without the reflection, since it runs once per adapter frame. Nil
// and empty must stay different, as DeepEqual has them: both occur, and calling them equal would change which frames
// are suppressed. The aliasing shortcut is required too: DeepEqual calls two slices sharing a backing array equal
// without comparing elements, so a NaN equals itself there, and forwardLocalState's struct copy shares the adapter's
// Position array. Distinct slices holding NaN are not equal, which errs toward sending.
func samePosition(a, b []float64) bool {
	if (a == nil) != (b == nil) {
		return false
	}
	if len(a) != len(b) {
		return false
	}
	if len(a) > 0 && &a[0] == &b[0] {
		return true
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
