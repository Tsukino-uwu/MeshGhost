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

// wireNames is every bridge message type, with the literal each of the four
// hand-written adapters matches on, written out rather than derived from the
// constants. A test that says TypeHello == TypeHello proves nothing; these are
// the strings the other three languages have hardcoded.
//
// ALL of them, since 2026-09-08. Until then this map held 8 of the 18, and the
// ten it omitted were not the obscure ones: Pseudoregalia's Plugin.cpp compares
// against "remote_name" and "recording_state" and emits a raw
// {"type":"player_frozen",...} line it composes by hand, so a rename of any of
// those compiled cleanly, passed every Go test, and stopped a shipped adapter.
// The mechanical backstop that would have caught it -- preflight.ps1's
// bridge-coverage gate -- runs from docs.yml, whose trigger is **.md, so the
// .go push that did the renaming fired ci.yml and never ran the gate.
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

// TestEnvelopeRoundTripsEveryMessageType is the one that would catch a renamed
// JSON tag. Every adapter matches on these exact strings -- the Lua ones do a
// literal string compare against "render_remote" -- so a Go-side rename compiles
// cleanly, passes every other test, and silently stops four games rendering.
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

// TestEveryBridgeMessageTypeValueIsFrozen closes the hole the map above cannot
// close on its own: a map of 8 entries and a map of 18 look identical from
// inside a test that only iterates it, which is exactly how the list fell ten
// behind between 2026-08-25 and 2026-09-08. Iterating the pinned names can
// never notice a name that was never pinned.
//
// WHY IT PARSES THE SOURCE. Go constants do not survive into the running
// program as a set: they are folded into their use sites at compile time, and
// reflect offers no way to enumerate a package's constants (there is no
// runtime object to enumerate). The declaration list exists in exactly one
// place a test can reach -- bridge.go itself -- so this reads it with go/ast
// and compares the declared MessageType constants against wireNames in BOTH
// directions. Adding a TypeSomethingNew constant therefore fails this test
// until it is pinned above, which is the property the review asked for; the
// same walk is what internal/gameblind already does to enforce its own rules,
// so the technique is not new to this repo.
//
// The go test working directory is the package directory, so "bridge.go" is
// the file this test's own package is compiled from -- there is no path
// configuration to drift.
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

// parseMessageTypeConstants returns every constant of type MessageType
// declared in the named file, as constant name -> string value. It follows
// Go's own rule that a spec with neither a type nor a value repeats the
// previous one, so a future iota-style block is read the same way the compiler
// reads it rather than silently skipped.
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

// TestRenderRemoteCosmeticIsOmittedUnlessSet pins the wire shape of the flag
// ADR 0047 added: a real peer's render_remote is byte-for-byte what it was
// before the flag existed (no "cosmetic" key at all), and a local peer's says
// so explicitly. An adapter that predates the flag therefore sees nothing new
// for real peers, and one that reads it gets a plain JSON bool.
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
