package relay

import "time"

// Limits enforced starting Phase 3, per the "Limits" section of
// agent_docs/contract.md. Originally these defended against only a
// malformed or careless peer, not a determined attacker (the relay ran
// no-auth through Phase 4) — the relay-safety work recorded in
// agent_docs/architecture.md's room-code/version ADR adds real
// authentication and audits this file with an adversarial peer in mind, so
// treat the numbers below as tight, not generous, going forward. State
// field limits shared with internal/core (MaxLineBytes, MaxPositionLen,
// MaxExtrasBytes, etc.) live in internal/protocol/limits.go instead of
// here, referenced directly as protocol.* at each call site rather than
// aliased — a review pass found the previous half-aliased state (some
// constants aliased here, some referenced as protocol.* directly at the
// same call sites) confusing.
const (
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

	// DefaultHelloTimeout bounds how long an unauthenticated connection may
	// sit without completing a Hello and joining a room. Without this, a
	// connection that never sends a Hello — or sends other, otherwise-legal
	// messages just to keep transport's idle timeout from firing without
	// ever actually joining — is held open indefinitely, one live goroutine
	// and socket per attempt. See Server.HelloTimeout.
	DefaultHelloTimeout = 10 * time.Second

	// MaxHelloFieldLen bounds every string field of Hello (GameID, Room,
	// DisplayName, RoomCode, GameVersion) — previously unbounded, found
	// while auditing for malicious-peer hardening alongside room-code auth.
	// One shared constant rather than five, since none of these fields has
	// any real reason to differ from the others: a room name, a display
	// name, and a version string are all short human-facing text. Checked
	// before any of them are used to create or look up a room, so an
	// oversized field is refused at the same handshake stage as a bad
	// protocol version or room code, not after doing any work with it.
	MaxHelloFieldLen = 128
)
