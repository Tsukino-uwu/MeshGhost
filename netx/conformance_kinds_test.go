//go:build !meshghost_devudp

package netx_test

import "github.com/Tsukino-uwu/MeshGhost/netx"

// transportsUnderTest is every kind netx can dial and listen on in a release; plain udp joins only under the
// meshghost_devudp tag (conformance_kinds_dev_test.go). Adding a kind subjects it to the whole suite.
var transportsUnderTest = []netx.Kind{netx.TCP, netx.QUIC}
