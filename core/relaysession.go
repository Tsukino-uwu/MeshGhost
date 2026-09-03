package core

// The core's relay connection: dialling it, losing it, and getting it back.
//
// Split out of core.go on 2026-08-25. Everything here runs on, or races with, the
// relay connection lifecycle -- which is why the reconnect bookkeeping and the
// permanent-refusal handling live beside the connect path rather than scattered
// through a 2,048-line file.

import (
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// ConnectRelay dials this Core's RelayAddr, performs the hello/welcome
// handshake for gameID using its Room/DisplayName/RoomCode/GameVersion/
// DialTimeout fields (set these before calling), and wires up handling of
// join/leave/state messages from the relay for the rest of this Core's
// life. It blocks until Welcome, Reject, or timeout.
//
// Collapsed from a 7-parameter signature (addr, gameID, room, displayName,
// roomCode, gameVersion, timeout) in a review pass: every parameter except
// gameID already duplicated one of these fields — the same redundancy
// applyFileConfig's own configTargets struct in cmd/meshghost was
// introduced to avoid. The version advertised is c.GameVersion when the
// user set one, and otherwise whatever the adapter last reported through
// ConnectRelayOnAdapterHello — resolved per call, so an adapter that
// reconnects reporting a new version is advertised under the new one.
func (c *Core) ConnectRelay(gameID string) error {
	addr, room, displayName, roomCode, timeout :=
		c.RelayAddr, c.Room, c.DisplayName, c.RoomCode, c.DialTimeout

	gameVersion := c.GameVersion
	if gameVersion == "" {
		c.mu.Lock()
		gameVersion = c.adapterGameVersion
		c.mu.Unlock()
	}

	// protocol.MaxLineBytes, not transport's generous 64KiB package
	// default — found in a review pass: the relay already used its own
	// tighter limit for connections it accepts, but the core's own dialed
	// relay connection didn't, despite enforcing every per-field cap on
	// receive (storeRemoteState). 0/0 for idle/write timeout means "use
	// transport's own defaults".
	// The handshake always happens over tcp, whatever Transport says, and
	// that is not configurable. Only after it does this Core move to the
	// transport the user actually asked for. See resolveTransport.
	kind, dialAddr, tlsOpts, err := c.resolveTransport(addr, gameID, room, displayName, roomCode, gameVersion)
	if err != nil {
		return fmt.Errorf("core: dial relay: %w", err)
	}

	// netx.Dial rather than transport.Dial* so the transport is selectable
	// (agent_docs/architecture.md's transport ADR); transport.FromConnWithLimits
	// then applies the same NDJSON framing and limits to whatever net.Conn
	// comes back, identically for tcp, udp and quic. DefaultDialTimeout,
	// not this call's `timeout`, matches what transport.DialWithLimits used
	// internally before this change — `timeout` bounds the wait for Welcome
	// further down, which is a different thing.
	netConn, err := netx.DialWithTLS(kind, dialAddr, transport.DefaultDialTimeout, tlsOpts)
	if err != nil {
		// In automatic mode, a transport that cannot be DIALLED here is not tried again --
		// the next attempt falls to the next preference, and tcp always works because the
		// handshake already happened over it. Without this a machine that cannot do quic at
		// all (Wine returns WSAEOPNOTSUPP from quic-go's UDP setup) re-picks quic forever.
		//
		// An explicit preference is deliberately NOT remembered: someone who asked for quic
		// should keep being told it is failing rather than be quietly moved.
		//
		// TWO CONSECUTIVE failures, not one. See Core.transportDialFailures: a relay that is
		// merely RESTARTING can fail a single quic dial while its tcp listener is already back,
		// and condemning on that would silently pin the rest of the session to tcp.
		if c.Transport == netx.Auto && kind != netx.TCP {
			c.mu.Lock()
			if c.transportDialFailures == nil {
				c.transportDialFailures = map[string]int{}
			}
			c.transportDialFailures[kind.String()]++
			n := c.transportDialFailures[kind.String()]
			condemn := n >= transportDialFailuresBeforeGivingUp
			first := false
			if condemn {
				if c.unusableTransports == nil {
					c.unusableTransports = map[string]bool{}
				}
				first = !c.unusableTransports[kind.String()]
				c.unusableTransports[kind.String()] = true
			}
			c.mu.Unlock()
			switch {
			case first:
				log.Printf("core: %s cannot be used on this machine (%v) -- %d attempts in a row "+
					"failed, so it will not be chosen again this session; the next attempt falls "+
					"back to the next transport", kind, err, n)
			case !condemn:
				log.Printf("core: %s dial failed (%v) -- retrying; it is only given up on after "+
					"%d failures in a row, because a restarting relay can fail one", kind, err,
					transportDialFailuresBeforeGivingUp)
			}
		}
		return fmt.Errorf("core: dial relay: %w", err)
	}
	if kind == netx.TCP && c.TLS != tlsx.Off && !tlsx.IsTLS(netConn) {
		log.Printf("core: WARNING: this session is UNENCRYPTED tcp — the relay at %s does not "+
			"speak TLS, so the room code and everything else cross the network in the clear", dialAddr)
	}
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
	c.mu.Lock()
	// TAKING THE SLOT OVER FORGETS WHAT WAS IN IT. If a previous connection is
	// still sitting here, this Core is done with it whatever its own callback
	// has managed to run yet -- and leaving its identity in place is what makes
	// this connection's Welcome look like an illegal second one and get thrown
	// away. See forgetRelaySessionLocked for the full failure and the run that
	// found it.
	replaced := c.relay
	if replaced != nil && replaced != conn {
		c.forgetRelaySessionLocked()
	}
	c.relay = conn
	c.mu.Unlock()
	if replaced != nil && replaced != conn {
		// The samples belonged to the session that just ended, and the socket
		// to a connection nobody will read again. Both outside the lock:
		// dropAllRemotes takes it, and Close can land its own callback.
		c.dropAllRemotes()
		_ = replaced.Close()
	}

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	// Closed when this connection dies, so the wait for Welcome below ends the
	// moment the socket does instead of running out the dial timeout. Without
	// it a relay that hangs up mid-handshake -- restarting, refusing at the TCP
	// layer, or simply dropped -- left the caller blocked for the whole
	// timeout, and on the bridge path that caller is an adapter's Hello: the
	// game sat there waiting on a connection that was already gone. Found
	// 2026-08-29 by the schedule fuzzer, which could produce it on demand once
	// the dial timeout was set to a realistic ten seconds.
	gone := make(chan struct{})
	var goneOnce sync.Once
	conn.OnError(func(err error) { log.Printf("core: relay connection error: %v", err) })
	conn.OnDisconnect(func(err error) {
		log.Printf("core: relay disconnected: %v", err)
		goneOnce.Do(func() { close(gone) })
		// Without this, a remote's last known snapshot sits in c.remotes
		// forever: remoteBuffer.at() holds the newest sample with no
		// extrapolation once renderTime passes it, so nothing about the
		// existing per-frame tick logic would ever notice the relay is
		// gone and there's nothing to despawn. Clearing here means the
		// very next adapter frame sees every remote vanish from
		// remoteStatesAt's result at once, which onAdapterFrame already
		// turns into a despawn_remote per id via its existing
		// rendered-vs-current diff — no new wire message, no bridge
		// change, just making sure this path actually fires.
		//
		// Moved inside the wasCurrent guard below in a review pass
		// 2026-08-16: it was the one thing this callback did unguarded, so a
		// stale connection's late OnDisconnect would have wiped the *live*
		// connection's remotes, despawning and respawning every ghost. No
		// reachable trigger was found at the time, so it was recorded as
		// removing an asymmetry rather than fixing an observed bug.
		//
		// The reason then given for it being unreachable — "readLoop fires
		// synchronously on Close" — is WRONG, and believing it caused a real
		// bug: readLoop runs on its own goroutine (transport.FromConn starts
		// it), so Close only unblocks its Scan and this callback lands
		// whenever that goroutine is next scheduled. See
		// clearRelayIfCurrent, which exists because ConnectRelay's failure
		// paths cannot wait for it. The wasCurrent guard is load-bearing,
		// not tidiness.
		wasCurrent, retry := c.clearRelaySession(conn)

		if wasCurrent {
			c.dropAllRemotes()
		}

		// See autoRetryGameID's doc comment: only armed by a prior
		// ConnectRelayOnAdapterHello success, so this is a no-op for
		// cmd/meshghost-fakeadapter and core_test.go's direct ConnectRelay
		// callers.
		if wasCurrent && retry.gameID != "" {
			go c.reconnectWithBackoff(retry.gameID, retry.adapterGameVersion, retry.bridgeConn)
		}
	})
	conn.OnReceive(func(payload []byte) { c.handleRelayMessage(conn, payload, welcome, reject) })

	// A resume token from a previous session on this Core, if any. Presented
	// on every connect attempt: the relay silently ignores one it does not
	// recognise, so there is no need to know whether this is a reconnect.
	c.mu.Lock()
	resumeToken := c.resumeToken
	// Told to the relay so it can stop forwarding what this core would only
	// discard at render time. It is the exact inverse of the adapter's own
	// declaration, read under the same lock that writes it in bridgeserve.go,
	// which runs before ConnectRelayOnAdapterHello -- so an adapter that takes
	// over area visibility (Emerald, Crystal with cross-map armed) is never
	// filtered by the relay either.
	//
	// A core with no adapter attached yet reports true, which is harmless: it
	// sends no state, so it has no area of its own on record and the relay's
	// filter fails open for it regardless.
	ownAreaOnly := !c.adapterRenderAllAreas
	c.mu.Unlock()

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
		NameColor:       c.NameColor,
		RoomCode:        roomCode,
		GameVersion:     gameVersion,
		MaxReceiveHz:    c.MaxReceiveHz,
		Features:        c.effectiveFeatures(),
		ResumeToken:     resumeToken,
		OwnAreaOnly:     ownAreaOnly,
	})
	if err != nil {
		_ = conn.Close()
		return err
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		_ = conn.Close()
		return err
	}
	if err := conn.Send(env); err != nil {
		_ = conn.Close()
		return fmt.Errorf("core: send hello: %w", err)
	}

	if timeout <= 0 {
		// Every other timing knob in this codebase (transport.go,
		// relay.go) treats <=0 as "use the default" — found missing here
		// in a review pass. Without this, a Core built without explicitly
		// setting DialTimeout (nothing but cmd/meshghost does) times out
		// on its very first select below.
		timeout = DefaultDialTimeout
	}

	select {
	case w := <-welcome:
		c.mu.Lock()
		if c.relay != conn {
			// The connection died while its own Welcome was sitting in this
			// channel, and the teardown has already run. Applying it now
			// RESURRECTS the dead session's identity on a Core that has none
			// -- and the next connection's Welcome is then thrown away as an
			// illegal second one, leaving the core answering to a name the
			// relay retired and deaf to everyone in the room.
			//
			// This is the last of the five the schedule fuzzer found on
			// 2026-08-29, and the only one where the losing race is INSIDE a
			// single connect: the select can be handed a buffered Welcome and
			// a closed socket at the same instant, and it is free to take
			// either. Both are now correct.
			c.mu.Unlock()
			_ = conn.Close()
			return fmt.Errorf("core: the relay connection dropped before its welcome could be applied")
		}
		c.playerID = w.PlayerID
		c.relayGame = gameID
		c.mu.Unlock()
		if agreed := c.RoomFeatures(); len(agreed) > 0 {
			// Worth one line at connect: a room's capabilities are matched
			// exactly and are the difference between a lease being arbitrated
			// and silently ignored, so "which set did we actually land on"
			// should never require reading the relay's log to answer.
			log.Printf("core: room %q negotiated capabilities %v", room, agreed)
		}
		go c.sendHeartbeats(conn)
		return nil
	case r := <-reject:
		_ = conn.Close()
		c.clearRelayIfCurrent(conn)
		return &RejectError{Reason: r.Reason}
	case <-gone:
		// Deliberately the same shape as the timeout below -- an error, not a
		// retry from in here. Whoever asked for this connection decides what
		// to do about it, and both callers already know how: cmd/meshghost's
		// startup loop and reconnectWithBackoff both back off and try again.
		_ = conn.Close()
		c.clearRelayIfCurrent(conn)
		return fmt.Errorf("core: the relay connection dropped before the welcome arrived")
	case <-time.After(timeout): // wall-clock: waiting on a RELAY over a socket
		_ = conn.Close()
		c.clearRelayIfCurrent(conn)
		return fmt.Errorf("core: timed out waiting for welcome from relay")
	}
}

// clearRelaySession forgets everything that belonged to ONE relay connection
// and reports whether conn was the live one, along with what a redial would
// need. Every field it touches is per-connection: carrying any of them into
// the next session means answering a new relay's questions with an old
// relay's answers. Clearing c.relay is what lets a later bridge Hello (the
// adapter reconnecting, e.g. relaunching the game) redial via
// ConnectRelayOnAdapterHello, instead of finding it non-nil and treating this
// Core as connected forever.
//
// It is a method rather than the body of ConnectRelay's OnDisconnect closure
// because a closure needs a real socket and a real drop to reach, which is
// why eleven of these twelve clears went untested until 2026-08-22. The
// stale-callback guard in particular is unreachable from a black-box test:
// it only fires when an OLD connection's callback lands after a NEWER one has
// replaced it, and nothing outside this package can arrange that. See
// core/reconnect_test.go.
func (c *Core) clearRelaySession(conn transport.Transport) (bool, relayRetry) {
	c.mu.Lock()
	defer c.mu.Unlock()

	retry := relayRetry{c.autoRetryGameID, c.autoRetryAdapterGameVersion, c.autoRetryBridgeConn}
	if c.relay != conn {
		// A stale connection's callback, landing after a newer one already
		// replaced it. Touching anything here would wipe the LIVE session.
		//
		// This is correct and it is NOT the whole story: what the old session
		// left behind still has to be forgotten, and by the time this runs the
		// new connection owns the fields. That is why the forgetting also
		// happens at the takeover -- see forgetRelaySessionLocked's callers.
		return false, retry
	}

	c.relay = nil
	c.forgetRelaySessionLocked()

	return true, retry
}

// forgetRelaySessionLocked drops everything that belonged to ONE relay
// connection, without touching c.relay itself. Called from two places, and the
// second one is why it exists: clearRelaySession, when a connection this Core
// still owns dies, and ConnectRelay, when a NEW connection takes the slot over.
//
// The takeover call closes the fourth bug the schedule fuzzer found
// (2026-08-29, on CI's Windows runner, in a schedule that drops a relay socket
// under a running game). A reconnect can complete before the dead connection's
// OnDisconnect is scheduled -- the callback runs on that connection's own read
// goroutine, whenever the runtime gets to it. The stale-callback guard above
// then correctly declines to touch anything, and the old session's playerID
// was therefore never cleared. The new connection's Welcome then hits the
// "a second Welcome is protocol-illegal" guard in handleRelayMessage, which
// keys off exactly that field, and is DISCARDED: the core keeps the old id,
// gets no roster, no send rate, no policy and no clock for the session it is
// actually on -- and since states from ids outside the roster are dropped by
// design, it goes permanently, silently deaf. Attached adapter, bridge_ready
// sent, live socket, no error logged, and every other player invisible.
//
// The caller must hold c.mu.
func (c *Core) forgetRelaySessionLocked() {
	c.playerID = ""
	c.relayGame = ""
	c.relayOwner = nil
	// Cleared so a reconnect (to this relay again, or a different,
	// differently-configured one) starts from effectiveSendInterval's
	// "nothing advertised yet" fallback instead of inheriting this
	// connection's now-stale rate.
	c.serverSendInterval = 0
	// Cleared with the rate above so a reconnect to a differently-configured
	// relay never inherits a stale policy. The adapter is told the new value
	// once the next Welcome lands.
	c.relayGhostCollision = ""
	c.relayPolicyKnown = false
	// Per-connection too: the room's agreed capabilities, the clock offset (a
	// different relay has a different clock, and even the same one restarted
	// may have jumped), the outstanding ping timings, and whether this session
	// was a resumption. The resume TOKEN deliberately survives — this is
	// exactly the drop it exists for, and a test pins that it is still here
	// afterwards precisely because it is one line among twelve clears.
	c.activeFeatures = nil
	c.resumed = false
	c.clock = clockSync{}
	// Reset with the clock it derives from: a new connection may have a
	// completely different offset, and carrying the old ceiling across would
	// freeze the new one until real time caught up.
	c.lastNowMs = 0
	c.pendingPings = nil
	// Roster is per-connection: player_ids are only meaningful within the
	// connection that assigned them. Welcome used to be the de facto reset (it
	// replaced the map wholesale), but it no longer does -- see the Welcome
	// case, which now merges so a Join that arrives first isn't erased -- so
	// the reset has to be explicit here, or a stale id could outlive the
	// connection that named it and pass the trust check on the next one.
	c.roster = make(map[string]struct{})
}

func (c *Core) clearRelayIfCurrent(conn transport.Transport) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.relay == conn {
		c.relay = nil
	}
}

// ConnectRelayOnAdapterHello lazily connects Core to the relay the first
// time an adapter declares its game (and, optionally, game version) via a
// bridge.Hello, instead of requiring the caller to already know either at
// startup — see agent_docs/architecture.md's ADR. Uses RelayAddr/Room/
// DisplayName/RoomCode/DialTimeout, which must be set (directly on the
// Core) before any bridge connection can send a Hello.
//
// adapterGameVersion is what the adapter itself reported; c.GameVersion, if
// set, overrides it — mirroring how -game/config already lets a caller with
// no real adapter (dev-scripts, cmd/meshghost-fakeadapter) force a value
// instead of waiting for one to arrive over the bridge.
//
// bridgeConn is the specific bridge connection whose Hello triggered this
// call, or nil for a caller with no bridge connection at all (the eager
// -game/config path). Recorded as c.relayOwner on a successful new
// connect, so only this connection's own later disconnect is allowed to
// tear down the relay session it established — see relayOwner's doc
// comment.
//
// No-op if this Core is already connected to the relay for the same
// gameID. If it's already connected for a *different* gameID, returns an
// error rather than reconnecting: the earlier connection's relay Hello
// already committed this Core to that game and can't be retracted, so a
// second game can't share the same Core/process.
func (c *Core) ConnectRelayOnAdapterHello(gameID, adapterGameVersion string, bridgeConn transport.Transport) error {
	// OFFLINE IS ENFORCED HERE, at the one funnel, and not at the caller: both
	// ways into a relay dial come through this function -- cmd/meshghost's
	// startup retry loop when -game is set, and an adapter's own hello over the
	// bridge when it is not -- which is exactly why it was written as a funnel.
	// Guarding only the loop would leave a game launching itself into a dial
	// the player asked not to happen. Nil, not an error: nothing failed.
	if c.Offline {
		return nil
	}
	c.relayConnectMu.Lock()
	defer c.relayConnectMu.Unlock()

	c.mu.Lock()
	alreadyConnected := c.relay != nil
	connectedGame := c.relayGame
	c.mu.Unlock()

	if alreadyConnected {
		if connectedGame == gameID {
			// OWNERSHIP FOLLOWS THE CURRENT ADAPTER, and this transfer is the
			// whole reason this branch is not a bare `return nil` any more.
			//
			// A relaunched game reaches here: the relay session is still up for
			// the same game, so there is nothing to dial. But without the
			// transfer, c.relayOwner stays the DEPARTING bridge connection --
			// and handleBridgeConn's OnDisconnect tears the relay session down
			// when `c.relayOwner == nd`, which is still true for a connection
			// that has already been replaced. So the departing adapter killed
			// the session its replacement had just been handed, AND disarmed
			// auto-retry on the way out, leaving the Core with an attached
			// adapter, no relay connection and nothing to redial it: a dead
			// session until the game is restarted again.
			//
			// Found by CI on 2026-08-27 as a one-in-two intermittent failure of
			// internal/e2e's TestARelaunchedGameGetsAWorkingSessionAgain ("no
			// ghost completed the round trip within 1m0s of relaunching the
			// adapter"). 25 local -race runs of that test never reproduced it;
			// the window is between the departing connection releasing the
			// admission slot and its relay Close landing, which is
			// microseconds wide and which a real relaunch normally misses.
			//
			// Re-arming auto-retry is part of the fix, not tidying: if the
			// relay connection is already dying as we transfer, the retry --
			// now pointing at the LIVE bridge connection rather than the dead
			// one -- is what reconnects it.
			if bridgeConn != nil {
				runBeforeArmingAutoRetryHook()
				c.mu.Lock()
				c.relayOwner = bridgeConn
				c.autoRetryGameID = gameID
				c.autoRetryAdapterGameVersion = adapterGameVersion
				c.autoRetryBridgeConn = bridgeConn
				// The SECOND door into the dead session this branch was written
				// to close, found by the schedule fuzzer 2026-08-29 on
				// "attach, detach, attach". The session we decided to transfer
				// can die between that decision and this arming: the departing
				// adapter's OnDisconnect closes the relay and empties
				// auto-retry, and if the teardown reaches clearRelaySession
				// first it finds nothing armed and starts nothing -- and then
				// this arms a retry that no future event will ever run,
				// because a redial is only triggered by a connection dropping
				// and the connection is already gone. The core sits there with
				// an attached, bridge_ready adapter, no relay connection, no
				// error and nothing retrying, which is precisely the state the
				// ownership transfer above exists to prevent.
				lost := c.relay == nil
				c.mu.Unlock()
				if lost {
					log.Printf("core: the relay session died as ownership passed to the new adapter — reconnecting in the background")
					go c.reconnectWithBackoff(gameID, adapterGameVersion, bridgeConn)
				}
			}
			return nil
		}
		return fmt.Errorf("core: already connected to the relay as game %q, cannot also serve %q on the same process", connectedGame, gameID)
	}

	c.mu.Lock()
	cachedGame, cachedReason := c.permanentRejectGame, c.permanentRejectReason
	c.mu.Unlock()
	if cachedGame == gameID && cachedReason != "" {
		// Already logged once, below, the first time this was hit. A
		// permanently-rejected combination doesn't change without a config
		// edit and restart, so retrying the relay dial (and re-logging
		// identically) every time the adapter reconnects to the bridge
		// would just spam both this process's log and the relay.
		return &RejectError{Reason: cachedReason}
	}

	// Record what the adapter reported in its own field rather than writing
	// it into c.GameVersion. c.GameVersion is the *user's* override, and
	// latching an adapter-reported value into it destroys the "not set"
	// state for the rest of the process: an adapter that reconnects
	// reporting a different version (the user enabled DLC and relaunched the
	// game, say) would then be advertised to the relay under the first
	// version it ever reported, with nothing in the log to explain it.
	// Found in a review pass 2026-08-16; ConnectRelay resolves the two.
	c.mu.Lock()
	c.adapterGameVersion = adapterGameVersion
	c.mu.Unlock()
	err := c.ConnectRelay(gameID)
	if err != nil {
		reason, isReject := asRejectReason(err)
		permanent := isReject && isPermanentRejectReason(reason)

		now := time.Now() // wall-clock: throttles a log line for a human

		c.mu.Lock()
		changed := c.lastConnectErr != err.Error()
		c.lastConnectErr = err.Error()
		if changed || c.connectFailingSince.IsZero() {
			c.connectFailingSince = now
		}
		// Repeat the same message periodically while it keeps failing —
		// see reconnectLogInterval for why silence is the worse option.
		stillFailing := !permanent && !changed &&
			!c.lastConnectErrLoggedAt.IsZero() &&
			now.Sub(c.lastConnectErrLoggedAt) >= getReconnectLogInterval()
		if changed || stillFailing {
			c.lastConnectErrLoggedAt = now
		}
		failingFor := now.Sub(c.connectFailingSince)
		relayAddr := c.RelayAddr
		if permanent {
			c.permanentRejectGame = gameID
			c.permanentRejectReason = reason
		}
		c.mu.Unlock()

		switch {
		case changed:
			// No "core: " prefix here — every error ConnectRelay can
			// return is already self-prefixed with it (dial/send/timeout
			// errors, and RejectError.Error()), so this used to print
			// "core: core: ...". Found in a review pass.
			if permanent {
				log.Printf("%v — not retrying automatically; fix the underlying config and restart to try again", err)
			} else {
				log.Printf("%v — will keep retrying", err)
			}
		case stillFailing:
			log.Printf("core: still cannot reach the relay at %s after %s of retrying: %v",
				relayAddr, failingFor.Round(time.Second), err)
		}
		return err
	}

	runBeforeArmingAutoRetryHook()

	c.mu.Lock()
	c.relayGame = gameID
	c.relayOwner = bridgeConn
	c.lastConnectErr = ""
	c.lastConnectErrLoggedAt = time.Time{}
	c.connectFailingSince = time.Time{}
	c.permanentRejectGame = ""
	c.permanentRejectReason = ""
	c.autoRetryGameID = gameID
	c.autoRetryAdapterGameVersion = adapterGameVersion
	c.autoRetryBridgeConn = bridgeConn
	// The drop that lands INSIDE this handshake, between ConnectRelay
	// returning and auto-retry being armed here. OnDisconnect ran while
	// autoRetryGameID was still empty, so it cleared the session and started
	// nothing -- and nothing else ever would, because a redial is only ever
	// triggered by a connection dropping and there is no longer a connection
	// to drop. The game keeps running, the adapter was told bridge_ready, and
	// the player is invisible to the room until they relaunch it.
	//
	// Read under the same lock clearRelaySession takes, which is what makes
	// "exactly one retry loop" true rather than likely: whichever of the two
	// gets the lock second sees the other's decision. If it cleared first, its
	// retry.gameID was empty and this starts the loop; if this armed first, it
	// sees a live c.relay and starts nothing, because OnDisconnect will.
	//
	// Found 2026-08-28 by core/schedule_convergence_fuzz_test.go, on the schedule
	// "both attach, both send, alice's relay socket dies" -- roughly one run
	// in twenty, which is exactly the shape a fixed-sequence test cannot see.
	lostDuringHandshake := c.relay == nil
	c.mu.Unlock()

	if lostDuringHandshake {
		log.Printf("core: the relay connection dropped while this session was still being set up — reconnecting in the background")
		go c.reconnectWithBackoff(gameID, adapterGameVersion, bridgeConn)
	}

	if c.OnRelayConnected != nil {
		c.OnRelayConnected(gameID)
	}
	return nil
}

// beforeArmingAutoRetryHook, if set, runs at the point where
// ConnectRelayOnAdapterHello is about to arm auto-retry -- on BOTH paths there,
// the one that dialled and the one that transferred ownership of a session
// that was already up. Nil in every shipped path and set only by
// handshakedrop_test.go, which needs the relay connection to die inside that
// window: the window is real (a fuzzed schedule hits it about one run in
// twenty) but nothing outside this package can aim at it, so without the seam
// both regression tests for it would be probabilistic ones.
//
// ATOMIC, AND THAT IS NOT DECORATION -- a plain func() variable here was a real
// data race that CI's -race job would have caught eventually and that a local
// run reproduced roughly once in five full suites (2026-08-30). The write is
// the test's own t.Cleanup clearing the hook; the read is this package's
// RECONNECT goroutine, which outlives the test that started it and is still
// looping through ConnectRelayOnAdapterHello when Cleanup runs. So it is a
// test-infrastructure race rather than a shipped bug -- the hook is nil in
// every real session -- but it fails the suite just as hard, and "only tests"
// is not a reason to leave a race in a package whose -race job is the thing
// standing between this project and the bugs local runs cannot find.
//
// The load costs an atomic read on a path that is already dialling a socket.
var beforeArmingAutoRetryHook atomic.Pointer[func()]

// runBeforeArmingAutoRetryHook loads and runs the hook if one is set.
func runBeforeArmingAutoRetryHook() {
	if fn := beforeArmingAutoRetryHook.Load(); fn != nil {
		(*fn)()
	}
}

// reconnectWithBackoff keeps calling ConnectRelayOnAdapterHello for
// (gameID, adapterGameVersion, bridgeConn) until it succeeds or is
// permanently refused, so a relay restart or network blip after an already-
// successful connect doesn't leave this Core stuck disconnected forever —
// see autoRetryGameID's doc comment on the Core struct for the live incident
// that surfaced this gap and why cmd/meshghost's own connectRelayWithRetry
// (which only drives the *first* connect attempt) didn't cover it.
//
// Unlike cmd/meshghost's connectRelayWithRetry, this never calls
// log.Fatalf on a permanent rejection — Core is a library and must not
// exit the host process out from under a real adapter (a running game).
// It logs and stops retrying instead; ConnectRelayOnAdapterHello's own
// permanent-reject caching means this doesn't spam the relay either.
func (c *Core) reconnectWithBackoff(gameID, adapterGameVersion string, bridgeConn transport.Transport) {
	backoff, backoffMax := c.reconnectBackoffBounds()
	for {
		err := c.ConnectRelayOnAdapterHello(gameID, adapterGameVersion, bridgeConn)
		if err == nil {
			return
		}
		if IsPermanentRejectErr(err) {
			log.Printf("core: %v — giving up on automatic reconnect for game %q", err, gameID)
			return
		}
		time.Sleep(backoff) // wall-clock: paces real reconnect attempts
		backoff = nextBackoffWithin(backoff, backoffMax)
	}
}

// retryRelayForSoloAdapter keeps trying the relay for an adapter that was
// ACCEPTED without one (bridgeserve.go: a relay that is merely down no longer
// refuses the game). It is deliberately NOT reconnectWithBackoff:
//
//   - it stops when the adapter it belongs to is gone. That loop starts from a
//     relay DROP, with its adapter still attached, so it never needed the check;
//     this one starts at hello time and would otherwise outlive the game and go
//     on redialling on behalf of a closed bridge connection.
//   - the identity check is exact (nd is the attached adapter, not merely one).
//     A relaunched game arrives as a NEW connection and brings its own hello,
//     which starts its own attempt; this loop redialling on the old one's behalf
//     would hand relayOwner a connection that has already gone.
//
// A success is logged, because the session silently changing from solo to
// connected is exactly the kind of thing a player should be able to see in the
// log afterwards.
func (c *Core) retryRelayForSoloAdapter(gameID, adapterGameVersion string, nd transport.Transport) {
	backoff, backoffMax := c.reconnectBackoffBounds()
	for {
		c.mu.Lock()
		mine := c.attachedAdapter == nd
		c.mu.Unlock()
		if !mine {
			return
		}
		err := c.ConnectRelayOnAdapterHello(gameID, adapterGameVersion, nd)
		if err == nil {
			log.Printf("core: a relay answered -- no longer playing alone; other players in the room will appear now")
			return
		}
		if IsPermanentRejectErr(err) {
			log.Printf("core: %v -- staying solo for this session; recording, replays and chasers still work", err)
			return
		}
		time.Sleep(backoff) // wall-clock: paces real reconnect attempts
		backoff = nextBackoffWithin(backoff, backoffMax)
	}
}

// PlayerID returns the id assigned by the relay at Welcome. Empty until
// ConnectRelay succeeds.
func (c *Core) PlayerID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.playerID
}

// handleRelayMessage handles one line from the relay. conn is the connection it
// arrived on, and a message from a connection this Core has already replaced is
// DISCARDED rather than applied.
//
// That guard is the other half of clearRelaySession's stale-callback guard, and
// it is there for the same reason: a connection's callbacks run on that
// connection's own goroutine and land whenever the runtime gets to them, so a
// dead session's Welcome can arrive after a new session is established.
// Applied, it overwrites the LIVE session's identity with a retired one -- the
// core then calls itself by a name the relay has given to nobody, while the
// room calls it something else, and every check that compares the two silently
// disagrees. Found 2026-08-29 by the schedule fuzzer on a constrained CPU, one
// shape after the takeover fix in ConnectRelay closed the mirror-image case.
//
// A nil conn means "no connection context" and skips the check, which is how
// core_test.go drives this function directly.
func (c *Core) handleRelayMessage(conn transport.Transport, payload []byte, welcome chan<- protocol.Welcome, reject chan<- protocol.Reject) {
	if conn != nil {
		c.mu.Lock()
		stale := c.relay != conn
		c.mu.Unlock()
		if stale {
			return
		}
	}
	// Counted before parsing, so a malformed line still shows up as inbound
	// cost -- it was paid for on the wire either way.
	atomic.AddUint64(&c.stats.messagesReceived, 1)
	atomic.AddUint64(&c.stats.bytesReceived, uint64(len(payload)))

	var env protocol.Envelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return
	}

	switch env.Type {
	case protocol.TypeWelcome:
		c.mu.Lock()
		alreadyWelcomed := c.playerID != ""
		c.mu.Unlock()
		if alreadyWelcomed {
			// A second Welcome mid-connection is protocol-illegal — Welcome
			// only ever arrives once, replying to this Core's own Hello.
			// Ignored rather than reprocessed, so a hostile or buggy relay
			// can't reset this Core's roster/playerID mid-session.
			log.Printf("core: received a second Welcome from the relay after already connected — ignoring")
			return
		}
		var w protocol.Welcome
		if err := json.Unmarshal(env.Payload, &w); err == nil {
			c.mu.Lock()
			// MERGED into the roster, not assigned over it. The relay adds a
			// joining client to the room before it sends that client's
			// Welcome, so another player joining in that window has its Join
			// forwarded to us first -- our very first message can be someone
			// else's Join, ahead of our own Welcome. Replacing the map here
			// (which this did until 2026-08-16) erased that player, and since
			// states from anyone outside the roster are dropped by design
			// (see the roster field's comment), we would never render them
			// again for the whole session: two people starting at the same
			// moment could simply never see each other. Found by a relay test
			// written for a different race, in the CI race job.
			//
			// Safe against a stale id outliving its connection because the
			// roster is now cleared explicitly on disconnect.
			if c.roster == nil {
				c.roster = make(map[string]struct{}, len(w.Roster))
			}
			for _, id := range w.Roster {
				if !c.admitToRosterLocked(id) {
					break
				}
			}
			// w.SendHz == 0 means "not advertised" (an older relay that
			// predates this field), a distinct case from "advertised badly" —
			// only clamp (defense-in-depth against a hostile relay talking
			// this Core into an absurd rate, same trust-boundary posture as
			// the roster cross-check and ValidateState on receive) when a
			// real value was actually sent. See effectiveSendInterval and the
			// ADR in agent_docs/architecture.md.
			if w.SendHz > 0 {
				c.serverSendInterval = time.Second / time.Duration(protocol.ClampSendHz(w.SendHz))
			}
			// Normalized on receive rather than trusted as sent, the same
			// defence-in-depth against a hostile relay as clamping SendHz
			// above — and here an unrecognized value normalizes to
			// "disabled", so a relay cannot talk this client into a physical
			// effect by sending garbage.
			c.relayGhostCollision = protocol.NormalizeGhostCollision(w.GhostCollision)
			c.relayPolicyKnown = true
			// The room's agreed set, normalized again on receive rather than
			// trusted as sent — same defence-in-depth against a hostile relay
			// as clamping SendHz above.
			c.activeFeatures = protocol.NormalizeFeatures(w.Features)
			c.resumed = w.Resumed
			hadToken := c.resumeToken != ""
			if w.ResumeToken != "" {
				c.resumeToken = w.ResumeToken
			}
			c.mu.Unlock()
			// A Welcome can land long after the adapter came up: a background
			// reconnect, or a resume into a relay configured differently from
			// the one this session started on. Re-push so the adapter follows
			// the room it is actually in now. No-ops when nothing changed.
			c.pushSessionPolicy()
			logResumeOutcome(w, hadToken)

			select {
			case welcome <- w:
			default:
			}

			// THE NAMETAGS OF EVERYONE ALREADY IN THE ROOM, AND THIS MUST HAPPEN AFTER THE SEND
			// ABOVE -- which is the opposite of what a plausible-sounding argument said.
			//
			// The argument was: the send completes the handshake, whose caller then pushes the
			// adapter everything already known, so storing names after it means that push reads an
			// empty map. It sounds airtight and it is wrong twice over. First, it was tested: with
			// the store deliberately left late, the delivery test passed 60 runs out of 60, so the
			// race it describes does not decide anything. Second, moving it EARLIER caused a real
			// regression -- storeRemoteName writes to the adapter's bridge socket, that write can
			// block, and blocking here delays the Welcome the handshake is waiting on. The
			// pre-existing FuzzSchedule caught it as "alice ... timed out waiting for welcome".
			//
			// So: nothing that can block belongs before the handshake completes. The adapter still
			// learns these names, from pushRemoteNames when it attaches -- which is a different
			// mechanism from this one and is what actually carries them (see remotenames.go).
			//
			// Outside the lock above deliberately: storeRemoteName takes c.mu itself.
			c.storeRosterNames(w.Nametags)
		}
	case protocol.TypeReject:
		var r protocol.Reject
		if err := json.Unmarshal(env.Payload, &r); err == nil {
			select {
			case reject <- r:
			default:
				// No handshake select is waiting on this channel — this is a
				// Reject arriving after the handshake (the relay closing an
				// already-joined connection, e.g. ReasonRateLimited). Without
				// logging it here the reason is lost entirely and the user
				// sees only a bare "relay disconnected" from OnDisconnect.
				c.mu.Lock()
				connected := c.playerID != ""
				c.mu.Unlock()
				if connected {
					log.Printf("core: relay closed this connection: %s", r.Reason)
				}
			}
		}
	case protocol.TypeJoin:
		var j protocol.Join
		if err := json.Unmarshal(env.Payload, &j); err == nil {
			c.mu.Lock()
			admitted := c.admitToRosterLocked(j.PlayerID)
			c.mu.Unlock()
			if !admitted {
				// Nothing else for this id either: the name and the seeded
				// state would outlive a roster entry that never existed.
				break
			}
			c.storeRemoteName(j.PlayerID, j.Nametag)
			if j.State != nil {
				c.storeRemoteState(*j.State)
			}
		}
	case protocol.TypeLeave:
		var l protocol.Leave
		if err := json.Unmarshal(env.Payload, &l); err == nil {
			c.mu.Lock()
			delete(c.roster, l.PlayerID)
			// Dropped with the roster entry, not left behind: player ids are
			// reused by a relay across a session, so a stale name here would
			// eventually be shown over somebody else's ghost.
			delete(c.remoteNames, l.PlayerID)
			c.mu.Unlock()
			c.dropRemote(l.PlayerID)
		}
	case protocol.TypeState:
		var st protocol.State
		if err := json.Unmarshal(env.Payload, &st); err == nil {
			c.storeRemoteState(st)
		}
	default:
		// The event/lease/escrow planes and Pong, which handleOnlineMessage
		// owns (core/online.go). Anything it does not recognise
		// either — a message type from a newer relay — is ignored, the same
		// forward-compatibility posture as unknown fields.
		c.handleOnlineMessage(env)
	}
}
