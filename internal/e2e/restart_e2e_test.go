package e2e

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// Restarts against the real binaries. All but one pin -transport tcp: a hard-killed quic peer sends no close frame and
// lingers until quic's idle timeout, which would dominate any assertion about a restart.

// restartTimeout is longer than testTimeout: reconnectWithBackoff doubles to a cap, so a client that failed a dial or
// two during the outage may wait out a long backoff.
const restartTimeout = 60 * time.Second

// killAndWait kills a process and reaps it: until then the OS may still hold its listening socket, and a replacement
// on the same address would race a bind failure.
func killAndWait(t *testing.T, cmd *exec.Cmd) {
	t.Helper()
	if cmd == nil || cmd.Process == nil {
		return
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatalf("kill: %v", err)
	}
	_, _ = cmd.Process.Wait()
}

// restartRelay starts a relay on an address one was just killed on, and starts it again if it exits at the bind:
// anything on the runner, such as a connection's local end, can sit on a freePort number for seconds. An exit before
// the listener answers means retry, a second apart, so a port never given back fails with the relay's own bind error
// rather than a silent timeout. A test's first start is not retried; a first bind failing means the rig is wrong.
func restartRelay(t *testing.T, dir, bin string, args ...string) *exec.Cmd {
	t.Helper()
	const attempts = 10
	addr := ""
	for i, a := range args {
		if a == "-addr" && i+1 < len(args) {
			addr = args[i+1]
		}
	}
	if addr == "" {
		t.Fatal("restartRelay: no -addr in the relay's args")
	}
	for attempt := 1; attempt <= attempts; attempt++ {
		cmd := start(t, dir, bin, args...)
		exited := make(chan struct{})
		go func() { _, _ = cmd.Process.Wait(); close(exited) }()
		deadline := time.Now().Add(testTimeout)
		for time.Now().Before(deadline) {
			select {
			case <-exited:
				t.Logf("restartRelay: attempt %d of %d exited before listening on %s (its bind error is above) -- retrying", attempt, attempts, addr)
				time.Sleep(time.Second)
				goto next
			default:
			}
			if conn, err := net.DialTimeout("tcp", addr, time.Second); err == nil {
				conn.Close()
				// Whatever holds the port may accept too, so the relay is up only if it is still alive after the dial.
				select {
				case <-exited:
					t.Logf("restartRelay: attempt %d of %d exited before listening on %s (its bind error is above) -- retrying", attempt, attempts, addr)
					time.Sleep(time.Second)
					goto next
				default:
					return cmd
				}
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatalf("restartRelay: nothing listening on %s after %v and the relay did not exit", addr, testTimeout)
	next:
	}
	t.Fatalf("restartRelay: the relay exited at every one of %d starts on %s -- the port was never given back", attempts, addr)
	return nil
}

// TestRestartRelayRetriesWhileThePortIsHeld: the test holds the port for a second, the relay's first start dies at the
// bind, and a later start comes up.
func TestRestartRelayRetriesWhileThePortIsHeld(t *testing.T) {
	r := newRig(t)
	// The holder is a connection whose local end is the port, not a listener: a listener would accept the probe dial
	// and look like a relay.
	far, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("far listener: %v", err)
	}
	defer far.Close()
	// The far end closes with the holder: a half-close leaves the port in FIN_WAIT_2 on Linux for a minute, while
	// both ends closed leave TIME_WAIT, which SO_REUSEADDR lets the relay bind through.
	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := far.Accept()
		if err != nil {
			return
		}
		accepted <- c
	}()
	local, err := net.ResolveTCPAddr("tcp", r.relayAddr)
	if err != nil {
		t.Fatalf("resolve %s: %v", r.relayAddr, err)
	}
	holder, err := (&net.Dialer{LocalAddr: local}).Dial("tcp", far.Addr().String())
	if err != nil {
		t.Fatalf("hold %s: %v", r.relayAddr, err)
	}
	farConn := <-accepted
	released := make(chan struct{})
	go func() {
		time.Sleep(time.Second)
		farConn.Close()
		holder.Close()
		close(released)
	}()
	started := time.Now()
	cmd := restartRelay(t, r.dir, r.relayBin, "-addr", r.relayAddr, "-loopback")
	<-released
	if cmd == nil || cmd.Process == nil {
		t.Fatal("restartRelay returned no process")
	}
	if took := time.Since(started); took < 500*time.Millisecond {
		t.Fatalf("the relay came up in %v while the port was still held -- the holder did not hold, so this test proved nothing", took)
	}
	waitForListener(t, r.relayAddr)
}

// drainRenders empties what the adapter already buffered, so a later assertion is about renders after the restart.
func drainRenders(renders <-chan bridge.RenderRemote) {
	for {
		select {
		case <-renders:
		default:
			return
		}
	}
}

// requireRendersStop is the negative control: it proves the outage was real, so a restart that killed nothing cannot
// pass.
func requireRendersStop(t *testing.T, renders <-chan bridge.RenderRemote, what string) {
	t.Helper()
	drainRenders(renders)
	deadline := time.Now().Add(restartTimeout)
	for time.Now().Before(deadline) {
		quiet := true
		settle := time.After(750 * time.Millisecond)
	wait:
		for {
			select {
			case <-renders:
				quiet = false
				break wait
			case <-settle:
				break wait
			}
		}
		if quiet {
			return
		}
		drainRenders(renders)
	}
	t.Fatalf("ghosts kept arriving after %s -- the outage this test depends on never happened", what)
}

// awaitFreshRender requires a render that arrives from now on.
func awaitFreshRender(t *testing.T, renders <-chan bridge.RenderRemote, what string) bridge.RenderRemote {
	t.Helper()
	select {
	case rr := <-renders:
		return rr
	case <-time.After(restartTimeout):
		t.Fatalf("no ghost completed the round trip within %s of %s", restartTimeout, what)
		return bridge.RenderRemote{}
	}
}

// TestASessionRecoversWhenTheRelayProcessIsRestarted: a relay restarted under a running client and adapter, neither of
// them touched, comes back without anyone intervening.
func TestASessionRecoversWhenTheRelayProcessIsRestarted(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)
	relayCmd := startRelay(t, r.dir, r.relayBin, r.relayAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, "-transport", "tcp")

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()
	awaitFreshRender(t, renders, "the initial session")

	killAndWait(t, relayCmd)
	requireRendersStop(t, renders, "killing the relay")

	// Promptly, on the same address: every second the relay is missing is more backoff to wait out.
	restartRelay(t, r.dir, r.relayBin, "-addr", r.relayAddr, "-loopback")
	awaitFreshRender(t, renders, "restarting the relay")
}

// TestTheClientProcessCanBeRestartedUnderARunningAdapter: the core goes away under a running adapter, which reconnects
// to its replacement on the same bridge port, so the port is released when the process dies.
func TestTheClientProcessCanBeRestartedUnderARunningAdapter(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)
	clientCmd := startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, "-transport", "tcp")

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()
	awaitFreshRender(t, renders, "the initial session")

	killAndWait(t, clientCmd)
	requireRendersStop(t, renders, "killing the client")

	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, "-transport", "tcp")
	awaitFreshRender(t, renders, "restarting the client")
}

// TestARelaunchedGameGetsAWorkingSessionAgain: an adapter leaves and a new one attaches to the same running core, so
// the slot is released, as every game relaunch needs.
func TestARelaunchedGameGetsAWorkingSessionAgain(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, "-transport", "tcp")

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	first := awaitFreshRender(t, renders, "the initial session")
	if first.PlayerID == "" {
		t.Fatal("the first session's render carried no player_id")
	}
	stop()

	// A fresh adapter against the same core, exactly as a relaunched game does.
	relaunched, stopAgain := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stopAgain()
	again := awaitFreshRender(t, relaunched, "relaunching the adapter")
	if again.PlayerID == "" {
		t.Error("the relaunched game's render carried no player_id")
	}
}

// TestAutomaticTransportIsNotSilentlyDowngradedByARelayRestart: after a real relay dies and comes back, a client in
// automatic mode is still on quic, so it does not pin tcp and pays quic's linger. A guard, not a regression test: both
// listeners return together here, so the race core/transportfallback_test.go reproduces never opens.
func TestAutomaticTransportIsNotSilentlyDowngradedByARelayRestart(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	base := newRig(t)
	r := base.withFreshPorts(t)
	quicAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	relayArgs := []string{
		"-loopback", "-transport", "tcp,quic", "-addr", r.relayAddr, "-listen-quic", quicAddr,
	}

	relayCmd := start(t, r.dir, r.relayBin, relayArgs...)
	waitForRelayTransport(t, netx.TCP, r.relayAddr)
	waitForRelayTransport(t, netx.QUIC, quicAddr)

	// Auto, given the tcp address only: reaching quic requires asking the relay.
	startClientOn(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, netx.Auto)

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()
	awaitFreshRender(t, renders, "the initial session")

	killAndWait(t, relayCmd)
	requireRendersStop(t, renders, "killing the relay")

	restartRelay(t, r.dir, r.relayBin, relayArgs...)
	waitForRelayTransport(t, netx.TCP, r.relayAddr)
	waitForRelayTransport(t, netx.QUIC, quicAddr)
	awaitFreshRender(t, renders, "restarting the relay")

	logBytes, err := os.ReadFile(filepath.Join(r.dir, "meshghost.log"))
	if err != nil {
		t.Fatalf("read client log: %v", err)
	}
	logText := string(logBytes)

	// Recovered, and recovered on quic.
	if strings.Contains(logText, "not be chosen again this session") {
		t.Fatal("the client gave up on a transport across a relay restart -- the session came " +
			"back on tcp instead of quic, which no existing assertion would have noticed")
	}
	if n := strings.Count(logText, "using quic at"); n < 2 {
		t.Fatalf("client chose quic %d times, want at least 2 (once before the restart and once "+
			"after) -- it reconnected on something other than the transport it started on", n)
	}
}
