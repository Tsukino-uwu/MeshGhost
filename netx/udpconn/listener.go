package udpconn

import (
	"crypto/rand"
	"fmt"
	"net"
	"sync"
	"time"
)

// Split out of udpconn.go on 2026-08-27, along the banner comments that file had already drawn
// around its four concerns -- so the cut lines were chosen by whoever wrote them, not by this
// pass. Same precedent as relay/online.go into one file per plane (2026-08-25). udpconn.go keeps
// the package doc, the wire format, the constants and ErrDatagramTooLarge, which every part uses.
//
// Listener: one UDP socket demultiplexed into one Conn per remote address, plus admission.

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
	buf := make([]byte, readBufferBytes)
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
		if n > MaxDatagramBytes {
			// Nothing this package sends is that large, so it is not ours;
			// dropped without touching l.conns. See readBufferBytes for why
			// it must be read in full rather than left to the socket.
			continue
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

		// SNAPSHOT UNDER THE LOCK, CLOSE OUTSIDE IT. Holding l.mu across
		// c.once.Do() is a lock-ordering deadlock, found 2026-09-01 in a
		// goroutine dump from a test binary that hung for ten minutes:
		//
		//   Conn.Close   takes c.once, then calls l.forget() -> wants l.mu
		//   Listener.Close takes l.mu,  then calls c.once.Do -> wants c.once
		//
		// Opposite orders, so a peer disconnecting at the moment the
		// listener closes wedges both goroutines permanently — a relay that
		// never finishes shutting down, and (as seen) a whole test package
		// stuck behind it. Rare because the window is one map iteration
		// wide, which is exactly why it survived until an unrelated timing
		// change shook it loose.
		//
		// Taking the snapshot first removes the nesting entirely: nothing
		// here holds l.mu while touching a Conn, so forget()'s l.mu wait is
		// always against an unheld lock. Emptying the map under the same
		// lock keeps forget() correct-but-redundant for these conns rather
		// than racing it.
		l.mu.Lock()
		closing := make([]*Conn, 0, len(l.conns))
		for _, c := range l.conns {
			closing = append(closing, c)
		}
		l.conns = map[string]*Conn{}
		l.mu.Unlock()

		for _, c := range closing {
			c.once.Do(func() { close(c.closed) })
		}
	})
	return nil
}

func (l *Listener) Addr() net.Addr { return l.pc.LocalAddr() }
