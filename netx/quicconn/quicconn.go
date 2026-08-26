// Package quicconn presents QUIC as an ordinary net.Listener handing out
// ordinary net.Conns, the same shape netx/udpconn provides for
// UDP, so relay and transport need no knowledge of it.
//
// QUIC is worth having because it is the only one of the three transports
// that is fast under packet loss AND encrypted AND resistant to address
// spoofing, with no configuration from the user. Its handshake IS TLS 1.3,
// so encryption is not optional, and its connection IDs make a forged
// source address useless — the two things plain UDP gives up.
//
// # Streams and datagrams, and why both
//
// A QUIC connection here carries one bidirectional stream plus datagrams:
//
//   - Transport.Send -> the stream. Reliable and ordered.
//   - Transport.SendUnreliable -> a QUIC datagram (RFC 9221). Fire and
//     forget.
//
// Using only the stream would work and would be simpler, but it would also
// make QUIC pointless for this project: a single reliable stream
// head-of-line blocks exactly like TCP, so a lost packet stalls the newer
// positions queued behind it just the same. The payoff only appears once
// the state plane rides datagrams.
//
// # Why the stream side is line-buffered here
//
// Datagrams and stream bytes are merged into one byte stream for Read,
// because that is what a net.Conn is. Merging naively would corrupt
// framing: if the stream has delivered half of one JSON line when a
// datagram arrives, splicing the datagram in mid-line produces something
// no parser can recover. So the stream is split into complete lines before
// anything is handed upward, and a datagram is already exactly one line.
// Interleaving then only ever happens at line boundaries, where it is
// harmless.
//
// # Certificates
//
// The listener generates an in-memory, self-signed Ed25519 certificate once
// per process and never writes it anywhere. Nothing verifies it by
// fingerprint, so a file on disk would buy no security at all while putting
// a private key next to the executable in a zip people re-share. The client
// therefore sets InsecureSkipVerify: connect_to is a bare IP with no CA and
// no hostname to check, so this gives encryption against someone watching
// the network, not proof of who is on the other end. Binding relay identity
// to the room code is a separate, scoped-but-unscheduled piece of work —
// see agent_docs/ideas.md's transport-security section.
package quicconn

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	quic "github.com/quic-go/quic-go"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

const (
	// alpn identifies this protocol during the TLS handshake. Both ends
	// must agree or the handshake fails outright, which is the desired
	// outcome when something else is listening on the port.
	alpn = "meshghost"

	// maxLineBytes bounds one NDJSON line read off the stream. Matches
	// transport's own generous default rather than
	// protocol's tighter one, because this package deliberately
	// has no dependency on either — the real per-message limit is enforced
	// above, where the protocol is actually known.
	maxLineBytes = 64 * 1024

	readQueue = 64
)

// newSelfSignedTLSConfig builds the listener's TLS configuration with a
// freshly generated in-memory certificate. Exported so a caller can reuse
// one config across listeners; generating per connection would be a free
// CPU lever for an unauthenticated stranger.
//
// The certificate generation itself lives in netx/tlsx, shared with TLS
// over the tcp transport so there is one self-signed-certificate story in
// this project rather than two that can drift apart.
func newSelfSignedTLSConfig() (*tls.Config, error) {
	cfg, _, err := tlsx.ServerConfig(alpn)
	if err != nil {
		return nil, err
	}
	return cfg, nil
}

func clientTLSConfig() *tls.Config {
	return &tls.Config{
		// No CA and no hostname: connect_to is a bare IP a friend sent
		// you, so there is nothing a certificate could be checked against.
		// This still encrypts the session against anyone merely watching
		// the network, which is strictly more than tcp or udp offer. It
		// does NOT prove the relay is the one you meant — see the package
		// doc and agent_docs/ideas.md's transport-security section.
		InsecureSkipVerify: true,
		NextProtos:         []string{alpn},
		MinVersion:         tls.VersionTLS13,
	}
}

func quicConfig() *quic.Config {
	return &quic.Config{EnableDatagrams: true}
}

// ------------------------------------------------------------------- Conn

// Conn adapts one QUIC connection (its single bidirectional stream plus its
// datagrams) to net.Conn.
type Conn struct {
	qc     *quic.Conn
	stream *quic.Stream

	in     chan []byte
	closed chan struct{}
	once   sync.Once

	readBuf []byte

	mu            sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time
}

func newConn(qc *quic.Conn, stream *quic.Stream) *Conn {
	c := &Conn{
		qc:     qc,
		stream: stream,
		in:     make(chan []byte, readQueue),
		closed: make(chan struct{}),
	}
	go c.streamLoop()
	go c.datagramLoop()
	return c
}

// streamLoop splits the reliable stream into whole NDJSON lines before
// queueing them, so a datagram arriving mid-line cannot corrupt framing.
// See the package doc.
func (c *Conn) streamLoop() {
	sc := bufio.NewScanner(c.stream)
	sc.Buffer(make([]byte, 4096), maxLineBytes)
	for sc.Scan() {
		line := append(append([]byte(nil), sc.Bytes()...), '\n')
		select {
		case c.in <- line:
		case <-c.closed:
			return
		}
	}
	// The stream ended: the peer closed, or the connection died.
	c.Close()
}

func (c *Conn) datagramLoop() {
	for {
		b, err := c.qc.ReceiveDatagram(context.Background())
		if err != nil {
			return
		}
		cp := append([]byte(nil), b...)
		select {
		case c.in <- cp:
		case <-c.closed:
			return
		default:
			// Full queue: drop, exactly as the udp transport does. The
			// only traffic on this path is the lossy state plane, where a
			// dropped sample is superseded ~50ms later.
		}
	}
}

func (c *Conn) Read(p []byte) (int, error) {
	if len(c.readBuf) > 0 {
		n := copy(p, c.readBuf)
		c.readBuf = c.readBuf[n:]
		return n, nil
	}

	c.mu.Lock()
	dl := c.readDeadline
	c.mu.Unlock()

	var timeout <-chan time.Time
	if !dl.IsZero() {
		t := time.NewTimer(time.Until(dl))
		defer t.Stop()
		timeout = t.C
	}

	select {
	case b, ok := <-c.in:
		if !ok {
			return 0, io.EOF
		}
		n := copy(p, b)
		if n < len(b) {
			c.readBuf = append(c.readBuf[:0], b[n:]...)
		}
		return n, nil
	case <-timeout:
		return 0, os.ErrDeadlineExceeded
	case <-c.closed:
		return 0, net.ErrClosed
	}
}

// Write sends p on the reliable, ordered stream.
func (c *Conn) Write(p []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	default:
	}
	c.mu.Lock()
	dl := c.writeDeadline
	c.mu.Unlock()
	if !dl.IsZero() {
		_ = c.stream.SetWriteDeadline(dl)
		defer c.stream.SetWriteDeadline(time.Time{})
	}
	return c.stream.Write(p)
}

// WriteUnreliable sends p as a QUIC datagram: no retransmission, no
// ordering, and no head-of-line blocking against the stream. This is the
// method that makes QUIC worth choosing over TCP — see the package doc.
//
// A datagram too large for the connection's current path MTU is refused by
// quic-go rather than fragmented, and that error is returned as-is.
func (c *Conn) WriteUnreliable(p []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	default:
	}
	if err := c.qc.SendDatagram(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// closeLinger is how long a closing connection stays alive after its stream
// has been closed, so the bytes already written to that stream can actually
// reach the peer.
//
// Without it, Close() closed the stream and tore down the whole QUIC
// connection in the same breath. Closing the stream only signals FIN; the data
// still has to be delivered, and it cannot be once the connection is gone — so
// the peer received CONNECTION_CLOSE instead of the last message and never saw
// it at all.
//
// **That silently broke every send-before-close in the project on quic**, which
// is a pattern this codebase relies on deliberately in three places: the
// relay's Reject before refusing a hello (a client with a wrong room code saw a
// bare hangup rather than the reason, which is the entire thing rejectAndClose
// exists to prevent), the relay's rate-limit Reject, and the core's goodbye
// before a deliberate leave. Found 2026-08-17 by the goodbye going missing on
// quic while working perfectly on tcp.
//
// 250ms is chosen to be far longer than a loopback or LAN round trip and short
// enough to be invisible: Close() itself does not wait, so nothing blocks on
// this — only the connection object survives a moment longer.
const closeLinger = 250 * time.Millisecond

func (c *Conn) Close() error {
	c.once.Do(func() {
		close(c.closed)
		// Closing the stream first signals FIN, so the peer learns the message
		// it is about to receive is the last one.
		_ = c.stream.Close()
		// The connection teardown is deferred rather than skipped: a QUIC
		// connection left open forever would leak, and a peer that has already
		// gone will simply never read the data. Deferred with AfterFunc rather
		// than a sleep so Close stays non-blocking — it is called from read
		// loops and from error paths that must not stall.
		time.AfterFunc(closeLinger, func() { _ = c.qc.CloseWithError(0, "") })
	})
	return nil
}

func (c *Conn) LocalAddr() net.Addr  { return c.qc.LocalAddr() }
func (c *Conn) RemoteAddr() net.Addr { return c.qc.RemoteAddr() }

func (c *Conn) SetDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline, c.writeDeadline = t, t
	c.mu.Unlock()
	return nil
}

func (c *Conn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline = t
	c.mu.Unlock()
	return nil
}

func (c *Conn) SetWriteDeadline(t time.Time) error {
	c.mu.Lock()
	c.writeDeadline = t
	c.mu.Unlock()
	return nil
}

// TLSConnectionState exposes the underlying TLS state. Present so the
// scoped-but-unscheduled room-code channel-binding work
// (agent_docs/ideas.md) can reach ExportKeyingMaterial without this package
// having to change shape later; nothing calls it yet.
func (c *Conn) TLSConnectionState() tls.ConnectionState {
	return c.qc.ConnectionState().TLS
}

// --------------------------------------------------------------- Listener

// Listener is a net.Listener over a QUIC listener.
type Listener struct {
	ql     *quic.Listener
	accept chan *Conn
	closed chan struct{}
	once   sync.Once
}

// Listen binds addr and serves QUIC with a freshly generated self-signed
// certificate.
func Listen(addr string) (*Listener, error) {
	tlsConf, err := newSelfSignedTLSConfig()
	if err != nil {
		return nil, err
	}
	ql, err := quic.ListenAddr(addr, tlsConf, quicConfig())
	if err != nil {
		return nil, fmt.Errorf("quicconn: listen %s: %w", addr, err)
	}
	l := &Listener{
		ql:     ql,
		accept: make(chan *Conn, 16),
		closed: make(chan struct{}),
	}
	go l.acceptLoop()
	return l, nil
}

func (l *Listener) acceptLoop() {
	for {
		qc, err := l.ql.Accept(context.Background())
		if err != nil {
			l.Close()
			return
		}
		// Wait for the client's stream on its own goroutine: a client that
		// completes the handshake and then opens no stream must not stall
		// every other pending connection.
		go l.awaitStream(qc)
	}
}

func (l *Listener) awaitStream(qc *quic.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stream, err := qc.AcceptStream(ctx)
	if err != nil {
		_ = qc.CloseWithError(0, "no stream")
		return
	}
	select {
	case l.accept <- newConn(qc, stream):
	case <-l.closed:
		_ = qc.CloseWithError(0, "listener closed")
	}
}

func (l *Listener) Accept() (net.Conn, error) {
	select {
	case c := <-l.accept:
		return c, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *Listener) Close() error {
	l.once.Do(func() {
		close(l.closed)
		_ = l.ql.Close()
	})
	return nil
}

func (l *Listener) Addr() net.Addr { return l.ql.Addr() }

// ------------------------------------------------------------------- Dial

// Dial connects to a quicconn listener at addr, bounded by timeout, and
// opens the single bidirectional stream the connection carries.
func Dial(addr string, timeout time.Duration) (net.Conn, error) {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	qc, err := quic.DialAddr(ctx, addr, clientTLSConfig(), quicConfig())
	if err != nil {
		return nil, fmt.Errorf("quicconn: dial %s: %w (is the relay serving quic? by default quic shares the relay's own port; it moves to listen_quic only when plain udp is served too)", addr, err)
	}
	stream, err := qc.OpenStreamSync(ctx)
	if err != nil {
		_ = qc.CloseWithError(0, "no stream")
		return nil, fmt.Errorf("quicconn: open stream: %w", err)
	}
	// Note a QUIC stream does not exist on the wire until something is
	// written to it, so the relay's Accept returns only once this client
	// sends its first message — which is always the hello, immediately.
	// Deliberately NOT nudged open with an empty line here: that would
	// deliver a zero-length payload the relay would try to parse as an
	// envelope, producing a spurious malformed-message error on every
	// single quic connection.
	return newConn(qc, stream), nil
}

// TransportName identifies this connection's transport to a caller holding
// only a net.Conn. See the equivalent in netx/udpconn.
func (c *Conn) TransportName() string { return "quic" }
