// Command meshghost-fakeadapter is the Phase 5 proof and the synthetic-peer
// load generator: it drives real Cores entirely in-process, via core.Adapter,
// against fake ghosts that walk in a circle — no game, no bridge socket, no
// emulator, and (checked by this file's own import list) nothing under
// adapters/. Run two instances against the same relay/room to see each print
// the other's circling position, the same milestone Phase 4 proved on screen
// with two real BizHawk clients, but headless.
//
// With -clients N it instead runs N independent Cores in one process, each
// its own relay connection, which is the load-test rig: N synthetic peers
// against a relay measures the relay's own N^2 fan-out cost (Room.Forward
// sends every state to every other member — see relay/limits.go's
// DefaultMaxClients), and N synthetic peers joining a room a REAL game client
// is also in puts N ghosts on that client's screen without needing N copies
// of the game. That second mode is the only way to measure an adapter's
// per-ghost render cost, which is the ceiling that actually binds; see
// dev-scripts/README.md.
//
// Nothing here knows anything about any specific game. To impersonate a real
// game's peers you pass its game_id, its area_id, its position
// dimensionality, and a blob of game-specific extras as flags — the
// per-game values live in dev-scripts launchers, not in this file, for the
// same reason core has no game branching.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// circleAdapter satisfies core.Adapter. It has no game to read from: local
// state is a deterministic function of wall-clock time, tracing a circle of
// radius radiusUnits, one full revolution every periodSeconds.
//
// RunAdapter still drives it at full tick rate (real per-frame semantics,
// per the tick model in agent_docs/contract.md — that's the thing being
// proven) but printing every tick would be unreadable at ~60fps, so
// printing to the console (this demo's stand-in for a real adapter's silent
// gui.drawImage redraw) is throttled to logInterval per remote.
type circleAdapter struct {
	start         time.Time
	radiusUnits   float64
	periodSeconds float64
	logInterval   time.Duration

	// phase offsets this client's position around the circle so N clients
	// spread out along it instead of stacking into one point — N ghosts
	// piled at identical coordinates would understate both the render cost
	// being measured and (for a game with ghost collision on, like
	// Pseudoregalia) the physics cost.
	phase float64

	// dims is how many position components to send: 2 for a 2D game, 3 for
	// a 3D one. Position is variable-length by design (see protocol.State).
	dims   int
	center []float64

	// areaID must equal the real client's own area_id for that client to
	// render these ghosts at all — core filters remote states by
	// area_id equality (Core.remoteStatesAt), so a mismatch silently
	// renders nothing and looks exactly like a broken harness.
	areaID string
	// churnAreaID is the area_id used during a churn window: a value the
	// real client is guaranteed NOT to be in, so its core despawns this
	// ghost and respawns it when the window ends. That exercises
	// spawn/despawn cost (for Pseudoregalia, a full pawn-clone
	// construction) rather than only steady-state rendering.
	churnAreaID string
	churnEvery  time.Duration
	churnFor    time.Duration
	// churnOffset staggers this client's churn window away from its
	// siblings'. Without it every client derives its window from the same
	// process start time and they all despawn and respawn in lockstep,
	// which is both unrealistic (real players don't change area on the
	// same frame) and misleading to measure: it produces one big periodic
	// spike instead of the steady trickle of spawn/despawn work a real
	// room generates.
	churnOffset time.Duration

	anim        string
	orientation json.RawMessage
	yawFollows  bool
	// facingFollows sends orientation as one of the four cardinal strings
	// ("up"/"down"/"left"/"right") chosen from the circle tangent, which is
	// what a 2D grid game's adapter expects -- Crystal and Emerald both key
	// a ghost's facing (and therefore its walk animation) off that string.
	// Without it a synthetic peer sends no orientation at all, and a drawn
	// ghost has no facing to animate: it renders a static forward-facing
	// frame, which reads as "animation is broken" when nothing is broken.
	facingFollows bool
	extras        map[string]any

	// quiet suppresses this client's own per-remote render logging. With N
	// clients in one process every client sees every other, so leaving all
	// of them logging is N^2 lines/sec; the rig logs from one client only.
	quiet bool

	// renders counts RenderRemote calls for the periodic throughput
	// summary. Atomic: RunAdapter's tick goroutine writes it, the summary
	// goroutine reads it.
	renders atomic.Uint64

	mu        sync.Mutex
	lastPrint map[string]time.Time
	live      map[string]bool
}

// inChurnWindow reports whether this client should currently pretend to be
// in a different area. Deterministic from elapsed time so every client's
// churn is reproducible across runs rather than depending on scheduling.
func (a *circleAdapter) inChurnWindow(elapsed time.Duration) bool {
	if a.churnEvery <= 0 || a.churnFor <= 0 {
		return false
	}
	return (elapsed+a.churnOffset)%a.churnEvery < a.churnFor
}

func (a *circleAdapter) GetLocalState() (protocol.State, bool) {
	return a.stateAt(time.Since(a.start))
}

// stateAt is GetLocalState with the clock passed in, so the deterministic
// part (the circle, the facing, the churn window) can be tested at a chosen
// point on the path instead of at whatever moment the test happened to run.
func (a *circleAdapter) stateAt(elapsed time.Duration) (protocol.State, bool) {
	t := elapsed.Seconds()
	angle := 2*math.Pi*t/a.periodSeconds + a.phase

	pos := make([]float64, a.dims)
	copy(pos, a.center)
	// Circle in the first two components (the horizontal plane in both 3D
	// games); any third component stays at its center value, so ghosts
	// orbit at the height they were placed rather than corkscrewing.
	pos[0] = a.center[0] + a.radiusUnits*math.Cos(angle)
	if a.dims > 1 {
		pos[1] = a.center[1] + a.radiusUnits*math.Sin(angle)
	}

	area := a.areaID
	if a.inChurnWindow(elapsed) {
		area = a.churnAreaID
	}

	orient := a.orientation
	if a.facingFollows {
		// The tangent of a counter-clockwise circle leads the radius by 90
		// degrees; quantise it to the nearest cardinal so it reads like a
		// character walking a path on a tile grid.
		tx, ty := -math.Sin(angle), math.Cos(angle)
		dir := "right"
		if math.Abs(tx) >= math.Abs(ty) {
			if tx < 0 {
				dir = "left"
			}
		} else if ty < 0 {
			dir = "up"
		} else {
			dir = "down"
		}
		orient = json.RawMessage(`"` + dir + `"`)
	}
	if a.yawFollows {
		// Face along the circle's tangent so the ghosts look like they're
		// walking their path rather than sliding sideways — the tangent of
		// a counter-clockwise circle leads the radius by 90 degrees.
		yaw := math.Mod(angle*180/math.Pi+90, 360)
		orient = json.RawMessage(fmt.Sprintf("[0,%.2f,0]", yaw))
	}

	return protocol.State{
		AreaID:      area,
		Position:    pos,
		Orientation: orient,
		Anim:        a.anim,
		Extras:      a.extras,
	}, true
}

func (a *circleAdapter) RenderRemote(playerID string, state protocol.State) {
	a.renders.Add(1)
	a.mu.Lock()
	a.live[playerID] = true
	last, seen := a.lastPrint[playerID]
	due := !a.quiet && (!seen || time.Since(last) >= a.logInterval)
	if due {
		a.lastPrint[playerID] = time.Now()
	}
	a.mu.Unlock()
	if due {
		log.Printf("render_remote %s at %s (area=%s anim=%s)", playerID, formatPos(state.Position), state.AreaID, state.Anim)
	}
}

func (a *circleAdapter) DespawnRemote(playerID string) {
	a.mu.Lock()
	delete(a.lastPrint, playerID)
	delete(a.live, playerID)
	a.mu.Unlock()
	if !a.quiet {
		log.Printf("despawn_remote %s", playerID)
	}
}

// liveCount is how many distinct remotes this client is currently
// rendering. This is the harness's own headless self-check: a rig of N
// clients should settle at N-1 here, and anything less means states are
// being dropped (wrong area_id, wrong game_id, or a relay at MaxClients)
// rather than the load test being genuinely light.
func (a *circleAdapter) liveCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.live)
}

func formatPos(pos []float64) string {
	parts := make([]string, len(pos))
	for i, v := range pos {
		parts[i] = strconv.FormatFloat(v, 'f', 2, 64)
	}
	return strings.Join(parts, ",")
}

// parseCenter turns "x,y" or "x,y,z" into a slice of exactly dims
// components, padding with zeros so -center is optional even in 3D.
func parseCenter(s string, dims int) ([]float64, error) {
	out := make([]float64, dims)
	if strings.TrimSpace(s) == "" {
		return out, nil
	}
	parts := strings.Split(s, ",")
	if len(parts) > dims {
		return nil, fmt.Errorf("center %q has %d components but -dims is %d", s, len(parts), dims)
	}
	for i, p := range parts {
		v, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return nil, fmt.Errorf("center component %q: %w", p, err)
		}
		out[i] = v
	}
	return out, nil
}

// loadExtras parses the -extras flag, which is either a literal JSON object
// or @path to a file containing one. Kept opaque and unvalidated beyond
// "is it a JSON object": extras is free-form and game-specific by contract
// (agent_docs/contract.md), so this binary has no business knowing which
// keys a given game expects.
func loadExtras(spec string) (map[string]any, error) {
	if strings.TrimSpace(spec) == "" {
		return nil, nil
	}
	raw := []byte(spec)
	if strings.HasPrefix(spec, "@") {
		b, err := os.ReadFile(strings.TrimPrefix(spec, "@"))
		if err != nil {
			return nil, fmt.Errorf("read extras file: %w", err)
		}
		raw = b
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("parse extras as a JSON object: %w", err)
	}
	return out, nil
}

// cloneExtras gives each client its own copy. The map is only ever read
// after startup, but N Cores marshalling one shared map concurrently is the
// kind of thing that is fine until someone adds a mutation, so each client
// owning its own is the cheap way to keep that true.
func cloneExtras(src map[string]any) map[string]any {
	if src == nil {
		return nil
	}
	out := make(map[string]any, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func main() {
	relayAddr := flag.String("relay", "127.0.0.1:7777", "relay address to connect to")
	room := flag.String("room", "fake", "room name to join")
	name := flag.String("name", "fake-ghost", "display name to advertise to the relay (a -clients index is appended when >1)")
	roomCode := flag.String("room-code", "", "shared secret to send the relay for room-code auth "+
		"-- only needed if the relay you're connecting to has one configured")
	gameID := flag.String("game-id", "faketest", "game_id to advertise -- must match the real client's "+
		"game_id (\"emerald\"/\"crystal\"/\"tevi\"/\"pseudoregalia\") to share a room with a real game")
	gameVersion := flag.String("game-version", "", "game_version to advertise to the relay")
	clients := flag.Int("clients", 1, "how many independent synthetic peers to run in this process, "+
		"each with its own Core and relay connection")
	radius := flag.Float64("radius", 10, "circle radius in position units")
	period := flag.Float64("period", 4, "seconds per full revolution")
	dims := flag.Int("dims", 2, "position components to send: 2 for a 2D game (Emerald), 3 for a 3D one")
	center := flag.String("center", "", "circle center as comma-separated position components, e.g. "+
		"\"1200,-3400,520\" -- put this near the real player so the ghosts are actually on screen")
	areaID := flag.String("area-id", "fake-arena", "area_id to send -- MUST equal the real client's own "+
		"area_id or its core filters these ghosts out and nothing renders")
	churnArea := flag.String("churn-area-id", "fake-elsewhere", "area_id used during churn windows (see -churn-every)")
	churnEvery := flag.Duration("churn-every", 0, "if set, each ghost periodically switches to -churn-area-id, "+
		"forcing the real client to despawn and respawn it -- measures spawn cost, not just steady-state render cost")
	churnFor := flag.Duration("churn-for", 2*time.Second, "how long each -churn-every window lasts")
	anim := flag.String("anim", "walking", "anim tag to send (opaque; must be one the target game's adapter understands)")
	extrasSpec := flag.String("extras", "", "game-specific extras as a literal JSON object, or @path to a file containing one")
	yawFollows := flag.Bool("yaw-follows-path", false, "send orientation as [pitch,yaw,roll] with yaw following the circle tangent")
	facingFollows := flag.Bool("facing-follows-path", false, "send orientation as a cardinal string "+
		"(\"up\"/\"down\"/\"left\"/\"right\") following the circle tangent -- what a 2D tile game's adapter reads")
	tick := flag.Duration("tick", 16*time.Millisecond, "how often to drive a frame (~60fps default)")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay, "interpolation delay for remote ghosts")
	logEvery := flag.Duration("log-every", 500*time.Millisecond, "minimum time between console prints per remote (the core still ticks at -tick regardless)")
	statsEvery := flag.Duration("stats-every", 0, "if set, print a periodic summary of remotes rendered and render rate")
	features := flag.String("features", "",
		"comma-separated capabilities to negotiate beyond the cosmetic ghost overlay, e.g. "+
			"\"event.v1,lease.v1,escrow.v1\". Turning any on makes these synthetic peers drive AND "+
			"CHECK that plane -- see -event-every/-lease-every/-trade-every and controlplane.go. "+
			"Every member of a room must pass the same set")
	eventEvery := flag.Duration("event-every", 0, "if set (and event.v1 is in -features), each "+
		"synthetic peer broadcasts an event this often. Every peer checks that the sequencer stamps "+
		"it receives strictly increase, which is the ordering guarantee the event plane exists to "+
		"provide")
	leaseEvery := flag.Duration("lease-every", 0, "if set (and lease.v1 is in -features), each peer "+
		"tries to claim -lease-key this often, holds it briefly, then releases. They all go for the "+
		"SAME key on purpose: contention is what makes the one-holder-at-a-time check mean anything")
	leaseKey := flag.String("lease-key", "contended-key", "the opaque key every peer contends for (see -lease-every)")
	leaseHold := flag.Duration("lease-hold", 2*time.Second, "TTL to request when claiming; a winner releases after half of it")
	tradeEvery := flag.Duration("trade-every", 0, "if set (and escrow.v1 is in -features), peers pair "+
		"off and run a full two-sided exchange this often, checking that every one reaches committed "+
		"or aborted and that an abort never delivers a deposit")
	worldAuthority := flag.String("world-authority", "sim", "the lease key world writes are made under "+
		"(see -host-entities); opaque, and a different key from -lease-key")
	hostEntities := flag.Int("host-entities", 0, "if set (and world.v1 and lease.v1 are both in "+
		"-features), every peer contends for -world-authority and whichever wins drives this many "+
		"synthetic entities into the world the relay holds custody of")
	entityHz := flag.Int("entity-hz", 10, "how often per second the holder writes each entity's position "+
		"(lossily -- discrete changes are written reliably regardless)")
	migrateEvery := flag.Duration("migrate-every", 0, "if set, the holder releases -world-authority this "+
		"often, forcing a real handover into contention. Without it the run tests custody but never "+
		"migration, which is the half that can actually go wrong")
	enemies := flag.Int("enemies", 0, "if set (and event.v1 is in -features), each peer damages this "+
		"many shared synthetic enemies over the event plane and checks the kill-credit invariants "+
		"(agent_docs/kill-credit.md). No game and no world plane needed: the whole model is "+
		"arithmetic over an ordered stream")
	hitEvery := flag.Duration("hit-every", 250*time.Millisecond, "how often each peer damages one enemy (see -enemies)")
	enemyResetEvery := flag.Duration("enemy-reset-every", 20*time.Second,
		"how often each peer advances one enemy to a new generation, which is what a leash, a wipe or "+
			"a respawn looks like on the ledger. 0 disables resets")
	hitDupEvery := flag.Duration("hit-dup-every", 3*time.Second,
		"how often each peer deliberately re-sends its previous damage report. A reliable transport "+
			"never duplicates, so without this the exactly-once applied-set is never exercised. 0 disables")
	playerDeathEvery := flag.Duration("player-death-every", 15*time.Second,
		"how often each peer spends a window dead, which is what gives 'tag it once then die' "+
			"something to be judged against. 0 means nobody ever dies")
	playerDeathFor := flag.Duration("player-death-for", 4*time.Second, "how long each -player-death-every window lasts")
	duration := flag.Duration("duration", 0, "stop and print the summary after this long. 0 (the "+
		"default) means run until interrupted, which is right when a human is watching and wrong "+
		"for a script -- a soak or CI job needs the process to end on its own and report, and "+
		"killing it with a signal from outside loses the summary and the exit code that goes with it")
	transportName := flag.String("transport", netx.TCP.String(),
		"which transport to move to after the (always-tcp) handshake: tcp, udp, quic, or auto. "+
			"Until this existed the rig never set Transport at all, so it inherited netx.Kind's tcp "+
			"zero value and the load tiers could only ever exercise tcp -- see dev-scripts/README.md")
	flag.Parse()

	// Strict parse, same as cmd/meshghost: a typo must not silently downgrade
	// the transport, which netx.Kind's tcp zero value would otherwise do
	// quietly.
	transportKind, err := netx.ParseKind(*transportName)
	if err != nil {
		log.Fatalf("meshghost-fakeadapter: %v", err)
	}

	if *clients < 1 {
		log.Fatalf("meshghost-fakeadapter: -clients must be at least 1, got %d", *clients)
	}
	if *dims < 1 {
		log.Fatalf("meshghost-fakeadapter: -dims must be at least 1, got %d", *dims)
	}
	centerVec, err := parseCenter(*center, *dims)
	if err != nil {
		log.Fatalf("meshghost-fakeadapter: %v", err)
	}
	extras, err := loadExtras(*extrasSpec)
	if err != nil {
		log.Fatalf("meshghost-fakeadapter: %v", err)
	}

	stop := make(chan struct{})
	if *duration > 0 {
		// time.AfterFunc rather than a goroutine with a select: there is
		// nothing else for it to wait on, and closing twice is impossible
		// because the signal handler below closes the same channel only if it
		// fires first -- both paths go through stopOnce.
		time.AfterFunc(*duration, func() { stopOnce(stop) })
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		stopOnce(stop)
	}()

	// Resolved before any client connects: the feature list travels in the
	// relay Hello, and a room's set is matched exactly, so getting this wrong
	// fails at the handshake rather than halfway through a run.
	featureList := protocol.NormalizeFeatures(strings.Split(*features, ","))
	cpCfg := controlPlaneConfig{
		clients:     *clients,
		eventEvery:  *eventEvery,
		leaseEvery:  *leaseEvery,
		leaseKey:    *leaseKey,
		leaseHold:   *leaseHold,
		tradeEvery:  *tradeEvery,
		statsEvery:  *statsEvery,
		featureList: featureList,
		world: worldConfig{
			on:        *hostEntities > 0,
			authority: *worldAuthority,
			entities:  *hostEntities,
			entityHz:  *entityHz,
			migrate:   *migrateEvery,
		},
		credit: creditConfig{
			on:         *enemies > 0,
			enemies:    *enemies,
			hitEvery:   *hitEvery,
			resetEvery: *enemyResetEvery,
			dupEvery:   *hitDupEvery,
			deathEvery: *playerDeathEvery,
			deathFor:   *playerDeathFor,
		},
	}
	if cpCfg.credit.on && !protocol.HasFeature(featureList, protocol.FeatureEventV1) {
		// Refused rather than warned: the credit plane is nothing but events,
		// so a run without the capability would negotiate a cosmetic room and
		// then check eight invariants against a stream that never arrives --
		// reporting a clean result for a test that did not run.
		log.Fatalf("meshghost-fakeadapter: -enemies needs %q in -features", protocol.FeatureEventV1)
	}
	// Two keys per entity: a reliable one for discrete state, a lossy one for
	// position. See world.go's entityKey for why they must not be one blob.
	if cpCfg.world.on && cpCfg.world.entities*2 > protocol.MaxWorldKeysPerRoom {
		// Refused rather than clamped: a run that silently drove fewer entities
		// than asked for would report a green result for a workload nobody
		// chose, and the cap is a protocol bound rather than a preference.
		log.Fatalf("meshghost-fakeadapter: -host-entities %d needs %d world keys (two per entity), "+
			"over protocol.MaxWorldKeysPerRoom (%d)",
			cpCfg.world.entities, cpCfg.world.entities*2, protocol.MaxWorldKeysPerRoom)
	}
	if cpCfg.world.on && !protocol.HasFeature(featureList, protocol.FeatureWorldV1) {
		log.Fatalf("meshghost-fakeadapter: -host-entities needs %q in -features (and %q with it)",
			protocol.FeatureWorldV1, protocol.FeatureLeaseV1)
	}
	cpCfg.anyPlaneOn = len(featureList) > 0 &&
		(*eventEvery > 0 || *leaseEvery > 0 || *tradeEvery > 0 || cpCfg.world.on || cpCfg.credit.on)
	if len(featureList) > 0 && !cpCfg.anyPlaneOn {
		// Advertising a capability and then never using it is a real and
		// confusing state: the room negotiates it, every cosmetic client is
		// refused for the mismatch, and nothing is actually exercised. Worth
		// a line rather than silence.
		log.Printf("meshghost-fakeadapter: warning: -features %v is set but no plane is being driven "+
			"-- pass -event-every, -lease-every or -trade-every to actually exercise them",
			featureList)
	}

	start := time.Now()
	adapters := make([]*circleAdapter, 0, *clients)
	cores := make([]*core.Core, 0, *clients)

	for i := 0; i < *clients; i++ {
		displayName := *name
		if *clients > 1 {
			displayName = fmt.Sprintf("%s-%d", *name, i)
		}

		c := core.New()
		c.InterpolationDelay = *interp
		c.Transport = transportKind
		c.RelayAddr = *relayAddr
		c.Room = *room
		c.DisplayName = displayName
		c.RoomCode = *roomCode
		c.GameVersion = *gameVersion
		c.Features = featureList
		c.DialTimeout = 5 * time.Second
		// Deliberately still the old one-shot connect-or-fail pattern, not
		// cmd/meshghost's retry-with-backoff: this is dev-only tooling meant to
		// fail fast and visibly if pointed at a bad address, not something that
		// needs to tolerate a slow-starting relay the way the real shipped
		// client does. See the ADR in agent_docs/architecture.md.
		//
		// Failing on client i also reports i, because the most likely cause
		// of a partial failure in a load test is the relay's MaxClients cap
		// (8 by default, server-wide across all rooms) rather than a bad
		// address — and that reads as "the rig is broken" unless the count
		// is right there in the message.
		if err := c.ConnectRelay(*gameID); err != nil {
			log.Fatalf("meshghost-fakeadapter: client %d of %d: %v "+
				"(if this is a capacity refusal, raise the relay's -max-clients: it defaults to %d, server-wide)",
				i, *clients, err, 8)
		}

		a := &circleAdapter{
			start:         start,
			radiusUnits:   *radius,
			periodSeconds: *period,
			logInterval:   *logEvery,
			phase:         2 * math.Pi * float64(i) / float64(*clients),
			dims:          *dims,
			center:        centerVec,
			areaID:        *areaID,
			churnAreaID:   *churnArea,
			churnEvery:    *churnEvery,
			churnFor:      *churnFor,
			churnOffset:   time.Duration(int64(*churnEvery) * int64(i) / int64(*clients)),
			anim:          *anim,
			yawFollows:    *yawFollows,
			facingFollows: *facingFollows,
			extras:        cloneExtras(extras),
			// Only client 0 narrates. See circleAdapter.quiet.
			quiet:     i != 0,
			lastPrint: make(map[string]time.Time),
			live:      make(map[string]bool),
		}
		adapters = append(adapters, a)
		cores = append(cores, c)
	}

	log.Printf("meshghost-fakeadapter: %d client(s) connected to relay %s in room %q as game_id=%q area_id=%q, "+
		"circling radius=%.1f period=%.1fs dims=%d",
		*clients, *relayAddr, *room, *gameID, *areaID, *radius, *period, *dims)
	if *churnEvery > 0 {
		log.Printf("meshghost-fakeadapter: churn on -- each ghost spends %s of every %s in area_id %q",
			*churnFor, *churnEvery, *churnArea)
	}

	var wg sync.WaitGroup
	for i := range cores {
		wg.Add(1)
		go func(c *core.Core, a *circleAdapter) {
			defer wg.Done()
			c.RunAdapter(a, *tick, stop)
		}(cores[i], adapters[i])
	}

	// The control plane runs alongside the circling ghosts rather than instead
	// of them, deliberately: a bug that only appears when arbitration traffic
	// shares a connection with 20Hz state traffic is exactly the kind this rig
	// exists to find, and running the two separately would never produce it.
	var planes []*controlPlane
	if cpCfg.anyPlaneOn {
		for i, c := range cores {
			cp := newControlPlane(i)
			if cpCfg.world.on {
				// Built before attach, which is what registers its OnWorldState.
				cp.world = newWorldChecker(cpCfg.world, "", reportViolation)
			}
			if cpCfg.credit.on {
				// Each client gets a DIFFERENT difficulty scale, which is the
				// whole point: a run where everyone agrees on maximum health
				// never ratchets, so it would check the easy half of the model
				// and call the hard half green.
				cp.credit = newCreditChecker(cpCfg.credit, "", creditScale(i), reportViolation)
			}
			cp.attach(c)
			planes = append(planes, cp)
		}
		log.Printf("meshghost-fakeadapter: control plane on -- capabilities %v, "+
			"events every %s, lease claims every %s (key %q), exchanges every %s",
			featureList, *eventEvery, *leaseEvery, *leaseKey, *tradeEvery)
		for _, cp := range planes {
			wg.Add(1)
			go cp.run(stop, &wg, cpCfg)
			if cpCfg.world.on {
				wg.Add(1)
				go cp.runWorld(stop, &wg, cpCfg.world)
			}
			if cpCfg.credit.on {
				wg.Add(1)
				go cp.runCredit(stop, &wg, cpCfg.credit)
			}
		}
	}

	if *statsEvery > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ticker := time.NewTicker(*statsEvery)
			defer ticker.Stop()
			var prev uint64
			for {
				select {
				case <-stop:
					return
				case <-ticker.C:
					var total uint64
					for _, a := range adapters {
						total += a.renders.Load()
					}
					delta := total - prev
					prev = total
					// liveCount from client 0 is the self-check: with N
					// clients all in one room it should read N-1. Churn
					// deliberately moves clients in and out of the area, so
					// the number is expected to vary then and a fixed
					// expectation would read as a failure rather than the
					// feature working.
					// A lower bound, not an equality: this client sees its
					// N-1 in-process siblings PLUS anyone else in the room,
					// which in the Tier 2 rig is the whole point (a real
					// game client is in there too). An equality check here
					// reported a healthy run as a failure.
					expect := fmt.Sprintf("expect >=%d", len(adapters)-1)
					if *churnEvery > 0 {
						expect = "varies: churn on"
					}
					log.Printf("stats: clients=%d client0_remotes=%d (%s) renders=%d (%.0f/s across all clients)",
						len(adapters), adapters[0].liveCount(), expect,
						total, float64(delta)/statsEvery.Seconds())
				}
			}
		}()
	}

	wg.Wait()
	if len(planes) > 0 {
		summarize(planes, time.Since(start))
	}
	log.Println("meshghost-fakeadapter: stopped")
	// A run that saw an invariant fail exits non-zero, so this can sit in a
	// script or a soak job instead of needing someone to read the log. Every
	// other failure in this program is already log.Fatalf; this is the one
	// that can happen after a completely successful startup.
	if violations.Load() > 0 {
		os.Exit(1)
	}
}

// stopOnce closes stop, tolerating a second caller.
//
// Both shutdown paths -- -duration elapsing and an interrupt arriving -- close
// the same channel, and a run that is interrupted just as its duration expires
// would otherwise panic on a double close while trying to shut down cleanly.
// That is a rare race whose only symptom would be a stack trace in place of
// the summary, which is precisely the output the run existed to produce.
var stopMu sync.Mutex
var stopped bool

func stopOnce(stop chan struct{}) {
	stopMu.Lock()
	defer stopMu.Unlock()
	if stopped {
		return
	}
	stopped = true
	close(stop)
}
