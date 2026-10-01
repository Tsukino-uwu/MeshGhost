package quicconn

import (
	"errors"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
)

// TestDialHintBlamesTheMachineWhenTheUDPSocketCannotBeCreated uses the Wine/Proton shape: Go turns Wine's
// WSAEOPNOTSUPP from WSAIoctl into a "listen" OpError, and the relay was never contacted.
func TestDialHintBlamesTheMachineWhenTheUDPSocketCannotBeCreated(t *testing.T) {
	err := &net.OpError{
		Op:   "listen",
		Net:  "udp",
		Addr: &net.UDPAddr{IP: net.IPv4zero, Port: 0},
		Err:  &os.SyscallError{Syscall: "wsaioctl", Err: syscall.Errno(10045)},
	}
	hint := dialHint(err)
	if strings.Contains(hint, "is the relay serving quic") {
		t.Fatalf("a local socket failure still blamed the relay: %q", hint)
	}
	if !strings.Contains(hint, "could not create a udp socket") {
		t.Fatalf("hint does not name the real cause: %q", hint)
	}
	if !strings.Contains(hint, "tcp") {
		t.Fatalf("hint does not tell the reader what they get instead: %q", hint)
	}
}

func TestDialHintReachesThroughWrapping(t *testing.T) {
	inner := &net.OpError{Op: "listen", Net: "udp", Err: errors.New("nope")}
	wrapped := errors.Join(errors.New("quicconn: dial x"), inner)
	if strings.Contains(dialHint(wrapped), "is the relay serving quic") {
		t.Fatal("hint did not see the listen failure through wrapping")
	}
}

func TestDialHintStillAsksAboutTheRelayForEverythingElse(t *testing.T) {
	for _, err := range []error{
		errors.New("timeout: no recent network activity"),
		&net.OpError{Op: "read", Net: "udp", Err: errors.New("connection refused")},
	} {
		if !strings.Contains(dialHint(err), "is the relay serving quic") {
			t.Fatalf("lost the relay-side hint for %v", err)
		}
	}
}
