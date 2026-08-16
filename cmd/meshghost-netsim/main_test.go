package main

import (
	"fmt"
	"math/rand"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"
)

// The proxy mirrors port NUMBERS across two hosts, so a test needs a port
// free on both. Picking it on the target host and reusing the number on the
// listen host is enough here: nothing else in the suite binds 127.0.0.2.
func freeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("pick udp port: %v", err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("pick tcp port: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func newFaults(seed int64) *faults {
	return &faults{
		start:      time.Now(),
		directions: map[direction]bool{up: true, down: true},
		rng:        rand.New(rand.NewSource(seed)),
	}
}

// TestUDPProxyForwardsBothWays is the baseline: with no faults armed the
// proxy must be invisible, including on the return path. The return path is
// the half that needs the per-client upstream socket, so a proxy that only
// forwarded one way would still look fine to a one-shot send test.
func TestUDPProxyForwardsBothWays(t *testing.T) {
	port := freeUDPPort(t)

	echo, err := net.ListenPacket("udp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		t.Skipf("cannot bind target udp port %d: %v", port, err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := echo.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = echo.WriteTo(append([]byte("re:"), buf[:n]...), from)
		}
	}()

	st := &stats{}
	if err := serveUDP("127.0.0.2", "127.0.0.1", port, newFaults(1), st); err != nil {
		t.Skipf("cannot bind listen udp 127.0.0.2:%d: %v", port, err)
	}

	client, err := net.Dial("udp", "127.0.0.2:"+strconv.Itoa(port))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer client.Close()

	if _, err := client.Write([]byte("ping")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := client.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, 2048)
	n, err := client.Read(buf)
	if err != nil {
		t.Fatalf("no reply came back through the proxy: %v", err)
	}
	if got := string(buf[:n]); got != "re:ping" {
		t.Errorf("got %q, want %q", got, "re:ping")
	}
}

// TestUDPProxyDropsEverythingAtTotalLoss confirms the fault model is
// actually wired to the forwarding path. A proxy that accepted -loss and
// ignored it would pass every other test here.
func TestUDPProxyDropsEverythingAtTotalLoss(t *testing.T) {
	port := freeUDPPort(t)

	target, err := net.ListenPacket("udp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		t.Skipf("cannot bind target udp port %d: %v", port, err)
	}
	defer target.Close()

	arrived := make(chan struct{}, 1)
	go func() {
		buf := make([]byte, 2048)
		for {
			if _, _, err := target.ReadFrom(buf); err != nil {
				return
			}
			select {
			case arrived <- struct{}{}:
			default:
			}
		}
	}()

	f := newFaults(2)
	f.loss = 1.0
	st := &stats{}
	if err := serveUDP("127.0.0.2", "127.0.0.1", port, f, st); err != nil {
		t.Skipf("cannot bind listen udp 127.0.0.2:%d: %v", port, err)
	}

	client, err := net.Dial("udp", "127.0.0.2:"+strconv.Itoa(port))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer client.Close()
	for i := 0; i < 20; i++ {
		if _, err := client.Write([]byte("ping")); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	select {
	case <-arrived:
		t.Fatal("a datagram reached the target with -loss=1.0")
	case <-time.After(400 * time.Millisecond):
	}
	if st.dropped.Load() == 0 {
		t.Error("nothing was counted as dropped despite total loss")
	}
	if st.forwarded.Load() != 0 {
		t.Errorf("forwarded %d datagrams at total loss", st.forwarded.Load())
	}
}

// TestTCPProxyPreservesOrderUnderJitter is the property that makes the tcp
// side honest. Delay is applied inline per direction specifically so a
// later chunk cannot overtake an earlier one -- reordering a tcp stream
// would be simulating something that cannot happen above the kernel.
func TestTCPProxyPreservesOrderUnderJitter(t *testing.T) {
	port := freeTCPPort(t)

	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		t.Skipf("cannot bind target tcp port %d: %v", port, err)
	}
	defer ln.Close()

	const lines = 40
	got := make(chan string, lines)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 1)
		cur := ""
		for {
			if _, err := c.Read(buf); err != nil {
				return
			}
			if buf[0] == '\n' {
				got <- cur
				cur = ""
				continue
			}
			cur += string(buf[0])
		}
	}()

	f := newFaults(3)
	f.latency = 2 * time.Millisecond
	f.jitter = 2 * time.Millisecond
	if err := serveTCP("127.0.0.2", "127.0.0.1", port, f, &stats{}); err != nil {
		t.Skipf("cannot bind listen tcp 127.0.0.2:%d: %v", port, err)
	}

	client, err := net.Dial("tcp", "127.0.0.2:"+strconv.Itoa(port))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer client.Close()
	for i := 0; i < lines; i++ {
		if _, err := fmt.Fprintf(client, "%d\n", i); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		time.Sleep(time.Millisecond)
	}

	for i := 0; i < lines; i++ {
		select {
		case line := <-got:
			if line != strconv.Itoa(i) {
				t.Fatalf("tcp stream arrived out of order: position %d held %q", i, line)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d of %d lines arrived", i, lines)
		}
	}
}

// TestPartitionWindowIsTimeBasedNotRandom pins the deliberate choice to
// drive blackouts off the clock: a window you can predict is one you can
// line up against a log, which a random draw would not be.
func TestPartitionWindowIsTimeBasedNotRandom(t *testing.T) {
	f := newFaults(4)
	f.partitionEvery = 200 * time.Millisecond
	f.partitionFor = 100 * time.Millisecond

	f.start = time.Now()
	if !f.partitioned() {
		t.Error("expected to start inside a partition window")
	}
	f.start = time.Now().Add(-120 * time.Millisecond)
	if f.partitioned() {
		t.Error("expected to be outside the window 120ms in")
	}
	f.start = time.Now().Add(-220 * time.Millisecond)
	if !f.partitioned() {
		t.Error("expected the window to repeat every 200ms")
	}

	off := newFaults(5)
	if off.partitioned() {
		t.Error("partitions must be off unless both -partition-every and -partition-for are set")
	}
}

func TestParsePorts(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want []int
	}{
		{"", nil},
		{"7777", []int{7777}},
		{"7777,7780", []int{7777, 7780}},
		{" 7777 , 7780 ", []int{7777, 7780}},
	} {
		got := parsePorts(tc.in)
		if len(got) != len(tc.want) {
			t.Errorf("parsePorts(%q) = %v, want %v", tc.in, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("parsePorts(%q) = %v, want %v", tc.in, got, tc.want)
				break
			}
		}
	}
}

// TestSeedReproducesTheSameFaultSequence is what makes a bad run worth
// reporting: same seed, same draws. The doc comment on faults is careful
// that this covers the sequence and not the interleaving of concurrent
// flows, and this test only claims the former.
func TestSeedReproducesTheSameFaultSequence(t *testing.T) {
	draw := func(seed int64) []bool {
		f := newFaults(seed)
		f.loss = 0.5
		out := make([]bool, 50)
		for i := range out {
			out[i] = f.chance(f.loss)
		}
		return out
	}
	a, b, c := draw(99), draw(99), draw(100)

	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("same seed diverged at draw %d", i)
		}
	}
	same := true
	for i := range a {
		if a[i] != c[i] {
			same = false
			break
		}
	}
	if same {
		t.Error("two different seeds produced an identical sequence")
	}
}
