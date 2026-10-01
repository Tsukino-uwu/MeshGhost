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

// The hostile harness: a stranger's view of the shipped relay, through the stack a real connection meets (netx.Listen,
// the open-connection limiter, the TLS sniff, connection tracking), which package relay's raw listeners skip. The
// clients speak the wire by hand, to send what a stranger can send rather than what our client would.

// stackOpts configures one shipped stack for a test.
type stackOpts struct {
	roomCode     string
	maxClients   int
	helloTimeout time.Duration
	// sources overrides the per-address table; nil means the one main builds for maxClients.
	sources *srclimit.Table
}

// startShippedStack brings up a tcp listener as main does and serves it with a relay.Server configured from opts,
// returning the dial address and the server. Closed on cleanup.
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

// lockedBuffer is a bytes.Buffer safe to write from the relay's goroutines while a test reads it.
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

// captureLog routes the standard logger into a buffer for the test's life. The logger is process-global, so tests
// using this must not run in parallel.
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

// dialTLS is a TLS connection that verifies nothing: a stranger has no fingerprint, and the handshake is under test,
// not the identity.
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

// sendHello writes one hello line, filling the protocol version if the test left it zero.
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

// readEnvelopeLine is readEnvelope keeping the raw line as well, for a caller that hands it to a paketest.Prover.
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

// expectClosed fails unless the relay ends the connection within the window: a timeout means the relay is holding a
// socket it should have dropped.
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

// helloFor is a well-formed hello for room-1. The code is proven, not carried: sendHelloWithCode runs the proof.
func helloFor() protocol.Hello {
	return protocol.Hello{
		GameID:      "game-a",
		Room:        "room-1",
		DisplayName: "stranger",
	}
}

// withKE1 is hello plus the proof's first message, for a test that expects the relay to refuse before answering it.
func withKE1(t *testing.T, hello protocol.Hello, code, identity string) protocol.Hello {
	t.Helper()
	hello.PakeKE1 = paketest.New(t, code, identity).KE1()
	return hello
}

// sendHelloWithCode sends hello proving code against the stack's identity and answers the relay's KE2, so the next
// line the test reads is the relay's verdict. A wrong code sends an unusable KE3.
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
		// Not a KE2: every caller here expects the proof to run when a code is configured.
		t.Fatalf("the relay answered %q instead of the proof's KE2", string(line))
	}
	if n := br.Buffered(); n > 0 {
		t.Fatalf("%d byte(s) arrived behind the KE2 before the KE3 was sent", n)
	}
}

// TestShippedStackRejectsAWrongRoomCode: through every wrapper, over TLS, a wrong code gets the same legible Reject a
// raw listener gives, while a plaintext hello, wrong code or right, gets only a close at the sniff.
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
		// A plaintext client with the right code is the stale build the sniff exists to turn away.
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

// TestShippedStackClosesASilentConnectionAtTheHelloTimeout: a stranger that completes the TLS handshake and then says
// nothing is dropped when the relay's hello timer fires. The sniff's own timeout comes first and is not configurable
// through netx.TLSOptions, so this asserts the relay's half.
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

// TestShippedStackRefusesAPlaintextClient: a client from before TLS, or a hand tool, is closed at the sniff and never
// reaches the relay's hello timer.
func TestShippedStackRefusesAPlaintextClient(t *testing.T) {
	captureLog(t)
	addr, _ := startShippedStack(t, stackOpts{helloTimeout: time.Minute})
	c := dialRaw(t, addr)
	if _, err := c.Write([]byte("{\"type\":\"hello\"}\n")); err != nil {
		return // refused before the write landed
	}
	expectClosed(t, c, 5*time.Second)
}

// TestShippedStackCapsOpenConnectionsFromOneSource: one address holding idle sockets stops at its own share
// (relay.MaxOpenConnsPerSourceFor) while the listener still has room. The refusal is a close with no Reject: the
// limiter sits below the protocol and cannot write one.
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
	// Let the accept loop take them all: one the OS accepted but the limiter has not counted would let the next in.
	time.Sleep(200 * time.Millisecond)

	// One more from the same address is closed at once.
	extra := dialRaw(t, addr)
	expectClosed(t, extra, hostileDialTimeout)

	// Release one and the address is admitted again: the socket stays open past the window a refused one closes in.
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

// TestShippedStackThrottlesRoomCodeGuessesFromOneSource: one address gets relay.RoomCodeAttemptBurst wrong codes,
// and the next hello, right or wrong, is refused as rate limited before the code is compared.
func TestShippedStackThrottlesRoomCodeGuessesFromOneSource(t *testing.T) {
	captureLog(t)
	addr, srv := startShippedStack(t, stackOpts{roomCode: "right-code"})
	// The budget refills a token a second and every guess costs a real OPAQUE exchange, so a slow run can earn a
	// token back mid-burst: guess until blocked, allowing the refill the clock permits, and fail if it blocks early
	// or never.
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
	// The budget is spent: the right code and another wrong one are both refused as rate limited.
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

// TestShippedStackCountsTheHelloTimeoutFromAccept: the handshake starts most of a window after accept, and the close
// must come at the end of the window that started at accept, which needs trackedConn to forward AcceptedAt.
func TestShippedStackCountsTheHelloTimeoutFromAccept(t *testing.T) {
	captureLog(t)
	const hold = time.Second
	const lateBy = 700 * time.Millisecond
	addr, _ := startShippedStack(t, stackOpts{helloTimeout: hold})
	raw := dialRaw(t, addr)
	time.Sleep(lateBy) // the sniff waits for a first byte; the socket is already accepted
	tc := tls.Client(raw, &tls.Config{
		InsecureSkipVerify: true, // a stranger verifies nothing; see dialTLS
		NextProtos:         []string{netx.TLSALPN},
		MinVersion:         tls.VersionTLS13,
	})
	_ = tc.SetDeadline(time.Now().Add(hostileDialTimeout))
	if err := tc.Handshake(); err != nil {
		t.Fatalf("tls handshake: %v", err)
	}
	_ = tc.SetDeadline(time.Time{})
	// From accept, hold-lateBy is left; from the handshake, a whole hold. Allow past the first, short of the second.
	expectClosed(t, tc, hold-lateBy+350*time.Millisecond)
}
