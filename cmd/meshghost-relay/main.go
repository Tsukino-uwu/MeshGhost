// Command meshghost-relay is the standalone relay entry point. No behavior
// yet — exists to prove internal/relay and internal/transport compile
// together as a real top-level consumer, per the dependency graph in
// agent_docs/architecture.md.
package main

import (
	"fmt"

	"meshghost/internal/relay"
)

func main() {
	// Referenced to prove internal/relay compiles as a real top-level
	// consumer; not constructed for real yet — Room has no working methods
	// before Phase 3.
	_ = relay.Room{}
	fmt.Println("meshghost-relay: not implemented yet (Phase 0 skeleton) — see agent_docs/plans.md")
}
