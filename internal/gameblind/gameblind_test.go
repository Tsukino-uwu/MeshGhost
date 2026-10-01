// Package gameblind holds the tests that keep the Go side game-blind, so the split between client and server on one
// side and adapter and game on the other fails a test when crossed instead of resting on prose.
//
// The forbidden thing is not a game's identity: game_id is part of the contract, routed and filtered on as an opaque
// label. It is the Go side knowing what a game does: its mechanics, states, units and quirks. A label may be carried,
// compared and logged, never the thing a behaviour is chosen by. The likeliest breach is not a branch on a game's name
// but contract creep, a field only one game needs added to the wire and "just passed through", which is why the wire's
// field lists are frozen below.
//
// Comments and tests are exempt: naming the game a rule came from is documentation, and tests use real game ids as
// sample data, the opaque-label use the contract intends.
package gameblind_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// gameTokens are the shipped games and the families they arrive through: generic transport and session code has no
// legitimate reason to contain any of them.
var gameTokens = []string{"emerald", "crystal", "tevi", "pseudoregalia", "pokemon", "bizhawk"}

// libraryDirs is the generic Go side. internal/e2e is left out because it names games as test data; pake and the
// internal packages are in because core, relay and netx import them, and the import check trusts any package of this
// module whose path names no game.
var libraryDirs = []string{"bridge", "core", "netx", "protocol", "relay", "transport",
	"pake", "internal/cfg", "internal/hotkey", "internal/textfmt", "internal/throttle"}

const cmdDir = "cmd"

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("resolving the repo root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("expected go.mod at %s: %v", root, err)
	}
	return root
}

func containsGameToken(s string) string {
	low := strings.ToLower(s)
	for _, tok := range gameTokens {
		if strings.Contains(low, tok) {
			return tok
		}
	}
	return ""
}

// Every non-test .go file under the given roots, testdata excluded.
func goFiles(t *testing.T, root string, dirs []string) []string {
	t.Helper()
	var out []string
	for _, d := range dirs {
		err := filepath.WalkDir(filepath.Join(root, d), func(path string, e fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if e.IsDir() {
				if e.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
				out = append(out, path)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", d, err)
		}
	}
	if len(out) == 0 {
		t.Fatal("found no Go files to check -- the paths in this test have gone stale")
	}
	return out
}

// TestGoSideNeverBranchesOnAGame fails when the generic Go side contains a game's name in code. A library package has
// no user-facing text, so no identifier or string literal may name a game; cmd/ may in help text, but never in a
// comparison, switch or lookup, the shapes that choose behaviour by game.
func TestGoSideNeverBranchesOnAGame(t *testing.T) {
	root := repoRoot(t)
	fset := token.NewFileSet()

	check := func(path string, cmdRules bool) {
		f, err := parser.ParseFile(fset, path, nil, 0) // 0: comments are not in the AST, and are allowed
		if err != nil {
			t.Fatalf("parsing %s: %v", path, err)
		}

		// First pass: game-name literals where a decision is made, so cmd/'s help text can be told from a comparison.
		decisions := map[token.Pos]string{}
		mark := func(n ast.Node) {
			ast.Inspect(n, func(inner ast.Node) bool {
				if lit, ok := inner.(*ast.BasicLit); ok && lit.Kind == token.STRING {
					if tok := containsGameToken(lit.Value); tok != "" {
						decisions[lit.Pos()] = tok
					}
				}
				return true
			})
		}
		ast.Inspect(f, func(n ast.Node) bool {
			switch v := n.(type) {
			case *ast.BinaryExpr:
				if v.Op == token.EQL || v.Op == token.NEQ {
					mark(v)
				}
			case *ast.CaseClause:
				for _, e := range v.List {
					mark(e)
				}
			case *ast.IndexExpr:
				mark(v.Index)
			case *ast.KeyValueExpr:
				mark(v.Key)
			}
			return true
		})

		rel, _ := filepath.Rel(root, path)
		ast.Inspect(f, func(n ast.Node) bool {
			switch v := n.(type) {
			case *ast.Ident:
				if tok := containsGameToken(v.Name); tok != "" {
					t.Errorf("%s:%d: the identifier %q names a game (%q). The Go side may carry a "+
						"game's id as an opaque label, never know what that game does -- see this "+
						"file's header and the 2026-08-20 ADR.",
						rel, fset.Position(v.Pos()).Line, v.Name, tok)
				}
			case *ast.BasicLit:
				if v.Kind != token.STRING {
					return true
				}
				tok := containsGameToken(v.Value)
				if tok == "" {
					return true
				}
				_, isDecision := decisions[v.Pos()]
				if !cmdRules {
					t.Errorf("%s:%d: %s names a game (%q). A library package has no user-facing "+
						"text, so this is behaviour selected by which game is attached.",
						rel, fset.Position(v.Pos()).Line, v.Value, tok)
				} else if isDecision {
					t.Errorf("%s:%d: %s names a game (%q) in a comparison, switch or lookup. "+
						"Naming games in help text is fine; branching on one is not.",
						rel, fset.Position(v.Pos()).Line, v.Value, tok)
				}
			}
			return true
		})
	}

	for _, path := range goFiles(t, root, libraryDirs) {
		check(path, false)
	}
	for _, path := range goFiles(t, root, []string{cmdDir}) {
		check(path, true)
	}
}

// allowedThirdParty is explicit rather than all of go.mod, so a new dependency is a decision, not a side effect of
// go get.
var allowedThirdParty = []string{
	"github.com/quic-go/quic-go",
	"golang.org/x/",
	// The room-code proof's OPAQUE implementation, imported only by pake.
	"github.com/bytemare/opaque",
}

// TestGoSideImportsStayGeneric fails when a library package imports something outside the standard library, this
// module and allowedThirdParty: the back door through which game knowledge would arrive as a dependency.
func TestGoSideImportsStayGeneric(t *testing.T) {
	root := repoRoot(t)
	fset := token.NewFileSet()
	const module = "github.com/Tsukino-uwu/MeshGhost"

	for _, path := range goFiles(t, root, libraryDirs) {
		f, err := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parsing %s: %v", path, err)
		}
		rel, _ := filepath.Rel(root, path)
		for _, imp := range f.Imports {
			p := strings.Trim(imp.Path.Value, `"`)
			if !strings.Contains(strings.Split(p, "/")[0], ".") { // no dot in the first segment: stdlib
				continue
			}
			if strings.HasPrefix(p, module) {
				if tok := containsGameToken(p); tok != "" {
					t.Errorf("%s:%d: imports %q, which names a game (%q).",
						rel, fset.Position(imp.Pos()).Line, p, tok)
				}
				continue
			}
			ok := false
			for _, a := range allowedThirdParty {
				if strings.HasPrefix(p, a) {
					ok = true
					break
				}
			}
			if !ok {
				t.Errorf("%s:%d: imports %q, which is not the standard library, this module, or an "+
					"allowed dependency. If it belongs here, add it to allowedThirdParty and say why.",
					rel, fset.Position(imp.Pos()).Line, p)
			}
		}
	}
}

// The wire, frozen: each entry is the JSON field names of one message, sorted.
//
// The burden of proof for adding one: area_id and anim are the shape to copy, held and compared by equality without
// the core reading what is inside. Before this list is edited, one of these must hold:
//
//   - the field serves at least two unrelated games, a generic capability rather than one game's mechanic; or
//   - the field is opaque to the core by construction: carried, compared by equality at most, never interpreted.
//
// If neither holds it is game knowledge, and it belongs in the adapter, inside an opaque field it already has (extras,
// an event payload).
var frozenProtocolFields = map[string][]string{
	// prev passes the second test: the previous sample as a delta of the same opaque fields, built and undone by
	// protocol.BuildPrev and ApplyPrev without reading any of them.
	"State": {"anim", "area_id", "extras", "orientation", "player_id", "position", "prev", "seq", "timestamp"},
	// StatePrev passes as State does: every field is one of State's own, or a flag (position_none, extras_none) saying
	// it was absent, since JSON cannot tell an omitted field from an empty one.
	"StatePrev": {"anim", "area_id", "extras", "extras_none", "orientation", "position", "position_none", "seq", "timestamp"},
	"Envelope":  {"payload", "type"},
	// own_area_only passes the second test: a bool asking the relay to compare two area_ids for equality.
	// name_color and the nametags pass both: every game that draws a ghost can draw a label over it, and the core
	// sanitizes them for safety but never reads, compares or branches on them; player_id stays the only identity.
	// pake_ke1 and Pake are the room-code proof's opaque bytes, handed to package pake and never read.
	"Hello":   {"display_name", "features", "game_id", "game_version", "max_receive_hz_per_player", "name_color", "own_area_only", "pake_ke1", "protocol_version", "query_only", "resume_token", "room"},
	"Pake":    {"ke2", "ke3"},
	"Welcome": {"features", "ghost_collision", "nametags", "player_id", "protocol_version", "resume_token", "resumed", "roster", "send_hz", "server_time_ms"},
	"Reject":  {"code", "reason", "retryable"},
	"Join":    {"nametag", "player_id", "state"},
	"Nametag": {"color", "name"},
	"Leave":   {"player_id"},
	"Event":   {"corr_id", "from", "payload", "seq", "to"},
	"Ping":    {"nonce"},
	// own_area_only again, for Hello's reason; its own message because Hello is sent before the adapter attaches.
	"Prefs":          {"own_area_only"},
	"Pong":           {"nonce", "server_time_ms"},
	"TransportOffer": {"kind", "port"},
	"Transports":     {"offers"},
	"Lease":          {"key", "op", "ttl_ms"},
	"LeaseState":     {"expires_at", "holder", "key", "reason", "seq"},
	"Escrow":         {"blob", "id", "op", "with"},
	"EscrowState":    {"blobs", "committed", "deposited", "id", "parties", "phase", "reason", "seq"},
	"World":          {"authority", "blob", "key", "op", "reliable"},
	"WorldEntry":     {"blob", "dropped", "key"},
	"WorldState":     {"authority", "entries", "holder", "reason", "seq"},
}

var frozenBridgeFields = map[string][]string{
	"Envelope": {"payload", "type"},
	// interpolate_orientation and input_tracks pass the second test like render_all_areas: bools by which an adapter
	// declares a capability of its own. min_protocol_version passes it too: a number compared with the relay's version
	// and never interpreted, since no game's floor differs for a reason about the game.
	"Hello":       {"features", "game_id", "game_version", "input_tracks", "interpolate_orientation", "min_protocol_version", "render_all_areas"},
	"Event":       {"Event"},
	"Lease":       {"Lease"},
	"LeaseState":  {"LeaseState"},
	"Escrow":      {"Escrow"},
	"EscrowState": {"EscrowState"},
	"World":       {"World"},
	"WorldState":  {"WorldState"},
	// chaser_contact is a policy string like ghost_collision; the core knows nothing about what contact is.
	"SessionPolicy": {"chaser_contact", "ghost_collision"},
	// ReplayControl is an action from a fixed list and seconds: the adapter pressing one of the core's own keys.
	"ReplayControl": {"action", "seconds"},
	"Reject":        {"code", "reason", "retryable"},
	"LocalState":    {"state"},
	// BridgeReady carries nothing, and the empty list is the point: session facts go in session_policy and
	// recording_state.
	"BridgeReady": {},
	// RemoteName passes as protocol.Nametag does: a label any game can draw, sanitized and never read for meaning.
	"RemoteName": {"color", "display_name", "player_id"},
	// RecordingState is a bool and a wall-clock stamp for a recording the core owns.
	"RecordingState": {"recording", "started_unix_ms"},
	// PlayerFrozen is the closest call: every game holds the player still outside gameplay somehow, and the core learns
	// nothing about which; a reason string naming the game's own state would breach the rule.
	"PlayerFrozen": {"frozen"},
	// InputSample passes both: every game has input, and the core compares m for equality without decomposing it,
	// copies labels, axes and source verbatim, checks f and t for order only and carries ax; the adapter names its own
	// buttons.
	"InputSample": {"axes", "drop", "edges", "labels", "source"},
	"InputEdge":   {"ax", "f", "m", "t"},
	// RemoteInput is InputSample going the other way: the file's bytes verbatim, plus at, computed from two timestamps
	// the core owns, and reset, a bare "drop what you hold".
	"RemoteInput":     {"axes", "edges", "labels", "player_id", "reset", "source"},
	"RemoteInputEdge": {"at", "ax", "f", "m", "t"},
	// orientation_from, orientation_to and interp_t pass the second test: the same opaque bytes orientation already is,
	// and a fraction of two timestamps the core owns. cosmetic is a bool the core sets on a ghost it invented.
	"RenderRemote":  {"cosmetic", "interp_t", "orientation_from", "orientation_to", "player_id", "state"},
	"DespawnRemote": {"player_id"},
}

func jsonFields(v any) []string {
	t := reflect.TypeOf(v)
	out := make([]string, 0, t.NumField())
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		name := strings.Split(f.Tag.Get("json"), ",")[0]
		if name == "" {
			name = f.Name
		}
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// TestWireFieldsAreFrozen fails when a message gains or loses a field without this test being updated, so contract
// creep is a decision, not a drift.
func TestWireFieldsAreFrozen(t *testing.T) {
	protocolSamples := map[string]any{
		"State": protocol.State{}, "StatePrev": protocol.StatePrev{},
		"Envelope": protocol.Envelope{}, "Hello": protocol.Hello{},
		"Welcome": protocol.Welcome{}, "Reject": protocol.Reject{}, "Join": protocol.Join{},
		"Nametag": protocol.Nametag{},
		"Leave":   protocol.Leave{}, "Event": protocol.Event{}, "Ping": protocol.Ping{},
		"Pong": protocol.Pong{}, "Prefs": protocol.Prefs{},
		"TransportOffer": protocol.TransportOffer{},
		"Transports":     protocol.Transports{}, "Lease": protocol.Lease{}, "Pake": protocol.Pake{},
		"LeaseState": protocol.LeaseState{}, "Escrow": protocol.Escrow{},
		"EscrowState": protocol.EscrowState{}, "World": protocol.World{},
		"WorldEntry": protocol.WorldEntry{}, "WorldState": protocol.WorldState{},
	}
	bridgeSamples := map[string]any{
		"Envelope": bridge.Envelope{}, "Hello": bridge.Hello{}, "Event": bridge.Event{},
		"Lease": bridge.Lease{}, "LeaseState": bridge.LeaseState{}, "Escrow": bridge.Escrow{},
		"EscrowState": bridge.EscrowState{}, "World": bridge.World{},
		"WorldState": bridge.WorldState{}, "SessionPolicy": bridge.SessionPolicy{},
		"Reject": bridge.Reject{}, "LocalState": bridge.LocalState{},
		"RenderRemote": bridge.RenderRemote{}, "DespawnRemote": bridge.DespawnRemote{},
		"ReplayControl": bridge.ReplayControl{}, "BridgeReady": bridge.BridgeReady{},
		"RemoteName": bridge.RemoteName{}, "RecordingState": bridge.RecordingState{},
		"PlayerFrozen": bridge.PlayerFrozen{},
		"InputSample":  bridge.InputSample{}, "InputEdge": bridge.InputEdge{},
		"RemoteInput": bridge.RemoteInput{}, "RemoteInputEdge": bridge.RemoteInputEdge{},
	}

	compare := func(which string, samples map[string]any, frozen map[string][]string) {
		for name, sample := range samples {
			want, ok := frozen[name]
			if !ok {
				t.Errorf("%s.%s has no frozen field list -- add one and read the burden of proof "+
					"above it first", which, name)
				continue
			}
			got := jsonFields(sample)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("%s.%s fields changed:\n  frozen: %v\n  actual: %v\n"+
					"A new field must serve two unrelated games or be opaque to the core by "+
					"construction (see the comment above frozenProtocolFields). If it is neither, "+
					"it is game knowledge and belongs in the adapter.", which, name, want, got)
			}
		}
		for name := range frozen {
			if _, ok := samples[name]; !ok {
				t.Errorf("%s.%s is frozen here but no longer sampled -- was it renamed or removed?",
					which, name)
			}
		}
	}

	compare("protocol", protocolSamples, frozenProtocolFields)
	compare("bridge", bridgeSamples, frozenBridgeFields)
}

// TestEveryBridgeMessageStructIsSampled: an exported struct in bridge.go that was never sampled is invisible to
// TestWireFieldsAreFrozen, free to grow a game-shaped field. It parses the source because a package cannot list its
// declared types at run time.
func TestEveryBridgeMessageStructIsSampled(t *testing.T) {
	path := filepath.Join(repoRoot(t), "bridge", "bridge.go")
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
	if err != nil {
		t.Fatalf("parsing %s: %v", path, err)
	}
	declared := 0
	ast.Inspect(f, func(n ast.Node) bool {
		ts, ok := n.(*ast.TypeSpec)
		if !ok {
			return true
		}
		if _, isStruct := ts.Type.(*ast.StructType); !isStruct {
			return true
		}
		if !ts.Name.IsExported() {
			return true
		}
		declared++
		if _, ok := frozenBridgeFields[ts.Name.Name]; !ok {
			t.Errorf("bridge.%s is an exported bridge message with no entry in frozenBridgeFields "+
				"-- add it to frozenBridgeFields AND to bridgeSamples in TestWireFieldsAreFrozen, "+
				"and read the burden of proof above frozenProtocolFields before you do", ts.Name.Name)
		}
		return true
	})
	if declared == 0 {
		t.Fatalf("found no exported struct types in %s -- the parse, not the contract, is what broke", path)
	}
}

// forbiddenEdges keeps server, client and adapter apart: the split is why the Go side can be trusted without a game
// running, why a relay hosts games it has never heard of, and why an adapter can be written without reading relay/. A
// merge looks like an import, so each edge is one, named by what it would mean.
var forbiddenEdges = []struct{ from, to, why string }{
	{"relay", "bridge", "the server would learn the adapter interface -- the bridge is the CLIENT's business, and a relay that knows it is a relay that could talk to a game"},
	{"relay", "core", "the server would absorb the client"},
	{"core", "relay", "the client would absorb the server"},
	{"bridge", "relay", "the adapter-facing contract would learn the relay protocol -- the same rule adapters themselves are held to"},
	{"bridge", "core", "the adapter-facing contract would depend on the client that serves it, making them one thing"},
	{"cmd/meshghost", "relay", "one binary would be both client and server"},
	{"cmd/meshghost-relay", "core", "one binary would be both server and client"},
	{"cmd/meshghost-relay", "bridge", "the relay binary would speak the adapter's protocol"},
}

// TestTheThreeStayApart fails when a shipped package or binary imports across one of those edges.
func TestTheThreeStayApart(t *testing.T) {
	root := repoRoot(t)
	const module = "github.com/Tsukino-uwu/MeshGhost/"
	fset := token.NewFileSet()

	for _, edge := range forbiddenEdges {
		dir := filepath.Join(root, filepath.FromSlash(edge.from))
		err := filepath.WalkDir(dir, func(path string, e fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			// Tests are exempt: core's tests start a real relay to prove the two halves work together.
			if e.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			f, perr := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
			if perr != nil {
				return perr
			}
			rel, _ := filepath.Rel(root, path)
			for _, imp := range f.Imports {
				p := strings.Trim(imp.Path.Value, `"`)
				if p == module+edge.to || strings.HasPrefix(p, module+edge.to+"/") {
					t.Errorf("%s:%d: %s imports %s -- %s. See this file's header.",
						rel, fset.Position(imp.Pos()).Line, edge.from, edge.to, edge.why)
				}
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", edge.from, err)
		}
	}
}

// relayOnlyVocabulary is relay-protocol vocabulary: an adapter that contains any of it is speaking past its own bridge.
var relayOnlyVocabulary = []string{"resume_token", "room_code", "pake_ke1", "protocol_version"}

// containsIdentifier is strings.Contains at word boundaries, so an adapter's own min_protocol_version does not match
// the relay's protocol_version; an exemption list would need renewing for every such field. Identifier characters are
// letters, digits and underscore in Lua, C# and C++ alike.
func containsIdentifier(body, word string) bool {
	for i := 0; ; {
		j := strings.Index(body[i:], word)
		if j < 0 {
			return false
		}
		start := i + j
		end := start + len(word)
		beforeOK := start == 0 || !isIdentRune(rune(body[start-1]))
		afterOK := end == len(body) || !isIdentRune(rune(body[end]))
		if beforeOK && afterOK {
			return true
		}
		i = start + 1
	}
}

func isIdentRune(r rune) bool {
	return r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

// TestAdaptersNeverSpeakTheRelayProtocol reads the adapter sources as text, since they are Lua, C# and C++. Vendored
// dependencies are skipped: they are not ours.
func TestAdaptersNeverSpeakTheRelayProtocol(t *testing.T) {
	root := repoRoot(t)
	exts := map[string]bool{".lua": true, ".cs": true, ".cpp": true, ".hpp": true}
	skipDirs := map[string]bool{"RE-UE4SS": true, "_deps": true, "build": true, "lib": true, "obj": true, "bin": true}

	err := filepath.WalkDir(filepath.Join(root, "adapters"), func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if e.IsDir() {
			if skipDirs[e.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if !exts[strings.ToLower(filepath.Ext(path))] {
			return nil
		}
		b, rerr := os.ReadFile(path)
		if rerr != nil {
			return rerr
		}
		body := strings.ToLower(string(b))
		rel, _ := filepath.Rel(root, path)
		for _, word := range relayOnlyVocabulary {
			if containsIdentifier(body, word) {
				t.Errorf("%s: contains %q, which belongs to the relay protocol. An adapter speaks "+
					"to its own local core over the bridge and to nothing else.", rel, word)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking adapters: %v", err)
	}
}
