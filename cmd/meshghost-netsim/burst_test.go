package main

import (
	"math/rand"
	"sync"
	"testing"
	"time"
)

func burstFaults(loss float64, mean time.Duration) *faults {
	return &faults{
		loss:      loss,
		burstMean: mean,
		mu:        sync.Mutex{},
		rng:       rand.New(rand.NewSource(1)),
	}
}

// runLengths feeds samples spaced by spacing through the model and returns the length of each run of lost ones.
func runLengths(f *faults, samples int, spacing time.Duration) []int {
	now := time.Unix(0, 0)
	var runs []int
	cur := 0
	for i := 0; i < samples; i++ {
		if f.losing(now) {
			cur++
		} else if cur > 0 {
			runs = append(runs, cur)
			cur = 0
		}
		now = now.Add(spacing)
	}
	if cur > 0 {
		runs = append(runs, cur)
	}
	return runs
}

// TestMemorylessLossHardlyEverLosesARun pins the default's shape, the baseline for the tests below: at 5% and 15Hz,
// memoryless loss almost never loses three samples in a row.
func TestMemorylessLossHardlyEverLosesARun(t *testing.T) {
	f := &faults{loss: 0.05, mu: sync.Mutex{}, rng: rand.New(rand.NewSource(1))}
	// One minute at 15Hz.
	runs := runLengths(f, 900, 66*time.Millisecond)

	long := 0
	for _, n := range runs {
		if n >= 3 {
			long++
		}
	}
	if long > 2 {
		t.Fatalf("memoryless loss produced %d runs of 3+ in a minute at 5%%, which is far more "+
			"than the ~0.1 the arithmetic predicts -- either the model changed or this test's "+
			"seed is unrepresentative", long)
	}
}

// TestCorrelatedLossProducesRunsLongEnoughToMatter: at the same -loss, -loss-burst delivers losses in runs long
// enough to matter to an interpolation buffer.
func TestCorrelatedLossProducesRunsLongEnoughToMatter(t *testing.T) {
	f := burstFaults(0.05, 250*time.Millisecond)
	// Ten minutes at 15Hz, about 30s bad in total at 5%, so several bad periods are expected rather than lucky.
	runs := runLengths(f, 9000, 66*time.Millisecond)
	if len(runs) == 0 {
		t.Fatal("correlated loss lost nothing at all in ten minutes at 5%")
	}

	long := 0
	for _, n := range runs {
		if n >= 3 { // 3 samples at 66ms is ~200ms, the low end of bad wifi's 150-500ms runs
			long++
		}
	}
	if long == 0 {
		t.Fatalf("correlated loss produced %d runs, none of them 3 samples or longer -- "+
			"the flag exists to reach the 150-500ms gap regime, and this is still the "+
			"memoryless shape", len(runs))
	}
}

// TestCorrelatedLossKeepsTheSameLongRunShare: the flag changes how losses arrive, not how many, so a result under it
// differs from one without it only in the arrangement.
func TestCorrelatedLossKeepsTheSameLongRunShare(t *testing.T) {
	const want = 0.05
	f := burstFaults(want, 250*time.Millisecond)
	now := time.Unix(0, 0)
	lost, total := 0, 60000 // over an hour at 15Hz
	for i := 0; i < total; i++ {
		if f.losing(now) {
			lost++
		}
		now = now.Add(66 * time.Millisecond)
	}
	got := float64(lost) / float64(total)
	if got < want*0.6 || got > want*1.6 {
		t.Fatalf("correlated loss dropped %.3f of datagrams, want about %.3f -- -loss has to keep "+
			"meaning the same thing or a comparison against the default profile is measuring two "+
			"changes at once", got, want)
	}
}

// TestTheDefaultModelIsUntouchedWhenTheFlagIsUnset: every interp verdict on record was made against the default model.
func TestTheDefaultModelIsUntouchedWhenTheFlagIsUnset(t *testing.T) {
	f := &faults{loss: 0, mu: sync.Mutex{}, rng: rand.New(rand.NewSource(1))}
	if f.losing(time.Unix(0, 0)) {
		t.Fatal("a fault model with no -loss dropped a datagram")
	}
}
