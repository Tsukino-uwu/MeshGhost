package core

// The send path: local state out to the relay, and keeping the link alive.
//
// Split out of core.go on 2026-08-25. The rate rule lives here and is easy to get
// backwards: the effective send interval is the SLOWER of this client's own
// configured minimum and the rate the relay advertised, so a relay can never
// speed a client up past a rate it explicitly chose.

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
	// CHANGE SUPPRESSION. An identical state is not worth a packet: most of a
	// singleplayer session is spent standing still, and at 20-100Hz that is
	// hundreds of byte-identical messages a minute, uploaded, fanned out to
	// every peer in the room, and rendered as no movement at all. Requested
	// 2026-08-21 and again 2026-08-28 (agent_docs/ideas.md, "third rung");
	// this is the whole-state half of it, which needs no protocol change --
	// the per-field version makes wire fields optional and is a protocol rev.
	//
	// GAME-AGNOSTIC by construction: "is this value the same as last time" needs
	// no knowledge of what the value means, which is why it belongs here rather
	// than in four adapters.
	//
	// The keepalive is not optional. Silence and absence must stay
	// distinguishable -- for the relay, for a late joiner who has never seen a
	// state from this player, and on udp, where a suppressed packet's loss would
	// otherwise persist until the player next moves.
	unchanged := c.IdleKeepalive > 0 && sameSentState(c.lastSentState, state)
	if unchanged && time.Since(c.lastSendAt) < c.IdleKeepalive {
		// lastSendAt deliberately NOT updated: this frame did not send, and the
		// next CHANGED frame must be free to go out as soon as the ordinary
		// rate limit allows rather than being pushed back by a skip.
		c.suppressedSinceSend = true
		c.mu.Unlock()
		atomic.AddUint64(&c.stats.statesSuppressed, 1)
		return
	}

	// THE BRACKET SAMPLE, and it is what makes suppression invisible rather
	// than merely cheap. A receiver interpolates between the two samples that
	// bracket its render time (core/interp.go), so resuming after a silence
	// would blend the stale standing position into the first moving one across
	// the whole gap -- a ghost creeping at a fraction of walking speed, which
	// adapters/CLAUDE.md forbids outright ("never move a ghost slower than the
	// game moves"). Re-stating the unchanged state one millisecond before the
	// changed one collapses that gap: the peer holds still until the instant it
	// genuinely moved, then moves at its own true rate.
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

	c.lastSendAt = time.Now()
	playerID := c.playerID
	carryPrev := c.redundancyOnLocked(interval)
	c.mu.Unlock()

	// From here to the end: one adapter frame's packets go out together and
	// in order, and each records itself as the next one's predecessor. The
	// loss cover (ADR 0045) is only correct if "previous" means the packet
	// sent immediately before, so this section is serialized on its own
	// mutex rather than c.mu, which nowMs needs.
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
	// Stamped in the RELAY's clock domain when this room negotiated clock
	// sync, and in the local one otherwise (which is every room today, and
	// every room against an older relay). See nowMs and clockSync in
	// online.go: a receiver compares this against its own wall clock, so what
	// matters is that every member of a room measures against the same one,
	// not that any of them is right about the real time.
	st.Timestamp = c.nowMs()
	c.attachPrev(&st, carryPrev)
	c.sendState(relay, st)
}

// redundancyOnLocked says whether a state sent at this interval carries the
// sample before it. Caller holds c.mu (the interval came from under it).
func (c *Core) redundancyOnLocked(interval time.Duration) bool {
	gate := c.RedundancyMinInterval
	if gate == 0 {
		gate = DefaultRedundancyMinInterval
	}
	return gate > 0 && interval >= gate
}

// attachPrev makes st carry the last state sent (as a delta) when the cover is
// on, and records st as the next state's predecessor either way. Caller holds
// c.sendMu. The recorded copy never carries a prev of its own, so a delta is
// always against a plain sample.
func (c *Core) attachPrev(st *protocol.State, carry bool) {
	if carry && c.lastSentWire != nil {
		st.Prev = protocol.BuildPrev(c.lastSentWire, st)
		atomic.AddUint64(&c.stats.prevCarried, 1)
	}
	kept := *st
	kept.Prev = nil
	c.lastSentWire = &kept
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
	// One pass, not two. This used to marshal the State and then marshal an
	// Envelope around the bytes that produced, re-parsing and re-copying every
	// one of them -- the same shape the relay had, and the same fix
	// (protocol.AppendEnvelope, whose comment carries the precondition and the
	// fuzz target behind it).
	//
	// It matters more here than on the relay despite the smaller share: a core
	// runs on the same machine as the game it is serving, at up to 100Hz, so
	// its cost lands on the frame budget that agent_docs/plans.md says may
	// never be spent to buy bandwidth.
	env := protocol.AppendEnvelope(nil, protocol.TypeState, payload)
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

// sameSentState answers the one question change suppression turns on: would
// this state render exactly as the last one sent? Seq and Timestamp are
// excluded because they differ on every frame by design and mean nothing on
// screen; PlayerID because it is stamped after this comparison.
//
// Every other field is compared WITHOUT interpretation -- Orientation is raw
// JSON, Extras is a free-form map, and both are opaque to the core
// (contract.md). reflect.DeepEqual is the honest tool for that: it compares
// what is there without the core having to know what any of it means, and a
// state is a handful of small fields at at most 100Hz.
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
	// Extras keeps reflect.DeepEqual. Hand-comparing a map[string]any means
	// re-implementing reflection, badly, on the one field whose contents are
	// free-form by contract -- and the cheap fields above already short-circuit
	// almost every changed frame before reaching it.
	return reflect.DeepEqual(prev.Extras, cur.Extras)
}

// samePosition is reflect.DeepEqual for a []float64, without the reflection.
// This runs once per adapter frame -- up to 100Hz on the dev rig, on the
// machine running the game -- which is the whole reason it is worth spelling
// out by hand.
//
// The nil-versus-empty case is not pedantry and must not be "simplified" away:
// DeepEqual reports a nil slice and an empty one as DIFFERENT, and both really
// occur (protocol.IsValidPosition accepts either, and a state with no position
// decodes to nil while "position":[] decodes to empty). A plain length check
// followed by a loop would call them equal and quietly change which frames get
// suppressed.
//
// The aliasing shortcut is likewise not an optimisation but a correctness
// requirement, and TestSamePositionMatchesDeepEqual is what found that out.
// DeepEqual documents that two slices sharing a backing array and a length are
// deeply equal WITHOUT comparing elements, so it reports a []float64{NaN} as
// equal to itself while an element-wise loop reports the opposite. That case is
// live rather than theoretical: forwardLocalState keeps `kept := *state`, a
// struct copy that shares the adapter's own Position array, so prev and cur
// really can be the same memory on the next frame.
//
// Element comparison is then plain ==, exactly as DeepEqual does it: two
// DISTINCT slices both holding NaN are not equal, so such a state is not
// suppressed. That errs toward sending, which is the safe direction, and it is
// bit-for-bit what this path did before -- the bar for a change meant to be
// invisible.
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
