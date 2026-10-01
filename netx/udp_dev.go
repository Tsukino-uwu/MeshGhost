//go:build meshghost_devudp

package netx

import (
	"net"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/udpconn"
)

// The dev build's plain udp, compiled only under the meshghost_devudp tag: an A/B control against quic (the same
// datagram path without QUIC's congestion control) and Wireshark-readable packets. Its known spoofing and deadline
// gaps are accepted because nothing that ships is built with this tag; udp_release.go is the other half.

// AutoPreference is the order Auto picks in, udp last: it cannot be encrypted, so nothing picks it while quic is
// available.
var AutoPreference = []Kind{QUIC, TCP, UDP}

func parseUDPKind() (Kind, error) { return UDP, nil }

func udpListen(addr string) (net.Listener, error) { return udpconn.Listen(addr) }

func udpDial(addr string, timeout time.Duration) (net.Conn, error) {
	return udpconn.Dial(addr, timeout)
}
