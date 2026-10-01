package tlsx

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"
)

// newDER returns a self-signed certificate's DER bytes. Two calls give two unrelated certificates; the verifier is
// handed raw DER, so nothing here has to chain or verify.
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

// The verifier must be handed only the leaf: with InsecureSkipVerify there is no chain building, and only the first
// certificate is bound to the handshake signature. The genuine relay's certificate is present here, just not where
// it proves anything.
func TestTheVerifierIsHandedOnlyTheLeafCertificate(t *testing.T) {
	relay := newDER(t, "relay")
	attacker := newDER(t, "attacker")
	want := Fingerprint(relay)

	check := func(leaf []byte) error {
		if Fingerprint(leaf) != want {
			return errors.New("not the relay")
		}
		return nil
	}
	// The completed handshake's PeerCertificates are whatever the peer sent, in its order.
	verify := func(chain [][]byte, _ any) error {
		state := tls.ConnectionState{HandshakeComplete: true}
		for _, der := range chain {
			c, err := x509.ParseCertificate(der)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			state.PeerCertificates = append(state.PeerCertificates, c)
		}
		return VerifyLeaf(state, check)
	}

	if err := verify([][]byte{relay}, nil); err != nil {
		t.Fatalf("the genuine relay's own certificate must pass: %v", err)
	}
	if err := verify([][]byte{attacker, relay}, nil); err == nil {
		t.Fatal("a chain whose LEAF is not the relay's certificate was accepted: " +
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

func TestClientConfigRefusesANilVerifier(t *testing.T) {
	if _, err := ClientConfig("", nil); err == nil {
		t.Fatal("ClientConfig with a nil verifier returned a config; it must refuse")
	}
}

// TestNormalizeFingerprintIsPickyAboutLengthOnly: a placeholder must not normalize to the empty string. The
// known-relays store parses its file with this, so the rule protects a hand-edited entry.
func TestNormalizeFingerprintIsPickyAboutLengthOnly(t *testing.T) {
	real := Fingerprint(newDER(t, "relay"))
	for _, ok := range []string{
		real,
		strings.ToUpper(real),
		"  " + real + "\n",
		withColons(real),
	} {
		got, err := NormalizeFingerprint(ok)
		if err != nil || got != real {
			t.Fatalf("NormalizeFingerprint(%q) = %q, %v; want the fingerprint", ok, got, err)
		}
	}
	for _, bad := range []string{"<paste here>", "TODO", "zz", "abc", real[:63], real + "0", ":::"} {
		if got, err := NormalizeFingerprint(bad); err == nil {
			t.Fatalf("NormalizeFingerprint(%q) = %q with no error; a value that is not a fingerprint must refuse", bad, got)
		}
	}
	if got, err := NormalizeFingerprint("  "); err != nil || got != "" {
		t.Fatalf("NormalizeFingerprint(blank) = %q, %v; want the empty string and no error", got, err)
	}
}

func withColons(hex string) string {
	var b strings.Builder
	for i := 0; i < len(hex); i += 2 {
		if i > 0 {
			b.WriteByte(':')
		}
		b.WriteString(hex[i : i+2])
	}
	return b.String()
}

// TestTheVerifierSeesOnlyACertificateTheServerProvedItHolds: the known-relays Verifier records what it is shown, so a
// server presenting the genuine relay's certificate while signing with another key must fail the handshake without
// the verifier being called, or an on-path attacker rewrites a player's remembered identity.
func TestTheVerifierSeesOnlyACertificateTheServerProvedItHolds(t *testing.T) {
	_, genuineKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	genuineDER, err := x509.CreateCertificate(nil, tmpl, tmpl, genuineKey.Public(), genuineKey)
	if err != nil {
		t.Fatal(err)
	}
	_, impostorKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	server := &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{{Certificate: [][]byte{genuineDER}, PrivateKey: impostorKey}},
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	go func() {
		_ = tls.Server(b, server).Handshake()
		_ = b.Close()
	}()
	calls := 0
	_, err = Client(a, "", func([]byte) error { calls++; return nil }, 2*time.Second)
	if err == nil {
		t.Fatal("a server that cannot sign for its certificate completed the handshake")
	}
	if calls != 0 {
		t.Fatalf("the verifier was called %d time(s) for a certificate the server never proved it holds", calls)
	}
}
