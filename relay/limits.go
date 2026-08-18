package relay

import (
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Limits enforced starting Phase 3, per the "Limits" section of
// agent_docs/contract.md. Originally these defended against only a
// malformed or careless peer, not a determined attacker (the relay ran
// no-auth through Phase 4) — the relay-safety work recorded in
// agent_docs/architecture.md's room-code/version ADR adds real
// authentication and audits this file with an adversarial peer in mind, so
// treat the numbers below as tight, not generous, going forward. State
// field limits shared with core (MaxLineBytes, MaxPositionLen,
// MaxExtrasBytes, etc.) live in protocol/limits.go instead of
// here, referenced directly as protocol.* at each call site rather than
// aliased — a review pass found the previous half-aliased state (some
// constants aliased here, some referenced as protocol.* directly at the
// same call sites) confusing.
const (
	// DefaultMaxClients bounds how many clients a single relay accepts in
	// total, across every room it's hosting, when a host doesn't configure
	// one (see Server.MaxClients). This is server-wide, not per room: two
	// rooms don't each get their own DefaultMaxClients worth of headroom.
	// Room.Forward fans every state message out to every other member of
	// its own room, so traffic within a room grows roughly with the square
	// of that room's size, not linearly — a host who raises this a lot and
	// then lets it all pile into one room is trading their own relay's
	// bandwidth/CPU for more seats, not something to size up casually. No
	// enforced ceiling: a host who wants more than the default is free to
	// configure it and find out.
	DefaultMaxClients = 8

	// MaxMessagesPerSecond is the FLOOR of the per-client flood cap, not the
	// cap itself since the send/receive rate-control feature (see the ADR in
	// agent_docs/architecture.md): the real cap is
	// max(MaxMessagesPerSecond, sendHz*RateLimitHeadroomMultiple), computed
	// by MaxMessagesPerSecondFor below, so a relay configured for a faster
	// send_hz gets proportionally more headroom instead of tripping this
	// flat number outright. At the default send_hz (protocol.DefaultSendHz,
	// 20), the computed cap is exactly this constant's historical value —
	// 120 — so an unconfigured relay's behavior is unchanged. The core does
	// throttle its own send rate (core.Core.MinSendInterval / the room's
	// advertised send_hz, added the same session TEVI's uncapped Update()
	// first tripped this limit for real — see agent_docs/architecture.md's
	// ADR); this floor still sits above that default rate for headroom
	// rather than to compensate for an unthrottled client.
	MaxMessagesPerSecond = 120

	// RateLimitHeadroomMultiple is how many messages per second per client
	// the relay tolerates for each Hz of the room's configured send rate.
	// 6x is not a fresh judgement: it is exactly MaxMessagesPerSecond /
	// protocol.DefaultSendHz (120/20), chosen so a relay left at defaults
	// computes precisely the historical hardcoded 120 and this scaling
	// changes nothing for an existing deployment. The headroom covers
	// ping/pong heartbeats, scheduling jitter against a fixed tumbling
	// window, and a client that ignores the advertised rate outright — the
	// flood cap is a resource guard, not enforcement of send_hz (nothing
	// anywhere makes a client honor Welcome.SendHz).
	// Derived, not a literal, so the stated relationship can't silently
	// break if protocol.DefaultSendHz changes (found in a review pass
	// 2026-08-16: all three were independent literals in two packages).
	RateLimitHeadroomMultiple = MaxMessagesPerSecond / protocol.DefaultSendHz

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

// MaxMessagesPerSecondFor returns the per-client flood cap for a room running
// at sendHz. It only ever scales UP from MaxMessagesPerSecond: lowering a
// relay's send_hz must never start disconnecting clients that are still
// sending at their own built-in default rate — an older client, or any
// client with an explicit local override, never sees Welcome.SendHz at all
// or deliberately ignores it, and none of them deserve to be dropped just
// because the operator turned the room down.
//
// Exported so a caller outside this package (cmd/meshghost-relay, which
// prints the cap to the operator at startup) reports the number the relay
// actually enforces. It had hand-copied the formula, which would have made
// the startup banner lie the moment this rule changed — found in a review
// pass 2026-08-16. An unexported alias in front of this one was deleted in
// the 2026-08-18 audit: it only duplicated the doc comment.
func MaxMessagesPerSecondFor(sendHz int) int {
	if limit := sendHz * RateLimitHeadroomMultiple; limit > MaxMessagesPerSecond {
		return limit
	}
	return MaxMessagesPerSecond
}
