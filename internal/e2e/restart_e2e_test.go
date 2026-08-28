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

// Restarts, against the real binaries.
//
// Nothing in this package restarted anything until 2026-08-22: the only
// outage covered was TestClientSurvivesARelayThatIsNotThereYet, which is the
// relay being late at STARTUP -- a different code path
// (connectRelayWithRetry) from a relay that goes away mid-session
// (reconnectWithBackoff). Meanwhile "something restarted" is the most common
// thing that actually happens to this software: a player relaunches the game,
// a host restarts the server, a client is killed and started again. The same
// week this file was written, a re-attaching adapter turned out to be told the
// wrong ghost-collision policy, and the reproduction was exactly a relaunch.
//
// All three pin -transport tcp, for the reason world_e2e_test.go documents: a
// hard-killed quic peer sends no close frame and lingers until quic's own idle
// timeout (~17s), which would dominate any assertion about a restart.

// restartTimeout is deliberately longer than the file's testTimeout.
// reconnectWithBackoff starts at 1s and doubles to a 15s cap, so a client that
// has already failed a dial or two during the outage may legitimately wait out
// a long backoff before its next attempt. A tight timeout here would report a
// working reconnect as a failure.
const restartTimeout = 60 * time.Second

// killAndWait kills a process and REAPS it. The Wait is the part that matters
// for a restart: until the process is reaped the OS may still hold its
// listening socket, so starting the replacement on the same address races a
// bind failure that has nothing to do with the code under test. t.Cleanup's
// own kill of an already-reaped process is harmless.
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

// drainRenders empties whatever the adapter has already buffered, so a later
// assertion is about renders produced AFTER the restart. startAdapter's
// channel holds 64, and without this every test here would pass on a render
// that arrived before the kill.
func drainRenders(renders <-chan bridge.RenderRemote) {
	for {
		select {
		case <-renders:
		default:
			return
		}
	}
}

// requireRendersStop is the negative control every restart test needs: it
// proves the outage was real. Without it, a "restart" that in fact killed
// nothing would still pass the recovery assertion below it.
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

// TestASessionRecoversWhenTheRelayProcessIsRestarted is the live incident
// core.go's autoRetryGameID comment records (2026-08-14: a shared relay was
// restarted under two running cores, both logged "relay disconnected", and
// both then sat there forever). The fix shipped; nothing has ever tested it
// against the real binaries.
//
// Neither the client nor the adapter is touched: recovering without human
// intervention is the whole property.
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

	// Promptly, and on the same address: the client is already backing off, so
	// every second the relay is missing is a second of backoff to wait out.
	startRelay(t, r.dir, r.relayBin, r.relayAddr)
	awaitFreshRender(t, renders, "restarting the relay")
}

// TestTheClientProcessCanBeRestartedUnderARunningAdapter is the mirror case,
// and it asserts a property the harness was built for and never exercised:
// startAdapter reconnects on its own because core deliberately closes a bridge
// connection when the relay is unreachable, so a real adapter must keep
// retrying. Nothing had ever taken the core away underneath one.
//
// Restarting on the SAME bridge port also proves the port is genuinely
// released when the process dies, which is a real Windows failure mode rather
// than a theoretical one.
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

// TestARelaunchedGameGetsAWorkingSessionAgain is a game relaunch at process
// scale: the adapter goes away and a new one attaches to the same, still
// running core. Existing e2e only proves a SECOND, concurrent adapter is
// refused -- never that the slot is released when the first one leaves, which
// is the case a player hits every time they restart the game, and the case
// TestGhostCollisionRepeatedForANewAdapter flaked on in CI.
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

// TestAutomaticTransportIsNotSilentlyDowngradedByARelayRestart is the one restart test that does
// NOT pin -transport tcp, and the exception is the point of it.
//
// Its three neighbours pin tcp for the reason this file's header gives, and that choice left a real
// gap: AUTOMATIC mode is the only mode that can silently change transport, and no restart test ever
// ran in it. A defect introduced on 2026-08-28 lived exactly there -- a transport was given up on
// after a single failed dial, so a client reconnecting while a relay's tcp listener was back but
// its quic listener was not would spend the rest of its session on tcp. Every existing test still
// passed, because the session RECOVERS; it just recovers degraded, with nothing visible on screen.
// THIS IS A GUARD, NOT A REGRESSION TEST, and the difference is worth stating because the opposite
// claim is the easy one to make. It PASSES with that defect reintroduced: a relay restarted here
// brings both listeners up together -- waitForRelayTransport below even waits for quic before the
// client reconnects -- so the race window never opens and no quic dial ever fails. Reproducing the
// race needs a relay that ADVERTISES quic while nothing accepts on that port, which is what
// core/transportfallback_test.go builds, and that is the test which fails without the fix.
//
// What this one is for is the property no other restart test asserts at all: after a real relay
// process dies and comes back, a real client is still on the transport it started on. Any future
// change that downgrades more eagerly -- on a timeout, on a Welcome failure, on a backoff -- lands
// here, and none of the neighbours would notice.
//
// It pays the cost the header describes -- a hard-killed quic client lingers until quic's own idle
// timeout -- which is what restartTimeout is for.
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

	// Auto, and given the TCP address only: reaching quic requires asking the relay.
	startClientOn(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, netx.Auto)

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()
	awaitFreshRender(t, renders, "the initial session")

	killAndWait(t, relayCmd)
	requireRendersStop(t, renders, "killing the relay")

	start(t, r.dir, r.relayBin, relayArgs...)
	waitForRelayTransport(t, netx.TCP, r.relayAddr)
	waitForRelayTransport(t, netx.QUIC, quicAddr)
	awaitFreshRender(t, renders, "restarting the relay")

	logBytes, err := os.ReadFile(filepath.Join(r.dir, "meshghost.log"))
	if err != nil {
		t.Fatalf("read client log: %v", err)
	}
	logText := string(logBytes)

	// THE ASSERTION THE OTHER RESTART TESTS CANNOT MAKE: recovered, and recovered on quic.
	if strings.Contains(logText, "not be chosen again this session") {
		t.Fatal("the client gave up on a transport across a relay restart -- the session came " +
			"back on tcp instead of quic, which no existing assertion would have noticed")
	}
	if n := strings.Count(logText, "using quic at"); n < 2 {
		t.Fatalf("client chose quic %d times, want at least 2 (once before the restart and once "+
			"after) -- it reconnected on something other than the transport it started on", n)
	}
}
