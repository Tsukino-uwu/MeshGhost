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

// Fuzzing the schedule rather than the bytes: the seed picks the order of attach, detach, drop and send events and the
// delays between them, and one invariant must hold at the end of every one. A fixed-sequence reconnect test cannot
// reach the failures that depend on which player was already in the room, or on timing.
//
// The timings that matter are per-Core fields, so compressing them runs the shipped code path, faster.
//
// It asserts an invariant, never a script, since any ordering may produce any intermediate state: whatever happened,
// once both games are attached and sending, each sees the other's ghost, under the other's name, and nothing else.

// fuzzSchedule* are the compressed clock: each is a per-Core field, so this is the shipped path, faster.
const (
	fuzzScheduleStaleAfter   = 200 * time.Millisecond
	fuzzScheduleInterp       = 15 * time.Millisecond
	fuzzScheduleKeepalive    = 10 * time.Millisecond
	fuzzScheduleHeartbeat    = 10 * time.Millisecond
	fuzzScheduleBackoff      = 2 * time.Millisecond
	fuzzScheduleMaxBackoff   = 10 * time.Millisecond
	fuzzScheduleMaxSteps     = 10
	fuzzScheduleConvergeWait = 5 * time.Second
)

// fuzzScheduleDelays is the delay alphabet, deliberately not linear: most steps land inside one send interval, where
// ordering races live, while the top entry is longer than fuzzScheduleStaleAfter, so some schedules age a ghost out and
// must bring it back. The clock stays longer than the machine's scheduling noise, or the target tests the CPU, not the
// code.
var fuzzScheduleDelays = [8]time.Duration{
	0, 0, time.Millisecond, 2 * time.Millisecond,
	5 * time.Millisecond, 20 * time.Millisecond, 60 * time.Millisecond, 250 * time.Millisecond,
}

// scheduleActor is one player: a lazily-connecting Core, its bridge, and the fake adapter attached to it, if any.
type scheduleActor struct {
	t      *testing.T
	name   string
	core   *Core
	bridge *pipeListener
	fa     *fakeAdapter
	pos    float64
}

// fuzzScheduleConfigBytes is how many leading seed bytes describe the room's configuration rather than its schedule:
// send rate, interpolation delay, curve and prediction, keepalive, per-peer receive cap.
const fuzzScheduleConfigBytes = 5

// fuzzSchedulePinnedConfig is the configuration the seeds replay their schedules under: MaxSendHz, a 15ms interpolation
// delay (index 2), linear curve and prediction, a 10ms keepalive (index 2), no receive cap.
var fuzzSchedulePinnedConfig = []byte{byte(protocol.MaxSendHz), 0x02, 0x00, 0x02, 0x00}

// fuzzScheduleSeedSchedules are the seed orderings, schedule bytes only.
var fuzzScheduleSeedSchedules = [][]byte{
	{0x04, 0x05, 0x00, 0x01},
	{0x04, 0x00, 0x00, 0xed, 0x00},
	{0x04, 0x05, 0x00, 0x01, 0x06, 0x00, 0x01},
	{0x04, 0x05, 0x00, 0x01, 0x02, 0x2c, 0x04, 0x00},
	{0x05, 0x04, 0xf6, 0x07, 0x03, 0x05, 0x01},
}

// fuzzScheduleInterps and fuzzScheduleKeepalives are the alphabets for the two timing knobs, small and short: every
// value must stay well inside fuzzScheduleConvergeWait, or a slow but correct configuration reports as a failure. The
// shipped interpolation delay is left out for that reason. What varies is the knobs' relationship (the delay against
// the sample gap, the keepalive against the stale window), which compression preserves.
var fuzzScheduleInterps = [4]time.Duration{
	0, 5 * time.Millisecond, 15 * time.Millisecond, 40 * time.Millisecond,
}

var fuzzScheduleKeepalives = [4]time.Duration{
	0, 5 * time.Millisecond, 10 * time.Millisecond, 50 * time.Millisecond,
}

// scheduleConfig is one room's worth of randomized settings.
type scheduleConfig struct {
	rawSendHz    int // as configured, before clamping: 0 and out-of-range are legal inputs
	rawReceiveHz int // per-peer receive cap, 0 meaning uncapped
	interp       time.Duration
	keepalive    time.Duration
	curve        CurveMode
	predict      PredictMode
	extrapolate  time.Duration
}

// String is what a failing corpus entry prints, so its configuration can be reproduced, as scheduleOps does for the
// ordering.
func (c scheduleConfig) String() string {
	return fmt.Sprintf("send_hz=%d(->%d) recv_hz=%d(->%d) interp=%v keepalive=%v curve=%s predict=%s extrapolate=%v",
		c.rawSendHz, protocol.ClampSendHz(c.rawSendHz),
		c.rawReceiveHz, protocol.ClampReceiveHz(c.rawReceiveHz),
		c.interp, c.keepalive, c.curve, c.predict, c.extrapolate)
}

// decodeScheduleConfig turns the seed's config prefix into settings by masking, never rejecting, so the whole byte
// space maps onto a legal configuration and no execution is wasted.
func decodeScheduleConfig(b []byte) scheduleConfig {
	cfg := scheduleConfig{
		// Raw and unclamped on purpose: 0 and >MaxSendHz are what a hostile or careless relay sends.
		rawSendHz: int(b[0]),
		interp:    fuzzScheduleInterps[b[1]&0x03],
		keepalive: fuzzScheduleKeepalives[b[3]&0x03],
		// A receive cap is a per-client choice; the byte's own value is used, so most bytes mean some cap, clamped as
		// the send rate is.
		rawReceiveHz: int(b[4]),
	}

	// Curve and prediction share one byte: one bit picks the curve, two the prediction mode, one turns extrapolation
	// on. They are packed because they compose, and the engine mutates one byte at a time.
	switch b[2] & 0x01 {
	case 0:
		cfg.curve = CurveLinear
	default:
		cfg.curve = CurveCatmullRom
	}
	switch (b[2] >> 1) & 0x03 {
	case 0:
		cfg.predict = PredictLinear
	case 1:
		cfg.predict = PredictDamped
	default:
		cfg.predict = PredictAccelerated
	}
	if (b[2]>>3)&0x01 == 1 {
		// Long enough to predict past the newest sample, short enough that a correction lands inside the converge
		// window.
		cfg.extrapolate = 20 * time.Millisecond
	}
	return cfg
}

// scheduleStaleAfter keeps the stale window coherent with the room's send rate. A window shorter than the gap between
// sends despawns a peer sending normally, a misconfiguration rather than a defect; four sample gaps, floored at
// fuzzScheduleStaleAfter, keeps every generated room one that must converge.
func scheduleStaleAfter(rawSendHz int) time.Duration {
	gap := time.Second / time.Duration(protocol.ClampSendHz(rawSendHz))
	if stale := 4 * gap; stale > fuzzScheduleStaleAfter {
		return stale
	}
	return fuzzScheduleStaleAfter
}

// newScheduleActorWith is newScheduleActor under a fuzzed configuration.
func newScheduleActorWith(t *testing.T, relayAddr, name string, cfg scheduleConfig) *scheduleActor {
	t.Helper()
	return newScheduleActorTuned(t, relayAddr, name, func(c *Core) {
		c.InterpolationDelay = cfg.interp
		c.IdleKeepalive = cfg.keepalive
		c.RemoteStaleAfter = scheduleStaleAfter(cfg.rawSendHz)
		c.MaxReceiveHz = protocol.ClampReceiveHz(cfg.rawReceiveHz)
		c.Curve = cfg.curve
		c.Predict = cfg.predict
		c.Extrapolate = cfg.extrapolate
	})
}

func newScheduleActor(t *testing.T, relayAddr, name string) *scheduleActor {
	t.Helper()
	return newScheduleActorTuned(t, relayAddr, name, nil)
}

// newScheduleActorTuned builds the actor with the compressed clock, then lets tune override what the fuzzed
// configuration varies, so the fixed-clock callers and the fuzzed one share one setup.
func newScheduleActorTuned(t *testing.T, relayAddr, name string, tune func(*Core)) *scheduleActor {
	t.Helper()
	// In-memory, not a socket: this target attaches and detaches adapters thousands of times per campaign.
	ln := newPipeListener()
	t.Cleanup(func() { ln.Close() })
	c := startCoreLazyServing(t, ln, relayAddr, "fuzzroom", name, func(c *Core) {
		c.MinSendInterval = time.Millisecond
		c.InterpolationDelay = fuzzScheduleInterp
		c.IdleKeepalive = fuzzScheduleKeepalive
		c.RemoteStaleAfter = fuzzScheduleStaleAfter
		c.HeartbeatInterval = fuzzScheduleHeartbeat
		c.ReconnectInitialBackoff = fuzzScheduleBackoff
		c.ReconnectMaxBackoff = fuzzScheduleMaxBackoff
		// Not compressed: many fuzz workers can starve a relay handshake past 2s, and a core that gives up on its
		// Welcome reports as a convergence failure unrelated to the schedule.
		c.DialTimeout = 10 * time.Second
		if tune != nil {
			tune(c)
		}
	})
	// A Core has no Close, so one left by a finished iteration keeps redialling every few milliseconds; once an
	// ephemeral port is recycled it joins a later test's relay and takes one of its client slots. Disarming is the
	// closest thing to stopping it. It runs after the adapter sockets close (Cleanup is LIFO), so it catches only what
	// the game closing missed.
	t.Cleanup(func() {
		c.mu.Lock()
		c.autoRetryGameID = ""
		c.autoRetryAdapterGameVersion = ""
		c.autoRetryBridgeConn = nil
		conn := c.relay
		c.relay = nil
		c.mu.Unlock()
		if conn != nil {
			_ = conn.Close()
		}
	})
	return &scheduleActor{t: t, name: name, core: c, bridge: ln}
}

func (a *scheduleActor) attach() {
	if a.fa != nil {
		return
	}
	// The bridge is an in-memory pipe, so this fails only when teardown closed the listener; the converge loop calls
	// attach again either way.
	fa, err := dialFakeAdapterPipeErr(a.t, a.bridge)
	if err != nil {
		return
	}
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

// frame is one adapter tick. The position moves every time, so change suppression cannot be what keeps a state off the
// wire. A failed send is not a test failure: a core still finishing the previous adapter's disconnect answers "busy"
// and hangs up, and a real adapter dials again, so this drops the connection for the next attach to remake.
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

// drain empties the fake adapter's despawn channel, which nothing here reads.
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

// sees reports whether this actor's adapter renders exactly peer, under peer's name, and nobody else: an identity left
// behind by a reconnect is a ghost of somebody not there. The peerID == "" guard is load-bearing: a core that never
// reached a relay keeps its adapter and plays solo with no player id, and convergence must never be satisfiable by two
// games each playing alone.
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

// internals is what a failure needs and the outside cannot see, so a wedged core can be told apart from a slow one.
func (a *scheduleActor) internals() string {
	a.core.mu.Lock()
	defer a.core.mu.Unlock()
	return fmt.Sprintf("relay=%v adapterAttached=%v adapterReady=%v autoRetry=%q lastErr=%q",
		a.core.relay != nil, a.core.attachedAdapter != nil, a.core.adapterReady,
		a.core.autoRetryGameID, a.core.lastConnectErr)
}

func (a *scheduleActor) describe() string {
	if a.fa == nil {
		return fmt.Sprintf("%s(id=%q, detached, %s)", a.name, a.core.PlayerID(), a.internals())
	}
	a.fa.mu.Lock()
	defer a.fa.mu.Unlock()
	ids := make([]string, 0, len(a.fa.rendered))
	for id := range a.fa.rendered {
		ids = append(ids, fmt.Sprintf("%s(name=%q)", id, a.fa.names[id].DisplayName))
	}
	return fmt.Sprintf("%s(id=%q, rendering=[%s], %s)", a.name, a.core.PlayerID(),
		strings.Join(ids, " "), a.internals())
}

// scheduleOps names what a seed byte's low bits mean, so a failing corpus entry prints as the sequence it ran.
var scheduleOps = [8]string{
	"a.frame", "b.frame", "a.detach", "b.detach",
	"a.attach", "b.attach", "a.dropRelay", "b.dropRelay",
}

// fuzz-census: no-ci-step -- stands up real relay sockets per input, so a continuous
// campaign is ephemeral-port-bound long before it is idea-bound. Run by hand.
func FuzzSchedule(f *testing.F) {
	// The seeds are the orderings known to matter, replayed by a plain go test: both present before either sends, one
	// joining after the other has settled, a relay blip under a running game, a game closing and relaunching. Every
	// seed carries the configuration prefix ahead of its schedule; TestFuzzScheduleSeedsAreLongerThanTheirConfig pins
	// it.
	for _, schedule := range fuzzScheduleSeedSchedules {
		f.Add(append(append([]byte{}, fuzzSchedulePinnedConfig...), schedule...))
	}

	f.Fuzz(func(t *testing.T, seed []byte) {
		if len(seed) == 0 {
			return
		}

		// The configuration is part of the seed: the send rate sets the gap between samples, which races the keepalive,
		// the stale window and the interpolation buffer's edges, and curve and prediction change which samples the
		// buffer must hold. Rates are raw bytes, so 0 (unspecified) and out-of-range (clamped) are explored too.
		if len(seed) <= fuzzScheduleConfigBytes {
			return
		}
		cfg := decodeScheduleConfig(seed[:fuzzScheduleConfigBytes])
		seed = seed[fuzzScheduleConfigBytes:]
		if len(seed) > fuzzScheduleMaxSteps {
			seed = seed[:fuzzScheduleMaxSteps]
		}

		s := relay.NewServer()
		s.SendHz = cfg.rawSendHz
		relayAddr := startRelayWith(t, s)

		a := newScheduleActorWith(t, relayAddr, "alice", cfg)
		b := newScheduleActorWith(t, relayAddr, "bob", cfg)

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

		// Whatever the schedule left, both games are now attached and sending, where a player says "I still can't see
		// them": everything above is allowed, this is not.
		deadline := time.Now().Add(fuzzScheduleConvergeWait)
		for time.Now().Before(deadline) {
			// Re-attached inside the loop: a core still finishing the previous connection refuses this one, and a
			// relaunched game keeps trying too.
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
