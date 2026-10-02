// Command meshghost-fakeadapter is the synthetic-peer load generator: it drives real Cores in-process, via
// core.Adapter or, with -bridge, over a real bridge socket, against fake ghosts that walk a circle, with no game and
// nothing under adapters/. Two instances on one relay and room each print the other's circling position.
//
// With -clients N it runs N independent Cores in one process, each its own relay connection. Against a relay alone
// that measures the relay's N^2 fan-out; joined to a room a real game client is in, it puts N ghosts on that client's
// screen, the only way to measure an adapter's per-ghost render cost.
//
// Nothing here knows any game: a game's peers are imitated by passing its game_id, area_id, position dimensionality
// and extras as flags, and the per-game values live in the dev-scripts launchers.
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

// circleAdapter satisfies core.Adapter with no game to read from: local state is a deterministic function of time,
// a circle of radiusUnits once every periodSeconds, read at the full tick rate (RunAdapter, or sendLoop under -bridge);
// console printing, the stand-in for a real adapter's redraw, is throttled to logInterval per remote.
type circleAdapter struct {
	start       time.Time
	radiusUnits float64
	// dimScale multiplies the circle offset per component; nil circles components 0 and 1 and holds the rest at
	// their center. A game may send one position twice at two scales, and holding the second pair still would stack
	// every peer on one spot.
	dimScale      []float64
	periodSeconds float64
	logInterval   time.Duration

	// phase spreads the clients along the circle: ghosts stacked on one point would understate the render cost and,
	// with ghost collision on, the physics cost.
	phase float64

	// dims is how many position components to send: 2 for a 2D game, 3 for a 3D one.
	dims   int
	center []float64

	// areaID must equal the real client's own area_id, or its core filters these ghosts out and the harness looks
	// broken.
	areaID string
	// churnAreaID is an area_id the real client is never in: during a churn window its core despawns this ghost
	// and respawns it after, exercising spawn cost rather than only steady-state rendering.
	churnAreaID string
	churnEvery  time.Duration
	churnFor    time.Duration
	// churnOffset staggers this client's churn window from its siblings', which would otherwise all despawn in
	// lockstep: one periodic spike instead of a real room's steady trickle.
	churnOffset time.Duration

	anim        string
	orientation json.RawMessage
	yawFollows  bool
	// facingFollows sends orientation as a cardinal string from the circle tangent, which a 2D grid adapter keys a
	// ghost's facing and walk animation off; without one a drawn ghost renders a static frame.
	facingFollows bool
	extras        map[string]any

	// quiet suppresses this client's per-remote render logging: with every client logging, N clients print N^2
	// lines a second.
	quiet bool

	// renders counts RenderRemote calls for the stats summary.
	renders atomic.Uint64

	mu        sync.Mutex
	lastPrint map[string]time.Time
	live      map[string]bool
	// stopPeriod and stopFraction: how often the synthetic peer stops, and for what fraction of that period.
	stopPeriod   float64
	stopFraction float64
}

// inChurnWindow reports whether this client should pretend to be in another area, from elapsed time alone so churn
// reproduces across runs.
func (a *circleAdapter) inChurnWindow(elapsed time.Duration) bool {
	if a.churnEvery <= 0 || a.churnFor <= 0 {
		return false
	}
	return (elapsed+a.churnOffset)%a.churnEvery < a.churnFor
}

func (a *circleAdapter) GetLocalState() (protocol.State, bool) {
	return a.stateAt(time.Since(a.start))
}

// travelled maps wall seconds to seconds of movement: move for (1-stopFraction) of each stopPeriod, then hold. It is
// the angle's clock rather than the angle, so a ghost resumes where it stopped instead of jumping, which would be a
// teleport, a different test.
func (a *circleAdapter) travelled(t float64) float64 {
	if a.stopPeriod <= 0 || a.stopFraction <= 0 {
		return t
	}
	moving := a.stopPeriod * (1 - a.stopFraction)
	whole := math.Floor(t / a.stopPeriod)
	within := t - whole*a.stopPeriod
	if within > moving {
		within = moving
	}
	return whole*moving + within
}

// defaultStopPeriod is 0, no stops. A stop is where an extrapolating interpolator overshoots and has to correct, which
// a constant-speed circle never shows; it is opt-in because a rig change that alters what a run means would make the
// recorded numbers incomparable. Stops are a pure function of elapsed time, so a run reproduces from its flags.
const defaultStopPeriod = 0.0
const defaultStopFraction = 0.25

// stateAt is GetLocalState with the clock passed in, so the circle, the facing and the churn window can be tested at a
// chosen point on the path.
func (a *circleAdapter) stateAt(elapsed time.Duration) (protocol.State, bool) {
	t := elapsed.Seconds()

	angle := 2*math.Pi*a.travelled(t)/a.periodSeconds + a.phase

	pos := make([]float64, a.dims)
	copy(pos, a.center)
	// Circle in the first two components; any third holds its center value, so ghosts orbit at their placed height.
	dx := a.radiusUnits * math.Cos(angle)
	dy := a.radiusUnits * math.Sin(angle)
	if len(a.dimScale) > 0 {
		// Each component moves by the offset times its own scale, so one restating another in other units stays
		// consistent with it.
		for i := range pos {
			sc := 0.0
			if i < len(a.dimScale) {
				sc = a.dimScale[i]
			}
			if i%2 == 0 {
				pos[i] = a.center[i] + dx*sc
			} else {
				pos[i] = a.center[i] + dy*sc
			}
		}
	} else {
		pos[0] = a.center[0] + dx
		if a.dims > 1 {
			pos[1] = a.center[1] + dy
		}
	}

	area := a.areaID
	if a.inChurnWindow(elapsed) {
		area = a.churnAreaID
	}

	orient := a.orientation
	if a.facingFollows {
		// The tangent of a counter-clockwise circle, quantised to the nearest cardinal like a walk on a tile grid.
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
		// Face along the tangent, which leads the radius by 90 degrees, so ghosts walk their path rather than slide.
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

// liveCount is how many distinct remotes this client renders, the rig's headless self-check: N clients should see
// at least N-1, and fewer means states are dropped (wrong area_id or game_id, or a relay at its client cap).
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

// parseCenter turns "x,y" or "x,y,z" into exactly dims components, padding with zeros so -center is optional.
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

// loadExtras parses -extras, a literal JSON object or @path to a file holding one. It checks only that it is an
// object: extras is free-form and game-specific by contract.
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

// cloneExtras gives each client its own copy, so N Cores never marshal one shared map that someone later mutates.
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

// peerAreaID spreads peer i over areas distinct area_ids, suffixed to base so a run stays traceable to the game it
// imitates. areas <= 1 returns base unchanged, so the default cannot alter a number measured before the flag.
func peerAreaID(base string, i, areas int) string {
	if areas <= 1 {
		return base
	}
	return fmt.Sprintf("%s-%d", base, i%areas)
}

func main() {
	relayAddr := flag.String("relay", "127.0.0.1:7777", "relay address to connect to")
	room := flag.String("room", "fake", "room name to join")
	name := flag.String("name", "fake-ghost", "display name to advertise to the relay (a -clients index is appended when >1)")
	nameColor := flag.String("name-color", "", "nametag colour for the synthetic peers, as a hex code like \"#F54927\" -- exercises the nametag colour path end to end")
	roomCode := flag.String("room-code", "", "shared secret to send the relay for room-code auth "+
		"-- only needed if the relay you're connecting to has one configured")
	gameID := flag.String("game-id", "faketest", "game_id to advertise -- must match the real client's "+
		"game_id (\"emerald\"/\"crystal\"/\"tevi\"/\"pseudoregalia\") to share a room with a real game")
	gameVersion := flag.String("game-version", "", "game_version to advertise to the relay")
	clients := flag.Int("clients", 1, "how many independent synthetic peers to run in this process, "+
		"each with its own Core and relay connection")
	radius := flag.Float64("radius", 10, "circle radius in position units")
	dimScale := flag.String("dim-scale", "",
		"comma-separated multiplier PER POSITION COMPONENT for the circle offset, e.g. "+
			"\"1,1,16,16\"  for a game that sends the same place as tiles AND as pixels "+
			"(Crystal does: {mapX, mapY, mapX*16, mapY*16}, and its painted tier draws from the "+
			"pixel pair). Empty (the default) keeps the historical behaviour: the first two "+
			"components circle and the rest hold their center value -- which silently stacks "+
			"every synthetic peer on one spot for any game that renders from a later pair")
	overBridge := flag.Bool("bridge", false,
		"drive each synthetic peer over a REAL bridge socket, the way a game does, instead of "+
			"calling the core in-process. Off, this tool calls adapter.RenderRemote as a direct Go "+
			"method call -- no marshal, no queue, no coalescing, no backpressure, no line framing -- "+
			"so it is structurally incapable of finding a bridge ceiling, which is why the "+
			"~350-ghost one stayed hidden until a real game hit it. On, every render crosses a "+
			"loopback socket as NDJSON and the frame path writes one too.\n"+
			"KEEP BOTH IN MIND WHEN READING A NUMBER: off is the mode that reaches hundreds of "+
			"peers in one process (no socket each) and is what loads the RELAY; on is the only "+
			"mode that loads the BRIDGE. Numbers from the two are not comparable, and every "+
			"summary line says which produced it")
	stopEvery := flag.Float64("stop-every", defaultStopPeriod,
		"how often the synthetic peer stops, in seconds; 0 (the default) never stops. "+
			"Try 7. A constant-speed circle is the most "+
			"flattering input an interpolator can be given -- no stops, no turns, every prediction "+
			"right and every correction zero -- and dev-scripts/README.md's own rule is that you "+
			"judge an interpolator on the CORRECTION. 0 restores the old always-moving circle, which "+
			"is what every measurement before 2026-09-11 was taken against")
	stopFor := flag.Float64("stop-fraction", defaultStopFraction,
		"what fraction of each -stop-every the peer spends standing still (0..1)")
	period := flag.Float64("period", 4, "seconds per full revolution")
	dims := flag.Int("dims", 2, "position components to send: 2 for a 2D game (Emerald), 3 for a 3D one")
	center := flag.String("center", "", "circle center as comma-separated position components, e.g. "+
		"\"1200,-3400,520\" -- put this near the real player so the ghosts are actually on screen")
	areaID := flag.String("area-id", "fake-arena", "area_id to send -- MUST equal the real client's own "+
		"area_id or its core filters these ghosts out and nothing renders")
	areas := flag.Int("areas", 1, "spread the synthetic peers over this many distinct area_ids: peer i gets "+
		"-area-id with a -N suffix, and 1 (the default) keeps every peer in -area-id exactly as before. "+
		"Dev-only, and the only way this rig can produce the room SHAPE relay-side area filtering exists for -- a "+
		"single-area room is that filter's worst case and saves nothing by construction. Note the ghosts stop being "+
		"visible to a real game client at anything above 1, since its core filters by area equality: this is for "+
		"measuring the relay, not for loading a renderer.")
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
	replayDir := flag.String("replay-dir", "", "play every replay file in <dir>/active/ as a ghost on client 0 (ADR 0047); "+
		"the circling adapter logs each render it gets, which is how you see it. Works offline")
	recordDir := flag.String("record", "", "record client 0's own state stream to this folder as a replay file "+
		"(ADR 0047; the file appears at the first frame and closes on exit). Works with -relay \"\" (offline)")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay, "interpolation delay for remote ghosts")
	// The render knobs meshghost.exe has beside -interp, same names and defaults, so a netsim link can be measured
	// headless.
	extrapolate := flag.Duration("extrapolate", 0, "prediction window past the newest sample, as meshghost -extrapolate")
	predict := flag.String("predict", string(core.PredictLinear), "linear, damped or accelerated, as meshghost -predict")
	correction := flag.Duration("correction", 0, "error-decay time constant, as meshghost -correction")
	localInterp := flag.Duration("local-interp", core.DefaultLocalGhostDelay,
		"render delay for a LOCAL ghost -- a replay or a chaser -- which is not the network one; "+
			"see core.DefaultLocalGhostDelay. -replay-dir here is how this is eyeballed offline")
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

	// Strict parse, as cmd/meshghost: a typo must not fall back to netx.Kind's tcp zero value.
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
	// Refused rather than clamped: measuring a different room shape than the one asked for is not evidence.
	if *areas < 1 {
		log.Fatalf("meshghost-fakeadapter: -areas must be at least 1, got %d", *areas)
	}
	centerVec, err := parseCenter(*center, *dims)
	if err != nil {
		log.Fatalf("meshghost-fakeadapter: %v", err)
	}
	var dimScaleVec []float64
	if *dimScale != "" {
		// Parsed as -center is: at most -dims components, any missing one zero.
		dimScaleVec, err = parseCenter(*dimScale, *dims)
		if err != nil {
			log.Fatalf("meshghost-fakeadapter: -dim-scale: %v", err)
		}
	}
	extras, err := loadExtras(*extrasSpec)
	if err != nil {
		log.Fatalf("meshghost-fakeadapter: %v", err)
	}

	stop := make(chan struct{})
	if *duration > 0 {
		time.AfterFunc(*duration, func() { stopOnce(stop) })
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		stopOnce(stop)
	}()

	// Resolved before any client connects: a room matches the feature set exactly, at the handshake.
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
		// Refused rather than warned: the credit plane is only events, so without them it would pass on nothing.
		log.Fatalf("meshghost-fakeadapter: -enemies needs %q in -features", protocol.FeatureEventV1)
	}
	// Two keys per entity: a reliable one for discrete state, a lossy one for position.
	if cpCfg.world.on && cpCfg.world.entities*2 > protocol.MaxWorldKeysPerRoom {
		// Refused rather than clamped: fewer entities than asked would pass a workload nobody chose.
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
		// The room still negotiates an unused capability and refuses every cosmetic client for the mismatch.
		log.Printf("meshghost-fakeadapter: warning: -features %v is set but no plane is being driven "+
			"-- pass -event-every, -lease-every or -trade-every to actually exercise them",
			featureList)
	}

	start := time.Now()
	adapters := make([]*circleAdapter, 0, *clients)
	cores := make([]*core.Core, 0, *clients)
	var planes []*controlPlane

	for i := 0; i < *clients; i++ {
		displayName := *name
		if *clients > 1 {
			displayName = fmt.Sprintf("%s-%d", *name, i)
		}

		c := core.New()
		c.InterpolationDelay = *interp
		c.LocalInterpolationDelay = *localInterp
		c.Extrapolate = *extrapolate
		c.Predict = core.PredictMode(*predict)
		c.Correction = *correction
		c.Transport = transportKind
		c.RelayAddr = *relayAddr
		c.Room = *room
		c.DisplayName = displayName
		c.NameColor = *nameColor
		c.RoomCode = *roomCode
		c.GameVersion = *gameVersion
		c.Features = featureList
		c.DialTimeout = 5 * time.Second
		if i == 0 && *replayDir != "" {
			c.ReplayDir = *replayDir
			c.StartReplays()
		}
		if i == 0 && *recordDir != "" {
			c.ReplayDir = *recordDir
			if path, err := c.StartRecording(); err != nil {
				log.Fatalf("meshghost-fakeadapter: -record: %v", err)
			} else {
				log.Printf("meshghost-fakeadapter: recording client 0 to %s", path)
			}
		}
		// The checkers attach before the connection: after it, writing c's callbacks races the read goroutine, and
		// the Welcome, first roster and any adoption snapshot would land unseen.
		var cp *controlPlane
		if cpCfg.anyPlaneOn {
			cp = newControlPlane(i)
			if cpCfg.world.on {
				// Built before attach, which is what registers its OnWorldState.
				cp.world = newWorldChecker(cpCfg.world, "", reportViolation)
			}
			if cpCfg.credit.on {
				// A different difficulty scale per client, or the ratchet never fires.
				cp.credit = newCreditChecker(cpCfg.credit, "", creditScale(i), reportViolation)
			}
			cp.attach(c)
			planes = append(planes, cp)
		}

		// One-shot connect-or-fail, unlike cmd/meshghost's retry: dev tooling fails fast at a bad address. The error
		// names client i, since a partial failure is most likely the relay's server-wide client cap.
		if *relayAddr == "" {
			// Offline: the state path still runs, as the recorder tap sits before the relay check.
			log.Printf("meshghost-fakeadapter: client %d running OFFLINE (-relay \"\"): nothing is sent anywhere", i)
		} else if err := c.ConnectRelay(*gameID); err != nil {
			log.Fatalf("meshghost-fakeadapter: client %d of %d: %v "+
				"(if this is a capacity refusal, raise the relay's -max-clients: it defaults to %d, server-wide)",
				i, *clients, err, 8)
		}

		a := &circleAdapter{
			start:         start,
			radiusUnits:   *radius,
			dimScale:      dimScaleVec,
			periodSeconds: *period,
			stopPeriod:    *stopEvery,
			stopFraction:  *stopFor,
			logInterval:   *logEvery,
			phase:         2 * math.Pi * float64(i) / float64(*clients),
			dims:          *dims,
			center:        centerVec,
			areaID:        peerAreaID(*areaID, i, *areas),
			churnAreaID:   *churnArea,
			churnEvery:    *churnEvery,
			churnFor:      *churnFor,
			churnOffset:   time.Duration(int64(*churnEvery) * int64(i) / int64(*clients)),
			anim:          *anim,
			yawFollows:    *yawFollows,
			facingFollows: *facingFollows,
			extras:        cloneExtras(extras),
			quiet:         i != 0,
			lastPrint:     make(map[string]time.Time),
			live:          make(map[string]bool),
		}
		adapters = append(adapters, a)
		cores = append(cores, c)
	}

	log.Printf("meshghost-fakeadapter: %d client(s) connected to relay %s in room %q as game_id=%q area_id=%q, "+
		"circling radius=%.1f period=%.1fs dims=%d",
		*clients, *relayAddr, *room, *gameID, *areaID, *radius, *period, *dims)
	if *areas > 1 {
		// A real game client renders nothing outside its own area, which looks like a broken rig.
		log.Printf("meshghost-fakeadapter: peers spread over %d area_ids (%q..%q) -- a real game client will "+
			"render only the share matching its own area",
			*areas, peerAreaID(*areaID, 0, *areas), peerAreaID(*areaID, *areas-1, *areas))
	}
	if *churnEvery > 0 {
		log.Printf("meshghost-fakeadapter: churn on -- each ghost spends %s of every %s in area_id %q",
			*churnFor, *churnEvery, *churnArea)
	}

	var wg sync.WaitGroup
	var bridgePeers []*bridgePeer
	if *overBridge {
		// Built before the tick goroutines start, so a dial failure is a startup error.
		for i := range cores {
			bp, err := runBridgePeer(cores[i], adapters[i], *gameID, *tick, stop)
			if err != nil {
				log.Fatalf("meshghost-fakeadapter: client %d: %v", i, err)
			}
			bridgePeers = append(bridgePeers, bp)
		}
		log.Printf("meshghost-fakeadapter: BRIDGE MODE -- %d peer(s) over real loopback sockets. "+
			"Every render crosses NDJSON framing, the core's writer queue and its coalescing, "+
			"which the in-process mode skips entirely. Numbers here are NOT comparable with "+
			"in-process ones.", len(bridgePeers))
	}
	for i := range cores {
		if *overBridge {
			break // the bridge peers have their own send and read goroutines
		}
		wg.Add(1)
		go func(c *core.Core, a *circleAdapter) {
			defer wg.Done()
			c.RunAdapter(a, *tick, stop)
		}(cores[i], adapters[i])
	}

	// The control plane runs alongside the circling ghosts: a bug that needs arbitration and state traffic on one
	// connection shows only then.
	if cpCfg.anyPlaneOn {
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

	// The peak-peer sampler is always on: a run that loses peers is the one nobody thought to turn a flag on for.
	watch := newPeerWatch(adapters)
	wg.Add(1)
	go func() {
		defer wg.Done()
		watch.run(stop)
	}()

	if *statsEvery > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ticker := time.NewTicker(*statsEvery)
			defer ticker.Stop()
			var prev uint64
			// The divisor is real elapsed time: a ticker fires late when the process is busy, so the nominal
			// interval would inflate the rate exactly as the rig falls behind.
			lastAt := time.Now()
			for {
				select {
				case <-stop:
					return
				case <-ticker.C:
					now := time.Now()
					elapsed := now.Sub(lastAt).Seconds()
					lastAt = now
					if elapsed <= 0 {
						continue
					}
					var total uint64
					for _, a := range adapters {
						total += a.renders.Load()
					}
					delta := total - prev
					prev = total
					// A lower bound: client 0 sees its N-1 siblings plus anyone else in the room, such as a real
					// game client. Churn moves clients in and out of the area on purpose.
					expect := fmt.Sprintf("expect >=%d", len(adapters)-1)
					if *churnEvery > 0 {
						expect = "varies: churn on"
					}
					// In-process renders count per tick per known remote whether or not anything arrived; bridge
					// renders are lines that crossed a socket.
					mode := "in-process"
					extra := ""
					if *overBridge {
						mode = "bridge"
						var lines, fails uint64
						for _, bp := range bridgePeers {
							lines += bp.linesIn.Load()
							fails += bp.sendFails.Load()
						}
						extra = fmt.Sprintf(" lines_in=%d send_fails=%d", lines, fails)
					}
					log.Printf("stats [%s]: clients=%d client0_remotes=%d (%s) renders=%d (%.0f/s across all clients)%s",
						mode, len(adapters), adapters[0].liveCount(), expect,
						total, float64(delta)/elapsed, extra)
					// Client 0's core line too, as meshghost.exe prints under -stats: the transit and buffer-dry
					// meters of the only headless receiver.
					log.Print(cores[0].Stats().String())
				}
			}
		}()
	}

	wg.Wait()
	checkAttrition(adapters, watch, *relayAddr != "", *churnEvery > 0 || *areas > 1)
	if len(planes) > 0 {
		summarize(planes, time.Since(start))
	}
	log.Println("meshghost-fakeadapter: stopped")
	// Every other failure here is already log.Fatalf; this one can follow a clean startup.
	if violations.Load() > 0 {
		os.Exit(1)
	}
}

var stopMu sync.Mutex
var stopped bool

// stopOnce closes stop, tolerating a second caller: -duration and an interrupt both close it, and a double close
// would print a stack trace in place of the summary.
func stopOnce(stop chan struct{}) {
	stopMu.Lock()
	defer stopMu.Unlock()
	if stopped {
		return
	}
	stopped = true
	close(stop)
}
