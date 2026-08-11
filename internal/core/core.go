// Package core is the game-agnostic client: it owns the relay connection,
// the snapshot/interpolation buffer, and remote-player tracking. It talks
// to the relay via internal/transport.Transport and to a real adapter via
// internal/bridge — never to game memory or a rendering primitive directly.
// See agent_docs/contract.md's tick model: the adapter always drives (calls
// in once per frame); the core interpolates and pushes already-interpolated
// state back out.
//
// Hard rule (agent_docs/architecture.md, CLAUDE.md): this package must never
// import anything under adapters/, and must never branch on game_id or any
// other opaque field's contents.
package core

import (
	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// internal/bridge is not imported yet — nothing here uses it until Phase 3
// adds the bridge listener. Per the dependency graph in
// agent_docs/architecture.md, Core is expected to depend on it then.

// Adapter is an in-process Go interface used only by the Phase 5 fake/test
// adapter (one that moves a ghost in a circle, per agent_docs/phases —
// created when that phase starts) and any future in-process host. Real
// adapters — BizHawk Lua today, anything else later — never implement this
// interface; they speak the internal/bridge wire protocol instead. This
// interface exists purely so Phase 5 can prove the core has no game-specific
// leaks without needing a socket at all.
type Adapter interface {
	// GetLocalState returns the current local snapshot. ok == false means
	// "don't send this frame" — the wire equivalent of bridge.LocalState
	// with State == nil.
	GetLocalState() (state protocol.State, ok bool)

	// RenderRemote upserts a remote ghost's state. Called once per core
	// frame tick for every known remote, not only on new network data —
	// see the tick model in agent_docs/contract.md for why.
	RenderRemote(playerID string, state protocol.State)

	// DespawnRemote removes a remote ghost.
	DespawnRemote(playerID string)
}

// Core is the game-agnostic client. No behavior yet — the relay connection,
// interpolation buffer, and bridge listener are Phase 3+ work.
type Core struct {
	// TODO(Phase 3): relay transport.Transport — the relay-protocol
	// connection this Core drives.
	// TODO(Phase 3): bridge listener accepting adapter connections and
	// speaking internal/bridge's message shapes.
	// TODO(Phase 3): per-remote-player interpolation buffer, keyed by
	// player_id, fed by protocol.State messages and drained via
	// bridge.RenderRemote / bridge.DespawnRemote each frame tick.
}

// New wires a Core to a relay transport. No behavior yet.
func New(relay transport.Transport) *Core {
	return &Core{}
}
