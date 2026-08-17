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
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"meshghost/internal/bridge"
	"meshghost/internal/netx"
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
// require a config change) as opposed to one that might. An explicit
// retryable set, not a blacklist-of-one, since the send/receive rate-control
// feature added a second retryable reason (see the ADR in
// agent_docs/architecture.md): unknown reasons from a future relay stay
// classified permanent, the conservative default this has always had.
func isPermanentRejectReason(reason string) bool {
	switch reason {
	case protocol.ReasonServerFull, protocol.ReasonRateLimited:
		// ServerFull resolves if someone leaves; RateLimited resolves
		// because a reconnecting client re-reads the room's advertised
		// send_hz from the new Welcome and may well fit under the cap this
		// time.
		return false
	}
	return true
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

// DefaultMinSendInterval is this Core's fallback send interval when neither
// the relay advertised a rate nor this Core's own MinSendInterval was set
// (see effectiveSendInterval) — an older relay that predates
// Welcome.SendHz, most obviously. Rederived from protocol.DefaultSendHz
// rather than a separate literal so the two numbers cannot drift apart.
// Added in Phase 6 (TEVI) after hitting this for real: relay.
// MaxMessagesPerSecond was a hardcoded 120, but a Unity adapter's Update()
// runs uncapped well above that, so every-frame forwarding got the
// connection closed by the relay after ~2 minutes (agent_docs/verified.md's
// Phase 6.4/6.5 entry). 50ms (20Hz) leaves comfortable headroom under the
// relay's cap regardless of adapter frame rate, and is well above the
// brief's own 10Hz sync hypothesis. See the ADR in agent_docs/architecture.md
// for the send/receive rate-control feature that made this a fallback
// rather than a fixed rate.
const DefaultMinSendInterval = time.Second / protocol.DefaultSendHz

// DefaultMaxReceiveHz is the receive cap a Core requests in Hello.
// MaxReceiveHz when its caller hasn't set one. Zero means uncapped — every
// peer's state is forwarded at whatever rate the room runs at, which is
// exactly today's pre-existing behavior and therefore the only safe
// default: capping by default would silently degrade every existing ghost.
// Opting in (Core.MaxReceiveHz) is a statement about this machine's own
// downlink, not about the room. See the ADR in agent_docs/architecture.md.
const DefaultMaxReceiveHz = 0

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

	// attachedAdapter is the one bridge connection currently allowed to drive
	// this Core, and is NOT the same thing as relayOwner above. relayOwner
	// answers "whose disconnect may tear down the relay"; this answers "may you
	// attach at all", which is an admission question asked at Hello time.
	// Conflating the two is how the stale-callback bug relayOwner exists to
	// prevent got written in the first place, so they stay separate.
	//
	// A Core serves at most ONE adapter. This was always the intent -- the
	// contract describes "the bridge connection" in the singular throughout --
	// but nothing enforced it, and the gap was not theoretical: two adapters
	// running the SAME game_id both got a successful Hello (see
	// ConnectRelayOnAdapterHello's early "already connected as this game"
	// return) and then silently shared one relay session, fighting over one
	// playerID, one seq, one send-rate budget, and one localAreaID. Two games,
	// one ghost, both logging a normal "connected". Found 2026-08-16 while
	// designing the port walk that makes two instances a normal thing to do.
	attachedAdapter transport.Transport

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
	// Transport selects how ConnectRelay reaches the relay. The zero value
	// (netx.TCP) is the original and only pre-2026-08-16 behaviour, so a
	// Core built without setting this is unchanged — which is what keeps
	// every existing test on the exact same code path. Note this concerns
	// only the relay connection: the adapter bridge is always loopback TCP
	// and no adapter can observe this field. See the transport ADR in
	// agent_docs/architecture.md.
	Transport netx.Kind
	// MaxReceiveHz is sent as Hello.MaxReceiveHz — the highest rate, per
	// peer, at which this client asks the relay to forward other players'
	// state to it. Zero (DefaultMaxReceiveHz) means uncapped. A request, not
	// a guarantee: an older relay ignores the field entirely and there is no
	// echo in Welcome to tell this Core whether it was honored. See the ADR
	// in agent_docs/architecture.md.
	MaxReceiveHz int

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

	// MinSendInterval is this Core's own deliberately-configured floor on
	// how often it sends to the relay, regardless of adapter call rate.
	// Zero (the default — New() no longer presets this) means "no local
	// preference; adopt whatever the relay advertises." A non-zero value is
	// a floor, never a ceiling: effectiveSendInterval takes the SLOWER of
	// this and the relay's advertised rate, so setting this can only ever
	// make this Core send slower than the room, on behalf of a poor local
	// connection — the relay can never speed this Core up past a rate it
	// deliberately chose. See DefaultMinSendInterval and the ADR in
	// agent_docs/architecture.md for the send/receive rate-control feature.
	MinSendInterval time.Duration
	lastSendAt      time.Time

	// serverSendInterval is the interval derived from the relay's advertised
	// Welcome.SendHz, or 0 if the relay advertised nothing (an older relay)
	// or hasn't sent Welcome yet. Guarded by mu; set once per connection in
	// handleRelayMessage's Welcome case and cleared on disconnect, so a
	// reconnect to a differently-configured relay never inherits a stale
	// rate.
	serverSendInterval time.Duration

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

	// Features is the capability list this Core advertises in Hello.Features,
	// on top of whatever the adapter itself asks for over the bridge (see
	// effectiveFeatures). Empty by default, deliberately: a room's feature
	// set is sticky and matched exactly, so a Core that advertised
	// capabilities nobody asked for would refuse to share a room with any
	// client that hadn't been upgraded in lockstep. Everything past the
	// cosmetic state plane is opt-in — see agent_docs/beyond-cosmetic.md §3
	// and the Feature* constants in internal/protocol/online.go.
	Features []string

	// adapterFeatures is what the adapter last requested in its bridge
	// Hello, kept separate from the exported Features (the user's own
	// setting) for the same reason adapterGameVersion is kept separate from
	// GameVersion: latching one into the other destroys the "not set" state
	// for the rest of the process.
	adapterFeatures []string

	// resumeToken is the single-use secret from the last Welcome, presented
	// in a later Hello to reclaim this identity after an unexpected drop.
	// Deliberately NOT cleared on disconnect — that is precisely when it
	// becomes useful — but cleared when the adapter itself goes away, since
	// that is a real departure the room should see rather than a blip to
	// paper over.
	resumeToken string

	// activeFeatures is the room's agreed feature set, from Welcome.Features
	// — NOT what this Core asked for. The two can differ only by the relay
	// being older than this client (in which case the room agreed on
	// nothing), because a real mismatch is refused at the handshake. Every
	// send path gates on this rather than on the request, so a capability
	// this room does not have fails with a clear error instead of being
	// dropped somewhere in the relay. Guarded by mu; cleared on disconnect.
	activeFeatures []string

	// resumed records whether the current session reclaimed a previous
	// identity (Welcome.Resumed) rather than being issued a fresh one.
	resumed bool

	// lastNowMs is the highest value nowMs has returned, so the clock it hands
	// out never moves backwards when the offset estimate is revised downwards.
	// Guarded by mu. See nowMs.
	lastNowMs int64

	// clock holds this connection's estimate of the offset between the local
	// wall clock and the relay's. See clockSync in online.go for why a shared
	// clock domain matters: State.Timestamp is compared directly against a
	// local wall clock by interp.go, so peers whose clocks disagree stop
	// interpolating silently rather than failing.
	clock clockSync

	// pendingPings maps a heartbeat nonce to when it was sent, so a Pong can
	// be turned into a round-trip time. The nonce field existed from the
	// start and nothing read it back, which meant RTT was not merely
	// unmeasured but not computable at all.
	pendingPings map[uint64]time.Time

	// OnEvent, OnLeaseState and OnEscrowState, if set, receive the event
	// plane and the two arbitration planes. A caller that leaves them nil
	// (every cosmetic caller) still has these messages forwarded to its
	// attached adapter over the bridge — these exist for an in-process host
	// and for tests, the same narrow role core.Adapter has.
	OnEvent       func(ev protocol.Event)
	OnLeaseState  func(st protocol.LeaseState)
	OnEscrowState func(st protocol.EscrowState)

	// adapterGameVersion is the version the adapter last reported in its
	// bridge Hello. Kept separate from the exported GameVersion (the user's
	// override) so a reconnecting adapter reporting a different version is
	// advertised under the new one — see ConnectRelay, which resolves the
	// two per call rather than latching either.
	adapterGameVersion string
}

// New creates an empty Core with no relay connection yet. Two ways to
// connect: call ConnectRelay directly before ServeBridge (the eager
// -game/config path), or set RelayAddr/Room/DisplayName/RoomCode/
// GameVersion/DialTimeout and let ConnectRelayOnAdapterHello dial lazily
// once a bridge Hello arrives (the default, no-game-set path) — "call
// ConnectRelay before ServeBridge" stopped being the only supported order
// once that lazy path was added; this comment previously still said it was
// required, found stale in a review pass. InterpolationDelay defaults to
// DefaultInterpolationDelay; set the field directly to override it.
// MinSendInterval is deliberately left at its zero value here (unlike
// InterpolationDelay) — see its own doc comment: zero means "no local
// preference, adopt the relay's advertised rate," and DefaultMinSendInterval
// only ever applies as effectiveSendInterval's last-resort fallback.
func New() *Core {
	return &Core{
		remotes:            make(map[string]*remoteBuffer),
		InterpolationDelay: DefaultInterpolationDelay,
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
	kind, dialAddr, err := c.resolveTransport(addr, gameID, room, displayName, roomCode, gameVersion)
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
	netConn, err := netx.Dial(kind, dialAddr, transport.DefaultDialTimeout)
	if err != nil {
		return fmt.Errorf("core: dial relay: %w", err)
	}
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
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
		//
		// Moved inside the wasCurrent guard below in a review pass
		// 2026-08-16: it was the one thing this callback did unguarded, so a
		// stale connection's late OnDisconnect would have wiped the *live*
		// connection's remotes, despawning and respawning every ghost. No
		// reachable trigger was found (readLoop fires synchronously on
		// Close, well before any retry path installs a replacement), so this
		// is removing an asymmetry, not fixing an observed bug.
		//
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
			// Cleared so a reconnect (to this relay again, or a different,
			// differently-configured one) starts from effectiveSendInterval's
			// "nothing advertised yet" fallback instead of inheriting this
			// connection's now-stale rate.
			c.serverSendInterval = 0
			// Per-connection too: the room's agreed capabilities, the clock
			// offset (a different relay has a different clock, and even the
			// same one restarted may have jumped), the outstanding ping
			// timings, and whether this session was a resumption. The resume
			// TOKEN deliberately survives — this is exactly the drop it
			// exists for.
			c.activeFeatures = nil
			c.resumed = false
			c.clock = clockSync{}
			// Reset with the clock it derives from: a new connection may have a
			// completely different offset, and carrying the old ceiling across
			// would freeze the new one until real time caught up.
			c.lastNowMs = 0
			c.pendingPings = nil
			// Roster is per-connection: player_ids are only meaningful within
			// the connection that assigned them. Welcome used to be the de
			// facto reset (it replaced the map wholesale), but it no longer
			// does -- see the Welcome case, which now merges so a Join that
			// arrives first isn't erased -- so the reset has to be explicit
			// here, or a stale id could outlive the connection that named it
			// and pass the trust check on the next one.
			c.roster = make(map[string]struct{})
		}
		retryGameID, retryAdapterVersion, retryBridgeConn := c.autoRetryGameID, c.autoRetryAdapterGameVersion, c.autoRetryBridgeConn
		c.mu.Unlock()

		if wasCurrent {
			c.dropAllRemotes()
		}

		// See autoRetryGameID's doc comment: only armed by a prior
		// ConnectRelayOnAdapterHello success, so this is a no-op for
		// cmd/meshghost-fakeadapter and core_test.go's direct ConnectRelay
		// callers.
		if wasCurrent && retryGameID != "" {
			go c.reconnectWithBackoff(retryGameID, retryAdapterVersion, retryBridgeConn)
		}
	})
	conn.OnReceive(func(payload []byte) { c.handleRelayMessage(payload, welcome, reject) })

	// A resume token from a previous session on this Core, if any. Presented
	// on every connect attempt: the relay silently ignores one it does not
	// recognise, so there is no need to know whether this is a reconnect.
	c.mu.Lock()
	resumeToken := c.resumeToken
	c.mu.Unlock()

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
		RoomCode:        roomCode,
		GameVersion:     gameVersion,
		MaxReceiveHz:    c.MaxReceiveHz,
		Features:        c.effectiveFeatures(),
		ResumeToken:     resumeToken,
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
				c.roster[id] = struct{}{}
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
			logResumeOutcome(w, hadToken)
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
		// The event/lease/escrow planes and Pong, which handleOnlineMessage
		// owns (internal/core/online.go). Anything it does not recognise
		// either — a message type from a newer relay — is ignored, the same
		// forward-compatibility posture as unknown fields.
		c.handleOnlineMessage(env)
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
		// Free the admission slot whether or not this connection owned the
		// relay: a Core whose adapter has gone is available again, which is
		// what lets a relaunched game reuse it instead of walking to a new
		// port every time.
		if c.attachedAdapter == nd {
			c.attachedAdapter = nil
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
			c.mu.Unlock()

			if err := c.ConnectRelayOnAdapterHello(h.GameID, h.GameVersion, nd); err != nil {
				// Release the slot claimed above: this connection never
				// became the adapter, so holding it would make the Core
				// permanently unavailable to anyone else.
				c.mu.Lock()
				if c.attachedAdapter == nd {
					c.attachedAdapter = nil
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

// effectiveSendInterval returns the slower of (the relay's advertised
// interval, this Core's own configured floor), falling back to
// DefaultMinSendInterval when neither exists. Slower, always: the relay's
// rate is prescriptive for a client that hasn't expressed a preference, but
// a client that deliberately set MinSendInterval did so because of its own
// connection, and the relay has no business overriding that upward. Caller
// holds c.mu. See the ADR in agent_docs/architecture.md.
func (c *Core) effectiveSendInterval() time.Duration {
	switch {
	case c.MinSendInterval > 0 && c.serverSendInterval > 0:
		if c.MinSendInterval > c.serverSendInterval {
			return c.MinSendInterval
		}
		return c.serverSendInterval
	case c.MinSendInterval > 0:
		return c.MinSendInterval
	case c.serverSendInterval > 0:
		return c.serverSendInterval
	default:
		return DefaultMinSendInterval
	}
}

// forwardLocalState stamps and sends state to the relay, if there is one.
// state == nil means "don't send this frame" (get_local_state()'s nil
// case). Actual sends are capped to effectiveSendInterval() regardless of
// how often the adapter calls in — see its own comment and
// DefaultMinSendInterval's. A dropped frame here is not stamped with
// seq/timestamp at all, so it never reaches the relay and never affects
// Core.seq's monotonic count.
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
	interval := c.effectiveSendInterval()
	elapsed := time.Since(c.lastSendAt)
	if c.lastSendAt.IsZero() {
		elapsed = interval // always allow the first send
	}
	if elapsed < interval {
		c.mu.Unlock()
		return
	}
	c.lastSendAt = time.Now()
	playerID := c.playerID
	c.mu.Unlock()

	st := *state
	st.PlayerID = playerID
	st.Seq = atomic.AddUint64(&c.seq, 1)
	// Stamped in the RELAY's clock domain when this room negotiated clock
	// sync, and in the local one otherwise (which is every room today, and
	// every room against an older relay). See nowMs and clockSync in
	// online.go: a receiver compares this against its own wall clock, so what
	// matters is that every member of a room measures against the same one,
	// not that any of them is right about the real time.
	st.Timestamp = c.nowMs()
	c.sendState(relay, st)
}

// tickRenders diffs the currently-interpolated remote set against what was
// rendered last tick, calling render for every current remote and despawn
// for every remote that dropped out — shared by both the bridge-wire path
// (onAdapterFrame) and the in-process path (onAdapterFrameInProcess) so the
// tick-model diff logic exists exactly once.
func (c *Core) tickRenders(rendered map[string]bool, render func(id string, st protocol.State), despawn func(id string)) {
	// The same clock domain outgoing timestamps are stamped in (nowMs), which
	// is the whole point: remote samples carry the sender's idea of the time,
	// and comparing them against a render time measured on a different clock
	// is what makes interpolation degrade silently under skew. With clock
	// sync off — every room today — this is exactly the previous
	// time.Now().Add(-delay).
	renderTime := c.nowMs() - c.InterpolationDelay.Milliseconds()
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

// sendHeartbeats sends a Ping on conn every Core.HeartbeatInterval
// (DefaultHeartbeatInterval unless overridden; a value <= 0 disables
// heartbeats entirely and this returns immediately) for as
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
	var nonce uint64
	// One ping is a heartbeat; a short burst of them is a clock measurement.
	// The burst comes first because the heartbeat interval is 20s, and an
	// offset estimate that takes a minute to form is useless for exactly the
	// minute a player is first walking into everyone else's view. Three
	// probes cost three messages and give the "keep the lowest RTT"
	// estimator something to choose between, which a single sample cannot.
	//
	// Spaced at the SHORTER of the probe interval and this Core's heartbeat
	// interval. A Core configured to heartbeat faster than the burst clearly
	// wants pings sooner, and spacing the burst wider than the heartbeat
	// would delay the very keepalive it is being sent alongside — which is
	// not hypothetical, it broke two existing heartbeat tests the moment the
	// burst was added with a fixed interval.
	probeGap := initialClockProbeInterval
	if interval < probeGap {
		probeGap = interval
	}
	for i := 0; i < initialClockProbeCount; i++ {
		if !c.sendPing(conn, &nonce) {
			return
		}
		time.Sleep(probeGap)
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		if !c.sendPing(conn, &nonce) {
			return
		}
	}
}

// sendPing sends one Ping on conn and records when it went out, so the
// matching Pong can be turned into a round-trip time and a clock offset.
// Returns false once conn is no longer this Core's relay connection, or the
// send fails — in both cases sendHeartbeats should stop.
func (c *Core) sendPing(conn transport.Transport, nonce *uint64) bool {
	c.mu.Lock()
	stillCurrent := c.relay == conn
	c.mu.Unlock()
	if !stillCurrent {
		return false
	}
	*nonce++
	payload, err := json.Marshal(protocol.Ping{Nonce: *nonce})
	if err != nil {
		return true
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypePing, Payload: payload})
	if err != nil {
		return true
	}
	// Recorded before the send, not after: a send that blocks briefly is part
	// of the round trip a client actually experiences, and stamping
	// afterwards would quietly subtract it and bias every estimate low.
	c.recordPingSent(*nonce, time.Now())
	return conn.Send(env) == nil
}

// discoverTransportTimeout bounds the whole "what do you serve?" exchange.
// Short on purpose: this sits in front of every connection attempt when
// transport is "auto", and a relay that cannot answer promptly is one we
// should stop waiting on and just connect to over tcp.
const discoverTransportTimeout = 3 * time.Second

// resolveTransport decides what this Core actually dials.
//
// **The handshake is always tcp, and no config setting can change that.**
// Core.Transport is not "how to connect" but "what to move to once
// connected": tcp means stay put, and udp or quic mean upgrade if the relay
// offers them. That inversion buys three things at once — a client never
// needs to be told which port a transport lives on (quic's differs, and
// guessing is impossible), the one leg that must work is always the
// transport that works everywhere and is readable while debugging, and a
// misconfigured preference degrades to a working tcp session instead of a
// timeout.
//
// A tcp preference short-circuits: there is nothing to upgrade to, so the
// single connection made is already the tcp one, and asking would cost a
// round trip to learn nothing.
//
// The returned error is non-nil only when the relay could not be reached
// over tcp at all — which is exactly the error the caller would have
// produced itself, so it is passed up rather than papered over. Every other
// failure (old relay, refused room code, malformed answer) returns tcp at
// the configured address, letting the real connect attempt surface the real
// problem.
func (c *Core) resolveTransport(addr, gameID, room, displayName, roomCode, gameVersion string) (netx.Kind, string, error) {
	if c.Transport == netx.TCP {
		return netx.TCP, addr, nil
	}

	offers, err := c.queryTransports(addr, gameID, room, displayName, roomCode, gameVersion)
	if err != nil {
		return netx.TCP, addr, err
	}
	kind, dialAddr := c.chooseTransport(addr, offers)
	return kind, dialAddr, nil
}

// queryTransports performs the tcp handshake leg: connect, ask what the
// relay serves, hang up without joining.
//
// Not joining is the whole point. Joining first and upgrading afterwards
// would make every other player in the room watch this one leave and
// rejoin, because the relay assigns a fresh player_id per connection and
// agent_docs/contract.md guarantees no session resumption.
//
// An error is returned only for an unreachable relay. Anything else yields
// a nil list, meaning "nothing to upgrade to".
func (c *Core) queryTransports(addr, gameID, room, displayName, roomCode, gameVersion string) ([]protocol.TransportOffer, error) {
	netConn, err := netx.Dial(netx.TCP, addr, discoverTransportTimeout)
	if err != nil {
		return nil, err
	}
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
	defer conn.Close()

	replies := make(chan protocol.Envelope, 1)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}
		select {
		case replies <- env:
		default:
		}
	})

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
		RoomCode:        roomCode,
		GameVersion:     gameVersion,
		QueryOnly:       true,
	})
	if err != nil {
		return nil, nil
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		return nil, nil
	}
	if err := conn.Send(env); err != nil {
		return nil, nil
	}

	select {
	case reply := <-replies:
		switch reply.Type {
		case protocol.TypeTransports:
			var t protocol.Transports
			if err := json.Unmarshal(reply.Payload, &t); err != nil {
				return nil, nil
			}
			return t.Offers, nil
		case protocol.TypeWelcome:
			// An older relay: it does not know query_only, so it treated
			// this as a real hello and joined us. Nothing to upgrade to, so
			// use tcp. The connection is closed on return, which such a
			// relay reports to the room as a leave — one spurious
			// join/leave against pre-2026-08-16 relays only, and the price
			// of the field being additive rather than a version bump.
			log.Printf("core: relay at %s does not support transport discovery (older build) — using tcp", addr)
			return nil, nil
		default:
			// A reject (wrong room code, wrong version, ...). Let the real
			// connect attempt surface it, with its reason, rather than
			// duplicating that logic here.
			return nil, nil
		}
	case <-time.After(discoverTransportTimeout):
		return nil, nil
	}
}

// chooseTransport picks the best offered transport and rebuilds the address
// to dial.
//
// Only the port comes from the relay; the host is always the one the user
// configured. That is what lets discovery work through NAT and port
// forwarding — a relay bound to 0.0.0.0 has no idea which address reaches
// it, but the client just connected to one, so it already knows.
func (c *Core) chooseTransport(addr string, offers []protocol.TransportOffer) (netx.Kind, string) {
	if len(offers) == 0 {
		return netx.TCP, addr
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return netx.TCP, addr
	}

	byKind := map[string]protocol.TransportOffer{}
	for _, o := range offers {
		if o.Port > 0 && o.Port < 65536 {
			byKind[o.Kind] = o
		}
	}

	// An explicit preference is honoured exactly, and only that one is
	// considered — a client asking for quic must not silently land on udp,
	// which would swap an encrypted session for one that cannot be
	// encrypted at all. netx.Auto is the only value that ranks.
	wants := []netx.Kind{c.Transport}
	if c.Transport == netx.Auto {
		wants = netx.AutoPreference
	}

	for _, want := range wants {
		if want == netx.TCP {
			return netx.TCP, addr
		}
		o, ok := byKind[want.String()]
		if !ok {
			continue
		}
		chosen := net.JoinHostPort(host, strconv.Itoa(o.Port))
		log.Printf("core: relay offers %s — using %s at %s", offerList(offers), want, chosen)
		return want, chosen
	}

	// Asked for something this relay does not serve. Staying on tcp is
	// right — the session works, which a timeout would not — but say so,
	// because otherwise a user who deliberately chose quic for encryption
	// would silently get an unencrypted session with nothing to indicate it.
	log.Printf("core: this relay does not offer %s (it offers %s) — staying on tcp",
		c.Transport, offerList(offers))
	return netx.TCP, addr
}

func offerList(offers []protocol.TransportOffer) string {
	parts := make([]string, 0, len(offers))
	for _, o := range offers {
		parts = append(parts, fmt.Sprintf("%s:%d", o.Kind, o.Port))
	}
	return strings.Join(parts, ", ")
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
	// SendUnreliable, not Send: this is the state plane, which
	// agent_docs/contract.md defines as lossy and latest-wins. On tcp
	// there is no difference at all. On a datagram transport it means a
	// lost sample is superseded by the next one ~50ms later instead of
	// being retransmitted — and a retransmitted position would arrive
	// stale and out of order, which is worse than the gap it fills. Every
	// other message this Core sends stays on Send. See the transport ADR
	// in agent_docs/architecture.md.
	if err := relay.SendUnreliable(env); err != nil {
		log.Printf("core: send state to relay failed: %v", err)
	}
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
