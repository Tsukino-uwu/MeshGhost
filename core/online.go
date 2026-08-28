package core

// The client half of everything past the cosmetic state plane: capability
// advertisement, clock sync against the relay, session resumption, and the
// send/receive paths for the event, lease, escrow and world planes. (The world
// plane was missing from this list until 2026-08-27; SetWorld, DropWorld and
// sendWorld are all in this file.)
//
// Nothing here interprets a payload. A lease key, an escrow blob and an event
// payload pass through this package as opaque bytes on their way between the
// relay and whichever adapter asked for them — the same rule that keeps the
// core game-agnostic for area_id and anim (CLAUDE.md), applied to a plane
// that could otherwise carry a whole battle protocol.

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// clockSync is this connection's estimate of the offset between the local
// wall clock and the relay's.
//
// **Why it exists:** agent_docs/contract.md makes State.Timestamp wall-clock,
// and interp.go's remoteBuffer.at() compares a *local* render time directly
// against a *remote's* timestamps. Two peers whose clocks disagree by more
// than the interpolation delay therefore stop interpolating and fall back to
// an edge snapshot every tick — with no error anywhere, which is the worst
// possible failure mode: ghosts that look subtly wrong for a reason nothing
// reports. Nobody's clock has to be *correct*; they only have to agree, and
// the relay is the one thing every member of a room already shares.
//
// The estimate keeps the sample with the LOWEST round-trip time rather than
// averaging. That is the standard approach and the right one: a slow sample
// is slow because it was delayed somewhere, and an asymmetric delay is
// exactly what corrupts an offset estimate. Averaging drags the estimate
// toward the noise; keeping the best sample discards it.
type clockSync struct {
	// offsetMs is (relay clock - local clock) in milliseconds, from the best
	// sample so far. Zero also means "never measured", which is deliberately
	// indistinguishable from "measured as zero" — both mean "apply nothing".
	offsetMs int64
	// bestRTTMs is the round-trip time of the sample offsetMs came from.
	// Zero means no sample yet.
	bestRTTMs int64
}

// observe folds one ping/pong round trip into the estimate. sentAt is when
// the Ping went out, serverMs is the relay's own clock from the Pong, and
// recvAt is when the Pong arrived.
//
// The offset is the standard three-timestamp estimate: assume the network
// delay was symmetric, so the relay's clock reading corresponds to the local
// midpoint of the round trip.
func (cs *clockSync) observe(sentAt, recvAt time.Time, serverMs int64) {
	if serverMs == 0 {
		// An older relay that does not stamp its clock. Nothing to learn, and
		// no offset applied — exactly the pre-2026-08-17 behaviour.
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

// The clock's two numbers are read through Stats() -- see core/stats.go, which
// records why: these were exported as ClockOffsetMs() and RelayRTTMs() on the
// claim that "a caller can log or display it", and then no caller ever did.
// Both were deleted on 2026-08-27 with zero call sites anywhere including
// tests; Stats.ClockOffsetMs and Stats.RelayRTTMs expose the same two values to
// the one consumer that wanted them.

// nowMs is the timestamp this Core stamps on outgoing state: local wall clock,
// shifted into the relay's clock domain when clock sync is in play.
//
// The shift is applied only for a room that agreed on FeatureClockV1, because
// it changes which clock a timestamp is expressed in — and a room where some
// members shift and others don't is worse than one where nobody does. Feature
// stickiness is what makes that safe to assume rather than hope for. Caller
// must not hold c.mu.
func (c *Core) nowMs() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.nowMsLocked()
}

// nowMsLocked is nowMs for a caller that ALREADY HOLDS c.mu. It exists
// because Go mutexes are not reentrant and taking c.mu twice on one goroutine
// deadlocks the whole client -- which is not hypothetical: remoteStatesAt,
// which runs under the lock, called nowMs on 2026-08-28 and hung the core on
// its first render tick. The visible symptom was two frozen GAMES, because an
// adapter writing state to a core that has stopped reading eventually blocks on
// the socket, on the game's main thread. Anything called from under c.mu needs
// this form.
func (c *Core) nowMsLocked() int64 {
	ms := time.Now().UnixMilli() + c.clockAdjustLocked()
	// **Never go backwards.** The offset is re-estimated whenever a better
	// (lower-RTT) sample arrives, so it can DECREASE — and this value feeds
	// both the timestamp stamped on outgoing state and the render time used to
	// interpolate remotes. Either one moving backwards is a real fault:
	//
	//   - interp.go's remoteBuffer.add states plainly that callers must add
	//     snapshots in non-decreasing Timestamp order and that it does not
	//     re-sort, so a timestamp that went backwards would leave every peer's
	//     buffer unsorted and at() picking the wrong bracket.
	//   - a render time that went backwards would rewind every ghost slightly,
	//     and — because opaque fields come from the older bracketing snapshot —
	//     could flip one back to a previous value, manufacturing a state edge
	//     in a field the core is forbidden to interpret. An adapter that fires
	//     on such an edge (Pseudoregalia poses a ghost's slide exactly that
	//     way) would act on a transition that never happened.
	//
	// Clamping rather than slewing: this holds the clock still until real time
	// catches up, which is what a monotonic clock should do with a correction
	// that would otherwise step back. A correction FORWARD is applied
	// immediately, since jumping ahead breaks neither property above.
	if ms < c.lastNowMs {
		ms = c.lastNowMs
	}
	c.lastNowMs = ms
	return ms
}

// clockAdjustLocked returns the offset to apply, or 0 when this room did not
// opt into clock sync. Caller holds c.mu.
func (c *Core) clockAdjustLocked() int64 {
	if !protocol.HasFeature(c.activeFeatures, protocol.FeatureClockV1) {
		return 0
	}
	return c.clock.offsetMs
}

// effectiveFeatures is what this Core advertises: its own configured
// Features plus whatever the adapter asked for in its bridge Hello,
// normalized into one set.
//
// The adapter gets a say here, unlike with the relay address, transport or
// rate (agent_docs/contract.md's invariant). That is not an exception to the
// rule but an application of the same logic that already lets an adapter
// report game_version: a capability is a statement about what the ADAPTER can
// do, and the adapter is the only thing that knows. It still cannot influence
// *how* the core reaches the relay — only what it will ask that relay for.
func (c *Core) effectiveFeatures() []string {
	c.mu.Lock()
	adapter := c.adapterFeatures
	c.mu.Unlock()
	combined := make([]string, 0, len(c.Features)+len(adapter))
	combined = append(combined, c.Features...)
	combined = append(combined, adapter...)
	return protocol.NormalizeFeatures(combined)
}

// RoomFeatures is what the relay reported this room actually agreed on,
// which is what every send path below gates against — not what this Core
// asked for. Empty against a relay that predates feature negotiation. Set
// from Welcome, cleared on disconnect.
func (c *Core) RoomFeatures() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]string, len(c.activeFeatures))
	copy(out, c.activeFeatures)
	return out
}

// Resumed reports whether the current relay session reclaimed a previous
// identity rather than being issued a new one. False for a fresh session and
// for any room without protocol.FeatureResumeV1.
func (c *Core) Resumed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.resumed
}

// ErrFeatureNotEnabled is returned by the send paths below when this room's
// agreed feature set does not include the capability being used. A distinct
// error rather than a silent drop: a caller that asks for a lease in a room
// with no leases has a configuration problem, and silence is how that becomes
// a bug report about trades "sometimes" not working.
var ErrFeatureNotEnabled = fmt.Errorf("core: this room did not negotiate that capability")

// ErrNotConnected is returned when there is no relay connection to send on.
var ErrNotConnected = fmt.Errorf("core: not connected to a relay")

// sendControl marshals and sends one non-state message on the RELIABLE plane.
// Reliable is the default and is what every plane but one uses: a lease grant,
// an escrow step and an event all carry a decision, and unlike a position
// sample a lost one is never superseded by the next.
//
// The one exception is a lossy world write, which goes through
// sendControlUnreliable below. That is a delivery choice the ADAPTER makes per
// write, not a property of the plane — see protocol.World.Reliable.
func (c *Core) sendControl(t protocol.MessageType, feature string, payload any) error {
	return c.sendControlOn(t, feature, payload, false)
}

// sendControlUnreliable is sendControl for a message the caller has declared
// superseded by its own next update. Named distinctly rather than added as a
// bool on sendControl, the same reasoning transport.SendUnreliable and
// Room.ForwardUnreliable already follow: reliability is opt-OUT, so a call site
// that never learns this exists stays correct.
//
// **Losing reliability does not lose ordering.** The relay stamps and delivers
// every world write under one lock regardless of which of these sent it, so a
// message that arrives is never out of order with respect to another that
// arrived; it can only be missing. On tcp there is no difference at all.
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
	// See sendState's note: one pass rather than marshaling the payload and
	// then marshaling an envelope around its own output.
	env := protocol.AppendEnvelope(nil, t, b)
	if unreliable {
		return relay.SendUnreliable(env)
	}
	return relay.Send(env)
}

// SendEvent sends one event. ev.To names an addressee, or is empty for a room
// broadcast; From and Seq are ignored on send and stamped by the relay.
//
// The sender always receives its own event back, carrying the relay's
// sequencer stamp — that echo is how a client learns where its own action
// landed in the total order, and an adapter distinguishes it by comparing
// From against its own player_id.
func (c *Core) SendEvent(ev protocol.Event) error {
	ev.From = ""
	ev.Seq = 0
	if !protocol.ValidateEvent(ev) {
		// Checked here as well as at the relay, the same two-enforcement-point
		// discipline ValidateState already has — a caller gets a real error
		// instead of a message the relay silently drops. There is no
		// fragmentation fallback on purpose: an oversized payload means the
		// event should carry a reference to the data rather than the data.
		return fmt.Errorf("core: event exceeds protocol limits (payload max %d bytes)", protocol.MaxEventBytes)
	}
	return c.sendControl(protocol.TypeEvent, protocol.FeatureEventV1, ev)
}

// ClaimLease asks the relay for exclusive hold of an opaque key. The answer
// arrives asynchronously as a LeaseState (OnLeaseState, or over the bridge) —
// **this returns when the request was sent, never when it was granted.**
//
// The adapter must ask BEFORE acting, never announce after. Acting locally
// and then claiming puts the relay's "no" after the fact is already on
// screen, which is a rollback problem: per-game, and genuinely hard. That
// costs a network round trip before anything visible happens, which is
// invisible for a turn-based trade and unacceptable for anything twitchy —
// and is the real reason this goes no deeper than bounded, consensual
// interactions.
func (c *Core) ClaimLease(key string, ttl time.Duration) error {
	return c.sendLease(protocol.Lease{Op: protocol.LeaseClaim, Key: key, TTLMs: int(ttl.Milliseconds())})
}

// RenewLease extends a lease this Core already holds. From a non-holder it is
// denied rather than quietly upgraded into a claim.
func (c *Core) RenewLease(key string, ttl time.Duration) error {
	return c.sendLease(protocol.Lease{Op: protocol.LeaseRenew, Key: key, TTLMs: int(ttl.Milliseconds())})
}

// ReleaseLease gives up a held key immediately, rather than waiting out its
// TTL.
func (c *Core) ReleaseLease(key string) error {
	return c.sendLease(protocol.Lease{Op: protocol.LeaseRelease, Key: key})
}

func (c *Core) sendLease(req protocol.Lease) error {
	if !protocol.ValidateLease(req) {
		return fmt.Errorf("core: invalid lease request (key max %d bytes)", protocol.MaxLeaseKeyLen)
	}
	return c.sendControl(protocol.TypeLease, protocol.FeatureLeaseV1, req)
}

// SendEscrow drives one step of a two-sided atomic exchange. Results arrive
// asynchronously as EscrowState.
//
// **An adapter applies the swap only on EscrowPhaseCommitted, and never
// before.** Any other phase — including "both sides deposited" — may still
// end in an abort, and acting early is how one side ends up having given
// something away that the other never received.
func (c *Core) SendEscrow(req protocol.Escrow) error {
	if !protocol.ValidateEscrow(req) {
		return fmt.Errorf("core: invalid escrow request (blob max %d bytes)", protocol.MaxEscrowBlobBytes)
	}
	return c.sendControl(protocol.TypeEscrow, protocol.FeatureEscrowV1, req)
}

// SetWorld writes one entity's opaque state into the world the relay holds
// custody of, under an authority lease this Core must already hold. Like every
// other send here it returns when the request went out, never when it was
// accepted — a refusal arrives asynchronously as a WorldState carrying
// protocol.WorldDenied.
//
// reliable selects the delivery variant: false for continuous motion that the
// next write supersedes, true for a change that must not be missed. **A write
// that CREATES a key must be reliable** — a lossy one on a key the relay does
// not yet hold is ignored, because the lossy and reliable planes cannot be
// ordered against each other and a create that raced a drop would resurrect an
// entity permanently. See protocol.WorldSet.
//
// **This Core keeps no world of its own.** It forwards writes up and states
// down and holds nothing in between, exactly as it does for leases. A map of
// entities in here would be the core holding game state, which is the one thing
// the core/adapter split exists to prevent — and it would be wrong as well as
// forbidden, since the relay's copy is the authoritative one.
func (c *Core) SetWorld(authority, key string, blob json.RawMessage, reliable bool) error {
	return c.sendWorld(protocol.World{
		Op: protocol.WorldSet, Authority: authority, Key: key, Blob: blob, Reliable: reliable,
	})
}

// DropWorld removes one entity from the world. Always reliable: a drop is by
// definition not superseded by anything, and a lost one leaves an entity
// standing for everyone who missed it with no later message to correct them.
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

// handleOnlineMessage dispatches the event/lease/escrow planes to whichever
// consumers exist: the in-process callbacks, and the attached adapter over
// the bridge. Both, not either — an in-process host may want to observe
// traffic it also forwards. Returns false for a type it does not handle, so
// handleRelayMessage's own switch keeps its unknown-type fallthrough.
func (c *Core) handleOnlineMessage(env protocol.Envelope) bool {
	switch env.Type {
	case protocol.TypeEvent:
		var ev protocol.Event
		if err := json.Unmarshal(env.Payload, &ev); err != nil {
			return true
		}
		if !protocol.ValidateEvent(ev) {
			// Mirrors the relay's own check on receive. A hostile or
			// compromised relay is not trusted to have enforced its limits,
			// the same posture ValidateState already takes here.
			return true
		}
		if c.OnEvent != nil {
			c.OnEvent(ev)
		}
		c.pushToAdapter(bridge.TypeEvent, bridge.Event{Event: ev})
	case protocol.TypeLeaseState:
		var st protocol.LeaseState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			return true
		}
		if c.OnLeaseState != nil {
			c.OnLeaseState(st)
		}
		c.pushToAdapter(bridge.TypeLeaseState, bridge.LeaseState{LeaseState: st})
	case protocol.TypeEscrowState:
		var st protocol.EscrowState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			return true
		}
		if c.OnEscrowState != nil {
			c.OnEscrowState(st)
		}
		c.pushToAdapter(bridge.TypeEscrowState, bridge.EscrowState{EscrowState: st})
	case protocol.TypeWorldState:
		var st protocol.WorldState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			return true
		}
		if !protocol.ValidateWorldState(st) {
			// Mirrors the relay's own check, the hostile-relay posture the
			// event and state planes already take on this side.
			return true
		}
		// **Deliberately NOT filtered against the roster**, unlike
		// storeRemoteState. A world entry legitimately outlives the player who
		// wrote it, and Holder may name someone who has already left — so a
		// roster check here would silently discard exactly the adopted world
		// custody exists to preserve. See protocol.WorldState.Holder.
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

// observePong turns a heartbeat reply into a clock sample. A nonce with no
// recorded send time is ignored — it belongs to a previous connection, or to
// a relay echoing something this Core never sent.
func (c *Core) observePong(pong protocol.Pong) {
	recvAt := time.Now()
	c.mu.Lock()
	sentAt, ok := c.pendingPings[pong.Nonce]
	if ok {
		delete(c.pendingPings, pong.Nonce)
		c.clock.observe(sentAt, recvAt, pong.ServerTimeMs)
	}
	c.mu.Unlock()
}

// recordPingSent remembers when a nonce went out, bounding the map so a relay
// that never answers cannot make it grow. Pings are sequential per
// connection, so dropping the oldest is dropping the least useful.
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

// initialClockProbeCount / initialClockProbeInterval control the short burst
// of pings sent right after connecting.
//
// The burst exists because the heartbeat runs every 20s, and an estimate that
// takes a minute to form is useless for the first minute — which is exactly
// when a player is walking into view of everyone else. Three probes a second
// apart cost three messages and give the "keep the lowest RTT" estimator
// something to choose between, which one sample cannot.
const (
	initialClockProbeCount    = 3
	initialClockProbeInterval = 1 * time.Second
)

// pushToAdapter sends one message to the attached adapter, if there is one.
// Silently does nothing when no adapter is attached — a core with no game on
// it is a normal, expected state (it is what every core looks like before the
// game launches), not an error worth logging per message.
func (c *Core) pushToAdapter(t bridge.MessageType, payload any) {
	c.mu.Lock()
	nd := c.attachedAdapter
	c.mu.Unlock()
	if nd == nil {
		return
	}
	sendBridgeEnvelope(nd, t, payload)
}

// reportBridgeSendErr logs an adapter's failed request against the relay.
//
// Logged rather than answered with a bridge-level rejection, deliberately.
// The three planes are asynchronous by nature — a lease request's real answer
// is a LeaseState that arrives later — so adding a second, synchronous
// failure channel would give an adapter two different shapes to handle for
// one operation. The failures reachable here are all configuration problems
// (a capability this room never negotiated, or no relay connection yet), not
// per-request outcomes, and they belong in the log the user reads once rather
// than in a code path every adapter must implement.
func (c *Core) reportBridgeSendErr(nd transport.Transport, t bridge.MessageType, err error) {
	if err == nil {
		return
	}
	log.Printf("core: adapter's %s could not be sent to the relay: %v", t, err)
}

// logResumeOutcome reports what a reconnect actually achieved, once, at the
// point it is known. Worth a line: "your ghost never disappeared for anyone"
// and "everyone saw you leave and come back" look identical from this side
// otherwise, and only one of them is the behaviour resumption was configured
// for.
func logResumeOutcome(w protocol.Welcome, hadToken bool) {
	switch {
	case w.Resumed:
		log.Printf("core: resumed the previous session as %s — the room was never told we left", w.PlayerID)
	case hadToken:
		log.Printf("core: could not resume the previous session (token expired or the relay restarted) — joined fresh as %s", w.PlayerID)
	}
}

// sendGoodbye tells the relay this client is leaving deliberately, so it
// announces a real leave rather than holding the identity for a reconnect.
//
// Synchronous, and sent before the Close that follows it: transport.Send
// writes the line to the socket before returning, so a goodbye that raced its
// own hangup would put us straight back to the behaviour this removes. Same
// send-before-close reasoning as rejectBridge.
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
		// Only worth a line at all because its absence changes what every
		// other player sees: without a goodbye they watch a frozen ghost until
		// the grace window expires instead of seeing a clean departure.
		log.Printf("core: could not tell the relay this was a deliberate leave (%v) — peers will see this session time out instead", err)
	}
}
