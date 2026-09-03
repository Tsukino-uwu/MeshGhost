package core

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// FUZZ EVERYTHING AT ONCE.
//
// The user, 2026-09-03: "I want the fuzzer to test absolutely everything we
// could think about and even things we might forget/miss; a fuzzer that
// doesn't fuzz everything randomly won't catch things we didn't think about,
// and that is what it is supposed to catch." Every other target here fuzzes
// one axis: bytes into a parser, or the order of a few real events. This one
// fuzzes the CONFIGURATION, the ORDER, the TIMING and the VALUES of one whole
// client at the same time -- the replay-era features (recording, playback,
// seeks, the chaser pack, split times) on top of the adapter and relay paths
// they sit in -- and asks only for invariants a player would state. Every
// byte of the seed maps onto a legal input by masking, never by rejecting, so
// the engine wastes nothing and the corpus stays readable as a script.
//
// NO RELAY SOCKETS, deliberately. The two schedule fuzzers stand up real
// relays and are opt-in because of it (schedule_fuzz_test.go's account of the
// port wall). This target keeps one core, one bridge listener and a recording
// stand-in for the relay, so it runs in CI's fuzz campaign and under the race
// job like the parser targets, where a schedule-only target could not.
//
// THE INVARIANTS, checked after every step and at the end, whatever happened:
//   - no panic, no deadlock: every wait is bounded;
//   - a render for a replay:/chaser: id carries cosmetic=true, a render for a
//     relay id never does, and nothing with a local prefix ever reaches the
//     relay transport (the never-on-the-wire rule, ADR 0047);
//   - the roster never exceeds protocol.MaxRosterSize, and local ghosts never
//     exceed maxActiveReplays;
//   - after the last step the core still answers an adapter frame.
//
// The compressed clock is the shipped code path with shorter per-Core
// fields (the convergence fuzzer's argument), never a special branch.
//
// Long campaign by hand, on an idle machine:
//
//	go test ./core -run=XXX -fuzz=FuzzEverything -fuzztime=10m -parallel 2

const (
	fuzzEverythingConfigBytes = 8
	fuzzEverythingMaxSteps    = 24
)

// fuzzEverythingOps is the alphabet: a step byte's low five bits pick one.
var fuzzEverythingOps = [32]string{
	"frame.walk", "frame.stand", "frame.otherArea", "frame.nil",
	"frame.badPosition", "frame.fatExtras", "frame.emptyArea", "frame.jump",
	"attach", "detach", "file.valid", "file.garbage",
	"file.otherGame", "file.huge", "startReplays", "stopReplays",
	"ctl.restart", "ctl.rewind", "ctl.ff", "ctl.replayLast",
	"ctl.recordToggle", "ctl.saveLast", "ctl.nonsense", "relay.join",
	"relay.state", "relay.leave", "relay.stateLocalPrefix", "relay.forget",
	"gap", "chasersStart", "chasersStop", "relay.welcome",
}

type fuzzEverythingCfg struct {
	interp, keepalive, stale       time.Duration
	replayStart, replaySeek, spawn time.Duration
	chaserOn, contact, splitTimes  bool
	chaserCount                    int
	chaserDelay, chaserSpacing     time.Duration
	saveLast                       time.Duration
	recordOnLaunch                 bool
}

func (c fuzzEverythingCfg) String() string {
	return fmt.Sprintf("interp=%v keepalive=%v stale=%v replayStart=%v seek=%v chaser=%v count=%d delay=%v spacing=%v spawn=%v contact=%v split=%v saveLast=%v recordOnLaunch=%v",
		c.interp, c.keepalive, c.stale, c.replayStart, c.replaySeek, c.chaserOn, c.chaserCount, c.chaserDelay, c.chaserSpacing, c.spawn, c.contact, c.splitTimes, c.saveLast, c.recordOnLaunch)
}

// Small alphabets so a schedule lands inside the compressed clock, plus one
// out-of-range entry in each that the clamps must eat.
var (
	fuzzEverythingDurations = [8]time.Duration{0, 5 * time.Millisecond, 20 * time.Millisecond, 50 * time.Millisecond, 120 * time.Millisecond, 300 * time.Millisecond, -7 * time.Second, 48 * time.Hour}
	fuzzEverythingCounts    = [8]int{0, 1, 2, 3, 8, 9, -1, 1 << 20}
)

func decodeFuzzEverythingCfg(b []byte) fuzzEverythingCfg {
	d := func(i int) time.Duration { return fuzzEverythingDurations[b[i%len(b)]&0x07] }
	return fuzzEverythingCfg{
		interp:         d(0),
		keepalive:      d(1),
		stale:          d(2),
		replayStart:    d(3),
		replaySeek:     d(4),
		spawn:          fuzzEverythingDurations[(b[5]>>3)&0x07],
		chaserOn:       b[5]&0x01 == 1,
		contact:        b[5]&0x02 == 2,
		splitTimes:     b[5]&0x04 == 4,
		chaserCount:    fuzzEverythingCounts[b[6]&0x07],
		chaserDelay:    fuzzEverythingDurations[(b[6]>>3)&0x07],
		chaserSpacing:  fuzzEverythingDurations[b[7]&0x07],
		saveLast:       fuzzEverythingDurations[(b[7]>>3)&0x07],
		recordOnLaunch: b[7]&0x40 != 0,
	}
}

// fuzzEverythingClip is a random VALID clip: the length, spacing, areas and a
// gap come from the byte.
func fuzzEverythingClip(b byte) []byte {
	n := 2 + int(b&0x0F)
	step := int64(10 + 30*int(b>>4&0x03))
	var states []protocol.State
	ts := int64(1_000_000)
	for i := 0; i < n; i++ {
		area := "a"
		if b&0x40 != 0 && i > n/2 {
			area = "b"
		}
		if b&0x80 != 0 && i == n/2 {
			ts += 2000 // a recorded gap: a seam on playback
		}
		states = append(states, protocol.State{Timestamp: ts, AreaID: area, Position: []float64{float64(i), 0}, Anim: "run"})
		ts += step
	}
	// Every player-editable header key, from the byte: in-range, out-of-range
	// and nonsense values alike, since the loader must clamp or refuse each.
	hdr := map[string]any{
		"name":        []string{"F", "", "‮evil", "AVeryLongGhostNameIndeedItIs"}[b&0x03],
		"color":       []string{"#FF8800", "red", "", "#12"}[(b>>2)&0x03],
		"speed":       []any{0.25, 1, 4, 99, -3, "fast", 0, math.NaN()}[(b>>1)&0x07],
		"loop":        b&0x20 != 0,
		"anchor":      []string{"launch", "start", "area", "sideways"}[(b>>5)&0x03],
		"start_delay": []string{"0s", "40ms", "-5s", "abc"}[b&0x03],
		"trim_start":  []string{"0s", "auto", "20ms", "1h"}[(b>>3)&0x03],
		"trim_end":    []string{"0s", "10ms", "-1s", "99h"}[(b>>4)&0x03],
		"skip_gaps":   []string{"0s", "1s", "1ms", "x"}[(b>>6)&0x03],
	}
	return clipBytes(hdr, states)
}

func FuzzEverything(f *testing.F) {
	// Seeds: a quiet run, a replay through a seek, a chaser pack through a gap,
	// hostile frames, the relay injecting local-prefixed ids, a clock reset.
	f.Add([]byte{2, 1, 4, 0, 1, 0x00, 1, 0x00, 8, 0, 10, 14, 0, 0, 16, 0, 0, 17, 0, 0, 9})
	f.Add([]byte{2, 1, 4, 0, 1, 0x39, 3, 0x0a, 8, 0, 0, 0, 0, 0, 28, 3, 3, 3, 0, 0, 0, 0, 29})
	f.Add([]byte{0, 0, 3, 0, 0, 0x00, 0, 0x00, 8, 4, 5, 6, 7, 0, 0, 24, 26, 25, 27, 0, 0})
	f.Add([]byte{3, 2, 5, 1, 2, 0x07, 4, 0x4f, 8, 10, 14, 0, 0, 20, 0, 21, 0, 19, 0, 9, 8, 0, 0})

	f.Fuzz(func(t *testing.T, seed []byte) {
		if len(seed) <= fuzzEverythingConfigBytes {
			return
		}
		cfg := decodeFuzzEverythingCfg(seed[:fuzzEverythingConfigBytes])
		steps := seed[fuzzEverythingConfigBytes:]
		if len(steps) > fuzzEverythingMaxSteps {
			steps = steps[:fuzzEverythingMaxSteps]
		}

		dir := filepath.Join(t.TempDir(), "replay")
		c := New()
		c.InterpolationDelay = cfg.interp
		c.IdleKeepalive = cfg.keepalive
		c.RemoteStaleAfter = cfg.stale
		c.ReplayDir = dir
		c.ReplayStartDelay = cfg.replayStart
		c.ReplaySeek = cfg.replaySeek
		c.SplitTimes = cfg.splitTimes
		c.SaveLastSpan = cfg.saveLast
		c.RecordOnLaunch = cfg.recordOnLaunch
		c.ChaserEnabled = cfg.chaserOn
		c.ChaserCount = cfg.chaserCount
		c.ChaserDelay = cfg.chaserDelay
		c.ChaserSpacing = cfg.chaserSpacing
		c.ChaserSpawnDelay = cfg.spawn
		c.ChaserContact = cfg.contact
		c.ChaserName = "F"
		rt := &recordingTransport{}
		c.mu.Lock()
		c.relay = rt
		c.playerID = "self"
		c.relayGame = "emerald"
		c.relayPolicyKnown = true
		c.mu.Unlock()

		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
		t.Cleanup(func() { ln.Close() })
		go c.ServeBridge(ln)
		t.Cleanup(func() { c.StopReplays(); c.StopChasers(); c.StopRecording() })

		var fa *fakeAdapter
		attach := func() {
			if fa != nil {
				return
			}
			fa = reattachFakeAdapter(t, ln.Addr().String(), "emerald")
		}
		detach := func() {
			if fa == nil {
				return
			}
			fa.conn.Close()
			fa = nil
		}
		attach()

		x := 0.0
		frame := func(st *protocol.State) {
			if fa == nil {
				return
			}
			payload, _ := json.Marshal(bridge.LocalState{State: st})
			env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
			_ = fa.conn.Send(env) // a dead adapter is a legal state, not a failure
		}
		relayMsg := func(typ protocol.MessageType, v any) {
			payload, _ := json.Marshal(v)
			env, _ := json.Marshal(protocol.Envelope{Type: typ, Payload: payload})
			c.handleRelayMessage(rt, env, make(chan protocol.Welcome, 1), make(chan protocol.Reject, 1))
		}
		files := 0
		ran := make([]string, 0, len(steps))

		check := func(step string) {
			t.Helper()
			// Roster and local-ghost caps.
			c.mu.Lock()
			roster, local := len(c.roster), len(c.localPeers)
			c.mu.Unlock()
			if roster > protocol.MaxRosterSize {
				t.Fatalf("after %s: roster %d exceeds the cap (%s; ran %s)", step, roster, cfg, strings.Join(ran, " "))
			}
			if local > maxActiveReplays+maxChasers {
				t.Fatalf("after %s: %d local ghosts (%s; ran %s)", step, local, cfg, strings.Join(ran, " "))
			}
			// Cosmetic on every local render, never on a relay one.
			if fa != nil {
				fa.mu.Lock()
				for id, m := range fa.renderMsgs {
					if isLocalPeerID(id) != m.Cosmetic {
						fa.mu.Unlock()
						t.Fatalf("after %s: render for %q has cosmetic=%v (%s; ran %s)", step, id, m.Cosmetic, cfg, strings.Join(ran, " "))
					}
				}
				fa.mu.Unlock()
			}
			// Nothing local on the wire.
			for _, raw := range rt.all() {
				if strings.Contains(string(raw), `"replay:`) || strings.Contains(string(raw), `"chaser:`) {
					t.Fatalf("after %s: a local peer reached the relay transport: %s (%s; ran %s)", step, raw, cfg, strings.Join(ran, " "))
				}
			}
		}

		for _, b := range steps {
			op := fuzzEverythingOps[b&0x1F]
			ran = append(ran, op)
			switch op {
			case "frame.walk":
				x += 1
				frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run"})
			case "frame.stand":
				frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "idle"})
			case "frame.otherArea":
				frame(&protocol.State{AreaID: "b", Position: []float64{x, 0}})
			case "frame.nil":
				frame(nil)
			case "frame.badPosition":
				frame(&protocol.State{AreaID: "a", Position: []float64{math.Inf(1), math.NaN()}})
			case "frame.fatExtras":
				frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Extras: map[string]any{"k": strings.Repeat("x", 3000)}})
			case "frame.emptyArea":
				frame(&protocol.State{AreaID: "", Position: []float64{x, 0}})
			case "frame.jump":
				x += 1e6
				frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
			case "attach":
				attach()
			case "detach":
				detach()
			case "file.valid", "file.otherGame", "file.huge", "file.garbage":
				os.MkdirAll(filepath.Join(dir, "active"), 0o755)
				files++
				name := filepath.Join(dir, "active", fmt.Sprintf("f%02d.ndjson", files))
				var data []byte
				switch op {
				case "file.valid":
					data = fuzzEverythingClip(b)
				case "file.otherGame":
					data = clipBytes(map[string]any{"game": "someothergame"}, walkStates(3, 50))
				case "file.huge":
					data = append(clipBytes(nil, nil), []byte(`{"area_id":"`+strings.Repeat("h", protocol.MaxLineBytes)+`"}`+"\n")...)
				default:
					data = seed
				}
				os.WriteFile(name, data, 0o644)
			case "startReplays":
				c.StartReplays()
			case "stopReplays":
				c.StopReplays()
			case "ctl.restart":
				_ = c.ReplayControl(ReplayRestart, int(b>>5))
			case "ctl.rewind":
				_ = c.ReplayControl(ReplayRewind, int(b>>5))
			case "ctl.ff":
				_ = c.ReplayControl(ReplayFastForward, int(b>>5))
			case "ctl.replayLast":
				_ = c.ReplayControl(ReplayLast, 0)
			case "ctl.recordToggle":
				_ = c.ReplayControl(ReplayRecordToggle, 0)
			case "ctl.saveLast":
				_ = c.ReplayControl(ReplaySaveLast, 0)
			case "ctl.nonsense":
				_ = c.ReplayControl(ReplayAction(string(seed)), -1)
			case "relay.join":
				relayMsg(protocol.TypeJoin, protocol.Join{PlayerID: fmt.Sprintf("p%d", b>>5), Nametag: &protocol.Nametag{Name: "P"}})
			case "relay.state":
				relayMsg(protocol.TypeState, protocol.State{PlayerID: fmt.Sprintf("p%d", b>>5), Timestamp: c.nowMs(), AreaID: "a", Position: []float64{float64(b), 1}})
			case "relay.leave":
				relayMsg(protocol.TypeLeave, protocol.Leave{PlayerID: fmt.Sprintf("p%d", b>>5)})
			case "relay.stateLocalPrefix":
				// A hostile relay naming a local id: it must be dropped, not
				// steer a local ghost. (Never admitted: no Join carries it.)
				relayMsg(protocol.TypeState, protocol.State{PlayerID: "replay:f01.ndjson", Timestamp: c.nowMs(), AreaID: "a", Position: []float64{9, 9}})
				relayMsg(protocol.TypeJoin, protocol.Join{PlayerID: "chaser:1", Nametag: &protocol.Nametag{Name: "evil"}})
			case "relay.forget":
				c.mu.Lock()
				c.forgetRelaySessionLocked()
				c.relay = rt
				c.playerID = "self"
				c.relayGame = "emerald"
				c.mu.Unlock()
			case "gap":
				// Long enough to cross the compressed stale window and the
				// chaser seam sometimes (stale can be 5ms..300ms, the seam
				// 1.5s only with the top alphabet entry), short enough that a
				// schedule stays affordable: the first campaign ran 20 inputs
				// in its first 40s on the seeds' gaps alone.
				time.Sleep([4]time.Duration{10, 40, 120, 350}[(b>>5)&0x03] * time.Millisecond)
			case "chasersStart":
				c.StartChasers()
			case "chasersStop":
				c.StopChasers()
			case "relay.welcome":
				// A room policy landing mid-session: any collision value, any
				// rate, a roster of ids including local-prefixed ones.
				relayMsg(protocol.TypeWelcome, protocol.Welcome{
					PlayerID:       "self",
					SendHz:         int(b) * 3,
					GhostCollision: []string{"enabled", "disabled", "", "sideways"}[(b>>5)&0x03],
					Roster:         []string{"p1", "chaser:1", "replay:f01.ndjson", ""},
				})
				c.SetRingSpan(fuzzEverythingDurations[b>>5])
			}
			// One tick so the step's effect reaches the adapter, then the checks.
			frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
			time.Sleep(time.Millisecond)
			check(op)
		}

		// Whatever happened, the core still serves a frame and renders.
		attach()
		before := c.tickCount()
		frame(&protocol.State{AreaID: "a", Position: []float64{x + 1, 0}})
		if !c.awaitTick(before, testTimeout) {
			// The stacks are the finding: which goroutine holds what.
			buf := make([]byte, 1<<20)
			n := runtime.Stack(buf, true)
			t.Fatalf("the core stopped ticking (%s; ran %s)\n%s", cfg, strings.Join(ran, " "), buf[:n])
		}
		check("end")
	})
}
