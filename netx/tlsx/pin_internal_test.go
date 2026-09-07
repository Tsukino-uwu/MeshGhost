package tlsx

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"testing"
	"time"
)

// newDER returns a self-signed certificate's DER bytes. Two calls give two
// unrelated certificates, which is all these tests need: the pin is compared
// against raw DER, so nothing here has to chain or verify.
func newDER(t *testing.T, cn string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	return der
}

// The pin must be satisfied ONLY by the leaf. InsecureSkipVerify is set on the
// client config on purpose (a bare IP has no CA and no hostname to check), so
// Go builds and verifies no chain: rawCerts is whatever the peer chose to send,
// and only rawCerts[0] is bound to the handshake signature. Before 2026-09-07
// the check looped over every entry, so an attacker who copied the relay's
// public certificate could present [attacker_leaf, genuine_relay_cert], match
// the pin at index 1, and key the session with a certificate they own.
//
// This test fails against that loop: the pin here is the genuine relay's, and
// the genuine certificate IS present -- just not where it proves anything.
func TestPinIsSatisfiedOnlyByTheLeafCertificate(t *testing.T) {
	relay := newDER(t, "relay")
	attacker := newDER(t, "attacker")
	pin := fingerprint(relay)

	verify := clientConfig("", pin).VerifyPeerCertificate
	if verify == nil {
		t.Fatal("a non-empty pin must install VerifyPeerCertificate")
	}

	if err := verify([][]byte{relay}, nil); err != nil {
		t.Fatalf("the genuine relay's own certificate must satisfy its pin: %v", err)
	}
	if err := verify([][]byte{attacker, relay}, nil); err == nil {
		t.Fatal("a chain whose LEAF is not the pinned certificate was accepted: " +
			"only rawCerts[0] is bound to the handshake, so matching any later " +
			"entry accepts a certificate the peer does not hold the key for")
	}
	if err := verify([][]byte{attacker}, nil); err == nil {
		t.Fatal("an unrelated certificate was accepted")
	}
	if err := verify(nil, nil); err == nil {
		t.Fatal("an empty chain was accepted")
	}
}

// An empty pin means encryption without authentication, which is the package
// doc's documented default -- no verifier is installed at all.
func TestNoPinInstallsNoVerifier(t *testing.T) {
	if clientConfig("", "").VerifyPeerCertificate != nil {
		t.Fatal("an empty pin must not install a verifier")
	}
}
