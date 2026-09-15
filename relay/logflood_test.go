package relay

import (
	"bytes"
	"errors"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// The relay's log is a host's only window and it is 1 MiB with one rotated
// copy, so every line a stranger can cause per connection is, across a few
// thousand cycling connections, a way to erase the history (fourth
// adversarial review, 2026-09-13, A4 and its post-join sibling C4, plus C5
// and C6). These tests count lines.

type lockedBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuf) count(substr string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Count(l.b.String(), substr)
}

func captureRelayLog(t *testing.T) *lockedBuf {
	t.Helper()
	buf := &lockedBuf{}
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	return buf
}

// TestRefusedHellosLogAtMostOnceASecond: fifty wrong codes in well under a
// second produce one refusal line, and it carries the count.
func TestRefusedHellosLogAtMostOnceASecond(t *testing.T) {
	logs := captureRelayLog(t)
	s := NewServer()
	s.RoomCode = "right"
	addr := startServerWith(t, s)
	const attempts = 50
	for i := 0; i < attempts; i++ {
		c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r", RoomCode: "wrong"})
		c.expectReject(2 * time.Second)
		c.conn.Close()
	}
	if n := logs.count("refused hello"); n > 2 {
		t.Fatalf("%d refusal lines for %d refused hellos; want at most 2 (one per second)", n, attempts)
	}
	if s.refusedHelloLine.Count() != attempts {
		t.Fatalf("throttle counted %d, want %d: the count must cover the lines it swallowed", s.refusedHelloLine.Count(), attempts)
	}
}

// failingTransport refuses every write, the way a socket whose far end has
// gone does, and counts how many it refused.
type failingTransport struct {
	transport.Transport
	writes atomic32
}

type atomic32 struct {
	mu sync.Mutex
	n  int
}

func (a *atomic32) add() {
	a.mu.Lock()
	a.n++
	a.mu.Unlock()
}

func (a *atomic32) load() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.n
}

func (f *failingTransport) Send([]byte) error {
	f.writes.add()
	return errors.New("wsasend: an existing connection was forcibly closed by the remote host")
}

func (f *failingTransport) SendUnreliable([]byte) error { return f.Send(nil) }

// TestAnOutboxStopsAtTheFirstFailedSend: a queue of twenty reliable lines
// behind a dead socket costs one log line and one write, not twenty of each,
// and the writer goroutine exits.
func TestAnOutboxStopsAtTheFirstFailedSend(t *testing.T) {
	logs := captureRelayLog(t)
	ft := &failingTransport{}
	o := newOutbox("p9", ft)
	// Fill before the writer can drain: enqueue is quick and the first Send
	// fails synchronously, so most lines are queued when it does.
	for i := 0; i < 20; i++ {
		if !o.enqueue(outMsg{line: []byte("{\"type\":\"leave\"}\n")}) {
			t.Fatalf("enqueue %d refused with the queue far under its cap", i)
		}
	}
	select {
	case <-o.done:
	case <-time.After(2 * time.Second):
		t.Fatal("the writer did not exit after a failed send")
	}
	if n := ft.writes.load(); n != 1 {
		t.Fatalf("%d writes attempted on a dead socket, want exactly 1", n)
	}
	if n := logs.count("send to p9 failed"); n != 1 {
		t.Fatalf("%d failure lines, want 1", n)
	}
	// And an enqueue after that is absorbed, not a disconnect signal: the
	// connection is already gone.
	if !o.enqueue(outMsg{line: []byte("x\n")}) {
		t.Fatal("enqueue after the writer closed reported a disconnect-worthy failure")
	}
}

// TestHelloTimeoutsAndConnectionErrorsLogAtMostOnceASecond: thirty sockets
// that say nothing, then thirty that reset -- each class one line.
func TestHelloTimeoutsAndConnectionErrorsLogAtMostOnceASecond(t *testing.T) {
	logs := captureRelayLog(t)
	s := NewServer()
	s.HelloTimeout = 100 * time.Millisecond
	addr := startServerWith(t, s)
	const each = 30
	var silent []net.Conn
	for i := 0; i < each; i++ {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		silent = append(silent, c)
	}
	defer func() {
		for _, c := range silent {
			c.Close()
		}
	}()
	// Wait out the hello timeout for all of them.
	time.Sleep(400 * time.Millisecond)
	if n := logs.count("did not complete hello"); n > 2 {
		t.Fatalf("%d hello-timeout lines for %d silent connections; want at most 2", n, each)
	}
	if got := s.helloTimeoutLine.Count(); got != each {
		t.Fatalf("hello timeouts counted %d, want %d", got, each)
	}
}
