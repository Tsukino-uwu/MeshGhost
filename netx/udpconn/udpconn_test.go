//go:build meshghost_devudp

package udpconn

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

const testTimeout = 3 * time.Second

// rawPeer is a bare UDP socket that talks to one address. Unconnected, like the shipped dialer's: connecting a udp
// socket to loopback depends on the host's network stack and filter drivers, not on this code. Each rawPeer has its
// own ephemeral source address, which is what "from another address" means to the cookie check.
type rawPeer struct {
	pc *net.UDPConn
	to *net.UDPAddr
}

func dialRaw(t *testing.T, to net.Addr) *rawPeer {
	t.Helper()
	ua, err := net.ResolveUDPAddr("udp", to.String())
	if err != nil {
		t.Fatalf("resolve %s: %v", to, err)
	}
	if ua.IP == nil || ua.IP.IsUnspecified() {
		// A dialed conn's local address is the unspecified one (the dialer binds a nil address), so it resolves to
		// [::]:port, which Linux takes as localhost and Windows refuses. Loopback is what both mean.
		ua.IP = net.IPv6loopback
		if ip4 := ua.IP.To4(); ip4 != nil {
			ua.IP = ip4
		}
	}
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		t.Fatalf("raw listen: %v", err)
	}
	return &rawPeer{pc: pc, to: ua}
}

func (r *rawPeer) Write(b []byte) (int, error)       { return r.pc.WriteToUDP(b, r.to) }
func (r *rawPeer) Read(b []byte) (int, error)        { n, _, err := r.pc.ReadFromUDP(b); return n, err }
func (r *rawPeer) SetReadDeadline(t time.Time) error { return r.pc.SetReadDeadline(t) }
func (r *rawPeer) Close() error                      { return r.pc.Close() }

func listenTest(t *testing.T) *Listener {
	t.Helper()
	l, err := Listen("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}

// dialAndAccept completes a full validated connection and returns both
// ends, failing the test if either side does not appear.
func dialAndAccept(t *testing.T, l *Listener) (client, server net.Conn) {
	t.Helper()
	type accepted struct {
		c   net.Conn
		err error
	}
	ch := make(chan accepted, 1)
	go func() {
		c, err := l.Accept()
		ch <- accepted{c, err}
	}()

	client, err := Dial(l.Addr().String(), testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { client.Close() })

	select {
	case a := <-ch:
		if a.err != nil {
			t.Fatalf("accept: %v", a.err)
		}
		t.Cleanup(func() { a.c.Close() })
		return client, a.c
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for Accept after a successful Dial")
		return nil, nil
	}
}

// TestRoundTripBothDirections: a demultiplexed pseudo-conn behaves like the net.Conn the rest of the code expects.
func TestRoundTripBothDirections(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	if _, err := client.Write([]byte(`{"from":"client"}` + "\n")); err != nil {
		t.Fatalf("client write: %v", err)
	}
	if got := readOne(t, server); got != `{"from":"client"}`+"\n" {
		t.Errorf("server read %q", got)
	}

	if _, err := server.Write([]byte(`{"from":"server"}` + "\n")); err != nil {
		t.Fatalf("server write: %v", err)
	}
	if got := readOne(t, client); got != `{"from":"server"}`+"\n" {
		t.Errorf("client read %q", got)
	}
}

func readOne(t *testing.T, c net.Conn) string {
	t.Helper()
	if err := c.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	buf := make([]byte, MaxDatagramBytes)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(buf[:n])
}

// TestUnvalidatedSourceNeverReachesAccept: a source that has not proved it receives at its address gets no
// connection, or a spoofed source could drive the relay and use it as a reflector.
func TestUnvalidatedSourceNeverReachesAccept(t *testing.T) {
	l := listenTest(t)

	raw := dialRaw(t, l.Addr())
	defer raw.Close()

	// Straight to data, skipping the exchange entirely.
	if _, err := raw.Write([]byte(`{"unvalidated":true}` + "\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	// And a confirm carrying a cookie that was never issued.
	bogus := append([]byte{ctrlPrefix, ctrlConfirm}, make([]byte, cookieLen)...)
	if _, err := raw.Write(bogus); err != nil {
		t.Fatalf("write: %v", err)
	}

	assertNoAccept(t, l, 300*time.Millisecond)
}

// TestCookieFromOneAddressDoesNotValidateAnother: a cookie is bound to the address it was issued for, so a harvested
// one cannot be replayed from elsewhere.
func TestCookieFromOneAddressDoesNotValidateAnother(t *testing.T) {
	l := listenTest(t)

	// Obtain a real cookie the legitimate way, from address A.
	a := dialRaw(t, l.Addr())
	defer a.Close()
	if _, err := a.Write([]byte{ctrlPrefix, ctrlHello}); err != nil {
		t.Fatalf("hello: %v", err)
	}
	if err := a.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, 64)
	n, err := a.Read(buf)
	if err != nil {
		t.Fatalf("read cookie: %v", err)
	}
	if n < 2+cookieLen || buf[0] != ctrlPrefix || buf[1] != ctrlCookie {
		t.Fatalf("did not get a cookie back, got % x", buf[:n])
	}
	cookie := append([]byte(nil), buf[2:2+cookieLen]...)

	// Replay it from a different source address B.
	b := dialRaw(t, l.Addr())
	defer b.Close()
	if _, err := b.Write(append([]byte{ctrlPrefix, ctrlConfirm}, cookie...)); err != nil {
		t.Fatalf("replay: %v", err)
	}

	assertNoAccept(t, l, 300*time.Millisecond)
}

func assertNoAccept(t *testing.T, l *Listener, within time.Duration) {
	t.Helper()
	ch := make(chan net.Conn, 1)
	go func() {
		c, err := l.Accept()
		if err == nil {
			ch <- c
		}
	}()
	select {
	case c := <-ch:
		c.Close()
		t.Fatal("listener accepted a connection from an address that never validated")
	case <-time.After(within):
	}
}

// TestReadPreservesAPartiallyConsumedDatagram: real UDP discards what does not fit the caller's buffer; the in-memory
// queue must not, or a reader with a small buffer would lose the tail of a line.
func TestReadPreservesAPartiallyConsumedDatagram(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	const line = `{"abcdefghij":1}` + "\n"
	if _, err := client.Write([]byte(line)); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	var got []byte
	small := make([]byte, 4)
	for len(got) < len(line) {
		n, err := server.Read(small)
		if err != nil {
			t.Fatalf("read: %v (got %q so far)", err, got)
		}
		got = append(got, small[:n]...)
	}
	if string(got) != line {
		t.Errorf("reassembled %q, want %q", got, line)
	}
}

// TestOversizedWriteIsRefusedNotFragmented: a datagram large enough to be fragmented is lost whole when any fragment
// is, so the write is refused with an error naming the fix.
func TestOversizedWriteIsRefusedNotFragmented(t *testing.T) {
	l := listenTest(t)
	client, _ := dialAndAccept(t, l)

	_, err := client.Write(make([]byte, MaxDatagramBytes+1))
	if err == nil {
		t.Fatal("oversized write succeeded, want an error")
	}
	if !errors.Is(err, ErrDatagramTooLarge) {
		t.Errorf("error = %v, want it to wrap ErrDatagramTooLarge", err)
	}
	if !strings.Contains(err.Error(), "tcp") {
		t.Errorf("error %q should name the workaround (the tcp transport)", err)
	}

	// The refusal must also say, structurally, that nothing reached the wire, so transport.Send keeps the session.
	// Asserted on both sides because transport cannot import this package, and through the %w wrap as it arrives.
	var nw interface{ NotWritten() bool }
	if !errors.As(err, &nw) {
		t.Fatalf("error %v does not implement NotWritten; transport.Send will close the "+
			"connection over a message that never left this process", err)
	}
	if !nw.NotWritten() {
		t.Error("NotWritten() = false for an error produced before the write")
	}
}

// TestReadDeadlineExpires: transport's idle timeout depends on read deadlines, since UDP has no disconnect signal of
// its own.
func TestReadDeadlineExpires(t *testing.T) {
	l := listenTest(t)
	_, server := dialAndAccept(t, l)

	if err := server.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	start := time.Now()
	_, err := server.Read(make([]byte, 64))
	if err == nil {
		t.Fatal("read succeeded with nothing sent, want a deadline error")
	}
	if elapsed := time.Since(start); elapsed > testTimeout {
		t.Errorf("read blocked %s past its deadline", elapsed)
	}
}

// TestCookieIsBoundToItsTimeSlot pins the derivation, so a refactor cannot make cookies constant and every captured
// one valid forever.
func TestCookieIsBoundToItsTimeSlot(t *testing.T) {
	secret := []byte("test-secret-not-used-on-the-wire")
	now := time.Now()
	slot := currentSlot(now)

	if c1, c2 := cookieFor(secret, "1.2.3.4:5", slot), cookieFor(secret, "1.2.3.4:5", slot+1); string(c1) == string(c2) {
		t.Error("cookie is identical across time slots; a captured one would never expire")
	}
	if c1, c2 := cookieFor(secret, "1.2.3.4:5", slot), cookieFor(secret, "1.2.3.4:6", slot); string(c1) == string(c2) {
		t.Error("cookie is identical across addresses; it would not validate anything")
	}
	if !validCookie(secret, "1.2.3.4:5", cookieFor(secret, "1.2.3.4:5", slot-1), now) {
		t.Error("previous slot's cookie rejected; a client on a slow link would never connect")
	}
	if validCookie(secret, "1.2.3.4:5", cookieFor(secret, "1.2.3.4:5", slot-5), now) {
		t.Error("a long-expired cookie was accepted")
	}
}

// TestInjectionFromTheRightAddressWithTheWrongTokenIsDropped: a datagram from the client's real address, correctly
// framed but carrying a wrong token, is dropped. That is what the token adds over address validation.
func TestInjectionFromTheRightAddressWithTheWrongTokenIsDropped(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	// A legitimate message first, to prove the channel works and what delivered looks like.
	const real = `{"legit":true}` + "\n"
	if _, err := client.Write([]byte(real)); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := readOne(t, server); got != real {
		t.Fatalf("server read %q, want %q", got, real)
	}

	// Now forge one from the client's own socket — same source address,
	// same framing, wrong token.
	raw := client.(*Conn)
	forged := append([]byte{ctrlPrefix, ctrlLossy}, make([]byte, tokenLen)...)
	for i := range forged[2 : 2+tokenLen] {
		forged[2+i] = raw.token[i] ^ 0xFF // guaranteed different
	}
	forged = append(forged, []byte(`{"forged":true}`+"\n")...)
	if _, err := raw.rawWrite(forged); err != nil {
		t.Fatalf("send forged: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, MaxDatagramBytes)
	n, err := server.Read(buf)
	if err == nil {
		t.Fatalf("a datagram with the wrong token was delivered: %q", buf[:n])
	}

	// A rejected forgery must not disturb the session it targeted.
	const after = `{"still":"working"}` + "\n"
	if _, err := client.Write([]byte(after)); err != nil {
		t.Fatalf("write after forgery: %v", err)
	}
	if got := readOne(t, server); got != after {
		t.Fatalf("server read %q after a rejected forgery, want %q", got, after)
	}
}

// TestUnframedDatagramsAreIgnored: a bare NDJSON line is not accepted, or the token could be bypassed by not
// using it.
func TestUnframedDatagramsAreIgnored(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	raw := client.(*Conn)
	if _, err := raw.rawWrite([]byte(`{"unframed":true}` + "\n")); err != nil {
		t.Fatalf("send unframed: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	if n, err := server.Read(make([]byte, MaxDatagramBytes)); err == nil {
		t.Fatalf("an unframed datagram was delivered (%d bytes); the token would be bypassable", n)
	}
}
