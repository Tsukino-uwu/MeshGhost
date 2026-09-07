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

// startCoreLazyWith is startCoreLazy plus a hook to configure the Core before
// it serves, so a test can set a client-side preference.
func startCoreLazyWith(t *testing.T, relayAddr, room, name string, cfg func(*Core)) (*Core, string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return startCoreLazyServing(t, ln, relayAddr, room, name, cfg), ln.Addr().String()
}

// startCoreLazyServing is startCoreLazyWith over a listener the caller owns, so
// a fuzz target can serve the same bridge over an in-memory pipe instead of a
// socket (see pipeListener) without duplicating the setup.
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

// sessionPolicies extracts every session_policy the core pushed to this
// transport, in order.
// sessionPolicies reads the session_policy messages an adapter was sent.
//
// IT WAITS FOR THE QUEUE FIRST, and that is not defensiveness. Since
// 2026-09-07 sendToAdapter ENQUEUES rather than writes (core/adapterwriter.go):
// a writer goroutine drains, so "the call returned" no longer means "the
// adapter has it". Reading the inbox straight after a push is a race that wins
// on a fast machine and loses under -race on CI, which is exactly how it was
// found -- this suite passed locally at -count=3 and failed all three counts on
// the Linux race job.
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

// TestGhostCollisionNotPushedBeforeTheRoomHasSpoken is the regression for the
// race CI's -race job caught on 2026-08-22, made deterministic by driving
// pushSessionPolicy at the interleaving instead of waiting for it.
//
// "No Welcome yet" and "a room that advertised nothing" are the same value
// (""), and ResolveGhostCollision("", "") is ENABLED -- so a push in that
// state tells the adapter to make ghosts solid in a room that disabled them.
// It is reachable whenever a relaunching game re-attaches while the previous
// relay connection's teardown is still in flight: the attach path sees
// c.relay still set, returns "already connected", and the teardown clears the
// policy before the push reads it.
func TestGhostCollisionNotPushedBeforeTheRoomHasSpoken(t *testing.T) {
	c := New()
	rt := &recordingTransport{}
	c.attachedAdapter = rt
	c.adapterReady = true

	// Exactly the state the teardown leaves behind.
	c.relayGhostCollision = ""
	c.relayPolicyKnown = false
	c.pushSessionPolicy()
	if got := sessionPolicies(t, c, rt); len(got) != 0 {
		t.Fatalf("pushed %v before any Welcome -- an unknown room policy must not be "+
			"resolved into a physical effect", got)
	}

	// The Welcome that answers the question is what pushes.
	c.relayGhostCollision = protocol.GhostCollisionDisabled
	c.relayPolicyKnown = true
	c.pushSessionPolicy()
	if got := sessionPolicies(t, c, rt); len(got) != 1 || got[0] != protocol.GhostCollisionDisabled {
		t.Fatalf("after Welcome the adapter got %v, want one %q", got, protocol.GhostCollisionDisabled)
	}
}

// waitAdapterDrained blocks until everything enqueued for nd has been written,
// so a test can assert on what the adapter received. See sessionPolicies for
// why this exists at all.
func waitAdapterDrained(t *testing.T, c *Core, nd transport.Transport) {
	t.Helper()
	// idle(), not queueLen(). run() clears w.q the instant it TAKES a batch and
	// writes it several syscalls later, so waiting on the queue returns while
	// the batch is still in flight -- which is a race against the wire, on a
	// helper whose entire job is to make the wire observable. Measured at ~1-2%
	// over -count=500 on a fast box with no -race; CI runs -race -count=3 on a
	// slower one. Worse than the flake: the NEGATIVE assertion in this file
	// (nothing is pushed before the room has spoken) could pass over a live
	// regression, because an empty read is exactly what it wants to see.
	//
	// c.writerFor is deliberately still used rather than a lookup: a connection
	// with no writer yet is genuinely drained, and writerFor's fresh writer is
	// idle by construction.
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
