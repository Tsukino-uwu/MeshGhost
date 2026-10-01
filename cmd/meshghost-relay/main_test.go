package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// writeConfig writes prefix and body to a temp config.json and returns its path; prefix lets a test put a byte-order
// mark in front of the JSON.
func writeConfig(t *testing.T, prefix []byte, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, append(prefix, []byte(body)...), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

const testServerConfig = `{"server": {"listen_on": "1.2.3.4:9999", "only_game": "pseudoregalia"}}`

// applyTestConfig runs applyFileConfig over path with no flags marked explicit, returning listen_on and only_game.
func applyTestConfig(path string) (addr, onlyGame string) {
	addr, onlyGame, _, _ = applyTestConfigFull(path)
	return addr, onlyGame
}

// applyTestConfigFull is applyTestConfig plus the transport keys. It passes every configTargets field: a nil target
// is a nil dereference the moment a config file sets its key.
func applyTestConfigFull(path string) (addr, onlyGame, transport, quicAddr string) {
	addr, onlyGame, transport, quicAddr, _ = applyTestConfigWithTLS(path)
	return addr, onlyGame, transport, quicAddr
}

// applyTestConfigWithTLS is applyTestConfigFull plus the obsolete tls key, still read so checkLegacyTLSKey can judge
// it.
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

// TestConfigWithUTF8BOMIsStillRead: a Windows editor may prepend a UTF-8 BOM, which encoding/json refuses, and a
// file discarded for it would silently fall back to defaults, room_code included.
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

func TestConfigWithoutBOMIsUnaffected(t *testing.T) {
	path := writeConfig(t, nil, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "1.2.3.4:9999" || onlyGame != "pseudoregalia" {
		t.Errorf("listen_on = %q, only_game = %q, want the plain file read normally", addr, onlyGame)
	}
}

// TestUTF16ConfigLeavesDefaults: a UTF-16 file cannot be salvaged by stripping a prefix, so every target keeps its
// flag default.
func TestUTF16ConfigLeavesDefaults(t *testing.T) {
	path := writeConfig(t, []byte{0xFF, 0xFE}, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "" || onlyGame != "" {
		t.Errorf("listen_on = %q, only_game = %q, want both left at their defaults", addr, onlyGame)
	}
}

// TestTransportKeysAreReadFromConfig: transport and listen_quic both reach their targets; dropping listen_quic would
// bind quic where nobody dials.
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

// TestTransportAbsentFromConfigLeavesTheFlagDefaults: an older config.json with neither key leaves the flag defaults.
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

// TestEmptyConfigFileIsSilentlyIgnored: an empty file means nothing was configured. On Windows -config nul reads as a
// file of zero bytes, not as a missing one.
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

// TestTheObsoleteTLSKeyIsStillReadSoItCanBeJudged: an old config.json still carries the key, and a value that asked
// for plaintext must reach checkLegacyTLSKey rather than vanish as unknown.
func TestTheObsoleteTLSKeyIsStillReadSoItCanBeJudged(t *testing.T) {
	path := writeConfig(t, nil, `{"server": {"tls": "off"}}`)
	_, _, _, _, legacy := applyTestConfigWithTLS(path)
	if legacy != "off" {
		t.Fatalf("tls = %q, want the obsolete value read so it can be refused", legacy)
	}
}

// TestTheObsoleteTLSKeyIsJudgedByWhatItAskedFor: plaintext modes refuse to start, "required" runs with a note,
// absent is silent, and a value the key never had is an error too.
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

// TestResolveQuicAddr: a relay that quietly relocated quic would advertise a port the host never forwarded, which
// surfaces much later as quic clients unable to connect.
func TestResolveQuicAddr(t *testing.T) {
	const addr = "0.0.0.0:7777"

	t.Run("quic shares addr's port by default", func(t *testing.T) {
		// Hosting means forwarding one port number.
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP, netx.QUIC}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != addr {
			t.Fatalf("got %q, want %q -- quic should share -addr's port", got, addr)
		}
	})

	t.Run("quic KEEPS the shared port when udp is served too", func(t *testing.T) {
		// quic is a default transport and plain udp is opt-in, so udp is the one that moves.
		got, err := resolveQuicAddr([]netx.Kind{netx.TCP, netx.UDP, netx.QUIC}, addr, sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != addr {
			t.Fatalf("got %q, want %q -- quic keeps -addr's port and udp is the one that moves", got, addr)
		}
	})

	t.Run("an explicit listen-quic settles it, even alongside udp", func(t *testing.T) {
		// Naming a port is taking responsibility for forwarding it.
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

// TestServerSectionIsFoundCaseInsensitively: the unknown-key check looks at the section encoding/json decoded, and
// the decoder matches "Server" too.
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

// TestListeningLineNamesTheAddressFamily: a wildcard bind is a dual-stack socket on the OSes that ship this relay,
// and a host's firewall rule is per family.
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
	// No real wildcard bind: every compile is a new executable, and Windows Firewall prompts for each one that opens
	// 0.0.0.0. The note is a pure function of the reported address, which the cases above cover.
}

// TestConfigIsFoundInTheWorkingDirectoryFirstThenBesideTheExecutable: a relay run as a service has a working
// directory that is not its own folder.
func TestConfigIsFoundInTheWorkingDirectoryFirstThenBesideTheExecutable(t *testing.T) {
	exeDir := t.TempDir()
	exe := func() (string, error) { return exeDir, nil }
	// logPath reads the package-level lookup when no config was found.
	prevExe := executableDir
	executableDir = exe
	t.Cleanup(func() { executableDir = prevExe })
	cwd := t.TempDir()
	// A test cannot change the working directory portably, so that file is named by an absolute path.
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
