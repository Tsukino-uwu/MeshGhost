package udpconn

import (
	"crypto/subtle"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

// Split out of udpconn.go on 2026-08-27, along the banner comments that file had already drawn
// around its four concerns -- so the cut lines were chosen by whoever wrote them, not by this
// pass. Same precedent as relay/online.go into one file per plane (2026-08-25). udpconn.go keeps
// the package doc, the wire format, the constants and ErrDatagramTooLarge, which every part uses.
//
// Conn: one remote address presented as an ordinary net.Conn, with the reliability, ordering
// and reorder-window machinery that costs relay/ zero lines.

// ------------------------------------------------------------------- Conn

// Conn is one remote address's view of the shared socket, presented as a
// net.Conn so transport can wrap it in the same NDJSON framing it
// applies to TCP.
type Conn struct {
	pc     *net.UDPConn
	remote *net.UDPAddr
	owner  *Listener // nil for a dialed (client-side) Conn

	// token is this connection's unpredictable secret, issued by the
	// listener on admission and required on every application datagram
	// afterwards. See tokenLen for why address validation alone is not
	// enough.
	token [tokenLen]byte

	in     chan []byte
	closed chan struct{}
	once   sync.Once

	// readBuf holds the remainder of a datagram that did not fit in the
	// caller's buffer. Real UDP discards that remainder; an in-memory queue
	// must not, or a short Read would silently eat half a JSON line.
	// Touched only from Read, which transport calls from a single
	// goroutine.
	readBuf []byte

	mu            sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time

	// Reliability state. Write goes through here; WriteUnreliable does not
	// touch any of it.
	relMu   sync.Mutex
	nextSeq uint64
	pending map[uint64]*pendingMsg

	// wantSeq is the next sequence number that may be delivered, and
	// reorderBuf holds payloads that arrived ahead of it. Together they make
	// the reliable path ordered as well as reliable.
	//
	// These replaced a plain seen-set: with in-order delivery a duplicate is
	// just seq < wantSeq, so the old set and its 1024-entry pruning are no
	// longer needed to recognise one.
	//
	// wantSeq is initialised lazily rather than at construction because
	// there are two construction sites; 0 means "not yet started" and is
	// promoted to 1, which is the first value Write can assign (it
	// increments before use).
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
		return 0, net.ErrClosed
	}
}

// Write sends p reliably: it is retransmitted until the far end acks it or
// the retry budget runs out, at which point the connection is closed
// (which relay already turns into a normal leave).
//
// Payloads are also delivered to the far end IN ORDER. That is not free on
// a datagram transport and is not implied by retransmission: the receive
// path holds anything that arrives early until the gap ahead of it fills
// (see handleControl's ctrlData case). Before that, this comment claimed
// "TCP-like semantics" while delivering out of order under loss, and
// relay's lifecycle messages ride this path — a leave overtaking
// its own join stranded that peer's ghost for the whole session.
//
// Reliable is the default because this is a net.Conn: anything holding one
// generically — transport's framing, a future caller, a test —
// gets TCP-like semantics without having to know it is on UDP. The lossy
// fast path is the explicit opt-out, WriteUnreliable, and only the state
// plane uses it.
//
// It does not block waiting for the ack. Blocking would stall
// relay's Forward loop for every other recipient behind one slow
// peer, and the guarantee callers actually need is "this will keep trying",
// not "this has arrived by the time Write returns". A peer that never acks
// is a peer that has gone away, and closing is the right report for that.
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

// WriteUnreliable sends p once, with no sequence number, no ack and no
// retransmission. It is still framed — `0xFF 0x07 <token8>` ahead of the
// NDJSON line, 10 bytes — because every application datagram must carry the
// token; an unwrapped one would be a way to simply not carry it, and is
// dropped on arrival. (This comment also claimed the payload went on the wire
// "exactly as the NDJSON line and nothing else", which stopped being true when
// the token became mandatory. Corrected 2026-08-17.)
//
// Dropping is the correct behaviour rather than a regrettable one: the
// state plane is explicitly lossy and latest-wins (agent_docs/contract.md),
// so a lost position sample is superseded by the next one ~50ms later
// rather than missed. Retransmitting it would deliver stale data late,
// which is worse than not delivering it at all.
func (c *Conn) WriteUnreliable(p []byte) (int, error) {
	if err := c.checkWritable(p, 2+tokenLen); err != nil {
		return 0, err
	}
	wire := make([]byte, 0, 2+tokenLen+len(p))
	wire = append(wire, ctrlPrefix, ctrlLossy)
	wire = append(wire, c.token[:]...)
	wire = append(wire, p...)
	return c.rawWrite(wire)
}

// checkWritable rejects a write that is closed or would risk IP
// fragmentation, accounting for overhead bytes the caller's payload will
// gain on the wire.
func (c *Conn) checkWritable(p []byte, overhead int) error {
	select {
	case <-c.closed:
		return net.ErrClosed
	default:
	}
	if len(p)+overhead > MaxDatagramBytes {
		return fmt.Errorf("%w: %d bytes (+%d framing), limit %d — use the tcp transport for messages this large",
			ErrDatagramTooLarge, len(p), overhead, MaxDatagramBytes)
	}
	return nil
}

func (c *Conn) rawWrite(b []byte) (int, error) {
	c.mu.Lock()
	dl := c.writeDeadline
	c.mu.Unlock()
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
				// The peer stopped acking entirely. Treat it as gone
				// rather than retrying forever: UDP has no disconnect
				// signal, so this is the only way a vanished client is
				// ever noticed, and relay's existing disconnect
				// path turns it into a real leave for the rest of the room.
				c.Close()
				return
			}
			for _, w := range resend {
				if _, err := c.rawWrite(w); err != nil {
					return
				}
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

// handleControl processes one control datagram, returning a payload for the
// caller to deliver or nil. Shared by the listener's demultiplexer and a
// dialed conn's own read loop, so the two cannot drift.
//
// Reliable payloads (ctrlData) are delivered HERE rather than returned,
// because acking correctly requires knowing whether delivery succeeded.
// Only the lossy path returns a payload, where dropping is the intended
// behaviour anyway.
func (c *Conn) handleControl(b []byte) []byte {
	if len(b) < 2 || b[0] != ctrlPrefix {
		return nil
	}
	// Every application datagram must carry this connection's token.
	// Address validation gated admission; this gates everything after it,
	// so guessing a client's ip:port is not enough to inject into its
	// session. Constant-time, for the same reason the room-code compare in
	// relay is. See tokenLen.
	//
	// body is sliced inside this guard, not after it. It used to be computed
	// unconditionally for every message type, which stayed in bounds only by
	// two coincidences: both callers pass buf[:n] out of a MaxDatagramBytes
	// array, so slicing past len was still within cap, and body went unused
	// for the types that skip the check. Neither is a property to lean on in
	// the most exposed surface in the repo.
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

		// Already delivered. Re-ack and stop: a lost ack is exactly why the
		// sender is retransmitting, and silence would keep it retransmitting
		// until it gives up and drops the connection.
		if seq < c.wantSeq {
			c.relMu.Unlock()
			c.sendAck(seq)
			return nil
		}

		// Arrived ahead of something still in flight. Hold it, so nothing
		// above here ever sees a later message before an earlier one — a
		// leave overtaking its own join used to strand that peer's ghost
		// permanently (see core's TestLeaveIsNotUndoneByALateJoin).
		//
		// Deliberately NOT acked while it sits here, which is what keeps the
		// "ack only what was actually delivered" rule below intact: acking
		// now and hitting a full queue at delivery time would lose the
		// payload with the sender believing it landed. Unacked means the
		// sender keeps retransmitting until it is genuinely delivered.
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

		// This is the one being waited for, so it and any contiguous run it
		// unblocks can go up now.
		//
		// Deliver BEFORE acking, and ack only if delivery succeeded. The
		// obvious order — ack, record, then hand upward — is wrong, and
		// wrong in a way that silently defeats the entire reliability layer:
		// deliver drops when the queue is full, but the sender has its ack
		// by then so it never retransmits. A join, leave or welcome could
		// vanish under a burst while Write reported success. Only reachable
		// with a stalled reader and a full queue, which is why no test
		// caught it; found in review.
		out := make([]byte, len(payload))
		copy(out, payload)
		curSeq, cur, buffered := seq, out, false

		var acks []uint64
		for {
			if !c.deliver(cur) {
				// Nothing was consumed: a buffered payload is still in the
				// map and wantSeq still points at it, and a just-arrived one
				// is still held by the sender. Either way it is retried, and
				// the next arrival re-runs this drain.
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

func (c *Conn) Close() error {
	c.once.Do(func() {
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

// deliver hands one datagram to this Conn, reporting whether it was
// accepted. Never blocks: this runs on the listener's single read loop, so
// waiting for one slow reader would stall every other connection.
//
// The bool is load-bearing for reliable delivery — see handleControl, which
// must not acknowledge a payload it could not hand over.
func (c *Conn) deliver(b []byte) bool {
	select {
	case c.in <- b:
		return true
	default:
		return false
	}
}
