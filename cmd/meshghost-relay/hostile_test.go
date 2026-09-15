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

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
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
	identity, fingerprint, err := tlsx.ServerConfig(netx.TLSALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	listeners, err := buildListeners(listenerConfig{
		kinds:      []netx.Kind{netx.TCP},
		addr:       "127.0.0.1:0",
		identity:   identity,
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
	srv.PakeIdentity = fingerprint // as main wires it: the proof binds to the served certificate
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
	env, _ := readEnvelopeLine(t, c)
	return env
}

// readEnvelopeLine is readEnvelope keeping the raw line as well, for a
// caller that hands it to a paketest.Prover.
func readEnvelopeLine(t *testing.T, c net.Conn) (protocol.Envelope, []byte) {
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
	return env, line
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

// helloFor is a well-formed hello for room r. The code is proven, not
// carried (ADR 0067): sendHelloWithCode runs the proof.
func helloFor() protocol.Hello {
	return protocol.Hello{
		GameID:      "game-a",
		Room:        "room-1",
		DisplayName: "stranger",
	}
}

// withKE1 is helloFor plus the proof's first message, for a test that expects
// the relay to refuse BEFORE answering it (a blocked source).
func withKE1(t *testing.T, hello protocol.Hello, code, identity string) protocol.Hello {
	t.Helper()
	hello.PakeKE1 = paketest.New(t, code, identity).KE1()
	return hello
}

// sendHelloWithCode sends hello proving code against the stack's identity
// and answers the relay's KE2 from the same socket, so the next line the
// test reads is the relay's verdict -- a Welcome, a Reject, or whatever the
// test is about. A wrong code sends an unusable KE3 (internal/paketest).
func sendHelloWithCode(t *testing.T, c net.Conn, hello protocol.Hello, code, identity string) {
	t.Helper()
	prover := paketest.New(t, code, identity)
	hello.PakeKE1 = prover.KE1()
	sendHello(t, c, hello)
	if prover == nil {
		return
	}
	_ = c.SetReadDeadline(time.Now().Add(hostileDialTimeout))
	br := bufio.NewReader(c)
	line, err := br.ReadBytes('\n')
	if err != nil {
		t.Fatalf("reading the relay's answer to the proof: %v", err)
	}
	if !prover.Handle(line, func(out []byte) error { _, err := c.Write(append(out, '\n')); return err }) {
		// Not a KE2: the relay refused (or welcomed) without the proof. Put
		// the line back for the caller by failing loudly instead -- every
		// caller here expects the proof to run when a code is configured.
		t.Fatalf("the relay answered %q instead of the proof's KE2", string(line))
	}
	if n := br.Buffered(); n > 0 {
		t.Fatalf("%d byte(s) arrived behind the KE2 before the KE3 was sent", n)
	}
}

// TestShippedStackRejectsAWrongRoomCode is the harness's own proof: through
// every wrapper, a wrong code gets the same legible Reject a raw listener
// gives -- over TLS, which since 2026-09-15 is the only way to reach the
// relay at all. The plaintext row is the other half of that: a plaintext
// hello, wrong code or right, never reaches the relay and gets no Reject,
// only a close at the sniff.
func TestShippedStackRejectsAWrongRoomCode(t *testing.T) {
	captureLog(t)
	addr, srv := startShippedStack(t, stackOpts{roomCode: "right"})
	t.Run("tls", func(t *testing.T) {
		c := dialTLS(t, addr)
		sendHelloWithCode(t, c, helloFor(), "wrong", srv.PakeIdentity)
		rej := readReject(t, c)
		if rej.Code != protocol.CodeInvalidRoomCode {
			t.Fatalf("reject code %q (%q), want %q", rej.Code, rej.Reason, protocol.CodeInvalidRoomCode)
		}
		expectClosed(t, c, hostileDialTimeout)
	})
	t.Run("plaintext is refused before the code is even read", func(t *testing.T) {
		c := dialRaw(t, addr)
		// The RIGHT code, on purpose: the refusal is about the missing
		// handshake, not the code, and a plaintext client with the right
		// code is exactly the stale build the sniff exists to turn away.
		env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := c.Write(append(env, '\n')); err != nil {
			return // closed already
		}
		_ = c.SetReadDeadline(time.Now().Add(hostileDialTimeout))
		if n, err := c.Read(make([]byte, 1)); err == nil || n > 0 {
			t.Fatalf("the relay answered a plaintext hello with %d byte(s); it must close without a word", n)
		}
	})
}

// TestShippedStackClosesASilentConnectionAtTheHelloTimeout: a socket that
// never says hello is dropped when the relay's hello timer fires.
//
// The shipped stack has two timers in front of a stranger: the TLS sniff
// holds a byte-less socket for ITS timeout first (tlsx's HandshakeTimeout,
// 10 s, not configurable through netx.TLSOptions), and only a connection
// that completed a handshake is handed to the relay, where the hello timer
// starts. Since 2026-09-15 a plaintext first byte is refused at the sniff,
// so the cheapest way a stranger reaches the relay's timer is a completed
// handshake followed by silence -- which is what this test does. The two
// timers used to add up (the pass-3 P1b remainder); since later the same
// day the relay's timer counts from the moment the socket was ACCEPTED
// (tlsx.servedConn.AcceptedAt, relay.TestTheHelloTimeoutCountsFromAccept),
// so a stranger is held for one window, not two. This test asserts the
// relay's half on the shipped stack.
func TestShippedStackClosesASilentConnectionAtTheHelloTimeout(t *testing.T) {
	captureLog(t)
	const hold = 300 * time.Millisecond
	addr, _ := startShippedStack(t, stackOpts{helloTimeout: hold})
	c := dialTLS(t, addr)
	started := time.Now()
	expectClosed(t, c, 10*hold)
	if waited := time.Since(started); waited < hold/2 {
		t.Fatalf("closed after %s, before the %s hello timeout could have fired", waited, hold)
	}
}

// TestShippedStackRefusesAPlaintextClient: a client from before TLS, or a
// hand tool, is closed at the sniff and never reaches the relay -- so the
// hello timer is not even what closes it.
func TestShippedStackRefusesAPlaintextClient(t *testing.T) {
	captureLog(t)
	addr, _ := startShippedStack(t, stackOpts{helloTimeout: time.Minute})
	c := dialRaw(t, addr)
	if _, err := c.Write([]byte("{\"type\":\"hello\"}\n")); err != nil {
		return // refused before the write landed
	}
	expectClosed(t, c, 5*time.Second)
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
	addr, _ := startShippedStack(t, stackOpts{maxClients: seats, helloTimeout: time.Minute})

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
	addr, srv := startShippedStack(t, stackOpts{roomCode: "right-code"})
	// The budget refills one whole token per second (RoomCodeAttemptsPerSecond),
	// and every guess here costs a real OPAQUE exchange -- under the race
	// detector on CI's runner the burst alone took 1.5 s, one token came back
	// mid-burst, and the guess after the burst was answered with a KE2 instead
	// of the rate-limit Reject (2026-09-15, three of three runs). So: guess
	// until the relay blocks, allowing exactly the refill the wall clock
	// permits, and fail if it blocks EARLY or never blocks at all.
	rateLimited := protocol.CodeForReason(protocol.ReasonRateLimited)
	started := time.Now()
	guesses := 0
	for {
		c := dialTLS(t, addr)
		prover := paketest.New(t, "wrong", srv.PakeIdentity)
		hello := helloFor()
		hello.PakeKE1 = prover.KE1()
		sendHello(t, c, hello)
		env, line := readEnvelopeLine(t, c)
		guesses++
		if env.Type == protocol.TypePake {
			// Not blocked yet: finish the proof so the relay charges it.
			_ = prover.Handle(line, func(out []byte) error { _, err := c.Write(append(out, '\n')); return err })
			if rej := readReject(t, c); rej.Code != protocol.CodeInvalidRoomCode {
				t.Fatalf("guess %d: code %q, want %q", guesses, rej.Code, protocol.CodeInvalidRoomCode)
			}
			_ = c.Close()
			refilled := int(time.Since(started) / time.Second)
			if guesses > relay.RoomCodeAttemptBurst+refilled+1 {
				t.Fatalf("%d wrong codes in %s and the source is still not rate limited (burst %d, refill %v/s)",
					guesses, time.Since(started), relay.RoomCodeAttemptBurst, relay.RoomCodeAttemptsPerSecond)
			}
			continue
		}
		if env.Type != protocol.TypeReject {
			t.Fatalf("guess %d: got a %q, want a pake or a reject", guesses, env.Type)
		}
		var rej protocol.Reject
		if err := json.Unmarshal(env.Payload, &rej); err != nil {
			t.Fatalf("unmarshal reject: %v", err)
		}
		if rej.Code != rateLimited {
			t.Fatalf("guess %d: reject %q (%q), want rate limited", guesses, rej.Code, rej.Reason)
		}
		_ = c.Close()
		if guesses <= relay.RoomCodeAttemptBurst {
			t.Fatalf("rate limited on guess %d, before the burst of %d was spent", guesses, relay.RoomCodeAttemptBurst)
		}
		break
	}
	// The budget is spent: the right code from the same address is refused
	// as rate limited, and so is another wrong one.
	for _, code := range []string{"right-code", "wrong"} {
		c := dialTLS(t, addr)
		// Blocked before the proof: the hello with KE1 gets the Reject at once.
		sendHello(t, c, withKE1(t, helloFor(), code, srv.PakeIdentity))
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
