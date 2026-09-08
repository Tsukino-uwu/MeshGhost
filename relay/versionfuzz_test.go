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

// FuzzHelloProtocolVersion drives every version a hello can carry.
//
// WHY THIS EXISTS AND THE OTHER FUZZERS DO NOT COVER IT: both existing relay
// targets hard-code `ProtocolVersion: protocol.Version`, so the field was the
// one hello value nothing ever varied -- and on 2026-09-08 it stopped being a
// constant comparison and became a DECISION with two outcomes, made before the
// room is touched. A gate nothing fuzzes is a gate whose edges nobody has seen
// (the user asked for exactly this on the day the floor landed).
//
// Two properties, and the second is the interesting one:
//
//   - The relay SURVIVES any int the field can hold -- negative, zero, 1, the
//     floor, far above it, and both int64 extremes, which is where an arithmetic
//     comparison would go wrong if anyone ever replaced `>=` with a subtraction.
//   - The verdict MATCHES protocol.AcceptsPeerVersion exactly. That is what stops
//     the two ends drifting: the relay refusing something the shared predicate
//     accepts is precisely the split-brain a floor is supposed to remove, and it
//     would otherwise show up as "some players cannot join" long after the change
//     that caused it.
func FuzzHelloProtocolVersion(f *testing.F) {
	// The edges by name, so a failure points at a case rather than a number.
	for _, v := range []int64{
		0,                                      // a peer from before the field existed
		1,                                      // every build before the 2026-09-08 cutover
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

	// One relay for the whole campaign, on an in-memory listener, for the same
	// reason the two targets in fuzz_test.go do it: a real 127.0.0.1:0 listener
	// plus a real dial PER ITERATION burns two ephemeral ports each, and at a
	// few thousand executions a second the kernel runs out of them long before
	// the campaign ends. CI hit exactly that on 2026-09-08 -- "listen tcp
	// 127.0.0.1:0: bind: address already in use" after 22 s and ~55k execs --
	// and reported it as a finding against whatever input happened to be
	// running, which is a harness defect wearing a crasher's clothes. Nothing
	// under test here is the TCP layer; the decision is made on the decoded
	// hello.
	//
	// The join log is silenced like the siblings do: every accepted version is
	// a join, and the log volume rather than the relay is what throttles the run.
	log.SetOutput(io.Discard)
	f.Cleanup(func() { log.SetOutput(os.Stderr) })

	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	srv := NewServer()
	srv.SendHz = protocol.MaxSendHz
	srv.MaxClients = 4096 // see the MaxClients note on FuzzRelaySurvivesArbitraryLines
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
