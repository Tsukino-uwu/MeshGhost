// Command meshghost-fakeadapter is the Phase 5 proof: it drives a real Core
// entirely in-process, via core.Adapter, against a fake ghost that walks in
// a circle — no game, no bridge socket, no emulator, and (checked by this
// file's own import list) nothing under adapters/. Run two instances
// against the same relay/room to see each print the other's circling
// position, the same milestone Phase 4 proved on screen with two real
// BizHawk clients, but headless.
package main

import (
	"flag"
	"log"
	"math"
	"os"
	"os/signal"
	"sync"
	"time"

	"meshghost/internal/core"
	"meshghost/internal/protocol"
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

	mu        sync.Mutex
	lastPrint map[string]time.Time
}

func (a *circleAdapter) GetLocalState() (protocol.State, bool) {
	t := time.Since(a.start).Seconds()
	angle := 2 * math.Pi * t / a.periodSeconds
	return protocol.State{
		AreaID:   "fake-arena",
		Position: []float64{a.radiusUnits * math.Cos(angle), a.radiusUnits * math.Sin(angle)},
		Anim:     "walking",
	}, true
}

func (a *circleAdapter) RenderRemote(playerID string, state protocol.State) {
	a.mu.Lock()
	last, seen := a.lastPrint[playerID]
	due := !seen || time.Since(last) >= a.logInterval
	if due {
		a.lastPrint[playerID] = time.Now()
	}
	a.mu.Unlock()
	if due {
		log.Printf("render_remote %s at %.2f,%.2f (area=%s anim=%s)", playerID, state.Position[0], state.Position[1], state.AreaID, state.Anim)
	}
}

func (a *circleAdapter) DespawnRemote(playerID string) {
	a.mu.Lock()
	delete(a.lastPrint, playerID)
	a.mu.Unlock()
	log.Printf("despawn_remote %s", playerID)
}

func main() {
	relayAddr := flag.String("relay", "127.0.0.1:7777", "relay address to connect to")
	room := flag.String("room", "fake", "room name to join")
	name := flag.String("name", "fake-ghost", "display name to advertise to the relay")
	radius := flag.Float64("radius", 10, "circle radius in position units")
	period := flag.Float64("period", 4, "seconds per full revolution")
	tick := flag.Duration("tick", 16*time.Millisecond, "how often to drive a frame (~60fps default)")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay, "interpolation delay for remote ghosts")
	logEvery := flag.Duration("log-every", 500*time.Millisecond, "minimum time between console prints per remote (the core still ticks at -tick regardless)")
	flag.Parse()

	c := core.New()
	c.InterpolationDelay = *interp
	if err := c.ConnectRelay(*relayAddr, "faketest", *room, *name, 5*time.Second); err != nil {
		log.Fatalf("meshghost-fakeadapter: %v", err)
	}
	log.Printf("meshghost-fakeadapter: connected to relay %s as %s in room %q, circling radius=%.1f period=%.1fs",
		*relayAddr, c.PlayerID(), *room, *radius, *period)

	adapter := &circleAdapter{
		start:         time.Now(),
		radiusUnits:   *radius,
		periodSeconds: *period,
		logInterval:   *logEvery,
		lastPrint:     make(map[string]time.Time),
	}

	stop := make(chan struct{})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		close(stop)
	}()

	c.RunAdapter(adapter, *tick, stop)
	log.Println("meshghost-fakeadapter: stopped")
}
