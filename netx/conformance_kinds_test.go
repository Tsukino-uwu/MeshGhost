//go:build !meshghost_devudp

package netx_test

import "github.com/Tsukino-uwu/MeshGhost/netx"

// transportsUnderTest is every kind netx can dial and listen on in a
// release: what ships. Plain udp joins only under the meshghost_devudp tag
// (conformance_kinds_dev_test.go), ADR 0065 -- and it was the "unreliable
// transport" in this suite until then, so quic carries that role now
// rather than the coverage quietly shrinking.
var transportsUnderTest = []netx.Kind{netx.TCP, netx.QUIC}
