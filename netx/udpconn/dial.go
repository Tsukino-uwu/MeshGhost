//go:build meshghost_devudp

package udpconn

import (
	"fmt"
	"net"
	"time"
)

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

	// Retry the hello: nothing beneath this exchange is reliable yet, and one dropped datagram would look like the
	// relay being down.
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

	// Confirm, then wait for the token issued on admission, retried like the hello. admit is idempotent for an address
	// that already has a Conn, so a repeated confirm just re-sends the token.
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

// fromRelay reports whether a datagram came from the address being dialled. The socket is unconnected, so the
// kernel filters no source: without this an off-path attacker spraying the ephemeral range during the connect window
// could make the client adopt a forged token. Checked in user space, since a connected socket would turn a mismatch
// into a hard failure. It does not stop an attacker who can forge the relay's address or read the traffic.
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
			// With the reason, which transport.fail would suppress as a local close if this were net.ErrClosed. A local
			// Close() finds once already spent, so it keeps its nil reason.
			c.closeWith(err)
			return
		}
		if !fromRelay(src, c.remote) {
			// Not from this Conn's relay; the token check would drop it too.
			continue
		}
		if n == 0 || n > MaxDatagramBytes {
			// Oversized: not ours (see readBufferBytes).
			continue
		}
		// Every real payload is a control frame carrying this connection's token; anything else is dropped.
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

// TransportName identifies this connection's transport to a caller holding only a net.Conn, so relay can label a
// client without importing this package.
func (c *Conn) TransportName() string { return "udp" }
