package relay

// What one inbound state costs the relay, through Room.forwardState, the path handleConn takes. Read allocs/op at
// least as closely as ns/op: the fan-out is quadratic in room size, so per-recipient allocation decides big rooms.

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// discardTransport keeps nothing, so what is measured is the relay's work, not a socket's or recordingTransport's. A
// pointer to a non-empty struct, so the compiler cannot treat it as zero-sized and skip costs a real conn pays.
type discardTransport struct{ sent int }

func (d *discardTransport) Send([]byte) error           { d.sent++; return nil }
func (d *discardTransport) SendUnreliable([]byte) error { d.sent++; return nil }
func (d *discardTransport) OnReceive(func([]byte))      {}
func (d *discardTransport) OnDisconnect(func(error))    {}
func (d *discardTransport) OnError(func(error))         {}
func (d *discardTransport) Close() error                { return nil }

// benchRoom's members never opted in to area filtering, so every one is a recipient: the worst case for fan-out.
// Member 0 is the sender.
func benchRoom(n int) *Room {
	r := newRoom("bench", "1", "room", nil)
	for i := 0; i < n; i++ {
		r.tryAdd(&Client{PlayerID: fmt.Sprintf("p%d", i), Conn: &discardTransport{}})
	}
	return r
}

// Emerald's and TEVI's state shapes, with the field names they send: an invented shape measures an invented cost.
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

// BenchmarkStateFanout is the headline number: one inbound state, decoded, validated, stamped, recorded and fanned
// out to every other member.
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

// BenchmarkValidateState isolates protocol.ValidateState. "noExtras" is no real adapter's shape: it is the
// short-circuit path, so the difference names the cost of bounding the extras.
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

// BenchmarkEnvelopeMarshal measures envelope() turning a State into payload bytes, then the two ways of turning a
// payload into a line.
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
	// viaMarshal is the control plane's way; viaAppend is the state path's.
	b.Run("payloadToLine/viaMarshal", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, err := json.Marshal(env); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("payloadToLine/viaAppend", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			_ = protocol.AppendEnvelope(nil, protocol.TypeState, env.Payload)
		}
	})
}

// A fan-out benchmark over states that were dropped as invalid, or reached nobody, would report a fine number and
// mean nothing.
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
	if n := len(r.stateRecipients("p0", got.AreaID, got.AreaID, 100, time.Now())); n != 3 {
		t.Fatalf("expected the other 3 members as recipients, got %d", n)
	}
}

var _ transport.Transport = (*discardTransport)(nil)
