package netx

import (
	"net"
	"sync"
)

// UDPUsable reports whether this process can create a udp socket at all, and caches the answer for its life. quic's
// first act is net.ListenUDP on the wildcard address, so a process that cannot open one cannot have quic or udp.
//
// Under Wine, Go's netFD.init returns the WSAEOPNOTSUPP that Wine answers to WSAIoctl(SIO_UDP_CONNRESET) and
// SIO_UDP_NETRESET, so every udp socket in the process fails. Opening a socket rather than detecting Wine stays right
// once Wine implements the ioctls, and scopes itself: a native Linux client beside a Wine-hosted one answers true.
func UDPUsable() bool {
	udpUsableOnce.Do(func() {
		c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
		if err != nil {
			udpUsableErr = err
			return
		}
		_ = c.Close()
		udpUsable = true
	})
	return udpUsable
}

// UDPUnusableReason returns why UDPUsable said no, for the log line that
// explains the downgrade. Empty when udp works.
func UDPUnusableReason() string {
	if UDPUsable() {
		return ""
	}
	if udpUsableErr == nil {
		return "unknown"
	}
	return udpUsableErr.Error()
}

var (
	udpUsableOnce sync.Once
	udpUsable     bool
	udpUsableErr  error
)
