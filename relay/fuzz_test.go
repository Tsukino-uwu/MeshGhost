package relay

import (
	"encoding/json"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// FuzzRelaySurvivesArbitraryLines is the end-to-end counterpart to the
// parser fuzzing in protocol and transport: it throws
// arbitrary bytes at a real, running relay and then checks the relay can
// still serve a legitimate client.
//
// This is the shape of the only genuinely untrusted input the project has.
// A relay is a listening port strangers connect to, and every hand-written
// test in relay_test.go sends a well-formed message that merely violates a
// documented limit — none of them send bytes that aren't a message at all.
//
// The server is shared across iterations on purpose, which makes the
// liveness check cumulative: if malformed input leaks connection slots
// (Server.MaxClients is a global count released on disconnect), the good
// client eventually stops being able to join and this fails. A fresh server
// per iteration would hide that entirely.
//
// MaxClients is raised well above the shipped default of 8 for this run,
// though, and slot-leak detection proper belongs to TestNoSlotLeak in
// leak_test.go rather than here. At the default, 12 fuzz workers each
// holding a garbage connection and a probe connection contend for 8 global
// slots, so the probe starts failing on contention alone and burns its full
// retry window — measured as throughput collapsing to zero for ~18s at a
// time. That is the cap working as designed, not a defect, but it makes the
// fuzzer spend its time queueing instead of exploring inputs.
//
// The listener is in-memory (net.Pipe) rather than TCP. The relay has no
// TCP-specific code — Serve takes any net.Listener and handleConn any
// net.Conn — and a fuzzer opening real sockets at hundreds of thousands of
// iterations per second exhausts the ephemeral port range on Windows and
// fails with a dial error that says nothing about the relay. Real-TCP
// coverage of well-formed traffic is what the rest of relay_test.go is for.
//
// Longer campaign:
//
//	go test ./relay -run=XXX -fuzz=FuzzRelaySurvivesArbitraryLines -fuzztime=60s
func FuzzRelaySurvivesArbitraryLines(f *testing.F) {
	f.Add([]byte(`{"type":"hello","payload":{"protocol_version":1,"game_id":"g"}}`))
	f.Add([]byte(`{"type":"state","payload":{"position":[1,2]}}`))
	f.Add([]byte(`{"type":"hello","payload":"not an object"}`))
	f.Add([]byte(`{"type":"hello","payload":{"protocol_version":1,"game_id":"g","room":"fuzzroom"}}`))
	f.Add([]byte(`{"type":`))
	f.Add([]byte(`[]`))
	f.Add([]byte(``))
	f.Add([]byte{0x00, 0x01, 0x02})

	// The relay logs a line per join and per failed send. The fuzzer
	// discovers valid hellos quickly and then produces tens of thousands a
	// second, and that log volume — not the relay itself — is what throttles
	// the run: measured, it collapses throughput to zero for ~18s at a
	// stretch while the engine blocks on test output. Nothing here asserts
	// on log content.
	log.SetOutput(io.Discard)
	f.Cleanup(func() { log.SetOutput(os.Stderr) })

	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	srv := NewServer()
	srv.MaxClients = 4096 // see the MaxClients note above
	go srv.Serve(ln)

	f.Fuzz(func(t *testing.T, data []byte) {
		conn, err := ln.dial()
		if err != nil {
			t.Fatalf("relay listener stopped accepting: %v", err)
		}
		// net.Pipe is unbuffered and the relay's read loop stops on a bad
		// line, so an undeadlined write here would hang the fuzz run
		// instead of reporting anything.
		_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		_, _ = conn.Write(data)
		_, _ = conn.Write([]byte{'\n'})
		conn.Close()

		if !relayStillServesAGoodClient(ln) {
			t.Fatalf("relay stopped serving good clients after input %q", data)
		}
	})
}

// postJoinRoom names each iteration's own room below.
var postJoinRoom atomic.Uint64

// FuzzRelaySurvivesArbitraryPostJoinMessages reaches the code the target above
// cannot: the relay's POST-JOIN dispatch.
//
// The target above dials, writes one line and hangs up, so it only ever
// exercises the pre-auth hello path. Everything past the handshake —
// handleEvent, handleLease, handleEscrow, handleWorld and the state path — was
// therefore reached only by hand-written, well-formed tests, and those are
// exactly the handlers where a stranger's string becomes a key in the relay's
// own maps: a lease key, an escrow id, and a worldKey all do.
//
// **This is a second target rather than a change to the first**, deliberately.
// The first one's whole value is that its input is not shaped like a message;
// prefixing it with a canned hello would mean the hello parser never saw garbage
// again, and would invalidate the corpus committed under testdata/fuzz/ for it,
// which dev-scripts/ci-fuzz.sh reads as a genuine find rather than a mismatch.
// The two own different questions: "is this a message at all" and "given that it
// is, is the plane handler safe".
//
// The input is STRUCTURED — a type and a payload, not one line — so the harness
// builds the envelope and every iteration is guaranteed to land in the dispatch
// switch. With a raw line the engine would spend its budget rediscovering
// {"type":...,"payload":...} and any invalid-JSON iteration would die at the
// outer decode, which is already the other target's job. Same reasoning as
// protocol.FuzzValidateWorldIsStableAcrossTheWire's typed arguments.
//
// Longer campaign:
//
//	go test ./relay -run=XXX -fuzz=FuzzRelaySurvivesArbitraryPostJoinMessages -fuzztime=60s
func FuzzRelaySurvivesArbitraryPostJoinMessages(f *testing.F) {
	// The world seeds name authority "a" on purpose: that is the lease the
	// prologue below actually holds, and without it every world write lands in
	// the denial branch and the store/evict/stamp/broadcast path stays
	// unreachable — a campaign that looks like it covers custody and doesn't.
	f.Add("world", []byte(`{"op":"set","authority":"a","key":"e0","blob":{"hp":3},"reliable":true}`))
	f.Add("world", []byte(`{"op":"drop","authority":"a","key":"e0"}`))
	f.Add("world", []byte(`{"op":"set","authority":"a","key":"e0","blob":{"x":1}}`))
	f.Add("world", []byte(`{"op":"set","authority":"nobody","key":"e0","blob":1,"reliable":true}`))
	f.Add("lease", []byte(`{"op":"release","key":"a"}`))
	f.Add("escrow", []byte(`{"op":"open","id":"x","with":"p1"}`))
	f.Add("event", []byte(`{"to":"p1","corr_id":"c","payload":{}}`))
	f.Add("state", []byte(`{"position":[1,2]}`))
	f.Add("leave", []byte(`{}`))
	f.Add("hello", []byte(`{"protocol_version":1,"game_id":"fuzzgame"}`))
	f.Add("", []byte(``))

	// Same reason as the other target: the relay logs a line per join, and this
	// one joins every iteration, so the log volume rather than the relay is what
	// would throttle the run.
	log.SetOutput(io.Discard)
	f.Cleanup(func() { log.SetOutput(os.Stderr) })

	// Its own listener and server, NOT shared with the target above: both
	// register an f.Cleanup that closes the listener, and in a plain seed-only
	// `go test` both run sequentially, so sharing would let the first one's
	// cleanup close the listener out from under this one.
	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	srv := NewServer()
	srv.MaxClients = 4096 // see the MaxClients note on the target above
	go srv.Serve(ln)

	f.Fuzz(func(t *testing.T, typ string, payload []byte) {
		// A fresh room per iteration, named from a counter rather than from the
		// input. Not for feature stickiness — the hello is canned, so its
		// feature set is always identical — but for the LEASE: a lease is
		// exclusive, so in a shared room the parallel fuzz workers contend for
		// key "a" and whether a given input reached the accept path or the
		// denial path would depend on which workers happened to overlap. A fuzz
		// finding that does not replay is worthless. Nothing in the relay
		// branches on a room name, so replay determinism is unaffected.
		room := "wf" + strconv.FormatUint(postJoinRoom.Add(1), 36)

		conn, err := ln.dial()
		if err != nil {
			t.Fatalf("relay listener stopped accepting: %v", err)
		}
		// **Drain before writing anything.** The relay answers a hello with a
		// Welcome from inside its own read-loop callback, and net.Pipe is
		// unbuffered, so with nobody reading, that write blocks for the full
		// transport write timeout (10s) and the fuzzed line is never even read.
		// Without this the campaign does not fail — it just runs at a handful of
		// iterations per minute, which is worse, because it looks like coverage.
		drained := make(chan struct{})
		go func() { defer close(drained); _, _ = io.Copy(io.Discard, conn) }()

		write := func(b []byte) bool {
			_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
			if _, err := conn.Write(b); err != nil {
				return false
			}
			_, err := conn.Write([]byte{'\n'})
			return err == nil
		}

		// The prologue is built here and never by the fuzzer: it is the one
		// pre-state the fuzzer cannot reach on its own, and the point of the
		// target is what happens AFTER it.
		//
		// All four room-scoped planes at once, and world.v1 needs lease.v1 named
		// explicitly or the dispatch returns before handleWorld. Deliberately no
		// resume.v1: it would make the relay hold this identity after the
		// disconnect instead of releasing it, which pins the room and breaks the
		// teardown assertion below.
		hello, err := json.Marshal(protocol.Hello{
			ProtocolVersion: protocol.Version,
			GameID:          "fuzzgame",
			Room:            room,
			DisplayName:     "probe",
			Features: []string{
				protocol.FeatureEventV1, protocol.FeatureEscrowV1,
				protocol.FeatureLeaseV1, protocol.FeatureWorldV1,
			},
		})
		if err != nil {
			t.Fatalf("marshal hello: %v", err)
		}
		if !write(mustEnvelope(t, protocol.TypeHello, hello)) {
			conn.Close()
			<-drained
			return
		}
		// Claiming the authority is load-bearing, not setup noise: handleWorld
		// only stores anything for the lease's current holder.
		claim, err := json.Marshal(protocol.Lease{Op: protocol.LeaseClaim, Key: "a"})
		if err != nil {
			t.Fatalf("marshal lease: %v", err)
		}
		if !write(mustEnvelope(t, protocol.TypeLease, claim)) {
			conn.Close()
			<-drained
			return
		}

		// The fuzzed message. Raw invalid bytes are the other target's job, so
		// anything that is not valid JSON is carried as a JSON string instead —
		// that keeps the envelope well-formed and the plane handler reachable.
		body := payload
		if !json.Valid(body) {
			body, err = json.Marshal(string(payload))
			if err != nil {
				body = []byte(`null`)
			}
		}
		write(mustEnvelope(t, protocol.MessageType(typ), body))

		conn.Close()
		<-drained

		if !relayStillServesAGoodClient(ln) {
			t.Fatalf("relay stopped serving good clients after %q with payload %q", typ, payload)
		}
	})
}

// maxFuzzRooms bounds how many rooms the post-join target tolerates at once.
//
// **Per worker PROCESS, which is what makes a small number the right one.** Go
// fuzzing runs inputs in separate worker processes, so each gets its own Server
// and runs one input at a time: the legitimate steady state is this iteration's
// room, the liveness probe's own, and whatever is still tearing down
// asynchronously — two or three. 64 is ~20x that and still an order of magnitude
// below where a leak lands.
//
// Sized by measurement, not taste. At 512 this assertion was VACUOUS: with
// dropIfEmpty deliberately broken so any room holding a world entry is never
// swept, a 30s campaign still passed, because only the small fraction of inputs
// that are a valid reliable world write leak a room and that fraction is spread
// across 12 processes. A ceiling a bug cannot reach is worse than no ceiling,
// since it reads as coverage.
const maxFuzzRooms = 2

func roomCount(s *Server) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.rooms)
}

// mustEnvelope wraps an already-marshaled payload in an envelope line.
func mustEnvelope(t *testing.T, typ protocol.MessageType, payload []byte) []byte {
	t.Helper()
	b, err := json.Marshal(protocol.Envelope{Type: typ, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	return b
}

// roomEventuallyGone reports whether a room has left the server's table.
// Retried for the same reason relayStillServesAGoodClient is: the room is
// dropped when the relay notices the disconnect, so one immediate check would
// race that and report a leak that isn't one. A real leak never resolves.
func roomEventuallyGone(s *Server, gameID, name string) bool {
	key := roomKey(gameID, name)
	deadline := time.Now().Add(3 * time.Second)
	for {
		s.mu.Lock()
		_, present := s.rooms[key]
		s.mu.Unlock()
		if !present {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// relayStillServesAGoodClient dials a well-formed client and reports whether
// it gets its Welcome. Retried briefly rather than checked once: a connection
// slot is released when the relay notices a disconnect, so a single immediate
// attempt would race that and report a leak that isn't one. A genuine leak
// never resolves and still fails here.
func relayStillServesAGoodClient(ln *pipeListener) bool {
	deadline := time.Now().Add(3 * time.Second)
	for {
		if welcomed(ln) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func welcomed(ln *pipeListener) bool {
	raw, err := ln.dial()
	if err != nil {
		return false
	}
	conn := transport.FromConn(raw)
	defer conn.Close()

	got := make(chan protocol.MessageType, 4)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if json.Unmarshal(payload, &env) == nil {
			select {
			case got <- env.Type:
			default:
			}
		}
	})

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "fuzzgame",
		Room:            "fuzzroom",
		DisplayName:     "probe",
	})
	if err != nil {
		return false
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		return false
	}
	if err := conn.Send(env); err != nil {
		return false
	}

	select {
	case typ := <-got:
		return typ == protocol.TypeWelcome
	case <-time.After(time.Second):
		return false
	}
}

// pipeListener is a net.Listener backed by net.Pipe, so a test can drive
// Server.Serve without binding a real socket. See the port-exhaustion note
// on FuzzRelaySurvivesArbitraryLines for why this exists.
type pipeListener struct {
	conns  chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{
		conns:  make(chan net.Conn),
		closed: make(chan struct{}),
	}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *pipeListener) Addr() net.Addr { return pipeAddr{} }

// dial returns the caller's end of a new connection, handing the other end
// to whoever is in Accept.
func (l *pipeListener) dial() (net.Conn, error) {
	client, server := net.Pipe()
	select {
	case l.conns <- server:
		return client, nil
	case <-l.closed:
		client.Close()
		server.Close()
		return nil, net.ErrClosed
	}
}

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }
func (pipeAddr) String() string  { return "pipe" }
