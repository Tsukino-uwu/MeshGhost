package core

// Local peers: ghosts this core invents (a replay, the chaser pack), rendered through the same buffer and bridge
// messages as relay peers. A local peer never reaches the relay, always renders cosmetic, and never carries loss cover
// (Prev is stripped). The roster is wiped on every reconnect, so feedLocalPeer re-admits on every sample.

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

// isLocalPeerID says whether an id has the shape only this core hands out. render_remote.cosmetic is built from this,
// never from membership: a seam drops and re-admits the peer, and a tick inside that window would call it solid.
func isLocalPeerID(id string) bool {
	return strings.HasPrefix(id, localPeerReplayPrefix) || strings.HasPrefix(id, localPeerChaserPrefix)
}

// acceptableRelayPeerID is the shape a relay-announced player_id must have before this core keys anything by it: not
// empty, within MaxHelloFieldLenForID (it becomes a map key and reaches the mod verbatim), and without a local-peer
// prefix, or a relay minting "chaser:1" would feed this core's own chaser buffer a ghost the age-out never removes.
func acceptableRelayPeerID(id string) bool {
	return id != "" &&
		protocol.ValidOpaqueString(id, protocol.MaxHelloFieldLenForID) &&
		!isLocalPeerID(id)
}

// admitLocalPeer registers id as a ghost this core invents and hands the adapter its nametag. False means the roster
// is full and the peer will not render; the caller logs that once.
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
	c.storeRemoteName(id, &tag)
	return true
}

// feedLocalPeer hands one sample to the interpolation buffer as if it came from the relay. Its timestamp must already
// be on the c.nowMs() clock, which the age-out and the render clock read. False means id was never admitted, or the
// roster refused the re-admit.
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

// dropLocalPeer removes a local peer the way a relay Leave removes a real one, so the next render tick despawns it and
// a later admit is a fresh join.
func (c *Core) dropLocalPeer(id string) {
	c.mu.Lock()
	delete(c.roster, id)
	delete(c.remoteNames, id)
	delete(c.localPeers, id)
	c.mu.Unlock()
	c.dropRemote(id)
}

// ticksBegun is how many render ticks have started. A seam takes it right after the drop and waits for tickCount to
// pass it: a tick already in flight may have rendered the old peer without sending the despawn.
func (c *Core) ticksBegun() uint64 {
	return atomic.LoadUint64(&c.ticksStarted)
}

// tickCount is how many render ticks have run. A seek is a drop and a re-feed, and the despawn reaches the adapter
// only if a tick runs between them; otherwise the ghost glides instead of jumping.
func (c *Core) tickCount() uint64 {
	return atomic.LoadUint64(&c.ticks)
}

// awaitTick waits until tickCount passes after, or max elapses. Polled, not signalled: the adapter's frames may stop
// (a menu). stop lets halt() interrupt the replay and chaser goroutines that call this; a nil stop never fires.
func (c *Core) awaitTick(after uint64, max time.Duration, stop <-chan struct{}) bool {
	deadline := time.Now().Add(max)   // wall-clock: bounds a poll for an adapter frame
	for time.Now().Before(deadline) { // wall-clock: pairs with the deadline above
		if c.tickCount() > after {
			return true
		}
		select {
		case <-stop:
			// A tick may have landed between the check and the stop.
			return c.tickCount() > after
		case <-time.After(2 * time.Millisecond): // wall-clock: the poll interval
		}
	}
	return c.tickCount() > after
}
