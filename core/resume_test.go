package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// The CLIENT half of session resumption.
//
// Until 2026-08-22 no test in this package so much as mentioned resumeToken.
// Every resume test lived in relay/online_test.go and drove raw protocol
// clients, so the relay's half was well covered and the code in THIS package
// -- storing the token, presenting it on the next Hello, discarding it when
// the game closes -- had never run under test at all.
//
// The rule the pair below pins is an asymmetry, and it is the whole design: a
// dropped relay keeps the token, because that is precisely the drop it exists
// for; the game closing discards it, because a relaunched game must be a new
// player in the room rather than a silent reclaim of the old identity.

// startResumingCore is a Core that asks for resume.v1, connected eagerly.
// resume.v1 is client-scoped, so it never splits a room -- one member can have
// it while others do not, which is what lets these tests share an ordinary
// relay with an ordinary peer.
func startResumingCore(t *testing.T, relayAddr, room, name string) *Core {
	t.Helper()
	c := New()
	c.RelayAddr = relayAddr
	c.Room = room
	c.DisplayName = name
	c.DialTimeout = testTimeout
	c.Features = []string{protocol.FeatureResumeV1}
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect relay: %v", err)
	}
	return c
}

func resumeTokenOf(c *Core) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.resumeToken
}

// waitForRelayGone polls until the core has noticed its relay connection is
// gone. The teardown runs on the transport's read-loop goroutine, so it lands
// whenever that goroutine is next scheduled, not synchronously on Close.
func waitForRelayGone(t *testing.T, c *Core) {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		gone := c.relay == nil
		c.mu.Unlock()
		if gone {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for the core to notice its relay connection had dropped")
}

// TestReconnectPresentsTheTokenAndReclaimsTheSameIdentity is the first test
// anywhere that runs this package's resume code.
//
// The reconnect is driven by the test rather than by reconnectWithBackoff,
// whose first retry is a full second away -- the property under test is "the
// token is kept and presented", not "the backoff schedule is what it is".
func TestReconnectPresentsTheTokenAndReclaimsTheSameIdentity(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	// Explicit, though the 20s default would do: a grace expiry here would
	// look like a resume failure, and the two deserve different diagnoses.
	s.ResumeGrace = 30 * time.Second
	relayAddr := startRelayWith(t, s)

	c := startResumingCore(t, relayAddr, "room1", "alice")
	firstID := c.PlayerID()
	firstToken := resumeTokenOf(c)
	if firstID == "" || firstToken == "" {
		t.Fatalf("setup: the relay minted no resume token (id %q, token %q) -- it only does so "+
			"for a client that asked for resume.v1, and without one the rest of this test would "+
			"pass for the wrong reason", firstID, firstToken)
	}

	c.mu.Lock()
	conn := c.relay
	c.mu.Unlock()
	if err := conn.Close(); err != nil {
		t.Fatalf("close relay connection: %v", err)
	}
	waitForRelayGone(t, c)

	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("reconnect: %v", err)
	}

	if got := c.PlayerID(); got != firstID {
		t.Errorf("player id after the reconnect is %q, want %q -- the token was not presented, "+
			"so every peer in the room saw this client leave and a stranger arrive", got, firstID)
	}
	if !c.Resumed() {
		t.Error("Resumed() is false after reclaiming the same identity")
	}
	// Tokens are single-use: the relay rotates one on every resume, and a
	// client that kept the spent one would fail to resume the SECOND time.
	if got := resumeTokenOf(c); got == "" || got == firstToken {
		t.Errorf("resume token after the reconnect is %q (was %q) -- the rotated token was not "+
			"stored, so the next drop would not be resumable", got, firstToken)
	}
}

// TestARelaunchedGameIsANewIdentityNotAResumedOne is the other half of the
// asymmetry: the token is discarded when the OWNER bridge connection goes,
// because that means the game itself closed.
//
// The black-box half of this -- a fresh player id -- would pass even with the
// token clear deleted, because the core also sends an explicit Leave
// (sendGoodbye) which ends the relay-side session immediately, so there would
// be nothing left to resume into. The private-field assertion is therefore the
// one that actually isolates the client's behaviour, and is why this test
// reads resumeToken directly.
func TestARelaunchedGameIsANewIdentityNotAResumedOne(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.ResumeGrace = 30 * time.Second
	relayAddr := startRelayWith(t, s)

	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.Features = []string{protocol.FeatureResumeV1}
	})
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	waitForPlayerID(t, c)

	firstID := c.PlayerID()
	if resumeTokenOf(c) == "" {
		t.Fatal("setup: no resume token was issued, so discarding it proves nothing")
	}

	// The game closing: the adapter's bridge connection goes away.
	fa.conn.Close()

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if resumeTokenOf(c) == "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := resumeTokenOf(c); got != "" {
		t.Errorf("the resume token survived the game closing (%q) -- the relaunched game would "+
			"silently reclaim the previous session's identity", got)
	}

	// Retry rather than assuming the admission slot is free the instant the
	// socket closes: the core frees it from the departing connection's own
	// read loop.
	reattachFakeAdapter(t, bridgeAddr, "emerald")
	waitForPlayerID(t, c)

	if got := c.PlayerID(); got == firstID {
		t.Errorf("the relaunched game came back as %q, the same identity as before", got)
	}
	if c.Resumed() {
		t.Error("Resumed() is true for a relaunched game -- it is a new player in the room")
	}
}

// TestARefusedSecondAdapterDoesNotDiscardTheResumeToken covers the last arm of
// the owner guard. The token clear sits inside the same `owns` branch as the
// auto-retry disarm and the relay close that
// TestMismatchedSecondAdapterDoesNotKillFirstAdaptersRelaySession already
// protects: a connection that never became the adapter must take nothing with
// it when it is refused.
func TestARefusedSecondAdapterDoesNotDiscardTheResumeToken(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.ResumeGrace = 30 * time.Second
	relayAddr := startRelayWith(t, s)

	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.Features = []string{protocol.FeatureResumeV1}
	})
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	waitForPlayerID(t, c)

	firstID := c.PlayerID()
	token := resumeTokenOf(c)
	if token == "" {
		t.Fatal("setup: no resume token was issued")
	}

	// A second adapter for a different game: refused, and its connection then
	// closes -- but it never owned anything.
	intruder := dialFakeAdapter(t, bridgeAddr)
	intruder.hello("tevi")
	intruder.awaitReject()
	time.Sleep(50 * time.Millisecond)

	if got := resumeTokenOf(c); got != token {
		t.Errorf("a refused adapter's disconnect changed the resume token (%q -> %q)", token, got)
	}
	if got := c.PlayerID(); got != firstID {
		t.Errorf("a refused adapter's disconnect changed the player id (%q -> %q)", firstID, got)
	}
}

// TestAPeersGhostSurvivesOurOwnReconnect is the point of the whole feature,
// asserted the way a player would notice it: nothing in here reads a private
// field.
//
// Without resumption a reconnecting client comes back under a new id, so every
// peer despawns the old ghost and spawns a stranger. With it, the peer sees
// nothing at all -- which is the assertion, and it is a negative one, so the
// test keeps the peer's adapter ticking throughout to give a despawn every
// chance to arrive.
func TestAPeersGhostSurvivesOurOwnReconnect(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.ResumeGrace = 30 * time.Second
	relayAddr := startRelayWith(t, s)

	alice := startResumingCore(t, relayAddr, "room1", "alice")
	aliceID := alice.PlayerID()
	if aliceID == "" || resumeTokenOf(alice) == "" {
		t.Fatal("setup: alice has no resumable session")
	}

	bob, bobBridge := startCore(t, relayAddr, "emerald", "room1", "bob")
	bobAdapter := dialFakeAdapter(t, bobBridge)
	waitForPlayerID(t, bob)

	// Alice has no adapter of her own; her state goes straight through the
	// core, re-sent inside every wait loop for the usual reason.
	aliceState := protocol.State{AreaID: "zone-a", Position: []float64{5, 5}, Anim: "idle"}
	bobState := protocol.State{AreaID: "zone-a", Position: []float64{0, 0}, Anim: "idle"}

	deadline := time.Now().Add(testTimeout)
	seen := false
	for time.Now().Before(deadline) && !seen {
		alice.forwardLocalState(&aliceState)
		bobAdapter.frame(&bobState)
		_, seen = bobAdapter.rendersOf(aliceID)
		time.Sleep(10 * time.Millisecond)
	}
	if !seen {
		t.Fatal("setup: bob never rendered alice, so a despawn would prove nothing")
	}

	// Drain anything already queued, so the assertion below is about what
	// happens from here on.
	for drained := false; !drained; {
		select {
		case <-bobAdapter.despawns:
		default:
			drained = true
		}
	}

	alice.mu.Lock()
	conn := alice.relay
	alice.mu.Unlock()
	if err := conn.Close(); err != nil {
		t.Fatalf("close alice's relay connection: %v", err)
	}
	waitForRelayGone(t, alice)
	if err := alice.ConnectRelay("emerald"); err != nil {
		t.Fatalf("alice reconnect: %v", err)
	}
	if got := alice.PlayerID(); got != aliceID {
		t.Fatalf("alice came back as %q, not %q -- she did not resume, so this test cannot say "+
			"anything about what bob saw", got, aliceID)
	}

	// Keep bob ticking well past the round trip: a despawn is decided on his
	// own next frame, so it needs frames to arrive on.
	until := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(until) {
		alice.forwardLocalState(&aliceState)
		bobAdapter.frame(&bobState)
		select {
		case id := <-bobAdapter.despawns:
			if id == aliceID {
				t.Fatalf("bob despawned alice's ghost across her reconnect -- resumption exists " +
					"precisely so a brief drop is invisible to the rest of the room")
			}
		default:
		}
		time.Sleep(10 * time.Millisecond)
	}

	if _, ok := bobAdapter.rendersOf(aliceID); !ok {
		t.Error("alice is no longer rendered for bob after her reconnect")
	}
}
