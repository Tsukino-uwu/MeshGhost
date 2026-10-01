//go:build meshghost_devudp

package udpconn

import (
	"crypto/subtle"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// Conn is one remote address's view of the shared socket, presented as a
// net.Conn so transport can wrap it in the same NDJSON framing it
// applies to TCP.
type Conn struct {
	pc     *net.UDPConn
	remote *net.UDPAddr
	owner  *Listener // nil for a dialed (client-side) Conn

	// token is this connection's unpredictable secret, issued on admission and required on every application
	// datagram afterwards (see tokenLen).
	token [tokenLen]byte

	in     chan []byte
	closed chan struct{}
	once   sync.Once

	// closeErr is why this connection ended, nil for a close this side decided on. Written in once.Do before closed is
	// closed, which publishes it: nothing may read it before observing that channel closed.
	closeErr error

	// writeClosed is set by CloseWrite: no new payload may go out. A flag rather than a channel because retryLoop and
	// sendAck must go on writing through it.
	writeClosed atomic.Bool

	// readBuf holds the rest of a datagram that did not fit the caller's buffer: real UDP discards it, but an in-memory
	// queue must not, or a short Read would eat half a line. Touched only from Read, on transport's one goroutine.
	readBuf []byte

	mu            sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time

	// dialWMu is the write-deadline lock for a Conn that owns its socket;
	// an accepted one uses its listener's instead. See socketWriteMu.
	dialWMu sync.Mutex

	// lossyMu guards lossyBuf, the scratch buffer WriteUnreliable frames into, so the relay's per-recipient fan-out
	// does not allocate per call. Not mu, which rawWrite takes and releases while the buffer is still in use.
	lossyMu  sync.Mutex
	lossyBuf []byte

	// Reliability state: Write uses it, WriteUnreliable never does.
	relMu   sync.Mutex
	nextSeq uint64
	pending map[uint64]*pendingMsg

	// wantSeq is the next sequence number that may be delivered, and reorderBuf holds payloads that arrived ahead of
	// it, so the reliable path is ordered as well as reliable. A wantSeq of 0 means not started and is promoted to 1,
	// the first value Write assigns.
	wantSeq    uint64
	reorderBuf map[uint64][]byte

	retryOne sync.Once
}

// pendingMsg is a reliable payload still waiting for its ack.
type pendingMsg struct {
	wire     []byte // the full ctrlData datagram, ready to resend as-is
	attempts int
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
// net.ErrClosed. transport.fail suppresses net.ErrClosed as a local Close, and here retry exhaustion, a peer that has
// gone, closes the connection too. Lock-free: closeErr is written before close(c.closed), which every caller has seen.
func (c *Conn) closeReason() error {
	if c.closeErr != nil {
		return c.closeErr
	}
	return net.ErrClosed
}

// Write sends p reliably and in order: it is retransmitted until acked or until the retry budget runs out, which
// closes the connection, and the receiver holds early arrivals until the gap fills. It does not wait for the ack,
// which would stall relay's fan-out behind one slow peer.
func (c *Conn) Write(p []byte) (int, error) {
	if err := c.checkWritable(p, 2+tokenLen+seqLen); err != nil {
		return 0, err
	}

	c.relMu.Lock()
	c.nextSeq++
	seq := c.nextSeq
	wire := make([]byte, 0, 2+tokenLen+seqLen+len(p))
	wire = append(wire, ctrlPrefix, ctrlData)
	wire = append(wire, c.token[:]...)
	var sb [seqLen]byte
	binary.BigEndian.PutUint64(sb[:], seq)
	wire = append(wire, sb[:]...)
	wire = append(wire, p...)
	if c.pending == nil {
		c.pending = map[uint64]*pendingMsg{}
	}
	c.pending[seq] = &pendingMsg{wire: wire}
	c.relMu.Unlock()

	c.retryOne.Do(func() { go c.retryLoop() })

	if _, err := c.rawWrite(wire); err != nil {
		return 0, err
	}
	return len(p), nil
}

// WriteUnreliable sends p once, with no sequence number, ack or retransmission, framed as 0xFF 0x07 <token8> because
// every application datagram carries the token. A lost sample is superseded by the next; resending it would deliver
// stale data late.
func (c *Conn) WriteUnreliable(p []byte) (int, error) {
	if err := c.checkWritable(p, 2+tokenLen); err != nil {
		return 0, err
	}
	// Held across rawWrite, which still reads the buffer: releasing after the framing would let a concurrent call
	// overwrite a datagram mid-send.
	c.lossyMu.Lock()
	defer c.lossyMu.Unlock()
	c.lossyBuf = append(c.lossyBuf[:0], ctrlPrefix, ctrlLossy)
	c.lossyBuf = append(c.lossyBuf, c.token[:]...)
	c.lossyBuf = append(c.lossyBuf, p...)
	return c.rawWrite(c.lossyBuf)
}

// MaxPayloadBytes is the largest payload one reliable Write can carry: MaxDatagramBytes less the control prefix, the
// token and the sequence number. A caller building a message sizes it to fit; transport.NDJSONConn reads it
// structurally and subtracts its own newline.
func (c *Conn) MaxPayloadBytes() int { return MaxDatagramBytes - 2 - tokenLen - seqLen }

// checkWritable rejects a write that is closed or would risk IP
// fragmentation, accounting for overhead bytes the caller's payload will
// gain on the wire.
func (c *Conn) checkWritable(p []byte, overhead int) error {
	select {
	case <-c.closed:
		return c.closeReason()
	default:
	}
	if c.writeClosed.Load() {
		// Half-closed: net.TCPConn's answer after CloseWrite. retryLoop and sendAck call rawWrite directly and go on.
		return net.ErrClosed
	}
	if len(p)+overhead > MaxDatagramBytes {
		return fmt.Errorf("%w: %d bytes (+%d framing), limit %d — use the tcp transport for messages this large",
			ErrDatagramTooLarge, len(p), overhead, MaxDatagramBytes)
	}
	return nil
}

// socketWriteMu serializes a set-deadline/write/clear-deadline sequence against every other write on the same
// socket. An accepted Conn's c.pc is the listener's socket, so a write deadline is per-socket state; a dialed Conn
// owns its socket, but two goroutines writing on it would stomp each other's deadline the same way.
func (c *Conn) socketWriteMu() *sync.Mutex {
	if c.owner != nil {
		return &c.owner.wmu
	}
	return &c.dialWMu
}

func (c *Conn) rawWrite(b []byte) (int, error) {
	c.mu.Lock()
	dl := c.writeDeadline
	c.mu.Unlock()

	// Taken for every write: an unbounded write overlapping another's deadline window is the coupling this removes.
	m := c.socketWriteMu()
	m.Lock()
	defer m.Unlock()
	if !dl.IsZero() {
		_ = c.pc.SetWriteDeadline(dl)
		defer c.pc.SetWriteDeadline(time.Time{})
	}
	return c.pc.WriteToUDP(b, c.remote)
}

// retryLoop resends unacked reliable payloads. One goroutine per
// connection, started on the first reliable Write and stopped when the
// connection closes.
func (c *Conn) retryLoop() {
	t := time.NewTicker(retryInterval)
	defer t.Stop()
	for {
		select {
		case <-c.closed:
			return
		case <-t.C:
			var resend [][]byte
			exhausted := false

			c.relMu.Lock()
			for seq, m := range c.pending {
				m.attempts++
				if m.attempts > maxRetries {
					exhausted = true
					delete(c.pending, seq)
					continue
				}
				resend = append(resend, m.wire)
			}
			c.relMu.Unlock()

			if exhausted {
				// The peer stopped acking. UDP has no disconnect signal, so this is how a vanished peer is noticed, and
				// the reason is kept so it is not reported as an ordinary hangup.
				c.closeWith(ErrPeerUnresponsive)
				return
			}
			for _, w := range resend {
				// One failed datagram, not a dead connection: returning would stop the count above that notices a
				// vanished peer. Errors are dropped; this library has no logger.
				_, _ = c.rawWrite(w)
			}
		}
	}
}

// sendAck acknowledges one reliable sequence number.
func (c *Conn) sendAck(seq uint64) {
	ab := make([]byte, 0, 2+tokenLen+seqLen)
	ab = append(ab, ctrlPrefix, ctrlAck)
	ab = append(ab, c.token[:]...)
	var sb [seqLen]byte
	binary.BigEndian.PutUint64(sb[:], seq)
	ab = append(ab, sb[:]...)
	_, _ = c.rawWrite(ab)
}

// handleControl processes one control datagram, returning a payload for the caller to deliver or nil. Shared by the
// listener's demultiplexer and a dialed conn's read loop, so the two cannot drift. Reliable payloads are delivered
// here rather than returned, because acking correctly requires knowing whether delivery succeeded.
func (c *Conn) handleControl(b []byte) []byte {
	if len(b) < 2 || b[0] != ctrlPrefix {
		return nil
	}
	// Every application datagram must carry this connection's token, compared in constant time. body is sliced only
	// inside this guard, after its length check.
	var body []byte
	if b[1] == ctrlData || b[1] == ctrlLossy || b[1] == ctrlAck {
		if len(b) < 2+tokenLen ||
			subtle.ConstantTimeCompare(b[2:2+tokenLen], c.token[:]) != 1 {
			return nil
		}
		body = b[2+tokenLen:]
	}

	switch b[1] {
	case ctrlLossy:
		out := make([]byte, len(body))
		copy(out, body)
		return out

	case ctrlData:
		if len(body) < seqLen {
			return nil
		}
		seq := binary.BigEndian.Uint64(body[:seqLen])
		payload := body[seqLen:]

		c.relMu.Lock()
		if c.wantSeq == 0 {
			c.wantSeq = 1
		}

		// Already delivered. Re-ack: a lost ack is why the sender is retransmitting, and silence would keep it
		// retransmitting until it gives up and drops the connection.
		if seq < c.wantSeq {
			c.relMu.Unlock()
			c.sendAck(seq)
			return nil
		}

		// Arrived ahead of something in flight: hold it, so nothing above sees a later message before an earlier one.
		// Not acked while held: acking now and meeting a full queue at delivery would lose it with the sender
		// believing it landed.
		if seq > c.wantSeq {
			if c.reorderBuf == nil {
				c.reorderBuf = map[uint64][]byte{}
			}
			if _, held := c.reorderBuf[seq]; !held && len(c.reorderBuf) < reorderWindow {
				buf := make([]byte, len(payload))
				copy(buf, payload)
				c.reorderBuf[seq] = buf
			}
			c.relMu.Unlock()
			return nil
		}

		// The one being waited for: it and any contiguous run it unblocks go up now. Deliver before acking, and ack
		// only what was delivered: deliver drops on a full queue, and an acked payload is never retransmitted.
		out := make([]byte, len(payload))
		copy(out, payload)
		curSeq, cur, buffered := seq, out, false

		var acks []uint64
		for {
			if !c.deliver(cur) {
				// Nothing was consumed: a buffered payload stays in the map with wantSeq on it, and a just-arrived
				// one is still held by the sender. Either is retried, and the next arrival re-runs this drain.
				break
			}
			acks = append(acks, curSeq)
			if buffered {
				delete(c.reorderBuf, curSeq)
			}
			c.wantSeq = curSeq + 1

			next, ok := c.reorderBuf[c.wantSeq]
			if !ok {
				break
			}
			curSeq, cur, buffered = c.wantSeq, next, true
		}
		c.relMu.Unlock()

		for _, a := range acks {
			c.sendAck(a)
		}
		return nil

	case ctrlAck:
		if len(body) < seqLen {
			return nil
		}
		seq := binary.BigEndian.Uint64(body[:seqLen])
		c.relMu.Lock()
		delete(c.pending, seq)
		c.relMu.Unlock()
		return nil
	}
	return nil
}

// CloseWrite half-closes this connection: no new payload may be written, while queued ones keep being retransmitted,
// acks keep flowing and Read keeps working. transport.CloseGracefully relies on it, since Close ends retryLoop (a
// Reject would get one datagram) and unregisters the Conn (the drain would read nothing).
func (c *Conn) CloseWrite() error {
	c.writeClosed.Store(true)
	return nil
}

func (c *Conn) Close() error { return c.closeWith(nil) }

// closeWith is Close, recording why: a nil reason means this side decided to, anything else is the cause Read and
// Write report instead of a bare net.ErrClosed.
func (c *Conn) closeWith(reason error) error {
	c.once.Do(func() {
		// Before the channel close, which publishes it.
		c.closeErr = reason
		close(c.closed)
		if c.owner != nil {
			c.owner.forget(c.remote.String())
		} else {
			// A dialed Conn owns its socket outright; an accepted one
			// shares the listener's, which the listener closes.
			_ = c.pc.Close()
		}
	})
	return nil
}

func (c *Conn) LocalAddr() net.Addr  { return c.pc.LocalAddr() }
func (c *Conn) RemoteAddr() net.Addr { return c.remote }

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

// deliver hands one datagram to this Conn, reporting whether it was accepted. Never blocks: it runs on the listener's
// single read loop. handleControl must not acknowledge a payload deliver refused.
func (c *Conn) deliver(b []byte) bool {
	select {
	case c.in <- b:
		return true
	default:
		return false
	}
}
