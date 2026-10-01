//go:build !meshghost_devudp

package relay

import "github.com/Tsukino-uwu/MeshGhost/netx"

// transportKindsUnderTest is the shipped transports the mixed-room and budget tests run against; plain udp joins only
// under the meshghost_devudp tag.
var transportKindsUnderTest = []netx.Kind{netx.TCP, netx.QUIC}
