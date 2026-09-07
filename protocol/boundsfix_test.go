package protocol

// Regressions for the three bounds the 2026-09-07 adversarial review found
// measuring the wrong thing (C3, C4, C5). Each of these fails against the code
// as it stood on 2026-09-07.

import (
	"encoding/json"
	"strings"
	"testing"
)

// maxDatagramBudget is netx/udpconn's MaxDatagramBytes. Duplicated as a literal
// rather than imported: protocol may not depend on a transport, and the whole
// point of the world-plane derivation is that this number is the one being
// spent. netx/udpconn/world_bounds_test.go asserts the real constant against
// the real message from the other side of the dependency.
const maxDatagramBudget = 1200

// worldStateWireBytes is the world_state line the relay would put on the wire
// for one entry under the named authority and key, framing included.
func worldStateWireBytes(t *testing.T, authority, key string) int {
	t.Helper()
	blob := json.RawMessage(`"` + strings.Repeat("x", MaxWorldBlobBytes-2) + `"`)
	if JSONWireLen(blob) != MaxWorldBlobBytes {
		t.Fatalf("built a %d-byte blob, want %d", JSONWireLen(blob), MaxWorldBlobBytes)
	}
	payload, err := json.Marshal(WorldState{
		Authority: authority,
		Holder:    strings.Repeat("p", 16),
		Seq:       ^uint64(0),
		Reason:    WorldSnapshot,
		Entries:   []WorldEntry{{Key: key, Blob: blob}},
	})
	if err != nil {
		t.Fatalf("marshal world_state: %v", err)
	}
	line, err := json.Marshal(Envelope{Type: TypeWorldState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	t.Logf("world_state with a %d-byte authority and a %d-byte key: %d bytes of payload, %d on the wire",
		len(authority), len(key), len(payload), len(line))
	return len(line)
}

// TestAWorldAuthorityAndKeyAreMeasuredOnTheWire is C3. MaxWorldBlobBytes is
// derived by subtracting MaxLeaseKeyLen and MaxWorldKeyLen from the datagram
// budget, so measuring those two with len() while the blob is measured with
// JSONWireLen makes the arithmetic false by up to six times.
//
// Measured 2026-09-08 by the helper above: all-ASCII, 1082 bytes of payload
// and 1115 on the wire, comfortably inside udpconn's 1200. With the authority
// swapped for 128 '&' and the key for 64 '&' — both of which ValidateWorld
// accepted until this fix — the same message is 2042 bytes of payload and 2075
// on the wire, which udpconn.checkWritable refuses. The refusal surfaces only
// as "relay: send to pX failed:", so every world_state under that authority
// simply stops existing for every udp and quic-datagram peer.
func TestAWorldAuthorityAndKeyAreMeasuredOnTheWire(t *testing.T) {
	asciiAuthority := strings.Repeat("a", MaxLeaseKeyLen)
	asciiKey := strings.Repeat("k", MaxWorldKeyLen)
	if n := worldStateWireBytes(t, asciiAuthority, asciiKey); n > maxDatagramBudget {
		t.Fatalf("the all-ASCII maximal world_state is already %d bytes, over the %d-byte "+
			"datagram budget -- this test cannot say anything about escaping", n, maxDatagramBudget)
	}

	// Every byte here is legal in an opaque identifier and every one of them
	// costs six on the wire.
	escapedAuthority := strings.Repeat("&", MaxLeaseKeyLen)
	escapedKey := strings.Repeat("&", MaxWorldKeyLen)
	if n := worldStateWireBytes(t, escapedAuthority, escapedKey); n <= maxDatagramBudget {
		t.Fatalf("the escaped maximal world_state is %d bytes, inside the %d-byte budget -- "+
			"the premise of this test no longer holds", n, maxDatagramBudget)
	}

	if ValidateWorld(World{Op: WorldSet, Authority: escapedAuthority, Key: "e0"}) {
		t.Error("a world authority that only fits before escaping was accepted")
	}
	if ValidateWorld(World{Op: WorldSet, Authority: "sim", Key: escapedKey}) {
		t.Error("a world key that only fits before escaping was accepted")
	}
	if ValidateWorldState(WorldState{Authority: escapedAuthority, Holder: "p1"}) {
		t.Error("a world_state authority that only fits before escaping was accepted")
	}
	if ValidateWorldState(WorldState{Authority: "sim", Holder: "p1",
		Entries: []WorldEntry{{Key: escapedKey, Blob: json.RawMessage(`1`)}}}) {
		t.Error("a world_state entry key that only fits before escaping was accepted")
	}

	// The bound must not have moved for anything that does not escape: the
	// ASCII maximum above is still exactly at the limit, not one byte under.
	if !ValidateWorld(World{Op: WorldSet, Authority: asciiAuthority, Key: asciiKey}) {
		t.Error("the maximal all-ASCII authority/key pair was rejected")
	}
}

// TestOpaqueStringWireLengthMatchesWhatMarshalWrites pins the new measure to
// the encoder it models, the same way TestJSONWireLenMatchesWhatMarshalWrites
// pins its raw-value sibling. Under-counting is the whole bug; over-counting
// would silently refuse legitimate identifiers, so this checks both directions
// for valid UTF-8, which is the only input the check ever sees.
func TestOpaqueStringWireLengthMatchesWhatMarshalWrites(t *testing.T) {
	for _, s := range []string{
		"", "sim", "a?x=1&y=2", "<tag>", strings.Repeat("&", 128),
		"quote\"and\\slash", "control\x01\x1f", "héllo", "日本語", "  ",
	} {
		enc, err := json.Marshal(s)
		if err != nil {
			t.Fatalf("marshal %q: %v", s, err)
		}
		// enc carries the two surrounding quotes that opaqueStringWireLen
		// deliberately leaves to the message's scaffolding.
		if got, want := opaqueStringWireLen(s), len(enc)-2; got != want {
			t.Errorf("opaqueStringWireLen(%q) = %d, encoder wrote %d bytes of content", s, got, want)
		}
	}
}

// TestACarriedPrevOrientationMeetsTheNestingCap is C4. ValidateState applies
// both halves of the orientation bound to state.orientation; validPrev applied
// only the size half, so this value was refused in one field and accepted in
// the other — and ApplyPrev then reconstructs a sample that ValidateState
// itself would reject and hands it to the adapter as render_remote.orientation.
func TestACarriedPrevOrientationMeetsTheNestingCap(t *testing.T) {
	const levels = 120
	deep := json.RawMessage(strings.Repeat("[", levels) + strings.Repeat("]", levels))
	if JSONWireLen(deep) > MaxOrientationBytes {
		t.Fatalf("the fixture is %d bytes, over MaxOrientationBytes (%d) -- it would be "+
			"refused on size and would prove nothing about depth", JSONWireLen(deep), MaxOrientationBytes)
	}
	if levels <= MaxJSONDepth {
		t.Fatalf("the fixture is %d levels deep, within MaxJSONDepth (%d)", levels, MaxJSONDepth)
	}

	carrying := State{PlayerID: "p1", Seq: 2, Timestamp: 1000, AreaID: "a", Anim: "idle"}
	if !ValidateState(carrying) {
		t.Fatal("the carrying state was rejected before the prev was attached")
	}
	if ValidateState(State{PlayerID: "p1", Seq: 2, Timestamp: 1000, AreaID: "a",
		Anim: "idle", Orientation: deep}) {
		t.Fatal("ValidateState accepted the deep orientation directly -- premise gone")
	}

	carrying.Prev = &StatePrev{Seq: 1, Timestamp: 900, Orientation: deep}
	if ValidateState(carrying) {
		t.Fatal("a prev.orientation past the nesting cap was accepted")
	}
}

// TestApplyPrevNeverProducesAStateValidateStateRejects is the consequence C4
// actually costs: whatever survives validation must still be valid once
// ApplyPrev has reconstructed it, because that reconstruction is what reaches
// the adapter. The deep orientation above is the case that broke it.
func TestApplyPrevNeverProducesAStateValidateStateRejects(t *testing.T) {
	const levels = 120
	deep := json.RawMessage(strings.Repeat("[", levels) + strings.Repeat("]", levels))
	for _, prev := range []*StatePrev{
		{Seq: 1, Timestamp: 900},
		{Seq: 1, Timestamp: 900, Orientation: deep},
		{Seq: 1, Timestamp: 900, Orientation: json.RawMessage(`[0,1,0,0]`)},
	} {
		cur := State{PlayerID: "p1", Seq: 2, Timestamp: 1000, AreaID: "a", Anim: "idle", Prev: prev}
		if !ValidateState(cur) {
			continue
		}
		back, ok := ApplyPrev(&cur)
		if !ok {
			t.Fatal("ApplyPrev found no prev on a state that carries one")
		}
		if !ValidateState(back) {
			t.Errorf("a validated state reconstructed into one ValidateState rejects: %+v", prev)
		}
	}
}

// TestEveryHelloStringFieldIsBounded is C5. NameColor was the one hello string
// outside the check, harmless only because SanitizeNameColor happens to refuse
// anything that is not 4 or 7 bytes — accidentally safe, not bounded. The loop
// covers the whole set so that the next field added to Hello and forgotten
// fails here rather than reaching the relay unbounded.
func TestEveryHelloStringFieldIsBounded(t *testing.T) {
	over := strings.Repeat("x", MaxHelloFieldLen+1)
	for name, h := range map[string]Hello{
		"game_id":      {GameID: over},
		"room":         {Room: over},
		"display_name": {DisplayName: over},
		"room_code":    {RoomCode: over},
		"game_version": {GameVersion: over},
		"name_color":   {NameColor: over},
	} {
		if ValidateHelloFields(h) {
			t.Errorf("an oversized %s was accepted", name)
		}
	}
	at := strings.Repeat("x", MaxHelloFieldLen)
	if !ValidateHelloFields(Hello{GameID: at, Room: at, DisplayName: at,
		RoomCode: at, GameVersion: at, NameColor: at}) {
		t.Error("a hello with every string field exactly at the bound was rejected")
	}
}
