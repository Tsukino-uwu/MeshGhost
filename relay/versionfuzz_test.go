package relay

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"log"
	"os"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// FuzzHelloProtocolVersion drives every version a hello can carry, which the other relay targets hard-code. The relay
// survives any int, where a subtraction in place of >= would wrap, and its verdict matches protocol.AcceptsPeerVersion
// exactly, so the two ends cannot drift into some players being unable to join.
func FuzzHelloProtocolVersion(f *testing.F) {
	// The edges by name, so a failure points at a case rather than a number.
	for _, v := range []int64{
		0,                                      // a peer from before the field existed
		1,                                      // every build before the version floor
		int64(protocol.MinProtocolVersion) - 1, // one below the floor
		int64(protocol.MinProtocolVersion),     // exactly the floor
		int64(protocol.Version),                // us
		int64(protocol.Version) + 1,            // a client newer than this relay
		1 << 31,                                // past int32, where a careless cast would wrap
		-1,                                     // negative
		-(1 << 31),
	} {
		b := make([]byte, 8)
		binary.LittleEndian.PutUint64(b, uint64(v))
		f.Add(b)
	}

	// One relay on an in-memory listener, as in fuzz_test.go: a listener and a dial per iteration exhaust the ephemeral
	// ports, and the bind error reads as a finding against whatever input was running. Every accepted version is a
	// join, so the log is silenced or its volume throttles the run.
	log.SetOutput(io.Discard)
	f.Cleanup(func() { log.SetOutput(os.Stderr) })

	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	srv := NewServer()
	srv.SendHz = protocol.MaxSendHz
	srv.MaxClients = 4096 // as in FuzzRelaySurvivesArbitraryLines
	go srv.Serve(ln)

	f.Fuzz(func(t *testing.T, seed []byte) {
		if len(seed) < 8 {
			return
		}
		version := int(int64(binary.LittleEndian.Uint64(seed[:8])))

		raw, err := ln.dial()
		if err != nil {
			t.Fatalf("relay listener stopped accepting: %v", err)
		}
		conn := transport.FromConn(raw)
		defer conn.Close()

		envs := make(chan protocol.Envelope, 4)
		conn.OnReceive(func(payload []byte) {
			var env protocol.Envelope
			if json.Unmarshal(payload, &env) == nil {
				select {
				case envs <- env:
				default:
				}
			}
		})

		hello, err := json.Marshal(protocol.Hello{
			ProtocolVersion: version,
			GameID:          "fuzzgame",
			Room:            "fuzzroom",
			DisplayName:     "probe",
		})
		if err != nil {
			return
		}
		env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
		if err != nil {
			return
		}
		if err := conn.Send(env); err != nil {
			return
		}

		want := protocol.AcceptsPeerVersion(version)
		select {
		case got := <-envs:
			switch got.Type {
			case protocol.TypeWelcome:
				if !want {
					t.Fatalf("version %d was WELCOMED, but protocol.AcceptsPeerVersion says no "+
						"(floor is %d) -- the relay and the shared predicate disagree, which is the "+
						"split-brain the floor exists to remove", version, protocol.MinProtocolVersion)
				}
			case protocol.TypeReject:
				if want {
					t.Fatalf("version %d was REFUSED, but protocol.AcceptsPeerVersion accepts it "+
						"(floor is %d) -- a peer at or above the floor must join, including one "+
						"NEWER than this relay", version, protocol.MinProtocolVersion)
				}
				var rej protocol.Reject
				if err := json.Unmarshal(got.Payload, &rej); err != nil {
					t.Fatalf("version %d: reject did not decode: %v", version, err)
				}
				if rej.Code != protocol.CodeProtocolVersionMismatch {
					t.Fatalf("version %d refused with code %q, want %q -- an adapter branches on the "+
						"code, so a version refusal that names something else sends the player to "+
						"fix the wrong setting", version, rej.Code, protocol.CodeProtocolVersionMismatch)
				}
				if rej.Retryable {
					t.Fatalf("version %d refused as RETRYABLE -- no amount of reconnecting changes "+
						"either build's version, and saying otherwise makes a client hammer a relay "+
						"it can never talk to", version)
				}
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("version %d got neither a welcome nor a reject -- the relay answered a hello "+
				"with silence, which no client has a timeout short enough to survive well", version)
		}
	})
}
