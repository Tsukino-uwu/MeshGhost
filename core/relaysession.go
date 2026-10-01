package core

// The core's relay connection: dialling it, losing it, and getting it back. Everything here runs on, or races with,
// the connection lifecycle, so the reconnect bookkeeping and refusal handling live beside the connect path.

import (
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// ConnectRelay dials RelayAddr, performs the hello and welcome handshake for gameID using this Core's connection
// fields, and handles the relay's messages from then on. It blocks until Welcome, Reject or timeout. The version
// advertised is GameVersion if set, otherwise what the adapter last reported, resolved per call.
func (c *Core) ConnectRelay(gameID string) error {
	addr, room, displayName, roomCode, timeout :=
		c.relayAddr(), c.room(), c.displayName(), c.roomCode(), c.DialTimeout

	gameVersion := c.GameVersion
	if gameVersion == "" {
		c.mu.Lock()
		gameVersion = c.adapterGameVersion
		c.mu.Unlock()
	}

	// The handshake always happens over tcp, whatever Transport says; resolveTransport then picks the session's.
	kind, dialAddr, tlsOpts, err := c.resolveTransport(addr, gameID, room, displayName, roomCode, gameVersion)
	if err != nil {
		return fmt.Errorf("core: dial relay: %w", err)
	}

	// transport.DefaultDialTimeout, not timeout: timeout bounds the wait for Welcome below.
	netConn, err := netx.DialWithTLS(kind, dialAddr, transport.DefaultDialTimeout, tlsOpts)
	if err != nil {
		// In auto mode a transport that cannot be dialled here stops being chosen after two failures in a row (see
		// Core.transportDialFailures); tcp always works, since the handshake used it. An explicit choice keeps failing.
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
	// The room-code proof (roomproof.go), nil with no code, prepared so the hello can carry its first message.
	proof, err := newRoomProof(roomCode, netConn)
	if err != nil {
		_ = netConn.Close()
		return fmt.Errorf("core: room code proof: %w", err)
	}
	// protocol.MaxLineBytes, the limit the relay itself applies, not transport's default; 0, 0 take transport's
	// default idle and write timeouts.
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
	c.mu.Lock()
	// The dial succeeded, so this transport's run of consecutive failures is over.
	delete(c.transportDialFailures, kind.String())
	// Taking the slot over forgets what was in it: a previous connection's identity left in place would make this
	// connection's Welcome look like an illegal second one (see forgetRelaySessionLocked).
	replaced := c.relay
	if replaced != nil && replaced != conn {
		c.forgetRelaySessionLocked()
	}
	c.relay = conn
	previousOut := c.relayOut
	c.relayOut = newRelayWriter(conn, func() { c.relayStuck(conn) })
	c.mu.Unlock()
	previousOut.close()
	if replaced != nil && replaced != conn {
		// Outside the lock: dropAllRemotes takes it, and Close can land its own callback.
		c.dropAllRemotes()
		_ = replaced.Close()
	}

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	// gone ends the wait for Welcome the moment the socket dies, so a relay that hangs up mid-handshake does not
	// leave a launching game's hello blocked for the whole timeout.
	gone := make(chan struct{})
	var goneOnce sync.Once
	conn.OnError(func(err error) { log.Printf("core: relay connection error: %v", err) })
	conn.OnDisconnect(func(err error) {
		log.Printf("core: relay disconnected: %v", err)
		goneOnce.Do(func() { close(gone) })
		// Dropping the remotes makes the next adapter frame despawn each one; nothing else would, since a buffer
		// holds its newest sample forever. The wasCurrent guard is load-bearing: this runs on readLoop's own
		// goroutine, after Close returns, possibly once a newer connection is live.
		wasCurrent, retry := c.clearRelaySession(conn)

		if wasCurrent {
			c.dropAllRemotes()
		}

		// Armed only by a ConnectRelayOnAdapterHello success, so a direct ConnectRelay never retries.
		if wasCurrent && retry.gameID != "" {
			go c.reconnectWithBackoff(retry.gameID, retry.adapterGameVersion, retry.bridgeConn)
		}
	})
	conn.OnReceive(func(payload []byte) {
		// A proof message is answered or refused here and never reaches the ordinary handler; a refusal arrives as a
		// local Reject, so the handshake fails the same way a relay's wrong-code refusal does.
		if proof.intercept(conn, payload, func(r protocol.Reject) {
			select {
			case reject <- r:
			default:
			}
		}) {
			return
		}
		c.handleRelayMessage(conn, payload, welcome, reject)
	})

	// The resume token goes on every attempt: the relay ignores one it does not recognise.
	c.mu.Lock()
	resumeToken := c.resumeToken
	// The inverse of the adapter's render_all_areas, so an adapter that takes over area visibility is never filtered
	// by the relay. With no adapter yet it is true and harmless: no state sent means no area on record.
	ownAreaOnly := !c.adapterRenderAllAreas
	c.mu.Unlock()

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
		NameColor:       c.nameColor(),
		PakeKE1:         proof.KE1(),
		GameVersion:     gameVersion,
		MaxReceiveHz:    c.maxReceiveHz(),
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
		// A Reject that already arrived beats the send error: a relay that refuses and closes fast enough closes
		// the socket under this send, and the reason sits unread in the channel. Only the read loop that delivered
		// it can close the socket here, so an unrelated write error is never mistaken for a refusal.
		select {
		case r := <-reject:
			_ = conn.Close()
			c.clearRelayIfCurrent(conn)
			return &RejectError{Reason: r.Reason, Code: r.Code, Retryable: r.Retryable}
		default:
		}
		_ = conn.Close()
		return fmt.Errorf("core: send hello: %w", err)
	}

	if timeout <= 0 {
		timeout = DefaultDialTimeout
	}

	if fn := beforeHandshakeSelectHook.Load(); fn != nil {
		(*fn)()
	}

	select {
	case w := <-welcome:
		// The client half of the version floor, reported as a permanent refusal naming both versions: retrying
		// changes neither build. A relay advertising 0 predates the field and fails the same comparison.
		if rej := c.refuseWelcomeVersion(w); rej != nil {
			_ = conn.Close()
			c.clearRelayIfCurrent(conn)
			return rej
		}
		c.mu.Lock()
		if c.relay != conn {
			// The connection died with its Welcome still in the channel and the teardown has run: applying it now
			// would resurrect a dead identity and make the next connection's Welcome an illegal second one.
			c.mu.Unlock()
			_ = conn.Close()
			return fmt.Errorf("core: the relay connection dropped before its welcome could be applied")
		}
		c.playerID = w.PlayerID
		c.relayGame = gameID
		c.mu.Unlock()
		if agreed := c.RoomFeatures(); len(agreed) > 0 {
			log.Printf("core: room %q negotiated capabilities %v", room, agreed)
		}
		go c.sendHeartbeats(conn)
		return nil
	case r := <-reject:
		_ = conn.Close()
		c.clearRelayIfCurrent(conn)
		return &RejectError{Reason: r.Reason, Code: r.Code, Retryable: r.Retryable}
	case <-gone:
		// A Reject that already arrived beats the drop: the relay rejects and closes at once, and a select with two
		// ready cases picks at random, which would report a permanent refusal as a transient drop.
		select {
		case r := <-reject:
			_ = conn.Close()
			c.clearRelayIfCurrent(conn)
			return &RejectError{Reason: r.Reason, Code: r.Code, Retryable: r.Retryable}
		default:
		}
		// An error, not a retry from here: both callers already back off and try again.
		_ = conn.Close()
		c.clearRelayIfCurrent(conn)
		return fmt.Errorf("core: the relay connection dropped before the welcome arrived")
	case <-time.After(timeout): // wall-clock: waiting on a relay over a socket
		_ = conn.Close()
		c.clearRelayIfCurrent(conn)
		return fmt.Errorf("core: timed out waiting for welcome from relay")
	}
}

// clearRelaySession forgets everything that belonged to one relay connection and reports whether conn was the live
// one, with what a redial needs. Clearing c.relay lets a later bridge hello redial instead of finding this Core
// connected forever. A method, not the OnDisconnect closure body, so a test can reach the stale-callback guard.
func (c *Core) clearRelaySession(conn transport.Transport) (bool, relayRetry) {
	c.mu.Lock()
	defer c.mu.Unlock()

	retry := relayRetry{c.autoRetryGameID, c.autoRetryAdapterGameVersion, c.autoRetryBridgeConn}
	if c.relay != conn {
		// A stale connection's late callback: touching anything would wipe the live session. What the old session
		// left behind was forgotten at the takeover instead.
		return false, retry
	}

	c.relay = nil
	// Closing rather than abandoning the writer drains what is queued (a clean leave) and ends its goroutine.
	c.relayOut.close()
	c.relayOut = nil
	c.forgetRelaySessionLocked()

	return true, retry
}

// forgetRelaySessionLocked drops everything that belonged to one relay connection except c.relay itself. It runs
// when an owned connection dies and when a new connection takes the slot over: a reconnect can finish before the
// dead connection's callback runs, and an old playerID left in place would make the new Welcome an illegal second
// one and the core silently deaf. The caller must hold c.mu.
func (c *Core) forgetRelaySessionLocked() {
	c.playerID = ""
	c.welcomed = false
	c.relayGame = ""
	c.relayOwner = nil
	c.serverSendInterval = 0
	c.relayGhostCollision = ""
	c.relayPolicyKnown = false
	// The resume token deliberately survives: this is the drop it exists for.
	c.activeFeatures = nil
	c.resumed = false
	c.clock = clockSync{}
	// c.lastNowMs is deliberately kept: clearing it lets the clock step back by the dropped offset, which unsorts every
	// buffer and despawns the chaser pack. Holding still until real time catches up is the lesser cost.
	c.pendingPings = nil
	// player_ids mean something only within the connection that assigned them, and Welcome merges rather than
	// replaces, so the reset is explicit or a stale id would pass the trust check on the next connection.
	c.roster = make(map[string]int64)
	// The roster's shadow maps go with it, or what accumulates is pushed to the next adapter one remote_name each.
	// agedOut never holds a local id, so it clears wholesale.
	c.agedOut = nil
	// remoteNames also holds the player's own chaser and replay tags, whose ghosts outlive a relay drop. Asked by id,
	// never c.localPeers: membership is dropped and re-admitted at every seam, and a reconnect can land inside one.
	for id := range c.remoteNames {
		if !isLocalPeerID(id) {
			delete(c.remoteNames, id)
		}
	}
}

// clearRelayIfCurrent drops a connection whose handshake failed. OnDisconnect runs later on the read goroutine, and
// until it does a retry would find c.relay set with no game and report "already connected" instead of the refusal.
// Guarded on c.relay == conn so a late call never clears a newer connection.
func (c *Core) clearRelayIfCurrent(conn transport.Transport) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.relay == conn {
		c.relay = nil
		c.relayOut.close()
		c.relayOut = nil
	}
}

// ConnectRelayOnAdapterHello connects to the relay the first time an adapter declares its game, so the caller need
// not know it at startup. The connection fields must be set before any bridge hello. adapterGameVersion is what the
// adapter reported; GameVersion overrides it. bridgeConn (nil on the eager -game path) becomes relayOwner. Already
// connected for the same game, it only hands ownership and auto-retry to bridgeConn; for a different game it is an
// AlreadyServingError, since the earlier hello committed this Core to that game.
func (c *Core) ConnectRelayOnAdapterHello(gameID, adapterGameVersion string, bridgeConn transport.Transport) error {
	// Offline is enforced here, the one funnel both ways into a dial pass through; nil, since nothing failed.
	if c.offline() {
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
			// A relaunched game: ownership follows the current adapter, or the departing connection's disconnect
			// tears down the session its replacement was just handed. Auto-retry is re-armed at the live connection
			// so a session already dying as it transfers still reconnects.
			if bridgeConn != nil {
				runBeforeArmingAutoRetryHook()
				c.mu.Lock()
				c.relayOwner = bridgeConn
				c.autoRetryGameID = gameID
				c.autoRetryAdapterGameVersion = adapterGameVersion
				c.autoRetryBridgeConn = bridgeConn
				// The session can die between the decision and this arming, with the teardown finding nothing armed;
				// nothing would ever redial it, so this does.
				lost := c.relay == nil
				c.mu.Unlock()
				if lost {
					log.Printf("core: the relay session died as ownership passed to the new adapter — reconnecting in the background")
					go c.reconnectWithBackoff(gameID, adapterGameVersion, bridgeConn)
				}
			}
			return nil
		}
		// Not a plain error: bridgeserve.go refuses a hello only when IsPermanentRejectErr says the failure is final.
		return &AlreadyServingError{Connected: connectedGame, Requested: gameID}
	}

	c.mu.Lock()
	cachedGame, cachedReason := c.permanentRejectGame, c.permanentRejectReason
	cachedCode, cachedAt := c.permanentRejectCode, c.permanentRejectAt
	c.mu.Unlock()
	roomCodeDue := cachedCode == protocol.CodeInvalidRoomCode &&
		time.Since(cachedAt) >= RoomCodeRetryInterval // wall-clock: paces a real retry, like the backoff sleeps
	if cachedGame == gameID && cachedReason != "" && !roomCodeDue {
		// Logged once already; only a config edit and restart changes it.
		return &RejectError{Reason: cachedReason, Code: cachedCode}
	}

	// Its own field, never GameVersion, the player's override: see Core.adapterGameVersion.
	c.mu.Lock()
	c.adapterGameVersion = adapterGameVersion
	c.mu.Unlock()
	err := c.ConnectRelay(gameID)
	if err != nil {
		rej, isReject := asReject(err)
		reason := ""
		permanent := false
		if isReject {
			reason = rej.Reason
			permanent = isPermanentReject(rej.Reason, rej.Code, rej.Retryable)
		}

		now := time.Now() // wall-clock: throttles a log line for a human

		c.mu.Lock()
		changed := c.lastConnectErr != err.Error()
		c.lastConnectErr = err.Error()
		if changed || c.connectFailingSince.IsZero() {
			c.connectFailingSince = now
		}
		stillFailing := !permanent && !changed &&
			!c.lastConnectErrLoggedAt.IsZero() &&
			now.Sub(c.lastConnectErrLoggedAt) >= getReconnectLogInterval()
		if changed || stillFailing {
			c.lastConnectErrLoggedAt = now
		}
		failingFor := now.Sub(c.connectFailingSince)
		relayAddr := c.relayAddr()
		if permanent {
			c.permanentRejectGame = gameID
			c.permanentRejectReason = reason
			c.permanentRejectCode = ""
			if isReject {
				c.permanentRejectCode = rej.Code
			}
			c.permanentRejectAt = now
		}
		c.mu.Unlock()

		switch {
		case changed:
			// No "core: " prefix: every error ConnectRelay returns already carries it.
			if permanent && IsRoomCodeRefusalErr(err) {
				log.Printf("%v — trying again once a minute, in case the server was not the real one or its code "+
					"changes; if your room_code is wrong, fix it and restart", err)
			} else if permanent {
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
	c.permanentRejectCode = ""
	c.permanentRejectAt = time.Time{}
	c.autoRetryGameID = gameID
	c.autoRetryAdapterGameVersion = adapterGameVersion
	c.autoRetryBridgeConn = bridgeConn
	// A drop between ConnectRelay returning and this arming found nothing armed and started nothing. Read under the
	// lock clearRelaySession takes, so exactly one of the two starts the retry loop.
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

// beforeArmingAutoRetryHook is a test seam that runs just before ConnectRelayOnAdapterHello arms auto-retry, so a
// test can drop the relay inside that window. Atomic although only tests set it: reconnect goroutines outlive the
// test that cleared it.
var beforeArmingAutoRetryHook atomic.Pointer[func()]

// beforeHandshakeSelectHook is a test seam that runs just before ConnectRelay's handshake select, so a test can make
// a Reject and the drop both ready at once. Atomic for the same reason.
var beforeHandshakeSelectHook atomic.Pointer[func()]

func runBeforeArmingAutoRetryHook() {
	if fn := beforeArmingAutoRetryHook.Load(); fn != nil {
		(*fn)()
	}
}

// reconnectWithBackoff calls ConnectRelayOnAdapterHello until it succeeds or is permanently refused, so a relay
// restart after a successful connect does not leave this Core disconnected. A library never exits the host: on a
// permanent refusal it logs and stops.
func (c *Core) reconnectWithBackoff(gameID, adapterGameVersion string, bridgeConn transport.Transport) {
	initial, backoffMax := c.reconnectBackoffBounds()
	backoff, holdFirst := c.resumeReconnectBackoff(initial, backoffMax)
	for {
		// Stop if the game is gone, or a loop asleep in the backoff when the player quits would rejoin with no game
		// and hold a seat forever. Closed, not "attached": the ownership-transfer path starts this loop for a
		// connection that is not attached yet.
		if transportIsClosed(bridgeConn) {
			return
		}
		// Wait before the first dial too when the previous session achieved nothing; looping, so the check above
		// still runs after the wait.
		if holdFirst {
			holdFirst = false
			log.Printf("core: the last relay session ended almost as soon as it started -- "+
				"waiting %s before trying again", backoff)
			time.Sleep(backoff) // wall-clock: paces real reconnect attempts
			backoff = c.escalateReconnectBackoff(backoff, backoffMax)
			continue
		}
		err := c.ConnectRelayOnAdapterHello(gameID, adapterGameVersion, bridgeConn)
		if err == nil {
			return
		}
		if IsRoomCodeRefusalErr(err) {
			time.Sleep(RoomCodeRetryInterval) // wall-clock: paces real reconnect attempts
			continue
		}
		if IsPermanentRejectErr(err) {
			log.Printf("core: %v — giving up on automatic reconnect for game %q", err, gameID)
			return
		}
		time.Sleep(backoff) // wall-clock: paces real reconnect attempts
		backoff = c.escalateReconnectBackoff(backoff, backoffMax)
	}
}

// resumeReconnectBackoff decides what a starting reconnect loop waits from what the previous session managed;
// holdFirst means wait before the first dial. The threshold is the backoff itself: a session that outlived the wait
// is progress, so a relay restart resets and a flaky link settles where its uptime matches its backoff, instead of
// escalating past DefaultResumeGrace.
func (c *Core) resumeReconnectBackoff(initial, max time.Duration) (backoff time.Duration, holdFirst bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	upAt := c.relaySessionUpAt
	c.relaySessionUpAt = time.Time{} // one verdict per session
	held := c.reconnectBackoff
	if held < initial {
		held = initial
	}
	// No session to judge: the loop's own failure path owns the cadence.
	if upAt.IsZero() {
		c.reconnectBackoff = initial
		return initial, false
	}
	if c.clk().Since(upAt) >= held {
		c.reconnectBackoff = initial
		return initial, false
	}
	c.reconnectBackoff = held
	return held, true
}

// escalateReconnectBackoff doubles within max and remembers the result, so the escalation survives the loop
// returning on a dial that succeeds however briefly.
func (c *Core) escalateReconnectBackoff(cur, max time.Duration) time.Duration {
	next := nextBackoffWithin(cur, max)
	c.mu.Lock()
	c.reconnectBackoff = next
	c.mu.Unlock()
	return next
}

// retryRelayForSoloAdapter keeps trying the relay for an adapter accepted while the relay was down. Unlike
// reconnectWithBackoff it stops unless nd is still the attached adapter: a relaunched game brings its own hello and
// attempt, and redialling for the old connection would hand relayOwner one that is gone.
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
		if IsRoomCodeRefusalErr(err) {
			time.Sleep(RoomCodeRetryInterval) // wall-clock: paces real reconnect attempts (RoomCodeRetryInterval)
			continue
		}
		if IsPermanentRejectErr(err) {
			log.Printf("core: %v -- staying solo for this session; recording, replays and chasers still work", err)
			return
		}
		time.Sleep(backoff) // wall-clock: paces real reconnect attempts
		backoff = nextBackoffWithin(backoff, backoffMax)
	}
}

// PlayerID returns the id assigned by the relay at Welcome. Empty until ConnectRelay succeeds.
func (c *Core) PlayerID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.playerID
}

// handleRelayMessage handles one line from the relay. A message from a connection this Core has already replaced is
// discarded: callbacks land late on the connection's own goroutine, and a dead session's Welcome would overwrite the
// live identity. A nil conn skips the check, for tests.
func (c *Core) handleRelayMessage(conn transport.Transport, payload []byte, welcome chan<- protocol.Welcome, reject chan<- protocol.Reject) {
	if conn != nil {
		c.mu.Lock()
		stale := c.relay != conn
		c.mu.Unlock()
		if stale {
			return
		}
	}
	// Counted before parsing: a malformed line was paid for on the wire too.
	atomic.AddUint64(&c.stats.messagesReceived, 1)
	atomic.AddUint64(&c.stats.bytesReceived, uint64(len(payload)))

	var env protocol.Envelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return
	}

	switch env.Type {
	case protocol.TypeWelcome:
		c.mu.Lock()
		// A flag of our own, not "is playerID set": the relay chooses playerID.
		alreadyWelcomed := c.welcomed
		c.mu.Unlock()
		if alreadyWelcomed {
			// A second Welcome is protocol-illegal, and reprocessing it would let a relay reset the roster mid-session.
			log.Printf("core: received a second Welcome from the relay after already connected — ignoring")
			return
		}
		var w protocol.Welcome
		if err := json.Unmarshal(env.Payload, &w); err == nil {
			// The id that names us gets the same shape check as our peers': empty, unbounded or local-shaped is
			// refused, and the Welcome dropped rather than repaired, since only the relay can assign an id.
			if !acceptableRelayPeerID(w.PlayerID) {
				log.Printf("core: the relay's welcome named this client with an unusable player_id -- refusing the session")
				return
			}
			c.mu.Lock()
			c.welcomed = true
			c.relaySessionUpAt = c.clk().Now()
			// Merged, not replaced: the relay adds a joiner to the room before sending its Welcome, so another
			// player's Join can arrive first, and replacing the map would lose them for the session.
			if c.roster == nil {
				c.roster = make(map[string]int64, len(w.Roster))
			}
			for _, id := range w.Roster {
				// continue, not break: one unusable id is no reason to refuse the real peers after it.
				if !acceptableRelayPeerID(id) {
					continue
				}
				if !c.admitToRosterLocked(id) {
					break
				}
			}
			// Zero means an older relay advertised nothing; a real value is clamped against a hostile relay.
			if w.SendHz > 0 {
				c.serverSendInterval = time.Second / time.Duration(protocol.ClampSendHz(w.SendHz))
			}
			// Normalized, not trusted: an unrecognized value becomes "disabled", so garbage cannot cause a physical
			// effect.
			c.relayGhostCollision = protocol.NormalizeGhostCollision(w.GhostCollision)
			c.relayPolicyKnown = true
			c.activeFeatures = protocol.NormalizeFeatures(w.Features)
			c.resumed = w.Resumed
			hadToken := c.resumeToken != ""
			if w.ResumeToken != "" {
				c.resumeToken = w.ResumeToken
			}
			c.mu.Unlock()
			// A Welcome can land long after the adapter came up (a background reconnect, a resume into a relay
			// configured differently), so the adapter follows the room it is in now.
			c.pushSessionPolicy()
			logResumeOutcome(w, hadToken)

			select {
			case welcome <- w:
			default:
			}

			// After the send, never before: storing a name can block on the bridge and would delay the Welcome the
			// handshake waits on. The adapter gets these names from pushRemoteNames when it attaches. Outside the
			// lock: storeRemoteName takes c.mu.
			c.storeRosterNames(w.Nametags)
		}
	case protocol.TypeReject:
		var r protocol.Reject
		if err := json.Unmarshal(env.Payload, &r); err == nil {
			// The handshake's state decides which Reject this is: once joined, nothing reads the channel again, so a
			// mid-session refusal must be logged here. playerID is set only by our own Welcome and cleared with the
			// session.
			c.mu.Lock()
			joined := c.playerID != ""
			c.mu.Unlock()
			if joined {
				log.Printf("core: relay closed this connection: %s (code %q)", r.Reason, r.Code)
				break
			}
			select {
			case reject <- r:
			default:
				log.Printf("core: relay refused this connection again before it was read: %s (code %q)",
					r.Reason, r.Code)
			}
		}
	case protocol.TypeJoin:
		var j protocol.Join
		if err := json.Unmarshal(env.Payload, &j); err == nil {
			if !acceptableRelayPeerID(j.PlayerID) {
				break
			}
			c.mu.Lock()
			admitted := c.admitToRosterLocked(j.PlayerID)
			c.mu.Unlock()
			if !admitted {
				// No name or seed either: both would outlive a roster entry that never existed.
				break
			}
			c.storeRemoteName(j.PlayerID, j.Nametag)
			if j.State != nil {
				// The seed is that player's by definition, so its id comes from the Join: otherwise the seed would be
				// an ungated door into storeRemoteState.
				seed := *j.State
				seed.PlayerID = j.PlayerID
				c.storeRemoteState(seed)
			}
		}
	case protocol.TypeLeave:
		var l protocol.Leave
		if err := json.Unmarshal(env.Payload, &l); err == nil {
			// The same gate as Join and State: a leave for a local id would despawn the player's own chaser or replay.
			if !acceptableRelayPeerID(l.PlayerID) {
				break
			}
			c.mu.Lock()
			delete(c.roster, l.PlayerID)
			// A relay may reuse an id, and a stale name would then end up over somebody else's ghost.
			delete(c.remoteNames, l.PlayerID)
			// Whoever gets the id next arrives with a Join, not as a returning peer.
			delete(c.agedOut, l.PlayerID)
			c.mu.Unlock()
			c.dropRemote(l.PlayerID)
		}
	case protocol.TypeState:
		var st protocol.State
		if err := json.Unmarshal(env.Payload, &st); err == nil {
			if !acceptableRelayPeerID(st.PlayerID) {
				break
			}
			c.storeRemoteState(st)
		}
	default:
		// The opt-in planes and Pong (online.go); a type from a newer relay is ignored there.
		c.handleOnlineMessage(env)
	}
}

// refuseWelcomeVersion applies both protocol floors to a relay's Welcome and returns the refusal, or nil. The
// build's own floor runs first and unconditionally, so an adapter can only tighten it.
func (c *Core) refuseWelcomeVersion(w protocol.Welcome) *RejectError {
	// A relay advertising 0 predates the field and fails the same comparison.
	if !protocol.AcceptsPeerVersion(w.ProtocolVersion) {
		return &RejectError{
			Reason: fmt.Sprintf("this relay speaks protocol version %d, but this build needs %d or newer "+
				"-- update the relay (or run an older client against it)",
				w.ProtocolVersion, protocol.MinProtocolVersion),
			Code:      protocol.CodeProtocolVersionMismatch,
			Retryable: false,
		}
	}
	// The adapter's own floor: it may depend on a field an older relay never forwards (bridge.Hello's
	// MinProtocolVersion). Zero passes.
	c.mu.Lock()
	floor := c.adapterMinProtocol
	c.mu.Unlock()
	if floor > 0 && w.ProtocolVersion < floor {
		return &RejectError{
			Reason: fmt.Sprintf("this relay speaks protocol version %d, but the attached game's "+
				"adapter requires %d or newer -- update the relay, or run a build of the mod "+
				"that matches it",
				w.ProtocolVersion, floor),
			Code:      protocol.CodeProtocolVersionMismatch,
			Retryable: false,
		}
	}
	return nil
}
