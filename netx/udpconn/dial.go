package udpconn

import (
	"fmt"
	"net"
	"time"
)

// Split out of udpconn.go on 2026-08-27, along the banner comments that file had already drawn
// around its four concerns -- so the cut lines were chosen by whoever wrote them, not by this
// pass. Same precedent as relay/online.go into one file per plane (2026-08-25). udpconn.go keeps
// the package doc, the wire format, the constants and ErrDatagramTooLarge, which every part uses.
//
// Dial: the client side of the handshake, and the dialed connection's own read loop.

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
		until := minTime(time.Now().Add(500*time.Millisecond), deadline)
		for cookie == nil {
			_ = pc.SetReadDeadline(until)
			n, src, err := pc.ReadFromUDP(buf)
			if err != nil {
				break // timed out waiting; send another hello
			}
			if !fromRelay(src, ua) {
				continue // not the relay: keep waiting, do not burn a retry
			}
			if n >= 2+cookieLen && buf[0] == ctrlPrefix && buf[1] == ctrlCookie {
				cookie = append([]byte(nil), buf[2:2+cookieLen]...)
			}
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
		until := minTime(time.Now().Add(500*time.Millisecond), deadline)
		for token == nil {
			_ = pc.SetReadDeadline(until)
			n, src, err := pc.ReadFromUDP(buf)
			if err != nil {
				break
			}
			if !fromRelay(src, ua) {
				continue
			}
			if n >= 2+tokenLen && buf[0] == ctrlPrefix && buf[1] == ctrlReady {
				token = append([]byte(nil), buf[2:2+tokenLen]...)
			}
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

// fromRelay reports whether a datagram came from the address being dialled.
//
// The socket is UNCONNECTED (net.ListenUDP with a nil local address), so the
// kernel applies no source filter at all and every read here returns whatever
// reached the port. Until 2026-09-08 both handshake reads discarded the sender
// entirely, so an off-path attacker who knew a player's IP could spray
// `FF 06 <8 random bytes>` across the ephemeral port range during the connect
// window: whichever landed first won the token loop, the client adopted an
// attacker-chosen token, and from then on every datagram it sent failed the
// relay's constant-time token compare and was dropped. What the player saw was
// a session that connected and then never worked, with no error on either side.
// Cheap to mount, blind, and needs no position on the path.
//
// Comparing the source is the whole defence, and it is deliberately done in
// user space rather than by connecting the socket: a connected socket would
// turn the same mismatch into a hard failure with no way to see what arrived,
// and this package's read loops already have to be tolerant of stray
// datagrams (see readBufferBytes). It does NOT defend against an attacker who
// can forge the relay's source address or read the traffic -- that is the
// standing limit of this transport, stated in the package doc, and is why quic
// exists.
func fromRelay(src, want *net.UDPAddr) bool {
	return src != nil && want != nil && src.Port == want.Port && src.IP.Equal(want.IP)
}

// dialedReadLoop is the client-side equivalent of Listener.readLoop: a
// dialed Conn owns its socket, so it does its own reading rather than being
// fed by a demultiplexer.
func (c *Conn) dialedReadLoop() {
	buf := make([]byte, readBufferBytes)
	for {
		n, src, err := c.pc.ReadFromUDP(buf)
		if err != nil {
			c.once.Do(func() { close(c.closed) })
			return
		}
		if !fromRelay(src, c.remote) {
			// Not from the relay this Conn is talking to. Dropped for the
			// reason fromRelay gives: after admission the token would catch
			// it anyway, but the handshake had no token yet.
			continue
		}
		if n == 0 || n > MaxDatagramBytes {
			// Oversized: not ours, dropped. See readBufferBytes.
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
// switch so relay can label a client without importing this
// package at all — the same structural-interface trick transport
// uses for unreliableWriter, and the reason the relay stays free of
// transport-specific imports.
func (c *Conn) TransportName() string { return "udp" }
