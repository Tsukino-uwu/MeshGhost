package bridge

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// These pin the Go side of the wire contract the adapters implement by hand in other languages, and fuzz the JSON
// boundary an adapter feeds the core.

// wireNames is every bridge message type with the literal the adapters match on, written out rather than derived from
// the constants: a test that says TypeHello == TypeHello proves nothing.
var wireNames = map[MessageType]string{
	TypeHello:          "hello",
	TypeLocalState:     "local_state",
	TypeRenderRemote:   "render_remote",
	TypeDespawnRemote:  "despawn_remote",
	TypeRemoteName:     "remote_name",
	TypeBridgeReady:    "bridge_ready",
	TypeReject:         "reject",
	TypeReplayControl:  "replay_control",
	TypePlayerFrozen:   "player_frozen",
	TypeChaserReset:    "chaser_reset",
	TypeInputSample:    "input_sample",
	TypeRemoteInput:    "remote_input",
	TypeSessionPolicy:  "session_policy",
	TypeRecordingState: "recording_state",
	TypeEvent:          "event",
	TypeLease:          "lease",
	TypeLeaseState:     "lease_state",
	TypeEscrow:         "escrow",
	TypeEscrowState:    "escrow_state",
	TypeWorld:          "world",
	TypeWorldState:     "world_state",
}

// TestEnvelopeRoundTripsEveryMessageType catches a renamed type literal, which would compile and pass every other test
// while every adapter stopped matching.
func TestEnvelopeRoundTripsEveryMessageType(t *testing.T) {
	for typ, literal := range wireNames {
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

// TestEveryBridgeMessageTypeValueIsFrozen compares the MessageType constants declared in bridge.go with wireNames in
// both directions, so a new constant fails until it is pinned; iterating wireNames alone cannot notice one never
// pinned. It parses the source because Go cannot enumerate a package's constants at run time.
func TestEveryBridgeMessageTypeValueIsFrozen(t *testing.T) {
	declared := parseMessageTypeConstants(t, "bridge.go")
	if len(declared) == 0 {
		t.Fatal("parsed no MessageType constants out of bridge.go -- the parse, not the contract, is what broke")
	}
	for name, value := range declared {
		literal, ok := wireNames[MessageType(value)]
		if !ok {
			t.Errorf("bridge.%s = %q is not pinned in wireNames -- add it there (and add a sample to "+
				"internal/gameblind's bridgeSamples), so a later rename of it cannot pass this suite", name, value)
			continue
		}
		if literal != value {
			t.Errorf("bridge.%s declares %q but is pinned as %q", name, value, literal)
		}
	}
	byValue := make(map[string]string, len(declared))
	for name, value := range declared {
		byValue[value] = name
	}
	for typ := range wireNames {
		if _, ok := byValue[string(typ)]; !ok {
			t.Errorf("wireNames pins %q but no MessageType constant in bridge.go declares it -- "+
				"was the constant renamed or removed? Four adapters still match on that literal", typ)
		}
	}
}

// parseMessageTypeConstants returns every MessageType constant in filename as name -> value. A spec with neither a type
// nor a value repeats the previous one, as the compiler reads it, so an implicit-type block is not silently skipped.
func parseMessageTypeConstants(t *testing.T, filename string) map[string]string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filename, nil, parser.SkipObjectResolution)
	if err != nil {
		t.Fatalf("parsing %s: %v", filename, err)
	}
	out := map[string]string{}
	for _, decl := range f.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		lastType := ""
		for _, spec := range gen.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			switch typ := vs.Type.(type) {
			case *ast.Ident:
				lastType = typ.Name
			default:
				if len(vs.Values) > 0 {
					lastType = ""
				}
			}
			if lastType != "MessageType" {
				continue
			}
			for i, name := range vs.Names {
				if i >= len(vs.Values) {
					t.Errorf("const %s has no literal value this test can read", name.Name)
					continue
				}
				lit, ok := vs.Values[i].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					t.Errorf("const %s is not a plain string literal, so it cannot be pinned by value", name.Name)
					continue
				}
				value, err := strconv.Unquote(lit.Value)
				if err != nil {
					t.Errorf("const %s: unquoting %s: %v", name.Name, lit.Value, err)
					continue
				}
				out[name.Name] = value
			}
		}
	}
	return out
}

// TestHelloDefaultsAreTheCosmeticShippedOnes pins what an adapter that declares nothing gets, which is the shipped
// behaviour: no capabilities, and the core's own cross-area filter left on.
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

// TestHelloOmitsEmptyOptionalFields: a captured hello shows only what was declared.
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

// TestUnknownFieldsAndTypesAreIgnored is the forward-compatibility rule that lets a newer core talk to an older
// adapter.
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
		var env Envelope
		if err := json.Unmarshal([]byte(`{"type":"invented_later","payload":{}}`), &env); err != nil {
			t.Fatalf("an unknown type must still decode: %v", err)
		}
		if env.Type != "invented_later" {
			t.Errorf("type = %q", env.Type)
		}
	})
}

// TestLocalStateNilStateIsDistinguishableFromAZeroState: state null is an adapter with nothing to send this frame, and
// must never become a ghost at the origin.
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

// TestSessionPolicyValuesMatchTheProtocolConstants: the bridge carries the two strings the relay resolved, and adapters
// compare against those literals.
func TestSessionPolicyValuesMatchTheProtocolConstants(t *testing.T) {
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

// TestRenderRemoteRoundTripsPositionAndOpaqueTags: position, area and anim survive, and orientation survives verbatim
// as raw JSON, since its shape is per game.
func TestRenderRemoteRoundTripsPositionAndOpaqueTags(t *testing.T) {
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

// FuzzEnvelopeUnmarshalNeverPanics: the core decodes whatever an adapter writes to the bridge, and a panic takes the
// core and every ghost down.
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
		// The core forwards some of these onward, so re-encoding must not panic either.
		if _, err := json.Marshal(env); err != nil {
			return
		}
	})
}

// FuzzHelloUnmarshalNeverPanics covers the first message on every bridge connection, decoded before anything is
// established.
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
		// A decoded hello is forwarded into the relay hello, where protocol.ValidateHelloFields bounds it.
		if _, err := json.Marshal(h); err != nil {
			return
		}
	})
}

// TestRenderRemoteCosmeticIsOmittedUnlessSet: a real peer's render_remote carries no cosmetic key, so an adapter that
// predates the flag sees nothing new, and a local ghost's says cosmetic:true.
func TestRenderRemoteCosmeticIsOmittedUnlessSet(t *testing.T) {
	real, err := json.Marshal(RenderRemote{PlayerID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(real), "cosmetic") {
		t.Fatalf("a real peer's render_remote must not carry the cosmetic key: %s", real)
	}
	local, err := json.Marshal(RenderRemote{PlayerID: "replay:lap1", Cosmetic: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(local), `"cosmetic":true`) {
		t.Fatalf("a local peer's render_remote must say cosmetic:true: %s", local)
	}
	var out RenderRemote
	if err := json.Unmarshal(local, &out); err != nil {
		t.Fatal(err)
	}
	if !out.Cosmetic {
		t.Fatal("cosmetic did not survive a round trip")
	}
}
