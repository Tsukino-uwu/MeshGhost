package gameblind_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// EVERY WIRE SHAPE MUST BE IN THE FROZEN-FIELDS GATE, and until 2026-09-11
// nothing checked that (review J9).
//
// TestWireFieldsAreFrozen compares a hand-written sample map against a
// hand-written frozen-field map. It errors when a FROZEN entry has no sample --
// and it has nothing at all to say about a type that was never added to either.
// So the gate protected exactly the shapes somebody remembered to list, and a
// new message type was invisible to it by default, which is the wrong default
// for a gate whose whole job is noticing what changed.
//
// Five shapes had escaped that way (`BridgeReady`, `RemoteName`,
// `RecordingState`, `PlayerFrozen`, and `protocol.StatePrev`'s nine fields).
// Listing those five is the fix for those five; this is the fix for the next
// one, which is the one nobody will be looking for.
//
// The source is parsed rather than reflected over, because reflection cannot
// enumerate the types a package DECLARES -- only the ones something already
// mentions, which is the same blind spot one level down.
func TestEveryWireShapeIsCoveredByTheFrozenGate(t *testing.T) {
	for _, pkg := range []struct {
		dir   string
		which string
	}{
		{filepath.Join("..", "..", "protocol"), "protocol"},
		{filepath.Join("..", "..", "bridge"), "bridge"},
	} {
		declared := wireStructsIn(t, pkg.dir)
		covered := frozenNamesFor(t, pkg.which)
		var missing []string
		for _, name := range declared {
			if !covered[name] {
				missing = append(missing, name)
			}
		}
		if len(missing) > 0 {
			sort.Strings(missing)
			t.Errorf("%s declares %d wire shape(s) the frozen-fields gate has never seen: %v\n"+
				"Every struct with json tags in this package crosses a wire, so every one of them "+
				"is a place game knowledge can enter. Add it to BOTH maps in "+
				"TestWireFieldsAreFrozen -- the sample and the frozen field list -- and read the "+
				"burden of proof above frozenProtocolFields before you do.",
				pkg.which, len(missing), missing)
		}
	}
}

// wireStructsIn returns the names of exported structs in dir that have at least
// one json-tagged field -- which is this repo's definition of "crosses a wire".
// _test.go files are skipped: a test's own fixture is not a wire shape.
func wireStructsIn(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	fset := token.NewFileSet()
	var out []string
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, filepath.Join(dir, e.Name()), nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", e.Name(), err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			ts, ok := n.(*ast.TypeSpec)
			if !ok || !ts.Name.IsExported() {
				return true
			}
			st, ok := ts.Type.(*ast.StructType)
			if !ok {
				return true
			}
			for _, field := range st.Fields.List {
				if field.Tag != nil && strings.Contains(field.Tag.Value, "json:") {
					out = append(out, ts.Name.Name)
					return true
				}
			}
			return true
		})
	}
	sort.Strings(out)
	return out
}

// frozenNamesFor reads the sample-map literals out of gameblind_test.go itself.
// Parsing the test rather than exporting a list from it keeps the two maps where
// they are readable -- next to the reasoning that justifies each entry -- and
// still makes them checkable.
func frozenNamesFor(t *testing.T, which string) map[string]bool {
	t.Helper()
	src, err := os.ReadFile("gameblind_test.go")
	if err != nil {
		t.Fatalf("read gameblind_test.go: %v", err)
	}
	want := "protocolSamples := map[string]any{"
	if which == "bridge" {
		want = "bridgeSamples := map[string]any{"
	}
	text := string(src)
	i := strings.Index(text, want)
	if i < 0 {
		t.Fatalf("could not find %q in gameblind_test.go -- the gate was restructured and this "+
			"check is now reading nothing, which is the exact failure it exists to prevent", want)
	}
	end := strings.Index(text[i:], "\n\t}")
	if end < 0 {
		t.Fatal("could not find the end of the sample map")
	}
	body := text[i : i+end]

	out := map[string]bool{}
	for _, part := range strings.Split(body, "\"") {
		// Keys are the quoted strings; values are package selectors and never
		// quoted, so every odd-indexed piece is a name. Collecting all of them
		// and letting extras through is fine: this map is only ever asked
		// "is X present".
		if part != "" && !strings.ContainsAny(part, "{}:,= \t\n") {
			out[part] = true
		}
	}
	if len(out) == 0 {
		t.Fatalf("parsed no names out of %s -- see the note above", want)
	}
	return out
}
