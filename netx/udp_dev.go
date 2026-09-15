//go:build meshghost_devudp

package netx

import (
	"net"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/udpconn"
)

// This file is the DEV build's plain udp: the real thing, compiled only
// under the meshghost_devudp tag (ADR 0065). It exists as an A/B control
// against quic -- the same unreliable, datagram-shaped path without QUIC's
// congestion control -- and for Wireshark-readable packets. Nothing that
// ships is built with this tag; udp_release.go is the other half.
//
// Known, accepted, and closed by not shipping rather than by fixing (fourth
// adversarial review, 2026-09-13, section D): a limiter-refused udp joiner
// is sent its ready token before netx.LimitListener decides
// (udpconn/listener.go) and udp Close sends nothing, so it waits out its
// own timeout (D1); the handshake phase adopts the first FF 02 / FF 06 from
// the relay's address, so a source-forging spray inside one RTT can hand a
// dialer a token the relay never issued (D2); the read loop performs socket
// writes with no deadline (D3).

// AutoPreference is the order Auto picks in. UDP last, deliberately: it
// cannot be encrypted, so nothing should pick it on a user's behalf while
// quic is available.
var AutoPreference = []Kind{QUIC, TCP, UDP}

func parseUDPKind() (Kind, error) { return UDP, nil }

func udpListen(addr string) (net.Listener, error) { return udpconn.Listen(addr) }

func udpDial(addr string, timeout time.Duration) (net.Conn, error) {
	return udpconn.Dial(addr, timeout)
}
