//go:build !meshghost_devudp

package netx

import (
	"errors"
	"net"
	"time"
)

// A release knows plain udp only as not a transport: it never rescued a player quic could not (quic runs over udp, so
// whatever blocks one blocks both), it cannot be encrypted, and it was attack surface for no player benefit. The
// implementation stays in netx/udpconn behind the meshghost_devudp tag; udp_dev.go is the other half.

// ErrUDPNotSupported is what every udp entry point returns in a release. A config.json that still says "udp" is an
// error, not a fallback, for the same reason ParseKind refuses a typo.
var ErrUDPNotSupported = errors.New("netx: udp is not a supported transport; use quic or tcp")

// AutoPreference is the order Auto picks in; the first offered transport wins. QUIC first, the only one both
// loss-tolerant and encrypted; TCP second, always reachable because the handshake just used it.
var AutoPreference = []Kind{QUIC, TCP}

func parseUDPKind() (Kind, error) { return TCP, ErrUDPNotSupported }

func udpListen(string) (net.Listener, error) { return nil, ErrUDPNotSupported }

func udpDial(string, time.Duration) (net.Conn, error) { return nil, ErrUDPNotSupported }
