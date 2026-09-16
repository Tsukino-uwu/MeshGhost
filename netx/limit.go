package netx

import (
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
)

// LimitListener bounds how many connections accepted from ln may be open at
// once. Past max, a new connection is closed immediately rather than handed to
// the caller -- and rather than queued, which is what x/net/netutil's version
// does: a queued stranger still holds a kernel socket, and the relay's
// per-connection timers never start for it, so the cap would bound memory
// but not descriptors.
//
// Why this exists: the relay's MaxClients counts JOINED clients. Nothing
// counted a connection that had been accepted and not yet said hello, and
// each of those costs a goroutine, a read buffer, a socket and a timer for up
// to HelloTimeout -- or, under TLS, a handshake goroutine before the relay
// even sees it. So a stranger could hold thousands open from one machine at
// a few bytes each, and past the descriptor limit Accept itself failed.
// Found by the 2026-09-02 adversarial review. Applied UNDER the TLS layer so
// that handshaking connections count too.
//
// A refusal is logged at most once per second: the refusals are the attack,
// and a line per refusal would turn a connection flood into a disk flood.
func LimitListener(ln net.Listener, max int, logf func(string, ...any)) net.Listener {
	return LimitListenerWith(ln, LimitOptions{Max: max, Logf: logf})
}

// LimitOptions configures LimitListenerWith.
type LimitOptions struct {
	// Max bounds open connections across the whole listener; 0 means the
	// listener is returned untouched.
	Max int
	// Sources, when set, additionally bounds open connections PER CLIENT
	// ADDRESS (srclimit.Options.MaxOpenPerSource). A global cap alone is
	// what one machine walks straight through: hold all Max sockets from
	// one address and every real player is refused with a bare close
	// (fourth adversarial review, 2026-09-13, finding A5). The table is
	// shared with the other listeners and with the relay's room-code
	// guard so one address is one source everywhere; ADR 0064.
	Sources *srclimit.Table
	// Logf receives the throttled refusal lines. Nil means none.
	Logf func(string, ...any)
}

// LimitListenerWith is LimitListener with a per-source bound too.
func LimitListenerWith(ln net.Listener, o LimitOptions) net.Listener {
	if o.Max <= 0 {
		return ln
	}
	return &limitListener{Listener: ln, max: int64(o.Max), sources: o.Sources, logf: o.Logf}
}

type limitListener struct {
	net.Listener
	max     int64
	sources *srclimit.Table
	open    atomic.Int64
	refused atomic.Int64
	lastLog atomic.Int64 // unix nanos of the last refusal line
	// The per-source refusals get their own count and throttle: the line
	// prints different numbers (this address's cap, not the listener's),
	// and folding them into one would either misreport the numbers or let
	// one kind of flood silence the other's line.
	refusedSource atomic.Int64
	lastSourceLog atomic.Int64
	logf          func(string, ...any)
}

// Open reports how many accepted connections are currently open. For tests.
func (l *limitListener) Open() int { return int(l.open.Load()) }

func (l *limitListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if l.open.Add(1) > l.max {
			l.open.Add(-1)
			_ = c.Close()
			l.noteRefusal()
			continue
		}
		// The address is taken ONCE, here, and the release closure keeps it:
		// Close runs the underlying Close before release (limitedConn.Close),
		// and what RemoteAddr returns on a closed connection is not something
		// three different net.Conn implementations promise.
		var release func()
		if l.sources != nil {
			addr := c.RemoteAddr()
			if !l.sources.Acquire(addr) {
				l.open.Add(-1)
				_ = c.Close()
				l.noteSourceRefusal()
				continue
			}
			release = func() {
				l.open.Add(-1)
				l.sources.Release(addr)
			}
		} else {
			release = func() { l.open.Add(-1) }
		}
		lc := &limitedConn{Conn: c, release: release}
		if uw, ok := c.(unreliableWriter); ok {
			return &limitedLossyConn{limitedConn: lc, uw: uw}, nil
		}
		return lc, nil
	}
}

func (l *limitListener) noteRefusal() {
	n := l.refused.Add(1)
	now := time.Now().UnixNano()
	last := l.lastLog.Load()
	if now-last < int64(time.Second) || !l.lastLog.CompareAndSwap(last, now) {
		return
	}
	if l.logf != nil {
		l.logf("netx: refused a connection: %d already open (limit %d); %d refused so far",
			l.open.Load(), l.max, n)
	}
}

// noteSourceRefusal logs a per-address refusal at most once a second, by
// count only -- the address itself is never printed (docs/security.md's
// privacy section; the table keeps it in memory and nowhere else).
func (l *limitListener) noteSourceRefusal() {
	n := l.refusedSource.Add(1)
	now := time.Now().UnixNano()
	last := l.lastSourceLog.Load()
	if now-last < int64(time.Second) || !l.lastSourceLog.CompareAndSwap(last, now) {
		return
	}
	if l.logf != nil {
		l.logf("netx: refused a connection: its address already holds as many as one address may; "+
			"%d refused so far for that reason", n)
	}
}

type limitedConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *limitedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}

// CloseWrite and TransportName forward through the wrapper for the same reason
// limitedLossyConn exists: limitedConn embeds net.Conn as an INTERFACE, so a
// method the underlying connection has but net.Conn does not is invisible to
// the type assertions that look for it. Two shipped consequences, both found
// 2026-09-07:
//
//   - transport.CloseGracefully asserts for CloseWrite and falls back to a hard
//     Close when it is missing. The relay wraps EVERY accepted connection in a
//     limiter, so every reject the relay wrote -- wrong room code, version
//     mismatch, rate limited -- was lost to a TCP reset behind the unread data
//     instead of reaching the client, which then classified a PERMANENT refusal
//     as a transport error and retried it forever.
//   - relay's transportName asserts for TransportName and defaults to "tcp", so
//     every udp and quic client was logged as "tcp" in the per-client line a
//     remote tester is asked to send back.
//
// Both return the underlying behaviour when it exists and today's fallback when
// it does not, so a connection that genuinely cannot half-close still ends in
// Close, exactly as before.
func (c *limitedConn) CloseWrite() error {
	cw, ok := c.Conn.(interface{ CloseWrite() error })
	if !ok {
		return errors.New("netx: the underlying connection cannot half-close")
	}
	return cw.CloseWrite()
}

func (c *limitedConn) TransportName() string {
	tn, ok := c.Conn.(interface{ TransportName() string })
	if !ok {
		return "tcp"
	}
	return tn.TransportName()
}

// AcceptedAt and MaxPayloadBytes forward for the same reason (pass 5 of the
// adversarial review, 2026-09-16, P1d-1): the limiter wraps every quic
// connection above quicconn, so the relay's hello timer could not see when a
// quic connection was accepted and restarted its window at the first stream.
// Zero values are the relay's own fallbacks: the whole window, no datagram
// bound. Test: TestLimitListenerForwardsTheOptionalMethods.
func (c *limitedConn) AcceptedAt() time.Time {
	a, ok := c.Conn.(interface{ AcceptedAt() time.Time })
	if !ok {
		return time.Time{}
	}
	return a.AcceptedAt()
}

func (c *limitedConn) MaxPayloadBytes() int {
	m, ok := c.Conn.(interface{ MaxPayloadBytes() int })
	if !ok {
		return 0
	}
	return m.MaxPayloadBytes()
}

// unreliableWriter is the state plane's fire-and-forget escape hatch, as the
// transport package discovers it: by type assertion on the net.Conn, which is
// exactly what an embedded-interface wrapper defeats.
type unreliableWriter interface {
	WriteUnreliable(p []byte) (int, error)
}

// limitedLossyConn is limitedConn for a connection that also has an
// unreliable write -- the quic and udp transports. It exists because
// limitedConn embeds net.Conn as an INTERFACE, so the underlying
// connection's WriteUnreliable is hidden behind it: transport.SendUnreliable
// asserts for the method, finds nothing, and falls back to the reliable
// stream. That is what happened the night the limiter shipped (2026-09-02):
// every state the relay forwarded over quic rode the ordered stream, so one
// lost or reordered packet stalled every sample behind it for a round trip,
// and a TEVI ghost through meshghost-netsim at 2% loss snapped every few
// seconds at any interpolation delay. The datagram path is the reason quic
// is worth serving at all (quicconn's package doc), and this wrapper is what
// keeps it reachable through the limiter. Test: TestLimitListenerKeepsTheUnreliableWrite.
type limitedLossyConn struct {
	*limitedConn
	uw unreliableWriter
}

func (c *limitedLossyConn) WriteUnreliable(p []byte) (int, error) {
	return c.uw.WriteUnreliable(p)
}
