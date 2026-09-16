package core

// The transit and dry percentiles exist to size a delay (prediction-planning.md,
// A2.0), so a percentile that reads low is the dangerous direction: a delay
// sized on it is too short. These pin the rank arithmetic, the bucket edge
// rounding UP, the overflow bucket, and that Core.Stats reads the real meters.

import (
	"strings"
	"testing"
)

func TestHistogramPercentileIsTheBucketEdgeAboveTheRank(t *testing.T) {
	var h msHistogram
	// 100 readings: 1..100ms. p50 is the 50th (50ms, bucket [50,60)), p95 the
	// 95th (bucket [90,100)), p99 the 99th (bucket [90,100)), p100 the 100th
	// (bucket [100,110), whose edge is capped at the 100ms max).
	for ms := int64(1); ms <= 100; ms++ {
		h.add(ms)
	}
	for _, c := range []struct {
		p    float64
		want int64
	}{{50, 60}, {95, 100}, {99, 100}, {100, 100}, {1, 10}} {
		if got := h.percentile(c.p, 100); got != c.want {
			t.Errorf("p%v = %dms, want %dms", c.p, got, c.want)
		}
	}
}

func TestHistogramPercentileIsNotTheMean(t *testing.T) {
	// 94 fast samples and 6 slow ones: the mean sits near 40ms, and a delay
	// sized on it misses every slow one. p95 must land in the slow group.
	var h msHistogram
	for i := 0; i < 94; i++ {
		h.add(20)
	}
	for i := 0; i < 6; i++ {
		h.add(400)
	}
	if got := h.percentile(95, 400); got != 400 {
		t.Errorf("p95 = %dms, want 400 (the slow group's bucket, capped at its max)", got)
	}
	if got := h.percentile(50, 400); got != 30 {
		t.Errorf("p50 = %dms, want 30", got)
	}
}

func TestHistogramOverflowAndNegativeReadings(t *testing.T) {
	var h msHistogram
	h.add(-50) // a clock offset can make transit negative; it counts as 0
	h.add(9000)
	if got := h.percentile(50, 9000); got != 10 {
		t.Errorf("p50 = %dms, want 10 (the negative reading's bucket)", got)
	}
	if got := h.percentile(99, 9000); got != 9000 {
		t.Errorf("p99 = %dms, want the max (9000) for the overflow bucket", got)
	}
	var fast msHistogram
	for i := 0; i < 10; i++ {
		fast.add(2)
	}
	if got := fast.percentile(50, 2); got != 2 {
		t.Errorf("p50 of ten 2ms readings = %dms, want 2 (never past the max)", got)
	}
	var empty msHistogram
	if got := empty.percentile(99, 0); got != 0 {
		t.Errorf("empty p99 = %d, want 0", got)
	}
}

func TestStatsLinePrintsTransitAndDryPercentiles(t *testing.T) {
	c := New()
	c.mu.Lock()
	for i := 0; i < 99; i++ {
		c.transit.record(100)
		c.dry.record(30, true)
	}
	c.transit.record(700)
	c.dry.record(900, true)
	c.mu.Unlock()

	s := c.Stats()
	if s.TransitP50Ms != 110 || s.TransitP99Ms != 110 || s.TransitMaxMs != 700 {
		t.Errorf("transit p50/p99/max = %d/%d/%d, want 110/110/700", s.TransitP50Ms, s.TransitP99Ms, s.TransitMaxMs)
	}
	if s.DryP95Ms != 40 || s.DryMaxMs != 900 {
		t.Errorf("dry p95/max = %d/%d, want 40/900", s.DryP95Ms, s.DryMaxMs)
	}
	line := s.String()
	for _, want := range []string{"transit: 100 samples, avg 106ms, p50 110ms, p95 110ms, p99 110ms, max 700ms", "p95 40ms, p99 40ms, max 900ms past the newest sample"} {
		if !strings.Contains(line, want) {
			t.Errorf("stats line lacks %q:\n%s", want, line)
		}
	}
}
