// Package tlsx is TLS for the tcp transport, and nothing else.
//
// It exists because `tcp` is the one leg of a MeshGhost session that is
// always used and was always plaintext: every client handshakes over tcp
// before it moves anywhere (see core's resolveTransport and
// docs/security.md's "How a client actually connects"), and that handshake
// carries the room code. So a session on the encrypted `quic` transport
// still sent its room code across the network in the clear, on the
// discovery leg, before it ever reached quic. Encrypting tcp closes that.
//
// # What this protects against, precisely
//
// The certificate is self-signed, generated in memory, and never written
// anywhere. Unless the operator hands out its fingerprint and the player
// pins it (Pin below), nothing verifies who is on the other end. So:
//
//   - Passive capture — someone reading traffic on shared wifi, a VPN, an
//     ISP — is blocked. The room code stops being readable.
//   - An active man-in-the-middle who can intercept and re-terminate the
//     connection is NOT blocked, because they can present their own
//     self-signed certificate and it is accepted.
//   - Pinning a fingerprint closes the second case too, for anyone willing
//     to compare a string out of band. It is opt-in; nothing generates or
//     distributes it automatically, and there is no CA anywhere in this
//     design.
//
// That is the same honest posture quic already has (netx/quicconn's
// package doc), reached the same way, and it is written down in
// docs/security.md rather than implied.
//
// # Why one port serves both
//
// A TLS ClientHello starts with the byte 0x16; an NDJSON line starts with
// '{'. NewListener reads exactly one byte and decides, so a TLS client and
// a netcat session reach the same relay on the same port. Debugging a
// relay by hand keeps working with the feature on, which is the property
// that makes Auto safe to enable.
package tlsx

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net"
	"strings"
	"sync"
	"time"
)

// DefaultHandshakeTimeout bounds one accepted connection's sniff plus TLS
// handshake. It exists because a handshake is real CPU an unauthenticated
// stranger can ask for: without a bound, N half-open connections each hold
// a goroutine and a socket indefinitely. See agent_docs/ideas.md's note on
// the (still absent) per-IP cap, which is a separate decision.
const DefaultHandshakeTimeout = 10 * time.Second

// tlsRecordHandshake is the first byte of a TLS record of type handshake —
// what every ClientHello begins with. No JSON value starts with it, which
// is what makes one-byte sniffing unambiguous here.
const tlsRecordHandshake = 0x16

// Mode is the three-way TLS switch, identical on the relay and the client
// so one word means one thing in both config files.
type Mode int

const (
	// Off is plaintext, and the built-in default. Deliberate: plaintext is
	// how a session gets debugged — netcat, a packet capture,
	// cmd/meshghost-netsim — and turning that off by default would cost
	// the project its cheapest diagnostic. A release turns it on in
	// config.json.
	Off Mode = iota

	// Auto encrypts when the other end can. On a listener it serves TLS
	// and plaintext on one port. On a client it speaks TLS and falls back
	// to plaintext only if the handshake fails outright — loudly, never
	// silently, and never after a TLS connection to the same relay has
	// already succeeded in this attempt (see core's resolveTransport).
	Auto

	// Required refuses plaintext. A listener closes a connection that does
	// not begin a TLS handshake; a client never sends a byte to a relay it
	// could not handshake with. This is the first MeshGhost security
	// setting a stale peer cannot silently disable — room-code auth could
	// not do that (agent_docs/risks.md).
	Required
)

func (m Mode) String() string {
	switch m {
	case Off:
		return "off"
	case Auto:
		return "auto"
	case Required:
		return "required"
	default:
		return fmt.Sprintf("Mode(%d)", int(m))
	}
}

// ParseMode resolves a mode name from a flag or config key. Strict, for the
// same reason netx.ParseKind is: the zero value is Off, so a lenient parse
// would turn a typo into a silently unencrypted session.
func ParseMode(s string) (Mode, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "off", "false", "no":
		return Off, nil
	case "auto":
		return Auto, nil
	case "required", "on", "true", "yes":
		return Required, nil
	default:
		return Off, fmt.Errorf("tlsx: unknown tls mode %q (want off, auto, or required)", s)
	}
}

// ServerConfig builds a listener's TLS configuration around a freshly
// generated in-memory Ed25519 certificate, and returns the certificate's
// fingerprint alongside it.
//
// Nothing is written to disk, ever. A key file next to the exe would buy no
// security — nothing verifies the certificate unless a fingerprint is
// pinned by hand — while putting a private key inside a zip people
// re-share. Same reasoning quicconn already applies.
//
// Call this once per process and reuse the result: generating a key per
// connection would hand an unauthenticated stranger a free CPU lever.
func ServerConfig(alpn string) (*tls.Config, string, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, "", fmt.Errorf("tlsx: generate key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, "", fmt.Errorf("tlsx: generate serial: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "meshghost-relay"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, priv)
	if err != nil {
		return nil, "", fmt.Errorf("tlsx: create certificate: %w", err)
	}
	cfg := &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: priv}},
		MinVersion:   tls.VersionTLS13,
	}
	if alpn != "" {
		cfg.NextProtos = []string{alpn}
	}
	return cfg, Fingerprint(der), nil
}

// Fingerprint is the SHA-256 of a certificate's DER bytes, lower-case hex
// with no separators. This is the string a relay operator can read out of
// their log and a player can paste into "tls_fingerprint" — the only thing
// in this design that authenticates a relay, and entirely opt-in.
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

// ClientConfig builds a dialer's TLS configuration.
//
// InsecureSkipVerify is set on purpose and is not a shortcut: "connect_to"
// is a bare IP a friend sent you, so there is no CA and no hostname a
// certificate could be checked against. Verification, when it happens at
// all, is the pin — an exact fingerprint match, compared out of band by a
// human. Passing an empty pin means encryption without authentication,
// which is what the package doc spells out.
func ClientConfig(alpn, pin string) *tls.Config {
	cfg := &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS13,
	}
	if alpn != "" {
		cfg.NextProtos = []string{alpn}
	}
	pin = normalizeFingerprint(pin)
	if pin != "" {
		cfg.VerifyPeerCertificate = func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			for _, raw := range rawCerts {
				if Fingerprint(raw) == pin {
					return nil
				}
			}
			got := "none"
			if len(rawCerts) > 0 {
				got = Fingerprint(rawCerts[0])
			}
			return fmt.Errorf("tlsx: relay certificate fingerprint %s does not match the pinned %s "+
				"— either you are talking to a different relay than you think, or the host restarted "+
				"it (the certificate is regenerated every run, so a pin has to be re-copied after a restart)",
				got, pin)
		}
	}
	return cfg
}

// normalizeFingerprint accepts the shapes a human might paste: with or
// without colons, spaces or upper case. A fingerprint is a string a person
// copies by hand, so being picky about separators would produce a confusing
// "does not match" for two identical certificates.
func normalizeFingerprint(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(s)) {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f':
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Client wraps an already-dialed connection in TLS and completes the
// handshake before returning, so a failure surfaces here rather than
// halfway through the first Send. On failure the underlying connection is
// closed — the caller has nothing usable left.
func Client(conn net.Conn, alpn, pin string, timeout time.Duration) (net.Conn, error) {
	if timeout <= 0 {
		timeout = DefaultHandshakeTimeout
	}
	tc := tls.Client(conn, ClientConfig(alpn, pin))
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if err := tc.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("tlsx: handshake: %w", err)
	}
	return tc, nil
}

// IsTLS reports whether conn is an established TLS connection. Used by the
// core to refuse a downgrade: once a relay has proven it speaks TLS on one
// leg, the next leg to the same relay is not allowed to be plaintext.
func IsTLS(conn net.Conn) bool {
	_, ok := conn.(*tls.Conn)
	return ok
}

// ListenConfig configures NewListener.
type ListenConfig struct {
	// Mode is the switch. Off returns the inner listener untouched.
	Mode Mode

	// TLS is the server certificate config, normally from ServerConfig.
	// Required when Mode is not Off.
	TLS *tls.Config

	// HandshakeTimeout bounds the sniff plus handshake per connection.
	// Zero means DefaultHandshakeTimeout.
	HandshakeTimeout time.Duration

	// Logf receives one line per refused plaintext connection under
	// Required, and per failed handshake. Nil means the standard logger.
	Logf func(format string, args ...any)
}

// NewListener wraps ln so accepted connections are sniffed and, when they
// begin a TLS handshake, decrypted.
//
// Mode Off returns ln unchanged, so the feature genuinely costs nothing
// when it is not on — no extra goroutine, no extra allocation, not even a
// wrapper type between the relay and its socket.
//
// The sniff and the handshake happen on a per-connection goroutine, not
// inside Accept. That matters: doing it in Accept would let one client that
// connects and then says nothing stall every other client for the whole
// handshake timeout, which is a denial of service anyone can perform with
// netcat.
func NewListener(ln net.Listener, cfg ListenConfig) (net.Listener, error) {
	if cfg.Mode == Off {
		return ln, nil
	}
	if cfg.TLS == nil {
		return nil, errors.New("tlsx: NewListener needs a TLS config when mode is not off")
	}
	timeout := cfg.HandshakeTimeout
	if timeout <= 0 {
		timeout = DefaultHandshakeTimeout
	}
	logf := cfg.Logf
	if logf == nil {
		logf = log.Printf
	}
	l := &sniffListener{
		Listener: ln,
		mode:     cfg.Mode,
		tlsCfg:   cfg.TLS,
		timeout:  timeout,
		logf:     logf,
		out:      make(chan accepted, 16),
		done:     make(chan struct{}),
	}
	go l.acceptLoop()
	return l, nil
}

type accepted struct {
	conn net.Conn
	err  error
}

type sniffListener struct {
	net.Listener
	mode    Mode
	tlsCfg  *tls.Config
	timeout time.Duration
	logf    func(format string, args ...any)

	out       chan accepted
	done      chan struct{}
	closeOnce sync.Once
}

func (l *sniffListener) acceptLoop() {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			l.deliver(accepted{err: err})
			return
		}
		go l.classify(c)
	}
}

// classify reads the one byte that decides what this connection is, then
// either hands it up as-is or completes a TLS handshake on it first.
func (l *sniffListener) classify(c net.Conn) {
	deadline := time.Now().Add(l.timeout)
	_ = c.SetReadDeadline(deadline)

	first := make([]byte, 1)
	n, err := c.Read(first)
	if err != nil || n == 0 {
		// Nothing usable arrived in time. Dropped silently: a port scan
		// and a health check both look exactly like this, and logging
		// them would fill a host's log with noise they cannot act on.
		_ = c.Close()
		return
	}
	_ = c.SetReadDeadline(time.Time{})

	pc := &prefixConn{Conn: c, prefix: first[:n]}

	if first[0] != tlsRecordHandshake {
		if l.mode == Required {
			l.logf("meshghost: refused a plaintext connection from %s — this relay is configured "+
				"tls=required, so only encrypted clients are accepted", c.RemoteAddr())
			_ = c.Close()
			return
		}
		l.deliver(accepted{conn: pc})
		return
	}

	tc := tls.Server(pc, l.tlsCfg)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	if err := tc.HandshakeContext(ctx); err != nil {
		l.logf("meshghost: tls handshake with %s failed: %v", c.RemoteAddr(), err)
		_ = c.Close()
		return
	}
	l.deliver(accepted{conn: tc})
}

func (l *sniffListener) deliver(a accepted) {
	select {
	case l.out <- a:
	case <-l.done:
		if a.conn != nil {
			_ = a.conn.Close()
		}
	}
}

func (l *sniffListener) Accept() (net.Conn, error) {
	select {
	case a := <-l.out:
		return a.conn, a.err
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *sniffListener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.done)
		err = l.Listener.Close()
	})
	return err
}

// prefixConn replays the bytes already consumed by the sniff before
// delegating to the real connection. Without it the ClientHello would be
// missing its first byte and every handshake would fail.
type prefixConn struct {
	net.Conn
	prefix []byte
}

func (c *prefixConn) Read(p []byte) (int, error) {
	if len(c.prefix) > 0 {
		n := copy(p, c.prefix)
		c.prefix = c.prefix[n:]
		return n, nil
	}
	return c.Conn.Read(p)
}
