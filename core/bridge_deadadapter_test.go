package core

import (
	"bufio"
	"encoding/json"
	"errors"
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
	// THE REAL CLOCK, not newFakeClock. This test used to advance a fake clock
	// 5 ms per frame from A's write loop, and that coupling is what made it
	// hang on one CPU (CI's -race job, 2026-09-08, the third red run): with
	// 512 chaser goroutines woken per sample, the scheduler alternated between
	// "A runs and advances the clock" and "the core drains A's buffered
	// frames", so every sample the core stamped carried the SAME gameplay
	// time, the chasers never saw their 1 ms of movement, nothing was ever
	// rendered, no write ever failed, and the 20 s guard fired. Real time
	// stamps each frame as the core reads it, so movement is always visible
	// however the goroutines interleave. Verified with `-cpu 1` on both
	// sides: hangs on the fake clock, passes on the real one.
	c := New()
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
	// TINY SOCKET BUFFERS, on both ends of A's connection. The property under
	// test is "a write that fails frees the slot"; it says nothing about how
	// many bytes it takes to make one fail. Left to the kernel, that is
	// several megabytes of send buffer plus receive buffer, autotuned upward
	// on Linux, and the core has to push all of it -- 512 render lines per
	// frame -- before its 300 ms deadline can fire. Under -race on a loaded
	// CI runner (2026-09-08, the second red run on this test) it managed
	// under that in 20 s, and the guard below fired instead. A fixed 4 KB
	// each way, which also switches autotuning off, means the FIRST frame's
	// batch is already more than the socket can hold.
	go c.ServeBridge(smallWriteBufferListener{ln})

	// Adapter A: a raw socket, so the test controls when it reads.
	a, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial A: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	if tcp, ok := a.(*net.TCPConn); ok {
		_ = tcp.SetReadBuffer(4096)
	}
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

	// A now sends frames and never reads again. Every frame moves the player,
	// so the whole pack is admitted and every tick writes 512 render lines
	// into a socket nobody drains.
	aDead := make(chan error, 1)
	go func() {
		for i := 0; ; i++ {
			st := protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"}
			payload, _ := json.Marshal(bridge.LocalState{State: &st})
			env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
			// Only a NON-timeout error means the core closed this socket.
			// A's own deadline can expire first: under -race on a loaded
			// CI runner (2026-09-08) the core's reader fell behind this
			// loop, A's send buffer filled, and A's 2 s deadline fired
			// while the core was still healthy and had not yet filled A's
			// receive buffer -- so B's hello met a live incumbent and was
			// refused "busy", correctly, and the test failed on a premise
			// it never reached. A timeout here is "keep pushing", carrying
			// on from the bytes already written so the line stays whole;
			// the 20 s guard below still catches a core that never gives up.
			line := append(env, '\n')
			for len(line) > 0 {
				_ = a.SetWriteDeadline(time.Now().Add(2 * time.Second))
				n, err := a.Write(line)
				line = line[n:]
				if err != nil {
					var ne net.Error
					if errors.As(err, &ne) && ne.Timeout() {
						continue
					}
					aDead <- err
					return
				}
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

// smallWriteBufferListener shrinks the send buffer of every connection the
// core accepts, so a peer that stops reading makes the core's write fail
// after a few kilobytes rather than a few megabytes. See the note at its use.
type smallWriteBufferListener struct{ net.Listener }

func (l smallWriteBufferListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	if tcp, ok := conn.(*net.TCPConn); ok {
		_ = tcp.SetWriteBuffer(4096)
	}
	return conn, nil
}
