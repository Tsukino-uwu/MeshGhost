package netx_test

// TLS over the tcp transport, tested at the netx seam — where a caller
// (the relay's main, the core) actually reaches it.
//
// The load-bearing test here is
// TestTheRoomCodeIsNotReadableOnTheWireWithTLS, which taps the bytes
// actually crossing the socket rather than asserting on configuration. It
// has a deliberate negative control in the same function: with tls off the
// room code IS readable, so the test fails if the feature stops working
// *and* fails if the test stops actually looking.

import (
	"bufio"
	"bytes"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

const tlsTestTimeout = 5 * time.Second

// tap sits between a client and target, forwarding both directions and
// recording every byte the client sends. This is the packet capture a
// coffee-shop eavesdropper would have.
type tap struct {
	ln net.Listener

	mu   sync.Mutex
	seen bytes.Buffer
}

func newTap(t *testing.T, target string) *tap {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("tap listen: %v", err)
	}
	tp := &tap{ln: ln}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go tp.pipe(c, target)
		}
	}()
	return tp
}

func (tp *tap) pipe(client net.Conn, target string) {
	defer client.Close()
	server, err := net.DialTimeout("tcp", target, tlsTestTimeout)
	if err != nil {
		return
	}
	defer server.Close()
	go io.Copy(client, server)
	buf := make([]byte, 4096)
	for {
		n, err := client.Read(buf)
		if n > 0 {
			tp.mu.Lock()
			tp.seen.Write(buf[:n])
			tp.mu.Unlock()
			if _, werr := server.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func (tp *tap) addr() string { return tp.ln.Addr().String() }

func (tp *tap) captured() string {
	tp.mu.Lock()
	defer tp.mu.Unlock()
	return tp.seen.String()
}

// relayish is a stand-in for the relay: a listener in the given TLS mode
// that reads one line per connection. It is netx.ListenWithTLS, so this
// exercises the same call the real relay makes.
func relayish(t *testing.T, mode tlsx.Mode) (addr string, got chan string) {
	t.Helper()

	var opts netx.TLSOptions
	if mode != tlsx.Off {
		cfg, _, err := tlsx.ServerConfig(netx.TLSALPN)
		if err != nil {
			t.Fatalf("ServerConfig: %v", err)
		}
		opts = netx.TLSOptions{Mode: mode, Server: cfg, Logf: func(string, ...any) {}}
	}
	ln, err := netx.ListenWithTLS(netx.TCP, "127.0.0.1:0", opts)
	if err != nil {
		t.Fatalf("ListenWithTLS: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	got = make(chan string, 4)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetReadDeadline(time.Now().Add(tlsTestTimeout))
				line, err := bufio.NewReader(c).ReadString(byte('\n'))
				// Only NDJSON is reported. A plaintext relay handed a TLS
				// ClientHello sees binary garbage, exactly as the real one
				// would; reporting it would make "did the room code
				// arrive?" answer yes for bytes no relay could parse.
				if line == "" || !strings.HasPrefix(line, "{") {
					_ = err
					return
				}
				select {
				case got <- line:
				default:
				}
			}(c)
		}
	}()
	return ln.Addr().String(), got
}

// TestTheRoomCodeIsNotReadableOnTheWireWithTLS is the whole point of the
// feature, asserted against real bytes on a real socket.
//
// The plaintext half is not decoration: it proves the tap is looking at the
// right traffic, so a green encrypted half means "the room code was
// encrypted" rather than "the test stopped watching".
func TestTheRoomCodeIsNotReadableOnTheWireWithTLS(t *testing.T) {
	const secret = "hunter2-room-code"
	hello := "{\"room_code\":\"" + secret + "\"}\n"

	t.Run("plaintext leaks it", func(t *testing.T) {
		addr, got := relayish(t, tlsx.Off)
		tp := newTap(t, addr)

		conn, err := netx.DialWithTLS(netx.TCP, tp.addr(), tlsTestTimeout, netx.TLSOptions{})
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()
		if _, err := conn.Write([]byte(hello)); err != nil {
			t.Fatalf("write: %v", err)
		}
		if line := <-got; !strings.Contains(line, secret) {
			t.Fatalf("the relay got %q, want the hello", line)
		}
		if !strings.Contains(tp.captured(), secret) {
			t.Fatal("the control case did not capture the room code, so this test is not " +
				"watching the wire and the encrypted case below proves nothing")
		}
	})

	t.Run("tls hides it", func(t *testing.T) {
		addr, got := relayish(t, tlsx.Required)
		tp := newTap(t, addr)

		conn, err := netx.DialWithTLS(netx.TCP, tp.addr(), tlsTestTimeout,
			netx.TLSOptions{Mode: tlsx.Required})
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()
		if _, err := conn.Write([]byte(hello)); err != nil {
			t.Fatalf("write: %v", err)
		}
		if line := <-got; !strings.Contains(line, secret) {
			t.Fatalf("the relay got %q, want the hello — TLS must not change what arrives", line)
		}
		if strings.Contains(tp.captured(), secret) {
			t.Fatal("the room code was readable on the wire despite tls=required")
		}
	})
}

// TestRequiredRefusesAPlaintextRelay: no bytes to a relay that cannot
// handshake. This is the property no earlier MeshGhost security setting had
// — room-code auth is enforced only by the relay, so a stale relay silently
// disables it (agent_docs/risks.md). A required client cannot be disabled
// from the other end.
func TestRequiredRefusesAPlaintextRelay(t *testing.T) {
	addr, got := relayish(t, tlsx.Off)

	_, err := netx.DialWithTLS(netx.TCP, addr, tlsTestTimeout, netx.TLSOptions{Mode: tlsx.Required})
	if err == nil {
		t.Fatal("a tls=required client connected to a plaintext relay")
	}
	// It necessarily sends a ClientHello — that is what "try TLS" means —
	// but no application data, so the room code and everything else in the
	// hello never reach a relay that could not encrypt them.
	select {
	case line := <-got:
		t.Fatalf("the plaintext relay received the application line %q; a required client must "+
			"send none at all", line)
	case <-time.After(300 * time.Millisecond):
	}
}

// TestAutoReachesBothKindsOfRelay: the compatibility requirement. A client
// with tls on must still connect to a relay built before the feature
// existed, and must use TLS with one that has it.
func TestAutoReachesBothKindsOfRelay(t *testing.T) {
	for _, tc := range []struct {
		name       string
		relay      tlsx.Mode
		wantSecure bool
	}{
		{"old plaintext relay", tlsx.Off, false},
		{"relay serving both", tlsx.Auto, true},
		{"relay requiring tls", tlsx.Required, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			addr, got := relayish(t, tc.relay)
			conn, err := netx.DialWithTLS(netx.TCP, addr, tlsTestTimeout,
				netx.TLSOptions{Mode: tlsx.Auto, Logf: func(string, ...any) {}})
			if err != nil {
				t.Fatalf("auto could not connect: %v", err)
			}
			defer conn.Close()
			if tlsx.IsTLS(conn) != tc.wantSecure {
				t.Fatalf("encrypted = %v, want %v", tlsx.IsTLS(conn), tc.wantSecure)
			}
			if _, err := conn.Write([]byte("{\"hi\":1}\n")); err != nil {
				t.Fatalf("write: %v", err)
			}
			if line := <-got; !strings.Contains(line, "hi") {
				t.Fatalf("relay got %q", line)
			}
		})
	}
}

// TestPlaintextClientStillReachesATLSRelayInAuto is the other half of
// "must not fail to connect to a relay that offers both": the relay's auto
// mode has to keep serving the clients that predate the feature, and netcat.
func TestPlaintextClientStillReachesATLSRelayInAuto(t *testing.T) {
	addr, got := relayish(t, tlsx.Auto)
	conn, err := netx.Dial(netx.TCP, addr, tlsTestTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("{\"plain\":1}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if line := <-got; !strings.Contains(line, "plain") {
		t.Fatalf("relay got %q, want the plaintext line", line)
	}
}

// TestUDPCannotBeRequiredToEncrypt: Go has no DTLS, so "udp plus tls
// required" has no correct behaviour. Refusing is the only honest one — the
// alternative is a session the user believes is encrypted and is not.
func TestUDPCannotBeRequiredToEncrypt(t *testing.T) {
	_, err := netx.DialWithTLS(netx.UDP, "127.0.0.1:1", tlsTestTimeout,
		netx.TLSOptions{Mode: tlsx.Required})
	if err == nil {
		t.Fatal("udp accepted tls=required; that session would be plaintext while claiming otherwise")
	}
	if !strings.Contains(err.Error(), "udp") {
		t.Fatalf("error %q does not name udp as the problem", err)
	}
}

// TestQUICAlreadySatisfiesRequired: quic's handshake IS TLS 1.3, so
// requiring TLS must not break it or double-wrap it.
func TestQUICAlreadySatisfiesRequired(t *testing.T) {
	ln, err := netx.Listen(netx.QUIC, "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen quic: %v", err)
	}
	defer ln.Close()

	done := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 128)
		n, _ := c.Read(buf)
		done <- string(buf[:n])
	}()

	conn, err := netx.DialWithTLS(netx.QUIC, ln.Addr().String(), tlsTestTimeout,
		netx.TLSOptions{Mode: tlsx.Required})
	if err != nil {
		t.Fatalf("quic dial under tls=required: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("{\"q\":1}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case line := <-done:
		if !strings.Contains(line, "q") {
			t.Fatalf("quic delivered %q", line)
		}
	case <-time.After(tlsTestTimeout):
		t.Fatal("quic under tls=required delivered nothing")
	}
}

// TestListenWithTLSOffIsUntouched: mode off must not put anything between
// the relay and its socket.
func TestListenWithTLSOffIsUntouched(t *testing.T) {
	ln, err := netx.ListenWithTLS(netx.TCP, "127.0.0.1:0", netx.TLSOptions{})
	if err != nil {
		t.Fatalf("ListenWithTLS: %v", err)
	}
	defer ln.Close()
	if _, ok := ln.(*net.TCPListener); !ok {
		t.Fatalf("got %T, want the bare net.TCPListener", ln)
	}
}
