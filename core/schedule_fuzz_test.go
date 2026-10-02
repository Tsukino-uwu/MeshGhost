package core

import (
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// FuzzNameDeliverySurvivesAnyConnectOrdering fuzzes the schedule, not the bytes: who connects first, whether the
// adapter attaches before or after its core reaches the relay, and the gaps between. A peer's name must reach the
// other side's adapter however the session was assembled.
//
// Every input stands up two cores and a bridge, so anything -fuzz reports needs checking against the OS first.
// fuzz-census: no-ci-step -- stands up real relay sockets per input, so a continuous
// campaign is ephemeral-port-bound long before it is idea-bound. Run by hand.
func FuzzNameDeliverySurvivesAnyConnectOrdering(f *testing.F) {
	// Seeds: the two orderings that actually differed live, plus a couple of gap shapes.
	f.Add(true, uint8(0), uint8(0))   // peer first, no gaps -- the case that failed
	f.Add(false, uint8(0), uint8(0))  // watcher first -- the case that worked
	f.Add(true, uint8(7), uint8(3))   // peer first, with the adapter lagging its core
	f.Add(false, uint8(2), uint8(11)) // watcher first, gaps the other way

	// Opt-in: its sockets starve other packages on a shared machine, even with only the seeds. Run it with:
	//
	//     MESHGHOST_SCHEDULE_FUZZ=1 go test ./core/ -run FuzzNameDelivery
	//     MESHGHOST_SCHEDULE_FUZZ=1 go test ./core/ -run XXX -fuzz FuzzNameDelivery -fuzztime 30s -parallel 2
	if os.Getenv("MESHGHOST_SCHEDULE_FUZZ") == "" {
		f.Skip("socket-hungry: it starves other packages on a shared machine. " +
			"Set MESHGHOST_SCHEDULE_FUZZ=1 to run it deliberately.")
	}

	f.Fuzz(func(t *testing.T, peerFirst bool, gapA, gapB uint8) {
		// Bounded so a schedule cannot become a hang; milliseconds are enough to reorder two goroutines' work.
		pause := func(g uint8) { time.Sleep(time.Duration(g%16) * time.Millisecond) }

		// One relay for the whole run, since a relay per input exhausts ephemeral ports in seconds. Cores still
		// come up per input: their connect ordering is what varies.
		addr := sharedFuzzRelay(t)

		// A room per input, or the watcher is told about leftover cores from earlier inputs.
		room := fmt.Sprintf("fuzzroom-%d", atomic.AddUint64(&fuzzRoomSeq, 1))

		// startCore leaves the relay connection open, which across thousands of inputs fills the shared relay.
		hangUpAfter := func(c *Core) *Core {
			t.Cleanup(func() {
				c.mu.Lock()
				conn := c.relay
				c.mu.Unlock()
				if conn != nil {
					conn.Close()
				}
			})
			return c
		}

		named := func() *Core {
			c, _ := startCore(t, addr, "fuzzgame", room, "Named")
			return hangUpAfter(c)
		}
		watcher := func() (*Core, string) {
			c, bridge := startCoreLazy(t, addr, room, "Watcher")
			return hangUpAfter(c), bridge
		}

		var watcherCore *Core
		var bridgeAddr string
		if peerFirst {
			// The peer is already in the room: its name can only reach the watcher through the
			// Welcome roster, and then across a bridge that did not exist at handshake time.
			named()
			pause(gapA)
			watcherCore, bridgeAddr = watcher()
		} else {
			watcherCore, bridgeAddr = watcher()
			pause(gapA)
			named()
		}
		_ = watcherCore

		pause(gapB)
		fa := reattachFakeAdapter(t, bridgeAddr, "fuzzgame")

		deadline := time.Now().Add(testTimeout)
		for time.Now().Before(deadline) {
			fa.mu.Lock()
			n := len(fa.names)
			var got string
			for _, rn := range fa.names {
				got = rn.DisplayName
			}
			fa.mu.Unlock()
			if n > 0 {
				if got != "Named" {
					t.Fatalf("adapter was told %q, want %q (peerFirst=%v gaps=%d,%d)",
						got, "Named", peerFirst, gapA, gapB)
				}
				return
			}
			time.Sleep(2 * time.Millisecond)
		}
		t.Fatalf("the adapter was never told the peer's name (peerFirst=%v gaps=%d,%d). Either the "+
			"roster never carried it, this core never stored it, or it stored it and never handed "+
			"it over at attach -- the three stages that looked identical from outside on 2026-08-28",
			peerFirst, gapA, gapB)
	})
}

// sharedFuzzRelay returns one relay for the whole fuzz run. It outlives every input, so it is never t.Cleanup'd; the
// process exiting closes it.
func sharedFuzzRelay(t *testing.T) string {
	fuzzRelayOnce.Do(func() {
		s := relay.NewServer()
		s.SendHz = protocol.MaxSendHz
		// Capacity is not under test: a hung-up core's slot frees only once the relay notices, after the next input
		// has started. Package relay tests capacity.
		s.MaxClients = 100000
		raw, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
		ln := serveTLS(t, raw)
		go s.Serve(ln)
		fuzzRelayAddr = ln.Addr().String()
	})
	return fuzzRelayAddr
}

var (
	fuzzRelayOnce sync.Once
	fuzzRelayAddr string
	// fuzzRoomSeq isolates inputs from each other on the shared relay.
	fuzzRoomSeq uint64
)
