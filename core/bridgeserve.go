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
			// The adapter taking over area-based visibility (bridge.Hello's
			// own comment has the why). Under the same lock remoteStatesAt
			// takes, so the filter change is atomic with the attach.
			c.adapterRenderAllAreas = h.RenderAllAreas
			c.mu.Unlock()

			if err := c.ConnectRelayOnAdapterHello(h.GameID, h.GameVersion, nd); err != nil {
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
			sendBridgeEnvelope(nd, bridge.TypeBridgeReady, bridge.BridgeReady{})
			c.mu.Lock()
			c.adapterReady = true
			c.mu.Unlock()
			// The relay handshake above has already completed, so the room's
			// policy is known by now and the adapter gets it as part of
			// coming up rather than a tick later. Order matters: an adapter
			// keys off bridge_ready to start sending, so the policy has to
			// follow it, not precede it.
			c.pushSessionPolicy()
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
		func(id string, st protocol.State) { c.sendRenderRemote(nd, id, st) },
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
	ticker := time.NewTicker(tickInterval)
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
	c.tickRenders(rendered, adapter.RenderRemote, adapter.DespawnRemote)
}

func (c *Core) sendRenderRemote(nd transport.Transport, playerID string, st protocol.State) {
	sendBridgeEnvelope(nd, bridge.TypeRenderRemote, bridge.RenderRemote{PlayerID: playerID, State: st})
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
	nd := c.attachedAdapter
	// relayPolicyKnown, not just a non-empty value: an unknown room policy
	// resolves to ENABLED, and telling an adapter to make ghosts solid because
	// nobody has said otherwise yet is the wrong direction to guess in. The
	// Welcome that answers the question pushes for us.
	if nd == nil || !c.adapterReady || !c.relayPolicyKnown || effective == c.sentGhostCollision {
		c.mu.Unlock()
		return
	}
	c.sentGhostCollision = effective
	c.mu.Unlock()

	sendBridgeEnvelope(nd, bridge.TypeSessionPolicy, bridge.SessionPolicy{
		GhostCollision: effective,
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
