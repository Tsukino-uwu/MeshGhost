//go:build meshghost_devudp

package main

import (
	"flag"
	"net"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// The DEV build's plain udp, compiled only under the meshghost_devudp tag
// (ADR 0065, 2026-09-15): the -listen-udp flag, where udp lands when quic
// takes the shared port, and the consts that say so. Lifted verbatim from
// main.go; udp_release.go is the release's half, where none of this exists.

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

// FallbackUDPAddr is where the plain udp transport goes when it cannot share
// -addr's udp port, which happens when quic is also being served -- quic runs
// over udp too, and the two would collide on one number.
//
// **udp is the one that moves, and that is the whole point.** quic is a DEFAULT
// transport (-transport is "tcp,quic"), so a host who never thought about
// transports is serving it; plain udp is opt-in, unencryptable, and last in
// netx.AutoPreference. Making the default transport surrender the shared port to
// an opt-in one had it backwards -- it broke "forward 7777" for the common case
// to accommodate the rare one. Corrected 2026-08-27 after the user pointed out
// that tcp and quic are supposed to share while udp takes the odd port.
//
// 7778 and 7779 are both skipped because packaging/release/README.txt already
// hands those out as local bridge ports (7778 normally, 7779 for a second copy
// on the same machine). Neither would actually collide -- the bridge is TCP and
// this is UDP, which are separate port spaces -- but a reader comparing two
// config files should not have to know that to tell whether something is a typo.
//
// **Only the PORT relocates. The bind interface is always -addr's** -- see
// relocatedUDPAddr. Every paragraph above justifies the port and none of them
// ever addressed the host, and until 2026-09-08 this whole string was returned
// wholesale: a host running `-addr 0.0.0.0:7777 -transport tcp,udp,quic` bound
// udp on loopback, unreachable from anywhere but that machine, while the startup
// banner told them to forward 7780 and the relay advertised udp:7780 to remote
// clients who resolved it against the address they had dialled and failed.
const FallbackUDPPort = "7780"

// FallbackUDPAddr is what the relocation lands on for the DEFAULT -addr
// (127.0.0.1:7777), which is what the -listen-udp help text quotes. It is an
// example of the rule, not the rule: the rule is FallbackUDPPort on -addr's own
// host, and a relay bound to 0.0.0.0 relocates udp to 0.0.0.0:7780.
const FallbackUDPAddr = "127.0.0.1:" + FallbackUDPPort

// resolveUDPAddr decides where the plain udp transport listens.
//
// It is the mirror of resolveQuicAddr and carries the actual conflict rule: quic
// keeps -addr's port because it is a default transport, and udp -- opt-in,
// unencryptable, last in netx.AutoPreference -- moves aside when both are served.
//
// Relocating udp silently is safe in a way relocating quic never was: nothing
// picks udp automatically, so the only way to be on it is to have asked for it by
// name, and the startup log prints the port it landed on. A host who did not ask
// for udp is unaffected, and one who did is reading the log they asked for.
func resolveUDPAddr(kinds []netx.Kind, addr, udpAddr string) (string, error) {
	if !servesKind(kinds, netx.UDP) {
		// Not serving udp: -listen-udp is irrelevant and passed through untouched,
		// the same way -listen-quic is when quic is off.
		return udpAddr, nil
	}
	if udpAddr != sharesAddrPort {
		// Explicitly placed by the operator. Believed without further checking:
		// naming a port is the act of taking responsibility for forwarding it.
		return udpAddr, nil
	}
	if servesKind(kinds, netx.QUIC) {
		return relocatedUDPAddr(addr), nil
	}
	return addr, nil
}

// relocatedUDPAddr moves udp off -addr's port and nowhere else: same bind
// interface, FallbackUDPPort instead of the port. This is the shape
// resolveQuicAddr next door has always had -- it returns addr, so it inherits
// whatever interface the operator chose -- and the shape resolveUDPAddr lacked
// until 2026-09-08, when it returned the whole of FallbackUDPAddr and threw the
// operator's bind interface away with the port. A host who typed
// `-addr 0.0.0.0:7777` got a udp listener nobody outside the machine could
// reach, plus a startup banner telling them to forward a port that would never
// carry anything.
//
// An -addr with no port at all (or otherwise unsplittable) keeps the old
// constant. It is not a shape this binary can bind anyway -- netx.ListenWithTLS
// gets the same string and fails -- so this is about not inventing a second
// error path for input that is already about to be refused with its own message.

func relocatedUDPAddr(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return FallbackUDPAddr
	}
	return net.JoinHostPort(host, FallbackUDPPort)
}
