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

	"github.com/Tsukino-uwu/MeshGhost/internal/textfmt"
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

	// statesSuppressed counts local frames that were NOT sent because the
	// state was identical to the last one sent (see forwardLocalState's
	// change suppression). bracketsSent counts the extra re-statements sent
	// on resume so a receiver never interpolates across a silence. The pair
	// is what says whether suppression is paying: suppressed is the saving,
	// brackets are its cost, and the cost is one packet per resume.
	statesSuppressed uint64
	bracketsSent     uint64

	// prevCarried counts sent states that carried the sample before them
	// (loss cover, ADR 0045); prevRecovered counts received states whose
	// carried prev filled a hole this client had not seen. Recovered is the
	// number that says the link is losing packets, and that the cover is
	// paying: on a clean link it stays 0 while carried climbs with every send.
	prevCarried   uint64
	prevRecovered uint64

	// remotesAgedOut counts peers dropped for going silent rather than for
	// leaving -- see remoteStatesAt. A non-zero value in a healthy session
	// means Leaves are not arriving, which is worth knowing on its own.
	remotesAgedOut uint64
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

	// StatesSuppressed is how many local frames were skipped as identical to
	// the last one sent; BracketsSent is how many extra re-statements were
	// sent on resume to keep interpolation exact.
	StatesSuppressed uint64
	BracketsSent     uint64
	// PrevCarried is how many sent states carried their predecessor as loss
	// cover; PrevRecovered how many received states' carried predecessor
	// filled a sample this client never got. See ADR 0045.
	PrevCarried   uint64
	PrevRecovered uint64

	// RemotesAgedOut is how many peers were despawned for silence rather than
	// for a Leave.
	RemotesAgedOut uint64

	// What the prediction actually did, as opposed to what it was allowed to
	// do. ExtrapolatedRenders counts render-set entries that were predicted
	// rather than interpolated or held; ExtrapolatedAvgMs and ExtrapolatedMaxMs
	// are how far past the newest sample those went; ExtrapolationsCapped is how
	// many hit the configured ceiling, which is the number that says the ceiling
	// is too low rather than merely present.
	ExtrapolatedRenders  uint64
	ExtrapolationsCapped uint64
	ExtrapolatedAvgMs    float64
	ExtrapolatedMaxMs    int64

	// The buffer running dry under a MOVING peer (see dryMeter): renders of a
	// moving peer, how many of them found the render time past the newest
	// sample, and how far past on average and at worst.
	MovingRenders uint64
	DryRenders    uint64
	DryAvgMs      float64
	DryMaxMs      int64

	// Sample transit (see transitMeter): samples timed, mean and worst arrival
	// delay, and how many took longer than slowTransitMs.
	TransitSamples uint64
	TransitAvgMs   float64
	TransitMaxMs   int64
	TransitSlow    uint64

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

// SuppressedShare is the fraction of would-be sends that change suppression
// removed, 0 to 1 -- the honest denominator being everything that reached the
// send path after rate limiting, i.e. what was actually sent plus what was
// skipped. The bracket re-statements are counted as sends, because they are.
func (s Stats) SuppressedShare() float64 {
	total := s.StatesSent + s.StatesSuppressed
	if total == 0 {
		return 0
	}
	return float64(s.StatesSuppressed) / float64(total)
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
		StatesSuppressed:     atomic.LoadUint64(&c.stats.statesSuppressed),
		BracketsSent:         atomic.LoadUint64(&c.stats.bracketsSent),
		PrevCarried:          atomic.LoadUint64(&c.stats.prevCarried),
		PrevRecovered:        atomic.LoadUint64(&c.stats.prevRecovered),
		RemotesAgedOut:       atomic.LoadUint64(&c.stats.remotesAgedOut),
	}
	s.PeersRendered = int(atomic.LoadInt64(&c.renderedNow))
	c.mu.Lock()
	s.ExtrapolatedRenders = c.extrapolation.count
	s.ExtrapolationsCapped = c.extrapolation.cappedHit
	s.ExtrapolatedMaxMs = c.extrapolation.maxMs
	if c.extrapolation.count > 0 {
		s.ExtrapolatedAvgMs = float64(c.extrapolation.totalMs) / float64(c.extrapolation.count)
	}
	s.MovingRenders = c.dry.renders
	s.DryRenders = c.dry.dry
	s.DryMaxMs = c.dry.maxMs
	if c.dry.dry > 0 {
		s.DryAvgMs = float64(c.dry.totalMs) / float64(c.dry.dry)
	}
	s.TransitSamples = c.transit.count
	s.TransitMaxMs = c.transit.maxMs
	s.TransitSlow = c.transit.slow
	if c.transit.count > 0 {
		s.TransitAvgMs = float64(c.transit.totalMs) / float64(c.transit.count)
	}
	s.PeersKnown = len(c.roster)
	s.RelayRTTMs = c.clock.bestRTTMs
	s.ClockOffsetMs = c.clock.offsetMs
	s.ClockMeasured = c.clock.bestRTTMs != 0
	s.Connected = c.relay != nil
	s.PlayerID = c.playerID
	if !c.startedAt.IsZero() {
		s.Uptime = time.Since(c.startedAt) // wall-clock: pairs with startedAt, reported to a human
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
	out += fmt.Sprintf(" | sent %d states (%s, %s)", s.StatesSent, textfmt.Bytes(s.BytesSent), textfmt.PerHour(s.BytesSent, s.Uptime))
	out += fmt.Sprintf(" | received %d msgs (%s, %s)", s.MessagesReceived, textfmt.Bytes(s.BytesReceived), textfmt.PerHour(s.BytesReceived, s.Uptime))
	if s.ExtrapolatedRenders > 0 {
		out += fmt.Sprintf(" | predicted %d renders (avg %.0fms ahead, max %dms, %d hit the cap)",
			s.ExtrapolatedRenders, s.ExtrapolatedAvgMs, s.ExtrapolatedMaxMs, s.ExtrapolationsCapped)
	}
	if s.MovingRenders > 0 {
		out += fmt.Sprintf(" | buffer dry on %d of %d moving renders (avg %.0fms, max %dms past the newest sample)",
			s.DryRenders, s.MovingRenders, s.DryAvgMs, s.DryMaxMs)
	}
	if s.TransitSamples > 0 {
		out += fmt.Sprintf(" | transit: %d samples, avg %.0fms, max %dms, %d over %dms",
			s.TransitSamples, s.TransitAvgMs, s.TransitMaxMs, s.TransitSlow, slowTransitMs)
	}
	if s.StatesSuppressed > 0 {
		out += fmt.Sprintf(" | %d frames suppressed as unchanged (%.0f%% of what would have been sent, %d brackets)",
			s.StatesSuppressed, s.SuppressedShare()*100, s.BracketsSent)
	}
	if s.PrevCarried > 0 || s.PrevRecovered > 0 {
		out += fmt.Sprintf(" | loss cover: %d states carried their predecessor, %d lost samples recovered from it",
			s.PrevCarried, s.PrevRecovered)
	}
	if s.StatesReceived > 0 {
		out += fmt.Sprintf(" | %.0f%% of remote states discarded as cross-area",
			s.CrossAreaShare()*100)
	}
	return out
}
