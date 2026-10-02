package core

import (
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// sessionFields is every per-connection value, read under the lock so a test can compare before against after without
// racing the teardown on the transport's read-loop goroutine.
type sessionFields struct {
	relayNil     bool
	playerID     string
	relayGame    string
	ownerNil     bool
	sendInterval time.Duration
	ghostPolicy  string
	policyKnown  bool
	featureCount int
	resumed      bool
	clock        clockSync
	lastNowMs    int64
	pendingPings int
	rosterSize   int
	remotesSize  int
	resumeToken  string
}

func snapshotSession(c *Core) sessionFields {
	c.mu.Lock()
	defer c.mu.Unlock()
	return sessionFields{
		relayNil:     c.relay == nil,
		playerID:     c.playerID,
		relayGame:    c.relayGame,
		ownerNil:     c.relayOwner == nil,
		sendInterval: c.serverSendInterval,
		ghostPolicy:  c.relayGhostCollision,
		policyKnown:  c.relayPolicyKnown,
		featureCount: len(c.activeFeatures),
		resumed:      c.resumed,
		clock:        c.clock,
		lastNowMs:    c.lastNowMs,
		pendingPings: len(c.pendingPings),
		rosterSize:   len(c.roster),
		remotesSize:  len(c.remotes),
		resumeToken:  c.resumeToken,
	}
}

// TestRelayDropForgetsEverythingThatConnectionTaughtUs closes the real socket and requires every per-connection field
// back at its empty value, after asserting each was populated: a reset test on an unset field passes against a deleted
// reset. resumeToken, lastNowMs and Core.seq are asserted to survive.
func TestRelayDropForgetsEverythingThatConnectionTaughtUs(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.GhostCollision = protocol.GhostCollisionDisabled
	relayAddr := startRelayWith(t, s)

	// The lazy hello path is the only one that sets relayOwner and the one a real game takes; the fast heartbeat
	// puts a real entry in pendingPings.
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.Features = []string{protocol.FeatureResumeV1}
		c.HeartbeatInterval = 5 * time.Millisecond
	})
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	waitForPlayerID(t, c)

	peer, peerBridge := startCoreLazy(t, relayAddr, "room1", "bob")
	peerAdapter := dialFakeAdapter(t, peerBridge)
	peerAdapter.hello("emerald")
	peerAdapter.awaitReady()
	waitForPlayerID(t, peer)

	// Re-sent every iteration: forwardLocalState drops a frame inside MinSendInterval rather than deferring it.
	peerState := protocol.State{AreaID: "zone-a", Position: []float64{1, 2}, Anim: "idle"}
	selfState := protocol.State{AreaID: "zone-a", Position: []float64{0, 0}, Anim: "idle"}
	deadline := time.Now().Add(testTimeout)
	// The ping-in-flight precondition reads polled, not the later `before`: a pong can land between the two reads.
	var polled sessionFields
	for time.Now().Before(deadline) {
		peerAdapter.frame(&peerState)
		fa.frame(&selfState)
		polled = snapshotSession(c)
		if polled.rosterSize > 0 && polled.remotesSize > 0 && polled.pendingPings > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Injected, not measured: the property is that teardown zeroes the estimate, not that it is right.
	c.mu.Lock()
	c.clock = clockSync{offsetMs: 5000, bestRTTMs: 20}
	c.lastNowMs = time.Now().UnixMilli() + 5000
	c.resumeToken = "token-from-this-session"
	// Disarm the automatic reconnect, or the core redials within milliseconds and the checks read the new session.
	c.autoRetryGameID = ""
	c.mu.Unlock()

	before := snapshotSession(c)
	seqBefore := atomic.LoadUint64(&c.seq)

	if before.relayNil {
		t.Fatal("setup: there is no relay connection to drop")
	}
	for _, f := range []struct {
		name  string
		unset bool
	}{
		{"playerID", before.playerID == ""},
		{"relayGame", before.relayGame == ""},
		{"relayOwner", before.ownerNil},
		{"serverSendInterval", before.sendInterval == 0},
		{"relayGhostCollision", before.ghostPolicy == ""},
		{"relayPolicyKnown", !before.policyKnown},
		{"activeFeatures", before.featureCount == 0},
		{"clock", before.clock == clockSync{}},
		{"lastNowMs", before.lastNowMs == 0},
		{"pendingPings", polled.pendingPings == 0}, // see polled: a pong may have landed since
		{"roster", before.rosterSize == 0},
		{"remotes", before.remotesSize == 0},
		{"resumeToken", before.resumeToken == ""},
	} {
		if f.unset {
			t.Fatalf("setup: %s was never populated, so this test cannot prove anything about it",
				f.name)
		}
	}

	c.mu.Lock()
	conn := c.relay
	c.mu.Unlock()
	if err := conn.Close(); err != nil {
		t.Fatalf("close relay connection: %v", err)
	}

	// dropAllRemotes clears remotes after the lock is released, so poll.
	var after sessionFields
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		after = snapshotSession(c)
		if after.relayNil && after.rosterSize == 0 && after.remotesSize == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	for _, f := range []struct {
		name string
		kept bool
	}{
		{"relay", !after.relayNil},
		{"playerID", after.playerID != ""},
		{"relayGame", after.relayGame != ""},
		{"relayOwner", !after.ownerNil},
		{"serverSendInterval", after.sendInterval != 0},
		{"relayGhostCollision", after.ghostPolicy != ""},
		{"relayPolicyKnown", after.policyKnown},
		{"activeFeatures", after.featureCount != 0},
		{"resumed", after.resumed},
		{"clock", after.clock != clockSync{}},
		{"pendingPings", after.pendingPings != 0},
		{"roster", after.rosterSize != 0},
		{"remotes", after.remotesSize != 0},
	} {
		if f.kept {
			t.Errorf("%s survived the relay disconnect -- the next connection would inherit "+
				"this one's answer", f.name)
		}
	}

	// lastNowMs survives the drop: clearing it rewinds the clock and leaves remote buffers unsorted, while keeping it
	// only freezes the emitted clock until real time catches up, which is bounded and self-heals.
	if after.lastNowMs < before.lastNowMs {
		t.Errorf("lastNowMs went BACKWARDS across the relay drop (%d, was %d) -- the emitted clock "+
			"rewinds by the dropped offset, which leaves every peer's interpolation buffer unsorted "+
			"and despawns the chaser pack", after.lastNowMs, before.lastNowMs)
	}

	if after.resumeToken != before.resumeToken {
		t.Errorf("resumeToken was cleared by the relay drop (%q -> %q) -- a drop is exactly when "+
			"it becomes useful, and clearing it here turns every reconnect into a new identity",
			before.resumeToken, after.resumeToken)
	}
	// Never rewinds, rather than never moves: a frame in flight at the close may still stamp one more.
	if seqAfter := atomic.LoadUint64(&c.seq); seqAfter < seqBefore {
		t.Errorf("Core.seq went backwards across the relay drop (%d -> %d) -- a peer that had "+
			"already seen the higher numbers would read the reconnect as a rewind",
			seqBefore, seqAfter)
	}
}

// TestAStaleIdCannotPassTheNextConnectionsTrustCheck: the roster is a trust boundary, so an id that outlived its
// connection must not pass the next one's check. The teardown is real; the next handshake is hand-driven, since a
// real reconnect would legitimately re-list the same peer.
func TestAStaleIdCannotPassTheNextConnectionsTrustCheck(t *testing.T) {
	relayAddr := startRelay(t)
	c, _ := startCore(t, relayAddr, "emerald", "room1", "alice")
	peer, _ := startCore(t, relayAddr, "emerald", "room1", "bob")
	waitForPlayerID(t, peer)
	staleID := peer.PlayerID()

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		_, known := c.roster[staleID]
		c.mu.Unlock()
		if known {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	c.mu.Lock()
	_, known := c.roster[staleID]
	c.mu.Unlock()
	if !known {
		t.Fatalf("setup: %q never entered the roster, so clearing it proves nothing", staleID)
	}

	c.mu.Lock()
	conn := c.relay
	c.mu.Unlock()
	if err := conn.Close(); err != nil {
		t.Fatalf("close relay connection: %v", err)
	}
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		gone := c.relay == nil
		c.mu.Unlock()
		if gone {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	c.handleRelayMessage(nil, mustEnvelope(t, protocol.TypeWelcome,
		protocol.Welcome{PlayerID: "self-2", Roster: []string{"announced-peer"}}), welcome, reject)
	c.handleRelayMessage(nil, mustEnvelope(t, protocol.TypeState, protocol.State{
		PlayerID: staleID, AreaID: "a", Position: []float64{1, 2}, Anim: "idle"}), welcome, reject)
	c.handleRelayMessage(nil, mustEnvelope(t, protocol.TypeState, protocol.State{
		PlayerID: "announced-peer", AreaID: "a", Position: []float64{3, 4}, Anim: "idle"}), welcome, reject)

	c.mu.Lock()
	_, stalePassed := c.remotes[staleID]
	_, announcedPassed := c.remotes["announced-peer"]
	c.mu.Unlock()

	if stalePassed {
		t.Error("a player_id from the PREVIOUS connection still passed the roster check -- " +
			"player_ids are only meaningful within the connection that assigned them")
	}
	// The negative control: a core that accepts no one would pass otherwise.
	if !announcedPassed {
		t.Error("the id the new Welcome actually announced was rejected too -- this test would " +
			"otherwise pass for the wrong reason")
	}
}

// TestALateDropFromASupersededConnectionChangesNothing: OnDisconnect runs on its own read-loop goroutine, so an old
// connection's callback can land after a newer one replaced it. Pure scheduling, so the seam is called directly.
func TestALateDropFromASupersededConnectionChangesNothing(t *testing.T) {
	c := New()
	superseded := &recordingTransport{}
	live := &recordingTransport{}

	c.mu.Lock()
	c.relay = live
	c.playerID = "p-live"
	c.relayGame = "emerald"
	c.relayOwner = live
	c.serverSendInterval = 20 * time.Millisecond
	c.relayGhostCollision = protocol.GhostCollisionDisabled
	c.relayPolicyKnown = true
	c.activeFeatures = []string{protocol.FeatureResumeV1}
	c.clock = clockSync{offsetMs: 7, bestRTTMs: 3}
	c.lastNowMs = 1234
	c.roster = map[string]int64{"p-peer": 0}
	c.mu.Unlock()

	before := snapshotSession(c)

	if wasCurrent, _ := c.clearRelaySession(superseded); wasCurrent {
		t.Fatal("a superseded connection's teardown reported itself as the live one")
	}
	if got := snapshotSession(c); got != before {
		t.Errorf("a superseded connection's teardown changed the live session:\n  before: %+v\n"+
			"  after:  %+v\nthe guard is what stops a stale read loop despawning every ghost in "+
			"a healthy session", before, got)
	}

	// The negative control: a guard, not a permanent refusal.
	if wasCurrent, _ := c.clearRelaySession(live); !wasCurrent {
		t.Fatal("the live connection's own teardown was ignored")
	}
	c.mu.Lock()
	cleared := c.relay == nil
	c.mu.Unlock()
	if !cleared {
		t.Error("the live connection's own teardown left c.relay set")
	}
}

// TestClearRelayIfCurrentIgnoresASupersededConnection is the same guard on ConnectRelay's failure path, which cannot
// wait for the read loop's callback.
func TestClearRelayIfCurrentIgnoresASupersededConnection(t *testing.T) {
	c := New()
	live := &recordingTransport{}
	c.mu.Lock()
	c.relay = live
	c.mu.Unlock()

	c.clearRelayIfCurrent(&recordingTransport{})
	c.mu.Lock()
	stillLive := c.relay == live
	c.mu.Unlock()
	if !stillLive {
		t.Fatal("a superseded connection's failure path cleared the live relay")
	}

	c.clearRelayIfCurrent(live)
	c.mu.Lock()
	cleared := c.relay == nil
	c.mu.Unlock()
	if !cleared {
		t.Fatal("the live connection's own failure path did not clear it")
	}
}

// mustEnvelope marshals payload into a relay envelope, for tests that feed handleRelayMessage directly.
func mustEnvelope(t *testing.T, typ protocol.MessageType, payload any) []byte {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal %s payload: %v", typ, err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: typ, Payload: b})
	if err != nil {
		t.Fatalf("marshal %s envelope: %v", typ, err)
	}
	return env
}
