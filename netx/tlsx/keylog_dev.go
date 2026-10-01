//go:build meshghost_devudp

package tlsx

// Dev-only TLS session keys for Wireshark: with the meshghost_devudp tag and SSLKEYLOGFILE set, every configuration
// this package builds appends its session secrets to that file in the NSS key log format, so a capture can be decoded
// on the developer's own machine. A release has no such hook (keylog_release.go).

import (
	"log"
	"os"
)

func init() {
	path := os.Getenv("SSLKEYLOGFILE")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		log.Printf("tlsx: SSLKEYLOGFILE=%q could not be opened: %v (session keys are not being logged)", path, err)
		return
	}
	keyLogWriter = f
	log.Printf("tlsx: DEV BUILD: TLS session keys are being written to %s for Wireshark -- every "+
		"session this process makes is decodable with that file", path)
}
