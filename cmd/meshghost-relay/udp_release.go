//go:build !meshghost_devudp

package main

import (
	"fmt"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// A release relay serves no plain udp. netx.ParseKinds already refuses "udp" as a transport; this file closes the
// listen_udp key and keeps main() free of the flag.

// udpListenFlag registers no flag: there is no -listen-udp in a release.
func udpListenFlag() *string {
	s := ""
	return &s
}

// resolveUDPListen has nothing to resolve: kinds can never contain udp here.
func resolveUDPListen(_ []netx.Kind, _, udpAddr string) (string, error) {
	return udpAddr, nil
}

// checkUDPConfig refuses a config.json that still places plain udp. An empty listen_udp is ignored: older shipped
// configs carry the key empty, and a host who never touched it asked for nothing.
func checkUDPConfig(listenUDP string) error {
	if listenUDP == "" {
		return nil
	}
	return fmt.Errorf("meshghost-relay: \"listen_udp\" is set to %q, but plain udp is not a supported "+
		"transport (since 2026-09-15; use quic, which is encrypted, or tcp). Remove the key from "+
		"config.json", listenUDP)
}
