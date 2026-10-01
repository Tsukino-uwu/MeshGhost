//go:build meshghost_devudp

package netx

import "testing"

func TestParseKindsAcceptsUDPInTheDevBuild(t *testing.T) {
	for _, in := range []string{"udp", "udp,quic", "quic,udp"} {
		got, err := ParseKinds(in)
		if err != nil {
			t.Errorf("ParseKinds(%q): %v", in, err)
			continue
		}
		if len(got) == 0 || got[0] != TCP {
			t.Errorf("ParseKinds(%q) = %v, want tcp first", in, got)
		}
	}
	if got, err := ParseKinds("tcp,udp,tcp"); err != nil || len(got) != 2 {
		t.Fatalf("ParseKinds(\"tcp,udp,tcp\") = %v, %v; want exactly [tcp udp]", got, err)
	}
}

// TestAutoNeverPrefersUDPOverQUIC: udp and quic behave the same under loss but udp cannot be encrypted, so auto
// ranking it first would be a silent downgrade.
func TestAutoNeverPrefersUDPOverQUIC(t *testing.T) {
	quicAt, udpAt := -1, -1
	for i, k := range AutoPreference {
		switch k {
		case QUIC:
			quicAt = i
		case UDP:
			udpAt = i
		}
	}
	if quicAt < 0 || udpAt < 0 {
		t.Fatalf("AutoPreference = %v, want it to rank both quic and udp", AutoPreference)
	}
	if udpAt < quicAt {
		t.Errorf("AutoPreference ranks udp (%d) above quic (%d) — auto would silently choose an "+
			"unencryptable transport over an encrypted one", udpAt, quicAt)
	}
	if AutoPreference[len(AutoPreference)-1] != UDP {
		t.Errorf("AutoPreference = %v, want udp last", AutoPreference)
	}
}
