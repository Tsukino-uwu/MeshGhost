package core

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// Fuzzing the SCHEDULE rather than the bytes: the seed picks the ORDER of
// attach/detach/drop/send events and the DELAYS between them, and the same
// invariant is required to hold at the end of every one of them.
//
// Why this exists (agent_docs/ideas.md, "Fuzz the SCHEDULE, not just the
// bytes"): every other fuzz target in this repo feeds a parser bytes, and
// every reconnect test runs ONE fixed sequence with fixed sleeps. The failures
// that actually reach a player are the other family -- "it only happens if the
// other player was already in the room", "it only happens 8-15 seconds in".
// The nametag bug of 2026-08-28 was exactly that: a peer already present took
// a different code path from one that joined while you watched, and no test
// varied which of the two it was.
//
// The whole thing is affordable only because the timings that matter are
// per-Core fields rather than constants -- RemoteStaleAfter at 60ms instead of
// 3s turns "peer silent for twice the stale window" into 120ms of real time,
// down the identical code path. Core.ReconnectInitialBackoff and
// ReconnectMaxBackoff (backoff_test.go) were made fields for this.
//
// It asserts an INVARIANT, never a script. A script is what makes a test like
// this brittle: any ordering may legitimately produce any intermediate state,
// so the only honest requirement is the one a player would state --
// **whatever happened, once both games are attached and sending, each one sees
// the other's ghost, under the other's name, and sees nothing else.**

// fuzzSchedule* are the compressed clock. Every one is a per-Core field, so
// nothing here is a special code path: it is the shipped path, faster.
const (
	fuzzScheduleStaleAfter   = 60 * time.Millisecond
	fuzzScheduleInterp       = 5 * time.Millisecond
	fuzzScheduleKeepalive    = 5 * time.Millisecond
	fuzzScheduleHeartbeat    = 10 * time.Millisecond
	fuzzScheduleBackoff      = 2 * time.Millisecond
	fuzzScheduleMaxBackoff   = 10 * time.Millisecond
	fuzzScheduleMaxSteps     = 10
	fuzzScheduleConvergeWait = 5 * time.Second
)

// fuzzScheduleDelays is the delay alphabet, in milliseconds. Deliberately not
// linear: most steps should land inside one send interval (where ordering
// races live), while the top entry is longer than fuzzScheduleStaleAfter so
// some schedules do age a ghost out and have to bring it back.
var fuzzScheduleDelays = [8]time.Duration{
	0, 0, time.Millisecond, 2 * time.Millisecond,
	5 * time.Millisecond, 10 * time.Millisecond, 25 * time.Millisecond, 120 * time.Millisecond,
}

// scheduleActor is one player: a lazily-connecting Core, its bridge address,
// and whichever fake adapter is currently attached to it (none, between a
// detach and the next attach).
type scheduleActor struct {
	t      *testing.T
	name   string
	core   *Core
	bridge string
	fa     *fakeAdapter
	pos    float64
}

func newScheduleActor(t *testing.T, relayAddr, name string) *scheduleActor {
	t.Helper()
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "fuzzroom", name, func(c *Core) {
		c.MinSendInterval = time.Millisecond
		c.InterpolationDelay = fuzzScheduleInterp
		c.IdleKeepalive = fuzzScheduleKeepalive
		c.RemoteStaleAfter = fuzzScheduleStaleAfter
		c.HeartbeatInterval = fuzzScheduleHeartbeat
		c.ReconnectInitialBackoff = fuzzScheduleBackoff
		c.ReconnectMaxBackoff = fuzzScheduleMaxBackoff
	})
	return &scheduleActor{t: t, name: name, core: c, bridge: bridgeAddr}
}

func (a *scheduleActor) attach() {
	if a.fa != nil {
		return
	}
	fa := dialFakeAdapter(a.t, a.bridge)
	a.t.Cleanup(func() { fa.conn.Close() })
	fa.hello("fuzzgame")
	a.fa = fa
}

// detach is the game closing: the adapter's socket goes away, which the core
// turns into a real Leave for the rest of the room.
func (a *scheduleActor) detach() {
	if a.fa == nil {
		return
	}
	a.fa.conn.Close()
	a.fa = nil
}

// dropRelay is the network blip: the relay socket dies under a still-running
// game, which is the case auto-reconnect exists for.
func (a *scheduleActor) dropRelay() {
	a.core.mu.Lock()
	conn := a.core.relay
	a.core.mu.Unlock()
	if conn != nil {
		conn.Close()
	}
}

// frame is one adapter tick. The position moves every time so that change
// suppression (ADR 0039) cannot be what keeps a state off the wire -- this
// test is about ordering, and a suppressed send would look like one.
//
// A failed send is NOT a test failure, unlike fakeAdapter.frame's own Fatalf.
// A core whose previous adapter's disconnect is still in flight answers the
// next hello with "busy" and hangs up, and a real adapter's answer to that is
// to dial again (agent_docs/contract.md's port walk) -- so this drops the
// connection and lets the next attach re-make it. What must still hold is that
// the room converges anyway, which is what the caller asserts.
func (a *scheduleActor) frame() {
	if a.fa == nil {
		return
	}
	select {
	case <-a.fa.rejects:
		a.detach()
		return
	default:
	}
	a.pos++
	st := protocol.State{AreaID: "zone-a", Position: []float64{a.pos, 0}, Anim: "idle"}
	payload, err := json.Marshal(bridge.LocalState{State: &st})
	if err != nil {
		a.t.Fatalf("marshal local_state: %v", err)
	}
	env, err := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
	if err != nil {
		a.t.Fatalf("marshal envelope: %v", err)
	}
	if err := a.fa.conn.Send(env); err != nil {
		a.detach()
		return
	}
	a.drain()
}

// drain empties the fake adapter's despawn channel. It is a BLOCKING send on
// the connection's own read goroutine (core_test.go), so a schedule that
// produced more despawns than its buffer holds would wedge that adapter, and
// the failure would then look like the core going silent.
func (a *scheduleActor) drain() {
	if a.fa == nil {
		return
	}
	for {
		select {
		case <-a.fa.despawns:
		default:
			return
		}
	}
}

// sees reports whether this actor's adapter is rendering exactly peer and
// nobody else, under peer's name. "Nobody else" is half the point: an identity
// left behind by a reconnect is a ghost of somebody who is not there.
func (a *scheduleActor) sees(peerID, peerName string) bool {
	if a.fa == nil || peerID == "" {
		return false
	}
	a.fa.mu.Lock()
	defer a.fa.mu.Unlock()
	if len(a.fa.rendered) != 1 {
		return false
	}
	if _, ok := a.fa.rendered[peerID]; !ok {
		return false
	}
	return a.fa.names[peerID].DisplayName == peerName
}

func (a *scheduleActor) describe() string {
	if a.fa == nil {
		return fmt.Sprintf("%s(id=%q, detached)", a.name, a.core.PlayerID())
	}
	a.fa.mu.Lock()
	defer a.fa.mu.Unlock()
	ids := make([]string, 0, len(a.fa.rendered))
	for id := range a.fa.rendered {
		ids = append(ids, fmt.Sprintf("%s(name=%q)", id, a.fa.names[id].DisplayName))
	}
	return fmt.Sprintf("%s(id=%q, rendering=[%s])", a.name, a.core.PlayerID(), strings.Join(ids, " "))
}

// scheduleOps names what a seed byte's low bits mean. Kept as a table so a
// failing corpus entry can be printed as the sequence it actually ran, which
// is the difference between a reproducible schedule and a hex string.
var scheduleOps = [8]string{
	"a.frame", "b.frame", "a.detach", "b.detach",
	"a.attach", "b.attach", "a.dropRelay", "b.dropRelay",
}

func FuzzSchedule(f *testing.F) {
	// The seeds are the orderings already known to matter, so a plain `go
	// test` run -- which replays the corpus rather than fuzzing -- covers
	// them: both present before either sends, one joining after the other is
	// settled, a relay blip under a running game, and a game closing and
	// relaunching.
	f.Add([]byte{0x04, 0x05, 0x00, 0x01})
	f.Add([]byte{0x04, 0x00, 0x00, 0xed, 0x00})
	f.Add([]byte{0x04, 0x05, 0x00, 0x01, 0x06, 0x00, 0x01})
	f.Add([]byte{0x04, 0x05, 0x00, 0x01, 0x02, 0x2c, 0x04, 0x00})
	f.Add([]byte{0x05, 0x04, 0xf6, 0x07, 0x03, 0x05, 0x01})

	f.Fuzz(func(t *testing.T, seed []byte) {
		if len(seed) == 0 {
			return
		}
		if len(seed) > fuzzScheduleMaxSteps {
			seed = seed[:fuzzScheduleMaxSteps]
		}

		s := relay.NewServer()
		s.SendHz = protocol.MaxSendHz
		relayAddr := startRelayWith(t, s)

		a := newScheduleActor(t, relayAddr, "alice")
		b := newScheduleActor(t, relayAddr, "bob")

		ran := make([]string, 0, len(seed))
		for _, step := range seed {
			op := step & 0x07
			who := a
			if op%2 == 1 {
				who = b
			}
			switch op {
			case 0, 1:
				who.frame()
			case 2, 3:
				who.detach()
			case 4, 5:
				who.attach()
			case 6, 7:
				who.dropRelay()
			}
			delay := fuzzScheduleDelays[(step>>3)&0x07]
			ran = append(ran, fmt.Sprintf("%s+%v", scheduleOps[op], delay))
			if delay > 0 {
				time.Sleep(delay)
			}
		}

		// Whatever the schedule left behind, both games are now running and
		// both are sending -- the state a player is in when they say "I still
		// can't see them". Everything above is allowed; this is not.
		deadline := time.Now().Add(fuzzScheduleConvergeWait)
		for time.Now().Before(deadline) {
			// Re-attached inside the loop, not once before it: a core that
			// refused this connection because the previous one had not
			// finished going away drops it again, and a real relaunched game
			// keeps trying too.
			a.attach()
			b.attach()
			a.frame()
			b.frame()
			if a.sees(b.core.PlayerID(), "bob") && b.sees(a.core.PlayerID(), "alice") {
				return
			}
			time.Sleep(2 * time.Millisecond)
		}
		t.Fatalf("after schedule [%s] the two never converged within %v:\n  %s\n  %s",
			strings.Join(ran, " "), fuzzScheduleConvergeWait, a.describe(), b.describe())
	})
}
