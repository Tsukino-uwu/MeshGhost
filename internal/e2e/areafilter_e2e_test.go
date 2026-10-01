package e2e

import (
	"encoding/json"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// Relay-side cross-area filtering through the real binaries. The relay's unit tests check the decision; these check
// what a client stops receiving, which is what can freeze a ghost on screen.

// movingAdapter is startAdapter with an area the test can change mid-flight: a seam crossing is area_id changing
// between two consecutive states from the same peer.
func movingAdapter(t *testing.T, bridgeAddr, gameID string, area *atomic.Value) (<-chan bridge.RenderRemote, func()) {
	return movingAdapterWith(t, bridgeAddr, gameID, area, false)
}

// movingAdapterAllAreas declares render_all_areas, so its client must never be filtered by area.
func movingAdapterAllAreas(t *testing.T, bridgeAddr, gameID string, area *atomic.Value) (<-chan bridge.RenderRemote, func()) {
	return movingAdapterWith(t, bridgeAddr, gameID, area, true)
}

func movingAdapterWith(t *testing.T, bridgeAddr, gameID string, area *atomic.Value, allAreas bool) (<-chan bridge.RenderRemote, func()) {
	t.Helper()

	renders := make(chan bridge.RenderRemote, 256)
	stop := make(chan struct{})
	var stopOnce sync.Once

	go func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			func() {
				conn, err := transport.Dial(bridgeAddr)
				if err != nil {
					return
				}
				defer conn.Close()

				dead := make(chan struct{})
				var deadOnce sync.Once
				conn.OnDisconnect(func(error) { deadOnce.Do(func() { close(dead) }) })
				conn.OnReceive(func(payload []byte) {
					var env bridge.Envelope
					if json.Unmarshal(payload, &env) != nil {
						return
					}
					switch env.Type {
					case bridge.TypeRenderRemote:
						var rr bridge.RenderRemote
						if json.Unmarshal(env.Payload, &rr) == nil {
							select {
							case renders <- rr:
							default:
							}
						}
					case bridge.TypeDespawnRemote:
						// Reported as a render with an empty area, so one channel keeps arrivals and departures
						// in order.
						var dr bridge.DespawnRemote
						if json.Unmarshal(env.Payload, &dr) == nil {
							select {
							case renders <- bridge.RenderRemote{PlayerID: dr.PlayerID}:
							default:
							}
						}
					}
				})

				if !sendBridge(conn, bridge.TypeHello, bridge.Hello{GameID: gameID, RenderAllAreas: allAreas}) {
					return
				}
				var seq uint64
				for {
					select {
					case <-stop:
						return
					case <-dead:
						return
					case <-time.After(20 * time.Millisecond):
					}
					seq++
					if !sendBridge(conn, bridge.TypeLocalState, bridge.LocalState{
						State: &protocol.State{
							Seq:       seq,
							Timestamp: time.Now().UnixMilli(),
							AreaID:    area.Load().(string),
							Position:  []float64{1, 2},
							Anim:      "walk",
						},
					}) {
						return
					}
				}
			}()
			select {
			case <-stop:
				return
			case <-time.After(100 * time.Millisecond):
			}
		}
	}()

	return renders, func() { stopOnce.Do(func() { close(stop) }) }
}

// promptly bounds the assertions about timing. A frozen ghost heals on its own once core.DefaultRemoteStaleAfter ages
// it out, so waiting only for the end state would pass with the fix removed; one second is above the send interval
// and CI noise, and below that age-out.
const promptly = time.Second

// awaitPeerEvent waits for an event about the other peer that satisfies want. A despawn arrives as a RenderRemote with
// a zero State, so an empty AreaID means no longer rendered.
func awaitPeerEvent(t *testing.T, ch <-chan bridge.RenderRemote, within time.Duration, want func(bridge.RenderRemote) bool, what string) {
	t.Helper()
	deadline := time.After(within)
	for {
		select {
		case rr := <-ch:
			if want(rr) {
				return
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// TestCrossAreaFilteringIsInvisibleThroughTheRealBinaries: a peer that walks away is despawned promptly rather than
// freezing, and after a crossing ordinary forwarding resumes and the peer is visible again.
func TestCrossAreaFilteringIsInvisibleThroughTheRealBinaries(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	// A second client, so there are two real peers rather than a loopback echo.
	bridge2 := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, bridge2)

	var walkerArea, stayerArea atomic.Value
	walkerArea.Store("town")
	stayerArea.Store("town")

	walkerRenders, stopWalker := movingAdapter(t, r.bridgeAddr, "e2egame", &walkerArea)
	defer stopWalker()
	stayerRenders, stopStayer := movingAdapter(t, bridge2, "e2egame", &stayerArea)
	defer stopStayer()

	// Both in "town": each must see the other, so the filter is not simply dropping everything.
	awaitPeerEvent(t, walkerRenders, testTimeout, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "town"
	}, "the walker to see the stayer while both are in town")
	awaitPeerEvent(t, stayerRenders, testTimeout, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "town"
	}, "the stayer to see the walker while both are in town")

	// The walker crosses the seam; without the transition rule its ghost stands frozen in the stayer's town until it
	// ages out.
	walkerArea.Store("cave")
	awaitPeerEvent(t, stayerRenders, promptly, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID != "town"
	}, "the stayer to stop rendering the walker after it left town")

	// The stayer follows into the cave. This does not prove the arrival seed, since an unseeded arrival still lands
	// within promptly on the next keepalive; the relay's TestArrivalIsSeededWithPeersAlreadyInTheArea pins that.
	stayerArea.Store("cave")
	awaitPeerEvent(t, stayerRenders, promptly, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "cave"
	}, "the stayer to see the walker again after following it into the cave")
}

// TestAnAdapterAttachingLateStillDisablesAreaFiltering: a client connects to the relay at startup, before its adapter
// attaches, so its Hello cannot say whether the adapter renders other areas; a cross-map adapter that attaches later
// must still turn filtering off.
func TestAnAdapterAttachingLateStillDisablesAreaFiltering(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	bridge2 := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, bridge2)

	// The delay is the test: an adapter attaching within milliseconds can beat the client's own connect, and then the
	// Hello carries the right answer and the bug hides. A second is far more than the ~200ms a client takes to connect.
	time.Sleep(time.Second)

	// Both clients are connected with no adapter attached; anything attaching from here on is late.
	var aArea, bArea atomic.Value
	aArea.Store("town")
	bArea.Store("route")

	// The peer that renders every area.
	aRenders, stopA := movingAdapterAllAreas(t, r.bridgeAddr, "e2egame", &aArea)
	defer stopA()
	_, stopB := movingAdapter(t, bridge2, "e2egame", &bArea)
	defer stopB()

	// Different areas: a filtered client would see nothing, a cross-map one must still be sent the peer.
	awaitPeerEvent(t, aRenders, testTimeout, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "route"
	}, "a cross-map adapter attaching AFTER its client connected to still receive another area's peer")
}
