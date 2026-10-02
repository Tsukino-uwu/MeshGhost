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

// TestADeadAdapterSocketFreesTheCoreForTheReconnect: when a render write to an adapter that stopped reading times
// out and the core closes the socket, the game's immediate reconnect is accepted, not refused "busy" while the read
// loop is still inside the failing frame.
func TestADeadAdapterSocketFreesTheCoreForTheReconnect(t *testing.T) {
	// The real clock: a fake one advanced from A's write loop can stamp every sample with the same time on one CPU,
	// so nothing moves, nothing renders and no write fails.
	c := New()
	c.InterpolationDelay = 0
	c.LocalInterpolationDelay = 0
	c.bridgeWriteTimeout = 300 * time.Millisecond
	// Big enough that the tick after the failure would spend its time failing hundreds more sends.
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
	// 4 KB buffers on both ends of A's connection, which also turns off Linux autotuning: left to the kernel, megabytes
	// must fill before the write deadline can fire.
	go c.ServeBridge(smallWriteBufferListener{ln})

	// A raw socket, so the test controls when it reads.
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

	// A now sends frames and never reads again; the player moves, so every tick writes 512 render lines.
	aDead := make(chan error, 1)
	go func() {
		for i := 0; ; i++ {
			st := protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"}
			payload, _ := json.Marshal(bridge.LocalState{State: &st})
			env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
			// Only a non-timeout error means the core closed this socket: A's own deadline can fire first while the
			// core is still healthy, so a timeout keeps pushing from the bytes already written.
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

	// Watch the core, not only A: how A's kernel reports the close varies, and "closed but still attached" is the
	// window the reconnect must be accepted in. A's error is a second signal.
	deadline := time.After(20 * time.Second)
	poll := time.NewTicker(5 * time.Millisecond)
	defer poll.Stop()
wait:
	for {
		select {
		case err := <-aDead:
			t.Logf("A's write failed: %v", err)
			break wait
		case <-poll.C:
			c.mu.Lock()
			incumbent := c.attachedAdapter
			c.mu.Unlock()
			if incumbent == nil || transportIsClosed(incumbent) {
				t.Logf("the core closed A's socket (still attached: %v)", incumbent != nil)
				break wait
			}
		case <-deadline:
			t.Fatal("the core never gave up writing to an adapter that stopped reading")
		}
	}

	// B reconnects at once, the way the game does.
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

// smallWriteBufferListener shrinks the send buffer of every accepted connection, so a peer that stops reading makes
// the core's write fail after kilobytes rather than megabytes.
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
