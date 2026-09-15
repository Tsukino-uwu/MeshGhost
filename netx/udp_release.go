//go:build !meshghost_devudp

package netx

import (
	"errors"
	"net"
	"time"
)

// This file is what a RELEASE knows about plain udp: that it is not a
// transport. ADR 0065 (2026-09-15): udp never rescued a player quic could
// not (quic runs over udp, so whatever blocks one blocks both), it cannot be
// encrypted, and it was attack surface for no player benefit. The
// implementation stays in netx/udpconn behind the meshghost_devudp build tag
// as a comparison tool; udp_dev.go is this file's other half.

// ErrUDPNotSupported is what every udp entry point returns in a release. A
// config.json that still says "udp" is an error, not a fallback, for the
// same reason ParseKind refuses a typo: a transport nobody chose is a
// downgrade nobody sees.
var ErrUDPNotSupported = errors.New("netx: udp is not a supported transport; use quic or tcp")

// AutoPreference is the order Auto picks in: the first offered transport
// wins. QUIC first because it is the only one that is both loss-tolerant
// and encrypted; TCP second, and always reachable because the handshake
// just used it. (Until 2026-09-15 plain udp was a deliberate last entry.)
var AutoPreference = []Kind{QUIC, TCP}

func parseUDPKind() (Kind, error) { return TCP, ErrUDPNotSupported }

func udpListen(string) (net.Listener, error) { return nil, ErrUDPNotSupported }

func udpDial(string, time.Duration) (net.Conn, error) { return nil, ErrUDPNotSupported }
