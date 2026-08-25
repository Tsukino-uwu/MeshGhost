package core

// The send path: local state out to the relay, and keeping the link alive.
//
// Split out of core.go on 2026-08-25. The rate rule lives here and is easy to get
// backwards: the effective send interval is the SLOWER of this client's own
// configured minimum and the rate the relay advertised, so a relay can never
// speed a client up past a rate it explicitly chose.

import (
	"encoding/json"
	"log"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// effectiveSendInterval returns the slower of (the relay's advertised
// interval, this Core's own configured floor), falling back to
// DefaultMinSendInterval when neither exists. Slower, always: the relay's
// rate is prescriptive for a client that hasn't expressed a preference, but
// a client that deliberately set MinSendInterval did so because of its own
// connection, and the relay has no business overriding that upward. Caller
// holds c.mu. See the ADR in agent_docs/architecture.md.
func (c *Core) effectiveSendInterval() time.Duration {
	// The slower of the two wins, and if neither is set the built-in default
	// does. Written as a max rather than the four-arm switch this used to be:
	// both non-positive means neither was set, one set means that one, and both
	// set means the slower -- which is exactly what taking the larger does.
	d := c.MinSendInterval
	if c.serverSendInterval > d {
		d = c.serverSendInterval
	}
	if d <= 0 {
		d = DefaultMinSendInterval
	}
	return d
}

// forwardLocalState stamps and sends state to the relay, if there is one.
// state == nil means "don't send this frame" (get_local_state()'s nil
// case). Actual sends are capped to effectiveSendInterval() regardless of
// how often the adapter calls in — see its own comment and
// DefaultMinSendInterval's. A dropped frame here is not stamped with
// seq/timestamp at all, so it never reaches the relay and never affects
// Core.seq's monotonic count.
func (c *Core) forwardLocalState(state *protocol.State) {
	if state == nil {
		return
	}

	c.mu.Lock()
	// Recorded on every real local frame, independent of MinSendInterval
	// throttling below and of whether a relay connection exists yet --
	// remoteStatesAt's cross-area filter needs this to always reflect the
	// adapter's actual current area, not just what was last sent over the
	// network. See the 2026-08-13 ADR in architecture.md.
	c.localAreaID = state.AreaID
	relay := c.relay
	if relay == nil {
		// No adapter has sent a Hello yet (or -game/config never set one) --
		// nothing to forward to. Not an error: this is the normal state
		// while ConnectRelayOnAdapterHello is waiting for one.
		c.mu.Unlock()
		return
	}
	interval := c.effectiveSendInterval()
	elapsed := time.Since(c.lastSendAt)
	if c.lastSendAt.IsZero() {
		elapsed = interval // always allow the first send
	}
	if elapsed < interval {
		c.mu.Unlock()
		return
	}
	c.lastSendAt = time.Now()
	playerID := c.playerID
	c.mu.Unlock()

	st := *state
	st.PlayerID = playerID
	st.Seq = atomic.AddUint64(&c.seq, 1)
	// Stamped in the RELAY's clock domain when this room negotiated clock
	// sync, and in the local one otherwise (which is every room today, and
	// every room against an older relay). See nowMs and clockSync in
	// online.go: a receiver compares this against its own wall clock, so what
	// matters is that every member of a room measures against the same one,
	// not that any of them is right about the real time.
	st.Timestamp = c.nowMs()
	c.sendState(relay, st)
}

// sendHeartbeats sends a Ping on conn every Core.HeartbeatInterval
// (DefaultHeartbeatInterval unless overridden; a value <= 0 disables
// heartbeats entirely and this returns immediately) for as
// long as conn remains this Core's current relay connection, so a relay
// connection with no real traffic (no adapter attached, or one reporting
// get_local_state()==nil for a stretch) doesn't get killed by the relay's
// idle timeout. See DefaultHeartbeatInterval's doc comment for the live
// incident this fixes. Exits silently once conn is replaced or closed —
// ConnectRelay's own OnDisconnect handler already logs and handles
// reconnection; this has nothing more to add on a Send failure.
func (c *Core) sendHeartbeats(conn transport.Transport) {
	interval := c.HeartbeatInterval
	if interval <= 0 {
		return
	}
	var nonce uint64
	// One ping is a heartbeat; a short burst of them is a clock measurement.
	// The burst comes first because the heartbeat interval is 20s, and an
	// offset estimate that takes a minute to form is useless for exactly the
	// minute a player is first walking into everyone else's view. Three
	// probes cost three messages and give the "keep the lowest RTT"
	// estimator something to choose between, which a single sample cannot.
	//
	// Spaced at the SHORTER of the probe interval and this Core's heartbeat
	// interval. A Core configured to heartbeat faster than the burst clearly
	// wants pings sooner, and spacing the burst wider than the heartbeat
	// would delay the very keepalive it is being sent alongside — which is
	// not hypothetical, it broke two existing heartbeat tests the moment the
	// burst was added with a fixed interval.
	probeGap := initialClockProbeInterval
	if interval < probeGap {
		probeGap = interval
	}
	for i := 0; i < initialClockProbeCount; i++ {
		if !c.sendPing(conn, &nonce) {
			return
		}
		time.Sleep(probeGap)
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		if !c.sendPing(conn, &nonce) {
			return
		}
	}
}

// sendPing sends one Ping on conn and records when it went out, so the
// matching Pong can be turned into a round-trip time and a clock offset.
// Returns false once conn is no longer this Core's relay connection, or the
// send fails — in both cases sendHeartbeats should stop.
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
	// Recorded before the send, not after: a send that blocks briefly is part
	// of the round trip a client actually experiences, and stamping
	// afterwards would quietly subtract it and bias every estimate low.
	c.recordPingSent(*nonce, time.Now())
	return conn.Send(env) == nil
}

func (c *Core) sendState(relay transport.Transport, st protocol.State) {
	payload, err := json.Marshal(st)
	if err != nil {
		log.Printf("core: BUG: state failed to marshal: %v", err)
		return
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		log.Printf("core: BUG: state envelope failed to marshal: %v", err)
		return
	}
	// SendUnreliable, not Send: this is the state plane, which
	// agent_docs/contract.md defines as lossy and latest-wins. On tcp
	// there is no difference at all. On a datagram transport it means a
	// lost sample is superseded by the next one ~50ms later instead of
	// being retransmitted — and a retransmitted position would arrive
	// stale and out of order, which is worse than the gap it fills. Every
	// other message this Core sends stays on Send. See the transport ADR
	// in agent_docs/architecture.md.
	if err := relay.SendUnreliable(env); err != nil {
		log.Printf("core: send state to relay failed: %v", err)
		return
	}
	atomic.AddUint64(&c.stats.statesSent, 1)
	atomic.AddUint64(&c.stats.bytesSent, uint64(len(env)))
}
