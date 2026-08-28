package relay

// What one inbound state COSTS the relay, and where that cost goes.
//
// Written 2026-08-28 as the baseline for the efficiency pass in
// agent_docs/plans.md's "Efficiency is a standing goal". Until now every
// benchmark in this repo lived in core (core/interp_bench_test.go) and measured
// RECEIVE-side arithmetic; nothing had ever measured the relay, which is the
// process that carries the whole room's fan-out and the one a host pays for.
//
// Read allocs/op at least as closely as ns/op. The fan-out is quadratic in room
// size (agent_docs/plans.md: n x (n-1) state messages), so per-recipient
// allocation is what decides whether a big room is possible at all -- and it is
// the number the stage-2 cleanup is aimed squarely at.
//
// These call Room.forwardState, the real path handleConn takes, rather than a
// replica of it kept in step by hand -- see that function's own comment.

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// discardTransport is a recipient that accepts everything and keeps nothing, so
// what is measured is the relay's own work rather than a socket or a test's
// bookkeeping. recordingTransport in world_test.go deliberately copies and
// retains every payload, which would put ITS allocations in these numbers.
//
// Deliberately a POINTER to a non-empty struct, which is not a detail: an
// interface holding a zero-sized value lets the compiler keep the bound method
// value in Room.forward on the stack, so a zero-sized discard type reports the
// per-recipient closure allocation as free when against a real *NDJSONConn it
// is not. Measured both ways 2026-08-28 -- the empty version hid it completely.
type discardTransport struct{ sent int }

func (d *discardTransport) Send([]byte) error           { d.sent++; return nil }
func (d *discardTransport) SendUnreliable([]byte) error { d.sent++; return nil }
func (d *discardTransport) OnReceive(func([]byte))      {}
func (d *discardTransport) OnDisconnect(func(error))    {}
func (d *discardTransport) OnError(func(error))         {}
func (d *discardTransport) Close() error                { return nil }

// benchRoom builds a room of n members that all share one area, which is the
// WORST case for fan-out and therefore the honest one to measure: every
// recipient is a real recipient, and the cross-area shadow counters suppress
// nothing. Member 0 is the sender.
func benchRoom(n int) *Room {
	r := newRoom("bench", "1", "room", nil)
	for i := 0; i < n; i++ {
		r.tryAdd(&Client{PlayerID: fmt.Sprintf("p%d", i), Conn: &discardTransport{}})
	}
	return r
}

// The two real state shapes on the wire today, with the field names the
// adapters actually send -- a benchmark against an invented shape measures an
// invented cost. Emerald carries 14 extras keys and 2D tile coordinates
// (meshghost_emerald.lua's encodeLocalState); TEVI carries 3 in the common case
// and a 3D position (MeshGhostTevi/BridgeClient.cs).
func emeraldState() protocol.State {
	return protocol.State{
		AreaID:      "map:1:2",
		Anim:        "walking",
		Position:    []float64{12, 34},
		Orientation: json.RawMessage(`"down"`),
		Extras: map[string]any{
			"gender": "m", "gfx": 1, "sanim": 0, "sidx": 2, "act": 0,
			"sox": 0, "soy": 0, "spaused": 0, "pspeed": 1, "noanim": 0,
			"invis": 0, "boat": 0, "fly": 0, "flyk": 0,
		},
	}
}

func teviState() protocol.State {
	return protocol.State{
		AreaID:      "Stage_01",
		Anim:        "Run",
		Position:    []float64{101.5, -22.25, 3},
		Orientation: json.RawMessage(`{"yaw":90}`),
		Extras:      map[string]any{"room_x": 3, "room_y": 4, "anim_t": 0.375},
	}
}

func mustPayload(tb testing.TB, st protocol.State) []byte {
	tb.Helper()
	b, err := json.Marshal(st)
	if err != nil {
		tb.Fatalf("marshal state: %v", err)
	}
	return b
}

// BenchmarkStateFanout is the headline number: one inbound state, decoded,
// validated, stamped, recorded and fanned out to every other member.
//
// The room sizes bracket what the project actually cares about: 2 is a session
// with a friend, 8 is DefaultMaxClients, 32 is the size agent_docs/plans.md
// prices at 39.7 GB/hour of host uplink, and 128 is there to show the shape of
// the curve rather than to describe a room anyone runs today.
func BenchmarkStateFanout(b *testing.B) {
	shapes := []struct {
		name string
		st   protocol.State
	}{
		{"emerald", emeraldState()},
		{"tevi", teviState()},
	}
	for _, shape := range shapes {
		payload := mustPayload(b, shape.st)
		for _, n := range []int{2, 8, 32, 128} {
			b.Run(fmt.Sprintf("%s/%d", shape.name, n), func(b *testing.B) {
				r := benchRoom(n)
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					r.forwardState("p0", payload)
				}
			})
		}
	}
}

// BenchmarkValidateState isolates protocol.ValidateState, which marshals
// st.Extras purely to measure its serialized length (protocol/limits.go).
// "noExtras" is not a real adapter -- every shipped one sends extras -- it is
// the short-circuit path, present so the difference between the two names the
// cost of that marshal exactly.
func BenchmarkValidateState(b *testing.B) {
	bare := emeraldState()
	bare.Extras = nil
	cases := []struct {
		name string
		st   protocol.State
	}{
		{"emerald14keys", emeraldState()},
		{"tevi3keys", teviState()},
		{"noExtras", bare},
	}
	for _, c := range cases {
		b.Run(c.name, func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				protocol.ValidateState(c.st)
			}
		})
	}
}

// BenchmarkEnvelopeMarshal measures the two marshals that stage 2 collapses
// into one: envelope() turns the State into payload bytes, and Room.forward
// then marshals the Envelope around those bytes, re-scanning and re-copying
// every one of them. Both are measured here so the saving is attributable
// rather than inferred from the fan-out number moving.
func BenchmarkEnvelopeMarshal(b *testing.B) {
	st := emeraldState()
	b.Run("stateToPayload", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, err := envelope(protocol.TypeState, st); err != nil {
				b.Fatal(err)
			}
		}
	})
	env, err := envelope(protocol.TypeState, st)
	if err != nil {
		b.Fatal(err)
	}
	b.Run("payloadToLine", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, err := json.Marshal(env); err != nil {
				b.Fatal(err)
			}
		}
	})
}

// Guards the benchmarks themselves: a fan-out benchmark that silently measured
// a room where every state was dropped as invalid, or reached nobody, would
// report a wonderful number and mean nothing. This is the same reasoning as the
// load rig's client0_remotes self-check (dev-scripts/README.md).
func TestBenchmarkFixturesAreRealisticAndForwarded(t *testing.T) {
	for _, st := range []protocol.State{emeraldState(), teviState()} {
		if !protocol.ValidateState(st) {
			t.Fatalf("benchmark fixture is rejected by ValidateState: %+v", st)
		}
	}
	r := benchRoom(4)
	got, ok := r.forwardState("p0", mustPayload(t, emeraldState()))
	if !ok {
		t.Fatal("benchmark fixture was not forwarded")
	}
	if got.PlayerID != "p0" {
		t.Fatalf("sender id not stamped: got %q", got.PlayerID)
	}
	if n := len(r.stateRecipients("p0", got.AreaID, 100, time.Now())); n != 3 {
		t.Fatalf("expected the other 3 members as recipients, got %d", n)
	}
}

var _ transport.Transport = (*discardTransport)(nil)
