package core

import (
	"errors"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAnAdapterFloorRefusesAnOlderRelay: an adapter may depend on a field an older relay never forwards, which the
// build's own floor cannot know; without a floor of its own it connects and quietly lacks what it was written for.
func TestAnAdapterFloorRefusesAnOlderRelay(t *testing.T) {
	c := New()
	// One above what this build speaks: too old for this adapter, not for the build.
	c.mu.Lock()
	c.adapterMinProtocol = protocol.Version + 1
	c.mu.Unlock()

	rejErr := c.refuseWelcomeVersion(protocol.Welcome{
		PlayerID:        "p1",
		ProtocolVersion: protocol.Version,
	})
	if rejErr == nil {
		t.Fatal("a relay below the adapter's declared floor was accepted -- the adapter then " +
			"renders with whatever the older relay forwards and nothing says the feature it " +
			"was built for is missing")
	}
	var rej *RejectError
	if !errors.As(error(rejErr), &rej) {
		t.Fatalf("refusal came back as %T, want a *RejectError -- no amount of retrying changes "+
			"either build's version, so classifying it as transient makes a client hammer a "+
			"relay it can never use", rejErr)
	}
	if rej.Retryable {
		t.Fatal("the refusal is marked retryable")
	}
	if rej.Code != protocol.CodeProtocolVersionMismatch {
		t.Fatalf("code %q, want %q", rej.Code, protocol.CodeProtocolVersionMismatch)
	}
}

// No floor is the default, so an adapter that predates the field keeps working unchanged.
func TestAnAdapterWithNoFloorAcceptsWhatTheBuildAccepts(t *testing.T) {
	c := New()
	if rej := c.refuseWelcomeVersion(protocol.Welcome{
		PlayerID:        "p1",
		ProtocolVersion: protocol.Version,
	}); rej != nil {
		t.Fatalf("an adapter declaring no floor was refused: %v", rej)
	}
}

// An adapter's floor may only tighten: one below the build's would switch off a safety check from outside the process.
func TestAnAdapterCannotLowerTheBuildFloor(t *testing.T) {
	c := New()
	c.mu.Lock()
	c.adapterMinProtocol = 1 // below protocol.MinProtocolVersion
	c.mu.Unlock()

	rej := c.refuseWelcomeVersion(protocol.Welcome{
		PlayerID:        "p1",
		ProtocolVersion: protocol.MinProtocolVersion - 1,
	})
	if rej == nil {
		t.Fatal("an adapter-declared floor below this build's own let a too-old relay through -- " +
			"the field would then be a way to switch off a safety check from outside the process")
	}
}
