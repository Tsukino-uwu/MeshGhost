// Package udpconn presents a single UDP socket as an ordinary net.Listener
// handing out ordinary net.Conns, one per remote address.
//
// That shape is the whole point. internal/relay's Serve takes a
// net.Listener and handleConn a net.Conn, each connection getting its own
// goroutine — an invariant the relay leans on hard, since Client.gateMu's
// comment there says everything else needs no lock because "OnReceive is
// serial". Demultiplexing here, below that layer, means UDP support costs
// internal/relay exactly zero lines and re-audits no concurrency. See the
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
// bits here clear the same bar. This is the measure internal/README.md's
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
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
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
	// ctrlData carries a payload that must arrive: an 8-byte big-endian
	// sequence number followed by the NDJSON line. ctrlAck echoes that
	// sequence number back. Unreliable payloads are NOT wrapped at all —
	// they go on the wire as the bare line — so the hot path stays exactly
	// one datagram of pure NDJSON with no header to strip.
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
	// bar comfortably. This is the measure internal/README.md's own
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

// ---------------------------------------------------------------- cookies

// cookieFor derives the address-validation cookie for addr in the given
// time slot. Deriving rather than storing is what keeps an unauthenticated
// stranger from growing the listener's memory — see the package doc.
func cookieFor(secret []byte, addr string, slot int64) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(addr))
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(slot))
	m.Write(b[:])
	return m.Sum(nil)[:cookieLen]
}

func currentSlot(now time.Time) int64 { return now.UnixNano() / int64(cookieSlot) }

// validCookie reports whether got is the cookie for addr in either the
// current or the previous slot. Constant-time, so a wrong guess cannot be
// refined byte by byte the way the room-code comparison in internal/relay
// already guards against.
func validCookie(secret []byte, addr string, got []byte, now time.Time) bool {
	if len(got) != cookieLen {
		return false
	}
	slot := currentSlot(now)
	for _, s := range []int64{slot, slot - 1} {
		if subtle.ConstantTimeCompare(got, cookieFor(secret, addr, s)) == 1 {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------------- Conn

// Conn is one remote address's view of the shared socket, presented as a
// net.Conn so internal/transport can wrap it in the same NDJSON framing it
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
	// Touched only from Read, which internal/transport calls from a single
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
// (which internal/relay already turns into a normal leave).
//
// Payloads are also delivered to the far end IN ORDER. That is not free on
// a datagram transport and is not implied by retransmission: the receive
// path holds anything that arrives early until the gap ahead of it fills
// (see handleControl's ctrlData case). Before that, this comment claimed
// "TCP-like semantics" while delivering out of order under loss, and
// internal/relay's lifecycle messages ride this path — a leave overtaking
// its own join stranded that peer's ghost for the whole session.
//
// Reliable is the default because this is a net.Conn: anything holding one
// generically — internal/transport's framing, a future caller, a test —
// gets TCP-like semantics without having to know it is on UDP. The lossy
// fast path is the explicit opt-out, WriteUnreliable, and only the state
// plane uses it.
//
// It does not block waiting for the ack. Blocking would stall
// internal/relay's Forward loop for every other recipient behind one slow
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

// WriteUnreliable sends p as a bare datagram, once, with no sequence
// number, no ack and no retransmission — so the payload on the wire is
// exactly the NDJSON line and nothing else.
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
				// ever noticed, and internal/relay's existing disconnect
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
	// internal/relay is. See tokenLen.
	if b[1] == ctrlData || b[1] == ctrlLossy || b[1] == ctrlAck {
		if len(b) < 2+tokenLen ||
			subtle.ConstantTimeCompare(b[2:2+tokenLen], c.token[:]) != 1 {
			return nil
		}
	}
	body := b[2+tokenLen:]

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
		// permanently (see internal/core's TestLeaveIsNotUndoneByALateJoin).
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

// --------------------------------------------------------------- Listener

// Listener is a net.Listener over one UDP socket, demultiplexing by remote
// address.
type Listener struct {
	pc     *net.UDPConn
	secret []byte

	accept chan *Conn
	closed chan struct{}
	once   sync.Once

	mu    sync.Mutex
	conns map[string]*Conn
}

// Listen binds addr and starts demultiplexing. The returned Listener
// satisfies net.Listener, so relay.Serve consumes it unchanged.
func Listen(addr string) (*Listener, error) {
	ua, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("udpconn: resolve %s: %w", addr, err)
	}
	pc, err := net.ListenUDP("udp", ua)
	if err != nil {
		return nil, fmt.Errorf("udpconn: listen %s: %w", addr, err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		_ = pc.Close()
		return nil, fmt.Errorf("udpconn: generate cookie secret: %w", err)
	}
	l := &Listener{
		pc:     pc,
		secret: secret,
		accept: make(chan *Conn, 16),
		closed: make(chan struct{}),
		conns:  map[string]*Conn{},
	}
	go l.readLoop()
	return l, nil
}

func (l *Listener) readLoop() {
	buf := make([]byte, MaxDatagramBytes)
	for {
		n, remote, err := l.pc.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-l.closed:
			default:
				l.Close()
			}
			return
		}
		l.handle(buf[:n], remote)
	}
}

func (l *Listener) handle(b []byte, remote *net.UDPAddr) {
	if len(b) == 0 {
		return
	}
	key := remote.String()

	if b[0] == ctrlPrefix {
		if len(b) < 2 {
			return
		}
		switch b[1] {
		case ctrlHello:
			// Stateless challenge: nothing is remembered about this
			// address until it proves it can receive at the address it
			// claims. See the package doc on why storing would be worse.
			out := append([]byte{ctrlPrefix, ctrlCookie}, cookieFor(l.secret, key, currentSlot(time.Now()))...)
			_, _ = l.pc.WriteToUDP(out, remote)
			return
		case ctrlConfirm:
			if !validCookie(l.secret, key, b[2:], time.Now()) {
				return
			}
			l.admit(remote, key)
			return
		case ctrlData, ctrlLossy, ctrlAck:
			// Application traffic, which only means anything for an
			// already-admitted connection — and handleControl additionally
			// requires that connection's own token, so neither an
			// unvalidated source nor one that merely guessed a live
			// client's ip:port can inject on anyone's behalf.
			if c := l.lookup(key); c != nil {
				if payload := c.handleControl(b); payload != nil {
					c.deliver(payload)
				}
			}
			return
		default:
			return
		}
	}

	// Anything that is not a control frame is not application data either:
	// since the token became mandatory, every real payload is wrapped. An
	// unwrapped datagram is either an old peer or a probe, and is dropped.
}

func (l *Listener) lookup(key string) *Conn {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.conns[key]
}

// admit creates and queues a Conn for a validated address, unless one
// already exists — a retransmitted confirm must not replace a live
// connection, which would strand whatever the relay had already associated
// with it.
func (l *Listener) admit(remote *net.UDPAddr, key string) {
	l.mu.Lock()
	if _, exists := l.conns[key]; exists {
		l.mu.Unlock()
		return
	}
	c := &Conn{
		pc:     l.pc,
		remote: remote,
		owner:  l,
		in:     make(chan []byte, readQueue),
		closed: make(chan struct{}),
	}
	if _, err := rand.Read(c.token[:]); err != nil {
		l.mu.Unlock()
		return
	}
	l.conns[key] = c
	l.mu.Unlock()

	// Hand the token over. Retransmitted by the client's own confirm
	// retries if this datagram is lost: an unanswered confirm makes the
	// client send another, and admit above is idempotent for an address
	// that already has a Conn, so this send is what repeats.
	ready := append([]byte{ctrlPrefix, ctrlReady}, c.token[:]...)
	_, _ = l.pc.WriteToUDP(ready, remote)

	select {
	case l.accept <- c:
	case <-l.closed:
	}
}

func (l *Listener) forget(key string) {
	l.mu.Lock()
	delete(l.conns, key)
	l.mu.Unlock()
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
		_ = l.pc.Close()
		l.mu.Lock()
		for _, c := range l.conns {
			c.once.Do(func() { close(c.closed) })
		}
		l.conns = map[string]*Conn{}
		l.mu.Unlock()
	})
	return nil
}

func (l *Listener) Addr() net.Addr { return l.pc.LocalAddr() }

// ------------------------------------------------------------------- Dial

// Dial completes the address-validation exchange with a udpconn listener at
// addr and returns the resulting net.Conn. It blocks for at most timeout.
func Dial(addr string, timeout time.Duration) (net.Conn, error) {
	ua, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("udpconn: resolve %s: %w", addr, err)
	}
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, fmt.Errorf("udpconn: open socket: %w", err)
	}
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	deadline := time.Now().Add(timeout)
	if err := pc.SetDeadline(deadline); err != nil {
		_ = pc.Close()
		return nil, err
	}

	// Retry the hello rather than sending one and hoping: this exchange is
	// the one part of the connection that has no reliability underneath it
	// yet, and a single dropped datagram here would look to the user like
	// "the relay is down" rather than "one packet was lost".
	buf := make([]byte, MaxDatagramBytes)
	var cookie []byte
	for cookie == nil && time.Now().Before(deadline) {
		if _, err := pc.WriteToUDP([]byte{ctrlPrefix, ctrlHello}, ua); err != nil {
			_ = pc.Close()
			return nil, fmt.Errorf("udpconn: send hello: %w", err)
		}
		_ = pc.SetReadDeadline(minTime(time.Now().Add(500*time.Millisecond), deadline))
		n, _, err := pc.ReadFromUDP(buf)
		if err != nil {
			continue // timed out waiting; send another hello
		}
		if n >= 2+cookieLen && buf[0] == ctrlPrefix && buf[1] == ctrlCookie {
			cookie = append([]byte(nil), buf[2:2+cookieLen]...)
		}
	}
	if cookie == nil {
		_ = pc.Close()
		return nil, fmt.Errorf("udpconn: no response from %s within %s (is the relay serving the udp transport on this port?)", addr, timeout)
	}

	// Confirm, then wait for the token the listener issues on admission.
	// Retried for the same reason the hello is: this leg has no reliability
	// underneath it yet, and a single lost datagram would otherwise look
	// like "the relay is down". admit is idempotent for an address that
	// already has a Conn, so a repeated confirm just re-sends the token.
	confirm := append([]byte{ctrlPrefix, ctrlConfirm}, cookie...)
	var token []byte
	for token == nil && time.Now().Before(deadline) {
		if _, err := pc.WriteToUDP(confirm, ua); err != nil {
			_ = pc.Close()
			return nil, fmt.Errorf("udpconn: send confirm: %w", err)
		}
		_ = pc.SetReadDeadline(minTime(time.Now().Add(500*time.Millisecond), deadline))
		n, _, err := pc.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		if n >= 2+tokenLen && buf[0] == ctrlPrefix && buf[1] == ctrlReady {
			token = append([]byte(nil), buf[2:2+tokenLen]...)
		}
	}
	if token == nil {
		_ = pc.Close()
		return nil, fmt.Errorf("udpconn: %s never confirmed the connection within %s", addr, timeout)
	}

	if err := pc.SetDeadline(time.Time{}); err != nil {
		_ = pc.Close()
		return nil, err
	}

	c := &Conn{
		pc:     pc,
		remote: ua,
		in:     make(chan []byte, readQueue),
		closed: make(chan struct{}),
	}
	copy(c.token[:], token)
	go c.dialedReadLoop()
	return c, nil
}

// dialedReadLoop is the client-side equivalent of Listener.readLoop: a
// dialed Conn owns its socket, so it does its own reading rather than being
// fed by a demultiplexer.
func (c *Conn) dialedReadLoop() {
	buf := make([]byte, MaxDatagramBytes)
	for {
		n, err := c.pc.Read(buf)
		if err != nil {
			c.once.Do(func() { close(c.closed) })
			return
		}
		if n == 0 {
			continue
		}
		// Every real payload is wrapped in a control frame carrying this
		// connection's token, so anything else is dropped.
		if buf[0] == ctrlPrefix {
			if payload := c.handleControl(buf[:n]); payload != nil {
				c.deliver(payload)
			}
		}
	}
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

// TransportName identifies this connection's transport to a caller holding
// only a net.Conn. Declared as a method rather than exposed through a type
// switch so internal/relay can label a client without importing this
// package at all — the same structural-interface trick internal/transport
// uses for unreliableWriter, and the reason the relay stays free of
// transport-specific imports.
func (c *Conn) TransportName() string { return "udp" }
