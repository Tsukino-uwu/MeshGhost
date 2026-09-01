package relay

import (
	"time"
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
	// 15 since 2026-09-01) the scaled term is 90, so this floor is what
	// applies — the same 120 an unconfigured relay has always enforced. The core does
	// throttle its own send rate (core.Core.MinSendInterval / the room's
	// advertised send_hz, added the same session TEVI's uncapped Update()
	// first tripped this limit for real — see agent_docs/architecture.md's
	// ADR); this floor still sits above that default rate for headroom
	// rather than to compensate for an unthrottled client.
	MaxMessagesPerSecond = 120

	// RateLimitHeadroomMultiple is how many messages per second per client
	// the relay tolerates for each Hz of the room's configured send rate.
	// 6x covers ping/pong heartbeats, scheduling jitter against a fixed
	// tumbling window, and a client that ignores the advertised rate
	// outright — the flood cap is a resource guard, not enforcement of
	// send_hz (nothing anywhere makes a client honor Welcome.SendHz).
	//
	// **A LITERAL AGAIN as of 2026-09-01, and the flip is the point.** It
	// was written as MaxMessagesPerSecond / protocol.DefaultSendHz (120/20)
	// in a 2026-08-16 review pass, so that "a relay left at defaults
	// computes precisely the historical 120" could not silently break. When
	// DefaultSendHz dropped 20 → 15, that derivation would have kept the
	// defaults case right (15 × 8 = 120) while quietly RAISING the cap at
	// every configured rate above the default — a 100Hz room would have gone
	// from 600 to 800 messages/second per client, loosening a resource guard
	// as a side effect of a cosmetic smoothness decision nobody connected to
	// it.
	//
	// So the invariant worth protecting turned out to be the CAP's behaviour,
	// not the arithmetic link: pinned at 6, every configured rate keeps
	// exactly the cap it had, and the default case is unchanged too — 15 × 6
	// = 90 falls under the MaxMessagesPerSecond floor, which returns 120, the
	// same number 20Hz produced. Both properties hold, which is why this is a
	// literal rather than a redivision.
	//
	// The 2026-08-16 lesson still stands where it was aimed (three
	// independent literals in two packages); what it missed is that a derived
	// constant transmits a change to places the change was never reasoned
	// about. A derivation is only safe while every dependant WANTS to move
	// with the source.
	RateLimitHeadroomMultiple = 6

	// DefaultHelloTimeout bounds how long an unauthenticated connection may
	// sit without completing a Hello and joining a room. Without this, a
	// connection that never sends a Hello — or sends other, otherwise-legal
	// messages just to keep transport's idle timeout from firing without
	// ever actually joining — is held open indefinitely, one live goroutine
	// and socket per attempt. See Server.HelloTimeout.
	DefaultHelloTimeout = 10 * time.Second
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
