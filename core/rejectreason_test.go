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

// TestARelayThatIsMerelyDownDoesNotRejectTheAdapter: with nothing listening, the hello is accepted and the game plays
// solo while the relay is retried in the background. A refusal per hello would cool port after port in an adapter's
// port walk, and recording and replays need no relay at all.
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

// TestAPermanentRelayRefusalStillSaysRelay: a refusal retrying cannot fix (a wrong room code, a version mismatch) still
// names the relay, since all four adapters match the substring "relay" to wait on this core rather than walk to the
// next port. It asserts only that the word appears, case-insensitively: the message stays readable and improvable.
func TestAPermanentRelayRefusalStillSaysRelay(t *testing.T) {
	c := &Core{RelayAddr: deadAddr(t), DialTimeout: 500 * time.Millisecond}
	// A permanent refusal this core already knows, as a second hello for the same game hits; it needs no relay, which
	// keeps this test about the message.
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

// deadAddr is a port nothing listens on: bind one, learn its number, release it, rather than assume a hardcoded port is
// free.
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

// TestASoloSessionUpgradesWhenARelayAppears: a solo session joins once a relay turns up, with the game doing nothing,
// so solo is never a resting state. A solo core has no player id, so no test waiting for one passes without a relay.
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

	// A solo core has no identity, which keeps waitForPlayerID and everything built on it honest.
	if id := c.PlayerID(); id != "" {
		t.Fatalf("a core that never reached a relay reported player id %q -- a solo session must "+
			"not look like a joined one to anything that checks", id)
	}

	// The host starts the server.
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	relayLn := listenTLSOn(t, addr)
	defer relayLn.Close()
	go s.Serve(relayLn)

	waitForPlayerID(t, c)
}

// TestASessionFlapsBetweenSoloAndJoinedAndTheRecordingSurvivesIt: solo, joined, solo, joined, driven only by the server
// coming and going with the game attached throughout, and a recording spanning it all is one clip with no gap playback
// would treat as a seam, since the recorder taps the local frame before the relay is consulted.
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
		ln := listenTLSOn(t, addr)
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

	// The recording is one clip, and the flapping is invisible in it.
	clip, err := loadReplay(path, true)
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
