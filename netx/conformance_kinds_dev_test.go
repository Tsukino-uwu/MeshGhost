//go:build meshghost_devudp

package netx_test

import "github.com/Tsukino-uwu/MeshGhost/netx"

// transportsUnderTest under the dev tag: all three, so a comparison run
// (dev-scripts/run-gotests-udp.bat) holds udp to the same contract.
var transportsUnderTest = []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}
