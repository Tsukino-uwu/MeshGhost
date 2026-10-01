package e2e

import (
	"encoding/json"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestChaserFollowsThroughTheRealBinary: -chaser on the shipped client renders named cosmetic chaser ghosts fed only by
// the adapter's own frames, lagging by their own delay and not the interp as well; with -chaser-contact kill,
// session_policy carries the mode's own word.
func TestChaserFollowsThroughTheRealBinary(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}
	observedNames.Lock()
	observedNames.byPlayer = nil
	observedNames.Unlock()

	base := newRig(t)
	r := base.withFreshPorts(t)
	start(t, r.dir, r.relayBin, "-addr", r.relayAddr)
	waitForListener(t, r.relayAddr)

	bridgeAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	// -interp 450ms, the shipped value: a chaser must lag by its own delay, not that plus the network's jitter buffer,
	// and at interp 0 the two cannot differ.
	startClient(t, r.dir, r.clientBin, r.relayAddr, bridgeAddr, "-transport", "tcp",
		"-interp", "450ms",
		"-chaser", "-chaser-count", "2", "-chaser-delay", "200ms", "-chaser-spacing", "100ms",
		"-chaser-spawn-delay", "100ms", "-chaser-name", "Shadow", "-chaser-contact", "kill")
	// A moving player: a chaser never spawns on one who stands still, which the shared driver's fixed position is.
	renders, policies, playerX, stop := startMovingAdapter(t, bridgeAddr, "e2egame")
	defer stop()

	seen := map[string]bool{}
	lagMs := -1.0
	lags := 0
	contact := ""
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && (len(seen) < 2 || lags < 5 || contact == "") {
		select {
		case sp := <-policies:
			contact = sp.ChaserContact
			if contact != "kill" {
				t.Fatalf("session_policy.chaser_contact = %q, want \"kill\" -- the flag's own word, "+
					"not a bool spelling (ADR 0068): %+v", contact, sp)
			}
		case rr := <-renders:
			if strings.HasPrefix(rr.PlayerID, "chaser:") {
				if !rr.Cosmetic {
					t.Fatalf("a chaser rendered without cosmetic=true: %+v", rr)
				}
				seen[rr.PlayerID] = true
				// The walker covers 0.5 units per 20ms, so one unit is 40ms of lag; chaser:2 sits a spacing further
				// back. Read only past x 30, once the buffer is full: a just-spawned chaser edge-holds on its oldest
				// sample and reads short.
				if rr.PlayerID == "chaser:1" && len(rr.State.Position) > 0 {
					if x := playerX(); x > 30 {
						lagMs = (x - rr.State.Position[0]) * 40
						lags++
					}
				}
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	if len(seen) < 2 {
		t.Fatalf("saw chasers %v, want chaser:1 and chaser:2", seen)
	}
	if contact == "" {
		t.Fatal("the real binary never pushed a session_policy carrying chaser_contact, with -chaser-contact kill set")
	}
	if lags < 5 {
		t.Fatalf("only measured chaser:1 against the player %d time(s); need a settled buffer", lags)
	}
	if lagMs < 80 || lagMs > 400 {
		t.Fatalf("chaser:1 lagged the player by %.0fms, want about 200 (its -chaser-delay, plus "+
			"the small local render delay). About 650 means it is being charged the 450ms -interp "+
			"as well, which is the 2026-09-03 defect", lagMs)
	}
	awaitRemoteNameCalled(t, "Shadow 1", "the first chaser's numbered nametag")
}

// startMovingAdapter is startAdapter with a player whose x advances every frame. It reports the last x sent, so a test
// can measure a ghost's lag in the player's own units, and hands over every session_policy it is pushed.
func startMovingAdapter(t *testing.T, bridgeAddr, gameID string) (<-chan bridge.RenderRemote, <-chan bridge.SessionPolicy, func() float64, func()) {
	t.Helper()
	renders := make(chan bridge.RenderRemote, 64)
	policies := make(chan bridge.SessionPolicy, 8)
	stop := make(chan struct{})
	var stopOnce sync.Once
	var xMu sync.Mutex
	var lastX float64
	go func() {
		conn, err := transport.Dial(bridgeAddr)
		if err != nil {
			return
		}
		defer conn.Close()
		conn.OnReceive(func(payload []byte) {
			var env bridge.Envelope
			if json.Unmarshal(payload, &env) != nil {
				return
			}
			switch env.Type {
			case bridge.TypeRemoteName:
				var rn bridge.RemoteName
				if json.Unmarshal(env.Payload, &rn) == nil {
					observedNames.Lock()
					if observedNames.byPlayer == nil {
						observedNames.byPlayer = map[string]bridge.RemoteName{}
					}
					observedNames.byPlayer[rn.PlayerID] = rn
					observedNames.Unlock()
				}
			case bridge.TypeRenderRemote:
				var rr bridge.RenderRemote
				if json.Unmarshal(env.Payload, &rr) == nil {
					select {
					case renders <- rr:
					default:
					}
				}
			case bridge.TypeSessionPolicy:
				var sp bridge.SessionPolicy
				if json.Unmarshal(env.Payload, &sp) == nil {
					select {
					case policies <- sp:
					default:
					}
				}
			}
		})
		if !sendBridge(conn, bridge.TypeHello, bridge.Hello{GameID: gameID}) {
			return
		}
		var seq uint64
		x := 0.0
		for {
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
			}
			seq++
			x += 0.5
			xMu.Lock()
			lastX = x
			xMu.Unlock()
			if !sendBridge(conn, bridge.TypeLocalState, bridge.LocalState{State: &protocol.State{
				Seq: seq, Timestamp: time.Now().UnixMilli(), AreaID: "e2earea", Position: []float64{x, -3.25}, Anim: "walk",
			}}) {
				return
			}
		}
	}()
	playerX := func() float64 {
		xMu.Lock()
		defer xMu.Unlock()
		return lastX
	}
	return renders, policies, playerX, func() { stopOnce.Do(func() { close(stop) }) }
}
