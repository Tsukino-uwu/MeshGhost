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
		if admitted && prevTs != 0 && s.Timestamp-prevTs > replayGapSeamMs {
			ch.c.dropLocalPeer(ch.id)
			ch.c.awaitTick(ch.c.ticksBegun(), 500*time.Millisecond)
			admitted = false
		}
		prevTs = s.Timestamp
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
	name := protocol.SanitizeDisplayName(c.ChaserName)
	color := protocol.SanitizeNameColor(c.ChaserColor)
	room := maxActiveReplays - c.ActiveReplays()
	if count > room {
		log.Printf("core: only %d of %d chasers started: %d local ghosts is the cap and %d replays are active", room, count, maxActiveReplays, c.ActiveReplays())
		count = room
	}

	c.chaserMu.Lock()
	for i := 0; i < count; i++ {
		d := delay + time.Duration(i)*spacing
		tag := protocol.Nametag{Name: name, Color: color}
		if count > 1 && name != "" {
			tag.Name = protocol.SanitizeDisplayName(fmt.Sprintf("%s %d", name, i+1))
		}
		size := int((d + chaserQueueSlack).Milliseconds() / 10) // 100Hz worth
		ch := &chaser{c: c, id: fmt.Sprintf("%s%d", localPeerChaserPrefix, i+1), tag: tag, delay: d,
			in: make(chan protocol.State, size), stop: make(chan struct{}), done: make(chan struct{})}
		c.chasers = append(c.chasers, ch)
		go ch.run()
	}
	c.chaserMu.Unlock()
	if count > 0 {
		log.Printf("core: %d chaser(s) following: the first %s behind, then every %s", count, delay, spacing)
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
