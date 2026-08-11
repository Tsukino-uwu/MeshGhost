package relay

// Limits enforced starting Phase 3, per the "Limits" section of
// agent_docs/contract.md. These defend against a malformed or careless
// peer corrupting a room for everyone else in it — not against a
// determined attacker (the relay runs no-auth through Phase 4, see the
// architecture.md ADR), so the numbers below are generous rather than
// tight.
const (
	// MaxLineBytes bounds one NDJSON line (the whole Envelope, including
	// its payload) accepted from a client. Chosen generously above any
	// legitimate state message (a handful of floats plus short opaque
	// strings comfortably fits in a few hundred bytes) while still ruling
	// out a client trying to wedge an unbounded payload through Extras.
	MaxLineBytes = 4096

	// MaxExtrasBytes bounds the serialized size of State.Extras.
	MaxExtrasBytes = 1024

	// MaxPositionLen bounds len(State.Position). The contract deliberately
	// never fixes Position at 2 or 3 components (agent_docs/contract.md),
	// so this is headroom above the largest known real use (3 for a 3D
	// game) rather than a length any adapter should approach.
	MaxPositionLen = 8

	// MaxClientsPerRoom bounds room size. Phase 4's target is two; this
	// leaves room for the roadmap's later multi-peer testing without
	// letting a room grow unbounded.
	MaxClientsPerRoom = 8

	// MaxMessagesPerSecond is a per-client rate limit on the relay
	// protocol. The core does not yet throttle its own send rate (an open
	// question in agent_docs/contract.md — get_local_state can be sampled
	// up to the adapter's frame rate, up to ~60Hz), so this is set well
	// above that rather than at the brief's 10Hz hypothesis, to avoid
	// punishing correct, unthrottled clients.
	MaxMessagesPerSecond = 120
)
