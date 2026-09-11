package core

// The core's side of the bridge: the local, loopback-only channel to an adapter.
//
// Split out of core.go on 2026-08-25. This is the OTHER protocol -- see
// agent_docs/contract.md's "Two protocols" section. An adapter speaks only this,
// never the relay protocol, and a core serves exactly one adapter at a time.

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
	nd := transport.FromConnWithLimits(netConn, transport.DefaultMaxLineBytes, transport.DefaultIdleTimeout, c.bridgeWriteTimeout)
	rendered := make(map[string]bool)

	nd.OnError(func(err error) { log.Printf("core: bridge connection error: %v", err) })
	nd.OnDisconnect(func(err error) { c.bridgeConnGone(nd) })
	nd.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}
		// ADMISSION APPLIES TO EVERY MESSAGE, NOT JUST HELLO. Only the hello
		// case checked attachedAdapter, so every other bridge message was
		// dispatched off whatever connection reached the socket. The bridge
		// binds loopback with NO authentication -- deliberately, and documented
		// at cmd/meshghost's bridgeIsLoopback -- so that means any process on
		// the machine, and on a shared Windows box any other user.
		//
		// What it allowed, each verified in the code: send local_state and have
		// it forwarded to the relay under the real player's player_id and seq,
		// speaking as them to the whole room; receive the render_remote stream
		// for every peer, continuously, on a connection that never handshook;
		// drive replay_control to start and stop their recordings; and, when the
		// relay had been connected eagerly so relayOwner was nil, claim
		// relayOwner in onAdapterFrame -- so closing that connection sent the
		// real player's Goodbye with auto-retry already disarmed. It also made
		// c.lastChaserOfferMs a genuine data race, since recorder.go justifies
		// its unsynchronised access with "runs on the one goroutine that
		// delivers adapter frames".
		//
		// contract.md states the invariant and names the failure it prevents:
		// two adapters on one core fighting over one player_id, one seq, one
		// send-rate budget and one area_id. Found by the 2026-09-07 review, by
		// two agents independently.
		//
		// WHAT THIS DOES NOT CLOSE. It refuses a non-hello message while a
		// DIFFERENT connection holds the slot. It does NOT require a hello: the
		// bridge has always accepted frames from a connection that never
		// handshook -- every fakeAdapter in the suite relies on it -- and making
		// one mandatory is a contract change, filed rather than done here. So a
		// process that connects BEFORE the game still gets in; that is the
		// unauthenticated-loopback design and it needs a decision, not a patch.
		// What is closed is the case that needs no race to win.
		if env.Type != bridge.TypeHello {
			c.mu.Lock()
			impostor := c.attachedAdapter != nil && c.attachedAdapter != nd
			c.mu.Unlock()
			if impostor {
				// Silent: this is usually a second copy of the game, whose own
				// hello already got "busy" and said why. A line per message
				// would let it flood the log at frame rate.
				return
			}
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
			// A dead incumbent is not a busy one. transport.Send closes the
			// socket on a failed write and the peer sees that close (a RESET)
			// before Send has even returned, so a game can be back on this
			// port with a fresh hello before the Core has finished noticing.
			// Refusing it there is what sent a tester's mod off to start a
			// SECOND core on the next port (2026-09-06, 512 chasers): the
			// visible symptom was "the client died". So: if the connection
			// holding the slot is already closed, run its disconnect cleanup
			// -- relay, chasers, replays, recording, exactly what the read
			// loop would have run -- and let this hello take the slot.
			c.mu.Lock()
			incumbent := c.attachedAdapter
			c.mu.Unlock()
			if incumbent != nil && incumbent != nd && transportIsClosed(incumbent) {
				log.Printf("core: the attached adapter's socket is closed -- releasing it for this hello instead of answering busy")
				c.bridgeConnGone(incumbent)
			}

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
				rejectBridge(nd, "busy: this core already has a game attached", bridge.CodeBusy, false)
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
			// Read by StartReplays on this same goroutine a moment later, and
			// by replayLast from a hotkey; under c.mu for the same reason as
			// its two siblings.
			c.adapterWantsInputTracks = h.InputTracks
			// The adapter's own protocol floor, checked against the relay's
			// announced version when the Welcome lands. See
			// bridge.Hello.MinProtocolVersion for why an adapter gets a say,
			// and Core.adapterMinProtocol for why it can only tighten.
			c.adapterMinProtocol = h.MinProtocolVersion
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
			// Same independent read for the same reason: no line here means
			// the core parsed no flag, whatever the adapter logged it sent.
			if h.InputTracks {
				log.Printf("core: adapter asked for input tracks -- a replay whose clip has one will stream remote_input")
			}
			// Same independent read, and this one matters more than the two
			// above: a floor that was not parsed is a floor that is not being
			// enforced, and the failure it prevents is silent by definition.
			if h.MinProtocolVersion > 0 {
				log.Printf("core: adapter requires relay protocol version %d or newer "+
					"(this build's own floor is %d) -- a relay below it will be refused",
					h.MinProtocolVersion, protocol.MinProtocolVersion)
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
					// Carries the relay's own code straight through when the
					// refusal came from there, so an adapter sees ONE namespace
					// rather than having to know which side refused it. A local
					// AlreadyServingError has no relay code, so it gets the
					// bridge one.
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
			// record_on_launch: armed the moment the game's mod attaches. The
			// file itself appears at the first in-game sample, so the main menu
			// is never in it and a game quit before play leaves nothing behind.
			c.armRing()
			// The input ring is the ALWAYS-ON half of the input track (ADR
			// 0056): armed from attach whenever replay.inputs is set, so
			// save-last can export the last stretch of input without anything
			// having been armed in advance. reset() first, because a second
			// adapter's bit 3 is not the first one's bit 3 and its frame
			// counter starts again from zero.
			c.inputMeta.reset()
			c.armInputRing()
			if c.recordOnLaunch() {
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
		case bridge.TypePlayerFrozen:
			var msg bridge.PlayerFrozen
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.SetPlayerFrozen(msg.Frozen)
		case bridge.TypeInputSample:
			var msg bridge.InputSample
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			// Validated here rather than in recordInput so a malformed batch is
			// named once, at the boundary it arrived at. Dropped, never a
			// disconnect: an adapter is not detached for sending a bad line.
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

// bridgeConnGone is the whole of what a bridge connection's end means to the
// Core, and it is idempotent: every branch checks that nd is STILL the
// connection it would act on, so a second call, or a call after another
// adapter has attached, does nothing. Two callers: the transport's
// OnDisconnect (the read loop ended), and onAdapterFrame the moment a write
// to the adapter fails -- see the note there for why the second one exists.
// bridgeConnGone is the whole of what a bridge connection's end means to the
// Core, in two halves that must not be merged again.
//
// releaseAdapterSlot is the half that has to happen NOW and can happen
// anywhere: one c.mu section that calls nothing. finishBridgeTeardown is the
// half that stops the machinery, and it takes OTHER locks -- the recorder's,
// the chaser pack's -- so it may never run on a stack that might already hold
// one. FuzzEverything found that the hard way on 2026-09-06, seconds after the
// peer space was widened: StartRecording holds `c.rec.mu`, pushes the new
// recording state to the adapter, the write fails, and the failure ran
// StopRecording, which waits for `c.rec.mu`. The test hung rather than failed.
//
// Both halves are idempotent, and every branch checks that nd is STILL the
// connection it would act on, so a second call, or a call after another adapter
// has attached, does nothing.
func (c *Core) bridgeConnGone(nd transport.Transport) {
	wasAdapter, owns, relay := c.releaseAdapterSlot(nd)
	// The outbound queue goes with the connection: anything still in it has
	// nowhere to land, and its goroutine must not outlive the socket.
	c.dropWriter(nd)
	c.finishBridgeTeardown(nd, wasAdapter, owns, relay)
}

// releaseAdapterSlot clears everything a gone bridge connection owns that c.mu
// protects, and does nothing else -- no other lock, no call out. That is what
// makes it safe from any goroutine, including one already holding the
// recorder's or the pack's lock. It reports what the connection was, so the
// caller can hand that to finishBridgeTeardown.
func (c *Core) releaseAdapterSlot(nd transport.Transport) (wasAdapter, ownsRelay bool, relay transport.Transport) {
	c.mu.Lock()
	defer c.mu.Unlock()
	relay = c.relay
	ownsRelay = c.relayOwner == nd
	wasAdapter = c.attachedAdapter == nd
	// Free the admission slot whether or not this connection owned the relay:
	// a Core whose adapter has gone is available again, which is what lets a
	// relaunched game reuse it instead of walking to a new port every time.
	if wasAdapter {
		c.attachedAdapter = nil
		c.adapterReady = false
		// The next adapter may be an ordinary one: its Hello decides afresh,
		// and until then the core's own filter is the default.
		c.adapterRenderAllAreas = false
		c.adapterWantsOrientBracket = false
		c.adapterWantsInputTracks = false
	}
	// Disarm auto-retry (see autoRetryGameID's doc comment): this Close is the
	// adapter/game intentionally going away, not an unexpected relay drop, so
	// ConnectRelay's own OnDisconnect handler must NOT reconnect behind its
	// back. Found by a real test failure this fix introduced.
	//
	// GATED ON ownsRelay OR autoRetryBridgeConn, NOT ownsRelay ALONE. It was
	// ownsRelay alone, and forgetRelaySessionLocked sets c.relayOwner = nil on
	// EVERY relay disconnect -- so for the whole duration of a relay outage, no
	// bridge connection owns the relay and this disarm could not run. An adapter
	// that went away inside that window (the player quit while the relay was
	// down) freed the admission slot and left auto-retry armed with the resume
	// token intact: the reconnect loop then rejoined the room, reclaimed the
	// same player_id, and heartbeated a seat that no game was behind and nothing
	// would ever release. Aggravated by the next launch of a DIFFERENT game
	// getting AlreadyServingError, so the mod port-walks and starts a second
	// core. Found by the 2026-09-07 review, by two agents independently;
	// reconnectWithBackoff now also re-checks its adapter every iteration, for
	// the goroutine already asleep in the backoff when this runs.
	if ownsRelay || c.autoRetryBridgeConn == nd {
		c.autoRetryGameID = ""
		c.autoRetryAdapterGameVersion = ""
		c.autoRetryBridgeConn = nil
		c.resumeToken = ""
	}
	return wasAdapter, ownsRelay, relay
}

// finishBridgeTeardown stops what the gone adapter had running. It takes locks
// other than c.mu, so callers that might hold one run it on its own goroutine.
//
// The successor check is why this is safe to run late: if another adapter has
// taken the slot in the meantime, its own Hello has already restarted replays
// and chasers, and stopping them here would tear down the NEW session. Closing
// the relay is guarded by ownership for the same reason (c.relayOwner), so a
// late teardown cannot close a relay connection the successor established.
func (c *Core) finishBridgeTeardown(nd transport.Transport, wasAdapter, ownsRelay bool, relay transport.Transport) {
	// ONE lock section, re-reading what releaseAdapterSlot could only snapshot.
	//
	// ownsRelay and relay were captured BEFORE the admission slot was freed, and
	// from that instant a relaunched game may attach -- 150ms is the measured
	// real-world figure (2026-09-06, the 512-chaser session). This function then
	// closed the relay on the strength of the stale flag before it ever looked
	// for a successor, and its successor check was a second, separate c.mu
	// section that was already out of date by the time StopReplays ran. Since
	// 2026-09-07 the writer's onDead runs it as `go c.finishBridgeTeardown(...)`,
	// which adds unbounded scheduling latency between the snapshot and the act.
	//
	// The comment above claimed ownership already made this safe. It did not:
	// ownership was READ ONCE and never re-read, and a successor can inherit
	// this very relay connection (relaysession.go's same-game transfer branch),
	// so a late teardown could send the successor's Goodbye and close the socket
	// it was using -- peers see leave-then-rejoin under a new player_id, and the
	// relaunched game runs with no chasers, no replays and no recording while
	// every log line looks normal. Found by the 2026-09-07 review.
	c.mu.Lock()
	successor := c.attachedAdapter != nil && c.attachedAdapter != nd
	// Still ours only if nobody has taken the relay over in the meantime. A nil
	// relayOwner means the session was forgotten (the relay dropped), which is
	// not a successor claiming it.
	stillOurs := ownsRelay && relay != nil && c.relay == relay &&
		(c.relayOwner == nd || c.relayOwner == nil)
	c.mu.Unlock()

	if stillOurs {
		// Closing the relay connection turns this into a real disconnect the
		// relay can broadcast as a Leave, so this player's ghost actually
		// disappears for everyone else instead of freezing in place forever.
		// See the OnDisconnect handler in ConnectRelay for the other half: it
		// clears c.relay so a future bridge Hello can redial.
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
	// StopRecording closes the input track that started with it; this covers
	// the other case -- a track armed on its own, with no state recording.
	if _, _, err := c.StopInputRecording(); err != nil {
		log.Printf("core: closing the input track on adapter disconnect: %v", err)
	}
	c.SetInputRingSpan(0)
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
	// **A failed write to the adapter ends the connection HERE, on this
	// goroutine, before anything else happens.** transport.Send closes the
	// socket on a write error (a timed-out line is half-written and NDJSON
	// cannot resync), but the OnDisconnect that frees the admission slot runs
	// only when the read loop notices -- and the read loop IS this goroutine,
	// still inside this frame. Found live 2026-09-06 with a tester's 512-chaser
	// pack: at 353 ghosts a render write timed out, the remaining 352 sends of
	// that tick each failed and logged, the game saw the close and reconnected
	// within 150 ms, and its hello was refused "busy" by a core whose adapter
	// socket was already dead. The mod then walked to the next port and started
	// a SECOND core, which is what the tester reported as "the client died".
	// So: the first failure stops the tick (no 352 more log lines), and the
	// same cleanup OnDisconnect would run happens now, so the reconnect finds
	// the slot free. bridgeConnGone is idempotent; the read loop's own call
	// afterwards is a no-op.
	//
	// TWO ERRORS, TWO MEANINGS -- and until 2026-09-08 this told them apart in
	// neither the handling nor the log. sendToAdapter returns errBridgeGone
	// when the connection is finished, and errBridgeMarshal when a payload
	// THIS PROCESS BUILT could not be turned into JSON. Both ran the teardown
	// above and both printed "the adapter's socket is dead", so a single
	// un-marshalable value -- a NaN in one peer's extras is the reachable case,
	// since encoding/json refuses non-finite floats -- sent the relay a
	// Goodbye, stopped the chasers, the replays and the recording, and reported
	// a healthy socket as dead. The next person to read that log goes looking
	// at the transport.
	//
	// A MARSHAL FAILURE DROPS THAT ONE MESSAGE AND NOTHING ELSE. It is
	// per-message by construction (marshalBridge runs per payload) and it is a
	// defect in this process, so there is nothing for a teardown to repair and
	// no reason to cost the player their session for it: the bad peer loses one
	// frame, everyone else in the same tick still renders, and the frame after
	// this one tries again. Only errBridgeGone still latches and stops the
	// tick, which is the case the latch was written for -- 352 further failed
	// sends and 352 log lines after the first one, 2026-09-06.
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
		// Once per process, not once per frame: the trigger repeats on every
		// tick for as long as that peer keeps sending the value, and at ~180Hz
		// the logging would be the next defect. marshalBridge's own line, also
		// once, names the message type.
		logBridgeBugOnce("adapter-frame-marshal",
			"core: BUG: %d message(s) in this adapter frame could not be marshalled -- dropped them and KEPT the session, "+
				"because a payload this process built is a defect here, not a dead socket (repeats are silent)", marshalBugs)
	}
	if goneErr != nil {
		log.Printf("core: the adapter's socket is dead (%v) -- detaching now so a reconnect is accepted", goneErr)
		c.bridgeConnGone(nd)
	}
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

// rejectBridge tells an adapter why it cannot have this Core, then closes the
// connection. Both halves matter: the reason is what an adapter puts in its log
// (and what a player ends up pasting into a bug report), and the close is what
// frees it to go looking elsewhere without waiting on a timeout.
//
// Send-before-close is deliberate and load-bearing: transport.Send is
// synchronous, so the line is written to the socket before Close, and a
// reject that raced its own hangup would put us right back to a silent
// disconnect -- the thing this exists to remove.
func rejectBridge(nd transport.Transport, reason, code string, retryable bool) {
	log.Printf("core: refused an adapter: %s", reason)
	// Deliberately NOT sendToAdapter: this connection never became the
	// adapter, so a failed write here has no session to tear down.
	_ = sendBridgeEnvelope(nd, bridge.TypeReject, bridge.Reject{
		Reason: reason, Code: code, Retryable: retryable,
	})
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
	// **OFFLINE IS A KNOWN POLICY, not an unanswered one (review J2, fixed
	// 2026-09-11).** The gate below waits for a relay Welcome before telling
	// the adapter anything, and read outside the lock here because
	// Core.offline() takes its own.
	//
	// Waiting is right for a relay that has not answered YET and wrong for a
	// session that will never have one: offline, there is no room, so the
	// room's opinion is not unknown -- it is absent, and the player's own
	// setting is the whole answer. The consequence was worse than a missing
	// message, because `chaser_contact` rides this same message and the chaser
	// is explicitly a SOLO feature (ADR 0047): the one mode where the chaser
	// exists without a room was the one mode where its opt-in could never be
	// delivered.
	offline := c.offline()

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
	// Logged because this is the one place a player can see WHY their ghosts
	// are or are not solid: the value is the resolution of two settings in two
	// different files, one of which is on someone else's machine. Says which
	// side decided it, so "I set it to enabled and it's off" answers itself.
	source := "the room"
	if offline {
		// There is no room to have decided it.
		source = "your own config (offline)"
	} else if protocol.NormalizeGhostCollision(c.GhostCollision) == protocol.GhostCollisionDisabled &&
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

	_ = c.sendToAdapter(nd, bridge.TypeRecordingState, bridge.RecordingState{
		Recording:     recording,
		StartedUnixMs: startedMs,
	})
}

// transportIsClosed asks a transport whether its socket is gone. Optional
// capability rather than a Transport method, the same shape as the unreliable
// writer in package transport: an in-process or test transport that cannot
// close simply answers false, which is the safe direction -- it means "keep
// the incumbent", the behaviour that stood before this existed.
func transportIsClosed(t transport.Transport) bool {
	c, ok := t.(interface{ IsClosed() bool })
	return ok && c.IsClosed()
}

// sendToAdapter is the ONLY way anything reaches the attached adapter, and the
// reason it exists is that a write to a dead adapter must free the Core on the
// spot, whatever goroutine noticed.
//
// transport.Send closes the socket on a write error (a timed-out line is
// half-written and NDJSON cannot resynchronize), but the OnDisconnect that
// frees the admission slot only runs when the READ loop notices -- and the
// read loop is usually the very goroutine still inside the frame that is
// failing. Meanwhile the game has already seen the close and reconnected: its
// hello lands on a Core whose adapter socket is dead and is refused "busy".
//
// Found live 2026-09-06 in a tester's 512-chaser session (a stress test of the
// no-cap chaser count). At 353 ghosts one render write timed out; the rest of
// that tick logged 1,200 more failures; the game reconnected within 150 ms and
// was refused; the mod walked to the next port and started a SECOND core --
// reported as "the client died". A nametag push from a CHASER goroutine can be
// the write that fails first, which is why this cannot live on the frame path
// alone. bridgeConnGone is idempotent, so the read loop's later call is a
// no-op.
// IT NO LONGER WRITES. Since 2026-09-07 it enqueues onto the connection's
// adapterWriter, which never blocks the caller and never fails for slowness --
// see core/adapterwriter.go for why a slow adapter must not become a dead one.
// The error it still returns means the connection is FINISHED (closed, or
// stuck past the queue cap), which is the only case a caller ever needed to
// distinguish.
//
// SO THIS CALL RETURNING NO LONGER MEANS THE ADAPTER HAS THE MESSAGE. Ordering
// is still exact -- one queue, one writer -- but delivery is not synchronous.
// Anything that asserts on what the adapter received must wait for the queue to
// drain (core_test's waitAdapterDrained). That is not theoretical: making this
// asynchronous turned TestGhostCollisionNotPushedBeforeTheRoomHasSpoken into a
// race that PASSED locally under -race -count=3 and failed all three counts on
// CI's Linux race job, which is where it was caught.
func (c *Core) sendToAdapter(nd transport.Transport, t bridge.MessageType, payload any) error {
	env, ok := marshalBridge(t, payload)
	if !ok {
		return errBridgeMarshal
	}
	w := c.writerFor(nd)
	m := queuedMsg{env: env}
	switch t {
	case bridge.TypeRenderRemote:
		// The one message that may be superseded: it says where a peer IS,
		// so an unsent one is worthless once a newer one exists.
		if rr, isRender := payload.(bridge.RenderRemote); isRender {
			m.renderOf = rr.PlayerID
		}
	case bridge.TypeDespawnRemote:
		// Stop coalescing onto this peer's queued render before the despawn
		// goes in, so a LATER render (a respawn) lands after the despawn
		// instead of replacing a message that now sits in front of it.
		if dr, isDespawn := payload.(bridge.DespawnRemote); isDespawn {
			w.forgetPending(dr.PlayerID)
		}
	}
	if !w.enqueue(m) {
		return errBridgeGone
	}
	return nil
}

// writerFor returns this connection's outbound queue, starting it on first
// use. Keyed by the connection rather than held on the Core because a hello
// that gets refused is answered on a connection that never became the
// adapter, and the two must not share a queue.
//
// A CONNECTION WHOSE SOCKET IS ALREADY GONE GETS NO ENTRY IN THE MAP, and that
// is the whole of the fix for c.writers growing without bound (2026-09-08).
// Every sendToAdapter caller reads nd under c.mu and RELEASES the lock before
// sending -- deliberately, so a wedged adapter socket cannot stall the relay
// side (see pushSessionPolicy's note, and the callers in online.go and
// remotenames.go). So this interleaving is ordinary: a nametag push takes nd,
// the read loop ends and bridgeConnGone runs dropWriter, and the push then
// arrives here with a connection nothing will ever remove again. It registered
// a fresh writer -- one goroutine and one queue -- keyed by the dead
// NDJSONConn, which the map key itself then pinned along with its buffers, for
// the life of the process. One entry per game relaunch that lands in that
// window, forever.
//
// transportIsClosed is the exact test because dropWriter is only ever reached
// through bridgeConnGone, and every path into it has closed the socket first:
// the transport closes itself before firing OnDisconnect, transport.Send closes
// it on a failed write, the stuck-adapter verdict closes it explicitly
// (adapterwriter.go), and the dead-incumbent hello path checks this very
// predicate before calling. A message for a closed socket is undeliverable
// anyway, so refusing it costs nothing that was going to arrive, and it also
// stops spawning a writer goroutine for a socket nobody can write to.
//
// A transport that cannot answer the question (the in-process test doubles)
// answers false and gets the behaviour it had before this existed.
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
	// The dead-adapter handling that used to sit inline on every failed send.
	// The slot goes NOW; the teardown that stops replays, chasers and the
	// recording goes on its own goroutine, because this can run while the
	// recorder's lock is held, where running it inline deadlocks
	// (FuzzEverything, 2026-09-06). Both halves are idempotent, so the read
	// loop's own disconnect call afterwards is a no-op.
	w := newAdapterWriter(nd, &c.stats.rendersSuperseded, func() {
		wasAdapter, owns, relay := c.releaseAdapterSlot(nd)
		if wasAdapter || owns {
			go c.finishBridgeTeardown(nd, wasAdapter, owns, relay)
		}
	})
	c.writers[nd] = w
	return w
}

// dropWriter stops and forgets a connection's queue. Called from the same
// place the admission slot is freed, so a connection's goroutine cannot
// outlive the connection.
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
