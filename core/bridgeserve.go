package core

// The core's side of the bridge, the loopback channel to an adapter: the other protocol. An adapter speaks only this,
// never the relay protocol, and a core serves one adapter at a time.

import (
	"encoding/json"
	"errors"
	"log"
	"net"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// ServeBridge accepts adapter connections on ln, each on its own goroutine, until Accept returns an error (typically
// because ln was closed).
func (c *Core) ServeBridge(ln net.Listener) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go c.handleBridgeConn(conn)
	}
}

func (c *Core) handleBridgeConn(netConn net.Conn) {
	nd := transport.FromConnWithLimits(netConn, transport.DefaultMaxLineBytes, transport.DefaultIdleTimeout, c.bridgeWriteTimeout)
	rendered := make(map[string]bool)

	nd.OnError(func(err error) { log.Printf("core: bridge connection error: %v", err) })
	nd.OnDisconnect(func(err error) { c.bridgeConnGone(nd) })
	// spoke and warnedNoHello need no lock: transport delivers OnReceive serially, on one goroutine.
	spoke := false
	warnedNoHello := false
	nd.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			// A first line that is not NDJSON is not an adapter, and is hung up on: otherwise a browser page could
			// POST to this port and have its chosen body parsed once the skipped header lines pass. Only the first
			// line, since a later bad line is one bad frame from an adapter that has proved itself.
			if !spoke {
				log.Printf("core: a bridge connection opened with a line that is not NDJSON -- closing it " +
					"(this port speaks one protocol, and something else is talking to it)")
				_ = nd.Close()
			}
			return
		}
		spoke = true
		// Admission applies to every message, and a hello is mandatory: the bridge is unauthenticated loopback, so
		// any local process could otherwise speak as the player or read every peer's stream. A hostile process can
		// still send its own hello, but then it claims the slot and the real game's hello is visibly refused as busy.
		if env.Type != bridge.TypeHello {
			c.mu.Lock()
			attached := c.attachedAdapter
			c.mu.Unlock()
			if attached != nd {
				// Another holder is usually a second copy of the game, already told "busy": no line per frame. No
				// holder means this connection never sent a hello, worth saying once.
				if attached == nil && !warnedNoHello {
					warnedNoHello = true
					log.Printf("core: ignoring %s from a bridge connection that never sent a hello -- "+
						"an adapter must introduce itself before the core will act for it", env.Type)
				}
				return
			}
		}

		switch env.Type {
		case bridge.TypeHello:
			var h bridge.Hello
			if err := json.Unmarshal(env.Payload, &h); err != nil {
				return
			}

			// A dead incumbent is not a busy one: a failed write closes the socket and the game sees it at once, so
			// its fresh hello can arrive before the Core has noticed. Run the old connection's cleanup and admit.
			c.mu.Lock()
			incumbent := c.attachedAdapter
			c.mu.Unlock()
			if incumbent != nil && incumbent != nd && transportIsClosed(incumbent) {
				log.Printf("core: the attached adapter's socket is closed -- releasing it for this hello instead of answering busy")
				c.bridgeConnGone(incumbent)
			}

			// Admission before the relay is touched, answered with a reason so a refused adapter knows to try the
			// next port rather than guess at a silent hangup.
			c.mu.Lock()
			busy := c.attachedAdapter != nil && c.attachedAdapter != nd
			if !busy {
				c.attachedAdapter = nd
				c.adapterReady = false
				// A new adapter has been told nothing, so even an unchanged policy is pushed again.
				c.sentGhostCollision = ""
			}
			c.mu.Unlock()
			if busy {
				rejectBridge(nd, "busy: this core already has a game attached", bridge.CodeBusy, false)
				return
			}

			// Recorded before the connect: the relay hello carries the union of the adapter's features and c.Features.
			// The area, orientation and input flags change under the lock remoteStatesAt takes, atomic with the attach.
			c.mu.Lock()
			c.adapterFeatures = protocol.NormalizeFeatures(h.Features)
			c.adapterGameID = h.GameID
			c.adapterRenderAllAreas = h.RenderAllAreas
			c.adapterWantsOrientBracket = h.InterpolateOrientation
			c.adapterWantsInputTracks = h.InputTracks
			c.adapterMinProtocol = h.MinProtocolVersion
			c.mu.Unlock()

			// Logged from what the core parsed, not what the adapter thinks it sent: no line here means no bracket,
			// no input tracks, or no floor enforced, whatever the adapter's own log says.
			if h.InterpolateOrientation {
				log.Printf("core: adapter asked for interpolated orientation -- render_remote will carry the bracket")
			}
			if h.InputTracks {
				log.Printf("core: adapter asked for input tracks -- a replay whose clip has one will stream remote_input")
			}
			if h.MinProtocolVersion > 0 {
				log.Printf("core: adapter requires relay protocol version %d or newer "+
					"(this build's own floor is %d) -- a relay below it will be refused",
					h.MinProtocolVersion, protocol.MinProtocolVersion)
			}

			if err := c.ConnectRelayOnAdapterHello(h.GameID, h.GameVersion, nd); err != nil {
				// An unreachable relay is no reason to refuse the game: recording, replays and chasers work alone, so
				// the adapter is accepted and the relay tried in the background. A permanent refusal still rejects,
				// since the player must be told.
				if IsPermanentRejectErr(err) {
					// Release the slot: this connection never became the adapter.
					c.mu.Lock()
					if c.attachedAdapter == nd {
						c.attachedAdapter = nil
						c.adapterReady = false
					}
					c.mu.Unlock()
					// The relay's own code passes straight through, so an adapter sees one namespace; a local
					// AlreadyServingError has none and gets the bridge's.
					code, retryable := bridge.CodeAlreadyServing, false
					if rej, ok := asReject(err); ok && rej.Code != "" {
						code, retryable = rej.Code, rej.Retryable
					}
					rejectBridge(nd, err.Error(), code, retryable)
					return
				}
				if !c.offline() {
					log.Printf("core: playing alone -- no relay reached yet (%v). The game is "+
						"attached and recording, replays and chasers all work; nobody else will "+
						"appear until a relay answers, and one is still being tried for.", err)
					go c.retryRelayForSoloAdapter(h.GameID, h.GameVersion, nd)
				}
			}
			_ = c.sendToAdapter(nd, bridge.TypeBridgeReady, bridge.BridgeReady{})
			c.mu.Lock()
			c.adapterReady = true
			c.mu.Unlock()
			c.armRing()
			// The input ring is always on from attach, so save-last needs nothing armed in advance; reset first, since
			// a new adapter's bits and frame counter are its own.
			c.inputMeta.reset()
			c.armInputRing()
			// record_on_launch arms at attach; the file appears at the first in-game sample, so the main menu is never
			// in it.
			if c.recordOnLaunch() {
				if _, err := c.StartRecording(); err != nil {
					log.Printf("core: record_on_launch: %v", err)
				}
			}
			c.StartReplays()
			c.StartChasers()
			// After bridge_ready, never before: an adapter keys off it to start.
			c.pushSessionPolicy()
			// An adapter can attach while a recording is already running.
			c.pushRecordingState()
			// The relay's hello could not have known this adapter's area preference: a -game core connects before
			// the game launches.
			c.pushAreaPreference()
			// The Joins that carried these names may have passed long before this game launched.
			c.pushRemoteNames(nd)
		case bridge.TypeLocalState:
			var msg bridge.LocalState
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.onAdapterFrame(msg, nd, rendered)
		case bridge.TypeReplayControl:
			var msg bridge.ReplayControl
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			// Logged either way: the adapter gets no reply, so this is where a player sees the key did something.
			what, err := c.ReplayControl(ReplayAction(msg.Action), msg.Seconds)
			if err != nil {
				log.Printf("core: replay_control %q from the adapter: %v", msg.Action, err)
			} else {
				log.Printf("core: replay_control %q from the adapter: %s", msg.Action, what)
			}
		case bridge.TypePlayerFrozen:
			var msg bridge.PlayerFrozen
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.SetPlayerFrozen(msg.Frozen)
		case bridge.TypeChaserReset:
			// Logged either way, like replay_control.
			if n, ok := c.ResetChasers(); ok {
				log.Printf("core: chaser_reset from the adapter: the pack starts over (%d ghost(s))", n)
			} else {
				log.Printf("core: chaser_reset from the adapter: ignored (no pack running, or one just started over)")
			}
		case bridge.TypeInputSample:
			var msg bridge.InputSample
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			// Validated at the boundary so a malformed batch is named once; dropped, never a disconnect.
			if !bridge.ValidateInputSample(msg) {
				c.logInputReject(bridge.InputSampleRejectReason(msg))
				return
			}
			c.recordInput(msg)
		case bridge.TypeEvent:
			var msg bridge.Event
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.reportBridgeSendErr(nd, bridge.TypeEvent, c.SendEvent(msg.Event))
		case bridge.TypeLease:
			var msg bridge.Lease
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.reportBridgeSendErr(nd, bridge.TypeLease, c.sendLease(msg.Lease))
		case bridge.TypeEscrow:
			var msg bridge.Escrow
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.reportBridgeSendErr(nd, bridge.TypeEscrow, c.SendEscrow(msg.Escrow))
		case bridge.TypeWorld:
			var msg bridge.World
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.reportBridgeSendErr(nd, bridge.TypeWorld, c.sendWorld(msg.World))
		}
	})
}

// bridgeConnGone is the whole of what a bridge connection's end means to the Core, called when the read loop ends
// and the moment a write to the adapter fails. Its two halves must not be merged: releaseAdapterSlot takes only c.mu
// and can run anywhere, while finishBridgeTeardown takes the recorder's and the pack's locks and must never run on a
// stack that may hold one. Both are idempotent and act only while nd is still the connection they would act on.
func (c *Core) bridgeConnGone(nd transport.Transport) {
	wasAdapter, owns, relay := c.releaseAdapterSlot(nd)
	c.dropWriter(nd)
	c.finishBridgeTeardown(nd, wasAdapter, owns, relay)
}

// releaseAdapterSlot clears what a gone bridge connection owns under c.mu, takes no other lock and calls nothing, so
// it is safe from any goroutine. It reports what the connection was, for finishBridgeTeardown.
func (c *Core) releaseAdapterSlot(nd transport.Transport) (wasAdapter, ownsRelay bool, relay transport.Transport) {
	c.mu.Lock()
	defer c.mu.Unlock()
	relay = c.relay
	ownsRelay = c.relayOwner == nd
	wasAdapter = c.attachedAdapter == nd
	// Freed whether or not this connection owned the relay, so a relaunched game reuses this Core.
	if wasAdapter {
		c.attachedAdapter = nil
		c.adapterReady = false
		c.adapterRenderAllAreas = false
		c.adapterWantsOrientBracket = false
		c.adapterWantsInputTracks = false
	}
	// The game going away is not a relay drop, so auto-retry is disarmed. Not on ownsRelay alone: a relay outage
	// clears relayOwner, and a player quitting inside it would leave a reconnect loop holding a seat with no game.
	if ownsRelay || c.autoRetryBridgeConn == nd {
		c.autoRetryGameID = ""
		c.autoRetryAdapterGameVersion = ""
		c.autoRetryBridgeConn = nil
		c.resumeToken = ""
	}
	return wasAdapter, ownsRelay, relay
}

// finishBridgeTeardown stops what the gone adapter had running. It takes locks other than c.mu, so a caller that may
// hold one runs it on its own goroutine, possibly late: a relaunched game can attach, and even inherit this relay
// connection, in between. So it re-reads ownership and looks for a successor in one c.mu section before acting.
func (c *Core) finishBridgeTeardown(nd transport.Transport, wasAdapter, ownsRelay bool, relay transport.Transport) {
	c.mu.Lock()
	successor := c.attachedAdapter != nil && c.attachedAdapter != nd
	// A nil relayOwner means the relay dropped and the session was forgotten, not that a successor claimed it.
	stillOurs := ownsRelay && relay != nil && c.relay == relay &&
		(c.relayOwner == nd || c.relayOwner == nil)
	c.mu.Unlock()

	if stillOurs {
		// A real disconnect the relay broadcasts as a Leave, so this ghost disappears for everyone else.
		sendGoodbye(relay)
		_ = relay.Close()
	}
	if !wasAdapter || successor {
		return
	}
	c.StopReplays()
	c.StopChasers()
	if _, _, err := c.StopRecording(); err != nil {
		log.Printf("core: closing the recording on adapter disconnect: %v", err)
	}
	// StopRecording closes the input track it started; this covers a track armed on its own.
	if _, _, err := c.StopInputRecording(); err != nil {
		log.Printf("core: closing the input track on adapter disconnect: %v", err)
	}
	c.SetInputRingSpan(0)
	// The state ring too: armed with no adapter it keeps the last session for the life of the process, and any
	// bridge connection's frames would feed it. armRing restores it at the next attach.
	c.SetRingSpan(0)
}

// onAdapterFrame is the one entry point a wire-speaking adapter drives, per frame: it forwards the adapter's local
// state to the relay (if any), then answers on the same call with a render or despawn for every remote.
func (c *Core) onAdapterFrame(msg bridge.LocalState, nd transport.Transport, rendered map[string]bool) {
	c.mu.Lock()
	if c.relay != nil && c.relayOwner == nil {
		// The eager -game path connects before any bridge connection exists, so the first one to drive a frame
		// claims the relay and its disconnect still despawns this player for peers.
		c.relayOwner = nd
	}
	c.mu.Unlock()

	c.forwardLocalState(msg.State)
	// A dead socket ends the connection here: the read loop that would notice is this goroutine, and the game has
	// already seen the close and may be reconnecting. The first errBridgeGone stops the tick and frees the slot now.
	// A marshal failure is a defect in this process, not the socket: that one message is dropped and the session kept.
	var goneErr error
	marshalBugs := 0
	note := func(err error) {
		switch {
		case err == nil:
		case errors.Is(err, errBridgeMarshal):
			marshalBugs++
		case goneErr == nil:
			goneErr = err
		}
	}
	c.tickRenders(rendered,
		func(id string, st protocol.State, br orientBracket) {
			if goneErr == nil {
				note(c.sendRenderRemote(nd, id, st, br))
			}
		},
		func(id string) {
			if goneErr == nil {
				note(c.sendDespawnRemote(nd, id))
			}
		},
	)
	if marshalBugs > 0 {
		// Once per process: the trigger repeats every tick while the peer keeps sending the value.
		logBridgeBugOnce("adapter-frame-marshal",
			"core: BUG: %d message(s) in this adapter frame could not be marshalled -- dropped them and KEPT the session, "+
				"because a payload this process built is a defect here, not a dead socket (repeats are silent)", marshalBugs)
	}
	if goneErr != nil {
		log.Printf("core: the adapter's socket is dead (%v) -- detaching now so a reconnect is accepted", goneErr)
		c.bridgeConnGone(nd)
	}
}

// RunAdapter drives Core in-process against adapter, calling its methods directly with no bridge socket, every
// tickInterval until stop is closed. It proves the core needs nothing but the Adapter interface.
func (c *Core) RunAdapter(adapter Adapter, tickInterval time.Duration, stop <-chan struct{}) {
	rendered := make(map[string]bool)
	ticker := time.NewTicker(tickInterval) // wall-clock: RunAdapter polls a game for frames
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			c.onAdapterFrameInProcess(adapter, rendered)
		}
	}
}

func (c *Core) onAdapterFrameInProcess(adapter Adapter, rendered map[string]bool) {
	if state, ok := adapter.GetLocalState(); ok {
		c.forwardLocalState(&state)
	}
	// The in-process path drops the orientation bracket: nothing implementing Adapter draws anything.
	c.tickRenders(rendered,
		func(id string, st protocol.State, _ orientBracket) { adapter.RenderRemote(id, st) },
		adapter.DespawnRemote,
	)
}

// sendRenderRemote takes cosmetic from the id, never from c.localPeers membership: a seam drops and re-admits a local
// peer, and a tick inside it would tell the adapter a replay ghost is solid for that frame.
func (c *Core) sendRenderRemote(nd transport.Transport, playerID string, st protocol.State, br orientBracket) error {
	msg := bridge.RenderRemote{PlayerID: playerID, State: st, Cosmetic: isLocalPeerID(playerID)}
	if br.Have {
		msg.OrientationFrom, msg.OrientationTo, msg.InterpT = br.From, br.To, br.T
	}
	return c.sendToAdapter(nd, bridge.TypeRenderRemote, msg)
}

func (c *Core) sendDespawnRemote(nd transport.Transport, playerID string) error {
	return c.sendToAdapter(nd, bridge.TypeDespawnRemote, bridge.DespawnRemote{PlayerID: playerID})
}

// rejectBridge tells an adapter why it cannot have this Core, then closes the connection so it can look elsewhere.
// The synchronous send before Close is what keeps the reason from racing the hangup.
func rejectBridge(nd transport.Transport, reason, code string, retryable bool) {
	log.Printf("core: refused an adapter: %s", reason)
	// Not sendToAdapter: this connection never became the adapter, so there is no session to tear down.
	_ = sendBridgeEnvelope(nd, bridge.TypeReject, bridge.Reject{
		Reason: reason, Code: code, Retryable: retryable,
	})
	_ = nd.Close()
}

// pushSessionPolicy resolves the room policy against this Core's own preference and sends it to the attached adapter
// when it changed, so the Welcome handler can call it unconditionally. The send is outside mu: a wedged adapter
// socket must not stall every relay message.
func (c *Core) pushSessionPolicy() {
	// Offline is a known policy, not an unanswered one: there is no room, so the player's own setting is the whole
	// answer, and chaser_contact, a solo feature, rides this message. Read outside the lock: offline() takes its own.
	offline := c.offline()

	c.mu.Lock()
	effective := protocol.ResolveGhostCollision(c.relayGhostCollision, c.GhostCollision)
	// Absent when contact is off or there is no pack for it to apply to.
	contact := ""
	if c.ChaserEnabled && c.ChaserContact.Active() {
		contact = string(c.ChaserContact)
	}
	key := effective + "|" + contact
	nd := c.attachedAdapter
	// An unknown room policy resolves to enabled, the wrong way to guess; the Welcome that answers it pushes for us.
	if nd == nil || !c.adapterReady || !(c.relayPolicyKnown || offline) || key == c.sentGhostCollision {
		c.mu.Unlock()
		return
	}
	c.sentGhostCollision = key
	c.mu.Unlock()

	_ = c.sendToAdapter(nd, bridge.TypeSessionPolicy, bridge.SessionPolicy{
		GhostCollision: effective,
		ChaserContact:  contact,
	})
	// Says which side decided, the one place a player can see why ghosts are or are not solid.
	source := "the room"
	if offline {
		source = "your own config (offline)"
	} else if protocol.NormalizeGhostCollision(c.GhostCollision) == protocol.GhostCollisionDisabled &&
		effective == protocol.GhostCollisionDisabled {
		source = "your own config"
	}
	log.Printf("core: ghost collision %s (set by %s) — told the adapter", effective, source)
}

// pushRecordingState tells the attached adapter whether a recording is running, on change only. The record hotkey
// belongs to this process, so without it the only feedback is a console line, hidden by default. Sends outside mu,
// like pushSessionPolicy.
func (c *Core) pushRecordingState() {
	recording := c.Recording()
	c.rec.mu.Lock()
	startedMs := c.rec.startedUnixMs
	c.rec.mu.Unlock()
	c.pushRecordingStateValues(recording, startedMs)
}

// pushRecordingStateValues touches only c.mu, for callers that already hold c.rec.mu (StartRecording does, and Go
// mutexes are not reentrant). The recorder is always released before c.mu is taken, so the two never nest.
func (c *Core) pushRecordingStateValues(recording bool, startedMs int64) {
	if !recording {
		startedMs = 0
	}

	c.mu.Lock()
	nd := c.attachedAdapter
	unchanged := c.sentRecordingStateKnown &&
		c.sentRecordingState == recording &&
		c.sentRecordingStartedMs == startedMs
	if nd == nil || !c.adapterReady || unchanged {
		c.mu.Unlock()
		return
	}
	c.sentRecordingState = recording
	c.sentRecordingStartedMs = startedMs
	c.sentRecordingStateKnown = true
	c.mu.Unlock()

	_ = c.sendToAdapter(nd, bridge.TypeRecordingState, bridge.RecordingState{
		Recording:     recording,
		StartedUnixMs: startedMs,
	})
}

// transportIsClosed asks a transport whether its socket is gone. An optional capability, not a Transport method: a
// transport that cannot tell answers false, the safe direction of keeping the incumbent.
func transportIsClosed(t transport.Transport) bool {
	c, ok := t.(interface{ IsClosed() bool })
	return ok && c.IsClosed()
}

// sendToAdapter is the only way anything reaches the attached adapter. It enqueues onto the connection's
// adapterWriter, which never blocks the caller, so a slow adapter never becomes a dead one; an error means the
// connection is finished (closed, or stuck past the queue cap). Returning does not mean the adapter has the message:
// order is exact, delivery is not synchronous, so a test asserting on delivery waits for the queue to drain.
func (c *Core) sendToAdapter(nd transport.Transport, t bridge.MessageType, payload any) error {
	env, ok := marshalBridge(t, payload)
	if !ok {
		return errBridgeMarshal
	}
	w := c.writerFor(nd)
	m := queuedMsg{env: env}
	switch t {
	case bridge.TypeRenderRemote:
		// The one message that may be superseded: an unsent position is worthless once a newer one exists.
		if rr, isRender := payload.(bridge.RenderRemote); isRender {
			m.renderOf = rr.PlayerID
		}
	case bridge.TypeDespawnRemote:
		// Stop coalescing onto this peer's queued render, so a later respawn lands after the despawn.
		if dr, isDespawn := payload.(bridge.DespawnRemote); isDespawn {
			w.forgetPending(dr.PlayerID)
		}
	}
	if !w.enqueue(m) {
		return errBridgeGone
	}
	return nil
}

// writerFor returns this connection's outbound queue, starting it on first use. Keyed by connection because a refused
// hello is answered on a connection that never became the adapter.
//
// A closed connection gets no entry: a caller that read nd before releasing c.mu can arrive after dropWriter, and a
// writer registered then would never be removed. Every path to dropWriter closes the socket first, so
// transportIsClosed is the exact test.
func (c *Core) writerFor(nd transport.Transport) *adapterWriter {
	c.writerMu.Lock()
	defer c.writerMu.Unlock()
	if w, ok := c.writers[nd]; ok {
		return w
	}
	if transportIsClosed(nd) {
		return closedAdapterWriter(nd)
	}
	if c.writers == nil {
		c.writers = make(map[transport.Transport]*adapterWriter)
	}
	// On a dead adapter the slot goes now; the teardown runs on its own goroutine, since this can run while the
	// recorder's lock is held.
	w := newAdapterWriter(nd, &c.stats.rendersSuperseded, func() {
		wasAdapter, owns, relay := c.releaseAdapterSlot(nd)
		if wasAdapter || owns {
			go c.finishBridgeTeardown(nd, wasAdapter, owns, relay)
		}
	})
	c.writers[nd] = w
	return w
}

// dropWriter stops and forgets a connection's queue, beside the slot release, so its goroutine cannot outlive it.
func (c *Core) dropWriter(nd transport.Transport) {
	c.writerMu.Lock()
	w := c.writers[nd]
	delete(c.writers, nd)
	c.writerMu.Unlock()
	if w != nil {
		w.close()
	}
}

func sendBridgeEnvelope(nd transport.Transport, t bridge.MessageType, payload any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		log.Printf("core: BUG: %s payload failed to marshal: %v", t, err)
		return err
	}
	env, err := json.Marshal(bridge.Envelope{Type: t, Payload: b})
	if err != nil {
		log.Printf("core: BUG: %s envelope failed to marshal: %v", t, err)
		return err
	}
	if err := nd.Send(env); err != nil {
		log.Printf("core: send %s to adapter failed: %v", t, err)
		return err
	}
	return nil
}

// pushAreaPreference tells the relay whether this client wants states from other areas, the inverse of the adapter's
// render_all_areas. The relay hello cannot know it when a -game core connects before the game launches, and a stale
// "own area only" would filter a cross-map adapter's peers away. Sent on every attach: one small message.
func (c *Core) pushAreaPreference() {
	c.mu.Lock()
	relay := c.relay
	ownAreaOnly := !c.adapterRenderAllAreas
	c.mu.Unlock()
	if relay == nil {
		// The hello sent on connect reads the same field.
		return
	}
	payload, err := json.Marshal(protocol.Prefs{OwnAreaOnly: &ownAreaOnly})
	if err != nil {
		log.Printf("core: BUG: prefs failed to marshal: %v", err)
		return
	}
	// Reliable, not lossy: a dropped prefs message is a ghost that never appears, not a sample that arrives late.
	if err := relay.Send(protocol.AppendEnvelope(nil, protocol.TypePrefs, payload)); err != nil {
		log.Printf("core: could not tell the relay our area preference: %v", err)
		return
	}
	if !ownAreaOnly {
		log.Printf("core: adapter renders all areas — asked the relay not to filter by area")
	}
}
