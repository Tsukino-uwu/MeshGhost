// Package core is the game-agnostic client: it owns the relay connection,
// the snapshot/interpolation buffer, and remote-player tracking. It talks
// to the relay via transport.Transport and to a real adapter via
// bridge — never to game memory or a rendering primitive directly.
// See agent_docs/contract.md's tick model: the adapter always drives (calls
// in once per frame, over the bridge, by sending a LocalState message); the
// core responds to that same call with already-interpolated RenderRemote /
// DespawnRemote pushes for every currently known remote.
//
// Hard rule (agent_docs/architecture.md, CLAUDE.md): this package must never
// import anything under adapters/, and must never branch on game_id or any
// other opaque field's contents.
//
// Pre-1.0: no API stability guarantee. This package may change shape in any
// release, third-party use is untested and unsupported, and running
// meshghost.exe beside your game and speaking the bridge is the route we
// actually test. See the repo README and docs/integrating.md.
//
// How this package fits the whole -- the life of a connection and of a state
// message, traced across all of them -- is docs/networking.md.
package core

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
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
// core renders remotes by default, to smooth over network jitter.
//
// MEASURED, 2026-08-19, and no longer the guess this comment used to admit to.
// Emerald was run with both renderers on screen at once
// (MESHGHOST_COMPARE_TIERS) and judged by the user at each setting: at 100ms an
// engine-driven ghost visibly chops while running; at 250ms, with nothing else
// changed, "it actually just looks 1:1:1 perfect now, drawn/player/spawn".
// agent_docs/verified.md has the run.
//
// Why a tile game is the demanding case, and why this value should hold for
// others: a ghost driven by the game's own movement can only START A STEP when
// it has been told the peer moved, and positions arrive at the room's send rate
// (DefaultMinSendInterval, 20Hz) rather than per frame. Whatever slack this
// delay does not absorb, the ghost shows as a hitch — and a tile game shows it
// hardest, because a step is a discrete commitment rather than a nudge an
// action game can blend away.
//
// The cost is honest and bounded: a peer renders a quarter-second behind where
// they actually are, a little over one tile at walking pace. That is the trade
// the user took (2026-08-19) on the grounds that this is the first time anyone
// had actually measured how the setting looks.
//
// CHANGING THIS MEANS CHANGING THREE FILES, not one: packaging/release/config.json and
// packaging/release/games/client-config-template.json carry explicit values that OVERRIDE this for
// every packaged player. Raising it here and not there is a default nobody receives -- which is
// exactly what happened on 2026-08-19 until the user asked what the release actually ships.
// cmd/meshghost/shippedconfig_test.go now fails when they disagree.
//
// Overridable per-Core (see Core.InterpolationDelay).
const DefaultInterpolationDelay = 250 * time.Millisecond

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
// with Pong (relay/relay.go) — this just wires the client side up
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
// interface; they speak the bridge wire protocol instead. This
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
	// only the relay connection: the adapter bridge is loopback TCP and no
	// adapter can observe this field. ("Always" until 2026-08-25, when that
	// turned out to be an assumption rather than a guarantee -- nothing
	// enforced it. cmd/meshghost now refuses a non-loopback -bridge bind
	// without an explicit override, because the bridge is unauthenticated.) See the transport ADR in
	// agent_docs/architecture.md.
	Transport netx.Kind
	// TLS turns on encryption for this Core's tcp legs — both the
	// discovery handshake and, when the session itself stays on tcp, the
	// session. The zero value (tlsx.Off) is plaintext, the behaviour every
	// pre-2026-08-19 Core had, so an unset Core is on the identical code
	// path.
	//
	// This matters even for a quic session: the discovery leg is always
	// tcp and always carries the room code, so a quic client with TLS off
	// still hands the room code to anyone watching the network. See the
	// TLS-over-tcp ADR in agent_docs/architecture.md.
	//
	// tlsx.Required refuses to talk to a relay that cannot handshake.
	// tlsx.Auto falls back to plaintext with a warning, and never after a
	// TLS leg to that same relay has already succeeded — see
	// resolveTransport.
	TLS tlsx.Mode
	// TLSFingerprint optionally pins the relay's self-signed certificate:
	// the SHA-256 the relay prints in its own log, compared out of band by
	// a human. Empty means encryption without authentication, which is
	// exactly what quic already gives (docs/security.md).
	TLSFingerprint string
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

	// GhostCollision is this client's OWN ghost-collision preference,
	// protocol.GhostCollisionDisabled or "" (no preference). Set from
	// client.ghost_collision. It is resolved against the relay's advertised
	// policy by protocol.ResolveGhostCollision, more restrictive wins — so
	// setting this to "disabled" turns ghost collision off for this player
	// whatever the room says, and setting it to "enabled" does NOT override
	// a host who turned it off. See the ADR in agent_docs/architecture.md.
	GhostCollision string

	// relayGhostCollision is what the relay advertised in Welcome, or "" for
	// an older relay or one whose operator set nothing. Guarded by mu; set
	// per connection in handleRelayMessage's Welcome case and cleared on
	// disconnect, exactly like serverSendInterval above, so a reconnect to a
	// differently-configured relay never inherits a stale policy.
	relayGhostCollision string

	// relayPolicyKnown reports whether relayGhostCollision came from an actual
	// Welcome, rather than being the zero value of a Core no relay has told
	// anything yet. The two are indistinguishable in the value itself -- a relay
	// predating the field also advertises "" -- but they must not resolve the
	// same way: ResolveGhostCollision("", "") is ENABLED, so pushing a policy
	// before the room has said anything tells the adapter to make ghosts solid
	// in a room that disabled them. Guarded by mu; set with relayGhostCollision
	// in the Welcome case and cleared with it on disconnect.
	//
	// The window is narrow and real: a relaunching game re-attaches, the attach
	// path finds the previous connection's c.relay still set and returns "already
	// connected", and that connection's teardown clears the policy in between
	// that check and the push. CI's race job caught it as
	// TestGhostCollisionRepeatedForANewAdapter reading "enabled" from a relay
	// that had only ever said "disabled" (2026-08-22).
	relayPolicyKnown bool

	// adapterReady is true once bridge_ready has been sent on the current
	// adapter connection. Guarded by mu.
	//
	// It exists because Welcome arrives on the RELAY read goroutine while
	// bridge_ready is sent on the ADAPTER read goroutine, and the relay
	// handshake is what ConnectRelayOnAdapterHello is waiting for — so
	// without this gate the two race, and a session_policy could reach an
	// adapter before the bridge_ready it is supposed to follow. An adapter
	// keys off bridge_ready to decide the core is usable at all, so anything
	// arriving first is entitled to be discarded. Caught by
	// TestGhostCollisionPolicyArrivesAfterBridgeReady, which failed
	// intermittently before this existed.
	adapterReady bool

	// sentGhostCollision is the last value actually pushed to the adapter, so
	// a re-resolve that changes nothing sends nothing. Guarded by mu. Empty
	// means "never sent on this bridge connection" and is reset when an
	// adapter attaches, so a NEW adapter always gets a policy even if the
	// resolved value happens to match what the previous one was told.
	sentGhostCollision string

	// HeartbeatInterval overrides DefaultHeartbeatInterval for this Core —
	// how often sendHeartbeats pings an otherwise-quiet relay connection.
	// <= 0 disables heartbeats entirely (used by core_test.go to reproduce
	// the pre-fix idle-timeout-churn bug directly).
	HeartbeatInterval time.Duration

	mu          sync.Mutex
	remotes     map[string]*remoteBuffer
	localAreaID string // this Core's own most recently known area_id, for cross-area filtering

	// stats are the diagnostic counters behind Core.Stats (core/stats.go).
	// Atomic adds on paths that already exist -- never a lock of their own,
	// and never per-tick work, since the state path runs at the adapter's
	// frame rate. startedAt is zero for a Core built as a literal (several
	// tests do), which Stats reports as an unknown rate rather than lying.
	stats       coreStats
	startedAt   time.Time
	renderedNow int64

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

	// lastConnectErrLoggedAt/connectFailingSince exist so that "logged again
	// only when the message changes" does not become "logged once, then
	// silence forever". A core whose relay address no longer has a relay on
	// it retries the identical dial every 15s indefinitely and, before this,
	// said so exactly once — so from the outside a core stuck dialing a dead
	// address was indistinguishable from a core that had given up or hung.
	// Found live 2026-08-19: one of four cores had been pointed at a
	// crowd-test relay on a private port by a config.json that was later
	// deleted; the relay was killed, the core dialed it for ten minutes in
	// total silence, and the first guess was a reconnect defect (there was
	// none — the loop was working the whole time and reconnected within 15s
	// once something listened again). connectFailingSince dates the outage so
	// the repeat can say how long this has been going on, which is the fact
	// that identifies it as stale config rather than a blip.
	lastConnectErrLoggedAt time.Time
	connectFailingSince    time.Time

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
	// and the Feature* constants in protocol/online.go.
	Features []string

	// adapterFeatures is what the adapter last requested in its bridge
	// Hello, kept separate from the exported Features (the user's own
	// setting) for the same reason adapterGameVersion is kept separate from
	// GameVersion: latching one into the other destroys the "not set" state
	// for the rest of the process.
	adapterFeatures []string

	// adapterRenderAllAreas mirrors the attached adapter's Hello
	// render_all_areas: when true, remoteStatesAt skips the cross-area
	// filter -- the adapter has declared it translates or hides foreign
	// areas itself. Reset with the rest of the adapter state on detach.
	adapterRenderAllAreas bool

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
	// OnWorldState receives the world-custody plane. Same role as the three
	// above: nil for every cosmetic caller, and the messages still reach an
	// attached adapter over the bridge either way.
	OnWorldState func(st protocol.WorldState)

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
		startedAt:          time.Now(),
		remotes:            make(map[string]*remoteBuffer),
		InterpolationDelay: DefaultInterpolationDelay,
		HeartbeatInterval:  DefaultHeartbeatInterval,
		roster:             make(map[string]struct{}),
	}
}

// clearRelayIfCurrent drops a half-established relay connection from the
// Core's state, so a handshake that failed leaves nothing behind that looks
// like a live session.
//
// ConnectRelay assigns c.relay as soon as the dial succeeds, well before it
// knows whether the relay will answer Welcome or Reject. Both failure paths
// Close the connection, and this used to be left entirely to the
// OnDisconnect callback installed above. That callback does NOT run
// synchronously: Close unblocks readLoop's Scan, but readLoop is a separate
// goroutine (transport.FromConn starts it), so onDisconnect fires whenever
// that goroutine is next scheduled. Until it does, c.relay is non-nil while
// c.relayGame is still "" — and ConnectRelayOnAdapterHello's
// already-connected guard reads exactly those two fields, so a caller
// retrying inside that window gets
//
//	core: already connected to the relay as game "", cannot also serve "x"
//
// instead of the real reject reason, and a permanent rejection stops being
// reported as one (IsPermanentRejectErr is false for that error, so
// reconnectWithBackoff keeps dialing something it has already been told is
// hopeless).
//
// Found by CI's race job 2026-08-17 as an intermittent
// TestConnectRelayOnAdapterHelloCachesPermanentReject failure. The window is
// normally microseconds, which is why -count=20 locally never reproduced it
// and the race detector's much slower scheduling did — the same shape as the
// join-broadcast race recorded in relay/relay.go.
//
// Guarded on c.relay == conn so a late call can never clear a NEWER
// connection's state, matching OnDisconnect's own wasCurrent check. Only
// c.relay is touched: a handshake that never reached Welcome never set
// playerID or relayGame, and the retry fields are armed only after a
// successful ConnectRelayOnAdapterHello, so there is nothing else here to
// unwind. OnDisconnect still runs afterwards and correctly no-ops.
// relayRetry is what a disconnect needs in order to redial: read under the
// same lock that clears the session, so a reconnect cannot be armed or
// disarmed in between.
type relayRetry struct {
	gameID             string
	adapterGameVersion string
	bridgeConn         transport.Transport
}

// reconnectLogInterval is how often a still-failing reconnect repeats its
// (identical) complaint. A var rather than a const only so a test can shrink
// it — nothing else writes it. One minute is chosen to be cheap enough to
// leave running indefinitely and frequent enough that a human reading the log
// during a session sees the problem within a minute of looking.
var reconnectLogInterval = 60 * time.Second

// discoverTransportTimeout bounds the whole "what do you serve?" exchange.
// Short on purpose: this sits in front of every connection attempt when
// transport is "auto", and a relay that cannot answer promptly is one we
// should stop waiting on and just connect to over tcp.
const discoverTransportTimeout = 3 * time.Second
