//go:build meshghost_devudp

package main

import (
	"flag"
	"net"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// The dev build's plain udp, compiled only under the meshghost_devudp tag: the -listen-udp flag, and where udp lands
// when quic takes the shared port.

// udpListenFlag registers -listen-udp.
func udpListenFlag() *string {
	return flag.String("listen-udp", sharesAddrPort,
		"where the plain udp transport listens. Empty (the default) means -addr's port -- except "+
			"when quic is served too, where udp moves to port "+FallbackUDPPort+" on -addr's own "+
			"interface (so a relay on 0.0.0.0:7777 serves udp on 0.0.0.0:"+FallbackUDPPort+") and "+
			"quic keeps the shared number. quic is a default transport and plain udp is opt-in, so "+
			"udp is the one that takes the odd port. Ignored unless udp is in -transport")
}

// resolveUDPListen is resolveUDPAddr, under the name main calls in both builds.
func resolveUDPListen(kinds []netx.Kind, addr, udpAddr string) (string, error) {
	return resolveUDPAddr(kinds, addr, udpAddr)
}

// checkUDPConfig: a dev build serves udp, so listen_udp is a setting here.
func checkUDPConfig(string) error { return nil }

// FallbackUDPPort is the port plain udp moves to when quic is also served, since quic runs over udp too and the two
// would collide on one number. udp is the one that moves: quic is a default transport, while plain udp is opt-in,
// unencryptable and last in netx.AutoPreference. Only the port relocates; the bind interface stays -addr's.
const FallbackUDPPort = "7780"

// FallbackUDPAddr is where udp relocates for the default -addr (127.0.0.1:7777), and for an -addr with no port.
const FallbackUDPAddr = "127.0.0.1:" + FallbackUDPPort

// resolveUDPAddr decides where the plain udp transport listens, the mirror of resolveQuicAddr: quic keeps -addr's
// port and udp moves aside when both are served. Moving udp silently is safe because nothing picks udp
// automatically, and the startup log prints the port it landed on.
func resolveUDPAddr(kinds []netx.Kind, addr, udpAddr string) (string, error) {
	if !servesKind(kinds, netx.UDP) {
		// Not serving udp: -listen-udp passes through untouched, as -listen-quic does when quic is off.
		return udpAddr, nil
	}
	if udpAddr != sharesAddrPort {
		// Placed by the operator, and believed: naming a port is taking responsibility for forwarding it.
		return udpAddr, nil
	}
	if servesKind(kinds, netx.QUIC) {
		return relocatedUDPAddr(addr), nil
	}
	return addr, nil
}

// relocatedUDPAddr moves udp off -addr's port and nowhere else: the same bind interface, FallbackUDPPort for the
// port. An -addr it cannot split keeps FallbackUDPAddr: netx.ListenWithTLS refuses that address with its own message.
func relocatedUDPAddr(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return FallbackUDPAddr
	}
	return net.JoinHostPort(host, FallbackUDPPort)
}
