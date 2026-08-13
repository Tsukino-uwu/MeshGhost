// Package core is the game-agnostic client: it owns the relay connection,
// the snapshot/interpolation buffer, and remote-player tracking. It talks
// to the relay via internal/transport.Transport and to a real adapter via
// internal/bridge — never to game memory or a rendering primitive directly.
// See agent_docs/contract.md's tick model: the adapter always drives (calls
// in once per frame, over the bridge, by sending a LocalState message); the
// core responds to that same call with already-interpolated RenderRemote /
// DespawnRemote pushes for every currently known remote.
//
// Hard rule (agent_docs/architecture.md, CLAUDE.md): this package must never
// import anything under adapters/, and must never branch on game_id or any
// other opaque field's contents.
package core

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"meshghost/internal/bridge"
	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// DefaultInterpolationDelay is how far behind the most recent samples the
// core renders remotes by default, to smooth over network jitter. The
// brief's "10Hz sync looks fine" is a hypothesis, not yet confirmed against
// a running game — see the open question in agent_docs/contract.md. 100ms
// is a starting guess for tile-grid movement, not a measured value.
// Overridable per-Core (see Core.InterpolationDelay) — Phase 3's loopback
// test runs ~200ms so the trailing ghost is plainly visible on screen.
const DefaultInterpolationDelay = 100 * time.Millisecond

// DefaultMinSendInterval caps how often forwardLocalState actually sends to
// the relay, independent of how often the adapter calls in. Added in Phase 6
// (TEVI) after hitting this for real: relay.MaxMessagesPerSecond is 120, but
// a Unity adapter's Update() runs uncapped well above that, so every-frame
// forwarding got the connection closed by the relay after ~2 minutes
// (agent_docs/verified.md's Phase 6.4/6.5 entry). 50ms (20Hz) leaves
// comfortable headroom under the relay's cap regardless of adapter frame
// rate, and is well above the brief's own 10Hz sync hypothesis. Overridable
// per-Core, same pattern as InterpolationDelay.
const DefaultMinSendInterval = 50 * time.Millisecond

// Adapter is an in-process Go interface used only by the Phase 5 fake/test
// adapter (one that moves a ghost in a circle, per agent_docs/phases —
// created when that phase starts) and any future in-process host. Real
// adapters — BizHawk Lua today, anything else later — never implement this
// interface; they speak the internal/bridge wire protocol instead. This
// interface exists purely so Phase 5 can prove the core has no game-specific
// leaks without needing a socket at all.
type Adapter interface {
	// GetLocalState returns the current local snapshot. ok == false means
	// "don't send this frame" — the wire equivalent of bridge.LocalState
	// with State == nil.
	GetLocalState() (state protocol.State, ok bool)

	// RenderRemote upserts a remote ghost's state. Called once per core
	// frame tick for every known remote, not only on new network data —
	// see the tick model in agent_docs/contract.md for why.
	RenderRemote(playerID string, state protocol.State)

	// DespawnRemote removes a remote ghost.
	DespawnRemote(playerID string)
}

// Core is the game-agnostic client: one relay connection, a bridge
// listener accepting adapter connections, and a per-remote-player
// interpolation buffer.
type Core struct {
	relay     transport.Transport
	playerID  string
	relayGame string // game_id this Core is connected to the relay as, once connected
	seq       uint64

	// RelayAddr, Room, DisplayName, and DialTimeout are used by
	// ConnectRelayOnAdapterHello to dial the relay lazily, the first time an
	// adapter's bridge.Hello arrives with a game_id, for callers that don't
	// already know the game at startup (e.g. cmd/meshghost with no -game
	// flag/config value) — see agent_docs/architecture.md's ADR. Unused by
	// the direct ConnectRelay path. Set these before ServeBridge if
	// ConnectRelayOnAdapterHello will be relied on.
	RelayAddr   string
	Room        string
	DisplayName string
	DialTimeout time.Duration

	// OnRelayConnected, if set, is called once after
	// ConnectRelayOnAdapterHello successfully connects — lets a caller like
	// cmd/meshghost log its usual "connected to relay" line even though the
	// connection now happens off the initial startup path. Not called by
	// the direct ConnectRelay path, whose caller already knows synchronously
	// when it returns.
	OnRelayConnected func(gameID string)

	relayConnectMu sync.Mutex // serializes ConnectRelayOnAdapterHello dials

	// InterpolationDelay overrides DefaultInterpolationDelay for this Core.
	// Exported so cmd/meshghost can set it from a flag; adapters never see
	// or set this — it's a core-internal render-timing knob, not part of
	// the bridge wire protocol.
	InterpolationDelay time.Duration

	// MinSendInterval overrides DefaultMinSendInterval for this Core — the
	// minimum time between relay sends, regardless of adapter call rate.
	// See DefaultMinSendInterval's comment for why this exists.
	MinSendInterval time.Duration
	lastSendAt      time.Time

	mu          sync.Mutex
	remotes     map[string]*remoteBuffer
	localAreaID string // this Core's own most recently known area_id, for cross-area filtering
}

// New creates an empty Core with no relay connection yet — call
// ConnectRelay before ServeBridge. InterpolationDelay and MinSendInterval
// default to DefaultInterpolationDelay/DefaultMinSendInterval; set the
// fields directly to override them.
func New() *Core {
	return &Core{
		remotes:            make(map[string]*remoteBuffer),
		InterpolationDelay: DefaultInterpolationDelay,
		MinSendInterval:    DefaultMinSendInterval,
	}
}

// ConnectRelay dials addr, performs the hello/welcome handshake, and wires
// up handling of join/leave/state messages from the relay for the rest of
// this Core's life. It blocks until Welcome arrives or timeout elapses.
func (c *Core) ConnectRelay(addr, gameID, room, displayName string, timeout time.Duration) error {
	conn, err := transport.Dial(addr)
	if err != nil {
		return fmt.Errorf("core: dial relay: %w", err)
	}
	c.mu.Lock()
	c.relay = conn
	c.mu.Unlock()

	welcome := make(chan protocol.Welcome, 1)
	conn.OnError(func(err error) { log.Printf("core: relay connection error: %v", err) })
	conn.OnDisconnect(func(err error) {
		log.Printf("core: relay disconnected: %v", err)
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
		c.dropAllRemotes()

		// Clear relay identity so a later bridge Hello (the adapter
		// reconnecting, e.g. relaunching the game) can redial via
		// ConnectRelayOnAdapterHello instead of finding c.relay non-nil and
		// treating this Core as still connected forever. Guarded against a
		// stale callback firing after a newer connection has already
		// replaced this one.
		c.mu.Lock()
		if c.relay == conn {
			c.relay = nil
			c.playerID = ""
			c.relayGame = ""
		}
		c.mu.Unlock()
	})
	conn.OnReceive(func(payload []byte) { c.handleRelayMessage(payload, welcome) })

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
	})
	if err != nil {
		return err
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		return err
	}
	if err := conn.Send(env); err != nil {
		return fmt.Errorf("core: send hello: %w", err)
	}

	select {
	case w := <-welcome:
		c.mu.Lock()
		c.playerID = w.PlayerID
		c.relayGame = gameID
		c.mu.Unlock()
		return nil
	case <-time.After(timeout):
		return fmt.Errorf("core: timed out waiting for welcome from relay")
	}
}

// ConnectRelayOnAdapterHello lazily connects Core to the relay the first
// time an adapter declares its game via a bridge.Hello, instead of
// requiring the caller to already know the game_id at startup — see
// agent_docs/architecture.md's ADR. Uses RelayAddr/Room/DisplayName/
// DialTimeout, which must be set (directly on the Core) before any bridge
// connection can send a Hello.
//
// No-op if this Core is already connected to the relay for the same
// gameID. If it's already connected for a *different* gameID, returns an
// error rather than reconnecting: the earlier connection's relay Hello
// already committed this Core to that game and can't be retracted, so a
// second game can't share the same Core/process.
func (c *Core) ConnectRelayOnAdapterHello(gameID string) error {
	c.relayConnectMu.Lock()
	defer c.relayConnectMu.Unlock()

	c.mu.Lock()
	alreadyConnected := c.relay != nil
	connectedGame := c.relayGame
	c.mu.Unlock()

	if alreadyConnected {
		if connectedGame == gameID {
			return nil
		}
		return fmt.Errorf("core: already connected to the relay as game %q, cannot also serve %q on the same process", connectedGame, gameID)
	}

	if err := c.ConnectRelay(c.RelayAddr, gameID, c.Room, c.DisplayName, c.DialTimeout); err != nil {
		return err
	}
	c.mu.Lock()
	c.relayGame = gameID
	c.mu.Unlock()

	if c.OnRelayConnected != nil {
		c.OnRelayConnected(gameID)
	}
	return nil
}

// PlayerID returns the id assigned by the relay at Welcome. Empty until
// ConnectRelay succeeds.
func (c *Core) PlayerID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.playerID
}

func (c *Core) handleRelayMessage(payload []byte, welcome chan<- protocol.Welcome) {
	var env protocol.Envelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return
	}

	switch env.Type {
	case protocol.TypeWelcome:
		var w protocol.Welcome
		if err := json.Unmarshal(env.Payload, &w); err == nil {
			select {
			case welcome <- w:
			default:
			}
		}
	case protocol.TypeJoin:
		var j protocol.Join
		if err := json.Unmarshal(env.Payload, &j); err == nil && j.State != nil {
			c.storeRemoteState(*j.State)
		}
	case protocol.TypeLeave:
		var l protocol.Leave
		if err := json.Unmarshal(env.Payload, &l); err == nil {
			c.dropRemote(l.PlayerID)
		}
	case protocol.TypeState:
		var st protocol.State
		if err := json.Unmarshal(env.Payload, &st); err == nil {
			c.storeRemoteState(st)
		}
	default:
		// Unknown or not-yet-implemented types (event, ping/pong) are
		// ignored — same forward-compatibility posture as unknown fields.
	}
}

func (c *Core) storeRemoteState(st protocol.State) {
	if st.PlayerID == "" || st.PlayerID == c.playerID {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	b, ok := c.remotes[st.PlayerID]
	if !ok {
		b = &remoteBuffer{}
		c.remotes[st.PlayerID] = b
	}
	b.add(st)
}

func (c *Core) dropRemote(playerID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.remotes, playerID)
}

// dropAllRemotes clears every tracked remote at once — used when the relay
// connection itself is lost, since there's no longer any source for
// updates or an explicit Leave to drive individual despawns.
func (c *Core) dropAllRemotes() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.remotes = make(map[string]*remoteBuffer)
}

// remoteStatesAt returns the interpolated state of every currently known
// remote at renderTime that is also in this Core's own current area --
// cross-area filtering, added 2026-08-13 after a real two-player TEVI test
// showed a remote's ghost rendering at another zone's raw world coordinates,
// invisible only by coincidence (see the ADR in architecture.md). Equality
// comparison only, per contract.md's area_id rule -- never branches on
// contents. If localAreaID is still empty (no real local frame has arrived
// yet), every remote passes through unfiltered rather than hiding
// everything on an unknown local area.
func (c *Core) remoteStatesAt(renderTime int64) map[string]protocol.State {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]protocol.State, len(c.remotes))
	for id, buf := range c.remotes {
		st, ok := buf.at(renderTime)
		if !ok {
			continue
		}
		if c.localAreaID != "" && st.AreaID != c.localAreaID {
			continue
		}
		out[id] = st
	}
	return out
}

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
		c.mu.Lock()
		relay := c.relay
		c.mu.Unlock()
		if relay != nil {
			relay.Close()
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
			if err := c.ConnectRelayOnAdapterHello(h.GameID); err != nil {
				log.Printf("core: %v", err)
				nd.Close()
			}
		case bridge.TypeLocalState:
			var msg bridge.LocalState
			if err := json.Unmarshal(env.Payload, &msg); err != nil {
				return
			}
			c.onAdapterFrame(msg, nd, rendered)
		}
	})
}

// onAdapterFrame is the one entry point a wire-speaking adapter drives, per
// frame: it forwards the adapter's local state to the relay (if any), then
// responds on the same call with an upsert/despawn for every remote's
// currently-interpolated state — the tick model in agent_docs/contract.md.
func (c *Core) onAdapterFrame(msg bridge.LocalState, nd transport.Transport, rendered map[string]bool) {
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

// forwardLocalState stamps and sends state to the relay, if there is one.
// state == nil means "don't send this frame" (get_local_state()'s nil
// case). Actual sends are capped to MinSendInterval regardless of how often
// the adapter calls in — see DefaultMinSendInterval's comment. A dropped
// frame here is not stamped with seq/timestamp at all, so it never reaches
// the relay and never affects Core.seq's monotonic count.
func (c *Core) forwardLocalState(state *protocol.State) {
	if state == nil {
		return
	}

	c.mu.Lock()
	// Recorded on every real local frame, independent of MinSendInterval
	// throttling below and of whether a relay connection exists yet --
	// remoteStatesAt's cross-area filter needs this to always reflect the
	// adapter's actual current area, not just what was last sent over the
	// network. See the 2026-08-13 ADR in architecture.md.
	c.localAreaID = state.AreaID
	relay := c.relay
	if relay == nil {
		// No adapter has sent a Hello yet (or -game/config never set one) --
		// nothing to forward to. Not an error: this is the normal state
		// while ConnectRelayOnAdapterHello is waiting for one.
		c.mu.Unlock()
		return
	}
	elapsed := time.Since(c.lastSendAt)
	if c.lastSendAt.IsZero() {
		elapsed = c.MinSendInterval // always allow the first send
	}
	if elapsed < c.MinSendInterval {
		c.mu.Unlock()
		return
	}
	c.lastSendAt = time.Now()
	playerID := c.playerID
	c.mu.Unlock()

	st := *state
	st.PlayerID = playerID
	st.Seq = atomic.AddUint64(&c.seq, 1)
	st.Timestamp = time.Now().UnixMilli()
	c.sendState(relay, st)
}

// tickRenders diffs the currently-interpolated remote set against what was
// rendered last tick, calling render for every current remote and despawn
// for every remote that dropped out — shared by both the bridge-wire path
// (onAdapterFrame) and the in-process path (onAdapterFrameInProcess) so the
// tick-model diff logic exists exactly once.
func (c *Core) tickRenders(rendered map[string]bool, render func(id string, st protocol.State), despawn func(id string)) {
	renderTime := time.Now().Add(-c.InterpolationDelay).UnixMilli()
	current := c.remoteStatesAt(renderTime)

	for id, st := range current {
		render(id, st)
		rendered[id] = true
	}
	for id := range rendered {
		if _, stillKnown := current[id]; !stillKnown {
			despawn(id)
			delete(rendered, id)
		}
	}
}

func (c *Core) sendState(relay transport.Transport, st protocol.State) {
	payload, err := json.Marshal(st)
	if err != nil {
		log.Printf("core: BUG: state failed to marshal: %v", err)
		return
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		log.Printf("core: BUG: state envelope failed to marshal: %v", err)
		return
	}
	if err := relay.Send(env); err != nil {
		log.Printf("core: send state to relay failed: %v", err)
	}
}

func (c *Core) sendRenderRemote(nd transport.Transport, playerID string, st protocol.State) {
	sendBridgeEnvelope(nd, bridge.TypeRenderRemote, bridge.RenderRemote{PlayerID: playerID, State: st})
}

func (c *Core) sendDespawnRemote(nd transport.Transport, playerID string) {
	sendBridgeEnvelope(nd, bridge.TypeDespawnRemote, bridge.DespawnRemote{PlayerID: playerID})
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
