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

// The relay's log keeps 1 MiB and one rotated copy, so any line a stranger can cause per connection is, over a few
// thousand cycling connections, a way to erase it. These tests count lines.

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

// TestRefusedHellosLogAtMostOnceASecond: fifty wrong codes inside a second make one refusal line carrying the count.
func TestRefusedHellosLogAtMostOnceASecond(t *testing.T) {
	logs := captureRelayLog(t)
	s := NewServer()
	s.RoomCode = "right"
	addr := startServerWith(t, s)
	const attempts = 50
	for i := 0; i < attempts; i++ {
		// An unusable proof is refused with no key exchange, so all fifty land inside one throttle window.
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

// TestAnOutboxStopsAtTheFirstFailedSend: twenty reliable lines behind a dead socket cost one log line and one write,
// and the writer exits.
func TestAnOutboxStopsAtTheFirstFailedSend(t *testing.T) {
	logs := captureRelayLog(t)
	ft := &failingTransport{}
	o := newOutbox("p9", ft)
	// enqueue is quick and the first Send fails synchronously, so most lines are queued by then.
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
	// An enqueue after that is absorbed, not a disconnect signal: the connection is already gone.
	if !o.enqueue(outMsg{line: []byte("x\n")}) {
		t.Fatal("enqueue after the writer closed reported a disconnect-worthy failure")
	}
}

// TestHelloTimeoutsAndConnectionErrorsLogAtMostOnceASecond: thirty silent sockets make at most two hello-timeout
// lines, and the throttle counts all thirty.
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
	time.Sleep(400 * time.Millisecond)
	if n := logs.count("did not complete hello"); n > 2 {
		t.Fatalf("%d hello-timeout lines for %d silent connections; want at most 2", n, each)
	}
	if got := s.helloTimeoutLine.Count(); got != each {
		t.Fatalf("hello timeouts counted %d, want %d", got, each)
	}
}

// addrFailingTransport fails with the *net.OpError a real socket returns, which prints the peer's address.
type addrFailingTransport struct{ transport.Transport }

func (addrFailingTransport) Send([]byte) error {
	return &net.OpError{Op: "write", Net: "tcp",
		Addr: &net.TCPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 51234},
		Err:  errors.New("connection reset by peer")}
}

// TestAFailedPreAdmissionSendLogsAtMostOnceASecond: a Reject that fails on a reset stream is throttled like every
// other line a stranger can cause, and never prints the peer's address.
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

// TestARefusedLineDoesNotEndTheOutbox: a line refused before writing, such as a state too large for a quic datagram,
// must not end the writer, or every later line is lost while pongs keep the member looking alive.
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
