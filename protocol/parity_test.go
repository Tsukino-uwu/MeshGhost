package protocol

import (
	"fmt"
	"strings"
	"testing"
)

// Three bounds that every sibling already had (X1-6, X1-7, X1-8; 2026-09-12).
//
// A parity cell's whole job is "who else is of this shape", and these are what
// it found in this package: two receive validators missing a check their
// neighbours carry, and one bare `len()` among a file of `ValidOpaqueString`s.
// None is dramatic on its own. All three are the shape that produced eleven of
// the roughly twenty-five defects this pass fixed, which is the reason to keep
// looking for it (agent_docs/pitfalls/method.md).

// TestValidateEventBoundsTheIdItCarriesFrom is X1-7. Every other receive
// validator in this package bounds every peer id it carries; ValidateEvent
// bounded To and CorrID and left From, which the relay stamps and the CORE
// then validates a hostile relay's version of before handing it to the adapter
// as "who this came from".
func TestValidateEventBoundsTheIdItCarriesFrom(t *testing.T) {
	base := Event{Payload: []byte(`{}`)}

	long := base
	long.From = strings.Repeat("p", MaxHelloFieldLenForID+1)
	if ValidateEvent(long) {
		t.Fatalf("accepted an event whose From is %d bytes, over the %d cap that every other "+
			"peer id on a receive path gets", len(long.From), MaxHelloFieldLenForID)
	}

	// What ValidOpaqueString actually refuses is invalid UTF-8, and that is the
	// property that matters for an id: a string that does not survive a
	// marshal/unmarshal round trip unchanged (json replaces the bad byte with
	// U+FFFD) is one this core would key a map by and the relay would key a
	// DIFFERENT one by. Control bytes are legal UTF-8 and are deliberately not
	// refused -- an opaque id's contents are the game's business.
	bad := base
	bad.From = string([]byte{'p', 0xff, 0xfe})
	if ValidateEvent(bad) {
		t.Fatal("accepted an event whose From is not valid UTF-8")
	}

	// EMPTY IS LEGAL, and this is the half that matters as much as the bound:
	// a relay that predates the field sends no From at all, and refusing that
	// would drop every event from an older relay in order to stop one from a
	// hostile one.
	ok := base
	if !ValidateEvent(ok) {
		t.Fatal("refused an event with no From; that is the shape an older relay sends")
	}
	ok.From = "p2"
	if !ValidateEvent(ok) {
		t.Fatal("refused an event with an ordinary From")
	}
}

// TestNormalizeFeaturesIsBounded is X1-6. validateFeatures gates a Hello, so
// the relay is protected from a client's list; nothing gated a Welcome, so the
// client took whatever the relay answered with -- into c.activeFeatures, which
// HasFeature scans linearly under c.mu on every inbound plane message.
func TestNormalizeFeaturesIsBounded(t *testing.T) {
	var huge []string
	for i := 0; i < 1000; i++ {
		huge = append(huge, fmt.Sprintf("feature.v%d", i))
	}
	got := NormalizeFeatures(huge)
	if len(got) > MaxFeatures {
		t.Fatalf("normalized 1000 features into %d; a relay's Welcome would then cost %d string "+
			"compares under the core's lock on every plane message", len(got), len(got))
	}

	// A name no feature could have is dropped rather than counted against the
	// cap, so a flood of long junk cannot push a real capability out.
	junk := []string{strings.Repeat("x", MaxFeatureLen+1), string([]byte{0xff, 0xfe}), FeatureEventV1}
	got = NormalizeFeatures(junk)
	if len(got) != 1 || got[0] != FeatureEventV1 {
		t.Fatalf("normalized %q to %q; the real feature must survive and the impossible ones must not",
			junk, got)
	}

	// And the ordinary case is untouched: this function's day job is making two
	// clients' lists comparable, and a real list is nowhere near any of these
	// bounds.
	real := []string{FeatureWorldV1, FeatureEventV1, FeatureEventV1, "  " + FeatureLeaseV1 + "  "}
	got = NormalizeFeatures(real)
	if len(got) != 3 {
		t.Fatalf("normalized %q to %q, want three distinct features", real, got)
	}
}

// TestValidateFeaturesUsesTheOpaqueStringRule is X1-8: the last bare len()
// check on an opaque string in this package, now asking the same question every
// sibling asks. Unreachable from the wire, because encoding/json replaces an
// invalid byte with U+FFFD before this ever runs -- which is a property of the
// decoder in front of it, not of this exported function, and is exactly the
// reasoning that let X1-4 through on another field.
func TestValidateFeaturesUsesTheOpaqueStringRule(t *testing.T) {
	if validateFeatures([]string{string([]byte{0xff, 0xfe})}) {
		t.Fatal("accepted a feature name that is not valid UTF-8 -- a name that does not survive " +
			"a round trip unchanged is a capability no two clients can agree on")
	}
	if validateFeatures([]string{strings.Repeat("f", MaxFeatureLen+1)}) {
		t.Fatal("accepted a feature name over the length cap")
	}
	if !validateFeatures([]string{FeatureEventV1, FeatureWorldV1}) {
		t.Fatal("refused two ordinary feature names")
	}
}
