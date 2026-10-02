//go:build meshghost_devudp

// Package udpconn presents a single UDP socket as an ordinary net.Listener handing out net.Conns, one per remote
// address. Demultiplexing below the relay keeps its one-goroutine-per-connection model, so udp costs the relay no
// lines and no concurrency re-audit.
//
// # Wire format
//
// One datagram carries exactly one NDJSON line, framed by a leading 0xFF, which can neither begin a JSON object nor
// be a legal UTF-8 start byte. Unframed datagrams are dropped.
//
//	0xFF 0x01                        client hello ("I'd like to connect")
//	0xFF 0x02 <cookie16>             server cookie   (address challenge)
//	0xFF 0x03 <cookie16>             client confirm  (echoes it back)
//	0xFF 0x06 <token8>               server ready    (issues the token)
//	0xFF 0x07 <token8> <line>        unreliable payload
//	0xFF 0x04 <token8> <seq8> <line> reliable payload
//	0xFF 0x05 <token8> <seq8>        ack
//
// # Two defences, guarding two different things
//
// Address validation gates admission. UDP has no handshake, so a source address is only a claim: before a remote gets
// a Conn it must echo a cookie the listener sent to the address it claimed, which defeats blind spoofing and stops
// the relay being a reflector. The cookie is derived, not stored, as HMAC(secret, addr || timeSlot) checked against
// the current and previous slot: a table of unvalidated addresses would be unbounded memory a stranger controls. It is
// the trick of a TCP SYN cookie and QUIC's Retry.
//
// The per-connection token gates everything after admission: without it, anyone able to spoof a live client's
// ip:port could inject state into its session. 64 unpredictable bits clear the bar TCP's 32-bit sequence number sets.
//
// Neither stops an attacker on the path, who reads the cookie and the token off the wire, and neither is encryption:
// Go's standard library has no DTLS, so every line crosses the wire readable and the room-code proof is bound to no
// relay identity. Use QUIC if that matters.
package udpconn

import (
	"errors"
	"time"
)

const (
	// ctrlPrefix marks a control datagram: 0xFF can neither start a JSON object nor be a UTF-8 leading byte, so the
	// data path needs no length or type field to tell them apart.
	ctrlPrefix = 0xFF

	ctrlHello   = 0x01
	ctrlCookie  = 0x02
	ctrlConfirm = 0x03
	// ctrlData carries a payload that must arrive: the token, an 8-byte big-endian sequence number, then the NDJSON
	// line. ctrlAck echoes that sequence number back.
	ctrlData = 0x04
	ctrlAck  = 0x05
	// ctrlReady carries the token issued on admission, and ctrlLossy an unreliable payload, so that every application
	// datagram carries the token.
	ctrlReady = 0x06
	ctrlLossy = 0x07

	cookieLen = 16
	seqLen    = 8

	// tokenLen is the per-connection secret every application datagram carries after admission (see the package
	// doc). It is visible in every datagram, so it does nothing against an on-path attacker; that needs quic.
	tokenLen = 8

	// retryInterval and maxRetries bound a reliable send: the state plane never rides it, so a plain timer loop is
	// cheap, and ~6s of effort is well inside relay.DefaultHelloTimeout.
	retryInterval = 250 * time.Millisecond
	maxRetries    = 24

	// cookieSlot is how long a cookie stays valid. The current and previous slot are accepted: long enough for a slow
	// link to answer, short enough that a captured cookie is not reusable later.
	cookieSlot = 30 * time.Second

	// MaxDatagramBytes bounds one datagram below the ~1500-byte Ethernet MTU with room for headers, because a
	// fragmented datagram is lost whole when any fragment is. protocol.MaxLineBytes is larger, so a big state message
	// is refused rather than truncated, and such a client should use tcp.
	MaxDatagramBytes = 1200

	// readBufferBytes is the largest datagram IPv4 or IPv6 can carry, deliberately not MaxDatagramBytes: on Windows a
	// read into a smaller buffer returns WSAEMSGSIZE, and both read loops treat any error as the socket dying.
	// Oversized datagrams are read in full and then dropped.
	readBufferBytes = 65535

	// readQueue is how many datagrams may wait for one Conn before more are dropped: the state plane is lossy, and
	// blocking would let one slow reader stall the demultiplexer for every connection on the socket.
	readQueue = 64

	// reorderWindow bounds out-of-order reliable payloads held while a gap fills. A payload past it is not acked, so
	// the sender retransmits it, as it would a dropped datagram.
	reorderWindow = 64
)

// ErrDatagramTooLarge is returned by Write for a payload that would risk IP
// fragmentation. It is deliberately an error rather than a silent
// truncation: a half-written JSON line would be a parse error at the far
// end with no clue as to why.
var ErrDatagramTooLarge error = tooLargeError{}

// ErrPeerUnresponsive is what Read reports once the retry budget for a reliable payload has run out and the
// connection was closed for it. UDP has no disconnect signal, so this is how the transport notices a vanished peer;
// a bare net.ErrClosed would be suppressed by transport.fail as a local close.
var ErrPeerUnresponsive = errors.New("udpconn: peer stopped acknowledging reliable messages")

// tooLargeError is ErrDatagramTooLarge's own type, for one method: NotWritten. transport.Send closes the connection
// on a write error because a half-sent line cannot be resynchronized, and this error comes before a byte is sent.
// A method because transport cannot import this package; on the sentinel so errors.As finds it through the %w.
type tooLargeError struct{}

func (tooLargeError) Error() string { return "udpconn: message too large for one datagram" }

// NotWritten reports that a Write failing with this error put no bytes on the
// wire, so the connection is unharmed and only the message was lost.
func (tooLargeError) NotWritten() bool { return true }
