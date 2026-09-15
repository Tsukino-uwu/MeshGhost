//go:build !meshghost_devudp

package relay

import "github.com/Tsukino-uwu/MeshGhost/netx"

// transportKindsUnderTest is every transport the relay's mixed-room and
// budget tests run against: what ships. Plain udp joins the list only under
// the meshghost_devudp tag (udp_test.go), ADR 0065.
var transportKindsUnderTest = []netx.Kind{netx.TCP, netx.QUIC}
