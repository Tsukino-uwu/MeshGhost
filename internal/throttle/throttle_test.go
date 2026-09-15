package throttle

import (
	"sync"
	"testing"
)

// TestOnlyOneLinePerIntervalButEveryOneIsCounted: a burst prints once and the
// printed count covers the burst.
func TestOnlyOneLinePerIntervalButEveryOneIsCounted(t *testing.T) {
	var l Line
	printed := 0
	var lastN int64
	for i := 0; i < 1000; i++ {
		n, ok := l.Allow()
		if ok {
			printed++
			lastN = n
		}
	}
	if printed != 1 {
		t.Fatalf("printed %d lines in one burst, want 1", printed)
	}
	if lastN != 1 {
		t.Fatalf("the printed line carried count %d, want 1 (it was the first)", lastN)
	}
	if l.Count() != 1000 {
		t.Fatalf("Count = %d, want 1000", l.Count())
	}
}

// TestConcurrentCallersPrintOnce: the CAS is what makes many goroutines agree
// on the one line, which the relay's per-connection goroutines need.
func TestConcurrentCallersPrintOnce(t *testing.T) {
	var l Line
	var wg sync.WaitGroup
	var mu sync.Mutex
	printed := 0
	for g := 0; g < 32; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				if _, ok := l.Allow(); ok {
					mu.Lock()
					printed++
					mu.Unlock()
				}
			}
		}()
	}
	wg.Wait()
	if printed != 1 {
		t.Fatalf("printed %d lines across 32 goroutines in one burst, want 1", printed)
	}
	if l.Count() != 32*200 {
		t.Fatalf("Count = %d, want %d", l.Count(), 32*200)
	}
}
