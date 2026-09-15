package gameblind_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"testing"
)

// TestRelayCoreAndCmdNeverReadAClientAddress pins the privacy property
// docs/security.md states: the relay does not read a client's IP. Only netx
// may call RemoteAddr -- it must, to demultiplex udp and to name a refused
// connection in a throttled log line -- and from 2026-09-15 it also keeps
// per-source counters there (ADR 0064: in memory, bounded, never logged,
// never persisted).
//
// The relay gets its per-source policy through an interface it calls with
// the net.Conn (relay.Server.SourceGuard), so the address is read on netx's
// side of that line. This test is what keeps a shortcut -- "just split the
// address here" -- from turning that decision into drift. Tests are exempt:
// the hostile harness dials from a known address and may say so.
func TestRelayCoreAndCmdNeverReadAClientAddress(t *testing.T) {
	root := repoRoot(t)
	fset := token.NewFileSet()
	checked := 0
	for _, path := range goFiles(t, root, []string{"relay", "core", "cmd"}) {
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatalf("parsing %s: %v", path, err)
		}
		checked++
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "RemoteAddr" {
				return true
			}
			rel, _ := filepath.Rel(root, path)
			t.Errorf("%s:%d calls RemoteAddr. The relay, the client and cmd/ never read a "+
				"client's address (docs/security.md); per-source policy lives in netx and is "+
				"reached through relay.Server.SourceGuard with the net.Conn.",
				rel, fset.Position(call.Pos()).Line)
			return true
		})
	}
	if checked < 20 {
		t.Fatalf("checked only %d files; the walk is not seeing the packages", checked)
	}
}
