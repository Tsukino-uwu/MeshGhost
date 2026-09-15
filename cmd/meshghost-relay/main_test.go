package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// writeConfig writes body to a temp config.json and returns its path, with
// prefix prepended raw so a test can put a byte-order mark (or anything else
// an editor might leave) in front of the JSON.
func writeConfig(t *testing.T, prefix []byte, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, append(prefix, []byte(body)...), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

const testServerConfig = `{"server": {"listen_on": "1.2.3.4:9999", "only_game": "pseudoregalia"}}`

// applyTestConfig runs applyFileConfig over path with no flags marked
// explicit, returning the resulting listen address and only_game.
func applyTestConfig(path string) (addr, onlyGame string) {
	addr, onlyGame, _, _ = applyTestConfigFull(path)
	return addr, onlyGame
}

// applyTestConfigFull is applyTestConfig plus the transport keys, and it
// passes EVERY configTargets field. Passing all of them is not tidiness: a
// nil target is a nil dereference the moment a config file sets the
// corresponding key, so a partially-populated struct here would turn a real
// crash into a test that passes by never exercising the field.
func applyTestConfigFull(path string) (addr, onlyGame, transport, quicAddr string) {
	addr, onlyGame, transport, quicAddr, _ = applyTestConfigWithTLS(path)
	return addr, onlyGame, transport, quicAddr
}

// applyTestConfigWithTLS is applyTestConfigFull plus the obsolete tls key,
// which is still read so checkLegacyTLSKey can judge it.
func applyTestConfigWithTLS(path string) (addr, onlyGame, transport, quicAddr, legacyTLS string) {
	var maxClients, sendHz, resumeGrace int
	var roomCode, udpAddr, ghostCollision string
	var qlog bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		addr: &addr, roomCode: &roomCode, onlyGame: &onlyGame,
		maxClients: &maxClients, sendHz: &sendHz, resumeGrace: &resumeGrace,
		transport: &transport, quicAddr: &quicAddr, udpAddr: &udpAddr, legacyTLS: &legacyTLS,
		ghostCollision: &ghostCollision, qlog: &qlog,
	})
	return addr, onlyGame, transport, quicAddr, legacyTLS
}

// TestConfigWithUTF8BOMIsStillRead is the regression test for a config file
// saved by a Windows editor that prepends a UTF-8 BOM: encoding/json refuses
// those three bytes, which used to discard the whole file — silently falling
// back to defaults for every setting in it, including room_code, while
// looking perfectly correct to whoever edited it. Found while testing the
// only_game setting.
func TestConfigWithUTF8BOMIsStillRead(t *testing.T) {
	path := writeConfig(t, []byte{0xEF, 0xBB, 0xBF}, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "1.2.3.4:9999" {
		t.Errorf("listen_on = %q, want it read through the BOM", addr)
	}
	if onlyGame != "pseudoregalia" {
		t.Errorf("only_game = %q, want it read through the BOM", onlyGame)
	}
}

// TestConfigWithoutBOMIsUnaffected confirms the BOM strip didn't change the
// ordinary case.
func TestConfigWithoutBOMIsUnaffected(t *testing.T) {
	path := writeConfig(t, nil, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "1.2.3.4:9999" || onlyGame != "pseudoregalia" {
		t.Errorf("listen_on = %q, only_game = %q, want the plain file read normally", addr, onlyGame)
	}
}

// TestUTF16ConfigLeavesDefaults confirms a UTF-16 file is refused rather than
// half-read: it can't be salvaged by stripping a prefix, so applyFileConfig
// must leave every target untouched (the caller's flag defaults) instead of
// writing garbage into them.
func TestUTF16ConfigLeavesDefaults(t *testing.T) {
	path := writeConfig(t, []byte{0xFF, 0xFE}, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "" || onlyGame != "" {
		t.Errorf("listen_on = %q, only_game = %q, want both left at their defaults", addr, onlyGame)
	}
}

// TestTransportKeysAreReadFromConfig confirms both new server keys reach
// their flag targets. listen_quic matters as much as transport: quic runs
// over udp and so cannot share a port with the plain udp transport, which
// means a relay serving both needs two addresses and silently dropping one
// of them would bind quic somewhere nobody is dialing.
func TestTransportKeysAreReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"server":{"listen_on":"0.0.0.0:7777",`+
		`"listen_quic":"0.0.0.0:7780","transport":"tcp,udp,quic"}}`)
	addr, _, transport, quicAddr := applyTestConfigFull(path)
	if transport != "tcp,udp,quic" {
		t.Errorf("transport = %q, want %q", transport, "tcp,udp,quic")
	}
	if quicAddr != "0.0.0.0:7780" {
		t.Errorf("listen_quic = %q, want %q", quicAddr, "0.0.0.0:7780")
	}
	if addr != "0.0.0.0:7777" {
		t.Errorf("listen_on = %q, want %q", addr, "0.0.0.0:7777")
	}
}

// TestTransportAbsentFromConfigLeavesTheFlagDefaults is the compatibility
// half: a config.json written before selectable transports existed has
// neither key, and such a relay must keep serving tcp exactly as it did.
func TestTransportAbsentFromConfigLeavesTheFlagDefaults(t *testing.T) {
	path := writeConfig(t, nil, `{"server":{"listen_on":"0.0.0.0:7777"}}`)
	transport, quicAddr := "tcp", sharesAddrPort
	var addr, onlyGame, roomCode string
	var maxClients, sendHz int
	applyFileConfig(path, map[string]bool{}, configTargets{
		addr: &addr, roomCode: &roomCode, onlyGame: &onlyGame,
		maxClients: &maxClients, sendHz: &sendHz,
		transport: &transport, quicAddr: &quicAddr,
	})
	if transport != "tcp" {
		t.Errorf("transport = %q, want it left at the flag default %q", transport, "tcp")
	}
	if quicAddr != sharesAddrPort {
		t.Errorf("listen_quic = %q, want it left at the flag default (empty = share -addr's port)", quicAddr)
	}
}

// TestEmptyConfigFileIsSilentlyIgnored covers "no config" spelled as a file
// that exists and holds nothing.
//
// dev-scripts/run-loadtest-relay.bat passes `-config nul` to mean "ignore the
// repo's config.json". On Windows os.ReadFile("nul") does not fail
// os.IsNotExist -- it succeeds with zero bytes -- so this reached
// json.Unmarshal, which returned "unexpected end of JSON input", and the relay
// warned on every run that EVERY SETTING was being ignored and defaults used
// instead. The relay was working correctly; the warning read like a broken
// install. An empty file means nothing was configured, which is not an error.
func TestEmptyConfigFileIsSilentlyIgnored(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{"completely empty", ""},
		{"only whitespace", "\n\n   \t\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := writeConfig(t, nil, tc.body)

			addr, onlyGame, transport, quicAddr := applyTestConfigFull(path)
			for field, got := range map[string]string{
				"listen_on": addr, "only_game": onlyGame,
				"transport": transport, "listen_quic": quicAddr,
			} {
				if got != "" {
					t.Errorf("%s = %q, want the flag default left untouched", field, got)
				}
			}
		})
	}
}

// TestTheObsoleteTLSKeyIsStillReadSoItCanBeJudged: the key is gone from
// the flags, but an old config.json still carries it, and a value that asked
// for plaintext must reach checkLegacyTLSKey rather than vanish as unknown.
func TestTheObsoleteTLSKeyIsStillReadSoItCanBeJudged(t *testing.T) {
	path := writeConfig(t, nil, `{"server": {"tls": "off"}}`)
	_, _, _, _, legacy := applyTestConfigWithTLS(path)
	if legacy != "off" {
		t.Fatalf("tls = %q, want the obsolete value read so it can be refused", legacy)
	}
}

// TestTheObsoleteTLSKeyIsJudgedByWhatItAskedFor: plaintext modes refuse to
// start, "required" runs with a note, absent is silent, and a value the key
// never had is an error too.
func TestTheObsoleteTLSKeyIsJudgedByWhatItAskedFor(t *testing.T) {
	for _, tc := range []struct {
		value    string
		wantErr  bool
		wantNote bool
	}{
		{"", false, false},
		{"required", false, true},
		{"on", false, true},
		{"TRUE", false, true},
		{"off", true, false},
		{"auto", true, false},
		{"false", true, false},
		{"no", true, false},
		{"requried", true, false},
	} {
		note, err := checkLegacyTLSKey(tc.value)
		if (err != nil) != tc.wantErr {
			t.Errorf("tls=%q: err=%v, want error=%v", tc.value, err, tc.wantErr)
		}
		if (note != "") != tc.wantNote {
			t.Errorf("tls=%q: note=%q, want note=%v", tc.value, note, tc.wantNote)
		}
		if err != nil && !strings.Contains(err.Error(), "2026-09-15") {
			t.Errorf("tls=%q: the error does not say since when: %v", tc.value, err)
		}
	}
}

// TestTLSAbsentFromConfigLeavesTheTargetAlone: an existing config file with
// no "tls" key leaves the legacy target untouched.
func TestTLSAbsentFromConfigLeavesTheTargetAlone(t *testing.T) {
	path := writeConfig(t, nil, testServerConfig)
	tlsMode := ""
	var addr, onlyGame, roomCode, transport, quicAddr string
	var maxClients, sendHz, resumeGrace int
	applyFileConfig(path, map[string]bool{}, configTargets{
		addr: &addr, roomCode: &roomCode, onlyGame: &onlyGame,
		maxClients: &maxClients, sendHz: &sendHz, resumeGrace: &resumeGrace,
		transport: &transport, quicAddr: &quicAddr, legacyTLS: &tlsMode,
	})
	if tlsMode != "" {
		t.Fatalf("tls = %q, want the target left alone", tlsMode)
	}
}

// TestResolveQuicAddr covers where quic listens, which is the one startup
// decision with a refusal in it.
//
// It was five nested conditions and a log.Fatalf inside main() until 2026-08-25,
// so nothing could reach it except internal/e2e spawning a real process -- and
// e2e cannot easily assert the refusal, because the refusal IS the process
// exiting. The rule matters because getting it wrong is silent in the worst
// direction: a relay that quietly relocated quic would advertise a port the host
// never forwarded, and that surfaces much later as "quic clients cannot connect"
// with nothing pointing back at startup.
func TestResolveQuicAddr(t *testing.T) {
	const addr = "0.0.0.0:7777"

	t.Run("quic shares addr's port by default", func(t *testing.T) {
		// The whole point: hosting means forwarding ONE port number.
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP, netx.QUIC}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != addr {
			t.Fatalf("got %q, want %q -- quic should share -addr's port", got, addr)
		}
	})

	t.Run("quic KEEPS the shared port when udp is served too", func(t *testing.T) {
		// Corrected 2026-08-27. This used to refuse and demand a port for quic,
		// which had it backwards: quic is a DEFAULT transport and plain udp is
		// opt-in, so making the default one surrender the shared number broke
		// "forward 7777" for the common case to accommodate the rare one. udp
		// moves instead -- see TestResolveUDPAddr.
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP, netx.UDP, netx.QUIC}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != addr {
			t.Fatalf("got %q, want %q -- quic keeps -addr's port and udp is the one that moves", got, addr)
		}
	})

	t.Run("an explicit listen-quic settles it, even alongside udp", func(t *testing.T) {
		// Naming a port is the operator taking responsibility for forwarding it.
		const explicit = "0.0.0.0:7780"
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP, netx.UDP, netx.QUIC}, addr, explicit)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != explicit {
			t.Fatalf("got %q, want %q", got, explicit)
		}
	})

	t.Run("udp without quic is fine and shares nothing", func(t *testing.T) {
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP, netx.UDP}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != sharesAddrPort {
			t.Fatalf("got %q, want it untouched -- quic is not being served", got)
		}
	})

	t.Run("tcp only leaves listen-quic alone", func(t *testing.T) {
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP}, addr, "0.0.0.0:9999")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "0.0.0.0:9999" {
			t.Fatalf("got %q, want it passed through unvalidated", got)
		}
	})

}

// TestServerSectionIsFoundCaseInsensitively: the unknown-key check looks at
// the section encoding/json decoded, and the decoder matches "Server" (B7).
func TestServerSectionIsFoundCaseInsensitively(t *testing.T) {
	for _, in := range []string{`{"server":{"a":1}}`, `{"Server":{"a":1}}`, `{"SERVER":{"a":1}}`} {
		if got := serverSection([]byte(in)); string(got) != `{"a":1}` {
			t.Errorf("serverSection(%s) = %q, want the section", in, got)
		}
	}
	if got := serverSection([]byte(`{"client":{}}`)); got != nil {
		t.Errorf("serverSection found %q in a file with no server section", got)
	}
}

// TestListeningLineNamesTheAddressFamily is finding B1: a wildcard bind is a
// dual-stack socket on the OSes that ship this relay, and the line has to say
// so, because the firewall rule a host writes is per family.
func TestListeningLineNamesTheAddressFamily(t *testing.T) {
	mustTCP := func(s string) net.Addr {
		a, err := net.ResolveTCPAddr("tcp", s)
		if err != nil {
			t.Fatalf("resolve %s: %v", s, err)
		}
		return a
	}
	for _, tc := range []struct {
		addr net.Addr
		want string
	}{
		{mustTCP("[::]:7777"), "IPv6 AND IPv4"},
		{mustTCP("0.0.0.0:7777"), "every IPv4 address"},
		{mustTCP("127.0.0.1:7777"), ""},
		{mustTCP("203.0.113.9:7777"), ""},
	} {
		got := listeningLine(tc.addr, "tcp")
		if tc.want == "" {
			if strings.Contains(got, "every") {
				t.Errorf("%s: a specific address got a family note: %q", tc.addr, got)
			}
			continue
		}
		if !strings.Contains(got, tc.want) {
			t.Errorf("%s: %q does not say %q", tc.addr, got, tc.want)
		}
	}
	// Deliberately NO real wildcard bind here: a test binary opening 0.0.0.0
	// is a new executable every compile, and Windows Firewall asks about each
	// one -- a prompt on the user's screen per test run (seen 2026-09-15).
	// The family note is a pure function of the address the OS reports, and
	// the synthetic addresses above cover both shapes it can report.
}

// TestConfigIsFoundInTheWorkingDirectoryFirstThenBesideTheExecutable is
// finding B2: a relay run as a service has a working directory that is not
// its own folder, and until 2026-09-15 it read no file and said nothing.
func TestConfigIsFoundInTheWorkingDirectoryFirstThenBesideTheExecutable(t *testing.T) {
	exeDir := t.TempDir()
	exe := func() (string, error) { return exeDir, nil }
	// logPath reads the package-level lookup when no config was found; point
	// it at the same directory for this test's life.
	prevExe := executableDir
	executableDir = exe
	t.Cleanup(func() { executableDir = prevExe })
	cwd := t.TempDir()
	// A relative flag value is resolved against the process working directory,
	// which a test cannot change portably -- so the "working directory" file is
	// named by an absolute path the way os.Stat would see it from cwd.
	inCwd := filepath.Join(cwd, "config.json")

	t.Run("neither exists: both places named, nothing read", func(t *testing.T) {
		got := resolveConfigPath(inCwd, false, exe)
		if got.found {
			t.Fatalf("found = true with no file anywhere: %+v", got)
		}
		if !strings.Contains(got.note, "no config file at") || !strings.Contains(got.note, inCwd) {
			t.Fatalf("the note does not say where it looked: %q", got.note)
		}
		// An absolute flag value is not re-based beside the executable.
		if strings.Contains(got.note, exeDir) {
			t.Fatalf("an absolute -config default was re-based beside the executable: %q", got.note)
		}
		if lp := got.logPath("meshghost-server.log"); filepath.Dir(lp) != exeDir {
			t.Fatalf("with no config the log went to %s, want beside the executable %s", lp, exeDir)
		}
	})

	t.Run("beside the executable when the working directory has none", func(t *testing.T) {
		beside := filepath.Join(exeDir, "config.json")
		if err := os.WriteFile(beside, []byte(`{"server":{}}`), 0o600); err != nil {
			t.Fatal(err)
		}
		defer os.Remove(beside)
		got := resolveConfigPath("config.json", false, exe)
		if !got.found || got.path != beside {
			t.Fatalf("got %+v, want the file beside the executable", got)
		}
		if !strings.Contains(got.note, "beside the executable") {
			t.Fatalf("the note does not say the file came from beside the executable: %q", got.note)
		}
		if lp := got.logPath("meshghost-server.log"); filepath.Dir(lp) != exeDir {
			t.Fatalf("the log went to %s, want beside the config in %s", lp, exeDir)
		}
	})

	t.Run("the working directory wins when both exist", func(t *testing.T) {
		if err := os.WriteFile(inCwd, []byte(`{"server":{}}`), 0o600); err != nil {
			t.Fatal(err)
		}
		beside := filepath.Join(exeDir, "config.json")
		if err := os.WriteFile(beside, []byte(`{"server":{}}`), 0o600); err != nil {
			t.Fatal(err)
		}
		got := resolveConfigPath(inCwd, false, exe)
		if !got.found || got.path != inCwd {
			t.Fatalf("got %+v, want the working-directory file", got)
		}
		if lp := got.logPath("meshghost-server.log"); filepath.Dir(lp) != cwd {
			t.Fatalf("the log went to %s, want beside the config in %s", lp, cwd)
		}
	})

	t.Run("an explicit -config is believed and named", func(t *testing.T) {
		got := resolveConfigPath(filepath.Join(cwd, "missing.json"), true, exe)
		if got.found || !strings.Contains(got.note, "given by -config") {
			t.Fatalf("got %+v", got)
		}
	})
}
