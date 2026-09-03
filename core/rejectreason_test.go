package core

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// THE REJECT REASON IS A CONTRACT WITH FOUR ADAPTERS, AND NOTHING PINNED IT UNTIL NOW.
//
// REWRITTEN 2026-09-03, because the behaviour it pinned changed on purpose: a relay that is merely
// DOWN no longer refuses the adapter at all (bridgeserve.go -- the game attaches, plays solo, and
// the relay is retried in the background), so the first test below now asserts the opposite of
// what this file used to. What survives unchanged is the WORD contract for the refusals that are
// left, which the second test carries.
//
// The original note, still the reason the word matters: when a core refuses an adapter, the reason
// text is what all four shipped adapters branch on. All four shipped adapters branch on that text: each looks
// for the substring "relay" to tell "this core cannot reach the relay" apart from "this core
// already has a game", because the correct response to the two is opposite -- wait on the same
// core, versus walk to the next port.
//
// Getting that distinction wrong is not theoretical. Three of the four adapters lacked it until
// 2026-08-28 and the symptom reached a real user: with the relay down, each rejection cooled
// another port until the whole range was marked and the sweep reported "NO free port to start a
// core on". Crystal had the guard since 2026-08-19; the other three did not.
//
// So the WORD matters now. Reword core's dial error to "could not connect to the server" and all
// four adapters silently revert to the behaviour that broke that user's session -- with every
// other Go test still green, because nothing else looks at this string. This test is what makes
// that rewording fail loudly instead.
//
// It deliberately asserts the weakest useful thing: that the reason mentions the relay at all,
// case-insensitively. It is not a golden-string test and must not become one -- the message is
// meant to stay human-readable and improvable. What may not change is that it says "relay".
// TestARelayThatIsMerelyDownDoesNotRejectTheAdapter is the 2026-09-03 behaviour change, pinned
// from the adapter's side: with nothing listening, the hello is ACCEPTED and the game plays solo.
//
// It is the same defect the file's own history describes, cured at the source rather than worked
// around in four adapters: a refusal per hello is what cooled port after port until a real user's
// sweep reported "NO free port to start a core on". A core that accepts cannot start that
// cascade. It also unblocks the solo features Phase 11 added -- with the old refusal,
// record_on_launch with no relay running wrote nothing at all, which is how this was found.
func TestARelayThatIsMerelyDownDoesNotRejectTheAdapter(t *testing.T) {
	dead := deadAddr(t)
	c := &Core{RelayAddr: dead, DialTimeout: 500 * time.Millisecond}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the bridge: %v", err)
	}
	defer ln.Close()
	go c.ServeBridge(ln)

	fa := dialFakeAdapter(t, ln.Addr().String())
	fa.hello("anygame")

	select {
	case <-fa.ready:
	case reason := <-fa.rejects:
		t.Fatalf("a downed relay refused the adapter (%q). Since 2026-09-03 it must not: the game "+
			"attaches, plays alone, and the relay is retried in the background -- otherwise "+
			"recording and replays, which need no relay at all, cannot run either", reason)
	case <-time.After(testTimeout):
		t.Fatal("the adapter was neither accepted nor refused")
	}
}

// TestAPermanentRelayRefusalStillSaysRelay: the refusals that REMAIN keep the word. A wrong room
// code or a version mismatch is not something retrying fixes, so the adapter is still refused --
// and the reason must still identify the relay as the cause, because that is what tells an adapter
// to wait on this core rather than walk to the next port.
func TestAPermanentRelayRefusalStillSaysRelay(t *testing.T) {
	c := &Core{RelayAddr: deadAddr(t), DialTimeout: 500 * time.Millisecond}
	// A permanent refusal this core has already been told about, which is exactly what a second
	// hello for the same game hits -- and it needs no relay, which keeps this test about the
	// message rather than about a handshake.
	c.permanentRejectGame = "anygame"
	c.permanentRejectReason = "wrong room code"

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the bridge: %v", err)
	}
	defer ln.Close()
	go c.ServeBridge(ln)

	fa := dialFakeAdapter(t, ln.Addr().String())
	fa.hello("anygame")
	reason := fa.awaitReject()
	if !strings.Contains(strings.ToLower(reason), "relay") {
		t.Fatalf("a permanent relay refusal was reported to the adapter as %q, which does not "+
			"mention the relay. All four adapters match the substring \"relay\" in this reason to "+
			"tell a relay-caused refusal apart from a busy core, and they do OPPOSITE things in "+
			"the two cases. If this message is being reworded, update every adapter's reject "+
			"handling in the same commit -- see the 2026-08-28 entries in both BridgeClient files "+
			"and both Lua adapters.", reason)
	}
}

// deadAddr is a port nothing is listening on: bind one, learn its number, release it. Better than
// a hardcoded "surely nothing is here" port, which is exactly the assumption that makes a test
// flaky on somebody else's machine.
func deadAddr(t *testing.T) string {
	t.Helper()
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a port: %v", err)
	}
	addr := probe.Addr().String()
	if err := probe.Close(); err != nil {
		t.Fatalf("release the probe port: %v", err)
	}
	return addr
}

// TestASoloSessionUpgradesWhenARelayAppears is the other half of accepting an adapter with no
// relay, and it is the test that stops "solo" from becoming a silent resting state: the session
// must JOIN when a relay turns up, without the game doing anything.
//
// It also answers the question the user asked when this was built (2026-09-03) -- make sure
// nothing starts reading a solo session as success. Two things enforce that, and both are here:
// a solo core has no player id (so every test that waits for one still measures a real relay, and
// none of them can pass without one), and this test proves the solo state is temporary rather
// than terminal.
func TestASoloSessionUpgradesWhenARelayAppears(t *testing.T) {
	// A port reserved and released, then bound by a relay later -- the same shape as a player
	// starting the game before the host starts the server.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a port: %v", err)
	}
	addr := probe.Addr().String()
	probe.Close()

	c := New()
	c.RelayAddr = addr
	c.Room = "solo"
	c.DialTimeout = testTimeout
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the bridge: %v", err)
	}
	defer ln.Close()
	go c.ServeBridge(ln)

	fa := dialFakeAdapter(t, ln.Addr().String())
	fa.hello("anygame")
	fa.awaitReady() // accepted with no relay in existence

	// A SOLO CORE HAS NO IDENTITY. This is what keeps every other test honest: waitForPlayerID
	// and everything built on it still cannot pass without a relay having answered.
	if id := c.PlayerID(); id != "" {
		t.Fatalf("a core that never reached a relay reported player id %q -- a solo session must "+
			"not look like a joined one to anything that checks", id)
	}

	// The host starts the server.
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	relayLn, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("bind the relay on the reserved port: %v", err)
	}
	defer relayLn.Close()
	go s.Serve(relayLn)

	waitForPlayerID(t, c)
}

// TestASessionFlapsBetweenSoloAndJoinedAndTheRecordingSurvivesIt answers the two questions the
// user asked when solo sessions landed (2026-09-03): does it go BACK to solo when the server
// disappears, can it go back and forth, and what happens to a recording that is running across
// all of it.
//
// The answers this pins: solo -> joined -> solo -> joined, driven only by the server appearing and
// disappearing, with the game attached and none the wiser; and a recording that spans the whole
// thing is ONE continuous clip, because the recorder taps the local frame before anything about
// the relay is consulted (sending.go). The clip must have no gap big enough to be a playback seam
// (replayGapSeamMs), or a rejoin would show up as the ghost teleporting mid-replay.
func TestASessionFlapsBetweenSoloAndJoinedAndTheRecordingSurvivesIt(t *testing.T) {
	// One address, bound and unbound as the "server" comes and goes.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a port: %v", err)
	}
	addr := probe.Addr().String()
	probe.Close()

	c := New()
	c.RelayAddr = addr
	c.Room = "flap"
	c.DialTimeout = testTimeout
	// The retry cadence a player never notices and a test cannot wait out.
	c.ReconnectInitialBackoff = 5 * time.Millisecond
	c.ReconnectMaxBackoff = 20 * time.Millisecond
	c.ReplayDir = filepath.Join(t.TempDir(), "replay")
	c.MinSendInterval = time.Millisecond

	bridgeLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the bridge: %v", err)
	}
	defer bridgeLn.Close()
	go c.ServeBridge(bridgeLn)

	fa := dialFakeAdapter(t, bridgeLn.Addr().String())
	fa.hello("anygame")
	fa.awaitReady()

	path, err := c.StartRecording()
	if err != nil {
		t.Fatalf("StartRecording: %v", err)
	}

	x := 0.0
	// feed walks the player forward for d, which is what keeps the recording
	// running through every phase rather than only at the moments measured.
	feed := func(d time.Duration) {
		deadline := time.Now().Add(d)
		for time.Now().Before(deadline) {
			x++
			c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run"})
			time.Sleep(2 * time.Millisecond)
		}
	}
	awaitSolo := func(what string) {
		deadline := time.Now().Add(testTimeout)
		for time.Now().Before(deadline) {
			if c.PlayerID() == "" {
				return
			}
			x++
			c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run"})
			time.Sleep(2 * time.Millisecond)
		}
		t.Fatalf("%s: still holding a player id, so the core never returned to solo", what)
	}
	startRelayOn := func() net.Listener {
		s := relay.NewServer()
		s.SendHz = protocol.MaxSendHz
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			t.Fatalf("bind the relay: %v", err)
		}
		go s.Serve(ln)
		return ln
	}
	// killRelay takes the server away for real: the listener stops answering new
	// dials, and the live connection dies under the client the way a killed
	// server process would.
	killRelay := func(ln net.Listener) {
		ln.Close()
		c.mu.Lock()
		conn := c.relay
		c.mu.Unlock()
		if conn != nil {
			conn.Close()
		}
	}

	// Phase 1: solo. No relay has ever existed.
	feed(30 * time.Millisecond)
	if id := c.PlayerID(); id != "" {
		t.Fatalf("solo core reported player id %q", id)
	}

	// Phase 2: the host starts the server.
	ln1 := startRelayOn()
	waitForPlayerID(t, c)
	feed(30 * time.Millisecond)

	// Phase 3: the server goes away again.
	killRelay(ln1)
	awaitSolo("after the server was killed")
	feed(30 * time.Millisecond)

	// Phase 4: and comes back. This is the half that proves it is not one-way.
	ln2 := startRelayOn()
	defer ln2.Close()
	waitForPlayerID(t, c)
	feed(30 * time.Millisecond)

	if _, n, err := c.StopRecording(); err != nil || n == 0 {
		t.Fatalf("StopRecording = %d samples, %v", n, err)
	}

	// THE RECORDING IS ONE CLIP, and the flapping is invisible in it.
	clip, err := loadReplay(path)
	if err != nil {
		t.Fatalf("the recording made across the flap does not load: %v", err)
	}
	if len(clip.samples) < 20 {
		t.Fatalf("the clip holds %d samples, too few to have spanned four phases", len(clip.samples))
	}
	for i := 1; i < len(clip.samples); i++ {
		prev, cur := clip.samples[i-1], clip.samples[i]
		if cur.Timestamp < prev.Timestamp {
			t.Fatalf("sample %d went backwards in time (%d after %d) -- a rejoin must not rewind the clock a recording is stamped on",
				i, cur.Timestamp, prev.Timestamp)
		}
		if gap := cur.Timestamp - prev.Timestamp; gap >= replayGapSeamMs {
			t.Fatalf("sample %d sits %dms after the one before it, which playback treats as a SEAM (>= %dms) -- "+
				"joining or losing a relay must not punch a hole in a recording",
				i, gap, replayGapSeamMs)
		}
	}
	// The walk is continuous too: the last position must reflect every phase,
	// not just the ones where a relay happened to be up.
	if last := clip.samples[len(clip.samples)-1].Position[0]; last < 20 {
		t.Fatalf("the clip ends at x=%v, which is short of what four phases of walking wrote", last)
	}
}
