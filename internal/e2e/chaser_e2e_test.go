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

// TestChaserFollowsThroughTheRealBinary: -chaser on the shipped client makes
// a cosmetic "chaser:1" ghost render to the adapter, named from the flag,
// with nothing but the adapter's own frames feeding it.
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
	startClient(t, r.dir, r.clientBin, r.relayAddr, bridgeAddr, "-transport", "tcp",
		"-chaser", "-chaser-count", "2", "-chaser-delay", "200ms", "-chaser-spacing", "100ms",
		"-chaser-spawn-delay", "100ms", "-chaser-name", "Shadow")
	// A MOVING player: a chaser never spawns on one who stands still (the
	// spawn window, core/chaser.go), and the shared driver sends one fixed
	// position every frame, which is exactly a standing player.
	renders, stop := startMovingAdapter(t, bridgeAddr, "e2egame")
	defer stop()

	seen := map[string]bool{}
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && len(seen) < 2 {
		select {
		case rr := <-renders:
			if strings.HasPrefix(rr.PlayerID, "chaser:") {
				if !rr.Cosmetic {
					t.Fatalf("a chaser rendered without cosmetic=true: %+v", rr)
				}
				seen[rr.PlayerID] = true
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	if len(seen) < 2 {
		t.Fatalf("saw chasers %v, want chaser:1 and chaser:2", seen)
	}
	awaitRemoteNameCalled(t, "Shadow 1", "the first chaser's numbered nametag")
}

// startMovingAdapter is startAdapter with a player who walks: x advances every
// frame. Kept beside the one test that needs it rather than folded into the
// shared driver, whose fixed position every other test relies on.
func startMovingAdapter(t *testing.T, bridgeAddr, gameID string) (<-chan bridge.RenderRemote, func()) {
	t.Helper()
	renders := make(chan bridge.RenderRemote, 64)
	stop := make(chan struct{})
	var stopOnce sync.Once
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
			if !sendBridge(conn, bridge.TypeLocalState, bridge.LocalState{State: &protocol.State{
				Seq: seq, Timestamp: time.Now().UnixMilli(), AreaID: "e2earea", Position: []float64{x, -3.25}, Anim: "walk",
			}}) {
				return
			}
		}
	}()
	return renders, func() { stopOnce.Do(func() { close(stop) }) }
}
