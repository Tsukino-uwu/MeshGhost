package quicconn

import (
	"errors"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
)

// A dial that failed because the LOCAL udp socket could not be created must not
// ask the reader whether the relay serves quic -- the relay was never contacted.
//
// This is the Wine/Proton shape exactly: quic.DialAddr calls net.ListenUDP first
// and returns its error unwrapped, and Go's netFD.init turns Wine's
// WSAEOPNOTSUPP ("winapi error #10045") from WSAIoctl into a "listen" OpError.
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

// Still wrapped in fmt.Errorf %w, so errors.As must reach through the wrapping
// the real Dial applies.
func TestDialHintReachesThroughWrapping(t *testing.T) {
	inner := &net.OpError{Op: "listen", Net: "udp", Err: errors.New("nope")}
	wrapped := errors.Join(errors.New("quicconn: dial x"), inner)
	if strings.Contains(dialHint(wrapped), "is the relay serving quic") {
		t.Fatal("hint did not see the listen failure through wrapping")
	}
}

// Every OTHER failure had a working socket, so the relay-side question is the
// right one and must survive.
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
