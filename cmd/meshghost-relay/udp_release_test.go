//go:build !meshghost_devudp

package main

import (
	"strings"
	"testing"
)

// TestAConfigThatStillPlacesUDPIsRefused pins the release build at listen_udp, the one door netx.ParseKinds does not
// cover: empty is ignored, and a real value is refused with the alternatives named.
func TestAConfigThatStillPlacesUDPIsRefused(t *testing.T) {
	if err := checkUDPConfig(""); err != nil {
		t.Fatalf("an empty listen_udp must be ignored, got: %v", err)
	}
	err := checkUDPConfig("0.0.0.0:7780")
	if err == nil {
		t.Fatal("a non-empty listen_udp was accepted by a release build")
	}
	for _, want := range []string{"listen_udp", "not a supported transport", "quic", "tcp"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("refusal %q does not mention %q", err, want)
		}
	}
	// A release registers no flag, so without a config the value is empty.
	if v := udpListenFlag(); v == nil || *v != "" {
		t.Fatalf("udpListenFlag = %v, want an empty value in a release", v)
	}
}
