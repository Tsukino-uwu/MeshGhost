package core

// The client half of the planes past cosmetic: capability negotiation, clock sync against the relay, session
// resumption, and the send and receive paths for the event, lease, escrow and world planes. Nothing here interprets a
// payload: keys and blobs pass between the relay and the adapter as opaque bytes.

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// clockSync estimates the offset between the local wall clock and the relay's. A local render time is compared
// against a remote's wall-clock stamps, so peers whose clocks disagree by more than the delay stop interpolating with
// no error anywhere; they need only agree, and the relay is what a room shares. The lowest round trip wins: a slow
// sample was delayed somewhere, and an asymmetric delay is what corrupts an offset.
type clockSync struct {
	// offsetMs is (relay clock - local clock) from the best sample; zero also means never measured, and both mean
	// apply nothing.
	offsetMs int64
	// bestRTTMs is the round trip offsetMs came from; zero means no sample yet.
	bestRTTMs int64
}

// observe folds one ping/pong round trip into the estimate, assuming a symmetric delay: the relay's reading is the
// local midpoint of the round trip.
func (cs *clockSync) observe(sentAt, recvAt time.Time, serverMs int64) {
	if serverMs == 0 {
		// A relay that does not stamp its clock: nothing to learn.
		return
	}
	rtt := recvAt.Sub(sentAt).Milliseconds()
	if rtt < 0 {
		return
	}
	if cs.bestRTTMs != 0 && rtt >= cs.bestRTTMs {
		return
	}
	midpoint := sentAt.UnixMilli() + rtt/2
	cs.bestRTTMs = rtt
	cs.offsetMs = serverMs - midpoint
}

// nowMs is the timestamp this Core stamps on outgoing state: the local clock, shifted into the relay's when the room
// agreed on FeatureClockV1 (a room where only some members shift is worse than none). Caller must not hold c.mu.
func (c *Core) nowMs() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.nowMsLocked()
}

// nowMsLocked is nowMs for a caller that already holds c.mu: Go mutexes are not reentrant, and a core deadlocked on
// c.mu stops reading, so the adapter's writes block on the game's main thread.
func (c *Core) nowMsLocked() int64 {
	// Every outgoing stamp, render time and replay or chaser due time comes from here. The offset stays
	// wall-measured on purpose: a virtual clock cannot measure the network, and it is a scalar a test can set.
	ms := c.clk().Now().UnixMilli() + c.clockAdjustLocked()
	// Never go backwards: a better sample can lower the offset. A rewound stamp unsorts every peer's buffer, and a
	// rewound render time can flip an opaque field back, an edge an adapter would act on. Hold until real time
	// catches up; a forward correction applies at once.
	if ms < c.lastNowMs {
		ms = c.lastNowMs
	}
	c.lastNowMs = ms
	return ms
}

// clockAdjustLocked returns the offset to apply, or 0 when this room did not opt into clock sync. Caller holds c.mu.
func (c *Core) clockAdjustLocked() int64 {
	if !protocol.HasFeature(c.activeFeatures, protocol.FeatureClockV1) {
		return 0
	}
	return c.clock.offsetMs
}

// effectiveFeatures is this Core's configured Features plus whatever the adapter's bridge Hello asked for. The adapter
// has a say here, unlike over the relay address or rate, because a capability is a statement about what it can do.
func (c *Core) effectiveFeatures() []string {
	c.mu.Lock()
	adapter := c.adapterFeatures
	c.mu.Unlock()
	combined := make([]string, 0, len(c.Features)+len(adapter))
	combined = append(combined, c.Features...)
	combined = append(combined, adapter...)
	return protocol.NormalizeFeatures(combined)
}

// RoomFeatures is what the relay reported this room agreed on, which every send path gates against. Set from Welcome,
// cleared on disconnect.
func (c *Core) RoomFeatures() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]string, len(c.activeFeatures))
	copy(out, c.activeFeatures)
	return out
}

// Resumed reports whether the current relay session reclaimed a previous identity rather than being issued a new one.
func (c *Core) Resumed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.resumed
}

// ErrFeatureNotEnabled is returned by the send paths when this room did not negotiate the capability: an error, not
// a silent drop, because a lease asked for in a room without leases is a configuration problem.
var ErrFeatureNotEnabled = fmt.Errorf("core: this room did not negotiate that capability")

// ErrNotConnected is returned when there is no relay connection to send on.
var ErrNotConnected = fmt.Errorf("core: not connected to a relay")

// sendControl sends one non-state message on the reliable plane: a lease grant, an escrow step or an event carries a
// decision, which no later message supersedes.
func (c *Core) sendControl(t protocol.MessageType, feature string, payload any) error {
	return c.sendControlOn(t, feature, payload, false)
}

// sendControlUnreliable is sendControl for a message superseded by the caller's own next update, named apart so
// reliability stays opt-out. It does not lose ordering: the relay delivers every world write under one lock, so a
// message can only be missing.
func (c *Core) sendControlUnreliable(t protocol.MessageType, feature string, payload any) error {
	return c.sendControlOn(t, feature, payload, true)
}

func (c *Core) sendControlOn(t protocol.MessageType, feature string, payload any, unreliable bool) error {
	c.mu.Lock()
	relay := c.relay
	enabled := protocol.HasFeature(c.activeFeatures, feature)
	c.mu.Unlock()
	if relay == nil {
		return ErrNotConnected
	}
	if !enabled {
		return ErrFeatureNotEnabled
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	env := protocol.AppendEnvelope(nil, t, b)
	// Queued, so the bridge read goroutine never blocks on the relay; a full queue closes the connection rather than
	// drop a reliable line, and that is reported as a send failure.
	if !c.sendToRelay(relay, env, unreliable) {
		return ErrNotConnected
	}
	return nil
}

// SendEvent sends one event: ev.To names an addressee or is empty for a broadcast, and From and Seq are stamped by the
// relay. The sender receives its own event back with the sequencer stamp, which is where its action landed.
func (c *Core) SendEvent(ev protocol.Event) error {
	ev.From = ""
	ev.Seq = 0
	if !protocol.ValidateEvent(ev) {
		// Checked here too so a caller gets a real error; an oversized event should carry a reference, not the data.
		return fmt.Errorf("core: event exceeds protocol limits (payload max %d bytes)", protocol.MaxEventBytes)
	}
	return c.sendControl(protocol.TypeEvent, protocol.FeatureEventV1, ev)
}

// ClaimLease asks the relay for exclusive hold of an opaque key. The answer arrives later as a LeaseState, so this
// returns when the request was sent, never when it was granted. An adapter must ask before acting: acting first turns
// the relay's no into a rollback.
func (c *Core) ClaimLease(key string, ttl time.Duration) error {
	return c.sendLease(protocol.Lease{Op: protocol.LeaseClaim, Key: key, TTLMs: int(ttl.Milliseconds())})
}

// RenewLease extends a lease this Core already holds; from a non-holder it is denied, not turned into a claim.
func (c *Core) RenewLease(key string, ttl time.Duration) error {
	return c.sendLease(protocol.Lease{Op: protocol.LeaseRenew, Key: key, TTLMs: int(ttl.Milliseconds())})
}

// ReleaseLease gives up a held key immediately, rather than waiting out its TTL.
func (c *Core) ReleaseLease(key string) error {
	return c.sendLease(protocol.Lease{Op: protocol.LeaseRelease, Key: key})
}

func (c *Core) sendLease(req protocol.Lease) error {
	if !protocol.ValidateLease(req) {
		return fmt.Errorf("core: invalid lease request (key max %d bytes)", protocol.MaxLeaseKeyLen)
	}
	return c.sendControl(protocol.TypeLease, protocol.FeatureLeaseV1, req)
}

// SendEscrow drives one step of a two-sided atomic exchange; results arrive as EscrowState. An adapter applies the
// swap only on EscrowPhaseCommitted: any earlier phase, "both sides deposited" included, may still abort.
func (c *Core) SendEscrow(req protocol.Escrow) error {
	if !protocol.ValidateEscrow(req) {
		return fmt.Errorf("core: invalid escrow request (blob max %d bytes)", protocol.MaxEscrowBlobBytes)
	}
	return c.sendControl(protocol.TypeEscrow, protocol.FeatureEscrowV1, req)
}

// SetWorld writes one entity's opaque state into the relay's world, under an authority lease this Core must hold; a
// refusal arrives later as a WorldState carrying WorldDenied. reliable false is for motion the next write supersedes.
// A write that creates a key must be reliable: a lossy create is ignored, since the two planes cannot be ordered
// against each other. This Core keeps no world of its own; the relay's copy is authoritative.
func (c *Core) SetWorld(authority, key string, blob json.RawMessage, reliable bool) error {
	return c.sendWorld(protocol.World{
		Op: protocol.WorldSet, Authority: authority, Key: key, Blob: blob, Reliable: reliable,
	})
}

// DropWorld removes one entity from the world. Always reliable: nothing supersedes a drop.
func (c *Core) DropWorld(authority, key string) error {
	return c.sendWorld(protocol.World{
		Op: protocol.WorldDrop, Authority: authority, Key: key, Reliable: true,
	})
}

func (c *Core) sendWorld(req protocol.World) error {
	if !protocol.ValidateWorld(req) {
		return fmt.Errorf("core: invalid world write (authority max %d bytes, key max %d, blob max %d)",
			protocol.MaxLeaseKeyLen, protocol.MaxWorldKeyLen, protocol.MaxWorldBlobBytes)
	}
	if req.Reliable {
		return c.sendControl(protocol.TypeWorld, protocol.FeatureWorldV1, req)
	}
	return c.sendControlUnreliable(protocol.TypeWorld, protocol.FeatureWorldV1, req)
}

// planeNegotiated gates an inbound opt-in plane on both halves of the negotiation: the room agreed it, and this side
// asked for it. The second half does the work: a hostile relay writes activeFeatures itself but cannot make this
// client have asked, and a default cosmetic room asks for nothing. c.Features is fixed before the core runs.
func (c *Core) planeNegotiated(feature string) bool {
	c.mu.Lock()
	agreed := protocol.HasFeature(c.activeFeatures, feature)
	asked := protocol.HasFeature(c.adapterFeatures, feature)
	c.mu.Unlock()
	return agreed && (asked || protocol.HasFeature(c.Features, feature))
}

// handleOnlineMessage dispatches the event, lease, escrow and world planes to both the in-process callbacks and the
// attached adapter, and folds a pong into clock sync. It returns false for a type it does not handle.
func (c *Core) handleOnlineMessage(env protocol.Envelope) bool {
	switch env.Type {
	case protocol.TypeEvent:
		if !c.planeNegotiated(protocol.FeatureEventV1) {
			return true
		}
		var ev protocol.Event
		if err := json.Unmarshal(env.Payload, &ev); err != nil {
			return true
		}
		if !protocol.ValidateEvent(ev) {
			// Every inbound plane mirrors the relay's own check: a hostile relay is not trusted to have enforced it.
			return true
		}
		if c.OnEvent != nil {
			c.OnEvent(ev)
		}
		c.pushToAdapter(bridge.TypeEvent, bridge.Event{Event: ev})
	case protocol.TypeLeaseState:
		if !c.planeNegotiated(protocol.FeatureLeaseV1) {
			return true
		}
		var st protocol.LeaseState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			return true
		}
		if !protocol.ValidateLeaseState(st) {
			return true
		}
		if c.OnLeaseState != nil {
			c.OnLeaseState(st)
		}
		c.pushToAdapter(bridge.TypeLeaseState, bridge.LeaseState{LeaseState: st})
	case protocol.TypeEscrowState:
		if !c.planeNegotiated(protocol.FeatureEscrowV1) {
			return true
		}
		var st protocol.EscrowState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			return true
		}
		if !protocol.ValidateEscrowState(st) {
			return true
		}
		if c.OnEscrowState != nil {
			c.OnEscrowState(st)
		}
		c.pushToAdapter(bridge.TypeEscrowState, bridge.EscrowState{EscrowState: st})
	case protocol.TypeWorldState:
		if !c.planeNegotiated(protocol.FeatureWorldV1) {
			return true
		}
		var st protocol.WorldState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			return true
		}
		if !protocol.ValidateWorldState(st) {
			return true
		}
		// Not filtered against the roster: a world entry outlives its writer, and Holder may name someone who left.
		if c.OnWorldState != nil {
			c.OnWorldState(st)
		}
		c.pushToAdapter(bridge.TypeWorldState, bridge.WorldState{WorldState: st})
	case protocol.TypePong:
		var pong protocol.Pong
		if err := json.Unmarshal(env.Payload, &pong); err != nil {
			return true
		}
		c.observePong(pong)
	default:
		return false
	}
	return true
}

// observePong turns a heartbeat reply into a clock sample; a nonce with no recorded send time is ignored.
func (c *Core) observePong(pong protocol.Pong) {
	recvAt := time.Now() // wall-clock: half of an RTT measurement of the real network
	// The relay's clock reading gets a timestamp's bound.
	if pong.ServerTimeMs < 0 || pong.ServerTimeMs > protocol.MaxTimestampMs {
		return
	}
	c.mu.Lock()
	sentAt, ok := c.pendingPings[pong.Nonce]
	if !ok {
		c.mu.Unlock()
		return
	}
	delete(c.pendingPings, pong.Nonce)
	before := c.clock
	c.clock.observe(sentAt, recvAt, pong.ServerTimeMs)
	// The offset is bounded because nowMsLocked latches forward: one fast reply's offset would decide the session,
	// every render time would pass every sample, and the age-out would despawn the room. Refused rather than clamped,
	// keeping the last honest estimate.
	if off := c.clock.offsetMs; off > maxClockOffsetMs || off < -maxClockOffsetMs {
		c.clock = before
		c.mu.Unlock()
		log.Printf("core: ignoring the relay's clock -- it puts this room %s away from this machine's "+
			"own clock, which is past anything clock sync is meant to correct", time.Duration(off)*time.Millisecond)
		return
	}
	c.mu.Unlock()
}

// maxClockOffsetMs bounds how far a relay's clock may move this client's. Generous: clock sync corrects ordinary skew,
// which can be minutes, and an hour off is past where the machine's clock already breaks TLS certificate checks.
const maxClockOffsetMs = int64(60 * 60 * 1000)

// recordPingSent remembers when a nonce went out. The map is bounded, oldest nonce first, so a relay that never
// answers cannot grow it.
func (c *Core) recordPingSent(nonce uint64, at time.Time) {
	c.mu.Lock()
	if c.pendingPings == nil {
		c.pendingPings = make(map[uint64]time.Time, 8)
	}
	if len(c.pendingPings) > 32 {
		var oldest uint64
		first := true
		for n := range c.pendingPings {
			if first || n < oldest {
				oldest, first = n, false
			}
		}
		delete(c.pendingPings, oldest)
	}
	c.pendingPings[nonce] = at
	c.mu.Unlock()
}

// initialClockProbeCount pings go out right after connecting, initialClockProbeInterval apart: at the heartbeat's
// pace the estimate would take a minute to form, and the lowest-RTT estimator needs samples to choose between.
const (
	initialClockProbeCount    = 3
	initialClockProbeInterval = 1 * time.Second
)

// pushToAdapter sends one message to the attached adapter, if any; no adapter is a normal state, not worth a log line.
func (c *Core) pushToAdapter(t bridge.MessageType, payload any) {
	c.mu.Lock()
	nd := c.attachedAdapter
	c.mu.Unlock()
	if nd == nil {
		return
	}
	_ = c.sendToAdapter(nd, t, payload)
}

// reportBridgeSendErr logs an adapter's failed request rather than answering it: the planes answer asynchronously, and
// these failures are configuration problems (no capability, no relay), not per-request outcomes.
func (c *Core) reportBridgeSendErr(nd transport.Transport, t bridge.MessageType, err error) {
	if err == nil {
		return
	}
	log.Printf("core: adapter's %s could not be sent to the relay: %v", t, err)
}

// logResumeOutcome reports once what a reconnect achieved: a resumed session and a fresh join look identical from this
// side otherwise.
func logResumeOutcome(w protocol.Welcome, hadToken bool) {
	switch {
	case w.Resumed:
		log.Printf("core: resumed the previous session as %s — the room was never told we left", w.PlayerID)
	case hadToken:
		log.Printf("core: could not resume the previous session (token expired or the relay restarted) — joined fresh as %s", w.PlayerID)
	}
}

// sendGoodbye tells the relay this leave is deliberate, so it announces a real leave instead of holding the identity
// for a reconnect. Synchronous, so the line is on the socket before the Close that follows.
func sendGoodbye(relay transport.Transport) {
	payload, err := json.Marshal(protocol.Leave{})
	if err != nil {
		return
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeLeave, Payload: payload})
	if err != nil {
		return
	}
	if err := relay.Send(env); err != nil {
		log.Printf("core: could not tell the relay this was a deliberate leave (%v) — peers will see this session time out instead", err)
	}
}
