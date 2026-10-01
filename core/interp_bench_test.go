package core

// What the render knobs cost. Bandwidth is not benchmarked: both curves and the prediction are receive-side arithmetic
// over samples already in the buffer, and none of them changes a byte on the wire.

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func benchBuffer() *remoteBuffer {
	b := &remoteBuffer{}
	for i := 0; i < 8; i++ {
		b.add(protocol.State{
			AreaID:    "a",
			Anim:      "walk",
			Position:  []float64{float64(i) * 10, float64(i * i)},
			Timestamp: 1000 + int64(i)*50,
		})
	}
	return b
}

func BenchmarkRenderLinear(b *testing.B) {
	buf := benchBuffer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		buf.atAhead(1175, 0, CurveLinear, PredictLinear, nil)
	}
}

func BenchmarkRenderCatmullRom(b *testing.B) {
	buf := benchBuffer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		buf.atAhead(1175, 0, CurveCatmullRom, PredictLinear, nil)
	}
}

func BenchmarkRenderExtrapolated(b *testing.B) {
	buf := benchBuffer()
	var m extrapolationMeter
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		buf.atAhead(1400, 150, CurveLinear, PredictLinear, &m)
	}
}

// BenchmarkSameSentState: the send side's whole-state comparison, which runs once per adapter frame.
func BenchmarkSameSentState(b *testing.B) {
	prev := &protocol.State{
		AreaID: "a", Anim: "idle", Position: []float64{1, 2},
		Extras: map[string]any{"vfx_seq": 3, "trail": 0, "room_x": 4, "room_y": 5},
	}
	cur := *prev
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		sameSentState(prev, &cur)
	}
}
