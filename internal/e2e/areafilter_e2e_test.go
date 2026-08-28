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

// Relay-side cross-area filtering, through the real binaries.
//
// The unit tests in relay/areafilter_test.go check the decision; this checks
// the CONSEQUENCE, which is the part that can put a defect on a player's
// screen. Two real clients, two real adapters, one real relay, and a peer that
// walks across a seam -- the shape of the live Emerald check, minus the game.
//
// It exists because the two hazards here are both about what a client STOPS
// receiving, and a test that only asserts "the filter dropped something" would
// pass while a ghost froze on screen.

// movingAdapter is startAdapter with an area the test can change mid-flight,
// which is the whole point: a seam crossing is an area_id changing between two
// consecutive states from the same peer.
func movingAdapter(t *testing.T, bridgeAddr, gameID string, area *atomic.Value) (<-chan bridge.RenderRemote, func()) {
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
						// Reported as a render with an empty area so one
						// channel carries both halves of the story in order --
						// which matters, since "appeared" and "went away" are
						// only meaningful relative to each other.
						var dr bridge.DespawnRemote
						if json.Unmarshal(env.Payload, &dr) == nil {
							select {
							case renders <- bridge.RenderRemote{PlayerID: dr.PlayerID}:
							default:
							}
						}
					}
				})

				if !sendBridge(conn, bridge.TypeHello, bridge.Hello{GameID: gameID}) {
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

// promptly is the deadline for the two assertions that are about TIMING rather
// than about eventual correctness, and picking it is the whole difficulty of
// this test.
//
// Both of the defects here heal on their own eventually -- a frozen ghost is
// removed by core.DefaultRemoteStaleAfter (3s), and an unseeded arrival appears
// on the peer's next IdleKeepalive (250ms). So a test that simply waits for the
// right end state passes with the fix REMOVED, just more slowly. That is not a
// hypothetical: the first version of this test did exactly that, and was
// confirmed useless by deleting the transition rule and watching it stay green.
//
// One second: comfortably above the ~20ms send interval and any scheduling
// noise on a loaded CI runner, and comfortably below the 3s age-out that would
// otherwise mask the bug.
const promptly = time.Second

// awaitPeerEvent waits for an event about the OTHER peer that satisfies want,
// within the given deadline. A despawn arrives as a RenderRemote with a zero
// State, so an empty AreaID means "no longer rendered".
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

// The two properties that together make the filter invisible on screen:
// a peer that walks away is despawned promptly rather than freezing, and a peer
// standing in the area you walk INTO appears without waiting for it to move.
//
// The second is the one change suppression makes load-bearing: a motionless
// peer re-states only every keepalive, so without the relay's arrival seed a
// filtered client would walk into an empty-looking room.
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

	// Both in "town": each must see the other, which also proves the filter is
	// not simply dropping everything.
	awaitPeerEvent(t, walkerRenders, testTimeout, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "town"
	}, "the walker to see the stayer while both are in town")
	awaitPeerEvent(t, stayerRenders, testTimeout, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "town"
	}, "the stayer to see the walker while both are in town")

	// The walker crosses the seam. The stayer must be told -- that is the
	// transition rule, and without it the walker's ghost stands frozen in the
	// stayer's town until the 3s stale-after timer removes it.
	walkerArea.Store("cave")
	awaitPeerEvent(t, stayerRenders, promptly, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID != "town"
	}, "the stayer to stop rendering the walker after it left town")

	// Now the stayer follows into the cave and must see the walker there.
	//
	// This assertion does NOT prove the arrival seed, and saying so is the
	// point: removing the seed and running this at -count=3 keeps it green,
	// because an unseeded arrival still resolves on the peer's next
	// IdleKeepalive (250ms), comfortably inside `promptly`. The seed's whole
	// value is bounded by that keepalive -- it turns "up to a quarter second
	// of an empty-looking room at every seam" into "immediately" -- and it is
	// relay/areafilter_test.go's TestArrivalIsSeededWithPeersAlreadyInTheArea
	// that actually pins it. What this covers is the plainer property: after a
	// crossing, ordinary forwarding resumes and the peer is visible again.
	stayerArea.Store("cave")
	awaitPeerEvent(t, stayerRenders, promptly, func(rr bridge.RenderRemote) bool {
		return rr.State.AreaID == "cave"
	}, "the stayer to see the walker again after following it into the cave")
}
