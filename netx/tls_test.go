package netx_test

// TLS over the tcp transport, tested at the netx seam where the relay and the core reach it.

import (
	"bufio"
	"bytes"
	"errors"
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

// tap sits between a client and target, forwarding both directions and recording every byte the client sends: an
// eavesdropper's packet capture.
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

// relayish stands in for the relay through the same netx.ListenWithTLS call, reading one line per connection. It
// returns the address, the lines received and the fingerprint served.
func relayish(t *testing.T) (addr string, got chan string, fingerprint string) {
	t.Helper()
	cfg, fp, err := tlsx.ServerConfig(netx.TLSALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	ln, err := netx.ListenWithTLS(netx.TCP, "127.0.0.1:0", netx.TLSOptions{Server: cfg, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatalf("ListenWithTLS: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().String(), readLines(t, ln), fp
}

// rawRelay is a plaintext listener that reads one line per connection, as a relay without TLS would: the control
// case of the wire test, and what a client must refuse.
func rawRelay(t *testing.T) (addr string, got chan string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().String(), readLines(t, ln)
}

func readLines(t *testing.T, ln net.Listener) chan string {
	t.Helper()
	got := make(chan string, 4)
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
				// Only NDJSON is reported: a ClientHello is binary no relay could parse, not an arrived line.
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
	return got
}

// trustAny is the dial-side options a test that is not about verification uses, named so every use is greppable.
var trustAny = netx.TLSOptions{Verify: tlsx.TrustAnyCertificate}

// TestTheRoomCodeIsNotReadableOnTheWireWithTLS asserts against real bytes on a real socket. The plaintext half proves
// the tap is watching the right traffic; no shipped dial is plaintext, so it is a raw socket to a raw listener.
func TestTheRoomCodeIsNotReadableOnTheWireWithTLS(t *testing.T) {
	const secret = "hunter2-room-code"
	hello := "{\"room_code\":\"" + secret + "\"}\n"

	t.Run("plaintext leaks it (control)", func(t *testing.T) {
		addr, got := rawRelay(t)
		tp := newTap(t, addr)

		conn, err := net.DialTimeout("tcp", tp.addr(), tlsTestTimeout)
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
		addr, got, _ := relayish(t)
		tp := newTap(t, addr)

		conn, err := netx.DialWithTLS(netx.TCP, tp.addr(), tlsTestTimeout, trustAny)
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
			t.Fatal("the room code was readable on the wire")
		}
	})
}

// TestAClientRefusesAPlaintextRelay: no application bytes to a relay that cannot handshake, a property the other end
// cannot disable. Two shapes of relay, indistinguishable from the client's side: a plaintext relay never answers a
// ClientHello with bytes, which is what an on-path party blackholing the handshake looks like.
func TestAClientRefusesAPlaintextRelay(t *testing.T) {
	for _, tc := range []struct {
		name  string
		relay func(t *testing.T) (string, chan string)
	}{
		{"a plaintext relay that reads the line and hangs up", rawRelay},
		{"a relay that says nothing at all", func(t *testing.T) (string, chan string) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatalf("listen: %v", err)
			}
			t.Cleanup(func() { ln.Close() })
			go func() {
				for {
					c, err := ln.Accept()
					if err != nil {
						return
					}
					t.Cleanup(func() { c.Close() })
				}
			}()
			return ln.Addr().String(), make(chan string)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			addr, got := tc.relay(t)
			conn, err := netx.DialWithTLS(netx.TCP, addr, 500*time.Millisecond, trustAny)
			if err == nil {
				conn.Close()
				t.Fatal("the client connected to a plaintext relay; a failed handshake must be a refusal")
			}
			// It necessarily sends a ClientHello, but no application data.
			select {
			case line := <-got:
				t.Fatalf("the plaintext relay received the application line %q; the client must "+
					"send none at all", line)
			case <-time.After(300 * time.Millisecond):
			}
		})
	}
}

// TestARelayRefusesAPlaintextClient: a plaintext client (or netcat) is closed, and its line never reaches the relay.
func TestARelayRefusesAPlaintextClient(t *testing.T) {
	addr, got, _ := relayish(t)
	conn, err := net.DialTimeout("tcp", addr, tlsTestTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("{\"plain\":1}\n")); err != nil {
		return // closed already: refused
	}
	select {
	case line := <-got:
		t.Fatalf("the relay accepted the plaintext line %q", line)
	case <-time.After(300 * time.Millisecond):
	}
	_ = conn.SetReadDeadline(time.Now().Add(tlsTestTimeout))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("the plaintext connection is still open; the relay must close it")
	}
}

// TestOneIdentityOnTCPAndQUIC: the relay hands both listeners the same certificate, so a client sees one fingerprint
// whichever transport it lands on.
func TestOneIdentityOnTCPAndQUIC(t *testing.T) {
	cfg, fp, err := tlsx.ServerConfig(netx.TLSALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	opts := netx.TLSOptions{Server: cfg, Logf: func(string, ...any) {}}
	seen := map[netx.Kind]string{}
	for _, kind := range []netx.Kind{netx.TCP, netx.QUIC} {
		ln, err := netx.ListenWithTLS(kind, "127.0.0.1:0", opts)
		if err != nil {
			t.Fatalf("%s: ListenWithTLS: %v", kind, err)
		}
		t.Cleanup(func() { ln.Close() })
		go func() {
			for {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				c.Close()
			}
		}()
		conn, err := netx.DialWithTLS(kind, ln.Addr().String(), tlsTestTimeout, netx.TLSOptions{
			Verify: func(leaf []byte) error { seen[kind] = tlsx.Fingerprint(leaf); return nil },
		})
		if err != nil {
			t.Fatalf("%s: DialWithTLS: %v", kind, err)
		}
		conn.Close()
	}
	if seen[netx.TCP] != fp || seen[netx.QUIC] != fp {
		t.Fatalf("tcp presented %q, quic presented %q, the identity is %q -- one relay must have one fingerprint",
			seen[netx.TCP], seen[netx.QUIC], fp)
	}
}

// TestTheVerifierDecidesOnEveryTransport: a refusing verifier refuses the quic handshake as it does the tcp one, and
// a missing verifier is an error on both rather than an unchecked session.
func TestTheVerifierDecidesOnEveryTransport(t *testing.T) {
	cfg, _, err := tlsx.ServerConfig(netx.TLSALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	for _, kind := range []netx.Kind{netx.TCP, netx.QUIC} {
		t.Run(kind.String(), func(t *testing.T) {
			ln, err := netx.ListenWithTLS(kind, "127.0.0.1:0", netx.TLSOptions{Server: cfg, Logf: func(string, ...any) {}})
			if err != nil {
				t.Fatalf("ListenWithTLS: %v", err)
			}
			defer ln.Close()
			go func() {
				for {
					c, err := ln.Accept()
					if err != nil {
						return
					}
					c.Close()
				}
			}()
			addr := ln.Addr().String()
			if conn, err := netx.DialWithTLS(kind, addr, tlsTestTimeout, netx.TLSOptions{
				Verify: func([]byte) error { return errors.New("not my relay") },
			}); err == nil {
				conn.Close()
				t.Fatal("a refusing verifier did not refuse")
			}
			if conn, err := netx.DialWithTLS(kind, addr, tlsTestTimeout, netx.TLSOptions{}); err == nil {
				conn.Close()
				t.Fatal("a nil verifier connected; it must be an error")
			}
			if conn, err := netx.DialWithTLS(kind, addr, tlsTestTimeout, trustAny); err != nil {
				t.Fatalf("an accepting verifier failed: %v", err)
			} else {
				conn.Close()
			}
		})
	}
}

// TestBareDialRefusesQUIC: nothing can reach a quic relay without a verifier by taking the plain Dial.
func TestBareDialRefusesQUIC(t *testing.T) {
	if conn, err := netx.Dial(netx.QUIC, "127.0.0.1:1", tlsTestTimeout); err == nil {
		conn.Close()
		t.Fatal("netx.Dial(QUIC) returned a connection; it must refuse and name DialWithTLS")
	} else if !strings.Contains(err.Error(), "DialWithTLS") {
		t.Fatalf("error %q does not name DialWithTLS", err)
	}
}

// TestListenWithTLSNeedsAnIdentity: a relay that forgot its identity does not come up plaintext.
func TestListenWithTLSNeedsAnIdentity(t *testing.T) {
	for _, kind := range []netx.Kind{netx.TCP, netx.QUIC} {
		if ln, err := netx.ListenWithTLS(kind, "127.0.0.1:0", netx.TLSOptions{}); err == nil {
			ln.Close()
			t.Fatalf("%s: ListenWithTLS without an identity listened; it must refuse", kind)
		}
	}
}
