//go:build meshghost_devudp

package udpconn

import (
	"crypto/rand"
	"fmt"
	"net"
	"sync"
	"time"
)

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

	// wmu serializes writes on pc, which every accepted Conn shares: the write deadline is per-socket state (see
	// Conn.socketWriteMu).
	wmu sync.Mutex
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
			// Nothing this package sends is that large, so it is not ours; it is still read in full (see
			// readBufferBytes).
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
			// Stateless challenge: nothing is remembered about this address until it proves it receives at the
			// address it claims.
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
			// Only for an admitted connection, and handleControl also requires its token, so neither an
			// unvalidated source nor one that guessed a live client's ip:port can inject on anyone's behalf.
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

	// Anything else is not application data either: every real payload is a control frame, so it is dropped.
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
	if existing, exists := l.conns[key]; exists {
		l.mu.Unlock()
		// Re-send the token: the retry means the client has not seen a ready, and silence would turn one lost ready
		// into a failed Dial. Same connection, same token.
		ready := append([]byte{ctrlPrefix, ctrlReady}, existing.token[:]...)
		_, _ = l.pc.WriteToUDP(ready, remote)
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

	// Never block: admit runs on readLoop, the one goroutine reading the socket for every connection, so a full
	// accept queue would stall them all. A dropped admission costs one handshake, which the client's confirm retries
	// re-run, and forgetting the key means no token is issued for a session the listener will never serve.
	select {
	case l.accept <- c:
	case <-l.closed:
		l.forget(key)
		return
	default:
		l.forget(key)
		return
	}

	// Hand the token over. If it is lost, the client's next confirm makes admit above re-send it.
	ready := append([]byte{ctrlPrefix, ctrlReady}, c.token[:]...)
	_, _ = l.pc.WriteToUDP(ready, remote)
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

		// Snapshot under the lock, close outside it: Conn.Close takes c.once and then l.mu (in forget), so holding
		// l.mu across c.once.Do deadlocks against a peer disconnecting now. Emptying the map under the same lock
		// leaves forget redundant for these conns rather than racing it.
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
