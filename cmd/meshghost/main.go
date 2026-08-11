// Command meshghost is the desktop app entry point: the core client, wired
// to a relay transport and a local adapter bridge. No behavior yet — this
// exists to prove internal/core, internal/transport, and internal/bridge
// compile together as a real top-level consumer, per the dependency graph
// in agent_docs/architecture.md.
package main

import (
	"fmt"

	"meshghost/internal/core"
)

func main() {
	// core.New requires a transport.Transport; there is no real one to
	// construct yet (internal/transport.NDJSONConn panics — Phase 3 work),
	// so this stops here rather than wiring a fake one. Its purpose is to
	// prove internal/core compiles as a real top-level consumer.
	_ = core.New
	fmt.Println("meshghost: not implemented yet (Phase 0 skeleton) — see agent_docs/plans.md")
}
