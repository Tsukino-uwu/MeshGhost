// Package transport provides generic NDJSON framing over any net.Conn -
// tcp, and udpconn/quicconn alike. It knows
// nothing about protocol.Envelope or any other message shape — it moves
// bytes, one JSON-line payload at a time. core and relay
// both consume the Transport interface, for the relay connection and the
// adapter bridge alike (see agent_docs/contract.md's "two protocols"
// section — both use this same framing, over different sockets).
//
// This package has no internal dependencies.
//
// How this package fits the whole -- the life of a connection and of a state
// message, traced across all of them -- is docs/networking.md.
package transport

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

const (
	// DefaultMaxLineBytes bounds one NDJSON line accepted before its
	// delimiter is found, enforced during the read itself via
	// bufio.Scanner's max-token-size — not after the line is already fully
	// buffered. The old bufio.Reader.ReadBytes approach grew its internal
	// buffer without bound until it found a '\n', so a peer that streamed
	// bytes with no newline could force unbounded memory growth in both the
	// relay and the core; any length check performed on the delivered
	// payload (e.g. relay.MaxLineBytes) ran too late to prevent
	// that. Found and fixed while scoping relay-safety hardening — see the
	// room-code/version ADR in agent_docs/architecture.md.
	//
	// This default is generous above any legitimate message on either
	// protocol this package carries. A tighter per-connection limit can
	// still be set via NDJSONConn.MaxLineBytes — the relay does this with
	// its own, smaller relay/limits.go value, so the two limits
	// stay in one place instead of duplicated as magic numbers.
	DefaultMaxLineBytes = 64 * 1024

	// DefaultIdleTimeout closes a connection that hasn't delivered a
	// complete line within this long, refreshed after every line. Without
	// this, a connection that never finishes a line — including one that
	// never sends anything at all — is held open (a live goroutine and
	// socket) forever.
	DefaultIdleTimeout = 60 * time.Second

	// DefaultWriteTimeout bounds one Send call. Without it, a peer that
	// stops reading blocks the writer indefinitely; relay.Room.Forward
	// depends on Send returning in bounded time so one stalled room member
	// can't freeze delivery to the rest of the room (see Room.Forward's own
	// doc comment for the other half of that fix).
	DefaultWriteTimeout = 10 * time.Second

	// DefaultDialTimeout bounds the TCP connect in Dial. net.Dial alone has
	// no timeout of its own.
	DefaultDialTimeout = 10 * time.Second
)

// Transport is the swappable network boundary named in the brief: adapters
// never implement or hold this directly (see bridge for their
// side), but core and relay both depend on it.
type Transport interface {
	// Send writes one payload as a single NDJSON line, reliably. Every
	// transport guarantees delivery here, so a caller that knows nothing
	// about SendUnreliable below is always correct.
	Send(payload []byte) error

	// SendUnreliable writes one payload with no delivery guarantee, for
	// the lossy latest-wins state plane only. A transport with no
	// unreliable mode (TCP) implements it as Send. See the NDJSONConn
	// method for why reliability is opt-out rather than opt-in.
	SendUnreliable(payload []byte) error

	// OnReceive registers the callback invoked once per received line.
	// Replaces any previously registered callback.
	OnReceive(func(payload []byte))

	// OnDisconnect and OnError report connection lifecycle events the
	// brief's original send/on_receive pair didn't cover. (An OnConnect
	// existed here too until a review pass removed it: FromConn/Dial
	// already start the read loop before returning, so it fired from a
	// goroutine racing the caller's own registration of it — unusable as
	// specified, and nothing in this codebase ever actually registered
	// one.)
	OnDisconnect(func(err error))
	OnError(func(err error))

	// Close releases the underlying connection.
	Close() error
}

// NDJSONConn is the concrete Transport implementation over any net.Conn
// (tcp, udpconn, quicconn), newline-delimited JSON per line. Structurally satisfies
// Transport; declared here as a compile-time check.
//
// Reconnect-with-backoff is not implemented here: this type wraps a single
// already-established net.Conn (dialed or accepted), and only the dialing
// side (the core, connecting to a relay) has anywhere to redial to. That
// retry loop belongs with the core's Dial call, not in this dumb framer —
// see agent_docs/contract.md's transport section.
//
// Heartbeat (ping/pong) is likewise not implemented here: transport moves
// bytes, one line at a time, and does not know protocol.Envelope shapes
// (see the package doc above). Ping/pong are protocol-level messages, so
// that loop belongs in core and relay, not in this
// package. core.Core.sendHeartbeats sends a Ping on an otherwise-
// quiet connection and relay answers with a Pong. That is still not
// liveness detection - a dead peer is found by the idle timeout, not by a
// missing Pong - but the Pong is read back: core turns each one into an
// RTT and a clock offset (core/online.go's clockSync). This package knows
// nothing about any of it. See agent_docs/contract.md's Transport section.
type NDJSONConn struct {
	conn net.Conn

	// MaxLineBytes, IdleTimeout, and WriteTimeout default to this package's
	// Default* constants (set by Dial/FromConn) and may be overwritten by
	// the caller immediately after Dial/FromConn returns — before any data
	// could plausibly have been read yet — same registration-order caveat
	// already documented for OnReceive et al. below. A value <= 0 falls
	// back to the corresponding default at the start of readLoop/Send.
	//
	// That "immediately after" caveat is a real, if narrow, data race —
	// found in a review pass: FromConn already starts the read goroutine
	// before returning, so a caller setting these fields afterward (as
	// relay used to do for MaxLineBytes) is racing that
	// goroutine's own read of them in readLoop. Prefer
	// FromConnWithLimits, which sets these before the goroutine starts.
	MaxLineBytes int
	IdleTimeout  time.Duration
	WriteTimeout time.Duration

	writeMu sync.Mutex
	// writeBuf is Send's scratch space for joining payload and '\n' into a
	// single Write. Guarded by writeMu, reused across calls so the hot
	// state path doesn't allocate per message. See Send for why one Write
	// rather than two.
	writeBuf []byte

	cbMu         sync.Mutex
	onReceive    func(payload []byte)
	onDisconnect func(err error)
	onError      func(err error)

	// deliverMu serializes actual callback delivery (not field access —
	// that's cbMu) so a backlog flushed by OnReceive can't interleave with
	// a payload readLoop is delivering concurrently. Held across the
	// callback itself, which is safe because no callback re-registers
	// OnReceive on its own connection.
	deliverMu sync.Mutex
	// pending holds payloads that arrived before OnReceive was registered.
	// FromConn starts readLoop before it returns, so every caller has a
	// window between "connection exists" and "callback installed" — and a
	// message landing in that window used to be dropped on the floor with
	// no error anywhere. Found 2026-08-16 while isolating an intermittent
	// test failure: `go test ./...` failed in ~9 of 12 runs, a different
	// test each time, always a timeout waiting for a message that was sent
	// but never delivered. Real-world reachable, not just a test artifact:
	// the relay installs its callback after FromConnWithLimits, so a client
	// whose Hello arrives fast enough would never be welcomed.
	pending [][]byte

	closeOnce sync.Once
}

var _ Transport = (*NDJSONConn)(nil)

// Dial connects to addr over TCP (bounded by DefaultDialTimeout) and starts
// the read loop immediately. Register callbacks (OnReceive etc.) right
// after Dial returns and before calling Send — the read loop begins
// delivering data as soon as the connection is up, and a callback
// registered late can miss early lines.
func Dial(addr string) (*NDJSONConn, error) {
	return DialWithLimits(addr, DefaultMaxLineBytes, DefaultIdleTimeout, DefaultWriteTimeout)
}

// DialWithLimits is Dial's more general form — see FromConnWithLimits for
// the same registration-order rationale and per-field zero-value
// convention.
func DialWithLimits(addr string, maxLineBytes int, idleTimeout, writeTimeout time.Duration) (*NDJSONConn, error) {
	conn, err := net.DialTimeout("tcp", addr, DefaultDialTimeout)
	if err != nil {
		return nil, err
	}
	return FromConnWithLimits(conn, maxLineBytes, idleTimeout, writeTimeout), nil
}

// FromConn wraps an already-established connection — typically one
// returned by a net.Listener's Accept, on the relay/bridge-server side —
// and starts its read loop, using this package's Default* limits. Same
// callback-registration-order caveat as Dial applies to OnReceive et al.
// For a non-default MaxLineBytes/IdleTimeout/WriteTimeout, use
// FromConnWithLimits instead of setting the fields after this returns —
// see MaxLineBytes's doc comment for why.
func FromConn(conn net.Conn) *NDJSONConn {
	return FromConnWithLimits(conn, DefaultMaxLineBytes, DefaultIdleTimeout, DefaultWriteTimeout)
}

// FromConnWithLimits is FromConn's more general form: it sets
// MaxLineBytes/IdleTimeout/WriteTimeout before starting the read loop,
// closing the registration-order race FromConn's exported fields
// otherwise have. Same per-field zero-value convention as setting the
// fields directly: maxLineBytes <= 0 means "use DefaultMaxLineBytes";
// idleTimeout/writeTimeout == 0 means "use the matching default", < 0
// means "disabled" (see readLoop/Send). Added in a review pass after
// finding relay set nd.MaxLineBytes on an already-running
// connection.
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

	for {
		if idle > 0 {
			_ = c.conn.SetReadDeadline(time.Now().Add(idle))
		}

		if !scanner.Scan() {
			err := scanner.Err()
			if err == nil {
				err = io.EOF
			}
			c.fail(err)
			return
		}

		// Copy: scanner.Bytes() aliases an internal buffer that the next
		// Scan call reuses, unlike the previous bufio.Reader.ReadBytes,
		// which always returned a freshly allocated slice — callers
		// (json.Unmarshal and friends) were written assuming that
		// guarantee, so preserve it here rather than auditing every
		// downstream consumer.
		payload := append([]byte(nil), bytes.TrimRight(scanner.Bytes(), "\r")...)

		c.deliverMu.Lock()
		c.cbMu.Lock()
		onReceive := c.onReceive
		c.cbMu.Unlock()
		if onReceive != nil {
			onReceive(payload)
		} else {
			// No callback yet — hold it for OnReceive to flush rather
			// than dropping it. See the pending field's comment.
			c.pending = append(c.pending, payload)
		}
		c.deliverMu.Unlock()
	}
}

// fail reports a terminal read error (or EOF) through OnError (for non-EOF
// causes) and OnDisconnect, then closes the connection. Closing here —
// unlike the pre-hardening version, which left the socket for the caller to
// clean up — matters now that this loop can itself decide to terminate a
// connection (an oversized line, an idle timeout) with no offending message
// ever reaching a caller's OnReceive to trigger its own Close() call.
func (c *NDJSONConn) fail(err error) {
	// net.ErrClosed is not a failure to report: it can only be produced by
	// THIS process calling Close() on the connection, never by the peer or by
	// the network. Every place that closes deliberately -- the relay answering
	// a query_only transport-discovery hello (relay), a rejected
	// hello, a hello timeout, an oversized line, a rate-limit trip -- already
	// logs its own reason, so passing this to OnError only ever adds a second,
	// scarier-looking line about the close it just decided on.
	//
	// Found 2026-08-16 by reproducing it: a client on the shipped default
	// transport (udp) made the relay log
	// "connection error: read tcp ...: use of closed network connection"
	// immediately before every successful join, because discovery closes the
	// tcp connection while this read loop is parked in Scan(). Harmless, but
	// it put an error line at the top of the log a remote tester is asked to
	// send back. OnDisconnect still fires either way, so nothing that reacts
	// to a connection ending is affected.
	if err != io.EOF && !errors.Is(err, net.ErrClosed) {
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

// Send writes payload as a single NDJSON line, bounded by WriteTimeout so a
// peer that stops reading cannot block the caller forever. payload must not
// itself contain a newline — callers pass already-marshaled JSON, which
// never does.
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

	// One Write, not two. Over TCP the split was invisible — the kernel
	// coalesces a byte stream either way — but a datagram transport turns
	// "write payload, write '\n'" into two datagrams per message, which
	// breaks framing outright and cannot be fixed downstream. Found while
	// scoping selectable transports (agent_docs/architecture.md's transport
	// ADR); see the one-Write regression test in transport_test.go.
	c.writeBuf = append(c.writeBuf[:0], payload...)
	c.writeBuf = append(c.writeBuf, '\n')
	_, err := c.conn.Write(c.writeBuf)
	return err
}

// SendUnreliable sends payload with no delivery guarantee, for the lossy
// latest-wins state plane (agent_docs/contract.md: excess samples are
// dropped, never queued, so a lost one is superseded rather than missed).
//
// Reliability is opt-*out* rather than opt-in on purpose: Send is reliable
// on every transport, so a call site that never learns about this method
// stays correct. Only the two state hot paths — the core's own send and the
// relay's forward — give the guarantee up, and everything carrying
// lifecycle meaning (hello/welcome/join/leave/reject/ping/pong) keeps it. A
// dropped leave would strand a ghost on screen forever.
//
// Over TCP there is nothing to give up: the stream is reliable whether or
// not anyone asks, so this is exactly Send. A datagram transport opts in by
// having its net.Conn implement unreliableWriter, which is why this is a
// type assertion rather than a field — transport must not import
// netx (it has no internal dependencies at all, by design), and a
// net.Conn that knows nothing about any of this still works.
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

// unreliableWriter is the optional escape hatch a datagram-based net.Conn
// implements to offer fire-and-forget delivery alongside the reliable Write
// every net.Conn already has. Declared here rather than imported so this
// package keeps its no-internal-dependencies property; netx/udpconn
// and netx/quicconn satisfy it structurally.
type unreliableWriter interface {
	WriteUnreliable(p []byte) (int, error)
}

// OnReceive registers cb as this connection's message handler, then
// delivers — in arrival order, before returning — anything that arrived
// before it was registered. Without that flush, every message landing in
// the window between FromConn/Dial starting the read loop and the caller
// installing its callback was silently discarded; see the pending field.
func (c *NDJSONConn) OnReceive(cb func(payload []byte)) {
	c.cbMu.Lock()
	c.onReceive = cb
	c.cbMu.Unlock()

	// deliverMu (not cbMu) so readLoop can't interleave a newer payload
	// into the middle of this backlog.
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

// Close closes the underlying connection. The read loop observes the
// resulting error and fires OnDisconnect on its own; Close does not fire
// it directly, so a locally-initiated close and a remote hangup are
// reported through the same single path.
func (c *NDJSONConn) Close() error {
	var err error
	c.closeOnce.Do(func() {
		err = c.conn.Close()
	})
	return err
}
