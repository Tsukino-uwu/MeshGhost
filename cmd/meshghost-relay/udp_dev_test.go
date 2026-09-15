//go:build meshghost_devudp

package main

// The udp address-relocation tests, compiled only under the meshghost_devudp
// tag (ADR 0065, 2026-09-15). Moved verbatim from relaycli_test.go and
// main_test.go's TestResolveQuicAddr.

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// TestUDPRelocationKeepsTheBindInterface is the F7 regression.
//
// Returning FallbackUDPAddr wholesale threw away the operator's -addr along
// with its port: a relay started with `-addr 0.0.0.0:7777 -transport
// tcp,udp,quic` bound udp on 127.0.0.1, reachable from nowhere but the host's
// own machine, while the startup banner told the host to forward 7780 and the
// relay advertised udp:7780 to remote clients -- who resolve an offered port
// against the address they dialled, and so dialled a port with nothing on it.
// Every line of commentary on that constant justified the PORT; none of them
// ever addressed the host.
func TestUDPRelocationKeepsTheBindInterface(t *testing.T) {
	both := []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}

	cases := []struct {
		name string
		addr string
		want string
	}{
		{"every interface", "0.0.0.0:7777", "0.0.0.0:" + FallbackUDPPort},
		{"one public interface", "203.0.113.9:7777", "203.0.113.9:" + FallbackUDPPort},
		{"ipv6", "[::]:7777", "[::]:" + FallbackUDPPort},
		{"loopback, the default", "127.0.0.1:7777", FallbackUDPAddr},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveUDPAddr(both, tc.addr, sharesAddrPort)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("udp landed on %q for -addr %q, want %q -- only the PORT moves; a udp "+
					"listener on an interface the operator never chose is unreachable from "+
					"outside, and the relay advertises it to remote clients anyway",
					got, tc.addr, tc.want)
			}
		})
	}

	t.Run("an addr with no port keeps the old constant", func(t *testing.T) {
		// Not a shape this binary can bind either way -- netx.ListenWithTLS gets
		// the same string and refuses with its own message -- so this is about
		// not inventing a second error path for input already being refused.
		got, err := resolveUDPAddr(both, "not-an-address", sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != FallbackUDPAddr {
			t.Fatalf("got %q, want %q", got, FallbackUDPAddr)
		}
	})

	t.Run("quic still keeps the shared port", func(t *testing.T) {
		// The 2026-08-27 rule this fix must not disturb: quic is the default
		// transport, so quic keeps -addr's number and udp is the one that moves.
		got, err := resolveQuicAddr(both, "0.0.0.0:7777", sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "0.0.0.0:7777" {
			t.Fatalf("quic landed on %q, want it on -addr's own port", got)
		}
	})
}

func TestResolveUDPAddr(t *testing.T) {
	const addr = "0.0.0.0:7777"

	t.Run("udp is the one that moves, not quic", func(t *testing.T) {
		// The rule this whole change exists for.
		got, err := resolveUDPAddr([]netx.Kind{netx.TCP, netx.UDP, netx.QUIC}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		// The PORT moves; the interface does not. This asserted FallbackUDPAddr
		// until 2026-09-08, i.e. the loopback host -- which is what let
		// resolveUDPAddr discard the operator's -addr entirely and bind udp
		// somewhere no remote player could reach, while the startup banner told
		// them to forward it.
		want := "0.0.0.0:" + FallbackUDPPort
		if got != want {
			t.Fatalf("got %q, want %q -- udp takes the odd port when quic is served, on -addr's own interface", got, want)
		}
	})

	t.Run("udp without quic keeps addr's port", func(t *testing.T) {
		// Nothing to collide with, so there is no reason to make a host forward
		// a second number.
		got, err := resolveUDPAddr([]netx.Kind{netx.TCP, netx.UDP}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != addr {
			t.Fatalf("got %q, want %q", got, addr)
		}
	})

	t.Run("an explicit listen-udp is believed", func(t *testing.T) {
		const explicit = "0.0.0.0:7999"
		got, err := resolveUDPAddr([]netx.Kind{netx.TCP, netx.UDP, netx.QUIC}, addr, explicit)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != explicit {
			t.Fatalf("got %q, want %q -- naming a port is taking responsibility for forwarding it", got, explicit)
		}
	})

	t.Run("listen-udp is passed through untouched when udp is not served", func(t *testing.T) {
		got, err := resolveUDPAddr([]netx.Kind{netx.TCP, netx.QUIC}, addr, "0.0.0.0:9999")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "0.0.0.0:9999" {
			t.Fatalf("got %q, want it passed through unvalidated", got)
		}
	})

	t.Run("the shipped default serves tcp,quic and never places udp", func(t *testing.T) {
		// Out of the box there is no udp at all, so nothing should be relocated
		// and hosting stays one forwarded number.
		kinds, err := netx.ParseKinds("tcp,quic")
		if err != nil {
			t.Fatalf("ParseKinds: %v", err)
		}
		quic, err := resolveQuicAddr(kinds, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		udp, err := resolveUDPAddr(kinds, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if quic != addr || udp != sharesAddrPort {
			t.Fatalf("quic=%q udp=%q -- want quic on %q and udp untouched", quic, udp, addr)
		}
	})

	t.Run("the shipped default (tcp,quic) lands on a shared port", func(t *testing.T) {
		// Guards the out-of-the-box case specifically: the relay ships serving
		// tcp,quic, so this is the path almost every real host takes.
		kinds, err := netx.ParseKinds("tcp,quic")
		if err != nil {
			t.Fatalf("ParseKinds: %v", err)
		}
		got, err := resolveQuicAddr(kinds, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("the shipped default must not refuse to start: %v", err)
		}
		if got != addr {
			t.Fatalf("got %q, want %q", got, addr)
		}
	})
}
