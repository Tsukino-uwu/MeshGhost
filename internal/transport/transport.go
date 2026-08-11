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

	// OnConnect, OnDisconnect, and OnError report connection lifecycle
	// events the brief's original send/on_receive pair didn't cover.
	OnConnect(func())
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
// that liveness loop belongs in internal/core and internal/relay once they
// exist, not in this package.
type NDJSONConn struct {
	conn net.Conn

	writeMu sync.Mutex

	cbMu         sync.Mutex
	onReceive    func(payload []byte)
	onConnect    func()
	onDisconnect func(err error)
	onError      func(err error)

	closeOnce sync.Once
}

var _ Transport = (*NDJSONConn)(nil)

// Dial connects to addr over TCP and starts the read loop immediately.
// Register callbacks (OnReceive etc.) right after Dial returns and before
// calling Send — the read loop begins delivering data as soon as the
// connection is up, and a callback registered late can miss early lines.
func Dial(addr string) (*NDJSONConn, error) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	return FromConn(conn), nil
}

// FromConn wraps an already-established connection — typically one
// returned by a net.Listener's Accept, on the relay/bridge-server side —
// and starts its read loop. Same callback-registration-order caveat as
// Dial applies.
func FromConn(conn net.Conn) *NDJSONConn {
	c := &NDJSONConn{conn: conn}
	go c.readLoop()
	return c
}

func (c *NDJSONConn) readLoop() {
	c.cbMu.Lock()
	onConnect := c.onConnect
	c.cbMu.Unlock()
	if onConnect != nil {
		onConnect()
	}

	reader := bufio.NewReader(c.conn)
	for {
		line, err := reader.ReadBytes('\n')
		if err == nil {
			payload := bytes.TrimRight(line, "\r\n")
			c.cbMu.Lock()
			onReceive := c.onReceive
			c.cbMu.Unlock()
			if onReceive != nil {
				onReceive(payload)
			}
			continue
		}

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
		return
	}
}

// Send writes payload as a single NDJSON line. payload must not itself
// contain a newline — callers pass already-marshaled JSON, which never
// does.
func (c *NDJSONConn) Send(payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

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

func (c *NDJSONConn) OnConnect(cb func()) {
	c.cbMu.Lock()
	defer c.cbMu.Unlock()
	c.onConnect = cb
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
