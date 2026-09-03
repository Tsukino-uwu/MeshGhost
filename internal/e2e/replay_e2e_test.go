package e2e

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestReplayFileBecomesAGhostThroughTheRealBinary is ADR 0047 end to end: a
// file dropped into replay/active/ beside the client's config renders through
// the real meshghost.exe as a cosmetic ghost carrying the header's name, with
// no second player anywhere. The relay is up only because the shipped client
// refuses an adapter it cannot connect for; the replay itself never touches it.
func TestReplayFileBecomesAGhostThroughTheRealBinary(t *testing.T) {
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

	replayDir := filepath.Join(t.TempDir(), "replay")
	if err := os.MkdirAll(filepath.Join(replayDir, "active"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A 20-sample clip of a walk across the adapter's own area, looping so the
	// test never races its end.
	var sb strings.Builder
	sb.WriteString(`{"meshghost_replay":1,"name":"PB","color":"#FF8800","speed":1.0,"loop":true,"game":"e2egame"}` + "\n")
	for i := 0; i < 20; i++ {
		sb.WriteString(`{"seq":` + strconv.Itoa(i+1) + `,"timestamp":` + strconv.FormatInt(1_000_000+int64(i)*100, 10) +
			`,"area_id":"e2earea","position":[` + strconv.Itoa(i) + `,0],"anim":"walk"}` + "\n")
	}
	if err := os.WriteFile(filepath.Join(replayDir, "active", "pb.ndjson"), []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	bridgeAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	// -interp 450ms, the shipped value, rather than startClient's 0ms: a replay
	// is drawn on its OWN schedule and must not be pushed back by the network
	// jitter buffer as well (phases/phase11.md, 2026-09-03).
	startClient(t, r.dir, r.clientBin, r.relayAddr, bridgeAddr, "-transport", "tcp",
		"-interp", "450ms", "-replay-dir", replayDir)
	renders, stop := startAdapter(t, bridgeAddr, "e2egame")
	defer stop()

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		select {
		case rr := <-renders:
			if strings.HasPrefix(rr.PlayerID, "replay:") {
				if !rr.Cosmetic {
					t.Fatalf("the replay ghost rendered without cosmetic=true: %+v", rr)
				}
				if rr.State.AreaID != "e2earea" || rr.State.Anim != "walk" {
					t.Fatalf("the replay ghost carries the wrong sample: %+v", rr.State)
				}
				awaitRemoteNameCalled(t, "PB", "the replay's header name")
				return
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	t.Fatal("no render_remote for a replay: ghost ever reached the adapter")
}
