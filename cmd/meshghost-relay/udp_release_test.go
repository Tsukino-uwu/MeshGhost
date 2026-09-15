//go:build !meshghost_devudp

package main

import (
	"strings"
	"testing"
)

// TestAConfigThatStillPlacesUDPIsRefused pins ADR 0065's release half at the
// one door netx.ParseKinds does not cover: listen_udp. An empty value is what
// every config shipped before 2026-09-15 carries and is ignored; a real one
// is refused with the alternatives named. (Build-tagged sibling:
// udp_dev_test.go, where the same key is a setting.)
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
	// And the flag a release does not register leaves the value empty, so the
	// check above is the whole story for a relay started with no config.
	if v := udpListenFlag(); v == nil || *v != "" {
		t.Fatalf("udpListenFlag = %v, want an empty value in a release", v)
	}
}
