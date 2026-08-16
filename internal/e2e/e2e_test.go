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

	"meshghost/internal/bridge"
	"meshghost/internal/netx"
	"meshghost/internal/protocol"
	"meshghost/internal/transport"
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
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
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
// relay, internal/core deliberately closes the bridge connection so the
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
		relayBin:   buildBinary(t, dir, "meshghost/cmd/meshghost-relay", "meshghost-server"),
		clientBin:  buildBinary(t, dir, "meshghost/cmd/meshghost", "meshghost"),
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
