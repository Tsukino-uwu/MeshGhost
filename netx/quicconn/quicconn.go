// Package quicconn presents QUIC as an ordinary net.Listener handing out net.Conns, the shape netx/udpconn gives
// UDP, so relay and transport need no knowledge of it.
//
// QUIC is the one transport that is fast under packet loss, encrypted and resistant to address spoofing with no
// configuration: its handshake is TLS 1.3, and its connection IDs make a forged source address useless.
//
// # Streams and datagrams
//
// A connection carries one bidirectional stream plus datagrams:
//
//   - Transport.Send -> the stream. Reliable and ordered.
//   - Transport.SendUnreliable -> a QUIC datagram (RFC 9221). Fire and forget.
//
// The stream alone would head-of-line block exactly like TCP; the payoff is the state plane riding datagrams.
//
// Read merges both into one byte stream, so the stream is split into whole lines before anything is handed up, and
// a datagram is already one line: interleaving happens only at line boundaries, where it cannot corrupt framing.
//
// # Certificates
//
// ListenWith serves the certificate the relay's tcp listener serves (Options.TLS), so a client sees one fingerprint
// per relay; Listen without one self-signs in memory, for tests. A client verifies through a tlsx.Verifier, and
// DialWith refuses a nil one. There is no CA and no hostname check.
package quicconn

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	quic "github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/qlog"

	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

const (
	// alpn must match on both ends or the handshake fails, which is what should happen when something else listens
	// on the port.
	alpn = "meshghost"

	// maxLineBytes bounds one NDJSON line off the stream at transport's generous default: this package knows no
	// protocol, and the real per-message limit is enforced above.
	maxLineBytes = 64 * 1024

	readQueue = 64
)

// newSelfSignedTLSConfig is the listener's TLS config with an in-memory certificate, for Listen without a shared
// identity (tests only). Once per listener: per connection would be a free CPU lever for a stranger.
func newSelfSignedTLSConfig() (*tls.Config, error) {
	cfg, _, err := tlsx.ServerConfig(alpn)
	if err != nil {
		return nil, err
	}
	return cfg, nil
}

// withALPN is the shared identity as this transport serves it: a clone, so the tcp listener's NextProtos are
// untouched.
func withALPN(shared *tls.Config) *tls.Config {
	cfg := shared.Clone()
	cfg.NextProtos = []string{alpn}
	return cfg
}

// qlogEnabled gates the qlog tracer; atomic so a test can flip it while the listener's goroutines read it.
var qlogEnabled atomic.Bool

// SetQLog turns quic-go's qlog tracing on or off for every connection made after the call. Off by default, so an
// environment variable alone never makes the relay write a file per connection.
func SetQLog(enabled bool) { qlogEnabled.Store(enabled) }

func quicConfig() *quic.Config {
	cfg := &quic.Config{
		EnableDatagrams: true,
		// One bidirectional stream plus datagrams, so nothing else is granted: quic-go's defaults let a stranger who
		// has handshaked but not said hello park many MiB of unread stream data. -1 is quic-go's "none", 0 "default".
		MaxIncomingStreams:    1,
		MaxIncomingUniStreams: -1,
		// Lines are at most protocol.MaxLineBytes and read as they arrive; the window bounds what a peer sends ahead.
		InitialStreamReceiveWindow:     64 * 1024,
		MaxStreamReceiveWindow:         256 * 1024,
		InitialConnectionReceiveWindow: 64 * 1024,
		MaxConnectionReceiveWindow:     256 * 1024,
	}
	// Dev diagnostics, only when asked: quic-go writes a qlog trace per connection into the directory QLOGDIR names.
	if qlogEnabled.Load() {
		cfg.Tracer = qlog.DefaultConnectionTracer
	}
	return cfg
}

// Conn adapts one QUIC connection (its single bidirectional stream plus its
// datagrams) to net.Conn.
type Conn struct {
	qc     *quic.Conn
	stream *quic.Stream

	// acceptedAt is set only on the accepting side; zero on a dialed connection.
	acceptedAt time.Time

	in     chan []byte
	closed chan struct{}
	once   sync.Once

	// closeErr is why this connection ended, nil for a close this side decided on. Written in once.Do before closed
	// is closed, which publishes it.
	closeErr error

	readBuf []byte

	mu            sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time

	// dgramSlot holds the one datagram send allowed to be parked inside quic-go at a time (see WriteUnreliable).
	dgramSlot chan struct{}
}

func newConn(qc *quic.Conn, stream *quic.Stream) *Conn {
	c := &Conn{
		qc:        qc,
		stream:    stream,
		in:        make(chan []byte, readQueue),
		closed:    make(chan struct{}),
		dgramSlot: make(chan struct{}, 1),
	}
	go c.streamLoop()
	go c.datagramLoop()
	return c
}

// streamLoop queues the stream as whole NDJSON lines, so a datagram arriving mid-line cannot corrupt framing.
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
	// nil is a clean FIN; anything else is the cause (an idle timeout, a CONNECTION_CLOSE, a broken path, or
	// bufio.ErrTooLong from the line limit), which Read reports instead of a bare net.ErrClosed.
	c.closeWith(sc.Err())
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
			// Full queue: drop. Only the lossy state plane rides datagrams, and its next sample supersedes this one.
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
		return 0, c.closeReason()
	}
}

// closeReason is what a Read or Write on a closed connection reports: the cause if it died of one, else
// net.ErrClosed, which transport.fail suppresses as a local Close. Lock-free: closeErr is written before
// close(c.closed), and every caller has already received from that channel.
func (c *Conn) closeReason() error {
	if c.closeErr != nil {
		return c.closeErr
	}
	return net.ErrClosed
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

// WriteUnreliable sends p as a QUIC datagram: no retransmission, no ordering, and no head-of-line blocking against
// the stream. A line too large for the path's datagram is written to the stream instead, because quic-go refuses
// rather than fragments it: a state late is better than never, and the stream is framed the same.
func (c *Conn) WriteUnreliable(p []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	default:
	}

	// SendDatagram blocks with no timeout once quic-go's queue is full, so it runs on a goroutine the write deadline
	// can abandon. A datagram that cannot be queued counts as written: the next sample supersedes it, and an error
	// would end the relay's writer for this client. One slot, because a relay client has one writer goroutine.
	dl := c.writeDeadlineNow()
	select {
	case c.dgramSlot <- struct{}{}:
	default:
		// A previous datagram is still parked: drop without spawning.
		return len(p), nil
	}
	// Copied: the send outlives this call, and transport reuses its buffer.
	buf := append([]byte(nil), p...)
	done := make(chan error, 1)
	go func() {
		defer func() { <-c.dgramSlot }()
		done <- c.qc.SendDatagram(buf)
	}()

	var timeout <-chan time.Time
	if !dl.IsZero() {
		t := time.NewTimer(time.Until(dl))
		defer t.Stop()
		timeout = t.C
	}
	select {
	case err := <-done:
		var tooLarge *quic.DatagramTooLargeError
		if errors.As(err, &tooLarge) {
			return c.Write(p)
		}
		if err != nil {
			return 0, err
		}
		return len(p), nil
	case <-timeout:
		// The send stays parked and ends with the queue or the connection; this caller is released.
		return len(p), nil
	case <-c.closed:
		return 0, net.ErrClosed
	}
}

func (c *Conn) writeDeadlineNow() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.writeDeadline
}

// closeLinger bounds how long a closed connection stays up so bytes already written reach the peer: CONNECTION_CLOSE
// discards unacknowledged data, and quic-go has no "stream acknowledged" signal. A peer closing on our FIN ends it in
// a round trip; 5 s outlasts the retransmission backoff (on loopback, the probe after a 2 s blackout is near 3.8 s).
const closeLinger = 5 * time.Second

// CloseWrite half-closes this connection: the stream sends its FIN, so the peer knows the last line arrived, while
// the connection stays up and Read keeps working. transport.CloseGracefully hard-closes anything without it.
func (c *Conn) CloseWrite() error { return c.stream.Close() }

func (c *Conn) Close() error { return c.closeWith(nil) }

// closeWith is Close, recording why: a nil reason means this side decided to, anything else is the cause Read and
// Write report instead of net.ErrClosed.
func (c *Conn) closeWith(reason error) error {
	c.once.Do(func() {
		// Before the channel close, which publishes it.
		c.closeErr = reason
		close(c.closed)
		// The FIN tells the peer the message it is about to receive is the last one.
		_ = c.stream.Close()
		// Teardown waits for the peer's close or closeLinger, on a goroutine: Close is called from read loops and
		// error paths that must not stall.
		go func() {
			linger := time.NewTimer(closeLinger)
			defer linger.Stop()
			select {
			case <-c.qc.Context().Done():
			case <-linger.C:
			}
			_ = c.qc.CloseWithError(0, "")
		}()
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

// AcceptedAt is when the listener took this connection in, before it waited for the client's first stream, or zero
// on a dialed connection. The relay's hello timeout counts from it.
func (c *Conn) AcceptedAt() time.Time { return c.acceptedAt }

// TLSConnectionState exposes the TLS state, so tlsx.PeerFingerprint can read the leaf the room-code proof binds to.
func (c *Conn) TLSConnectionState() tls.ConnectionState {
	return c.qc.ConnectionState().TLS
}

// Listener is a net.Listener over a QUIC listener.
type Listener struct {
	// pending counts connections that have handshaked and not yet opened a stream, which netx.LimitListener cannot
	// see.
	pendingMu      sync.Mutex
	pending        int
	refusedPending int
	lastPendingLog time.Time
	refusedSource  int
	lastSourceLog  time.Time
	// sources is the per-address table, shared with netx.LimitListener; nil means no per-source bound.
	sources *srclimit.Table
	// maxPending is this listener's copy of the package default, so a test restoring the var never races acceptLoop.
	maxPending int

	ql     *quic.Listener
	accept chan *Conn
	closed chan struct{}
	once   sync.Once
}

// Options configures ListenWith.
type Options struct {
	// TLS is the relay's identity, shared with its tcp listener so one relay has one fingerprint. Nil generates a
	// self-signed certificate in memory (tests only).
	TLS *tls.Config

	// Sources, when set, bounds connections waiting for a stream per client address, on top of the listener-wide
	// maxPending. The slot is released when the connection is handed to Accept, where netx.LimitListener takes over
	// the count with the same table.
	Sources *srclimit.Table
}

// Listen binds addr and serves QUIC with a freshly generated self-signed
// certificate. For tests; a relay passes its identity through ListenWith.
func Listen(addr string) (*Listener, error) {
	return ListenWith(addr, Options{})
}

// ListenWith is Listen with Options.
func ListenWith(addr string, o Options) (*Listener, error) {
	var tlsConf *tls.Config
	if o.TLS != nil {
		tlsConf = withALPN(o.TLS)
	} else {
		var err error
		if tlsConf, err = newSelfSignedTLSConfig(); err != nil {
			return nil, err
		}
	}
	ua, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("quicconn: resolve %s: %w", addr, err)
	}
	pc, err := net.ListenUDP("udp", ua)
	if err != nil {
		return nil, fmt.Errorf("quicconn: listen %s: %w", addr, err)
	}
	tr := &quic.Transport{
		Conn: pc,
		// Every unvalidated source gets a Retry first (RFC 9000 §8.1.2), so a spoofed Initial costs a stateless reply
		// rather than a TLS handshake and half-open state, and the relay is no 3x reflector; quic.ListenAddr never
		// validates. One extra round trip per connect: quic-go suggests gating on load, but a relay is always exposed.
		VerifySourceAddress: func(net.Addr) bool { return true },
	}
	ql, err := tr.Listen(tlsConf, quicConfig())
	if err != nil {
		_ = pc.Close()
		return nil, fmt.Errorf("quicconn: listen %s: %w", addr, err)
	}
	l := &Listener{
		ql:     ql,
		accept: make(chan *Conn, 16),
		closed: make(chan struct{}),
		// Read before the accept goroutine exists, whose creation orders every later read.
		maxPending: maxPending,
		sources:    o.Sources,
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
		// Counted here because a quic connection reaches Accept, and netx.LimitListener, only once it opens a
		// stream. Refused rather than queued: a queued stranger still holds everything it would hold anyway.
		if !l.takePending() {
			_ = qc.CloseWithError(0, "too many pending connections")
			l.notePendingRefusal()
			continue
		}
		// The address is taken once: release may run after the close, when RemoteAddr is not promised.
		var release func()
		if l.sources != nil {
			addr := qc.RemoteAddr()
			if !l.sources.Acquire(addr) {
				l.releasePending()
				_ = qc.CloseWithError(0, "too many connections from one address")
				l.noteSourceRefusal()
				continue
			}
			release = func() { l.sources.Release(addr) }
		}
		// On its own goroutine, so a client that opens no stream cannot stall the other pending connections.
		go l.awaitStream(qc, release)
	}
}

// noteSourceRefusal is notePendingRefusal for the per-address bound: once a
// second, a count, never the address.
func (l *Listener) noteSourceRefusal() {
	l.pendingMu.Lock()
	n := l.refusedSource + 1
	l.refusedSource = n
	quiet := time.Since(l.lastSourceLog) < time.Second
	if !quiet {
		l.lastSourceLog = time.Now()
	}
	l.pendingMu.Unlock()
	if quiet {
		return
	}
	log.Printf("quicconn: refused a connection: its address already holds as many as one address "+
		"may; %d refused so far for that reason", n)
}

// maxPending bounds connections that have handshaked and not yet opened a stream. A multiple of the accept channel,
// since this package does not know the relay's MaxOpenConns: a client opens its stream in one round trip. A var only
// so a test can lower it rather than complete 257 TLS handshakes; each Listener copies it in ListenWith.
var maxPending = 256

func (l *Listener) takePending() bool {
	l.pendingMu.Lock()
	defer l.pendingMu.Unlock()
	if l.pending >= l.maxPending {
		return false
	}
	l.pending++
	return true
}

func (l *Listener) releasePending() {
	l.pendingMu.Lock()
	l.pending--
	l.pendingMu.Unlock()
}

// notePendingRefusal logs at most once a second: the refusals are the flood, and a line each would make a connection
// flood a disk flood.
func (l *Listener) notePendingRefusal() {
	l.pendingMu.Lock()
	n := l.refusedPending + 1
	l.refusedPending = n
	pending := l.pending
	quiet := time.Since(l.lastPendingLog) < time.Second
	if !quiet {
		l.lastPendingLog = time.Now()
	}
	l.pendingMu.Unlock()
	if quiet {
		return
	}
	// pending, then the limit: the two are equal when this fires, so printing the limit twice would look right.
	log.Printf("quicconn: refused a connection: %d already handshaked and waiting for a stream "+
		"(limit %d); %d refused so far", pending, l.maxPending, n)
}

// awaitStream waits for the client's first stream and hands the connection up. release, when non-nil, gives back
// the per-source slot whether the stream arrived or not.
func (l *Listener) awaitStream(qc *quic.Conn, release func()) {
	defer l.releasePending()
	if release != nil {
		defer release()
	}
	acceptedAt := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stream, err := qc.AcceptStream(ctx)
	if err != nil {
		_ = qc.CloseWithError(0, "no stream")
		return
	}
	c := newConn(qc, stream)
	// The relay's hello timeout counts from here, so this wait and the hello timer overlap instead of adding up.
	c.acceptedAt = acceptedAt
	select {
	case l.accept <- c:
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

// dialHint explains a failed dial. quic.DialAddr opens its local udp socket first and returns that error unwrapped,
// a *net.OpError with Op "listen": then the relay cannot be the cause (under Wine/Proton every udp socket fails).
// Anything else got a socket and failed afterwards, where the relay-side question belongs.
func dialHint(err error) string {
	var oe *net.OpError
	if errors.As(err, &oe) && oe.Op == "listen" {
		return " (this machine could not create a udp socket at all, so quic and plain udp are" +
			" both unavailable here and tcp is the only transport it can use; under Wine/Proton" +
			" that is expected and not a fault of the relay)"
	}
	return " (is the relay serving quic? by default quic shares the relay's own port;" +
		" it moves to listen_quic only when plain udp is served too)"
}

// Dial is refused: a quic dial without a certificate verifier would accept anyone. Use DialWith, and say
// tlsx.TrustAnyCertificate out loud if that is what you mean (tests, dev tools).
func Dial(addr string, timeout time.Duration) (net.Conn, error) {
	return nil, errors.New("quicconn: Dial verifies nothing -- use DialWith with a tlsx.Verifier")
}

// DialWith connects to a quicconn listener at addr, bounded by timeout,
// verifies the relay's leaf certificate with verify once the handshake completes,
// and opens the single bidirectional stream the connection carries. A nil
// verifier is an error before any packet is sent.
func DialWith(addr string, timeout time.Duration, verify tlsx.Verifier) (net.Conn, error) {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	tlsConf, err := tlsx.ClientConfig(alpn, verify)
	if err != nil {
		return nil, fmt.Errorf("quicconn: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	qc, err := quic.DialAddr(ctx, addr, tlsConf, quicConfig())
	if err != nil {
		return nil, fmt.Errorf("quicconn: dial %s: %w%s", addr, err, dialHint(err))
	}
	// The handshake is complete, so the leaf is one the relay proved it holds; a TLS callback runs before that proof.
	if err := tlsx.VerifyLeaf(qc.ConnectionState().TLS, verify); err != nil {
		_ = qc.CloseWithError(0, "certificate refused")
		return nil, fmt.Errorf("quicconn: %w", err)
	}
	stream, err := qc.OpenStreamSync(ctx)
	if err != nil {
		_ = qc.CloseWithError(0, "no stream")
		return nil, fmt.Errorf("quicconn: open stream: %w", err)
	}
	// A stream exists on the wire only once written to, so the relay's Accept returns at this client's hello. Not
	// nudged open with an empty line: the relay would parse it as a malformed envelope.
	return newConn(qc, stream), nil
}

// TransportName identifies this connection's transport to a caller holding
// only a net.Conn.
func (c *Conn) TransportName() string { return "quic" }
