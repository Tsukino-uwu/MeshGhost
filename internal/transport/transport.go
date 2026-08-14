// Package transport provides generic NDJSON-over-TCP framing. It knows
// nothing about protocol.Envelope or any other message shape — it moves
// bytes, one JSON-line payload at a time. internal/core and internal/relay
// both consume the Transport interface, for the relay connection and the
// adapter bridge alike (see agent_docs/contract.md's "two protocols"
// section — both use this same framing, over different sockets).
//
// This package has no internal dependencies.
package transport

import (
	"bufio"
	"bytes"
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
	// payload (e.g. internal/relay.MaxLineBytes) ran too late to prevent
	// that. Found and fixed while scoping relay-safety hardening — see the
	// room-code/version ADR in agent_docs/architecture.md.
	//
	// This default is generous above any legitimate message on either
	// protocol this package carries. A tighter per-connection limit can
	// still be set via NDJSONConn.MaxLineBytes — the relay does this with
	// its own, smaller internal/relay/limits.go value, so the two limits
	// stay in one place instead of duplicated as magic numbers.
	DefaultMaxLineBytes = 64 * 1024

	// DefaultIdleTimeout closes a connection that hasn't delivered a
	// complete line within this long, refreshed after every line. Without
	// this, a connection that never finishes a line — including one that
	// never sends anything at all — is held open (a live goroutine and
	// socket) forever.
	DefaultIdleTimeout = 60 * time.Second

	// DefaultWriteTimeout bounds one Send call. Without it, a peer that
	// stops reading blocks the writer indefinitely; internal/relay.Room.Forward
	// depends on Send returning in bounded time so one stalled room member
	// can't freeze delivery to the rest of the room (see Room.Forward's own
	// doc comment for the other half of that fix).
	DefaultWriteTimeout = 10 * time.Second

	// DefaultDialTimeout bounds the TCP connect in Dial. net.Dial alone has
	// no timeout of its own.
	DefaultDialTimeout = 10 * time.Second
)

// Transport is the swappable network boundary named in the brief: adapters
// never implement or hold this directly (see internal/bridge for their
// side), but internal/core and internal/relay both depend on it.
type Transport interface {
	// Send writes one payload as a single NDJSON line.
	Send(payload []byte) error

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

// NDJSONConn is the concrete Transport implementation over a TCP
// connection, newline-delimited JSON per line. Structurally satisfies
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
// that loop belongs in internal/core and internal/relay, not in this
// package. internal/core.Core.sendHeartbeats sends a Ping on an otherwise-
// quiet connection and internal/relay answers with a Pong — but this is an
// idle-timeout-avoidance mechanism, not liveness/RTT detection; nothing
// currently reads the Pong back. See agent_docs/contract.md's Transport
// section for the real mechanism and why it exists.
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
	// internal/relay used to do for MaxLineBytes) is racing that
	// goroutine's own read of them in readLoop. Prefer
	// FromConnWithLimits, which sets these before the goroutine starts.
	MaxLineBytes int
	IdleTimeout  time.Duration
	WriteTimeout time.Duration

	writeMu sync.Mutex

	cbMu         sync.Mutex
	onReceive    func(payload []byte)
	onDisconnect func(err error)
	onError      func(err error)

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
// finding internal/relay set nd.MaxLineBytes on an already-running
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

		c.cbMu.Lock()
		onReceive := c.onReceive
		c.cbMu.Unlock()
		if onReceive != nil {
			onReceive(payload)
		}
	}
}

// fail reports a terminal read error (or EOF) through OnError (for non-EOF
// causes) and OnDisconnect, then closes the connection. Closing here —
// unlike the pre-hardening version, which left the socket for the caller to
// clean up — matters now that this loop can itself decide to terminate a
// connection (an oversized line, an idle timeout) with no offending message
// ever reaching a caller's OnReceive to trigger its own Close() call.
func (c *NDJSONConn) fail(err error) {
	if err != io.EOF {
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

	if _, err := c.conn.Write(payload); err != nil {
		return err
	}
	_, err := c.conn.Write([]byte{'\n'})
	return err
}

func (c *NDJSONConn) OnReceive(cb func(payload []byte)) {
	c.cbMu.Lock()
	defer c.cbMu.Unlock()
	c.onReceive = cb
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
