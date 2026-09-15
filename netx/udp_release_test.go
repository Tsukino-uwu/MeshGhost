//go:build !meshghost_devudp

package netx

import (
	"errors"
	"testing"
	"time"
)

// What a RELEASE guarantees about plain udp (ADR 0065): the name is refused
// wherever a transport can be named, nothing dials or listens on it, and
// auto never ranks it. Each of these is the untagged half of a rule whose
// tagged half lives in udp_dev_test.go.

func TestUDPIsRefusedByParseKind(t *testing.T) {
	for _, in := range []string{"udp", "UDP", " udp "} {
		if _, err := ParseKind(in); !errors.Is(err, ErrUDPNotSupported) {
			t.Fatalf("ParseKind(%q) = %v, want ErrUDPNotSupported", in, err)
		}
	}
	for _, in := range []string{"udp", "tcp,udp", "udp,quic", "tcp,quic,udp"} {
		if _, err := ParseKinds(in); !errors.Is(err, ErrUDPNotSupported) {
			t.Fatalf("ParseKinds(%q) = %v, want ErrUDPNotSupported -- a config that still says udp must not start", in, err)
		}
	}
	// And the error says what to use instead.
	if _, err := ParseKind("udp"); err == nil || err.Error() != "netx: udp is not a supported transport; use quic or tcp" {
		t.Fatalf("the refusal does not name the alternatives: %v", err)
	}
}

func TestUDPCannotBeListenedOnOrDialled(t *testing.T) {
	if ln, err := Listen(UDP, "127.0.0.1:0"); err == nil {
		ln.Close()
		t.Fatal("Listen(UDP) succeeded in a release build")
	} else if !errors.Is(err, ErrUDPNotSupported) {
		t.Fatalf("Listen(UDP) = %v, want ErrUDPNotSupported", err)
	}
	if c, err := Dial(UDP, "127.0.0.1:1", 100*time.Millisecond); err == nil {
		c.Close()
		t.Fatal("Dial(UDP) succeeded in a release build")
	} else if !errors.Is(err, ErrUDPNotSupported) {
		t.Fatalf("Dial(UDP) = %v, want ErrUDPNotSupported", err)
	}
}

func TestAutoPreferenceHasNoUDP(t *testing.T) {
	if len(AutoPreference) == 0 || AutoPreference[0] != QUIC {
		t.Fatalf("AutoPreference = %v, want quic first", AutoPreference)
	}
	for _, k := range AutoPreference {
		if k == UDP {
			t.Fatalf("AutoPreference = %v contains udp; a release must never rank a transport it refuses to dial", AutoPreference)
		}
	}
}
