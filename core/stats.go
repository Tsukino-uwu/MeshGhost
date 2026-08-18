package core

// Client-side counters, and the Stats snapshot cmd/meshghost logs on a timer.
//
// This is the client half of what relay's -introspect already does for the
// server. It exists because the core measured several genuinely useful things
// and then showed them to nobody: ClockOffsetMs and RelayRTTMs were exported
// with a comment saying a caller could display them, and until 2026-08-18 no
// caller did, so a large clock offset or a bad link stayed "completely
// invisible" -- the exact thing that comment said exporting them prevented.
//
// Every counter is an atomic add on a path that already exists, never a new
// lock and never per-tick work of its own. CLAUDE.md is blunt that a
// diagnostic can break the thing it measures, and the state path here runs at
// the adapter's frame rate.
//
// Counters are cumulative for the life of the process, NOT per connection:
// they deliberately survive a reconnect, because "how much has this session
// cost me" is the question being asked, and a reconnect resetting the numbers
// would hide exactly the flapping worth noticing. Rates are derived by the
// caller from two snapshots.

import (
	"fmt"
	"sync/atomic"
	"time"
)

// coreStats is the raw counter block. Read through Core.Stats, never directly.
type coreStats struct {
	statesSent uint64
	bytesSent  uint64

	messagesReceived uint64
	bytesReceived    uint64
	statesReceived   uint64

	// statesFilteredByArea counts remotes skipped at render time because
	// their area_id did not match the local player's. This is the client
	// side of the same question relay's cross-area fan-out counters ask: it
	// is bytes that were paid for and then discarded, and it is the number
	// that says how much relay-side filtering would be worth to THIS client.
	statesFilteredByArea uint64

	rendersSent  uint64
	despawnsSent uint64
}

// Stats is one snapshot of what this core has done and what it currently
// believes about its link. Safe to call at any time from any goroutine.
type Stats struct {
	// Uptime is how long this Core has been running, so a reader can turn
	// cumulative counters into rates without keeping a previous sample.
	Uptime time.Duration

	StatesSent uint64
	BytesSent  uint64

	MessagesReceived uint64
	BytesReceived    uint64
	StatesReceived   uint64

	// StatesFilteredByArea is how many remote samples were received, parsed,
	// buffered and then dropped at render time for being in another area.
	StatesFilteredByArea uint64

	RendersSent  uint64
	DespawnsSent uint64

	// PeersKnown is roster size (everyone the relay says is in the room);
	// PeersRendered is how many are currently being drawn. The gap between
	// them is almost always the area filter.
	PeersKnown    int
	PeersRendered int

	// RelayRTTMs is the best round trip measured on this connection, 0 if
	// none has been. ClockOffsetMs is meaningful only when ClockMeasured.
	RelayRTTMs    int64
	ClockOffsetMs int64
	ClockMeasured bool

	Connected bool
	PlayerID  string
}

// CrossAreaShare is the fraction of received state samples this client threw
// away because the sender was somewhere else, 0 to 1. Directly comparable to
// the relay's own cross-area figure, and the two should broadly agree -- if
// they do not, one of them is measuring wrong.
func (s Stats) CrossAreaShare() float64 {
	total := s.StatesReceived
	if total == 0 {
		return 0
	}
	return float64(s.StatesFilteredByArea) / float64(total)
}

// Stats captures the current counters and link state.
func (c *Core) Stats() Stats {
	s := Stats{
		StatesSent:           atomic.LoadUint64(&c.stats.statesSent),
		BytesSent:            atomic.LoadUint64(&c.stats.bytesSent),
		MessagesReceived:     atomic.LoadUint64(&c.stats.messagesReceived),
		BytesReceived:        atomic.LoadUint64(&c.stats.bytesReceived),
		StatesReceived:       atomic.LoadUint64(&c.stats.statesReceived),
		StatesFilteredByArea: atomic.LoadUint64(&c.stats.statesFilteredByArea),
		RendersSent:          atomic.LoadUint64(&c.stats.rendersSent),
		DespawnsSent:         atomic.LoadUint64(&c.stats.despawnsSent),
	}
	s.PeersRendered = int(atomic.LoadInt64(&c.renderedNow))
	c.mu.Lock()
	s.PeersKnown = len(c.roster)
	s.RelayRTTMs = c.clock.bestRTTMs
	s.ClockOffsetMs = c.clock.offsetMs
	s.ClockMeasured = c.clock.bestRTTMs != 0
	s.Connected = c.relay != nil
	s.PlayerID = c.playerID
	if !c.startedAt.IsZero() {
		s.Uptime = time.Since(c.startedAt)
	}
	c.mu.Unlock()
	return s
}

// String renders the one-line form cmd/meshghost logs. Written for a human
// staring at a terminal during a live test, in the units agent_docs asks for
// (a rate they can feel, not a raw byte count).
func (s Stats) String() string {
	link := "not connected"
	if s.Connected {
		link = fmt.Sprintf("connected as %s", s.PlayerID)
		if s.ClockMeasured {
			link += fmt.Sprintf(", rtt %dms, clock offset %dms", s.RelayRTTMs, s.ClockOffsetMs)
		} else {
			link += ", rtt not yet measured"
		}
	}
	out := fmt.Sprintf("meshghost stats: %s | %d peers known, %d rendered", link, s.PeersKnown, s.PeersRendered)
	out += fmt.Sprintf(" | sent %d states (%s, %s)", s.StatesSent, humanBytes(s.BytesSent), perHour(s.BytesSent, s.Uptime))
	out += fmt.Sprintf(" | received %d msgs (%s, %s)", s.MessagesReceived, humanBytes(s.BytesReceived), perHour(s.BytesReceived, s.Uptime))
	if s.StatesReceived > 0 {
		out += fmt.Sprintf(" | %.0f%% of remote states discarded as cross-area",
			s.CrossAreaShare()*100)
	}
	return out
}

// humanBytes and perHour keep the log line in units a person can act on --
// "41 MB/hour" is a number someone can compare against their connection, where
// "11.7 KB/s" is one they have to convert first.
func humanBytes(n uint64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/float64(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/float64(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", n)
	}
}

func perHour(n uint64, uptime time.Duration) string {
	if uptime <= 0 {
		return "rate unknown"
	}
	return humanBytes(uint64(float64(n)/uptime.Hours())) + "/hour"
}
