package netx

import (
	"fmt"
	"net"
	"testing"
	"time"
)

// TestParseKindRejectsATypo: a mistyped transport must stop the binary. Kind's zero value is TCP, so a lenient parser
// would turn "quik" into tcp with no message anywhere.
func TestParseKindRejectsATypo(t *testing.T) {
	for _, bad := range []string{"quik", "tcp/udp", "", "  ", "sctp"} {
		if _, err := ParseKind(bad); err == nil {
			t.Errorf("ParseKind(%q) succeeded, want an error", bad)
		}
	}
}

func TestParseKindAcceptsEveryTransport(t *testing.T) {
	// "udp" is the dev build's alone; a release refuses it (udp_release_test.go).
	for in, want := range map[string]Kind{
		"tcp": TCP, "quic": QUIC,
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

// TestParseKindsPreservesOrderAndDropsDuplicates: order matters only for the startup log, but a duplicate would be
// two listeners racing for one port.
func TestParseKindsPreservesOrderAndDropsDuplicates(t *testing.T) {
	got, err := ParseKinds("quic, tcp ,quic,tcp")
	if err != nil {
		t.Fatalf("ParseKinds: %v", err)
	}
	want := []Kind{QUIC, TCP}
	if len(got) != len(want) {
		t.Fatalf("ParseKinds gave %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("ParseKinds gave %v, want %v", got, want)
		}
	}
}

func TestParseKindsRejectsAnEmptyList(t *testing.T) {
	for _, bad := range []string{"", "   ", ",", " , , "} {
		if _, err := ParseKinds(bad); err == nil {
			t.Errorf("ParseKinds(%q) succeeded, want an error", bad)
		}
	}
}

// TestTCPListenAndDialRoundTrip is the seam's smoke test: what Listen and Dial return must behave as the
// net.Listener and net.Conn that relay and transport consume.
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

// TestTCPAndUDPShareAPortNumber: TCP and UDP have independent port spaces, so serving tcp and quic (over UDP) costs
// one port number, not two.
//
// Windows reserves scattered UDP ranges (Hyper-V, WinNAT) and hands out ephemeral ports in order, so one draw can
// land in a reserved block; the test retries, letting each side pick the port in turn. A retry keeps the assertion as
// strong: if the port spaces were not independent, every attempt would fail.
func TestTCPAndUDPShareAPortNumber(t *testing.T) {
	const attempts = 40
	var lastErr error

	for i := 0; i < attempts; i++ {
		first, second := TCP, QUIC
		if i%2 == 1 {
			first, second = QUIC, TCP
		}
		firstLn, err := Listen(first, "127.0.0.1:0")
		if err != nil {
			t.Fatalf("%s listen: %v", first, err)
		}

		_, port, err := net.SplitHostPort(firstLn.Addr().String())
		if err != nil {
			firstLn.Close()
			t.Fatalf("split host/port: %v", err)
		}

		secondLn, err := Listen(second, net.JoinHostPort("127.0.0.1", port))
		if err != nil {
			// Almost certainly an OS-reserved range.
			lastErr = fmt.Errorf("port %s (%s first): %w", port, first, err)
			firstLn.Close()
			continue
		}

		got, want := secondLn.Addr().String(), firstLn.Addr().String()
		secondLn.Close()
		firstLn.Close()

		if got != want {
			t.Fatalf("%s bound %s, want the same address as %s (%s)", second, got, first, want)
		}
		return // the claim holds: one port number served both.
	}

	t.Fatalf("no port in %d attempts could be bound on both tcp and udp; last: %v — "+
		"if this is every port rather than an unlucky few, tcp and udp are not sharing a "+
		"port space and the relay's one-port scheme is broken", attempts, lastErr)
}

// TestParseKindsAlwaysIncludesTCP: every client handshakes over tcp before moving to its configured transport, so a
// relay serving only quic would be unreachable by everyone.
func TestParseKindsAlwaysIncludesTCP(t *testing.T) {
	for _, in := range []string{"quic", "quic,quic"} {
		got, err := ParseKinds(in)
		if err != nil {
			t.Errorf("ParseKinds(%q): %v", in, err)
			continue
		}
		if len(got) == 0 || got[0] != TCP {
			t.Errorf("ParseKinds(%q) = %v, want tcp first — a relay without tcp is unreachable", in, got)
		}
	}
	// Naming it explicitly must not duplicate the listener.
	got, err := ParseKinds("tcp,quic,tcp")
	if err != nil {
		t.Fatalf("ParseKinds: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ParseKinds(\"tcp,quic,tcp\") = %v, want exactly [tcp quic]", got)
	}
}
