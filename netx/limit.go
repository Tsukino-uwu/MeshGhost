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
		return &limitedConn{Conn: c, release: func() { l.open.Add(-1) }}, nil
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
