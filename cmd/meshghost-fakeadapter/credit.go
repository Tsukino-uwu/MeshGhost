package main

// The kill-credit half of the synthetic-peer rig: N fake clients damaging
// shared synthetic enemies over the event plane, each folding the same ordered
// damage ledger and deciding for itself whether its own copy died and whether
// it earned the reward.
//
// **The design this checks is agent_docs/kill-credit.md**, and the single idea
// it rests on is that death is derived rather than announced: nobody sends "the
// enemy died", everyone applies the same ordered damage and arrives there
// independently. That is what makes the model falsifiable without a game, which
// is the only reason this rig can exist — participation, generations and the
// difficulty ratchet are arithmetic over an ordered stream, and arithmetic is
// exactly what CLAUDE.md says to confirm with the tools rather than by watching.
//
// Nothing here is a game and nothing here is shipped adapter behaviour. The
// enemies, the damage numbers and the difficulty scales are invented; what is
// real is the ordering, the folding rule, and the invariants below.
//
// Eight invariants are checked here, continuing controlplane.go's three and
// world.go's five:
//
//  9. **Exactly-once** — a report already applied never moves the fold again.
//     The relay's reliable plane does not duplicate, so this rig injects the
//     duplicates itself: an adapter that resumes after a blip, or folds both a
//     live stream and an adopted snapshot, will see the same hit twice, and the
//     applied-set is the only thing between that and a boss that dies early.
//  10. **Monotonic scale** — an encounter's difficulty ratchet never decreases
//     within a generation. This is what "don't scale it downwards" turns into,
//     and it has to hold across arrival order rather than only across the
//     sequence somebody imagined.
//  11. **No resurrection** — once a copy is dead for a generation it stays dead.
//     A later report, or a ratchet that grows the maximum, must not lift it off
//     zero; fractions make that true by construction, which is precisely why it
//     is worth asserting rather than assuming.
//  12. **Generation isolation** — a report from an older generation never
//     touches the current one. Without it a report in flight across a reset
//     lands on the fresh enemy and quietly damages it, which is invisible in a
//     log and obvious in a fight.
//  13. **Death agreement** — two participants that both watched a generation
//     from its start compute the *identical* killing stamp for it. This is the
//     real payoff: the wire-visible form of "everyone's copy died at the same
//     moment", and what a naive absolute-damage ledger breaks the instant two
//     clients disagree about maximum health.
//  14. **No credit without participation** — never rewarded for an enemy this
//     client never damaged.
//  15. **No credit while dead** — never rewarded for a kill that landed while
//     this client was dead. Tag it once, die, and get nothing.
//  16. **No liveness without participation** — a non-participant's copy never
//     dies. The other half of the same rule, and the one that stops a shared
//     "boss died" from robbing somebody of a fight they never joined.
//
// checkSeq in controlplane.go already covers ordering for this plane too: every
// report rides an event, stamped out of the same room counter as everything else.

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
	// dupEvery is how often a client deliberately re-sends its previous report.
	// A real transport will not do this to us, so invariant 9 would never be
	// exercised by traffic alone — and an untested applied-set is exactly the
	// kind of code that turns out to have been keyed by the wrong field.
	dupEvery time.Duration
	// deathEvery/deathFor are this client's own synthetic death windows, which
	// is what invariants 15 and 16 need in order to have anything to say.
	deathEvery time.Duration
	deathFor   time.Duration
}

// The whole report vocabulary. The relay understands none of it: this rides the
// event plane as an opaque payload, exactly as a real adapter's would.
const (
	creditHit   = "hit"
	creditReset = "reset"
	creditDeath = "death"
)

// creditMsg is one report on the ledger. Entirely made up, and entirely opaque
// to the core and relay.
type creditMsg struct {
	Op  string `json:"op"`
	Key string `json:"key"`
	Gen uint64 `json:"gen"`
	// DealerSeq is the sender's own counter, and together with the sender's
	// player_id it is what makes a report identifiable for invariant 9.
	// Deliberately NOT the relay's stamp: that is unique per delivery, so
	// deduplicating on it would dedupe nothing.
	DealerSeq uint64 `json:"dseq"`
	// Amt is damage in the dealer's own units and Scale is the dealer's own
	// maximum. Both are needed because neither alone means anything on another
	// client — see foldHit for the ratchet-then-divide rule that turns the pair
	// into a fraction everyone agrees on.
	Amt   float64 `json:"amt,omitempty"`
	Scale float64 `json:"scale,omitempty"`
	// At and Frac are carried only by a death report: the relay stamp of the
	// report that crossed zero, and the accumulated fraction at that moment.
	// They exist so participants can check agreement (invariant 13) rather than
	// each client silently believing its own arithmetic.
	At   uint64  `json:"at,omitempty"`
	Frac float64 `json:"frac,omitempty"`
}

// encounter is one client's fold of one (enemy, generation) pair.
type encounter struct {
	// scale is the ratchet: the running maximum over the difficulty of every
	// client that has actually damaged this enemy. Never decreases.
	scale float64
	// total is the PUBLIC fold: the accumulated share of the fight dealt by
	// everyone, advanced on every report whether this client is fighting or
	// not. frac is what this client's OWN copy has taken, which is zero until
	// it joins in.
	//
	// **They are two fields because a bystander has to track a fight it is not
	// in.** The moment it does swing, it adopts the accumulated total — the
	// mid-fight snap kill-credit.md names as a real visible cost — and folding
	// only one number would leave it with nothing to adopt and a boss at full
	// health. Found by this file's own test, which is the entire reason to
	// write the test before believing the model.
	total float64
	frac  float64
	// applied is the exactly-once set, keyed by dealer and dealer sequence.
	applied map[string]bool
	// participant is whether THIS client has damaged it, which is the only
	// thing deciding whether the fold above touches its own copy at all.
	participant bool
	// dead, deathAt and deathFrac are this client's own copy's death, recorded
	// when it crosses zero. announced is whether the room has been told.
	dead      bool
	deathAt   uint64
	deathFrac float64
	announced bool
	// sawStart is whether this client watched the generation from its first
	// report. A client that joined mid-fight legitimately folds a different
	// prefix, so it must not be judged against anyone else's total — see
	// onDeathReport.
	sawStart bool
	// credited records that this client took the reward, for invariants 14/15.
	credited bool
	// diedWhileDown records that the kill landed inside one of this client's
	// own death windows, which is what invariant 15 is judged against.
	diedWhileDown bool
}

// creditChecker is one client's view of the credit plane. Its own lock, like
// worldChecker's, because it is driven from both the receive callback and the
// attack goroutine and shares nothing with the lease/escrow state.
type creditChecker struct {
	cfg    creditConfig
	self   string
	scale  float64
	report func(format string, args ...any)

	mu sync.Mutex
	// enc is every (enemy, generation) this client has folded, keyed by encKey.
	// Kept after death rather than deleted, because invariants 11 and 13 are
	// both about what happens AFTER a copy dies.
	enc map[string]*encounter
	// gen is the current generation per enemy. Anything else is invariant 12's
	// business.
	gen map[string]uint64
	// alive is this client's own synthetic liveness. Guarded by mu so the death
	// window and the fold cannot disagree at the instant a kill lands, which is
	// the only instant it matters.
	alive bool
	// lastSent is the previous report per enemy, so the duplicate injector has
	// something real to re-send rather than a fabricated one.
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

// enemyKey is the opaque per-enemy key. A real adapter would put the game, the
// area and the enemy in here; the relay compares it for equality and learns
// nothing either way.
func enemyKey(i int) string { return fmt.Sprintf("enemy%d", i) }

// encKey pairs an enemy with a generation. One map key rather than a nested map
// because every invariant below is about one generation of one enemy, and a
// nested map invites reading the wrong generation's state.
func encKey(key string, gen uint64) string { return key + "#" + strconv.FormatUint(gen, 10) }

// splitEncKey is encKey's inverse. Enemy keys carry no '#' of their own, so the
// last one is the separator.
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

// atGen returns the fold for one generation, creating it on first sight.
// Caller must hold c.mu.
//
// **sawStart is set only by a reset**, which is the one event that proves this
// client was present when a generation began. A generation created by a hit is
// one it may have joined at any point, and judging its shorter prefix against
// everyone else's total would report the rig's own join time as a relay defect
// — the mistake world.go's checker made on its first soak, and worth not
// repeating. The cost is that invariant 13 says nothing about an enemy's first
// generation, or about any run with -enemy-reset-every 0.
func (c *creditChecker) atGen(key string, gen uint64, first bool) *encounter {
	k := encKey(key, gen)
	e := c.enc[k]
	if e == nil {
		e = &encounter{applied: make(map[string]bool), sawStart: first}
		c.enc[k] = e
	}
	return e
}

// onEvent folds one report. This is the whole model; everything else in this
// file either drives traffic into it or checks what it produced.
func (c *creditChecker) onEvent(ev protocol.Event) {
	var msg creditMsg
	if err := json.Unmarshal(ev.Payload, &msg); err != nil || msg.Key == "" {
		// Not ours. The event plane is shared with controlplane.go's own
		// chatter, so anything unparseable is somebody else's message rather
		// than a defect.
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

// foldHit applies one damage report, and is where every arithmetic decision in
// kill-credit.md actually lives.
func (c *creditChecker) foldHit(ev protocol.Event, msg creditMsg) {
	c.mu.Lock()
	defer c.mu.Unlock()

	cur, known := c.gen[msg.Key]
	if !known {
		// First time this client has heard of this enemy. Adopt whatever
		// generation the report carries rather than assuming zero, so a late
		// joiner does not spend the rest of the run discarding everything as
		// stale.
		c.gen[msg.Key] = msg.Gen
		cur = msg.Gen
	}
	if msg.Gen != cur {
		if msg.Gen < cur {
			// Invariant 12, and the case it exists for: a report in flight
			// across a reset. Discarding it is the correct behaviour, so this
			// is counted rather than reported.
			c.stale.Add(1)
			return
		}
		// Ahead of the reset that would have created it. Impossible from a
		// correct sender, and adopting it silently would let one confused
		// client drag the whole room's generation forward.
		c.report("client %s got a report for %s at generation %d while it is at %d "+
			"-- a generation cannot run ahead of the reset that created it",
			c.self, msg.Key, msg.Gen, cur)
		return
	}

	// Never `first`: an encounter created by a HIT is one this client did not
	// watch from the start, even when it is the first thing it ever heard about
	// the enemy. Only a reset proves otherwise — see atGen.
	e := c.atGen(msg.Key, msg.Gen, false)
	id := ev.From + ":" + strconv.FormatUint(msg.DealerSeq, 10)
	if e.applied[id] {
		// Invariant 9. A duplicate arriving is normal; applying it is not.
		// Returning here IS the invariant — the test asserts the fold did not
		// move, because a violation that only reports itself is one an
		// implementation can pass by reporting and then doing it anyway.
		return
	}
	e.applied[id] = true

	// **Ratchet first, then divide.** The dealer's own maximum joins the
	// running maximum before its damage is valued against it, which is what
	// makes an opener's hit worth its share of the fight it was actually
	// fighting and every later hit worth its share of the harder one. The other
	// order would value a Hard player's first hit against an Easy player's bar.
	prevScale := e.scale
	if msg.Scale > e.scale {
		e.scale = msg.Scale
	}
	if e.scale < prevScale {
		// Invariant 10. Structural above — scale only ever takes a max — so
		// this asserts that it stayed structural, and fails loudly the day the
		// max is "simplified" into an assignment. That is exactly the edit
		// somebody makes while adding a second scale source.
		c.report("client %s lowered %s's scale from %g to %g -- the ratchet must never go down",
			c.self, msg.Key, prevScale, e.scale)
		e.scale = prevScale
	}
	if e.scale <= 0 {
		return
	}
	// **The ledger is public; applying it to my own copy is not.** The total
	// advances for everyone, including a bystander who has never swung — that
	// is what it has to adopt if it ever does.
	if ev.From == c.self && e.total < 1 {
		// A participant joins only while there is still a fight to join. Past
		// that the enemy is already down in the shared ledger, and swinging at
		// it must not retroactively buy a share of a fight that is over.
		e.participant = true
	}
	e.total += msg.Amt / e.scale

	if !e.participant || e.dead {
		// Invariant 11 is the second half of that condition: once dead, later
		// reports move the public total and never this copy, so no ratchet and
		// no straggler can lift it off zero.
		return
	}
	// Catch-up is this single assignment. A client that has been folding all
	// along was already equal to the total; one that just joined snaps to it.
	e.frac = e.total
	c.hits.Add(1)

	if e.frac < 1 {
		return
	}
	// It just died on this client's copy.
	e.dead = true
	e.deathAt = ev.Seq
	e.deathFrac = e.frac
	c.kills.Add(1)
	if !e.participant {
		// Invariant 16. Unreachable by construction above, and asserted anyway:
		// this is the rule that stops a shared death from robbing somebody of a
		// fight they never joined, and a refactor that moved the participation
		// gate would otherwise break it in silence.
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

// foldReset moves an enemy to a new generation. Idempotent by generation, which
// is what lets any client issue one without coordinating: two clients resetting
// from the same generation both name the same successor, and the second is a
// no-op.
func (c *creditChecker) foldReset(msg creditMsg) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if msg.Gen <= c.gen[msg.Key] {
		return
	}
	c.gen[msg.Key] = msg.Gen
	// Created by the reset itself, so every client that saw the reset counts as
	// having watched this generation from its start.
	c.atGen(msg.Key, msg.Gen, true)
	c.resets.Add(1)
}

// onDeathReport is invariant 13, and the most valuable check in this file: two
// participants that both watched a generation from its start must have crossed
// zero on the SAME report.
func (c *creditChecker) onDeathReport(ev protocol.Event, msg creditMsg) {
	if ev.From == c.self {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.enc[encKey(msg.Key, msg.Gen)]
	if e == nil || !e.dead || !e.sawStart {
		// Nothing to compare, or this client joined mid-fight and legitimately
		// folded a different prefix. Declining to judge is the right answer:
		// the alternative reports the rig's own join time as a defect.
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

// checkCredit is invariants 14 and 15, run once at the end of a run rather than
// inline: they are properties of what a client walked away with, and the
// cheapest place to be sure of them is over everything, once.
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

// setAlive opens or closes this client's death window, reporting whether it
// changed so the caller can act on a transition without holding the lock.
func (c *creditChecker) setAlive(alive bool) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.alive == alive {
		return false
	}
	c.alive = alive
	return true
}

// nextReport builds this client's next hit on one enemy. Returns false when
// there is nothing to send, which is the normal state for an enemy already dead
// on this client's copy.
func (c *creditChecker) nextReport(key string) (creditMsg, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	gen := c.gen[key]
	if e := c.enc[encKey(key, gen)]; e != nil && e.total >= 1 {
		// The PUBLIC total, not this client's own copy: a bystander's copy is
		// never dead, and letting it keep hammering an enemy the room has
		// already killed would generate traffic no adapter would ever send.
		return creditMsg{}, false
	}
	c.dealerNo++
	// Damage as a fixed share of this client's own scale, so a fight takes a
	// predictable number of hits at any difficulty — which keeps a run's
	// duration independent of which clients happened to join it.
	msg := creditMsg{
		Op: creditHit, Key: key, Gen: gen, DealerSeq: c.dealerNo,
		Amt: c.scale / 8, Scale: c.scale,
	}
	c.lastSent[key] = msg
	return msg, true
}

// lastReport returns the previous report for an enemy, for the duplicate
// injector.
func (c *creditChecker) lastReport(key string) (creditMsg, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	msg, ok := c.lastSent[key]
	return msg, ok
}

// deathToAnnounce returns one death this client has not yet told the room
// about. Announcing is what makes invariant 13 checkable at all: without it
// every client believes its own arithmetic and no disagreement is ever visible.
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

// stats is the end-of-run summary line for this plane.
func (c *creditChecker) stats() string {
	return fmt.Sprintf("hits=%d kills=%d rewards=%d agreed=%d resets=%d stale=%d",
		c.hits.Load(), c.kills.Load(), c.rewards.Load(),
		c.agreedOn.Load(), c.resets.Load(), c.stale.Load())
}

// runCredit drives this client's credit traffic until stop closes: attack
// enemies, occasionally re-send a report, occasionally reset one, announce its
// own kills, and go in and out of its own death windows.
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
	// Announcing is cheap and only fires when there is an unannounced kill, so
	// it runs on its own short tick rather than being bolted onto the hit tick,
	// where a client that had stopped attacking would never announce.
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
			// Invariant 9's traffic. A real transport will not duplicate a
			// reliable event, so if the rig does not do it deliberately the
			// applied-set is never exercised at all.
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
			// Down for deathFor, then back up on its own timer, so a client is
			// alive for most of a run and dead for a real slice of it.
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

// creditScale is client i's own maximum-health scale, and the spread is
// deliberate: with every client on the same difficulty the ratchet never fires,
// so a run would exercise the easy half of the model and report the hard half
// as green. Powers of 1.5 rather than a random draw keeps a run reproducible.
func creditScale(i int) float64 {
	scale := 1000.0
	for n := 0; n < i%4; n++ {
		scale *= 1.5
	}
	return scale
}
