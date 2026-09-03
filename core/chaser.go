package core

// The chaser pack: the player's own past, following them (ADR 0047).
//
// "Similar to how Badeline chases Madeline in Celeste": chaser i of count runs
// delay + i*spacing behind the player, so with four or five of them going back
// somewhere you were puts you in a ghost's path (the user's design,
// 2026-09-03). Each chaser is a local peer fed by the same tap the recorder
// uses -- recordLocal hands every stamped in-game sample to every chaser's
// channel, and a goroutine per chaser sleeps until sample.Timestamp + its
// delay, then feeds it. No relay, no file: it works offline and costs the
// adapter exactly what count more peers would.
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
	maxChasers = 8
	// maxChaserBehind caps how far behind the player any chaser may run.
	// FOUND BY THE EVERYTHING-FUZZER on its first run (2026-09-03): a legal
	// config of count 8 and spacing 48h asked the eighth chaser for a queue
	// sized to 336 hours of samples -- make(chan, 120 million) on the bridge
	// goroutine, which is where the next adapter's hello is answered. The
	// game sat with no bridge_ready for seconds, and the test saw a core
	// that had stopped ticking. A chaser ten minutes behind is already a
	// ghost of a different session; anything past this is clamped and logged.
	maxChaserBehind = 10 * time.Minute
	// chaserQueueSlack is how much beyond its delay a chaser's channel
	// holds, at the adapter's fastest rate. A full channel drops the NEWEST
	// sample for that chaser (the player is outrunning the drain, which
	// means the goroutine stalled); nothing blocks the frame.
	chaserQueueSlack = 2 * time.Second
)

type chaser struct {
	c     *Core
	id    string
	tag   protocol.Nametag
	delay time.Duration
	// spawn is how long the player must have been moving before this chaser
	// may appear (the user's rule, 2026-09-03: no chaser spawns on top of a
	// player who has not moved yet).
	spawn time.Duration
	in    chan protocol.State
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
	// movingSince is the timestamp of the first sample that differed from
	// the one before it since the last (re)start; zero until then. A sample
	// is skipped -- not delayed -- until the player has been moving for the
	// spawn window, so the chaser's first appearance is `delay` behind a
	// player who is already on the move, never a copy of one standing still.
	var movingSince int64
	var prevPos []float64
	for {
		var s protocol.State
		select {
		case <-ch.stop:
			return
		case s = <-ch.in:
		}
		due := s.Timestamp + ch.delay.Milliseconds()
		// A gap in the LIVE stream (menu, loading, nil frames): seam, so the
		// chaser reappears rather than gliding across the hole.
		if prevTs != 0 && s.Timestamp-prevTs > replayGapSeamMs {
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
		// Sleep in slices so a stop is prompt.
		for {
			now := ch.c.nowMs()
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
			case <-time.After(wait):
			}
		}
		if !admitted {
			if !ch.c.admitLocalPeer(ch.id, ch.tag) {
				log.Printf("core: %s: the roster is full, not following", ch.id)
				return
			}
			admitted = true
		}
		s.Timestamp = due
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

// offer hands one stamped sample to a chaser without ever blocking the
// adapter's frame.
func (ch *chaser) offer(s protocol.State) {
	select {
	case ch.in <- s:
	default:
	}
}

// StartChasers builds the pack from the Chaser* fields and starts following.
// Called when the adapter attaches; safe to call again.
func (c *Core) StartChasers() int {
	c.StopChasers()
	if !c.ChaserEnabled {
		return 0
	}
	count := c.ChaserCount
	if count < 1 {
		count = 1
	}
	if count > maxChasers {
		log.Printf("core: chaser count %d clamped to %d", count, maxChasers)
		count = maxChasers
	}
	delay := c.ChaserDelay
	if delay <= 0 {
		delay = 3 * time.Second
	}
	spacing := c.ChaserSpacing
	if spacing < 0 {
		spacing = 0
	}
	spawn := c.ChaserSpawnDelay
	if spawn <= 0 {
		spawn = delay
	}
	name := protocol.SanitizeDisplayName(c.ChaserName)
	color := protocol.SanitizeNameColor(c.ChaserColor)
	room := maxActiveReplays - c.ActiveReplays()
	if count > room {
		log.Printf("core: only %d of %d chasers started: %d local ghosts is the cap and %d replays are active", room, count, maxActiveReplays, c.ActiveReplays())
		count = room
	}

	c.chaserMu.Lock()
	clamped := false
	for i := 0; i < count; i++ {
		d := delay + time.Duration(i)*spacing
		if d > maxChaserBehind {
			d = maxChaserBehind
			clamped = true
		}
		tag := protocol.Nametag{Name: name, Color: color}
		if count > 1 && name != "" {
			tag.Name = protocol.SanitizeDisplayName(fmt.Sprintf("%s %d", name, i+1))
		}
		size := int((d + chaserQueueSlack).Milliseconds() / 10) // 100Hz worth
		ch := &chaser{c: c, id: fmt.Sprintf("%s%d", localPeerChaserPrefix, i+1), tag: tag, delay: d, spawn: spawn,
			in: make(chan protocol.State, size), stop: make(chan struct{}), done: make(chan struct{})}
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
	c.chaserMu.Unlock()
	if len(pack) == 0 {
		return
	}
	c.rearmTap()
	for _, ch := range pack {
		ch.halt()
	}
	for _, ch := range pack {
		select {
		case <-ch.done:
		case <-time.After(time.Second):
		}
		c.dropLocalPeer(ch.id)
	}
}

// offerChasers is recordLocal's hand-off: one lock, one non-blocking send per
// chaser, only while a pack exists (tapArmed covers the "nothing armed" case).
func (c *Core) offerChasers(s protocol.State) {
	c.chaserMu.Lock()
	pack := c.chasers
	c.chaserMu.Unlock()
	for _, ch := range pack {
		ch.offer(s)
	}
}
