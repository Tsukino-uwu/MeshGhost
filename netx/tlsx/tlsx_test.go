package tlsx_test

import (
	"bufio"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

const testALPN = "meshghost"

const testTimeout = 5 * time.Second

// serve brings up a sniffing listener plus an echo-ish accept loop that
// reads one line per connection and reports it on the returned channel.
// Returns the address to dial and the fingerprint of the certificate it is
// using.
func serve(t *testing.T) (addr, fingerprint string, lines chan string) {
	t.Helper()

	cfg, fp, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	addr, lines = serveWith(t, cfg)
	return addr, fp, lines
}

// serveWith is serve for a caller that built the config itself (the
// identity tests).
func serveWith(t *testing.T, cfg *tls.Config) (addr string, lines chan string) {
	t.Helper()
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln, err := tlsx.NewListener(raw, tlsx.ListenConfig{
		TLS:              cfg,
		HandshakeTimeout: testTimeout,
		Logf:             func(string, ...any) {},
	})
	if err != nil {
		raw.Close()
		t.Fatalf("NewListener: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	lines = make(chan string, 4)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				// A whole line, via bufio, exactly as transport's own read
				// loop does it. Deliberately not a single Read: the sniffed
				// first byte is replayed as its own short read, which is
				// ordinary net.Conn behaviour and is why every real reader
				// in this project goes through a bufio.Scanner.
				_ = c.SetReadDeadline(time.Now().Add(testTimeout))
				line, err := bufio.NewReader(c).ReadString('\n')
				if line == "" && err != nil {
					return
				}
				select {
				case lines <- line:
				default:
				}
				_, _ = c.Write([]byte("ok\n"))
			}(c)
		}
	}()
	return ln.Addr().String(), lines
}

// dialTLS is a client handshake that accepts any certificate: what a test
// that is not about verification uses.
func dialTLS(t *testing.T, addr string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	secure, err := tlsx.Client(c, testALPN, tlsx.TrustAnyCertificate, testTimeout)
	if err != nil {
		t.Fatalf("handshake: %v", err)
	}
	return secure
}

// TestNewListenerNeedsAConfig: there is no mode that returns the listener
// untouched any more. A caller that forgot the identity gets an error, not
// a plaintext relay.
func TestNewListenerNeedsAConfig(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer raw.Close()
	if _, err := tlsx.NewListener(raw, tlsx.ListenConfig{}); err == nil {
		t.Fatal("NewListener without a TLS config returned a listener; it must refuse")
	}
}

// TestAPlaintextClientIsRefused is the anti-downgrade half: a relay must not
// hand a plaintext connection upward at all, however well-formed it is.
// Until 2026-09-15 this was the behaviour of tls=required only; now it is
// the only behaviour.
func TestAPlaintextClientIsRefused(t *testing.T) {
	addr, _, lines := serve(t)

	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	if _, err := c.Write([]byte("{\"room_code\":\"hunter2\"}\n")); err != nil {
		// A write can already fail if the close raced it; that is the
		// refusal too.
		return
	}
	select {
	case got := <-lines:
		t.Fatalf("a plaintext line %q reached the application", got)
	case <-time.After(500 * time.Millisecond):
	}

	// And the connection is actually closed, not merely ignored.
	_ = c.SetReadDeadline(time.Now().Add(testTimeout))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("the refused connection is still readable; it should have been closed")
	}
}

// TestATLSClientIsAccepted: refusing plaintext must not refuse everything,
// and the sniffed first byte must be replayed -- if it were eaten, the
// ClientHello would be missing its record header and every handshake would
// fail, so this test failing is also that test failing.
func TestATLSClientIsAccepted(t *testing.T) {
	addr, _, lines := serve(t)
	secure := dialTLS(t, addr)
	defer secure.Close()
	if _, err := secure.Write([]byte("{}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := <-lines; got != "{}\n" {
		t.Fatalf("got %q, want the line delivered byte for byte", got)
	}
}

// TestTheVerifierSeesTheRelaysLeafCertificate: what the verifier is handed
// is the DER of the certificate the listener serves, so a fingerprint
// computed from it equals the one ServerConfig returned.
func TestTheVerifierSeesTheRelaysLeafCertificate(t *testing.T) {
	addr, fp, _ := serve(t)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	var seen string
	secure, err := tlsx.Client(c, testALPN, func(leaf []byte) error {
		seen = tlsx.Fingerprint(leaf)
		return nil
	}, testTimeout)
	if err != nil {
		t.Fatalf("handshake: %v", err)
	}
	secure.Close()
	if seen != fp {
		t.Fatalf("the verifier saw fingerprint %q, the listener serves %q", seen, fp)
	}
}

// TestAVerifierErrorRefusesTheConnection: the verifier's error is the
// handshake's error, and nothing was sent past the handshake.
func TestAVerifierErrorRefusesTheConnection(t *testing.T) {
	addr, _, lines := serve(t)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	refused := errors.New("not the relay I meant")
	secure, err := tlsx.Client(c, testALPN, func([]byte) error { return refused }, testTimeout)
	if err == nil {
		secure.Close()
		t.Fatal("a handshake the verifier refused completed")
	}
	if !errors.Is(err, refused) {
		t.Fatalf("handshake error %v does not carry the verifier's reason", err)
	}
	select {
	case got := <-lines:
		t.Fatalf("a line %q reached the application through a refused handshake", got)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestANilVerifierIsAnErrorNotAnUncheckedHandshake: forgetting the verifier
// must not quietly become "trust anyone". The error comes before a byte is
// sent, and the socket is closed.
func TestANilVerifierIsAnErrorNotAnUncheckedHandshake(t *testing.T) {
	addr, _, _ := serve(t)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if secure, err := tlsx.Client(c, testALPN, nil, testTimeout); err == nil {
		secure.Close()
		t.Fatal("Client with a nil verifier handshaked; it must refuse")
	}
	if _, err := c.Write([]byte("x")); err == nil {
		t.Fatal("the socket is still open after the nil-verifier refusal")
	}
}

// TestALPNMismatchFails: the ALPN is what tells a MeshGhost relay apart
// from anything else that happens to be listening on the port, so a
// mismatch must break the handshake rather than produce a connection that
// fails confusingly later.
func TestALPNMismatchFails(t *testing.T) {
	addr, _, _ := serve(t)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if _, err := tlsx.Client(c, "something-else", tlsx.TrustAnyCertificate, testTimeout); err == nil {
		t.Fatal("a handshake with the wrong ALPN succeeded")
	}
}

// TestOneSilentClientDoesNotStallEveryoneElse: the sniff happens on a
// per-connection goroutine, not inside Accept. Done in Accept, a single
// client that connects and then says nothing would block every other client
// for the whole handshake timeout — a denial of service anyone can perform
// with netcat.
func TestOneSilentClientDoesNotStallEveryoneElse(t *testing.T) {
	addr, _, lines := serve(t)

	silent, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer silent.Close()

	talker := dialTLS(t, addr)
	defer talker.Close()
	if _, err := talker.Write([]byte("{\"second\":1}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case got := <-lines:
		if !strings.Contains(got, "second") {
			t.Fatalf("got %q, want the second client's line", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a silent client blocked a talking one; the sniff is happening inside Accept")
	}
}

func TestIsTLSDistinguishesTheTwo(t *testing.T) {
	if tlsx.IsTLS(nil) {
		t.Error("IsTLS(nil) says encrypted")
	}
	var plain net.Conn = &net.TCPConn{}
	if tlsx.IsTLS(plain) {
		t.Error("a plain TCP conn reported as TLS")
	}
	if !tlsx.IsTLS(tls.Client(plain, &tls.Config{InsecureSkipVerify: true})) {
		t.Error("a tls.Conn reported as plaintext")
	}
}

// TestClientClosesTheSocketOnAFailedHandshake: otherwise every refused
// connection leaks a socket and a file descriptor on the client, and the
// caller has nothing usable to close.
func TestClientClosesTheSocketOnAFailedHandshake(t *testing.T) {
	// A listener that accepts and immediately hangs up: no TLS server at
	// all, so the handshake cannot complete.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			c.Close()
		}
	}()

	c, err := net.DialTimeout("tcp", ln.Addr().String(), testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if _, err := tlsx.Client(c, testALPN, tlsx.TrustAnyCertificate, testTimeout); err == nil {
		t.Fatal("handshake against a hung-up listener succeeded")
	}
	if _, err := c.Write([]byte("x")); err == nil {
		if _, err := c.Read(make([]byte, 1)); err == nil {
			t.Fatal("the connection is still usable after a failed handshake; it should be closed")
		} else if !errors.Is(err, net.ErrClosed) && !errors.Is(err, io.EOF) {
			// A remote-closed read error is fine too — the point is that
			// it is not a working connection.
			_ = err
		}
	}
}

// TestAHandshakeThatNeverFinishesIsClosedAtTheTimeout is finding E3 of the
// fourth adversarial review: no test wrote 0x16 followed by garbage or by
// nothing, and none ever waited out the handshake timeout -- so a listener
// that held such a socket forever (and its open-connection slot with it)
// would have run green. This one waits it out, and asserts one throttled
// log line rather than one per failure.
func TestAHandshakeThatNeverFinishesIsClosedAtTheTimeout(t *testing.T) {
	cfg, _, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	const hold = 300 * time.Millisecond
	var logged atomic.Int32
	ln, err := tlsx.NewListener(raw, tlsx.ListenConfig{
		TLS:              cfg,
		HandshakeTimeout: hold,
		Logf:             func(string, ...any) { logged.Add(1) },
	})
	if err != nil {
		t.Fatalf("NewListener: %v", err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close() // nothing here should ever be handed up
		}
	}()

	for _, tc := range []struct {
		name  string
		bytes []byte
		// held: the listener has nothing to refuse until the timer fires (a
		// silent socket); false when Go's TLS server can reject the bytes as
		// soon as they arrive (a record that is not a ClientHello).
		held bool
	}{
		{"0x16 then garbage", append([]byte{0x16}, []byte("this is not a ClientHello, and never will be")...), false},
		{"0x16 then nothing", []byte{0x16}, true},
		{"nothing at all", nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := net.DialTimeout("tcp", raw.Addr().String(), testTimeout)
			if err != nil {
				t.Fatalf("dial: %v", err)
			}
			defer c.Close()
			if len(tc.bytes) > 0 {
				if _, err := c.Write(tc.bytes); err != nil {
					t.Fatalf("write: %v", err)
				}
			}
			started := time.Now()
			_ = c.SetReadDeadline(time.Now().Add(10 * hold))
			_, err = c.Read(make([]byte, 1))
			if err == nil {
				t.Fatal("read a byte from a listener that should have closed the connection")
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				t.Fatalf("the connection was still open %s after a %s handshake timeout", 10*hold, hold)
			}
			if waited := time.Since(started); tc.held && waited < hold/2 {
				t.Fatalf("closed after %s, before the %s timeout could have fired", waited, hold)
			}
		})
	}
	// Three failures inside a second: the throttle lets at most two lines out
	// (the sub-tests run for ~300 ms each, so one interval may elapse).
	if n := logged.Load(); n > 2 {
		t.Fatalf("%d handshake-failure lines for 3 failures; want at most 2 (one a second)", n)
	}
}

// TestAnAcceptedConnectionSaysWhenItWasAccepted: what NewListener hands up
// carries the moment the raw socket was accepted, so the relay's hello
// timeout can count from there and the sniff's timeout and the hello
// timer overlap rather than add up (pass-3 P1b, closed 2026-09-15).
func TestAnAcceptedConnectionSaysWhenItWasAccepted(t *testing.T) {
	cfg, _, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln, err := tlsx.NewListener(raw, tlsx.ListenConfig{TLS: cfg, HandshakeTimeout: testTimeout, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatalf("NewListener: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	before := time.Now()
	go func() {
		c := dialTLS(t, ln.Addr().String())
		_, _ = c.Write([]byte("x\n"))
	}()
	c, err := ln.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	defer c.Close()
	a, ok := c.(interface{ AcceptedAt() time.Time })
	if !ok {
		t.Fatalf("an accepted %T does not say when it was accepted", c)
	}
	if at := a.AcceptedAt(); at.Before(before) || at.After(time.Now()) {
		t.Fatalf("accepted at %v, outside [%v, now]", at, before)
	}
	if !tlsx.IsTLS(c) {
		t.Fatalf("an accepted %T is not reported as TLS", c)
	}
	if tlsx.PeerFingerprint(c) != "" {
		t.Fatal("a client that presented no certificate has a peer fingerprint")
	}
}
