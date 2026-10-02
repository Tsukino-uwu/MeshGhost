// Package transport provides NDJSON framing over any net.Conn (tcp, udpconn and quicconn alike). It knows no message
// shape and moves bytes, one JSON-line payload at a time. core and relay both use the Transport interface, for the
// relay connection and the adapter bridge alike, over different sockets.
//
// This package has no internal dependencies.
package transport

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// DefaultMaxLineBytes bounds one NDJSON line before its delimiter is found, enforced during the read by
	// bufio.Scanner's max token size, so a peer streaming bytes with no newline cannot grow memory without bound. It is
	// generous above any legitimate message; the relay's accepted connections and the core's dialed one pass the
	// smaller protocol.MaxLineBytes.
	DefaultMaxLineBytes = 64 * 1024

	// overflowHeadBytes is how much of an oversized line the error keeps: enough to name the message, and small
	// because a relay logs it, quoted, before any hello.
	overflowHeadBytes = 96

	// DefaultIdleTimeout closes a connection that has not delivered a complete line within this long, refreshed after
	// every line, so one that never finishes a line is not held open forever.
	DefaultIdleTimeout = 60 * time.Second

	// DefaultWriteTimeout bounds one Send, so a peer that stops reading cannot block the writer forever.
	DefaultWriteTimeout = 10 * time.Second

	// DefaultDialTimeout bounds the TCP connect in Dial; net.Dial has no timeout of its own.
	DefaultDialTimeout = 10 * time.Second
)

// Transport is the swappable network boundary core and relay depend on. Adapters never hold one; bridge is their side.
type Transport interface {
	// Send writes one payload as a single NDJSON line, reliably on every transport, so a caller that knows nothing of
	// SendUnreliable is always correct.
	Send(payload []byte) error

	// SendUnreliable writes one payload with no delivery guarantee, for the lossy latest-wins state plane only. A
	// transport with no unreliable mode (TCP) implements it as Send.
	SendUnreliable(payload []byte) error

	// OnReceive registers the callback invoked once per received line, replacing any earlier one.
	OnReceive(func(payload []byte))

	// OnDisconnect and OnError report the connection ending and its errors. There is no OnConnect: the read loop
	// starts before Dial or FromConn returns, so it would race its own registration.
	OnDisconnect(func(err error))
	OnError(func(err error))

	// Close releases the underlying connection.
	Close() error
}

// NDJSONConn is the Transport over any net.Conn (tcp, udpconn, quicconn), one JSON payload per line. It wraps one
// established connection and neither redials nor heartbeats: only the dialing core has anywhere to redial to, and
// ping and pong are protocol messages that core and relay handle. A dead peer is found by the idle timeout.
type NDJSONConn struct {
	conn net.Conn

	// MaxLineBytes, IdleTimeout and WriteTimeout are the connection's limits: MaxLineBytes <= 0 or a zero timeout means
	// the Default* value, and a negative timeout disables it. Set them through FromConnWithLimits or DialWithLimits:
	// the read loop is already running when FromConn returns, so setting them afterwards races it.
	MaxLineBytes int
	IdleTimeout  time.Duration
	WriteTimeout time.Duration

	// drainUntil, when set, is the read deadline readLoop uses instead of the idle timeout: CloseGracefully has
	// half-closed the socket and the loop only drains what the peer already sent, so the close arrives as a FIN, not a
	// reset. Guarded by drainMu.
	drainMu    sync.Mutex
	drainUntil time.Time

	writeMu sync.Mutex
	// writeBuf is Send's scratch space for joining payload and '\n' into one Write, guarded by writeMu and reused so
	// the state path does not allocate per message.
	writeBuf []byte

	cbMu         sync.Mutex
	onReceive    func(payload []byte)
	onDisconnect func(err error)
	onError      func(err error)

	// deliverMu serializes callback delivery (cbMu guards the fields) so a backlog flushed by OnReceive cannot
	// interleave with a payload readLoop is delivering. Held across the callback, which is safe because no callback
	// re-registers OnReceive on its own connection.
	deliverMu sync.Mutex
	// pending holds payloads that arrived before OnReceive was registered: the read loop starts before FromConn
	// returns, and the relay installs its callback after FromConnWithLimits, so a fast hello would otherwise be lost.
	pending [][]byte

	closeOnce sync.Once
	// closed is set the moment this connection closes for any reason (Close, CloseGracefully, a failed write, the read
	// loop ending), so a caller sees a dead socket before the disconnect callback, which waits on the read loop.
	closed atomic.Bool
}

var _ Transport = (*NDJSONConn)(nil)

// bufferProbe, when set by a test, is told how many bytes the read loop's scanner holds each time it looks for a line,
// so a test can measure what bounds the buffer and not only what is delivered. Nil in production: one atomic load per
// split call. Atomic because a test sets and clears it while earlier read loops may still be running.
var bufferProbe atomic.Pointer[func(n int)]

// Dial connects to addr over TCP, bounded by DefaultDialTimeout, and starts the read loop at once. Register callbacks
// right after it returns: lines that arrive first are held for OnReceive, but a disconnect before OnDisconnect is
// registered goes unreported.
func Dial(addr string) (*NDJSONConn, error) {
	return DialWithLimits(addr, DefaultMaxLineBytes, DefaultIdleTimeout, DefaultWriteTimeout)
}

// DialWithLimits is Dial with the limits set before the read loop starts, as in FromConnWithLimits.
func DialWithLimits(addr string, maxLineBytes int, idleTimeout, writeTimeout time.Duration) (*NDJSONConn, error) {
	conn, err := net.DialTimeout("tcp", addr, DefaultDialTimeout)
	if err != nil {
		return nil, err
	}
	return FromConnWithLimits(conn, maxLineBytes, idleTimeout, writeTimeout), nil
}

// FromConn wraps an established connection, typically one from a listener's Accept, and starts its read loop with the
// Default* limits. The same callback-registration caveat as Dial applies; for other limits use FromConnWithLimits.
func FromConn(conn net.Conn) *NDJSONConn {
	return FromConnWithLimits(conn, DefaultMaxLineBytes, DefaultIdleTimeout, DefaultWriteTimeout)
}

// FromConnWithLimits is FromConn with MaxLineBytes, IdleTimeout and WriteTimeout set before the read loop starts.
// maxLineBytes <= 0 means DefaultMaxLineBytes; a zero timeout means its default and a negative one disables it.
func FromConnWithLimits(conn net.Conn, maxLineBytes int, idleTimeout, writeTimeout time.Duration) *NDJSONConn {
	c := &NDJSONConn{
		conn:         conn,
		MaxLineBytes: maxLineBytes,
		IdleTimeout:  idleTimeout,
		WriteTimeout: writeTimeout,
	}
	go c.readLoop()
	return c
}

func (c *NDJSONConn) readLoop() {
	maxLine := c.MaxLineBytes
	if maxLine <= 0 {
		maxLine = DefaultMaxLineBytes
	}
	idle := c.IdleTimeout
	if idle < 0 {
		idle = 0
	} else if idle == 0 {
		idle = DefaultIdleTimeout
	}

	scanner := bufio.NewScanner(c.conn)
	initial := maxLine
	if initial > 4096 {
		initial = 4096
	}
	scanner.Buffer(make([]byte, initial), maxLine)
	// overflowHead keeps the start of a line about to fail with ErrTooLong: scanner.Bytes() means something only after
	// a successful Scan, so the split function, which sees the full buffer, is the last look at those bytes.
	var overflowHead []byte
	scanner.Split(func(data []byte, atEOF bool) (int, []byte, error) {
		if probe := bufferProbe.Load(); probe != nil {
			(*probe)(len(data))
		}
		advance, token, err := bufio.ScanLines(data, atEOF)
		if atEOF && err == nil && token != nil && bytes.IndexByte(data[:advance], '\n') < 0 {
			// A torn tail is not a message: bytes left at EOF with no newline are the front of a line whose sender's
			// write deadline expired mid-line (Send closes on that), so they are consumed with no token.
			return len(data), nil, nil
		}
		if advance == 0 && token == nil && err == nil && len(data) >= maxLine && overflowHead == nil {
			n := len(data)
			if n > overflowHeadBytes {
				n = overflowHeadBytes
			}
			overflowHead = append([]byte(nil), data[:n]...)
		}
		return advance, token, err
	})

	for {
		c.drainMu.Lock()
		drainUntil := c.drainUntil
		c.drainMu.Unlock()
		if !drainUntil.IsZero() {
			_ = c.conn.SetReadDeadline(drainUntil)
		} else if idle > 0 {
			_ = c.conn.SetReadDeadline(time.Now().Add(idle))
		}

		if !scanner.Scan() {
			err := scanner.Err()
			if err == nil {
				err = io.EOF
			}
			if !drainUntil.IsZero() {
				// A drain ending, by the peer's FIN or the drain deadline, is the close CloseGracefully already chose.
				err = io.EOF
			}
			if errors.Is(err, bufio.ErrTooLong) && overflowHead != nil {
				// Without the head, "token too long" says a line was oversized but not which.
				err = fmt.Errorf("%w (line head: %q)", err, overflowHead)
			}
			c.fail(err)
			return
		}

		// Copy: scanner.Bytes() aliases a buffer the next Scan reuses, and callers may keep the payload.
		payload := append([]byte(nil), bytes.TrimRight(scanner.Bytes(), "\r")...)

		c.deliverMu.Lock()
		c.cbMu.Lock()
		onReceive := c.onReceive
		c.cbMu.Unlock()
		if onReceive != nil {
			onReceive(payload)
		} else {
			c.pending = append(c.pending, payload)
		}
		c.deliverMu.Unlock()
	}
}

// fail reports a terminal read error through OnError (unless EOF) and OnDisconnect, then closes the connection, since
// the read loop itself may end a connection (an oversized line, an idle timeout) that no caller would otherwise close.
func (c *NDJSONConn) fail(err error) {
	// A close this side made has logged its own reason, so it is not reported again. The test is the closed flag, not
	// net.ErrClosed: a datagram peer cannot hang up, so every terminal failure there (udp retry exhaustion, a quic idle
	// timeout) ends in a local close, and quic-go's errors match net.ErrClosed on purpose.
	if err != io.EOF && !(errors.Is(err, net.ErrClosed) && c.closed.Load()) {
		c.cbMu.Lock()
		onError := c.onError
		c.cbMu.Unlock()
		if onError != nil {
			onError(err)
		}
	}

	c.cbMu.Lock()
	onDisconnect := c.onDisconnect
	c.cbMu.Unlock()
	if onDisconnect != nil {
		onDisconnect(err)
	}

	_ = c.Close()
}

// Send writes payload as a single NDJSON line, bounded by WriteTimeout so a peer that stops reading cannot block the
// caller forever. payload must not contain a newline; marshalled JSON never does.
func (c *NDJSONConn) Send(payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	writeTimeout := c.WriteTimeout
	if writeTimeout < 0 {
		writeTimeout = 0
	} else if writeTimeout == 0 {
		writeTimeout = DefaultWriteTimeout
	}
	if writeTimeout > 0 {
		_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
		defer c.conn.SetWriteDeadline(time.Time{})
	}

	// One Write, not two: a datagram transport would send the payload and its '\n' as two datagrams.
	c.writeBuf = append(c.writeBuf[:0], payload...)
	c.writeBuf = append(c.writeBuf, '\n')
	_, err := c.conn.Write(c.writeBuf)
	if err != nil && !writeNeverHappened(err) {
		// A deadline can expire with the line half-written, and NDJSON cannot resynchronize, so close. closed is set
		// first because the peer sees the reset before this returns. A write that never happened put no byte on the
		// wire, so nothing is mis-framed.
		c.closed.Store(true)
		_ = c.conn.Close()
	}
	return err
}

// writeNeverHappened reports whether err says the connection refused the message before putting any of it on the
// wire, as udpconn does with a payload too large for one datagram: one skipped message, not a dropped player. A
// structural interface because this package cannot import netx; a net.Conn that never claims it gets the safe answer.
func writeNeverHappened(err error) bool {
	var nw interface{ NotWritten() bool }
	return errors.As(err, &nw) && nw.NotWritten()
}

// SendUnreliable sends payload with no delivery guarantee, for the lossy latest-wins state plane, where a lost sample
// is superseded rather than missed. Reliability is opt-out so a call site that never learns of this stays correct:
// only the state hot paths give it up, since a dropped leave would strand a ghost. Over TCP it is Send; a datagram
// net.Conn opts in by implementing unreliableWriter.
func (c *NDJSONConn) SendUnreliable(payload []byte) error {
	uw, ok := c.conn.(unreliableWriter)
	if !ok {
		return c.Send(payload)
	}

	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	writeTimeout := c.WriteTimeout
	if writeTimeout < 0 {
		writeTimeout = 0
	} else if writeTimeout == 0 {
		writeTimeout = DefaultWriteTimeout
	}
	if writeTimeout > 0 {
		_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
		defer c.conn.SetWriteDeadline(time.Time{})
	}

	c.writeBuf = append(c.writeBuf[:0], payload...)
	c.writeBuf = append(c.writeBuf, '\n')
	_, err := uw.WriteUnreliable(c.writeBuf)
	return err
}

// MaxPayloadBytes reports the largest payload one Send can carry on this connection, with the '\n' Send appends
// already deducted, or 0 when the transport imposes no limit (tcp and quic stream). A net.Conn that says nothing also
// gets 0, so a caller falls back to the protocol's own bound; the relay sizes a Welcome by it.
func (c *NDJSONConn) MaxPayloadBytes() int {
	m, ok := c.conn.(interface{ MaxPayloadBytes() int })
	if !ok {
		return 0
	}
	n := m.MaxPayloadBytes()
	if n <= 1 {
		return 0
	}
	return n - 1
}

// unreliableWriter is what a datagram net.Conn implements to offer fire-and-forget delivery beside its reliable Write.
// netx/udpconn and netx/quicconn satisfy it structurally, so this package keeps no internal dependencies.
type unreliableWriter interface {
	WriteUnreliable(p []byte) (int, error)
}

// OnReceive registers cb as this connection's message handler, then delivers, in arrival order and before returning,
// anything that arrived before it was registered.
func (c *NDJSONConn) OnReceive(cb func(payload []byte)) {
	c.cbMu.Lock()
	c.onReceive = cb
	c.cbMu.Unlock()

	// deliverMu, not cbMu, so readLoop cannot interleave a newer payload into this backlog.
	c.deliverMu.Lock()
	defer c.deliverMu.Unlock()
	backlog := c.pending
	c.pending = nil
	if cb == nil {
		return
	}
	for _, payload := range backlog {
		cb(payload)
	}
}

func (c *NDJSONConn) OnDisconnect(cb func(err error)) {
	c.cbMu.Lock()
	defer c.cbMu.Unlock()
	c.onDisconnect = cb
}

func (c *NDJSONConn) OnError(cb func(err error)) {
	c.cbMu.Lock()
	defer c.cbMu.Unlock()
	c.onError = cb
}

// Close closes the underlying connection. The read loop sees the resulting error and fires OnDisconnect, so a local
// close and a remote hangup report through one path.
func (c *NDJSONConn) Close() error {
	var err error
	c.closeOnce.Do(func() {
		c.closed.Store(true)
		err = c.conn.Close()
	})
	return err
}

// IsClosed reports whether this connection has been closed, by either end and for any reason. It is a fact about the
// socket, never about liveness: a peer that has stopped reading but not hung up is not closed.
func (c *NDJSONConn) IsClosed() bool { return c.closed.Load() }

// CloseGracefully closes the connection so that whatever Send wrote last still reaches the peer. Over TCP a plain
// Close with unread incoming data sends a reset, which can discard what the peer has not read yet, such as a Reject to
// a client that flooded the relay. So it half-closes (the FIN follows the last Send), keeps reading for up to drain,
// and lets readLoop close the socket when the peer's FIN arrives or the drain ends. With no CloseWrite or no drain, it
// is Close.
func (c *NDJSONConn) CloseGracefully(drain time.Duration) {
	type closeWriter interface{ CloseWrite() error }
	cw, ok := c.conn.(closeWriter)
	if !ok || drain <= 0 {
		_ = c.Close()
		return
	}
	c.drainMu.Lock()
	c.drainUntil = time.Now().Add(drain)
	c.drainMu.Unlock()
	// Wake a Scan blocked on the idle deadline so it picks up the drain deadline.
	_ = c.conn.SetReadDeadline(c.drainUntil)
	if err := cw.CloseWrite(); err != nil {
		_ = c.Close()
	}
}
