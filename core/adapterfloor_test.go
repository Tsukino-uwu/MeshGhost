package core

import (
	"errors"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// AN ADAPTER MAY DECLARE ITS OWN PROTOCOL FLOOR, AND IT MAY ONLY TIGHTEN.
//
// The core's own floor (protocol.MinProtocolVersion) answers "can these two
// BUILDS talk", which is a property of the wire. An adapter's answers a
// different question that only the adapter can: it may depend on a field an
// older relay never forwards, and without a floor of its own it connects,
// renders, and is quietly missing the thing it was written for. That silent
// degradation is the failure this exists to turn into a refusal.
//
// The user's call, 2026-09-11: "similar to the server/client min floor we
// already have".
func TestAnAdapterFloorRefusesAnOlderRelay(t *testing.T) {
	c := New()
	// One above what this build speaks, so the relay in front of it is by
	// definition too old for this adapter and not for the build.
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

// NO OPINION IS THE DEFAULT, and it is what every shipped adapter sends -- so an
// adapter that predates the field must keep working unchanged.
func TestAnAdapterWithNoFloorAcceptsWhatTheBuildAccepts(t *testing.T) {
	c := New()
	if rej := c.refuseWelcomeVersion(protocol.Welcome{
		PlayerID:        "p1",
		ProtocolVersion: protocol.Version,
	}); rej != nil {
		t.Fatalf("an adapter declaring no floor was refused: %v", rej)
	}
}

// AND IT MAY ONLY TIGHTEN. An adapter naming a floor BELOW the build's must not
// talk the core into accepting a relay the core itself refuses -- otherwise the
// field is a way to disable a safety check from outside the process.
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
