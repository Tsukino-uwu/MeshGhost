package core

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// waitPolicy returns the next session_policy the core pushed, or fails.
func waitPolicy(t *testing.T, fa *fakeAdapter) string {
	t.Helper()
	select {
	case got := <-fa.policies:
		return got.GhostCollision
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for a session_policy on the bridge")
		return ""
	}
}

// startCoreLazyWith is startCoreLazy plus a hook to configure the Core before it serves.
func startCoreLazyWith(t *testing.T, relayAddr, room, name string, cfg func(*Core)) (*Core, string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return startCoreLazyServing(t, ln, relayAddr, room, name, cfg), ln.Addr().String()
}

// startCoreLazyServing is startCoreLazyWith over a listener the caller owns, such as a fuzz target's pipeListener.
func startCoreLazyServing(t *testing.T, ln net.Listener, relayAddr, room, name string, cfg func(*Core)) *Core {
	t.Helper()
	c := New()
	c.RelayAddr = relayAddr
	c.Room = room
	c.DisplayName = name
	c.DialTimeout = testTimeout
	if cfg != nil {
		cfg(c)
	}
	go c.ServeBridge(ln)
	return c
}

// TestGhostCollisionPolicyReachesTheAdapter runs every hop end to end (relay field, Welcome, core resolve, bridge
// message), since the failure that matters is a hop silently dropping the value.
func TestGhostCollisionPolicyReachesTheAdapter(t *testing.T) {
	for _, tc := range []struct {
		name        string
		relayPolicy string
		clientPref  string
		want        string
	}{
		{"host disables it", protocol.GhostCollisionDisabled, "", protocol.GhostCollisionDisabled},
		{"host leaves it alone", protocol.GhostCollisionEnabled, "", protocol.GhostCollisionEnabled},
		{"host says nothing at all", "", "", protocol.GhostCollisionEnabled},
		{"player opts out under a permissive host", protocol.GhostCollisionEnabled, protocol.GhostCollisionDisabled, protocol.GhostCollisionDisabled},
		{"player cannot opt back in under a strict host", protocol.GhostCollisionDisabled, protocol.GhostCollisionEnabled, protocol.GhostCollisionDisabled},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := relay.NewServer()
			s.SendHz = protocol.MaxSendHz
			s.GhostCollision = tc.relayPolicy
			relayAddr := startRelayWith(t, s)

			pref := tc.clientPref
			_, bridgeAddr := startCoreLazyWith(t, relayAddr, "room", "p1", func(c *Core) {
				c.GhostCollision = pref
			})

			fa := dialFakeAdapter(t, bridgeAddr)
			fa.hello("emerald")
			fa.awaitReady()

			if got := waitPolicy(t, fa); got != tc.want {
				t.Errorf("adapter was told ghost_collision=%q, want %q "+
					"(relay advertised %q, client preferred %q)",
					got, tc.want, tc.relayPolicy, pref)
			}
		})
	}
}

// TestGhostCollisionPolicyIsNeverEmptyOnTheBridge: an adapter never has to invent a default of its own.
func TestGhostCollisionPolicyIsNeverEmptyOnTheBridge(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	relayAddr := startRelayWith(t, s)

	_, bridgeAddr := startCoreLazy(t, relayAddr, "room", "p1")
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()

	if got := waitPolicy(t, fa); got == "" {
		t.Fatal("adapter was handed an empty ghost_collision; it should always get a resolved value")
	}
}

// TestGhostCollisionGarbageFromRelayFailsSafe: an unrecognized relay value cannot talk a client into a physical
// effect; the relay is normalized, not trusted.
func TestGhostCollisionGarbageFromRelayFailsSafe(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.GhostCollision = "yes-please-make-them-solid"
	relayAddr := startRelayWith(t, s)

	_, bridgeAddr := startCoreLazy(t, relayAddr, "room", "p1")
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()

	if got := waitPolicy(t, fa); got != protocol.GhostCollisionDisabled {
		t.Errorf("garbage relay policy resolved to %q, want %q", got, protocol.GhostCollisionDisabled)
	}
}

// TestGhostCollisionRepeatedForANewAdapter: a relaunched game's adapter is told again, or it would fall back to its
// compiled-in default.
func TestGhostCollisionRepeatedForANewAdapter(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.GhostCollision = protocol.GhostCollisionDisabled
	relayAddr := startRelayWith(t, s)

	_, bridgeAddr := startCoreLazy(t, relayAddr, "room", "p1")

	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	if got := waitPolicy(t, fa); got != protocol.GhostCollisionDisabled {
		t.Fatalf("first adapter got %q", got)
	}
	fa.conn.Close()

	// Retry: the Core frees the slot from the departing connection's own read loop, not at the close.
	fa2 := reattachFakeAdapter(t, bridgeAddr, "emerald")
	if got := waitPolicy(t, fa2); got != protocol.GhostCollisionDisabled {
		t.Errorf("re-attached adapter got %q, want %q -- a relaunched game must be told the policy again",
			got, protocol.GhostCollisionDisabled)
	}
}

// TestGhostCollisionPolicyArrivesAfterBridgeReady: an adapter may drop anything sent before bridge_ready, and Welcome
// (relay read loop) races bridge_ready (adapter read loop), so the policy must follow it.
func TestGhostCollisionPolicyArrivesAfterBridgeReady(t *testing.T) {
	// Repeated because it is a scheduling race.
	for i := 0; i < 50; i++ {
		s := relay.NewServer()
		s.SendHz = protocol.MaxSendHz
		s.GhostCollision = protocol.GhostCollisionDisabled
		relayAddr := startRelayWith(t, s)

		_, bridgeAddr := startCoreLazy(t, relayAddr, "room", "p1")
		fa := dialFakeAdapter(t, bridgeAddr)
		fa.hello("emerald")
		fa.awaitReady()
		if got := waitPolicy(t, fa); got != protocol.GhostCollisionDisabled {
			t.Fatalf("iteration %d: policy %q", i, got)
		}

		var seenReady bool
	drain:
		for {
			select {
			case typ := <-fa.order:
				switch typ {
				case bridge.TypeBridgeReady:
					seenReady = true
				case bridge.TypeSessionPolicy:
					if !seenReady {
						t.Fatalf("iteration %d: session_policy arrived BEFORE bridge_ready; "+
							"an adapter is entitled to discard it", i)
					}
				}
			default:
				break drain
			}
		}
		fa.conn.Close()
	}
}

// sessionPolicies returns every session_policy the core pushed to this transport, in order. It waits for the queue
// first: sendToAdapter enqueues, so a returned call does not mean the adapter has it.
func sessionPolicies(t *testing.T, c *Core, rt *recordingTransport) []string {
	t.Helper()
	waitAdapterDrained(t, c, rt)
	var out []string
	for _, raw := range rt.all() {
		var env bridge.Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatalf("unmarshal bridge envelope: %v", err)
		}
		if env.Type != bridge.TypeSessionPolicy {
			continue
		}
		var p bridge.SessionPolicy
		if err := json.Unmarshal(env.Payload, &p); err != nil {
			t.Fatalf("unmarshal session_policy: %v", err)
		}
		out = append(out, p.GhostCollision)
	}
	return out
}

// TestGhostCollisionNotPushedBeforeTheRoomHasSpoken: "no Welcome yet" and "a room that said nothing" are both "", and
// ResolveGhostCollision("", "") is enabled, so a push before the room speaks could make ghosts solid in a room that
// disabled them. Reachable when a relaunching game re-attaches during the previous relay teardown; driven here at
// the interleaving.
func TestGhostCollisionNotPushedBeforeTheRoomHasSpoken(t *testing.T) {
	c := New()
	rt := &recordingTransport{}
	c.attachedAdapter = rt
	c.adapterReady = true

	// The state the teardown leaves behind.
	c.relayGhostCollision = ""
	c.relayPolicyKnown = false
	c.pushSessionPolicy()
	if got := sessionPolicies(t, c, rt); len(got) != 0 {
		t.Fatalf("pushed %v before any Welcome -- an unknown room policy must not be "+
			"resolved into a physical effect", got)
	}

	c.relayGhostCollision = protocol.GhostCollisionDisabled
	c.relayPolicyKnown = true
	c.pushSessionPolicy()
	if got := sessionPolicies(t, c, rt); len(got) != 1 || got[0] != protocol.GhostCollisionDisabled {
		t.Fatalf("after Welcome the adapter got %v, want one %q", got, protocol.GhostCollisionDisabled)
	}
}

// waitAdapterDrained blocks until everything enqueued for nd has been written, so a test can assert on what the
// adapter received.
func waitAdapterDrained(t *testing.T, c *Core, nd transport.Transport) {
	t.Helper()
	// idle(), not queueLen(): run() clears w.q when it takes a batch and writes it several syscalls later, and an empty
	// read is what a negative assertion wants to see. A connection with no writer yet is drained.
	deadline := time.Now().Add(testTimeout)
	for {
		if c.writerFor(nd).idle() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the adapter's outbound queue never drained in %v", testTimeout)
		}
		time.Sleep(time.Millisecond)
	}
}
