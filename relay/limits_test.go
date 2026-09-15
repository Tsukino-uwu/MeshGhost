package relay

import "testing"

// The three sizing functions cmd/meshghost-relay feeds the listeners and the
// banner from. Until 2026-09-15 MaxOpenConnsFor reached production through one
// untested assignment (fourth adversarial review, E2), and the banner printed a
// configured max_clients of 0 while eight were enforced (B7).

func TestMaxOpenConnsForFloorsAtSixtyFourAndScalesEightPerSeat(t *testing.T) {
	for _, tc := range []struct{ seats, want int }{
		{0, MinMaxOpenConns}, {1, MinMaxOpenConns}, {8, 64}, {9, 72}, {32, 256},
	} {
		if got := MaxOpenConnsFor(tc.seats); got != tc.want {
			t.Errorf("MaxOpenConnsFor(%d) = %d, want %d", tc.seats, got, tc.want)
		}
	}
}

func TestMaxOpenConnsPerSourceForFloorsAtSixteenAndScalesTwoPerSeat(t *testing.T) {
	for _, tc := range []struct{ seats, want int }{
		{0, MinMaxOpenConnsPerSource}, {8, 16}, {9, 18}, {32, 64},
	} {
		if got := MaxOpenConnsPerSourceFor(tc.seats); got != tc.want {
			t.Errorf("MaxOpenConnsPerSourceFor(%d) = %d, want %d", tc.seats, got, tc.want)
		}
		// The per-source share never reaches the listener-wide cap, or one
		// address could still take every slot.
		if MaxOpenConnsPerSourceFor(tc.seats) >= MaxOpenConnsFor(tc.seats) {
			t.Errorf("at %d seats the per-source cap %d is not below the listener cap %d",
				tc.seats, MaxOpenConnsPerSourceFor(tc.seats), MaxOpenConnsFor(tc.seats))
		}
	}
}

func TestEffectiveMaxClientsIsWhatTryReserveSlotEnforces(t *testing.T) {
	for _, tc := range []struct{ configured, want int }{
		{0, DefaultMaxClients}, {-3, DefaultMaxClients}, {1, 1}, {12, 12},
	} {
		if got := EffectiveMaxClients(tc.configured); got != tc.want {
			t.Errorf("EffectiveMaxClients(%d) = %d, want %d", tc.configured, got, tc.want)
		}
	}
	// And the reservation agrees: a server configured 0 admits exactly the default.
	s := NewServer()
	s.MaxClients = 0
	for i := 0; i < DefaultMaxClients; i++ {
		if !s.tryReserveSlot() {
			t.Fatalf("slot %d refused under a configured 0, which means the default", i+1)
		}
	}
	if s.tryReserveSlot() {
		t.Fatalf("slot %d admitted; EffectiveMaxClients(0) is %d", DefaultMaxClients+1, DefaultMaxClients)
	}
}
