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

// TestTCPDelayDoesNotClumpTheStream: lines sent evenly through a delayed tcp path must arrive evenly. It asserts the
// shape, not the timing: clumping puts most of a batch into a few moments.
func TestTCPDelayDoesNotClumpTheStream(t *testing.T) {
	const (
		lines   = 40
		spacing = 10 * time.Millisecond
		latency = 100 * time.Millisecond
	)

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

	// A real socket, not net.Pipe: a pipe is unbuffered, so a sleeping proxy would throttle the sender and hide the
	// clumping, which comes from the kernel buffer the sender runs ahead into.
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
	// Close real too: the far end's reader is blocked on it, and closing the source only ends pumpTCP's read loop,
	// so wg.Wait() would hang.
	_ = srcConn.Close()
	_ = real.Close()
	_ = dstLn.Close()
	wg.Wait()

	if first := seen[0].Sub(start); first < latency/2 {
		t.Fatalf("the first line arrived after %v, which is less than half the configured %v -- "+
			"the delay is not being applied at all", first, latency)
	}

	// The limit, 23 of 39, sits between the two distributions measured under load: an inline-sleep proxy scored
	// 32-35 tight gaps, this one 0-14.
	tight := 0
	for i := 1; i < len(seen); i++ {
		if seen[i].Sub(seen[i-1]) < spacing/4 {
			tight++
		}
	}
	t.Logf("%d of %d arrival gaps under a quarter of the send spacing", tight, len(seen)-1)
	if tight > (len(seen)-1)*3/5 {
		t.Fatalf("%d of %d arrival gaps were under a quarter of the send spacing -- the proxy is "+
			"CLUMPING the stream rather than delaying it, which is a different network from the "+
			"one the flags describe, and it is the one every tcp verdict would be measured on",
			tight, len(seen)-1)
	}
}
