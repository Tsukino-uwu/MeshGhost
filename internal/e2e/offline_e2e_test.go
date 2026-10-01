package e2e

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestOfflineClientRendersAReplayAndNeverDialsTheRelay: with "offline" set, the real meshghost.exe plays a replay ghost
// and never contacts the relay, not on a retry and not when the adapter's hello arrives, the second path into a dial.
// The test binds the relay address itself and counts accepts; zero is the assertion.
func TestOfflineClientRendersAReplayAndNeverDialsTheRelay(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}
	base := newRig(t)
	r := base.withFreshPorts(t)

	// The relay address is real and listening, so a client that dialed could not hide it.
	ln, err := net.Listen("tcp", r.relayAddr)
	if err != nil {
		t.Fatalf("listen on the relay address: %v", err)
	}
	defer ln.Close()
	var dials int64
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			atomic.AddInt64(&dials, 1)
			conn.Close()
		}
	}()

	replayDir := filepath.Join(t.TempDir(), "replay")
	if err := os.MkdirAll(filepath.Join(replayDir, "active"), 0o755); err != nil {
		t.Fatal(err)
	}
	var sb strings.Builder
	sb.WriteString(`{"meshghost_replay":1,"name":"Alone","speed":1.0,"loop":true,"game":"e2egame"}` + "\n")
	for i := 0; i < 20; i++ {
		sb.WriteString(`{"seq":` + strconv.Itoa(i+1) + `,"timestamp":` + strconv.FormatInt(1_000_000+int64(i)*100, 10) +
			`,"area_id":"e2earea","position":[` + strconv.Itoa(i) + `,0],"anim":"walk"}` + "\n")
	}
	if err := os.WriteFile(filepath.Join(replayDir, "active", "alone.ndjson"), []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	bridgeAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	startClient(t, r.dir, r.clientBin, r.relayAddr, bridgeAddr,
		"-transport", "tcp", "-offline", "-replay-dir", replayDir)
	renders, stop := startAdapter(t, bridgeAddr, "e2egame")
	defer stop()

	saw := false
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && !saw {
		select {
		case rr := <-renders:
			if strings.HasPrefix(rr.PlayerID, "replay:") {
				if !rr.Cosmetic {
					t.Fatalf("an offline replay rendered without cosmetic=true: %+v", rr)
				}
				saw = true
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	if !saw {
		t.Fatal("no replay ghost rendered with -offline: the bridge must still serve, since it is " +
			"how the game's mod attaches and nothing renders without it")
	}
	// Checked after the ghost: by now the client would have retried several times.
	if n := atomic.LoadInt64(&dials); n != 0 {
		t.Fatalf("an offline client opened %d connection(s) to the relay address", n)
	}
}
