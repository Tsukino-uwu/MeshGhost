package tlsx_test

import (
	"crypto/tls"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// The relay's persisted identity (ADR 0066). Every test here fails against
// the in-memory ServerConfig this replaced: a certificate regenerated per
// process has a new fingerprint every time, which is exactly what a client
// that remembers fingerprints cannot live with.

func load(t *testing.T, dir string) (*tls.Config, string) {
	t.Helper()
	cfg, fp, err := tlsx.LoadOrCreateIdentity(dir, testALPN)
	if err != nil {
		t.Fatalf("LoadOrCreateIdentity(%s): %v", dir, err)
	}
	return cfg, fp
}

func TestAFreshFolderGetsAnIdentityThatIsReusedNextTime(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	_, first := load(t, dir)
	if len(first) != tlsx.FingerprintHexLen {
		t.Fatalf("fingerprint %q is not %d hex digits", first, tlsx.FingerprintHexLen)
	}
	for _, name := range []string{tlsx.KeyFileName, tlsx.CertFileName, tlsx.FingerprintFileName} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s was not written: %v", name, err)
		}
	}
	if got, _ := os.ReadFile(filepath.Join(dir, tlsx.FingerprintFileName)); strings.TrimSpace(string(got)) != first {
		t.Errorf("%s holds %q, want the fingerprint %q", tlsx.FingerprintFileName, got, first)
	}

	// The second "restart": the same identity, not a new one.
	_, second := load(t, dir)
	if second != first {
		t.Fatalf("a restart produced fingerprint %q, the first run had %q -- the identity was regenerated", second, first)
	}
}

// TestALoadedIdentityIsWhatTheListenerServes: the round trip through PEM
// must give a listener whose leaf certificate has the persisted
// fingerprint, or the file is a decoy.
func TestALoadedIdentityIsWhatTheListenerServes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	load(t, dir) // create
	cfg, fp := load(t, dir)

	addr, _ := serveWith(t, cfg)
	c, err := net.DialTimeout("tcp", addr, testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	var seen string
	secure, err := tlsx.Client(c, testALPN, func(leaf []byte) error {
		seen = tlsx.Fingerprint(leaf)
		return nil
	}, testTimeout)
	if err != nil {
		t.Fatalf("handshake: %v", err)
	}
	secure.Close()
	if seen != fp {
		t.Fatalf("the listener served fingerprint %q, the loaded identity says %q", seen, fp)
	}
}

// TestDeletingTheWholeIdentityRegeneratesIt: the documented way to a new
// identity is to move BOTH files out. A new fingerprint follows.
func TestDeletingTheWholeIdentityRegeneratesIt(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	_, first := load(t, dir)
	for _, name := range []string{tlsx.KeyFileName, tlsx.CertFileName, tlsx.FingerprintFileName} {
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			t.Fatalf("remove %s: %v", name, err)
		}
	}
	_, second := load(t, dir)
	if second == first {
		t.Fatal("a deleted identity came back with the same fingerprint")
	}
}

// TestHalfAnIdentityIsFatal: one of the two files missing is never a silent
// regeneration -- that would hide a broken install behind a "new identity"
// warning on every client.
func TestHalfAnIdentityIsFatal(t *testing.T) {
	for _, missing := range []string{tlsx.KeyFileName, tlsx.CertFileName} {
		t.Run("missing "+missing, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "tls")
			load(t, dir)
			if err := os.Remove(filepath.Join(dir, missing)); err != nil {
				t.Fatalf("remove: %v", err)
			}
			if _, _, err := tlsx.LoadOrCreateIdentity(dir, testALPN); err == nil {
				t.Fatalf("with %s missing the identity loaded (or was regenerated); it must be fatal", missing)
			} else if !strings.Contains(err.Error(), missing) {
				t.Fatalf("the error %q does not name the missing file %s", err, missing)
			}
		})
	}
}

// TestACorruptIdentityIsFatal: garbage, and a key that is not the
// certificate's, both refuse.
func TestACorruptIdentityIsFatal(t *testing.T) {
	corrupt := func(t *testing.T, dir, name string, with []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), with, 0o600); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	t.Run("garbage key", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "tls")
		load(t, dir)
		corrupt(t, dir, tlsx.KeyFileName, []byte("not a key\n"))
		if _, _, err := tlsx.LoadOrCreateIdentity(dir, testALPN); err == nil {
			t.Fatal("a garbage key loaded")
		}
	})
	t.Run("garbage certificate", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "tls")
		load(t, dir)
		corrupt(t, dir, tlsx.CertFileName, []byte("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"))
		if _, _, err := tlsx.LoadOrCreateIdentity(dir, testALPN); err == nil {
			t.Fatal("a garbage certificate loaded")
		}
	})
	t.Run("key from another identity", func(t *testing.T) {
		a := filepath.Join(t.TempDir(), "a")
		b := filepath.Join(t.TempDir(), "b")
		load(t, a)
		load(t, b)
		otherKey, err := os.ReadFile(filepath.Join(b, tlsx.KeyFileName))
		if err != nil {
			t.Fatal(err)
		}
		corrupt(t, a, tlsx.KeyFileName, otherKey)
		if _, _, err := tlsx.LoadOrCreateIdentity(a, testALPN); err == nil {
			t.Fatal("a key that does not match the certificate loaded")
		}
	})
}

// TestAWrongFingerprintFileIsRewrittenNotFatal: the fingerprint file is
// derived, for humans; it can never be why a relay fails to start.
func TestAWrongFingerprintFileIsRewrittenNotFatal(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	_, fp := load(t, dir)
	if err := os.WriteFile(filepath.Join(dir, tlsx.FingerprintFileName), []byte("stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, again := load(t, dir)
	if again != fp {
		t.Fatalf("fingerprint changed to %q from %q because of a stale fingerprint file", again, fp)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, tlsx.FingerprintFileName)); strings.TrimSpace(string(got)) != fp {
		t.Fatalf("%s still holds %q after a load; want it rewritten to %q", tlsx.FingerprintFileName, got, fp)
	}
	if err := os.Remove(filepath.Join(dir, tlsx.FingerprintFileName)); err != nil {
		t.Fatal(err)
	}
	load(t, dir)
	if _, err := os.Stat(filepath.Join(dir, tlsx.FingerprintFileName)); err != nil {
		t.Fatalf("a missing fingerprint file was not recreated: %v", err)
	}
}

// TestTheKeyIsPrivate: 0600 where the OS has modes. Windows has ACLs
// instead, and Go's Chmod there touches only the read-only bit, so the
// assertion is skipped rather than faked.
func TestTheKeyIsPrivate(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("file modes are not a thing on Windows; the key's mode is asserted on POSIX in CI")
	}
	dir := filepath.Join(t.TempDir(), "tls")
	load(t, dir)
	fi, err := os.Stat(filepath.Join(dir, tlsx.KeyFileName))
	if err != nil {
		t.Fatal(err)
	}
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Fatalf("%s has mode %o, want 0600", tlsx.KeyFileName, got)
	}
}

// TestNoTemporaryFileIsLeftBehind: the atomic write cleans up after itself,
// so a tls/ folder never accumulates .tmp files a host would wonder about.
func TestNoTemporaryFileIsLeftBehind(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	load(t, dir)
	load(t, dir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("temporary file %s left in the identity folder", e.Name())
		}
	}
	if len(entries) != 3 {
		t.Fatalf("%d entries in the identity folder, want exactly the three files", len(entries))
	}
}
