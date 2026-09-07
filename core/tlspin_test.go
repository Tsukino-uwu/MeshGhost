package core

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// A pin means the session is authenticated, so it must escalate tls to
// required.
//
// Under tlsx.Auto, "the pin did not match" and "this relay is too old to speak
// TLS" arrive as the same error from tlsx.Client, and Auto exists to fall back
// to plaintext on that error. So before 2026-09-07 a fingerprint under the
// SHIPPED default turned MITM detection into an automatic downgrade: an
// attacker who refused the handshake, or presented any certificate at all, got
// a plaintext session -- and the room code crosses the discovery leg.
//
// tlsOptions is the single place the discovery leg and the session leg both
// read, which is why the escalation lives there rather than at the flag.
func TestAPinEscalatesAutoToRequired(t *testing.T) {
	for _, tc := range []struct {
		name string
		mode tlsx.Mode
		pin  string
		want tlsx.Mode
	}{
		{"auto with a pin is required", tlsx.Auto, "ab:cd", tlsx.Required},
		{"auto with no pin stays auto", tlsx.Auto, "", tlsx.Auto},
		{"required with a pin stays required", tlsx.Required, "ab:cd", tlsx.Required},
		{"off is left alone", tlsx.Off, "ab:cd", tlsx.Off},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := New()
			c.TLS = tc.mode
			c.TLSFingerprint = tc.pin
			got := c.tlsOptions()
			if got.Mode != tc.want {
				t.Fatalf("tlsOptions().Mode = %v, want %v (pin %q, configured %v)",
					got.Mode, tc.want, tc.pin, tc.mode)
			}
			if got.Fingerprint != tc.pin {
				t.Fatalf("tlsOptions().Fingerprint = %q, want %q", got.Fingerprint, tc.pin)
			}
		})
	}
}
