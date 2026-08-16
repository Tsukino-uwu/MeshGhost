package udpconn

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

const testTimeout = 3 * time.Second

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

// TestRoundTripBothDirections is the basic proof that a demultiplexed
// pseudo-conn behaves like the net.Conn the rest of the codebase expects.
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

// TestUnvalidatedSourceNeverReachesAccept is the address-validation
// property, and the reason this package exists rather than a bare
// net.ListenUDP. A datagram whose source address has not proved it can
// receive at that address must not produce a connection, or the relay could
// be driven — and used as a reflector — by a spoofed source.
func TestUnvalidatedSourceNeverReachesAccept(t *testing.T) {
	l := listenTest(t)

	raw, err := net.Dial("udp", l.Addr().String())
	if err != nil {
		t.Fatalf("raw dial: %v", err)
	}
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

// TestCookieFromOneAddressDoesNotValidateAnother pins that the cookie is
// bound to the address it was issued for. If it were not, one honest client
// could hand its cookie to anyone, or an attacker could harvest one and
// replay it from elsewhere — which would defeat the entire point of
// validating the address.
func TestCookieFromOneAddressDoesNotValidateAnother(t *testing.T) {
	l := listenTest(t)

	// Obtain a real cookie the legitimate way, from address A.
	a, err := net.Dial("udp", l.Addr().String())
	if err != nil {
		t.Fatalf("dial a: %v", err)
	}
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
	b, err := net.Dial("udp", l.Addr().String())
	if err != nil {
		t.Fatalf("dial b: %v", err)
	}
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

// TestReadPreservesAPartiallyConsumedDatagram is the framing bug this
// package would otherwise have. Real UDP throws away whatever did not fit
// in the caller's buffer; an in-memory queue that copied that behaviour
// would silently eat the tail of a JSON line whenever a reader passed a
// small buffer, producing a parse error at a layer that could not explain
// it.
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

// TestOversizedWriteIsRefusedNotFragmented covers the MTU rule. A datagram
// large enough to be fragmented is lost whole when any one fragment is
// lost, so this returns an error naming the fix rather than sending
// something that will mysteriously fail on a real network.
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
}

// TestReadDeadlineExpires confirms deadlines work, which
// internal/transport's read loop depends on for its own idle timeout — a
// pseudo-conn that ignored them would leave a dead UDP peer's connection
// open forever, since UDP has no disconnect signal of its own.
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

// TestCookieIsBoundToItsTimeSlot pins the derivation directly, so a future
// refactor cannot quietly make cookies constant — which would make every
// captured cookie valid forever and turn address validation into
// decoration.
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

// TestInjectionFromTheRightAddressWithTheWrongTokenIsDropped is the
// property the per-connection token exists for, and the one address
// validation alone does not provide.
//
// The cookie exchange gates ADMISSION: it proves a source address is real.
// After that, a connection used to be identified by source address alone,
// so anyone able to spoof a live client's ip:port could inject state into
// its session — the thing TCP makes hard by also requiring a 32-bit
// sequence number, and the thing internal/README.md's own CelesteNet notes
// cite as why TCP is safer by construction.
//
// This test forges exactly that: a datagram sent from the client's real
// address, correctly framed, carrying a token that is merely wrong.
func TestInjectionFromTheRightAddressWithTheWrongTokenIsDropped(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	// A legitimate message first, to prove the channel works at all and to
	// establish what "delivered" looks like.
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

	// And the real connection must still work afterwards — a rejected
	// forgery must not disturb the session it targeted.
	const after = `{"still":"working"}` + "\n"
	if _, err := client.Write([]byte(after)); err != nil {
		t.Fatalf("write after forgery: %v", err)
	}
	if got := readOne(t, server); got != after {
		t.Fatalf("server read %q after a rejected forgery, want %q", got, after)
	}
}

// TestUnframedDatagramsAreIgnored covers the other half of making the token
// mandatory: a bare NDJSON line, which used to be a valid unreliable
// payload, must no longer be accepted — otherwise the token would be
// trivially bypassable by simply not using it.
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
