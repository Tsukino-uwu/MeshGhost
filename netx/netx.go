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
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/quicconn"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/netx/udpconn"
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

// AutoPreference is the order Auto picks in: the first offered transport
// wins.
//
// QUIC first because it is the only one that is both loss-tolerant and
// encrypted. TCP second. **UDP last, deliberately, even though it shares
// QUIC's loss behaviour** — it cannot be encrypted at all (Go has no DTLS),
// so choosing it automatically would silently downgrade a user's room code
// to plaintext on a relay that also offered quic. Someone who genuinely
// wants udp can still name it explicitly; nothing should pick it on their
// behalf.
var AutoPreference = []Kind{QUIC, TCP, UDP}

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
		return UDP, nil
	case "quic":
		return QUIC, nil
	case "auto":
		return Auto, nil
	default:
		return TCP, fmt.Errorf("netx: unknown transport %q (want tcp, udp, quic, or auto)", s)
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
	switch k {
	case TCP:
		return net.Listen("tcp", addr)
	case UDP:
		return udpconn.Listen(addr)
	case QUIC:
		return quicconn.Listen(addr)
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
		return udpconn.Dial(addr, timeout)
	case QUIC:
		return quicconn.Dial(addr, timeout)
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

// TLSOptions turns TLS on for the tcp transport. It is deliberately
// separate from Kind: TLS is not a fourth transport, it is a property of
// one of them.
//
// The other two are unaffected and cannot be affected. quic's handshake is
// already TLS 1.3, so it satisfies Required by construction. udp cannot be
// encrypted at all (Go's standard library has no DTLS), so Required plus
// udp is an error rather than a silently unencrypted session — the same
// refusal-over-degradation choice ParseKind makes for a typo'd transport
// name.
type TLSOptions struct {
	// Mode is off / auto / required. The zero value is off, so a
	// zero-valued TLSOptions is exactly the pre-TLS behaviour.
	Mode tlsx.Mode

	// Server is the listener's certificate config (tlsx.ServerConfig).
	// Listen-side only, and required when Mode is not off — the caller
	// builds it so it can log the fingerprint and reuse one certificate
	// across the process.
	Server *tls.Config

	// Fingerprint is the client-side pin: the relay's certificate
	// fingerprint, compared out of band. Empty means encryption without
	// authentication. Dial-side only.
	Fingerprint string

	// Logf receives the downgrade warning and the listener's per-connection
	// notices. Nil means the standard logger.
	Logf func(format string, args ...any)
}

func (o TLSOptions) logf(format string, args ...any) {
	if o.Logf != nil {
		o.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

// ListenWithTLS is Listen plus TLS on the tcp transport.
//
// Under tlsx.Auto one port serves TLS and plaintext together, so a relay
// with TLS on is still drivable by hand with netcat. Under tlsx.Required a
// plaintext connection is closed without being handed to the caller.
func ListenWithTLS(k Kind, addr string, opts TLSOptions) (net.Listener, error) {
	ln, err := Listen(k, addr)
	if err != nil {
		return nil, err
	}
	if k != TCP || opts.Mode == tlsx.Off {
		return ln, nil
	}
	wrapped, err := tlsx.NewListener(ln, tlsx.ListenConfig{
		Mode: opts.Mode,
		TLS:  opts.Server,
		Logf: opts.Logf,
	})
	if err != nil {
		_ = ln.Close()
		return nil, err
	}
	return wrapped, nil
}

// DialWithTLS is Dial plus TLS on the tcp transport.
//
// The fallback rule is the whole security-relevant part, so it is stated
// plainly: under tlsx.Required there is no fallback at all — a relay that
// cannot handshake gets no bytes, not even a hello. Under tlsx.Auto a
// failed handshake falls back to plaintext once, with a warning naming the
// downgrade, which is what lets a TLS-configured client still reach a relay
// built before this feature existed. Nothing downgrades quietly.
func DialWithTLS(k Kind, addr string, timeout time.Duration, opts TLSOptions) (net.Conn, error) {
	if opts.Mode == tlsx.Off {
		return Dial(k, addr, timeout)
	}
	if k == UDP && opts.Mode == tlsx.Required {
		return nil, fmt.Errorf("netx: transport udp cannot be encrypted (Go has no DTLS) but tls is %q — choose quic, or tcp with tls, or set tls to off", opts.Mode)
	}
	if k != TCP {
		// quic is already TLS 1.3; udp under auto is unencryptable and
		// stays as it was. Neither has anything for this layer to add.
		return Dial(k, addr, timeout)
	}

	conn, err := Dial(TCP, addr, timeout)
	if err != nil {
		return nil, err
	}
	secure, err := tlsx.Client(conn, TLSALPN, opts.Fingerprint, timeout)
	if err == nil {
		return secure, nil
	}
	if opts.Mode == tlsx.Required {
		return nil, fmt.Errorf("netx: tls is required but the relay at %s did not complete a TLS handshake: %w", addr, err)
	}
	opts.logf("netx: WARNING: the relay at %s does not speak TLS (%v) — falling back to an "+
		"UNENCRYPTED tcp session, so the room code crosses the network in the clear. Set tls to "+
		"\"required\" to refuse this instead.", addr, err)
	return Dial(TCP, addr, timeout)
}
