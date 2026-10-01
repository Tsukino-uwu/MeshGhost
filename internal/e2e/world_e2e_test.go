package e2e

// The world-custody plane through the shipped binaries: the only test that kills the process holding the authority
// and watches its successor pick the world up, which the relay's in-process tests cannot do.

import (
	"encoding/json"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// worldAdapter drives the world plane over the bridge: it declares the capabilities in its own Hello, writes entities,
// and records everything the core pushes back.
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

// awaitLease waits until this adapter has seen a lease state with the given reason for the world authority.
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

// mark returns a cursor into what this adapter has received, so a later awaitWorld only considers what arrives after
// it: a client is seeded on join and again on adopting the authority, with the same reason.
func (a *worldAdapter) mark() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.states)
}

// awaitWorld waits for world messages after since with the given reason and returns the entities they carried, merged
// across however many messages the relay batched them into.
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

// TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner: a host writes a world, its process is killed, a second
// client takes the authority and is handed the same world, and a third client joining later is seeded with it.
func TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner(t *testing.T) {
	r := newRig(t)
	// Not -loopback: this needs several real clients in one room.
	start(t, r.dir, r.relayBin, "-addr", r.relayAddr)
	waitForListener(t, r.relayAddr)

	launch := func() (string, *worldAdapter, func()) {
		bridgeAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
		cmd := start(t, r.dir, r.clientBin,
			"-relay", r.relayAddr,
			"-bridge", bridgeAddr,
			// No -game: connecting eagerly at startup would reach the relay before the adapter declares its
			// capabilities.
			"-room", "e2eworld",
			// tcp, so the relay notices the kill: a hard-killed quic peer lingers until quic's idle timeout, against an
			// immediate RST on tcp.
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

	// A peer joins and is seeded with the world, which proves it was populated before the host dies.
	_, peer, _ := launch()
	peer.awaitWorld(t, 0, protocol.WorldSnapshot, 2)
	adoptFrom := peer.mark()

	// The host's process dies outright, with no clean release.
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

	// A client that was never present joins and is seeded with the current world.
	_, latecomer, _ := launch()
	seeded := latecomer.awaitWorld(t, 0, protocol.WorldSnapshot, 2)
	if seeded["boss"] != `{"hp":40}` || seeded["door"] != `{"hp":1}` {
		t.Fatalf("the late joiner was seeded with %+v, want the current world", seeded)
	}
}
