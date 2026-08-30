// Package gameblind holds the tests that keep the Go side game-blind.
//
// WHY THIS EXISTS. MeshGhost is built on the client/server being one thing and the adapter/game
// being another, and until now that separation was enforced only by prose -- `CLAUDE.md`'s core
// rule and the 2026-08-20 ADR in `agent_docs/architecture.md`. Prose is a statement of intent,
// not enforcement: nothing failed when it was crossed. These tests fail.
//
// WHAT THE RULE ACTUALLY IS, in the user's own words (2026-08-20): *"its fine to have
// dumb/generic things in the server/client i guess, if it allows us to reuse things for other
// games. but i still want it to be dumb/not know how the games work"*, and, sharpening it once
// more: *"its fine to have the `game_id` etc, know what game it is. but specifically for 'game
// knowledge' on what the games do/how they work"*.
//
// So the forbidden thing is NOT the identity of a game. `game_id` is a first-class part of the
// contract -- the relay routes rooms by it, a host filters on it, `-game` names it on the command
// line, and every one of those treats it as an opaque label it never looks inside. What is
// forbidden is the Go side knowing anything about what a game DOES: its mechanics, its states, its
// units, its quirks. A label may be carried, compared to another label, and logged. It may never
// be the thing a behaviour is chosen by.
//
// THE THREE CHECKS, and what each one catches:
//
//  1. `TestGoSideNeverBranchesOnAGame` -- the literal tell. A game name in a library package's
//     code at all, or anywhere in `cmd/` outside help text, means a behaviour is being selected by
//     which game is attached.
//  2. `TestGoSideImportsStayGeneric` -- drift by dependency. A game-specific package imported into
//     the core would be game knowledge arriving through the back door.
//  3. `TestWireFieldsAreFrozen` -- the one that matters most, and the one prose missed entirely.
//     The realistic failure is not `if game == "emerald"`; nobody writes that after reading the
//     rule. It is CONTRACT CREEP: a field only one game needs, added to the wire and "just passed
//     through". Every word of the prose rule is satisfied and the protocol has quietly become
//     game-shaped anyway. Freezing the field lists makes that impossible to do silently -- adding
//     a field means editing this test, which is where the burden of proof is stated.
//
// COMMENTS AND TESTS ARE DELIBERATELY EXEMPT. Naming the game a rule came from is how the reason
// survives -- `core.go` explaining a filter with "Emerald's cross-map ghosts" is documentation,
// not knowledge the code acts on -- and the Go-side tests use real game ids as sample DATA, which
// is exactly the opaque-label use the contract intends.
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

// The four shipped games plus the two families they arrive through. A name here is not a
// blocklist of words -- it is the vocabulary that proves game knowledge leaked in, because there
// is no legitimate reason for generic transport/session code to contain any of them.
var gameTokens = []string{"emerald", "crystal", "tevi", "pseudoregalia", "pokemon", "bizhawk"}

// The generic Go side, in full. `internal/e2e` is excluded on purpose: it is a test harness that
// drives a fake adapter and names games as data, which is the allowed use.
var libraryDirs = []string{"bridge", "core", "netx", "protocol", "relay", "transport"}

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

// TestGoSideNeverBranchesOnAGame fails when the generic Go side contains a game's name in code.
//
// Library packages are held to the strict form: no game name in any identifier or string literal,
// full stop. They have no user-facing text, so there is nothing legitimate to say a game's name
// in. `cmd/` is allowed to name games in help text -- a host reading `-game` deserves to know what
// the real values look like -- but never in a comparison, a switch, or a map lookup, because those
// are the shapes that make behaviour depend on which game is attached.
func TestGoSideNeverBranchesOnAGame(t *testing.T) {
	root := repoRoot(t)
	fset := token.NewFileSet()

	check := func(path string, cmdRules bool) {
		f, err := parser.ParseFile(fset, path, nil, 0) // 0: comments are not in the AST, and are allowed
		if err != nil {
			t.Fatalf("parsing %s: %v", path, err)
		}

		// First pass: the positions of game-name literals that sit somewhere a DECISION is made.
		// Collected separately so `cmd/`'s help text can be told apart from a comparison.
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

// Third-party dependencies the generic side is allowed to have. Kept explicit rather than
// "anything already in go.mod": the point is that a NEW one is a decision somebody makes on
// purpose, not something that arrives with a `go get`.
var allowedThirdParty = []string{
	"github.com/quic-go/quic-go",
	"golang.org/x/",
}

// TestGoSideImportsStayGeneric fails when a library package imports something that is not the
// standard library, this module, or an explicitly allowed dependency -- the back door through
// which game knowledge would arrive as a dependency rather than as a branch.
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

// The wire, frozen. Each entry is the JSON field names of one message, sorted.
//
// THE BURDEN OF PROOF FOR ADDING ONE. `area_id` and `anim` are the shape to copy: the core holds
// them, compares them by equality, and never reads what is inside -- so they carry whatever a game
// means by them without the core learning any of it. A new field must be the same kind of thing.
// Concretely, before this list is edited, one of these has to be true:
//
//   - the field serves at least two unrelated games, so it is a generic capability rather than one
//     game's mechanic wearing a general-sounding name; or
//   - the field is opaque to the core by construction -- carried, compared by equality at most,
//     never interpreted, exactly like `area_id`.
//
// If neither holds, the thing being added is game knowledge, and it belongs in the adapter, which
// is free to put whatever it likes inside an opaque field it already has (`extras`, an event
// payload) without the core ever knowing.
var frozenProtocolFields = map[string][]string{
	"State":    {"anim", "area_id", "extras", "orientation", "player_id", "position", "seq", "timestamp"},
	"Envelope": {"payload", "type"},
	// own_area_only (2026-08-28) qualifies under the SECOND test above: it is a bare bool
	// asking the relay to compare two area_ids for equality and forward accordingly. The relay
	// learns nothing about what an area is, exactly as it learns nothing from area_id itself --
	// which is the field it makes the relay act on. It mirrors bridge.Hello.render_all_areas
	// below, already frozen on the same reasoning.
	//
	// name_color, nametags and nametag (2026-08-28) qualify under BOTH tests. A label above a
	// character is not knowledge about any particular game -- every game that can draw a ghost
	// can draw a label over it, which is the "serves two unrelated games" test -- and the core
	// treats both halves as opaque: it sanitizes them for SAFETY and never reads them for
	// meaning, never compares them, never branches on them. Nothing anywhere keys off a name;
	// player_id remains the only identity, which is the property that keeps this cosmetic.
	//
	// The colour is a bare "#RRGGBB" for the same reason area_id is an opaque string: the core
	// can validate its SHAPE without knowing what any game does with it.
	"Hello":   {"display_name", "features", "game_id", "game_version", "max_receive_hz_per_player", "name_color", "own_area_only", "protocol_version", "query_only", "resume_token", "room", "room_code"},
	"Welcome": {"features", "ghost_collision", "nametags", "player_id", "resume_token", "resumed", "roster", "send_hz", "server_time_ms"},
	"Reject":  {"reason"},
	"Join":    {"nametag", "player_id", "state"},
	"Nametag": {"color", "name"},
	"Leave":   {"player_id"},
	"Event":   {"corr_id", "from", "payload", "seq", "to"},
	"Ping":    {"nonce"},
	// own_area_only again, for the same reason it is allowed on Hello: a bool asking the relay
	// to compare two opaque ids for equality teaches it nothing about what an area is. It needs
	// its own message because Hello is sent before the adapter attaches -- see protocol.TypePrefs.
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
	// interpolate_orientation (2026-08-30) qualifies under the SECOND test above and mirrors
	// render_all_areas beside it: a bare bool by which an adapter declares a capability of its
	// OWN -- "my orientation is continuous, so a midpoint between two of them means something".
	// The core learns nothing about the game from it; it does not even learn what an orientation
	// IS, which is precisely why the interpolation happens in the adapter. Bridge-only, so it
	// cannot fragment room compatibility. See bridge.Hello and ADR 0043.
	"Hello":         {"features", "game_id", "game_version", "interpolate_orientation", "render_all_areas"},
	"Event":         {"Event"},
	"Lease":         {"Lease"},
	"LeaseState":    {"LeaseState"},
	"Escrow":        {"Escrow"},
	"EscrowState":   {"EscrowState"},
	"World":         {"World"},
	"WorldState":    {"WorldState"},
	"SessionPolicy": {"ghost_collision"},
	"Reject":        {"reason"},
	"LocalState":    {"state"},
	// orientation_from/orientation_to/interp_t (2026-08-30) qualify under the SECOND test
	// above, and are the cleanest case of it in the list: the two orientation blobs are the
	// SAME opaque bytes `orientation` already is, carried verbatim, and interp_t is a fraction
	// the core computed from two timestamps it owns. The core learns nothing about what an
	// orientation is by saying which pair it used -- it still cannot read either one, which is
	// exactly why the interpolation has to happen in the adapter. bridge only, never
	// protocol.State: nothing here crosses the network. See bridge.RenderRemote.
	"RenderRemote":  {"interp_t", "orientation_from", "orientation_to", "player_id", "state"},
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

// TestWireFieldsAreFrozen fails when a message gains or loses a field without this test being
// updated -- the gate that makes contract creep a decision instead of a drift.
func TestWireFieldsAreFrozen(t *testing.T) {
	protocolSamples := map[string]any{
		"State": protocol.State{}, "Envelope": protocol.Envelope{}, "Hello": protocol.Hello{},
		"Welcome": protocol.Welcome{}, "Reject": protocol.Reject{}, "Join": protocol.Join{},
		"Nametag": protocol.Nametag{},
		"Leave":   protocol.Leave{}, "Event": protocol.Event{}, "Ping": protocol.Ping{},
		"Pong": protocol.Pong{}, "Prefs": protocol.Prefs{},
		"TransportOffer": protocol.TransportOffer{},
		"Transports":     protocol.Transports{}, "Lease": protocol.Lease{},
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

// THE THREE STAY THREE.
//
// User, 2026-08-20: *"I want it to always stay server/client + adapter modular/split, never to
// have all 3 merge into 1-2 things"*. The split is not a filing convention -- it is why the Go
// side can be trusted without a game running, why a relay can host games it has never heard of,
// and why an adapter can be written by someone who never reads `relay/`. Merging any two of them
// would not break a test anywhere before this one, because merging looks like an import.
//
// Each edge below is one of those merges, named by what it would mean:
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

// TestTheThreeStayApart fails when any of those imports appears, in the package or its tests.
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
			// Tests are exempt, and deliberately: `core`'s own tests start a REAL relay to check
			// the client against, which is the harness proving the two halves work together --
			// the opposite of merging them. What must never happen is a shipped package or
			// binary depending on the other side, which is what this walks.
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

// Relay-protocol vocabulary. An adapter that contains any of these is speaking past its own
// bridge, which is `CLAUDE.md`'s "adapters never speak the relay protocol" -- the third leg of the
// split, and the only one that lives outside Go.
var relayOnlyVocabulary = []string{"resume_token", "room_code", "protocol_version"}

// TestAdaptersNeverSpeakTheRelayProtocol reads the adapter sources as text, because they are Lua,
// C# and C++ and there is no other way to hold them to it from here. Vendored dependencies are
// skipped -- what they contain is not ours and not a claim about our split.
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
			if strings.Contains(body, word) {
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
