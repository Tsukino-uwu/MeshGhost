package core

// The core's side of the bridge: the local, loopback-only channel to an adapter.
//
// Split out of core.go on 2026-08-25. This is the OTHER protocol -- see
// agent_docs/contract.md's "Two protocols" section. An adapter speaks only this,
// never the relay protocol, and a core serves exactly one adapter at a time.

import (
	"encoding/json"
	"log"
	"net"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// ServeBridge accepts adapter connections on ln, handling each on its own
// goroutine, until Accept returns an error (typically because ln was
// closed). The bridge is localhost-only and, per agent_docs/contract.md,
// carries only the adapter <-> core traffic — never relay protocol bytes.
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
	nd := transport.FromConn(netConn)
	rendered := make(map[string]bool)

	nd.OnError(func(err error) { log.Printf("core: bridge connection error: %v", err) })
	nd.OnDisconnect(func(err error) {
		// The adapter (game) is gone -- closing the relay connection turns
		// this into a real disconnect the relay can broadcast as a Leave,
		// so this player's ghost actually disappears for everyone else
		// instead of freezing in place forever. See the OnDisconnect
		// handler in ConnectRelay for the other half: it clears c.relay so
		// a future bridge Hello (the adapter reconnecting) can redial.
		//
		// Only do this if nd is the connection that actually established
		// the current relay session (c.relayOwner) -- found in a review
		// pass: this used to fire unconditionally, so a second bridge
		// connection that never became the adapter at all (e.g. refused
		// for a mismatched game_id) closing here tore down a completely
		// unrelated, working relay session out from under the real
		// adapter.
		c.mu.Lock()
		relay := c.relay
		owns := c.relayOwner == nd
		wasAdapter := c.attachedAdapter == nd
		// Free the admission slot whether or not this connection owned the
		// relay: a Core whose adapter has gone is available again, which is
		// what lets a relaunched game reuse it instead of walking to a new
		// port every time.
		if c.attachedAdapter == nd {
			c.attachedAdapter = nil
			c.adapterReady = false
			// The next adapter may be an ordinary one: its Hello decides
			// afresh, and until then the core's own filter is the default.
			c.adapterRenderAllAreas = false
			c.adapterWantsOrientBracket = false
		}
		if owns {
			// Disarm auto-retry (see autoRetryGameID's doc comment) before
			// closing — this Close is the adapter/game intentionally going
			// away, not an unexpected relay drop, so ConnectRelay's own
			// OnDisconnect handler must NOT reconnect behind its back. Found
			// by a real test failure this fix introduced
			// (TestReconnectAfterBridgeDisconnectGetsFreshPlayerID): without
			// this, a deliberate bridge-driven relay close raced against the
			// new auto-retry and silently reconnected with a fresh
			// player_id before the disconnect could even be observed,
			// defeating the entire point of closing the relay connection on
			// a real adapter disconnect (broadcasting a real Leave and
			// letting a later Hello start clean).
			c.autoRetryGameID = ""
			c.autoRetryAdapterGameVersion = ""
			c.autoRetryBridgeConn = nil
			// The game closed. That is a real departure the rest of the room
			// should see as a leave, so the resume credential is discarded
			// here — resumption exists for the connection dropping underneath
			// a still-running game, which is a different event even though
			// both arrive as a closed socket. Without this, relaunching the
			// game would silently reclaim the old identity and nobody would
			// ever have seen the ghost go.
			c.resumeToken = ""
		}
		c.mu.Unlock()
		if relay != nil && owns {
			// Tell the relay this is a deliberate departure before hanging up,
			// so it announces a real leave instead of holding this identity
			// for its resume grace. Clearing c.resumeToken above only decides
			// where the NEXT connection lands; it tells the relay nothing about
			// this one, and without this the room watches a frozen ghost for
			// the whole grace window every time someone quits the game. Found
			// live 2026-08-17, in the loopback session that was meant only to
			// re-confirm the cosmetic path.
			//
			// Best effort: a failure here just means the relay falls back to
			// treating it as an unexplained drop, which is the pre-existing
			// behaviour and still correct, only slower.
			sendGoodbye(relay)
			_ = relay.Close()
		}
		if wasAdapter {
			// AFTER the goodbye, never before it (CI's race job, 2026-09-03):
			// these waits -- up to a second per replay player or chaser whose
			// goroutine is mid-seam -- sat between the socket closing and the
			// Leave reaching the relay, and a game relaunched inside that
			// window was handed its old identity back under the resume grace
			// (TestARelaunchedGameIsANewIdentityNotAResumedOne, red on the
			// runner, green locally twenty of twenty). The relay must hear the
			// departure first; the local ghosts can be torn down after.
			//
			// The game closed: every replay stops with it, so a relaunch starts
			// each one from the top rather than mid-clip; a launch-to-quit
			// recording ends here, and so does a manual one. StopRecording is
			// a no-op when nothing was armed.
			c.StopReplays()
			c.StopChasers()
			if _, _, err := c.StopRecording(); err != nil {
				log.Printf("core: closing the recording on adapter disconnect: %v", err)
			}
		}
	})
	nd.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}
		switch env.Type {
		case bridge.TypeHello:
			var h bridge.Hello
			if err := json.Unmarshal(env.Payload, &h); err != nil {
				return
			}

			// Admission first, before the relay is touched at all. A Core
			// serves one adapter; a second one attaching would share this
			// one's playerID and seq and corrupt both sessions rather than
			// fail (see the attachedAdapter field). Answering with a reason
			// instead of a bare Close is what lets an adapter walk to the
			// next port knowing WHY, rather than guessing from a silent
			// hangup that could equally be a crash.
			c.mu.Lock()
			busy := c.attachedAdapter != nil && c.attachedAdapter != nd
			if !busy {
				c.attachedAdapter = nd
				c.adapterReady = false
				// A new adapter has been told nothing yet, whatever the
				// previous one heard. Without this reset, an adapter
				// reconnecting into an unchanged policy would come up with no
				// session_policy at all and fall back to its compiled-in
				// default -- the exact case a re-launched game hits.
				c.sentGhostCollision = ""
			}
			c.mu.Unlock()
			if busy {
				rejectBridge(nd, "busy: this core already has a game attached")
				return
			}

			// Recorded before the connect below, because the relay Hello it
			// sends carries the union of this and c.Features. An adapter that
			// asks for nothing (every shipped adapter) leaves this empty and
			// the client stays wire-compatible with any room.
			c.mu.Lock()
			c.adapterFeatures = protocol.NormalizeFeatures(h.Features)
			c.adapterGameID = h.GameID
			// The adapter taking over area-based visibility (bridge.Hello's
			// own comment has the why). Under the same lock remoteStatesAt
			// takes, so the filter change is atomic with the attach.
			c.adapterRenderAllAreas = h.RenderAllAreas
			// Same lock, same reason: remoteStatesAt reads this, so the
			// change is atomic with the attach rather than landing mid-tick.
			c.adapterWantsOrientBracket = h.InterpolateOrientation
			c.mu.Unlock()

			// Logged from what the core PARSED, not from what the adapter
			// thinks it sent -- an adapter logging its own outgoing hello
			// proves only that it built the string (CLAUDE.md). This line is
			// the independent read, and it is the one to check when a ghost's
			// facing steps: no line, no bracket, and the adapter is rendering
			// the raw orientation whatever its own flag says.
			if h.InterpolateOrientation {
				log.Printf("core: adapter asked for interpolated orientation -- render_remote will carry the bracket")
			}

			if err := c.ConnectRelayOnAdapterHello(h.GameID, h.GameVersion, nd); err != nil {
				// AN UNREACHABLE RELAY IS NOT A REASON TO REFUSE THE GAME.
				// Until 2026-09-03 it was: any connect error rejected the
				// adapter, so with no relay running the mod attached, was
				// refused, and retried every ten seconds forever. That cost
				// nothing while ghosts were the only feature -- but Phase 11
				// made recording, replays and the chaser SOLO features
				// (ADR 0047), and refusing the session refuses those too.
				// Seen live: record_on_launch armed, no relay up, and not one
				// sample written, because the tap only runs on frames an
				// attached adapter sends. The user's call, and their
				// expectation was that both had always worked alone.
				//
				// So: accept the adapter, say plainly that nobody else will
				// appear, and keep trying the relay in the background with the
				// same loop a mid-session drop uses -- ghosts appear by
				// themselves if one comes up. A PERMANENT refusal (wrong room
				// code, a version mismatch, a protocol gap) still rejects,
				// because no amount of retrying fixes those and the player
				// needs to be told rather than left in a room of one.
				if IsPermanentRejectErr(err) {
					// Release the slot claimed above: this connection never
					// became the adapter, so holding it would make the Core
					// permanently unavailable to anyone else.
					c.mu.Lock()
					if c.attachedAdapter == nd {
						c.attachedAdapter = nil
						c.adapterReady = false
					}
					c.mu.Unlock()
					// The reason reaches the adapter now, where it used to be
					// logged only in the core's own log (and, for the
					// "already connected as another game" case, not even
					// there — that path returns before the dedup logging).
					rejectBridge(nd, err.Error())
					return
				}
				if !c.Offline {
					log.Printf("core: playing alone -- no relay reached yet (%v). The game is "+
						"attached and recording, replays and chasers all work; nobody else will "+
						"appear until a relay answers, and one is still being tried for.", err)
					go c.retryRelayForSoloAdapter(h.GameID, h.GameVersion, nd)
				}
			}
			sendBridgeEnvelope(nd, bridge.TypeBridgeReady, bridge.BridgeReady{})
			c.mu.Lock()
			c.adapterReady = true
			c.mu.Unlock()
			// record_on_launch: armed the moment the game's mod attaches. The
			// file itself appears at the first in-game sample, so the main menu
			// is never in it and a game quit before play leaves nothing behind.
			c.armRing()
			if c.RecordOnLaunch {
				if _, err := c.StartRecording(); err != nil {
					log.Printf("core: record_on_launch: %v", err)
				}
			}
			// Every file in replay/active/ is loaded now and starts at the
			// player's first in-game frame (core/replay.go).
			c.StartReplays()
			// And the chaser pack, if the player turned it on (core/chaser.go).
			c.StartChasers()
			// The relay handshake above has already completed, so the room's
			// policy is known by now and the adapter gets it as part of
			// coming up rather than a tick later. Order matters: an adapter
			// keys off bridge_ready to start sending, so the policy has to
			// follow it, not precede it.
			c.pushSessionPolicy()
			// State on arrival, not only on the next toggle: an adapter can attach
			// while a recording is already running -- a game relaunched during one --
			// and would otherwise show nothing until it stopped.
			c.pushRecordingState()
			// And tell the RELAY what this adapter just told us, because the
			// Hello could not have known it. A core started from its -game
			// flag connects at startup and its adapter attaches whenever the
			// game launches -- so the relay has been assuming this client
			// wants only its own area, which for a cross-map adapter is
			// exactly wrong. Sent after the connect, unconditionally, so the
			// relay's view matches the adapter's regardless of which order
			// the two arrived in.
			c.pushAreaPreference()
			// And every nametag already known, for the same reason: the Joins
			// that carried them may have gone past long before this game
			// launched. Without this, peers who were already in the room stay
			// nameless for the whole session while later arrivals get labels --
			// which reads as the nametags being broken rather than as a missed
			// handover.
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
			// Logged either way: the adapter gets no reply, so this line is the
			// only place a player sees that their in-game key did something.
			what, err := c.ReplayControl(ReplayAction(msg.Action), msg.Seconds)
			if err != nil {
				log.Printf("core: replay_control %q from the adapter: %v", msg.Action, err)
			} else {
				log.Printf("core: replay_control %q from the adapter: %s", msg.Action, what)
			}
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

// onAdapterFrame is the one entry point a wire-speaking adapter drives, per
// frame: it forwards the adapter's local state to the relay (if any), then
// responds on the same call with an upsert/despawn for every remote's
// currently-interpolated state — the tick model in agent_docs/contract.md.
func (c *Core) onAdapterFrame(msg bridge.LocalState, nd transport.Transport, rendered map[string]bool) {
	c.mu.Lock()
	if c.relay != nil && c.relayOwner == nil {
		// Claims ownership for the eager -game/config path (ConnectRelay
		// called directly, or ConnectRelayOnAdapterHello with a nil
		// bridgeConn from cmd/meshghost's connectRelayWithRetry): there's
		// no Hello-driven ownership assignment in that case, since the
		// relay connects before any bridge connection exists. The first
		// bridge connection to actually drive a frame through an
		// as-yet-unowned relay connection claims it, so its own later
		// disconnect still despawns for peers — see relayOwner's doc
		// comment. A real adapter that did send a Hello already has
		// c.relayOwner == nd by the time its first frame reaches here, so
		// this is a no-op for the common case.
		c.relayOwner = nd
	}
	c.mu.Unlock()

	c.forwardLocalState(msg.State)
	c.tickRenders(rendered,
		func(id string, st protocol.State, br orientBracket) { c.sendRenderRemote(nd, id, st, br) },
		func(id string) { c.sendDespawnRemote(nd, id) },
	)
}

// RunAdapter drives Core in-process against adapter — calling
// GetLocalState/RenderRemote/DespawnRemote directly as Go method calls,
// with no bridge socket in between. This is the Phase 5 proof that the core
// has no game-specific leaks: the only thing wired up here is the
// core.Adapter interface, never anything under adapters/. Ticks at
// tickInterval until stop is closed.
func (c *Core) RunAdapter(adapter Adapter, tickInterval time.Duration, stop <-chan struct{}) {
	rendered := make(map[string]bool)
	ticker := time.NewTicker(tickInterval) // wall-clock: RunAdapter polls a GAME for frames
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
	// The in-process path drops the orientation bracket: core.Adapter is a Go
	// interface implemented by test adapters and cmd/meshghost-fakeadapter,
	// none of which draws anything, and widening it to carry a bracket nobody
	// renders would buy a signature change and no behaviour. A real adapter
	// speaks the bridge, where the bracket is on the message.
	c.tickRenders(rendered,
		func(id string, st protocol.State, _ orientBracket) { adapter.RenderRemote(id, st) },
		adapter.DespawnRemote,
	)
}

// COSMETIC COMES FROM THE ID, NOT FROM CURRENT MEMBERSHIP, and the difference is
// a real bug rather than a preference. It used to ask isLocalPeer, which looks
// the id up in c.localPeers -- and a seam DROPS the peer and re-admits it
// (replay.go's seam, every restart, lap and recorded gap). A render tick landing
// inside that window found the id absent and sent cosmetic=false for a replay
// ghost, which tells the adapter that ghost is solid and damageable for that
// frame. ADR 0047 says a replay or chaser ghost is cosmetic whatever
// ghost_collision says, so that frame is a contract violation.
//
// The prefix is authoritative and cannot race: isLocalPeerID's own comment
// records that relay ids come from the relay's counter and never carry one, so
// the two namespaces cannot collide. Membership is transient; the id is not.
//
// Found 2026-09-03 by FuzzEverything on CI, minutes after the clip generator was
// fixed -- before that no clip ever loaded, so no replay ghost ever existed in
// that target and this path had never once run there.
func (c *Core) sendRenderRemote(nd transport.Transport, playerID string, st protocol.State, br orientBracket) {
	msg := bridge.RenderRemote{PlayerID: playerID, State: st, Cosmetic: isLocalPeerID(playerID)}
	if br.Have {
		msg.OrientationFrom, msg.OrientationTo, msg.InterpT = br.From, br.To, br.T
	}
	sendBridgeEnvelope(nd, bridge.TypeRenderRemote, msg)
}

func (c *Core) sendDespawnRemote(nd transport.Transport, playerID string) {
	sendBridgeEnvelope(nd, bridge.TypeDespawnRemote, bridge.DespawnRemote{PlayerID: playerID})
}

// rejectBridge tells an adapter why it cannot have this Core, then closes the
// connection. Both halves matter: the reason is what an adapter puts in its log
// (and what a player ends up pasting into a bug report), and the close is what
// frees it to go looking elsewhere without waiting on a timeout.
//
// Send-before-close is deliberate and load-bearing: transport.Send is
// synchronous, so the line is written to the socket before Close, and a
// reject that raced its own hangup would put us right back to a silent
// disconnect -- the thing this exists to remove.
func rejectBridge(nd transport.Transport, reason string) {
	log.Printf("core: refused an adapter: %s", reason)
	sendBridgeEnvelope(nd, bridge.TypeReject, bridge.Reject{Reason: reason})
	_ = nd.Close()
}

// pushSessionPolicy resolves the room policy against this Core's own
// preference and sends it to the attached adapter, if it has changed since
// the last time we told that adapter.
//
// Called after BridgeReady (the adapter's first policy) and again from the
// Welcome handler (a reconnect, or a resume into a differently-configured
// relay). Sending only on change is what makes the second call cheap enough
// to make unconditionally: the common reconnect re-advertises the same
// policy and this does nothing.
//
// The send happens OUTSIDE mu deliberately. transport.Send can block on a
// slow or wedged adapter socket, and holding the Core's lock across that
// would stall every relay message for the whole process — the adapter is a
// separate process and is not trusted to drain promptly.
func (c *Core) pushSessionPolicy() {
	c.mu.Lock()
	effective := protocol.ResolveGhostCollision(c.relayGhostCollision, c.GhostCollision)
	contact := ""
	if c.ChaserEnabled && c.ChaserContact {
		contact = "enabled"
	}
	// The de-dupe key covers both fields: a change in either is a new push.
	key := effective + "|" + contact
	nd := c.attachedAdapter
	// relayPolicyKnown, not just a non-empty value: an unknown room policy
	// resolves to ENABLED, and telling an adapter to make ghosts solid because
	// nobody has said otherwise yet is the wrong direction to guess in. The
	// Welcome that answers the question pushes for us.
	if nd == nil || !c.adapterReady || !c.relayPolicyKnown || key == c.sentGhostCollision {
		c.mu.Unlock()
		return
	}
	c.sentGhostCollision = key
	c.mu.Unlock()

	sendBridgeEnvelope(nd, bridge.TypeSessionPolicy, bridge.SessionPolicy{
		GhostCollision: effective,
		ChaserContact:  contact,
	})
	// Logged because this is the one place a player can see WHY their ghosts
	// are or are not solid: the value is the resolution of two settings in two
	// different files, one of which is on someone else's machine. Says which
	// side decided it, so "I set it to enabled and it's off" answers itself.
	source := "the room"
	if protocol.NormalizeGhostCollision(c.GhostCollision) == protocol.GhostCollisionDisabled &&
		effective == protocol.GhostCollisionDisabled {
		source = "your own config"
	}
	log.Printf("core: ghost collision %s (set by %s) — told the adapter", effective, source)
}

// pushRecordingState tells the attached adapter whether a recording is running,
// on change only.
//
// WHY THE CORE HAS TO SAY THIS AT ALL. The record hotkey is system-wide and
// owned by this process (ADR 0048), and the core never touches the game -- so
// the only feedback a player had was a console line, which is useless mid-run
// and useless with the console hidden, which is the shipped default. Measured
// the day this was written: the agent read that same log, concluded a recording
// was running, pressed the toggle to stop it, and STARTED one instead. If the
// log is not enough for the process that WRITES it, it is not enough.
//
// Called from both recorder directions and from adapter attach, so an adapter
// that comes up mid-recording is told rather than waiting for the next toggle.
// De-duped, so the attach path calls it unconditionally.
//
// Sends OUTSIDE mu, for the reason pushSessionPolicy documents: a wedged adapter
// socket must not stall the relay side.
func (c *Core) pushRecordingState() {
	recording := c.Recording()
	c.rec.mu.Lock()
	startedMs := c.rec.startedUnixMs
	c.rec.mu.Unlock()
	c.pushRecordingStateValues(recording, startedMs)
}

// pushRecordingStateValues is the half that touches ONLY c.mu, for callers that
// already hold c.rec.mu and therefore cannot ask the recorder anything.
//
// **This split is a deadlock fix, found by the test hanging (2026-09-04).**
// StartRecording holds c.rec.mu through a defer for its whole body, and the
// first version of this pushed from inside it -- so the push called Recording(),
// which wants that same mutex, and Go mutexes are not reentrant. The test did
// not fail, it stopped, which is the shape this class of bug always takes.
//
// Lock ORDER is the other half of the reason it is written this way: everything
// here reads the recorder first and releases it BEFORE taking c.mu, so the two
// locks are never held at once and no caller can invert them.
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

	sendBridgeEnvelope(nd, bridge.TypeRecordingState, bridge.RecordingState{
		Recording:     recording,
		StartedUnixMs: startedMs,
	})
}

func sendBridgeEnvelope(nd transport.Transport, t bridge.MessageType, payload any) {
	b, err := json.Marshal(payload)
	if err != nil {
		log.Printf("core: BUG: %s payload failed to marshal: %v", t, err)
		return
	}
	env, err := json.Marshal(bridge.Envelope{Type: t, Payload: b})
	if err != nil {
		log.Printf("core: BUG: %s envelope failed to marshal: %v", t, err)
		return
	}
	if err := nd.Send(env); err != nil {
		log.Printf("core: send %s to adapter failed: %v", t, err)
	}
}

// pushAreaPreference tells the relay whether this client wants states from
// other areas, which is the inverse of the attached adapter's own
// render_all_areas declaration (bridge.Hello).
//
// It exists because the Hello cannot answer the question. A core started from
// its -game flag connects to the relay at startup; its adapter attaches when
// the game launches, which may be minutes later. So at Hello time there is no
// adapter to ask, the core defaults to "only my own area", and a cross-map
// adapter's peers are then filtered away by the relay.
//
// FOUND LIVE 2026-08-28, in the first real Emerald session after relay-side
// area filtering shipped: a ghost crossing a route seam froze on the tile it
// entered and vanished three seconds later, which is the departing-ghost
// signature exactly -- one state delivered by the transition rule, then
// silence, then the stale-after timer. The relay's own introspect line
// confirmed it, reporting 60% of bytes filtered in a room where Emerald should
// have had none. The code comment claiming an unattached adapter was
// "harmless" because the filter fails open was wrong: it fails open only until
// the client's area is known, and then the stale declaration applies forever.
//
// Sent unconditionally rather than only on a change: it is one small message
// per adapter attach, and "only when it differs from what we sent" is state
// this does not need to keep.
func (c *Core) pushAreaPreference() {
	c.mu.Lock()
	relay := c.relay
	ownAreaOnly := !c.adapterRenderAllAreas
	c.mu.Unlock()
	if relay == nil {
		// Not connected yet, so there is nothing to correct -- the Hello this
		// core sends when it does connect reads the same field, and by then
		// the adapter is attached.
		return
	}
	payload, err := json.Marshal(protocol.Prefs{OwnAreaOnly: &ownAreaOnly})
	if err != nil {
		log.Printf("core: BUG: prefs failed to marshal: %v", err)
		return
	}
	if err := relay.Send(protocol.AppendEnvelope(nil, protocol.TypePrefs, payload)); err != nil {
		// Reliable, not lossy: a dropped prefs message leaves the relay
		// filtering a client that needs everything, which is a ghost that
		// never appears rather than a sample that arrives late.
		log.Printf("core: could not tell the relay our area preference: %v", err)
		return
	}
	if !ownAreaOnly {
		log.Printf("core: adapter renders all areas — asked the relay not to filter by area")
	}
}
