// Package udpconn presents a single UDP socket as an ordinary net.Listener
// handing out ordinary net.Conns, one per remote address.
//
// That shape is the whole point. relay's Serve takes a
// net.Listener and handleConn a net.Conn, each connection getting its own
// goroutine — an invariant the relay leans on hard, since Client.gateMu's
// comment there says everything else needs no lock because "OnReceive is
// serial". Demultiplexing here, below that layer, means UDP support costs
// relay exactly zero lines and re-audits no concurrency. See the
// transport ADR in agent_docs/architecture.md.
//
// # Wire format
//
// One datagram carries exactly one NDJSON line. Every datagram is framed,
// with a leading 0xFF that can neither begin a JSON object nor be a legal
// UTF-8 start byte.
//
//	0xFF 0x01                        client hello ("I'd like to connect")
//	0xFF 0x02 <cookie16>             server cookie   (address challenge)
//	0xFF 0x03 <cookie16>             client confirm  (echoes it back)
//	0xFF 0x06 <token8>               server ready    (issues the token)
//	0xFF 0x07 <token8> <line>        unreliable payload
//	0xFF 0x04 <token8> <seq8> <line> reliable payload
//	0xFF 0x05 <token8> <seq8>        ack
//
// Payloads were once bare NDJSON lines, which was pleasingly greppable but
// became untenable once the token was mandatory: an unwrapped datagram
// would have been a way to simply not carry it. Unframed datagrams are now
// dropped.
//
// # Two defences, guarding two different things
//
// **Address validation gates admission**, described below.
//
// **The per-connection token gates everything after it.** Without one, a
// connection is identified by source address alone, so anyone able to spoof
// a live client's ip:port could inject state into its session. TCP makes
// that hard by also requiring a 32-bit sequence number; 64 unpredictable
// bits here clear the same bar. This is the measure docs/security.md's
// CelesteNet notes describe — recorded there as the reason TCP is safer by
// construction, and applied here for exactly that reason. Technique only:
// no code was taken from that project.
//
// # Address validation, and why it is stateless
//
// UDP has no handshake, so a source address is only a claim: anyone can
// forge a datagram that says it came from somewhere else. Before a remote
// gets a Conn it must echo back a cookie the listener sent to the address
// it claimed, which proves that address really does reach it. That defeats
// blind spoofing and stops the relay being used as a reflector.
//
// The cookie is derived, not stored: HMAC(secret, addr || timeSlot),
// checked against the current and previous slot. Keeping a table of
// unvalidated addresses would itself be the vulnerability — one map entry
// per forged hello is unbounded memory an unauthenticated stranger
// controls. Deriving it costs one HMAC and no memory at all. This is the
// same trick as a TCP SYN cookie, and QUIC's Retry packet.
//
// Neither defence stops an attacker already ON the network path, who can
// simply read the cookie and the token out of the traffic. That is exactly
// the limit TCP sequence numbers have too, and the honest comparison to
// draw: this is not encryption. UDP cannot be encrypted here at all — Go's
// standard library has no DTLS — so a room code on this transport crosses
// the wire in the clear. Use QUIC if that matters.
package udpconn

import (
	"errors"
	"time"
)

const (
	// ctrlPrefix marks a control datagram. 0xFF can neither start a JSON
	// object nor be a valid UTF-8 leading byte, so a data line and a
	// control message are unambiguous without a length or type field on
	// the data path.
	ctrlPrefix = 0xFF

	ctrlHello   = 0x01
	ctrlCookie  = 0x02
	ctrlConfirm = 0x03
	// ctrlData carries a payload that must arrive: the token, then an 8-byte
	// big-endian sequence number, then the NDJSON line. ctrlAck echoes that
	// sequence number back.
	//
	// This comment used to end "unreliable payloads are NOT wrapped at all —
	// they go on the wire as the bare line", which was true before the
	// per-connection token became mandatory and has been false since. It is
	// called out rather than quietly deleted because it survived long enough
	// to be the one thing in this file that would send someone implementing a
	// client from the source down a path where nothing is ever delivered:
	// unframed datagrams are dropped on arrival (see the package doc's wire
	// table, ctrlLossy below, and WriteUnreliable). Corrected 2026-08-17.
	ctrlData = 0x04
	ctrlAck  = 0x05
	// ctrlReady carries the per-connection token the relay issues on
	// admission, and ctrlLossy is an unreliable payload. Both exist so that
	// EVERY application datagram carries the token -- see tokenLen.
	ctrlReady = 0x06
	ctrlLossy = 0x07

	cookieLen = 16
	seqLen    = 8

	// tokenLen is the per-connection secret every application datagram must
	// carry after admission.
	//
	// The address-validation cookie above proves a source address is real,
	// which stops blind spoofing and reflection -- but it only gates
	// ADMISSION. Without this token, a connection is identified by source
	// address alone, so anyone who can guess a client's ip:port can inject
	// state into its session. TCP makes that hard by also requiring a
	// 32-bit sequence number; 64 unpredictable bits here clears the same
	// bar comfortably. This is the measure docs/security.md's own
	// CelesteNet notes describe -- recorded there as the reason TCP is
	// safer by construction, then initially not applied here.
	//
	// It does NOT defend against an attacker who can already SEE the
	// traffic, since the token is visible in every datagram -- exactly the
	// same limit TCP sequence numbers have. That needs encryption, i.e.
	// quic.
	tokenLen = 8

	// retryInterval and maxRetries bound a reliable send. Lifecycle
	// messages are a handful per session (hello, welcome, join, leave,
	// reject), so a plain timer loop is both correct and cheap here — the
	// volume that would make this expensive rides SendUnreliable instead.
	// ~6s of total effort is well inside relay.DefaultHelloTimeout.
	retryInterval = 250 * time.Millisecond
	maxRetries    = 24

	// cookieSlot is how long a cookie stays valid. Both the current and
	// previous slot are accepted, so the real window is one to two slots —
	// long enough for a client on a slow link to answer, short enough that
	// a captured cookie is not reusable later.
	cookieSlot = 30 * time.Second

	// MaxDatagramBytes bounds one datagram. Chosen below the ~1500-byte
	// Ethernet MTU with room for IP/UDP headers, because a datagram large
	// enough to be fragmented is lost entirely when any single fragment is
	// lost — turning one dropped packet into a dropped message. Note
	// protocol.MaxLineBytes is larger (4096), so a state message with big
	// extras can exceed this; that is reported rather than silently
	// truncated, and such a client should use tcp.
	MaxDatagramBytes = 1200

	// readBufferBytes is the size of the buffer each read loop hands the
	// socket, and it is deliberately NOT MaxDatagramBytes: the largest
	// datagram IPv4 or (non-jumbogram) IPv6 can carry, so no datagram anyone
	// can send arrives larger than the buffer. That matters because a read
	// into a buffer smaller than the datagram is not a truncation on every
	// platform — on Windows, ReadFromUDP returns the truncated bytes AND a
	// WSAEMSGSIZE error, and both read loops treat any error as the socket
	// dying. Until 2026-09-02 the buffer was MaxDatagramBytes, so one
	// spoofable 1201-byte datagram from anywhere on the internet, with no
	// handshake, closed the listener; and cmd/meshghost-relay treats a
	// listener dying as fatal, so it took the tcp and quic transports down
	// with it. The same buffer on the dialed side let one packet to a
	// player's port end their session. Found by the 2026-09-02 adversarial
	// review; the fuzzer had never seen it because it truncated its own
	// inputs to MaxDatagramBytes. Regression: oversized_test.go. Datagrams
	// over MaxDatagramBytes are read in full and then dropped.
	readBufferBytes = 65535

	// readQueue is how many datagrams may wait for one Conn before further
	// ones are dropped. Dropping is correct rather than regrettable here:
	// the state plane is explicitly lossy and latest-wins, and blocking
	// instead would let one slow reader stall the demultiplexer for every
	// other connection on the socket.
	readQueue = 64

	// reorderWindow bounds how many out-of-order reliable payloads are held
	// while waiting for the gap ahead of them to fill. Overflow is safe
	// rather than lossy: a payload that cannot be held is simply not acked,
	// so the sender retransmits it — the same mechanism that covers a
	// dropped datagram. 64 is far above what this plane can actually
	// produce, since only lifecycle messages ride it and a sender has at
	// most a handful in flight.
	reorderWindow = 64
)

// ErrDatagramTooLarge is returned by Write for a payload that would risk IP
// fragmentation. It is deliberately an error rather than a silent
// truncation: a half-written JSON line would be a parse error at the far
// end with no clue as to why.
var ErrDatagramTooLarge = errors.New("udpconn: message too large for one datagram")
