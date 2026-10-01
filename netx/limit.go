package netx

import (
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
)

// LimitListener bounds how many connections accepted from ln may be open at once. Past max, a new connection is
// closed at once rather than queued (as x/net/netutil does): a queued stranger still holds a kernel socket, so the cap
// would bound memory but not descriptors.
//
// The relay's MaxClients counts joined clients only, and each connection not yet past its hello costs a goroutine, a
// buffer, a socket and a timer, so this is applied beneath TLS, where handshaking connections count too. A refusal is
// logged at most once a second: the refusals are the attack, and a line each would turn it into a disk flood.
func LimitListener(ln net.Listener, max int, logf func(string, ...any)) net.Listener {
	return LimitListenerWith(ln, LimitOptions{Max: max, Logf: logf})
}

// LimitOptions configures LimitListenerWith.
type LimitOptions struct {
	// Max bounds open connections across the whole listener; 0 means the listener is returned untouched.
	Max int
	// Sources, when set, also bounds open connections per client address (srclimit.Options.MaxOpenPerSource), so one
	// machine cannot hold all Max and lock every player out. The table is shared with the other listeners and the
	// relay's room-code guard, so one address is one source everywhere.
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
	// Per-source refusals have their own count and throttle so one kind of flood cannot silence the other's line.
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
		// The address is taken once, here: release runs after the underlying Close, and RemoteAddr on a closed
		// connection is not something every net.Conn implementation promises.
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

// noteSourceRefusal logs a per-address refusal at most once a second, by count only: the address is never printed.
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

// CloseWrite and TransportName forward because limitedConn embeds net.Conn as an interface, which hides every method
// net.Conn lacks from the type assertions that look for it: without CloseWrite the relay's rejects are lost to a
// reset, and without TransportName every client is logged as tcp. Each falls back as if the method were missing.
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

// AcceptedAt and MaxPayloadBytes forward for the same reason, so the relay's hello timer sees when a quic connection
// was accepted. Zero values are the relay's own fallbacks: the whole window, no datagram bound.
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

// unreliableWriter is the state plane's fire-and-forget write, which transport finds by type assertion on the
// net.Conn.
type unreliableWriter interface {
	WriteUnreliable(p []byte) (int, error)
}

// limitedLossyConn is limitedConn for a connection that also has an unreliable write (quic, udp). Without it the
// embedded interface hides WriteUnreliable, and transport.SendUnreliable falls back to the ordered stream, where one
// lost packet stalls every state behind it.
type limitedLossyConn struct {
	*limitedConn
	uw unreliableWriter
}

func (c *limitedLossyConn) WriteUnreliable(p []byte) (int, error) {
	return c.uw.WriteUnreliable(p)
}
