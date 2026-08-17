// Package e2e drives the actual shipped executables as processes.
//
// Everything else in this repo's test suite exercises packages in-process.
// That leaves a real gap: cmd/meshghost and cmd/meshghost-relay contain flag
// parsing, config loading, and the wiring that turns those into a Core and a
// Server, and the only tests touching them check config-file BOM handling.
// A change that wired a flag to the wrong field, or dropped the bridge
// listener entirely, would pass every existing test and still ship a broken
// meshghost.exe.
//
// Covering that used to mean running dev-scripts by hand -- launch
// run-relay-loopback.bat, launch run-core-*.bat, attach something that
// speaks the bridge protocol, and look. This is that rig, automated: real
// binaries, real TCP, real NDJSON, no game and no human.
package e2e

import (
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

const (
	testTimeout = 20 * time.Second
	pollEvery   = 25 * time.Millisecond
)

func exeName(base string) string {
	if runtime.GOOS == "windows" {
		return base + ".exe"
	}
	return base
}

// buildBinary compiles one command into dir and returns its path. Built from
// source every run rather than reusing whatever sits at the repo root: those
// root binaries are stale far more often than anyone expects (CLAUDE.md has
// a standing rule about it after a bug repro once ran against binaries a
// full day old), and a test that silently exercises yesterday's build is
// worse than no test.
func buildBinary(t *testing.T, dir, pkg, base string) string {
	t.Helper()
	out := filepath.Join(dir, exeName(base))
	cmd := exec.Command("go", "build", "-o", out, pkg)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build %s: %v\n%s", pkg, err, output)
	}
	return out
}

// freePort asks the OS for a port, then releases it. There is an inherent
// race between releasing and the child process binding, but the alternative
// is parsing an address out of the relay's log output, which would couple
// this test to a log line's exact wording. On a loopback-only test machine
// the window is not a practical problem.
//
// It checks the port is free for UDP as well as TCP, and retries if it isn't.
// Asking for a TCP port only proves a TCP port is free, and the relay binds
// the SAME number for udp (and another for quic, which is udp underneath), so
// the two were never the same question. On Windows they can differ outright:
// Hyper-V/WinNAT reserve blocks of the ephemeral range, and a udp bind inside
// one fails with "An attempt was made to access a socket in a way forbidden by
// its access permissions" (WSAEACCES) on a number TCP handed out happily.
//
// Found 2026-08-16 when a release build failed on exactly that, three tests at
// once, on ports 63503/63536/63555. It is luck-of-the-draw, which is worse than
// a reliable failure: it had passed on the same code minutes earlier, so
// re-running would have "fixed" it and taught us nothing.
func freePort(t *testing.T) int {
	t.Helper()
	const attempts = 20
	for i := 0; i < attempts; i++ {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("reserve port: %v", err)
		}
		port := ln.Addr().(*net.TCPAddr).Port
		ln.Close()

		// Probe udp on the same number. Closed immediately: this only answers
		// "is this number usable", the same way the tcp listen above does.
		pc, err := net.ListenPacket("udp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			continue // reserved or taken for udp -- ask for a different one
		}
		pc.Close()
		return port
	}
	t.Fatalf("could not find a port free for both tcp and udp after %d attempts", attempts)
	return 0
}

// start launches a binary with cwd set to dir. cwd matters: both binaries
// read config.json from the working directory, so without this they would
// pick up the repo's own packaging/release/config.json and the test would
// depend on whatever that file currently says.
func start(t *testing.T, dir, bin string, args ...string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %s: %v", bin, err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	return cmd
}

func waitForListener(t *testing.T, addr string) {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for {
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("nothing listening on %s after %s", addr, testTimeout)
		}
		time.Sleep(pollEvery)
	}
}

// startAdapter runs a bridge adapter against the client's bridge port and
// returns the render_remote messages it receives.
//
// It reconnects, which is not incidental: when the client cannot reach the
// relay, core deliberately closes the bridge connection so the
// adapter retries later (see core.go's bridge Hello handler and
// adapters/_template/PROTOCOL.md's "non-blocking, retry next frame on
// failure"). Every real adapter -- the BizHawk Lua, TEVI's plugin,
// Pseudoregalia's mod -- has this loop. An adapter without one appears to
// work whenever the relay happens to be up first and silently never
// recovers otherwise, which is exactly the ordering
// TestClientSurvivesARelayThatIsNotThereYet covers.
//
// The returned stop function is idempotent so a test can both defer it and
// call it early.
func startAdapter(t *testing.T, bridgeAddr, gameID string) (<-chan bridge.RenderRemote, func()) {
	t.Helper()

	renders := make(chan bridge.RenderRemote, 64)
	stop := make(chan struct{})
	var stopOnce sync.Once

	stopped := func() bool {
		select {
		case <-stop:
			return true
		default:
			return false
		}
	}

	// One connection's lifetime: dial, say hello, then push frames until the
	// connection dies or the test ends.
	session := func() {
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
			if json.Unmarshal(payload, &env) != nil || env.Type != bridge.TypeRenderRemote {
				return
			}
			var rr bridge.RenderRemote
			if json.Unmarshal(env.Payload, &rr) == nil {
				select {
				case renders <- rr:
				default: // a full buffer means the test already has what it needs
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
			ok := sendBridge(conn, bridge.TypeLocalState, bridge.LocalState{
				State: &protocol.State{
					Seq:       seq,
					Timestamp: time.Now().UnixMilli(),
					AreaID:    "e2earea",
					Position:  []float64{12.5, -3.25},
					Anim:      "walk",
				},
			})
			if !ok {
				return
			}
		}
	}

	go func() {
		for !stopped() {
			session()
			// Same shape as a real adapter's retry: pause briefly rather
			// than spinning on a client that isn't ready.
			select {
			case <-stop:
				return
			case <-time.After(100 * time.Millisecond):
			}
		}
	}()

	return renders, func() { stopOnce.Do(func() { close(stop) }) }
}

// sendBridge writes one bridge message, reporting whether it got out. A
// failed send here means the connection died, which is a normal event this
// adapter recovers from -- not a test failure.
func sendBridge(conn *transport.NDJSONConn, typ bridge.MessageType, payload any) bool {
	b, err := json.Marshal(payload)
	if err != nil {
		return false
	}
	env, err := json.Marshal(bridge.Envelope{Type: typ, Payload: b})
	if err != nil {
		return false
	}
	return conn.Send(env) == nil
}

// startRelay and startClient launch the real binaries with the flags the
// dev-scripts use, minus the personal paths.
func startRelay(t *testing.T, dir, bin, addr string) {
	t.Helper()
	start(t, dir, bin, "-addr", addr, "-loopback")
	waitForListener(t, addr)
}

func startClient(t *testing.T, dir, bin, relayAddr, bridgeAddr string) {
	t.Helper()
	start(t, dir, bin,
		"-relay", relayAddr,
		"-bridge", bridgeAddr,
		"-game", "e2egame",
		"-room", "e2eroom",
		"-interp", "0ms",
		"-min-send", "10ms",
	)
	waitForListener(t, bridgeAddr)
}

// rig builds both binaries and picks their ports.
type rig struct {
	dir        string
	relayBin   string
	clientBin  string
	relayAddr  string
	bridgeAddr string
}

func newRig(t *testing.T) rig {
	t.Helper()
	dir := t.TempDir()
	return rig{
		dir:        dir,
		relayBin:   buildBinary(t, dir, "github.com/Tsukino-uwu/MeshGhost/cmd/meshghost-relay", "meshghost-server"),
		clientBin:  buildBinary(t, dir, "github.com/Tsukino-uwu/MeshGhost/cmd/meshghost", "meshghost"),
		relayAddr:  net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t))),
		bridgeAddr: net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t))),
	}
}

// TestReleaseBinariesRoundTripAGhost is the automated form of the loopback
// check a human otherwise performs by launching two dev-scripts and watching
// the screen: a real relay process in loopback mode, a real client process,
// and a real adapter on the bridge. A state sent in must come back as a
// render_remote, which means it crossed the bridge, the client's relay
// connection, the relay's forwarding path, and all the way back.
// TestSecondAdapterIsRejectedByTheRealBinary is the end-to-end half of the
// core's admission-control tests: against the ACTUAL shipped meshghost.exe, a
// second adapter attaching to a core that already has one is told why and hung
// up on, rather than silently joining and sharing the first one's relay session.
//
// Worth having at this level as well as in core because the failure it
// guards is invisible by nature -- both adapters used to log a normal
// "connected" -- so a unit test passing while the real binary misbehaved would
// look exactly like success.
//
// Both adapters are dialed by hand rather than through startAdapter, because
// startAdapter connects asynchronously and reconnects on drop: which of the two
// reached the core first would be a coin toss, and the test would sometimes
// assert against whichever one lost.
func TestSecondAdapterIsRejectedByTheRealBinary(t *testing.T) {
	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)

	// answers watches one bridge connection for the core's reply to a hello:
	// "" for bridge_ready, or the reason for a reject.
	answers := func(conn *transport.NDJSONConn) <-chan string {
		out := make(chan string, 1)
		conn.OnReceive(func(payload []byte) {
			var env bridge.Envelope
			if json.Unmarshal(payload, &env) != nil {
				return
			}
			switch env.Type {
			case bridge.TypeBridgeReady:
				select {
				case out <- "":
				default:
				}
			case bridge.TypeReject:
				var rj bridge.Reject
				if json.Unmarshal(env.Payload, &rj) == nil {
					select {
					case out <- rj.Reason:
					default:
					}
				}
			}
		})
		return out
	}

	// The first adapter must be fully attached before the second dials, and
	// bridge_ready is exactly that signal -- it is why the core sends one.
	first, err := transport.Dial(r.bridgeAddr)
	if err != nil {
		t.Fatalf("first adapter dial: %v", err)
	}
	defer first.Close()
	firstAnswer := answers(first)
	if !sendBridge(first, bridge.TypeHello, bridge.Hello{GameID: "e2egame"}) {
		t.Fatal("first adapter could not send hello")
	}
	select {
	case reason := <-firstAnswer:
		if reason != "" {
			t.Fatalf("first adapter was rejected (%q), want it accepted", reason)
		}
	case <-time.After(testTimeout):
		t.Fatal("first adapter never got bridge_ready")
	}

	second, err := transport.Dial(r.bridgeAddr)
	if err != nil {
		t.Fatalf("second adapter dial: %v", err)
	}
	defer second.Close()
	secondAnswer := answers(second)
	if !sendBridge(second, bridge.TypeHello, bridge.Hello{GameID: "e2egame"}) {
		t.Fatal("second adapter could not send hello")
	}
	select {
	case reason := <-secondAnswer:
		if reason == "" {
			t.Fatal("second adapter was ACCEPTED -- the real binary still lets two adapters " +
				"share one core, which silently corrupts both sessions")
		}
	case <-time.After(testTimeout):
		t.Fatal("second adapter got no answer at all, want a reject with a reason")
	}
}

// TestPortWalkFindsAFreeCore models the port walk each adapter performs
// (Pseudoregalia's BridgeClient today, TEVI and Emerald later) against REAL
// core processes, so the sequence the C++ implements is checked even though the
// C++ itself cannot run here without the game.
//
// It exists because the interesting cases cannot be produced by hand: Steam
// refuses a second Pseudoregalia, so "two instances" is untestable on the dev
// machine, and a foreign program squatting on a bridge port is not something
// anyone can arrange on demand either. Both are just listeners, so a test can
// hold them.
//
// Three ports, one of each kind the walk must tell apart:
//
//	P1  a real core WITH an adapter attached -> answers reject, skip it
//	P2  something else entirely, accepting connections and never speaking
//	P3  a real core with nothing attached    -> answers bridge_ready, use it
func TestPortWalkFindsAFreeCore(t *testing.T) {
	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	busyAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	squatAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	freeAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))

	// P1: a core with an adapter already on it.
	startClient(t, r.dir, r.clientBin, r.relayAddr, busyAddr)
	_, stopAdapter := startAdapter(t, busyAddr, "e2egame")
	defer stopAdapter()

	// P3: a core with nobody on it.
	startClient(t, r.dir, r.clientBin, r.relayAddr, freeAddr)

	// P2: the squatter. Accepts, reads nothing, answers nothing -- the shape of
	// an unrelated program that happens to hold a port in our range.
	squatLn, err := net.Listen("tcp", squatAddr)
	if err != nil {
		t.Fatalf("squatter listen: %v", err)
	}
	defer squatLn.Close()
	go func() {
		var held []net.Conn
		defer func() {
			for _, c := range held {
				c.Close()
			}
		}()
		for {
			c, err := squatLn.Accept()
			if err != nil {
				return
			}
			held = append(held, c) // hold it open, say nothing
		}
	}()

	waitForListener(t, busyAddr)
	waitForListener(t, freeAddr)
	// The busy core is only busy once its adapter has actually said hello;
	// without this the first candidate is a race rather than a known state.
	time.Sleep(2 * time.Second)

	chosen, spawnable := walkPorts(t, []string{busyAddr, squatAddr, freeAddr})

	if chosen != freeAddr {
		t.Errorf("walk landed on %q, want the free core at %q", chosen, freeAddr)
	}
	if spawnable != "" {
		t.Errorf("walk offered %q as somewhere to start a core, want none -- every port "+
			"had a listener, so starting one would collide", spawnable)
	}
}

// TestPortWalkOffersAFreePortToSpawnOn is the other half: when nothing in range
// will have the adapter, the walk must report a port where NOTHING is listening,
// which is where the mod starts a core. It must never offer a port that answered
// and said it was busy -- that is another game's core, and contract.md is
// explicit that an adapter only ever starts or stops a core it owns.
func TestPortWalkOffersAFreePortToSpawnOn(t *testing.T) {
	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	busyAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	emptyAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))

	startClient(t, r.dir, r.clientBin, r.relayAddr, busyAddr)
	_, stopAdapter := startAdapter(t, busyAddr, "e2egame")
	defer stopAdapter()
	waitForListener(t, busyAddr)
	time.Sleep(2 * time.Second)

	chosen, spawnable := walkPorts(t, []string{busyAddr, emptyAddr})

	if chosen != "" {
		t.Errorf("walk settled on %q, want nothing usable", chosen)
	}
	if spawnable != emptyAddr {
		t.Errorf("walk offered %q to start a core on, want the empty port %q", spawnable, emptyAddr)
	}
}

// TestPortWalkSkipsSeveralBusyCores is the same question with no fakes at all:
// every port here holds a REAL meshghost.exe, the first two with real adapters
// attached, and the walk has to step past both to reach the free one.
//
// This is the scenario the dev machine cannot produce by hand -- Steam refuses
// a second Pseudoregalia, so "two games already running, start a third" only
// exists here. TestPortWalkFindsAFreeCore covers the one case real cores cannot
// simulate (something that is not MeshGhost at all holding a port); this covers
// the case that needs no simulation.
func TestPortWalkSkipsSeveralBusyCores(t *testing.T) {
	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	busy1 := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	busy2 := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	free := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))

	for _, addr := range []string{busy1, busy2, free} {
		startClient(t, r.dir, r.clientBin, r.relayAddr, addr)
		waitForListener(t, addr)
	}
	for _, addr := range []string{busy1, busy2} {
		_, stop := startAdapter(t, addr, "e2egame")
		defer stop()
	}
	// Both adapters need to have said hello before either core counts as busy.
	time.Sleep(2 * time.Second)

	chosen, spawnable := walkPorts(t, []string{busy1, busy2, free})

	if chosen != free {
		t.Errorf("walk landed on %q, want the only free core at %q", chosen, free)
	}
	if spawnable != "" {
		t.Errorf("walk offered %q to start a core on, want none -- all three ports were taken", spawnable)
	}
}

// walkPorts is the adapter-side algorithm from agent_docs/contract.md, written
// in Go: for each candidate, connect; nothing listening marks a port a core
// could be started on; a reject means somebody else's core; bridge_ready means
// this one is ours. Returns the address it settled on ("" for none) and the
// first port worth starting a core on.
func walkPorts(t *testing.T, addrs []string) (chosen, spawnable string) {
	t.Helper()
	const answerTimeout = 1500 * time.Millisecond

	for _, addr := range addrs {
		conn, err := transport.Dial(addr)
		if err != nil {
			if spawnable == "" {
				spawnable = addr
			}
			continue
		}

		answer := make(chan bridge.MessageType, 1)
		conn.OnReceive(func(payload []byte) {
			var env bridge.Envelope
			if json.Unmarshal(payload, &env) != nil {
				return
			}
			if env.Type == bridge.TypeBridgeReady || env.Type == bridge.TypeReject {
				select {
				case answer <- env.Type:
				default:
				}
			}
		})
		if !sendBridge(conn, bridge.TypeHello, bridge.Hello{GameID: "e2egame"}) {
			conn.Close()
			continue
		}

		select {
		case got := <-answer:
			if got == bridge.TypeBridgeReady {
				return addr, spawnable
			}
			conn.Close() // rejected -- somebody else's core
		case <-time.After(answerTimeout):
			// Silence is NOT acceptance. Something that accepts a connection and
			// then never speaks is far more likely an unrelated program than a
			// MeshGhost core, and committing to it strands the adapter with no
			// ghosts and no explanation -- the exact silent failure this whole
			// change exists to remove. Skipping an older core costs nothing by
			// comparison: the walk simply starts its own on a free port.
			conn.Close()
		}
	}
	return "", spawnable
}

func TestReleaseBinariesRoundTripAGhost(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()

	select {
	case rr := <-renders:
		if rr.PlayerID == "" {
			t.Fatal("render_remote carried an empty player_id")
		}
		if rr.State.AreaID != "e2earea" {
			t.Fatalf("ghost came back in area %q, want %q", rr.State.AreaID, "e2earea")
		}
		if len(rr.State.Position) != 2 {
			t.Fatalf("ghost position has %d components, want 2 (sent [12.5,-3.25])",
				len(rr.State.Position))
		}
		if rr.State.Anim != "walk" {
			t.Fatalf("ghost anim is %q, want %q", rr.State.Anim, "walk")
		}
	case <-time.After(testTimeout):
		t.Fatalf("no render_remote reached the adapter within %s -- the state never "+
			"completed the bridge -> client -> relay -> client -> bridge round trip", testTimeout)
	}
}

// TestClientSurvivesARelayThatIsNotThereYet covers an ordering real users hit
// constantly and no dev-script exercises deliberately: the client (and its
// adapter) started before the relay exists. Nothing may exit, and the session
// must come up on its own once the relay appears -- no restart, no human.
func TestClientSurvivesARelayThatIsNotThereYet(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)

	// Client and adapter first, with nothing to connect to.
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)
	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()

	// Long enough for the client to fail several relay dials and for the
	// core to have closed the adapter's bridge connection at least once, so
	// this really tests recovery rather than a lucky first attempt.
	time.Sleep(1500 * time.Millisecond)

	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	select {
	case <-renders:
	case <-time.After(testTimeout):
		t.Fatalf("client never established a working session with a relay that "+
			"appeared after it started (waited %s)", testTimeout)
	}
}

// waitForRelayTransport is waitForListener for a transport where a bare TCP
// connect proves nothing. It dials the way a real client would — which for
// udp means completing the address-validation exchange, and for quic the
// TLS handshake — so a successful probe means the relay is genuinely
// serving that transport on that port, not merely that something is bound.
func waitForRelayTransport(t *testing.T, kind netx.Kind, addr string) {
	t.Helper()
	if kind == netx.TCP {
		waitForListener(t, addr)
		return
	}
	deadline := time.Now().Add(testTimeout)
	for {
		conn, err := netx.Dial(kind, addr, time.Second)
		if err == nil {
			conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("nothing serving %s on %s after %s: %v", kind, addr, testTimeout, err)
		}
		time.Sleep(pollEvery)
	}
}

// startRelayOn is startRelay for a chosen transport. quic gets its own
// address because it runs over udp and so cannot share a port with the
// plain udp transport.
// startRelayOn serves tcp plus kind, and returns once both are up.
//
// tcp is not optional: netx.ParseKinds adds it whether or not it is named,
// because every client handshakes over tcp before moving to its configured
// transport. tcpAddr is therefore what a client connects to for ANY kind —
// quic in particular listens elsewhere (it runs over udp and cannot share a
// port with the plain udp transport), and the client learns that port from
// the handshake rather than being told it.
func startRelayOn(t *testing.T, dir, bin, tcpAddr, quicAddr string, kind netx.Kind) {
	t.Helper()
	args := []string{"-loopback", "-transport", "tcp," + kind.String(), "-addr", tcpAddr}
	if kind == netx.QUIC {
		args = append(args, "-listen-quic", quicAddr)
	}
	start(t, dir, bin, args...)
	waitForRelayTransport(t, netx.TCP, tcpAddr)
	if kind == netx.QUIC {
		waitForRelayTransport(t, netx.QUIC, quicAddr)
	} else if kind != netx.TCP {
		waitForRelayTransport(t, kind, tcpAddr)
	}
}

func startClientOn(t *testing.T, dir, bin, relayAddr, bridgeAddr string, kind netx.Kind) {
	t.Helper()
	start(t, dir, bin,
		"-relay", relayAddr,
		"-bridge", bridgeAddr,
		"-transport", kind.String(),
		"-game", "e2egame",
		"-room", "e2eroom",
		"-interp", "0ms",
		"-min-send", "10ms",
	)
	waitForListener(t, bridgeAddr)
}

// withFreshPorts reuses an already-built pair of binaries with new ports,
// so a table of transports does not pay for a rebuild per entry — which
// matters more now that quic-go is linked in.
func (r rig) withFreshPorts(t *testing.T) rig {
	t.Helper()
	r.relayAddr = net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	r.bridgeAddr = net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	return r
}

// TestReleaseBinariesRoundTripAGhostOnEveryTransport is
// TestReleaseBinariesRoundTripAGhost repeated for udp and quic: the real
// relay and client processes, launched with -transport, carrying a real
// ghost all the way from the adapter's bridge socket, out over the chosen
// transport, through the relay and back.
//
// This is the test that would catch a transport wired correctly in the
// packages but not actually reachable from the shipped binaries' flags and
// config — the gap between "the unit tests pass" and "a user can turn it
// on", which is the entire reason internal/e2e exists.
func TestReleaseBinariesRoundTripAGhostOnEveryTransport(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	base := newRig(t)
	for _, kind := range []netx.Kind{netx.UDP, netx.QUIC} {
		t.Run(kind.String(), func(t *testing.T) {
			r := base.withFreshPorts(t)
			quicAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
			startRelayOn(t, r.dir, r.relayBin, r.relayAddr, quicAddr, kind)
			// The client is given the TCP address only, for every kind: the
			// handshake is always tcp, and the real transport's port comes
			// back from the relay.
			startClientOn(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, kind)

			renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
			defer stop()

			select {
			case rr := <-renders:
				if rr.PlayerID == "" {
					t.Fatal("render_remote carried an empty player_id")
				}
				if rr.State.AreaID != "e2earea" {
					t.Fatalf("ghost came back in area %q, want %q", rr.State.AreaID, "e2earea")
				}
				if rr.State.Anim != "walk" {
					t.Fatalf("ghost anim is %q, want %q", rr.State.Anim, "walk")
				}
			case <-time.After(testTimeout):
				t.Fatalf("no render_remote reached the adapter over %s within %s", kind, testTimeout)
			}
		})
	}
}

// TestAutoTransportUpgradesToQUIC is the discovery feature end to end: a
// real client told only "auto" and a tcp address finds the relay's quic
// port, which it could not possibly have guessed — quic runs on a
// different port, so there is nothing to probe for.
//
// It asserts on the client's own log rather than on packet contents
// because that log line is also the user-visible artifact: without it, a
// user has no way to tell which transport they actually ended up on.
func TestAutoTransportUpgradesToQUIC(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	base := newRig(t)
	r := base.withFreshPorts(t)
	quicAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))

	start(t, r.dir, r.relayBin,
		"-loopback",
		"-transport", "tcp,quic",
		"-addr", r.relayAddr,
		"-listen-quic", quicAddr,
	)
	waitForRelayTransport(t, netx.TCP, r.relayAddr)
	waitForRelayTransport(t, netx.QUIC, quicAddr)

	// The client is given the TCP address only. Finding quic requires
	// asking the relay.
	startClientOn(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, netx.Auto)

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()

	select {
	case rr := <-renders:
		if rr.State.AreaID != "e2earea" {
			t.Fatalf("ghost came back in area %q, want %q", rr.State.AreaID, "e2earea")
		}
	case <-time.After(testTimeout):
		t.Fatalf("no render_remote reached the adapter with transport=auto within %s", testTimeout)
	}

	logBytes, err := os.ReadFile(filepath.Join(r.dir, "meshghost.log"))
	if err != nil {
		t.Fatalf("read client log: %v", err)
	}
	logText := string(logBytes)
	wantPort := quicAddr[strings.LastIndex(quicAddr, ":"):]
	if !strings.Contains(logText, "using quic at") || !strings.Contains(logText, wantPort) {
		t.Fatalf("client did not report upgrading to quic on %s. Log was:\n%s", quicAddr, logText)
	}
}
