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
	// drainBytes is how many bytes the fake adapter reads per drainEvery; 0 is as fast as Go can.
	drainBytes  int
	drainEvery  time.Duration
	minSend     time.Duration
	extrapolate time.Duration
	correction  time.Duration
	// allAreas, orientBracket and inputTracks are what a richer hello declares, re-set after every attach.
	allAreas, orientBracket bool
	// inputTracks also makes file.valid write an input track beside its clip.
	inputTracks bool
}

func (c fuzzEverythingCfg) String() string {
	return fmt.Sprintf("interp=%v localInterp=%v keepalive=%v stale=%v replayStart=%v seek=%v chaser=%v count=%d delay=%v spacing=%v spawn=%v contact=%v split=%v saveLast=%v recordOnLaunch=%v drain=%dB/%v",
		c.interp, c.localInterp, c.keepalive, c.stale, c.replayStart, c.replaySeek, c.chaserOn, c.chaserCount, c.chaserDelay, c.chaserSpacing, c.spawn, c.contact, c.splitTimes, c.saveLast, c.recordOnLaunch, c.drainBytes, c.drainEvery)
}

// Small alphabets so a schedule lands inside the compressed clock, plus out-of-range entries the clamps must eat.
var (
	fuzzEverythingDurations = [8]time.Duration{0, 5 * time.Millisecond, 20 * time.Millisecond, 50 * time.Millisecond, 120 * time.Millisecond, 300 * time.Millisecond, -7 * time.Second, 48 * time.Hour}
	fuzzEverythingCounts    = [8]int{0, 1, 2, 3, 8, 9, -1, 1 << 20}
	// Bytes per fuzzEverythingDrainEvery; unlimited (0) stays the majority so ordinary schedules still dominate.
	fuzzEverythingDrains = [8]int{0, 0, 0, 0, 64 << 10, 8 << 10, 1 << 10, 256}
	// Half off, so ordinary schedules still dominate.
	fuzzEverythingCorrections = [4]time.Duration{0, 0, 20 * time.Millisecond, 48 * time.Hour}
)

// fuzzEverythingDrainEvery is the adapter's frame: one read allowance per tick, as a game drains its bridge socket.
const fuzzEverythingDrainEvery = 2 * time.Millisecond

// The orientation shapes real adapters send. Opaque to the core, so each must reach the adapter unread and unchanged.
var fuzzEverythingOrientations = [8]json.RawMessage{
	nil,
	json.RawMessage(`1.5`),
	json.RawMessage(`"north"`),
	json.RawMessage(`[0.1,0.2,0.3]`),
	json.RawMessage(`{"x":0,"y":0,"z":0,"w":1}`),
	json.RawMessage(`null`),
	json.RawMessage(`{"a":{"b":{"c":[1,2,3,4]}}}`), // nested, to prove nothing walks it
	json.RawMessage(`-359.99999999999994`),         // a float that must round-trip exactly
}

// decodeFuzzEverythingCfg packs new fields into spare bits: growing fuzzEverythingConfigBytes would invalidate the
// seed corpus.
func decodeFuzzEverythingCfg(b []byte) fuzzEverythingCfg {
	d := func(i int) time.Duration { return fuzzEverythingDurations[b[i%len(b)]&0x07] }
	return fuzzEverythingCfg{
		interp:         d(0),
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
		drainBytes:     fuzzEverythingDrains[(b[1]>>5)&0x07],
		drainEvery:     fuzzEverythingDrainEvery,
		minSend:        fuzzEverythingDurations[(b[2]>>3)&0x07],
		extrapolate:    fuzzEverythingDurations[(b[3]>>3)&0x07],
		correction:     fuzzEverythingCorrections[(b[6]>>6)&0x03],
		allAreas:       b[4]&0x08 != 0,
		orientBracket:  b[4]&0x10 != 0,
		inputTracks:    b[4]&0x20 != 0,
	}
}

// fuzzZipOf wraps clip bytes in a zip of clips entries (at least one), so one archive becomes several ghosts. The zip
// is always structurally valid; what varies is inside it.
func fuzzZipOf(data []byte, clips int) []byte {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	if clips < 1 {
		clips = 1
	}
	// Past the first two the body is a minimal valid clip: the point is the id count, and repeating a fuzzed body
	// would only slow the target.
	small := clipBytes(nil, walkStates(2, 1))
	for i := 0; i < clips; i++ {
		w, err := zw.Create(fmt.Sprintf("c%03d.ndjson", i))
		if err != nil {
			return data
		}
		body := data
		if i > 1 {
			body = small
		}
		if _, err := w.Write(body); err != nil {
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

// fuzzEverythingClip builds one of eight deliberate clip shapes from the step byte's top three bits, the only free
// ones: the low five are pinned to file.valid's op index.
func fuzzEverythingClip(b byte) []byte {
	k := b >> 5

	n := []int{4, 12, 6, 8, 5, 3, 7, 9}[k]
	step := []int64{10, 10, 20, 40, 100, 10, 30, 10}[k]
	areaChange := k == 2 || k == 6
	// k=1 collapses its gap via skip_gaps; k=3 keeps it raw but plays at 4x, so the raw seam costs 500ms, not 2s.
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

	// Shapes 0-4 must load, so playback runs; 5-7 must be refused (a string speed, a NaN speed, a trim past the
	// clip), since a player can edit a clip file. TestFuzzEverythingClipShapesAreWhatTheyClaim pins the split.
	hdr := map[string]any{
		"name":        []string{"F", "F", "F", "F", "", "F", "‮evil", "AVeryLongGhostNameIndeedItIs"}[k],
		"color":       []string{"#FF8800", "#FF8800", "#FF8800", "#FF8800", "red", "", "#12", "#FF8800"}[k],
		"speed":       []any{1, 1, 1, 4, 0.25, "fast", math.NaN(), 99}[k],
		"loop":        k == 2,
		"anchor":      []string{"launch", "launch", "start", "area", "start", "launch", "sideways", "launch"}[k],
		"start_delay": []string{"0s", "0s", "0s", "0s", "40ms", "-5s", "0s", "abc"}[k],
		"trim_start":  []string{"0s", "0s", "0s", "20ms", "0s", "auto", "0s", "1h"}[k],
		"trim_end":    []string{"0s", "0s", "0s", "10ms", "0s", "0s", "0s", "-1s"}[k],
		// k=1's threshold sits between the 10ms spacing and the 2s gap, so only the gap collapses into a seam.
		"skip_gaps": []string{"0s", "1s", "0s", "0s", "0s", "0s", "0s", "x"}[k],
		// One per shape, so a later file of the same shape reuses the same input track.
		"recording_id": fmt.Sprintf("fz%d", k),
	}
	return clipBytes(hdr, states)
}

// fuzzEverythingTrack is the input track beside fuzzEverythingClip(b): an edge every 10ms across every shape's span,
// gaps included, with a stick value on every other edge.
func fuzzEverythingTrack(b byte) []byte {
	k := b >> 5
	var edges []inputEdgeLine
	for i := 0; i < 320; i++ {
		e := inputEdgeLine{Ts: 1_000_000 + int64(i)*10, F: uint64(i), T: int64(i) * 10, M: uint32(i & 3)}
		if i%2 == 1 {
			e.Ax = []float64{float64(i%7) / 7}
		}
		edges = append(edges, e)
	}
	return trackBytes(map[string]any{"recording_id": fmt.Sprintf("fz%d", k)}, edges)
}

// FuzzEverything fuzzes the configuration, order, timing and values of one whole client at once: recording, playback,
// seeks, chasers and split times on top of the adapter and relay paths. Every seed byte maps onto a legal input by
// masking, never by rejecting, so the corpus reads as a script. It opens no relay sockets, so it runs in CI's fuzz
// campaign and the race job, and its timings are the shipped per-Core fields set short, never a special branch. After
// every step and at the end:
//   - no panic and no deadlock: every wait is bounded;
//   - a render for a replay: or chaser: id is cosmetic, one for a relay id never is, and no local id reaches the relay;
//   - neither kind of roster seat, relay-announced or local, exceeds protocol.MaxRosterSize, and local ghosts past
//     that cap never outnumber the files written plus the chasers asked for;
//   - the relay clock never runs backwards, and remote_input stays well-formed;
//   - after the last step the core still answers an adapter frame.
//
// Long campaign by hand, on an idle machine:
//
//	go test ./core -run=XXX -fuzz=FuzzEverything -fuzztime=10m -parallel 2
func FuzzEverything(f *testing.F) {
	// Seeds: a quiet run, a replay through a seek, a chaser pack through a gap,
	// hostile frames, the relay injecting local-prefixed ids, a clock reset.
	f.Add([]byte{2, 1, 4, 0, 1, 0x00, 1, 0x00, 8, 0, 10, 14, 0, 0, 16, 0, 0, 17, 0, 0, 9})
	f.Add([]byte{2, 1, 4, 0, 1, 0x39, 3, 0x0a, 8, 0, 0, 0, 0, 0, 28, 3, 3, 3, 0, 0, 0, 0, 29})
	f.Add([]byte{0, 0, 3, 0, 0, 0x00, 0, 0x00, 8, 4, 5, 6, 7, 0, 0, 24, 26, 25, 27, 0, 0})
	f.Add([]byte{3, 2, 5, 1, 2, 0x07, 4, 0x4f, 8, 10, 14, 0, 0, 20, 0, 21, 0, 19, 0, 9, 8, 0, 0})
	// A replay seam, cheaply: 42 is file.valid at clip shape 1, whose 2s gap skip_gaps collapses; 124 is a 350ms
	// gap, ample for playback to reach the seam.
	f.Add([]byte{2, 1, 4, 0, 2, 0x00, 1, 0x00, 8, 42, 14, 124, 0, 124})
	// The clock stepping back under a live replay: 59 is clock.backStep, between two seeks.
	f.Add([]byte{2, 1, 4, 0, 2, 0x00, 1, 0x00, 8, 42, 14, 59, 17, 124, 59, 18, 0})
	// Input tracks (config byte 4, bit 5): through the cheap seam, a restart and rewind, and a detach mid-stream.
	f.Add([]byte{2, 1, 4, 0, 0x22, 0x00, 1, 0x00, 8, 42, 14, 124, 0, 124})
	f.Add([]byte{2, 1, 4, 0, 0x21, 0x00, 1, 0x00, 8, 0, 10, 14, 0, 0, 16, 0, 0, 17, 0, 0, 9})
	f.Add([]byte{2, 1, 4, 0, 0x21, 0x00, 1, 0x00, 8, 106, 14, 0, 0, 9, 8, 0, 0, 16, 0})

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
		// One contact bit picks hurt; kill takes the same policy push and has its own test.
		if cfg.contact {
			c.ChaserContact = ChaserContactHurt
		}
		c.ChaserName = "F"
		c.MinSendInterval = cfg.minSend
		c.Extrapolate = cfg.extrapolate
		c.Correction = cfg.correction
		rt := &recordingTransport{}
		c.mu.Lock()
		c.relay = rt
		c.playerID = "self"
		c.relayGame = "emerald"
		c.relayPolicyKnown = true
		c.mu.Unlock()

		// In memory, not a socket: a listener per iteration exhausts Windows' ephemeral ports in seconds. ServeBridge
		// and its framing are still the shipped code.
		ln := newPipeListener()
		t.Cleanup(func() { ln.Close() })
		go c.ServeBridge(ln)
		t.Cleanup(func() { c.StopReplays(); c.StopChasers(); c.StopRecording() })

		// Short: a throttled drain can stall a write, and a pipe has no kernel buffer to absorb it.
		c.bridgeWriteTimeout = 100 * time.Millisecond

		var fa *fakeAdapter
		attach := func() {
			if fa != nil {
				return
			}
			fa = reattachFakeAdapterWith(t, "emerald", func() *fakeAdapter {
				a, err := dialThrottledFakeAdapterPipeErr(t, ln, cfg.drainBytes, cfg.drainEvery)
				if err != nil {
					t.Skipf("bridge pipe closed during teardown: %v", err)
				}
				return a
			})
			// reattachFakeAdapterWith sends a bare hello and every attach resets these, so re-declare after each one.
			c.mu.Lock()
			c.adapterRenderAllAreas = cfg.allAreas
			c.adapterWantsOrientBracket = cfg.orientBracket
			c.adapterWantsInputTracks = cfg.inputTracks
			c.mu.Unlock()
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
		// The newest `at` seen per local id since its last reset.
		inputLastAt := map[string]int64{}
		ran := make([]string, 0, len(steps))

		// The step byte has no bits left, so the step index widens the id space: the same parameter later in a run
		// names another peer.
		peerID := func(param byte, step int) string {
			return fmt.Sprintf("p%d", int(param)+step*8)
		}
		// Ids a well-behaved relay never sends; each must be dropped, never admitted.
		hostileIDs := []string{
			"",
			strings.Repeat("x", 4096),
			"p1\u0000hidden",
			"replay:f01.ndjson",
			"chaser:1",
			"../../etc/passwd",
			"p1 p2",
			"\ufeffp1",
		}

		// clock.backStep below tries to break nowMsLocked's never-backwards clamp.
		var lastNow int64

		check := func(step string) {
			t.Helper()
			if now := c.nowMs(); now < lastNow {
				t.Fatalf("after %s: nowMs went backwards, %d -> %d (%s; ran %s)", step, lastNow, now, cfg, strings.Join(ran, " "))
			} else {
				lastNow = now
			}
			c.mu.Lock()
			local := len(c.localPeers)
			relaySeats, localSeats := 0, 0
			for id := range c.roster {
				if isLocalPeerID(id) {
					localSeats++
				} else {
					relaySeats++
				}
			}
			c.mu.Unlock()
			if relaySeats > protocol.MaxRosterSize || localSeats > protocol.MaxRosterSize {
				t.Fatalf("after %s: roster holds %d relay and %d local seats, cap %d each (%s; ran %s)", step, relaySeats, localSeats, protocol.MaxRosterSize, cfg, strings.Join(ran, " "))
			}
			if bound := files + cfg.chaserCount; local > bound && local > protocol.MaxRosterSize {
				t.Fatalf("after %s: %d local ghosts, more than %d files + %d chasers (%s; ran %s)", step, local, files, cfg.chaserCount, cfg, strings.Join(ran, " "))
			}
			if fa != nil {
				for {
					var r receivedInput
					select {
					case r = <-fa.inputs:
					default:
						goto inputsChecked
					}
					id := r.msg.PlayerID
					if !cfg.inputTracks {
						t.Fatalf("after %s: remote_input for %q reached an adapter that never asked (%s; ran %s)", step, id, cfg, strings.Join(ran, " "))
					}
					if !isLocalPeerID(id) {
						t.Fatalf("after %s: remote_input for a non-local id %q (%s; ran %s)", step, id, cfg, strings.Join(ran, " "))
					}
					if len(r.msg.Edges) > bridge.MaxInputEdgesPerBatch {
						t.Fatalf("after %s: remote_input for %q carries %d edges, over %d (%s; ran %s)", step, id, len(r.msg.Edges), bridge.MaxInputEdgesPerBatch, cfg, strings.Join(ran, " "))
					}
					if r.msg.Reset {
						if r.msg.Labels == nil {
							t.Fatalf("after %s: a reset line for %q carries no labels (%s; ran %s)", step, id, cfg, strings.Join(ran, " "))
						}
						delete(inputLastAt, id)
					} else if r.msg.Labels != nil {
						t.Fatalf("after %s: a non-reset line for %q re-declared the tables (%s; ran %s)", step, id, cfg, strings.Join(ran, " "))
					}
					for _, e := range r.msg.Edges {
						if last, ok := inputLastAt[id]; ok && e.At < last {
							t.Fatalf("after %s: remote_input for %q runs backwards, at %d after %d, with no reset between (%s; ran %s)", step, id, e.At, last, cfg, strings.Join(ran, " "))
						}
						inputLastAt[id] = e.At
					}
				}
			inputsChecked:
			}
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
			for _, raw := range rt.all() {
				if strings.Contains(string(raw), `"replay:`) || strings.Contains(string(raw), `"chaser:`) {
					t.Fatalf("after %s: a local peer reached the relay transport: %s (%s; ran %s)", step, raw, cfg, strings.Join(ran, " "))
				}
			}
		}

		for i, b := range steps {
			op := fuzzEverythingOps[b&0x1F]
			ran = append(ran, op)
			switch op {
			case "frame.walk":
				x += 1
				// With cfg.orientBracket on, these opaque blobs cross the whole render path to the adapter.
				frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run",
					Orientation: fuzzEverythingOrientations[(b>>5)&0x07]})
			case "frame.stand":
				// player_frozen stops the chaser pack's clock; a freeze left on across chasersStop could strand the
				// accumulator.
				switch b >> 6 {
				case 3:
					c.SetPlayerFrozen(true)
				case 2:
					c.SetPlayerFrozen(false)
				}
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
					if cfg.inputTracks {
						// Where the recorder would put it; overwriting the same shape's track is harmless.
						os.MkdirAll(c.inputsDir(), 0o755)
						os.WriteFile(filepath.Join(c.inputsDir(), fmt.Sprintf("in-fz%d.ndjson", b>>5)), fuzzEverythingTrack(b), 0o644)
					}
				case "file.otherGame":
					data = clipBytes(map[string]any{"game": "someothergame"}, walkStates(3, 50))
				case "file.huge":
					data = append(clipBytes(nil, nil), []byte(`{"area_id":"`+strings.Repeat("h", protocol.MaxLineBytes)+`"}`+"\n")...)
				default:
					data = seed
				}
				// Every third file is a zip, chosen by the file counter because the step byte has no bits left.
				if files%3 == 0 {
					// Every sixth carries two clips, every ninth eight. A crowd past the roster cap costs seconds an
					// execution, so it is TestAZipOfMoreClipsThanTheRosterHasSeats; a peer flood stays cheap here.
					clips := 1
					switch {
					case files%9 == 0:
						clips = 8
					case files%6 == 0:
						clips = 2
					}
					name = strings.TrimSuffix(name, ".ndjson") + ".zip"
					data = fuzzZipOf(data, clips)
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
				// 7 floods past the roster cap in one step, which single joins never reach; 6 is a hostile id;
				// 0-5 an ordinary peer.
				switch {
				case b>>5 == 7:
					for n := 0; n < protocol.MaxRosterSize+88; n++ {
						relayMsg(protocol.TypeJoin, protocol.Join{PlayerID: fmt.Sprintf("flood%d", n), Nametag: &protocol.Nametag{Name: "F"}})
					}
				case b>>5 == 6:
					relayMsg(protocol.TypeJoin, protocol.Join{PlayerID: hostileIDs[i%len(hostileIDs)], Nametag: &protocol.Nametag{Name: "P"}})
				default:
					relayMsg(protocol.TypeJoin, protocol.Join{PlayerID: peerID(b>>5, i), Nametag: &protocol.Nametag{Name: "P"}})
				}
			case "relay.state":
				// A state for someone never admitted must be dropped by the roster.
				id := peerID(b>>5, i)
				if b>>5 == 6 {
					id = hostileIDs[i%len(hostileIDs)]
				}
				relayMsg(protocol.TypeState, protocol.State{PlayerID: id, Timestamp: c.nowMs(), AreaID: "a", Position: []float64{float64(b), 1}})
			case "relay.leave":
				// Half the leaves name a peer from an earlier step; the rest name someone who was never there.
				away := i
				if b&0x20 != 0 && i > 0 {
					away = i - 1
				}
				relayMsg(protocol.TypeLeave, protocol.Leave{PlayerID: peerID(b>>5, away)})
			case "relay.stateLocalPrefix":
				// A hostile relay naming a local id: it must be dropped, never steer a local ghost.
				relayMsg(protocol.TypeState, protocol.State{PlayerID: "replay:f01.ndjson", Timestamp: c.nowMs(), AreaID: "a", Position: []float64{9, 9}})
				relayMsg(protocol.TypeJoin, protocol.Join{PlayerID: "chaser:1", Nametag: &protocol.Nametag{Name: "evil"}})
			case "relay.forget":
				// forget drops the session, which resets the monotonic clamp; backStep keeps it up and shrinks the
				// offset as a lower-RTT ping does, the only path that drives nowMsLocked's clamp.
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
					// clock.v1 must be active or clockAdjustLocked returns 0 and the offset is inert.
					c.activeFeatures = []string{protocol.FeatureClockV1}
					// The step back varies with the top two bits, so several of these need not land on one value.
					c.clock = clockSync{offsetMs: -int64(b>>6+1) * 1000, bestRTTMs: 1}
					c.mu.Unlock()
				}
			case "gap":
				// Long enough to cross the compressed stale window, short enough that a schedule stays affordable.
				time.Sleep([4]time.Duration{10, 40, 120, 350}[(b>>5)&0x03] * time.Millisecond)
			case "chasersStart":
				c.StartChasers()
			case "chasersStop":
				c.StopChasers()
			case "relay.welcome":
				// A room policy landing mid-session, its roster including local-prefixed ids.
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

// TestFuzzEverythingClipShapesAreWhatTheyClaim pins fuzzEverythingClip's eight shapes, since a fuzz target that
// exercises nothing passes like one that exercises everything: five load, three are refused, and k=1 carries one
// forced seam.
func TestFuzzEverythingClipShapesAreWhatTheyClaim(t *testing.T) {
	// A file.valid step byte: the op index in the low five bits, the shape in the top three.
	shape := func(k byte) byte { return 10 | k<<5 }

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
			if d := clip.duration(); d > 500*time.Millisecond {
				t.Fatalf("k=1 spans %v: the 2s gap was not collapsed, so this shape costs wall time on every run", d)
			}
		}
	}
	if loaded < 5 {
		t.Fatalf("only %d of 8 shapes load; playback-from-a-file needs several or the target silently stops testing it", loaded)
	}
}
