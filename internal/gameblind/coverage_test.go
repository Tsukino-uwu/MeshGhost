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

// TestEveryWireShapeIsCoveredByTheFrozenGate: every json-tagged struct protocol and bridge declare must be in
// TestWireFieldsAreFrozen's maps, which otherwise see only the shapes someone remembered to list. It parses the source
// because reflection cannot enumerate the types a package declares.
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

// wireStructsIn returns the exported structs in dir with at least one json-tagged field, this repo's definition of
// crossing a wire; a _test.go fixture is not a wire shape.
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

// frozenNamesFor reads the sample-map literals out of gameblind_test.go, so the maps stay beside the reasoning for each
// entry and are still checkable.
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
		// Keys are quoted and values never are, so every odd piece is a name; extras are harmless, since this map is
		// only asked whether a name is present.
		if part != "" && !strings.ContainsAny(part, "{}:,= \t\n") {
			out[part] = true
		}
	}
	if len(out) == 0 {
		t.Fatalf("parsed no names out of %s -- see the note above", want)
	}
	return out
}
