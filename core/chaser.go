package core

// The chaser pack: the player's own past, following them (ADR 0047).
//
// "Similar to how Badeline chases Madeline in Celeste": chaser i of count runs
// delay + i*spacing behind the player, so with four or five of them going back
// somewhere you were puts you in a ghost's path (the user's design,
// 2026-09-03). Each chaser is a local peer fed by the same tap the recorder
// uses -- recordLocal writes every stamped in-game sample ONCE into the
// pack's shared history (chaserHistory), and a goroutine per chaser reads it
// at its own cursor, sleeps until sample.Timestamp + its delay, then feeds
// it. No relay, no file: it works offline and costs the adapter exactly what
// count more peers would.
//
// COSMETIC, ALWAYS: a chaser renders with cosmetic=true like every local
// peer. The only effect it may ever have is the contact hook,
// session_policy.chaser_contact, which an adapter honours only under its own
// per-game ADR and the user's on-screen confirmation -- none exists yet.
//
// A live gap longer than replayGapSeamMs (a menu, a loading screen, nil
// frames) is a seam for every chaser, so the pack reappears where the player
// is rather than gliding there from where they were.

import (
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

const (
	// No cap on the chaser COUNT since 2026-09-06 (the user's call: "allow
	// people to do as much as their game can handle"). The 8 that stood here
	// was hit by a tester the day before. What remains is the roster:
	// protocol.MaxRosterSize seats shared with every real peer, which is what
	// bounds startChasers below -- past it admitLocalPeer refuses anyway.
	//
	// maxChaserBehind caps how far behind the player any chaser may run.
	// FOUND BY THE EVERYTHING-FUZZER on its first run (2026-09-03): a legal
	// config of count 8 and spacing 48h asked the eighth chaser for a queue
	// sized to 336 hours of samples -- make(chan, 120 million) on the bridge
	// goroutine, which is where the next adapter's hello is answered. The
	// game sat with no bridge_ready for seconds, and the test saw a core
	// that had stopped ticking. A chaser ten minutes behind is already a
	// ghost of a different session; anything past this is clamped and logged.
	//
	// SINCE THE SHARED HISTORY (below) THE COUNT NO LONGER MULTIPLIES THIS.
	// One ring is sized to the DEEPEST chaser's delay, so this clamp alone
	// bounds the pack's whole memory at ~7.7MB however many chasers there are.
	maxChaserBehind = 10 * time.Minute
	// chaserHistorySlack is how much beyond the deepest chaser's delay the
	// shared history holds, at chaserOfferIntervalMs. It is the margin a
	// chaser goroutine may fall behind the writer before the samples it has
	// not read yet are overwritten -- see chaserHistory.read's `lapped`.
	//
	// "At the adapter's fastest rate" is what this used to say, and it was
	// not: the sizing assumed 100Hz while Pseudoregalia sends ~180, so every
	// chaser more than ~6s behind filled its queue, lost a hole longer than
	// the seam threshold, and cycled despawn/respawn on the player with a
	// period of delay+spawn (2026-09-05, watched live). The tap now thins to
	// the rate assumed here, which turns the sizing into an invariant instead
	// of a hope.
	chaserHistorySlack = 2 * time.Second
	// chaserOfferIntervalMs is the minimum spacing, in gameplay milliseconds,
	// between samples the tap hands to the pack -- 100 a second, the rate the
	// history is sized for. A chaser renders through interpolation and never
	// needed more.
	chaserOfferIntervalMs = 10
)

// chaserHistory is the pack's shared past: ONE copy of the player's recent
// samples, read by every chaser at its own offset.
//
// IT REPLACED A PRIVATE CHANNEL PER CHASER, and the reason is arithmetic.
// Every chaser replays the same stream lagged by a different amount, so a
// queue each meant N copies of overlapping history: a tester's 512-pack at
// 1s spacing sized 13.2 million protocol.State slots -- 1.69 GB of channel
// buffer, allocated on the bridge goroutine the instant the adapter attached,
// and again on every reconnect (measured 2026-09-07). One ring sized to the
// deepest delay holds 51,400 slots for the same pack: ~6.6MB, a ~220x cut,
// and it is flat in the count rather than quadratic.
//
// THE OVERWRITE DIRECTION IS THE OTHER HALF. A full channel dropped the
// NEWEST sample for that chaser, punching a hole into the middle of its
// trail that it could not see -- the 2026-09-05 despawn/respawn cycle. A
// full ring overwrites the OLDEST instead, so a chaser that cannot keep up
// loses the far end of its own past and is TOLD it happened (`lapped`),
// which it renders as a seam. Both are degradation; only one is honest.
type chaserHistory struct {
	mu  sync.Mutex
	buf []protocol.State
	// next is the global index of the next write; the sample written at
	// global index i lives at buf[i%len(buf)]. Monotonic and never reset,
	// so a reader's cursor stays meaningful across any number of wraps.
	next int64
	// notify is closed and replaced on every write: the broadcast a chaser
	// waiting for a sample that does not exist yet selects on, alongside its
	// own stop. A channel rather than a sync.Cond precisely because a chaser
	// must be able to abandon the wait, which Cond cannot express. Cold in
	// practice -- a chaser is at least its delay behind the writer, so it
	// only waits at the very start of a pack.
	notify chan struct{}
}

func newChaserHistory(slots int) *chaserHistory {
	if slots < 1 {
		slots = 1
	}
	return &chaserHistory{buf: make([]protocol.State, slots), notify: make(chan struct{})}
}

// add records one sample and wakes every waiting chaser. Never blocks and
// never fails: this runs on the adapter's frame path, where the rule is that
// nothing the pack does may cost the frame anything.
func (h *chaserHistory) add(s protocol.State) {
	h.mu.Lock()
	h.buf[h.next%int64(len(h.buf))] = s
	h.next++
	woken := h.notify
	h.notify = make(chan struct{})
	h.mu.Unlock()
	close(woken)
}

// read returns the sample at global index i.
//
// ok=false means the history has not reached i yet, and `wait` is the channel
// to block on until it might have. Both are decided under ONE lock so a
// sample landing between the check and the wait cannot be missed -- the
// classic lost-wakeup, and the only subtle thing in this type.
//
// lapped=true means i had already been overwritten: this reader fell more
// than chaserHistorySlack behind the writer. `got` is then the oldest sample
// that still survives, which is where the caller resumes, and the gap it
// jumped is a seam.
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

// written is how many samples the history has ever taken, which is also the
// index a chaser starting now would read first.
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
	// spawn is how long the player must have been moving before this chaser
	// may appear (the user's rule, 2026-09-03: no chaser spawns on top of a
	// player who has not moved yet).
	spawn time.Duration
	// hist is the pack's shared history, read at this chaser's own cursor.
	hist *chaserHistory
	stop chan struct{}
	done chan struct{}
	once sync.Once
}

func (ch *chaser) halt() { ch.once.Do(func() { close(ch.stop) }) }

func (ch *chaser) run() {
	defer close(ch.done)
	defer ch.c.dropLocalPeer(ch.id)
	admitted := false
	var prevTs int64
	// movingSince is the timestamp of the first sample that differed from
	// the one before it since the last (re)start; zero until then. A sample
	// is skipped -- not delayed -- until the player has been moving for the
	// spawn window, so the chaser's first appearance is `delay` behind a
	// player who is already on the move, never a copy of one standing still.
	var movingSince int64
	var prevPos []float64
	// cursor is this chaser's read position in the shared history, in the
	// history's own global index space. It starts at 0 because StartChasers
	// builds a fresh history for each pack, so index 0 is the pack's first
	// sample.
	var cursor int64
	for {
		s, got, lapped, ok, wait := ch.hist.read(cursor)
		if !ok {
			// Nothing recorded yet at this cursor -- the start of a pack,
			// or a game that has stopped sending frames.
			select {
			case <-ch.stop:
				return
			case <-wait:
			}
			continue
		}
		cursor = got + 1
		due := s.Timestamp + ch.delay.Milliseconds()
		// A gap in the LIVE stream (menu, loading, nil frames): seam, so the
		// chaser reappears rather than gliding across the hole. `lapped` is
		// the same thing from the other end -- this goroutine fell far enough
		// behind that the history overwrote what it had not read, so its
		// trail has a hole whatever the timestamps say.
		if lapped || (prevTs != 0 && s.Timestamp-prevTs > replayGapSeamMs) {
			if admitted {
				ch.c.dropLocalPeer(ch.id)
				ch.c.awaitTick(ch.c.ticksBegun(), 500*time.Millisecond, ch.stop)
				admitted = false
			}
			// The spawn window starts over after a gap: the player is
			// standing wherever they reappeared.
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
		// Sleep in slices so a stop is prompt. GAMEPLAY time on both sides
		// (ADR 0053): the stamp came from gameplayStamp and the clock here
		// stands still while the adapter says the player is frozen, so a
		// pause menu costs this chaser no delay -- it holds where it is and
		// resumes the same distance behind, instead of spending the pause
		// converging onto a player who cannot move.
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
			case <-time.After(wait): // wall-clock: the SLEEP; its due time comes from nowMs, which is virtual
			}
		}
		if !admitted {
			if !ch.c.admitLocalPeer(ch.id, ch.tag) {
				log.Printf("core: %s: the roster is full, not following", ch.id)
				return
			}
			admitted = true
		}
		// Back to the WALL clock for the render side, which interpolates every
		// local peer against nowMs: the wall instant `due` fell on is exactly
		// (wall now - gameplay now) later than the gameplay instant, since no
		// freeze can sit between a passed due time and now.
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
	// One snapshot under c.mu, which is what guards these fields everywhere
	// else (pushSessionPolicy reads them the same way): the caller is the
	// bridge goroutine on attach, so reading them bare races anything that
	// sets them. Sanitising and clamping happen on the copies, off the lock.
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
	// A fresh pack starts on a fresh gameplay clock: the accumulator only
	// ever means "since these chasers began", and this runs on attach, where
	// the adapter's first frozen report is still to come.
	c.frozenMu.Lock()
	c.frozenSince, c.frozenTotalMs = 0, 0
	c.frozenMu.Unlock()

	// THE DEEPEST DELAY SIZES THE WHOLE PACK, once, because the history is
	// shared: every chaser reads the same ring at its own offset, so the
	// count does not enter the sizing at all. Computed before the loop so
	// the ring exists before the first goroutine can read it.
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

// StopChasers halts the pack and drops its ghosts.
func (c *Core) StopChasers() {
	c.chaserMu.Lock()
	pack := c.chasers
	c.chasers = nil
	// Released with the pack: the ring is the pack's memory, and holding it
	// past a stop would keep the deepest chaser's whole delay alive for a
	// session that no longer has chasers in it.
	c.chaserHist = nil
	c.chaserMu.Unlock()
	if len(pack) == 0 {
		return
	}
	c.rearmTap()
	for _, ch := range pack {
		ch.halt()
	}
	// ONE second for the WHOLE PACK, not one per chaser (2026-09-08). This
	// used to be a fresh time.After per member, so the total wait was the
	// count times a second -- and the count has been uncapped since
	// 2026-09-06. The starved pack is exactly the pack that misses its joins
	// (an adapter that cannot keep up is what starves these goroutines), and
	// StopChasers runs on the bridge's hello goroutine, so the wait sat
	// directly across the attach path: a relaunched game that had already been
	// told bridge_ready hung there with no error, and finishBridgeTeardown
	// stalled behind it too.
	//
	// A shared budget rather than no budget: a goroutine that is about to
	// finish is still joined, and once the second is spent the rest are
	// checked without blocking -- one that has already closed done is joined
	// at zero cost, and one that has not is left to exit on its own, which it
	// does the moment it next reads ch.stop. Its ghost is gone either way,
	// because dropLocalPeer below is unconditional.
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

// SetPlayerFrozen is the bridge's player_frozen message (ADR 0053): the
// adapter says the game is holding the player still outside gameplay, or has
// let go. Only a CHANGE does anything, so an adapter may repeat itself. The
// chaser pack is the one consumer; nothing else in the core reads this.
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

// gameplayNowMs is nowMs with every frozen span taken out -- the clock a
// chaser sleeps on. It stands still for as long as the adapter says the
// player is frozen.
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

// gameplayStamp converts the tap's wall stamp of a frame taken NOW into the
// gameplay clock, or reports false for a frame taken while frozen -- which
// the chaser must never see (recorder.go says why).
func (c *Core) gameplayStamp(wallMs int64) (int64, bool) {
	c.frozenMu.Lock()
	defer c.frozenMu.Unlock()
	if c.frozenSince != 0 {
		return 0, false
	}
	return wallMs - c.frozenTotalMs, true
}

// offerChasers is recordLocal's hand-off: one lock and ONE write, however
// many chasers are following, only while a pack exists (tapArmed covers the
// "nothing armed" case). It used to be a non-blocking send per chaser, which
// made the frame path's cost linear in the count -- 512 channel sends per
// sample -- on top of the memory the private queues cost.
func (c *Core) offerChasers(s protocol.State) {
	c.chaserMu.Lock()
	hist := c.chaserHist
	c.chaserMu.Unlock()
	if hist != nil {
		hist.add(s)
	}
}
