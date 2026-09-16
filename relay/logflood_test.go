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
		// A proof that is not one, which is what a flooder sends: refused at
		// once, no key exchange on either side, so fifty of them land inside
		// one throttle window whatever the machine is doing.
		c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r", PakeKE1: "bm90IGEga2Ux"})
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

// addrFailingTransport fails every write with the *net.OpError a real socket
// returns, which prints the peer's address.
type addrFailingTransport struct{ transport.Transport }

func (addrFailingTransport) Send([]byte) error {
	return &net.OpError{Op: "write", Net: "tcp",
		Addr: &net.TCPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 51234},
		Err:  errors.New("connection reset by peer")}
}

// TestAFailedPreAdmissionSendLogsAtMostOnceASecond is pass 5's P1b-1: a
// stranger's refused hello followed by a stream reset makes the Reject's
// write fail, and sendEnvelope printed one line per connection with no
// throttle -- the A4 flood through the one line it missed. And the line
// carried the peer's address, which the relay's log never does.
func TestAFailedPreAdmissionSendLogsAtMostOnceASecond(t *testing.T) {
	logs := captureRelayLog(t)
	const attempts = 200
	for i := 0; i < attempts; i++ {
		sendEnvelope(addrFailingTransport{}, protocol.TypeReject, protocol.Reject{Reason: "no"})
	}
	if n := logs.count("failed"); n > 2 {
		t.Fatalf("%d send-failure lines for %d failed sends; want at most 2 (one per second)", n, attempts)
	}
	if logs.count("203.0.113.7") != 0 {
		t.Fatal("the send-failure line printed the peer's address")
	}
}

// notWrittenErr is a refusal that put nothing on the wire.
type notWrittenErr struct{}

func (notWrittenErr) Error() string    { return "datagram too large" }
func (notWrittenErr) NotWritten() bool { return true }

// refusesFirstUnreliable refuses its first unreliable line before writing
// and delivers everything else.
type refusesFirstUnreliable struct {
	transport.Transport
	mu        sync.Mutex
	refused   bool
	delivered []string
}

func (r *refusesFirstUnreliable) Send(p []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.delivered = append(r.delivered, string(p))
	return nil
}

func (r *refusesFirstUnreliable) SendUnreliable(p []byte) error {
	r.mu.Lock()
	if !r.refused {
		r.refused = true
		r.mu.Unlock()
		return notWrittenErr{}
	}
	r.mu.Unlock()
	return r.Send(p)
}

// TestARefusedLineDoesNotEndTheOutbox is pass 5's PM-1: one line the
// connection refused before writing -- a state too large for a quic
// datagram -- ended the member's writer, and every join, leave and state
// owed to it after that was silently discarded while its pongs kept it
// looking alive.
func TestARefusedLineDoesNotEndTheOutbox(t *testing.T) {
	captureRelayLog(t)
	rt := &refusesFirstUnreliable{}
	o := newOutbox("p7", rt)
	o.enqueue(outMsg{line: []byte("big-state"), unreliable: true})
	o.enqueue(outMsg{line: []byte("join")})
	o.enqueue(outMsg{line: []byte("state"), unreliable: true})
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		rt.mu.Lock()
		n := len(rt.delivered)
		rt.mu.Unlock()
		if n == 2 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	t.Fatalf("delivered %q after one refused line; want the join and the next state", rt.delivered)
}
