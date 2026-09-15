// Package netx is the transport-selection seam: it turns a transport name
// from config.json ("tcp", "udp", "quic") into an ordinary net.Listener or
// net.Conn, and nothing else.
//
// Everything above this package stays transport-agnostic as a result.
// relay's Serve takes a net.Listener and handleConn a net.Conn, so
// neither changes to gain a transport; transport wraps whatever
// net.Conn it is handed in the same NDJSON framing regardless. That is the
// point of doing the work at this layer rather than by adding a second
// Transport implementation: the relay's per-connection-goroutine model —
// which Client.gateMu's comment in relay leans on when it says
// everything else needs no lock because "OnReceive is serial" — survives
// untouched. See the transport ADR in agent_docs/architecture.md.
//
// This package deliberately has no dependency on protocol,
// core, or relay, the same leaf-package discipline
// transport keeps.
//
// Note for datagram transports: one datagram carries exactly one NDJSON
// line. NDJSON framing is redundant there but harmless, and keeping it
// means a single Transport implementation covers all three.
//
// How this package fits the whole -- the life of a connection and of a state
// message, traced across all of them -- is docs/networking.md.
package netx

import (
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/quicconn"
	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// Kind is a selectable transport. The zero value is TCP, which is both the
// default and the only one that existed before selectable transports — so
// any zero-valued struct keeps the original behaviour.
type Kind int

const (
	// TCP is newline-delimited JSON over a TCP stream. The default, and
	// the only transport that can be read with netcat or a packet capture
	// — see docs/security.md's transport section.
	TCP Kind = iota

	// UDP is one datagram per NDJSON line, with delivery guaranteed only
	// for messages sent via Transport.Send. It cannot be encrypted: Go's
	// standard library has no DTLS, so a room code on this transport
	// crosses the wire in the clear with no way to fix it. Use QUIC if
	// encryption matters.
	UDP

	// QUIC is one datagram per NDJSON line over a QUIC connection, whose
	// handshake is TLS 1.3 — so it is encrypted and resistant to address
	// spoofing without any extra configuration.
	QUIC

	// Auto is a client-only placeholder: ask the relay what it serves, then
	// use the best of those. It is never a real transport, so Listen and
	// Dial refuse it — core resolves it to a concrete Kind before
	// either is called. See the transport discovery ADR in
	// agent_docs/architecture.md.
	Auto
)

// AutoPreference, the order Auto picks in, lives in udp_release.go (QUIC,
// TCP -- what ships) and udp_dev.go (plus UDP last, under the
// meshghost_devudp tag). ADR 0065.

// ParseKind resolves a transport name from config or a flag. It is
// deliberately strict: an unrecognized value is an error rather than a
// silent fall back to TCP, because a typo would otherwise downgrade the
// transport without saying so. That is the same trap already recorded in
// agent_docs/risks.md for a stale binary silently ignoring room_code.
func ParseKind(s string) (Kind, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "tcp":
		return TCP, nil
	case "udp":
		// A release refuses the name outright (udp_release.go); the dev build
		// accepts it. Refusing rather than falling back to tcp is the same
		// choice the default arm makes for a typo: a transport the user did
		// not get should be an error they see.
		return parseUDPKind()
	case "quic":
		return QUIC, nil
	case "auto":
		return Auto, nil
	default:
		return TCP, fmt.Errorf("netx: unknown transport %q (want tcp, quic, or auto)", s)
	}
}

// ParseKinds resolves a comma-separated list, for the relay, which may
// serve several transports at once. Order is preserved and duplicates are
// dropped. An empty list is an error rather than a default, so a
// misconfigured relay refuses to start instead of quietly listening on
// something the operator did not choose.
func ParseKinds(s string) ([]Kind, error) {
	var out []Kind
	seen := map[Kind]bool{}
	for _, part := range strings.Split(s, ",") {
		if strings.TrimSpace(part) == "" {
			continue
		}
		k, err := ParseKind(part)
		if err != nil {
			return nil, err
		}
		if k == Auto {
			return nil, fmt.Errorf("netx: %q is a client-only setting; a relay must name the transports it serves (tcp, udp, quic)", Auto)
		}
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, k)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("netx: no transport named in %q (want a comma-separated list of tcp, udp, quic)", s)
	}

	// tcp is mandatory and is prepended if the operator left it out. Every
	// client handshakes over tcp before moving to anything else — that is
	// what lets it discover which transports exist and on which ports — so
	// a relay without tcp would be unreachable by every client, including
	// ones configured for the very transports it does serve.
	//
	// Silently adding it rather than refusing to start: the operator asked
	// to serve udp/quic and still gets exactly that, plus the leg that makes
	// them reachable. Found by internal/e2e when a udp-only relay stopped
	// being connectable.
	if !seen[TCP] {
		out = append([]Kind{TCP}, out...)
	}
	return out, nil
}

func (k Kind) String() string {
	switch k {
	case TCP:
		return "tcp"
	case UDP:
		return "udp"
	case QUIC:
		return "quic"
	case Auto:
		return "auto"
	default:
		return fmt.Sprintf("Kind(%d)", int(k))
	}
}

// Listen starts a listener for k on addr.
//
// Every kind returns a plain net.Listener whose Accept yields a net.Conn,
// including the datagram ones — the demultiplexing that makes that true for
// UDP lives in the udpconn subpackage, and QUIC's equivalent in quicconn.
func Listen(k Kind, addr string) (net.Listener, error) {
	return listenWith(k, addr, nil)
}

// listenWith is Listen with the per-source table quic's pending gate needs;
// the other kinds have no pre-Accept window and take it from LimitListener.
func listenWith(k Kind, addr string, sources *srclimit.Table) (net.Listener, error) {
	switch k {
	case TCP:
		return net.Listen("tcp", addr)
	case UDP:
		return udpListen(addr)
	case QUIC:
		return quicconn.ListenWith(addr, quicconn.Options{Sources: sources})
	case Auto:
		return nil, fmt.Errorf("netx: %q is a client-only setting and cannot be listened on — a relay must name the transports it serves", Auto)
	default:
		return nil, fmt.Errorf("netx: unknown transport %v", int(k))
	}
}

// Dial connects to addr over k, bounded by timeout.
func Dial(k Kind, addr string, timeout time.Duration) (net.Conn, error) {
	switch k {
	case TCP:
		return net.DialTimeout("tcp", addr, timeout)
	case UDP:
		return udpDial(addr, timeout)
	case QUIC:
		// quic is TLS by construction, so a dial that verifies nothing is
		// the same downgrade a plaintext tcp dial would be. Refused here
		// rather than trusted; DialWithTLS is the one dial for it.
		return nil, errors.New("netx: quic must be dialed through DialWithTLS, which verifies the relay's certificate")
	case Auto:
		return nil, fmt.Errorf("netx: %q must be resolved to a concrete transport before dialing (core does this via relay discovery)", Auto)
	default:
		return nil, fmt.Errorf("netx: unknown transport %v", int(k))
	}
}

// TLSALPN is the ALPN identifier for MeshGhost's NDJSON protocol carried
// over TLS on the tcp transport. Both ends must agree or the handshake
// fails outright, which is the wanted outcome when something else entirely
// is listening on the port.
const TLSALPN = "meshghost"

// TLSOptions is what every shipped transport needs to be encrypted AND
// verified: the relay's one identity on the listen side, a verifier of it on
// the dial side. It is deliberately separate from Kind: TLS is not a fourth
// transport, it is a property every shipped one has. There is no mode --
// since 2026-09-15 there is nothing to switch (ADR 0066).
//
// tcp is wrapped in tlsx; quic's own handshake is TLS 1.3 and is given the
// same certificate and the same verifier. The tagged dev-only udp transport
// cannot be encrypted (Go's standard library has no DTLS) and ignores every
// field here; it never ships (ADR 0065).
type TLSOptions struct {
	// Server is the listener's identity (tlsx.LoadOrCreateIdentity, or
	// tlsx.ServerConfig in a test). Listen-side, required for tcp and quic
	// -- the caller builds it so it can log the fingerprint and serve one
	// certificate on every listener.
	Server *tls.Config

	// Verify checks the relay's leaf certificate during the dial-side
	// handshake, on tcp and quic alike. Required: a nil verifier is an
	// error, never an unchecked connection. core supplies its known-relays
	// store's verifier; a test says tlsx.TrustAnyCertificate.
	Verify tlsx.Verifier

	// Logf receives the listener's per-connection notices. Nil means the
	// standard logger.
	Logf func(format string, args ...any)

	// MaxOpenConns bounds accepted-and-not-yet-closed connections per
	// listener, counted beneath the TLS layer so handshakes count too; 0
	// means unbounded. Listen-side only. See LimitListener.
	MaxOpenConns int

	// Sources, when set, bounds the same thing PER CLIENT ADDRESS, through
	// every listener that shares the table -- and quic's pending gate, the
	// window before Accept that MaxOpenConns cannot see. Listen-side only.
	// See LimitOptions.Sources and package srclimit.
	Sources *srclimit.Table
}

func (o TLSOptions) logf(format string, args ...any) {
	if o.Logf != nil {
		o.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

// ListenWithTLS is Listen with the relay's identity: tcp is wrapped so
// every accepted connection is a completed TLS handshake (a plaintext one
// is closed, with a throttled log line), and quic serves the same
// certificate. This is the only listen the shipped relay makes.
func ListenWithTLS(k Kind, addr string, opts TLSOptions) (net.Listener, error) {
	if opts.Server == nil && (k == TCP || k == QUIC) {
		return nil, fmt.Errorf("netx: ListenWithTLS(%s) needs the relay's identity in TLSOptions.Server", k)
	}
	var ln net.Listener
	var err error
	if k == QUIC {
		ln, err = quicconn.ListenWith(addr, quicconn.Options{TLS: opts.Server, Sources: opts.Sources})
	} else {
		ln, err = listenWith(k, addr, opts.Sources)
	}
	if err != nil {
		return nil, err
	}
	// Before the TLS wrap, so a connection parked in its handshake counts.
	ln = LimitListenerWith(ln, LimitOptions{Max: opts.MaxOpenConns, Sources: opts.Sources, Logf: opts.logf})
	if k != TCP {
		return ln, nil
	}
	wrapped, err := tlsx.NewListener(ln, tlsx.ListenConfig{
		TLS:  opts.Server,
		Logf: opts.Logf,
	})
	if err != nil {
		_ = ln.Close()
		return nil, err
	}
	return wrapped, nil
}

// DialWithTLS is the one dial a client makes: tcp handshaked through tlsx,
// quic through its own TLS 1.3 handshake, both verified by opts.Verify.
//
// The rule is the whole security-relevant part, so it is stated plainly: a
// client NEVER falls back to plaintext, and never accepts a certificate its
// verifier did not. A relay that cannot complete a handshake gets no bytes,
// not even a hello.
//
// Until 2026-09-15 there was an "auto" mode that fell back to plaintext
// once, with a warning, so a client could still reach a relay built before
// TLS existed. The fourth adversarial review (A1) showed what that
// allowance cost: ANY failed handshake took the fallback -- a dropped
// ClientHello, a reset, the 3 s discovery timeout -- and the plaintext
// redial carried the room code, so an on-path party only had to break one
// handshake to read it. And nothing could tell an old relay from that
// party, because a plaintext relay never answers a ClientHello with bytes.
// Every release since 2026-08-19 speaks TLS, so the allowance was
// withdrawn, and the same day the mode went with it (user decision; ADR
// 0066). The tagged dev-only udp transport is the one plaintext dial left,
// and it never ships.
func DialWithTLS(k Kind, addr string, timeout time.Duration, opts TLSOptions) (net.Conn, error) {
	switch k {
	case UDP:
		return Dial(UDP, addr, timeout)
	case QUIC:
		return quicconn.DialWith(addr, timeout, opts.Verify)
	case TCP:
	default:
		return Dial(k, addr, timeout) // Auto and unknown: the error Dial gives
	}

	conn, err := Dial(TCP, addr, timeout)
	if err != nil {
		return nil, err
	}
	secure, err := tlsx.Client(conn, TLSALPN, opts.Verify, timeout)
	if err != nil {
		return nil, fmt.Errorf("netx: the relay at %s did not complete a TLS handshake (%w). This client "+
			"never sends an unencrypted byte, because the room code would cross the network readable; "+
			"either the server is older than 2026-08-19, or something between you and it is "+
			"interfering.", addr, err)
	}
	return secure, nil
}
