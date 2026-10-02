package core

// The chaser pack: the player's own past following them, chaser i delay + i*spacing behind. recordLocal writes each
// stamped sample once into the pack's shared history, and a goroutine per chaser reads it at its own cursor and feeds
// it as a local peer when due. A chaser always renders cosmetic; its only possible effect is ChaserContact.

import (
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// ChaserContact is what touching a chaser does to the player, carried to the adapter as
// session_policy.chaser_contact: "hurt" is an enemy's touch in that game, "kill" a death, "off" (the default) nothing.
// The core only carries the word; an adapter triggers the game's own damage or death path and never writes health.
type ChaserContact string

const (
	ChaserContactOff  ChaserContact = "off"
	ChaserContactHurt ChaserContact = "hurt"
	ChaserContactKill ChaserContact = "kill"
)

// ParseChaserContact reads the config value. The legacy bool still reads, "true" as hurt and "false" as off, so an
// older config keeps its meaning; empty is off.
func ParseChaserContact(s string) (ChaserContact, error) {
	switch s {
	case "", "off", "false":
		return ChaserContactOff, nil
	case "hurt", "true":
		return ChaserContactHurt, nil
	case "kill":
		return ChaserContactKill, nil
	}
	return ChaserContactOff, fmt.Errorf("chaser.contact %q is not a mode -- use \"off\", \"hurt\" or \"kill\"", s)
}

// Active reports whether the mode is anything but off; the zero value is off, so an unset Core pushes no policy.
func (m ChaserContact) Active() bool {
	return m == ChaserContactHurt || m == ChaserContactKill
}

const (
	// maxChaserBehind caps how far behind any chaser may run, and so the shared history's size whatever the count. A
	// chaser ten minutes behind is already a ghost of a different session.
	maxChaserBehind = 10 * time.Minute
	// chaserHistorySlack is how far a chaser goroutine may fall behind the writer before unread samples are
	// overwritten (see chaserHistory.read's lapped).
	chaserHistorySlack = 2 * time.Second
	// chaserOfferIntervalMs is the minimum gameplay-ms spacing between samples the tap hands the pack: the 100 a
	// second the history is sized for, whatever rate the adapter sends at. A chaser interpolates and needs no more.
	chaserOfferIntervalMs = 10
)

// chaserHistory is the pack's shared past: one copy of the player's recent samples, read by every chaser at its own
// offset, so its memory is flat in the count. A full ring overwrites the oldest and tells a reader that fell behind
// (lapped), which renders as a seam rather than a hole in the trail it cannot see.
type chaserHistory struct {
	mu  sync.Mutex
	buf []protocol.State
	// next is the global index of the next write, never reset, so a cursor survives any number of wraps; sample i
	// lives at buf[i%len(buf)].
	next int64
	// notify is closed and replaced on every write: a channel, not a sync.Cond, because a waiting chaser must be able
	// to abandon the wait on stop.
	notify chan struct{}
}

func newChaserHistory(slots int) *chaserHistory {
	if slots < 1 {
		slots = 1
	}
	return &chaserHistory{buf: make([]protocol.State, slots), notify: make(chan struct{})}
}

// add records one sample and wakes every waiting chaser. It never blocks: it runs on the adapter's frame path.
func (h *chaserHistory) add(s protocol.State) {
	h.mu.Lock()
	h.buf[h.next%int64(len(h.buf))] = s
	h.next++
	woken := h.notify
	h.notify = make(chan struct{})
	h.mu.Unlock()
	close(woken)
}

// read returns the sample at global index i. ok=false means the history has not reached i yet; wait is taken under
// the same lock, so a sample landing between the check and the wait cannot be missed. lapped=true means i was
// overwritten: got is then the oldest surviving sample, where the caller resumes, and the jump is a seam.
func (h *chaserHistory) read(i int64) (s protocol.State, got int64, lapped bool, ok bool, wait <-chan struct{}) {
	h.mu.Lock()
	defer h.mu.Unlock()
	span := int64(len(h.buf))
	oldest := h.next - span
	if oldest < 0 {
		oldest = 0
	}
	if i < oldest {
		i, lapped = oldest, true
	}
	if i >= h.next {
		return protocol.State{}, i, false, false, h.notify
	}
	return h.buf[i%span], i, lapped, true, nil
}

// written is how many samples the history has ever taken: the index a chaser starting now reads first.
func (h *chaserHistory) written() int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.next
}

type chaser struct {
	c     *Core
	id    string
	tag   protocol.Nametag
	delay time.Duration
	// spawn is how long the player must have been moving before this chaser may appear, so none spawns on top of a
	// player who has not moved.
	spawn time.Duration
	hist  *chaserHistory
	stop  chan struct{}
	done  chan struct{}
	once  sync.Once
}

func (ch *chaser) halt() { ch.once.Do(func() { close(ch.stop) }) }

func (ch *chaser) run() {
	defer close(ch.done)
	defer ch.c.dropLocalPeer(ch.id)
	admitted := false
	var prevTs int64
	// movingSince is the stamp of the first sample that moved since the last (re)start, zero until then. Samples are
	// skipped, not delayed, until the spawn window has passed, so the first appearance is never a standing copy.
	var movingSince int64
	var prevPos []float64
	// cursor starts at 0 because StartChasers builds a fresh history for each pack.
	var cursor int64
	for {
		s, got, lapped, ok, wait := ch.hist.read(cursor)
		if !ok {
			select {
			case <-ch.stop:
				return
			case <-wait:
			}
			continue
		}
		cursor = got + 1
		due := s.Timestamp + ch.delay.Milliseconds()
		// A gap in the live stream (a menu, a load) is a seam, so the chaser reappears rather than gliding across the
		// hole; lapped is the same hole seen from this end.
		if lapped || (prevTs != 0 && s.Timestamp-prevTs > replayGapSeamMs) {
			if admitted {
				ch.c.dropLocalPeer(ch.id)
				ch.c.awaitTick(ch.c.ticksBegun(), 500*time.Millisecond, ch.stop)
				admitted = false
			}
			// The player is standing wherever they reappeared, so the spawn window starts over.
			movingSince, prevPos = 0, nil
		}
		prevTs = s.Timestamp
		if !admitted {
			if movingSince == 0 {
				if prevPos != nil && !samePosition(prevPos, s.Position) {
					movingSince = s.Timestamp
				}
				prevPos = append(prevPos[:0], s.Position...)
				if movingSince == 0 {
					continue
				}
			}
			if s.Timestamp-movingSince < ch.spawn.Milliseconds() {
				continue
			}
		}
		// Sleep in slices so a stop is prompt. Gameplay time on both sides, so a pause holds the chaser the same
		// distance behind instead of converging onto a player who cannot move.
		var now int64
		for {
			now = ch.c.gameplayNowMs()
			if now >= due {
				break
			}
			wait := time.Duration(due-now) * time.Millisecond
			if wait > 50*time.Millisecond {
				wait = 50 * time.Millisecond
			}
			select {
			case <-ch.stop:
				return
			case <-time.After(wait): // wall-clock: the sleep; its due time comes from nowMs, which is virtual
			}
		}
		if !admitted {
			if !ch.c.admitLocalPeer(ch.id, ch.tag) {
				log.Printf("core: %s: the roster is full, not following", ch.id)
				return
			}
			admitted = true
		}
		// Back to the wall clock, which the render side interpolates against: due fell (wall now - gameplay now) later
		// in wall time, since no freeze can sit between a passed due time and now.
		s.Timestamp = ch.c.nowMs() - now + due
		if !ch.c.feedLocalPeer(ch.id, s) {
			select {
			case <-ch.stop:
				return
			default:
			}
			// Dropped from outside; re-admit on the next sample.
			admitted = false
		}
	}
}

// StartChasers builds the pack from the Chaser* fields and starts following.
// Called when the adapter attaches; safe to call again.
func (c *Core) StartChasers() int {
	c.StopChasers()
	// One snapshot under c.mu, which guards these fields; reading them bare races the live setters.
	c.mu.Lock()
	enabled, count, delay := c.ChaserEnabled, c.ChaserCount, c.ChaserDelay
	spacing, spawn := c.ChaserSpacing, c.ChaserSpawnDelay
	rawName, rawColor := c.ChaserName, c.ChaserColor
	c.mu.Unlock()
	if !enabled {
		return 0
	}
	if count < 1 {
		count = 1
	}
	if count > protocol.MaxRosterSize {
		log.Printf("core: chaser count %d clamped to %d, the roster's whole size", count, protocol.MaxRosterSize)
		count = protocol.MaxRosterSize
	}
	if delay <= 0 {
		delay = 3 * time.Second
	}
	if spacing < 0 {
		spacing = 0
	}
	if spawn <= 0 {
		spawn = delay
	}
	name := protocol.SanitizeDisplayName(rawName)
	color := protocol.SanitizeNameColor(rawColor)
	// A fresh pack starts a fresh gameplay clock; on attach the adapter's first frozen report is still to come.
	c.frozenMu.Lock()
	c.frozenSince, c.frozenTotalMs = 0, 0
	c.frozenMu.Unlock()

	// The deepest delay sizes the shared history once; the count does not enter it.
	deepest := delay + time.Duration(count-1)*spacing
	clamped := deepest > maxChaserBehind
	if clamped {
		deepest = maxChaserBehind
	}
	hist := newChaserHistory(int((deepest + chaserHistorySlack).Milliseconds() / 10)) // 100Hz worth

	c.chaserMu.Lock()
	c.chaserHist = hist
	for i := 0; i < count; i++ {
		d := delay + time.Duration(i)*spacing
		if d > maxChaserBehind {
			d = maxChaserBehind
		}
		tag := protocol.Nametag{Name: name, Color: color}
		if count > 1 && name != "" {
			tag.Name = protocol.SanitizeDisplayName(fmt.Sprintf("%s %d", name, i+1))
		}
		ch := &chaser{c: c, id: fmt.Sprintf("%s%d", localPeerChaserPrefix, i+1), tag: tag, delay: d, spawn: spawn,
			hist: hist, stop: make(chan struct{}), done: make(chan struct{})}
		c.chasers = append(c.chasers, ch)
		go ch.run()
	}
	c.chaserMu.Unlock()
	if clamped {
		log.Printf("core: chaser delay+spacing reaches past %s; the far chasers are clamped to that", maxChaserBehind)
	}
	if count > 0 {
		log.Printf("core: %d chaser(s) following: the first %s behind, then every %s; none appears until you have been moving for %s", count, delay, spacing, spawn)
		// After the unlock: rearmTap takes chaserMu itself.
		c.rearmTap()
	}
	return count
}

// chaserResetMinGap is how close two chaser_resets may land and both act: a reset rebuilds the history, so a reset
// per frame (a bug, a stuck edge) must not rebuild it every frame, while a death and its reload are seconds apart.
const chaserResetMinGap = time.Second

// ResetChasers is the bridge's chaser_reset: the running pack starts over as if play had just begun. It reports the
// new pack's size and whether it acted: a stopped pack stays stopped, and a reset within chaserResetMinGap of the
// last is ignored.
func (c *Core) ResetChasers() (int, bool) {
	now := c.nowMs()
	c.chaserMu.Lock()
	running := len(c.chasers) > 0
	recent := c.chaserResetAtMs != 0 && now-c.chaserResetAtMs < chaserResetMinGap.Milliseconds()
	if running && !recent {
		c.chaserResetAtMs = now
	}
	c.chaserMu.Unlock()
	if !running || recent {
		return 0, false
	}
	return c.StartChasers(), true
}

// StopChasers halts the pack and drops its ghosts.
func (c *Core) StopChasers() {
	c.chaserMu.Lock()
	pack := c.chasers
	c.chasers = nil
	// Released with the pack, or the deepest chaser's whole delay stays alive.
	c.chaserHist = nil
	c.chaserMu.Unlock()
	if len(pack) == 0 {
		return
	}
	c.rearmTap()
	for _, ch := range pack {
		ch.halt()
	}
	// One second for the whole pack, not per chaser: this runs on the bridge's hello goroutine, across the attach
	// path. Past the budget a straggler exits on its next read of ch.stop, and its ghost goes either way.
	budget := time.NewTimer(time.Second) // wall-clock: a shutdown join -- virtual would turn a leak into a hang
	defer budget.Stop()
	spent := false
	for _, ch := range pack {
		if spent {
			select {
			case <-ch.done:
			default:
			}
		} else {
			select {
			case <-ch.done:
			case <-budget.C:
				spent = true
			}
		}
		c.dropLocalPeer(ch.id)
	}
}

// SetPlayerFrozen is the bridge's player_frozen: the game is holding the player still outside gameplay, or has let
// go. Only a change acts, so an adapter may repeat itself; the chaser pack is the one consumer.
func (c *Core) SetPlayerFrozen(frozen bool) {
	now := c.nowMs()
	c.frozenMu.Lock()
	was := c.frozenSince != 0
	if frozen && !was {
		c.frozenSince = now
	} else if !frozen && was {
		c.frozenTotalMs += now - c.frozenSince
		c.frozenSince = 0
	}
	total := c.frozenTotalMs
	c.frozenMu.Unlock()
	if frozen != was {
		if frozen {
			log.Printf("core: player frozen (adapter): the chaser pack holds")
		} else {
			log.Printf("core: player resumed (adapter): the chaser pack follows again, %s of pauses excluded so far", time.Duration(total)*time.Millisecond)
		}
	}
}

// gameplayNowMs is nowMs with every frozen span taken out: the clock a chaser sleeps on.
func (c *Core) gameplayNowMs() int64 {
	now := c.nowMs()
	c.frozenMu.Lock()
	defer c.frozenMu.Unlock()
	g := now - c.frozenTotalMs
	if c.frozenSince != 0 {
		g -= now - c.frozenSince
	}
	return g
}

// gameplayStamp converts the tap's wall stamp of a frame taken now into gameplay time, or reports false for a frame
// taken while frozen, which the chaser must never see.
func (c *Core) gameplayStamp(wallMs int64) (int64, bool) {
	c.frozenMu.Lock()
	defer c.frozenMu.Unlock()
	if c.frozenSince != 0 {
		return 0, false
	}
	return wallMs - c.frozenTotalMs, true
}

// offerChasers is recordLocal's hand-off: one lock and one write however many chasers follow.
func (c *Core) offerChasers(s protocol.State) {
	c.chaserMu.Lock()
	hist := c.chaserHist
	c.chaserMu.Unlock()
	if hist != nil {
		hist.add(s)
	}
}
