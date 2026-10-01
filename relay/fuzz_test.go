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

// FuzzRelaySurvivesArbitraryLines throws arbitrary bytes at a running relay, then checks it still serves a good
// client. The server is shared across iterations, so a leaked connection slot accumulates until the check fails. The
// listener is net.Pipe: real sockets at fuzz rates exhaust Windows' ephemeral ports and fail with a dial error.
func FuzzRelaySurvivesArbitraryLines(f *testing.F) {
	f.Add([]byte(`{"type":"hello","payload":{"protocol_version":1,"game_id":"g"}}`))
	f.Add([]byte(`{"type":"state","payload":{"position":[1,2]}}`))
	f.Add([]byte(`{"type":"hello","payload":"not an object"}`))
	f.Add([]byte(`{"type":"hello","payload":{"protocol_version":1,"game_id":"g","room":"fuzzroom"}}`))
	f.Add([]byte(`{"type":`))
	f.Add([]byte(`[]`))
	f.Add([]byte(``))
	f.Add([]byte{0x00, 0x01, 0x02})

	// Log volume, not the relay, would throttle the run; nothing here asserts on log content.
	log.SetOutput(io.Discard)
	f.Cleanup(func() { log.SetOutput(os.Stderr) })

	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	srv := NewServer()
	srv.MaxClients = 4096 // at the default, workers contend for slots and the probe queues instead of exploring
	go srv.Serve(ln)

	f.Fuzz(func(t *testing.T, data []byte) {
		conn, err := ln.dial()
		if err != nil {
			t.Fatalf("relay listener stopped accepting: %v", err)
		}
		// net.Pipe is unbuffered and the relay stops reading on a bad line, so an undeadlined write would hang the run.
		_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		_, _ = conn.Write(data)
		_, _ = conn.Write([]byte{'\n'})
		conn.Close()

		if !relayStillServesAGoodClient(ln) {
			t.Fatalf("relay stopped serving good clients after input %q", data)
		}
	})
}

var postJoinRoom atomic.Uint64

// FuzzRelaySurvivesArbitraryPostJoinMessages fuzzes the dispatch after a real join, where a stranger's string becomes
// a lease key, escrow id or world key. A separate target, so the first keeps feeding the hello parser non-messages
// and its committed corpus stays valid; the input is a type and a payload, so every iteration reaches the dispatch.
func FuzzRelaySurvivesArbitraryPostJoinMessages(f *testing.F) {
	// Authority "a" is the lease the prologue holds; any other reaches only the denial branch.
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

	// This target joins every iteration, so log volume would throttle the run.
	log.SetOutput(io.Discard)
	f.Cleanup(func() { log.SetOutput(os.Stderr) })

	// Not shared: a seed-only go test runs both targets in turn, and the first's cleanup closes its listener.
	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	srv := NewServer()
	srv.MaxClients = 4096 // as in the target above
	go srv.Serve(ln)

	f.Fuzz(func(t *testing.T, typ string, payload []byte) {
		// A room per iteration, so parallel workers never contend for lease "a" and a finding replays.
		room := "wf" + strconv.FormatUint(postJoinRoom.Add(1), 36)

		conn, err := ln.dial()
		if err != nil {
			t.Fatalf("relay listener stopped accepting: %v", err)
		}
		// Drain first: the Welcome is written from the relay's read loop and net.Pipe is unbuffered, so unread it
		// blocks for the write timeout and the campaign crawls without failing.
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

		// world.v1 needs lease.v1 named or dispatch returns before handleWorld. No resume.v1: the relay would hold
		// this identity after the disconnect, which pins the room.
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
		// handleWorld stores only for the lease's current holder.
		claim, err := json.Marshal(protocol.Lease{Op: protocol.LeaseClaim, Key: "a"})
		if err != nil {
			t.Fatalf("marshal lease: %v", err)
		}
		if !write(mustEnvelope(t, protocol.TypeLease, claim)) {
			conn.Close()
			<-drained
			return
		}

		// Invalid JSON goes as a JSON string, so the envelope stays well-formed and the handler reachable.
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

func mustEnvelope(t *testing.T, typ protocol.MessageType, payload []byte) []byte {
	t.Helper()
	b, err := json.Marshal(protocol.Envelope{Type: typ, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	return b
}

// relayStillServesAGoodClient reports whether a well-formed client gets its Welcome, retried briefly: a slot is
// released when the relay notices a disconnect, so one immediate attempt would race it.
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

// pipeListener is a net.Listener backed by net.Pipe, so a test can drive Server.Serve without binding a socket.
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
