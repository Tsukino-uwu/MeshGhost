// Package core is the game-agnostic client: it owns the relay connection, the snapshot and interpolation buffer, and
// remote-player tracking. It talks to the relay through transport.Transport and to an adapter over the bridge, never
// to game memory or a rendering primitive.
//
// The adapter always drives: it calls in once per frame by sending a LocalState, and the core answers that same call
// with already-interpolated RenderRemote and DespawnRemote pushes for every known remote.
//
// This package never imports anything under adapters/ and never branches on game_id or any other opaque field.
//
// The Go API follows module semver, but what the version marks is the wire protocol: third-party use of these
// packages is untested, so pin a version if it must not move. Running meshghost.exe beside a game and speaking the
// bridge is the tested route.
package core

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// RejectError wraps a relay's protocol.Reject so callers can tell an explained refusal (wrong room code, version
// mismatch, a full room) from a dial error or a timeout without string-matching. See IsPermanentRejectErr.
type RejectError struct {
	Reason string
	// Code and Retryable are the machine-readable half of the refusal; a relay older than the code field sends
	// neither, which is what isPermanentReject's prose fallback is for.
	Code      string
	Retryable bool
}

func (e *RejectError) Error() string {
	return fmt.Sprintf("core: relay refused connection: %s", e.Reason)
}

// AlreadyServingError is a refusal this Core makes itself: a bridge hello asked for a different game_id than the one
// this process is already connected as, and a Core holds one relay session with one game identity. It is not a
// RejectError because the relay was never asked and the message reaches the player; IsPermanentRejectErr reports
// true for both.
type AlreadyServingError struct {
	Connected string // the game_id this Core is already serving
	Requested string // the game_id the new hello asked for
}

func (e *AlreadyServingError) Error() string {
	return fmt.Sprintf("core: already connected to the relay as game %q, cannot also serve %q on the same process", e.Connected, e.Requested)
}

func asRejectReason(err error) (reason string, ok bool) {
	var rejErr *RejectError
	if errors.As(err, &rejErr) {
		return rejErr.Reason, true
	}
	return "", false
}

func asReject(err error) (*RejectError, bool) {
	var rejErr *RejectError
	if errors.As(err, &rejErr) {
		return rejErr, true
	}
	return nil, false
}

// isPermanentRejectReason is the prose fallback for a relay older than reject codes. It names the retryable set, so
// an unknown reason from a future relay stays permanent.
func isPermanentRejectReason(reason string) bool {
	switch reason {
	case protocol.ReasonServerFull, protocol.ReasonRateLimited:
		// A room empties when someone leaves; a reconnecting client re-reads send_hz and may fit under the cap.
		return false
	}
	return true
}

// isPermanentReject reads a known code first, then the relay's retryable flag for a code this build has never seen
// (so a newer relay can add a refusal), then the prose. A hostile relay gains nothing by claiming retryable: the
// ServerFull prose already lets it.
func isPermanentReject(reason, code string, retryable bool) bool {
	if code != "" {
		if known, ok := protocol.RetryableForCode(code); ok {
			return !known
		}
		return !retryable
	}
	return isPermanentRejectReason(reason)
}

// RoomCodeRetryInterval is how often a room-code refusal, permanent in every other sense, is tried again: a client
// cannot tell a wrong code from an impostor or a host who restarted without the code, and both heal by themselves.
// One attempt a minute stays inside the relay's per-address allowance of wrong codes. A var for tests.
var RoomCodeRetryInterval = time.Minute

// IsRoomCodeRefusalErr reports whether err is a room-code refusal, from the relay or decided locally by the proof.
func IsRoomCodeRefusalErr(err error) bool {
	rej, ok := asReject(err)
	return ok && rej.Code == protocol.CodeInvalidRoomCode
}

// IsPermanentRejectErr reports whether err is a refusal a retry will not fix: a relay Reject with such a reason, or
// this Core's own AlreadyServingError. Exported for a caller with its own retry loop (cmd/meshghost's eager -game
// path).
func IsPermanentRejectErr(err error) bool {
	var serving *AlreadyServingError
	if errors.As(err, &serving) {
		return true
	}
	rej, ok := asReject(err)
	return ok && isPermanentReject(rej.Reason, rej.Code, rej.Retryable)
}

// DefaultInterpolationDelay is how far behind the newest samples the core renders remotes, to absorb network jitter:
// a ghost driven by the game's own movement can only start a step once told the peer moved, and whatever slack this
// leaves shows as a hitch. 450ms serves the worst link a shipped build must survive; a closer link can lower it.
//
// packaging/release/config.json sets its own value for every packaged player and packaging/config-overrides may
// differ per game, so change them with this; cmd/meshghost/shippedconfig_test.go fails when they disagree.
const DefaultInterpolationDelay = 450 * time.Millisecond

// DefaultLocalGhostDelay is the render delay for a ghost this core invented, a replay or chaser: a local sample never
// crossed a network. Not zero, or render time lands on the newest sample and holds, a stair-step at the feed rate;
// 25ms is one or two intervals at a game's frame rate. Derived per buffer it would go non-monotone under a hitch.
const DefaultLocalGhostDelay = 25 * time.Millisecond

// DefaultIdleKeepalive is how often an unchanged state is sent anyway once change suppression is dropping repeats.
// It bounds how stale a receiver's copy can get, so it must stay well under DefaultInterpolationDelay.
const DefaultIdleKeepalive = 250 * time.Millisecond

// DefaultRemoteStaleAfter is how long a peer may be silent before its ghost is despawned. A live peer restates itself
// every DefaultIdleKeepalive, so twelve of them in silence is a client that is gone, without waiting for the
// transport's own drop detection.
const DefaultRemoteStaleAfter = 3 * time.Second

// DefaultRedundancyMinInterval is the send interval at and above which every state also carries the sample before it
// (protocol.StatePrev) as loss cover. The gate is the interval, not the transport, because that decides whether one
// lost packet is visible: at 15Hz it is a 67ms hole, at 60Hz a frame.
const DefaultRedundancyMinInterval = 40 * time.Millisecond

// DefaultMinSendInterval is the fallback send interval when neither the relay advertised a rate nor MinSendInterval
// is set (an older relay without Welcome.SendHz). Derived from protocol.DefaultSendHz so the two cannot drift, it
// keeps an adapter that calls in every frame well under the relay's flood cap.
const DefaultMinSendInterval = time.Second / protocol.DefaultSendHz

// DefaultMaxReceiveHz is the receive cap a Core requests in Hello.MaxReceiveHz when its caller set none. Zero means
// uncapped, the only safe default: capping by default would silently degrade every ghost.
const DefaultMaxReceiveHz = 0

// DefaultHeartbeatInterval is how often a Ping goes out on an otherwise quiet relay connection. With no state to send
// nothing else keeps it alive, and transport.DefaultIdleTimeout (60s) would close it.
const DefaultHeartbeatInterval = 20 * time.Second

// InitialReconnectBackoff and MaxReconnectBackoff bound every automatic relay reconnect: start at one second, double,
// stop at fifteen. The core and cmd/meshghost share the cadence; on a permanent rejection the core logs and stops,
// cmd/meshghost exits.
const (
	InitialReconnectBackoff = 1 * time.Second
	MaxReconnectBackoff     = 15 * time.Second
)

// NextReconnectBackoff returns the next delay after cur, clamped to MaxReconnectBackoff.
func NextReconnectBackoff(cur time.Duration) time.Duration {
	return nextBackoffWithin(cur, MaxReconnectBackoff)
}

func nextBackoffWithin(cur, max time.Duration) time.Duration {
	if cur >= max {
		return max
	}
	if next := cur * 2; next < max {
		return next
	}
	return max
}

// reconnectBackoffBounds is this Core's retry cadence, its own values where set. They are fields so a test can run an
// outage of any length on a 20ms ceiling.
func (c *Core) reconnectBackoffBounds() (initial, max time.Duration) {
	initial, max = InitialReconnectBackoff, MaxReconnectBackoff
	if c.ReconnectInitialBackoff > 0 {
		initial = c.ReconnectInitialBackoff
	}
	if c.ReconnectMaxBackoff > 0 {
		max = c.ReconnectMaxBackoff
	}
	// A ceiling below the floor reads as a bug rather than a setting.
	if max < initial {
		max = initial
	}
	return initial, max
}

// DefaultDialTimeout is ConnectRelay's timeout when its own is <=0. It matches transport.DefaultDialTimeout so a
// caller that sets neither gets one number end to end.
const DefaultDialTimeout = transport.DefaultDialTimeout

// Adapter is an in-process host interface for the fake adapter (cmd/meshghost-fakeadapter) and tests, which prove
// the core has no game-specific leaks without a socket. Real adapters speak the bridge protocol instead.
type Adapter interface {
	// GetLocalState returns the current local snapshot; ok == false means don't send this frame, like a
	// bridge.LocalState with a nil State.
	GetLocalState() (state protocol.State, ok bool)

	// RenderRemote upserts a remote ghost's state, once per core tick for every known remote, not only on new data.
	RenderRemote(playerID string, state protocol.State)

	// DespawnRemote removes a remote ghost.
	DespawnRemote(playerID string)
}

// transportDialFailuresBeforeGivingUp is how many consecutive failed dials of one transport stop automatic selection
// choosing it; one failure is ambiguous (see Core.transportDialFailures).
const transportDialFailuresBeforeGivingUp = 2

// Core is the game-agnostic client: one relay connection, a bridge listener accepting adapter connections, and a
// per-remote-player interpolation buffer.
type Core struct {
	relay transport.Transport
	// relayOut is the current relay connection's outbound queue and the only path a frame takes to the relay
	// (relaywriter.go says why the frame path may not write the socket). Guarded by mu.
	relayOut  *relayWriter
	playerID  string
	relayGame string // game_id this Core is connected to the relay as, once connected
	seq       uint64

	lastStateDropLog atomic.Pointer[time.Time]

	// relayOwner is the bridge connection responsible for the current c.relay; only its disconnect may close it. Set
	// by ConnectRelayOnAdapterHello on a hello that connects, or by onAdapterFrame for the first bridge connection to
	// drive a frame through an unclaimed relay (the eager -game path, where the relay connects first).
	relayOwner transport.Transport

	// attachedAdapter is the one bridge connection allowed to drive this Core, decided at hello. It is kept apart from
	// relayOwner, which only decides whose disconnect may tear down the relay.
	attachedAdapter transport.Transport
	// writers is the outbound queue per bridge connection (adapterwriter.go), so a slow adapter costs superseded ghost
	// positions rather than the session. writerMu is never c.mu: enqueue runs on the frame path and from chasers.
	writerMu sync.Mutex
	writers  map[transport.Transport]*adapterWriter
	// bridgeWriteTimeout is the write deadline on every bridge connection; zero means transport.DefaultWriteTimeout.
	bridgeWriteTimeout time.Duration

	// RelayAddr, Room, DisplayName and DialTimeout are where and as whom ConnectRelay dials. ConnectRelayOnAdapterHello
	// uses them on the first bridge hello when the game is not known at startup, so set them before ServeBridge.
	RelayAddr   string
	Room        string
	DisplayName string
	// ReconnectInitialBackoff and ReconnectMaxBackoff override the reconnect cadence; 0 means the package defaults.
	ReconnectInitialBackoff time.Duration
	ReconnectMaxBackoff     time.Duration

	// NameColor is this player's own nametag colour as "#RRGGBB" (protocol.SanitizeNameColor); empty means no
	// preference. Ignored when DisplayName is empty.
	NameColor string
	// RoomCode is the shared secret a coded relay requires; empty against a relay with no code.
	RoomCode string
	// GameVersion overrides the version the adapter reported; empty means use the adapter's.
	GameVersion string
	DialTimeout time.Duration
	// Transport selects how ConnectRelay reaches the relay; the zero value is netx.TCP. The adapter bridge is loopback
	// TCP whatever this says.
	Transport netx.Kind
	// KnownRelays remembers which relay is which: every leg to a relay is TLS, and the relay's certificate is checked
	// against what this store holds for the address (trust on first use). Nil means an in-memory store allocated on
	// first use, so no path trusts blindly; cmd/meshghost sets a file-backed one that survives a relaunch.
	KnownRelays *KnownRelays
	// MaxReceiveHz asks the relay to forward each peer's state at most this often; zero means uncapped. A request,
	// not a guarantee: an older relay ignores it and Welcome does not echo it.
	MaxReceiveHz int

	// OnRelayConnected, if set, is called once after ConnectRelayOnAdapterHello connects; ConnectRelay never calls it.
	OnRelayConnected func(gameID string)

	relayConnectMu sync.Mutex // serializes ConnectRelayOnAdapterHello dials

	// InterpolationDelay overrides DefaultInterpolationDelay for this Core. Adapters never see it.
	InterpolationDelay time.Duration

	// ReplayName and ReplayColor become a recording's header "name" and "color", what a replay ghost's nametag shows.
	// Empty falls back to DisplayName and NameColor, then to an unnamed clip.
	ReplayName  string
	ReplayColor string

	// ReplayDelta writes only the extras that changed since the previous sample, carrying the rest forward on load.
	// Only the samples change shape; the header a player hand-edits stays as it is.
	ReplayDelta bool

	// ReplayGzip writes recordings as .ndjson.gz instead of .ndjson; both loaders read either. Off by default: a gzip
	// stream cut short when the game closes is refused whole by ordinary tools, while a plain file loses nothing.
	ReplayGzip bool

	// ReplayInputs also records what the player pressed, as a separate track in replay/inputs/. Off by default, as
	// every new capability ships. On, the input ring runs from attach so save-last can export it after the fact. A
	// track never plays back as a ghost: it lives in a subfolder so neither replay scanner picks it up.
	ReplayInputs bool

	// Offline means this Core never dials a relay. The bridge still binds and the adapter still attaches, so
	// recording, replays and chasers all work. A config re-read may change it; read it through offline().
	Offline bool

	// LocalInterpolationDelay overrides DefaultLocalGhostDelay for this Core; zero means zero, as tests need.
	LocalInterpolationDelay time.Duration

	// MinSendInterval is this Core's own floor on how often it sends; zero means adopt the relay's advertised rate.
	// effectiveSendInterval takes the slower of the two, so the relay can never speed this Core past its choice.
	MinSendInterval time.Duration
	lastSendAt      time.Time

	// RedundancyMinInterval gates the loss cover (DefaultRedundancyMinInterval when zero; negative turns it off): a
	// state carries the sample before it only when the effective send interval is at least this long.
	RedundancyMinInterval time.Duration
	// lastSentWire is the last state handed to the transport, seq and timestamp included, so the next one can carry
	// it as its prev. sendMu is held from stamping through sending so two adapter frames cannot interleave.
	sendMu       sync.Mutex
	lastSentWire *protocol.State

	// RemoteStaleAfter is how long a peer may send nothing before its ghost is despawned. Zero means
	// DefaultRemoteStaleAfter; negative disables aging out and trusts a Leave to arrive.
	RemoteStaleAfter time.Duration

	// Predict picks how a ghost is carried past its newest sample: a straight line from the last velocity, or a curve
	// with acceleration. Empty means PredictLinear. Only consulted when Extrapolate is positive.
	Predict PredictMode

	// extrapolation, dry and transit are render diagnostics, guarded by mu, which remoteStatesAt already holds.
	extrapolation extrapolationMeter
	dry           dryMeter
	transit       transitMeter
	// DryLog, when set, receives at most one line a second naming the samples around a dry render (dev only).
	// dryLoggedAt is the nowMs of the last line, guarded by mu.
	DryLog      func(string)
	dryLoggedAt int64

	// Curve picks how a position between two samples is computed: a straight line, or a Catmull-Rom spline through
	// four. Empty means CurveLinear. Like Extrapolate, a per-game judgement made on screen.
	Curve CurveMode

	// Extrapolate is how far past the newest sample a peer may be drawn by continuing its last velocity; zero holds
	// the newest sample. Opt-in per game: it hides part of InterpolationDelay and pays with a correction whenever a
	// peer does not do what was predicted, so it means little at the shipped delay.
	Extrapolate time.Duration

	// Correction is the time constant over which a ghost slides from where it was drawn to where a new sample puts
	// it, instead of jumping. Zero, what ships, is a jump. It only matters for a render past the newest sample: a loss
	// gap, or any Extrapolate window. Judged on screen like Curve and Extrapolate.
	Correction time.Duration

	// IdleKeepalive is how often a state identical to the last one sent goes out anyway; change suppression drops the
	// rest. A keepalive rather than silence so the relay can tell quiet from gone, a late joiner gets a state within
	// this bound, and a lost packet on udp costs at most this long. Zero disables suppression.
	IdleKeepalive time.Duration

	// lastSentState is the last state sent with player_id, seq and timestamp zeroed, so it compares on what a
	// receiver would render. suppressedSinceSend decides the bracket re-statement. Both guarded by mu.
	lastSentState       *protocol.State
	suppressedSinceSend bool

	// serverSendInterval comes from the relay's Welcome.SendHz, or 0 before Welcome or from an older relay. Guarded
	// by mu and cleared on disconnect, so a reconnect never inherits a stale rate.
	serverSendInterval time.Duration

	// GhostCollision is this client's own preference, protocol.GhostCollisionDisabled or "". It is resolved against
	// the relay's policy by protocol.ResolveGhostCollision and the more restrictive wins, so "enabled" here never
	// overrides a host who turned it off.
	GhostCollision string

	// relayGhostCollision is the relay's Welcome policy. Guarded by mu; cleared on disconnect.
	relayGhostCollision string

	// relayPolicyKnown is whether relayGhostCollision came from a Welcome at all: an unset policy resolves to enabled,
	// so pushing one before the room has spoken would make ghosts solid in a room that disabled them. Guarded by mu.
	relayPolicyKnown bool

	// adapterReady is true once bridge_ready has been sent on the current adapter connection. Welcome arrives on the
	// relay goroutine and bridge_ready goes out on the adapter's, so this gate keeps a session_policy from reaching an
	// adapter before the bridge_ready it must follow. Guarded by mu.
	adapterReady bool

	// sentGhostCollision is the last value pushed to the adapter, so a re-resolve that changes nothing sends nothing.
	// Empty means never sent on this connection and is reset when an adapter attaches. Guarded by mu.
	sentGhostCollision string
	// sentRecordingStateKnown matters because the first state to send is false, the zero value: without it a freshly
	// attached adapter would never be told.
	sentRecordingState      bool
	sentRecordingStateKnown bool
	sentRecordingStartedMs  int64

	// HeartbeatInterval overrides DefaultHeartbeatInterval for this Core; <= 0 disables heartbeats.
	HeartbeatInterval time.Duration

	// settingsMu guards the replay and connection fields a config.json re-read may change while running; every read
	// goes through an accessor in settings.go.
	settingsMu  sync.RWMutex
	mu          sync.Mutex
	remotes     map[string]*remoteBuffer
	localAreaID string // this Core's own most recently known area_id, for cross-area filtering

	// stats are the counters behind Core.Stats: atomic adds on existing paths, never a lock or per-tick work. startedAt
	// is zero for a Core built as a literal, which Stats reports as an unknown rate.
	stats       coreStats
	startedAt   time.Time
	renderedNow int64

	// timeSrc is the clock this Core reads for logic whose other end is our own code, not a socket, process or human.
	// Nil means the wall clock; only tests set it, and clk() reads it without ever assigning it.
	timeSrc coreClock

	// roster is the set of player_ids seen via Welcome or Join; a State for any other id is dropped, so a hostile
	// relay cannot inject one. The value is when the seat was granted, on the injectable clock, so a seat with no
	// state behind it can be taken back: the age-out walks c.remotes and would never see it. Zero means unset.
	roster map[string]int64

	// reconnectBackoff and relaySessionUpAt carry the retry cadence across reconnect loops, which otherwise reset it
	// on every successful dial. resumeReconnectBackoff resets it when a session lasted at least as long as the wait
	// it was about to impose, so a relay restart resets and a welcome-then-drop escalates all the way.
	reconnectBackoff time.Duration
	relaySessionUpAt time.Time

	// welcomed is whether this connection has had its one Welcome. Not "is playerID set": the relay chooses playerID,
	// and an empty one would disable the second-Welcome guard.
	welcomed bool

	// agedOut is every id the age-out took a roster seat from without a Leave. Such a peer may only be paused (an
	// emulator that stopped its adapter), so a state from it retakes its seat through the same capped admission; an
	// id the relay never admitted is still refused. A Leave clears it.
	agedOut map[string]struct{}

	// localPeers is the set of ids this Core invented, replays and chasers. Each is also in the roster, or its state
	// would be dropped; this set marks its renders cosmetic.
	localPeers map[string]struct{}
	// The recorder tap (recorder.go). ReplayDir is the replay/ folder beside config.json; RecordOnLaunch records
	// while an adapter is attached; SaveLastSpan is how much the ring keeps for SaveLast.
	ReplayDir      string
	RecordOnLaunch bool
	SaveLastSpan   time.Duration
	// ReplayStartDelay is how long after the first in-game frame a replay starts when its header says 0s; a file's
	// start_delay overrides it.
	ReplayStartDelay time.Duration
	// ReplaySeek is how far one rewind or fast-forward moves when the caller gives no amount.
	ReplaySeek time.Duration
	// SplitTimes puts "+1.2s" on a replay ghost's nametag. Off by default: a tag that changes several times a second
	// is a visible behaviour a player opts into.
	SplitTimes bool
	rec        recorder
	ring       sampleRing
	tapArmed   uint32
	// The input track (inputrecorder.go) is a second, independent tap with its own atomic: folding it into tapArmed
	// would start feeding chasers nobody asked for (see rearmInputTap).
	inputRec      inputRecorder
	inputRing     inputRing
	inputMeta     inputMeta
	inputTapArmed uint32
	// Playback (replay.go): the loaded players, armed by StartReplays and launched by the first in-game frame.
	replayMu       sync.Mutex
	replays        map[string]*replayPlayer
	replaysPending uint32
	// The chaser pack (chaser.go): the player's own past following them. ChaserContact reaches the adapter as
	// session_policy.chaser_contact, which only an adapter that implements contact acts on.
	ChaserEnabled bool
	ChaserCount   int
	ChaserDelay   time.Duration
	ChaserSpacing time.Duration
	ChaserName    string
	ChaserColor   string
	ChaserContact ChaserContact
	// ChaserSpawnDelay is how long the player must have been moving before a chaser appears, so it never spawns on
	// top of a standing player. Zero means the chaser's own delay.
	ChaserSpawnDelay time.Duration
	chaserMu         sync.Mutex
	chasers          []*chaser
	// chaserHist is the pack's one shared copy of the player's recent past; nil with no pack.
	chaserHist *chaserHistory
	// chaserResetAtMs is when ResetChasers last started the pack over (0 = never); guarded by chaserMu.
	chaserResetAtMs int64
	// The chaser's gameplay clock: wall time minus every span the adapter reported the player frozen. Under frozenMu,
	// never c.mu: its readers already take c.mu for nowMs and must not nest it.
	frozenMu      sync.Mutex
	frozenSince   int64
	frozenTotalMs int64
	// lastChaserOfferMs is the gameplay stamp of the last sample handed to the chaser pack, which the tap thins to
	// what the chaser queues are sized for. Written only from the adapter-frame goroutine.
	lastChaserOfferMs int64
	// ticks and ticksStarted count render ticks at their end and start, atomically, so a waiter can ask for a tick
	// that began after some moment (localpeer.go's seek needs its despawn delivered before the re-feed).
	ticks        uint64
	ticksStarted uint64

	// permanentRejectGame and its siblings cache a refusal not worth retrying, checked before dialing so an adapter
	// that reconnects to the bridge every few seconds does not hammer the relay. Only a process restart clears it,
	// except a room-code refusal, which expires after RoomCodeRetryInterval.
	permanentRejectGame   string
	permanentRejectReason string
	permanentRejectCode   string
	permanentRejectAt     time.Time

	// lastConnectErr is the last logged connect failure; an identical one is not logged again, so a retrying adapter
	// does not flood the log while the relay comes up.
	lastConnectErr string

	// lastConnectErrLoggedAt and connectFailingSince make a still-failing dial repeat itself with how long it has
	// been failing, so a core dialing a dead address does not look like one that hung.
	lastConnectErrLoggedAt time.Time
	connectFailingSince    time.Time

	// autoRetryGameID and its siblings are set by ConnectRelayOnAdapterHello on every successful connect, and tell
	// ConnectRelay's OnDisconnect to start reconnectWithBackoff after a drop. A direct ConnectRelay leaves them empty
	// and so fails fast, as the fake adapter and the direct tests want.
	autoRetryGameID             string
	autoRetryAdapterGameVersion string
	autoRetryBridgeConn         transport.Transport

	// Features is the capability list this Core advertises in Hello.Features, on top of what the adapter asks for.
	// Empty by default: a room's feature set is matched exactly, so advertising unasked capabilities would refuse
	// every client not upgraded in lockstep.
	Features []string

	// adapterFeatures is what the adapter last requested, kept apart from Features so latching one into the other
	// cannot destroy the "not set" state.
	adapterFeatures []string

	// adapterMinProtocol is the protocol floor the attached adapter declared; zero means no opinion. The core applies
	// its own floor first, so this can only be stricter. Guarded by mu.
	adapterMinProtocol int

	// unusableTransports records transports whose dial failed on this machine (quic under Wine, whose UDP setup is
	// unsupported), so automatic selection stops choosing them. Only netx.Auto consults it: an explicit preference
	// gets a clear repeated error, never a silent downgrade. Guarded by mu; keyed by netx.Kind.String().
	unusableTransports map[string]bool

	// remoteNames maps a peer's player_id to its sanitized nametag; an absent id has no nametag. Held apart from the
	// interpolation buffer because a name arrives once and must reach an adapter that attaches later. Guarded by mu.
	remoteNames map[string]protocol.Nametag

	// transportDialFailures counts consecutive dial failures per transport. A dial only fails once tcp has reached
	// the relay, so one failure may be a restarting relay whose quic listener is not up yet; two in a row is not.
	// Reset by a successful dial. Guarded by mu; keyed by netx.Kind.String().
	transportDialFailures map[string]int

	// udpProbe overrides the can-this-machine-open-udp check for tests; nil means netx.UDPUsable.
	udpProbe func() bool

	// udpImpossibleLogged keeps the udp-is-impossible explanation to once per process: the answer cannot change.
	udpImpossibleLogged sync.Once

	// adapterRenderAllAreas mirrors the adapter's hello render_all_areas: the adapter translates or hides foreign
	// areas itself, so remoteStatesAt skips the cross-area filter. Reset on detach.
	adapterRenderAllAreas bool

	// adapterWantsOrientBracket mirrors the adapter's hello interpolate_orientation: render_remote carries the
	// orientation bracket only then, since an adapter with a discrete facing cannot use it. Reset on detach.
	adapterWantsOrientBracket bool

	// adapterWantsInputTracks mirrors the adapter's hello input_tracks: a replay streams its clip's input track as
	// remote_input only then, and otherwise never looks for one. Reset on detach.
	adapterWantsInputTracks bool

	// inputTrackScans counts replay loads that scanned replay/inputs/, so a test can prove an adapter that did not
	// ask cost no directory read. Atomic.
	inputTrackScans uint32

	// resumeToken is the single-use secret from the last Welcome, presented in a later Hello to reclaim this identity
	// after a drop. Kept across a disconnect, when it is needed, but cleared when the adapter goes away: that is a
	// real departure the room should see.
	resumeToken string

	// activeFeatures is the room's agreed feature set from Welcome.Features, not what this Core asked for. Every send
	// path gates on it, so a capability the room lacks fails with a clear error. Guarded by mu; cleared on disconnect.
	activeFeatures []string

	// resumed records whether the current session reclaimed a previous identity (Welcome.Resumed).
	resumed bool

	// lastNowMs is the highest value nowMs has returned, so the clock never moves backwards when the offset estimate
	// is revised down. Guarded by mu.
	lastNowMs int64

	// clock is this connection's estimate of the offset to the relay's clock: interp.go compares State.Timestamp with
	// the local clock, so peers whose clocks disagree would silently stop interpolating.
	clock clockSync

	// pendingPings maps a heartbeat nonce to when it was sent, so a Pong becomes a round-trip time.
	pendingPings map[uint64]time.Time

	// OnEvent, OnLeaseState and OnEscrowState, if set, receive the event plane and the two arbitration planes, for an
	// in-process host and tests. The messages reach an attached adapter over the bridge either way.
	OnEvent       func(ev protocol.Event)
	OnLeaseState  func(st protocol.LeaseState)
	OnEscrowState func(st protocol.EscrowState)
	// OnWorldState receives the world-custody plane, in the same role as the three above.
	OnWorldState func(st protocol.WorldState)

	// adapterGameVersion is the version the adapter last reported, kept apart from GameVersion so a reconnecting
	// adapter with a new version is advertised under it; ConnectRelay resolves the two per call.
	adapterGameVersion string
	// adapterGameID is the game_id the adapter last announced, kept whether or not the relay was reached: the
	// recorder's header names the game from it.
	adapterGameID string
}

// New creates a Core with no relay connection yet. Either call ConnectRelay before ServeBridge, or set the connection
// fields and let ConnectRelayOnAdapterHello connect when a bridge hello arrives. MinSendInterval stays zero: adopt
// the relay's advertised rate.
func New() *Core {
	return &Core{
		startedAt:               time.Now(), // wall-clock: reported to a human as uptime (stats.go)
		remotes:                 make(map[string]*remoteBuffer),
		InterpolationDelay:      DefaultInterpolationDelay,
		ReplayDelta:             true,
		ReplayGzip:              false,
		LocalInterpolationDelay: DefaultLocalGhostDelay,
		IdleKeepalive:           DefaultIdleKeepalive,
		HeartbeatInterval:       DefaultHeartbeatInterval,
		roster:                  make(map[string]int64),
	}
}

// relayRetry is what a disconnect needs to redial, read under the same lock that clears the session so a reconnect
// cannot be armed or disarmed in between.
type relayRetry struct {
	gameID             string
	adapterGameVersion string
	bridgeConn         transport.Transport
}

// reconnectLogIntervalNanos is how often a still-failing reconnect repeats its complaint. Atomic although only tests
// write it: a reconnect loop on a dead address outlives the test that started it and reads this during the next.
var reconnectLogIntervalNanos atomic.Int64

func init() { reconnectLogIntervalNanos.Store(int64(60 * time.Second)) }

func getReconnectLogInterval() time.Duration {
	return time.Duration(reconnectLogIntervalNanos.Load())
}

// setReconnectLogInterval is test-only; it returns the previous value to restore.
func setReconnectLogInterval(d time.Duration) time.Duration {
	return time.Duration(reconnectLogIntervalNanos.Swap(int64(d)))
}

// discoverTransportTimeout bounds the whole "what do you serve?" exchange. Short: it sits in front of every auto
// connection attempt, and a relay that cannot answer promptly is connected to over tcp.
const discoverTransportTimeout = 3 * time.Second

// remoteStaleAfter resolves RemoteStaleAfter, returning zero for "never age out". Caller holds c.mu.
func (c *Core) remoteStaleAfter() time.Duration {
	if c.RemoteStaleAfter == 0 {
		return DefaultRemoteStaleAfter
	}
	if c.RemoteStaleAfter < 0 {
		return 0
	}
	return c.RemoteStaleAfter
}
