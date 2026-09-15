//go:build !meshghost_devudp

package tlsx

// A release never logs TLS session keys: keyLogWriter stays nil whatever the
// environment says. keylog_dev.go is the tagged opposite.
