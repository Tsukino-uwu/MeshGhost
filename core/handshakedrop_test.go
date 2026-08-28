package core

import (
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// A relay connection that dies INSIDE the join handshake -- after ConnectRelay
// has returned but before ConnectRelayOnAdapterHello has armed auto-retry.
//
// Found 2026-08-28 by FuzzSchedule (schedule_convergence_fuzz_test.go), which
// hit it roughly one schedule in twenty on "both attach, both send, one side's
// relay socket dies". The window is small and the consequence is not: the
// relay's OnDisconnect ran while autoRetryGameID was still empty, so it tore
// the session down and started nothing, and nothing else ever would -- a
// redial is only triggered by a connection dropping, and by then there was no
// connection left to drop. The adapter had already been told bridge_ready, so
// the game ran on happily with its player invisible to the room until it was
// relaunched.
//
// The seam (beforeArmingAutoRetryHook) exists only for this test: the window is
// real but nothing outside this package can aim at it, and a regression test
// that reproduces a bug one run in twenty is not a regression test.
func TestARelayDropInsideTheHandshakeStillReconnects(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.ReconnectInitialBackoff = 2 * time.Millisecond
		c.ReconnectMaxBackoff = 10 * time.Millisecond
	})

	// Fires once, on the FIRST connect only: the reconnect that follows has to
	// be allowed to succeed, or this would test an unreachable relay instead.
	var once sync.Once
	beforeArmingAutoRetryHook = func() {
		once.Do(func() {
			c.mu.Lock()
			conn := c.relay
			c.mu.Unlock()
			if conn == nil {
				t.Error("setup: there was no relay connection to drop inside the handshake")
				return
			}
			_ = conn.Close()
			// Waiting for the teardown to actually land is what makes this
			// deterministic rather than another run of the same race: the
			// arming below must happen with c.relay already nil.
			deadline := time.Now().Add(testTimeout)
			for time.Now().Before(deadline) {
				c.mu.Lock()
				cleared := c.relay == nil
				c.mu.Unlock()
				if cleared {
					return
				}
				time.Sleep(time.Millisecond)
			}
			t.Error("setup: the dropped connection was never cleared, so the window was not reproduced")
		})
	}
	t.Cleanup(func() { beforeArmingAutoRetryHook = nil })

	fa := dialFakeAdapter(t, bridgeAddr)
	t.Cleanup(func() { fa.conn.Close() })
	fa.hello("fuzzgame")

	// The invariant: a game that is still running ends up back in the room on
	// its own. Before the fix this waited out the full timeout with c.relay
	// nil and no retry goroutine in existence.
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		connected := c.relay != nil && c.playerID != ""
		c.mu.Unlock()
		if connected {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("the core never reconnected after the relay dropped inside its handshake -- "+
		"player_id %q, relay connection present: %v", c.PlayerID(), func() bool {
		c.mu.Lock()
		defer c.mu.Unlock()
		return c.relay != nil
	}())
}

// The same window, the other door: the session dies as ownership passes from a
// departing adapter to its replacement.
//
// ConnectRelayOnAdapterHello takes a different path when the relay session is
// already up -- it transfers ownership instead of dialling, which is the fix
// for the relaunch bug CI found on 2026-08-27. That path had the identical
// hole: the departing adapter's disconnect can close the relay and empty
// auto-retry between "this session is up" and "arm auto-retry for the new
// adapter", and what is left is a core with an attached, bridge_ready adapter,
// no relay connection, no error, and a retry armed that nothing will ever run.
// FuzzSchedule reached it on the schedule "attach, detach, attach" (2026-08-29).
//
// Called directly rather than through a second bridge connection, because
// which of the two paths a real relaunch takes is exactly the race in
// question: a test that dialled would exercise the dial path most of the time
// and pass without ever entering this branch.
func TestASessionDyingDuringOwnershipTransferStillReconnects(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.ReconnectInitialBackoff = 2 * time.Millisecond
		c.ReconnectMaxBackoff = 10 * time.Millisecond
	})

	fa := dialFakeAdapter(t, bridgeAddr)
	t.Cleanup(func() { fa.conn.Close() })
	fa.hello("fuzzgame")
	waitForPlayerID(t, c)

	// The replacement adapter's connection. It never speaks -- this test drives
	// the handover itself, and what the connection carries is irrelevant to the
	// window.
	replacement, err := transport.Dial(bridgeAddr)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	t.Cleanup(func() { replacement.Close() })

	var once sync.Once
	beforeArmingAutoRetryHook = func() {
		once.Do(func() {
			// Exactly what handleBridgeConn's OnDisconnect does for the
			// departing adapter, in the order it does it: disarm first, then
			// close the relay. Doing it here is what puts it inside the window.
			c.mu.Lock()
			c.autoRetryGameID = ""
			c.autoRetryAdapterGameVersion = ""
			c.autoRetryBridgeConn = nil
			conn := c.relay
			c.mu.Unlock()
			if conn == nil {
				t.Error("setup: there was no relay session to transfer, so the window was not reproduced")
				return
			}
			_ = conn.Close()
			deadline := time.Now().Add(testTimeout)
			for time.Now().Before(deadline) {
				c.mu.Lock()
				cleared := c.relay == nil
				c.mu.Unlock()
				if cleared {
					return
				}
				time.Sleep(time.Millisecond)
			}
			t.Error("setup: the closed session was never cleared, so the window was not reproduced")
		})
	}
	t.Cleanup(func() { beforeArmingAutoRetryHook = nil })

	if err := c.ConnectRelayOnAdapterHello("fuzzgame", "", replacement); err != nil {
		t.Fatalf("ownership transfer: %v", err)
	}

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		connected := c.relay != nil && c.playerID != ""
		c.mu.Unlock()
		if connected {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("the core never reconnected after the session died mid-transfer -- an attached, " +
		"bridge_ready adapter with no relay connection and nothing retrying is the dead session " +
		"the transfer path exists to prevent")
}

// A relay that hangs up mid-handshake is noticed, rather than waited out.
//
// ConnectRelay's wait for Welcome used to have exactly two ends: the Welcome
// (or a Reject) and the dial timeout. A connection that simply DIED had
// neither, so the caller blocked for the whole timeout -- and on the bridge
// path that caller is an adapter's Hello, so a game that had just launched sat
// there for ten seconds on a connection that was already gone, then got told
// "timed out waiting for welcome", which describes the clock rather than what
// happened.
//
// Found 2026-08-29 by FuzzSchedule: the schedule "attach, then kill the relay
// socket" produced it every single run once the target stopped using an
// unrealistically short dial timeout to hide it.
func TestARelayThatHangsUpMidHandshakeIsNoticedImmediately(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	// A relay that accepts and then hangs up without ever answering: the
	// handshake half of a restarting relay, and the one case neither existing
	// end of the select could see.
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	c := New()
	c.RelayAddr = ln.Addr().String()
	c.Room = "room1"
	const dialTimeout = 30 * time.Second
	c.DialTimeout = dialTimeout

	start := time.Now()
	err = c.ConnectRelay("fuzzgame")
	took := time.Since(start)

	if err == nil {
		t.Fatal("ConnectRelay reported success against a relay that hung up without a welcome")
	}
	// Generously bounded: the point is "does not wait out the timeout", and a
	// loaded machine may take a moment to notice a closed socket.
	if took > dialTimeout/3 {
		t.Fatalf("ConnectRelay took %v to notice a dropped connection with a %v dial timeout -- "+
			"it is waiting out the clock instead of watching the socket (err: %v)",
			took.Round(time.Millisecond), dialTimeout, err)
	}
}
