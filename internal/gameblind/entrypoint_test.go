package gameblind_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

// TestRemoteStateHasOneEntryPoint is the structural half of ADR 0047's safety
// argument: a replay file can do exactly what a stranger's packets can do, and
// nothing more, BECAUSE both reach the core through storeRemoteState (with
// protocol.ValidateState in front of it) and nothing else does. This fails the
// build if a new caller appears anywhere in core, so a second door -- a loader
// that "just appends to the buffer", a chaser that skips validation -- is a
// decision made in this file rather than a drift.
//
// The allowed callers, by file: the relay session (a Join's first state and
// every State message) and the local-peer feeder every replay and chaser goes
// through. Tests are exempt: they call it to set up a peer.
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
