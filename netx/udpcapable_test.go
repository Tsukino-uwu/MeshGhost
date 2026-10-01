package netx

import "testing"

// A probe that false-negatives would silently take quic away from every player.
func TestUDPUsableIsTrueOnAMachineThatHasUDP(t *testing.T) {
	if !UDPUsable() {
		t.Fatalf("UDPUsable said no on a machine that plainly has udp: %s", UDPUnusableReason())
	}
	if r := UDPUnusableReason(); r != "" {
		t.Fatalf("UDPUnusableReason = %q, want empty when udp works", r)
	}
}

// Cached, so calling it on every connect attempt costs one syscall per process.
func TestUDPUsableIsStable(t *testing.T) {
	first := UDPUsable()
	for range 100 {
		if UDPUsable() != first {
			t.Fatal("UDPUsable changed its answer within one process")
		}
	}
}
