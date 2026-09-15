package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// This file is the hostile harness: a stranger's view of the SHIPPED relay.
//
// Every test in package relay listens raw (relay_test.go's startServerWith),
// so until 2026-09-15 nothing exercised the stack a real connection meets --
// netx.Listen, the open-connection limiter, the TLS sniff, connection
// tracking, then relay.Serve -- with input that is not cooperative. The three
// wrapper bugs netx/limit.go recounts all lived in those layers, and each
// shipped because the tests stopped one layer short. Fourth review, 2026-09-13,
// finding E1.
//
// The clients here speak the wire by hand (a raw socket, or stdlib tls.Client
// with verification off) rather than through transport or core, because the
// point is to send what a stranger can send, not what our client would.

// stackOpts configures one shipped stack for a test.
type stackOpts struct {
	roomCode     string
	maxClients   int
	helloTimeout time.Duration
	tls          tlsx.Mode // the relay's -tls; tlsx.Off is the zero value, so say Auto when you mean the default
	// sources overrides the per-address table; nil means the one main
	// builds for maxClients (newSourceTable), which is what ships.
	sources *srclimit.Table
}

// startShippedStack brings up a tcp listener exactly as main does
// (buildListeners) and serves it with a relay.Server configured from opts.
// Returns the dial address and the server, for tests that want to poke at
// its state. Closed on cleanup; the log is captured by captureLog first when
// a test wants to read it.
func startShippedStack(t *testing.T, opts stackOpts) (string, *relay.Server) {
	t.Helper()
	if opts.maxClients == 0 {
		opts.maxClients = relay.DefaultMaxClients
	}
	if opts.sources == nil {
		opts.sources = newSourceTable(opts.maxClients)
	}
	listeners, _, err := buildListeners(listenerConfig{
		kinds:      []netx.Kind{netx.TCP},
		addr:       "127.0.0.1:0",
		tls:        opts.tls,
		maxClients: opts.maxClients,
		sources:    opts.sources,
	})
	if err != nil {
		t.Fatalf("buildListeners: %v", err)
	}
	if len(listeners) != 1 {
		t.Fatalf("buildListeners returned %d listeners, want 1", len(listeners))
	}
	ln := listeners[0].ln
	t.Cleanup(func() { _ = ln.Close() })

	srv := relay.NewServer()
	srv.RoomCode = opts.roomCode
	srv.SourceGuard = opts.sources // as main wires it: one table for the listeners and the relay
	srv.MaxClients = opts.maxClients
	if opts.helloTimeout > 0 {
		srv.HelloTimeout = opts.helloTimeout
	}
	go func() { _ = srv.Serve(ln) }()
	return ln.Addr().String(), srv
}

// lockedBuffer is a bytes.Buffer safe to write from the relay's goroutines
// while a test reads it.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// captureLog routes the standard logger into a buffer for the test's life.
// The relay logs through the standard logger, and the standard logger is
// process-global, so tests using this must not run in parallel.
func captureLog(t *testing.T) *lockedBuffer {
	t.Helper()
	buf := &lockedBuffer{}
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	return buf
}

const hostileDialTimeout = 2 * time.Second

// dialRaw is a plaintext tcp connection to the relay: what netcat gets.
func dialRaw(t *testing.T, addr string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, hostileDialTimeout)
	if err != nil {
		t.Fatalf("dial %s: %v", addr, err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// dialTLS is a TLS connection that verifies nothing -- a stranger has no
// fingerprint, and the handshake is what is under test, not the identity.
func dialTLS(t *testing.T, addr string) net.Conn {
	t.Helper()
	raw := dialRaw(t, addr)
	tc := tls.Client(raw, &tls.Config{
		InsecureSkipVerify: true, // deliberate: see the doc comment
		NextProtos:         []string{netx.TLSALPN},
		MinVersion:         tls.VersionTLS13,
	})
	_ = tc.SetDeadline(time.Now().Add(hostileDialTimeout))
	if err := tc.Handshake(); err != nil {
		t.Fatalf("tls handshake with %s: %v", addr, err)
	}
	_ = tc.SetDeadline(time.Time{})
	return tc
}

// sendHello writes one hello line, filling the protocol version if the test
// left it zero.
func sendHello(t *testing.T, c net.Conn, hello protocol.Hello) {
	t.Helper()
	if hello.ProtocolVersion == 0 {
		hello.ProtocolVersion = protocol.Version
	}
	payload, err := json.Marshal(hello)
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	line, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	_ = c.SetWriteDeadline(time.Now().Add(hostileDialTimeout))
	if _, err := c.Write(append(line, '\n')); err != nil {
		t.Fatalf("write hello: %v", err)
	}
}

// readEnvelope reads one line and decodes it, failing on silence.
func readEnvelope(t *testing.T, c net.Conn) protocol.Envelope {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(hostileDialTimeout))
	line, err := bufio.NewReader(c).ReadBytes('\n')
	if err != nil {
		t.Fatalf("reading the relay's answer: %v", err)
	}
	var env protocol.Envelope
	if err := json.Unmarshal(line, &env); err != nil {
		t.Fatalf("the relay answered something that is not an envelope: %q", line)
	}
	return env
}

// readReject reads one line and requires it to be a Reject.
func readReject(t *testing.T, c net.Conn) protocol.Reject {
	t.Helper()
	env := readEnvelope(t, c)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got a %q, want a reject", env.Type)
	}
	var rej protocol.Reject
	if err := json.Unmarshal(env.Payload, &rej); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	return rej
}

// expectClosed fails unless the relay ends the connection within the window:
// a timeout means the relay is holding a socket it should have dropped.
func expectClosed(t *testing.T, c net.Conn, within time.Duration) {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(within))
	buf := make([]byte, 1)
	_, err := c.Read(buf)
	if err == nil {
		t.Fatal("read a byte; the relay should have closed the connection")
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		t.Fatalf("the relay kept the connection open for %s", within)
	}
	if err != io.EOF && !errors.Is(err, net.ErrClosed) {
		// A reset is also a close, just a rude one; only silence is the defect.
		t.Logf("connection ended with: %v", err)
	}
}

// helloFor is a well-formed hello for room r with the given code.
func helloFor(code string) protocol.Hello {
	return protocol.Hello{
		GameID:      "game-a",
		Room:        "room-1",
		DisplayName: "stranger",
		RoomCode:    code,
	}
}

// TestShippedStackRejectsAWrongRoomCode is the harness's own proof: through
// every wrapper, over plaintext and over TLS, a wrong code gets the same
// legible Reject a raw listener gives.
func TestShippedStackRejectsAWrongRoomCode(t *testing.T) {
	captureLog(t)
	addr, _ := startShippedStack(t, stackOpts{roomCode: "right", tls: tlsx.Auto})
	for _, tc := range []struct {
		name string
		dial func(*testing.T, string) net.Conn
	}{
		{"plaintext", dialRaw},
		{"tls", dialTLS},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := tc.dial(t, addr)
			sendHello(t, c, helloFor("wrong"))
			rej := readReject(t, c)
			if rej.Code != protocol.CodeInvalidRoomCode {
				t.Fatalf("reject code %q (%q), want %q", rej.Code, rej.Reason, protocol.CodeInvalidRoomCode)
			}
			expectClosed(t, c, hostileDialTimeout)
		})
	}
}

// TestShippedStackClosesASilentConnectionAtTheHelloTimeout: a socket that
// never says hello is dropped when the relay's hello timer fires.
//
// Two shapes, because the shipped default has two timers in front of a
// stranger. With tls off the socket reaches the relay directly and the hello
// timer is the only one. Under auto the TLS sniff holds a byte-less socket
// for ITS timeout first (tlsx's HandshakeTimeout, 10 s, not configurable
// through netx.TLSOptions), and only a connection that has sent its first
// byte is handed to the relay -- so the second case sends one byte and then
// falls silent, which is the cheapest way a stranger reaches the relay's
// timer. That the two timers add up is the pass-3 P1b remainder, recorded,
// not fixed here; this test asserts the relay's half.
func TestShippedStackClosesASilentConnectionAtTheHelloTimeout(t *testing.T) {
	captureLog(t)
	const hold = 300 * time.Millisecond
	for _, tc := range []struct {
		name  string
		mode  tlsx.Mode
		first []byte
	}{
		{"tls off, nothing sent", tlsx.Off, nil},
		{"tls auto, one byte then silence", tlsx.Auto, []byte("{")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			addr, _ := startShippedStack(t, stackOpts{helloTimeout: hold, tls: tc.mode})
			c := dialRaw(t, addr)
			started := time.Now()
			if len(tc.first) > 0 {
				if _, err := c.Write(tc.first); err != nil {
					t.Fatalf("write: %v", err)
				}
			}
			expectClosed(t, c, 10*hold)
			if waited := time.Since(started); waited < hold/2 {
				t.Fatalf("closed after %s, before the %s hello timeout could have fired", waited, hold)
			}
		})
	}
}

// TestShippedStackCapsOpenConnectionsFromOneSource is finding A5 through the
// stack that ships: one address holding idle sockets used to be able to take
// every one of the listener's 64 slots and refuse every real player with a
// bare close. Now it stops at its own share (relay.MaxOpenConnsPerSourceFor)
// while the listener still has room. The refusal is a close with no Reject,
// deliberately: the limiter sits below the protocol and cannot write one.
func TestShippedStackCapsOpenConnectionsFromOneSource(t *testing.T) {
	captureLog(t)
	const seats = 8
	perSource := relay.MaxOpenConnsPerSourceFor(seats)
	if perSource >= relay.MaxOpenConnsFor(seats) {
		t.Fatalf("per-source cap %d is not below the listener cap %d; the test would prove nothing",
			perSource, relay.MaxOpenConnsFor(seats))
	}
	addr, _ := startShippedStack(t, stackOpts{maxClients: seats, tls: tlsx.Auto, helloTimeout: time.Minute})

	// Hold the whole per-source allowance open and silent.
	held := make([]net.Conn, 0, perSource)
	for i := 0; i < perSource; i++ {
		held = append(held, dialRaw(t, addr))
	}
	// Let the accept loop take them all: a socket the OS accepted but the
	// limiter has not yet counted would let the next one slip through.
	time.Sleep(200 * time.Millisecond)

	// One more from the same address is closed at once.
	extra := dialRaw(t, addr)
	expectClosed(t, extra, hostileDialTimeout)

	// Release one and the address is admitted again; the socket stays open
	// past the window a refused one is closed in.
	_ = held[0].Close()
	time.Sleep(100 * time.Millisecond)
	again := dialRaw(t, addr)
	_ = again.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := again.Read(make([]byte, 1)); err == nil {
		t.Fatal("read a byte from a silent relay")
	} else if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
		t.Fatalf("the connection after a release was closed (%v); the freed slot was not given back", err)
	}
}

// TestShippedStackThrottlesRoomCodeGuessesFromOneSource is finding A3 through
// the shipped stack and the shipped table: one address gets
// relay.RoomCodeAttemptBurst wrong codes, and the next hello -- right or
// wrong -- is refused as rate limited before the code is compared.
func TestShippedStackThrottlesRoomCodeGuessesFromOneSource(t *testing.T) {
	captureLog(t)
	addr, _ := startShippedStack(t, stackOpts{roomCode: "right-code", tls: tlsx.Auto})
	for i := 0; i < relay.RoomCodeAttemptBurst; i++ {
		c := dialRaw(t, addr)
		sendHello(t, c, helloFor("wrong"))
		if rej := readReject(t, c); rej.Code != protocol.CodeInvalidRoomCode {
			t.Fatalf("guess %d: code %q, want %q", i+1, rej.Code, protocol.CodeInvalidRoomCode)
		}
		_ = c.Close()
	}
	// The budget is spent: the right code from the same address is refused
	// as rate limited, and so is another wrong one.
	for _, code := range []string{"right-code", "wrong"} {
		c := dialRaw(t, addr)
		sendHello(t, c, helloFor(code))
		rej := readReject(t, c)
		if rej.Code != protocol.CodeForReason(protocol.ReasonRateLimited) {
			t.Fatalf("after the burst, %q got code %q (%q), want rate limited", code, rej.Code, rej.Reason)
		}
		_ = c.Close()
	}
}

// TestAShortRoomCodeWarnsAtStartup holds the startup line to its word for
// the three cases a host can be in.
func TestAShortRoomCodeWarnsAtStartup(t *testing.T) {
	if got := roomCodeStartupNotice(""); !strings.Contains(got, "WARNING: no room code") {
		t.Fatalf("empty code: %q", got)
	}
	if got := roomCodeStartupNotice("abc"); !strings.Contains(got, "only 3 characters") {
		t.Fatalf("short code: %q", got)
	}
	if got := roomCodeStartupNotice("long-enough-code"); strings.Contains(got, "characters") || !strings.Contains(got, "enabled") {
		t.Fatalf("long code: %q", got)
	}
}
