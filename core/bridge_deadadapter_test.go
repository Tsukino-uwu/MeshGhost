package core

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A tester's 2026-09-06 session, 512 chasers at one per second: at 353 ghosts
// a render write to the game timed out, the core closed the socket, the game
// reconnected within 150 ms -- and was refused "busy" by the very core whose
// adapter had just died, because the cleanup that frees the slot ran only
// when the read loop noticed, and the read loop was still inside the frame
// that was failing 352 more sends. The mod walked to the next port and
// started a second core. This is that sequence with a 300 ms write deadline
// and an adapter that stops reading: the reconnect must be ACCEPTED.
func TestADeadAdapterSocketFreesTheCoreForTheReconnect(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.InterpolationDelay = 0
	c.LocalInterpolationDelay = 0
	c.bridgeWriteTimeout = 300 * time.Millisecond
	// A pack big enough that the tick after the failure would, without the
	// fix, spend its time failing hundreds more sends -- the window the real
	// reconnect landed in.
	c.ChaserEnabled = true
	c.ChaserCount = 512
	c.ChaserDelay = time.Millisecond
	c.ChaserSpacing = 0
	c.ChaserSpawnDelay = time.Millisecond
	rt := &recordingTransport{}
	c.mu.Lock()
	c.relay = rt
	c.playerID = "self"
	c.relayGame = "emerald"
	c.mu.Unlock()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)

	// Adapter A: a raw socket, so the test controls when it reads.
	a, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial A: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	hello, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeHello, Payload: json.RawMessage(`{"game_id":"emerald"}`)})
	if _, err := a.Write(append(hello, '\n')); err != nil {
		t.Fatalf("A hello: %v", err)
	}
	ar := bufio.NewReader(a)
	for {
		line, err := ar.ReadString('\n')
		if err != nil {
			t.Fatalf("A waiting for bridge_ready: %v", err)
		}
		if strings.Contains(line, `"bridge_ready"`) {
			break
		}
	}

	// A now sends frames and never reads again. Every frame advances the
	// clock and moves the player, so the whole pack is admitted and every tick
	// writes 512 render lines into a socket nobody drains.
	aDead := make(chan error, 1)
	go func() {
		for i := 0; ; i++ {
			clk.Advance(5 * time.Millisecond)
			st := protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"}
			payload, _ := json.Marshal(bridge.LocalState{State: &st})
			env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
			_ = a.SetWriteDeadline(time.Now().Add(2 * time.Second))
			if _, err := a.Write(append(env, '\n')); err != nil {
				aDead <- err
				return
			}
		}
	}()

	// The core's write deadline fires once A's receive buffer is full; the
	// core closes the socket and A's next write fails.
	select {
	case err := <-aDead:
		t.Logf("A's write failed: %v", err)
	case <-time.After(20 * time.Second):
		t.Fatal("the core never gave up writing to an adapter that stopped reading")
	}

	// Adapter B reconnects at once, the way the game does. Without the fix
	// this hello is refused "busy: this core already has a game attached".
	b := dialFakeAdapter(t, ln.Addr().String())
	b.hello("emerald")
	select {
	case <-b.ready:
	case reason := <-b.rejects:
		t.Fatalf("the reconnect was refused (%q); the core's adapter socket was already dead", reason)
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for the reconnect's bridge_ready")
	}
}
