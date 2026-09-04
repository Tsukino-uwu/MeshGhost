package core

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"math"
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
//   - the relay clock never runs backwards, however the offset moves;
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
	localInterp                    time.Duration
	replayStart, replaySeek, spawn time.Duration
	chaserOn, contact, splitTimes  bool
	chaserCount                    int
	chaserDelay, chaserSpacing     time.Duration
	saveLast                       time.Duration
	recordOnLaunch                 bool
}

func (c fuzzEverythingCfg) String() string {
	return fmt.Sprintf("interp=%v localInterp=%v keepalive=%v stale=%v replayStart=%v seek=%v chaser=%v count=%d delay=%v spacing=%v spawn=%v contact=%v split=%v saveLast=%v recordOnLaunch=%v",
		c.interp, c.localInterp, c.keepalive, c.stale, c.replayStart, c.replaySeek, c.chaserOn, c.chaserCount, c.chaserDelay, c.chaserSpacing, c.spawn, c.contact, c.splitTimes, c.saveLast, c.recordOnLaunch)
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
		interp: d(0),
		// Bits 3-5 of the same byte, which were free -- growing
		// fuzzEverythingConfigBytes would invalidate the seed corpus.
		localInterp:    fuzzEverythingDurations[(b[0]>>3)&0x07],
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

// fuzzZipOf wraps clip bytes in a zip, optionally twice over so the multi-clip
// path (one archive becoming several ghosts) is exercised too. A zip this
// function builds is always structurally valid; what varies is what is INSIDE
// it, which is the half the loader has to survive.
func fuzzZipOf(data []byte, twice bool) []byte {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	names := []string{"a.ndjson"}
	if twice {
		names = append(names, "b.ndjson")
	}
	for _, n := range names {
		w, err := zw.Create(n)
		if err != nil {
			return data
		}
		if _, err := w.Write(data); err != nil {
			return data
		}
	}
	// A file that is not a clip, which the loader must skip rather than refuse.
	if w, err := zw.Create("readme.txt"); err == nil {
		_, _ = w.Write([]byte("not a clip"))
	}
	if err := zw.Close(); err != nil {
		return data
	}
	return buf.Bytes()
}

// fuzzEverythingClip builds one clip from the step byte's THREE FREE BITS, and
// the reason it is written this way is a bug this function used to have.
//
// The op is chosen with b&0x1F, so a byte that reaches here has its low five
// bits pinned to file.valid's index (01010) and only bits 5-7 vary. The
// original version read nine header keys out of the whole byte as though all
// eight bits were free — but `speed` came from (b>>1)&0x07, which is bits 3..1,
// all pinned, and always selected the STRING "fast". So every clip this
// function ever produced was refused by the loader with
//
//	line 1 is not a replay header: json: cannot unmarshal string into ... speed
//
// and playback-from-a-file was dead the whole time: the only way a replay ever
// started in this target was ctl.replayLast / ctl.saveLast on a real recording.
// The deliberate 2s-gap seam below had never once run. Found 2026-09-03 while
// adding a seam seed, by reading the -v log rather than by a failure — a
// passing fuzz target that silently exercises nothing looks exactly like a
// passing one that does.
//
// So: eight bits of pretend entropy are replaced by eight DELIBERATE shapes.
// Three bits is genuinely all a single step byte has left, and naming the
// shapes is honest where hashing a pinned byte was not.
func fuzzEverythingClip(b byte) []byte {
	k := b >> 5

	// Body: length, spacing, an area change, and a recorded gap.
	n := []int{4, 12, 6, 8, 5, 3, 7, 9}[k]
	step := []int64{10, 10, 20, 40, 100, 10, 30, 10}[k]
	areaChange := k == 2 || k == 6
	// k=1 collapses its gap via skip_gaps (cheap); k=3 leaves it raw but plays
	// at 4x, so the uncollapsed seam path costs ~500ms rather than two seconds.
	recordedGap := k == 1 || k == 3

	var states []protocol.State
	ts := int64(1_000_000)
	for i := 0; i < n; i++ {
		area := "a"
		if areaChange && i > n/2 {
			area = "b"
		}
		if recordedGap && i == n/2 {
			ts += 2000 // > replayGapSeamMs: a seam on playback
		}
		states = append(states, protocol.State{Timestamp: ts, AreaID: area, Position: []float64{float64(i), 0}, Anim: "run"})
		ts += step
	}

	// Header. Five shapes the loader must ACCEPT, so playback actually runs,
	// and three (5, 6, 7) it must refuse: a string speed, a NaN speed, and
	// durations that trim the clip out of existence. A clip file is
	// player-editable, so both halves are real inputs. The split is pinned by
	// TestFuzzEverythingClipShapesAreWhatTheyClaim.
	hdr := map[string]any{
		"name":        []string{"F", "F", "F", "F", "", "F", "‮evil", "AVeryLongGhostNameIndeedItIs"}[k],
		"color":       []string{"#FF8800", "#FF8800", "#FF8800", "#FF8800", "red", "", "#12", "#FF8800"}[k],
		"speed":       []any{1, 1, 1, 4, 0.25, "fast", math.NaN(), 99}[k],
		"loop":        k == 2,
		"anchor":      []string{"launch", "launch", "start", "area", "start", "launch", "sideways", "launch"}[k],
		"start_delay": []string{"0s", "0s", "0s", "0s", "40ms", "-5s", "0s", "abc"}[k],
		"trim_start":  []string{"0s", "0s", "0s", "20ms", "0s", "auto", "0s", "1h"}[k],
		"trim_end":    []string{"0s", "0s", "0s", "10ms", "0s", "0s", "0s", "-1s"}[k],
		// k=1 is the CHEAP seam: applySkipGaps collapses the 2s gap to one
		// millisecond and marks a forcedSeam, so the seam path runs without
		// two seconds of wall time. The threshold sits BETWEEN the clip's 10ms
		// spacing and its 2s gap deliberately — at "1ms" every ordinary step
		// would collapse too and the clip becomes one long seam, which
		// exercises the path but is no longer a clip with a seam in it. k=7
		// leaves the gap raw, so the expensive path stays reachable too, at
		// one shape in eight rather than half of them.
		"skip_gaps": []string{"0s", "1s", "0s", "0s", "0s", "0s", "0s", "x"}[k],
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
	// A REPLAY SEAM, cheaply. Step byte 42 is file.valid (42&0x1F == 10) at
	// clip shape k=1 (42>>5), the one whose 2s recorded gap is collapsed to a
	// millisecond by skip_gaps while still marking a forcedSeam — so the seam
	// path runs for about a millisecond instead of two seconds. 124 is a
	// 350ms gap, ample for playback to reach the seam at ~51ms in.
	f.Add([]byte{2, 1, 4, 0, 2, 0x00, 1, 0x00, 8, 42, 14, 124, 0, 124})
	// THE CLOCK STEPPING BACK UNDER A LIVE REPLAY. Byte 59 is relay.forget's
	// slot with bit 5 set, i.e. the clock.backStep variant, landing between two
	// seeks so the player's own re-base path (replay.go's prevNow check) runs
	// against a clamped clock rather than a rewound one.
	f.Add([]byte{2, 1, 4, 0, 2, 0x00, 1, 0x00, 8, 42, 14, 59, 17, 124, 59, 18, 0})

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
		c.LocalInterpolationDelay = cfg.localInterp
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

		// IN-MEMORY, NOT A SOCKET. Twelve workers standing up a listener and
		// an adapter connection per iteration exhaust Windows' ephemeral
		// ports in seconds, and the target then fails for a reason that has
		// nothing to do with the schedule it was running -- see pipeListener.
		// The bridge itself is the real one: ServeBridge, the framing and
		// every callback are the shipped code.
		ln := newPipeListener()
		t.Cleanup(func() { ln.Close() })
		go c.ServeBridge(ln)
		t.Cleanup(func() { c.StopReplays(); c.StopChasers(); c.StopRecording() })

		var fa *fakeAdapter
		attach := func() {
			if fa != nil {
				return
			}
			fa = reattachFakeAdapterWith(t, "emerald", func() *fakeAdapter { return dialFakeAdapterPipe(t, ln) })
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

		// The relay clock must never run backwards, whatever the offset does.
		// nowMsLocked clamps it (online.go's "Never go backwards"), and the
		// clock.backStep variant below is what tries to break that clamp.
		var lastNow int64

		check := func(step string) {
			t.Helper()
			if now := c.nowMs(); now < lastNow {
				t.Fatalf("after %s: nowMs went backwards, %d -> %d (%s; ran %s)", step, lastNow, now, cfg, strings.Join(ran, " "))
			} else {
				lastNow = now
			}
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
				// EVERY THIRD FILE GOES IN AS A ZIP, and one of those holds two
				// clips. replay/active reads .zip since 2026-09-04 and nothing
				// here covered it: every file op wrote .ndjson, so the archive
				// path, the multi-clip ids and a zip sitting beside plain files
				// were all unexercised by the target that exists precisely to
				// run this lifecycle in every order.
				//
				// Chosen by the file COUNTER rather than by seed bits, because
				// the step byte has none left (five bits pick the op, three pick
				// the clip shape) and the variety this target trades on is the
				// ORDER of operations, not the bytes inside a file -- FuzzReplay
				// already throws arbitrary bytes at the parser.
				if files%3 == 0 {
					name = strings.TrimSuffix(name, ".ndjson") + ".zip"
					data = fuzzZipOf(data, files%6 == 0)
				}
				os.WriteFile(name, data, 0o644)
			case "startReplays":
				c.StartReplays()
			case "stopReplays":
				c.StopReplays()
			case "ctl.restart":
				_, _ = c.ReplayControl(ReplayRestart, int(b>>5))
			case "ctl.rewind":
				_, _ = c.ReplayControl(ReplayRewind, int(b>>5))
			case "ctl.ff":
				_, _ = c.ReplayControl(ReplayFastForward, int(b>>5))
			case "ctl.replayLast":
				_, _ = c.ReplayControl(ReplayLast, 0)
			case "ctl.recordToggle":
				_, _ = c.ReplayControl(ReplayRecordToggle, 0)
			case "ctl.saveLast":
				_, _ = c.ReplayControl(ReplaySaveLast, 0)
			case "ctl.nonsense":
				_, _ = c.ReplayControl(ReplayAction(string(seed)), -1)
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
				// TWO VARIANTS, from a parameter bit this slot does not
				// otherwise use. Both are "the relay's clock moved", and they
				// are the two ways it moves:
				//
				//   forget    — the whole session drops. This already clears
				//               c.clock and c.lastNowMs, so the monotonic
				//               clamp is RESET rather than tested.
				//   backStep  — the session STAYS UP and the offset shrinks,
				//               which is what happens when a better (lower-RTT)
				//               ping sample arrives. This is the only path that
				//               actually drives nowMsLocked's clamp, and until
				//               now nothing fuzzed it.
				if b&0x20 == 0 {
					ran[len(ran)-1] = "relay.forget"
					c.mu.Lock()
					c.forgetRelaySessionLocked()
					c.relay = rt
					c.playerID = "self"
					c.relayGame = "emerald"
					c.mu.Unlock()
				} else {
					ran[len(ran)-1] = "clock.backStep"
					c.mu.Lock()
					// clock.v1 must be active or clockAdjustLocked returns 0
					// and the offset is inert.
					c.activeFeatures = []string{protocol.FeatureClockV1}
					// Backwards by a decreasing amount, so a schedule with
					// several of these keeps stepping the offset down instead
					// of landing on one value.
					c.clock = clockSync{offsetMs: -int64(b>>6+1) * 1000, bestRTTMs: 1}
					c.mu.Unlock()
				}
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
		if !c.awaitTick(before, testTimeout, nil) {
			// The stacks are the finding: which goroutine holds what.
			buf := make([]byte, 1<<20)
			n := runtime.Stack(buf, true)
			t.Fatalf("the core stopped ticking (%s; ran %s)\n%s", cfg, strings.Join(ran, " "), buf[:n])
		}
		check("end")
	})
}

// TestFuzzEverythingClipShapesAreWhatTheyClaim pins fuzzEverythingClip's eight
// shapes, and exists because the version before 2026-09-03 produced clips the
// loader refused EVERY TIME: `speed` was read from bits the op index pins, so
// it was always the string "fast" and playback-from-a-file never once ran in
// this target. The fuzz target still passed, because a target that exercises
// nothing passes exactly like one that exercises everything.
//
// So the shapes are asserted here rather than trusted. Four must load (or the
// replay path is dead again), four must be refused or clamped (or the hostile
// header coverage is gone), and k=1 must carry exactly one forced seam (or the
// cheap-seam seed stops reaching the seam).
func TestFuzzEverythingClipShapesAreWhatTheyClaim(t *testing.T) {
	// b is a file.valid step byte: the op index in the low five bits, the
	// shape in the top three, exactly as the fuzz loop produces it.
	shape := func(k byte) byte { return 10 | k<<5 }

	// 5, 6 and 7 are the hostile headers: a string speed, a NaN speed, and
	// durations that trim the clip out of existence. All three must be refused.
	wantLoads := map[byte]bool{0: true, 1: true, 2: true, 3: true, 4: true, 5: false, 6: false, 7: false}
	loaded := 0
	for k := byte(0); k < 8; k++ {
		b := shape(k)
		if got := b & 0x1F; got != 10 {
			t.Fatalf("k=%d: byte %d is op index %d, not file.valid (10)", k, b, got)
		}
		clip, err := parseReplay(bytes.NewReader(fuzzEverythingClip(b)), "f.ndjson")
		if wantLoads[k] != (err == nil) {
			t.Fatalf("k=%d: loads=%v, want %v (err %v)", k, err == nil, wantLoads[k], err)
		}
		if err != nil {
			continue
		}
		loaded++
		if len(clip.samples) < 2 {
			t.Fatalf("k=%d: %d sample(s), a clip that short cannot play", k, len(clip.samples))
		}
		if k == 1 {
			if len(clip.forcedSeam) != 1 {
				t.Fatalf("k=1 is the cheap-seam shape: %d forced seam(s), want exactly 1 (skip_gaps must sit between the 10ms spacing and the 2s gap)", len(clip.forcedSeam))
			}
			// Cheap: the collapsed clip must be milliseconds, not seconds.
			if d := clip.duration(); d > 500*time.Millisecond {
				t.Fatalf("k=1 spans %v: the 2s gap was not collapsed, so this shape costs wall time on every run", d)
			}
		}
	}
	if loaded < 5 {
		t.Fatalf("only %d of 8 shapes load; playback-from-a-file needs several or the target silently stops testing it", loaded)
	}
}
