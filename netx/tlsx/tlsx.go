// Package tlsx is TLS for the tcp transport, and the one certificate story every MeshGhost transport shares. tcp is
// the leg every session uses: every client handshakes over it before moving to any other transport.
//
// # What this protects against
//
// There is no plaintext mode and no plaintext fallback: a listener refuses a connection that does not begin a TLS
// handshake, and a client sends nothing to a relay it cannot handshake with. The certificate is self-signed; what
// authenticates it is the Verifier the client passes to Client, which in core remembers each relay's fingerprint on
// first connect and checks it afterwards (trust on first use, the SSH model). So:
//
//   - Passive capture (shared wifi, a VPN, an ISP) is blocked on every connection.
//   - An active man-in-the-middle on the first connection to a relay is not detected: there is nothing yet to compare
//     against. From the second connection on, a changed identity is noticed.
//   - There is no CA: connect_to is a bare IP, so there is no name a certificate could be checked against.
//
// # Why the sniff stays
//
// A TLS ClientHello starts with the byte 0x16; an NDJSON line starts with '{'. NewListener reads one byte before
// handshaking, so a plaintext client (an old build, or netcat) is refused with a log line that says why, rather than
// a handshake failure that names nothing.
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
	"io"
	"log"
	"math/big"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/throttle"
)

// defaultHandshakeTimeout bounds one accepted connection's sniff plus TLS handshake: a handshake is CPU an
// unauthenticated stranger can ask for, and without a bound each half-open connection holds a goroutine and a socket.
const defaultHandshakeTimeout = 10 * time.Second

// tlsRecordHandshake is the first byte of every ClientHello. No JSON value starts with it, which is what makes
// one-byte sniffing unambiguous.
const tlsRecordHandshake = 0x16

// certificateValidity is twenty years: the identity is persisted and a Verifier compares the fingerprint only, so
// this is the one field of the certificate a player could never be asked to do anything about.
const certificateValidity = 20 * 365 * 24 * time.Hour

// Verifier decides whether the certificate a relay presented is the relay the client meant. It receives the leaf
// certificate's DER bytes and nothing else, and a non-nil error refuses the connection before a byte of application
// data is sent.
//
// Only the leaf: with InsecureSkipVerify set there is no chain building, and only the first certificate the peer
// sends is bound to the handshake signature. An attacker can append a copy of the relay's public certificate after
// its own, so matching any later entry accepts a certificate the peer holds no key for.
type Verifier func(leafDER []byte) error

// TrustAnyCertificate is the Verifier that accepts every certificate, for tests and dev tools only
// (cmd/meshghost-netsim stands between two ends it owns). No shipped client path uses it, and a nil Verifier is an
// error rather than this.
func TrustAnyCertificate([]byte) error { return nil }

// newCertificate generates a fresh Ed25519 self-signed certificate and returns it with its fingerprint.
func newCertificate() (tls.Certificate, string, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", fmt.Errorf("tlsx: generate key: %w", err)
	}
	der, err := certificateFor(pub, priv)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}, Fingerprint(der), nil
}

// certificateFor self-signs a certificate for an Ed25519 key pair. The serial is random, so two certificates for the
// same key have different fingerprints, which is why identity.go persists the certificate as well as the key.
func certificateFor(pub ed25519.PublicKey, priv ed25519.PrivateKey) ([]byte, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, fmt.Errorf("tlsx: generate serial: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "meshghost-relay"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(certificateValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, priv)
	if err != nil {
		return nil, fmt.Errorf("tlsx: create certificate: %w", err)
	}
	return der, nil
}

// keyLogWriter, when a dev build sets it (keylog_dev.go), receives every session's secrets in Wireshark's NSS key
// log format. Nil in a release.
var keyLogWriter io.Writer

// configFor is the listener's TLS configuration around one certificate.
func configFor(cert tls.Certificate, alpn string) *tls.Config {
	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
		KeyLogWriter: keyLogWriter,
	}
	if alpn != "" {
		cfg.NextProtos = []string{alpn}
	}
	return cfg
}

// ServerConfig builds a listener's TLS configuration around a freshly generated in-memory Ed25519 certificate, and
// returns its fingerprint, for a test's relay or a tool that lives for one run; the shipped relay uses
// LoadOrCreateIdentity. Call either once per process: a key per connection would hand a stranger a free CPU lever.
func ServerConfig(alpn string) (*tls.Config, string, error) {
	cert, fp, err := newCertificate()
	if err != nil {
		return nil, "", err
	}
	return configFor(cert, alpn), fp, nil
}

// Fingerprint is the SHA-256 of a certificate's DER bytes, lower-case hex with no separators: what a relay prints at
// startup, what a client remembers in known_servers.json, and the only thing that identifies a relay.
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

// clientConfig builds a dialer's TLS configuration. InsecureSkipVerify is on purpose: connect_to is a bare IP, so
// there is no CA and no hostname to check. Verification is the Verifier, applied by VerifyLeaf after the handshake.
//
// Not in VerifyPeerCertificate: crypto/tls calls that (and VerifyConnection) when the Certificate message arrives,
// before CertificateVerify proves the server holds the key, so a recording Verifier could be fed any certificate by
// a handshake that then fails.
func clientConfig(alpn string) *tls.Config {
	cfg := &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS13,
		KeyLogWriter:       keyLogWriter,
	}
	if alpn != "" {
		cfg.NextProtos = []string{alpn}
	}
	return cfg
}

// ClientConfig is clientConfig for a caller that drives its own handshake (quicconn, through quic-go). That caller
// must call VerifyLeaf with the completed connection's state before sending anything; a nil verifier is an error so
// it cannot reach a config without one.
func ClientConfig(alpn string, verify Verifier) (*tls.Config, error) {
	if verify == nil {
		return nil, errors.New("tlsx: no certificate verifier -- a nil Verifier would accept anyone; " +
			"pass TrustAnyCertificate explicitly if that is what you mean")
	}
	return clientConfig(alpn), nil
}

// VerifyLeaf applies verify to a completed handshake's leaf certificate, the only one the handshake signature binds.
// Call it before the first byte of application data; a non-nil error means close the connection.
func VerifyLeaf(state tls.ConnectionState, verify Verifier) error {
	if verify == nil {
		return errors.New("tlsx: no certificate verifier")
	}
	if !state.HandshakeComplete {
		return errors.New("tlsx: the handshake has not completed; nothing is proven yet")
	}
	if len(state.PeerCertificates) == 0 {
		return errors.New("tlsx: the relay presented no certificate")
	}
	return verify(state.PeerCertificates[0].Raw)
}

// FingerprintHexLen is the length of a normalized fingerprint: SHA-256 as hex.
const FingerprintHexLen = 64

// NormalizeFingerprint accepts the shapes a human might write: with or without colons, spaces or upper case. The
// known-relays store parses its file with it, so a hand-edited entry compares equal to the relay's own print.
//
// It is picky about length, since dropping non-hex runes alone turns a placeholder such as "<paste here>" into the
// empty string. An empty input normalizes to empty; anything else must be exactly FingerprintHexLen hex digits.
func NormalizeFingerprint(s string) (string, error) {
	if strings.TrimSpace(s) == "" {
		return "", nil
	}
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(s)) {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f':
			b.WriteRune(r)
		}
	}
	if b.Len() != FingerprintHexLen {
		return "", fmt.Errorf("tlsx: %q is not a certificate fingerprint: it has %d "+
			"hex digits, and a SHA-256 fingerprint has %d (the relay prints it at startup as "+
			"\"tls certificate fingerprint: ...\")", s, b.Len(), FingerprintHexLen)
	}
	return b.String(), nil
}

// Client wraps an already-dialed connection in TLS and completes the handshake before returning, so a failure
// surfaces here rather than in the first Send; on failure the underlying connection is closed. verify is applied to
// the leaf once the handshake has proven it, and nil is an error: a caller that wants "just encrypt" says
// TrustAnyCertificate, where a reviewer can grep for it.
func Client(conn net.Conn, alpn string, verify Verifier, timeout time.Duration) (net.Conn, error) {
	if timeout <= 0 {
		timeout = defaultHandshakeTimeout
	}
	cfg, err := ClientConfig(alpn, verify)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	tc := tls.Client(conn, cfg)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if err := tc.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("tlsx: handshake: %w", err)
	}
	if err := VerifyLeaf(tc.ConnectionState(), verify); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("tlsx: handshake: %w", err)
	}
	return tc, nil
}

// IsTLS reports whether conn is an established TLS connection.
func IsTLS(conn net.Conn) bool {
	switch conn.(type) {
	case *tls.Conn, interface{ ConnectionState() tls.ConnectionState }:
		return true
	}
	return false
}

// servedConn is what NewListener hands up: the handshaked *tls.Conn plus the moment the raw socket was accepted,
// before the sniff and handshake. The relay's hello timeout counts from that moment (through AcceptedAt), so the two
// timeouts overlap instead of adding up.
type servedConn struct {
	*tls.Conn
	acceptedAt time.Time
}

// AcceptedAt is when the raw connection was accepted from the listener.
func (c *servedConn) AcceptedAt() time.Time { return c.acceptedAt }

// PeerFingerprint is the fingerprint of the leaf certificate the peer presented on conn (a *tls.Conn, or anything
// exposing its TLS state as quicconn.Conn does), or "" when conn is not TLS. The room-code proof (package pake) binds
// to it.
func PeerFingerprint(conn net.Conn) string {
	var state tls.ConnectionState
	switch c := conn.(type) {
	case *tls.Conn:
		state = c.ConnectionState()
	case interface{ ConnectionState() tls.ConnectionState }: // servedConn
		state = c.ConnectionState()
	case interface{ TLSConnectionState() tls.ConnectionState }:
		state = c.TLSConnectionState()
	default:
		return ""
	}
	if len(state.PeerCertificates) == 0 {
		return ""
	}
	return Fingerprint(state.PeerCertificates[0].Raw)
}

// ListenConfig configures NewListener.
type ListenConfig struct {
	// TLS is the server certificate config, from ServerConfig or LoadOrCreateIdentity. Required.
	TLS *tls.Config

	// HandshakeTimeout bounds the sniff plus handshake per connection. Zero means defaultHandshakeTimeout.
	HandshakeTimeout time.Duration

	// Logf receives the throttled lines for refused plaintext connections and failed handshakes. Nil means the
	// standard logger.
	Logf func(format string, args ...any)
}

// NewListener wraps ln so every accepted connection is handshaked as TLS before it is handed up, and one that does
// not begin a TLS handshake is closed with a log line saying so. The sniff and handshake run on a goroutine per
// connection, not inside Accept, so one client that connects and says nothing cannot stall every other.
func NewListener(ln net.Listener, cfg ListenConfig) (net.Listener, error) {
	if cfg.TLS == nil {
		return nil, errors.New("tlsx: NewListener needs a TLS config -- every connection is TLS since 2026-09-15")
	}
	timeout := cfg.HandshakeTimeout
	if timeout <= 0 {
		timeout = defaultHandshakeTimeout
	}
	logf := cfg.Logf
	if logf == nil {
		logf = log.Printf
	}
	l := &sniffListener{
		Listener: ln,
		tlsCfg:   cfg.TLS,
		timeout:  timeout,
		logf:     logf,
		out:      make(chan accepted, 16),
		done:     make(chan struct{}),
		fatal:    make(chan struct{}),
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
	tlsCfg  *tls.Config
	timeout time.Duration
	logf    func(format string, args ...any)

	out       chan accepted
	done      chan struct{}
	closeOnce sync.Once

	// fatal is closed once the inner listener has failed for good, after fatalErr is written (so the close publishes
	// it). Accept is a channel receive, and relay.Serve calls it again on every error, so without this a stopped
	// acceptLoop would leave that caller blocked for the life of the process.
	fatal    chan struct{}
	fatalErr error

	// The refusals are the attack, so they are logged at most once a second, with a count: a line per attempt turns
	// a connection flood into a disk flood. Counted apart, because a plaintext client is an old build or a hand tool,
	// and a failed handshake an attack or a version mismatch.
	plainLine throttle.Line
	shakeLine throttle.Line
}

// notePlaintextRefusal writes the throttled line for a connection that did not begin with a TLS handshake.
// throttle.Line's CompareAndSwap makes the per-connection goroutines racing here produce one line, not several.
func (l *sniffListener) notePlaintextRefusal(addr net.Addr) {
	n, ok := l.plainLine.Allow()
	if !ok {
		return
	}
	l.logf("meshghost: refused a plaintext connection from %s -- every connection is TLS since "+
		"2026-09-15, so this is a client older than that, or a hand tool such as netcat "+
		"(%d refused so far)", addr, n)
}

func (l *sniffListener) noteHandshakeFailure(addr net.Addr, err error) {
	n, ok := l.shakeLine.Allow()
	if !ok {
		return
	}
	l.logf("meshghost: tls handshake with %s failed: %v (%d failed so far)", addr, err, n)
}

func (l *sniffListener) acceptLoop() {
	var backoff time.Duration
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			// A temporary error must not end this loop: relay.Serve retries Accept on one (descriptor exhaustion),
			// and a stopped loop would leave it waiting on a channel nothing sends to. The error is still handed up,
			// since the policy is the caller's; this backoff only stops a caller with none spinning on EMFILE.
			if ne, ok := err.(net.Error); ok && ne.Temporary() { //nolint:staticcheck // the deprecation is about timeouts; EMFILE is exactly what this asks
				l.deliver(accepted{err: err})
				if backoff == 0 {
					backoff = 5 * time.Millisecond
				} else if backoff *= 2; backoff > time.Second {
					backoff = time.Second
				}
				select {
				case <-time.After(backoff):
				case <-l.done:
					return
				}
				continue
			}
			// Permanent: recorded rather than delivered once, so every later Accept gets the same error, not a hang.
			l.fatalErr = err
			close(l.fatal)
			return
		}
		backoff = 0
		go l.classify(c)
	}
}

// classify reads the one byte that decides what this connection is, then refuses it or completes a TLS handshake.
func (l *sniffListener) classify(c net.Conn) {
	acceptedAt := time.Now()
	deadline := acceptedAt.Add(l.timeout)
	_ = c.SetReadDeadline(deadline)

	first := make([]byte, 1)
	n, err := c.Read(first)
	if err != nil || n == 0 {
		// Dropped silently: a port scan and a health check look like this, and a host cannot act on either.
		_ = c.Close()
		return
	}
	_ = c.SetReadDeadline(time.Time{})

	if first[0] != tlsRecordHandshake {
		l.notePlaintextRefusal(c.RemoteAddr())
		_ = c.Close()
		return
	}

	pc := &prefixConn{Conn: c, prefix: first[:n]}
	tc := tls.Server(pc, l.tlsCfg)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	if err := tc.HandshakeContext(ctx); err != nil {
		l.noteHandshakeFailure(c.RemoteAddr(), err)
		_ = c.Close()
		return
	}
	l.deliver(accepted{conn: &servedConn{Conn: tc, acceptedAt: acceptedAt}})
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
	// Connections already sniffed are handed up before a failure: a handshake that completed as the inner listener
	// died is a real player's usable session.
	select {
	case a := <-l.out:
		return a.conn, a.err
	default:
	}
	select {
	case a := <-l.out:
		return a.conn, a.err
	case <-l.fatal:
		return nil, l.fatalErr
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

// prefixConn replays the byte the sniff consumed before delegating to the real connection, so the ClientHello is
// whole.
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

// CloseWrite and TransportName forward for the same reason netx's limitedConn's do: this type embeds net.Conn as an
// interface, which hides them. Only a *tls.Conn sits above it now; they keep the surface of the connection it wraps.
func (c *prefixConn) CloseWrite() error {
	cw, ok := c.Conn.(interface{ CloseWrite() error })
	if !ok {
		return errors.New("tlsx: the underlying connection cannot half-close")
	}
	return cw.CloseWrite()
}

func (c *prefixConn) TransportName() string {
	tn, ok := c.Conn.(interface{ TransportName() string })
	if !ok {
		return "tcp"
	}
	return tn.TransportName()
}
