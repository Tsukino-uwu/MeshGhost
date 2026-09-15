// Package tlsx is TLS for the tcp transport, and the one certificate story
// every MeshGhost transport shares.
//
// It exists because `tcp` is the one leg of a MeshGhost session that is
// always used: every client handshakes over tcp before it moves anywhere
// (see core's resolveTransport and docs/security.md's "How a client
// actually connects"), and that handshake carries the room code. So a
// session on the encrypted `quic` transport still sent its room code across
// the network in the clear, on the discovery leg, before it ever reached
// quic. Encrypting tcp closes that.
//
// # What this protects against, precisely
//
// Since 2026-09-15 there is no plaintext mode and no plaintext fallback: a
// listener refuses a connection that does not begin a TLS handshake, and a
// client sends nothing to a relay it cannot handshake with. The certificate
// is self-signed. What authenticates it is the Verifier the client passes
// to Client: core's known-relays store remembers each relay's fingerprint
// on first connect and checks it afterwards (trust on first use, the SSH
// model, ADR 0066). So:
//
//   - Passive capture -- someone reading traffic on shared wifi, a VPN, an
//     ISP -- is blocked on every connection.
//   - An active man-in-the-middle on the FIRST connection to a relay is not
//     detected: there is nothing yet to compare against. From the second
//     connection on, a changed identity is noticed.
//   - There is no CA anywhere in this design. connect_to is a bare IP, so
//     there is no name a certificate could be checked against.
//
// # Why the sniff stays
//
// A TLS ClientHello starts with the byte 0x16; an NDJSON line starts with
// '{'. NewListener reads exactly one byte before handshaking, so a client
// that speaks plaintext -- a build from before 2026-08-19, or netcat -- is
// refused with a log line that says WHY, rather than with a handshake
// failure that names nothing.
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

// defaultHandshakeTimeout bounds one accepted connection's sniff plus TLS
// handshake. It exists because a handshake is real CPU an unauthenticated
// stranger can ask for: without a bound, N half-open connections each hold
// a goroutine and a socket indefinitely. See agent_docs/ideas.md's note on
// the (still absent) per-IP cap, which is a separate decision.
const defaultHandshakeTimeout = 10 * time.Second

// tlsRecordHandshake is the first byte of a TLS record of type handshake —
// what every ClientHello begins with. No JSON value starts with it, which
// is what makes one-byte sniffing unambiguous here.
const tlsRecordHandshake = 0x16

// certificateValidity is how long a generated certificate is valid for.
// Twenty years: the relay's identity is persisted (identity.go) and nothing
// on the client checks the validity period -- a Verifier compares the
// fingerprint and nothing else -- so this is the one field of the
// certificate a player could never be asked to do anything about.
const certificateValidity = 20 * 365 * 24 * time.Hour

// Verifier decides whether the certificate a relay presented is the relay
// the client meant. It receives the LEAF certificate's DER bytes and nothing
// else -- the one certificate the peer proved possession of during the
// handshake -- and a non-nil error refuses the connection before a byte of
// application data is sent.
//
// ONLY the leaf. InsecureSkipVerify is set (there is no CA), so Go does no
// chain building: rawCerts is whatever DER blobs the peer chose to send,
// and only the FIRST is bound to the handshake signature. Matching against
// any later entry accepted a certificate the peer does not hold the key
// for: an attacker copies the relay's (public) cert, presents
// [attacker_leaf, genuine_relay_cert], and the check passes while the
// session is keyed by attacker_leaf. Found 2026-09-07, when the check was
// still a pin.
type Verifier func(leafDER []byte) error

// TrustAnyCertificate is the Verifier that accepts every certificate.
//
// FOR TESTS AND DEV TOOLS ONLY. It is what a test uses to reach a listener
// whose certificate it did not generate, and what cmd/meshghost-netsim
// uses to stand between two ends it owns. No shipped client path uses it:
// core always verifies through its known-relays store, and a nil Verifier
// is an error rather than this.
func TrustAnyCertificate([]byte) error { return nil }

// newCertificate generates a fresh Ed25519 self-signed certificate and
// returns it with its fingerprint.
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

// certificateFor self-signs a certificate for an Ed25519 key pair. Split
// from newCertificate so the identity loader can rebuild one for a key it
// read from disk; note the SERIAL is random, so two certificates for the
// same key have different fingerprints -- which is why identity.go persists
// the certificate as well as the key.
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

// keyLogWriter, when a dev build sets it (keylog_dev.go), receives every
// session's secrets in Wireshark's NSS key log format. Nil in a release.
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

// ServerConfig builds a listener's TLS configuration around a freshly
// generated in-memory Ed25519 certificate, and returns the certificate's
// fingerprint alongside it.
//
// This is the in-memory identity: a TEST's relay, or a tool that lives for
// one run. The shipped relay loads a persisted one with
// LoadOrCreateIdentity instead, so a client can recognize it across
// restarts. Call either once per process and reuse the result: generating
// a key per connection would hand an unauthenticated stranger a free CPU
// lever.
func ServerConfig(alpn string) (*tls.Config, string, error) {
	cert, fp, err := newCertificate()
	if err != nil {
		return nil, "", err
	}
	return configFor(cert, alpn), fp, nil
}

// Fingerprint is the SHA-256 of a certificate's DER bytes, lower-case hex
// with no separators: the string a relay prints at startup, the string a
// client remembers in known_servers.json, and the only thing that
// identifies a relay.
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

// clientConfig builds a dialer's TLS configuration around a Verifier.
//
// InsecureSkipVerify is set on purpose and is not a shortcut: "connect_to"
// is a bare IP a friend sent you, so there is no CA and no hostname a
// certificate could be checked against. Verification is the Verifier,
// applied to the leaf certificate only (see Verifier for why only).
func clientConfig(alpn string, verify Verifier) *tls.Config {
	cfg := &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS13,
		KeyLogWriter:       keyLogWriter,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("tlsx: the relay presented no certificate")
			}
			return verify(rawCerts[0])
		},
	}
	if alpn != "" {
		cfg.NextProtos = []string{alpn}
	}
	return cfg
}

// ClientConfig is clientConfig for a caller that drives its own handshake
// -- quicconn, whose dial is quic-go's rather than crypto/tls's. A nil
// verifier is an error there for the same reason it is in Client.
func ClientConfig(alpn string, verify Verifier) (*tls.Config, error) {
	if verify == nil {
		return nil, errors.New("tlsx: no certificate verifier -- a nil Verifier would accept anyone; " +
			"pass TrustAnyCertificate explicitly if that is what you mean")
	}
	return clientConfig(alpn, verify), nil
}

// FingerprintHexLen is the length of a normalized fingerprint: SHA-256 as
// hex.
const FingerprintHexLen = 64

// NormalizeFingerprint accepts the shapes a human might write: with or
// without colons, spaces or upper case. It is what the known-relays store
// parses its file with, so a hand-edited entry compares equal to the
// relay's own print of the same value.
//
// It is picky about LENGTH. Until 2026-09-15 it silently dropped every
// non-hex rune and returned whatever was left, so a placeholder such as
// "<paste here>" normalized to the empty string, which then meant "no pin"
// (fourth adversarial review, A2). An empty input still normalizes to the
// empty string; anything else must come out as exactly FingerprintHexLen
// hex digits or it is an error.
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

// Client wraps an already-dialed connection in TLS and completes the
// handshake before returning, so a failure surfaces here rather than
// halfway through the first Send. On failure the underlying connection is
// closed — the caller has nothing usable left.
//
// verify is applied to the relay's leaf certificate during the handshake;
// nil is an error, closed before a byte is sent. There is deliberately no
// "just encrypt" spelling here: a caller that wants that says
// TrustAnyCertificate, in a place a reviewer can grep for.
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

// servedConn is what NewListener hands up: the handshaked *tls.Conn plus
// the moment the raw socket was accepted, BEFORE the sniff and the
// handshake. The relay's hello timeout counts from that moment
// (Server.handleConn asks through AcceptedAt), so the sniff's own timeout
// and the hello timeout overlap instead of adding up: until 2026-09-15 a
// stranger could hold a socket for the sniff's 10 s and then the hello
// timer's 10 s, twice what the contract promised (third adversarial
// review, P1b; found again by the fourth's harness).
type servedConn struct {
	*tls.Conn
	acceptedAt time.Time
}

// AcceptedAt is when the raw connection was accepted from the listener.
func (c *servedConn) AcceptedAt() time.Time { return c.acceptedAt }

// PeerFingerprint is the fingerprint of the leaf certificate the peer
// presented on conn -- a *tls.Conn, or anything exposing its TLS state the
// way quicconn.Conn does -- or "" when conn is not TLS. It is what the
// room-code proof binds to (package pake): the identity a client names is
// the certificate it actually verified on this connection.
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
	// TLS is the server certificate config, from ServerConfig or
	// LoadOrCreateIdentity. Required.
	TLS *tls.Config

	// HandshakeTimeout bounds the sniff plus handshake per connection.
	// Zero means defaultHandshakeTimeout.
	HandshakeTimeout time.Duration

	// Logf receives one line per refused plaintext connection and per
	// failed handshake, throttled. Nil means the standard logger.
	Logf func(format string, args ...any)
}

// NewListener wraps ln so every accepted connection is handshaked as TLS
// before it is handed up, and a connection that does not begin a TLS
// handshake is closed with a log line saying so.
//
// The sniff and the handshake happen on a per-connection goroutine, not
// inside Accept. That matters: doing it in Accept would let one client that
// connects and then says nothing stall every other client for the whole
// handshake timeout, which is a denial of service anyone can perform with
// netcat.
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

	// fatal is closed once the inner listener has failed for good, with
	// fatalErr written before the close (so the close publishes it). It
	// exists because Accept is a channel receive: once acceptLoop has
	// stopped there is nothing left to send, and a caller that calls Accept
	// again -- which relay.Serve does on every error -- would block on that
	// channel for the life of the process. See acceptLoop.
	fatal    chan struct{}
	fatalErr error

	// THE REFUSALS ARE THE ATTACK, so they are counted and logged at most once
	// a second rather than once each. Both lines this listener writes about a
	// stranger -- a plaintext connection, and a handshake that failed -- were
	// one line per attempt, from an unauthenticated source, on a port that
	// exists to be reached from the internet. A machine opening connections
	// in a loop therefore turned a connection flood into a disk flood, with
	// the host's own log as the amplifier. netx.limitListener and quicconn's
	// notePendingRefusal both cap the same class the same way and have said
	// so in a comment since they shipped; this listener is the one place that
	// did not. Found by the pre-auth cell of the third adversarial review
	// (P1b-2, 2026-09-12).
	//
	// Counted separately because they mean different things: a plaintext
	// client is an old build or a hand tool, and a failed handshake may be an
	// attack or a version mismatch, and an operator reading one line an hour
	// needs to know which they have.
	plainLine throttle.Line
	shakeLine throttle.Line
}

// notePlaintextRefusal writes the throttled line for a connection that did
// not begin with a TLS handshake. The CompareAndSwap inside throttle.Line is
// what makes two per-connection goroutines racing here produce one line
// rather than two -- this listener handshakes on a goroutine per
// connection, so unlike limitListener's Accept loop there is no single
// writer.
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
			// A TEMPORARY error must not end this loop. relay.Serve
			// deliberately backs off and RETRIES on ne.Temporary() (added
			// 2026-09-02 so descriptor exhaustion could not take the relay
			// down), and until 2026-09-08 this loop returned on the first
			// error of any kind and delivered it exactly once: the retried
			// Accept then selected on a channel nothing would ever send to
			// again and parked forever. The relay logged one "retrying"
			// line and silently stopped accepting tcp for the rest of the
			// process while existing rooms kept working, so it looked
			// alive. This wrapper is always in the relay's tcp path.
			//
			// The error is still handed up rather than swallowed: the
			// backoff-and-log policy belongs to the caller, and this
			// wrapper exists to sniff bytes, not to make that decision. The
			// small backoff here is only so a caller with no policy of its
			// own cannot spin this loop on a repeating EMFILE.
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
			// Permanent: the listener is closed or the socket is gone.
			// Recorded rather than delivered once, so every later Accept
			// gets the same real error instead of hanging.
			l.fatalErr = err
			close(l.fatal)
			return
		}
		backoff = 0
		go l.classify(c)
	}
}

// classify reads the one byte that decides what this connection is, then
// either refuses it or completes a TLS handshake on it.
func (l *sniffListener) classify(c net.Conn) {
	acceptedAt := time.Now()
	deadline := acceptedAt.Add(l.timeout)
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
	// Connections already sniffed are handed up before the failure is
	// reported: a handshake that completed just as the inner listener died
	// is a usable session, and losing it would drop a real player.
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

// CloseWrite and TransportName forward for the same reason limitedConn's do
// (see netx/limit.go): this type embeds net.Conn as an interface, so
// without them anything that unwraps to it loses the limiter's half-close
// and transport label. Until 2026-09-15 a plaintext client was handed up
// wrapped in one of these, and that is where the loss showed (found
// 2026-09-07); today only a *tls.Conn sits above it, and the methods stay
// so the type keeps the same surface as the connection it wraps.
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
