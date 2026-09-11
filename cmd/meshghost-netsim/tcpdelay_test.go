package main

import (
	"bufio"
	"fmt"
	"math/rand"
	"net"
	"sync"
	"testing"
	"time"
)

// A DELAYED STREAM IS NOT A CLUMPED ONE, and the old proxy could only produce
// the second (review H16).
//
// pumpTCP used to sleep between the read and the write in the one goroutine
// doing both, so the configured latency became the path's SERVICE INTERVAL
// rather than its delay: at the no-arg profile's 100 ms it could complete about
// ten read-write cycles a second, and a 15 Hz sender's lines piled up in the
// kernel buffer between them and crossed in bursts. The receiver saw one clump
// every 100 ms instead of a smooth stream delayed by 100 ms.
//
// Those are different networks, and the difference matters more here than
// almost anywhere: this rig is what every rate and interpolation verdict is
// judged on (`run-netsim.bat`'s header, the user's rule). A verdict taken over
// tcp on the old proxy was partly measuring the proxy.
//
// WHAT IS ASSERTED is the shape, not the timing: lines sent evenly must ARRIVE
// evenly. The test counts how many arrive in one big burst; clumping puts most
// of a batch into a couple of moments, and a delayed stream spreads them out the
// way they were sent.
func TestTCPDelayDoesNotClumpTheStream(t *testing.T) {
	const (
		lines   = 40
		spacing = 10 * time.Millisecond
		latency = 100 * time.Millisecond
	)

	// The far end: accepts one connection and reads lines, stamping each.
	dstLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen dst: %v", err)
	}
	defer dstLn.Close()

	arrivals := make(chan time.Time, lines*2)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		c, aerr := dstLn.Accept()
		if aerr != nil {
			return
		}
		defer c.Close()
		sc := bufio.NewScanner(c)
		for sc.Scan() {
			arrivals <- time.Now()
		}
	}()

	// The source side is a REAL SOCKET, not net.Pipe, and that is load-bearing:
	// a pipe is unbuffered, so a proxy that sleeps between reads throttles the
	// SENDER too, and the lines arrive spread out for the wrong reason. The
	// clumping this test exists to catch comes from the kernel buffer the sender
	// can run ahead into while the proxy is asleep. With a pipe, the old
	// behaviour passes this test -- checked, 2026-09-11, before the socket
	// replaced it.
	srcLn, serr := net.Listen("tcp", "127.0.0.1:0")
	if serr != nil {
		t.Fatalf("listen src: %v", serr)
	}
	defer srcLn.Close()

	type accepted struct {
		c   net.Conn
		err error
	}
	accept := make(chan accepted, 1)
	go func() {
		c, aerr := srcLn.Accept()
		accept <- accepted{c, aerr}
	}()

	srcConn, cerr := net.Dial("tcp", srcLn.Addr().String())
	if cerr != nil {
		t.Fatalf("dial src: %v", cerr)
	}
	defer srcConn.Close()
	got := <-accept
	if got.err != nil {
		t.Fatalf("accept src: %v", got.err)
	}
	dstConn := got.c
	defer dstConn.Close()

	real, derr := net.Dial("tcp", dstLn.Addr().String())
	if derr != nil {
		t.Fatalf("dial dst: %v", derr)
	}
	defer real.Close()

	f := &faults{
		latency:    latency,
		directions: map[direction]bool{up: true, down: true},
		mu:         sync.Mutex{},
		rng:        rand.New(rand.NewSource(1)),
	}
	st := &stats{}
	go pumpTCP(f, st, up, dstConn, real)

	// Send evenly.
	start := time.Now()
	go func() {
		for i := 0; i < lines; i++ {
			fmt.Fprintf(srcConn, "line %d\n", i)
			time.Sleep(spacing)
		}
	}()

	seen := make([]time.Time, 0, lines)
	deadline := time.After(15 * time.Second)
	for len(seen) < lines {
		select {
		case at := <-arrivals:
			seen = append(seen, at)
		case <-deadline:
			t.Fatalf("only %d of %d lines arrived", len(seen), lines)
		}
	}
	// Close the PROXY'S OWN connection too, not just the pipe feeding it: the
	// reader at the far end is blocked on `real`, and closing the source only
	// ends pumpTCP's read loop. Without this the test passes every assertion and
	// then hangs in wg.Wait() forever, which is a hang wearing a green tick.
	_ = srcConn.Close()
	_ = real.Close()
	_ = dstLn.Close()
	wg.Wait()

	// THE DELAY IS REAL: the first line cannot arrive before it.
	if first := seen[0].Sub(start); first < latency/2 {
		t.Fatalf("the first line arrived after %v, which is less than half the configured %v -- "+
			"the delay is not being applied at all", first, latency)
	}

	// AND THE STREAM IS NOT CLUMPED. With inline sleeping, a batch of lines sent
	// 10 ms apart crosses in a few bursts and most gaps are ~0; delayed properly,
	// the arrival gaps look like the send gaps.
	tight := 0
	for i := 1; i < len(seen); i++ {
		if seen[i].Sub(seen[i-1]) < spacing/4 {
			tight++
		}
	}
	if tight > len(seen)/3 {
		t.Fatalf("%d of %d arrival gaps were under a quarter of the send spacing -- the proxy is "+
			"CLUMPING the stream rather than delaying it, which is a different network from the "+
			"one the flags describe, and it is the one every tcp verdict would be measured on",
			tight, len(seen)-1)
	}
}
