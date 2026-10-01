//go:build meshghost_devudp

package main

// The udp address-relocation tests, compiled only under the meshghost_devudp tag.

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// TestUDPRelocationKeepsTheBindInterface: only the port moves. A udp listener on an interface the operator never
// chose is unreachable from outside, while the relay advertises its port to remote clients anyway.
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
		// netx.ListenWithTLS refuses this address with its own message, so no second error path.
		got, err := resolveUDPAddr(both, "not-an-address", sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != FallbackUDPAddr {
			t.Fatalf("got %q, want %q", got, FallbackUDPAddr)
		}
	})

	t.Run("quic still keeps the shared port", func(t *testing.T) {
		// quic is the default transport, so quic keeps -addr's number and udp is the one that moves.
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
		got, err := resolveUDPAddr([]netx.Kind{netx.TCP, netx.UDP, netx.QUIC}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		// The port moves; the interface does not.
		want := "0.0.0.0:" + FallbackUDPPort
		if got != want {
			t.Fatalf("got %q, want %q -- udp takes the odd port when quic is served, on -addr's own interface", got, want)
		}
	})

	t.Run("udp without quic keeps addr's port", func(t *testing.T) {
		// Nothing to collide with, so no reason to make a host forward a second number.
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
		// Out of the box there is no udp, so nothing relocates and hosting stays one forwarded number.
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
		// The relay ships serving tcp,quic, so this is the path almost every real host takes.
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
