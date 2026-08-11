// Package transport provides generic NDJSON-over-TCP framing. It knows
// nothing about protocol.Envelope or any other message shape — it moves
// bytes, one JSON-line payload at a time. internal/core and internal/relay
// both consume the Transport interface, for the relay connection and the
// adapter bridge alike (see agent_docs/contract.md's "two protocols"
// section — both use this same framing, over different sockets).
//
// This package has no internal dependencies.
package transport

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
// No behavior yet — dialing, framing, reconnect-with-backoff, and the
// heartbeat loop are Phase 3 work (agent_docs/phases — a phase3.md file
// gets created when that phase starts, per agent_docs/README.md).
type NDJSONConn struct {
	// TODO(Phase 3): net.Conn, a buffered reader for line framing, the
	// registered callbacks, and reconnect/heartbeat state.
}

var _ Transport = (*NDJSONConn)(nil)

func (c *NDJSONConn) Send(payload []byte) error {
	panic("not implemented: Phase 3")
}

func (c *NDJSONConn) OnReceive(cb func(payload []byte)) {
	panic("not implemented: Phase 3")
}

func (c *NDJSONConn) OnConnect(cb func()) {
	panic("not implemented: Phase 3")
}

func (c *NDJSONConn) OnDisconnect(cb func(err error)) {
	panic("not implemented: Phase 3")
}

func (c *NDJSONConn) OnError(cb func(err error)) {
	panic("not implemented: Phase 3")
}

func (c *NDJSONConn) Close() error {
	panic("not implemented: Phase 3")
}
