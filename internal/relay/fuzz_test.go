package relay

import (
	"encoding/json"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"testing"
	"time"

	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// FuzzRelaySurvivesArbitraryLines is the end-to-end counterpart to the
// parser fuzzing in internal/protocol and internal/transport: it throws
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
//	go test ./internal/relay -run=XXX -fuzz=FuzzRelaySurvivesArbitraryLines -fuzztime=60s
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
