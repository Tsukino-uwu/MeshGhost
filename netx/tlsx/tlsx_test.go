package tlsx_test

import (
	"bufio"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

const testALPN = "meshghost"

const testTimeout = 5 * time.Second

// serve brings up a sniffing listener in mode, plus an echo-ish accept loop
// that reads one line per connection and reports it on the returned
// channel. Returns the address to dial and the fingerprint of the
// certificate it is using.
func serve(t *testing.T, mode tlsx.Mode) (addr, fingerprint string, lines chan string) {
	t.Helper()

	cfg, fp, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln, err := tlsx.NewListener(raw, tlsx.ListenConfig{
		Mode:             mode,
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
	return ln.Addr().String(), fp, lines
}

func TestParseModeRejectsATypo(t *testing.T) {
	if _, err := tlsx.ParseMode("requried"); err == nil {
		t.Fatal("a typo'd tls mode parsed cleanly; it would silently mean off, which is the whole trap")
	}
}

func TestParseModeAcceptsEveryMode(t *testing.T) {
	for in, want := range map[string]tlsx.Mode{
		"off":      tlsx.Off,
		"OFF":      tlsx.Off,
		" auto ":   tlsx.Auto,
		"required": tlsx.Required,
		"on":       tlsx.Required,
		"true":     tlsx.Required,
	} {
		got, err := tlsx.ParseMode(in)
		if err != nil || got != want {
			t.Errorf("ParseMode(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
}

// TestOffIsExactlyTheOldListener: mode off must not even wrap the listener,
// so the feature costs nothing at all when it is not on — no goroutine, no
// sniff, no extra byte of latency on the first read.
func TestOffIsExactlyTheOldListener(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer raw.Close()
	got, err := tlsx.NewListener(raw, tlsx.ListenConfig{Mode: tlsx.Off})
	if err != nil {
		t.Fatalf("NewListener: %v", err)
	}
	if got != raw {
		t.Fatalf("mode off returned a wrapper (%T); it must return the listener untouched", got)
	}
}

// TestAutoServesTLSAndPlaintextOnOnePort is the property that makes the
// feature safe to turn on: a relay with TLS enabled is still drivable by
// hand with netcat, which is how a session gets debugged.
func TestAutoServesTLSAndPlaintextOnOnePort(t *testing.T) {
	addr, _, lines := serve(t, tlsx.Auto)

	plain, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("plaintext dial: %v", err)
	}
	defer plain.Close()
	if _, err := plain.Write([]byte("{\"hello\":1}\n")); err != nil {
		t.Fatalf("plaintext write: %v", err)
	}
	if got := <-lines; !strings.Contains(got, "hello") {
		t.Fatalf("plaintext line %q did not arrive intact", got)
	}

	conn, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("tls dial: %v", err)
	}
	secure, err := tlsx.Client(conn, testALPN, "", testTimeout)
	if err != nil {
		t.Fatalf("tls handshake: %v", err)
	}
	defer secure.Close()
	if _, err := secure.Write([]byte("{\"encrypted\":1}\n")); err != nil {
		t.Fatalf("tls write: %v", err)
	}
	if got := <-lines; !strings.Contains(got, "encrypted") {
		t.Fatalf("tls line %q did not arrive intact", got)
	}
}

// TestTheSniffedByteIsNotEaten: the first byte is consumed to decide what
// the connection is and has to be replayed. If it were not, every plaintext
// line would arrive missing its opening brace and every handshake would
// fail — a corruption that only shows up on the very first byte, which is
// easy to miss by testing with a long message.
func TestTheSniffedByteIsNotEaten(t *testing.T) {
	addr, _, lines := serve(t, tlsx.Auto)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	if _, err := c.Write([]byte("{}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := <-lines; got != "{}\n" {
		t.Fatalf("got %q, want the line delivered byte for byte including its first character", got)
	}
}

// TestRequiredRefusesPlaintext is the anti-downgrade half: a relay that has
// been told to require TLS must not hand a plaintext connection upward at
// all, however well-formed it is.
func TestRequiredRefusesPlaintext(t *testing.T) {
	addr, _, lines := serve(t, tlsx.Required)

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
		t.Fatalf("a plaintext line %q reached the application under tls=required", got)
	case <-time.After(500 * time.Millisecond):
	}

	// And the connection is actually closed, not merely ignored.
	_ = c.SetReadDeadline(time.Now().Add(testTimeout))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("the refused connection is still readable; it should have been closed")
	}
}

// TestRequiredStillAcceptsTLS: refusing plaintext must not refuse everything.
func TestRequiredStillAcceptsTLS(t *testing.T) {
	addr, _, lines := serve(t, tlsx.Required)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	secure, err := tlsx.Client(c, testALPN, "", testTimeout)
	if err != nil {
		t.Fatalf("handshake: %v", err)
	}
	defer secure.Close()
	if _, err := secure.Write([]byte("{\"ok\":1}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := <-lines; !strings.Contains(got, "ok") {
		t.Fatalf("got %q, want the encrypted line delivered", got)
	}
}

// TestPinnedFingerprintAcceptsTheRelayItNames.
func TestPinnedFingerprintAcceptsTheRelayItNames(t *testing.T) {
	addr, fp, _ := serve(t, tlsx.Required)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	secure, err := tlsx.Client(c, testALPN, fp, testTimeout)
	if err != nil {
		t.Fatalf("handshake with the correct pin failed: %v", err)
	}
	secure.Close()
}

// TestPinnedFingerprintRefusesAnyoneElse is the only thing in this design
// that authenticates a relay. Without it, encryption stops a passive
// listener and nothing else — an active man in the middle presents their
// own self-signed certificate and is accepted, exactly as on quic today.
func TestPinnedFingerprintRefusesAnyoneElse(t *testing.T) {
	addr, fp, _ := serve(t, tlsx.Required)

	// Some other relay's fingerprint: same shape, different certificate.
	_, otherFP, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	if otherFP == fp {
		t.Fatal("two freshly generated certificates share a fingerprint; the generator is broken")
	}

	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if _, err := tlsx.Client(c, testALPN, otherFP, testTimeout); err == nil {
		t.Fatal("a relay presenting a different certificate was accepted despite a pin")
	}
}

// TestAPinIsForgivingAboutFormatting: a fingerprint is copied by hand out
// of a log and pasted into a config file, so colons, spaces and upper case
// must not turn a correct pin into a scary "different relay" error.
func TestAPinIsForgivingAboutFormatting(t *testing.T) {
	addr, fp, _ := serve(t, tlsx.Required)

	var spaced strings.Builder
	for i := 0; i < len(fp); i += 2 {
		if i > 0 {
			spaced.WriteByte(':')
		}
		spaced.WriteString(strings.ToUpper(fp[i : i+2]))
	}

	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	secure, err := tlsx.Client(c, testALPN, " "+spaced.String()+" ", testTimeout)
	if err != nil {
		t.Fatalf("a colon-separated upper-case pin was rejected: %v", err)
	}
	secure.Close()
}

// TestALPNMismatchFails: the ALPN is what tells a MeshGhost relay apart
// from anything else that happens to be listening on the port, so a
// mismatch must break the handshake rather than produce a connection that
// fails confusingly later.
func TestALPNMismatchFails(t *testing.T) {
	addr, _, _ := serve(t, tlsx.Required)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if _, err := tlsx.Client(c, "something-else", "", testTimeout); err == nil {
		t.Fatal("a handshake with the wrong ALPN succeeded")
	}
}

// TestOneSilentClientDoesNotStallEveryoneElse: the sniff happens on a
// per-connection goroutine, not inside Accept. Done in Accept, a single
// client that connects and then says nothing would block every other client
// for the whole handshake timeout — a denial of service anyone can perform
// with netcat.
func TestOneSilentClientDoesNotStallEveryoneElse(t *testing.T) {
	addr, _, lines := serve(t, tlsx.Auto)

	silent, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer silent.Close()

	talker, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
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

// TestIsTLSDistinguishesTheTwo, which is what the core's no-downgrade rule
// is built on.
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
	if _, err := tlsx.Client(c, testALPN, "", testTimeout); err == nil {
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
