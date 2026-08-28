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

// FUZZ THE SCHEDULE, NOT THE BYTES.
//
// Every other fuzz target in this repo feeds a parser: never panic, stable across the wire, matches
// json.Marshal. None of them varies ORDER or TIMING -- and on 2026-08-28 two bugs in one evening
// were purely about those. A nametag failed depending solely on WHICH SIDE CONNECTED FIRST, and the
// adapter bug underneath it bit only on the single tick where acceptance arrives. Nothing in the
// suite varied either, so nothing could have caught either. agent_docs/ideas.md has the plan; this
// is its first target.
//
// The seed picks the schedule: who connects first, whether the adapter attaches before or after its
// core reaches the relay, and the gaps between those steps. The assertion is an INVARIANT rather
// than a script -- a peer that set a name must end up delivered to the other side's adapter,
// however the session was assembled. A script would only re-test the one ordering somebody thought
// of, which is exactly how this got missed by hand.
//
// Timing is compressed, which is what makes this affordable in TIME: the delays are milliseconds
// and the waits are bounded by testTimeout.
//
// IT IS NOT AFFORDABLE IN SOCKETS, and that is the real finding from building it (2026-08-29).
// Every input stands up two cores and a bridge, so `-fuzz` at full tilt -- 550 execs/sec across 12
// workers -- exhausts Windows' ephemeral ports within seconds and reports the OS refusing a
// connection as a failing schedule. Four distinct harness limits were hit and fixed before this
// became clear: ephemeral-port exhaustion, leftover peers from earlier inputs, relay capacity, and
// finally TIME_WAIT accumulation that persists even at -parallel 2. NONE of the failures was a
// product bug.
//
// So this target earns its keep as a TABLE, not as a continuous fuzzer. Its seeds are the
// orderings that actually mattered live -- peer-first is the one that failed on 2026-08-28,
// watcher-first is the one that always worked -- and they run in every `go test` in about a
// second. Running `-fuzz` on it is a deliberate, short, low-parallelism act, and anything it
// reports needs checking against the OS before being believed.
//
// The lesson generalises past this file: an in-process scheduling fuzzer over REAL sockets is
// socket-bound long before it is idea-bound. A future version that wants to explore deeply should
// drive the core over an in-memory transport instead, which is a bigger change than it sounds
// because the ordering being tested is partly the ordering of real dials.
func FuzzNameDeliverySurvivesAnyConnectOrdering(f *testing.F) {
	// Seeds: the two orderings that actually differed live, plus a couple of gap shapes.
	f.Add(true, uint8(0), uint8(0))   // peer first, no gaps -- the case that failed
	f.Add(false, uint8(0), uint8(0))  // watcher first -- the case that worked
	f.Add(true, uint8(7), uint8(3))   // peer first, with the adapter lagging its core
	f.Add(false, uint8(2), uint8(11)) // watcher first, gaps the other way

	// OPT-IN, and it earned that the hard way.
	//
	// Run by default, even just its seeds, this destabilised the entire suite: netx timed out at
	// 600 SECONDS and an unrelated core test failed as collateral. Each input stands up two cores
	// and a bridge, and the sockets that costs starve other packages on the same machine -- the
	// same wall the -fuzz mode hits, reached from a different direction.
	//
	// A test that makes OTHER tests fail is worse than no test, so this one asks to be run:
	//
	//     MESHGHOST_SCHEDULE_FUZZ=1 go test ./core/ -run FuzzNameDelivery
	//     MESHGHOST_SCHEDULE_FUZZ=1 go test ./core/ -run XXX -fuzz FuzzNameDelivery -fuzztime 30s -parallel 2
	//
	// Skipping is not the same as deleting: the seeds still encode the two orderings that differed
	// live, and re-running them is one environment variable away when this area is touched.
	if os.Getenv("MESHGHOST_SCHEDULE_FUZZ") == "" {
		f.Skip("socket-hungry: it starves other packages on a shared machine. " +
			"Set MESHGHOST_SCHEDULE_FUZZ=1 to run it deliberately.")
	}

	f.Fuzz(func(t *testing.T, peerFirst bool, gapA, gapB uint8) {
		// Bounded so a fuzzer cannot turn a schedule into a hang: the point is ORDER, and
		// milliseconds are enough to reorder two goroutines' work.
		pause := func(g uint8) { time.Sleep(time.Duration(g%16) * time.Millisecond) }

		// ONE RELAY FOR THE WHOLE FUZZ RUN, not one per input.
		//
		// A relay per iteration exhausted the machine's sockets within seconds -- "bind: the
		// system lacked sufficient buffer space or because a queue was full" -- which the fuzzer
		// dutifully reported as a failing input. It was not one: the schedule under test was
		// irrelevant, the harness had simply run the OS out of ephemeral ports. That is worth
		// knowing about this whole approach: an in-process scheduling fuzzer is cheap in TIME and
		// expensive in SOCKETS, so what it reuses matters more than how fast each case runs.
		//
		// Cores still come up per input, because their connect ordering IS the thing being
		// varied. Only the relay is shared.
		addr := sharedFuzzRelay(t)

		// A ROOM PER INPUT, because the relay is shared.
		//
		// Without this the cores from every previous iteration are still sitting in the room, and
		// the watcher is told about THEM -- which surfaced immediately as "adapter was told
		// \"Watcher\"": a leftover peer from an earlier schedule, not the one this input set up.
		// Sharing a relay to save sockets means isolation has to come from somewhere, and the room
		// is the cheapest place to put it.
		room := fmt.Sprintf("fuzzroom-%d", atomic.AddUint64(&fuzzRoomSeq, 1))

		// AND EVERY CORE HANGS UP WHEN ITS INPUT IS DONE.
		//
		// startCore closes the bridge listener but leaves the relay connection open, which is fine
		// for one test and fatal across thousands: the shared relay filled and started answering
		// "server full", which the fuzzer reported as a failing input. It was the harness leaking
		// clients, not a schedule. Hanging up is also what a real client does, so this is closer to
		// the thing being modelled rather than a concession to it.
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

		// THE INVARIANT: however this was assembled, the adapter learns the name.
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

// sharedFuzzRelay returns one relay for the whole fuzz run. See the note at its call site for why
// a per-input relay is not viable.
//
// t.Helper only; deliberately NOT t.Cleanup'd per input -- it outlives every input by design, and
// the process exiting is what closes it.
func sharedFuzzRelay(t *testing.T) string {
	fuzzRelayOnce.Do(func() {
		s := relay.NewServer()
		s.SendHz = protocol.MaxSendHz
		// CAPACITY IS NOT WHAT THIS FUZZER TESTS, and the default cap made it fail as though it
		// were: cores hang up at the end of each input, but the relay does not free the slot until
		// it notices the disconnect, and the fuzzer starts the next input long before that. The
		// result was "server full" reported as a failing schedule -- the harness outrunning its own
		// cleanup, twice over now (the first was ephemeral-port exhaustion).
		//
		// A generous cap removes the harness from the answer. A relay's real capacity behaviour has
		// its own tests in package relay, where it is the subject rather than the scenery.
		s.MaxClients = 100000
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
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
