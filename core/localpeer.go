package core

// Local peers: ghosts this core invents rather than learns from the relay.
//
// A replay of a recorded run and the chaser (the player's own past, a few
// seconds behind) are both fed through here (ADR 0047). The whole design rests
// on one property the core already had: nothing downstream of storeRemoteState
// can tell where a sample came from, so a ghost that was never on the network
// renders through the same buffer, the same bridge messages and the same
// adapter code as a real peer. This file is the seam that makes that explicit
// and pins the three things a local peer must never do:
//
//   - reach the relay: the only send path is forwardLocalState -> sendState,
//     which reads the adapter's own state and never c.remotes, and a
//     relay-issued id never has the "replay:"/"chaser:" shape;
//   - be solid: every render_remote for a local peer carries cosmetic=true so
//     an adapter treats it as a picture whatever ghost_collision says;
//   - carry loss cover: Prev is stripped, so ApplyPrev never runs on a sample
//     the core itself made.
//
// THE ROSTER IS PER RELAY SESSION and is wiped on every reconnect
// (forgetRelaySessionLocked), so a local peer cannot rely on a one-time admit.
// feedLocalPeer re-admits on every sample -- one map lookup -- and the seat it
// takes counts against protocol.MaxRosterSize like any other peer's.

import (
	"strings"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

const (
	localPeerReplayPrefix = "replay:"
	localPeerChaserPrefix = "chaser:"
)

// isLocalPeerID says whether an id has the shape only this core hands out.
// Relay ids come from the relay's own counter and never carry a colon prefix
// like these, which is what keeps the two namespaces from colliding.
func isLocalPeerID(id string) bool {
	return strings.HasPrefix(id, localPeerReplayPrefix) || strings.HasPrefix(id, localPeerChaserPrefix)
}

// admitLocalPeer registers id as a ghost this core invents and hands the
// adapter its nametag. False means the roster is full (protocol.MaxRosterSize)
// and the peer will not render; the caller logs that once.
func (c *Core) admitLocalPeer(id string, tag protocol.Nametag) bool {
	c.mu.Lock()
	if c.localPeers == nil {
		c.localPeers = make(map[string]struct{})
	}
	ok := c.admitToRosterLocked(id)
	if ok {
		c.localPeers[id] = struct{}{}
	}
	c.mu.Unlock()
	if !ok {
		return false
	}
	// storeRemoteName sanitizes, stores, and pushes remote_name only on a
	// change -- and pushRemoteNames backfills a late-attaching adapter -- so a
	// local peer's tag is handled exactly like a relay peer's.
	c.storeRemoteName(id, &tag)
	return true
}

// feedLocalPeer hands one sample to the interpolation buffer as if it had
// arrived from the relay for id. The sample's timestamp must already be in the
// c.nowMs() domain (the caller rebases a recording; the chaser stamps its own
// due time), because the stale age-out and the render clock both read that
// clock. False means id was never admitted, or the roster refused the re-admit.
func (c *Core) feedLocalPeer(id string, st protocol.State) bool {
	st.PlayerID = id
	st.Prev = nil
	c.mu.Lock()
	_, local := c.localPeers[id]
	ok := local && c.admitToRosterLocked(id)
	c.mu.Unlock()
	if !ok {
		return false
	}
	c.storeRemoteState(st)
	return true
}

// dropLocalPeer removes a local peer the way a relay Leave removes a real one:
// roster, nametag and buffer together, so the next render tick despawns it and
// a later admit is a fresh join (the adapter is told the name again).
func (c *Core) dropLocalPeer(id string) {
	c.mu.Lock()
	delete(c.roster, id)
	delete(c.remoteNames, id)
	delete(c.localPeers, id)
	c.mu.Unlock()
	c.dropRemote(id)
}

// isLocalPeer is the render-time check behind render_remote.cosmetic.
func (c *Core) isLocalPeer(id string) bool {
	c.mu.Lock()
	_, local := c.localPeers[id]
	c.mu.Unlock()
	return local
}

// tickCount is how many render ticks have run. A seek (restart, rewind, the
// loop seam) is a drop followed by a re-feed, and the despawn only reaches the
// adapter if a tick runs BETWEEN the two -- otherwise the diff in tickRenders
// sees the id present on both sides and the ghost glides instead of jumping.
func (c *Core) tickCount() uint64 {
	return atomic.LoadUint64(&c.ticks)
}

// awaitTick waits until at least one render tick has run after `after`, or
// max elapses. Polled rather than signalled: ticks are driven by the adapter's
// own frames, which may simply stop (the game is in a menu), and a waiter that
// blocks forever on a game that stopped calling would wedge a replay.
func (c *Core) awaitTick(after uint64, max time.Duration) bool {
	deadline := time.Now().Add(max)
	for time.Now().Before(deadline) {
		if c.tickCount() > after {
			return true
		}
		time.Sleep(2 * time.Millisecond)
	}
	return c.tickCount() > after
}
