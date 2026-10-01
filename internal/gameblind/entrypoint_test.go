package gameblind_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

// TestRemoteStateHasOneEntryPoint: a replay file can do only what a stranger's packets can, because both reach the
// core through storeRemoteState, behind protocol.ValidateState, and nothing else does. A new caller in core fails
// here, so a second door is a decision made in this file. The allowed callers are the relay session (a Join's first
// state and every State) and the local-peer feeder every replay and chaser goes through.
func TestRemoteStateHasOneEntryPoint(t *testing.T) {
	root := repoRoot(t)
	allowed := map[string]bool{
		"relaysession.go": true,
		"localpeer.go":    true,
	}
	fset := token.NewFileSet()
	found := 0
	for _, path := range goFiles(t, root, []string{"core"}) {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatalf("parsing %s: %v", path, err)
		}
		base := filepath.Base(path)
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "storeRemoteState" {
				return true
			}
			found++
			if !allowed[base] {
				rel, _ := filepath.Rel(root, path)
				t.Errorf("%s:%d calls storeRemoteState. Remote state has ONE entry point (ADR 0047): "+
					"feed a synthetic peer through feedLocalPeer, and a relay message through the "+
					"session -- never a third path.", rel, fset.Position(call.Pos()).Line)
			}
			return true
		})
	}
	if found < 3 {
		t.Fatalf("found %d storeRemoteState call sites; the relay session has two and the local-peer feeder one -- the walk is not seeing the package", found)
	}
}
