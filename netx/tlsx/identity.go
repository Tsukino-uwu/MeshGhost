package tlsx

// The relay's persisted identity: one key pair and one certificate, kept in
// a folder beside the relay's config so a client that connected once can
// recognize the same relay after a restart. Until 2026-09-15 the certificate
// lived in memory and was regenerated every run, which was right while
// nothing checked it (ADR 0034: a key file next to the exe bought no
// security). Now every client checks it (core's known-relays store), and a
// persisted key is what makes that check mean anything. ADR 0066.

import (
	"crypto/ed25519"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// The files LoadOrCreateIdentity keeps in its folder. All three are written
// together; the fingerprint is derived from the certificate and is there for
// a human to read or copy, never for the loader to trust.
const (
	// IdentityDirName is the folder's name, beside the relay's config.json.
	IdentityDirName = "tls"
	// KeyFileName holds the private key: PKCS#8, PEM, mode 0600 where the
	// OS supports modes. Keep it private: whoever has it IS this relay to
	// every client that has connected before.
	KeyFileName = "relay.key"
	// CertFileName holds the certificate, PEM. Persisted because a
	// certificate re-signed from the same key has a new serial and so a new
	// fingerprint -- the key alone does not pin the identity.
	CertFileName = "relay.crt"
	// FingerprintFileName holds the fingerprint as one line of hex, so an
	// operator can read it without a tool.
	FingerprintFileName = "relay.fingerprint"
)

// LoadOrCreateIdentity returns the listener's TLS configuration for the
// identity kept in dir, creating one when the folder holds none.
//
// The rules are all-or-nothing, and never silent:
//
//   - Neither the key nor the certificate exists: generate both, write the
//     three files (each through a temporary file and a rename, so a crash
//     mid-write leaves nothing half-written), and return them.
//   - Both exist and agree: load them.
//   - Anything else -- one of the two is missing, either is unreadable or
//     does not parse, the key does not match the certificate -- is an
//     ERROR the relay should refuse to start on. Regenerating quietly in
//     any of those cases would give the relay a new identity every client
//     then warns about, while hiding the broken file that caused it.
//
// The fingerprint file is rewritten whenever it is missing or disagrees
// with the certificate: it is derived, not identity, so it can never be
// the reason a relay refuses to start.
func LoadOrCreateIdentity(dir, alpn string) (*tls.Config, string, error) {
	keyPath := filepath.Join(dir, KeyFileName)
	certPath := filepath.Join(dir, CertFileName)
	fpPath := filepath.Join(dir, FingerprintFileName)

	keyPEM, keyErr := os.ReadFile(keyPath)
	certPEM, certErr := os.ReadFile(certPath)
	switch {
	case errors.Is(keyErr, os.ErrNotExist) && errors.Is(certErr, os.ErrNotExist):
		cert, fp, err := newCertificate()
		if err != nil {
			return nil, "", err
		}
		if err := writeIdentity(dir, cert, fp); err != nil {
			return nil, "", err
		}
		return configFor(cert, alpn), fp, nil
	case keyErr != nil:
		return nil, "", fmt.Errorf("tlsx: the relay's key file cannot be read: %w (the certificate %s is "+
			"present; either restore %s from a backup, or move BOTH files out of %s to have a new "+
			"identity generated -- every client that connected before will then warn that this "+
			"relay's identity changed)", keyErr, certPath, KeyFileName, dir)
	case certErr != nil:
		return nil, "", fmt.Errorf("tlsx: the relay's certificate file cannot be read: %w (the key %s is "+
			"present; either restore %s from a backup, or move BOTH files out of %s to have a new "+
			"identity generated -- every client that connected before will then warn that this "+
			"relay's identity changed)", certErr, keyPath, CertFileName, dir)
	}

	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, "", fmt.Errorf("tlsx: the relay's identity in %s does not load: %w (the key and "+
			"certificate must be the pair that was generated together; restore both from a backup, "+
			"or move both out of the folder to have a new identity generated)", dir, err)
	}
	if len(cert.Certificate) == 0 {
		return nil, "", fmt.Errorf("tlsx: %s holds no certificate", certPath)
	}
	if _, ok := cert.PrivateKey.(ed25519.PrivateKey); !ok {
		return nil, "", fmt.Errorf("tlsx: the key in %s is not the Ed25519 key this relay generates; "+
			"restore the original or move the identity out of the folder", keyPath)
	}
	fp := Fingerprint(cert.Certificate[0])

	if existing, err := os.ReadFile(fpPath); err != nil || strings.TrimSpace(string(existing)) != fp {
		if err := WriteFileAtomic(fpPath, []byte(fp+"\n"), 0o644); err != nil {
			return nil, "", err
		}
	}
	return configFor(cert, alpn), fp, nil
}

// writeIdentity writes the three files for a freshly generated identity.
func writeIdentity(dir string, cert tls.Certificate, fp string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("tlsx: create %s: %w", dir, err)
	}
	priv := cert.PrivateKey.(ed25519.PrivateKey)
	keyDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return fmt.Errorf("tlsx: encode key: %w", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})

	// The key first and most restricted. If the certificate write then fails
	// the loader sees "key present, certificate missing" and refuses to
	// start, which is the wanted outcome for a half-written identity.
	if err := WriteFileAtomic(filepath.Join(dir, KeyFileName), keyPEM, 0o600); err != nil {
		return err
	}
	if err := WriteFileAtomic(filepath.Join(dir, CertFileName), certPEM, 0o644); err != nil {
		return err
	}
	return WriteFileAtomic(filepath.Join(dir, FingerprintFileName), []byte(fp+"\n"), 0o644)
}

// WriteFileAtomic writes data to path through a temporary file in the same
// directory and a rename, so a reader never sees a partial file. The mode is
// applied to the temporary file before it holds a byte. Exported because
// core's known-relays store writes its file the same way, and one atomic
// write in the repo is better than two that can drift.
func WriteFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return fmt.Errorf("tlsx: write %s: %w", path, err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = tmp.Close(); _ = os.Remove(tmpName) }
	if err := tmp.Chmod(mode); err != nil {
		cleanup()
		return fmt.Errorf("tlsx: write %s: %w", path, err)
	}
	if _, err := tmp.Write(data); err != nil {
		cleanup()
		return fmt.Errorf("tlsx: write %s: %w", path, err)
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("tlsx: write %s: %w", path, err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("tlsx: write %s: %w", path, err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("tlsx: write %s: %w", path, err)
	}
	return nil
}
