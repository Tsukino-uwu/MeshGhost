package core

import (
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// waitPolicy returns the next session_policy the core pushed, or fails.
func waitPolicy(t *testing.T, fa *fakeAdapter) string {
	t.Helper()
	select {
	case got := <-fa.policies:
		return got
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for a session_policy on the bridge")
		return ""
	}
}

// startCoreLazyWith is startCoreLazy plus a hook to configure the Core before
// it serves, so a test can set a client-side preference.
func startCoreLazyWith(t *testing.T, relayAddr, room, name string, cfg func(*Core)) (*Core, string) {
	t.Helper()
	c := New()
	c.RelayAddr = relayAddr
	c.Room = room
	c.DisplayName = name
	c.DialTimeout = testTimeout
	if cfg != nil {
		cfg(c)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)
	return c, ln.Addr().String()
}

// The end-to-end path the whole feature is: a host sets one config value and
// an adapter, in a different process, is told. Every hop in between (relay
// Server field -> Welcome -> core resolve -> bridge message) is exercised here
// rather than unit-tested in isolation, because the interesting failure is a
// hop that silently drops the value, which no single-package test would catch.
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

// An adapter is never handed "" and never has to invent a default of its own:
// whatever nobody configured, it hears a real policy.
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

// A relay sending something unrecognized must not be able to talk a client
// into a physical effect. Same trust-boundary posture as clamping SendHz on
// receive: the relay is not trusted, it is normalized.
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

// A re-attaching adapter must be told again. Without the reset in the attach
// path, a re-launched game would come up with no session_policy at all and
// silently fall back to its own compiled-in default -- which is exactly the
// case a player hits every time they restart the game.
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

	// Retry rather than assuming the slot is free the instant the socket
	// closes — the Core frees it from the departing connection's own read loop.
	// See reattachFakeAdapter: asserting the instant version is what made this
	// test go red in a release build while the same commit passed CI.
	fa2 := reattachFakeAdapter(t, bridgeAddr, "emerald")
	if got := waitPolicy(t, fa2); got != protocol.GhostCollisionDisabled {
		t.Errorf("re-attached adapter got %q, want %q -- a relaunched game must be told the policy again",
			got, protocol.GhostCollisionDisabled)
	}
}

// bridge_ready must arrive before session_policy. An adapter treats
// bridge_ready as "this core is mine and usable"; anything sent before it is
// entitled to be dropped on the floor, so a policy that raced ahead of it
// would be silently lost and the adapter would run on its own default.
//
// This is a genuine cross-goroutine race inside the Core, not a formality:
// Welcome arrives on the relay read loop while bridge_ready is sent on the
// adapter read loop. Written after discovering that removing the post-ready
// push did not fail any test -- because the Welcome path was quietly
// delivering the policy first.
func TestGhostCollisionPolicyArrivesAfterBridgeReady(t *testing.T) {
	// Repeated because it is a scheduling race: a single pass proves very
	// little, and -count on top of this widens it further.
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

		// Drain the recorded order and check the first session_policy never
		// precedes the first bridge_ready.
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
