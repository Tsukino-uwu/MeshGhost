package netx

import (
	"net"
	"sync"
	"sync/atomic"
	"time"
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
	if max <= 0 {
		return ln
	}
	return &limitListener{Listener: ln, max: int64(max), logf: logf}
}

type limitListener struct {
	net.Listener
	max     int64
	open    atomic.Int64
	refused atomic.Int64
	lastLog atomic.Int64 // unix nanos of the last refusal line
	logf    func(string, ...any)
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
		lc := &limitedConn{Conn: c, release: func() { l.open.Add(-1) }}
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
		l.logf("netx: refused a connection: %d already open (limit %d); %d refused so far", l.max, l.max, n)
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
