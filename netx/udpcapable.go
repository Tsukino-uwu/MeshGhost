package netx

import (
	"net"
	"sync"
)

// UDPUsable reports whether this machine can create a udp socket at all, and
// caches the answer for the life of the process.
//
// It exists because "can I do quic" and "can I do plain udp" are not two
// questions on some platforms — they are one, answered before a single packet
// moves. quic.DialAddr's first act is net.ListenUDP on the wildcard address,
// and udpconn's is the same, so a machine that cannot open a udp socket cannot
// have either transport no matter what the relay offers.
//
// Wine/Proton is the case that found it. Go's netFD.init issues
// WSAIoctl(SIO_UDP_CONNRESET) and, since the fix for golang/go#68614,
// SIO_UDP_NETRESET, and RETURNS the error rather than ignoring it; Wine does
// not implement them and answers WSAEOPNOTSUPP ("winapi error #10045"), so
// EVERY udp socket in the process fails. A Proton tester's log showed the cost:
// two doomed quic dials and up to seven seconds of connect delay on every
// single game launch, forever, because the per-process condemnation in
// Core.unusableTransports is relearned from scratch each time the core starts.
//
// # Why this is a probe and not a platform check
//
// Asking "am I under Wine" would answer today's question and be wrong later:
// Wine that implements the ioctls would be denied quic by a hard-coded rule it
// no longer deserves. Asking the machine to actually open a socket costs one
// syscall at startup, needs no Wine detection, and is right on any platform
// that fails udp for any reason — including ones nobody has hit yet.
//
// It is also self-scoping, which is the property that matters when a Linux
// player has both clients available. This asks about THIS PROCESS. A
// Wine-hosted client autostarted by the game answers false; a native Linux
// client, which is a different process on the Linux side of the prefix, opens
// its socket normally and answers true — even when both read the same
// config.json out of the same game folder. No setting has to describe the
// situation, and no setting can describe it wrongly.
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
