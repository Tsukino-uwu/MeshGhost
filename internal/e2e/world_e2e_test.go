package e2e

// The world-custody plane driven through the actual shipped binaries: a real
// relay process, three real client processes, and three bridge adapters that
// speak nothing but the bridge protocol — no game, no human.
//
// **This is the only test that proves custody survives a host process dying**,
// as opposed to a lease being released by a function call. Everything the
// relay's own tests can reach is in-process: they can free a lease, but they
// cannot kill the thing holding it and watch its successor pick the world up
// off the floor. That is the entire scenario the feature exists for, so it is
// worth the cost of building binaries for.

import (
	"encoding/json"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	"meshghost/internal/bridge"
	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// worldAdapter is a bridge adapter that drives the world plane: it declares the
// capabilities in its own Hello (an adapter's one legitimate say in what the
// core negotiates), writes entities, and records everything the core pushes
// back down.
type worldAdapter struct {
	conn *transport.NDJSONConn

	mu     sync.Mutex
	states []protocol.WorldState
	leases []protocol.LeaseState
}

func dialWorldAdapter(t *testing.T, bridgeAddr string) *worldAdapter {
	t.Helper()
	conn, err := transport.Dial(bridgeAddr)
	if err != nil {
		t.Fatalf("dial bridge %s: %v", bridgeAddr, err)
	}
	t.Cleanup(func() { conn.Close() })

	a := &worldAdapter{conn: conn}
	conn.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if json.Unmarshal(payload, &env) != nil {
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		switch env.Type {
		case bridge.TypeWorldState:
			var st bridge.WorldState
			if json.Unmarshal(env.Payload, &st) == nil {
				a.states = append(a.states, st.WorldState)
			}
		case bridge.TypeLeaseState:
			var st bridge.LeaseState
			if json.Unmarshal(env.Payload, &st) == nil {
				a.leases = append(a.leases, st.LeaseState)
			}
		}
	})

	if !sendBridge(conn, bridge.TypeHello, bridge.Hello{
		GameID:   "e2egame",
		Features: []string{protocol.FeatureLeaseV1, protocol.FeatureWorldV1},
	}) {
		t.Fatal("bridge hello failed")
	}
	return a
}

func (a *worldAdapter) claim(t *testing.T) {
	t.Helper()
	if !sendBridge(a.conn, bridge.TypeLease, bridge.Lease{
		Lease: protocol.Lease{Op: protocol.LeaseClaim, Key: "sim", TTLMs: 60_000},
	}) {
		t.Fatal("claim failed to send")
	}
}

func (a *worldAdapter) set(t *testing.T, key string, value int) {
	t.Helper()
	blob, err := json.Marshal(map[string]int{"hp": value})
	if err != nil {
		t.Fatalf("marshal blob: %v", err)
	}
	if !sendBridge(a.conn, bridge.TypeWorld, bridge.World{
		World: protocol.World{
			Op: protocol.WorldSet, Authority: "sim", Key: key, Blob: blob, Reliable: true,
		},
	}) {
		t.Fatal("world write failed to send")
	}
}

// awaitLease waits until this adapter has seen a lease state with the given
// reason for the world authority.
func (a *worldAdapter) awaitLease(t *testing.T, reason string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		a.mu.Lock()
		for _, st := range a.leases {
			if st.Reason == reason {
				a.mu.Unlock()
				return
			}
		}
		a.mu.Unlock()
		time.Sleep(50 * time.Millisecond)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	t.Fatalf("never saw a %q for the world authority; lease states seen: %+v", reason, a.leases)
}

// mark returns a cursor into what this adapter has already received, so a later
// awaitWorld only considers what arrives AFTER it. Necessary because the same
// reason legitimately appears more than once in one run — a client is seeded on
// join and again on adopting the authority — and a check that looked at the
// whole history would happily pass on the older one.
func (a *worldAdapter) mark() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.states)
}

// awaitWorld waits for world messages after since with the given reason, and
// returns the entities they carried, merged across however many messages the
// relay batched the answer into.
func (a *worldAdapter) awaitWorld(t *testing.T, since int, reason string, wantKeys int) map[string]string {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		got := map[string]string{}
		a.mu.Lock()
		for _, st := range a.states[min(since, len(a.states)):] {
			if st.Reason != reason {
				continue
			}
			for _, e := range st.Entries {
				if e.Dropped {
					delete(got, e.Key)
					continue
				}
				got[e.Key] = string(e.Blob)
			}
		}
		a.mu.Unlock()
		if len(got) >= wantKeys {
			return got
		}
		time.Sleep(50 * time.Millisecond)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	t.Fatalf("timed out waiting for %d entities with reason %q; saw %+v", wantKeys, reason, a.states)
	return nil
}

// TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner is the whole feature
// in one run: a host writes a world, the host's PROCESS is killed, a second
// client takes the authority and is handed the same world, and a third client
// that was never there for any of it joins and sees exactly the same thing.
func TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner(t *testing.T) {
	r := newRig(t)
	// Not -loopback: this needs several real clients in one room, which is the
	// opposite of what loopback mode is for.
	start(t, r.dir, r.relayBin, "-addr", r.relayAddr)
	waitForListener(t, r.relayAddr)

	launch := func() (string, *worldAdapter, func()) {
		bridgeAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
		cmd := start(t, r.dir, r.clientBin,
			"-relay", r.relayAddr,
			"-bridge", bridgeAddr,
			// Deliberately NO -game: that makes the core connect eagerly at
			// startup, before any adapter has spoken, so the adapter's own
			// declared capabilities never reach the relay Hello. The lazy path
			// -- dial on the first bridge Hello -- is both the default and the
			// only one that carries them.
			"-room", "e2eworld",
			// tcp explicitly, because this test kills a process and needs the
			// relay to notice. A hard-killed quic peer sends no close frame and
			// its connection lingers until quic's own idle timeout (~17s,
			// measured 2026-08-17), against an immediate RST on tcp -- so on the
			// default "auto" this would spend the whole test waiting on a
			// property that has nothing to do with custody.
			"-transport", "tcp",
			"-interp", "0ms",
			"-min-send", "10ms",
		)
		waitForListener(t, bridgeAddr)
		return bridgeAddr, dialWorldAdapter(t, bridgeAddr), func() {
			if cmd.Process != nil {
				_ = cmd.Process.Kill()
			}
		}
	}

	// The host: claims the authority and populates a small world.
	_, host, killHost := launch()
	host.claim(t)
	host.awaitLease(t, protocol.LeaseGranted)
	host.set(t, "boss", 100)
	host.set(t, "door", 1)

	// A peer joins and is seeded with the world that already exists. Waiting for
	// that here is what proves the world was really populated before the host
	// died rather than after — without it the kill below could beat the writes
	// and the test would pass for the wrong reason.
	_, peer, _ := launch()
	peer.awaitWorld(t, 0, protocol.WorldSnapshot, 2)
	adoptFrom := peer.mark()

	// The host's process dies outright — no goodbye, no clean release. This is
	// the case that would take the world with it if lifetime were tied to the
	// lease.
	killHost()
	peer.awaitLease(t, protocol.LeaseHolderLeft)

	// The peer takes over. The relay hands it the world with the grant.
	peer.claim(t)
	peer.awaitLease(t, protocol.LeaseGranted)
	adopted := peer.awaitWorld(t, adoptFrom, protocol.WorldSnapshot, 2)
	if adopted["boss"] != `{"hp":100}` || adopted["door"] != `{"hp":1}` {
		t.Fatalf("the successor adopted %+v, want the dead host's world byte-for-byte", adopted)
	}

	// The successor writes on, from what it adopted.
	peer.set(t, "boss", 40)

	// And a client that was never present for any of it joins and is seeded
	// with the same world — the same mechanism, for free.
	_, latecomer, _ := launch()
	seeded := latecomer.awaitWorld(t, 0, protocol.WorldSnapshot, 2)
	if seeded["boss"] != `{"hp":40}` || seeded["door"] != `{"hp":1}` {
		t.Fatalf("the late joiner was seeded with %+v, want the current world", seeded)
	}
}
