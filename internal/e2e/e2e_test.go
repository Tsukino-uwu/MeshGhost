// Package e2e drives the shipped executables as processes: real binaries, real TCP, real NDJSON, no game and no
// human. It covers what in-process tests cannot, the flag parsing, config loading and wiring in cmd/meshghost and
// cmd/meshghost-relay.
package e2e

import (
	"encoding/json"
	"math/rand/v2"
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
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
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

// buildBinary compiles one command into dir and returns its path. Built every run, never the repo root's binaries,
// which are often stale.
func buildBinary(t *testing.T, dir, pkg, base string) string {
	t.Helper()
	out := filepath.Join(dir, exeName(base))
	cmd := exec.Command("go", "build", "-o", out, pkg)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build %s: %v\n%s", pkg, err, output)
	}
	return out
}

// freePort returns a port free for both tcp and udp, since the relay binds the same number for each. Windows reserves
// blocks of the ephemeral range for one protocol and hands ephemeral ports out sequentially, so candidates rotate
// between the OS's udp pick, its tcp pick and a random port below the ephemeral range, each probed on both. The
// release-to-bind race remains; reading the address from the relay's log would tie the test to its wording.
func freePort(t *testing.T) int {
	t.Helper()
	const attempts = 200
	var lastErr error
	for i := 0; i < attempts; i++ {
		var port int
		switch i % 3 {
		case 0:
			pc, err := net.ListenPacket("udp", "127.0.0.1:0")
			if err != nil {
				lastErr = err
				continue
			}
			port = pc.LocalAddr().(*net.UDPAddr).Port
			pc.Close()
		case 1:
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				lastErr = err
				continue
			}
			port = ln.Addr().(*net.TCPAddr).Port
			ln.Close()
		default:
			// Below Windows' 49152+ ephemeral range; random so consecutive misses are never neighbours in one block.
			port = 20000 + rand.IntN(29000)
		}

		ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			lastErr = err
			continue // taken or reserved for tcp -- try a different one
		}
		ln.Close()
		pc, err := net.ListenPacket("udp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			lastErr = err
			continue // taken or reserved for udp -- try a different one
		}
		pc.Close()
		return port
	}
	// The last error is what names a reservation as one.
	t.Fatalf("could not find a port free for both tcp and udp after %d attempts (last error: %v)",
		attempts, lastErr)
	return 0
}

// start launches a binary with its working directory set to dir, where both binaries read config.json from, so no
// test depends on the repo's own shipped config.
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

// observedNames records every remote_name any adapter in this process was told. A map, not a channel: the message
// arrives once per peer, and a channel nobody was reading would make "missed" look like "never sent".
var observedNames struct {
	sync.Mutex
	byPlayer map[string]bridge.RemoteName
}

// awaitRemoteNameCalled waits for an adapter to be told a nametag with exactly this display name. Any name would not
// do: the rig invents others, such as a loopback ghost's "<name>-ghost".
func awaitRemoteNameCalled(t *testing.T, want, what string) bridge.RemoteName {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		observedNames.Lock()
		for _, rn := range observedNames.byPlayer {
			if rn.DisplayName == want {
				observedNames.Unlock()
				return rn
			}
		}
		observedNames.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no remote_name %q ever reached the adapter (%s)", want, what)
	return bridge.RemoteName{}
}

// startAdapter runs a bridge adapter against the client's bridge port and returns the render_remote messages it
// receives, plus an idempotent stop. Like every real adapter it reconnects, so a dropped bridge recovers.
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

	// One connection's lifetime: dial, say hello, then push frames until the connection dies or the test ends.
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
			if json.Unmarshal(payload, &env) != nil {
				return
			}
			if env.Type == bridge.TypeRemoteName {
				var rn bridge.RemoteName
				if json.Unmarshal(env.Payload, &rn) == nil {
					observedNames.Lock()
					if observedNames.byPlayer == nil {
						observedNames.byPlayer = map[string]bridge.RemoteName{}
					}
					observedNames.byPlayer[rn.PlayerID] = rn
					observedNames.Unlock()
				}
				return
			}
			if env.Type != bridge.TypeRenderRemote {
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
			select {
			case <-stop:
				return
			case <-time.After(100 * time.Millisecond):
			}
		}
	}()

	return renders, func() { stopOnce.Do(func() { close(stop) }) }
}

// sendBridge writes one bridge message, reporting whether it got out; a failed send is a dead connection, not a test
// failure.
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

// startRelay launches the real relay in loopback mode, returning the process so a test can kill it and start another
// on the same address.
func startRelay(t *testing.T, dir, bin, addr string) *exec.Cmd {
	t.Helper()
	cmd := start(t, dir, bin, "-addr", addr, "-loopback")
	waitForListener(t, addr)
	return cmd
}

// startClient launches the real client, returning the process and taking extra flags. A client accepts its adapter
// with no relay reachable and plays solo, so a test of the relay must assert on something only a relay produces: a
// player id, a peer's render_remote, a room event.
func startClient(t *testing.T, dir, bin, relayAddr, bridgeAddr string, extra ...string) *exec.Cmd {
	t.Helper()
	args := append([]string{
		"-relay", relayAddr,
		"-bridge", bridgeAddr,
		"-game", "e2egame",
		"-room", "e2eroom",
		"-interp", "0ms",
		"-min-send", "10ms",
	}, extra...)
	cmd := start(t, dir, bin, args...)
	waitForListener(t, bridgeAddr)
	return cmd
}

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

// TestSecondAdapterIsRejectedByTheRealBinary: a second adapter attaching to the shipped meshghost.exe is told why and
// hung up on, not silently joined to the first one's session. Both are dialed by hand because startAdapter's
// asynchronous reconnect would make which one arrived first a coin toss.
func TestSecondAdapterIsRejectedByTheRealBinary(t *testing.T) {
	r := newRig(t)
	startRelay(t, r.dir, r.relayBin, r.relayAddr)
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)

	// answers watches one connection for the core's reply to a hello: "" for bridge_ready, or the reject's reason.
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

	// The first adapter must be attached before the second dials, which bridge_ready signals.
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

// TestPortWalkFindsAFreeCore runs the adapters' port walk against real core processes, with one port of each kind the
// walk must tell apart:
//
//	P1  a real core with an adapter attached -> answers reject, skip it
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

	// P2: the squatter, an unrelated program holding a port in the range: accepts, then says nothing.
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
	// The busy core is only busy once its adapter has said hello.
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

// TestPortWalkOffersAFreePortToSpawnOn: with no core in range free, the walk offers a port where nothing listens, never
// one whose core answered busy, since an adapter only starts or stops a core it owns.
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

// TestPortWalkSkipsSeveralBusyCores: every port holds a real core, the first two with adapters attached, and the walk
// steps past both to the free one.
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
	// Both adapters must have said hello before either core counts as busy.
	time.Sleep(2 * time.Second)

	chosen, spawnable := walkPorts(t, []string{busy1, busy2, free})

	if chosen != free {
		t.Errorf("walk landed on %q, want the only free core at %q", chosen, free)
	}
	if spawnable != "" {
		t.Errorf("walk offered %q to start a core on, want none -- all three ports were taken", spawnable)
	}
}

// walkPorts is the adapters' port walk in Go: nothing listening marks a port a core could start on, a reject means
// another game's core, bridge_ready means ours. It returns the address it settled on ("" for none) and the first port
// worth starting a core on.
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
			// Silence is not acceptance: a listener that never speaks is more likely an unrelated program.
			conn.Close()
		}
	}
	return "", spawnable
}

// TestReleaseBinariesRoundTripAGhost: a state a real adapter sends comes back as a render_remote through a real client
// and a loopback relay, so it crossed the bridge, both relay legs and back.
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

// TestClientSurvivesARelayThatIsNotThereYet: a client and adapter started before the relay exists must not exit, and
// the session comes up on its own once the relay appears.
func TestClientSurvivesARelayThatIsNotThereYet(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t)

	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr)
	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()

	// Long enough for the client to fail several relay dials, so this tests recovery, not a lucky first attempt.
	time.Sleep(1500 * time.Millisecond)

	startRelay(t, r.dir, r.relayBin, r.relayAddr)

	select {
	case <-renders:
	case <-time.After(testTimeout):
		t.Fatalf("client never established a working session with a relay that "+
			"appeared after it started (waited %s)", testTimeout)
	}
}

// waitForRelayTransport is waitForListener for a transport where a bare TCP connect proves nothing: it dials as a
// client would, so success means the relay is serving that transport on that port.
func waitForRelayTransport(t *testing.T, kind netx.Kind, addr string) {
	t.Helper()
	if kind == netx.TCP {
		waitForListener(t, addr)
		return
	}
	deadline := time.Now().Add(testTimeout)
	for {
		// Trust-any: the question is whether something serves the transport, not who; the client under test verifies.
		conn, err := netx.DialWithTLS(kind, addr, time.Second, netx.TLSOptions{Verify: tlsx.TrustAnyCertificate})
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

// startRelayOn serves tcp plus kind and returns once both are up. Every client handshakes over tcp, so tcpAddr is what
// a client connects to for any kind; quic listens on its own port, which the client learns from the handshake.
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

// withFreshPorts reuses the built binaries with new ports, so a table of transports does not rebuild per entry.
func (r rig) withFreshPorts(t *testing.T) rig {
	t.Helper()
	r.relayAddr = net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	r.bridgeAddr = net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	return r
}

// TestReleaseBinariesRoundTripAGhostOnEveryTransport is TestReleaseBinariesRoundTripAGhost over each non-tcp transport
// a release ships, catching one wired in the packages but unreachable from the binaries' flags and config.
func TestReleaseBinariesRoundTripAGhostOnEveryTransport(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	base := newRig(t)
	// A release build has no udp.
	for _, kind := range []netx.Kind{netx.QUIC} {
		t.Run(kind.String(), func(t *testing.T) {
			r := base.withFreshPorts(t)
			quicAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
			startRelayOn(t, r.dir, r.relayBin, r.relayAddr, quicAddr, kind)
			// The client gets the tcp address only: the handshake is always tcp, and the relay names the real port.
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

// TestAutoTransportUpgradesToQUIC: a client told only "auto" and a tcp address finds the relay's quic port, which it
// cannot guess. It asserts on the client's log because that line is how a player tells which transport they are on.
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

// TestReleaseBinariesRoundTripAGhostOverTLS: a ghost round-trips over tcp with a room code set and no encryption flag
// on either binary. tcp because every handshake and the room code proof ride it; quic is encrypted regardless.
func TestReleaseBinariesRoundTripAGhostOverTLS(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t).withFreshPorts(t)

	start(t, r.dir, r.relayBin,
		"-loopback",
		"-transport", "tcp",
		"-room-code", "e2e-secret",
		"-addr", r.relayAddr,
	)
	waitForListener(t, r.relayAddr)

	start(t, r.dir, r.clientBin,
		"-relay", r.relayAddr,
		"-bridge", r.bridgeAddr,
		"-transport", "tcp",
		"-room-code", "e2e-secret",
		"-game", "e2egame",
		"-room", "e2eroom",
		"-interp", "0ms",
		"-min-send", "10ms",
	)
	waitForListener(t, r.bridgeAddr)

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()

	select {
	case rr := <-renders:
		if rr.State.AreaID != "e2earea" {
			t.Fatalf("ghost came back in area %q, want %q", rr.State.AreaID, "e2earea")
		}
	case <-time.After(testTimeout):
		t.Fatalf("no render_remote reached the adapter over tls within %s", testTimeout)
	}

	// Clients remember the relay by its fingerprint, so it must be in the host's log and its identity on disk to
	// survive a restart; the client keeps its known-servers file beside its config, here the same folder.
	logBytes, err := os.ReadFile(filepath.Join(r.dir, "meshghost-server.log"))
	if err != nil {
		t.Fatalf("read relay log: %v", err)
	}
	if !strings.Contains(string(logBytes), "tls certificate fingerprint:") {
		t.Fatalf("the relay never printed its certificate fingerprint. Log was:\n%s", logBytes)
	}
	for _, name := range []string{"server.key", "server.crt", "server.fingerprint", "README.txt"} {
		if _, err := os.Stat(filepath.Join(r.dir, "private", name)); err != nil {
			t.Errorf("the relay did not persist private/%s beside itself: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(r.dir, "known_servers.json")); err != nil {
		t.Errorf("the client did not write known_servers.json beside its config: %v", err)
	}
}

// TestTheClientRefusesAPlaintextRelay is the downgrade guard: a relay that speaks no TLS, an old one or an on-path
// party, must never deliver a ghost, and the client has no setting that could disable this.
func TestTheClientRefusesAPlaintextRelay(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	r := newRig(t).withFreshPorts(t)

	plain, err := net.Listen("tcp", r.relayAddr)
	if err != nil {
		t.Fatalf("listen plaintext relay: %v", err)
	}
	t.Cleanup(func() { plain.Close() })
	go func() {
		for {
			c, err := plain.Accept()
			if err != nil {
				return
			}
			// Read whatever arrives and hang up, as an old relay does with a line it cannot parse.
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
				_, _ = c.Read(make([]byte, 4096))
			}(c)
		}
	}()

	start(t, r.dir, r.clientBin,
		"-relay", r.relayAddr,
		"-bridge", r.bridgeAddr,
		"-transport", "tcp",
		"-game", "e2egame",
		"-room", "e2eroom",
		"-interp", "0ms",
		"-min-send", "10ms",
	)
	waitForListener(t, r.bridgeAddr)

	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()

	select {
	case rr := <-renders:
		t.Fatalf("a ghost (%s) came back from a PLAINTEXT relay -- the session was silently "+
			"downgraded", rr.PlayerID)
	case <-time.After(3 * time.Second):
	}
}

// TestAnAdapterJoiningARoomIsToldTheNamesAlreadyThere: a named peer is connected before the second game launches, so
// that client learns the name from its Welcome roster, not a Join, and must hand it to an adapter that attaches later.
func TestAnAdapterJoiningARoomIsToldTheNamesAlreadyThere(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and launches real binaries; skipped under -short")
	}

	observedNames.Lock()
	observedNames.byPlayer = nil
	observedNames.Unlock()

	base := newRig(t)
	r := base.withFreshPorts(t)
	// Not -loopback: a loopback echo would add a third nametag ("Alice-ghost") that races the real one.
	start(t, r.dir, r.relayBin, "-addr", r.relayAddr)
	waitForListener(t, r.relayAddr)

	// The peer who is already here, with a name.
	firstBridge := net.JoinHostPort("127.0.0.1", strconv.Itoa(freePort(t)))
	startClient(t, r.dir, r.clientBin, r.relayAddr, firstBridge, "-transport", "tcp", "-name", "Alice")
	_, stopFirst := startAdapter(t, firstBridge, "e2egame")
	defer stopFirst()

	// Now the second game launches: its client connects, and its adapter attaches after.
	startClient(t, r.dir, r.clientBin, r.relayAddr, r.bridgeAddr, "-transport", "tcp", "-name", "Bob")
	renders, stop := startAdapter(t, r.bridgeAddr, "e2egame")
	defer stop()
	awaitFreshRender(t, renders, "the two-client session")

	awaitRemoteNameCalled(t, "Alice", "a peer named Alice was in the room before this adapter attached")
}
