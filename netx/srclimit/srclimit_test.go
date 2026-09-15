package srclimit

import (
	"fmt"
	"net"
	"testing"
	"time"
)

type fakeConn struct {
	net.Conn
	remote net.Addr
}

func (f fakeConn) RemoteAddr() net.Addr { return f.remote }

func tcpAddr(t *testing.T, s string) net.Addr {
	t.Helper()
	a, err := net.ResolveTCPAddr("tcp", s)
	if err != nil {
		t.Fatalf("resolve %s: %v", s, err)
	}
	return a
}

// clock is a settable now() so the bucket's leak is asserted, not slept for.
type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newTable(t *testing.T, o Options) (*Table, *clock) {
	t.Helper()
	c := &clock{t: time.Unix(1_000_000, 0)}
	tb := New(o)
	tb.now = c.now
	return tb, c
}

func TestOpenConnectionsAreCappedPerAddressAndFreedOnRelease(t *testing.T) {
	tb, _ := newTable(t, Options{MaxOpenPerSource: 2})
	a := tcpAddr(t, "192.0.2.1:1111")
	b := tcpAddr(t, "192.0.2.2:1111")
	if !tb.Acquire(a) || !tb.Acquire(a) {
		t.Fatal("the first two connections from one address were refused")
	}
	if tb.Acquire(a) {
		t.Fatal("a third connection from one address was accepted past the cap")
	}
	// Different ports, same host: still the same source.
	if tb.Acquire(tcpAddr(t, "192.0.2.1:2222")) {
		t.Fatal("the cap is keyed by port, not by host")
	}
	if !tb.Acquire(b) {
		t.Fatal("another address was refused because the first was at its cap")
	}
	tb.Release(a)
	if !tb.Acquire(a) {
		t.Fatal("a released slot was not freed")
	}
	refusedOpen, _, _ := tb.Counts()
	if refusedOpen != 2 {
		t.Fatalf("refusedOpen = %d, want 2", refusedOpen)
	}
}

func TestAnUnkeyableAddressIsNeverCounted(t *testing.T) {
	tb, _ := newTable(t, Options{MaxOpenPerSource: 1})
	pipe, _ := net.Pipe()
	defer pipe.Close()
	for i := 0; i < 5; i++ {
		if !tb.Acquire(pipe.RemoteAddr()) {
			t.Fatalf("an address without a host:port shape was refused on try %d", i)
		}
	}
	if tb.Len() != 0 {
		t.Fatalf("%d entries remembered for an unkeyable address, want 0", tb.Len())
	}
}

func TestIPv6ZonesDoNotSplitOneSource(t *testing.T) {
	tb, _ := newTable(t, Options{MaxOpenPerSource: 1})
	if !tb.Acquire(tcpAddr(t, "[fe80::1%eth0]:1")) {
		t.Fatal("first refused")
	}
	if tb.Acquire(tcpAddr(t, "[fe80::1%eth1]:2")) {
		t.Fatal("a zone suffix made one address look like two")
	}
}

func TestWrongRoomCodesAreBudgetedPerAddressAndLeakBack(t *testing.T) {
	tb, clk := newTable(t, Options{AuthBurst: 3, AuthRefillPerSecond: 1})
	c := fakeConn{remote: tcpAddr(t, "192.0.2.9:5")}
	other := fakeConn{remote: tcpAddr(t, "192.0.2.10:5")}
	for i := 0; i < 3; i++ {
		if tb.Blocked(c) {
			t.Fatalf("blocked after %d failures, burst is 3", i)
		}
		tb.NoteAuthFailure(c)
	}
	if !tb.Blocked(c) {
		t.Fatal("not blocked after using the whole burst")
	}
	if tb.Blocked(other) {
		t.Fatal("another address was blocked for this one's failures")
	}
	clk.t = clk.t.Add(999 * time.Millisecond)
	if !tb.Blocked(c) {
		t.Fatal("unblocked before one token leaked back")
	}
	clk.t = clk.t.Add(2 * time.Millisecond)
	if tb.Blocked(c) {
		t.Fatal("still blocked after one token leaked back")
	}
	tb.NoteAuthFailure(c)
	if !tb.Blocked(c) {
		t.Fatal("one failure after one leaked token should block again: that is the 1/s rate")
	}
	clk.t = clk.t.Add(time.Hour)
	if tb.Blocked(c) {
		t.Fatal("an address stays blocked forever")
	}
	_, _, blocked := tb.Counts()
	if blocked < 2 {
		t.Fatalf("blockedAuths = %d, want at least 2", blocked)
	}
}

func TestAZeroBurstTracksNothing(t *testing.T) {
	tb, _ := newTable(t, Options{})
	c := fakeConn{remote: tcpAddr(t, "192.0.2.9:5")}
	for i := 0; i < 100; i++ {
		tb.NoteAuthFailure(c)
	}
	if tb.Blocked(c) {
		t.Fatal("blocked with no burst configured")
	}
	if tb.Len() != 0 {
		t.Fatalf("%d entries remembered with nothing to track", tb.Len())
	}
}

// TestTheTableIsBoundedAndEvictsTheOldestIdleEntry: full of idle addresses,
// the oldest goes; full of active ones, the newcomer is refused.
func TestTheTableIsBoundedAndEvictsTheOldestIdleEntry(t *testing.T) {
	tb, clk := newTable(t, Options{MaxOpenPerSource: 4, MaxEntries: 3, AuthBurst: 2, AuthRefillPerSecond: 1})
	addr := func(i int) net.Addr { return tcpAddr(t, fmt.Sprintf("10.1.0.%d:1", i)) }

	// Three idle entries, touched at different times.
	for i := 1; i <= 3; i++ {
		clk.t = clk.t.Add(time.Second)
		if !tb.Acquire(addr(i)) {
			t.Fatalf("acquire %d refused", i)
		}
		tb.Release(addr(i))
	}
	if tb.Len() != 3 {
		t.Fatalf("Len = %d, want 3", tb.Len())
	}
	// A fourth evicts the oldest idle one (addr 1), not a newer one.
	clk.t = clk.t.Add(time.Second)
	if !tb.Acquire(addr(4)) {
		t.Fatal("a newcomer was refused although idle entries could be evicted")
	}
	if tb.Len() != 3 {
		t.Fatalf("Len = %d after eviction, want 3", tb.Len())
	}
	// addr 1 was forgotten: it can open again from scratch; addr 4 is at 1.
	if !tb.Acquire(addr(2)) || !tb.Acquire(addr(3)) {
		t.Fatal("entries that should have survived were refused")
	}
	// Now all three (2, 3, 4) hold a connection: none is idle.
	if tb.Acquire(addr(5)) {
		t.Fatal("a newcomer was admitted by evicting an ACTIVE entry")
	}
	_, refusedFull, _ := tb.Counts()
	if refusedFull != 1 {
		t.Fatalf("refusedFull = %d, want 1", refusedFull)
	}
	// An entry with a non-empty bucket is active too, until it leaks.
	tb.Release(addr(2))
	tb.NoteAuthFailure(fakeConn{remote: addr(2)})
	if tb.Acquire(addr(6)) {
		t.Fatal("an entry with a live failure bucket was evicted")
	}
	clk.t = clk.t.Add(2 * time.Second)
	if !tb.Acquire(addr(6)) {
		t.Fatal("the bucket leaked empty but the entry was not treated as idle")
	}
}

func TestKeyShapes(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"1.2.3.4:80", "1.2.3.4"},
		{"[::1]:80", "::1"},
		{"[fe80::1%en0]:1", "fe80::1"},
		{"pipe", ""},
		{"", ""},
	} {
		got := Key(strAddr(tc.in))
		if got != tc.want {
			t.Errorf("Key(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
	if Key(nil) != "" {
		t.Error("Key(nil) is not empty")
	}
}

type strAddr string

func (s strAddr) Network() string { return "test" }
func (s strAddr) String() string  { return string(s) }
