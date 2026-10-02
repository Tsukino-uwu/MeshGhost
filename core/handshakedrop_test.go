package core

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestARelayDropInsideTheHandshakeStillReconnects: a relay connection that dies after ConnectRelay returns but before
// auto-retry is armed is still redialled, or the game runs on invisible to the room. beforeArmingAutoRetryHook exists
// only to aim at that window.
func TestARelayDropInsideTheHandshakeStillReconnects(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room1", "alice", func(c *Core) {
		c.ReconnectInitialBackoff = 2 * time.Millisecond
		c.ReconnectMaxBackoff = 10 * time.Millisecond
	})

	// Fires on the first connect only: the reconnect after it must be allowed to succeed.
	var once sync.Once
	hook := func() {
		once.Do(func() {
			c.mu.Lock()
			conn := c.relay
			c.mu.Unlock()
			if conn == nil {
				t.Error("setup: there was no relay connection to drop inside the handshake")
				return
			}
			_ = conn.Close()
			// Waiting for the teardown to land makes this deterministic: the arming must happen with c.relay already
			// nil.
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
	beforeArmingAutoRetryHook.Store(&hook)
	t.Cleanup(func() { beforeArmingAutoRetryHook.Store(nil) })

	fa := dialFakeAdapter(t, bridgeAddr)
	t.Cleanup(func() { fa.conn.Close() })
	fa.hello("fuzzgame")

	// The invariant: a game that is still running ends up back in the room on its own.
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

// TestASessionDyingDuringOwnershipTransferStillReconnects: the same window on the ownership-transfer path, where the
// departing adapter's disconnect closes the relay and empties auto-retry before it is armed for the replacement. Called
// directly, since a test that dialled would mostly take the dial path and pass without entering this branch.
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

	// The replacement adapter's connection never speaks: this test drives the handover itself.
	replacement, err := transport.Dial(bridgeAddr)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	t.Cleanup(func() { replacement.Close() })

	var once sync.Once
	hook := func() {
		once.Do(func() {
			// What handleBridgeConn's OnDisconnect does for the departing adapter, in its order: disarm, then close the
			// relay.
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
	beforeArmingAutoRetryHook.Store(&hook)
	t.Cleanup(func() { beforeArmingAutoRetryHook.Store(nil) })

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

// TestARelayThatHangsUpMidHandshakeIsNoticedImmediately: a connection that dies before its Welcome ends ConnectRelay's
// wait at once, rather than after the dial timeout.
func TestARelayThatHangsUpMidHandshakeIsNoticedImmediately(t *testing.T) {
	ln := listenTLS(t)
	// A relay that accepts, TLS handshake included, then hangs up without answering: the handshake half of a restarting
	// relay.
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
	err := c.ConnectRelay("fuzzgame")
	took := time.Since(start)

	if err == nil {
		t.Fatal("ConnectRelay reported success against a relay that hung up without a welcome")
	}
	// Generously bounded: the point is not waiting out the timeout, and a loaded machine may be slow to see a closed
	// socket.
	if took > dialTimeout/3 {
		t.Fatalf("ConnectRelay took %v to notice a dropped connection with a %v dial timeout -- "+
			"it is waiting out the clock instead of watching the socket (err: %v)",
			took.Round(time.Millisecond), dialTimeout, err)
	}
}

// TestASecondConnectDoesNotInheritTheFirstsIdentity: a reconnect can complete before the old connection's OnDisconnect
// runs, and the stale-callback guard then leaves the old playerID in place. The new Welcome must still apply, or it is
// dropped as a second Welcome and the player goes deaf. Reproduced by connecting twice without letting the first
// connection die.
func TestASecondConnectDoesNotInheritTheFirstsIdentity(t *testing.T) {
	relayAddr := startRelay(t)
	c, _ := startCoreLazyWith(t, relayAddr, "room1", "alice", nil)

	if err := c.ConnectRelay("fuzzgame"); err != nil {
		t.Fatalf("first connect: %v", err)
	}
	first := c.PlayerID()
	if first == "" {
		t.Fatal("setup: the first connect produced no player id")
	}

	// A peer, so the second session has a roster worth losing.
	peer, peerBridge := startCoreLazy(t, relayAddr, "room1", "bob")
	peerAdapter := dialFakeAdapter(t, peerBridge)
	t.Cleanup(func() { peerAdapter.conn.Close() })
	peerAdapter.hello("fuzzgame")
	waitForPlayerID(t, peer)

	// The reconnect, arriving while the previous connection still holds the slot.
	if err := c.ConnectRelay("fuzzgame"); err != nil {
		t.Fatalf("second connect: %v -- the welcome for the new session was discarded", err)
	}

	second := c.PlayerID()
	if second == first {
		t.Fatalf("the core still calls itself %q after reconnecting -- it kept the dead session's "+
			"identity, and the relay is calling it something else", first)
	}
	if second == "" {
		t.Fatal("the core has no player id after reconnecting")
	}

	// The roster must be the new session's, or every peer's state is dropped as untrusted.
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		_, known := c.roster[peer.PlayerID()]
		c.mu.Unlock()
		if known {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("the peer %q is not in the roster after reconnecting -- every state it sends will be "+
		"dropped as untrusted, which is what being silently deaf looks like from inside", peer.PlayerID())
}

// TestAWelcomeForADeadConnectionIsNotApplied: a Welcome queued just before its socket dies must not be applied after
// the teardown, or the Core holds a player_id for no connection and drops the reconnect's Welcome as a second one. The
// invariant holds whichever way the select goes: the Core never claims an identity it has no connection for.
func TestAWelcomeForADeadConnectionIsNotApplied(t *testing.T) {
	ln := listenTLS(t)

	// A relay that welcomes and hangs up in the same breath, so both events reach the connect goroutine together.
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				br := bufio.NewReader(conn)
				if _, err := br.ReadString('\n'); err != nil {
					return
				}
				payload, err := json.Marshal(protocol.Welcome{PlayerID: "p1"})
				if err != nil {
					return
				}
				env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWelcome, Payload: payload})
				if err != nil {
					return
				}
				_, _ = conn.Write(append(env, '\n'))
			}(conn)
		}
	}()

	// Repeated because the select may take either branch, and the fix must make both orderings correct.
	for i := 0; i < 30; i++ {
		c := New()
		c.RelayAddr = ln.Addr().String()
		c.Room = "room1"
		c.DialTimeout = testTimeout
		_ = c.ConnectRelay("fuzzgame")

		c.mu.Lock()
		id, live := c.playerID, c.relay != nil
		c.mu.Unlock()
		if id != "" && !live {
			t.Fatalf("attempt %d: the core calls itself %q with no relay connection -- it applied a "+
				"welcome belonging to a session that had already been torn down, and the next "+
				"connection's welcome will be thrown away as an illegal second one", i, id)
		}
	}
}
