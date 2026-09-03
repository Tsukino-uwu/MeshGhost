package e2e

import (
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
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
		"-chaser", "-chaser-count", "2", "-chaser-delay", "200ms", "-chaser-spacing", "100ms", "-chaser-name", "Shadow")
	renders, stop := startAdapter(t, bridgeAddr, "e2egame")
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
