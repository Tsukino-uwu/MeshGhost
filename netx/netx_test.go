package netx

import (
	"net"
	"testing"
	"time"
)

// TestParseKindRejectsATypo is the point of ParseKind being strict. A
// mistyped transport must stop the binary, not silently fall back to TCP:
// an operator who wrote "quik" expecting an encrypted transport and got an
// unencrypted one instead, with no message anywhere, is the exact failure
// agent_docs/risks.md already records for a stale binary ignoring
// room_code. Kind's zero value is TCP, so a lenient parser would produce
// precisely that.
func TestParseKindRejectsATypo(t *testing.T) {
	for _, bad := range []string{"quik", "tcp/udp", "", "  ", "sctp"} {
		if _, err := ParseKind(bad); err == nil {
			t.Errorf("ParseKind(%q) succeeded, want an error", bad)
		}
	}
}

func TestParseKindAcceptsEveryTransport(t *testing.T) {
	for in, want := range map[string]Kind{
		"tcp": TCP, "udp": UDP, "quic": QUIC,
		"TCP": TCP, " quic ": QUIC,
	} {
		got, err := ParseKind(in)
		if err != nil {
			t.Errorf("ParseKind(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("ParseKind(%q) = %v, want %v", in, got, want)
		}
	}
}

// TestParseKindsPreservesOrderAndDropsDuplicates covers the relay's
// multi-transport list. Order matters only for the startup log's
// readability, but duplicates must not produce two listeners racing for the
// same port.
func TestParseKindsPreservesOrderAndDropsDuplicates(t *testing.T) {
	got, err := ParseKinds("quic, tcp ,udp,tcp")
	if err != nil {
		t.Fatalf("ParseKinds: %v", err)
	}
	want := []Kind{QUIC, TCP, UDP}
	if len(got) != len(want) {
		t.Fatalf("ParseKinds gave %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("ParseKinds gave %v, want %v", got, want)
		}
	}
}

// TestParseKindsRejectsAnEmptyList confirms a relay configured with no
// transport refuses to start rather than defaulting to something the
// operator did not ask for.
func TestParseKindsRejectsAnEmptyList(t *testing.T) {
	for _, bad := range []string{"", "   ", ",", " , , "} {
		if _, err := ParseKinds(bad); err == nil {
			t.Errorf("ParseKinds(%q) succeeded, want an error", bad)
		}
	}
}

// TestTCPListenAndDialRoundTrip is the seam's own smoke test: whatever
// Listen and Dial return has to behave like the net.Listener/net.Conn pair
// the rest of the codebase already expects, because relay and
// transport consume them as exactly that.
func TestTCPListenAndDialRoundTrip(t *testing.T) {
	ln, err := Listen(TCP, "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		accepted <- c
	}()

	client, err := Dial(TCP, ln.Addr().String(), 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	var server net.Conn
	select {
	case server = <-accepted:
		defer server.Close()
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for Accept")
	}

	if _, err := client.Write([]byte("ping\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 5)
	if err := server.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	if _, err := server.Read(buf); err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(buf) != "ping\n" {
		t.Fatalf("read %q, want %q", buf, "ping\n")
	}
}

// TestTCPAndUDPShareAPortNumber pins the fact the relay's port scheme rests
// on: TCP and UDP have independent port spaces, so serving both transports
// costs one port number, not two. QUIC is the exception — it is carried
// over UDP, so it collides with the plain udp transport and gets its own
// port (cmd/meshghost-relay's DefaultQuicAddr).
//
// Verified here rather than asserted in a comment, because if it were ever
// false the relay would fail to start in its shipped tcp,udp configuration
// and the reason would not be obvious from the error.
func TestTCPAndUDPShareAPortNumber(t *testing.T) {
	tcpLn, err := Listen(TCP, "127.0.0.1:0")
	if err != nil {
		t.Fatalf("tcp listen: %v", err)
	}
	defer tcpLn.Close()

	_, port, err := net.SplitHostPort(tcpLn.Addr().String())
	if err != nil {
		t.Fatalf("split host/port: %v", err)
	}

	udpLn, err := Listen(UDP, net.JoinHostPort("127.0.0.1", port))
	if err != nil {
		t.Fatalf("udp listen on the same port %s as tcp: %v", port, err)
	}
	defer udpLn.Close()

	if got := udpLn.Addr().String(); got != tcpLn.Addr().String() {
		t.Fatalf("udp bound %s, want the same address as tcp (%s)", got, tcpLn.Addr())
	}
}

// TestParseKindsAlwaysIncludesTCP pins the rule that keeps a relay
// reachable. Every client handshakes over tcp before moving to its
// configured transport, so a relay serving only udp or only quic would be
// unreachable by everyone — including clients configured for exactly the
// transport it does serve.
//
// Found by internal/e2e when a udp-only relay stopped being connectable,
// after every package-level test still passed. Pinned here so the rule
// cannot be quietly dropped.
func TestParseKindsAlwaysIncludesTCP(t *testing.T) {
	for _, in := range []string{"udp", "quic", "udp,quic", "quic,udp"} {
		got, err := ParseKinds(in)
		if err != nil {
			t.Errorf("ParseKinds(%q): %v", in, err)
			continue
		}
		if len(got) == 0 || got[0] != TCP {
			t.Errorf("ParseKinds(%q) = %v, want tcp first — a relay without tcp is unreachable", in, got)
		}
	}
	// And naming it explicitly must not duplicate the listener.
	got, err := ParseKinds("tcp,udp,tcp")
	if err != nil {
		t.Fatalf("ParseKinds: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ParseKinds(\"tcp,udp,tcp\") = %v, want exactly [tcp udp]", got)
	}
}

// TestAutoNeverPrefersUDPOverQUIC pins the ordering that keeps an automatic
// choice from being a silent security downgrade: udp and quic behave the
// same under packet loss, but udp cannot be encrypted at all, so nothing
// should pick it on a user's behalf while quic is available.
func TestAutoNeverPrefersUDPOverQUIC(t *testing.T) {
	quicAt, udpAt := -1, -1
	for i, k := range AutoPreference {
		switch k {
		case QUIC:
			quicAt = i
		case UDP:
			udpAt = i
		}
	}
	if quicAt < 0 || udpAt < 0 {
		t.Fatalf("AutoPreference = %v, want it to rank both quic and udp", AutoPreference)
	}
	if udpAt < quicAt {
		t.Errorf("AutoPreference ranks udp (%d) above quic (%d) — auto would silently choose an "+
			"unencryptable transport over an encrypted one", udpAt, quicAt)
	}
	if AutoPreference[len(AutoPreference)-1] != UDP {
		t.Errorf("AutoPreference = %v, want udp last", AutoPreference)
	}
}
