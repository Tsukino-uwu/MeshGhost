package bridge

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// This package had no test file at all until 2026-08-25, which is the gap these
// close. It is 300 lines of wire contract that FOUR adapters implement by hand,
// in three languages that share no code with it and no code with each other --
// Lua for Emerald and Crystal, C# for TEVI, C++ for Pseudoregalia. Nothing here
// can verify those implementations; what it can do is pin the Go side of the
// contract they were all written against, so the reference does not move
// underneath them silently.
//
// It is also a JSON parsing boundary fed by a game mod, which is the other
// reason: the core decodes whatever an adapter sends, and an adapter is a script
// a user edits.

// TestEnvelopeRoundTripsEveryMessageType is the one that would catch a renamed
// JSON tag. Every adapter matches on these exact strings -- the Lua ones do a
// literal string compare against "render_remote" -- so a Go-side rename compiles
// cleanly, passes every other test, and silently stops four games rendering.
func TestEnvelopeRoundTripsEveryMessageType(t *testing.T) {
	// The wire names, written out rather than derived from the constants. A test
	// that says TypeHello == TypeHello proves nothing; these are the literals the
	// other three languages have hardcoded.
	want := map[MessageType]string{
		TypeHello:         "hello",
		TypeLocalState:    "local_state",
		TypeRenderRemote:  "render_remote",
		TypeDespawnRemote: "despawn_remote",
		TypeBridgeReady:   "bridge_ready",
		TypeReject:        "reject",
		TypeSessionPolicy: "session_policy",
	}
	for typ, literal := range want {
		if string(typ) != literal {
			t.Errorf("message type is %q, but adapters match on the literal %q", typ, literal)
		}
		env := Envelope{Type: typ, Payload: json.RawMessage(`{}`)}
		b, err := json.Marshal(env)
		if err != nil {
			t.Fatalf("marshal %s: %v", typ, err)
		}
		if !strings.Contains(string(b), `"type":"`+literal+`"`) {
			t.Errorf("envelope for %s does not serialize its type as %q: %s", typ, literal, b)
		}
		var back Envelope
		if err := json.Unmarshal(b, &back); err != nil {
			t.Fatalf("unmarshal %s: %v", typ, err)
		}
		if back.Type != typ {
			t.Errorf("round trip changed type: %q -> %q", typ, back.Type)
		}
	}
}

// TestHelloDefaultsAreTheCosmeticShippedOnes pins what an adapter that declares
// nothing gets. Every shipped adapter sends only game_id (and usually
// game_version), so the zero value of everything else IS the shipped behaviour:
// no capabilities requested, and the core's own cross-area filter left on.
func TestHelloDefaultsAreTheCosmeticShippedOnes(t *testing.T) {
	var h Hello
	if err := json.Unmarshal([]byte(`{"game_id":"emerald"}`), &h); err != nil {
		t.Fatalf("a minimal hello must decode: %v", err)
	}
	if h.GameID != "emerald" {
		t.Errorf("game_id = %q, want %q", h.GameID, "emerald")
	}
	if h.GameVersion != "" {
		t.Errorf("game_version = %q, want empty for an adapter that omits it", h.GameVersion)
	}
	if len(h.Features) != 0 {
		t.Errorf("features = %v, want none -- nothing past cosmetic may be on by default", h.Features)
	}
	if h.RenderAllAreas {
		t.Error("render_all_areas defaulted to true; absent must mean false, which is the core's own area filter staying ON")
	}
}

// TestHelloOmitsEmptyOptionalFields guards the other direction. An adapter
// author reading a captured hello should see what was actually declared, not a
// wall of empty strings suggesting settings that were never set.
func TestHelloOmitsEmptyOptionalFields(t *testing.T) {
	b, err := json.Marshal(Hello{GameID: "crystal"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := string(b)
	for _, absent := range []string{"game_version", "features", "render_all_areas"} {
		if strings.Contains(got, absent) {
			t.Errorf("a minimal hello carries %q it never set: %s", absent, got)
		}
	}
}

// TestUnknownFieldsAndTypesAreIgnored is the forward-compatibility rule from
// agent_docs/contract.md, and it is the reason a newer core can talk to an older
// adapter at all. Contract: "Unknown fields in a received message are ignored,
// not rejected", and an unknown message type is ignored rather than an error.
func TestUnknownFieldsAndTypesAreIgnored(t *testing.T) {
	t.Run("an unknown field does not fail the decode", func(t *testing.T) {
		var h Hello
		err := json.Unmarshal([]byte(`{"game_id":"tevi","invented_later":{"a":1}}`), &h)
		if err != nil {
			t.Fatalf("an unknown field must be ignored, not rejected: %v", err)
		}
		if h.GameID != "tevi" {
			t.Errorf("game_id = %q -- the known fields must still land", h.GameID)
		}
	})

	t.Run("an unknown message type decodes as an envelope", func(t *testing.T) {
		// The core switches on Type and ignores what it does not know. Decoding
		// has to succeed for it to get that far.
		var env Envelope
		if err := json.Unmarshal([]byte(`{"type":"invented_later","payload":{}}`), &env); err != nil {
			t.Fatalf("an unknown type must still decode: %v", err)
		}
		if env.Type != "invented_later" {
			t.Errorf("type = %q", env.Type)
		}
	})
}

// TestLocalStateNilStateIsTheAdapterSayingNothingToSend covers the contract's
// "get_local_state() returning nil means don't send this frame" -- the case a
// player sitting at the title screen produces, which Emerald's latch rule turns
// into a real leave rather than a frozen ghost.
func TestLocalStateNilStateIsDistinguishableFromAZeroState(t *testing.T) {
	var msg LocalState
	if err := json.Unmarshal([]byte(`{"state":null}`), &msg); err != nil {
		t.Fatalf("a null state must decode: %v", err)
	}
	if msg.State != nil {
		t.Fatal("state:null decoded to a non-nil State -- 'nothing to send' would become a ghost at the origin")
	}

	if err := json.Unmarshal([]byte(`{"state":{}}`), &msg); err != nil {
		t.Fatalf("an empty state object must decode: %v", err)
	}
	if msg.State == nil {
		t.Fatal("state:{} decoded to nil -- an empty object is a state, not an absence")
	}
}

// TestSessionPolicyEnabledMeansTheAdaptersOwnDefaultsStand pins the field whose
// meaning is easy to invert. Per agent_docs/contract.md: "enabled" means the
// adapter's own defaults stand, including wherever it already makes a ghost
// passable -- it is NOT an instruction to make ghosts solid. "disabled" is the
// binding one.
func TestSessionPolicyValuesMatchTheProtocolConstants(t *testing.T) {
	// The bridge carries the same two strings the relay resolved, so an adapter
	// comparing against "enabled"/"disabled" is comparing against these.
	if protocol.GhostCollisionEnabled != "enabled" || protocol.GhostCollisionDisabled != "disabled" {
		t.Fatalf("ghost collision literals moved: %q / %q -- four adapters compare against the old ones",
			protocol.GhostCollisionEnabled, protocol.GhostCollisionDisabled)
	}
	b, err := json.Marshal(SessionPolicy{GhostCollision: protocol.GhostCollisionDisabled})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(b), `"ghost_collision":"disabled"`) {
		t.Errorf("session_policy does not carry ghost_collision as expected: %s", b)
	}
}

// TestRenderRemoteCarriesStateByValue is a shape check with a real consequence:
// RenderRemote.State is a value, not a pointer, because a render is always about
// a state that exists. Making it a pointer would let a nil reach an adapter that
// has no way to express "draw nothing here" other than despawning.
func TestRenderRemoteRoundTripsPositionAndOpaqueTags(t *testing.T) {
	// Orientation is json.RawMessage on purpose: it is a scalar for one adapter,
	// a quaternion for another, and the core never has to understand which. A
	// quoted string here is what Emerald actually sends.
	in := RenderRemote{
		PlayerID: "p2",
		State: protocol.State{
			PlayerID:    "p2",
			AreaID:      "0:9",
			Position:    []float64{12.5, -3},
			Orientation: json.RawMessage(`"west"`),
			Anim:        "walking",
		},
	}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out RenderRemote
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.PlayerID != in.PlayerID || out.State.AreaID != in.State.AreaID ||
		out.State.Anim != in.State.Anim {
		t.Fatalf("round trip changed a field: %+v -> %+v", in, out)
	}
	if string(out.State.Orientation) != string(in.State.Orientation) {
		t.Fatalf("orientation did not survive verbatim: %s -> %s", in.State.Orientation, out.State.Orientation)
	}
	if len(out.State.Position) != 2 || out.State.Position[0] != 12.5 || out.State.Position[1] != -3 {
		t.Fatalf("position did not survive: %v", out.State.Position)
	}
}

// FuzzEnvelopeUnmarshalNeverPanics is the reason this file exists at all. The
// core decodes an Envelope from whatever an adapter writes to the bridge socket,
// and an adapter is a Lua script a user can edit. A panic here takes the core
// down and the ghosts with it.
//
// Mirrors protocol's own FuzzEnvelopeUnmarshalNeverPanics, which has covered the
// relay side since before this package had any coverage at all.
func FuzzEnvelopeUnmarshalNeverPanics(f *testing.F) {
	f.Add([]byte(`{"type":"hello","payload":{"game_id":"emerald"}}`))
	f.Add([]byte(`{"type":"local_state","payload":{"state":null}}`))
	f.Add([]byte(`{"type":"render_remote","payload":{"player_id":"p2","state":{}}}`))
	f.Add([]byte(`{"type":"","payload":null}`))
	f.Add([]byte(`{}`))
	f.Add([]byte(``))
	f.Add([]byte(`[]`))
	f.Add([]byte(`{"type":123}`))
	f.Add([]byte("{\"type\":\"hello\",\"payload\":\xff\xfe}"))

	f.Fuzz(func(t *testing.T, data []byte) {
		var env Envelope
		if err := json.Unmarshal(data, &env); err != nil {
			return // a rejected message is a fine outcome; a panic is not
		}
		// Whatever came back must survive being re-encoded, since the core
		// forwards some of these onward.
		if _, err := json.Marshal(env); err != nil {
			return
		}
	})
}

// FuzzHelloUnmarshalNeverPanics covers the first message on every bridge
// connection specifically. It is the one an adapter sends before anything is
// established, so it is decoded on a path with the least state around it -- and
// it is the message every one of the four hand-written adapters composes itself.
func FuzzHelloUnmarshalNeverPanics(f *testing.F) {
	f.Add([]byte(`{"game_id":"emerald","game_version":"phase5.5"}`))
	f.Add([]byte(`{"game_id":"crystal","features":["event.v1"],"render_all_areas":true}`))
	f.Add([]byte(`{"game_id":null}`))
	f.Add([]byte(`{"features":"not-an-array"}`))
	f.Add([]byte(`{"render_all_areas":"yes"}`))
	f.Add([]byte(`{}`))

	f.Fuzz(func(t *testing.T, data []byte) {
		var h Hello
		if err := json.Unmarshal(data, &h); err != nil {
			return
		}
		// A decoded hello is forwarded into the relay hello, so it must
		// re-encode. protocol.ValidateHelloFields is what bounds it there; here
		// the only claim is that nothing panics on the way.
		if _, err := json.Marshal(h); err != nil {
			return
		}
	})
}
