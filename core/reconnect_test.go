package core

import (
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// What a dropped relay connection must forget, and the two guards that decide
// whether it forgets anything at all.
//
// Written 2026-08-22, after CI's -race job caught a re-attaching adapter being
// told "enabled" by a relay that had only ever said "disabled". That bug was
// one field (relayPolicyKnown) inside a teardown that clears thirteen, and a
// survey found exactly one of the thirteen had a test. The rest are all the
// same shape: carry a value from a connection that is gone into the next one,
// and the new session answers a new relay's questions with an old relay's
// answers -- silently, because every value involved is plausible.

// sessionFields is every per-connection value, read under the lock so a test
// can compare before against after without racing the teardown, which runs on
// the transport's own read-loop goroutine.
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

// TestRelayDropForgetsEverythingThatConnectionTaughtUs drives a REAL drop --
// closing the real socket, so the real OnDisconnect callback runs -- and then
// requires every per-connection field to be back at its "nothing has told us
// anything yet" value.
//
// It asserts the setup first, and that half is not a formality: a reset test
// whose field was never populated passes against a deleted reset, which is
// worse than no test at all.
//
// Two values are deliberately NOT cleared, and are asserted to survive:
// resumeToken (a drop is exactly when it becomes useful -- see resume_test.go)
// and Core.seq (the relay never asks a reconnecting client to restart its
// sequence, and restarting it would read as a rewind to a peer that had
// already seen higher numbers).
func TestRelayDropForgetsEverythingThatConnectionTaughtUs(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.GhostCollision = protocol.GhostCollisionDisabled
	relayAddr := startRelayWith(t, s)

	// The lazy/Hello path, because it is the only one that sets relayOwner and
	// the only one a real game ever takes. The fast heartbeat is what puts a
	// real entry in pendingPings instead of a fabricated one.
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.Features = []string{protocol.FeatureResumeV1}
		c.HeartbeatInterval = 5 * time.Millisecond
	})
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	waitForPlayerID(t, c)

	// A real peer, so the roster and the remote buffer are populated the way
	// production populates them rather than by hand.
	peer, peerBridge := startCoreLazy(t, relayAddr, "room1", "bob")
	peerAdapter := dialFakeAdapter(t, peerBridge)
	peerAdapter.hello("emerald")
	peerAdapter.awaitReady()
	waitForPlayerID(t, peer)

	// Re-sent every iteration: forwardLocalState DROPS a frame that arrives
	// inside MinSendInterval rather than deferring it, so a state sent exactly
	// once can legitimately never reach the wire.
	peerState := protocol.State{AreaID: "zone-a", Position: []float64{1, 2}, Anim: "idle"}
	selfState := protocol.State{AreaID: "zone-a", Position: []float64{0, 0}, Anim: "idle"}
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		peerAdapter.frame(&peerState)
		fa.frame(&selfState)
		got := snapshotSession(c)
		if got.rosterSize > 0 && got.remotesSize > 0 && got.pendingPings > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// The clock estimate is injected rather than measured: producing a real one
	// needs clock.v1 negotiated and a pong round trip, and the property under
	// test is "teardown zeroes it", not "the estimate is right". online_test.go
	// assigns c.clock directly for the same reason.
	c.mu.Lock()
	c.clock = clockSync{offsetMs: 5000, bestRTTMs: 20}
	c.lastNowMs = time.Now().UnixMilli() + 5000
	c.resumeToken = "token-from-this-session"
	// Disarm the automatic reconnect. The Hello path arms it, so without this
	// the core redials within milliseconds and every assertion below reads the
	// NEW session's freshly-populated fields instead of the cleared ones --
	// which is exactly how the first draft of this test "passed" nothing.
	// Reconnecting is TestRelayDisconnectAutoReconnects' job; this test is
	// about what the teardown leaves behind.
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
		{"pendingPings", before.pendingPings == 0},
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

	// remotes is cleared by dropAllRemotes after the lock is released, so this
	// needs a poll rather than a single read.
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

	// lastNowMs MUST SURVIVE THE DROP, and this assertion was the inverse until
	// 2026-09-08. Both directions are genuinely bad, which is why the reasoning
	// is written out rather than just the rule:
	//
	//   - CLEARING it (what this used to assert) lets nowMs step BACKWARDS by
	//     the dropped offset, because forgetRelaySessionLocked also clears
	//     activeFeatures and clockAdjustLocked returns 0 without clock.v1. A
	//     backwards clock is not a cosmetic problem: interp.go's remoteBuffer.add
	//     states that callers must add snapshots in non-decreasing Timestamp
	//     order and that it does not re-sort, so every peer's buffer goes
	//     unsorted; and recordLocal stamps the past, so a +5s room feeds the
	//     chaser pack nothing for five seconds, every chaser sees a gap past
	//     replayGapSeamMs, and the whole pack despawns and respawns on the
	//     player -- the same visible signature as the 2026-09-05 queue-hole bug.
	//   - KEEPING it (what this now asserts) means the clamp holds the emitted
	//     clock still until real time catches up: in that same +5s room,
	//     outgoing timestamps freeze for up to five seconds after the drop.
	//     That is a real cost and it is NOT nothing -- chasers and replays read
	//     the same clock, so they stall with it.
	//
	// Keeping it is the lesser of the two: a freeze is bounded by the offset and
	// self-heals, while an unsorted buffer is a corruption that persists. The
	// fix that avoids BOTH is to re-anchor the clock at the drop (carry the
	// offset forward as a baseline so the emitted value is continuous rather
	// than either rewound or frozen), which needs a new persistent term in
	// nowMsLocked -- the root every timestamp, render time and playback due-time
	// comes from. Recorded as the known residual rather than attempted in the
	// same pass; see REVIEW-FINDINGS.md E9.
	if after.lastNowMs < before.lastNowMs {
		t.Errorf("lastNowMs went BACKWARDS across the relay drop (%d, was %d) -- the emitted clock "+
			"rewinds by the dropped offset, which leaves every peer's interpolation buffer unsorted "+
			"and despawns the chaser pack", after.lastNowMs, before.lastNowMs)
	}

	// The two deliberate exceptions.
	if after.resumeToken != before.resumeToken {
		t.Errorf("resumeToken was cleared by the relay drop (%q -> %q) -- a drop is exactly when "+
			"it becomes useful, and clearing it here turns every reconnect into a new identity",
			before.resumeToken, after.resumeToken)
	}
	// Never rewinds, rather than never moves: a frame already in flight when
	// the socket closed may still stamp one more on its way out.
	if seqAfter := atomic.LoadUint64(&c.seq); seqAfter < seqBefore {
		t.Errorf("Core.seq went backwards across the relay drop (%d -> %d) -- a peer that had "+
			"already seen the higher numbers would read the reconnect as a rewind",
			seqBefore, seqAfter)
	}
}

// TestAStaleIdCannotPassTheNextConnectionsTrustCheck is the roster half of the
// sweep above, asserted through its consequence rather than through the map's
// size, because the roster is a trust boundary: a state whose player_id is not
// in it is dropped, so an id that outlived the connection that named it would
// be rendering a ghost the current relay never announced.
//
// The teardown here is real; only the NEXT connection's handshake is
// synthetic. A real reconnect would legitimately re-list the same peer, so the
// test would first have to prove the peer had left -- a timing dependency that
// buys no extra coverage of the line under test.
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

	// The next connection's handshake, hand-driven: a Welcome naming a
	// DIFFERENT peer, then one state from each id.
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
	// The negative control: without it, this test would also pass against a
	// core that had simply stopped accepting anyone at all.
	if !announcedPassed {
		t.Error("the id the new Welcome actually announced was rejected too -- this test would " +
			"otherwise pass for the wrong reason")
	}
}

// TestALateDropFromASupersededConnectionChangesNothing covers the guard
// nothing else can reach.
//
// A transport's OnDisconnect runs on its own read-loop goroutine, so an OLD
// connection's callback can land after a NEWER one has already replaced it.
// Without the guard, that late callback nulls the live relay, empties the live
// roster and despawns every ghost in a session that is perfectly healthy. The
// hazard is pure scheduling, so it is asserted at the seam rather than raced
// for: clearRelaySession is called directly with the superseded connection.
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
	c.roster = map[string]struct{}{"p-peer": {}}
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

	// The negative control: the guard must be a guard, not a permanent refusal.
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

// TestClearRelayIfCurrentIgnoresASupersededConnection is the same guard on
// ConnectRelay's failure path, which exists precisely because that path cannot
// wait for the read loop's callback to arrive.
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

// mustEnvelope marshals payload into a relay envelope, for the tests that feed
// handleRelayMessage directly instead of going over a socket.
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
