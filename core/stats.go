package core

// Client-side counters, and the Stats snapshot cmd/meshghost logs on a timer: the client half of what the relay's
// -introspect does for the server.
//
// Every counter is an atomic add on a path that already exists, never a new lock or per-tick work of its own: a
// diagnostic can break what it measures, and the state path runs at the adapter's frame rate.
//
// Counters are cumulative for the life of the process, not per connection: a reconnect resetting them would hide the
// flapping worth noticing. Rates are derived by the caller from two snapshots.

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

	// statesFilteredByArea counts remotes skipped at render time for another area_id: bytes paid for and discarded, and
	// what relay-side filtering would be worth to this client.
	statesFilteredByArea uint64

	rendersSent  uint64
	despawnsSent uint64

	// statesSuppressed counts local frames not sent because they matched the last one sent; bracketsSent counts the
	// re-statements sent on resume so a receiver never interpolates across a silence. The saving and its cost.
	statesSuppressed uint64
	bracketsSent     uint64

	// prevCarried counts sent states that carried the sample before them as loss cover; prevRecovered counts received
	// states whose carried prev filled a hole. Recovered says the link is losing packets and the cover is paying; on a
	// clean link it stays 0.
	prevCarried   uint64
	prevRecovered uint64

	// remotesAgedOut counts peers dropped for silence rather than a Leave; non-zero in a healthy session means Leaves
	// are not arriving.
	remotesAgedOut uint64
	// remotesReturned counts aged-out peers re-admitted by a fresh state, such as a paused emulator resuming: zero on a
	// healthy link, and equal to the age-outs in a room of players who alt-tab.
	remotesReturned uint64

	// rendersSuperseded counts ghost positions replaced in the bridge's outbound queue before the adapter read them:
	// zero means the adapter kept up, and a climbing value means the bridge is the limit and the adapter gets the
	// freshest positions. That is the design, not a fault.
	rendersSuperseded uint64
}

// Stats is one snapshot of what this core has done and believes about its link. Safe from any goroutine.
type Stats struct {
	// Uptime turns the cumulative counters into rates without a previous sample.
	Uptime time.Duration

	StatesSent uint64
	BytesSent  uint64

	MessagesReceived uint64
	BytesReceived    uint64
	StatesReceived   uint64

	// StatesFilteredByArea is how many remote samples were received and buffered, then dropped at render time for being
	// in another area.
	StatesFilteredByArea uint64

	RendersSent  uint64
	DespawnsSent uint64

	// StatesSuppressed is how many local frames were skipped as identical to the last one sent; BracketsSent how many
	// re-statements were sent on resume to keep interpolation exact.
	StatesSuppressed uint64
	BracketsSent     uint64
	// PrevCarried is how many sent states carried their predecessor as loss cover; PrevRecovered how many received ones
	// filled a sample this client never got.
	PrevCarried   uint64
	PrevRecovered uint64

	// RemotesAgedOut is how many peers were despawned for silence rather than for a Leave.
	RemotesAgedOut uint64

	// RemotesReturned is how many of those came back: states resumed under the same id, retaking a seat without a Join.
	RemotesReturned uint64

	// RendersSuperseded is how many ghost positions were replaced in the bridge queue before the adapter read them: how
	// far behind the game has been running.
	RendersSuperseded uint64

	// What the prediction did: ExtrapolatedRenders counts renders predicted rather than interpolated or held, AvgMs and
	// MaxMs how far past the newest sample they went, and ExtrapolationsCapped how many hit the ceiling, which says the
	// ceiling is too low rather than merely present.
	ExtrapolatedRenders  uint64
	ExtrapolationsCapped uint64
	ExtrapolatedAvgMs    float64
	ExtrapolatedMaxMs    int64

	// The buffer running dry under a moving peer (dryMeter): moving renders, how many found the render time past the
	// newest sample, and how far past on average and at worst.
	MovingRenders uint64
	DryRenders    uint64
	DryAvgMs      float64
	DryMaxMs      int64
	// DryP50Ms/P95/P99 are percentiles of how far past the newest sample the dry renders ran, to the 10ms bucket edge:
	// the window extrapolate would have to cover to fill that share of the gaps.
	DryP50Ms int64
	DryP95Ms int64
	DryP99Ms int64

	// Sample transit (see transitMeter): samples timed, mean and worst arrival
	// delay, and how many took longer than slowTransitMs.
	TransitSamples uint64
	TransitAvgMs   float64
	TransitMaxMs   int64
	TransitSlow    uint64
	// TransitP50Ms/P95/P99 are percentiles of the same arrival delay, to the 10ms bucket edge. A delay sized for a link
	// must cover its high percentile, which the mean hides and the max overstates.
	TransitP50Ms int64
	TransitP95Ms int64
	TransitP99Ms int64

	// PeersKnown is the roster size, PeersRendered how many are drawn now; the gap is almost always the area filter.
	PeersKnown    int
	PeersRendered int

	// RelayRTTMs is the best round trip on this connection, 0 if none yet. ClockOffsetMs means something only when
	// ClockMeasured.
	RelayRTTMs    int64
	ClockOffsetMs int64
	ClockMeasured bool

	Connected bool
	PlayerID  string
}

// CrossAreaShare is the fraction of received state samples discarded because the sender was elsewhere, 0 to 1. It
// should broadly agree with the relay's own cross-area figure; if not, one of them is measuring wrong.
func (s Stats) CrossAreaShare() float64 {
	total := s.StatesReceived
	if total == 0 {
		return 0
	}
	return float64(s.StatesFilteredByArea) / float64(total)
}

// SuppressedShare is the fraction of would-be sends change suppression removed, 0 to 1, over everything that reached
// the send path after rate limiting. Brackets count as sends, because they are.
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
		RemotesReturned:      atomic.LoadUint64(&c.stats.remotesReturned),
		RendersSuperseded:    atomic.LoadUint64(&c.stats.rendersSuperseded),
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
	s.DryP50Ms = c.dry.hist.percentile(50, c.dry.maxMs)
	s.DryP95Ms = c.dry.hist.percentile(95, c.dry.maxMs)
	s.DryP99Ms = c.dry.hist.percentile(99, c.dry.maxMs)
	s.TransitSamples = c.transit.count
	s.TransitMaxMs = c.transit.maxMs
	s.TransitSlow = c.transit.slow
	if c.transit.count > 0 {
		s.TransitAvgMs = float64(c.transit.totalMs) / float64(c.transit.count)
	}
	s.TransitP50Ms = c.transit.hist.percentile(50, c.transit.maxMs)
	s.TransitP95Ms = c.transit.hist.percentile(95, c.transit.maxMs)
	s.TransitP99Ms = c.transit.hist.percentile(99, c.transit.maxMs)
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

// String renders the one-line form cmd/meshghost logs, for a person watching a live test: rates they can feel, not raw
// byte counts.
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
	if s.RendersSuperseded > 0 {
		out += fmt.Sprintf(" | %d stale ghost position(s) superseded before the game read them (it is behind, not broken)", s.RendersSuperseded)
	}
	if s.MovingRenders > 0 {
		out += fmt.Sprintf(" | buffer dry on %d of %d moving renders (avg %.0fms, p50 %dms, p95 %dms, p99 %dms, max %dms past the newest sample)",
			s.DryRenders, s.MovingRenders, s.DryAvgMs, s.DryP50Ms, s.DryP95Ms, s.DryP99Ms, s.DryMaxMs)
	}
	if s.TransitSamples > 0 {
		out += fmt.Sprintf(" | transit: %d samples, avg %.0fms, p50 %dms, p95 %dms, p99 %dms, max %dms, %d over %dms",
			s.TransitSamples, s.TransitAvgMs, s.TransitP50Ms, s.TransitP95Ms, s.TransitP99Ms, s.TransitMaxMs, s.TransitSlow, slowTransitMs)
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
