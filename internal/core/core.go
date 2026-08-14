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
	"errors"
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

// RejectError wraps a relay's protocol.Reject reason so callers can
// distinguish a real, explained refusal (wrong room code, version
// mismatch, a full room) from other connection failures — a plain dial
// error (the relay isn't up yet), a timeout — without string-matching a
// formatted message. See IsPermanentRejectErr.
type RejectError struct {
	Reason string
}

func (e *RejectError) Error() string {
	return fmt.Sprintf("core: relay refused connection: %s", e.Reason)
}

// asRejectReason extracts Reason from err if it is (or wraps) a
// *RejectError.
func asRejectReason(err error) (reason string, ok bool) {
	var rejErr *RejectError
	if errors.As(err, &rejErr) {
		return rejErr.Reason, true
	}
	return "", false
}

// isPermanentRejectReason reports whether reason won't resolve on its own
// with a retry (wrong room code, version mismatch, protocol version — all
// require a config change) as opposed to one that might (ReasonServerFull,
// if someone leaves).
func isPermanentRejectReason(reason string) bool {
	return reason != protocol.ReasonServerFull
}

// IsPermanentRejectErr reports whether err represents a relay Reject whose
// reason won't resolve on its own with a retry. Exported so a caller with
// its own retry loop (cmd/meshghost's eager -game path) can decide whether
// to keep trying or give up, using the same classification
// ConnectRelayOnAdapterHello already applies to itself.
func IsPermanentRejectErr(err error) bool {
	reason, ok := asRejectReason(err)
	return ok && isPermanentRejectReason(reason)
}

// DefaultInterpolationDelay is how far behind the most recent samples the
// core renders remotes by default, to smooth over network jitter. The
// brief's "10Hz sync looks fine" was the original hypothesis; the actual
// send rate (DefaultMinSendInterval, 20Hz) has since been live-confirmed
// across three games, see agent_docs/contract.md's Limits section. 100ms
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

// DefaultHeartbeatInterval is how often ConnectRelay sends a Ping on an
// otherwise-quiet relay connection. Found live 2026-08-14: with no adapter
// attached (or any adapter frame reporting get_local_state()==nil, e.g. a
// player parked at a menu), forwardLocalState never sends anything, and
// nothing else was keeping the connection alive — transport.DefaultIdleTimeout
// (60s) killed it, the same-day auto-reconnect fix immediately redialed, and
// the relay handed out a brand-new player_id each cycle (nextPlayerID never
// reuses one), which every other peer sees as a leave+join/ghost despawn-
// respawn once a minute. 20s leaves comfortable margin under the 60s cutoff
// even accounting for scheduling jitter. The relay already replies to Ping
// with Pong (internal/relay/relay.go) — this just wires the client side up
// to actually send one.
const DefaultHeartbeatInterval = 20 * time.Second

// DefaultDialTimeout is ConnectRelay's fallback when its timeout parameter
// is <=0 — every other timing knob in this codebase treats zero as "use
// the default" (transport.go, relay.go); ConnectRelay didn't, found in a
// review pass. Matches transport.DefaultDialTimeout (the underlying TCP
// connect's own bound), so a caller that leaves both unset gets one
// consistent number end to end.
const DefaultDialTimeout = transport.DefaultDialTimeout

// Adapter is an in-process Go interface used only by the Phase 5 fake/test
// adapter (cmd/meshghost-fakeadapter, a ghost that moves in a circle — see
// agent_docs/phases/phase5.md) and any future in-process host. Real
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

	// relayOwner is the bridge connection considered responsible for the
	// current c.relay — only its own disconnect is allowed to close
	// c.relay. Set two ways: (1) ConnectRelayOnAdapterHello, on a Hello
	// that actually establishes a new relay connection (the common case);
	// (2) onAdapterFrame, claimed by the first bridge connection to drive
	// a frame through a relay connection nobody's claimed yet — covers the
	// eager -game/config path, where the relay connects before any bridge
	// connection exists at all, so there's no Hello to assign ownership
	// at. Found in a review pass: handleBridgeConn's OnDisconnect used to
	// close c.relay for *any* bridge connection dropping, including one
	// that never became the adapter at all (e.g. a second adapter refused
	// for a mismatched game_id), which tore down a completely unrelated,
	// working relay session out from under the real adapter.
	relayOwner transport.Transport

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
	// RoomCode is sent as Hello.RoomCode — the shared secret a room-code
	// auth-enabled relay checks before accepting a join. Empty is fine
	// against a relay running with no configured code (the default). See
	// the ADR in agent_docs/architecture.md.
	RoomCode string
	// GameVersion is sent as Hello.GameVersion, overriding whatever the
	// adapter itself reported over bridge.Hello — mirrors how -game already
	// overrides an adapter-declared game_id, for callers with no real
	// adapter to ask (dev-scripts, cmd/meshghost-fakeadapter). Empty means
	// "use whatever the adapter reported."
	GameVersion string
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

	// HeartbeatInterval overrides DefaultHeartbeatInterval for this Core —
	// how often sendHeartbeats pings an otherwise-quiet relay connection.
	// <= 0 disables heartbeats entirely (used by core_test.go to reproduce
	// the pre-fix idle-timeout-churn bug directly).
	HeartbeatInterval time.Duration

	mu          sync.Mutex
	remotes     map[string]*remoteBuffer
	localAreaID string // this Core's own most recently known area_id, for cross-area filtering

	// roster is the set of player_ids this Core has actually seen via
	// Welcome or Join — a State for any other id is dropped rather than
	// silently creating a remote. Before this, the Core trusted the relay
	// completely: Welcome.Roster was discarded, and any player_id arriving
	// in a State was accepted with no cross-check, so a hostile or
	// compromised relay could inject state for an arbitrary id. See the ADR
	// in agent_docs/architecture.md.
	roster map[string]struct{}

	// permanentRejectGame/permanentRejectReason cache a relay Reject this
	// Core has decided isn't worth retrying (see isPermanentRejectReason).
	// Checked before dialing in ConnectRelayOnAdapterHello so a retrying
	// adapter (reconnecting to the bridge every couple of seconds, per
	// adapters/_template/PROTOCOL.md's "non-blocking, retry next frame on
	// failure" rule) doesn't keep hammering the relay with an identical, hopeless
	// connection attempt. Cleared implicitly on process restart — nothing
	// else resets it, since nothing about a running process's own Hello
	// values can change on their own.
	permanentRejectGame   string
	permanentRejectReason string

	// lastConnectErr is the most recently logged connect failure of any
	// kind (a plain dial error while the relay isn't up yet, a transient
	// Reject like "room full", or a permanent one) — logged again only
	// when the message actually changes, so a retrying adapter doesn't
	// flood this process's log with an identical line every retry while
	// waiting for the relay to come up.
	lastConnectErr string

	// autoRetryGameID/autoRetryAdapterGameVersion/autoRetryBridgeConn are
	// set by ConnectRelayOnAdapterHello on every successful connect, and
	// read by ConnectRelay's OnDisconnect handler to decide whether a later
	// drop should trigger a background reconnect loop (reconnectWithBackoff)
	// instead of leaving this Core permanently disconnected.
	//
	// Found live 2026-08-14: two real cores (both connected fine) had their
	// shared relay process restarted out from under them — both logged
	// "relay disconnected" and then sat idle forever, since the only
	// existing retry loop (cmd/meshghost's connectRelayWithRetry) drives
	// just the *first* connect attempt and returns once it succeeds; a real
	// adapter's own bridge-Hello resend (the other trigger for
	// ConnectRelayOnAdapterHello) only happens when the *bridge* connection
	// itself drops, which a relay-only outage never touches. So a relay
	// restart/network blip after a successful connect had no path back to
	// "connected" at all short of restarting the whole client process.
	//
	// Deliberately scoped to ConnectRelayOnAdapterHello's own success path,
	// not ConnectRelay in general: cmd/meshghost-fakeadapter calls
	// ConnectRelay directly and is meant to fail fast and visibly (see its
	// ADR entry in architecture.md), and core_test.go's direct ConnectRelay
	// tests shouldn't spawn background goroutines outliving the test. Both
	// leave these fields at their zero value, so OnDisconnect's
	// retryGameID != "" check naturally opts them out.
	autoRetryGameID             string
	autoRetryAdapterGameVersion string
	autoRetryBridgeConn         transport.Transport
}

// New creates an empty Core with no relay connection yet. Two ways to
// connect: call ConnectRelay directly before ServeBridge (the eager
// -game/config path), or set RelayAddr/Room/DisplayName/RoomCode/
// GameVersion/DialTimeout and let ConnectRelayOnAdapterHello dial lazily
// once a bridge Hello arrives (the default, no-game-set path) — "call
// ConnectRelay before ServeBridge" stopped being the only supported order
// once that lazy path was added; this comment previously still said it was
// required, found stale in a review pass. InterpolationDelay and
// MinSendInterval default to DefaultInterpolationDelay/
// DefaultMinSendInterval; set the fields directly to override them.
func New() *Core {
	return &Core{
		remotes:            make(map[string]*remoteBuffer),
		InterpolationDelay: DefaultInterpolationDelay,
		MinSendInterval:    DefaultMinSendInterval,
		HeartbeatInterval:  DefaultHeartbeatInterval,
		roster:             make(map[string]struct{}),
	}
}

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
// introduced to avoid. GameVersion here is used as-is, unlike
// ConnectRelayOnAdapterHello's adapter-reported-value-with-override
// resolution — a caller with an adapter-reported version to consider
// should go through that function instead, which itself resolves into
// this field before calling ConnectRelay.
func (c *Core) ConnectRelay(gameID string) error {
	addr, room, displayName, roomCode, gameVersion, timeout :=
		c.RelayAddr, c.Room, c.DisplayName, c.RoomCode, c.GameVersion, c.DialTimeout

	// protocol.MaxLineBytes, not transport's generous 64KiB package
	// default — found in a review pass: the relay already used its own
	// tighter limit for connections it accepts, but the core's own dialed
	// relay connection didn't, despite enforcing every per-field cap on
	// receive (storeRemoteState). 0/0 for idle/write timeout means "use
	// transport's own defaults".
	conn, err := transport.DialWithLimits(addr, protocol.MaxLineBytes, 0, 0)
	if err != nil {
		return fmt.Errorf("core: dial relay: %w", err)
	}
	c.mu.Lock()
	c.relay = conn
	c.mu.Unlock()

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
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
		wasCurrent := c.relay == conn
		if wasCurrent {
			c.relay = nil
			c.playerID = ""
			c.relayGame = ""
			c.relayOwner = nil
		}
		retryGameID, retryAdapterVersion, retryBridgeConn := c.autoRetryGameID, c.autoRetryAdapterGameVersion, c.autoRetryBridgeConn
		c.mu.Unlock()

		// See autoRetryGameID's doc comment: only armed by a prior
		// ConnectRelayOnAdapterHello success, so this is a no-op for
		// cmd/meshghost-fakeadapter and core_test.go's direct ConnectRelay
		// callers.
		if wasCurrent && retryGameID != "" {
			go c.reconnectWithBackoff(retryGameID, retryAdapterVersion, retryBridgeConn)
		}
	})
	conn.OnReceive(func(payload []byte) { c.handleRelayMessage(payload, welcome, reject) })

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
		RoomCode:        roomCode,
		GameVersion:     gameVersion,
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
		c.playerID = w.PlayerID
		c.relayGame = gameID
		c.mu.Unlock()
		go c.sendHeartbeats(conn)
		return nil
	case r := <-reject:
		_ = conn.Close()
		return &RejectError{Reason: r.Reason}
	case <-time.After(timeout):
		// Close conn so the existing OnDisconnect handler above clears
		// c.relay/playerID/relayGame — without this, a later
		// ConnectRelayOnAdapterHello sees c.relay still non-nil with
		// relayGame=="" and returns "already connected as game ''"
		// forever, wedging retries. Found in a review pass.
		_ = conn.Close()
		return fmt.Errorf("core: timed out waiting for welcome from relay")
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

	// Resolve into c.GameVersion itself (rather than a local variable) since
	// ConnectRelay now reads it directly from the Core, no longer taking it
	// as a parameter — an explicit override already set on c.GameVersion
	// wins and is left alone; otherwise this adopts whatever the adapter
	// reported, even if that's also empty.
	if c.GameVersion == "" {
		c.GameVersion = adapterGameVersion
	}
	err := c.ConnectRelay(gameID)
	if err != nil {
		reason, isReject := asRejectReason(err)
		permanent := isReject && isPermanentRejectReason(reason)

		c.mu.Lock()
		changed := c.lastConnectErr != err.Error()
		c.lastConnectErr = err.Error()
		if permanent {
			c.permanentRejectGame = gameID
			c.permanentRejectReason = reason
		}
		c.mu.Unlock()

		if changed {
			// No "core: " prefix here — every error ConnectRelay can
			// return is already self-prefixed with it (dial/send/timeout
			// errors, and RejectError.Error()), so this used to print
			// "core: core: ...". Found in a review pass.
			if permanent {
				log.Printf("%v — not retrying automatically; fix the underlying config and restart to try again", err)
			} else {
				log.Printf("%v — will keep retrying", err)
			}
		}
		return err
	}

	c.mu.Lock()
	c.relayGame = gameID
	c.relayOwner = bridgeConn
	c.lastConnectErr = ""
	c.permanentRejectGame = ""
	c.permanentRejectReason = ""
	c.autoRetryGameID = gameID
	c.autoRetryAdapterGameVersion = adapterGameVersion
	c.autoRetryBridgeConn = bridgeConn
	c.mu.Unlock()

	if c.OnRelayConnected != nil {
		c.OnRelayConnected(gameID)
	}
	return nil
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
	const (
		initialBackoff = 1 * time.Second
		maxBackoff     = 15 * time.Second
	)
	backoff := initialBackoff
	for {
		err := c.ConnectRelayOnAdapterHello(gameID, adapterGameVersion, bridgeConn)
		if err == nil {
			return
		}
		if IsPermanentRejectErr(err) {
			log.Printf("core: %v — giving up on automatic reconnect for game %q", err, gameID)
			return
		}
		time.Sleep(backoff)
		if backoff < maxBackoff {
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}
}

// PlayerID returns the id assigned by the relay at Welcome. Empty until
// ConnectRelay succeeds.
func (c *Core) PlayerID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.playerID
}

func (c *Core) handleRelayMessage(payload []byte, welcome chan<- protocol.Welcome, reject chan<- protocol.Reject) {
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
			c.roster = make(map[string]struct{}, len(w.Roster))
			for _, id := range w.Roster {
				c.roster[id] = struct{}{}
			}
			c.mu.Unlock()
			select {
			case welcome <- w:
			default:
			}
		}
	case protocol.TypeReject:
		var r protocol.Reject
		if err := json.Unmarshal(env.Payload, &r); err == nil {
			select {
			case reject <- r:
			default:
			}
		}
	case protocol.TypeJoin:
		var j protocol.Join
		if err := json.Unmarshal(env.Payload, &j); err == nil {
			c.mu.Lock()
			c.roster[j.PlayerID] = struct{}{}
			c.mu.Unlock()
			if j.State != nil {
				c.storeRemoteState(*j.State)
			}
		}
	case protocol.TypeLeave:
		var l protocol.Leave
		if err := json.Unmarshal(env.Payload, &l); err == nil {
			c.mu.Lock()
			delete(c.roster, l.PlayerID)
			c.mu.Unlock()
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
	if st.PlayerID == "" {
		return
	}
	// Size/length/finiteness caps mirror the relay's own checks
	// (internal/relay) via the shared protocol.ValidateState, applied here
	// too since a hostile or compromised relay was previously trusted
	// completely. See the ADR in agent_docs/architecture.md.
	if !protocol.ValidateState(st) {
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if st.PlayerID == c.playerID {
		// Moved inside the lock — c.playerID is written under c.mu
		// elsewhere (ConnectRelay et al.); reading it unlocked here was a
		// real data race, found in a review pass.
		return
	}
	if _, known := c.roster[st.PlayerID]; !known {
		// A state for a player_id this Core never saw via Welcome/Join is
		// dropped rather than trusted — only the relay stamps player_id
		// server-side, and this Core has no other way to confirm who's
		// actually in the room. See the roster field's doc comment.
		return
	}
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
		}
		c.mu.Unlock()
		if relay != nil && owns {
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
			if err := c.ConnectRelayOnAdapterHello(h.GameID, h.GameVersion, nd); err != nil {
				// Already logged, with dedup, inside
				// ConnectRelayOnAdapterHello — just close this bridge
				// connection so the adapter's own reconnect loop tries
				// again later, per adapters/_template/PROTOCOL.md's
				// "non-blocking, retry next frame on failure".
				_ = nd.Close()
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

// sendHeartbeats sends a Ping on conn every DefaultHeartbeatInterval for as
// long as conn remains this Core's current relay connection, so a relay
// connection with no real traffic (no adapter attached, or one reporting
// get_local_state()==nil for a stretch) doesn't get killed by the relay's
// idle timeout. See DefaultHeartbeatInterval's doc comment for the live
// incident this fixes. Exits silently once conn is replaced or closed —
// ConnectRelay's own OnDisconnect handler already logs and handles
// reconnection; this has nothing more to add on a Send failure.
func (c *Core) sendHeartbeats(conn transport.Transport) {
	interval := c.HeartbeatInterval
	if interval <= 0 {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var nonce uint64
	for range ticker.C {
		c.mu.Lock()
		stillCurrent := c.relay == conn
		c.mu.Unlock()
		if !stillCurrent {
			return
		}
		nonce++
		payload, err := json.Marshal(protocol.Ping{Nonce: nonce})
		if err != nil {
			continue
		}
		env, err := json.Marshal(protocol.Envelope{Type: protocol.TypePing, Payload: payload})
		if err != nil {
			continue
		}
		if err := conn.Send(env); err != nil {
			return
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
