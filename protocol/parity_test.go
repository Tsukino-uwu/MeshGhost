package protocol

import (
	"fmt"
	"strings"
	"testing"
)

// TestValidateEventBoundsTheIdItCarriesFrom: every other receive validator bounds every peer id it carries, and the
// core checks a relay's From before handing it to the adapter as the sender.
func TestValidateEventBoundsTheIdItCarriesFrom(t *testing.T) {
	base := Event{Payload: []byte(`{}`)}

	long := base
	long.From = strings.Repeat("p", MaxHelloFieldLenForID+1)
	if ValidateEvent(long) {
		t.Fatalf("accepted an event whose From is %d bytes, over the %d cap that every other "+
			"peer id on a receive path gets", len(long.From), MaxHelloFieldLenForID)
	}

	// Invalid UTF-8 is what matters for an id: it does not survive a round trip, so core and relay would key
	// different strings. Control bytes are legal UTF-8 and allowed; an opaque id's contents are the game's business.
	bad := base
	bad.From = string([]byte{'p', 0xff, 0xfe})
	if ValidateEvent(bad) {
		t.Fatal("accepted an event whose From is not valid UTF-8")
	}

	// Empty is legal: a relay older than the field sends no From, and refusing it would drop all its events.
	ok := base
	if !ValidateEvent(ok) {
		t.Fatal("refused an event with no From; that is the shape an older relay sends")
	}
	ok.From = "p2"
	if !ValidateEvent(ok) {
		t.Fatal("refused an event with an ordinary From")
	}
}

// TestNormalizeFeaturesIsBounded: validateFeatures gates only a Hello, so a Welcome's list reaches the client, and
// HasFeature scans it under the core's lock on every plane message.
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

	// A name no feature could have is dropped, not counted against the cap, so junk cannot push a real one out.
	junk := []string{strings.Repeat("x", MaxFeatureLen+1), string([]byte{0xff, 0xfe}), FeatureEventV1}
	got = NormalizeFeatures(junk)
	if len(got) != 1 || got[0] != FeatureEventV1 {
		t.Fatalf("normalized %q to %q; the real feature must survive and the impossible ones must not",
			junk, got)
	}

	// The ordinary case is untouched: a real list is nowhere near these bounds.
	real := []string{FeatureWorldV1, FeatureEventV1, FeatureEventV1, "  " + FeatureLeaseV1 + "  "}
	got = NormalizeFeatures(real)
	if len(got) != 3 {
		t.Fatalf("normalized %q to %q, want three distinct features", real, got)
	}
}

// TestValidateFeaturesUsesTheOpaqueStringRule: only the decoder in front keeps invalid UTF-8 off the wire, which is a
// property of the decoder, not of ValidateHelloFields, which is exported.
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
