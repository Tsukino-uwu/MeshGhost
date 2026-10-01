package relay

import (
	"time"
)

// State field limits shared with core live in protocol/limits.go, referenced as protocol.* at each call site.
const (
	// DefaultMaxClients bounds how many clients one relay accepts in total, across every room, when a host configures
	// none. A room's traffic grows with the square of its size, so raising it trades the host's bandwidth for seats.
	DefaultMaxClients = 8

	// MaxMessagesPerSecond is the floor of the per-client flood cap; MaxMessagesPerSecondFor scales the cap with
	// send_hz, and at the default send_hz the floor is what applies.
	MaxMessagesPerSecond = 120

	// RateLimitHeadroomMultiple is how many messages per second per client the relay tolerates for each Hz of the
	// room's send rate: room for heartbeats, scheduling jitter and a client that ignores the advertised rate, since
	// the cap is a resource guard, not enforcement of send_hz. A literal on purpose: derived from
	// protocol.DefaultSendHz, lowering that default would silently raise the cap at every configured rate.
	RateLimitHeadroomMultiple = 6

	// DefaultHelloTimeout bounds how long an unauthenticated connection may sit without completing a Hello and
	// joining a room; legal non-Hello messages would otherwise keep it open indefinitely.
	DefaultHelloTimeout = 10 * time.Second
)

// EffectiveMaxClients is the seat count the relay enforces for a configured max_clients: the value itself, or
// DefaultMaxClients when it is zero or negative. One function so the enforcement and the startup banner agree.
func EffectiveMaxClients(configured int) int {
	if configured <= 0 {
		return DefaultMaxClients
	}
	return configured
}

// MaxOpenConnsFor is the per-listener bound on accepted connections, joined or not, applied through
// netx.LimitListener. A real client uses one connection, so every seat can be reconnecting at once with strangers
// knocking, while a flood of never-hello connections stops at a number the host can absorb.
func MaxOpenConnsFor(maxClients int) int {
	if n := maxClients * OpenConnsPerSeat; n > MinMaxOpenConns {
		return n
	}
	return MinMaxOpenConns
}

const (
	OpenConnsPerSeat = 8
	MinMaxOpenConns  = 64
)

// MaxOpenConnsPerSourceFor is the per-address half of MaxOpenConnsFor, applied through netx/srclimit across every
// listener. A client holds one connection at a time, but one address may be a household behind one NAT filling every
// seat; the 2x is a margin for relay-side overlap on a resume or a quic hand-up, not a measurement.
func MaxOpenConnsPerSourceFor(maxClients int) int {
	if n := maxClients * OpenConnsPerSourcePerSeat; n > MinMaxOpenConnsPerSource {
		return n
	}
	return MinMaxOpenConnsPerSource
}

const (
	OpenConnsPerSourcePerSeat = 2
	MinMaxOpenConnsPerSource  = 16
)

// RoomCodeAttemptBurst and RoomCodeAttemptsPerSecond budget wrong room codes per client address, through
// Server.SourceGuard. A code rides both legs of a join, so a burst of 6 is three typos free; an address over budget
// is refused before its code is compared, the right code included. Reasoned from the join's shape, not measured.
const (
	RoomCodeAttemptBurst      = 6
	RoomCodeAttemptsPerSecond = 1.0
)

// rateLimitDrain bounds how long a rate-limited connection is kept half-open after its Reject, so the client's
// remaining flood is read instead of reset: long enough to see the Reject, short enough not to hold a slot.
const rateLimitDrain = 2 * time.Second

// handshakeCloseDrain is the same drain for a handshake's last line (a Reject, or a query-only client's transport
// offer): Close behind unread bytes is a reset, which discards the line still unread in the client's buffer.
const handshakeCloseDrain = 2 * time.Second

// MaxMessagesPerSecondFor returns the per-client flood cap for a room running at sendHz. It only scales up from
// MaxMessagesPerSecond, so turning a room down never drops a client that ignores Welcome.SendHz. Exported so the
// startup banner prints the cap the relay enforces.
func MaxMessagesPerSecondFor(sendHz int) int {
	if limit := sendHz * RateLimitHeadroomMultiple; limit > MaxMessagesPerSecond {
		return limit
	}
	return MaxMessagesPerSecond
}
