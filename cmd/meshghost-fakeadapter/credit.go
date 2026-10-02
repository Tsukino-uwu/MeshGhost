package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// creditConfig is the flag-derived configuration for this plane.
type creditConfig struct {
	on         bool
	enemies    int
	hitEvery   time.Duration
	resetEvery time.Duration
	// dupEvery is how often a client re-sends its previous report: a real transport never duplicates, so traffic
	// alone would never exercise invariant 9.
	dupEvery time.Duration
	// deathEvery and deathFor are this client's own synthetic death windows, for invariants 15 and 16.
	deathEvery time.Duration
	deathFor   time.Duration
}

// The report vocabulary, opaque to the relay: it rides the event plane as a real adapter's payload would.
const (
	creditHit   = "hit"
	creditReset = "reset"
	creditDeath = "death"
)

// creditMsg is one report on the ledger, made up and opaque to the core and relay.
type creditMsg struct {
	Op  string `json:"op"`
	Key string `json:"key"`
	Gen uint64 `json:"gen"`
	// DealerSeq is the sender's own counter; with its player_id it identifies a report for invariant 9. The relay's
	// stamp would not: it is unique per delivery, so a duplicate gets a new one.
	DealerSeq uint64 `json:"dseq"`
	// Amt is damage in the dealer's own units and Scale the dealer's own maximum; foldHit turns the pair into a
	// fraction every client agrees on.
	Amt   float64 `json:"amt,omitempty"`
	Scale float64 `json:"scale,omitempty"`
	// At and Frac are carried only by a death report: the relay stamp of the report that crossed zero and the
	// accumulated fraction then, so participants can check agreement (invariant 13).
	At   uint64  `json:"at,omitempty"`
	Frac float64 `json:"frac,omitempty"`
}

// encounter is one client's fold of one (enemy, generation) pair.
type encounter struct {
	// scale is the ratchet: the running maximum difficulty of every client that has damaged this enemy.
	scale float64
	// total is the public fold, the share of the fight dealt by everyone, advanced whether this client fights or
	// not; frac is what its own copy has taken. A bystander needs the total to adopt when it first swings.
	total float64
	frac  float64
	// applied is the exactly-once set, keyed by dealer and dealer sequence.
	applied map[string]bool
	// participant is whether this client has damaged it, which decides whether the fold touches its own copy.
	participant bool
	// dead, deathAt and deathFrac are this client's own copy's death; announced is whether the room has been told.
	dead      bool
	deathAt   uint64
	deathFrac float64
	announced bool
	// sawStart is whether this client watched the generation from its first report; a mid-fight joiner folds a
	// different prefix, so it is not judged against anyone else's.
	sawStart bool
	// credited records that this client took the reward, for invariants 14 and 15.
	credited bool
	// diedWhileDown records that the kill landed inside one of this client's own death windows (invariant 15).
	diedWhileDown bool
}

// creditChecker is one client's view of the kill-credit plane: clients damage shared synthetic enemies over the
// event plane, and each folds the same ordered ledger and decides for itself whether its copy died and whether it
// earned the reward. Each derives a death from the same ordered damage rather than being told of it, which makes the
// model checkable without a game. The enemies and numbers are invented; the ordering, the folding rule and these
// invariants are real:
//  9. exactly-once: a report already applied never moves the fold again;
//  10. monotonic scale: an encounter's difficulty ratchet never decreases within a generation, in any arrival order;
//  11. no resurrection: a copy dead for a generation stays dead, whatever report or ratchet comes later;
//  12. generation isolation: a report from an older generation never touches the current one;
//  13. death agreement: two participants that both watched a generation from its start compute the same killing
//     stamp for it;
//  14. no credit without participation: no reward for an enemy this client never damaged;
//  15. no credit while dead: no reward for a kill that landed while this client was dead;
//  16. no liveness without participation: a non-participant's copy never dies.
//
// Ordering is checkSeq's, since every report rides a stamped event. It has its own lock because the receive
// callback and the attack goroutine both drive it.
type creditChecker struct {
	cfg    creditConfig
	self   string
	scale  float64
	report func(format string, args ...any)

	mu sync.Mutex
	// enc is every (enemy, generation) this client has folded, keyed by encKey and kept after death for invariants
	// 11 and 13.
	enc map[string]*encounter
	gen map[string]uint64
	// alive is this client's own synthetic liveness, under mu so the death window and the fold agree when a kill
	// lands.
	alive bool
	// lastSent is the previous report per enemy, for the duplicate injector to re-send.
	lastSent map[string]creditMsg
	dealerNo uint64

	hits     atomic.Uint64
	kills    atomic.Uint64
	rewards  atomic.Uint64
	stale    atomic.Uint64
	resets   atomic.Uint64
	agreedOn atomic.Uint64
}

func newCreditChecker(cfg creditConfig, self string, scale float64, report func(string, ...any)) *creditChecker {
	return &creditChecker{
		cfg:      cfg,
		self:     self,
		scale:    scale,
		report:   report,
		enc:      make(map[string]*encounter),
		gen:      make(map[string]uint64),
		alive:    true,
		lastSent: make(map[string]creditMsg),
	}
}

// enemyKey is the opaque per-enemy key; a real adapter's would name the game, the area and the enemy.
func enemyKey(i int) string { return fmt.Sprintf("enemy%d", i) }

// encKey pairs an enemy with a generation in one key, so no lookup reads another generation's state.
func encKey(key string, gen uint64) string { return key + "#" + strconv.FormatUint(gen, 10) }

// splitEncKey is encKey's inverse; the last '#' is the separator.
func splitEncKey(k string) (string, uint64) {
	i := strings.LastIndex(k, "#")
	if i < 0 {
		return k, 0
	}
	gen, err := strconv.ParseUint(k[i+1:], 10, 64)
	if err != nil {
		return k[:i], 0
	}
	return k[:i], gen
}

// atGen returns the fold for one generation, creating it on first sight. Caller must hold c.mu. Only a reset passes
// first, as the one event that proves this client saw the generation begin, so invariant 13 says nothing about an
// enemy's first generation or a run with -enemy-reset-every 0.
func (c *creditChecker) atGen(key string, gen uint64, first bool) *encounter {
	k := encKey(key, gen)
	e := c.enc[k]
	if e == nil {
		e = &encounter{applied: make(map[string]bool), sawStart: first}
		c.enc[k] = e
	}
	return e
}

// onEvent folds one report: the whole model.
func (c *creditChecker) onEvent(ev protocol.Event) {
	var msg creditMsg
	if err := json.Unmarshal(ev.Payload, &msg); err != nil || msg.Key == "" {
		// Not a credit report: the control plane's own events share this plane.
		return
	}
	switch msg.Op {
	case creditHit:
		c.foldHit(ev, msg)
	case creditReset:
		c.foldReset(msg)
	case creditDeath:
		c.onDeathReport(ev, msg)
	}
}

// foldHit applies one damage report; every arithmetic rule of the model lives here.
func (c *creditChecker) foldHit(ev protocol.Event, msg creditMsg) {
	c.mu.Lock()
	defer c.mu.Unlock()

	cur, known := c.gen[msg.Key]
	if !known {
		// Adopt the report's generation rather than assuming zero, or a late joiner discards everything as stale.
		c.gen[msg.Key] = msg.Gen
		cur = msg.Gen
	}
	if msg.Gen != cur {
		if msg.Gen < cur {
			// Invariant 12: a report in flight across a reset is correctly discarded, so it is counted, not reported.
			c.stale.Add(1)
			return
		}
		// Ahead of its own reset: impossible from a correct sender, and adopting it would drag the room forward.
		c.report("client %s got a report for %s at generation %d while it is at %d "+
			"-- a generation cannot run ahead of the reset that created it",
			c.self, msg.Key, msg.Gen, cur)
		return
	}

	// Never first: only a reset proves this client watched the generation from its start.
	e := c.atGen(msg.Key, msg.Gen, false)
	id := ev.From + ":" + strconv.FormatUint(msg.DealerSeq, 10)
	if e.applied[id] {
		// Invariant 9: a duplicate arriving is normal, applying it is not, so the test asserts the fold did not move.
		return
	}
	e.applied[id] = true

	// Ratchet first, then divide: the other order would value a Hard player's first hit against an Easy player's bar.
	prevScale := e.scale
	if msg.Scale > e.scale {
		e.scale = msg.Scale
	}
	if e.scale < prevScale {
		// Invariant 10: structural above, asserted so a max turned into an assignment fails.
		c.report("client %s lowered %s's scale from %g to %g -- the ratchet must never go down",
			c.self, msg.Key, prevScale, e.scale)
		e.scale = prevScale
	}
	if e.scale <= 0 {
		return
	}
	// The ledger is public, applying it to this copy is not: a bystander's total advances too.
	if ev.From == c.self && e.total < 1 {
		// Joining only while the fight is on: a swing at an enemy already down buys no share of it.
		e.participant = true
	}
	e.total += msg.Amt / e.scale

	if !e.participant || e.dead {
		// Invariant 11: once dead, later reports move the public total and never this copy.
		return
	}
	// Catch-up: a client folding all along already equals the total, one that just joined snaps to it.
	e.frac = e.total
	c.hits.Add(1)

	if e.frac < 1 {
		return
	}
	e.dead = true
	e.deathAt = ev.Seq
	e.deathFrac = e.frac
	c.kills.Add(1)
	if !e.participant {
		// Invariant 16: unreachable by construction, asserted so moving the participation gate cannot break it quietly.
		c.report("client %s had %s die on its own copy without ever damaging it "+
			"-- a non-participant's copy must never take a point of the ledger",
			c.self, msg.Key)
	}
	if c.alive {
		e.credited = true
		c.rewards.Add(1)
	} else {
		e.diedWhileDown = true
	}
}

// foldReset moves an enemy to a new generation. Idempotent by generation, so any client may issue one without
// coordinating: two resets from one generation name the same successor.
func (c *creditChecker) foldReset(msg creditMsg) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if msg.Gen <= c.gen[msg.Key] {
		return
	}
	c.gen[msg.Key] = msg.Gen
	// A client that saw the reset watched this generation from its start.
	c.atGen(msg.Key, msg.Gen, true)
	c.resets.Add(1)
}

// onDeathReport is invariant 13: two participants that both watched a generation from its start crossed zero on the
// same report.
func (c *creditChecker) onDeathReport(ev protocol.Event, msg creditMsg) {
	if ev.From == c.self {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.enc[encKey(msg.Key, msg.Gen)]
	if e == nil || !e.dead || !e.sawStart {
		// A mid-fight joiner folded a different prefix; judging it would report the rig's join time as a defect.
		return
	}
	if e.deathAt != msg.At {
		c.report("client %s killed %s at stamp %d but %s killed it at stamp %d "+
			"-- two participants folding one ordered ledger disagreed about when it died",
			c.self, msg.Key, e.deathAt, ev.From, msg.At)
		return
	}
	if math.Abs(e.deathFrac-msg.Frac) > 1e-9 {
		c.report("client %s and %s agree %s died at stamp %d but not on the total dealt "+
			"(%.12f vs %.12f) -- the fold is order-dependent somewhere it must not be",
			c.self, ev.From, msg.Key, msg.At, e.deathFrac, msg.Frac)
		return
	}
	c.agreedOn.Add(1)
}

// checkCredit is invariants 14 and 15, run once at the end: they are about what a client walked away with.
func (c *creditChecker) checkCredit() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, e := range c.enc {
		if !e.credited {
			continue
		}
		if !e.participant {
			c.report("client %s took the reward for %s without ever damaging it "+
				"-- damage is the only thing that buys participation", c.self, k)
		}
		if !e.dead {
			c.report("client %s took the reward for %s, which never died on its own copy",
				c.self, k)
		}
		if e.diedWhileDown {
			c.report("client %s took the reward for %s even though the kill landed while it was dead "+
				"-- tag it once and die is worth nothing", c.self, k)
		}
	}
}

// setAlive opens or closes this client's death window and reports whether it changed.
func (c *creditChecker) setAlive(alive bool) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.alive == alive {
		return false
	}
	c.alive = alive
	return true
}

// nextReport builds this client's next hit on one enemy, or false when the room's ledger already has it dead.
func (c *creditChecker) nextReport(key string) (creditMsg, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	gen := c.gen[key]
	if e := c.enc[encKey(key, gen)]; e != nil && e.total >= 1 {
		// The public total, since a bystander's copy never dies and no adapter hits an enemy the room has killed.
		return creditMsg{}, false
	}
	c.dealerNo++
	// A fixed share of this client's own scale, so a fight takes the same number of hits at any difficulty.
	msg := creditMsg{
		Op: creditHit, Key: key, Gen: gen, DealerSeq: c.dealerNo,
		Amt: c.scale / 8, Scale: c.scale,
	}
	c.lastSent[key] = msg
	return msg, true
}

// lastReport returns the previous report for an enemy, for the duplicate injector.
func (c *creditChecker) lastReport(key string) (creditMsg, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	msg, ok := c.lastSent[key]
	return msg, ok
}

// deathToAnnounce returns one death this client has not yet told the room about; without announcing, invariant 13
// could never see a disagreement.
func (c *creditChecker) deathToAnnounce() (creditMsg, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, e := range c.enc {
		if !e.dead || e.announced || !e.participant {
			continue
		}
		e.announced = true
		key, gen := splitEncKey(k)
		return creditMsg{
			Op: creditDeath, Key: key, Gen: gen,
			At: e.deathAt, Frac: e.deathFrac,
		}, true
	}
	return creditMsg{}, false
}

// resetToIssue names the successor generation for one enemy.
func (c *creditChecker) resetToIssue(i int) creditMsg {
	key := enemyKey(i)
	c.mu.Lock()
	defer c.mu.Unlock()
	return creditMsg{Op: creditReset, Key: key, Gen: c.gen[key] + 1}
}

// stats formats this plane's counters, stale reports included, as one line.
func (c *creditChecker) stats() string {
	return fmt.Sprintf("hits=%d kills=%d rewards=%d agreed=%d resets=%d stale=%d",
		c.hits.Load(), c.kills.Load(), c.rewards.Load(),
		c.agreedOn.Load(), c.resets.Load(), c.stale.Load())
}

// runCredit drives this client's credit traffic until stop closes: attack, re-send a report, reset an enemy,
// announce its own kills, and go in and out of its own death windows.
func (cp *controlPlane) runCredit(stop <-chan struct{}, wg *sync.WaitGroup, cfg creditConfig) {
	defer wg.Done()

	c := cp.credit
	hit := time.NewTicker(atLeast(cfg.hitEvery, 100*time.Millisecond))
	defer hit.Stop()
	reset := tickerOrNil(cfg.resetEvery)
	defer stopTicker(reset)
	dup := tickerOrNil(cfg.dupEvery)
	defer stopTicker(dup)
	death := tickerOrNil(cfg.deathEvery)
	defer stopTicker(death)
	// On its own short tick, so a client that stopped attacking still announces.
	announce := time.NewTicker(200 * time.Millisecond)
	defer announce.Stop()

	target, resetTarget := 0, 0
	for {
		select {
		case <-stop:
			c.checkCredit()
			return

		case <-hit.C:
			key := enemyKey(target % max1(cfg.enemies))
			target++
			if msg, ok := c.nextReport(key); ok {
				cp.sendCredit(msg)
			}

		case <-dup:
			// Invariant 9's traffic: a real transport never duplicates a reliable event.
			if msg, ok := c.lastReport(enemyKey(target % max1(cfg.enemies))); ok {
				cp.sendCredit(msg)
			}

		case <-reset:
			cp.sendCredit(c.resetToIssue(resetTarget % max1(cfg.enemies)))
			resetTarget++

		case <-announce.C:
			for {
				msg, ok := c.deathToAnnounce()
				if !ok {
					break
				}
				cp.sendCredit(msg)
			}

		case <-death:
			if c.setAlive(false) {
				time.AfterFunc(cfg.deathFor, func() { c.setAlive(true) })
			}
		}
	}
}

// sendCredit puts one report on the event plane, broadcast to the room.
func (cp *controlPlane) sendCredit(msg creditMsg) {
	payload, err := json.Marshal(msg)
	if err != nil {
		return
	}
	if err := cp.core.SendEvent(protocol.Event{Payload: payload}); err != nil {
		log.Printf("meshghost-fakeadapter: client %d could not send a %s report: %v",
			cp.index, msg.Op, err)
	}
}

func atLeast(d, floor time.Duration) time.Duration {
	if d <= 0 {
		return floor
	}
	return d
}

// creditScale is client i's own maximum-health scale, spread so the ratchet fires; powers of 1.5 rather than a random
// draw keep a run reproducible.
func creditScale(i int) float64 {
	scale := 1000.0
	for n := 0; n < i%4; n++ {
		scale *= 1.5
	}
	return scale
}
